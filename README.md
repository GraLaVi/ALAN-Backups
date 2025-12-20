# Alan Backend - Centralized Backup Service

Automated backup solution for Docker volumes in the Alan Backend infrastructure.

## Overview

This backup service provides:
- Automated daily backups (3:00 AM UTC by default)
- Weekly backup retention (Sundays)
- Backup rotation with configurable retention policies
- JSON status files for FastAPI/NextJS dashboard integration
- Email notifications (configurable)
- Easy restore functionality

## Backed Up Services

- **RabbitMQ**: Message broker data and definitions
- **Loki**: Log aggregation data
- **Grafana**: Dashboards and configurations
- **PostgreSQL**: Managed separately (see [postgres_sql/docker-compose.yml](../postgres_sql/docker-compose.yml))

## Directory Structure

```
alan-backups/
├── docker-compose.yml          # Backup service definition
├── scripts/
│   ├── backup.sh               # Main backup script
│   ├── restore.sh              # Restore utility
│   └── notify.sh               # Notification handler
├── config/
│   ├── backup.conf             # Configuration file
│   └── api-integration-example.md  # API integration examples
└── README.md                   # This file

Backup storage (on host):
/mnt/shared/alan/backups/
├── rabbitmq/
│   ├── daily/                  # Last 7 days
│   └── weekly/                 # Last 4 weeks
├── loki/
│   ├── daily/
│   └── weekly/
├── grafana/
│   ├── daily/
│   └── weekly/
└── status/                     # JSON status files for API
    ├── backup_summary.json
    ├── rabbitmq_last_backup.json
    ├── loki_last_backup.json
    ├── grafana_last_backup.json
    └── webhook_payload.json
```

## Quick Start

### 1. Prerequisites

Ensure the backup directory exists:
```bash
sudo mkdir -p /mnt/shared/alan/backups/{rabbitmq,loki,grafana}/{daily,weekly}
sudo mkdir -p /mnt/shared/alan/backups/status
sudo chown -R $(id -u):$(id -g) /mnt/shared/alan/backups
```

### 2. Configure RabbitMQ Credentials

Edit [config/backup.conf](config/backup.conf) if your RabbitMQ uses non-default credentials:
```bash
RABBITMQ_USER=your_username
RABBITMQ_PASS=your_password
```

Or set them in your environment/secrets.

### 3. Start the Backup Service

```bash
cd alan-backups
docker compose up -d
```

### 4. Verify It's Running

```bash
# Check container status
docker ps | grep alan_backup_service

# View logs
docker logs -f alan_backup_service

# Check if initial backup ran
ls -lh /mnt/shared/alan/backups/rabbitmq/daily/
```

### 5. Test Manual Backup

```bash
docker exec alan_backup_service /usr/local/bin/backup.sh
```

## Configuration

### Backup Schedule

Edit [docker-compose.yml](docker-compose.yml) environment variables:
```yaml
- BACKUP_SCHEDULE=0 3 * * *  # Cron format (default: 3 AM daily)
```

### Retention Policy

Edit [config/backup.conf](config/backup.conf):
```bash
RETENTION_DAILY=7    # Keep daily backups for 7 days
RETENTION_WEEKLY=4   # Keep 4 most recent weekly backups
```

### Email Notifications

When ready to enable email notifications, edit [config/backup.conf](config/backup.conf):
```bash
SMTP_ENABLED=true
SMTP_HOST=smtp.gmail.com
SMTP_PORT=587
SMTP_USER=your-email@gmail.com
SMTP_PASSWORD=your-app-password
SMTP_FROM=backups@yourdomain.com
SMTP_TO=admin@yourdomain.com
```

Then restart the service:
```bash
docker compose restart
```

## Restore Operations

The restore script provides an interactive way to restore from backups.

### List Available Backups
```bash
docker exec -it alan_backup_service /usr/local/bin/restore.sh rabbitmq list
docker exec -it alan_backup_service /usr/local/bin/restore.sh loki list
docker exec -it alan_backup_service /usr/local/bin/restore.sh grafana list
```

### Restore from Latest Backup
```bash
docker exec -it alan_backup_service /usr/local/bin/restore.sh rabbitmq latest
```

### Restore from Specific Backup
```bash
docker exec -it alan_backup_service /usr/local/bin/restore.sh rabbitmq \
  /backups/rabbitmq/daily/backup-2024-01-15T03-00-00.tar.gz
```

**Note**: The restore script will:
1. Ask for confirmation
2. Stop the service container
3. Clear existing data
4. Extract the backup
5. Restart the service

## Dashboard Integration

The backup service creates JSON status files that your FastAPI/NextJS dashboard can consume.

### Status File Locations

All status files are in `/mnt/shared/alan/backups/status/`:
- `backup_summary.json` - Overall status
- `{service}_last_backup.json` - Per-service details
- `webhook_payload.json` - Event payload for webhooks

### Quick FastAPI Example

```python
from fastapi import APIRouter
from pathlib import Path
import json

router = APIRouter()

@router.get("/api/backups/status")
async def get_backup_status():
    status_file = Path("/mnt/shared/alan/backups/status/backup_summary.json")
    if status_file.exists():
        return json.loads(status_file.read_text())
    return {"status": "no_data"}
```

See [config/api-integration-example.md](config/api-integration-example.md) for complete integration examples.

## Monitoring

### Check Backup Status
```bash
# View summary
cat /mnt/shared/alan/backups/status/backup_summary.json | jq

# View service-specific status
cat /mnt/shared/alan/backups/status/rabbitmq_last_backup.json | jq
```

### View Logs
```bash
docker logs alan_backup_service
docker logs -f alan_backup_service --tail 100
```

### Check Disk Usage
```bash
du -sh /mnt/shared/alan/backups/*
```

## Troubleshooting

### Backup Service Won't Start

Check if the external volumes exist:
```bash
docker volume ls | grep -E '(rabbitmq|loki|grafana)'
```

If volumes are named differently, update [docker-compose.yml](docker-compose.yml) volume section.

### Permission Issues

Ensure the backup directory is writable:
```bash
sudo chown -R $(id -u):$(id -g) /mnt/shared/alan/backups
```

### RabbitMQ Definitions Backup Fails

Verify RabbitMQ management API is accessible:
```bash
curl -u guest:guest http://localhost:15672/api/definitions
```

Update credentials in [config/backup.conf](config/backup.conf) if needed.

### Email Notifications Not Working

Check msmtp logs inside the container:
```bash
docker exec alan_backup_service cat /tmp/msmtp.log
```

For Gmail, you may need an [App Password](https://support.google.com/accounts/answer/185833).

## Backup Strategy

### Daily Backups
- Run at 3:00 AM UTC (configurable)
- Kept for 7 days (configurable)
- Stored in `{service}/daily/` directories

### Weekly Backups
- Taken every Sunday at 3:00 AM UTC
- Keep 4 most recent (configurable)
- Stored in `{service}/weekly/` directories

### What Gets Backed Up

| Service | What's Backed Up | Method |
|---------|------------------|--------|
| RabbitMQ | Data volume + Definitions (queues, exchanges) | tar.gz + JSON API export |
| Loki | Time-series log data | tar.gz |
| Grafana | Dashboards, data sources, config | tar.gz |
| PostgreSQL | Database dumps | Managed separately via [postgres_sql](../postgres_sql/) |

## Security Considerations

- Backup files are stored unencrypted on `/mnt/shared/alan/backups`
- Consider encrypting backups for production environments
- Restrict access to backup directory
- Use secure credentials for SMTP
- Status files contain metadata but not sensitive data

## Performance Impact

- Backups run during off-peak hours (3 AM)
- Volumes are mounted read-only
- Compression reduces storage requirements
- Backup duration: typically 1-5 minutes depending on data size

## Maintenance

### Update Backup Service
```bash
cd alan-backups
docker compose pull
docker compose up -d
```

### Change Backup Schedule
1. Edit `BACKUP_SCHEDULE` in [docker-compose.yml](docker-compose.yml)
2. Restart: `docker compose restart`

### Add More Services

To backup additional services:
1. Add volume to [docker-compose.yml](docker-compose.yml)
2. Add backup function to [scripts/backup.sh](scripts/backup.sh)
3. Add restore function to [scripts/restore.sh](scripts/restore.sh)
4. Restart the service

## Support

For issues or questions:
1. Check logs: `docker logs alan_backup_service`
2. Verify configuration in [config/backup.conf](config/backup.conf)
3. Test manual backup: `docker exec alan_backup_service /usr/local/bin/backup.sh`

## License

Part of the Alan Backend infrastructure.
