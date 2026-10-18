#!/bin/bash
# Download the model weights for ONE part into /opt/ComfyUI/models.
# Invoked at image-build time by Dockerfile.models (baked into a layer).
#
# Two images are composed from these parts (see .github/workflows/build.yml):
#   A  comfyui-h3-novita    ~86 GB  H3 video generation
#   B  comfyui-qwen-novita  ~49 GB  Qwen 2.1 image editing + the spare H3 variants
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
    mkdir -p "$M/$subdir"
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
KJ=https://huggingface.co/Kijai/MiniMax-H3-experimental/resolve/main
KJTAE=https://huggingface.co/Kijai/MiniMax-H3-TAE/resolve/main
SING=https://huggingface.co/WarmBloodAban/Minimax-h3_Singularity/resolve/main
SILV=https://huggingface.co/silveroxides/MiniMax-H3_tests/resolve/main
LBH=https://huggingface.co/LBH-123-AI/Minimax_h3_latent_Upscaler/resolve/main
T8VG=https://huggingface.co/t8star/Qwen-Image-2.1-viggle-turbo-4step-r64-comfy/resolve/main
T8PR=https://huggingface.co/t8star/Pruna-Qwen-Image-2.1-Comfy/resolve/main

echo "=== PART=$PART ==="
case "$PART" in

  # ---------------- image A: MiniMax H3 video generation ---------------------
  h3-fl2va)
    fetch diffusion_models minimax_h3_fl2va_pruned_int8_convrot.safetensors \
        "$H3/diffusion_models/minimax_h3_fl2va_pruned_int8_convrot.safetensors" 20000000000
    ;;
  h3-singularity)
    # the ref2va model Seed Hunter v2.5.1's UNETLoader points at
    fetch diffusion_models Minimax-h3_Singularity_ref2va_Pruned_v1.3_int8.safetensors \
        "$SING/Minimax-h3_Singularity_ref2va_Pruned_v1.3_int8.safetensors" 20000000000
    ;;
  h3enc)
    fetch text_encoders qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors \
        "$H3/text_encoders/qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors" 15000000000
    ;;
  h3vae-kijai)
    # Kijai's int8 convrot video VAE — the one the workflow uses (much faster)
    fetch vae minimax_h3_video_vae_int8_convrot.safetensors \
        "$KJ/minimax_h3_video_vae_int8_convrot.safetensors" 3000000000
    ;;
  h3vae-fp16)
    fetch vae minimax_h3_video_vae_fp16.safetensors \
        "$H3/vae/minimax_h3_video_vae_fp16.safetensors" 5000000000
    ;;
  h3vae-audio)
    fetch vae minimax_h3_audio_vae_fp32.safetensors \
        "$H3/vae/minimax_h3_audio_vae_fp32.safetensors" 500000000
    ;;
  h3loras)
    # Kijai's DMAD 4-step (the workflow's recommended turbo LoRA)
    fetch loras/MINIMAX minimax_h3_DMAD_4step_full_lora_avg_rank_39_bf16.safetensors \
        "$KJ/loras/minimax_h3_DMAD_4step_full_lora_avg_rank_39_bf16.safetensors" 350000000
    # silveroxides dareties — both fro levels linked by the workflow/Civitai page
    fetch loras minimax_h3_fl2v_turbo_silver_dareties_comfy_pruned_v1.safetensors \
        "$SILV/minimax_h3_fl2v_turbo_silver_dareties_comfy_pruned_v1.safetensors" 750000000
    fetch loras minimax_h3_ref2v_turbo_4step_v0.1_v4_step600_dareties_fro0975.safetensors \
        "$SILV/ref2v_dareties/minimax_h3_ref2v_turbo_4step_v0.1_v4_step600_dareties_fro0975.safetensors" 690000000
    fetch loras minimax_h3_ref2v_turbo_4step_v0.1_v4_step600_dareties_fro0995.safetensors \
        "$SILV/ref2v_dareties/minimax_h3_ref2v_turbo_4step_v0.1_v4_step600_dareties_fro0995.safetensors" 1100000000
    ;;
  h3extra)
    # neural latent upscaler used by the v2.5.1 upscale pass
    fetch latent_upscale_models minimax_h3_latent_upscaler_3d_conv_v1_fp16.safetensors \
        "$LBH/minimax_h3_latent_upscaler_3d_conv_v1/minimax_h3_latent_upscaler_3d_conv_v1_fp16.safetensors" 680000000
    # TaeH3 tiny VAE for Kijai's Model Preview Override
    fetch vae_approx taeh3.safetensors "$KJTAE/vae_approx/taeh3.safetensors" 9000000
    ;;
  seedvr2)
    fetch SEEDVR2 seedvr2_ema_3b_fp16.safetensors "$SV/seedvr2_ema_3b_fp16.safetensors" 6500000000
    fetch SEEDVR2 ema_vae_fp16.safetensors        "$SV/ema_vae_fp16.safetensors"        450000000
    ;;

  # ---------------- image B: Qwen 2.1 + spare H3 variants -------------------
  qwen-diff)
    fetch diffusion_models qwen_image_2.1_int8_convrot.safetensors \
        "$QW/diffusion_models/qwen_image_2.1_int8_convrot.safetensors" 7000000000
    ;;
  qwen-enc)
    fetch text_encoders qwen3vl_8b_int8_convrot.safetensors \
        "$QW/text_encoders/qwen3vl_8b_int8_convrot.safetensors" 9000000000
    ;;
  qwen-vae)
    fetch vae qwen_image_2.1_vae_bf16.safetensors \
        "$QW/vae/qwen_image_2.1_vae_bf16.safetensors" 600000000
    ;;
  qwen-loras)
    # keep the workflow's exact "-t8" filenames so ComfyUI validation passes
    fetch loras qwen_image_2.1_viggle_turbo_v0.2.1_r256_comfy-t8.safetensors \
        "$T8VG/qwen_image_2.1_viggle_turbo_v0.2.1_r256_comfy.safetensors" 1700000000
    fetch loras p_qwen_image_2.1_8step_v0.1-comfyui-T8.safetensors \
        "$T8PR/p_qwen_image_2.1_8step_v0.1-comfyui-T8.safetensors" 300000000
    ;;
  h3-ref2va-org)
    # the stock Comfy-Org ref2va (kept alongside Singularity, lives in image B)
    fetch diffusion_models minimax_h3_ref2va_pruned_int8_convrot.safetensors \
        "$H3/diffusion_models/minimax_h3_ref2va_pruned_int8_convrot.safetensors" 20000000000
    ;;

  *) echo "ERROR: unknown PART '$PART'"; exit 1;;
esac

# Split oversized weights into sub-4 GB chunks. SimplePod hosts will not unpack a
# ~21 GB layer (their console loops "Pulling image" forever, diskUsage never moves),
# while PPIO and Novita pull this image fine. Chunking shrinks the largest layer
# without changing what the model contains; build/stitch-models.py puts it back at
# boot, lazily, so the platforms that already work pay nothing.
# Chunk only at IMAGE BUILD time (Dockerfile.models sets CHUNK_MODELS=1).
#
# At runtime -- SimplePod's boot download via fetch-models-boot.sh -- the files must stay
# whole: ComfyUI loads them by name, and that path has no stitch step, so splitting here
# would leave every model invisible. Defaulting to 0 makes the runtime path correct without
# it having to know about this at all.
if [ "${CHUNK_MODELS:-0}" = "1" ] && [ -x /opt/chunk-model.sh ]; then
    shopt -s nullglob
    for f in "$M"/diffusion_models/*.safetensors "$M"/text_encoders/*.safetensors \
             "$M"/vae/*.safetensors "$M"/SEEDVR2/*.safetensors; do
        [ -f "$f" ] || continue
        bash /opt/chunk-model.sh "$f" 3500 | sed 's/^/  /'
    done
    shopt -u nullglob
fi

echo "=== $PART tree ==="; du -sh "$M"/* 2>/dev/null | sort -rh | head
if [ "$FAILED" -gt 0 ]; then echo "ERROR: $FAILED download(s) failed"; exit 1; fi
echo "=== PART $PART complete ==="
