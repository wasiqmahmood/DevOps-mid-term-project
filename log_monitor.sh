#!/bin/bash
# =============================================================================
# ENHANCED LOG MONITOR WITH CONTEXTUAL ALERTS
# =============================================================================

# Set PATH explicitly to include jq
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# --- Configuration ---
LOG_FILES=("/var/log/syslog" "/var/log/auth.log")
KEYWORDS=("error" "failed" "critical" "denied" "unauthorized")
STATE_DIR="/var/log/monitor_state"
ALERT_EMAIL=$(source /etc/profile.d/backup_env.sh 2>/dev/null; echo $ALERT_EMAIL)
SLACK_WEBHOOK=$(source /etc/profile.d/backup_env.sh 2>/dev/null; echo $SLACK_WEBHOOK)

# --- Alert Functions ---
send_email_alert() {
  local subject="$1"
  local body="$2"
  if [ -n "$ALERT_EMAIL" ] && command -v mail >/dev/null; then
    echo "$body" | mail -s "$subject" "$ALERT_EMAIL"
  else
    echo "Email alert not sent: mail command not available or ALERT_EMAIL not set" >&2
  fi
}

send_slack_alert() {
  local message="$1"
  local log_excerpt="$2"
  
  # Use full path to jq if available
  local jq_path=$(command -v jq)
  
  if [ -n "$jq_path" ]; then
    local payload=$($jq_path -n \
      --arg text "$message" \
      --arg excerpt "$log_excerpt" \
      '{text: "\($text)\n```\($excerpt)```"}')
  else
    local payload="{\"text\":\"$message\n\`\`\`$log_excerpt\`\`\`\"}"
  fi
  
  if [ -n "$SLACK_WEBHOOK" ]; then
    curl -s -X POST -H "Content-type: application/json" \
      -d "$payload" "$SLACK_WEBHOOK" >/dev/null
  else
    echo "Slack alert not sent: SLACK_WEBHOOK not set" >&2
  fi
}

# --- State Management ---
get_log_state() {
  local log="$1"
  local state_file="$STATE_DIR/$(basename "$log").state"
  
  if [ -f "$state_file" ]; then
    read -r last_inode last_size < "$state_file"
    echo "$last_inode $last_size"
  else
    echo "0 0"
  fi
}

update_log_state() {
  local log="$1"
  local inode="$2"
  local size="$3"
  local state_file="$STATE_DIR/$(basename "$log").state"
  
  mkdir -p "$STATE_DIR"
  echo "$inode $size" > "$state_file"
}

# --- Monitoring Core ---
process_log() {
  local log="$1"
  [ ! -f "$log" ] && return
  
  # Get current state
  current_inode=$(stat -c%i "$log" 2>/dev/null)
  [ -z "$current_inode" ] && return
  current_size=$(stat -c%s "$log" 2>/dev/null)
  
  # Get last state
  read -r last_inode last_size < <(get_log_state "$log")
  
  # Handle log rotation
  if [[ "$current_inode" != "$last_inode" ]] || [[ "$current_size" -lt "$last_size" ]]; then
    last_size=0
  fi
  
  # Process new content
  if [[ "$current_size" -gt "$last_size" ]]; then
    new_content=$(tail -c +$((last_size + 1)) "$log" 2>/dev/null)
    
    # Check for keywords
    for term in "${KEYWORDS[@]}"; do
      if grep -iq -m1 "$term" <<< "$new_content"; then
        # Prepare alert
        local timestamp=$(date +"%Y-%m-%d %H:%M:%S")
        local hostname=$(hostname)
        local alert_subject="[ALERT] $hostname: $term detected in $(basename "$log")"
        local alert_message="$timestamp - $term found in $log"
        
        # Get context
        local log_excerpt=$(grep -i -C 2 "$term" <<< "$new_content" | head -n 10)
        
        # Log to monitor.log
        echo "ALERT: Keyword '$term' found in $log at $timestamp" >> /var/log/monitor.log
        
        # Send alerts
        send_email_alert "$alert_subject" "$alert_message\n\nExcerpt:\n$log_excerpt"
        send_slack_alert "$alert_message" "$log_excerpt"
      fi
    done
    
    # Update state
    update_log_state "$log" "$current_inode" "$current_size"
  fi
}

# --- Main Execution ---
main() {
  mkdir -p "$STATE_DIR"
  
  # Log start of monitoring
  echo "$(date) - Starting log monitoring" >> /var/log/monitor.log
  
  for log in "${LOG_FILES[@]}"; do
    process_log "$log"
  done
  
  # Log end of monitoring
  echo "$(date) - Completed log monitoring cycle" >> /var/log/monitor.log
}

main "$@"
