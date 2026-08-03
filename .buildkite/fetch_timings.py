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
import time
import urllib.error
import urllib.request

ORG = os.environ.get("BUILDKITE_ORG", "questdb-1")
PIPE = os.environ.get("BUILDKITE_PIPELINE", "questdb")
TOKEN = os.environ.get("BUILDKITE_API_TOKEN", "")
OUT_DIR = "surefire-timings"
API = "https://api.buildkite.com/v2"

# Buildkite's per-user REST budget is small (50/window) and a full artifact
# sweep of one green build makes hundreds of calls, so 429s are expected, not
# exceptional. Honour Retry-After and cap the wait so a stuck limiter can never
# hang the build.
MAX_RETRIES = 5
MAX_RETRY_WAIT_S = 60


def _get(url, want_json=True):
    for attempt in range(MAX_RETRIES + 1):
        req = urllib.request.Request(url, headers={"Authorization": f"Bearer {TOKEN}"})
        try:
            with urllib.request.urlopen(req, timeout=30) as r:
                data = r.read()
            break
        except urllib.error.HTTPError as e:
            if e.code == 429 and attempt < MAX_RETRIES:
                # Prefer the server's Retry-After; fall back to a short backoff.
                wait = e.headers.get("Retry-After") or e.headers.get("RateLimit-Reset")
                try:
                    wait = min(int(wait), MAX_RETRY_WAIT_S)
                except (TypeError, ValueError):
                    wait = min(2 ** attempt, MAX_RETRY_WAIT_S)
                sys.stderr.write(f"fetch_timings: 429, waiting {wait}s (attempt {attempt + 1})\n")
                time.sleep(max(1, wait))
                continue
            raise
    if not want_json:
        return data
    parsed = json.loads(data)
    # A Buildkite error (rate limit, not found, ...) comes back as a dict with a
    # "message" where a list was expected. Surface it so the caller degrades to
    # count-balanced sharding instead of silently iterating nothing.
    if isinstance(parsed, dict) and "message" in parsed and "number" not in parsed:
        raise RuntimeError(f"buildkite API: {parsed['message']}")
    return parsed


def _get_all_pages(url):
    """Fetch every page of a paginated list endpoint (Buildkite caps per_page at 100).

    The old single-page fetch silently capped the artifact list at 100 XMLs, so
    the generator only ever saw the first ~100 test classes' timings. Walk pages
    until one comes back short.
    """
    sep = "&" if "?" in url else "?"
    out = []
    page = 1
    while True:
        chunk = _get(f"{url}{sep}per_page=100&page={page}")
        if not isinstance(chunk, list) or not chunk:
            break
        out.extend(chunk)
        if len(chunk) < 100:
            break
        page += 1
    return out


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
        arts = _get_all_pages(f"{API}/organizations/{ORG}/pipelines/{PIPE}/builds/{build_no}/artifacts")
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
