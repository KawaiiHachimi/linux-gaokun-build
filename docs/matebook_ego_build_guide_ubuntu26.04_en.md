English | [中文](matebook_ego_build_guide_ubuntu26.04_zh.md)

# Huawei MateBook E Go 2023 Ubuntu 26.04 Manual Build Guide

> **Target Device**: Huawei MateBook E Go 2023 (codename `gaokun3`)  
> **Platform**: Qualcomm Snapdragon 8cx Gen3 (`SC8280XP`)  
> **Target System**: Ubuntu 26.04 (Resolute Raccoon) GNOME, systemd-boot boot, ext4 root filesystem  
> **Recommended Host**: Ubuntu/Debian or other distributions supporting `debootstrap`  
> **Repository Assumption**: This document assumes your current repository is at `~/gaokun/linux-gaokun-buildbot`

**For WSL2, it's recommended to switch to a kernel with more complete filesystem support such as `vfat`, `ext4`, for example: <https://github.com/Nevuly/WSL2-Linux-Kernel-Rolling/releases>**

---

## Preparation Notes

This document uses content already in the project, no need to obtain additional device-specific repositories:

- `patches/`
- `defconfig/`
- `dts/`
- `tools/`
- `firmware/`

If the host is arm64, you can build natively.  
If the host is x86_64, please prepare a usable aarch64 cross toolchain and set `CROSS_COMPILE` additionally when compiling the kernel.

---

## Step 1: Prepare Working Directory

Install basic dependencies (Ubuntu host example):

```bash
sudo apt-get update
sudo apt-get install -y \
    gcc make bison flex bc libssl-dev libelf-dev dwarves \
    git parted dosfstools e2fsprogs curl python3 rsync ccache \
    debootstrap qemu-user-static binfmt-support zstd xz-utils kmod
```

Prepare source and working directory:

```bash
mkdir -p ~/gaokun/matebook-build-ubuntu

cd ~/gaokun
# Get specified version of Linux mainline source
if [ ! -d "mainline-linux" ]; then
    git clone --depth 1 --branch v7.0-rc7 \
        https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git \
        mainline-linux
fi
```

Set environment variables:

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

## Step 2: Compile Kernel

First compile the standard kernel.

```bash
cd $KERN_SRC

# Apply project built-in patches
git config user.name "local builder"
git config user.email "builder@example.com"
git am $GAOKUN_DIR/patches/*.patch

mkdir -p $KERN_OUT
ccache -z

# Generate config from patched gaokun3_defconfig, then fill in new kernel default options
make O=$KERN_OUT ARCH=arm64 gaokun3_defconfig
make O=$KERN_OUT ARCH=arm64 olddefconfig
make O=$KERN_OUT ARCH=arm64 -j$(nproc)
make O=$KERN_OUT ARCH=arm64 modules_prepare

KREL=$(cat $KERN_OUT/include/config/kernel.release)
echo $KREL
KREL_EL2=""
ccache -s
```

If you need EL2, it's recommended to first install the standard kernel to rootfs, or separately backup the `Image`, `dtb`, `modules` outputs, then continue building the kernel with `-gaokun3-el2` suffix on the same source tree, with EL2 outputs in a separate output directory:

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

## Step 3: Build RootFS

Use Ubuntu's official `ubuntu-base` prebuilt rootfs as base, then install desktop environment and additional packages via chroot.

> If the host is x86_64, you need to copy `qemu-aarch64-static` to the rootfs to support chroot execution of arm64 binaries.  
> [avikivity/qemu-aarch64-static-fast](https://github.com/avikivity/qemu-aarch64-static-fast) is a parameter wrapper for QEMU user-mode emulator. It transparently improves AArch64 program execution efficiency in non-native environments by dynamically injecting high-performance CPU flags (such as `pauth-impdef=on`) at runtime.

```bash
mkdir -p $ROOTFS_DIR

# Download ubuntu-base prebuilt rootfs (comes with correct apt source configuration, no manual setup needed)
UBUNTU_BASE_URL="https://cdimages.ubuntu.com/ubuntu-base/releases/26.04/release/ubuntu-base-26.04-base-arm64.tar.gz"
UBUNTU_BASE_BETA_URL="https://cdimages.ubuntu.com/ubuntu-base/releases/26.04/beta/ubuntu-base-26.04-beta-base-arm64.tar.gz"
UBUNTU_BASE_TAR=$WORKDIR/ubuntu-base-arm64.tar.gz

if ! curl -fsSL -o "$UBUNTU_BASE_TAR" "$UBUNTU_BASE_URL"; then
    echo "Release tarball not found, trying beta..."
    curl -fsSL -o "$UBUNTU_BASE_TAR" "$UBUNTU_BASE_BETA_URL"
fi

sudo tar -xzf "$UBUNTU_BASE_TAR" -C $ROOTFS_DIR

# x86_64 host: copy qemu-aarch64-static to support chroot
if [ "$(uname -m)" != "aarch64" ]; then
    sudo cp "$(which qemu-aarch64-static)" $ROOTFS_DIR/usr/bin/
fi
```

Mount virtual filesystems and enter chroot to install packages:

```bash
sudo mount --bind /dev $ROOTFS_DIR/dev
sudo mount --bind /dev/pts $ROOTFS_DIR/dev/pts
sudo mount -t proc proc $ROOTFS_DIR/proc
sudo mount -t sysfs sys $ROOTFS_DIR/sys
sudo mount -t tmpfs tmpfs $ROOTFS_DIR/run

# Copy DNS configuration for network access inside chroot
if [ -L "$ROOTFS_DIR/etc/resolv.conf" ] || [ -e "$ROOTFS_DIR/etc/resolv.conf" ]; then
    sudo mv $ROOTFS_DIR/etc/resolv.conf $ROOTFS_DIR/etc/resolv.conf.bak
fi
sudo cp /etc/resolv.conf $ROOTFS_DIR/etc/resolv.conf

sudo chroot $ROOTFS_DIR /bin/bash
```

Execute inside chroot:

```bash
export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get install -y locales
sed -i 's/# zh_CN.UTF-8/zh_CN.UTF-8/' /etc/locale.gen
locale-gen
update-locale LANG=zh_CN.UTF-8 LANGUAGE=zh_CN:en_US:en LC_MESSAGES=zh_CN.UTF-8
rm -f /etc/resolv.conf
ln -s /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf

# First install kernel-related dependencies and initramfs-tools
apt-get install -y \
    linux-base initramfs-tools kmod

apt-get install -y --no-install-recommends \
    systemd-boot systemd-boot-efi

# Install basic network and compression tools (may be missing in ubuntu-base)
apt-get install -y \
    iputils-ping iproute2 net-tools dnsutils traceroute \
    xz-utils unzip zip bzip2 zstd p7zip-full \
    wget curl ca-certificates gnupg lsb-release \
    less file sudo

# Configure Mozilla official APT repository, install native deb version Firefox
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

# Install desktop environment and common software
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

# Install multimedia codecs
apt-get install -y \
    gstreamer1.0-libav gstreamer1.0-plugins-ugly \
    ubuntu-restricted-extras

apt-get clean
exit
```

Back on the host, install kernel, modules, firmware and local tools to rootfs:

```bash
cd $KERN_SRC

KREL=$(cat $KERN_OUT/include/config/kernel.release)
echo $KREL

sudo make O=$KERN_OUT ARCH=arm64 INSTALL_MOD_PATH=$ROOTFS_DIR modules_install
sudo rm -f $ROOTFS_DIR/lib/modules/$KREL/{build,source}

# Install kernel image in Ubuntu style
sudo mkdir -p $ROOTFS_DIR/boot
sudo cp $KERN_OUT/arch/arm64/boot/Image \
    $ROOTFS_DIR/boot/vmlinuz-$KREL

# Ubuntu's kernel-install will look for DTB from here
sudo mkdir -p $ROOTFS_DIR/usr/lib/linux-image-$KREL/qcom
sudo cp $KERN_OUT/arch/arm64/boot/dts/qcom/sc8280xp-huawei-gaokun3.dtb \
     $ROOTFS_DIR/usr/lib/linux-image-$KREL/qcom/sc8280xp-huawei-gaokun3.dtb

# Keep an extra copy of DTB under /boot for convenience when switching to GRUB or other bootloaders
sudo mkdir -p $ROOTFS_DIR/boot
sudo cp $KERN_OUT/arch/arm64/boot/dts/qcom/sc8280xp-huawei-gaokun3.dtb \
     $ROOTFS_DIR/boot/dtb-$KREL

# If EL2 is needed, install the second set of EL2 kernel and DTB
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

# Directly copy the project's built-in minimum firmware set
sudo mkdir -p $ROOTFS_DIR/lib/firmware
sudo cp -r $FW_REPO/. $ROOTFS_DIR/lib/firmware/

# Install project's device-specific scripts and services
sudo mkdir -p $ROOTFS_DIR/usr/local/bin
sudo mkdir -p $ROOTFS_DIR/usr/local/lib/gaokun-touchscreen-tuner
sudo mkdir -p $ROOTFS_DIR/etc/systemd/system
sudo mkdir -p $ROOTFS_DIR/usr/share/alsa/ucm2/Qualcomm/sc8280xp
sudo mkdir -p $ROOTFS_DIR/usr/share/applications

# Touchscreen tuner script and desktop entry
sudo cp $GAOKUN_DIR/tools/touchscreen-tuner/touchscreen-tune \
    $ROOTFS_DIR/usr/local/bin/touchscreen-tune
sudo cp $GAOKUN_DIR/tools/touchscreen-tuner/tune.py \
    $ROOTFS_DIR/usr/local/lib/gaokun-touchscreen-tuner/tune.py
sudo cp $GAOKUN_DIR/tools/touchscreen-tuner/touchscreen-tune.desktop \
    $ROOTFS_DIR/usr/share/applications/touchscreen-tune.desktop
sudo chmod +x $ROOTFS_DIR/usr/local/bin/touchscreen-tune

# Touchpad activation script and service
sudo cp $GAOKUN_DIR/tools/touchpad/huawei-tp-activate.py \
    $ROOTFS_DIR/usr/local/bin/
sudo cp $GAOKUN_DIR/tools/touchpad/huawei-touchpad.service \
    $ROOTFS_DIR/etc/systemd/system/
sudo chmod +x $ROOTFS_DIR/usr/local/bin/huawei-tp-activate.py

# GDM monitor sync script and service
sudo cp $GAOKUN_DIR/tools/monitors/gdm-monitor-sync \
    $ROOTFS_DIR/usr/local/bin/
sudo cp $GAOKUN_DIR/tools/monitors/gdm-monitor-sync.service \
    $ROOTFS_DIR/etc/systemd/system/
sudo chmod +x $ROOTFS_DIR/usr/local/bin/gdm-monitor-sync

# Bluetooth address patch script and service
sudo cp $GAOKUN_DIR/tools/bluetooth/patch-nvm-bdaddr.py \
    $ROOTFS_DIR/usr/local/bin/
sudo chmod +x $ROOTFS_DIR/usr/local/bin/patch-nvm-bdaddr.py

# Audio UCM configuration
sudo cp $GAOKUN_DIR/tools/audio/sc8280xp.conf \
    $ROOTFS_DIR/usr/share/alsa/ucm2/Qualcomm/sc8280xp/

# Shared image assets used by the CI image pipeline
sudo mkdir -p $ROOTFS_DIR/usr/local/share/gaokun
sudo cp -a $GAOKUN_DIR/tools/image-assets/etc/. \
    $ROOTFS_DIR/etc/
sudo cp $GAOKUN_DIR/tools/image-assets/usr/local/share/gaokun/monitors.xml \
    $ROOTFS_DIR/usr/local/share/gaokun/monitors.xml

# Let Ubuntu's initramfs-tools include DSP firmware in early boot stage,
# otherwise remoteproc may fail to find firmware before root filesystem is mounted in standard boot entry
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

Unmount previous virtual filesystems:

```bash
sudo umount $ROOTFS_DIR/dev/pts
sudo umount $ROOTFS_DIR/dev
sudo umount $ROOTFS_DIR/proc
sudo umount $ROOTFS_DIR/sys
sudo umount $ROOTFS_DIR/run
```

---

## Step 4: Create Bootable Image

### 1. Create Image and Partitions

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

### 2. Sync RootFS to Image

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

### 3. chroot Initialization and Generate systemd-boot / BLS

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

Execute inside chroot:

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

Notes:

- Instead of manually creating `loader/entries/*.conf`, we let `kernel-install`'s `90-loaderentry.install` auto-generate standard BLS entries.
- Default uses `--entry-token=machine-id`, so final entry filenames will be `/boot/efi/loader/entries/<machine-id>-<kernel-release>.conf`.
- Kernel, `initrd` and DTB will be automatically copied to `/boot/efi/<machine-id>/<kernel-release>/`; this is the standard BLS Type #1 directory layout.

### 4. Final Cleanup

```bash
sync
cleanup_mounts
sudo losetup -d $LOOP
```

---

## Step 5: Dual Boot and EL2 Instructions

- For dual boot EFI overlay method, refer to [dual_boot_guide_en.md](dual_boot_guide_en.md)
- EL2 support is already included when you also build the `-gaokun3-el2` kernel variant in this guide.
- Refer to [el2_kvm_guide_en.md](el2_kvm_guide_en.md) for implementation details, boot-chain structure, and debugging notes.
