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

# -------------------------
# GRUB patching (MicroOS-safe)
# -------------------------

patch_grub_defaults() {
  local grub_def="/etc/default/grub"
  [[ -f "$grub_def" ]] || { log "GRUB defaults not found ($grub_def); skipping GRUB patch"; return 0; }

  log "Patching /etc/default/grub: GRUB_TIMEOUT=5, GRUB_RECORDFAIL_TIMEOUT=5, add modprobe.blacklist=floppy"

  # Visible menu timeout
  if grep -q '^GRUB_TIMEOUT=' "$grub_def"; then
    sed -i 's/^GRUB_TIMEOUT=.*/GRUB_TIMEOUT=5/' "$grub_def"
  else
    echo 'GRUB_TIMEOUT=5' >> "$grub_def"
  fi

  # Recordfail timeout can override what you see on screen
  if grep -q '^GRUB_RECORDFAIL_TIMEOUT=' "$grub_def"; then
    sed -i 's/^GRUB_RECORDFAIL_TIMEOUT=.*/GRUB_RECORDFAIL_TIMEOUT=5/' "$grub_def"
  else
    echo 'GRUB_RECORDFAIL_TIMEOUT=5' >> "$grub_def"
  fi

  # Floppy suppression via kernel cmdline (bootloader-level; takes effect next boot)
  if grep -q '^GRUB_CMDLINE_LINUX_DEFAULT=' "$grub_def"; then
    if ! grep -q 'modprobe\.blacklist=floppy' "$grub_def"; then
      sed -i 's/^\(GRUB_CMDLINE_LINUX_DEFAULT="[^"]*\)"/\1 modprobe.blacklist=floppy"/' "$grub_def"
    fi
  elif grep -q '^GRUB_CMDLINE_LINUX=' "$grub_def"; then
    if ! grep -q 'modprobe\.blacklist=floppy' "$grub_def"; then
      sed -i 's/^\(GRUB_CMDLINE_LINUX="[^"]*\)"/\1 modprobe.blacklist=floppy"/' "$grub_def"
    fi
  else
    echo 'GRUB_CMDLINE_LINUX_DEFAULT="modprobe.blacklist=floppy"' >> "$grub_def"
  fi
}

regen_grub_cfg_transactional() {
  # On MicroOS, /boot is typically not writable from the running snapshot.
  # The supported, robust way is: transactional-update grub.cfg
  log "Regenerating GRUB config via transactional-update (MicroOS-safe)"

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
if ! systemctl list-unit-files --no-legend "${UNIT}" >/dev/null 2>&1; then
  # Not installed yet; try again on next timer tick.
  exit 0
fi

log "Detected installed ${UNIT}; disabling cloud-init and removing boot wiring"

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
# Stage1: packages (transactional)
# -------------------------

stage1_install_packages() {
  log "Stage1: transactional package install (will reboot afterwards)"

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

  # Patch GRUB (timeout + fd0 suppression) and regenerate config in a MicroOS-safe way
  patch_grub

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
  ln -sf /etc/machine-id /var/lib/dbus/machine-id

  sync
  shutdown -h now
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
