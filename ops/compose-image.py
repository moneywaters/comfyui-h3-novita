#!/usr/bin/env python3
"""Compose the final image from the env image + one or more model-part images.

Why: a GitHub-hosted runner has ~43 GB of free disk, but the finished image is
~55 GB.  So each part is built and pushed separately (each needs <=~25 GB), and
this script stitches them back together *at the registry* by appending only the
new layers of every part onto the env image's layer list.

Because every part is built FROM the same nvidia/cuda base, their leading layers
are byte-identical to the env image's leading layers; we drop that shared prefix
and keep only the trailing layers each part actually added.

Usage:
  compose-image.py --repo moneywaters/comfyui-h3-novita \
      --env sha-env --parts sha-h3diff,sha-h3enc,... --out latest
"""
import argparse
import base64
import hashlib
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

REG = "https://registry-1.docker.io"
AUTH = "https://auth.docker.io/token"
DOCKER_BASE = "docker.io"
BASE_IMAGE = "nvidia/cuda:13.0.1-cudnn-runtime-ubuntu24.04"

MANIFEST_ACCEPT = ", ".join([
    "application/vnd.docker.distribution.manifest.v2+json",
    "application/vnd.oci.image.manifest.v1+json",
    "application/vnd.docker.distribution.manifest.list.v2+json",
    "application/vnd.oci.image.index.v1+json",
])
MT_DOCKER_MANIFEST = "application/vnd.docker.distribution.manifest.v2+json"
MT_DOCKER_CONFIG = "application/vnd.docker.container.image.v1+json"
MT_OCI_MANIFEST = "application/vnd.oci.image.manifest.v1+json"
MT_OCI_CONFIG = "application/vnd.oci.image.config.v1+json"


def log(*a):
    print(*a, flush=True)


def _basic_auth():
    """Docker Hub credentials for registry pushes, if supplied."""
    u = os.environ.get("DOCKER_USER") or os.environ.get("REGISTRY_USER")
    p = os.environ.get("DOCKER_PASS") or os.environ.get("DOCKER_TOKEN") \
        or os.environ.get("REGISTRY_PASS")
    if u and p:
        return "Basic " + base64.b64encode(f"{u}:{p}".encode()).decode()
    return None


def get_token(repo, actions="pull,push"):
    url = f"{AUTH}?service=registry.docker.io&scope=repository:{repo}:{actions}"
    basic = _basic_auth()
    for attempt in range(5):
        try:
            req = urllib.request.Request(url)
            if basic:
                req.add_header("Authorization", basic)
            with urllib.request.urlopen(req, timeout=60) as r:
                return json.load(r)["token"]
        except Exception as e:
            if attempt == 4:
                raise
            log(f"  auth retry {attempt+1}: {e}")
            time.sleep(3)


def request(url, token, method="GET", data=None, ctype=None, accept=None,
            extra_headers=None, timeout=300):
    headers = {"Authorization": f"Bearer {token}"}
    if ctype:
        headers["Content-Type"] = ctype
    if accept:
        headers["Accept"] = accept
    if extra_headers:
        headers.update(extra_headers)
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return resp.status, dict(resp.headers), resp.read()
    except urllib.error.HTTPError as e:
        body = e.read()[:400]
        raise RuntimeError(f"{method} {url} -> {e.code}: {body}") from None


def resolve_manifest(repo, ref):
    """Return (manifest_dict, media_type), resolving an index to linux/amd64."""
    token = get_token(repo, "pull")
    st, hdrs, body = request(f"{REG}/v2/{repo}/manifests/{ref}", token,
                             accept=MANIFEST_ACCEPT)
    m = json.loads(body)
    mt = (hdrs.get("Content-Type") or "").split(";")[0].strip()
    if "manifests" in m:  # multi-arch index
        chosen = None
        for entry in m["manifests"]:
            p = entry.get("platform", {})
            if p.get("architecture") == "amd64" and p.get("os") == "linux":
                chosen = entry
                if p.get("variant") in (None, "", "v1"):
                    break
        if not chosen:
            raise RuntimeError(f"no linux/amd64 manifest in index for {repo}:{ref}")
        return resolve_manifest(repo, chosen["digest"])
    return m, mt


def get_blob_json(repo, digest):
    token = get_token(repo, "pull")
    st, hdrs, body = request(f"{REG}/v2/{repo}/blobs/{digest}", token)
    return json.loads(body)


def layer_size(entry):
    return entry.get("size", 0)


def compose(args):
    repo = args.repo

    log("== resolving env image ==")
    env_m, env_mt = resolve_manifest(repo, args.env)
    env_c = get_blob_json(repo, env_m["config"]["digest"])
    env_layers = env_m["layers"]
    env_diff = env_c["rootfs"]["diff_ids"]
    env_hist = env_c["history"]
    log(f"  env: {len(env_layers)} layers, {len(env_diff)} diff_ids, "
        f"{len(env_hist)} history")

    log("== resolving base image (for the shared-prefix count) ==")
    base_m, _ = resolve_manifest("nvidia/cuda",
                                 BASE_IMAGE.split(":", 1)[1])
    base_c = get_blob_json("nvidia/cuda", base_m["config"]["digest"])
    N = len(base_m["layers"])
    base_hist_len = len(base_c["history"])
    log(f"  base: {N} layers, {base_hist_len} history entries")

    final_layers = list(env_layers)
    final_diff = list(env_diff)
    final_hist = list(env_hist)

    for part in args.parts:
        log(f"== part {part} ==")
        m, mt = resolve_manifest(repo, part)
        c = get_blob_json(repo, m["config"]["digest"])
        if len(m["layers"]) < N:
            raise RuntimeError(f"{part}: fewer layers ({len(m['layers'])}) than base ({N})")
        new_layers = m["layers"][N:]
        new_diff = c["rootfs"]["diff_ids"][N:]
        new_hist = c["history"][base_hist_len:]

        non_empty = sum(1 for h in new_hist if not h.get("empty_layer"))
        if non_empty != len(new_diff):
            log(f"  WARN history/diff mismatch ({non_empty} vs {len(new_diff)}); "
                f"synthesising history")
            new_hist = [{"created": "1970-01-01T00:00:00Z",
                         "created_by": "compose-image.py synthesised"} for _ in new_diff]

        log(f"  +{len(new_layers)} layer(s), "
            f"+{sum(layer_size(l) for l in new_layers)/1e9:.2f} GB")
        final_layers += new_layers
        final_diff += new_diff
        final_hist += new_hist

    if len(final_diff) != len(final_layers):
        raise RuntimeError(f"diff_ids ({len(final_diff)}) != layers ({len(final_layers)})")

    # Pick media types that match the layers we are referencing.
    layer_mts = {l.get("mediaType", "") for l in final_layers}
    oci_layers = all("oci.image.layer" in mt for mt in layer_mts if mt)
    if oci_layers and layer_mts:
        cfg_mt, man_mt = MT_OCI_CONFIG, MT_OCI_MANIFEST
    else:
        cfg_mt, man_mt = MT_DOCKER_CONFIG, MT_DOCKER_MANIFEST
    log(f"  media types: manifest={man_mt}")

    new_cfg = dict(env_c)
    new_cfg["rootfs"] = {"type": "layers", "diff_ids": final_diff}
    new_cfg["history"] = final_hist
    # propagate the effective layer set onto container_config if present
    if isinstance(new_cfg.get("container_config"), dict):
        cc = dict(new_cfg["container_config"])
        cc.pop("Hostname", None)
        new_cfg["container_config"] = cc

    cfg_bytes = json.dumps(new_cfg, separators=(",", ":")).encode()
    cfg_digest = "sha256:" + hashlib.sha256(cfg_bytes).hexdigest()

    manifest = {
        "schemaVersion": 2,
        "mediaType": man_mt,
        "config": {"mediaType": cfg_mt, "size": len(cfg_bytes), "digest": cfg_digest},
        "layers": final_layers,
    }
    man_bytes = json.dumps(manifest, separators=(",", ":")).encode()

    total = sum(layer_size(l) for l in final_layers)
    log(f"== composed image: {len(final_layers)} layers, {total/1e9:.2f} GB, "
        f"config {len(cfg_bytes)} B, manifest {len(man_bytes)} B ==")

    if args.dry_run:
        log("dry-run: not pushing")
        return 0

    log("== pushing config blob ==")
    token = get_token(repo, "pull,push")
    st, hdrs, _ = request(f"{REG}/v2/{repo}/blobs/uploads/", token, method="POST",
                          data=b"", ctype="application/octet-stream")
    location = hdrs.get("Location") or hdrs.get("location")
    if not location:
        raise RuntimeError("no upload Location returned")
    if location.startswith("/"):
        location = REG + location
    sep = "&" if "?" in location else "?"
    put_url = f"{location}{sep}digest={urllib.parse.quote(cfg_digest, safe=':')}"
    st, _, _ = request(put_url, token, method="PUT", data=cfg_bytes,
                       ctype="application/octet-stream")
    log(f"  config uploaded ({st})")

    log("== pushing manifest ==")
    token = get_token(repo, "pull,push")
    st, _, body = request(f"{REG}/v2/{repo}/manifests/{args.out}", token,
                          method="PUT", data=man_bytes, ctype=man_mt)
    log(f"  manifest put -> {st} {body[:200]!r}")

    if args.out != "latest":
        token = get_token(repo, "pull,push")
        request(f"{REG}/v2/{repo}/manifests/latest", token, method="PUT",
                data=man_bytes, ctype=man_mt)
        log("  also tagged :latest")

    log("COMPOSE OK")
    return 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--repo", required=True)
    ap.add_argument("--env", required=True)
    ap.add_argument("--parts", required=True,
                    help="comma-separated part tags/digests, in layer order")
    ap.add_argument("--out", default="latest")
    ap.add_argument("--oci", action="store_true", help="force OCI media types")
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()
    args.parts = [p for p in args.parts.split(",") if p.strip()]
    try:
        return compose(args)
    except Exception as e:
        log(f"COMPOSE FAILED: {e}")
        return 1


if __name__ == "__main__":
    sys.exit(main())
