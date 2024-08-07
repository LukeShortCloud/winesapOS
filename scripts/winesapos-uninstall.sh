#!/bin/bash

# Log the standard output and error of the uninstall to a location that will still exist when done (the 'root' user home directory).
exec > >(tee /root/winesapos-uninstall.log) 2>&1

# Remove winesapOS and SteamOS repositories.
crudini --del /etc/pacman.conf winesapos
crudini --del /etc/pacman.conf winesapos-testing
crudini --del /etc/pacman.conf jupiter
crudini --del /etc/pacman.conf holo
crudini --del /etc/pacman.conf jupiter-rel
crudini --del /etc/pacman.conf holo-rel
pacman -S -y

rm -r -f \
  /etc/os-release-winesapos \
  /etc/systemd/system/pacman-mirrors.service \
  /etc/systemd/system/snapper-cleanup-hourly.timer \
  /etc/systemd/system/winesapos-flatpak-update.service \
  /etc/systemd/system/winesapos-resize-root-file-system.service \
  /etc/winesapos/ \
  /home/winesap/.winesapos/ \
  /home/winesap/Desktop/winesapos-dual-boot.desktop \
  /home/winesap/Desktop/winesapos-setup.desktop \
  /home/winesap/Desktop/winesapos-upgrade.desktop \
  /usr/lib/os-release-winesapos \
  /usr/local/bin/winesapos-dual-boot.sh \
  /usr/local/bin/winesapos-resize-root-file-system.sh \
  /usr/share/sddm/faces/winesap.face.icon \
  /var/winesapos/

systemctl daemon-reload
