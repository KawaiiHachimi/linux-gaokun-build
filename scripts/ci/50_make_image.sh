#!/usr/bin/env bash
set -euo pipefail

: "${WORKDIR:?missing WORKDIR}"
: "${ROOTFS_DIR:?missing ROOTFS_DIR}"
: "${ARTIFACT_DIR:?missing ARTIFACT_DIR}"
: "${IMAGE_FILE:?missing IMAGE_FILE}"
: "${IMAGE_SIZE:?missing IMAGE_SIZE}"

KREL="$(cat "$WORKDIR/kernel-release.txt")"

truncate -s "$IMAGE_SIZE" "$IMAGE_FILE"
parted -s "$IMAGE_FILE" mklabel gpt
parted -s "$IMAGE_FILE" mkpart EFI fat32 1MiB 256MiB
parted -s "$IMAGE_FILE" set 1 esp on
parted -s "$IMAGE_FILE" mkpart rootfs ext4 256MiB 100%

LOOP="$(sudo losetup --show -fP "$IMAGE_FILE")"
sudo mkfs.vfat -F32 -n EFI "${LOOP}p1"
sudo mkfs.ext4 -L rootfs "${LOOP}p2"

EFI_UUID="$(sudo blkid -s UUID -o value "${LOOP}p1")"
ROOT_UUID="$(sudo blkid -s UUID -o value "${LOOP}p2")"

MNT=/mnt/ego-fedora
cleanup() {
  set +e
  sudo umount "$MNT/dev/pts" 2>/dev/null || true
  sudo umount "$MNT/boot/efi" 2>/dev/null || true
  sudo umount "$MNT/dev" 2>/dev/null || true
  sudo umount "$MNT/proc" 2>/dev/null || true
  sudo umount "$MNT/sys" 2>/dev/null || true
  sudo umount "$MNT/run" 2>/dev/null || true
  sudo umount "$MNT" 2>/dev/null || true
  sudo losetup -d "$LOOP" 2>/dev/null || true
}
trap cleanup EXIT

sudo mkdir -p "$MNT"
sudo mount "${LOOP}p2" "$MNT"
sudo mkdir -p "$MNT/boot/efi"
sudo mount "${LOOP}p1" "$MNT/boot/efi"

sudo rsync -aHAX "$ROOTFS_DIR/" "$MNT/"

sudo tee "$MNT/etc/fstab" >/dev/null <<EOF
UUID=${ROOT_UUID}  /         ext4   defaults,noatime  0  1
UUID=${EFI_UUID}   /boot/efi vfat   defaults          0  2
EOF

sudo mount --bind /dev "$MNT/dev"
sudo mount --bind /dev/pts "$MNT/dev/pts"
sudo mount -t proc proc "$MNT/proc"
sudo mount -t sysfs sys "$MNT/sys"
sudo mount -t tmpfs tmpfs "$MNT/run"

sudo chroot "$MNT" /usr/bin/env KREL="$KREL" /bin/bash -euxo pipefail <<'CHROOT_EOF'
echo "fedora" > /etc/hostname
id -u user >/dev/null 2>&1 || useradd -m -s /bin/bash -G wheel user
echo "user:user" | chpasswd
mkdir -p /etc/sudoers.d
echo "%wheel ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/wheel-nopasswd
chmod 440 /etc/sudoers.d/wheel-nopasswd

systemctl enable gdm NetworkManager sshd huawei-touchpad.service || true

mkdir -p /etc/modules-load.d
echo -e "pci-pwrctrl-pwrseq\nath11k_pci" > /etc/modules-load.d/wifi.conf
echo "btqca" > /etc/modules-load.d/bluetooth.conf
echo -e "panel-himax-hx83121a\nmsm\nhid_multitouch" > /etc/modules-load.d/display.conf
echo -e "huawei-gaokun-ec\nhuawei-gaokun-battery\nucsi_huawei_gaokun" > /etc/modules-load.d/battery.conf

cat > /etc/dracut.conf.d/matebook.conf <<MODEOF
hostonly="no"
add_drivers+=" nvme phy-qcom-qmp-pcie phy-qcom-qmp-combo phy-qcom-qmp-usb phy-qcom-snps-femto-v2 usb-storage uas typec panel-himax-hx83121a msm i2c-hid-of "
install_items+=" /lib/firmware/qcom/a660_sqe.fw /lib/firmware/qcom/a660_gmu.bin /lib/firmware/qcom/sc8280xp/HUAWEI/gaokun3/* "
MODEOF

dracut --force --kver "$KREL"

cat > /etc/default/grub <<GRUBEOF
GRUB_DEFAULT=saved
GRUB_TIMEOUT=5
GRUB_DISTRIBUTOR="Fedora"
GRUB_ENABLE_BLSCFG=false
GRUB_CMDLINE_LINUX="rhgb clk_ignore_unused pd_ignore_unused arm64.nopauth iommu.passthrough=0 iommu.strict=0 pcie_aspm.policy=powersupersave modprobe.blacklist=simpledrm efi=noruntime fbcon=rotate:1 usbhid.quirks=0x12d1:0x10b8:0x20000000 consoleblank=0 loglevel=4"
GRUB_DEFAULT_DTB="qcom/sc8280xp-huawei-gaokun3.dtb"
GRUBEOF

grub2-install --target=arm64-efi --efi-directory=/boot/efi --boot-directory=/boot --removable --force
grub2-mkconfig -o /boot/grub2/grub.cfg

ROOT_UUID="$(blkid -s UUID -o value /dev/disk/by-label/rootfs)"
mkdir -p /boot/efi/EFI/BOOT /boot/efi/EFI/fedora
cat > /boot/efi/EFI/BOOT/grub.cfg <<EOF
search --no-floppy --fs-uuid --set=root ${ROOT_UUID}
set prefix=(\$root)/boot/grub2
configfile (\$root)/boot/grub2/grub.cfg
EOF
cp /boot/efi/EFI/BOOT/grub.cfg /boot/efi/EFI/fedora/grub.cfg

grep -n "devicetree" /boot/grub2/grub.cfg
CHROOT_EOF

sync
sudo cp "$MNT/boot/grub2/grub.cfg" "$ARTIFACT_DIR/grub.cfg"
sudo cp "$MNT/boot/efi/EFI/BOOT/grub.cfg" "$ARTIFACT_DIR/efi-bridge-grub.cfg"

trap - EXIT
cleanup
