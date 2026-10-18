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


## Model substitutions — Seed Hunter v2.5.1

The workflow shipped referencing a 21 GB fine-tune and a 21 GB fl2va model. The server
already had Comfy-Org's **ref2va pruned int8**, so both references were remapped onto it
instead of downloading 42 GB more.

| workflow reference | size | replaced with | why |
|---|---|---|---|
| `Minimax-h3_Singularity_ref2va_Pruned_v1.3_int8.safetensors` | 20.97 GB | `minimax_h3_ref2va_pruned_int8_convrot.safetensors` (**already on the server**) | Singularity is a *fine-tune of ref2va*; same architecture, same int8-convrot quantisation, same pruned shape. This is a true analog. |
| `minimax_h3_fl2va_pruned_int8_convrot.safetensors` | 20.97 GB | same existing ref2va file | **no fl2va exists on the server.** Pointed at ref2va so the graph validates and runs. |

Two nodes were remapped (ComfyUI reads `widgets_values_named`, not `widgets_values` —
missing that dict is why the first attempt silently did nothing):
1. node 171, the *live* "Load Models & Patches" subgraph instance — this is the one that runs
2. the subgraph definition's `UNETLoader` default — still validated by ComfyUI even though
   the instance overrides it

Verified after the change: **0 functional references to either missing file**, 13 references
to the existing ref2va.

### Consequence worth knowing
fl2va is trained for first/last-keyframe conditioning and is the higher-quality half of the
hybrid; ref2va adds reference conditioning. With only one H3 diffusion model present, the
`MiniMaxH3HybridLoader` node (fl2va base + ref2va overlay) has nothing to merge, so that
hybrid path is unavailable. If you want it later, the single missing piece is
`minimax_h3_fl2va_pruned_int8_convrot.safetensors` (20.97 GB).

### Still downloading (as instructed: small files kept)
| file | size |
|---|---|
| `loras/minimax_h3_ref2v_turbo_4step_v0.1_v4_step600_dareties_fro0995.safetensors` | 1.16 GB |
| `vae/minimax_h3_video_vae_int8_convrot.safetensors` (Kijai) | 3.17 GB |

Already fetched: `taeh3.safetensors` (9 MB), `loras/MINIMAX/minimax_h3_DMAD_4step_..._bf16` (350 MB).


## Launching a prewarmed US-CA-06 box

`~/novita-comfy.sh` (source: `ops/novita-comfy.sh`) — one command to get a running
ComfyUI on the prewarmed cluster:

```bash
~/novita-comfy.sh            # start (or reuse) + print and open the GUI URL
~/novita-comfy.sh status     # instance, endpoints, prewarm state
~/novita-comfy.sh url        # just the GUI URL
~/novita-comfy.sh ssh        # interactive shell (via the HTTP CONNECT proxy)
~/novita-comfy.sh stop       # delete the instance
```

Defaults: cluster `us-ca-6` (US-CA-06), image `.../comfyui-h3-novita:sha-260882616d3e`,
name `seedhunter-prewarmed`, rootfs 200 GB, billing `auto` (spot, then on-demand).
Override with `NOVITA_CLUSTER`, `NOVITA_IMAGE`, `NOVITA_BILLING`, `NOVITA_PRODUCT`,
`NOVITA_INSTANCE_NAME`, `NOVITA_ROOTFS`, `NOVITA_NO_OPEN=1` (don't auto-open).

Because US-CA-06 is prewarmed, `start` is near-instant — no 83 GB pull.
The default image is the content tag `:sha-260882616d3e`.

## The stale-cache bug, and the fix

**Symptom.** A prewarm task reported `Succeeded` (83.00 GB) and an instance booted
from us-ca-6 in seconds — but it was running the *first* build: the v2.1 workflow,
no Singularity, one LoRA, an empty latent-upscaler list.

**Cause.** The prewarm was created on the mutable tag `:latest`. Docker Hub's
`latest` did point at the new digest (`sha256:260882…`, 57 layers — verified), but
the cluster node still had the **old digest cached under that tag name**, so
starting from cache silently served stale layers. Nothing in the prewarm API
surfaces this: `state=Succeeded` and a matching `imageSize` are both consistent
with the wrong content.

**Fix (three parts).**
1. `ops/compose-image.py` now publishes a **content-derived tag** in addition to
   `--out`: `sha-<first 12 hex of the manifest digest>`, and logs
   `USE FOR PREWARM/DEPLOY: <repo>:sha-…`. A tag whose name encodes the digest
   cannot be re-pointed at different bytes, so a prewarm on it is either current or
   absent — never stale.
2. `ops/novita-comfy.sh` warns in preflight when the image is a mutable tag
   (`:latest`, `:main`, `:clore`) and names the content tag to use instead.
3. `ops/retag.py` creates an immutable tag from an existing one without re-uploading
   layers (used to mint `v2.5.1`, and to mint content tags).

The existing us-ca-6 prewarm runs on `:v2.5.1`, which is already immutable.

Content tags minted for the already-published images via `retag.yml` (run on a
GitHub runner, because Docker Hub is unreachable from the dev Mac — see below):

| image | tag | digest | size |
|---|---|---|---|
| `comfyui-h3-novita` | `sha-260882616d3e` | `sha256:260882616d3e…` | 83.00 GB / 57 layers |
| `comfyui-qwen-novita` | `sha-827d623639cd` | `sha256:827d623639cd…` | 46.78 GB / 41 layers |

Both were verified round-trip (PUT 201, re-read digest matches).

### The cluster cache is keyed by REFERENCE, not digest

Prewarming `:sha-260882616d3e` — the *same digest* as the already-prewarmed
`:v2.5.1` — started a **full 83 GB re-pull**. So a prewarm is cached per image
*reference* (tag), not per content digest. This is the whole explanation for the
original bug: re-prewarming an existing tag name (`latest`) could leave the node's
old layers in place, while the API reported `Succeeded`.

**Policy:** prewarm exactly the reference you intend to deploy, and never rely on
re-pushing an existing tag. Prefer the content tag, since it cannot be re-pointed.


### Build determinism

Re-running the build with an unchanged image definition produced a **different
manifest digest** (`sha-289174e82568` then `sha-b300518d0c68`; same 57 layers, same
83.00 GB, config blob 46112 B vs 46109 B). Podman records `created` timestamps in the
config, so a rebuild is never byte-identical. Consequence: **every env rebuild
produces a new content tag, which invalidates the prewarm** — budget a re-prewarm
(~12-30 min) after any image change.

### Two build bugs found and fixed

1. **Seed Hunter v2.5.1 had a red node.** `ThreeWaySwitch` was missing from the
   image. `ControlAltAI-Nodes` was documented as baked in but was never in
   `build/nodes.sh`. Added, and `verify-env.sh` now asserts the classes the shipped
   workflows need are registered, so a best-effort clone that silently fails aborts
   the build.
2. **Image B could not compose.** Every part — including the `qwen-*` ones — is
   pushed to the `IMAGE_A` repository, but B composed with `--env part-env` resolved
   in B's own repo and died with `MANIFEST_UNKNOWN`. The workflow now passes
   `--parts-repo` pointing at image A.

Current tags:

| image | content tag | digest | size |
|---|---|---|---|
| `comfyui-h3-novita` | `sha-289174e82568` | `sha256:144f9ad28217…` | 83.00 GB / 57 layers |
| `comfyui-qwen-novita` | `sha-bbf34a62c728` | `sha256:bbf34a62c728…` | 46.78 GB / 41 layers |

### Shadowrocket must be ON to reach Novita

Novita resolves through Shadowrocket's tunnel (`utun5`, `198.18.0.1`, system proxy
`127.0.0.1:1082`) to a fake IP (`198.18.0.33`). With the tunnel down *and* the proxy
still configured, every HTTPS request dies with `SSL_ERROR_SYSCALL` — including
connections made straight to Novita's real IPs. Docker Hub behaves the same, and
`auth.docker.io` is blocked even with the tunnel up. Net: **registry work belongs on
GitHub Actions; Novita work needs the tunnel up.**


### v2.5.1 was desynced from image A

Commit `71cb638` ("Remap v2.5.1 onto the existing ref2va") rewrote the workflow's
HybridLoader `unet_name` from `Minimax-h3_Singularity_ref2va_Pruned_v1.3_int8` to
`minimax_h3_ref2va_pruned_int8_convrot` — the Comfy-Org model, which is **in image B,
not A**. That remap was a stopgap from when the two 21 GB downloads were cancelled;
the Singularity plan was executed afterwards, but the workflow was never reverted.

Image A ships `Minimax-h3_Singularity_ref2va_Pruned_v1.3_int8` +
`minimax_h3_fl2va_pruned_int8_convrot`, so the baked workflow pointed at a model that
does not exist in A.

`63dc6bf:workflows/Minimax_Seed_Hunter_v2.5.1.json` is **byte-identical to the
workflow supplied at** `/Users/asan/Downloads/minimaxH3SEEDHUNTERLatent_v251.json`
(md5 `62a802dd3d19f293e15d144dde09c5c7`) and is the version consistent with image A.
It has been restored.

Verified on image `sha-289174e82568`:

* all 53 workflow node types resolve — `ThreeWaySwitch` included, 0 missing
* `taeh3.safetensors` is in `models/vae_approx/` (from the `h3extra` part)
* `minimax_h3_latent_upscaler_3d_conv_v1_fp16.safetensors` is in
  `models/latent_upscale_models/`
* both `Minimax-h3_Singularity…` and `minimax_h3_fl2va…` are in `models/diffusion_models/`

> Note: `POST /userdata/<file>` on ComfyUI takes a **raw body**, not multipart. A
> multipart upload returns 200 but saves the MIME preamble, producing invalid JSON
> and a silent 235-byte bloat.


## The UI stuck on the "Comfy" logo

**Symptom.** The web UI shows the ComfyUI logo forever and never becomes usable, on
every instance, direct or tunnelled, regardless of image.

**Investigation.** Driving Orca's embedded browser against the page and reading the
console plus the network log:

* the server is fine — `/extensions` answers in ~10 ms, `/object_info` in ~0.6 s, and
  every one of the 319 extension scripts serves in 1-2 ms when fetched on the box
* the transport is lossy over a remote proxy: fetching all 318 extension files at
  browser-like concurrency took 155 s with **14 hard failures** (4.4%), and the
  browser does not retry a failed `<script>`
* the app **is** mounted under the overlay: `#vue-app` has children, `window.app`
  exists, the graph is initialised, and the canvas renders at ~60 FPS
* removing `#splash-loader` by hand reveals a complete, working ComfyUI

**Root cause.** The frontend removes the splash only when the extension store's
`spinner` flag goes true -> false. From the entry bundle:

```js
let t = H(), r = a(() => t.spinner)
oe(r, (e, t) => { t && !e && document.getElementById('splash-loader')?.remove() },
   { flush: 'post' })
```

If any extension script fails to load, the flag never clears, so a fully functional
UI stays covered by the loading overlay.

**Fix.** `build/patch-frontend.sh` rewrites the `#splash-loader` rule in
`comfyui_frontend_package/static/index.html` to `display:none!important` (-105 bytes).
It is tolerant of a frontend that has no splash at all and fails loudly if the rule
exists but cannot be matched. `verify-env.sh` asserts the patch is present, so the
build breaks rather than shipping a UI that can hang on the logo.

Not affected by this: the API, the WebSocket (works over HTTP/1.1), workflow
execution, or image contents. This is purely the loading overlay.


## PPIO (second GPU platform)

PPIO sells the same SKU names as Novita (`4090.16c62g`, …) and its prewarm API is a
near-copy: `POST /openapi/v1/image/prewarm` with
`{imageUrl, repositoryAuth, clusterId, productIds, note}`, a **100 GB per-image cap**
and a **5-task quota** (verified: `perImageSize: 100`, `limit: 5`).

### Access is via MCP, not the API key

The API key supplied for PPIO returns `401 UNAUTHORIZED / "key not found"` on every
endpoint (`https://api.ppio.com/gpu-instance/openapi/v1/…`), including the correct
base path — so it is not valid for this platform. It is not a header or base-path
problem: bare `Authorization: <key>` yields `authorization not found` and other bases
yield `404`, i.e. the route is right and the key is wrong.

What does work is PPIO's **hosted MCP server**, which is OAuth-based rather than
key-based:

```bash
cmd mcp add --transport http --scope user ppio https://mcp.ppio.com/mcp
```

It registers an OAuth client and completes the browser authorization automatically.
Tokens land in `~/.commandcode/mcp-tokens.json` and refresh on their own. The server
exposes two tools, `search` (query the OpenAPI spec) and `execute` (run JS against
the API), so all PPIO work goes through `mcp__ppio__execute`.

Two practical notes:

* The MCP **truncates responses at ~6000 tokens**, and `/openapi/v1/products` returns
  every GPU at once well past that. Filter inside the JS and return only what you need
  (`rows.filter(x => /4090/.test(x.name))`) rather than fetching the whole list.
* Its JSON can contain raw control characters, so a strict `json.loads` on a dumped
  payload fails — parse leniently.

### Skills

PPIO publishes official skills; both are installed globally
(`~/.commandcode/skills/{ppio-docs,ppio-sandbox}`):

```bash
cmd skills add PPIO/ppio-skills -s ppio-docs    --global
cmd skills add PPIO/ppio-skills -s ppio-sandbox --global
```

`ppio-docs` is a reference/router skill (LLM, sandbox, GPU, integrations, FAQ); it
defers to `https://raw.githubusercontent.com/PPIO/ppio-skills/main/skills/...` and
treats pricing/availability as dynamic data. It carries no prewarm or spot detail.

### 4090 spot landscape

`billingMethod` is a query param on `/openapi/v1/products`. As of this run:

| billingMethod | 4090 SKUs | deployable |
|---|---|---|
| `spot` | `4090.16c62g`, `4090.16c62g.os`, `4090.16c125g`, `4090.16c96g.v2` | none |
| `onDemand` | + `4090.16c125g.nas` | `4090.16c62g`, `4090.16c62g.os` |

25 clusters total, **14 carry a 4090**, and 8 of those are in the spot region list:
`as-sgp-2`, `cn-south-1`, `eu-gb-1`, `eu-ger-2`, `jp-tyo-2`, `oc-au-1`, `sa-br-1`,
`us-ca-6`.


### ops/ppio_pick.py and the TTY rules it had to learn

The picker is a dependency-free arrow-key menu (`fzf`, `dialog` and `whiptail` are all
absent). Three things bit it, all worth remembering for any interactive shell tool:

* **The UI cannot go to stdout.** The caller captures the picker with `$(...)`, which
  makes stdout a *pipe* — the menu would be swallowed into the variable rather than
  shown. So the menu is drawn on `/dev/tty` and only the chosen id goes to stdout.
* **`/dev/tty` is not seekable.** A single `open("/dev/tty", "r+")` raises
  `UnsupportedOperation: File or stream is not seekable`; it must be opened twice, once
  for read and once for write. Raw mode set through the read handle still applies to the
  terminal as a whole, because termios state is per-tty, not per-fd.
* **Read keys as raw bytes.** A text-mode handle applies universal-newline translation,
  which rewrites a CR keypress so Enter never matches `"\r"` and the menu looks like it
  ignores Enter (verified: LF selected, CR did nothing). `os.read(fd, 1)` fixes it.

Verified through a real pty: Down/Down/Enter and a digit jump both land on the right row,
`q` cancels with exit 130, and with no terminal the picker says to pass a location
explicitly rather than hanging.


### ops/ppio-api.sh — the REST variant

`ops/ppio.sh` reaches PPIO through the OAuth MCP server because the first API key was
rejected. That key has since been replaced with a working one, so `ops/ppio-api.sh`
does the same job over plain REST:

```
https://api.ppio.com/gpu-instance/openapi/v1    Authorization: Bearer $PPIO_API_KEY
```

Identical command surface, no MCP, no OAuth, no `ppio_mcp.py` — just `curl`. It reuses
`ppio_pick.py` for the menu, so `questionary` is still required. The key defaults to the
one in the script and can be overridden with `PPIO_API_KEY`.

**Spot vs on-demand is the thing that matters here.** For the same cluster and SKU the
two disagrees, and querying `/products` without `billingMethod` reports *on-demand*
availability — which is why an earlier launch said `4090.16c62g deploy=True` and then got
`INSUFFICIENT_RESOURCE`:

| cluster `us-ca-6`, SKU `4090.16c62g` | `availableDeploy` |
|---|---|
| `billingMethod=spot` | **false** |
| `billingMethod=onDemand` | **true** |

So every availability check now passes `billingMethod` (default `spot`, overridable with
`PPIO_BILLING`), and `create` uses the same billing mode it checked. On-demand genuinely
allocates in us-ca-6; spot does not.

### Two portability traps

* **`$0` is not a path.** With `sh ppio.sh` (a bare relative name) `exec "$0"` searches
  `PATH` and dies with `exec: ppio.sh: not found`. Both scripts now compute
  `SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"` and re-invoke through that.
* **No bash 4 syntax.** macOS ships bash 3.2, so `${VAR^^}` fails with
  `bad substitution` under `sh`. Use the plain value.


### New tag: sha-a43885f9a8b4 (compiler + correct workflow)

Two runtime failures prompted this build:

**1. `RuntimeError: Failed to find C compiler`.** The Dockerfile had *deliberately*
dropped gcc when SageAttention was removed, on the theory that nothing builds from source
any more. That was wrong: Triton compiles its `CudaUtils` shim on first use, and on a 4090
torch picks Triton impls for `_native` ops. It kills the entire H3 text-encode path:

```
MiniMaxH3ReferenceToVideo -> clip.encode -> llama.precompute_freqs_cis
  -> torch._native.bmm_outer_product -> triton -> cc -> "Failed to find C compiler"
```

Fixed by installing `gcc g++ python3-dev` and asserting `cc --version` in the Dockerfile.

**2. `ERROR: VAE is invalid: None` / `Value not in list`.** Two separate causes:

* the baked workflow's `Load Models & Patches` subgraph pointed `UNETLoader` at
  `minimax_h3_ref2va_pruned_int8_convrot` — the Comfy-Org model that lives in image B,
  not A. Restored to fl2va + Singularity.
* `taeh3` is a **preview** VAE (`models/vae_approx`); selecting it in a `VAELoader`
  can only ever fail. It belongs in `ModelPreviewOverrideKJ.tiny_vae`, which is where the
  correct workflow already puts it. The real VAEs are `minimax_h3_video_vae_int8_convrot`
  and `minimax_h3_audio_vae_fp32`.

`verify-env.sh` now parses the workflow and checks **loader values** across the graph and
subgraph definitions. A first attempt grepped the file for the ref2va filename and failed
the build on a false positive, because the workflow also carries a markdown note that
links to that model.

### ops/ppio-swap.sh

Swapping onto a new image has an unavoidable window: the cluster has one free 4090, and
the card only frees when the old instance is deleted — so deleting by hand and then typing
the create leaves a gap someone else can take. `ppio-swap.sh` does every fallible check
first (image resolves, prewarm is Succeeded, a product exists) and only then deletes and
creates back-to-back in one process.

A subtlety it encodes: while your own instance holds the card, `/products` reports nothing
deployable, so a naive capacity check would refuse forever. A running instance on that
cluster is itself the evidence, so the strict gate only applies when nothing is running.

`--dry-run` shows the full plan without touching anything; it refuses to swap onto a cold
(non-prewarmed) image.


### Why the GUI takes ~87s every time (and now won't)

Measured a cold load on the new instance: **87 seconds, 828 requests**, broken down as
**693 Script** + 155 Fetch + 23 Image. ComfyUI's cache middleware is the cause:

```python
# middleware/cache_middleware.py
if request.path.endswith(".js") or request.path.endswith(".css") or is_entry_point:
    response.headers.setdefault("Cache-Control", "no-store")
```

**Every `.js` and `.css` is served `no-store`** (images get `max-age=86400`). ComfyUI does
that so a frontend update lands immediately, but it means *nothing* is ever reused: each
page load re-downloads all ~690 modules, and over a remote host's proxy at ~0.5-1s per
request that is ~87s, every single time. It is not a one-off cost.

Request attribution (of the 693 scripts):

| source | requests |
|---|---|
| **ComfyUI-Pixaroma** | **419** |
| frontend bundle | 62 |
| rgthree-comfy | 53 *(workflow never uses it)* |
| ComfyUI-Custom-Scripts | 37 *(unused)* |
| ComfyUI-KJNodes | 26 |
| cg-use-everywhere | 20 *(unused)* |
| ComfyUI-Manager | 18 *(unused at runtime)* |
| ComfyUI-Impact-Pack | 7 *(unused)* |

Pixaroma alone is 60%: its `WEB_DIRECTORY="./js"` holds 91 subdirectories (89 `index.js`
plus 330 `.mjs` shared modules) and `/extensions` lists every one, so the browser loads
all of it even though the workflow touches only 5 of its node types.

**Fix applied:** `build/patch-cache.sh` changes that branch to
`public, max-age=86400`. Caching hard is safe *here specifically* because every instance
gets its own hostname (`<instanceId>-8188.<cluster>.gpu-instance.<domain>`), so the
browser cache is scoped to one instance — a new image is a new origin, so stale JS can
never be served against a different build. First load still pays the download; every
later one comes from cache.

Not yet done: trimming Pixaroma's `js/` to the subdirectories the workflow needs
(~11 of 91) would cut ~360 requests off even the *first* load. Left alone for now because
it means deleting files inside a third-party pack and risking its widgets.

### Why it doesn't start the instant the image is ready

Measured on the previous swap: instance `createdAt` **09:13:26** → ComfyUI's python process
start **09:23:33**. That is **10.1 minutes** during which the API already reported the
instance as `running` — the status flips long before the container is serving. So the
sequence is ~10 min of provisioning/pull/unpack with an optimistic `running` flag, then a
~2s python start, then the ~87s page load.

This is also why an earlier note in this report claiming a swap came up "in ~20 seconds"
was wrong: that measured the API status, not readiness.


### Result of the caching fix, and one thing I could not verify

The headers are right now:

```
/extensions/ComfyUI-Pixaroma/help_browser/index.js
  cache-control: public, max-age=86400
/extensions/ComfyUI-KJNodes/js/...        public, max-age=86400
/assets/index-CKO20XHW.js                 public, max-age=86400
```

But driving Orca's embedded browser, a reload still issued 976 requests with 964 × `200`
and only 3 × `304`. That is what a **cache-disabled automation context** looks like, and
I could not rule that out from here, so I am not claiming the browser-cache win is proven
in a real browser — only that the response headers now permit it.

There are two classes of asset here, and they differ:

* **Core assets** (anything served by ComfyUI's own `web.static`, i.e. the frontend bundle)
  carry `ETag` + `Last-Modified` and honour conditional requests — verified:
  `If-None-Match: "18ddc2510546f000-ca2"` returns **304** with a 0-byte body. So these
  have a working revalidation fallback.
* **Pixaroma's 419 modules** (served by its own custom route) carry `max-age` but
  **no `ETag` and no `Last-Modified`** — asking with either header returns a full `200`
  again. `max-age` alone has to carry those, with no 304 fallback.

So the honest position: the headers on every asset now permit caching, and core assets
additionally revalidate correctly. Whether a real browser takes the win is the part I
could not confirm from here — see above.

### Instance start-up: ~10 minutes before anything is listening

From the previous swap: instance `createdAt` **09:13:26** → ComfyUI's python process start
**09:23:33** = **607s**. The API flips to `running` long before the container is serving,
which is why "running" in the console does not mean "usable". The measured phases are:

| phase | time |
|---|---|
| create -> ComfyUI python start | ~10 min (provision, pull, unpack) |
| python start -> server listening | ~2 s |
| first page load (cold) | ~87 s |

Prewarming did not remove the ~10 minutes, only the image-download part of it. That is
worth setting expectations against: a fresh instance is ~10 min from click to usable.


### Limiting loaded custom nodes without a rebuild (PPIO `command`)

Goal: fewer extension requests by loading only the packs Seed Hunter v2.5.1 needs.
Answer: **no rebuild needed** — the PPIO create API's `command` field overrides the image
CMD, so the flags can be passed at instance-creation time.

Two traps, both hit and both now handled:

1. **`--whitelist-custom-nodes` is `nargs='+'` — SPACE separated, not commas.**
   ```python
   # comfy/cli_args.py:216
   parser.add_argument("--whitelist-custom-nodes", type=str, nargs='+', default=[], ...)
   ```
   Passing `"A,B,C"` makes it ONE entry that matches no directory, so ComfyUI logs
   `Skipping ...` for *every* pack — including the ones you meant to keep. The whole
   server comes up with zero custom nodes.
2. **`command` replaces `/opt/start.sh`, which is what starts sshd** and does the runtime
   key injection. So a bare ComfyUI command line silently costs you SSH. The replacement
   therefore starts sshd itself; the key is already baked into the image's
   `/root/.ssh/authorized_keys` (verified: 1 line), so SSH still works.

Working form (452 chars, well under the 2047 limit), with `entrypoint` left alone so
`tini --` still reaps:

```
command: /bin/bash -c "cd /opt/ComfyUI && /usr/sbin/sshd -D -e -f /etc/ssh/sshd_config &          exec /opt/comfyui-venv/bin/python3 main.py --listen 0.0.0.0 --port 8188          --preview-method auto --disable-all-custom-nodes --whitelist-custom-nodes          <pack dirs, space separated>"
```

**Verified on a throwaway as-sgp-2 instance** (created, measured, deleted; the live
us-ca-6 instance was never touched):

| | with flags | without |
|---|---|---|
| extension scripts | **185** | 319 |
| workflow node types resolving | **53 / 53** | 53 / 53 |
| SSH | open | open |
| rebuild required | no | — |

The whitelist holds exactly the ten packs the workflow uses, nothing else:

```
ComfyUI-Easy-Use  ComfyUI-Fantastic-MiniMaxH3-PromptBuilder  ComfyUI-H3-Prompt-IDE
ComfyUI-KJNodes   ComfyUI-MiniMaxH3Mod   ComfyUI-Pixaroma   ComfyUI-VFI
ComfyUI-VideoHelperSuite  Comfyui_Minimax_h3_latent_Upscaler  ControlAltAI-Nodes
```

`ComfyUI_MinimaxH3HybridLoader` is deliberately *not* in the list: the image ships it, but
the workflow contains no `Hybrid` node at all (grep count 0) — the subgraph uses plain
UNETLoader/CLIPLoader/VAELoader nodes.

Wire it up with `PPIO_LIMIT_NODES=1 ./ops/ppio-api.sh launch us-ca-6`.

Caveat: this disables ComfyUI-Manager too, so the Manager panel is gone. That is the point
of "nothing else", but it means no in-browser node installation on that instance.


### HybridLoader needs matching key prefixes (found the hard way)

Wiring `Load Models & Patches` to `MiniMaxH3HybridLoader` (fl2va base + Singularity overlay)
failed at execution:

```
RuntimeError: MiniMax H3 hybrid loader: the two checkpoints have different key sets,
cannot hybridise.
base-only    = ['adaln_t_table', 'blocks.0.adaln_proj.linear.weight', ...]
overlay-only = ['model.diffusion_model.adaln_t_table', 'model.diffusion_model.blocks.0...']
```

Both files hold the **same 932 tensors**; Singularity is packaged with the
`model.diffusion_model.` prefix and the Comfy-Org fl2va is not. ComfyUI's stock loaders
normalise that prefix internally, which is why a plain `UNETLoader` never cared — but the
hybrid merges key-by-key and refuses.

**Fix:** `build/normalize-models.sh` strips the prefix. It rewrites **only the JSON
header** — safetensors offsets are relative to the data section, so padding the shorter
JSON with spaces keeps the header the same byte length and every offset valid. No tensor
data is read or moved; the file size is unchanged (20,967,647,456 both before and after)
and it costs milliseconds. Verified idempotent, and both files end with 932 keys, 0
prefixed.

It runs from `start.sh` at container boot rather than at build time, because the models
live in their own build part — baking the change would mean re-downloading 20 GB. That is
a deliberate trade-off worth revisiting if the models ever move into the env part.

After normalising, the hybrid loads:

```
[MiniMaxH3Hybrid] base=minimax_h3_fl2va_pruned_int8_convrot.safetensors
                  overlay=Minimax-h3_Singularity_ref2va_Pruned_v1.3_int8.safetensors
                  preset=block_range_adaln blocks=25..49
Prompt executed in 0.15 seconds
```

Settings follow the node's README recommendation for higher ref2va quality: fl2va as base,
ref2va as overlay, `block_range_adaln`, blocks 25..49. `ComfyUI_MinimaxH3HybridLoader` was
added to the `PPIO_LIMIT_NODES` whitelist accordingly.


### Why the loading screen stalls: /object_info without compression

Measured on the deployed instance:

| | time |
|---|---|
| `/` (20 KB) | 1.9 s |
| `/extensions` | 2.2 s |
| **`/object_info` (3.55 MB)** | **84.5 s** |

Locally the same request takes **0.20 s**, so the server is fine — it is pure throughput on
a large payload over a high-latency link (~42 KB/s effective).

ComfyUI had response compression **off** (`main.py ... --enable-compress-response-body` was
not in the args; `Accept-Encoding: gzip` returned the identical 3,554,279 bytes). Enabling
it on a test server:

| | bytes |
|---|---|
| `/object_info` uncompressed | 3,554,279 |
| `/object_info` gzip | **388,812** (9.1x smaller) |

So the loading screen's worst stall goes from ~84s to ~9s. `--enable-compress-response-body`
is now in `start.sh`, and also in the `PPIO_LIMIT_NODES` command so it applies with no
rebuild.

Worth noting the whitelist compounds with this: with packs disabled `/object_info` is
3,190,770 bytes instead of 3,554,279 before compression, and 389 KB after.



### novita-comfy.sh: dynamic image + warm-location picker

`ops/novita-comfy.sh` now follows the `ppio.sh` pattern. Bare invocation opens a TUI
listing the locations that have **both** a deployable 4090 right now **and** a `Succeeded`
prewarm for the image it is about to run; picking one launches there.

The image is no longer hardcoded. It is read back from `/image/prewarm` (newest successful
prewarm for `comfyui-h3-novita`), so the script cannot drift behind the prewarms the way
`:sha-289174e82568` did — that stale tag meant a cold 83 GB pull even though the cluster
was warm. `NOVITA_IMAGE` still pins one by hand.

Commands are now `menu` (default), `launch`, `clusters`, `products`, `prewarm-list`,
`prewarm`, `instances`, `deploy-wait`, `create`, `status [id]`, `url`, `ssh`,
`stop`, `delete <id>`. The old `start` behaviour is kept as an alias.

**Two bugs fixed along the way, both of which silently emptied the location list:**

1. `live_capacity` ran 14 concurrent `curl`es through `xargs -I{} sh -c ... >> "$tmp"`.
   Appends are not atomic, so records interleaved mid-JSON (one merged line came out
   30 KB long) and most clusters were dropped. Now each cluster writes its own file and
   the reader walks the directory. The same bug was in `ppio-api.sh`; fixed there too.
2. `ppio-api.sh`'s menu reader called `os.path.join` without importing `os`, so every
   cluster raised `NameError` straight into `except Exception: continue` — the menu could
   never list anything. Also fixed.

`ppio_pick.py` gained a `PICK_TITLE` env var so both launchers share one picker.











### One codebase, two tags: weights baked for PPIO/Novita, code-only for SimplePod

The image now answers a single question at boot — **are the weights already on disk?** —
instead of trying to detect the platform. That makes one Dockerfile serve all three.

| tag | contents | size | who runs it |
|---|---|---|---|
| `:latest` / `:sha-<id>` | code only | 12.9 GB | SimplePod (its hosts cannot unpack our ~20 GB layers) |
| `:models` / `:sha-<id>-models` | weights baked in | ~83 GB | PPIO and Novita, which prewarm it for instant boots |

Both tags carry identical code, including `fetch-models-boot.sh`. On `:models` the weights
are present and it returns immediately; on `:latest` they are absent and it downloads them
from Hugging Face once, after which a container restart reuses them.

**Why not platform sniffing.** I could detect SimplePod from `/app` or `/workspace` mounts,
but that is a guess, and a wrong guess means either a customer waiting 40 GB of downloads
they did not need, or a container that cannot start. Making the tag carry the answer is
explicit: the operator chooses the trade-off by choosing the tag, and the image still
behaves correctly if that choice is ever wrong.

**Dockerfile.env gains `ARG BAKED_MODELS`.** The weights RUN is deliberately its own
instruction, so a code-only build never carries that layer, and a failed part fails the
build rather than shipping a half-baked image.

**The workflow builds both, then asserts they differ the right way:** `:latest` must have
zero model files over 100 MB, `:models` must have some, and both must carry the boot
scripts. If both tags ever come out the same, a platform is silently broken — so it fails
the build instead.

**Builder hardening from the first attempt.** `h3-fl2va`, `h3-singularity` and `h3enc`
downloaded fine (55 GB) but `h3vae-kijai` failed with `WARN download failed`. The file
exists and serves (verified: HTTP 302 to the CDN), so it was a stalled transfer that
curl's own `--retry` does not recover from. The fetcher now wraps curl in an outer attempt
loop with **`-C -` resume**, so a 20 GB transfer that dies at 90% continues instead of
restarting, and the bake loop retries a failed part once before giving up.

### The image is code-only; weights come from Hugging Face at boot

**This is the design now, and it replaces the chunking approach.** Chunking was the wrong
fix: it kept ~62 GB of weights in the image and only shuffled them into smaller layers.

The image ships **no model weights at all**. `build/fetch-models-boot.sh` runs from
`start.sh` and downloads them from Hugging Face on a fresh instance; on a container restart
they are already on disk and it returns immediately.

**What this fixes.** SimplePod's hosts would not unpack our ~20 GB model layers — their
console looped `Preparing instance / Pulling image` forever while `diskUsage` stayed 0.00
and the container never started. Reproduced on host 216 (RTX 4090) and host 161 (RTX 3090),
at 100 GB and 200 GB disk, while a 7 GB control image booted on those same hosts in ~300s.
A code-only image has no such layers, so it pulls anywhere.

**What it costs.** A fresh instance downloads ~40 GB of weights once before its first
generation, and needs `HF_TOKEN` set on the instance/template `envVariables`. A restart of
the same container reuses the on-disk weights and pays nothing. For PPIO and Novita this
also means the prewarm now caches a ~7 GB image instead of ~86 GB.

**Removed:** `Dockerfile.models`, `build/chunk-model.sh`, `build/stitch-models.sh`,
`build/stitch-models.py`, `ops/compose-image.py`, `ops/check-sizes.py`, `ops/retag.py`.
The split-build/compose machinery existed only to assemble huge model layers, so it goes
with them. `build/models-part.sh` stays — it is the Hugging Face fetcher the boot path calls.

**The workflow is now one job:** build `Dockerfile.env`, assert no model file over 100 MB is
baked in (failing the build if one is, so the property cannot silently regress), then push
both image names with a content tag.

**`build/models-source.sh`** went from platform-detection to a simpler and more honest
question — *are the weights already present?* It reports `baked` (present, skip the download)
or `download` (absent, fetch), with `BULK_MODELS_SOURCE` to force either. Verified: weights
absent → download, weights present → baked, forced values honoured.

### Why the first chunked build did not change the layer shape

The build went green and the log clearly showed chunking working — "19998 MB -> 6 chunks of
<=3500 MB", "removed the original (reassembled at boot)", and the verify step printed
`OK  no model file over 4 GB`. But the pushed images were unchanged:

| tag | layers | largest |
|---|---|---|
| sha-9ba51985e251 (before) | 63 | 20.96, 20.95, 14.88, 7.28, 5.20 |
| sha-c87358278e8d (after) | 78 | **20.95**, 20.95, 14.87, 7.28, 5.20 |

Still five layers over 4 GB, and the part images showed the same single 20.95 GB layer.

**Cause: the download and the chunking were in the SAME `RUN`.** podman diffs a layer by
what the *instruction created*, not by its final state, so the 20 GB safetensors —
downloaded and then split and deleted inside one instruction — was still captured whole.
`compose-image.py` appends only the trailing layers a part adds, so the fat layer that
should have been dropped was in fact the only one being kept.

**Fix:** `Dockerfile.models` now has the fetch as one `RUN` and the chunking as the next.
The 20 GB file lands in its own layer, which compose drops, leaving the ~3.5 GB chunks.

**And a check that can actually catch this:** the previous verification ran on the env
image, where no models exist yet, so it could never see a bad part layer. The models image
now asserts, in the same `RUN` that chunks, that `find ... -size +4G` is empty and **fails
the build** if any model file is still oversized.

Validated without a daemon: the Dockerfile parses to 11 well-formed instructions and the
new chunk `RUN` body passes `sh -n`. Also corrected `ARG PART=h3diff`, a default that never
matched any real PART.

### Platform-aware weights: baked on PPIO/Novita, downloaded on SimplePod

SimplePod will not unpack this image's ~21 GB layers, so the baked weights are unreachable
there. Rather than maintain two images, the image now decides at boot where its weights
come from — `build/models-source.sh` — and only SimplePod takes the slow path.

**How the platform is decided, explicit first:**

1. `BULK_MODELS_SOURCE=baked|download` — wins outright. SimplePod templates and instances
   both accept `envVariables`, so the launcher can simply say so. Never guess when you can
   be told.
2. `SIMPLEPOD=1` (or `SIMPLEPOD_INSTANCE*`) — set by the SimplePod launcher's start script.
3. Filesystem sniffing, for a hand-made template: `/app/data`, `/workspace`,
   `/usr/local/bin/entrypoint.sh`, `/opt/simplepod-login`. Every match is logged with its
   reason so a false positive is diagnosable rather than mysterious.
4. Otherwise **baked**, because PPIO and Novita prewarm this image and a fast boot is the
   whole point.

The answer goes to stdout, the reasoning to stderr, and the decision is cached in
`/run/models-source`. Exit code is `0` for baked, `10` for download, so callers can branch.

Verified decision matrix: explicit download → download; explicit baked beats `SIMPLEPOD=1`
→ baked; `SIMPLEPOD=1` → download; nothing set → baked; `banana` → warns and falls back to
baked; `DOWNLOAD` → download (case-insensitive).

**The download path reuses `models-part.sh`,** which already is the Hugging Face fetcher
used at image-build time (per-file curl, 6 retries, a minimum-size check, `.partial`
staging). Reusing it means the boot and build paths cannot drift. It fetches a curated part
set by default — `h3-fl2va h3-singularity h3enc h3vae-kijai h3vae-audio h3loras h3extra
seedvr2`, i.e. what the shipped workflows actually need — so a SimplePod user is not billed
for waiting on Qwen weights for an H3 run. `MODELS_PARTS` overrides it.

Guards, all verified: no `HF_TOKEN` refuses with the exact `envVariables` snippet to add; a
space check against the nearest existing ancestor of the models dir refuses *before* a
20 GB write; a failed part is logged and ComfyUI still starts.

**One subtle bug this surfaced.** `models-part.sh` chunked unconditionally, so a boot
download would have split the files it had just fetched — and since the download path has no
stitch step, every model would have been invisible to ComfyUI. Chunking is now gated behind
`CHUNK_MODELS=1`, which only `Dockerfile.models` sets, so the gate defaults to the safe
answer for runtime callers.

**Also found:** `models-part.sh` and `chunk-model.sh` lived only in the models image, but the
runtime download calls them, so both are now COPYed into the env image too.

**Platform compatibility:** unchanged for PPIO and Novita — with no SimplePod signal the
script resolves `baked` and returns immediately, so their prewarmed boots pay nothing.

### The SimplePod blocker, and the chunked-weight fix

**What was proven.** Our 83.1 GB image will not unpack on SimplePod. Their console loops
`Preparing instance / Pulling image` every ~4 minutes forever; `dockerPullProgressBar`
reaches 100% each cycle, `diskUsage` stays 0.00, and the container never starts.

Reproduced on two different hosts and two disk sizes:

| host | GPU | disk | cycles | reached running | diskUsage |
|---|---|---|---|---|---|
| 216 | RTX 4090 | 100 GB | 5 | no | 0.00 |
| 216 | RTX 4090 | 200 GB | 3 | no | 0.00 |
| 161 | RTX 3090 | 200 GB | 4 | no | 0.00 |

A 7 GB control image on those *same* hosts boots in ~300s. So it is the image, not the
host, and not the disk size.

**The difference that matters is layer shape:** ours is 63 layers / 83.1 GB with single
20.96 GB layers; the control is 29 layers / 7.37 GB with nothing over a few GB. Each big
layer is one model file — docker stores them uncompressed, so a 20 GB safetensors becomes
a ~21 GB layer, and unpacking it needs that much scratch on the overlay the storage driver
writes to. Corroborated by an earlier SimplePod session in this repo's history where the
root overlay was 32 GB and died with `No space left on device`.

**The fix, and why it is lazy.** `build/chunk-model.sh` splits any weight over the
threshold into sub-4 GB `.partNNN` files at build time (verified: total chunk bytes must
equal the original, else the original is kept). `build/stitch-models.py` reassembles them
at boot, and it is deliberately scoped to `diffusion_models` only — the two ~20 GB files
that both broke SimplePod and get used first.

That scoping is what keeps **PPIO and Novita unaffected**: they already pull this image
and prewarm it successfully, so they must not pay a new cost. A model is only reassembled
when something asks for it, and `MODELS_REASSEMBLE_ALL=1` widens the scope if wanted.

Safety properties, all verified locally:
* byte-identical round trip (sha256 match on an 8 MB model split 3 ways)
* non-contiguous chunk sets are refused rather than silently concatenated
* a truncated destination is detected by size and rebuilt
* rebuild is atomic — temp file plus `os.replace`, so an interrupted boot cannot leave a
  corrupt model ComfyUI would try to load
* idempotent — a second run reports "0 built, 1 already present"
* chunks over 4 GB warn, because that is exactly the case that still fails on SimplePod

`verify-env.sh` now asserts the stitcher exists, that start.sh calls it, and reports the
real layer-shape facts (any unchunked model file over 4 GB is called out).

**Preserved:** `sha-5ec04390d8cb` (the build PPIO and Novita prewarm from) remains tagged,
along with 12 other `sha-*` tags. The content-tag scheme means a new build is always a new
tag — nothing is overwritten.

### SimplePod US-MN-01: our image cannot be pulled by that host

Tried the newest image A (`sha-9ba51985e251`, 83.1 GB) on US-MN-01 (host 216, RTX 4090,
$0.38/hr). **Unusable: the host re-pulls forever.**

The console loops every ~5 minutes:

```
12:08:11 Pulling image...
12:12:58 Preparing instance... / 12:13:00 Pulling image...
12:17:xx Preparing instance... / 12:17:xx Pulling image...
```

`dockerPullProgressBar` reaches **100% (82.89 GB)** every cycle, then restarts. `diskUsage`
stays 0.00, so nothing is ever written. No error is surfaced anywhere — only
Preparing/Pulling.

**It is not disk size.** First attempt at the template's default 100 GB, then a retry at
200 GB: identical loop. (My first diagnosis blamed the 100 GB disk; that was wrong, and 200
GB disproved it.)

**It is not the host or the network.** A control instance on the *same* host with the stock
`simplepodai/comfyui` image (7.37 GB, 29 layers) came up cleanly in ~300s and served the GUI:

* `status: running`, pull took ~12s
* `[INFO] Starting server / To see the GUI go to: http://0.0.0.0:8188`
* 8188: https://consortium-environments-talented-emotional.trycloudflare.com/simplepod-login
* direct: http://159.48.242.20:41813/simplepod-login

The host pulls the 83 GB **download** at 200-680 MB/s, so bandwidth is not the issue either.

**What is different about our image:** 63 layers, 83.1 GB, with single layers of 20.96 GB and
20.95 GB. The control has 29 layers totalling 7.37 GB and no layer over a few GB. The
download completes and the **unpack/storage step is what fails**, which points at that host's
storage driver handling a ~21 GB single layer -- but SimplePod exposes no docker error, so
this is the strongest supported inference, not a confirmed cause. (I checked for duplicated
layers; the size histogram shows no repeats, so that theory is dead.)

**Also learned, and useful regardless of host:** direct-IP access (`http://<ip>:41813`,
`ssh -p 41811`) is far faster than the trycloudflare proxy -- **TTFB 0.22s direct vs 1.9s
proxied, an 8x difference.** Any launcher for SimplePod should prefer the direct port.

**Only one Docker 4090 host exists in US-MN-01 (id 216),** so the image-vs-host question
cannot be separated by trying a second US-MN-01 host.

Templates left in place: `comfyui-h3 A (seedhunter)` (id 31996, 200 GB) pointing at
`moneywaters/comfyui-h3-novita:sha-9ba51985e251`. No instances left running.

### Upload speed: it is the local VPN tunnel, not the image

Reported as "ridiculous upload speed, surely some kind of error". Measured, and it is not a
bug in the image, in ComfyUI, or on the GPU host.

**Isolating the server.** I launched an `L40S` on PPIO with a *tiny* `python:3.12-slim`
container whose only job is to answer `ok` in about a millisecond -- no ComfyUI, no 83 GB
pull. Against that trivial server:

* TTFB was **1.3-2.0 s** for a handler that does nothing. So the latency is the path, not
  the application.
* An 8 MB upload ran at **622 KB/s** -- the same figure ComfyUI produces (0.6-0.85 MB/s).
  ComfyUI adds nothing measurable.

**Isolating the path.** The *same* 8 MB payload to Cloudflare, repeated:

| run | 1 | 2 | 3 | 4 | 5 | 6 |
|---|---|---|---|---|---|---|
| MB/s | 0.08 | 0.91 | 0.08 | 3.07 | 3.02 | 0.08 |

Identical bytes, identical endpoint, **37x swing**. That is loss and stalling, not a
bandwidth ceiling -- the path can do 3 MB/s, it just usually does not.

**What is in the path.** `route -n get default` -> `utun5`, and every destination resolves
into `198.18.0.x`, Shadowrocket's fake-IP range:

```
speed.cloudflare.com      198.18.0.142  via utun5
api.ppio.com              198.18.0.105  via utun5
<instance>-8188....ppinfra.com  198.18.0.140  via utun5
```

Binding to `en0` to escape the tunnel cannot reach the internet at all (every attempt timed
out at 75 s), so the tunnel is the only egress from this machine.

**Things that do NOT help (measured, so do not ship them):**

* **Parallel uploads.** 4 x 2 MB gave **0.34 MB/s aggregate** versus 0.62 MB/s for a single
  stream -- concurrency made it worse, which fits tunnel saturation rather than a
  per-stream cap. The `bulk_io` uploader stays sequential on purpose.
* **Server-side tuning.** The server receives exactly what the tunnel delivers; the timing
  middleware's handler duration matches the client's own measurement to within 20%.
* **Compression.** Video is already compressed.

**The fix** is to stop routing the GPU hosts through the tunnel -- a Direct rule in
Shadowrocket for `ppinfra.com` and `novita.ai`. I did not apply it: the domain rules live in
`default.db.rule`, an obfuscated `SDAT=3` blob, and the SQLite `rule.db` next to it stores
its sections as binary blobs while being held open by the Shadowrocket GUI (pid 1716) with a
live 32 KB `-wal`. Editing either from outside a running app risks being overwritten or
corrupting the rule set, so this one belongs in the Shadowrocket UI.

`ops/netprobe.sh` reproduces the whole measurement against any instance URL.

### First measured GUI load (the answer to "why is it slow")

`/debug/timing` on a live instance, after a full page load of the whitelist build
(`--disable-all-custom-nodes --whitelist-custom-nodes`, 186 extensions):

| class | requests | total ms | avg ms | bytes |
|---|---|---|---|---|
| js | 609 | 2,739 | 4.5 | 7.76 MB |
| json | 291 | 5,334 | 18.3 | 13.0 MB |
| object_info | 7 | 981 | 140.2 | 6.50 MB |
| css | 11 | 123 | 11.2 | 0 |
| asset | 6 | 1.0 | 0.2 | 0 |
| websocket | 1 | 254,784 | -- | 0 (long-lived `/ws`) |

**~917 requests, and the server spends only ~9.2s total on them.** So the first load is
not slow because the server is slow -- it is slow because 917 requests each pay a
round-trip through the host proxy. The earlier TTFB measurement (1.2s) is almost entirely
network: the handler itself averages 4.5ms for a JS module and 18.3ms for a JSON call.

That is why the cache patch helps so much on loads 2+ (no requests at all) and why the
whitelist matters for load 1 (320 -> 186 extensions). It also means the remaining lever for
a cold load is request count, not server tuning.

Also visible: the `/ws` entry is one long-lived socket held for the whole session (254s),
so it must be read as a constant, not as a slow request. And `/api/object_info` is 3.25 MB
per call as measured by the middleware, which sits *before* `compress_body` in the chain --
so that figure is the uncompressed size, not what the browser transfers.

Download button verified too: it reports `no upscaled_batch.zip yet (HTTP 404) — run the
workflow first — the zip is rebuilt after each run`, on screen, rather than failing
silently.

### bulk_io: the upload/download status was invisible (root cause)

Symptom: the file picker opens, you choose files, and the upload bar never changes.

Cause, measured in the live page on `sha-cdb9137a0634`: the status line was a normal text
widget with `disabled = true`. The current frontend (frontend 1.53.6, Vue node renderer)
draws a disabled text widget as an **empty greyed field**, and assigning `widget.value` from
JS does not repaint it either. Setting `status.value = "PROBE-VISIBLE-VALUE"` put the string
in the model and **nowhere in the DOM** (`innerTextHasProbe: false`,
`anyInputHasProbe: false`). A screenshot of the node shows the field rendered blank.

So uploads were frequently succeeding while showing nothing at all. Verified end to end:
firing the real change event with a File produced `uploaded 1/1 to input/videos`, and
`POST /api/upload/image` returns 200 from curl and from the page.

Fixes in `build/bulk_io/web/bulk_io.js`:

* status is now an `addDOMWidget` div we own; `textContent` updates are immediate
  (verified: `initialVisible: true`, `updatedVisible: true`, and visible in a screenshot)
* uploads use `XMLHttpRequest` instead of `fetch`, because only XHR exposes
  `upload.onprogress` -- so the line shows `uploading 42% 18.2/43.5 MB` live and then
  `0.12 MB/s · ~6s left` (verified: 4 progress ticks at 4/55/69/100%)
* failures are no longer swallowed: HTTP status and response body are shown, and an empty
  selection says so instead of returning silently
* `input.value` is reset on every path, so re-picking the same file always fires `change`
* the hidden `<input>` is created once per node and removed in `onRemoved`; it used to be
  appended on every `onNodeCreated` and never cleaned up (six were live after a few loads)

**Why uploads feel slow: the link, not the code.** Measured against this instance,
`POST /upload/image` runs at ~0.1-0.56 MB/s (1 MB in 10.4s; 4 MB in 7.4s; a 120 MB body
stalled at 32 MB after 240s). A 500 MB video is therefore 15+ minutes per file. The progress
line now makes that visible instead of looking hung.

**Same measurement explains the slow first GUI load:** TTFB is ~1.2s (connect is only 25ms)
and the page pulls ~700 module requests, so a cold load is ~700 x 1.2s spread over the
browser's connection limit. The cache patch only helps loads 2+; the whitelist
(`PPIO_LIMIT_NODES=1`) cuts the request count and has not yet been used on any instance.

### Request timing: measuring the slow GUI load instead of guessing

The earlier caching/compression round shipped fixes with no way to measure them, so "the
GUI is still slow" had no data behind it. `build/patch-timing.sh` adds
`middleware/timing_middleware.py` plus three edits to `server.py`: an import, a slot for
`request_timing` at the head of the middleware chain, and `GET /debug/timing`.

It logs every request slower than `COMFY_TIMING_SLOW_MS` (250ms) with duration, bytes and
path; keeps per-class and per-path totals; and returns the summary as JSON. So after a page
load:

    curl -s <gui-url>/debug/timing | python3 -m json.tool

which splits the load into websocket / object_info / js / css / json / asset / other with
request counts, total and average ms, and the 25 slowest paths. The middleware swallows its
own exceptions so it can never take the server down. `verify-env.sh` asserts the file, the
registration and the route (23 checks now).

**Note on what is NOT yet baked in.** `--disable-all-custom-nodes --whitelist-custom-nodes`
exists only as a create-time `command` override in `ppio-api.sh`; a plain launch still loads
all 22 packs and ~319 extension scripts. Seven of those packs are not referenced by either
shipped workflow (`ComfyUI-Manager`, `ComfyUI-Impact-Pack`, `comfyui_controlnet_aux`,
`cg-use-everywhere`, `ComfyUI-Custom-Scripts`, `rgthree-comfy`,
`ComfyUI-Frame-Interpolation`, `ComfyUI-MiniMax-H3-W4A4-VSA`), and each ships frontend
scripts that the browser must fetch.

### SeedVR2 bulk upscale workflow (handoff/SEEDVR2_BULK_HANDOFF.md)

Shipped `Naxci1-SeedVR2.5-Auto-Manuel-BULK.json` (28 nodes / 33 links) plus everything it
needs, so a user can multi-select local videos, queue once, and download a ZIP of the
results:

* **`bulk_io`** -- our own pack (§4), COPYed rather than cloned: `BulkVideoUpload`
  (multi-file picker -> ComfyUI's own `POST /upload/image`) and `DownloadAllZip`
  (one-click ZIP of the output folder). Its `web/bulk_io.js` renders both buttons.
* **`ComfyUI-BatchFolderTools`** -- `FolderVideoLoader_BFT` (folder iterator) +
  `QueueNext_BFT` (self-requeue, so one Queue Prompt walks the batch).
* **`ComfyMath`** -- `CM_IntToFloat` / `CM_FloatToInt`.
* **SeedVR2 cache patch** (`build/patch-seedvr2.sh`, §5): rewrites the truthiness tests in
  `src/core/model_configuration.py` to `is not None`. Unpatched, the *second* run in a
  batch raises `TypeError: CompatibleDiT does not support len()` because a torch.compile'd
  OptimizedModule's `__len__` throws.
* **DVB deliberately absent**: the workflow replaces its For-Each nodes, and it pins
  numpy<2.

Widget values verified against §6.2: `cache_model=true` on both SeedVR2 loaders,
`attention_mode="sdpa"` (note `flash_attn` is not a valid option), `format="video/h264-mp4"`
(no NVENC on this box, so an nvenc format writes a 0-byte file), `batch_size=5` (must be
4n+1), and `SeedVR2TorchCompileSettings` bypassed (mode 4). The upscaler carries the current
12-widget signature, so no drift.

`verify-env.sh` now asserts the packs, the `cv2` import, the patch, the classes
(`BulkVideoUpload`, `DownloadAllZip`, `FolderVideoLoader_BFT`, `QueueNext_BFT`,
`CM_IntToFloat`, `CM_FloatToInt`, `JoinStrings`), the workflow file, and that DVB is absent
-- 19 checks in total.

The `PPIO_LIMIT_NODES` whitelist is now the union of both shipped workflows' packs (15).


**The handoff's §5 snippet is wrong and only half-works.** It says to replace both
`if cached_model:` and `if cached_vae:`. In the real source there is no `cached_vae` test —
upstream reuses the SAME local name for both branches:

```
595:  cached_model = global_cache.get_dit(...)   ->  596:  if cached_model:   # DiT
615:  cached_model = global_cache.get_vae(...)   ->  616:  if cached_model:   # VAE
```

So the snippet's second replacement matched nothing and only the DiT site was fixed, while
the VAE site — the one that actually crashes a batch — stayed broken. `patch-seedvr2.sh`
replaces **every** bare `if cached_model:` site (verified: 2 of 2, 0 remaining) and
`verify-env.sh` asserts none survive. The first build failed precisely on that assertion,
which is how this was caught rather than shipped.

### Prewarms created

Image `docker.io/moneywaters/comfyui-h3-novita:sha-289174e82568` (83.00 GB, resolved
server-side as `82995082446` bytes — under the cap), targeting the four 4090 spot SKUs:

| cluster | location | id |
|---|---|---|
| `us-ca-6` | US-California-06 | `td4yl3iu5nntxphk` |
| `as-sgp-2` | Asia-Singapore-02 | `jh6oxuvdqnt52wle` |
| `jp-tyo-2` | Asia-Japan-02 | `6z2niercdkb9262h` |
| `eu-ger-2` | Europe-Germany-02 | `juvqfm0ewybwf4ct` |
| `cn-south-1` | China-South-01 | `4h5ufdtjlaaehl6l` |

Quota is now 5 of 5. Three of the eight spot clusters (`eu-gb-1`, `oc-au-1`,
`sa-br-1`) were left un-prewarmed for lack of slots.


### ops/ppio.sh

A PPIO counterpart to `ops/novita.sh`. **Running it bare opens a dropdown menu of every
location that has a 4090**, and launches a 4090 SPOT instance in whichever one you pick:

```bash
./ops/ppio.sh clusters                          # clusters, flagging the ones with a 4090
./ops/ppio.sh products 4090 spot                # stock + region count (also onDemand/monthly)
./ops/ppio.sh prewarm-list                      # quota + tasks
./ops/ppio.sh prewarm [image] [cluster] [pids]  # create a prewarm
./ops/ppio.sh prewarm-wait <taskId>
./ops/ppio.sh instances
./ops/ppio.sh                                   # pick a location, launch 4090 spot (default)
./ops/ppio.sh menu                              # same, explicitly
./ops/ppio.sh --wait                            # poll us-ca-6 for 4090, then launch
./ops/ppio.sh launch [cluster] [4090]           # skip the menu
./ops/ppio.sh deploy-wait [cluster] [4090]      # poll for capacity, then create
./ops/ppio.sh create <cluster> <productId> [rootfs] [name]
./ops/ppio.sh status|ip|delete <instanceId>
```

Because there is no usable API key, it does not use curl. All calls go through
`ops/ppio_mcp.py`, a small JSON-RPC client that reuses the MCP OAuth token from
`~/.commandcode/mcp-tokens.json`; it prints the API `data` as JSON so the shell can
format it exactly like a REST response. If the token is stale it says so and points
at `cmd mcp auth ppio`.

Two PPIO/MCP quirks it handles:

* results are **doubly wrapped** — the JSON-RPC result's `content[0].text` is itself a
  `{"content":[{"text": ...}]}` envelope, so a single unwrap yields an envelope string
  rather than the value (this is what made the first version print
  `string indices must be integers`)
* the **~6000-token truncation**, so every subcommand filters inside the JS and returns
  only the fields it prints

**Spot behaves exactly like Novita's** — the platform advertises capacity it does not
have. `products ... spot` and even `/products?clusterId=us-ca-6` report
`availableDeploy: true` for `4090.16c62g` and `4090.16c62g.os`, yet
`instance/create` comes straight back with `INSUFFICIENT_RESOURCE`. `launch` detects
that refusal and points at `deploy-wait` rather than pretending it succeeded.

## Prewarm state

Quota is 5 tasks, and it is now full. Build A (`sha-289174e82568`) is prewarmed in
four clusters; build B (`sha-cac7104aef86`) in one.

| cluster | image | state | took |
|---|---|---|---|
| `us-ca-6` — US-CA-06 (California) | A `sha-289174e82568` | Succeeded | 29.0m |
| `us-dallas-nas-2` — US-Dallas-NAS-02 | A `sha-289174e82568` | Succeeded | 6.5m |
| `as-sgp-2` — AS-SGP-02 (Singapore) | A `sha-289174e82568` | Succeeded | 18.5m |
| `eu-ger-2` — EU-GER-02 (Germany) | A `sha-289174e82568` | Succeeded | 18.4m |
| `us-ca-6` — US-CA-06 (California) | B `sha-cac7104aef86` | Succeeded | 66.5m |

`us-ca-nas-2` was dropped to make room for B: it reports no products at all.

### Where a 4090 is actually available

Availability is not the same as "has a prewarm". Of the clusters the API lists, only
**`1` (US-01 Dallas)** and **`us-dallas-nas-2`** expose a 4090 product right now;
`us-ca-6`, `as-sgp-2` and `eu-ger-2` currently offer only L40S. So the only cluster
that is both prewarmed *and* has a 4090 is **`us-dallas-nas-2`**. `1` (US-01 Dallas)
has 4090s but no prewarm.

### Prewarm throughput varies a lot

In the same cluster and the same window, the 83.00 GB image A pulled at ~47.7 MB/s
(29.0 min) while the 46.78 GB image B managed only ~12.2 MB/s (66.5 min) — 4x slower
for a smaller image. Both ended `Succeeded` with no error; the difference looks like
node/peer congestion rather than anything about the image. Worth remembering when
judging whether a prewarm is stuck: this one was not, just slow.

## Reproduce

```bash
gh workflow run build.yml -R moneywaters/comfyui-h3-novita -f torch_index=cu130

ops/novita.sh prewarm docker.io/moneywaters/comfyui-h3-novita:latest us-ca-6   # and 4 more
ops/prewarm-monitor.sh

ops/novita-ssh.sh --list
ops/novita-ssh.sh <instanceId> nvidia-smi
```
