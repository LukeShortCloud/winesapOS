FROM archlinux:latest
#FROM manjarolinux/base:latest

RUN pacman -S -y --noconfirm && pacman -S --noconfirm --needed base-devel git python-setuptools python-setuptools-scm && echo -e '[multilib]\nInclude = /etc/pacman.d/mirrorlist\n' >> /etc/pacman.conf && pacman -S -y && pacman -S --noconfirm wget && sed -i s'/\[options\]/\[options\]\nXferCommand = \/usr\/bin\/wget --passive-ftp -c -O %o %u/'g /etc/pacman.conf && useradd --create-home winesap && echo "winesap ALL=(root) NOPASSWD:ALL" > /etc/sudoers.d/winesap && chmod 0440 /etc/sudoers.d/winesap
# Clean.
RUN pacman --noconfirm -S -c -c && rm -rf /var/cache/pacman/pkg/*

COPY winesapos-build-repo.sh /usr/local/bin/

VOLUME ["/output"]

# The 'makepkg' command requires building packages as a non-root user.
# Use the 'winesap' user.
USER 1000:1000
CMD /usr/local/bin/winesapos-build-repo.sh
