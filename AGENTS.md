# bezaforge-infrastructure — Agent Instructions

## What this repository is

The self-hosted operational backbone as infrastructure-as-code: a Proxmox
hypervisor and its VMs running git, work tracking, docs, monitoring, inference
and the ERP, plus the networking, storage and backups underneath them.
`ansible/` and `terraform/` are the substance; `docker/`, `scripts/` and `docs/`
support them.

**There is no application and no test suite. The fleet is the product**, so "it
builds" means nothing here and "it is deployed and verified live" means
everything.

## ⛔ Merged is not deployed

The single most important fact about this project, and it has recurred at least
four times. A merged pull request changes a file in git and **zero machines**.
CI stays green and nothing alerts on the gap.

```bash
cd ansible   # NEVER from the repo root — that yields a silent empty recap
ansible-playbook site.yml --tags <role> --limit <host> --ask-become-pass --ask-vault-pass
```

Both prompts make this **maintainer-run, never automated**. An automated
contributor's job is: hand over the command → verify live with read-only checks
→ have it re-run for the idempotency proof (`changed=0`). Work is not done until
all three have happened, and a merge is never reported as a deployment.

## Hard rules

- ⛔ **Never write to a `forge-*` host.** No `ansible-playbook`, no service
  restart, no file edit, no `docker compose up`. Hand over the exact command.
- ✅ **Read-only checks against live hosts are fair game** — `ssh <host>
  '<read command>'`, `curl -sI`, `docker inspect`, `systemctl status`.
  Verifying is not writing.
- ⛔ **Never touch DNS, VM lifecycle, secrets or shared git history.**
- ⛔ **One command per handover message.**
- **Codify, don't console.** A fix applied by hand on a host is unshipped work
  until it is a role. Live-only fixes have been lost to rebuilds before.
- **Secrets never enter a tracked file.**

## Traps

These are the ones hit in the first hour.

- ⚠️ **`--check` produces documented false drift on this fleet** —
  `docker_compose_v2` restarts, erpnext "Bring up", an autofs mount chmod.
  Confirm every `--check` finding against the live host before reporting drift.
- ⚠️ **`ansible-playbook` from the repo root produces a silent empty recap.**
  `cd ansible` first.
- ⛔ **DNS records go in `bezaforge_dns_rewrites` (`group_vars/all`)** and deploy
  with `--tags adguard,dnsmasq`. Never the AdGuard web UI — it reaches AdGuard
  only and is invisible to dnsmasq.
- ⛔ **Never add a public resolver to the client list.** NXDOMAIN is a valid
  answer, so resolved accepts it and never retries AdGuard — and resolved does
  not fail back, so after any AdGuard blip a host stays on the secondary
  indefinitely.
- ⛔ **Never name a Grafana dashboard subdirectory `General`.** It is Grafana's
  reserved default; the collision aborts the whole provisioning walk and imports
  nothing. That ran undetected every 30 s for 87 days.
- ⚠️ **Prometheus target labels beat metric labels.** Grep `prometheus.yml`
  before adding any label to a `bezaforge_*` metric, or it silently becomes
  `exported_<label>`.
- ⚠️ **Proxmox passthrough must use cluster resource mappings**, never raw
  `hostpci` — an API token counts as not-root and is refused.
- ⛔ **Nothing on this fleet alerts on a service being down.** Do not read a
  green host, a healthy Traefik, or "all alerts deliver" as "the service is up."

## Checks

There is no build and no repo-level test suite. The gates are:

- **CI** (GitHub Actions, `.github/workflows/ci.yml`): `yamllint`, a Grafana
  alert-rule check (`scripts/check-alert-rules.py`), `ansible-lint`, and
  `terraform fmt -check` + `terraform validate`.
- **Live verification and an idempotency re-run.** This is the real gate — see
  *Merged is not deployed*.

## Conventions

- **Mermaid is the authored source of truth for all 14 architecture diagrams**,
  superseding an earlier drawio-first arrangement. The `.drawio` siblings are
  generated. Edit the Mermaid.
- Operational runbooks live in Outline (`docs.bezaforge.dev`); work lives in
  OpenProject (`pm.bezaforge.dev`). Neither is mirrored into this repository.
- Findings start provisional and become canonical only once something verified
  them. Nothing durable is left in vendor memory or chat history — memory is a
  cache and can be wiped without warning.
- Dates are absolute. "Last week" in a durable document is a defect.

## Contributing

All work happens on a branch and lands through a pull request. Nothing is
committed or pushed directly to `main`.

Machinery and binaries belong here; long-form documentation does not, and there
are deliberately **no repo-side documentation mirrors** — they drifted, which is
why they were dropped. A decision recorded only in a chat message exists
nowhere.
