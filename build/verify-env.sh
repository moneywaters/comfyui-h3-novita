#!/bin/bash
# Build-time verification for the env ("config UI") part.
set -uo pipefail
FAIL=0

echo "=== python ==="
"${VIRTUAL_ENV:-/opt/comfyui-venv}/bin/python3" - <<'PY' || FAIL=1
import importlib, sys
for m in ("torch","torchvision","comfy_kitchen","safetensors","transformers","aiohttp"):
    try:
        importlib.import_module(m); print("  OK  import", m)
    except Exception as e:
        print("  BAD import", m, e); sys.exit(1)
import torch
print("  torch", torch.__version__, "cuda", torch.version.cuda)
PY

echo "=== custom nodes ==="
n=$(find /opt/ComfyUI/custom_nodes -maxdepth 1 -mindepth 1 -type d | wc -l | tr -d ' ')
echo "  $n node directories"
[ "$n" -ge 15 ] || { echo "  BAD: too few custom nodes"; FAIL=$((FAIL+1)); }

# Each clone in nodes.sh is best-effort, so a pack can vanish silently (a rename or
# a dead URL) and only surface later as a red node in a user's workflow. Assert the
# classes the shipped workflows actually need are registered somewhere on disk.
echo "=== required node classes ==="
for cls in ThreeWaySwitch MiniMaxH3HybridLoader MinimaxH3LatentUpscalerNode2D ModelPreviewOverrideKJ; do
    if grep -rqs --include='*.py' "\"$cls\"\|'$cls'" /opt/ComfyUI/custom_nodes; then
        echo "  OK  $cls"
    elif grep -rqs --include='*.py' "\b$cls\b" /opt/ComfyUI/custom_nodes; then
        echo "  OK  $cls (unmapped ref)"
    else
        echo "  BAD $cls is not provided by any custom node pack"; FAIL=$((FAIL+1))
    fi
done

echo "=== workflows ==="
w=$(find /opt/ComfyUI/user/default/workflows -name '*.json' | wc -l | tr -d ' ')
echo "  $w workflow(s)"
for f in /opt/ComfyUI/user/default/workflows/*.json; do echo "    $(basename "$f")"; done
[ "$w" -ge 1 ] || { echo "  BAD: no workflows"; FAIL=$((FAIL+1)); }


echo "=== workflow model references ==="
WF=/opt/ComfyUI/user/default/workflows/Minimax_Seed_Hunter_v2.5.1.json
if [ ! -f "$WF" ]; then
    echo "  BAD v2.5.1 workflow missing"; FAIL=$((FAIL+1))
else
    # Image A ships fl2va + Singularity; the Comfy-Org ref2va lives in image B, so a
    # loader pointing at it cannot run here. This regressed once when a stray file copy
    # overwrote the fix, so assert it.
    #
    # Check LOADER VALUES only, via the parser: the workflow also carries a markdown
    # note that links to the ref2va model, and a plain grep for the name matches that
    # text and reports a false failure (it did exactly that on the first run).
    python3 - "$WF" <<'PY' || FAIL=$((FAIL+1))
import json, sys

BAD = "minimax_h3_ref2va_pruned_int8_convrot.safetensors"
WANT = ["minimax_h3_fl2va_pruned_int8_convrot.safetensors",
        "Minimax-h3_Singularity_ref2va_Pruned_v1.3_int8.safetensors"]
FIELDS = ("unet_name", "vae_name", "clip_name", "lora_name", "tiny_vae")

wf = json.load(open(sys.argv[1]))
vals, seen = [], set()

def walk(o):
    if isinstance(o, dict):
        if id(o) in seen:
            return
        seen.add(id(o))
        named = o.get("widgets_values_named") or {}
        for f in FIELDS:
            v = named.get(f)
            if isinstance(v, str):
                vals.append(v)
        arr = o.get("widgets_values")
        if isinstance(arr, list):
            vals.extend(x for x in arr if isinstance(x, str) and x.endswith(".safetensors"))
        for x in o.values():
            walk(x)
    elif isinstance(o, list):
        for x in o:
            walk(x)

walk(wf)
bad = sorted({v for v in vals if v == BAD})
missing = [m for m in WANT if m not in vals]

if bad:
    print("  BAD loader points at ref2va_org (image B's model): %s" % bad)
if missing:
    print("  BAD workflow does not load: %s" % missing)
if not bad and not missing:
    print("  OK  loaders use fl2va + Singularity (%d loader values checked)" % len(set(vals)))
sys.exit(1 if (bad or missing) else 0)
PY
fi

echo "=== JS/CSS cacheable ==="
CM=$(ls /opt/ComfyUI/middleware/cache_middleware.py 2>/dev/null | head -1)
if [ -z "$CM" ]; then
    echo "  BAD cache middleware missing"; FAIL=$((FAIL+1))
elif grep -q 'public, max-age=86400' "$CM"; then
    echo "  OK  JS/CSS served cacheable (repeat loads use the browser cache)"
else
    echo "  BAD JS/CSS still no-store: every page load re-fetches ~690 modules"; FAIL=$((FAIL+1))
fi

echo "=== sshd ==="
test -x /usr/sbin/sshd && echo "  OK sshd present" || { echo "  BAD sshd missing"; FAIL=$((FAIL+1)); }

echo "=== splash disabled ==="
SPLASH_HTML=$(ls /opt/comfyui-venv/lib/python*/site-packages/comfyui_frontend_package/static/index.html 2>/dev/null | head -1)
if [ -z "$SPLASH_HTML" ]; then
    echo "  BAD frontend index.html not found"; FAIL=$((FAIL+1))
elif grep -q '#splash-loader{display:none!important}' "$SPLASH_HTML"; then
    echo "  OK splash overlay disabled"
elif ! grep -q '#splash-loader' "$SPLASH_HTML"; then
    echo "  OK no splash overlay in this frontend build"
else
    echo "  BAD splash still enabled (a shell wrapper can keep the UI stuck on the logo)"; FAIL=$((FAIL+1))
fi

echo "=== ffmpeg ==="
ffmpeg -hide_banner -version 2>/dev/null | head -1 || { echo "  BAD ffmpeg missing"; FAIL=$((FAIL+1)); }

echo "=== model dirs ==="
mkdir -p /opt/ComfyUI/models/{diffusion_models,text_encoders,vae,loras,loras/MINIMAX,latent_upscale_models,vae_approx,SEEDVR2}
ls -d /opt/ComfyUI/models/*/ | sed 's/^/  /'

echo
if [ "$FAIL" -gt 0 ]; then echo "VERIFY-ENV FAILED ($FAIL)"; exit 1; fi
echo "VERIFY-ENV OK"
