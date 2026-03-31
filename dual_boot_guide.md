# Windows + Linux 双系统安装与引导配置（DG + Simple Init）

本文档以 Simple Init 为例，接管默认启动项，实现 Windows / Linux 二选一

## 一、准备

- 工具：DiskGenius（下文简称 DG）
- 文件：
	- 解压后的虚拟磁盘镜像如 `ubuntu-26.04-gaokun3.img`
	- [Simple Init](https://github.com/BigfootACA/simple-init) UEFI Binaries：
		- https://github.com/rodriguezst/simple-init/releases/download/20241118/SimpleInit-AARCH64.efi

## 二、备份虚拟磁盘 rootfs 并还原到内置硬盘

1. 在 DG 中先挂载虚拟磁盘镜像。
2. 找到镜像里的 Linux rootfs 分区，右键使用“备份分区到镜像文件”，备份类型选择“完整备份”，导出为 `rootfs.pmf`。
3. 在内置硬盘分区上右键使用“拆分分区”，分区后部建立新分区，作为 Linux rootfs 目标分区。
4. 对该新分区执行“还原分区”，选择刚才的 `rootfs.pmf`，完成 rootfs 写入。
5. 检查还原后的分区“卷UUID”是否与虚拟磁盘镜像中的 rootfs 分区“卷UUID”一致。

## 三、同步 EFI 目录

1. 从虚拟磁盘镜像中拷贝出完整的 `EFI` 目录。
2. 打开内置硬盘 EFI 分区文件浏览，先将 `\EFI\BOOT\BOOTAA64.efi` 重命名为 `\EFI\BOOT\BOOTAA64.efi.bak` 备份原始启动文件。
3. 把拷出的 `EFI` 目录直接拖入内置硬盘 EFI 分区根目录。

完成后，`EFI` 下应包含如下目录（名称可能因发行版不同而变化）：
- `boot`
- `fedora` 或 `ubuntu` 等 Linux 发行版目录
- `microsoft`

## 四、替换默认引导为 Simple Init

1. 下载 `SimpleInit-AARCH64.efi`。
2. 将其重命名为 `BOOTAA64.efi`。
3. 拖入并覆盖内置硬盘 EFI 分区中的：
	 - `\EFI\BOOT\BOOTAA64.efi`

## 五、修改 EFI 分区卷序列号

1. 在 DG 中查看虚拟磁盘镜像 EFI 分区卷序列号（如 ABCD-1234），右键可进行复制。
2. 右键内置硬盘 EFI 分区，选择“修改卷序列号”，输入复制的卷序列号，注意去除中间的“-”。
3. 检查其卷序列号是否改成与虚拟磁盘镜像 EFI 分区相同的卷序列号。

## 六、重启验证

- 重启后应进入 Simple Init 启动菜单。
- 菜单中可选择启动 Windows 或 Linux 发行版。

## 补充说明（EL2 可选）

当前仓库的 Fedora/Ubuntu 构建文档已经包含 EL2 DTB 复制和 GRUB 的 EL2 启动项，如果你要在默认 `\\EFI\\BOOT\\BOOTAA64.efi` 入口里串入 Secure Launch，可使用 `tools/el2` 目录包装器产物`bootaa64.efi`。

### EL2 引导建议

EL2 专用文档：[el2_kvm_guide.md](el2_kvm_guide.md)

推荐顺序：

1. 先按本篇完成 Windows + Linux 双启动。
2. 再按 [el2_kvm_guide.md](el2_kvm_guide.md) 部署 `tools/el2` 的 `bootaa64.efi`、`slbounceaa64.efi`、`tcblaunch.exe` 以及 `SimpleInit-AARCH64.efi`。
3. 在 GRUB 中选择 EL2 菜单项启动，并按 EL2 文档完成 KVM 验证。

## 可选：GRUB 多引导（OS_PROBER）

如果你不使用 Simple Init，也可以改为由 GRUB 自动探测并生成 Windows 启动项：

1. 完成上述步骤后，将 EFI Linux 发行版目录 `grubaa64.efi` 重命名再次拖入覆盖 `\EFI\BOOT\BOOTAA64.efi`，让 GRUB 作为默认引导程序启动 Linux。
2. 编辑 `/etc/default/grub`，确认存在如下配置：

```bash
GRUB_DISABLE_OS_PROBER=false
```

3. 安装并启用 os-prober 后，重新生成 GRUB 配置：
	- Ubuntu / Debian：`sudo update-grub`
	- Fedora：`sudo grub2-mkconfig -o /boot/grub2/grub.cfg`

重启后，GRUB 菜单中通常会出现 Windows Boot Manager。

如 Fedora 上 os-prober 不可用，可手动写入 `/etc/grub.d/40_custom`：

```bash
menuentry "Windows Boot Manager" --class windows --class os {
    insmod fat
    insmod part_gpt
    search --no-floppy --file --set=root /EFI/Microsoft/Boot/bootmgfw.efi
    chainloader /EFI/Microsoft/Boot/bootmgfw.efi
}
```

保存后执行：`sudo grub2-mkconfig -o /boot/grub2/grub.cfg`，即可生成手动添加的 Windows 启动项。

## 常见提醒

- 若启动菜单未出现，优先检查：
	- `\EFI\BOOT\BOOTAA64.efi` 是否已被 Simple Init 覆盖
	- EFI 目录结构是否完整（包含 `\EFI\ubuntu\grubaa64.efi` 或者 `\EFI\fedora\grubaa64.efi` 等 GRUB efi files）
	- EFI 卷序列号是否与镜像一致
- 若误操作导致无法启动，可启动 USB 存储设备上的 Linux 或 WinPE（推荐使用 [CNBYDJ PE](https://bydjpe.winos.me)） 挂载内置硬盘 EFI 分区，使用先前备份的 `BOOTAA64.efi.bak` 回滚。
