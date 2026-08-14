#!/usr/bin/env python3
"""check-alert-rules.py — validate the Grafana alert provisioning file.

WHY THIS EXISTS
---------------
`alert-rules.yaml` is excluded from BOTH linters — from yamllint and from
ansible-lint — because it is a verbatim Grafana provisioning-API export
whose indentation style is the exporter's, not ours (FORGE-58). That
exclusion is correct, but it left the file with **no validation at all**:
a YAML syntax error in it passes CI green.

The consequence is not cosmetic. Grafana refuses to provision a file it
cannot parse, so a broken rules file means the alerts silently do not
exist — including the ones written specifically to catch problems that
are invisible in normal operation. An alert that was never provisioned
and an alert that never fires look identical from the outside.

This was not hypothetical. On 2026-08-14, editing this file to describe a
new failure mode introduced an unescaped apostrophe inside a single-quoted
YAML scalar and broke the document. Both linters passed it. Only a
hand-run parse caught it.

WHAT IT CHECKS
  * the document parses as YAML at all
  * every group has a name and a rules list
  * every rule has uid / title / condition
  * uids are unique (Grafana silently keeps only one of a duplicate pair)
  * annotations carry a summary, so a firing alert is never a bare title

USAGE
  scripts/check-alert-rules.py [path]     # defaults to the repo's file

EXIT CODES
  0  valid
  1  invalid — the message names the rule and the problem
"""

import sys
from pathlib import Path

import yaml

DEFAULT = (
    "ansible/roles/monitoring/files/grafana/provisioning/alerting/alert-rules.yaml"
)


def main():
    path = Path(sys.argv[1] if len(sys.argv) > 1 else DEFAULT)
    if not path.is_file():
        print(f"FAIL: {path} does not exist")
        return 1

    try:
        doc = yaml.safe_load(path.read_text())
    except yaml.YAMLError as exc:
        # The common cause is an apostrophe inside a single-quoted scalar,
        # which must be doubled ('') in YAML. Say so — the raw parser error
        # points at a column and not at the reason.
        print(f"FAIL: {path} is not valid YAML\n{exc}")
        print(
            "\nHINT: a literal ' inside a single-quoted YAML scalar must be "
            "written ''. Alert descriptions are single-quoted, so an "
            "apostrophe in prose breaks the document."
        )
        return 1

    problems = []
    uids = {}
    rule_count = 0

    for gi, group in enumerate(doc.get("groups") or []):
        if not group.get("name"):
            problems.append(f"group[{gi}] has no name")
        for rule in group.get("rules") or []:
            rule_count += 1
            title = rule.get("title", "<untitled>")
            for field in ("uid", "title", "condition"):
                if not rule.get(field):
                    problems.append(f"rule {title!r} is missing {field}")
            uid = rule.get("uid")
            if uid:
                if uid in uids:
                    problems.append(
                        f"duplicate uid {uid!r}: {uids[uid]!r} and {title!r} "
                        "— Grafana keeps only one"
                    )
                uids[uid] = title
            if not (rule.get("annotations") or {}).get("summary"):
                problems.append(f"rule {title!r} has no annotations.summary")

    if not rule_count:
        problems.append("no rules found at all — the file provisions nothing")

    if problems:
        print(f"FAIL: {path}")
        for p in problems:
            print(f"  - {p}")
        return 1

    print(f"OK: {path} — {rule_count} rules, {len(uids)} unique uids")
    return 0


if __name__ == "__main__":
    sys.exit(main())
