#!/usr/bin/env python3
"""Verify the production filler source against its reviewed source manifest."""
import hashlib
import json
from pathlib import Path

root = Path(__file__).resolve().parents[1]
manifest = json.loads((root / 'source-manifest.json').read_text())
if manifest.get('algorithm') != 'sha256' or set(manifest.get('sources', {})) != {'src/MercuriOrderFiller.sol'}:
    raise SystemExit('unexpected Trade production source manifest')
for name, want in manifest['sources'].items():
    got = hashlib.sha256((root / name).read_bytes()).hexdigest()
    if got != want:
        raise SystemExit(f'{name}: source hash differs from manifest')
    print(f'{name}: sha256 {got}')
