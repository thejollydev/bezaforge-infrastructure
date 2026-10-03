# Upgrading LangFuse

LangFuse runs on forge-ops as six containers from
`ansible/roles/services/files/langfuse-compose.yml`: web, worker, Postgres,
ClickHouse, Redis and MinIO. The web and worker images are one release and
move together. ClickHouse, Postgres and Redis have minimum versions that a
LangFuse release can raise, so read the release notes before bumping web and
worker.

## Before any upgrade

1. Read the release notes from the running version to the target, and the
   upgrade guide if the major version changes
   (<https://langfuse.com/self-hosting/upgrade>).
2. Check the infrastructure minimums the target names against the compose
   file. Upgrade ClickHouse first when it needs to move.
3. Bump `langfuse/langfuse` and `langfuse/langfuse-worker` to the same tag,
   each with its digest.

## Deploy

```bash
cd ansible
ansible-playbook site.yml --tags services --limit forge-ops --ask-become-pass --ask-vault-pass
```

Then run it again. The second run should report `changed=0`.

## Verify

Read-only, from the laptop:

```bash
ssh forge-ops 'docker ps --filter name=langfuse --format "{{.Names}}\t{{.Status}}\t{{.Image}}"'
ssh forge-ops 'docker logs langfuse-web --since 10m 2>&1 | tail -30'
ssh forge-ops 'docker logs langfuse-worker --since 10m 2>&1 | grep -i -E "error|migrat" | tail -20'
curl -sI https://langfuse.bezaforge.dev | head -1
```

All six containers should be `Up`, and the database containers `(healthy)`.
The web log should show the ClickHouse and Postgres migrations finishing.
Signing in at <https://langfuse.bezaforge.dev> should show the version
beside the logo.

## v3 to v4 (2026-10-03, #1334)

**What changed:**
- web and worker went from 3.187.0 to 4.50.0
- ClickHouse went from 25.8 to 26.8, its current long-term-support release.
  v4 needs at least 25.12.
- Postgres 17 and Redis 7 already met v4's minimums.

The write mode stays at v4's default, `events_only`. Nothing sends to the
legacy ingestion endpoints, and there was no v3 history worth backfilling: one
test trace.

**The same deploy turns off ClickHouse's system log tables.** Under v3 they had
grown to 13 GB with no traces stored (`langfuse-clickhouse-system-logs.xml`).
The setting stops them growing but does not delete the tables that already
exist. Once the deploy has verified, drop those tables and the 900 MB core dump
ClickHouse left on 2026-09-20. On forge-ops:

```bash
ssh forge-ops
```

```bash
docker exec langfuse-clickhouse clickhouse-client --multiquery -q "DROP TABLE IF EXISTS system.text_log SYNC; DROP TABLE IF EXISTS system.trace_log SYNC; DROP TABLE IF EXISTS system.metric_log SYNC; DROP TABLE IF EXISTS system.asynchronous_metric_log SYNC; DROP TABLE IF EXISTS system.opentelemetry_span_log SYNC; DROP TABLE IF EXISTS system.latency_log SYNC"
```

```bash
docker exec langfuse-clickhouse rm -f /var/lib/clickhouse/core.1
```

Then check what is left:

```bash
docker exec langfuse-clickhouse du -sh /var/lib/clickhouse
```
