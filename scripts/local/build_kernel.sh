#!/bin/bash
set -e

# Detect OS distribution
if [ -f /etc/os-release ]; then
    . /etc/os-release
    DISTRO=$ID
else
    echo "Cannot determine OS distribution. Exiting."
    exit 1
fi

if [[ "$DISTRO" != "ubuntu" && "$DISTRO" != "fedora" ]]; then
    echo "Unsupported distribution: $DISTRO. Only ubuntu and fedora are supported. Exiting."
    exit 1
fi

# Ask and install minimal build toolchain based on distribution
read -r -p "Install necessary minimal kernel build toolchain? [Y/n]: " install_deps
install_deps=${install_deps:-Y}
if [[ "$install_deps" =~ ^([yY][eE][sS]|[yY])$ ]]; then
    echo "Installing build dependencies for $DISTRO..."
    if [ "$DISTRO" == "ubuntu" ]; then
        sudo apt-get update
        sudo apt-get install -y gcc make bison flex bc libssl-dev libelf-dev dwarves git ccache curl
    elif [ "$DISTRO" == "fedora" ]; then
        sudo dnf install -y gcc make bison flex bc openssl-devel elfutils-libelf-devel ncurses-devel dwarves git ccache curl
    fi
fi

export GAOKUN_DIR=~/gaokun/linux-gaokun-buildbot
export KERN_SRC=~/gaokun/mainline-linux
export KERN_OUT=~/gaokun/kernel-out
export KERN_OUT_EL2=~/gaokun/kernel-out-el2

export CCACHE_DIR=~/gaokun/.ccache
export CCACHE_BASEDIR=~/gaokun
export CCACHE_NOHASHDIR=true
export CCACHE_COMPILERCHECK=content
if [ -d /usr/lib64/ccache ]; then
    export PATH=/usr/lib64/ccache:$PATH
elif [ -d /usr/lib/ccache ]; then
    export PATH=/usr/lib/ccache:$PATH
fi

read -r -p "Build EL2 kernel? (Y: only EL2, n: only standard, both: build both) [n]: " el2_choice
el2_choice=${el2_choice:-n}

if [ ! -f "$KERN_SRC/arch/arm64/configs/gaokun3_defconfig" ]; then
    read -r -p "gaokun3_defconfig not found in kernel directory. Pull kernel and apply patches? [y/N]: " response
    if [[ "$response" =~ ^([yY][eE][sS]|[yY])$ ]]; then
        if [ ! -d "$GAOKUN_DIR" ]; then
            echo "linux-gaokun-buildbot not found. Cloning..."
            mkdir -p ~/gaokun
            git clone https://github.com/KawaiiHachimi/linux-gaokun-buildbot "$GAOKUN_DIR"
        fi
        
        read -r -p "Use Chinese mirror (mirrors.bfsu.edu.cn) for Linux kernel? [Y/n]: " mirror_choice
        mirror_choice=${mirror_choice:-Y}
        if [[ "$mirror_choice" =~ ^([nN][oO]|[nN])$ ]]; then
            KERNEL_URL="https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git"
        else
            KERNEL_URL="https://mirrors.bfsu.edu.cn/git/linux.git"
        fi
        
        rm -rf "$KERN_SRC"
        git clone --depth=1 "$KERNEL_URL" "$KERN_SRC" -b v7.0-rc6
        cd "$KERN_SRC"
        
        # Detect and set git user info to avoid overwriting existing configuration
        if [ -z "$(git config user.name)" ]; then
            git config user.name "local builder"
        fi
        if [ -z "$(git config user.email)" ]; then
            git config user.email "builder@example.com"
        fi
        
        git am "$GAOKUN_DIR"/patches/*.patch
    else
        echo "Exiting."
        exit 1
    fi
fi

cd "$KERN_SRC"

if command -v ccache >/dev/null 2>&1; then
    echo "Resetting ccache statistics..."
    ccache -z
fi

build_kernel() {
    local mode=$1
    local out_dir
    local conf_name
    local dtb_name

    if [ "$mode" == "el2" ]; then
        out_dir="$KERN_OUT_EL2"
        conf_name="${DISTRO}-gaokun3-el2.conf"
        dtb_name="sc8280xp-huawei-gaokun3-el2.dtb"
        
        echo -e "\n=== Building EL2 Kernel ==="
        # Apply EL2 patches only if they haven't been applied yet
        if git apply --check "$GAOKUN_DIR"/patches/el2/*.patch 2>/dev/null; then
            echo "Applying EL2 patches..."
            git apply --index "$GAOKUN_DIR"/patches/el2/*.patch
            git commit -m "Apply EL2 patches"
        fi

        mkdir -p "$out_dir"
        make O="$out_dir" ARCH=arm64 gaokun3_defconfig
        "$KERN_SRC"/scripts/config --file "$out_dir"/.config --set-str LOCALVERSION "-gaokun3-el2"
    else
        out_dir="$KERN_OUT"
        conf_name="${DISTRO}-gaokun3.conf"
        dtb_name="sc8280xp-huawei-gaokun3.dtb"
        
        echo -e "\n=== Building Standard Kernel ==="
        mkdir -p "$out_dir"
        make O="$out_dir" ARCH=arm64 gaokun3_defconfig
    fi

    make O="$out_dir" ARCH=arm64 olddefconfig
    make O="$out_dir" ARCH=arm64 -j$(nproc)
    make O="$out_dir" ARCH=arm64 modules_prepare

    local krel=$(cat "$out_dir"/include/config/kernel.release)
    echo "KREL ($mode): $krel"

    # Distribution-specific configuration
    local initrd_src
    local initrd_dst
    local dtb_inst_dir

    if [ "$DISTRO" == "ubuntu" ]; then
        initrd_src="initrd.img-$krel"
        initrd_dst="initrd.img"
        dtb_inst_dir="/usr/lib/linux-image-$krel/qcom"
    elif [ "$DISTRO" == "fedora" ]; then
        initrd_src="initramfs-$krel.img"
        initrd_dst="initramfs.img"
        dtb_inst_dir="/boot/dtb-$krel/qcom"
    fi

    sudo make O="$out_dir" ARCH=arm64 INSTALL_MOD_PATH=/ modules_install
    sudo rm -f /lib/modules/"$krel"/{build,source}

    sudo cp "$out_dir"/arch/arm64/boot/Image /boot/vmlinuz-"$krel"
    sudo mkdir -p "$dtb_inst_dir"
    sudo cp "$out_dir"/arch/arm64/boot/dts/qcom/"$dtb_name" "$dtb_inst_dir"/"$dtb_name"

    # Generate initramfs
    if [ "$DISTRO" == "ubuntu" ]; then
        sudo update-initramfs -c -k "$krel"
    elif [ "$DISTRO" == "fedora" ]; then
        sudo dracut --force --kver "$krel"
    fi

    local efi_dest="/boot/efi/gaokun3/$DISTRO/$krel"
    sudo mkdir -p "$efi_dest"

    sudo cp /boot/vmlinuz-"$krel" "$efi_dest"/vmlinuz
    sudo cp /boot/"$initrd_src" "$efi_dest"/"$initrd_dst"
    sudo cp "$dtb_inst_dir"/"$dtb_name" "$efi_dest"/"$dtb_name"

    local conf_file="/boot/efi/loader/entries/$conf_name"
    if [ -f "$conf_file" ]; then
        sudo sed -i "s/^version .*/version ${krel}/g" "$conf_file"
        sudo sed -i "s|^linux .*|linux /gaokun3/$DISTRO/${krel}/vmlinuz|g" "$conf_file"
        sudo sed -i "s|^initrd .*|initrd /gaokun3/$DISTRO/${krel}/${initrd_dst}|g" "$conf_file"
        sudo sed -i "s|^devicetree .*|devicetree /gaokun3/$DISTRO/${krel}/${dtb_name}|g" "$conf_file"
        echo "Updated systemd-boot config: $conf_file"
    else
        echo "WARNING: $conf_file not found! You may need to create it manually."
    fi
}

if [[ "$el2_choice" == "both" ]]; then
    build_kernel "std"
    build_kernel "el2"
elif [[ "$el2_choice" =~ ^([yY][eE][sS]|[yY])$ ]]; then
    build_kernel "el2"
else
    build_kernel "std"
fi

if command -v ccache >/dev/null 2>&1; then
    echo -e "\n----------------------------------------"
    echo "Ccache statistics for this build:"
    ccache -s
    echo "----------------------------------------"
fi

echo -e "\nDone! Kernel update completed. You can now reboot."
