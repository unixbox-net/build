#!/bin/bash
# MODULE 1: Prepare ISO structure and mount base image
set -euo pipefail
source "/root/base/lib/env.sh"


log "[*] [Module 1] Preparing ISO and darksite directories..."
ISO_ORIG="/root/debian-12.10.0-amd64-netinst.iso"
BUILD_DIR="/root/debian-iso"
CUSTOM_DIR="$BUILD_DIR/custom"
MOUNT_DIR="/mnt/iso"
DARKSITE_DIR="$CUSTOM_DIR/darksite"

umount "$MOUNT_DIR" 2>/dev/null || true
rm -rf "$BUILD_DIR"
mkdir -p "$CUSTOM_DIR" "$MOUNT_DIR" "$DARKSITE_DIR"

mount -o loop "$ISO_ORIG" "$MOUNT_DIR"
rsync -aHAX "$MOUNT_DIR/" "$CUSTOM_DIR/"
umount "$MOUNT_DIR"
