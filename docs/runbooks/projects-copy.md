# Runbook — The Projects copy on bezapool

The laptop's `~/Projects` goes one way to the hypervisor by Syncthing and
shows up read-only in File Browser as the `projects` source. It is the
off-laptop copy of every working tree, including work that is not committed
or pushed yet, and sanoid's snapshots let you go back to an earlier day.

| Copy | Path | Folder type | Managed by |
|---|---|---|---|
| Laptop | `~/Projects` | send-only | by hand (step 4) |
| forge-hypervisor | `/bezapool/projects` (ZFS, snapshotted) | receive-only | `roles/syncthing` (`syncthing_extra_folders`) |
| forge-files | `/srv/projects`, a read-only bind mount | — | `roles/forge-files-host`, `roles/filebrowser` |

- **What stays on the laptop:** secrets (`.env` files, Terraform state and
  `.tfvars`, `.terraform`, keys, `settings.local.json`), build output and
  caches (`node_modules`, `.venv`, `target`, `dist`, `build`, `.next` and
  similar), and `.git`. The list is `syncthing_projects_ignore_patterns` in
  `group_vars/all`. The laptop's `.stignore` must carry the same patterns,
  because ignores are local and the sender's are the ones that keep a file
  from leaving. The server's copy is a second guard.
- **One way.** The laptop only sends and the hypervisor only receives, so
  nothing on the server side can change a working tree. A deletion on the
  laptop is a deletion here too; the snapshots are what make it a backup.
  Snapshots follow the share's template: 14 daily, 8 weekly, 6 monthly.
- **Not offsite.** Restic does not take this dataset. The repositories are
  on three forges already, and the working trees are about 43 GB.
- **Not watched.** The sync check covers the vault only.
- **Who can see it:** both File Browser logins, the phone's included, view
  and download only.

Every `ansible-playbook` command below prompts for the vault password, so
it needs your own terminal.

---

## First deployment

### 1. Create the dataset (forge-hypervisor, by hand)

```bash
ssh root@10.10.10.10 'zfs create bezapool/projects && findmnt /bezapool/projects'
```

The role refuses to configure the folder until this is mounted, and sanoid
errors on a dataset that does not exist, so this comes first.

### 2. The hypervisor side

Adds the receive-only folder, its snapshots, and the read-only bind mount
into forge-files. The `forge-files-host` tag restarts the container when the
mounts change.

```bash
cd ~/Projects/bezaforge-infrastructure/ansible && ansible-playbook site.yml --limit forge-hypervisor --tags syncthing,sanoid,forge-files-host --ask-vault-pass
```

### 3. File Browser

```bash
cd ~/Projects/bezaforge-infrastructure/ansible && ansible-playbook site.yml --limit forge-files --tags filebrowser --ask-vault-pass
```

### 4. The laptop side (by hand)

The ignore file goes first, so the first scan already leaves secrets out.
Write it from the same list the server uses:

```bash
cd ~/Projects/bezaforge-infrastructure/ansible && { echo '// Same patterns as syncthing_projects_ignore_patterns (group_vars/all). Not synced; keep them in step.'; python3 -c 'import yaml; [print(p) for p in yaml.safe_load(open("inventory/group_vars/all/vars.yml"))["syncthing_projects_ignore_patterns"]]'; } > ~/Projects/.stignore && mkdir -p ~/Projects/.stfolder && cat ~/Projects/.stignore
```

Then add the folder, send-only, shared with the hypervisor (its ID is
`syncthing_device_id` in `host_vars/forge-hypervisor`):

```bash
K=$(grep -o '<apikey>[^<]*' ~/.local/state/syncthing/config.xml | cut -d'>' -f2); ME=$(syncthing device-id); HV=$(grep -oP '^syncthing_device_id: \K\S+' ~/Projects/bezaforge-infrastructure/ansible/inventory/host_vars/forge-hypervisor/vars.yml); curl -fsS -X POST -H "X-API-Key: $K" -H 'Content-Type: application/json' http://127.0.0.1:8384/rest/config/folders -d "{\"id\":\"projects\",\"label\":\"Projects\",\"path\":\"$HOME/Projects\",\"type\":\"sendonly\",\"fsWatcherEnabled\":true,\"rescanIntervalS\":3600,\"devices\":[{\"deviceID\":\"$ME\"},{\"deviceID\":\"$HV\"}]}" && echo "folder added"
```

The first send is about 43 GB, most of it `video-projects`.

### 5. Prove it

- **It arrived.** Once the laptop's GUI shows the folder up to date:
  `ssh root@10.10.10.10 'du -sh /bezapool/projects'` is about 43G.
- **No secrets came over.** This prints nothing but `.env.example` files:

  ```bash
  ssh root@10.10.10.10 "find /bezapool/projects \( -name '.env*' -o -name '*.tfstate*' -o -name '*.tfvars' -o -name '*.pem' -o -name '*.key' -o -name 'settings.local.json' -o -name .terraform -o -name .git \) -print"
  ```

- **It is read-only in File Browser.** `pct exec 104 -- touch /srv/projects/x`
  fails with "Read-only file system", and both logins see the `projects`
  source.
- **Snapshots run.** The next day,
  `ssh root@10.10.10.10 'zfs list -t snapshot bezapool/projects'` lists one.

---

## Changing what is left out

Edit `syncthing_projects_ignore_patterns`, deploy step 2, then rewrite the
laptop's `.stignore` with the command in step 4. A pattern added later does
not remove files already on the server: delete those by hand, and destroy
any snapshot that holds one if it was a secret.

## Getting a file back

Browse the `projects` source in File Browser and download it, or for an
earlier day, take it from a snapshot:
`ssh root@10.10.10.10 'ls /bezapool/projects/.zfs/snapshot/'`.
