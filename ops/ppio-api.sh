#!/bin/bash
# PPIO GPU-instance helper — direct REST API version (no MCP).
#
# Same commands as ops/ppio.sh, but talks to https://api.ppio.com/gpu-instance/openapi/v1
# with `Authorization: Bearer $PPIO_API_KEY` instead of going through PPIO's OAuth MCP
# server. Use this one when you have a working API key.
#
# Running it with no arguments opens a dropdown of the locations that have a 4090
# AVAILABLE right now, and launches a 4090 instance in whichever one you pick.
# On-demand is the default because spot never allocates on PPIO; override with
# PPIO_BILLING=spot if you want to try spot anyway.
#
#   ./ppio-api.sh                               pick a location, launch (default)
#   ./ppio-api.sh menu                          same, explicitly
#   ./ppio-api.sh --wait                        poll us-ca-6 for 4090, then launch
#   ./ppio-api.sh launch [cluster] [4090]       skip the menu
#   ./ppio-api.sh clusters                      clusters, flagging the ones with a 4090
#   ./ppio-api.sh products [4090] [spot|onDemand|monthly]
#   ./ppio-api.sh prewarm-list                  prewarm tasks + quota
#   ./ppio-api.sh prewarm [image] [cluster] [pids]
#   ./ppio-api.sh prewarm-wait <taskId>
#   ./ppio-api.sh instances
#   ./ppio-api.sh deploy-wait [cluster] [4090]  poll for capacity, then create
#   ./ppio-api.sh create <cluster> <productId> [rootfs] [name]
#   ./ppio-api.sh status <instanceId>
#   ./ppio-api.sh ip <instanceId>
#   ./ppio-api.sh delete <instanceId>
#
# Env: PPIO_API_KEY, IMAGE, PPIO_CLUSTER, PPIO_WANT, PPIO_ROOTFS, PPIO_NAME.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# absolute path to this script: "$0" may be a bare relative name like "ppio-api.sh"
# (e.g. `sh ppio-api.sh`), which exec would look up in PATH and miss
SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"

API_KEY="${PPIO_API_KEY:-sk_YPyomQB6CJYriRsMrA_rZtAxiuaIAdsgiH8piQQmaqc}"
B="${PPIO_API_BASE:-https://api.ppio.com/gpu-instance/openapi/v1}"
IMAGE="${IMAGE:-docker.io/moneywaters/comfyui-h3-novita:sha-cdb9137a0634}"
CLUSTER="${PPIO_CLUSTER:-us-ca-6}"
WANT="${PPIO_WANT:-4090}"
BILLING="${PPIO_BILLING:-onDemand}"
# Set PPIO_LIMIT_NODES=1 to start ComfyUI with --disable-all-custom-nodes plus a whitelist
# of ONLY the packs the Seed Hunter v2.5.1 workflow needs. Verified: 319 -> 185 extension
# scripts, all 53 workflow node types still resolve, no image rebuild required.
# NOTE: --whitelist-custom-nodes is argparse nargs='+' (SPACE separated). A comma-joined
# string becomes ONE bogus entry and ComfyUI then skips EVERY custom node.
LIMIT_NODES="${PPIO_LIMIT_NODES:-0}"
WHITELIST="${PPIO_WHITELIST:-bulk_io ComfyMath ComfyUI-BatchFolderTools ComfyUI-Easy-Use ComfyUI-Fantastic-MiniMaxH3-PromptBuilder ComfyUI-H3-Prompt-IDE ComfyUI-KJNodes ComfyUI-MiniMaxH3Mod ComfyUI-Pixaroma ComfyUI-SeedVR2_VideoUpscaler ComfyUI-VFI ComfyUI-VideoHelperSuite Comfyui_Minimax_h3_latent_Upscaler ControlAltAI-Nodes ComfyUI_MinimaxH3HybridLoader}"
ROOTFS="${PPIO_ROOTFS:-200}"
NAME="${PPIO_NAME:-seedhunter-ppio}"
# PPIO exposes these four 4090 SKUs under billingMethod=spot
SPOT_4090="4090.16c62g,4090.16c62g.os,4090.16c125g,4090.16c96g.v2"

AUTH=(-H "Authorization: Bearer ${API_KEY}" -H "Content-Type: application/json")
api()  { curl -s --retry 3 --retry-all-errors --max-time 60 "${AUTH[@]}" "$@"; }
fmt()  { python3 -c "import json,sys;d=json.load(sys.stdin);$1"; }
jsq()  { python3 -c "import json,sys;print(json.dumps(sys.argv[1]))" "$1"; }
warn_key() {
  case "$1" in
    *'"code":401'*|*UNAUTHORIZED*)
      echo "  !! PPIO rejected the API key (401). Check PPIO_API_KEY." >&2;;
  esac
}

# Bare invocation opens the picker; `--wait` polls for capacity first.
case "${1:-}" in
  "")       set -- menu ;;
  --wait)   set -- deploy-wait "${2:-$CLUSTER}" "${3:-$WANT}" ;;
  --status) set -- instances ;;
esac

case "${1:-}" in

  clusters)
    out=$(api "$B/clusters"); warn_key "$out"; echo "$out" | fmt "
for c in d.get('data', []):
    print('  %-18s %-26s %s' % (c['id'], c['name'],
          '4090' if any('4090' in t for t in (c.get('availableGpuType') or [])) else '-'))"
    ;;

  products)
    filt="${2:-4090}"; bm="${3:-spot}"
    out=$(api "$B/products?gpuNum=1&billingMethod=$bm"); warn_key "$out"; echo "$out" | fmt "
print('  billingMethod=$bm')
rows=[p for p in (d.get('data') or []) if '$filt' in str(p.get('name',''))]
if not rows: print('  (none)')
for p in rows:
    print('  %-22s %-16s price=%-8s deploy=%-6s regions=%d' % (p.get('id'), str(p.get('name'))[:16], p.get('price'), p.get('availableDeploy'), len(p.get('regions') or [])))"
    ;;

  prewarm-list)
    echo "--- quota ---"
    out=$(api "$B/image/prewarm/quota"); warn_key "$out"; echo "$out" | fmt "
print('  used: %s of %s | perImageSize(GB): %s | policy: %s' % (d.get('total'),d.get('limit'),d.get('perImageSize'),d.get('policy')))"
    echo "--- tasks ---"
    out=$(api "$B/image/prewarm"); warn_key "$out"; echo "$out" | fmt "
print('  %-18s %-16s %-10s %-16s %s' % ('ID','CLUSTER','STATE','IMAGE','BYTES'))
for t in d.get('data', []):
    print('  %-18s %-16s %-10s %-16s %s' % (t.get('id'), t.get('clusterId'), t.get('state') or t.get('status'), str(t.get('imageUrl','')).split(':')[-1], t.get('imageSize')))"
    ;;

  prewarm)
    img="${2:-$IMAGE}"; cluster="${3:-$CLUSTER}"; pids="${4:-$SPOT_4090}"
    body=$(python3 -c "
import json
print(json.dumps({'imageUrl':'$img','repositoryAuth':'','clusterId':'$cluster',
                  'productIds':[x for x in '$pids'.split(',') if x],'note':'comfyui-h3-novita'}))")
    echo "prewarm image=$img cluster=$cluster"
    out=$(api -X POST -d "$body" "$B/image/prewarm"); warn_key "$out"; echo "$out"; echo
    ;;

  prewarm-wait)
    id="${2:?taskId required}"; n=0
    while [ "$n" -lt 240 ]; do
      st=$(api "$B/image/prewarm" | fmt "
ts=[t for t in d.get('data',[]) if str(t.get('id'))=='$id']
print((ts[0].get('state') or ts[0].get('status')) if ts else 'unknown')" 2>/dev/null)
      echo "[$n] task $id state=$st"
      case "$st" in Succeeded) echo "PREWARM DONE"; exit 0;; Failed) echo "PREWARM FAILED"; exit 1;; esac
      n=$((n+1)); sleep 20
    done
    echo timeout; exit 1
    ;;

  instances)
    out=$(api "$B/gpu/instances?pageSize=50&pageNum=1"); warn_key "$out"; echo "$out" | fmt "
rows = d.get('instances') or d.get('data') or []
if not rows: print('  (no instances)')
for i in rows:
    print('  %-26s %-10s %-18s %-9s %s' % (i.get('id'), str(i.get('status') or i.get('state')),
          str(i.get('productName')), str(i.get('billingMode')), str(i.get('imageUrl'))[-24:]))
    for p in (i.get('portMappings') or []):
        if p.get('endpoint'): print('      %s/%s -> %s' % (p.get('port'),p.get('type'),p.get('endpoint')))"
    ;;

  menu)
    echo "== checking which locations have a $WANT available ==" >&2
    cl=$(api "$B/clusters"); warn_key "$cl"
    [ -z "$cl" ] && { echo "clusters request failed"; exit 1; }

    tmp=$(mktemp); names=$(mktemp); trap 'rm -f "$tmp" "$names"' EXIT

    # clusters that list this GPU, with display names
    echo "$cl" | fmt "
for c in d.get('data', []):
    if any('$WANT' in t for t in (c.get('availableGpuType') or [])):
        print('%s\t%s' % (c['id'], c['name']))
" > "$names"

    if [ ! -s "$names" ]; then echo "no cluster lists a $WANT"; exit 1; fi

    # check each of them for live capacity, in parallel
    cut -f1 "$names" | xargs -P 8 -I{} sh -c \
      'curl -s --retry 2 --retry-all-errors --max-time 45 \
         -H "Authorization: Bearer '"$API_KEY"'" \
         "'"$B"'/products?gpuNum=1&clusterId={}" | sed "s|^|{}|"' >> "$tmp" 2>/dev/null

    items=$(python3 - "$tmp" "$names" "$WANT" <<'PY'
import json, sys
raw, named, want = sys.argv[1], sys.argv[2], sys.argv[3]

names = {}
for line in open(named, encoding="utf-8"):
    cid, _, nm = line.rstrip("\n").partition("\t")
    if cid:
        names[cid] = nm

live = {}
for line in open(raw, encoding="utf-8", errors="replace"):
    cid, _, payload = line.partition("|")
    try:
        d = json.loads(payload)
    except Exception:
        continue
    ids = [p["id"] for p in (d.get("data") or [])
           if want in str(p.get("name", "")) and p.get("availableDeploy")]
    if ids:
        live[cid] = ids

out = [{"id": c, "cols": [c, names.get(c, ""), "%d available" % len(v)]}
       for c, v in live.items()]
out.sort(key=lambda r: (-int(r["cols"][2].split()[0]), r["id"]))
print(json.dumps(out, ensure_ascii=False))
PY
)
    if [ -z "$items" ] || [ "$items" = "[]" ]; then
      echo
      echo "No location currently has a $WANT available for $BILLING deployment."
      echo "The prewarm is done, so a launch will be fast whenever capacity appears."
      echo "Poll for it with:  $SELF --wait"
      exit 1
    fi
    pick=$(python3 "$HERE/ppio_pick.py" "$items") || exit $?
    [ -z "$pick" ] && exit 1
    echo
    exec "$SELF" launch "$pick" "$WANT"
    ;;

  launch)
    cluster="${2:-$CLUSTER}"; want="${3:-$WANT}"
    echo "== launch: cluster=$cluster =="
    echo "   image: $IMAGE"
    pw=$(api "$B/image/prewarm" | fmt "
ts=[t for t in d.get('data',[]) if t.get('clusterId')=='$cluster' and str(t.get('imageUrl'))=='$IMAGE']
print((ts[0].get('state') or ts[0].get('status')) if ts else 'none')" 2>/dev/null)
    echo "   prewarm: $pw"
    out=$(api "$B/products?gpuNum=1&billingMethod=$BILLING&clusterId=$cluster"); warn_key "$out"
    echo "   $want products in $cluster:"
    echo "$out" | fmt "
rows=[p for p in (d.get('data') or []) if '$want' in str(p.get('name',''))]
if not rows: print('     (none)')
for p in rows: print('     %-22s deploy=%s' % (p.get('id'), p.get('availableDeploy')))"
    prod=$(echo "$out" | fmt "
rows=[p for p in (d.get('data') or []) if '$want' in str(p.get('name','')) and p.get('availableDeploy')]
print(rows[0]['id'] if rows else '')" 2>/dev/null)
    if [ -z "$prod" ]; then
      echo "   -> no $want deployable in $cluster right now"
      echo "   poll for capacity with: $SELF deploy-wait $cluster $want"
      exit 1
    fi
    echo "   creating $BILLING instance on $prod"
    resp=$("$SELF" create "$cluster" "$prod" "$ROOTFS" "$NAME" 2>&1)
    echo "$resp"
    case "$resp" in
      *'"id"'*) ;;
      *) echo
         echo "   create refused (spot capacity is advertised then lost, as on Novita)."
         echo "   retry with: $SELF deploy-wait $cluster $want"
         exit 1;;
    esac
    ;;

  deploy-wait)
    cluster="${2:-$CLUSTER}"; want="${3:-$WANT}"
    for i in $(seq 1 240); do
      prods=$(api "$B/products?gpuNum=1&billingMethod=$BILLING&clusterId=$cluster" | fmt "
print(' '.join(p['id'] for p in (d.get('data') or [])
      if '$want' in str(p.get('name','')) and p.get('availableDeploy')))" 2>/dev/null)
      echo "[$(date +%H:%M:%S)] cycle $i deployable: ${prods:-none}"
      for pid in $prods; do
        resp=$("$SELF" create "$cluster" "$pid" "$ROOTFS" "$NAME" 2>&1)
        echo "   $pid -> $resp"
        case "$resp" in *'"id"'*) echo CREATED; exit 0;; esac
        sleep 20
      done
      sleep 60
    done
    echo "no capacity after retries"; exit 1
    ;;

  create)
    cluster="${2:-$CLUSTER}"; product="${3:?productId}"; rootfs="${4:-$ROOTFS}"; name="${5:-$NAME}"
    body=$(LIMIT_NODES="$LIMIT_NODES" WHITELIST="$WHITELIST" python3 - "$name" "$product" "$rootfs" "$IMAGE" "$cluster" "$BILLING" <<'BODYEOF'
import json, os, sys
name, product, rootfs, image, cluster, billing = sys.argv[1:7]
b = {"name": name, "productId": product, "gpuNum": 1, "rootfsSize": int(rootfs),
     "imageUrl": image, "ports": "22/tcp,8188/http", "kind": "gpu",
     "clusterId": cluster, "billingMode": billing, "month": 0}
if os.environ.get("LIMIT_NODES") == "1":
    # Overrides the image CMD (/opt/start.sh). ENTRYPOINT stays `tini --`, so signal
    # handling is kept; sshd is started explicitly because start.sh is bypassed. The SSH
    # key is already baked into the image's /root/.ssh/authorized_keys, so it still works.
    #
    # normalize-models.sh MUST run here: start.sh is what normally invokes it, and without
    # it Singularity keeps the "model.diffusion_model." prefix, which makes HybridLoader
    # refuse to merge ("the two checkpoints have different key sets"). It is idempotent and
    # costs milliseconds.
    # NOTE the grouping: "cd X && sshd &" would background the cd as well, leaving the
    # exec'd python in the wrong cwd. A plain "cd X;" keeps it in this shell; the & then
    # applies to sshd alone.
    inner = ("cd /opt/ComfyUI; /usr/sbin/sshd -D -e -f /etc/ssh/sshd_config & "
             "bash /opt/normalize-models.sh; "
             "exec /opt/comfyui-venv/bin/python3 main.py --listen 0.0.0.0 --port 8188 "
             "--preview-method auto --enable-compress-response-body "
             "--disable-all-custom-nodes --whitelist-custom-nodes "
             + os.environ["WHITELIST"])
    b["command"] = "/bin/bash -c " + json.dumps(inner)
print(json.dumps(b))
BODYEOF
)
    out=$(api -X POST -d "$body" "$B/gpu/instance/create"); warn_key "$out"; echo "$out"
    ;;

  status)
    id="${2:?instanceId}"
    out=$(api "$B/gpu/instance?instanceId=$id"); warn_key "$out"; echo "$out" | fmt "
print(json.dumps({k:d.get(k) for k in ('id','name','status','productName','billingMode','portMappings','rootfsSize','statusError') if k in d}, indent=1, ensure_ascii=False))"
    ;;

  ip)
    id="${2:?instanceId}"
    out=$(api "$B/gpu/instance?instanceId=$id"); warn_key "$out"; echo "$out" | fmt "
print('  ipAddress :', d.get('ipAddress'))
print('  sshPort   :', d.get('sshPort'))
for p in (d.get('portMappings') or []):
    if p.get('endpoint'): print('  %s/%s -> %s' % (p.get('port'),p.get('type'),p.get('endpoint')))"
    ;;

  delete)
    # PPIO mirrors Novita: the field is `instanceId`, and `id` fails validation.
    id="${2:?instanceId}"
    out=$(api -X POST -d "{\"instanceId\":\"$id\"}" "$B/gpu/instance/delete"); warn_key "$out"; echo "$out"; echo
    ;;

  help|-h|--help) sed -n '6,27p' "$SELF"; exit 0;;
  *) echo "unknown command: $1" >&2; echo; sed -n '6,27p' "$SELF" >&2; exit 2;;
esac
