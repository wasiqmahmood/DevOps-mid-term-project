#!/bin/bash
# =============================================================================
# ENHANCED BACKUP SYSTEM WITH INTEGRITY CHECKS
# =============================================================================

# --- Configuration ---
BACKUP_DIR="/backups/archives"
GIT_REPO="/backups/repo"
DIRS_TO_BACKUP=("/etc" "/var/www")
RETENTION_DAYS=30
MIN_DISK_SPACE=1048576  # 1GB in KB
ADMIN_EMAIL=$(source /etc/profile.d/backup_env.sh; echo $ADMIN_EMAIL)

# --- Initialize Logging ---  [NEW SECTION ADDED HERE]
LOG_DIR="/var/log/backups"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/backup_$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1
echo "[$(date)] Starting backup operation"  # Initial log entry

# --- Initialize ---
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
BACKUP_FILE="$BACKUP_DIR/backup-$TIMESTAMP.tar.gz"

# --- Validation Checks ---
check_disk_space() {
  local available=$(df -k --output=avail "$BACKUP_DIR" | tail -1)
  if [ "$available" -lt $MIN_DISK_SPACE ]; then
    echo "ERROR: Insufficient disk space (only ${available}KB available)"
    return 1
  fi
}
validate_directories() {
  for dir in "${DIRS_TO_BACKUP[@]}"; do
    if [ ! -d "$dir" ]; then
      echo "ERROR: Source directory $dir does not exist" | tee -a "$LOG_FILE"
      return 1
    fi
  done
}

# --- Backup Functions ---
create_archive() {
  if ! tar -czf "$BACKUP_FILE" \
      --exclude="*.tmp" \
      --exclude="cache/*" \
      "${DIRS_TO_BACKUP[@]}" 2>> "$LOG_FILE"; then
    echo "BACKUP CREATION FAILED" | tee -a "$LOG_FILE"
    return 1
  fi
}

verify_backup() {
  if ! tar -tzf "$BACKUP_FILE" >/dev/null 2>&1; then
    echo "BACKUP VERIFICATION FAILED: File is corrupted" | tee -a "$LOG_FILE"
    rm -f "$BACKUP_FILE"
    return 1
  fi
}

version_control() {
  cp "$BACKUP_FILE" "$GIT_REPO/" || return 1
  (
    cd "$GIT_REPO" || exit 1
    git add "backup-$TIMESTAMP.tar.gz" || return 1
    git commit -m "System backup $TIMESTAMP" --quiet || return 1
  )
}

apply_retention() {
  find "$BACKUP_DIR" -name "*.tar.gz" -mtime +$RETENTION_DAYS -delete 2>/dev/null
}

# --- Main Execution ---
{
  # Run validation checks
  check_disk_space || exit 1
  validate_directories || exit 1
  
  # Create and verify backup
  create_archive || exit 1
  verify_backup || exit 1
  
  # Version control
  version_control || {
    echo "GIT OPERATION FAILED" | tee -a "$LOG_FILE"
    exit 1
  }
  
  # Apply retention policy
  apply_retention
  
  # Quarterly optimization
  if [ $(date +%d) -eq 1 ] && [ $(date +%m) -eq 1 ]; then
    git -C "$GIT_REPO" gc --aggressive --quiet
  fi
  
  # Success reporting
  BACKUP_SIZE=$(du -h "$BACKUP_FILE" | cut -f1)
  echo "SUCCESS: Backup completed ($BACKUP_SIZE)" | tee -a "$LOG_FILE"
  
} || {
  # Failure handling
  echo "CRITICAL: Backup failed at step $?" | tee -a "$LOG_FILE"
  [ -n "$ADMIN_EMAIL" ] && mail -s "BACKUP FAILURE" "$ADMIN_EMAIL" < "$LOG_FILE"
  exit 1
}
