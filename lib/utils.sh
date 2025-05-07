#!/bin/bash
# Shared utilities for logging and error handling

log() {
  echo "[INFO] $(date '+%Y-%m-%d %H:%M:%S')]: $*"
}

error_exit() {
  echo "[ERROR] $(date '+%Y-%m-%d %H:%M:%S')]: $*" >&2
  exit 1
}
