#!/bin/bash
# Boot for the baked SenseNova image: sshd + vLLM serve /model.
# TP / MAX_MODEL_LEN / QUANT come from env so one image covers
# 1x4090 (AWQ quant) and 2xL40S (BF16/FP8) without a rebuild.
set -u
/usr/sbin/sshd -D -e -f /etc/ssh/sshd_config &
exec python3 -m vllm.entrypoints.openai.api_server \
  --model /model \
  --host 0.0.0.0 --port 8000 \
  --tensor-parallel-size "${TP:-1}" \
  --max-model-len "${MAX_MODEL_LEN:-32768}" \
  --reasoning-parser qwen3 \
  --enable-auto-tool-choice \
  --tool-call-parser qwen3_coder \
  --trust-remote-code \
  --enforce-eager
