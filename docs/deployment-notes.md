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

### Harbor — Traefik Label Placement
Labels must go on the `proxy` service (nginx), not the `core` service.
Proxy listens on port 8080 internally (not 8085).
Verify with: `docker inspect nginx | grep -A5 Labels`

### Taiga — RabbitMQ Service Name
The RabbitMQ container MUST be named `taiga-async-rabbitmq`.
This name is hardcoded in Taiga's internal config. Any other name breaks async operations silently.

### Homepage — Allowed Hosts
Requires explicit env var or it refuses connections:
```yaml
environment:
  HOMEPAGE_ALLOWED_HOSTS: home.bezaforge.dev
```

---

## forge-dev (Arch Linux VM)

### qemu-guest-agent on Arch
The `qemu-guest-agent` package on Arch Linux is missing the `[Install]` section in its systemd unit.
`systemctl enable qemu-guest-agent` fails without a drop-in override:

```bash
mkdir -p /etc/systemd/system/qemu-guest-agent.service.d/
cat > /etc/systemd/system/qemu-guest-agent.service.d/override.conf << 'EOF'
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now qemu-guest-agent
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
