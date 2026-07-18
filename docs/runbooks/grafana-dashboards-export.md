# Runbook — Export Grafana dashboards into version control

**Why:** Grafana dashboards live in a SQLite DB inside the container. If the volume is lost (or Grafana is re-deployed clean) the dashboards must be re-created by hand. This runbook captures them into `ansible/roles/monitoring/files/grafana/dashboards/` so they ship with the repo and are re-provisioned automatically on the next playbook run.

**Provisioning is already wired up.** Anything dropped in `ansible/roles/monitoring/files/grafana/dashboards/<folder>/<name>.json` gets bind-mounted into the Grafana container and auto-imported within 30 seconds. The folder name becomes the Grafana folder (because `foldersFromFilesStructure: true` in the provider config).

**Subfolders → Grafana folders.** Recommended layout:

```
ansible/roles/monitoring/files/grafana/dashboards/
├── Infrastructure/
│   ├── host-overview.json
│   ├── docker-host.json
│   └── network.json
├── Services/
│   ├── traefik.json
│   └── gitea.json
└── Logs/
    └── loki-explore.json
```

---

## Export procedure (per dashboard)

### Option A — UI export (one dashboard at a time)

1. Open the dashboard in Grafana.
2. Click the **Share** icon (or `Ctrl+S`).
3. **Export** tab → toggle **Export for sharing externally** OFF (we want internal UIDs preserved so dashboard links and alert references survive re-import).
4. Click **Save to file** — Grafana downloads `<dashboard-name>-<timestamp>.json`.
5. Rename the file to `<kebab-case-name>.json` (drop the timestamp) and drop it into the right subfolder under `ansible/roles/monitoring/files/grafana/dashboards/`.
6. `git add` + commit.

### Option B — API export (all dashboards at once)

Run from any host with `curl` + `jq` that can reach `https://grafana.bezaforge.dev`:

```bash
# Bitwarden (or wherever) — Grafana service account token with Viewer role
GRAFANA_TOKEN="<paste>"

OUT_DIR="$HOME/grafana-export-$(date +%Y-%m-%d)"
mkdir -p "$OUT_DIR"

# List all dashboards (paginated, but the homelab is well under 5000)
curl -fsSL -H "Authorization: Bearer $GRAFANA_TOKEN" \
  "https://grafana.bezaforge.dev/api/search?type=dash-db&limit=5000" \
  | jq -c '.[]' \
  | while read -r dash; do
      uid=$(echo "$dash" | jq -r '.uid')
      title=$(echo "$dash" | jq -r '.title' | tr ' /' '__' | tr -cd '[:alnum:]_-')
      folder=$(echo "$dash" | jq -r '.folderTitle // "General"' | tr ' /' '__' | tr -cd '[:alnum:]_-')
      mkdir -p "$OUT_DIR/$folder"
      curl -fsSL -H "Authorization: Bearer $GRAFANA_TOKEN" \
        "https://grafana.bezaforge.dev/api/dashboards/uid/$uid" \
        | jq '.dashboard | del(.id)' \
        > "$OUT_DIR/$folder/$title.json"
      echo "exported $folder/$title.json"
  done
```

> **`del(.id)`** — Grafana's internal numeric `id` is per-instance. Stripping it lets the provisioned dashboard be re-imported into a fresh Grafana DB without ID collisions. The `uid` is preserved and stable.

Then move the captured tree into the repo:

```bash
# Mirror into the role files dir (overwrites stale files; new dashboards land too)
rsync -av --delete "$OUT_DIR/" \
  ~/Projects/bezaforge-infrastructure/ansible/roles/monitoring/files/grafana/dashboards/

cd ~/Projects/bezaforge-infrastructure
git status   # review what changed
git add ansible/roles/monitoring/files/grafana/dashboards/
git commit -m "ops(grafana): refresh dashboards from live export $(date +%Y-%m-%d)"
```

---

## Verifying provisioning is live

After the next `ansible-playbook site.yml --tags monitoring` run:

```bash
ssh joseph@10.10.20.20 'ls -la /opt/bezaforge/grafana/dashboards/ /opt/bezaforge/grafana/provisioning/dashboards/'
```

Expect: the exported folder structure mirrored on disk + `bezaforge.yaml` in provisioning/dashboards.

In the Grafana UI, the **BezaForge** folder should contain everything (with sub-folders if any). Edits in the UI persist for the running session (allowUiUpdates=true) but the file on disk wins on container restart — so production-worthy tweaks must be re-exported and committed.

---

## Notes & gotchas

- **Service account tokens** — Create in Grafana → Administration → Service accounts → New token. Viewer scope is enough for export. Save in Bitwarden.
- **Dashboard provider folder vs. JSON `folderTitle`** — The provider config sets `folder: BezaForge` as the root; subdirectories on disk create nested folders under it.
- **Don't commit dashboard tokens** — Some panels reference data source UIDs or service account tokens inline. Sanitize before commit if you see secrets.
- **Datasources are not exported here** — Provisioning datasources is wired up but unused (datasources still live in Grafana's SQLite). When you're ready to provision them, drop YAML in `ansible/roles/monitoring/files/grafana/provisioning/datasources/`. See the Grafana docs for the schema.
- **Alerting rules** — Same picture as datasources; provision separately when you want them in code.
