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
        
        echo "Applying standard gaokun3 patches..."
        git apply --index "$GAOKUN_DIR"/patches/*.patch
        git commit -m "Apply standard gaokun3 patches"
    else
        echo "Exiting."
        exit 1
    fi
fi

if command -v ccache >/dev/null 2>&1; then
    echo "Resetting ccache statistics..."
    ccache -z
fi

ensure_ubuntu_initramfs_firmware_hook() {
    sudo mkdir -p /etc/initramfs-tools/hooks
    sudo tee /etc/initramfs-tools/hooks/gaokun3-firmware >/dev/null <<'EOF'
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
    sudo chmod 0755 /etc/initramfs-tools/hooks/gaokun3-firmware
}

build_kernel() {
    local mode=$1
    local out_dir
    local dtb_name
    local cmdline
    local conf_root
    local temp_kernel_conf_root=""
    local restore_kernel_conf=0

    cd "$KERN_SRC"
    
    # Check current Git tree state by looking at the last commit message
    local is_el2_patched=false
    if git log -1 --pretty=%B | grep -q "Apply EL2 patches"; then
        is_el2_patched=true
    fi

    if [ "$mode" == "el2" ]; then
        out_dir="$KERN_OUT_EL2"
        dtb_name="sc8280xp-huawei-gaokun3-el2.dtb"
        
        echo -e "\n=== Preparing Source Tree for EL2 Kernel ==="
        if [ "$is_el2_patched" = false ]; then
            echo "Applying EL2 patches to source tree..."
            git apply --index "$GAOKUN_DIR"/patches/el2/*.patch
            git commit -m "Apply EL2 patches"
        else
            echo "Source tree is already patched for EL2."
        fi

        mkdir -p "$out_dir"
        make O="$out_dir" ARCH=arm64 gaokun3_defconfig
        "$KERN_SRC"/scripts/config --file "$out_dir"/.config --set-str LOCALVERSION "-gaokun3-el2"
        
    else
        out_dir="$KERN_OUT"
        dtb_name="sc8280xp-huawei-gaokun3.dtb"
        
        echo -e "\n=== Preparing Source Tree for Standard Kernel ==="
        if [ "$is_el2_patched" = true ]; then
            echo "Reverting EL2 patches to restore standard source tree..."
            # Reset the tree back 1 commit (removing the EL2 patches)
            git reset --hard HEAD~1
        else
            echo "Source tree is already in standard state."
        fi

        mkdir -p "$out_dir"
        make O="$out_dir" ARCH=arm64 gaokun3_defconfig
    fi

    echo "Starting build..."
    make O="$out_dir" ARCH=arm64 olddefconfig
    make O="$out_dir" ARCH=arm64 -j$(nproc)
    make O="$out_dir" ARCH=arm64 modules_prepare

    local krel=$(cat "$out_dir"/include/config/kernel.release)
    echo "KREL ($mode): $krel"

    # Distribution-specific configuration
    local initrd_src
    local dtb_inst_dir
    local dtb_boot_dir

    if [ "$DISTRO" == "ubuntu" ]; then
        initrd_src="initrd.img-$krel"
        dtb_inst_dir="/usr/lib/linux-image-$krel/qcom"
        dtb_boot_dir="/boot"
    elif [ "$DISTRO" == "fedora" ]; then
        initrd_src="initramfs-$krel.img"
        dtb_inst_dir="/usr/lib/modules/$krel/dtb/qcom"
        dtb_boot_dir="/boot/dtb-$krel/qcom"
    fi

    sudo make O="$out_dir" ARCH=arm64 INSTALL_MOD_PATH=/ modules_install
    sudo rm -f /lib/modules/"$krel"/{build,source}

    sudo cp "$out_dir"/arch/arm64/boot/Image /boot/vmlinuz-"$krel"
    sudo mkdir -p "$dtb_inst_dir"
    sudo cp "$out_dir"/arch/arm64/boot/dts/qcom/"$dtb_name" "$dtb_inst_dir"/"$dtb_name"
    if [ "$DISTRO" == "ubuntu" ]; then
        sudo cp "$out_dir"/arch/arm64/boot/dts/qcom/"$dtb_name" "$dtb_boot_dir"/dtb-"$krel"
    else
        sudo mkdir -p "$dtb_boot_dir"
        sudo cp "$out_dir"/arch/arm64/boot/dts/qcom/"$dtb_name" "$dtb_boot_dir"/"$dtb_name"
    fi

    if ! sudo test -f "$dtb_inst_dir/$dtb_name"; then
        echo "ERROR: DTB was not installed where kernel-install expects it:" >&2
        echo "  expected: $dtb_inst_dir/$dtb_name" >&2
        echo "  source:   $out_dir/arch/arm64/boot/dts/qcom/$dtb_name" >&2
        sudo ls -ld "$dtb_inst_dir" 2>/dev/null || true
        sudo find "$(dirname "$dtb_inst_dir")" -maxdepth 3 -type f 2>/dev/null | sort || true
        exit 1
    fi

    if [ -f /etc/kernel/cmdline ]; then
        cmdline="$(tr -s '[:space:]' ' ' </etc/kernel/cmdline)"
    else
        cmdline="$(tr ' ' '\n' </proc/cmdline | grep -ve '^BOOT_IMAGE=' -e '^initrd=' | tr '\n' ' ')"
    fi
    cmdline="${cmdline%" "}"

    if [ "$mode" == "el2" ] && [[ "$cmdline" != *"modprobe.blacklist=simpledrm"* ]]; then
        cmdline="${cmdline} modprobe.blacklist=simpledrm"
        cmdline="${cmdline#" "}"
    fi

    conf_root="$(mktemp -d)"
    trap 'rm -rf "$conf_root"' RETURN

    printf 'layout=bls\n' >"$conf_root/install.conf"
    printf '%s\n' "$cmdline" >"$conf_root/cmdline"
    printf 'qcom/%s\n' "$dtb_name" >"$conf_root/devicetree"

    if [ "$DISTRO" == "ubuntu" ]; then
        temp_kernel_conf_root="$(mktemp -d)"
        restore_kernel_conf=1

        for name in install.conf cmdline devicetree; do
            if sudo test -f "/etc/kernel/$name"; then
                sudo cp "/etc/kernel/$name" "$temp_kernel_conf_root/$name.orig"
            fi
        done

        printf 'layout=bls\n' | sudo tee /etc/kernel/install.conf >/dev/null
        printf '%s\n' "$cmdline" | sudo tee /etc/kernel/cmdline >/dev/null
        printf 'qcom/%s\n' "$dtb_name" | sudo tee /etc/kernel/devicetree >/dev/null
    fi

    # Generate initramfs. On Ubuntu this runs post-update hooks that call
    # kernel-install, so /etc/kernel/devicetree must already match this mode.
    if [ "$DISTRO" == "ubuntu" ]; then
        ensure_ubuntu_initramfs_firmware_hook
        sudo update-initramfs -c -k "$krel"
    elif [ "$DISTRO" == "fedora" ]; then
        sudo dracut --force --kver "$krel"
    fi

    echo "kernel-install inputs:"
    echo "  kernel release: $krel"
    echo "  kernel image:   /boot/vmlinuz-$krel"
    echo "  initrd:         /boot/$initrd_src"
    echo "  devicetree:     qcom/$dtb_name"
    echo "  dtb source:     $dtb_inst_dir/$dtb_name"

    {
        sudo kernel-install --entry-token=machine-id remove "$krel" >/dev/null 2>&1 || true
        sudo env KERNEL_INSTALL_CONF_ROOT="$conf_root" \
            kernel-install --verbose --make-entry-directory=yes --entry-token=machine-id add \
            "$krel" "/boot/vmlinuz-$krel" "/boot/$initrd_src"
    } || {
        if [ "$restore_kernel_conf" -eq 1 ]; then
            for name in install.conf cmdline devicetree; do
                if [ -f "$temp_kernel_conf_root/$name.orig" ]; then
                    sudo cp "$temp_kernel_conf_root/$name.orig" "/etc/kernel/$name"
                else
                    sudo rm -f "/etc/kernel/$name"
                fi
            done
            rm -rf "$temp_kernel_conf_root"
        fi
        rm -rf "$conf_root"
        trap - RETURN
        return 1
    }

    if [ "$restore_kernel_conf" -eq 1 ]; then
        for name in install.conf cmdline devicetree; do
            if [ -f "$temp_kernel_conf_root/$name.orig" ]; then
                sudo cp "$temp_kernel_conf_root/$name.orig" "/etc/kernel/$name"
            else
                sudo rm -f "/etc/kernel/$name"
            fi
        done
        rm -rf "$temp_kernel_conf_root"
    fi

    rm -rf "$conf_root"
    trap - RETURN
}

# Run the build according to user choice
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
