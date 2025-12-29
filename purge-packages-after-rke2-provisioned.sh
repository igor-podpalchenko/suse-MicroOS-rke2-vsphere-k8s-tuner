#!/usr/bin/env bash
set -euo pipefail

# strip.sh (MicroOS)
# - Remove provisioning/firstboot + kdump tooling + some docs-ish pkgs + ISO authoring stack
# - Purge man pages dirs (show size)
# Hard rules:
#   - NEVER remove NetworkManager* packages (we lock them during solve/apply)
#   - DO NOT remove: wpa_supplicant, ModemManager, libbluetooth3 (not referenced at all)

APPLY=0
while (($#)); do
  case "$1" in
    --apply) APPLY=1 ;;
    -h|--help)
      cat <<'EOF'
Usage:
  ./strip.sh
    Dry-run only (shows planned removals + size estimate + current man-dir size)

  sudo ./strip.sh --apply
    Apply via transactional-update (creates new snapshot), then reboot
EOF
      exit 0
      ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
  shift
done

SUDO=""
if [[ "$(id -u)" -ne 0 ]]; then
  SUDO="sudo"
fi

SNAPPER_CMD=(snapper)
if [[ -n "$SUDO" ]]; then
  SNAPPER_CMD=("$SUDO" snapper)
fi

snapper_capture_state() {
  local out_var="$1"
  local -n out_ref="$out_var"
  out_ref=()

  local snapper_bin="${SNAPPER_CMD[${#SNAPPER_CMD[@]}-1]}"
  if ! command -v "${snapper_bin}" >/dev/null 2>&1; then
    echo "[warn] snapper not found; snapshot descriptions will not be updated" >&2
    return 1
  fi

  mapfile -t out_ref < <("${SNAPPER_CMD[@]}" --csvout list 2>/dev/null | awk 'NR>1')
  return 0
}

annotate_snapper_diff() {
  local desc="$1"
  local before_var="$2"
  local -n before_ref="$before_var"

  local snapper_bin="${SNAPPER_CMD[${#SNAPPER_CMD[@]}-1]}"
  if ! command -v "${snapper_bin}" >/dev/null 2>&1; then
    return 0
  fi

  local -A before_set before_dates
  for line in "${before_ref[@]}"; do
    IFS=';' read -r id type pre date user cleanup desc_before userdata_before <<<"$line"
    [[ -z "$id" ]] && continue
    before_set["$id"]=1
    before_dates["$id"]="$date"
  done

  local -a after_lines=()
  mapfile -t after_lines < <("${SNAPPER_CMD[@]}" --csvout list 2>/dev/null | awk 'NR>1')
  local -A after_pre after_date after_userdata
  for line in "${after_lines[@]}"; do
    IFS=';' read -r id type pre date user cleanup desc_after userdata_after <<<"$line"
    [[ -z "$id" ]] && continue
    after_pre["$id"]="$pre"
    after_date["$id"]="$date"
    after_userdata["$id"]="$userdata_after"
  done

  for id in "${!after_pre[@]}"; do
    [[ -n "${before_set[$id]:-}" ]] && continue
    local parent="${after_pre[$id]}"
    local parent_date=""
    if [[ -n "$parent" && "$parent" != "-" && "$parent" != "0" ]]; then
      parent_date="${after_date[$parent]:-}"
    fi

    local -a userdata_fields=()
    if [[ -n "${after_userdata[$id]}" ]]; then
      userdata_fields+=("${after_userdata[$id]}")
    fi
    if [[ -n "$parent" && "$parent" != "-" && "$parent" != "0" ]]; then
      userdata_fields+=("parent_id=${parent}")
      if [[ -n "$parent_date" ]]; then
        userdata_fields+=("parent_date=${parent_date// /T}")
      fi
    fi
    local combined_userdata
    combined_userdata="$(printf '%s ' "${userdata_fields[@]}" | sed 's/[[:space:]]*$//')"

    echo "[apply] ${SNAPPER_CMD[*]} modify --description \"${desc}\" --userdata \"${combined_userdata}\" ${id}"
    "${SNAPPER_CMD[@]}" modify --description "$desc" --userdata "$combined_userdata" "$id" || true
  done
}

is_installed() { rpm -q "$1" >/dev/null 2>&1; }

rpm_kib() {
  local p="$1"
  rpm -q --qf '%{INSTALLSIZE}\n' "$p" 2>/dev/null | head -n1 || true
}

# Parse package names from zypper output:
# "The following N packages are going to be REMOVED:" then lines of names.
parse_planned_pkgs() {
  awk '
    BEGIN {mode=0}
    /^The following [0-9]+ packages are going to be REMOVED:/ {mode=1; next}
    mode==1 {
      if ($0 ~ /^[[:space:]]*$/) {mode=0; next}
      for (i=1;i<=NF;i++) print $i
    }
  ' | sort -u
}

print_size_table_from_list() {
  local title="$1"
  shift
  local pkgs=("$@")

  echo
  echo "[info] $title"
  if ((${#pkgs[@]} == 0)); then
    echo "  (none)"
    return 0
  fi

  local tsv=""
  for p in "${pkgs[@]}"; do
    local kib=0
    if is_installed "$p"; then
      kib="$(rpm_kib "$p")"
      [[ -n "${kib:-}" ]] || kib=0
    fi
    tsv+="${p}\t${kib}\n"
  done

  echo -e "$tsv" | sort -k2,2nr | awk '
    BEGIN {
      printf "  %-40s %12s\n", "PACKAGE", "MiB"
      printf "  %-40s %12s\n", "----------------------------------------", "------------"
      total_kib=0
    }
    {
      pkg=$1; kib=$2+0
      total_kib+=kib
      printf "  %-40s %12.2f\n", pkg, kib/1024.0
    }
    END {
      printf "  %-40s %12s\n", "----------------------------------------", "------------"
      printf "  %-40s %12.2f\n", "TOTAL (approx)", total_kib/1024.0
    }
  '
}

installed_from_list() {
  local out=()
  for p in "$@"; do
    if is_installed "$p"; then out+=("$p"); fi
  done
  printf '%s\n' "${out[@]}"
}

du_bytes() {
  local path="$1"
  if [[ -d "$path" ]]; then
    du -sb "$path" 2>/dev/null | awk '{print $1}' || echo 0
  else
    echo 0
  fi
}

du_human() {
  local path="$1"
  if [[ -d "$path" ]]; then
    du -sh "$path" 2>/dev/null | awk '{print $1}' || echo "0"
  else
    echo "0"
  fi
}

# ---- NetworkManager protection via lock ----
NM_LOCK_SPEC='NetworkManager*'
NM_LOCK_ADDED=0

nm_lock_present() {
  # "zypper locks" prints a table; grep is good enough for the exact spec we add.
  $SUDO zypper -n locks 2>/dev/null | grep -Fq "$NM_LOCK_SPEC"
}

nm_lock_add_temp() {
  if nm_lock_present; then
    return 0
  fi
  echo "[info] Adding temporary zypper lock to prevent NM removal: ${NM_LOCK_SPEC}"
  $SUDO zypper -n addlock "$NM_LOCK_SPEC" >/dev/null
  NM_LOCK_ADDED=1
}

nm_lock_remove_temp() {
  if ((NM_LOCK_ADDED == 1)); then
    echo "[info] Removing temporary zypper lock: ${NM_LOCK_SPEC}"
    $SUDO zypper -n removelock "$NM_LOCK_SPEC" >/dev/null 2>&1 || true
  fi
}

trap nm_lock_remove_temp EXIT

run_dry() {
  $SUDO zypper -n rm --dry-run --no-clean-deps "$@"
}

# -----------------------------
# Targets (explicit packages)
# -----------------------------
CORE_TARGETS=(
  # Provisioning / cloud-init / first boot
  cloud-init
  cloud-init-config-MicroOS
  combustion
  ignition
  jeos-firstboot
  ssh-pairing

  # Crash dump tooling (kdump)
  kdump
  kexec-tools
  makedumpfile

  # Logs / docs-ish packages
  yast2-logs
  info
  less
  mandoc-bin

  # ISO/image authoring stack
  xorriso
  libburn4
  libisoburn1
  libisofs6
  libjte2

  # --- Python 3.13 stack (explicit; remove all) ---
  libpython3_13-1_0
  python313
  python313-base
  python313-attrs
  python313-PyJWT
  python313-passlib
  python313-urllib3
  python313-typing_extensions
  python313-setuptools
  python313-pyserial
  python313-pycparser
  python313-cffi
  python313-maturin
  python313-rpds-py
  python313-referencing
  python313-jsonschema-specifications
  python313-jsonschema
  python313-jsonpointer
  python313-jsonpatch
  python313-idna
  python313-configobj
  python313-charset-normalizer
  python313-certifi
  python313-requests
  python313-blinker
  python313-bcrypt
  python313-cryptography
  python313-oauthlib
  python313-MarkupSafe
  python313-Jinja2
  python313-PyYAML

  # Intentionally NOT including:
  #   wpa_supplicant, ModemManager, libbluetooth3
  # and NOT any NetworkManager* packages.
)

# Tooling that typically installs a lot of man pages (remove if installed)
MAN_TOOLING_TARGETS=(
  man
  man-pages
  man-pages-posix
  man-pages-posix-devel
  man-pages-devel
  groff
  groff-base
  groff-full
)

echo "[info] Collecting installed packages from explicit removal list..."
CORE_INSTALLED=($(installed_from_list "${CORE_TARGETS[@]}" || true))
MANPKG_INSTALLED=($(installed_from_list "${MAN_TOOLING_TARGETS[@]}" || true))

ALL_REQ=("${CORE_INSTALLED[@]}" "${MANPKG_INSTALLED[@]}")

echo
echo "[info] Explicit targets (installed): ${#ALL_REQ[@]}"
for p in "${ALL_REQ[@]}"; do
  echo "  - $p"
done

echo
echo "[info] Man directories current size (will be purged by directory delete, not by RPM):"
USR_MAN_BYTES="$(du_bytes /usr/share/man)"
USR_MAN_HUMAN="$(du_human /usr/share/man)"
USRL_MAN_BYTES="$(du_bytes /usr/local/share/man)"
USRL_MAN_HUMAN="$(du_human /usr/local/share/man)"
echo "  /usr/share/man        : ${USR_MAN_HUMAN}  (${USR_MAN_BYTES} bytes)"
echo "  /usr/local/share/man  : ${USRL_MAN_HUMAN}  (${USRL_MAN_BYTES} bytes)"

# Ensure NM cannot be removed by solver
nm_lock_add_temp

echo
echo "[info] Running zypper dry-run to discover planned removals..."

PLANNED=""
if ((${#ALL_REQ[@]} > 0)); then
  DRY_OUT="$(run_dry "${ALL_REQ[@]}" 2>&1)" || {
    echo
    echo "[error] zypper dry-run failed:"
    echo "----------------------------------------------------------------------"
    echo "$DRY_OUT"
    echo "----------------------------------------------------------------------"
    exit 1
  }
  PLANNED="$(parse_planned_pkgs <<<"$DRY_OUT")"
fi

# With the lock in place, NM packages should not appear.
if [[ -n "${PLANNED:-}" ]] && grep -Eq '^(NetworkManager|NetworkManager-)' <<<"$PLANNED"; then
  echo
  echo "[ABORT] Even with a zypper lock, NetworkManager packages are still planned for removal."
  echo "This indicates something unusual in solver behavior. Refusing to proceed."
  echo
  echo "[debug] Planned removals that triggered abort:"
  grep -E '^(NetworkManager|NetworkManager-)' <<<"$PLANNED" | sed 's/^/  - /' || true
  exit 1
fi

echo
echo "[info] Planned RPM packages to be removed (zypper):"
if [[ -n "${PLANNED:-}" ]]; then
  echo "$PLANNED" | sed 's/^/  - /'
else
  echo "  (none)"
fi

# Size estimate for planned removals (only installed RPMs)
SIZE_PKGS=()
if [[ -n "${PLANNED:-}" ]]; then
  while read -r p; do
    [[ -n "$p" ]] || continue
    if is_installed "$p"; then SIZE_PKGS+=("$p"); fi
  done <<<"$PLANNED"
fi

print_size_table_from_list "Size on disk for planned RPM removals (rpm INSTALLSIZE KiB → MiB):" "${SIZE_PKGS[@]}"

echo
echo "[info] Size on disk for man-page directories to be purged:"
TOTAL_MAN_BYTES=$((USR_MAN_BYTES + USRL_MAN_BYTES))
if command -v numfmt >/dev/null 2>&1; then
  TOTAL_MAN_HUMAN="$(numfmt --to=iec --suffix=B "${TOTAL_MAN_BYTES}" 2>/dev/null || echo "${TOTAL_MAN_BYTES}B")"
else
  TOTAL_MAN_HUMAN="${TOTAL_MAN_BYTES} bytes"
fi
echo "  TOTAL man dirs (approx): ${TOTAL_MAN_HUMAN}"

if ((APPLY == 0)); then
  echo
  echo "[dry-run] No changes made."
  echo "To apply removal (creates new snapshot):"
  echo "  $SUDO ./strip.sh --apply"
  exit 0
fi

echo
echo "[apply] Applying transactional changes (creates new snapshot):"
echo "        - RPM removals (safe list)"
echo "        - Purge man directories (/usr/share/man, /usr/local/share/man)"
echo "        - NetworkManager* is protected by zypper lock: ${NM_LOCK_SPEC}"

SNAP_BEFORE=()
SNAPPER_TRACKING=0
if snapper_capture_state SNAP_BEFORE; then
  SNAPPER_TRACKING=1
fi

# Apply inside a new snapshot
$SUDO transactional-update -n run bash -lc "
set -euo pipefail

echo '[tu] Pre: man dir sizes'
if [[ -d /usr/share/man ]]; then du -sh /usr/share/man || true; fi
if [[ -d /usr/local/share/man ]]; then du -sh /usr/local/share/man || true; fi

if ((${#ALL_REQ[@]} > 0)); then
  echo '[tu] Removing RPM packages (no-clean-deps): ${ALL_REQ[*]}'
  zypper -n rm --no-clean-deps ${ALL_REQ[*]}
else
  echo '[tu] No RPM packages to remove'
fi

echo '[tu] Purging man directories'
rm -rf /usr/share/man /usr/local/share/man || true
mkdir -p /usr/share/man || true
rm -rf /var/cache/man 2>/dev/null || true

echo '[tu] Post: man dir sizes'
if [[ -d /usr/share/man ]]; then du -sh /usr/share/man || true; fi
if [[ -d /usr/local/share/man ]]; then du -sh /usr/local/share/man || true; fi

echo '[tu] Post-check: python313'
rpm -q python313 && echo '[tu][WARN] python313 still installed' || echo '[tu] python313 removed'

echo '[tu] Done'
"

echo
echo "[apply] Done. Reboot to activate:"
echo "  $SUDO reboot"
echo
echo "[apply] Rollback if needed:"
echo "  $SUDO transactional-update rollback && $SUDO reboot"

if ((SNAPPER_TRACKING == 1)); then
  annotate_snapper_diff "purge-packages-after-rke2-provisioned --apply" SNAP_BEFORE
fi
