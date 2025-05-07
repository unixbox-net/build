#!/bin/bash
# MODULE 4: GUI Installer
set -euo pipefail
source "/root/base/lib/env.sh"

log "[*] [Module 4] Writing preseed.cfg to install LogHOG (lh) at base install..."

cat > "$CUSTOM_DIR/preseed.cfg" <<EOF
# Localization
d-i debian-installer/locale string en_US.UTF-8
d-i console-setup/ask_detect boolean false
d-i keyboard-configuration/xkb-keymap select us

# Networking
d-i netcfg/choose_interface select auto
d-i netcfg/get_hostname string debian
d-i netcfg/get_domain string lan.xaeon.io

# Mirrors
d-i mirror/country string manual
d-i mirror/http/hostname string deb.debian.org
d-i mirror/http/directory string /debian
d-i mirror/http/proxy string

# APT sections
d-i apt-setup/use_mirror boolean true
d-i apt-setup/non-free boolean true
d-i apt-setup/contrib boolean true

# Include darksite APT repo
d-i apt-setup/local0/repository string file:///cdrom/darksite/aptrepo
d-i apt-setup/local0/comment string LogHOG Repo
d-i apt-setup/local0/source boolean false

# User setup
d-i passwd/root-login boolean false
d-i passwd/make-user boolean true
d-i passwd/username string debian
d-i passwd/user-fullname string Debian User
d-i passwd/user-password password debian
d-i passwd/user-password-again password debian

# Timezone
d-i time/zone string America/Toronto
d-i clock-setup/utc boolean true
d-i clock-setup/ntp boolean true

# Partitioning (automated with LVM)
d-i partman-auto/method string lvm
d-i partman-lvm/device_remove_lvm boolean true
d-i partman-auto/choose_recipe select atomic
d-i partman/confirm boolean true
d-i partman/confirm_nooverwrite boolean true
d-i partman/confirm_write_new_label boolean true
d-i partman/choose_partition select finish
d-i partman-lvm/confirm boolean true
d-i partman-lvm/confirm_nooverwrite boolean true
d-i partman-lvm/confirm_write_new_label boolean true
d-i partman-auto-lvm/guided_size string max

# Task selection
tasksel tasksel/first multiselect standard, ssh-server

# Popularity
popularity-contest popularity-contest/participate boolean false

# GRUB
d-i grub-installer/bootdev string /dev/sda
d-i grub-installer/only_debian boolean true

# Base packages to install
d-i pkgsel/include string lh

# Post-installation: setup darksite scripts
d-i preseed/late_command string \
  cp -a /cdrom/darksite /target/root/ ; \
  in-target chmod +x /root/darksite/postinstall.sh ; \
  in-target cp /root/darksite/bootstrap.service /etc/systemd/system/ ; \
  in-target systemctl daemon-reexec ; \
  in-target systemctl enable bootstrap.service ;

# Ensure automatic final step
d-i finish-install/keep-consoles boolean false
d-i finish-install/exit-installer boolean true
d-i finish-install/reboot_in_progress note
d-i debian-installer/exit/reboot boolean true
d-i cdrom-detect/eject boolean true

# Make installer shut down after install
d-i debian-installer/exit/poweroff boolean true
EOF
