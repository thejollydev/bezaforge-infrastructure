# Services Reference

All services run on **forge-ops** via Docker Compose.
Base path: `/opt/bezaforge/{service}/docker-compose.yml`

---

## Reverse Proxy & SSL

### Traefik v3
- **Image:** `traefik:v3`
- **Ports:** 80 (HTTP → HTTPS redirect), 443 (HTTPS), 8080 (dashboard, internal only)
- **Config:** Static config in `traefik.yml`, dynamic config via Docker labels
- **SSL:** Wildcard cert `*.bezaforge.dev` via Let's Encrypt DNS-01 (Cloudflare API)
- **Notes:**
  - `acme.json` must be `chmod 600` or Traefik refuses to write certs
  - Use `propagation.delayBeforeChecks: 30s` (not `delayBeforeCheck`) in Traefik v3.6+
  - All services added via Docker labels — no static routing config needed

---

## DNS & Network Services

### AdGuard Home
- **Port:** 53 (DNS), 3000 (web UI, internal)
- **Role:** Authoritative DNS for all VLANs
- **Key config:** Wildcard rewrite `*.bezaforge.dev → 10.10.20.20`
- **Notes:** Must disable `systemd-resolved` before deployment (conflicts on port 53)

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
- **Deployed on:** forge-ops, forge-ai, forge-dev (systemd service on each host)

---

## Developer Tools

### Gitea
- **Image:** `gitea/gitea`
- **Role:** Self-hosted Git server (internal repos, mirrors)
- **Storage:** Persistent volume for repositories

### Harbor
- **Image:** `goharbor/harbor`
- **Role:** Private container registry with vulnerability scanning
- **Notes:** Traefik labels go on the `proxy` service (nginx) at port 8080, NOT the `core` service

### Wiki.js
- **Image:** `requarks/wiki`
- **Role:** Internal technical documentation
- **Storage:** PostgreSQL backend

### Taiga
- **Image:** `taigaio/taiga-*` (multi-container)
- **Role:** Agile project management (sprints, backlog, kanban)
- **Notes:**
  - RabbitMQ service MUST be named `taiga-async-rabbitmq` (hardcoded in Taiga)
  - `EVENTS_PUSH_BACKEND_URL` is required in taiga-back or all writes return 500

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
