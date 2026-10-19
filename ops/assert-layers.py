#!/usr/bin/env python3
"""Fail the build if any docker layer is large enough to break SimplePod's unpacker.

Background, measured rather than guessed:

  code-only image  -> largest layer 3.16 GB, pulls on SimplePod in ~90 s
  plain :models    -> layers of 20.96 / 20.95 / 14.88 / 7.28 GB, and SimplePod's console
                      loops "Preparing instance / Pulling image" forever: the progress bar
                      reaches 100% every ~4 min, diskUsage stays 0.00, the container never
                      starts. Ruled out: disk size (100 GB and 200 GB both failed), host
                      health (failed on two different hosts while a 7 GB control image
                      booted on those same hosts), and the image itself (PPIO and Novita
                      pull it fine).

So the property this image must have is: no layer over the limit. Chunking the weights is
the only way to get it, because docker stores each file uncompressed -- a 20 GB safetensors
IS a 20 GB layer, and a later RUN that deletes and re-splits it does not remove the earlier
blob from the image.

Docker layers are immutable and additive, which is why the split has to happen while
streaming the download (curl | split) rather than afterwards.

Usage: assert-layers.py [repo:]tag [repo2:]tag ...
Exit status 1 if any layer exceeds LIMIT_BYTES (default 4 GiB).
"""

import json
import os
import sys
import urllib.request

LIMIT = int(os.environ.get("LIMIT_BYTES", 4 * 1024**3))
HUB = "https://hub.docker.com/v2/repositories/{repo}/tags/{tag}/images"


def fetch(ref):
    repo, _, tag = ref.partition(":")
    if not tag:
        tag = "latest"
    url = HUB.format(repo=repo, tag=tag)
    with urllib.request.urlopen(url, timeout=60) as r:
        d = json.load(r)
    if isinstance(d, list):
        d = d[0] if d else {}
    return [l for l in (d.get("layers") or []) if (l.get("size") or 0) > 0]


def main(refs):
    if not refs:
        print("usage: assert-layers.py repo:tag [...]", file=sys.stderr)
        return 2

    ok = True
    checked = 0
    for ref in refs:
        try:
            layers = fetch(ref)
        except Exception as e:
            # Not "OK" -- we simply do not know. Say so, and do not let it pass silently.
            print(f"  WARN cannot inspect {ref} ({e}) -- NOT verified")
            ok = False
            continue

        if not layers:
            print(f"  WARN {ref}: no layers reported -- NOT verified")
            ok = False
            continue
        checked += 1

        sizes = [l["size"] for l in layers]
        big = sorted((s for s in sizes if s > LIMIT), reverse=True)
        print(
            "  %-52s %3d layers  %6.1f GB  largest %5.2f GB"
            % (ref, len(sizes), sum(sizes) / 1e9, max(sizes) / 1e9)
        )
        if big:
            print(
                "  ERROR %s has %d layer(s) over %.1f GB: %s"
                % (ref, len(big), LIMIT / 1e9, ", ".join("%.2f" % (b / 1e9) for b in big))
            )
            print("        SimplePod cannot unpack these. Check that MODEL_CHUNK_MB reached")
            print("        models-part.sh -- if the split ran after the download instead of")
            print("        during it, the unsplit blob is still in an earlier layer.")
            ok = False

    if ok and checked:
        print("  OK: verified %d tag(s), no layer exceeds %.1f GB" % (checked, LIMIT / 1e9))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
