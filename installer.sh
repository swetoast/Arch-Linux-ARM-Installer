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

ensure_prereqs() {
  for cmd in dialog lsblk sfdisk mkfs.vfat bsdtar curl arch-chroot; do
    command -v "$cmd" >/dev/null || { echo "Missing $cmd"; exit 1; }
  done
}

select_drive() {
  mapfile -t DEVICES < <(lsblk -dn -o NAME,SIZE,MODEL | awk '{print $1 " " $2 " " $3}')
  MENU_ITEMS=()
  for i in "${!DEVICES[@]}"; do
    MENU_ITEMS+=("$i" "${DEVICES[$i]}")
  done
  CHOICE=$(dialog --clear --stdout --menu "Select target drive" "$HEIGHT" "$WIDTH" "$MENU_HEIGHT" "${MENU_ITEMS[@]}")
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
    3 "xfs" off)
  case "$FS" in
    1) ROOTFS="ext4" ;;
    2) ROOTFS="btrfs" ;;
    3) ROOTFS="xfs" ;;
  esac
}

select_kernel() {
  KF=$(dialog --clear --stdout --radiolist "Select kernel flavor" "$HEIGHT" "$WIDTH" "$MENU_HEIGHT" \
    1 "linux-rpi" on \
    2 "linux-rpi-16k" off)
  case "$KF" in
    1) KERNEL_FLAVOR="linux-rpi" ;;
    2) KERNEL_FLAVOR="linux-rpi-16k" ;;
  esac
}

collect_system_info() {
  HOSTNAME=$(dialog --clear --stdout --inputbox "Enter hostname" "$HEIGHT" "$WIDTH" "archarm")
  USERNAME=$(dialog --clear --stdout --inputbox "Enter username" "$HEIGHT" "$WIDTH" "user")
  USERPASS=$(dialog --clear --stdout --passwordbox "Enter password for $USERNAME" "$HEIGHT" "$WIDTH")
  ROOTPASS=$(dialog --clear --stdout --passwordbox "Enter root password" "$HEIGHT" "$WIDTH")
  LOCALE=$(dialog --clear --stdout --inputbox "Enter locale (e.g. en_US.UTF-8)" "$HEIGHT" "$WIDTH" "en_US.UTF-8")
  TIMEZONE=$(dialog --clear --stdout --inputbox "Enter timezone (e.g. Europe/Stockholm)" "$HEIGHT" "$WIDTH" "UTC")
}

partition_format() {
  dialog --yesno "WARNING: This will wipe $SDDEV. Continue?" "$HEIGHT" "$WIDTH" || exit 1
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
  mkdir -p "$DOWNLOADDIR"
  cd "$DOWNLOADDIR"
  [[ -f "$(basename "$DISTURL")" ]] || curl -JLO "$DISTURL"
  mkdir -p "$SDMOUNT"
  mount "$SDPARTROOT" "$SDMOUNT"
  mkdir -p "$SDMOUNT/boot"
  mount "$SDPARTBOOT" "$SDMOUNT/boot"
  bsdtar -xpf "$DOWNLOADDIR/$(basename "$DISTURL")" -C "$SDMOUNT"
}

configure_fstab() {
  root_uuid=$(blkid -s UUID -o value "$SDPARTROOT")
  boot_uuid=$(blkid -s UUID -o value "$SDPARTBOOT")
  case "$ROOTFS" in
    ext4) root_type="ext4" root_opts="defaults,noatime" ;;
    btrfs) root_type="btrfs" root_opts="compress=zstd,ssd,noatime,space_cache=v2" ;;
    xfs) root_type="xfs" root_opts="defaults,noatime" ;;
  esac
  cat > "$SDMOUNT/etc/fstab" <<EOT
UUID=$root_uuid  /      $root_type  $root_opts  0 1
UUID=$boot_uuid  /boot  vfat        defaults    0 2
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

  umount "$SDMOUNT/dev" || true
  umount "$SDMOUNT/proc" || true
  umount "$SDMOUNT/sys" || true
  umount "$SDMOUNT/run" || true
}

install_tools_chroot() {
  mount --bind /dev  "$SDMOUNT/dev"
  mount --bind /proc "$SDMOUNT/proc"
  mount --bind /sys  "$SDMOUNT/sys"
  mount --bind /run  "$SDMOUNT/run"

  arch-chroot "$SDMOUNT" /bin/bash -c "
    set -euo pipefail
    case \"$ROOTFS\" in
      ext4)  pacman -Sy --noconfirm e2fsprogs ;;
      btrfs) pacman -Sy --noconfirm btrfs-progs ;;
      xfs)   pacman -Sy --noconfirm xfsprogs ;;
    esac
    pacman -Sy --noconfirm dosfstools
  "

  umount "$SDMOUNT/dev" || true
  umount "$SDMOUNT/proc" || true
  umount "$SDMOUNT/sys" || true
  umount "$SDMOUNT/run" || true
}

configure_system_chroot() {
  mount --bind /dev  "$SDMOUNT/dev"
  mount --bind /proc "$SDMOUNT/proc"
  mount --bind /sys  "$SDMOUNT/sys"
  mount --bind /run  "$SDMOUNT/run"

  arch-chroot "$SDMOUNT" /bin/bash -c "
    set -euo pipefail
    echo '$LOCALE UTF-8' >> /etc/locale.gen
    locale-gen
    echo 'LANG=$LOCALE' > /etc/locale.conf

    ln -sf /usr/share/zoneinfo/$TIMEZONE /etc/localtime
    hwclock --systohc

    echo '$HOSTNAME' > /etc/hostname

    useradd -m -G wheel -s /bin/bash $USERNAME
    echo '$USERNAME:$USERPASS' | chpasswd
    echo 'root:$ROOTPASS' | chpasswd
  "

  umount "$SDMOUNT/dev" || true
  umount "$SDMOUNT/proc" || true
  umount "$SDMOUNT/sys" || true
  umount "$SDMOUNT/run" || true
}

finish() {
  sync
  umount -R "$SDMOUNT" || true
  dialog --msgbox "Installation complete." "$HEIGHT" "$WIDTH"
}

# Run everything in sequence
ensure_prereqs
select_drive
select_fs
select_kernel
collect_system_info
partition_format
install_rootfs
configure_fstab
replace_kernel
install_tools_chroot
configure_system_chroot
finish
