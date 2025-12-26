#!/usr/bin/env bash
set -euo pipefail

APPLY=0
ADMIN_MNT="/run/btrfs-admin"

while (($#)); do
  case "$1" in
    --apply) APPLY=1 ;;
    --admin-mnt) ADMIN_MNT="${2:-}"; shift ;;
    -h|--help)
      cat <<EOF
Usage:
  sudo $0 [--apply] [--admin-mnt /run/btrfs-admin]

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
for cmd in btrfs findmnt awk sed sort mount umount ls rm; do
  have "$cmd" || { echo "Missing required command: $cmd" >&2; exit 1; }
done

snapnum_from_path() {
  local p="$1"
  if [[ "$p" =~ \.snapshots/([0-9]+)/snapshot ]]; then
    echo "${BASH_REMATCH[1]}"
    return 0
  fi
  return 1
}

set_ro_false() {
  local path="$1"
  btrfs property set -ts "$path" ro false >/dev/null 2>&1 || true
  btrfs property set -t s  "$path" ro false >/dev/null 2>&1 || true
  btrfs property set       "$path" ro false >/dev/null 2>&1 || true
}

list_child_subvol_relpaths() {
  local parent_abs="$1"
  # Children of a given subvolume (direct only). Paths are relative to the filesystem root (our ADMIN_MNT).
  btrfs subvolume list -o "$parent_abs" 2>/dev/null | awk '
    {
      pos=index($0," path ");
      if (pos>0) print substr($0,pos+6);
    }'
}

# TRUE recursive deletion:
#  - delete children first (and their children, etc.)
#  - then delete the parent
delete_subvol_recursive() {
  local abs="$1"

  # Find direct children and recurse into them first (deepest-first)
  mapfile -t children_rel < <(list_child_subvol_relpaths "$abs" | awk 'NF')
  if [[ "${#children_rel[@]}" -gt 0 ]]; then
    # Sort by path length descending so deeper paths go first
    mapfile -t children_rel < <(
      printf "%s\n" "${children_rel[@]}" |
        awk '{print length($0) "\t" $0}' |
        sort -nr |
        cut -f2-
    )

    for rel in "${children_rel[@]}"; do
      local child_abs="$ADMIN_MNT/$rel"
      if btrfs subvolume show "$child_abs" >/dev/null 2>&1; then
        delete_subvol_recursive "$child_abs"
      fi
    done
  fi

  # Now delete this subvolume itself
  if findmnt -rn "$abs" >/dev/null 2>&1; then
    echo "[apply] umount -l $abs"
    umount -l "$abs" || true
  fi

  if btrfs subvolume show "$abs" >/dev/null 2>&1; then
    set_ro_false "$abs"
    echo "[apply] btrfs subvolume delete $abs"
    if ! btrfs subvolume delete "$abs"; then
      # If something raced/appeared, try one more time after re-listing children
      # (still best-effort; but usually this second pass resolves it)
      echo "[warn] delete failed, retrying after another child scan: $abs" >&2
      mapfile -t retry_children < <(list_child_subvol_relpaths "$abs" | awk 'NF')
      for rel in "${retry_children[@]}"; do
        local child_abs="$ADMIN_MNT/$rel"
        if btrfs subvolume show "$child_abs" >/dev/null 2>&1; then
          delete_subvol_recursive "$child_abs"
        fi
      done
      set_ro_false "$abs"
      btrfs subvolume delete "$abs" || true
    fi
  fi
}

ensure_admin_mount() {
  mkdir -p "$ADMIN_MNT"
  if findmnt -rn "$ADMIN_MNT" >/dev/null 2>&1; then
    return 0
  fi
  echo "[apply] mounting Btrfs top-level RW at $ADMIN_MNT"
  mount -t btrfs -o rw,subvolid=5 "$SRC_DEV" "$ADMIN_MNT"
}

cleanup_admin_mount() {
  if findmnt -rn "$ADMIN_MNT" >/dev/null 2>&1; then
    umount "$ADMIN_MNT" || true
  fi
}
trap cleanup_admin_mount EXIT

# ---- Discover current state ----
OPTS="$(findmnt -no OPTIONS / 2>/dev/null || true)"
SRC_RAW="$(findmnt -no SOURCE / 2>/dev/null || true)"

CURRENT_SUBVOL_PATH="$(tr ',' '\n' <<<"$OPTS" | sed -n 's/^subvol=//p' | head -n1 || true)"
CURRENT_SUBVOLID="$(tr ',' '\n' <<<"$OPTS" | sed -n 's/^subvolid=//p' | head -n1 || true)"
CURRENT_SNAPNUM="$(snapnum_from_path "${CURRENT_SUBVOL_PATH:-}" 2>/dev/null || true)"

if [[ -z "${CURRENT_SUBVOLID:-}" ]]; then
  norm="${CURRENT_SUBVOL_PATH#/}"
  if [[ -n "$norm" ]]; then
    CURRENT_SUBVOLID="$(btrfs subvolume list -a / 2>/dev/null | awk -v p="$norm" '
      { id=$2; pos=index($0," path "); if (pos>0) { path=substr($0,pos+6); if (path==p) { print id; exit } } }' || true)"
  fi
fi

if [[ -z "${CURRENT_SUBVOLID:-}" ]]; then
  echo "[ERR] Could not determine current root subvolume ID." >&2
  echo "      findmnt -no OPTIONS / -> $OPTS" >&2
  exit 1
fi

SRC_DEV="$SRC_RAW"
if [[ "$SRC_DEV" == *"["*"]"* ]]; then
  SRC_DEV="${SRC_DEV%%[*}"
fi
if [[ -z "${SRC_DEV:-}" ]]; then
  echo "[ERR] Could not determine device for / (got: $SRC_RAW)" >&2
  exit 1
fi

ROOT_PREFIX=""
if [[ "${CURRENT_SUBVOL_PATH:-}" =~ ^(.*)/\.snapshots/[0-9]+/snapshot$ ]]; then
  ROOT_PREFIX="${BASH_REMATCH[1]}"   # e.g. "/@"
fi
if [[ -z "${ROOT_PREFIX:-}" ]]; then
  echo "[ERR] Could not determine snapshots prefix from: $CURRENT_SUBVOL_PATH" >&2
  exit 1
fi

echo "[info] btrfs source raw    : $SRC_RAW"
echo "[info] btrfs source device : $SRC_DEV"
echo "[info] current root subvol : ${CURRENT_SUBVOL_PATH:-<unknown>}"
echo "[info] current snap number : ${CURRENT_SNAPNUM:-<not a /.snapshots/N boot>}"
echo "[info] current subvol id   : $CURRENT_SUBVOLID"
echo "[info] snapshots prefix    : $ROOT_PREFIX"
echo

# Plan: delete ALL numeric snapshot dirs except current snapshot number (and never touch 0)
SNAP_DIR="$ROOT_PREFIX/.snapshots"
KEEP_NUM="${CURRENT_SNAPNUM:-}"

if [[ -z "${KEEP_NUM}" ]]; then
  echo "[ERR] You are not booted from /.snapshots/N/snapshot; refusing to mass-delete snapshots." >&2
  echo "      current subvol: $CURRENT_SUBVOL_PATH" >&2
  exit 1
fi

# Build list of snapshot numbers present on disk (not just ones with snapshot/ subvol still present)
mapfile -t ALL_NUMS < <(
  ls -1 "/.snapshots" 2>/dev/null | awk '/^[0-9]+$/ {print $1}' | sort -n
)

DEL_NUMS=()
for n in "${ALL_NUMS[@]}"; do
  [[ "$n" == "0" ]] && continue
  [[ "$n" == "$KEEP_NUM" ]] && continue
  DEL_NUMS+=("$n")
done

echo "[plan] snapshot numbers to delete (disk): ${#DEL_NUMS[@]}"
[[ "${#DEL_NUMS[@]}" -gt 0 ]] && printf "  - %s\n" "${DEL_NUMS[@]}"
echo
echo "[plan] set btrfs default to current subvol id: $CURRENT_SUBVOLID (RW mount subvolid=5)"
echo

if [[ "$APPLY" -eq 0 ]]; then
  echo "[dry-run] Not applying. Re-run with --apply."
  exit 0
fi

ensure_admin_mount

echo "[apply] btrfs subvolume set-default $CURRENT_SUBVOLID $ADMIN_MNT"
btrfs subvolume set-default "$CURRENT_SUBVOLID" "$ADMIN_MNT"

# Delete snapshot subvolumes + remove their metadata directories
for n in "${DEL_NUMS[@]}"; do
  snap_abs="$ADMIN_MNT$ROOT_PREFIX/.snapshots/$n/snapshot"

  if [[ -d "$snap_abs" ]] && btrfs subvolume show "$snap_abs" >/dev/null 2>&1; then
    delete_subvol_recursive "$snap_abs"
  fi

  # Remove the remaining metadata dir (files), even if snapshot subvol already gone
  meta_abs="$ADMIN_MNT$ROOT_PREFIX/.snapshots/$n"
  if [[ -d "$meta_abs" ]]; then
    echo "[apply] rm -rf $meta_abs"
    rm -rf "$meta_abs" || true
  fi
done

echo
echo "[verify] remaining entries under $ADMIN_MNT$ROOT_PREFIX/.snapshots:"
ls -la "$ADMIN_MNT$ROOT_PREFIX/.snapshots" || true

echo
echo "[ok] Done."
echo "[next] Reboot."
echo "[note] GRUB list may still show old entries until grub.cfg is regenerated."
