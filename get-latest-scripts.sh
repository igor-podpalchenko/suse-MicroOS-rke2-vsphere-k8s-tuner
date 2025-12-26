#!/bin/bash

curl -s https://raw.githubusercontent.com/igor-podpalchenko/suse-MicroOS-rke2-vsphere-k8s-tuner/refs/heads/main/microos-rke2-template.sh > microos-rke2-template.sh
curl -s https://raw.githubusercontent.com/igor-podpalchenko/suse-MicroOS-rke2-vsphere-k8s-tuner/refs/heads/main/purge-ko-for-vsphere.sh > purge-ko-for-vsphere.sh
curl -s https://raw.githubusercontent.com/igor-podpalchenko/suse-MicroOS-rke2-vsphere-k8s-tuner/refs/heads/main/merge-snapshoots.sh > merge-snapshoots.sh
curl -s https://raw.githubusercontent.com/igor-podpalchenko/suse-MicroOS-rke2-vsphere-k8s-tuner/refs/heads/main/purge-packages-after-rke2-provisioned.sh > purge-packages-after-rke2-provisioned.sh

chmod 755 *.sh
