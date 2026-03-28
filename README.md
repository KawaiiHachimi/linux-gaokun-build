# linux-gaokun-buildbot

Build scripts, patches, kernel config, DTS files, tools, and firmware for Linux images targeting the Huawei MateBook E Go 2023 (`gaokun3` / `SC8280XP`).

## What is included

- `patches/`: kernel patches and device support changes
- `defconfig/`: local kernel configuration used by CI/manual builds
- `drivers/`: local mirrors of the patched driver sources kept in the patch series
- `dts/`: local mirrors of the patched device tree sources kept in the patch series
- `firmware/`: minimal firmware bundle used by the image build
- `packaging/`: RPM spec templates for kernel and firmware packages
- `tools/`: device-specific helper scripts and service files
- `scripts/ci/`: workflow build, image creation, and packaging scripts

The image pipeline now builds and installs a dedicated RPM set:
`kernel-gaokun`, `kernel-modules-gaokun`, `kernel-devel-gaokun`, and
`linux-firmware-gaokun`.

## Getting started

- Build guide (Chinese): [matebook_ego_build_guide_fedora44.md](matebook_ego_build_guide_fedora44.md)
- GitHub Actions workflow: [.github/workflows/fedora-gaokun3-release.yml](.github/workflows/fedora-gaokun3-release.yml)

## References

- [right-0903/linux-gaokun](https://github.com/right-0903/linux-gaokun)
- [whitelewi1-ctrl/matebook-e-go-linux](https://github.com/whitelewi1-ctrl/matebook-e-go-linux)
- [gaokun on AUR](https://aur.archlinux.org/packages?O=0&K=gaokun)
- [TheUnknownThing/linux-gaokun](https://github.com/TheUnknownThing/linux-gaokun)
