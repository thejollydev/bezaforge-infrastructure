# Runbook — Disaster-recovery restore drill

**Audience:** Joseph, or any future operator with `root@forge-hypervisor` + `--ask-vault-pass` access.

**Status:** Policy v1 — **ratified 2026-07-11** (FORGE-76). Backups are only as good as the last *restore* you proved. This runbook makes restore-testing a scheduled, repeatable thing instead of a hope. It does **not** automate anything — it defines *what* to drill, *how often*, *the exact commands*, and *where to log the result*.

---

## Why drill restores at all

Three reasons, same spirit as the [secret-rotation runbook](secret-rotation.md):

1. **A backup you have never restored is a hypothesis, not a backup.** vzdump can be green every night and still produce an unbootable image; a restic repo can pass `restic check` (metadata only) and still fail to hand back your data if the password or GCS credentials have drifted. The only proof is a restore.
2. **Force the recovery path to stay healthy.** The offsite GCS path in particular is *never* exercised by normal operations — the nightly job only ever *writes*. A drill is the sole continuous test that the download-and-decrypt path works.
3. **Know your RTO before the incident, not during it.** Timing a drill tells you how long a real recovery takes, so a real outage has a number attached instead of a panic.

---

## The four backup layers (what we are drilling)

Per ADR 0001 (MVB four-layer) + the forge-erp hardening in PR #63 (FORGE-60/61/62). All times EDT.

| # | Layer | Produces | Schedule | Offsite? | Restore proves |
|---|-------|----------|----------|----------|----------------|
| 1 | **VM image** (Proxmox vzdump, all VMs, `snapshot` mode + guest-agent fs-freeze) | `vzdump-qemu-<vmid>-*.vma.zst` on `bezapool-vzdump`, keep-daily=7 | 02:00 | **No** (on-pool only) | A whole VM boots from bare metal |
| 2 | **App-consistent dumps** — forge-ops Postgres (`db-dumps`: gitea, langfuse, netbox, outline, plane, brizza → `bezapool/forge-ops-backup`, keep 14) + forge-erp `bench backup --with-files` → `bezapool/forge-erp-backup` | `.sql.gz` / bench `.tgz` | 02:30 / 03:30 | Yes (via layer 4) | A database/site restores independent of the VM |
| 3 | **ZFS snapshots** (sanoid, every 15 min) on `gdrive`, `forge-ops-backup`, `brizza-backup`, `forge-erp-backup`, `downloads`, `media` | block-level snapshots | continuous | No | File-level "undo" + point-in-time recovery |
| 4 | **Offsite** (restic → GCS Nearline) of `/bezapool/{forge-ops-backup,vault,brizza-backup,forge-erp-backup}` + `/sharepool/files` | encrypted restic repo in GCS | 04:00; integrity `restic check` Sun 05:00 | **Yes (this IS the offsite)** | Data survives total loss of the rack |

**Layer supply chain (nightly):** 02:00 vzdump → 02:30 db-dumps → 02:45 forge-ops rsync → 03:00 sanoid daily → 03:30 forge-erp bench→rsync → 03:45 brizza `~/.hermes` rsync → 04:00 restic→GCS. So the 04:00 offsite run carries *same-night* dumps.

---

## Drill procedures

Each drill is self-contained and **non-destructive to production** — restores always land on a throwaway target (scratch VMID, scratch database, scratch directory), which is destroyed afterward.

### Drill A — VM image restore (layer 1) — *verified working 2026-06-15*

Restore the latest image to a throwaway VMID with the NIC forced down so it cannot clash with the live VM. Example uses forge-erp (VMID 103); substitute any VMID.

```bash
# On forge-hypervisor as root. Pick the newest backup for the VMID:
ls -t /bezapool/vzdump/dump/vzdump-qemu-103-*.vma.zst | head -1

qmrestore bezapool-vzdump:backup/vzdump-qemu-103-<TS>.vma.zst 199 --storage vm-scratch --unique 1
qm set 199 --net0 virtio,bridge=vmbr0,link_down=1   # NIC DOWN before boot — do not skip
qm start 199 && qm terminal 199                     # verify boot; inside: `docker ps` shows the app containers
# ... confirm the app came up, note the wall-clock time ...
qm stop 199 && qm destroy 199 --purge
```

**Pass =** guest boots clean and the app's containers are `Up`. For forge-erp, ERPNext (`erpnext-one-*` + `mariadb-database`) reaches a login page. Record how long qmrestore→boot took (your RTO for a VM).

### Drill B — Offsite restic restore (layer 4) — *highest DR value, never exercised by ops*

This is the single most important drill: it is the only test that the GCS download path, the restic repo password, and the GCS service-account credentials all still work together. `restic check` does **not** cover this (it verifies repo metadata, not a data round-trip).

```bash
# On forge-hypervisor as root. Secrets come from the vault-managed restic env
# (RESTIC_REPOSITORY, RESTIC_PASSWORD, GOOGLE_APPLICATION_CREDENTIALS) —
# source the same environment the restic-gcs systemd unit uses.
restic snapshots | tail -5                          # newest snapshot IDs
mkdir -p /root/dr-drill && cd /root/dr-drill
# Restore ONE known path from the latest snapshot (small + verifiable):
restic restore latest --include /bezapool/forge-erp-backup --target /root/dr-drill
# Verify a real file came back and is intact:
find /root/dr-drill -name '*.tgz' -o -name '*.sql*' | head
# For a bench dump, confirm the tar is readable:
tar -tzf /root/dr-drill/bezapool/forge-erp-backup/<latest>.tgz | head
rm -rf /root/dr-drill
```

**Pass =** a real backup artifact downloads from GCS and passes an integrity read (`tar -tzf` / `gunzip -t`). If restic errors on password or credentials, **that is the finding** — fix before it is an emergency.

### Drill C — Postgres dump restore (layer 2, forge-ops)

Restore a service's nightly dump into a scratch database inside its own container — never over the live DB. Example: Plane (adjust service/container per `db-dumps` defaults).

```bash
# On forge-ops as joseph. Newest dump for the service:
ls -t /mnt/bezapool/forge-ops-backup/plane/*.sql.gz | head -1
# Create a scratch DB and load into it (socket auth inside the container):
docker exec -e PGHOST=/var/run/postgresql plane-plane-db-1 \
  psql -U <superuser> -c 'CREATE DATABASE dr_drill;'
gunzip -c /mnt/bezapool/forge-ops-backup/plane/<TS>.sql.gz | \
  docker exec -i -e PGHOST=/var/run/postgresql plane-plane-db-1 \
  psql -U <superuser> -d dr_drill
# Spot-check row counts on a couple of core tables, then drop:
docker exec -e PGHOST=/var/run/postgresql plane-plane-db-1 \
  psql -U <superuser> -d dr_drill -c '\dt' | head
docker exec -e PGHOST=/var/run/postgresql plane-plane-db-1 \
  psql -U <superuser> -c 'DROP DATABASE dr_drill;'
```

> Plane needs the `PGHOST=/var/run/postgresql` override (its compose injects `PGHOST=plane-db`, forcing TCP + password auth). The other five services (gitea/langfuse/netbox/outline/brizza) do not. The superuser is whatever `POSTGRES_USER` each container sets — read it with `docker exec <container> printenv POSTGRES_USER`.

### Drill D — forge-erp app-consistent restore (layer 2, financials)

Prove the ERPNext `bench backup` can be restored (the layer that actually protects the books). Restore into a **scratch site**, not the live `erp.bezaforge.dev`.

```bash
# On forge-erp as joseph. Latest bench backup set (db + files):
ls -t /var/lib/docker/volumes/erpnext-one_sites/_data/erp.bezaforge.dev/private/backups/ | head
# bench restore into a throwaway site (does NOT touch erp.bezaforge.dev):
docker exec erpnext-one-backend-1 bench new-site dr-drill.local --no-mariadb-socket --admin-password <tmp> --mariadb-root-password <root>
docker exec erpnext-one-backend-1 bench --site dr-drill.local restore /home/frappe/frappe-bench/sites/erp.bezaforge.dev/private/backups/<TS>-database.sql.gz
# Confirm it migrates + a core doctype has rows, then drop the scratch site:
docker exec erpnext-one-backend-1 bench --site dr-drill.local list-apps
docker exec erpnext-one-backend-1 bench drop-site dr-drill.local --force --no-backup
```

**Pass =** the scratch site restores and lists the ERPNext apps. (If you would rather not stand up a scratch site, the minimum viable check is `gunzip -t <TS>-database.sql.gz` to prove the dump is not truncated — but a real `bench restore` is the true proof.)

### Drill E — ZFS file-level recovery (layer 3)

Snapshots are browsable read-only under `.zfs/snapshot/` — no rollback needed to recover a file.

```bash
# On forge-hypervisor as root:
zfs list -t snapshot -o name,creation bezapool/gdrive | tail -5
ls /bezapool/gdrive/.zfs/snapshot/                  # each dir = a point in time
# Copy a known file out of a past snapshot to verify granularity:
cp /bezapool/gdrive/.zfs/snapshot/<snap>/<some-file> /tmp/dr-check && rm /tmp/dr-check
```

**Pass =** a file from a past snapshot reads back byte-intact.

### Drill F — Full DR tabletop (annual, no execution)

A walkthrough, not a live restore: "forge-hypervisor is gone — rebuild from zero." Confirm you can, on paper, name every step and where each dependency lives:

- Reinstall Proxmox + recreate `bezapool` / `vm-scratch` storages.
- **Where do the vzdump images live if the pool is gone?** → they are **on-pool only** (no offsite). This is the known single point of failure (FORGE-60 closed the *forge-erp* gap by putting its bench dumps offsite via restic; whole-VM images are still on-pool). The tabletop should confirm the recovery story is "rebuild VMs from config + restore app data from GCS (layer 4)," not "restore VM images" — because in a total-pool-loss scenario the images are gone with it.
- Restore app data from GCS (Drill B), re-run Ansible to reconstitute hosts, restore databases (Drill C/D).
- Confirm vault (`--ask-vault-pass`) password + restic password + GCS creds are recorded in **Bitwarden** and reachable without the rack.

---

## Cadence — ratified 2026-07-11

Deliberately lean so it actually gets done by a solo operator. **Two tiers, one anchor date each.**

| When | Drills | Layers | Why this is the whole quarterly/annual set |
|------|--------|--------|--------------------------------------------|
| **Quarterly** (each quarter-start) | **B — Offsite restic restore** + **A — VM image restore (forge-erp)** | 4, 1 | The two highest-value drills, ~20 min total. B is the *only* test of the GCS/password/creds path; A validates the financials host boots + its guest-agent fs-freeze. |
| **Annual** (fold onto the Q1 run) | **C — Postgres dump restore** (rotate one service) + **D — forge-erp bench restore** + **E — ZFS file recovery** + **F — Full DR tabletop** | 2, 2, 3, all | One yearly "everything else" pass. Proves app-level restores (books + a rotated Postgres service), file-level ZFS recovery, and the cross-layer creds/dependency tabletop. |

**Anchor:** run the quarterly **B + A(forge-erp)** together at each quarter-start; on the **Q1** run, add the four annual drills (C/D/E/F). A single recurring Plane item — *"DR drill — <quarter>"* — keeps it on the radar; the Q1 instance carries the annual add-ons.

*Rationale for the lean v1: the risk with a solo operator isn't the cadence being wrong, it's it being too much ceremony to sustain. Start with the two drills that matter most on a habit you'll keep, and add rigor later if the pattern holds. The individual per-layer cadences (semi-annual C/D, annual E/F rotations) can be split back out if annual proves too coarse.*

---

## Drill log

Append one row per drill run. Keep it here (version-controlled) so the history travels with the runbook.

| Date | Drill | Target | Result | RTO (wall-clock) | Notes / findings | Operator |
|------|-------|--------|--------|------------------|------------------|----------|
| 2026-06-15 | A | forge-erp (VMID 103) → scratch 199 | ✅ Pass | ~not recorded | Booted clean, ERPNext came up. Pre-runbook baseline (recorded retroactively). | Joseph |
| _next_ | B | restic `latest` → /root/dr-drill | — | — | First-ever offsite restore drill — establishes the baseline. | |

---

## Related

- [Secret-rotation runbook](secret-rotation.md) — the vault/restic/GCS secrets these drills depend on.
- ADR 0001 (MVB four-layer backup) — the design these layers implement.
- FORGE-44 — why `bezapool/vzdump` is **not** sanoid-snapshotted (snapshotting backups pins pruned copies).
- FORGE-60/61/62 (PR #63) — the forge-erp offsite + app-consistent + retention hardening referenced above.
