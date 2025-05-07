#!/bin/bash
# MODULE 5: Re-Pack+darksite makes it zoom zoom!
set -euo pipefail
source "/root/base/lib/env.sh"

log "[*] [Module 5] Rebuilding ISO..."

: "${BUILD_DIR:=/root/debian-iso}"
: "${CUSTOM_DIR:=$BUILD_DIR/custom}"
: "${OUTPUT_ISO:=$BUILD_DIR/darksite-custom.iso}"
: "${FINAL_ISO:=/root/final-darksite.iso}"

TXT_CFG="$CUSTOM_DIR/isolinux/txt.cfg"
ISOLINUX_CFG="$CUSTOM_DIR/isolinux/isolinux.cfg"

# Update isolinux with darksite autoinstall
cat >> "$TXT_CFG" <<EOF
label auto
  menu label ^Automated Darksite Install
  kernel /install.amd/vmlinuz
  append auto=true priority=critical vga=788 initrd=/install.amd/initrd.gz preseed/file=/cdrom/preseed.cfg ---
EOF

sed -i 's/^default .*/default auto/' "$ISOLINUX_CFG"

# Build ISO
xorriso -as mkisofs \
  -o "$OUTPUT_ISO" \
  -r -J -joliet-long -l \
  -b isolinux/isolinux.bin \
  -c isolinux/boot.cat \
  -no-emul-boot -boot-load-size 4 -boot-info-table \
  -isohybrid-mbr /usr/lib/ISOLINUX/isohdpfx.bin \
  -eltorito-alt-boot \
  -e boot/grub/efi.img \
  -no-emul-boot -isohybrid-gpt-basdat "$CUSTOM_DIR"

mv "$OUTPUT_ISO" "$FINAL_ISO"
log "[✓] ISO ready at $FINAL_ISO"
