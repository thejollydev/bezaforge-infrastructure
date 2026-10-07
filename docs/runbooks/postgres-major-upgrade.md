# Moving a service to a new Postgres major

A new Postgres major cannot read the old one's data directory. Bumping the
image alone leaves the database refusing to start. `roles/postgres-major`
does the move during a normal deploy: it dumps the database from the old
server, brings the new one up alone on an empty data location, restores, and
checks that the tables and rows are what they were.

Each service has its own Postgres, so each is moved by itself.

| Service | Container | Was | State |
|---|---|---|---|
| NetBox | `netbox-postgres` | 16 | moved to 18 in the change that added this runbook |
| LangFuse | `langfuse-db` | 17 | to do |
| Outline | `outline-db` | 15 | not moved: Outline is being torn down |
| Gitea | `gitea-db` | 15 | to do, last: everything pulls from it |

## What a move needs in the repository

Renovate proposes the image bump as one pull request per service. **That pull
request is not enough by itself, and merging it alone would lose sight of the
data.** The same change has to:

1. **Point the database at a new, empty location.** For a bind mount, a new
   host directory; for a named volume, a new volume name. The old data is
   then never touched, and going back is reverting the change.
2. **Mount it at `/var/lib/postgresql`, not `/var/lib/postgresql/data`,** from
   Postgres 18 on. The image keeps its data in
   `/var/lib/postgresql/<major>/docker` and declares the parent as its volume.
   Mounted at `.../data`, 18 writes to an anonymous volume and the database is
   gone at the next recreate.
3. **Name the database for the role**, so it runs between the compose file
   landing and the stack starting: an entry in `services_postgres_majors`
   (`roles/services/defaults/main.yml`), or an `include_role` in the service's
   own role for one outside `roles/services`.

Push those onto Renovate's branch, or make the whole change by hand and close
its pull request.

## What the role does

When the running server is older than the image the compose file asks for:

1. Refuses if the server holds any database or role besides the service's
   own. It dumps one database; anything else would be left behind.
2. Stops the application containers that write to the database.
3. Counts the tables and rows, exactly.
4. Dumps the database to `/opt/bezaforge/pg-upgrade/` on the host.
5. Writes an in-progress marker there.
6. Brings up the database service alone, on the new image and the new
   location, and waits for it over TCP. (A socket check passes while the image
   is still initialising, and a restore started then is cut off.)
7. Refuses to restore unless the server is the new major and holds no tables.
8. Restores, counts again, and fails if the counts differ.
9. Runs `analyze`, removes the marker and prints both counts.

The service's own task then starts the stack. When the versions already
match, the role reads the version and does nothing.

It refuses to go to an older major, and it refuses to guess when the database
container exists but does not answer.

## Deploy

The fleet update pass ([fleet-update.md](fleet-update.md)) does it, or for
one service's role by itself:

```bash
ansible-playbook ansible/site.yml --tags services --limit forge-ops --ask-become-pass --ask-vault-pass
```

The service is down from step 2 until its stack starts again: seconds for a
small database, longer for Gitea's.

## Verify

The run prints `was` and `now` with the table and row counts. Then, read-only:

```bash
ssh forge-ops 'docker ps --filter name=netbox --format "{{.Names}}\t{{.Status}}\t{{.Image}}"'
ssh forge-ops 'docker exec netbox-postgres psql -U netbox -d netbox -Atc "select version()"'
curl -sI https://netbox.bezaforge.dev | head -1
```

Sign in and open something that reads and something that writes.

## Afterwards

The old data is still on forge-ops, and so is the dump. Once the application
has been in use on the new major for long enough to trust it, remove both by
hand:

- the old data: `/opt/bezaforge/<service>/postgres` for a bind mount, or the
  old named volume
- the dump: `/opt/bezaforge/pg-upgrade/<container>_pg<old>_<time>.pgc`

The nightly dumps (`roles/db-dumps`) carry on by container name and need no
change.

## When it stops

**Nothing here has been needed yet.** The role and both of its refusals were
exercised against throwaway containers on a workstation, 15 to 18 and 16 to
18. The recovery below is reasoned, not drilled.

The applications stay stopped, the old data is untouched, and the marker
`/opt/bezaforge/pg-upgrade/<container>.in-progress` names the dump and the
count taken before. The next run refuses to do anything while the marker is
there, because the new database may be empty or half restored and starting
the application on it would hide that.

To go back to the old major:

1. Revert the change that moved the image and the data location, and deploy.
   The old container comes back on the old data.
2. On forge-ops, remove the marker and the new, half-filled location:

   ```bash
   sudo rm /opt/bezaforge/pg-upgrade/<container>.in-progress
   ```

   ```bash
   sudo rm -rf /opt/bezaforge/<service>/postgres18
   ```

To try again instead, fix the cause, remove the container, the new location
and the marker by hand, start the database on its **old** image so the role
can read its version, and deploy.
