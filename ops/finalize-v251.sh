#!/bin/bash
# Put the freshly downloaded v2.5.1 models into the layout link-models.sh expects,
# then (re)create the symlinks. Safe to re-run.
#
# Two files need placing by hand because the workflow addresses them by subfolder
# or the upstream repo keeps them in a non-category directory:
#   * DMAD LoRA   -> referenced as "MINIMAX\<name>"  => loras/MINIMAX/
#   * fro0995     -> upstream path is ref2v_dareties/ which is not a model category
set -u

HDD=/mnt/data/comfy-models/models
MODELS="$HOME/ComfyUI/models"
LOG="$HOME/v251-finalize.log"
log() { printf '%s %s\n' "$(date -Is)" "$*" | tee -a "$LOG"; }

log "=== finalize v2.5.1 models ==="

# 1. DMAD LoRA -> loras/MINIMAX/ so the "MINIMAX\<name>" reference resolves
dmad_src="$HDD/Kijai--MiniMax-H3-experimental/snapshots/master/loras/minimax_h3_DMAD_4step_full_lora_avg_rank_39_bf16.safetensors"
dmad_dst="$HDD/Kijai--MiniMax-H3-experimental/snapshots/master/loras/MINIMAX/minimax_h3_DMAD_4step_full_lora_avg_rank_39_bf16.safetensors"
if [ -f "$dmad_src" ] && [ ! -f "$dmad_dst" ]; then
    mkdir -p "$(dirname "$dmad_dst")"
    if mv -f "$dmad_src" "$dmad_dst"; then
        log "moved DMAD into loras/MINIMAX/"
        rm -f "$MODELS/loras/minimax_h3_DMAD_4step_full_lora_avg_rank_39_bf16.safetensors"
    fi
fi

# 2. fro0995 -> loras/ (its upstream dir ref2v_dareties is not a category)
f_src="$HDD/silveroxides--MiniMax-H3_tests/snapshots/master/ref2v_dareties/minimax_h3_ref2v_turbo_4step_v0.1_v4_step600_dareties_fro0995.safetensors"
f_dst="$HDD/silveroxides--MiniMax-H3_tests/snapshots/master/loras/minimax_h3_ref2v_turbo_4step_v0.1_v4_step600_dareties_fro0995.safetensors"
if [ -f "$f_src" ] && [ ! -f "$f_dst" ]; then
    mkdir -p "$(dirname "$f_dst")"
    mv -f "$f_src" "$f_dst" && log "moved fro0995 into loras/"
fi

# 3. rebuild every symlink
log "--- link-models.sh ---"
"$HOME/bin/link-models.sh" link 2>&1 | tail -12 | tee -a "$LOG"

# 4. verify the model files the (remapped) workflow needs
log "--- verify ---"
rc=0
# --- files that had to be fetched -------------------------------------------
for f in \
  "diffusion_models/minimax_h3_ref2va_pruned_int8_convrot.safetensors" \
  "vae/minimax_h3_video_vae_int8_convrot.safetensors" \
  "loras/minimax_h3_ref2v_turbo_4step_v0.1_v4_step600_dareties_fro0995.safetensors" \
  "loras/MINIMAX/minimax_h3_DMAD_4step_full_lora_avg_rank_39_bf16.safetensors" \
  "vae_approx/taeh3.safetensors" ; do
    p="$MODELS/$f"
    if [ -e "$p" ]; then
        log "  OK      $(du -hL "$p" 2>/dev/null | cut -f1)  $f"
    elif [ -L "$p" ]; then
        log "  DANGLING $f"; rc=1
    else
        log "  MISSING  $f"; rc=1
    fi
done
# --- pre-existing files the workflow also loads ------------------------------
for f in \
  "text_encoders/qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors" \
  "vae/minimax_h3_video_vae_fp16.safetensors" \
  "vae/minimax_h3_audio_vae_fp32.safetensors" \
  "latent_upscale_models/minimax_h3_latent_upscaler_3d_conv_v1_fp16.safetensors" \
  "loras/minimax_h3_fl2v_turbo_silver_dareties_comfy_pruned_v1.safetensors" ; do
    p="$MODELS/$f"
    if [ -e "$p" ]; then log "  OK      (pre-existing) $f"; else log "  MISSING (pre-existing) $f"; rc=1; fi
done

log "note: the workflow was remapped onto the existing ref2va;"
log "      'Singularity ref2va' and 'fl2va' both now point at"
log "      minimax_h3_ref2va_pruned_int8_convrot.safetensors"

[ $rc -eq 0 ] && log "=== all v2.5.1 model files present ===" || log "=== some files still missing ==="
log "free space: $(df -h /mnt/data | awk 'NR==2{print $4}')"
exit $rc
