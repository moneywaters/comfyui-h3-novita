#!/bin/bash
# Strip the "model.diffusion_model." key prefix from safetensors checkpoints that carry it.
#
# Why: ComfyUI_MinimaxH3HybridLoader merges a base and an overlay checkpoint key-by-key and
# refuses when their key sets differ. Here they do differ -- same 932 tensors, different
# naming:
#
#   minimax_h3_fl2va_pruned_int8_convrot.safetensors                  932 keys, no prefix
#   Minimax-h3_Singularity_ref2va_Pruned_v1.3_int8.safetensors        932 keys, all prefixed
#
# so the hybrid dies with "the two checkpoints have different key sets, cannot hybridise".
# ComfyUI's stock loaders normalise the prefix internally, which is why the plain
# UNETLoader never cared.
#
# The rewrite touches ONLY the JSON header. safetensors stores tensor offsets relative to
# the start of the data section, so as long as the header keeps the same byte length
# (padding the shorter JSON with spaces) every offset stays valid and none of the ~20 GB of
# tensor data is read or moved. Runs in milliseconds, and only the header block is written.
#
# Idempotent: already-normalised files are skipped.
#
# Runs at container start rather than at build time on purpose -- the models live in their
# own build part, so baking the change would mean re-downloading 20 GB. Revisit if these
# ever move into the env part.
set -uo pipefail

MODELS_DIR="${COMFYUI_MODELS_DIR:-/opt/ComfyUI/models}"
PREFIX="model.diffusion_model."
MARKER="/opt/.models-normalised"

[ -f "$MARKER" ] && exit 0

shopt -s nullglob
targets=("$MODELS_DIR"/diffusion_models/*.safetensors)
[ ${#targets[@]} -eq 0 ] && exit 0

python3 - "$PREFIX" "${targets[@]}" <<'PY'
import json, struct, sys

prefix = sys.argv[1]
names = sys.argv[2:]
changed = skipped = 0

for path in names:
    try:
        with open(path, "r+b") as f:
            raw = f.read(8)
            if len(raw) < 8:
                continue
            n = struct.unpack("<Q", raw)[0]
            hdr = f.read(n)
            try:
                h = json.loads(hdr)
            except Exception:
                continue
            keys = [k for k in h if k != "__metadata__"]
            if not any(k.startswith(prefix) for k in keys):
                skipped += 1
                continue

            new = {(k[len(prefix):] if k.startswith(prefix) else k): v for k, v in h.items()}
            nb = json.dumps(new, separators=(",", ":")).encode()
            if len(nb) > n:
                print("  WARN %s: new header %d > %d; offsets would shift, skipped"
                      % (path.rsplit("/", 1)[-1], len(nb), n))
                continue
            f.seek(8)
            f.write(nb + b" " * (n - len(nb)))
            print("  normalised %s (%d keys, header %d -> %d, data untouched)"
                  % (path.rsplit("/", 1)[-1], len(keys), n, len(nb)))
            changed += 1
    except Exception as e:
        print("  WARN %s: %s" % (path.rsplit("/", 1)[-1], e))

print("  normalise-models: %d file(s) rewritten, %d already clean" % (changed, skipped))
PY

touch "$MARKER" 2>/dev/null || true
