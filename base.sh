#!/bin/bash
#
# no touch template creation tool for proxmox
# + clone.sh - point+shoot interactive or full auto.. be careful!
# + snappy.sh - taget (snapshot | delete | revert) ontap
# + Rest Collection - Fully event driven
# + pfsences (yes please!)
#
# dead simple: ./base.sh 1000
# du-nn!
# currently limited to a single host.

set -euo pipefail
source "/root/base/lib/env.sh"
source "/root/base/lib/utils.sh"

# === Globals ===
MODULE_DIR="/root/base/modules"
VMID="${1:-}"

# === Early sanity checks ===
[[ -z "$VMID" ]] && error_exit "Usage: $0 <VMID>"
[[ $(id -u) -ne 0 ]] && error_exit "This script must be run as root."
command -v xorriso >/dev/null || error_exit "Missing xorriso. Run: apt install xorriso"
command -v jq >/dev/null || error_exit "Missing jq. Run: apt install jq"
[[ ! -f /root/debian-12.10.0-amd64-netinst.iso ]] && error_exit "Base ISO missing."

# === Load all modules as defined in manifest ===
source "/root/base/load_modules.sh"

log "[✓] All tasks completed successfully."
