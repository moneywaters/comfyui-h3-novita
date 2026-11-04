#!/usr/bin/env python3
"""Append a tiny file layer (e.g. authorized_keys) onto an existing image tag,
entirely at the registry: no runner build, no re-download. Produces a new tag.

Usage:
  append-layer.py --repo moneywaters/sensenova-code2video \
    --from sha-5e618bfa7176 --out baked \
    --file root/.ssh/authorized_keys:/tmp/authorized_keys \
    [--mode 600] [--dir-mode 700]

Multiple --file allowed. Parent dirs are created with --dir-mode.
"""
import argparse
import base64
import gzip
import hashlib
import io
import json
import os
import sys
import tarfile
import time

import importlib.util
_here = os.path.join(os.path.dirname(os.path.abspath(__file__)))
_spec = importlib.util.spec_from_file_location(
    "compose_image", os.path.join(_here, "compose-image.py"))
_compose = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_compose)
REG, get_token, request = _compose.REG, _compose.get_token, _compose.request
resolve_manifest, get_blob_json = (_compose.resolve_manifest,
                                   _compose.get_blob_json)

DOCKER_MANIFEST = "application/vnd.docker.distribution.manifest.v2+json"
DOCKER_CONFIG = "application/vnd.docker.container.image.v1+json"


def build_layer(files, file_mode=0o600, dir_mode=0o700):
    """Tar (with explicit dir entries) -> (gzipped bytes, blob_digest, diff_id)."""
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w") as t:
        made = set()

        def ensure_dir(path):
            parts = path.strip("/").split("/")[:-1]
            cur = ""
            for p in parts:
                cur += "/" + p
                if cur not in made:
                    made.add(cur)
                    ti = tarfile.TarInfo(cur.lstrip("/"))
                    ti.type = tarfile.DIRTYPE
                    ti.mode = dir_mode
                    ti.uid = ti.gid = 0
                    ti.uname = ti.gname = "root"
                    ti.mtime = 0
                    t.addfile(ti)

        for dest, src in files:
            with open(src, "rb") as f:
                data = f.read()
            ensure_dir(dest)
            ti = tarfile.TarInfo(dest.strip("/"))
            ti.size = len(data)
            ti.mode = file_mode
            ti.uid = ti.gid = 0
            ti.uname = ti.gname = "root"
            ti.mtime = 0
            t.addfile(ti, io.BytesIO(data))
    raw = buf.getvalue()
    comp = gzip.compress(raw, compresslevel=9, mtime=0)
    return (comp, "sha256:" + hashlib.sha256(comp).hexdigest(),
            "sha256:" + hashlib.sha256(raw).hexdigest())


def upload_blob(repo, token, comp, digest):
    st, hdrs, _ = request(f"{REG}/v2/{repo}/blobs/uploads/", token,
                          method="POST", data=b"",
                          )
    loc = hdrs.get("Location") or hdrs.get("location")
    if not loc:
        raise RuntimeError("no upload Location returned")
    if loc.startswith("/"):
        loc = REG + loc
    import urllib.parse
    sep = "&" if "?" in loc else "?"
    url = f"{loc}{sep}digest={urllib.parse.quote(digest, safe=':')}"
    st, _, body = request(url, token, method="PUT", data=comp,
                          ctype="application/octet-stream")
    if st not in (200, 201):
        raise RuntimeError(f"blob upload -> {st}: {body[:200]}")
    return st


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--repo", required=True)
    ap.add_argument("--from", dest="from_tag", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--file", action="append", default=[],
                    help="dest:src, dest relative to / (e.g. root/.ssh/authorized_keys:/tmp/ak)")
    ap.add_argument("--mode", default="600")
    ap.add_argument("--dir-mode", default="700")
    ap.add_argument("--history-by", default="append-layer.py baked-ssh-key")
    args = ap.parse_args()
    files = []
    for spec in args.file:
        dest, src = spec.split(":", 1)
        files.append((dest, src))
    if not files:
        print("no --file given", file=sys.stderr)
        return 2

    comp, blob_digest, diff_id = build_layer(
        files, int(args.mode, 8), int(args.dir_mode, 8))
    print(f"layer: {len(comp)} B blob={blob_digest[:19]} diff={diff_id[:19]}",
          flush=True)

    m, man_mt = resolve_manifest(args.repo, args.from_tag)
    cfg = get_blob_json(args.repo, m["config"]["digest"])
    cfg_mt = m["config"].get("mediaType", DOCKER_CONFIG)
    if man_mt not in (DOCKER_MANIFEST,
                       "application/vnd.oci.image.manifest.v1+json"):
        man_mt = DOCKER_MANIFEST

    token = get_token(args.repo, "pull,push")
    # skip upload if blob already present
    import urllib.error
    try:
        st, _, _ = request(f"{REG}/v2/{args.repo}/blobs/{blob_digest}",
                           token, method="HEAD")
        print(f"blob exists ({st}), skipping upload")
    except RuntimeError as e:
        if "404" not in str(e):
            raise
        print("uploading blob...", flush=True)
        upload_blob(args.repo, token, comp, blob_digest)

    new_layers = list(m["layers"]) + [{
        "mediaType": "application/vnd.docker.image.rootfs.diff.tar.gzip",
        "size": len(comp), "digest": blob_digest}]
    new_cfg = dict(cfg)
    new_cfg["rootfs"] = {"type": "layers",
                         "diff_ids": list(cfg["rootfs"]["diff_ids"]) + [diff_id]}
    new_cfg["history"] = list(cfg.get("history", [])) + [{
        "created": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "created_by": args.history_by, "empty_layer": False}]
    cfg_bytes = json.dumps(new_cfg, separators=(",", ":")).encode()
    cfg_digest = "sha256:" + hashlib.sha256(cfg_bytes).hexdigest()

    st, hdrs, _ = request(f"{REG}/v2/{args.repo}/blobs/uploads/", token,
                          method="POST", data=b"")
    loc = hdrs.get("Location") or hdrs.get("location")
    if loc.startswith("/"):
        loc = REG + loc
    import urllib.parse
    sep = "&" if "?" in loc else "?"
    st, _, body = request(
        f"{loc}{sep}digest={urllib.parse.quote(cfg_digest, safe=':')}",
        token, method="PUT", data=cfg_bytes,
        ctype="application/octet-stream")
    print(f"config upload -> {st}")

    manifest = {"schemaVersion": 2, "mediaType": man_mt,
                "config": {"mediaType": cfg_mt, "size": len(cfg_bytes),
                           "digest": cfg_digest},
                "layers": new_layers}
    man_bytes = json.dumps(manifest, separators=(",", ":")).encode()
    man_digest = "sha256:" + hashlib.sha256(man_bytes).hexdigest()
    content_tag = "sha-" + man_digest.split(":", 1)[1][:12]
    for tag in (content_tag, args.out):
        token = get_token(args.repo, "pull,push")
        st, _, body = request(
            f"{REG}/v2/{args.repo}/manifests/{tag}", token,
            method="PUT", data=man_bytes, ctype=man_mt)
        print(f"tag {tag} -> {st} {body[:100]!r}")
    print(f"USE FOR PREWARM/DEPLOY: {args.repo}:{content_tag}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
