# Huawei MateBook E Go 2023 EL2 + KVM 指南

## 1. 实现目标

- 在 MateBook E Go 2023 上使用现有镜像启用 EL2 启动。
- 在 Linux 中拿到可用的 KVM 能力。
- 结合 `tools/slbounce_el2` 使用 `BOOTAA64.EFI` 单入口链式启动。

## 2. 关键信息

当前 Fedora/Ubuntu 构建文档和 CI Workflow 已把 EL2 相关启动条件写入：

1. 内核构建产物里会复制 `sc8280xp-huawei-gaokun3-el2.dtb`。
2. GRUB 已增加 EL2 启动菜单项（带 `devicetree` 指向 EL2 DTB）。

## 3. 为什么需要 slbounce（简述）

项目地址：https://github.com/TravMurav/slbounce

Qualcomm WoA 机型通常需要通过 Secure Launch 路径完成 EL2 接管，`slbounceaa64.efi` 负责在退出 UEFI Boot Services 时进行关键切换。

MateBook E Go 2023 当前限制是：

- 无原生 UEFI Shell 入口。
- 固件只认 `\\EFI\\BOOT\\BOOTAA64.EFI`。

因此建议用链式入口：

1. `\\EFI\\BOOT\\BOOTAA64.EFI`（包装器）
2. `\\slbounceaa64.efi`
3. `\\EFI\\BOOT\\SimpleInit-AARCH64.efi`
4. Simple Init 里再选 GRUB/Windows

## 4. tools/slbounce_el2 目录简要说明

当前仓库已内置一个可直接编译的包装器目录：`tools/slbounce_el2`。

主要文件：

- `loader_main.c`：链式启动逻辑（现在是 slbounce -> Simple Init，可以自行修改）。
- `Makefile`：AArch64 GNU-EFI 交叉编译脚本。
- `gnu-efi/`：编译所需头文件和库。
- `slbounceaa64.efi`：slbounce 驱动文件（部署到 EFI 分区根）。
- `tcblaunch.exe`：已验证版本的 TCB 文件（部署到 EFI 分区根）。
- `bootaa64.efi`：包装器编译产物。

## 5. 如何编译新的 bootaa64.efi

在 Ubuntu 类宿主机：

```bash
sudo apt-get update
sudo apt-get install -y gcc-aarch64-linux-gnu binutils-aarch64-linux-gnu

cd /workspaces/linux-gaokun-build/tools/slbounce_el2
make clean
make
```

成功后得到：

- `tools/slbounce_el2/bootaa64.efi`

如果你要改链路（例如改 Simple Init 路径），编辑 `loader_main.c` 后重新 `make` 即可。

## 6. 部署到 EFI 分区

先备份再替换：

1. 备份原文件：`\\EFI\\BOOT\\BOOTAA64.EFI.bak1`。
2. 复制包装器：`tools/slbounce_el2/bootaa64.efi -> \\EFI\\BOOT\\BOOTAA64.EFI`
3. EFI 分区**根目录**放置：
   - `\\slbounceaa64.efi`
   - `\\tcblaunch.exe`
   - `\\EFI\\BOOT\\SimpleInit-AARCH64.efi`
4. Simple Init 菜单中：
   - Windows -> `\\EFI\\Microsoft\\Boot\\bootmgfw.efi`
   - Linux -> 发行版 GRUB（例如 `\\EFI\\fedora\\grubaa64.efi` 或 `\\EFI\\ubuntu\\grubaa64.efi`）
5. GRUB 菜单中选择 EL2 Hypervisor 项启动。

最终 EFI 目录结构类似于：
```text
/boot/efi
├── EFI
│   ├── Boot
│   │   ├── BOOTAA64.EFI
│   │   ├── ...
│   │   └── SimpleInit-AARCH64.efi
│   ├── Microsoft
│   │   ├── Boot
│   │   └── Recovery
│   └── ubuntu
│       ├── grub.cfg
│       └── grubaa64.efi
├── slbounceaa64.efi
└── tcblaunch.exe
```

## 7. KVM 最小配置检查

当前 `defconfig/gaokun3_defconfig` 至少确保：

```text
CONFIG_VIRTUALIZATION=y
CONFIG_KVM=y
```
然后重新构建内核并安装。

## 8. 启动后验证（EL2 + KVM）

进系统后执行：

```bash
uname -a
dmesg | grep -Ei 'kvm|hypervisor|el2'
ls -l /dev/kvm
```

## 9. 常见问题排查顺序

1. `BOOTAA64.EFI` 已替换，但 EFI 根目录缺少 `slbounceaa64.efi` 或 `tcblaunch.exe`。
2. 包装器加载路径与实际文件路径不一致（特别是 `SimpleInit-AARCH64.efi` 路径）。
3. Simple Init 能进但 Linux 选项指向错误的 GRUB 路径。
4. 内核未启用 `CONFIG_VIRTUALIZATION`/`CONFIG_KVM`。
