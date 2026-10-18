#!/bin/bash
# Boot-time weight provisioning, driven by models-source.sh's decision.
#
#   baked     -> nothing to do; the weights are already on disk. That is the :models tag,
#                which PPIO and Novita prewarm, and also any restart of a container that
#                has already downloaded them.
#   download  -> fetch from Hugging Face. That is the code-only tag, which SimplePod must
#                use because its hosts cannot unpack our ~20 GB weight layers.
#
# On the download path this reuses build/models-part.sh, which is already the Hugging Face
# fetcher used at image-build time: per-file curl with retries, a minimum-size sanity check
# and a .partial staging file so a truncated download never lands as a real model. Reusing
# it means the boot path and the build path cannot drift apart.
#
# HF_TOKEN is required on that path. Without it we stop and say so rather than booting a
# container that will fail confusingly at generation time.
set -uo pipefail

log() { echo "[models] $*"; }

MODELS_DIR="${COMFYUI_PATH:-/opt/ComfyUI}/models"
HERE="$(cd "$(dirname "$0")" && pwd)"

# Which parts to fetch. The default is what the shipped workflows actually need, not all
# 14 parts -- a Nomic user on SimplePod is paying per hour and should not wait on Qwen
# weights for an H3 run. Override with MODELS_PARTS="h3-fl2va h3enc ...".
DEFAULT_PARTS="${MODELS_PARTS:-h3-fl2va h3-singularity h3enc h3vae-kijai h3vae-audio h3loras h3extra seedvr2}"

source_answer=""
if [ -x "$HERE/models-source.sh" ]; then
    # NOTE: read the answer, not the exit status -- piping into tail would mask it
    source_answer="$("$HERE/models-source.sh" 2>/dev/null | tail -1)"
else
    log "WARN: models-source.sh not found; assuming baked"
    source_answer=baked
fi
log "weights source: ${source_answer:-unknown}"

if [ "$source_answer" != "download" ]; then
    log "using the weights baked into the image"
    exit 0
fi

# ---------------------------------------------------------------- HF token
TOKEN="${HF_TOKEN:-${HUGGING_FACE_HUB_TOKEN:-}}"
if [ -z "$TOKEN" ]; then
    log "ERROR: this platform needs weights downloaded from Hugging Face, but HF_TOKEN is empty."
    log "       Set it on the instance/template envVariables (SimplePod supports this), e.g."
    log "         envVariables: [{\"name\":\"HF_TOKEN\",\"value\":\"hf_...\"}]"
    log "       ComfyUI will start, but workflows will fail to load their models."
    exit 1
fi

# ---------------------------------------------------------------- space check
# 40 GB is the rough size of the default part set (the two ~20 GB diffusion models
# dominate). SimplePod's root overlay is the small filesystem that bit us before, so check
# it rather than discovering it halfway through a 20 GB write.
NEED_GB="${MODELS_NEED_GB:-40}"
# the models dir may not exist yet; df the nearest existing ancestor so the check is real
probe="$MODELS_DIR"
while [ ! -d "$probe" ] && [ "$probe" != "/" ]; do probe="$(dirname "$probe")"; done
avail_kb=$(df -Pk "$probe" 2>/dev/null | awk 'NR==2{print $4}')
if [ -n "$avail_kb" ]; then
    avail_gb=$(( avail_kb / 1024 / 1024 ))
    log "free space at $probe: ${avail_gb} GB (need ~${NEED_GB} GB)"
    if [ "$avail_gb" -lt "$NEED_GB" ]; then
        log "ERROR: not enough space for the model download; refusing to start a 20 GB fetch."
        log "       Mount a SimplePod Network Storage and point COMFYUI_PATH/models at it,"
        log "       or set MODELS_NEED_GB lower if your part set is smaller."
        exit 1
    fi
fi

# ---------------------------------------------------------------- fetch
FE="${HERE}/models-part.sh"
[ -x "$FE" ] || FE=/opt/models-part.sh
if [ ! -f "$FE" ]; then
    log "ERROR: models-part.sh not found; cannot download weights"
    exit 1
fi

log "fetching parts: $DEFAULT_PARTS"
failed_parts=()
for part in $DEFAULT_PARTS; do
    log "--- $part ---"
    if PART="$part" HF_TOKEN="$TOKEN" COMFYUI_PATH="${COMFYUI_PATH:-/opt/ComfyUI}" \
        bash "$FE" 2>&1 | sed 's/^/    /'; then
        log "$part ok"
    else
        log "$part FAILED"
        failed_parts+=("$part")
    fi
done

if [ "${#failed_parts[@]}" -gt 0 ]; then
    log "WARN: ${#failed_parts[@]} part(s) failed: ${failed_parts[*]}"
    log "      ComfyUI will still start; the affected workflows will report missing models."
fi

log "model provisioning finished"
exit 0