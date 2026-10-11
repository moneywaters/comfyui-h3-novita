#!/bin/bash
# Novita AI GPU-instance helper for the comfyui-h3-novita image.
#
#   ./novita.sh clusters                     list clusters
#   ./novita.sh products [4090|5090]         list products (spot price, stock, regions)
#   ./novita.sh balance                      account credit
#   ./novita.sh prewarm-list                 list prewarm tasks + quota
#   ./novita.sh prewarm <image> <cluster>    create a prewarm task
#   ./novita.sh prewarm-wait <taskId>        poll a prewarm task
#   ./novita.sh deploy-wait <cluster> [prod] poll for 4090 spot capacity and create
#   ./novita.sh instances                    list instances
#   ./novita.sh create <cluster> <productId> create a spot instance running the image
#   ./novita.sh status <instanceId>          instance status
#   ./novita.sh ip <instanceId>              public ip + port mappings
#   ./novita.sh delete <instanceId>          terminate an instance
set -uo pipefail

API_KEY="${NOVITA_API_KEY:-sk_-9UruuL5HS9S3lT0iStLtkFhTFxixkEd00zSPjI9tv8}"
B="https://api.novita.ai/gpu-instance/openapi/v1"
IMAGE="${IMAGE:-docker.io/moneywaters/comfyui-h3-novita:latest}"
AUTH=(-H "Authorization: Bearer ${API_KEY}" -H "Content-Type: application/json")

jqpy() { python3 -c "import json,sys;d=json.load(sys.stdin);$1"; }

case "${1:-}" in
  clusters)
    curl -s --max-time 30 "${AUTH[@]}" "$B/clusters" | jqpy "
for c in d['data']: print(' ', c['id'].ljust(18), c['name'].ljust(28), c.get('availableGpuType'))"
    ;;

  products)
    filt="${2:-4090}"
    curl -s --max-time 30 "${AUTH[@]}" "$B/products?gpuNum=1" | jqpy "
rows=d.get('data') or []
for p in rows:
    if '$filt' in str(p.get('name','')):
        print(' ', str(p.get('id')).ljust(20), str(p.get('name')).ljust(16),
              'spot:', p.get('spotPrice'), '| onDemand:', p.get('price'),
              '| inv:', p.get('inventoryState'), '|', p.get('regions'))"
    ;;

  prewarm-list)
    echo "--- quota ---"
    curl -s --max-time 25 "${AUTH[@]}" "$B/image/prewarm/quota" | jqpy "
print(' used:', d.get('total'), 'of', d.get('limit'), '| perImageSize(GB):', d.get('perImageSize'), '| policy:', d.get('policy'))"
    echo "--- tasks ---"
    curl -s --max-time 25 "${AUTH[@]}" "$B/image/prewarm" | jqpy "
for t in d.get('data', []): print(' ', t)"
    ;;

  prewarm)
    img="${2:-$IMAGE}"; cluster="${3:?clusterId required}"; prods="${4:-}"
    body=$(python3 -c "
import json,sys
b={'imageUrl':'$img','clusterId':'$cluster','note':'comfyui-h3-novita'}
if '$prods'.strip(): b['productIds']=[x for x in '$prods'.split(',') if x]
print(json.dumps(b))")
    echo "POST $body"
    curl -s --max-time 40 -X POST "${AUTH[@]}" -d "$body" "$B/image/prewarm"
    echo
    ;;

  prewarm-wait)
    id="${2:?taskId required}"; n=0
    while [ "$n" -lt 240 ]; do
      out=$(curl -s --max-time 25 "${AUTH[@]}" "$B/image/prewarm")
      st=$(echo "$out" | jqpy "
ts=[t for t in d.get('data',[]) if str(t.get('id'))=='$id']
print(ts[0].get('status') if ts else 'unknown')" 2>/dev/null)
      echo "[$n] task $id status=$st"
      case "$st" in success|finished|completed|done) echo "PREWARM DONE"; exit 0;; failed|error) echo "PREWARM FAILED"; exit 1;; esac
      n=$((n+1)); sleep 15
    done
    echo "timeout"; exit 1
    ;;

  balance)
    curl -s --max-time 25 "${AUTH[@]}" "https://api.novita.ai/openapi/v1/billing/balance/detail" | jqpy "
for k in ('availableBalance','cashBalance','creditLimit','outstandingInvoices'):
    v=d.get(k)
    if v is not None: print(f'  {k:22s} \${int(v)/10000:.2f}')"
    ;;

  deploy-wait)
    cluster="${2:?clusterId}"; want="${3:-4090}"
    for i in $(seq 1 240); do
      prods=$(curl -s --max-time 40 "${AUTH[@]}" "$B/products?clusterId=$cluster&gpuNum=1" | jqpy "
print(' '.join(p['id'] for p in (d.get('data') or []) if '$want' in str(p.get('name','')) and p.get('availableDeploy')))" 2>/dev/null)
      echo "[$(date +%H:%M:%S)] cycle $i deployable: ${prods:-none}"
      for pid in $prods; do
        resp=$(curl -s --max-time 90 -X POST "${AUTH[@]}" -d "{\"name\":\"h3-novita-test\",\"productId\":\"$pid\",\"gpuNum\":1,\"rootfsSize\":150,\"imageUrl\":\"$IMAGE\",\"ports\":\"22/tcp,8188/http\",\"kind\":\"gpu\",\"clusterId\":\"$cluster\",\"billingMode\":\"spot\",\"month\":0}" "$B/gpu/instance/create")
        echo "   $pid -> $resp"
        case "$resp" in *'"id"'*) echo "CREATED"; exit 0;; esac
        sleep 20
      done
      sleep 60
    done
    echo "no capacity after retries"; exit 1
    ;;

  instances)
    curl -s --max-time 30 "${AUTH[@]}" "$B/gpu/instances?pageSize=50&pageNum=1" | jqpy "
for i in d.get('instances', []):
    print(' ', i['id'].ljust(26), i.get('status').ljust(10), i.get('productName','').ljust(18),
          i.get('billingMode','').ljust(9), i.get('imageUrl','')[:60])"
    ;;

  create)
    cluster="${2:?clusterId}"; product="${3:?productId}"
    rootfs="${4:-200}"; name="${5:-h3-novita-test}"
    body=$(python3 -c "
import json
print(json.dumps({
  'name':'$name','productId':'$product','gpuNum':1,'rootfsSize':int('$rootfs'),
  'imageUrl':'$IMAGE','ports':'22/tcp,8188/http','kind':'gpu',
  'clusterId':'$cluster','billingMode':'spot','month':0,
  'envs':[{'key':'NOVITA_IMAGE','value':'comfyui-h3-novita'}]
}))")
    echo "POST $body"
    curl -s --max-time 40 -X POST "${AUTH[@]}" -d "$body" "$B/gpu/instance/create"
    echo
    ;;

  status)
    id="${2:?instanceId}"
    curl -s --max-time 25 "${AUTH[@]}" "$B/gpu/instances?pageSize=50&pageNum=1" | jqpy "
for i in d.get('instances', []):
    if i['id']=='$id':
        print(json.dumps({k:i.get(k) for k in ('id','status','productName','billingMode','spotStatus','portMappings','rootfsSize','statusError')}, indent=1))"
    ;;

  ip)
    id="${2:?instanceId}"
    curl -s --max-time 25 "${AUTH[@]}" "$B/gpu/instances?pageSize=50&pageNum=1" | jqpy "
for i in d.get('instances', []):
    if i['id']=='$id':
        print('ipAddress:', i.get('ipAddress'), '| ssh:', i.get('sshPort'), '| mappings:', i.get('portMappings'))
        print('all keys:', sorted(i.keys()))"
    ;;

  delete)
    # the API field is `instanceId`; sending `id` fails VALIDATOR
    # ("value length must be at least 1 runes") without deleting anything.
    id="${2:?instanceId}"
    curl -s --max-time 60 -X POST "${AUTH[@]}" -d "{\"instanceId\":\"$id\"}" "$B/gpu/instance/delete"; echo
    ;;

  *) sed -n '2,16p' "$0"; exit 1;;
esac
