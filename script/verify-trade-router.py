#!/usr/bin/env python3
"""Read-only reproduction of every router runtime byte, including immutables."""
import hashlib
import json
from pathlib import Path
import subprocess
root = Path(__file__).resolve().parents[1]
report = json.loads((root / 'docs/reports/2026-09-27-trade-router-comparison.json').read_text())
artifact = json.loads((root / 'out/trade-router/UniversalRouter.sol/UniversalRouter.json').read_text())
names = {}
def visit(x):
    if isinstance(x, dict):
        if x.get('nodeType') == 'VariableDeclaration' and x.get('mutability') == 'immutable':
            names[str(x['id'])] = x['name']
        for v in x.values(): visit(v)
    elif isinstance(x, list):
        for v in x: visit(v)
for path in (root / 'out/trade-router').glob('*/*.json'):
    visit(json.loads(path.read_text()).get('ast', {}))
def cast(*args):
    return subprocess.run(['cast', *map(str,args)], capture_output=True, text=True, check=True).stdout.strip()
def keccak(raw):
    return cast('keccak', raw)
proofs = {x['chainId']: x['immutables'] for x in report['immutableProof']}
for network in report['networks']:
    chain = network['chainId']
    values = dict(proofs[chain])
    router = network['contracts']['router']['address']
    domain_type = keccak('EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)')
    domain = keccak(cast('abi-encode', 'f(bytes32,bytes32,bytes32,uint256,address)', domain_type,keccak('UniversalRouter'),keccak('2'),chain,router))
    assert values['_cachedDomainSeparator'] == domain
    assert int(values['_cachedChainId'],16) == chain
    bytecode = bytearray.fromhex(artifact['deployedBytecode']['object'].removeprefix('0x'))
    for key, refs in artifact['deployedBytecode']['immutableReferences'].items():
        value = bytes.fromhex(values[names[key]].removeprefix('0x'))
        for ref in refs:
            assert len(value) == ref['length']
            bytecode[ref['start']:ref['start']+ref['length']] = value
    rpc = 'https://rpc.testnet.arc.io' if chain == 5042002 else 'https://rpc.mainnet.arc.io'
    live = bytes.fromhex(cast('code',router,'--rpc-url',rpc,'--block',network['block']).removeprefix('0x'))
    assert hashlib.sha256(live).hexdigest() == network['contracts']['router']['sha256']
    assert bytecode == live, f'{chain}: runtime does not match reconstructed source'
    print(f'{chain}: all {len(live)} runtime bytes match at block {network["block"]}')
