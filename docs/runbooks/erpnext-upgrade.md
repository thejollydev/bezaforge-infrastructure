# Upgrading ERPNext

ERPNext runs on forge-erp from a vendored frappe_docker compose file,
`ansible/roles/erpnext/files/erpnext-one.yaml`. An upgrade is the image tag
moving in that file, followed by `bench migrate`. The in-app "Update
Available" button is never used on a container deploy.

Renovate proposes each release as one PR that moves the nine image refs in
the compose file and `erpnext_version` in the role's defaults together.
Every release, majors included, merges itself once CI is green, and the next
fleet update pass upgrades the instance with no further step.

## A major version

Nothing holds a major back, so the moment to look is before the weekly pass
runs, not before a merge. When `git log` shows a new major of ERPNext on
`main`, read the Frappe and ERPNext upgrade guide for anything that changes
how entries post, how reports total, or what a form prints, and take a VM
backup from Proxmox before running the pass.

## Deploy

Merging changes nothing on forge-erp. The next fleet update pass
([fleet-update.md](fleet-update.md)) deploys it, or on its own:

```bash
ansible-playbook ansible/site.yml --tags erpnext --limit forge-erp --ask-become-pass --ask-vault-pass
```

When the image in the compose file is not the one the running backend was
created from, the `erpnext` role upgrades instead of only recreating the
containers:

1. Refuses to go to an older version. That means a stale checkout; pull and
   run again.
2. Records the ledger totals: the number of posted GL entries and their debit
   and credit sums.
3. Runs the nightly backup job now (`bench backup --with-files`, then the
   copy to bezapool), so the dump is off the VM before anything changes.
4. Brings the stack up on the new image.
5. Runs `bench --site erp.bezaforge.dev migrate`.
6. Records the ledger totals again and fails if they differ.

The run prints both versions, `bench version`, and both ledger lines.

## Verify

Read-only:

```bash
ssh forge-erp 'docker ps --filter name=erpnext-one --format "{{.Names}}\t{{.Status}}\t{{.Image}}"'
ssh forge-erp 'docker exec erpnext-one-backend-1 bench version'
ssh forge-erp 'docker exec erpnext-one-backend-1 bench doctor'
curl -sI https://erp.bezaforge.dev | head -1
```

Then sign in and open a list and a report. If the desk loads without its
styling, reload without the browser cache before looking further.

## If the ledger totals moved, or the migrate failed

**This path has not been drilled.** It is written from how frappe_docker and
`bench restore` work, not from having done it on this instance; treat each
step as something to check before running.

Nothing is rolled back automatically. The backup taken in step 3 is in the
site's `private/backups` directory on forge-erp and on bezapool under
`forge-erp-backup/backups`, named with the time of the run.

1. Put the old image refs back in `erpnext-one.yaml` (revert the PR) and
   deploy. The role will refuse the older version, which is correct for a
   stale checkout and wrong here, so recreate the containers by hand on
   forge-erp:

   ```bash
   cd /opt/bezaforge/erpnext && docker compose -p erpnext-one -f erpnext-one.yaml up -d
   ```

2. Restore the backup into the site:

   ```bash
   docker exec -it erpnext-one-backend-1 bench --site erp.bezaforge.dev restore <path to the .sql.gz> --with-public-files <public tar> --with-private-files <private tar>
   ```

3. Check `bench version` and the ledger before doing anything else.

For anything the backup cannot undo, the previous night's VM backup in
Proxmox is the whole machine as it was.
