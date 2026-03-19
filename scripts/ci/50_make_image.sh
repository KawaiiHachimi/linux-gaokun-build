#!/usr/bin/env bash
set -euo pipefail

: "${GAOKUN_DIR:?missing GAOKUN_DIR}"
: "${WORKDIR:?missing WORKDIR}"
: "${KERN_SRC:?missing KERN_SRC}"
: "${KERN_OUT:?missing KERN_OUT}"
: "${IMAGE_FILE:?missing IMAGE_FILE}"

KREL="$(cat "$WORKDIR/kernel-release.txt")"

if [[ ! -f "$IMAGE_FILE" ]]; then
  echo "Image file not found: $IMAGE_FILE" >&2
  exit 1
fi

if [[ "$(uname -m)" == "aarch64" ]]; then
  CROSS_COMPILE=""
else
  CROSS_COMPILE="aarch64-linux-gnu-"
fi

LOOP="$(sudo losetup --show -fP "$IMAGE_FILE")"
EFI_PART="${LOOP}p1"
BOOT_PART="${LOOP}p2"
ROOT_PART="${LOOP}p3"
MNT=/mnt/ego-fedora

cleanup() {
  set +e
  sudo umount "$MNT/dev/pts" 2>/dev/null || true
  sudo umount "$MNT/boot/efi" 2>/dev/null || true
  sudo umount "$MNT/boot" 2>/dev/null || true
  sudo umount "$MNT/home" 2>/dev/null || true
  sudo umount "$MNT/var" 2>/dev/null || true
  sudo umount "$MNT/dev" 2>/dev/null || true
  sudo umount "$MNT/proc" 2>/dev/null || true
  sudo umount "$MNT/sys" 2>/dev/null || true
  sudo umount "$MNT/run" 2>/dev/null || true
  sudo umount "$MNT" 2>/dev/null || true
  sudo losetup -d "$LOOP" 2>/dev/null || true
}
trap cleanup EXIT

sudo mkdir -p "$MNT"
if sudo mount -o subvol=root "$ROOT_PART" "$MNT" 2>/dev/null; then
  sudo mkdir -p "$MNT/home" "$MNT/var"
  sudo mount -o subvol=home "$ROOT_PART" "$MNT/home"
  sudo mount -o subvol=var "$ROOT_PART" "$MNT/var"
else
  sudo mount "$ROOT_PART" "$MNT"
fi

sudo mkdir -p "$MNT/boot" "$MNT/boot/efi"
sudo mount "$BOOT_PART" "$MNT/boot"
sudo mount "$EFI_PART" "$MNT/boot/efi"

sudo mount --bind /dev "$MNT/dev"
sudo mount --bind /dev/pts "$MNT/dev/pts"
sudo mount -t proc proc "$MNT/proc"
sudo mount -t sysfs sys "$MNT/sys"
sudo mount -t tmpfs tmpfs "$MNT/run"

sudo make -C "$KERN_SRC" O="$KERN_OUT" ARCH=arm64 CROSS_COMPILE="$CROSS_COMPILE" \
  INSTALL_MOD_PATH="$MNT" modules_install
sudo rm -f "$MNT/lib/modules/$KREL/build" "$MNT/lib/modules/$KREL/source"

sudo cp "$KERN_OUT/arch/arm64/boot/Image" "$MNT/boot/vmlinuz-$KREL"
sudo mkdir -p "$MNT/boot/dtb-$KREL/qcom"
sudo cp "$KERN_OUT/arch/arm64/boot/dts/qcom/sc8280xp-huawei-gaokun3.dtb" \
  "$MNT/boot/dtb-$KREL/qcom/"

test -d "$GAOKUN_DIR/firmware"
sudo mkdir -p \
  "$MNT/usr/local/bin" \
  "$MNT/etc/systemd/system" \
  "$MNT/usr/share/alsa/ucm2/Qualcomm/sc8280xp"
sudo cp "$GAOKUN_DIR/tools/touchpad/huawei-tp-activate.py" "$MNT/usr/local/bin/"
sudo cp "$GAOKUN_DIR/tools/touchpad/huawei-touchpad.service" "$MNT/etc/systemd/system/"
sudo chmod +x "$MNT/usr/local/bin/huawei-tp-activate.py"
sudo cp "$GAOKUN_DIR/tools/bluetooth/patch-nvm-bdaddr.py" "$MNT/usr/local/bin/"
sudo chmod +x "$MNT/usr/local/bin/patch-nvm-bdaddr.py"
sudo cp "$GAOKUN_DIR/tools/audio/sc8280xp.conf" \
  "$MNT/usr/share/alsa/ucm2/Qualcomm/sc8280xp/"

sudo chroot "$MNT" /usr/bin/env KREL="$KREL" /bin/bash -euxo pipefail <<'CHROOT_SETUP_EOF'
echo "fedora" > /etc/hostname
id -u user >/dev/null 2>&1 || useradd -m -s /bin/bash -G wheel user
echo "user:user" | chpasswd
mkdir -p /etc/sudoers.d
echo "%wheel ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/wheel-nopasswd
chmod 440 /etc/sudoers.d/wheel-nopasswd

mkdir -p /home/user/.config
cat > /home/user/.config/monitors.xml <<'EOF'
<monitors version="2">
    <configuration>
        <layoutmode>logical</layoutmode>
        <logicalmonitor>
            <x>0</x>
            <y>0</y>
            <scale>1.6666666269302368</scale>
            <primary>yes</primary>
            <transform>
                <rotation>right</rotation>
                <flipped>no</flipped>
            </transform>
            <monitor>
                <monitorspec>
                    <connector>DSI-1</connector>
                    <vendor>unknown</vendor>
                    <product>unknown</product>
                    <serial>unknown</serial>
                </monitorspec>
                <mode>
                    <width>1600</width>
                    <height>2560</height>
                    <rate>59.694</rate>
                </mode>
            </monitor>
        </logicalmonitor>
    </configuration>
</monitors>
EOF
chown user:user /home/user/.config/monitors.xml

GDM_DIR="/var/lib/gdm/seat0/config"
mkdir -p "$GDM_DIR"
cp /home/user/.config/monitors.xml "$GDM_DIR/monitors.xml"
chown --reference="$GDM_DIR" "$GDM_DIR/monitors.xml"

systemctl enable gdm NetworkManager sshd huawei-touchpad.service || true

mkdir -p /etc/modules-load.d
echo -e "pci-pwrctrl-pwrseq\nath11k_pci" > /etc/modules-load.d/wifi.conf
echo "btqca" > /etc/modules-load.d/bluetooth.conf
echo -e "panel-himax-hx83121a\nmsm\nhid_multitouch" > /etc/modules-load.d/display.conf
echo -e "lpasscc_sc8280xp\nsnd-soc-sc8280xp" > /etc/modules-load.d/audio.conf
echo -e "huawei-gaokun-ec\nhuawei-gaokun-battery\nucsi_huawei_gaokun" > /etc/modules-load.d/battery.conf

mkdir -p /etc/modprobe.d
echo "softdep pinctrl_sc8280xp_lpass_lpi pre: lpasscc_sc8280xp" > /etc/modprobe.d/audio-deps.conf

mapfile -t STOCK_KERNEL_PKGS < <(rpm -qa | grep -E '^kernel(-(core|modules|modules-core|modules-extra|uki-virt|uki-virt-addons))?-[0-9]' || true)
if (( ${#STOCK_KERNEL_PKGS[@]} > 0 )); then
  dnf remove -y "${STOCK_KERNEL_PKGS[@]}" || rpm -e --nodeps "${STOCK_KERNEL_PKGS[@]}" || true
fi

if rpm -q linux-firmware >/dev/null 2>&1; then
  dnf remove -y linux-firmware || rpm -e --nodeps linux-firmware || true
fi

find /boot -maxdepth 1 -type f \
  \( -name 'vmlinuz-*' -o -name 'initramfs-*.img' -o -name 'System.map-*' -o -name 'config-*' -o -name '.vmlinuz-*.hmac' \) \
  ! -name "vmlinuz-$KREL" \
  -delete
find /boot -maxdepth 1 -type d -name 'dtb-*' ! -name "dtb-$KREL" -exec rm -rf {} +
find /lib/modules -mindepth 1 -maxdepth 1 -type d ! -name "$KREL" -exec rm -rf {} +
rm -f /boot/loader/entries/*.conf

rm -rf /lib/firmware/*
mkdir -p /lib/firmware

cat > /etc/dracut.conf.d/matebook.conf <<EOF
hostonly="no"
add_drivers+=" btrfs nvme phy-qcom-qmp-pcie phy-qcom-qmp-combo phy-qcom-qmp-usb phy-qcom-snps-femto-v2 usb-storage uas typec pci-pwrctrl-pwrseq ath11k ath11k_pci panel-himax-hx83121a msm i2c-hid-of lpasscc_sc8280xp snd-soc-sc8280xp pinctrl_sc8280xp_lpass_lpi "
EOF
CHROOT_SETUP_EOF

sudo cp -r "$GAOKUN_DIR/firmware"/. "$MNT/lib/firmware/"

sudo chroot "$MNT" /usr/bin/env KREL="$KREL" /bin/bash -euxo pipefail <<'CHROOT_BOOT_EOF'
dracut --force "/boot/initramfs-$KREL.img" "$KREL"

CURRENT_OPTIONS="rhgb quiet root=UUID=$(findmnt -no UUID /) rootflags=subvol=root"
MACHINE_ID="$(cat /etc/machine-id)"
mkdir -p /boot/loader/entries
cat > "/boot/loader/entries/${MACHINE_ID}-${KREL}.conf" <<EOF
title Fedora Linux (${KREL}) 44 (Workstation Edition) - gaokun3
version ${KREL}
linux /vmlinuz-${KREL}
initrd /initramfs-${KREL}.img
options ${CURRENT_OPTIONS} clk_ignore_unused pd_ignore_unused arm64.nopauth iommu.passthrough=0 iommu.strict=0 pcie_aspm.policy=powersupersave modprobe.blacklist=simpledrm efi=noruntime fbcon=rotate:1 usbhid.quirks=0x12d1:0x10b8:0x20000000 consoleblank=0 loglevel=4 psi=1
devicetree /dtb-${KREL}/qcom/sc8280xp-huawei-gaokun3.dtb
grub_users \$grub_users
grub_arg --unrestricted
grub_class fedora
EOF

grub2-mkconfig -o /boot/grub2/grub.cfg
grub2-set-default 0 || true
grep -n "sc8280xp-huawei-gaokun3.dtb" /boot/loader/entries/*.conf
CHROOT_BOOT_EOF

sync

trap - EXIT
cleanup
