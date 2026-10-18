#!/bin/bash
# Build-time counterpart to stitch-models.py: split oversized model weights into
# sub-4 GB chunk files so no docker layer is large enough to break SimplePod's unpack.
#
# Called from build/models-part.sh AFTER the fetch, so the layer that lands in the image
# contains the chunks rather than the original file.
#
#   bash build/chunk-model.sh <path-to-safetensors> [chunk-mb]
#
# Splitting is destructive to the original *in the layer only*: the original is removed
# once the chunks are verified, so the image never carries both copies (that would add
# 20 GB per model for nothing).
#
# A model at or below the threshold is left untouched -- no point chunking what already
# fits, and it keeps small models loadable with no boot-time stitch.
set -uo pipefail

FILE="${1:?usage: chunk-model.sh <file> [chunk-mb]}"
CHUNK_MB="${2:-3500}"                      # 3.5 GB: comfortably under the ~4 GB danger zone
THRESHOLD_BYTES=$(( CHUNK_MB * 1024 * 1024 ))

[ -f "$FILE" ] || { echo "chunk-model: no such file: $FILE"; exit 1; }

size=$(stat -c%s "$FILE" 2>/dev/null || stat -f%z "$FILE")
if [ "$size" -le "$THRESHOLD_BYTES" ]; then
    echo "chunk-model: $(basename "$FILE") is $((size/1048576)) MB -- left as one file"
    exit 0
fi

n=$(( (size + THRESHOLD_BYTES - 1) / THRESHOLD_BYTES ))
echo "chunk-model: $(basename "$FILE") is $((size/1048576)) MB -> $n chunks of <=${CHUNK_MB} MB"

# `split` numbers with a fixed-width suffix and lexically-sortable names, which is exactly
# what stitch-models.py expects (part000..partNNN, contiguous from zero).
rm -f "$FILE".part[0-9][0-9][0-9]
if ! split -b "${CHUNK_MB}m" -d -a 3 "$FILE" "$FILE.part"; then
    echo "chunk-model: split failed for $(basename "$FILE")"
    rm -f "$FILE".part[0-9][0-9][0-9]
    exit 1
fi

# verify before deleting the original: total chunk bytes must equal the original size,
# or we would ship a corrupt model and only find out at inference time
total=$(cat "$FILE".part[0-9][0-9][0-9] | wc -c | tr -d ' ')
if [ "$total" != "$size" ]; then
    echo "chunk-model: chunk total $total != original $size -- keeping the original"
    rm -f "$FILE".part[0-9][0-9][0-9]
    exit 1
fi

biggest=$(for f in "$FILE".part[0-9][0-9][0-9]; do
    stat -c%s "$f" 2>/dev/null || stat -f%z "$f"
done | sort -rn | head -1)
echo "chunk-model: ok, $n chunks, largest $((biggest/1048576)) MB"

rm -f "$FILE"
echo "chunk-model: removed the original $(basename "$FILE") (reassembled at boot)"
exit 0