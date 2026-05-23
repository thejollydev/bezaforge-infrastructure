# Runbook — Secret rotation policy

**Audience:** Joseph, or any future operator with `--ask-vault-pass` access.

**Status:** Policy v1 — 2026-05-17. This is a *floor* — nothing here is automated yet (HashiCorp Vault would automate; see Phase 2 guide 04). The point of the runbook is to make rotation a known, scheduled, repeatable thing rather than a never-thing.

---

## Why rotate at all

Three reasons:

1. **Limit blast radius if a secret leaks.** A leaked password that gets rotated quarterly is a 0–90-day exposure window. A leaked password that never rotates is exposed forever.
2. **Force the recovery path to stay healthy.** If you've never rotated `gitea_db_password`, then you don't know whether the rotation actually works — until you need it to, in an incident. Routine rotation is a continuous test of the rotation procedure itself.
3. **Compliance/professional habit.** Most production-grade orgs require it. Building the habit now while the homelab is small is cheaper than retrofitting it.

---

## Cadence — by secret class

| Class | Cadence | Trigger to rotate ahead of schedule |
|-------|---------|-------------------------------------|
| **Internal service DB passwords** (Postgres, RabbitMQ users for self-hosted services) | Annual | Suspected compromise; departing operator; container image CVE in the DB engine |
| **External-scope API tokens** (Cloudflare, GCS service account, future GitHub PAT) | 90 days | Suspected compromise; provider revocation; principle of least privilege change |
| **App framework secrets** (`*_SECRET_KEY`, `NEXTAUTH_SECRET`, `API_TOKEN_PEPPERS`) | Annual | Suspected compromise (rotates session tokens — forces re-login everywhere) |
| **Admin UI passwords** (Grafana, AdGuard, NetBox superuser) | Annual | Suspected compromise; password manager audit flagged weak |
| **Restic repo password** (`vault_restic_password`) | **Never under routine** | Suspected compromise only. Rotation requires re-encrypting the entire restic repo — high-effort + creates a window without an off-site backup. Treat as a long-lived secret with a Bitwarden audit trail. |
| **Restic GCS service-account JSON** (`vault_gcs_credentials_json`) | 90 days (the key, not the SA) | Suspected compromise; SA permission scope change |
| **TLS certs** (Let's Encrypt via Traefik) | Auto (~60d) | Renewal failure (Cloudflare DNS-01 API token expired) |
| **SSH host keys** | **Never under routine** | Host re-built; suspected compromise of the host (then full re-key + known-hosts cleanup across all clients) |
| **SSH user keys** (Joseph's `~/.ssh/`) | When practical (every ~2 years) | Workstation compromise; key algorithm deprecation |
| **ansible-vault password** | Annual | Workstation compromise; password manager audit |

---

## Secret inventory — current vault

The following secret variable names appear in templates under `ansible/roles/*/templates/*.j2`. Each name is the Ansible variable consumed at render time — the actual encrypted value lives in one of the `vault.yml` files listed in the **Stored in** column.

| Variable | Class | Stored in | Used by | Last rotated |
|----------|-------|-----------|---------|--------------|
| `gitea_db_password` | Internal DB | `host_vars/forge-ops/vault.yml` | Gitea Postgres | — (initial) |
| `taiga_db_password` | Internal DB | `host_vars/forge-ops/vault.yml` | Taiga Postgres | Removed 2026-05-22 (Taiga retired — replaced by Plane per guide 12) |
| `taiga_rabbitmq_password` | Internal DB | `host_vars/forge-ops/vault.yml` | Taiga RabbitMQ | Removed 2026-05-22 (Taiga retired) |
| `taiga_secret_key` | App framework | `host_vars/forge-ops/vault.yml` | Taiga Django `SECRET_KEY` | Removed 2026-05-22 (Taiga retired) |
| `wiki_db_password` | Internal DB | `host_vars/forge-ops/vault.yml` | Wiki.js Postgres | Removed 2026-05-17 (Wiki.js retired — replaced by Outline per guide 12) |
| `outline_db_password` | Internal DB | `host_vars/forge-ops/vault.yml` | Outline Postgres (referenced in `roles/outline/templates/env.j2` + interpolated into compose for the postgres service) | — (initial 2026-05-22) |
| `outline_secret_key` | App framework | `host_vars/forge-ops/vault.yml` | Outline `SECRET_KEY` (session signing) | — (initial 2026-05-22) |
| `outline_utils_secret` | App framework | `host_vars/forge-ops/vault.yml` | Outline `UTILS_SECRET` (sub-token signing) | — (initial 2026-05-22) |
| `outline_oidc_client_id` | OIDC config (not sensitive) | `host_vars/forge-ops/vault.yml` | Outline OIDC client ID (Google Workspace OAuth client — IDs are public; stored in vault for templating convenience, not secrecy) | — (initial 2026-05-22) |
| `outline_oidc_client_secret` | External-scope OIDC | `host_vars/forge-ops/vault.yml` | Outline OIDC client secret (Google Workspace OAuth) | — (initial 2026-05-22) |
| `plane_db_password` | Internal DB | `host_vars/forge-ops/vault.yml` | Plane Postgres | — (initial 2026-05-22) |
| `plane_rabbitmq_password` | Internal DB | `host_vars/forge-ops/vault.yml` | Plane RabbitMQ | — (initial 2026-05-22) |
| `plane_secret_key` | App framework | `host_vars/forge-ops/vault.yml` | Plane Django `SECRET_KEY` | — (initial 2026-05-22) |
| `plane_live_server_secret_key` | App framework | `host_vars/forge-ops/vault.yml` | Plane live-server (websocket) shared secret | — (initial 2026-05-22) |
| `plane_minio_access_key` | Internal credential | `host_vars/forge-ops/vault.yml` | Plane bundled MinIO access key (internal — Plane is its only client) | — (initial 2026-05-22) |
| `plane_minio_secret_key` | Internal credential | `host_vars/forge-ops/vault.yml` | Plane bundled MinIO secret key (internal — Plane is its only client) | — (initial 2026-05-22) |
| `netbox_db_password` | Internal DB | `host_vars/forge-ops/vault.yml` | NetBox Postgres | — (initial) |
| `netbox_secret_key` | App framework | `host_vars/forge-ops/vault.yml` | NetBox Django `SECRET_KEY` | — (initial) |
| `netbox_superuser_password` | Admin UI | `host_vars/forge-ops/vault.yml` | NetBox superuser login | — (initial) |
| `netbox_api_token_peppers` | App framework | `host_vars/forge-ops/vault.yml` | NetBox API token pepper | — (initial) |
| `langfuse_db_password` | Internal DB | `host_vars/forge-ops/vault.yml` | Langfuse Postgres | — (initial) |
| `langfuse_nextauth_secret` | App framework | `host_vars/forge-ops/vault.yml` | Langfuse `NEXTAUTH_SECRET` (session signing) | — (initial) |
| `homepage_jellyfin_api_key` | Internal API | `host_vars/forge-ops/vault.yml` | Homepage widget → Jellyfin | — (initial) |
| `homepage_kavita_password` | Internal API | `host_vars/forge-ops/vault.yml` | Homepage widget → Kavita | — (initial) |
| `homepage_qbittorrent_password` | Internal API | `host_vars/forge-ops/vault.yml` | Homepage widget → qBittorrent | — (initial) |
| `grafana_admin_password` | Admin UI | `host_vars/forge-ops/vault.yml` | Grafana initial admin password | — (initial) |
| `cloudflare_dns_api_token` | External-scope API | `host_vars/forge-ops/vault.yml` | Traefik DNS-01 challenge | — (initial) |
| `vault_restic_password` | Backup encryption | `host_vars/forge-hypervisor/vault.yml` | restic repo encryption | — (initial 2026-05-17) |
| `vault_gcs_credentials_json` | External-scope API | `host_vars/forge-hypervisor/vault.yml` | restic GCS service account | — (initial 2026-05-17) |

> **"— (initial)"** means the value has been in place since the variable was first defined and has never been rotated. **All Phase 1 / early Phase 2 secrets share this status as of 2026-05-17.** First annual rotation pass is due 2027-02 (one year after Phase 1 service deployment 2026-02-23) for internal DBs + admin UIs.

**Not in vault — UI-managed (rotate via the service's own UI):**

- AdGuard Home admin password (web UI → Settings → Users)
- ERPNext admin password
- Jellyfin admin password
- Kavita admin password
- qBittorrent web UI password
- NetBox superuser is `netbox_superuser_password` above *for initial seed only* — subsequent rotation is done in the NetBox UI.
- **Outline:** sign-in is Google Workspace OIDC only — no local admin accounts to rotate. Outline OIDC client config (`outline_oidc_client_id` + `outline_oidc_client_secret`) IS in ansible-vault (see inventory above) and is rotated via Google Cloud Console + ansible-vault edit.
- **Plane:** sign-in is Google OAuth only — no local admin accounts to rotate. Plane's Google OAuth client_id + client_secret are **NOT in ansible-vault** — they live in Plane's Postgres `instance_configurations` table, entered through Plane's god-mode UI on initial setup. Rotate via Google Cloud Console (issue new client secret) + Plane god-mode UI (paste the new secret). The `IS_GOOGLE_ENABLED` seed task in `roles/plane/tasks/main.yml` only sets the toggle row — it does not store credentials.

---

## Rotation procedure — by class

### Internal DB password (Postgres, RabbitMQ)

Pattern (example: `gitea_db_password`):

```bash
# 1. Generate new password (pick one, save to Bitwarden under "gitea_db_password")
openssl rand -base64 32 | tr -d '/+=' | head -c 32 ; echo

# 2. Update inside the running container BEFORE updating Ansible — if step 4
#    fails the password mismatch only affects the container restart, not
#    config drift.
ssh -t joseph@10.10.20.20
docker exec -it gitea-db psql -U gitea -c "ALTER USER gitea WITH PASSWORD '<new>';"
exit

# 3. Edit the vault file
cd ~/Projects/bezaforge-infrastructure
ansible-vault edit ansible/inventory/host_vars/forge-ops/vault.yml --ask-vault-pass
# update the gitea_db_password: value to <new>

# 4. Re-render compose + restart so the application picks up the new password
ansible-playbook -i ansible/inventory ansible/site.yml \
    --tags services --limit forge-ops \
    --ask-become-pass --ask-vault-pass

# 5. Verify
curl -fsSL -o /dev/null -w "%{http_code}\n" https://git.bezaforge.dev   # 200
docker logs gitea --tail 50 | grep -iE "error|fatal"                     # empty

# 6. Update "Last rotated" column in this runbook + commit
```

**Why update the DB first, then Ansible:** If you flip Ansible first then the DB, the application will run for 2–30 minutes (until the compose redeploy) with the wrong cached password and you'll get auth errors in the logs that look like an incident. DB-first → Ansible avoids the window.

### External-scope API token (Cloudflare, GCS)

1. Generate the new token in the provider UI **with the same scope** as the existing one. Don't delete the old token yet.
2. `ansible-vault edit` the variable.
3. `ansible-playbook` with the relevant tag (e.g., `--tags traefik` for Cloudflare).
4. Verify the new token works (Traefik: tail logs for the next ACME renewal attempt; GCS: `restic snapshots` from forge-hypervisor — should succeed).
5. **Then** revoke the old token in the provider UI.
6. Update "Last rotated" + commit.

### App framework secret (`*_SECRET_KEY`, `NEXTAUTH_SECRET`, `*_PEPPERS`)

These sign cookies/sessions/tokens. **Rotating invalidates all existing sessions** — everyone gets logged out, all API tokens issued before rotation are dead.

1. Coordinate the timing (no users mid-task; for Joseph-only services this is a non-issue).
2. Generate new value (`openssl rand -hex 64` for `SECRET_KEY`-style values).
3. `ansible-vault edit`.
4. `ansible-playbook` → container restart.
5. Re-login to every affected service.
6. Re-issue any API tokens that were in use (e.g., NetBox API tokens for Prometheus scraping).

### `vault_restic_password` (backup encryption)

**Don't rotate routinely.** If you must:

1. Initialize a **new** restic repo in a new GCS bucket prefix with the new password.
2. Run a full backup pass into the new repo.
3. Verify a restore works from the new repo.
4. Keep the old repo for the retention window (6 months per current policy), then delete the bucket prefix.
5. Update the ansible-vault var to the new password + redeploy the `restic-gcs` role pointing at the new bucket prefix.

### `vault_gcs_credentials_json` (GCS service-account key)

The service account itself is long-lived; only the JSON key rotates:

1. In Google Cloud console → IAM → Service accounts → `restic@bezaforge-backups.iam.gserviceaccount.com` (or whatever the SA is) → Keys → **Add key** → JSON.
2. `ansible-vault edit` the variable; paste the new JSON.
3. `ansible-playbook --tags restic-gcs --limit forge-hypervisor`.
4. Verify with `sudo restic -r gs:bezaforge-backups-<id>:/ snapshots` on forge-hypervisor.
5. **Then** in Google Cloud console, delete the old key.

### `ansible-vault` password itself

```bash
ansible-vault rekey ansible/inventory/host_vars/forge-ops/vault.yml
ansible-vault rekey ansible/inventory/host_vars/forge-hypervisor/vault.yml
# Confirm by opening each file
ansible-vault view ansible/inventory/host_vars/forge-ops/vault.yml
```

Save the new password in Bitwarden (entry: "BezaForge ansible-vault password"). Do not commit the password anywhere.

---

## Schedule

| When | What |
|------|------|
| 2027-02 | First annual pass — all "Internal DB" + "App framework" + "Admin UI" rows |
| 2026-08-17 (90d after restic ship) | First `vault_gcs_credentials_json` rotation |
| 2026-08-17 (90d after Cloudflare token issuance) | First `cloudflare_dns_api_token` rotation (verify last-issued date — may already be older) |
| Continuous | Update "Last rotated" column above + commit, every time a rotation lands |

A simple way to keep the schedule honest: drop a calendar reminder for each annual pass + each quarterly external-token pass. When the calendar fires, this runbook is the procedure.

---

## Audit script idea (future)

A small script that:
1. Parses this runbook's secret inventory table to get the list of variables + "Last rotated" dates.
2. Flags any row where (today - last_rotated) > cadence.
3. Optionally posts the overdue list to a Discord/email webhook.

Not built. The honest "audit" today is: open this runbook, look at the dates, see if any are older than the cadence column.

When HashiCorp Vault (Phase 2 guide 04) is in, all of this becomes pull-from-Vault + Vault enforces TTLs natively — but ansible-vault + a written runbook is the floor while we get there.
