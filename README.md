# BezaForge Infrastructure Platform

Production-grade private cloud managed entirely as code. VM provisioning via Terraform, configuration management via Ansible, 15+ containerized services via Docker Compose, full observability stack, automated wildcard TLS, and GPU-accelerated LLM inference — all on bare-metal hardware at home.

![Terraform](https://img.shields.io/badge/Terraform-7B42BC?style=flat&logo=terraform&logoColor=white)
![Ansible](https://img.shields.io/badge/Ansible-EE0000?style=flat&logo=ansible&logoColor=white)
![Proxmox](https://img.shields.io/badge/Proxmox-E57000?style=flat&logo=proxmox&logoColor=white)
![Docker](https://img.shields.io/badge/Docker-2496ED?style=flat&logo=docker&logoColor=white)
![Prometheus](https://img.shields.io/badge/Prometheus-E6522C?style=flat&logo=prometheus&logoColor=white)
![Grafana](https://img.shields.io/badge/Grafana-F46800?style=flat&logo=grafana&logoColor=white)
![Linux](https://img.shields.io/badge/Linux-FCC624?style=flat&logo=linux&logoColor=black)

---

## Architecture Overview

| Host | Role | Hardware | OS |
|------|------|----------|----|
| **forge-hypervisor** | Proxmox hypervisor | Ryzen 7 5800X, 48GB RAM, RX 7900 XT, ZFS mirror | Proxmox VE 9.1 |
| **forge-ops** | Docker service host | i9-12900H, 32GB DDR5 | Debian 13.3 |
| **forge-ai** | GPU LLM inference | RX 7900 XT passthrough, ROCm | Ubuntu 26.04 |
| **forge-erp** | ERP (ERPNext v16) | 2 vCPU, 8GB RAM (4GB balloon floor) | Ubuntu 26.04 |

---

## Infrastructure as Code

All VMs are declaratively defined and managed via Terraform using the [bpg/proxmox](https://registry.terraform.io/providers/bpg/proxmox/latest) provider.

### Module Design

A reusable `proxmox-vm` module (`terraform/modules/proxmox-vm/`) encapsulates all VM configuration. Each VM in `vms.tf` is a single module call with only the values that differ from defaults — keeping definitions concise and consistent.

```hcl
module "forge_erp" {
  source = "./modules/proxmox-vm"

  vm_id        = 103
  name         = "forge-erp"
  description  = "ERPNext v16 — accounting and operations"
  node_name    = var.proxmox_node
  cores        = 2
  memory       = 8192
  disk_size    = 100
  storage_pool = "vm-fast"
  vlan_id      = 20
  ip_address   = "10.10.20.50/24"
  gateway      = "10.10.20.1"
  ssh_public_key = var.ssh_public_key
  tags         = ["erp"]
}
```

### Key Design Decisions

- **`create_from_template`** — Boolean flag that controls whether a VM is cloned from a cloud-init template (new VMs) or imported from an existing Proxmox VM. This allows existing hand-built VMs to be brought under Terraform management without recreation.
- **`disk_format`** — Existing VMs have `qcow2` disks; new VMs provisioned from template use `raw`. Exposed as a per-VM variable to prevent perpetual state drift.
- **GPU passthrough** — `hostpci_devices` variable accepts a list of PCI device objects, enabling declarative GPU passthrough (PCIe mode, xvga) for `forge-ai`.
- **`reboot_after_update = false`** — Prevents the provider from autonomously rebooting VMs after config changes. Reboots are performed manually and deliberately.
- **Sensitive variables** — API token and SSH public key are declared `sensitive = true` and supplied via `terraform.tfvars` (gitignored), never hardcoded.

### Usage

```bash
# Prerequisites: Terraform >= 1.5, Proxmox API token with VM.Admin permissions

cd terraform/

# Create terraform.tfvars
cat > terraform.tfvars <<EOF
proxmox_api_token = "root@pam!terraform=<your-token>"
proxmox_node      = "forge-hypervisor"
ssh_public_key    = "<your-public-key>"
EOF

terraform init
terraform plan
terraform apply
```

---

## Configuration Management (Ansible)

Ansible automates all post-provisioning configuration for forge-ops. A single command brings a fresh Debian install to full production state with all services running.

### Roles

| Role | What It Manages |
|------|----------------|
| `network` | forge-ops `/etc/network/interfaces` (Debian ifupdown) — untagged VLAN 10 mgmt + tagged VLAN 20 production, plus the `vlan` package the subinterface needs. Opt-in via `network_manage_interfaces` (default `false`); **deliberately handler-free** — it restores config on a rebuild and never restarts networking, which would drop SSH and fleet DNS. Rebuild procedure: `docs/runbooks/rebuild-forge-ops-networking.md` |
| `common` | Packages, locale, timezone, SSH hardening, UFW firewall, sysctl tuning, systemd-resolved DNS, NFS client mounts |
| `docker` | Docker CE install (`deb822_repository`), `/opt/bezaforge/` directory tree, container UID ownership, `bezaforge-net` bridge network |
| `traefik` | Reverse proxy, wildcard TLS via Let's Encrypt DNS-01 (Cloudflare), security headers middleware |
| `adguard` | AdGuard Home DNS server (codified `querylog_interval: 7d` — store AdGuard's canonical form, **not** `168h`, or it rewrites the config and restarts on every run) |
| `monitoring` | Prometheus + Grafana + Loki + Promtail + node-exporter + cAdvisor; Grafana dashboards provisioned from VCS (`files/grafana/dashboards/`) |
| `services` | Codified application services (gitea, netbox, langfuse, homepage, uptime-kuma, open-webui, calibre-web) across 3 secret-management patterns |
| `outline` | Outline wiki (`docs.bezaforge.dev`) — Outline + Postgres + Redis; Google OIDC; local-FS uploads |
| `openproject` | OpenProject Community PM (`pm.bezaforge.dev`) — all-in-one image (bundled Postgres/memcached/web/Rails workers) behind Traefik; the live work tracker (replaced Plane 2026-07, FORGE #455) |
| `ollama` | GPU LLM inference on forge-ai (version-pinned install, env-file, UFW rules to VLANs 50/20/30, model seed list, custom Modelfile builds) |
| `fail2ban` | SSH brute-force protection (forge-ops, forge-ai) |
| `vault-sync` | Knowledge vault git sync (ADR 0002, `never-knowledge`) — canonical clone on the hypervisor (webhook + timer, GitHub/GitLab mirror fan-out). Single-host since forge-brizza's retirement; the deployment-shape parametrization is kept for Brizza v2 |
| `gdrive-replica` | One-way nightly rclone mirror of Google Drive → `bezapool/gdrive` on the hypervisor (drive.readonly scope; replaces retired Insync — FORGE-35) |
| `sanoid` | ZFS auto-snapshots on forge-hypervisor — per-dataset retention on `bezapool` **and `sharepool`** (vault 24h/14d/8w/12m, gdrive 24h/14d/8w/12m, forge-ops-backup 7d/4w/6m, forge-erp-backup, sharepool/files; backup datasets deliberately not snapshotted). Also owns the nightly `syncoid` replica `sharepool/files` → `bezapool/sharepool-backup`. |
| `db-dumps` | Nightly 02:30 EDT `pg_dumpall` per Postgres container on forge-ops → NFS-mounted `bezapool/forge-ops-backup` |
| `forge-ops-backup-rsync` | Nightly 02:45 EDT rsync of `/opt/bezaforge/<svc>/` → NFS-mounted `bezapool/forge-ops-backup` |
| `restic-gcs` | Daily 04:00 EDT restic snapshot of `bezapool/{forge-ops-backup,vault,forge-erp-backup}` + `/sharepool/files` (nested Drive mount excluded) → GCS Nearline (`bezaforge-backups-95d56ebe`) |

### Secret Management

Secrets (DB passwords, API tokens, secret keys, OIDC client secrets) are stored in an ansible-vault encrypted file (`host_vars/forge-ops/vault.yml`). Inventory + rotation policy in `docs/runbooks/secret-rotation.md`. Three patterns handle secret injection across the codified services:

- **Template services** (gitea) — Jinja2 compose files with vault variables
- **Env-var services** (netbox, langfuse, outline, openproject) — `.env` files templated from vault, compose files copied or bind-mounted as-is
- **Simple services** (homepage, uptime-kuma) — no secrets, plain file copy

### Usage

```bash
cd ansible/

# Install required collections
ansible-galaxy collection install -r requirements.yml

# Full deployment
ansible-playbook site.yml -l forge-ops --ask-become-pass --ask-vault-pass

# Single role
ansible-playbook site.yml -l forge-ops --tags monitoring --ask-become-pass --ask-vault-pass

# Dry run (preview changes without applying)
ansible-playbook site.yml -l forge-ops --check --diff --ask-become-pass --ask-vault-pass
```

---

## Network Design

5-VLAN architecture managed by TP-Link Omada SDN (ER7412-M2 router, OC220 controller, EAP723 AP):

| VLAN | Name | Subnet | Purpose |
|------|------|--------|---------|
| 10 | Management | 10.10.10.0/24 | Infrastructure admin access |
| 20 | Production | 10.10.20.0/24 | Docker services host (forge-ops) |
| 30 | Development | 10.10.30.0/24 | Reserved — future dev workstation (forge-dev removed 2026-06-24) |
| 40 | Home | 10.10.40.0/24 | Personal devices, WiFi |
| 50 | AI | 10.10.50.0/24 | GPU workloads (forge-ai); 10.10.50.20 reserved for Brizza v2 |

**Inter-VLAN firewall rules** isolate home/personal devices from infrastructure.
**AdGuard Home** serves as authoritative DNS for all VLANs with wildcard rewrite for `*.bezaforge.dev`.
**forge-ops NIC tagging:** `enp44s0` **untagged** = VLAN 10 management (`10.10.10.20`); `enp44s0.20` **tagged** = VLAN 20 production (`10.10.20.20`, holds the default route). There is **no `enp44s0.10`** — docs claimed the reverse until 2026-08-07. Codified in `roles/network` (#628); rebuild path in `docs/runbooks/rebuild-forge-ops-networking.md`.
**Traefik v3** reverse proxy handles all HTTPS routing with automatic wildcard TLS via Let's Encrypt DNS-01 challenge (Cloudflare API).

---

## Deployed Services

All services run on **forge-ops** via Docker Compose at `/opt/bezaforge/{service}/`.

| Service | Purpose | URL |
|---------|---------|-----|
| **Traefik v3** | Reverse proxy + wildcard TLS (Let's Encrypt) | `traefik.bezaforge.dev` |
| **AdGuard Home** | DNS server + ad/tracker blocking | `10.10.20.20:3053` |
| **Prometheus** | Metrics collection (10+ scrape targets) | `prometheus.bezaforge.dev` |
| **Grafana** | Dashboards, alerting, data visualization | `grafana.bezaforge.dev` |
| **Loki + Promtail** | Log aggregation from all containers | Grafana data source |
| **Uptime Kuma** | Service availability monitoring | `uptime.bezaforge.dev` |
| **Gitea** | Self-hosted Git server (SSH on port 2222) | `git.bezaforge.dev` |
| **Outline** | Self-hosted wiki (Google Workspace OIDC; replaces retired Wiki.js) | `docs.bezaforge.dev` |
| **OpenProject** | Self-hosted project + work tracking (Community edition; replaced retired Plane) | `pm.bezaforge.dev` |
| **NetBox** | IP address management + network docs | `netbox.bezaforge.dev` |
| **Langfuse** | LLM observability and tracing | `langfuse.bezaforge.dev` |
| **Homepage** | Unified service dashboard | `home.bezaforge.dev` |
| **Calibre-Web** | Ebook library + reader (replaced retired Kavita) | `books.bezaforge.dev` |
| **Open WebUI** | Shared chat UI fronting Ollama | `chat.bezaforge.dev` |
| **Ollama** | Local LLM inference (on forge-ai) | `10.10.50.10:11434` |

---

## Observability Stack

```
forge-ops containers ──► Promtail ──► Loki ──► Grafana
forge-ops system     ──► Node Exporter ──► Prometheus ──► Grafana
forge-ops containers ──► cAdvisor ──► Prometheus ──► Grafana
forge-ai system      ──► Node Exporter ──► Prometheus ──► Grafana
All services         ──► Uptime Kuma (availability checks)
```

- **Prometheus** scrapes 10+ targets including node exporters, cAdvisor, and service-specific metrics
- **Grafana** provides dashboards for infrastructure resources, container stats, and service health
- **Loki + Promtail** aggregates logs from all Docker containers with full-text search via Grafana
- **Uptime Kuma** monitors HTTP/HTTPS availability with alert notifications

---

## SSL / TLS

Traefik v3 with automatic wildcard certificate for `*.bezaforge.dev`:
- **Challenge type:** DNS-01 via Cloudflare API (scoped API token)
- **Renewal:** Automatic, managed by Traefik
- **Coverage:** All internal services over HTTPS with valid certificate

---

## GPU Passthrough & LLM Inference

AMD RX 7900 XT (Navi 31 / gfx1100) passed through to `forge-ai` VM:

1. IOMMU enabled on forge-hypervisor (`amd_iommu=on iommu=pt` in GRUB)
2. GPU bound to `vfio-pci` driver on hypervisor
3. ROCm on the Ubuntu 26.04 guest (in-kernel `amdgpu` + Ubuntu-native `rocm-smi` tooling)
4. Ollama running with full GPU acceleration (verified via `ollama ps` Processor column)
5. GPU passthrough declared in Terraform via `hostpci_devices` — no manual Proxmox UI configuration

Models served locally — no external API calls for LLM inference.

---

## Storage

**bezapool** — ZFS mirror pool on forge-hypervisor:
- 2× 4TB HDDs in mirror configuration
- Datasets: `vault` (knowledge vault git clone — ADR 0002, `never-knowledge` synced from Gitea by `roles/vault-sync`), `gdrive` (Google Drive docs replica — nightly one-way rclone via `roles/gdrive-replica`), `forge-ops-backup` (nightly app-state mirror), `forge-erp-backup` (ERPNext bench backups), `sharepool-backup` (syncoid replica), `vzdump` (Proxmox VM backups — deliberately not snapshotted)
- NFS exports: `bezapool/{gdrive,forge-ops-backup}` mounted on forge-ops at `/mnt/bezapool/`

> The `media` + `downloads` datasets and their NFS exports were **destroyed 2026-07-18** when the Jellyfin/Seedbox media stack was retired (~106 GB reclaimed). Ebooks are served by Calibre-Web-Automated from `/opt/bezaforge/calibre-web/` bind mounts, **not** from an NFS-mounted dataset.

**sharepool** — single-disk ZFS pool (2TB Seagate) on forge-hypervisor — the unified file-access layer (ADR 0003):
- `sharepool/files` exported by **Samba**, with a live two-way **rclone Google Drive mount** nested at `GoogleDrive/`
- Consumers: laptop + Windows dev PC over SMB; forge-ai at `/mnt/bezashare` via `roles/fileshare-client`
- Protected by nightly syncoid replica → `bezapool/sharepool-backup` + restic→GCS (Drive mount excluded)

**vm-fast** / **vm-scratch** — NVMe pools:
- 1TB + 500GB NVMe for high-performance VM storage

---

## Backups

Four-layer backup architecture (deployed 2026-05-17 — see ADR 0001 in the vault, `05_Projects/bezaforge-infrastructure/design/decisions/0001-backup-architecture.md`, for the full rationale):

| Layer | Mechanism | Cadence | Scope |
|-------|-----------|---------|-------|
| **1. Snapshots** | `sanoid` on `bezapool` + `sharepool` | 15-min timer | Source datasets (vault 24h/14d/8w/12m; gdrive 24h/14d/8w/12m; forge-ops-backup 7d/4w/6m; forge-erp-backup; sharepool/files). Backup datasets (`vzdump`, `sharepool-backup`) deliberately NOT snapshotted — snapshots pinned 1.44 TB of pruned backups (FORGE-44) |
| **2. App state** | `pg_dumpall` + `rsync` on forge-ops | Nightly 02:30 / 02:45 EDT | Per-Postgres-container DB dumps + `/opt/bezaforge/<svc>/` → NFS-mounted `bezapool/forge-ops-backup` |
| **3. VM images** | Proxmox `vzdump` | Nightly 02:00 EDT | All VMIDs + cloud-init templates → `bezapool/vzdump` |
| **4. Off-site** | `restic` → Google Cloud Storage Nearline | Daily 04:00 EDT | `bezapool/forge-ops-backup` + `bezapool/vault` → `gs:bezaforge-backups-<id>` (us-central1) |

Roles: `roles/sanoid`, `roles/db-dumps`, `roles/forge-ops-backup-rsync`, `roles/restic-gcs`.

---

## Repository Structure

```
bezaforge-infrastructure/
├── ansible/
│   ├── ansible.cfg              # Defaults (inventory path)
│   ├── requirements.yml         # Galaxy collections (community.docker, etc.)
│   ├── site.yml                 # Main playbook — 5 plays (hypervisor, docker, gpu, assistant, erp hosts)
│   ├── update.yml               # Deliberate fleet package upgrade, in a safe order
│   ├── health.yml               # Read-only fleet health verification
│   ├── inventory/
│   │   ├── hosts.yml            # Host groups (hypervisor_hosts, docker_hosts, gpu_hosts, assistant_hosts)
│   │   └── host_vars/
│   │       ├── forge-ops/
│   │       │   ├── vars.yml     # Connection, network, service list
│   │       │   └── vault.yml    # Encrypted secrets (ansible-vault)
│   │       ├── forge-hypervisor/        # Hypervisor vars + vaulted secrets
│   │       ├── forge-erp/               # ERP host vars + vaulted secrets
│   │       └── forge-ai.yml     # GPU host vars (ollama models)
│   └── roles/
│       ├── common/                    # Base setup, SSH, UFW, NFS, sysctl, LLMNR off
│       ├── fail2ban/                  # SSH brute-force protection
│       ├── docker/                    # Docker CE, directory tree, bezaforge-net
│       ├── traefik/                   # Reverse proxy + TLS + middleware
│       ├── adguard/                   # DNS server (codified log retention)
│       ├── monitoring/                # Prometheus + Grafana + Loki + Promtail (dashboards in VCS)
│       ├── services/                  # Codified app services (gitea, netbox, langfuse, homepage, uptime-kuma)
│       ├── outline/                   # Outline wiki (docs.bezaforge.dev) — Google OIDC
│       ├── openproject/               # OpenProject PM (pm.bezaforge.dev) — all-in-one
│       ├── ollama/                    # GPU inference on forge-ai (pinned version, model seeds, Modelfiles)
│       ├── erpnext/                   # ERPNext (frappe_docker) on forge-erp
│       ├── forge-erp/                 # forge-erp host + bench-backup chain
│       ├── fileshare/                 # Samba + rclone Drive mount (ADR 0003)
│       ├── fileshare-client/          # SMB mount on agent VMs (/mnt/bezashare)
│       ├── minio-exports/             # LangFuse MinIO logical exports
│       ├── guest-agent/               # qemu-guest-agent on Proxmox VMs
│       ├── rocm/                      # forge-ai ROCm as-built
│       ├── vault-sync/                # Knowledge vault git sync (hypervisor)
│       ├── gdrive-replica/            # Nightly rclone Drive→bezapool mirror (hypervisor)
│       ├── sanoid/                    # ZFS auto-snapshots on forge-hypervisor (bezapool)
│       ├── db-dumps/                  # Nightly pg_dumpall per Postgres container → NFS
│       ├── forge-ops-backup-rsync/    # Nightly rsync of /opt/bezaforge/<svc>/ → NFS
│       └── restic-gcs/                # Daily restic → GCS Nearline (off-site backup)
├── terraform/
│   ├── main.tf              # Provider configuration (bpg/proxmox)
│   ├── variables.tf         # Root variables (api token, node, ssh key)
│   ├── outputs.tf           # VM IP outputs
│   ├── vms.tf               # VM definitions (forge-ai, forge-erp, forge-arcade)
│   └── modules/
│       └── proxmox-vm/      # Reusable VM module
│           ├── main.tf      # Resource definition
│           ├── variables.tf # All configurable inputs with defaults
│           └── outputs.tf   # VM ID and IP
├── docs/
│   ├── architecture.md      # Detailed architecture notes
│   ├── services.md          # Per-service configuration notes
│   ├── hardware.md          # Hardware inventory
│   └── deployment-notes.md  # Lessons learned and gotchas
├── docker/
│   ├── prometheus/
│   │   └── prometheus.yml   # Scrape configuration (legacy, now in ansible)
│   ├── traefik/
│   │   └── traefik.yml      # Static configuration (legacy, now in ansible)
│   └── loki/
│       └── loki-config.yml  # Loki configuration (legacy, now in ansible)
└── scripts/
    └── README.md            # Automation scripts (in progress)
```

---

## Technologies

`Terraform` `Ansible` `Proxmox VE` `Docker` `Docker Compose` `Traefik v3` `Prometheus` `Grafana` `Loki` `Promtail` `Uptime Kuma` `AdGuard Home` `Gitea` `Outline` `OpenProject` `NetBox` `Langfuse` `Calibre-Web` `Ollama` `ROCm` `ZFS` `sanoid` `restic` `Google Cloud Storage` `NFS` `Linux (Arch / Debian / Ubuntu)` `Cloudflare` `Let's Encrypt` `TP-Link Omada SDN` `Bash` `YAML` `HCL` `Jinja2`

---

## Related Projects

- [ansible-arch](https://github.com/thejollydev/ansible-arch) — Ansible playbook for Arch Linux workstation automation (jolly-LOQ-arch)
- [dotfiles](https://github.com/thejollydev/dotfiles) — GNU Stow-managed dotfiles (zsh, starship, nvim, kitty, zellij)
