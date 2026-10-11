#!/bin/bash
# Runs ON the Novita GPU instance (root), driven by .github/workflows/test-instance.yml.
# Verifies the pre-warmed image: GPU, sshd, ComfyUI, the baked models for BOTH
# workflows, and a real MiniMax H3 video generation with the v2.5.1 model set.
set -uo pipefail

API=http://127.0.0.1:8188
WF=/opt/ComfyUI/user/default/workflows/H3_t2v_api_test.json
M=/opt/ComfyUI/models
FAIL=0

echo "=================== 1. GPU ==================="
nvidia-smi --query-gpu=name,driver_version,memory.total --format=csv,noheader || { echo "BAD nvidia-smi"; FAIL=$((FAIL+1)); }

echo "=================== 2. SSH ==================="
# iproute2 is not installed in the image, so probe the socket with a bash builtin
if (exec 3<>/dev/tcp/127.0.0.1/22) 2>/dev/null; then
    echo "  OK sshd listening on 22 (/dev/tcp connect succeeded)"
    exec 3>&- 2>/dev/null || true
else
    echo "  BAD sshd not listening on 22"; FAIL=$((FAIL+1))
fi
[ -n "${SSH_CONNECTION:-}" ] && echo "  OK inbound SSH session: ${SSH_CONNECTION}"
echo "  user: $(whoami)  host: $(hostname)"

echo "=================== 3. ComfyUI ==================="
for i in $(seq 1 90); do
    [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$API/" 2>/dev/null)" = "200" ] && { echo "  ComfyUI up after ${i} tries"; break; }
    sleep 4
done
if [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$API/" 2>/dev/null)" != "200" ]; then
    echo "  BAD ComfyUI not responding; last 40 log lines:"; tail -n 40 /var/log/comfyui.log 2>/dev/null; FAIL=$((FAIL+1))
fi

echo "=================== 4. files on disk (v2.5.1 set) ==================="
check_file() {  # <path> <min-bytes> <label>
    if [ -f "$1" ]; then
        local s; s=$(stat -c%s "$1")
        if [ "$s" -ge "$2" ]; then printf '  OK  %-64s %6s MB\n' "$3" "$((s/1048576))"
        else printf '  BAD %-64s %6s MB (min %s)\n' "$3" "$((s/1048576))" "$(( $2/1048576 ))"; FAIL=$((FAIL+1)); fi
    else printf '  MISSING %s\n' "$3"; FAIL=$((FAIL+1)); fi
}
check_file "$M/diffusion_models/minimax_h3_fl2va_pruned_int8_convrot.safetensors" 20000000000 "H3 fl2va pruned int8"
check_file "$M/diffusion_models/Minimax-h3_Singularity_ref2va_Pruned_v1.3_int8.safetensors" 20000000000 "H3 Singularity ref2va pruned int8"
check_file "$M/text_encoders/qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors" 15000000000 "H3 qwen3vl-32b nvfp4 TE"
check_file "$M/vae/minimax_h3_video_vae_int8_convrot.safetensors" 3000000000 "H3 video VAE int8 (Kijai)"
check_file "$M/vae/minimax_h3_video_vae_fp16.safetensors" 5000000000 "H3 video VAE fp16"
check_file "$M/vae/minimax_h3_audio_vae_fp32.safetensors" 500000000 "H3 audio VAE fp32"
check_file "$M/loras/MINIMAX/minimax_h3_DMAD_4step_full_lora_avg_rank_39_bf16.safetensors" 350000000 "Kijai DMAD 4-step LoRA"
check_file "$M/loras/minimax_h3_fl2v_turbo_silver_dareties_comfy_pruned_v1.safetensors" 750000000 "silver fl2v dareties LoRA"
check_file "$M/loras/minimax_h3_ref2v_turbo_4step_v0.1_v4_step600_dareties_fro0975.safetensors" 690000000 "silver ref2v dareties fro0975"
check_file "$M/latent_upscale_models/minimax_h3_latent_upscaler_3d_conv_v1_fp16.safetensors" 680000000 "H3 latent upscaler 3D fp16"
check_file "$M/vae_approx/taeh3.safetensors" 9000000 "TaeH3 tiny VAE"
check_file "$M/SEEDVR2/seedvr2_ema_3b_fp16.safetensors" 6500000000 "SeedVR2 3B fp16"
check_file "$M/diffusion_models/qwen_image_2.1_int8_convrot.safetensors" 7000000000 "Qwen 2.1 diffusion int8"
check_file "$M/text_encoders/qwen3vl_8b_int8_convrot.safetensors" 9000000000 "Qwen 3vl-8b int8 TE"
check_file "$M/vae/qwen_image_2.1_vae_bf16.safetensors" 600000000 "Qwen 2.1 VAE bf16"

echo "=================== 5. ComfyUI sees the models ==================="
python3 - "$API" <<'PY' || FAIL=$((FAIL+1))
import json, sys, urllib.request
api = sys.argv[1]
oi = json.load(urllib.request.urlopen(api + "/object_info", timeout=240))
required = {
    ("UNETLoader", "unet_name"): ["minimax_h3_fl2va_pruned_int8_convrot.safetensors",
                                  "Minimax-h3_Singularity_ref2va_Pruned_v1.3_int8.safetensors"],
    ("CLIPLoader", "clip_name"): ["qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors",
                                  "qwen3vl_8b_int8_convrot.safetensors"],
    ("VAELoader", "vae_name"): ["minimax_h3_video_vae_int8_convrot.safetensors",
                                "minimax_h3_video_vae_fp16.safetensors",
                                "minimax_h3_audio_vae_fp32.safetensors",
                                "qwen_image_2.1_vae_bf16.safetensors"],
    ("LoraLoaderModelOnly", "lora_name"): ["MINIMAX/minimax_h3_DMAD_4step_full_lora_avg_rank_39_bf16.safetensors",
                                           "minimax_h3_fl2v_turbo_silver_dareties_comfy_pruned_v1.safetensors"],
}
# node classes the shipped workflows need
node_classes = ["ModelAttentionBackend", "BlockSparseAttention", "MiniMaxH3HybridLoader",
                "MiniMaxH3ReferenceToVideo", "MiniMaxH3ImageToVideo",
                "MiniMaxH3RefModsLoader", "MiniMaxH3MediaLoader"]
bad = 0
for (node, key), expect in required.items():
    try:
        opts = oi[node]["input"]["required"][key][0]
    except Exception as e:
        print(f"  BAD cannot read {node}.{key}: {e}"); bad += 1; continue
    for f in expect:
        ok = f in opts
        print(f"  {'OK ' if ok else 'BAD'} {node}: {f}")
        if not ok: bad += 1
print("  -- node classes --")
for c in node_classes:
    ok = c in oi
    print(f"  {'OK ' if ok else 'BAD'} {c}")
    if not ok: bad += 1
# latent upscaler is a custom-node combo, list it from its own node if present
for nm in [k for k in oi if "LatentUpscaler" in k]:
    try:
        opts = oi[nm]["input"]["required"]["model_name"][0]
        hit = "minimax_h3_latent_upscaler_3d_conv_v1_fp16.safetensors" in opts
        print(f"  {'OK ' if hit else 'BAD'} {nm}.model_name -> latent upscaler")
        if not hit: bad += 1
    except Exception:
        pass
sys.exit(1 if bad else 0)
PY

echo "=================== 6. live H3 generation (v2.5.1 model set) ==================="
python3 - "$API" "$WF" <<'PY' || FAIL=$((FAIL+1))
import json, random, sys, time, os, urllib.request, urllib.error
api, wf_path = sys.argv[1], sys.argv[2]
wf = json.load(open(wf_path))

# ComfyUI validates every node input, including branches the active switch never
# runs. Repoint any LoRA that is not in the image at one that is (dead branch when
# the turbo switch is off, so this cannot change the produced video).
oi = json.load(urllib.request.urlopen(api + "/object_info/LoraLoaderModelOnly", timeout=180))
avail = oi["LoraLoaderModelOnly"]["input"]["required"]["lora_name"][0]
for nid, node in wf.items():
    ins = node.get("inputs") or {}
    if "lora_name" in ins and ins["lora_name"] not in avail:
        print(f"  note: node {nid} lora {ins['lora_name']!r} not in image -> using {avail[0]!r}")
        ins["lora_name"] = avail[0]

# randomise the seed so this is a genuine generation, not a cache hit
seeds = []
for nid, node in wf.items():
    if node.get("class_type") == "RandomNoise":
        node["inputs"]["noise_seed"] = random.randrange(1, 2**31); seeds.append(nid)
print("  randomised seeds on:", seeds)
print("  unet:", wf["140:127"]["inputs"]["unet_name"])
print("  vae :", wf["140:119"]["inputs"]["vae_name"])
print("  lora:", wf["140:134"]["inputs"]["lora_name"])

def post(url, payload):
    req = urllib.request.Request(url, data=json.dumps(payload).encode(),
                                 headers={"Content-Type": "application/json"})
    return json.load(urllib.request.urlopen(req, timeout=60))

try:
    r = post(api + "/prompt", {"prompt": wf, "client_id": "h3-image-test"})
except urllib.error.HTTPError as e:
    print("  BAD /prompt rejected:", e.code); print(e.read().decode()[:2000]); sys.exit(1)
pid = r.get("prompt_id")
print("  prompt_id:", pid, "| queued:", r.get("number"))
if not pid: print("  BAD no prompt_id:", r); sys.exit(1)

t0 = time.time(); outputs = None
while time.time() - t0 < 3600:
    try: h = json.load(urllib.request.urlopen(f"{api}/history/{pid}", timeout=30))
    except Exception: h = {}
    if pid in h:
        rec = h[pid]; st = rec.get("status", {})
        if st.get("completed") or st.get("status_str") == "success" or rec.get("outputs"):
            outputs = rec.get("outputs", {})
            print(f"  completed in {time.time()-t0:.0f}s | status={st.get('status_str')}")
            break
        if st.get("status_str") == "error":
            print("  BAD execution error:"); print(json.dumps(st, indent=1)[:2500]); sys.exit(1)
    time.sleep(5)
else:
    print("  BAD timeout waiting for generation"); sys.exit(1)

found = []
for nid, out in (outputs or {}).items():
    for kind, items in out.items():
        for it in (items if isinstance(items, list) else [items]):
            if isinstance(it, dict) and it.get("filename"):
                found.append((nid, kind, it.get("subfolder", ""), it["filename"]))
if not found:
    print("  BAD no output files:", json.dumps(outputs)[:800]); sys.exit(1)

outdir = "/opt/ComfyUI/output"; ok = 0
for nid, kind, sub, fn in found:
    p = os.path.join(outdir, sub, fn)
    if not os.path.exists(p): print(f"  BAD missing output {p}"); continue
    sz = os.path.getsize(p); age = time.time() - os.path.getmtime(p)
    fresh = age < (time.time() - t0) + 60
    print(f"  OUTPUT {kind}: {p} ({sz/1e6:.2f} MB, age {age:.0f}s, fresh={fresh})")
    if sz > 100_000 and fresh and fn.endswith((".mp4", ".webm", ".png")): ok += 1
print("  valid fresh outputs:", ok)
sys.exit(0 if ok else 1)
PY

echo
if [ "$FAIL" -gt 0 ]; then echo "INSTANCE TEST FAILED ($FAIL check(s))"; exit 1; fi
echo "INSTANCE TEST PASSED — pre-warmed image generates video on this GPU"
