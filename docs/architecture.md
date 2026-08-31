# Architecture

This file is intentionally minimal. The canonical, living architecture document for BezaForge lives in the knowledge vault — that's where it's actively maintained and where the diagrams, IP allocation tables, sanoid retention rules, backup architecture, NFS chain, and per-VM memory layout all live alongside each other.

## Canonical source

The `never-knowledge` vault, under `10_Workspaces/BezaCore-Labs/Workspaces/BezaForge-Infrastructure/`:

- **Architecture:** `Architecture/architecture.md` (diagrams in `Architecture/Diagrams/`, per-service guides in `Architecture/Guides/`)
- **IP allocation:** `Resources/ip-allocation.md`
- **ADRs:** `Decisions/` — `adr-0001_backup-architecture.md` through `adr-0008_mermaid-as-diagram-source.md`
- **Phase plans:** `Plans/phase-1_foundation.md`, `phase-2_automation.md`, `phase-3_kubernetes.md`
- **Roadmap (live status):** `Plans/roadmap.md`

Paths updated 2026-08-30 (#791). They previously named `05_Projects/bezaforge-infrastructure/` in the **Master-Mind** vault, which was retired (#195) and frozen on 2026-08-15 — every path in that list had been dead for a fortnight.

Reach it through Never4gA rather than by opening files directly: `never4ga --actor <client>/<model> context startup --client <client> --cwd "$PWD"` resolves this repository to that workspace and returns the bounded pack. `never4ga concept get <id>` fetches a single document. `AGENTS.md` in this repo carries the session-startup sequence.

## Repo-local references that *are* worth checking in

The vault is canonical for design, but a few facts live alongside the code because they're operationally inseparable from it:

- **Service inventory + bezaforge.dev URL table** → `README.md` in this repo (top of file)
- **Hardware spec + per-VM resource list** → `README.md` (Infrastructure section) and `terraform/vms.tf` (authoritative for VM definitions)
- **VLAN ACLs + DNS** → not in repo; configured in the Omada controller UI. The verified live matrix lives in vault `10_Workspaces/BezaCore-Labs/Workspaces/BezaForge-Infrastructure/Resources/ip-allocation.md` ("Firewall Rules Summary" — checked against the live gateway 2026-06-26 — and "DNS Configuration"). Codifying this in Terraform was evaluated and **declined** (OpenProject #122, 2026-07-31): of three community Omada providers only one covers VLANs/ACLs/port-profiles, and it is four months old, feature-frozen, single-maintainer; none covers DNS rewrites. Omada stays hand-managed.
- **Backups** → `README.md` (Backups section) summarizes the four-layer architecture. ADR 0001 in `10_Workspaces/BezaCore-Labs/Workspaces/BezaForge-Infrastructure/Decisions/adr-0001_backup-architecture.md` (vault) has the full decision record.
- **Per-service Docker Compose** → `ansible/roles/services/templates/*-compose.yml.j2`
- **Per-role secrets schema** → `ansible/inventory/host_vars/*/vault.yml` (ansible-vault encrypted)

## History

This file was previously a partial architecture summary that drifted out of sync with the vault (last meaningful update Mar 2026; bypassed all of Phase 2). It was replaced with this stub on 2026-05-17 per ROADMAP carryover #20.

Other stale files in this directory follow the same pattern — `services.md` and `deployment-notes.md` predate Phase 2 and may also be out of date. Trust the vault first; if a repo-local doc is needed for operational reasons, the README and `docs/runbooks/` are the right homes.

`hardware.md` was **refreshed and verified against live hardware on 2026-08-07** and is no longer in that stale set. That pass corrected four wrong facts it had been carrying: the RX 7900 XT's VRAM (24GB → **20GB**, measured 21,458,059,264 B on forge-ai), the ER7412-M2's port count (*"5 VLAN-capable ports"* → **10× RJ45 + 2× SFP + USB**; the 5 was the number of VLAN *interfaces*), the EAP723's generation (WiFi 6 → **WiFi 7**), and forge-ops described as dual-NIC when only one port is active. It also gained forge-k3s-worker's Wake-on-LAN caveat and TINY-WIN.
