# Deployment Notes & Lessons Learned

Real issues encountered during deployment and how they were resolved.
This serves as a runbook for future rebuilds and as reference for common edge cases.

---

## Proxmox

### GPU Passthrough — Reset Behaviour

> ❌ **CORRECTED 2026-08-04 (#617).** This section previously stated the RX 7900 XT could not
> be reset without a full host reboot, and instructed: *"Always use `qm reboot 101` instead of
> `qm stop 101`… Never use the Stop button."* **That is false on this board, and following it
> would block the shared-GPU design entirely.** Superseded text retained below for the record.

**Measured behaviour (proven end-to-end 2026-07-31):** the card can be handed **VM → VM with no
host reboot**. Full cycle verified: forge-ai → release → a different VM (`amdgpu` bound, HDMI audio
attached) → release → forge-ai, ending with a 16 GB model resident at **100% GPU**.

This was genuinely in doubt — `0000:2f:00.0` advertises **no FLR** (`reset_method` = `bus` only),
`vendor-reset` does not support the 7000 series, and community reports for RDNA3 under VFIO are
mostly negative. Reset behaviour is board/BIOS/kernel specific, and this board (MSI X570 Tomahawk /
Ryzen 7 5800X / PVE 9.x) handles it: Proxmox's FLR attempt fails, then **vfio-pci performs its own
secondary-bus reset**, which succeeds.

⚠️ **Expect this on every start of every VM holding the card, including healthy ones — it is benign:**
```
error writing '1' to '/sys/bus/pci/devices/0000:2f:00.0/reset': Inappropriate ioctl for device
failed to reset PCI device '0000:2f:00.0', but trying to continue as not all devices need a reset
```
Do not chase it. vfio-pci's `resetting → reset done` lines that follow are the real outcome.

**The actual constraint is mutual exclusion, not reboots.** Only one VM may hold `0000:2f:00` at a
time (forge-ai `101` / forge-arcade `105`). Stopping forge-ai to hand the card over is **correct and
supported** — it is the intended workflow, not a hazard.

<details>
<summary>Superseded text (pre-2026-08-04) — do not follow</summary>

> **Symptom:** After stopping forge-ai VM, the RX 7900 XT enters a dirty state.
> On next VM start: `amdgpu: probe of 0000:01:00.0 failed with error -22` and no `/dev/dri/` devices appear in the VM.
> *(Note: `0000:01:00.0` was itself wrong — the card is at `0000:2f:00.0`.)*
>
> **Root cause:** AMD GPU reset bug — the GPU doesn't fully reset when the VM stops.
>
> **Fix:** Reboot forge-hypervisor (full host reboot, not just VM restart).
>
> **Prevention:** Always use `qm reboot 101` instead of `qm stop 101` followed by `qm start 101`.
> Never use the "Stop" button in Proxmox UI for forge-ai — use "Reboot" only.

</details>

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

### AdGuard Home — Port 53 is NOT a conflict ⛔

**Corrected 2026-08-09.** This section used to say `systemd-resolved` must be stopped and disabled before deploying AdGuard. That is wrong, and acting on it would break forge-ops.

The two coexist because each binds a *specific* address, not `0.0.0.0` — verified live on forge-ops:

```
AdGuard   10.10.20.20:53      (tcp + udp)   <- compose binds this IP explicitly
resolved  127.0.0.53:53, 127.0.0.54:53      <- stub listeners only
```

`systemd-resolved` is `active` and `enabled` on forge-ops and must stay that way. `roles/dns-client` configures resolved there to give the host its own resolution (primary AdGuard `10.10.20.20`, secondary dnsmasq `10.10.10.10`) and to emit the `bezaforge_dns_primary_in_use` metric behind the "DNS Not Using Primary" alert. Disabling it removes both.

If something *does* fail to bind :53, the cause is a listener on `0.0.0.0:53`, not resolved. Check with `ss -lntup | grep ':53 '`.

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
