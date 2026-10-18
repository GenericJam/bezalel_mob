"""Publish the built packs (data/out) to the R2 bucket behind PUBLIC_BASE as the next
data version, then point the manifest at it.

  python3 data/scripts/publish.py [--dry-run]

Layout, served at PUBLIC_BASE:
  packs/v<N>/<pack>.sqlite.zst   immutable; an existing object is never replaced
  packs/manifest.json            the only mutable object, uploaded last, no-cache

N is one more than the manifest's data_version (1 if there is no manifest), or
--version N. An object already at packs/v<N>/ is accepted only if it is
byte-identical to the local file (an interrupted publish resumes); anything else
stops the publish (after a rebuild, rerun with a fresh --version: unreferenced
v<N> objects are harmless). Every upload is verified by fetching it from
PUBLIC_BASE and comparing size and sha256. All reads add a unique query string so
they reach R2, not a Cloudflare edge copy (which caches 404s too).
The data/ directory must be committed, so the manifest's bezalel_commit names the
build that made the packs. Needs: npx (wrangler, logged in to the account that owns
the bucket), git, network. Standard library only.
"""

from __future__ import annotations

import argparse
import datetime
import uuid
import hashlib
import json
import subprocess
import sys
import urllib.error
import urllib.request
from pathlib import Path

BUCKET = "bezalel-packs"
PUBLIC_BASE = "https://bezalel.genericjam.com"
MANIFEST_KEY = "packs/manifest.json"
MANIFEST_SCHEMA = 1
PACK_CACHE = "public, max-age=31536000, immutable"
DATA = Path(__file__).resolve().parent.parent
OUT = DATA / "out"


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def fetch(key: str) -> bytes | None:
    """The object at PUBLIC_BASE/key, or None if it doesn't exist. The unique query
    string makes the request miss the edge cache, so the answer comes from R2."""
    request = urllib.request.Request(
        f"{PUBLIC_BASE}/{key}?publish={uuid.uuid4().hex}", headers={"User-Agent": "bezalel-publish/1"}
    )
    try:
        with urllib.request.urlopen(request, timeout=300) as response:
            return response.read()
    except urllib.error.HTTPError as error:
        if error.code == 404:
            return None
        raise


def wrangler(*args: str) -> None:
    subprocess.run(["npx", "-y", "wrangler@4", *args], check=True)


def put(key: str, path: Path, content_type: str, cache_control: str, dry_run: bool) -> None:
    print(f"  put {key} ({path.stat().st_size:,} bytes)")
    if not dry_run:
        wrangler("r2", "object", "put", f"{BUCKET}/{key}", "--file", str(path), "--remote",
                 "--content-type", content_type, "--cache-control", cache_control)


def verify(key: str, size: int, sha256: str) -> None:
    served = fetch(key)
    if served is None or len(served) != size or sha256_bytes(served) != sha256:
        sys.exit(f"{PUBLIC_BASE}/{key}: served object does not match (size, sha256)")
    print(f"  verified {PUBLIC_BASE}/{key}")


def read_sizes() -> dict[str, dict]:
    lines = (OUT / "sizes.tsv").read_text().splitlines()
    header = lines[0].split("\t")
    return {row[0]: dict(zip(header, row)) for row in (line.split("\t") for line in lines[1:])}


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--dry-run", action="store_true", help="check and print, upload nothing")
    parser.add_argument("--version", type=int, help="data version to publish (default: manifest's + 1)")
    args = parser.parse_args()

    if subprocess.run(["git", "status", "--porcelain", "--", str(DATA)], capture_output=True,
                      text=True, check=True, cwd=DATA).stdout.strip():
        sys.exit("data/ has uncommitted changes; commit the build that made the packs first")
    commit = subprocess.run(["git", "rev-parse", "HEAD"], capture_output=True, text=True,
                            check=True, cwd=DATA).stdout.strip()

    packs = json.loads((DATA / "packs.json").read_text())["packs"]
    pins = json.loads((DATA / "pins.json").read_text())
    sizes = read_sizes()
    if set(sizes) != set(packs):
        sys.exit(f"out/sizes.tsv packs {sorted(sizes)} differ from packs.json {sorted(packs)}")

    current = fetch(MANIFEST_KEY)
    previous = json.loads(current) if current else None
    version = args.version if args.version is not None else (previous["data_version"] if previous else 0) + 1
    if version < 1 or (previous and version <= previous["data_version"]):
        sys.exit(f"version {version} must be at least 1 and newer than the published one")
    print(f"Publishing data version {version} (previous: {previous['data_version'] if previous else 'none'})")

    entries = []
    for name, spec in packs.items():
        path = OUT / f"{name}.sqlite.zst"
        data = path.read_bytes()
        digest = sha256_bytes(data)
        if digest != sizes[name]["zst_sha256"]:
            sys.exit(f"{path}: sha256 differs from out/sizes.tsv; rebuild")
        key = f"packs/v{version}/{name}.sqlite.zst"
        existing = fetch(key)
        if existing is not None and sha256_bytes(existing) != digest:
            sys.exit(f"{PUBLIC_BASE}/{key} exists with different content; refusing to overwrite")
        if existing is None:
            put(key, path, "application/zstd", PACK_CACHE, args.dry_run)
        else:
            print(f"  {key} already uploaded (identical)")
        if not args.dry_run:
            verify(key, len(data), digest)
        entries.append({
            "name": name,
            "description": spec["description"],
            "required": spec["required"],
            "licence": spec["licence"],
            "url": f"{PUBLIC_BASE}/{key}",
            "compression": "zstd",
            "size": len(data),
            "sha256": digest,
            "raw_size": int(sizes[name]["raw_bytes"]),
            "raw_sha256": sizes[name]["sha256"],
            "tables": spec["tables"],
        })

    built = datetime.datetime.fromtimestamp((OUT / "sizes.tsv").stat().st_mtime, datetime.timezone.utc)
    manifest = {
        "schema": MANIFEST_SCHEMA,
        "data_version": version,
        "built": built.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "bezalel_commit": commit,
        "studybible_mcp": pins["studybible_mcp"],
        "sources": "https://github.com/GenericJam/bezalel_mob/blob/master/data/SOURCES.md",
        "packs": entries,
    }
    body = (json.dumps(manifest, indent=2, ensure_ascii=False) + "\n").encode()
    local = OUT / "manifest.json"
    local.write_bytes(body)
    put(MANIFEST_KEY, local, "application/json", "no-cache", args.dry_run)
    if not args.dry_run:
        verify(MANIFEST_KEY, len(body), sha256_bytes(body))
    print(f"\nManifest: {PUBLIC_BASE}/{MANIFEST_KEY} -> data version {version}")


if __name__ == "__main__":
    main()
