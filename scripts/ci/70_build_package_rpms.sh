#!/usr/bin/env bash
set -euo pipefail

: "${GAOKUN_DIR:?missing GAOKUN_DIR}"
: "${WORKDIR:?missing WORKDIR}"
: "${KERN_SRC:?missing KERN_SRC}"
: "${KERN_OUT:?missing KERN_OUT}"
: "${ARTIFACT_DIR:?missing ARTIFACT_DIR}"
: "${KERNEL_TAG:?missing KERNEL_TAG}"
: "${PACKAGE_RELEASE_TAG:?missing PACKAGE_RELEASE_TAG}"

KREL="$(cat "$WORKDIR/kernel-release.txt")"
RPM_TOPDIR="$WORKDIR/rpmbuild"
BUILDROOT_DIR="$WORKDIR/package-buildroots"
KERNEL_STAGE="$BUILDROOT_DIR/kernel-gaokun3"
MODULES_STAGE="$BUILDROOT_DIR/kernel-modules-gaokun3"
MODULES_RAW_STAGE="$BUILDROOT_DIR/kernel-modules-raw"
DEVEL_STAGE="$BUILDROOT_DIR/kernel-devel-gaokun3"
DEVEL_TREE="$DEVEL_STAGE/usr/src/kernels/$KREL"
FIRMWARE_STAGE="$BUILDROOT_DIR/linux-firmware-gaokun3"
KREL_VERSION="${KREL//-/_}"
RPM_BUILD_JOBS="${RPM_BUILD_JOBS:-$(nproc)}"
RPM_PAYLOAD_LEVEL="${RPM_PAYLOAD_LEVEL:-2}"
RPM_PAYLOAD_MACRO="w${RPM_PAYLOAD_LEVEL}T${RPM_BUILD_JOBS}.xzdio"

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

  sed \
    -e "s|@KREL_VERSION@|$KREL_VERSION|g" \
    -e "s|@KREL@|$KREL|g" \
    "$template_path" >"$output_path"
}

prepare_kernel_package() {
  rm -rf "$KERNEL_STAGE"
  mkdir -p "$KERNEL_STAGE/boot/dtb-$KREL/qcom"

  install -Dm644 "$KERN_OUT/arch/arm64/boot/Image" \
    "$KERNEL_STAGE/boot/vmlinuz-$KREL"
  install -Dm644 "$KERN_OUT/System.map" \
    "$KERNEL_STAGE/boot/System.map-$KREL"
  install -Dm644 "$KERN_OUT/.config" \
    "$KERNEL_STAGE/boot/config-$KREL"
  install -Dm644 "$KERN_OUT/arch/arm64/boot/dts/qcom/sc8280xp-huawei-gaokun3.dtb" \
    "$KERNEL_STAGE/boot/dtb-$KREL/qcom/sc8280xp-huawei-gaokun3.dtb"
}

prepare_modules_package() {
  rm -rf "$MODULES_STAGE" "$MODULES_RAW_STAGE"
  mkdir -p "$MODULES_STAGE/usr/lib" "$MODULES_STAGE/lib"

  make -C "$KERN_SRC" O="$KERN_OUT" ARCH=arm64 INSTALL_MOD_PATH="$MODULES_RAW_STAGE" modules_install
  mv "$MODULES_RAW_STAGE/lib/modules" "$MODULES_STAGE/usr/lib/"
  rm -rf "$MODULES_RAW_STAGE"
  rm -f "$MODULES_STAGE/usr/lib/modules/$KREL/build" \
        "$MODULES_STAGE/usr/lib/modules/$KREL/source"
  ln -s ../usr/lib/modules "$MODULES_STAGE/lib/modules"
  depmod -b "$MODULES_STAGE" -a "$KREL"
  rm -f "$MODULES_STAGE/lib/modules"
  rmdir "$MODULES_STAGE/lib"
}

prepare_kernel_devel_package() {
  rm -rf "$DEVEL_STAGE"
  mkdir -p "$DEVEL_TREE" "$DEVEL_STAGE/usr/lib/modules/$KREL"

  rsync -a --delete --exclude '.git' "$KERN_SRC/" "$DEVEL_TREE/"
  rsync -a "$KERN_OUT/" "$DEVEL_TREE/"

  find "$DEVEL_TREE" -type f \
    \( -name '*.o' -o -name '*.ko' -o -name '*.a' -o -name '*.cmd' -o -name '*.mod' -o -name '*.mod.c' \) \
    -delete
  find "$DEVEL_TREE" -type l \( -name build -o -name source \) -delete

  ln -s "../../../src/kernels/$KREL" "$DEVEL_STAGE/usr/lib/modules/$KREL/build"
  ln -s "../../../src/kernels/$KREL" "$DEVEL_STAGE/usr/lib/modules/$KREL/source"
}

prepare_firmware_package() {
  rm -rf "$FIRMWARE_STAGE"
  mkdir -p "$FIRMWARE_STAGE/usr/lib/firmware"
  cp -a "$GAOKUN_DIR/firmware/." "$FIRMWARE_STAGE/usr/lib/firmware/"
  rm -f "$FIRMWARE_STAGE/usr/lib/firmware/"*.spec.in
}

prepare_kernel_package
prepare_modules_package
prepare_kernel_devel_package
prepare_firmware_package

prepare_tarball "kernel-gaokun3.tar.gz" "$KERNEL_STAGE"
prepare_tarball "kernel-modules-gaokun3.tar.gz" "$MODULES_STAGE"
prepare_tarball "kernel-devel-gaokun3.tar.gz" "$DEVEL_STAGE"
prepare_tarball "linux-firmware-gaokun3.tar.gz" "$FIRMWARE_STAGE"

render_spec_template \
  "$GAOKUN_DIR/packaging/kernel-gaokun3.spec.in" \
  "$RPM_TOPDIR/SPECS/kernel-gaokun3.spec"
render_spec_template \
  "$GAOKUN_DIR/packaging/kernel-modules-gaokun3.spec.in" \
  "$RPM_TOPDIR/SPECS/kernel-modules-gaokun3.spec"
render_spec_template \
  "$GAOKUN_DIR/packaging/kernel-devel-gaokun3.spec.in" \
  "$RPM_TOPDIR/SPECS/kernel-devel-gaokun3.spec"
render_spec_template \
  "$GAOKUN_DIR/firmware/linux-firmware-gaokun3.spec.in" \
  "$RPM_TOPDIR/SPECS/linux-firmware-gaokun3.spec"

rpmbuild_common_args=(
  --define "_topdir $RPM_TOPDIR"
  --define "_binary_payload $RPM_PAYLOAD_MACRO"
  --define "_source_payload $RPM_PAYLOAD_MACRO"
)

build_rpm_spec() {
  local spec_path="$1"
  rpmbuild "${rpmbuild_common_args[@]}" -bb "$spec_path"
}

build_rpm_spec "$RPM_TOPDIR/SPECS/kernel-gaokun3.spec" &
pid_kernel=$!
build_rpm_spec "$RPM_TOPDIR/SPECS/kernel-modules-gaokun3.spec" &
pid_modules=$!
build_rpm_spec "$RPM_TOPDIR/SPECS/kernel-devel-gaokun3.spec" &
pid_devel=$!
build_rpm_spec "$RPM_TOPDIR/SPECS/linux-firmware-gaokun3.spec" &
pid_firmware=$!

wait "$pid_kernel"
wait "$pid_modules"
wait "$pid_devel"
wait "$pid_firmware"

kernel_rpm_path="$(find "$RPM_TOPDIR/RPMS" -name 'kernel-gaokun3-*.rpm' -print -quit)"
kernel_modules_rpm_path="$(find "$RPM_TOPDIR/RPMS" -name 'kernel-modules-gaokun3-*.rpm' -print -quit)"
kernel_devel_rpm_path="$(find "$RPM_TOPDIR/RPMS" -name 'kernel-devel-gaokun3-*.rpm' -print -quit)"
firmware_rpm_path="$(find "$RPM_TOPDIR/RPMS" -name 'linux-firmware-gaokun3-*.rpm' -print -quit)"

kernel_rpm_name="$(basename "$kernel_rpm_path")"
kernel_modules_rpm_name="$(basename "$kernel_modules_rpm_path")"
kernel_devel_rpm_name="$(basename "$kernel_devel_rpm_path")"
firmware_rpm_name="$(basename "$firmware_rpm_path")"

cp "$kernel_rpm_path" "$ARTIFACT_DIR/$kernel_rpm_name"
cp "$kernel_modules_rpm_path" "$ARTIFACT_DIR/$kernel_modules_rpm_name"
cp "$kernel_devel_rpm_path" "$ARTIFACT_DIR/$kernel_devel_rpm_name"
cp "$firmware_rpm_path" "$ARTIFACT_DIR/$firmware_rpm_name"

cat >"$ARTIFACT_DIR/package-manifest.json" <<EOF
{
  "package_release_tag": "${PACKAGE_RELEASE_TAG}",
  "kernel_tag": "${KERNEL_TAG}",
  "kernel_release": "${KREL}",
  "built_at_utc": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "packages": {
    "kernel": "${kernel_rpm_name}",
    "kernel_modules": "${kernel_modules_rpm_name}",
    "kernel_devel": "${kernel_devel_rpm_name}",
    "firmware": "${firmware_rpm_name}"
  }
}
EOF

cat >"$ARTIFACT_DIR/package-release-body.md" <<EOF
## Package Bundle

- Package Tag: \`${PACKAGE_RELEASE_TAG}\`
- Kernel Tag: \`${KERNEL_TAG}\`
- Kernel Release: \`${KREL}\`
- Architecture: \`aarch64\`
- Build Time (UTC): \`$(date -u +"%Y-%m-%dT%H:%M:%SZ")\`

## Included RPMs

- \`${kernel_rpm_name}\`
- \`${kernel_modules_rpm_name}\`
- \`${kernel_devel_rpm_name}\`
- \`${firmware_rpm_name}\`
EOF
