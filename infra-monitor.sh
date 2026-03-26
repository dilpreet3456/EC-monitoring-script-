
#!/bin/bash

set -euo pipefail

# =========================
# CONFIG
# =========================
LOG_FILE="infra_monitor.log"
DISK_THRESHOLD=80
SERVICE_NAME="nginx"
DRY_RUN=${DRY_RUN:-false}

# =========================
# LOGGING
# =========================
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

error_exit() {
    log "ERROR: $1"
    exit 1
}

# =========================
# CHECK EC2 METADATA (SAFE)
# =========================
check_instance_health() {

    if curl -s --connect-timeout 2 http://169.254.169.254 >/dev/null; then

        TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" \
        -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")

        INSTANCE_ID=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
        http://169.254.169.254/latest/meta-data/instance-id)

        log "Running on EC2: $INSTANCE_ID"

    else
        log "Not running on EC2 (Skipping metadata check)"
    fi
}

# =========================
# AUTO-INSTALL + SERVICE CHECK
# =========================
install_nginx_if_needed() {

    if ! command -v nginx >/dev/null 2>&1; then
        log "nginx not found. Installing..."

        PKG_MANAGER=$(command -v dnf || command -v yum)

        if [ "$DRY_RUN" = true ]; then
            log "[DRY RUN] Would install nginx"
        else
            sudo $PKG_MANAGER install -y nginx || error_exit "Install failed"
        fi

        log "nginx installation completed"
    fi
}

check_service() {

    # Detect CI/CD (no systemd)
    if [ ! -d /run/systemd/system ]; then
        log "CI/CD environment detected → skipping service management"
        return 0
    fi

    # Install nginx if missing
    if ! command -v nginx >/dev/null 2>&1; then
        log "nginx not found. Installing..."
        PKG_MANAGER=$(command -v dnf || command -v yum)
        sudo $PKG_MANAGER install -y nginx || error_exit "Install failed"
    fi

    # Check service status
    if systemctl is-active --quiet "$SERVICE_NAME"; then
        log "$SERVICE_NAME is running"
    else
        log "$SERVICE_NAME is NOT running"
        sudo systemctl start "$SERVICE_NAME" || error_exit "Failed to start service"
        log "$SERVICE_NAME started successfully"
    fi
}

# =========================
# DISK CHECK
# =========================
check_disk() {

    USAGE=$(df / | awk 'NR==2 {print $5}' | sed 's/%//')

    if [[ "$USAGE" -gt "$DISK_THRESHOLD" ]]; then
        log "WARNING: Disk usage is ${USAGE}%"
    else
        log "Disk usage normal: ${USAGE}%"
    fi
}

# =========================
# LOG ROTATION (SAFE)
# =========================
rotate_logs() {

    if [ "$DRY_RUN" = true ]; then
        log "[DRY RUN] Would rotate logs"
        return
    fi

    find . -name "*.log" -size +1M | while read file; do
        gzip "$file"
        log "Compressed log: $file"
    done
}

# =========================
# MAIN
# =========================
main() {

    log "===== Script Started ====="

    check_instance_health
    check_service
    check_disk
    rotate_logs

    log "===== Script Completed ====="
}

main "$@"
