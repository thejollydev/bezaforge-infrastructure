#!/usr/bin/env python3
"""Write Umami's secrets and tunnel values into forge-ops's encrypted vars.

Run as the editor of `ansible-vault edit`, so the values go from where they
were made into the encrypted file without being typed, pasted or shown:

    UMAMI_PUBLIC_HOSTNAME=<the public hostname> \\
    UMAMI_TUNNEL_CREDENTIALS=~/.cloudflared/<tunnel id>.json \\
    EDITOR="python3 -I scripts/umami-vault-setup.py" \\
    ansible-vault edit ansible/inventory/host_vars/forge-ops/vault.yml

ansible-vault decrypts the file to a temporary copy, runs this on it, and
encrypts the result. The three secrets are generated here. The tunnel's ID,
account and secret are read from the credentials file that
`cloudflared tunnel create` wrote.

A key that is already in the file is left alone and reported, so a second
run changes nothing and never replaces a secret a running Umami depends on.
Only key names are printed, never a value.
"""

import json
import os
import re
import secrets
import sys


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: run as EDITOR for `ansible-vault edit` (see the docstring)", file=sys.stderr)
        return 2
    vault_path = sys.argv[1]

    hostname = os.environ.get("UMAMI_PUBLIC_HOSTNAME", "").strip()
    credentials_path = os.path.expanduser(os.environ.get("UMAMI_TUNNEL_CREDENTIALS", "").strip())
    if not hostname or not credentials_path:
        print("Set UMAMI_PUBLIC_HOSTNAME and UMAMI_TUNNEL_CREDENTIALS. Nothing was written.", file=sys.stderr)
        return 2
    if not re.fullmatch(r"[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+", hostname):
        print(f"UMAMI_PUBLIC_HOSTNAME does not look like a hostname: {hostname!r}", file=sys.stderr)
        return 2

    try:
        with open(credentials_path, encoding="utf-8") as handle:
            credentials = json.load(handle)
        tunnel = {
            "umami_tunnel_id": credentials["TunnelID"],
            "umami_tunnel_account_tag": credentials["AccountTag"],
            "umami_tunnel_secret": credentials["TunnelSecret"],
        }
    except (OSError, ValueError, KeyError) as error:
        print(f"Could not read the tunnel credentials file: {type(error).__name__}", file=sys.stderr)
        return 2

    wanted = {
        "umami_db_password": secrets.token_hex(32),
        "umami_app_secret": secrets.token_hex(32),
        "umami_two_factor_encryption_key": secrets.token_hex(32),
        "umami_public_hostname": hostname,
        **tunnel,
    }

    with open(vault_path, encoding="utf-8") as handle:
        text = handle.read()

    present = [key for key in wanted if re.search(rf"^{re.escape(key)}\s*:", text, re.MULTILINE)]
    missing = [key for key in wanted if key not in present]

    if missing:
        lines = [
            "",
            "# Umami and its Cloudflare Tunnel (roles/services). Written by",
            "# scripts/umami-vault-setup.py.",
        ]
        # json.dumps gives a double-quoted string, which is also valid YAML.
        lines += [f"{key}: {json.dumps(str(wanted[key]))}" for key in missing]
        if text and not text.endswith("\n"):
            text += "\n"
        with open(vault_path, "w", encoding="utf-8") as handle:
            handle.write(text + "\n".join(lines) + "\n")

    for key in missing:
        print(f"added    {key}")
    for key in present:
        print(f"kept     {key} (already set)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
