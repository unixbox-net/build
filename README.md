# Proxmox ISO Builder and Deployment Tool

This project provides a **fully automated ISO builder and deployment pipeline** for creating custom Debian-based Proxmox VM templates.  
It automates **repacking ISOs, embedding darksite packages/configs, bootstrapping VMs, finalizing templates, and mass cloning** across Proxmox clusters.

The result: **press a button and get instantly available, production-ready VMs or templates** — anywhere, on Proxmox clusters, bare metal, or even PXE-booted hardware.

---

## Table of Contents

1. [Features](#features)  
2. [Requirements](#requirements)  
3. [Build Process Overview](#build-process-overview)  
4. [Example Workflow](#example-workflow)  
5. [Key Benefits](#key-benefits)  
6. [Advanced Options](#advanced-options)  
7. [Super Advanced Options](#super-advanced-options)  
   - [Zero Trust Builds](#zero-trust-builds)  
   - [Self-Deploying Workstations](#self-deploying-workstations)  
   - [Ephemeral Infrastructure](#ephemeral-infrastructure)  
   - [Near Unlimited Boot Options](#near-unlimited-boot-options)  
   - [Architecture-Agnostic Targets](#architecture-agnostic-targets)  
   - [Cluster Assimilation (Ceph / Storage Expansion)](#cluster-assimilation-ceph--storage-expansion)  
   - [In Practice](#in-practice)  

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
```

- VM boots → unattended Debian install → runs postinstall.sh → powers off.
- Script marks it as a template and creates first clone automatically.
- Clones are immediately usable with baked configs and SSH keys.

## Key Benefits

- No manual template building: ISO + script does everything automatically.
- Air-gapped ready: Packages baked into ISO (no mirrors).
- PXE deployable: ISO can boot bare metal and auto-configure.
- Works on any release archecture such as arm/amd and qemu/kvm based hypervisor (such as proxmox/bhyve)
- Cluster-wide scaling: Deploys across Proxmox nodes with ZFS, UFS, or Ceph storage.
- Able include addiitonal hardware such as virtual hard disks, network cards etc.
- Operator-friendly: Logs everything, hardened configs, clean templates.
- Mass deployment: Instantly clone hundreds/thousands of instances.
- Ideal to move from traditional linux "pets" to "cattle" simply destory and replace in seconds.
- Ensured consistencty, version control and reliability across any number of sites.

- **CI/CD Friendly (No Git Required)**
  - Works with **any existing CI/CD pipeline** — Jenkins, GitLab, GitHub Actions, Semaphore, etc.
  - Simply **divert or copy your build artifacts** into the ISO’s `darksite/` directory and install durring pressed, or post install via postinstall.sh
  - On deployment, those artifacts are **installed, configured, and running** automatically.
  - No need to clone repos or run git commands on the target — making it ideal for **air-gapped, darksite, or zero-trust environments**.



## Advanced Options

- Multiple boot processes supported (systemd services, rc.d).
- Flexible post-install: bake extra configs, monitoring agents, or business logic.
- Extendable: add your own packages/scripts into /root/build/scripts.
- Deliver ANY serivce in a VM wrapper that is fully configured and ready to go.
- "baked" infrastucutre built from scratch using true Zero Trust OS's built from literally nothing.

## Super Advanced Options

This system is not limited to “just making templates.”  
By extending the build and post-install logic, deployments can be tailored into **zero-trust, user-ready operating systems** that are preconfigured down to the individual user level.

### Examples

- **Zero Trust Builds**
  - Deploy operating systems that come pre-baked with hardened defaults (firewall, SSH, identity scrubbing).
  - Inject **per-user policies, credentials, and configs** so that even desktop apps (e.g., Evolution Mail) can be prebaked with accounts, ready to sync a mailbox *before the first login*.

- **Self-Deploying Workstations**
  - VM images can ship with **RDP/VNC baked in** — upload them to any hypervisor and they appear instantly accessible, with no manual steps.
  - Supports “desktop anywhere” deployments.

- **Ephemeral Infrastructure**
  - Combine with a simple `cron` job to **deploy and tear down fleets of VMs automatically**.
  - Scale environments up and down on-demand (lab, CI/CD, load test, or burst workloads).

- **Near Unlimited Boot Options**
  - Bake in **ZFS and Boot Environments** to:
    - Roll out workloads onto ZFS-backed hosts.
    - Snapshot and rollback entire systems instantly.
    - Test, patch, or replace systems without risk.

- **Architecture-Agnostic Targets**
  - Any system with a BIOS/UEFI can be a target: x86, ARM, or beyond.
  - Write the ISO to a USB stick → boot it in a laptop, server, ARM SBC, or even unconventional hardware.
  - The same process works from **Proxmox clusters → PXE boot → bare metal → embedded devices**.

- **Cluster (Ceph / Proxmox) Expansion**
  - New nodes can be deployed with all required configs baked in to **auto-join an existing Proxmox cluster** at first boot.
  - The deployment process can automatically **consume local disks** and extend the existing **Ceph storage pool** without manual intervention.
  - Effectively, new hardware (or VMs with attached disks) can be **“assimilated” into the cluster** — expanding compute and storage at the same time.
  - No keyboard input, no git commands, no manual steps. Just burn → boot → and watch the cluster grow itself.

### In Practice

- Ship a **zero-trust workstation image** to your Proxmox cluster.
- Auto-deploy it with **per-user credentials baked in**.
- Let it provision, pull configs, and phone home securely before first login.
- Rollback, rebuild, or redeploy at will — at **cluster scale or on commodity hardware**.

This makes the system not only a **template factory**, but a **universal deployment engine**.
