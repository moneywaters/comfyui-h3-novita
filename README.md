# comfyui-h3-novita

ComfyUI + **MiniMax H3** (video) + **Qwen-Image 2.1** (image edit) + **SeedVR2** (upscale)
baked into a single GPU-container image for **Novita AI** instances.

Everything the workflows need lives *inside* the image: the ComfyUI UI, all custom nodes,
all model weights, and the workflow JSONs. No runtime downloads.

## What's inside

| Layer | Contents |
|---|---|
| Base | `nvidia/cuda:13.0.1-cudnn-runtime-ubuntu24.04` |
| Runtime | Python 3.12 venv (`/opt/comfyui-venv`), PyTorch `cu130`, NVENC-capable `ffmpeg` |
| App | ComfyUI pinned at `8d534945` (v0.37.0) + 18 custom nodes |
| Models | MiniMax H3 *ref2va* int8 · qwen3vl-32b nvfp4 text encoder · H3 video/audio VAE · H3 ref2v turbo LoRA · SeedVR2 3B + VAE |
| Workflows | `Minimax_Seed_Hunter_v2.1.json`, `Qwen_Image_2.1_Integrated_Image_Editing_v1.5.json` |
| SSH | `openssh-server`, root key login (Novita console key + a baked fallback key) |

Models are downloaded **at image-build time** into image layers. Nothing is ever pulled to a
local machine. The Hugging Face token is passed as a build **secret** so it never lands in a layer.

## Model set

`MODEL_SET=video` (default) — ~52 GB, everything needed for MiniMax H3 video generation + SeedVR2 upscaling.

`MODEL_SET=all` — adds Qwen-Image 2.1 int8 + text encoders + VAE (~27 GB more) for the image-editing workflow.

## Build

Built by GitHub Actions (`.github/workflows/build.yml`) which uses **Podman** and pushes to
Docker Hub. Required repository secrets:

| Secret | Meaning |
|---|---|
| `DOCKER_USER` | Docker Hub user (`moneywaters`) |
| `DOCKER_PASS` | Docker Hub PAT |
| `HF_TOKEN` | Hugging Face token with access to `Comfy-Org/MiniMax-H3` |

Manual build:

```bash
printf '%s' "$HF_TOKEN" > /tmp/hf_token
podman build --secret id=hf_token,src=/tmp/hf_token \
  --build-arg MODEL_SET=video --build-arg TORCH_INDEX=cu130 \
  -t moneywaters/comfyui-h3-novita:latest .
```

## Run on Novita

Image: `moneywaters/comfyui-h3-novita:latest`
Exposed ports: `22/tcp`, `8188/http`
The container starts `sshd` and ComfyUI (`0.0.0.0:8188`) together.
