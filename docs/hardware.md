# Hardware Inventory

## forge-hypervisor

| Component | Spec |
|-----------|------|
| CPU | AMD Ryzen 7 5800X (8-core / 16-thread, 3.8GHz base / 4.7GHz boost) |
| RAM | 48GB DDR4 |
| GPU | AMD Radeon RX 7900 XT (24GB GDDR6, Navi 31 / gfx1100) — passed through to forge-ai |
| Storage | 2× 4TB HDD (ZFS mirror, bezapool) + 1TB NVMe (vm-fast) + 500GB NVMe (vm-scratch) |
| Network | 1GbE onboard |
| OS | Proxmox VE 9.1 |
| Role | Hypervisor — all VMs, GPU passthrough |

## forge-ops (Bare Metal Docker Host)

| Component | Spec |
|-----------|------|
| CPU | Intel i9-12900H (14-core, 20-thread) |
| RAM | 32GB DDR5 |
| Storage | 1TB NVMe |
| Network | Dual NIC — VLAN 10 (management) + VLAN 20 (production) |
| OS | Debian 13.3 Trixie |
| Role | Docker host — all production services |

## Networking Equipment

| Device | Model | Role |
|--------|-------|------|
| Router | TP-Link ER7412-M2 | 2.5GbE multi-WAN router, 5 VLAN-capable ports |
| Controller | TP-Link OC220 | Omada hardware SDN controller |
| Access Point | TP-Link EAP723 | WiFi 6, VLAN-aware (4 SSIDs) |

## forge-k3s-worker (Powered Off — Phase 2)

| Component | Spec |
|-----------|------|
| CPU | Intel i5-8500T |
| RAM | 16GB |
| Role | K3s worker node (future Kubernetes cluster) |
