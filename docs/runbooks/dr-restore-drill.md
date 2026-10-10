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
| 2 | **App-consistent dumps** — forge-ops Postgres (`db-dumps`: gitea, langfuse, netbox, openproject → `bezapool/forge-ops-backup`, keep 14) + forge-erp `bench backup --with-files` → `bezapool/forge-erp-backup` | `.sql.gz` / bench `.tgz` | 02:30 / 03:30 | Yes (via layer 4) | A database/site restores independent of the VM |
| 3 | **ZFS snapshots** (sanoid, every 15 min) on `gdrive`, `forge-ops-backup`, `forge-erp-backup`, `downloads`, `media` | block-level snapshots | continuous | No | File-level "undo" + point-in-time recovery |
| 4 | **Offsite** (restic → GCS Nearline) of `/bezapool/{forge-ops-backup,vault,forge-erp-backup}` + `/sharepool/files` | encrypted restic repo in GCS | 04:00; integrity `restic check` Sun 05:00 | **Yes (this IS the offsite)** | Data survives total loss of the rack |

**Layer supply chain (nightly):** 02:00 vzdump → 02:30 db-dumps → 02:45 forge-ops rsync → 03:00 sanoid daily → 03:30 forge-erp bench→rsync → 04:00 restic→GCS. So the 04:00 offsite run carries *same-night* dumps.

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

Restore a service's nightly dump into a scratch database inside its own container — never over the live DB. Example: Gitea (adjust service/container per `db-dumps` defaults).

```bash
# On forge-ops as joseph. Newest dump for the service:
ls -t /mnt/bezapool/forge-ops-backup/gitea/*.sql.gz | head -1
# Create a scratch DB and load into it (socket auth inside the container):
docker exec gitea-db \
  psql -U <superuser> -c 'CREATE DATABASE dr_drill;'
gunzip -c /mnt/bezapool/forge-ops-backup/gitea/<TS>.sql.gz | \
  docker exec -i gitea-db \
  psql -U <superuser> -d dr_drill
# Spot-check row counts on a couple of core tables, then drop:
docker exec gitea-db \
  psql -U <superuser> -d dr_drill -c '\dt' | head
docker exec gitea-db \
  psql -U <superuser> -c 'DROP DATABASE dr_drill;'
```

> The superuser is whatever `POSTGRES_USER` each container sets — read it with `docker exec <container> printenv POSTGRES_USER`. (Some services inject a `PGHOST` that forces TCP + password auth; if a dump/restore hits `fe_sendauth: no password supplied`, add `-e PGHOST=/var/run/postgresql` to force the local Unix socket — check the `db-dumps` defaults for per-service `pghost` overrides.)

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

### Drill G — forge-agents restore onto a spare VM (the agent team)

forge-agents is bare metal and is rebuilt from code, not from an image; only
its data is backed up (Brizza ADR 0018). This drill proves both halves: the
role installs Hermes on a bare host, and the nightly backup
(`roles/hermes-backup`, pulled by `roles/forge-agents-backup-pull`) restores
into it with the agents' profiles, memory and boards.

**Three things that must not happen**, each with the step that prevents it:

- **A restored agent must never start.** The archive holds every agent's
  live bot token, and a second gateway serving them takes the real agents
  offline. The drill host gets `hermes_team_install_only: true`, so no
  gateway is ever installed there.
- **The restored subscription login must never be used.** It refreshes by
  single-use token: one refresh from the drill host would end the real
  host's login for every agent. Step 5 moves `auth.json` aside the moment
  the restore finishes, and nothing in the drill talks to a provider.
- **The restored Syncthing identity must never run.** It is the real
  host's device, and two of one device corrupts the vault sync.
  `host-settings.tar.gz` is listed, never unpacked into place.

```bash
# 1. The VM. Add the forge_agents_drill module to terraform/vms.tf (it is
#    kept there, commented with its purpose, only while a drill runs), then:
cd terraform && terraform apply -target=module.forge_agents_drill

# 2. Hermes, installed by the same role that installs it on forge-agents,
#    and nothing else (the host is in drill_hosts with install-only set):
cd ansible && ansible-playbook site.yml --limit forge-agents-drill --ask-become-pass --ask-vault-pass

# 3. Nothing that could start an agent exists on the drill host. Expect
#    no hermes-gateway unit and no hermes timers:
ssh <admin>@10.10.50.21 'systemctl --user list-unit-files "hermes*" --no-legend; systemctl --user list-timers --no-legend | grep -c hermes'

# 4. The backup, from the dataset to the drill host, through the control
#    machine without touching its disk. Then check it against its manifest:
for f in MANIFEST hermes-backup.zip host-settings.tar.gz; do
  ssh root@forge-hypervisor "cat /bezapool/forge-agents-backup/$f" \
    | ssh <admin>@10.10.50.21 "umask 077; mkdir -p ~/restore; cat > ~/restore/$f"
done
ssh <admin>@10.10.50.21 'cd ~/restore && grep -E "^[0-9a-f]{64}  " MANIFEST | sha256sum --check --strict'

# 5. Restore, and move the login aside in the same command:
ssh <admin>@10.10.50.21 '~/.local/bin/hermes import --force ~/restore/hermes-backup.zip; mv ~/.hermes/auth.json ~/restore/auth.json.set-aside; chmod 000 ~/restore/auth.json.set-aside'

# 6. What came back. Compare with the manifest and with the live host:
ssh <admin>@10.10.50.21 'ls ~/.hermes/profiles; ~/.local/bin/hermes kanban list | grep -c "t_"; cat ~/.hermes/profiles/*/memories/MEMORY.md 2>/dev/null | head; tar -tzf ~/restore/host-settings.tar.gz'

# 7. Record the result below, then destroy the VM: remove the module from
#    terraform/vms.tf, the host from ansible/inventory/hosts.yml and its
#    host_vars file, and apply.
cd terraform && terraform apply
```

**Pass =** Hermes installs on the bare VM from the role; every profile in
the manifest is present with its soul, config and `.env`; the board holds
the same number of cards as the live host; an agent's memory reads back;
`host-settings.tar.gz` lists Syncthing's identity, Never4gA's config and
the repository key; and no gateway unit ever existed on the drill host.

---

## Cadence — ratified 2026-07-11

Deliberately lean so it actually gets done by a solo operator. **Two tiers, one anchor date each.**

| When | Drills | Layers | Why this is the whole quarterly/annual set |
|------|--------|--------|--------------------------------------------|
| **Quarterly** (each quarter-start) | **B — Offsite restic restore** + **A — VM image restore (forge-erp)** | 4, 1 | The two highest-value drills, ~20 min total. B is the *only* test of the GCS/password/creds path; A validates the financials host boots + its guest-agent fs-freeze. |
| **Annual** (fold onto the Q1 run) | **C — Postgres dump restore** (rotate one service) + **D — forge-erp bench restore** + **E — ZFS file recovery** + **F — Full DR tabletop** | 2, 2, 3, all | One yearly "everything else" pass. Proves app-level restores (books + a rotated Postgres service), file-level ZFS recovery, and the cross-layer creds/dependency tabletop. |

**Anchor:** run the quarterly **B + A(forge-erp)** together at each quarter-start; on the **Q1** run, add the four annual drills (C/D/E/F). A single recurring OpenProject item — *"DR drill — <quarter>"* — keeps it on the radar; the Q1 instance carries the annual add-ons.

*Rationale for the lean v1: the risk with a solo operator isn't the cadence being wrong, it's it being too much ceremony to sustain. Start with the two drills that matter most on a habit you'll keep, and add rigor later if the pattern holds. The individual per-layer cadences (semi-annual C/D, annual E/F rotations) can be split back out if annual proves too coarse.*

---

## Drill log

Append one row per drill run. Keep it here (version-controlled) so the history travels with the runbook.

| Date | Drill | Target | Result | RTO (wall-clock) | Notes / findings | Operator |
|------|-------|--------|--------|------------------|------------------|----------|
| 2026-06-15 | A | forge-erp (VMID 103) → scratch 199 | ✅ Pass | ~not recorded | Booted clean, ERPNext came up. Pre-runbook baseline (recorded retroactively). | Joseph |
| 2026-07-11 | B | restic `latest` → /root/dr-drill | ✅ Pass | ~3s | **First-ever offsite restore drill.** GCS auth + repo decrypt + download all confirmed working. Restored `/bezapool/forge-erp-backup` (1.86 MiB) from snapshot `486f15b3`; `database.sql.gz` passed `gunzip -t`, both `-files.tar`/`-private-files.tar` passed `tar -tf`. The GCS/password/creds path — never exercised by ops before — is proven. | Joseph |
| 2026-07-11 | A | forge-erp (VMID 103) → scratch 199 | ✅ Pass | ~40s (restore) | 50 GB image, 68.5% sparse, `qmrestore`→disk in 39.7s. Booted NIC-down (`link_down=1`); guest-agent up ~5s; all 8 ERPNext containers `Up`, `mariadb-database` `Up (healthy)`. Confirms forge-erp guest-agent is present (not part of FORGE-79/83 gap). Scratch VM purged after. | Joseph |

---

## Related

- [Secret-rotation runbook](secret-rotation.md) — the vault/restic/GCS secrets these drills depend on.
- ADR 0001 (MVB four-layer backup) — the design these layers implement.
- FORGE-44 — why `bezapool/vzdump` is **not** sanoid-snapshotted (snapshotting backups pins pruned copies).
- FORGE-60/61/62 (PR #63) — the forge-erp offsite + app-consistent + retention hardening referenced above.
- `roles/hermes-backup`, `roles/forge-agents-backup-pull` — the agent host's nightly backup that Drill G restores.
