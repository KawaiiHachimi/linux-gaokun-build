# linux-gaokun-build

Build scripts, patches, tools, and firmware for Linux images targeting the Huawei MateBook E Go 2023 (`gaokun3` / `SC8280XP`).

## What is included

- `gaokun-patches/`: kernel patches and device support changes
- `firmware/`: minimal firmware bundle used by the image build
- `tools/`: device-specific helper scripts and service files
- `scripts/ci/`: workflow build, image customization, and packaging scripts

## Build flow

The current build flow starts from the Fedora Workstation raw image, downloads and decompresses it when needed, then customizes a copied working image in place:

- build the patched kernel
- fetch `https://download.fedoraproject.org/pub/fedora/linux/releases/test/44_Beta/Workstation/aarch64/images/Fedora-Workstation-Disk-44_Beta-1.2.aarch64.raw.xz` when the raw image is missing
- copy `Fedora-Workstation-Disk-44_Beta-1.2.aarch64.raw` into the build directory
- mount the existing Fedora partitions and Btrfs subvolumes
- install the new kernel/modules
- remove Fedora's stock kernel packages, old boot artifacts, and `linux-firmware`
- copy the repository firmware bundle
- regenerate initramfs, BLS entry, and GRUB config
- package the resulting raw image

## Getting started

- Build guide (Chinese): [matebook_ego_build_guide_fedora44.md](matebook_ego_build_guide_fedora44.md)
- GitHub Actions workflow: [.github/workflows/fedora-gaokun3-release.yml](.github/workflows/fedora-gaokun3-release.yml)

## References

- [right-0903/linux-gaokun](https://github.com/right-0903/linux-gaokun)
- [whitelewi1-ctrl/matebook-e-go-linux](https://github.com/whitelewi1-ctrl/matebook-e-go-linux)
- [gaokun on AUR](https://aur.archlinux.org/packages?O=0&K=gaokun)
