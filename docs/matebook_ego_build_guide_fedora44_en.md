English | [中文](matebook_ego_build_guide_fedora44_zh.md)

# Huawei MateBook E Go 2023 Fedora 44 Manual Build Guide

> **Target Device**: Huawei MateBook E Go 2023 (codename `gaokun3`)  
> **Platform**: Qualcomm Snapdragon 8cx Gen3 (`SC8280XP`)  
> **Target System**: Fedora 44 GNOME, systemd-boot boot, Btrfs root filesystem  
> **Recommended Host**: Fedora or other RPM/DNF-based distributions  
> **Repository Assumption**: This document assumes your current repository is at `~/gaokun/linux-gaokun-buildbot`

**For WSL2, it's recommended to switch to a kernel with more complete filesystem support such as `vfat`, `btrfs`, for example: <https://github.com/Nevuly/WSL2-Linux-Kernel-Rolling/releases>**

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

Install basic dependencies (Fedora arm64 host example):

```bash
sudo dnf install gcc make bison flex bc openssl-devel elfutils-libelf-devel \
    ncurses-devel dwarves git parted dosfstools btrfs-progs curl python3 rsync ccache
```

Prepare source and working directory:

```bash
mkdir -p ~/gaokun/matebook-build-fedora

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
export WORKDIR=~/gaokun/matebook-build-fedora
export KERN_SRC=~/gaokun/mainline-linux
export KERN_OUT=~/gaokun/kernel-out
export KERN_OUT_EL2=~/gaokun/kernel-out-el2
export FW_REPO=$GAOKUN_DIR/firmware
export ROOTFS_DIR=$WORKDIR/rootfs
export IMAGE_FILE=$WORKDIR/fedora-44-gaokun3.img
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

Use `dnf --installroot` to install Fedora 44 GNOME Desktop, with additional boot, network, input method and common tools.

> If the host is Ubuntu or other non-Fedora system, you can first install `dnf`, then continue using `--installroot` method to build.

```bash
mkdir -p $ROOTFS_DIR

sudo dnf -y install glibc-langpack-en glibc-langpack-zh
export LANG=zh_CN.UTF-8
export LC_ALL=zh_CN.UTF-8
export LANGUAGE=zh_CN:zh

# First step: install base system, locale and langpacks
sudo dnf --installroot=$ROOTFS_DIR --releasever=44 --forcearch=aarch64 --use-host-config -y \
    --exclude=gnome-boxes,gnome-connections,snapshot,gnome-weather,gnome-contacts,gnome-maps,simple-scan,gnome-clocks,gnome-calculator,gnome-calendar \
    install \
    @core @standard \
    systemd-boot-unsigned alsa-ucm \
    glibc-langpack-en glibc-langpack-zh \
    langpacks-en langpacks-zh_CN \
    google-noto-color-emoji-fonts google-noto-emoji-fonts \
    i2c-tools alsa-utils pipewire-utils

sudo mkdir -p $ROOTFS_DIR/etc
sudo tee $ROOTFS_DIR/etc/locale.conf > /dev/null <<EOF
LANG=zh_CN.UTF-8
LC_MESSAGES=zh_CN.UTF-8
EOF

# Second step: install desktop environment and applications, can more reliably pull Chinese translation subpackages into rootfs
sudo dnf --installroot=$ROOTFS_DIR --releasever=44 --forcearch=aarch64 --use-host-config -y \
    --exclude=gnome-boxes,gnome-connections,snapshot,gnome-weather,gnome-contacts,gnome-maps,simple-scan,gnome-clocks,gnome-calculator,gnome-calendar \
    install \
    @gnome-desktop \
    fcitx5-chinese-addons gnome-tweaks gnome-extensions-app telnet mpv v4l-utils vim nano ripgrep git htop fastfetch screen firefox

# Install RPMFusion and add libavcodec-freeworld (hardware video decoding support)
sudo dnf --installroot=$ROOTFS_DIR --releasever=44 --forcearch=aarch64 --use-host-config -y \
    install \
    https://download1.rpmfusion.org/free/fedora/rpmfusion-free-release-44.noarch.rpm

sudo mkdir -p /etc/pki/rpm-gpg
sudo cp -a $ROOTFS_DIR/etc/pki/rpm-gpg/. /etc/pki/rpm-gpg/

sudo dnf --installroot=$ROOTFS_DIR --releasever=44 --forcearch=aarch64 --use-host-config -y \
    --setopt=reposdir="$ROOTFS_DIR/etc/yum.repos.d,/etc/yum.repos.d" \
    install \
    libavcodec-freeworld
```

Install kernel, modules, firmware and local tools:

```bash
cd $KERN_SRC

KREL=$(cat $KERN_OUT/include/config/kernel.release)
echo $KREL

sudo make O=$KERN_OUT ARCH=arm64 INSTALL_MOD_PATH=$ROOTFS_DIR modules_install
sudo rm -f $ROOTFS_DIR/lib/modules/$KREL/{build,source}

# Install kernel image
sudo mkdir -p $ROOTFS_DIR/boot
sudo cp $KERN_OUT/arch/arm64/boot/Image \
    $ROOTFS_DIR/boot/vmlinuz-$KREL

# Fedora's kernel-install will look for DTB from here
sudo mkdir -p $ROOTFS_DIR/usr/lib/modules/$KREL/dtb/qcom
sudo cp $KERN_OUT/arch/arm64/boot/dts/qcom/sc8280xp-huawei-gaokun3.dtb \
    $ROOTFS_DIR/usr/lib/modules/$KREL/dtb/qcom/

# Keep an extra copy of DTB under /boot for convenience when switching to GRUB or other bootloaders
sudo mkdir -p $ROOTFS_DIR/boot/dtb-$KREL/qcom
sudo cp $KERN_OUT/arch/arm64/boot/dts/qcom/sc8280xp-huawei-gaokun3.dtb \
    $ROOTFS_DIR/boot/dtb-$KREL/qcom/

# If EL2 is needed, install the second set of EL2 kernel and DTB
if [ -n "$KREL_EL2" ]; then
    sudo make -C $KERN_SRC O=$KERN_OUT_EL2 ARCH=arm64 INSTALL_MOD_PATH=$ROOTFS_DIR modules_install
    sudo rm -f $ROOTFS_DIR/lib/modules/$KREL_EL2/{build,source}
    sudo cp $KERN_OUT_EL2/arch/arm64/boot/Image \
        $ROOTFS_DIR/boot/vmlinuz-$KREL_EL2
    sudo mkdir -p $ROOTFS_DIR/usr/lib/modules/$KREL_EL2/dtb/qcom
    sudo cp $KERN_OUT_EL2/arch/arm64/boot/dts/qcom/sc8280xp-huawei-gaokun3-el2.dtb \
        $ROOTFS_DIR/usr/lib/modules/$KREL_EL2/dtb/qcom/
    sudo mkdir -p $ROOTFS_DIR/boot/dtb-$KREL_EL2/qcom
    sudo cp $KERN_OUT_EL2/arch/arm64/boot/dts/qcom/sc8280xp-huawei-gaokun3-el2.dtb \
        $ROOTFS_DIR/boot/dtb-$KREL_EL2/qcom/
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
parted -s $IMAGE_FILE mkpart rootfs btrfs 1025MiB 100%

LOOP=$(sudo losetup --show -fP $IMAGE_FILE)
sudo mkfs.vfat -F32 -n EFI ${LOOP}p1
sudo mkfs.btrfs -f -L rootfs ${LOOP}p2

EFI_UUID=$(sudo blkid -s UUID -o value ${LOOP}p1)
ROOT_UUID=$(sudo blkid -s UUID -o value ${LOOP}p2)
```

### 2. Create Btrfs Subvolumes and Sync RootFS

```bash
sudo mkdir -p /mnt/ego-fedora

# Create common Fedora subvolume layout: @ for root partition, @home for home directory, @var for /var
sudo mount ${LOOP}p2 /mnt/ego-fedora
sudo btrfs subvolume create /mnt/ego-fedora/@
sudo btrfs subvolume create /mnt/ego-fedora/@home
sudo btrfs subvolume create /mnt/ego-fedora/@var
sudo umount /mnt/ego-fedora

# Mount subvolumes and prepare EFI partition
sudo mount -o subvol=@ ${LOOP}p2 /mnt/ego-fedora
sudo mkdir -p /mnt/ego-fedora/home
sudo mount -o subvol=@home ${LOOP}p2 /mnt/ego-fedora/home
sudo mkdir -p /mnt/ego-fedora/var
sudo mount -o subvol=@var ${LOOP}p2 /mnt/ego-fedora/var
sudo mkdir -p /mnt/ego-fedora/boot/efi
sudo mount ${LOOP}p1 /mnt/ego-fedora/boot/efi

sudo rsync -aHAX --info=progress2 --exclude='/proc/*' --exclude='/sys/*' --exclude='/dev/*' --exclude='/run/*' $ROOTFS_DIR/ /mnt/ego-fedora/

sudo tee /mnt/ego-fedora/etc/fstab > /dev/null <<EOF
UUID=${ROOT_UUID}  /         btrfs  subvol=@,compress=zstd:1,ssd,noatime  0  0
UUID=${ROOT_UUID}  /home     btrfs  subvol=@home,compress=zstd:1,ssd,noatime  0  0
UUID=${ROOT_UUID}  /var      btrfs  subvol=@var,compress=zstd:1,ssd,noatime  0  0
UUID=${EFI_UUID}   /boot/efi vfat   defaults,nofail,x-systemd.device-timeout=10s  0  2
EOF
```

### 3. chroot Initialization and Generate systemd-boot / BLS

```bash
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

sudo mount --bind /dev /mnt/ego-fedora/dev
sudo mount --bind /dev/pts /mnt/ego-fedora/dev/pts
sudo mount -t proc proc /mnt/ego-fedora/proc
sudo mount -t sysfs sys /mnt/ego-fedora/sys
sudo mount -t tmpfs tmpfs /mnt/ego-fedora/run

sudo chroot /mnt/ego-fedora /bin/bash
```

Execute inside chroot:

```bash
cat > /etc/dracut.conf.d/matebook.conf <<EOF
hostonly="no"
add_drivers+=" btrfs nvme phy-qcom-qmp-pcie phy-qcom-qmp-combo phy-qcom-qmp-usb phy-qcom-snps-femto-v2 usb-storage uas typec pci-pwrctrl-pwrseq ath11k ath11k_pci i2c-hid-of lpasscc_sc8280xp snd-soc-sc8280xp pinctrl_sc8280xp_lpass_lpi "
install_items+=" /lib/firmware/qcom/sc8280xp/HUAWEI/gaokun3/qcslpi8280.mbn /lib/firmware/qcom/sc8280xp/HUAWEI/gaokun3/qcadsp8280.mbn /lib/firmware/qcom/sc8280xp/HUAWEI/gaokun3/qccdsp8280.mbn /lib/firmware/qcom/sc8280xp/SC8280XP-HUAWEI-GAOKUN3-tplg.bin /lib/firmware/qcom/sc8280xp/HUAWEI/gaokun3/audioreach-tplg.bin "
EOF

install -d /etc/kernel
cat > /etc/kernel/install.conf <<EOF
layout=bls
EOF

install -d /etc/kernel/install.d
ln -sf /dev/null /etc/kernel/install.d/51-dracut-rescue.install

cat > /etc/kernel/cmdline <<EOF
root=UUID=${ROOT_UUID} rootflags=subvol=@ clk_ignore_unused pd_ignore_unused arm64.nopauth iommu.passthrough=0 iommu.strict=0 pcie_aspm.policy=powersupersave efi=noruntime fbcon=rotate:1 usbhid.quirks=0x12d1:0x10b8:0x20000000 consoleblank=0 loglevel=4 psi=1
EOF

cat > /etc/kernel/devicetree <<EOF
qcom/sc8280xp-huawei-gaokun3.dtb
EOF

dracut --force --kver $KREL
if [ -n "$KREL_EL2" ]; then
    dracut --force --kver $KREL_EL2
fi

rm -f /etc/machine-id
systemd-machine-id-setup
MACHINE_ID=$(cat /etc/machine-id)

bootctl --no-variables --esp-path=/boot/efi install

kernel-install --make-entry-directory=yes --entry-token=machine-id add \
    $KREL /boot/vmlinuz-$KREL

if [ -n "$KREL_EL2" ]; then
    mkdir -p /boot/efi/EFI/systemd/drivers
    mkdir -p /boot/efi/firmware/qcom/sc8280xp/HUAWEI/gaokun3

    EL2_CONF_ROOT=$(mktemp -d)
    cat > $EL2_CONF_ROOT/install.conf <<EOF
layout=bls
EOF
    cat > $EL2_CONF_ROOT/cmdline <<EOF
root=UUID=${ROOT_UUID} rootflags=subvol=@ clk_ignore_unused pd_ignore_unused arm64.nopauth iommu.passthrough=0 iommu.strict=0 pcie_aspm.policy=powersupersave modprobe.blacklist=simpledrm efi=noruntime fbcon=rotate:1 usbhid.quirks=0x12d1:0x10b8:0x20000000 consoleblank=0 loglevel=4 psi=1
EOF
    cat > $EL2_CONF_ROOT/devicetree <<EOF
qcom/sc8280xp-huawei-gaokun3-el2.dtb
EOF
    KERNEL_INSTALL_CONF_ROOT=$EL2_CONF_ROOT \
        kernel-install --make-entry-directory=yes --entry-token=machine-id add \
        $KREL_EL2 /boot/vmlinuz-$KREL_EL2
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

- Instead of manually maintaining `loader/entries/*.conf` and `gaokun3/fedora/...` directories, we let `kernel-install` generate the standard BLS Type #1 layout.
- Default uses `--entry-token=machine-id`, so entry names become `/boot/efi/loader/entries/<machine-id>-<kernel-release>.conf`.
- Fedora 44's `90-loaderentry.install` looks for device tree from `/usr/lib/modules/<kernel-release>/dtb/`, so DTB must be placed in this standard path.
- Fedora's default `51-dracut-rescue.install` generates an additional `0-rescue` boot entry, but this rescue entry doesn't include `devicetree` by default and is unusable on gaokun3, so it's explicitly disabled here.

### Touchscreen Driver Acknowledgments

- [chiyuki0325/EGoTouchRev-Linux](https://github.com/chiyuki0325/EGoTouchRev-Linux): The source and main upstream reference for the directly integrated `himax_hx83121a_spi` touchscreen driver and tuning algorithm in this repository.
- [awarson2233/EGoTouchRev](https://github.com/awarson2233/EGoTouchRev): The Windows-side touch algorithm project referenced by EGoTouchRev-Linux, also an important upstream source for touch algorithm tuning and behavior in this solution.

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
