#!/bin/bash
set -euo pipefail

# Load environment variables and utility functions
source "/root/base/lib/env.sh"  # To load environment variables
source "/root/base/lib/utils.sh"  # To load logging and error handling utilities

# Add timestamp to logs
LOG_FILE="debug.txt"
BUILD_DIR="/root/build/"  # Fixed: Closing quote added here
exec &> >(tee -a "$LOG_FILE")

# Function to log and display messages
log() {
  echo "[INFO] $(date '+%Y-%m-%d %H:%M:%S')]: $1"
}

# Function to log errors and terminate
error_log() {
  echo "[ERROR] $(date '+%Y-%m-%d %H:%M:%S')]: $1" >&2
  exit 1
}

log "[INFO] 2025-05-01 21:20:00]: Starting debug script to display all files."

# Display the structure of /root/base and related directories
log "[INFO] Displaying the directory structure of /root/base"
tree /root/base

log "[INFO] Displaying contents of /root/darksite directory"
tree /root/darksite-repo

log "[INFO] Displaying the build directory structure"
tree "$BUILD_DIR"

# ---- SSH and SCP steps ----

# SSH copy-id: Ensure the SSH key is copied to the remote machine
log "[INFO] Copying SSH key to remote server"
ssh-copy-id todd@10.100.10.150 || error_log "[ERROR] SSH key copy failed"

log "[INFO] SSH key copied successfully. Now attempting to SCP the debug file."

# SCP the debug.txt file to the remote server
log "[INFO] Copying debug.txt to remote server..."
scp debug.txt todd@10.100.10.150:/home/todd/Downloads/ || error_log "[ERROR] SCP failed to transfer the file."

log "[INFO] Debug file transferred successfully."

# ---- File check and verification ----

log "[INFO] Checking if required files exist in darksite and build directories"

# Verify the existence of files used by the build in directories
FILES_TO_CHECK=(
  "$DARKSITE_DIR/postinstall.sh"
  "$DARKSITE_DIR/bootstrap.service"
  "$DARKSITE_DIR/finalize-template.sh"
  "$CUSTOM_DIR/preseed.cfg"
  "$FINAL_ISO"
  "$OUTPUT_ISO"
  "$BUILD_DIR/darksite-custom.iso"
)

for file in "${FILES_TO_CHECK[@]}"; do
  if [ -f "$file" ]; then
    log "[INFO] File $file exists."
  else
    error_log "[ERROR] File $file does NOT exist."
  fi
done

# ---- Trace files added/modified during the process ----

log "[INFO] Tracing all files added or modified in /root/darksite and /root/base"

# Use find to list all files in the build and darksite directories
find "$BUILD_DIR" -type f -exec echo "[INFO] File in build dir: {}" \;
find "$DARKSITE_DIR" -type f -exec echo "[INFO] File in darksite dir: {}" \;

log "[INFO] Debugging script finished. Check debug.txt for detailed logs."
