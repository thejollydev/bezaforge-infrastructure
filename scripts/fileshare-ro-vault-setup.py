#!/usr/bin/env python3
"""Write the read-only share login's password into forge-hypervisor's vars.

The password is the one typed into the phone's SMB app (#49), so it is
chosen by the person running this, not generated. It is read into an
environment variable without echoing, and this script copies it into the
encrypted file as the editor of `ansible-vault edit`:

    read -rs 'FILESHARE_RO_PASSWORD?Password for bezashare-ro: ' && export FILESHARE_RO_PASSWORD && \\
    EDITOR="python3 -I scripts/fileshare-ro-vault-setup.py" \\
    ansible-vault edit ansible/inventory/host_vars/forge-hypervisor/vault.yml; \\
    unset FILESHARE_RO_PASSWORD

ansible-vault decrypts the file to a temporary copy, runs this on it, and
encrypts the result. A key already in the file is replaced, so running it
again changes the password. Only the key name is printed, never the value.
"""

import json
import os
import re
import sys

KEY = "vault_fileshare_smb_ro_password"


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: run as EDITOR for `ansible-vault edit` (see the docstring)", file=sys.stderr)
        return 2
    vault_path = sys.argv[1]

    password = os.environ.get("FILESHARE_RO_PASSWORD", "")
    if len(password) < 12:
        print("FILESHARE_RO_PASSWORD is unset or shorter than 12 characters. Nothing was written.", file=sys.stderr)
        return 2
    if "'" in password or "\n" in password:
        # The role passes it to smbpasswd inside single quotes.
        print("The password may not contain a single quote or a newline. Nothing was written.", file=sys.stderr)
        return 2

    with open(vault_path, encoding="utf-8") as handle:
        text = handle.read()

    # json.dumps gives a double-quoted string, which is also valid YAML.
    line = f"{KEY}: {json.dumps(password)}"
    pattern = re.compile(rf"^{re.escape(KEY)}\s*:.*$", re.MULTILINE)
    if pattern.search(text):
        text = pattern.sub(lambda _: line, text, count=1)
        action = "replaced"
    else:
        if text and not text.endswith("\n"):
            text += "\n"
        text += (
            "\n# The read-only share login used by the phone (roles/fileshare, #49).\n"
            "# Written by scripts/fileshare-ro-vault-setup.py.\n"
            f"{line}\n"
        )
        action = "added"

    with open(vault_path, "w", encoding="utf-8") as handle:
        handle.write(text)
    print(f"{action} {KEY}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
