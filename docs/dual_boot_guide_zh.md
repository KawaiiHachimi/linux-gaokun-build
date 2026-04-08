[English](dual_boot_guide_en.md) | 中文

# Windows + Linux 双系统安装与引导配置（DG + systemd-boot）

本文档以 `systemd-boot` 为例，接管默认启动项，实现 Windows / Linux 二选一

## 一、准备

- 工具：DiskGenius（下文简称 DG）
- 文件：
	- 解压后的虚拟磁盘镜像如 `ubuntu-26.04-gaokun3.img`
- UEFI 设置：开机 F2 启动，UEFI 菜单 Secure Boot 选择 Disable 保存并重启

## 二、备份虚拟磁盘 rootfs 并还原到内置硬盘

1. 在 DG 中选择“磁盘”-“打开磁盘镜像文件”，先挂载虚拟磁盘镜像。
2. 找到镜像里的 Linux rootfs 分区，右键使用“备份分区到镜像文件”，备份类型选择“完整备份”，导出为 `rootfs.pmf`。
3. 在内置硬盘分区上右键使用“拆分分区”，分区后部建立新分区，大于 12G 即可，作为 Linux rootfs 目标分区。
4. 对该新分区执行“从镜像文件还原分区”，选择刚才的 `rootfs.pmf`，完成 rootfs 写入。
5. 检查还原后的分区“卷UUID”是否与虚拟磁盘镜像中的 rootfs 分区“卷UUID”一致。

## 三、同步 EFI 分区内容

1. 在 DG 中打开虚拟磁盘镜像的 EFI 分区文件浏览。
2. 从镜像 EFI 分区根目录拷贝全部文件和文件夹到指定位置。
3. 打开内置硬盘 EFI 分区文件浏览，先将 `\EFI\BOOT\BOOTAA64.EFI` 备份为 `\EFI\BOOT\BOOTAA64.EFI.bak`。
4. 把指定位置下的镜像 EFI 分区根目录全部内容直接拖入内置硬盘 EFI 分区根目录覆盖。

完成后，内置硬盘 EFI 分区根目录通常应包含如下内容：
- `EFI`
- `loader`
- `<machine-id>` 或其他 `kernel-install` entry-token 目录
- `firmware`（若镜像包含 EL2）
- `tcblaunch.exe`（若镜像包含 EL2）

其中 `EFI` 下通常应包含：
- `BOOT`
- `systemd`
- `Microsoft`

Windows 一般可由 `systemd-boot` 自动探测，所以无需额外修改 Windows 引导项。

说明：

- 现在镜像使用标准 `kernel-install` + BLS 布局，不再固定使用 `gaokun3/<distro>/<kernel-release>/...` 目录。
- 默认情况下，Gaokun3 镜像会使用 `--entry-token=machine-id`，因此 ESP 中通常会出现 `/loader/entries/<machine-id>-<kernel-release>.conf`，以及 `/<machine-id>/<kernel-release>/linux|initrd|*.dtb` 这类目录结构。
- 若发行版或用户改过 `kernel-install --entry-token`，顶层目录名可能不是 `machine-id`，但仍会遵循同样的 BLS 规则。

## 四、修改 EFI 分区卷序列号

1. 在 DG 中查看虚拟磁盘镜像 EFI 分区卷序列号（如 `ABCD-1234`），右键可进行复制。
2. 右键内置硬盘 EFI 分区，选择“修改卷序列号”，输入复制的卷序列号，注意去除中间的 `-`。
3. 检查其卷序列号是否改成与虚拟磁盘镜像 EFI 分区相同的卷序列号。

## 五、重启验证

- 重启后应进入 `systemd-boot` 启动菜单。
- 菜单中可选择启动 Windows 或 Linux 发行版。
- 进入 Linux 发行版后可以使用 gnome-disk 等磁盘工具或 growpart/resize2fs/btrfs 等命令扩容 rootfs 分区和文件系统到整个剩余空间。

## 补充说明（EL2 可选）

若镜像已带好 EL2 所需文件，完成本篇后直接在 `systemd-boot` 中选择 EL2 菜单项启动即可，详见 [el2_kvm_guide_zh.md](el2_kvm_guide_zh.md)。

## 常见提醒

- 若启动菜单未出现，优先检查：
	- `\EFI\BOOT\BOOTAA64.EFI` 是否已经被镜像中的 `systemd-boot` 覆盖
	- EFI 分区根目录结构是否完整
	- 是否存在 `\loader\entries\<entry-token>-<kernel-release>.conf`
	- 是否存在 `\<entry-token>\<kernel-release>\` 下的 `linux`、`initrd`、`*.dtb`
	- EL2 所需的 `firmware\`、`tcblaunch.exe`、`\EFI\systemd\drivers\` 是否完整
	- EFI 卷序列号是否与镜像一致
- 若进入 Linux 后但没有正常挂载 `/boot/efi`，检查 `/etc/fstab` 中 EFI 分区的 UUID 是否与内置硬盘 EFI 分区的 UUID 一致。
- 若误操作导致无法启动，可启动 USB 存储设备上的 Linux 或 WinPE（推荐使用 [CNBYDJ PE](https://bydjpe.winos.me)）挂载内置硬盘 EFI 分区，使用先前备份的 `BOOTAA64.EFI.bak` 回滚。
