#!/usr/bin/env python3
"""check-personal-strings.py — fail if the tree names something personal.

WHY THIS EXISTS
---------------
This repository is public. The admin account, the knowledge vault's name,
home paths and personal project names belong in the encrypted vars or in
untracked files, never in the tree (#1335). On 2026-09-29 they were moved
behind variables, and by 2026-10-24 the name had crept back into 28 files
through comments and runbooks, along with a personal project list. A rule
that depends on remembering it does not hold; this check makes it hold.

WHAT IT CHECKS
  Every tracked file, case-insensitively, for each string in the
  PERSONAL_STRINGS environment variable (one per line). The list itself is
  a repository secret, because a public list of the strings to keep out
  would publish them.

  A hit is reported as file:line only. The matching text is never printed,
  so the CI log does not leak what the secret holds.

  With PERSONAL_STRINGS unset or empty, it says so and passes.

USAGE
  PERSONAL_STRINGS="$(cat ~/.config/bezaforge-personal-strings)" scripts/check-personal-strings.py
"""
import os
import subprocess
import sys


def main() -> int:
    patterns = [p.strip() for p in os.environ.get("PERSONAL_STRINGS", "").splitlines() if p.strip()]
    if not patterns:
        print("PERSONAL_STRINGS is not set; nothing to check")
        return 0

    args = ["git", "grep", "-n", "-i", "-F", "-I"]
    for p in patterns:
        args += ["-e", p]
    result = subprocess.run(args, capture_output=True, text=True)
    if result.returncode == 1:
        print(f"ok: none of {len(patterns)} personal strings appear in the tree")
        return 0
    if result.returncode != 0:
        print(result.stderr, file=sys.stderr)
        return 2

    hits = sorted({":".join(line.split(":", 2)[:2]) for line in result.stdout.splitlines()})
    print(f"personal material in {len(hits)} place(s); the text is not shown:")
    for hit in hits:
        print(f"  {hit}")
    print("Move it behind a variable with an encrypted value, or use a placeholder (#1335).")
    return 1


if __name__ == "__main__":
    sys.exit(main())
