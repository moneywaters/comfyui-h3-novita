#!/bin/bash
# Disable ComfyUI's splash / "Loading ComfyUI" overlay.
#
# Why this is needed: the frontend removes #splash-loader only when the extension
# store's `spinner` flag transitions true -> false -- see the App setup in the
# entry bundle:
#
#   let t = H(), r = a(() => t.spinner)
#   oe(r, (e, t) => { t && !e && document.getElementById('splash-loader')?.remove() },
#      { flush: 'post' })
#
# When any extension script fails to load, that flag never clears and the overlay
# stays on top of a fully working UI: the Vue app mounts, the graph initialises,
# the canvas renders, and the user still stares at a logo. A remote GPU host's
# HTTP proxy makes that failure reliable -- a burst of ~320 extension scripts over
# a high-latency, lossy link drops a handful every time, and the browser does not
# retry script tags. Observed on Novita: 318 files fetched, 14 hard failures.
#
# Setting the rule to display:none sidesteps the gate without touching the app.
set -uo pipefail

HTML=$(ls /opt/comfyui-venv/lib/python*/site-packages/comfyui_frontend_package/static/index.html 2>/dev/null | head -1)
if [ -z "$HTML" ]; then
    echo "patch-frontend: comfyui_frontend_package/static/index.html not found"
    exit 1
fi

python3 - "$HTML" <<'PY'
import re
import sys

path = sys.argv[1]
s = open(path, encoding="utf-8").read()

NEW = "#splash-loader{display:none!important}"

if NEW in s:
    print("patch-frontend: already disabled")
    raise SystemExit(0)

if "#splash-loader" not in s:
    # No splash in this frontend build: nothing to do, and nothing to break.
    print("patch-frontend: no #splash-loader rule in this build; nothing to do")
    raise SystemExit(0)

m = re.search(r"#splash-loader\{[^}]*\}", s)
if not m:
    print("patch-frontend: #splash-loader present but its rule did not match")
    raise SystemExit(1)

s = s[: m.start()] + NEW + s[m.end():]
open(path, "w", encoding="utf-8").write(s)
print(f"patch-frontend: disabled splash in {path}")
PY
