#!/usr/bin/env bash
# Build a Raspberry Pi bootable image that auto-runs /root/installer.sh at first boot.
# - Downloads Arch Linux ARM rootfs via HTTP
# - Verifies integrity using MD5 only (no GPG)
# - Produces artifacts/<image>.img.xz
set -euo pipefail

###
# ---------- Config (override via env) ----------
IMAGE_NAME="${IMAGE_NAME:-rpi-live-archarm-$(date +%Y%m%d)}"
IMAGE_SIZE_GB="${IMAGE_SIZE_GB:-4}"      # Total size of the image file
BOOT_MB="${BOOT_MB:-256}"                # Size of FAT32 /boot
ROOTFS="${ROOTFS:-ext4}"                 # ext4 is recommended for live root
DISTURL="${DISTURL:-http://os.archlinuxarm.org/os/ArchLinuxARM-rpi-aarch64-latest.tar.gz}"

# Determine repo root so we can find installer and service files
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

INSTALLER="${INSTALLER:-${REPO_ROOT}/installer.sh}"
AUTO_SCRIPT="${AUTO_SCRIPT:-${REPO_ROOT}/scripts/auto-install.sh}"
AUTO_SERVICE="${AUTO_SERVICE:-${REPO_ROOT}/units/auto-install.service}"

WORKDIR="$(pwd)"
OUTDIR="${WORKDIR}/artifacts"
IMG="${WORKDIR}/${IMAGE_NAME}.img"

MNT_BOOT="/tmp/piusb/boot"
MNT_ROOT="/tmp/piusb/root"

###
# ---------- Preflight ----------
need() { command -v "$1" >/dev/null || { echo "Missing dependency: $1"; exit 1; }; }
has()  { command -v "$1" >/dev/null; }

# Core tools used on ubuntu-latest runners
need curl
need rsync
need xz
need sfdisk
need losetup
need mkfs.vfat
need mkfs.ext4

# Extractor: prefer bsdtar; fallback to GNU tar
EXTRACTOR="bsdtar"
if ! has bsdtar; then
  if has tar; then
    EXTRACTOR="tar"
  else
    echo "Need either bsdtar (libarchive-tools) or GNU tar installed."
    exit 1
  fi
fi

[[ -r "$INSTALLER" && -x "$INSTALLER" ]] || { echo "installer.sh missing or not executable: $INSTALLER"; exit 1; }
[[ -r "$AUTO_SCRIPT" && -x "$AUTO_SCRIPT" ]] || { echo "auto-install.sh missing or not executable: $AUTO_SCRIPT"; exit 1; }
[[ -r "$AUTO_SERVICE" ]] || { echo "auto-install.service missing: $AUTO_SERVICE"; exit 1; }

sudo modprobe loop || true
mkdir -p "$OUTDIR"

cleanup() {
  set +e
  sync
  sudo umount "$MNT_BOOT" 2>/dev/null || true
  sudo umount "$MNT_ROOT" 2>/dev/null || true
  [[ -n "${LOOPDEV:-}" ]] && sudo losetup -d "$LOOPDEV" 2>/dev/null || true
  sudo rm -rf /tmp/piusb 2>/dev/null || true
  set -e
}
trap cleanup EXIT

###
# ---------- Create sparse image & partition (DOS/MBR) ----------
echo ":: Creating image ${IMG} (${IMAGE_SIZE_GB}G)"
truncate -s "${IMAGE_SIZE_GB}G" "$IMG"

# sfdisk partitioning:
# p1: 256MB (type 0x0c, LBA FAT32, bootable)
# p2: rest (type 0x83, Linux)
echo ":: Partitioning image ..."
sfdisk --wipe always "$IMG" <<EOF
label: dos
label-id: 0x$(printf "%08x" $RANDOM)
device: $IMG
unit: sectors

${IMG}1 : start=2048, size=$((BOOT_MB*2048)), type=0x0c, bootable
${IMG}2 : start=$((BOOT_MB*2048+2048)), type=0x83
EOF

# Map loop device with partition scanning
LOOPDEV="$(sudo losetup --find --show --partscan "$IMG")"
BOOT_PART="${LOOPDEV}p1"
ROOT_PART="${LOOPDEV}p2"

echo ":: Formatting filesystems ..."
sudo mkfs.vfat -F32 -n BOOT "$BOOT_PART"
sudo mkfs.ext4 -F -L ROOT "$ROOT_PART"

echo ":: Mounting filesystems ..."
mkdir -p "$MNT_BOOT" "$MNT_ROOT"
sudo mount "$BOOT_PART" "$MNT_BOOT"
sudo mount "$ROOT_PART" "$MNT_ROOT"

###
# ---------- Download & verify Arch Linux ARM rootfs (HTTP + MD5) ----------
cd /tmp
BASE="$(basename "$DISTURL")"
echo ":: Downloading over HTTP: $DISTURL"
# Use IPv4 and retries for robustness in CI
curl -4 -fSLo "$BASE"        --retry 5 --retry-connrefused --retry-delay 2 "$DISTURL"
curl -4 -fSLo "${BASE}.md5"  --retry 5 --retry-connrefused --retry-delay 2 "${DISTURL}.md5"

# Require MD5 to proceed
if [[ ! -f "/tmp/${BASE}.md5" ]]; then
  echo "ERROR: MD5 checksum file missing for ${BASE}. Refusing to proceed."
  echo "       Expected at: ${DISTURL}.md5"
  exit 1
fi

echo ":: Verifying MD5 checksum ..."
md5sum -c "/tmp/${BASE}.md5"

###
# ---------- Extract rootfs into / ----------
echo ":: Extracting rootfs into ${MNT_ROOT} ..."
if [[ "$EXTRACTOR" == "bsdtar" ]]; then
  sudo bsdtar -xpf "/tmp/${BASE}" -C "$MNT_ROOT"
else
  # GNU tar fallback with xattrs/ACLs
  sudo tar --xattrs --xattrs-include='*' --acls -xpf "/tmp/${BASE}" -C "$MNT_ROOT"
fi

# Copy firmware/kernel from ext root /boot to FAT32 /boot (what Pi firmware reads)
echo ":: Syncing boot files ..."
sudo rsync -a "${MNT_ROOT}/boot/" "${MNT_BOOT}/"

###
# ---------- System configs for live env ----------
echo ":: Writing fstab, cmdline.txt, config.txt ..."
sudo tee "${MNT_ROOT}/etc/fstab" >/dev/null <<EOT
LABEL=ROOT  /      ${ROOTFS}  defaults,noatime  0 1
LABEL=BOOT  /boot  vfat       defaults          0 2
EOT

PARTUUID="$(sudo blkid -s PARTUUID -o value "$ROOT_PART")"
sudo tee "${MNT_BOOT}/cmdline.txt" >/dev/null <<EOT
console=serial0,115200 console=tty1 root=PARTUUID=${PARTUUID} rw rootwait fsck.repair=yes quiet systemd.unified_cgroup_hierarchy=1
EOT

sudo tee -a "${MNT_BOOT}/config.txt" >/dev/null <<'EOT'
# Live USB defaults (installer will adjust on the installed system)
gpu_mem=128
EOT

###
# ---------- Embed installer & autorun service ----------
echo ":: Installing autorun service and installer ..."
sudo install -m 0755 "$INSTALLER"   "${MNT_ROOT}/root/installer.sh"
sudo install -m 0755 "$AUTO_SCRIPT" "${MNT_ROOT}/root/auto-install.sh"
sudo install -m 0644 "$AUTO_SERVICE" "${MNT_ROOT}/etc/systemd/system/auto-install.service"
sudo mkdir -p "${MNT_ROOT}/etc/systemd/system/multi-user.target.wants"
sudo ln -sf /etc/systemd/system/auto-install.service \
           "${MNT_ROOT}/etc/systemd/system/multi-user.target.wants/auto-install.service"

###
## ---------- Cleanup and compress ----------
echo ":: Finalizing image ..."
sync
sudo umount "$MNT_BOOT" "$MNT_ROOT"
sudo losetup -d "$LOOPDEV"
rm -rf /tmp/piusb

echo ":: Compressing image ..."
xz -T0 -z -9 -c "$IMG" > "${OUTDIR}/${IMAGE_NAME}.img.xz"
