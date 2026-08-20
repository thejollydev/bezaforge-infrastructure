<!-- AIW-MANAGED: repository-agent-policy-v2 -->
# Repository Agent Policy — bezaforge-infrastructure

Project ID: `bezaforge-infrastructure`

## Resolve durable project knowledge at runtime

```bash
aiw project path bezaforge-infrastructure      # preferred
# fallback: $AIW_VAULT/10-projects/bezaforge-infrastructure
```

Read `index.md`, `project.md`, and — before touching ANYTHING on this fleet —
`80-knowledge/lessons-learned.md`: the standing-caveats list, where every
line has an incident number behind it. Phase guides:
`50-execution/phases/`. ADRs: `00-governance/decisions/`. Migrated
2026-08-15; Master-Mind is historical.

## What this repository is

Infrastructure-as-code for the BezaForge fleet: `terraform/` (Proxmox VMs),
`ansible/` (configuration), `docker/` (compose), `scripts/`,
`docs/runbooks/`. No tests or build at repo level — the fleet is the
product.

## ⛔ MERGED IS NOT DEPLOYED

A merged PR changes a file in git and zero machines. Nothing detects the
gap. Every change to a deployable path is unshipped until applied and
verified live:

```bash
cd ansible   # NEVER from the repo root — that yields a silent empty recap
ansible-playbook site.yml --tags <role> --limit <host> --ask-become-pass --ask-vault-pass
```

Both prompts make this **Joseph-run, never agent-run**. Agents hand over the
exact command, then verify live with read-only checks (their own job) and
re-run for the idempotency proof.

⛔ **The proof is NOT `changed=0` — that is unachievable here.** Since
`roles/deploy-stamp` shipped (#671) every tagged run rewrites a stamp file
containing a fresh `deployed_ts`, so `Stamp each role applied in this pass`
reports `changed` **by design**. A tagged deploy floors at `changed=1`.
**The criterion: the only changed task is the deploy stamp.** Any other
changed task on a second identical run is a finding.

⚠️ And a `docker_compose_v2` "Start …" that changes on a re-run is **not
automatically** the documented false drift — that case recreates *once*.
Decide it with `docker inspect -f '{{.Created}}'` across the two runs: an
unchanged timestamp is cosmetic, a new one is real recreation.

## Fleet rules that bite (full list in the vault lessons-learned)

- `--check` produces documented false drift (docker_compose_v2 restarts,
  erpnext, autofs mount chmod) — confirm every finding against the host.
- DNS records go in `bezaforge_dns_rewrites` (group_vars/all) and deploy
  with `--tags adguard,dnsmasq` — never the AdGuard UI.
- Never a public resolver in the client list; resolved does not fail back.
- Never name a Grafana dashboard subdirectory `General`.
- Prometheus target labels beat metric labels — grep `prometheus.yml`
  before adding any label to a `bezaforge_*` metric.
- Proxmox passthrough uses cluster resource mappings, never raw hostpci
  with token auth.

## Change isolation and completion

Substantial writes on an assigned task branch/worktree (`aiw worktree new
bezaforge-infrastructure <agent> <slug>`); merges to `main` are Joseph's
unless the task brief records a delegation. All host writes are human-only
(Agent Boundaries Standard). Completion = deployed + verified live +
idempotency re-run, with evidence recorded per the quality-gate standard.
