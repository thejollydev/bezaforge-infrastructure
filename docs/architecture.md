# Architecture Notes

## Physical Hardware

### forge-hypervisor
- **CPU:** AMD Ryzen 7 5800X (8-core, 16-thread)
- **RAM:** 48GB DDR4
- **GPU:** AMD RX 7900 XT (24GB VRAM) — passed through to forge-ai VM
- **Storage:**
  - 2× 4TB HDD — ZFS mirror pool (`bezapool`)
  - 1TB NVMe — VM storage pool (`vm-fast`)
  - 500GB NVMe — scratch pool (`vm-scratch`)
- **OS:** Proxmox VE 9.1
- **Role:** Hypervisor — runs all VMs

### forge-ops
- **CPU:** Intel i9-12900H
- **RAM:** 32GB DDR5
- **Network:** Dual NIC (VLAN 10 management + VLAN 20 production)
- **OS:** Debian 13.3 Trixie
- **Role:** Docker service host — all production services run here

---

## VM Inventory

| VMID | Name | OS | VLAN | IP | vCPU | RAM | Purpose |
|------|------|----|------|-----|------|-----|---------|
| 101 | forge-ai | Ubuntu 24.04 | 50 | 10.10.50.10 | 6 | 16GB | GPU passthrough + Ollama |
| 102 | forge-dev | Arch Linux | 30 | 10.10.30.10 | 4 | 8GB | Dev environment |
| 103 | forge-erp | Ubuntu 24.04 | 20 | 10.10.20.50 | 4 | 8GB | ERPNext (pending) |
| 104 | forge-bezalel | Ubuntu 24.04 | 50 | 10.10.50.20 | 4 | 16GB | Bezalel AI assistant (OpenClaw + Engram consumer) |

---

## Network Architecture

### SDN Hardware
- **Router:** TP-Link ER7412-M2 (2.5GbE multi-WAN)
- **Controller:** TP-Link OC220 (Omada hardware controller)
- **Access Point:** TP-Link EAP723 (WiFi 6, VLAN-aware)

### VLAN Design
Traffic isolation by function — each VLAN has its own subnet and firewall policy.

**Firewall rules:**
- VLAN 40 (Home) → cannot reach VLANs 10, 20, 30, 50
- VLAN 50 (AI) → can reach VLAN 20 (for Prometheus scraping)
- VLAN 30 (Dev) → can reach VLAN 20 (for service access)
- VLAN 10 (Management) → can reach all VLANs (admin access)

### DNS
AdGuard Home runs on forge-ops (VLAN 20, port 53).
Configured as DHCP DNS for all VLANs via Omada controller.

**Wildcard DNS rewrite:**
```
*.bezaforge.dev → 10.10.20.20 (forge-ops / Traefik)
```

All subdomains resolve to Traefik, which routes to the correct service container.

---

## SSL / TLS Architecture

```
Internet → Cloudflare DNS → forge-ops (Traefik)
                                    ↓
                         Let's Encrypt ACME
                         (DNS-01 via CF API)
                                    ↓
                    Wildcard cert: *.bezaforge.dev
                                    ↓
                    All services served over HTTPS
```

Traefik holds the wildcard certificate and terminates TLS for all internal services. No service handles its own TLS.

---

## GPU Passthrough Architecture

```
forge-hypervisor (Proxmox)
├── IOMMU enabled (amd_iommu=on iommu=pt)
├── RX 7900 XT → vfio-pci driver (bound at boot)
└── forge-ai VM
    ├── PCIe passthrough: RX 7900 XT + RX 7900 XT Audio
    ├── ROCm 7.2.0 (amdgpu-dkms)
    └── Ollama (GPU-accelerated inference)
```

The GPU is fully dedicated to forge-ai — forge-hypervisor uses integrated/headless graphics for console.
