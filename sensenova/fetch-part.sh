#!/bin/bash
# Fetch one shard group of SenseNova-6.8-Code2Video into /model.
# Called once per Dockerfile layer so no single layer commit doubles
# past the runner's free disk. Usage: fetch-part.sh "pattern1 pattern2"
set -euo pipefail
python3 - "$1" <<'PY'
import sys
from huggingface_hub import snapshot_download
import os
patterns = sys.argv[1].split()
snapshot_download(repo_id=os.environ.get("MODEL_REPO", "sensenova/SenseNova-6.8-Code2Video"),
    local_dir="/model", allow_patterns=patterns)
PY
echo "part done: $1"
ls /model/*.safetensors 2>/dev/null | wc -l
