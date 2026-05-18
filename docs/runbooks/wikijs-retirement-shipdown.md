# Runbook — Wiki.js retirement ship-down (one-time, 2026-05-17)

**Status:** One-time procedure. Once executed and verified, this runbook can be deleted.

This is the operational counterpart to the repo edits that removed Wiki.js from Ansible roles, the homepage dashboard, and project docs on 2026-05-17. Those edits *describe* the desired state; this runbook *takes* the running container down on forge-ops and archives its data.

## Pattern

This mirrors the Harbor retirement (commit `64c6a59`, 2026-05-17). The compose stack stops, the install dir is renamed with a dated `_retired-` prefix so it's obvious in `ls`, the next nightly rsync + restic captures the final state for the configured retention window (6 months for restic→GCS), and after that window the dir can be permanently deleted.

## On forge-ops (10.10.20.20)

The Phase 1 `joseph` user on forge-ops is in the `docker` group + owns the per-service dirs under `/opt/bezaforge/`, so neither `docker compose` nor renaming the dir needs sudo. Run interactively (one ssh, sequential commands) so any unexpected prompt can be answered:

```bash
ssh joseph@10.10.20.20
```

Then on forge-ops:

```bash
set -euo pipefail
cd /opt/bezaforge

# 1. Final pg_dump — belt + suspenders. The db-dumps role
#    dumped wiki nightly until today's repo edit; the most
#    recent dump in bezapool/forge-ops-backup/wiki/ is at
#    most 24h old. This pins the very-last state right here
#    alongside the install dir so it travels with the archive.
if [ -d wiki ]; then
  docker exec wiki-db pg_dumpall -U wiki \
    | gzip > "wiki/final-pgdump-$(date +%Y-%m-%d).sql.gz"
  ls -lh "wiki/final-pgdump-$(date +%Y-%m-%d).sql.gz"
fi

# 2. Stop + remove containers + anonymous volumes. The
#    postgres data dir is bind-mounted under /opt/bezaforge/wiki/
#    so the persistent data on disk survives `down -v`.
if [ -d wiki ]; then
  ( cd /opt/bezaforge/wiki && docker compose down -v )
fi

# 3. Archive the install dir with a dated retired- prefix
#    (same pattern as Harbor on 2026-05-17). If this `mv`
#    fails with permission denied, your /opt/bezaforge/ is
#    root-owned — fall back to `sudo mv` interactively.
if [ -d wiki ]; then
  mv wiki _retired-wikijs-2026-05-17
  ls -ld _retired-wikijs-2026-05-17
fi

# 4. Show the final state
docker ps --filter "name=wiki" --format 'STILL RUNNING: {{.Names}}'  # should be empty
ls -ld /opt/bezaforge/_retired-* 2>/dev/null

exit  # back to your workstation
```

## Verify (from workstation)

```bash
# Container should not exist
ssh joseph@10.10.20.20 'docker ps -a --filter name=wiki --format "{{.Names}} {{.Status}}"'

# Subdomain should now return 404 from Traefik (no matching router)
curl -sS -o /dev/null -w "%{http_code}\n" https://wiki.bezaforge.dev
# Expect: 404

# Homepage card should be gone
curl -sS https://home.bezaforge.dev | grep -i 'wiki\.js' || echo "no wiki.js card — good"
```

## After-shipdown bookkeeping

1. The next nightly `forge-ops-backup-rsync` run will NOT touch `_retired-wikijs-2026-05-17/` (the role only iterates the `backup_services` list, which no longer includes wiki). The Phase 1 final state was captured in the rsync mirror up through the last successful run before retirement; restic→GCS picked it up the same night. Joseph can confirm the snapshot ID with `sudo restic -r gs:bezaforge-backups-... snapshots --path /mnt/bezapool/forge-ops-backup/wiki` on forge-hypervisor.
2. The next `ansible-playbook site.yml --tags services --limit forge-ops` run will NOT recreate the wiki stack (it's no longer in `compose_services`).
3. The next nightly `db-dumps` run will NOT attempt a wiki pg_dump (the entry was removed from `postgres_dumps`).
4. Around 2026-11-17 (6 months out), delete `_retired-wikijs-2026-05-17/` from forge-ops if no need has arisen to revive it.

## DNS

The `wiki.bezaforge.dev` subdomain is covered by the wildcard AdGuard DNS rewrite (`*.bezaforge.dev → 10.10.20.20`). No DNS change is needed — Traefik just stops routing it.
