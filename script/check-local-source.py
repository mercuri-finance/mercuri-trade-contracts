#!/usr/bin/env python3
"""Verify the production sources against their reviewed source manifest: every `src/` file listed, none extra."""
import hashlib
import json
from pathlib import Path

root = Path(__file__).resolve().parents[1]
manifest = json.loads((root / 'source-manifest.json').read_text())
actual = {str(p.relative_to(root)) for p in (root / 'src').rglob('*.sol')}
if manifest.get('algorithm') != 'sha256' or set(manifest.get('sources', {})) != actual:
    raise SystemExit(f'unexpected Trade production source manifest: src/ holds {sorted(actual)}')
for name, want in sorted(manifest['sources'].items()):
    got = hashlib.sha256((root / name).read_bytes()).hexdigest()
    if got != want:
        raise SystemExit(f'{name}: source hash differs from manifest')
    print(f'{name}: sha256 {got}')
