#!/usr/bin/env python3
"""Assert every composed image is under Novita's 100 GB per-image prewarm cap."""
import json
import sys
import urllib.request

CAP_GB = 100.0


def tags(repo):
    url = f"https://hub.docker.com/v2/repositories/{repo}/tags?page_size=25"
    with urllib.request.urlopen(url, timeout=45) as r:
        return json.load(r).get("results", [])


def main():
    repos = sys.argv[1:]
    if not repos:
        print("usage: check-sizes.py <repo> [repo...]")
        return 2
    bad = 0
    for repo in repos:
        print(f"--- {repo} ---")
        try:
            rows = tags(repo)
        except Exception as e:
            print(f"  ERROR querying: {e}")
            bad += 1
            continue
        final = [t for t in rows if t["name"] == "latest"]
        if not final:
            print("  ERROR: no :latest tag found")
            bad += 1
            continue
        for t in rows:
            gb = t.get("full_size", 0) / 1e9
            if t["name"] != "latest" and not t["name"].startswith("part-"):
                continue
            if t["name"] != "latest":
                continue
            flag = "OK  " if gb < CAP_GB else "OVER"
            print(f"  {flag} {t['name']:<12} {gb:7.2f} GB  (cap {CAP_GB:.0f} GB)")
            if gb >= CAP_GB:
                bad += 1
    if bad:
        print(f"FAILED: {bad} problem(s)")
        return 1
    print("all composed images are under the prewarm cap")
    return 0


if __name__ == "__main__":
    sys.exit(main())
