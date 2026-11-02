# PART 2/2 — one model-weight part, built FROM the bare CUDA base.
# MUST stay FROM nvidia/cuda (not FROM env): ops/compose-image.py drops the
# first N layers matching this exact base and appends only the new layers
# onto the env image. Building FROM env would re-embed the whole vLLM stack
# in every part (that's how `baked` hit 119 GB).
# Build: podman build --build-arg PART=p1 -f sensenova-part.Dockerfile .
FROM nvidia/cuda:13.0.1-cudnn-runtime-ubuntu24.04

ARG DEBIAN_FRONTEND=noninteractive
ARG PART=p1

RUN apt-get update && apt-get install -y --no-install-recommends \
        python3 python3-pip ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && pip3 install --no-cache-dir --break-system-packages huggingface_hub

ENV MODEL_REPO="sensenova/SenseNova-6.8-Code2Video"

COPY sensenova/fetch-part.sh /opt/fetch-part.sh
RUN chmod +x /opt/fetch-part.sh

# One part per image, so this layer commits reliably on a GHA runner.
RUN PART="${PART}" /opt/fetch-part.sh
