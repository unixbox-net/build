#!/usr/bin/env bash
set -euo pipefail

LOG_FILE="/root/install.txt"
exec &> >(tee -a "$LOG_FILE")

log()       { echo "[INFO] $(date '+%F %T') - $*"; }
error_log() { echo "[ERROR] $(date '+%F %T') - $*" >&2; }

# =============================================================================
#                                CONFIG
# =============================================================================

# ---- ISO source --------------------------------------------------------------
#ISO_ORIG="/root/debian-12.10.0-amd64-netinst.iso"
ISO_ORIG="/root/debian-13.0.0-amd64-DVD-1.iso"

# ---- Build workspace ---------------------------------------------------------
BUILD_DIR="/root/build"
CUSTOM_DIR="$BUILD_DIR/custom"
MOUNT_DIR="/mnt/build"
DARKSITE_DIR="$CUSTOM_DIR/darksite"
PRESEED_FILE="preseed.cfg"
OUTPUT_ISO="$BUILD_DIR/base.iso"
FINAL_ISO="/root/clone.iso"

# ---- Cluster target ----------------------------------------------------------
INPUT="${INPUT:-1}"           # 1|fiend, 2|dragon, 3|lion
VMID="${VMID:-1002}"
VMNAME="${VMNAME:-test}"      # base short name (no domain; will add domain below)

# ---- Domain (used everywhere) -----------------------------------------------
DOMAIN="${DOMAIN:-unixbox.net}"

# ---- Storage choices ---------------------------------------------------------
#VM_STORAGE="local-zfs"       # ZFS on the node
#VM_STORAGE="fireball"        # ZFS on Fiend
VM_STORAGE="void"             # Ceph RBD storage ID mapping to Ceph pool
#VM_STORAGE="ceph-cpeh"       # Example of a second Ceph storage

# Where ISOs live (must be a dir storage, not RBD)
ISO_STORAGE="${ISO_STORAGE:-local}"

# Disk size (GiB)
DISK_SIZE_GB="${DISK_SIZE_GB:-32}"

# CPU/RAM for the base VM
MEMORY_MB="${MEMORY_MB:-4096}"
CORES="${CORES:-4}"

# ---- Installer networking ----------------------------------------------------
# static | dhcp
NETWORK_MODE="${NETWORK_MODE:-static}"
STATIC_IP="${STATIC_IP:-10.100.10.111}"
NETMASK="${NETMASK:-255.255.255.0}"
GATEWAY="${GATEWAY:-10.100.10.1}"
NAMESERVER="${NAMESERVER:-10.100.10.2 10.100.10.3 1.1.1.1 8.8.8.8}"

# ---- Cloud-Init toggle -------------------------------------------------------
# Set default to true so clones get unique hostname/IP out of the box.
USE_CLOUD_INIT="${USE_CLOUD_INIT:-true}"
CLONE_VLAN_ID="${CLONE_VLAN_ID:-}"   # optional VLAN tag for clones

# ---- Clone fanout ------------------------------------------------------------
NUM_CLONES="${NUM_CLONES:-3}"
BASE_CLONE_VMID="${BASE_CLONE_VMID:-3000}"
BASE_CLONE_IP="${BASE_CLONE_IP:-$STATIC_IP}"
CLONE_MEMORY_MB="${CLONE_MEMORY_MB:-4096}"
CLONE_CORES="${CLONE_CORES:-4}"

# ---- Extra disks for clones --------------------------------------------------
EXTRA_DISK_COUNT="${EXTRA_DISK_COUNT:-2}"            # how many extra disks per clone
EXTRA_DISK_SIZE_GB="${EXTRA_DISK_SIZE_GB:-100}"      # GiB each
EXTRA_DISK_TARGET="${EXTRA_DISK_TARGET:-fireball}"   # storage for the extra disks

# ---- Install Profile ---------------------------------------------------------
# server | gnome-min | gnome-full | xfce-min | kde-min
INSTALL_PROFILE="${INSTALL_PROFILE:-server}"

# ---- Optional extra scripts packed into ISO ---------------------------------
SCRIPTS_DIR="${SCRIPTS_DIR:-/root/custom-scripts}"

# =============================================================================
#                        Compute/Validate basics
# =============================================================================

VMNAME_CLEAN="${VMNAME//[_\.]/-}"
VMNAME_CLEAN="$(echo "$VMNAME_CLEAN" | sed 's/^-*//;s/-*$//;s/--*/-/g' | tr '[:upper:]' '[:lower:]')"
if [[ ! "$VMNAME_CLEAN" =~ ^[a-z0-9-]+$ ]]; then
  error_log "Invalid VM name after cleanup: '$VMNAME_CLEAN' (letters, digits, dashes only)."
  exit 1
fi
VMNAME="$VMNAME_CLEAN"

case "$INPUT" in
  1|fiend)  HOST_NAME="fiend.${DOMAIN}";  PROXMOX_HOST="10.100.10.225" ;;
  2|dragon) HOST_NAME="dragon.${DOMAIN}"; PROXMOX_HOST="10.100.10.226" ;;
  3|lion)   HOST_NAME="lion.${DOMAIN}";   PROXMOX_HOST="10.100.10.227" ;;
  *) error_log "Unknown host: $INPUT"; exit 1 ;;
esac

BASE_FQDN="${VMNAME}.${DOMAIN}"
BASE_VMNAME="${BASE_FQDN}-template"   # actual Proxmox VM name for the base/template VM

log "Target: $HOST_NAME ($PROXMOX_HOST)  VMID=$VMID  VMNAME=$BASE_VMNAME"
log "Storages: VM_STORAGE=$VM_STORAGE  ISO_STORAGE=$ISO_STORAGE  Disk=${DISK_SIZE_GB}G"
log "Network: $NETWORK_MODE  DOMAIN=$DOMAIN  Cloud-Init: $USE_CLOUD_INIT  Profile: $INSTALL_PROFILE"

# =============================================================================
#                              Build ISO payload
# =============================================================================

log "Cleaning build dir..."
umount "$MOUNT_DIR" 2>/dev/null || true
rm -rf "$BUILD_DIR"
mkdir -p "$CUSTOM_DIR" "$MOUNT_DIR" "$DARKSITE_DIR"

log "Mount ISO..."
mount -o loop "$ISO_ORIG" "$MOUNT_DIR"

log "Copy ISO contents..."
cp -a "$MOUNT_DIR/"* "$CUSTOM_DIR/"
cp -a "$MOUNT_DIR/.disk" "$CUSTOM_DIR/"
umount "$MOUNT_DIR"

log "Stage custom scripts..."
mkdir -p "$DARKSITE_DIR/scripts"
if [[ -d "$SCRIPTS_DIR" ]] && compgen -G "$SCRIPTS_DIR/*" >/dev/null; then
  rsync -a "$SCRIPTS_DIR"/ "$DARKSITE_DIR/scripts"/
  log "Added scripts from $SCRIPTS_DIR"
else
  log "No scripts at $SCRIPTS_DIR; skipping."
fi

# -----------------------------------------------------------------------------
# postinstall.sh (runs inside the installed VM on first boot)
# -----------------------------------------------------------------------------
log "Writing postinstall.sh..."
cat > "$DARKSITE_DIR/postinstall.sh" <<'EOSCRIPT'
#!/usr/bin/env bash
set -euo pipefail
LOG="/var/log/postinstall.log"
exec > >(tee -a "$LOG") 2>&1
trap 'echo "[X] Failed at line $LINENO" >&2' ERR
log(){ echo "[INFO] $(date '+%F %T') - $*"; }

# Load runtime vars persisted by preseed
if [ -f /etc/environment.d/99-provision.conf ]; then
  . /etc/environment.d/99-provision.conf
fi

: "${DOMAIN:?}"
: "${USE_CLOUD_INIT:=true}"
INSTALL_PROFILE="${INSTALL_PROFILE:-server}"

# === Users & SSH keys =========================================================
USERS=(
  "todd:ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHV51Eelt8PwYreHhJJ4JJP3OMwrXswUShblYY10J+A/ todd@onyx"
)

# Build AllowUsers from USERS array
ALLOW_USERS=""
for e in "${USERS[@]}"; do u="${e%%:*}"; ALLOW_USERS+="$u "; done
ALLOW_USERS="${ALLOW_USERS%% }"

# -----------------------------------------------------------------------------
update_and_upgrade() {
  log "APT sources -> trixie"
  cat >/etc/apt/sources.list <<'EOF'
deb http://deb.debian.org/debian trixie main contrib non-free non-free-firmware
deb http://security.debian.org/debian-security trixie-security main contrib non-free non-free-firmware
deb http://deb.debian.org/debian trixie-updates main contrib non-free non-free-firmware
EOF
  export DEBIAN_FRONTEND=noninteractive
  apt update
  apt -y upgrade
}

install_base_packages() {
  log "Installing base packages..."
  apt install -y --no-install-recommends \
    curl wget ca-certificates gnupg lsb-release unzip \
    net-tools traceroute tcpdump sysstat strace lsof ltrace \
    rsync rsyslog cron chrony sudo git ethtool jq \
    qemu-guest-agent openssh-server \
    ngrep nmap \
    bpfcc-tools bpftrace libbpf-dev python3-bpfcc python3 python3-pip \
    uuid-runtime tmux htop python3.13-venv \
    linux-image-amd64 linux-headers-amd64
}

maybe_install_desktop() {
  case "$INSTALL_PROFILE" in
    gnome-min)
      log "Installing minimal GNOME (Wayland by default via gdm3)..."
      apt install -y --no-install-recommends gnome-core gdm3 gnome-terminal network-manager
      systemctl enable gdm3 || true
      ;;
    gnome-full)
      log "Installing full GNOME (task-gnome-desktop; Wayland default)..."
      apt install -y task-gnome-desktop
      ;;
    xfce-min)
      log "Installing minimal XFCE (X11)..."
      apt install -y --no-install-recommends xfce4 xfce4-terminal lightdm xorg network-manager
      systemctl enable lightdm || true
      ;;
    kde-min)
      log "Installing minimal KDE Plasma (Wayland session)..."
      apt install -y --no-install-recommends plasma-desktop sddm plasma-workspace-wayland kwin-wayland konsole network-manager
      systemctl enable sddm || true
      ;;
    server) log "Server profile selected - skipping desktop." ;;
    *) log "Unknown INSTALL_PROFILE='$INSTALL_PROFILE' - skipping desktop." ;;
  esac
}

enforce_wayland_defaults() {
  # GNOME / gdm3
  if systemctl list-unit-files | grep -q '^gdm3\.service'; then
    mkdir -p /etc/gdm3
    if [ -f /etc/gdm3/daemon.conf ]; then
      if grep -q '^[# ]*WaylandEnable=' /etc/gdm3/daemon.conf; then
        sed -i 's/^[# ]*WaylandEnable=.*/WaylandEnable=true/' /etc/gdm3/daemon.conf
      else
        printf '\n[daemon]\nWaylandEnable=true\n' >> /etc/gdm3/daemon.conf
      fi
    else
      cat > /etc/gdm3/daemon.conf <<'EOF'
[daemon]
WaylandEnable=true
EOF
    fi
  fi

  # KDE / sddm
  if systemctl list-unit-files | grep -q '^sddm\.service'; then
    mkdir -p /etc/sddm.conf.d
    cat > /etc/sddm.conf.d/10-wayland.conf <<'EOF'
[General]
Session=plasmawayland.desktop

[Wayland]
EnableHiDPI=true
EOF
  fi
}

maybe_install_cloud_init() {
  if [[ "$USE_CLOUD_INIT" == "true" ]]; then
    log "Installing cloud-init..."
    apt install -y cloud-init cloud-guest-utils
    systemctl enable cloud-init cloud-init-local cloud-config cloud-final || true
  else
    log "Cloud-Init disabled by toggle."
  fi
}

disable_ipv6() {
  log "Disabling IPv6..."
  cat >/etc/sysctl.d/99-disable-ipv6.conf <<'EOF'
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
EOF
  sysctl -p /etc/sysctl.d/99-disable-ipv6.conf || true
}

write_bashrc() {
  log "Writing /etc/skel/.bashrc"
  cat >/etc/skel/.bashrc <<'EOF'
# ~/.bashrc
[ -z "$PS1" ] && return
PS1='\[\e[0;32m\]\u@\h\[\e[m\]:\[\e[0;34m\]\w\[\e[m\]\$ '
HISTSIZE=10000; HISTFILESIZE=20000; HISTTIMEFORMAT='%F %T '; HISTCONTROL=ignoredups:erasedups
shopt -s histappend checkwinsize cdspell
alias grep='grep --color=auto'
alias ll='ls -alF'; alias la='ls -A'; alias l='ls -CF'
alias ports='ss -tuln'; alias df='df -h'; alias du='du -h'
if [ -f /etc/bash_completion ]; then . /etc/bash_completion; fi
VENV_DIR="/root/bccenv"; [ -d "$VENV_DIR" ] && [ -n "$PS1" ] && . "$VENV_DIR/bin/activate"
echo "$USER! Connected to: $(hostname) on $(date)"
EOF
  for u in root ansible debian; do
    h=$(eval echo "~$u") || true
    [ -d "$h" ] || continue
    cp /etc/skel/.bashrc "$h/.bashrc"; chown "$u:$u" "$h/.bashrc" || true
  done
}

configure_ufw_firewall() {
  log "Configuring UFW..."
  apt-get install -y ufw
  sed -i 's/^IPV6=.*/IPV6=no/' /etc/default/ufw
  ufw default deny incoming
  ufw default allow outgoing
  ufw allow 22/tcp
  ufw --force enable
}

write_tmux_conf() {
  log "Writing tmux config..."
  cat >/etc/skel/.tmux.conf <<'EOF'
set -g mouse on
setw -g mode-keys vi
set -g history-limit 10000
set -g default-terminal "screen-256color"
bind | split-window -h
bind - split-window -v
unbind '"'; unbind %
bind r source-file ~/.tmux.conf \; display-message "Reloaded!"
EOF
  cp /etc/skel/.tmux.conf /root/.tmux.conf
}

install_custom_scripts() {
  log "Installing custom scripts (if any)..."
  if [[ -d /root/darksite/scripts ]] && compgen -G "/root/darksite/scripts/*" >/dev/null; then
    cp -a /root/darksite/scripts/* /usr/local/bin/
    chmod +x /usr/local/bin/* || true
  fi
}

setup_vim_config() {
  log "Vim + airline..."
  apt-get install -y vim vim-airline vim-airline-themes vim-ctrlp vim-fugitive vim-gitgutter vim-tabular
  mkdir -p /etc/skel/.vim/autoload/airline/themes
  cat >/etc/skel/.vimrc <<'EOF'
syntax on
filetype plugin indent on
set number relativenumber tabstop=2 shiftwidth=2 expandtab
EOF
}

setup_python_env() {
  log "Python env for BCC..."
  apt-get install -y python3-psutil python3-bpfcc
  local VENV_DIR="/root/bccenv"
  python3 -m venv --system-site-packages "$VENV_DIR"
  . "$VENV_DIR/bin/activate"
  pip install --upgrade pip wheel setuptools
  pip install cryptography pyOpenSSL numba pytest
  deactivate
  for f in /root/.bashrc /etc/skel/.bashrc; do
    grep -q "$VENV_DIR" "$f" 2>/dev/null || echo -e "\n# Auto-activate BCC venv\n[ -d \"$VENV_DIR\" ] && . \"$VENV_DIR/bin/activate\"" >> "$f"
  done
}

setup_users_and_ssh() {
  log "Creating users and hardening sshd..."
  for entry in "${USERS[@]}"; do
    u="${entry%%:*}"; key="${entry#*:}"
    id -u "$u" &>/dev/null || useradd --create-home --shell /bin/bash "$u"
    h="/home/$u"; mkdir -p "$h/.ssh"; chmod 700 "$h/.ssh"
    echo "$key" >"$h/.ssh/authorized_keys"; chmod 600 "$h/.ssh/authorized_keys"
    chown -R "$u:$u" "$h"
    echo "$u ALL=(ALL) NOPASSWD:ALL" >"/etc/sudoers.d/90-$u"; chmod 440 "/etc/sudoers.d/90-$u"
  done
  mkdir -p /etc/ssh/sshd_config.d
  cat >/etc/ssh/sshd_config.d/99-custom.conf <<EOF
Port 22
Protocol 2
PermitRootLogin no
PasswordAuthentication no
ChallengeResponseAuthentication no
UsePAM yes
X11Forwarding no
AllowTcpForwarding no
PermitEmptyPasswords no
ClientAliveInterval 300
ClientAliveCountMax 2
LoginGraceTime 30
MaxAuthTries 3
MaxSessions 2
PubkeyAuthentication yes
AuthorizedKeysFile .ssh/authorized_keys
AllowUsers ${ALLOW_USERS}
EOF
  chmod 600 /etc/ssh/sshd_config.d/99-custom.conf
  systemctl restart ssh
}

configure_dns_hosts() {
  log "Hostname + hosts..."
  VMNAME="$(hostname --short)"
  FQDN="${VMNAME}.${DOMAIN}"
  hostnamectl set-hostname "$FQDN"
  echo "$VMNAME" >/etc/hostname
  cat >/etc/hosts <<EOF
127.0.0.1 localhost
127.0.1.1 ${FQDN} ${VMNAME}
EOF
}

sync_skel_to_existing_users() {
  for u in root ansible debian; do
    h=$(eval echo "~$u") || true
    [ -d "$h" ] || continue
    cp /etc/skel/.bashrc "$h/.bashrc" || true
    cp /etc/skel/.tmux.conf "$h/.tmux.conf" || true
    cp /etc/skel/.vimrc "$h/.vimrc" || true
    chown -R "$u:$u" "$h" || true
  done
}

enable_services() {
  systemctl enable qemu-guest-agent ssh rsyslog chrony || true
}

cleanup_identity() {
  log "Cleaning identity for template safety..."
  truncate -s 0 /etc/machine-id
  rm -f /var/lib/dbus/machine-id
  ln -s /etc/machine-id /var/lib/dbus/machine-id
  rm -f /etc/ssh/ssh_host_* || true
  DEBIAN_FRONTEND=noninteractive dpkg-reconfigure openssh-server
}

final_cleanup() {
  apt autoremove -y || true
  apt clean || true
  rm -rf /tmp/* /var/tmp/* || true
  find /var/log -type f -exec truncate -s 0 {} \; || true
}

log "BEGIN postinstall"
update_and_upgrade
install_base_packages
maybe_install_desktop
enforce_wayland_defaults
maybe_install_cloud_init
disable_ipv6
setup_vim_config
write_bashrc
configure_ufw_firewall
write_tmux_conf
sync_skel_to_existing_users
setup_users_and_ssh
setup_python_env
configure_dns_hosts
install_custom_scripts
enable_services
cleanup_identity
final_cleanup

log "Disabling bootstrap service..."
systemctl disable bootstrap.service || true
rm -f /etc/systemd/system/bootstrap.service
rm -f /etc/systemd/system/multi-user.target.wants/bootstrap.service

log "Postinstall complete. Powering off..."
poweroff
EOSCRIPT
chmod +x "$DARKSITE_DIR/postinstall.sh"

# -----------------------------------------------------------------------------
# bootstrap.service
# -----------------------------------------------------------------------------
log "Writing bootstrap.service..."
cat > "$DARKSITE_DIR/bootstrap.service" <<'EOF'
[Unit]
Description=Initial Bootstrap Script (One-time)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/root/darksite/postinstall.sh
RemainAfterExit=no
TimeoutStartSec=900
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

# -----------------------------------------------------------------------------
# finalize-template.sh (runs on the build host; controls Proxmox cloning)
# -----------------------------------------------------------------------------
log "Writing finalize-template.sh..."
cat > "$DARKSITE_DIR/finalize-template.sh" <<'EOSCRIPT'
#!/usr/bin/env bash
set -euo pipefail

# Required env from caller:
: "${PROXMOX_HOST:?Missing PROXMOX_HOST}"
: "${TEMPLATE_VMID:?Missing TEMPLATE_VMID}"
: "${NUM_CLONES:?Missing NUM_CLONES}"
: "${BASE_CLONE_VMID:?Missing BASE_CLONE_VMID}"
: "${BASE_CLONE_IP:?Missing BASE_CLONE_IP}"
: "${CLONE_MEMORY_MB:=4096}"
: "${CLONE_CORES:=4}"
: "${CLONE_VLAN_ID:=}"
: "${CLONE_GATEWAY:=}"
: "${CLONE_NAMESERVER:=}"
: "${VMNAME_CLEAN:?Missing VMNAME_CLEAN}"
: "${VM_STORAGE:?Missing VM_STORAGE}"
: "${USE_CLOUD_INIT:=true}"
: "${DOMAIN:=localdomain}"

# Optional extra-disk vars (provided by main script)
: "${EXTRA_DISK_COUNT:=0}"
: "${EXTRA_DISK_SIZE_GB:=100}"
: "${EXTRA_DISK_TARGET:=}"

if [[ "$USE_CLOUD_INIT" != "true" ]]; then
  echo "[!] This flow expects cloud-init inside the template (USE_CLOUD_INIT=true)."
  echo "    Without it, clones will keep the template hostname/IP."
fi

echo "[*] Waiting for VM $TEMPLATE_VMID on $PROXMOX_HOST to shut down..."
SECONDS=0; TIMEOUT=900
while ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new root@"$PROXMOX_HOST" "qm status $TEMPLATE_VMID" | grep -q running; do
  (( SECONDS > TIMEOUT )) && { echo "[!] Timeout waiting for shutdown"; exit 1; }
  sleep 15
done

echo "[*] Converting $TEMPLATE_VMID to template..."
ssh root@"$PROXMOX_HOST" "qm template $TEMPLATE_VMID"

# Helper: check a storage exists/active on this node
check_storage() {
  local stor="$1"
  ssh root@"$PROXMOX_HOST" "pvesm status --storage $stor 2>/dev/null | awk 'NR>1 {print \$6}'" | grep -qx active
}

# Calculate base IP pieces
IP_PREFIX=$(echo "$BASE_CLONE_IP" | cut -d. -f1-3)
IP_START=$(echo "$BASE_CLONE_IP" | cut -d. -f4)

# Pre-check extra disk target if requested
if [[ "$EXTRA_DISK_COUNT" -gt 0 ]]; then
  if [[ -z "$EXTRA_DISK_TARGET" ]]; then
    echo "[!] EXTRA_DISK_COUNT>0 but EXTRA_DISK_TARGET is empty; extra disks will be skipped."
    EXTRA_DISK_COUNT=0
  else
    if check_storage "$EXTRA_DISK_TARGET"; then
      echo "[*] Extra disks will be created on storage '$EXTRA_DISK_TARGET' (${EXTRA_DISK_COUNT} x ${EXTRA_DISK_SIZE_GB}G per clone)."
    else
      echo "[!] Storage '$EXTRA_DISK_TARGET' is not active on node $PROXMOX_HOST; skipping extra disks."
      EXTRA_DISK_COUNT=0
    fi
  fi
fi

for ((i=0; i<NUM_CLONES; i++)); do
  CLONE_VMID=$((BASE_CLONE_VMID + i))
  INDEX=$((i+1))
  CLONE_IP="${IP_PREFIX}.$((IP_START + i))"

  # Name clones test-1, test-2, ... and set guest hostname accordingly
  NEW_HOSTNAME="${VMNAME_CLEAN}-${INDEX}"
  FQDN="${NEW_HOSTNAME}.${DOMAIN}"
  DESC="${FQDN} - ${CLONE_IP}"

  echo "[*] Cloning ${NEW_HOSTNAME} (VMID $CLONE_VMID, IP $CLONE_IP)..."

  ssh root@"$PROXMOX_HOST" "qm clone $TEMPLATE_VMID $CLONE_VMID --name '${NEW_HOSTNAME}' --full 1 --storage $VM_STORAGE"
  ssh root@"$PROXMOX_HOST" "qm set $CLONE_VMID --delete ide3 || true"

  NET_OPTS="virtio,bridge=vmbr0"
  [[ -n "$CLONE_VLAN_ID" ]] && NET_OPTS="${NET_OPTS},tag=${CLONE_VLAN_ID}"

  ssh root@"$PROXMOX_HOST" "qm set $CLONE_VMID \
    --memory $CLONE_MEMORY_MB \
    --cores $CLONE_CORES \
    --net0 $NET_OPTS \
    --agent enabled=1 \
    --boot order=scsi0 \
    --description '$DESC'"

  if [[ "$USE_CLOUD_INIT" == "true" ]]; then
    ssh root@"$PROXMOX_HOST" "qm set $CLONE_VMID --ide3 ${VM_STORAGE}:cloudinit"
    IPARG="ip=${CLONE_IP}/24"
    [[ -n "$CLONE_GATEWAY"    ]] && IPARG="${IPARG},gw=${CLONE_GATEWAY}"
    ssh root@"$PROXMOX_HOST" "qm set $CLONE_VMID --ipconfig0 '${IPARG}'"
    [[ -n "$CLONE_NAMESERVER" ]] && ssh root@"$PROXMOX_HOST" "qm set $CLONE_VMID --nameserver '$CLONE_NAMESERVER'"
    ssh root@"$PROXMOX_HOST" "qm set $CLONE_VMID --searchdomain '$DOMAIN' --hostname '$FQDN'"
  fi

  # Attach optional extra disks (scsi1..scsiN), scsi0 is the system disk
  if [[ "$EXTRA_DISK_COUNT" -gt 0 ]]; then
    echo "[*] Adding $EXTRA_DISK_COUNT extra disk(s) to VM $CLONE_VMID on $EXTRA_DISK_TARGET..."
    for ((d=1; d<=EXTRA_DISK_COUNT; d++)); do
      DISK_BUS="scsi$((d))"
      ssh root@"$PROXMOX_HOST" "qm set $CLONE_VMID --${DISK_BUS} ${EXTRA_DISK_TARGET}:${EXTRA_DISK_SIZE_GB}"
    done
  fi

  ssh root@"$PROXMOX_HOST" "qm start $CLONE_VMID"
  echo "[OK] Clone ${NEW_HOSTNAME} started."
done

echo "[OK] All clones created."
EOSCRIPT
chmod +x "$DARKSITE_DIR/finalize-template.sh"

# =============================================================================
#                        Preseed (Network + Profile)
# =============================================================================
log "Creating preseed.cfg..."

if [[ "$NETWORK_MODE" == "dhcp" ]]; then
  NETBLOCK=$(cat <<EOF
# Networking (DHCP)
d-i netcfg/choose_interface select auto
d-i netcfg/disable_dhcp boolean false
d-i netcfg/get_hostname string $VMNAME
d-i netcfg/get_domain string $DOMAIN
EOF
)
else
  NETBLOCK=$(cat <<EOF
# Networking (Static)
d-i netcfg/choose_interface select auto
d-i netcfg/get_hostname string $VMNAME
d-i netcfg/get_domain string $DOMAIN
d-i netcfg/disable_dhcp boolean true
d-i netcfg/get_ipaddress string $STATIC_IP
d-i netcfg/get_netmask string $NETMASK
d-i netcfg/get_gateway string $GATEWAY
d-i netcfg/get_nameservers string $NAMESERVER
EOF
)
fi

case "$INSTALL_PROFILE" in
  server)
    PROFILEBLOCK=$(cat <<'EOF'
# Server profile (no desktop)
tasksel tasksel/first multiselect standard, ssh-server
d-i pkgsel/include string
d-i pkgsel/ignore-recommends boolean true
d-i pkgsel/upgrade select none
EOF
)
    ;;
  gnome-min)
    PROFILEBLOCK=$(cat <<'EOF'
# Minimal GNOME (Wayland via gdm3; no xorg)
tasksel tasksel/first multiselect standard
d-i pkgsel/include string gnome-core gdm3 gnome-terminal network-manager
d-i pkgsel/ignore-recommends boolean true
d-i pkgsel/upgrade select none
EOF
)
    ;;
  gnome-full)
    PROFILEBLOCK=$(cat <<'EOF'
# Full GNOME (task-gnome-desktop uses Wayland by default)
tasksel tasksel/first multiselect standard, desktop, gnome-desktop, ssh-server
d-i pkgsel/include string
d-i pkgsel/ignore-recommends boolean false
d-i pkgsel/upgrade select none
EOF
)
    ;;
  xfce-min)
    PROFILEBLOCK=$(cat <<'EOF'
# Minimal XFCE (Xfce is X11; keep xorg)
tasksel tasksel/first multiselect standard
d-i pkgsel/include string xfce4 xfce4-terminal lightdm xorg network-manager
d-i pkgsel/ignore-recommends boolean true
d-i pkgsel/upgrade select none
EOF
)
    ;;
  kde-min)
    PROFILEBLOCK=$(cat <<'EOF'
# Minimal KDE Plasma (Wayland session)
tasksel tasksel/first multiselect standard
d-i pkgsel/include string plasma-desktop sddm plasma-workspace-wayland kwin-wayland konsole network-manager
d-i pkgsel/ignore-recommends boolean true
d-i pkgsel/upgrade select none
EOF
)
    ;;
  *)
    error_log "Unknown INSTALL_PROFILE: $INSTALL_PROFILE (use server|gnome-min|gnome-full|xfce-min|kde-min)"; exit 1;;
esac

cat > "$CUSTOM_DIR/$PRESEED_FILE" <<EOF
# Locale & keyboard
d-i debian-installer/locale string en_US.UTF-8
d-i console-setup/ask_detect boolean false
d-i keyboard-configuration/xkb-keymap select us

$NETBLOCK

# Mirrors (we'll re-point in postinstall)
d-i mirror/country string manual
d-i mirror/http/hostname string deb.debian.org
d-i mirror/http/directory string /debian
d-i mirror/http/proxy string
d-i apt-setup/use_mirror boolean false
d-i apt-setup/non-free boolean true
d-i apt-setup/contrib boolean true

# Temporary user (postinstall creates real users)
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

# Disk (guided LVM on whole disk)
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

$PROFILEBLOCK

# GRUB
d-i grub-installer/bootdev string /dev/sda
d-i grub-installer/only_debian boolean true

# Finish & power off (no reboot prompt)
d-i finish-install/keep-consoles boolean false
d-i finish-install/exit-installer boolean true
d-i cdrom-detect/eject boolean true
d-i debian-installer/exit/poweroff boolean true

# Late command: copy darksite & persist runtime vars for postinstall
d-i preseed/late_command string \
  mkdir -p /target/root/darksite ; \
  cp -a /cdrom/darksite/* /target/root/darksite/ ; \
  in-target chmod +x /root/darksite/postinstall.sh ; \
  in-target cp /root/darksite/bootstrap.service /etc/systemd/system/bootstrap.service ; \
  in-target /bin/sh -c 'mkdir -p /etc/environment.d' ; \
  in-target /bin/sh -c 'printf "DOMAIN=%s\nUSE_CLOUD_INIT=%s\nINSTALL_PROFILE=%s\n" "$DOMAIN" "$USE_CLOUD_INIT" "$INSTALL_PROFILE" > /etc/environment.d/99-provision.conf' ; \
  in-target systemctl daemon-reload ; \
  in-target systemctl enable bootstrap.service ;
EOF

# =============================================================================
#                        Boot menu & ISO rebuild
# =============================================================================
log "Updating isolinux/txt.cfg..."
TXT_CFG="$CUSTOM_DIR/isolinux/txt.cfg"
ISOLINUX_CFG="$CUSTOM_DIR/isolinux/isolinux.cfg"
cat >> "$TXT_CFG" <<EOF
label auto
  menu label ^base
  kernel /install.amd/vmlinuz
  append auto=true priority=critical vga=788 initrd=/install.amd/initrd.gz preseed/file=/cdrom/$PRESEED_FILE ---
EOF
sed -i 's/^default .*/default auto/' "$ISOLINUX_CFG"

log "Rebuilding ISO..."
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
log "ISO ready: $FINAL_ISO"

# =============================================================================
#                Upload ISO & create the base VM on Proxmox
# =============================================================================
log "Uploading ISO to $PROXMOX_HOST..."
scp -q "$FINAL_ISO" "root@${PROXMOX_HOST}:/var/lib/vz/template/iso/"
FINAL_ISO_BASENAME="$(basename "$FINAL_ISO")"

log "Creating VM $VMID on $PROXMOX_HOST..."
ssh root@"$PROXMOX_HOST" \
  VMID="$VMID" VMNAME="$BASE_VMNAME" FINAL_ISO="$FINAL_ISO_BASENAME" \
  VM_STORAGE="${VM_STORAGE:-void}" ISO_STORAGE="${ISO_STORAGE:-local}" \
  DISK_SIZE_GB="${DISK_SIZE_GB:-32}" MEMORY_MB="${MEMORY_MB:-4096}" \
  CORES="${CORES:-4}" USE_CLOUD_INIT="${USE_CLOUD_INIT:-true}" \
  'bash -s' <<'EOSSH'
set -euo pipefail
: "${VMID:?}"; : "${VMNAME:?}"; : "${FINAL_ISO:?}"
: "${VM_STORAGE:?}"; : "${ISO_STORAGE:?}"
: "${DISK_SIZE_GB:?}"; : "${MEMORY_MB:?}"; : "${CORES:?}"
: "${USE_CLOUD_INIT:?}"

qm destroy "$VMID" --purge || true

qm create "$VMID" \
  --name "$VMNAME" \
  --memory "$MEMORY_MB" \
  --cores "$CORES" \
  --net0 virtio,bridge=vmbr0,firewall=1 \
  --ide2 ${ISO_STORAGE}:iso/${FINAL_ISO},media=cdrom \
  --scsihw virtio-scsi-single \
  --scsi0 ${VM_STORAGE}:${DISK_SIZE_GB} \
  --serial0 socket \
  --ostype l26 \
  --agent enabled=1

qm set "$VMID" --efidisk0 ${VM_STORAGE}:0,efitype=4m,pre-enrolled-keys=0
qm set "$VMID" --boot order=ide2
qm start "$VMID"
EOSSH

# =============================================================================
#           Wait for preseed shutdown, flip boot order, set description
# =============================================================================
log "Waiting for VM $VMID to power off after installer..."
SECONDS=0; TIMEOUT=1800
while ssh root@"$PROXMOX_HOST" "qm status $VMID" | grep -q running; do
  (( SECONDS > TIMEOUT )) && { error_log "Timeout waiting for installer shutdown"; exit 1; }
  sleep 20
done

# Base VM description = <fqdn>-template - IP|DHCP
if [[ "$NETWORK_MODE" == "static" ]]; then
  BASE_DESC="${BASE_FQDN}-template - ${STATIC_IP}"
else
  BASE_DESC="${BASE_FQDN}-template - DHCP"
fi

log "Detach ISO, set boot=scsi0, (optionally) add cloudinit, set description..."
ssh root@"$PROXMOX_HOST" 'bash -s --' "$VMID" "$VM_STORAGE" "$USE_CLOUD_INIT" "$BASE_DESC" <<'EOSSH'
set -euo pipefail
VMID="$1"; VM_STORAGE="$2"; USE_CLOUD_INIT="$3"; VM_DESC="$4"

qm set "$VMID" --delete ide2
qm set "$VMID" --boot order=scsi0
if [ "$USE_CLOUD_INIT" = "true" ]; then
  qm set "$VMID" --ide3 ${VM_STORAGE}:cloudinit
fi
qm set "$VMID" --description "$VM_DESC"
qm start "$VMID"
EOSSH

# =============================================================================
#                Wait for postinstall poweroff, then template+clone
# =============================================================================
log "Waiting for VM $VMID to power off after postinstall..."
SECONDS=0; TIMEOUT=1800
while ssh root@"$PROXMOX_HOST" "qm status $VMID" | grep -q running; do
  (( SECONDS > TIMEOUT )) && { error_log "Timeout waiting for postinstall shutdown"; exit 1; }
  sleep 20
done

log "Template + clone loop..."
export PROXMOX_HOST TEMPLATE_VMID="$VMID" VM_STORAGE USE_CLOUD_INIT DOMAIN
export NUM_CLONES BASE_CLONE_VMID BASE_CLONE_IP CLONE_MEMORY_MB CLONE_CORES
export CLONE_VLAN_ID CLONE_GATEWAY="$GATEWAY" CLONE_NAMESERVER="$NAMESERVER"
export VMNAME_CLEAN="$VMNAME"
export EXTRA_DISK_COUNT EXTRA_DISK_SIZE_GB EXTRA_DISK_TARGET

bash "$DARKSITE_DIR/finalize-template.sh"

log "All done."
