#!/usr/bin/env bash
# Bonus 2; run as agent-admin with rights to source and destination.
set -euo pipefail
export LC_ALL=C
SOURCE_DIR="${AGENT_LOG_DIR:-/var/log/agent-app}"
ARCHIVE_DIR='/var/log/monitor/agent-app/archive'
[[ -d "$SOURCE_DIR" ]] || { echo '[WARNING] Source directory missing'; exit 0; }
[[ -r "$SOURCE_DIR" && -w "$SOURCE_DIR" ]] || { echo '[WARNING] Source directory inaccessible'; exit 1; }
if [[ ! -d "$ARCHIVE_DIR" ]]; then
  mkdir -p "$ARCHIVE_DIR" 2>/dev/null || { echo '[WARNING] Cannot create archive directory'; exit 1; }
fi
[[ -w "$ARCHIVE_DIR" ]] || { echo '[WARNING] Archive directory not writable'; exit 1; }
# Exclude active monitor.log to avoid disrupting cron writes; rotate files first.
count=0
while IFS= read -r -d '' file; do
  base="$(basename "$file")"
  [[ "$base" == monitor.log ]] && { echo '[INFO] Skipping active monitor.log'; continue; }
  output="$ARCHIVE_DIR/${base}.$(date -r "$file" +%Y%m%d%H%M%S).gz"
  [[ ! -e "$output" ]] || { echo "[WARNING] Archive exists: $output"; continue; }
  if gzip -c -- "$file" > "$output"; then
    touch -r "$file" "$output" # Preserve age for 30-day expiration.
    rm -- "$file"
    echo "[INFO] Archived $base"; count=$((count+1))
  else
    rm -f -- "$output"; echo "[WARNING] Failed to archive $base" >&2
  fi
done < <(find "$SOURCE_DIR" -maxdepth 1 -type f -name '*.log' -mtime +6 -print0)
find "$ARCHIVE_DIR" -maxdepth 1 -type f -name '*.gz' -mtime +29 -print -delete
echo "[INFO] Files archived: $count"
