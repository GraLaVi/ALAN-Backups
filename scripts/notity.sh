#!/bin/bash
#
# Alan Backend - Notification Script
# Sends email notifications about backup status via ALAN API
#

# Configuration
STATUS_ROOT="/services/health_checks/status"

# Parameters
FAILED_COUNT=${1:-0}
DURATION=${2:-0}

# Log function
log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1"
}

# Send notification via API
send_api_notification() {
    local subject=$1
    local body=$2

    # Check if notification email is configured
    if [ -z "${NOTIFICATION_EMAIL}" ]; then
        log "Notification email not configured (NOTIFICATION_EMAIL not set), skipping notification"
        return 0
    fi

    # Determine API endpoint based on environment
    local api_url
    if [ "${APP_ENV}" = "production" ]; then
        api_url="https://api.gphusa.com/alan/process"
    else
        api_url="https://161.97.145.138:8000/alan/process"
    fi

    log "Sending notification via API (${APP_ENV} environment)..."

    # Escape JSON special characters in body
    local body_escaped=$(echo "$body" | jq -Rs .)

    # Build JSON payload
    local payload=$(cat <<EOF
{
  "task_name": "queue_notification_task",
  "handler_key": "alan_tasks",
  "payload": {
    "to": "${NOTIFICATION_EMAIL}",
    "subject": "${subject}",
    "body_text": ${body_escaped},
    "provider": "smtp"
  }
}
EOF
)

    # Retry logic: 3 attempts with 5-second delay
    local max_attempts=3
    local attempt=1
    local success=false

    while [ $attempt -le $max_attempts ]; do
        log "API notification attempt ${attempt}/${max_attempts}..."

        # Send API request
        local response
        local http_code
        response=$(curl -s -w "\n%{http_code}" -X POST "${api_url}" \
            -H "Content-Type: application/json" \
            -d "${payload}" 2>&1)

        http_code=$(echo "$response" | tail -n1)
        local response_body=$(echo "$response" | sed '$d')

        if [ ! -z "$http_code" ] && [ "$http_code" -ge 200 ] 2>/dev/null && [ "$http_code" -lt 300 ] 2>/dev/null; then
            log "Notification sent successfully to ${NOTIFICATION_EMAIL} (HTTP ${http_code})"
            log "API Response: ${response_body}"
            success=true
            break
        else
            log "WARNING: API request failed with HTTP ${http_code}"
            log "Response: ${response_body}"

            if [ $attempt -lt $max_attempts ]; then
                log "Retrying in 5 seconds..."
                sleep 5
            fi
        fi

        attempt=$((attempt + 1))
    done

    if [ "$success" = false ]; then
        log "ERROR: Failed to send notification after ${max_attempts} attempts"
        log "Backup completed successfully but notification failed"
        return 1
    fi

    return 0
}

# Generate email body
generate_email_body() {
    local status=$1
    local rabbitmq_status=$(cat "${STATUS_ROOT}/rabbitmq_last_backup.json" 2>/dev/null | jq -r '.status' || echo "unknown")
    local loki_status=$(cat "${STATUS_ROOT}/loki_last_backup.json" 2>/dev/null | jq -r '.status' || echo "unknown")
    local grafana_status=$(cat "${STATUS_ROOT}/grafana_last_backup.json" 2>/dev/null | jq -r '.status' || echo "unknown")

    local rabbitmq_size=$(cat "${STATUS_ROOT}/rabbitmq_last_backup.json" 2>/dev/null | jq -r '.size_bytes' || echo "0")
    local loki_size=$(cat "${STATUS_ROOT}/loki_last_backup.json" 2>/dev/null | jq -r '.size_bytes' || echo "0")
    local grafana_size=$(cat "${STATUS_ROOT}/grafana_last_backup.json" 2>/dev/null | jq -r '.size_bytes' || echo "0")

    # Format sizes
    rabbitmq_size_human=$(numfmt --to=iec ${rabbitmq_size} 2>/dev/null || echo "${rabbitmq_size} bytes")
    loki_size_human=$(numfmt --to=iec ${loki_size} 2>/dev/null || echo "${loki_size} bytes")
    grafana_size_human=$(numfmt --to=iec ${grafana_size} 2>/dev/null || echo "${grafana_size} bytes")

    cat <<EOF
Alan Backend Backup Report
==========================

Status: ${status}
Timestamp: $(date)
Duration: ${DURATION} seconds
Failed Services: ${FAILED_COUNT}/3

Service Status:
---------------
RabbitMQ: ${rabbitmq_status} (${rabbitmq_size_human})
Loki:     ${loki_status} (${loki_size_human})
Grafana:  ${grafana_status} (${grafana_size_human})

Backup Location:
----------------
/mnt/shared/alan/backups/

Retention Policy:
-----------------
Daily backups: 7 days
Weekly backups: 4 weeks

Next Scheduled Backup:
---------------------
$(cat "${STATUS_ROOT}/backup_summary.json" 2>/dev/null | jq -r '.next_scheduled_backup' || echo "See backup schedule configuration")

---
This is an automated message from the Alan Backend Backup Service.
View details in the dashboard or check status files at ${STATUS_ROOT}/
EOF
}

# Create webhook payload for API integration
create_webhook_payload() {
    local status=$1
    local summary_file="${STATUS_ROOT}/backup_summary.json"

    if [ ! -f "$summary_file" ]; then
        log "Summary file not found, cannot create webhook payload"
        return 1
    fi

    # Create webhook payload
    cat > "${STATUS_ROOT}/webhook_payload.json" <<EOF
{
  "event": "backup_completed",
  "timestamp": "$(date -Iseconds)",
  "status": "${status}",
  "failed_count": ${FAILED_COUNT},
  "duration_seconds": ${DURATION},
  "summary": $(cat "$summary_file")
}
EOF

    log "Webhook payload created at ${STATUS_ROOT}/webhook_payload.json"
}

# Main execution
main() {
    log "Preparing notifications..."

    # Determine overall status
    if [ ${FAILED_COUNT} -eq 0 ]; then
        status="SUCCESS"
        subject="Alan Backup: Success"
    else
        status="PARTIAL_FAILURE"
        subject="Alan Backup: Warning - ${FAILED_COUNT} service(s) failed"
    fi

    # Generate email body
    email_body=$(generate_email_body "$status")

    # Send notification via API
    send_api_notification "$subject" "$email_body"

    # Create webhook payload for API integration
    create_webhook_payload "$status"

    log "Notification process completed"
}

# Run main function
main
