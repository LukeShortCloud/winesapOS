# Upgrade Notes

## 4.0.0 to 4.1.0

- Change KDE Plasma from version 5 to 6.
- Change the default sleep level to be S3 deep sleep.
- Add support for cellular modems.
- Change IO schedulers to be optimal depending on the storage type.
- Change the default session of KDE Plasma to use Wayland instead of Xorg.
- Change upgrade to remove unused Pacman packages when done.
- Change 'python-crudini' package to use the newer 'crudini' package instead.
- Change primary Linux kernel from Linux T2 to Linux Nobara.
- Remove PackageKit in favor of bauh.
- Add a symlink for forwards compatibility from /etc/winesapos/ to /var/winesapos/.
- Add support for sound on the Steam Deck OLED.

## 3.4.0 to 4.0.0

**Action Required:**

- None.

**No Action Required:**

- Remove no longer needed "amdgpu.sg_display=0" workaround.
- Change EFI variables to be available again on non-Mac hardware.
- Add the Chaotic AUR repository.
- Change 'linux-lts' to be Linux 6.6 instead of 6.1.
- Change Bcachefs to be installed using the official packages instead of from the AUR.
- Change Flatpaks to be updated for both the user and system.
- Change upgrade to allow the [winesapos-testing] repository.
- Change upgrade to allow skipping the version check.
- Change Internet connection check to have a progress bar.
- Add Distrobox for managing containers.
- Add support for the GFS2 file system.
- Add support for the CephFS file system.
- Change 'pacman-static' to be installed as a package instead of a single binary.
- Change IPv4 network traffic to be prioritized over IPv6.
- Change open file limits to be higher.

## 3.3.0 to 3.4.0

**Action Required:**

- None.

**No Action Required:**

- BalenaEtcher system package is replaced with the AppImage which makes the upgrade process much faster and use less disk space.
- Add GPG signatures to all winesapOS packages and the database metadata.
- Add fingerprint scanning support.
- Add improved compatibility with community Steam Deck apps.
- Add Wayland support for KDE Plasma.
- Change 'crudini' package to use the newer 'python-crudini' package instead.
- Add support for iPhone file transfers and Internet tethering.
- Add a Gamescope session for Steam.
- Add Open Gamepad UI.
- Add a Gamescope session for Open Gamepad UI.
- Add Journaled File System (JFS) support.
- Add support for Razer accessories.
- Change the 'vapor-steamos-theme-kde' package to be the newly renamed 'plasma5-themes-vapor-steamos' package.
- Add Oversteer for managing racing wheels and related accessories.
- Change OpenJDK to the newly split Arch Linux package.
- Add a fail-safe service to switch to a TTY console if the display manager fails to load.

## 3.2.1 to 3.3.0

**Action Required:**

- None.

**No Action Required:**

- 'base-devel' is manually upgraded.
- 'pacman' is manually upgraded to deal with the [community] repository being merged into the [extra] repository.
- Packages are now installed from the renamed [holo-rel] repository instead of the original [holo] repository.
- 'steamdeck-kde-presets' is now replaced by 'vapor-steamos-theme-kde'.
- 'nano' is set as the default text editor.
- 'pipewire' is now split into two packages: 'pipewire' and 'libpipewire'.
- Snapper now only keeps up to 10 hourly snapshots.
- NetworkManager now uses the IWD backend.
- Add support for major upgrades from Mac Linux Gaming Stick 2 to winesapOS 3.
- 'yay' is now installed as a package instead of a locally installed binary.
- 'snd-hda-codec-cs8409' audio driver for Macs is updated to work with Linux LTS 6.1.
- Add the AppImagePool package manager.
- Add support for the CIFS/SMB network file system.
- Add support for the NFS network file system.
- Add support for the EROFS file system.
- Add support for the F2FS file system.
- Add support for the SSDFS file system.
- Add improved support for FAT file systems.
- Add support for the ReiserFS file system.
- Add support for the FATX16 and FATX32 file systems.
- Change the latest Linux LTS to be version 6.1.
- Change MangoHud to use the new package names.
- Change to using 'pacman-static' during upgrades for a more stable upgrade experience.

## 3.2.0 to 3.2.1

**Action Required:**

- None.

**No Action Required:**

- The "Steam Deck Client" is changed from the "beta" to "stable" update channel.
- The SteamOS repositories now use the new SteamOS 3.4 names.

## 3.1.1 to 3.2.0

**Action Required:**

- None.

**No Action Required:**

- 'linux-neptune' is replaced by 'linux'.
- Flatseal is installed.
- GParted is installed.
- 'game-devices-udev' is installed.
- Pamac is replaced by bauh.
- 'broadcom-wl' is installed.
- 'mbpfan-git' is installed.

## 3.1.0 to 3.1.1

**Action Required:**

- None.

**No Action Required:**

- 'pipewire-media-session' is replaced by 'wireplumber'.
- Vimix theme for GRUB is installed.

## 3.0.1 to 3.1.0

**Action Required:**

- None.

**No Action Required:**

- winesapOS now has a repository that is added.
- Temporary mounts switched from `ramfs` to `tmpfs` to support FUSE which is required by AppImage and Flatpaks.
- SteamOS 3.2 provides a new 'linux-firmware-neptune-rtw-debug' package that replaces 'linux-firmware'. This makes systems unbootable. The new package is now ignored and removed if detected.
- Upstream Arch Linux repositories are enabled since SteamOS has not updated their mirror Arch Linux packages since launch. This fixes various issues.
- ProtonUp-Qt is installed as a Flatpak instead of from the AUR due to build issues.
- Xbox controller support is added.
- AntiMicroX is installed to support configuring controllers.
- A simple text editor, kate, is installed.
- The GRUB menu is now updated after an upgrade to include new Btrfs snapshots.
- 'mesa' is replaced by 'mesa-steamos' which is a customized package of Mesa from SteamOS for support for all graphics drivers (not just AMD).
- 'clang-libs' is replaced by 'clang' which is a newer version from Arch Linux.
- The remote upgrade script itself is now always updated for smoother upgrades.
- Ignored packages such as Linux kernels and GRUB will now be updated.
- Mac drivers are now re-installed for the newer Linux kernels.
- NVIDIA graphics drivers will now be updated.
- All system packages will now be upgraded as part of winesapOS upgrades.

## 3.0.0 to 3.0.1

**Action Required:**

- None.

**No Action Required:**

- `makepkg` (used by `yay` to build packages) is configured to use all available cores for faster package builds.
- Pamac from the AUR is broken upstream and is fixed by installing an older version.

## 3.0.0-rc.0 to 3.0.0

**Action Required:**

- None.

**No Action Required:**

- The exFAT partition is updated with the "msdata" flag to allow it to be mounted on Windows automatically.

## 2.1.0 to 2.2.0

**Action Required:**

- None.

**No Action Required:**

- The initramfs is updated with more storage device drivers to help with boot problems.
    - Refer to: https://github.com/LukeShortCloud/winesapOS/issues/94
- Pacman is now configured to download up to 5 packages in parallel (instead of the default of 1).

## 2.0.0 to 2.1.0

**Action Required:**

- None.

**No Action Required:**

- Btrfs mounts now use zstd compression and have TRIM/discard support enabled.
- Linux 5.4 kernel is installed as an alternative to the Linux 5.10 kernel.
- apple-bce drivers are updated.
- GRUB menu now shows up on boot.
- Heroic Games Launcher is installed for playing Epic Games Store games.
- smartmontools is installed for monitoring drive health.
- Shortcuts are added to the desktop for game launchers and the office suite.
- Proton-6.5-GE-2 is installed as an alternative Steam Play compatibility tool.
- Printer drivers are installed.
