#!/usr/bin/env bash
set -euo pipefail

# prune_snapper_keep_default.sh
#
# Goal:
#   Remove all old Snapper snapshots so that, after reboot, GRUB shows
#   only ONE "Snapshot Update of #N" entry (the default snapshot).
#
# Safety:
#   - Always keeps #1 (first root filesystem)
#   - Keeps the *default* snapshot (the one that will boot next)
#   - Keeps the *current* snapshot (if booted from /.snapshots/N/snapshot), to avoid self-amputation
#
# Usage:
#   sudo ./prune_snapper_keep_default.sh          # dry-run
#   sudo ./prune_snapper_keep_default.sh --apply  # delete
#
# Optional:
#   --config root   (snapper config name; default: root)

APPLY=0
CFG="root"

while (($#)); do
  case "$1" in
    --apply) APPLY=1 ;;
    --config) CFG="${2:-}"; shift ;;
    -h|--help)
      cat <<EOF
Usage:
  sudo $0 [--apply] [--config root]

Default is dry-run. Use --apply to delete snapshots.
EOF
      exit 0
      ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
  shift
done

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run as root." >&2
  exit 1
fi

have() { command -v "$1" >/dev/null 2>&1; }

if ! have snapper; then
  echo "snapper not found." >&2
  exit 1
fi
if ! have btrfs; then
  echo "btrfs not found." >&2
  exit 1
fi
if ! have findmnt; then
  echo "findmnt not found." >&2
  exit 1
fi

extract_snapnum_from_path() {
  # Accept paths like:
  #   .snapshots/5/snapshot
  #   /.snapshots/5/snapshot
  #   @/.snapshots/5/snapshot
  local p="$1"
  if [[ "$p" =~ \.snapshots/([0-9]+)/snapshot ]]; then
    echo "${BASH_REMATCH[1]}"
    return 0
  fi
  return 1
}

get_default_snapshot_num() {
  # btrfs subvolume get-default /  -> includes "path ..."
  local line path
  line="$(btrfs subvolume get-default / 2>/dev/null || true)"
  path="${line##* path }"
  if [[ -z "$line" || "$path" == "$line" ]]; then
    return 1
  fi
  extract_snapnum_from_path "$path"
}

get_current_snapshot_num() {
  # findmnt -no OPTIONS / -> contains subvol=...
  local opts subvol
  opts="$(findmnt -no OPTIONS / 2>/dev/null || true)"
  subvol="$(tr ',' '\n' <<<"$opts" | sed -n 's/^subvol=//p' | head -n1)"
  [[ -n "$subvol" ]] || return 1
  extract_snapnum_from_path "$subvol"
}

DEFAULT_SNAP=""
CURRENT_SNAP=""

if DEFAULT_SNAP="$(get_default_snapshot_num 2>/dev/null)"; then
  :
else
  echo "[ERR] Could not determine default snapshot number from btrfs default subvolume." >&2
  echo "      btrfs subvolume get-default / output was:" >&2
  btrfs subvolume get-default / >&2 || true
  exit 1
fi

if CURRENT_SNAP="$(get_current_snapshot_num 2>/dev/null)"; then
  :
else
  CURRENT_SNAP="" # might be "first root filesystem" (not a /.snapshots/N boot)
fi

# Build keep-set
declare -A KEEP=()
KEEP["1"]=1
KEEP["$DEFAULT_SNAP"]=1
if [[ -n "$CURRENT_SNAP" ]]; then
  KEEP["$CURRENT_SNAP"]=1
fi

echo "[info] snapper config : $CFG"
echo "[info] keep snapshots : $(printf "%s " "${!KEEP[@]}" | xargs echo)"
echo "[info] default snap   : $DEFAULT_SNAP"
echo "[info] current snap   : ${CURRENT_SNAP:-<not booted from /.snapshots/N>} "
echo

# Get all snapshot numbers
# Prefer stable column output; fall back to parsing if needed.
mapfile -t ALL < <(snapper -c "$CFG" list --no-headers --columns number 2>/dev/null | awk '{print $1}' || true)
if [[ "${#ALL[@]}" -eq 0 ]]; then
  # fallback parse: first column of normal output is the number
  mapfile -t ALL < <(snapper -c "$CFG" list --no-headers 2>/dev/null | awk '{print $1}' || true)
fi

# Filter deletions
DEL=()
for n in "${ALL[@]}"; do
  [[ "$n" =~ ^[0-9]+$ ]] || continue
  # skip special 0 if present
  [[ "$n" -eq 0 ]] && continue
  if [[ -z "${KEEP[$n]+x}" ]]; then
    DEL+=("$n")
  fi
done

if [[ "${#DEL[@]}" -eq 0 ]]; then
  echo "[info] Nothing to delete. Snapper snapshot set already minimal."
  exit 0
fi

# Sort deletions
IFS=$'\n' DEL=($(printf "%s\n" "${DEL[@]}" | sort -n))
unset IFS

# Build ranges for nicer deletion
RANGES=()
start="${DEL[0]}"
prev="${DEL[0]}"

for ((i=1; i<${#DEL[@]}; i++)); do
  cur="${DEL[i]}"
  if [[ "$cur" -eq $((prev + 1)) ]]; then
    prev="$cur"
    continue
  fi
  if [[ "$start" -eq "$prev" ]]; then
    RANGES+=("$start")
  else
    RANGES+=("${start}-${prev}")
  fi
  start="$cur"
  prev="$cur"
done
# finalize last
if [[ "$start" -eq "$prev" ]]; then
  RANGES+=("$start")
else
  RANGES+=("${start}-${prev}")
fi

echo "[plan] Will delete snapshots (ranges): ${RANGES[*]}"
echo

if [[ "$APPLY" -eq 0 ]]; then
  echo "[dry-run] Not applying. Re-run with --apply to delete."
  exit 0
fi

# Apply deletions
for r in "${RANGES[@]}"; do
  echo "[apply] snapper -c $CFG delete $r"
  snapper -c "$CFG" delete "$r"
done

echo
echo "[ok] Deletion completed."
echo "[note] Reboot to see GRUB snapshot menu shrink to the remaining default snapshot."
