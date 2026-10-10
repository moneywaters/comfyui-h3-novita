#!/bin/bash
# Download models INTO THE IMAGE at build time.
# Nothing large is ever pulled to the local machine.
# Resumable + strict size verification so a truncated file can never be baked in.
set -uo pipefail

M="${COMFYUI_PATH:-/opt/ComfyUI}/models"
HF="${HF_TOKEN:-}"
MODEL_SET="${MODEL_SET:-video}"

mkdir -p "$M"/{diffusion_models,text_encoders,vae,loras,SEEDVR2}

if [ -z "$HF" ]; then
    echo "ERROR: HF_TOKEN is empty — cannot fetch gated repos."
    exit 1
fi

FAILED=0
download() {  # <subdir> <filename> <url> <min-bytes>
    local subdir="$1" name="$2" url="$3" minbytes="${4:-1000000}"
    local dest="$M/$subdir/$name"
    mkdir -p "$M/$subdir"
    if [ -f "$dest" ]; then
        local have; have=$(stat -c%s "$dest" 2>/dev/null || echo 0)
        if [ "$have" -ge "$minbytes" ]; then
            echo "OK  exists: $subdir/$name ($((have/1048576)) MB)"
            return 0
        fi
        echo "WARN short ($((have/1048576)) MB) — re-downloading $name"
        rm -f "$dest"
    fi
    echo "GET $subdir/$name"
    if wget -q --header="Authorization: Bearer ${HF}" \
            --tries=4 --timeout=60 --read-timeout=120 --waitretry=5 \
            --progress=dot:giga -O "$dest.partial" "$url"; then
        local got; got=$(stat -c%s "$dest.partial" 2>/dev/null || echo 0)
        if [ "$got" -ge "$minbytes" ]; then
            mv -f "$dest.partial" "$dest"
            echo "OK  $subdir/$name ($((got/1048576)) MB)"
            return 0
        fi
        echo "WARN truncated: $name ($((got/1048576)) MB)"
        rm -f "$dest.partial"
    else
        rm -f "$dest.partial"
        echo "WARN download failed: $name"
    fi
    FAILED=$((FAILED+1))
    return 1
}

H3=https://huggingface.co/Comfy-Org/MiniMax-H3/resolve/main
QW=https://huggingface.co/Comfy-Org/Qwen-Image-2.1/resolve/main
SV=https://huggingface.co/numz/SeedVR2_comfyUI/resolve/main

# =========================== MiniMax H3 (video generation) ===================
# ref2va = reference-to-video+audio (what the Seed Hunter workflow uses)
download diffusion_models minimax_h3_ref2va_pruned_int8_convrot.safetensors \
    "$H3/diffusion_models/minimax_h3_ref2va_pruned_int8_convrot.safetensors" 20000000000
download text_encoders qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors \
    "$H3/text_encoders/qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors" 15000000000
download vae minimax_h3_video_vae_fp16.safetensors \
    "$H3/vae/minimax_h3_video_vae_fp16.safetensors" 5000000000
download vae minimax_h3_audio_vae_fp32.safetensors \
    "$H3/vae/minimax_h3_audio_vae_fp32.safetensors" 500000000
download loras minimax_h3_ref2v_turbo_4step_v0.1_comfyui_bf16.safetensors \
    "$H3/loras/minimax_h3_ref2v_turbo_4step_v0.1_comfyui_bf16.safetensors" 1800000000

# =========================== SeedVR2 (final upscale) =========================
download SEEDVR2 seedvr2_ema_3b_fp16.safetensors "$SV/seedvr2_ema_3b_fp16.safetensors" 6500000000
download SEEDVR2 ema_vae_fp16.safetensors        "$SV/ema_vae_fp16.safetensors"        450000000

# =========================== Qwen-Image 2.1 (image editing) ==================
if [ "$MODEL_SET" = "all" ]; then
    download diffusion_models qwen_image_2.1_int8_convrot.safetensors \
        "$QW/diffusion_models/qwen_image_2.1_int8_convrot.safetensors" 7000000000
    download text_encoders qwen3vl_8b_int8_convrot.safetensors \
        "$QW/text_encoders/qwen3vl_8b_int8_convrot.safetensors" 9000000000
    download text_encoders qwen3.5_9b_qwen_image_2.1_pe_i2i.int8_convrot.safetensors \
        "$QW/text_encoders/qwen3.5_9b_qwen_image_2.1_pe_i2i.int8_convrot.safetensors" 9000000000
    download vae qwen_image_2.1_vae_bf16.safetensors \
        "$QW/vae/qwen_image_2.1_vae_bf16.safetensors" 600000000
fi

echo "=== model tree ==="
du -sh "$M"/* 2>/dev/null | sort -rh
echo "=== total ==="
du -sh "$M" 2>/dev/null

if [ "$FAILED" -gt 0 ]; then
    echo "ERROR: $FAILED model(s) failed to download"
    exit 1
fi
echo "=== all models baked in ==="
