#!/usr/bin/env python3
"""Copy an image manifest from one Docker Hub repo to another, without re-pushing layers.

Why this exists: image A and image B are byte-identical -- the only difference is the NAME,
because the PPIO and Novita launchers ask for comfyui-qwen-novita when a Qwen run is wanted.
Re-pushing 83 GB to publish the same bytes under a second name is pure waste, so instead we
read the manifest from the source repo and PUT it, unchanged, to the destination. The layers
already live in the shared registry; only the manifest (a few KB) moves.

Blobs are content-addressed, so this is exact: the destination manifest references the same
digests and cannot drift from the source.
"""
import argparse
import json
import sys
import urllib.request

MEDIA = "application/vnd.docker.distribution.manifest.v2+json"


def req(url, token=None, method="GET", data=None, ctype=None):
    r = urllib.request.Request(url, method=method, data=data)
    if token:
        r.add_header("Authorization", "Bearer %s" % token)
    if ctype:
        r.add_header("Content-Type", ctype)
    if method == "GET":
        r.add_header("Accept", MEDIA)
    with urllib.request.urlopen(r, timeout=120) as resp:
        return resp.status, resp.read()


def token_for(user, password, repo):
    import base64
    url = ("https://auth.docker.io/token?service=registry.docker.io"
           "&scope=repository:%s:pull,push" % repo)
    cred = base64.b64encode(("%s:%s" % (user, password)).encode()).decode()
    r = urllib.request.Request(url)
    r.add_header("Authorization", "Basic %s" % cred)
    with urllib.request.urlopen(r, timeout=60) as resp:
        return json.load(resp)["token"]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--from-repo", required=True)
    ap.add_argument("--from-tag", required=True)
    ap.add_argument("--to-repo", required=True)
    ap.add_argument("--to-tag", required=True)
    ap.add_argument("--to-tag-also", default=None)
    ap.add_argument("--user", default=None, help="Docker Hub user (or $DOCKER_USER)")
    ap.add_argument("--password", default=None, help="Docker Hub password (or $DOCKER_PASS)")
    a = ap.parse_args()

    import os
    user = a.user or os.environ.get("DOCKER_USER")
    pw = a.password or os.environ.get("DOCKER_PASS")
    if not user or not pw:
        print("copy-tag: DOCKER_USER / DOCKER_PASS required", file=sys.stderr)
        return 2

    st, body = req("https://registry-1.docker.io/v2/%s/manifests/%s"
                   % (a.from_repo, a.from_tag), token_for(user, pw, a.from_repo))
    print("copy-tag: read %s:%s (%d bytes)" % (a.from_repo, a.from_tag, len(body)))

    tok = token_for(user, pw, a.to_repo)
    for tag in [a.to_tag] + ([a.to_tag_also] if a.to_tag_also else []):
        st, _ = req("https://registry-1.docker.io/v2/%s/manifests/%s" % (a.to_repo, tag),
                    token=tok, method="PUT", data=body, ctype=MEDIA)
        print("copy-tag: wrote %s:%s -> HTTP %s" % (a.to_repo, tag, st))
    return 0


if __name__ == "__main__":
    sys.exit(main())
