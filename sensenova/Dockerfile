# SenseNova-6.8-Code2Video FULL BF16 baked image for PPIO.
FROM vllm/vllm-openai:latest

ENV MODEL_REPO="sensenova/SenseNova-6.8-Code2Video" \
    MODEL_ID="/model" \
    TP=1 \
    MAX_MODEL_LEN=32768

RUN apt-get update && apt-get install -y --no-install-recommends openssh-server procps \
    && rm -rf /var/lib/apt/lists/* \
    && mkdir -p /run/sshd /root/.ssh && chmod 700 /root/.ssh

COPY sensenova/fetch-part.sh /opt/fetch-part.sh
COPY sensenova/start.sh /opt/sensenova-start.sh
RUN chmod +x /opt/fetch-part.sh /opt/sensenova-start.sh

RUN /opt/fetch-part.sh "*.json *.jinja *.txt *.md tokenizer*"
RUN /opt/fetch-part.sh "model-00001-of-00012.safetensors model-00002-of-00012.safetensors"
RUN /opt/fetch-part.sh "model-00003-of-00012.safetensors model-00004-of-00012.safetensors"
RUN /opt/fetch-part.sh "model-00005-of-00012.safetensors model-00006-of-00012.safetensors"
RUN /opt/fetch-part.sh "model-00007-of-00012.safetensors model-00008-of-00012.safetensors"
RUN /opt/fetch-part.sh "model-00009-of-00012.safetensors model-00010-of-00012.safetensors"
RUN /opt/fetch-part.sh "model-00011-of-00012.safetensors model-00012-of-00012.safetensors"

EXPOSE 8000 22
CMD ["/opt/sensenova-start.sh"]
