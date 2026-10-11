#!/bin/bash
# novita-comfy.sh — bring up the prewarmed US-CA-06 ComfyUI GPU box.
#
#   ./novita-comfy.sh          start (or reuse) the instance, print + open the GUI URL
#   ./novita-comfy.sh status   show the instance, endpoints and prewarm state
#   ./novita-comfy.sh url      print just the GUI URL
#   ./novita-comfy.sh stop     delete the instance
#   ./novita-comfy.sh ssh      open an interactive SSH session
#
# Overrides (env):
#   NOVITA_API_KEY        API key                     (default from ops/novita.sh)
#   NOVITA_IMAGE          image ref to run            (default .../comfyui-h3-novita:v2.5.1)
#   NOVITA_CLUSTER        cluster id                  (default us-ca-6, i.e. US-CA-06)
#   NOVITA_INSTANCE_NAME  instance name to reuse/make (default seedhunter-prewarmed)
#   NOVITA_ROOTFS         rootfs GB                   (default 200)
#   NOVITA_BILLING        spot | onDemand | auto      (default auto: spot then onDemand)
#   NOVITA_PRODUCT        pin a product id            (default: cheapest deployable 4090)
#
# Notes
#  * US-CA-06 is prewarmed, so a start is near-instant (no 83 GB pull).
#  * `auto` tries spot first. In practice this account usually cannot allocate
#    4090 spot (INSUFFICIENT_RESOURCE even when the API advertises inventory), so
#    it falls through to on-demand, which is ~2x the price.
set -uo pipefail

API_KEY="${NOVITA_API_KEY:-sk_-9UruuL5HS9S3lT0iStLtkFhTFxixkEd00zSPjI9tv8}"
B="https://api.novita.ai/gpu-instance/openapi/v1"
IMAGE="${NOVITA_IMAGE:-docker.io/moneywaters/comfyui-h3-novita:v2.5.1}"
CLUSTER="${NOVITA_CLUSTER:-us-ca-6}"
NAME="${NOVITA_INSTANCE_NAME:-seedhunter-prewarmed}"
ROOTFS="${NOVITA_ROOTFS:-200}"
BILLING="${NOVITA_BILLING:-auto}"
PRODUCT="${NOVITA_PRODUCT:-}"
SSH_KEY="${NOVITA_SSH_KEY:-$HOME/.ssh/novita}"
SSH_HELPER="$(cd "$(dirname "$0")" 2>/dev/null && pwd)/novita-ssh.sh"
BALANCE_URL="https://api.novita.ai/openapi/v1/billing/balance/detail"

api() { curl -s --max-time 45 -H "Authorization: Bearer ${API_KEY}" "$@"; }

die() { echo "error: $*" >&2; exit 1; }

# --- pretty helpers ---------------------------------------------------------
hr() { printf '%s\n' "------------------------------------------------------------"; }

find_instance_id() {
    api "$B/gpu/instances?pageSize=50&pageNum=1" | NAME="$NAME" python3 -c "
import json,sys,os
want=os.environ['NAME']
try: d=json.load(sys.stdin)
except Exception: raise SystemExit
for i in d.get('instances', []):
    if i.get('name')==want and i.get('status') not in ('removed','toRemove'):
        print(i['id']); break
"
}

instance_json() {  # $1 = id
    api "$B/gpu/instances?pageSize=50&pageNum=1" | IID="$1" python3 -c "
import json,sys,os
iid=os.environ['IID']
try: d=json.load(sys.stdin)
except Exception: raise SystemExit
for i in d.get('instances', []):
    if i['id']==iid:
        print(json.dumps(i)); break
"
}

show_instance() {  # $1 = id
    j=$(instance_json "$1")
    [ -z "$j" ] && { echo "  (instance $1 not found)"; return 1; }
    echo "$j" | python3 -c "
import json,sys
i=json.load(sys.stdin)
print('  id      :', i['id'])
print('  name    :', i.get('name'))
print('  status  :', i.get('status'))
print('  product :', i.get('productName'))
print('  cluster :', i.get('clusterName'))
print('  billing :', i.get('billingMode'), '| rootfs', i.get('rootfsSize'), 'GB')
print('  image   :', str(i.get('imageUrl'))[:78])
for p in (i.get('portMappings') or []):
    if p.get('endpoint'):
        print('  %-7s : %s' % (str(p['port'])+'/'+str(p['type']), p['endpoint']))
se=i.get('statusError') or {}
if se.get('message'): print('  error   :', se.get('message'))
"
}

gui_url() {  # $1 = id
    instance_json "$1" | python3 -c "
import json,sys
try: i=json.load(sys.stdin)
except Exception: raise SystemExit
for p in (i.get('portMappings') or []):
    if str(p.get('port'))=='8188' and p.get('endpoint'):
        print(p['endpoint']); break
"
}

ssh_target() {  # $1 = id  -> host:port
    instance_json "$1" | python3 -c "
import json,sys
try: i=json.load(sys.stdin)
except Exception: raise SystemExit
for p in (i.get('portMappings') or []):
    if str(p.get('port'))=='22' and p.get('endpoint'):
        print(p['endpoint']); break
"
}

# --- prewarm / product lookup ----------------------------------------------
check_prewarm() {
    api "$B/image/prewarm" | IMG="$IMAGE" CID="$CLUSTER" python3 -c "
import json,sys,os,time
img=os.environ['IMG']; cid=os.environ['CID']
try: d=json.load(sys.stdin)
except Exception: print('unknown'); raise SystemExit
for t in d.get('data', []):
    if t.get('imageUrl')==img and t.get('clusterId')==cid:
        print(t.get('state')); break
else:
    print('none')
"
}

pick_product() {
    if [ -n "$PRODUCT" ]; then echo "$PRODUCT"; return 0; fi
    api "$B/products?clusterId=${CLUSTER}&gpuNum=1" | python3 -c "
import json,sys
try: d=json.load(sys.stdin)
except Exception: raise SystemExit
best=None
for p in (d.get('data') or []):
    if '4090' not in str(p.get('name','')): continue
    if not p.get('availableDeploy'): continue
    sp=int(p.get('spotPrice') or p.get('price') or 0)
    if best is None or (sp and sp < best[0]): best=(sp, p.get('id'))
print(best[1] if best else '')
"
}

create_instance() {  # $1 = product, $2 = billing
    curl -s --max-time 90 -X POST -H "Authorization: Bearer ${API_KEY}" \
      -H "Content-Type: application/json" \
      -d "{\"name\":\"${NAME}\",\"productId\":\"$1\",\"gpuNum\":1,\"rootfsSize\":${ROOTFS},
           \"imageUrl\":\"${IMAGE}\",\"ports\":\"22/tcp,8188/http\",\"kind\":\"gpu\",
           \"clusterId\":\"${CLUSTER}\",\"billingMode\":\"$2\",\"month\":0}" \
      "$B/gpu/instance/create"
}

wait_running() {  # $1 = id ; returns 0 when running
    local id="$1" i st
    for i in $(seq 1 80); do
        st=$(instance_json "$id" | python3 -c "
import json,sys
try: i=json.load(sys.stdin)
except Exception: raise SystemExit
print(i.get('status',''))
" 2>/dev/null)
        printf '\r  status: %-12s (%d)' "${st:-?}" "$i"
        case "$st" in
            running) echo; return 0;;
            exited|removed) echo; return 1;;
        esac
        sleep 10
    done
    echo; return 1
}

open_url() {
    [ "${NOVITA_NO_OPEN:-0}" = "1" ] && return 0
    if command -v open >/dev/null 2>&1; then open "$1" >/dev/null 2>&1 || true
    elif command -v xdg-open >/dev/null 2>&1; then xdg-open "$1" >/dev/null 2>&1 || true
    fi
}

# --- commands ---------------------------------------------------------------
do_start() {
    existing=$(find_instance_id)
    if [ -n "$existing" ]; then
        st=$(instance_json "$existing" | python3 -c "
import json,sys
try: i=json.load(sys.stdin)
except Exception: raise SystemExit
print(i.get('status',''))")
        hr; echo "reusing existing instance"; show_instance "$existing"
        if [ "$st" != "running" ]; then
            echo; echo "waiting for it to come up."
            wait_running "$existing" || die "instance did not reach running"
        fi
        url=$(gui_url "$existing")
        [ -n "$url" ] && { echo; echo "ComfyUI: $url"; open_url "$url"; }
        return 0
    fi

    hr; echo "preflight"
    # A prewarm on a MUTABLE tag can keep serving the old digest after a re-push:
    # the prewarm reports "Succeeded" while an instance boots stale content. Builds
    # now also publish a content-derived tag (compose-image.py prints
    # "USE FOR PREWARM/DEPLOY: <repo>:sha-<digest12>"), which cannot be re-pointed.
    case "$IMAGE" in
        *:latest|*:clore|*:main)
            echo "  WARNING: '$IMAGE' is a mutable tag."
            echo "           A prewarm on it may serve a stale cached image."
            echo "           Prefer the content tag a build prints, e.g. :sha-260882616d3e";;
    esac
    pw=$(check_prewarm)
    echo "  image  : $IMAGE"
    echo "  cluster: $CLUSTER"
    echo "  prewarm: ${pw}"
    case "$pw" in
        Succeeded) echo "          -> warm: start should take seconds";;
        Pending|Running) echo "          -> still warming: first start will pull 83 GB";;
        none) echo "          -> NO prewarm for this image in $CLUSTER; expect a long cold pull";;
    esac

    prod=$(pick_product)
    [ -z "$prod" ] && die "no deployable 4090 in $CLUSTER right now"
    echo "  product: $prod"
    bal=$(api "$BALANCE_URL" 2>/dev/null | python3 -c "
import json,sys
try: d=json.load(sys.stdin); print('%.2f' % (int(d['availableBalance'])/10000))
except Exception: print('?')" 2>/dev/null)
    echo "  balance: \$$bal"

    resp=""
    case "$BILLING" in
        spot)     echo; echo "creating spot instance"; resp=$(create_instance "$prod" spot);;
        onDemand) echo; echo "creating on-demand instance"; resp=$(create_instance "$prod" onDemand);;
        auto)
            echo; echo "creating spot instance"
            resp=$(create_instance "$prod" spot)
            case "$resp" in
              *'"id"'*) ;;
              *) echo "  spot refused: $(echo "$resp" | head -c 120)"
                 echo "  falling back to on-demand (about 2x spot)"
                 resp=$(create_instance "$prod" onDemand);;
            esac;;
        *) die "NOVITA_BILLING must be spot, onDemand or auto";;
    esac

    id=$(echo "$resp" | python3 -c "
import json,sys
try: print(json.load(sys.stdin).get('id',''))
except Exception: print('')")
    if [ -z "$id" ]; then
        echo "create failed: $resp" >&2
        echo >&2
        echo "This is usually spot capacity, not a problem with your account or image." >&2
        echo "Try: NOVITA_BILLING=onDemand $0" >&2
        exit 1
    fi
    echo "  instance: $id"

    echo
    if ! wait_running "$id"; then
        hr; echo "instance did not reach running; last state:"; show_instance "$id"; exit 1
    fi

    hr; show_instance "$id"
    url=$(gui_url "$id")
    tgt=$(ssh_target "$id")
    echo
    if [ -n "$url" ]; then
        echo "ComfyUI : $url"
        echo "  (workflows are under /opt/ComfyUI/user/default/workflows/"
        echo "   load: Minimax_Seed_Hunter_v2.5.1.json)"
    fi
    if [ -n "$tgt" ]; then
        echo "SSH     : ssh -i $SSH_KEY -p ${tgt##*:} root@${tgt%:*}"
        [ -x "$SSH_HELPER" ] && echo "          or: $SSH_HELPER $id"
    fi
    [ -n "$url" ] && { echo; echo "opening the GUI..."; open_url "$url"; }
}

do_status() {
    id=$(find_instance_id)
    if [ -z "$id" ]; then
        echo "no '$NAME' instance running."
        hr; echo "prewarm for $CLUSTER: $(check_prewarm)"
        echo "start it with: $0"
        return 1
    fi
    show_instance "$id"
    url=$(gui_url "$id")
    [ -n "$url" ] && echo "  URL     : $url"
    hr; echo "prewarm for $CLUSTER: $(check_prewarm)"
}

do_url() {
    id=$(find_instance_id)
    [ -z "$id" ] && die "no '$NAME' instance; run '$0' to start one"
    u=$(gui_url "$id"); [ -z "$u" ] && die "instance has no 8188 endpoint yet (still starting?)"
    echo "$u"
}

do_stop() {
    id=$(find_instance_id)
    [ -z "$id" ] && { echo "no '$NAME' instance to stop."; return 0; }
    echo "deleting $id ..."
    # the API field is `instanceId`; `id` fails VALIDATOR without deleting
    api -X POST -H "Content-Type: application/json" -d "{\"instanceId\":\"$id\"}" \
        "$B/gpu/instance/delete"; echo
    for _ in $(seq 1 30); do
        [ -z "$(find_instance_id)" ] && { echo "deleted."; return 0; }
        sleep 5
    done
    echo "still present after 150s; check the console."
}

do_ssh() {
    id=$(find_instance_id)
    [ -z "$id" ] && die "no '$NAME' instance; run '$0' first"
    tgt=$(ssh_target "$id"); [ -z "$tgt" ] && die "no SSH endpoint yet"
    host=${tgt%:*}; port=${tgt##*:}
    [ -x "$SSH_HELPER" ] && exec "$SSH_HELPER" "$id"
    exec ssh -i "$SSH_KEY" -p "$port" -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null "root@$host"
}

case "${1:-start}" in
    start)  do_start;;
    status) do_status;;
    url)    do_url;;
    stop)   do_stop;;
    ssh)    do_ssh;;
    -h|--help|help) sed -n '2,26p' "$0";;
    *) echo "usage: $0 [start|status|url|stop|ssh]" >&2; exit 1;;
esac
