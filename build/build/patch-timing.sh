#!/bin/bash
# Per-request timing, so "the GUI takes ages to load" can be answered with numbers
# instead of guesses.
#
# Why this exists: the earlier fix round reasoned its way to a cause (uncompressed
# /object_info + no-store on every module) and shipped three fixes without leaving any way
# to measure the result. When the load was still slow there was nothing on the box to say
# which phase was eating the time -- how much is request latency through the host proxy,
# how much is /object_info, how much is simply the module count.
#
# Installs middleware/timing_middleware.py and wires it into server.py:
#   * every request is timed; anything over COMFY_TIMING_SLOW_MS (default 250) is logged
#     with its duration, byte count and path
#   * a running summary is kept per file class and per path
#   * GET /debug/timing returns that summary as JSON
#
# So after a GUI load:  curl -s <gui-url>/debug/timing | python3 -m json.tool
set -uo pipefail

MWDIR=/opt/ComfyUI/middleware
SERVER=/opt/ComfyUI/server.py
mkdir -p "$MWDIR"

cat > "$MWDIR/timing_middleware.py" <<'PYEOF'
"""Per-request timing for diagnosing slow page loads.

Kept deliberately dependency-free and exception-safe: a bug in here must never take down
the server, so every hook swallows its own errors. State lives in the module, which the
snapshot route reads.

Timing is wall-clock around the handler, so it includes anything the handler awaited
(file read, JPEG encode, queue work) as well as the response write.
"""

import logging
import os
import time
from collections import defaultdict

from aiohttp import web

SLOW_MS = float(os.environ.get("COMFY_TIMING_SLOW_MS", "250"))
SUMMARY_EVERY = int(os.environ.get("COMFY_TIMING_SUMMARY_EVERY", "250"))

log = logging.getLogger("comfy.timing")


def _classify(path, ctype=""):
    """Bucket a request so the summary reads as phases rather than 800 paths."""
    p = path.lower()
    if p.startswith("/ws"):
        return "websocket"
    if p.startswith("/object_info") or p.endswith("/object_info"):
        return "object_info"
    if p.endswith(".mjs") or p.endswith(".js"):
        return "js"
    if p.endswith(".css"):
        return "css"
    if p.endswith(".json") or "/api/" in p:
        return "json"
    if p.startswith("/view") or p.startswith("/api/view") or "/assets/" in p:
        return "asset"
    if "image" in ctype:
        return "asset"
    return "other"


class _Stats:
    def __init__(self):
        self.reset()

    def reset(self):
        self.n = 0
        self.errors = 0
        self.total_ms = 0.0
        self.bytes = 0
        self.started = time.time()
        self.cls_count = defaultdict(int)
        self.cls_ms = defaultdict(float)
        self.cls_bytes = defaultdict(int)
        self.paths = defaultdict(lambda: {"n": 0, "ms": 0.0, "bytes": 0})
        self.slow = []          # (ms, nbytes, status, path)
        self.slowest = 0.0

    def record(self, cls, path, ms, nbytes, status):
        self.n += 1
        self.total_ms += ms
        self.bytes += nbytes
        if status >= 400:
            self.errors += 1
        self.cls_count[cls] += 1
        self.cls_ms[cls] += ms
        self.cls_bytes[cls] += nbytes
        e = self.paths[path]
        e["n"] += 1
        e["ms"] += ms
        e["bytes"] += nbytes
        if ms > self.slowest:
            self.slowest = ms
        # keep only the worst handful, so memory cannot grow without bound
        self.slow.append((round(ms, 1), nbytes, status, path))
        if len(self.slow) > 400:
            self.slow.sort(reverse=True)
            del self.slow[200:]

    def snapshot(self):
        wall = max(time.time() - self.started, 1e-6)
        by_cls = []
        for c in sorted(self.cls_ms, key=lambda k: -self.cls_ms[k]):
            by_cls.append({
                "class": c,
                "requests": self.cls_count[c],
                "total_ms": round(self.cls_ms[c], 1),
                "avg_ms": round(self.cls_ms[c] / max(self.cls_count[c], 1), 1),
                "bytes": self.cls_bytes[c],
            })
        worst = sorted(self.slow, reverse=True)[:25]
        heaviest = sorted(self.paths.items(), key=lambda kv: -kv[1]["ms"])[:25]
        return {
            "requests": self.n,
            "errors": self.errors,
            "wall_seconds": round(wall, 1),
            "sum_request_ms": round(self.total_ms, 1),
            "avg_ms": round(self.total_ms / max(self.n, 1), 1),
            "slowest_ms": round(self.slowest, 1),
            "response_bytes": self.bytes,
            "by_class": by_cls,
            "slowest_requests": [
                {"ms": ms, "bytes": b, "status": s, "path": p} for ms, b, s, p in worst
            ],
            "heaviest_paths": [
                {"path": p, "requests": v["n"], "total_ms": round(v["ms"], 1),
                 "avg_ms": round(v["ms"] / max(v["n"], 1), 1), "bytes": v["bytes"]}
                for p, v in heaviest
            ],
        }


STATS = _Stats()


@web.middleware
async def request_timing(request, handler):
    t0 = time.perf_counter()
    status = 0
    nbytes = 0
    try:
        response = await handler(request)
        status = response.status
        try:
            nbytes = len(response.body) if response.body is not None else 0
        except Exception:
            nbytes = 0
        return response
    except web.HTTPException as e:
        status = e.status
        raise
    finally:
        try:
            ms = (time.perf_counter() - t0) * 1000.0
            cls = _classify(request.path)
            STATS.record(cls, request.path, ms, nbytes, status)
            if ms >= SLOW_MS:
                log.info("[timing] %8.1fms %9d B  %s  %s", ms, nbytes, status, request.path)
            if SUMMARY_EVERY and STATS.n % SUMMARY_EVERY == 0:
                s = STATS.snapshot()
                log.info("[timing] %d requests, %.0fms total, slowest %.0fms: %s",
                         s["requests"], s["sum_request_ms"], s["slowest_ms"],
                         ", ".join("%s=%d/%.0fms" % (c["class"], c["requests"], c["total_ms"])
                                   for c in s["by_class"][:6]))
        except Exception:
            pass


def snapshot_response(request):
    return web.json_response(STATS.snapshot())
PYEOF
echo "patch-timing: wrote $MWDIR/timing_middleware.py"

python3 - "$SERVER" <<'PY'
import sys

path = sys.argv[1]
s = open(path, encoding="utf-8").read()

IMPORT_ANCHOR = "from middleware.cache_middleware import cache_control"
IMPORT_LINE = "from middleware.timing_middleware import request_timing, snapshot_response"

MID_OLD = "        middlewares = [cache_control, deprecation_warning]"
MID_NEW = ("        # request_timing first, so its clock covers every later middleware\n"
           "        middlewares = [request_timing, cache_control, deprecation_warning]")

ROUTE_ANCHOR = ("        self.app = web.Application(client_max_size=max_upload_size, "
                "middlewares=middlewares)")
ROUTE_LINE = ("\n        # /debug/timing: a JSON summary of per-request timings, so a slow\n"
              "        # page load can be attributed to a phase instead of guessed at.\n"
              "        self.app.router.add_get(\"/debug/timing\", snapshot_response)")

changed = []

if IMPORT_LINE in s:
    pass
elif IMPORT_ANCHOR in s:
    s = s.replace(IMPORT_ANCHOR, IMPORT_ANCHOR + "\n" + IMPORT_LINE, 1)
    changed.append("import")
else:
    print("patch-timing: cache_middleware import not found -- server.py layout changed")
    raise SystemExit(1)

if MID_NEW in s:
    pass
elif MID_OLD in s:
    s = s.replace(MID_OLD, MID_NEW, 1)
    changed.append("middleware list")
else:
    print("patch-timing: middleware list not found -- server.py layout changed")
    raise SystemExit(1)

if '"/debug/timing"' in s:
    pass
elif ROUTE_ANCHOR in s:
    s = s.replace(ROUTE_ANCHOR, ROUTE_ANCHOR + ROUTE_LINE, 1)
    changed.append("route")
else:
    print("patch-timing: web.Application(...) not found -- server.py layout changed")
    raise SystemExit(1)

if changed:
    open(path, "w", encoding="utf-8").write(s)
    print("patch-timing: patched %s (%s)" % (path, ", ".join(changed)))
else:
    print("patch-timing: already patched")
PY