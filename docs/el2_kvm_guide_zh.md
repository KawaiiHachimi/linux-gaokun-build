[English](el2_kvm_guide_en.md) | 中文

# Huawei MateBook E Go 2023 EL2 实现说明

## 1. 文档定位

- 常规镜像与软件包构建流程已经可以可选产出 `-gaokun3-el2` 内核变体以及所需 EFI 载荷。
- 本文更侧重说明这些 EL2 构建产物背后的实现细节、启动链结构，以及内核与固件要求。
- 因此它更适合作为理解、调试和定制 EL2 路径的参考，而不是构建完成后必须逐项执行的清单。

## 2. 核心结论

仅凭 `slbounce` 即可进入 EL2，但它不负责 DSP 启动。MateBook E Go 2023 上音频依赖 ADSP/CDSP/SLPI 等 remoteproc；若这些 remoteproc 在退出 UEFI 前未被正确拉起，EL2 Linux 中通常会直接表现为无声。

这一组合中各组件的职责可概括为：

1. `slbounce`：在 `ExitBootServices()` 时完成 Secure Launch，切换到 EL2。
2. `qebspil`：在退出 UEFI 之前，根据设备树中已启用的 remoteproc 节点，把对应 DSP 固件加载并启动。
3. EL2 内核补丁：让 Linux 正确接管已经由 `qebspil` 启动的 remoteproc，而不是把它们当作异常状态处理。

因此，EL2 能否“真正可用”，关键不只是进不进入 EL2，而是：

- EL2 菜单项是否使用了 `-gaokun3-el2` 内核和 `-el2.dtb`
- EFI 中是否具备 `qebspil` 所需的最小固件集
- 内核是否具备 remoteproc/PAS handover 所需补丁

## 3. 启动链与文件布局

建议的启动链如下：

1. `\EFI\BOOT\BOOTAA64.EFI`
2. `\EFI\systemd\drivers\slbounceaa64.efi`
3. `\EFI\systemd\drivers\qebspilaa64.efi`
4. `systemd-boot` -> EL2 菜单项

说明：

- `BOOTAA64.EFI` 现在是 `systemd-boot`
- `slbounce` 负责 EL2 切换
- `tcblaunch.exe` 是配合 `slbounce` 使用的 TCB 文件，仓库中自带一个经过验证可用的微软签名 TCB 二进制文件
- `qebspil` 负责在 UEFI 阶段完成 DSP 预启动
- `systemd-boot` 只负责提供标准项和 EL2 项两个菜单入口；真正决定 EL2 行为的是 EL2 BLS 菜单项指向的内核、initrd 与 DTB
- 标准内核文件布局现在由 `kernel-install` 自动生成，默认与 `machine-id`/entry-token 挂钩

EFI 侧至少需要以下文件：

- `BOOTAA64.EFI`
- `slbounceaa64.efi`
- `qebspilaa64.efi`
- `tcblaunch.exe`
- `\firmware\...` 下的 DSP 固件文件

其中：

- `slbounceaa64.efi` 和 `qebspilaa64.efi` 需要放到 `\EFI\systemd\drivers\`
- `\firmware\...` 中当前最小需求为：
  - `qcadsp8280.mbn`
  - `qccdsp8280.mbn`
  - `qcslpi8280.mbn`

建议的目录结构如下：

```text
/boot/efi
├── <entry-token>
│   ├── <kernel-release>/linux
│   ├── <kernel-release>/initrd
│   ├── <kernel-release>/sc8280xp-huawei-gaokun3.dtb
│   ├── <kernel-release-el2>/linux
│   ├── <kernel-release-el2>/initrd
│   └── <kernel-release-el2>/sc8280xp-huawei-gaokun3-el2.dtb
├── EFI
│   ├── BOOT
│   │   └── BOOTAA64.EFI
│   └── systemd
│       ├── systemd-bootaa64.efi
│       └── drivers
│           ├── qebspilaa64.efi
│           └── slbounceaa64.efi
├── firmware
│   └── qcom
│       └── sc8280xp
│           └── HUAWEI
│               └── gaokun3
│                   ├── qcadsp8280.mbn
│                   ├── qccdsp8280.mbn
│                   └── qcslpi8280.mbn
├── tcblaunch.exe
├── loader
│   ├── entries
│   │   ├── <entry-token>-<kernel-release>.conf
│   │   └── <entry-token>-<kernel-release-el2>.conf
│   └── loader.conf
```

其中：

- `<entry-token>` 默认通常就是 `/etc/machine-id`
- 上面的 `linux` 文件名是 `90-loaderentry.install` 自动生成的标准 BLS Type #1 命名，不再是手工命名的 `vmlinuz`
- 若系统改用了别的 `kernel-install --entry-token`，目录名前缀会随之变化，但整体结构不变

## 4. 内核侧要求

内核侧至少需要：

- EL2 DTB：`sc8280xp-huawei-gaokun3-el2.dtb`
- EL2 内核：`CONFIG_LOCALVERSION="-gaokun3-el2"`
- `CONFIG_VIRTUALIZATION=y`
- `CONFIG_KVM=y`
- `CONFIG_REMOTEPROC=y`
- Qualcomm remoteproc/PAS 相关驱动
- qebspil 对应的 handover / late-attach / EL2-PAS 补丁

### 4.1 必选配置项

重新编译内核前，至少确认以下配置项已启用：

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

不同内核版本的符号名称可能略有差异，请以实际版本为准，但核心原则不变：**KVM、remoteproc 及 qcom PAS/Q6V5 必须齐备**。

### 4.2 补丁的作用

当前可直接使用仓库内 `patches/el2` 中的补丁集。按语义分类，重点涉及以下三个方向：

1. **remoteproc handover / late attach**
   使 Linux 能够接管由 `qebspil` 预先启动的 remoteproc，而不是把这些 remoteproc 视为异常或重复启动对象。

2. **qcom PAS / SCM / SHM bridge 在 EL2 下的支持**
   使 SCM 与 SHM bridge 在 EL2 下使用正确的 owner/VMID，并处理 bare-metal EL2 环境下 PAS reset 本身不可靠的问题。

3. **SMP2P / rpmsg / QRTR / pmic_glink 的竞态与接管稳定性修正**
   修正在 remoteproc 已由启动阶段预先拉起后，SMP2P 状态接管、rpmsg 通道建立、QRTR 握手以及 pmic_glink 探测顺序中的竞态问题，避免出现设备已运行但通信链路未正确建立的情况。

## 5. 固件准备

`qebspil` 通过读取设备树中的 `firmware-name` 属性来定位固件，因此 EFI 分区中的 `/firmware` 目录并不是随意放文件，而是要与设备树引用严格对应。

建议先在可正常工作的系统中确认所需文件：

```bash
find /sys/firmware/devicetree -name firmware-name -exec cat {} + | xargs -0n1
```

对当前 gaokun3 EL2 方案，EFI 中建议保留最小集合：

- `qcadsp8280.mbn`
- `qccdsp8280.mbn`
- `qcslpi8280.mbn`

这些文件通常来源于系统中的 `/lib/firmware/qcom/sc8280xp/HUAWEI/gaokun3/`。若音频功能仍不正常，应首先确认这里的文件名是否与设备树中的 `firmware-name` 完全一致。

## 6. 编译说明

当前可直接使用仓库内 `tools/el2` 中的必要引导组件，主要文件如下：

- `slbounceaa64.efi`：slbounce 驱动文件
- `tcblaunch.exe`：已验证版本的 TCB 文件
- `qebspilaa64.efi`：qebspil 编译产物

### 6.1 编译 slbounce

```bash
git clone --recursive https://github.com/TravMurav/slbounce.git
cd slbounce
make CROSS_COMPILE=aarch64-linux-gnu-
```

产物：

- `out/slbounce.efi`

重命名为 `slbounceaa64.efi` 后部署至 `\EFI\systemd\drivers\`。

### 6.2 编译 qebspil

```bash
git clone --recursive https://github.com/stephan-gh/qebspil.git
cd qebspil
make CROSS_COMPILE=aarch64-linux-gnu-
```

产物：

- `out/qebspilaa64.efi`

部署至 `\EFI\systemd\drivers\`。

如需强制启动所有 remoteproc（而非仅限带有 `qcom,broken-reset` 标记的节点）：

```bash
make CROSS_COMPILE=aarch64-linux-gnu- QEBSPIL_ALWAYS_START=1
```

若对平台 DTS 的完整性尚无把握，建议暂不启用此选项。

## 7. 启动后验证

进入系统后，执行以下命令进行验证：

```bash
uname -a
dmesg | grep -Ei 'kvm|hypervisor|el2|q6v5|adsp|cdsp|slpi|remoteproc'
ls -l /dev/kvm
ls /sys/class/remoteproc/
```

重点关注以下几点：

- `/dev/kvm` 是否存在
- 系统是否已运行于 EL2
- remoteproc 节点是否存在且未全部处于离线状态
- 是否存在 ADSP/CDSP/SLPI 相关错误信息

## 8. 排查重点

若表现为“EL2 正常但音频无效”，建议优先按以下顺序检查：

1. 是否已部署 `qebspilaa64.efi`
2. ESP 顶层 `/firmware/...` 目录是否存在，且至少包含
   `qcadsp8280.mbn`、`qccdsp8280.mbn`、`qcslpi8280.mbn`
3. 这些文件名是否与设备树中的 `firmware-name` 属性一致
4. EL2 菜单项是否已加载 `-el2.dtb`
5. EL2 菜单项是否使用了 `-gaokun3-el2` 内核
6. 内核是否包含 qebspil 对应的 remoteproc/PAS 补丁
7. `dmesg` 中是否出现 ADSP/CDSP handover、PAS、IOMMU 或 resource table 相关错误
8. 若 remoteproc 节点未带有 `qcom,broken-reset` 属性，可考虑重新编译并启用 `QEBSPIL_ALWAYS_START=1`

## 9. 最小操作建议

若当前目标仅为恢复音频功能，最小操作步骤如下：

1. 新增 `qebspilaa64.efi`
2. 补全 ESP 上的 3 个 DSP 固件文件
3. 合入 qebspil README 所指向的 handover/PAS 补丁后重新编译 EL2 内核
4. 确认 EL2 菜单项使用 `-gaokun3-el2` 内核和 `-el2.dtb`
5. 验证 ADSP/CDSP/SLPI 的启动情况

在完成上述步骤之前，不建议将精力继续集中于 ALSA 或声卡驱动层面的排查。
