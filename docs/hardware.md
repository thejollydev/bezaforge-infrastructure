# Hardware Inventory

> Models and specifications only, verified against the live hardware (the hypervisor on 2026-10-24). Addresses, host names, interface names, port assignments and storage names are deployment detail and are kept out of this public repository.

## Hypervisor

| Component | Spec |
|-----------|------|
| Case | SAMA V60 mid-tower ATX, curved tempered-glass panel, 7× 120 mm ARGB fans |
| Power supply | EVGA SuperNOVA 750 G2 (220-G2-0750-XR) — 750 W, 80 PLUS Gold, fully modular |
| Motherboard | MSI MAG X570 TOMAHAWK WIFI (MS-7C84) — 6× SATA 6Gb/s + 2× M.2 Key-M |
| CPU | AMD Ryzen 7 5800X (8-core / 16-thread, 3.8GHz base / 4.7GHz boost) |
| RAM | 48GB DDR4, two mismatched Corsair Vengeance RGB Pro kits: 2× 8GB `CMW16GX4M2C3000C15` (3000 kit) + 2× 16GB `CMW32GX4M2D3600C18` (3600 kit). **All four run at 2133 MT/s** |
| GPU | XFX Speedster MERC 310 RX 7900 XT (`RX-79TMERCUR`, **20GB** GDDR6, Navi 31 / gfx1100) in PCI_E1, linked at PCIe 4.0 x16 — passed through to the inference VM |
| Boot | Crucial MX500 250GB SATA SSD (`CT250MX500SSD1`) |
| NVMe | M2_1: WD_BLACK SN850X 1TB (VM disks, CPU lanes) · M2_2: WD_BLACK SN770 500GB (scratch VM disks, chipset lanes) |
| HDD | 2× WD Red Plus 4TB (`WD40EFPX`) as a ZFS mirror + Seagate FireCuda 2TB SSHD (`ST2000DX002`) as a single-disk ZFS pool for the file share |
| Network | Realtek RTL8125 **2.5GbE** onboard, linked at 1 Gbps because the gateway port it uses is gigabit; a VLAN trunk into a VLAN-aware bridge. Onboard Intel Wi-Fi 6 AX200, unused |
| OS | Proxmox VE 9 |
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

## Service host (bare-metal Docker)

| Component | Spec |
|-----------|------|
| Model | BOSGAME P2 Pro |
| CPU | Intel i9-12900H (14-core, 20-thread) |
| RAM | 32GB DDR5 |
| Storage | 1TB PCIe 4.0 NVMe (Kingston) |
| Network | Two Intel I226-V 2.5GbE ports, **one active** — the management VLAN untagged and the production VLAN on a tagged sub-interface. The second port is spare and down |
| OS | Debian 13 Trixie |
| Role | Docker host — all production services |

## Spare node

| Component | Spec |
|-----------|------|
| Model | Lenovo ThinkCentre M920Q |
| CPU | Intel i5-8500T |
| RAM | 16GB DDR4 |
| Storage | 256GB NVMe, wiped |
| OS | None |
| State | **Idle hardware, powered off.** Still racked and cabled; its NIC holds a link for Wake-on-LAN while off, so a lit port does not mean it is running |
| History | Hosted an agent team on bare metal until 2026-10-21, and before that was planned as a Kubernetes worker that was never used |

## Desktop

| Component | Spec |
|-----------|------|
| Model | Lenovo ThinkCentre M920Q (2nd unit) |
| CPU | Intel i5-8500T |
| RAM | 16GB DDR4 |
| OS | Windows 11 |
| Role | Occasional desktop, not racked; cabled to the gateway through the rack's patch panel |

## Networking Equipment

| Device | Model | Role |
|--------|-------|------|
| Router | TP-Link ER7412-M2 | Multi-WAN Omada gateway — 10× RJ45 (2 at 2.5G) + 2× SFP + USB. The only wired L2/L3 device; there is no switch |
| Controller | TP-Link OC220 | Omada hardware SDN controller |
| Access Point | TP-Link EAP723 | WiFi 7 (802.11be, BE5000), 2.5GbE, PoE-powered through a POE260S injector |
| Patch panel | 24-port keystone, 1U | Passive; hosts cable through it to the router |

## Rack & Power

| Item | Spec |
|------|------|
| Cabinet | VEVOR 15U wall-mount (18" internal depth) — free-standing |
| UPS | Tripp Lite SMART1500LCD (1500 VA / 900 W), 2U, eight battery-backed outlets. Carries everything in the rack and nothing outside it |
| Hypervisor power | Its own surge protector, **not battery-backed**, to keep the GPU tower's 400–500 W load off the UPS |
| Growth headroom | 9U free in the rack; 2 of 6 SATA connectors free on the hypervisor; PCI_E2, PCI_E3 and PCI_E4 empty |
