# linux-gaokun-build

Build scripts, patches, kernel config, DTS files, tools, and firmware for Linux images targeting the Huawei MateBook E Go 2023 (`gaokun3` / `SC8280XP`).

## What is included

- `gaokun-patches/`: kernel patches and device support changes
- `defconfig/`: local kernel configuration used by CI/manual builds
- `dts/`: local device tree sources copied into the kernel tree during build
- `firmware/`: minimal firmware bundle used by the image build
- `tools/`: device-specific helper scripts and service files
- `scripts/ci/`: workflow build, image creation, and packaging scripts

The touchscreen path is now handled as an in-kernel SPI driver carried in
`gaokun-patches/`; the build no longer relies on a separate DKMS package or
userspace I2C recovery helpers.

## Getting started

- Build guide (Chinese): [matebook_ego_build_guide_fedora44.md](matebook_ego_build_guide_fedora44.md)
- GitHub Actions workflow: [.github/workflows/fedora-gaokun3-release.yml](.github/workflows/fedora-gaokun3-release.yml)

## References

- [right-0903/linux-gaokun](https://github.com/right-0903/linux-gaokun)
- [whitelewi1-ctrl/matebook-e-go-linux](https://github.com/whitelewi1-ctrl/matebook-e-go-linux)
- [gaokun on AUR](https://aur.archlinux.org/packages?O=0&K=gaokun)
