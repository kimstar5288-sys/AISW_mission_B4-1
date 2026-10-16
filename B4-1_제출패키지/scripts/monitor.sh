#!/usr/bin/env bash
# B4-1 | agent-admin cron runner; agent-dev:agent-core 750
set -u
export LC_ALL=C
AGENT_HOME="${AGENT_HOME:-/home/agent-admin/agent-app}"
AGENT_PORT="${AGENT_PORT:-15034}"
AGENT_LOG_DIR="${AGENT_LOG_DIR:-/var/log/agent-app}"
APP_PROCESS="${AGENT_APP_PROCESS:-agent_app.py}"
LOG_FILE="$AGENT_LOG_DIR/monitor.log"

fail(){ echo "[ERROR] $*" >&2; exit 1; }
warn(){ echo "[WARNING] $*"; }
command -v ss >/dev/null || fail 'ss command is required (iproute2).'
command -v pgrep >/dev/null || fail 'pgrep command is required (procps).'
command -v flock >/dev/null || fail 'flock command is required (util-linux).'
[[ -d "$AGENT_LOG_DIR" && -w "$AGENT_LOG_DIR" ]] || fail "Log directory not writable: $AGENT_LOG_DIR"
[[ "$AGENT_PORT" =~ ^[0-9]+$ ]] || fail 'AGENT_PORT must be numeric'

# Concurrent manual/cron runs should not race during rotation.
exec 9>"$AGENT_LOG_DIR/.monitor.lock" || fail 'Cannot open monitor lock'
flock -w 10 9 || fail 'Cannot acquire monitor lock'
echo '====== SYSTEM MONITOR RESULT ======'
echo '[HEALTH CHECK]'
# Exact file name in full argv; customize AGENT_APP_PROCESS for packaged executable.
PID="$(pgrep -f "(^|[ /])${APP_PROCESS//./\.}([[:space:]]|$)" | head -n 1 || true)"
[[ -n "$PID" ]] || fail "Application process not found: $APP_PROCESS"
echo "Checking process '$APP_PROCESS'... [OK] (PID: $PID)"
# ss output: LISTEN 0 128 0.0.0.0:15034 ... or [::]:15034
if ! ss -H -ltn | awk -v port="$AGENT_PORT" '{split($4,a,":"); if (a[length(a)]==port) found=1} END{exit !found}'; then
  fail "TCP $AGENT_PORT not LISTENING"
fi
echo "Checking port $AGENT_PORT... [OK]"

if command -v ufw >/dev/null 2>&1; then
  if ! ufw status 2>/dev/null | grep -q '^Status: active'; then warn 'UFW inactive'; fi
elif command -v firewall-cmd >/dev/null 2>&1; then
  if ! firewall-cmd --state 2>/dev/null | grep -qx running; then warn 'firewalld inactive'; fi
else
  warn 'Neither ufw nor firewalld command was found'
fi

# CPU: two /proc/stat samples (~0.2 sec), total and idle deltas.
read -r _ u1 n1 s1 i1 w1 irq1 sirq1 steal1 _ < /proc/stat
sleep 0.2
read -r _ u2 n2 s2 i2 w2 irq2 sirq2 steal2 _ < /proc/stat
t1=$((u1+n1+s1+i1+w1+irq1+sirq1+steal1))
t2=$((u2+n2+s2+i2+w2+irq2+sirq2+steal2))
id1=$((i1+w1)); id2=$((i2+w2)); dt=$((t2-t1)); did=$((id2-id1))
CPU="$(awk -v t="$dt" -v i="$did" 'BEGIN {printf "%.1f", t>0 ? 100*(t-i)/t : 0}')"
MEM="$(awk '/^MemTotal:/ {t=$2} /^MemAvailable:/ {a=$2} END {printf "%.1f", t>0 ? 100*(t-a)/t : 0}' /proc/meminfo)"
DISK="$(df -P / | awk 'NR==2 {gsub(/%/,"",$5); print $5}')"
[[ "$DISK" =~ ^[0-9]+$ ]] || fail 'Could not get disk usage'
echo '[RESOURCE MONITORING]'
echo "CPU Usage : $CPU%"
echo "MEM Usage : $MEM%"
echo "DISK Used : $DISK%"
awk -v v="$CPU" 'BEGIN{exit !(v>20)}' && warn "CPU threshold exceeded ($CPU% > 20%)"
awk -v v="$MEM" 'BEGIN{exit !(v>10)}' && warn "MEM threshold exceeded ($MEM% > 10%)"
awk -v v="$DISK" 'BEGIN{exit !(v>80)}' && warn "DISK threshold exceeded ($DISK% > 80%)"

# Retain one active file <=10 MiB and <=9 numbered backups => at most 10 files.
# Rotation happens before append, so new append may slightly exceed the threshold.
rotate_if_needed(){
  local estimated="${#1}" size
  size=$(stat -c %s "$LOG_FILE" 2>/dev/null || echo 0)
  if (( size + estimated + 1 > 10485760 )); then
    rm -f "${LOG_FILE}.9"
    for ((n=8;n>=1;n--)); do
      [[ ! -f "${LOG_FILE}.$n" ]] || mv "${LOG_FILE}.$n" "${LOG_FILE}.$((n+1))"
    done
    [[ ! -f "$LOG_FILE" ]] || mv "$LOG_FILE" "${LOG_FILE}.1"
  fi
}
LINE="[$(date '+%Y-%m-%d %H:%M:%S')] PID:$PID CPU:$CPU% MEM:$MEM% DISK_USED:$DISK%"
rotate_if_needed "$LINE"
printf '%s\n' "$LINE" >> "$LOG_FILE" || fail 'Cannot append log'
chmod 640 "$LOG_FILE" 2>/dev/null || true
printf '[INFO] Log appended: %s\n' "$LOG_FILE"
