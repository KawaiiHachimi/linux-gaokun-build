English | [中文](dual_boot_guide_zh.md)

# Windows + Linux Dual Boot Installation and Boot Configuration (DG + systemd-boot)

This document uses `systemd-boot` as an example to take over the default boot entry, enabling Windows / Linux dual boot selection.

## 1. Preparation

- Tools: DiskGenius (referred to as DG below)
- Files:
	- Extracted virtual disk image such as `ubuntu-26.04-gaokun3.img`
- UEFI Settings: Press F2 at startup, set Secure Boot to Disable in UEFI menu, save and reboot

## 2. Backup Virtual Disk rootfs and Restore to Internal Drive

1. In DG, select "Disk" -> "Open Disk Image File" to mount the virtual disk image first.
2. Find the Linux rootfs partition in the image, right-click and use "Backup Partition to Image File", select "Full Backup" as backup type, export as `rootfs.pmf`.
3. Right-click on the internal drive partition and use "Split Partition", create a new partition at the end of the partition, at least 12G, as the Linux rootfs target partition.
4. Execute "Restore Partition from Image File" on this new partition, select the `rootfs.pmf` created earlier, complete the rootfs write.
5. Verify that the "Volume UUID" of the restored partition matches the "Volume UUID" of the rootfs partition in the virtual disk image.

## 3. Sync EFI Partition Contents

1. Open the EFI partition file browser of the virtual disk image in DG.
2. Copy all files and folders from the image EFI partition root directory to a designated location.
3. Open the internal drive EFI partition file browser, first backup `\EFI\BOOT\BOOTAA64.EFI` as `\EFI\BOOT\BOOTAA64.EFI.bak`.
4. Drag all contents from the designated location (image EFI partition root) directly into the internal drive EFI partition root to overwrite.

After completion, the internal drive EFI partition root should typically contain:
- `EFI`
- `loader`
- `<machine-id>` or other `kernel-install` entry-token directory
- `firmware` (if image includes EL2)
- `tcblaunch.exe` (if image includes EL2)

The `EFI` directory should typically contain:
- `BOOT`
- `systemd`
- `Microsoft`

Windows can generally be auto-detected by `systemd-boot`, so no additional modification to Windows boot entry is needed.

Notes:

- The images now use standard `kernel-install` + BLS layout, no longer using fixed `gaokun3/<distro>/<kernel-release>/...` directories.
- By default, Gaokun3 images use `--entry-token=machine-id`, so the ESP typically contains `/loader/entries/<machine-id>-<kernel-release>.conf`, and `/<machine-id>/<kernel-release>/linux|initrd|*.dtb` directory structure.
- If the distribution or user has changed `kernel-install --entry-token`, the top-level directory name may not be `machine-id`, but will still follow the same BLS rules.

## 4. Modify EFI Partition Volume Serial Number

1. In DG, view the virtual disk image EFI partition volume serial number (e.g., `ABCD-1234`), right-click to copy.
2. Right-click the internal drive EFI partition, select "Modify Volume Serial Number", enter the copied serial number, note to remove the `-` in the middle.
3. Verify that its volume serial number has been changed to match the virtual disk image EFI partition.

## 5. Reboot Verification

- After reboot, you should enter the `systemd-boot` boot menu.
- The menu allows selecting Windows or Linux distribution to boot.
- After entering the Linux distribution, you can use gnome-disk or other disk tools, or commands like growpart/resize2fs/btrfs to expand the rootfs partition and filesystem to the remaining space.

## Additional Notes (EL2 Optional)

If the image already includes the required EL2 files, after completing this guide, simply select the EL2 menu entry in `systemd-boot` to boot. See [el2_kvm_guide_en.md](el2_kvm_guide_en.md) for details.

## Common Reminders

- If the boot menu does not appear, first check:
	- Whether `\EFI\BOOT\BOOTAA64.EFI` has been overwritten by `systemd-boot` from the image
	- Whether the EFI partition root directory structure is complete
	- Whether `\loader\entries\<entry-token>-<kernel-release>.conf` exists
	- Whether `\<entry-token>\<kernel-release>\` contains `linux`, `initrd`, `*.dtb`
	- Whether EL2 required `firmware\`, `tcblaunch.exe`, `\EFI\systemd\drivers\` are complete
	- Whether EFI volume serial number matches the image
- If Linux boots but `/boot/efi` is not properly mounted, check if the UUID of the EFI partition in `/etc/fstab` matches the internal drive EFI partition UUID.
- If you accidentally cause boot failure, you can boot Linux from USB storage device or WinPE (recommended: [CNBYDJ PE](https://bydjpe.winos.me)) to mount the internal drive EFI partition and rollback using the previously backed up `BOOTAA64.EFI.bak`.
