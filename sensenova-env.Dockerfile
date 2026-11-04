# PART 1/2 — the vLLM runtime ("env") image: CUDA base + pip vLLM + boot.
# Built FROM nvidia/cuda (NOT from vllm/vllm-openai): the stock vLLM image
# carries ~280 buildkit layers, and a 295-layer image never finishes PPIO
# prewarm (stuck 90+ min on 64 GB, while the ~30-layer 83 GB ComfyUI image
# prewarms in ~14 min). This keeps env to ~6 layers, baked to ~13.
# No model weights here. Parts (Dockerfile.part) build FROM the same CUDA
# base, then compose-image.py stitches env + parts at the registry.
#
# CUDA 12.8 (NOT 13.0): Novita/PPIO 4090 hosts run drivers that reject
# cuda>=13.0 containers (nvidia-container-cli "unsatisfied condition").
FROM nvidia/cuda:12.8.1-cudnn-runtime-ubuntu24.04

ARG DEBIAN_FRONTEND=noninteractive
ARG TORCH_INDEX=cu128

ENV MODEL_REPO="sensenova/SenseNova-6.8-Code2Video" \
    MODEL_ID="/model" \
    TP=1 \
    MAX_MODEL_LEN=32768 \
    PATH="/opt/venv/bin:/usr/local/cuda/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
    VIRTUAL_ENV=/opt/venv

RUN apt-get update && apt-get install -y --no-install-recommends \
        python3 python3-venv python3-pip python3-dev \
        gcc g++ git wget curl ca-certificates \
        openssh-server procps \
        libgl1 libglib2.0-0 libsm6 libxext6 libxrender1 libgomp1 \
    && rm -rf /var/lib/apt/lists/* \
    && mkdir -p /run/sshd /root/.ssh && chmod 700 /root/.ssh \
    && python3 -m venv /opt/venv

# vLLM + serving stack in ONE layer (qwen3_5 arch needs vLLM >= 0.17;
# pip latest is past that). Mirrors the ComfyUI cu130 torch pattern.
RUN /opt/venv/bin/pip install --no-cache-dir --upgrade pip \
    && /opt/venv/bin/pip install --no-cache-dir \
        --index-url https://download.pytorch.org/whl/${TORCH_INDEX} \
        torch \
    && /opt/venv/bin/pip install --no-cache-dir \
        "vllm>=0.17" huggingface_hub

COPY sensenova/start.sh /opt/sensenova-start.sh
RUN chmod +x /opt/sensenova-start.sh

EXPOSE 8000 22
CMD ["/opt/sensenova-start.sh"]
