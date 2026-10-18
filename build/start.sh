#!/bin/bash
# Container entrypoint (PID1 = tini). Starts sshd + ComfyUI, keeps both alive.
set -uo pipefail

log() { echo "[start] $*"; }

# ------------------------------------------------------------------ SSH setup
mkdir -p /run/sshd /root/.ssh /etc/ssh/sshd_config.d
chmod 700 /root/.ssh

# Runtime key injection (Novita may pass the key through an env var or mount).
for v in SSH_AUTHORIZED_KEY SSH_PUBLIC_KEY PUBLIC_KEY SSH_KEY AUTHORIZED_KEYS; do
    val="${!v:-}"
    [ -n "$val" ] && printf '%s\n' "$val" >> /root/.ssh/authorized_keys
done
if [ -d /root/.ssh/keys ]; then
    cat /root/.ssh/keys/* >> /root/.ssh/authorized_keys 2>/dev/null || true
fi

# Optional root password (Novita console "password" login).
if [ -n "${ROOT_PASSWORD:-}" ]; then
    echo "root:${ROOT_PASSWORD}" | chpasswd 2>/dev/null || true
fi

[ -f /etc/ssh/ssh_host_ed25519_key ] || ssh-keygen -A >/dev/null 2>&1

cat > /etc/ssh/sshd_config.d/99-novita.conf <<'EOF'
PermitRootLogin yes
PasswordAuthentication yes
PubkeyAuthentication yes
UsePAM no
EOF

if [ -s /root/.ssh/authorized_keys ]; then
    sort -u /root/.ssh/authorized_keys -o /root/.ssh/authorized_keys
    chmod 600 /root/.ssh/authorized_keys
    log "authorized_keys: $(wc -l < /root/.ssh/authorized_keys) key(s)"
else
    log "WARN: no authorized_keys — key injection did not happen"
fi

/usr/sbin/sshd -D -e -f /etc/ssh/sshd_config &
SSHD_PID=$!
sleep 1
if kill -0 "$SSHD_PID" 2>/dev/null; then log "sshd running pid=$SSHD_PID"; else log "ERROR: sshd died"; fi

# ------------------------------------------------------------------ ComfyUI
cd "${COMFYUI_PATH:-/opt/ComfyUI}" || exit 1
PY="${VIRTUAL_ENV:-/opt/comfyui-venv}/bin/python3"
mkdir -p /var/log

# Blend a base + overlay checkpoint requires matching key sets; Singularity ships the
# "model.diffusion_model." prefix and fl2va does not, which makes HybridLoader refuse.
# Header-only rewrite, milliseconds, idempotent -- see build/normalize-models.sh.
# Weights arrive here, not in the image: the image is code-only so it can be pulled
# anywhere. On a container restart they are already on disk and this is a no-op; on a
# fresh instance it downloads them from Hugging Face. Runs before normalize-models,
# which rewrites safetensors headers and needs whole files.
# Where do the weights come from? On PPIO and Novita the image holds them and this is a
# no-op. On SimplePod the baked weights cannot be unpacked at all (their hosts loop on a
# ~21 GB layer forever), so this fetches them from Hugging Face instead. The decision and
# its reason are logged by models-source.sh.
if [ -x /opt/fetch-models-boot.sh ]; then
    bash /opt/fetch-models-boot.sh 2>&1 | sed 's/^/[models] /' || \
        log "WARN: model provisioning reported a problem (continuing to start ComfyUI)"
fi

if [ -x /opt/normalize-models.sh ]; then
    log "normalising model key prefixes"
    bash /opt/normalize-models.sh 2>&1 | sed 's/^/[norm] /' || log "WARN: normalise-models failed"
fi

log "starting ComfyUI ($PY)"
# --enable-compress-response-body matters a lot here: /object_info is 3.55 MB of JSON and
# gzip takes it to 389 KB (9.1x). Over a remote host's proxy (~40 KB/s effective) that is
# the difference between an 84s stall on the loading screen and ~9s.
"$PY" main.py --listen 0.0.0.0 --port 8188 --preview-method auto \
    --enable-compress-response-body > /var/log/comfyui.log 2>&1 &
COMFY_PID=$!
log "ComfyUI pid=$COMFY_PID  (log: /var/log/comfyui.log)"

# ------------------------------------------------------------------ supervise
wait -n "$SSHD_PID" "$COMFY_PID"
rc=$?
log "a service exited (rc=$rc) — shutting down container"
tail -n 40 /var/log/comfyui.log 2>/dev/null || true
kill "$SSHD_PID" "$COMFY_PID" 2>/dev/null || true
exit "$rc"
