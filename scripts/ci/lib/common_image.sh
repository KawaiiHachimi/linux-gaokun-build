#!/usr/bin/env bash
set -euo pipefail

install_common_image_assets() {
  local rootfs_dir="$1"
  local gaokun_dir="$2"

  install -d \
    "$rootfs_dir/etc/modules-load.d" \
    "$rootfs_dir/etc/modprobe.d" \
    "$rootfs_dir/usr/local/share/gaokun"

  cp -a "$gaokun_dir/tools/image-assets/etc/modules-load.d/." \
    "$rootfs_dir/etc/modules-load.d/"
  cp -a "$gaokun_dir/tools/image-assets/etc/modprobe.d/." \
    "$rootfs_dir/etc/modprobe.d/"
  install -Dm644 \
    "$gaokun_dir/tools/image-assets/usr/local/share/gaokun/monitors.xml" \
    "$rootfs_dir/usr/local/share/gaokun/monitors.xml"
}

install_el2_efi_payloads() {
  local rootfs_dir="$1"
  local gaokun_dir="$2"

  install -d \
    "$rootfs_dir/boot/efi/EFI/systemd/drivers" \
    "$rootfs_dir/boot/efi/firmware"

  install -Dm644 "$gaokun_dir/tools/el2/slbounceaa64.efi" \
    "$rootfs_dir/boot/efi/EFI/systemd/drivers/slbounceaa64.efi"
  install -Dm644 "$gaokun_dir/tools/el2/qebspilaa64.efi" \
    "$rootfs_dir/boot/efi/EFI/systemd/drivers/qebspilaa64.efi"
  install -Dm644 "$gaokun_dir/tools/el2/tcblaunch.exe" \
    "$rootfs_dir/boot/efi/tcblaunch.exe"
  install -Dm644 "$rootfs_dir/lib/firmware/qcom/sc8280xp/HUAWEI/gaokun3/qcadsp8280.mbn" \
    "$rootfs_dir/boot/efi/firmware/qcom/sc8280xp/HUAWEI/gaokun3/qcadsp8280.mbn"
  install -Dm644 "$rootfs_dir/lib/firmware/qcom/sc8280xp/HUAWEI/gaokun3/qccdsp8280.mbn" \
    "$rootfs_dir/boot/efi/firmware/qcom/sc8280xp/HUAWEI/gaokun3/qccdsp8280.mbn"
  install -Dm644 "$rootfs_dir/lib/firmware/qcom/sc8280xp/HUAWEI/gaokun3/qcslpi8280.mbn" \
    "$rootfs_dir/boot/efi/firmware/qcom/sc8280xp/HUAWEI/gaokun3/qcslpi8280.mbn"
}
