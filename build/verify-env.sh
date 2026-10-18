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
# Image A ships fl2va + Singularity + nvfp4 TE; the Comfy-Org ref2va and the int8 TE
# live in image B / upstream, so a loader pointing at them cannot run here. This
# regressed once when a stray file copy overwrote the fix, so assert it per workflow.
#
# Check LOADER VALUES only, via the parser: workflows also carry markdown notes that
# link to upstream models, and a plain grep for the name matches that text and
# reports a false failure (it did exactly that on the first run).
for WF in Minimax_Seed_Hunter_v2.5.1.json H3_CharSheet_6Panel.json H3_Cinematic_Multishot.json; do
WF_PATH="/opt/ComfyUI/user/default/workflows/$WF"
if [ ! -f "$WF_PATH" ]; then
    echo "  BAD $WF missing"; FAIL=$((FAIL+1))
    continue
fi
python3 - "$WF_PATH" "$WF" <<'PY' || FAIL=$((FAIL+1))
import json, sys

path, name = sys.argv[1], sys.argv[2]
BAD = {"minimax_h3_ref2va_pruned_int8_convrot.safetensors",
       "qwen3vl_32b_minimax_h3_int8_convrot.safetensors",
       "minimax_h3_hybrid_fl2va_ref2va_b30-49-int8.safetensors",
       "minimax_h3_turbo_v4_step600_ema.safetensors"}
WANT = {"minimax_h3_fl2va_pruned_int8_convrot.safetensors",
        "Minimax-h3_Singularity_ref2va_Pruned_v1.3_int8.safetensors",
        "qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors"}
FIELDS = ("unet_name", "vae_name", "clip_name", "lora_name", "tiny_vae",
          "base_model", "overlay_model")

wf = json.load(open(path))
vals, seen = [], set()

def walk(o, active=True):
    if isinstance(o, dict):
        if id(o) in seen:
            return
        seen.add(id(o))
        # muted/bypassed nodes (and nodes inside the bypassed speedup subgraph
        # instance) never execute, so their refs are inert
        if o.get("mode") == 4:
            return
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
bad = sorted({v for v in vals if v in BAD})
missing = sorted(m for m in WANT if m not in vals)

if bad:
    print("  BAD %s loads non-image model: %s" % (name, bad))
if missing:
    print("  BAD %s does not load: %s" % (name, missing))
if not bad and not missing:
    print("  OK  %s loaders resolve in-image (%d values)" % (name, len(set(vals))))
sys.exit(1 if (bad or missing) else 0)
PY
done

echo "=== JS/CSS cacheable ==="
CM=$(ls /opt/ComfyUI/middleware/cache_middleware.py 2>/dev/null | head -1)
if [ -z "$CM" ]; then
    echo "  BAD cache middleware missing"; FAIL=$((FAIL+1))
elif grep -q 'public, max-age=86400' "$CM"; then
    echo "  OK  core JS/CSS served cacheable"
else
    echo "  BAD core JS/CSS still no-store: every page load re-fetches ~690 modules"; FAIL=$((FAIL+1))
fi
PIXSR=$(ls /opt/ComfyUI/custom_nodes/*Pixaroma/server_routes.py 2>/dev/null | head -1)
if [ -n "$PIXSR" ]; then
    if grep -q 'public, max-age=86400' "$PIXSR"; then
        echo "  OK  Pixaroma modules cacheable (that pack is 419 of the script requests)"
    else
        echo "  BAD Pixaroma still forces no-store on its 419 modules"; FAIL=$((FAIL+1))
    fi
fi


echo "=== SeedVR2 bulk workflow ==="
# packs
for d in ComfyUI-BatchFolderTools ComfyMath ComfyUI-SeedVR2_VideoUpscaler bulk_io; do
    if [ -d "/opt/ComfyUI/custom_nodes/$d" ]; then
        echo "  OK  pack $d"
    else
        echo "  BAD pack $d missing"; FAIL=$((FAIL+1))
    fi
done
# our own pack must keep its web dir, or the buttons never render
if [ -f /opt/ComfyUI/custom_nodes/bulk_io/web/bulk_io.js ]; then
    echo "  OK  bulk_io web extension present"
else
    echo "  BAD bulk_io/web/bulk_io.js missing (no upload/download buttons)"; FAIL=$((FAIL+1))
fi
# cv2: BatchFolderTools' folder loader imports it
if "${VIRTUAL_ENV:-/opt/comfyui-venv}/bin/python3" -c "import cv2" 2>/dev/null; then
    echo "  OK  import cv2 (BatchFolderTools needs it)"
else
    echo "  BAD cv2 not importable"; FAIL=$((FAIL+1))
fi
# the §5 cache patch
SEEDCFG=/opt/ComfyUI/custom_nodes/ComfyUI-SeedVR2_VideoUpscaler/src/core/model_configuration.py
if [ -f "$SEEDCFG" ]; then
    # both the DiT and VAE branches use `if cached_model:` upstream, so assert that NO
    # bare truthiness test survives -- checking for a cached_vae one would never match.
    if grep -qE '^\s*if cached_model:\s*$' "$SEEDCFG"; then
        echo "  BAD SeedVR2 still has a bare 'if cached_model:' (2nd run dies on len())"; FAIL=$((FAIL+1))
    elif grep -q 'if cached_model is not None:' "$SEEDCFG"; then
        echo "  OK  SeedVR2 cache patch applied ($(grep -c 'if cached_model is not None:' "$SEEDCFG") site(s))"
    else
        echo "  BAD SeedVR2 cache patch not applied"; FAIL=$((FAIL+1))
    fi
fi
# the workflow itself
if [ -f "/opt/ComfyUI/user/default/workflows/Naxci1-SeedVR2.5-Auto-Manuel-BULK.json" ]; then
    echo "  OK  bulk workflow shipped"
else
    echo "  BAD bulk workflow missing"; FAIL=$((FAIL+1))
fi
# node classes each pack must contribute
for cls in BulkVideoUpload DownloadAllZip FolderVideoLoader_BFT QueueNext_BFT CM_IntToFloat CM_FloatToInt JoinStrings; do
    if grep -rqs --include='*.py' "\"$cls\"\|'$cls'" /opt/ComfyUI/custom_nodes; then
        echo "  OK  $cls"
    else
        echo "  BAD $cls not provided by any pack"; FAIL=$((FAIL+1))
    fi
done
# DVB must NOT be present: the bulk workflow replaces it and it pins numpy<2
if [ -d /opt/ComfyUI/custom_nodes/comfyui-dream-video-batches ]; then
    echo "  BAD comfyui-dream-video-batches present (pins numpy<2; must not ship)"; FAIL=$((FAIL+1))
else
    echo "  OK  comfyui-dream-video-batches absent"
fi


echo "=== request timing ==="
# Without this we are back to guessing which phase of a slow page load is at fault.
if [ -f /opt/ComfyUI/middleware/timing_middleware.py ]; then
    echo "  OK  timing_middleware.py present"
else
    echo "  BAD timing middleware missing (no way to diagnose a slow load)"; FAIL=$((FAIL+1))
fi
if grep -q 'request_timing, cache_control' /opt/ComfyUI/server.py 2>/dev/null; then
    echo "  OK  request_timing registered first in the middleware chain"
else
    echo "  BAD request_timing not registered in server.py"; FAIL=$((FAIL+1))
fi
if grep -q '"/debug/timing"' /opt/ComfyUI/server.py 2>/dev/null; then
    echo "  OK  /debug/timing route present"
else
    echo "  BAD /debug/timing route missing"; FAIL=$((FAIL+1))
fi


echo "=== bulk_io status visibility ==="
BJ=/opt/ComfyUI/custom_nodes/bulk_io/web/bulk_io.js
if [ -f "$BJ" ]; then
    # a plain text widget with disabled=true renders EMPTY in the current frontend, so the
    # status must be a DOM widget; without this the upload looks like it does nothing
    if grep -q 'addDOMWidget' "$BJ"; then
        echo "  OK  bulk_io status is visible (DOM widget)"
    else
        echo "  BAD bulk_io status not a DOM widget (uploads will appear to do nothing)"; FAIL=$((FAIL+1))
    fi
    if grep -q 'xhr.upload.onprogress' "$BJ"; then
        echo "  OK  bulk_io reports upload progress"
    else
        echo "  BAD no upload progress events"; FAIL=$((FAIL+1))
    fi
    if grep -q 'status.disabled' "$BJ"; then
        echo "  BAD bulk_io still uses a disabled text widget for status"; FAIL=$((FAIL+1))
    else
        echo "  OK  no disabled status widget"
    fi
else
    echo "  BAD bulk_io web extension missing"; FAIL=$((FAIL+1))
fi


echo "=== simplepod layering / chunked weights ==="
# SimplePod hosts will not unpack a ~21 GB layer (their console loops "Pulling image"
# forever while diskUsage stays 0.00). Models above the threshold must therefore ship as
# chunks, and the stitcher must be present to put them back.
if [ -x /opt/stitch-models.sh ] && [ -f /opt/stitch-models.py ]; then
    echo "  OK  stitcher present"
else
    echo "  BAD stitcher missing -- chunked weights would never be reassembled"; FAIL=$((FAIL+1))
fi
if grep -q 'stitch-models.sh' /opt/start.sh 2>/dev/null; then
    echo "  OK  start.sh reassembles chunked weights at boot"
else
    echo "  BAD start.sh does not reassemble chunked weights"; FAIL=$((FAIL+1))
fi

# Report the real layer-shape facts the build produced: any model file still present at
# over ~4 GB means chunking was skipped, which is the exact condition that fails on
# SimplePod. Printed as a warning rather than a hard failure because PPIO and Novita
# serve this image fine either way.
BIG=$(find /opt/ComfyUI/models -maxdepth 2 -type f \( -name '*.safetensors' -o -name '*.gguf' \) \
        -size +4G 2>/dev/null | head -20)
if [ -n "$BIG" ]; then
    echo "  WARN unchunked model file(s) over 4 GB (SimplePod may refuse to unpack):"
    echo "$BIG" | while read -r f; do printf '        %s\n' "$(basename "$f")"; done
else
    echo "  OK  no model file over 4 GB (SimplePod-safe layer shape)"
fi
CHUNKS=$(find /opt/ComfyUI/models -maxdepth 2 -type f -name '*.part[0-9][0-9][0-9]' 2>/dev/null | wc -l | tr -d ' ')
echo "  chunk files present: $CHUNKS"
if [ "$CHUNKS" -gt 0 ]; then
    if python3 /opt/stitch-models.py --models-dir /opt/ComfyUI/models --all --list 2>/dev/null | grep -q missing; then
        echo "  OK  at least one model needs stitching at boot (lazy path exercised)"
    else
        echo "  OK  all chunked models already stitched"
    fi
fi


echo "=== platform-aware weight sourcing ==="
# The image carries weights for PPIO/Novita, which prewarm it. SimplePod cannot unpack the
# big layers at all, so there it must fetch from Hugging Face instead. All four scripts
# below have to be present for that to work end to end.
for f in /opt/models-source.sh /opt/fetch-models-boot.sh /opt/models-part.sh /opt/chunk-model.sh; do
    if [ -x "$f" ]; then
        echo "  OK  $(basename "$f")"
    else
        echo "  BAD $f missing/not executable (weight sourcing broken)"; FAIL=$((FAIL+1))
    fi
done
# start.sh must consult the decision before it tries to stitch or normalise
if grep -q 'fetch-models-boot.sh' /opt/start.sh 2>/dev/null; then
    echo "  OK  start.sh provisions weights for the platform"
else
    echo "  BAD start.sh never calls fetch-models-boot.sh"; FAIL=$((FAIL+1))
fi
# chunking must be OFF by default so the runtime download path writes whole files
if grep -q 'CHUNK_MODELS:-0' /opt/models-part.sh 2>/dev/null; then
    echo "  OK  chunking gated to build time (CHUNK_MODELS defaults 0)"
else
    echo "  BAD models-part.sh would chunk runtime downloads (models would vanish)"; FAIL=$((FAIL+1))
fi
# and the resolved decision, so a boot log shows which way this image went
if [ -x /opt/models-source.sh ]; then
    printf '  resolved weights source: %s\n' "$(/opt/models-source.sh 2>/dev/null | tail -1)"
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
