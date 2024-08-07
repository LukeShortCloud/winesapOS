#!/bin/bash

# Enable shell debugging.
set -x
START_TIME=$(date --iso-8601=seconds)
exec > >(tee /tmp/upgrade_${START_TIME}.log) 2>&1
echo "Start time: ${START_TIME}"

WINESAPOS_UPGRADE_FILES="${WINESAPOS_UPGRADE_FILES:-true}"
WINESAPOS_UPGRADE_VERSION_CHECK="${WINESAPOS_UPGRADE_VERSION_CHECK:-true}"

# Check for a custom user name. Default to 'winesap'.
ls /tmp/winesapos_user_name.txt &> /dev/null
if [ $? -eq 0 ]; then
    WINESAPOS_USER_NAME=$(cat /tmp/winesapos_user_name.txt)
else
    WINESAPOS_USER_NAME="winesap"
fi

# Create a symlink for forwards compatibility.
ln -s /etc/winesapos /var/winesapos

install_pacman_static() {
    export CMD_PACMAN=/usr/bin/pacman-static
    ls ${CMD_PACMAN} &> /dev/null
    if [ $? -ne 0 ]; then
        # This package is provided by the Chaotic AUR repository.
        /usr/bin/pacman --noconfirm -S pacman-static
        if [ $? -ne 0 ]; then
            export CMD_PACMAN=/usr/local/bin/pacman-static
            ls ${CMD_PACMAN} &> /dev/null
            if [ $? -ne 0 ]; then
                wget https://pkgbuild.com/~morganamilo/pacman-static/x86_64/bin/pacman-static -LO ${CMD_PACMAN}
                chmod +x ${CMD_PACMAN}
                ls ${CMD_PACMAN} &> /dev/null
                if [ $? -ne 0 ]; then
                    # If all else fails, use the non-static 'pacman' binary.
                    export CMD_PACMAN=/usr/bin/pacman
                fi
            fi
        fi
    fi
}

install_pacman_static

WINESAPOS_DISTRO_DETECTED=$(grep -P '^ID=' /etc/os-release | cut -d= -f2)
CMD_PACMAN_INSTALL=(${CMD_PACMAN} --noconfirm -S --needed)
CMD_PACMAN_REMOVE=(${CMD_PACMAN} -R -n -s --noconfirm)
CMD_YAY_INSTALL=(sudo -u ${WINESAPOS_USER_NAME} yay --pacman ${CMD_PACMAN} --noconfirm -S --needed --removemake)
CMD_FLATPAK_INSTALL=(flatpak install -y --noninteractive)

WINESAPOS_VERSION_NEW="$(curl https://raw.githubusercontent.com/LukeShortCloud/winesapOS/stable/files/os-release-winesapos | grep VERSION_ID | cut -d = -f 2)"
export WINESAPOS_VERSION_ORIGINAL=""
# winesapOS >= 4.1.0
if [ -f /usr/lib/os-release-winesapos ]; then
    export WINESAPOS_VERSION_ORIGINAL="$(grep VERSION_ID /usr/lib/os-release-winesapos | cut -d = -f 2)"
# winesapOS < 4.1.0
else
    export WINESAPOS_VERSION_ORIGINAL="$(sudo cat /etc/winesapos/VERSION)"
fi

export WINESAPOS_IMAGE_TYPE=""
# winesapOS >= 4.1.0
if [ -f /usr/lib/os-release-winesapos ]; then
    export WINESAPOS_IMAGE_TYPE="$(grep VARIANT_ID /usr/lib/os-release-winesapos | cut -d = -f 2)"
# winesapOS < 4.1.0
else
    export WINESAPOS_IMAGE_TYPE="$(sudo cat /etc/winesapos/IMAGE_TYPE)"
fi

echo "Setting up tools required for the progress bar..."
${CMD_PACMAN} -Q | grep -q qt6-tools
if [ $? -ne 0 ]; then
    ${CMD_PACMAN_INSTALL[*]} qt6-tools
fi

# KDE Plasma 5 uses "qdbus" and 6 uses "qdbus6".
qdbus_cmd=""
if [ -e /usr/bin/qdbus ]; then
    qdbus_cmd="qdbus"
elif [ -e /usr/bin/qdbus6 ]; then
    qdbus_cmd="qdbus6"
else
    echo "No 'qdbus' command found. Progress bars will not work."
fi

${CMD_PACMAN} -Q | grep -q kdialog
if [ $? -ne 0 ]; then
    ${CMD_PACMAN_INSTALL[*]} kdialog
fi
echo "Setting up tools required for the progress bar complete."

test_internet_connection() {
    # Check with https://ping.archlinux.org/ to see if we have an Internet connection.
    return $(curl -s https://ping.archlinux.org/ | grep "This domain is used for connectivity checking" | wc -l)
}

while true;
    do kdialog_dbus=$(sudo -E -u ${WINESAPOS_USER_NAME} kdialog --title "winesapOS Upgrade" --progressbar "Checking Internet connection..." 2 | cut -d" " -f1)
    sudo -E -u ${WINESAPOS_USER_NAME} ${qdbus_cmd} ${kdialog_dbus} /ProgressDialog showCancelButton false
    test_internet_connection
    if [ $? -eq 1 ]; then
        sudo -E -u ${WINESAPOS_USER_NAME} ${qdbus_cmd} ${kdialog_dbus} /ProgressDialog org.kde.kdialog.ProgressDialog.close
        # Break out of the "while" loop if we have an Internet connection.
        break 2
    fi
    sudo -E -u ${WINESAPOS_USER_NAME} ${qdbus_cmd} ${kdialog_dbus} /ProgressDialog org.kde.kdialog.ProgressDialog.close
    sudo -E -u ${WINESAPOS_USER_NAME} kdialog --title "winesapOS Upgrade" \
            --yesno "A working Internet connection for upgrades is not detected. \
            \nPlease connect to the Internet and try again, or select Cancel to quit Upgrade." \
            --yes-label "Retry" \
            --no-label "Cancel"
    if [ $? -eq 1 ]; then
        # Exit the script if the user selects "Cancel".
        exit 1
    fi
done

if [[ "${WINESAPOS_UPGRADE_VERSION_CHECK}" == "true" ]]; then
    # 'sort -V' does not work with semantic numbers.
    # As a workaround, adding an underline to versions without a suffix allows the semantic sort to work.
    if [[ $(echo -e "${WINESAPOS_VERSION_NEW}\n${WINESAPOS_VERSION_ORIGINAL}" | sed '/-/!{s/$/_/}' | sort -V) == "$(echo -e ${WINESAPOS_VERSION_NEW}"\n"${WINESAPOS_VERSION_ORIGINAL} | sed '/-/!{s/$/_/}')" ]]; then
        sudo -E -u ${WINESAPOS_USER_NAME} kdialog --title "winesapOS Upgrade" --msgbox "No upgrade for winesapOS available."
        exit 0
    fi
fi

if [[ "${WINESAPOS_UPGRADE_FILES}" == "true" ]]; then
    echo "Upgrading the winesapOS upgrade script..."
    mv /home/${WINESAPOS_USER_NAME}/.winesapos/winesapos-upgrade-remote-stable.sh "/home/${WINESAPOS_USER_NAME}/.winesapos/winesapos-upgrade-remote-stable.sh_${START_TIME}"
    wget https://raw.githubusercontent.com/LukeShortCloud/winesapOS/stable/scripts/winesapos-upgrade-remote-stable.sh -LO /home/${WINESAPOS_USER_NAME}/.winesapos/winesapos-upgrade-remote-stable.sh
    # If the download fails for any reason, revert back to the original upgrade script.
    if [ $? -ne 0 ]; then
        rm -f /home/${WINESAPOS_USER_NAME}/.winesapos/winesapos-upgrade-remote-stable.sh
        cp "/home/${WINESAPOS_USER_NAME}/.winesapos/winesapos-upgrade-remote-stable.sh_${START_TIME}" /home/${WINESAPOS_USER_NAME}/.winesapos/winesapos-upgrade-remote-stable.sh
    fi
    chmod +x /home/${WINESAPOS_USER_NAME}/.winesapos/winesapos-upgrade-remote-stable.sh

    mv /home/${WINESAPOS_USER_NAME}/.winesapos/winesapos-upgrade.desktop "/home/${WINESAPOS_USER_NAME}/.winesapos/winesapos-upgrade.desktop_${START_TIME}"
    wget https://raw.githubusercontent.com/LukeShortCloud/winesapOS/stable/files/winesapos-upgrade.desktop -LO /home/${WINESAPOS_USER_NAME}/.winesapos/winesapos-upgrade.desktop
    # If the download fails for any reason, revert back to the original upgrade script.
    if [ $? -ne 0 ]; then
        rm -f /home/${WINESAPOS_USER_NAME}/.winesapos/winesapos-upgrade.desktop
        cp "/home/${WINESAPOS_USER_NAME}/.winesapos/winesapos-upgrade.desktop_${START_TIME}" /home/${WINESAPOS_USER_NAME}/.winesapos/winesapos-upgrade.desktop
    fi
    chmod +x /home/${WINESAPOS_USER_NAME}/.winesapos/winesapos-upgrade.desktop

    chown -R 1000:1000 /home/${WINESAPOS_USER_NAME}/.winesapos/
    echo "Upgrading the winesapOS upgrade script complete."

    if [[ "$(sha512sum /home/${WINESAPOS_USER_NAME}/.winesapos/winesapos-upgrade-remote-stable.sh | cut -d' ' -f1)" != "$(sha512sum /home/${WINESAPOS_USER_NAME}/.winesapos/winesapos-upgrade-remote-stable.sh_${START_TIME} | cut -d' ' -f1)" ]]; then
        echo "The winesapOS upgrade script has been updated. Please re-run the 'winesapOS Upgrade' desktop shortcut."
        sudo -E -u ${WINESAPOS_USER_NAME} kdialog --title "winesapOS Upgrade" --msgbox "The winesapOS upgrade script has been updated. Please re-run the 'winesapOS Upgrade' desktop shortcut."
        exit 100
    fi

    if [[ "$(sha512sum /home/${WINESAPOS_USER_NAME}/.winesapos/winesapos-upgrade.desktop | cut -d' ' -f1)" != "$(sha512sum /home/${WINESAPOS_USER_NAME}/.winesapos/winesapos-upgrade.desktop_${START_TIME} | cut -d' ' -f1)" ]]; then
        echo "The winesapOS upgrade desktop shortcut has been updated. Please re-run the 'winesapOS Upgrade' desktop shortcut."
        sudo -E -u ${WINESAPOS_USER_NAME} kdialog --title "winesapOS Upgrade" --msgbox "The winesapOS upgrade desktop shortcut has been updated. Please re-run the 'winesapOS Upgrade' desktop shortcut."
        exit 100
    fi
else
    echo "Skipping upgrade of winesapOS upgrade files."
fi

current_shell=$(cat /proc/$$/comm)
if [[ "${current_shell}" != "bash" ]]; then
    sudo -E -u ${WINESAPOS_USER_NAME} kdialog --title "winesapOS Upgrade" --msgbox "winesapOS scripts require Bash but ${current_shell} detected. Exiting..."
    exit 1
fi

if [[ "${WINESAPOS_IMAGE_TYPE}" == "secure" ]]; then
    echo "Allow passwordless 'sudo' for AUR packages installed via 'yay' to be done automatically..."
    mv /etc/sudoers.d/${WINESAPOS_USER_NAME} /root/etc-sudoersd-${WINESAPOS_USER_NAME}
    echo "${WINESAPOS_USER_NAME} ALL=(root) NOPASSWD:ALL" > /etc/sudoers.d/${WINESAPOS_USER_NAME}
    chmod 0440 /etc/sudoers.d/${WINESAPOS_USER_NAME}
    echo "Allow passwordless 'sudo' for AUR packages installed via 'yay' to be done automatically complete."
fi

# Disable PackageKit during the upgrade process.
# Otherwise, this can lead to a huge memory leak.
# https://github.com/LukeShortCloud/winesapOS/issues/697
systemctl stop packagekit
systemctl mask packagekit

echo "OLD PACKAGES:"
pacman -Q

kdialog_dbus=$(sudo -E -u ${WINESAPOS_USER_NAME} kdialog --title "winesapOS Upgrade" --progressbar "Please wait for Pacman keyrings to update..." 4 | cut -d" " -f1)
sudo -E -u ${WINESAPOS_USER_NAME} ${qdbus_cmd} ${kdialog_dbus} /ProgressDialog showCancelButton false
sudo -E -u ${WINESAPOS_USER_NAME} ${qdbus_cmd} ${kdialog_dbus} /ProgressDialog Set org.kde.kdialog.ProgressDialog value 1
# SteamOS 3.4 changed the name of the stable repositories.
# https://github.com/LukeShortCloud/winesapOS/issues/537
echo "Switching to new SteamOS release repositories..."
sed -i s'/\[holo\]/\[holo-rel\]/'g /etc/pacman.conf
sed -i s'/\[jupiter\]/\[jupiter-rel\]/'g /etc/pacman.conf
echo "Switching to new SteamOS release repositories complete."
# Update the repository cache.
sudo -E ${CMD_PACMAN} -S -y -y
sudo -E -u ${WINESAPOS_USER_NAME} ${qdbus_cmd} ${kdialog_dbus} /ProgressDialog Set org.kde.kdialog.ProgressDialog value 2
# It is possible for users to have such an old database of GPG keys that the '*-keyring' packages fail to install due to GPG verification failures.
crudini --set /etc/pacman.conf core SigLevel Never
if [[ "${WINESAPOS_DISTRO_DETECTED}" == "manjaro" ]]; then
    rm -r -f /etc/pacman.d/gnupg
    pacman-key --init
    sudo -E -u ${WINESAPOS_USER_NAME} ${qdbus_cmd} ${kdialog_dbus} /ProgressDialog Set org.kde.kdialog.ProgressDialog value 3
    ${CMD_PACMAN} --noconfirm -S archlinux-keyring manjaro-keyring
else
    rm -r -f /etc/pacman.d/gnupg
    pacman-key --init
    sudo -E -u ${WINESAPOS_USER_NAME} ${qdbus_cmd} ${kdialog_dbus} /ProgressDialog Set org.kde.kdialog.ProgressDialog value 3
    ${CMD_PACMAN} --noconfirm -S archlinux-keyring
fi
crudini --del /etc/pacman.conf core SigLevel
sudo -E -u ${WINESAPOS_USER_NAME} ${qdbus_cmd} ${kdialog_dbus} /ProgressDialog org.kde.kdialog.ProgressDialog.close

# Workaround an upstream bug in DKMS.
## https://github.com/LukeShortCloud/winesapOS/issues/427
ln -s /usr/bin/sha512sum /usr/bin/sha512

echo "Running 3.0.0-rc.0 to 3.0.0 upgrades..."
kdialog_dbus=$(sudo -E -u ${WINESAPOS_USER_NAME} kdialog --title "winesapOS Upgrade" --progressbar "Running 3.0.0-rc.0 to 3.0.0 upgrades..." 2 | cut -d" " -f1)
sudo -E -u ${WINESAPOS_USER_NAME} ${qdbus_cmd} ${kdialog_dbus} /ProgressDialog showCancelButton false
sudo -E -u ${WINESAPOS_USER_NAME} ${qdbus_cmd} ${kdialog_dbus} /ProgressDialog Set org.kde.kdialog.ProgressDialog value 1

echo "Upgrading exFAT partition to work on Windows..."
# Example output: "vda2" or "nvme0n1p2"
exfat_partition_device_name_short=$(lsblk -o name,label | grep wos-drive | awk '{print $1}' | grep -o -P '[a-z]+.*')
exfat_partition_device_name_full="/dev/${exfat_partition_device_name_short}"
# Example output: 2
exfat_partition_number=$(echo ${exfat_partition_device_name_short} | grep -o -P "[0-9]+$")

echo ${exfat_partition_device_name_short} | grep -q nvme
if [ $? -eq 0 ]; then
    # Example output: /dev/nvme0n1
    root_device=$(echo "${exfat_partition_device_name_full}" | grep -P -o "/dev/nvme[0-9]+n[0-9]+")
else
    # Example output: /dev/vda
    root_device=$(echo "${exfat_partition_device_name_full}" | sed s'/[0-9]//'g)
fi
parted ${root_device} set ${exfat_partition_number} msftdata on
echo "Upgrading exFAT partition to work on Windows complete."

echo "Running 3.0.0-rc.0 to 3.0.0 upgrades complete."
sudo -E -u ${WINESAPOS_USER_NAME} ${qdbus_cmd} ${kdialog_dbus} /ProgressDialog org.kde.kdialog.ProgressDialog.close

echo "Running 3.0.0 to 3.0.1 upgrades..."
kdialog_dbus=$(sudo -E -u ${WINESAPOS_USER_NAME} kdialog --title "winesapOS Upgrade" --progressbar "Running 3.0.0 to 3.0.1 upgrades..." 2 | cut -d" " -f1)
sudo -E -u ${WINESAPOS_USER_NAME} ${qdbus_cmd} ${kdialog_dbus} /ProgressDialog showCancelButton false
sudo -E -u ${WINESAPOS_USER_NAME} ${qdbus_cmd} ${kdialog_dbus} /ProgressDialog Set org.kde.kdialog.ProgressDialog value 1

echo "Upgrading 'makepkg' and 'yay' to use all available processor cores for compilation..."
grep -q -P "^MAKEFLAGS" /etc/makepkg.conf
if [ $? -ne 0 ]; then
    echo 'MAKEFLAGS="-j $(nproc)"' >> /etc/makepkg.conf
fi
echo "Upgrading 'makepkg' and 'yay' to use all available processor cores for compilation complete."

echo "Running 3.0.0 to 3.0.1 upgrades complete."
sudo -E -u ${WINESAPOS_USER_NAME} ${qdbus_cmd} ${kdialog_dbus} /ProgressDialog org.kde.kdialog.ProgressDialog.close


echo "Running 3.0.1 to 3.1.0 upgrades..."
kdialog_dbus=$(sudo -E -u ${WINESAPOS_USER_NAME} kdialog --title "winesapOS Upgrade" --progressbar "Running 3.0.1 to 3.1.0 upgrades..." 12 | cut -d" " -f1)
sudo -E -u ${WINESAPOS_USER_NAME} ${qdbus_cmd} ${kdialog_dbus} /ProgressDialog showCancelButton false
sudo -E -u ${WINESAPOS_USER_NAME} ${qdbus_cmd} ${kdialog_dbus} /ProgressDialog Set org.kde.kdialog.ProgressDialog value 1

# Temporarily disable the XferCommand.
# https://github.com/LukeShortCloud/winesapOS/issues/802
# https://github.com/LukeShortCloud/winesapOS/issues/900
crudini --del /etc/pacman.conf options XferCommand

echo "Adding the winesapOS repository..."
crudini --del /etc/pacman.conf winesapos
crudini --del /etc/pacman.conf winesapos-testing
if [[ "${WINESAPOS_UPGRADE_TESTING_REPO}" == "true" ]]; then
    sed -i s'/\[core]/[winesapos-testing]\nServer = https:\/\/winesapos.lukeshort.cloud\/repo\/$repo\/$arch\nSigLevel = Never\n\n[core]/'g /etc/pacman.conf
else
    sed -i s'/\[core]/[winesapos]\nServer = https:\/\/winesapos.lukeshort.cloud\/repo\/$repo\/$arch\n\n[core]/'g /etc/pacman.conf
fi
echo "Adding the winesapOS repository complete."
sudo -E -u ${WINESAPOS_USER_NAME} ${qdbus_cmd} ${kdialog_dbus} /ProgressDialog Set org.kde.kdialog.ProgressDialog value 2

echo "Enabling newer upstream Arch Linux package repositories..."
if [[ "${WINESAPOS_DISTRO_DETECTED}" != "manjaro" ]]; then
    crudini --set /etc/pacman.conf core Server 'https://mirror.rackspace.com/archlinux/$repo/os/$arch'
    crudini --del /etc/pacman.conf core Include
    crudini --set /etc/pacman.conf extra Server 'https://mirror.rackspace.com/archlinux/$repo/os/$arch'
    crudini --del /etc/pacman.conf extra Include
    crudini --set /etc/pacman.conf multilib Server 'https://mirror.rackspace.com/archlinux/$repo/os/$arch'
    crudini --del /etc/pacman.conf multilib Include
fi
# Arch Linux and Manjaro have merged the community repository into the extra repository.
crudini --del /etc/pacman.conf community
# Arch Linux is backward compatible with SteamOS packages but SteamOS is not forward compatible with Arch Linux.
# Move these repositories to the bottom of the Pacman configuration file to account for that.
crudini --del /etc/pacman.conf jupiter
crudini --del /etc/pacman.conf holo
crudini --del /etc/pacman.conf jupiter-rel
crudini --del /etc/pacman.conf holo-rel
if [[ "${WINESAPOS_DISTRO_DETECTED}" == "steamos" ]]; then
    crudini --set /etc/pacman.conf jupiter-rel Server 'https://steamdeck-packages.steamos.cloud/archlinux-mirror/$repo/os/$arch'
    crudini --set /etc/pacman.conf jupiter-rel SigLevel Never
    crudini --set /etc/pacman.conf holo-rel Server 'https://steamdeck-packages.steamos.cloud/archlinux-mirror/$repo/os/$arch'
    crudini --set /etc/pacman.conf holo-rel SigLevel Never
fi

pacman-key --list-keys | grep -q 1805E886BECCCEA99EDF55F081CA29E4A4B01239
if [ $? -ne 0 ]; then
    echo "Adding the public GPG key for the winesapOS repository..."
    pacman-key --recv-keys 1805E886BECCCEA99EDF55F081CA29E4A4B01239
    pacman-key --init
    pacman-key --lsign-key 1805E886BECCCEA99EDF55F081CA29E4A4B01239
    crudini --del /etc/pacman.conf winesapos SigLevel
    echo "Adding the public GPG key for the winesapOS repository complete."
fi
sudo -E ${CMD_PACMAN} -S -y -y
sudo -E -u ${WINESAPOS_USER_NAME} ${qdbus_cmd} ${kdialog_dbus} /ProgressDialog Set org.kde.kdialog.ProgressDialog value 2

# Install the latest Chaotic AUR keyring and mirror list.
wget 'https://cdn-mirror.chaotic.cx/chaotic-aur/chaotic-keyring.pkg.tar.zst' -LO /chaotic-keyring.pkg.tar.zst
${CMD_PACMAN} --noconfirm -U /chaotic-keyring.pkg.tar.zst
wget 'https://cdn-mirror.chaotic.cx/chaotic-aur/chaotic-mirrorlist.pkg.tar.zst' -LO /chaotic-mirrorlist.pkg.tar.zst
${CMD_PACMAN} --noconfirm -U /chaotic-mirrorlist.pkg.tar.zst
rm -f /chaotic-*.pkg.tar.zst

# Configure the Pacman configuration after the keys and mirrors have been installed for the Chaotic AUR.
grep -q "\[chaotic-aur\]" /etc/pacman.conf
if [ $? -ne 0 ]; then
    echo "Adding the Chaotic AUR repository..."
    pacman-key --list-keys | grep -q 3056513887B78AEB
    if [ $? -ne 0 ]; then
        echo "Adding the public GPG key for the Chaotic AUR repository..."
        pacman-key --recv-keys 3056513887B78AEB
        pacman-key --init
        pacman-key --lsign-key 3056513887B78AEB
        echo "Adding the public GPG key for the Chaotic AUR repository complete."
    fi
    echo "
[chaotic-aur]
Include = /etc/pacman.d/chaotic-mirrorlist" >> /etc/pacman.conf
    echo "Adding the Chaotic AUR repository complete."
fi

crudini --del /etc/pacman.conf arch-mact2
crudini --del /etc/pacman.conf Redecorating-t2
crudini --set /etc/pacman.conf arch-mact2 Server https://mirror.funami.tech/arch-mact2/os/x86_64
crudini --set /etc/pacman.conf arch-mact2 SigLevel Never
crudini --set /etc/pacman.conf Redecorating-t2 Server https://github.com/Redecorating/archlinux-t2-packages/releases/download/packages
crudini --set /etc/pacman.conf Redecorating-t2 SigLevel Never
sudo -E -u ${WINESAPOS_USER_NAME} ${qdbus_cmd} ${kdialog_dbus} /ProgressDialog Set org.kde.kdialog.ProgressDialog value 3

sudo -E ${CMD_PACMAN} -S -y -y
if [[ "${WINESAPOS_DISTRO_DETECTED}" == "manjaro" ]]; then
    ${CMD_PACMAN} --noconfirm -S archlinux-keyring manjaro-keyring
else
    ${CMD_PACMAN} --noconfirm -S archlinux-keyring
fi

install_pacman_static
echo "Enabling newer upstream Arch Linux package repositories complete."
sudo -E -u ${WINESAPOS_USER_NAME} ${qdbus_cmd} ${kdialog_dbus} /ProgressDialog Set org.kde.kdialog.ProgressDialog value 4

# Upgrade glibc. This allows some programs to work during the upgrade process.
${CMD_PACMAN_INSTALL[*]} glibc lib32-glibc

${CMD_PACMAN} -Q | grep -q libpamac-full
if [ $? -eq 0 ]; then
    echo "Replacing Pacmac with bauh..."
    # Do not remove dependencies to keep 'flatpak' and 'snapd' installed.
    # The first '--nodeps' tells Pacman to not remove dependencies.
    # The second '--nodeps' tells is to ignore the packages being required as a dependency for other applications.
    # 'discover' needs 'archlinux-appstream-data' so we will re-install it after this.
    ${CMD_PACMAN} -R -n --nodeps --nodeps --noconfirm archlinux-appstream-data-pamac libpamac-full pamac-all
    ${CMD_PACMAN_INSTALL[*]} archlinux-appstream-data
    ${CMD_YAY_INSTALL[*]} bauh
    rm -f /home/${WINESAPOS_USER_NAME}/Desktop/org.manjaro.pamac.manager.desktop
    cp /usr/share/applications/bauh.desktop /home/${WINESAPOS_USER_NAME}/Desktop/
    chmod +x /home/${WINESAPOS_USER_NAME}/Desktop/bauh.desktop
    chown 1000:1000 /home/${WINESAPOS_USER_NAME}/Desktop/bauh.desktop
    # Enable the 'snapd' service. This was not enabled in winesapOS <= 3.1.1.
    systemctl enable --now snapd
    echo "Replacing Pacmac with bauh complete."
fi
sudo -E -u ${WINESAPOS_USER_NAME} ${qdbus_cmd} ${kdialog_dbus} /ProgressDialog Set org.kde.kdialog.ProgressDialog value 5

grep -q tmpfs /etc/fstab
if [ $? -ne 0 ]; then
    echo "Switching volatile mounts from 'ramfs' to 'tmpfs' for compatibility with FUSE (used by AppImage and Flatpak packages)..."
    sed -i s'/ramfs/tmpfs/'g /etc/fstab
    echo "Switching volatile mounts from 'ramfs' to 'tmpfs' for compatibility with FUSE (used by AppImage and Flatpak packages) complete."
fi

if [[ "${WINESAPOS_DISTRO_DETECTED}" == "steamos" ]]; then
    # This is a new package in SteamOS 3.2 that will replace 'linux-firmware' which can lead to unbootable systems.
    # https://github.com/LukeShortCloud/winesapOS/issues/372
    grep -q linux-firmware-neptune-rtw-debug /etc/pacman.conf
    if [ $? -ne 0 ]; then
        echo "Ignoring the new conflicting linux-firmware-neptune-rtw-debug package..."
        sed -i s'/IgnorePkg = /IgnorePkg = linux-firmware-neptune-rtw-debug /'g /etc/pacman.conf
        echo "Ignoring the new conflicting linux-firmware-neptune-rtw-debug package complete."
    fi
fi

# Install ProtonUp-Qt as a Flatpak to avoid package conflicts when upgrading to Arch Linux packages.
# https://github.com/LukeShortCloud/winesapOS/issues/375#issuecomment-1146678638
${CMD_PACMAN} -Q | grep -q protonup-qt
if [ $? -eq 0 ]; then
    echo "Installing a newer version of ProtonUp-Qt..."
    ${CMD_PACMAN_REMOVE[*]} protonup-qt
    rm -f /home/${WINESAPOS_USER_NAME}/Desktop/net.davidotek.pupgui2.desktop
    ${CMD_FLATPAK_INSTALL[*]} net.davidotek.pupgui2
    cp /var/lib/flatpak/app/net.davidotek.pupgui2/current/active/export/share/applications/net.davidotek.pupgui2.desktop /home/${WINESAPOS_USER_NAME}/Desktop/
    chmod +x /home/${WINESAPOS_USER_NAME}/Desktop/net.davidotek.pupgui2.desktop
    chown 1000:1000 /home/${WINESAPOS_USER_NAME}/Desktop/net.davidotek.pupgui2.desktop
    echo "Installing a newer version of ProtonUp-Qt complete."
fi
sudo -E -u ${WINESAPOS_USER_NAME} ${qdbus_cmd} ${kdialog_dbus} /ProgressDialog Set org.kde.kdialog.ProgressDialog value 6

if [[ "${WINESAPOS_IMAGE_TYPE}" != "minimal" ]]; then
    ls -1 /etc/modules-load.d/ | grep -q winesapos-controllers.conf
    if [ $? -ne 0 ]; then
        echo "Installing Xbox controller support..."
        ${CMD_YAY_INSTALL[*]} xone-dkms-git
        touch /etc/modules-load.d/winesapos-controllers.conf
        echo -e "xone-wired\nxone-dongle\nxone-gip\nxone-gip-gamepad\nxone-gip-headset\nxone-gip-chatpad\nxone-gip-guitar" | tee /etc/modules-load.d/winesapos-controllers.conf
        for i in xone-wired xone-dongle xone-gip xone-gip-gamepad xone-gip-headset xone-gip-chatpad xone-gip-guitar;
            do modprobe --verbose $i
        done
        echo "Installing Xbox controller support complete."
    fi
fi
sudo -E -u ${WINESAPOS_USER_NAME} ${qdbus_cmd} ${kdialog_dbus} /ProgressDialog Set org.kde.kdialog.ProgressDialog value 7

if [[ "${WINESAPOS_IMAGE_TYPE}" != "minimal" ]]; then
    flatpak list | grep -P "^AntiMicroX" &> /dev/null
    if [ $? -ne 0 ]; then
        echo "Installing AntiMicroX for changing controller inputs..."
        ${CMD_FLATPAK_INSTALL[*]} io.github.antimicrox.antimicrox
        cp /var/lib/flatpak/app/io.github.antimicrox.antimicrox/current/active/export/share/applications/io.github.antimicrox.antimicrox.desktop /home/${WINESAPOS_USER_NAME}/Desktop/
        chmod +x /home/${WINESAPOS_USER_NAME}/Desktop/io.github.antimicrox.antimicrox.desktop
        chown 1000:1000 /home/${WINESAPOS_USER_NAME}/Desktop/io.github.antimicrox.antimicrox.desktop
        echo "Installing AntiMicroX for changing controller inputs complete."
    fi
fi
sudo -E -u ${WINESAPOS_USER_NAME} ${qdbus_cmd} ${kdialog_dbus} /ProgressDialog Set org.kde.kdialog.ProgressDialog value 8

if [[ "${XDG_CURRENT_DESKTOP}" -eq "KDE" ]]; then
    if [ ! -f /usr/bin/kate ]; then
        echo "Installing the simple text editor 'kate'...."
        ${CMD_PACMAN_INSTALL[*]} kate
        echo "Installing the simple text editor 'kate' complete."
    fi
elif [[ "${XDG_CURRENT_DESKTOP}" -eq "X-Cinnamon" ]]; then
    if [ ! -f /usr/bin/xed ]; then
        echo "Installing the simple text editor 'xed'..."
        ${CMD_PACMAN_INSTALL[*]} xed
        echo "Installing the simple text editor 'xed' complete."
    fi
fi
sudo -E -u ${WINESAPOS_USER_NAME} ${qdbus_cmd} ${kdialog_dbus} /ProgressDialog Set org.kde.kdialog.ProgressDialog value 9

${CMD_PACMAN} -Q | grep -q linux-firmware-neptune
if [ $? -eq 0 ]; then
    echo "Removing conflicting 'linux-firmware-neptune' packages..."
    ${CMD_PACMAN} -Q linux-firmware-neptune &> /dev/null
    if [ $? -eq 0 ]; then
        ${CMD_PACMAN_REMOVE[*]} linux-firmware-neptune
    fi
    ${CMD_PACMAN} -Q linux-firmware-neptune-rtw-debug &> /dev/null
    if [ $? -eq 0 ]; then
        ${CMD_PACMAN_REMOVE[*]} linux-firmware-neptune-rtw-debug
    fi
    ${CMD_PACMAN_INSTALL[*]} linux-firmware
    echo "Removing conflicting 'linux-firmware-neptune' packages complete."
fi
sudo -E -u ${WINESAPOS_USER_NAME} ${qdbus_cmd} ${kdialog_dbus} /ProgressDialog Set org.kde.kdialog.ProgressDialog value 10

echo "Upgrading to 'clang' from Arch Linux..."
${CMD_PACMAN} -Q | grep -q clang-libs
if [ $? -eq 0 ]; then
    # SteamOS 3 splits 'clang' (64-bit) into two packages: (1) 'clang' and (2) 'clang-libs'.
    # It does not ship a 'lib32-clang' package.
    ${CMD_PACMAN} -R -d --nodeps --noconfirm clang clang-libs
fi
# Arch Linux has a 'clang' and 'lib32-clang' package.
${CMD_PACMAN_INSTALL[*]} clang lib32-clang
echo "Upgrading to 'clang' from Arch Linux complete."
sudo -E -u ${WINESAPOS_USER_NAME} ${qdbus_cmd} ${kdialog_dbus} /ProgressDialog Set org.kde.kdialog.ProgressDialog value 11

echo "Running 3.0.1 to 3.1.0 upgrades complete."
sudo -E -u ${WINESAPOS_USER_NAME} ${qdbus_cmd} ${kdialog_dbus} /ProgressDialog org.kde.kdialog.ProgressDialog.close

echo "Running 3.1.0 to 3.1.1 upgrades..."
kdialog_dbus=$(sudo -E -u ${WINESAPOS_USER_NAME} kdialog --title "winesapOS Upgrade" --progressbar "Running 3.1.0 to 3.1.1 upgrades..." 2 | cut -d" " -f1)
sudo -E -u ${WINESAPOS_USER_NAME} ${qdbus_cmd} ${kdialog_dbus} /ProgressDialog showCancelButton false
sudo -E -u ${WINESAPOS_USER_NAME} ${qdbus_cmd} ${kdialog_dbus} /ProgressDialog Set org.kde.kdialog.ProgressDialog value 1

${CMD_PACMAN} -Q | grep -q pipewire-media-session
if [ $? -eq 0 ]; then
    ${CMD_PACMAN} -R -d --nodeps --noconfirm pipewire-media-session
    ${CMD_PACMAN_INSTALL[*]} wireplumber
fi

grep -q -P "^GRUB_THEME=/boot/grub/themes/Vimix/theme.txt" /etc/default/grub
if [ $? -ne 0 ]; then
    ${CMD_PACMAN_INSTALL[*]} grub-theme-vimix
    ## This theme needs to exist in the '/boot/' mount because if the root file system is encrypted, then the theme cannot be found.
    mkdir -p /boot/grub/themes/
    cp -R /usr/share/grub/themes/Vimix /boot/grub/themes/Vimix
    crudini --set /etc/default/grub "" GRUB_THEME /boot/grub/themes/Vimix/theme.txt
    ## Target 720p for the GRUB menu as a minimum to support devices such as the GPD Win.
    ## https://github.com/LukeShortCloud/winesapOS/issues/327
    crudini --set /etc/default/grub "" GRUB_GFXMODE 1280x720,auto
    ## Setting the GFX payload to 'text' instead 'keep' makes booting more reliable by supporting all graphics devices.
    ## https://github.com/LukeShortCloud/winesapOS/issues/327
    crudini --set /etc/default/grub "" GRUB_GFXPAYLOAD_LINUX text
    # Remove the whitespace from the 'GRUB_* = ' lines that 'crudini' creates.
    sed -i -r "s/(\S*)\s*=\s*(.*)/\1=\2/g" /etc/default/grub
fi
echo "Running 3.1.0 to 3.1.1 upgrades complete."
sudo -E -u ${WINESAPOS_USER_NAME} ${qdbus_cmd} ${kdialog_dbus} /ProgressDialog org.kde.kdialog.ProgressDialog.close

echo "Running 3.1.1 to 3.2.0 upgrades..."
kdialog_dbus=$(sudo -E -u ${WINESAPOS_USER_NAME} kdialog --title "winesapOS Upgrade" --progressbar "Running 3.1.1 to 3.2.0 upgrades..." 5 | cut -d" " -f1)
sudo -E -u ${WINESAPOS_USER_NAME} ${qdbus_cmd} ${kdialog_dbus} /ProgressDialog showCancelButton false
sudo -E -u ${WINESAPOS_USER_NAME} ${qdbus_cmd} ${kdialog_dbus} /ProgressDialog Set org.kde.kdialog.ProgressDialog value 1

if [[ "${WINESAPOS_DISTRO_DETECTED}" == "steamos" ]]; then
    ${CMD_PACMAN} -Q | grep -q linux-steamos
    if [ $? -ne 0 ]; then
        ${CMD_PACMAN} -R -d --nodeps --noconfirm linux-neptune linux-neptune-headers
        ${CMD_PACMAN_INSTALL[*]} linux linux-headers
    fi
fi
sudo -E -u ${WINESAPOS_USER_NAME} ${qdbus_cmd} ${kdialog_dbus} /ProgressDialog Set org.kde.kdialog.ProgressDialog value 2

if [[ "${WINESAPOS_IMAGE_TYPE}" != "minimal" ]]; then
    flatpak list | grep -P "^Flatseal" &> /dev/null
    if [ $? -ne 0 ]; then
        ${CMD_FLATPAK_INSTALL[*]} com.github.tchx84.Flatseal
        cp /var/lib/flatpak/app/com.github.tchx84.Flatseal/current/active/export/share/applications/com.github.tchx84.Flatseal.desktop /home/${WINESAPOS_USER_NAME}/Desktop/
        chmod +x /home/${WINESAPOS_USER_NAME}/Desktop/com.github.tchx84.Flatseal.desktop
        chown 1000:1000 /home/${WINESAPOS_USER_NAME}/Desktop/com.github.tchx84.Flatseal.desktop
    fi
fi
sudo -E -u ${WINESAPOS_USER_NAME} ${qdbus_cmd} ${kdialog_dbus} /ProgressDialog Set org.kde.kdialog.ProgressDialog value 3

${CMD_PACMAN} -Q | grep -q game-devices-udev
if [ $? -eq 0 ]; then
    sudo -u ${WINESAPOS_USER_NAME} yay --pacman ${CMD_PACMAN} --noconfirm -S --removemake game-devices-udev
fi
sudo -E -u ${WINESAPOS_USER_NAME} ${qdbus_cmd} ${kdialog_dbus} /ProgressDialog Set org.kde.kdialog.ProgressDialog value 4

if [[ "${WINESAPOS_DISTRO_DETECTED}" == "steamos" ]]; then
    # If holo-rel/filesystem is replaced by core/filesystem during an upgrade it can break UEFI boot.
    # https://github.com/LukeShortCloud/winesapOS/issues/514
    grep -P ^IgnorePkg /etc/pacman.conf  | grep -q filesystem
    if [ $? -ne 0 ]; then
        echo "Ignoring the conflicting 'filesystem' package..."
        sed -i s'/IgnorePkg = /IgnorePkg = filesystem /'g /etc/pacman.conf
        echo "Ignoring the conflicting 'filesystem' package complete."
    fi
fi

echo "Running 3.1.1 to 3.2.0 upgrades complete."
sudo -E -u ${WINESAPOS_USER_NAME} ${qdbus_cmd} ${kdialog_dbus} /ProgressDialog org.kde.kdialog.ProgressDialog.close

echo "Running 3.2.0 to 3.2.1 upgrades..."
echo "Switching Steam back to the 'stable' update channel..."
rm -f /home/${WINESAPOS_USER_NAME}/.local/share/Steam/package/beta
echo "Switching Steam back to the 'stable' update channel complete."
echo "Running 3.2.0 to 3.2.1 upgrades complete."

echo "Running 3.2.1 to 3.3.0 upgrades..."
kdialog_dbus=$(sudo -E -u ${WINESAPOS_USER_NAME} kdialog --title "winesapOS Upgrade" --progressbar "Running 3.2.1 to 3.3.0 upgrades..." 13 | cut -d" " -f1)
sudo -E -u ${WINESAPOS_USER_NAME} ${qdbus_cmd} ${kdialog_dbus} /ProgressDialog showCancelButton false
echo "Setting up default text editor..."
grep -q "EDITOR=nano" /etc/environment
if [ $? -eq 0 ]; then
    echo "Default text editor already set. Skipping..."
else
    echo "Default text editor not already set. Proceeding..."
    echo "EDITOR=nano" >> /etc/environment
fi
echo "Setting up default text editor complete."
sudo -E -u ${WINESAPOS_USER_NAME} ${qdbus_cmd} ${kdialog_dbus} /ProgressDialog Set org.kde.kdialog.ProgressDialog value 1

echo "Switching to the new 'plasma5-themes-vapor-steamos' package..."
${CMD_PACMAN} -Q steamdeck-kde-presets
if [ $? -eq 0 ]; then
    echo "Old 'steamdeck-kde-presets' package detected. Proceeding..."
    rm -f /usr/share/libalpm/hooks/steamdeck-kde-presets.hook
    ${CMD_PACMAN} -R -n --noconfirm steamdeck-kde-presets
    ${CMD_YAY_INSTALL[*]} plasma5-themes-vapor-steamos
    # Force update "konsole" to get the /etc/xdg/konsolerc file it provides.
    rm -f /etc/xdg/konsolerc
    ${CMD_PACMAN} -S --noconfirm konsole
else
    echo "Old 'steamdeck-kde-presets' package not detected. Skipping..."
fi
echo "Switching to the new 'plasma5-themes-vapor-steamos' package complete."
sudo -E -u ${WINESAPOS_USER_NAME} ${qdbus_cmd} ${kdialog_dbus} /ProgressDialog Set org.kde.kdialog.ProgressDialog value 2

echo "Switching to the new 'libpipewire' package..."
${CMD_PACMAN} -Q pipewire
if [ $? -eq 0 ]; then
    echo "Old 'pipewire' package detected. Proceeding..."
    ${CMD_PACMAN} -R -n --nodeps --nodeps --noconfirm pipewire lib32-pipewire
    ${CMD_PACMAN_INSTALL[*]} libpipewire lib32-libpipewire
else
    echo "Old 'pipewire' package not detected. Skipping..."
fi
echo "Switching to the new 'libpipewire' package complete."
sudo -E -u ${WINESAPOS_USER_NAME} ${qdbus_cmd} ${kdialog_dbus} /ProgressDialog Set org.kde.kdialog.ProgressDialog value 3

echo "Limiting the number of Snapper backups..."
ls /etc/systemd/system/snapper-cleanup-hourly.timer
if [ $? -ne 0 ]; then
    sed -i s'/TIMELINE_LIMIT_HOURLY=.*/TIMELINE_LIMIT_HOURLY="10"/'g /etc/snapper/configs/root
    sed -i s'/TIMELINE_LIMIT_HOURLY=.*/TIMELINE_LIMIT_HOURLY="10"/'g /etc/snapper/configs/home
    cat <<EOF > /etc/systemd/system/snapper-cleanup-hourly.timer
[Unit]
Description=Hourly Cleanup of Snapper Snapshots
Documentation=man:snapper(8) man:snapper-configs(5)

[Timer]
OnCalendar=hourly
Persistent=true
Unit=snapper-cleanup.timer

[Install]
WantedBy=timers.target
EOF
    systemctl daemon-reload
    systemctl disable --now snapper-cleanup.timer
    systemctl enable --now snapper-cleanup-hourly.timer
    systemctl restart snapper-timeline.timer
fi
echo "Limiting the number of Snapper backups complete."
sudo -E -u ${WINESAPOS_USER_NAME} ${qdbus_cmd} ${kdialog_dbus} /ProgressDialog Set org.kde.kdialog.ProgressDialog value 4

echo "Setting 'iwd' as the backend for NetworkManager..."
echo -e "[device]\nwifi.backend=iwd" > /etc/NetworkManager/conf.d/wifi_backend.conf
systemctl disable wpa_supplicant
echo "Setting 'iwd' as the backend for NetworkManager complete."

# The extra 'grep' at the end is to only grab the numbers.
# Otherwise, there are invisible special characters in front which cause the float comparison to fail.
YAY_CURRENT_VER=$(yay --version | cut -d" " -f2 | cut -dv -f2 | cut -d. -f1,2 | grep -o -P "[0-9]+.[0-9]+")
# If the expression is true, it returns a '1'. If the expression is false, it returns '0'.
yay_ver_comparison=$(expr "${YAY_CURRENT_VER}" '<=' "11.1")
if [ "${yay_ver_comparison}" -eq 1 ]; then
    # Check to see if 'yay' or 'yay-git' is installed already.
    ${CMD_PACMAN} -Q | grep -q -P "^yay"
    if [ $? -ne 0 ]; then
        echo "Replacing a manual installation of 'yay' with a package installation..."
        mv /usr/bin/yay /usr/local/bin/yay
        hash -r
        ${CMD_YAY_INSTALL[*]} yay
        if [ $? -eq 0 ]; then
            rm -f /usr/local/bin/yay
	fi
        echo "Replacing a manual installation of 'yay' with a package installation complete."
    fi
fi
sudo -E -u ${WINESAPOS_USER_NAME} ${qdbus_cmd} ${kdialog_dbus} /ProgressDialog Set org.kde.kdialog.ProgressDialog value 5

${CMD_PACMAN} -Q | grep appimagepool-appimage
if [ $? -ne 0 ]; then
    echo "Adding the AppImagePool package manager..."
    ${CMD_YAY_INSTALL[*]} appimagelauncher appimagepool-appimage
    cp /usr/share/applications/appimagepool.desktop /home/${WINESAPOS_USER_NAME}/Desktop/
    chmod +x /home/${WINESAPOS_USER_NAME}/Desktop/appimagepool.desktop
    chown 1000:1000 /home/${WINESAPOS_USER_NAME}/Desktop/appimagepool.desktop
    echo "Adding the AppImagePool package manager complete."
fi
sudo -E -u ${WINESAPOS_USER_NAME} ${qdbus_cmd} ${kdialog_dbus} /ProgressDialog Set org.kde.kdialog.ProgressDialog value 6

${CMD_PACMAN} -Q | grep cifs-utils
if [ $? -ne 0 ]; then
    echo "Adding support for the CIFS/SMB file system..."
    ${CMD_PACMAN_INSTALL[*]} cifs-utils
    echo "Adding support for the CIFS/SMB file system done."
fi
${CMD_PACMAN} -Q | grep nfs-utils
if [ $? -ne 0 ]; then
    echo "Adding support for the NFS file system..."
    ${CMD_PACMAN_INSTALL[*]} nfs-utils
    echo "Adding support for the NFS file system done."
fi
sudo -E -u ${WINESAPOS_USER_NAME} ${qdbus_cmd} ${kdialog_dbus} /ProgressDialog Set org.kde.kdialog.ProgressDialog value 7

${CMD_PACMAN} -Q | grep erofs-utils
if [ $? -ne 0 ]; then
    echo "Adding support for the EROFS file system..."
    ${CMD_PACMAN_INSTALL[*]} erofs-utils
    echo "Adding support for the EROFS file system done."
fi
sudo -E -u ${WINESAPOS_USER_NAME} ${qdbus_cmd} ${kdialog_dbus} /ProgressDialog Set org.kde.kdialog.ProgressDialog value 8

${CMD_PACMAN} -Q | grep f2fs-tools
if [ $? -ne 0 ]; then
    echo "Adding support for the F2FS file system..."
    ${CMD_PACMAN_INSTALL[*]} f2fs-tools
    echo "Adding support for the F2FS file system done."
fi
sudo -E -u ${WINESAPOS_USER_NAME} ${qdbus_cmd} ${kdialog_dbus} /ProgressDialog Set org.kde.kdialog.ProgressDialog value 9

${CMD_PACMAN} -Q | grep ssdfs-tools
if [ $? -ne 0 ]; then
    echo "Adding support for the SSDFS file system..."
    ${CMD_YAY_INSTALL[*]} ssdfs-tools
    echo "Adding support for the SSDFS file system done."
fi
sudo -E -u ${WINESAPOS_USER_NAME} ${qdbus_cmd} ${kdialog_dbus} /ProgressDialog Set org.kde.kdialog.ProgressDialog value 10

${CMD_PACMAN} -Q | grep mtools
if [ $? -ne 0 ]; then
    echo "Adding improved support for FAT file systems..."
    ${CMD_PACMAN_INSTALL[*]} mtools
    echo "Adding improved support for FAT file systems done."
fi
sudo -E -u ${WINESAPOS_USER_NAME} ${qdbus_cmd} ${kdialog_dbus} /ProgressDialog Set org.kde.kdialog.ProgressDialog value 11

${CMD_PACMAN} -Q | grep reiserfsprogs
if [ $? -ne 0 ]; then
    echo "Adding support for the ReiserFS file system..."
    # 'cmake' is required to build 'reiserfs-defrag' but is not installed with 'base-devel'.
    ${CMD_PACMAN_INSTALL[*]} reiserfsprogs cmake
    ${CMD_YAY_INSTALL[*]} reiserfs-defrag
    echo "Adding support for the ReiserFS file system done."
fi
sudo -E -u ${WINESAPOS_USER_NAME} ${qdbus_cmd} ${kdialog_dbus} /ProgressDialog Set org.kde.kdialog.ProgressDialog value 12

${CMD_PACMAN} -Q mangohud-common
if [ $? -eq 0 ]; then
    echo "Updating MangoHud to the new package names..."
    ${CMD_PACMAN} -R -n --nodeps --nodeps --noconfirm mangohud-common mangohud lib32-mangohud
    ${CMD_PACMAN_INSTALL[*]} mangohud lib32-mangohud
    echo "Updating MangoHud to the new package names complete."
fi

sudo -E -u ${WINESAPOS_USER_NAME} ${qdbus_cmd} ${kdialog_dbus} /ProgressDialog org.kde.kdialog.ProgressDialog.close
echo "Running 3.2.1 to 3.3.0 upgrades complete."

echo "Running 3.3.0 to 3.4.0 upgrades..."
kdialog_dbus=$(sudo -E -u ${WINESAPOS_USER_NAME} kdialog --title "winesapOS Upgrade" --progressbar "Running 3.3.0 to 3.4.0 upgrades..." 11 | cut -d" " -f1)
sudo -E -u ${WINESAPOS_USER_NAME} ${qdbus_cmd} ${kdialog_dbus} /ProgressDialog showCancelButton false
# Check to see if Electron from the AUR is installed.
# It is a dependency of balena-etcher but takes along
# time and a lot of disk space to compile.
${CMD_PACMAN} -Q | grep -P "^electron[0-9]+"
if [ $? -eq 0 ]; then
    ${CMD_PACMAN_REMOVE[*]} balena-etcher
    export ETCHER_VER="1.18.11"
    wget "https://github.com/balena-io/etcher/releases/download/v${ETCHER_VER}/balenaEtcher-${ETCHER_VER}-x64.AppImage" -O /home/${WINESAPOS_USER_NAME}/Desktop/balenaEtcher.AppImage
    chmod +x /home/${WINESAPOS_USER_NAME}/Desktop/balenaEtcher.AppImage
    rm -f /home/${WINESAPOS_USER_NAME}/Desktop/balena-etcher-electron.desktop
fi
sudo -E -u ${WINESAPOS_USER_NAME} ${qdbus_cmd} ${kdialog_dbus} /ProgressDialog Set org.kde.kdialog.ProgressDialog value 1

${CMD_PACMAN} -Q fprintd
if [ $? -ne 0 ]; then
    ${CMD_PACMAN_INSTALL[*]} fprintd
fi
sudo -E -u ${WINESAPOS_USER_NAME} ${qdbus_cmd} ${kdialog_dbus} /ProgressDialog Set org.kde.kdialog.ProgressDialog value 2

ls /home/deck
if [ $? -ne 0 ]; then
    ln -s /home/winesap /home/deck
fi

${CMD_PACMAN} -Q plasma-wayland-session
if [ $? -ne 0 ]; then
    echo "Adding Wayland support..."
    ${CMD_PACMAN_INSTALL[*]} plasma-wayland-session
    echo "Adding Wayland support complete."
fi
sudo -E -u ${WINESAPOS_USER_NAME} ${qdbus_cmd} ${kdialog_dbus} /ProgressDialog Set org.kde.kdialog.ProgressDialog value 3

${CMD_PACMAN} -Q python-crudini
if [ $? -eq 0 ]; then
    echo "Replacing 'python-crudini' with the newer 'crudini'..."
    ${CMD_PACMAN_REMOVE[*]} python-crudini
    # Use the '${CMD_YAY_INSTALL[*]}' without the '--needed' argument to force re-install 'python-iniparse'.
    sudo -u ${WINESAPOS_USER_NAME} yay --pacman ${CMD_PACMAN} --noconfirm -S --removemake crudini python-iniparse
    echo "Replacing 'python-crudini' with the newer 'crudini' complete."
fi
sudo -E -u ${WINESAPOS_USER_NAME} ${qdbus_cmd} ${kdialog_dbus} /ProgressDialog Set org.kde.kdialog.ProgressDialog value 4

ls /etc/systemd/system/winesapos-touch-bar-usbmuxd-fix.service
if [ $? -eq 0 ]; then
    echo "Upgrading usbmuxd to work with iPhone devices again even with T2 Mac drivers..."
    systemctl disable --now winesapos-touch-bar-usbmuxd-fix
    rm -f /etc/systemd/system/winesapos-touch-bar-usbmuxd-fix.service
    systemctl daemon-reload
    rm -f /usr/local/bin/winesapos-touch-bar-usbmuxd-fix.sh
    rm -f /usr/lib/udev/rules.d/39-usbmuxd.rules
    wget "https://raw.githubusercontent.com/libimobiledevice/usbmuxd/master/udev/39-usbmuxd.rules.in" -O /usr/lib/udev/rules.d/39-usbmuxd.rules
    echo "Upgrading usbmuxd to work with iPhone devices again even with T2 Mac drivers complete."
fi

systemctl --quiet is-enabled iwd
if [ $? -eq 0 ]; then
    echo "Disabling iwd for better NetworkManager compatibility..."
    # Do not disable '--now' because that would interrupt network connections.
    systemctl disable iwd
    echo "Disabling iwd for better NetworkManager compatibility done."
fi
sudo -E -u ${WINESAPOS_USER_NAME} ${qdbus_cmd} ${kdialog_dbus} /ProgressDialog Set org.kde.kdialog.ProgressDialog value 5

if [[ "${WINESAPOS_IMAGE_TYPE}" != "minimal" ]]; then
    ${CMD_PACMAN} -Q gamescope-session-git
    if [ $? -ne 0 ]; then
        echo "Adding Gamescope Session support..."
        ${CMD_YAY_INSTALL[*]} gamescope-session-git gamescope-session-steam-git
        echo "Adding Gamescope Session support complete."
    fi

    ${CMD_PACMAN} -Q opengamepadui-bin
    if [ $? -ne 0 ]; then
        echo "Adding Open Gamepad UI..."
        ${CMD_YAY_INSTALL[*]} opengamepadui-bin opengamepadui-session-git
        echo "Adding Open Gamepad UI complete."
    fi
fi
sudo -E -u ${WINESAPOS_USER_NAME} ${qdbus_cmd} ${kdialog_dbus} /ProgressDialog Set org.kde.kdialog.ProgressDialog value 6

${CMD_PACMAN} -Q jfsutils
if [ $? -ne 0 ]; then
    ${CMD_PACMAN_INSTALL[*]} jfsutils
fi
sudo -E -u ${WINESAPOS_USER_NAME} ${qdbus_cmd} ${kdialog_dbus} /ProgressDialog Set org.kde.kdialog.ProgressDialog value 7

if [[ "${WINESAPOS_IMAGE_TYPE}" != "minimal" ]]; then
    ${CMD_PACMAN} -Q openrazer-daemon
    if [ $? -ne 0 ]; then
        ${CMD_PACMAN_INSTALL[*]} openrazer-daemon openrazer-driver-dkms python-pyqt5 python-openrazer razercfg
        sudo gpasswd -a ${WINESAPOS_USER_NAME} plugdev
        systemctl enable --now razerd
        cp /usr/share/applications/razercfg.desktop /home/${WINESAPOS_USER_NAME}/Desktop/
        chmod +x /home/${WINESAPOS_USER_NAME}/Desktop/razercfg.desktop
    fi
fi
sudo -E -u ${WINESAPOS_USER_NAME} ${qdbus_cmd} ${kdialog_dbus} /ProgressDialog Set org.kde.kdialog.ProgressDialog value 8

${CMD_PACMAN} -Q vapor-steamos-theme-kde
if [ $? -eq 0 ]; then
    ${CMD_PACMAN_REMOVE[*]} vapor-steamos-theme-kde
    ${CMD_YAY_INSTALL[*]} plasma5-themes-vapor-steamos
fi
sudo -E -u ${WINESAPOS_USER_NAME} ${qdbus_cmd} ${kdialog_dbus} /ProgressDialog Set org.kde.kdialog.ProgressDialog value 9

if [[ "${WINESAPOS_IMAGE_TYPE}" != "minimal" ]]; then
    ${CMD_PACMAN} -Q oversteer
    if [ $? -ne 0 ]; then
        ${CMD_YAY_INSTALL[*]} oversteer
        cp /usr/share/applications/org.berarma.Oversteer.desktop /home/${WINESAPOS_USER_NAME}/Desktop/
        chmod +x /home/${WINESAPOS_USER_NAME}/Desktop/org.berarma.Oversteer.desktop
    fi
fi
sudo -E -u ${WINESAPOS_USER_NAME} ${qdbus_cmd} ${kdialog_dbus} /ProgressDialog Set org.kde.kdialog.ProgressDialog value 10

# Use the new Java Development Kit packages.
# https://archlinux.org/news/incoming-changes-in-jdk-jre-21-packages-may-require-manual-intervention/
for java_edition in jdk jre
    do for java_ver in "" 17 11 8
        do for java_headless in "" -headless
            do pacman -Q ${java_edition}${java_ver}-openjdk${java_headless}
            if [ $? -eq 0 ]; then
                yes | ${CMD_PACMAN} -S ${java_edition}${java_ver}-openjdk${java_headless}
            fi
        done
    done
done

${CMD_PACMAN} -Q lightdm
if [ $? -eq 0 ]; then
    if [ ! -f /etc/systemd/system/lightdm.service.d/lightdm-restart-policy.conf ]; then
        mkdir -p /etc/systemd/system/lightdm.service.d/
        wget "https://raw.githubusercontent.com/LukeShortCloud/winesapOS/stable/files/lightdm-restart-policy.conf" -O /etc/systemd/system/lightdm.service.d/lightdm-restart-policy.conf
        wget "https://raw.githubusercontent.com/LukeShortCloud/winesapOS/stable/files/lightdm-failure-handler.service" -O /etc/systemd/system/lightdm-failure-handler.service
        wget "https://raw.githubusercontent.com/LukeShortCloud/winesapOS/stable/files/lightdm-success-handler.service" -O /etc/systemd/system/lightdm-success-handler.service
        systemctl daemon-reload
        systemctl enable lightdm-success-handler
    fi
fi
sudo -E -u ${WINESAPOS_USER_NAME} ${qdbus_cmd} ${kdialog_dbus} /ProgressDialog org.kde.kdialog.ProgressDialog.close
echo "Running 3.3.0 to 3.4.0 upgrades complete."

echo "Running 3.4.0 to 4.0.0 upgrades..."
kdialog_dbus=$(sudo -E -u ${WINESAPOS_USER_NAME} kdialog --title "winesapOS Upgrade" --progressbar "Running 3.4.0 to 4.0.0 upgrades..." 8 | cut -d" " -f1)
sudo -E -u ${WINESAPOS_USER_NAME} ${qdbus_cmd} ${kdialog_dbus} /ProgressDialog showCancelButton false
sed -i s'/options amdgpu sg_display=0//'g /etc/modprobe.d/winesapos-amd.conf

dmidecode -s system-product-name | grep -P ^Mac
if [ $? -ne 0 ]; then
    echo "No Mac hardware detected."
    echo "Re-enabling EFI variables..."
    sed -i s'/efi=noruntime //'g /etc/default/grub
fi

${CMD_PACMAN} -Q firefox-esr-bin
if [ $? -eq 0 ]; then
    ${CMD_PACMAN_REMOVE[*]} firefox-esr-bin
    ${CMD_PACMAN_INSTALL[*]} firefox-esr
fi
sudo -E -u ${WINESAPOS_USER_NAME} ${qdbus_cmd} ${kdialog_dbus} /ProgressDialog Set org.kde.kdialog.ProgressDialog value 1

${CMD_PACMAN} -Q mangohud
if [ $? -eq 0 ]; then
    ${CMD_PACMAN_REMOVE[*]} mangohud lib32-mangohud goverlay
    ${CMD_PACMAN_INSTALL[*]} mangohud-git lib32-mangohud-git goverlay-git
fi
sudo -E -u ${WINESAPOS_USER_NAME} ${qdbus_cmd} ${kdialog_dbus} /ProgressDialog Set org.kde.kdialog.ProgressDialog value 2

${CMD_PACMAN} -Q bcachefs-tools
if [ $? -ne 0 ]; then
    ${CMD_PACMAN} -Q bcachefs-tools-git
    if [ $? -eq 0 ]; then
        ${CMD_PACMAN_REMOVE[*]} linux-bcachefs-git linux-bcachefs-git-headers bcachefs-tools-git
    fi
    ${CMD_PACMAN_INSTALL[*]} bcachefs-tools
fi
sudo -E -u ${WINESAPOS_USER_NAME} ${qdbus_cmd} ${kdialog_dbus} /ProgressDialog Set org.kde.kdialog.ProgressDialog value 3

if [[ "${WINESAPOS_IMAGE_TYPE}" != "minimal" ]]; then
    ${CMD_PACMAN} -Q distrobox
    if [ $? -ne 0 ]; then
        ${CMD_PACMAN_INSTALL[*]} distrobox podman
    fi
fi
sudo -E -u ${WINESAPOS_USER_NAME} ${qdbus_cmd} ${kdialog_dbus} /ProgressDialog Set org.kde.kdialog.ProgressDialog value 4

${CMD_PACMAN} -Q gfs2-utils
if [ $? -ne 0 ]; then
    ${CMD_YAY_INSTALL[*]} gfs2-utils
fi
sudo -E -u ${WINESAPOS_USER_NAME} ${qdbus_cmd} ${kdialog_dbus} /ProgressDialog Set org.kde.kdialog.ProgressDialog value 5

${CMD_PACMAN} -Q glusterfs
if [ $? -ne 0 ]; then
    ${CMD_PACMAN_INSTALL[*]} glusterfs
fi
sudo -E -u ${WINESAPOS_USER_NAME} ${qdbus_cmd} ${kdialog_dbus} /ProgressDialog Set org.kde.kdialog.ProgressDialog value 6

${CMD_PACMAN} -Q ceph-bin
if [ $? -ne 0 ]; then
    ${CMD_YAY_INSTALL[*]} ceph-libs-bin ceph-bin
fi
sudo -E -u ${WINESAPOS_USER_NAME} ${qdbus_cmd} ${kdialog_dbus} /ProgressDialog Set org.kde.kdialog.ProgressDialog value 7

grep -q -P "^precedence ::ffff:0:0/96  100$" /etc/gai.conf
if [ $? -ne 0 ]; then
    echo "label  ::1/128       0
label  ::/0          1
label  2002::/16     2
label ::/96          3
label ::ffff:0:0/96  4
precedence  ::1/128       50
precedence  ::/0          40
precedence  2002::/16     30
precedence ::/96          20
precedence ::ffff:0:0/96  100" > /etc/gai.conf
fi

grep -P -q "^fs.file-max=524288" /etc/sysctl.d/00-winesapos.conf 2> /dev/null
if [ $? -ne 0 ]; then
    echo "vm.max_map_count=16777216
fs.file-max=524288" >> /etc/sysctl.d/00-winesapos.conf
fi

grep -P -q "^DefaultLimitNOFILE=524288" /etc/systemd/system.conf.d/20-file-limits.conf 2> /dev/null
if [ $? -ne 0 ]; then
    mkdir -p /etc/systemd/system.conf.d/
    echo "[Manager]
DefaultLimitNOFILE=524288" > /etc/systemd/system.conf.d/20-file-limits.conf
fi

if (${CMD_PACMAN} -Q mesa && ${CMD_PACMAN} -Q opencl-mesa-steamos); then
    ${CMD_PACMAN_REMOVE[*]} opencl-mesa-steamos lib32-opencl-mesa-steamos
    ${CMD_PACMAN_INSTALL[*]} opencl-rusticl-mesa lib32-opencl-rusticl-mesa
fi

sudo -E -u ${WINESAPOS_USER_NAME} ${qdbus_cmd} ${kdialog_dbus} /ProgressDialog org.kde.kdialog.ProgressDialog.close
echo "Running 3.4.0 to 4.0.0 upgrades complete."

echo "Running 4.0.0 to 4.1.0 upgrades..."

${CMD_PACMAN} -Q packagekit-qt6
if [ $? -ne 0 ]; then
    # These packages have been removed in KDE Plasma 6.
    # https://github.com/LukeShortCloud/winesapOS/issues/742
    # We no longer want to install PackageKit, either.
    # https://github.com/LukeShortCloud/winesapOS/issues/827
    ${CMD_PACMAN_REMOVE[*]} packagekit-qt5 plasma-wayland-session
    # Enable Wayland support for the official NVIDIA drivers.
    ${CMD_PACMAN} -Q | grep -q -P "^nvidia"
    if [ $? -eq 0 ]; then
        grep "nvidia_drm.modeset=1" /etc/default/grub
        if [ $? -ne 0 ]; then
            sed -i s'/GRUB_CMDLINE_LINUX="/GRUB_CMDLINE_LINUX="nvidia_drm.modeset=1 /'g /etc/default/grub
        fi
    fi
fi

grep "mem_sleep_default=deep" /etc/default/grub
if [ $? -ne 0 ]; then
    echo "Change the default sleep level to be S3 deep sleep..."
    sed -i s'/GRUB_CMDLINE_LINUX="/GRUB_CMDLINE_LINUX="mem_sleep_default=deep /'g /etc/default/grub
fi

${CMD_PACMAN} -Q modem-manager-gui
if [ $? -ne 0 ]; then
    ${CMD_PACMAN_INSTALL[*]} modem-manager-gui usb_modeswitch
fi

grep -q kyber /etc/udev/rules.d/60-winesapos-io-schedulers.rules
if [ $? -ne 0 ]; then
    echo -n "Enabling that optimal IO schedulers..."
    echo '# Serial drives and SD cards.
ACTION=="add|change", KERNEL=="sd[a-z]*|mmcblk[0-9]*", ATTR{queue/scheduler}="bfq"

# NVMe drives.
ACTION=="add|change", KERNEL=="nvme[0-9]*", ATTR{queue/scheduler}="kyber"' > /etc/udev/rules.d/60-winesapos-io-schedulers.rules
fi

# Delete our old session override to ensure that the Plasma Wayland session is used for KDE Plasma >= 6.
grep -q "XSession=plasma" /var/lib/AccountsService/users/${WINESAPOS_USER_NAME}
if [ $? -eq 0 ]; then
    rm -f /var/lib/AccountsService/users/${WINESAPOS_USER_NAME}
fi

${CMD_PACMAN} -Q linux-fsync-nobara-bin
if [ $? -ne 0 ]; then
    ${CMD_YAY_INSTALL[*]} linux-fsync-nobara-bin
fi

${CMD_PACMAN} -Q steamdeck-dsp
if [ $? -eq 0 ]; then
    ${CMD_PACMAN} -Q linux-firmware-valve
    if [ $? -ne 0 ]; then
        ${CMD_PACMAN_INSTALL[*]} linux-firmware-valve
    fi
fi

echo "Running 4.0.0 to 4.1.0 upgrades complete."

echo "Upgrading system packages..."
kdialog_dbus=$(sudo -E -u ${WINESAPOS_USER_NAME} kdialog --title "winesapOS Upgrade" --progressbar "Please wait for all system packages to upgrade (this can take a long time)..." 11 | cut -d" " -f1)
sudo -E -u ${WINESAPOS_USER_NAME} ${qdbus_cmd} ${kdialog_dbus} /ProgressDialog showCancelButton false
sudo -E -u ${WINESAPOS_USER_NAME} ${qdbus_cmd} ${kdialog_dbus} /ProgressDialog Set org.kde.kdialog.ProgressDialog value 1

# Remove the problematic 'fatx' package first.
# https://github.com/LukeShortCloud/winesapOS/issues/651
${CMD_PACMAN} -Q fatx
if [ $? -eq 0 ]; then
    ${CMD_PACMAN_REMOVE[*]} fatx
fi

# Remove the problematic 'gwenview' package.
gwenview_found=0
${CMD_PACMAN} -Q gwenview
if [ $? -eq 0 ]; then
    gwenview_found=1
    ${CMD_PACMAN_REMOVE[*]} gwenview
fi

# Remove the problematic 'replay-sorcery' package.
# https://github.com/LukeShortCloud/winesapOS/issues/903
replay_sorcery_found=0
${CMD_PACMAN} -Q replay-sorcery
if [ $? -eq 0 ]; then
    replay_sorcery_found=1
    ${CMD_PACMAN_REMOVE[*]} replay-sorcery
fi

# The 'base-devel' package needs to be explicitly updated since it was changed to a meta package.
# https://github.com/LukeShortCloud/winesapOS/issues/569
sudo -E ${CMD_PACMAN} -S -y --noconfirm base-devel

# On old builds of Mac Linux Gaming Stick, this file is provided by 'filesystem' but is replaced by 'systemd' in newer versions.
# Detect if it is the old version and, if so, delete the conflicting file.
# https://github.com/LukeShortCloud/winesapOS/issues/229#issuecomment-1595868315
grep -q "LC_COLLATE=C" /usr/share/factory/etc/locale.conf
if [ $? -eq 0 ]; then
    rm -f /usr/share/factory/etc/locale.conf
fi

# This upgrade needs to happen before updating the Linux kernels.
# Otherwise, it can lead to an unbootable system.
# https://github.com/LukeShortCloud/winesapOS/issues/379#issuecomment-1166577683
${CMD_PACMAN} -S -u --noconfirm

# Check to see if the previous update failed by seeing if there are still packages to be downloaded for an upgrade.
# If there are, try to upgrade all of the system packages one more time.
sudo -E ${CMD_PACMAN} -S -u -p | grep -P ^http | grep -q tar.zst
if [ $? -eq 0 ]; then
    ${CMD_PACMAN} -S -u --noconfirm
fi

sudo -E -u ${WINESAPOS_USER_NAME} ${qdbus_cmd} ${kdialog_dbus} /ProgressDialog Set org.kde.kdialog.ProgressDialog value 2

sudo -E -u ${WINESAPOS_USER_NAME} flatpak update -y --noninteractive
sudo -E -u ${WINESAPOS_USER_NAME} flatpak uninstall --unused -y --noninteractive
sudo -E -u ${WINESAPOS_USER_NAME} ${qdbus_cmd} ${kdialog_dbus} /ProgressDialog Set org.kde.kdialog.ProgressDialog value 3

flatpak update -y --noninteractive
flatpak uninstall --unused -y --noninteractive
sudo -E -u ${WINESAPOS_USER_NAME} ${qdbus_cmd} ${kdialog_dbus} /ProgressDialog Set org.kde.kdialog.ProgressDialog value 4
# Remove the Flatpak directory for the user to avoid errors.
# This directory will automatically get re-generated when a 'flatpak' command is ran.
# https://github.com/LukeShortCloud/winesapOS/issues/516
rm -r -f /home/${WINESAPOS_USER_NAME}/.local/share/flatpak

# Remove the old 'ceph-libs' package from the AUR that is no longer used.
# The newer version also fails to compile causing all AUR upgrades to fail.
${CMD_PACMAN} -Q ceph-libs
if [ $? -eq 0 ]; then
    ${CMD_PACMAN_REMOVE[*]} ceph-libs
fi

sudo -u ${WINESAPOS_USER_NAME} yay --pacman ${CMD_PACMAN} -S -y -y -u --noconfirm

# Re-install FATX by re-compiling it from the AUR.
${CMD_YAY_INSTALL[*]} aur/fatx
# Re-install gwenview.
if [[ "${gwenview_found}" == "1" ]]; then
    ${CMD_PACMAN_INSTALL[*]} gwenview
fi
# Re-install replay-sorcery.
if [[ "${replay_sorcery_found}" == "1" ]]; then
    ${CMD_PACMAN_INSTALL[*]} replay-sorcery
fi

# Re-add this setting for the Plasma 5 Vapor theme after the system upgrade is complete.
crudini --set /etc/xdg/konsolerc "Desktop Entry" DefaultProfile Vapor.profile
sudo -E -u ${WINESAPOS_USER_NAME} ${qdbus_cmd} ${kdialog_dbus} /ProgressDialog Set org.kde.kdialog.ProgressDialog value 5
echo "Upgrading system packages complete."

echo "Upgrading ignored packages..."
if [[ "${WINESAPOS_DISTRO_DETECTED}" == "arch" ]]; then
    yes | ${CMD_PACMAN} -S core/linux-lts core/linux-lts-headers core/grub core/filesystem
elif [[ "${WINESAPOS_DISTRO_DETECTED}" == "manjaro" ]]; then
    yes | ${CMD_PACMAN} -S core/linux66 core/linux66-headers core/grub
    # Due to conflicts between Mac Linux Gaming Stick 2 versus winesapOS 3, do not replace the 'filesystem' package.
    # https://github.com/LukeShortCloud/winesapOS/issues/229#issuecomment-1595886615
    if [[ "${WINESAPOS_USER_NAME}" == "stick" ]]; then
	yes | ${CMD_PACMAN} -S core/filesystem
    else
	yes | ${CMD_PACMAN} -S holo-rel/filesystem
    fi
elif [[ "${WINESAPOS_DISTRO_DETECTED}" == "steamos" ]]; then
    yes | ${CMD_PACMAN} -S core/linux-lts core/linux-lts-headers linux-steamos linux-steamos-headers core/grub holo-rel/filesystem
fi
echo "Upgrading ignored packages done."
sudo -E -u ${WINESAPOS_USER_NAME} ${qdbus_cmd} ${kdialog_dbus} /ProgressDialog Set org.kde.kdialog.ProgressDialog value 6

${CMD_PACMAN} -Q | grep -q nvidia-dkms
if [ $? -eq 0 ]; then
    echo "Upgrading NVIDIA drivers..."
    ${CMD_PACMAN} -S --noconfirm \
      extra/nvidia-dkms \
      extra/nvidia-utils \
      multilib/lib32-nvidia-utils \
      extra/opencl-nvidia \
      multilib/lib32-opencl-nvidia
    echo "Upgrading NVIDIA drivers complete."
fi
sudo -E -u ${WINESAPOS_USER_NAME} ${qdbus_cmd} ${kdialog_dbus} /ProgressDialog Set org.kde.kdialog.ProgressDialog value 7

echo "Removing unused Pacman packages..."
${CMD_PACMAN} -Qdtq | ${CMD_PACMAN} -R -n -s --noconfirm -
echo "Removing unused Pacman packages done."
sudo -E -u ${WINESAPOS_USER_NAME} ${qdbus_cmd} ${kdialog_dbus} /ProgressDialog Set org.kde.kdialog.ProgressDialog value 8

dmidecode -s system-product-name | grep -P ^Mac
if [ $? -eq 0 ]; then
    echo "Mac hardware detected."

    ${CMD_PACMAN} -Q mbpfan-git
    if [ $? -ne 0 ]; then
        echo "Installing MacBook fan support..."
        ${CMD_YAY_INSTALL[*]} mbpfan-git
        crudini --set /etc/mbpfan.conf general min_fan_speed 1300
        crudini --set /etc/mbpfan.conf general max_fan_speed 6200
        crudini --set /etc/mbpfan.conf general max_temp 105
        systemctl enable --now mbpfan
        echo "Installing MacBook fan support complete."
    fi

    echo "Re-installing Mac drivers..."
    # Sound driver for Linux LTS 6.6.
    # https://github.com/LukeShortCloud/winesapOS/issues/152
    # https://github.com/LukeShortCloud/winesapOS/issues/614
    # First, clean up old driver files that may exist.
    rm -r -f /snd-hda-codec-cs8409
    git clone --branch linux5.19 https://github.com/egorenar/snd-hda-codec-cs8409.git
    cd snd-hda-codec-cs8409
    # The last kernel found from the 'tail' command is actually the newest one.
    export KVER=$(ls -1 /lib/modules/ | grep -P "^6.6." | tail -n 1)
    make
    make install
    cd ..
    rm -rf snd-hda-codec-cs8409
    # The old "linux5.14" branch created a module called "snd-hda-codec-cirrus".
    # The new "linux5.19" branch creates a module called "snd-hda-codec-cs8409".
    echo "snd-hda-codec-cs8409" > /etc/modules-load.d/winesapos-sound.conf

    # Reinstall the MacBook Pro Touch Bar driver to force the DKMS to re-install on all kernels.
    sudo -u ${WINESAPOS_USER_NAME} yay --pacman ${CMD_PACMAN} --noconfirm -S --removemake macbook12-spi-driver-dkms
    ${CMD_YAY_INSTALL[*]} macbook12-spi-driver-dkms
    for kernel in $(ls -1 /usr/lib/modules/ | grep -P "^[0-9]+"); do
        dkms install --no-depmod macbook12-spi-driver/$(${CMD_PACMAN} -Q macbook12-spi-driver-dkms | awk {'print $2'} | cut -d- -f1) -k ${kernel} --force
    done

    for kernel in $(ls -1 /usr/lib/modules/ | grep -P "^[0-9]+"); do
        # This will sometimes fail the first time it tries to install.
        timeout 120s dkms install -m apple-bce -v 0.1 -k ${kernel}
        if [ $? -ne 0 ]; then
            dkms install -m apple-bce -v 0.1 -k ${kernel}
        fi
    done
    echo "Re-installing Mac drivers done."
else
    echo "No Mac hardware detected."
fi
sudo -E -u ${WINESAPOS_USER_NAME} ${qdbus_cmd} ${kdialog_dbus} /ProgressDialog Set org.kde.kdialog.ProgressDialog value 9

# winesapOS 3.0.Y will have broken UEFI boot after an upgrade so we need to re-install it.
# Legacy BIOS boot is unaffected.
# https://github.com/LukeShortCloud/winesapOS/issues/695
grep "3.0*" /etc/winesapos/VERSION
if [ $? -eq 0 ]; then
    grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=winesapOS --removable --no-nvram
fi

echo "Rebuilding initramfs with new drivers..."
mkinitcpio -P
echo "Rebuilding initramfs with new drivers complete."
sudo -E -u ${WINESAPOS_USER_NAME} ${qdbus_cmd} ${kdialog_dbus} /ProgressDialog Set org.kde.kdialog.ProgressDialog value 10

echo "Updating Btrfs snapshots in the GRUB menu..."
grub-mkconfig -o /boot/grub/grub.cfg
echo "Updating Btrfs snapshots in the GRUB menu complete."

# Allow PackageKit (required for Discover) to work again.
systemctl unmask packagekit

if [[ "${WINESAPOS_IMAGE_TYPE}" == "secure" ]]; then
    echo "Disallow passwordless 'sudo' now that the upgrade is done..."
    rm -f /etc/sudoers.d/${WINESAPOS_USER_NAME}
    mv /root/etc-sudoersd-${WINESAPOS_USER_NAME} /etc/sudoers.d/${WINESAPOS_USER_NAME}
    echo "Disallow passwordless 'sudo' now that the upgrade is done complete."
fi

echo "NEW PACKAGES:"
pacman -Q

echo "VERSION_ORIGINAL=${WINESAPOS_VERSION_ORIGINAL},VERSION_NEW=${WINESAPOS_VERSION_NEW},DATE=${START_TIME}" >> /etc/winesapos/UPGRADED
rm -f /etc/winesapos/VERSION /etc/winesapos/IMAGE_TYPE /usr/lib/os-release-winesapos
curl https://raw.githubusercontent.com/LukeShortCloud/winesapOS/stable/files/os-release-winesapos --location --output /usr/lib/os-release-winesapos
echo -e "VARIANT=\""${WINESAPOS_IMAGE_TYPE}""\"\\nVARIANT_ID=${WINESAPOS_IMAGE_TYPE} | tee -a /usr/lib/os-release-winesapos
ln -s /usr/lib/os-release-winesapos /etc/os-release-winesapos

sudo -E -u ${WINESAPOS_USER_NAME} ${qdbus_cmd} ${kdialog_dbus} /ProgressDialog org.kde.kdialog.ProgressDialog.close

test_internet_connection
if [ $? -ne 1 ]; then
    sudo -E -u ${WINESAPOS_USER_NAME} kdialog --title "winesapOS Upgrade" --msgbox "Upgrade complete but no network connection detected. There may have been an issue during the upgrade."
else
    sudo -E -u ${WINESAPOS_USER_NAME} kdialog --title "winesapOS Upgrade" --msgbox "Upgrade complete! Please reboot to load new changes."
fi

echo "End time: $(date --iso-8601=seconds)"

if [[ "${WINESAPOS_USER_NAME}" == "stick" ]]; then
    mv /tmp/upgrade_${START_TIME}.log /etc/mac-linux-gaming-stick/
else
    mv /tmp/upgrade_${START_TIME}.log /etc/winesapos/
fi
