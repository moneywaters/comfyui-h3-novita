#!/bin/bash
# Swap a PPIO GPU instance onto a newly-prewarmed image with as small a gap as possible.
#
# The problem this solves: you cannot keep the old instance while creating the new one
# (the cluster has a single 4090 free, and whoever asks first gets it). So the old one
# must be deleted — but if you do that by hand and then type the create command, you
# leave a window where someone else takes the card. This does delete and create
# back-to-back in one process, with every check done BEFORE the delete.
#
#   ./ppio-swap.sh [--cluster us-ca-6] [--image <ref>] [--cluster-only]
#
# Order of operations (all failure-prone steps happen before anything is destroyed):
#   1. resolve the image (default: --image, else the newest Succeeded prewarm)
#   2. confirm that prewarm is Succeeded for this cluster
#   3. note the current instance (a running one also proves a card is available here)
#   4. resolve the product id
#   5. DELETE, then CREATE immediately
#   6. wait for running, print endpoints
#
# If create fails after the delete, it says so loudly and prints the retry command; it
# never pretends the swap succeeded.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
API_KEY="${PPIO_API_KEY:-sk_YPyomQB6CJYriRsMrA_rZtAxiuaIAdsgiH8piQQmaqc}"
B="${PPIO_API_BASE:-https://api.ppio.com/gpu-instance/openapi/v1}"
CLUSTER="${PPIO_CLUSTER:-us-ca-6}"
WANT="${PPIO_WANT:-4090}"
BILLING="${PPIO_BILLING:-onDemand}"
ROOTFS="${PPIO_ROOTFS:-200}"
NAME="${PPIO_NAME:-seedhunter-ppio}"
IMAGE=""
DRY=0
AUTH=(-H "Authorization: Bearer ${API_KEY}" -H "Content-Type: application/json")

while [ $# -gt 0 ]; do
  case "$1" in
    --cluster) CLUSTER="$2"; shift 2;;
    --image)   IMAGE="$2";   shift 2;;
    --billing) BILLING="$2"; shift 2;;
    --name)    NAME="$2";    shift 2;;
    --dry-run) DRY=1;        shift;;
    -h|--help) sed -n '2,23p' "$SELF"; exit 0;;
    *) echo "unknown option: $1" >&2; exit 2;;
  esac
done

api() { curl -s --retry 3 --retry-all-errors --max-time 60 "${AUTH[@]}" "$@"; }
fmt() { python3 -c "import json,sys;d=json.load(sys.stdin);$1"; }
die() { echo "  !! $*" >&2; exit 1; }

echo "== ppio-swap: cluster=$CLUSTER billing=$BILLING =="
echo "-- 1. resolve image"
if [ -z "$IMAGE" ]; then
  IMAGE=$(api "$B/image/prewarm" | fmt "
ts=[t for t in d.get('data', []) if t.get('clusterId')=='$CLUSTER' and (t.get('state') or t.get('status'))=='Succeeded']
ts.sort(key=lambda t: int(t.get('createTime') or 0), reverse=True)
print(ts[0]['imageUrl'] if ts else '')")
  [ -z "$IMAGE" ] && die "no Succeeded prewarm for $CLUSTER; pass --image"
fi
echo "   image: $IMAGE"

echo "-- 2. prewarm state"
pw=$(api "$B/image/prewarm" | fmt "
ts=[t for t in d.get('data', []) if t.get('clusterId')=='$CLUSTER' and str(t.get('imageUrl'))=='$IMAGE']
print((ts[0].get('state') or ts[0].get('status')) if ts else 'none')")
echo "   prewarm: $pw"
[ "$pw" = "Succeeded" ] || die "prewarm is '$pw', not Succeeded — refusing to swap onto a cold image"

echo "-- 3. current instance"
allinst=$(api "$B/gpu/instances?pageSize=50&pageNum=1")
old=$(echo "$allinst" | fmt "
rows=d.get('instances') or d.get('data') or []
print(rows[0]['id'] if rows else '')")
oldimg=""
if [ -n "$old" ]; then
  oldimg=$(echo "$allinst" | fmt "
rows=d.get('instances') or d.get('data') or []
print(rows[0].get('imageUrl') or '')")
  echo "   $old  ($oldimg)"
  if [ "$oldimg" = "$IMAGE" ]; then
    echo "   already on the target image — nothing to do"
    exit 0
  fi
else
  echo "   (none running)"
fi

echo "-- 4. capacity"
# Careful: while OUR instance holds the card, /products reports nothing deployable --
# the capacity only appears once we delete it. So a running instance on this cluster is
# itself the evidence that a card can be had, and we must not treat that as "no
# capacity" or the swap could never run.
prod=$(api "$B/products?gpuNum=1&billingMethod=$BILLING&clusterId=$CLUSTER" | fmt "
rows=[p for p in (d.get('data') or []) if '$WANT' in str(p.get('name',''))]
live=[p['id'] for p in rows if p.get('availableDeploy')]
print(live[0] if live else (rows[0]['id'] if rows else ''))")
[ -z "$prod" ] && die "cluster $CLUSTER offers no $WANT product at all"
if [ -n "$old" ]; then
  echo "   product: $prod  (deployable flag is false because our own instance holds it;"
  echo "            it frees on delete, which is why delete+create happen back-to-back)"
else
  dep=$(api "$B/products?gpuNum=1&billingMethod=$BILLING&clusterId=$CLUSTER" | fmt "
rows=[p for p in (d.get('data') or []) if '$WANT' in str(p.get('name','')) and p.get('availableDeploy')]
print('yes' if rows else 'no')")
  [ "$dep" = "yes" ] || die "no $WANT deployable in $CLUSTER ($BILLING) right now — nothing was deleted"
  echo "   product: $prod (deployable)"
fi

if [ "$DRY" = "1" ]; then
  echo "-- 5. DRY RUN: would delete ${old:-<none>} and create on $prod with $IMAGE"
  echo "   (nothing was changed; drop --dry-run to do it)"
  exit 0
fi

echo "-- 5. delete + create (no gap)"
if [ -n "$old" ]; then
  api -X POST -d "{\"instanceId\":\"$old\"}" "$B/gpu/instance/delete" >/dev/null
  echo "   deleted $old"
fi

body=$(python3 -c "
import json
print(json.dumps({'name':'$NAME','productId':'$prod','gpuNum':1,'rootfsSize':int('$ROOTFS'),
                  'imageUrl':'$IMAGE','ports':'22/tcp,8188/http','kind':'gpu',
                  'clusterId':'$CLUSTER','billingMode':'$BILLING','month':0}))")
resp=$(api -X POST -d "$body" "$B/gpu/instance/create")
new=$(echo "$resp" | python3 -c "
import json,sys
try: print(json.load(sys.stdin).get('id',''))
except Exception: print('')")
if [ -z "$new" ]; then
  echo
  echo "  !! create FAILED after deleting $old:"
  echo "     $resp"
  echo "     the capacity was taken in the gap, or the cluster is full."
  echo "     retry with: $SELF --cluster $CLUSTER --image $IMAGE"
  exit 1
fi
echo "   created $new"

echo "-- 6. waiting for running"
for i in $(seq 1 90); do
  st=$(api "$B/gpu/instance?instanceId=$new" | fmt "print(d.get('status') or d.get('state') or '?')" 2>/dev/null)
  printf '\r   status: %-12s (%d)' "$st" "$i"
  case "$st" in
    running) echo; break;;
    failed|error) echo; die "instance went to '$st'";;
  esac
  sleep 10
done
echo
api "$B/gpu/instance?instanceId=$new" | fmt "
print('   image :', d.get('imageUrl'))
print('   billing:', d.get('billingMode'), '| product:', d.get('productName'))
for p in (d.get('portMappings') or []):
    if p.get('endpoint'): print('   %s/%s -> %s' % (p.get('port'),p.get('type'),p.get('endpoint')))"
