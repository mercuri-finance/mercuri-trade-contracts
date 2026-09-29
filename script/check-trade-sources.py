#!/usr/bin/env python3
"""Check the unchanged upstream compiler closures before local trade tests."""
import json
import pathlib
import subprocess
root = pathlib.Path(__file__).resolve().parents[1]
for name in ('universal-router', 'uniswapx'):
    base = root / 'lib' / name
    manifest = json.loads((base / 'source-manifest.json').read_text())
    expected = manifest['sources']
    actual = {str(p.relative_to(base)) for p in base.rglob('*.sol')}
    assert actual == set(expected), f'{name}: compiler source inventory changed'
    for source, digest in expected.items():
        content = (base / source).read_bytes()
        result = subprocess.run(['cast', 'keccak', '0x' + content.hex()], capture_output=True, text=True, check=True).stdout.strip()
        assert result == digest, f'{name}: source changed: {source}'
    print(f'{name}: {len(expected)} upstream sources match {manifest["revision"]}')
