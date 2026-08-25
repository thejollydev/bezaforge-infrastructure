# OpenProject provisioning — the PM standard as code

Reproducible setup for the self-hosted OpenProject instance (`pm.bezaforge.dev`),
so every project gets the **same industry-standard PM layout** instead of a
hand-clicked snowflake. Philosophy: run PM the way real engineering/DevOps teams
do — standard taxonomies **by project class**, epics = real initiatives, Kanban +
categories + milestones.

## The standard

- **Categories = domain filters**, defined once per project *class* (not per project):
  - **DEV** (9): Frontend · Backend · Data & Storage · API & Integrations · Infrastructure & Deploy · Design & Content · Testing & QA · Security · Docs
  - **INFRA** (10): Compute & Provisioning · Networking & DNS · Storage & Files · Backups & DR · Monitoring & Observability · Config Management · Security & Secrets · Services & Applications · CI/CD & Automation · Documentation
  - **BUSINESS** (6): Legal & Compliance · Finance · Strategy · Brand & Marketing · Operations · Partnerships
  - **Personal/life** projects get bespoke taxonomies (genuinely different domains).
  - Unused categories in a given project are **normal** — that's how a standard works.
- **Types**: Task / Bug / Epic (epics = finite initiatives, not permanent buckets).
- **Milestones** = phases/releases → the Roadmap view.
- **Dashboard** (per project): Description · Status · "Open work — by category" table · status chart.
- **Board**: "Active Work" Kanban (New → In Progress).
- **Saved views**: Open by Category · Open by Status · Bugs · Epics.

## Files

| File | Runs where | Does |
|------|-----------|------|
| `op_provision_rails.rb` | forge-ops (Rails console) | categories + type-enablement — the only parts OpenProject's REST API can't do. One paste provisions every project in `CONFIG`, and realigns BezaForge. |
| `op_provision.py <id>` | workstation | everything REST-scriptable: project description/status, milestones, the 4 saved views, dashboard grid layout, Active Work board. Idempotent. |
| `op_build.py` | workstation | one-off used to categorize + retype BezaForge's 99 items (an item→category mapping). Template/reference for the per-project **content pass** (tagging existing items into categories). |

Auth: all three read the API token from `~/.op-token` (chmod 600). REST base
`https://pm.bezaforge.dev/api/v3`.

## Usage (new or re-provisioned project)

```bash
# 0) preview — writes nothing, prints what each project would gain:
docker exec -e DRY_RUN=1 openproject bundle exec rails runner /tmp/op_provision_rails.rb

# 1) categories + types (forge-ops) — add the project to CONFIG first:
docker cp op_provision_rails.rb openproject:/tmp/ && \
  docker exec openproject bundle exec rails runner /tmp/op_provision_rails.rb

# 2) layout (workstation):
./op_provision.py <identifier>

# 3) tag the project's existing items into categories (content pass) —
#    per-item judgment, à la op_build.py.
```

## Gotchas

- Categories + per-project **type enablement** are **UI/Rails-only** — the REST API
  returns 404/silently-ignores them. Everything else is REST. Confirmed against
  the vendor docs: `types` is a read-only linked property on the project
  resource, absent from both the create and update schemas, and the project's
  own `_links.types` declares `method=GET`. There is no API path; don't go
  looking for one.
- A **query's project link carries the numeric id** (`/api/v3/projects/32`),
  never the identifier. `ensure_queries` matched on the identifier until
  2026-08-25, so its delete-by-name never fired and **every re-run added four
  more saved views**. Fixed; `bezaforge-infrastructure` had accumulated eleven.
- **Archived projects 403** on queries, grids and work packages, so
  `op_provision.py` skips them with one message rather than failing six times.
  The Rails half still applies, so an archived project is fully provisioned the
  moment it is unarchived. Currently archived: `bezacore-ops`.
- **Retired projects** go in `RETIRED` in the Rails script, not merely left out
  of `CONFIG` — otherwise the "NOT IN CONFIG" report nags about them on every
  run, which is its own kind of resurfacing. `master-mind-cutover` is retired:
  archived, done, and never provisioned again. Its 14 work packages stay; the
  taxonomy and types a 2026-08-25 run briefly gave it were removed again.
- The three top-level containers (`infrastructure`, `personal-life`, `clients`)
  are **deliberately** outside the standard — see `CONTAINERS` in the Rails
  script. A run reports any project in neither list, so a new one announces
  itself instead of being silently missed.
- REST query **filters** use the `_links` operator form; resource-valued filters
  (e.g. `type`) put values in `_links.values` as hrefs, not a plain `values` array.
- The **overview grid** can't be deleted via REST (403); PATCH it.
- The Claude-in-Chrome automation tab can render the Description/Status widgets
  **blank** when they're fine in a real browser — verify data via the API, not that tab.

Background: OpenProject migration + rationale live in the vault
(`05_Projects/bezaforge-infrastructure/`) and the Outline runbooks.
