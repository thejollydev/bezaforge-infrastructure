# BezaForge Infrastructure Platform

Production-grade private cloud built on Proxmox VE, Docker, and a 5-VLAN network architecture. Runs 10+ containerized services with full observability, automated wildcard SSL, and GPU-accelerated LLM inference.

![Infrastructure](https://img.shields.io/badge/Proxmox-E57000?style=flat&logo=proxmox&logoColor=white)
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
| **forge-erp** | ERP (pending) | 4 vCPU, 8GB RAM | Ubuntu 24.04 |

---

## Network Design

5-VLAN architecture managed by TP-Link Omada SDN (ER7412-M2 router, OC220 controller, EAP723 AP):

| VLAN | Name | Subnet | Purpose |
|------|------|--------|---------|
| 10 | Management | 10.10.10.0/24 | Infrastructure admin access |
| 20 | Production | 10.10.20.0/24 | Docker services host (forge-ops) |
| 30 | Development | 10.10.30.0/24 | Dev VM (forge-dev) |
| 40 | Home | 10.10.40.0/24 | Personal devices, WiFi |
| 50 | AI | 10.10.50.0/24 | GPU workloads (forge-ai) |

**Inter-VLAN firewall rules** isolate home/personal devices from infrastructure.
**AdGuard Home** serves as authoritative DNS for all VLANs with wildcard rewrite for `*.bezaforge.dev`.
**Traefik v3** reverse proxy handles all HTTPS routing with automatic wildcard TLS via Let's Encrypt DNS-01 challenge (Cloudflare API).

---

## Deployed Services

All services run on **forge-ops** via Docker Compose at `/opt/bezaforge/{service}/`.

| Service | Purpose | URL |
|---------|---------|-----|
| **Traefik v3** | Reverse proxy + wildcard TLS (Let's Encrypt) | `traefik.bezaforge.dev` |
| **AdGuard Home** | DNS server + ad/tracker blocking | `adguard.bezaforge.dev` |
| **Prometheus** | Metrics collection (10+ scrape targets) | `prometheus.bezaforge.dev` |
| **Grafana** | Dashboards, alerting, data visualization | `grafana.bezaforge.dev` |
| **Loki + Promtail** | Log aggregation from all containers | Grafana data source |
| **Uptime Kuma** | Service availability monitoring | `uptime.bezaforge.dev` |
| **Gitea** | Self-hosted Git server | `git.bezaforge.dev` |
| **Harbor** | Private container registry | `harbor.bezaforge.dev` |
| **Taiga** | Agile project management | `taiga.bezaforge.dev` |
| **Wiki.js** | Internal documentation wiki | `wiki.bezaforge.dev` |
| **NetBox** | IP address management + network docs | `netbox.bezaforge.dev` |
| **Homepage** | Unified service dashboard | `home.bezaforge.dev` |

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

Models served locally — no external API calls for LLM inference.

---

## Storage

**bezapool** — ZFS mirror pool on forge-hypervisor:
- 2× 4TB HDDs in mirror configuration
- Used for VM disk images and persistent data

**vm-fast** / **vm-scratch** — NVMe pools:
- 1TB + 500GB NVMe for high-performance VM storage

---

## Repository Structure

```
bezaforge-infrastructure/
├── docs/
│   ├── architecture.md      # Detailed architecture notes
│   ├── services.md          # Per-service configuration notes
│   ├── hardware.md          # Hardware inventory
│   └── deployment-notes.md  # Lessons learned and gotchas
├── docker/
│   ├── prometheus/
│   │   └── prometheus.yml   # Scrape configuration
│   ├── traefik/
│   │   └── traefik.yml      # Static configuration
│   ├── loki/
│   │   └── loki-config.yml  # Loki configuration
│   └── adguard/
│       └── README.md        # AdGuard setup notes
└── scripts/
    └── README.md            # Automation scripts (in progress)
```

---

## Technologies

`Proxmox VE` `Docker` `Docker Compose` `Traefik v3` `Prometheus` `Grafana` `Loki` `Promtail` `Uptime Kuma` `AdGuard Home` `Gitea` `Harbor` `Taiga` `Wiki.js` `NetBox` `Ollama` `ROCm` `ZFS` `Linux (Arch / Debian / Ubuntu)` `Cloudflare` `Let's Encrypt` `TP-Link Omada SDN` `Bash` `Python` `YAML`

---

## Related Projects

- [arch-ansible](https://github.com/thejollydev/arch-ansible) — Ansible playbooks for Arch Linux dev environment setup
