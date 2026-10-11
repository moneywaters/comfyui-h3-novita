# Novita AI deployment report — comfyui-h3-novita

## Objective
Rebuild the Podman image containing the config UI (ComfyUI), models, nodes and
workflows entirely inside the container; download models **at image-build time**
(never onto the local machine); pre-warm the image in the Novita console; then
rent a 4090 and confirm the pre-warmed image generates video.

## Artefacts

| Thing | Value |
|---|---|
| GitHub repo (build) | `github.com/moneywaters/comfyui-h3-novita` (public) |
| Image | `docker.io/moneywaters/comfyui-h3-novita:latest` |
| Image size / layers | **84.35 GB / 42 layers**, linux/amd64 |
| Prewarm task | `j44pvpgb53i41vep` — **Succeeded**, cluster `US-CA-06 (California)`, 205.8 min |
| Instance | `44396e8c31f521f9` — RTX 4090 24GB, on-demand, `US-CA-06` |
| ComfyUI URL | https://44396e8c31f521f9-8188.us-ca-6.gpu-instance.novita.ai |
| SSH endpoint | `proxy.us-ca-6.gpu-instance.novita.ai:63842` |

## Build strategy (and why)

The finished image is 84.35 GB, but a GitHub-hosted runner has only ~43 GB free
(measured). Downloading models locally was explicitly forbidden and the local Mac
has 20 GB free. So the image is built in **independent parts**, each small enough
for a runner, then stitched back together **at the registry**:

```
env         10.35 GB  CUDA 13.0.1 + torch cu130 + ComfyUI + 18 custom node packs
h3diff-fl2va 20.96 GB  MiniMax H3 fl2va pruned int8   (video workflow default)
h3diff-ref2va 20.96 GB MiniMax H3 ref2va pruned int8  (Seed Hunter uses ref2va)
h3enc       14.88 GB  qwen3vl-32b minimax h3 nvfp4 text encoder
h3aux        9.91 GB  video VAE int8 + video VAE fp16 + audio VAE fp32 + 3 LoRAs
seedvr2      7.29 GB  SeedVR2 3B fp16 + VAE
```

`ops/compose-image.py` merges them: every part is built `FROM` the same
`nvidia/cuda:13.0.1-cudnn-runtime-ubuntu24.04`, so their leading 10 layers are
byte-identical to the env image's. The composer drops that shared prefix on each
part and appends only each part's **new** layers onto the env image's layer list,
then PUTs the resulting manifest to the registry. Verified: config `36040 B`,
manifest `7118 B`, 42 layers, `diff_ids` == layers, ENTRYPOINT/CMD and
`22/tcp`+`8188/http` preserved.

Models are fetched in `build/models-part.sh` via `curl` with `HF_TOKEN` supplied
as a BuildKit **secret**, so the token never lands in a layer.

## Results on the rented 4090

- `nvidia-smi` / `system_stats`: **RTX 4090, 25.25 GB VRAM, 24.79 GB free**, 66.6 GB RAM
- ComfyUI **0.37.0** serving on `:8188` (HTTP 200), `comfy-kitchen 0.2.35` loaded
- Models resolvable through ComfyUI's own `object_info`:
  - `UNETLoader`: `minimax_h3_fl2va_pruned_int8_convrot`, `minimax_h3_ref2va_pruned_int8_convrot`
  - `CLIPLoader`: `qwen3vl_32b_minimax_h3_nvfp4_awq`
  - `VAELoader`: `minimax_h3_video_vae_int8_convrot`, `minimax_h3_video_vae_fp16`, `minimax_h3_audio_vae_fp32`
- sshd listening on 22 (container entrypoint starts sshd + ComfyUI together)
- Live MiniMax H3 text-to-video submitted through `POST /prompt`

## Notes / deviations

- **No US-CA-06 pre-warm before this task** — the earlier pre-warm list was
  truncated by my own `head`, which made the cluster look absent. US-CA-06 exists
  (id `us-ca-6`) and does host 4090s. Corrected.
- **Spot was unavailable**: every 4090 spot `create` returned
  `INSUFFICIENT_RESOURCE` even though the product list said `availableDeploy=true`.
  Proven to be cluster capacity, not our image — a tiny `nvidia/cuda` image also
  failed in `us-ca-6`. On-demand succeeded on the first attempt at $0.33/hr
  (spot would be $0.17/hr). Account balance $10.00.
- **Prewarm has no progress API.** The docs expose only
  `Pending | Running | Succeeded | Failed`; there is no byte/percent field and no
  per-task endpoint. `ops/prewarm-monitor.sh` polls state + elapsed instead.
- **Docker Hub rate limiting was ruled out**: `x-ratelimit-limit: 100;w=3600`,
  remaining 99. Only manifest requests count — one pull = 1 manifest + 42 blobs,
  so >100 simultaneous nodes would be needed. The 205-minute prewarm is purely the
  84.35 GB payload.
- Running the job on GitHub's small runner **OOM-killed** the SageAttention
  compile; it is therefore off by default (`install_sage=0`) and bounded
  (`MAX_JOBS=1`, 2 archs, 40-min timeout) if enabled.
- `curlimages/curl` is musl-linked, not static — model parts install `curl` via apt.
- Pre-creating `/opt/ComfyUI` in the apt layer broke `git clone`; removed.
- The two `fl2v` turbo LoRAs were added to `models-part.sh` *after* `h3aux` had
  been built, so they are not in the current image. The shipped Seed Hunter
  workflow uses `minimax_h3_ref2v_turbo_4step_v0.1`, which **is** present.

## Reproduce

```bash
# build (per-part, parallel) + compose + push
gh workflow run build.yml -R moneywaters/comfyui-h3-novita \
  -f parts='["env","h3diff-fl2va","h3diff-ref2va","h3enc","h3aux","seedvr2"]' \
  -f model_parts='h3diff-fl2va,h3diff-ref2va,h3enc,h3aux,seedvr2' \
  -f torch_index=cu130 -f install_sage=0

# prewarm in the 4090 cluster, then watch
ops/novita.sh prewarm docker.io/moneywaters/comfyui-h3-novita:latest us-ca-6
ops/prewarm-monitor.sh

# deploy + verify
ops/novita.sh balance
ops/novita.sh deploy-wait us-ca-6 4090     # spot; use create for on-demand
```
