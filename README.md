# ALAN Backups - Centralized Backup Service

Automated backup of RabbitMQ, Loki, Grafana, and PostgreSQL for the ALAN backend.

## What gets backed up

| Service    | Source                                      | Method                              |
|------------|---------------------------------------------|-------------------------------------|
| RabbitMQ   | `rabbitmq_data` volume + management API     | `tar.gz` + JSON definitions export  |
| Loki       | `loki-data` volume                          | `tar.gz`                            |
| Grafana    | `grafana-data` volume                       | `tar.gz`                            |
| PostgreSQL | Remote host (`POSTGRES_HOST`), 3 databases  | `pg_dump` → `.sql.gz` per database  |

PostgreSQL connects to an external host (`161.97.145.138` in dev, `10.108.0.7` in prod) — see `docker-compose.yml` / `docker-compose.prod.yml`.

## Project layout

```
ALAN-Backups/
├── Dockerfile
├── docker-compose.yml          # Base / dev config
├── docker-compose.prod.yml     # Prod overrides (APP_ENV, prod DB host)
├── start_app.sh                # Prod helper: uses both compose files
├── start_app_dev.sh            # Dev helper: base compose only
├── scripts/
│   ├── backup.sh               # Main backup script (runs via cron in container)
│   ├── notify.sh               # Sends email via ALAN API
│   └── restore.sh              # Interactive restore (rabbitmq/loki/grafana only)
└── README.md
```

Host paths:
- Backups (primary): `/mnt/shared/alan/backups/{rabbitmq,loki,grafana,postgresql}/{daily,weekly}/`
- Backups (cold-storage archive): `/mnt/shared/object_storage/backup_archives/{service}/{daily,weekly}/` — older backups are moved here automatically
- Status JSON: `/mnt/shared/alan/services/health_checks/status/`
- In-container log: `/home/david/logs/backup.log`

## Start / stop the service

Use the helper scripts — they wire up the right compose file(s).

```bash
# Dev (single host)
./start_app_dev.sh --build   # build image + start
./start_app_dev.sh --up      # start from existing image
./start_app_dev.sh --logs    # tail container logs
./start_app_dev.sh --stop    # stop container
./start_app_dev.sh --down    # stop + remove (including volumes)

# Prod (adds docker-compose.prod.yml)
./start_app.sh --build
./start_app.sh --up
./start_app.sh --logs
./start_app.sh --stop
./start_app.sh --down
```

Container name: `alan_backup_service`. Service name (for `docker compose`): `backup`.

## Schedule

- Default: `BACKUP_SCHEDULE="0 3 * * *"` — 3:00 AM **America/New_York** (`TZ` is set in compose).
- To change: edit `BACKUP_SCHEDULE` in `docker-compose.yml`, then `./start_app.sh --up` (recreates the container so cron picks up the new schedule).

## Retention & archival

After every run, old backups are **moved** (verified copy, then delete source)
to the cold-storage archive instead of being deleted:

- Primary (`/mnt/shared/alan/backups`) keeps the newest **`KEEP_DAILY=1`** file
  in each `daily/` and the newest **`KEEP_WEEKLY=1`** in each `weekly/`, per
  file prefix (per database for postgresql; `backup-*`/`definitions-*` for the
  volume backups). Everything older moves to the archive under
  `backup_archives/{service}/{daily,weekly}/`.
- Archive retention is **per tier**, aged by original backup mtime (which both
  transports preserve), so a file is judged on when the backup was taken, not
  when it was archived:
  - `*/daily/` — **`ARCHIVE_RETENTION_DAILY_DAYS=7`**
  - `*/weekly/` — **`ARCHIVE_RETENTION_WEEKLY_DAYS=30`**
  - anything else — **`ARCHIVE_RETENTION_DAYS=180`**, a catch-all so a file
    outside the `{service}/{daily,weekly}` layout cannot live forever.
- Steady state per database: 1 daily + 1 weekly in primary, ~7 dailies and 4
  weeklies in the archive — about five weeks of Sunday coverage.
- `postgresql/errors/` logs: still deleted after 30 days (not archived).
- A file is never removed from the primary unless its archive copy verified.
  If the archive target is missing/unwritable, archival is **skipped** (files
  stay put), the run still succeeds, and the notification email carries a
  warning.

### Dry-running the prune

`ARCHIVE_PRUNE_DRY_RUN=true` makes the prune report and delete nothing — the
log lists up to 20 paths per tier, `archive_last_run.json` carries
`prune_dry_run` / `prune_candidates`, and the notification email says
`Pruned: 0 (DRY RUN — N file(s) matched retention, none deleted)`. Archival
itself (moving files out of primary) still runs normally; only deletion is
suppressed, including the stale-`.partial` sweep.

Use it for the first run after tightening a retention window, since the prune
is otherwise silent about what it removed:

```bash
ARCHIVE_PRUNE_DRY_RUN=true ./start_app.sh --up   # one run, inspect the counts
./start_app.sh --up                              # then let it prune for real
```

To check the blast radius without touching the container at all:

```bash
rclone lsf archive:gph-shared-plus/backup_archives -R --files-only \
  --include "/*/daily/**"  --min-age 7d  | wc -l
rclone lsf archive:gph-shared-plus/backup_archives -R --files-only \
  --include "/*/weekly/**" --min-age 30d | wc -l
```

### Archive transports

- **Remote / rclone (prod)** — set `ARCHIVE_REMOTE=<bucket>/<prefix>`
  (prod: `gph-shared-plus/backup_archives`, see `docker-compose.prod.yml`).
  Files are uploaded straight to DO Spaces with `rclone copyto` using
  credentials parsed from the host's s3fs passwd file (mounted read-only at
  `/etc/passwd-s3fs`; since it is root:600, the entrypoint stages a
  david-readable copy at `/run/s3fs-creds` = `ARCHIVE_S3_CREDS_FILE`).
  Verification: rclone
  Content-MD5-checks every part in transit, and the script re-checks the
  remote object size before deleting the source. Prune runs via
  `rclone delete --min-age`.

  **Why not write through the s3fs mount?** DO Spaces does not implement
  `UploadPartCopy`. s3fs flushes mid-write once 5GB of dirty data accumulates
  (`max_dirty_data` default) and then needs that API to assemble the final
  object, so any file **>5GB written through s3fs fails with EIO** at close.
  This silently broke `alan_business` (~10.7GB) archival in Jul 2026; every
  smaller file worked, which made it look database-specific.
- **Filesystem (dev / no `ARCHIVE_REMOTE`)** — verified copy (size + md5,
  `gzip -t` for dumps) into the `ARCHIVE_ROOT` bind mount
  (`/mnt/shared/object_storage/backup_archives` on the host), then delete
  source. The bind mount uses `rslave` propagation so the container picks the
  mount up even if it appears after container start.

The host s3fs mount at `/mnt/shared/object_storage` is still handy for
*browsing/restoring* archived files in prod; it is just no longer in the
upload path.

## Manually running a backup

```bash
# Run a full backup synchronously (streams output)
docker exec alan_backup_service /usr/local/bin/backup.sh

# Same, but save output locally
docker exec alan_backup_service /usr/local/bin/backup.sh 2>&1 | tee /tmp/backup-test.log

# Run detached and tail the container's backup log
docker exec -d alan_backup_service /usr/local/bin/backup.sh
docker exec alan_backup_service tail -f /home/david/logs/backup.log
```

A manual run uses the same env the cron job has (same `NOTIFICATION_EMAIL`, `APP_ENV`, DB creds, etc.), so it's an end-to-end test of the backup + notification path.

## Manually testing notifications only

`notify.sh` reads whatever status files already exist on disk, so you can exercise the email path without a fresh backup:

```bash
# Args are: <failed_count> <duration_seconds> — both purely cosmetic
docker exec alan_backup_service /usr/local/bin/notify.sh 0 42   # success-style email
docker exec alan_backup_service /usr/local/bin/notify.sh 2 999  # partial-failure-style email
```

## Restoring

`restore.sh` is interactive and supports **rabbitmq, loki, grafana** (PostgreSQL restore is not scripted — use `psql` / `pg_restore` against the dump in `/mnt/shared/alan/backups/postgresql/`).

```bash
# List available backups for a service
docker exec -it alan_backup_service /usr/local/bin/restore.sh rabbitmq list
docker exec -it alan_backup_service /usr/local/bin/restore.sh loki list
docker exec -it alan_backup_service /usr/local/bin/restore.sh grafana list

# Restore from the latest backup
docker exec -it alan_backup_service /usr/local/bin/restore.sh rabbitmq latest

# Restore from a specific backup file (path is inside the container)
docker exec -it alan_backup_service /usr/local/bin/restore.sh rabbitmq \
  /backups/rabbitmq/daily/backup-2026-05-21T03-00-00.tar.gz
```

The restore flow:
1. Confirms with `yes/no`
2. Stops the target service container (`rabbitmq` / `loki` / `loki-grafana`)
3. Clears existing data in the mounted volume
4. Extracts the tarball
5. Restarts the target service container

**Restoring PostgreSQL manually** (host shell, not the backup container):

```bash
# Find the dump you want — recent ones in the primary, older ones in the archive
ls /mnt/shared/alan/backups/postgresql/{daily,weekly}/
ls /mnt/shared/object_storage/backup_archives/postgresql/{daily,weekly}/

# Restore (example for alandb — adjust user/host as needed)
gunzip -c /mnt/shared/alan/backups/postgresql/daily/alandb-2026-05-21T03-00-00.sql.gz \
  | psql -h <postgres_host> -U <user> -d alandb
```

**Restoring an archived (older) backup**: `restore.sh` only sees `/backups`
(the primary). For rabbitmq/loki/grafana, either pass the archived file by
copying it back into the primary tree first, or restore manually. For
PostgreSQL just point `gunzip -c` at the archive path directly (example above).

## Notification configuration

Notifications are sent by `notify.sh` via the ALAN API (`queue_notification_task` → SMTP). There is **one gate**: the `NOTIFICATION_EMAIL` env var. If empty, the script logs `"Notification email not configured ..., skipping notification"` and returns.

| Variable             | Purpose                                              | Set in                          |
|----------------------|------------------------------------------------------|---------------------------------|
| `NOTIFICATION_EMAIL` | Recipient address. Empty/unset = notifications off. | `docker-compose.yml:47`         |
| `APP_ENV`            | `production` → `https://api.gphusa.com/alan/process` <br> anything else → `http://75.119.134.30:8000/alan/process` and `(DEV)` subject tag | `docker-compose.yml:46` (default `development`) <br> overridden to `production` in `docker-compose.prod.yml:8` |

**To suppress notifications in dev**: change the default in `docker-compose.yml:47` from `${NOTIFICATION_EMAIL:-admin@gphusa.com}` to `${NOTIFICATION_EMAIL:-}`, then only set `NOTIFICATION_EMAIL` in the prod environment.

## What the notification email contains

The email body (rewritten in `notify.sh`) now includes:

1. **Header** — `Status`, `Timestamp`, `Duration`, `Failed Services: N/M` (computed from the actual status files, including each PostgreSQL DB).
2. **Failures** — only present when something failed. Lists every failed item with its `message` and (for PostgreSQL) `error_detail`. Each field is truncated to **700 chars** with a `…(truncated)` marker so a long `pg_dump` stderr doesn't blow up the email.
3. **Service Status** — per-service line for RabbitMQ / Loki / Grafana with size + duration, plus a **PostgreSQL** subsection with one row per database.
4. **Archive (cold storage)** — status, files/bytes moved, files pruned; a `WARNING:` line when archival was skipped or files failed to archive.
5. **Backup location, retention, next scheduled** — footer info.

Subject line:
- Success: `ALAN Systems Backup: Success`
- Partial failure: `ALAN Systems Backup: Warning - N service(s) failed`
- All backups fine but archival skipped/partial: ` (archive warning)` is appended.
- In dev, ` (DEV)` is appended.

## Status files (dashboard integration)

All written to `/mnt/shared/alan/services/health_checks/status/`:

- `backup_summary.json` — overall rollup (rabbitmq, loki, grafana, postgresql.overall_status, postgresql.databases map, retention policy, embedded `archive` block, next scheduled run).
- `rabbitmq_last_backup.json`, `loki_last_backup.json`, `grafana_last_backup.json` — per-service: `status`, `message`, `timestamp`, `backup_date`, `backup_file`, `size_bytes`, `duration_seconds`.
- `postgresql_<dbname>_last_backup.json` — one per DB. Same fields plus `database` and (on failure) `error_detail` containing the `pg_dump` stderr.
- `archive_last_run.json` — archival result: `status` (`success`/`skipped`/`partial_failure`), `message`, `archive_root`, `files_moved`, `bytes_moved`, `files_failed`, `files_pruned`.
- `webhook_payload.json` — last webhook payload for the dashboard.

Quick checks:
```bash
cat /mnt/shared/alan/services/health_checks/status/backup_summary.json | jq
cat /mnt/shared/alan/services/health_checks/status/postgresql_alandb_last_backup.json | jq
```

## Monitoring

```bash
# In-container backup log (where cron output goes — NOT docker stdout)
docker exec alan_backup_service tail -n 200 /home/david/logs/backup.log

# Container-level logs (entrypoint + cron daemon only)
docker logs -f alan_backup_service

# Disk usage of backup trees (primary + archive)
du -sh /mnt/shared/alan/backups/*
du -sh /mnt/shared/object_storage/backup_archives/*

# Last archival result
cat /mnt/shared/alan/services/health_checks/status/archive_last_run.json | jq
```

## Troubleshooting

### Email says "archive warning" / archival skipped

The archive dir was missing or not writable at run time — files simply stayed
in the primary (nothing is lost). Check:

```bash
ls -ld /mnt/shared/object_storage/backup_archives   # must exist, owned 1000:1000
sudo chown 1000:1000 /mnt/shared/object_storage/backup_archives
```

After (re)mounting the cheap disk at `/mnt/shared/object_storage`, re-check
ownership — fresh mounts come up root-owned. The container's bind mount uses
`rslave` propagation, so a mount appearing later is picked up without a
container restart; the next 3 AM run archives the backlog automatically.

### `docker compose logs backup` shows nothing about backups

Expected — the cron job redirects its output to `/home/david/logs/backup.log` inside the container (`docker-compose.yml:79`). Use the in-container tail shown above.

### `WARNING: API request failed with HTTP 000` in `notify.sh`

`000` means curl never received a response — connection-level failure. The notify.sh request has no explicit timeout, so each attempt hangs ~2 minutes before failing. Diagnose from inside the container:

```bash
# Does DNS resolve the notification endpoint?
docker exec alan_backup_service nslookup api.gphusa.com

# Can the container reach it at all?
docker exec alan_backup_service curl -v --connect-timeout 10 https://api.gphusa.com/alan/process
```

If DNS fails on the prod host, uncomment the `dns:` block in `docker-compose.prod.yml` (the prod-internal DNS `10.108.0.6` is pre-filled but commented).

### Backup service won't start

Check the external volumes the compose file imports exist:
```bash
docker volume ls | grep -E '(rabbitmq|loki|grafana)'
```

Expected names (per `docker-compose.yml:86-99`):
`alan-broker_rabbitmq_data`, `alan-broker_rabbitmq_logs`, `alan-loki_loki-data`, `alan-loki_grafana-data`.

### Permission errors writing backups

The container runs as UID 1000. Make sure host paths are writable:
```bash
sudo chown -R 1000:1000 /mnt/shared/alan/backups /mnt/shared/alan/services
```

### RabbitMQ definitions backup fails

Verify the management API from inside the container:
```bash
docker exec alan_backup_service \
  curl -u "$RABBITMQ_USER:$RABBITMQ_PASS" http://rabbitmq:15672/api/definitions | head
```

Credentials come from `RABBITMQ_DEFAULT_USER` / `RABBITMQ_DEFAULT_PASS` in the host env (defaults to `guest`/`guest`).

### PostgreSQL backup fails for one DB

Check the per-DB status file — `error_detail` contains the `pg_dump` stderr that triggered the failure:
```bash
cat /mnt/shared/alan/services/health_checks/status/postgresql_<db>_last_backup.json | jq '.error_detail'
```

The same content is now also surfaced in the `Failures:` section of the email (truncated to 700 chars).

## Security notes

- Backups are stored unencrypted on `/mnt/shared/alan/backups`. Restrict filesystem access.
- PostgreSQL credentials are in `docker-compose.yml` and `docker-compose.prod.yml` as env defaults — override via host env (e.g. `POSTGRES_PASSWORD=...`) rather than committing real secrets.
- Status JSON files contain backup metadata only (sizes, statuses, error messages) — no row data.
