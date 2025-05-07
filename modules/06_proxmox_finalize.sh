#!/bin/bash
# MODULE 6: Upload ISO to Proxmox and finalize template build
set -euo pipefail
source "/root/base/lib/env.sh"

log "[*] Uploading ISO to Proxmox..."
scp "$FINAL_ISO" root@"$PROXMOX_HOST":/var/lib/vz/template/iso/
FINAL_ISO_BASENAME=$(basename "$FINAL_ISO")

log "[*] Creating and starting Proxmox VM..."
ssh root@"$PROXMOX_HOST" bash <<EOSSH
set -euxo pipefail

# Cleanup if exists
qm destroy $VMID --purge || true

# Create new VM
qm create $VMID \
  --name unity-template \
  --memory 4096 \
  --cores 4 \
  --net0 virtio,bridge=vmbr1 \
  --ide2 local:iso/$FINAL_ISO_BASENAME,media=cdrom \
  --efidisk0 local-zfs:0,efitype=4m \
  --scsihw virtio-scsi-single \
  --scsi0 local-zfs:32 \
  --boot order=ide2 \
  --serial0 socket \
  --ostype l26 \
  --agent enabled=1

# Boot installer
qm start $VMID

# Wait for shutdown (installer complete)
SECONDS=0
TIMEOUT=900
while qm status $VMID | grep -q running; do
  (( SECONDS > TIMEOUT )) && exit 1
  sleep 30
done

echo "[✓] VM $VMID powered off after install"

# Cloud-init prep
qm set $VMID --delete ide2
qm set $VMID --boot order=scsi0
qm set $VMID --ide3 local-zfs:cloudinit
qm set $VMID --description "BCC Template - Cloud-init Phase"
qm start $VMID
EOSSH

# Now trigger finalize script
log "[*] Running finalize-template.sh after second VM shutdown..."
bash "$DARKSITE_DIR/finalize-template.sh" "$VMID"
