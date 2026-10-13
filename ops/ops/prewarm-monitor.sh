#!/bin/bash
# Monitor a Novita image-prewarm task.
#
# Novita exposes no byte-level progress: the list API only carries
# state ∈ {Pending,Running,Succeeded,Failed}, createTime, completeTime and reason.
# So this polls that endpoint, prints elapsed time, and exits on a transition.
#
#   ./prewarm-monitor.sh            # watch every task, poll 60s
#   ./prewarm-monitor.sh <taskId>   # watch one task
set -uo pipefail

API_KEY="${NOVITA_API_KEY:-sk_-9UruuL5HS9S3lT0iStLtkFhTFxixkEd00zSPjI9tv8}"
B="https://api.novita.ai/gpu-instance/openapi/v1"
WANT_ID="${1:-}"
INTERVAL="${INTERVAL:-60}"
AUTH=(-H "Authorization: Bearer ${API_KEY}")

echo "=== quota (images / per-image GB) ==="
curl -s --max-time 25 "${AUTH[@]}" "$B/image/prewarm/quota" | python3 -c "
import json,sys
d=json.load(sys.stdin)
print(f\"  used {d.get('total')} of {d.get('limit')} | max image {d.get('perImageSize')} GB | policy {d.get('policy')}\")"

prev=""
n=0
while true; do
  n=$((n+1))
  raw=$(curl -s --max-time 30 "${AUTH[@]}" "$B/image/prewarm")
  now=$(date +%s)
  line=$(echo "$raw" | WANT="$WANT_ID" NOW="$now" python3 -c "
import json,sys,os
d=json.load(sys.stdin)
want=os.environ.get('WANT','')
now=int(os.environ['NOW'])
rows=d.get('data',[])
if not rows:
    print('  (no prewarm tasks)'); print('__STATE__none'); raise SystemExit
states=[]
for t in rows:
    if want and t['id']!=want: continue
    c=int(t.get('createTime') or 0)
    done=int(t.get('completeTime') or 0)
    el=(done or now)-c
    sz=int(t.get('imageSize') or 0)/1e9
    print(f\"  {t['id']}  {t.get('state'):<10} {t.get('clusterName','')[:26]:<26} {sz:6.2f}GB  elapsed {el/60:6.1f}m  reason={t.get('reason')}\")
    states.append(t.get('state'))
print('__STATE__' + ','.join(states))
")
  echo "[$(date +%H:%M:%S)] poll $n"
  echo "$line" | grep -v '__STATE__'
  st=$(echo "$line" | grep '__STATE__' | sed 's/__STATE__//')
  if [ "$st" != "$prev" ]; then echo "  ^ state changed: '${prev:-<init>}' -> '$st'"; prev="$st"; fi
  case "$st" in
    Succeeded*)  echo "== PREWARM SUCCEEDED =="; exit 0;;
    Failed*)     echo "== PREWARM FAILED ==";    exit 1;;
    none)        exit 0;;
  esac
  sleep "$INTERVAL"
done
