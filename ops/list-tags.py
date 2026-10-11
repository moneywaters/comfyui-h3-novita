#!/usr/bin/env python3
"""Print the non-`part-*` tags of a Docker Hub repo with sizes.

Usage: list-tags.py <namespace/repo>
"""
import json
import sys
import urllib.request

SKIP_PREFIX = "part-"


def main():
    if len(sys.argv) < 2:
        print("usage: list-tags.py <namespace/repo>")
        return 2
    repo = sys.argv[1].strip("/")
    url = f"https://hub.docker.com/v2/repositories/{repo}/tags?page_size=50"
    try:
        with urllib.request.urlopen(url, timeout=45) as r:
            d = json.load(r)
    except Exception as e:
        print(f"  could not list tags for {repo}: {e}")
        return 1
    rows = [t for t in d.get("results", []) if not t["name"].startswith(SKIP_PREFIX)]
    if not rows:
        print(f"  {repo}: no non-part tags")
        return 0
    for t in sorted(rows, key=lambda x: x["name"]):
        print(f"  {t['name']:<20} {t.get('full_size', 0)/1e9:8.2f} GB  {t.get('last_updated','')[:19]}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
