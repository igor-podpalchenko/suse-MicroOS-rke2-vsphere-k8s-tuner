#!/usr/bin/env bash
set -euo pipefail

# merge-snapshoots.sh
#
# Goal:
#   Discard all snapshots except the CURRENT running system state,
#   so after reboot GRUB shows only a single "Snapshot Update ..." entry.
#
# What it does (in --apply):
#   1) Detect CURRENT root subvolume and set it as Btrfs default (next boot = same state)
#   2) Delete all Snapper snapshots except CURRENT (if current is a snapshot) or delete all snapshots (if not)
#   3) Delete orphaned /.snapshots/<N>/snapshot subvolumes not known to snapper (if any)
#   4) Regenerate /boot/grub2/grub.cfg (best-effort; tries to remount /boot rw)
#
# Usage:
#   sudo ./merge-snapshoots.sh           # dry-run
#   sudo ./merge-snapshoots.sh --apply   # apply deletions
#
# Notes:
# - This is intentionally aggressive: it removes rollback history.

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

for cmd in snapper btrfs findmnt awk sed sort; do
  if ! have "$cmd"; then
    echo "Missing required command: $cmd" >&2
    exit 1
  fi
done

# Extract N from paths like /.snapshots/N/snapshot
snapnum_from_path() {
  local p="$1"
  if [[ "$p" =~ \.snapshots/([0-9]+)/snapshot ]]; then
    echo "${BASH_REMATCH[1]}"
    return 0
  fi
  return 1
}

# Current root subvol path (from mount options) and ID (from btrfs subvolume show)
CURRENT_SUBVOL_PATH=""
CURRENT_SNAPNUM=""
CURRENT_SUBVOL_ID=""

opts="$(findmnt -no OPTIONS / || true)"
subvol="$(tr ',' '\n' <<<"$opts" | sed -n 's/^subvol=//p' | head -n1 || true)"
CURRENT_SUBVOL_PATH="${subvol:-}"

if [[ -n "$CURRENT_SUBVOL_PATH" ]]; then
  CURRENT_SNAPNUM="$(snapnum_from_path "$CURRENT_SUBVOL_PATH" 2>/dev/null || true)"
fi

# Get current root subvolume ID (works regardless of being snapshot/base)
# btrfs subvolume show / output includes: "Subvolume ID: <id>"
CURRENT_SUBVOL_ID="$(btrfs subvolume show / 2>/dev/null | awk -F': ' '/^Subvolume ID:/{print $2; exit}' || true)"
if [[ -z "$CURRENT_SUBVOL_ID" ]]; then
  echo "[ERR] Could not determine current root subvolume ID (btrfs subvolume show /)." >&2
  exit 1
fi

echo "[info] snapper config      : $CFG"
echo "[info] current root subvol : ${CURRENT_SUBVOL_PATH:-<unknown>}"
echo "[info] current snap number : ${CURRENT_SNAPNUM:-<not a /.snapshots/N boot>}"
echo "[info] current subvol id   : $CURRENT_SUBVOL_ID"
echo

# In your desired workflow, CURRENT is what must remain.
# So keep-set is ONLY current snapshot number (if it exists).
declare -A KEEP=()
if [[ -n "${CURRENT_SNAPNUM:-}" ]]; then
  KEEP["$CURRENT_SNAPNUM"]=1
fi

# Collect snapper snapshot numbers
mapfile -t ALL_SNAPS < <(snapper -c "$CFG" list --no-headers --columns number 2>/dev/null | awk '{print $1}' || true)
if [[ "${#ALL_SNAPS[@]}" -eq 0 ]]; then
  mapfile -t ALL_SNAPS < <(snapper -c "$CFG" list --no-headers 2>/dev/null | awk '{print $1}' || true)
fi

DEL_SNAPS=()
for n in "${ALL_SNAPS[@]}"; do
  [[ "$n" =~ ^[0-9]+$ ]] || continue
  [[ "$n" -eq 0 ]] && continue
  if [[ -z "${KEEP[$n]+x}" ]]; then
    DEL_SNAPS+=("$n")
  fi
done

# Also find orphaned snapshot subvols under /.snapshots that snapper may not list
ORPHAN_SUBVOLS=()
shopt -s nullglob
for d in /.snapshots/[0-9]*/snapshot; do
  n="$(awk -F'/' '{print $(NF-1)}' <<<"$d")"
  [[ "$n" =~ ^[0-9]+$ ]] || continue
  if [[ -n "${KEEP[$n]+x}" ]]; then
    continue
  fi
  # If snapper lists it, it will be handled by snapper delete; if not, we treat as orphan too
  ORPHAN_SUBVOLS+=("$n")
done
shopt -u nullglob

# De-dup orphan list
if [[ "${#ORPHAN_SUBVOLS[@]}" -gt 0 ]]; then
  mapfile -t ORPHAN_SUBVOLS < <(printf "%s\n" "${ORPHAN_SUBVOLS[@]}" | sort -n | awk '!seen[$0]++')
fi

echo "[plan] snapper snapshots to delete : ${#DEL_SNAPS[@]}"
if [[ "${#DEL_SNAPS[@]}" -gt 0 ]]; then
  printf "  - %s\n" "${DEL_SNAPS[@]}" | head -n 50
  [[ "${#DEL_SNAPS[@]}" -gt 50 ]] && echo "  ... (truncated)"
fi
echo

echo "[plan] orphan snapshot subvols to delete (by number): ${#ORPHAN_SUBVOLS[@]}"
if [[ "${#ORPHAN_SUBVOLS[@]}" -gt 0 ]]; then
  printf "  - %s\n" "${ORPHAN_SUBVOLS[@]}" | head -n 50
  [[ "${#ORPHAN_SUBVOLS[@]}" -gt 50 ]] && echo "  ... (truncated)"
fi
echo

echo "[plan] set btrfs default to current subvol id: $CURRENT_SUBVOL_ID"
echo

if [[ "$APPLY" -eq 0 ]]; then
  echo "[dry-run] Not applying. Re-run with --apply."
  exit 0
fi

# 1) Make current state persist across reboot
echo "[apply] btrfs subvolume set-default $CURRENT_SUBVOL_ID /"
btrfs subvolume set-default "$CURRENT_SUBVOL_ID" /

# 2) Delete snapper snapshots (except current)
if [[ "${#DEL_SNAPS[@]}" -gt 0 ]]; then
  # Delete in ascending order, individually (simple + reliable)
  mapfile -t DEL_SNAPS < <(printf "%s\n" "${DEL_SNAPS[@]}" | sort -n)
  for n in "${DEL_SNAPS[@]}"; do
    echo "[apply] snapper -c $CFG delete $n"
    snapper -c "$CFG" delete "$n" || true
  done
else
  echo "[apply] no snapper snapshots to delete"
fi

# 3) Delete orphaned btrfs snapshot subvolumes not removed by snapper (if any)
if [[ "${#ORPHAN_SUBVOLS[@]}" -gt 0 ]]; then
  for n in "${ORPHAN_SUBVOLS[@]}"; do
    p="/.snapshots/$n/snapshot"
    if [[ -d "$p" ]]; then
      # If mounted, try lazy unmount
      if findmnt -rn "$p" >/dev/null 2>&1; then
        echo "[apply] umount -l $p"
        umount -l "$p" || true
      fi
      # Delete subvolume if it is one
      if btrfs subvolume show "$p" >/dev/null 2>&1; then
        echo "[apply] btrfs subvolume delete $p"
        btrfs subvolume delete "$p" || true
      fi
      # Clean leftover metadata dirs (best-effort)
      rm -rf "/.snapshots/$n" 2>/dev/null || true
    fi
  done
else
  echo "[apply] no orphan subvolumes to delete"
fi

# 4) Regenerate grub.cfg so stale menu entries disappear (best-effort)
if have grub2-mkconfig; then
  echo
  echo "[apply] regenerating /boot/grub2/grub.cfg (best-effort)"
  BOOT_REMOUNTED=0
  if mountpoint -q /boot; then
    if mount -o remount,rw /boot 2>/dev/null; then
      BOOT_REMOUNTED=1
    fi
  fi

  if grub2-mkconfig -o /boot/grub2/grub.cfg 2>/dev/null; then
    echo "[apply] grub.cfg regenerated"
  else
    echo "[WARN] grub2-mkconfig failed (likely /boot is read-only on MicroOS)." >&2
    echo "       Workaround:" >&2
    echo "         sudo transactional-update -n run grub2-mkconfig -o /boot/grub2/grub.cfg" >&2
    echo "       Then run this script again (because TU creates a new snapshot)." >&2
  fi

  if [[ "$BOOT_REMOUNTED" -eq 1 ]]; then
    mount -o remount,ro /boot 2>/dev/null || true
  fi
else
  echo "[WARN] grub2-mkconfig not found; GRUB menu might remain stale until regenerated." >&2
fi

echo
echo "[ok] Done."
echo "[next] Reboot now. GRUB should show only the current state (single Snapshot Update entry)."
