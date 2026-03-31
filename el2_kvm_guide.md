# Huawei MateBook E Go 2023 EL2 + KVM 指南

## 1. 目标

- 让 MateBook E Go 2023 通过 Secure Launch 进入 EL2。
- 在 Linux 中启用可用的 KVM。
- 在 EL2 模式下补齐 DSP 启动链，尽量恢复音频等依赖 remoteproc 的功能。

## 2. 结论先说

当前要点不是只有 `slbounce`：

1. `slbounce` 负责在 `ExitBootServices()` 时切到 EL2。
2. 音频依赖的 ADSP/CDSP/SLPI 这类 remoteproc，在 EL2 下通常不能再指望 Qualcomm 原有 hypervisor 替你拉起。
3. 因此需要额外引入 `qebspil`，在退出 UEFI 前先把 DSP 固件启动。
4. Linux 内核侧还需要带上 `qebspil` 对应的 remoteproc/PAS handover 补丁；否则即使 DSP 被提前启动，内核也可能无法正确接管。

## 3. 需要的组件

EFI 侧至少需要：

- `BOOTAA64.EFI`：自定义包装器
- `slbounceaa64.efi`
- `tcblaunch.exe`
- `qebspilaa64.efi`
- `SimpleInit-AARCH64.efi`（或你自己的下一级引导器）
- `/firmware/...` 下的 DSP 固件文件

内核侧至少需要：

- EL2 DTB：`sc8280xp-huawei-gaokun3-el2.dtb`
- `CONFIG_VIRTUALIZATION=y`
- `CONFIG_KVM=y`
- `CONFIG_REMOTEPROC=y`
- Qualcomm remoteproc/PAS 相关驱动可用
- qebspil 对应的 handover / late-attach / EL2-PAS 补丁

## 4. 为什么只用 slbounce 还不够

`slbounce` 解决的是 **EL2 接管**；它不负责替 Linux 启动 DSP。

而 `qebspil` 的用途是：在 `ExitBootServices()` 之前，根据 DT 中启用的 remoteproc 节点，把对应固件先加载并启动。对 EL2 Linux 来说，这一步通常正是音频是否能工作的分水岭。

## 5. 推荐启动链

建议链路改成：

1. `\EFI\BOOT\BOOTAA64.EFI`
2. `\slbounceaa64.efi`
3. `\qebspilaa64.efi`
4. `\EFI\BOOT\SimpleInit-AARCH64.efi`
5. Simple Init -> GRUB -> EL2 菜单项

说明：

- `slbounce` 仍然负责 Secure Launch / EL2 切换。
- `qebspil` 负责在退出 UEFI 前预启动 DSP。
- GRUB 菜单必须显式指定 `-el2.dtb`。

## 6. 重新编译项

### 6.1 编译 BOOTAA64.EFI 包装器

```bash
sudo apt-get update
sudo apt-get install -y gcc-aarch64-linux-gnu binutils-aarch64-linux-gnu

cd /workspaces/linux-gaokun-build/tools/el2
make clean
make
```

产物：

- `tools/el2/bootaa64.efi`

### 6.2 编译 qebspil

```bash
git clone --recursive https://github.com/stephan-gh/qebspil.git
cd qebspil
make CROSS_COMPILE=aarch64-linux-gnu-
```

产物：

- `out/qebspilaa64.efi`

如需强制启动所有 remoteproc（不只限带 `qcom,broken-reset` 的节点）：

```bash
make CROSS_COMPILE=aarch64-linux-gnu- QEBSPIL_ALWAYS_START=1
```

不确定平台 DTS 是否完整时，先不要加这个开关。

## 7. 需要补的内核部分

### 7.1 必选

重新编译内核前，至少确认：

```text
CONFIG_VIRTUALIZATION=y
CONFIG_KVM=y
CONFIG_REMOTEPROC=y
CONFIG_QCOM_SYSMON=y
CONFIG_QCOM_Q6V5_COMMON=y
CONFIG_QCOM_Q6V5_ADSP=y
CONFIG_QCOM_Q6V5_MSS=y
CONFIG_QCOM_PIL_INFO=y
```

如果你的树里符号名略有变化，以实际内核版本为准，但原则不变：**KVM + remoteproc + qcom PAS/Q6V5 必须齐**。

### 7.2 必补的补丁方向

当前可直接使用仓库内 `patches/el2` 这组补丁；按语义看，重点是下面三类：

1. **remoteproc handover / late attach**  
   让 Linux 能接管 qebspil 预启动的 remoteproc，而不是把它当成异常状态。

2. **qcom PAS 在 EL2 下的支持**  
   当 Linux 自己管理 IOMMU / stream ID / resource table 时，允许 PAS 正确认证和接管固件。

3. **ADSP lite firmware / DTB 清理与接管修正**  
   否则旧的 lite ADSP 占着内存或状态，完整音频固件接不上，仍可能没声音。

## 8. 固件准备

`qebspil` 读取 DT 中的 `firmware-name`，所以要把对应固件放到 ESP 的顶层 `/firmware` 目录。

建议先在能正常工作的系统里确认需要哪些文件：

```bash
find /sys/firmware/devicetree -name firmware-name -exec cat {} + | xargs -0n1
```

然后把对应文件从 `/lib/firmware/` 或 Windows 分区拷到 EFI 分区。SC8280XP 常见至少包括：

- `qcadsp*.mbn`
- `qccdsp*.mbn`
- `qcslpi*.mbn`

如果你的机器音频仍不工作，第一优先检查的就是这里。

## 9. EFI 部署

先备份再替换：

1. 备份 `\EFI\BOOT\BOOTAA64.EFI`
2. 替换为 `tools/el2/bootaa64.efi`
3. EFI 分区根目录放：
   - `\slbounceaa64.efi`
   - `\tcblaunch.exe`
   - `\qebspilaa64.efi`
4. EFI 分区放：
   - `\EFI\BOOT\SimpleInit-AARCH64.efi`
5. EFI 分区顶层放：
   - `\firmware\...`
6. Simple Init 中跳转发行版 GRUB
7. GRUB 中选择 EL2 菜单项

建议目录类似：

```text
/boot/efi
├── EFI
│   ├── Boot
│   │   ├── BOOTAA64.EFI
│   │   ├── ...
│   │   └── SimpleInit-AARCH64.efi
│   ├── ubuntu
│   │   ├── grubaa64.efi
│   │   └── grub.cfg
│   └── ...
├── firmware
│   └── qcom
│       └── sc8280xp
│           └── HUAWEI
│               └── gaokun3
│                   ├── qcadsp8280.mbn
│                   ├── qccdsp8280.mbn
│                   └── qcslpi8280.mbn
├── qebspilaa64.efi
├── slbounceaa64.efi
└── tcblaunch.exe
```

## 10. 启动后验证

进系统后执行：

```bash
uname -a
dmesg | grep -Ei 'kvm|hypervisor|el2|q6v5|adsp|cdsp|slpi|remoteproc'
ls -l /dev/kvm
ls /sys/class/remoteproc/
```

重点看：

- `/dev/kvm` 是否存在
- 是否已经在 EL2
- remoteproc 是否存在且不是全部离线
- 是否有 ADSP/CDSP/SLPI 相关报错

## 11. 出现“EL2 正常但音频无效”时，排查顺序

1. 是否真的部署了 `qebspilaa64.efi`
2. ESP 顶层是否存在 `/firmware/...`，且文件名和 DT 的 `firmware-name` 一致
3. EL2 菜单是否确实加载了 `-el2.dtb`
4. 内核是否包含 qebspil 对应的 remoteproc/PAS 补丁
5. `dmesg` 是否出现 ADSP/CDSP handover、PAS、IOMMU、resource table 相关错误
6. 若 remoteproc 节点未带 `qcom,broken-reset`，再考虑重新编译 `QEBSPIL_ALWAYS_START=1`

## 12. 最小建议

如果你现在的目标是“先把音频救活”，最小动作就是：

1. 保留现有 `slbounce` 链路
2. 新增 `qebspilaa64.efi`
3. 补齐 ESP 上的 `/firmware/...`
4. 内核合入 qebspil README 指向的 handover/PAS 补丁后重编
5. 再验证 ADSP/CDSP/SLPI 启动情况

这一步做完之前，不建议只围着 ALSA/声卡驱动继续排查。