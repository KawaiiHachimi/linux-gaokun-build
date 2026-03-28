#!/usr/bin/env bash
set -euo pipefail

: "${WORKDIR:?missing WORKDIR}"
: "${ARTIFACT_DIR:?missing ARTIFACT_DIR}"
: "${IMAGE_FILE:?missing IMAGE_FILE}"
: "${IMAGE_CHUNK_SIZE:?missing IMAGE_CHUNK_SIZE}"
: "${FEDORA_RELEASE:?missing FEDORA_RELEASE}"
: "${KERNEL_TAG:?missing KERNEL_TAG}"
: "${DESKTOP_ENVIRONMENT:?missing DESKTOP_ENVIRONMENT}"
: "${EXCLUDED_PACKAGES:?missing EXCLUDED_PACKAGES}"
: "${EXTRA_PACKAGES:?missing EXTRA_PACKAGES}"

KREL="$(cat "$WORKDIR/kernel-release.txt")"
IMAGE_BASENAME="$(basename "$IMAGE_FILE")"
ZST_FILE="$ARTIFACT_DIR/${IMAGE_BASENAME}.zst"
RELEASE_BODY_FILE="$ARTIFACT_DIR/release-body.md"
SPLIT_THRESHOLD_BYTES=$((2 * 1024 * 1024 * 1024))

cp "$IMAGE_FILE" "$ARTIFACT_DIR/"
zstd -T0 -19 "$ARTIFACT_DIR/$IMAGE_BASENAME" -o "$ZST_FILE"

if [ "$(stat -c '%s' "$ZST_FILE")" -lt "$SPLIT_THRESHOLD_BYTES" ]; then
  PACKAGE_GLOB="${IMAGE_BASENAME}.zst"
  cat > "$RELEASE_BODY_FILE" <<EOF
## Build Information

- Distribution: \`Fedora Linux ${FEDORA_RELEASE}\`
- Kernel Tag: \`${KERNEL_TAG}\`
- Kernel Release: \`${KREL}\`
- Architecture: \`arm64\`
- Root Filesystem: \`Btrfs (@, @home, @var)\`
- Bootloader: \`GRUB2 (BLS disabled, traditional grub.cfg)\`
- Image File: \`${IMAGE_BASENAME}\`
- Compressed File: \`${IMAGE_BASENAME}.zst\`
- Build Time (UTC): \`$(date -u +"%Y-%m-%dT%H:%M:%SZ")\`

## Rootfs Selection

- Desktop Environment: \`${DESKTOP_ENVIRONMENT}\`
- Excluded Packages: \`${EXCLUDED_PACKAGES}\`
- Extra Packages: \`${EXTRA_PACKAGES}\`

## Default Login

- Username: \`user\`
- Password: \`user\`
EOF
else
  split -b "$IMAGE_CHUNK_SIZE" -d -a 3 \
    "$ZST_FILE" \
    "$ZST_FILE.part-"
  PACKAGE_GLOB="${IMAGE_BASENAME}.zst.part-*"
  cat > "$RELEASE_BODY_FILE" <<EOF
## Build Information

- Distribution: \`Fedora Linux ${FEDORA_RELEASE}\`
- Kernel Tag: \`${KERNEL_TAG}\`
- Kernel Release: \`${KREL}\`
- Architecture: \`arm64\`
- Root Filesystem: \`Btrfs (@, @home, @var)\`
- Bootloader: \`GRUB2 (BLS disabled, traditional grub.cfg)\`
- Image File: \`${IMAGE_BASENAME}\`
- Compressed File: \`${IMAGE_BASENAME}.zst\`
- Build Time (UTC): \`$(date -u +"%Y-%m-%dT%H:%M:%SZ")\`

## Rootfs Selection

- Desktop Environment: \`${DESKTOP_ENVIRONMENT}\`
- Excluded Packages: \`${EXCLUDED_PACKAGES}\`
- Extra Packages: \`${EXTRA_PACKAGES}\`

## Default Login

- Username: \`user\`
- Password: \`user\`

## Reassemble And Decompress

\`\`\`bash
cat ${IMAGE_BASENAME}.zst.part-* > ${IMAGE_BASENAME}.zst
zstd -d ${IMAGE_BASENAME}.zst -o ${IMAGE_BASENAME}
\`\`\`
EOF
fi

sudo chown "$(id -u):$(id -g)" "$RELEASE_BODY_FILE"

TAG_NAME="fedora${FEDORA_RELEASE}-${KREL}-$(date -u +%Y%m%d%H%M%S)"

echo "$TAG_NAME" > "$WORKDIR/tag-name.txt"
echo "$KREL" > "$WORKDIR/kernel-release-export.txt"
echo "$PACKAGE_GLOB" > "$WORKDIR/package-glob.txt"
echo "$(basename "$RELEASE_BODY_FILE")" > "$WORKDIR/release-body-file.txt"
