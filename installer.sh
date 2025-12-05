#!/bin/bash
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Run as root."
  exit 1
fi

HEIGHT=20
WIDTH=70
MENU_HEIGHT=10

SDMOUNT=/mnt/target
DOWNLOADDIR=/tmp/archarm
DISTURL="http://os.archlinuxarm.org/os/ArchLinuxARM-rpi-aarch64-latest.tar.gz"

SDDEV=""
SDPARTBOOT=""
SDPARTROOT=""
ROOTFS="ext4"
KERNEL_FLAVOR="linux-rpi"
HOSTNAME=""
USERNAME=""
USERPASS=""
ROOTPASS=""
LOCALE="en_US.UTF-8"
TIMEZONE="UTC"
NETWORKING="systemd-networkd"
WIFI_SSID=""
WIFI_PASS=""
WIFI_COUNTRY=""

cleanup_mounts() {
  umount -R "$SDMOUNT" 2>/dev/null || true
}
trap cleanup_mounts EXIT

ensure_prereqs() {
  for cmd in dialog lsblk sfdisk mkfs.vfat bsdtar curl arch-chroot blkid partprobe udevadm sed awk grep; do
    command -v "$cmd" >/dev/null || { echo "Missing $cmd"; exit 1; }
  done
  mkdir -p "$SDMOUNT" "$DOWNLOADDIR"
}

select_drive() {
  mapfile -t DEVICES < <(lsblk -dn -o NAME,SIZE,MODEL | awk '{print $1 " " $2 " " substr($0, index($0,$3))}')
  ((${#DEVICES[@]})) || { echo "No block devices found."; exit 1; }
  MENU_ITEMS=()
  for i in "${!DEVICES[@]}"; do
    MENU_ITEMS+=("$i" "${DEVICES[$i]}")
  done
  CHOICE=$(dialog --clear --stdout --menu "Select target drive" "$HEIGHT" "$WIDTH" "$MENU_HEIGHT" "${MENU_ITEMS[@]}") || exit 1
  SDDEV="/dev/$(echo "${DEVICES[$CHOICE]}" | awk '{print $1}')"
  if [[ "$SDDEV" =~ (mmcblk|nvme) ]]; then
    SDPARTBOOT="${SDDEV}p1"
    SDPARTROOT="${SDDEV}p2"
  else
    SDPARTBOOT="${SDDEV}1"
    SDPARTROOT="${SDDEV}2"
  fi
}

select_fs() {
  FS=$(dialog --clear --stdout --radiolist "Select filesystem for root partition" "$HEIGHT" "$WIDTH" "$MENU_HEIGHT" \
    1 "ext4" on \
    2 "btrfs" off \
    3 "xfs" off) || exit 1
  case "$FS" in
    1) ROOTFS="ext4" ;;
    2) ROOTFS="btrfs" ;;
    3) ROOTFS="xfs" ;;
  esac
}

select_kernel() {
  KF=$(dialog --clear --stdout --radiolist "Select kernel flavor" "$HEIGHT" "$WIDTH" "$MENU_HEIGHT" \
    1 "linux-rpi" on \
    2 "linux-rpi-16k" off) || exit 1
  case "$KF" in
    1) KERNEL_FLAVOR="linux-rpi" ;;
    2) KERNEL_FLAVOR="linux-rpi-16k" ;;
  esac
}

collect_system_info() {
  HOSTNAME=$(dialog --clear --stdout --inputbox "Enter hostname" "$HEIGHT" "$WIDTH" "rpi5") || exit 1
  USERNAME=$(dialog --clear --stdout --inputbox "Enter username" "$HEIGHT" "$WIDTH" "pi") || exit 1
  USERPASS=$(dialog --clear --stdout --passwordbox "Enter password for $USERNAME" "$HEIGHT" "$WIDTH") || exit 1
  ROOTPASS=$(dialog --clear --stdout --passwordbox "Enter root password" "$HEIGHT" "$WIDTH") || exit 1
  LOCALE=$(dialog --clear --stdout --inputbox "Enter locale (e.g. en_US.UTF-8 or sv_SE.UTF-8)" "$HEIGHT" "$WIDTH" "en_US.UTF-8") || exit 1
  TIMEZONE=$(dialog --clear --stdout --inputbox "Enter timezone (e.g. Europe/Stockholm)" "$HEIGHT" "$WIDTH" "Europe/Stockholm") || exit 1
  NETSEL=$(dialog --clear --stdout --radiolist "Select networking setup" "$HEIGHT" "$WIDTH" "$MENU_HEIGHT" \
    1 "systemd-networkd + resolved" on \
    2 "NetworkManager" off) || exit 1
  case "$NETSEL" in
    1) NETWORKING="systemd-networkd" ;;
    2) NETWORKING="NetworkManager" ;;
  esac
  if dialog --yesno "Configure Wi-Fi?" "$HEIGHT" "$WIDTH"; then
    WIFI_SSID=$(dialog --clear --stdout --inputbox "SSID" "$HEIGHT" "$WIDTH") || exit 1
    WIFI_PASS=$(dialog --clear --stdout --passwordbox "Password" "$HEIGHT" "$WIDTH") || exit 1
    WIFI_COUNTRY=$(dialog --clear --stdout --inputbox "Country code (e.g. SE, US)" "$HEIGHT" "$WIDTH" "SE") || exit 1
  fi
}

partition_format() {
  dialog --yesno "WARNING: This will WIPE $SDDEV. Continue?" "$HEIGHT" "$WIDTH" || exit 1
  wipefs -af "$SDDEV" || true
  sfdisk --quiet --wipe always "$SDDEV" << EOF
,256M,0c,
,,,
EOF
  partprobe "$SDDEV" || true
  udevadm settle || true
  mkfs.vfat -F 32 "$SDPARTBOOT"
  case "$ROOTFS" in
    ext4) mkfs.ext4 -F "$SDPARTROOT" ;;
    btrfs) mkfs.btrfs -f "$SDPARTROOT" ;;
    xfs) mkfs.xfs -f "$SDPARTROOT" ;;
  esac
}

install_rootfs() {
  cd "$DOWNLOADDIR"
  [[ -f "$(basename "$DISTURL")" ]] || curl -JLO "$DISTURL"
  mount "$SDPARTROOT" "$SDMOUNT"
  mkdir -p "$SDMOUNT/boot"
  mount "$SDPARTBOOT" "$SDMOUNT/boot"
  bsdtar -xpf "$DOWNLOADDIR/$(basename "$DISTURL")" -C "$SDMOUNT"
}

configure_fstab() {
  root_uuid=$(blkid -s UUID -o value "$SDPARTROOT")
  boot_uuid=$(blkid -s UUID -o value "$SDPARTBOOT")
  case "$ROOTFS" in
    ext4) root_type="ext4"; root_opts="defaults,noatime" ;;
    btrfs) root_type="btrfs"; root_opts="compress=zstd,ssd,noatime,space_cache=v2" ;;
    xfs) root_type="xfs"; root_opts="defaults,noatime" ;;
  esac
  cat > "$SDMOUNT/etc/fstab" <<EOT
UUID=$root_uuid  /      $root_type  $root_opts  0 1
UUID=$boot_uuid  /boot  vfat        defaults    0 2
EOT
}

configure_cmdline() {
  root_partuuid=$(blkid -s PARTUUID -o value "$SDPARTROOT")
  cat > "$SDMOUNT/boot/cmdline.txt" <<EOT
console=serial0,115200 console=tty1 root=PARTUUID=$root_partuuid rw rootwait fsck.repair=yes quiet splash systemd.unified_cgroup_hierarchy=1
EOT
}

replace_kernel() {
  mount --bind /dev  "$SDMOUNT/dev"
  mount --bind /proc "$SDMOUNT/proc"
  mount --bind /sys  "$SDMOUNT/sys"
  mount --bind /run  "$SDMOUNT/run"

  arch-chroot "$SDMOUNT" /bin/bash -c "
    set -euo pipefail
    pacman-key --init || true
    pacman-key --populate archlinuxarm || true
    pacman -Sy --noconfirm ${KERNEL_FLAVOR} ${KERNEL_FLAVOR}-headers linux-firmware
  "

  umount "$SDMOUNT/dev" "$SDMOUNT/proc" "$SDMOUNT/sys" "$SDMOUNT/run" || true
}

install_tools_chroot() {
  mount --bind /dev  "$SDMOUNT/dev"
  mount --bind /proc "$SDMOUNT/proc"
  mount --bind /sys  "$SDMOUNT/sys"
  mount --bind /run  "$SDMOUNT/run"

  cat > "$SDMOUNT/tmp/install-tools.sh" <<EOF
#!/bin/bash
set -euo pipefail
pacman -Sy --noconfirm sudo dosfstools wireless-regdb
if ! grep -q '^%wheel' /etc/sudoers; then
  echo '%wheel ALL=(ALL) ALL' >> /etc/sudoers
fi
case "$ROOTFS" in
  ext4)  pacman -Sy --noconfirm e2fsprogs ;;
  btrfs) pacman -Sy --noconfirm btrfs-progs ;;
  xfs)   pacman -Sy --noconfirm xfsprogs ;;
esac
EOF

  if [[ -n "$WIFI_SSID" ]]; then
    if [[ "$NETWORKING" == "systemd-networkd" ]]; then
      cat >> "$SDMOUNT/tmp/install-tools.sh" <<'EOF'
pacman -Sy --noconfirm iwd
EOF
    else
      cat >> "$SDMOUNT/tmp/install-tools.sh" <<'EOF'
pacman -Sy --noconfirm networkmanager iw
EOF
    fi
  fi

  chmod +x "$SDMOUNT/tmp/install-tools.sh"
  arch-chroot "$SDMOUNT" /tmp/install-tools.sh
  rm -f "$SDMOUNT/tmp/install-tools.sh"

  umount "$SDMOUNT/dev" "$SDMOUNT/proc" "$SDMOUNT/sys" "$SDMOUNT/run" || true
}

configure_system_chroot() {
  mount --bind /dev  "$SDMOUNT/dev"
  mount --bind /proc "$SDMOUNT/proc"
  mount --bind /sys  "$SDMOUNT/sys"
  mount --bind /run  "$SDMOUNT/run"

  sanitized_ssid=$(echo "$WIFI_SSID" | sed 's/[^A-Za-z0-9._-]/_/g' || true)

  cat > "$SDMOUNT/tmp/setup-system.sh" <<EOF
#!/bin/bash
set -euo pipefail

# Locale
sed -i '/^$LOCALE/d' /etc/locale.gen || true
echo "$LOCALE UTF-8" >> /etc/locale.gen
locale-gen
echo "LANG=$LOCALE" > /etc/locale.conf
echo "KEYMAP=us" > /etc/vconsole.conf

# Timezone and time sync
ln -sf /usr/share/zoneinfo/$TIMEZONE /etc/localtime
hwclock --systohc
systemctl enable systemd-timesyncd

# Hostname
echo "$HOSTNAME" > /etc/hostname

# User + passwords
if ! id "$USERNAME" >/dev/null 2>&1; then
  useradd -m -G wheel -s /bin/bash "$USERNAME"
fi
echo "$USERNAME:$USERPASS" | chpasswd
echo "root:$ROOTPASS" | chpasswd

# Networking
if [[ "$NETWORKING" == "systemd-networkd" ]]; then
  systemctl enable systemd-networkd systemd-resolved
  mkdir -p /etc/systemd/network
  cat > /etc/systemd/network/20-wired-dhcp.network <<NET
[Match]
Name=e*
[Network]
DHCP=yes
NET
  ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf || true

  if [[ -n "$WIFI_SSID" ]]; then
    systemctl enable iwd
    mkdir -p /etc/iwd
    cat > /etc/iwd/main.conf <<CONF
[General]
EnableNetworkConfiguration=true
RegulatoryDomain=$WIFI_COUNTRY
CONF
    cat > /etc/iwd/$sanitized_ssid.psk <<WIFI
[Security]
PreSharedKey=$WIFI_PASS
WIFI
    chmod 600 /etc/iwd/$sanitized_ssid.psk || true
  fi

else
  systemctl enable NetworkManager
  if [[ -n "$WIFI_SSID" ]]; then
    iw reg set $WIFI_COUNTRY || true
    nmcli dev wifi connect "$WIFI_SSID" password "$WIFI_PASS" || true
  fi
fi
EOF

  chmod +x "$SDMOUNT/tmp/setup-system.sh"
  arch-chroot "$SDMOUNT" /tmp/setup-system.sh
  rm -f "$SDMOUNT/tmp/setup-system.sh"

  umount "$SDMOUNT/dev" "$SDMOUNT/proc" "$SDMOUNT/sys" "$SDMOUNT/run" || true
}

finish() {
  sync
  umount -R "$SDMOUNT" || true
  dialog --msgbox "Installation complete." "$HEIGHT" "$WIDTH"
}

ensure_prereqs
select_drive
select_fs
select_kernel
collect_system_info
partition_format
install_rootfs
configure_fstab
configure_cmdline
replace_kernel
install_tools_chroot
configure_system_chroot
finish
