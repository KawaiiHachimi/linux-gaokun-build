#!/usr/bin/env bash
set -euo pipefail

: "${GAOKUN_DIR:?missing GAOKUN_DIR}"
: "${WORKDIR:?missing WORKDIR}"
: "${KERN_SRC:?missing KERN_SRC}"
: "${KERN_OUT:?missing KERN_OUT}"
: "${ROOTFS_DIR:?missing ROOTFS_DIR}"

KREL="$(cat "$WORKDIR/kernel-release.txt")"
FW_REPO="${FW_REPO:-$GAOKUN_DIR/firmware}"

if [[ "$(uname -m)" == "aarch64" ]]; then
  CROSS_COMPILE=""
else
  CROSS_COMPILE="aarch64-linux-gnu-"
fi

sudo make -C "$KERN_SRC" O="$KERN_OUT" ARCH=arm64 CROSS_COMPILE="$CROSS_COMPILE" \
  INSTALL_MOD_PATH="$ROOTFS_DIR" modules_install
sudo rm -f "$ROOTFS_DIR/lib/modules/$KREL/build" "$ROOTFS_DIR/lib/modules/$KREL/source"

sudo mkdir -p "$ROOTFS_DIR/boot"
sudo cp "$KERN_OUT/arch/arm64/boot/Image" "$ROOTFS_DIR/boot/vmlinuz-$KREL"
sudo mkdir -p "$ROOTFS_DIR/boot/dtb-$KREL/qcom"
sudo cp "$KERN_OUT/arch/arm64/boot/dts/qcom/sc8280xp-huawei-gaokun3.dtb" \
  "$ROOTFS_DIR/boot/dtb-$KREL/qcom/"

test -d "$FW_REPO"
sudo mkdir -p "$ROOTFS_DIR/lib/firmware"
sudo cp -r "$FW_REPO"/. "$ROOTFS_DIR/lib/firmware/"

sudo mkdir -p \
  "$ROOTFS_DIR/usr/local/bin" \
  "$ROOTFS_DIR/etc/systemd/system" \
  "$ROOTFS_DIR/usr/share/alsa/ucm2/Qualcomm/sc8280xp"
sudo cp "$GAOKUN_DIR/tools/touchpad/huawei-tp-activate.py" "$ROOTFS_DIR/usr/local/bin/"
sudo cp "$GAOKUN_DIR/tools/touchpad/huawei-touchpad.service" "$ROOTFS_DIR/etc/systemd/system/"
sudo chmod +x "$ROOTFS_DIR/usr/local/bin/huawei-tp-activate.py"
sudo cp "$GAOKUN_DIR/tools/monitors/gdm-monitor-sync" "$ROOTFS_DIR/usr/local/bin/"
sudo cp "$GAOKUN_DIR/tools/monitors/gdm-monitor-sync.service" \
  "$ROOTFS_DIR/etc/systemd/system/"
sudo chmod +x "$ROOTFS_DIR/usr/local/bin/gdm-monitor-sync"
sudo cp "$GAOKUN_DIR/tools/bluetooth/patch-nvm-bdaddr.py" "$ROOTFS_DIR/usr/local/bin/"
sudo chmod +x "$ROOTFS_DIR/usr/local/bin/patch-nvm-bdaddr.py"
sudo cp "$GAOKUN_DIR/tools/audio/sc8280xp.conf" \
  "$ROOTFS_DIR/usr/share/alsa/ucm2/Qualcomm/sc8280xp/"
