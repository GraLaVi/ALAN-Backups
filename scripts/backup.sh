#!/bin/bash
#
# Alan Backend - Centralized Backup Script
# Backs up RabbitMQ, Loki, and Grafana volumes
# Creates JSON status files for API integration
#

set -e

# Configuration
BACKUP_ROOT="/backups"
STATUS_ROOT="/services/health_checks/status"
TIMESTAMP=$(date +%Y-%m-%dT%H-%M-%S)
DATE=$(date +%Y-%m-%d)
WEEKDAY=$(date +%u)  # 1=Monday, 7=Sunday

# Retention settings
RETENTION_DAILY=${RETENTION_DAILY:-7}
RETENTION_WEEKLY=${RETENTION_WEEKLY:-4}
RETENTION_ERROR_LOGS=${RETENTION_ERROR_LOGS:-30}  # Keep error logs for 30 days

# Timeout settings
BACKUP_TIMEOUT=${BACKUP_TIMEOUT:-7200}  # Default 2 hours for large databases

# Log function
log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1"
}

# Check available disk space
check_disk_space() {
    local required_bytes=$1
    local backup_path=$2
    
    # Get available space in bytes for the backup directory
    local available_bytes=0
    local check_path="$(dirname "$backup_path")"
    
    if ! command -v df >/dev/null 2>&1; then
        log "WARNING: df command not available, skipping disk space check"
        return 0
    fi
    
    # Ensure the path exists
    if [ ! -d "$check_path" ]; then
        log "WARNING: Path '$check_path' does not exist, skipping disk space check"
        return 0
    fi
    
    # Try df -B1 first (1-byte blocks), fallback to df -k (1KB blocks) if not supported
    local df_output
    local block_size=1
    local available_blocks=0
    local df_exit_code=0
    
    # Try -B1 first
    if df -B1 "$check_path" >/dev/null 2>&1; then
        df_output=$(df -P -B1 "$check_path" 2>&1)
        df_exit_code=$?
        block_size=1
        log "DEBUG: Using df -B1 (1-byte blocks)"
    else
        # Fallback to -k (1KB blocks)
        df_output=$(df -P -k "$check_path" 2>&1)
        df_exit_code=$?
        block_size=1024
        log "DEBUG: Using df -k (1KB blocks) as -B1 is not available"
    fi
    
    # Always log the df output for debugging
    log "DEBUG: df command for path '$check_path' returned exit code: $df_exit_code"
    log "DEBUG: df output: $df_output"
    
    if [ $df_exit_code -ne 0 ]; then
        log "WARNING: df command failed for path '$check_path', output: $df_output"
        log "WARNING: Skipping disk space check"
        return 0
    fi
    
    # Parse available space from df output
    # In POSIX mode, columns are: Filesystem, Blocks, Used, Available, Capacity%, Mounted
    # Try multiple parsing methods to be robust
    available_blocks=$(echo "$df_output" | tail -n +2 | awk '{print $4}' | head -1 | tr -d ' ')
    
    # If that didn't work, try getting the "Available" column by name (some df versions)
    if [ -z "$available_blocks" ] || ! echo "$available_blocks" | grep -qE '^[0-9]+$'; then
        # Try alternative: look for the line and get the 4th field
        available_blocks=$(echo "$df_output" | grep -E "^[^ ]+.*[0-9]+.*[0-9]+.*[0-9]+" | awk '{print $4}' | head -1 | tr -d ' ')
    fi
    
    log "DEBUG: Parsed available_blocks from df: '$available_blocks'"
    log "DEBUG: Full df line: $(echo "$df_output" | tail -n +2 | head -1)"
    
    # Validate that we got a number
    if [ -z "$available_blocks" ] || ! echo "$available_blocks" | grep -qE '^[0-9]+$'; then
        log "WARNING: Could not parse available disk space from df output"
        log "DEBUG: df output was: $df_output"
        log "DEBUG: Parsed available_blocks: '$available_blocks'"
        log "WARNING: Skipping disk space check"
        return 0
    fi
    
    # Convert to bytes
    available_bytes=$((available_blocks * block_size))
    
    # Log disk space information for debugging
    local available_display=$(numfmt --to=iec ${available_bytes} 2>/dev/null || echo "${available_bytes} bytes")
    local required_display=$(numfmt --to=iec ${required_bytes} 2>/dev/null || echo "${required_bytes} bytes")
    log "Disk space check for ${check_path}: Available: ${available_display}, Required: ${required_display}"
    log "DEBUG: Calculation: ${available_blocks} blocks × ${block_size} bytes/block = ${available_bytes} bytes"
    
    if [ "$available_bytes" -lt "$required_bytes" ]; then
        log "ERROR: Insufficient disk space. Required: ${required_display}, Available: ${available_display}"
        log "DEBUG: df output was: $df_output"
        log "DEBUG: Parsed ${available_blocks} blocks of ${block_size} bytes = ${available_bytes} bytes"
        return 1
    fi
    
    return 0
}

# Get database size estimate in bytes
get_database_size() {
    local db_name=$1
    local size_bytes
    
    # Query database size from PostgreSQL (native connection)
    # Use PGPASSWORD for authentication
    size_bytes=$(PGPASSWORD="${POSTGRES_PASS}" psql -h "${POSTGRES_HOST}" -p "${POSTGRES_PORT:-5432}" -U "${POSTGRES_USER}" -d "${POSTGRES_DB:-postgres}" -t -A -c "SELECT pg_database_size('${db_name}');" 2>/dev/null | tr -d ' ' || echo "0")
    
    # Return 0 if query failed
    if [ -z "$size_bytes" ] || [ "$size_bytes" = "0" ]; then
        echo "0"
        return 1
    fi
    
    echo "$size_bytes"
    return 0
}

# Run command with timeout
run_with_timeout() {
    local timeout_seconds=$1
    shift
    local cmd="$@"
    
    # Check if timeout command is available
    if command -v timeout >/dev/null 2>&1; then
        timeout "${timeout_seconds}" $cmd
        local exit_code=$?
        if [ $exit_code -eq 124 ]; then
            log "ERROR: Command timed out after ${timeout_seconds} seconds"
            return 124
        fi
        return $exit_code
    else
        # Fallback: run without timeout if timeout command not available
        log "WARNING: timeout command not available, running without timeout"
        $cmd
        return $?
    fi
}

# Calculate next cron execution time based on BACKUP_SCHEDULE
# Example: BACKUP_SCHEDULE="0 3 * * *" means 3:00 AM daily
calculate_next_backup_time() {
    local schedule="${BACKUP_SCHEDULE:-0 3 * * *}"

    # Parse cron expression (minute hour day month weekday)
    local cron_minute=$(echo "$schedule" | awk '{print $1}')
    local cron_hour=$(echo "$schedule" | awk '{print $2}')

    # Get current time components
    local current_hour=$(date +%H | sed 's/^0//')
    local current_minute=$(date +%M | sed 's/^0//')

    # Handle empty string when stripping leading zero from "00"
    [ -z "$current_hour" ] && current_hour=0
    [ -z "$current_minute" ] && current_minute=0

    # Calculate next execution time
    local next_date
    if [ "$current_hour" -lt "$cron_hour" ] || \
       ([ "$current_hour" -eq "$cron_hour" ] && [ "$current_minute" -lt "$cron_minute" ]); then
        # Next run is today
        next_date=$(date +%Y-%m-%d)
    else
        # Next run is tomorrow (BusyBox-compatible: add 86400 seconds = 1 day)
        next_date=$(date -d "@$(($(date +%s) + 86400))" +%Y-%m-%d)
    fi

    # Format: YYYY-MM-DDTHH:MM:SS with timezone
    printf "%sT%02d:%02d:00%s" "$next_date" "$cron_hour" "$cron_minute" "$(date +%z | sed 's/\([+-][0-9][0-9]\)\([0-9][0-9]\)/\1:\2/')"
}

# Update status file (JSON format for API)
update_status() {
    local service=$1
    local status=$2
    local message=$3
    local size=$4
    local duration=$5

    # Escape strings for JSON
    local escaped_service=$(escape_json_string "${service}")
    local escaped_status=$(escape_json_string "${status}")
    local escaped_message=$(escape_json_string "${message}")

    # Ensure numeric fields are valid (default to 0 if empty or not a number)
    local size_value=${size:-0}
    local duration_value=${duration:-0}
    # Validate they are numeric
    if ! echo "$size_value" | grep -qE '^-?[0-9]+$'; then
        size_value=0
    fi
    if ! echo "$duration_value" | grep -qE '^-?[0-9]+$'; then
        duration_value=0
    fi

    cat > "${STATUS_ROOT}/${service}_last_backup.json" <<EOF
{
  "service": "${escaped_service}",
  "status": "${escaped_status}",
  "message": "${escaped_message}",
  "timestamp": "$(date -Iseconds)",
  "backup_date": "${DATE}",
  "backup_file": "${escaped_service}/daily/backup-${TIMESTAMP}.tar.gz",
  "size_bytes": ${size_value},
  "duration_seconds": ${duration_value}
}
EOF
}

# Backup RabbitMQ
backup_rabbitmq() {
    log "Starting RabbitMQ backup..."
    local start_time=$(date +%s)
    local backup_dir="${BACKUP_ROOT}/rabbitmq"

    # Determine if weekly backup (Sunday = 7)
    if [ "$WEEKDAY" -eq 7 ]; then
        local target_dir="${backup_dir}/weekly"
    else
        local target_dir="${backup_dir}/daily"
    fi

    local backup_file="${target_dir}/backup-${TIMESTAMP}.tar.gz"

    # Backup RabbitMQ definitions (queues, exchanges, bindings)
    log "Exporting RabbitMQ definitions..."
    if curl -s -u "${RABBITMQ_USER}:${RABBITMQ_PASS}" \
         "http://${RABBITMQ_HOST}:${RABBITMQ_PORT}/api/definitions" \
         -o "${target_dir}/definitions-${TIMESTAMP}.json"; then
        log "RabbitMQ definitions exported successfully"
    else
        log "WARNING: Failed to export RabbitMQ definitions (may not be critical)"
    fi

    # Backup RabbitMQ data volume
    log "Creating RabbitMQ volume backup..."
    tar czf "${backup_file}" \
        -C /source/rabbitmq_data . \
        2>/dev/null || true

    local end_time=$(date +%s)
    local duration=$((end_time - start_time))
    local size=$(stat -c%s "${backup_file}" 2>/dev/null || echo 0)

    if [ -f "${backup_file}" ]; then
        log "RabbitMQ backup completed: ${backup_file} ($(numfmt --to=iec ${size} 2>/dev/null || echo ${size}))"
        update_status "rabbitmq" "success" "Backup completed successfully" "${size}" "${duration}"
        return 0
    else
        log "ERROR: RabbitMQ backup failed"
        update_status "rabbitmq" "failed" "Backup file creation failed" 0 "${duration}"
        return 1
    fi
}

# Backup Loki
backup_loki() {
    log "Starting Loki backup..."
    local start_time=$(date +%s)
    local backup_dir="${BACKUP_ROOT}/loki"

    if [ "$WEEKDAY" -eq 7 ]; then
        local target_dir="${backup_dir}/weekly"
    else
        local target_dir="${backup_dir}/daily"
    fi

    local backup_file="${target_dir}/backup-${TIMESTAMP}.tar.gz"

    log "Creating Loki volume backup..."
    tar czf "${backup_file}" \
        -C /source/loki-data . \
        2>/dev/null || true

    local end_time=$(date +%s)
    local duration=$((end_time - start_time))
    local size=$(stat -c%s "${backup_file}" 2>/dev/null || echo 0)

    if [ -f "${backup_file}" ]; then
        log "Loki backup completed: ${backup_file} ($(numfmt --to=iec ${size} 2>/dev/null || echo ${size}))"
        update_status "loki" "success" "Backup completed successfully" "${size}" "${duration}"
        return 0
    else
        log "ERROR: Loki backup failed"
        update_status "loki" "failed" "Backup file creation failed" 0 "${duration}"
        return 1
    fi
}

# Backup Grafana
backup_grafana() {
    log "Starting Grafana backup..."
    local start_time=$(date +%s)
    local backup_dir="${BACKUP_ROOT}/grafana"

    if [ "$WEEKDAY" -eq 7 ]; then
        local target_dir="${backup_dir}/weekly"
    else
        local target_dir="${backup_dir}/daily"
    fi

    local backup_file="${target_dir}/backup-${TIMESTAMP}.tar.gz"

    log "Creating Grafana volume backup..."
    tar czf "${backup_file}" \
        -C /source/grafana-data . \
        2>/dev/null || true

    local end_time=$(date +%s)
    local duration=$((end_time - start_time))
    local size=$(stat -c%s "${backup_file}" 2>/dev/null || echo 0)

    if [ -f "${backup_file}" ]; then
        log "Grafana backup completed: ${backup_file} ($(numfmt --to=iec ${size} 2>/dev/null || echo ${size}))"
        update_status "grafana" "success" "Backup completed successfully" "${size}" "${duration}"
        return 0
    else
        log "ERROR: Grafana backup failed"
        update_status "grafana" "failed" "Backup file creation failed" 0 "${duration}"
        return 1
    fi
}

# Escape string for JSON (escape quotes, backslashes, newlines, etc.)
escape_json_string() {
    local str="$1"
    # Escape backslashes first
    str="${str//\\/\\\\}"
    # Escape quotes
    str="${str//\"/\\\"}"
    # Escape newlines
    str="${str//$'\n'/\\n}"
    # Escape carriage returns
    str="${str//$'\r'/\\r}"
    # Escape tabs
    str="${str//$'\t'/\\t}"
    echo "$str"
}

# Update PostgreSQL database status file
update_postgresql_db_status() {
    local db_name=$1
    local status=$2
    local message=$3
    local size=$4
    local duration=$5
    local backup_file=$6
    local error_detail=$7

    # Escape strings for JSON
    local escaped_db_name=$(escape_json_string "${db_name}")
    local escaped_status=$(escape_json_string "${status}")
    local escaped_message=$(escape_json_string "${message}")
    local escaped_backup_file=$(escape_json_string "${backup_file:-none}")
    local escaped_error_detail=""
    
    if [ -n "$error_detail" ]; then
        escaped_error_detail=$(escape_json_string "$error_detail")
    fi

    # Ensure numeric fields are valid (default to 0 if empty or not a number)
    local size_value=${size:-0}
    local duration_value=${duration:-0}
    # Validate they are numeric
    if ! echo "$size_value" | grep -qE '^-?[0-9]+$'; then
        size_value=0
    fi
    if ! echo "$duration_value" | grep -qE '^-?[0-9]+$'; then
        duration_value=0
    fi

    if [ -n "$error_detail" ]; then
        cat > "${STATUS_ROOT}/postgresql_${db_name}_last_backup.json" <<EOF
{
  "service": "postgresql",
  "database": "${escaped_db_name}",
  "status": "${escaped_status}",
  "message": "${escaped_message}",
  "timestamp": "$(date -Iseconds)",
  "backup_date": "${DATE}",
  "backup_file": "${escaped_backup_file}",
  "size_bytes": ${size_value},
  "duration_seconds": ${duration_value},
  "error_detail": "${escaped_error_detail}"
}
EOF
    else
        cat > "${STATUS_ROOT}/postgresql_${db_name}_last_backup.json" <<EOF
{
  "service": "postgresql",
  "database": "${escaped_db_name}",
  "status": "${escaped_status}",
  "message": "${escaped_message}",
  "timestamp": "$(date -Iseconds)",
  "backup_date": "${DATE}",
  "backup_file": "${escaped_backup_file}",
  "size_bytes": ${size_value},
  "duration_seconds": ${duration_value}
}
EOF
    fi
}

# Backup PostgreSQL
backup_postgresql() {
    log "Starting PostgreSQL backup..."
    local overall_start_time=$(date +%s)
    local backup_dir="${BACKUP_ROOT}/postgresql"

    # Determine if weekly backup (Sunday = 7)
    if [ "$WEEKDAY" -eq 7 ]; then
        local target_dir="${backup_dir}/weekly"
        log "Weekly PostgreSQL backup (Sunday)"
    else
        local target_dir="${backup_dir}/daily"
        log "Daily PostgreSQL backup"
    fi
    
    # Create errors directory for preserving error logs
    local errors_dir="${backup_dir}/errors"
    mkdir -p "${errors_dir}"

    # Get list of all user databases (excluding system databases)
    log "Querying PostgreSQL for user databases..."
    local databases
    local query_output
    local query_error
    local connect_db="${POSTGRES_DB:-postgres}"
    
    # Query databases, using POSTGRES_DB (since we know it works for pg_dump)
    log "Connecting to database '${connect_db}' to query database list..."
    if ! query_output=$(PGPASSWORD="${POSTGRES_PASS}" psql -h "${POSTGRES_HOST}" -p "${POSTGRES_PORT:-5432}" -U "${POSTGRES_USER}" -d "${connect_db}" -t -A -c "SELECT datname FROM pg_database WHERE datistemplate = false AND datname != 'postgres';" 2>&1); then
        log "ERROR: psql query command failed"
        log "Error output: $query_output"
        update_postgresql_db_status "unknown" "failed" "Failed to execute database query" 0 $((($(date +%s) - overall_start_time))) "none" "psql query command failed"
        return 1
    fi
    
    query_error=$(echo "$query_output" | grep -i "^ERROR" || echo "")
    
    # Extract database names (one per line, trim whitespace, filter empty lines)
    databases=$(echo "$query_output" | grep -v -i "^ERROR" | grep -v -i "^WARNING" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | grep -v '^$' || echo "")
    
    # Check if there was an error in the query
    if [ -n "$query_error" ]; then
        log "ERROR: Failed to retrieve database list from PostgreSQL"
        log "PostgreSQL error: $query_error"
        log "Full output: $query_output"
        update_postgresql_db_status "unknown" "failed" "Failed to retrieve database list" 0 $((($(date +%s) - overall_start_time))) "none" "$(echo "$query_error" | head -1)"
        return 1
    fi

    if [ -z "$databases" ]; then
        log "ERROR: No user databases found or failed to retrieve database list from PostgreSQL"
        log "Query output: $query_output"
        update_postgresql_db_status "unknown" "failed" "No databases found or query failed" 0 $((($(date +%s) - overall_start_time))) "none" "No databases returned from query"
        return 1
    fi

    log "Found databases: $(echo $databases | tr '\n' ' ')"
    
    local total_databases=0
    local successful_backups=0
    local failed_backups=0

    # Backup each database
    for db_name in $databases; do
        total_databases=$((total_databases + 1))
        log "Backing up database: ${db_name}"
        local db_start_time=$(date +%s)
        
        local backup_file="${target_dir}/${db_name}-${TIMESTAMP}.sql.gz"
        local temp_file="${target_dir}/${db_name}-${TIMESTAMP}.sql.gz.tmp"
        local error_log="${errors_dir}/${db_name}-${TIMESTAMP}-error.log"

        # Get database size for logging and disk space check
        log "Querying database size for ${db_name}..."
        local db_size_bytes=$(get_database_size "${db_name}")
        local db_size_display="unknown"
        local estimated_backup_size=0
        
        if [ "$db_size_bytes" != "0" ] && [ -n "$db_size_bytes" ]; then
            db_size_display=$(numfmt --to=iec ${db_size_bytes} 2>/dev/null || echo "${db_size_bytes} bytes")
            log "Database ${db_name} size: ${db_size_display}"
            # Estimate backup size: 2x database size (conservative for compressed backup)
            estimated_backup_size=$((db_size_bytes * 2))
        else
            log "WARNING: Could not determine database size for ${db_name}, using default estimate"
            estimated_backup_size=1073741824  # Default 1GB estimate
        fi

        # Check disk space before starting backup
        # Use BACKUP_ROOT to check the actual mount point, not the specific file path
        if ! check_disk_space "${estimated_backup_size}" "${BACKUP_ROOT}/postgresql"; then
            local db_end_time=$(date +%s)
            local db_duration=$((db_end_time - db_start_time))
            local error_msg="Insufficient disk space for backup"
            
            # Save error log
            echo "ERROR: ${error_msg}" > "${error_log}"
            echo "Database: ${db_name}" >> "${error_log}"
            echo "Database size: ${db_size_display}" >> "${error_log}"
            echo "Required space: $(numfmt --to=iec ${estimated_backup_size} 2>/dev/null || echo "${estimated_backup_size} bytes")" >> "${error_log}"
            echo "Timestamp: $(date -Iseconds)" >> "${error_log}"
            
            log "ERROR: PostgreSQL backup failed for database ${db_name}: ${error_msg}"
            update_postgresql_db_status "${db_name}" "failed" "Backup failed: ${error_msg}" 0 "${db_duration}" "none" "${error_msg}"
            failed_backups=$((failed_backups + 1))
            continue
        fi

        # Enable pipefail to catch pipeline failures
        set -o pipefail
        
        # Start progress monitoring in background for long-running backups
        local progress_pid=""
        (
            local last_size=0
            local last_log_time=$(date +%s)
            local max_wait=$((BACKUP_TIMEOUT + 60))  # Wait slightly longer than timeout
            local waited=0
            while [ $waited -lt $max_wait ] && [ ! -f "${temp_file}.complete" ]; do
                sleep 30
                waited=$((waited + 30))
                if [ -f "${temp_file}" ]; then
                    local current_size=$(stat -c%s "${temp_file}" 2>/dev/null || echo 0)
                    local current_time=$(date +%s)
                    local time_since_log=$((current_time - last_log_time))
                    
                    # Log progress every 5 minutes if file is growing
                    if [ $time_since_log -ge 300 ] && [ $current_size -gt $last_size ]; then
                        local elapsed=$((current_time - db_start_time))
                        local size_display=$(numfmt --to=iec ${current_size} 2>/dev/null || echo "${current_size} bytes")
                        log "Backup progress for ${db_name}: ${elapsed}s elapsed, ${size_display} written..."
                        last_log_time=$current_time
                        last_size=$current_size
                    fi
                fi
            done
        ) &
        progress_pid=$!
        
        # Perform backup via native PostgreSQL connection
        local error_msg=""
        local pg_dump_exit_code=0
        
        log "Starting pg_dump for ${db_name} (timeout: ${BACKUP_TIMEOUT}s)..."
        
        # Run pg_dump first to a temporary uncompressed file to properly capture exit code
        # Then gzip the result, so we can check pg_dump's exit code separately
        local temp_sql_file="${target_dir}/${db_name}-${TIMESTAMP}.sql.tmp"
        
        # Run pg_dump with timeout, capturing both stdout and stderr separately
        # Use a temp file for stderr to check for errors even if exit code is 0
        local pg_dump_stderr="${temp_sql_file}.stderr"
        set +o pipefail  # Disable pipefail temporarily
        if ! PGPASSWORD="${POSTGRES_PASS}" run_with_timeout "${BACKUP_TIMEOUT}" pg_dump -h "${POSTGRES_HOST}" -p "${POSTGRES_PORT:-5432}" -U "${POSTGRES_USER}" -d "${db_name}" > "${temp_sql_file}" 2>"${pg_dump_stderr}"; then
            pg_dump_exit_code=$?
        else
            pg_dump_exit_code=0
        fi
        set -o pipefail  # Re-enable pipefail
        
        # Check if there are errors in stderr (even if exit code is 0)
        if [ -s "${pg_dump_stderr}" ]; then
            cat "${pg_dump_stderr}" >> "${error_log}"
            # If stderr has content, it might indicate a problem
            local stderr_content=$(cat "${pg_dump_stderr}")
            if echo "$stderr_content" | grep -qi "error\|failed\|fatal"; then
                pg_dump_exit_code=1
                log "WARNING: pg_dump produced error messages in stderr"
            fi
        fi
        rm -f "${pg_dump_stderr}"
        
        # Check if temp_sql_file exists and has content
        if [ ! -f "${temp_sql_file}" ]; then
            log "ERROR: pg_dump did not create output file"
            pg_dump_exit_code=1
        elif [ ! -s "${temp_sql_file}" ]; then
            log "ERROR: pg_dump output file is empty"
            pg_dump_exit_code=1
            # Show error log content for debugging
            if [ -s "${error_log}" ]; then
                log "pg_dump error output: $(head -20 "${error_log}")"
            fi
        else
            local temp_file_size=$(stat -c%s "${temp_sql_file}" 2>/dev/null || echo 0)
            log "pg_dump completed: ${temp_file_size} bytes written to temp file"
        fi
        
        # If pg_dump succeeded and file has content, compress the output
        if [ $pg_dump_exit_code -eq 0 ] && [ -s "${temp_sql_file}" ]; then
            if ! gzip -c "${temp_sql_file}" > "${temp_file}" 2>>"${error_log}"; then
                pg_dump_exit_code=1
                log "ERROR: Failed to compress backup file"
            fi
            rm -f "${temp_sql_file}"
        else
            rm -f "${temp_sql_file}"
        fi
        
        # Signal progress monitor to stop
        touch "${temp_file}.complete" 2>/dev/null || true
        sleep 1
        kill "${progress_pid}" 2>/dev/null || true
        wait "${progress_pid}" 2>/dev/null || true
        rm -f "${temp_file}.complete"
        
        # Check exit code
        if [ $pg_dump_exit_code -ne 0 ]; then
            # Read error message from log
            error_msg=$(cat "${error_log}" 2>/dev/null | head -20 || echo "pg_dump command failed (exit code: ${pg_dump_exit_code})")
            
            # Categorize error
            local error_category="unknown"
            if [ $pg_dump_exit_code -eq 124 ]; then
                error_category="timeout"
                error_msg="Backup timed out after ${BACKUP_TIMEOUT} seconds. ${error_msg}"
            elif echo "$error_msg" | grep -qi "disk\|space\|full\|no space"; then
                error_category="disk_space"
                error_msg="Disk space error: ${error_msg}"
            elif echo "$error_msg" | grep -qi "connection\|connect\|network"; then
                error_category="connection"
                error_msg="Connection error: ${error_msg}"
            else
                error_category="other"
            fi
            
            # Append additional context to error log
            {
                echo ""
                echo "=== Error Details ==="
                echo "Exit code: ${pg_dump_exit_code}"
                echo "Error category: ${error_category}"
                echo "Database: ${db_name}"
                echo "Database size: ${db_size_display}"
                echo "Duration: $((($(date +%s) - db_start_time))) seconds"
                echo "Timestamp: $(date -Iseconds)"
            } >> "${error_log}"
            
            log "ERROR: PostgreSQL backup failed for database ${db_name} (${error_category})"
            log "Error: ${error_msg}"
            log "Full error log saved to: ${error_log}"

            local db_end_time=$(date +%s)
            local db_duration=$((db_end_time - db_start_time))

            # Clean up temp file
            rm -f "${temp_file}"

            # Write failure status for this database
            update_postgresql_db_status "${db_name}" "failed" "Backup failed (${error_category})" 0 "${db_duration}" "none" "${error_msg}"
            failed_backups=$((failed_backups + 1))
            
            # Restore pipefail setting
            set +o pipefail
            continue
        fi
        
        # Restore pipefail setting
        set +o pipefail

        # Move temp file to final location
        mv "${temp_file}" "${backup_file}"
        
        # Remove error log if backup succeeded (no errors occurred)
        rm -f "${error_log}"

        local db_end_time=$(date +%s)
        local db_duration=$((db_end_time - db_start_time))
        local size=$(stat -c%s "${backup_file}" 2>/dev/null || echo 0)

        if [ -f "${backup_file}" ] && [ "${size}" -gt 0 ]; then
            local size_display=$(numfmt --to=iec ${size} 2>/dev/null || echo "${size} bytes")

            log "Database ${db_name} backup completed successfully"
            log "File: ${backup_file}"
            log "Size: ${size_display}"
            log "Duration: ${db_duration} seconds"

            # Relative path for JSON
            local relative_path="postgresql/$(basename $(dirname ${backup_file}))/$(basename ${backup_file})"

            # Write success status for this database
            update_postgresql_db_status "${db_name}" "success" "Backup completed successfully" "${size}" "${db_duration}" "${relative_path}"
            successful_backups=$((successful_backups + 1))
        else
            log "ERROR: PostgreSQL backup file is missing or empty for database ${db_name}"
            local db_duration=$((db_end_time - db_start_time))
            local error_msg="Backup file is missing or empty after completion"
            
            # Save error log for file verification failure
            {
                echo "ERROR: ${error_msg}"
                echo "Database: ${db_name}"
                echo "Database size: ${db_size_display}"
                echo "Backup file: ${backup_file}"
                echo "File exists: $([ -f "${backup_file}" ] && echo "yes" || echo "no")"
                echo "File size: ${size} bytes"
                echo "Duration: ${db_duration} seconds"
                echo "Timestamp: $(date -Iseconds)"
            } > "${error_log}"

            # Write failure status for this database
            update_postgresql_db_status "${db_name}" "failed" "Backup file is missing or empty" 0 "${db_duration}" "none" "${error_msg}"
            failed_backups=$((failed_backups + 1))
        fi
    done

    local overall_end_time=$(date +%s)
    local overall_duration=$((overall_end_time - overall_start_time))

    log "PostgreSQL backup summary: ${successful_backups}/${total_databases} databases backed up successfully"

    # Return 0 if all backups succeeded, 1 if any failed
    if [ ${failed_backups} -eq 0 ]; then
        return 0
    else
        return 1
    fi
}

# Cleanup old backups
cleanup_old_backups() {
    log "Cleaning up old backups..."

    for service in rabbitmq loki grafana postgresql; do
        local backup_dir="${BACKUP_ROOT}/${service}"

        # Clean daily backups older than RETENTION_DAILY days
        log "Cleaning ${service} daily backups older than ${RETENTION_DAILY} days..."
        find "${backup_dir}/daily" -name "*.tar.gz" -type f -mtime +${RETENTION_DAILY} -delete 2>/dev/null || true
        find "${backup_dir}/daily" -name "*.sql.gz" -type f -mtime +${RETENTION_DAILY} -delete 2>/dev/null || true
        find "${backup_dir}/daily" -name "*.json" -type f -mtime +${RETENTION_DAILY} -delete 2>/dev/null || true

        # Keep only RETENTION_WEEKLY most recent weekly backups
        log "Cleaning ${service} weekly backups, keeping ${RETENTION_WEEKLY} most recent..."
        ls -t "${backup_dir}/weekly/"*.tar.gz 2>/dev/null | tail -n +$((RETENTION_WEEKLY + 1)) | xargs rm -f 2>/dev/null || true
        ls -t "${backup_dir}/weekly/"*.sql.gz 2>/dev/null | tail -n +$((RETENTION_WEEKLY + 1)) | xargs rm -f 2>/dev/null || true
        ls -t "${backup_dir}/weekly/"*.json 2>/dev/null | tail -n +$((RETENTION_WEEKLY + 1)) | xargs rm -f 2>/dev/null || true
        
        # Clean error logs older than RETENTION_ERROR_LOGS days (only for postgresql)
        if [ "$service" = "postgresql" ] && [ -d "${backup_dir}/errors" ]; then
            log "Cleaning ${service} error logs older than ${RETENTION_ERROR_LOGS} days..."
            find "${backup_dir}/errors" -name "*-error.log" -type f -mtime +${RETENTION_ERROR_LOGS} -delete 2>/dev/null || true
        fi
    done

    log "Cleanup completed"
}

# Generate summary status
generate_summary() {
    log "Generating backup summary..."

    local rabbitmq_status=$(cat "${STATUS_ROOT}/rabbitmq_last_backup.json" 2>/dev/null | jq -r '.status' || echo "unknown")
    local loki_status=$(cat "${STATUS_ROOT}/loki_last_backup.json" 2>/dev/null | jq -r '.status' || echo "unknown")
    local grafana_status=$(cat "${STATUS_ROOT}/grafana_last_backup.json" 2>/dev/null | jq -r '.status' || echo "unknown")
    
    # Collect PostgreSQL database statuses
    local postgresql_databases_json="{}"
    local postgresql_overall_status="success"
    local postgresql_db_list=""
    
    # Find all PostgreSQL database status files
    for status_file in "${STATUS_ROOT}"/postgresql_*_last_backup.json; do
        if [ -f "$status_file" ]; then
            local db_name=$(basename "$status_file" | sed 's/postgresql_\(.*\)_last_backup.json/\1/')
            local db_status=$(cat "$status_file" 2>/dev/null | jq -r '.status' || echo "unknown")
            
            # Build database status JSON
            if [ "$postgresql_databases_json" = "{}" ]; then
                postgresql_databases_json="{\"${db_name}\": \"${db_status}\""
            else
                postgresql_databases_json="${postgresql_databases_json}, \"${db_name}\": \"${db_status}\""
            fi
            
            # Track overall PostgreSQL status (fail if any database failed)
            if [ "$db_status" != "success" ]; then
                postgresql_overall_status="partial_failure"
            fi
            
            # Build log message list
            if [ -z "$postgresql_db_list" ]; then
                postgresql_db_list="${db_name}=${db_status}"
            else
                postgresql_db_list="${postgresql_db_list}, ${db_name}=${db_status}"
            fi
        fi
    done
    
    # Close the JSON object if we added any databases
    if [ "$postgresql_databases_json" != "{}" ]; then
        postgresql_databases_json="${postgresql_databases_json}}"
    fi
    
    # If no PostgreSQL databases found, set to unknown
    if [ "$postgresql_databases_json" = "{}" ]; then
        postgresql_overall_status="unknown"
        postgresql_databases_json="{}"
    fi

    local overall_status="success"
    if [ "$rabbitmq_status" != "success" ] || [ "$loki_status" != "success" ] || [ "$grafana_status" != "success" ] || [ "$postgresql_overall_status" != "success" ]; then
        overall_status="partial_failure"
    fi

    cat > "${STATUS_ROOT}/backup_summary.json" <<EOF
{
  "overall_status": "${overall_status}",
  "timestamp": "$(date -Iseconds)",
  "services": {
    "rabbitmq": "${rabbitmq_status}",
    "loki": "${loki_status}",
    "grafana": "${grafana_status}",
    "postgresql": {
      "overall_status": "${postgresql_overall_status}",
      "databases": ${postgresql_databases_json}
    }
  },
  "retention_policy": {
    "daily": ${RETENTION_DAILY},
    "weekly": ${RETENTION_WEEKLY}
  },
  "next_scheduled_backup": "$(calculate_next_backup_time)"
}
EOF

    if [ -n "$postgresql_db_list" ]; then
        log "Summary: RabbitMQ=${rabbitmq_status}, Loki=${loki_status}, Grafana=${grafana_status}, PostgreSQL=${postgresql_overall_status} (${postgresql_db_list})"
    else
        log "Summary: RabbitMQ=${rabbitmq_status}, Loki=${loki_status}, Grafana=${grafana_status}, PostgreSQL=${postgresql_overall_status}"
    fi
}

# Main execution
main() {
    log "========================================="
    log "Starting Alan Backend Backup Process"
    log "========================================="

    local backup_start=$(date +%s)
    local failed=0

    # Run backups
    backup_rabbitmq || failed=$((failed + 1))
    backup_loki || failed=$((failed + 1))
    backup_grafana || failed=$((failed + 1))
    backup_postgresql || failed=$((failed + 1))

    # Cleanup old backups
    cleanup_old_backups

    # Generate summary
    generate_summary

    local backup_end=$(date +%s)
    local total_duration=$((backup_end - backup_start))

    log "========================================="
    log "Backup process completed in ${total_duration} seconds"
    log "Failed backups: ${failed}/4"
    log "========================================="

    # Send notification
    if [ -x /usr/local/bin/notify.sh ]; then
        /usr/local/bin/notify.sh "${failed}" "${total_duration}"
    fi

    return ${failed}
}

# Run main function
main
