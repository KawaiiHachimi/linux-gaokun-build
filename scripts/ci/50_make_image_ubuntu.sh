#!/usr/bin/env bash
set -euo pipefail

. "$(dirname "$0")/lib/common_image.sh"

: "${GAOKUN_DIR:?missing GAOKUN_DIR}"
: "${WORKDIR:?missing WORKDIR}"
: "${ROOTFS_DIR:?missing ROOTFS_DIR}"
: "${ARTIFACT_DIR:?missing ARTIFACT_DIR}"
: "${IMAGE_FILE:?missing IMAGE_FILE}"
: "${IMAGE_SIZE:?missing IMAGE_SIZE}"
: "${UBUNTU_RELEASE:?missing UBUNTU_RELEASE}"

BUILD_EL2="${BUILD_EL2:-false}"
KREL="$(cat "$WORKDIR/kernel-release.txt")"
KREL_EL2=""
if [[ "$BUILD_EL2" == "true" && -f "$WORKDIR/kernel-release-el2.txt" ]]; then
  KREL_EL2="$(cat "$WORKDIR/kernel-release-el2.txt")"
fi

EFI_END_MIB=1025
truncate -s "$IMAGE_SIZE" "$IMAGE_FILE"
parted -s "$IMAGE_FILE" mklabel gpt
parted -s "$IMAGE_FILE" mkpart EFI fat32 1MiB "${EFI_END_MIB}MiB"
parted -s "$IMAGE_FILE" set 1 esp on
parted -s "$IMAGE_FILE" mkpart rootfs ext4 "${EFI_END_MIB}MiB" 100%

LOOP="$(sudo losetup --show -fP "$IMAGE_FILE")"
sudo mkfs.vfat -F32 -n EFI "${LOOP}p1"
sudo mkfs.ext4 -L rootfs "${LOOP}p2"

EFI_UUID="$(sudo blkid -s UUID -o value "${LOOP}p1")"
ROOT_UUID="$(sudo blkid -s UUID -o value "${LOOP}p2")"

MNT=/mnt/ego-ubuntu
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

sudo rsync -aHAX --exclude='/proc/*' --exclude='/sys/*' --exclude='/dev/*' --exclude='/run/*' "$ROOTFS_DIR/" "$MNT/"
install_common_image_assets "$MNT" "$GAOKUN_DIR"

sudo tee "$MNT/etc/fstab" >/dev/null <<EOF
UUID=${ROOT_UUID}  /         ext4   errors=remount-ro,noatime  0  1
UUID=${EFI_UUID}   /boot/efi vfat   defaults,nofail,x-systemd.device-timeout=10s  0  2
EOF

sudo mount --bind /dev "$MNT/dev"
sudo mount --bind /dev/pts "$MNT/dev/pts"
sudo mount -t proc proc "$MNT/proc"
sudo mount -t sysfs sys "$MNT/sys"
sudo mount -t tmpfs tmpfs "$MNT/run"

sudo chroot "$MNT" /usr/bin/env KREL="$KREL" KREL_EL2="$KREL_EL2" BUILD_EL2="$BUILD_EL2" ROOT_UUID="$ROOT_UUID" /bin/bash -euxo pipefail <<'CHROOT_EOF'
echo "ubuntu" > /etc/hostname
id -u user >/dev/null 2>&1 || useradd -m -s /bin/bash -G sudo user
echo "user:user" | chpasswd
mkdir -p /etc/sudoers.d
echo "%sudo ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/sudo-nopasswd
chmod 440 /etc/sudoers.d/sudo-nopasswd
cat > /etc/default/locale <<'EOF'
LANG=zh_CN.UTF-8
LANGUAGE=zh_CN:en_US:en
LC_MESSAGES=zh_CN.UTF-8
EOF

rm -f /etc/resolv.conf
ln -s /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf

mkdir -p /var/lib/AccountsService/users
cat > /var/lib/AccountsService/users/user <<'EOF'
[User]
Language=zh_CN.UTF-8
EOF
cat > /var/lib/AccountsService/users/gdm <<'EOF'
[User]
Language=zh_CN.UTF-8
SystemAccount=true
EOF

install -d -m 0755 /home/user/.config
install -Dm644 /usr/local/share/gaokun/monitors.xml /home/user/.config/monitors.xml
chown -R user:user /home/user

install -d -m 1777 -o root -g root /tmp/.X11-unix

cat > /etc/systemd/system/gaokun-fix-x11-unix.service <<'EOF'
[Unit]
Description=Fix /tmp/.X11-unix ownership for Xwayland
After=gdm.service
Wants=gdm.service

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'mkdir -p /tmp/.X11-unix && chown root:root /tmp/.X11-unix && chmod 1777 /tmp/.X11-unix'

[Install]
WantedBy=graphical.target
EOF

systemctl enable gdm NetworkManager ssh huawei-touchpad.service \
  gaokun-fix-x11-unix.service gdm-monitor-sync.service || true

cat >> /etc/initramfs-tools/modules <<'MODEOF'
# Storage and USB
nvme
phy-qcom-qmp-pcie
phy-qcom-qmp-combo
phy-qcom-qmp-usb
phy-qcom-snps-femto-v2
usb-storage
uas
typec
# WiFi
pci-pwrctrl-pwrseq
ath11k
ath11k_pci
# Input
i2c-hid-of
MODEOF

mkdir -p /etc/initramfs-tools/hooks
cat > /etc/initramfs-tools/hooks/gaokun3-firmware <<'EOF'
#!/bin/sh
set -e

. /usr/share/initramfs-tools/hook-functions

copy_fw() {
    copy_file firmware "$1" || [ "$?" -eq 1 ]
}

copy_fw /lib/firmware/qcom/sc8280xp/HUAWEI/gaokun3/qcadsp8280.mbn
copy_fw /lib/firmware/qcom/sc8280xp/HUAWEI/gaokun3/qccdsp8280.mbn
copy_fw /lib/firmware/qcom/sc8280xp/HUAWEI/gaokun3/qcslpi8280.mbn
copy_fw /lib/firmware/qcom/sc8280xp/HUAWEI/gaokun3/audioreach-tplg.bin
EOF
chmod 0755 /etc/initramfs-tools/hooks/gaokun3-firmware

install -d /etc/kernel
cat > /etc/kernel/install.conf <<'EOF'
layout=bls
EOF

cat > /etc/kernel/cmdline <<EOF
root=UUID=$ROOT_UUID clk_ignore_unused pd_ignore_unused arm64.nopauth iommu.passthrough=0 iommu.strict=0 pcie_aspm.policy=powersupersave modprobe.blacklist=simpledrm efi=noruntime fbcon=rotate:1 usbhid.quirks=0x12d1:0x10b8:0x20000000 consoleblank=0 loglevel=4 psi=1
EOF

cat > /etc/kernel/devicetree <<'EOF'
qcom/sc8280xp-huawei-gaokun3.dtb
EOF

run_update_initramfs() {
  local krel="$1"
  local dtb="$2"

  printf 'qcom/%s\n' "$dtb" > /etc/kernel/devicetree
  update-initramfs -c -k "$krel"
}

run_update_initramfs "$KREL" "sc8280xp-huawei-gaokun3.dtb"
if [[ "$BUILD_EL2" == "true" && -n "$KREL_EL2" ]]; then
  run_update_initramfs "$KREL_EL2" "sc8280xp-huawei-gaokun3-el2.dtb"
fi

rm -f /etc/machine-id
systemd-machine-id-setup
MACHINE_ID="$(cat /etc/machine-id)"

bootctl --no-variables --esp-path=/boot/efi install

run_kernel_install() {
  local krel="$1"
  local image="$2"
  local initrd="$3"
  local dtb="$4"
  local cmdline="$5"
  local conf_root

  conf_root="$(mktemp -d)"
  cat > "$conf_root/install.conf" <<'EOF'
layout=bls
EOF
  printf '%s\n' "$cmdline" > "$conf_root/cmdline"
  printf 'qcom/%s\n' "$dtb" > "$conf_root/devicetree"

  kernel-install --entry-token=machine-id remove "$krel" || true
  KERNEL_INSTALL_CONF_ROOT="$conf_root" \
    kernel-install --verbose --make-entry-directory=yes --entry-token=machine-id add \
    "$krel" "$image" "$initrd"
  rm -rf "$conf_root"
}

BASE_CMDLINE="$(cat /etc/kernel/cmdline)"
run_kernel_install \
  "$KREL" \
  "/boot/vmlinuz-$KREL" \
  "/boot/initrd.img-$KREL" \
  "sc8280xp-huawei-gaokun3.dtb" \
  "$BASE_CMDLINE"

if [[ "$BUILD_EL2" == "true" && -n "$KREL_EL2" ]]; then
  EL2_CMDLINE="${BASE_CMDLINE}"
  run_kernel_install \
    "$KREL_EL2" \
    "/boot/vmlinuz-$KREL_EL2" \
    "/boot/initrd.img-$KREL_EL2" \
    "sc8280xp-huawei-gaokun3-el2.dtb" \
    "$EL2_CMDLINE"
fi

cat > /boot/efi/loader/loader.conf <<EOF
default ${MACHINE_ID}-${KREL}.conf
timeout 5
console-mode keep
editor no
EOF
CHROOT_EOF

if [[ "$BUILD_EL2" == "true" && -n "$KREL_EL2" ]]; then
  install_el2_efi_payloads "$MNT" "$GAOKUN_DIR"
fi

sync

trap - EXIT
cleanup
