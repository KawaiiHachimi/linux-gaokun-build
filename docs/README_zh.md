[English](../README.md) | 中文

# linux-gaokun-buildbot

面向华为 MateBook E Go 2023（代号 `gaokun3`）、基于高通骁龙 8cx Gen3（`SC8280XP`）平台的 Linux 镜像构建脚本、补丁、内核配置、设备树文件、工具和固件。

镜像流水线现默认使用 `systemd-boot`，并可选构建带 `CONFIG_LOCALVERSION="-gaokun3-el2"` 的第二套 EL2 内核变体。

## 包含内容

- `patches/`：内核补丁和设备支持更改
- `defconfig/`：CI/手动构建使用的本地内核配置
- `drivers/`：补丁系列中修改过的驱动源码本地镜像
- `dts/`：补丁系列中修改过的设备树源码本地镜像
- `docs/`：中英文使用/构建指南与平台说明
- `firmware/`：镜像构建使用的最小固件集
- `packaging/`：内核和固件包的 RPM spec 模板
- `tools/`：设备专属辅助脚本、服务文件和 EL2 EFI 载荷
- `scripts/ci/`：工作流构建、镜像创建和打包脚本
- `scripts/local/`：一些可在本地设备上运行的实用脚本

软件包流水线会构建并安装专用软件包集：

- **Fedora (RPM)**：`kernel-gaokun3`、`kernel-modules-gaokun3`、`kernel-devel-gaokun3`、`linux-firmware-gaokun3`
- **Ubuntu (DEB)**：`linux-image-gaokun3`、`linux-modules-gaokun3`、`linux-headers-gaokun3`、`linux-firmware-gaokun3`
- **可选 EL2 变体**：用于第二套 EL2 内核构建的 `*-gaokun3-el2` 软件包集
- Ubuntu 内核镜像包在安装/升级时运行 `update-initramfs`，进而通过发行版的 `systemd-boot` 钩子刷新 BLS 条目。
- Fedora 内核 RPM 现自带匹配的 `dracut.conf.d` 片段，并在 `%posttrans` 中运行 `dracut` + `kernel-install add`，因此安装或升级软件包会自动刷新 initramfs 和 BLS 条目。

## 启动产物布局

镜像和本地安装工作流现遵循标准 `kernel-install` + BLS 流程，而非手动编写 `systemd-boot` 条目。

- BLS 条目名称和条目目录由 `kernel-install` 生成。使用默认 `--entry-token=machine-id` 时，文件名与 `/etc/machine-id` 绑定，如 `loader/entries/<machine-id>-<kernel-release>.conf`。
- 复制到 ESP 的内核、initrd/initramfs 和 DTB 文件也会由发行版钩子自动放入匹配的 `<entry-token>/<kernel-release>/` 目录。
- 在 `/boot` 中还会保留一份 DTB 的兼容副本，方便用户后续切换到 GRUB。
- Ubuntu DTB 安装在 `/usr/lib/linux-image-<kernel-release>/qcom/` 供 `kernel-install` 使用，另有 `/boot/dtb-<kernel-release>` 兼容副本。
- Fedora DTB 安装在 `/usr/lib/modules/<kernel-release>/dtb/qcom/` 供 `kernel-install` 使用，另有 `/boot/dtb-<kernel-release>/qcom/` 兼容副本。
- Gaokun3 镜像脚本提供 `/etc/kernel/cmdline` 和 `/etc/kernel/devicetree`，然后调用 `kernel-install add` 填充最终的 BLS 条目。

## 快速开始

- 双系统引导指南：[English](dual_boot_guide_en.md) | [中文](dual_boot_guide_zh.md)
- EL2 实现说明：[English](el2_kvm_guide_en.md) | [中文](el2_kvm_guide_zh.md)
- 构建指南 – Fedora 44：[English](matebook_ego_build_guide_fedora44_en.md) | [中文](matebook_ego_build_guide_fedora44_zh.md)
- 构建指南 – Ubuntu 26.04：[English](matebook_ego_build_guide_ubuntu26.04_en.md) | [中文](matebook_ego_build_guide_ubuntu26.04_zh.md)
- GitHub Actions – Fedora：[.github/workflows/fedora-gaokun3-release.yml](../.github/workflows/fedora-gaokun3-release.yml)
- GitHub Actions – Ubuntu：[.github/workflows/ubuntu-gaokun3-release.yml](../.github/workflows/ubuntu-gaokun3-release.yml)
- 仓库校验工作流：[.github/workflows/repo-validation.yml](../.github/workflows/repo-validation.yml)

## 补丁来源

- `0001` 到 `0009` 以及 `0017`：来自 [right-0903/linux-gaokun](https://github.com/right-0903/linux-gaokun)
- `0010`：来自 [whitelewi1-ctrl/matebook-e-go-linux](https://github.com/whitelewi1-ctrl/matebook-e-go-linux)
- `0011`：本仓库内的本地改动，用于启用 DSC 以及 60 Hz / 120 Hz 切换
- `0012`：来自 [chiyuki0325/EGoTouchRev-Linux](https://github.com/chiyuki0325/EGoTouchRev-Linux)
- `0013`：来自 [TheUnknownThing/linux-gaokun](https://github.com/TheUnknownThing/linux-gaokun)
- `0014` 到 `0016`：来自 lore.kernel.org 上的 Qualcomm Iris SC8280XP 系列补丁：<https://lore.kernel.org/all/20260125-iris-sc8280xp-v3-2-d21861a9ea33@oss.qualcomm.com/>
- `0099`：本仓库内的本地补丁，用于导入当前的 DTS 文件和 `gaokun3_defconfig`

## 功能支持

设备硬件工作情况可参考 [right-0903/linux-gaokun 的 Feature Support](https://github.com/right-0903/linux-gaokun?tab=readme-ov-file#feature-support)。

## 参考

- [right-0903/linux-gaokun](https://github.com/right-0903/linux-gaokun)：内核补丁和设备支持工作的主要来源，附有详细的提交信息和说明。
- [TheUnknownThing/linux-gaokun](https://github.com/TheUnknownThing/linux-gaokun)：内核补丁和设备支持工作的另一个分支，包含触摸屏和 EC 相关的独特提交和说明。
- [whitelewi1-ctrl/matebook-e-go-linux](https://github.com/whitelewi1-ctrl/matebook-e-go-linux)：最早修复面板背光问题的仓库，包含一些额外的 Gaokun3 Linux 支持资源和修改。
- [gaokun on AUR](https://aur.archlinux.org/packages?O=0&K=gaokun)：为 Gaokun3 构建的多个 AUR 软件包，包括内核和固件包。
- [chenxuecong2/firmware-huawei-gaokun3](https://github.com/chenxuecong2/firmware-huawei-gaokun3)：Gaokun3 固件集合仓库。
- [chiyuki0325/EGoTouchRev-Linux](https://github.com/chiyuki0325/EGoTouchRev-Linux)：内置 `himax_hx83121a_spi` 内核模块的上游触摸屏驱动和算法仓库。
- [awarson2233/EGoTouchRev](https://github.com/awarson2233/EGoTouchRev)：EGoTouchRev-Linux 参考的 Windows 侧触控算法项目，也是 Gaokun3 触摸屏调参流水线的重要上游参考。
- [TravMurav/slbounce](https://github.com/TravMurav/slbounce)：在 Gaokun3 上启用 EL2 支持和安全启动的 UEFI 应用程序。
- [TravMurav/linux](https://github.com/TravMurav/linux/tree/x13s-6.18-v1.1-cxsd)：包含一些 sc8280xp 平台 EL2 支持补丁的 Linux 内核树。
- [stephan-gh/qebspil](https://github.com/stephan-gh/qebspil)：在高通平台上预启动 DSP 固件的 UEFI 应用程序，可在引导链中用于启动 Linux 之前。
