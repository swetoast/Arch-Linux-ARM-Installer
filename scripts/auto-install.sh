#!/usr/bin/env bash
set -euo pipefail

# Minimal prerequisites that your installer expects (lean set)
pacman -Sy --noconfirm --needed \
  arch-install-scripts dialog bsdtar curl gpg md5sum util-linux \
  e2fsprogs btrfs-progs xfsprogs iwd networkmanager openssh avahi nss-mdns

# Pick one network stack (your installer lets you choose later anyway)
systemctl enable systemd-networkd systemd-resolved || true
# Or choose NetworkManager:
# systemctl enable NetworkManager || true

ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf || true

# Run your interactive# Run your interactive installer
bash /root/installer.sh
