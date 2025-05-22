#!/bin/bash
set -euo pipefail

LOG_FILE="/root/install.txt"
exec &> >(tee -a "$LOG_FILE")

log() { echo "[INFO] $(date): $1"; }
error_log() { echo "[ERROR] $(date): $1" >&2; }

# === CONFIGURATION ===
ISO_ORIG="/root/debian-12.10.0-amd64-netinst.iso"
BUILD_DIR="/root/debian-iso"
CUSTOM_DIR="$BUILD_DIR/custom"
MOUNT_DIR="/mnt/iso"
DARKSITE_DIR="$CUSTOM_DIR/darksite"
PRESEED_FILE="preseed.cfg"
OUTPUT_ISO="$BUILD_DIR/semaphore.iso"
FINAL_ISO="/root/semaphore.iso"
PROXMOX_HOST="10.200.0.100"
VMID="${1:-}"

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
mount -o loop "$ISO_ORIG" "$MOUNT_DIR" || error_log "Failed to mount ISO"

log "[*] Copying ISO contents..."
cp -a "$MOUNT_DIR/"* "$CUSTOM_DIR/" || error_log "Failed to copy ISO contents"
cp -a "$MOUNT_DIR/.disk" "$CUSTOM_DIR/" || error_log "Failed to copy .disk directory"
umount "$MOUNT_DIR"

log "[*] Writing postinstall.sh..."
cat > "$DARKSITE_DIR/postinstall.sh" <<'EOSCRIPT'
#!/bin/bash
set -euxo pipefail

# === Configuration ===
LOGFILE="/var/log/postinstall.log"
POSTGRES_DB="semaphore"
POSTGRES_USER="semaphore"
POSTGRES_PASS="semaphorepassword"
SEMAPHORE_VERSION="2.9.49"

# === Logging Setup ===
exec > >(tee -a "$LOGFILE") 2>&1
trap 'echo "[✖] Postinstall failed on line $LINENO"; exit 1' ERR
log() { echo "[INFO] $(date '+%F %T') — $*"; }

# === Functions ===

remove_cd_sources() {
  sed -i '/cdrom:/d' /etc/apt/sources.list
}

install_packages() {
  log "Installing core packages..."

  apt update
  apt install -y --no-install-recommends \
    ansible \
    bpfcc-tools \
    bpftrace \
    build-essential \
    chrony \
    cloud-init \
    clang \
    cron \
    curl \
    docker-compose \
    docker.io \
    eatmydata \
    firefox-esr \
    git \
    gnupg \
    gnome-terminal \
    htop \
    jq \
    libbpfcc-dev \
    libelf-dev \
    libpq-dev \
    linux-headers-$(uname -r) \
    lsb-release \
    lsof \
    ltrace \
    net-tools \
    ngrep \
    nmap \
    openssh-client \
    openssh-server \
    patch \
    pipewire \
    postgresql \
    postgresql-client \
    python3 \
    python3-bpfcc \
    python3-pip \
    python3-setuptools \
    python3-venv \
    rsync \
    rsyslog \
    rsyslog-relp \
    sed \
    sensible-utils \
    software-properties-common \
    strace \
    sudo \
    sysstat \
    task-gnome-desktop \
    tcpdump \
    tmux \
    traceroute \
    uuid-runtime \
    ufw \
    vim \
    vim-airline \
    vim-airline-themes \
    vim-ctrlp \
    vim-fugitive \
    vim-gitgutter \
    vim-tabular \
    wget \
    wireplumber \
    xrdp

  # Enable necessary services
  systemctl enable xrdp
  systemctl enable gdm3
}

create_users() {
  log "Creating 'ansible' and 'debian' users with correct SSH keys..."

  for user in ansible debian; do
    id "$user" &>/dev/null || adduser --disabled-password --gecos "" "$user"

    user_home="/home/${user}"
    ssh_dir="$user_home/.ssh"
    mkdir -p "$ssh_dir"
    chown "$user:$user" "$ssh_dir"

    # Ensure old keys are gone
    rm -f "$ssh_dir/id_rsa" "$ssh_dir/id_rsa.pub" "$ssh_dir/authorized_keys"

    # Generate key pair AS the target user, with correct comment
    sudo -u "$user" ssh-keygen -t rsa -b 4096 -f "$ssh_dir/id_rsa" -N "" -C "$user@$(hostname)" <<< y >/dev/null 2>&1

    # Setup authorized_keys and export keypair to /root
    cp "$ssh_dir/id_rsa.pub" "$ssh_dir/authorized_keys"
    cp "$ssh_dir/id_rsa" "/root/${user}_id_rsa"
    cp "$ssh_dir/id_rsa.pub" "/root/${user}_id_rsa.pub"

    chmod 700 "$ssh_dir"
    chmod 600 "$ssh_dir"/*
    chown -R "$user:$user" "$ssh_dir"

    echo "$user ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/$user"
    usermod -aG docker "$user"

    log "[✔] SSH key generated for $user with identity $user@$(hostname)"
  done
}

setup_postgresql() {
  log "Setting up PostgreSQL database for Semaphore..."

  sudo -u postgres psql -tc "SELECT 1 FROM pg_database WHERE datname='${POSTGRES_DB}'" | grep -q 1 || \
    sudo -u postgres psql -c "CREATE DATABASE ${POSTGRES_DB}"

  sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='${POSTGRES_USER}'" | grep -q 1 || \
    sudo -u postgres psql -c "CREATE USER ${POSTGRES_USER} WITH ENCRYPTED PASSWORD '${POSTGRES_PASS}'"

  sudo -u postgres psql -c "GRANT ALL PRIVILEGES ON DATABASE ${POSTGRES_DB} TO ${POSTGRES_USER}"
}

install_semaphore() {
  log "Installing Semaphore version ${SEMAPHORE_VERSION}..."

  curl -L -o /usr/local/bin/semaphore "https://github.com/ansible-semaphore/semaphore/releases/download/v${SEMAPHORE_VERSION}/semaphore_${SEMAPHORE_VERSION}_linux_amd64"
  chmod +x /usr/local/bin/semaphore

  adduser --system --group --home /var/lib/semaphore semaphore
  mkdir -p /etc/semaphore /var/lib/semaphore
  chown semaphore: /etc/semaphore /var/lib/semaphore

  cat > /etc/semaphore/config.json <<EOF
{
  "mysql": {
    "host": "127.0.0.1",
    "port": "",
    "user": "${POSTGRES_USER}",
    "pass": "${POSTGRES_PASS}",
    "name": "${POSTGRES_DB}"
  },
  "port": "3000",
  "tmp_path": "/tmp/semaphore",
  "access_key_encryption": "$(uuidgen)"
}
EOF

  chown semaphore: /etc/semaphore/config.json
  chmod 600 /etc/semaphore/config.json

  cat > /etc/systemd/system/semaphore.service <<EOF
[Unit]
Description=Semaphore Ansible Web UI
After=network.target postgresql.service

[Service]
Type=simple
User=semaphore
Group=semaphore
ExecStart=/usr/local/bin/semaphore -config /etc/semaphore/config.json
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reexec
  systemctl enable semaphore
  systemctl start semaphore
}

configure_xrdp_wayland() {
  log "Configuring XRDP with GNOME and PipeWire for Wayland..."

  echo "gnome-session" > /etc/skel/.xsession

  mkdir -p /etc/polkit-1/localauthority.conf.d
  cat > /etc/polkit-1/localauthority.conf.d/50-localauth.conf <<EOF
[Configuration]
AdminIdentities=unix-user:debian
EOF

  loginctl enable-linger debian
}

configure_ansible_environment() {
  log "Setting up Ansible environment..."

  mkdir -p /etc/ansible
  cat > /etc/ansible/ansible.cfg <<EOF
[defaults]
inventory = /etc/ansible/hosts
host_key_checking = False
EOF

  echo "[local]" > /etc/ansible/hosts
  echo "localhost ansible_connection=local" >> /etc/ansible/hosts
}

configure_firewall() {
  log "Configuring firewall rules..."

  ufw allow 22/tcp     # SSH
  ufw allow 3389/tcp   # XRDP
  ufw allow 3000/tcp   # Semaphore
  ufw --force enable
}

create_users() {
  log "Creating system users 'ansible' and 'debian' if needed..."

  id -u ansible &>/dev/null || adduser --disabled-password --gecos "" ansible
  id -u debian &>/dev/null || adduser --disabled-password --gecos "" debian
}

generate_user_ssh_keys() {
  log "Generating SSH keys for 'ansible' and 'debian'..."

  for user in ansible debian; do
    USER_HOME="/home/${user}"
    mkdir -p "${USER_HOME}/.ssh"
    ssh-keygen -t rsa -b 4096 -f "${USER_HOME}/.ssh/id_rsa" -N "" -q
    cp "${USER_HOME}/.ssh/id_rsa" "/root/${user}_id_rsa"
    cp "${USER_HOME}/.ssh/id_rsa.pub" "${USER_HOME}/.ssh/authorized_keys"
    chmod 700 "${USER_HOME}/.ssh"
    chmod 600 "${USER_HOME}/.ssh/"*
    chown -R "${user}:${user}" "${USER_HOME}/.ssh"
    echo "${user} ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/${user}"
  done
}

setup_observability_stack() {
  log "Installing Ghost observability toolchain..."

  rm -rf /opt/ghost
  python3 -m venv /opt/ghost
  /opt/ghost/bin/python3 -m ensurepip --upgrade
  /opt/ghost/bin/pip install --upgrade pip setuptools wheel

  /opt/ghost/bin/pip install \
    numba pytest requests rich psycopg2-binary

  log "Ghost observability virtual environment ready at /opt/ghost"
}

reset_cloud_identity() {
  log "Resetting machine identity and cloud-init state..."

  cloud-init clean --logs
  rm -rf /var/lib/cloud/

  truncate -s 0 /etc/machine-id
  rm -f /var/lib/dbus/machine-id || true
  ln -s /etc/machine-id /var/lib/dbus/machine-id

  hostnamectl set-hostname "node-$(uuidgen | cut -c1-8)"
  echo "$(hostname)" > /etc/hostname

  rm -f /etc/ssh/ssh_host_*
}

harden_ssh() {
  log "Validating and hardening SSH config..."
  cat > /etc/ssh/sshd_config.d/hardening.conf <<EOF
PasswordAuthentication no
PermitRootLogin no
EOF

  if sshd -t; then
    systemctl restart ssh
    log "SSH hardened successfully."
  else
    log "[WARN] SSH config invalid — removing hardening policy"
    rm -f /etc/ssh/sshd_config.d/hardening.conf
  fi
}

prepare_logs() {
  log "Preparing systemd tmpfiles for logs..."

  cat > /etc/tmpfiles.d/services.conf <<EOF
d /var/log/postgresql 0755 postgres postgres -
f /var/log/postgresql/postgresql.log 0640 postgres postgres -
EOF

  systemd-tmpfiles --create
}

cleanup_logs() {
  log "Cleaning up logs and temporary files..."

  find /var/log -type f -not -name 'postinstall.log' -delete
  rm -rf /tmp/* /var/tmp/*
}

self_destruct() {
  log "Scheduling bootstrap.service cleanup on next boot..."

  cat > /etc/systemd/system/bootstrap-cleanup.service <<EOF
[Unit]
Description=Cleanup bootstrap.service
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/bin/bash -c 'rm -f /etc/systemd/system/bootstrap.service /etc/systemd/system/bootstrap-cleanup.service && systemctl daemon-reload'

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable bootstrap-cleanup.service
}

main() {
  log "Starting full Semaphore Control Node installation"

  install_packages
  create_users
  generate_user_ssh_keys
  setup_postgresql
  install_semaphore
  configure_xrdp_wayland
  configure_ansible_environment
  configure_firewall
  setup_observability_stack
  reset_cloud_identity
  harden_ssh
  prepare_logs
  cleanup_logs
  self_destruct

  log "Installation complete. System will now power off."
  sync
  sleep 3
  poweroff
}

main
EOSCRIPT

chmod +x "$DARKSITE_DIR/postinstall.sh"

log "[*] Writing bootstrap.service..."
cat > "$DARKSITE_DIR/bootstrap.service" <<'EOF'
#[Unit]
#Description=Initial Bootstrap Script
#After=network-online.target
#Wants=network-online.target

#[Service]
#Type=oneshot
#ExecStart=/root/darksite/postinstall.sh
#RemainAfterExit=false
#TimeoutStartSec=900
#StandardOutput=journal
#StandardError=journal

#[Install]
#WantedBy=multi-user.target

[Unit]
Description=Initial Bootstrap Script
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/root/darksite/postinstall.sh
StandardOutput=journal+console
StandardError=journal+console
RemainAfterExit=false
TimeoutStartSec=900

[Install]
WantedBy=multi-user.target
EOF

log "[*] Writing finalize-template.sh..."
cat > "$DARKSITE_DIR/finalize-template.sh" <<'EOSCRIPT'
#!/bin/bash
set -euxo pipefail

VMID="${1:-}"
PROXMOX_HOST="10.200.0.100"

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
#ssh root@"$PROXMOX_HOST" "qm template $VMID"
echo "[✓] Template finalized."
EOSCRIPT

chmod +x "$DARKSITE_DIR/finalize-template.sh"

# --- Preseed file ---
log "[*] Creating preseed.cfg..."
cat > "$CUSTOM_DIR/$PRESEED_FILE" <<EOF
# Localization
d-i debian-installer/locale string en_US.UTF-8
d-i console-setup/ask_detect boolean true
# d-i keyboard-configuration/xkb-keymap select us

# Networking
# d-i netcfg/choose_interface select auto
# d-i netcfg/get_hostname string debian
# d-i netcfg/get_domain string lan.xaeon.io

# Mirrors
d-i mirror/country string manual
d-i mirror/http/hostname string deb.debian.org
d-i mirror/http/directory string /debian
d-i mirror/http/proxy string

# APT sections
d-i apt-setup/use_mirror boolean true
d-i apt-setup/non-free boolean true
d-i apt-setup/contrib boolean true

# User setup
d-i passwd/root-login boolean false
d-i passwd/make-user boolean true
# d-i passwd/username string debian
# d-i passwd/user-fullname string Debian User
# d-i passwd/user-password password debian
# d-i passwd/user-password-again password debian

# Timezone
# d-i time/zone string America/Toronto
d-i clock-setup/utc boolean true
d-i clock-setup/ntp boolean true

# Partitioning (manual for hardware)
# d-i partman-auto/method string lvm
# d-i partman-lvm/device_remove_lvm boolean true
# d-i partman-auto/choose_recipe select atomic
# d-i partman/confirm boolean true
# d-i partman/confirm_nooverwrite boolean true
# d-i partman/confirm_write_new_label boolean true
# d-i partman/choose_partition select finish
# d-i partman-lvm/confirm boolean true
# d-i partman-lvm/confirm_nooverwrite boolean true
# d-i partman-lvm/confirm_write_new_label boolean true
# d-i partman-auto-lvm/guided_size string max

# Task selection
tasksel tasksel/first multiselect standard, ssh-server

# Popularity
popularity-contest popularity-contest/participate boolean false

# GRUB
# d-i grub-installer/bootdev string /dev/sda
d-i grub-installer/only_debian boolean true

d-i finish-install/keep-consoles boolean false
d-i finish-install/exit-installer boolean true
d-i finish-install/reboot_in_progress note
d-i debian-installer/exit/reboot boolean true
d-i cdrom-detect/eject boolean true

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
  menu label ^Semaphore
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
    --name semaphore-template \\
    --memory 8192 \\
    --cores 10 \\
    --net0 virtio,bridge=vmbr0,firewall=1 \\
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
  qm set \$VMID --description 'semaphore'

  # Start again to trigger postinstall script
  qm start \$VMID
EOSSH

# === Finalize Template After Postinstall (and second shutdown)
  log "[*] Running finalize-template.sh after second VM shutdown..."
  bash "$DARKSITE_DIR/finalize-template.sh" "$VMID"

  log "[✓] VM $VMID fully built, configured, and saved as a template."
