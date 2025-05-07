#!/bin/bash
# MODULE 2: Postinstall Scripts, see Examples
set -euxo pipefail

# === Config ===
LOGFILE="/var/log/postinstall.log"
UNITY_DB="unityworld"
UNITY_USER="unity"
UNITY_PASS="unitypass"
REDIS_PASS="redispass"
UNITY_DEST="/opt/unityserver"
UNITY_SRC="/root/darksite/opt/unityserver"

# === Logging Setup ===
exec > >(tee -a "$LOGFILE") 2>&1
trap 'echo "[✖] Postinstall failed on line $LINENO"; exit 1' ERR
log() { echo "[INFO] $(date '+%F %T') — $*"; }

log "Starting postinstall setup..."

# === Function Definitions ===

remove_cd_sources() {
  sed -i '/cdrom:/d' /etc/apt/sources.list
}

install_packages() {
  apt update
  apt install -y cloud-init redis-server postgresql nginx varnish ufw tmux openssh-server sudo
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
    mkdir -p /home/"$user"/.ssh
    echo "$ssh_key" > /home/"$user"/.ssh/authorized_keys
    chmod 700 /home/"$user"/.ssh
    chmod 600 /home/"$user"/.ssh/authorized_keys
    chown -R "$user:$user" /home/"$user"/.ssh
    echo "$user ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/"$user"
  fi
}

# === Create Users (SSH and sudo access) ===
create_user "ansible" "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDQxCqOqlNPjv/ZkIkAs8yhhx9EVOEsQUDx80Auhvn8U ansible"

deploy_unity_server() {
  local SRC_BASE="/root/darksite"
  local SRC_DIR="$SRC_BASE/opt/unityserver"
  local DEST_DIR="/opt/unityserver"
  local SERVER_BIN="$DEST_DIR/server.x86_64"

  echo "[INFO] $(date '+%F %T') — Initializing Unity server deployment..."

  # Ensure all necessary directories exist
  echo "[INFO] $(date '+%F %T') — Creating required directories..."
  mkdir -p \
    "$SRC_BASE" \
    "$SRC_BASE/opt" \
    "$SRC_DIR" \
    "$DEST_DIR" \
    /etc/ssh/sshd_config.d \
    /var/log/unityserver \
    /var/lib/unityserver \
    /var/run/unityserver

  # Optional: populate default structure in /root/darksite/opt/unityserver if empty
  if [[ -z "$(ls -A "$SRC_DIR")" ]]; then
    echo "[WARN] $(date '+%F %T') — Source directory $SRC_DIR is empty. Please populate it with Unity server files."
    return 1
  fi

  # Copy Unity server files (including hidden ones)
  echo "[INFO] $(date '+%F %T') — Copying Unity server files from $SRC_DIR to $DEST_DIR..."
  cp -a "$SRC_DIR/." "$DEST_DIR/" || {
    echo "[ERROR] $(date '+%F %T') — Failed to copy Unity server files."
    return 1
  }

  # Ensure the Unity server binary exists
  if [[ ! -f "$SERVER_BIN" ]]; then
    echo "[ERROR] $(date '+%F %T') — Unity server binary not found: $SERVER_BIN"
    return 1
  fi

  # Make the binary executable
  echo "[INFO] $(date '+%F %T') — Making binary executable: $SERVER_BIN"
  chmod +x "$SERVER_BIN" || {
    echo "[ERROR] $(date '+%F %T') — Failed to chmod binary."
    return 1
  }

  echo "[INFO] $(date '+%F %T') — Unity server deployed successfully to $DEST_DIR."
}

setup_postgres() {
  sudo -u postgres psql -tc "SELECT 1 FROM pg_database WHERE datname='$UNITY_DB'" | grep -q 1 || \
    sudo -u postgres psql -c "CREATE DATABASE $UNITY_DB"

  if ! sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='$UNITY_USER'" | grep -q 1; then
    sudo -u postgres psql -c "CREATE USER $UNITY_USER WITH ENCRYPTED PASSWORD '$UNITY_PASS';"
  fi

  sudo -u postgres psql -c "GRANT ALL PRIVILEGES ON DATABASE $UNITY_DB TO $UNITY_USER;"
}

configure_redis() {
  sed -i "s/^# requirepass .*/requirepass $REDIS_PASS/" /etc/redis/redis.conf
  systemctl restart redis
}

tune_varnish() {
  sed -i 's/.port = "6081";/.port = "80";/' /etc/varnish/default.vcl
  sed -i 's|^ExecStart=.*|ExecStart=/usr/sbin/varnishd -a :80 -b localhost:8080|' /lib/systemd/system/varnish.service
  systemctl daemon-reexec
  systemctl restart varnish
}

setup_ufw() {
  ufw allow 22/tcp
  ufw allow 80/tcp
  ufw allow 6081/tcp
  ufw allow 7777/tcp
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

prepare_logs() {
  log "Creating tmpfiles.d entries for default logs..."
  cat > /etc/tmpfiles.d/services.conf <<EOF
d /var/log/nginx 0755 www-data www-data -
f /var/log/nginx/access.log 0640 www-data www-data -
f /var/log/nginx/error.log 0640 www-data www-data -
d /var/log/redis 0755 redis redis -
f /var/log/redis/redis-server.log 0640 redis redis -
d /var/log/postgresql 0755 postgres postgres -
f /var/log/postgresql/postgresql.log 0640 postgres postgres -
d /var/log/varnish 0755 varnishlog adm -
f /var/log/varnish/varnishncsa.log 0640 varnishlog adm -
EOF

  systemd-tmpfiles --create
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
harden_ssh
deploy_unity_server
setup_postgres
configure_redis
tune_varnish
setup_ufw
reset_cloud_init
regenerate_identity
prepare_logs
cleanup_logs
self_destruct

log "[✔] Postinstall complete — rebooting..."
#reboot
poweroff
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

[Install]
WantedBy=multi-user.target
EOF

chmod +x "$DARKSITE_DIR/postinstall.sh"

VMID="${1:-}"
PROXMOX_HOST="10.255.0.2"

if [[ -z "$VMID" ]]; then
  echo "[✗] Usage: $0 <VMID>"
  exit 1
fi

echo "[*] Waiting for VM $VMID to shut down after cloud-init..."

SECONDS=0
TIMEOUT=900

while ssh root@"$PROXMOX_HOST" "qm status $VMID" | grep -q running; do
  if (( SECONDS > TIMEOUT )); then
    echo "[✗] Timeout waiting for VM shutdown."
    exit 1
  fi
  sleep 30
done

echo "[*] VM $VMID has shut down after cloud-init. Marking as template..."
ssh root@"$PROXMOX_HOST" "qm template $VMID"
echo "[✓] Template finalized."
EOSCRIPT

chmod +x "$DARKSITE_DIR/finalize-template.sh"
