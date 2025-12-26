#!/usr/bin/env bash
set -euo pipefail

# kpurge2.sh
# Purge kernel modules on openSUSE MicroOS using transactional-update.
#
# v11 (2025-12-26) — FIX: inline TU payload (no /var/tmp script dependency),
#                    update ONLY filtering policy per vSphere+k8s profile.
SCRIPT_VERSION="v11 (2025-12-26) — inline TU payload; filter: hard delete wireless+sound, prune classes, keep VMware essentials"

usage() {
  cat <<'EOF'
Usage:
  ./kpurge2.sh            # dry-run: show what would be removed
  ./kpurge2.sh --apply    # apply inside transactional-update snapshot (requires reboot)

Notes:
  - Designed for openSUSE MicroOS / transactional-update systems.
  - Candidate = matches_delete_profile(relpath) AND NOT REQUIRED(lsmod+deps) AND NOT VMware keep-list.
  - --apply runs ALL discovery+delete INSIDE a transactional-update snapshot (inline payload).
EOF
}

APPLY=0
case "${1:-}" in
  --apply) APPLY=1 ;;
  "" ) ;;
  -h|--help) usage; exit 0 ;;
  *) echo "[ERR] unknown arg: $1"; usage; exit 2 ;;
esac

KVER="$(uname -r)"
ROOT="/lib/modules/${KVER}/kernel"
DRIVERS_ROOT="${ROOT}/drivers"

bytes_human() {
  local n="${1:-0}"
  if command -v numfmt >/dev/null 2>&1; then
    numfmt --to=iec --suffix=B "$n"
  else
    echo "${n}B"
  fi
}

modules_stats() {
  local root="$1"
  find "$root" -type f \( -name '*.ko' -o -name '*.ko.zst' -o -name '*.ko.xz' -o -name '*.ko.gz' \) -print0 2>/dev/null \
  | while IFS= read -r -d '' f; do
      stat -c '%s' "$f" 2>/dev/null || echo 0
    done \
  | awk '{c+=1; s+=$1} END{printf "%d %d\n", c+0, s+0}'
}

echo "[info] kpurge ${SCRIPT_VERSION}"
echo "[info] Script: $(readlink -f "$0" 2>/dev/null || echo "$0")"
echo "[info] Parsed: APPLY=${APPLY}  KVER=${KVER}"
echo "[info] Kernel: ${KVER}"
echo "[info] Drivers root: ${DRIVERS_ROOT}"
read -r pre_count pre_bytes < <(modules_stats "$DRIVERS_ROOT")
echo "[info] Overall *.ko* under drivers: ${pre_count} files, $(bytes_human "$pre_bytes")"

cat <<EOF
[info] Purge profile summary (vSphere + k8s node):
  - HARD DELETE:
      * ${ROOT}/drivers/net/wireless/**
      * ${ROOT}/sound/**
  - DELETE (broad classes), with VMware keep-list + REQUIRED exclusions:
      * gpu, media, bluetooth, usb, firewire, ieee1394, thunderbolt, infiniband,
        mmc, input, hid, staging, fpga, thermal, hwmon
  - KEEP (even if under deleted trees):
      * VMware essentials (allowlist): vmxnet3/vmxnet, vmw_pvscsi, vmw_vmci, vmw_balloon,
        vsock/vhost_vsock/vmw_vsock_*, ahci/libahci/ata_piix/nvme,
        sd_mod/sr_mod, e1000/e1000e/pcnet32, ttm/drm_ttm_helper/vmwgfx, mpt* SAS
  - ALSO KEEP:
      * Anything in REQUIRED set (lsmod + dependency closure)
EOF

if (( APPLY == 0 )); then
  echo
  echo "[dry-run] No changes made."
  echo "To apply (creates new snapshot):"
  echo "   $0 --apply"
  exit 0
fi

LOG="/var/tmp/kpurge.${KVER}.apply.log"
echo
echo "[apply] Starting transactional-update; all discovery+delete happens INSIDE snapshot."
echo "[apply] Log: ${LOG}"
echo "[apply] Running transactional-update now..."

# IMPORTANT: Inline TU payload. Do NOT rely on /var/tmp script existing in snapshot.
transactional-update -n run bash -lc "$(cat <<'EOS'
set -euo pipefail

bytes_human() {
  local n="${1:-0}"
  if command -v numfmt >/dev/null 2>&1; then numfmt --to=iec --suffix=B "$n"; else echo "${n}B"; fi
}

modules_stats() {
  local root="$1"
  find "$root" -type f \( -name '*.ko' -o -name '*.ko.zst' -o -name '*.ko.xz' -o -name '*.ko.gz' \) -print0 2>/dev/null \
  | while IFS= read -r -d '' f; do stat -c '%s' "$f" 2>/dev/null || echo 0; done \
  | awk '{c+=1; s+=$1} END{printf "%d %d\n", c+0, s+0}'
}

norm_mod() {
  local m="$1"
  m="${m%.ko}"
  m="${m%.ko.zst}"
  m="${m%.ko.xz}"
  m="${m%.ko.gz}"
  m="${m//-/_}"
  echo "$m"
}

modinfo_field() {
  local kver="$1"
  local field="$2"
  local mod="$3"
  if modinfo -k "$kver" -F "$field" "$mod" >/dev/null 2>&1; then
    modinfo -k "$kver" -F "$field" "$mod" 2>/dev/null || true
  else
    modinfo -F "$field" "$mod" 2>/dev/null || true
  fi
}

# VMware essentials allowlist (basename match, normalized)
KEEP_VMW_BASENAMES=(
  vmw_balloon
  vmxnet3
  vmw_pvscsi
  vmwgfx
  vmw_vmci
  vmw_vsock_vmci_transport
  vmw_vsock_virtio_transport
  vsock
  vhost_vsock
  vmmouse

  ahci
  libahci
  ata_piix
  nvme

  sd_mod
  sr_mod

  e1000
  e1000e
  pcnet32
  vmxnet

  mptspi
  mptsas
  mpt3sas

  drm_ttm_helper
  ttm
)

is_keep_vmw_module() {
  local base="$1"
  base="$(norm_mod "$base")"
  local k
  for k in "${KEEP_VMW_BASENAMES[@]}"; do
    [[ "$base" == "$(norm_mod "$k")" ]] && return 0
  done
  return 1
}

# Filtering policy (ONLY filtering changed):
#  - HARD DELETE: drivers/net/wireless/** and sound/**
#  - DELETE classes: gpu, media, bluetooth, usb, firewire, ieee1394, thunderbolt, infiniband,
#                    mmc, input, hid, staging, fpga, thermal, hwmon
#  - KEEP: VMware essentials allowlist
matches_delete_profile() {
  local rel="$1"          # relative to $ROOT
  local base="${rel##*/}" # basename

  # Always keep VMware essentials
  if is_keep_vmw_module "$base"; then
    return 1
  fi

  # Remove completely
  if [[ "$rel" == drivers/net/wireless/* ]]; then
    return 0
  fi
  if [[ "$rel" == sound/* ]]; then
    return 0
  fi

  # Remove with exclusions (broad classes)
  case "$rel" in
    drivers/gpu/*|gpu/*) return 0 ;;
    drivers/media/*|media/*) return 0 ;;
    drivers/bluetooth/*|bluetooth/*) return 0 ;;
    drivers/usb/*|usb/*) return 0 ;;
    drivers/firewire/*|firewire/*) return 0 ;;
    drivers/ieee1394/*|ieee1394/*) return 0 ;;
    drivers/thunderbolt/*|thunderbolt/*) return 0 ;;
    drivers/infiniband/*|infiniband/*) return 0 ;;
    drivers/mmc/*|mmc/*) return 0 ;;
    drivers/input/*|input/*) return 0 ;;
    drivers/hid/*|hid/*) return 0 ;;
    drivers/staging/*|staging/*) return 0 ;;
    drivers/fpga/*|fpga/*) return 0 ;;
    drivers/thermal/*|thermal/*) return 0 ;;
    drivers/hwmon/*|hwmon/*) return 0 ;;
  esac

  # keep everything else by default
  return 1
}

KVER="$(uname -r)"
ROOT="/lib/modules/${KVER}/kernel"
DRIVERS_ROOT="${ROOT}/drivers"

echo "[tu] hello from TU snapshot"
echo "[tu] kernel=${KVER}"
echo "[tu] root=${ROOT}"

echo "[tu] Overall *.ko* under drivers BEFORE:"
read -r pre_count pre_bytes < <(modules_stats "$DRIVERS_ROOT")
echo "[tu]   count=$pre_count  size=$(bytes_human "$pre_bytes")"

# Build REQUIRED set = loaded modules + dependency closure
declare -A REQUIRED=()
declare -a QUEUE=()

if command -v lsmod >/dev/null 2>&1; then
  while read -r mod _; do
    [[ "$mod" == "Module" ]] && continue
    [[ -n "$mod" ]] || continue
    mod="$(norm_mod "$mod")"
    if [[ -z "${REQUIRED[$mod]+x}" ]]; then
      REQUIRED["$mod"]=1
      QUEUE+=("$mod")
    fi
  done < <(lsmod | awk '{print $1" "$2}' || true)
fi

q=0
while [[ $q -lt ${#QUEUE[@]} ]]; do
  m="${QUEUE[$q]}"
  q=$((q+1))
  deps="$(modinfo_field "$KVER" depends "$m" | head -n1 || true)"
  [[ -n "${deps:-}" ]] || continue
  IFS=',' read -r -a arr <<<"$deps"
  for d in "${arr[@]}"; do
    d="$(echo "$d" | tr -d '[:space:]')"
    [[ -n "$d" ]] || continue
    d="$(norm_mod "$d")"
    if [[ -z "${REQUIRED[$d]+x}" ]]; then
      REQUIRED["$d"]=1
      QUEUE+=("$d")
    fi
  done
done

echo "[tu] required_modules=${#REQUIRED[@]}"

# Enumerate module files (kernel root: includes drivers/, sound/, net/, etc.)
mapfile -d '' -t ALL_FILES < <(
  find "$ROOT" -type f \( -name '*.ko' -o -name '*.ko.zst' -o -name '*.ko.xz' -o -name '*.ko.gz' \) -print0 2>/dev/null
)
echo "[tu] module_files_under_root=${#ALL_FILES[@]}"

TMP_SIZED="/tmp/kpurge.${KVER}.sized"
: >"$TMP_SIZED"

cand_count=0
cand_bytes=0
top1_path=""
top1_size=0

for f in "${ALL_FILES[@]}"; do
  rel="${f#$ROOT/}"

  matches_delete_profile "$rel" || continue

  base="$(basename "$f")"
  mod="$(norm_mod "$base")"
  [[ -n "${REQUIRED[$mod]+x}" ]] && continue

  sz="$(stat -c '%s' "$f" 2>/dev/null || echo 0)"
  cand_count=$((cand_count+1))
  cand_bytes=$((cand_bytes+sz))
  printf '%s\t%s\n' "$sz" "$f" >>"$TMP_SIZED"

  if (( sz > top1_size )); then
    top1_size=$sz
    top1_path="$f"
  fi
done

echo "[tu] candidates=$cand_count candidates_size=$(bytes_human "$cand_bytes")"
echo "[tu] top25:"
if [[ -s "$TMP_SIZED" ]]; then
  # avoid SIGPIPE(141): no head
  sort -k1,1nr "$TMP_SIZED" | awk -F'\t' 'NR<=25 {printf "  %10s  %s\n", $1, $2}'
fi

if ((cand_count == 0)); then
  echo "[tu] no candidates -> nothing to delete"
  exit 0
fi

echo "[tu] top1 candidate (largest) should be deleted:"
echo "[tu]   ${top1_size}  ${top1_path}"

# Delete
deleted=0
failed=0
deleted_bytes=0

while IFS=$'\t' read -r sz f; do
  [[ -n "$f" ]] || continue
  [[ -e "$f" ]] || continue
  if rm -f -- "$f"; then
    deleted=$((deleted+1))
    deleted_bytes=$((deleted_bytes+sz))
  else
    failed=$((failed+1))
    echo "[tu][WARN] failed to delete: $f"
  fi
done <"$TMP_SIZED"

echo "[tu] deleted=$deleted failed=$failed deleted_bytes=$(bytes_human "$deleted_bytes")"

echo "[tu] depmod -a $KVER"
depmod -a "$KVER" || true

if [[ -n "${top1_path:-}" ]]; then
  if [[ -e "$top1_path" ]]; then
    echo "[tu][WARN] top1 still exists after delete: $top1_path"
  else
    echo "[tu] verified: top1 removed"
  fi
fi

echo "[tu] Overall *.ko* under drivers AFTER:"
read -r post_count post_bytes < <(modules_stats "$DRIVERS_ROOT")
echo "[tu]   count=$post_count  size=$(bytes_human "$post_bytes")"
freed=$((pre_bytes - post_bytes))
echo "[tu] Freed-bytes (drivers subtree): $(bytes_human "$freed")"

echo "[tu] DONE"
EOS
)" 2>&1 | tee "$LOG"

echo
echo "[apply] transactional-update finished. Reboot to activate:"
echo "   reboot"
echo
echo "[apply] Rollback if needed:"
echo "   transactional-update rollback && reboot"
