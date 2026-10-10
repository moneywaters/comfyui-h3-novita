#!/bin/bash
# Runs ON the Novita GPU instance (root), driven by .github/workflows/test-instance.yml.
# Verifies the pre-warmed image: GPU, sshd, ComfyUI, baked models, and a real
# MiniMax H3 text-to-video generation.
set -uo pipefail

API=http://127.0.0.1:8188
WF=/opt/ComfyUI/user/default/workflows/H3_t2v_api_test.json
FAIL=0

echo "=================== 1. GPU ==================="
nvidia-smi || { echo "BAD: nvidia-smi failed"; FAIL=$((FAIL+1)); }
nvidia-smi --query-gpu=name,driver_version,memory.total --format=csv,noheader || true

echo "=================== 2. SSH ==================="
ss -lntp 2>/dev/null | grep -E ':22\b' && echo "  OK sshd listening" || { echo "  BAD sshd not listening"; FAIL=$((FAIL+1)); }
whoami; echo "host: $(hostname)"

echo "=================== 3. ComfyUI ==================="
for i in $(seq 1 90); do
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$API/" 2>/dev/null)
    [ "$code" = "200" ] && { echo "  ComfyUI up after ${i} tries"; break; }
    sleep 4
done
if [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$API/" 2>/dev/null)" != "200" ]; then
    echo "  BAD ComfyUI not responding; last 40 log lines:"
    tail -n 40 /var/log/comfyui.log 2>/dev/null
    FAIL=$((FAIL+1))
fi

echo "=================== 4. baked models ==================="
python3 - "$API" <<'PY' || FAIL=$((FAIL+1))
import json, sys, urllib.request
api = sys.argv[1]
oi = json.load(urllib.request.urlopen(api + "/object_info", timeout=180))
want = {
    ("UNETLoader", "unet_name"): ["minimax_h3_fl2va_pruned_int8_convrot.safetensors",
                                  "minimax_h3_ref2va_pruned_int8_convrot.safetensors"],
    ("CLIPLoader", "clip_name"): ["qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors"],
    ("VAELoader", "vae_name"): ["minimax_h3_video_vae_int8_convrot.safetensors",
                                "minimax_h3_video_vae_fp16.safetensors",
                                "minimax_h3_audio_vae_fp32.safetensors"],
    ("LoraLoaderModelOnly", "lora_name"): ["minimax_h3_fl2v_turbo_8step_v1.0_comfyui_bf16.safetensors"],
}
bad = 0
for (node, key), expect in want.items():
    try:
        opts = oi[node]["input"]["required"][key][0]
    except Exception as e:
        print(f"  BAD cannot read {node}.{key}: {e}"); bad += 1; continue
    for f in expect:
        ok = f in opts
        print(f"  {'OK ' if ok else 'BAD'} {node}: {f}")
        if not ok: bad += 1
# SeedVR2 is discovered by the SeedVR2 node pack, not core object_info
import subprocess
sv = subprocess.run(["bash","-lc","ls -1 /opt/ComfyUI/models/SEEDVR2 2>/dev/null"],capture_output=True,text=True).stdout.split()
print("  SEEDVR2 dir:", sv or "EMPTY")
if len(sv) < 2: bad += 1
sys.exit(1 if bad else 0)
PY

echo "=================== 5. live H3 text-to-video ==================="
python3 - "$API" "$WF" <<'PY' || FAIL=$((FAIL+1))
import json, sys, time, urllib.request, urllib.error, os
api, wf_path = sys.argv[1], sys.argv[2]
wf = json.load(open(wf_path))
print("  submitting", len(wf), "node workflow")

def post(url, payload):
    req = urllib.request.Request(url, data=json.dumps(payload).encode(),
                                 headers={"Content-Type": "application/json"})
    return json.load(urllib.request.urlopen(req, timeout=60))

try:
    r = post(api + "/prompt", {"prompt": wf, "client_id": "h3-image-test"})
except urllib.error.HTTPError as e:
    body = e.read().decode()[:2000]
    print("  BAD /prompt rejected:", e.code); print(body); sys.exit(1)

pid = r.get("prompt_id")
print("  prompt_id:", pid, "| queued:", r.get("number"))
if not pid:
    print("  BAD no prompt_id:", r); sys.exit(1)

t0 = time.time()
outputs = None
while time.time() - t0 < 3600:
    try:
        h = json.load(urllib.request.urlopen(f"{api}/history/{pid}", timeout=30))
    except Exception:
        h = {}
    if pid in h:
        rec = h[pid]
        st = rec.get("status", {})
        if st.get("completed") or st.get("status_str") == "success" or rec.get("outputs"):
            outputs = rec.get("outputs", {})
            print(f"  completed in {time.time()-t0:.0f}s | status={st.get('status_str')}")
            break
        if st.get("status_str") == "error":
            print("  BAD execution error:")
            print(json.dumps(st, indent=1)[:2500]); sys.exit(1)
    time.sleep(5)
else:
    print("  BAD timeout waiting for generation"); sys.exit(1)

found = []
for nid, out in (outputs or {}).items():
    for kind, items in out.items():
        for it in (items if isinstance(items, list) else [items]):
            if isinstance(it, dict) and it.get("filename"):
                found.append((nid, kind, it.get("subfolder",""), it["filename"], it.get("type","")))
if not found:
    print("  BAD no output files:", json.dumps(outputs)[:800]); sys.exit(1)

outdir = "/opt/ComfyUI/output"
ok = 0
for nid, kind, sub, fn, typ in found:
    p = os.path.join(outdir, sub, fn)
    sz = os.path.getsize(p) if os.path.exists(p) else -1
    print(f"  OUTPUT {kind}: {p} ({sz/1e6:.2f} MB)")
    if sz > 100_000 and (fn.endswith(".mp4") or fn.endswith(".webm") or fn.endswith(".png")):
        ok += 1
print("  valid outputs:", ok)
sys.exit(0 if ok else 1)
PY

echo
if [ "$FAIL" -gt 0 ]; then echo "INSTANCE TEST FAILED ($FAIL check(s))"; exit 1; fi
echo "INSTANCE TEST PASSED — pre-warmed image generates video on this GPU"
