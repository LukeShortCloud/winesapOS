#!/bin/bash

WINESAPOS_IMAGE_TYPE="$(grep VARIANT_ID /usr/lib/os-release-winesapos | cut -d = -f 2)"

# The secure image requires that the "sudo" password be provided for the "winesap" user.
# This password is also required to be reset during the first login so it is unknown.
# Prompt the user to enter in their password.
# On other image types, they do not require a password to run "sudo" commands so using
# the command "sudo -S" to read the password from standard input still works as expected.
if [[ "${WINESAPOS_IMAGE_TYPE}" == "secure" ]]; then
    while true;
        do user_pw=$(kdialog --title "winesapOS First-Time Setup" --password 'Please enter your password (default: "winesap") to start the first-time setup.')
        echo ${user_pw} | sudo -S whoami
        if [ $? -eq 0 ]; then
            # Break out of the "while" loop if the password works with the "sudo -S" command.
            break 2
        fi
    done
fi

# Enable shell debugging.
set -x
START_TIME=$(date --iso-8601=seconds)
exec > >(sudo tee /var/winesapos/setup_${START_TIME}.log) 2>&1
echo "Start time: ${START_TIME}"

current_shell=$(cat /proc/$$/comm)
if [[ "${current_shell}" != "bash" ]]; then
    echo "winesapOS scripts require Bash but ${current_shell} detected. Exiting..."
    exit 1
fi

CMD_PACMAN_INSTALL=(/usr/bin/pacman --noconfirm -S --needed)
CMD_YAY_INSTALL=(yay --noconfirm -S --removemake)
CMD_FLATPAK_INSTALL=(flatpak install -y --noninteractive)

export WINESAPOS_USER_NAME="${USER}"

# KDE Plasma 5 uses "qdbus" and 6 uses "qdbus6".
qdbus_cmd=""
if [ -e /usr/bin/qdbus ]; then
    qdbus_cmd="qdbus"
elif [ -e /usr/bin/qdbus6 ]; then
    qdbus_cmd="qdbus6"
else
    echo "No 'qdbus' command found. Progress bars will not work."
fi

# Enable Btrfs quotas for Snapper.
# Snapper does not work during the winesapOS build so this needs to happen during the first-time setup.
sudo snapper -c root setup-quota
sudo snapper -c home setup-quota
sudo btrfs qgroup limit 50G /.snapshots
sudo btrfs qgroup limit 50G /home/.snapshots

pacman -Q broadcom-wl-dkms
if [ $? -ne 0 ]; then
    kdialog --title "winesapOS First-Time Setup" --yesno "Do you want to install the Broadcom proprietary Wi-Fi driver? Try this if Wi-Fi is not working. A reboot is required when done."
    if [ $? -eq 0 ]; then
        kdialog_dbus=$(kdialog --title "winesapOS First-Time Setup" --progressbar "Please wait for Broadcom proprietary Wi-Fi drivers to be installed..." 3 | cut -d" " -f1)
        ${qdbus_cmd} ${kdialog_dbus} /ProgressDialog Set org.kde.kdialog.ProgressDialog value 1
        # Blacklist drives that are known to cause conflicts with the official Broadcom 'wl' driver.
        echo -e "\nblacklist b43\nblacklist b43legacy\nblacklist bcm43xx\nblacklist bcma\nblacklist brcm80211\nblacklist brcmsmac\nblacklist brcmfmac\nblacklist brcmutil\nblacklist ndiswrapper\nblacklist ssb\nblacklist tg3\n" | sudo tee /etc/modprobe.d/winesapos.conf
        broadcom_wl_dkms_pkg=$(ls -1 /var/lib/winesapos/ | grep broadcom-wl-dkms | grep -P "zst$")
        sudo pacman -U --noconfirm /var/lib/winesapos/${broadcom_wl_dkms_pkg}
        ${qdbus_cmd} ${kdialog_dbus} /ProgressDialog Set org.kde.kdialog.ProgressDialog value 2
        echo "wl" | sudo tee -a /etc/modules-load.d/winesapos-wifi.conf
        sudo mkinitcpio -P
        ${qdbus_cmd} ${kdialog_dbus} /ProgressDialog org.kde.kdialog.ProgressDialog.close
    fi
fi

# "Jupiter" is the code name for the Steam Deck.
sudo dmidecode -s system-product-name | grep -P ^Jupiter
if [ $? -eq 0 ]; then
    echo "Steam Deck hardware detected."
    # Rotate the desktop temporarily.
    export embedded_display_port=$(xrandr | grep eDP | grep " connected" | cut -d" " -f1)
    xrandr --output ${embedded_display_port} --rotate right
    # Rotate the desktop permanently.
    echo "xrandr --output ${embedded_display_port} --rotate right" | sudo tee /etc/profile.d/xrandr.sh
    # Rotate GRUB.
    sudo sed -i s'/GRUB_GFXMODE=.*/GRUB_GFXMODE=720x1280,auto/'g /etc/default/grub
    # Rotate the initramfs output.
    sudo sed -i s'/GRUB_CMDLINE_LINUX="/GRUB_CMDLINE_LINUX="fbcon:rotate=1 /'g /etc/default/grub
else
    echo "No Steam Deck hardware detected."
    kdialog --title "winesapOS First-Time Setup" --yesno "Do you want to rotate the screen (for devices that have a tablet screen)?"
    if [ $? -eq 0 ]; then
        rotation_selected=$(kdialog --title "winesapOS First-Time Setup" --menu "Select the desired screen orientation..." right "90 degrees right (clockwise)" left "90 degrees left (counter-clockwise)" inverted "180 degrees inverted (upside-down)")
        export fbcon_rotate=0
        if [[ "${rotation_selected}" == "right" ]]; then
            export fbcon_rotate=1
            sudo sed -i s'/GRUB_GFXMODE=.*/GRUB_GFXMODE=720x1280,auto/'g /etc/default/grub
        elif [[ "${rotation_selected}" == "left" ]]; then
            export fbcon_rotate=3
            sudo sed -i s'/GRUB_GFXMODE=.*/GRUB_GFXMODE=720x1280,auto/'g /etc/default/grub
        elif [[ "${rotation_selected}" == "inverted" ]]; then
            export fbcon_rotate=2
        fi
        # Rotate the TTY output.
        sudo -E sed -i s"/GRUB_CMDLINE_LINUX=\"/GRUB_CMDLINE_LINUX=\"fbcon:rotate=${fbcon_rotate} /"g /etc/default/grub
        echo ${fbcon_rotate} | sudo tee /sys/class/graphics/fbcon/rotate_all
        # Rotate the desktop temporarily.
        export embedded_display_port=$(xrandr | grep eDP | grep " connected" | cut -d" " -f1)
        if [ ! -z ${embedded_display_port} ]; then
            xrandr --output ${embedded_display_port} --rotate ${rotation_selected}
            # Rotate the desktop permanently.
            echo "xrandr --output ${embedded_display_port} --rotate ${rotation_selected}" | sudo tee /etc/profile.d/xrandr.sh
        fi
    fi
fi

test_internet_connection() {
    # Check with https://ping.archlinux.org/ to see if we have an Internet connection.
    return $(curl -s https://ping.archlinux.org/ | grep "This domain is used for connectivity checking" | wc -l)
}

while true;
    do kdialog_dbus=$(kdialog --title "winesapOS First-Time Setup" --progressbar "Checking Internet connection..." 2 | cut -d" " -f1)
    ${qdbus_cmd} ${kdialog_dbus} /ProgressDialog showCancelButton false
    test_internet_connection
    if [ $? -eq 1 ]; then
        ${qdbus_cmd} ${kdialog_dbus} /ProgressDialog org.kde.kdialog.ProgressDialog.close
        # Break out of the "while" loop if we have an Internet connection.
        break 2
    fi
    ${qdbus_cmd} ${kdialog_dbus} /ProgressDialog org.kde.kdialog.ProgressDialog.close
    kdialog --title "winesapOS First-Time Setup" \
            --yesno "A working Internet connection for setting up graphics drivers is not detected. \
            \nPlease connect to the Internet and try again, or select Cancel to quit Setup." \
            --yes-label "Retry" \
            --no-label "Cancel"
    if [ $? -eq 1 ]; then
        # Exit the script if the user selects "Cancel".
        exit 1
    fi
done

# Download the Steam bootstrap files in the background.
# This allows the Steam Gamescope Session to work on the next reboot.
steam_bootstrap() {
    if [[ -f /usr/bin/steam ]]; then
        tmux new-session -d -s steam 'xwfb-run --error-file /tmp/weston.log steam &> /tmp/steam.log'
    fi
}

steam_bootstrap

winesapos_ver_latest="$(curl https://raw.githubusercontent.com/LukeShortCloud/winesapOS/stable/files/os-release-winesapos | grep VERSION_ID | cut -d = -f 2)"
winesapos_ver_current="$(grep VERSION_ID /usr/lib/os-release-winesapos | cut -d = -f 2)"
# 'sort -V' does not work with semantic numbers.
# As a workaround, adding an underline to versions without a suffix allows the semantic sort to work.
if [[ $(echo -e "${winesapos_ver_latest}\n${winesapos_ver_current}" | sed '/-/!{s/$/_/}' | sort -V) == "$(echo -e ${winesapos_ver_latest}"\n"${winesapos_ver_current} | sed '/-/!{s/$/_/}')" ]]; then
    echo "No newer version found."
else
    kdialog --title "winesapOS First-Time Setup" --yesno "This is an older version of winesapOS. It is recommended to either download the latest image or run the winesapOS Upgrade on the desktop first. Do you want to continue the first-time setup?"
    if [ $? -ne 0 ]; then
        exit 0
    fi
fi

if [[ "${WINESAPOS_IMAGE_TYPE}" == "secure" ]]; then
    echo "Allow passwordless 'sudo' for AUR packages installed via 'yay' to be done automatically..."
    sudo -E sh -c 'mv /etc/sudoers.d/${WINESAPOS_USER_NAME} /root/etc-sudoersd-${WINESAPOS_USER_NAME}; echo "${WINESAPOS_USER_NAME} ALL=(root) NOPASSWD:ALL" > /etc/sudoers.d/${WINESAPOS_USER_NAME}; chmod 0440 /etc/sudoers.d/${WINESAPOS_USER_NAME}'
    echo "Allow passwordless 'sudo' for AUR packages installed via 'yay' to be done automatically complete."
fi

os_detected=$(grep -P ^ID= /etc/os-release | cut -d= -f2)

if [ "${os_detected}" != "arch" ] && [ "${os_detected}" != "manjaro" ]; then
    echo Unsupported operating system. Please use Arch Linux or Manjaro.
    exit 1
fi

echo "Turning on the Mac fan service if the hardware is Apple..."
sudo dmidecode -s system-product-name | grep -P ^Mac
if [ $? -eq 0 ]; then
    echo "Mac hardware detected."
    sudo systemctl enable --now mbpfan
    # Networking over USB does not work on T2 Macs.
    # https://wiki.t2linux.org/guides/postinstall/
    echo -e "blacklist cdc_ncm\nblacklist cdc_mbim\n" | sudo tee -a /etc/modprobe.d/winesapos-mac.conf
    # Enable audio workaround for T2 Macs.
    sudo sed -i s'/GRUB_CMDLINE_LINUX_DEFAULT="/GRUB_CMDLINE_LINUX_DEFAULT="efi=noruntime intel_iommu=on iommu=pt pcie_ports=compat /'g /etc/default/grub
else
    echo "No Mac hardware detected."
fi
echo "Turning on the Mac fan service if the hardware is Apple complete."

# Dialog to ask the user what mirror region they want to use
if [ "${os_detected}" = "arch" ]; then
    # Fetch the list of regions from the Arch Linux mirror status JSON API
    mirror_regions=("${(@f)$(curl -s https://archlinux.org/mirrors/status/json/ | jq -r '.urls[].country' | sort | uniq | sed '1d')}")
fi 

if [ "${os_detected}" = "manjaro" ]; then
    # Fetch the list of regions from the Manjaro mirror status JSON API
    mirror_regions=("${(@f)$(curl -s https://repo.manjaro.org/status.json | jq -r '.[].country' | sort | uniq)}")
fi

kdialog_dbus=$(kdialog --title "winesapOS First-Time Setup" --progressbar "Please wait for the setup to update the Pacman cache..." 3 | cut -d" " -f1)
chosen_region=$(kdialog --title "winesapOS First-Time Setup" \
                        --combobox "Select your desired mirror region, \nor press Cancel to use default settings:" \
                        "${mirror_regions[@]}")

${qdbus_cmd} ${kdialog_dbus} /ProgressDialog Set org.kde.kdialog.ProgressDialog value 1

if [ "${os_detected}" = "arch" ]; then
    # Check if the user selected a mirror region.
    if [ -n "${chosen_region}" ]; then 
        # this seems like a better idea than writing global config we can't reliably remove a line
        sudo reflector --verbose --latest 10 --sort age --save /etc/pacman.d/mirrorlist --country "${chosen_region}"
        # ideally we should be sorting by `rate` for consistency but it may get too slow
    else
        # Fallback to the Arch Linux and Rackspace global mirrors.
        echo 'Server = https://geo.mirror.pkgbuild.com/$repo/os/$arch' | sudo tee /etc/pacman.d/mirrorlist
        echo 'Server = https://mirror.rackspace.com/archlinux/$repo/os/$arch' | sudo tee -a /etc/pacman.d/mirrorlist
    fi
fi

if [[ "${os_detected}" == "manjaro" ]]; then
    if [ -n "${chosen_region}" ]; then
        sudo pacman-mirrors -c "${chosen_region}"
    else
        sudo pacman-mirrors -f 5
    fi
fi

${qdbus_cmd} ${kdialog_dbus} /ProgressDialog Set org.kde.kdialog.ProgressDialog value 2

sudo pacman -S -y
${qdbus_cmd} ${kdialog_dbus} /ProgressDialog org.kde.kdialog.ProgressDialog.close

system_manufacturer=$(sudo dmidecode -s system-manufacturer)
if [[ "${system_manufacturer}" == "Framework" ]]; then
    echo "Framework laptop detected."
    kdialog_dbus=$(kdialog --title "winesapOS First-Time Setup" --progressbar "Please wait for Framework drivers to be installed..." 8 | cut -d" " -f1)
    lscpu | grep -q Intel
    if [ $? -eq 0 ]; then
        # Enable better power management of NVMe devices on Intel Framework devices.
        sudo sed -i s'/GRUB_CMDLINE_LINUX_DEFAULT="/GRUB_CMDLINE_LINUX_DEFAULT="nvme.noacpi=1 /'g /etc/default/grub
    fi
    ${qdbus_cmd} ${kdialog_dbus} /ProgressDialog Set org.kde.kdialog.ProgressDialog value 1
    # Fix keyboard.
    echo "blacklist hid_sensor_hub" | sudo tee /etc/modprobe.d/framework-als-deactivate.conf
    ${qdbus_cmd} ${kdialog_dbus} /ProgressDialog Set org.kde.kdialog.ProgressDialog value 2
    # Fix firmware updates.
    sudo mkdir /etc/fwupd/
    echo -e "[uefi_capsule]\nDisableCapsuleUpdateOnDisk=true" | sudo tee /etc/fwupd/uefi_capsule.conf
    ${qdbus_cmd} ${kdialog_dbus} /ProgressDialog Set org.kde.kdialog.ProgressDialog value 3
    # Enable support for the ambient light sensor.
    sudo ${CMD_PACMAN_INSTALL[*]} iio-sensor-proxy
    ${qdbus_cmd} ${kdialog_dbus} /ProgressDialog Set org.kde.kdialog.ProgressDialog value 4
    # Enable the ability to disable the touchpad while typing.
    sudo touch /usr/share/libinput/50-framework.quirks
    echo '[Framework Laptop 16 Keyboard Module]
MatchName=Framework Laptop 16 Keyboard Module*
MatchUdevType=keyboard
MatchDMIModalias=dmi:*svnFramework:pnLaptop16*
AttrKeyboardIntegration=internal' | sudo tee /usr/share/libinput/50-framework.quirks
    ${qdbus_cmd} ${kdialog_dbus} /ProgressDialog Set org.kde.kdialog.ProgressDialog value 5
    # Enable a better audio profile for Framework Laptops.
    # https://github.com/cab404/framework-dsp
    sudo ${CMD_PACMAN_INSTALL[*]} easyeffects
    # 'unzip' is not installed on the winesapOS minimal image.
    sudo ${CMD_PACMAN_INSTALL[*]} unzip
    TMP=$(mktemp -d) && \
    CFG=${XDG_CONFIG_HOME:-~/.config}/easyeffects && \
    mkdir -p "$CFG" && \
    curl -Lo $TMP/fwdsp.zip https://github.com/cab404/framework-dsp/archive/refs/heads/master.zip && \
    unzip -d $TMP $TMP/fwdsp.zip 'framework-dsp-master/config/*/*' && \
    sed -i 's|%CFG%|'$CFG'|g' $TMP/framework-dsp-master/config/*/*.json && \
    cp -rv $TMP/framework-dsp-master/config/* $CFG && \
    rm -rf $TMP
    ${qdbus_cmd} ${kdialog_dbus} /ProgressDialog Set org.kde.kdialog.ProgressDialog value 6
    # Automatically configure the correct region for the Wi-Fi device.
    export COUNTRY_CODE="$(curl -s ipinfo.io | jq -r .country)"
    ## Temporarily.
    sudo -E iw reg set ${COUNTRY_CODE}
    ## Permanently.
    sudo ${CMD_PACMAN_INSTALL[*]} wireless-regdb
    echo "WIRELESS_REGDOM=\"${COUNTRY_CODE}\"" | sudo tee -a /etc/conf.d/wireless-regdom
    ${qdbus_cmd} ${kdialog_dbus} /ProgressDialog Set org.kde.kdialog.ProgressDialog value 7
    # Enable support for the LED matrix on the Framework Laptop 16.
    ${CMD_YAY_INSTALL[*]} inputmodule-control
    ${qdbus_cmd} ${kdialog_dbus} /ProgressDialog org.kde.kdialog.ProgressDialog.close
else
    echo "Framework laptop not detected."
fi

# https://github.com/linux-surface/linux-surface/wiki/Installation-and-Setup#arch
system_family=$(sudo dmidecode -s system-family)
if [[ "${system_family}" == "Surface" ]]; then
    echo "Microsoft Surface laptop detected."
    kdialog_dbus=$(kdialog --title "winesapOS First-Time Setup" --progressbar "Please wait for Microsoft Surface drivers to be installed..." 3 | cut -d" " -f1)
    # The recommended GPG key is no longer valid.
    echo -e "\n[linux-surface]\nServer = https://pkg.surfacelinux.com/arch/\nSigLevel = Never" | sudo tee -a /etc/pacman.conf
    sudo pacman -S -y
    ${qdbus_cmd} ${kdialog_dbus} /ProgressDialog Set org.kde.kdialog.ProgressDialog value 1

    sudo ${CMD_PACMAN_INSTALL[*]} iptsd
    ${qdbus_cmd} ${kdialog_dbus} /ProgressDialog Set org.kde.kdialog.ProgressDialog value 2

    sudo pacman -R -n --nodeps --nodeps --noconfirm libwacom
    # Install build dependencies for 'libwacom-surface' first.
    sudo ${CMD_PACMAN_INSTALL[*]} meson ninja
    ${CMD_YAY_INSTALL[*]} libwacom-surface
    ${qdbus_cmd} ${kdialog_dbus} /ProgressDialog org.kde.kdialog.ProgressDialog.close
else
    echo "Microsoft Surface laptop not detected."
fi

if sudo dmidecode -s system-manufacturer | grep -P "^ASUS"; then
    echo "ASUS computer detected."
    kdialog_dbus=$(kdialog --title "winesapOS First-Time Setup" --progressbar "Please wait for ASUS utilities to be installed..." 1 | cut -d" " -f1)
    ${CMD_YAY_INSTALL[*]} asusctl-git
    ${qdbus_cmd} ${kdialog_dbus} /ProgressDialog org.kde.kdialog.ProgressDialog.close
else
    echo "ASUS computer not detected."
fi

graphics_selected=$(kdialog --title "winesapOS First-Time Setup" --menu "Select your desired graphics driver..." amd AMD intel Intel nvidia-open "NVIDIA Open (for DLSS, Turing and newer)" nvidia-mesa "NVIDIA Mesa (for portability, Kepler and newer)" virtualbox VirtualBox vmware VMware)
# Keep track of the selected graphics drivers for upgrade purposes.
echo ${graphics_selected} | sudo tee /var/winesapos/graphics
kdialog_dbus=$(kdialog --title "winesapOS First-Time Setup" --progressbar "Please wait for the graphics driver to be installed..." 2 | cut -d" " -f1)
${qdbus_cmd} ${kdialog_dbus} /ProgressDialog Set org.kde.kdialog.ProgressDialog value 1

if [[ "${graphics_selected}" == "amd" ]]; then
    true
elif [[ "${graphics_selected}" == "intel" ]]; then
    sudo pacman -S --noconfirm \
      extra/intel-media-driver \
      extra/intel-compute-runtime
elif [[ "${graphics_selected}" == "nvidia-open" ]]; then
    sudo pacman -S --noconfirm \
      extra/nvidia-open-dkms \
      extra/nvidia-utils \
      multilib/lib32-nvidia-utils \
      extra/opencl-nvidia \
      multilib/lib32-opencl-nvidia

    # Enable Wayland support.
    sudo sed -i s'/GRUB_CMDLINE_LINUX_DEFAULT="/GRUB_CMDLINE_LINUX_DEFAULT="nvidia_drm.modeset=1 nvidia_drm.fbdev=1 /'g /etc/default/grub

    # Block the loading of conflicting open source NVIDIA drivers.
    sudo touch /etc/modprobe.d/winesapos-nvidia.conf
    echo "blacklist nova
blacklist nouveau
blacklist nvidiafb
blacklist nv
blacklist rivafb
blacklist rivatv
blacklist uvcvideo" | sudo tee /etc/modprobe.d/winesapos-nvidia.conf

    # Enable NVIDIA services to prevent crashes.
    # https://github.com/LukeShortCloud/winesapOS/issues/837
    sudo systemctl enable nvidia-hibernate nvidia-persistenced nvidia-powerd nvidia-resume nvidia-suspend
elif [[ "${graphics_selected}" == "nvidia-mesa" ]]; then
    # Enable GSP firmware support for older graphics cards.
    sudo sed -i s'/GRUB_CMDLINE_LINUX_DEFAULT="/GRUB_CMDLINE_LINUX_DEFAULT="nouveau.config=NvGspRm=1 /'g /etc/default/grub

    # Enable experimental support for old graphics cards starting with Kepler.
    echo "NVK_I_WANT_A_BROKEN_VULKAN_DRIVER=1" | sudo tee -a /etc/environment

    # Block the loading of conflicting NVIDIA Open Kernel Module drivers.
    sudo touch /etc/modprobe.d/winesapos-nvidia.conf
    echo "blacklist nvidia
blacklist nvidiafb
blacklist nvidia_drm
blacklist i2c_nvidia_gpu" | sudo tee /etc/modprobe.d/winesapos-nvidia.conf
elif [[ "${graphics_selected}" == "virtualbox" ]]; then
    sudo pacman -S --noconfirm virtualbox-guest-utils
    sudo systemctl enable --now vboxservice
    sudo usermod -a -G vboxsf winesap
elif [[ "${graphics_selected}" == "vmware" ]]; then
    sudo pacman -S --noconfirm \
      open-vm-tools \
      xf86-video-vmware \
      xf86-input-vmmouse \
      gtkmm3
    sudo systemctl enable --now \
      vmtoolsd \
      vmware-vmblock-fuse
fi
${qdbus_cmd} ${kdialog_dbus} /ProgressDialog org.kde.kdialog.ProgressDialog.close

swap_selected=$(kdialog --title "winesapOS First-Time Setup" --menu "Select your method for swap..." zram "zram (fast to create, uses CPU)" swapfile "swapfile (slow to create, uses I/O)" none "none")
if [[ "${swap_selected}" == "zram" ]]; then
    kdialog_dbus=$(kdialog --title "winesapOS First-Time Setup" --progressbar "Please wait for zram to be enabled..." 1 | cut -d" " -f1)
    # Configure optimized zram settings used by Pop!_OS.
    echo "vm.swappiness = 180
vm.watermark_boost_factor = 0
vm.watermark_scale_factor = 125
vm.page-cluster = 0" | sudo tee /etc/sysctl.d/99-vm-zram-parameters.conf
    echo "[zram0]
zram-size = ram / 2
compression-algorithm = zstd" | sudo tee /etc/systemd/zram-generator.conf
    sudo systemctl daemon-reload && sudo systemctl enable systemd-zram-setup@zram0.service
    ${qdbus_cmd} ${kdialog_dbus} /ProgressDialog org.kde.kdialog.ProgressDialog.close
elif [[ "${swap_selected}" == "swapfile" ]]; then
    kdialog_dbus=$(kdialog --title "winesapOS First-Time Setup" --progressbar "Please wait for the swapfile to be enabled..." 1 | cut -d" " -f1)
    swap_size_selected=$(kdialog --title "winesapOS First-Time Setup" --inputbox "Swap size (GB):" "8")
    echo "vm.swappiness=1" | sudo tee -a /etc/sysctl.d/00-winesapos.conf
    sudo touch /swap/swapfile
    # Avoid Btrfs copy-on-write.
    sudo chattr +C /swap/swapfile
    # Now fill in the swap file.
    sudo dd if=/dev/zero of=/swap/swapfile bs=1M count="${swap_size_selected}000"
    # A swap file requires strict permissions to work.
    sudo chmod 0600 /swap/swapfile
    sudo mkswap /swap/swapfile
    sudo swaplabel --label winesapos-swap /swap/swapfile
    sudo swapon /swap/swapfile
    echo "/swap/swapfile    none    swap    defaults    0 0" | sudo tee -a /etc/fstab
    ${qdbus_cmd} ${kdialog_dbus} /ProgressDialog org.kde.kdialog.ProgressDialog.close
fi

kdialog --title "winesapOS First-Time Setup" --yesno "Do you want to change the current locale (en_US.UTF-8 UTF-8)?"
if [ $? -eq 0 ]; then
    kdialog --title "winesapOS First-Time Setup" --yesno "Do you want to see all availables locales in /etc/locale.gen?"
    if [ $? -eq 0 ]; then
        kdialog --title "winesapOS First-Time Setup" --textbox /etc/locale.gen
    fi

    locale_selected=$(kdialog --title "winesapOS First-Time Setup" --inputbox "Locale for /etc/locale.gen:" "en_US.UTF-8 UTF-8")
    kdialog_dbus=$(kdialog --title "winesapOS First-Time Setup" --progressbar "Please wait for the locale to be setup..." 2 | cut -d" " -f1)
    ${qdbus_cmd} ${kdialog_dbus} /ProgressDialog Set org.kde.kdialog.ProgressDialog value 1
    echo "${locale_selected}" | sudo tee -a /etc/locale.gen
    sudo locale-gen
    sudo sed -i '/^LANG/d' /etc/locale.conf
    echo "LANG=$(echo ${locale_selected} | cut -d' ' -f1)" | sudo tee -a /etc/locale.conf
    sed -i '/^LANG/d' /home/${USER}/.config/plasma-localerc
    echo "LANG=$(echo ${locale_selected} | cut -d' ' -f1)" >> /home/${USER}/.config/plasma-localerc
    ${qdbus_cmd} ${kdialog_dbus} /ProgressDialog org.kde.kdialog.ProgressDialog.close
fi

kdialog --title "winesapOS First-Time Setup" --yesno "Do you want to change the current time zone (UTC)?"
if [ $? -eq 0 ]; then
    selected_time_zone=$(kdialog --title "winesapOS First-Time Setup" --combobox "Select the desired time zone:" $(timedatectl list-timezones))
    sudo timedatectl set-timezone ${selected_time_zone}
fi

kdialog --title "winesapOS First-Time Setup" --yesno "Do you want to install the Nix package manager?"
if [ $? -eq 0 ]; then
    kdialog_dbus=$(kdialog --title "winesapOS First-Time Setup" --progressbar "Please wait for the Nix package manager to be installed..." 2 | cut -d" " -f1)
    curl -L https://install.determinate.systems/nix | sudo sh -s -- install --no-confirm
    ${qdbus_cmd} ${kdialog_dbus} /ProgressDialog Set org.kde.kdialog.ProgressDialog value 1
    sudo systemctl enable --now nix-daemon
    . /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh
    nix-channel --add https://nixos.org/channels/nixpkgs-unstable
    nix-channel --update
    ${qdbus_cmd} ${kdialog_dbus} /ProgressDialog org.kde.kdialog.ProgressDialog.close
fi

kdialog --title "winesapOS First-Time Setup" --yesno "Do you want to install recommended applications for productivity?"
if [ $? -eq 0 ]; then
    kdialog_dbus=$(kdialog --title "winesapOS First-Time Setup" --progressbar "Please wait for recommended productivity applications to be installed..." 11 | cut -d" " -f1)
    # Calibre for an ebook manager.
    sudo ${CMD_FLATPAK_INSTALL[*]} com.calibre_ebook.calibre
    cp /var/lib/flatpak/app/com.calibre_ebook.calibre/current/active/export/share/applications/com.calibre_ebook.calibre.desktop /home/${USER}/Desktop/
    ${qdbus_cmd} ${kdialog_dbus} /ProgressDialog Set org.kde.kdialog.ProgressDialog value 1
    # Cheese for a webcam utility.
    sudo ${CMD_FLATPAK_INSTALL[*]} org.gnome.Cheese
    cp /var/lib/flatpak/app/org.gnome.Cheese/current/active/export/share/applications/org.gnome.Cheese.desktop /home/${USER}/Desktop/
    ${qdbus_cmd} ${kdialog_dbus} /ProgressDialog Set org.kde.kdialog.ProgressDialog value 2
    # CoolerControl for computer fan management.
    ${CMD_YAY_INSTALL[*]} coolercontrol
    cp /usr/share/applications/org.coolercontrol.CoolerControl.desktop /home/${USER}/Desktop/
    ${qdbus_cmd} ${kdialog_dbus} /ProgressDialog Set org.kde.kdialog.ProgressDialog value 3
    # FileZilla for FTP file transfers.
    sudo ${CMD_FLATPAK_INSTALL[*]} org.filezillaproject.Filezilla
    cp /var/lib/flatpak/exports/share/applications/org.filezillaproject.Filezilla.desktop /home/${USER}/Desktop/
    ${qdbus_cmd} ${kdialog_dbus} /ProgressDialog Set org.kde.kdialog.ProgressDialog value 4
    # Flatseal for managing Flatpaks.
    sudo ${CMD_FLATPAK_INSTALL[*]} com.github.tchx84.Flatseal
    cp /var/lib/flatpak/app/com.github.tchx84.Flatseal/current/active/export/share/applications/com.github.tchx84.Flatseal.desktop /home/${USER}/Desktop/
    ${qdbus_cmd} ${kdialog_dbus} /ProgressDialog Set org.kde.kdialog.ProgressDialog value 5
    # Google Chrome web browser.
    sudo ${CMD_FLATPAK_INSTALL[*]} com.google.Chrome
    cp /var/lib/flatpak/app/com.google.Chrome/current/active/export/share/applications/com.google.Chrome.desktop /home/${USER}/Desktop/
    ${qdbus_cmd} ${kdialog_dbus} /ProgressDialog Set org.kde.kdialog.ProgressDialog value 6
    # KeePassXC for an encrypted password manager.
    sudo ${CMD_FLATPAK_INSTALL[*]} org.keepassxc.KeePassXC
    cp /var/lib/flatpak/app/org.keepassxc.KeePassXC/current/active/export/share/applications/org.keepassxc.KeePassXC.desktop /home/${USER}/Desktop/
    ${qdbus_cmd} ${kdialog_dbus} /ProgressDialog Set org.kde.kdialog.ProgressDialog value 7
    # LibreOffice for an office suite.
    sudo ${CMD_FLATPAK_INSTALL[*]} org.libreoffice.LibreOffice
    cp /var/lib/flatpak/app/org.libreoffice.LibreOffice/current/active/export/share/applications/org.libreoffice.LibreOffice.desktop /home/${USER}/Desktop/
    ${qdbus_cmd} ${kdialog_dbus} /ProgressDialog Set org.kde.kdialog.ProgressDialog value 8
    # PeaZip compression utility.
    sudo ${CMD_FLATPAK_INSTALL[*]} io.github.peazip.PeaZip
    cp /var/lib/flatpak/app/io.github.peazip.PeaZip/current/active/export/share/applications/io.github.peazip.PeaZip.desktop /home/${USER}/Desktop/
    ${qdbus_cmd} ${kdialog_dbus} /ProgressDialog Set org.kde.kdialog.ProgressDialog value 9
    # qBittorrent for torrents.
    sudo ${CMD_FLATPAK_INSTALL[*]} org.qbittorrent.qBittorrent
    cp /var/lib/flatpak/app/org.qbittorrent.qBittorrent/current/active/export/share/applications/org.qbittorrent.qBittorrent.desktop /home/${USER}/Desktop/
    ${qdbus_cmd} ${kdialog_dbus} /ProgressDialog Set org.kde.kdialog.ProgressDialog value 10
    # VLC media player.
    sudo ${CMD_FLATPAK_INSTALL[*]} org.videolan.VLC
    cp /var/lib/flatpak/app/org.videolan.VLC/current/active/export/share/applications/org.videolan.VLC.desktop /home/${USER}/Desktop/
    ${qdbus_cmd} ${kdialog_dbus} /ProgressDialog org.kde.kdialog.ProgressDialog.close
else
    prodpkgs=$(kdialog --title "winesapOS First-Time Setup" --separate-output --checklist "Select productivity packages to install:" \
                       balena-etcher:other "balenaEtcher (storage cloner)" off \
                       com.calibre_ebook.calibre:flatpak "Calibre (ebooks)" off \
                       org.gnome.Cheese:flatpak "Cheese (webcam)" off \
                       com.gitlab.davem.ClamTk:flatpak "ClamTk (anti-virus)" off \
                       coolercontrol:pkg "CoolerControl (fan control)" off \
                       org.filezillaproject.Filezilla:flatpak "FileZilla (FTP)" off \
                       com.github.tchx84.Flatseal:flatpak "Flatseal (Flatpak manager)" off \
                       com.google.Chrome "Google Chrome (web browser)" off \
                       gparted:pkg "GParted (partition manager)" off \
                       org.keepassxc.KeePassXC:flatpak "KeePassXC (password manager)" off \
                       org.libreoffice.LibreOffice:flatpak "LibreOffice (office suite)" off \
                       io.github.peazip.PeaZip:flatpak "PeaZip (compression)" off \
                       qdirstat:pkg "QDirStat (storage space analyzer)" off \
                       shutter:pkg "Shutter (screenshots)" off \
                       org.qbittorrent.qBittorrent:flatpak "qBittorrent (torrent)" off \
                       veracrypt:pkg "VeraCrypt (file encryption)" off \
                       org.videolan.VLC:flatpak "VLC (media player)" off)
    for prodpkg in ${prodpkgs}
        do kdialog_dbus=$(kdialog --title "winesapOS First-Time Setup" --progressbar "Please wait for ${prodpkg} to be installed..." 2 | cut -d" " -f1)
        ${qdbus_cmd} ${kdialog_dbus} /ProgressDialog Set org.kde.kdialog.ProgressDialog value 1
        echo ${prodpkg} | grep -P ":flatpak$"
        if [ $? -eq 0 ]; then
            sudo ${CMD_FLATPAK_INSTALL[*]} $(echo "${prodpkg}" | cut -d: -f1)
        fi
        echo ${prodpkg} | grep -P ":pkg$"
        if [ $? -eq 0 ]; then
            ${CMD_YAY_INSTALL[*]} $(echo "${prodpkg}" | cut -d: -f1)
        fi
        echo ${prodpkg} | grep -P "^balena-etcher:other$"
        if [ $? -eq 0 ]; then
            export ETCHER_VER="1.7.9"
            wget "https://github.com/balena-io/etcher/releases/download/v${ETCHER_VER}/balenaEtcher-${ETCHER_VER}-x64.AppImage" -O /home/${USER}/Desktop/balenaEtcher.AppImage
            chmod +x /home/${USER}/Desktop/balenaEtcher.AppImage
        fi
        ${qdbus_cmd} ${kdialog_dbus} /ProgressDialog org.kde.kdialog.ProgressDialog.close
    done
fi

kdialog --title "winesapOS First-Time Setup" --yesno "Do you want to install recommended applications for gaming?"
if [ $? -eq 0 ]; then
    kdialog_dbus=$(kdialog --title "winesapOS First-Time Setup" --progressbar "Please wait for recommended gaming applications to be installed..." 11 | cut -d" " -f1)
    # AntiMicroX for configuring controller input.
    sudo ${CMD_FLATPAK_INSTALL[*]} io.github.antimicrox.antimicrox
    cp /var/lib/flatpak/app/io.github.antimicrox.antimicrox/current/active/export/share/applications/io.github.antimicrox.antimicrox.desktop /home/${USER}/Desktop/
    ${qdbus_cmd} ${kdialog_dbus} /ProgressDialog Set org.kde.kdialog.ProgressDialog value 1
    # Bottles for running any Windows game or application.
    sudo ${CMD_FLATPAK_INSTALL[*]} com.usebottles.bottles
    cp /var/lib/flatpak/app/com.usebottles.bottles/current/active/export/share/applications/com.usebottles.bottles.desktop /home/${USER}/Desktop/
    ${qdbus_cmd} ${kdialog_dbus} /ProgressDialog Set org.kde.kdialog.ProgressDialog value 2
    # Discord for social gaming.
    sudo ${CMD_FLATPAK_INSTALL[*]} com.discordapp.Discord
    cp /var/lib/flatpak/app/com.discordapp.Discord/current/active/export/share/applications/com.discordapp.Discord.desktop /home/${USER}/Desktop/
    ${qdbus_cmd} ${kdialog_dbus} /ProgressDialog Set org.kde.kdialog.ProgressDialog value 3
    # Heroic Games Launcher.
    sudo ${CMD_FLATPAK_INSTALL[*]} com.heroicgameslauncher.hgl
    cp /var/lib/flatpak/app/com.heroicgameslauncher.hgl/current/active/export/share/applications/com.heroicgameslauncher.hgl.desktop /home/${USER}/Desktop/
    ${qdbus_cmd} ${kdialog_dbus} /ProgressDialog Set org.kde.kdialog.ProgressDialog value 4
    # Ludusavi.
    ${CMD_YAY_INSTALL[*]} ludusavi
    cp /usr/share/applications/com.github.mtkennerly.ludusavi.desktop /home/${USER}/Desktop/
    ${qdbus_cmd} ${kdialog_dbus} /ProgressDialog Set org.kde.kdialog.ProgressDialog value 5
    # Lutris.
    sudo ${CMD_FLATPAK_INSTALL[*]} net.lutris.Lutris
    cp /var/lib/flatpak/app/net.lutris.Lutris/current/active/export/share/applications/net.lutris.Lutris.desktop /home/${USER}/Desktop/
    ${qdbus_cmd} ${kdialog_dbus} /ProgressDialog Set org.kde.kdialog.ProgressDialog value 6
    # MangoHud.
    ${CMD_YAY_INSTALL[*]} mangohud-git lib32-mangohud-git
    # Flatpak's non-interactive mode does not work for MangoHud.
    # Instead, install a specific version of MangoHud.
    # https://github.com/LukeShortCloud/winesapOS/issues/336
    sudo ${CMD_FLATPAK_INSTALL[*]} runtime/org.freedesktop.Platform.VulkanLayer.MangoHud/x86_64/23.08
    ${qdbus_cmd} ${kdialog_dbus} /ProgressDialog Set org.kde.kdialog.ProgressDialog value 7
    # Prism Launcher for playing Minecraft.
    sudo ${CMD_FLATPAK_INSTALL[*]} org.prismlauncher.PrismLauncher
    cp /var/lib/flatpak/app/org.prismlauncher.PrismLauncher/current/active/export/share/applications/org.prismlauncher.PrismLauncher.desktop /home/${USER}/Desktop/
    ${qdbus_cmd} ${kdialog_dbus} /ProgressDialog Set org.kde.kdialog.ProgressDialog value 8
    # Protontricks for managing dependencies in Proton.
    sudo ${CMD_FLATPAK_INSTALL[*]} com.github.Matoking.protontricks
    ## Add a wrapper script so that the Flatpak can be used normally via the CLI.
    echo '#!/bin/bash
flatpak run com.github.Matoking.protontricks $@
' | sudo tee /usr/local/bin/protontricks
    sudo chmod +x /usr/local/bin/protontricks
    ${qdbus_cmd} ${kdialog_dbus} /ProgressDialog Set org.kde.kdialog.ProgressDialog value 9
    # ProtonUp-Qt for managing GE-Proton versions.
    sudo ${CMD_FLATPAK_INSTALL[*]} net.davidotek.pupgui2
    cp /var/lib/flatpak/app/net.davidotek.pupgui2/current/active/export/share/applications/net.davidotek.pupgui2.desktop /home/${USER}/Desktop/
    ${qdbus_cmd} ${kdialog_dbus} /ProgressDialog Set org.kde.kdialog.ProgressDialog value 10
    # OBS Studio for screen recording and live streaming.
    sudo ${CMD_FLATPAK_INSTALL[*]} com.obsproject.Studio
    cp /var/lib/flatpak/app/com.obsproject.Studio/current/active/export/share/applications/com.obsproject.Studio.desktop /home/${USER}/Desktop/
    ${qdbus_cmd} ${kdialog_dbus} /ProgressDialog org.kde.kdialog.ProgressDialog.close
else
    gamepkgs=$(kdialog --title "winesapOS First-Time Setup" --separate-output --checklist "Select gaming packages to install:" \
                 io.github.antimicrox.antimicrox:flatpak "AntiMicroX" off \
                 com.usebottles.bottles:flatpak "Bottles" off \
                 deckyloader:other "Decky Loader" off \
                 com.discordapp.Discord:flatpak "Discord" off \
                 emudeck:other "EmuDeck" off \
                 gamemode:pkg "GameMode (64-bit)" off \
                 lib32-gamemode:pkg "GameMode (32-bit)" off \
                 gamescope:other "Gamescope Session" off \
                 game-devices-udev:pkg "games-devices-udev (extra controller support)" off \
                 goverlay:pkg "GOverlay" off \
                 com.heroicgameslauncher.hgl:flatpak "Heroic Games Launcher" off \
                 ludusavi:pkg "Ludusavi" off \
                 net.lutris.Lutris:flatpak "Lutris" off \
                 mangohud-git:other "MangoHud (64-bit)" off \
                 lib32-mangohud-git:pkg "MangoHud (32-bit)" off \
                 com.obsproject.Studio:flatpak "Open Broadcaster Software (OBS) Studio." off \
                 opengamepadui:other "Open Gamepad UI" off \
                 org.prismlauncher.PrismLauncher:flatpak "Prism Launcher" off \
                 com.github.Matoking.protontricks:flatpak "Protontricks" off \
                 net.davidotek.pupgui2:flatpak "ProtonUp-Qt" off \
                 steam:other "Steam" off \
                 zerotier-one:pkg "ZeroTier One VPN (CLI)" off \
                 zerotier-gui-git:pkg "ZeroTier One VPN (GUI)" off)
    for gamepkg in ${gamepkgs}
        do kdialog_dbus=$(kdialog --title "winesapOS First-Time Setup" --progressbar "Please wait for ${gamepkg} to be installed..." 2 | cut -d" " -f1)
        ${qdbus_cmd} ${kdialog_dbus} /ProgressDialog Set org.kde.kdialog.ProgressDialog value 1
        echo ${gamepkg} | grep -P ":flatpak$"
        if [ $? -eq 0 ]; then
            sudo ${CMD_FLATPAK_INSTALL[*]} $(echo "${gamepkg}" | cut -d: -f1)
        fi
        echo ${gamepkg} | grep -P ":pkg$"
        if [ $? -eq 0 ]; then
            ${CMD_YAY_INSTALL[*]} $(echo "${gamepkg}" | cut -d: -f1)
        fi

        echo ${gamepkg} | grep -P "^deckyloader:other$"
        if [ $? -eq 0 ]; then
            # First install the 'zenity' dependency.
            sudo ${CMD_PACMAN_INSTALL[*]} zenity
            wget "https://github.com/SteamDeckHomebrew/decky-installer/releases/latest/download/decky_installer.desktop" -O /home/${USER}/Desktop/decky_installer.desktop
        fi

        echo ${gamepkg} | grep -P "^emudeck:other$"
        if [ $? -eq 0 ]; then
            EMUDECK_GITHUB_URL="https://api.github.com/repos/EmuDeck/emudeck-electron/releases/latest"
            EMUDECK_URL="$(curl -s ${EMUDECK_GITHUB_URL} | grep -E 'browser_download_url.*AppImage' | cut -d '"' -f 4)"
            wget "${EMUDECK_URL}" -O /home/${USER}/Desktop/EmuDeck.AppImage
            chmod +x /home/${USER}/Desktop/EmuDeck.AppImage
        fi

        echo ${gamepkg} | grep -P "^gamescope:other$"
        if [ $? -eq 0 ]; then
            sudo ${CMD_PACMAN_INSTALL[*]} gamescope
            ${CMD_YAY_INSTALL[*]} gamescope-session-git gamescope-session-steam-git
        fi

        echo ${gamepkg} | grep -P "^mangohud-git:other$"
        if [ $? -eq 0 ]; then
            ${CMD_YAY_INSTALL[*]} mangohud-git
            sudo ${CMD_FLATPAK_INSTALL[*]} runtime/org.freedesktop.Platform.VulkanLayer.MangoHud/x86_64/23.08
        fi

        echo ${gamepkg} | grep -P "^opengamepadui:other$"
        if [ $? -eq 0 ]; then
            ${CMD_YAY_INSTALL[*]} opengamepadui-bin opengamepadui-session-git
        fi

        echo ${gamepkg} | grep -P "^steam:other$"
        if [ $? -eq 0 ]; then
            sudo ${CMD_PACMAN_INSTALL[*]} steam steam-native-runtime
            steam_bootstrap
        fi
        ${qdbus_cmd} ${kdialog_dbus} /ProgressDialog org.kde.kdialog.ProgressDialog.close
    done
fi

# Fix permissions.
sudo chown 1000:1000 /home/${USER}/Desktop/*.desktop
chmod +x /home/${USER}/Desktop/*.desktop

kdialog --title "winesapOS First-Time Setup" --yesno "Do you want to install Waydroid for Android app support?"
if [ $? -eq 0 ]; then
    kdialog_dbus=$(kdialog --title "winesapOS First-Time Setup" --progressbar "Please wait for Waydroid to be installed..." 2 | cut -d" " -f1)
    ${CMD_YAY_INSTALL[*]} waydroid
    ${qdbus_cmd} ${kdialog_dbus} /ProgressDialog Set org.kde.kdialog.ProgressDialog value 1
    ${CMD_YAY_INSTALL[*]} waydroid-image-gapps
    ${qdbus_cmd} ${kdialog_dbus} /ProgressDialog org.kde.kdialog.ProgressDialog.close
fi

answer_install_ge="false"
kdialog --title "winesapOS First-Time Setup" --yesno "Do you want to install the GloriousEggroll variant of Proton?"
if [ $? -eq 0 ]; then
    kdialog_dbus=$(kdialog --title "winesapOS First-Time Setup" --progressbar "Please wait for the GloriousEggroll variant of Proton to be installed..." 2 | cut -d" " -f1)
    answer_install_ge="true"
    # GE-Proton.
    mkdir -p /home/${USER}/.local/share/Steam/compatibilitytools.d/
    PROTON_GE_VERSION="GE-Proton9-11"
    curl https://github.com/GloriousEggroll/proton-ge-custom/releases/download/${PROTON_GE_VERSION}/${PROTON_GE_VERSION}.tar.gz --location --output /home/${USER}/.local/share/Steam/compatibilitytools.d/${PROTON_GE_VERSION}.tar.gz
    ${qdbus_cmd} ${kdialog_dbus} /ProgressDialog Set org.kde.kdialog.ProgressDialog value 1
    tar -x -v -f /home/${USER}/.local/share/Steam/compatibilitytools.d/${PROTON_GE_VERSION}.tar.gz --directory /home/${USER}/.local/share/Steam/compatibilitytools.d/
    rm -f /home/${USER}/.local/share/Steam/compatibilitytools.d/${PROTON_GE_VERSION}.tar.gz
    ${qdbus_cmd} ${kdialog_dbus} /ProgressDialog org.kde.kdialog.ProgressDialog.close
fi

# This package contains proprietary firmware that we cannot ship
# which is why it is installed as part of the first-time setup.
kdialog --title "winesapOS First-Time Setup" --yesno "Do you want to install Xbox controller support?"
if [ $? -eq 0 ]; then
    kdialog_dbus=$(kdialog --title "winesapOS First-Time Setup" --progressbar "Please wait for Xbox controller drivers to be installed..." 2 | cut -d" " -f1)
    ${qdbus_cmd} ${kdialog_dbus} /ProgressDialog Set org.kde.kdialog.ProgressDialog value 1
    ${CMD_YAY_INSTALL[*]} xone-dkms-git
    sudo touch /etc/modules-load.d/winesapos-controllers.conf
    echo -e "xone-wired\nxone-dongle\nxone-gip\nxone-gip-gamepad\nxone-gip-headset\nxone-gip-chatpad\nxone-gip-guitar" | sudo tee -a /etc/modules-load.d/winesapos-controllers.conf
    for i in xone-wired xone-dongle xone-gip xone-gip-gamepad xone-gip-headset xone-gip-chatpad xone-gip-guitar;
        do sudo modprobe --verbose ${i}
    done
    sudo git clone https://github.com/medusalix/xpad-noone /usr/src/xpad-noone-1.0
    for kernel in $(ls -1 /usr/lib/modules/ | grep -P "^[0-9]+"); do
        sudo dkms install -m xpad-noone -v 1.0 -k ${kernel}
    done
    echo -e "\nxpad-noone\n" | sudo tee -a /etc/modules-load.d/winesapos-controllers.conf
    echo -e "\nblacklist xpad\n" | sudo tee -a /etc/modprobe.d/winesapos.conf
    sudo rmmod xpad
    sudo modprobe xpad-noone
    ${qdbus_cmd} ${kdialog_dbus} /ProgressDialog org.kde.kdialog.ProgressDialog.close
fi

kdialog --title "winesapOS First-Time Setup" --yesno "Do you want to enable the ZeroTier VPN service?"
if [ $? -eq 0 ]; then
    if [[ "${WINESAPOS_IMAGE_TYPE}" == "minimal" ]]; then
        kdialog_dbus=$(kdialog --title "winesapOS First-Time Setup" --progressbar "Please wait for ZeroTier to be installed..." 2 | cut -d" " -f1)
        sudo ${CMD_PACMAN_INSTALL[*]} zerotier-one
        ${qdbus_cmd} ${kdialog_dbus} /ProgressDialog Set org.kde.kdialog.ProgressDialog value 1
        ${CMD_YAY_INSTALL[*]} zerotier-gui-git
        ${qdbus_cmd} ${kdialog_dbus} /ProgressDialog org.kde.kdialog.ProgressDialog.close
    fi
    # ZeroTier GUI will fail to launch with a false-positive error if the service is not running.
    sudo systemctl enable --now zerotier-one
fi

if [[ "${WINESAPOS_IMAGE_TYPE}" != "secure" ]]; then
    kdialog --title "winesapOS First-Time Setup" --yesno "Do you want to change your password?"
    if [ $? -eq 0 ]; then
        # Disable debug logging as to not leak password in the log file.
        set +x
        winesap_password=$(kdialog --title "winesapOS First-Time Setup" --password "Enter your new password:")
        echo "${USER}:${winesap_password}" | sudo chpasswd
        # Re-enable debug logging.
        set -x
    fi
fi

kdialog --title "winesapOS First-Time Setup" --yesno "Do you want to change the root password?"
if [ $? -eq 0 ]; then
    set +x
    root_password=$(kdialog --title "winesapOS First-Time Setup" --password "Enter the new root password:")
    echo "root:${root_password}" | sudo chpasswd
    set -x
fi

if [[ "${WINESAPOS_IMAGE_TYPE}" == "secure" ]]; then
    kdialog --title "winesapOS First-Time Setup" --yesno "Do you want to change the LUKS storage encryption password?"
    if [ $? -eq 0 ]; then
        # This should always be "/dev/mapper/cryptroot" on the secure image.
        root_partition=$(mount | grep 'on \/ ' | awk '{print $1}')
        # Example output: "mmcblk0p5", "nvme0n1p5", "sda5"
        root_partition_shortname=$(lsblk -o name,label | grep winesapos-luks | awk '{print $1}' | grep -o -P '[a-z]+.*')
        set +x
        luks_password=$(kdialog --title "winesapOS First-Time Setup" --password "Enter the new LUKS storage encryption password:")
        echo -e "password\n${luks_password}\n${luks_password}\n" | cryptsetup luksChangeKey /dev/${root_partition_shortname}
        set -x
    fi
fi

kdialog --title "winesapOS First-Time Setup" --yesno "Do you want to enable autologin?"
if [ $? -eq 0 ]; then
    sudo mkdir /etc/sddm.conf.d/
    sudo crudini --ini-options=nospace --set /etc/sddm.conf.d/autologin.conf Autologin User winesap
    sudo crudini --ini-options=nospace --set /etc/sddm.conf.d/autologin.conf Autologin Session plasma
fi

kdialog --title "winesapOS First-Time Setup" --yesno "Do you want to hide the GRUB boot menu?"
if [ $? -eq 0 ]; then
    sudo crudini --ini-options=nospace --set /etc/default/grub "" GRUB_TIMEOUT 0
    sudo crudini --ini-options=nospace --set /etc/default/grub "" GRUB_TIMEOUT_STYLE hidden
fi

# Remove the Flatpak directory for the user to avoid errors.
# This directory will automatically get re-generated when a 'flatpak' command is ran.
# https://github.com/LukeShortCloud/winesapOS/issues/516
rm -r -f /home/${USER}/.local/share/flatpak

kdialog --title "winesapOS First-Time Setup" --yesno "Do you want to upgrade hardware firmware from LVFS with fwupdmgr?"
if [ $? -eq 0 ]; then
    kdialog_dbus=$(kdialog --title "winesapOS First-Time Setup" --progressbar "Please wait for hardware firmware to be upgraded..." 2 | cut -d" " -f1)
    sudo fwupdmgr refresh --force
    ${qdbus_cmd} ${kdialog_dbus} /ProgressDialog Set org.kde.kdialog.ProgressDialog value 1
    sudo fwupdmgr update --assume-yes --no-reboot-check
    ${qdbus_cmd} ${kdialog_dbus} /ProgressDialog org.kde.kdialog.ProgressDialog.close
fi

kdialog_dbus=$(kdialog --title "winesapOS First-Time Setup" --progressbar "Please wait for the new drivers to be enabled on boot..." 2 | cut -d" " -f1)
${qdbus_cmd} ${kdialog_dbus} /ProgressDialog Set org.kde.kdialog.ProgressDialog value 1
# Regenerate the initramfs to load all of the new drivers.
sudo mkinitcpio -P
${qdbus_cmd} ${kdialog_dbus} /ProgressDialog org.kde.kdialog.ProgressDialog.close

# Regenerate the GRUB configuration to load the new Btrfs snapshots.
# This allows users to easily revert back to a fresh installation of winesapOS.
sudo grub-mkconfig -o /boot/grub/grub.cfg

# Delete the shortcut symlink so this will not auto-start again during the next login.
rm -f ~/.config/autostart/winesapos-setup.desktop

echo "Running first-time setup tests..."
kdialog_dbus=$(kdialog --title "winesapOS First-Time Setup" --progressbar "Please wait for the first-time setup tests to finish..." 2 | cut -d" " -f1)

echo -n "\tChecking that Btrfs quotas are enabled..."
# There should be two entries for 50 GiB. One for root and one for home.
if [[ "$(sudo btrfs qgroup show -pcre / | grep -c 50.00GiB)" == "2" ]]; then
    echo PASS
else
    echo FAIL
fi
${qdbus_cmd} ${kdialog_dbus} /ProgressDialog Set org.kde.kdialog.ProgressDialog value 1

if [[ "${answer_install_ge}" == "true" ]]; then
    echo "Testing that GE Proton has been installed..."
    echo -n "\tChecking that GE Proton is installed..."
    ls -1 /home/${USER}/.local/share/Steam/compatibilitytools.d/ | grep -v -P ".tar.gz$" | grep -q -P "^GE-Proton.*"
    if [ $? -eq 0 ]; then
        echo PASS
    else
        echo FAIL
    fi

    echo -n "\tChecking that the GE Proton tarball has been removed..."
    ls -1 /home/${USER}/.local/share/Steam/compatibilitytools.d/ | grep -q -P ".tar.gz$"
    if [ $? -eq 1 ]; then
        echo PASS
    else
        echo FAIL
    fi
    echo "Testing that GE Proton has been installed complete."
fi
echo "Running first-time setup tests complete."
${qdbus_cmd} ${kdialog_dbus} /ProgressDialog org.kde.kdialog.ProgressDialog.close

if [[ "${WINESAPOS_IMAGE_TYPE}" == "secure" ]]; then
    echo "Disallow passwordless 'sudo' now that the setup is done..."
    sudo -E sh -c 'rm -f /etc/sudoers.d/${WINESAPOS_USER_NAME}; mv /root/etc-sudoersd-${WINESAPOS_USER_NAME} /etc/sudoers.d/${WINESAPOS_USER_NAME}'
    echo "Disallow passwordless 'sudo' now that the setup is done complete."
fi

kdialog --title "winesapOS First-Time Setup" --msgbox "Please reboot to load new changes."
echo "End time: $(date --iso-8601=seconds)"
