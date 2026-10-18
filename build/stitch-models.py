#!/usr/bin/env python3
"""Rebuild <name>.safetensors from <name>.safetensors.partNNN chunks.

Why chunked at all: SimplePod hosts will not unpack our 83 GB image. Their console
loops "Preparing instance / Pulling image" every ~4 minutes indefinitely -- the download
reaches 100% each cycle, `diskUsage` never moves, and the container never starts. It is
reproducible on host 216 (RTX 4090) and host 161 (RTX 3090), at both 100 GB and 200 GB
disk, while a 7 GB control image boots on those same hosts in ~300s.

The structural difference is layer shape: ours is 63 layers / 83.1 GB with single
20.96 GB layers, the control is 29 layers / 7.37 GB with nothing over a few GB. Docker
stores each model file uncompressed, so a 20 GB safetensors *is* a 20 GB layer, and
unpacking one needs that much scratch on the overlay the storage driver writes to.

So the image ships those weights pre-split into sub-4 GB chunks and this puts them back.
It is deliberately lazy: only the directories named on the command line are touched, so
PPIO and Novita -- which pull this image happily and prewarm it -- pay nothing unless
they actually load a chunked model.

Safety properties this file is responsible for:

* **Atomic.** Rebuild goes to a temp file in the destination directory, then `os.replace`,
  which is atomic on the same filesystem. An interrupted rebuild cannot leave a
  half-written model that ComfyUI would then try to load.
* **Verified.** The stitched size must equal the sum of the chunk sizes, or the temp file
  is discarded and the destination left alone.
* **Self-describing.** Chunks are plain byte ranges, so no manifest is needed; `part000`
  .. `partNNN` sort lexically and are concatenated in order.
* **Idempotent.** A destination whose size already matches the total is skipped unless
  --force.
"""

import argparse
import os
import re
import sys


CHUNK_RE = re.compile(r"^(?P<stem>.+)\.part(?P<idx>\d+)$")

# --- tunables -----------------------------------------------------------------
# Directories walked by default when start.sh calls this without --dirs. The two
# 20 GB diffusion models are the ones that broke SimplePod, and they are the ones a
# user reaches for first, so they get stitched eagerly at boot.
DEFAULT_DIRS = ("diffusion_models",)
# A chunk larger than this means something rebuilt the image without chunking; warn
# because that is exactly the case that fails on SimplePod.
WARN_CHUNK_BYTES = 4 * 1024**3


def log(msg):
    print("[stitch] %s" % msg, flush=True)


def find_chunk_groups(root):
    """Map destination path -> ordered list of chunk paths, under `root`."""
    groups = {}
    if not os.path.isdir(root):
        return groups
    for dirpath, _dirnames, filenames in os.walk(root):
        for fn in filenames:
            m = CHUNK_RE.match(fn)
            if not m:
                continue
            dest = os.path.join(dirpath, m.group("stem"))
            groups.setdefault(dest, []).append(
                (int(m.group("idx")), os.path.join(dirpath, fn))
            )
    # sort each group by chunk index and make sure numbering is 0..N-1 with no gaps,
    # otherwise concatenating would silently produce a corrupt model
    good = {}
    for dest, parts in groups.items():
        parts.sort()
        idxs = [i for i, _ in parts]
        if idxs != list(range(len(parts))):
            log("SKIP %s: chunk indices are not contiguous (%s)"
                % (os.path.basename(dest), idxs[:12]))
            continue
        good[dest] = [p for _, p in parts]
    return good


def stitch(dest, parts, force=False, verbose=False):
    total = sum(os.path.getsize(p) for p in parts)

    if os.path.exists(dest) and not force:
        have = os.path.getsize(dest)
        if have == total:
            if verbose:
                log("ok    %s (%.2f GB, %d chunks)"
                    % (os.path.basename(dest), total / 1e9, len(parts)))
            return "skip"
        # a wrong-size destination means a previous rebuild died partway; redo it
        log("redo  %s: present size %d != chunk total %d"
            % (os.path.basename(dest), have, total))

    biggest = max(os.path.getsize(p) for p in parts)
    if biggest > WARN_CHUNK_BYTES:
        log("WARN  %s has a %.2f GB chunk -- SimplePod may still fail to unpack it"
            % (os.path.basename(dest), biggest / 1e9))

    tmp = dest + ".stitching"
    log("build %s (%.2f GB from %d chunks)"
        % (os.path.basename(dest), total / 1e9, len(parts)))
    written = 0
    try:
        with open(tmp, "wb") as out:
            for p in parts:
                with open(p, "rb") as src:
                    while True:
                        buf = src.read(8 * 1024 * 1024)
                        if not buf:
                            break
                        out.write(buf)
                        written += len(buf)
        if written != total:
            raise IOError("wrote %d of %d bytes" % (written, total))
        os.replace(tmp, dest)
    except Exception as e:
        log("FAIL  %s: %s" % (os.path.basename(dest), e))
        try:
            os.unlink(tmp)
        except OSError:
            pass
        return "fail"

    got = os.path.getsize(dest)
    if got != total:
        log("FAIL  %s: final size %d != %d" % (os.path.basename(dest), got, total))
        return "fail"
    log("done  %s (%.2f GB)" % (os.path.basename(dest), got / 1e9))
    return "build"


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--models-dir", default="/opt/ComfyUI/models")
    ap.add_argument("--dirs", nargs="*", default=list(DEFAULT_DIRS),
                    help="subdirectories of --models-dir to walk (default: %s)" % (DEFAULT_DIRS,))
    ap.add_argument("--all", action="store_true",
                    help="walk the whole models tree instead of --dirs")
    ap.add_argument("--force", action="store_true",
                    help="rebuild even when the destination size already matches")
    ap.add_argument("--list", action="store_true",
                    help="only report what would be built")
    ap.add_argument("--verbose", action="store_true")
    args = ap.parse_args()

    roots = [args.models_dir] if args.all else \
            [os.path.join(args.models_dir, d) for d in args.dirs]

    groups = {}
    for r in roots:
        groups.update(find_chunk_groups(r))

    if not groups:
        if args.verbose:
            log("no chunked models under %s" % ", ".join(roots))
        return 0

    if args.list:
        for dest, parts in sorted(groups.items()):
            total = sum(os.path.getsize(p) for p in parts)
            state = "present" if (os.path.exists(dest)
                                  and os.path.getsize(dest) == total) else "missing"
            print("%-12s %-46s %8.2f GB  %2d chunks"
                  % (state, os.path.basename(dest), total / 1e9, len(parts)))
        return 0

    counts = {"build": 0, "skip": 0, "fail": 0}
    for dest, parts in sorted(groups.items()):
        counts[stitch(dest, parts, force=args.force, verbose=args.verbose)] += 1

    log("summary: %d built, %d already present, %d failed"
        % (counts["build"], counts["skip"], counts["fail"]))
    # missing models are a runtime problem for one workflow, not a reason to refuse to
    # boot the container -- start.sh logs this and carries on
    return 1 if counts["fail"] else 0


if __name__ == "__main__":
    sys.exit(main())