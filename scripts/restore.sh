#!/bin/bash
#
# Alan Backend - Restore Script
# Restores RabbitMQ, Loki, or Grafana from backup
#
# Usage:
#   ./restore.sh <service> <backup-file>
#   ./restore.sh rabbitmq /backups/rabbitmq/daily/backup-2024-01-01T03-00-00.tar.gz
#

set -e

# Configuration
BACKUP_ROOT="/backups"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Log functions
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Usage information
usage() {
    cat <<EOF
Alan Backend Restore Script

Usage:
    $0 <service> <backup-file>

Services:
    rabbitmq    - Restore RabbitMQ data and definitions
    loki        - Restore Loki logs data
    grafana     - Restore Grafana dashboards and config

Examples:
    # List available backups
    $0 list rabbitmq

    # Restore from specific backup
    $0 rabbitmq /backups/rabbitmq/daily/backup-2024-01-01T03-00-00.tar.gz

    # Restore from latest backup
    $0 rabbitmq latest

EOF
    exit 1
}

# List available backups
list_backups() {
    local service=$1
    local backup_dir="${BACKUP_ROOT}/${service}"

    log_info "Available backups for ${service}:"
    echo ""
    echo "Daily backups:"
    ls -lh "${backup_dir}/daily/"*.tar.gz 2>/dev/null | awk '{print "  " $9 " (" $5 ", " $6 " " $7 ")"}' || echo "  None found"

    echo ""
    echo "Weekly backups:"
    ls -lh "${backup_dir}/weekly/"*.tar.gz 2>/dev/null | awk '{print "  " $9 " (" $5 ", " $6 " " $7 ")"}' || echo "  None found"

    echo ""
    log_info "Use: $0 ${service} <backup-file-path>"
    exit 0
}

# Get latest backup
get_latest_backup() {
    local service=$1
    local latest=$(ls -t "${BACKUP_ROOT}/${service}"/daily/*.tar.gz 2>/dev/null | head -n1)

    if [ -z "$latest" ]; then
        latest=$(ls -t "${BACKUP_ROOT}/${service}"/weekly/*.tar.gz 2>/dev/null | head -n1)
    fi

    echo "$latest"
}

# Restore RabbitMQ
restore_rabbitmq() {
    local backup_file=$1

    log_warn "========================================="
    log_warn "RESTORING RABBITMQ FROM BACKUP"
    log_warn "========================================="
    log_warn "This will REPLACE all current RabbitMQ data!"
    log_warn "Backup file: ${backup_file}"
    log_warn ""

    read -p "Are you sure you want to continue? (yes/no): " confirm
    if [ "$confirm" != "yes" ]; then
        log_info "Restore cancelled"
        exit 0
    fi

    log_info "Step 1: Stopping RabbitMQ container..."
    docker stop rabbitmq 2>/dev/null || true

    log_info "Step 2: Clearing current RabbitMQ data..."
    rm -rf /source/rabbitmq_data/* 2>/dev/null || true

    log_info "Step 3: Extracting backup..."
    tar xzf "${backup_file}" -C /source/rabbitmq_data/

    # Restore definitions if available
    local backup_timestamp=$(basename "${backup_file}" | sed 's/backup-\(.*\)\.tar\.gz/\1/')
    local definitions_file=$(dirname "${backup_file}")/definitions-${backup_timestamp}.json

    if [ -f "$definitions_file" ]; then
        log_info "Step 4: RabbitMQ definitions found: ${definitions_file}"
        log_info "After RabbitMQ starts, import definitions using:"
        log_info "  curl -u guest:guest -X POST -H 'Content-Type: application/json' \\"
        log_info "    -d @${definitions_file} \\"
        log_info "    http://localhost:15672/api/definitions"
    else
        log_warn "Step 4: No definitions file found, skipping..."
    fi

    log_info "Step 5: Starting RabbitMQ container..."
    docker start rabbitmq

    log_info "========================================="
    log_info "RabbitMQ restore completed!"
    log_info "========================================="
}

# Restore Loki
restore_loki() {
    local backup_file=$1

    log_warn "========================================="
    log_warn "RESTORING LOKI FROM BACKUP"
    log_warn "========================================="
    log_warn "This will REPLACE all current Loki data!"
    log_warn "Backup file: ${backup_file}"
    log_warn ""

    read -p "Are you sure you want to continue? (yes/no): " confirm
    if [ "$confirm" != "yes" ]; then
        log_info "Restore cancelled"
        exit 0
    fi

    log_info "Step 1: Stopping Loki container..."
    docker stop loki-server 2>/dev/null || true

    log_info "Step 2: Clearing current Loki data..."
    rm -rf /source/loki-data/* 2>/dev/null || true

    log_info "Step 3: Extracting backup..."
    tar xzf "${backup_file}" -C /source/loki-data/

    log_info "Step 4: Starting Loki container..."
    docker start loki-server

    log_info "========================================="
    log_info "Loki restore completed!"
    log_info "========================================="
}

# Restore Grafana
restore_grafana() {
    local backup_file=$1

    log_warn "========================================="
    log_warn "RESTORING GRAFANA FROM BACKUP"
    log_warn "========================================="
    log_warn "This will REPLACE all current Grafana dashboards and config!"
    log_warn "Backup file: ${backup_file}"
    log_warn ""

    read -p "Are you sure you want to continue? (yes/no): " confirm
    if [ "$confirm" != "yes" ]; then
        log_info "Restore cancelled"
        exit 0
    fi

    log_info "Step 1: Stopping Grafana container..."
    docker stop loki-grafana 2>/dev/null || true

    log_info "Step 2: Clearing current Grafana data..."
    rm -rf /source/grafana-data/* 2>/dev/null || true

    log_info "Step 3: Extracting backup..."
    tar xzf "${backup_file}" -C /source/grafana-data/

    log_info "Step 4: Starting Grafana container..."
    docker start loki-grafana

    log_info "========================================="
    log_info "Grafana restore completed!"
    log_info "Login at http://localhost:3000"
    log_info "========================================="
}

# Main execution
main() {
    if [ $# -lt 1 ]; then
        usage
    fi

    local service=$1
    local backup_file=$2

    # Validate service
    case "$service" in
        rabbitmq|loki|grafana)
            ;;
        *)
            log_error "Invalid service: $service"
            usage
            ;;
    esac

    # Handle list command
    if [ "$backup_file" = "list" ] || [ -z "$backup_file" ]; then
        list_backups "$service"
    fi

    # Handle latest command
    if [ "$backup_file" = "latest" ]; then
        backup_file=$(get_latest_backup "$service")
        if [ -z "$backup_file" ]; then
            log_error "No backups found for ${service}"
            exit 1
        fi
        log_info "Using latest backup: ${backup_file}"
    fi

    # Validate backup file exists
    if [ ! -f "$backup_file" ]; then
        log_error "Backup file not found: ${backup_file}"
        exit 1
    fi

    # Perform restore
    case "$service" in
        rabbitmq)
            restore_rabbitmq "$backup_file"
            ;;
        loki)
            restore_loki "$backup_file"
            ;;
        grafana)
            restore_grafana "$backup_file"
            ;;
    esac
}

# Run main function
main "$@"
