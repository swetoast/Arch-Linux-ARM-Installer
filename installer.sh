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
KERNELURL="http://mirror.archlinuxarm.org/aarch64/core/linux-rpi-6.1.63-1-aarch64.pkg.tar.xz"

SDDEV=""
SDPARTBOOT=""
SDPARTROOT=""
ROOTFS="ext4"

ensure_prereqs() {
  command -v dialog >/dev/null || { echo "Install 'dialog' first"; exit 1; }
  command -v lsblk >/dev/null || { echo "lsblk missing"; exit 1; }
  command -v sfdisk >/dev/null || { echo "sfdisk missing"; exit 1; }
  command -v mkfs.vfat >/dev/null || { echo "dosfstools missing"; exit 1; }
  command -v bsdtar >/dev/null || { echo "bsdtar missing"; exit 1; }
  command -v curl >/dev/null || { echo "curl missing"; exit 1; }
  command -v arch-chroot >/dev/null || pacman -Sy --noconfirm arch-install-scripts
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

replace_kernel() {
  rm -rf "${SDMOUNT:?}/boot"/*
  mkdir -p "$DOWNLOADDIR/linux-rpi"
  pushd "$DOWNLOADDIR/linux-rpi" >/dev/null
  rm -f -- ./*.pkg.tar.* || true
  curl -JLO "$KERNELURL"
  tar xf -- ./*.pkg.tar.*
  cp -rf boot/* "$SDMOUNT/boot/"
  popd >/dev/null
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

install_tools_chroot() {
  mount --bind /dev  "$SDMOUNT/dev"
  mount --bind /proc "$SDMOUNT/proc"
  mount --bind /sys  "$SDMOUNT/sys"
  mount --bind /run  "$SDMOUNT/run"
  arch-chroot "$SDMOUNT" /bin/bash -c "
    pacman-key --init || true
    pacman-key --populate archlinuxarm || true
    pacman -Sy --noconfirm base linux-firmware
    case \"$ROOTFS\" in
      ext4) pacman -Sy --noconfirm e2fsprogs ;;
      btrfs) pacman -Sy --noconfirm btrfs-progs ;;
      xfs) pacman -Sy --noconfirm xfsprogs ;;
    esac
    pacman -Sy --noconfirm dosfstools
  "
}

finish() {
  sync
  umount -R "$SDMOUNT" || true
  dialog --msgbox "Installation complete." "$HEIGHT" "$WIDTH"
}

ensure_prereqs
select_drive
select_fs
partition_format
install_rootfs
replace_kernel
configure_fstab
install_tools_chroot
finish
