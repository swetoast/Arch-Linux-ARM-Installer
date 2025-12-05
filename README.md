# Arch Linux ARM Installer

This project provides a script that helps set up Arch Linux ARM on a drive such as an SD card, M.2 drive, or hard disk. It guides you through the process with a text-based interface where you choose the drive and the type of file system. After that, the script runs all steps automatically.

## What the script does

1. Shows you a list of available drives so you can pick the one you want to use.
2. Lets you choose the file system for the main partition (ext4, btrfs, or xfs).
3. Wipes and partitions the selected drive.
4. Formats the partitions (boot partition as FAT32, root partition with your chosen file system).
5. Downloads and installs Arch Linux ARM.
6. Removes the default boot files and replaces them with the Raspberry Pi Foundation kernel.
7. Creates an `fstab` file so the system knows how to mount the partitions.
8. Enters the new system and installs the tools needed for the chosen file system.
9. Cleans up and unmounts the drive.

## Requirements

- Run the script as root.
- Arch Linux system with `dialog`, `lsblk`, `sfdisk`, `mkfs.vfat`, `bsdtar`, `curl`, and `arch-chroot` installed.
- Internet connection to download Arch Linux ARM and the kernel package.

## How to use

1. Download the script and make it executable:
   ```bash
   chmod +x installer.sh
   ```
2. Run it as root:
   ```bash
   sudo ./installer.sh
   ```
3. Follow the on-screen prompts to select the drive and file system.
4. The script will handle the rest automatically.

## Notes

- The chosen drive will be completely wiped. Make sure you select the correct one.
- The script uses a text interface with uniform windows for a consistent experience.
- At the end, you will have a bootable Arch Linux ARM system prepared on your chosen drive.
