#!/bin/bash
# Fetch the models Seed Hunter v2.5.1 needs that the server does not have yet.
#
# Sources: hf-mirror.com (huggingface.co is blocked/throttled from here).
# Layout matches the existing convention so link-models.sh picks the files up:
#   /mnt/data/comfy-models/models/<Repo--Name>/snapshots/master/<subdir>/<file>
#
# Resumable: re-running continues partial files. Safe to re-run.
set -u

ROOT=/mnt/data/comfy-models/models
LOG="$HOME/v251-dl.log"
MIRROR=https://hf-mirror.com

log() { printf '%s %s\n' "$(date -Is)" "$*" >>"$LOG"; echo "$*"; }
say() { printf '%s %s\n' "$(date -Is)" "$*"; }

# fetch <hf-repo> <subpath/in/repo> <local-category-dir>
#   hf-repo uses "/" (Kijai/MiniMax-H3-TAE) and also names the local snapshot dir
#   (slashes become "--", matching what the earlier downloads produced).
fetch() {
    local repo="$1" sub="$2" cat="$3"
    local name; name=$(basename "$sub")
    local dir="${repo//\//--}"
    local out="$ROOT/$dir/snapshots/master/$cat/$name"
    # HF download URL form: <mirror>/<repo>/resolve/main/<path>
    local url="$MIRROR/$repo/resolve/main/$sub"
    mkdir -p "$(dirname "$out")"

    if [ -f "$out" ]; then
        local have expect
        have=$(stat -c%s "$out" 2>/dev/null || echo 0)
        expect=$(curl -sIL "$url" 2>/dev/null | tr -d '\r' | awk 'tolower($1)=="content-length:"{n=$2} END{print n+0}')
        if [ "${expect:-0}" -gt 0 ] && [ "$have" -ge "$expect" ]; then
            log "OK     $cat/$name ($((have/1048576)) MB) complete"
            return 0
        fi
        log "RESUME $cat/$name at $((have/1048576)) MB of $(( ${expect:-0} /1048576)) MB"
    else
        log "GET    $cat/$name"
    fi

    curl -L --fail --retry 8 --retry-delay 5 --retry-all-errors \
         --silent --show-error -C - -o "$out" "$url" >>"$LOG" 2>&1
    local rc=$?
    if [ $rc -eq 0 ]; then
        log "DONE   $cat/$name $(du -h "$out" 2>/dev/null | cut -f1)"
    else
        log "FAIL   $cat/$name (curl exit $rc)"
    fi
    return $rc
}

say "==== v2.5.1 model fetch starting ===="
say "target: $(du -sh "$ROOT" 2>/dev/null | cut -f1) used | $(df -h /mnt/data | awk 'NR==2{print $4}') free"
: > "$LOG"

# small first, so the LoRA / upscale / preview path works sooner
fetch "Kijai/MiniMax-H3-TAE" \
      "vae_approx/taeh3.safetensors" \
      "vae_approx"

fetch "Kijai/MiniMax-H3-experimental" \
      "loras/minimax_h3_DMAD_4step_full_lora_avg_rank_39_bf16.safetensors" \
      "loras"

fetch "silveroxides/MiniMax-H3_tests" \
      "ref2v_dareties/minimax_h3_ref2v_turbo_4step_v0.1_v4_step600_dareties_fro0995.safetensors" \
      "loras"

fetch "Kijai/MiniMax-H3-experimental" \
      "minimax_h3_video_vae_int8_convrot.safetensors" \
      "vae"

# the two 21 GB diffusion models
fetch "Comfy-Org/MiniMax-H3" \
      "diffusion_models/minimax_h3_fl2va_pruned_int8_convrot.safetensors" \
      "diffusion_models"

fetch "WarmBloodAban/Minimax-h3_Singularity" \
      "Minimax-h3_Singularity_ref2va_Pruned_v1.3_int8.safetensors" \
      "diffusion_models"

say "==== v2.5.1 model fetch finished ===="
say "free space now: $(df -h /mnt/data | awk 'NR==2{print $4}')"
