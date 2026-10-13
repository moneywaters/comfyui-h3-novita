#!/bin/bash
# SSH straight into a Novita GPU instance from this Mac.
#
# Shadowrocket (a system-wide packet tunnel) intercepts outbound TCP, so a bare
# `ssh <ip> -p <port>` stalls even though the instance is healthy. The fix is to
# tunnel through Shadowrocket's HTTP CONNECT proxy instead of routing
# transparently — hence http-connect-proxy.
#
#   ./novita-ssh.sh <instanceId> [remote command...]
#   ./novita-ssh.sh --list
set -uo pipefail

API_KEY="${NOVITA_API_KEY:-sk_-9UruuL5HS9S3lT0iStLtkFhTFxixkEd00zSPjI9tv8}"
B="https://api.novita.ai/gpu-instance/openapi/v1"
KEY="${NOVITA_SSH_KEY:-$HOME/.ssh/novita}"
PROXY_BIN="${HTTP_CONNECT_PROXY_BIN:-$HOME/bin/http-connect-proxy}"
PROXY_ADDR="${HTTP_CONNECT_PROXY:-127.0.0.1:1082}"

api() { curl -s --max-time 30 -H "Authorization: Bearer ${API_KEY}" "$@"; }

find_instance() {  # <id> -> "host port"  (empty if not found)
    api "$B/gpu/instances?pageSize=50&pageNum=1" | ID="$1" python3 -c "
import json,sys,os
want=os.environ['ID']
try: d=json.load(sys.stdin)
except Exception: raise SystemExit
for i in d.get('instances', []):
    if i.get('id') != want: continue
    host=port=''
    for p in (i.get('portMappings') or []):
        if str(p.get('port'))=='22' and p.get('endpoint'):
            ep=p['endpoint']
            host, _, port = ep.rpartition(':')
    print(i.get('status',''), host, port)
"
}

case "${1:-}" in
  --list|"")
    api "$B/gpu/instances?pageSize=50&pageNum=1" | python3 -c "
import json,sys
d=json.load(sys.stdin)
rows=d.get('instances', [])
if not rows: print('  (no instances)')
for i in rows:
    ssh=''
    for p in (i.get('portMappings') or []):
        if str(p.get('port'))=='22': ssh=p.get('endpoint') or ''
    print(f\"  {i['id']}  {i.get('status','?'):<10} {i.get('productName','?'):<18} {ssh}\")
"
    exit 0;;
esac

ID="$1"; shift
info=$(find_instance "$ID")
status=$(echo "$info" | awk '{print $1}')
host=$(echo "$info" | awk '{print $2}')
port=$(echo "$info" | awk '{print $3}')

if [ -z "$host" ] || [ -z "$port" ]; then
    if [ -z "$status" ]; then
        echo "instance '$ID' not found — run: $0 --list" >&2
    else
        echo "instance '$ID' is '$status' and has no SSH endpoint yet; wait for running" >&2
    fi
    exit 1
fi
[ "$status" = "running" ] || echo "note: instance status is '$status'" >&2

PROXY_ARGS=()
if [ -x "$PROXY_BIN" ] && nc -z -G 2 127.0.0.1 "${PROXY_ADDR##*:}" 2>/dev/null; then
    echo "-> ssh root@${host}:${port}  (via HTTP CONNECT ${PROXY_ADDR})" >&2
    PROXY_ARGS=(-o "ProxyCommand=${PROXY_BIN} %h %p")
else
    echo "-> ssh root@${host}:${port}  (direct; no proxy at ${PROXY_ADDR})" >&2
fi

if [ "$#" -eq 0 ]; then
    exec ssh -i "$KEY" -p "$port" \
        -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o ServerAliveInterval=30 -o ServerAliveCountMax=10 \
        "${PROXY_ARGS[@]}" "root@${host}"
fi
exec ssh -i "$KEY" -p "$port" \
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o ServerAliveInterval=30 -o ServerAliveCountMax=10 \
    "${PROXY_ARGS[@]}" "root@${host}" "$@"
