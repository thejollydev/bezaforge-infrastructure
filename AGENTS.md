# bezaforge-infrastructure — Agent Contract

Read by every agent. Claude Code, Codex and Antigravity all read this file;
`CLAUDE.md` beside it is subordinate and carries only Claude-specific notes.
Machine-wide conventions live in `~/.claude/CLAUDE.md`.

## What this repository is

The self-hosted operational backbone for BezaCore Labs as infrastructure-as-code:
a Proxmox hypervisor and its VMs running git, work tracking, docs, monitoring,
inference and the ERP, plus the networking, storage and backups underneath them.
`ansible/` and `terraform/` are the substance; `docker/`, `scripts/` and `docs/`
support them.

**There is no application and no test suite. The fleet is the product**, so "it
builds" means nothing here and "it is deployed and verified live" means
everything.

## Mandatory startup

The vault holds the work; this repository holds the product. Plans, decisions,
runbook history, lessons and session logs live in the BezaForge Infrastructure
workspace of the `never-knowledge` vault, not here.

```bash
never4ga --actor <client>/<model> context startup --client <client> --cwd "$PWD"
never4ga workspace resolve --path "$PWD"    # this repository -> its workspace
```

`--actor` is a **global** flag and goes before the subcommand. Name yourself
properly — `claude-code/claude-opus-5`, not `claude-code` — because anything you
write records you as its producer.

Then read, in the workspace: `Context/agent-context.md`, `Context/charter.md`,
and **`Research/lessons-learned.md` before touching the fleet** — every line
there is a paid incident with a work-item number.

Without Never4gA available the vault is at `~/Vaults/never-knowledge` and the
workspace at `10_Workspaces/BezaCore-Labs/Workspaces/BezaForge-Infrastructure/`.
Read the same files by path. If the vault is unreachable, say so rather than
guessing at project state.

## ⛔ Merged is not deployed

The single most important fact about this project, and it has recurred at least
four times. A merged pull request changes a file in git and **zero machines**.
CI stays green and nothing alerts on the gap.

```bash
cd ansible   # NEVER from the repo root — that yields a silent empty recap
ansible-playbook site.yml --tags <role> --limit <host> --ask-become-pass --ask-vault-pass
```

Both prompts make this **Joseph-run, never agent-run**. The agent's job is:
hand over the command → verify live with read-only checks → have him re-run for
the idempotency proof (`changed=0`). Work is not done until all three have
happened, and a merge is never reported as a deployment.

## Hard rules

- ⛔ **Never write to a `forge-*` host.** No `ansible-playbook`, no service
  restart, no file edit, no `docker compose up`. Hand over the exact command.
- ✅ **Read-only checks against live hosts are your own job** — `ssh <host>
  '<read command>'`, `curl -sI`, `docker inspect`, `systemctl status`.
  Verifying is not writing.
- ⛔ **Never touch DNS, VM lifecycle, secrets or shared git history.**
- ⛔ **One command per handover message.** The `!` prompt takes exactly one.
  Never wrap a remote command as `ssh host '…'` for pasting — no TTY, and it
  mangles.
- **Codify, don't console.** A fix applied by hand on a host is unshipped work
  until it is a role. Live-only fixes have been lost to rebuilds before.
- **Secrets never enter the vault**, and never a tracked file here.

## Traps

The full list is `Research/lessons-learned.md` in the workspace and is not
duplicated here. These are the ones hit in the first hour:

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
- ⛔ **Nothing on this fleet alerts on a service being down** (open item #676).
  Do not read a green host, a healthy Traefik, or "all alerts deliver" as "the
  service is up."
- ⚠️ **`git remote get-url --all origin` returns *fetch* URLs — GitHub only.**
  One fetch remote, three push remotes. Use `--push --all` for anything that
  iterates remotes.
- ⚠️ **`gh pr merge --delete-branch` deletes on GitHub only.** Gitea and GitLab
  keep the branch.

## Checks

There is no build and no repo-level test suite. The gates are:

- **CI** (GitHub Actions, `.github/workflows/ci.yml`): `yamllint`, a Grafana
  alert-rule check (`scripts/check-alert-rules.py`), `ansible-lint`, and
  `terraform fmt -check` + `terraform validate`.
- **Live verification and an idempotency re-run.** This is the real gate — see
  *Merged is not deployed*.
- `Plans/quality-plan.md` in the workspace holds the gate-by-gate detail.

## Conventions

- **Mermaid is the authored source of truth for all 14 architecture diagrams**
  (ADR 0008, 2026-06-25, superseding the drawio-first lock). The `.drawio`
  siblings are generated. Edit the Mermaid.
- Ground hardware and rack facts in the workspace's `Architecture/architecture.md`;
  ground IP, VLAN and firewall facts in its `Resources/ip-allocation.md`.
- Facts land in the vault; operational runbooks land in Outline
  (`docs.bezaforge.dev`); work lands in OpenProject (`pm.bezaforge.dev`).
  Neither Outline nor the tracker is mirrored into the vault or this repository.
- Findings start provisional and become canonical only once something verified
  them. Nothing durable is left in vendor memory or chat history — memory is a
  cache and can be wiped without warning.
- Dates are absolute. "Last week" in a durable document is a defect.

## Branching

All work happens on a branch and lands through a pull request. Never commit
directly to `main`, and never push to `main`.

One `origin` pushes to three hubs — GitHub, GitLab and Gitea at
`git.bezaforge.dev:2222` — and `main` must be the same commit on all three. Open
the pull request on GitHub, which is the fetch remote; the merge propagates on
the next `git push origin`.

**Never add an AI as co-author**, and never leave any other trace of AI
involvement in a commit message, pull request or document.

## The vault holds the work

Documentation belongs in the workspace, machinery and binaries belong here, and
there are deliberately **no repo-side documentation mirrors** — they drifted,
which is why they were dropped. A decision recorded only in a chat message
exists nowhere.
