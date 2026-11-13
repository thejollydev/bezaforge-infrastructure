#!/usr/bin/env python3
"""Write the list of outside addresses Prometheus probes into forge-ops's encrypted vars.

Run as the editor of `ansible-vault edit`, so the list goes into the
encrypted file without the file being opened by hand:

    EXTERNAL_PROBE_TARGETS="<https url> <https url> ..." \\
    EDITOR="python3 -I scripts/external-probes-vault-setup.py" \\
    ansible-vault edit ansible/inventory/host_vars/forge-ops/vault.yml

ansible-vault decrypts the file to a temporary copy, runs this on it, and
encrypts the result. The addresses are given on the command line and never
written into this repository, which is public.

Unlike a secret, this list is meant to change, so a second run REPLACES
`monitoring_external_probe_targets` with the new list. Nothing else in the
file is touched. Only the count is printed, never an address.
"""

import json
import os
import re
import sys

KEY = "monitoring_external_probe_targets"
COMMENT = [
    "# Addresses outside the fleet that Prometheus probes (roles/monitoring).",
    "# Written by scripts/external-probes-vault-setup.py.",
]
# The key, with either an inline value or the indented list lines under it,
# and the two comment lines above it when this script wrote them.
BLOCK = re.compile(
    r"(?:^" + re.escape(COMMENT[0]) + r"\n^" + re.escape(COMMENT[1]) + r"\n)?"
    r"^" + re.escape(KEY) + r"\s*:[^\n]*\n(?:^[ \t]+[^\n]*\n)*",
    re.MULTILINE,
)


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: run as EDITOR for `ansible-vault edit` (see the docstring)", file=sys.stderr)
        return 2
    vault_path = sys.argv[1]

    targets = os.environ.get("EXTERNAL_PROBE_TARGETS", "").split()
    if not targets:
        print("Set EXTERNAL_PROBE_TARGETS to one or more https URLs. Nothing was written.", file=sys.stderr)
        return 2
    bad = [index + 1 for index, target in enumerate(targets) if not re.fullmatch(r"https://[^\s\"'\\]+", target)]
    if bad:
        print(f"Not an https URL: item {', '.join(map(str, bad))} of the list. Nothing was written.", file=sys.stderr)
        return 2
    if len(set(targets)) != len(targets):
        print("The list repeats an address. Nothing was written.", file=sys.stderr)
        return 2

    with open(vault_path, encoding="utf-8") as handle:
        text = handle.read()
    if text and not text.endswith("\n"):
        text += "\n"

    found = len(BLOCK.findall(text))
    text = BLOCK.sub("", text).rstrip("\n")

    # json.dumps gives a double-quoted string, which is also valid YAML.
    lines = ["", *COMMENT, f"{KEY}:", *[f"  - {json.dumps(target)}" for target in targets]]
    with open(vault_path, "w", encoding="utf-8") as handle:
        handle.write((text + "\n" if text else "") + "\n".join(lines) + "\n")

    print(f"{'replaced' if found else 'added   '} {KEY} ({len(targets)} addresses)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
