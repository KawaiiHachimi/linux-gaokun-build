#!/usr/bin/env bash
set -euo pipefail

: "${GAOKUN_DIR:?missing GAOKUN_DIR}"
: "${WORKDIR:?missing WORKDIR}"
: "${ARTIFACT_DIR:?missing ARTIFACT_DIR}"
: "${KERNEL_TAG:?missing KERNEL_TAG}"
: "${PACKAGE_RELEASE_TAG:?missing PACKAGE_RELEASE_TAG}"

BUILD_EL2="${BUILD_EL2:-false}"
KERN_SRC_BASE="${KERN_SRC_BASE:-${KERN_SRC:-}}"
KERN_OUT="${KERN_OUT:-}"
KERN_SRC_EL2="${KERN_SRC_EL2:-${KERN_SRC:-}}"
KERN_OUT_EL2="${KERN_OUT_EL2:-}"

: "${KERN_SRC_BASE:?missing KERN_SRC_BASE}"
: "${KERN_OUT:?missing KERN_OUT}"

BASE_KREL="$(cat "$WORKDIR/kernel-release.txt")"
EL2_KREL=""
if [[ -f "$WORKDIR/kernel-release-el2.txt" ]]; then
  EL2_KREL="$(cat "$WORKDIR/kernel-release-el2.txt")"
fi

RPM_TOPDIR="$WORKDIR/rpmbuild"
BUILDROOT_DIR="$WORKDIR/package-buildroots"
RPM_BUILD_JOBS="${RPM_BUILD_JOBS:-$(nproc)}"
RPM_PAYLOAD_LEVEL="${RPM_PAYLOAD_LEVEL:-2}"
RPM_PAYLOAD_MACRO="w${RPM_PAYLOAD_LEVEL}T${RPM_BUILD_JOBS}.xzdio"
FIRMWARE_RPM_VERSION="${FIRMWARE_RPM_VERSION:-$(date -u +%Y%m%d)}"
BUILD_TIME_UTC="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

mkdir -p \
  "$ARTIFACT_DIR" \
  "$RPM_TOPDIR/BUILD" \
  "$RPM_TOPDIR/BUILDROOT" \
  "$RPM_TOPDIR/RPMS" \
  "$RPM_TOPDIR/SOURCES" \
  "$RPM_TOPDIR/SPECS" \
  "$RPM_TOPDIR/SRPMS"

prepare_tarball() {
  local tar_name="$1"
  local source_dir="$2"
  tar -C "$source_dir" -czf "$RPM_TOPDIR/SOURCES/$tar_name" .
}

render_spec_template() {
  local template_path="$1"
  local output_path="$2"
  shift 2

  local sed_args=()
  while [[ $# -gt 0 ]]; do
    sed_args+=(-e "s|$1|$2|g")
    shift 2
  done

  sed "${sed_args[@]}" "$template_path" >"$output_path"
}

build_variant_rpms() {
  local variant_key="$1"
  local pkg_suffix="$2"
  local src_dir="$3"
  local out_dir="$4"
  local krel="$5"
  local dtb_name="$6"

  local kernel_pkg="kernel-gaokun3${pkg_suffix}"
  local modules_pkg="kernel-modules-gaokun3${pkg_suffix}"
  local devel_pkg="kernel-devel-gaokun3${pkg_suffix}"
  local krel_version="${krel//-/_}"
  local dracut_conf="90-gaokun3-${krel}.conf"
  local kernel_stage="$BUILDROOT_DIR/${kernel_pkg}"
  local modules_stage="$BUILDROOT_DIR/${modules_pkg}"
  local modules_raw_stage="$BUILDROOT_DIR/${modules_pkg}-raw"
  local devel_stage="$BUILDROOT_DIR/${devel_pkg}"
  local devel_tree="$devel_stage/usr/src/kernels/$krel"
  local kernel_tar="${kernel_pkg}.tar.gz"
  local modules_tar="${modules_pkg}.tar.gz"
  local devel_tar="${devel_pkg}.tar.gz"

  rm -rf "$kernel_stage" "$modules_stage" "$modules_raw_stage" "$devel_stage"
  mkdir -p "$kernel_stage/boot/dtb-$krel/qcom" "$kernel_stage/usr/lib/dracut/dracut.conf.d" \
    "$modules_stage/usr/lib" "$modules_stage/lib" "$devel_tree" \
    "$devel_stage/usr/lib/modules/$krel"

  install -Dm644 "$out_dir/arch/arm64/boot/Image" \
    "$kernel_stage/boot/vmlinuz-$krel"
  install -Dm644 "$out_dir/System.map" \
    "$kernel_stage/boot/System.map-$krel"
  install -Dm644 "$out_dir/.config" \
    "$kernel_stage/boot/config-$krel"
  install -Dm644 "$out_dir/arch/arm64/boot/dts/qcom/$dtb_name" \
    "$kernel_stage/boot/dtb-$krel/qcom/$dtb_name"
  cat > "$kernel_stage/usr/lib/dracut/dracut.conf.d/$dracut_conf" <<'EOF'
hostonly="no"
add_drivers+=" btrfs nvme phy-qcom-qmp-pcie phy-qcom-qmp-combo phy-qcom-qmp-usb phy-qcom-snps-femto-v2 usb-storage uas typec pci-pwrctrl-pwrseq ath11k ath11k_pci i2c-hid-of lpasscc_sc8280xp snd-soc-sc8280xp pinctrl_sc8280xp_lpass_lpi "
install_items+=" /lib/firmware/qcom/sc8280xp/HUAWEI/gaokun3/qcslpi8280.mbn /lib/firmware/qcom/sc8280xp/HUAWEI/gaokun3/qcadsp8280.mbn /lib/firmware/qcom/sc8280xp/HUAWEI/gaokun3/qccdsp8280.mbn /lib/firmware/qcom/sc8280xp/SC8280XP-HUAWEI-GAOKUN3-tplg.bin /lib/firmware/qcom/sc8280xp/HUAWEI/gaokun3/audioreach-tplg.bin "
EOF

  make -C "$src_dir" O="$out_dir" ARCH=arm64 INSTALL_MOD_PATH="$modules_raw_stage" modules_install
  mv "$modules_raw_stage/lib/modules" "$modules_stage/usr/lib/"
  rm -rf "$modules_raw_stage"
  install -Dm644 "$out_dir/arch/arm64/boot/dts/qcom/$dtb_name" \
    "$modules_stage/usr/lib/modules/$krel/dtb/qcom/$dtb_name"
  rm -f "$modules_stage/usr/lib/modules/$krel/build" \
        "$modules_stage/usr/lib/modules/$krel/source"
  ln -s ../usr/lib/modules "$modules_stage/lib/modules"
  depmod -b "$modules_stage" -a "$krel"
  rm -f "$modules_stage/lib/modules"
  rmdir "$modules_stage/lib"

  rsync -a --delete --exclude '.git' "$src_dir/" "$devel_tree/"
  rsync -a "$out_dir/" "$devel_tree/"
  find "$devel_tree" -type f \
    \( -name '*.o' -o -name '*.ko' -o -name '*.a' -o -name '*.cmd' -o -name '*.mod' -o -name '*.mod.c' \) \
    -delete
  find "$devel_tree" -type l \( -name build -o -name source \) -delete
  ln -s "../../../src/kernels/$krel" "$devel_stage/usr/lib/modules/$krel/build"
  ln -s "../../../src/kernels/$krel" "$devel_stage/usr/lib/modules/$krel/source"

  prepare_tarball "$kernel_tar" "$kernel_stage"
  prepare_tarball "$modules_tar" "$modules_stage"
  prepare_tarball "$devel_tar" "$devel_stage"

  render_spec_template \
    "$GAOKUN_DIR/packaging/kernel-gaokun3.spec.in" \
    "$RPM_TOPDIR/SPECS/${kernel_pkg}.spec" \
    "@PKG_NAME@" "$kernel_pkg" \
    "@SOURCE_NAME@" "$kernel_tar" \
    "@KREL_VERSION@" "$krel_version" \
    "@KREL@" "$krel" \
    "@DTB_FILE@" "$dtb_name"

  render_spec_template \
    "$GAOKUN_DIR/packaging/kernel-modules-gaokun3.spec.in" \
    "$RPM_TOPDIR/SPECS/${modules_pkg}.spec" \
    "@PKG_NAME@" "$modules_pkg" \
    "@SOURCE_NAME@" "$modules_tar" \
    "@KREL_VERSION@" "$krel_version" \
    "@KREL@" "$krel" \
    "@REQUIRES_KERNEL@" "$kernel_pkg"

  render_spec_template \
    "$GAOKUN_DIR/packaging/kernel-devel-gaokun3.spec.in" \
    "$RPM_TOPDIR/SPECS/${devel_pkg}.spec" \
    "@PKG_NAME@" "$devel_pkg" \
    "@SOURCE_NAME@" "$devel_tar" \
    "@KREL_VERSION@" "$krel_version" \
    "@KREL@" "$krel" \
    "@REQUIRES_MODULES@" "$modules_pkg"

  rpmbuild "${rpmbuild_common_args[@]}" -bb "$RPM_TOPDIR/SPECS/${kernel_pkg}.spec"
  rpmbuild "${rpmbuild_common_args[@]}" -bb "$RPM_TOPDIR/SPECS/${modules_pkg}.spec"
  rpmbuild "${rpmbuild_common_args[@]}" -bb "$RPM_TOPDIR/SPECS/${devel_pkg}.spec"

  local kernel_rpm_path
  local modules_rpm_path
  local devel_rpm_path
  kernel_rpm_path="$(find "$RPM_TOPDIR/RPMS" -name "${kernel_pkg}-*.rpm" -print -quit)"
  modules_rpm_path="$(find "$RPM_TOPDIR/RPMS" -name "${modules_pkg}-*.rpm" -print -quit)"
  devel_rpm_path="$(find "$RPM_TOPDIR/RPMS" -name "${devel_pkg}-*.rpm" -print -quit)"

  local kernel_rpm_name="$(basename "$kernel_rpm_path")"
  local modules_rpm_name="$(basename "$modules_rpm_path")"
  local devel_rpm_name="$(basename "$devel_rpm_path")"

  cp "$kernel_rpm_path" "$ARTIFACT_DIR/$kernel_rpm_name"
  cp "$modules_rpm_path" "$ARTIFACT_DIR/$modules_rpm_name"
  cp "$devel_rpm_path" "$ARTIFACT_DIR/$devel_rpm_name"

  printf -v "KREL_${variant_key^^}" '%s' "$krel"
  printf -v "KERNEL_RPM_${variant_key^^}" '%s' "$kernel_rpm_name"
  printf -v "MODULES_RPM_${variant_key^^}" '%s' "$modules_rpm_name"
  printf -v "DEVEL_RPM_${variant_key^^}" '%s' "$devel_rpm_name"
}

build_firmware_rpm() {
  local firmware_stage="$BUILDROOT_DIR/linux-firmware-gaokun3"
  local firmware_tar="linux-firmware-gaokun3.tar.gz"

  rm -rf "$firmware_stage"
  mkdir -p "$firmware_stage/usr/lib/firmware"
  cp -a "$GAOKUN_DIR/firmware/." "$firmware_stage/usr/lib/firmware/"
  rm -f "$firmware_stage/usr/lib/firmware/"*.spec.in

  prepare_tarball "$firmware_tar" "$firmware_stage"

  render_spec_template \
    "$GAOKUN_DIR/packaging/linux-firmware-gaokun3.spec.in" \
    "$RPM_TOPDIR/SPECS/linux-firmware-gaokun3.spec" \
    "@FW_VERSION@" "$FIRMWARE_RPM_VERSION" \
    "@SOURCE_NAME@" "$firmware_tar"

  rpmbuild "${rpmbuild_common_args[@]}" -bb "$RPM_TOPDIR/SPECS/linux-firmware-gaokun3.spec"

  local firmware_rpm_path
  firmware_rpm_path="$(find "$RPM_TOPDIR/RPMS" -name 'linux-firmware-gaokun3-*.rpm' -print -quit)"
  FIRMWARE_RPM="$(basename "$firmware_rpm_path")"
  cp "$firmware_rpm_path" "$ARTIFACT_DIR/$FIRMWARE_RPM"
}

rpmbuild_common_args=(
  --define "_topdir $RPM_TOPDIR"
  --define "_binary_payload $RPM_PAYLOAD_MACRO"
  --define "_source_payload $RPM_PAYLOAD_MACRO"
)

build_variant_rpms "standard" "" "$KERN_SRC_BASE" "$KERN_OUT" "$BASE_KREL" \
  "sc8280xp-huawei-gaokun3.dtb"

if [[ "$BUILD_EL2" == "true" ]]; then
  : "${KERN_OUT_EL2:?missing KERN_OUT_EL2}"
  if [[ -z "$EL2_KREL" ]]; then
    echo "BUILD_EL2=true but kernel-release-el2.txt is missing" >&2
    exit 1
  fi

  build_variant_rpms "el2" "-el2" "$KERN_SRC_EL2" "$KERN_OUT_EL2" "$EL2_KREL" \
    "sc8280xp-huawei-gaokun3-el2.dtb"
fi

build_firmware_rpm

EL2_MANIFEST_BLOCK=""
EL2_RELEASE_BLOCK=""
if [[ "$BUILD_EL2" == "true" ]]; then
  EL2_MANIFEST_BLOCK="$(cat <<EOF
,
    "el2": {
      "release": "${KREL_EL2}",
      "packages": {
        "kernel": "${KERNEL_RPM_EL2}",
        "kernel_modules": "${MODULES_RPM_EL2}",
        "kernel_devel": "${DEVEL_RPM_EL2}"
      }
    }
EOF
)"
  EL2_RELEASE_BLOCK="$(cat <<EOF
- \`${KERNEL_RPM_EL2}\`
- \`${MODULES_RPM_EL2}\`
- \`${DEVEL_RPM_EL2}\`
EOF
)"
fi

cat >"$ARTIFACT_DIR/package-manifest.json" <<EOF
{
  "package_release_tag": "${PACKAGE_RELEASE_TAG}",
  "kernel_tag": "${KERNEL_TAG}",
  "build_el2": ${BUILD_EL2},
  "built_at_utc": "${BUILD_TIME_UTC}",
  "firmware_version": "${FIRMWARE_RPM_VERSION}",
  "kernels": {
    "standard": {
      "release": "${KREL_STANDARD}",
      "packages": {
        "kernel": "${KERNEL_RPM_STANDARD}",
        "kernel_modules": "${MODULES_RPM_STANDARD}",
        "kernel_devel": "${DEVEL_RPM_STANDARD}"
      }
    }${EL2_MANIFEST_BLOCK}
  },
  "packages": {
    "firmware": "${FIRMWARE_RPM}"
  }
}
EOF

cat >"$ARTIFACT_DIR/package-release-body.md" <<EOF
## Package Bundle

- Package Tag: \`${PACKAGE_RELEASE_TAG}\`
- Kernel Tag: \`${KERNEL_TAG}\`
- EL2 Package Set Included: \`${BUILD_EL2}\`
- Firmware Version: \`${FIRMWARE_RPM_VERSION}\`
- Architecture: \`aarch64\`
- Build Time (UTC): \`${BUILD_TIME_UTC}\`

## Included RPMs

- \`${KERNEL_RPM_STANDARD}\`
- \`${MODULES_RPM_STANDARD}\`
- \`${DEVEL_RPM_STANDARD}\`
${EL2_RELEASE_BLOCK}
- \`${FIRMWARE_RPM}\`
EOF
