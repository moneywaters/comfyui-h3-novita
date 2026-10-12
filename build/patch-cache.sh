#!/bin/bash
# Serve ComfyUI's JS/CSS cacheable instead of `no-store`.
#
# Why: middleware/cache_middleware.py sets Cache-Control: no-store for every .js, .css
# and index*.json. ComfyUI does this so a frontend update takes effect immediately, but
# it means every single page load re-downloads the whole extension set -- ~690 module
# requests here (ComfyUI-Pixaroma alone is 419 of them). Over a remote GPU host's HTTP
# proxy each request costs 0.5-1s, so a cold GUI takes ~87s and never gets faster:
# measured 87s / 828 requests, with only ~26 responses actually reused.
#
# Caching hard is safe in this deployment for a specific reason: every instance gets its
# own hostname, <instanceId>-8188.<cluster>.gpu-instance.<domain>, so the browser cache
# is scoped to a single instance. A new image means a new instance means a new origin,
# so cached JS can never be served against a different build.
#
# Effect: the first load still costs the full download, every later load is served from
# cache and lands in a second or two.
set -uo pipefail

MW=$(ls /opt/ComfyUI/middleware/cache_middleware.py 2>/dev/null | head -1)
if [ -z "$MW" ]; then
    echo "patch-cache: middleware/cache_middleware.py not found"
    exit 1
fi

python3 - "$MW" <<'PY'
import sys

path = sys.argv[1]
s = open(path, encoding="utf-8").read()

OLD = '''    if request.path.endswith(".js") or request.path.endswith(".css") or is_entry_point:
        response.headers.setdefault("Cache-Control", "no-store")
        return response'''

NEW = '''    if request.path.endswith(".js") or request.path.endswith(".css") or is_entry_point:
        # NOT no-store: that made every page load re-fetch all ~690 extension modules
        # (~87s over a high-latency link, every single time). This is a per-instance
        # origin (<instanceId>-8188.<cluster>.gpu-instance.<domain>), so a hard cache
        # cannot leak stale JS across builds -- a new image is always a new origin.
        response.headers.setdefault("Cache-Control", "public, max-age=86400")
        return response'''

if NEW in s:
    print("patch-cache: already patched")
elif OLD in s:
    s = s.replace(OLD, NEW, 1)
    open(path, "w", encoding="utf-8").write(s)
    print("patch-cache: JS/CSS now cacheable (public, max-age=86400) in %s" % path)
else:
    print("patch-cache: no-store branch not found -- middleware shape changed upstream")
    raise SystemExit(1)
PY
