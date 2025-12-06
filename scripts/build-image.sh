#!/usr/bin/env bash
# Build a Raspberry Pi AArch64 bootable image that auto-runs /root/installer.sh at first boot.
# - Downloads Arch Linux ARM (AArch64) rootfs via HTTP
# - Verifies integrity using MD5 only (no GPG)
# - Produces artifacts/<image>.img.xz
set -euo pipefail

###
# ---------- Config (override via env) ----------
IMAGE_NAME="${IMAGE_NAME:-rpi-live-archarm-${DATE:-$(date +%Y%m%d)}}"
IMAGE_SIZE_GB="${IMAGE_SIZE_GB:-4}"      # Total size of the image file
BOOT_MB="${BOOT_MB:-512}"                # FAT32 /boot size (set to 256 if you prefer; selective copy prevents overflow)
ROOTFS="${ROOTFS:-ext4}"                 # ext4 recommended for the live rootfs
DISTURL="${DISTURL:-http://os.archlinuxarm.org/os/ArchLinuxARM-rpi-aarch64-latest.tar.gz}"

# Repo paths (installer + autorun service/helpers)
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

# Tools on ubuntu-latest runners
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
  if has tar; then EXTRACTOR="tar"; else
    echo "Need either bsdtar (libarchive-tools) or GNU tar installed."; exit 1
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

# p1: FAT32 /boot (bootable), p2: ext4 /
echo ":: Partitioning image ..."
sfdisk --wipe always "$IMG" <<EOF
label: dos
label-id: 0x$(printf "%08x" $RANDOM)
device: $IMG
unit: sectors

${IMG}1 : start=2048, size=$((BOOT_MB*2048)), type=0x0c, bootable
${IMG}2 : start=$((BOOT_MB*2048+2048)), type=0x83
EOF

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
# ---------- Download & MD5 verify Arch Linux ARM (AArch64) rootfs ----------
cd /tmp
BASE="$(basename "$DISTURL")"
echo ":: Downloading over HTTP: $DISTURL"
curl -4 -fSLo "$BASE"        --retry 5 --retry-connrefused --retry-delay 2 "$DISTURL"
curl -4 -fSLo "${BASE}.md5"  --retry 5 --retry-connrefused --retry-delay 2 "${DISTURL}.md5"

if [[ ! -f "/tmp/${BASE}.md5" ]]; then
  echo "ERROR: MD5 checksum file missing for ${BASE}. Expected at: ${DISTURL}.md5"
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
  sudo tar --xattrs --xattrs-include='*' --acls -xpf "/tmp/${BASE}" -C "$MNT_ROOT"
fi

# Move/copy boot files to FAT32 /boot.
# Keep /boot small: exclude non-Pi DTBs, then add Pi broadcom DTBs + overlays.
echo ":: Syncing boot files ..."
sudo rsync -a --delete --exclude='dtbs/**' "${MNT_ROOT}/boot/" "${MNT_BOOT}/"
sudo mkdir -p "${MNT_BOOT}/dtbs/broadcom" "${MNT_BOOT}/overlays"
sudo rsync -a "${MNT_ROOT}/boot/dtbs/broadcom/" "${MNT_BOOT}/dtbs/broadcom/" || true
sudo rsync -a "${MNT_ROOT}/boot/overlays/"     "${MNT_BOOT}/overlays/"     || true

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
# ---------- Embed installer & autorun ----------
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
