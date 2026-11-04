#!/bin/bash
# Boot for the baked SenseNova image: sshd + vLLM serve /model.
# TP / MAX_MODEL_LEN / QUANT come from env (PPIO command
# or envs), so the same image covers 1x4090 (AWQ) and 2xL40S (BF16/FP8).
set -u

# ------------------------------------------------------------------ SSH setup
# Platform key injection: PPIO/Novita mount console SSH keys into the
# container (env vars and/or /root/.ssh/keys/*). Collect them so key auth
# works alongside the console password login.
mkdir -p /run/sshd /root/.ssh /etc/ssh/sshd_config.d
chmod 700 /root/.ssh
touch /root/.ssh/authorized_keys
for v in SSH_AUTHORIZED_KEY SSH_PUBLIC_KEY PUBLIC_KEY SSH_KEY AUTHORIZED_KEYS; do
    val="${!v:-}"
    [ -n "$val" ] && printf '%s\n' "$val" >> /root/.ssh/authorized_keys
done
if [ -d /root/.ssh/keys ]; then
    cat /root/.ssh/keys/* >> /root/.ssh/authorized_keys 2>/dev/null || true
fi
[ -f /etc/ssh/ssh_host_ed25519_key ] || ssh-keygen -A >/dev/null 2>&1
cat > /etc/ssh/sshd_config.d/99-platform.conf <<'EOF'
PermitRootLogin yes
PasswordAuthentication yes
PubkeyAuthentication yes
UsePAM no
EOF
if [ -s /root/.ssh/authorized_keys ]; then
    sort -u /root/.ssh/authorized_keys -o /root/.ssh/authorized_keys
    chmod 600 /root/.ssh/authorized_keys
    echo "[start] authorized_keys: $(wc -l < /root/.ssh/authorized_keys) key(s)"
else
    echo "[start] WARN: no authorized_keys — key injection did not happen"
fi
/usr/sbin/sshd -D -e -f /etc/ssh/sshd_config &
sleep 1

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
