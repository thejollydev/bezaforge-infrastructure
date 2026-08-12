#!/usr/bin/env python3
"""deploy-drift-check.py — report roles merged to main but never deployed (#671).

WHY THIS EXISTS
---------------
A merged PR changes a file in git. It changes nothing on any host until
`ansible-playbook` runs. Nothing detected the gap: CI went green, the repo
read as correct, and no alert fired. That has bitten four times —

  #649  a Grafana alert merged 08-10 and was inert until 08-11. An alert
        built to catch a failure invisible in normal operation was itself
        invisibly absent.
  #164  a netbox digest auto-merged 08-10, undeployed for two days. Nobody
        reviewed it *or* shipped it, because auto-merge removed the only
        human touchpoint.
  #552  an entire safety-net remediation sat undeployed for a day. Every
        protection written because a failure went unalerted was itself
        inert.

Both 2026-08-11 instances were found only because a full `--check` sweep was
demanded by hand. That is not a process, so this asks the question on a
timer instead.

HOW IT WORKS
------------
Two clocks, compared per role:

  WANTED   the committer timestamp of the newest commit touching
           `ansible/roles/<role>` on main, read from the Gitea API.
  DEPLOYED the committer timestamp of the repo HEAD that was checked out
           when that role last ran, stamped onto the host by
           roles/deploy-stamp and scraped out of Prometheus.

If WANTED is newer than DEPLOYED, that host is running an older version of
that role than main describes. No git clone is needed anywhere: Gitea
answers `contents/` and `commits?path=` over plain HTTPS.

Reading the role list FROM GIT rather than from a list in this repo is
deliberate. A role that was added in a merged commit and never deployed is
exactly the bug being hunted; a baked-in list would have a blind spot
shaped precisely like it.

WHAT THIS CATCHES AND WHAT IT DOES NOT — stated plainly, because a check
whose blind spot is undocumented gets trusted past its evidence:

  CAUGHT  a role whose files changed on main and which has not been
          deployed to some host since; a host deployed from a dirty
          working tree (the stamp cannot be trusted, so it is reported
          rather than believed).
  MISSED  a host that has NEVER run roles/deploy-stamp. It exports no
          series, and an absent series is indistinguishable from a healthy
          one. Every play gained the stamper with `tags: always`, so the
          first deploy after #671 arms every host — but until a host is
          stamped once, it is invisible here. `--hosts` lists who is
          currently reporting, so that gap is at least visible on demand.
  MISSED  drift that is not in git at all — a file hand-edited on a host.
          That is `--check`'s job, not this one's.

USAGE
  scripts/deploy-drift-check.py             # summary + anything behind
  scripts/deploy-drift-check.py -v          # every host/role pair
  scripts/deploy-drift-check.py --hosts     # which hosts report stamps
  ROLES_OVERRIDE=adguard,ollama scripts/deploy-drift-check.py

EXIT CODES
  0  every stamped host is current with main
  1  at least one host is BEHIND main on at least one role
  2  the check is INVALID — Gitea or Prometheus was unreachable, or a host
     was deployed from a dirty tree. Not a pass and not a drift result;
     fix the cause before reading anything into the comparison.
"""

import json
import os
import ssl
import sys
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime

GITEA_URL = os.environ.get("GITEA_URL", "https://git.bezaforge.dev")
GITEA_REPO = os.environ.get("GITEA_REPO", "joseph/bezaforge-infrastructure")
PROM_URL = os.environ.get("PROM_URL", "https://prometheus.bezaforge.dev")
BRANCH = os.environ.get("BRANCH", "main")
ROLES_PATH = os.environ.get("ROLES_PATH", "ansible/roles")
TIMEOUT = int(os.environ.get("TIMEOUT", "15"))

# Grace is deliberately 0 here. The delay between "merged" and "fairly
# called drift" is expressed as the Grafana rule's `for:` window, in one
# place, where it can be seen and tuned without redeploying this script.
GRACE_SECONDS = int(os.environ.get("GRACE_SECONDS", "0"))

DEPLOYED_METRIC = "bezaforge_role_deployed_commit_timestamp_seconds"
DIRTY_METRIC = "bezaforge_role_deployed_dirty"


class Unreachable(Exception):
    """A data source could not be read. Always exit 2, never a pass."""


def _get(url):
    ctx = ssl.create_default_context()
    req = urllib.request.Request(url, headers={"Accept": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT, context=ctx) as r:
            return json.loads(r.read().decode())
    except (urllib.error.URLError, urllib.error.HTTPError, ValueError, OSError) as exc:
        raise Unreachable(f"{url} -> {exc}") from exc


def gitea_roles():
    """Every role directory on the branch, read from git rather than a list."""
    url = (
        f"{GITEA_URL}/api/v1/repos/{GITEA_REPO}/contents/"
        f"{urllib.parse.quote(ROLES_PATH)}?ref={urllib.parse.quote(BRANCH)}"
    )
    return sorted(e["name"] for e in _get(url) if e.get("type") == "dir")


def gitea_role_head_ts(role):
    """Committer epoch of the newest commit touching this role's directory.

    Gitea ignores `limit` on this endpoint but always returns newest-first,
    so element 0 is the answer and pagination never matters. Verified
    against `git log` on four paths with different counts (9/7/12/24) —
    the `path` filter is real, not silently ignored.
    """
    path = urllib.parse.quote(f"{ROLES_PATH}/{role}")
    url = (
        f"{GITEA_URL}/api/v1/repos/{GITEA_REPO}/commits"
        f"?sha={urllib.parse.quote(BRANCH)}&path={path}"
    )
    commits = _get(url)
    if not commits:
        return None
    raw = commits[0]["commit"]["committer"]["date"]
    return int(datetime.fromisoformat(raw).timestamp())


def prom_query(expr):
    """Instant query -> list of (labels, float value)."""
    url = f"{PROM_URL}/api/v1/query?query={urllib.parse.quote(expr)}"
    body = _get(url)
    if body.get("status") != "success":
        raise Unreachable(f"prometheus returned status={body.get('status')}")
    return [(r["metric"], float(r["value"][1])) for r in body["data"]["result"]]


def main():
    argv = sys.argv[1:]
    verbose = "-v" in argv or "--verbose" in argv
    hosts_only = "--hosts" in argv

    try:
        deployed = {
            (m.get("instance", "?"), m.get("role", "?")): v
            for m, v in prom_query(DEPLOYED_METRIC)
        }
        dirty = {
            (m.get("instance", "?"), m.get("role", "?")): v
            for m, v in prom_query(DIRTY_METRIC)
        }
    except Unreachable as exc:
        print(f"RESULT: INVALID — could not read Prometheus: {exc}")
        print("checked=0  behind=0  dirty=0  unstamped=0")
        return 2

    if hosts_only:
        seen = sorted({h for h, _ in deployed})
        print("hosts currently reporting deploy stamps:")
        for h in seen:
            n = len([1 for hh, _ in deployed if hh == h])
            print(f"  {h:<20} {n} roles")
        if not seen:
            print("  (none — no host has run roles/deploy-stamp yet)")
        return 0

    try:
        roles = gitea_roles()
    except Unreachable as exc:
        print(f"RESULT: INVALID — could not read Gitea: {exc}")
        print("checked=0  behind=0  dirty=0  unstamped=0")
        return 2

    override = os.environ.get("ROLES_OVERRIDE")
    if override:
        # Narrows the sweep to named roles. Primarily for proving this
        # script's own FAIL branch: a check whose red path has never been
        # exercised is not known to work.
        roles = [r for r in override.split(",") if r.strip()]

    wanted = {}
    for role in roles:
        try:
            ts = gitea_role_head_ts(role)
        except Unreachable as exc:
            print(f"RESULT: INVALID — could not read Gitea history for {role}: {exc}")
            print("checked=0  behind=0  dirty=0  unstamped=0")
            return 2
        if ts is not None:
            wanted[role] = ts

    behind = []
    dirty_pairs = []
    checked = 0

    print(f"{'HOST':<18} {'ROLE':<26} {'DEPLOYED':<20} {'MAIN':<20} RESULT")
    print(f"{'----':<18} {'----':<26} {'--------':<20} {'----':<20} ------")

    for (host, role), dep_ts in sorted(deployed.items()):
        want_ts = wanted.get(role)
        if want_ts is None:
            # The role has a stamp but no longer exists on the branch —
            # deleted upstream, stamp not yet reaped. Not drift.
            continue
        checked += 1
        dep_s = datetime.fromtimestamp(dep_ts).strftime("%Y-%m-%d %H:%M")
        want_s = datetime.fromtimestamp(want_ts).strftime("%Y-%m-%d %H:%M")

        if dirty.get((host, role), 0) >= 1:
            print(f"{host:<18} {role:<26} {dep_s:<20} {want_s:<20} *** DIRTY TREE ***")
            dirty_pairs.append((host, role))
            continue

        if want_ts > dep_ts + GRACE_SECONDS:
            days = (want_ts - dep_ts) / 86400.0
            print(
                f"{host:<18} {role:<26} {dep_s:<20} {want_s:<20} "
                f"*** BEHIND {days:.1f}d ***"
            )
            behind.append((host, role))
        elif verbose:
            print(f"{host:<18} {role:<26} {dep_s:<20} {want_s:<20} ok")

    unstamped = len(wanted) and not deployed
    print()
    print(
        f"checked={checked}  behind={len(behind)}  "
        f"dirty={len(dirty_pairs)}  unstamped={int(bool(unstamped))}"
    )

    if not deployed:
        print("RESULT: INVALID — no host reports a deploy stamp at all.")
        print("  Nothing has run roles/deploy-stamp yet, so nothing can be compared.")
        print("  Deploy it: cd ansible && ansible-playbook site.yml \\")
        print("               --ask-become-pass --ask-vault-pass")
        return 2

    if dirty_pairs:
        print("RESULT: INVALID — a host was deployed from a dirty working tree.")
        print("  Its stamp names a commit that does not describe what was applied,")
        print("  so it cannot be compared. Commit or stash, then redeploy that role.")
        for host, role in dirty_pairs:
            print(f"    {host}: {role}")
        return 2

    if behind:
        print("RESULT: BEHIND — main has changes these hosts have never received.")
        print("  Deploy the affected roles, then verify the LIVE artifact, not the")
        print("  PLAY RECAP (a tag-scoped run only touches the tags you name):")
        tags = ",".join(sorted({r for _, r in behind}))
        print("    cd ansible && ansible-playbook site.yml \\")
        print(f"      --tags {tags} --ask-become-pass --ask-vault-pass")
        return 1

    print(f"RESULT: CURRENT — all {checked} host/role pairs match main.")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Unreachable as exc:
        print(f"RESULT: INVALID — {exc}")
        print("checked=0  behind=0  dirty=0  unstamped=0")
        sys.exit(2)
