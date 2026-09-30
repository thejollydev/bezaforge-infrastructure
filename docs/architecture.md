# Architecture

This file is intentionally minimal. The living design record for BezaForge (architecture diagrams, IP allocation, decision records, phase plans and the roadmap) is maintained outside this repository, where the diagrams, sanoid retention rules, backup architecture, NFS chain and per-VM memory layout are kept alongside each other.

## Repo-local references that *are* worth checking in

The external record is canonical for design, but a few facts live alongside the code because they're operationally inseparable from it:

- **Service inventory + bezaforge.dev URL table** → `README.md` in this repo (top of file)
- **Hardware spec + per-VM resource list** → `README.md` (Infrastructure section) and `terraform/vms.tf` (authoritative for VM definitions)
- **VLAN ACLs + DNS** → not in repo; configured in the Omada controller UI. The verified live matrix (firewall rules checked against the live gateway 2026-06-26, and DNS configuration) is kept in the external design record. Codifying this in Terraform was evaluated and **declined** (OpenProject #122, 2026-07-31): of three community Omada providers only one covers VLANs/ACLs/port-profiles, and it is four months old, feature-frozen, single-maintainer; none covers DNS rewrites. Omada stays hand-managed.
- **Backups** → `README.md` (Backups section) summarizes the four-layer architecture.
- **Per-service Docker Compose** → `ansible/roles/services/templates/*-compose.yml.j2`
- **Per-role secrets schema** → `ansible/inventory/host_vars/*/vault.yml` (ansible-vault encrypted)

## History

This file was previously a partial architecture summary that drifted out of sync with the maintained design record (last meaningful update Mar 2026; bypassed all of Phase 2). It was replaced with this stub on 2026-05-17 per ROADMAP carryover #20.

Other stale files in this directory follow the same pattern — `services.md` and `deployment-notes.md` predate Phase 2 and may also be out of date. Trust the live hosts and the code first; if a repo-local doc is needed for operational reasons, the README and `docs/runbooks/` are the right homes.

`hardware.md` was **refreshed and verified against live hardware on 2026-08-07** and is no longer in that stale set. That pass corrected four wrong facts it had been carrying: the RX 7900 XT's VRAM (24GB → **20GB**, measured 21,458,059,264 B on forge-ai), the ER7412-M2's port count (*"5 VLAN-capable ports"* → **10× RJ45 + 2× SFP + USB**; the 5 was the number of VLAN *interfaces*), the EAP723's generation (WiFi 6 → **WiFi 7**), and forge-ops described as dual-NIC when only one port is active. It also gained forge-k3s-worker's Wake-on-LAN caveat and TINY-WIN.
