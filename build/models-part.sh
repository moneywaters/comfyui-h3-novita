#!/bin/bash
# Download the model weights for one PART into /opt/ComfyUI/models.
# Invoked at image-build time by Dockerfile.models (baked into a layer).
set -uo pipefail

M="${COMFYUI_PATH:-/opt/ComfyUI}/models"
PART="${PART:?PART must be set}"
HF="${HF_TOKEN:-}"
CURL=/usr/bin/curl
FAILED=0

if [ -z "$HF" ]; then echo "ERROR: HF_TOKEN empty"; exit 1; fi

fetch() {  # <subdir> <filename> <url> <min-bytes>
    local subdir="$1" name="$2" url="$3" minbytes="${4:-1000000}"
    local dest="$M/$subdir/$name"
    if [ -f "$dest" ]; then
        local have; have=$(stat -c%s "$dest" 2>/dev/null || echo 0)
        if [ "$have" -ge "$minbytes" ]; then echo "  OK exists $subdir/$name"; return 0; fi
        rm -f "$dest"
    fi
    echo "  GET $subdir/$name"
    if "$CURL" --fail --location --silent --show-error \
            --retry 6 --retry-delay 5 --retry-all-errors --create-dirs \
            -H "Authorization: Bearer ${HF}" \
            -o "$dest.partial" "$url"; then
        local got; got=$(stat -c%s "$dest.partial" 2>/dev/null || echo 0)
        if [ "$got" -ge "$minbytes" ]; then
            mv -f "$dest.partial" "$dest"
            echo "  OK $subdir/$name ($((got/1048576)) MB)"
            return 0
        fi
        echo "  WARN truncated $name ($((got/1048576)) MB)"
        rm -f "$dest.partial"
    else
        echo "  WARN download failed $name"
        rm -f "$dest.partial"
    fi
    FAILED=$((FAILED+1)); return 1
}

H3=https://huggingface.co/Comfy-Org/MiniMax-H3/resolve/main
QW=https://huggingface.co/Comfy-Org/Qwen-Image-2.1/resolve/main
SV=https://huggingface.co/numz/SeedVR2_comfyUI/resolve/main

echo "=== PART=$PART ==="
case "$PART" in
  h3diff-fl2va)
    fetch diffusion_models minimax_h3_fl2va_pruned_int8_convrot.safetensors \
        "$H3/diffusion_models/minimax_h3_fl2va_pruned_int8_convrot.safetensors" 20000000000
    ;;
  h3diff-ref2va)
    fetch diffusion_models minimax_h3_ref2va_pruned_int8_convrot.safetensors \
        "$H3/diffusion_models/minimax_h3_ref2va_pruned_int8_convrot.safetensors" 20000000000
    ;;
  h3enc)
    fetch text_encoders qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors \
        "$H3/text_encoders/qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors" 15000000000
    ;;
  h3aux)
    fetch vae minimax_h3_video_vae_int8_convrot.safetensors \
        "$H3/vae/minimax_h3_video_vae_int8_convrot.safetensors" 2700000000
    fetch vae minimax_h3_video_vae_fp16.safetensors \
        "$H3/vae/minimax_h3_video_vae_fp16.safetensors" 5000000000
    fetch vae minimax_h3_audio_vae_fp32.safetensors \
        "$H3/vae/minimax_h3_audio_vae_fp32.safetensors" 500000000
    fetch loras minimax_h3_ref2v_turbo_4step_v0.1_comfyui_bf16.safetensors \
        "$H3/loras/minimax_h3_ref2v_turbo_4step_v0.1_comfyui_bf16.safetensors" 1800000000
    ;;
  seedvr2)
    fetch SEEDVR2 seedvr2_ema_3b_fp16.safetensors "$SV/seedvr2_ema_3b_fp16.safetensors" 6500000000
    fetch SEEDVR2 ema_vae_fp16.safetensors        "$SV/ema_vae_fp16.safetensors"        450000000
    ;;
  qwen-diff)
    fetch diffusion_models qwen_image_2.1_int8_convrot.safetensors \
        "$QW/diffusion_models/qwen_image_2.1_int8_convrot.safetensors" 7000000000
    ;;
  qwen-enc)
    fetch text_encoders qwen3vl_8b_int8_convrot.safetensors \
        "$QW/text_encoders/qwen3vl_8b_int8_convrot.safetensors" 9000000000
    fetch text_encoders qwen3.5_9b_qwen_image_2.1_pe_i2i.int8_convrot.safetensors \
        "$QW/text_encoders/qwen3.5_9b_qwen_image_2.1_pe_i2i.int8_convrot.safetensors" 9000000000
    fetch vae qwen_image_2.1_vae_bf16.safetensors \
        "$QW/vae/qwen_image_2.1_vae_bf16.safetensors" 600000000
    ;;
  *) echo "ERROR: unknown PART '$PART'"; exit 1;;
esac

echo "=== $PART tree ==="; du -sh "$M"/* 2>/dev/null | sort -rh | head
if [ "$FAILED" -gt 0 ]; then echo "ERROR: $FAILED download(s) failed"; exit 1; fi
echo "=== PART $PART complete ==="
