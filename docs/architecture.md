# Architecture

This file is intentionally minimal. The canonical, living architecture document for BezaForge lives in the Master-Mind Obsidian vault — that's where it's actively maintained and where the diagrams, IP allocation tables, sanoid retention rules, backup architecture, NFS chain, and per-VM memory layout all live alongside each other.

## Canonical source

Obsidian vault (Master-Mind):

- **Architecture:** `05_Projects/bezaforge-infrastructure/design/architecture.md`
- **IP allocation:** `05_Projects/bezaforge-infrastructure/design/ip-allocation.md`
- **ADRs:** `05_Projects/bezaforge-infrastructure/design/decisions/`
- **Phase plans + per-service guides:** `05_Projects/bezaforge-infrastructure/phases/`
- **Roadmap (live status):** `05_Projects/bezaforge-infrastructure/ROADMAP.md`

Open the vault via Obsidian on a workstation that has the Master-Mind vault synced. Claude Code reads it via the `obsidian-http` MCP server (see `CLAUDE.md` in this repo for the session-startup sequence).

## Repo-local references that *are* worth checking in

The vault is canonical for design, but a few facts live alongside the code because they're operationally inseparable from it:

- **Service inventory + bezaforge.dev URL table** → `README.md` in this repo (top of file)
- **Hardware spec + per-VM resource list** → `README.md` (Infrastructure section) and `terraform/vms.tf` (authoritative for VM definitions)
- **VLAN ACLs + DNS** → not in repo; configured in the Omada controller UI. See vault `02_Knowledge-Base/Quick-References/Networking/` for snapshots. (Carryover #18 on the ROADMAP — community Omada Terraform provider exists but isn't worth adopting yet.)
- **Backups** → `README.md` (Backups section) summarizes the four-layer architecture. ADR 0001 in `05_Projects/bezaforge-infrastructure/design/decisions/0001-backup-architecture.md` (vault) has the full decision record.
- **Per-service Docker Compose** → `ansible/roles/services/templates/*-compose.yml.j2`
- **Per-role secrets schema** → `ansible/inventory/host_vars/*/vault.yml` (ansible-vault encrypted)

## History

This file was previously a partial architecture summary that drifted out of sync with the vault (last meaningful update Mar 2026; bypassed all of Phase 2). It was replaced with this stub on 2026-05-17 per ROADMAP carryover #20.

Other stale files in this directory follow the same pattern — `hardware.md`, `services.md`, `deployment-notes.md` predate Phase 2 and may also be out of date. Trust the vault first; if a repo-local doc is needed for operational reasons, the README and `docs/runbooks/` are the right homes.
