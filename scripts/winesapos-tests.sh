#!/bin/bash

WINESAPOS_DEBUG_TESTS="${WINESAPOS_DEBUG_TESTS:-false}"
if [[ "${WINESAPOS_DEBUG_TESTS}" == "true" ]]; then
    set -x
else
    set +x
fi

echo "Tests start time: $(date)"

current_shell=$(cat /proc/$$/comm)
if [[ "${current_shell}" != "bash" ]]; then
    echo "winesapOS scripts require Bash but ${current_shell} detected. Exiting..."
    exit 1
fi

# Load default environment variables.
. ./env/winesapos-env-defaults.sh

WINESAPOS_DEVICE="${WINESAPOS_DEVICE:-vda}"

if [[ "${WINESAPOS_CREATE_DEVICE}" == "true" ]];
    then DEVICE="$(cat /tmp/winesapos-device.txt)"
else
    DEVICE="/dev/${WINESAPOS_DEVICE}"
fi

failed_tests=0
winesapos_test_failure() {
    failed_tests=$(expr ${failed_tests} + 1)
    echo FAIL
}

if [[ "${WINESAPOS_BUILD_CHROOT_ONLY}" == "false" ]]; then
    DEVICE_WITH_PARTITION="${DEVICE}"
    echo ${DEVICE} | grep -q -P "^/dev/(nvme|loop)"
    if [ $? -eq 0 ]; then
        # "nvme" and "loop" devices separate the device name and partition number by using a "p".
        # Example output: /dev/loop0p
        DEVICE_WITH_PARTITION="${DEVICE}p"
    fi

    echo "Testing partitions..."
    DEVICE_WITH_PARTITION_SHORT=$(echo ${DEVICE_WITH_PARTITION} | cut -d/ -f3)
    parted_print="$(parted ${DEVICE} print)"

    echo -n "\t\tChecking that ${DEVICE_WITH_PARTITION}1 is not formatted..."
    echo "${parted_print}" | grep -P "^ 1 " | grep -q -P "kB\s+primary"
    if [ $? -eq 0 ]; then
        echo PASS
    else
        winesapos_test_failure
    fi

    if [[ "${WINESAPOS_ENABLE_PORTABLE_STORAGE}" == "true" ]]; then
        echo -n "\t\tChecking that ${DEVICE_WITH_PARTITION}2 is formatted as exFAT..."
        # 'parted' does not support finding if a partition is exFAT formatted.
        # 'lsblk -f' does but that does not work inside of a container.
        # https://github.com/LukeShortCloud/winesapOS/issues/507
        echo "${parted_print}" | grep -P "^ 2 " | grep -q -P "GB\s+primary"
        if [ $? -eq 0 ]; then
            echo PASS
        else
            winesapos_test_failure
        fi

        echo -n "\t\tChecking that ${DEVICE_WITH_PARTITION}2 has the 'msftdata' partition flag..."
        parted ${DEVICE} print | grep -q msftdata
        if [ $? -eq 0 ]; then
            echo PASS
        else
            winesapos_test_failure
        fi
    fi

    if [[ "${WINESAPOS_ENABLE_PORTABLE_STORAGE}" == "true" ]]; then
        echo -n "\t\tChecking that ${DEVICE_WITH_PARTITION}3 is formatted as FAT32..."
        echo "${parted_print}" | grep -P "^ 3 " | grep -q fat
        if [ $? -eq 0 ]; then
            echo PASS
        else
            winesapos_test_failure
        fi
    else
        echo -n "\t\tChecking that ${DEVICE_WITH_PARTITION}2 is formatted as FAT32..."
        echo "${parted_print}" | grep -P "^ 2 " | grep -q fat
        if [ $? -eq 0 ]; then
            echo PASS
        else
            winesapos_test_failure
        fi
    fi

    if [[ "${WINESAPOS_ENABLE_PORTABLE_STORAGE}" == "true" ]]; then
        echo -n "\t\tChecking that ${DEVICE_WITH_PARTITION}4 is formatted as ext4..."
        echo "${parted_print}" | grep -P "^ 4 " | grep -q ext4
        if [ $? -eq 0 ]; then
            echo PASS
        else
            winesapos_test_failure
        fi
    else
        echo -n "\t\tChecking that ${DEVICE_WITH_PARTITION}3 is formatted as ext4..."
        echo "${parted_print}" | grep -P "^ 3 " | grep -q ext4
        if [ $? -eq 0 ]; then
            echo PASS
        else
            winesapos_test_failure
        fi
    fi

    if [[ "${WINESAPOS_ENABLE_PORTABLE_STORAGE}" == "true" ]]; then
        echo -n "\t\tChecking that ${DEVICE_WITH_PARTITION}5 is formatted as Btrfs..."
        if [[ "${WINESAPOS_ENCRYPT}" == "true" ]]; then
            parted /dev/mapper/cryptroot print | grep -q -P "^ 1 .*btrfs"
            if [ $? -eq 0 ]; then
                echo PASS
            else
                winesapos_test_failure
            fi
        else
            echo "${parted_print}" | grep -P "^ 5 " | grep -q btrfs
            if [ $? -eq 0 ]; then
                echo PASS
            else
                winesapos_test_failure
            fi
        fi
    else
        echo -n "\t\tChecking that ${DEVICE_WITH_PARTITION}4 is formatted as Btrfs..."
        if [[ "${WINESAPOS_ENCRYPT}" == "true" ]]; then
            parted /dev/mapper/cryptroot print | grep -q -P "^ 1 .*btrfs"
            if [ $? -eq 0 ]; then
                echo PASS
            else
                winesapos_test_failure
            fi
        else
            echo "${parted_print}" | grep -P "^ 4 " | grep -q btrfs
            if [ $? -eq 0 ]; then
                echo PASS
            else
                winesapos_test_failure
            fi
        fi
    fi

    echo -n "Checking that optimal IO schedulers are enabled..."
    grep -q kyber ${WINESAPOS_INSTALL_DIR}/etc/udev/rules.d/60-winesapos-io-schedulers.rules
    if [ $? -eq 0 ]; then
        echo PASS
    else
        winesapos_test_failure
    fi

    echo -n "Testing partitions complete.\n\n"

    echo "Testing /etc/fstab mounts..."

    echo "Debug output of fstab contents below..."
    cat ${WINESAPOS_INSTALL_DIR}/etc/fstab

    echo "\t\tChecking that each mount exists in /etc/fstab...\n"
    for i in \
      "^(\/dev\/mapper\/cryptroot|LABEL\=).*\s+/\s+btrfs\s+rw,noatime,nodiratime,compress-force=zstd:1,discard" \
      "^(\/dev\/mapper\/cryptroot|LABEL\=).*\s+/home\s+btrfs\s+rw,noatime,nodiratime,compress-force=zstd:1" \
      "^(\/dev\/mapper\/cryptroot|LABEL\=).*\s+/swap\s+btrfs\s+rw,noatime,nodiratime,compress-force=zstd:1" \
      "^(none|tmpfs)\s+/tmp\s+tmpfs\s+rw.*\s+0\s+0" \
      "^(none|tmpfs)\s+/var/log\s+tmpfs\s+rw.*\s+0\s+0" \
      "^(none|tmpfs)\s+/var/tmp\s+tmpfs\s+rw.*\s+0\s+0"
        do echo -n "\t\t${i}..."
        grep -q -P "${i}" ${WINESAPOS_INSTALL_DIR}/etc/fstab
        if [ $? -eq 0 ]; then
            echo PASS
        else
            winesapos_test_failure
        fi
    done

    fstab_efi="^LABEL\=.*\s+/boot/efi\s+vfat\s+rw"
    echo -n "\t\t${fstab_efi}..."
    grep -q -P "${fstab_efi}" ${WINESAPOS_INSTALL_DIR}/etc/fstab
    if [ $? -eq 0 ]; then
        echo PASS
    else
        winesapos_test_failure
    fi
    echo -n "Testing /etc/fstab mounts complete.\n\n"

    echo "Testing Btrfs subvolumes..."

    echo -n "\t\tChecking that the Btrfs subvolumes exist...\n"
    for i in \
      ".snapshots" \
      "home" \
      "home/\.snapshots" \
      "swap"
        do echo -n "\t\t${i}..."
        btrfs subvolume list ${WINESAPOS_INSTALL_DIR} | grep -q -P " ${i}$"
        if [ $? -eq 0 ]; then
            echo PASS
        else
            winesapos_test_failure
        fi
    done

    echo -n "Testing Btrfs subvolumes complete.\n\n"
fi

echo -n -e "\t\tChecking that the open file limits has been increased via systemd..."
grep -P -q "^DefaultLimitNOFILE=524288" ${WINESAPOS_INSTALL_DIR}/etc/systemd/system.conf.d/20-file-limits.conf
if [ $? -eq 0 ]; then
    echo PASS
else
    winesapos_test_failure
fi

echo "Testing user creation..."

echo -n "\t\tChecking that the 'winesap' user exists..."
grep -P -q "^${WINESAPOS_USER_NAME}:" ${WINESAPOS_INSTALL_DIR}/etc/passwd
if [ $? -eq 0 ]; then
    echo PASS
else
    winesapos_test_failure
fi

echo -n "\t\tChecking that the home directory for the 'winesap' user exists..."
if [ -d ${WINESAPOS_INSTALL_DIR}/home/${WINESAPOS_USER_NAME}/ ]; then
    echo PASS
else
    winesapos_test_failure
fi

echo -n "Testing user creation complete.\n\n"

echo "Testing package repositories..."

echo -n "\tChecking that the winesapOS repository was added..."
if [[ "${WINESAPOS_ENABLE_TESTING_REPO}" == "false" ]]; then
    grep -q -P "^\[winesapos\]" ${WINESAPOS_INSTALL_DIR}/etc/pacman.conf
    if [ $? -eq 0 ]; then
        echo PASS
    else
        winesapos_test_failure
    fi
else
    grep -q -P "^\[winesapos-testing\]" ${WINESAPOS_INSTALL_DIR}/etc/pacman.conf
    if [ $? -eq 0 ]; then
        echo PASS
    else
        winesapos_test_failure
    fi
fi

echo -n "\tChecking that the winesapOS GPG key was added..."
chroot ${WINESAPOS_INSTALL_DIR} pacman-key --list-keys | grep -q 1805E886BECCCEA99EDF55F081CA29E4A4B01239
if [ $? -eq 0 ]; then
    echo PASS
else
    winesapos_test_failure
fi

echo -n "\tChecking that the Chaotic AUR repository was added..."
grep -q -P "^\[chaotic-aur\]" ${WINESAPOS_INSTALL_DIR}/etc/pacman.conf
if [ $? -eq 0 ]; then
    echo PASS
else
    winesapos_test_failure
fi

echo -n "\tChecking that the Chaotic AUR GPG key was added..."
chroot ${WINESAPOS_INSTALL_DIR} pacman-key --list-keys | grep -q 3056513887B78AEB
if [ $? -eq 0 ]; then
    echo PASS
else
    winesapos_test_failure
fi

echo "Testing package repositories complete."

echo "Testing package installations..."

function pacman_search() {
    chroot ${WINESAPOS_INSTALL_DIR} pacman -Qsq ${1} &> /dev/null
}

function pacman_search_loop() {
    for i in ${@}
        do echo -n "\t${i}..."
        pacman_search "${i}"
        if [ $? -eq 0 ]; then
            echo PASS
        else
            winesapos_test_failure
        fi
    done
}

echo "\tChecking that the base system packages are installed..."
pacman_search_loop \
  accountsservice \
  arch-install-scripts \
  efibootmgr \
  flatpak \
  fprintd \
  fwupd \
  grub \
  inetutils \
  iwd \
  jq \
  mkinitcpio \
  networkmanager

if [[ "${WINESAPOS_BUILD_CHROOT_ONLY}" == "false" ]]; then
    echo "\tChecking that the Linux kernel packages are installed..."
    if [[ "${WINESAPOS_DISTRO_DETECTED}" == "manjaro" ]]; then
        pacman_search_loop linux-fsync-nobara-bin linux66 linux66-headers linux-firmware mkinitcpio-firmware amd-ucode intel-ucode apple-bcm-firmware
    elif [[ "${WINESAPOS_DISTRO}" == "arch" ]]; then
        pacman_search_loop linux-fsync-nobara-bin linux-lts linux-lts-headers linux-firmware mkinitcpio-firmware amd-ucode intel-ucode apple-bcm-firmware
    fi
fi

if [[ "${WINESAPOS_INSTALL_GAMING_TOOLS}" == "true" ]]; then
    echo "\tChecking that gaming tools are installed..."
    pacman_search_loop \
      gamemode \
      lib32-gamemode \
      gamescope \
      gamescope-session-git \
      gamescope-session-steam-git \
      goverlay-git \
      game-devices-udev \
      mangohud-git \
      lib32-mangohud-git \
      opengamepadui-bin \
      openrazer-daemon \
      oversteer \
      polychromatic \
      replay-sorcery-git \
      steam \
      steam-native-runtime \
      vkbasalt \
      lib32-vkbasalt \
      zenity \
      zerotier-one \
      zerotier-gui-git

    for i in \
      ${WINESAPOS_INSTALL_DIR}/home/${WINESAPOS_USER_NAME}/Desktop/EmuDeck.AppImage
        do echo -n "\t\tChecking if the file ${i} exists..."
        if [ -f "${i}" ]; then
          echo PASS
        else
          winesapos_test_failure
        fi
    done
fi

echo "\tChecking that the desktop environment packages are installed..."
pacman_search_loop \
  mesa \
  lib32-mesa \
  opencl-rusticl-mesa
  lib32-opencl-rusticl-mesa \
  sddm \
  vulkan-nouveau \
  xorg-server \
  xorg-server \
  xorg-xinit \
  xterm \
  xf86-input-libinput \
  xwayland-run-git

if [[ "${WINESAPOS_DE}" == "cinnamon" ]]; then
    pacman_search_loop \
      cinnamon \
      maui-pix \
      xorg-server \
      xed

    if [[ "${WINESAPOS_DISTRO_DETECTED}" == "manjaro" ]]; then
        pacman_search_loop \
            cinnamon-sounds \
            cinnamon-wallpapers \
            manjaro-cinnamon-settings \
            manjaro-settings-manager$ \
            adapta-maia-theme \
            kvantum-manjaro
    fi
elif [[ "${WINESAPOS_DE}" == "gnome" ]]; then
    pacman_search_loop \
      gnome \
      gnome-tweaks

    if [[ "${WINESAPOS_DISTRO_DETECTED}" == "manjaro" ]]; then
        pacman_search_loop \
          manjaro-gnome-settings \
	  manjaro-settings-manager
    fi
elif [[ "${WINESAPOS_DE}" == "plasma" ]]; then
    pacman_search_loop \
      plasma-meta \
      plasma-nm \
      dolphin \
      ffmpegthumbs \
      gwenview \
      kdegraphics-thumbnailers \
      konsole \
      kate \
      kdeconnect \
      kio

    if [[ "${WINESAPOS_DISTRO_DETECTED}" == "manjaro" ]]; then
        pacman_search_loop \
            manjaro-kde-settings \
            manjaro-settings-manager-knotifier \
            breath-wallpapers \
            plasma6-themes-breath \
            sddm-breath-theme
    fi

    echo -n "\tChecking that Plasma (Wayland) session is set as the default..."
    export wayland_session_file="plasma.desktop"
    if [[ "${WINESAPOS_DISTRO_DETECTED}" == "manjaro" ]]; then
        export wayland_session_file="plasmawayland.desktop"
    fi
    ls "${WINESAPOS_INSTALL_DIR}/usr/share/wayland-sessions/0${wayland_session_file}" &> /dev/null
    if [ $? -eq 0 ]; then
        echo PASS
    else
        winesapos_test_failure
    fi
fi

echo -n "\tChecking that SDDM will hide Nix build users..."
if [[ "$(chroot ${WINESAPOS_INSTALL_DIR} crudini --get /etc/sddm.conf.d/uid.conf Users MaximumUid)" == "2999" ]]; then
    echo PASS
else
    winesapos_test_failure
fi

echo "\tChecking that Bluetooth packages are installed..."
pacman_search_loop bluez bluez-utils blueman bluez-qt
echo "\tChecking that Bluetooth packages are installed complete."

echo -n "\tChecking that the 'bluetooth' service is enabled..."
chroot ${WINESAPOS_INSTALL_DIR} systemctl --quiet is-enabled bluetooth.service
if [ $? -eq 0 ]; then
    echo PASS
else
    winesapos_test_failure
fi

echo -n "Testing package installations complete.\n\n"

echo "Testing drivers installation..."
echo -e "\tChecking that the 'apple-bce' driver is loaded on boot..."
grep -P "^MODULES" ${WINESAPOS_INSTALL_DIR}/etc/mkinitcpio.conf | grep -q apple-bce
if [ $? -eq 0 ]; then
    echo PASS
else
    winesapos_test_failure
fi

echo -e "\tChecking that the 'apple-touchbar' driver will load automatically..."
grep -q "install apple-touchbar" ${WINESAPOS_INSTALL_DIR}/etc/modprobe.d/winesapos-mac.conf
if [ $? -eq 0 ]; then
    echo PASS
else
    winesapos_test_failure
fi

echo -n -e "\tChecking that USB modules will load automatically..."
grep -P "^MODULES" ${WINESAPOS_INSTALL_DIR}/etc/mkinitcpio.conf | grep -q "usbhid xhci_hcd"
if [ $? -eq 0 ]; then
    echo PASS
else
    winesapos_test_failure
fi

echo -n -e "\tChecking that the Intel VMD module will load automatically..."
grep -P "^MODULES" ${WINESAPOS_INSTALL_DIR}/etc/mkinitcpio.conf | grep -q "nvme vmd"
if [ $? -eq 0 ]; then
    echo PASS
else
    winesapos_test_failure
fi

echo -e "\tChecking that the 'radeon' driver will not load for specific older GPUs..."
grep -q "options radeon si_support=0" ${WINESAPOS_INSTALL_DIR}/etc/modprobe.d/winesapos-amd.conf
if [ $? -eq 0 ]; then
    echo PASS
else
    winesapos_test_failure
fi

echo -e "\tChecking that the AMDGPU workaround is configured..."
grep -q "options amdgpu noretry=0" ${WINESAPOS_INSTALL_DIR}/etc/modprobe.d/winesapos-amd.conf
if [ $? -eq 0 ]; then
    echo PASS
else
    winesapos_test_failure
fi

echo -e "\tChecking that 'linux-fsync-nobara-bin' is installed..."
pacman_search linux-fsync-nobara-bin
if [ $? -eq 0 ]; then
    echo PASS
else
    winesapos_test_failure
fi

echo -e "\tChecking that 'usbmuxd' is installed..."
pacman_search usbmuxd
if [ $? -eq 0 ]; then
    echo PASS
else
    winesapos_test_failure
fi

echo -n -e "\tChecking that newer udev rules for 'usbmuxd' are installed..."
grep -q "make sure iBridge (T1)" ${WINESAPOS_INSTALL_DIR}/usr/lib/udev/rules.d/39-usbmuxd.rules
if [ $? -eq 0 ]; then
    echo PASS
else
    winesapos_test_failure
fi

echo -n -e "\tChecking that udev rule for the Lenovo Legion Go is installed..."
grep -q "echo 17ef 6182" ${WINESAPOS_INSTALL_DIR}/usr/lib/udev/rules.d/50-lenovo-legion-controller.rules
if [ $? -eq 0 ]; then
    echo PASS
else
    winesapos_test_failure
fi

echo -n -e "\tChecking that Steam Deck OLED audio driver support is installed..."
pacman_search steamdeck-dsp
if [ $? -eq 0 ]; then
    echo PASS
else
    winesapos_test_failure
fi
echo -e "Testing drivers installation complete.\n\n"

echo "Testing that all files have been copied over..."

for i in \
  ${WINESAPOS_INSTALL_DIR}/etc/systemd/user/winesapos-mute.service \
  ${WINESAPOS_INSTALL_DIR}/usr/local/bin/winesapos-mute.sh \
  ${WINESAPOS_INSTALL_DIR}/usr/local/bin/winesapos-resize-root-file-system.sh \
  ${WINESAPOS_INSTALL_DIR}/usr/local/bin/winesapos-sddm-health-check.sh \
  ${WINESAPOS_INSTALL_DIR}/etc/systemd/system/winesapos-resize-root-file-system.service \
  ${WINESAPOS_INSTALL_DIR}/etc/systemd/system/winesapos-sddm-health-check.service \
  ${WINESAPOS_INSTALL_DIR}/etc/snapper/configs/root \
  ${WINESAPOS_INSTALL_DIR}/etc/snapper/configs/home \
  ${WINESAPOS_INSTALL_DIR}/usr/lib/os-release-winesapos \
  ${WINESAPOS_INSTALL_DIR}/var/winesapos/winesapos-install.log
    do echo -n "\t${i}..."
    if [ -f ${i} ]; then
        echo PASS
    else
        winesapos_test_failure
    fi
done

echo -n "\t${WINESAPOS_INSTALL_DIR}/etc/os-release-winesapos..."
if [[ -L ${WINESAPOS_INSTALL_DIR}/etc/os-release-winesapos ]]; then
    echo PASS
else
    winesapos_test_failure
fi

echo -n "Testing that all files have been copied over complete.\n\n"

echo "Testing that services are enabled..."

for i in \
  auto-cpufreq \
  cups \
  sddm \
  NetworkManager \
  winesapos-sddm-health-check \
  winesapos-resize-root-file-system \
  snapd \
  snapper-timeline.timer \
  systemd-timesyncd
    do echo -n "\t${i}..."
    chroot ${WINESAPOS_INSTALL_DIR} systemctl --quiet is-enabled ${i}
    if [ $? -eq 0 ]; then
        echo PASS
    else
        winesapos_test_failure
    fi
done

if [[ "${WINESAPOS_APPARMOR}" == "true" ]]; then
    echo -n "\tapparmor..."
    chroot ${WINESAPOS_INSTALL_DIR} systemctl --quiet is-enabled apparmor
    if [ $? -eq 0 ]; then
        echo PASS
    else
        winesapos_test_failure
    fi
fi

echo -n "Testing that services are enabled complete.\n\n"

if [[ "${WINESAPOS_BUILD_CHROOT_ONLY}" == "false" ]]; then
    echo "Testing the bootloader..."

    echo -n "\tChecking that GRUB 2 has been installed..."
    dd if=${DEVICE} bs=512 count=1 2> /dev/null | strings | grep -q GRUB
    if [ $? -eq 0 ]; then
        echo PASS
    else
        winesapos_test_failure
    fi

    echo -n "\tChecking that the '/boot/grub/grub.cfg' file exists..."
    if [ -f ${WINESAPOS_INSTALL_DIR}/boot/grub/grub.cfg ]; then
        echo PASS
    else
        winesapos_test_failure
    fi

    echo -n " \tChecking that the generic '/boot/efi/EFI/BOOT/BOOTX64.EFI' file exists..."
    if [ -f ${WINESAPOS_INSTALL_DIR}/boot/efi/EFI/BOOT/BOOTX64.EFI ]; then
        echo PASS
    else
        winesapos_test_failure
    fi

    echo -n "\tChecking that the GRUB terminal is set to 'console'..."
    grep -q "terminal_input console" ${WINESAPOS_INSTALL_DIR}/boot/grub/grub.cfg
    if [ $? -eq 0 ]; then
        echo PASS
    else
        winesapos_test_failure
    fi

    echo -n "\tChecking that the GRUB timeout has been set to 10 seconds..."
    grep -q "set timeout=10" ${WINESAPOS_INSTALL_DIR}/boot/grub/grub.cfg
    if [ $? -eq 0 ]; then
        echo PASS
    else
        winesapos_test_failure
    fi

    echo -n "\tChecking that the GRUB timeout style been set to 'menu'..."
    grep -q "set timeout_style=menu" ${WINESAPOS_INSTALL_DIR}/boot/grub/grub.cfg
    if [ $? -eq 0 ]; then
        echo PASS
    else
        winesapos_test_failure
    fi

    echo "\tChecking that GRUB has command line arguments for faster input device polling..."
    for i in usbhid.jspoll=1 usbhid.kbpoll=1 usbhid.mousepoll=1
        do echo -n "\t${i}..."
        grep -q "${i}" ${WINESAPOS_INSTALL_DIR}/boot/grub/grub.cfg
        if [ $? -eq 0 ]; then
            echo PASS
        else
            winesapos_test_failure
        fi
    done
    echo "\tChecking that GRUB has command line arguments for faster input device polling complete."

    echo -n "\tChecking that GRUB has the command line argument to enable NVMe support..."
    grep -q "nvme_load=yes" ${WINESAPOS_INSTALL_DIR}/boot/grub/grub.cfg
    if [ $? -eq 0 ]; then
        echo PASS
    else
        winesapos_test_failure
    fi

    echo -n "\tChecking that GRUB enables S3 deep sleep support..."
    grep -q "mem_sleep_default=deep" ${WINESAPOS_INSTALL_DIR}/boot/grub/grub.cfg
    if [ $? -eq 0 ]; then
        echo PASS
    else
        winesapos_test_failure
    fi

    echo -n "\tChecking that GRUB will use partition UUIDs instead of Linux UUIDs..."
    grep -q -P "^GRUB_DISABLE_LINUX_UUID=true" ${WINESAPOS_INSTALL_DIR}/etc/default/grub
    if [ $? -eq 0 ]; then
        grep -q -P "^GRUB_DISABLE_LINUX_PARTUUID=false" ${WINESAPOS_INSTALL_DIR}/etc/default/grub
        if [ $? -eq 0 ]; then
            echo PASS
        else
            winesapos_test_failure
        fi
    else
        winesapos_test_failure
    fi

    echo -n "\tChecking that GRUB will automatically boot into the correct kernel..."
    export GRUB_DEFAULT="1"
    if [[ "${WINESAPOS_DISTRO}" == "manjaro" ]]; then
        export GRUB_DEFAULT="0"
    fi
    grep -q -P "^GRUB_DEFAULT=${GRUB_DEFAULT}" ${WINESAPOS_INSTALL_DIR}/etc/default/grub
    if [ $? -eq 0 ]; then
        echo PASS
    else
        winesapos_test_failure
    fi

    echo -n "\tChecking that there are no fallback initramfs images..."
    ls -1 ${WINESAPOS_INSTALL_DIR}/boot | grep -q "-fallback.img"
    if [ $? -ne 0 ]; then
        echo PASS
    else
        winesapos_test_failure
    fi

    echo -n "\tChecking that the Vimix theme for GRUB exists..."
    if [ -f ${WINESAPOS_INSTALL_DIR}/boot/grub/themes/Vimix/theme.txt ]; then
        echo PASS
    else
        winesapos_test_failure
    fi

    echo -n "\tChecking that the Vimix theme for GRUB is enabled..."
    grep -q -P "^GRUB_THEME=/boot/grub/themes/Vimix/theme.txt" ${WINESAPOS_INSTALL_DIR}/etc/default/grub
    if [ $? -eq 0 ]; then
        echo PASS
    else
        winesapos_test_failure
    fi

    echo -n "\tChecking that GRUB is set to use resolutions supported by our theme..."
    grep -q -P "^GRUB_GFXMODE=1280x720,auto" ${WINESAPOS_INSTALL_DIR}/etc/default/grub
    if [ $? -eq 0 ]; then
        echo PASS
    else
        winesapos_test_failure
    fi

    echo -n "\tChecking that GRUB is set to use the text GFX payload for better boot compatibility..."
    grep -q -P "^GRUB_GFXPAYLOAD_LINUX=text" ${WINESAPOS_INSTALL_DIR}/etc/default/grub
    if [ $? -eq 0 ]; then
        echo PASS
    else
        winesapos_test_failure
    fi

    echo -n "\tChecking that GRUB is set to use winesapOS naming..."
    grep -q -P "^GRUB_DISTRIBUTOR=winesapOS" ${WINESAPOS_INSTALL_DIR}/etc/default/grub
    if [ $? -eq 0 ]; then
        echo PASS
    else
        winesapos_test_failure
    fi

    if [[ "${WINESAPOS_BUILD_CHROOT_ONLY}" == "false" ]]; then
        echo -n "\tChecking that GRUB Btrfs snapshots are set to use winesapOS naming..."
        grep -q -P "^GRUB_BTRFS_SUBMENUNAME=\"winesapOS snapshots\"" ${WINESAPOS_INSTALL_DIR}/etc/default/grub-btrfs/config
        if [ $? -eq 0 ]; then
            echo PASS
        else
            winesapos_test_failure
        fi
    fi
    echo "Testing the bootloader complete."
fi

echo "Testing that 'yay' is installed..."
echo -n "\tChecking for the 'yay' binary..."
if [ -f ${WINESAPOS_INSTALL_DIR}/usr/bin/yay ]; then
    echo PASS
else
    winesapos_test_failure
fi

echo "\tChecking that the 'yay' package is installed..."
pacman_search_loop yay
echo "\tChecking that the 'yay' package is installed complete."

echo "Testing that 'yay' is complete..."

echo "Testing desktop shortcuts..."
for i in \
  ${WINESAPOS_INSTALL_DIR}/home/${WINESAPOS_USER_NAME}/Desktop/appimagepool.desktop \
  ${WINESAPOS_INSTALL_DIR}/home/${WINESAPOS_USER_NAME}/Desktop/bauh.desktop \
  ${WINESAPOS_INSTALL_DIR}/home/${WINESAPOS_USER_NAME}/Desktop/blueman-manager.desktop \
  ${WINESAPOS_INSTALL_DIR}/home/${WINESAPOS_USER_NAME}/Desktop/firefox-esr.desktop \
  ${WINESAPOS_INSTALL_DIR}/home/${WINESAPOS_USER_NAME}/Desktop/terminator.desktop
    do echo -n "\t\tChecking if the file ${i} exists..."
    if [ -f "${i}" ]; then
      echo PASS
    else
      winesapos_test_failure
    fi
done

if [[ "${WINESAPOS_INSTALL_GAMING_TOOLS}" == "true" ]]; then

    for i in \
      ${WINESAPOS_INSTALL_DIR}/home/${WINESAPOS_USER_NAME}/Desktop/decky_installer.desktop \
      ${WINESAPOS_INSTALL_DIR}/home/${WINESAPOS_USER_NAME}/Desktop/io.github.benjamimgois.goverlay.desktop \
      ${WINESAPOS_INSTALL_DIR}/home/${WINESAPOS_USER_NAME}/Desktop/com.github.mtkennerly.ludusavi.desktop \
      ${WINESAPOS_INSTALL_DIR}/home/${WINESAPOS_USER_NAME}/Desktop/org.berarma.Oversteer.desktop \
      ${WINESAPOS_INSTALL_DIR}/home/${WINESAPOS_USER_NAME}/Desktop/polychromatic.desktop \
      ${WINESAPOS_INSTALL_DIR}/home/${WINESAPOS_USER_NAME}/Desktop/steam.desktop \
      ${WINESAPOS_INSTALL_DIR}/home/${WINESAPOS_USER_NAME}/Desktop/steamtinkerlaunch.desktop \
      ${WINESAPOS_INSTALL_DIR}/home/${WINESAPOS_USER_NAME}/Desktop/zerotier-gui.desktop
        do echo -n "\t\tChecking if the file ${i} exists..."
        if [ -f "${i}" ]; then
          echo PASS
        else
          winesapos_test_failure
        fi
    done

fi

if [[ "${WINESAPOS_INSTALL_PRODUCTIVITY_TOOLS}" == "true" ]]; then
    for i in \
      ${WINESAPOS_INSTALL_DIR}/home/${WINESAPOS_USER_NAME}/Desktop/balenaEtcher.AppImage \
      ${WINESAPOS_INSTALL_DIR}/home/${WINESAPOS_USER_NAME}/Desktop/clamtk.desktop \
      ${WINESAPOS_INSTALL_DIR}/home/${WINESAPOS_USER_NAME}/Desktop/org.coolercontrol.CoolerControl.desktop \
      ${WINESAPOS_INSTALL_DIR}/home/${WINESAPOS_USER_NAME}/Desktop/gparted.desktop \
      ${WINESAPOS_INSTALL_DIR}/home/${WINESAPOS_USER_NAME}/Desktop/qdirstat.desktop \
      ${WINESAPOS_INSTALL_DIR}/home/${WINESAPOS_USER_NAME}/Desktop/org.kde.spectacle.desktop \
      ${WINESAPOS_INSTALL_DIR}/home/${WINESAPOS_USER_NAME}/Desktop/veracrypt.desktop
        do echo -n "\t\tChecking if the file ${i} exists..."
        if [ -f "${i}" ]; then
          echo PASS
        else
          winesapos_test_failure
        fi
    done
fi

if [[ "${WINESAPOS_FIREWALL}" == "true" ]]; then
    i="${WINESAPOS_INSTALL_DIR}/home/${WINESAPOS_USER_NAME}/Desktop/firewall-config.desktop"
    echo -n "\t\tChecking if the file ${i} exists..."
    if [ -f "${i}" ]; then
        echo PASS
    else
        winesapos_test_failure
    fi
fi

if [[ "${WINESAPOS_DE}" == "cinnamon" ]]; then
    x=("${WINESAPOS_INSTALL_DIR}/home/${WINESAPOS_USER_NAME}/Desktop/nemo.desktop" "${WINESAPOS_INSTALL_DIR}/home/${WINESAPOS_USER_NAME}/Desktop/org.kde.pix.desktop")
elif [[ "${WINESAPOS_DE}" == "gnome" ]]; then
    x=("${WINESAPOS_INSTALL_DIR}/home/${WINESAPOS_USER_NAME}/Desktop/org.gnome.eog.desktop" "${WINESAPOS_INSTALL_DIR}/home/${WINESAPOS_USER_NAME}/Desktop/org.gnome.Nautilus.desktop")
elif [[ "${WINESAPOS_DE}" == "plasma" ]]; then
    x=("${WINESAPOS_INSTALL_DIR}/home/${WINESAPOS_USER_NAME}/Desktop/org.kde.dolphin.desktop" "${WINESAPOS_INSTALL_DIR}/home/${WINESAPOS_USER_NAME}/Desktop/org.kde.gwenview.desktop")
fi

for y in $x;
    do echo -n "\t\tChecking if the file ${y} exists..."
    if [ -f "${y}" ]; then
        echo PASS
    else
        winesapos_test_failure
    fi
done
echo "Testing desktop shortcuts complete."

echo -n "Testing that Oh My Zsh is installed..."
if [ -f ${WINESAPOS_INSTALL_DIR}/home/${WINESAPOS_USER_NAME}/.zshrc ]; then
    echo PASS
else
    winesapos_test_failure
fi
echo "Testing that Oh My Zsh is installed complete."

echo -n "Testing that the mkinitcpio hooks are loaded in the correct order..."
if [[ "${WINESAPOS_ENCRYPT}" == "true" ]]; then
    grep -q "HOOKS=(base microcode udev block keyboard keymap modconf encrypt filesystems fsck)" ${WINESAPOS_INSTALL_DIR}/etc/mkinitcpio.conf
    hooks_result="$?"
else
    grep -q "HOOKS=(base microcode udev block keyboard modconf filesystems fsck)" ${WINESAPOS_INSTALL_DIR}/etc/mkinitcpio.conf
    hooks_result="$?"
fi
if [ "${hooks_result}" -eq 0 ]; then
     echo PASS
 else
     winesapos_test_failure
 fi
echo "Testing that the mkinitcpio hooks are loaded in the correct order complete."

echo -n "Testing that ParallelDownloads is enabled in Pacman..."
grep -q -P "^ParallelDownloads" ${WINESAPOS_INSTALL_DIR}/etc/pacman.conf
if [ $? -eq 0 ]; then
    echo PASS
else
    winesapos_test_failure
fi
echo "Testing that ParallelDownloads is enabled in Pacman complete."

#echo -n "Testing that Pacman is configured to use 'curl'..."
#grep -q 'XferCommand = /usr/bin/curl --connect-timeout 60 --retry 10 --retry-delay 5 -L -C - -f -o %o %u' ${WINESAPOS_INSTALL_DIR}/etc/pacman.conf
#if [ $? -eq 0 ]; then
#    echo PASS
#else
#    winesapos_test_failure
#fi

echo "Testing that the machine-id was reset..."
echo -n "\t\tChecking that the /etc/machine-id file is empty..."
if [[ "$(cat ${WINESAPOS_INSTALL_DIR}/etc/machine-id)" == "" ]]; then
    echo PASS
else
    winesapos_test_failure
fi
echo -n "\t\tChecking that /var/lib/dbus/machine-id is a symlink..."
if [[ -L ${WINESAPOS_INSTALL_DIR}/var/lib/dbus/machine-id ]]; then
    echo PASS
else
    winesapos_test_failure
fi
echo "Testing that the machine-id was reset complete."

if [[ "${WINESAPOS_INSTALL_PRODUCTIVITY_TOOLS}" == "true" ]]; then
    echo "Testing that the offline ClamAV databases were downloaded..."
    for i in bytecode daily main; do
        echo -n "\t${i}..."
        if [[ -f ${WINESAPOS_INSTALL_DIR}/var/lib/clamav/${i}.cvd ]]; then
            echo PASS
        else
            if [[ -f ${WINESAPOS_INSTALL_DIR}/var/lib/clamav/${i}.cld ]]; then
                echo PASS
            else
                winesapos_test_failure
            fi
        fi
    done
    echo "Testing that the offline ClamAV databases were downloaded complete."
fi

if [[ "${WINESAPOS_FIREWALL}" == "true" ]]; then
    echo -n "Testing that the firewall has been installed..."
    if [[ -f ${WINESAPOS_INSTALL_DIR}/usr/bin/firewalld ]]; then
        echo PASS
    else
        winesapos_test_failure
    fi
fi

WINESAPOS_CPU_MITIGATIONS="${WINESAPOS_CPU_MITIGATIONS:-false}"
if [[ "${WINESAPOS_CPU_MITIGATIONS}" == "false" ]]; then
    echo -n "Testing that CPU mitigations are disabled in the Linux kernel..."
    grep -q "mitigations=off" ${WINESAPOS_INSTALL_DIR}/etc/default/grub
    if [ $? -eq 0 ]; then
        echo PASS
    else
        winesapos_test_failure
    fi
fi

WINESAPOS_DISABLE_KERNEL_UPDATES="${WINESAPOS_DISABLE_KERNEL_UPDATES:-true}"
if [[ "${WINESAPOS_DISABLE_KERNEL_UPDATES}" == "true" ]]; then
    echo -n "Testing that Pacman is configured to disable Linux kernel updates..."
    if [[ "${WINESAPOS_DISTRO}" == "manjaro" ]]; then
        grep -q "IgnorePkg = linux66 linux66-headers linux-fsync-nobara-bin filesystem" ${WINESAPOS_INSTALL_DIR}/etc/pacman.conf
        if [ $? -eq 0 ]; then
            echo PASS
        else
            winesapos_test_failure
        fi
    elif [[ "${WINESAPOS_DISTRO}" == "arch" ]]; then
        grep -q "IgnorePkg = linux-lts linux-lts-headers linux-fsync-nobara-bin filesystem" ${WINESAPOS_INSTALL_DIR}/etc/pacman.conf
        if [ $? -eq 0 ]; then
            echo PASS
        else
            winesapos_test_failure
        fi
    fi
fi

echo -n '\tChecking that the locale has been set...'
chroot ${WINESAPOS_INSTALL_DIR} locale --all-locales | grep -i "en_US.utf8"
if [ $? -eq 0 ]; then
    echo PASS
else
    winesapos_test_failure
fi

echo -n "\tChecking that the hostname is set..."
grep -q -P "^winesapos$" ${WINESAPOS_INSTALL_DIR}/etc/hostname
if [ $? -eq 0 ]; then
    echo PASS
else
    winesapos_test_failure
fi

echo -n "\tChecking that the hosts file is configured..."
grep -q -P "^127.0.1.1    winesapos$" ${WINESAPOS_INSTALL_DIR}/etc/hosts
if [ $? -eq 0 ]; then
    echo PASS
else
    winesapos_test_failure
fi

echo "\tChecking that all the packages from the AUR have been installed by yay..."
pacman_search_loop \
    appimagelauncher \
    appimagepool-appimage \
    auto-cpufreq \
    aw87559-firmware \
    ayaneo-platform-dkms-git \
    bauh \
    cloud-guest-utils \
    crudini \
    firefox-esr \
    hfsprogs \
    mbpfan-git \
    oh-my-zsh-git \
    oxp-sensors-dkms-git \
    pacman-static \
    paru \
    python-iniparse-git \
    python-tests \
    snapd

if [[ "${WINESAPOS_INSTALL_PRODUCTIVITY_TOOLS}" == "true" ]]; then
    pacman_search_loop \
      clamav \
      distrobox \
      qdirstat
fi

if [[ "${WINESAPOS_DISTRO_DETECTED}" != "manjaro" ]]; then
    pacman_search_loop \
      zsh
else
    pacman_search_loop \
      zsh
fi

if [[ "${WINESAPOS_APPARMOR}" == "true" ]]; then
    pacman_search_loop \
      apparmor \
      krathalans-apparmor-profiles-git
fi
echo "\tChecking that all the packages from the AUR have been installed by yay done."

echo 'Testing that the PipeWire audio library is installed...'
echo "\tChecking that PipeWire packages are installed..."
pacman_search_loop \
  pavucontrol \
  libpipewire \
  lib32-libpipewire \
  pipewire-alsa \
  pipewire-jack \
  lib32-pipewire-jack \
  pipewire-pulse \
  pipewire-v4l2 \
  lib32-pipewire-v4l2 \
  wireplumber
echo "\tChecking that PipeWire packages are installed complete."

echo "\tChecking that PipeWire services are enabled..."
for i in \
  winesapos-mute.service \
  pipewire.service \
  pipewire-pulse.service
    do echo -n "\t${i}..."
    ls "${WINESAPOS_INSTALL_DIR}/home/${WINESAPOS_USER_NAME}/.config/systemd/user/default.target.wants/${i}" &> /dev/null
    if [ $? -eq 0 ]; then
        echo PASS
    else
        winesapos_test_failure
    fi
done
echo "\tChecking that PipeWire services are enabled complete."
echo 'Testing that the PipeWire audio library is installed complete.'

echo 'Testing that support for all file systems is installed...'
pacman_search_loop \
  apfsprogs-git \
  bcachefs-tools \
  btrfs-progs \
  ceph-bin \
  cifs-utils \
  dosfstools \
  e2fsprogs \
  ecryptfs-utils \
  erofs-utils \
  exfatprogs \
  f2fs-tools \
  fatx \
  gfs2-utils \
  glusterfs \
  hfsprogs \
  jfsutils \
  linux-apfs-rw-dkms-git \
  minio \
  mtools \
  nfs-utils \
  nilfs-utils \
  ntfs-3g \
  reiserfsprogs \
  reiserfs-defrag \
  squashfs-tools \
  ssdfs-tools \
  sshfs \
  udftools \
  xfsprogs \
  zfs-dkms \
  zfs-utils

echo -n "\tChecking for the existence of '/etc/modules-load.d/winesapos-file-systems.conf'..."
ls ${WINESAPOS_INSTALL_DIR}/etc/modules-load.d/winesapos-file-systems.conf &> /dev/null
if [ $? -eq 0 ]; then
    echo PASS
else
    winesapos_test_failure
fi

echo -n "\tChecking the Snapper root configuration is configured to not take timeline snapshots..."
grep -q -P "^TIMELINE_CREATE=\"no\"" ${WINESAPOS_INSTALL_DIR}/etc/snapper/configs/root
if [ $? -eq 0 ]; then
    echo PASS
else
    winesapos_test_failure
fi

echo -n "\tChecking the Snapper home configuration is configured to use the correct subvolume..."
grep -q -P "^SUBVOLUME=\"/home\"" ${WINESAPOS_INSTALL_DIR}/etc/snapper/configs/home
if [ $? -eq 0 ]; then
    echo PASS
else
    winesapos_test_failure
fi
echo 'Testing that support for all file systems is installed complete.'

echo -n "\tChecking that the correct operating system was installed..."
grep -q "ID=${WINESAPOS_DISTRO}" ${WINESAPOS_INSTALL_DIR}/usr/lib/os-release
if [ $? -eq 0 ]; then
    echo PASS
else
    winesapos_test_failure
fi

echo -n "\tChecking that the OS variant has been set correctly..."
grep -q -P "^VARIANT_ID=(minimal|performance|secure)" ${WINESAPOS_INSTALL_DIR}/usr/lib/os-release-winesapos
if [ $? -eq 0 ]; then
    echo PASS
else
    winesapos_test_failure
fi

echo -n "\tChecking that the sudoers file for 'winesap' is correctly configured..."
if [[ "${WINESAPOS_SUDO_NO_PASSWORD}" == "true" ]]; then
    grep -q "${WINESAPOS_USER_NAME} ALL=(root) NOPASSWD:ALL" ${WINESAPOS_INSTALL_DIR}/etc/sudoers.d/${WINESAPOS_USER_NAME}
    if [ $? -eq 0 ]; then
        echo PASS
    else
        winesapos_test_failure
    fi
elif [[ "${WINESAPOS_SUDO_NO_PASSWORD}" == "false" ]]; then
    grep -q "${WINESAPOS_USER_NAME} ALL=(root) ALL" ${WINESAPOS_INSTALL_DIR}/etc/sudoers.d/${WINESAPOS_USER_NAME}
    if [ $? -eq 0 ]; then
        grep -q "${WINESAPOS_USER_NAME} ALL=(root) NOPASSWD: /usr/bin/dmidecode" ${WINESAPOS_INSTALL_DIR}/etc/sudoers.d/${WINESAPOS_USER_NAME}
        if [ $? -eq 0 ]; then
            echo PASS
        else
            winesapos_test_failure
        fi
    else
        winesapos_test_failure
    fi
fi

echo -n "\tChecking that the sudo timeout has been increased..."
grep -q "Defaults:${WINESAPOS_USER_NAME} passwd_tries=20,timestamp_timeout=-1" ${WINESAPOS_INSTALL_DIR}/etc/sudoers.d/${WINESAPOS_USER_NAME}
if [ $? -eq 0 ]; then
    echo PASS
else
    winesapos_test_failure
fi

echo "Testing that winesapOS desktop applications exist..."
for i in \
  /home/${WINESAPOS_USER_NAME}/.winesapos/winesapos-dual-boot.desktop \
  /home/${WINESAPOS_USER_NAME}/Desktop/winesapos-dual-boot.desktop \
  /usr/local/bin//winesapos-dual-boot.sh \
  /home/${WINESAPOS_USER_NAME}/.winesapos/winesapos-setup.sh \
  /home/${WINESAPOS_USER_NAME}/.winesapos/winesapos-setup.desktop \
  /home/${WINESAPOS_USER_NAME}/.config/autostart/winesapos-setup.desktop \
  /home/${WINESAPOS_USER_NAME}/Desktop/winesapos-setup.desktop \
  /home/${WINESAPOS_USER_NAME}/.winesapos/winesapos-upgrade-remote-stable.sh \
  /home/${WINESAPOS_USER_NAME}/.winesapos/winesapos-upgrade.desktop \
  /home/${WINESAPOS_USER_NAME}/Desktop/winesapos-upgrade.desktop \
  /home/${WINESAPOS_USER_NAME}/.winesapos/winesapos_logo_icon.png \
  /usr/share/sddm/faces/${WINESAPOS_USER_NAME}.face.icon;
    do echo -n "\t${i}..."
    ls "${WINESAPOS_INSTALL_DIR}${i}" &> /dev/null
    if [ $? -eq 0 ]; then
        echo PASS
    else
        winesapos_test_failure
    fi
done
echo "Testing that winesapOS desktop applications exist complete."

if [[ "${WINESAPOS_ENABLE_KLIPPER}" == "false" ]]; then
    echo "Testing that Klipper has been disabled..."
    echo "\tChecking that Klipper settings are configured..."
    for i in "KeepClipboardContents = false" "MaxClipItems = 1" "PreventEmptyClipboard = false";
	do echo -n -e "\t${i}..."
	grep -q -P "^${i}" ${WINESAPOS_INSTALL_DIR}/home/${WINESAPOS_USER_NAME}/.config/klipperrc
        if [ $? -eq 0 ]; then
            echo PASS
        else
            winesapos_test_failure
        fi
    done
    echo -n "\tChecking that the Klipper directory is mounted as a RAM file system..."
    grep -q "ramfs    /home/${WINESAPOS_USER_NAME}/.local/share/klipper    ramfs    rw,nosuid,nodev    0 0" ${WINESAPOS_INSTALL_DIR}/etc/fstab
    if [ $? -eq 0 ]; then
        echo PASS
    else
        winesapos_test_failure
    fi
    echo "Testing that Klipper has been disabled complete."
fi

echo "Checking that the default text editor has been set..."
grep -q "EDITOR=nano" ${WINESAPOS_INSTALL_DIR}/etc/environment
if [ $? -eq 0 ]; then
    echo PASS
else
    winesapos_test_failure
fi
echo "Checking that the default text editor has been set complete."

echo -n "Checking that NetworkManager is using IWD as the backend..."
grep -q "wifi.backend=iwd" ${WINESAPOS_INSTALL_DIR}/etc/NetworkManager/conf.d/wifi_backend.conf
if [ $? -eq 0 ]; then
    echo PASS
else
    winesapos_test_failure
fi

echo -n "Checking that IPv4 network traffic is prioritized over IPv6..."
grep -q "precedence ::ffff:0:0/96  100" ${WINESAPOS_INSTALL_DIR}/etc/gai.conf
if [ $? -eq 0 ]; then
    echo PASS
else
    winesapos_test_failure
fi

echo "Checking that the ${WINESAPOS_USER_NAME} user name has been set in desktop shortcuts for the setup and upgrade..."
for i in winesapos-setup.desktop winesapos-upgrade.desktop;
    do echo -n -e "\t${i}..."
    grep -q "/home/${WINESAPOS_USER_NAME}" ${WINESAPOS_INSTALL_DIR}/home/${WINESAPOS_USER_NAME}/.winesapos/${i}
    if [ $? -eq 0 ]; then
        echo PASS
    else
        winesapos_test_failure
    fi
done
echo "Checking that the ${WINESAPOS_USER_NAME} user name has been set in desktop shortcuts for the setup and upgrade done."

echo "Checking that the proprietary Broadcom Wi-Fi drivers are available for offline use..."
ls -1 ${WINESAPOS_INSTALL_DIR}/var/lib/winesapos/ | grep -q broadcom-wl-dkms
if [ $? -eq 0 ]; then
    echo PASS
else
    winesapos_test_failure
fi
echo "Checking that the proprietary Broadcom Wi-Fi drivers are available for offline use complete."

echo "Checking that a symlink was created for the 'deck' usesr for compatibility purposes..."
ls -lah ${WINESAPOS_INSTALL_DIR}/home/deck | grep -P "^lrwx"
if [ $? -eq 0 ]; then
    echo PASS
else
    winesapos_test_failure
fi
echo "Checking that a symlink was created for the 'deck' usesr for compatibility purposes complete."

echo -n "Checking that /snap is a symlink..."
if [[ -L ${WINESAPOS_INSTALL_DIR}/snap ]]; then
    echo PASS
else
    winesapos_test_failure
fi

echo "Tests end time: $(date)"

if (( ${failed_tests} == 0 )); then
    exit 0
else
    exit ${failed_tests}
fi
