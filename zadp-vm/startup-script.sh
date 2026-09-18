#!/bin/bash
set -euo pipefail
exec > >(logger -t zadp-startup -s 2>/dev/console) 2>&1

# Ops Agent: ZADP's memory/disk metrics come only from this. Non-fatal on purpose --
# a missing repo for a brand-new LTS must not stop the security updates below.
( curl -sSO https://dl.google.com/cloudagents/add-google-cloud-ops-agent-repo.sh \
  && sudo bash add-google-cloud-ops-agent-repo.sh --also-install ) \
  || echo "Ops Agent install failed; continuing without it" >&2

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y unattended-upgrades needrestart git
dpkg-reconfigure -f noninteractive unattended-upgrades
systemctl enable --now unattended-upgrades

# 2G swap: Discourse's asset build is memory-hungry and its own docs require swap
# on anything under 4G of RAM.
if [ ! -f /swapfile ]; then
  fallocate -l 2G /swapfile
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  echo '/swapfile none swap sw 0 0' >> /etc/fstab
  sysctl -w vm.swappiness=10
  echo 'vm.swappiness=10' > /etc/sysctl.d/99-swappiness.conf
fi

echo "zadp-startup: complete"
