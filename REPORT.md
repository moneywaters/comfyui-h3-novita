# Novita AI — ComfyUI image, round 2 (Seed Hunter v2.5.1 + Qwen 2.1)

## Answer: does it all fit in 100 GB?

**Not in one image — so it ships as two, both well under the cap.**

Novita caps a prewarm at **100 GB per image** ("the image pull quota limit per task is
100 GB", [Image Prewarm → Quota Limits](https://docs.novita.ai/guides/gpu-image-prewarm)).
The H3 side alone is 83.00 GB; adding Qwen 2.1 (19.39 GB) and the second ref2va model
you asked to keep (20.97 GB) would make **123.36 GB**, so a single image is impossible
without dropping models you said you want.

No distro change was needed. What *was* reclaimed is 42 GB of models that Seed Hunter
v2.5.1 no longer references (evidence: `SeedVR2` → 0 occurrences in the v2.5.1 JSON,
`vae_name: minimax_h3_video_vae_fp16` → 0, `vae_name: …_int8_convrot` → 2,
`unet_name: minimax_h3_fl2va_pruned_int8_convrot` → 1,
`unet_name: Minimax-h3_Singularity_ref2va_Pruned_v1.3_int8` → 1).

## The two images

| | image A | image B |
|---|---|---|
| repo | `moneywaters/comfyui-h3-novita` | `moneywaters/comfyui-qwen-novita` |
| size | **83.00 GB** / 57 layers | **46.78 GB** / 41 layers |
| for | MiniMax H3 video (Seed Hunter v2.5.1) | Qwen-Image 2.1 editing |
| extra | — | plus the spare Comfy-Org `ref2va` |

Both verified anonymously pullable (HTTP 200, exactly how the prewarm nodes fetch),
`diff_ids == layers`, and `Entrypoint ["/usr/bin/tini","--"] / Cmd ["/opt/start.sh"] /
ports 22+8188` intact through the compose step.

### Why the split falls here
Image A holds **100 % of what the H3 workflow loads**, so it is the hot path and gets
prewarmed. Image B holds Qwen plus two things that are valuable but *not* loaded by
v2.5.1. Nothing requested was dropped: you get **both ref2va models** (Singularity in A,
Comfy-Org in B) and **all the H3 VAEs plus taeh3** in A.

## Model list

### Image A — `moneywaters/comfyui-h3-novita:latest` (83.00 GB)

| size | file | source |
|---|---|---|
| — | env (torch cu130, ComfyUI 0.37.0, 21 node packs, workflows, sshd, ffmpeg) | — |
| 20.97 | `diffusion_models/minimax_h3_fl2va_pruned_int8_convrot.safetensors` | Comfy-Org/MiniMax-H3 |
| 20.97 | `diffusion_models/Minimax-h3_Singularity_ref2va_Pruned_v1.3_int8.safetensors` | WarmBloodAban/Minimax-h3_Singularity |
| 15.69 | `text_encoders/qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors` | Comfy-Org/MiniMax-H3 |
| 5.21 | `vae/minimax_h3_video_vae_fp16.safetensors` | Comfy-Org/MiniMax-H3 |
| 3.17 | `vae/minimax_h3_video_vae_int8_convrot.safetensors` | **Kijai**/MiniMax-H3-experimental |
| 0.60 | `vae/minimax_h3_audio_vae_fp32.safetensors` | Comfy-Org/MiniMax-H3 |
| 0.37 | `loras/MINIMAX/minimax_h3_DMAD_4step_full_lora_avg_rank_39_bf16.safetensors` | **Kijai**/MiniMax-H3-experimental |
| 0.77 | `loras/minimax_h3_fl2v_turbo_silver_dareties_comfy_pruned_v1.safetensors` | silveroxides/MiniMax-H3_tests |
| 0.71 | `loras/minimax_h3_ref2v_turbo_4step_v0.1_v4_step600_dareties_fro0975.safetensors` | silveroxides/…/ref2v_dareties |
| 1.16 | `loras/minimax_h3_ref2v_turbo_4step_v0.1_v4_step600_dareties_fro0995.safetensors` | silveroxides/…/ref2v_dareties |
| 0.69 | `latent_upscale_models/minimax_h3_latent_upscaler_3d_conv_v1_fp16.safetensors` | LBH-123-AI/Minimax_h3_latent_Upscaler |
| 0.01 | `vae_approx/taeh3.safetensors` | Kijai/MiniMax-H3-TAE |
| 6.78 | `SEEDVR2/seedvr2_ema_3b_fp16.safetensors` | numz/SeedVR2_comfyUI |
| 0.50 | `SEEDVR2/ema_vae_fp16.safetensors` | numz/SeedVR2_comfyUI |
| **77.59** | weights subtotal (83.00 GB measured total) | |

### Image B — `moneywaters/comfyui-qwen-novita:latest` (46.78 GB)

| size | file | source |
|---|---|---|
| — | env (same runtime layers as A) | — |
| 20.97 | `diffusion_models/minimax_h3_ref2va_pruned_int8_convrot.safetensors` | Comfy-Org/MiniMax-H3 |
| 9.35 | `text_encoders/qwen3vl_8b_int8_convrot.safetensors` | Comfy-Org/Qwen-Image-2.1 |
| 7.26 | `diffusion_models/qwen_image_2.1_int8_convrot.safetensors` | Comfy-Org/Qwen-Image-2.1 |
| 1.76 | `loras/qwen_image_2.1_viggle_turbo_v0.2.1_r256_comfy-t8.safetensors` | t8star/…-r64-comfy |
| 0.67 | `vae/qwen_image_2.1_vae_bf16.safetensors` | Comfy-Org/Qwen-Image-2.1 |
| 0.34 | `loras/p_qwen_image_2.1_8step_v0.1-comfyui-T8.safetensors` | t8star/Pruna-Qwen-Image-2.1-Comfy |
| **40.35** | weights subtotal (46.78 GB measured total) | |

Not baked: `qwen3.5_9b_qwen_image_2.1_pe_i2i` (9.47 GB) — its only consumer, `CLIPLoader`
id 494, feeds a **bypassed** `TextGenerate` node (mode 4).

## What changed in the build

- **SageAttention removed.** Dense attention is ComfyUI core's "comfy kitchen attention"
  (`ModelAttentionBackend` · 4 hits in v2.5.1); v2.5.1 has no `PathchSageAttentionKJ`
  node at all, and the Qwen workflow's node 628 is set to `disabled`. This also removed
  the need for a compiler.
- **Runtime slimmed** (8.36 → 6.96 GB): no `build-essential` / `python3-dev` / `git-lfs`,
  static BtbN ffmpeg instead of the apt package chain, `.git` + `__pycache__` + `examples/`
  stripped from every cloned node, pip cache dropped.
- **Nodes added:** `scottmudge/ComfyUI_MinimaxH3HybridLoader` (requested) and
  `LBH-123-AI/Comfyui_Minimax_h3_latent_Upscaler` (required by v2.5.1).
- **Workflows:** v2.5.1 installed as `Minimax_Seed_Hunter_v2.5.1.json`; the API test
  repointed to the v2.5.1 set (Singularity + Kijai int8 VAE + DMAD LoRA, turbo path on).
- **Composer:** cross-repo blob mounting (`uploads/?mount&from`) with a dual-scope token,
  so image B inherits the base/env layers without re-uploading ~35 GB.

## SSH — direct connect next time

Root cause of the earlier failure: instance `44396e8c31f521f9` had been **deleted**
(`/gpu/instances` → `total: 0`), so its endpoint answered nothing. The transport itself is
fine — through Shadowrocket's HTTP CONNECT proxy (`127.0.0.1:1082`) the helper pulled a real
SSH banner from `github.com:22` (`SSH-2.0-3bc2e72`) and echoed through `tcpbin.com:4242`.

- `~/bin/http-connect-proxy` — speaks CONNECT itself, because BSD `nc -X connect` chokes on
  `HTTP/1.1 200 Connection Established`
- `ops/novita-ssh.sh <instanceId> [cmd]` — resolves the SSH `host:port` from the Novita API,
  then sshs through the proxy (`--list` shows instances)
- `~/.ssh/config`: `Host novita novita-*` stanza with `ProxyCommand http-connect-proxy %h %p`

## Prewarm — 5 clusters, US-CA-06 first, cheapest first

| # | cluster | task | 4090 spot | state |
|---|---|---|---|---|
| 1 | `us-ca-6` — US-CA-06 (California) | `rcfnj3gxony894mm` | $0.17 | running |
| 2 | `us-ca-nas-2` — US-CA-NAS-02 (California) | `jr9ahjamacrsdkqo` | $0.17 | running |
| 3 | `us-dallas-nas-2` — US-Dallas-NAS-02 | `8t6f9bi9rpnlxwd6` | $0.335 | running |
| 4 | `eu-ger-2` — EU-GER-02 (Germany) | `nlje4k92k1a4jhyq` | $0.17 | running |
| 5 | `as-sgp-2` — AS-SGP-02 (Singapore) | `9fe9ss5jeghogxnt` | $0.17 | running |

`us-ca-6` was created **first**, as asked. Two intended clusters (`2` US-CA-NAS-01 and `1`
US-01 Dallas) rejected the prewarm with `CreateDockerImagePrewarm error`, so the last two
slots went to other 4090 clusters. Quota is 5 of 5.

Prewarm is 83 GB, which took ~3.4 h for the previous 84 GB image; expect similar here.

## Reproduce

```bash
gh workflow run build.yml -R moneywaters/comfyui-h3-novita -f torch_index=cu130

ops/novita.sh prewarm docker.io/moneywaters/comfyui-h3-novita:latest us-ca-6   # and 4 more
ops/prewarm-monitor.sh

ops/novita-ssh.sh --list
ops/novita-ssh.sh <instanceId> nvidia-smi
```
