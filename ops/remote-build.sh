#!/bin/bash
# Runs ON the remote builder host (root). Executed by .github/workflows/remote-build.yml.
# Requires: HF_TOKEN, DOCKER_USER, DOCKER_PASS in the environment.
set -euo pipefail

: "${HF_TOKEN:?HF_TOKEN required}"
: "${DOCKER_USER:?DOCKER_USER required}"
: "${DOCKER_PASS:?DOCKER_PASS required}"
MODEL_SET="${MODEL_SET:-video}"
TORCH_INDEX="${TORCH_INDEX:-cu130}"
INSTALL_SAGE="${INSTALL_SAGE:-1}"
REPO="${REPO:-https://github.com/moneywaters/comfyui-h3-novita.git}"
IMAGE="docker.io/${DOCKER_USER}/comfyui-h3-novita"

echo "=== host ==="; uname -a; nproc; free -g | head -2
echo "=== disk before ==="; df -h /

export DEBIAN_FRONTEND=noninteractive
if ! command -v podman >/dev/null 2>&1; then
    echo "=== installing podman ==="
    apt-get update -qq
    apt-get install -y -qq podman git ca-certificates
fi
podman --version

echo "=== clone repo ==="
rm -rf /build
git clone --depth 1 "$REPO" /build
cd /build

install -m 600 /dev/null /tmp/hf_token
printf '%s' "$HF_TOKEN" > /tmp/hf_token

echo "=== docker login ==="
printf '%s' "$DOCKER_PASS" | podman login docker.io -u "$DOCKER_USER" --password-stdin

echo "=== build (MODEL_SET=$MODEL_SET TORCH_INDEX=$TORCH_INDEX INSTALL_SAGE=$INSTALL_SAGE) ==="
podman build \
    --format oci \
    --secret id=hf_token,src=/tmp/hf_token \
    --build-arg MODEL_SET="$MODEL_SET" \
    --build-arg TORCH_INDEX="$TORCH_INDEX" \
    --build-arg INSTALL_SAGE="$INSTALL_SAGE" \
    -t "${IMAGE}:latest" \
    -t "${IMAGE}:${MODEL_SET}-${TORCH_INDEX}" \
    -f Dockerfile .

echo "=== image size ==="
podman images "${IMAGE}"
podman image inspect "${IMAGE}:latest" --format '{{.Size}}' | awk '{printf "%.2f GB\n", $1/1e9}'

echo "=== push ==="
podman push "${IMAGE}:latest"
podman push "${IMAGE}:${MODEL_SET}-${TORCH_INDEX}"

rm -f /tmp/hf_token
echo "=== disk after ==="; df -h /
echo "REMOTE BUILD COMPLETE"
