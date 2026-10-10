#!/bin/bash
# Best-effort SageAttention build (the Seed Hunter workflow uses PathchSageAttentionKJ).
# Non-fatal: if this fails the image still builds and ComfyUI still runs.
set -uo pipefail

PIP=/opt/comfyui-venv/bin/pip
PY=/opt/comfyui-venv/bin/python3

echo "--- installing nvcc + CUDA dev headers (runtime base has no compiler) ---"
if ! command -v nvcc >/dev/null 2>&1; then
    apt-get update -qq || true
    apt-get install -y --no-install-recommends \
        cuda-nvcc-13-0 cuda-cudart-dev-13-0 cuda-cccl-13-0 libcurand-dev-13-0 \
        2>&1 | tail -3 || echo "WARN: cuda dev packages not installed"
    rm -rf /var/lib/apt/lists/* || true
fi
command -v nvcc && nvcc --version | tail -2 || echo "WARN: nvcc still missing"

# torch>=2.14 + nvcc 13 needs CCCL headers and the ctk compat check disabled
export CCCL_DISABLE_CTK_COMPATIBILITY_CHECK=1
export TORCH_CUDA_ARCH_LIST="8.0;8.6;8.9;9.0;12.0+PTX"
export MAX_JOBS="${MAX_JOBS:-4}"
$PIP install --no-cache-dir nvidia-cuda-cccl 2>/dev/null || true

# libcudart.so dev symlink so the linker can resolve -lcudart
SITE=$($PY -c "import site;print(site.getsitepackages()[0])" 2>/dev/null || echo "")
for d in $SITE/nvidia/cuda_runtime/lib /usr/local/cuda/lib64; do
    [ -d "$d" ] || continue
    for f in "$d"/libcudart.so.*; do [ -e "$f" ] && ln -sf "$f" "$d/libcudart.so"; done
done

echo "--- building SageAttention from source ---"
rm -rf /tmp/SageAttention
git clone --depth 1 https://github.com/thu-ml/SageAttention.git /tmp/SageAttention || exit 0
cd /tmp/SageAttention || exit 0
sed -i 's/c++17/c++20/g' setup.py 2>/dev/null || true
$PIP install --no-cache-dir --no-build-isolation . 2>&1 | tail -15

$PY -c "from sageattention import sageattn; print('sageattention import OK')" \
    || $PIP install --no-cache-dir sageattention 2>&1 | tail -5 || true
rm -rf /tmp/SageAttention
