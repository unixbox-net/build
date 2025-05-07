#!/bin/bash
set -euo pipefail

LOG_FILE="/home/semaphore/install.txt"
exec &> >(tee -a "$LOG_FILE")

log() { echo "[INFO] $(date): $1"; }
error_log() { echo "[ERROR] $(date): $1" >&2; }

# === CONFIGURATION ===
ISO_ORIG="/home/semaphore/debian-12.10.0-amd64-DVD-1.iso"
BUILD_DIR="/home/semaphore/debian-iso"
CUSTOM_DIR="$BUILD_DIR/custom"
MOUNT_DIR="/mnt/iso"
DARKSITE_DIR="$CUSTOM_DIR/darksite"
PRESEED_FILE="preseed.cfg"
OUTPUT_ISO="$BUILD_DIR/netbird.iso"
FINAL_ISO="/home/semaphore/netbird.iso"
PROXMOX_HOST="10.255.0.2"
#VMID="${1:-}"
VMID="${1:-1002}"

if [ -z "$VMID" ]; then
  error_log "Usage: $0 <VMID>"
  exit 1
fi

log "[*] Using VMID $VMID"

log "[*] Cleaning up..."
umount "$MOUNT_DIR" 2>/dev/null || true
rm -rf "$BUILD_DIR"
mkdir -p "$CUSTOM_DIR" "$MOUNT_DIR" "$DARKSITE_DIR"

log "[*] Mounting ISO..."
mount -o loop "$ISO_ORIG" "$MOUNT_DIR"

log "[*] Copying ISO contents..."
cp -a "$MOUNT_DIR/"* "$CUSTOM_DIR/"
cp -a "$MOUNT_DIR/.disk" "$CUSTOM_DIR/"
umount "$MOUNT_DIR"

log "[*] Writing postinstall.sh..."
cat > "$DARKSITE_DIR/postinstall.sh" <<'EOSCRIPT'
#!/bin/bash
set -euxo pipefail

# === Logging Setup ===
LOGFILE="${LOGFILE:-/var/log/postinstall.log}"  # Ensure LOGFILE is set
exec > >(tee -a "$LOGFILE") 2>&1
trap 'echo "[✖] Postinstall failed on line $LINENO"; exit 1' ERR
log() { echo "[INFO] $(date '+%F %T') — $*"; }

log "Starting postinstall setup..."
# === Function Definitions ===

remove_cd_sources() {
  sed -i '/cdrom:/d' /etc/apt/sources.list
}

install_packages() {
  # Update apt repository and install essential packages
  apt update
  apt install -y --no-install-recommends cloud-init openssh-server sudo \
    gnome-session gnome-terminal gdm3 gnome-settings-daemon gnome-control-center firefox-esr nautilus \
    xwayland ufw vim dbus-user-session \
    gtk2-engines-murrine gtk2-engines-pixbuf gnome-tweaks

  # Enable GDM (GNOME Display Manager) but don't start it yet
  systemctl mask polkit.service || true
  systemctl enable gdm3

  log "[✔] GNOME Desktop environment installed and GDM enabled."
}

harden_ssh() {
  mkdir -p /etc/ssh/sshd_config.d/
  cat > /etc/ssh/sshd_config.d/hardening.conf <<EOF
PasswordAuthentication no
PermitRootLogin no
EOF
  systemctl restart ssh
}

create_user() {
  local user=$1
  local ssh_key=$2

  if ! id "$user" &>/dev/null; then
    adduser --disabled-password --gecos "" "$user"
    echo "$user ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/"$user"
  fi

  mkdir -p /home/"$user"/.ssh
  echo "$ssh_key" > /home/"$user"/.ssh/authorized_keys
  chmod 700 /home/"$user"/.ssh
  chmod 600 /home/"$user"/.ssh/authorized_keys
  chown -R "$user:$user" /home/"$user"/.ssh
}

create_users() {
  create_user "debian"  "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOULOqaBuNbkIro5ichg58TELDGD0f9H8AkPh9xph+VR debian@semaphore-BHS-VMH-2"
}


setup_ufw() {
  ufw allow 22/tcp
  ufw --force enable
}

reset_cloud_init() {
  cloud-init clean --logs
  rm -rf /var/lib/cloud/
  rm -f /etc/cloud/cloud.cfg.d/subiquity-disable-cloudinit.conf
}

regenerate_identity() {
  truncate -s 0 /etc/machine-id
  rm -f /var/lib/dbus/machine-id || true
  ln -s /etc/machine-id /var/lib/dbus/machine-id
  hostnamectl set-hostname "node-$(uuidgen | cut -c1-8)"
  echo "$(hostname)" > /etc/hostname
  rm -f /etc/ssh/ssh_host_*
}

cleanup_logs() {
  find /var/log -type f -not -name 'postinstall.log' -delete
  rm -rf /tmp/* /var/tmp/*
}

self_destruct() {
  log "Disabling and removing bootstrap.service..."
  systemctl disable bootstrap.service || true
  rm -f /etc/systemd/system/bootstrap.service
  systemctl daemon-reload
}

# === Execution Flow ===

remove_cd_sources
install_packages
create_users
harden_ssh
setup_ufw
reset_cloud_init
regenerate_identity
cleanup_logs
self_destruct

log "[✔] Postinstall complete — rebooting..."
#reboot
#poweroff
shutdown -h now
EOSCRIPT

chmod +x "$DARKSITE_DIR/postinstall.sh"

log "[*] Writing bootstrap.service..."
cat > "$DARKSITE_DIR/bootstrap.service" <<'EOF'
[Unit]
Description=Initial Bootstrap Script
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/root/darksite/postinstall.sh
RemainAfterExit=false
TimeoutStartSec=900
StandardOutput=journal
StandardError=journal
KillMode=process

[Install]
WantedBy=multi-user.target
EOF

log "[*] Writing finalize-template.sh..."
cat > "$DARKSITE_DIR/finalize-template.sh" <<'EOSCRIPT'
#!/bin/bash
set -euxo pipefail

VMID="${1:-}"
PROXMOX_HOST="10.255.0.2"

if [ -z "$VMID" ]; then
  echo "Usage: $0 <VMID>"
  exit 1
fi

echo "[*] Waiting for VM $VMID to shut down after cloud-init..."

SECONDS=0
TIMEOUT=900  # 15 minutes

while ssh root@"$PROXMOX_HOST" "qm status $VMID" | grep -q running; do
  if (( SECONDS > TIMEOUT )); then
    echo "[!] ERROR: Timeout waiting for VM $VMID to shut down."
    exit 1
  fi
  sleep 30
done

echo "[*] VM $VMID has shut down after cloud-init. Marking as template..."
ssh root@"$PROXMOX_HOST" "qm template $VMID"
echo "[✓] Template finalized."
EOSCRIPT

chmod +x "$DARKSITE_DIR/finalize-template.sh"

# --- Preseed file ---
log "[*] Creating preseed.cfg..."
cat > "$CUSTOM_DIR/$PRESEED_FILE" <<EOF
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

# Comment this out to enable mirrors on NetInst
#d-i mirror/no_mirror boolean true

# APT sections
d-i apt-setup/use_mirror boolean true
d-i apt-setup/non-free boolean true
d-i apt-setup/contrib boolean true

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
tasksel tasksel/first multiselect

# Popularity
popularity-contest popularity-contest/participate boolean false

# GRUB
d-i grub-installer/bootdev string /dev/sda
d-i grub-installer/only_debian boolean true

d-i finish-install/keep-consoles boolean false
d-i finish-install/exit-installer boolean true
d-i finish-install/reboot_in_progress note
d-i debian-installer/exit/reboot boolean true
d-i cdrom-detect/eject boolean true

tasksel tasksel/first multiselect standard, ssh-server
d-i finish-install/reboot_in_progress note

d-i preseed/late_command string \
  cp -a /cdrom/darksite /target/root/ ; \
  in-target chmod +x /root/darksite/postinstall.sh ; \
  in-target cp /root/darksite/bootstrap.service /etc/systemd/system/bootstrap.service ; \
  in-target systemctl daemon-reexec ; \
  in-target systemctl enable bootstrap.service ;

# Make installer shut down after install
d-i debian-installer/exit/poweroff boolean true

EOF
# --- Update isolinux ---
log "[*] Updating isolinux config..."
TXT_CFG="$CUSTOM_DIR/isolinux/txt.cfg"
ISOLINUX_CFG="$CUSTOM_DIR/isolinux/isolinux.cfg"

cat >> "$TXT_CFG" <<EOF
label auto
  menu label ^Netbird Installer
  kernel /install.amd/vmlinuz
  append auto=true priority=critical vga=788 initrd=/install.amd/initrd.gz preseed/file=/cdrom/$PRESEED_FILE ---
EOF

sed -i 's/^default .*/default auto/' "$ISOLINUX_CFG"

# --- Rebuild ISO ---
log "[*] Rebuilding ISO..."
xorriso -as mkisofs \
  -o "$OUTPUT_ISO" \
  -r -J -joliet-long -l \
  -b isolinux/isolinux.bin \
  -c isolinux/boot.cat \
  -no-emul-boot -boot-load-size 4 -boot-info-table \
  -isohybrid-mbr /usr/lib/ISOLINUX/isohdpfx.bin \
  -eltorito-alt-boot \
  -e boot/grub/efi.img \
  -no-emul-boot -isohybrid-gpt-basdat \
  "$CUSTOM_DIR"

mv "$OUTPUT_ISO" "$FINAL_ISO"

log "[*] ISO ready at $FINAL_ISO — done!"
# === UPLOAD TO PROXMOX ===
log "[*] Uploading ISO to Proxmox host $PROXMOX_HOST..."
scp "$FINAL_ISO" root@"$PROXMOX_HOST":/var/lib/vz/template/iso/

log "[*] Creating and running VM $VMID on Proxmox host $PROXMOX_HOST..."

FINAL_ISO_BASENAME=$(basename "$FINAL_ISO")

log "[*] Creating and running VM $VMID on Proxmox host $PROXMOX_HOST..."
ssh root@"$PROXMOX_HOST" bash <<EOSSH
  set -euxo pipefail

  VMID=$VMID
  FINAL_ISO="$FINAL_ISO_BASENAME"

  # Clean previous VM if exists
  qm destroy \$VMID --purge || true

  # Create base VM with ISO boot
  qm create \$VMID \\
    --name netbird \\
    --memory 4096 \\
    --cores 6 \\
    --net0 virtio,bridge=vmbr1,firewall=1 \\
    --ide2 local:iso/\$FINAL_ISO,media=cdrom \\
    --efidisk0 local-zfs:0,efitype=4m,pre-enrolled-keys=0 \\
    --scsihw virtio-scsi-single \\
    --scsi0 local-zfs:32 \\
    --boot order=ide2 \\
    --serial0 socket \\
    --ostype l26 \\
    --agent enabled=1

  # Start VM to run the ISO installer
  qm start \$VMID

  SECONDS=0
  TIMEOUT=900  # 15 minutes

  # Wait for the installer to finish and poweroff
  while qm status \$VMID | grep -q running; do
    if (( SECONDS > TIMEOUT )); then
      echo "[!] ERROR: Timeout waiting for VM \$VMID shutdown after \$TIMEOUT seconds."
      exit 1
    fi
    sleep 30
  done

  echo "[*] VM \$VMID has powered off after \${SECONDS}s."
  echo "[*] Detaching ISO and preparing for cloud-init..."

  # Remove CD-ROM
  qm set \$VMID --delete ide2

  # Set boot order to disk
  qm set \$VMID --boot order=scsi0

  # Attach Cloud-Init drive
  qm set \$VMID --ide3 local-zfs:cloudinit

  # Set description
  qm set \$VMID --description 'netbird'

  # Start again to trigger postinstall script
  qm start \$VMID
EOSSH

# === Finalize Template After Postinstall (and second shutdown)
  log "[*] Running finalize-template.sh after second VM shutdown..."
  bash "$DARKSITE_DIR/finalize-template.sh" "$VMID"

  log "[✓] VM $VMID fully built, configured, and saved as a template."

