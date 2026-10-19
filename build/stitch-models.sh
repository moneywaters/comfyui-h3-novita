#!/bin/bash
# Reassemble model weights that the image ships as chunk files.
#
# WHY THIS EXISTS
# SimplePod hosts refuse this image. Their console loops "Preparing instance /
# Pulling image" every ~4 minutes forever; dockerPullProgressBar reaches 100%
# each cycle, but diskUsage stays 0.00 and the container never starts. Verified
# on two different hosts (216 RTX 4090, 161 RTX 3090) with two different disk
# sizes (100 GB, 200 GB), while a 7 GB control image on the SAME hosts boots in
# ~300s. So it is the image, and the difference that matters is layer shape:
#
#   ours    63 layers, 83.1 GB, largest single layer 20.96 GB
#   control 29 layers,  7.37 GB, nothing over a few GB
#
# Those big layers are single model files -- docker stores them uncompressed, so
# a 20 GB safetensors becomes a ~21 GB layer. Unpacking a 21 GB layer needs that
# much scratch on the overlay the storage driver is writing to, and these hosts
# are sized for small models. (Supporting evidence: in an earlier SimplePod
# session the root overlay was 32 GB and failed with "No space left on device".)
#
# THE FIX
# Ship the largest weights as <name>.safetensors.partNNN chunks, each under 4 GB
# so no layer is large, and stitch them back together. Stitching is LAZY: a
# model is only rebuilt when something asks for it, so PPIO and Novita -- which
# pull this image fine and prewarm it -- pay nothing unless they actually load
# one of the chunked models. That keeps the image compatible with all three
# platforms, which is the constraint this change had to respect.
#
# WHAT CALLS IT
#   * build/start.sh does a fast pass over $MODELS_REASSEMBLE_DIRS (default:
#     diffusion_models, because those are the two 20 GB files) so the common
#     case is ready before the user clicks Queue Prompt.
#   * set $MODELS_REASSEMBLE_ALL=1 to stitch every chunked model at boot.
#   * anything else can call it directly to rebuild one file on demand.
#
# Idempotent and crash-safe: a rebuild goes to a temp file and is moved into
# place only when the size matches, so an interrupted boot never leaves a
# truncated model that ComfyUI would then fail to load.
set -uo pipefail

MODELS_DIR="${MODELS_DIR:-/opt/ComfyUI/models}"
HERE="$(cd "$(dirname "$0")" && pwd)"
# -f, not -x: the .py is invoked as `python3 script`, so it does not need the execute
# bit, and testing -x made this fall back to /opt whenever it was not chmod +x.
[ -f "$HERE/stitch-models.py" ] || HERE=/opt

say() { echo "[stitch] $*"; }

# Chunk naming: <stem>.partNNN, so foo.safetensors.part000 .. part0NN.
# A directory scan is enough -- one pass, no recursion beyond the model tree.
python3 "$HERE/stitch-models.py" \
    --models-dir "$MODELS_DIR" \
    ${MODELS_REASSEMBLE_DIRS:+--dirs $MODELS_REASSEMBLE_DIRS} \
    ${MODELS_REASSEMBLE_ALL:+--all} \
    ${MODELS_REASSEMBLE_FORCE:+--force} \
    ${MODELS_REASSEMBLE_VERBOSE:+--verbose}
rc=$?
if [ "$rc" -ne 0 ]; then
    say "WARN: stitch-models.py exited $rc (models may be incomplete)"
fi
exit 0