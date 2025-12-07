# Arch Linux ARM Installer (Raspberry Pi 4/5)

<p>
  <img src="https://github.com/user-attachments/assets/7974f2e2-a159-4d6b-ba08-9564e6b0e61b" alt="Arch Linux Logo" width="120" align="right" style="margin-left:15px;"/>
  This project provides a script that helps set up Arch Linux ARM on a drive such as an SD card, M.2 drive, or hard disk. It guides you through the process with a text-based interface where you choose the drive and the type of file system. After that, the script runs all steps automatically.
</p>

Source: https://archlinuxarm.org/platforms/armv8/broadcom/raspberry-pi-4

## What the script does

1. Shows you a list of available drives so you can pick the one you want to use.  
2. Lets you choose the file system for the main partition (ext4, btrfs, or xfs).  
3. Lets you choose the kernel flavor (linux‑rpi or linux‑rpi‑16k).  
4. Prompts for hostname, username, user password, root password, locale, and timezone.  
5. Prompts for networking setup (systemd‑networkd + systemd‑resolved or NetworkManager).  
6. Optionally prompts for Wi‑Fi SSID, password, and country code.  
7. Wipes and partitions the selected drive.  
8. Formats the partitions (boot partition as FAT32, root partition with your chosen file system).  
9. Downloads and installs Arch Linux ARM.  
10. Creates an `fstab` file so the system knows how to mount the partitions.  
11. Generates a correct Raspberry Pi 4/5 `cmdline.txt` using the root partition’s PARTUUID.  
12. Enters the new system and installs the selected kernel and its headers.  
13. Installs the tools needed for the chosen file system and `dosfstools`.  
14. Installs `sudo` and configures the wheel group in `/etc/sudoers`.  
15. Creates the user account, sets passwords, and enables systemd services for networking and time sync.  
16. If Wi‑Fi was configured, installs `iwd` (for systemd‑networkd) or `NetworkManager` + `iw`, sets the regulatory domain, and writes the Wi‑Fi configuration.  
17. Cleans up and unmounts the drive.

## Flowchart
<img width="587" height="2268" alt="image" src="https://github.com/user-attachments/assets/101d9a74-b3ef-4519-b52f-da9e44688c91" />

## Requirements

- Run the script as root.  
- Arch Linux system with `dialog`, `lsblk`, `sfdisk`, `mkfs.vfat`, `bsdtar`, `curl`, `arch-chroot`, `blkid`, `partprobe`, and `udevadm` installed.  
- For Wi‑Fi setup: `iwd` or `NetworkManager` + `iw` will be installed automatically if you choose Wi‑Fi.  


## How to use

1. Download the script and make it executable:
   ```bash
   chmod +x installer.sh
   ```
2. Run it as root:
   ```bash
   sudo ./installer.sh
   ```
3. Follow the on-screen prompts to select the drive, file system, kernel, hostname, user, passwords, locale, timezone, networking, and optionally Wi‑Fi SSID, password, and country code.  
4. The script will handle the rest automatically.  

## Notes

- The chosen drive will be completely wiped. Make sure you select the correct one.  
- The script uses a text interface with uniform windows for a consistent experience.  
- By the end, you’ll have a bootable Arch Linux ARM drive for Raspberry Pi 4/5 set up with your chosen kernel, user, network, and optional Wi‑Fi. The install works safely on the target drive, and you can turn on extras like remote access (SSH), easy name‑based access on your network (Avahi), a swap file, automatic storage upkeep, and simple boot settings like GPU memory and SPI/I²C.
