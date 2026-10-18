#!/bin/bash
# Decide whether to use the model weights baked into this image, or download them.
#
# WHY THIS EXISTS
# Our image holds ~83 GB of model weights so that PPIO and Novita can prewarm it and
# serve a generated workflow within seconds. SimplePod cannot use that: their hosts will
# not unpack a ~21 GB layer (the console loops "Preparing instance / Pulling image"
# forever, diskUsage never moves, the container never starts). Reproduced on host 216
# (RTX 4090) and host 161 (RTX 3090) at both 100 GB and 200 GB disk, while a 7 GB control
# image boots on those same hosts in ~300 seconds.
#
# So on SimplePod we want the opposite trade: skip the baked weights and pull them from
# Hugging Face at boot instead. That costs bandwidth per boot but nothing else, and it is
# the only thing that makes the image usable there at all.
#
# HOW PLATFORM IS DECIDED -- explicit first, sniffing second
# 1. $BULK_MODELS_SOURCE wins if set (baked | download). This is the reliable path:
#    SimplePod templates and instances both accept envVariables, so the launcher can just
#    say so. Never guess when you can be told.
# 2. $SIMPLEPOD=1 / $SIMPLEPOD_* -- set by the SimplePod launcher's start script.
# 3. Sniffing, as a fallback for a template someone created by hand: SimplePod's own
#    container image conventions show up inside the container. Their FileBrowser runs on
#    5335, Jupyter on 8888, and their templates mount the payload at /app or /workspace.
#    None of those exist on PPIO or Novita. A match here logs WHY it matched so a false
#    positive is diagnosable rather than mysterious.
# 4. Otherwise: baked. PPIO and Novita prewarm the image, so baked is the fast path and
#    must stay the default.
#
# The decision is written to /run/models-source so start.sh and any later step agree on
# one answer instead of re-deriving it.
set -uo pipefail

DECISION_FILE="${MODELS_DECISION_FILE:-/run/models-source}"
log() { echo "[models-source] $*" >&2; }

explicit="${BULK_MODELS_SOURCE:-}"
source=""

# --- decide from what is actually on disk -----------------------------------------
#
# The image ships NO model weights -- that is deliberate, see the header of
# fetch-models-boot.sh. So the question is never "which platform is this" but "are the
# weights already here?". A restart of the same container finds them and does nothing; a
# fresh instance downloads them.
#
# BULK_MODELS_SOURCE is still honoured so the behaviour can be forced:
#   baked    -> pretend the weights are present, do not download
#   download -> always verify against Hugging Face
explicit="${BULK_MODELS_SOURCE:-}"
explicit_lc=$(printf '%s' "$explicit" | tr '[:upper:]' '[:lower:]')

MODELS_DIR="${COMFYUI_PATH:-/opt/ComfyUI}/models"
# The two ~20 GB diffusion models are the ones every H3 workflow needs, so they are the
# honest test of "are the weights here?".
MARKER="${MODELS_MARKER:-$MODELS_DIR/diffusion_models}"
present=0
if [ -d "$MARKER" ]; then
    n=$(find "$MARKER" -maxdepth 1 -type f -name '*.safetensors' 2>/dev/null | wc -l | tr -d ' ')
    [ "${n:-0}" -gt 0 ] && present=1
fi

case "$explicit_lc" in
    baked)
        source=baked
        reason="BULK_MODELS_SOURCE=baked (forced)"
        ;;
    download|hf|huggingface)
        source=download
        reason="BULK_MODELS_SOURCE=$explicit (forced)"
        ;;
    "")
        if [ "$present" = "1" ]; then
            source=baked
            reason="weights already present in $MARKER"
        else
            source=download
            reason="no weights in $MARKER (image ships none; fetching from Hugging Face)"
        fi
        ;;
    *)
        log "WARN: BULK_MODELS_SOURCE='$explicit' is not baked|download; deciding from disk"
        if [ "$present" = "1" ]; then source=baked; reason="weights already present in $MARKER"
        else source=download; reason="no weights in $MARKER"; fi
        ;;
esac

# --- report + persist -------------------------------------------------------------
log "decision: $source"
log "because:  $reason"
# plain answer on stdout too, so callers can just do:  src="$(models-source.sh)"
printf '%s\n' "$source"

mkdir -p "$(dirname "$DECISION_FILE")" 2>/dev/null || true
if printf '%s\n' "$source" > "$DECISION_FILE" 2>/dev/null; then
    log "wrote $DECISION_FILE"
else
    # /run may be read-only in some sandboxes; the decision still holds for this process
    # tree, callers just cannot read the file
    log "WARN: could not write $DECISION_FILE (continuing)"
fi

if [ "$source" = "download" ]; then
    log "weights will be fetched from Hugging Face at boot (HF_TOKEN must be set)"
fi

# exit code doubles as the answer so a caller can do: if models-source.sh; then ... fi
[ "$source" = "baked" ] && exit 0 || exit 10