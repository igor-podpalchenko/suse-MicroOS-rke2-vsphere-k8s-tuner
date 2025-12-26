# suse-MicroOS-rke2-vsphere-k8s-tuner

Toolkit to prepare openSUSE MicroOS as a slim Rancher/RKE2 node template for vSphere. The scripts focus on transactional-update friendly changes: trimming kernel drivers, pruning packages, wiring cloud-init for Rancher, and cleaning snapshots so the exported OVF stays small.

## Included scripts
- `get-latest-scripts.sh`: Fetch the latest versions of all helper scripts from `main` and mark them executable.
- `microos-rke2-template.sh`: Staged setup for the MicroOS VM (package install, post-configuration, optional RKE2 binary install, and final template cleanup). Installs a timer that disables cloud-init after Rancher lays down `rancher-system-agent`, invoking the post-provision package purge before turning cloud-init off.
- `purge-ko-for-vsphere.sh`: Transactional delete of unneeded kernel drivers for vSphere-hosted Kubernetes nodes.
- `purge-packages-after-rke2-provisioned.sh`: Transactional package cleanup that runs after Rancher provisioning (man pages, kdump tooling, ISO authoring stack, etc.).
- `merge-snapshoots.sh`: Removes older Btrfs snapshots to reclaim space.

## End-to-end workflow (template creation)
This is the expected flow for building a minimal vSphere template. All steps run inside the MicroOS VM unless noted.

1. **Initial boot / baseline setup**
   - Boot the VM, set the root password, and add your users.

2. **Pull the latest scripts**
   ```bash
   curl -s https://raw.githubusercontent.com/igor-podpalchenko/suse-MicroOS-rke2-vsphere-k8s-tuner/refs/heads/main/get-latest-scripts.sh > get-latest-scripts.sh
   chmod 755 get-latest-scripts.sh
   ./get-latest-scripts.sh
   ```

3. **Kernel driver pruning for vSphere**
   ```bash
   du -hs /lib/modules/6.18.2-1-default
   ./purge-ko-for-vsphere.sh --apply
   reboot
   ```

4. **Stage 1: install base components**
   ```bash
   du -hs /lib/modules/6.18.2-1-default
   ./microos-rke2-template.sh --stage1
   reboot
   ```

5. **Post configuration**
   ```bash
   ./microos-rke2-template.sh --post
   # enables services, patches GRUB, wires cloud-init for Rancher, and installs the auto-disable timer
   ./microos-rke2-template.sh --finalize
   # resets cloud-init state and shuts down; before shutdown you can run optional cleanup:
   ./merge-snapshoots.sh --apply
   ```

6. **Convert to template**
   - Power off the VM (shutdown occurs in `--finalize`) and convert it to a vSphere template, then export as an OVF if desired.

## Rancher provisioning lifecycle
- Rancher clones the template and boots the VM; cloud-init runs to completion using NoCloud/VMware datasources.
- A systemd timer installed during `--post` waits for `rancher-system-agent` to appear. Once detected, it runs `purge-packages-after-rke2-provisioned.sh --apply`, then disables cloud-init to prevent further re-runs.
- After Rancher configuration, you can optionally call `./merge-snapshoots.sh --apply` to collapse snapshots and keep the node footprint small.

## Notes and future intent
- The timer-driven cleanup is designed to run package pruning automatically; extending it to also perform driver purging (the `purge-ko-for-vsphere.sh` logic) inside the same post-Rancher snapshot is a desired enhancement to align runtime and driver trimming.
- All purge operations are transactional-update based; expect to reboot after each `--apply` so changes take effect.
