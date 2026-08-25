#!/usr/bin/env python3
"""Verify the frozen Assistant speech reference bundle without model work."""

from __future__ import annotations

import hashlib
import json
from pathlib import Path


ROOT = Path(__file__).resolve().parent
MANIFEST = ROOT / "SOURCE_MANIFEST.json"


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main() -> int:
    manifest = json.loads(MANIFEST.read_text(encoding="utf-8"))
    failures: list[str] = []
    checked = 0
    for group in ("snapshots", "contracts"):
        for item in manifest[group]:
            path = ROOT / item["path"]
            checked += 1
            if not path.is_file():
                failures.append(f"missing: {item['path']}")
                continue
            actual = digest(path)
            if actual != item["sha256"]:
                failures.append(
                    f"hash mismatch: {item['path']} expected={item['sha256']} actual={actual}"
                )
            if group == "contracts":
                try:
                    json.loads(path.read_text(encoding="utf-8"))
                except (UnicodeDecodeError, json.JSONDecodeError) as exc:
                    failures.append(f"invalid JSON: {item['path']}: {exc}")
    if failures:
        for failure in failures:
            print(f"FAIL {failure}")
        return 1
    print(
        "OK assistant-speech-reference-manifest-v1 "
        f"files={checked} source={manifest['source']['commit']}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
