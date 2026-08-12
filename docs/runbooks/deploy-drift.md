# Runbook — Deploy Drift ("merged" is not "shipped")

What the **Deploy Drift** alert means, how to clear it, and how to prove it can still go red. Written for **#671**.

A merged PR changes a file in git. It changes nothing on any host until `ansible-playbook` runs. Nothing used to detect that gap — CI went green, the repo read as correct, and no alert fired. It has bitten four times:

| | What sat undeployed | For how long | Found by |
|---|---|---|---|
| **#649** | the `DNS Resolvers Disagree` alert | a day | a hand-run `--check` sweep |
| **#164** | a netbox image digest (auto-merged) | two days | the same sweep |
| **#552** | the entire `sharepool` remediation — five hosts | a day | the next session probing live state |
| 2026-05 | a homepage icon fix | two days | an unexpected `changed=` line |

Every one was found by hand or not at all. This alert exists so the system reports its own drift instead.

---

## What it proves, and what it does not

| Catches | Does not catch |
|---|---|
| A role whose files changed on `main` but which has not been deployed to some host since | A host that has **never** run `roles/deploy-stamp` — it exports no series, and an absent series looks identical to a healthy one |
| A host deployed from a **dirty** working tree, whose stamp names a commit that does not describe what is running | Drift that is not in git — a file hand-edited on a host. That is `--check`'s job |
| A brand-new role merged and never deployed (the role list is read from git, not baked in) | Anything outside `ansible/roles/**` — docs-only and CI-only commits are structurally incapable of firing this |

The blind spot in the first "does not" row is real but bounded: every play in `site.yml` gained `deploy-stamp` with `tags: always`, so the first full deploy arms every host. Until then, `--hosts` shows who is reporting.

---

## How it works

Two clocks, compared per role:

- **WANTED** — committer timestamp of the newest commit touching `ansible/roles/<role>` on `main`, read from the **Gitea API**. No clone anywhere: `contents/` enumerates the roles, `commits?path=` dates each one. No `forge-*` host carries a repo checkout and this does not make one the first.
- **DEPLOYED** — committer timestamp of the repo HEAD that was checked out when that role last ran, stamped onto the host by `roles/deploy-stamp` into `/etc/bezaforge/deployed/<role>` and exported as a node-exporter textfile metric.

`scripts/deploy-drift-check.py` on forge-ops compares them every 30 min and publishes `bezaforge_deploy_drift_exit_code`. The Grafana rule alerts on `> 0` after **6h**, which is long enough that merging and deploying in one session never nags.

**Why per-role and not one SHA per host:** almost every real deploy here is tag-scoped. A whole-host SHA would advance on `--tags adguard` and claim credit for the thirty roles that did not run — a false green, worse than no check. It would also read "behind" after any commit at all, including a README fix, and a permanently-red alert is one nobody reads.

---

## Responding to the alert

Run the check and read its table. It names every host/role pair and prints the exact deploy command:

```bash
scripts/deploy-drift-check.py -v        # every pair, not just the behind ones
scripts/deploy-drift-check.py --hosts   # which hosts report stamps at all
```

### Exit code 1 — BEHIND

At least one host is running an older commit of a role than `main` describes. The script prints the command; it looks like:

```bash
cd ansible && ansible-playbook site.yml \
  --tags <roles it named> --ask-become-pass --ask-vault-pass
```

⚠️ **Then verify the LIVE artifact, not the PLAY RECAP.** A tag-scoped run only touches the tags you name — that is exactly how #649 and #164 were missed. `ssh` and `diff` the on-host file, or curl the endpoint that changed. A second apply returning `changed=0` is the idempotency proof.

### Exit code 2 — INVALID (not a pass)

Three distinct causes; the script says which:

- **Dirty working tree** — a host was deployed from a checkout with modified tracked files, so its stamp names a commit that does not describe what is running. Commit or stash, then redeploy that role. `bezaforge_deploy_drift_dirty` carries the count.
- **Gitea or Prometheus unreachable** — the check reports INVALID rather than a pass. It reaches both through Traefik, so this usually means Traefik or DNS, not the checker. Check `docker ps` on forge-ops first.
- **Nothing stamped at all** — no host has run `roles/deploy-stamp` yet. Run a full `site.yml`.

---

## Proving it can still go red

A check whose failure path has never run is not known to work. This one's red paths were exercised at build time against a stub Prometheus and should be re-exercised after any change to the checker:

```bash
# BEHIND: stamp a role with a timestamp older than its last commit on main
PROM_URL=http://127.0.0.1:PORT ROLES_OVERRIDE=adguard scripts/deploy-drift-check.py -v
```

`ROLES_OVERRIDE` narrows the sweep to named roles and exists for exactly this purpose. The four verdicts and their exit codes:

| Scenario | Exit |
|---|---|
| Stamp older than the role's last commit | 1 |
| Stamp newer than the role's last commit | 0 |
| Stamp marked `dirty=1` | 2 |
| No host stamped at all | 2 |

The wrapper's own failure path matters too: if `deploy-drift-check.py` is missing or unrunnable, `deploy-drift-metric.sh` publishes `exit_code=2`, **not** a healthy `0`. An exporter that cannot measure must never emit a healthy value. Verify by pointing the wrapper at a nonexistent script and reading the `.prom`.

---

## Files

| Thing | Where |
|---|---|
| Stamper (every host, last in every play, `tags: always`) | `ansible/roles/deploy-stamp/` |
| Stamps on a host | `/etc/bezaforge/deployed/<role>` |
| Host metrics | `/var/lib/prometheus/node-exporter/bezaforge_deploy.prom` |
| Comparison script (one copy, deployed verbatim) | `scripts/deploy-drift-check.py` |
| Watcher on forge-ops + its metric | `ansible/roles/monitoring/` → `bezaforge_deploy_drift.prom` |
| Grafana rule (`Deploy Drift`, uid `bfg9deploydrift01`) | `ansible/roles/monitoring/files/grafana/provisioning/alerting/alert-rules.yaml` |

**Deliberately out of scope:** `roles/health-check` and `roles/os-update`. They are not in `site.yml` — they belong to `health.yml` and `update.yml`, which are run deliberately rather than as config convergence, so a change to them does not sit undeployed in the harmful sense. They carry no stamp and are therefore invisible to this check by construction. That is a decision, not an oversight.
