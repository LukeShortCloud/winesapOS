#!/bin/bash

WINESAPOS_DEBUG_INSTALL="${WINESAPOS_DEBUG_INSTALL:-true}"
if [[ "${WINESAPOS_DEBUG_INSTALL}" == "true" ]]; then
    set -x
else
    set +x
fi

# Log both the standard output and error from this script to a log file.
exec > >(tee /tmp/winesapos-install.log) 2>&1
echo "Start time: $(date)"

current_shell=$(cat /proc/$$/comm)
if [[ "${current_shell}" != "bash" ]]; then
    echo "winesapOS scripts require Bash but ${current_shell} detected. Exiting..."
    exit 1
fi

# Load default environment variables.
. ./env/winesapos-env-defaults.sh

if [[ "${WINESAPOS_BUILD_IN_VM_ONLY}" == "true" ]]; then
    lscpu | grep "Hypervisor vendor:"
    if [ $? -ne 0 ]
    then
        echo "This build is not running in a virtual machine. Exiting to be safe."
        exit 1
    fi
fi

# Increase the temporary storage up from 256 MB on the Arch Linux ISO live environment.
ls /run/archiso/cowspace &> /dev/null
if [ $? -eq 0 ]; then
    mount -o remount,size=3G /run/archiso/cowspace
fi

clear_cache() {
    chroot ${WINESAPOS_INSTALL_DIR} pacman --noconfirm -S -c -c
    # Each directory gets deleted separately in case the directory does not exist yet.
    # Otherwise, the entire 'rm' command will not run if one of the directories is not found.
    rm -rf ${WINESAPOS_INSTALL_DIR}/var/cache/pacman/pkg/*
    rm -rf ${WINESAPOS_INSTALL_DIR}/home/${WINESAPOS_USER_NAME}/.cache/go-build/*
    rm -rf ${WINESAPOS_INSTALL_DIR}/home/${WINESAPOS_USER_NAME}/.cache/paru/*
    rm -rf ${WINESAPOS_INSTALL_DIR}/home/${WINESAPOS_USER_NAME}/.cache/yay/*
    rm -rf ${WINESAPOS_INSTALL_DIR}/home/${WINESAPOS_USER_NAME}/.cargo/*
    rm -rf ${WINESAPOS_INSTALL_DIR}/tmp/*
}

pacman_install_chroot() {
    chroot ${WINESAPOS_INSTALL_DIR} /usr/bin/pacman --noconfirm -S --needed $@
    clear_cache
}

yay_install_chroot() {
    chroot ${WINESAPOS_INSTALL_DIR} sudo -u ${WINESAPOS_USER_NAME} yay --noconfirm -S --removemake $@
    clear_cache
}

if [ -n "${WINESAPOS_HTTP_PROXY_CA}" ]; then
    echo "Configuring the proxy certificate authority in the live environment..."
    cp "${WINESAPOS_HTTP_PROXY_CA}" /etc/ca-certificates/trust-source/anchors/
    update-ca-trust
    echo "Configuring the proxy certificate authority in the live environment complete."
fi

if [ -n "${WINESAPOS_HTTP_PROXY}" ]; then
    echo "Configuring the proxy in the live environment..."
    export http_proxy="${WINESAPOS_HTTP_PROXY}"
    export ftp_proxy="${http_proxy}"
    export rsync_proxy="${http_proxy}"
    export no_proxy="localhost,127.0.0.1,localaddress,.localdomain.com"
    export HTTP_PROXY="${http_proxy}"
    export FTP_PROXY="${http_proxy}"
    export RSYNC_PROXY="${http_proxy}"
    export NO_PROXY="${no_proxy}"
    if echo ${WINESAPOS_HTTP_PROXY} | grep -P "^https://"; then
        export https_proxy="${http_proxy}"
        export HTTPS_PROXY="${http_proxy}"
    fi
    echo "Configuring the proxy in the live environment complete."
fi

if [[ "${WINESAPOS_CREATE_DEVICE}" == "true" ]]; then

    mkdir ../output/

    if [[ -n "${WINESAPOS_CREATE_DEVICE_SIZE}" ]]; then
            fallocate -l "${WINESAPOS_CREATE_DEVICE_SIZE}GiB" ../output/winesapos.img
    else
        if [[ "${WINESAPOS_ENABLE_PORTABLE_STORAGE}" == "true" ]]; then
            fallocate -l 25GiB ../output/winesapos.img
        else
            fallocate -l 8GiB ../output/winesapos.img
        fi
    fi

    # The output should be "/dev/loop0" by default.
    DEVICE="$(losetup --partscan --find --show ../output/winesapos.img)"
    echo "${DEVICE}" | tee /tmp/winesapos-device.txt
fi

mkdir -p ${WINESAPOS_INSTALL_DIR}

if [[ "${WINESAPOS_BUILD_CHROOT_ONLY}" == "false" ]]; then
    DEVICE_WITH_PARTITION="${DEVICE}"
    echo ${DEVICE} | grep -q -P "^/dev/(nvme|loop)"
    if [ $? -eq 0 ]; then
        # "nvme" and "loop" devices separate the device name and partition number by using a "p".
        # Example output: /dev/loop0p
        DEVICE_WITH_PARTITION="${DEVICE}p"
    fi

    echo "Creating partitions..."
    # GPT is required for UEFI boot.
    parted ${DEVICE} mklabel gpt
    # An empty partition is required for BIOS boot backwards compatibility.
    parted ${DEVICE} mkpart primary 2048s 2MiB

    if [[ "${WINESAPOS_ENABLE_PORTABLE_STORAGE}" == "true" ]]; then
        # exFAT partition for generic flash drive storage.
        parted ${DEVICE} mkpart primary 2MiB 16GiB
        ## Configure this partition to be automatically mounted on Windows.
        parted ${DEVICE} set 2 msftdata on
        # EFI partition.
        parted ${DEVICE} mkpart primary fat32 16GiB 16.5GiB
        parted ${DEVICE} set 3 boot on
        parted ${DEVICE} set 3 esp on
        # Boot partition.
        parted ${DEVICE} mkpart primary ext4 16.5GiB 17.5GiB
        # Root partition uses the rest of the space.
        parted ${DEVICE} mkpart primary btrfs 17.5GiB 100%
    else
        # EFI partition.
        parted ${DEVICE} mkpart primary fat32 2MiB 512MiB
        parted ${DEVICE} set 2 boot on
        parted ${DEVICE} set 2 esp on
        # Boot partition.
        parted ${DEVICE} mkpart primary ext4 512MiB 1.5GiB
        # Root partition uses the rest of the space.
        parted ${DEVICE} mkpart primary btrfs 1.5GiB 100%
    fi

    # Avoid a race-condition where formatting devices may happen before the system detects the new partitions.
    sync
    partprobe

    if [[ "${WINESAPOS_ENABLE_PORTABLE_STORAGE}" == "true" ]]; then
        # Formatting via 'parted' does not work so we need to reformat those partitions again.
        mkfs -t exfat ${DEVICE_WITH_PARTITION}2
        # exFAT file systems require labels that are 11 characters or shorter.
        exfatlabel ${DEVICE_WITH_PARTITION}2 wos-drive
        mkfs -t vfat ${DEVICE_WITH_PARTITION}3
        # FAT32 file systems require upper-case labels that are 11 characters or shorter.
        fatlabel ${DEVICE_WITH_PARTITION}3 WOS-EFI
        mkfs -t ext4 ${DEVICE_WITH_PARTITION}4
        e2label ${DEVICE_WITH_PARTITION}4 winesapos-boot

        if [[ "${WINESAPOS_ENCRYPT}" == "true" ]]; then
            echo "${WINESAPOS_ENCRYPT_PASSWORD}" | cryptsetup -q luksFormat ${DEVICE_WITH_PARTITION}5
            cryptsetup config ${DEVICE_WITH_PARTITION}5 --label winesapos-luks
            echo "${WINESAPOS_ENCRYPT_PASSWORD}" | cryptsetup luksOpen ${DEVICE_WITH_PARTITION}5 cryptroot
            root_partition="/dev/mapper/cryptroot"
        else
            root_partition="${DEVICE_WITH_PARTITION}5"
        fi

    else
        # Formatting via 'parted' does not work so we need to reformat those partitions again.
        mkfs -t vfat ${DEVICE_WITH_PARTITION}2
        # FAT32 file systems require upper-case labels that are 11 characters or shorter.
        fatlabel ${DEVICE_WITH_PARTITION}2 WOS-EFI
        mkfs -t ext4 ${DEVICE_WITH_PARTITION}3
        e2label ${DEVICE_WITH_PARTITION}3 winesapos-boot

        if [[ "${WINESAPOS_ENCRYPT}" == "true" ]]; then
            echo "${WINESAPOS_ENCRYPT_PASSWORD}" | cryptsetup -q luksFormat ${DEVICE_WITH_PARTITION}4
            cryptsetup config ${DEVICE_WITH_PARTITION}4 --label winesapos-luks
            echo "${WINESAPOS_ENCRYPT_PASSWORD}" | cryptsetup luksOpen ${DEVICE_WITH_PARTITION}4 cryptroot
            root_partition="/dev/mapper/cryptroot"
        else
            root_partition="${DEVICE_WITH_PARTITION}4"
        fi
    fi

    mkfs -t btrfs ${root_partition}
    btrfs filesystem label ${root_partition} winesapos-root
    echo "Creating partitions complete."

    echo "Mounting partitions..."
    mount -t btrfs -o subvol=/,compress-force=zstd:1,discard,noatime,nodiratime ${root_partition} ${WINESAPOS_INSTALL_DIR}
    btrfs subvolume create ${WINESAPOS_INSTALL_DIR}/home
    mount -t btrfs -o subvol=/home,compress-force=zstd:1,discard,noatime,nodiratime ${root_partition} ${WINESAPOS_INSTALL_DIR}/home
    btrfs subvolume create ${WINESAPOS_INSTALL_DIR}/swap
    mount -t btrfs -o subvol=/swap,compress-force=zstd:1,discard,noatime,nodiratime ${root_partition} ${WINESAPOS_INSTALL_DIR}/swap
    mkdir ${WINESAPOS_INSTALL_DIR}/boot
    if [[ "${WINESAPOS_ENABLE_PORTABLE_STORAGE}" == "true" ]]; then
        mount -t ext4 ${DEVICE_WITH_PARTITION}4 ${WINESAPOS_INSTALL_DIR}/boot
    else
        mount -t ext4 ${DEVICE_WITH_PARTITION}3 ${WINESAPOS_INSTALL_DIR}/boot
    fi

    mkdir ${WINESAPOS_INSTALL_DIR}/boot/efi
    if [[ "${WINESAPOS_ENABLE_PORTABLE_STORAGE}" == "true" ]]; then
        mount -t vfat ${DEVICE_WITH_PARTITION}3 ${WINESAPOS_INSTALL_DIR}/boot/efi
    else
        mount -t vfat ${DEVICE_WITH_PARTITION}2 ${WINESAPOS_INSTALL_DIR}/boot/efi
    fi

    for i in tmp var/log var/tmp; do
        mkdir -p ${WINESAPOS_INSTALL_DIR}/${i}
        mount tmpfs -t tmpfs -o nodev,nosuid ${WINESAPOS_INSTALL_DIR}/${i}
    done

    echo "Mounting partitions complete."
fi

echo "Setting up fastest pacman mirror on live media..."

if [[ "${WINESAPOS_SINGLE_MIRROR}" == "true" ]]; then
    echo "Server = ${WINESAPOS_SINGLE_MIRROR_URL}/\$repo/os/\$arch" > /etc/pacman.d/mirrorlist
fi

pacman -S -y --noconfirm
echo "Setting up fastest pacman mirror on live media complete."

echo "Creating the keyrings used by Pacman..."
# The Arch Linux ISO has this mounted to tmpfs.
# Umount it first because the entire "gnupg" directory needs to be deleted for "pacman-key --init" to work.
killall gpg-agent
umount -l /etc/pacman.d/gnupg
rm -r -f /etc/pacman.d/gnupg
pacman-key --init
pacman --config <(echo -e "[options]\nArchitecture = auto\nSigLevel = Never\n[core]\nInclude = /etc/pacman.d/mirrorlist\n[extra]\nInclude = /etc/pacman.d/mirrorlist") --noconfirm -S archlinux-keyring
if [[ "${WINESAPOS_DISTRO_DETECTED}" == "manjaro" ]]; then
    pacman --config <(echo -e "[options]\nArchitecture = auto\nSigLevel = Never\n[core]\nInclude = /etc/pacman.d/mirrorlist") --noconfirm -S manjaro-keyring
fi
echo "Creating the keyrings used by Pacman done."

echo "Setting up Pacman parallel package downloads on live media..."
# Increase from the default 1 package download at a time to 5.
sed -i s'/\#ParallelDownloads.*/ParallelDownloads=5/'g /etc/pacman.conf
echo "Setting up Pacman parallel package downloads on live media complete."

echo "Install wget to help download packages..."
pacman -S --needed --noconfirm wget
echo "Install wget to help download packages complete."

echo "Configuring Pacman to use 'curl' for more reliable downloads on slow internet connections..."
#sed -i s'/\[options\]/\[options\]\nXferCommand = \/usr\/bin\/curl --connect-timeout 60 --retry 10 --retry-delay 5 -L -C - -f -o %o %u/'g /etc/pacman.conf
echo "Configuring Pacman to use 'curl' for more reliable downloads on slow internet connections complete."

echo "Updating all system packages on the live media before starting the build..."
pacman -S -y -y -u --noconfirm --config <(echo -e "[options]\nArchitecture = auto\nSigLevel = Never\n[core]\nInclude = /etc/pacman.d/mirrorlist\n[extra]\nInclude = /etc/pacman.d/mirrorlist")
echo "Updating all system packages on the live media before starting the build complete."

echo "Installing Arch Linux installation tools on the live media..."
# Required for the 'arch-chroot', 'genfstab', and 'pacstrap' tools.
# These are not provided by default in Manjaro.
/usr/bin/pacman --noconfirm -S --needed arch-install-scripts
echo "Installing Arch Linux installation tools on the live media complete."


echo "Installing ${WINESAPOS_DISTRO}..."

pacstrap -i ${WINESAPOS_INSTALL_DIR} base base-devel curl fwupd --noconfirm

# When building winesapOS using a container, ${WINESAPOS_INSTALL_DIR}/etc/pacman.conf does not get created.
# https://github.com/LukeShortCloud/winesapOS/issues/631
if [ ! -f "${WINESAPOS_INSTALL_DIR}/etc/pacman.conf" ]; then
    cp /etc/pacman.conf ${WINESAPOS_INSTALL_DIR}/etc/pacman.conf
else
    true
    #sed -i s'/\[options\]/\[options\]\nXferCommand = \/usr\/bin\/curl --connect-timeout 60 --retry 10 --retry-delay 5 -L -C - -f -o %o %u/'g ${WINESAPOS_INSTALL_DIR}/etc/pacman.conf
fi

echo "Adding the winesapOS repository..."
if [[ "${WINESAPOS_ENABLE_TESTING_REPO}" == "false" ]]; then
    sed -i s'/\[core]/[winesapos]\nServer = http:\/\/winesapos.lukeshort.cloud\/repo\/$repo\/$arch\n\n[core]/'g ${WINESAPOS_INSTALL_DIR}/etc/pacman.conf
else
    sed -i s'/\[core]/[winesapos-testing]\nServer = http:\/\/winesapos.lukeshort.cloud\/repo\/$repo\/$arch\nSigLevel = Never\n\n[core]/'g ${WINESAPOS_INSTALL_DIR}/etc/pacman.conf
fi

# DNS resolvers need to be configured first before accessing the GPG key server.
echo -e "nameserver 8.8.8.8\nnameserver 1.1.1.1" > ${WINESAPOS_INSTALL_DIR}/etc/resolv.conf

# Before we perform our first 'chroot', we need to mount the necessary Linux device, process, and system file systems.
mount --rbind /dev ${WINESAPOS_INSTALL_DIR}/dev
mount -t proc /proc ${WINESAPOS_INSTALL_DIR}/proc
mount --rbind /sys ${WINESAPOS_INSTALL_DIR}/sys

echo "Importing the public GPG key for the winesapOS repository..."
chroot ${WINESAPOS_INSTALL_DIR} pacman-key --recv-keys 1805E886BECCCEA99EDF55F081CA29E4A4B01239
chroot ${WINESAPOS_INSTALL_DIR} pacman-key --init
chroot ${WINESAPOS_INSTALL_DIR} pacman-key --lsign-key 1805E886BECCCEA99EDF55F081CA29E4A4B01239
echo "Importing the public GPG key for the winesapOS repository complete."
echo "Adding the winesapOS repository complete."

if [[ "${WINESAPOS_DISTRO}" == "arch" ]]; then
    echo "Adding the 32-bit multilb repository..."
    # 32-bit multilib libraries.
    echo -e '\n\n[multilib]\nInclude=/etc/pacman.d/mirrorlist' >> ${WINESAPOS_INSTALL_DIR}/etc/pacman.conf
    echo "Adding the 32-bit multilb repository..."
fi

# Use the fast mirrors that were already configured for the live environment.
rm -f ${WINESAPOS_INSTALL_DIR}/etc/pacman.d/mirrorlist
cp /etc/pacman.d/mirrorlist ${WINESAPOS_INSTALL_DIR}/etc/pacman.d/mirrorlist
# Update repository cache for [winesapos] and [multilib] repositories.
# Otherwise, 'pacman' commands will fail.
chroot ${WINESAPOS_INSTALL_DIR} pacman -S -y

# https://aur.chaotic.cx/
echo "Adding the Chaotic AUR repository..."
chroot ${WINESAPOS_INSTALL_DIR} pacman-key --recv-keys 3056513887B78AEB --keyserver keyserver.ubuntu.com
chroot ${WINESAPOS_INSTALL_DIR} pacman-key --lsign-key 3056513887B78AEB
wget 'https://cdn-mirror.chaotic.cx/chaotic-aur/chaotic-keyring.pkg.tar.zst' -LO ${WINESAPOS_INSTALL_DIR}/chaotic-keyring.pkg.tar.zst
chroot ${WINESAPOS_INSTALL_DIR} pacman --noconfirm -U /chaotic-keyring.pkg.tar.zst
wget 'https://cdn-mirror.chaotic.cx/chaotic-aur/chaotic-mirrorlist.pkg.tar.zst' -LO ${WINESAPOS_INSTALL_DIR}/chaotic-mirrorlist.pkg.tar.zst
chroot ${WINESAPOS_INSTALL_DIR} pacman --noconfirm -U /chaotic-mirrorlist.pkg.tar.zst
rm -f ${WINESAPOS_INSTALL_DIR}/chaotic-*.pkg.tar.zst

echo "
[chaotic-aur]
Include = /etc/pacman.d/chaotic-mirrorlist" >> ${WINESAPOS_INSTALL_DIR}/etc/pacman.conf

if [ -n "${WINESAPOS_HTTP_PROXY_CA}" ]; then
    echo "Configuring the proxy certificate authority in the chroot..."
    cp "${WINESAPOS_HTTP_PROXY_CA}" ${WINESAPOS_INSTALL_DIR}/etc/ca-certificates/trust-source/anchors/
    chroot ${WINESAPOS_INSTALL_DIR} update-ca-trust
    echo "Configuring the proxy certificate authority in the chroot complete."
fi

# Update repository cache. The extra '-y' is to accept any new keyrings.
chroot ${WINESAPOS_INSTALL_DIR} pacman -S -y -y

pacman_install_chroot efibootmgr core/grub iwd mkinitcpio modem-manager-gui networkmanager usb_modeswitch zram-generator
echo -e "[device]\nwifi.backend=iwd" > ${WINESAPOS_INSTALL_DIR}/etc/NetworkManager/conf.d/wifi_backend.conf
chroot ${WINESAPOS_INSTALL_DIR} systemctl enable NetworkManager systemd-timesyncd
# Prioritize IPv4 over IPv6 traffic.
# https://github.com/LukeShortCloud/winesapOS/issues/740
echo "label  ::1/128       0
label  ::/0          1
label  2002::/16     2
label ::/96          3
label ::ffff:0:0/96  4
precedence  ::1/128       50
precedence  ::/0          40
precedence  2002::/16     30
precedence ::/96          20
precedence ::ffff:0:0/96  100" > ${WINESAPOS_INSTALL_DIR}/etc/gai.conf
sed -i s'/MODULES=(/MODULES=(btrfs\ usbhid\ xhci_hcd\ nvme\ vmd\ /'g ${WINESAPOS_INSTALL_DIR}/etc/mkinitcpio.conf
echo "${WINESAPOS_LOCALE}" >> ${WINESAPOS_INSTALL_DIR}/etc/locale.gen
chroot ${WINESAPOS_INSTALL_DIR} locale-gen
# Example output: LANG=en_US.UTF-8
echo "LANG=$(echo ${WINESAPOS_LOCALE} | cut -d' ' -f1)" > ${WINESAPOS_INSTALL_DIR}/etc/locale.conf
# Hostname.
echo winesapos > ${WINESAPOS_INSTALL_DIR}/etc/hostname
## This is not a typo. The IPv4 address should '127.0.1.1' instead of '127.0.0.1' to work with systemd.
echo "127.0.1.1    winesapos" >> ${WINESAPOS_INSTALL_DIR}/etc/hosts
## This package provides the 'hostname' command along with other useful network utilities.
pacman_install_chroot inetutils
# Install fingerprint scanning support.
pacman_install_chroot fprintd
echo "Installing ${WINESAPOS_DISTRO} complete."
# GNOME Boxes and Virtual Machine Manager support.
pacman_install_chroot spice-vdagent
echo "Setting up Pacman parallel package downloads in chroot..."
# Increase from the default 1 package download at a time to 5.
sed -i s'/\#ParallelDownloads.*/ParallelDownloads=5/'g ${WINESAPOS_INSTALL_DIR}/etc/pacman.conf
echo "Setting up Pacman parallel package downloads in chroot complete."

if [[ "${WINESAPOS_BUILD_CHROOT_ONLY}" == "false" ]]; then
    echo "Saving partition mounts to /etc/fstab..."
    sync
    partprobe
    # Force a rescan of labels on the system.
    # https://github.com/LukeShortCloud/winesapOS/issues/251
    udevadm trigger
    # Wait for udev rules to load.
    udevadm settle
    # 'genfstab' now uses 'lsblk' which does not work in a container.
    # Instead, manually create the '/etc/fstab' file.
    # https://github.com/LukeShortCloud/winesapOS/issues/826
    #genfstab -L ${WINESAPOS_INSTALL_DIR} | grep -v tracefs > ${WINESAPOS_INSTALL_DIR}/etc/fstab
    echo "LABEL=winesapos-root        	/         	btrfs     	rw,noatime,nodiratime,compress-force=zstd:1,discard,space_cache=v2,subvolid=$(btrfs subvolume show /winesapos | grep "Subvolume ID"  | awk '{print $3}'),subvol=/	0 0
LABEL=winesapos-root        	/home     	btrfs     	rw,noatime,nodiratime,compress-force=zstd:1,discard,space_cache=v2,subvolid=$(btrfs subvolume show /winesapos/home | grep "Subvolume ID"  | awk '{print $3}'),subvol=/home	0 0
LABEL=winesapos-root        	/swap     	btrfs     	rw,noatime,nodiratime,compress-force=zstd:1,discard,space_cache=v2,subvolid=$(btrfs subvolume show /winesapos/swap | grep "Subvolume ID"  | awk '{print $3}'),subvol=/swap	0 0
LABEL=winesapos-boot        	/boot     	ext4      	rw,relatime	0 2
LABEL=WOS-EFI        	/boot/efi 	vfat      	rw,relatime,fmask=0022,dmask=0022,codepage=437,iocharset=iso8859-1,shortname=mixed,errors=remount-ro	0 2" > ${WINESAPOS_INSTALL_DIR}/etc/fstab
    # Add temporary mounts separately instead of using 'genfstab -P' to avoid extra file systems.
    echo "tmpfs    /tmp    tmpfs    rw,nosuid,nodev,inode64    0 0
tmpfs    /var/log    tmpfs    rw,nosuid,nodev,inode64    0 0
tmpfs    /var/tmp    tmpfs    rw,nosuid,nodev,inode64    0 0" >> ${WINESAPOS_INSTALL_DIR}/etc/fstab
    echo "View final /etc/fstab file:"
    cat ${WINESAPOS_INSTALL_DIR}/etc/fstab
    echo "Saving partition mounts to /etc/fstab complete."
fi

echo "Configuring fastest mirror in the chroot..."

if [[ "${WINESAPOS_DISTRO_DETECTED}" == "manjaro" ]]; then
    cp ../files/pacman-mirrors.service ${WINESAPOS_INSTALL_DIR}/etc/systemd/system/
    # This is required for 'pacman-mirrors' to determine if an IP address has been assigned yet.
    # Once an IP address is assigned, then the `pacman-mirrors' service will start.
    chroot ${WINESAPOS_INSTALL_DIR} systemctl enable NetworkManager-wait-online.service
elif [[ "${WINESAPOS_DISTRO_DETECTED}" == "arch" ]]; then
    pacman_install_chroot reflector
fi

# Re-use the mirror list that was created earlier.
rm -f ${WINESAPOS_INSTALL_DIR}/etc/pacman.d/mirrorlist
cp /etc/pacman.d/mirrorlist ${WINESAPOS_INSTALL_DIR}/etc/pacman.d/mirrorlist

echo "Configuring fastest mirror in the chroot complete."

echo "Installing additional package managers..."

# AUR package managers.
if [[ "${WINESAPOS_DISTRO_DETECTED}" == "manjaro" ]]; then
    pacman_install_chroot curl tar yay
else
    pacman_install_chroot curl tar
    export YAY_VER="12.3.5"
    curl https://github.com/Jguer/yay/releases/download/v${YAY_VER}/yay_${YAY_VER}_x86_64.tar.gz --remote-name --location
    tar -x -v -f yay_${YAY_VER}_x86_64.tar.gz
    mv yay_${YAY_VER}_x86_64/yay ${WINESAPOS_INSTALL_DIR}/usr/local/bin/yay
    rm -rf ./yay*
fi
# Development packages required for building other packages.
pacman_install_chroot binutils cmake dkms fakeroot gcc git make
echo 'MAKEFLAGS="-j $(nproc)"' >> ${WINESAPOS_INSTALL_DIR}/etc/makepkg.conf

# Add the 'pacman-static' command for more stable upgrades.
# https://github.com/LukeShortCloud/winesapOS/issues/623
wget https://pkgbuild.com/~morganamilo/pacman-static/x86_64/bin/pacman-static -LO ${WINESAPOS_INSTALL_DIR}/usr/local/bin/pacman-static
chmod +x ${WINESAPOS_INSTALL_DIR}/usr/local/bin/pacman-static

pacman_install_chroot \
  mesa \
  libva-mesa-driver \
  mesa-vdpau \
  opencl-rusticl-mesa \
  vulkan-intel \
  vulkan-mesa-layers \
  vulkan-nouveau \
  vulkan-radeon \
  vulkan-swrast \
  lib32-mesa \
  lib32-libva-mesa-driver \
  lib32-mesa-vdpau \
  lib32-vulkan-nouveau \
  lib32-opencl-rusticl-mesa \
  lib32-vulkan-intel \
  lib32-vulkan-mesa-layers \
  lib32-vulkan-radeon \
  lib32-vulkan-swrast

echo "
options radeon si_support=0
options radeon cik_support=0
options amdgpu si_support=1
options amdgpu cik_support=1" > ${WINESAPOS_INSTALL_DIR}/etc/modprobe.d/winesapos-amd.conf

# Workaround a known AMD driver issue:
# https://www.phoronix.com/news/AMDGPU-APU-noretry
# https://gitlab.freedesktop.org/drm/amd/-/issues/934
echo "
options amdgpu noretry=0" >> ${WINESAPOS_INSTALL_DIR}/etc/modprobe.d/winesapos-amd.conf

# Flatpak.
pacman_install_chroot flatpak
echo "Installing additional package managers complete."

if [[ "${WINESAPOS_FIREWALL}" == "true" ]]; then
    pacman_install_chroot firewalld
    chroot ${WINESAPOS_INSTALL_DIR} systemctl enable firewalld
fi

echo "Configuring user accounts..."
echo -e "root\nroot" | chroot ${WINESAPOS_INSTALL_DIR} passwd root
chroot ${WINESAPOS_INSTALL_DIR} useradd --create-home ${WINESAPOS_USER_NAME}
echo -e "${WINESAPOS_USER_NAME}\n${WINESAPOS_USER_NAME}" | chroot ${WINESAPOS_INSTALL_DIR} passwd ${WINESAPOS_USER_NAME}
echo "${WINESAPOS_USER_NAME} ALL=(root) NOPASSWD:ALL" > ${WINESAPOS_INSTALL_DIR}/etc/sudoers.d/${WINESAPOS_USER_NAME}
chmod 0440 ${WINESAPOS_INSTALL_DIR}/etc/sudoers.d/${WINESAPOS_USER_NAME}
mkdir ${WINESAPOS_INSTALL_DIR}/home/${WINESAPOS_USER_NAME}/Desktop
# Create a symlink for the "deck" user for compatibility with Steam Deck apps.
chroot ${WINESAPOS_INSTALL_DIR} ln -s /home/${WINESAPOS_USER_NAME} /home/deck
echo "Configuring user accounts complete."

echo "Installing AUR package managers..."
if [[ "${WINESAPOS_DISTRO_DETECTED}" == "arch" ]]; then
    yay_install_chroot yay
    rm -f ${WINESAPOS_INSTALL_DIR}/usr/local/bin/yay
fi

yay_install_chroot paru
echo "Installing AUR package managers complete."

# Add the 'pacman-static' package for more stable upgrades.
yay_install_chroot pacman-static

if [[ "${WINESAPOS_APPARMOR}" == "true" ]]; then
    echo "Installing AppArmor..."
    pacman_install_chroot apparmor
    yay_install_chroot krathalans-apparmor-profiles-git
    chroot ${WINESAPOS_INSTALL_DIR} systemctl enable apparmor
    chroot ${WINESAPOS_INSTALL_DIR} find /etc/apparmor.d/ -exec aa-enforce {} \;
    echo "Installing AppArmor complete."
fi

echo "Installing 'crudini' from the AUR..."
# These packages have to be installed in this exact order.
# Dependency for 'python-iniparse'. Refer to: https://aur.archlinux.org/packages/python-iniparse/.
pacman_install_chroot python-tests
# Dependency for 'crudini'.
yay_install_chroot python-iniparse-git
yay_install_chroot crudini
echo "Installing 'crudini' from the AUR complete."

echo "Installing Wi-Fi drivers..."
# Download an offline copy of the "broadcom-wl-dkms" driver.
# It can optionally be installed during the first-time setup.
mkdir -p ${WINESAPOS_INSTALL_DIR}/var/lib/winesapos/
chroot ${WINESAPOS_INSTALL_DIR} pacman -S -w --noconfirm broadcom-wl-dkms
# Find the exact package name.
for i in $(ls -1 ${WINESAPOS_INSTALL_DIR}/var/cache/pacman/pkg/ | grep broadcom-wl-dkms)
    do cp ${WINESAPOS_INSTALL_DIR}/var/cache/pacman/pkg/${i} ${WINESAPOS_INSTALL_DIR}/var/lib/winesapos/
done
echo "Installing Wi-Fi drivers complete."

echo "Installing sound drivers..."
# Install the PipeWire sound driver.
## PipeWire.
pacman_install_chroot libpipewire lib32-libpipewire wireplumber
## PipeWire backwards compatibility.
pacman_install_chroot pipewire-alsa pipewire-jack lib32-pipewire-jack pipewire-pulse pipewire-v4l2 lib32-pipewire-v4l2
## Enable the required services.
## Manually create the 'systemctl --user enable' symlinks as the command does not work in a chroot.
mkdir -p ${WINESAPOS_INSTALL_DIR}/home/${WINESAPOS_USER_NAME}/.config/systemd/user/default.target.wants/
chroot ${WINESAPOS_INSTALL_DIR} ln -s /usr/lib/systemd/user/pipewire.service /home/${WINESAPOS_USER_NAME}/.config/systemd/user/default.target.wants/pipewire.service
chroot ${WINESAPOS_INSTALL_DIR} ln -s /usr/lib/systemd/user/pipewire-pulse.service /home/${WINESAPOS_USER_NAME}/.config/systemd/user/default.target.wants/pipewire-pulse.service
# Custom systemd service to mute the audio on start.
# https://github.com/LukeShortCloud/winesapOS/issues/172
cp ../files/winesapos-mute.service ${WINESAPOS_INSTALL_DIR}/etc/systemd/user/
cp ./winesapos-mute.sh ${WINESAPOS_INSTALL_DIR}/usr/local/bin/
chroot ${WINESAPOS_INSTALL_DIR} ln -s /etc/systemd/user/winesapos-mute.service /home/${WINESAPOS_USER_NAME}/.config/systemd/user/default.target.wants/winesapos-mute.service
# PulseAudio Control is a GUI used for managing PulseAudio (or, in our case, PipeWire-Pulse).
pacman_install_chroot pavucontrol
echo "Installing sound drivers complete."

if [[ "${WINESAPOS_INSTALL_PRODUCTIVITY_TOOLS}" == "true" ]]; then
    echo "Installing additional packages..."
    pacman_install_chroot bind ffmpeg gparted jre8-openjdk libdvdcss lm_sensors man-db mlocate nano ncdu nmap openssh python python-pip python-setuptools rsync smartmontools spectacle sudo terminator tmate tmux wget veracrypt vi vim zstd
    # ClamAV anti-virus.
    pacman_install_chroot clamav clamtk
    ## Download an offline database for ClamAV.
    chroot ${WINESAPOS_INSTALL_DIR} freshclam

    # Distrobox.
    pacman_install_chroot distrobox podman

    # Etcher by balena.
    export ETCHER_VER="1.18.11"
    wget "https://github.com/balena-io/etcher/releases/download/v${ETCHER_VER}/balenaEtcher-${ETCHER_VER}-x64.AppImage" -O ${WINESAPOS_INSTALL_DIR}/home/${WINESAPOS_USER_NAME}/Desktop/balenaEtcher.AppImage
    chmod +x ${WINESAPOS_INSTALL_DIR}/home/${WINESAPOS_USER_NAME}/Desktop/balenaEtcher.AppImage
    echo "Installing additional packages complete."

    echo "Installing additional packages from the AUR..."
    yay_install_chroot coolercontrol qdirstat
    echo "Installing additional packages from the AUR complete."

else
    pacman_install_chroot bind lm_sensors man-db nano openssh rsync sudo terminator tmate tmux wget vi vim zstd
fi

echo "Installing Firefox ESR..."
yay_install_chroot firefox-esr
echo "Installing Firefox ESR complete."

echo "Installing Oh My Zsh..."
pacman_install_chroot zsh
yay_install_chroot oh-my-zsh-git
cp ${WINESAPOS_INSTALL_DIR}/usr/share/oh-my-zsh/zshrc ${WINESAPOS_INSTALL_DIR}/home/${WINESAPOS_USER_NAME}/.zshrc
chown 1000:1000 ${WINESAPOS_INSTALL_DIR}/home/${WINESAPOS_USER_NAME}/.zshrc
echo "Installing Oh My Zsh complete."

if [[ "${WINESAPOS_BUILD_CHROOT_ONLY}" == "false" ]]; then
    echo "Installing the Linux kernels..."

    # Enable the two t2linux repositories and install some of the required Mac drivers.
    echo "
[arch-mact2]
Server = https://mirror.funami.tech/arch-mact2/os/x86_64
SigLevel = Never

[Redecorating-t2]
Server = https://github.com/Redecorating/archlinux-t2-packages/releases/download/packages
SigLevel = Never" >> ${WINESAPOS_INSTALL_DIR}/etc/pacman.conf
    chroot ${WINESAPOS_INSTALL_DIR} pacman -S -y
    # linux-fsync-nobara-bin provides many patches including patches from linux-t2.
    # https://pagure.io/kernel-fsync/blob/main/f/SOURCES/t2linux.patch
    yay_install_chroot linux-fsync-nobara-bin
    pacman_install_chroot apple-t2-audio-config apple-bcm-firmware

    if [[ "${WINESAPOS_DISTRO_DETECTED}" == "manjaro" ]]; then
        pacman_install_chroot linux66 linux66-headers
    else
        pacman_install_chroot core/linux-lts core/linux-lts-headers
    fi

    if [[ "${WINESAPOS_DISABLE_KERNEL_UPDATES}" == "true" ]]; then
        echo "Setting up Pacman to disable Linux kernel updates..."

        if [[ "${WINESAPOS_DISTRO}" == "manjaro" ]]; then
            chroot ${WINESAPOS_INSTALL_DIR} crudini --set /etc/pacman.conf options IgnorePkg "linux66 linux66-headers linux-fsync-nobara-bin filesystem"
        elif [[ "${WINESAPOS_DISTRO}" == "arch" ]]; then
            chroot ${WINESAPOS_INSTALL_DIR} crudini --set /etc/pacman.conf options IgnorePkg "linux-lts linux-lts-headers linux-fsync-nobara-bin filesystem"
        fi

        echo "Setting up Pacman to disable Linux kernel updates complete."
    fi

    # Install all available Linux firmware packages from the official Arch Linux repositories.
    pacman_install_chroot \
      linux-firmware \
      linux-firmware-bnx2x \
      linux-firmware-liquidio \
      linux-firmware-marvell \
      linux-firmware-mellanox \
      linux-firmware-nfp \
      linux-firmware-qcom \
      linux-firmware-qlogic \
      linux-firmware-whence \
      alsa-firmware \
      sof-firmware

    # Install all available Linux firmware packages from the AUR.
    yay_install_chroot \
      mkinitcpio-firmware \
      aw87559-firmware \
      linux-firmware-asus \
      linux-firmware-valve

    # Install all CPU microcode updates.
    pacman_install_chroot \
      amd-ucode \
      intel-ucode
    echo "Installing the Linux kernels complete."
fi

echo "Installing additional file system support..."
echo "APFS"
yay_install_chroot apfsprogs-git linux-apfs-rw-dkms-git
echo "Bcachefs"
pacman_install_chroot bcachefs-tools
echo "Btrfs"
pacman_install_chroot btrfs-progs
echo "CephFS"
yay_install_chroot ceph-libs-bin ceph-bin
echo "CIFS/SMB"
pacman_install_chroot cifs-utils
echo "eCryptFS"
pacman_install_chroot ecryptfs-utils
echo "EROFS"
pacman_install_chroot erofs-utils
echo "ext3 and ext4"
pacman_install_chroot e2fsprogs lib32-e2fsprogs
echo "exFAT"
pacman_install_chroot exfatprogs
echo "F2FS"
pacman_install_chroot f2fs-tools
echo "FAT12, FAT16, and FAT32"
pacman_install_chroot dosfstools mtools
echo "FATX16 and FATX32"
# Temporarily install an old version of FATX.
# https://github.com/LukeShortCloud/winesapOS/issues/834
#yay_install_chroot fatx
chroot ${WINESAPOS_INSTALL_DIR} pacman -U --noconfirm  --config <(echo -e "[options]\nArchitecture = auto\nSigLevel = Never\n") https://winesapos.lukeshort.cloud/repo/winesapos-4.0.0/x86_64/fatx-1.15-4-any.pkg.tar.zst
echo "GFS2"
yay_install_chroot gfs2-utils
echo "GlusterFS"
pacman_install_chroot glusterfs
echo "HFS and HFS+"
yay_install_chroot hfsprogs
echo "JFS"
pacman_install_chroot jfsutils
echo "MinIO"
pacman_install_chroot minio
echo "NFS"
pacman_install_chroot nfs-utils
echo "NILFS2"
pacman_install_chroot nilfs-utils
echo "NTFS"
pacman_install_chroot ntfs-3g
echo "ReiserFS"
pacman_install_chroot reiserfsprogs
yay_install_chroot reiserfs-defrag
echo "SquashFS"
pacman_install_chroot squashfs-tools
echo "SSDFS"
yay_install_chroot ssdfs-tools
echo "SSHFS"
pacman_install_chroot sshfs
echo "UDF"
pacman_install_chroot udftools
echo "XFS"
pacman_install_chroot xfsprogs
echo "ZFS"
yay_install_chroot zfs-dkms zfs-utils
echo -e "apfs\nbtrfs\next4\nexfat\nfat\nhfs\nhfsplus\nntfs3\nzfs" > ${WINESAPOS_INSTALL_DIR}/etc/modules-load.d/winesapos-file-systems.conf
echo "Installing additional file system support complete."

echo "Optimizing battery life..."
yay_install_chroot auto-cpufreq
chroot ${WINESAPOS_INSTALL_DIR} systemctl enable auto-cpufreq
echo "Optimizing battery life complete."

echo "Minimizing writes to the disk..."
chroot ${WINESAPOS_INSTALL_DIR} crudini --set /etc/systemd/journald.conf Journal Storage volatile
echo "Minimizing writes to the disk compelete."

echo "Increasing open file limits..."
# This is no longer needed as of filesystem-2024.04.07-1.
# https://archlinux.org/news/increasing-the-default-vmmax_map_count-value/
#echo "vm.max_map_count=16777216
#fs.file-max=524288" >> ${WINESAPOS_INSTALL_DIR}/etc/sysctl.d/00-winesapos.conf

mkdir -p ${WINESAPOS_INSTALL_DIR}/etc/systemd/system.conf.d/
echo "[Manager]
DefaultLimitNOFILE=524288" > ${WINESAPOS_INSTALL_DIR}/etc/systemd/system.conf.d/20-file-limits.conf
echo "Increasing open file limits complete."

echo "Setting up the desktop environment..."
# Install Xorg.
pacman_install_chroot xorg-server xorg-xinit xorg-xinput xterm xf86-input-libinput xcb-util-keysyms xcb-util-cursor xcb-util-wm xcb-util-xrm
# Install xwayland-run to help run Steam during the first-time setup.
yay_install_chroot xwayland-run-git weston libwayland-server 
# Install the Simple Desktop Display Manager (SDDM).
pacman_install_chroot sddm
# Hide UIDs of Nix build users.
# https://github.com/LukeShortCloud/winesapOS/issues/840
mkdir -p ${WINESAPOS_INSTALL_DIR}/etc/sddm.conf.d/
touch ${WINESAPOS_INSTALL_DIR}/etc/sddm.conf.d/uid.conf
chroot ${WINESAPOS_INSTALL_DIR} crudini --set /etc/sddm.conf.d/uid.conf Users MaximumUid 2999
# Set up the SDDM failover handler.
mkdir -p ${WINESAPOS_INSTALL_DIR}/etc/systemd/system/sddm.service.d
cp ../files/winesapos-sddm-health-check.service ${WINESAPOS_INSTALL_DIR}/etc/systemd/system/
cp ../scripts/winesapos-sddm-health-check.sh ${WINESAPOS_INSTALL_DIR}/usr/local/bin/
chroot ${WINESAPOS_INSTALL_DIR} systemctl enable winesapos-sddm-health-check

# iPhone file transfer and and Internet tethering support.
## Install these dependencies first because 'plasma-meta' depends on 'usbmuxd'.
pacman_install_chroot libimobiledevice usbmuxd
## Replace the udev rules with new ones that workaround Mac driver issues.
## https://github.com/LukeShortCloud/winesapOS/issues/660
rm -f ${WINESAPOS_INSTALL_DIR}/usr/lib/udev/rules.d/39-usbmuxd.rules
wget "https://raw.githubusercontent.com/libimobiledevice/usbmuxd/master/udev/39-usbmuxd.rules.in" -O ${WINESAPOS_INSTALL_DIR}/usr/lib/udev/rules.d/39-usbmuxd.rules

# Lenovo Legion Go controller support for Linux kernel < 6.8.
echo "# Lenovo Legion Go
ACTION==\"add\", ATTRS{idVendor}==\"17ef\", ATTRS{idProduct}==\"6182\", RUN+=\"/sbin/modprobe xpad\" RUN+=\"/bin/sh -c 'echo 17ef 6182 > /sys/bus/usb/drivers/xpad/new_id'\"" > ${WINESAPOS_INSTALL_DIR}/usr/lib/udev/rules.d/50-lenovo-legion-controller.rules

# AYANEO LED controls.
yay_install_chroot ayaneo-platform-dkms-git ayaled-updated

# Steam Deck OLED audio support.
chroot ${WINESAPOS_INSTALL_DIR} pacman -U --noconfirm  --config <(echo -e "[options]\nArchitecture = auto\nSigLevel = Never\n") https://steamdeck-packages.steamos.cloud/archlinux-mirror/jupiter-main/os/x86_64/steamdeck-dsp-0.49-1-any.pkg.tar.zst

if [[ "${WINESAPOS_DE}" == "cinnamon" ]]; then
    echo "Installing the Cinnamon desktop environment..."
        pacman_install_chroot cinnamon
        # Image gallery and text editor.
        pacman_install_chroot maui-pix xed

    if [[ "${WINESAPOS_DISTRO_DETECTED}" == "manjaro" ]]; then
        pacman_install_chroot cinnamon-sounds cinnamon-wallpapers manjaro-cinnamon-settings manjaro-settings-manager
        # Install Manjaro specific Cinnamon theme packages.
        pacman_install_chroot adapta-maia-theme kvantum-manjaro
    fi

    echo "Installing the Cinnamon desktop environment complete."
elif [[ "${WINESAPOS_DE}" == "gnome" ]]; then
    echo "Installing the GNOME desktop environment...."
    pacman_install_chroot gnome gnome-tweaks

    if [[ "${WINESAPOS_DISTRO_DETECTED}" == "manjaro" ]]; then
        pacman_install_chroot manjaro-gnome-settings manjaro-settings-manager
    fi
    echo "Installing the GNOME desktop environment complete."
elif [[ "${WINESAPOS_DE}" == "i3" ]]
     echo "Installing i3"
     pacman_install_chroot i3-wm i3lock i3blocks i3status 
     echo "Installing i3 ... Completed successfully"
    
elif [[ "${WINESAPOS_DE}" == "sway" ]]; then
    echo "Installing the Sway tiling manager..."
    pacman_install_chroot swaylock swayidle swaybg sway 
    echo "Installing the Sway tiling manager. complete"

elif [[ "${WINESAPOS_DE}" == "plasma" ]]; then
    echo "Installing the KDE Plasma desktop environment..."
    pacman_install_chroot plasma-meta plasma-nm
    # Dolphin file manager and related plugins.
    pacman_install_chroot dolphin ffmpegthumbs kdegraphics-thumbnailers konsole
    chroot ${WINESAPOS_INSTALL_DIR} crudini --ini-options=nospace --set /etc/xdg/konsolerc "Desktop Entry" DefaultProfile Vapor.profile
    # Image gallery and text editor.
    pacman_install_chroot gwenview kate
elif [[ "${WINESAPOS_DE}" == "plasma-mobile" ]]; then
     echo "Installing the KDE Plasma Mobile DE..."
     yay_install_chroot plasma-mobile plasma-nano plasma-settings plasma-dialer plasma-mobile-sounds
     pacman_install_chroot maliit-keyboard bluez-qt kirigami-addons kpipewire kwin modemmanager-qt plasma-nm plasma-pa plasma-workspace-wallpapers
     echo "Installing the KDE Plasma Mobile DE... Completed"

    if [[ "${WINESAPOS_DISTRO_DETECTED}" == "manjaro" ]]; then
        pacman_install_chroot manjaro-kde-settings manjaro-settings-manager-knotifier
        # Install Manjaro specific KDE Plasma theme packages.
        pacman_install_chroot plasma6-themes-breath plasma6-themes-breath-extra breath-wallpapers sddm-breath-theme
    fi

    if [[ "${WINESAPOS_DISABLE_KWALLET}" == "true" ]]; then
        mkdir -p ${WINESAPOS_INSTALL_DIR}/home/${WINESAPOS_USER_NAME}/.config/
        touch ${WINESAPOS_INSTALL_DIR}/home/${WINESAPOS_USER_NAME}/.config/kwalletrc
        chroot ${WINESAPOS_INSTALL_DIR} crudini --set /home/${WINESAPOS_USER_NAME}/.config/kwalletrc Wallet Enabled false
        chroot ${WINESAPOS_INSTALL_DIR} chown -R ${WINESAPOS_USER_NAME}:${WINESAPOS_USER_NAME} /home/${WINESAPOS_USER_NAME}/.config
    fi

    # Klipper cannot be fully disabled via the CLI so we limit this service as much as possible.
    # https://github.com/LukeShortCloud/winesapOS/issues/368
    if [[ "${WINESAPOS_ENABLE_KLIPPER}" == "false" ]]; then
        mkdir -p ${WINESAPOS_INSTALL_DIR}/home/${WINESAPOS_USER_NAME}/.config/
        mkdir -p ${WINESAPOS_INSTALL_DIR}/home/${WINESAPOS_USER_NAME}/.local/share/klipper
        touch ${WINESAPOS_INSTALL_DIR}/home/${WINESAPOS_USER_NAME}/.config/klipperrc
        # Clear out the history during logout.
        chroot ${WINESAPOS_INSTALL_DIR} crudini --set /home/${WINESAPOS_USER_NAME}/.config/klipperrc General KeepClipboardContents false
        # Lower the number of items to keep in history from 20 down to 1.
        chroot ${WINESAPOS_INSTALL_DIR} crudini --set /home/${WINESAPOS_USER_NAME}/.config/klipperrc General MaxClipItems 1
        # Allow password managers to set an empty clipboard.
        chroot ${WINESAPOS_INSTALL_DIR} crudini --set /home/${WINESAPOS_USER_NAME}/.config/klipperrc General PreventEmptyClipboard false
        chroot ${WINESAPOS_INSTALL_DIR} chown -R ${WINESAPOS_USER_NAME}:${WINESAPOS_USER_NAME} /home/${WINESAPOS_USER_NAME}/.config
        # Ensure that the history is never saved to the local storage and only lives in RAM.
        echo "ramfs    /home/${WINESAPOS_USER_NAME}/.local/share/klipper    ramfs    rw,nosuid,nodev    0 0" >> ${WINESAPOS_INSTALL_DIR}/etc/fstab
    fi

    # Configure the Plasma (Wayland) session to be the default.
    # https://github.com/LukeShortCloud/winesapOS/issues/841
    if [[ "${WINESAPOS_DISTRO_DETECTED}" == "manjaro" ]]; then
        mv ${WINESAPOS_INSTALL_DIR}/usr/share/wayland-sessions/plasmawayland.desktop ${WINESAPOS_INSTALL_DIR}/usr/share/wayland-sessions/0plasmawayland.desktop
    else
        mv ${WINESAPOS_INSTALL_DIR}/usr/share/wayland-sessions/plasma.desktop ${WINESAPOS_INSTALL_DIR}/usr/share/wayland-sessions/0plasma.desktop
    fi

    pacman_install_chroot kdeconnect
    echo "Installing the KDE Plasma desktop environment complete."
fi

# Start SDDM. This will provide an option of which desktop environment to load.
chroot ${WINESAPOS_INSTALL_DIR} systemctl enable sddm
# Install Bluetooth.
pacman_install_chroot bluez bluez-utils blueman bluez-qt
chroot ${WINESAPOS_INSTALL_DIR} systemctl enable bluetooth
## This is required to turn Bluetooth on or off.
chroot ${WINESAPOS_INSTALL_DIR} usermod -a -G rfkill ${WINESAPOS_USER_NAME}
# Install printer drivers.
pacman_install_chroot cups libcups lib32-libcups bluez-cups cups-pdf usbutils
chroot ${WINESAPOS_INSTALL_DIR} systemctl enable cups
mkdir -p ${WINESAPOS_INSTALL_DIR}/home/${WINESAPOS_USER_NAME}/Desktop/
echo "Setting up the desktop environment complete."

echo 'Setting up the additional package managers...'
yay_install_chroot appimagepool-appimage bauh snapd
chroot ${WINESAPOS_INSTALL_DIR} systemctl enable snapd
# Enable support for classic Snaps.
mkdir -p ${WINESAPOS_INSTALL_DIR}/var/lib/snapd/snap
ln -s /var/lib/snapd/snap ${WINESAPOS_INSTALL_DIR}/snap

if [[ "${WINESAPOS_DISTRO_DETECTED}" == "manjaro" ]]; then
    chroot ${WINESAPOS_INSTALL_DIR} ${CMD_PACMAN_INSTALL[*]} appimagelauncher
else
    chroot ${WINESAPOS_INSTALL_DIR} ${CMD_YAY_INSTALL[*]} appimagelauncher
fi
echo 'Setting up additional package managers complete.'

if [[ "${WINESAPOS_INSTALL_GAMING_TOOLS}" == "true" ]]; then
    echo "Installing gaming tools..."
    # GameMode.
    pacman_install_chroot gamemode lib32-gamemode
    # Open Gamepad UI.
    yay_install_chroot opengamepadui-bin
    # Gamescope and Gamescope Session.
    pacman_install_chroot gamescope
    yay_install_chroot gamescope-session-git gamescope-session-steam-git opengamepadui-session-git
    # OpenRazer.
    pacman_install_chroot openrazer-daemon openrazer-driver-dkms python-pyqt5 python-openrazer
    yay_install_chroot polychromatic
    chroot ${WINESAPOS_INSTALL_DIR} gpasswd -a ${WINESAPOS_USER_NAME} plugdev
    # Oversteer.
    yay_install_chroot oversteer
    # MangoHud.
    yay_install_chroot mangohud-git lib32-mangohud-git
    # GOverlay.
    yay_install_chroot goverlay-git
    # ReplaySorcery.
    yay_install_chroot replay-sorcery-git
    # vkBasalt
    yay_install_chroot vkbasalt lib32-vkbasalt
    # Ludusavi.
    yay_install_chroot ludusavi
    # Steam dependencies.
    pacman_install_chroot gcc-libs libgpg-error libva libxcb lib32-gcc-libs lib32-libgpg-error lib32-libva lib32-libxcb
    # ZeroTier VPN.
    pacman_install_chroot zerotier-one
    yay_install_chroot zerotier-gui-git
    # game-devices-udev for more controller support.
    yay_install_chroot game-devices-udev
    EMUDECK_GITHUB_URL="https://api.github.com/repos/EmuDeck/emudeck-electron/releases/latest"
    EMUDECK_URL="$(curl -s ${EMUDECK_GITHUB_URL} | grep -E 'browser_download_url.*AppImage' | cut -d '"' -f 4)"
    wget "${EMUDECK_URL}" -O ${WINESAPOS_INSTALL_DIR}/home/${WINESAPOS_USER_NAME}/Desktop/EmuDeck.AppImage
    chmod +x ${WINESAPOS_INSTALL_DIR}/home/${WINESAPOS_USER_NAME}/Desktop/EmuDeck.AppImage
    # Steam.
    pacman_install_chroot steam steam-native-runtime
    # Steam Tinker Launch.
    yay_install_chroot steamtinkerlaunch
    # Decky Loader.
    ## First install the 'zenity' dependency.
    pacman_install_chroot zenity
    wget "https://github.com/SteamDeckHomebrew/decky-installer/releases/latest/download/decky_installer.desktop" -O ${WINESAPOS_INSTALL_DIR}/home/${WINESAPOS_USER_NAME}/Desktop/decky_installer.desktop
    echo "Installing gaming tools complete."
fi

echo "Setting up desktop shortcuts..."
cp ${WINESAPOS_INSTALL_DIR}/usr/share/applications/appimagepool.desktop ${WINESAPOS_INSTALL_DIR}/home/${WINESAPOS_USER_NAME}/Desktop/
cp ${WINESAPOS_INSTALL_DIR}/usr/share/applications/bauh.desktop ${WINESAPOS_INSTALL_DIR}/home/${WINESAPOS_USER_NAME}/Desktop/
cp ${WINESAPOS_INSTALL_DIR}/usr/share/applications/blueman-manager.desktop ${WINESAPOS_INSTALL_DIR}/home/${WINESAPOS_USER_NAME}/Desktop/
cp ${WINESAPOS_INSTALL_DIR}/usr/share/applications/firefox-esr.desktop ${WINESAPOS_INSTALL_DIR}/home/${WINESAPOS_USER_NAME}/Desktop/
cp ${WINESAPOS_INSTALL_DIR}/usr/share/applications/terminator.desktop ${WINESAPOS_INSTALL_DIR}/home/${WINESAPOS_USER_NAME}/Desktop/

if [[ "${WINESAPOS_DE}" == "cinnamon" ]]; then
    cp ${WINESAPOS_INSTALL_DIR}/usr/share/applications/nemo.desktop ${WINESAPOS_INSTALL_DIR}/home/${WINESAPOS_USER_NAME}/Desktop/
    cp ${WINESAPOS_INSTALL_DIR}/usr/share/applications/org.kde.pix.desktop ${WINESAPOS_INSTALL_DIR}/home/${WINESAPOS_USER_NAME}/Desktop/
elif [[ "${WINESAPOS_DE}" == "gnome" ]]; then
    cp ${WINESAPOS_INSTALL_DIR}/usr/share/applications/org.gnome.eog.desktop ${WINESAPOS_INSTALL_DIR}/home/${WINESAPOS_USER_NAME}/Desktop/
    cp ${WINESAPOS_INSTALL_DIR}/usr/share/applications/org.gnome.Nautilus.desktop ${WINESAPOS_INSTALL_DIR}/home/${WINESAPOS_USER_NAME}/Desktop/
elif [[ "${WINESAPOS_DE}" == "plasma" ]]; then
    cp ${WINESAPOS_INSTALL_DIR}/usr/share/applications/org.kde.dolphin.desktop ${WINESAPOS_INSTALL_DIR}/home/${WINESAPOS_USER_NAME}/Desktop/
    cp ${WINESAPOS_INSTALL_DIR}/usr/share/applications/org.kde.gwenview.desktop ${WINESAPOS_INSTALL_DIR}/home/${WINESAPOS_USER_NAME}/Desktop/
fi

if [[ "${WINESAPOS_INSTALL_GAMING_TOOLS}" == "true" ]]; then
    # GOverlay.
    cp ${WINESAPOS_INSTALL_DIR}/usr/share/applications/io.github.benjamimgois.goverlay.desktop ${WINESAPOS_INSTALL_DIR}/home/${WINESAPOS_USER_NAME}/Desktop/
    # Ludusavi.
    cp ${WINESAPOS_INSTALL_DIR}/usr/share/applications/com.github.mtkennerly.ludusavi.desktop ${WINESAPOS_INSTALL_DIR}/home/${WINESAPOS_USER_NAME}/Desktop/
    # Oversteer.
    cp ${WINESAPOS_INSTALL_DIR}/usr/share/applications/org.berarma.Oversteer.desktop ${WINESAPOS_INSTALL_DIR}/home/${WINESAPOS_USER_NAME}/Desktop/
    # Polychromatic.
    cp ${WINESAPOS_INSTALL_DIR}/usr/share/applications/polychromatic.desktop ${WINESAPOS_INSTALL_DIR}/home/${WINESAPOS_USER_NAME}/Desktop/
    # Steam.
    cp ${WINESAPOS_INSTALL_DIR}/usr/share/applications/steam.desktop ${WINESAPOS_INSTALL_DIR}/home/${WINESAPOS_USER_NAME}/Desktop/steam.desktop
    chmod +x ${WINESAPOS_INSTALL_DIR}/home/${WINESAPOS_USER_NAME}/Desktop/steam.desktop
    cp ${WINESAPOS_INSTALL_DIR}/usr/share/applications/steamtinkerlaunch.desktop ${WINESAPOS_INSTALL_DIR}/home/${WINESAPOS_USER_NAME}/Desktop/
    chmod +x ${WINESAPOS_INSTALL_DIR}/home/${WINESAPOS_USER_NAME}/Desktop/steamtinkerlaunch.desktop
    # ZeroTier GUI.
    cp ${WINESAPOS_INSTALL_DIR}/usr/share/applications/zerotier-gui.desktop ${WINESAPOS_INSTALL_DIR}/home/${WINESAPOS_USER_NAME}/Desktop/
fi

if [[ "${WINESAPOS_INSTALL_PRODUCTIVITY_TOOLS}" == "true" ]]; then
    # ClamTk (ClamAV GUI).
    cp ${WINESAPOS_INSTALL_DIR}/usr/share/applications/clamtk.desktop ${WINESAPOS_INSTALL_DIR}/home/${WINESAPOS_USER_NAME}/Desktop/
    # CoolerControl.
    cp ${WINESAPOS_INSTALL_DIR}/usr/share/applications/org.coolercontrol.CoolerControl.desktop ${WINESAPOS_INSTALL_DIR}/home/${WINESAPOS_USER_NAME}/Desktop/
    # GParted.
    cp ${WINESAPOS_INSTALL_DIR}/usr/share/applications/gparted.desktop ${WINESAPOS_INSTALL_DIR}/home/${WINESAPOS_USER_NAME}/Desktop/
    # QDirStat.
    cp ${WINESAPOS_INSTALL_DIR}/usr/share/applications/qdirstat.desktop ${WINESAPOS_INSTALL_DIR}/home/${WINESAPOS_USER_NAME}/Desktop/
    # Spectacle.
    cp ${WINESAPOS_INSTALL_DIR}/usr/share/applications/org.kde.spectacle.desktop ${WINESAPOS_INSTALL_DIR}/home/${WINESAPOS_USER_NAME}/Desktop/
    # VeraCrypt.
    cp ${WINESAPOS_INSTALL_DIR}/usr/share/applications/veracrypt.desktop ${WINESAPOS_INSTALL_DIR}/home/${WINESAPOS_USER_NAME}/Desktop/
fi

if [[ "${WINESAPOS_FIREWALL}" == "true" ]]; then
    cp ${WINESAPOS_INSTALL_DIR}/usr/share/applications/firewall-config.desktop ${WINESAPOS_INSTALL_DIR}/home/${WINESAPOS_USER_NAME}/Desktop/
fi

# Fix permissions on the desktop shortcuts.
chmod +x ${WINESAPOS_INSTALL_DIR}/home/${WINESAPOS_USER_NAME}/Desktop/*.desktop
chown -R 1000:1000 ${WINESAPOS_INSTALL_DIR}/home/${WINESAPOS_USER_NAME}/Desktop
echo "Setting up desktop shortcuts complete."

echo "Setting up additional Mac drivers..."
# Enable the T2 driver on boot.
sed -i s'/MODULES=(/MODULES=(apple-bce /'g ${WINESAPOS_INSTALL_DIR}/etc/mkinitcpio.conf
echo apple-bce >> ${WINESAPOS_INSTALL_DIR}/etc/modules-load.d/winesapos-mac.conf

# Delay the start of the Touch Bar driver.
# This works around a known bug where the driver cannot be configured.
# https://wiki.t2linux.org/guides/postinstall/
echo -e "install apple-touchbar /bin/sleep 10; /sbin/modprobe --ignore-install apple-touchbar" >> ${WINESAPOS_INSTALL_DIR}/etc/modprobe.d/winesapos-mac.conf

echo "Setting up additional Mac drivers complete."

echo "Setting up fan drivers..."
# Apple Macs.
yay_install_chroot mbpfan-git
chroot ${WINESAPOS_INSTALL_DIR} crudini --set /etc/mbpfan.conf general min_fan_speed 1300
chroot ${WINESAPOS_INSTALL_DIR} crudini --set /etc/mbpfan.conf general max_fan_speed 6200
chroot ${WINESAPOS_INSTALL_DIR} crudini --set /etc/mbpfan.conf general max_temp 105

# OneXPlayer handhelds.
yay_install_chroot oxp-sensors-dkms-git
echo "Setting up fan drivers complete."

echo "Setting mkinitcpio modules and hooks order..."

# Required fix for:
# https://github.com/LukeShortCloud/winesapOS/issues/94
if [[ "${WINESAPOS_ENCRYPT}" == "true" ]]; then
    # Also add 'keymap' and 'encrypt' for LUKS encryption support.
    sed -i s'/HOOKS=.*/HOOKS=(base microcode udev block keyboard keymap modconf encrypt filesystems fsck)/'g ${WINESAPOS_INSTALL_DIR}/etc/mkinitcpio.conf
else
    sed -i s'/HOOKS=.*/HOOKS=(base microcode udev block keyboard modconf filesystems fsck)/'g ${WINESAPOS_INSTALL_DIR}/etc/mkinitcpio.conf
fi

echo "Setting mkinitcpio modules and hooks order complete."

if [[ "${WINESAPOS_BUILD_CHROOT_ONLY}" == "false" ]]; then
    echo "Setting up the bootloader..."
    # Remove the redundant fallback initramfs because our normal initramfs is exactly the same.
    sed -i s"/PRESETS=('default' 'fallback')/PRESETS=('default')/"g ${WINESAPOS_INSTALL_DIR}/etc/mkinitcpio.d/*.preset
    rm -f ${WINESAPOS_INSTALL_DIR}/boot/*-fallback.img
    chroot ${WINESAPOS_INSTALL_DIR} mkinitcpio -P
    # These two configuration lines allow the GRUB menu to show on boot.
    # https://github.com/LukeShortCloud/winesapOS/issues/41
    chroot ${WINESAPOS_INSTALL_DIR} crudini --ini-options=nospace --set /etc/default/grub "" GRUB_TIMEOUT 10
    chroot ${WINESAPOS_INSTALL_DIR} crudini --ini-options=nospace --set /etc/default/grub "" GRUB_TIMEOUT_STYLE menu

    if [[ "${WINESAPOS_APPARMOR}" == "true" ]]; then
        echo "Enabling AppArmor in the Linux kernel..."
        sed -i s'/GRUB_CMDLINE_LINUX="/GRUB_CMDLINE_LINUX="apparmor=1 security=apparmor /'g ${WINESAPOS_INSTALL_DIR}/etc/default/grub
        echo "Enabling AppArmor in the Linux kernel complete."
    fi

    if [[ "${WINESAPOS_CPU_MITIGATIONS}" == "false" ]]; then
        echo "Enabling Linux kernel-level CPU exploit mitigations..."
        sed -i s'/GRUB_CMDLINE_LINUX_DEFAULT="/GRUB_CMDLINE_LINUX_DEFAULT="mitigations=off /'g ${WINESAPOS_INSTALL_DIR}/etc/default/grub
        echo "Enabling Linux kernel-level CPU exploit mitigations done."
    fi

    # Enable Btrfs with zstd compression support.
    # This will help allow GRUB to save the selected kernel for the next boot.
    sed -i s'/GRUB_PRELOAD_MODULES="/GRUB_PRELOAD_MODULES="btrfs zstd /'g ${WINESAPOS_INSTALL_DIR}/etc/default/grub
    # Disable the submenu to show all boot kernels/options on the main GRUB menu.
    chroot ${WINESAPOS_INSTALL_DIR} crudini --ini-options=nospace --set /etc/default/grub "" GRUB_DISABLE_SUBMENU y
    # Configure the default Linux kernel for the first boot.
    # This should be linux-fsync-nobara-bin.
    if [[ "${WINESAPOS_DISTRO_DETECTED}" == "manjaro" ]]; then
        # This is the 1st kernel in the list.
        chroot ${WINESAPOS_INSTALL_DIR} crudini --ini-options=nospace --set /etc/default/grub "" GRUB_DEFAULT 0
    else
        # This is the 2nd kernel in the list.
        chroot ${WINESAPOS_INSTALL_DIR} crudini --ini-options=nospace --set /etc/default/grub "" GRUB_DEFAULT 1
    fi
    # Use partitions UUIDs instead of Linux UUIDs. This is more portable across different UEFI motherboards.
    chroot ${WINESAPOS_INSTALL_DIR} crudini --ini-options=nospace --set /etc/default/grub "" GRUB_DISABLE_LINUX_UUID true
    chroot ${WINESAPOS_INSTALL_DIR} crudini --ini-options=nospace --set /etc/default/grub "" GRUB_DISABLE_LINUX_PARTUUID false
    # Setup the GRUB theme.
    pacman_install_chroot grub-theme-vimix
    ## This theme needs to exist in the '/boot/' mount because if the root file system is encrypted, then the theme cannot be found.
    mkdir -p ${WINESAPOS_INSTALL_DIR}/boot/grub/themes/
    cp -R ${WINESAPOS_INSTALL_DIR}/usr/share/grub/themes/Vimix ${WINESAPOS_INSTALL_DIR}/boot/grub/themes/Vimix
    chroot ${WINESAPOS_INSTALL_DIR} crudini --ini-options=nospace --set /etc/default/grub "" GRUB_THEME /boot/grub/themes/Vimix/theme.txt
    ## Target 720p for the GRUB menu as a minimum to support devices such as the GPD Win.
    ## https://github.com/LukeShortCloud/winesapOS/issues/327
    chroot ${WINESAPOS_INSTALL_DIR} crudini --ini-options=nospace --set /etc/default/grub "" GRUB_GFXMODE 1280x720,auto
    ## Setting the GFX payload to 'text' instead 'keep' makes booting more reliable by supporting all graphics devices.
    ## https://github.com/LukeShortCloud/winesapOS/issues/327
    chroot ${WINESAPOS_INSTALL_DIR} crudini --ini-options=nospace --set /etc/default/grub "" GRUB_GFXPAYLOAD_LINUX text
    # Set winesapOS name in the GRUB menu.
    chroot ${WINESAPOS_INSTALL_DIR} crudini --ini-options=nospace --set /etc/default/grub "" GRUB_DISTRIBUTOR winesapOS

    chroot ${WINESAPOS_INSTALL_DIR} grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=winesapOS --removable --no-nvram
    parted ${DEVICE} set 1 bios_grub on
    chroot ${WINESAPOS_INSTALL_DIR} grub-install --target=i386-pc ${DEVICE}

    if [[ "${WINESAPOS_ENCRYPT}" == "true" ]]; then
        sed -i s'/GRUB_CMDLINE_LINUX="/GRUB_CMDLINE_LINUX="cryptdevice=LABEL=winesapos-luks:cryptroot root='$(echo ${root_partition} | sed -e s'/\//\\\//'g)' /'g ${WINESAPOS_INSTALL_DIR}/etc/default/grub
    fi

    # Configure higher polling frequencies for better compatibility with input devices.
    sed -i s'/GRUB_CMDLINE_LINUX="/GRUB_CMDLINE_LINUX="usbhid.jspoll=1 usbhid.kbpoll=1 usbhid.mousepoll=1 /'g ${WINESAPOS_INSTALL_DIR}/etc/default/grub

    # Configure support for NVMe drives.
    sed -i s'/GRUB_CMDLINE_LINUX="/GRUB_CMDLINE_LINUX="nvme_load=yes /'g ${WINESAPOS_INSTALL_DIR}/etc/default/grub

    # Configure S3 deep sleep.
    sed -i s'/GRUB_CMDLINE_LINUX="/GRUB_CMDLINE_LINUX="mem_sleep_default=deep /'g ${WINESAPOS_INSTALL_DIR}/etc/default/grub

    efi_partition=2
    if [[ "${WINESAPOS_ENABLE_PORTABLE_STORAGE}" == "true" ]]; then
        efi_partition=3
    fi

    chroot ${WINESAPOS_INSTALL_DIR} grub-mkconfig -o /boot/grub/grub.cfg
    echo "Setting up the bootloader complete."
fi

echo "Enabling optimal IO schedulers..."
mkdir -p ${WINESAPOS_INSTALL_DIR}/etc/udev/rules.d/
echo '# Serial drives and SD cards.
ACTION=="add|change", KERNEL=="sd[a-z]*|mmcblk[0-9]*", ATTR{queue/scheduler}="bfq"

# NVMe drives.
ACTION=="add|change", KERNEL=="nvme[0-9]*", ATTR{queue/scheduler}="kyber"' > ${WINESAPOS_INSTALL_DIR}/etc/udev/rules.d/60-winesapos-io-schedulers.rules
echo "Enabling optimal IO schedulers complete."

echo "Setting up root file system resize script..."
# This package provides the required 'growpart' command.
pacman_install_chroot cloud-guest-utils
# Copy from the current directory which should be "scripts".
cp ./winesapos-resize-root-file-system.sh ${WINESAPOS_INSTALL_DIR}/usr/local/bin/
cp ../files/winesapos-resize-root-file-system.service ${WINESAPOS_INSTALL_DIR}/etc/systemd/system/
chroot ${WINESAPOS_INSTALL_DIR} systemctl enable winesapos-resize-root-file-system
echo "Setting up root file system resize script complete."

echo "Installing tools needed for dual-boot support..."
pacman_install_chroot arch-install-scripts os-prober
echo "Installing tools needed for dual-boot support complete."

echo "Setting up the first-time setup script..."
# Install dependencies for the first-time setup script.
## JSON Query is required for both the first-time setup and EmuDeck for video game console emulators.
## https://github.com/dragoonDorise/EmuDeck/pull/830/commits/22963b60503f495dd4c6185a15cb431d75c06022
pacman_install_chroot jq
# winesapOS first-time setup script.
mkdir -p ${WINESAPOS_INSTALL_DIR}/home/${WINESAPOS_USER_NAME}/.winesapos/ ${WINESAPOS_INSTALL_DIR}/home/${WINESAPOS_USER_NAME}/.config/autostart/
cp ./winesapos-setup.sh ${WINESAPOS_INSTALL_DIR}/home/${WINESAPOS_USER_NAME}/.winesapos/
cp ../files/winesapos-setup.desktop ${WINESAPOS_INSTALL_DIR}/home/${WINESAPOS_USER_NAME}/.winesapos/
sed -i s"/home\/winesap/home\/${WINESAPOS_USER_NAME}/"g ${WINESAPOS_INSTALL_DIR}/home/${WINESAPOS_USER_NAME}/.winesapos/winesapos-setup.desktop
ln -s /home/${WINESAPOS_USER_NAME}/.winesapos/winesapos-setup.desktop ${WINESAPOS_INSTALL_DIR}/home/${WINESAPOS_USER_NAME}/.config/autostart/winesapos-setup.desktop
ln -s /home/${WINESAPOS_USER_NAME}/.winesapos/winesapos-setup.desktop ${WINESAPOS_INSTALL_DIR}/home/${WINESAPOS_USER_NAME}/Desktop/winesapos-setup.desktop
## Install th required dependency for the setup script.
pacman_install_chroot kdialog
# winesapOS remote upgrade script.
cp ./winesapos-upgrade-remote-stable.sh ${WINESAPOS_INSTALL_DIR}/home/${WINESAPOS_USER_NAME}/.winesapos/
cp ../files/winesapos-upgrade.desktop ${WINESAPOS_INSTALL_DIR}/home/${WINESAPOS_USER_NAME}/.winesapos/
sed -i s"/home\/winesap/home\/${WINESAPOS_USER_NAME}/"g ${WINESAPOS_INSTALL_DIR}/home/${WINESAPOS_USER_NAME}/.winesapos/winesapos-upgrade.desktop
ln -s /home/${WINESAPOS_USER_NAME}/.winesapos/winesapos-upgrade.desktop ${WINESAPOS_INSTALL_DIR}/home/${WINESAPOS_USER_NAME}/Desktop/winesapos-upgrade.desktop
# winesapOS icon used for both desktop shortcuts and the SDDM profile picture.
cp ../files/winesapos_logo_icon.png ${WINESAPOS_INSTALL_DIR}/home/${WINESAPOS_USER_NAME}/.winesapos/winesapos_logo_icon.png
## Using an actual file instead of a symlink works more reliably for loading it.
cp ../files/winesapos_logo_icon.png ${WINESAPOS_INSTALL_DIR}/usr/share/sddm/faces/${WINESAPOS_USER_NAME}.face.icon
echo "Setting up the first-time setup script complete."

echo "Setting up the dual-boot script..."
cp ./winesapos-dual-boot.sh ${WINESAPOS_INSTALL_DIR}/usr/local/bin/
cp ../files/winesapos-dual-boot.desktop ${WINESAPOS_INSTALL_DIR}/home/${WINESAPOS_USER_NAME}/.winesapos/
ln -s /home/${WINESAPOS_USER_NAME}/.winesapos/winesapos-dual-boot.desktop ${WINESAPOS_INSTALL_DIR}/home/${WINESAPOS_USER_NAME}/Desktop/winesapos-dual-boot.desktop
echo "Setting up the dual-boot script complete."

if [[ "${WINESAPOS_BUILD_CHROOT_ONLY}" == "false" ]]; then
    echo "Configuring Btrfs backup tools..."
    pacman_install_chroot grub-btrfs snapper snap-pac
    chroot ${WINESAPOS_INSTALL_DIR} crudini --ini-options=nospace --set /etc/default/grub-btrfs/config "" GRUB_BTRFS_SUBMENUNAME "\"winesapOS snapshots\""
    cp ../files/etc-snapper-configs-root ${WINESAPOS_INSTALL_DIR}/etc/snapper/configs/root
    cp ../files/etc-snapper-configs-root ${WINESAPOS_INSTALL_DIR}/etc/snapper/configs/home
    # Disable the timeline for the root configuration. Rely on 'snap-pac' instead.
    sed -i s'/TIMELINE_CREATE=.*/TIMELINE_CREATE=\"no\"/'g ${WINESAPOS_INSTALL_DIR}/etc/snapper/configs/root
    sed -i s'/SUBVOLUME=.*/SUBVOLUME=\"\/home\"/'g ${WINESAPOS_INSTALL_DIR}/etc/snapper/configs/home
    chroot ${WINESAPOS_INSTALL_DIR} chown -R root:root /etc/snapper/configs
    btrfs subvolume create ${WINESAPOS_INSTALL_DIR}/.snapshots
    btrfs subvolume create ${WINESAPOS_INSTALL_DIR}/home/.snapshots
    # Ensure the new "root" and "home" configurations will be loaded.
    sed -i s'/SNAPPER_CONFIGS=\"\"/SNAPPER_CONFIGS=\"root home\"/'g ${WINESAPOS_INSTALL_DIR}/etc/conf.d/snapper
    chroot ${WINESAPOS_INSTALL_DIR} systemctl enable snapper-cleanup.timer snapper-timeline.timer
    echo "Configuring Btrfs backup tools complete."
fi

echo "Resetting the machine-id file..."
echo -n | tee ${WINESAPOS_INSTALL_DIR}/etc/machine-id
rm -f ${WINESAPOS_INSTALL_DIR}/var/lib/dbus/machine-id
chroot ${WINESAPOS_INSTALL_DIR} ln -s /etc/machine-id /var/lib/dbus/machine-id
echo "Resetting the machine-id file complete."

echo "Setting up winesapOS files..."
mkdir ${WINESAPOS_INSTALL_DIR}/var/winesapos/
# Create a symlink for backwards compatibility.
chroot ${WINESAPOS_INSTALL_DIR} ln -s /var/winesapos /etc/winesapos
# Secure this directory as it contains the verbose build log.
chmod 0700 ${WINESAPOS_INSTALL_DIR}/var/winesapos/
cp ../files/os-release-winesapos ${WINESAPOS_INSTALL_DIR}/usr/lib/
echo -e "VARIANT=\""${WINESAPOS_IMAGE_TYPE}""\"\\nVARIANT_ID=${WINESAPOS_IMAGE_TYPE} | tee -a ${WINESAPOS_INSTALL_DIR}/usr/lib/os-release-winesapos
chroot ${WINESAPOS_INSTALL_DIR} ln -s /usr/lib/os-release-winesapos /etc/os-release-winesapos
cp /tmp/winesapos-install.log ${WINESAPOS_INSTALL_DIR}/var/winesapos/
# Continue to log to the file after it has been copied over.
exec > >(tee -a ${WINESAPOS_INSTALL_DIR}/var/winesapos/winesapos-install.log) 2>&1
echo "Setting up winesapOS files complete."

echo "Setting up default text editor..."
echo "EDITOR=nano" >> ${WINESAPOS_INSTALL_DIR}/etc/environment
echo "Setting up default text editor complete."

echo "Cleaning up..."

# Temporarily add write permissions back to the file so we can modify it.
chmod 0644 ${WINESAPOS_INSTALL_DIR}/etc/sudoers.d/winesap

if [[ "${WINESAPOS_SUDO_NO_PASSWORD}" == "false" ]]; then
    echo "Require the 'winesap' user to enter a password when using sudo..."
    echo "${WINESAPOS_USER_NAME} ALL=(root) ALL" > ${WINESAPOS_INSTALL_DIR}/etc/sudoers.d/${WINESAPOS_USER_NAME}
    # This command is required for the user 'winesapos-mute.service'.
    echo "${WINESAPOS_USER_NAME} ALL=(root) NOPASSWD: /usr/bin/dmidecode" >> ${WINESAPOS_INSTALL_DIR}/etc/sudoers.d/${WINESAPOS_USER_NAME}
    echo "Require the 'winesap' user to enter a password when using sudo complete."
fi

# "sudo" defaults to a 15 minute timeout for when the user password needs to be provided again.
# This provides a problem for automated first-time setup and upgrade scripts on the secure image.
# Set the timeout to infinity (no timeout) by using a negative number.
# "sudo" also only allows 3 failed passwords before locking a user out from running privileged commands
# for a short period of time. Increase that to 20 tries to allow users to figure out their password.
echo "Defaults:${WINESAPOS_USER_NAME} passwd_tries=20,timestamp_timeout=-1" >> ${WINESAPOS_INSTALL_DIR}/etc/sudoers.d/${WINESAPOS_USER_NAME}
chmod 0440 ${WINESAPOS_INSTALL_DIR}/etc/sudoers.d/${WINESAPOS_USER_NAME}

chown -R 1000:1000 ${WINESAPOS_INSTALL_DIR}/home/${WINESAPOS_USER_NAME}

# For some unknown reason, this empty directory gets populated in the chroot using the name of the live environment kernel.
# https://github.com/LukeShortCloud/winesapOS/issues/607
LIVE_UNAME_R=$(uname -r)
rm -r -f ${WINESAPOS_INSTALL_DIR}/lib/modules/${LIVE_UNAME_R}

# Fix GPG errors due to incomplete keys.
# These configuration files will get properly recreated the next time GPG is used.
# https://github.com/LukeShortCloud/winesapOS/issues/851
rm -r -f ${WINESAPOS_INSTALL_DIR}/home/${WINESAPOS_USER_NAME}/.gnupg
echo "Cleaning up complete."

if [[ "${WINESAPOS_PASSWD_EXPIRE}" == "true" ]]; then

    for u in root ${WINESAPOS_USER_NAME}; do
        echo -n "Setting the password for ${u} to expire..."
        chroot ${WINESAPOS_INSTALL_DIR} passwd --expire ${u}
        echo "Done."
    done

fi

if [ -n "${WINESAPOS_HTTP_PROXY_CA}" ]; then
    echo "Removing the proxy certificate authority from the chroot..."
    rm -f ${WINESAPOS_INSTALL_DIR}/etc/ca-certificates/trust-source/anchors/$(echo ${WINESAPOS_HTTP_PROXY_CA} | grep -o -P '[^\/]*$')
    chroot ${WINESAPOS_INSTALL_DIR} update-ca-trust
    echo "Removing the proxy certificate authority from the chroot complete."
fi

if [[ -n "${WINESAPOS_CUSTOM_SCRIPT}" ]]; then
    echo "Looking for custom script..."
    if [ -f "${WINESAPOS_CUSTOM_SCRIPT}" ]; then
        echo "The custom script was found."
        echo "Viewing contents of the custom script..."
        cat "${WINESAPOS_CUSTOM_SCRIPT}"
        echo "Viewing contents of the custom script complete."
        echo "Running the custom script..."
        bash "${WINESAPOS_CUSTOM_SCRIPT}"
        echo "Running the custom script complete."
    else
        echo "The custom script was not found."
    fi
fi

echo "Defragmenting Btrfs root file system..."
btrfs filesystem defragment -r ${WINESAPOS_INSTALL_DIR}
echo "Defragmenting Btrfs root file system complete."

echo "Syncing files to disk..."
sync
echo "Syncing files to disk complete."

echo "Viewing final list of installed packages..."
chroot ${WINESAPOS_INSTALL_DIR} pacman -Q
echo "Viewing final list of installed packages complete."

echo "Running tests..."
bash ./winesapos-tests.sh
# The return code is the number of failed tests.
winesapos_tests_rc="$?"
echo "Running tests complete."

echo "Viewing final storage space usage..."
df -h
btrfs filesystem df -h ${WINESAPOS_INSTALL_DIR}
lsblk
echo "Viewing final storage space usage complete."

echo "Done."
echo "End time: $(date)"

if [[ "${WINESAPOS_CREATE_DEVICE}" == "true" ]]; then
    chroot ${WINESAPOS_INSTALL_DIR} pacman -Q > ../output/winesapos-packages.txt
    echo ${winesapos_tests_rc} > ../output/winesapos-install-rc.txt
    cp ${WINESAPOS_INSTALL_DIR}/var/winesapos/winesapos-install.log ../output/
fi

if (( ${winesapos_tests_rc} == 0 )); then
    exit 0
else
    exit ${winesapos_tests_rc}
fi
