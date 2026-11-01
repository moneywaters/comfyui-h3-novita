#!/bin/bash
# Fetch one weight part by PART name (p1..p6, ~2 shards each ~9 GB).
# Called at image-build time by sensenova-part.Dockerfile.
set -euo pipefail
case "${PART:-p1}" in
  p0) PATTERNS="*.json *.jinja *.txt *.md tokenizer*" ;;
  p1) PATTERNS="model-00001-of-00012.safetensors model-00002-of-00012.safetensors" ;;
  p2) PATTERNS="model-00003-of-00012.safetensors model-00004-of-00012.safetensors" ;;
  p3) PATTERNS="model-00005-of-00012.safetensors model-00006-of-00012.safetensors" ;;
  p4) PATTERNS="model-00007-of-00012.safetensors model-00008-of-00012.safetensors" ;;
  p5) PATTERNS="model-00009-of-00012.safetensors model-00010-of-00012.safetensors" ;;
  p6) PATTERNS="model-00011-of-00012.safetensors model-00012-of-00012.safetensors" ;;
  *) echo "unknown PART=$PART" >&2; exit 2 ;;
esac
python3 - <<PY
from huggingface_hub import snapshot_download
import os
snapshot_download(repo_id=os.environ.get("MODEL_REPO", "sensenova/SenseNova-6.8-Code2Video"),
    local_dir="/model", allow_patterns="$PATTERNS".split())
PY
echo "part $PART done"
du -sh /model 2>/dev/null || true
