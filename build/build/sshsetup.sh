#!/bin/bash
# Bake an authorized SSH key into the image (optional build arg).
# Novita also injects the console key at runtime; this is a belt-and-braces fallback.
set -uo pipefail

mkdir -p /root/.ssh
chmod 700 /root/.ssh

key="${SSH_AUTHORIZED_KEY:-}"
if [ -n "$key" ]; then
    printf '%s\n' "$key" > /root/.ssh/authorized_keys
    chmod 600 /root/.ssh/authorized_keys
    echo "sshsetup: baked 1 authorized key"
else
    rm -f /root/.ssh/authorized_keys
    echo "sshsetup: no SSH_AUTHORIZED_KEY provided (relying on runtime injection)"
fi
