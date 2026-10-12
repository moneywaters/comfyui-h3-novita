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
    # image A ships fl2va + Singularity; the Comfy-Org ref2va lives in image B, so a
    # workflow referencing it cannot run here. This has silently-ish regressed before
    # (a stray file copy overwrote a fix), so assert it.
    if grep -q 'minimax_h3_ref2va_pruned_int8_convrot.safetensors' "$WF"; then
        echo "  BAD workflow references ref2va_org, which is NOT in this image"
        FAIL=$((FAIL+1))
    else
        echo "  OK  no ref2va_org reference"
    fi
    grep -q 'minimax_h3_fl2va_pruned_int8_convrot.safetensors' "$WF" \
        && echo "  OK  references fl2va (present)" \
        || { echo "  BAD workflow does not reference fl2va"; FAIL=$((FAIL+1)); }
    grep -q 'Minimax-h3_Singularity_ref2va_Pruned_v1.3_int8.safetensors' "$WF" \
        && echo "  OK  references Singularity (present)" \
        || echo "  WARN no Singularity reference"
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
