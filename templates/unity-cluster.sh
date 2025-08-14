#!/bin/bash
set -euo pipefail

LOG_FILE="/root/install.txt"
exec &> >(tee -a "$LOG_FILE")

log() { echo "[INFO] $(date): $1"; }
error_log() { echo "[ERROR] $(date): $1" >&2; }

# .iso.conf
ISO_ORIG="/root/debian-12.10.0-amd64-netinst.iso" # Original Source .iso
BUILD_DIR="/root/bhs-dev-odin" # Directory to build packages & artifacts
CUSTOM_DIR="$BUILD_DIR/custom" #  Add custom directories to include on the .iso
MOUNT_DIR="/mnt/bhs-dev-odin" # Where to mount the .iso to be "repacked"
DARKSITE_DIR="$CUSTOM_DIR/darksite" # Destination directory for the "custom"  directory content
PRESEED_FILE="preseed.cfg" # name of the file for the pressed.configuration
OUTPUT_ISO="$BUILD_DIR/base.iso" # Name of the "re-packed" .iso
FINAL_ISO="/root/bhs-dev-odin.iso" # Final .iso output

# template.conf
INPUT="5" #  Proxmox host number (update the case statment below)
VMID="3005" # vmid of the TEMPLATE
VLANID="30" # VLAN_id (see case statment below)
VMNAME="bhs-dev-odin" # Name of the Template
STATIC_IP="192.168.30.105" # Base/Starting IP
NETMASK="255.255.255.0" # default netmask
GATEWAY="192.168.30.1" # default gateway
NAMESERVER="192.168.30.1" # default dns

# clone.conf
NUM_CLONES=3 # Number of clones
BASE_CLONE_VMID=305 # Starting VMID
BASE_CLONE_IP="$STATIC_IP" # Starting with the Static IP
CLONE_MEMORY_MB=4096 # Memory per clone
CLONE_CORES=4 # Cores per clone

# === VLAN-derived env ===
case "$VLANID" in
  10)
    : "${DOMAIN:=mgt.xaeon.io}"
    : "${GATEWAY:=10.0.10.1}"
    : "${NETMASK:=255.255.255.0}"
    : "${NAMESERVER1:=10.0.10.1}"
    : "${NAMESERVER2:=1.1.1.1}"
    ;;
  20)
    : "${DOMAIN:=dmz.xaeon.io}"
    : "${GATEWAY:=192.168.20.1}"
    : "${NETMASK:=255.255.255.0}"
    : "${NAMESERVER1:=192.168.20.1}"
    : "${NAMESERVER2:=1.1.1.1}"
    ;;
  30)
    : "${DOMAIN:=dev.xaeon.io}"
    : "${GATEWAY:=192.168.30.1}"
    : "${NETMASK:=255.255.255.0}"
    : "${NAMESERVER1:=192.168.30.1}"
    : "${NAMESERVER2:=1.1.1.1}"
    ;;
  40)
    : "${DOMAIN:=sql.xaeon.io}"
    : "${GATEWAY:=172.16.40.1}"
    : "${NETMASK:=255.255.255.0}"
    : "${NAMESERVER1:=172.16.40.1}"
    : "${NAMESERVER2:=1.1.1.1}"
    ;;
  50)
    : "${DOMAIN:=vpn.xaeon.io}"
    : "${GATEWAY:=172.16.50.1}"
    : "${NETMASK:=255.255.255.0}"
    : "${NAMESERVER1:=172.16.50.1}"
    : "${NAMESERVER2:=1.1.1.1}"
    ;;
  60)
    : "${DOMAIN:=wal.xaeon.io}"
    : "${GATEWAY:=172.16.60.1}"
    : "${NETMASK:=255.255.255.0}"
    : "${NAMESERVER1:=172.16.60.1}"
    : "${NAMESERVER2:=1.1.1.1}"
    ;;
  *)
    error_log "Unknown VLANID: $VLANID"; exit 1 ;;
esac

# Build combined list once (for cloud-init, preseed, qm)
NAMESERVERS_LIST="$NAMESERVER1${NAMESERVER2:+ $NAMESERVER2}"
VMNAME_SHORT="${VMNAME}"
DOMAIN="${DOMAIN}"
FQDN="${VMNAME_SHORT}.${DOMAIN}"
PROXMOX_VMNAME="${VMNAME_SHORT}.${DOMAIN}-${STATIC_IP}"
VMNAME="$VMNAME_SHORT"

# Clean VM Names
VMNAME_CLEAN="${VMNAME//[_\.]/-}"
VMNAME_CLEAN="$(echo "$VMNAME_CLEAN" | sed 's/^-*//;s/-*$//')"
VMNAME_CLEAN="$(echo "$VMNAME_CLEAN" | sed 's/--*/-/g')"
VMNAME_CLEAN="$(echo "$VMNAME_CLEAN" | tr '[:upper:]' '[:lower:]')"

if [[ ! "$VMNAME_CLEAN" =~ ^[a-z0-9-]+$ ]]; then
  error_log "Invalid VM name after cleanup: '$VMNAME_CLEAN'. Must be DNS-safe: letters, digits, dash only."
  exit 1
fi

VMNAME="$VMNAME_CLEAN"
log "[*] Using Proxmox host $INPUT, VMID $VMID, VLANID $VLANID"

case "$INPUT" in
  1|bmh-pve-1) HOST_NAME="bmh-pve-1"; PROXMOX_HOST="10.0.10.10" ;;
  2|bmh-pve-2) HOST_NAME="bmh-pve-2"; PROXMOX_HOST="10.0.10.20" ;;
  3|bmh-pve-3) HOST_NAME="bmh-pve-3"; PROXMOX_HOST="10.0.10.30" ;;
  4|bmh-pve-4) HOST_NAME="bmh-pve-4"; PROXMOX_HOST="10.0.10.15" ;;
  5|bmh-pve-5) HOST_NAME="bmh-pve-5"; PROXMOX_HOST="10.0.10.25" ;;
  6|gra-pve-1) HOST_NAME="gra-pve-1"; PROXMOX_HOST="10.0.10.210" ;;
  7|gra-pve-2) HOST_NAME="gra-pve-2"; PROXMOX_HOST="10.0.10.211" ;;
  *) error_log "Unknown host: $INPUT"; exit 1 ;;
esac

log "[*] Cleaning up..."
umount "$MOUNT_DIR" 2>/dev/null || true
rm -rf "$BUILD_DIR"
mkdir -p "$CUSTOM_DIR" "$MOUNT_DIR" "$DARKSITE_DIR"

log "[*] Mounting ISO..."
mount -o loop "$ISO_ORIG" "$MOUNT_DIR" || error_log "Failed to mount ISO"

log "[*] Copying ISO contents..."
cp -a "$MOUNT_DIR/"* "$CUSTOM_DIR/" || error_log "Failed to copy ISO contents"
cp -a "$MOUNT_DIR/.disk" "$CUSTOM_DIR/" || error_log "Failed to copy .disk directory"
log "[*] Copying custom scripts to darksite..."
mkdir -p "$DARKSITE_DIR/scripts"
cp -a /root/build/scripts/* "$DARKSITE_DIR/scripts/"
mkdir -p "$DARKSITE_DIR/opt/unityserver"
UNITY_DIR="$DARKSITE_DIR/opt/unityserver"
rm -rf "$UNITY_DIR"
mkdir -p "$UNITY_DIR/Data" "$UNITY_DIR/Scenes" "$UNITY_DIR/Scripts"
echo "Dummy Asset Data" > "$UNITY_DIR/Data/readme.txt"
echo "Dummy Scene Data" > "$UNITY_DIR/Scenes/sample_scene.unity"
echo "Dummy Script Content" > "$UNITY_DIR/Scripts/sample_script.cs"

cat > "$UNITY_DIR/server.c" <<'EOF'
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <netinet/in.h>
#include <arpa/inet.h>

#define PORT 7777

int main() {
    int server_fd, new_socket;
    struct sockaddr_in address;
    int addrlen = sizeof(address);
    printf("[INFO] Starting Unity Dummy Server on port %d...\n", PORT);
    server_fd = socket(AF_INET, SOCK_STREAM, 0);
    if (server_fd == 0) { perror("[ERROR] Socket failed"); exit(EXIT_FAILURE); }
    int opt = 1;
    setsockopt(server_fd, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));
    address.sin_family = AF_INET;
    address.sin_addr.s_addr = INADDR_ANY;
    address.sin_port = htons(PORT);
    if (bind(server_fd, (struct sockaddr *)&address, sizeof(address)) < 0) {
        perror("[ERROR] Bind failed");
        exit(EXIT_FAILURE);
    }
    if (listen(server_fd, 10) < 0) {
        perror("[ERROR] Listen failed");
        exit(EXIT_FAILURE);
    }
    printf("[INFO] Unity Dummy Server ready. Waiting for players...\n");
    while (1) {
        new_socket = accept(server_fd, (struct sockaddr *)&address, (socklen_t*)&addrlen);
        if (new_socket >= 0) {
            printf("[INFO] Player connected: %s:%d\n", inet_ntoa(address.sin_addr), ntohs(address.sin_port));
            send(new_socket, "Welcome to Dummy Unity Server!\n", 30, 0);
            close(new_socket);
        }
    }
}
EOF

gcc "$UNITY_DIR/server.c" -o "$UNITY_DIR/server.x86_64" -static
rm "$UNITY_DIR/server.c"
chmod +x "$UNITY_DIR/server.x86_64"

log "[*] Creating Unity systemd unit..."
mkdir -p "$DARKSITE_DIR/etc/systemd/system"
cat > "$DARKSITE_DIR/etc/systemd/system/unityserver.service" <<'EOF'
[Unit]
Description=Unity Headless MMO Server
After=network.target

[Service]
WorkingDirectory=/opt/unityserver
ExecStart=/opt/unityserver/server.x86_64
Restart=always
RestartSec=5
User=root

[Install]
WantedBy=multi-user.target
EOF
umount "$MOUNT_DIR"

log "[*] Writing postinstall.sh..."
# Create the script and inject environment vars from the build
{
  echo "#!/bin/bash"
  echo "set -euxo pipefail"
  echo ""
  echo "# === Baked from build script ==="
  echo "VMNAME=\"$VMNAME\""
  echo "DOMAIN=\"$DOMAIN\""
  echo "NAMESERVER1=\"$NAMESERVER1\""
  echo "NAMESERVER2=\"${NAMESERVER2:-}\""
  echo ""
} > "$DARKSITE_DIR/postinstall.sh"

cat >> "$DARKSITE_DIR/postinstall.sh" <<'EOSCRIPT'

UNITY_DB="unityworld"
UNITY_USER="unity"
UNITY_PASS="unitypass"
REDIS_PASS="redispass"
UNITY_DEST="/opt/unityserver"
UNITY_SRC="/root/darksite/opt/unityserver"
UNITY_SERVICE="/etc/systemd/system/unityserver.service"

LOG="/var/log/postinstall.log"
exec > >(tee -a "$LOG") 2>&1
exec 2>&1

trap 'echo "[✖] Script failed at line $LINENO" >&2; exit 1' ERR

log() { echo "[INFO] $(date '+%F %T') — $*"; }

# === USER DEFS ===
USERS=(
  "ansible:ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIWVsNIM6mkGM93IO64eHzAMg+xDQtDFYwuWRproAjrr ansible@semaphore"
  "debian:ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEM7mYwLYV6GvfoMh7f7y0goimbAtzjdkmCyJuoBEJ4o debian@semaphore"
  "RQ:ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIa5HMKOWih1FxPm0+5myxzudXQi91l5DQi/InJ5vR+O eddsa-key-20250716"
  "selim:ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILG0fkYewHgbwHBpXvgAPU6cXLY0rsnI5k93sRYNnrMe"
  "geooogle:ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILn/zcKJ84eaeQXU62JBx6MW8Zo1k7unS3HdQQrF7dye geooogle@tuf15"
  "todd:ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHV51Eelt8PwYreHhJJ4JJP3OMwrXswUShblYY10J+A/ todd@onyx"
  "coolify:ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIF4fBk0wYdkT6HJ04BPXv5DSEnvCzPpl06zD6PhWnpKR coolify@init"
  "srb:ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFWguqeG9CRBAZVHATEVLhU7o110wqoZozVczidlK6/h srb@hydra.cuci.nl"
)

# -----------------------------------------------------------------------------
update_and_upgrade() {
  log "[*] Updating and upgrading system..."

  # Write new sources.list
  cat <<EOF > /etc/apt/sources.list
deb http://deb.debian.org/debian bookworm main contrib non-free non-free-firmware
deb http://security.debian.org/debian-security bookworm-security main contrib non-free non-free-firmware
deb http://deb.debian.org/debian bookworm-updates main contrib non-free non-free-firmware
EOF

  # Noninteractive prevents prompts during dist-upgrade
  export DEBIAN_FRONTEND=noninteractive

  # Update and upgrade with safe fail
  apt update
  apt upgrade -y
}

# -----------------------------------------------------------------------------
install_base_packages() {
  log "Installing base packages..."

  apt install -y --no-install-recommends \
    curl wget ca-certificates gnupg lsb-release unzip \
    net-tools traceroute tcpdump sysstat strace lsof ltrace \
    rsync rsyslog cron chrony sudo git ethtool jq \
    cloud-init cloud-guest-utils qemu-guest-agent openssh-server \
    prometheus-node-exporter ngrep nmap netplan.io \
    bpfcc-tools bpftrace libbpf-dev python3-bpfcc python3 python3-pip \
    uuid-runtime tmux htop python3.11-venv \
    linux-image-amd64 linux-headers-amd64 redis-server postgresql \
    nginx varnish
}

# -----------------------------------------------------------------------------
disable_ipv6() {
  log "Disabling IPv6..."
  cat <<EOF > /etc/sysctl.d/99-disable-ipv6.conf
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
EOF
  sysctl -p /etc/sysctl.d/99-disable-ipv6.conf
}

# -----------------------------------------------------------------------------

# -----------------------------------------------------------------------------
write_bashrc() {
  log "Writing clean .bashrc for all users (via /etc/skel)..."

  local BASHRC=/etc/skel/.bashrc

  cat > "$BASHRC" <<'EOF'
# ~/.bashrc -- powerful defaults

# If not running interactively, don't do anything
[ -z "$PS1" ] && return

# Prompt
PS1='\[\e[0;32m\]\u@\h\[\e[m\]:\[\e[0;34m\]\w\[\e[m\]\$ '

# History with timestamps
HISTSIZE=10000
HISTFILESIZE=20000
HISTTIMEFORMAT='%F %T '
HISTCONTROL=ignoredups:erasedups
shopt -s histappend
shopt -s checkwinsize
shopt -s cdspell

# Color grep
alias grep='grep --color=auto'

# ls aliases
alias ls='ls --color=auto'
alias ll='ls -alF'
alias la='ls -A'
alias l='ls -CF'

# Safe file ops
alias cp='cp -i'
alias mv='mv -i'
alias rm='rm -i'

# Net & disk helpers
alias ports='ss -tuln'
alias df='df -h'
alias du='du -h'

alias tk='tmux kill-server'

# Load bash completion if available
if [ -f /etc/bash_completion ]; then
  . /etc/bash_completion
fi

# Auto-activate BCC virtualenv if present
VENV_DIR="/root/bccenv"
if [ -d "$VENV_DIR" ]; then
  if [ -n "$PS1" ]; then
    source "$VENV_DIR/bin/activate"
  fi
fi

# Custom: Show welcome on login
echo "$USER! Connected to: $(hostname) on $(date)"
EOF

  log ".bashrc written to /etc/skel/.bashrc"

  for USERNAME in root ansible debian; do
    HOME_DIR=$(eval echo "~$USERNAME")
    if [ -d "$HOME_DIR" ]; then
      cp "$BASHRC" "$HOME_DIR/.bashrc"
      chown "$USERNAME:$USERNAME" "$HOME_DIR/.bashrc"
      log "Updated .bashrc for $USERNAME"
    else
      log "Skipped .bashrc update for $USERNAME (home not found)"
    fi
  done

}

# -----------------------------------------------------------------------------
configure_ufw_firewall() {
  log "Configuring UFW firewall..."

  apt-get install -y ufw
  sed -i 's/^IPV6=.*/IPV6=no/' /etc/default/ufw
  ufw default deny incoming
  ufw default allow outgoing
  ufw allow 22/tcp
  ufw --force enable

  log "UFW firewall configured and enabled."
}

# -----------------------------------------------------------------------------
write_tmux_conf() {
  log "Writing tmux.conf to /etc/skel and root"

  local TMUX_CONF="/etc/skel/.tmux.conf"

  cat > "$TMUX_CONF" <<'EOF'
# ~/.tmux.conf — Airline-style theme
set -g mouse on
setw -g mode-keys vi
set -g history-limit 10000
set -g default-terminal "screen-256color"
set-option -ga terminal-overrides ",xterm-256color:Tc"
set-option -g status on
set-option -g status-interval 5
set-option -g status-justify centre
set-option -g status-bg colour236
set-option -g status-fg colour250
set-option -g status-style bold
set-option -g status-left-length 60
set-option -g status-left "#[fg=colour0,bg=colour83] #S #[fg=colour83,bg=colour55,nobold,nounderscore,noitalics]"
set-option -g status-right-length 120
set-option -g status-right "#[fg=colour55,bg=colour236]#[fg=colour250,bg=colour55] %Y-%m-%d  %H:%M #[fg=colour236,bg=colour55]#[fg=colour0,bg=colour236] #H "
set-window-option -g window-status-current-style "fg=colour0,bg=colour83,bold"
set-window-option -g window-status-current-format " #I:#W "
set-window-option -g window-status-style "fg=colour250,bg=colour236"
set-window-option -g window-status-format " #I:#W "
set-option -g pane-border-style "fg=colour238"
set-option -g pane-active-border-style "fg=colour83"
set-option -g message-style "bg=colour55,fg=colour250"
set-option -g message-command-style "bg=colour55,fg=colour250"
set-window-option -g bell-action none
bind | split-window -h
bind - split-window -v
unbind '"'
unbind %
bind r source-file ~/.tmux.conf \; display-message "Reloaded!"
bind-key -T copy-mode-vi 'v' send -X begin-selection
bind-key -T copy-mode-vi 'y' send -X copy-selection-and-cancel
EOF

  log ".tmux.conf written to /etc/skel/.tmux.conf"

  # Also set for root:
  cp "$TMUX_CONF" /root/.tmux.conf
  log ".tmux.conf copied to /root/.tmux.conf"
}

# -----------------------------------------------------------------------------
configure_cloud_init() {
  log "Configuring Cloud-Init defaults (user + fallback)..."

  local CONFIG_DIR="/etc/cloud/cloud.cfg.d"
  mkdir -p "$CONFIG_DIR"
  chmod 700 "$CONFIG_DIR"
  chown root:root "$CONFIG_DIR"

  cloud-init clean --logs

  # Main Cloud-Init user config
  local CUSTOM_CFG="$CONFIG_DIR/99_custom.cfg"
  cat <<EOF > "$CUSTOM_CFG"
disable_root: false
preserve_hostname: false
datasource_list: [ ConfigDrive, NoCloud ]
ssh_pwauth: false
ssh_deletekeys: true
manage_ssh_keys: true
ssh_genkeytypes: [ 'rsa', 'ecdsa', 'ed25519' ]

runcmd:
  - ip link set dev ens18 mtu 9000
EOF

  chmod 600 "$CUSTOM_CFG"
  chown root:root "$CUSTOM_CFG"

  log "Cloud-Init user config baked with MTU enforcement and fallback."
}

# -----------------------------------------------------------------------------
install_custom_scripts() {
  log "Installing custom scripts to /usr/local/bin..."

  if [[ -d /root/darksite/scripts ]]; then
    cp -a /root/darksite/scripts/* /usr/local/bin/
    chmod +x /usr/local/bin/*
    log "Custom scripts installed."
  else
    log "No custom scripts found in /root/darksite/scripts"
  fi
}

# -----------------------------------------------------------------------------
deploy_unity() {
  set -euo pipefail

  # Use baked vars; provide sane fallbacks if any got omitted
  UNITY_DB="${UNITY_DB:-unityworld}"
  UNITY_USER="${UNITY_USER:-unity}"
  UNITY_PASS="${UNITY_PASS:-unitypass}"
  REDIS_PASS="${REDIS_PASS:-redispass}"
  UNITY_DEST="${UNITY_DEST:-/opt/unityserver}"
  UNITY_SRC="${UNITY_SRC:-/root/darksite/opt/unityserver}"
  UNITY_SERVICE="${UNITY_SERVICE:-/etc/systemd/system/unityserver.service}"

  _exists() { command -v "$1" >/dev/null 2>&1; }

  log "=== Unity stack install starting ==="

  # 1) Unity server files + systemd unit
  log "[unity] deploying files to $UNITY_DEST"
  mkdir -p "$UNITY_DEST"
  cp -an "$UNITY_SRC"/* "$UNITY_DEST"/ || log "[unity] files already present, skipping copy"
  chmod +x "$UNITY_DEST"/server.* 2>/dev/null || true
  chmod +x "$UNITY_DEST"/server.x86_64 2>/dev/null || true

  if [ -f "$UNITY_SRC/../../etc/systemd/system/unityserver.service" ]; then
    cp -f "$UNITY_SRC/../../etc/systemd/system/unityserver.service" "$UNITY_SERVICE"
  elif [ -f "$UNITY_SRC/unityserver.service" ]; then
    cp -f "$UNITY_SRC/unityserver.service" "$UNITY_SERVICE"
  else
    log "[unity] WARNING: unityserver.service not found in expected paths; continuing"
  fi

  systemctl daemon-reload
  systemctl enable unityserver.service 2>/dev/null || true
  systemctl restart unityserver.service 2>/dev/null || true
  log "[unity] service enabled & (re)started if present"

  # 2) PostgreSQL database/user
  if _exists psql || systemctl is-enabled --quiet postgresql 2>/dev/null; then
    log "[postgres] ensuring database '$UNITY_DB' and user '$UNITY_USER'"

    sudo -u postgres psql -tc "SELECT 1 FROM pg_database WHERE datname='$UNITY_DB'" | grep -q 1 || \
      sudo -u postgres psql -c "CREATE DATABASE $UNITY_DB"

    if ! sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='$UNITY_USER'" | grep -q 1; then
      sudo -u postgres psql -c "CREATE USER $UNITY_USER WITH ENCRYPTED PASSWORD '$UNITY_PASS';"
    fi

    sudo -u postgres psql -c "GRANT ALL PRIVILEGES ON DATABASE $UNITY_DB TO $UNITY_USER;"
    log "[postgres] db/user ready"
  else
    log "[postgres] WARNING: PostgreSQL not detected; skipped"
  fi

  # 3) Redis password
  if systemctl list-unit-files | grep -q '^redis'; then
    log "[redis] configuring password"
    if grep -qE '^\s*requirepass\s' /etc/redis/redis.conf; then
      sed -i "s/^\s*requirepass\s\+.*/requirepass $REDIS_PASS/" /etc/redis/redis.conf || true
    else
      # add (uncomment) requirepass just in case
      sed -i "s/^#\s*requirepass .*/requirepass $REDIS_PASS/" /etc/redis/redis.conf || true
      grep -qE '^\s*requirepass\s' /etc/redis/redis.conf || echo "requirepass $REDIS_PASS" >> /etc/redis/redis.conf
    fi
    systemctl restart redis || true
    log "[redis] restarted with password"
  else
    log "[redis] WARNING: Redis not present; skipped"
  fi

  # 4) Varnish tuning (front :80 -> backend :8080)
  if systemctl list-unit-files | grep -q '^varnish\.service'; then
    log "[varnish] tuning port and service ExecStart"
    [ -f /etc/varnish/default.vcl ] && sed -i 's/.port = "6081";/.port = "80";/' /etc/varnish/default.vcl || true
    if [ -f /lib/systemd/system/varnish.service ]; then
      sed -i 's|^ExecStart=.*|ExecStart=/usr/sbin/varnishd -a :80 -b localhost:8080|' /lib/systemd/system/varnish.service || true
      systemctl daemon-reexec
      systemctl restart varnish || true
    fi
    log "[varnish] updated"
  else
    log "[varnish] WARNING: Varnish not present; skipped"
  fi

  # 5) UFW rules
  if _exists ufw; then
    log "[ufw] applying rules"
    ufw allow 22/tcp || true
    ufw allow 80/tcp || true
    ufw allow 6081/tcp || true
    ufw allow 7777/tcp || true
    ufw --force enable || true
  else
    log "[ufw] WARNING: ufw not installed; skipped"
  fi

  log "[logs] creating tmpfiles rules"
  cat > /etc/tmpfiles.d/services.conf <<'EOF'
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
  log "[logs] pruning"
  find /var/log -type f -not -name 'postinstall.log' -delete || true
  rm -rf /tmp/* /var/tmp/* || true
  log "[cleanup] removing temporary Unity sources if present"
  rm -rf /root/darksite/opt/unityserver 2>/dev/null || true
  rm -f "$UNITY_SRC/../../etc/systemd/system/unityserver.service" 2>/dev/null || true
  log "=== Unity stack install complete ==="
}

# -----------------------------------------------------------------------------
setup_vim_config() {
  log "Writing standard Vim config..."
    apt-get install -y \
    vim \
    vim-airline \
    vim-airline-themes \
    vim-ctrlp \
    vim-fugitive \
    vim-gitgutter \
    vim-tabular

  local VIMRC=/etc/skel/.vimrc
  mkdir -p /etc/skel/.vim/autoload/airline/themes

  cat > "$VIMRC" <<'EOF'
syntax on
filetype plugin indent on
set nocompatible
set number
set relativenumber
set tabstop=2 shiftwidth=2 expandtab
set autoindent smartindent
set background=dark
set ruler
set showcmd
set cursorline
set wildmenu
set incsearch
set hlsearch
set laststatus=2
set clipboard=unnamedplus
set showmatch
set backspace=indent,eol,start
set ignorecase
set smartcase
set scrolloff=5
set wildmode=longest,list,full
set splitbelow
set splitright
set colorcolumn=80
highlight ColorColumn ctermbg=darkgrey guibg=grey
highlight ExtraWhitespace ctermbg=red guibg=red
match ExtraWhitespace /\s\+$/
let g:airline_powerline_fonts = 1
let g:airline_theme = 'custom'
let g:airline#extensions#tabline#enabled = 1
let g:airline_section_z = '%l:%c'
let g:ctrlp_map = '<c-p>'
let g:ctrlp_cmd = 'CtrlP'
nmap <leader>gs :Gstatus<CR>
nmap <leader>gd :Gdiff<CR>
nmap <leader>gc :Gcommit<CR>
nmap <leader>gb :Gblame<CR>
let g:gitgutter_enabled = 1
autocmd FileType python,yaml setlocal tabstop=2 shiftwidth=2 expandtab
autocmd FileType javascript,typescript,json setlocal tabstop=2 shiftwidth=2 expandtab
autocmd FileType sh,bash,zsh setlocal tabstop=2 shiftwidth=2 expandtab
nnoremap <leader>w :w<CR>
nnoremap <leader>q :q<CR>
nnoremap <leader>tw :%s/\s\+$//e<CR>
if &term =~ 'xterm'
  let &t_SI = "\e[6 q"
  let &t_EI = "\e[2 q"
endif
EOF

  cat > /etc/skel/.vim/autoload/airline/themes/custom.vim <<'EOF'
let g:airline#themes#custom#palette = {}
let s:N1 = [ '#000000' , '#00ff5f' , 0 , 83 ]
let s:N2 = [ '#ffffff' , '#5f00af' , 255 , 55 ]
let s:N3 = [ '#ffffff' , '#303030' , 255 , 236 ]
let s:I1 = [ '#000000' , '#5fd7ff' , 0 , 81 ]
let s:I2 = [ '#ffffff' , '#5f00d7' , 255 , 56 ]
let s:I3 = [ '#ffffff' , '#303030' , 255 , 236 ]
let s:V1 = [ '#000000' , '#af5fff' , 0 , 135 ]
let s:V2 = [ '#ffffff' , '#8700af' , 255 , 91 ]
let s:V3 = [ '#ffffff' , '#303030' , 255 , 236 ]
let s:R1 = [ '#000000' , '#ff5f00' , 0 , 202 ]
let s:R2 = [ '#ffffff' , '#d75f00' , 255 , 166 ]
let s:R3 = [ '#ffffff' , '#303030' , 255 , 236 ]
let s:IA = [ '#aaaaaa' , '#1c1c1c' , 250 , 234 ]
let g:airline#themes#custom#palette.normal = airline#themes#generate_color_map(s:N1, s:N2, s:N3)
let g:airline#themes#custom#palette.insert = airline#themes#generate_color_map(s:I1, s:I2, s:I3)
let g:airline#themes#custom#palette.visual = airline#themes#generate_color_map(s:V1, s:V2, s:V3)
let g:airline#themes#custom#palette.replace = airline#themes#generate_color_map(s:R1, s:R2, s:R3)
let g:airline#themes#custom#palette.inactive = airline#themes#generate_color_map(s:IA, s:IA, s:IA)
EOF
}

# -----------------------------------------------------------------------------
setup_python_env() {
  log "Setting up Python for BCC scripts..."

  # System packages only — no pip bcc!
  apt-get install -y python3-psutil python3-bpfcc

  # Create a virtualenv that sees system site-packages
  local VENV_DIR="/root/bccenv"
  python3 -m venv --system-site-packages "$VENV_DIR"

  source "$VENV_DIR/bin/activate"
  pip install --upgrade pip wheel setuptools
  pip install cryptography pyOpenSSL numba pytest
  deactivate

  log "System Python has psutil + bpfcc. Venv created at $VENV_DIR with system site-packages."

  # Auto-activate for root
  local ROOT_BASHRC="/root/.bashrc"
  if ! grep -q "$VENV_DIR" "$ROOT_BASHRC"; then
    echo "" >> "$ROOT_BASHRC"
    echo "# Auto-activate BCC virtualenv" >> "$ROOT_BASHRC"
    echo "source \"$VENV_DIR/bin/activate\"" >> "$ROOT_BASHRC"
  fi

  # Auto-activate for future users
  local SKEL_BASHRC="/etc/skel/.bashrc"
  if ! grep -q "$VENV_DIR" "$SKEL_BASHRC"; then
    echo "" >> "$SKEL_BASHRC"
    echo "# Auto-activate BCC virtualenv if available" >> "$SKEL_BASHRC"
    echo "[ -d \"$VENV_DIR\" ] && source \"$VENV_DIR/bin/activate\"" >> "$SKEL_BASHRC"
  fi

  log "Virtualenv activation added to root and skel .bashrc"
}

# -----------------------------------------------------------------------------
setup_users_and_ssh() {
  log "Creating users, sudo rules, .ssh dirs — baked keys."

  # Create users and their SSH setup
  for entry in "${USERS[@]}"; do
    local USERNAME="${entry%%:*}"
    local PUBKEY="${entry#*:}"

    if ! id -u "$USERNAME" &>/dev/null; then
      useradd --create-home --shell /bin/bash "$USERNAME"
      log "User $USERNAME created."
    fi

    local HOME="/home/$USERNAME"

    # skel
    cp /etc/skel/.bashrc "$HOME/.bashrc" 2>/dev/null || true
    chown "$USERNAME:$USERNAME" "$HOME/.bashrc" 2>/dev/null || true

    # ssh
    local SSH_DIR="$HOME/.ssh"
    mkdir -p "$SSH_DIR"
    chmod 700 "$SSH_DIR"
    echo "$PUBKEY" > "$SSH_DIR/authorized_keys"
    chmod 600 "$SSH_DIR/authorized_keys"
    chown -R "$USERNAME:$USERNAME" "$SSH_DIR"

    # sudo
    echo "$USERNAME ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/90-$USERNAME"
    chmod 440 "/etc/sudoers.d/90-$USERNAME"

    # vim
    cp /etc/skel/.vimrc "$HOME/.vimrc" 2>/dev/null || true
    mkdir -p "$HOME/.vim/autoload/airline/themes"
    cp /etc/skel/.vim/autoload/airline/themes/custom.vim "$HOME/.vim/autoload/airline/themes/" 2>/dev/null || true
    chown -R "$USERNAME:$USERNAME" "$HOME/.vim" "$HOME/.vimrc" 2>/dev/null || true

    log "User $USERNAME ready with baked key."
  done

  # root editor theming
  cp /etc/skel/.vimrc /root/.vimrc 2>/dev/null || true
  mkdir -p /root/.vim/autoload/airline/themes
  cp /etc/skel/.vim/autoload/airline/themes/custom.vim /root/.vim/autoload/airline/themes/ 2>/dev/null || true

  log "Hardening SSH daemon config..."
  local SSHD_CONFIG="/etc/ssh/sshd_config.d/99-custom.conf"
  mkdir -p /etc/ssh/sshd_config.d

  # Build AllowUsers list from USERS array
  local ALLOW_USERS=""
  for entry in "${USERS[@]}"; do
    local U="${entry%%:*}"
    # Append to space-separated list
    ALLOW_USERS+="${U} "
  done
  # trim trailing space
  ALLOW_USERS="${ALLOW_USERS%% }"

  # Write sshd drop-in
  cat > "$SSHD_CONFIG" <<EOF
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
EOF

  # Only add AllowUsers if we have users (avoids empty directive)
  if [[ -n "$ALLOW_USERS" ]]; then
    echo "AllowUsers $ALLOW_USERS" >> "$SSHD_CONFIG"
  fi

  chmod 600 "$SSHD_CONFIG"
  systemctl restart ssh
  log "SSH hardened and restarted. AllowUsers: $ALLOW_USERS"
}

# -----------------------------------------------------------------------------
configure_dns_hosts() {
  log "Setting hostname and DNS from provided variables..."

  : "${VMNAME:?missing VMNAME}"
  : "${DOMAIN:?missing DOMAIN}"
  : "${NAMESERVER1:?missing NAMESERVER1}"
  # NAMESERVER2 optional

  IP="$(hostname -I | awk '{print $1}')"
  FQDN="${VMNAME}.${DOMAIN}"

  hostnamectl set-hostname "$FQDN"
  echo "$VMNAME" > /etc/hostname

  cat > /etc/hosts <<EOF
127.0.0.1 localhost
$IP $FQDN $VMNAME
EOF

  # ensure resolv.conf is a plain file (not a symlink from systemd-resolved)
  [ -L /etc/resolv.conf ] && rm -f /etc/resolv.conf

  {
    echo "search $DOMAIN"
    echo "nameserver $NAMESERVER1"
    [ -n "${NAMESERVER2:-}" ] && echo "nameserver $NAMESERVER2"
  } > /etc/resolv.conf

  chmod 644 /etc/resolv.conf
  chown root:root /etc/resolv.conf

  log "Hostname/DNS set: $FQDN; resolv.conf -> $(tr '\n' ' | ' < /etc/resolv.conf)"
}

# -----------------------------------------------------------------------------
sync_skel_to_existing_users() {
  log "Syncing skel configs to existing users (root + baked)..."

  for USERNAME in root ansible debian; do
    HOME_DIR=$(eval echo "~$USERNAME")
    if [ -d "$HOME_DIR" ]; then
      cp /etc/skel/.bashrc "$HOME_DIR/.bashrc"
      cp /etc/skel/.tmux.conf "$HOME_DIR/.tmux.conf"
      cp /etc/skel/.vimrc "$HOME_DIR/.vimrc"
      mkdir -p "$HOME_DIR/.vim/autoload/airline/themes"
      cp /etc/skel/.vim/autoload/airline/themes/custom.vim "$HOME_DIR/.vim/autoload/airline/themes/"
      chown -R "$USERNAME:$USERNAME" "$HOME_DIR/.bashrc" "$HOME_DIR/.tmux.conf" "$HOME_DIR/.vimrc" "$HOME_DIR/.vim"
      log "Synced skel configs for $USERNAME"
    else
      log "Skipped skel sync for $USERNAME (home not found)"
    fi
  done
}

# -----------------------------------------------------------------------------
enable_services() {
  log "Enabling cloud-init, qemu-guest-agent, ssh..."
  systemctl enable cloud-init qemu-guest-agent ssh rsyslog chrony prometheus-node-exporter
}

# -----------------------------------------------------------------------------
cleanup_identity() {
  log "Cleaning identity for template safety..."
  truncate -s 0 /etc/machine-id
  rm -f /var/lib/dbus/machine-id
  ln -s /etc/machine-id /var/lib/dbus/machine-id
  rm -f /etc/ssh/ssh_host_* || true
  dpkg-reconfigure openssh-server
}

# -----------------------------------------------------------------------------
final_cleanup() {
  log "Final cleanup..."
  apt autoremove -y
  apt clean
  rm -rf /tmp/* /var/tmp/*
  find /var/log -type f -exec truncate -s 0 {} \;
}

# -----------------------------------------------------------------------------
log "Running template setup..."

update_and_upgrade
install_base_packages
disable_ipv6
configure_cloud_init
setup_vim_config
write_bashrc
deploy_unity
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

log "Disabling bootstrap..."
systemctl disable bootstrap.service || true
rm -f /etc/systemd/system/bootstrap.service
rm -f /etc/systemd/system/multi-user.target.wants/bootstrap.service

log "Postinstall done. Shutting down..."
poweroff
EOSCRIPT

chmod +x "$DARKSITE_DIR/postinstall.sh"



log "[*] Writing bootstrap.service..."
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

log "[*] Writing finalize-template.sh..."
cat > "$DARKSITE_DIR/finalize-template.sh" <<'EOSCRIPT'
#!/bin/bash
set -Eeuo pipefail

# === Required args from environment ===
: "${PROXMOX_HOST:?Missing PROXMOX_HOST}"
: "${TEMPLATE_VMID:?Missing TEMPLATE_VMID}"
: "${NUM_CLONES:?Missing NUM_CLONES}"
: "${BASE_CLONE_VMID:?Missing BASE_CLONE_VMID}"
: "${BASE_CLONE_IP:?Missing BASE_CLONE_IP}"
: "${CLONE_MEMORY_MB:=4096}"
: "${CLONE_CORES:=4}"
: "${CLONE_VLAN_ID:?Missing CLONE_VLAN_ID}"
: "${CLONE_GATEWAY:?Missing CLONE_GATEWAY}"
: "${CLONE_NAMESERVER1:?Missing CLONE_NAMESERVER1}"
: "${VMNAME_CLEAN:?Missing VMNAME_CLEAN}"
: "${VMNAME_SHORT:?Missing VMNAME_SHORT}"
: "${DOMAIN:?Missing DOMAIN}"

# Build space-separated nameserver list for qm
NAMESERVERS="${CLONE_NAMESERVER1}${CLONE_NAMESERVER2:+ ${CLONE_NAMESERVER2}}"

echo "[*] Waiting for VM $TEMPLATE_VMID on $PROXMOX_HOST to shut down..."
SECONDS=0
TIMEOUT=900
while ssh root@"$PROXMOX_HOST" "qm status $TEMPLATE_VMID" | grep -q running; do
  if (( SECONDS > TIMEOUT )); then
    echo "[!] ERROR: Timeout waiting for VM $TEMPLATE_VMID to shut down."
    exit 1
  fi
  echo "[*] Still running... waiting 30s"
  sleep 30
done

echo "[*] Shutting down completed — converting to template..."
ssh root@"$PROXMOX_HOST" "qm template $TEMPLATE_VMID"
echo "[✓] Template finalized."

# Calculate base IP & prefix
IP_PREFIX=$(echo "$BASE_CLONE_IP" | cut -d. -f1-3)
IP_START=$(echo "$BASE_CLONE_IP" | cut -d. -f4)

for ((i=0; i<NUM_CLONES; i++)); do
  CLONE_VMID=$((BASE_CLONE_VMID + i))
  OCTET=$((IP_START + i))
  if (( OCTET > 254 )); then
    echo "[!] ERROR: Computed IP octet $OCTET exceeds /24 range for base $BASE_CLONE_IP"
    exit 1
  fi

  CLONE_IP="${IP_PREFIX}.${OCTET}"
  CLONE_INDEX=$((i+1))

  # Proxmox-visible name: short.domain-CLONE_IP-<index>
  CLONE_NAME="${VMNAME_SHORT}.${DOMAIN}-${CLONE_IP}-${CLONE_INDEX}"

  echo "[*] Cloning $CLONE_NAME (VMID: $CLONE_VMID, IP: $CLONE_IP)..."

  ssh root@"$PROXMOX_HOST" "qm clone $TEMPLATE_VMID $CLONE_VMID --name \"$CLONE_NAME\" --full true --storage local-zfs"
  ssh root@"$PROXMOX_HOST" "qm set $CLONE_VMID --delete ide3 || true"

  ssh root@"$PROXMOX_HOST" "qm set $CLONE_VMID \
    --memory $CLONE_MEMORY_MB \
    --cores $CLONE_CORES \
    --net0 virtio,bridge=vmbr0,tag=$CLONE_VLAN_ID,firewall=1 \
    --ipconfig0 ip=${CLONE_IP}/24,gw=${CLONE_GATEWAY} \
    --nameserver \"${CLONE_NAMESERVER1}${CLONE_NAMESERVER2:+ ${CLONE_NAMESERVER2}}\" \
    --agent enabled=1 \
    --ide3 local-zfs:cloudinit \
    --boot order=scsi0"

  # (optional) copy the pretty name into description, too
  ssh root@"$PROXMOX_HOST" "qm set $CLONE_VMID --description \"$CLONE_NAME\""

  ssh root@"$PROXMOX_HOST" "qm start $CLONE_VMID"
  echo "[✓] Clone ${CLONE_NAME} (VMID ${CLONE_VMID}) is running."
done
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
d-i netcfg/get_hostname string $VMNAME
d-i netcfg/get_domain string $DOMAIN
d-i netcfg/disable_dhcp boolean true
d-i netcfg/get_ipaddress string $STATIC_IP
d-i netcfg/get_netmask string $NETMASK
d-i netcfg/get_gateway string $GATEWAY
d-i netcfg/get_nameservers string $NAMESERVERS_LIST

# Mirrors
d-i mirror/country string manual
d-i mirror/http/hostname string deb.debian.org
d-i mirror/http/directory string /debian
d-i mirror/http/proxy string

# Comment this out to enable mirrors on NetInst
#d-i mirror/no_mirror boolean true

# APT sections
# disable mirror and use postinstall.sh
#d-i apt-setup/use_mirror boolean true
d-i apt-setup/use_mirror boolean false
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
  mkdir -p /target/root/darksite ; \
  cp -a /cdrom/darksite/* /target/root/darksite/ ; \
  in-target chmod +x /root/darksite/postinstall.sh ; \
  in-target cp /root/darksite/bootstrap.service /etc/systemd/system/bootstrap.service ; \
  in-target test -f /etc/systemd/system/bootstrap.service ; \
  in-target systemctl daemon-reload ; \
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
  menu label ^base
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

# === Upload to Proxmox ===
log "[*] Uploading ISO to Proxmox host $PROXMOX_HOST..."
scp "$FINAL_ISO" root@"$PROXMOX_HOST":/var/lib/vz/template/iso/

FINAL_ISO_BASENAME=$(basename "$FINAL_ISO")

log "[*] Creating VM $VMID on Proxmox host $PROXMOX_HOST..."
ssh root@"$PROXMOX_HOST" bash <<EOSSH
set -euxo pipefail

VMID=$VMID
VLANID=$VLANID
VMNAME="$PROXMOX_VMNAME"
FINAL_ISO="$FINAL_ISO_BASENAME"

# Destroy VM if it exists
qm destroy \$VMID --purge || true

# Create the VM
qm create \$VMID \\
  --name "\$VMNAME" \\
  --memory 4096 \\
  --cores 4 \\
  --net0 virtio,bridge=vmbr0,tag=\$VLANID,firewall=1 \\
  --ide2 local:iso/\$FINAL_ISO,media=cdrom \\
  --efidisk0 local-zfs:0,efitype=4m,pre-enrolled-keys=0 \\
  --scsihw virtio-scsi-single \\
  --scsi0 local-zfs:32 \\
  --boot order=ide2 \\
  --serial0 socket \\
  --ostype l26 \\
  --agent enabled=1

qm start \$VMID
EOSSH

# === Wait for VM to finish Preseed (first shutdown) ===
log "[*] Waiting for VM $VMID to power off after installer preseed phase..."

SECONDS=0
TIMEOUT=900

while ssh root@"$PROXMOX_HOST" "qm status $VMID" | grep -q running; do
  if (( SECONDS > TIMEOUT )); then
    log "[!] ERROR: Timeout waiting for VM $VMID to shutdown after installer."
    exit 1
  fi
  sleep 30
done

log "[*] VM $VMID has powered off after installer. Preparing for postinstall bootstrap..."

# === Detach ISO and set boot order ===
ssh root@"$PROXMOX_HOST" bash <<EOSSH
set -euxo pipefail

qm set $VMID --delete ide2
qm set $VMID --boot order=scsi0
qm set $VMID --ide3 local-zfs:cloudinit
qm set $VMID --description "$VMNAME-vlan$VLANID"

qm start $VMID
EOSSH

# === Wait for VM to shut down again after postinstall.sh ===
log "[*] Waiting for VM $VMID to power off after postinstall.sh execution..."

SECONDS=0
TIMEOUT=900

while ssh root@"$PROXMOX_HOST" "qm status $VMID" | grep -q running; do
  if (( SECONDS > TIMEOUT )); then
    log "[!] ERROR: Timeout waiting for VM $VMID to shutdown after postinstall.sh."
    exit 1
  fi
  sleep 30
done

log "[✓] VM $VMID has powered off after postinstall.sh. Finalizing as template and cloning first instance..."

# === Finalize Template & Clone Loop ===
IP_PREFIX=$(echo "$BASE_CLONE_IP" | cut -d. -f1-3)
IP_START=$(echo "$BASE_CLONE_IP" | cut -d. -f4)

export PROXMOX_HOST
export TEMPLATE_VMID="$VMID"
export CLONE_MEMORY_MB
export CLONE_CORES
export CLONE_VLAN_ID="$VLANID"
export CLONE_GATEWAY="$GATEWAY"
export CLONE_NAMESERVER1="$NAMESERVER1"
export CLONE_NAMESERVER2="${NAMESERVER2:-}"
export VMNAME_CLEAN="$VMNAME"
export VMNAME_SHORT
export DOMAIN
export NUM_CLONES
export BASE_CLONE_VMID
export BASE_CLONE_IP

bash "$DARKSITE_DIR/finalize-template.sh"
