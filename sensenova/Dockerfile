# SenseNova-6.8-Code2Video FULL BF16 baked image for PPIO.
# FROM stock vLLM (vLLM >= 0.17 supports the qwen3_5 arch natively).
# Full 27B BF16 (~55 GB). Will OOM on a 4090 — the 4090 boot test only
# verifies the image pulls, boots, and vLLM starts loading; then we decide
# (quant vs multi-GPU TP).
#
# 12 shards in 6 layers of 2 (~9 GB each) so no single layer commit
# doubles past a GitHub runner's free disk (same lesson as the ComfyUI
# part-split builds).
#
# Build (GitHub Actions x86 runner — NOT the M-series Mac: podman/qemu
# x86 emulation hangs on big builds):
#   podman build --format docker -t moneywaters/sensenova-code2video:bf16 .
FROM vllm/vllm-openai:latest

ENV MODEL_REPO="sensenova/SenseNova-6.8-Code2Video" \
    MODEL_ID="/model" \
    TP=1 \
    MAX_MODEL_LEN=32768

RUN apt-get update && apt-get install -y --no-install-recommends \
        openssh-server procps \
    && rm -rf /var/lib/apt/lists/* \
    && mkdir -p /run/sshd /root/.ssh && chmod 700 /root/.ssh

# Small files first (config, tokenizer, chat template, index).
RUN python3 -c "
from huggingface_hub import snapshot_download
import os
snapshot_download(repo_id=os.environ['MODEL_REPO'], local_dir='/model',
    allow_patterns=['*.json', '*.jinja', '*.txt', '*.md', 'tokenizer*'])"

# 12 shards in 6 layers of 2 (~9 GB each; peak stays under runner disk).
RUN python3 -c "
from huggingface_hub import snapshot_download
import os
snapshot_download(repo_id=os.environ['MODEL_REPO'], local_dir='/model',
    allow_patterns=['model-0000[12]-of-00012.safetensors'])"
RUN python3 -c "
from huggingface_hub import snapshot_download
import os
snapshot_download(repo_id=os.environ['MODEL_REPO'], local_dir='/model',
    allow_patterns=['model-0000[34]-of-00012.safetensors'])"
RUN python3 -c "
from huggingface_hub import snapshot_download
import os
snapshot_download(repo_id=os.environ['MODEL_REPO'], local_dir='/model',
    allow_patterns=['model-0000[56]-of-00012.safetensors'])"
RUN python3 -c "
from huggingface_hub import snapshot_download
import os
snapshot_download(repo_id=os.environ['MODEL_REPO'], local_dir='/model',
    allow_patterns=['model-0000[78]-of-00012.safetensors'])"
RUN python3 -c "
from huggingface_hub import snapshot_download
import os
snapshot_download(repo_id=os.environ['MODEL_REPO'], local_dir='/model',
    allow_patterns=['model-00009-of-00012.safetensors', 'model-00010-of-00012.safetensors'])"
RUN python3 -c "
from huggingface_hub import snapshot_download
import os
snapshot_download(repo_id=os.environ['MODEL_REPO'], local_dir='/model',
    allow_patterns=['model-00011-of-00012.safetensors', 'model-00012-of-00012.safetensors'])" && \
    ls -la /model/*.safetensors | head -n 14

COPY sensenova/start.sh /opt/sensenova-start.sh
RUN chmod +x /opt/sensenova-start.sh

EXPOSE 8000 22
CMD ["/opt/sensenova-start.sh"]
