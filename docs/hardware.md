# Hardware Inventory

> Verified against live hardware 2026-08-07; forge-hypervisor re-verified 2026-10-24. Physical port assignments, IPs and VLAN detail are deployment context and live in the private planning vault, not here.

## forge-hypervisor

| Component | Spec |
|-----------|------|
| Case | SAMA V60 mid-tower ATX, white, curved tempered-glass panel, 7× 120 mm ARGB fans |
| Power supply | EVGA SuperNOVA 750 G2 (220-G2-0750-XR) — 750 W, 80 PLUS Gold, fully modular |
| Motherboard | MSI MAG X570 TOMAHAWK WIFI (MS-7C84), board 1.0, BIOS 1.I0 (2025-03-20) — 6× SATA 6Gb/s + 2× M.2 Key-M |
| CPU | AMD Ryzen 7 5800X (8-core / 16-thread, 3.8GHz base / 4.7GHz boost) |
| RAM | 48GB DDR4, two mismatched Corsair Vengeance RGB Pro kits: 2× 8GB `CMW16GX4M2C3000C15` (3000 kit) + 2× 16GB `CMW32GX4M2D3600C18` (3600 kit). **All four run at 2133 MT/s** |
| GPU | XFX Speedster MERC 310 RX 7900 XT (`RX-79TMERCUR`, **20GB** GDDR6, Navi 31 / gfx1100) in PCI_E1, linked at PCIe 4.0 x16 — passed through to forge-ai |
| Boot | Crucial MX500 250GB SATA SSD (`CT250MX500SSD1`) |
| NVMe | M2_1: WD_BLACK SN850X 1TB (`vm-fast`, CPU lanes) · M2_2: WD_BLACK SN770 500GB (`vm-scratch`, chipset lanes) |
| HDD | 2× WD Red Plus 4TB (`WD40EFPX`, ZFS mirror, `bezapool`) + Seagate FireCuda 2TB SSHD (`ST2000DX002`, single-disk ZFS, `sharepool`) |
| Network | Realtek RTL8125 **2.5GbE** onboard (interface is named `nic0`), linked at 1 Gbps because the gateway port it uses is gigabit → VLAN-aware bridge `vmbr0`. Onboard Intel Wi-Fi 6 AX200, unused |
| OS | Proxmox VE 9.x |
| Role | Hypervisor — all VMs, GPU passthrough. Off-rack tower. |

**PCIe slot layout** (MSI manual, with a Ryzen 3000 or 5000 CPU):

| Slot | Lanes | From | In it |
|------|-------|------|-------|
| PCI_E1 | PCIe 4.0 x16 | CPU | RX 7900 XT |
| PCI_E2 | PCIe 3.0 x1 | chipset | empty |
| PCI_E3 | PCIe 4.0 x4 (x16 physical) | chipset | empty |
| PCI_E4 | PCIe 3.0 x1 | chipset | empty |
| M2_1 | PCIe 4.0 x4 | CPU | SN850X |
| M2_2 | PCIe 4.0 x4 or M.2 SATA | chipset | SN770 |

**SATA:** six SATA 6Gb/s connectors from the X570 chipset, with no M.2 sharing or disable rule; four are in use (boot SSD and three data drives), so two are free. Identify drives by serial: the kernel's `ataN` numbering changes from boot to boot.

**Known limits:**

- XFX asks for at least an 800 W supply for this card; the PSU is 750 W.
- The memory runs at the JEDEC default of 2133 MT/s, which usually means A-XMP is off in the BIOS. Mismatched kits should not be expected to run faster than 3000.

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

## Lenovo M920Q, idle (was forge-agents, and before that forge-k3s-worker)

| Component | Spec |
|-----------|------|
| Model | Lenovo ThinkCentre M920Q |
| CPU | Intel i5-8500T |
| RAM | 16GB DDR4 |
| Storage | 256GB NVMe, wiped |
| OS | None |
| State | **Idle hardware, powered off.** Still in U13 on the printed bracket beside the OC220, still cabled to PP 12 and router port 4 |
| History | The Brizza agent team's host, bare metal, from 2026-09-14 (BezaForge ADR 0011) until Joseph retired the team and the host on 2026-10-21. Its disk was wiped and it carries no OS; its address, 10.10.50.20, and the forge-agents name are released. Before that it was the Phase 3 K3s worker, never used |

> Router port 4 still has this box on it, with native VLAN 50. Powered off, its NIC can hold a 10 Mbps link for Wake-on-LAN — a lit port 4 does **not** mean anything is running.

## TINY-WIN

| Component | Spec |
|-----------|------|
| Model | Lenovo ThinkCentre M920Q (2nd unit) |
| CPU | Intel i5-8500T |
| RAM | 16GB DDR4 |
| OS | Windows 11 |
| Role | Occasional desktop on Joseph's desk — not racked; cabled to the gateway through the rack's patch panel. First wired 2026-08-07, re-wired 2026-09-27 after an office reorg |

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
| Growth headroom | 9U free in the rack; 2 of 6 SATA connectors free on the hypervisor; PCI_E2, PCI_E3 and PCI_E4 empty |
