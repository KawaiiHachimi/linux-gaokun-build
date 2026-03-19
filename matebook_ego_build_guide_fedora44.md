# Huawei MateBook E Go 2023 Fedora 44 手动构建指南

> **目标机型**：Huawei MateBook E Go 2023 (`SC8280XP` / `gaokun3`)  
> **基础镜像**：`Fedora-Workstation-Disk-44_Beta-1.2.aarch64.raw.xz` 解压后的 raw  
> **目标结果**：在 Fedora 44 Workstation raw 基础上注入 gaokun3 内核、固件和启动配置  
> **推荐宿主机**：Fedora 或其他 Linux 发行版  
> **仓库假设**：本文默认当前仓库位于 `~/gaokun/linux-gaokun-build`

**WSL2 建议切换到支持 `vfat`、`ext4`、`btrfs` 等文件系统更完整的内核，例如：<https://github.com/Nevuly/WSL2-Linux-Kernel-Rolling/releases>**

---

## 准备说明

本文使用项目内已有内容，不需要额外获取设备专属仓库：

- `gaokun-patches/`
- `tools/`
- `firmware/`

基础系统不再通过 `dnf --installroot` 现场生成，而是直接使用已经下载并解压好的 Fedora Workstation raw 镜像，并在它的副本上完成适配。

如果宿主机是 arm64，可直接原生构建。  
如果宿主机是 x86_64，请自行准备可用的 aarch64 交叉工具链，并在编译内核时额外设置 `CROSS_COMPILE`。

---

## 第一步：准备工作目录

安装基础依赖（Fedora 宿主机示例）：

```bash
sudo dnf install gcc make bison flex bc openssl-devel elfutils-libelf-devel \
    ncurses-devel dwarves git rsync btrfs-progs e2fsprogs dosfstools \
    curl python3
```

准备源码与工作目录：

```bash
mkdir -p ~/gaokun/matebook-build-fedora

cd ~/gaokun
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
export BASE_IMAGE_URL=https://download.fedoraproject.org/pub/fedora/linux/releases/test/44_Beta/Workstation/aarch64/images/Fedora-Workstation-Disk-44_Beta-1.2.aarch64.raw.xz
export BASE_IMAGE_FILE=$GAOKUN_DIR/Fedora-Workstation-Disk-44_Beta-1.2.aarch64.raw
export IMAGE_FILE=$WORKDIR/fedora-44-gaokun3.img
```

---

## 第二步：编译内核

应用项目内核补丁并构建：

```bash
cd $KERN_SRC

git am $GAOKUN_DIR/gaokun-patches/*.patch

mkdir -p $KERN_OUT

make O=$KERN_OUT ARCH=arm64 defconfig
make O=$KERN_OUT ARCH=arm64 olddefconfig
make O=$KERN_OUT ARCH=arm64 -j$(nproc)

KREL=$(cat $KERN_OUT/include/config/kernel.release)
echo $KREL
```

---

## 第三步：复制基础镜像

先下载并解压官方 Workstation raw 镜像，再复制出一份工作副本，避免直接修改原始镜像：

```bash
if [ ! -f "$BASE_IMAGE_FILE" ]; then
    curl -L "$BASE_IMAGE_URL" -o "${BASE_IMAGE_FILE}.xz"
    xz -d -T0 -f "${BASE_IMAGE_FILE}.xz"
fi

mkdir -p $WORKDIR
cp --reflink=auto $BASE_IMAGE_FILE $IMAGE_FILE
```

---

## 第四步：只读确认镜像布局

Fedora 44 Workstation aarch64 raw 的实际布局可以先只读确认：

```bash
LOOP=$(sudo losetup --show -fPr $BASE_IMAGE_FILE)
sudo blkid ${LOOP}p1 ${LOOP}p2 ${LOOP}p3
sudo losetup -d $LOOP
```

当前项目里已验证到的布局是：

- `p1`: `vfat`，挂载到 `/boot/efi`
- `p2`: `ext4`，挂载到 `/boot`
- `p3`: `btrfs`，使用 `root`、`home`、`var` 子卷

因此适配流程不再重建分区，而是保留 Fedora 官方镜像布局，直接在现有分区内替换内核与固件。

---

## 第五步：挂载镜像

```bash
LOOP=$(sudo losetup --show -fP $IMAGE_FILE)
sudo mkdir -p /mnt/ego-fedora

sudo mount -o subvol=root ${LOOP}p3 /mnt/ego-fedora
sudo mkdir -p /mnt/ego-fedora/home /mnt/ego-fedora/var
sudo mount -o subvol=home ${LOOP}p3 /mnt/ego-fedora/home
sudo mount -o subvol=var ${LOOP}p3 /mnt/ego-fedora/var

sudo mkdir -p /mnt/ego-fedora/boot /mnt/ego-fedora/boot/efi
sudo mount ${LOOP}p2 /mnt/ego-fedora/boot
sudo mount ${LOOP}p1 /mnt/ego-fedora/boot/efi

sudo mount --bind /dev /mnt/ego-fedora/dev
sudo mount --bind /dev/pts /mnt/ego-fedora/dev/pts
sudo mount -t proc proc /mnt/ego-fedora/proc
sudo mount -t sysfs sys /mnt/ego-fedora/sys
sudo mount -t tmpfs tmpfs /mnt/ego-fedora/run
```

---

## 第六步：安装内核和本地工具

```bash
cd $KERN_SRC
KREL=$(cat $KERN_OUT/include/config/kernel.release)

sudo make O=$KERN_OUT ARCH=arm64 INSTALL_MOD_PATH=/mnt/ego-fedora modules_install
sudo rm -f /mnt/ego-fedora/lib/modules/$KREL/{build,source}

sudo cp $KERN_OUT/arch/arm64/boot/Image /mnt/ego-fedora/boot/vmlinuz-$KREL
sudo mkdir -p /mnt/ego-fedora/boot/dtb-$KREL/qcom
sudo cp $KERN_OUT/arch/arm64/boot/dts/qcom/sc8280xp-huawei-gaokun3.dtb \
    /mnt/ego-fedora/boot/dtb-$KREL/qcom/

sudo mkdir -p /mnt/ego-fedora/usr/local/bin
sudo mkdir -p /mnt/ego-fedora/etc/systemd/system
sudo mkdir -p /mnt/ego-fedora/usr/share/alsa/ucm2/Qualcomm/sc8280xp

sudo cp $GAOKUN_DIR/tools/touchpad/huawei-tp-activate.py \
    /mnt/ego-fedora/usr/local/bin/
sudo cp $GAOKUN_DIR/tools/touchpad/huawei-touchpad.service \
    /mnt/ego-fedora/etc/systemd/system/
sudo chmod +x /mnt/ego-fedora/usr/local/bin/huawei-tp-activate.py

sudo cp $GAOKUN_DIR/tools/bluetooth/patch-nvm-bdaddr.py \
    /mnt/ego-fedora/usr/local/bin/
sudo chmod +x /mnt/ego-fedora/usr/local/bin/patch-nvm-bdaddr.py

sudo cp $GAOKUN_DIR/tools/audio/sc8280xp.conf \
    /mnt/ego-fedora/usr/share/alsa/ucm2/Qualcomm/sc8280xp/
```

---

## 第七步：chroot 初始化并替换固件

进入 chroot 后，先配置用户、服务和驱动，再卸载 Fedora 自带内核相关包与 `linux-firmware`，清理旧内核文件和模块目录，最后退出 chroot。

```bash
sudo chroot /mnt/ego-fedora /bin/bash
```

在 chroot 中执行：

```bash
echo "fedora" > /etc/hostname
id -u user >/dev/null 2>&1 || useradd -m -s /bin/bash -G wheel user
echo "user:user" | chpasswd
mkdir -p /etc/sudoers.d
echo "%wheel ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/wheel-nopasswd
chmod 440 /etc/sudoers.d/wheel-nopasswd

mkdir -p /home/user/.config
cat > /home/user/.config/monitors.xml <<'EOF'
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
                    <rate>59.694</rate>
                </mode>
            </monitor>
        </logicalmonitor>
    </configuration>
</monitors>
EOF
chown user:user /home/user/.config/monitors.xml

mkdir -p /var/lib/gdm/seat0/config
cp /home/user/.config/monitors.xml /var/lib/gdm/seat0/config/monitors.xml
chown --reference=/var/lib/gdm/seat0/config /var/lib/gdm/seat0/config/monitors.xml

systemctl enable gdm NetworkManager sshd huawei-touchpad.service || true

mkdir -p /etc/modules-load.d
echo -e "pci-pwrctrl-pwrseq\nath11k_pci" > /etc/modules-load.d/wifi.conf
echo "btqca" > /etc/modules-load.d/bluetooth.conf
echo -e "panel-himax-hx83121a\nmsm\nhid_multitouch" > /etc/modules-load.d/display.conf
echo -e "lpasscc_sc8280xp\nsnd-soc-sc8280xp" > /etc/modules-load.d/audio.conf
echo -e "huawei-gaokun-ec\nhuawei-gaokun-battery\nucsi_huawei_gaokun" > /etc/modules-load.d/battery.conf

mkdir -p /etc/modprobe.d
echo "softdep pinctrl_sc8280xp_lpass_lpi pre: lpasscc_sc8280xp" > /etc/modprobe.d/audio-deps.conf

mapfile -t STOCK_KERNEL_PKGS < <(rpm -qa | grep -E '^kernel(-(core|modules|modules-core|modules-extra|uki-virt|uki-virt-addons))?-[0-9]' || true)
if (( ${#STOCK_KERNEL_PKGS[@]} > 0 )); then
    dnf remove -y "${STOCK_KERNEL_PKGS[@]}" || rpm -e --nodeps "${STOCK_KERNEL_PKGS[@]}" || true
fi

if rpm -q linux-firmware >/dev/null 2>&1; then
    dnf remove -y linux-firmware || rpm -e --nodeps linux-firmware || true
fi

find /boot -maxdepth 1 -type f \
    \( -name 'vmlinuz-*' -o -name 'initramfs-*.img' -o -name 'System.map-*' -o -name 'config-*' -o -name '.vmlinuz-*.hmac' \) \
    ! -name "vmlinuz-$KREL" \
    -delete
find /boot -maxdepth 1 -type d -name 'dtb-*' ! -name "dtb-$KREL" -exec rm -rf {} +
find /lib/modules -mindepth 1 -maxdepth 1 -type d ! -name "$KREL" -exec rm -rf {} +
rm -f /boot/loader/entries/*.conf

rm -rf /lib/firmware/*
mkdir -p /lib/firmware

cat > /etc/dracut.conf.d/matebook.conf <<EOF
hostonly="no"
add_drivers+=" btrfs nvme phy-qcom-qmp-pcie phy-qcom-qmp-combo phy-qcom-qmp-usb phy-qcom-snps-femto-v2 usb-storage uas typec pci-pwrctrl-pwrseq ath11k ath11k_pci panel-himax-hx83121a msm i2c-hid-of lpasscc_sc8280xp snd-soc-sc8280xp pinctrl_sc8280xp_lpass_lpi "
EOF

exit
```

退出后再复制本仓库固件：

```bash
sudo cp -r $FW_REPO/. /mnt/ego-fedora/lib/firmware/
```

---

## 第八步：生成 initramfs 和 BLS 启动项

重新进入 chroot：

```bash
sudo chroot /mnt/ego-fedora /bin/bash
```

在 chroot 中执行：

```bash
dracut --force /boot/initramfs-$KREL.img $KREL

CURRENT_OPTIONS="rhgb quiet root=UUID=$(findmnt -no UUID /) rootflags=subvol=root"
MACHINE_ID=$(cat /etc/machine-id)
mkdir -p /boot/loader/entries

cat > /boot/loader/entries/${MACHINE_ID}-${KREL}.conf <<EOF
title Fedora Linux (${KREL}) 44 (Workstation Edition) - gaokun3
version ${KREL}
linux /vmlinuz-${KREL}
initrd /initramfs-${KREL}.img
options ${CURRENT_OPTIONS} clk_ignore_unused pd_ignore_unused arm64.nopauth iommu.passthrough=0 iommu.strict=0 pcie_aspm.policy=powersupersave modprobe.blacklist=simpledrm efi=noruntime fbcon=rotate:1 usbhid.quirks=0x12d1:0x10b8:0x20000000 consoleblank=0 loglevel=4 psi=1
devicetree /dtb-${KREL}/qcom/sc8280xp-huawei-gaokun3.dtb
grub_users \$grub_users
grub_arg --unrestricted
grub_class fedora
EOF

grub2-mkconfig -o /boot/grub2/grub.cfg
grub2-set-default 0 || true
exit
```

---

## 第九步：清理挂载

```bash
cleanup_mounts() {
    sudo umount /mnt/ego-fedora/dev/pts 2>/dev/null || true
    sudo umount /mnt/ego-fedora/boot/efi 2>/dev/null || true
    sudo umount /mnt/ego-fedora/boot 2>/dev/null || true
    sudo umount /mnt/ego-fedora/home 2>/dev/null || true
    sudo umount /mnt/ego-fedora/var 2>/dev/null || true
    sudo umount /mnt/ego-fedora/dev 2>/dev/null || true
    sudo umount /mnt/ego-fedora/proc 2>/dev/null || true
    sudo umount /mnt/ego-fedora/sys 2>/dev/null || true
    sudo umount /mnt/ego-fedora/run 2>/dev/null || true
    sudo umount /mnt/ego-fedora 2>/dev/null || true
}

cleanup_mounts
sudo losetup -d $LOOP
```

---

## 第十步：打包镜像

```bash
mkdir -p $WORKDIR/artifacts
cp $IMAGE_FILE $WORKDIR/artifacts/
zstd -T0 -19 $WORKDIR/artifacts/$(basename $IMAGE_FILE) \
    -o $WORKDIR/artifacts/$(basename $IMAGE_FILE).zst
```

---

## 补充说明

- 本流程不会修改原始 `BASE_IMAGE_FILE`，所有改动都在 `IMAGE_FILE` 副本上完成。
- 镜像内的 Fedora 自带内核包、旧模块目录、旧 BLS 项和 `linux-firmware` 都会先被清理，只保留当前自定义 `KREL` 这一套。
- 当前仓库里的 GitHub Actions workflow 也已经改成同一思路，但它要求 runner 工作目录里能直接拿到本地 raw 镜像文件。
- 文中所有 `tools/` 与 `firmware/` 都来自当前仓库。
