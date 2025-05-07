#!/bin/bash

# =============================================================================
# Proxmox VM Clone Script with Interactive Mode & Extended Help
# =============================================================================
# Supports both automated CLI usage and interactive prompts for manual use.
# Full clone + optional static IP + multiple ZFS volumes.
# =============================================================================

set -euo pipefail
LOG_FILE="/var/log/proxmox_batch_clone.log"
exec > >(tee -a "$LOG_FILE") 2>&1

log() { echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*"; }
error_exit() { log "ERROR: $1"; exit 1; }
trap 'error_exit "Script encountered an error."' ERR

usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  -t, --template <template-id>         Template VM ID to clone from"
    echo "  -c, --clone-count <number>          Number of clones to create"
    echo "  -s, --start-id <id>                 Starting VM ID"
    echo "  -n, --base-name <name>              Base name for cloned VMs"
    echo "  -r, --root-storage <pool>           Storage for root disk (default: local-zfs)"
    echo "  -e, --extra-storage <pool>          Storage for extra volumes (default: tiger)"
    echo "  -m, --memory <GB>                   Memory size in GB (default: 4)"
    echo "  -p, --cpu <cores>                   Number of CPU cores (default: 2)"
    echo "  -i, --ip <ip>                       Starting IP for static config"
    echo "  -g, --gateway <ip>                  Gateway for static config"
    echo "  -v, --zfs-volumes <number>          Extra ZFS volumes to attach (default: 0)"
    echo "  -z, --zfs-size <size>               Size of each ZFS volume (e.g. 20G)"
    echo "  -h, --help                          Show help"
    echo ""
    echo "Examples:"
    echo "  $0 -t 100 -c 3 -s 200 -n dev -m 8 -p 4"
    echo "  $0 -t 900 -c 2 -s 300 -n web -i 192.168.1.100 -g 192.168.1.1"
    echo "  $0 -t 800 -c 1 -s 150 -n build -v 2 -z 50G -e fastpool"
    echo "  $0 -t 500 -c 5 -s 100 -n testvm -r local-zfs -e backup"
    echo "  $0 -t 777 -c 4 -s 400 -n node -m 16 -p 8 -v 1 -z 20G"
    echo "  $0 -t 999 -c 1 -s 999 -n ci -i 10.0.0.50 -g 10.0.0.1 -v 3 -z 30G"
    exit 0
}

# --- Set Default Values ---
TEMPLATE_ID=""
CLONE_COUNT=1
START_ID=10000
BASE_NAME="clone"
ROOT_STORAGE="local-zfs"
STORAGE="local-zfs"
MEMORY_GB=4
CPU_CORES=2
BASE_IP=""
GATEWAY_IP="10.1.0.2"
ZFS_VOLUMES=0
ZFS_SIZE="20G"

# --- Interactive Mode if No Arguments ---
if [[ $# -eq 0 ]]; then
    echo "Interactive Mode Activated:"
    read -rp "Template VM ID: " input && TEMPLATE_ID="$input"
    [[ -z "$TEMPLATE_ID" ]] && error_exit "Template ID is required."

    read -rp "Number of clones [${CLONE_COUNT}]: " input && CLONE_COUNT="${input:-$CLONE_COUNT}"
    read -rp "Starting VM ID [${START_ID}]: " input && START_ID="${input:-$START_ID}"
    read -rp "Base name for VMs [${BASE_NAME}]: " input && BASE_NAME="${input:-$BASE_NAME}"
    read -rp "Root storage pool [${ROOT_STORAGE}]: " input && ROOT_STORAGE="${input:-$ROOT_STORAGE}"
    read -rp "Extra storage pool [${STORAGE}]: " input && STORAGE="${input:-$STORAGE}"
    read -rp "Memory in GB [${MEMORY_GB}]: " input && MEMORY_GB="${input:-$MEMORY_GB}"
    read -rp "CPU cores [${CPU_CORES}]: " input && CPU_CORES="${input:-$CPU_CORES}"
    read -rp "Starting IP (leave blank for DHCP): " BASE_IP
    read -rp "Gateway IP (required if static IP set): " GATEWAY_IP
    read -rp "ZFS volumes to attach [${ZFS_VOLUMES}]: " input && ZFS_VOLUMES="${input:-$ZFS_VOLUMES}"
    read -rp "ZFS volume size [${ZFS_SIZE}]: " input && ZFS_SIZE="${input:-$ZFS_SIZE}"
fi

# --- Parse Command Line Arguments (CLI mode) ---
while [[ $# -gt 0 ]]; do
    case "$1" in
        -t|--template) TEMPLATE_ID="$2"; shift 2 ;;
        -c|--clone-count) CLONE_COUNT="$2"; shift 2 ;;
        -s|--start-id) START_ID="$2"; shift 2 ;;
        -n|--base-name) BASE_NAME="$2"; shift 2 ;;
        -r|--root-storage) ROOT_STORAGE="$2"; shift 2 ;;
        -e|--extra-storage) STORAGE="$2"; shift 2 ;;
        -m|--memory) MEMORY_GB="$2"; shift 2 ;;
        -p|--cpu) CPU_CORES="$2"; shift 2 ;;
        -i|--ip) BASE_IP="$2"; shift 2 ;;
        -g|--gateway) GATEWAY_IP="$2"; shift 2 ;;
        -v|--zfs-volumes) ZFS_VOLUMES="$2"; shift 2 ;;
        -z|--zfs-size) ZFS_SIZE="$2"; shift 2 ;;
        -h|--help) usage ;;
        *) error_exit "Invalid option: $1" ;;
    esac
done

# --- Validate Required Inputs ---
if [[ -z "$TEMPLATE_ID" ]]; then
    error_exit "Template ID is required. Use -t or --template."
fi

# --- Validate Template ID Exists ---
if ! qm list | awk '{print $1}' | grep -q "^$TEMPLATE_ID$"; then
    error_exit "Template ID $TEMPLATE_ID does not exist."
fi

# --- Convert to Template If Needed ---
if ! qm config "$TEMPLATE_ID" | grep -q "^template: 1"; then
    log "[WARNING] VM $TEMPLATE_ID is not a template."
    read -p "Convert it to a template now? (y/N): " CONFIRM
    if [[ "$CONFIRM" =~ ^[Yy]$ ]]; then
        qm template "$TEMPLATE_ID"
        log "[INFO] Converted VM $TEMPLATE_ID to a template."
    else
        error_exit "Select a valid template to continue."
    fi
fi

# --- Begin Cloning Loop ---
CURRENT_ID="$START_ID"
for ((i=1; i<=CLONE_COUNT; i++)); do
    VM_NAME="${BASE_NAME}$(printf '%02d' "$i")"

    log "[*] Cloning $TEMPLATE_ID ➔ $CURRENT_ID ($VM_NAME)..."
    qm clone "$TEMPLATE_ID" "$CURRENT_ID" --name "$VM_NAME" --storage "$ROOT_STORAGE" --full true
    qm set "$CURRENT_ID" --memory "$((MEMORY_GB * 1024))" --cores "$CPU_CORES"

    if [[ -n "$BASE_IP" ]]; then
        IFS='.' read -r i1 i2 i3 i4 <<< "$BASE_IP"
        IP_LAST=$((i4 + i - 1))
        CLONE_IP="$i1.$i2.$i3.$IP_LAST"
        log "[*] Setting static IP $CLONE_IP with gateway $GATEWAY_IP"
        qm set "$CURRENT_ID" --ipconfig0 ip="${CLONE_IP}/24,gw=${GATEWAY_IP}"
    else
        log "[*] Leaving VM networking as DHCP."
    fi

    for ((j=1; j<=ZFS_VOLUMES; j++)); do
        VOLUME_NAME="vm-${CURRENT_ID}-disk-${j}"
        log "[*] Creating ZFS volume $STORAGE/$VOLUME_NAME of size $ZFS_SIZE..."
        zfs create -V "$ZFS_SIZE" "$STORAGE/$VOLUME_NAME"
        log "[*] Attaching volume $VOLUME_NAME to VM $CURRENT_ID..."
        qm set "$CURRENT_ID" -scsi"$j" "$STORAGE:$VOLUME_NAME"
    done

    log "[*] Starting VM $CURRENT_ID ($VM_NAME)..."
    qm start "$CURRENT_ID"
    CURRENT_ID=$((CURRENT_ID + 1))
done

log "[SUCCESS] All $CLONE_COUNT clone(s) created successfully."
