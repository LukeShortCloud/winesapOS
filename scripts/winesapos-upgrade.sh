#!/bin/bash

# Enable shell debugging.
set -x

START_TIME=$(date --iso-8601=seconds)

# Check for a custom user name. Default to 'winesap'.
if [[ -z "${WINESAPOS_USER_NAME}" ]]; then
    if ls /tmp/winesapos_user_name.txt &> /dev/null; then
        WINESAPOS_USER_NAME=$(cat /tmp/winesapos_user_name.txt)
    else
        WINESAPOS_USER_NAME="winesap"
    fi
fi

# Create a symlink for forwards compatibility.
if ! ls /var/winesapos &> /dev/null; then
    # For winesapOS 2, /var/winesapos will point to /etc/winesapos which will point to /etc/mac-linux-gaming-stick.
    if [[ "${WINESAPOS_USER_NAME}" == "stick" ]]; then
        if ! ls /etc/winesapos &> /dev/null; then
            ln -s /etc/mac-linux-gaming-stick /etc/winesapos
        fi
    fi
    ln -s /etc/winesapos /var/winesapos
fi

# Start logging to a file.
if [[ "${WINESAPOS_USER_NAME}" == "stick" ]]; then
    exec > >(tee "/etc/mac-linux-gaming-stick/upgrade_${START_TIME}.log") 2>&1
else
    exec > >(tee "/etc/winesapos/upgrade_${START_TIME}.log") 2>&1
fi
echo "Start time: ${START_TIME}"

WINESAPOS_UPGRADE_FILES="${WINESAPOS_UPGRADE_FILES:-true}"
WINESAPOS_UPGRADE_REPO_ROLLING="${WINESAPOS_UPGRADE_REPO_ROLLING:-true}"
WINESAPOS_UPGRADE_VERSION_CHECK="${WINESAPOS_UPGRADE_VERSION_CHECK:-false}"

failed_tests=0
winesapos_upgrade_failure() {
    # shellcheck disable=SC2003 disable=SC2086
    failed_tests=$(expr ${failed_tests} + 1)
    echo FAIL
}

crudini_wrapper() {
    if "${CMD_CRUDINI}" --version; then
        "${CMD_CRUDINI}" "$@"
    else
        echo "ERROR: crudini is broken. The upgrade will not work as intended."
    fi
}

install_static_curl() {
    CMD_CURL=/usr/bin/curl-static
    export CMD_CURL
    if ! "${CMD_CURL}" --version &> /dev/null; then
        # This package is provided by the winesapOS repository.
        if ! /usr/bin/pacman --noconfirm -S curl-static-bin; then
            export CMD_CURL=/usr/local/bin/curl-static
            if ! "${CMD_CURL}" --version &> /dev/null; then
                CURL_STATIC_VER="8.21.0"
                curl --location --remote-name "https://github.com/stunnel/static-curl/releases/download/${CURL_STATIC_VER}/curl-linux-x86_64-musl-${CURL_STATIC_VER}.tar.xz" --output-dir /tmp/
                tar -xvf "/tmp/curl-linux-x86_64-musl-${CURL_STATIC_VER}.tar.xz" -C /tmp/
                mv /tmp/curl "${CMD_CURL}"
                rm -f "/tmp/curl-linux-x86_64--musl${CURL_STATIC_VER}.tar.xz"
                if ! "${CMD_CURL}" --version &> /dev/null; then
                    # If all else fails, use the non-static 'curl' binary.
                    export CMD_CURL=/usr/bin/curl
                fi
            fi
        fi
    fi
}

install_static_crudini() {
    CMD_CRUDINI=/usr/local/bin/crudini-static
    export CMD_CRUDINI
    if ! ls "${CMD_CRUDINI}" &> /dev/null; then
        "${CMD_CURL}" --location --remote-name https://winesapos.lukeshort.cloud/repo/crudini-static --output-dir /usr/local/bin/
        chmod +x "${CMD_CRUDINI}"
        if ! ls "${CMD_CRUDINI}" &> /dev/null; then
            # If all else fails, use the non-static 'crudini' binary.
            export CMD_CRUDINI=/usr/bin/crudini
         fi
    fi

    if echo "${CMD_CURL}" | grep -q curl-static; then
        crudini_wrapper --set /etc/pacman.conf options XferCommand "${CMD_CURL} --connect-timeout 60 --retry 10 --retry-delay 5 -L -f -o %o %u"
    fi
}

install_static_pacman() {
    CMD_PACMAN=/usr/bin/pacman-static
    export CMD_PACMAN
    if ! ls "${CMD_PACMAN}" &> /dev/null; then
        # This package is provided by the Chaotic AUR repository.
        if ! /usr/bin/pacman --noconfirm -S pacman-static; then
            export CMD_PACMAN=/usr/local/bin/pacman-static
            if ! ls "${CMD_PACMAN}" &> /dev/null; then
                "${CMD_CURL}" --location --remote-name https://pkgbuild.com/~morganamilo/pacman-static/x86_64/bin/pacman-static --output-dir /usr/local/bin/
                chmod +x "${CMD_PACMAN}"
                if ! ls "${CMD_PACMAN}" &> /dev/null; then
                    # If all else fails, use the non-static 'pacman' binary.
                    export CMD_PACMAN=/usr/bin/pacman
                fi
            fi
        fi
    fi
    pacman_static_ver=$("${CMD_PACMAN}" --version | grep -o -P "Pacman v\d" | cut -dv -f2)
    if [ "${pacman_static_ver}" -lt 7 ]; then
        "${CMD_CURL}" --location --remote-name https://winesapos.lukeshort.cloud/repo/winesapos-4.2.0/x86_64/pacman-static-7.0.0.r3.g7736133-8-x86_64.pkg.tar.xz --output-dir /tmp/
        tar -xvf /tmp/pacman-static-7.0.0.r3.g7736133-8-x86_64.pkg.tar.xz -C /tmp/
        mv /tmp/usr/bin/pacman-static /usr/local/bin/pacman-static-7.0.0
        if /usr/local/bin/pacman-static-7.0.0 --version &> /dev/null; then
            export CMD_PACMAN=/usr/local/bin/pacman-static-7.0.0
        fi
    fi
}

install_static_paru() {
    CMD_AUR=/usr/bin/paru-static
    export CMD_AUR
    if ! ls "${CMD_AUR}" &> /dev/null; then
        # This package is provided by the winesapOS repository.
        if ! /usr/bin/pacman --noconfirm -S paru-static; then
            # Fall back to the dynamically linked 'paru' binary.
            export CMD_AUR=/usr/bin/paru
            if ! ls "${CMD_AUR}" &> /dev/null; then
                # If all else fails, use 'yay' which is what older winesapOS images shipped with.
                # This is not an absolute path because 'yay' lives in either '/usr/bin/' or
                # '/usr/local/bin/' depending on how old the image is.
                export CMD_AUR=yay
            fi
        fi
    fi
}

# Both 'paru' and 'yay' support the same arguments here.
# For backwards compatibility, this is reused by 'CMD_AUR_INSTALL'.
# shellcheck disable=SC2329
aur_install() {
    # shellcheck disable=SC2317
    sudo -u "${WINESAPOS_USER_NAME}" "${CMD_AUR}" --pacman "${CMD_PACMAN}" --noconfirm -S --needed --removemake "$@"
}

remove_unused_pkgs() {
    echo "Removing unused Pacman packages..."
    unused_pkgs="$(${CMD_PACMAN} -Q -d -t -q)"
    if [[ -n "${unused_pkgs}" ]]; then
	# Avoid using a pipe here so that Pacman hooks such as 'snap-pac' will continue to work.
        # shellcheck disable=SC2086
        ${CMD_PACMAN} -R -n -s --noconfirm ${unused_pkgs}
    fi
    echo "Removing unused Pacman packages done."
}

install_static_curl
install_static_pacman
install_static_paru

echo "OLD PACKAGES:"
"${CMD_PACMAN}" -Q

# This is a static build of 'crudini', created from 'pyinstaller', and built on winesapOS 3.3.0.
# https://github.com/winesapOS/winesapOS/issues/1050
install_static_crudini

check_pacman_corruption() {
    # could not parse = A corrupt database. Pacman will not work even if at least one of the databases is corrupt.
    # Example log line: could not parse package description file 'proxmark3-4.20142-1/desc' from db 'extra'
    # could not read db = A database file missing or permission error.
    # Example log line: error: could not read db 'extra'
    # invalid or corrupted = A corrupt package download.
    # Example log line: error: failed to synchronize all databases (invalid or corrupted database (PGP signature))
    if ${CMD_PACMAN} -S -l 2> /dev/stdout | grep -P "could not parse|could not read|invalid or corrupted"; then
        return 1
    fi
    # warning: database file for = A missing database file.
    # Example log line warning: database file for 'winesapos-rolling' does not exist (use '-Sy' to download)
    if ${CMD_PACMAN} -Q 2> /dev/stdout | grep "warning: database file for"; then
        return 1
    fi
    return 0
}

repair_pacman() {
    echo "Repairing corrupt Pacman..."
    rm -f /var/lib/pacman/sync/*.db
    find /var/cache/pacman/pkg/ -iname "*.part" -delete
    pacman_sync_dbs
    echo "Repairing corrupt Pacman complete."
}

refresh_mirrorlist() {
    echo "Refreshing the Pacman mirrorlist..."
    if [[ "${WINESAPOS_DISTRO_DETECTED}" == "manjaro" ]]; then
        pacman-mirrors --api --protocol https --country all
    elif command -v reflector &> /dev/null; then
        reflector --verbose --latest 10 --sort rate --protocol https --threads 10 --save /etc/pacman.d/mirrorlist
    else
        echo "WARNING: 'reflector' is not available. Falling back to a static list of well-known mirrors."
        # shellcheck disable=SC2016
        {
            echo 'Server = https://geo.mirror.pkgbuild.com/$repo/os/$arch'
            echo 'Server = https://mirror.rackspace.com/archlinux/$repo/os/$arch'
            echo 'Server = https://mirrors.kernel.org/archlinux/$repo/os/$arch'
            echo 'Server = https://fastly.mirror.pkgbuild.com/$repo/os/$arch'
        } | tee /etc/pacman.d/mirrorlist
    fi
    echo "Refreshing the Pacman mirrorlist complete."
}

pacman_sync_dbs() {
    if ! ${CMD_PACMAN} -S -y -y; then
        echo "WARNING: Failed to synchronize Pacman databases. Refreshing the mirrorlist and retrying..."
        refresh_mirrorlist
        if ! ${CMD_PACMAN} -S -y -y; then
            echo "ERROR: Still failed to synchronize Pacman databases after refreshing the mirrorlist."
            echo "DEBUG: Pacman configuration below."
            cat /etc/pacman.conf
            winesapos_upgrade_failure
        fi
    fi
}

check_update_pacman() {
    if ! ${CMD_PACMAN} -S -u -p; then
        echo "Pacman update status unknown."
        return 1
    fi
    if ! check_pacman_corruption; then
        echo "Pacman is broken."
        return 1
    fi
    if ${CMD_PACMAN} -S -u -p | grep -P '^(file|http)' | grep -q -P '^(file|http).*\.tar\.[a-z]+$'; then
        echo "Pacman update available."
        return 1
    else
        echo "Pacman update not available."
        return 0
    fi
}

check_update_aur() {
    if ! sudo -u "${WINESAPOS_USER_NAME}" "${CMD_AUR}" --version &> /dev/null; then
        echo "AUR update status unknown."
        return 1
    fi
    if ! check_pacman_corruption; then
        echo "Pacman is broken."
        return 1
    fi
    # The arguments between 'paru' and 'yay' are different for checking package updates from themselves (not 'pacman').
    #if sudo -u "${WINESAPOS_USER_NAME}" yay --pacman ${CMD_PACMAN} -S -u -p | grep -q -P '^(file|http).*\.tar\.[a-z]+$'; then
    aur_updates="$(sudo -u "${WINESAPOS_USER_NAME}" "${CMD_AUR}" --pacman ${CMD_PACMAN} -Q -u -a)"
    if echo "${aur_updates}" | grep -q -P "\S"; then
        echo "AUR update available for these packages:"
        echo "${aur_updates}"
        return 1
    else
        echo "AUR update not available."
        return 0
    fi
}

WINESAPOS_DISTRO_DETECTED=$(grep -P '^ID=' /etc/os-release | cut -d= -f2)
CMD_PACMAN_INSTALL=("${CMD_PACMAN}" --noconfirm -S --needed)
CMD_PACMAN_REMOVE=("${CMD_PACMAN}" -R -n -s --noconfirm)
CMD_AUR_INSTALL=(aur_install)
CMD_FLATPAK_INSTALL=(flatpak install -y --noninteractive)

WINESAPOS_VERSION_NEW="$(${CMD_CURL} https://raw.githubusercontent.com/winesapOS/winesapOS/main/rootfs/usr/lib/os-release-winesapos | grep VERSION_ID | cut -d = -f 2)"
WINESAPOS_VERSION_ORIGINAL=""
export WINESAPOS_VERSION_ORIGINAL
# winesapOS >= 4.1.0
if [ -f /usr/lib/os-release-winesapos ]; then
    WINESAPOS_VERSION_ORIGINAL="$(grep VERSION_ID /usr/lib/os-release-winesapos | cut -d = -f 2)"
    export WINESAPOS_VERSION_ORIGINAL
# winesapOS < 4.1.0
else
    WINESAPOS_VERSION_ORIGINAL="$(cat /etc/winesapos/VERSION)"
    export WINESAPOS_VERSION_ORIGINAL
fi

WINESAPOS_IMAGE_TYPE=""
export WINESAPOS_IMAGE_TYPE
# winesapOS >= 4.1.0
if [ -f /usr/lib/os-release-winesapos ]; then
    WINESAPOS_IMAGE_TYPE="$(grep VARIANT_ID /usr/lib/os-release-winesapos | cut -d = -f 2)"
    export WINESAPOS_IMAGE_TYPE
# winesapOS < 4.1.0
else
    WINESAPOS_IMAGE_TYPE="$(cat /etc/winesapos/IMAGE_TYPE)"
    export WINESAPOS_IMAGE_TYPE
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

echo "Configuring package repositories..."

# Mac Linux Gaming Stick (winesapOS) 2 does not have 'kdialog' installed.
# Only show initial upgrade prompts if it is installed.
# We install it later but need to update and fix Pacman first.
kdialog_dbus=""
if "${CMD_PACMAN}" -Q | grep -q kdialog; then
    kdialog_dbus=$(sudo -E -u "${WINESAPOS_USER_NAME}" kdialog --title "winesapOS Upgrade" --progressbar "Please wait for Pacman keyrings to update..." 5 | cut -d" " -f1)
    sudo -E -u "${WINESAPOS_USER_NAME}" "${qdbus_cmd}" "${kdialog_dbus}" /ProgressDialog showCancelButton false
fi

# Disable XferCommand for Pacman 6.1.
# https://github.com/winesapOS/winesapOS/issues/802
# https://github.com/winesapOS/winesapOS/issues/900
crudini_wrapper --del /etc/pacman.conf options XferCommand
if ! ${CMD_PACMAN} -Q pacman | grep -q "pacman 6.1"; then
    if ! grep -q -P "^XferCommand" /etc/pacman.conf; then
        sed -i "s/\[options\]/\[options\]\nXferCommand = $(echo ${CMD_CURL} | sed ""'s/\//\\\//g'"") --connect-timeout 60 --retry 10 --retry-delay 5 -L -f -o %o %u/g" /etc/pacman.conf
    fi
fi

# SteamOS 3.4 changed the name of the stable repositories.
# https://github.com/winesapOS/winesapOS/issues/537
echo "Switching to new SteamOS release repositories..."
sed -i 's/\[holo\]/\[holo-rel\]/g' /etc/pacman.conf
sed -i 's/\[jupiter\]/\[jupiter-rel\]/g' /etc/pacman.conf
echo "Switching to new SteamOS release repositories complete."

# https://github.com/winesapOS/winesapOS/issues/1114
echo "Remove old Pacman 6 configuration options..."
sed -i '/# If upgrades are available for these packages they will be asked for first/d' /etc/pacman.conf
sed -i '/SyncFirst/d' /etc/pacman.conf
echo "Remove old Pacman 6 configuration options complete."

# Arch Linux and Manjaro have merged the community repository into the extra repository.
echo "Removing deprecated Pacman repositories..."
crudini_wrapper --del /etc/pacman.conf community
crudini_wrapper --del /etc/pacman.conf community-testing
crudini_wrapper --del /etc/pacman.conf community-staging
echo "Removing deprecated Pacman repositories complete."

[[ -n "${kdialog_dbus}" ]] && sudo -E -u "${WINESAPOS_USER_NAME}" "${qdbus_cmd}" "${kdialog_dbus}" /ProgressDialog Set org.kde.kdialog.ProgressDialog value 1

# It is possible for users to have such an old database of GPG keys that the '*-keyring' packages fail to install due to GPG verification failures.
crudini_wrapper --set /etc/pacman.conf core SigLevel Never
# Since we reinitialize all of the keyrings, we need to re-add the locally signed keys.
rm -r -f /etc/pacman.d/gnupg
pacman-key --init
echo "Adding the public GPG key for the winesapOS repository..."
pacman-key --recv-keys 1805E886BECCCEA99EDF55F081CA29E4A4B01239
pacman-key --lsign-key 1805E886BECCCEA99EDF55F081CA29E4A4B01239
crudini_wrapper --del /etc/pacman.conf winesapos SigLevel
echo "Adding the public GPG key for the winesapOS repository complete."
echo "Adding the public GPG key for the Chaotic AUR repository..."
pacman-key --recv-keys 3056513887B78AEB
pacman-key --lsign-key 3056513887B78AEB
pacman-key --recv-keys D6C9442437365605
pacman-key --lsign-key D6C9442437365605
"${CMD_CURL}" --location --remote-name 'https://cdn-mirror.chaotic.cx/chaotic-aur/chaotic-keyring.pkg.tar.zst' --output-dir /
${CMD_PACMAN} --noconfirm -U /chaotic-keyring.pkg.tar.zst
rm -f /chaotic-*.pkg.tar.zst
echo "Adding the public GPG key for the Chaotic AUR repository complete."
[[ -n "${kdialog_dbus}" ]] && sudo -E -u "${WINESAPOS_USER_NAME}" "${qdbus_cmd}" "${kdialog_dbus}" /ProgressDialog Set org.kde.kdialog.ProgressDialog value 2

echo "Adding the winesapOS repository..."
crudini_wrapper --del /etc/pacman.conf winesapos
crudini_wrapper --del /etc/pacman.conf winesapos-rolling
crudini_wrapper --del /etc/pacman.conf winesapos-testing
if [[ "${WINESAPOS_UPGRADE_REPO_ROLLING}" == "true" ]]; then
    # shellcheck disable=SC2016
    sed -i 's/\[core]/[winesapos-rolling]\nServer = https:\/\/winesapos.lukeshort.cloud\/repo\/$repo\/$arch\n\n[core]/g' /etc/pacman.conf
else
    # shellcheck disable=SC2016
    sed -i 's/\[core]/[winesapos]\nServer = https:\/\/winesapos.lukeshort.cloud\/repo\/$repo\/$arch\n\n[core]/g' /etc/pacman.conf
fi
echo "Adding the winesapOS repository complete."

echo "Enabling newer upstream Arch Linux package repositories..."
# Use the mirrorlist for official repositories.
# shellcheck disable=SC2016
crudini_wrapper --set /etc/pacman.conf core Include '/etc/pacman.d/mirrorlist'
crudini_wrapper --del /etc/pacman.conf core Server
# shellcheck disable=SC2016
crudini_wrapper --set /etc/pacman.conf extra Include '/etc/pacman.d/mirrorlist'
crudini_wrapper --del /etc/pacman.conf extra Server
# shellcheck disable=SC2016
crudini_wrapper --set /etc/pacman.conf multilib Include '/etc/pacman.d/mirrorlist'
crudini_wrapper --del /etc/pacman.conf multilib Server
# Arch Linux is backward compatible with SteamOS packages but SteamOS is not forward compatible with Arch Linux.
# Move these repositories to the bottom of the Pacman configuration file to account for that.
crudini_wrapper --del /etc/pacman.conf jupiter
crudini_wrapper --del /etc/pacman.conf holo
crudini_wrapper --del /etc/pacman.conf jupiter-rel
crudini_wrapper --del /etc/pacman.conf holo-rel
if [[ "${WINESAPOS_DISTRO_DETECTED}" == "steamos" ]]; then
    # shellcheck disable=SC2016
    crudini_wrapper --set /etc/pacman.conf jupiter-rel Server 'https://steamdeck-packages.steamos.cloud/archlinux-mirror/$repo/os/$arch'
    crudini_wrapper --set /etc/pacman.conf jupiter-rel SigLevel Never
    # shellcheck disable=SC2016
    crudini_wrapper --set /etc/pacman.conf holo-rel Server 'https://steamdeck-packages.steamos.cloud/archlinux-mirror/$repo/os/$arch'
    crudini_wrapper --set /etc/pacman.conf holo-rel SigLevel Never
fi
[[ -n "${kdialog_dbus}" ]] && sudo -E -u "${WINESAPOS_USER_NAME}" "${qdbus_cmd}" "${kdialog_dbus}" /ProgressDialog Set org.kde.kdialog.ProgressDialog value 3

# Configure the Pacman configuration after the keys and mirrors have been installed for the Chaotic AUR.
if ${CMD_PACMAN} -Q chaotic-mirrorlist; then
    if ${CMD_PACMAN} -Q chaotic-keyring; then
        if ! grep -q "\[chaotic-aur\]" /etc/pacman.conf; then
            echo "Adding the Chaotic AUR repository..."
            echo "[chaotic-aur]
Include = /etc/pacman.d/chaotic-mirrorlist
SigLevel = Optional TrustedOnly" >> /etc/pacman.conf
            echo "Adding the Chaotic AUR repository complete."
        else
            crudini_wrapper --set /etc/pacman.conf chaotic-aur SigLevel "Optional TrustedOnly"
        fi
    fi
fi

crudini_wrapper --del /etc/pacman.conf arch-mact2
crudini_wrapper --del /etc/pacman.conf Redecorating-t2
# shellcheck disable=SC2016
crudini_wrapper --set /etc/pacman.conf arch-mact2 Include /etc/pacman.d/arch-mact2-mirrorlist
crudini_wrapper --set /etc/pacman.conf arch-mact2 SigLevel Never
# shellcheck disable=SC2016
crudini_wrapper --set /etc/pacman.conf Redecorating-t2 Server https://github.com/Redecorating/archlinux-t2-packages/releases/download/packages
crudini_wrapper --set /etc/pacman.conf Redecorating-t2 SigLevel Never
rm -f /etc/pacman.d/arch-mact2-mirrorlist
"${CMD_CURL}" --location --remote-name https://raw.githubusercontent.com/NoaHimesaka1873/arch-mact2-PKGBUILDs/refs/heads/senpai/arch-mact2-mirrorlist/arch-mact2-mirrorlist --output-dir /etc//pacman.d/
[[ -n "${kdialog_dbus}" ]] && sudo -E -u "${WINESAPOS_USER_NAME}" "${qdbus_cmd}" "${kdialog_dbus}" /ProgressDialog Set org.kde.kdialog.ProgressDialog value 4

"${CMD_CURL}" --location --remote-name 'https://cdn-mirror.chaotic.cx/chaotic-aur/chaotic-mirrorlist.pkg.tar.zst' --output-dir /
${CMD_PACMAN} --noconfirm -U /chaotic-mirrorlist.pkg.tar.zst
rm -f /chaotic-*.pkg.tar.zst

refresh_mirrorlist
pacman_sync_dbs

install_static_pacman

if [[ "${WINESAPOS_DISTRO_DETECTED}" == "manjaro" ]]; then
    ${CMD_PACMAN} --noconfirm -S archlinux-keyring manjaro-keyring
else
    ${CMD_PACMAN} --noconfirm -S archlinux-keyring
fi
crudini_wrapper --del /etc/pacman.conf core SigLevel
echo "Enabling newer upstream Arch Linux package repositories complete."
echo "Configuring package repositories complete."
[[ -n "${kdialog_dbus}" ]] && sudo -E -u "${WINESAPOS_USER_NAME}" "${qdbus_cmd}" "${kdialog_dbus}" /ProgressDialog org.kde.kdialog.ProgressDialog.close

if ! "${CMD_PACMAN}" -Q | grep -q kdialog; then
    "${CMD_PACMAN_INSTALL[@]}" kdialog
fi
echo "Setting up tools required for the progress bar complete."

test_internet_connection() {
    # Check with https://ping.archlinux.org/ to see if we have an Internet connection.
    return "$(${CMD_CURL} -s https://ping.archlinux.org/ | grep -c "This domain is used for connectivity checking")"
}

while true;
    do kdialog_dbus=$(sudo -E -u "${WINESAPOS_USER_NAME}" kdialog --title "winesapOS Upgrade" --progressbar "Checking Internet connection..." 2 | cut -d" " -f1)
    sudo -E -u "${WINESAPOS_USER_NAME}" "${qdbus_cmd}" "${kdialog_dbus}" /ProgressDialog showCancelButton false
    test_internet_connection
    # shellcheck disable=SC2181
    if [ $? -eq 1 ]; then
        sudo -E -u "${WINESAPOS_USER_NAME}" "${qdbus_cmd}" "${kdialog_dbus}" /ProgressDialog org.kde.kdialog.ProgressDialog.close
        # Break out of the "while" loop if we have an Internet connection.
        break 2
    fi
    sudo -E -u "${WINESAPOS_USER_NAME}" "${qdbus_cmd}" "${kdialog_dbus}" /ProgressDialog org.kde.kdialog.ProgressDialog.close
    sudo -E -u "${WINESAPOS_USER_NAME}" kdialog --title "winesapOS Upgrade" \
            --yesno "A working Internet connection for upgrades is not detected. \
            \nPlease connect to the Internet and try again, or select Cancel to quit Upgrade." \
            --yes-label "Retry" \
            --no-label "Cancel"
    # shellcheck disable=SC2181
    if [ $? -eq 1 ]; then
        # Exit the script if the user selects "Cancel".
        exit 1
    fi
done

if [[ "${WINESAPOS_UPGRADE_VERSION_CHECK}" == "true" ]]; then
    # 'sort -V' does not work with semantic numbers.
    # As a workaround, adding an underline to versions without a suffix allows the semantic sort to work.
    # shellcheck disable=SC2086
    if [[ $(echo -e "${WINESAPOS_VERSION_NEW}\n${WINESAPOS_VERSION_ORIGINAL}" | sed '/-/!{s/$/_/}' | sort -V) == "$(echo -e ${WINESAPOS_VERSION_NEW}"\n"${WINESAPOS_VERSION_ORIGINAL} | sed '/-/!{s/$/_/}')" ]]; then
        sudo -E -u "${WINESAPOS_USER_NAME}" kdialog --title "winesapOS Upgrade" --msgbox "No upgrade for winesapOS available."
        exit 0
    fi
fi

if [[ "${WINESAPOS_UPGRADE_FILES}" == "true" ]]; then
    echo "Upgrading the winesapOS upgrade script..."
    mv /home/"${WINESAPOS_USER_NAME}"/.winesapos/winesapos-upgrade-remote-stable.sh "/home/${WINESAPOS_USER_NAME}/.winesapos/winesapos-upgrade-remote-stable.sh_${START_TIME}"
    # If the download fails for any reason, revert back to the original upgrade script.
    if ! "${CMD_CURL}" --location --remote-name https://raw.githubusercontent.com/winesapOS/winesapOS/main/rootfs/home/winesap/.winesapos/winesapos-upgrade-remote-stable.sh --output-dir  /home/"${WINESAPOS_USER_NAME}"/.winesapos/; then
        rm -f /home/"${WINESAPOS_USER_NAME}"/.winesapos/winesapos-upgrade-remote-stable.sh
        cp "/home/${WINESAPOS_USER_NAME}/.winesapos/winesapos-upgrade-remote-stable.sh_${START_TIME}" /home/"${WINESAPOS_USER_NAME}"/.winesapos/winesapos-upgrade-remote-stable.sh
    fi
    chmod +x /home/"${WINESAPOS_USER_NAME}"/.winesapos/winesapos-upgrade-remote-stable.sh

    mv /home/"${WINESAPOS_USER_NAME}"/.winesapos/winesapos-upgrade.desktop "/home/${WINESAPOS_USER_NAME}/.winesapos/winesapos-upgrade.desktop_${START_TIME}"
    # If the download fails for any reason, revert back to the original upgrade script.
    if ! "${CMD_CURL}" --location --remote-name https://raw.githubusercontent.com/winesapOS/winesapOS/main/rootfs/home/winesap/.winesapos/winesapos-upgrade.desktop --output-dir /home/"${WINESAPOS_USER_NAME}"/.winesapos/; then
        rm -f /home/"${WINESAPOS_USER_NAME}"/.winesapos/winesapos-upgrade.desktop
        cp "/home/${WINESAPOS_USER_NAME}/.winesapos/winesapos-upgrade.desktop_${START_TIME}" /home/"${WINESAPOS_USER_NAME}"/.winesapos/winesapos-upgrade.desktop
    fi
    chmod +x /home/"${WINESAPOS_USER_NAME}"/.winesapos/winesapos-upgrade.desktop

    chown -R 1000:1000 /home/"${WINESAPOS_USER_NAME}"/.winesapos/
    echo "Upgrading the winesapOS upgrade script complete."

    if [[ "$(sha512sum /home/"${WINESAPOS_USER_NAME}"/.winesapos/winesapos-upgrade-remote-stable.sh | cut -d' ' -f1)" != "$(sha512sum "/home/${WINESAPOS_USER_NAME}/.winesapos/winesapos-upgrade-remote-stable.sh_${START_TIME}" | cut -d' ' -f1)" ]]; then
        echo "The winesapOS upgrade script has been updated. Please re-run the 'winesapOS Upgrade' desktop shortcut."
        sudo -E -u "${WINESAPOS_USER_NAME}" kdialog --title "winesapOS Upgrade" --msgbox "The winesapOS upgrade script has been updated. Please re-run the 'winesapOS Upgrade' desktop shortcut."
        exit 100
    fi

    if [[ "$(sha512sum /home/"${WINESAPOS_USER_NAME}"/.winesapos/winesapos-upgrade.desktop | cut -d' ' -f1)" != "$(sha512sum "/home/${WINESAPOS_USER_NAME}/.winesapos/winesapos-upgrade.desktop_${START_TIME}" | cut -d' ' -f1)" ]]; then
        echo "The winesapOS upgrade desktop shortcut has been updated. Please re-run the 'winesapOS Upgrade' desktop shortcut."
        sudo -E -u "${WINESAPOS_USER_NAME}" kdialog --title "winesapOS Upgrade" --msgbox "The winesapOS upgrade desktop shortcut has been updated. Please re-run the 'winesapOS Upgrade' desktop shortcut."
        exit 100
    fi
else
    echo "Skipping upgrade of winesapOS upgrade files."
fi

current_shell=$(cat /proc/$$/comm)
if [[ "${current_shell}" != "bash" ]]; then
    sudo -E -u "${WINESAPOS_USER_NAME}" kdialog --title "winesapOS Upgrade" --msgbox "winesapOS scripts require Bash but ${current_shell} detected. Exiting..."
    exit 1
fi

if [[ "${WINESAPOS_IMAGE_TYPE}" == "secure" ]]; then
    echo "Allow passwordless 'sudo' for AUR packages installed via 'yay' to be done automatically..."
    mv /etc/sudoers.d/"${WINESAPOS_USER_NAME}" /root/etc-sudoersd-"${WINESAPOS_USER_NAME}"
    echo "${WINESAPOS_USER_NAME} ALL=(root) NOPASSWD:ALL" > /etc/sudoers.d/"${WINESAPOS_USER_NAME}"
    chmod 0440 /etc/sudoers.d/"${WINESAPOS_USER_NAME}"
    echo "Allow passwordless 'sudo' for AUR packages installed via 'yay' to be done automatically complete."
fi

# Disable PackageKit during the upgrade process.
# Otherwise, this can lead to a huge memory leak.
# https://github.com/winesapOS/winesapOS/issues/697
systemctl stop packagekit
systemctl mask packagekit

# Workaround an upstream bug in DKMS.
## https://github.com/winesapOS/winesapOS/issues/427
ln -s /usr/bin/sha512sum /usr/bin/sha512

echo "Running 3.0.0-rc.0 to 3.0.0 upgrades..."
kdialog_dbus=$(sudo -E -u "${WINESAPOS_USER_NAME}" kdialog --title "winesapOS Upgrade" --progressbar "Running 3.0.0-rc.0 to 3.0.0 upgrades..." 2 | cut -d" " -f1)
sudo -E -u "${WINESAPOS_USER_NAME}" "${qdbus_cmd}" "${kdialog_dbus}" /ProgressDialog showCancelButton false
sudo -E -u "${WINESAPOS_USER_NAME}" "${qdbus_cmd}" "${kdialog_dbus}" /ProgressDialog Set org.kde.kdialog.ProgressDialog value 1

echo "Upgrading exFAT partition to work on Windows..."
# Example output: "vda2" or "nvme0n1p2"
exfat_partition_device_name_short=$(lsblk -o name,label | grep wos-drive | awk '{print $1}' | grep -o -P '[a-z]+.*')
exfat_partition_device_name_full="/dev/${exfat_partition_device_name_short}"
# Example output: 2
exfat_partition_number=$(echo "${exfat_partition_device_name_short}" | grep -o -P "[0-9]+$")

if echo "${exfat_partition_device_name_short}" | grep -q nvme; then
    # Example output: /dev/nvme0n1
    root_device=$(echo "${exfat_partition_device_name_full}" | grep -P -o "/dev/nvme[0-9]+n[0-9]+")
else
    # Example output: /dev/vda
    # shellcheck disable=SC2001
    root_device=$(echo "${exfat_partition_device_name_full}" | sed 's/[0-9]//g')
fi
parted "${root_device}" set "${exfat_partition_number}" msftdata on
echo "Upgrading exFAT partition to work on Windows complete."

echo "Running 3.0.0-rc.0 to 3.0.0 upgrades complete."
sudo -E -u "${WINESAPOS_USER_NAME}" "${qdbus_cmd}" "${kdialog_dbus}" /ProgressDialog org.kde.kdialog.ProgressDialog.close

echo "Running 3.0.0 to 3.0.1 upgrades..."
kdialog_dbus=$(sudo -E -u "${WINESAPOS_USER_NAME}" kdialog --title "winesapOS Upgrade" --progressbar "Running 3.0.0 to 3.0.1 upgrades..." 2 | cut -d" " -f1)
sudo -E -u "${WINESAPOS_USER_NAME}" "${qdbus_cmd}" "${kdialog_dbus}" /ProgressDialog showCancelButton false
sudo -E -u "${WINESAPOS_USER_NAME}" "${qdbus_cmd}" "${kdialog_dbus}" /ProgressDialog Set org.kde.kdialog.ProgressDialog value 1

echo "Upgrading 'makepkg' and 'yay' to use all available processor cores for compilation..."
if ! grep -q -P "^MAKEFLAGS" /etc/makepkg.conf; then
    # shellcheck disable=SC2016
    echo 'MAKEFLAGS="-j $(nproc)"' >> /etc/makepkg.conf
fi
echo "Upgrading 'makepkg' and 'yay' to use all available processor cores for compilation complete."

echo "Running 3.0.0 to 3.0.1 upgrades complete."
sudo -E -u "${WINESAPOS_USER_NAME}" "${qdbus_cmd}" "${kdialog_dbus}" /ProgressDialog org.kde.kdialog.ProgressDialog.close


echo "Running 3.0.1 to 3.1.0 upgrades..."
kdialog_dbus=$(sudo -E -u "${WINESAPOS_USER_NAME}" kdialog --title "winesapOS Upgrade" --progressbar "Running 3.0.1 to 3.1.0 upgrades..." 7 | cut -d" " -f1)
sudo -E -u "${WINESAPOS_USER_NAME}" "${qdbus_cmd}" "${kdialog_dbus}" /ProgressDialog showCancelButton false

# Upgrade glibc. This allows some programs to work during the upgrade process.
"${CMD_PACMAN_INSTALL[@]}" glibc lib32-glibc

if ${CMD_PACMAN} -Q | grep -q libpamac-full; then
    echo "Removing Pamac..."
    # Do not remove dependencies to keep 'flatpak' and 'snapd' installed.
    # The first '--nodeps' tells Pacman to not remove dependencies.
    # The second '--nodeps' tells is to ignore the packages being required as a dependency for other applications.
    ${CMD_PACMAN} -R -n --nodeps --nodeps --noconfirm archlinux-appstream-data-pamac libpamac-full pamac-all
    rm -f /home/"${WINESAPOS_USER_NAME}"/Desktop/org.manjaro.pamac.manager.desktop
    echo "Removing Pamac complete."
fi
sudo -E -u "${WINESAPOS_USER_NAME}" "${qdbus_cmd}" "${kdialog_dbus}" /ProgressDialog Set org.kde.kdialog.ProgressDialog value 1

if ! grep -q tmpfs /etc/fstab; then
    echo "Switching volatile mounts from 'ramfs' to 'tmpfs' for compatibility with FUSE (used by AppImage and Flatpak packages)..."
    sed -i 's/ramfs/tmpfs/g' /etc/fstab
    echo "Switching volatile mounts from 'ramfs' to 'tmpfs' for compatibility with FUSE (used by AppImage and Flatpak packages) complete."
fi

if [[ "${WINESAPOS_DISTRO_DETECTED}" == "steamos" ]]; then
    # This is a new package in SteamOS 3.2 that will replace 'linux-firmware' which can lead to unbootable systems.
    # https://github.com/winesapOS/winesapOS/issues/372
    if ! grep -q linux-firmware-neptune-rtw-debug /etc/pacman.conf; then
        echo "Ignoring the new conflicting linux-firmware-neptune-rtw-debug package..."
        sed -i 's/IgnorePkg = /IgnorePkg = linux-firmware-neptune-rtw-debug /g' /etc/pacman.conf
        echo "Ignoring the new conflicting linux-firmware-neptune-rtw-debug package complete."
    fi
fi

# Install ProtonUp-Qt as a Flatpak to avoid package conflicts when upgrading to Arch Linux packages.
# https://github.com/winesapOS/winesapOS/issues/375#issuecomment-1146678638
if ${CMD_PACMAN} -Q | grep -q protonup-qt; then
    echo "Installing a newer version of ProtonUp-Qt..."
    "${CMD_PACMAN_REMOVE[@]}" protonup-qt
    rm -f /home/"${WINESAPOS_USER_NAME}"/Desktop/net.davidotek.pupgui2.desktop
    "${CMD_FLATPAK_INSTALL[@]}" net.davidotek.pupgui2
    cp /var/lib/flatpak/app/net.davidotek.pupgui2/current/active/export/share/applications/net.davidotek.pupgui2.desktop /home/"${WINESAPOS_USER_NAME}"/Desktop/
    chmod +x /home/"${WINESAPOS_USER_NAME}"/Desktop/net.davidotek.pupgui2.desktop
    chown 1000:1000 /home/"${WINESAPOS_USER_NAME}"/Desktop/net.davidotek.pupgui2.desktop
    echo "Installing a newer version of ProtonUp-Qt complete."
fi
sudo -E -u "${WINESAPOS_USER_NAME}" "${qdbus_cmd}" "${kdialog_dbus}" /ProgressDialog Set org.kde.kdialog.ProgressDialog value 2

if [[ "${WINESAPOS_IMAGE_TYPE}" != "minimal" ]]; then
    # shellcheck disable=SC2010
    if ! ls -1 /etc/modules-load.d/ | grep -q winesapos-controllers.conf; then
        echo "Installing Xbox controller support..."
        "${CMD_AUR_INSTALL[@]}" xone-dkms-git
        touch /etc/modules-load.d/winesapos-controllers.conf
        echo -e "xone-wired\nxone-dongle\nxone-gip\nxone-gip-gamepad\nxone-gip-headset\nxone-gip-chatpad\nxone-gip-guitar" | tee /etc/modules-load.d/winesapos-controllers.conf
        for i in xone-wired xone-dongle xone-gip xone-gip-gamepad xone-gip-headset xone-gip-chatpad xone-gip-guitar;
            do modprobe --verbose $i
        done
        echo "Installing Xbox controller support complete."
    fi
fi
sudo -E -u "${WINESAPOS_USER_NAME}" "${qdbus_cmd}" "${kdialog_dbus}" /ProgressDialog Set org.kde.kdialog.ProgressDialog value 3

if [[ "${WINESAPOS_IMAGE_TYPE}" != "minimal" ]]; then
    if ! flatpak list | grep -P "^AntiMicroX" &> /dev/null; then
        echo "Installing AntiMicroX for changing controller inputs..."
        "${CMD_FLATPAK_INSTALL[@]}" io.github.antimicrox.antimicrox
        cp /var/lib/flatpak/app/io.github.antimicrox.antimicrox/current/active/export/share/applications/io.github.antimicrox.antimicrox.desktop /home/"${WINESAPOS_USER_NAME}"/Desktop/
        chmod +x /home/"${WINESAPOS_USER_NAME}"/Desktop/io.github.antimicrox.antimicrox.desktop
        chown 1000:1000 /home/"${WINESAPOS_USER_NAME}"/Desktop/io.github.antimicrox.antimicrox.desktop
        echo "Installing AntiMicroX for changing controller inputs complete."
    fi
fi
sudo -E -u "${WINESAPOS_USER_NAME}" "${qdbus_cmd}" "${kdialog_dbus}" /ProgressDialog Set org.kde.kdialog.ProgressDialog value 4

if [[ "${XDG_CURRENT_DESKTOP}" = "KDE" ]]; then
    if [ ! -f /usr/bin/kate ]; then
        echo "Installing the simple text editor 'kate'...."
        "${CMD_PACMAN_INSTALL[@]}" kate
        echo "Installing the simple text editor 'kate' complete."
    fi
elif [[ "${XDG_CURRENT_DESKTOP}" = "X-Cinnamon" ]]; then
    if [ ! -f /usr/bin/xed ]; then
        echo "Installing the simple text editor 'xed'..."
        "${CMD_PACMAN_INSTALL[@]}" xed
        echo "Installing the simple text editor 'xed' complete."
    fi
fi
sudo -E -u "${WINESAPOS_USER_NAME}" "${qdbus_cmd}" "${kdialog_dbus}" /ProgressDialog Set org.kde.kdialog.ProgressDialog value 5

if ${CMD_PACMAN} -Q | grep -q linux-firmware-neptune; then
    echo "Removing conflicting 'linux-firmware-neptune' packages..."
    if ${CMD_PACMAN} -Q linux-firmware-neptune &> /dev/null; then
        "${CMD_PACMAN_REMOVE[@]}" linux-firmware-neptune
    fi
    if ${CMD_PACMAN} -Q linux-firmware-neptune-rtw-debug &> /dev/null; then
        "${CMD_PACMAN_REMOVE[@]}" linux-firmware-neptune-rtw-debug
    fi
    "${CMD_PACMAN_INSTALL[@]}" linux-firmware
    echo "Removing conflicting 'linux-firmware-neptune' packages complete."
fi
sudo -E -u "${WINESAPOS_USER_NAME}" "${qdbus_cmd}" "${kdialog_dbus}" /ProgressDialog Set org.kde.kdialog.ProgressDialog value 6

echo "Upgrading to 'clang' from Arch Linux..."
if ${CMD_PACMAN} -Q | grep -q clang-libs; then
    # SteamOS 3 splits 'clang' (64-bit) into two packages: (1) 'clang' and (2) 'clang-libs'.
    # It does not ship a 'lib32-clang' package.
    ${CMD_PACMAN} -R -d --nodeps --noconfirm clang clang-libs
fi
# Arch Linux has a 'clang' and 'lib32-clang' package.
"${CMD_PACMAN_INSTALL[@]}" clang lib32-clang
echo "Upgrading to 'clang' from Arch Linux complete."

echo "Running 3.0.1 to 3.1.0 upgrades complete."
sudo -E -u "${WINESAPOS_USER_NAME}" "${qdbus_cmd}" "${kdialog_dbus}" /ProgressDialog org.kde.kdialog.ProgressDialog.close

echo "Running 3.1.0 to 3.1.1 upgrades..."
kdialog_dbus=$(sudo -E -u "${WINESAPOS_USER_NAME}" kdialog --title "winesapOS Upgrade" --progressbar "Running 3.1.0 to 3.1.1 upgrades..." 2 | cut -d" " -f1)
sudo -E -u "${WINESAPOS_USER_NAME}" "${qdbus_cmd}" "${kdialog_dbus}" /ProgressDialog showCancelButton false
sudo -E -u "${WINESAPOS_USER_NAME}" "${qdbus_cmd}" "${kdialog_dbus}" /ProgressDialog Set org.kde.kdialog.ProgressDialog value 1

if ${CMD_PACMAN} -Q | grep -q pipewire-media-session; then
    ${CMD_PACMAN} -R -d --nodeps --noconfirm pipewire-media-session
    "${CMD_PACMAN_INSTALL[@]}" wireplumber
fi

if ! grep -q -P "^GRUB_THEME=/boot/grub/themes/Vimix/theme.txt" /etc/default/grub; then
    "${CMD_PACMAN_INSTALL[@]}" grub-theme-vimix
    ## This theme needs to exist in the '/boot/' mount because if the root file system is encrypted, then the theme cannot be found.
    mkdir -p /boot/grub/themes/
    cp -R /usr/share/grub/themes/Vimix /boot/grub/themes/Vimix
    crudini_wrapper --set /etc/default/grub "" GRUB_THEME /boot/grub/themes/Vimix/theme.txt
    ## Target 720p for the GRUB menu as a minimum to support devices such as the GPD Win.
    ## https://github.com/winesapOS/winesapOS/issues/327
    crudini_wrapper --set /etc/default/grub "" GRUB_GFXMODE 1280x720,auto
    ## Setting the GFX payload to 'text' instead 'keep' makes booting more reliable by supporting all graphics devices.
    ## https://github.com/winesapOS/winesapOS/issues/327
    crudini_wrapper --set /etc/default/grub "" GRUB_GFXPAYLOAD_LINUX text
    # Remove the whitespace from the 'GRUB_* = ' lines that 'crudini' creates.
    sed -i -r "s/(\S*)\s*=\s*(.*)/\1=\2/g" /etc/default/grub
fi
echo "Running 3.1.0 to 3.1.1 upgrades complete."
sudo -E -u "${WINESAPOS_USER_NAME}" "${qdbus_cmd}" "${kdialog_dbus}" /ProgressDialog org.kde.kdialog.ProgressDialog.close

echo "Running 3.1.1 to 3.2.0 upgrades..."
kdialog_dbus=$(sudo -E -u "${WINESAPOS_USER_NAME}" kdialog --title "winesapOS Upgrade" --progressbar "Running 3.1.1 to 3.2.0 upgrades..." 5 | cut -d" " -f1)
sudo -E -u "${WINESAPOS_USER_NAME}" "${qdbus_cmd}" "${kdialog_dbus}" /ProgressDialog showCancelButton false
sudo -E -u "${WINESAPOS_USER_NAME}" "${qdbus_cmd}" "${kdialog_dbus}" /ProgressDialog Set org.kde.kdialog.ProgressDialog value 1

if [[ "${WINESAPOS_DISTRO_DETECTED}" == "steamos" ]]; then
    if ! ${CMD_PACMAN} -Q | grep -q linux-steamos; then
        ${CMD_PACMAN} -R -d --nodeps --noconfirm linux-neptune linux-neptune-headers
        "${CMD_PACMAN_INSTALL[@]}" linux linux-headers
    fi
fi
sudo -E -u "${WINESAPOS_USER_NAME}" "${qdbus_cmd}" "${kdialog_dbus}" /ProgressDialog Set org.kde.kdialog.ProgressDialog value 2

if [[ "${WINESAPOS_IMAGE_TYPE}" != "minimal" ]]; then
    if ! flatpak list | grep -P "^Flatseal" &> /dev/null; then
        "${CMD_FLATPAK_INSTALL[@]}" com.github.tchx84.Flatseal
        cp /var/lib/flatpak/app/com.github.tchx84.Flatseal/current/active/export/share/applications/com.github.tchx84.Flatseal.desktop /home/"${WINESAPOS_USER_NAME}"/Desktop/
        chmod +x /home/"${WINESAPOS_USER_NAME}"/Desktop/com.github.tchx84.Flatseal.desktop
        chown 1000:1000 /home/"${WINESAPOS_USER_NAME}"/Desktop/com.github.tchx84.Flatseal.desktop
    fi
fi
sudo -E -u "${WINESAPOS_USER_NAME}" "${qdbus_cmd}" "${kdialog_dbus}" /ProgressDialog Set org.kde.kdialog.ProgressDialog value 3

if ${CMD_PACMAN} -Q | grep -q game-devices-udev; then
    sudo -u "${WINESAPOS_USER_NAME}" "${CMD_AUR}" --pacman ${CMD_PACMAN} --noconfirm -S --removemake game-devices-udev
fi
sudo -E -u "${WINESAPOS_USER_NAME}" "${qdbus_cmd}" "${kdialog_dbus}" /ProgressDialog Set org.kde.kdialog.ProgressDialog value 4

if [[ "${WINESAPOS_DISTRO_DETECTED}" == "steamos" ]]; then
    # If holo-rel/filesystem is replaced by core/filesystem during an upgrade it can break UEFI boot.
    # https://github.com/winesapOS/winesapOS/issues/514
    if ! grep -P ^IgnorePkg /etc/pacman.conf  | grep -q filesystem; then
        echo "Ignoring the conflicting 'filesystem' package..."
        sed -i 's/IgnorePkg = /IgnorePkg = filesystem /g' /etc/pacman.conf
        echo "Ignoring the conflicting 'filesystem' package complete."
    fi
fi

# Enable the 'snapd' service. This was not enabled in winesapOS <= 3.1.1.
systemctl enable --now snapd

echo "Running 3.1.1 to 3.2.0 upgrades complete."
sudo -E -u "${WINESAPOS_USER_NAME}" "${qdbus_cmd}" "${kdialog_dbus}" /ProgressDialog org.kde.kdialog.ProgressDialog.close

echo "Running 3.2.0 to 3.2.1 upgrades..."
echo "Switching Steam back to the 'stable' update channel..."
rm -f /home/"${WINESAPOS_USER_NAME}"/.local/share/Steam/package/beta
echo "Switching Steam back to the 'stable' update channel complete."
echo "Running 3.2.0 to 3.2.1 upgrades complete."

echo "Running 3.2.1 to 3.3.0 upgrades..."
kdialog_dbus=$(sudo -E -u "${WINESAPOS_USER_NAME}" kdialog --title "winesapOS Upgrade" --progressbar "Running 3.2.1 to 3.3.0 upgrades..." 10 | cut -d" " -f1)
sudo -E -u "${WINESAPOS_USER_NAME}" "${qdbus_cmd}" "${kdialog_dbus}" /ProgressDialog showCancelButton false
echo "Setting up default text editor..."
if grep -q "EDITOR=nano" /etc/environment; then
    echo "Default text editor already set. Skipping..."
else
    echo "Default text editor not already set. Proceeding..."
    echo "EDITOR=nano" >> /etc/environment
fi
echo "Setting up default text editor complete."
sudo -E -u "${WINESAPOS_USER_NAME}" "${qdbus_cmd}" "${kdialog_dbus}" /ProgressDialog Set org.kde.kdialog.ProgressDialog value 1

echo "Switching to the new 'plasma5-themes-vapor-steamos' package..."
if ${CMD_PACMAN} -Q steamdeck-kde-presets; then
    echo "Old 'steamdeck-kde-presets' package detected. Proceeding..."
    rm -f /usr/share/libalpm/hooks/steamdeck-kde-presets.hook
    ${CMD_PACMAN} -R -n --noconfirm steamdeck-kde-presets
    "${CMD_AUR_INSTALL[@]}" plasma5-themes-vapor-steamos
    # Force update "konsole" to get the /etc/xdg/konsolerc file it provides.
    rm -f /etc/xdg/konsolerc
    ${CMD_PACMAN} -S --noconfirm konsole
else
    echo "Old 'steamdeck-kde-presets' package not detected. Skipping..."
fi
echo "Switching to the new 'plasma5-themes-vapor-steamos' package complete."
sudo -E -u "${WINESAPOS_USER_NAME}" "${qdbus_cmd}" "${kdialog_dbus}" /ProgressDialog Set org.kde.kdialog.ProgressDialog value 2

echo "Switching to the new 'libpipewire' package..."
if ${CMD_PACMAN} -Q pipewire; then
    echo "Old 'pipewire' package detected. Proceeding..."
    ${CMD_PACMAN} -R -n --nodeps --nodeps --noconfirm pipewire lib32-pipewire
    "${CMD_PACMAN_INSTALL[@]}" libpipewire lib32-libpipewire
else
    echo "Old 'pipewire' package not detected. Skipping..."
fi
echo "Switching to the new 'libpipewire' package complete."
sudo -E -u "${WINESAPOS_USER_NAME}" "${qdbus_cmd}" "${kdialog_dbus}" /ProgressDialog Set org.kde.kdialog.ProgressDialog value 3

echo "Limiting the number of Snapper backups..."
if ! ls /etc/systemd/system/snapper-cleanup-hourly.timer; then
    sed -i 's/TIMELINE_LIMIT_HOURLY=.*/TIMELINE_LIMIT_HOURLY="10"/g' /etc/snapper/configs/root
    sed -i 's/TIMELINE_LIMIT_HOURLY=.*/TIMELINE_LIMIT_HOURLY="10"/g' /etc/snapper/configs/home
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
sudo -E -u "${WINESAPOS_USER_NAME}" "${qdbus_cmd}" "${kdialog_dbus}" /ProgressDialog Set org.kde.kdialog.ProgressDialog value 4

echo "Setting 'iwd' as the backend for NetworkManager..."
echo -e "[device]\nwifi.backend=iwd" > /etc/NetworkManager/conf.d/wifi_backend.conf
systemctl disable wpa_supplicant
echo "Setting 'iwd' as the backend for NetworkManager complete."

if ! ${CMD_PACMAN} -Q | grep cifs-utils; then
    echo "Adding support for the CIFS/SMB file system..."
    "${CMD_PACMAN_INSTALL[@]}" cifs-utils
    echo "Adding support for the CIFS/SMB file system done."
fi
if ! ${CMD_PACMAN} -Q | grep nfs-utils; then
    echo "Adding support for the NFS file system..."
    "${CMD_PACMAN_INSTALL[@]}" nfs-utils
    echo "Adding support for the NFS file system done."
fi
sudo -E -u "${WINESAPOS_USER_NAME}" "${qdbus_cmd}" "${kdialog_dbus}" /ProgressDialog Set org.kde.kdialog.ProgressDialog value 5

if ! ${CMD_PACMAN} -Q | grep erofs-utils; then
    echo "Adding support for the EROFS file system..."
    "${CMD_PACMAN_INSTALL[@]}" erofs-utils
    echo "Adding support for the EROFS file system done."
fi
sudo -E -u "${WINESAPOS_USER_NAME}" "${qdbus_cmd}" "${kdialog_dbus}" /ProgressDialog Set org.kde.kdialog.ProgressDialog value 6

if ! ${CMD_PACMAN} -Q | grep f2fs-tools; then
    echo "Adding support for the F2FS file system..."
    "${CMD_PACMAN_INSTALL[@]}" f2fs-tools
    echo "Adding support for the F2FS file system done."
fi
sudo -E -u "${WINESAPOS_USER_NAME}" "${qdbus_cmd}" "${kdialog_dbus}" /ProgressDialog Set org.kde.kdialog.ProgressDialog value 7

if ! ${CMD_PACMAN} -Q | grep ssdfs-tools; then
    echo "Adding support for the SSDFS file system..."
    "${CMD_AUR_INSTALL[@]}" ssdfs-tools
    echo "Adding support for the SSDFS file system done."
fi
sudo -E -u "${WINESAPOS_USER_NAME}" "${qdbus_cmd}" "${kdialog_dbus}" /ProgressDialog Set org.kde.kdialog.ProgressDialog value 8

if ! ${CMD_PACMAN} -Q | grep mtools; then
    echo "Adding improved support for FAT file systems..."
    "${CMD_PACMAN_INSTALL[@]}" mtools
    echo "Adding improved support for FAT file systems done."
fi
sudo -E -u "${WINESAPOS_USER_NAME}" "${qdbus_cmd}" "${kdialog_dbus}" /ProgressDialog Set org.kde.kdialog.ProgressDialog value 9

# Only migrate systems that still have the legacy 'mangohud-common' package installed.
# Otherwise, the install below conflicts with the newer 'mangohud-git' package.
if ${CMD_PACMAN} -Q mangohud-common; then
    echo "Updating MangoHud to the new package names..."
    ${CMD_PACMAN} -R -n --nodeps --nodeps --noconfirm mangohud-common mangohud lib32-mangohud
    "${CMD_PACMAN_INSTALL[@]}" mangohud lib32-mangohud
    echo "Updating MangoHud to the new package names complete."
fi
sudo -E -u "${WINESAPOS_USER_NAME}" "${qdbus_cmd}" "${kdialog_dbus}" /ProgressDialog org.kde.kdialog.ProgressDialog.close
echo "Running 3.2.1 to 3.3.0 upgrades complete."

echo "Running 3.3.0 to 3.4.0 upgrades..."
kdialog_dbus=$(sudo -E -u "${WINESAPOS_USER_NAME}" kdialog --title "winesapOS Upgrade" --progressbar "Running 3.3.0 to 3.4.0 upgrades..." 9 | cut -d" " -f1)
sudo -E -u "${WINESAPOS_USER_NAME}" "${qdbus_cmd}" "${kdialog_dbus}" /ProgressDialog showCancelButton false
# Check to see if Electron from the AUR is installed.
# It is a dependency of balena-etcher but takes along
# time and a lot of disk space to compile.
if ${CMD_PACMAN} -Q | grep -P "^electron[0-9]+"; then
    "${CMD_PACMAN_REMOVE[@]}" balena-etcher
    ETCHER_VER="1.19.25"
    export ETCHER_VER
    "${CMD_CURL}" --location "https://github.com/balena-io/etcher/releases/download/v${ETCHER_VER}/balenaEtcher-${ETCHER_VER}-x64.AppImage" --output /home/"${WINESAPOS_USER_NAME}"/Desktop/balenaEtcher.AppImage
    chmod +x /home/"${WINESAPOS_USER_NAME}"/Desktop/balenaEtcher.AppImage
    rm -f /home/"${WINESAPOS_USER_NAME}"/Desktop/balena-etcher-electron.desktop
fi
sudo -E -u "${WINESAPOS_USER_NAME}" "${qdbus_cmd}" "${kdialog_dbus}" /ProgressDialog Set org.kde.kdialog.ProgressDialog value 1

if ! ${CMD_PACMAN} -Q fprintd; then
    "${CMD_PACMAN_INSTALL[@]}" fprintd
fi
sudo -E -u "${WINESAPOS_USER_NAME}" "${qdbus_cmd}" "${kdialog_dbus}" /ProgressDialog Set org.kde.kdialog.ProgressDialog value 2

if ! ls /home/deck; then
    ln -s /home/winesap /home/deck
fi

if ls /etc/systemd/system/winesapos-touch-bar-usbmuxd-fix.service; then
    echo "Upgrading usbmuxd to work with iPhone devices again even with T2 Mac drivers..."
    systemctl disable --now winesapos-touch-bar-usbmuxd-fix
    rm -f /etc/systemd/system/winesapos-touch-bar-usbmuxd-fix.service
    systemctl daemon-reload
    rm -f /usr/local/bin/winesapos-touch-bar-usbmuxd-fix.sh
    rm -f /usr/lib/udev/rules.d/39-usbmuxd.rules
    "${CMD_CURL}" --location "https://raw.githubusercontent.com/libimobiledevice/usbmuxd/master/udev/39-usbmuxd.rules.in" --output /usr/lib/udev/rules.d/39-usbmuxd.rules
    echo "Upgrading usbmuxd to work with iPhone devices again even with T2 Mac drivers complete."
fi

if systemctl --quiet is-enabled iwd; then
    echo "Disabling iwd for better NetworkManager compatibility..."
    # Do not disable '--now' because that would interrupt network connections.
    systemctl disable iwd
    echo "Disabling iwd for better NetworkManager compatibility done."
fi
sudo -E -u "${WINESAPOS_USER_NAME}" "${qdbus_cmd}" "${kdialog_dbus}" /ProgressDialog Set org.kde.kdialog.ProgressDialog value 3

if [[ "${WINESAPOS_IMAGE_TYPE}" != "minimal" ]]; then
    if ! ${CMD_PACMAN} -Q gamescope-session-git; then
        echo "Adding Gamescope Session support..."
        "${CMD_AUR_INSTALL[@]}" gamescope-session-git gamescope-session-steam-git
        echo "Adding Gamescope Session support complete."
    fi

    if ! ${CMD_PACMAN} -Q opengamepadui-bin; then
        echo "Adding Open Gamepad UI..."
        "${CMD_AUR_INSTALL[@]}" opengamepadui-bin opengamepadui-session-git
        echo "Adding Open Gamepad UI complete."
    fi
fi
sudo -E -u "${WINESAPOS_USER_NAME}" "${qdbus_cmd}" "${kdialog_dbus}" /ProgressDialog Set org.kde.kdialog.ProgressDialog value 4

if ! ${CMD_PACMAN} -Q jfsutils; then
    "${CMD_PACMAN_INSTALL[@]}" jfsutils
fi
sudo -E -u "${WINESAPOS_USER_NAME}" "${qdbus_cmd}" "${kdialog_dbus}" /ProgressDialog Set org.kde.kdialog.ProgressDialog value 5

if [[ "${WINESAPOS_IMAGE_TYPE}" != "minimal" ]]; then
    if ! ${CMD_PACMAN} -Q openrazer-daemon; then
        "${CMD_PACMAN_INSTALL[@]}" openrazer-daemon openrazer-driver-dkms python-pyqt5 python-openrazer razercfg
        sudo gpasswd -a "${WINESAPOS_USER_NAME}" plugdev
        systemctl enable --now razerd
        cp /usr/share/applications/razercfg.desktop /home/"${WINESAPOS_USER_NAME}"/Desktop/
        chmod +x /home/"${WINESAPOS_USER_NAME}"/Desktop/razercfg.desktop
    fi
fi
sudo -E -u "${WINESAPOS_USER_NAME}" "${qdbus_cmd}" "${kdialog_dbus}" /ProgressDialog Set org.kde.kdialog.ProgressDialog value 6

if ${CMD_PACMAN} -Q vapor-steamos-theme-kde; then
    "${CMD_PACMAN_REMOVE[@]}" vapor-steamos-theme-kde
    "${CMD_AUR_INSTALL[@]}" plasma5-themes-vapor-steamos
fi
sudo -E -u "${WINESAPOS_USER_NAME}" "${qdbus_cmd}" "${kdialog_dbus}" /ProgressDialog Set org.kde.kdialog.ProgressDialog value 7

if [[ "${WINESAPOS_IMAGE_TYPE}" != "minimal" ]]; then
    if ! ${CMD_PACMAN} -Q oversteer; then
        "${CMD_AUR_INSTALL[@]}" oversteer
        cp /usr/share/applications/org.berarma.Oversteer.desktop /home/"${WINESAPOS_USER_NAME}"/Desktop/
        chmod +x /home/"${WINESAPOS_USER_NAME}"/Desktop/org.berarma.Oversteer.desktop
    fi
fi
sudo -E -u "${WINESAPOS_USER_NAME}" "${qdbus_cmd}" "${kdialog_dbus}" /ProgressDialog Set org.kde.kdialog.ProgressDialog value 8

# Use the new Java Development Kit packages.
# https://archlinux.org/news/incoming-changes-in-jdk-jre-21-packages-may-require-manual-intervention/
for java_edition in jdk jre
    do for java_ver in "" 17 11 8
        do for java_headless in "" -headless
            do if "${CMD_PACMAN}" -Q ${java_edition}${java_ver}-openjdk${java_headless}; then
                yes | ${CMD_PACMAN} -S ${java_edition}${java_ver}-openjdk${java_headless}
            fi
        done
    done
done

if ${CMD_PACMAN} -Q lightdm; then
    if [ ! -f /etc/systemd/system/lightdm.service.d/lightdm-restart-policy.conf ]; then
        mkdir -p /etc/systemd/system/lightdm.service.d/
        "${CMD_CURL}" --location --remote-name "https://raw.githubusercontent.com/winesapOS/winesapOS/4.0.0/files/lightdm-restart-policy.conf" --output-dir /etc/systemd/system/lightdm.service.d/
        "${CMD_CURL}" --location --remote-name "https://raw.githubusercontent.com/winesapOS/winesapOS/4.0.0/files/lightdm-failure-handler.service" --output-dir /etc/systemd/system/
        "${CMD_CURL}" --location --remote-name "https://raw.githubusercontent.com/winesapOS/winesapOS/4.0.0/files/lightdm-success-handler.service" --output-dir /etc/systemd/system/
        systemctl daemon-reload
        systemctl enable lightdm-success-handler
    fi
fi
sudo -E -u "${WINESAPOS_USER_NAME}" "${qdbus_cmd}" "${kdialog_dbus}" /ProgressDialog org.kde.kdialog.ProgressDialog.close
echo "Running 3.3.0 to 3.4.0 upgrades complete."

echo "Running 3.4.0 to 4.0.0 upgrades..."
kdialog_dbus=$(sudo -E -u "${WINESAPOS_USER_NAME}" kdialog --title "winesapOS Upgrade" --progressbar "Running 3.4.0 to 4.0.0 upgrades..." 9 | cut -d" " -f1)
sudo -E -u "${WINESAPOS_USER_NAME}" "${qdbus_cmd}" "${kdialog_dbus}" /ProgressDialog showCancelButton false
sed -i 's/options amdgpu sg_display=0//g' /etc/modprobe.d/winesapos-amd.conf

if ! dmidecode -s system-product-name | grep -P ^Mac; then
    echo "No Mac hardware detected."
    echo "Re-enabling EFI variables..."
    sed -i 's/efi=noruntime //g' /etc/default/grub
fi

if ${CMD_PACMAN} -Q firefox-esr-bin; then
    "${CMD_PACMAN_REMOVE[@]}" firefox-esr-bin
    "${CMD_PACMAN_INSTALL[@]}" firefox-esr
fi
sudo -E -u "${WINESAPOS_USER_NAME}" "${qdbus_cmd}" "${kdialog_dbus}" /ProgressDialog Set org.kde.kdialog.ProgressDialog value 1

if ${CMD_PACMAN} -Q mangohud; then
    "${CMD_PACMAN_REMOVE[@]}" mangohud lib32-mangohud goverlay
    # 'goverlay-git' 1.8.10 and newer now conflict and replace the previous 'pascube' dependency because it is bundled now.
    if ${CMD_PACMAN} -Q pascube; then
        ${CMD_PACMAN} -R -n --nodeps --nodeps --noconfirm pascube
    fi
    "${CMD_PACMAN_INSTALL[@]}" mangohud-git lib32-mangohud-git goverlay-git
fi
sudo -E -u "${WINESAPOS_USER_NAME}" "${qdbus_cmd}" "${kdialog_dbus}" /ProgressDialog Set org.kde.kdialog.ProgressDialog value 2

if ! ${CMD_PACMAN} -Q bcachefs-tools; then
    if ${CMD_PACMAN} -Q bcachefs-tools-git; then
        "${CMD_PACMAN_REMOVE[@]}" linux-bcachefs-git linux-bcachefs-git-headers bcachefs-tools-git
    fi
    "${CMD_PACMAN_INSTALL[@]}" bcachefs-tools
fi
sudo -E -u "${WINESAPOS_USER_NAME}" "${qdbus_cmd}" "${kdialog_dbus}" /ProgressDialog Set org.kde.kdialog.ProgressDialog value 3

if [[ "${WINESAPOS_IMAGE_TYPE}" != "minimal" ]]; then
    if ! ${CMD_PACMAN} -Q distrobox; then
        "${CMD_PACMAN_INSTALL[@]}" distrobox podman
    fi
fi
sudo -E -u "${WINESAPOS_USER_NAME}" "${qdbus_cmd}" "${kdialog_dbus}" /ProgressDialog Set org.kde.kdialog.ProgressDialog value 4

if ! ${CMD_PACMAN} -Q gfs2-utils; then
    "${CMD_AUR_INSTALL[@]}" gfs2-utils
fi
sudo -E -u "${WINESAPOS_USER_NAME}" "${qdbus_cmd}" "${kdialog_dbus}" /ProgressDialog Set org.kde.kdialog.ProgressDialog value 5

if ! ${CMD_PACMAN} -Q glusterfs; then
    "${CMD_PACMAN_INSTALL[@]}" glusterfs
fi
sudo -E -u "${WINESAPOS_USER_NAME}" "${qdbus_cmd}" "${kdialog_dbus}" /ProgressDialog Set org.kde.kdialog.ProgressDialog value 6

if ! ${CMD_PACMAN} -Q ceph-bin; then
    "${CMD_AUR_INSTALL[@]}" ceph-libs-bin ceph-bin
fi
sudo -E -u "${WINESAPOS_USER_NAME}" "${qdbus_cmd}" "${kdialog_dbus}" /ProgressDialog Set org.kde.kdialog.ProgressDialog value 7

if ! grep -q -P "^precedence ::ffff:0:0/96  100$" /etc/gai.conf; then
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

if ! grep -P -q "^fs.file-max=524288" /etc/sysctl.d/00-winesapos.conf 2> /dev/null; then
    if ! grep -P -q "^fs.file-max=524288" /usr/lib/sysctl.d/50-winesapos-open-files.conf 2> /dev/null; then
        echo "vm.max_map_count=16777216
fs.file-max=524288" >> /usr/lib/sysctl.d/50-winesapos-open-files.conf
    fi
fi

if ! grep -P -q "^DefaultLimitNOFILE=524288" /usr/lib/systemd/user.conf.d/20-file-limits.conf 2> /dev/null; then
    mkdir -p /etc/systemd/system.conf.d/
    echo "[Manager]
DefaultLimitNOFILE=524288" > /usr/lib/systemd/user.conf.d/20-file-limits.conf
fi

if (${CMD_PACMAN} -Q mesa && ${CMD_PACMAN} -Q opencl-mesa-steamos); then
    "${CMD_PACMAN_REMOVE[@]}" opencl-mesa-steamos lib32-opencl-mesa-steamos
    "${CMD_PACMAN_INSTALL[@]}" opencl-mesa lib32-opencl-mesa
fi
sudo -E -u "${WINESAPOS_USER_NAME}" "${qdbus_cmd}" "${kdialog_dbus}" /ProgressDialog Set org.kde.kdialog.ProgressDialog value 8

if ${CMD_PACMAN} -Q purpose5; then
    ${CMD_PACMAN} -R -n --nodeps --nodeps --noconfirm purpose5
    "${CMD_PACMAN_INSTALL[@]}" purpose
fi

sudo -E -u "${WINESAPOS_USER_NAME}" "${qdbus_cmd}" "${kdialog_dbus}" /ProgressDialog org.kde.kdialog.ProgressDialog.close
echo "Running 3.4.0 to 4.0.0 upgrades complete."

echo "Running 4.0.0 to 4.1.0 upgrades..."
kdialog_dbus=$(sudo -E -u "${WINESAPOS_USER_NAME}" kdialog --title "winesapOS Upgrade" --progressbar "Running 4.0.0 to 4.1.0 upgrades..." 4 | cut -d" " -f1)
sudo -E -u "${WINESAPOS_USER_NAME}" "${qdbus_cmd}" "${kdialog_dbus}" /ProgressDialog showCancelButton false

if ! ${CMD_PACMAN} -Q packagekit-qt6; then
    # These packages have been removed in KDE Plasma 6.
    # https://github.com/winesapOS/winesapOS/issues/742
    # We no longer want to install PackageKit, either.
    # https://github.com/winesapOS/winesapOS/issues/827
    "${CMD_PACMAN_REMOVE[@]}" packagekit-qt5 plasma-wayland-session
    # Enable Wayland support for the official NVIDIA drivers.
    if ${CMD_PACMAN} -Q | grep -q -P "^nvidia"; then
        if ! grep "nvidia_drm.modeset=1" /etc/default/grub; then
            sed -i 's/GRUB_CMDLINE_LINUX="/GRUB_CMDLINE_LINUX="nvidia_drm.modeset=1 /g' /etc/default/grub
        fi
    fi
fi

if ! grep "mem_sleep_default=deep" /etc/default/grub; then
    echo "Change the default sleep level to be S3 deep sleep..."
    sed -i 's/GRUB_CMDLINE_LINUX="/GRUB_CMDLINE_LINUX="mem_sleep_default=deep /g' /etc/default/grub
fi

if ! ${CMD_PACMAN} -Q modem-manager-gui; then
    "${CMD_PACMAN_INSTALL[@]}" modem-manager-gui usb_modeswitch
fi
sudo -E -u "${WINESAPOS_USER_NAME}" "${qdbus_cmd}" "${kdialog_dbus}" /ProgressDialog Set org.kde.kdialog.ProgressDialog value 1

if ! grep -q kyber /etc/udev/rules.d/60-winesapos-io-schedulers.rules; then
    echo -n "Enabling that optimal IO schedulers..."
    echo '# Serial drives and SD cards.
ACTION=="add|change", KERNEL=="sd[a-z]*|mmcblk[0-9]*", ATTR{queue/scheduler}="bfq"

# NVMe drives.
ACTION=="add|change", KERNEL=="nvme[0-9]*", ATTR{queue/scheduler}="kyber"' > /etc/udev/rules.d/60-winesapos-io-schedulers.rules
fi

# Delete our old session override to ensure that the Plasma Wayland session is used for KDE Plasma >= 6.
if grep -q "XSession=plasma" /var/lib/AccountsService/users/"${WINESAPOS_USER_NAME}"; then
    rm -f /var/lib/AccountsService/users/"${WINESAPOS_USER_NAME}"
fi

if ! ${CMD_PACMAN} -Q linux-fsync-nobara-bin; then
    "${CMD_AUR_INSTALL[@]}" linux-fsync-nobara-bin
fi
sudo -E -u "${WINESAPOS_USER_NAME}" "${qdbus_cmd}" "${kdialog_dbus}" /ProgressDialog Set org.kde.kdialog.ProgressDialog value 2

# The "linux<VERSION" kernels are from Manjaro builds.
obsolete_kernel_pkgs=(
    linux54 linux54-headers \
    linux510 linux510-headers \
    linux515 linux515-headers \
    linux61 linux61-headers \
    linux66 linux66-headers \
    linux612 linux612-headers
)
obsolete_kernel_installed=()
for pkg in "${obsolete_kernel_pkgs[@]}"; do
    if ${CMD_PACMAN} -Q "${pkg}"; then
        obsolete_kernel_installed+=("${pkg}")
    fi
done
if [[ "${#obsolete_kernel_installed[@]}" -gt 0 ]]; then
    ${CMD_PACMAN} -R -n --nodeps --nodeps --noconfirm "${obsolete_kernel_installed[@]}"
    "${CMD_PACMAN_INSTALL[@]}" linux618 linux618-headers
fi
sudo -E -u "${WINESAPOS_USER_NAME}" "${qdbus_cmd}" "${kdialog_dbus}" /ProgressDialog Set org.kde.kdialog.ProgressDialog value 3

if ${CMD_PACMAN} -Q steamdeck-dsp; then
    if ! ${CMD_PACMAN} -Q linux-firmware-valve; then
        "${CMD_PACMAN_INSTALL[@]}" linux-firmware-valve
    fi
fi

sudo -E -u "${WINESAPOS_USER_NAME}" "${qdbus_cmd}" "${kdialog_dbus}" /ProgressDialog org.kde.kdialog.ProgressDialog.close
echo "Running 4.0.0 to 4.1.0 upgrades complete."

echo "Running 4.1.0 to 4.2.0 upgrades..."
# There are none.
echo "Running 4.1.0 to 4.2.0 upgrades complete."

echo "Running 4.2.0 to 4.3.0 upgrades..."
kdialog_dbus=$(sudo -E -u "${WINESAPOS_USER_NAME}" kdialog --title "winesapOS Upgrade" --progressbar "Running 4.2.0 to 4.3.0 upgrades..." 3 | cut -d" " -f1)
sudo -E -u "${WINESAPOS_USER_NAME}" "${qdbus_cmd}" "${kdialog_dbus}" /ProgressDialog showCancelButton false
if ${CMD_PACMAN} -Q steamtinkerlaunch; then
    "${CMD_PACMAN_REMOVE[@]}" steamtinkerlaunch
    "${CMD_AUR_INSTALL[@]}" steamtinkerlaunch-git
fi
sudo -E -u "${WINESAPOS_USER_NAME}" "${qdbus_cmd}" "${kdialog_dbus}" /ProgressDialog Set org.kde.kdialog.ProgressDialog value 1

if ! ${CMD_PACMAN} -Q cups-pdf; then
    "${CMD_PACMAN_INSTALL[@]}" cups-pdf
fi
sudo -E -u "${WINESAPOS_USER_NAME}" "${qdbus_cmd}" "${kdialog_dbus}" /ProgressDialog Set org.kde.kdialog.ProgressDialog value 2

# This firmware is now upstream in 'linux-firmware'.
if ${CMD_PACMAN} -Q linux-firmware-asus; then
    ${CMD_PACMAN} -R -n --nodeps --nodeps --noconfirm linux-firmware-asus
fi
sudo -E -u "${WINESAPOS_USER_NAME}" "${qdbus_cmd}" "${kdialog_dbus}" /ProgressDialog org.kde.kdialog.ProgressDialog.close
echo "Running 4.2.0 to 4.3.0 upgrades complete."

echo "Running 4.3.0 to 4.4.0 upgrades..."
kdialog_dbus=$(sudo -E -u "${WINESAPOS_USER_NAME}" kdialog --title "winesapOS Upgrade" --progressbar "Running 4.3.0 to 4.4.0 upgrades..." 3 | cut -d" " -f1)
sudo -E -u "${WINESAPOS_USER_NAME}" "${qdbus_cmd}" "${kdialog_dbus}" /ProgressDialog showCancelButton false

if ${CMD_PACMAN} -Q asusctl-git; then
    "${CMD_PACMAN_REMOVE[@]}" asusctl-git
    "${CMD_AUR_INSTALL[@]}" asusctl
fi
sudo -E -u "${WINESAPOS_USER_NAME}" "${qdbus_cmd}" "${kdialog_dbus}" /ProgressDialog Set org.kde.kdialog.ProgressDialog value 1

# The "linux-firmware-broadcom" package replaced "linux-firmware-bnx2x" during the "linux-firmware" meta package refactor.
# Checking for that change allows us to fix this upstream issue:
# https://archlinux.org/news/linux-firmware-2025061312fe085f-5-upgrade-requires-manual-intervention/
if ! ${CMD_PACMAN} -Q linux-firmware-broadcom; then
    # Remove these packages without dependencies before re-installing.
    ${CMD_PACMAN} -R -d -d --noconfirm linux-firmware
    ${CMD_PACMAN} -R -d -d --noconfirm linux-firmware-bnx2x
    ${CMD_PACMAN} -R -d -d --noconfirm linux-firmware-valve
    "${CMD_PACMAN_INSTALL[@]}" linux-firmware linux-firmware-broadcom linux-firmware-nvidia linux-firmware-valve
fi
sudo -E -u "${WINESAPOS_USER_NAME}" "${qdbus_cmd}" "${kdialog_dbus}" /ProgressDialog Set org.kde.kdialog.ProgressDialog value 2

# NVK now officially supports more older generations.
sed -i "/NVK_I_WANT_A_BROKEN_VULKAN_DRIVER=1/d" /etc/environment

if ${CMD_PACMAN} -Q dtrx; then
    "${CMD_PACMAN_REMOVE[@]}" dtrx
fi

rm -r -f /home/"${WINESAPOS_USER_NAME}"/.local/state/wireplumber/
if ! ${CMD_PACMAN} -Q pipewire; then
    "${CMD_PACMAN_INSTALL[@]}" pipewire
fi
sudo -E -u "${WINESAPOS_USER_NAME}" "${qdbus_cmd}" "${kdialog_dbus}" /ProgressDialog org.kde.kdialog.ProgressDialog.close
echo "Running 4.3.0 to 4.4.0 upgrades complete."

echo "Running 4.4.0 to 4.5.0 upgrades..."
kdialog_dbus=$(sudo -E -u "${WINESAPOS_USER_NAME}" kdialog --title "winesapOS Upgrade" --progressbar "Running 4.4.0 to 4.5.0 upgrades..." 6 | cut -d" " -f1)
sudo -E -u "${WINESAPOS_USER_NAME}" "${qdbus_cmd}" "${kdialog_dbus}" /ProgressDialog showCancelButton false

if ${CMD_PACMAN} -Q macbook12-spi-driver-dkms; then
    "${CMD_PACMAN_REMOVE[@]}" macbook12-spi-driver-dkms
fi

if [[ -f /usr/lib/systemd/system/sleep-rfkill.service ]]; then
    systemctl disable --now sleep-rfkill
    rm -f /usr/lib/systemd/system/sleep-rfkill.service
fi
sudo -E -u "${WINESAPOS_USER_NAME}" "${qdbus_cmd}" "${kdialog_dbus}" /ProgressDialog Set org.kde.kdialog.ProgressDialog value 1

if ! ${CMD_PACMAN} -Q bcachefs-dkms; then
    "${CMD_PACMAN_REMOVE[@]}" bcachefs-dkms
fi
sudo -E -u "${WINESAPOS_USER_NAME}" "${qdbus_cmd}" "${kdialog_dbus}" /ProgressDialog Set org.kde.kdialog.ProgressDialog value 2

# Reinstall the xpad-noone driver.
if [[ -f /etc/modules-load.d/winesapos-controllers.conf ]]; then
    modprobe -r xpad-noone
    dkms remove -m xpad-noone -v 1.0 --all
    rm -r -f /usr/src/xpad-noone-1.0
    git clone https://github.com/forkymcforkface/xpad-noone /usr/src/xpad-noone-1.0
    # shellcheck disable=SC2010
    for kernel in $(ls -1 /usr/lib/modules/ | grep -P "^[0-9]+"); do
        dkms install -m xpad-noone -v 1.0 -k "${kernel}"
    done
    modprobe xpad-noone
fi
sudo -E -u "${WINESAPOS_USER_NAME}" "${qdbus_cmd}" "${kdialog_dbus}" /ProgressDialog Set org.kde.kdialog.ProgressDialog value 3

if ${CMD_PACMAN} -Q | grep -q -P "coolercontrol (1|2)"; then
    "${CMD_PACMAN_REMOVE[@]}" coolercontrol
    "${CMD_PACMAN_REMOVE[@]}" coolercontrol-liqctld
    "${CMD_PACMAN_INSTALL[@]}" coolercontrol
fi
sudo -E -u "${WINESAPOS_USER_NAME}" "${qdbus_cmd}" "${kdialog_dbus}" /ProgressDialog Set org.kde.kdialog.ProgressDialog value 4

if ${CMD_PACMAN} -Q freerdp2; then
    ${CMD_PACMAN} -R -n --nodeps --nodeps --noconfirm freerdp2
fi
sudo -E -u "${WINESAPOS_USER_NAME}" "${qdbus_cmd}" "${kdialog_dbus}" /ProgressDialog Set org.kde.kdialog.ProgressDialog value 5

# 'mesa-vdpau' is now included in 'mesa'.
if ${CMD_PACMAN} -Q mesa-vdpau; then
    ${CMD_PACMAN} -R -n --nodeps --nodeps --noconfirm mesa-vdpau lib32-mesa-vdpau
fi
sudo -E -u "${WINESAPOS_USER_NAME}" "${qdbus_cmd}" "${kdialog_dbus}" /ProgressDialog org.kde.kdialog.ProgressDialog.close
echo "Running 4.4.0 to 4.5.0 upgrades complete."


kdialog_dbus=$(sudo -E -u "${WINESAPOS_USER_NAME}" kdialog --title "winesapOS Upgrade" --progressbar "Running 4.5.0 to 4.6.0 upgrades..." 16 | cut -d" " -f1)
sudo -E -u "${WINESAPOS_USER_NAME}" "${qdbus_cmd}" "${kdialog_dbus}" /ProgressDialog showCancelButton false

if ${CMD_PACMAN} -Q kdsoap-qt5; then
    ${CMD_PACMAN} -R -n --nodeps --nodeps --noconfirm kdsoap-qt5
fi
sudo -E -u "${WINESAPOS_USER_NAME}" "${qdbus_cmd}" "${kdialog_dbus}" /ProgressDialog Set org.kde.kdialog.ProgressDialog value 1

if ! grep wheel: /etc/group | grep -q "${WINESAPOS_USER_NAME}"; then
    groupadd wheel
    usermod -a -G wheel "${WINESAPOS_USER_NAME}"
fi

if [[ "$(cat /etc/hostname)" == "winesapos" ]]; then
    new_hostname="winesapos-$(uuidgen | cut -d- -f1)"
    echo "${new_hostname}" | tee /etc/hostname
    sed -i "s#winesapos#${new_hostname}#g" /etc/hosts
    hostnamectl set-hostname "${new_hostname}"
fi

if ! ${CMD_PACMAN} -Q plasma-login-manager; then
    if "${CMD_PACMAN_INSTALL[@]}" plasma-login-manager; then
        systemctl disable sddm winesapos-sddm-health-check
        "${CMD_CURL}" --location --remote-name https://raw.githubusercontent.com/winesapOS/winesapOS/main/rootfs/usr/bin/winesapos-plasmalogin-health-check.sh --output-dir /usr/bin/
        chmod +x /usr/bin/winesapos-plasmalogin-health-check.sh
        "${CMD_CURL}" --location --remote-name https://raw.githubusercontent.com/winesapOS/winesapOS/main/rootfs/usr/lib/systemd/system/winesapos-plasmalogin-health-check.service --output-dir /usr/lib/systemd/system/
        systemctl daemon-reload
        systemctl enable plasmalogin winesapos-plasmalogin-health-check
        mkdir -p /var/lib/AccountsService/icons/
        "${CMD_CURL}" --location --remote-name https://raw.githubusercontent.com/winesapOS/winesapOS/main/rootfs/var/lib/AccountsService/icons/winesap --output-dir /var/lib/AccountsService/icons/
        if grep "nopasswdlogin" /etc/pam.d/sddm; then
            echo '#%PAM-1.0
auth       sufficient   pam_succeed_if.so user ingroup nopasswdlogin
auth       include      system-login
account    include      system-login
session    include      system-login
password   include      system-login' > /etc/pam.d/plasmalogin
            echo '#%PAM-1.0
auth       sufficient   pam_succeed_if.so user ingroup nopasswdlogin
auth       include      system-login
account    include      system-login
session    include      system-login
password   include      system-login' > /etc/pam.d/kde
        fi
        # Use Wayland for the display manager and ensure that "Plasma (Wayland)" is the default session.
        echo "[General]
DisplayServer=wayland

[Greeter]
PreselectedSession=plasma.desktop" > /etc/plasmalogin.conf.d/winesapos.conf
        # Workaround Nix build users showing up in the display manager.
        mkdir -p /etc/plasmalogin.conf.d/
        touch /etc/plasmalogin.conf.d/uid.conf
        crudini_wrapper --set /etc/plasmalogin.conf.d/uid.conf Users MaximumUid 2999
    fi
else
    # Allow session selections by the user to be saved again.
    crudini_wrapper --del /etc/plasmalogin.conf.d/winesapos.conf Greeter PreselectedSession
fi

if ! ${CMD_PACMAN} -Q dmemcg-booster; then
    "${CMD_AUR_INSTALL[@]}" dmemcg-booster plasma-foreground-booster-dmemcg
    systemctl enable dmemcg-booster-system
fi
sudo -E -u "${WINESAPOS_USER_NAME}" "${qdbus_cmd}" "${kdialog_dbus}" /ProgressDialog Set org.kde.kdialog.ProgressDialog value 2

if ${CMD_PACMAN} -Q wxgtk3; then
    ${CMD_PACMAN} -R -n --nodeps --nodeps --noconfirm rest wxgtk3
fi
sudo -E -u "${WINESAPOS_USER_NAME}" "${qdbus_cmd}" "${kdialog_dbus}" /ProgressDialog Set org.kde.kdialog.ProgressDialog value 3

if ${CMD_PACMAN} -Q lib32-gstreamer; then
    "${CMD_PACMAN_REMOVE[@]}" lib32-gst-plugins-base-libs lib32-gstreamer
fi
sudo -E -u "${WINESAPOS_USER_NAME}" "${qdbus_cmd}" "${kdialog_dbus}" /ProgressDialog Set org.kde.kdialog.ProgressDialog value 4

# Arch Linux package name.
if ${CMD_PACMAN} -Q steam-native-runtime; then
    "${CMD_PACMAN_REMOVE[@]}" steam-native-runtime
fi
# Manjaro package name.
if ${CMD_PACMAN} -Q steam-native; then
    "${CMD_PACMAN_REMOVE[@]}" steam-native
fi
sudo -E -u "${WINESAPOS_USER_NAME}" "${qdbus_cmd}" "${kdialog_dbus}" /ProgressDialog Set org.kde.kdialog.ProgressDialog value 5

if ${CMD_PACMAN} -Q bauh; then
    echo "Removing bauh..."
    # Do not remove dependencies to keep 'flatpak' and 'snapd' installed.
    # The first '--nodeps' tells Pacman to not remove dependencies.
    # The second '--nodeps' tells is to ignore the packages being required as a dependency for other applications.
    ${CMD_PACMAN} -R -n --nodeps --nodeps --noconfirm bauh
    rm -f /home/"${WINESAPOS_USER_NAME}"/Desktop/bauh.desktop
    echo "Removing bauh complete."
fi
sudo -E -u "${WINESAPOS_USER_NAME}" "${qdbus_cmd}" "${kdialog_dbus}" /ProgressDialog Set org.kde.kdialog.ProgressDialog value 6

if ! ${CMD_PACMAN} -Q shelly-bin; then
    echo "Adding Shelly..."
    "${CMD_AUR_INSTALL[@]}" shelly-bin
    ln -s /usr/share/applications/com.shellyorg.shelly.desktop /home/"${WINESAPOS_USER_NAME}"/Desktop/
    echo "Adding Shelly complete."
fi
sudo -E -u "${WINESAPOS_USER_NAME}" "${qdbus_cmd}" "${kdialog_dbus}" /ProgressDialog Set org.kde.kdialog.ProgressDialog value 7

if ${CMD_PACMAN} -Q appimagepool-appimage; then
    ${CMD_PACMAN} -R -n --nodeps --nodeps --noconfirm appimagepool-appimage
    rm -f /home/"${WINESAPOS_USER_NAME}"/Desktop/appimagepool.desktop
fi
sudo -E -u "${WINESAPOS_USER_NAME}" "${qdbus_cmd}" "${kdialog_dbus}" /ProgressDialog Set org.kde.kdialog.ProgressDialog value 8

if ${CMD_PACMAN} -Q appimagelauncher; then
    "${CMD_PACMAN_REMOVE[@]}" appimagelauncher
fi
sudo -E -u "${WINESAPOS_USER_NAME}" "${qdbus_cmd}" "${kdialog_dbus}" /ProgressDialog Set org.kde.kdialog.ProgressDialog value 9

# 'goverlay-git' 1.8.10 and newer now conflict and replace the previous 'pascube' dependency because it is bundled now.
if ${CMD_PACMAN} -Q pascube; then
    ${CMD_PACMAN} -R -n --nodeps --nodeps --noconfirm pascube
fi
sudo -E -u "${WINESAPOS_USER_NAME}" "${qdbus_cmd}" "${kdialog_dbus}" /ProgressDialog Set org.kde.kdialog.ProgressDialog value 10

# 'spectacle' and other programs now depend on 'tesseract' which depends on 'tesseract-data-*'.
# There are many options for 'tesseract-data-*' packages. Here we define what should be used on winesapOS.
if ! ${CMD_PACMAN} -Q | grep tessdata; then
    "${CMD_PACMAN_INSTALL[@]}" tesseract-data-eng tesseract-data-osd
fi
sudo -E -u "${WINESAPOS_USER_NAME}" "${qdbus_cmd}" "${kdialog_dbus}" /ProgressDialog Set org.kde.kdialog.ProgressDialog value 11

# This package is no longer available.
if ${CMD_PACMAN} -Q qemu-block-gluster; then
    ${CMD_PACMAN} -R -n --nodeps --nodeps --noconfirm qemu-block-gluster
fi
sudo -E -u "${WINESAPOS_USER_NAME}" "${qdbus_cmd}" "${kdialog_dbus}" /ProgressDialog Set org.kde.kdialog.ProgressDialog value 12

# 'lib32-libcap' and 'lib32-libpcap' (not the 64-bit variants) packages have been abanonded.
if ${CMD_PACMAN} -Q lib32-libcap; then
    ${CMD_PACMAN} -R -n --nodeps --nodeps --noconfirm lib32-libcap
fi
sudo -E -u "${WINESAPOS_USER_NAME}" "${qdbus_cmd}" "${kdialog_dbus}" /ProgressDialog Set org.kde.kdialog.ProgressDialog value 13
if ${CMD_PACMAN} -Q lib32-libpcap; then
    ${CMD_PACMAN} -R -n --nodeps --nodeps --noconfirm lib32-libpcap
fi
sudo -E -u "${WINESAPOS_USER_NAME}" "${qdbus_cmd}" "${kdialog_dbus}" /ProgressDialog Set org.kde.kdialog.ProgressDialog value 14

if ${CMD_PACMAN} -Q lib32-libbpf; then
    ${CMD_PACMAN} -R -n --nodeps --nodeps --noconfirm lib32-libbpf
fi
sudo -E -u "${WINESAPOS_USER_NAME}" "${qdbus_cmd}" "${kdialog_dbus}" /ProgressDialog Set org.kde.kdialog.ProgressDialog value 15

if ${CMD_PACMAN} -Q lib32-v4l-utils; then
    ${CMD_PACMAN} -R -n --nodeps --nodeps --noconfirm lib32-v4l-utils
fi
sudo -E -u "${WINESAPOS_USER_NAME}" "${qdbus_cmd}" "${kdialog_dbus}" /ProgressDialog org.kde.kdialog.ProgressDialog.close
echo "Running 4.5.0 to 4.6.0 upgrades complete."

kdialog_dbus=$(sudo -E -u "${WINESAPOS_USER_NAME}" kdialog --title "winesapOS Upgrade" --progressbar "Running 4.6.0 to 4.7.0 upgrades..." 1 | cut -d" " -f1)
sudo -E -u "${WINESAPOS_USER_NAME}" "${qdbus_cmd}" "${kdialog_dbus}" /ProgressDialog showCancelButton false

if ${CMD_PACMAN} -Q lib32-audit; then
    ${CMD_PACMAN} -R -n --nodeps --nodeps --noconfirm lib32-audit
fi

sudo -E -u "${WINESAPOS_USER_NAME}" "${qdbus_cmd}" "${kdialog_dbus}" /ProgressDialog org.kde.kdialog.ProgressDialog.close
echo "Running 4.6.0 to 4.7.0 upgrades complete."

echo "Upgrading system packages..."
kdialog_dbus=$(sudo -E -u "${WINESAPOS_USER_NAME}" kdialog --title "winesapOS Upgrade" --progressbar "Please wait for all system packages to upgrade (this can take a long time)..." 12 | cut -d" " -f1)
sudo -E -u "${WINESAPOS_USER_NAME}" "${qdbus_cmd}" "${kdialog_dbus}" /ProgressDialog showCancelButton false
sudo -E -u "${WINESAPOS_USER_NAME}" "${qdbus_cmd}" "${kdialog_dbus}" /ProgressDialog Set org.kde.kdialog.ProgressDialog value 1

# Remove the problematic 'fatx' package first.
# https://github.com/winesapOS/winesapOS/issues/651
fatx_old_found=0
if ${CMD_PACMAN} -Q | grep -P "fatx 1\.[0-8]"; then
    fatx_old_found=1
    "${CMD_PACMAN_REMOVE[@]}" fatx
fi

# Remove the problematic 'gwenview' package.
gwenview_found=0
if ${CMD_PACMAN} -Q gwenview; then
    gwenview_found=1
    "${CMD_PACMAN_REMOVE[@]}" gwenview
    ${CMD_PACMAN} -R -n --nodeps --nodeps --noconfirm baloo5
fi

# The Replay Sorcery project was abandoned a long time ago.
# The AUR package was also dropped because it no longer builds.
for pkg in replay-sorcery replay-sorcery-git; do
    if ${CMD_PACMAN} -Q "${pkg}"; then
        "${CMD_PACMAN_REMOVE[@]}" "${pkg}"
    fi
done

# The 'base-devel' package needs to be explicitly updated since it was changed to a meta package.
# https://github.com/winesapOS/winesapOS/issues/569
${CMD_PACMAN} -S -y --noconfirm base-devel

# On old builds of Mac Linux Gaming Stick, this file is provided by 'filesystem' but is replaced by 'systemd' in newer versions.
# Detect if it is the old version and, if so, delete the conflicting file.
# https://github.com/winesapOS/winesapOS/issues/229#issuecomment-1595868315
if grep -q "LC_COLLATE=C" /usr/share/factory/etc/locale.conf; then
    rm -f /usr/share/factory/etc/locale.conf
fi

# If needed, repair Pacman before starting a full system upgrade.
if ! check_pacman_corruption; then
    repair_pacman
    if ! check_pacman_corruption; then
        echo "Pacman repository databases are still corrupt after a repair."
        winesapos_upgrade_failure
    fi
fi

# Remove obsolete packages.
# Most of thse are found in Mac Linux Gaming Stick (winesapOS 2).
obsolete_aur_pkgs=(
    cheese \
    clutter-gst clutter-gtk \
    openssl-1.0 lib32-openssl-1.0 \
    glew1.10 lib32-glew1.10 \
    gtk2 lib32-gtk2 \
    libgcrypt15 lib32-libgcrypt15 \
    lib32-libappindicator-gtk2 \
    lib32-libjpeg6-turbo \
    libdbusmenu-gtk2 lib32-libdbusmenu-gtk2 \
    libidn11 lib32-libidn11 \
    libindicator-gtk2 lib32-libindicator-gtk2 \
    libpng12 lib32-libpng12 \
    librtmp0 lib32-librtmp0 \
    libtiff4 lib32-libtiff4 \
    libudev0-shim lib32-libudev0-shim \
    libvpx1.3 lib32-libvpx1.3 \
    libwrap lib32-libwrap \
    webkit2gtk
)
obsolete_aur_installed=()
for pkg in "${obsolete_aur_pkgs[@]}"; do
    if ${CMD_PACMAN} -Q "${pkg}" &> /dev/null; then
        obsolete_aur_installed+=("${pkg}")
    fi
done
if [[ "${#obsolete_aur_installed[@]}" -gt 0 ]]; then
    echo "Removing obsolete packages to avoid rebuilding them from the AUR: ${obsolete_aur_installed[*]}..."
    ${CMD_PACMAN} -R -n --nodeps --nodeps --noconfirm "${obsolete_aur_installed[@]}"
    echo "Removing obsolete packages complete."
fi

echo "CURRENT PACKAGES BEFORE PACMAN UPGRADE:"
"${CMD_PACMAN}" -Q

# This upgrade needs to happen before updating the Linux kernels.
# Otherwise, it can lead to an unbootable system.
# https://github.com/winesapOS/winesapOS/issues/379#issuecomment-1166577683
${CMD_PACMAN} -S -u --noconfirm

# Check to see if the previous update failed by seeing if there are still packages to be downloaded for an upgrade.
# If there are, try to upgrade all of the system packages one more time.
if ! check_update_pacman; then
    refresh_mirrorlist
    # This second time, overwrite existing files on the file system to force the upgrade to continue.
    ${CMD_PACMAN} -S -u --overwrite '*' --noconfirm
    if ! check_update_pacman; then
        winesapos_upgrade_failure
    fi
fi

# Fix Pacman 7 permissions.
mkdir -p /var/cache/pacman/ /var/lib/pacman/
chown -R root:alpm /var/cache/pacman/ /var/lib/pacman/
chmod -R 775 /var/cache/pacman/ /var/lib/pacman/

sudo -E -u "${WINESAPOS_USER_NAME}" "${qdbus_cmd}" "${kdialog_dbus}" /ProgressDialog Set org.kde.kdialog.ProgressDialog value 2

flatpak repair
flatpak update -y --noninteractive
flatpak uninstall --unused -y --noninteractive
sudo -E -u "${WINESAPOS_USER_NAME}" "${qdbus_cmd}" "${kdialog_dbus}" /ProgressDialog Set org.kde.kdialog.ProgressDialog value 3

sudo -E -u "${WINESAPOS_USER_NAME}" flatpak repair
sudo -E -u "${WINESAPOS_USER_NAME}" flatpak update -y --noninteractive
sudo -E -u "${WINESAPOS_USER_NAME}" flatpak uninstall --unused -y --noninteractive
sudo -E -u "${WINESAPOS_USER_NAME}" "${qdbus_cmd}" "${kdialog_dbus}" /ProgressDialog Set org.kde.kdialog.ProgressDialog value 4
# Remove the Flatpak directory for the user to avoid errors.
# This directory will automatically get re-generated when a 'flatpak' command is ran.
# https://github.com/winesapOS/winesapOS/issues/516
rm -r -f /home/"${WINESAPOS_USER_NAME}"/.local/share/flatpak

# Remove the old 'ceph-libs' package from the AUR that is no longer used.
# The newer version also fails to compile causing all AUR upgrades to fail.
if ${CMD_PACMAN} -Q ceph-libs; then
    "${CMD_PACMAN_REMOVE[@]}" ceph-libs
fi

if ${CMD_PACMAN} -Q python-pep517; then
    "${CMD_PACMAN_REMOVE[@]}" python-pep517
fi

plasma_desktop_major_ver="$(${CMD_PACMAN} -Q plasma-desktop 2> /dev/null | cut -d' ' -f2 | cut -d. -f1)"
if [[ "${plasma_desktop_major_ver}" -ge 6 ]] 2> /dev/null; then
    echo "Removing obsolete KDE Plasma 5 packages to avoid rebuilding them from the AUR..."
    plasma5_pkgs_obsolete=(
        bluez-qt5 \
        kactivities-stats5 \
        kdelibs4support \
        kdesu5 \
        kdnssd5 \
        kemoticons \
        kfilemetadata5 \
        kholidays5 \
        kitemmodels5 \
        kpeople5 \
        kunitconversion5 \
        modemmanager-qt5 \
        networkmanager-qt5 \
        phonon-qt5 \
        phonon-qt5-gstreamer \
        phonon-qt5-vlc \
        plasma-framework5 \
        prison5 \
        qqc2-desktop-style5 \
        qt5-location \
        qt5-sensors \
        qt5-webchannel \
        qt5-webengine \
        qt5-webview \
    )
    plasma5_pkgs_installed=()
    for pkg in "${plasma5_pkgs_obsolete[@]}"; do
        if ${CMD_PACMAN} -Q "${pkg}"; then
            plasma5_pkgs_installed+=("${pkg}")
        fi
    done
    if [[ "${#plasma5_pkgs_installed[@]}" -gt 0 ]]; then
        ${CMD_PACMAN} -R -n --nodeps --nodeps --noconfirm "${plasma5_pkgs_installed[@]}"
    fi
    echo "Removing obsolete KDE Plasma 5 packages complete."
fi

# 'yay' is no longer used for upgrades but it is still shipped for interactive use.
# Replace an old manual installation of it with the Pacman package from the Chaotic AUR.
if ! ${CMD_PACMAN} -Q | grep -q -P "^yay"; then
    echo "Replacing a manual installation of 'yay' with a package installation..."
    mv /usr/bin/yay /usr/local/bin/yay
    hash -r
    if "${CMD_PACMAN_INSTALL[@]}" yay; then
        rm -f /usr/local/bin/yay
    else
        mv /usr/local/bin/yay /usr/bin/yay
    fi
    hash -r
    echo "Replacing a manual installation of 'yay' with a package installation complete."
fi

# 'js78' needs to be removed after a full system upgrade to avoid removing Cinnamon desktop environment dependencies.
if ${CMD_PACMAN} -Q js78; then
    "${CMD_PACMAN_REMOVE[@]}" js78
fi

# Remove unused packages before the AUR upgrade.
# Otherwise, old AUR packages that are no longer required are rebuilt from source.
remove_unused_pkgs

echo "CURRENT PACKAGES BEFORE AUR UPGRADE:"
"${CMD_PACMAN}" -Q

# Try again to install 'paru-static' now that the Pacman repositories are up-to-date.
# Older winesapOS images point at an older winesapOS repository that does not have it yet.
install_static_paru

sudo -u "${WINESAPOS_USER_NAME}" "${CMD_AUR}" --pacman ${CMD_PACMAN} -S -y -y -u --noconfirm
if ! check_update_aur; then
    sudo -u "${WINESAPOS_USER_NAME}" "${CMD_AUR}" --pacman ${CMD_PACMAN} -S -y -y -u --overwrite '*' --noconfirm
    # If there are still AUR package updates, report a failure.
    if ! check_update_aur; then
        winesapos_upgrade_failure
    fi
fi

# Re-install packages that had to be removed before the upgrade.
if [[ "${fatx_old_found}" == "1" ]]; then
    "${CMD_PACMAN_INSTALL[@]}" fatx
fi
if [[ "${gwenview_found}" == "1" ]]; then
    "${CMD_PACMAN_INSTALL[@]}" gwenview
fi

# Re-add this setting for the Plasma 5 Vapor theme after the system upgrade is complete.
crudini_wrapper --set /etc/xdg/konsolerc "Desktop Entry" DefaultProfile Vapor.profile
sudo -E -u "${WINESAPOS_USER_NAME}" "${qdbus_cmd}" "${kdialog_dbus}" /ProgressDialog Set org.kde.kdialog.ProgressDialog value 5
echo "Upgrading system packages complete."

echo "Upgrading ignored packages..."
if [[ "${WINESAPOS_DISTRO_DETECTED}" == "arch" ]]; then
    yes | ${CMD_PACMAN} -S core/linux-lts core/linux-lts-headers core/grub core/filesystem
elif [[ "${WINESAPOS_DISTRO_DETECTED}" == "manjaro" ]]; then
    yes | ${CMD_PACMAN} -S core/linux618 core/linux618-headers core/grub
    # Due to conflicts between Mac Linux Gaming Stick 2 versus winesapOS 3, do not replace the 'filesystem' package.
    # https://github.com/winesapOS/winesapOS/issues/229#issuecomment-1595886615
    if [[ "${WINESAPOS_USER_NAME}" == "stick" ]]; then
        yes | ${CMD_PACMAN} -S core/filesystem
    else
        yes | ${CMD_PACMAN} -S holo-rel/filesystem
    fi
elif [[ "${WINESAPOS_DISTRO_DETECTED}" == "steamos" ]]; then
    yes | ${CMD_PACMAN} -S core/linux-lts core/linux-lts-headers linux-steamos linux-steamos-headers core/grub holo-rel/filesystem
fi
echo "Upgrading ignored packages done."
sudo -E -u "${WINESAPOS_USER_NAME}" "${qdbus_cmd}" "${kdialog_dbus}" /ProgressDialog Set org.kde.kdialog.ProgressDialog value 6

echo "Fixing the SDDM virtual keyboard..."
# Workaround broken virtual keyboard.
# https://github.com/winesapOS/winesapOS/issues/1062
# https://github.com/winesapOS/winesapOS/issues/1144
if ! ${CMD_PACMAN} -Q plasma-keyboard; then
    "${CMD_PACMAN_INSTALL[@]}" plasma-keyboard
    echo "[General]
DisplayServer=wayland
GreeterEnvironment=QT_WAYLAND_SHELL_INTEGRATION=layer-shell

[Wayland]
CompositorCommand=kwin_wayland --drm --no-lockscreen --no-global-shortcuts --locale1 --inputmethod plasma-keyboard" > /etc/sddm.conf.d/winesapos.conf
    echo "KWIN_IM_SHOW_ALWAYS=1" >> /etc/environment
fi
echo "Fixing the SDDM virtual keyboard done."

if ${CMD_PACMAN} -Q | grep -q nvidia-dkms; then
    echo "Upgrading NVIDIA drivers..."
    ${CMD_PACMAN} -S --noconfirm \
      extra/nvidia-dkms \
      extra/nvidia-utils \
      multilib/lib32-nvidia-utils \
      extra/opencl-nvidia \
      multilib/lib32-opencl-nvidia
    echo "Upgrading NVIDIA drivers complete."
fi
sudo -E -u "${WINESAPOS_USER_NAME}" "${qdbus_cmd}" "${kdialog_dbus}" /ProgressDialog Set org.kde.kdialog.ProgressDialog value 7

remove_unused_pkgs
sudo -E -u "${WINESAPOS_USER_NAME}" "${qdbus_cmd}" "${kdialog_dbus}" /ProgressDialog Set org.kde.kdialog.ProgressDialog value 8

if dmidecode -s system-product-name | grep -P ^Mac; then
    echo "Mac hardware detected."

    if ! ${CMD_PACMAN} -Q mbpfan-git; then
        echo "Installing MacBook fan support..."
        "${CMD_AUR_INSTALL[@]}" mbpfan-git
        crudini_wrapper --set /etc/mbpfan.conf general min_fan_speed 1300
        crudini_wrapper --set /etc/mbpfan.conf general max_fan_speed 6200
        crudini_wrapper --set /etc/mbpfan.conf general max_temp 105
        systemctl enable --now mbpfan
        echo "Installing MacBook fan support complete."
    fi
else
    echo "No Mac hardware detected."
fi
sudo -E -u "${WINESAPOS_USER_NAME}" "${qdbus_cmd}" "${kdialog_dbus}" /ProgressDialog Set org.kde.kdialog.ProgressDialog value 9

# winesapOS 3.0.Y will have broken UEFI boot after an upgrade so we need to re-install it.
# Legacy BIOS boot is unaffected.
# https://github.com/winesapOS/winesapOS/issues/695
if grep "3.0*" /etc/winesapos/VERSION; then
    grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=winesapOS --removable --no-nvram
fi

echo "Rebuilding initramfs with new drivers..."
mkinitcpio -P
echo "Rebuilding initramfs with new drivers complete."
sudo -E -u "${WINESAPOS_USER_NAME}" "${qdbus_cmd}" "${kdialog_dbus}" /ProgressDialog Set org.kde.kdialog.ProgressDialog value 10

echo "Updating Btrfs snapshots in the GRUB menu..."
grub-mkconfig -o /boot/grub/grub.cfg
if [ -f /usr/share/libalpm/hooks/winesapos-etc-grub.d-10_linux.hook ]; then
    if ! grep -q "search --no-floppy --label winesapos-root --set root" /boot/grub/grub.cfg; then
        winesapos_upgrade_failure
    fi
    if ! grep -q "root=LABEL=winesapos-root" /boot/grub/grub.cfg; then
        winesapos_upgrade_failure
    fi
fi
echo "Updating Btrfs snapshots in the GRUB menu complete."

# Allow PackageKit (required for Discover) to work again.
systemctl unmask packagekit

# Fix Plasma 6.2 upgrade issues.
# https://github.com/winesapOS/winesapOS/issues/983
mkdir -p "/etc/winesapos/plasma-configs-${START_TIME}/"
mv /home/"${WINESAPOS_USER_NAME}"/.config/*plasma* "/etc/winesapos/plasma-configs-${START_TIME}/"
mv /home/"${WINESAPOS_USER_NAME}"/.config/*kde* "/etc/winesapos/plasma-configs-${START_TIME}/"
mv /home/"${WINESAPOS_USER_NAME}"/.config/*kwin* "/etc/winesapos/plasma-configs-${START_TIME}/"

if [[ "${WINESAPOS_IMAGE_TYPE}" == "secure" ]]; then
    echo "Disallow passwordless 'sudo' now that the upgrade is done..."
    rm -f /etc/sudoers.d/"${WINESAPOS_USER_NAME}"
    mv /root/etc-sudoersd-"${WINESAPOS_USER_NAME}" /etc/sudoers.d/"${WINESAPOS_USER_NAME}"
    echo "Disallow passwordless 'sudo' now that the upgrade is done complete."
fi

echo "NEW PACKAGES:"
"${CMD_PACMAN}" -Q

echo "VERSION_ORIGINAL=${WINESAPOS_VERSION_ORIGINAL},VERSION_NEW=${WINESAPOS_VERSION_NEW},DATE=${START_TIME}" >> /etc/winesapos/UPGRADED
rm -f /etc/winesapos/VERSION /etc/winesapos/IMAGE_TYPE /usr/lib/os-release-winesapos
"${CMD_CURL}" --location https://raw.githubusercontent.com/winesapOS/winesapOS/main/rootfs/usr/lib/os-release-winesapos --output /usr/lib/os-release-winesapos
# shellcheck disable=SC2027 disable=2086
echo -e "VARIANT=\""${WINESAPOS_IMAGE_TYPE}""\"\\nVARIANT_ID=${WINESAPOS_IMAGE_TYPE} | tee -a /usr/lib/os-release-winesapos
ln -s /usr/lib/os-release-winesapos /etc/os-release-winesapos
sudo -E -u "${WINESAPOS_USER_NAME}" "${qdbus_cmd}" "${kdialog_dbus}" /ProgressDialog Set org.kde.kdialog.ProgressDialog value 11

# Force a sync of all writes to the storage device since winesapOS is configured with a delayed write commit time.
sync
sudo -E -u "${WINESAPOS_USER_NAME}" "${qdbus_cmd}" "${kdialog_dbus}" /ProgressDialog org.kde.kdialog.ProgressDialog.close

# shellcheck disable=SC2181
test_internet_connection
if [ $? -ne 1 ]; then
    sudo -E -u "${WINESAPOS_USER_NAME}" kdialog --title "winesapOS Upgrade" --msgbox "Upgrade complete but no network connection detected. There may have been an issue during the upgrade."
else
    sudo -E -u "${WINESAPOS_USER_NAME}" kdialog --title "winesapOS Upgrade" --msgbox "Upgrade complete! Please reboot to load new changes."
fi

echo "End time: $(date --iso-8601=seconds)"

exit "${failed_tests}"
