#!/bin/bash
# Build-time verification: fail the build if the baked image is incomplete.
set -uo pipefail
M="${COMFYUI_PATH:-/opt/ComfyUI}/models"
FAIL=0

check_min() {  # <path> <min-bytes> <label>
    local p="$1" min="$2" label="$3"
    if [ -f "$p" ]; then
        local s; s=$(stat -c%s "$p" 2>/dev/null || echo 0)
        if [ "$s" -ge "$min" ]; then
            printf '  OK  %-58s %6s MB\n' "$label" "$((s/1048576))"
        else
            printf '  BAD %-58s %6s MB (min %s)\n' "$label" "$((s/1048576))" "$((min/1048576))"; FAIL=$((FAIL+1))
        fi
    else
        printf '  MISSING %s\n' "$label"; FAIL=$((FAIL+1))
    fi
}

echo "=== models ==="
check_min "$M/diffusion_models/minimax_h3_ref2va_pruned_int8_convrot.safetensors" 20000000000 "H3 ref2va pruned int8"
check_min "$M/text_encoders/qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors"         15000000000 "H3 qwen3vl 32b nvfp4 TE"
check_min "$M/vae/minimax_h3_video_vae_fp16.safetensors"                            5000000000 "H3 video VAE fp16"
check_min "$M/SEEDVR2/seedvr2_ema_3b_fp16.safetensors"                              6500000000 "SeedVR2 3B fp16"
check_min "$M/SEEDVR2/ema_vae_fp16.safetensors"                                      450000000 "SeedVR2 VAE"

echo "=== python ==="
"${VIRTUAL_ENV:-/opt/comfyui-venv}/bin/python3" - <<'PY' || FAIL=$((FAIL+1))
import importlib, sys
for m in ("torch","torchvision","comfy_kitchen","safetensors","transformers"):
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
echo "  $w workflow(s)"; for f in /opt/ComfyUI/user/default/workflows/*.json; do echo "    $(basename "$f")"; done
[ "$w" -ge 1 ] || { echo "  BAD: no workflows"; FAIL=$((FAIL+1)); }

echo "=== sshd ==="
test -x /usr/sbin/sshd && echo "  OK sshd present" || { echo "  BAD sshd missing"; FAIL=$((FAIL+1)); }

echo
if [ "$FAIL" -gt 0 ]; then echo "VERIFY FAILED ($FAIL problem(s))"; exit 1; fi
echo "VERIFY OK"
