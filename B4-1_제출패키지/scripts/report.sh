#!/usr/bin/env bash
# Optional YYYY-MM-DD HH:MM:SS start and end timestamps in local time.
set -euo pipefail
export LC_ALL=C
LOG="${AGENT_LOG_DIR:-/var/log/agent-app}/monitor.log"
if (( $# != 0 && $# != 2 )); then echo 'Usage: report.sh ["start YYYY-MM-DD HH:MM:SS" "end YYYY-MM-DD HH:MM:SS"]' >&2; exit 2; fi
[[ -r "$LOG" ]] || { echo "[WARNING] No readable log: $LOG" >&2; exit 1; }
START="${1:-}"; END="${2:-}"
if [[ -n "$START" && ( ! "$START" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}:[0-9]{2}$ || ! "$END" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}:[0-9]{2}$ ) ]]; then
 echo '[ERROR] Timestamp format: YYYY-MM-DD HH:MM:SS' >&2; exit 2
fi
awk -v start="$START" -v finish="$END" '
function summary(title,typ,avg) {
 if (count==0) return
 avg=sum[typ]/count
 printf "[%s]\n",title
 printf "Average : %.1f%%\n", avg
 printf "Maximum : %.1f%% at %s\n",hi[typ],hi_ts[typ]
 printf "Minimum : %.1f%% at %s\n",lo[typ],lo_ts[typ]
}
BEGIN {print "====== STATISTICS REPORT ======"}
{
 if (!match($0,/^\[[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}\]/)) next
 ts=substr($0,2,19)
 if (start!="" && (ts<start || ts>finish)) next
 if (!match($0,/CPU:[0-9.]+% MEM:[0-9.]+% DISK_USED:[0-9.]+%/)) next
 chunk=substr($0,RSTART,RLENGTH); split(chunk,items," ")
 for(i=1;i<=3;i++){split(items[i],p,":"); gsub(/%/,"",p[2]); x=p[2]+0; typ=i; sum[typ]+=x
 if(count==0 || x>hi[typ]){hi[typ]=x;hi_ts[typ]=ts}
 if(count==0 || x<lo[typ]){lo[typ]=x;lo_ts[typ]=ts}
 }
 count++
}
END {
 if(count==0) {print "[WARNING] No matching data points";exit 1}
 summary("CPU",1);summary("Memory",2);summary("Disk Used",3)
 printf "[Samples]\nData Points: %d samples\n",count
}' "$LOG"
