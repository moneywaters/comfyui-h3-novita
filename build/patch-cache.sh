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

# ---------------------------------------------------------------------------
# ComfyUI-Pixaroma re-disables caching for its OWN files, and it accounts for 419 of
# the ~693 script requests (91 js/ subdirs, 330 .mjs shared modules).
#
# Its server_routes.py explains the intent: an on_response_prepare hook mirrors core's
# no-store for .mjs (core only matches .js), and a middleware stamps every relative
# import with ?v=<plugin version>, so a plugin update invalidates the whole module tree
# without the user hard-refreshing.
#
# That reasoning is about UPDATES to a long-lived server. Neither condition holds here:
# every instance is its own origin (<instanceId>-8188.<cluster>.gpu-instance.<domain>),
# and the plugin version is frozen into the image. A new build is a new instance is a
# new origin, so a hard cache cannot go stale. The ?v= stamps still make each image's
# module URLs unique, so caching them is safe.
PIX=$(ls -d /opt/ComfyUI/custom_nodes/*Pixaroma 2>/dev/null | head -1)
if [ -z "$PIX" ]; then
    echo "patch-cache: ComfyUI-Pixaroma not installed; skipping its patch"
    exit 0
fi

python3 - "$PIX/server_routes.py" <<'PY'
import sys

path = sys.argv[1]
s = open(path, encoding="utf-8").read()

CACHEABLE = 'response.headers["Cache-Control"] = "public, max-age=86400"'
if CACHEABLE in s:
    print("patch-cache: Pixaroma already patched")
    raise SystemExit(0)

# only inside _pixaroma_no_cache, so we never touch an unrelated assignment
anchor = '''async def _pixaroma_no_cache(request, response):
    p = request.path
    if p.startswith(_PIX_PREFIX) and (p.endswith(".mjs") or p.endswith(".js")):
        response.headers["Cache-Control"] = "no-store"'''

replacement = '''async def _pixaroma_no_cache(request, response):
    p = request.path
    if p.startswith(_PIX_PREFIX) and (p.endswith(".mjs") or p.endswith(".js")):
        # Deployment override: upstream sets no-store here so plugin updates land
        # without a hard refresh. That reasoning needs a long-lived origin; ours is
        # per-instance (<instanceId>-8188.<cluster>.gpu-instance.<domain>) with the
        # plugin version frozen into the image, so a hard cache cannot go stale and
        # re-fetching all ~419 modules on every load is pure waste.
        response.headers["Cache-Control"] = "public, max-age=86400"'''

if anchor in s:
    s = s.replace(anchor, replacement, 1)
    open(path, "w", encoding="utf-8").write(s)
    print("patch-cache: Pixaroma modules now cacheable in %s" % path)
else:
    print("patch-cache: Pixaroma _pixaroma_no_cache not found -- pack changed upstream")
    raise SystemExit(1)
PY
