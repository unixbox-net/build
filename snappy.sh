#!/bin/bash

# =============================================================================
# Proxmox Snapshot Manager (Snapshot, Revert, Delete)
# =============================================================================
# Supports:
#   - Snapshot creation with timestamp or custom name
#   - Snapshot deletion
#   - Snapshot revert
#   - Interactive mode if no args
# =============================================================================

set -euo pipefail
LOG_FILE="/var/log/proxmox_snapshot.log"
exec > >(tee -a "$LOG_FILE") 2>&1

log()        { echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*"; }
error_exit() { log "ERROR: $1"; exit 1; }
trap 'error_exit "Script failed unexpectedly."' ERR

# Colors for usage
if [[ -t 1 ]]; then
    BOLD=$(tput bold)
    NORMAL=$(tput sgr0)
    BLUE=$(tput setaf 4)
    GREEN=$(tput setaf 2)
else
    BOLD=""; NORMAL=""; BLUE=""; GREEN=""
fi

# --- Help Menu ---
usage() {
    echo -e "${BOLD}${BLUE}Proxmox Snapshot Script${NORMAL}"
    echo -e "${BOLD}Usage:${NORMAL} $0 [OPTIONS]"
    echo ""
    echo -e "${BOLD}Options:${NORMAL}"
    printf "  %-28s %s\n" "-v, --vm <id>"          "VM ID to target (required)"
    printf "  %-28s %s\n" "-a, --action <op>"     "Action: snapshot | delete | revert"
    printf "  %-28s %s\n" "-n, --name <name>"      "Snapshot name (optional for create)"
    printf "  %-28s %s\n" "-h, --help"             "Show this help message"
    echo ""
    echo -e "${BOLD}Examples:${NORMAL}"
    printf "  %-40s %s\n" "$0 -v 101 -a snapshot" "Create a snapshot with timestamp"
    printf "  %-40s %s\n" "$0 -v 101 -a snapshot -n pre-upgrade" "Named snapshot"
    printf "  %-40s %s\n" "$0 -v 101 -a revert -n pre-upgrade" "Revert to a snapshot"
    printf "  %-40s %s\n" "$0 -v 101 -a delete -n old-snap" "Delete a snapshot"
    exit 0
}

# --- Defaults ---
VM_ID=""
ACTION=""
SNAP_NAME=""

# --- Interactive Prompt ---
if [[ $# -eq 0 ]]; then
    echo -e "\n${BOLD}${GREEN}Interactive Mode Activated${NORMAL}"
    read -rp "VM ID: " VM_ID
    read -rp "Action (snapshot/delete/revert): " ACTION
    read -rp "Snapshot name (leave blank to auto-generate): " SNAP_NAME
fi

# --- Argument Parsing ---
while [[ $# -gt 0 ]]; do
    case "$1" in
        -v|--vm) VM_ID="$2"; shift 2 ;;
        -a|--action) ACTION="$2"; shift 2 ;;
        -n|--name) SNAP_NAME="$2"; shift 2 ;;
        -h|--help) usage ;;
        *) error_exit "Unknown option: $1" ;;
    esac
done

# --- Input Validation ---
[[ -z "$VM_ID" ]] && error_exit "VM ID is required. Use -v or --vm."
[[ -z "$ACTION" ]] && error_exit "Action is required. Use -a or --action."

if ! qm list | awk '{print $1}' | grep -q "^$VM_ID$"; then
    error_exit "VM ID $VM_ID does not exist."
fi

# --- Actions ---
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

case "$ACTION" in
    snapshot)
        NAME="${SNAP_NAME:-snap_$TIMESTAMP}"
        log "[*] Creating snapshot '$NAME' for VM $VM_ID..."
        qm snapshot "$VM_ID" "$NAME" --description "Snapshot created on $TIMESTAMP"
        log "[+] Snapshot '$NAME' created successfully."
        ;;
    revert)
        [[ -z "$SNAP_NAME" ]] && error_exit "Snapshot name required for revert."
        log "[*] Reverting VM $VM_ID to snapshot '$SNAP_NAME'..."
        qm rollback "$VM_ID" "$SNAP_NAME"
        log "[+] VM $VM_ID reverted to snapshot '$SNAP_NAME'."
        ;;
    delete)
        [[ -z "$SNAP_NAME" ]] && error_exit "Snapshot name required for deletion."
        log "[*] Deleting snapshot '$SNAP_NAME' from VM $VM_ID..."
        qm delsnapshot "$VM_ID" "$SNAP_NAME"
        log "[+] Snapshot '$SNAP_NAME' deleted."
        ;;
    *)
        error_exit "Invalid action '$ACTION'. Use snapshot, revert, or delete."
        ;;
esac
