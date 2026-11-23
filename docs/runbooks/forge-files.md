# Runbook — forge-files (File Browser over the file share)

forge-files is CTID 104, an unprivileged Debian 13 container on the
hypervisor, running File Browser Quantum at `https://files.bezaforge.dev`.
It is the web view of the file share: browse, preview and download from
any browser, including a phone over WireGuard.

Three layers build it, and they run in this order:

| Layer | Where | What it does |
|---|---|---|
| `terraform/containers.tf` | Proxmox API | Creates the container, stopped, with its network and root disk |
| `roles/forge-files-host` | hypervisor | Adds the share's bind mount and the ID mapping, then starts the container |
| `roles/filebrowser` | forge-files | Installs File Browser, its config, the logins and the firewall rule |

Terraform cannot do the second layer: Proxmox lets only `root@pam` set
bind mounts and raw `lxc.*` keys, and an API token never counts as
`root@pam`.

---

## First deployment

1. **Vault the two passwords.** Both are chosen, not generated, because
   both are typed into a browser. The command is in the docstring of
   `scripts/filebrowser-vault-setup.py`; the first run uses
   `ansible-vault create`.
2. **Create the container.** In `terraform/`, run `terraform init -upgrade`
   if the lock file predates the provider constraint, then
   `terraform plan` and `terraform apply`. Expect two additions: the
   Debian 13 template download and the container. It is created stopped.
3. **Mount the share and start the container.** Against the hypervisor:
   `ansible-playbook site.yml --limit forge-hypervisor --tags forge-files-host`.
4. **Install File Browser.** `ansible-playbook site.yml --limit forge-files`.
5. **Route it.** `ansible-playbook site.yml --limit forge-ops --tags traefik`
   for the route, and `--tags adguard` there plus `--tags dnsmasq` on the
   hypervisor for the `forge-files.bezaforge.dev` host record.
6. **Give the owner's login write access, once.** New logins take the
   share's default permissions, view and download only. Sign in as the
   owner, open Settings → User management, and allow modify, create and
   delete on the `files` source for that login. Leave the phone's login as
   it is.
7. **Run steps 3 to 5 again.** Each should report no changes apart from
   the deploy stamp.

---

## Checks before it counts as done

- **Ownership.** Create a file through File Browser as the owner, then on
  the hypervisor: `stat -c '%U:%G' /sharepool/files/<file>` shows
  `bezashare:bezashare`.
- **The phone's login is read-only.** Signed in as `phone`, files open and
  download, and upload, rename and delete are refused.
- **Google Drive survives an rclone restart.** On the hypervisor,
  `systemctl restart rclone-gdrive-mount`, wait for it to come
  back, then list `/srv/files/GoogleDrive` inside the container
  (`pct exec 104 -- ls /srv/files/GoogleDrive`). If it shows nothing until
  the container restarts, the bind mount did not follow the new FUSE
  mount: note it on the issue, because the fix is a hook that restarts
  the container when the mount unit restarts.
- **Only Traefik reaches the port.** From the workstation,
  `curl -m 5 http://10.10.20.60:8080` times out; `https://files.bezaforge.dev`
  answers.
- **Indexing leaves Google Drive alone.** For the first hour after start,
  `journalctl -u filebrowser` should not show it walking `/GoogleDrive`.

---

## Changing things

- **A password.** Set only that variable and run the vault script with
  `ansible-vault edit`, then step 4. The owner's password is reapplied on
  every start. The phone's is reapplied when its hash in
  `/var/lib/filebrowser/data/.phone-password.sha256` no longer matches,
  which means a short File Browser restart.
- **The version.** Change `filebrowser_version` and `filebrowser_sha256`
  together. The digest is GitHub's own, shown with each release asset.
- **Another folder.** Add a bind mount in `roles/forge-files-host` and a
  source in `roles/filebrowser/templates/config.yaml.j2`. A new mount
  restarts the container.

## Recovery

- **The admin login is locked out.** Its password is reapplied from the
  vault on every start: `systemctl restart filebrowser` inside the
  container.
- **The container will not start after a mapping change.** On the
  hypervisor, `pct start 104 --debug` shows the LXC error. The mapping
  lines and `root:1500:1` in `/etc/subuid` and `/etc/subgid` must agree.
- **Rebuild from scratch.** `terraform destroy -target` the container,
  then the first deployment again. The share lives on the hypervisor and
  is untouched; only File Browser's own logins and settings are lost, and
  the nightly Proxmox backup of CT 104 holds those.
