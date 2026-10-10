# =============================================================================
# ComfyUI + MiniMax H3 / Qwen-Image 2.1 / SeedVR2  —  Novita AI GPU image
#
# Design rules (per user requirement):
#   * Models are downloaded AT BUILD TIME and baked into image layers.
#     Nothing large is ever pulled to the local machine.
#   * The HF token is supplied at build time (build arg / build secret) and is
#     NEVER written into an image layer.
#
# Build (buildx / podman):
#   DOCKER_BUILDKIT=1 docker build \
#     --secret id=hf_token,src=/tmp/hf_token \
#     --build-arg MODEL_SET=video \
#     -t moneywaters/comfyui-h3-novita:latest .
# =============================================================================
FROM nvidia/cuda:13.0.1-cudnn-runtime-ubuntu24.04

ARG DEBIAN_FRONTEND=noninteractive
# ---- build-time only knobs (do NOT persist into image ENV) ----
ARG HF_TOKEN=""
ARG MODEL_SET=video
ARG TORCH_INDEX=cu130
ARG COMFYUI_REF=8d534945
ARG SSH_AUTHORIZED_KEY=""
ARG INSTALL_SAGE=1

ENV PYTHONUNBUFFERED=1 \
    COMFYUI_PATH=/opt/ComfyUI \
    VIRTUAL_ENV=/opt/comfyui-venv \
    PATH=/opt/comfyui-venv/bin:/usr/local/cuda/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    OPENBLAS_NUM_THREADS=1 \
    OMP_NUM_THREADS=4

# ---------------------------------------------------------------- base system
RUN apt-get update && apt-get install -y --no-install-recommends \
        python3 python3-venv python3-dev python3-pip \
        git git-lfs wget curl xz-utils ca-certificates \
        openssh-server tini procps \
        ffmpeg libgl1 libglib2.0-0 libsm6 libxext6 libxrender1 libgomp1 \
        build-essential ninja-build \
    && rm -rf /var/lib/apt/lists/* \
    && mkdir -p /run/sshd /root/.ssh /opt/ComfyUI/models \
    && chmod 700 /root/.ssh \
    && test -x /usr/sbin/sshd

# --------------------------------------------------------------------- python
RUN python3 -m venv /opt/comfyui-venv \
    && /opt/comfyui-venv/bin/pip install -U --no-cache-dir pip wheel setuptools \
    && /opt/comfyui-venv/bin/pip install --no-cache-dir \
        torch torchvision torchaudio --index-url "https://download.pytorch.org/whl/${TORCH_INDEX}" \
    && /opt/comfyui-venv/bin/python -c "import torch;print('torch',torch.__version__,'cuda',torch.version.cuda)"

# -------------------------------------------------------------------- ComfyUI
RUN git clone https://github.com/comfyanonymous/ComfyUI.git /opt/ComfyUI \
    && cd /opt/ComfyUI \
    && git checkout "${COMFYUI_REF}" \
    && /opt/comfyui-venv/bin/pip install --no-cache-dir -r requirements.txt \
    && /opt/comfyui-venv/bin/python -c "import comfy_kitchen; print('comfy-kitchen ok')"

# --------------------------------------------------------------- custom nodes
COPY build/nodes.sh /opt/nodes.sh
RUN bash /opt/nodes.sh \
    && cd /opt/ComfyUI \
    && for req in custom_nodes/*/requirements.txt; do \
         [ -f "$req" ] && /opt/comfyui-venv/bin/pip install --no-cache-dir -r "$req" || true; \
       done \
    && /opt/comfyui-venv/bin/pip install --no-cache-dir \
         piexif rotary-embedding-torch numexpr imageio-ffmpeg pykalman \
         spandrel spandrel_extra_arches pandas segment-anything webcolors \
         sqlalchemy opencv-python-headless scikit-image matplotlib

# --------------------------------------------------- optional SageAttention
COPY build/sage.sh /opt/sage.sh
RUN if [ "${INSTALL_SAGE}" = "1" ]; then \
        bash /opt/sage.sh || echo "WARN: sageattention build skipped/failed (non-fatal)"; \
    else echo "INSTALL_SAGE=0 — skipping"; fi

# --------------------------------------------------- models (baked into layers)
COPY build/models.sh /opt/models.sh
RUN --mount=type=secret,id=hf_token,required=false \
    export HF_TOKEN="${HF_TOKEN:-$(cat /run/secrets/hf_token 2>/dev/null || true)}" \
    && MODEL_SET="${MODEL_SET}" bash /opt/models.sh

# ------------------------------------------------------------- workflows + app
COPY workflows/ /opt/ComfyUI/user/default/workflows/
COPY build/start.sh /opt/start.sh
COPY build/verify.sh /opt/verify.sh
COPY build/sshsetup.sh /opt/sshsetup.sh

RUN chmod +x /opt/start.sh /opt/verify.sh /opt/models.sh /opt/nodes.sh /opt/sshsetup.sh \
    && SSH_AUTHORIZED_KEY="${SSH_AUTHORIZED_KEY}" bash /opt/sshsetup.sh \
    && bash /opt/verify.sh

EXPOSE 22 8188
WORKDIR /opt/ComfyUI
ENTRYPOINT ["/usr/bin/tini","--"]
CMD ["/opt/start.sh"]
