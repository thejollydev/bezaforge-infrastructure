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
| **forge-ai** | GPU LLM inference | RX 7900 XT passthrough, ROCm 7.2.0 | Ubuntu 24.04 |
| **forge-dev** | Development environment | 4 vCPU, 8GB RAM | Arch Linux + KDE Plasma 6 |
| **forge-erp** | ERP (ERPNext v16) | 2 vCPU, 4GB RAM | Ubuntu 24.04 |
| **forge-brizza** | Brizza AI assistant (Python + LangGraph, Cognee MCP consumer) | 4 vCPU, 16GB RAM | Ubuntu 24.04 |

---

## Infrastructure as Code

All VMs are declaratively defined and managed via Terraform using the [bpg/proxmox](https://registry.terraform.io/providers/bpg/proxmox/latest) provider.

### Module Design

A reusable `proxmox-vm` module (`terraform/modules/proxmox-vm/`) encapsulates all VM configuration. Each VM in `vms.tf` is a single module call with only the values that differ from defaults — keeping definitions concise and consistent.

```hcl
module "forge_brizza" {
  source = "./modules/proxmox-vm"

  vm_id        = 104
  name         = "forge-brizza"
  description  = "Brizza AI assistant — Python + LangGraph, Cognee MCP consumer, Discord"
  node_name    = var.proxmox_node
  cores        = 4
  memory       = 16384
  disk_size    = 100
  storage_pool = "vm-fast"
  vlan_id      = 50
  ip_address   = "10.10.50.20/24"
  gateway      = "10.10.50.1"
  ssh_public_key = var.ssh_public_key
  tags         = ["ai", "brizza"]
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

| Role | Tasks | What It Manages |
|------|-------|----------------|
| `common` | 24 | Packages, locale, timezone, SSH hardening, UFW firewall (10 rules), sysctl tuning, systemd-resolved DNS, NFS client mounts |
| `docker` | 14 | Docker CE install, `/opt/bezaforge/` directory tree, container UID ownership, `bezaforge-net` bridge network |
| `traefik` | 6 | Reverse proxy, wildcard TLS via Cloudflare DNS challenge, security headers middleware |
| `adguard` | 3 | DNS server compose stack |
| `monitoring` | 8 | Prometheus + Grafana + Loki + Promtail + node-exporter + cAdvisor |
| `services` | 6 | 7 application services across 3 secret management patterns |

### Secret Management

14 secrets (DB passwords, API tokens, secret keys) are stored in an ansible-vault encrypted file (`host_vars/forge-ops/vault.yml`). Three patterns handle secret injection:

- **Template services** (gitea, taiga, wiki) — Jinja2 compose files with vault variables
- **Env-var services** (netbox, langfuse) — `.env` files templated from vault, compose files copied as-is
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
| 30 | Development | 10.10.30.0/24 | Dev VM (forge-dev) |
| 40 | Home | 10.10.40.0/24 | Personal devices, WiFi |
| 50 | AI | 10.10.50.0/24 | GPU workloads (forge-ai) and AI assistants (forge-brizza) |

**Inter-VLAN firewall rules** isolate home/personal devices from infrastructure.
**AdGuard Home** serves as authoritative DNS for all VLANs with wildcard rewrite for `*.bezaforge.dev`.
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
| **Taiga** | Agile project management (7 containers) | `taiga.bezaforge.dev` |
| **NetBox** | IP address management + network docs | `netbox.bezaforge.dev` |
| **Langfuse** | LLM observability and tracing | `langfuse.bezaforge.dev` |
| **Homepage** | Unified service dashboard | `home.bezaforge.dev` |
| **Jellyfin** | Media streaming server | `jellyfin.bezaforge.dev` |
| **Kavita** | Self-hosted reading server (books, comics, manga) | `kavita.bezaforge.dev` |
| **qBittorrent + Gluetun** | Seedbox with WireGuard VPN kill switch | `seedbox.bezaforge.dev` |
| **Ollama** | Local LLM inference (on forge-ai) | `10.10.50.10:11434` |

---

## Observability Stack

```
forge-ops containers ──► Promtail ──► Loki ──► Grafana
forge-ops system     ──► Node Exporter ──► Prometheus ──► Grafana
forge-ops containers ──► cAdvisor ──► Prometheus ──► Grafana
forge-ai system      ──► Node Exporter ──► Prometheus ──► Grafana
forge-dev system     ──► Node Exporter ──► Prometheus ──► Grafana
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
3. ROCm 7.2.0 installed on Ubuntu 24.04 guest
4. Ollama running with full GPU acceleration (verified via `ollama ps` Processor column)
5. GPU passthrough declared in Terraform via `hostpci_devices` — no manual Proxmox UI configuration

Models served locally — no external API calls for LLM inference.

---

## Storage

**bezapool** — ZFS mirror pool on forge-hypervisor:
- 2× 4TB HDDs in mirror configuration
- Datasets: `media`, `downloads`, `gdrive` (Insync sync target from forge-brizza), `forge-ops-backup` (nightly app-state mirror), `vzdump` (Proxmox VM backups)
- NFS exports: `bezapool/{media,downloads,gdrive,forge-ops-backup}` mounted on forge-ops/forge-brizza at `/mnt/bezapool/`
- Media library structure: movies, tv, music, photos, books

**vm-fast** / **vm-scratch** — NVMe pools:
- 1TB + 500GB NVMe for high-performance VM storage

---

## Backups

Four-layer backup architecture (deployed 2026-05-17 — see `docs/decisions/0001-backup-architecture.md` or the vault ADR for the full rationale):

| Layer | Mechanism | Cadence | Scope |
|-------|-----------|---------|-------|
| **1. Snapshots** | `sanoid` on `bezapool` | 15-min timer | All datasets (gdrive 24h/14d/8w/12m; forge-ops-backup 7d/4w/6m; downloads 7d; media 4d/4w/3m; vzdump 4d/2w/2m) |
| **2. App state** | `pg_dumpall` + `rsync` on forge-ops | Nightly 02:30 / 02:45 EDT | Per-Postgres-container DB dumps + `/opt/bezaforge/<svc>/` → NFS-mounted `bezapool/forge-ops-backup` |
| **3. VM images** | Proxmox `vzdump` | Nightly 02:00 EDT | All VMIDs + cloud-init templates → `bezapool/vzdump` |
| **4. Off-site** | `restic` → Google Cloud Storage Nearline | Daily 04:00 EDT | `bezapool/forge-ops-backup` → `gs:bezaforge-backups-<id>` (us-central1) |

Roles: `roles/sanoid`, `roles/db-dumps`, `roles/forge-ops-backup-rsync`, `roles/restic-gcs`.

---

## Repository Structure

```
bezaforge-infrastructure/
├── ansible/
│   ├── ansible.cfg              # Defaults (inventory path)
│   ├── requirements.yml         # Galaxy collections (community.docker, etc.)
│   ├── site.yml                 # Main playbook (docker_hosts + gpu_hosts)
│   ├── inventory/
│   │   ├── hosts.yml            # Host groups (docker_hosts, gpu_hosts)
│   │   └── host_vars/
│   │       ├── forge-ops/
│   │       │   ├── vars.yml     # Connection, network, service list
│   │       │   └── vault.yml    # Encrypted secrets (ansible-vault)
│   │       └── forge-ai.yml     # Minimal host vars
│   └── roles/
│       ├── common/              # Base setup, SSH, UFW, NFS, sysctl
│       ├── docker/              # Docker CE, directory tree, bezaforge-net
│       ├── traefik/             # Reverse proxy + TLS + middleware
│       ├── adguard/             # DNS server
│       ├── monitoring/          # Prometheus + Grafana + Loki + Promtail
│       ├── services/            # 7 app services (3 secret patterns)
│       └── ollama/              # GPU inference (forge-ai, planned)
├── terraform/
│   ├── main.tf              # Provider configuration (bpg/proxmox)
│   ├── variables.tf         # Root variables (api token, node, ssh key)
│   ├── outputs.tf           # VM IP outputs
│   ├── vms.tf               # VM definitions (forge-ai, forge-dev, forge-erp, forge-brizza)
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

`Terraform` `Ansible` `Proxmox VE` `Docker` `Docker Compose` `Traefik v3` `Prometheus` `Grafana` `Loki` `Promtail` `Uptime Kuma` `AdGuard Home` `Gitea` `Taiga` `NetBox` `Langfuse` `Jellyfin` `Kavita` `qBittorrent` `Gluetun` `Ollama` `ROCm` `ZFS` `sanoid` `restic` `Google Cloud Storage` `NFS` `Linux (Arch / Debian / Ubuntu)` `Cloudflare` `Let's Encrypt` `TP-Link Omada SDN` `Bash` `YAML` `HCL` `Jinja2`

---

## Related Projects

- [ansible-arch](https://github.com/thejollydev/ansible-arch) — Ansible playbook for Arch Linux workstation automation (forge-dev + jolly-LOQ-arch)
- [dotfiles](https://github.com/thejollydev/dotfiles) — GNU Stow-managed dotfiles (zsh, starship, nvim, kitty, zellij)
