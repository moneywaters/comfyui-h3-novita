# PART 1/2 — the vLLM runtime ("env") image: base + sshd + boot script.
# No model weights here. Parts (Dockerfile.part) build FROM this same tag,
# then compose-image.py stitches env + parts at the registry — no runner
# ever holds the full ~65 GB image (same pattern as the ComfyUI builds).
FROM vllm/vllm-openai:latest

ENV MODEL_REPO="sensenova/SenseNova-6.8-Code2Video" \
    MODEL_ID="/model" \
    TP=1 \
    MAX_MODEL_LEN=32768

RUN apt-get update && apt-get install -y --no-install-recommends openssh-server procps \
    && rm -rf /var/lib/apt/lists/* \
    && mkdir -p /run/sshd /root/.ssh && chmod 700 /root/.ssh

COPY sensenova/start.sh /opt/sensenova-start.sh
RUN chmod +x /opt/sensenova-start.sh

EXPOSE 8000 22
CMD ["/opt/sensenova-start.sh"]
