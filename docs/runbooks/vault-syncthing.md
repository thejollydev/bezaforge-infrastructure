# Runbook — The vault on Syncthing

The knowledge vault's files sync two-way between three copies, with the laptop
as the only git actor (BezaForge ADR 0012, Brizza ADR 0019). This runbook
covers the first deployment (#1216), the tests that prove it, and what to do
when something goes wrong.

| Copy | Path | Runs as | Managed by |
|---|---|---|---|
| Laptop (`jolly-LOQ-arch`) | `~/Vaults/never-knowledge` | `joseph`, user service | by hand (step 3) |
| forge-hypervisor | `/bezapool/vault` (ZFS, snapshotted, restic offsite) | `vaultsync` | `roles/syncthing` |
| forge-agents | `/home/joseph/Vaults/never-knowledge` | `joseph` | `roles/syncthing` |

- **Ignored everywhere:** `.git` at any depth, `/.obsidian` and `/.trash` at
  the root. `.stignore` is never synced, so each copy has its own with the
  same three patterns.
- **No discovery, no relays.** The servers listen on fixed addresses
  (`10.10.10.10:22000`, `10.10.50.20:22000`) and the laptop dials them, from
  Home WiFi or over WireGuard.
- **Git:** the laptop's `never4ga-vault-commit.timer` commits every 15 minutes
  and so picks up what the servers wrote. Syncthing's marker, its ignore file
  and conflict copies are in the vault's `.gitignore`.
- **Watching it:** a timer on forge-hypervisor pushes two Uptime Kuma
  monitors every 5 minutes. *In sync* checks that Syncthing answers, the
  folder has no errors, forge-agents and the hypervisor are connected, and no
  connected device stays behind for more than 15 minutes. *Conflicts* checks
  that no `*.sync-conflict-*` copy exists. A check that stops running goes
  quiet, and Kuma marks it down.

Every `ansible-playbook` and `ansible-vault` command below prompts for a
password, so it needs your own terminal.

---

## First deployment

### 1. Clear the vault-sync leftovers (forge-hypervisor, by hand)

Both are hand-managed, so there is no code change for them.

**The Drive export to forge-agents.** `/etc/exports` still exports
`/bezapool/gdrive` read-write to `10.10.50.20`, which was forge-brizza and is
now forge-agents. This removes that one line, keeps a copy of the file, and
leaves the forge-ops lines alone:

```bash
ssh root@10.10.10.10 "cp -a /etc/exports /etc/exports.bak-2026-09-14 && sed -i '/^\/bezapool\/gdrive[[:space:]]*10\.10\.50\.20(/d' /etc/exports && exportfs -ra && grep -v '^#' /etc/exports && exportfs -v | grep -c '10.10.50.20'"
```

Expect the remaining export lines (none naming `10.10.50.20`), then `0`.

**The lease sysctl.** `/etc/sysctl.d/99-vault-sync-nfs.conf` set
`fs.leases-enable=0` for the retired clone. Removing the file only changes
anything at the next reboot, so this also applies the default now, while
someone is watching:

```bash
ssh root@10.10.10.10 'rm /etc/sysctl.d/99-vault-sync-nfs.conf && sysctl -w fs.leases-enable=1 && sysctl fs.leases-enable'
```

Expect `fs.leases-enable = 1`. Leases re-enable NFSv4 delegations for
forge-ops's mounts. The next morning, confirm the nightly jobs that write
over NFS (`bezaforge-db-dump` at 02:30, `bezaforge-backup-rsync` at 02:45)
succeeded.

### 2. Install and generate identities (after the role's pull request is merged)

```bash
cd ~/Projects/bezaforge-infrastructure && git switch main && git pull && cd ansible && ansible-playbook site.yml -l forge-hypervisor,forge-agents --tags syncthing --ask-become-pass --ask-vault-pass
```

On each host this installs Syncthing 2.x, generates its identity, writes
`.stfolder` and `.stignore`, and adds the folder shared with the laptop only.
The servers do not know each other's IDs yet. Each host prints a
**`RECORD THIS:`** line with its device ID. Both IDs go into host_vars in a
second pull request (step 4).

Nothing syncs yet: the laptop has not been told about either server.

### 3. Pair the laptop (by hand)

Replace `<HYPERVISOR-ID>` and `<AGENTS-ID>` with the two IDs from step 2.
Order matters: the ignore file must exist before the folder is added, or the
laptop would offer `.git` and `.obsidian` to the servers.

1. Write the laptop's ignore file and folder marker:

   ```bash
   printf '%s\n' '// Same patterns as roles/syncthing on the servers. Not synced; keep them in step.' '.git' '/.obsidian' '/.trash' > ~/Vaults/never-knowledge/.stignore && mkdir -p ~/Vaults/never-knowledge/.stfolder && cat ~/Vaults/never-knowledge/.stignore
   ```

2. Add both servers as devices, through the laptop's own API:

   ```bash
   K=$(grep -o '<apikey>[^<]*' ~/.local/state/syncthing/config.xml | cut -d'>' -f2); for d in 'forge-hypervisor <HYPERVISOR-ID> 10.10.10.10' 'forge-agents <AGENTS-ID> 10.10.50.20'; do set -- $d; curl -fsS -X POST -H "X-API-Key: $K" -H 'Content-Type: application/json' http://127.0.0.1:8384/rest/config/devices -d "{\"deviceID\":\"$2\",\"name\":\"$1\",\"addresses\":[\"tcp://$3:22000\",\"quic://$3:22000\"]}" && echo "added $1"; done
   ```

3. Add the folder, shared with both:

   ```bash
   K=$(grep -o '<apikey>[^<]*' ~/.local/state/syncthing/config.xml | cut -d'>' -f2); ME=$(syncthing device-id); curl -fsS -X POST -H "X-API-Key: $K" -H 'Content-Type: application/json' http://127.0.0.1:8384/rest/config/folders -d "{\"id\":\"never-knowledge\",\"label\":\"never-knowledge\",\"path\":\"$HOME/Vaults/never-knowledge\",\"type\":\"sendreceive\",\"fsWatcherEnabled\":true,\"rescanIntervalS\":3600,\"devices\":[{\"deviceID\":\"$ME\"},{\"deviceID\":\"<HYPERVISOR-ID>\"},{\"deviceID\":\"<AGENTS-ID>\"}]}" && echo "folder added"
   ```

The laptop dials both servers and sends them the vault, about 11 MB without
`.git` and `.obsidian`. Watch it finish:

```bash
ssh root@10.10.10.10 'find /bezapool/vault -type f | wc -l'; ssh joseph@10.10.50.20 'find ~/Vaults/never-knowledge -type f | wc -l'; find ~/Vaults/never-knowledge -path '*/.git' -prune -o -path '*/.obsidian' -prune -o -path '*/.trash' -prune -o -type f -print | wc -l
```

The three counts should match within a minute or two. Each includes that
copy's own `.stignore`, which Syncthing never syncs, so it evens out.

### 4. Record the IDs and wire up Uptime Kuma (second pull request)

**Device IDs.** Give the two IDs from step 2 to the session preparing the
pull request, which sets `syncthing_device_id` in
`inventory/host_vars/forge-hypervisor/vars.yml` and
`inventory/host_vars/forge-agents.yml`.

**Two push monitors.** At <https://uptime.bezaforge.dev> add two monitors:

| Field | *In sync* | *Conflicts* |
|---|---|---|
| Monitor Type | Push | Push |
| Friendly Name | `Vault sync — in sync` | `Vault sync — conflicts` |
| Heartbeat Interval | 900 seconds | 900 seconds |
| Notifications | Uptime Kuma Alerts | Uptime Kuma Alerts |

Copy each monitor's **Push URL**. The query string does not matter: the check
drops it and sends its own `status` and `msg`.

**The vault edit**, on the second pull request's branch. This also removes
`vault_sync_webhook_token`, the retired clone's leftover:

```bash
cd ~/Projects/bezaforge-infrastructure/ansible && ansible-vault edit inventory/host_vars/forge-hypervisor/vault.yml
```

Delete the `vault_sync_webhook_token:` line and add:

```yaml
vault_syncthing_insync_push_url: "<Push URL of Vault sync — in sync>"
vault_syncthing_conflicts_push_url: "<Push URL of Vault sync — conflicts>"
```

### 5. Pair the servers (after the second pull request is merged)

```bash
cd ~/Projects/bezaforge-infrastructure && git switch main && git pull && cd ansible && ansible-playbook site.yml -l forge-hypervisor,forge-agents --tags syncthing --ask-become-pass --ask-vault-pass
```

Run it a second time. The recap must show `changed=0` for both hosts.

This run also starts the sync check's timer, and that run is its approval: it
is a recurring job, and Brizza build plan rule 4 wants a first run approved.
See its first result:

```bash
ssh root@10.10.10.10 'systemctl start bezaforge-syncthing-check.service; journalctl -u bezaforge-syncthing-check.service -n 4 --no-pager -o cat'
```

Expect `in sync: up: in sync` and `conflicts: up: no conflict copies`, and
both Kuma monitors green.

### 6. Prove it

The build step is done when all three pass. The test files are plain text at
the vault root; they are committed and then deleted, so they pass through git
history once.

**Laptop to servers, within a minute:**

```bash
date -Is > ~/Vaults/never-knowledge/syncthing-test-laptop.txt
```

```bash
sleep 60; ssh root@10.10.10.10 cat /bezapool/vault/syncthing-test-laptop.txt; ssh joseph@10.10.50.20 cat ~/Vaults/never-knowledge/syncthing-test-laptop.txt
```

Expect the same timestamp twice.

**forge-agents to the laptop and bezapool, then into git:**

```bash
ssh joseph@10.10.50.20 'date -Is > ~/Vaults/never-knowledge/syncthing-test-agents.txt'
```

```bash
sleep 60; cat ~/Vaults/never-knowledge/syncthing-test-agents.txt; ssh root@10.10.10.10 cat /bezapool/vault/syncthing-test-agents.txt
```

Wait for the next quarter hour, then:

```bash
git -C ~/Vaults/never-knowledge log --oneline -1 -- syncthing-test-agents.txt
```

Expect a commit from the laptop's timer.

**A deliberate conflict, reported.** Stop Syncthing on forge-agents, change
the same file on both sides, then start it again:

```bash
ssh -t joseph@10.10.50.20 'sudo systemctl stop syncthing@joseph && echo "edited on forge-agents" > ~/Vaults/never-knowledge/syncthing-test-agents.txt'
```

```bash
echo "edited on the laptop" > ~/Vaults/never-knowledge/syncthing-test-agents.txt
```

```bash
sleep 30; ssh -t joseph@10.10.50.20 'sudo systemctl start syncthing@joseph'
```

forge-agents' edit is older, so it becomes the conflict copy, and the copy
syncs everywhere. Then run the check:

```bash
sleep 60; ls ~/Vaults/never-knowledge | grep sync-conflict; ssh root@10.10.10.10 'systemctl start bezaforge-syncthing-check.service; journalctl -u bezaforge-syncthing-check.service -n 4 --no-pager -o cat'
```

Expect one `syncthing-test-agents.sync-conflict-…txt`, `conflicts: down: 1
conflict copies: …`, and *Vault sync — conflicts* red in Uptime Kuma.

**Clean up**, then confirm both monitors return to green:

```bash
rm ~/Vaults/never-knowledge/syncthing-test-*.txt && sleep 60 && ssh root@10.10.10.10 'systemctl start bezaforge-syncthing-check.service; journalctl -u bezaforge-syncthing-check.service -n 4 --no-pager -o cat'
```

---

## When something goes wrong

**A conflict copy.** Two copies changed the same file before either heard from
the other. Open both, keep the right content in the original file, and delete
the `.sync-conflict-` copy on any machine; the deletion syncs. The monitor
clears on the next check. Recurring conflicts on the same files mean two
writers are working on them, which ADR 0012 says to revisit.

**"forge-agents not connected" or "forge-hypervisor … behind".** Look at the
server's side first:

```bash
ssh -t joseph@10.10.50.20 'systemctl status syncthing@joseph --no-pager; sudo journalctl -u syncthing@joseph -n 30 --no-pager'
```

For the GUI, tunnel it to the laptop and open <http://127.0.0.1:8385>:

```bash
ssh -N -L 8385:127.0.0.1:8384 joseph@10.10.50.20
```

**"folder marker missing".** On the hypervisor, `bezapool/vault` is not
mounted. Syncthing has stopped the folder rather than syncing into an empty
directory, which is what the marker is for. Mount the dataset
(`zfs mount bezapool/vault`), then check again.

**A rebuilt server.** It generates a new identity, and the role stops with
"identity is not the one on record". Either restore `cert.pem` and `key.pem`
into `~/.local/state/syncthing` for the Syncthing user from backup, or record
the new ID (step 4) and replace the device on the laptop (step 3, with the
old device removed in the laptop's GUI).

## Rollback

Stop and disable Syncthing on the servers
(`systemctl disable --now syncthing@vaultsync` on the hypervisor,
`sudo systemctl disable --now syncthing@joseph` on forge-agents) and remove
the folder from the laptop's GUI. Every copy keeps its files, and the laptop's
git history is untouched. Remove `syncthing` from both plays in `site.yml` to
keep it from coming back.
