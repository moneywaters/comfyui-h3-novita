#!/bin/bash
# PPIO GPU-instance helper for the comfyui-h3-novita image.
# Mirrors ops/novita.sh, but PPIO's access is OAuth-via-MCP (see ppio_mcp.py) rather
# than an API key, because the supplied PPIO key is rejected with 401 "key not found".
#
# Running it with no arguments opens a dropdown menu of the locations that have a 4090,
# and launches a 4090 SPOT instance in whichever one you pick.
#
#   ./ppio.sh                                   pick a location, launch 4090 spot (default)
#   ./ppio.sh menu                              same, explicitly
#   ./ppio.sh --wait                            poll us-ca-6 for 4090 capacity, then launch
#   ./ppio.sh launch [cluster] [4090]           launch without the menu
#   ./ppio.sh clusters                          list clusters (and whether they have a 4090)
#   ./ppio.sh products [4090] [spot|onDemand|monthly]
#                                               products with stock + region count
#   ./ppio.sh prewarm-list                      prewarm tasks + quota
#   ./ppio.sh prewarm [image] [cluster] [pids]  create a prewarm task
#   ./ppio.sh prewarm-wait <taskId>             poll a prewarm task
#   ./ppio.sh instances                         list instances
#   ./ppio.sh deploy-wait [cluster] [4090]      poll for capacity, then create
#   ./ppio.sh create <cluster> <productId> [rootfs] [name]
#   ./ppio.sh status <instanceId>               instance status
#   ./ppio.sh ip <instanceId>                   ip + port mappings
#   ./ppio.sh delete <instanceId>               terminate an instance
#
# Override the defaults with PPIO_CLUSTER (default us-ca-6), PPIO_WANT (default 4090),
# PPIO_ROOTFS and PPIO_NAME.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
IMAGE="${IMAGE:-docker.io/moneywaters/comfyui-h3-novita:sha-289174e82568}"
CLUSTER="${PPIO_CLUSTER:-us-ca-6}"
WANT="${PPIO_WANT:-4090}"
ROOTFS="${PPIO_ROOTFS:-200}"
NAME="${PPIO_NAME:-seedhunter-ppio}"
# PPIO exposes these four 4090 SKUs under billingMethod=spot
SPOT_4090="4090.16c62g,4090.16c62g.os,4090.16c125g,4090.16c96g.v2"

# Bare invocation opens the picker; `--wait` polls for capacity first.
case "${1:-}" in
  "")           set -- menu ;;
  --wait)       set -- deploy-wait "${2:-$CLUSTER}" "${3:-$WANT}" ;;
  --status)     set -- instances ;;
esac

pp()  { python3 "$HERE/ppio_mcp.py" "$1"; }
fmt() { python3 -c "import json,sys;d=json.load(sys.stdin);$1"; }
# JSON-encode a shell value so it can be embedded safely in JS source
jsq() { python3 -c "import json,sys;print(json.dumps(sys.argv[1]))" "$1"; }

case "${1:-}" in

  clusters)
    pp '
async () => {
  const r = await api.request({method:"GET", path:"/openapi/v1/clusters", apiProduct:"gpu"});
  const rows = (r.data && r.data.data) || [];
  return rows.map(c => ({id:c.id, name:c.name, has4090:(c.availableGpuType||[]).some(t=>/4090/.test(t))}));
}' | fmt "
for c in d: print('  %-18s %-26s %s' % (c['id'], c['name'], '4090' if c['has4090'] else '-'))"
    ;;

  products)
    filt="${2:-4090}"; bm="${3:-spot}"
    FILT="$filt" BM="$bm" pp "
async () => {
  const r = await api.request({method:'GET', path:'/openapi/v1/products', apiProduct:'gpu',
                                query:{ billingMethod: $(jsq "$bm"), gpuNum: 1 }});
  const rows = (r.data && r.data.data) || [];
  return rows.filter(x => new RegExp($(jsq "$filt")).test(x.name||''))
             .map(x => ({id:x.id, name:x.name, price:x.price, deploy:x.availableDeploy, regions:(x.regions||[]).length}));
}" | fmt "
print('  billingMethod=%s' % '$bm')
if not d: print('  (none)')
for p in d: print('  %-22s %-16s price=%-8s deploy=%-6s regions=%d' % (p['id'],p['name'][:16],p['price'],p['deploy'],p['regions']))"
    ;;

  prewarm-list)
    echo "--- quota ---"
    pp 'async () => (await api.request({method:"GET",path:"/openapi/v1/image/prewarm/quota",apiProduct:"gpu"})).data' | fmt "
print('  used: %s of %s | perImageSize(GB): %s | policy: %s' % (d.get('total'),d.get('limit'),d.get('perImageSize'),d.get('policy')))"
    echo "--- tasks ---"
    pp '
async () => {
  const r = await api.request({method:"GET", path:"/openapi/v1/image/prewarm", apiProduct:"gpu"});
  const rows = (r.data && r.data.data) || [];
  return rows.map(x => ({id:x.id, cluster:x.clusterId, state:x.state||x.status,
                         image:(x.imageUrl||"").split(":").pop(), size:x.imageSize}));
}' | fmt "
print('  %-18s %-16s %-10s %-16s %s' % ('ID','CLUSTER','STATE','IMAGE','BYTES'))
for t in d: print('  %-18s %-16s %-10s %-16s %s' % (t['id'],t['cluster'],t['state'],t['image'],t['size']))"
    ;;

  prewarm)
    img="${2:-$IMAGE}"; cluster="${3:-$CLUSTER}"; pids="${4:-$SPOT_4090}"
    echo "prewarm image=$img cluster=$cluster"
    pp "
async () => {
  const body = {
    imageUrl: $(jsq "$img"), repositoryAuth: '', clusterId: $(jsq "$cluster"),
    productIds: $(jsq "$pids").split(',').filter(Boolean),
    note: 'comfyui-h3-novita',
  };
  const r = await api.request({method:'POST', path:'/openapi/v1/image/prewarm', apiProduct:'gpu', body});
  return r.data;
}"
    echo
    ;;

  prewarm-wait)
    id="${2:?taskId required}"; n=0
    while [ "$n" -lt 240 ]; do
      st=$(pp "
async () => {
  const r = await api.request({method:'GET', path:'/openapi/v1/image/prewarm', apiProduct:'gpu'});
  const rows = (r.data && r.data.data) || [];
  const t = rows.find(x => x.id === $(jsq "$id"));
  return t ? (t.state || t.status) : 'unknown';
}" 2>/dev/null | tr -d '\"')
      echo "[$n] task $id state=$st"
      case "$st" in Succeeded) echo "PREWARM DONE"; exit 0;; Failed) echo "PREWARM FAILED"; exit 1;; esac
      n=$((n+1)); sleep 20
    done
    echo timeout; exit 1
    ;;

  instances)
    pp '
async () => {
  const r = await api.request({method:"GET", path:"/openapi/v1/gpu/instances", apiProduct:"gpu",
                                query:{pageSize:50, pageNum:1}});
  const rows = (r.data && (r.data.instances || r.data.data)) || [];
  return rows.map(i => ({id:i.id, name:i.name, status:i.status||i.state, product:i.productName,
                         billing:i.billingMode, image:(i.imageUrl||"").slice(-24), ports:i.portMappings}));
}' | fmt "
if not d: print('  (no instances)')
for i in d:
    print('  %-26s %-10s %-18s %-9s %s' % (i['id'],str(i['status']),str(i['product']),str(i['billing']),i['image']))
    for p in (i.get('ports') or []):
        if p.get('endpoint'): print('      %s/%s -> %s' % (p.get('port'),p.get('type'),p.get('endpoint')))"
    ;;

  menu)
    echo "== checking which locations have a $WANT available ==" >&2
    # one MCP round trip: enumerate clusters, then check each for live capacity in JS.
    # Only clusters with something actually deployable are returned.
    items=$(pp "
async () => {
  const cl = await api.request({method:'GET', path:'/openapi/v1/clusters', apiProduct:'gpu'});
  const rows = (cl.data && cl.data.data) || [];
  const withGpu = rows.filter(c => (c.availableGpuType||[]).some(t => new RegExp($(jsq "$WANT")).test(t)));
  const out = [];
  for (const c of withGpu) {
    const p = await api.request({method:'GET', path:'/openapi/v1/products', apiProduct:'gpu',
                                  query:{ clusterId: c.id, gpuNum: 1 }});
    const pr = (p.data && p.data.data) || [];
    const live = pr.filter(x => new RegExp($(jsq "$WANT")).test(x.name||'') && x.availableDeploy);
    if (live.length) out.push({ id: c.id, name: c.name, deployable: live.map(x => x.id) });
  }
  out.sort((a,b) => b.deployable.length - a.deployable.length || a.id.localeCompare(b.id));
  return out;
}")
    if [ -z "$items" ] || [ "$items" = "[]" ]; then
      echo
      echo "No location currently has a $WANT available for deployment."
      echo "The prewarm is done, so a launch will be fast whenever capacity appears."
      echo "Poll for it with:  $0 --wait"
      exit 1
    fi
    menu_json=$(echo "$items" | python3 -c "
import json,sys
rows=json.load(sys.stdin)
out=[]
for r in rows:
    out.append({'id': r['id'],
                'cols': [r['id'], r['name'], '%d available' % len(r['deployable'])]})
print(json.dumps(out, ensure_ascii=False))
")
    pick=$(python3 "$HERE/ppio_pick.py" "$menu_json") || exit $?
    [ -z "$pick" ] && exit 1
    echo
    exec "$0" launch "$pick" "$WANT"
    ;;

  launch)
    cluster="${2:-$CLUSTER}"; want="${3:-$WANT}"
    echo "== launch: cluster=$cluster =="
    echo "   image: $IMAGE"
    CL="$cluster" IMG="$IMAGE" pp "
async () => {
  const r = await api.request({method:'GET', path:'/openapi/v1/image/prewarm', apiProduct:'gpu'});
  const rows = (r.data && r.data.data) || [];
  const t = rows.find(x => x.clusterId === $(jsq "$cluster") && x.imageUrl === $(jsq "$IMAGE"));
  return {state: t ? (t.state || t.status) : 'none'};
}" | fmt "print('   prewarm: %s' % d['state'])"
    echo "   deployable $want products in $cluster:"
    CL="$cluster" WANT="$want" pp "
async () => {
  const r = await api.request({method:'GET', path:'/openapi/v1/products', apiProduct:'gpu',
                                query:{ clusterId: $(jsq "$cluster"), gpuNum: 1 }});
  const rows = (r.data && r.data.data) || [];
  return rows.filter(x => new RegExp($(jsq "$want")).test(x.name||''))
             .map(x => ({id:x.id, deploy:x.availableDeploy}));
}" | fmt "
if not d: print('     (none)')
for p in d: print('     %-22s deploy=%s' % (p['id'], p['deploy']))" 2>/dev/null
    prod=$(CL="$cluster" WANT="$want" pp "
async () => {
  const r = await api.request({method:'GET', path:'/openapi/v1/products', apiProduct:'gpu',
                                query:{ clusterId: $(jsq "$cluster"), gpuNum: 1 }});
  const rows = (r.data && r.data.data) || [];
  const ok = rows.filter(x => new RegExp($(jsq "$want")).test(x.name||'') && x.availableDeploy);
  return ok.length ? ok[0].id : '';
}" 2>/dev/null | tr -d '\"')
    if [ -z "$prod" ]; then
      echo "   -> no $want deployable in $cluster right now"
      echo "   poll for capacity with: $0 deploy-wait $cluster $want"
      exit 1
    fi
    echo "   creating SPOT instance on $prod"
    out=$("$0" create "$cluster" "$prod" "$ROOTFS" "$NAME" 2>&1)
    echo "$out"
    case "$out" in
      *'"id"'*) ;;
      *) echo
         echo "   create refused (spot capacity is advertised then lost, as on Novita)."
         echo "   retry with: $0 deploy-wait $cluster $want"
         exit 1;;
    esac
    ;;

  deploy-wait)
    cluster="${2:-$CLUSTER}"; want="${3:-$WANT}"
    for i in $(seq 1 240); do
      prods=$(CL="$cluster" WANT="$want" pp "
async () => {
  const r = await api.request({method:'GET', path:'/openapi/v1/products', apiProduct:'gpu',
                                query:{ clusterId: $(jsq "$cluster"), gpuNum: 1 }});
  const rows = (r.data && r.data.data) || [];
  return rows.filter(x => new RegExp($(jsq "$want")).test(x.name||'') && x.availableDeploy).map(x => x.id);
}" 2>/dev/null | tr -d '[]\"' | tr ',' ' ')
      echo "[$(date +%H:%M:%S)] cycle $i deployable: ${prods:-none}"
      for pid in $prods; do
        resp=$("$0" create "$cluster" "$pid" "$ROOTFS" "$NAME" 2>&1)
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
    pp "
async () => {
  const body = {
    name: $(jsq "$name"), productId: $(jsq "$product"), gpuNum: 1,
    rootfsSize: parseInt($(jsq "$rootfs"), 10), imageUrl: $(jsq "$IMAGE"),
    ports: '22/tcp,8188/http', kind: 'gpu', clusterId: $(jsq "$cluster"),
    billingMode: 'spot', month: 0,
  };
  const r = await api.request({method:'POST', path:'/openapi/v1/gpu/instance/create', apiProduct:'gpu', body});
  return r.data;
}"
    echo
    ;;

  status)
    id="${2:?instanceId}"
    pp "
async () => (await api.request({method:'GET', path:'/openapi/v1/gpu/instance', apiProduct:'gpu',
                                query:{instanceId: $(jsq "$id")}})).data" | fmt "
print(json.dumps({k:d.get(k) for k in ('id','name','status','productName','billingMode','portMappings','rootfsSize','statusError') if k in d}, indent=1, ensure_ascii=False))"
    ;;

  ip)
    id="${2:?instanceId}"
    pp "
async () => (await api.request({method:'GET', path:'/openapi/v1/gpu/instance', apiProduct:'gpu',
                                query:{instanceId: $(jsq "$id")}})).data" | fmt "
print('  ipAddress :', d.get('ipAddress'))
print('  sshPort   :', d.get('sshPort'))
for p in (d.get('portMappings') or []):
    if p.get('endpoint'): print('  %s/%s -> %s' % (p.get('port'),p.get('type'),p.get('endpoint')))"
    ;;

  delete)
    # PPIO mirrors Novita here: the field is `instanceId`, and sending `id` fails validation.
    id="${2:?instanceId}"
    pp "
async () => (await api.request({method:'POST', path:'/openapi/v1/gpu/instance/delete', apiProduct:'gpu',
                                body:{instanceId: $(jsq "$id")}})).data"
    echo
    ;;

  help|-h|--help) sed -n '6,25p' "$0"; exit 0;;
  *) echo "unknown command: $1" >&2; echo; sed -n '6,25p' "$0" >&2; exit 2;;
esac
