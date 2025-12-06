#!/usr/bin/env bash
set -euo pipefail

# Minimal prerequisites your installer expects
pacman -Sy --noconfirm --needed \
  arch-install-scripts dialog bsdtar curl md5sum util-linux \
  e2fsprogs btrfs-progs xfsprogs iwd networkmanager openssh avahi nss-mdns

# Bring up networking (lean default)
systemctl enable systemd-networkdsystemctl enable systemd-networkd systemd-resolved || true
ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf || true
# Or choose NetworkManager (uncomment if preferred)
# systemctl enable NetworkManager || true

# Run your interactive installer
bash /root/installer.sh

# Prevent re-run on next boot
