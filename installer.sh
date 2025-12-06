#!/bin/bash
set -euo pipefail

if [[ $EUID -ne 0 ]]; then echo "Run as root."; exit 1; fi

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
KEYMAP="us"
NETWORKING="systemd-networkd"
WIFI_SSID=""
WIFI_PASS=""
WIFI_COUNTRY=""
SSH_ENABLE="yes"
SSH_KEYONLY="no"
SSH_DISABLE_ROOT="no"
CHRONY_ENABLE="no"
SWAP_SIZE_GB="0"
EXT4_TUNE="yes"
TRIM_ENABLE="yes"
AVAHI_ENABLE="yes"
BOOTLOADER_INSTALL="no"
GPU_MEM="128"
ENABLE_SPI="no"
ENABLE_I2C="no"

show_logo() {
  clear
  echo -e "\033[38;2;23;147;209m
                   ▄
                  ▟█▙
                 ▟███▙
                ▟█████▙
               ▟███████▙
              ▂▔▀▜██████▙
             ▟██▅▂▝▜█████▙
            ▟█████████████▙
           ▟███████████████▙
          ▟█████████████████▙
         ▟███████████████████▙
        ▟█████████▛▀▀▜████████▙
       ▟████████▛      ▜███████▙
      ▟█████████        ████████▙
     ▟██████████        █████▆▅▄▃▂
    ▟██████████▛        ▜█████████▙
   ▟██████▀▀▀              ▀▀██████▙
  ▟███▀▘                       ▝▀███▙
 ▟▛▀                               ▀▜▙
\033[0m"
  echo
  echo "      Arch Linux ARM Installer"
}

cleanup_mounts() { umount -R "$SDMOUNT" 2>/dev/null || true; }
trap cleanup_mounts EXIT

ensure_prereqs() {
  for cmd in dialog lsblk sfdisk mkfs.vfat bsdtar curl arch-chroot blkid partprobe udevadm sed awk grep gpg md5sum; do
    command -v "$cmd" >/dev/null || { echo "Missing $cmd"; exit 1; }
  done
  mkdir -p "$SDMOUNT" "$DOWNLOADDIR"
}

compute_fs_flags_for_target() {
  local parent
  parent=$(lsblk -no PKNAME "$SDPARTROOT" 2>/dev/null || true)
  if [[ -z "$parent" ]]; then
    parent=$(basename "$(readlink -f "$SDPARTROOT")" | sed -E 's/p?[0-9]+$//')
  fi
  local q="/sys/block/$parent/queue"
  local rotational=1 discard_max=0 discard_gran=0
  [[ -r "$q/rotational" ]] && rotational=$(cat "$q/rotational" 2>/dev/null || echo 1)
  [[ -r "$q/discard_max_bytes" ]] && discard_max=$(cat "$q/discard_max_bytes" 2>/dev/null || echo 0)
  [[ -r "$q/discard_granularity" ]] && discard_gran=$(cat "$q/discard_granularity" 2>/dev/null || echo 0)
  export TARGET_ROTATIONAL="$rotational"
  export TARGET_DISCARD_SUPPORTED="no"
  if [[ "$discard_max" -gt 0 || "$discard_gran" -gt 0 ]]; then
    export TARGET_DISCARD_SUPPORTED="yes"
  fi
  export EXT4_MKFS_ARGS="-F -O metadata_csum,64bit -E lazy_itable_init=1,lazy_journal_init=1"
  local ext4_opts="defaults,noatime,lazytime,commit=120"
  if [[ "$TARGET_ROTATIONAL" == "0" && "$TARGET_DISCARD_SUPPORTED" == "yes" && "$TRIM_ENABLE" == "yes" ]]; then
    ext4_opts="${ext4_opts},discard"
  fi
  export EXT4_MOUNT_OPTS="$ext4_opts"
  export BTRFS_MKFS_ARGS="-f"
  local btrfs_opts="compress=zstd,noatime,space_cache=v2"
  if [[ "$TARGET_ROTATIONAL" == "0" ]]; then
    btrfs_opts="${btrfs_opts},ssd"
  fi
  export BTRFS_MOUNT_OPTS="$btrfs_opts"
  export XFS_MKFS_ARGS="-f -m crc=1,reflink=1 -n ftype=1"
  local xfs_opts="defaults,noatime,inode64"
  if [[ "$TARGET_ROTATIONAL" == "0" && "$TARGET_DISCARD_SUPPORTED" == "yes" && "$TRIM_ENABLE" == "yes" ]]; then
    xfs_opts="${xfs_opts},discard"
  fi
  export XFS_MOUNT_OPTS="$xfs_opts"
}

assert_cross_arch_chroot() {
  mount --bind /dev "$SDMOUNT/dev"; mount --bind /proc "$SDMOUNT/proc"; mount --bind /sys "$SDMOUNT/sys"; mount --bind /run "$SDMOUNT/run"
  if ! arch-chroot "$SDMOUNT" /usr/bin/true 2>/dev/null; then
    umount "$SDMOUNT/dev" "$SDMOUNT/proc" "$SDMOUNT/sys" "$SDMOUNT/run" || true
    dialog --msgbox "Foreign-arch chroot detected. Install qemu-user-static/binfmt or run this on an ARM host." "$HEIGHT" "$WIDTH"
    echo "ERROR: arch-chroot into ARM rootfs requires binfmt_misc + qemu-aarch64-static, or an ARM host."
    exit 1
  fi
  umount "$SDMOUNT/dev" "$SDMOUNT/proc" "$SDMOUNT/sys" "$SDMOUNT/run" || true
}

select_drive() {
  mapfile -t DEVICES < <(lsblk -dn -o NAME,SIZE,MODEL | awk '{print $1 " " $2 " " substr($0, index($0,$3))}')
  ((${#DEVICES[@]})) || { echo "No block devices found."; exit 1; }
  MENU_ITEMS=(); for i in "${!DEVICES[@]}"; do MENU_ITEMS+=("$i" "${DEVICES[$i]}"); end
  CHOICE=$(dialog --clear --stdout --menu "Select target drive" "$HEIGHT" "$WIDTH" "$MENU_HEIGHT" "${MENU_ITEMS[@]}") || exit 1
  SDDEV="/dev/$(echo "${DEVICES[$CHOICE]}" | awk '{print $1}')"
  if [[ "$SDDEV" =~ (mmcblk|nvme) ]]; then SDPARTBOOT="${SDDEV}p1"; SDPARTROOT="${SDDEV}p2"; else SDPARTBOOT="${SDDEV}1"; SDPARTROOT="${SDDEV}2"; fi
}

select_fs() {
  FS=$(dialog --clear --stdout --radiolist "Select filesystem for root partition" "$HEIGHT" "$WIDTH" "$MENU_HEIGHT" \
    1 "ext4" on 2 "btrfs" off 3 "xfs" off) || exit 1
  case "$FS" in 1) ROOTFS="ext4";; 2) ROOTFS="btrfs";; 3) ROOTFS="xfs";; esac
}

select_kernel() {
  KF=$(dialog --clear --stdout --radiolist "Select kernel flavor" "$HEIGHT" "$WIDTH" "$MENU_HEIGHT" \
    1 "linux-rpi" on 2 "linux-rpi-16k" off) || exit 1
  case "$KF" in 1) KERNEL_FLAVOR="linux-rpi";; 2) KERNEL_FLAVOR="linux-rpi-16k";; esac
}

collect_system_info() {
  HOSTNAME=$(dialog --clear --stdout --inputbox "Enter hostname" "$HEIGHT" "$WIDTH" "rpi5") || exit 1
  USERNAME=$(dialog --clear --stdout --inputbox "Enter username" "$HEIGHT" "$WIDTH" "pi") || exit 1
  USERPASS=$(dialog --clear --stdout --passwordbox "Enter password for $USERNAME" "$HEIGHT" "$WIDTH") || exit 1
  ROOTPASS=$(dialog --clear --stdout --passwordbox "Enter root password" "$HEIGHT" "$WIDTH") || exit 1
  LOCALE=$(dialog --clear --stdout --inputbox "Enter locale (e.g. en_US.UTF-8 or sv_SE.UTF-8)" "$HEIGHT" "$WIDTH" "en_US.UTF-8") || exit 1
  TIMEZONE=$(dialog --clear --stdout --inputbox "Enter timezone (e.g. Europe/Stockholm)" "$HEIGHT" "$WIDTH" "Europe/Stockholm") || exit 1
  KEYMAP=$(dialog --clear --stdout --inputbox "Console keymap (e.g. us, se, de)" "$HEIGHT" "$WIDTH" "us") || exit 1
  NETSEL=$(dialog --clear --stdout --radiolist "Select networking setup" "$HEIGHT" "$WIDTH" "$MENU_HEIGHT" \
    1 "systemd-networkd + resolved" on 2 "NetworkManager" off) || exit 1
  case "$NETSEL" in 1) NETWORKING="systemd-networkd";; 2) NETWORKING="NetworkManager";; esac
  if dialog --yesno "Configure Wi-Fi?" "$HEIGHT" "$WIDTH"; then
    WIFI_SSID=$(dialog --clear --stdout --inputbox "SSID" "$HEIGHT" "$WIDTH") || exit 1
    WIFI_PASS=$(dialog --clear --stdout --passwordbox "Password" "$HEIGHT" "$WIDTH") || exit 1
    WIFI_COUNTRY=$(dialog --clear --stdout --inputbox "Country code (e.g. SE, US)" "$HEIGHT" "$WIDTH" "SE") || exit 1
  fi
  SSH_ENABLE=$(dialog --clear --stdout --radiolist "Enable SSH server?" "$HEIGHT" "$WIDTH" "$MENU_HEIGHT" 1 "yes" on 2 "no" off) || exit 1
  if [[ "$SSH_ENABLE" == "2" ]]; then SSH_ENABLE="no"; else SSH_ENABLE="yes"; fi
  if [[ "$SSH_ENABLE" == "yes" ]]; then
    SSH_KEYONLY=$(dialog --clear --stdout --radiolist "SSH auth mode" "$HEIGHT" "$WIDTH" "$MENU_HEIGHT" 1 "password+keys" on 2 "keys only" off) || exit 1
    if [[ "$SSH_KEYONLY" == "2" ]]; then SSH_KEYONLY="yes"; else SSH_KEYONLY="no"; fi
    SSH_DISABLE_ROOT=$(dialog --clear --stdout --radiolist "Disable root SSH login?" "$HEIGHT" "$WIDTH" "$MENU_HEIGHT" 1 "no" on 2 "yes" off) || exit 1
    if [[ "$SSH_DISABLE_ROOT" == "2" ]]; then SSH_DISABLE_ROOT="yes"; else SSH_DISABLE_ROOT="no"; fi
  fi
  CHRONY_ENABLE=$(dialog --clear --stdout --radiolist "Use chrony for NTP?" "$HEIGHT" "$WIDTH" "$MENU_HEIGHT" 1 "no (timesyncd)" on 2 "yes (chrony)" off) || exit 1
  if [[ "$CHRONY_ENABLE" == "2" ]]; then CHRONY_ENABLE="yes"; else CHRONY_ENABLE="no"; fi
  SWAP_SIZE_GB=$(dialog --clear --stdout --inputbox "Swap file size in GB (0 to skip)" "$HEIGHT" "$WIDTH" "0") || exit 1
  EXT4_TUNE=$(dialog --clear --stdout --radiolist "Tune ext4 reserved blocks to 0?" "$HEIGHT" "$WIDTH" "$MENU_HEIGHT" 1 "yes" on 2 "no" off) || exit 1
  if [[ "$EXT4_TUNE" == "2" ]]; then EXT4_TUNE="no"; else EXT4_TUNE="yes"; fi
  TRIM_ENABLE=$(dialog --clear --stdout --radiolist "Enable weekly fstrim?" "$HEIGHT" "$WIDTH" "$MENU_HEIGHT" 1 "yes" on 2 "no" off) || exit 1
  if [[ "$TRIM_ENABLE" == "2" ]]; then TRIM_ENABLE="no"; else TRIM_ENABLE="yes"; fi
  AVAHI_ENABLE=$(dialog --clear --stdout --radiolist "Enable Avahi/mDNS?" "$HEIGHT" "$WIDTH" "$MENU_HEIGHT" 1 "yes" on 2 "no" off) || exit 1
  if [[ "$AVAHI_ENABLE" == "2" ]]; then AVAHI_ENABLE="no"; else AVAHI_ENABLE="yes"; fi
  BOOTLOADER_INSTALL=$(dialog --clear --stdout --radiolist "Install raspberrypi-bootloader?" "$HEIGHT" "$WIDTH" "$MENU_HEIGHT" 1 "no" on 2 "yes" off) || exit 1
  if [[ "$BOOTLOADER_INSTALL" == "2" ]]; then BOOTLOADER_INSTALL="yes"; else BOOTLOADER_INSTALL="no"; fi
  GPU_MEM=$(dialog --clear --stdout --inputbox "GPU memory (MB) for /boot/config.txt" "$HEIGHT" "$WIDTH" "128") || exit 1
  ENABLE_SPI=$(dialog --clear --stdout --radiolist "Enable SPI overlay?" "$HEIGHT" "$WIDTH" "$MENU_HEIGHT" 1 "no" on 2 "yes" off) || exit 1
  if [[ "$ENABLE_SPI" == "2" ]]; then ENABLE_SPI="yes"; else ENABLE_SPI="no"; fi
  ENABLE_I2C=$(dialog --clear --stdout --radiolist "Enable I2C overlay?" "$HEIGHT" "$WIDTH" "$MENU_HEIGHT" 1 "no" on 2 "yes" off) || exit 1
  if [[ "$ENABLE_I2C" == "2" ]]; then ENABLE_I2C="yes"; else ENABLE_I2C="no"; fi
}

partition_format() {
  dialog --yesno "WARNING: This will WIPE $SDDEV. Continue?" "$HEIGHT" "$WIDTH" || exit 1
  wipefs -af "$SDDEV" || true
  sfdisk --quiet --wipe always "$SDDEV" << EOF
,256M,0c,
,,,
EOF
  partprobe "$SDDEV" || true; udevadm settle || true
  mkfs.vfat -F 32 "$SDPARTBOOT"
  compute_fs_flags_for_target
  case "$ROOTFS" in
    ext4)
      mkfs.ext4 $EXT4_MKFS_ARGS "$SDPARTROOT"
      if [[ "$EXT4_TUNE" == "yes" ]]; then tune2fs -m 0 "$SDPARTROOT" || true; fi
      ;;
    btrfs)
      mkfs.btrfs $BTRFS_MKFS_ARGS "$SDPARTROOT"
      ;;
    xfs)
      mkfs.xfs $XFS_MKFS_ARGS "$SDPARTROOT"
      ;;
  esac
}

install_rootfs() {
  cd "$DOWNLOADDIR"
  base="$(basename "$DISTURL")"
  md5url="${DISTURL}.md5"
  sigurl="${DISTURL}.sig"
  [[ -f "$base" ]] || curl -JLO "$DISTURL"
  curl -f -O "$md5url" || curl -f -O "$(dirname "$DISTURL")/${base}.md5"
  curl -f -O "$sigurl" || curl -f -O "$(dirname "$DISTURL")/${base}.sig"
  md5sum -c "${base}.md5"
  gpg --keyserver hkps://keyserver.ubuntu.com --recv-keys 68B3537F39A313B3E574D06777193F152BDBE6A6 \
    || { curl -fsSL https://raw.githubusercontent.com/archlinuxarm/archlinuxarm-keyring/master/archlinuxarm.gpg -o archlinuxarm.gpg && gpg --import archlinuxarm.gpg; }
  gpg --verify "${base}.sig" "$base"
  mount "$SDPARTROOT" "$SDMOUNT"; mkdir -p "$SDMOUNT/boot"; mount "$SDPARTBOOT" "$SDMOUNT/boot"
  bsdtar -xpf "$DOWNLOADDIR/$base" -C "$SDMOUNT"
}

configure_fstab() {
  root_uuid=$(blkid -s UUID -o value "$SDPARTROOT"); boot_uuid=$(blkid -s UUID -o value "$SDPARTBOOT")
  case "$ROOTFS" in
    ext4)
      root_type="ext4"; root_opts="${EXT4_MOUNT_OPTS:-defaults,noatime}"
      ;;
    btrfs)
      root_type="btrfs"; root_opts="${BTRFS_MOUNT_OPTS:-compress=zstd,noatime,space_cache=v2}"
      ;;
    xfs)
      root_type="xfs"; root_opts="${XFS_MOUNT_OPTS:-defaults,noatime,inode64}"
      ;;
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
  assert_cross_arch_chroot
  mount --bind /dev "$SDMOUNT/dev"; mount --bind /proc "$SDMOUNT/proc"; mount --bind /sys "$SDMOUNT/sys"; mount --bind /run "$SDMOUNT/run"
  arch-chroot "$SDMOUNT" /bin/bash -c "set -euo pipefail; pacman-key --init || true; pacman-key --populate archlinuxarm || true; pacman -Sy --noconfirm ${KERNEL_FLAVOR} ${KERNEL_FLAVOR}-headers linux-firmware"
  umount "$SDMOUNT/dev" "$SDMOUNT/proc" "$SDMOUNT/sys" "$SDMOUNT/run" || true
}

install_tools_chroot() {
  assert_cross_arch_chroot
  mount --bind /dev "$SDMOUNT/dev"; mount --bind /proc "$SDMOUNT/proc"; mount --bind /sys "$SDMOUNT/sys"; mount --bind /run "$SDMOUNT/run"

  cat > "$SDMOUNT/tmp/install-tools.sh" <<'EOF'
#!/bin/bash
set -euo pipefail
pacman -Sy --noconfirm sudo dosfstools wireless-regdb logrotate base-devel
if ! grep -q '^%wheel' /etc/sudoers; then echo '%wheel ALL=(ALL) ALL' >> /etc/sudoers; fi
EOF

  if [[ "$ROOTFS" == "ext4" ]]; then
    cat >> "$SDMOUNT/tmp/install-tools.sh" <<'EOF'
pacman -Sy --noconfirm e2fsprogs
EOF
  elif [[ "$ROOTFS" == "btrfs" ]]; then
    cat >> "$SDMOUNT/tmp/install-tools.sh" <<'EOF'
pacman -Sy --noconfirm btrfs-progs
EOF
  elif [[ "$ROOTFS" == "xfs" ]]; then
    cat >> "$SDMOUNT/tmp/install-tools.sh" <<'EOF'
pacman -Sy --noconfirm xfsprogs
EOF
  fi

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

  if [[ "$SSH_ENABLE" == "yes" ]]; then
    cat >> "$SDMOUNT/tmp/install-tools.sh" <<'EOF'
pacman -Sy --noconfirm openssh
EOF
  fi

  if [[ "$AVAHI_ENABLE" == "yes" ]]; then
    cat >> "$SDMOUNT/tmp/install-tools.sh" <<'EOF'
pacman -Sy --noconfirm avahi nss-mdns
EOF
  fi

  if [[ "$CHRONY_ENABLE" == "yes" ]]; then
    cat >> "$SDMOUNT/tmp/install-tools.sh" <<'EOF'
pacman -Sy --noconfirm chrony
EOF
  fi

  if [[ "$TRIM_ENABLE" == "yes" ]]; then
    cat >> "$SDMOUNT/tmp/install-tools.sh" <<'EOF'
systemctl enable fstrim.timer
EOF
  fi

  if [[ "$BOOTLOADER_INSTALL" == "yes" ]]; then
    cat >> "$SDMOUNT/tmp/install-tools.sh" <<'EOF'
pacman -Sy --noconfirm raspberrypi-bootloader
EOF
  fi

  chmod +x "$SDMOUNT/tmp/install-tools.sh"
  arch-chroot "$SDMOUNT" /tmp/install-tools.sh
  rm -f "$SDMOUNT/tmp/install-tools.sh"

  umount "$SDMOUNT/dev" "$SDMOUNT/proc" "$SDMOUNT/sys" "$SDMOUNT/run" || true
}

configure_system_chroot() {
  assert_cross_arch_chroot
  mount --bind /dev "$SDMOUNT/dev"; mount --bind /proc "$SDMOUNT/proc"; mount --bind /sys "$SDMOUNT/sys"; mount --bind /run "$SDMOUNT/run"

  sanitized_ssid=$(echo "$WIFI_SSID" | sed 's/[^A-Za-z0-9._-]/_/g' || true)
  WIFI_COUNTRY_UPPER=$(echo "$WIFI_COUNTRY" | tr '[:lower:]' '[:upper:]')

  cat > "$SDMOUNT/tmp/setup-system.sh" <<EOF
#!/bin/bash
set -euo pipefail

sed -i '/^$LOCALE/d' /etc/locale.gen || true
echo "$LOCALE UTF-8" >> /etc/locale.gen
locale-gen
echo "LANG=$LOCALE" > /etc/locale.conf
echo "KEYMAP=$KEYMAP" > /etc/vconsole.conf

ln -sf /usr/share/zoneinfo/$TIMEZONE /etc/localtime
hwclock --systohc
systemctl enable systemd-timesyncd

echo "$HOSTNAME" > /etc/hostname

if ! id "$USERNAME" >/dev/null 2>&1; then useradd -m -G wheel -s /bin/bash "$USERNAME"; fi
echo "$USERNAME:$USERPASS" | chpasswd
echo "root:$ROOTPASS" | chpasswd

# delete 'alarm' only if a proper admin user exists and is in wheel, and chosen username isn't 'alarm'
if [[ "$USERNAME" != "alarm" ]]; then
  if id "$USERNAME" >/dev/null 2>&1 && id -nG "$USERNAME" | tr ' ' '\\n' | grep -qx wheel; then
    if id alarm >/dev/null 2>&1; then userdel -r alarm || true; fi
  else
    echo "WARNING: user '$USERNAME' not fully provisioned; retaining 'alarm' account." >&2
  fi
fi

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
RegulatoryDomain=$WIFI_COUNTRY_UPPER
CONF
    mkdir -p /var/lib/iwd
    cat > /var/lib/iwd/$sanitized_ssid.psk <<WIFI
[Security]
PreSharedKey=$WIFI_PASS
WIFI
    chmod 600 /var/lib/iwd/$sanitized_ssid.psk || true
  fi

else
  systemctl enable NetworkManager
  if [[ -n "$WIFI_SSID" ]]; then
    iw reg set $WIFI_COUNTRY_UPPER || true
    cat > /etc/systemd/system/regdomain.service <<SRV
[Unit]
Description=Set Wi-Fi regulatory domain
After=network-pre.target
[Service]
Type=oneshot
ExecStart=/usr/bin/iw reg set $WIFI_COUNTRY_UPPER
[Install]
WantedBy=multi-user.target
SRV
    systemctl enable regdomain.service || true
    mkdir -p /etc/NetworkManager/system-connections
    cat > "/etc/NetworkManager/system-connections/${sanitized_ssid}.nmconnection" <<NM
[connection]
id=${WIFI_SSID}
type=wifi
autoconnect=true

[wifi]
ssid=${WIFI_SSID}
mode=infrastructure

[wifi-security]
key-mgmt=wpa-psk
psk=${WIFI_PASS}

[ipv4]
method=auto

[ipv6]
method=auto
NM
    chmod 600 "/etc/NetworkManager/system-connections/${sanitized_ssid}.nmconnection"
  fi
fi

if [[ "$SSH_ENABLE" == "yes" ]]; then
  systemctl enable sshd
  if [[ "$SSH_KEYONLY" == "yes" ]]; then
    sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config || true
    mkdir -p "/home/$USERNAME/.ssh"
    chmod 700 "/home/$USERNAME/.ssh"
    if [[ -f /root/seed_authorized_key.pub ]]; then
      cat /root/seed_authorized_key.pub >> "/home/$USERNAME/.ssh/authorized_keys"
      chmod 600 "/home/$USERNAME/.ssh/authorized_keys"
      chown -R "$USERNAME:$USERNAME" "/home/$USERNAME/.ssh"
    else
      echo "WARNING: SSH key-only selected but no /root/seed_authorized_key.pub found." >&2
    fi
  fi
  if [[ "$SSH_DISABLE_ROOT" == "yes" ]]; then
    sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config || true
  fi
fi

if [[ "$AVAHI_ENABLE" == "yes" ]]; then
  systemctl enable avahi-daemon
  if ! grep -q 'mdns4_minimal' /etc/nsswitch.conf 2>/dev/null; then
    sed -ri 's/^(hosts:\s+files)(.*dns.*)$/\1 mdns4_minimal [NOTFOUND=return]\2/' /etc/nsswitch.conf || true
  fi
fi

if [[ "$CHRONY_ENABLE" == "yes" ]]; then
  systemctl disable systemd-timesyncd || true
  systemctl enable chrony
fi

if [[ "$SWAP_SIZE_GB" != "0" && "$SWAP_SIZE_GB" != "" ]]; then
  if ! grep -q '/swapfile' /etc/fstab 2>/dev/null; then
    fsroot=\$(findmnt -no FSTYPE / || echo "")
    if [[ "\$fsroot" == "btrfs" ]]; then
      rm -f /swapfile
      truncate -s 0 /swapfile
      chattr +C /swapfile || true
      btrfs property set /swapfile compression none || true
      dd if=/dev/zero of=/swapfile bs=1M count=\$((SWAP_SIZE_GB*1024)) status=progress
    else
      fallocate -l "\${SWAP_SIZE_GB}G" /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=\$((SWAP_SIZE_GB*1024)) status=progress
    fi
    chmod 600 /swapfile
    mkswap /swapfile
    echo "/swapfile none swap defaults 0 0" >> /etc/fstab
  fi
fi

if [[ "$TRIM_ENABLE" == "yes" ]]; then
  systemctl enable fstrim.timer || true
fi

BOOTCFG="/boot/config.txt"
touch "\$BOOTCFG"
if grep -q '^gpu_mem=' "\$BOOTCFG"; then
  sed -i "s/^gpu_mem=.*/gpu_mem=$GPU_MEM/" "\$BOOTCFG"
else
  echo "gpu_mem=$GPU_MEM" >> "\$BOOTCFG"
fi
if [[ "$ENABLE_SPI" == "yes" ]]; then
  grep -q '^dtparam=spi=on' "\$BOOTCFG" || echo "dtparam=spi=on" >> "\$BOOTCFG"
fi
if [[ "$ENABLE_I2C" == "yes" ]]; then
  grep -q '^dtparam=i2c_arm=on' "\$BOOTCFG" || echo "dtparam=i2c_arm=on" >> "\$BOOTCFG"
fi

if [[ "$BOOTLOADER_INSTALL" == "yes" ]]; then
  true
fi

EOF

  chmod +x "$SDMOUNT/tmp/setup-system.sh"
  arch-chroot "$SDMOUNT" /tmp/setup-system.sh
  rm -f "$SDMOUNT/tmp/setup-system.sh"

  umount "$SDMOUNT/dev" "$SDMOUNT/proc" "$SDMOUNT/sys" "$SDMOUNT/run" || true
}

finish() { sync; umount -R "$SDMOUNT" || true; dialog --msgbox "Installation complete." "$HEIGHT" "$WIDTH"; }

show_logo
sleep 5
clear
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
