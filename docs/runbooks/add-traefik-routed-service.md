# Runbook — Add a Traefik-routed Service on forge-ops

This runbook covers the steps to add a new HTTPS-routed Docker service to the BezaForge stack on forge-ops. Follow it any time you spin up a new service that should be reachable at `https://<service>.bezaforge.dev`.

For Traefik installation, configuration, or DNS challenge setup — see `docs/architecture.md` and the BezaForge Phase 1 Traefik deployment notes. This runbook assumes Traefik is already running and the wildcard cert is healthy.

---

## Prerequisites (one-time, already in place)

- Traefik v3 running on forge-ops at `/opt/bezaforge/traefik`
- Wildcard cert for `*.bezaforge.dev` issued via Let's Encrypt DNS challenge (Cloudflare provider)
- Docker network `bezaforge-net` exists as an external network
- AdGuard Home configured with a wildcard rewrite for `*.bezaforge.dev → 10.10.20.20`
- Certresolver name in Traefik config: **`letsencrypt`** (not `cloudflare`)

---

## Steps to add a new service

### 1. Choose the hostname

Pattern: `<service>.bezaforge.dev` (e.g. `langfuse.bezaforge.dev` for LangFuse, `pm.bezaforge.dev` for OpenProject).

Keep names short, lowercase, no underscores. The hostname will appear in router labels and certificate SANs (the wildcard cert covers them automatically).

### 2. Confirm AdGuard DNS coverage

The AdGuard wildcard rewrite (`*.bezaforge.dev → 10.10.20.20`) covers any new subdomain automatically. **Verify before deploying:**

```bash
# From forge-ops or laptop
dig +short <service>.bezaforge.dev
# Expected: 10.10.20.20
```

If it doesn't resolve, the wildcard rewrite has been removed or overridden. Add a specific rewrite via the AdGuard UI: **Filters → DNS rewrites → Add → `<service>.bezaforge.dev` → `10.10.20.20`**.

### 3. Place the service under `/opt/bezaforge/<service>/`

Conventions:

- `/opt/bezaforge/<service>/docker-compose.yml` — compose file
- `/opt/bezaforge/<service>/.env` — secrets (chmod 600, never committed)
- `/opt/bezaforge/<service>/data/` (or named volumes) — persistent state

The `bezaforge` LV (mounted at `/opt/bezaforge`) has dedicated capacity for service data. Use it.

### 4. Add Traefik labels to the service in `docker-compose.yml`

Reference label block — copy, paste, replace `<service>` and `<port>`:

```yaml
services:
  <service>:
    # ... your service config ...
    networks:
      - bezaforge-net
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.<service>.rule=Host(`<service>.bezaforge.dev`)"
      - "traefik.http.routers.<service>.entrypoints=websecure"
      - "traefik.http.routers.<service>.tls.certresolver=letsencrypt"
      - "traefik.http.services.<service>.loadbalancer.server.port=<port>"

networks:
  bezaforge-net:
    external: true
```

**Required label fields:**

| Label | Purpose | Notes |
|-------|---------|-------|
| `traefik.enable=true` | Opt this service into Traefik | Traefik is configured with `exposedByDefault: false` — without this label the service is invisible to Traefik |
| `traefik.http.routers.<service>.rule` | Hostname matching | Use Host(\`<service>.bezaforge.dev\`); back-ticks are required by the rule syntax |
| `traefik.http.routers.<service>.entrypoints=websecure` | Bind to :443 | `web` (port 80) is configured to redirect to `websecure` automatically |
| `traefik.http.routers.<service>.tls.certresolver=letsencrypt` | Use the wildcard cert | Resolver name is `letsencrypt`, NOT `cloudflare` |
| `traefik.http.services.<service>.loadbalancer.server.port=<port>` | Internal container port | The port the service listens on inside the container, NOT a host-exposed port |

**Do NOT publish ports externally.** Don't add a `ports:` block to the service — Traefik reaches it on the Docker network. Adding a `ports:` block bypasses Traefik and skips TLS.

### 5. Attach to `bezaforge-net`

The service must join the external `bezaforge-net` network so Traefik can reach it. Already covered in the reference block above — confirm both the service-level `networks:` and the top-level `networks:` definition are present.

### 6. Optional: header / auth middleware

Most internal services don't need auth (network isolation). Some do — e.g. the Traefik dashboard uses basic-auth. Pattern:

```yaml
labels:
  - "traefik.http.routers.<service>.middlewares=<service>-auth"
  - "traefik.http.middlewares.<service>-auth.basicauth.users=admin:$$apr1$$..."
```

Note the `$$` escaping — Compose interprets a single `$` as a variable reference.

For services with their own auth (Grafana's login, OpenProject's own auth), no middleware is needed.

### 7. Bring up the service

```bash
cd /opt/bezaforge/<service>
docker compose up -d
docker compose logs -f
```

Watch for:
- The service starts and listens on its port
- Traefik discovers the new router (visible in Traefik logs)
- No "service not enabled" or "no available server" errors

In a separate terminal, watch Traefik:

```bash
docker logs -f traefik | grep -i <service>
```

You should see Traefik attach the new router/service. If you see nothing within a few seconds, the labels didn't reach Traefik — usually a typo or a network attachment issue.

### 8. Verify

**DNS:**
```bash
dig +short <service>.bezaforge.dev
# Expected: 10.10.20.20
```

**TLS + routing (from any machine that uses AdGuard):**
```bash
curl -I https://<service>.bezaforge.dev
# Expected: 200 / 301 / 401 (any non-cert-error response means TLS + routing work)
# Cert error = wildcard cert not yet issued or expired
```

**Cert validity:**
```bash
echo | openssl s_client -servername <service>.bezaforge.dev -connect <service>.bezaforge.dev:443 2>/dev/null \
  | openssl x509 -noout -dates -issuer -subject
# Expected issuer: Let's Encrypt
# Expected subject: CN=*.bezaforge.dev
```

**Traefik dashboard:**
Open `https://traefik.bezaforge.dev` (basic-auth required). The new router and service should appear under **HTTP > Routers** and **HTTP > Services**, both green.

---

## Common gotchas

- **No `ports:` block.** Adding `ports: ["8000:8000"]` bypasses Traefik. The service should NOT be reachable from the LAN directly — only via Traefik on :443.
- **Wrong `loadbalancer.server.port`.** This is the internal container port. If your service listens on 3000 inside the container, set port=3000 — even if you'd normally map it to 8080 externally.
- **Network attachment missing.** If the service isn't on `bezaforge-net`, Traefik can't reach it. Symptom: "no available server" in Traefik logs.
- **Cert error in browser.** Usually means the AdGuard rewrite is missing — DNS resolves to a public IP that doesn't have the wildcard cert. Or the wildcard cert renewal failed (check Traefik logs for ACME errors).
- **`certresolver=cloudflare` instead of `letsencrypt`.** `cloudflare` is the DNS challenge **provider** (set in static config); `letsencrypt` is the **resolver name** used by service labels. Mixing them produces `unknown certificate resolver` errors.
- **Compose `version:` field.** Older guides include `version: "3.8"`. Modern Docker Compose ignores it and warns. Safe to omit on new services.
- **Variable escaping in basic-auth.** Single `$` in label values gets eaten by Compose. Always double them: `$$apr1$$...`
- **Labels on the wrong service.** In a multi-service compose file, labels go on the service that should be exposed — not on a sidecar. For Outline (three services), the labels are only on `outline`, never on the internal `outline-db`/`outline-redis` sidecars.

---

## Removing a routed service

```bash
cd /opt/bezaforge/<service>
docker compose down
# Optionally: rm -rf /opt/bezaforge/<service>/  (only after backing up persistent data)
```

Traefik unloads the router automatically when the container disappears. No Traefik config changes needed.

If the hostname had a specific (non-wildcard) AdGuard rewrite, remove it from the AdGuard UI as well.

---

## Troubleshooting checklist

When a new service isn't reachable:

1. `docker compose ps` — service running?
2. `docker compose logs <service>` — listening on the port you labeled?
3. `docker network inspect bezaforge-net` — is the service attached?
4. `docker logs traefik | grep <service>` — did Traefik see the labels?
5. `dig +short <service>.bezaforge.dev` — DNS resolving to forge-ops?
6. `curl -k https://<service>.bezaforge.dev` — bypass cert check; does anything respond?
7. Traefik dashboard — router + service both green?
8. `docker exec traefik wget -O- http://<service>:<port>/` — can Traefik reach the service from inside its container?

If 1–4 pass but 5–6 fail: DNS or cert problem.
If 1–4 fail: labels or network problem.

---

## See also

- `docs/architecture.md` — overall network topology and service map
- BezaForge Phase 1 Traefik guide (vault) — initial Traefik deployment, Cloudflare DNS challenge setup, dashboard auth configuration
- `/opt/bezaforge/traefik/config/traefik.yml` on forge-ops — live static config
- `/opt/bezaforge/traefik/config/dynamic/middleware.yml` on forge-ops — shared middleware definitions
