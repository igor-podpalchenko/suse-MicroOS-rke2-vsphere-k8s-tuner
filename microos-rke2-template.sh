#!/usr/bin/env bash
set -euo pipefail

# microos-rke2-template.sh
# Prepare openSUSE MicroOS VMware image for Rancher (RKE2) provisioning on vSphere
#
# Usage:
#   sudo bash microos-rke2-template.sh --stage1
#   # VM reboots automatically
#   sudo bash microos-rke2-template.sh --post
#
# Optional:
#   sudo bash microos-rke2-template.sh --install-rke2   (install RKE2 binaries via get.rke2.io)
#   sudo bash microos-rke2-template.sh --finalize       (cloud-init clean + machine-id reset + shutdown)
#
# Notes:
# - Uses transactional-update (MicroOS) for package installs, then reboots.
# - Forces cloud-init to run full pipeline and prefer NoCloud (Rancher config-drive).
# - Disables Combustion (Ignition-like first boot).
# - Avoids enabling/starting rke2-server in template (Rancher will do that).
# - Suppresses fd0 noise via GRUB kernel cmdline (takes effect after reboot into snapshot).
# - Patches GRUB timeout from 10s to 5s (also patches recordfail timeout which can override visible countdown).
# - Adds a boot-time systemd *timer* that disables cloud-init after rancher-system-agent is installed.

log() { echo "[$(date -Is)] $*"; }

need_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "Run as root (sudo)." >&2
    exit 1
  fi
}

tu() {
  if [[ -x /usr/sbin/transactional-update ]]; then
    /usr/sbin/transactional-update "$@"
  else
    transactional-update "$@"
  fi
}

SNAPPER_CMD=(snapper)

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

parse_snapper_csv_line() {
  # snapper --csvout list is comma-separated. Extract fields we care about:
  # number, pre-number, date, userdata.
  local line="$1"
  local number_var="$2" pre_var="$3" date_var="$4" userdata_var="$5" active_var="${6:-}"
  local -n number_ref="$number_var"
  local -n pre_ref="$pre_var"
  local -n date_ref="$date_var"
  local -n userdata_ref="$userdata_var"

  if [[ -n "$active_var" ]]; then
    local -n active_ref="$active_var"
    active_ref=""
  fi

  number_ref=""
  pre_ref=""
  date_ref=""
  userdata_ref=""

  # snapper --csvout currently uses ';' as separator, but fall back to ',' if seen.
  local delim=';'
  if [[ "$line" != *";"* && "$line" == *,* ]]; then
    delim=','
  fi

  IFS="$delim" read -r _config _subvol _number _default _active _type _pre _date _user _used _cleanup _desc _userdata <<<"$line"
  number_ref="${_number//[[:space:]]/}"
  pre_ref="${_pre//[[:space:]]/}"
  date_ref="${_date:-}"
  userdata_ref="${_userdata:-}"
  if [[ -n "$active_var" ]]; then
    active_ref="${_active:-}"
  fi
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
  local -a before_numbers=()
  local parent_snapshot_id=""
  for line in "${before_ref[@]}"; do
    local id pre date userdata active
    parse_snapper_csv_line "$line" id pre date userdata active
    [[ -z "$id" ]] && continue
    before_set["$id"]=1
    before_dates["$id"]="$date"
    before_numbers+=("$id")

    if [[ -z "$parent_snapshot_id" ]]; then
      case "${active,,}" in
        yes|true|current|\*|+)
          parent_snapshot_id="$id"
          ;;
      esac
    fi
  done

  if [[ -z "$parent_snapshot_id" && ${#before_numbers[@]} -gt 0 ]]; then
    parent_snapshot_id="$(printf '%s\n' "${before_numbers[@]}" | sort -nr | head -n1)"
  fi

  local -a after_lines=()
  mapfile -t after_lines < <("${SNAPPER_CMD[@]}" --csvout list 2>/dev/null | awk 'NR>1')
  local -A after_pre after_date after_userdata
  for line in "${after_lines[@]}"; do
    local id pre date userdata
    parse_snapper_csv_line "$line" id pre date userdata
    [[ -z "$id" ]] && continue
    after_pre["$id"]="$pre"
    after_date["$id"]="$date"
    after_userdata["$id"]="$userdata"
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
    if [[ -n "$parent_snapshot_id" ]]; then
      userdata_fields+=("parent=${parent_snapshot_id}")
    fi
    if [[ -n "$parent" && "$parent" != "-" && "$parent" != "0" ]]; then
      userdata_fields+=("parent_id=${parent}")
      if [[ -n "$parent_date" ]]; then
        userdata_fields+=("parent_date=${parent_date// /T}")
      fi
    fi
    local combined_userdata
    combined_userdata="$(printf '%s ' "${userdata_fields[@]}" | sed 's/[[:space:]]*$//')"

    if [[ -n "$combined_userdata" ]]; then
      log "snapper modify --description \"${desc}\" --userdata \"${combined_userdata}\" ${id}"
      "${SNAPPER_CMD[@]}" modify --description "$desc" --userdata "$combined_userdata" "$id" || true
    else
      log "snapper modify --description \"${desc}\" ${id}"
      "${SNAPPER_CMD[@]}" modify --description "$desc" "$id" || true
    fi
  done
}

ensure_grub_cmdline_args() {
  local grub_def="/etc/default/grub"
  local args=("$@")
  local target_var=""

  for var in GRUB_CMDLINE_LINUX_DEFAULT GRUB_CMDLINE_LINUX; do
    if grep -q "^${var}=" "$grub_def"; then
      target_var="$var"
      break
    fi
  done

  if [[ -z "$target_var" ]]; then
    target_var="GRUB_CMDLINE_LINUX_DEFAULT"
    echo "${target_var}=\"${args[*]}\"" >> "$grub_def"
    return
  fi

  local current
  current=$(grep -E "^${target_var}=" "$grub_def" | head -n1 | sed -E "s/^${target_var}=\"(.*)\"/\\1/")

  for arg in "${args[@]}"; do
    if [[ " ${current} " != *" ${arg} "* ]]; then
      current="${current} ${arg}"
    fi
  done

  current="$(echo "${current}" | xargs)"

  local tmp
  tmp="$(mktemp)"
  while IFS= read -r line; do
    if [[ "$line" == ${target_var}=* ]]; then
      echo "${target_var}=\"${current}\"" >> "$tmp"
    else
      echo "$line" >> "$tmp"
    fi
  done < "$grub_def"

  cat "$tmp" > "$grub_def"
  rm -f "$tmp"
}

# -------------------------
# Path helpers
# -------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# -------------------------
# GRUB patching (MicroOS-safe)
# -------------------------

patch_grub_defaults() {
  local grub_def="/etc/default/grub"
  [[ -f "$grub_def" ]] || { log "GRUB defaults not found ($grub_def); skipping GRUB patch"; return 0; }

  log "Patching /etc/default/grub: GRUB_TIMEOUT=3, GRUB_RECORDFAIL_TIMEOUT=3, add modprobe.blacklist=floppy, SELinux permissive kernel args"

  # Visible menu timeout
  if grep -q '^GRUB_TIMEOUT=' "$grub_def"; then
    sed -i 's/^GRUB_TIMEOUT=.*/GRUB_TIMEOUT=3/' "$grub_def"
  else
    echo 'GRUB_TIMEOUT=3' >> "$grub_def"
  fi

  # Recordfail timeout can override what you see on screen
  if grep -q '^GRUB_RECORDFAIL_TIMEOUT=' "$grub_def"; then
    sed -i 's/^GRUB_RECORDFAIL_TIMEOUT=.*/GRUB_RECORDFAIL_TIMEOUT=3/' "$grub_def"
  else
    echo 'GRUB_RECORDFAIL_TIMEOUT=3' >> "$grub_def"
  fi

  # Kernel args (merged into existing GRUB_CMDLINE_* if present)
  ensure_grub_cmdline_args \
    modprobe.blacklist=floppy \
    security=selinux selinux=1 enforcing=0
}

regen_grub_cfg_transactional() {
  # On MicroOS, /boot is typically not writable from the running snapshot.
  # The supported, robust way is: transactional-update grub.cfg
  log "Regenerating GRUB config via transactional-update (MicroOS-safe)"

  local SNAP_BEFORE=()
  local SNAPPER_TRACKING=0
  if snapper_capture_state SNAP_BEFORE; then
    SNAPPER_TRACKING=1
  fi

  # Prefer the dedicated helper if available (it is on MicroOS / Leap Micro / SLE Micro).
  # This runs grub2-mkconfig in the proper context and updates /boot/grub2/grub.cfg.
  if transactional-update --help 2>/dev/null | grep -q 'grub\.cfg'; then
    tu grub.cfg
  else
    # Fallback: run grub2-mkconfig inside a new snapshot via 'run' (NOT 'shell').
    # Still may fail on some layouts if /boot is forced ro, but this is the best generic fallback.
    log "transactional-update grub.cfg not found; falling back to transactional-update run grub2-mkconfig"
    tu run bash -lc '
      set -euo pipefail
      mkdir -p /boot/grub2
      grub2-mkconfig -o /boot/grub2/grub.cfg
      if [ -d /sys/firmware/efi ] && [ -d /boot/efi ]; then
        mkdir -p /boot/efi/EFI/opensuse /boot/efi/EFI/BOOT
        grub2-mkconfig -o /boot/efi/EFI/opensuse/grub.cfg 2>/dev/null || true
        grub2-mkconfig -o /boot/efi/EFI/BOOT/grub.cfg 2>/dev/null || true
      fi
    '
  fi

  if (( SNAPPER_TRACKING == 1 )); then
    annotate_snapper_diff "microos-rke2-template grub.cfg regeneration" SNAP_BEFORE
  fi

  log "GRUB config regeneration done."
  log "IMPORTANT: reboot before running any further transactional-update commands, or grub.cfg may get overwritten."
}

patch_grub() {
  patch_grub_defaults
  regen_grub_cfg_transactional
}

# -------------------------
# Cloud-init auto-disable after Rancher agent is installed
# -------------------------

install_cloudinit_autodisable_timer() {
  log "Installing cloud-init auto-disable timer (disables cloud-init once rancher-system-agent is installed)"

  mkdir -p /usr/local/sbin

  cat > /usr/local/sbin/cloud-init-disable-if-rancher-agent.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

log() { echo "[cloud-init-disable] $*" >&2; }

# If already disabled, stop doing work (and stop the timer if it exists)
if [[ -f /etc/cloud/cloud-init.disabled ]]; then
  systemctl disable --now cloud-init-disable-if-rancher-agent.timer 2>/dev/null || true
  systemctl disable --now cloud-init-disable-if-rancher-agent.service 2>/dev/null || true
  exit 0
fi

# We act once the Rancher system-agent is INSTALLED (unit file exists).
# (It might not be active yet when first installed.)
UNIT="rancher-system-agent.service"
PURGE_SCRIPT="/usr/local/sbin/purge-packages-after-rke2-provisioned.sh"
if ! systemctl list-unit-files --no-legend "${UNIT}" >/dev/null 2>&1; then
  # Not installed yet; try again on next timer tick.
  exit 0
fi

log "Detected installed ${UNIT}; running post-provision cleanup then disabling cloud-init"

if [[ -x "${PURGE_SCRIPT}" ]]; then
  log "Invoking ${PURGE_SCRIPT} --apply (best-effort)"
  if ! "${PURGE_SCRIPT}" --apply; then
    log "[WARN] ${PURGE_SCRIPT} failed (continuing to disable cloud-init)"
  fi
else
  log "[WARN] Purge script not found/executable at ${PURGE_SCRIPT}; skipping package cleanup"
fi

# Standard kill switch
mkdir -p /etc/cloud
touch /etc/cloud/cloud-init.disabled

# Remove our boot wiring symlinks so cloud-init won't be forced next boot
rm -f /etc/systemd/system/multi-user.target.wants/cloud-init.target || true
rm -f /etc/systemd/system/cloud-init.target.wants/cloud-init-local.service \
      /etc/systemd/system/cloud-init.target.wants/cloud-init-main.service \
      /etc/systemd/system/cloud-init.target.wants/cloud-init-network.service \
      /etc/systemd/system/cloud-init.target.wants/cloud-config.service \
      /etc/systemd/system/cloud-init.target.wants/cloud-final.service \
      /etc/systemd/system/cloud-init.target.wants/cloud-init.service 2>/dev/null || true

systemctl daemon-reload || true

# Optional: stop current boot cloud-init stages (best-effort)
systemctl stop cloud-final cloud-config cloud-init-network cloud-init-main cloud-init-local cloud-init 2>/dev/null || true

# Disable the timer+service so we run once total
systemctl disable --now cloud-init-disable-if-rancher-agent.timer 2>/dev/null || true
systemctl disable --now cloud-init-disable-if-rancher-agent.service 2>/dev/null || true

log "Done"
EOF

  chmod 0755 /usr/local/sbin/cloud-init-disable-if-rancher-agent.sh

  cat > /etc/systemd/system/cloud-init-disable-if-rancher-agent.service <<'EOF'
[Unit]
Description=Disable cloud-init after Rancher system-agent is installed
After=multi-user.target
Wants=multi-user.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/cloud-init-disable-if-rancher-agent.sh
EOF

  cat > /etc/systemd/system/cloud-init-disable-if-rancher-agent.timer <<'EOF'
[Unit]
Description=Periodically disable cloud-init after Rancher system-agent is installed

[Timer]
# Start checking shortly after boot
OnBootSec=30
# Retry every 30s until success disables this timer
OnUnitActiveSec=30
Unit=cloud-init-disable-if-rancher-agent.service

[Install]
WantedBy=timers.target
EOF

  systemctl daemon-reload
  systemctl enable --now cloud-init-disable-if-rancher-agent.timer
}

# -------------------------
# Post-provision purge script install
# -------------------------

install_post_rancher_purge_script() {
  local src="${SCRIPT_DIR}/purge-packages-after-rke2-provisioned.sh"
  local dst="/usr/local/sbin/purge-packages-after-rke2-provisioned.sh"

  if [[ ! -f "$src" ]]; then
    log "Missing purge script at ${src}; required for post-provision cleanup."
    exit 1
  fi

  install -m 0755 "$src" "$dst"
  log "Installed purge-packages-after-rke2-provisioned.sh to ${dst}"
}

# -------------------------
# Stage1: packages (transactional)
# -------------------------

stage1_install_packages() {
  log "Stage1: transactional package install (will reboot afterwards)"

  local SNAP_BEFORE=()
  local SNAPPER_TRACKING=0
  if snapper_capture_state SNAP_BEFORE; then
    SNAPPER_TRACKING=1
  fi

  tu -n pkg install \
    cloud-init \
    open-vm-tools \
    open-iscsi \
    nfs-client \
    curl wget ca-certificates \
    openssh \
    containerd \
    apparmor-parser \
    net-tools-deprecated \
    xorriso

  if (( SNAPPER_TRACKING == 1 )); then
    annotate_snapper_diff "microos-rke2-template stage1 package install" SNAP_BEFORE
  fi

  log "Stage1 done. Rebooting to activate snapshot."
  log "Call reboot when ready."
  #reboot
}

# -------------------------
# Post: config + wiring
# -------------------------

post_config() {
  log "Post: enable services, disable combustion/ignition, configure rke2 sysctl/modules, cloud-init wiring, GRUB patch, install auto-disable timer"

  # Enable essentials
  systemctl enable --now sshd || true
  systemctl enable --now vmtoolsd || true
  systemctl enable --now vgauthd || true
  systemctl enable --now iscsid || systemctl enable --now iscsid.service || true

  # Disable Combustion + ignition units if present
  systemctl disable --now combustion 2>/dev/null || true
  systemctl mask combustion 2>/dev/null || true
  systemctl disable --now ignition-firstboot-complete.service ignition-disks.service ignition-fetch.service ignition-mount.service ignition.service 2>/dev/null || true
  systemctl mask ignition-firstboot-complete.service ignition-disks.service ignition-fetch.service ignition-mount.service ignition.service 2>/dev/null || true
  rm -rf /var/lib/combustion /etc/combustion /oem 2>/dev/null || true

  # RKE2 baseline kernel modules
  cat > /etc/modules-load.d/rke2.conf <<'EOF'
overlay
br_netfilter
EOF
  modprobe overlay br_netfilter || true

  # RKE2 baseline sysctl
  cat > /etc/sysctl.d/90-rke2.conf <<'EOF'
net.ipv4.ip_forward=1
net.bridge.bridge-nf-call-iptables=1
EOF
  sysctl --system || true

  # crictl config (optional but handy)
  cat > /etc/crictl.yaml <<'EOF'
runtime-endpoint: unix:///run/rke2/containerd/containerd.sock
image-endpoint: unix:///run/rke2/containerd/containerd.sock
timeout: 10
debug: false
EOF

  # Cloud-init: force enable + prefer NoCloud
  rm -f /etc/cloud/cloud-init.disabled
  cat > /etc/cloud/ds-identify.cfg <<'EOF'
policy: enabled
EOF
  mkdir -p /etc/cloud/cloud.cfg.d
  cat > /etc/cloud/cloud.cfg.d/90-datasource.cfg <<'EOF'
datasource_list: [ NoCloud, VMware, None ]
EOF

  # Wire full cloud-init pipeline (MicroOS units are mostly "static")
  mkdir -p /etc/systemd/system/multi-user.target.wants
  ln -sf /usr/lib/systemd/system/cloud-init.target \
    /etc/systemd/system/multi-user.target.wants/cloud-init.target

  mkdir -p /etc/systemd/system/cloud-init.target.wants
  for u in \
    cloud-init-local.service \
    cloud-init-main.service \
    cloud-init-network.service \
    cloud-config.service \
    cloud-final.service \
    cloud-init.service
  do
    if [[ -f "/usr/lib/systemd/system/$u" ]]; then
      ln -sf "/usr/lib/systemd/system/$u" "/etc/systemd/system/cloud-init.target.wants/$u"
    fi
  done
  systemctl daemon-reload

  # Persist /etc/rancher on /var/persist
  mkdir -p /var/persist/etc/rancher
  if [[ -d /etc/rancher && ! -L /etc/rancher ]]; then
    cp -a /etc/rancher/. /var/persist/etc/rancher/ 2>/dev/null || true
    rm -rf /etc/rancher
  fi
  ln -sfn /var/persist/etc/rancher /etc/rancher

  # Patch GRUB (timeout + fd0 suppression) and regenerate config in a MicroOS-safe way
  patch_grub

  # Install the purge script used post-Rancher provisioning (timer hook)
  install_post_rancher_purge_script

  # Install timer to disable cloud-init once rancher-system-agent is installed
  install_cloudinit_autodisable_timer

  log "Post done."
  log "GRUB changes are written now, but reboot soon (and before any further transactional-update runs)."
  log "cloud-init will be disabled automatically after Rancher installs rancher-system-agent (timer checks every 30s)."
}

# -------------------------
# Optional: preinstall rke2 binaries
# -------------------------

install_rke2_binaries() {
  log "Installing RKE2 binaries via official installer (does NOT enable/start service)"
  curl -sfL https://get.rke2.io | sh -
  ls -l /usr/local/bin/rke2 /opt/rke2/bin/rke2 2>/dev/null || true
}

# -------------------------
# Finalize: template cleanup
# -------------------------

finalize_for_template() {
  log "Finalizing for template: cloud-init clean + machine-id reset + shutdown"

  systemctl stop cloud-init cloud-init-local cloud-config cloud-final 2>/dev/null || true

  cloud-init clean --logs --seed || true
  rm -rf /var/lib/cloud/instances /var/lib/cloud/instance

  truncate -s 0 /etc/machine-id
  rm -f /var/lib/dbus/machine-id
  rm -f /var/lib/systemd/random-seed
  ln -sf /etc/machine-id /var/lib/dbus/machine-id

  sync
  echo "( ./merge-snapshoots.sh --apply ) shutdown -h now "
}

usage() {
  cat <<'EOF'
Usage:
  sudo bash microos-rke2-template.sh --stage1
  # reboots automatically
  sudo bash microos-rke2-template.sh --post

Optional:
  sudo bash microos-rke2-template.sh --install-rke2
  sudo bash microos-rke2-template.sh --finalize
EOF
}

main() {
  need_root

  if [[ $# -lt 1 ]]; then
    usage
    exit 2
  fi

  case "$1" in
    --stage1)       stage1_install_packages ;;
    --post)         post_config ;;
    --install-rke2) install_rke2_binaries ;;
    --finalize)     finalize_for_template ;;
    *)              usage; exit 2 ;;
  esac
}

main "$@"
