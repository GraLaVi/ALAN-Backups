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

# Truncate string to max chars, appending a marker if cut
truncate_str() {
    local str=$1
    local max=$2
    if [ ${#str} -gt "$max" ]; then
        printf '%s…(truncated)' "${str:0:$max}"
    else
        printf '%s' "$str"
    fi
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
        api_url="http://75.119.134.30:8000/alan/process"
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

# Read a field from a status JSON file, returning a fallback if missing/unreadable
read_status_field() {
    local file=$1
    local field=$2
    local fallback=$3
    if [ -f "$file" ]; then
        local val
        val=$(jq -r "${field} // empty" "$file" 2>/dev/null)
        if [ -z "$val" ]; then
            echo "$fallback"
        else
            echo "$val"
        fi
    else
        echo "$fallback"
    fi
}

# Generate email body
generate_email_body() {
    local status=$1
    local failures=""
    local failed_count=0
    local total_count=0

    # --- Non-PostgreSQL services ---
    local rmq_file="${STATUS_ROOT}/rabbitmq_last_backup.json"
    local loki_file="${STATUS_ROOT}/loki_last_backup.json"
    local graf_file="${STATUS_ROOT}/grafana_last_backup.json"

    local rabbitmq_status=$(read_status_field "$rmq_file" ".status" "unknown")
    local rabbitmq_message=$(read_status_field "$rmq_file" ".message" "")
    local rabbitmq_size=$(read_status_field "$rmq_file" ".size_bytes" "0")
    local rabbitmq_duration=$(read_status_field "$rmq_file" ".duration_seconds" "0")

    local loki_status=$(read_status_field "$loki_file" ".status" "unknown")
    local loki_message=$(read_status_field "$loki_file" ".message" "")
    local loki_size=$(read_status_field "$loki_file" ".size_bytes" "0")
    local loki_duration=$(read_status_field "$loki_file" ".duration_seconds" "0")

    local grafana_status=$(read_status_field "$graf_file" ".status" "unknown")
    local grafana_message=$(read_status_field "$graf_file" ".message" "")
    local grafana_size=$(read_status_field "$graf_file" ".size_bytes" "0")
    local grafana_duration=$(read_status_field "$graf_file" ".duration_seconds" "0")

    local rabbitmq_size_human=$(numfmt --to=iec ${rabbitmq_size} 2>/dev/null || echo "${rabbitmq_size} bytes")
    local loki_size_human=$(numfmt --to=iec ${loki_size} 2>/dev/null || echo "${loki_size} bytes")
    local grafana_size_human=$(numfmt --to=iec ${grafana_size} 2>/dev/null || echo "${grafana_size} bytes")

    # Track each non-postgres service in totals/failures (use '|' delimiter so colons in messages survive)
    for svc in "rabbitmq|${rabbitmq_status}|${rabbitmq_message}" \
               "loki|${loki_status}|${loki_message}" \
               "grafana|${grafana_status}|${grafana_message}"; do
        total_count=$((total_count + 1))
        local s_name="${svc%%|*}"
        local rest="${svc#*|}"
        local s_status="${rest%%|*}"
        local s_message="${rest#*|}"
        if [ "$s_status" != "success" ]; then
            failed_count=$((failed_count + 1))
            failures="${failures}- ${s_name}: ${s_status}"$'\n'
            if [ -n "$s_message" ]; then
                failures="${failures}    message: $(truncate_str "$s_message" 700)"$'\n'
            fi
        fi
    done

    # --- PostgreSQL per-database rows ---
    local pg_rows=""
    shopt -s nullglob
    local pg_status_files=("${STATUS_ROOT}"/postgresql_*_last_backup.json)
    shopt -u nullglob
    if [ ${#pg_status_files[@]} -gt 0 ]; then
        for status_file in "${pg_status_files[@]}"; do
            total_count=$((total_count + 1))

            local db_name=$(read_status_field "$status_file" ".database" "unknown")
            local db_status=$(read_status_field "$status_file" ".status" "unknown")
            local db_message=$(read_status_field "$status_file" ".message" "")
            local db_error=$(read_status_field "$status_file" ".error_detail" "")
            local db_size=$(read_status_field "$status_file" ".size_bytes" "0")
            local db_duration=$(read_status_field "$status_file" ".duration_seconds" "0")
            local db_size_human=$(numfmt --to=iec ${db_size} 2>/dev/null || echo "${db_size} bytes")

            pg_rows="${pg_rows}  ${db_name}: ${db_status} (${db_size_human}, ${db_duration}s)"$'\n'

            if [ "$db_status" != "success" ]; then
                failed_count=$((failed_count + 1))
                failures="${failures}- postgresql/${db_name}: ${db_status}"$'\n'
                if [ -n "$db_message" ]; then
                    failures="${failures}    message: $(truncate_str "$db_message" 700)"$'\n'
                fi
                if [ -n "$db_error" ]; then
                    failures="${failures}    error:   $(truncate_str "$db_error" 700)"$'\n'
                fi
            fi
        done
    else
        pg_rows="  (no PostgreSQL status files found)"$'\n'
    fi

    # --- Failures section (only when something failed) ---
    local failures_section=""
    if [ -n "$failures" ]; then
        failures_section="Failures:
---------
${failures}
"
    fi

    cat <<EOF
ALAN Systems Backend Backup Report
======================================

Status: ${status}
Timestamp: $(date)
Duration: ${DURATION} seconds
Failed Services: ${failed_count}/${total_count}

${failures_section}Service Status:
---------------
RabbitMQ: ${rabbitmq_status} (${rabbitmq_size_human}, ${rabbitmq_duration}s)
Loki:     ${loki_status} (${loki_size_human}, ${loki_duration}s)
Grafana:  ${grafana_status} (${grafana_size_human}, ${grafana_duration}s)
PostgreSQL:
${pg_rows}
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
This is an automated message from the ALAN Systems Backend Backup Service.
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
        subject="ALAN Systems Backup: Success"
    else
        status="PARTIAL_FAILURE"
        subject="ALAN Systems Backup: Warning - ${FAILED_COUNT} service(s) failed"
    fi
    
    # Add environment label to subject for dev environment only
    if [ "${APP_ENV}" = "development" ]; then
        subject="${subject} (DEV)"
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
