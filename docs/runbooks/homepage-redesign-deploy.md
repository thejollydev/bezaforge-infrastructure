# Deploy the redesigned bezaforge homepage

The homepage at https://home.bezaforge.dev is the gethomepage/homepage
container on forge-ops. Its compose file + env template live in
`ansible/roles/services/`; its YAML config + brand images live in
`docker/homepage/{config,images}/` and are deployed by the same role.

## What gets shipped

| Source (repo)                        | Destination (forge-ops)                  |
|--------------------------------------|------------------------------------------|
| `docker/homepage/config/*.yaml`      | `/opt/bezaforge/homepage/config/*.yaml`  |
| `docker/homepage/config/custom.css`  | `/opt/bezaforge/homepage/config/custom.css` |
| `docker/homepage/images/*`           | `/opt/bezaforge/homepage/images/`        |
| `ansible/.../homepage-compose.yml`   | `/opt/bezaforge/homepage/docker-compose.yml` |
| `ansible/.../homepage-env.j2`        | `/opt/bezaforge/homepage/.env`           |

## Prerequisites

- Ansible vault unlocks (`--ask-vault-pass`) — the `homepage-env.j2` template
  reads `homepage_jellyfin_api_key`, `homepage_kavita_password`, and
  `homepage_qbittorrent_password` from the encrypted host_vars.
- These services should be reachable from the homepage container on
  `bezaforge-net`: `jellyfin:8096`, `kavita:5000`, `gluetun:8080`.

## Deploy

From the repo root on your workstation:

```bash
cd ~/Projects/bezaforge-infrastructure/ansible
ansible-playbook -i inventory/hosts.yml site.yml \
  --limit forge-ops \
  --tags services \
  --ask-become-pass --ask-vault-pass
```

If `services` isn't a tag on the role, drop `--tags services` and run the
full play. The "Deploy homepage YAML config" and "Deploy homepage brand
images" tasks will sync the new files; gethomepage hot-reloads its YAML on
disk change automatically.

The "Restart homepage when brand images change" task only fires when the
contents of `/opt/bezaforge/homepage/images/` actually differ — first run
will restart once and pick up the new logo + favicon.

## Verify

```bash
# from forge-ops
docker ps --filter name=homepage
docker logs --tail 50 homepage    # look for "Loaded services.yaml"
ls /opt/bezaforge/homepage/config/
ls /opt/bezaforge/homepage/images/
```

In a browser, hard-reload `https://home.bezaforge.dev` (Cmd/Ctrl+Shift+R)
to bypass the cached `custom.css`. Verify both **Dashboard** and **Hosts**
tabs render, the logo appears top-left, and the cobalt focus ring shows on
the search field.

## Roll back

The previous (messy) config is still on forge-ops in the homepage volume.
Ansible's copy task overwrites in place, so the old files are gone after
deploy. If the new homepage breaks:

```bash
# on forge-ops — fastest rollback: stop the container and serve a 503 via Traefik
cd /opt/bezaforge/homepage
docker compose down

# OR — revert just the YAML to a known-bad-but-working state
git -C ~/Projects/bezaforge-infrastructure log --oneline docker/homepage/
git -C ~/Projects/bezaforge-infrastructure checkout <prev-sha> -- docker/homepage/
# then re-run the ansible play
```

If `custom.css` is the problem but YAML is fine, just rename it on the host:

```bash
mv /opt/bezaforge/homepage/config/custom.css{,.disabled}
docker restart homepage
```

## Edit the design

- **Add/remove a service:** edit `docker/homepage/config/services.yaml`,
  commit, re-run the play.
- **Tweak the visual:** edit `docker/homepage/config/custom.css`, commit,
  re-run. CSS is hot-loaded.
- **Add a widget that needs secrets:** add a new `HOMEPAGE_VAR_*` entry to
  both `ansible/roles/services/templates/homepage-env.j2` and to the
  `environment:` block in `ansible/roles/services/files/homepage-compose.yml`,
  then add the corresponding `vault_*` value to the encrypted
  `inventory/host_vars/forge-ops/vault.yml`.

## Brand assets

The PNGs in `docker/homepage/images/` were copied from
`~/Projects/bezacore-labs/brand-assets/bezaforge/exports/` (transparent +
favicon + apple + pwa exports, locked 2026-05-09). To refresh them after a
brand re-export, re-copy the same five files:

```bash
cd ~/Projects/bezaforge-infrastructure
cp ~/Projects/bezacore-labs/brand-assets/bezaforge/exports/transparent/bezaforge-256.png  docker/homepage/images/bezaforge-mark.png
cp ~/Projects/bezacore-labs/brand-assets/bezaforge/exports/transparent/bezaforge-512.png  docker/homepage/images/bezaforge-mark-512.png
cp ~/Projects/bezacore-labs/brand-assets/bezaforge/exports/favicon/bezaforge.ico          docker/homepage/images/favicon.ico
cp ~/Projects/bezacore-labs/brand-assets/bezaforge/exports/apple/bezaforge-apple-touch-icon.png  docker/homepage/images/apple-touch-icon.png
cp ~/Projects/bezacore-labs/brand-assets/bezaforge/exports/pwa/bezaforge-maskable-512.png docker/homepage/images/bezaforge-pwa-512.png
```

Brand palette + voice rules are documented in the vault at
`05_Projects/intelligrace/strategy/brand.md` (Ember & Cobalt, locked
2026-05-09). The `custom.css` token block at the top of the file mirrors
those values — update both if the palette ever changes.
