# Runbook — Export Grafana dashboards into version control

**Why:** Grafana dashboards live in a SQLite DB inside the container. If the volume is lost (or Grafana is re-deployed clean) they must be re-created by hand. This runbook captures them into `ansible/roles/monitoring/files/grafana/dashboards/` so they ship with the repo and are re-provisioned on the next playbook run.

---

## ⛔ Read this first — the failure this runbook caused (#659)

**From 2026-05-20 to 2026-08-15, no dashboard in this repo was ever provisioned into Grafana.** Not a degraded import — zero, every 30 seconds, roughly a quarter of a million consecutive failures.

The cause was one directory name. The old export snippet in this runbook fell back to `.folderTitle // "General"` for any dashboard sitting in Grafana's default folder, which created a directory called `General`. The provider runs with `foldersFromFilesStructure: true`, so Grafana tried to create a folder named `General` — **its own built-in default folder, which already exists and cannot be created.** That error aborts the *entire tree walk*, so nothing at all is imported.

Two lessons are baked into the procedure below:

1. **Never name a dashboard subdirectory `General`.** `scripts/grafana-export-dashboards.sh` remaps it, so the export can no longer recreate the condition.
2. **Verification must be able to fail.** The old "verify" step in this runbook checked that the JSON files existed on disk. They always did — the files were mounted correctly the whole time; it was the *import* that never happened. A check that stays green through total failure is not a check. The procedure below reads Grafana's own provisioning log instead.

---

## Provisioning model

Anything in `ansible/roles/monitoring/files/grafana/dashboards/<folder>/<name>.json` is bind-mounted into the container and imported within 30 seconds — **provided the folder name is importable.** One subdirectory becomes one Grafana folder.

```
ansible/roles/monitoring/files/grafana/dashboards/
├── BezaForge/          ← default landing folder (NEVER call this General)
│   ├── Node_Exporter_Full.json
│   └── Traefik.json
├── Infrastructure/     ← optional, add as the set grows
└── Services/
```

`folder:` in the provider config is kept equal to the primary directory name on purpose — Grafana's precedence between `folder` and `foldersFromFilesStructure` is version-dependent, and keeping them equal makes the outcome the same under either reading. If you rename one, rename the other.

---

## Export procedure

### Option A — script (all dashboards, preferred)

```bash
cd ~/Projects/bezaforge-infrastructure

# Token: Grafana → Administration → Service accounts → New token (Viewer is enough).
# Store it in Bitwarden. Admin basic auth also works.
GRAFANA_TOKEN='<paste>' scripts/grafana-export-dashboards.sh --dry-run   # look first
GRAFANA_TOKEN='<paste>' scripts/grafana-export-dashboards.sh
```

The script refuses to write on a non-200 response or a zero-dashboard result, so bad credentials can never silently overwrite a good export with an empty one.

Then review before committing — **this diff is the important part**:

```bash
git diff --stat ansible/roles/monitoring/files/grafana/dashboards/
```

Any change is a dashboard someone edited in the UI since the last capture. An empty diff means live and VCS already agree.

> ⚠️ **Do not `rsync --delete` an export over the dashboards directory.** The previous version of this runbook did, which silently deletes any dashboard the export did not return — including everything, if the API call failed. The script writes in place and touches nothing it did not fetch.

### Option B — UI export (one dashboard)

1. Open the dashboard → **Share** (or `Ctrl+S`) → **Export** tab.
2. Toggle **Export for sharing externally** OFF — internal UIDs must be preserved so dashboard links and alert references survive re-import.
3. **Save to file**, drop it into the right subfolder, `git add` + commit.

---

## Deploy

```bash
cd ansible && ansible-playbook site.yml --tags monitoring \
  --ask-become-pass --ask-vault-pass
```

---

## Verifying provisioning is actually live

⚠️ **Checking the files on disk proves nothing** — that is precisely what hid #659 for three months. Ask Grafana whether it imported them.

```bash
# 1. No provisioning errors. Expect NOTHING from this.
ssh joseph@10.10.20.20 \
  'docker logs grafana --since 10m 2>&1 | grep -iE "failed to (walk|create folder)"'

# 2. Positive confirmation the walk completed.
ssh joseph@10.10.20.20 \
  'docker logs grafana --since 10m 2>&1 | grep -iE "finished to provision dashboards"'
```

Check 1 empty **and** check 2 present is the pass condition. Check 1 alone is not: a provisioner that never starts also logs no failures.

3. In the Grafana UI the **BezaForge** folder should hold the dashboards, each showing the *"Provisioned dashboard"* banner. **No banner means it came from the DB, not from this repo** — the single clearest signal that provisioning is not doing what you think.

---

## Notes & gotchas

- **`del(.id)`** — Grafana's numeric `id` is per-instance; stripping it lets a dashboard re-import into a fresh DB without collisions. The `uid` is kept deliberately so links and alert references survive.
- **Service account tokens** — Grafana → Administration → Service accounts. Viewer scope is enough. Store in Bitwarden.
- **UI edits are not durable.** `allowUiUpdates: true` lets you tweak live, but disk wins on container restart. Re-export and commit anything worth keeping.
- **Don't commit secrets** — some panels inline data source UIDs or tokens. Sanitize before commit.
- **Datasources ARE provisioned** (`files/grafana/provisioning/datasources/datasources.yaml`) — live on forge-ops, not "wired up but unused" as this runbook claimed until 2026-08-15. Pin datasource UIDs; alert rules reference them.
- **Alert rules ARE provisioned** (`files/grafana/provisioning/alerting/alert-rules.yaml`, contact points templated from ansible-vault). The rules file is deliberately **static, never templated** — its annotations contain Go-template `{{ $labels.* }}` expressions Jinja would mangle — and is excluded from both linters, so `scripts/check-alert-rules.py` (run in CI) is its only validation.
