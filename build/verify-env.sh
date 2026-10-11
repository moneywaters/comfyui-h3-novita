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

echo "=== workflows ==="
w=$(find /opt/ComfyUI/user/default/workflows -name '*.json' | wc -l | tr -d ' ')
echo "  $w workflow(s)"
for f in /opt/ComfyUI/user/default/workflows/*.json; do echo "    $(basename "$f")"; done
[ "$w" -ge 1 ] || { echo "  BAD: no workflows"; FAIL=$((FAIL+1)); }

echo "=== sshd ==="
test -x /usr/sbin/sshd && echo "  OK sshd present" || { echo "  BAD sshd missing"; FAIL=$((FAIL+1)); }

echo "=== ffmpeg ==="
ffmpeg -hide_banner -version 2>/dev/null | head -1 || { echo "  BAD ffmpeg missing"; FAIL=$((FAIL+1)); }

echo "=== model dirs ==="
mkdir -p /opt/ComfyUI/models/{diffusion_models,text_encoders,vae,loras,loras/MINIMAX,latent_upscale_models,vae_approx,SEEDVR2}
ls -d /opt/ComfyUI/models/*/ | sed 's/^/  /'

echo
if [ "$FAIL" -gt 0 ]; then echo "VERIFY-ENV FAILED ($FAIL)"; exit 1; fi
echo "VERIFY-ENV OK"
