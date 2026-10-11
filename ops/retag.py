#!/usr/bin/env python3
"""Copy an existing image manifest to a new tag (no layer upload).

Why: `latest` is mutable, so a cluster node's prewarm cache can keep serving the
OLD digest for `latest` after you re-push. Pushing the same manifest under a
content-stable tag (e.g. v2.5.1) removes the ambiguity — the tag can only ever
mean one digest, so a prewarm either has it or pulls it.

Usage:
  retag.py --repo moneywaters/comfyui-h3-novita --from latest --to v2.5.1
"""
import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

REG = "https://registry-1.docker.io"
AUTH = "https://auth.docker.io/token"
ACCEPT = ", ".join([
    "application/vnd.docker.distribution.manifest.v2+json",
    "application/vnd.oci.image.manifest.v1+json",
    "application/vnd.docker.distribution.manifest.list.v2+json",
    "application/vnd.oci.image.index.v1+json",
])


def log(*a):
    print(*a, flush=True)


def _basic():
    u = os.environ.get("DOCKER_USER")
    p = os.environ.get("DOCKER_PASS")
    if u and p:
        import base64
        return "Basic " + base64.b64encode(f"{u}:{p}".encode()).decode()
    return None


def token(repo, actions="pull,push"):
    q = urllib.parse.quote(f"repository:{repo}:{actions}", safe=":,/")
    url = f"{AUTH}?service=registry.docker.io&scope={q}"
    for i in range(5):
        try:
            req = urllib.request.Request(url)
            b = _basic()
            if b:
                req.add_header("Authorization", b)
            with urllib.request.urlopen(req, timeout=60) as r:
                return json.load(r)["token"]
        except Exception as e:
            if i == 4:
                raise
            log(f"  auth retry {i+1}: {e}")
            time.sleep(3)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--repo", required=True)
    ap.add_argument("--from", dest="src", required=True)
    ap.add_argument("--to", dest="dst", required=True)
    a = ap.parse_args()

    t = token(a.repo, "pull")
    req = urllib.request.Request(f"{REG}/v2/{a.repo}/manifests/{a.src}",
                                 headers={"Authorization": f"Bearer {t}", "Accept": ACCEPT})
    with urllib.request.urlopen(req, timeout=120) as r:
        raw = r.read()
        mt = (r.headers.get("Content-Type") or "").split(";")[0].strip()
        digest = r.headers.get("Docker-Content-Digest") or ""
    m = json.loads(raw)

    if "manifests" in m:
        log("  source is a multi-arch index; copying the index as-is")
        total = None
    else:
        total = sum(l["size"] for l in m.get("layers", []))
        log(f"  source digest : {digest}")
        log(f"  layers        : {len(m.get('layers', []))}")
        log(f"  size          : {total/1e9:.2f} GB")

    t = token(a.repo, "pull,push")
    req = urllib.request.Request(f"{REG}/v2/{a.repo}/manifests/{a.dst}",
                                 data=raw, method="PUT",
                                 headers={"Authorization": f"Bearer {t}",
                                          "Content-Type": mt})
    try:
        with urllib.request.urlopen(req, timeout=180) as r:
            log(f"  PUT {a.src} -> {a.dst}: {r.status}")
    except urllib.error.HTTPError as e:
        log(f"  PUT failed {e.code}: {e.read()[:300]}")
        return 1

    # read it back to prove the tag resolves to the same digest
    t = token(a.repo, "pull")
    req = urllib.request.Request(f"{REG}/v2/{a.repo}/manifests/{a.dst}",
                                 headers={"Authorization": f"Bearer {t}", "Accept": ACCEPT})
    with urllib.request.urlopen(req, timeout=120) as r:
        back = r.headers.get("Docker-Content-Digest", "")
    log(f"  verify {a.dst} digest: {back}")
    log("  MATCH" if back == digest else "  MISMATCH")
    return 0 if back == digest else 1


if __name__ == "__main__":
    sys.exit(main())
