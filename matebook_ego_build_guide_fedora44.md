# Huawei MateBook E Go 2023 Fedora 44 手动构建指南

> **目标机型**：Huawei MateBook E Go 2023 (`SC8280XP` / `gaokun3`)  
> **目标系统**：Fedora 44 GNOME，GRUB 启动，Btrfs 根文件系统  
> **推荐宿主机**：Fedora 或其他基于 RPM/DNF 的发行版  
> **仓库假设**：本文默认你当前仓库位于 `~/gaokun/linux-gaokun-build`

**WSL2 建议切换到支持 `vfat`、`btrfs` 等文件系统更完整的内核，例如：<https://github.com/Nevuly/WSL2-Linux-Kernel-Rolling/releases>**

---

## 准备说明

本文使用项目内已有内容，不需要额外获取设备专属仓库：

- `gaokun-patches/`
- `defconfig/`
- `dts/`
- `tools/`
- `firmware/`

如果宿主机是 arm64，可直接原生构建。  
如果宿主机是 x86_64，请自行准备可用的 aarch64 交叉工具链，并在编译内核时额外设置 `CROSS_COMPILE`。

---

## 第一步：准备工作目录

安装基础依赖（Fedora arm64 宿主机示例）：

```bash
sudo dnf install gcc make bison flex bc openssl-devel elfutils-libelf-devel \
    ncurses-devel dwarves git parted dosfstools btrfs-progs curl python3 rsync
```

准备源码与工作目录：

```bash
mkdir -p ~/gaokun/matebook-build-fedora

cd ~/gaokun
# 获取指定版本的 Linux 主线源码
if [ ! -d "mainline-linux" ]; then
    git clone --depth 1 --branch v7.0-rc4 \
        https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git \
        mainline-linux
fi
```

设置环境变量：

```bash
export GAOKUN_DIR=~/gaokun/linux-gaokun-build
export WORKDIR=~/gaokun/matebook-build-fedora
export KERN_SRC=~/gaokun/mainline-linux
export KERN_OUT=$GAOKUN_DIR/kernel-out
export FW_REPO=$GAOKUN_DIR/firmware
export ROOTFS_DIR=$WORKDIR/rootfs
export IMAGE_FILE=$WORKDIR/fedora-44-gaokun3.img
```

---

## 第二步：编译内核

应用项目内核补丁，并导入仓库内的 DTS 与 defconfig 后构建。
当前触摸屏方案已经统一为内核内的 Himax HX83121A SPI 驱动，不再额外安装 DKMS，也不再依赖旧的 I2C 恢复脚本：

```bash
cd $KERN_SRC

# 应用项目内置补丁
git am $GAOKUN_DIR/gaokun-patches/*.patch

# 覆盖内核源码中的 defconfig，并拷入项目维护的 DTS 文件
install -Dm644 \
    $GAOKUN_DIR/defconfig/gaokun_defconfig \
    $KERN_SRC/arch/arm64/configs/defconfig
install -Dm644 \
    $GAOKUN_DIR/dts/sc8280xp-huawei-gaokun3.dts \
    $KERN_SRC/arch/arm64/boot/dts/qcom/sc8280xp-huawei-gaokun3.dts
install -Dm644 \
    $GAOKUN_DIR/dts/sc8280xp-huawei-gaokun3-camera.dtsi \
    $KERN_SRC/arch/arm64/boot/dts/qcom/sc8280xp-huawei-gaokun3-camera.dtsi

# 临时提交，避免内核版本字符串附带 -dirty
git add \
    arch/arm64/configs/defconfig \
    arch/arm64/boot/dts/qcom/sc8280xp-huawei-gaokun3.dts \
    arch/arm64/boot/dts/qcom/sc8280xp-huawei-gaokun3-camera.dtsi
git diff --cached --quiet || \
    git commit -m "arm64: gaokun3: import local dts and defconfig"

mkdir -p $KERN_OUT

# 先根据覆盖后的 defconfig 生成配置，再补齐新内核默认选项
make O=$KERN_OUT ARCH=arm64 defconfig
make O=$KERN_OUT ARCH=arm64 olddefconfig
make O=$KERN_OUT ARCH=arm64 -j$(nproc)

KREL=$(cat $KERN_OUT/include/config/kernel.release)
echo $KREL
```

---

## 第三步：构建 RootFS

使用 `dnf --installroot` 安装 Fedora 44 GNOME Desktop，并补充启动、网络、输入法和常用工具。

> 若宿主机是 Ubuntu 等非 Fedora 系统，可先安装 `dnf`，然后继续使用 `--installroot` 方式构建。

```bash
mkdir -p $ROOTFS_DIR

export LANG=zh_CN.UTF-8

# 第一步先安装基础系统、locale 和 langpacks
sudo dnf --installroot=$ROOTFS_DIR --releasever=44 --forcearch=aarch64 --use-host-config -y \
    install \
    @core @standard \
    grub2-efi-aa64-modules efibootmgr shim-aa64 alsa-ucm \
    glibc-langpack-en glibc-langpack-zh \
    langpacks-en langpacks-zh_CN ibus-typing-booster \
    i2c-tools alsa-utils pipewire-utils

sudo mkdir -p $ROOTFS_DIR/etc
sudo tee $ROOTFS_DIR/etc/locale.conf > /dev/null <<EOF
LANG=zh_CN.UTF-8
LC_MESSAGES=zh_CN.UTF-8
EOF

# 第二步再安装桌面环境和应用，能更稳定地把中文翻译子包一起拉进 rootfs
sudo dnf --installroot=$ROOTFS_DIR --releasever=44 --forcearch=aarch64 --use-host-config -y \
    --exclude=gnome-boxes,gnome-connections,gnome-browser-connector,snapshot,gnome-weather,gnome-contacts,gnome-maps,simple-scan,gnome-clocks,gnome-calculator,gnome-calendar \
    install \
    @gnome-desktop \
    fcitx5-chinese-addons gnome-tweaks telnet mpv v4l-utils vim git htop fastfetch screen firefox
```

安装内核、模块、固件和本地工具：

```bash
cd $KERN_SRC

KREL=$(cat $KERN_OUT/include/config/kernel.release)
echo $KREL

sudo make O=$KERN_OUT ARCH=arm64 INSTALL_MOD_PATH=$ROOTFS_DIR modules_install
sudo rm -f $ROOTFS_DIR/lib/modules/$KREL/{build,source}

# 安装 kernel image
sudo mkdir -p $ROOTFS_DIR/boot
sudo cp $KERN_OUT/arch/arm64/boot/Image \
    $ROOTFS_DIR/boot/vmlinuz-$KREL

# 创建 dtb 目录结构，供 GRUB 使用
sudo mkdir -p $ROOTFS_DIR/boot/dtb-$KREL/qcom
sudo cp $KERN_OUT/arch/arm64/boot/dts/qcom/sc8280xp-huawei-gaokun3.dtb \
    $ROOTFS_DIR/boot/dtb-$KREL/qcom/

# 直接复制项目内置的最小固件集
sudo mkdir -p $ROOTFS_DIR/lib/firmware
sudo cp -r $FW_REPO/. $ROOTFS_DIR/lib/firmware/

# 安装项目内的设备专属脚本与服务
sudo mkdir -p $ROOTFS_DIR/usr/local/bin
sudo mkdir -p $ROOTFS_DIR/etc/systemd/system
sudo mkdir -p $ROOTFS_DIR/usr/share/alsa/ucm2/Qualcomm/sc8280xp

sudo cp $GAOKUN_DIR/tools/touchpad/huawei-tp-activate.py \
    $ROOTFS_DIR/usr/local/bin/
sudo cp $GAOKUN_DIR/tools/touchpad/huawei-touchpad.service \
    $ROOTFS_DIR/etc/systemd/system/
sudo chmod +x $ROOTFS_DIR/usr/local/bin/huawei-tp-activate.py

sudo cp $GAOKUN_DIR/tools/monitors/gdm-monitor-sync \
    $ROOTFS_DIR/usr/local/bin/
sudo cp $GAOKUN_DIR/tools/monitors/gdm-monitor-sync.service \
    $ROOTFS_DIR/etc/systemd/system/
sudo chmod +x $ROOTFS_DIR/usr/local/bin/gdm-monitor-sync

sudo cp $GAOKUN_DIR/tools/bluetooth/patch-nvm-bdaddr.py \
    $ROOTFS_DIR/usr/local/bin/
sudo chmod +x $ROOTFS_DIR/usr/local/bin/patch-nvm-bdaddr.py

sudo cp $GAOKUN_DIR/tools/audio/sc8280xp.conf \
    $ROOTFS_DIR/usr/share/alsa/ucm2/Qualcomm/sc8280xp/
```

---

## 第四步：制作可启动镜像

### 1. 创建镜像和分区

```bash
cd $WORKDIR
truncate -s 12G $IMAGE_FILE

parted -s $IMAGE_FILE mklabel gpt
parted -s $IMAGE_FILE mkpart EFI fat32 1MiB 256MiB
parted -s $IMAGE_FILE set 1 esp on
parted -s $IMAGE_FILE mkpart rootfs btrfs 256MiB 100%

LOOP=$(sudo losetup --show -fP $IMAGE_FILE)
sudo mkfs.vfat -F32 -n EFI ${LOOP}p1
sudo mkfs.btrfs -f -L rootfs ${LOOP}p2

EFI_UUID=$(sudo blkid -s UUID -o value ${LOOP}p1)
ROOT_UUID=$(sudo blkid -s UUID -o value ${LOOP}p2)
```

### 2. 创建 Btrfs 子卷并同步 RootFS

```bash
sudo mkdir -p /mnt/ego-fedora

# 创建 Fedora 常见子卷布局：@ 用于根分区，@home 用于家目录，@var 用于 /var
sudo mount ${LOOP}p2 /mnt/ego-fedora
sudo btrfs subvolume create /mnt/ego-fedora/@
sudo btrfs subvolume create /mnt/ego-fedora/@home
sudo btrfs subvolume create /mnt/ego-fedora/@var
sudo umount /mnt/ego-fedora

# 挂载子卷并准备 EFI 分区
sudo mount -o subvol=@ ${LOOP}p2 /mnt/ego-fedora
sudo mkdir -p /mnt/ego-fedora/home
sudo mount -o subvol=@home ${LOOP}p2 /mnt/ego-fedora/home
sudo mkdir -p /mnt/ego-fedora/var
sudo mount -o subvol=@var ${LOOP}p2 /mnt/ego-fedora/var
sudo mkdir -p /mnt/ego-fedora/boot/efi
sudo mount ${LOOP}p1 /mnt/ego-fedora/boot/efi

sudo rsync -aHAX --info=progress2 $ROOTFS_DIR/ /mnt/ego-fedora/

sudo tee /mnt/ego-fedora/etc/fstab > /dev/null <<EOF
UUID=${ROOT_UUID}  /         btrfs  subvol=@,compress=zstd:1,ssd,noatime  0  0
UUID=${ROOT_UUID}  /home     btrfs  subvol=@home,compress=zstd:1,ssd,noatime  0  0
UUID=${ROOT_UUID}  /var      btrfs  subvol=@var,compress=zstd:1,ssd,noatime  0  0
UUID=${EFI_UUID}   /boot/efi vfat   defaults,nofail,x-systemd.device-timeout=10s  0  2
EOF
```

### 3. chroot 初始化并生成 GRUB

```bash
# 建议统一清理挂载，避免中途中断后留下残留状态
cleanup_mounts() {
    sudo umount /mnt/ego-fedora/dev/pts 2>/dev/null || true
    sudo umount /mnt/ego-fedora/boot/efi 2>/dev/null || true
    sudo umount /mnt/ego-fedora/var 2>/dev/null || true
    sudo umount /mnt/ego-fedora/home 2>/dev/null || true
    sudo umount /mnt/ego-fedora/dev 2>/dev/null || true
    sudo umount /mnt/ego-fedora/proc 2>/dev/null || true
    sudo umount /mnt/ego-fedora/sys 2>/dev/null || true
    sudo umount /mnt/ego-fedora/run 2>/dev/null || true
    sudo umount /mnt/ego-fedora 2>/dev/null || true
}
trap cleanup_mounts EXIT

sudo mount --bind /dev /mnt/ego-fedora/dev
sudo mount --bind /dev/pts /mnt/ego-fedora/dev/pts
sudo mount -t proc proc /mnt/ego-fedora/proc
sudo mount -t sysfs sys /mnt/ego-fedora/sys
sudo mount -t tmpfs tmpfs /mnt/ego-fedora/run

sudo chroot /mnt/ego-fedora /bin/bash
```

在 chroot 中执行：

```bash
KREL="$(ls /lib/modules/ | head -n1)"

# 创建默认用户与主机名
echo "fedora" > /etc/hostname
useradd -m -s /bin/bash -G wheel user
echo "user:user" | chpasswd
mkdir -p /etc/sudoers.d
echo "%wheel ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/wheel-nopasswd
chmod 440 /etc/sudoers.d/wheel-nopasswd
cat > /etc/locale.conf <<EOF
LANG=zh_CN.UTF-8
LC_MESSAGES=zh_CN.UTF-8
EOF

# 预置屏幕方向与缩放，并同步给 GDM 登录界面
mkdir -p /home/user/.config
cat > /home/user/.config/monitors.xml <<EOF
<monitors version="2">
    <configuration>
        <layoutmode>logical</layoutmode>
        <logicalmonitor>
            <x>0</x>
            <y>0</y>
            <scale>1.6666666269302368</scale>
            <primary>yes</primary>
            <transform>
                <rotation>right</rotation>
                <flipped>no</flipped>
            </transform>
            <monitor>
                <monitorspec>
                    <connector>DSI-1</connector>
                    <vendor>unknown</vendor>
                    <product>unknown</product>
                    <serial>unknown</serial>
                </monitorspec>
                <mode>
                    <width>1600</width>
                    <height>2560</height>
                    <rate>60.000</rate>
                </mode>
            </monitor>
        </logicalmonitor>
    </configuration>
</monitors>
EOF
chown user:user /home/user/.config/monitors.xml

# 开启图形、网络、SSH、触控板和首启显示同步服务
systemctl enable gdm NetworkManager sshd huawei-touchpad.service \
    gdm-monitor-sync.service

# 运行时与 dracut 都需要的关键模块
# 触摸屏驱动会由设备树自动匹配加载，无需额外写入 modules-load.d
mkdir -p /etc/modules-load.d
echo -e "pci-pwrctrl-pwrseq\nath11k_pci" > /etc/modules-load.d/wifi.conf
echo "btqca" > /etc/modules-load.d/bluetooth.conf
echo -e "panel-himax-hx83121a\nmsm\nhid_multitouch" > /etc/modules-load.d/display.conf
echo -e "lpasscc_sc8280xp\nsnd-soc-sc8280xp" > /etc/modules-load.d/audio.conf
echo -e "huawei-gaokun-ec\nhuawei-gaokun-battery\nucsi_huawei_gaokun" > /etc/modules-load.d/battery.conf

mkdir -p /etc/modprobe.d
echo "softdep pinctrl_sc8280xp_lpass_lpi pre: lpasscc_sc8280xp" > /etc/modprobe.d/audio-deps.conf

# Fedora 默认使用 dracut 生成 initramfs
cat > /etc/dracut.conf.d/matebook.conf <<MODEOF
hostonly="no"
add_drivers+=" btrfs nvme phy-qcom-qmp-pcie phy-qcom-qmp-combo phy-qcom-qmp-usb phy-qcom-snps-femto-v2 usb-storage uas typec pci-pwrctrl-pwrseq ath11k ath11k_pci panel-himax-hx83121a msm i2c-hid-of lpasscc_sc8280xp snd-soc-sc8280xp pinctrl_sc8280xp_lpass_lpi "
MODEOF

dracut --force --kver $KREL

ROOT_UUID="$(blkid -s UUID -o value /dev/disk/by-label/rootfs)"

cat > /etc/default/grub <<GRUBEOF
GRUB_DEFAULT=saved
GRUB_TIMEOUT=5
GRUB_DISTRIBUTOR="Fedora"
GRUB_ENABLE_BLSCFG=false
GRUB_CMDLINE_LINUX="clk_ignore_unused pd_ignore_unused arm64.nopauth iommu.passthrough=0 iommu.strict=0 pcie_aspm.policy=powersupersave modprobe.blacklist=simpledrm efi=noruntime fbcon=rotate:1 usbhid.quirks=0x12d1:0x10b8:0x20000000 consoleblank=0 loglevel=4 psi=1"
GRUB_DEFAULT_DTB="qcom/sc8280xp-huawei-gaokun3.dtb"
GRUBEOF

# 仅在生成镜像时临时禁用 os-prober，避免把宿主机系统探测进来
echo 'GRUB_DISABLE_OS_PROBER=true' >> /etc/default/grub
grub2-install --target=arm64-efi --efi-directory=/boot/efi --boot-directory=/boot --removable --force
grub2-mkconfig -o /boot/grub2/grub.cfg
sed -i '/^GRUB_DISABLE_OS_PROBER=true$/d' /etc/default/grub

# 给 EFI 分区写一个桥接 grub.cfg，按 rootfs UUID 找到真正菜单
mkdir -p /boot/efi/EFI/BOOT /boot/efi/EFI/fedora
cat > /boot/efi/EFI/BOOT/grub.cfg <<EOF
search --no-floppy --fs-uuid --set=root ${ROOT_UUID}
if [ -f (\$root)/@/boot/grub2/grub.cfg ]; then
    set prefix=(\$root)/@/boot/grub2
    configfile (\$root)/@/boot/grub2/grub.cfg
elif [ -f (\$root)/boot/grub2/grub.cfg ]; then
    set prefix=(\$root)/boot/grub2
    configfile (\$root)/boot/grub2/grub.cfg
else
    echo "ERROR: grub.cfg not found on rootfs UUID ${ROOT_UUID}"
    echo "Tried: /@/boot/grub2/grub.cfg and /boot/grub2/grub.cfg"
    sleep 5
fi
EOF
cp /boot/efi/EFI/BOOT/grub.cfg /boot/efi/EFI/fedora/grub.cfg

# 可选：确认最终 grub.cfg 中已经带上 devicetree
grep -n "devicetree" /boot/grub2/grub.cfg
exit
```

回到宿主机后清理挂载：

```bash
trap - EXIT
cleanup_mounts
sudo losetup -d $LOOP
```

---

## 第五步：刷写镜像

镜像生成后位于：

```bash
$WORKDIR/fedora-44-gaokun3.img
```

推荐先刷入 USB 存储：

```bash
sudo dd if=$IMAGE_FILE of=/dev/sdX bs=4M status=progress conv=fsync
```

也可以使用 `balenaEtcher`、`Rufus`、`gnome-disks` 等图形工具。

刷入后开机按 `F12`，在 UEFI 启动菜单里选择对应的 USB 引导项启动。

如果要写入机器内置 NVMe，还需要额外分区、复制系统并调整 EFI 引导项，不建议把上面的 `dd` 目标直接替换成内置盘设备名后盲刷。

---

## 额外说明

- 编译完成后可用 `grep CONFIG_TOUCHSCREEN_HIMAX_HX83121A_SPI $KERN_OUT/.config` 确认 SPI 触摸驱动已进入当前内核配置
- 首次启动后如需扩容，可使用 `gnome-disks`，或执行 `btrfs filesystem resize max /`
- 文中所有 `tools/` 与 firmware 都来自当前仓库，不依赖外部设备专属仓库
- 如果你需要自动化构建，可直接参考 GitHub Actions workflow：`.github/workflows/fedora-gaokun3-release.yml`
- 如果 GDM 登录界面的方向、主屏或外接显示器布局不对，先在用户会话里调好显示设置，再把 `~/.config/monitors.xml` 复制到 `/var/lib/gdm/seat0/config/monitors.xml`，并执行 `chown --reference=/var/lib/gdm/seat0/config /var/lib/gdm/seat0/config/monitors.xml`
