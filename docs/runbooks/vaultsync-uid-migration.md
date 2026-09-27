# Runbook — Move vaultsync off uid 1000, retire forge-ops' gdrive mount (#965)

Written for **#965**. Run once. A fresh host needs none of this, because `roles/gdrive-replica` creates vaultsync at uid 900 from the start.

## Why

The bezapool exports use `sec=sys`, which trusts the client's **numeric** uid. On the hypervisor, vaultsync was uid 1000. On every forge-* VM, uid 1000 is joseph. So joseph on an NFS client *was* vaultsync on the hypervisor. This was shown, not assumed: an unprivileged `touch` in `/bezapool/gdrive` from forge-ops succeeded.

Two changes close it:

1. **forge-ops stops mounting `/bezapool/gdrive`.** Nothing has used the mount since Jellyfin and Seedbox were retired (#485), and it was the only exported path the collision reached.
2. **vaultsync moves to uid/gid 900.** That removes the collision itself, so a future export (for example `/bezapool/vault`) can't bring it back.

## ⚠️ Order matters

`docker.service` on forge-ops carries `RequiresMountsFor=/mnt/bezapool/gdrive` (`roles/docker/templates/wait-for-nfs.conf.j2`, rendered from `nfs_mounts`). Rewrite that drop-in and `daemon-reload` **before** unmounting, so Docker no longer depends on the mount when it goes.

Do **not** rewrite it by running the docker role. Its handler is `reload systemd and restart docker`, which bounces every container on forge-ops for a change that only needs a reload. Step 1 renders the same template ad hoc, so the next docker role run finds nothing to change.

Unmount on forge-ops (step 2) **before** removing the export on the hypervisor (step 3). The other way round leaves forge-ops holding a stale NFS handle on a `hard` mount.

## 1. forge-ops: drop gdrive from Docker's mount dependencies

```bash
cd ~/Projects/bezaforge-infrastructure/ansible && ansible forge-ops -b --ask-become-pass --ask-vault-pass -m template -a "src=roles/docker/templates/wait-for-nfs.conf.j2 dest=/etc/systemd/system/docker.service.d/wait-for-nfs.conf mode=0644" && ansible forge-ops -b --ask-become-pass --ask-vault-pass -m systemd -a "daemon_reload=true"
```

Expect the drop-in to name only `/mnt/bezapool/forge-ops-backup`. Docker does not restart.

## 2. forge-ops (and the other `common` hosts): unmount and deploy `common`

```bash
cd ~/Projects/bezaforge-infrastructure/ansible && ansible-playbook site.yml -l forge-ops,forge-ai,forge-agents --tags common --ask-become-pass --ask-vault-pass
```

forge-ops reports `changed` on "Unmount retired NFS shares and remove them from fstab". forge-ai and forge-agents run it only to update their deploy stamps (they have `nfs_client: false`).

## 3. Hypervisor: renumber vaultsync, re-chown, retire the export

One command. It stops the three vaultsync-owned units, renumbers the user and group, re-chowns everything that carried 1000, removes the two `/bezapool/gdrive` export lines (keeping a backup of `/etc/exports`), and prints the result.

```bash
ssh root@10.10.10.10 'set -e; systemctl stop gdrive-replica.timer bezaforge-syncthing-check.timer syncthing@vaultsync.service; systemctl is-active gdrive-replica.service && { echo "gdrive-replica is mid-run; wait and re-run"; exit 1; }; if pgrep -u vaultsync; then echo "vaultsync still has processes; stop them first"; exit 1; fi; groupmod -g 900 vaultsync; usermod -u 900 vaultsync; chown -R -h --from=1000 900 /bezapool/gdrive /bezapool/vault /home/vaultsync; chown -R -h --from=:1000 :900 /bezapool/gdrive /bezapool/vault /home/vaultsync; cp -a /etc/exports /etc/exports.bak-965; sed -i "/^\/bezapool\/gdrive[[:space:]]/d" /etc/exports; exportfs -ra; id vaultsync; echo "left at 1000: $(find /bezapool/gdrive /bezapool/vault /home/vaultsync -xdev \( -uid 1000 -o -gid 1000 \) | wc -l)"; grep -v "^#" /etc/exports'
```

Expect `uid=900(vaultsync) gid=900(vaultsync)`, `left at 1000: 0`, and no `/bezapool/gdrive` line in the exports.

ZFS snapshots are read-only and keep the old numbers. A file restored from a snapshot taken before this date comes back owned by 1000, so re-chown it to vaultsync after restoring.

⚠️ This step missed `/tmp/gdrive-replica.lock`, which the last uid-1000 run had left behind. `/tmp` is sticky and `fs.protected_regular=2`, so uid 900 could not open it, and the next nightly run failed on its first line (2026-09-27, #1286). The lock now lives in the unit's `RuntimeDirectory`, and the role removes the old file. Step 5's timer check could not catch it, because the service does not run until 03:30.

## 4. Hypervisor: converge and restart through the roles

```bash
cd ~/Projects/bezaforge-infrastructure/ansible && ansible-playbook site.yml -l forge-hypervisor --tags gdrive-replica,syncthing --ask-become-pass --ask-vault-pass
```

The user and group tasks should report `ok`, because step 3 already made them match. The roles start `gdrive-replica.timer`, `syncthing@vaultsync` and the sync-check timer again.

## 5. Verify

```bash
ssh root@10.10.10.10 'systemctl is-active gdrive-replica.timer syncthing@vaultsync bezaforge-syncthing-check.timer; exportfs -v | grep -c gdrive'
ssh forge-ops 'findmnt /mnt/bezapool/gdrive; grep gdrive /etc/fstab; systemctl show docker -p RequiresMountsFor'
```

Expect three `active` lines and `0` gdrive exports. On forge-ops, expect no mount, no fstab line, and a `RequiresMountsFor` of `/mnt/bezapool/forge-ops-backup` only. Then run `scripts/deploy-drift-check.py`, which should report CURRENT. Finally, confirm the vault is still syncing: `bezaforge-syncthing-check` pushes to Uptime Kuma, and the vault should read the same on the laptop and on forge-agents.
