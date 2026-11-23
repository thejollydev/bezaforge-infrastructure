#!/usr/bin/env python3
"""Write File Browser's two login passwords into forge-files' vault.

Both are chosen by the person running this, not generated, because both
are typed into a browser: the owner's login (read-write) and the phone's
(view and download only), #49. They are read into environment variables
without echoing, and this script copies them into the encrypted file as
the editor of `ansible-vault`.

The first time, the file does not exist yet, so use `create`:

    read -rs 'FB_ADMIN_PASSWORD?Password for your File Browser login: ' && echo && \\
    read -rs 'FB_PHONE_PASSWORD?Password for the phone login: ' && echo && \\
    export FB_ADMIN_PASSWORD FB_PHONE_PASSWORD && \\
    EDITOR="python3 -I scripts/filebrowser-vault-setup.py" \\
    ansible-vault create ansible/inventory/host_vars/forge-files/vault.yml; \\
    unset FB_ADMIN_PASSWORD FB_PHONE_PASSWORD

To change one later, set only that variable and use `edit` in place of
`create`. A key already in the file is replaced and an unset variable
leaves its key alone. Only key names are printed, never values.
"""

import json
import os
import re
import sys

# environment variable -> vault key, and the comment written above a new key
KEYS = {
    "FB_ADMIN_PASSWORD": (
        "vault_filebrowser_admin_password",
        "The owner's File Browser login, read-write (roles/filebrowser, #49).",
    ),
    "FB_PHONE_PASSWORD": (
        "vault_filebrowser_phone_password",
        "The phone's File Browser login, view and download only (roles/filebrowser, #49).",
    ),
}


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: run as EDITOR for `ansible-vault create` or `edit` (see the docstring)", file=sys.stderr)
        return 2
    vault_path = sys.argv[1]

    given = {var: os.environ[var] for var in KEYS if os.environ.get(var)}
    if not given:
        print("Neither FB_ADMIN_PASSWORD nor FB_PHONE_PASSWORD is set. Nothing was written.", file=sys.stderr)
        return 2
    for var, password in given.items():
        if len(password) < 12:
            print(f"{var} is shorter than 12 characters. Nothing was written.", file=sys.stderr)
            return 2
        if "\n" in password:
            print(f"{var} contains a newline. Nothing was written.", file=sys.stderr)
            return 2

    with open(vault_path, encoding="utf-8") as handle:
        text = handle.read()
    if not text.strip():
        text = "---\n"

    for var, password in given.items():
        key, comment = KEYS[var]
        # json.dumps gives a double-quoted string, which is also valid YAML.
        line = f"{key}: {json.dumps(password)}"
        pattern = re.compile(rf"^{re.escape(key)}\s*:.*$", re.MULTILINE)
        if pattern.search(text):
            text = pattern.sub(lambda _: line, text, count=1)
            action = "replaced"
        else:
            if not text.endswith("\n"):
                text += "\n"
            text += f"\n# {comment}\n# Written by scripts/filebrowser-vault-setup.py.\n{line}\n"
            action = "added"
        print(f"{action} {key}")

    with open(vault_path, "w", encoding="utf-8") as handle:
        handle.write(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
