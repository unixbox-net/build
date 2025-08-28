# Proxmox ISO Builder and Deployment Tool

This project provides a **fully automated ISO builder and deployment pipeline** for creating custom Debian-based Proxmox VM templates.  
It automates **repacking ISOs, embedding darksite packages/configs, bootstrapping VMs, finalizing templates, and mass cloning** across Proxmox clusters.

The result: **press a button and get instantly available, production-ready VMs or templates** — anywhere, on Proxmox clusters, bare metal, or even PXE-booted hardware.

---

## Features

- **ISO repacking and darksite builds**
  - Starts from a stock Debian 12/13 netinst ISO.
  - Rebuilds it with preseed + embedded darksite directory containing:
    - All required `.deb` packages.
    - Custom scripts, configs, and post-install logic.
  - Produces a self-contained ISO that supports unattended offline installs (no mirrors needed).

- **Automated VM lifecycle in Proxmox**
  - Uploads the rebuilt ISO to your Proxmox cluster.
  - Creates and installs a VM from ISO with `preseed.cfg`.
  - Boots once, runs full unattended `postinstall.sh`, then shuts down.
  - Cleans machine identity (machine-id, SSH host keys) for safe templating.

- **Bootstrap and post-install automation**
  - Configures users, baked SSH keys, sudo rules, `.bashrc`, `tmux.conf`, and Vim configs.
  - Installs common system utilities, monitoring tools, and `cloud-init`.
  - Configures UFW firewall with hardened defaults.
  - Prepares Promtail (Loki shipper) for logging.
  - Sets hostnames, DNS, and Proxmox guest agent.
  - Optionally disables IPv6.
  - Final cleanup: autoremove packages, scrub logs, reset identity.

- **Template finalization and cloning**
  - Converts the VM to a **Proxmox template** automatically.
  - Uses `finalize-template.sh` to:
    - Mark VM as a template.
    - Clone N instances instantly.
    - Configure VMID, memory, cores, VLAN tags, and static IPs.
  - Clones can be created across multiple hosts/zones in parallel (tmux-friendly).

- **Scales everywhere**
  - Works with Proxmox storage backends (ZFS, UFS, Ceph).
  - ISO can be used with **PXE boot**, bare metal, or cloud providers.
  - Deploy **hundreds or thousands of nodes** consistently.

---

## Requirements

- **Proxmox cluster** with SSH access and `qm` CLI.
- **Debian base ISO** (e.g., `debian-12.10.0-amd64-netinst.iso`).
- Host with `bash`, `xorriso`, and privileges to upload ISOs to Proxmox.

---

## Build Process Overview

1. **Prepare build environment**
   - Mount stock Debian ISO.
   - Copy ISO contents to working dir.
   - Inject custom `preseed.cfg`, `darksite/` directory, and scripts.

2. **Darksite injection**
   - Packages, configs, and scripts are added under `/darksite`.
   - Enables unattended offline installation — ideal for air-gapped or restricted networks.

3. **Preseed and bootstrap**
   - Automated partitioning, user setup, and package installs.
   - At first boot:
     - Runs `postinstall.sh` via a one-time `bootstrap.service`.
     - Configures system defaults (users, SSH, firewall, logs, monitoring).
     - Cleans and powers off.

4. **ISO rebuild**
   - Creates a bootable hybrid ISO using `xorriso`.
   - Uploads to Proxmox (`/var/lib/vz/template/iso/`).

5. **VM creation**
   - Installs a VM from ISO with defined VMID, VLANID, and static IP.
   - Waits for auto shutdown.

6. **Template finalization**
   - Marks VM as a template.
   - Runs `finalize-template.sh` to generate clones.

7. **Clone deployment**
   - Spits out as many clones as required.
   - Multi-zone/multi-host supported (parallel with tmux).

---

## Example Workflow

```bash
# Build ISO and deploy VM/template on Proxmox host 5
./build-iso.sh

# After VM powers down, finalize and clone
/root/darksite/finalize-template.sh <PROXMOX_HOST> <TEMPLATE_VMID> <CLONE_VMID> <CLONE_IP>
