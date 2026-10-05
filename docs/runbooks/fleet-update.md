# Updating the fleet

One command brings every host up to what `main` says: OS packages, then every
pinned service. It is run by hand, about once a week. Nothing here runs on a
timer, and nothing merged is live until this pass has run.

```bash
scripts/fleet-update.sh
```

It works from any directory and asks for the sudo password and the vault
password, so it needs a real terminal.

## What it does

1. **Checks the checkout.** It refuses anything but a clean `main`, pulls, and
   pushes `main` back to `origin`. The playbook then checks again that the
   checkout is `main` at the commit GitHub has. A stale checkout would put
   every image Renovate has moved since back on its old pin.
2. **OS packages**, host by host: forge-hypervisor, then forge-ai and
   forge-erp, then forge-agents, then forge-ops last because it is DNS for
   every VLAN.
3. **`site.yml`.** Everything merged is deployed: container images, Ollama,
   LangFuse and the rest. ERPNext is upgraded rather than recreated when its
   image moved ([erpnext-upgrade.md](erpnext-upgrade.md)).
4. **Resolvers.** Redeploying AdGuard leaves hosts on the secondary resolver.
   Each host's primary-DNS check is run now, and the pass fails if a host is
   still off the primary.
5. **`health.yml`.** ZFS pools, mountpoints, containers, failed units and
   pending reboots.
6. **Reboot summary.** Which hosts need one. The pass never reboots anything.

## Then run it again

A second run straight after should find nothing to do: `changed=0` on every
host except forge-erp, where one task reports `changed` on every run by
design (the ERPNext configurator container; see `roles/erpnext`). Anything
else that changes twice is a defect in a role.

## Reboots

Reboot by hand, in the order the summary prints, and only inside a window you
chose: forge-hypervisor takes every VM down with it, and forge-ops takes DNS
and every service. Afterwards:

```bash
scripts/fleet-update.sh --tags resolver,health
```

## Where the updates come from

Renovate runs on Mondays and on demand (`gh workflow run renovate.yml`).

| Update | What happens |
|---|---|
| Digest, patch and minor, of everything | Merges itself once CI is green |
| Major | A PR that waits for a decision, announced in Discord as "MAJOR — needs your decision" |
| Major of a database or cache engine (Postgres, MariaDB, Redis, Valkey, ClickHouse) | The same, with a warning on the PR: merging it without migrating the data first stops the engine on the next pass |

ERPNext and LangFuse each arrive as one grouped PR
([erpnext-upgrade.md](erpnext-upgrade.md),
[langfuse-upgrade.md](langfuse-upgrade.md)).

The rules are in `.github/renovate.json`. A merge changes git and no machine.
The "Deploy Drift" alert reports roles that have sat merged and undeployed
([deploy-drift.md](deploy-drift.md)); this pass is what clears it.

## Parts of the pass on their own

| Wanted | Command |
|---|---|
| OS packages only | `scripts/fleet-update.sh --tags update` |
| Deploy what is merged, no package upgrade | `ansible-playbook ansible/site.yml --ask-become-pass --ask-vault-pass` |
| Resolvers and health after a reboot | `scripts/fleet-update.sh --tags resolver,health` |
| Health only | `ansible-playbook ansible/health.yml --ask-become-pass --ask-vault-pass` |

## Running it from a branch

To test a change to the pass itself before merging it:

```bash
scripts/fleet-update.sh --this-checkout
```

That skips the pull and both checks and deploys the checkout as it stands,
including modified files. The stamps `roles/deploy-stamp` writes will name
the branch, and they change once more when the same commit is deployed from
`main`.

## When it stops

A failure usually ends the whole run, not just that host's part. Most plays
here have one host, and when every host in a play has failed Ansible stops
the playbook: the plays after it, the resolver step and the health checks do
not run. On 2026-10-04 a failure on forge-agents meant forge-erp was never
deployed and nothing was verified. Fix the cause and run the command again;
every step is safe to repeat, and a run that did not reach the health checks
has not told you the fleet is healthy.

- **"This checkout is not main as GitHub has it"**: use the wrapper, which
  pulls first.
- **A host is not on the primary resolver**: check that AdGuard answers
  (`dig +short @10.10.20.20 bezaforge.dev`), then
  `sudo systemctl restart systemd-resolved` on that host. See
  [dns-failover-test.md](dns-failover-test.md).
- **ERPNext refused an older version, or the ledger totals moved**:
  [erpnext-upgrade.md](erpnext-upgrade.md).
- **forge-agents: "`never4ga adapters sync` wants to do more than write
  pointers"**: its Never4gA build is older than the laptop's. Rebuild the
  wheel ([never4ga-on-forge-agents.md](never4ga-on-forge-agents.md)).
- **A health check failed**: the message names the pool, mount or container.
