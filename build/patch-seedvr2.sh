#!/bin/bash
# SeedVR2: make `cache_model=true` survive a second queued run.
#
# Symptom if unpatched (handoff/SEEDVR2_BULK_HANDOFF.md §5): the 2nd run in a batch dies
# with `TypeError: CompatibleDiT does not support len()`.
#
# Cause: src/core/model_configuration.py tests a cached module for truthiness --
# `if cached_model:` -- but the cached value can be a torch.compile'd OptimizedModule,
# whose __len__ raises instead of returning a length. A None check is the correct test.
#
# With torch.compile off (the bulk workflow ships SeedVR2TorchCompileSettings bypassed) a
# plain module is truthy and the unpatched code happens to work -- patch it anyway, it is
# correct and the failure returns the moment compile is switched on.
set -uo pipefail

F=/opt/ComfyUI/custom_nodes/ComfyUI-SeedVR2_VideoUpscaler/src/core/model_configuration.py
if [ ! -f "$F" ]; then
    echo "patch-seedvr2: $F not found (pack missing or layout changed)"
    exit 1
fi

python3 - "$F" <<'PY'
import sys

path = sys.argv[1]
s = open(path, encoding="utf-8").read()

if "if cached_model is not None:" in s and "if cached_vae is not None:" in s:
    print("patch-seedvr2: already patched")
    raise SystemExit(0)

subs = [
    ("        if cached_model:\n", "        if cached_model is not None:\n"),
    ("        if cached_vae:\n",   "        if cached_vae is not None:\n"),
]

applied = 0
for old, new in subs:
    if old in s:
        s = s.replace(old, new, 1)
        applied += 1

if applied == 0:
    print("patch-seedvr2: neither truthiness test found -- source layout changed upstream")
    raise SystemExit(1)

open(path, "w", encoding="utf-8").write(s)
print("patch-seedvr2: applied %d/%d replacement(s)" % (applied, len(subs)))

for i, line in enumerate(open(path, encoding="utf-8"), 1):
    if "cached_model" in line and "if " in line:
        print("  %d: %s" % (i, line.rstrip()))
    if "cached_vae" in line and "if " in line:
        print("  %d: %s" % (i, line.rstrip()))
PY
