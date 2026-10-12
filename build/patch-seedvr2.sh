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

OLD = "        if cached_model:\n"
NEW = "        if cached_model is not None:\n"

n = s.count(OLD)
if n == 0:
    if s.count(NEW):
        print("patch-seedvr2: already patched (%d check(s))" % s.count(NEW))
        raise SystemExit(0)
    print("patch-seedvr2: no 'if cached_model:' truthiness test found -- layout changed")
    raise SystemExit(1)

# NOTE: the upstream source reuses the SAME local name for both branches --
#   cached_model = global_cache.get_dit(...)   ->  if cached_model:   (DiT)
#   cached_model = global_cache.get_vae(...)   ->  if cached_model:   (VAE)
# so there is no "if cached_vae:" to fix; the handoff's §5 snippet assumes one and
# therefore only ever patched the first site. Replace ALL of them.
s = s.replace(OLD, NEW)
open(path, "w", encoding="utf-8").write(s)
print("patch-seedvr2: patched %d truthiness check(s)" % n)

for i, line in enumerate(open(path, encoding="utf-8"), 1):
    if "cached_model" in line and line.lstrip().startswith("if "):
        print("  %d: %s" % (i, line.rstrip()))
PY
