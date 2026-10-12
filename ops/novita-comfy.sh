#!/bin/bash
# novita-comfy.sh — bring up the prewarmed Novita ComfyUI GPU box.
#
# Mirrors the ops/ppio.sh pattern: running it with no arguments opens a dropdown of the
# locations that have a 4090 AVAILABLE right now *and* a warm image cache, and launches
# in whichever one you pick.
#
# The image is resolved from the prewarm API at run time — never a hardcoded tag — so it
# always runs whatever the newest successful prewarm actually cached. Pinning a tag by
# hand is possible via NOVITA_IMAGE, but the default cannot go stale.
#
#   ./novita-comfy.sh                pick a warm location, launch (default)
#   ./novita-comfy.sh menu           same, explicitly
#   ./novita-comfy.sh --wait         poll us-ca-6 for a 4090, then launch
#   ./novita-comfy.sh launch [cluster] [4090]   skip the menu
#   ./novita-comfy.sh clusters       clusters, flagging 4090 + prewarm state
#   ./novita-comfy.sh products [4090]
#   ./novita-comfy.sh prewarm-list   prewarm tasks + quota
#   ./novita-comfy.sh prewarm [image] [cluster]  create a prewarm task
#   ./novita-comfy.sh instances      list instances
#   ./novita-comfy.sh deploy-wait [cluster] [4090]   poll for capacity, then create
#   ./novita-comfy.sh create <cluster> [productId] [rootfs] [name]
#   ./novita-comfy.sh status [instanceId]   our named instance, or a specific one
#   ./novita-comfy.sh url            print just the GUI URL
#   ./novita-comfy.sh ssh            open an interactive SSH session
#   ./novita-comfy.sh stop           delete our named instance
#   ./novita-comfy.sh delete <instanceId>   terminate a specific instance
#
# Overrides (env):
#   NOVITA_API_KEY        API key
#   NOVITA_IMAGE          pin an image ref      (default: newest successful prewarm)
#   NOVITA_REPO           image repo to track   (default comfyui-h3-novita)
#   NOVITA_CLUSTER        cluster id            (default us-ca-6, i.e. US-CA-06)
#   NOVITA_WANT           gpu filter            (default 4090)
#   NOVITA_INSTANCE_NAME  instance name to reuse/make (default seedhunter-prewarmed)
#   NOVITA_ROOTFS         rootfs GB             (default 200)
#   NOVITA_BILLING        spot | onDemand | auto  (default auto: spot then onDemand)
#   NOVITA_PRODUCT        pin a product id      (default: cheapest deployable 4090)
#
# Notes
#  * The default image is a CONTENT tag (sha-<digest12>). Prewarm/deploy cache is keyed
#    per reference, and a re-pushed mutable tag can keep serving old layers, so this
#    script reads the tag back from the prewarm list instead of naming one.
#  * `auto` tries spot first. In practice this account usually cannot allocate 4090 spot
#    (INSUFFICIENT_RESOURCE even when the API advertises inventory), so it falls through
#    to on-demand, which is ~2x the price.
#  * `start` is kept as an alias for the old behaviour: reuse our named instance if one
#    exists, otherwise open the picker.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# absolute path to this script: "$0" may be a bare relative name like "novita-comfy.sh"
# (e.g. `sh novita-comfy.sh`), which exec would look up in PATH and miss
SELF="$HERE/$(basename "$0")"

API_KEY="${NOVITA_API_KEY:-sk_-9UruuL5HS9S3lT0iStLtkFhTFxixkEd00zSPjI9tv8}"
B="https://api.novita.ai/gpu-instance/openapi/v1"
REPO="${NOVITA_REPO:-comfyui-h3-novita}"
CLUSTER="${NOVITA_CLUSTER:-us-ca-6}"
WANT="${NOVITA_WANT:-4090}"
NAME="${NOVITA_INSTANCE_NAME:-seedhunter-prewarmed}"
ROOTFS="${NOVITA_ROOTFS:-200}"
BILLING="${NOVITA_BILLING:-auto}"
PRODUCT="${NOVITA_PRODUCT:-}"
SSH_KEY="${NOVITA_SSH_KEY:-$HOME/.ssh/novita}"
SSH_HELPER="$HERE/novita-ssh.sh"
# shared with ops/ppio.sh; PICK_TITLE changes the prompt line
PICKER="$HERE/ppio_pick.py"
[ -f "$PICKER" ] || PICKER="$HOME/ppio_pick.py"
BALANCE_URL="https://api.novita.ai/openapi/v1/billing/balance/detail"

api() { curl -s --max-time 45 -H "Authorization: Bearer ${API_KEY}" "$@"; }
fmt() { python3 -c "import json,sys;d=json.load(sys.stdin);$1"; }

die() { echo "error: $*" >&2; exit 1; }

hr() { printf '%s\n' "------------------------------------------------------------"; }

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

ssh_target() {  # $1 = id -> host:port
    instance_json "$1" | python3 -c "
import json,sys
try: i=json.load(sys.stdin)
except Exception: raise SystemExit
for p in (i.get('portMappings') or []):
    if str(p.get('port'))=='22' and p.get('endpoint'):
        print(p['endpoint']); break
"
}

# --- image resolution --------------------------------------------------------
# Read the tag back from the prewarm list so we launch exactly what was cached.
# Hardcoding a tag here is how the previous version went stale: the prewarm moved on to
# a new content tag while the script kept asking for an old one, a cold 83 GB pull.
resolve_image() {
    if [ -n "${NOVITA_IMAGE:-}" ]; then printf '%s' "$NOVITA_IMAGE"; return 0; fi
    api "$B/image/prewarm" | REPO="$REPO" python3 -c "
import json,sys,os
repo=os.environ['REPO']
try: d=json.load(sys.stdin)
except Exception: raise SystemExit
best=None
for t in d.get('data', []):
    if repo not in str(t.get('imageUrl') or ''): continue
    if (t.get('state') or '') != 'Succeeded': continue
    key=(int(t.get('completeTime') or 0), int(t.get('createTime') or 0))
    if best is None or key > best[0]: best=(key, t['imageUrl'])
print(best[1] if best else '')
"
}

# state of an image in a cluster: Succeeded | Pending | Running | Failed | none
prewarm_state() {  # $1 = image, $2 = cluster
    api "$B/image/prewarm" | IMG="$1" CID="$2" python3 -c "
import json,sys,os
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

# clusterId -> state for one image, as JSON
prewarm_map() {  # $1 = image
    api "$B/image/prewarm" | IMG="$1" python3 -c "
import json,sys,os
img=os.environ['IMG']
try: d=json.load(sys.stdin)
except Exception: raise SystemExit
m={}
for t in d.get('data', []):
    if t.get('imageUrl')==img:
        m[t.get('clusterId')] = t.get('state')
print(json.dumps(m))
"
}

# --- capacity ----------------------------------------------------------------
clusters_with_gpu() {  # id<TAB>name for clusters advertising the GPU
    api "$B/clusters" | WANT="$WANT" python3 -c "
import json,sys,os
want=os.environ['WANT']
try: d=json.load(sys.stdin)
except Exception: raise SystemExit
for c in d.get('data', []):
    if any(want in t for t in (c.get('availableGpuType') or [])):
        print('%s\t%s' % (c['id'], c['name']))
"
}

# JSON: [{id, name, deployable:[productIds]}] for clusters that can deploy one now
live_capacity() {
    names=$(mktemp); dir=$(mktemp -d)
    clusters_with_gpu > "$names"
    if [ ! -s "$names" ]; then rm -f "$names"; rm -rf "$dir"; echo '[]'; return 0; fi
    # One file per cluster, 8 at a time. Appending 14 concurrent curl outputs to a single
    # file interleaves them mid-record and silently drops clusters; a file each cannot
    # race. Plain background jobs avoid the nested quoting an `xargs -I{} sh -c` needs.
    local cid nm n=0
    while IFS=$'\t' read -r cid nm; do
        [ -z "$cid" ] && continue
        api "$B/products?gpuNum=1&clusterId=$cid" > "$dir/$cid" 2>/dev/null &
        n=$((n + 1))
        [ $((n % 8)) -eq 0 ] && wait
    done < "$names"
    wait
    python3 - "$dir" "$names" "$WANT" <<'PY'
import json, os, sys
rdir, named, want = sys.argv[1], sys.argv[2], sys.argv[3]
names = {}
for line in open(named, encoding="utf-8"):
    cid, _, nm = line.rstrip("\n").partition("\t")
    if cid: names[cid] = nm
live = {}
for cid in names:
    try: d = json.load(open(os.path.join(rdir, cid), encoding="utf-8", errors="replace"))
    except Exception: continue
    ids = [p["id"] for p in (d.get("data") or [])
           if want in str(p.get("name", "")) and p.get("availableDeploy")]
    if ids: live[cid] = ids
print(json.dumps([{"id": c, "name": names.get(c, ""), "deployable": v} for c, v in live.items()]))
PY
    rm -f "$names"; rm -rf "$dir"
}

pick_product() {  # $1 = cluster
    if [ -n "$PRODUCT" ]; then echo "$PRODUCT"; return 0; fi
    api "$B/products?clusterId=${1}&gpuNum=1" | WANT="$WANT" python3 -c "
import json,sys,os
want=os.environ['WANT']
try: d=json.load(sys.stdin)
except Exception: raise SystemExit
best=None
for p in (d.get('data') or []):
    if want not in str(p.get('name','')) or not p.get('availableDeploy'): continue
    sp=int(p.get('spotPrice') or p.get('price') or 0)
    if best is None or (sp and sp < best[0]): best=(sp, p.get('id'))
print(best[1] if best else '')
"
}

create_instance() {  # $1 = product, $2 = billing, $3 = cluster
    curl -s --max-time 90 -X POST -H "Authorization: Bearer ${API_KEY}" \
      -H "Content-Type: application/json" \
      -d "{\"name\":\"${NAME}\",\"productId\":\"$1\",\"gpuNum\":1,\"rootfsSize\":${ROOTFS},
           \"imageUrl\":\"${IMAGE}\",\"ports\":\"22/tcp,8188/http\",\"kind\":\"gpu\",
           \"clusterId\":\"$3\",\"billingMode\":\"$2\",\"month\":0}" \
      "$B/gpu/instance/create"
}

wait_running() {  # $1 = id
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

# --- launching ---------------------------------------------------------------
do_launch() {  # $1 = cluster, $2 = want
    local cluster="$1" want="$2"
    echo "== launch: cluster=$cluster =="
    echo "   image: $IMAGE"
    pw=$(prewarm_state "$IMAGE" "$cluster")
    echo "   prewarm: $pw"
    case "$pw" in
        Succeeded) ;;
        none) echo "   NOTE: no prewarm for this image in $cluster — expect an 83 GB pull";;
        *)    echo "   NOTE: prewarm is $pw — the first start will pull 83 GB";;
    esac

    prod=$(pick_product "$cluster")
    if [ -z "$prod" ]; then
        echo "   -> no $want deployable in $cluster right now"
        echo "   poll for capacity with: $SELF deploy-wait $cluster $want"
        exit 1
    fi
    echo "   product: $prod"

    bal=$(api "$BALANCE_URL" 2>/dev/null | python3 -c "
import json,sys
try: d=json.load(sys.stdin); print('%.2f' % (int(d['availableBalance'])/10000))
except Exception: print('?')" 2>/dev/null)
    echo "   balance: \$$bal"

    local resp=""
    case "$BILLING" in
        spot)     echo "   creating spot"; resp=$(create_instance "$prod" spot "$cluster");;
        onDemand) echo "   creating on-demand"; resp=$(create_instance "$prod" onDemand "$cluster");;
        auto)
            echo "   creating spot"
            resp=$(create_instance "$prod" spot "$cluster")
            case "$resp" in
              *'"id"'*) ;;
              *) echo "   spot refused: $(printf '%s' "$resp" | head -c 120)"
                 echo "   falling back to on-demand (about 2x spot)"
                 resp=$(create_instance "$prod" onDemand "$cluster");;
            esac;;
        *) die "NOVITA_BILLING must be spot, onDemand or auto";;
    esac

    id=$(printf '%s' "$resp" | python3 -c "
import json,sys
try: print(json.load(sys.stdin).get('id',''))
except Exception: print('')")
    if [ -z "$id" ]; then
        echo "create failed: $resp" >&2
        echo >&2
        echo "This is usually capacity, not a problem with your account or image." >&2
        echo "Retry with: $SELF deploy-wait $cluster $want" >&2
        exit 1
    fi
    echo "   instance: $id"

    if ! wait_running "$id"; then
        hr; echo "instance did not reach running; last state:"; show_instance "$id"; exit 1
    fi
    hr; show_instance "$id"
    url=$(gui_url "$id"); tgt=$(ssh_target "$id")
    echo
    if [ -n "$url" ]; then
        echo "ComfyUI : $url"
        echo "  (workflows under /opt/ComfyUI/user/default/workflows/)"
    fi
    if [ -n "$tgt" ]; then
        echo "SSH     : ssh -i $SSH_KEY -p ${tgt##*:} root@${tgt%:*}"
        [ -x "$SSH_HELPER" ] && echo "          or: $SSH_HELPER $id"
    fi
    [ -n "$url" ] && { echo; echo "opening the GUI..."; open_url "$url"; }
}

do_menu() {
    [ -n "$IMAGE" ] || die "no successful prewarm for $REPO — create one with '$SELF prewarm', or set NOVITA_IMAGE"
    echo "== image (read back from the prewarm list): ${IMAGE##*:} ==" >&2
    echo "== which locations have a $WANT available AND warm ==" >&2

    live=$(live_capacity); [ -z "$live" ] && live='[]'
    pmap=$(prewarm_map "$IMAGE"); [ -z "$pmap" ] && pmap='{}'

    items=$(python3 - "$live" "$pmap" <<'PY'
import json, sys
live = json.loads(sys.argv[1])
pmap = json.loads(sys.argv[2])
# Offer a location only when BOTH hold: a 4090 is deployable now, and this image is
# already cached there. Anything else means a cold 83 GB pull.
out = [{"id": c["id"],
        "cols": [c["id"], c["name"], "%d avail" % len(c["deployable"]), "warm"]}
       for c in live if pmap.get(c["id"]) == "Succeeded"]
out.sort(key=lambda r: (-int(r["cols"][2].split()[0]), r["id"]))
print(json.dumps(out, ensure_ascii=False))
PY
)
    if [ -z "$items" ] || [ "$items" = "[]" ]; then
        echo
        echo "No location currently has a $WANT available with a warm cache for ${IMAGE##*:}."
        echo
        echo "  - warm locations, any capacity : $SELF clusters"
        echo "  - capacity only, cold start    : $SELF deploy-wait $CLUSTER $WANT"
        exit 1
    fi

    pick=$(PICK_TITLE="Novita — which location? (4090 + warm cache)" \
           python3 "$PICKER" "$items" 2>/dev/null) || exit $?
    [ -z "$pick" ] && exit 1
    echo
    exec "$SELF" launch "$pick" "$WANT"
}

show_clusters() {
    live=$(live_capacity); [ -z "$live" ] && live='[]'
    pmap=$(prewarm_map "$IMAGE"); [ -z "$pmap" ] && pmap='{}'
    python3 - "$live" "$pmap" "$WANT" "${IMAGE##*:}" <<'PY'
import json, sys
live = {c["id"]: c for c in json.loads(sys.argv[1])}
pmap = json.loads(sys.argv[2])
want, tag = sys.argv[3], sys.argv[4]
print("  image: %s" % (tag or "-"))
print("  %-20s %-32s %-12s %s" % ("CLUSTER", "NAME", want + " now", "prewarm"))
for cid in sorted(set(live) | set(pmap)):
    c = live.get(cid)
    print("  %-20s %-32s %-12s %s" % (
        cid, (c or {}).get("name", "")[:32],
        ("%d avail" % len(c["deployable"])) if c else "-",
        pmap.get(cid, "-")))
PY
}

do_deploy_wait() {  # $1 = cluster, $2 = want
    local cluster="$1" want="$2" i prods pid resp
    for i in $(seq 1 240); do
        prods=$(api "$B/products?clusterId=$cluster&gpuNum=1" | WANT="$want" python3 -c "
import json,sys,os
want=os.environ['WANT']
try: d=json.load(sys.stdin)
except Exception: raise SystemExit
print(' '.join(p['id'] for p in (d.get('data') or [])
      if want in str(p.get('name','')) and p.get('availableDeploy')))" 2>/dev/null)
        echo "[$(date +%H:%M:%S)] cycle $i deployable: ${prods:-none}"
        for pid in $prods; do
            case "$BILLING" in
                spot)     resp=$(create_instance "$pid" spot "$cluster");;
                onDemand) resp=$(create_instance "$pid" onDemand "$cluster");;
                auto)
                    resp=$(create_instance "$pid" spot "$cluster")
                    case "$resp" in
                      *'"id"'*) ;;
                      *) resp=$(create_instance "$pid" onDemand "$cluster");;
                    esac;;
                *) die "NOVITA_BILLING must be spot, onDemand or auto";;
            esac
            echo "   $pid -> $(printf '%s' "$resp" | head -c 100)"
            case "$resp" in *'"id"'*) echo CREATED; exit 0;; esac
            sleep 20
        done
        sleep 60
    done
    echo "no capacity after retries"; exit 1
}

# --- instance commands -------------------------------------------------------
do_start_compat() {  # old `start`: reuse our named instance if there is one
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
    do_menu
}

do_status() {
    id="${1:-}"
    if [ -z "$id" ]; then
        id=$(find_instance_id)
        if [ -z "$id" ]; then
            echo "no '$NAME' instance running."
            hr; echo "image from the prewarm list: ${IMAGE:-none}"
            echo "start it with: $0"
            return 1
        fi
    fi
    show_instance "$id"
    url=$(gui_url "$id"); [ -n "$url" ] && echo "  URL     : $url"
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
    id="${1:-}"
    [ -z "$id" ] && id=$(find_instance_id)
    [ -z "$id" ] && die "no '$NAME' instance; run '$0' first"
    tgt=$(ssh_target "$id"); [ -z "$tgt" ] && die "no SSH endpoint yet"
    host=${tgt%:*}; port=${tgt##*:}
    [ -x "$SSH_HELPER" ] && exec "$SSH_HELPER" "$id"
    exec ssh -i "$SSH_KEY" -p "$port" -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null "root@$host"
}

# --- dispatch ----------------------------------------------------------------
# Bare invocation opens the picker, like ppio.sh.
case "${1:-}" in
    "")        set -- menu ;;
    --wait)    set -- deploy-wait "${2:-$CLUSTER}" "${3:-$WANT}" ;;
    --status)  set -- instances ;;
esac

# resolved once, up front, for every command that needs it
IMAGE="$(resolve_image)"

case "${1:-}" in
    start)   do_start_compat;;

    menu)    do_menu;;

    launch)  do_launch "${2:-$CLUSTER}" "${3:-$WANT}";;

    clusters) show_clusters;;

    prewarm-list)
        echo "--- quota ---"
        api "$B/image/prewarm/quota" | fmt "
print('  used: %s of %s | perImageSize(GB): %s' % (d.get('total'),d.get('limit'),d.get('perImageSize')))"
        echo "--- tasks ---"
        api "$B/image/prewarm" | fmt "
print('  %-18s %-18s %-10s %-16s %s' % ('ID','CLUSTER','STATE','IMAGE','GB'))
for t in d.get('data', []):
    print('  %-18s %-18s %-10s %-16s %s' % (t.get('id'), t.get('clusterId'),
          t.get('state'), str(t.get('imageUrl','')).split(':')[-1],
          round(int(t.get('imageSize') or 0)/1e9, 1)))"
        ;;

    prewarm)
        img="${2:-$IMAGE}"; cluster="${3:-$CLUSTER}"
        body=$(python3 -c "
import json
print(json.dumps({'imageUrl':'$img','clusterId':'$cluster','note':'comfyui-h3-novita'}))")
        echo "prewarm image=$img cluster=$cluster"
        api -X POST -H "Content-Type: application/json" -d "$body" "$B/image/prewarm"; echo
        ;;

    products)
        filt="${2:-$WANT}"
        if [ -n "${NOVITA_PRODUCTS_CLUSTER:-}" ]; then
            api "$B/products?clusterId=$NOVITA_PRODUCTS_CLUSTER&gpuNum=1" | WANT="$filt" python3 -c "
import json,sys,os
want=os.environ['WANT']
for p in (d.get('data') or []):
    if want in str(p.get('name','')):
        print('  %-22s %-16s price=%-8s deploy=%s' % (p.get('id'), str(p.get('name'))[:16], p.get('price'), p.get('availableDeploy')))"
        else
            api "$B/products?gpuNum=1" | WANT="$filt" python3 -c "
import json,sys,os
want=os.environ['WANT']
for p in (d.get('data') or []):
    if want in str(p.get('name','')):
        print('  %-22s %-16s price=%-8s deploy=%-6s regions=%d' % (p.get('id'), str(p.get('name'))[:16],
              p.get('price'), p.get('availableDeploy'), len(p.get('regions') or [])))"
        fi
        ;;

    instances)
        api "$B/gpu/instances?pageSize=50&pageNum=1" | python3 -c "
import json,sys
d=json.load(sys.stdin); rows=d.get('instances') or []
if not rows: print('  (no instances)')
for i in rows:
    print('  %-26s %-10s %-18s %-9s %s' % (i.get('id'), str(i.get('status')),
          str(i.get('productName'))[:18], str(i.get('billingMode')), str(i.get('imageUrl'))[-24:]))
    for p in (i.get('portMappings') or []):
        if p.get('endpoint'): print('      %s/%s -> %s' % (p.get('port'),p.get('type'),p.get('endpoint')))"
        ;;

    deploy-wait) do_deploy_wait "${2:-$CLUSTER}" "${3:-$WANT}";;

    create)
        cluster="${2:-$CLUSTER}"; product="${3:-}"
        [ -z "$product" ] && product=$(pick_product "$cluster")
        [ -z "$product" ] && die "no deployable $WANT in $cluster; pass a productId"
        NAME="${5:-$NAME}"
        create_instance "$product" "$BILLING" "$cluster"
        echo
        ;;

    delete)
        id="${2:?instanceId}"
        api -X POST -H "Content-Type: application/json" -d "{\"instanceId\":\"$id\"}" \
            "$B/gpu/instance/delete"; echo
        ;;

    status)  do_status "${2:-}";;
    url)     do_url;;
    ssh)     do_ssh "${2:-}";;
    stop)    do_stop;;
    -h|--help|help) sed -n '2,41p' "$SELF"; exit 0;;
    *) echo "unknown command: $1" >&2; echo; sed -n '2,41p' "$SELF" >&2; exit 2;;
esac
