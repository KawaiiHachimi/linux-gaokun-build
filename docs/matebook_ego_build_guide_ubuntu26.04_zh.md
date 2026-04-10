[English](matebook_ego_build_guide_ubuntu26.04_en.md) | 中文

# Huawei MateBook E Go 2023 Ubuntu 26.04 手动构建指南

> **目标机型**：Huawei MateBook E Go 2023（代号 `gaokun3`）  
> **平台**：高通骁龙 8cx Gen3（`SC8280XP`）  
> **目标系统**：Ubuntu 26.04 (Resolute Raccoon) GNOME，systemd-boot 启动，ext4 根文件系统  
> **推荐宿主机**：Ubuntu/Debian 或其他支持 `debootstrap` 的发行版  
> **仓库假设**：本文默认你当前仓库位于 `~/gaokun/linux-gaokun-buildbot`

**WSL2 建议切换到支持 `vfat`、`ext4` 等文件系统更完整的内核，例如：<https://github.com/Nevuly/WSL2-Linux-Kernel-Rolling/releases>**

---

## 准备说明

本文使用项目内已有内容，不需要额外获取设备专属仓库：

- `patches/`
- `defconfig/`
- `dts/`
- `tools/`
- `firmware/`

如果宿主机是 arm64，可直接原生构建。  
如果宿主机是 x86_64，请自行准备可用的 aarch64 交叉工具链，并在编译内核时额外设置 `CROSS_COMPILE`。

---

## 第一步：准备工作目录

安装基础依赖（Ubuntu 宿主机示例）：

```bash
sudo apt-get update
sudo apt-get install -y \
    gcc make bison flex bc libssl-dev libelf-dev dwarves \
    git parted dosfstools e2fsprogs curl python3 rsync ccache \
    debootstrap qemu-user-static binfmt-support zstd xz-utils kmod
```

准备源码与工作目录：

```bash
mkdir -p ~/gaokun/matebook-build-ubuntu

cd ~/gaokun
# 获取指定版本的 Linux 主线源码
if [ ! -d "mainline-linux" ]; then
    git clone --depth 1 --branch v7.0-rc7 \
        https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git \
        mainline-linux
fi
```

设置环境变量：

```bash
export GAOKUN_DIR=~/gaokun/linux-gaokun-buildbot
export WORKDIR=~/gaokun/matebook-build-ubuntu
export KERN_SRC=~/gaokun/mainline-linux
export KERN_OUT=~/gaokun/kernel-out
export KERN_OUT_EL2=~/gaokun/kernel-out-el2
export FW_REPO=$GAOKUN_DIR/firmware
export ROOTFS_DIR=$WORKDIR/rootfs
export IMAGE_FILE=$WORKDIR/ubuntu-26.04-gaokun3.img
export CCACHE_DIR=$WORKDIR/.ccache
export CCACHE_BASEDIR=$WORKDIR
export CCACHE_NOHASHDIR=true
export CCACHE_COMPILERCHECK=content
if [ -d /usr/lib64/ccache ]; then
    export PATH=/usr/lib64/ccache:$PATH
elif [ -d /usr/lib/ccache ]; then
    export PATH=/usr/lib/ccache:$PATH
fi
```

---

## 第二步：编译内核

先编译标准内核。

```bash
cd $KERN_SRC

# 应用项目内置补丁
git config user.name "local builder"
git config user.email "builder@example.com"
git am $GAOKUN_DIR/patches/*.patch

mkdir -p $KERN_OUT
ccache -z

# 根据 patch 后的 gaokun3_defconfig 生成配置，再补齐新内核默认选项
make O=$KERN_OUT ARCH=arm64 gaokun3_defconfig
make O=$KERN_OUT ARCH=arm64 olddefconfig
make O=$KERN_OUT ARCH=arm64 -j$(nproc)
make O=$KERN_OUT ARCH=arm64 modules_prepare

KREL=$(cat $KERN_OUT/include/config/kernel.release)
echo $KREL
KREL_EL2=""
ccache -s
```

如果你需要 EL2，建议先把标准内核安装到 rootfs，或者先单独备份好 `Image`、`dtb`、`modules` 产物，然后在同一套源码上继续构建带 `-gaokun3-el2` 后缀的内核，EL2 产物单独放到另一个输出目录：

```bash
rm -rf $KERN_OUT_EL2
git -C $KERN_SRC apply --index $GAOKUN_DIR/patches/el2/*.patch
git -C $KERN_SRC commit -m "Apply EL2 patches"
ccache -z

make -C $KERN_SRC O=$KERN_OUT_EL2 ARCH=arm64 gaokun3_defconfig
$KERN_SRC/scripts/config --file $KERN_OUT_EL2/.config --set-str LOCALVERSION "-gaokun3-el2"
make -C $KERN_SRC O=$KERN_OUT_EL2 ARCH=arm64 olddefconfig
make -C $KERN_SRC O=$KERN_OUT_EL2 ARCH=arm64 -j$(nproc)
make -C $KERN_SRC O=$KERN_OUT_EL2 ARCH=arm64 modules_prepare

KREL_EL2=$(cat $KERN_OUT_EL2/include/config/kernel.release)
echo $KREL_EL2
ccache -s
```

---

## 第三步：构建 RootFS

使用 Ubuntu 官方 `ubuntu-base` 预构建 rootfs 作为基础，然后通过 chroot 安装桌面环境与额外软件包。

> 如果宿主机是 x86_64，需要拷贝 `qemu-aarch64-static` 到 rootfs 中以支持 chroot 执行 arm64 二进制。  
> [avikivity/qemu-aarch64-static-fast](https://github.com/avikivity/qemu-aarch64-static-fast) 是一个 QEMU 用户态模拟器的参数包装器 (Wrapper)。它通过在运行时动态注入高性能 CPU 标志位（如 `pauth-impdef=on`），透明地提升 AArch64 程序在非原生环境下的运行效率。

```bash
mkdir -p $ROOTFS_DIR

# 下载 ubuntu-base 预构建 rootfs（自带正确的 apt 源配置，无需手动写入）
UBUNTU_BASE_URL="https://cdimages.ubuntu.com/ubuntu-base/releases/26.04/release/ubuntu-base-26.04-base-arm64.tar.gz"
UBUNTU_BASE_BETA_URL="https://cdimages.ubuntu.com/ubuntu-base/releases/26.04/beta/ubuntu-base-26.04-beta-base-arm64.tar.gz"
UBUNTU_BASE_TAR=$WORKDIR/ubuntu-base-arm64.tar.gz

if ! curl -fsSL -o "$UBUNTU_BASE_TAR" "$UBUNTU_BASE_URL"; then
    echo "Release tarball not found, trying beta..."
    curl -fsSL -o "$UBUNTU_BASE_TAR" "$UBUNTU_BASE_BETA_URL"
fi

sudo tar -xzf "$UBUNTU_BASE_TAR" -C $ROOTFS_DIR

# x86_64 宿主机：拷贝 qemu-aarch64-static 以支持 chroot
if [ "$(uname -m)" != "aarch64" ]; then
    sudo cp "$(which qemu-aarch64-static)" $ROOTFS_DIR/usr/bin/
fi
```

挂载虚拟文件系统并进入 chroot 安装软件包：

```bash
sudo mount --bind /dev $ROOTFS_DIR/dev
sudo mount --bind /dev/pts $ROOTFS_DIR/dev/pts
sudo mount -t proc proc $ROOTFS_DIR/proc
sudo mount -t sysfs sys $ROOTFS_DIR/sys
sudo mount -t tmpfs tmpfs $ROOTFS_DIR/run

# 复制 DNS 配置以便 chroot 内可以联网
if [ -L "$ROOTFS_DIR/etc/resolv.conf" ] || [ -e "$ROOTFS_DIR/etc/resolv.conf" ]; then
    sudo mv $ROOTFS_DIR/etc/resolv.conf $ROOTFS_DIR/etc/resolv.conf.bak
fi
sudo cp /etc/resolv.conf $ROOTFS_DIR/etc/resolv.conf

sudo chroot $ROOTFS_DIR /bin/bash
```

在 chroot 中执行：

```bash
export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get install -y locales
sed -i 's/# zh_CN.UTF-8/zh_CN.UTF-8/' /etc/locale.gen
locale-gen
update-locale LANG=zh_CN.UTF-8 LANGUAGE=zh_CN:en_US:en LC_MESSAGES=zh_CN.UTF-8
rm -f /etc/resolv.conf
ln -s /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf

# 先安装内核相关依赖以及 initramfs-tools
apt-get install -y \
    linux-base initramfs-tools kmod

apt-get install -y --no-install-recommends \
    systemd-boot systemd-boot-efi

# 安装基础网络与压缩工具（ubuntu-base 中可能缺失）
apt-get install -y \
    iputils-ping iproute2 net-tools dnsutils traceroute \
    xz-utils unzip zip bzip2 zstd p7zip-full \
    wget curl ca-certificates gnupg lsb-release \
    less file sudo

# 配置 Mozilla 官方 APT 仓库，安装原生 deb 版 Firefox
install -d -m 0755 /etc/apt/keyrings
wget -qO- https://packages.mozilla.org/apt/repo-signing-key.gpg | \
    gpg --dearmor -o /etc/apt/keyrings/packages.mozilla.org.gpg

cat > /etc/apt/sources.list.d/mozilla.list <<EOF
deb [signed-by=/etc/apt/keyrings/packages.mozilla.org.gpg] https://packages.mozilla.org/apt mozilla main
EOF

cat > /etc/apt/preferences.d/mozilla <<EOF
Package: *
Pin: origin packages.mozilla.org
Pin-Priority: 1000
EOF

apt-get update

# 安装桌面环境与常用软件
apt-get install -y \
    ubuntu-desktop-minimal \
    language-pack-gnome-zh-hans \
    fonts-noto-cjk \
    fonts-noto-color-emoji \
    fcitx5-chinese-addons \
    gnome-tweaks gnome-shell-extension-manager \
    mpv v4l-utils vim nano ripgrep git htop screen \
    alsa-utils pipewire-alsa \
    ssh \
    firefox

# 安装多媒体编解码器
apt-get install -y \
    gstreamer1.0-libav gstreamer1.0-plugins-ugly \
    ubuntu-restricted-extras

apt-get clean
exit
```

回到宿主机，安装内核、模块、固件和本地工具到 rootfs：

```bash
cd $KERN_SRC

KREL=$(cat $KERN_OUT/include/config/kernel.release)
echo $KREL

sudo make O=$KERN_OUT ARCH=arm64 INSTALL_MOD_PATH=$ROOTFS_DIR modules_install
sudo rm -f $ROOTFS_DIR/lib/modules/$KREL/{build,source}

# 按 Ubuntu 风格安装 kernel image
sudo mkdir -p $ROOTFS_DIR/boot
sudo cp $KERN_OUT/arch/arm64/boot/Image \
    $ROOTFS_DIR/boot/vmlinuz-$KREL

# Ubuntu 的 kernel-install 会从这里查找 DTB
sudo mkdir -p $ROOTFS_DIR/usr/lib/linux-image-$KREL/qcom
sudo cp $KERN_OUT/arch/arm64/boot/dts/qcom/sc8280xp-huawei-gaokun3.dtb \
     $ROOTFS_DIR/usr/lib/linux-image-$KREL/qcom/sc8280xp-huawei-gaokun3.dtb

# 额外保留一份 /boot 下的 DTB，方便后续切换到 GRUB 等其他引导器
sudo mkdir -p $ROOTFS_DIR/boot
sudo cp $KERN_OUT/arch/arm64/boot/dts/qcom/sc8280xp-huawei-gaokun3.dtb \
     $ROOTFS_DIR/boot/dtb-$KREL

# 如果需要 EL2，再安装第二套 EL2 内核与 DTB
if [ -n "$KREL_EL2" ]; then
    sudo make -C $KERN_SRC O=$KERN_OUT_EL2 ARCH=arm64 INSTALL_MOD_PATH=$ROOTFS_DIR modules_install
    sudo rm -f $ROOTFS_DIR/lib/modules/$KREL_EL2/{build,source}
    sudo cp $KERN_OUT_EL2/arch/arm64/boot/Image \
        $ROOTFS_DIR/boot/vmlinuz-$KREL_EL2
    sudo mkdir -p $ROOTFS_DIR/usr/lib/linux-image-$KREL_EL2/qcom
    sudo cp $KERN_OUT_EL2/arch/arm64/boot/dts/qcom/sc8280xp-huawei-gaokun3-el2.dtb \
         $ROOTFS_DIR/usr/lib/linux-image-$KREL_EL2/qcom/sc8280xp-huawei-gaokun3-el2.dtb
    sudo mkdir -p $ROOTFS_DIR/boot
    sudo cp $KERN_OUT_EL2/arch/arm64/boot/dts/qcom/sc8280xp-huawei-gaokun3-el2.dtb \
         $ROOTFS_DIR/boot/dtb-$KREL_EL2
fi

# 直接复制项目内置的最小固件集
sudo mkdir -p $ROOTFS_DIR/lib/firmware
sudo cp -r $FW_REPO/. $ROOTFS_DIR/lib/firmware/

# 安装项目内的设备专属脚本与服务
sudo mkdir -p $ROOTFS_DIR/usr/local/bin
sudo mkdir -p $ROOTFS_DIR/usr/local/lib/gaokun-touchscreen-tuner
sudo mkdir -p $ROOTFS_DIR/etc/systemd/system
sudo mkdir -p $ROOTFS_DIR/usr/share/alsa/ucm2/Qualcomm/sc8280xp
sudo mkdir -p $ROOTFS_DIR/usr/share/applications

# 触摸屏调参工具和桌面入口
sudo cp $GAOKUN_DIR/tools/touchscreen-tuner/touchscreen-tune \
    $ROOTFS_DIR/usr/local/bin/touchscreen-tune
sudo cp $GAOKUN_DIR/tools/touchscreen-tuner/tune.py \
    $ROOTFS_DIR/usr/local/lib/gaokun-touchscreen-tuner/tune.py
sudo cp $GAOKUN_DIR/tools/touchscreen-tuner/touchscreen-tune.desktop \
    $ROOTFS_DIR/usr/share/applications/touchscreen-tune.desktop
sudo chmod +x $ROOTFS_DIR/usr/local/bin/touchscreen-tune

# 触控板激活脚本和服务
sudo cp $GAOKUN_DIR/tools/touchpad/huawei-tp-activate.py \
    $ROOTFS_DIR/usr/local/bin/
sudo cp $GAOKUN_DIR/tools/touchpad/huawei-touchpad.service \
    $ROOTFS_DIR/etc/systemd/system/
sudo chmod +x $ROOTFS_DIR/usr/local/bin/huawei-tp-activate.py

# GDM 显示器同步脚本和服务
sudo cp $GAOKUN_DIR/tools/monitors/gdm-monitor-sync \
    $ROOTFS_DIR/usr/local/bin/
sudo cp $GAOKUN_DIR/tools/monitors/gdm-monitor-sync.service \
    $ROOTFS_DIR/etc/systemd/system/
sudo chmod +x $ROOTFS_DIR/usr/local/bin/gdm-monitor-sync

# 蓝牙地址修补脚本和服务
sudo cp $GAOKUN_DIR/tools/bluetooth/patch-nvm-bdaddr.py \
    $ROOTFS_DIR/usr/local/bin/
sudo chmod +x $ROOTFS_DIR/usr/local/bin/patch-nvm-bdaddr.py

# 音频 UCM 配置
sudo cp $GAOKUN_DIR/tools/audio/sc8280xp.conf \
    $ROOTFS_DIR/usr/share/alsa/ucm2/Qualcomm/sc8280xp/

# 复用 CI 镜像流水线里的共享资源
sudo mkdir -p $ROOTFS_DIR/usr/local/share/gaokun
sudo cp -a $GAOKUN_DIR/tools/image-assets/etc/. \
    $ROOTFS_DIR/etc/
sudo cp $GAOKUN_DIR/tools/image-assets/usr/local/share/gaokun/monitors.xml \
    $ROOTFS_DIR/usr/local/share/gaokun/monitors.xml

# 让 Ubuntu 的 initramfs-tools 在早期启动阶段就带上 DSP 固件，
# 否则标准启动项里 remoteproc 可能在根文件系统挂载前就因找不到固件而失败
sudo mkdir -p $ROOTFS_DIR/etc/initramfs-tools/hooks
sudo tee $ROOTFS_DIR/etc/initramfs-tools/hooks/gaokun3-firmware > /dev/null <<'EOF'
#!/bin/sh
set -e

. /usr/share/initramfs-tools/hook-functions

copy_fw() {
    copy_file firmware "$1" || [ "$?" -eq 1 ]
}

copy_fw /lib/firmware/qcom/sc8280xp/HUAWEI/gaokun3/qcadsp8280.mbn
copy_fw /lib/firmware/qcom/sc8280xp/HUAWEI/gaokun3/qccdsp8280.mbn
copy_fw /lib/firmware/qcom/sc8280xp/HUAWEI/gaokun3/qcslpi8280.mbn
copy_fw /lib/firmware/qcom/sc8280xp/HUAWEI/gaokun3/audioreach-tplg.bin
EOF
sudo chmod 0755 $ROOTFS_DIR/etc/initramfs-tools/hooks/gaokun3-firmware
```

卸载之前的虚拟文件系统：

```bash
sudo umount $ROOTFS_DIR/dev/pts
sudo umount $ROOTFS_DIR/dev
sudo umount $ROOTFS_DIR/proc
sudo umount $ROOTFS_DIR/sys
sudo umount $ROOTFS_DIR/run
```

---

## 第四步：制作可启动镜像

### 1. 创建镜像和分区

```bash
cd $WORKDIR
truncate -s 12G $IMAGE_FILE

parted -s $IMAGE_FILE mklabel gpt
parted -s $IMAGE_FILE mkpart EFI fat32 1MiB 1025MiB
parted -s $IMAGE_FILE set 1 esp on
parted -s $IMAGE_FILE mkpart rootfs ext4 1025MiB 100%

LOOP=$(sudo losetup --show -fP $IMAGE_FILE)
sudo mkfs.vfat -F32 -n EFI ${LOOP}p1
sudo mkfs.ext4 -L rootfs ${LOOP}p2

EFI_UUID=$(sudo blkid -s UUID -o value ${LOOP}p1)
ROOT_UUID=$(sudo blkid -s UUID -o value ${LOOP}p2)
```

### 2. 同步 RootFS 到镜像

```bash
MNT=/mnt/ego-ubuntu

sudo mkdir -p $MNT
sudo mount ${LOOP}p2 $MNT
sudo mkdir -p $MNT/boot/efi
sudo mount ${LOOP}p1 $MNT/boot/efi

sudo rsync -aHAX --info=progress2 --exclude='/proc/*' --exclude='/sys/*' --exclude='/dev/*' --exclude='/run/*' $ROOTFS_DIR/ $MNT/

sudo tee $MNT/etc/fstab > /dev/null <<EOF
UUID=${ROOT_UUID}  /         ext4   errors=remount-ro,noatime  0  1
UUID=${EFI_UUID}   /boot/efi vfat   defaults,nofail,x-systemd.device-timeout=10s  0  2
EOF
```

### 3. chroot 初始化并生成 systemd-boot / BLS

```bash
cleanup_mounts() {
    sudo umount $MNT/dev/pts 2>/dev/null || true
    sudo umount $MNT/boot/efi 2>/dev/null || true
    sudo umount $MNT/dev 2>/dev/null || true
    sudo umount $MNT/proc 2>/dev/null || true
    sudo umount $MNT/sys 2>/dev/null || true
    sudo umount $MNT/run 2>/dev/null || true
    sudo umount $MNT 2>/dev/null || true
}

sudo mount --bind /dev $MNT/dev
sudo mount --bind /dev/pts $MNT/dev/pts
sudo mount -t proc proc $MNT/proc
sudo mount -t sysfs sys $MNT/sys
sudo mount -t tmpfs tmpfs $MNT/run

sudo chroot $MNT /bin/bash
```

在 chroot 中执行：

```bash
install -d /etc/kernel
cat > /etc/kernel/install.conf <<EOF
layout=bls
EOF

cat > /etc/kernel/cmdline <<EOF
root=UUID=${ROOT_UUID} clk_ignore_unused pd_ignore_unused arm64.nopauth iommu.passthrough=0 iommu.strict=0 pcie_aspm.policy=powersupersave modprobe.blacklist=simpledrm efi=noruntime fbcon=rotate:1 usbhid.quirks=0x12d1:0x10b8:0x20000000 consoleblank=0 loglevel=4 psi=1
EOF

cat > /etc/kernel/devicetree <<EOF
qcom/sc8280xp-huawei-gaokun3.dtb
EOF

run_update_initramfs() {
    local krel="$1"
    local dtb="$2"

    printf 'qcom/%s\n' "$dtb" > /etc/kernel/devicetree
    update-initramfs -c -k "$krel"
}

run_update_initramfs $KREL sc8280xp-huawei-gaokun3.dtb
if [ -n "$KREL_EL2" ]; then
    run_update_initramfs $KREL_EL2 sc8280xp-huawei-gaokun3-el2.dtb
fi

rm -f /etc/machine-id
systemd-machine-id-setup
MACHINE_ID=$(cat /etc/machine-id)

bootctl --no-variables --esp-path=/boot/efi install

kernel-install --make-entry-directory=yes --entry-token=machine-id add \
    $KREL /boot/vmlinuz-$KREL /boot/initrd.img-$KREL

if [ -n "$KREL_EL2" ]; then
    mkdir -p /boot/efi/EFI/systemd/drivers
    mkdir -p /boot/efi/firmware/qcom/sc8280xp/HUAWEI/gaokun3

    EL2_CONF_ROOT=$(mktemp -d)
    cat > $EL2_CONF_ROOT/install.conf <<EOF
layout=bls
EOF
    cat > $EL2_CONF_ROOT/cmdline <<EOF
root=UUID=${ROOT_UUID} clk_ignore_unused pd_ignore_unused arm64.nopauth iommu.passthrough=0 iommu.strict=0 pcie_aspm.policy=powersupersave modprobe.blacklist=simpledrm efi=noruntime fbcon=rotate:1 usbhid.quirks=0x12d1:0x10b8:0x20000000 consoleblank=0 loglevel=4 psi=1
EOF
    cat > $EL2_CONF_ROOT/devicetree <<EOF
qcom/sc8280xp-huawei-gaokun3-el2.dtb
EOF
    KERNEL_INSTALL_CONF_ROOT=$EL2_CONF_ROOT \
        kernel-install --make-entry-directory=yes --entry-token=machine-id add \
        $KREL_EL2 /boot/vmlinuz-$KREL_EL2 /boot/initrd.img-$KREL_EL2
    rm -rf $EL2_CONF_ROOT

    cp $GAOKUN_DIR/tools/el2/slbounceaa64.efi /boot/efi/EFI/systemd/drivers/
    cp $GAOKUN_DIR/tools/el2/qebspilaa64.efi /boot/efi/EFI/systemd/drivers/
    cp $GAOKUN_DIR/tools/el2/tcblaunch.exe /boot/efi/
    cp /lib/firmware/qcom/sc8280xp/HUAWEI/gaokun3/qcadsp8280.mbn \
       /boot/efi/firmware/qcom/sc8280xp/HUAWEI/gaokun3/
    cp /lib/firmware/qcom/sc8280xp/HUAWEI/gaokun3/qccdsp8280.mbn \
       /boot/efi/firmware/qcom/sc8280xp/HUAWEI/gaokun3/
    cp /lib/firmware/qcom/sc8280xp/HUAWEI/gaokun3/qcslpi8280.mbn \
       /boot/efi/firmware/qcom/sc8280xp/HUAWEI/gaokun3/
fi

cat > /boot/efi/loader/loader.conf <<EOF
default ${MACHINE_ID}-${KREL}.conf
timeout 5
console-mode keep
editor no
EOF

exit
```

说明：

- 这里不再手工创建 `loader/entries/*.conf`，而是交给 `kernel-install` 的 `90-loaderentry.install` 自动生成标准 BLS 条目。
- 默认使用 `--entry-token=machine-id`，所以最终条目文件名会是 `/boot/efi/loader/entries/<machine-id>-<kernel-release>.conf`。
- 内核、`initrd` 和 DTB 会自动复制到 `/boot/efi/<machine-id>/<kernel-release>/` 下；这正是 BLS Type #1 的标准目录布局。

### 4. 收尾清理

```bash
sync
cleanup_mounts
sudo losetup -d $LOOP
```

---

## 第五步：双系统和 EL2 说明

- 双系统覆盖 EFI 的方式请参考 [dual_boot_guide_zh.md](dual_boot_guide_zh.md)
- 如果在本指南中同时构建了 `-gaokun3-el2` 内核变体，产出的镜像就已经具备 EL2 支持。
- 有关实现细节、启动链结构和排障说明，请参考 [el2_kvm_guide_zh.md](el2_kvm_guide_zh.md)
