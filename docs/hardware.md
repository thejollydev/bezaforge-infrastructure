# Hardware Inventory

> Verified against live hardware 2026-08-07. Physical port assignments, IPs and VLAN detail are deployment context and live in the private planning vault, not here.

## forge-hypervisor

| Component | Spec |
|-----------|------|
| Motherboard | MSI MAG X570 TOMAHAWK WIFI (MS-7C84) — 6× SATA 6Gb/s + 2× M.2 Key-M |
| CPU | AMD Ryzen 7 5800X (8-core / 16-thread, 3.8GHz base / 4.7GHz boost) |
| RAM | 48GB DDR4 |
| GPU | AMD Radeon RX 7900 XT (**20GB** GDDR6, Navi 31 / gfx1100) — passed through to forge-ai |
| Storage | 250GB SSD (boot) + 1TB NVMe (`vm-fast`) + 500GB NVMe (`vm-scratch`) + 2× 4TB HDD (ZFS mirror, `bezapool`) + 2TB HDD (single-disk ZFS, `sharepool`) |
| Network | 1GbE onboard (interface is named `nic0`) → VLAN-aware bridge `vmbr0` |
| OS | Proxmox VE 9.x |
| Role | Hypervisor — all VMs, GPU passthrough. Off-rack tower. |

## forge-ops (Bare Metal Docker Host)

| Component | Spec |
|-----------|------|
| Model | BOSGAME P2 Pro |
| CPU | Intel i9-12900H (14-core, 20-thread) |
| RAM | 32GB DDR5 |
| Storage | 1TB PCIe 4.0 NVMe |
| Network | Two 2.5GbE ports, **one active** — untagged management VLAN + a tagged production VLAN sub-interface. The second port is spare and down. |
| OS | Debian 13 Trixie |
| Role | Docker host — all production services |

## forge-k3s-worker (Powered Off — Phase 3)

| Component | Spec |
|-----------|------|
| Model | Lenovo ThinkCentre M920Q |
| CPU | Intel i5-8500T |
| RAM | 16GB DDR4 |
| Storage | 256GB NVMe |
| Role | K3s worker node (future Kubernetes cluster) |

> Powered off, but its NIC holds link at 10 Mbps for Wake-on-LAN — a lit router port does **not** mean this node is running.

## TINY-WIN

| Component | Spec |
|-----------|------|
| Model | Lenovo ThinkCentre M920Q (2nd unit) |
| CPU | Intel i5-8500T |
| RAM | 16GB DDR4 |
| OS | Windows 11 |
| Role | Occasional desktop; wired into the rack 2026-08-07 |

## Networking Equipment

| Device | Model | Role |
|--------|-------|------|
| Router | TP-Link ER7412-M2 | 2.5GbE multi-WAN Omada gateway — **10× RJ45 + 2× SFP + USB** (5 *VLAN interfaces*, one per VLAN — not 5 ports). The only wired L2/L3 device; there is no switch. |
| Controller | TP-Link OC220 | Omada hardware SDN controller |
| Access Point | TP-Link EAP723 | **WiFi 7** (802.11be, BE5000), 2.5GbE, PoE-powered via a POE260S injector |
| Patch panel | 24-port keystone, 1U | Passive; hosts cable through it to the router |

## Rack & Power

| Item | Spec |
|------|------|
| Cabinet | VEVOR 15U wall-mount (18" internal depth) — free-standing on a file cabinet |
| UPS | Tripp Lite SMART1500LCD (1500 VA / 900 W), 2U |
| Growth headroom | 9U free in the rack; 2 free SATA ports on the hypervisor |
