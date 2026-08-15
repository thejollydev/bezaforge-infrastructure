#!/usr/bin/env bash
#
# grafana-export-dashboards.sh — capture every live Grafana dashboard into
# the repo, so a rebuild can restore them (#659).
#
# WHY THIS IS A SCRIPT AND NOT A SNIPPET IN THE RUNBOOK
# -----------------------------------------------------
# It used to be a snippet in docs/runbooks/grafana-dashboards-export.md, and
# that snippet carried the bug that made the whole provisioning pipeline
# inert for three months:
#
#     folder=$(... '.folderTitle // "General"' ...)
#
# A dashboard sitting in Grafana's default folder has no folderTitle, so the
# fallback wrote it to a directory called `General`. The provider runs with
# `foldersFromFilesStructure: true`, which creates one Grafana folder per
# directory — and **General is Grafana's built-in default folder. It already
# exists and cannot be created.** The provisioner errored, aborted the whole
# tree walk, and imported NOTHING. Every 30 seconds, from 2026-05-20 until
# 2026-08-15: roughly a quarter of a million failures, while the dashboards
# in VCS were never once provisioned.
#
# Fixing the directory alone would have left the instruction that recreates
# it. So the export lives here, once, with the reserved name handled.
#
# RESERVED FOLDER NAMES
# ---------------------
# `General` is the only reserved name today. It is remapped to the provider
# root rather than skipped, because a dashboard in the default folder is a
# real dashboard that must still be captured — silently dropping it would
# trade a loud failure for a quiet one.
#
# USAGE
#   GRAFANA_TOKEN=<service-account-token> scripts/grafana-export-dashboards.sh
#   GRAFANA_USER=admin GRAFANA_PASS=<pw> scripts/grafana-export-dashboards.sh
#   ... --dry-run     list what would be written, touch nothing
#
# Credentials are never read from the repo. Use a service-account token
# (Grafana -> Administration -> Service accounts) or the admin password
# from Bitwarden.

set -uo pipefail

GRAFANA_URL="${GRAFANA_URL:-https://grafana.bezaforge.dev}"
OUT_DIR="${OUT_DIR:-ansible/roles/monitoring/files/grafana/dashboards}"
ROOT_FOLDER="${ROOT_FOLDER:-BezaForge}"   # where default-folder dashboards land
DRY_RUN=0
[ "${1:-}" = "--dry-run" ] && DRY_RUN=1

for bin in curl jq; do
    command -v "$bin" >/dev/null || { echo "FAIL: $bin is required"; exit 2; }
done

# Auth: token preferred, basic auth as the fallback.
if [ -n "${GRAFANA_TOKEN:-}" ]; then
    AUTH=(-H "Authorization: Bearer ${GRAFANA_TOKEN}")
elif [ -n "${GRAFANA_USER:-}" ] && [ -n "${GRAFANA_PASS:-}" ]; then
    AUTH=(-u "${GRAFANA_USER}:${GRAFANA_PASS}")
else
    echo "FAIL: set GRAFANA_TOKEN, or GRAFANA_USER + GRAFANA_PASS."
    echo "  A token comes from Grafana -> Administration -> Service accounts."
    exit 2
fi

# Fail loudly on bad credentials rather than writing an empty export over a
# good one — an export that silently captures nothing is worse than none.
code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 \
       "${AUTH[@]}" "${GRAFANA_URL}/api/search?type=dash-db")
if [ "$code" != "200" ]; then
    echo "FAIL: ${GRAFANA_URL}/api/search returned HTTP ${code} (expected 200)."
    [ "$code" = "401" ] && echo "  401 = credentials rejected."
    exit 2
fi

list=$(curl -s --max-time 30 "${AUTH[@]}" "${GRAFANA_URL}/api/search?type=dash-db")
count=$(printf '%s' "$list" | jq 'length')
if [ "${count:-0}" -eq 0 ]; then
    echo "FAIL: Grafana reports zero dashboards. Refusing to write an empty export."
    exit 2
fi
echo "Found ${count} dashboards at ${GRAFANA_URL}"
echo

written=0
for uid in $(printf '%s' "$list" | jq -r '.[].uid'); do
    meta=$(printf '%s' "$list" | jq -r --arg u "$uid" '.[] | select(.uid==$u)')
    title=$(printf '%s' "$meta" | jq -r '.title' | tr ' /' '__' | tr -cd '[:alnum:]_-')
    folder=$(printf '%s' "$meta" | jq -r '.folderTitle // ""' | tr ' /' '__' | tr -cd '[:alnum:]_-')

    # ⚠️ THE BUG THIS SCRIPT EXISTS TO KILL. An empty or "General" folder is
    # the Grafana default folder; a directory of that name makes the
    # provisioner try to create a folder that already exists, which aborts
    # the entire walk and provisions nothing at all.
    if [ -z "$folder" ] || [ "$folder" = "General" ]; then
        folder="$ROOT_FOLDER"
    fi

    dest="${OUT_DIR}/${folder}/${title}.json"
    if [ "$DRY_RUN" -eq 1 ]; then
        echo "  would write ${dest}"
        continue
    fi

    mkdir -p "${OUT_DIR}/${folder}"
    body=$(curl -s --max-time 30 "${AUTH[@]}" "${GRAFANA_URL}/api/dashboards/uid/${uid}")
    # `del(.id)` so the JSON is portable between instances; the uid is kept
    # deliberately, so dashboard links and alert references survive re-import.
    if ! printf '%s' "$body" | jq -e '.dashboard' >/dev/null 2>&1; then
        echo "  SKIP ${title}: response carried no .dashboard object"
        continue
    fi
    printf '%s' "$body" | jq '.dashboard | del(.id)' > "$dest"
    echo "  wrote ${dest}"
    written=$((written + 1))
done

echo
if [ "$DRY_RUN" -eq 1 ]; then
    echo "dry run — nothing written."
    exit 0
fi
echo "exported=${written} of ${count}"
[ "$written" -eq "$count" ] || { echo "WARN: not every dashboard exported."; exit 1; }
echo
echo "Next: git diff the export. Any change is a dashboard edited in the UI"
echo "since the last capture — review before committing, then deploy with:"
echo "  cd ansible && ansible-playbook site.yml --tags monitoring \\"
echo "    --ask-become-pass --ask-vault-pass"
