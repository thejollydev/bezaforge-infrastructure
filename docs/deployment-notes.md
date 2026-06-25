# Deployment Notes & Lessons Learned

Real issues encountered during deployment and how they were resolved.
This serves as a runbook for future rebuilds and as reference for common edge cases.

---

## Proxmox

### GPU Passthrough — Reset Bug
**Symptom:** After stopping forge-ai VM, the RX 7900 XT enters a dirty state.
On next VM start: `amdgpu: probe of 0000:01:00.0 failed with error -22` and no `/dev/dri/` devices appear in the VM.

**Root cause:** AMD GPU reset bug — the GPU doesn't fully reset when the VM stops.

**Fix:** Reboot forge-hypervisor (full host reboot, not just VM restart).

**Prevention:** Always use `qm reboot 101` instead of `qm stop 101` followed by `qm start 101`.
Never use the "Stop" button in Proxmox UI for forge-ai — use "Reboot" only.

### IOMMU Configuration
Required kernel parameters on forge-hypervisor (`/etc/default/grub`):
```
GRUB_CMDLINE_LINUX_DEFAULT="quiet amd_iommu=on iommu=pt"
```
Also requires adding `vfio`, `vfio_iommu_type1`, `vfio_pci`, `vfio_virqfd` to `/etc/modules`.

---

## ROCm on Ubuntu 24.04

**Install sequence matters:**
1. Install `linux-headers-$(uname -r)` and `linux-modules-extra-$(uname -r)` FIRST
2. Download and install `amdgpu-install_7.2.70200-1_all.deb` (sets up AMD repos)
3. Run `amdgpu-install --usecase=rocm`
4. Install `rocm` package
5. Reboot
6. Add user to `render` and `video` groups

**Verification:** `ollama ps` — the Processor column is the definitive check.
`rocminfo` showing only CPU = GPU driver failed to init (not a ROCm config issue).

---

## Traefik v3

### DNS-01 Challenge Config (v3.6+)
```yaml
# CORRECT:
propagation:
  delayBeforeChecks: 30s

# WRONG (v2 syntax, silently fails in v3.6+):
delayBeforeCheck: 30
```

### acme.json Permissions
```bash
chmod 600 /opt/bezaforge/traefik/acme.json
```
Traefik refuses to read/write certs if permissions are wrong. No error — certs just never issue.

### Cloudflare Orphaned DNS Records
If cert issuance fails and you retry, Cloudflare may have a stale `_acme-challenge` TXT record.
Delete it manually in Cloudflare DNS before retrying.

---

## Docker Services

### Prometheus / Grafana / Loki — File Ownership
Data directories must be owned by specific UIDs before first container start:
```bash
chown -R 65534:65534 /opt/bezaforge/prometheus/data   # nobody
chown -R 472:472     /opt/bezaforge/grafana/data       # grafana
chown -R 10001:10001 /opt/bezaforge/loki/data          # loki
```
Containers will fail silently or with misleading errors without this.

### AdGuard Home — Port 53 Conflict
`systemd-resolved` listens on port 53 by default. Must disable before AdGuard:
```bash
systemctl stop systemd-resolved
systemctl disable systemd-resolved
```

### Plane — Caddy parser quirk + IS_GOOGLE_ENABLED seed
Upstream Plane v1.3.1's `plane-proxy` (Caddy) crashes parsing the global block if `CERT_ACME_CA` is an empty string (which the compose's `:-` default produces), even when `SITE_ADDRESS=:80` means plain HTTP only.
Set `CERT_ACME_CA` to the Let's Encrypt default URL in `.env` — never invoked, satisfies the parser.

Plane v1.3.1 also has [makeplane/plane#8679](https://github.com/makeplane/plane/issues/8679) — `IS_GOOGLE_ENABLED` row missing from the `instance_configurations` table on fresh init, so god-mode toggle silently no-ops. Fix codified in `ansible/roles/plane/tasks/main.yml` as an idempotent `INSERT ... ON CONFLICT DO NOTHING` via `community.docker.docker_container_exec`. Remove once upstream PR #8740 merges and we bump.

### Plane — Google OAuth redirect URI (trailing slash)
Plane v1.3.1 sends `https://plane.bezaforge.dev/auth/google/callback/` (**with trailing slash**) — official Plane docs omit the slash, which produces `redirect_uri_mismatch` from Google. Register both variants (slash + no-slash + mobile) in GCP. See `~/.claude/projects/.../memory/reference_plane_oauth_callback_urls.md`.

### Homepage — Allowed Hosts
Requires explicit env var or it refuses connections:
```yaml
environment:
  HOMEPAGE_ALLOWED_HOSTS: home.bezaforge.dev
```

---

## Networking

### forge-ops SSH Access — ufw
ufw on forge-ops only allows SSH from specific subnets.
If locked out from a new IP: ProxyJump through forge-hypervisor:
```bash
ssh -J root@<hypervisor-ip> joseph@<forge-ops-ip>
```
Then add the new source IP to ufw.
