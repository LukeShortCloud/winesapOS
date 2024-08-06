#!/bin/bash

echo -e "winesapOS Dual-Boot Installer (Beta)\n"
echo "Please read the full instructions first at: https://github.com/LukeShortCloud/winesapOS?tab=readme-ov-file#dual-boot"
echo "USE AT YOUR OWN RISK! DATA LOSS IS POSSIBLE. CLOSE THIS WINDOW IF YOU DO NOT ACCEPT THE RISK. OTHERWISE, ENTER ANY KEY TO COTINUE."
read -p ""

export WINESAPOS_IMAGE_TYPE="$(grep VARIANT_ID /usr/lib/os-release-winesapos | cut -d = -f 2)"
if [[ "${WINESAPOS_IMAGE_TYPE}" == "secure" ]]; then
    echo "INFO: Enter the root password when prompted..."
    sudo whoami
fi

echo "INFO: Determining the correct device name..."
ls -1 /dev/disk/by-label/winesapos-root0 &> /dev/null
if [ $? -eq 0 ]; then
    echo "INFO: Partition with label 'winesapos-root0' found."
    root_partition=$(ls -l /dev/disk/by-label/winesapos-root0 | grep -o -P "(hdd|mmcblk|nvme|sd).+")
    echo "DEBUG: Partition name is ${root_partition}."
    echo ${root_partition} | grep -q nvme
    if [ $? -eq 0 ]; then
        root_device=$(echo ${root_partition} | grep -P -o "/dev/nvme[0-9]+n[0-9]+")
    else
        echo ${root_partition} | grep -q mmcblk
        if [ $? -eq 0 ]; then
            root_device=$(echo ${root_partition} | grep -P -o "/dev/mmcblk[0-9]+")
        else
            root_device=$(echo ${root_partition} | sed s'/[0-9]//'g)
        fi
    fi
    echo "DEBUG: Root device name is ${root_device}."
else
    echo "ERROR: No partition with label 'winesapos-root0' found."
    exit 1
fi


lsblk --raw -o name,label | grep -q WOS-EFI0
if [ $? -eq 0 ]; then
    echo "INFO: EFI partition label WOS-EFI0 found."
    efi_partition="/dev/disk/by-label/WOS-EFI0"
else
    efi_partition=$(sudo fdisk -l /dev/${root_device} | grep "EFI System" | awk '{print $1}')
    echo ${efi_partition} | grep -q -o -P "(hdd|mmcblk|nvme|sd|).+"
    if [ $? -ne 0 ]; then
        echo "ERROR: No EFI partition found."
        exit 1
    else
        echo "INFO: Setting EFI label for a more reliable /etc/fstab later..."
        sudo fatlabel ${efi_partition} WOS-EFI0
    fi
fi
echo "INFO: EFI partition name is ${efi_partition}."

echo "INFO Mounting partitions..."
sudo mount -t btrfs -o subvol=/,compress-force=zstd:1,discard,noatime,nodiratime -L winesapos-root0 /mnt
sudo btrfs subvolume create /mnt/.snapshots
sudo btrfs subvolume create /mnt/home
sudo mount -t btrfs -o subvol=/home,compress-force=zstd:1,discard,noatime,nodiratime -L winesapos-root0 /mnt/home
sudo btrfs subvolume create /mnt/home/.snapshots
sudo btrfs subvolume create /mnt/swap
sudo mount -t btrfs -o subvol=/swap,compress-force=zstd:1,discard,noatime,nodiratime -L winesapos-root0 /mnt/swap
sudo mkdir /mnt/boot
sudo mount --label winesapos-boot0 /mnt/boot
sudo mkdir /mnt/boot/efi
sudo mount /dev/disk/by-label/WOS-EFI0 /mnt/boot/efi

winesapos_find_tarball() {
    for i in \
      "/run/media/${USER}/wos-drive" \
      "${HOME}/Desktop" \
      "${HOME}/Downloads"; \
        do ls -1 "${i}" 2> /dev/null | grep -q -P ".+-minimal.rootfs.tar.zst$"
        if [ $? -eq 0 ]; then
            echo "${i}/$(ls -1 "${i}" | grep -P ".+-minimal.rootfs.tar.zst$" | tail -n 1)"
	    return 0
        fi
    done
    echo "NONE"
    return 1
}

echo "INFO: Looking for existing tarballs..."
winesapos_tarball="$(winesapos_find_tarball)"
if [[ "${winesapos_tarball}" == "NONE" ]]; then
    echo "INFO: No winesapOS tarball found."
    WINESAPOS_VERSION_LATEST="$(curl https://raw.githubusercontent.com/LukeShortCloud/winesapOS/stable/files/os-release-winesapos | grep VERSION_ID | cut -d = -f 2)"
    cd "${HOME}/Downloads"
    echo "INFO: Downloading the rootfs tarball..."
    wget https://winesapos.lukeshort.cloud/repo/iso/winesapos-${WINESAPOS_VERSION_LATEST}/winesapos-${WINESAPOS_VERSION_LATEST}-minimal-rootfs.tar.zst
    winesapos_tarball="${HOME}/Downloads/winesapos-${WINESAPOS_VERSION_LATEST}-minimal-rootfs.tar.zst"
else
    echo "DEBUG: winesapOS tarball path is ${winesapos_tarball}"
fi

echo "INFO: Extracintg the rootfs tarball..."
sudo tar --extract --keep-old-files --verbose --file "${winesapos_tarball}" --directory /mnt/

# Configure the booloader.
## Only get the tmpfs mounts from the original /etc/fstab.
grep -v -P "winesapos|WOS" /mnt/etc/fstab | sudo tee /mnt/etc/fstab
## Then add the partition mounts using labels.
genfstab -L /mnt | sudo tee -a /mnt/etc/fstab
sudo mount --rbind /dev /mnt/dev
sudo mount --rbind /sys /mnt/sys
sudo mount -t proc /proc /mnt/proc
## Install GRUB.
sudo chroot /mnt grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=winesapOS
sudo chroot /mnt grub-mkconfig -o /boot/grub/grub.cfg
## Rebuild the initramfs so it is aware of the bootloader changes.
sudo chroot /mnt mkinitcpio -P
sudo sync

echo "INFO: Dual-boot installation complete!"
# Keep the terminal window open so users can review the logs.
sleep infinity
