#!/usr/bin/env python3
"""Fetch the last green build's surefire XML artifacts into ./surefire-timings/.

Feeds generate.py's weighted sharding. Best-effort: on any failure it prints a
warning and exits 0, leaving surefire-timings/ empty so the generator falls back
to count-balanced sharding (its median default). Never fails the build.

Env:
  BUILDKITE_API_TOKEN  - a token with read_builds + read_artifacts
  BUILDKITE_ORG        - org slug (default questdb-1)
  BUILDKITE_PIPELINE   - pipeline slug (default questdb)
Stdlib only. Python 3.
"""
import json
import os
import sys
import urllib.request

ORG = os.environ.get("BUILDKITE_ORG", "questdb-1")
PIPE = os.environ.get("BUILDKITE_PIPELINE", "questdb")
TOKEN = os.environ.get("BUILDKITE_API_TOKEN", "")
OUT_DIR = "surefire-timings"
API = "https://api.buildkite.com/v2"


def _get(url, want_json=True):
    req = urllib.request.Request(url, headers={"Authorization": f"Bearer {TOKEN}"})
    with urllib.request.urlopen(req, timeout=30) as r:
        data = r.read()
    if not want_json:
        return data
    parsed = json.loads(data)
    # A Buildkite error (rate limit, not found, ...) comes back as a dict with a
    # "message" where a list was expected. Surface it so the caller degrades to
    # count-balanced sharding instead of silently iterating nothing.
    if isinstance(parsed, dict) and "message" in parsed and "number" not in parsed:
        raise RuntimeError(f"buildkite API: {parsed['message']}")
    return parsed


def main():
    if not TOKEN:
        sys.stderr.write("fetch_timings: no BUILDKITE_API_TOKEN; skipping (count-balanced sharding)\n")
        return
    os.makedirs(OUT_DIR, exist_ok=True)
    try:
        builds = _get(f"{API}/organizations/{ORG}/pipelines/{PIPE}/builds?state=passed&per_page=5")
        if not builds:
            sys.stderr.write("fetch_timings: no passed builds yet; skipping\n")
            return
        build_no = builds[0]["number"]
        arts = _get(f"{API}/organizations/{ORG}/pipelines/{PIPE}/builds/{build_no}/artifacts?per_page=100")
        n = 0
        for a in arts:
            path = a.get("path", "")
            if "surefire" in path and path.endswith(".xml") and a.get("download_url"):
                try:
                    xml = _get(a["download_url"], want_json=False)
                except Exception:
                    continue
                # flatten path to a safe filename
                fn = path.replace("/", "_")
                with open(os.path.join(OUT_DIR, fn), "wb") as f:
                    f.write(xml)
                n += 1
        sys.stderr.write(f"fetch_timings: wrote {n} surefire XMLs from green build #{build_no}\n")
    except Exception as e:
        sys.stderr.write(f"fetch_timings: best-effort failure ({e!r}); count-balanced sharding\n")


if __name__ == "__main__":
    main()
