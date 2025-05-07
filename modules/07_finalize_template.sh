#!/bin/bash
# MODULE 7: Timer / Hold-Music as needed
set -euo pipefail
source "/root/base/lib/env.sh"

VMID="${1:-}"
[[ -z "$VMID" ]] && error_exit "Missing VMID"

log "[*] Waiting for VM $VMID to shut down after cloud-init..."

SECONDS=0
TIMEOUT=900

while ssh root@"$PROXMOX_HOST" "qm status $VMID" | grep -q running; do
  (( SECONDS > TIMEOUT )) && error_exit "[✗] Timeout waiting for VM to shut down"
  sleep 30
done

log "[*] VM $VMID has shut down after cloud-init. Marking as template..."
ssh root@"$PROXMOX_HOST" "qm template $VMID"
log "[✓] VM $VMID finalized as a Proxmox template."
