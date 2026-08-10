# Services Reference

All services run on **forge-ops** via Docker Compose.
Base path: `/opt/bezaforge/{service}/docker-compose.yml`

---

## Reverse Proxy & SSL

### Traefik v3
- **Image:** `traefik:v3`
- **Ports:** 80 (HTTP → HTTPS redirect), 443 (HTTPS). Dashboard at `traefik.bezaforge.dev` (`api.insecure: false`, basicauth via `traefik_basicauth_hash`) — no published 8080 host port
- **Config:** Static config in `traefik.yml`, dynamic config via Docker labels + the file provider (`/etc/traefik/dynamic/` for off-box routes)
- **SSL:** Per-host certs via Let's Encrypt DNS-01 (Cloudflare API) — each service router requests its own cert via the `letsencrypt` resolver (**no `*.bezaforge.dev` wildcard SAN**). `dnsChallenge.resolvers: [1.1.1.1, 8.8.8.8]` to bypass the AdGuard split-horizon SOA-walk (FORGE-22)
- **Notes:**
  - `acme.json` must be `chmod 600` or Traefik refuses to write certs
  - Use `propagation.delayBeforeChecks: 30s` (not `delayBeforeCheck`) in Traefik v3.6+
  - All services added via Docker labels — no static routing config needed

---

## DNS & Network Services

### AdGuard Home
- **Port:** 53 (DNS) on `10.10.20.20` only, 3053 → container 3000 (web UI, internal)
- **Role:** **Primary** DNS for all VLANs. Since #638 there is a **secondary**: dnsmasq on forge-hypervisor (`10.10.10.10`, `roles/dnsmasq`).
- **Key config:** wildcard rewrite `*.bezaforge.dev → 10.10.20.20` plus per-host overrides. Since #649 the rewrite table is **codified** in `bezaforge_dns_rewrites` (`group_vars/all`) and reconciled into AdGuard through its control API — add records there, not in the web UI.
- **Notes:** ⛔ **Do NOT disable `systemd-resolved`.** This line previously said the opposite; it was wrong and following it would break things. Verified live 2026-08-09: resolved is `active` + `enabled` on forge-ops and the two coexist on different addresses — AdGuard binds `10.10.20.20:53`, resolved binds only the stubs `127.0.0.53:53` / `127.0.0.54:53`. There is no conflict, and the compose file binds AdGuard to the specific IP precisely so there isn't. Disabling resolved on forge-ops would also remove what `roles/dns-client` configures there: the host's own resolution and the `bezaforge_dns_primary_in_use` metric.

---

## Observability Stack

### Prometheus
- **Image:** `prom/prometheus`
- **Scrape interval:** 15s
- **Targets:** Node Exporter (all hosts), cAdvisor (forge-ops), service-specific exporters
- **Notes:** Data directory must be `chown 65534:65534` before first start

### Grafana
- **Image:** `grafana/grafana`
- **Provisioning:** Data sources and dashboards provisioned via config files
- **Data sources:** Prometheus, Loki
- **Notes:** Data directory must be `chown 472:472` before first start

### Loki + Promtail
- **Images:** `grafana/loki`, `grafana/promtail`
- **Role:** Loki ingests logs; Promtail tails Docker container logs and ships to Loki
- **Notes:** Loki data directory must be `chown 10001:10001` before first start

### Uptime Kuma
- **Image:** `louislam/uptime-kuma`
- **Role:** HTTP/HTTPS availability monitoring with alert notifications
- **Monitors:** All services + all VMs (ping checks)

### cAdvisor
- **Image:** `gcr.io/cadvisor/cadvisor`
- **Role:** Per-container CPU/memory/network metrics → scraped by Prometheus

### Node Exporter
- **Role:** Host-level system metrics (CPU, memory, disk, network)
- **Deployed on:** forge-ops, forge-ai (systemd service on each host)

---

## Developer Tools

### Gitea
- **Image:** `gitea/gitea`
- **Role:** Self-hosted Git server (internal repos, mirrors)
- **Storage:** Persistent volume for repositories

### Outline
- **Image:** `outlinewiki/outline:1.7.1` + `postgres:15-alpine` + `redis:7-alpine`
- **Role:** Self-hosted wiki at `docs.bezaforge.dev` (replaced retired Wiki.js)
- **Auth:** Google Workspace OIDC, redirect URI `/auth/oidc.callback`
- **Storage:** Local-FS uploads at `/opt/bezaforge/outline/uploads/` (no MinIO — overkill for solo wiki use)
- **Ansible role:** `ansible/roles/outline/`

### OpenProject
- **Image:** `openproject/openproject` all-in-one (bundles Postgres + memcached + web + Rails workers under one supervisor), pinned to a release tag; Renovate tracks it
- **Role:** Self-hosted project + work tracking at `pm.bezaforge.dev` — the live work tracker (replaced Plane 2026-07, FORGE #455). Its Community REST API v3 filters server-side (unlike Plane CE), so the Claude Code integration works via the free `op-query` helper
- **Auth:** local admin (seeded on first boot); no external OIDC configured
- **Notes:** first boot is slow (~5–10 min: DB init + migrations + seeding — a 502 during that window is expected). ⚠️ **Backup gap:** data is in named volumes, not yet covered by db-dumps/rsync — a pilot-phase holdover now that this is the source of truth (FORGE #455 follow-up)
- **Ansible role:** `ansible/roles/openproject/`

### NetBox
- **Image:** `netboxcommunity/netbox`
- **Role:** IP address management, network topology documentation
- **Backend:** PostgreSQL + Redis

---

## Dashboard

### Homepage (gethomepage.dev)
- **Image:** `ghcr.io/gethomepage/homepage`
- **Role:** Unified dashboard with service status widgets
- **Notes:** Requires `HOMEPAGE_ALLOWED_HOSTS` env var set to the service domain
