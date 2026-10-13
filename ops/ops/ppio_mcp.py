#!/usr/bin/env python3
"""Run a JS snippet against the PPIO API through PPIO's hosted MCP server.

Why this exists: the PPIO API key we were given is rejected (401 "key not found"),
so there is no working key for a plain curl script. PPIO's MCP server is OAuth-based
and its token is already on disk, so this reuses that session instead.

It prints the API response (`data`) as JSON on stdout, so callers can pipe it into
python/`jq` exactly like a normal REST response.

Usage:
    ppio_mcp.py '<async () => { ... }>'      # JS expression
    ppio_mcp.py @file.js                     # JS read from a file

The JS runs with `api` in scope:
    api.request({method, path, apiProduct:"gpu", query, body})

MCP quirk to remember: responses are truncated at ~6000 tokens, so filter inside the
JS (`rows.filter(...)`) instead of returning a whole collection.
"""
import json
import os
import sys
import time
import urllib.error
import urllib.request

URL = "https://mcp.ppio.com/mcp"
TOKENS = os.path.expanduser("~/.commandcode/mcp-tokens.json")
SERVER = "ppio"


def die(msg, code=1):
    print(msg, file=sys.stderr)
    raise SystemExit(code)


def access_token():
    if not os.path.exists(TOKENS):
        die("no MCP token store at ~/.commandcode/mcp-tokens.json "
            "— run: cmd mcp auth ppio")
    tok = json.load(open(TOKENS)).get("tokens", {}).get(SERVER)
    if not tok:
        die("no stored token for 'ppio' — run: cmd mcp auth ppio")
    return tok["accessToken"]


def parse(raw, ctype):
    if "text/event-stream" in (ctype or ""):
        frames = []
        for line in raw.splitlines():
            if line.startswith("data:"):
                try:
                    frames.append(json.loads(line[5:].strip()))
                except Exception:
                    pass
        return frames[-1] if frames else None
    try:
        return json.loads(raw)
    except Exception:
        return None


def rpc(sid, tok, method, params=None, notify=False, rid=1):
    body = {"jsonrpc": "2.0", "method": method}
    if params is not None:
        body["params"] = params
    if not notify:
        body["id"] = rid
    hdr = {
        "Content-Type": "application/json",
        "Accept": "application/json, text/event-stream",
        "Authorization": f"Bearer {tok}",
    }
    if sid:
        hdr["Mcp-Session-Id"] = sid
    req = urllib.request.Request(URL, data=json.dumps(body).encode(), headers=hdr, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=120) as r:
            return parse(r.read().decode(errors="replace"), r.headers.get("Content-Type")), \
                   (r.headers.get("Mcp-Session-Id") or sid)
    except urllib.error.HTTPError as e:
        txt = e.read().decode(errors="replace")
        if e.code in (401, 403):
            die(f"MCP rejected the token ({e.code}) — re-auth with: cmd mcp auth ppio\n{txt[:300]}")
        return {"__error": e.code, "body": txt[:400]}, sid
    except Exception as e:
        die(f"could not reach {URL}: {e}")


def unwrap(resp):
    """Peel the MCP content envelope(s) down to the payload text.

    PPIO's server wraps results twice: the JSON-RPC result carries
    {"content":[{"type":"text","text": <another {"content":[{"text": ...}]}>}]},
    so a single unwrap yields an envelope string instead of the value.
    """
    try:
        text = resp["result"]["content"][0]["text"]
    except Exception:
        die(f"unexpected MCP result: {json.dumps(resp)[:500]}")
    for _ in range(4):
        try:
            obj = json.loads(text, strict=False)
        except Exception:
            return text
        if (isinstance(obj, dict) and isinstance(obj.get("content"), list) and obj["content"]
                and isinstance(obj["content"][0], dict) and "text" in obj["content"][0]):
            text = obj["content"][0]["text"]
            continue
        return text
    return text


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    js = sys.argv[1]
    if js.startswith("@"):
        js = open(js[1:], encoding="utf-8").read()

    tok = access_token()
    init, sid = rpc(None, tok, "initialize", {
        "protocolVersion": "2025-06-18",
        "capabilities": {},
        "clientInfo": {"name": "ppio.sh", "version": "1.0"},
    })
    if not init or "result" not in init:
        die(f"MCP initialize failed: {json.dumps(init)[:400]}")
    rpc(sid, tok, "notifications/initialized", {}, notify=True)

    resp, _ = rpc(sid, tok, "tools/call", {"name": "execute", "arguments": {"code": js}})
    text = unwrap(resp)

    if "--- TRUNCATED ---" in text:
        sys.stderr.write(
            "warning: MCP truncated this response (~6000 token limit).\n"
            "         Narrow the query or filter inside the JS.\n")

    try:
        env = json.loads(text, strict=False)
    except Exception:
        print(text)          # already a plain value
        return 0

    # `execute` wraps the API call as {success, status, data}
    if isinstance(env, dict) and "data" in env:
        if env.get("success") is False or (env.get("status") or 200) >= 400:
            die(f"API error {env.get('status')}: {json.dumps(env.get('error') or env)[:300]}")
        print(json.dumps(env["data"], ensure_ascii=False))
    else:
        print(json.dumps(env, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
