# Ansible Role: engram

**Status:** 🚧 STUB — interface documented, tasks not yet written.

## Lifecycle

This role lands at the end of Engram's build track (after Phase 6 of the Engram phase guides produces a verifiable artifact in `~/engram-dev/` on forge-ops). Until then this README documents the intended interface so the rest of BezaForge has visibility into what's coming.

Real implementation work happens during **Engram Phase 7 — Integration & Launch**. See `05_Projects/engram/implementation/08_Phase-7-Integration-Launch.md` (vault) for the rollout sequence.

## What this role will do

Deploy the Engram public artifact (the engram repo) to forge-ops at `/opt/bezaforge/engram/`, register it with Traefik for `https://engram.bezaforge.dev`, and schedule nightly backups.

The role is a **thin wrapper** around the build artifact. All substance — Docker Compose, Dockerfiles, source code, migrations, backup scripts — lives in the engram repo. The role only handles "where does this run on forge-ops, how does it get its secrets, how is it routed."

## Intended Tags

| Tag | What it does |
|-----|--------------|
| `preflight` | Ensure `/opt/bezaforge/engram/` exists with correct ownership; ensure `bezaforge-net` Docker network exists |
| `clone` | Clone the engram repo at a pinned ref (release tag or commit SHA) into `/opt/bezaforge/engram/` |
| `secrets` | Render `.env` from `host_vars/forge-ops/vault.yml` using ansible-vault encrypted values |
| `services` | `docker compose pull && docker compose up -d` from `/opt/bezaforge/engram/` |
| `migrations` | Run Alembic upgrade against the production Postgres (`docker compose exec` or one-shot container) |
| `backup` | Install nightly cron / systemd timer that calls `/opt/bezaforge/engram/scripts/backup.sh` |
| `verify` | curl `https://engram.bezaforge.dev/healthz` and assert all-ok |

## Defaults (planned)

```yaml
# defaults/main.yml (not yet written)
engram_install_path: /opt/bezaforge/engram
engram_repo_url: https://gitea.bezaforge.dev/joseph/engram.git
engram_repo_ref: main          # change to v0.0.1 once tagged
engram_owner: joseph
engram_group: joseph
engram_compose_profiles: []
engram_backup_hour: 3          # nightly cron hour
engram_backup_minute: 0
```

## Vault variables required (planned)

These go in `host_vars/forge-ops/vault.yml` (ansible-vault encrypted) when this role is implemented:

```yaml
# host_vars/forge-ops/vault.yml (additions)
engram_auth_token: <openssl rand -hex 32>
engram_postgres_password: <strong random>
engram_neo4j_password: <strong random>
```

The dev `.env` Joseph generates locally during Engram Phase 0 is **separate** from these production secrets. The Ansible role never reads dev secrets; it always renders from the vault.

## Dependencies

- `common` role (basic forge-ops hardening)
- `docker` role (Docker daemon + `bezaforge-net` network)
- `traefik` role (must be running on forge-ops; Engram registers via labels)

## Idempotency

The role MUST be idempotent. Running `ansible-playbook ... --tags engram` twice in a row should produce zero changes on the second run. This is a hard requirement.

## What this role does NOT do

- **Build Engram source code.** The role consumes the artifact as-is from the repo.
- **Manage the Engram database schema directly.** Alembic migrations are invoked, not authored, by the role.
- **Open firewall ports between VLANs.** Production access is via Traefik DNS (`engram.bezaforge.dev`), not by per-host firewall rules to a port. AdGuard wildcard rewrite handles DNS.
- **Manage MCP client configuration.** Per-client (Claude Code, Gemini CLI, Codex CLI, OpenClaw) MCP wiring is documented in Engram Phase 7 Steps 2–5 and lives outside this role.

## When to write the tasks

Trigger to start writing real tasks: **Engram Phase 6 of the build track is verifiable in `~/engram-dev/` on forge-ops** — i.e., the gateway, watcher, worker, and MCP server are all up and the contract smoke tests pass.

Until then, this stub is the BezaForge-side anchor that Engram exists in the deployment plan.

## Related docs

- Engram build phases: `05_Projects/engram/implementation/01_Phase-0-Preflight.md` through `08_Phase-7-Integration-Launch.md` (vault)
- Engram Master Implementation Guide: `05_Projects/engram/implementation/00_Master-Implementation-Guide.md` — see §4 (Two-Track Architecture) for the build/deploy split this role implements
- BezaForge Master Roadmap: `05_Projects/bezaforge-infrastructure/01_Master-Roadmap.md` — see the URGENT block at the top
