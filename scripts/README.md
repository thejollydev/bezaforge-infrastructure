# Scripts

Ad-hoc automation scripts for BezaForge infrastructure management.

> **Status:** Mostly superseded by Ansible roles. This directory is intentionally lean — anything reusable lives in `ansible/roles/` as a proper role instead.

## Current state

| Script | What it is | Deployed by |
|---|---|---|
| `dns-parity-check.sh` | Asserts AdGuard and dnsmasq answer internal names identically (#638/#649) | `roles/dnsmasq` copies it verbatim to forge-hypervisor |
| `deploy-drift-check.py` | Reports roles merged to `main` but never deployed (#671) | `roles/monitoring` copies it verbatim to forge-ops |
| `openproject/` | One-off OpenProject provisioning + structuring batches (2026-07 migration) | not deployed — run by hand from the workstation |

Both checkers live here rather than in the role's `files/` **on purpose**: the role copies this exact file to the host, so a hand-run check and the metric behind the alert can never disagree. Two copies of a drift checker is the same bug it exists to catch.

The original "planned scripts" list (`bootstrap-service`, `backup-verify`, `cert-check`, `health-check`) was authored in early Phase 1 and has been overtaken by reality:

- **`bootstrap-service`** — Superseded by the Ansible `services/` role pattern (per-service Jinja2 compose templates + vault secrets). New service add procedure lives in `vault: 02_Knowledge-Base/Workflows/new-docker-service.md` + `runbooks/add-traefik-routed-service.md`.
- **`backup-verify`** — Superseded by `ansible/roles/restic-gcs/` (which already exercises `restic check` weekly via systemd timer) and the four-layer backup architecture documented in `vault: 05_Projects/bezaforge-infrastructure/phases/2-automation/05-backups.md`. Manual restore drills should be a runbook, not a script.
- **`cert-check`** — Traefik renews `*.bezaforge.dev` automatically via Cloudflare DNS-01; Uptime Kuma monitors expiry of the rendered cert. No script needed.
- **`health-check`** — Replaced by Prometheus + Uptime Kuma. Status at a glance: `https://uptime.bezaforge.dev`.

If a one-off operational script is truly needed (something that isn't an Ansible role, a Terraform module, or a runbook procedure), drop it here with a comment header explaining why it's a script and not a role.
