
#!/usr/bin/env bash
set -euo pipefail

# --- Config (override via env) ---
IMAGE_NAME="${IMAGE_NAME:-rpi-live-archarm-$(date +%Y%m%d)}"
IMAGE_SIZE_GB="${IMAGE_SIZE_GB:-4}" # total image size
BOOT_MB="${BOOT_MB:-256}"           # FAT32 /boot size
ROOTFS="${ROOTFS:-ext4}"            # ext4 is safest for live env
DISTURL="${DISTURL:-https://os.archlinuxarm.org/os/ArchLinuxARM-rpi-aarch64-latest.tar.gz}"

# Paths in repo
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
INSTALLER="${INSTALLER:-$REPO_ROOT/installer.sh}"
AUTO_SCRIPT="${AUTO_SCRIPT:-$REPO_ROOT/scripts/auto-install.sh}"
AUTO_SERVICE="${AUTO_SERVICE:-$REPO_ROOT/units/auto-install.service}"

# --- Preflight ---
command -v bsdtar >/dev/null || { echo "bsdtar missing"; exit 1; }
command -v gpg >/dev/null || { echo "gpg missing"; exit 1; }
command -v sfdisk >/dev/null || { echo "sfdisk missing"; exit 1; }
command -v losetup >/dev/null || { echo "losetup missing"; exit 1; }
command -v mkfs.vfat >/dev/null || { echo "mkfs.vfat missing"; exit 1; }
command -v mkfs.ext4 >/dev/null || { echo "mkfs.ext4 missing"; exit 1; }
[[ -r "$INSTALLER" && -x "$INSTALLER" ]] || { echo "installer.sh missing or not executable"; exit 1; }

WORKDIR="$(pwd)"
OUTDIR="$WORKDIR/artifacts"
IMG="$WORKDIR/${IMAGE_NAME}.img"
mkdir -p "$OUTDIR"

# --- Create sparse image & partition (DOS/MBR) ---
truncate -s "${IMAGE_SIZE_GB}G" "$IMG"
sfdisk --wipe always "$IMG" <<EOF
label: dos
label-id: 0x$(printf "%08x" $RANDOM)
device: $IMG
unit: sectors

${IMG}1 : start=2048, size=$((BOOT_MB*2048)), type=0x0c, bootable
${IMG}2 : start=$((BOOT_MB*2048+2048)), type=0x83
EOF

# Map loop with partitions
LOOPDEV="$(sudo losetup --find --show --partscan "$IMG")"
BOOT_PART="${LOOPDEV}p1"
ROOT_PART="${LOOPDEV}p2"

# --- Format filesystems ---
sudo mkfs.vfat -F32 -n BOOT "$BOOT_PART"
sudo mkfs.ext4 -F -L ROOT "$ROOT_PART"

# --- Mount ---
mkdir -p /tmp/piusb/boot /tmp/piusb/root
sudo mount "$BOOT_PART" /tmp/piusb/boot
sudo mount "$ROOT_PART" /tmp/piusb/root

# --- Fetch Arch ARM tarball & verify ---
cd /tmp
BASE="$(basename "$DISTURL")"
curl -fSLO "$DISTURL"
curl -fSLO "${DISTURL}.md5" || true
curl -fSLO "${DISTURL}.sig" || true

# md5sum when available
[[ -f "/tmp/${BASE}.md5" ]] && md5sum -c "/tmp/${BASE}.md5" || echo "MD5 file not present, continuing"

# gpg verify when available
if [[ -f "/tmp/${BASE}.sig" ]]; then
  gpg --keyserver hkps://keyserver.ubuntu.com --recv-keys 68B3537F39A313B3E574D06777193F152BDBE6A6 \
   || { curl -fsSL https://raw.githubusercontent.com/archlinuxarm/archlinuxarm-keyring/master/archlinuxarm.gpg -o archlinuxarm.gpg && gpg --import archlinuxarm.gpg; }
  gpg --verify "/tmp/${BASE}.sig" "/tmp/${BASE}" || { echo "GPG verify failed"; exit 1; }
fi

# --- Extract rootfs into / ---
sudo bsdtar -xpf "/tmp/${BASE}" -C /tmp/piusb/root

# Copy boot firmware/kernel into FAT32 /boot for Pi firmware
sudo rsync -a /tmp/piusb/root/boot/ /tmp/piusb/boot/

# --- fstab, cmdline, config ---
sudo tee /tmp/piusb/root/etc/fstab >/dev/null <<EOT
LABEL=ROOT  /      ${ROOTFS}  defaults,noatime  0 1
LABEL=BOOT  /boot  vfat       defaults          0 2
EOT

PARTUUID="$(sudo blkid -s PARTUUID -o value "$ROOT_PART")"
sudo tee /tmp/piusb/boot/cmdline.txt >/dev/null <<EOT
console=serial0,115200 console=tty1 root=PARTUUID=${PARTUUID} rw rootwait fsck.repair=yes quiet systemd.unified_cgroup_hierarchy=1
EOT

sudo tee -a /tmp/piusb/boot/config.txt >/dev/null <<'EOT'
# Live USB defaults (installer will adjust later)
gpu_mem=128
EOT

# --- Embed installer and autorun ---
sudo install -m 0755 "$INSTALLER" /tmp/piusb/root/root/installer.sh
sudo install -m 0644 "$AUTO_SERVICE" /tmp/piusb/root/etc/systemd/system/auto-install.service
sudo install -m 0755 "$AUTO_SCRIPT"  /tmp/piusb/root/root/auto-install.sh
sudo ln -sf /etc/systemd/system/auto-install.service /tmp/piusb/root/etc/systemd/system/multi-user.target.wants/auto-install.service

# --- Clean up & compress ---
sync
sudo umount /tmp/piusb/boot /tmp/piusb/root
sudo losetup -d "$LOOPDEV"
rm -rf /tmp/piusb

xz -T0 -z -9 -c "$IMG" > "$OUTDIR/${IMAGE_NAME}.imgxz -T0 -z -9 -c "$IMG" > "$OUTDIR/${IMAGE_NAME}.img.xz"

