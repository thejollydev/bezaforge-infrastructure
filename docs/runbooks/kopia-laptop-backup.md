# The laptop's Kopia backup

The laptop's home directory is snapshotted every hour by Kopia into
`bezapool/kopia` on forge-hypervisor, over SFTP. Kopia encrypts and
deduplicates on the laptop, so nothing on the server is readable without the
repository password.

| Part | Where |
|---|---|
| The dataset, the `kopia` account (SFTP only, chrooted into the dataset) and its one key | `roles/kopia-target` here |
| A week of daily ZFS snapshots of the repository, out of the laptop's reach | `roles/sanoid`, template `kopia` |
| Kopia, KopiaUI, `~/.kopiaignore`, the hourly timer | `roles/kopia` in ansible-arch |
| The repository password | Typed once by the owner; kept in the desktop keyring and the password manager. Never in a repository |

What is left out, and why, is the `kopia_ignore` list in ansible-arch's
`roles/kopia/defaults/main.yml`. Projects are backed up in full, `.git` and
`.env` files included. The repository is on bezapool only, not off-site (the
owner's ruling, 2026-11-27).

## Setting it up

Once, in this order.

**1. The server side.** From this repository:

```bash
ansible-playbook ansible/site.yml --tags kopia-target,sanoid --limit forge-hypervisor --ask-become-pass --ask-vault-pass
```

**2. The laptop side.** From ansible-arch:

```bash
ansible-playbook site.yml --tags kopia --ask-become-pass --ask-vault-pass
```

**3. Create the repository.** It asks for the new repository password twice.
Put the password in the password manager first: without it the backup cannot
be read, by anyone.

```bash
kopia repository create sftp --host=10.10.10.10 --username=kopia --keyfile="$HOME/.ssh/kopia_ed25519" --known-hosts="$HOME/.ssh/known_hosts" --path=/repo
```

**4. Compress new data.**

```bash
kopia policy set --global --compression=zstd
```

**5. The first snapshot.** It reads the whole home directory, so run it docked
if you can; on Wi-Fi it is several times slower. After this the hourly timer
sends only what changed.

```bash
systemctl --user start kopia-backup.service
```

**6. A heartbeat, so a backup that stops is noticed.** In Uptime Kuma, add a
Push monitor named `Kopia laptop backup` with a heartbeat interval of 93600
seconds (26 hours) and the Uptime Kuma Alerts notification. Not shorter: the
laptop is shut overnight and away from home, and a tighter interval would
alarm every night. 26 hours alarms only when no backup has succeeded for more
than a day, the same slack as the Drive replica. Then put its push URL in the
file the backup script reads:

```bash
install -m 600 /dev/null ~/.config/kopia/heartbeat-url && "${EDITOR:-nano}" ~/.config/kopia/heartbeat-url
```

## Checking it

```bash
systemctl --user list-timers kopia-backup.timer
```

```bash
kopia snapshot list "$HOME"
```

```bash
journalctl --user -u kopia-backup.service -n 20
```

A run while the laptop is away from home and off WireGuard fails and is
retried next hour; the heartbeat only alarms when no run has succeeded for
its interval.

## Restoring

KopiaUI shows every snapshot and restores a file or folder from it. From the
command line:

```bash
kopia snapshot list "$HOME"
```

```bash
kopia restore <snapshot-id>/Documents/some-file ~/restored
```

On a new or rebuilt laptop: run the ansible-arch playbook, put the new
`~/.ssh/kopia_ed25519.pub` in `kopia_target_authorized_keys` in
`host_vars/forge-hypervisor/vars.yml` and deploy step 1 again, then connect
instead of create:

```bash
kopia repository connect sftp --host=10.10.10.10 --username=kopia --keyfile="$HOME/.ssh/kopia_ed25519" --known-hosts="$HOME/.ssh/known_hosts" --path=/repo
```

If the laptop has deleted or damaged the repository, the hypervisor holds a
week of daily ZFS snapshots of it: `zfs list -t snapshot bezapool/kopia`.
