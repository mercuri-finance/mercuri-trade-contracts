#!/usr/bin/env python3
"""Read-only reproduction of the Trade reactor and filler runtime bytes at a pinned block.

Rebuilds each expected runtime from out/ (deployedBytecode + immutableReferences) with the manifest and
deployment immutables substituted, then compares byte for byte with eth_getCode. Prints MATCH or the
differing offsets and exits non-zero on any mismatch. No keys, no signing, no writes.

  python3 script/verify-trade-filler.py --rpc URL --block N --deployment FILE   # FILE has reactor, filler,
                                                                                # reactorFeeOwner
  python3 script/verify-trade-filler.py --self-test                             # offline, no network
"""
import argparse
import json
import subprocess
import sys
import urllib.request
from pathlib import Path

root = Path(__file__).resolve().parents[1]
DEFAULT_RPC = 'https://rpc.testnet.arc.network'
JUMPDEST = 0x5B


def cast_keccak(raw):
    return subprocess.run(['cast', 'keccak', '0x' + raw.hex()], capture_output=True, text=True, check=True).stdout.strip()


def rpc_call(url, method, params):
    request = urllib.request.Request(
        url,
        json.dumps({'jsonrpc': '2.0', 'id': 1, 'method': method, 'params': params}).encode(),
        {'content-type': 'application/json', 'user-agent': 'curl/8.7.1'},
    )
    with urllib.request.urlopen(request, timeout=30) as response:
        body = json.loads(response.read())
    if 'error' in body:
        raise SystemExit(f'{method}: {body["error"]}')
    return body['result']


def immutable_names(artifact):
    names = {}

    def visit(node):
        if isinstance(node, dict):
            if node.get('nodeType') == 'VariableDeclaration' and node.get('mutability') == 'immutable':
                names[str(node['id'])] = node['name']
            for value in node.values():
                visit(value)
        elif isinstance(node, list):
            for value in node:
                visit(value)

    visit(artifact.get('ast', {}))
    # Inherited immutables are declared in other sources; resolve their ids against the sibling ASTs.
    needed = {str(k) for k in artifact['deployedBytecode']['immutableReferences']}
    if not needed <= set(names):
        for path in sorted((root / 'out').glob('*/*.json')):
            if needed <= set(names):
                break
            visit(json.loads(path.read_text()).get('ast', {}))
    missing = needed - set(names)
    if missing:
        raise SystemExit(f'cannot name immutable ids {sorted(missing)}')
    return names


def address_word(address):
    return bytes(12) + bytes.fromhex(address.removeprefix('0x').rjust(40, '0'))


def expected_runtime(artifact, values, pointers=None):
    """Return (expected bytes, immutable ranges). Values map immutable name to a 32-byte word.

    A name missing from values is an internal function pointer. Via-IR stores a small compiler-assigned function id
    there, which source and manifest cannot supply, so it is read from `pointers`: the runtime a simulated
    constructor call returns for the same creation bytecode and arguments. It must be a small id.
    """
    code = bytearray.fromhex(artifact['deployedBytecode']['object'].removeprefix('0x'))
    names = immutable_names(artifact)
    ranges = []
    for key, refs in artifact['deployedBytecode']['immutableReferences'].items():
        name = names[key]
        for ref in refs:
            start, length = ref['start'], ref['length']
            ranges.append((start, start + length, name))
            if name in values:
                assert length == 32 and len(values[name]) == 32
                code[start:start + length] = values[name]
            elif pointers is not None and len(pointers) >= start + length:
                if int.from_bytes(pointers[start:start + length], 'big') > 0xFF:
                    raise SystemExit(f'immutable {name} is not a small function id')
                code[start:start + length] = pointers[start:start + length]
    return bytes(code), ranges


def differing(expected, live):
    if len(expected) != len(live):
        return [f'length {len(live)} != expected {len(expected)}']
    offsets = [i for i in range(len(live)) if expected[i] != live[i]]
    return offsets


def verify(label, artifact, values, live, pointers=None):
    expected, ranges = expected_runtime(artifact, values, pointers)
    diff = differing(expected, live)
    if diff:
        where = ''
        if diff and isinstance(diff[0], int):
            hit = sorted({n for s, e, n in ranges if any(s <= o < e for o in diff)})
            where = f' (inside immutables: {", ".join(hit) or "none"})'
        print(f'{label}: MISMATCH at offsets {diff[:32]}{" ..." if len(diff) > 32 else ""}{where}')
        return False
    print(f'{label}: MATCH {len(live)} runtime bytes, keccak {cast_keccak(live)}')
    return True


def load(path):
    return json.loads((root / path).read_text())


def reactor_artifacts():
    return sorted((root / 'out/V3DutchOrderReactor.sol').glob('V3DutchOrderReactor.*.json'))


def manifest_values(manifest, reactor):
    return {
        'reactor': address_word(reactor),
        'router': address_word(manifest['router']),
        'permit2': address_word(manifest['permit2']),
        'usdc': address_word(manifest['usdc']),
        'launchHook': address_word(manifest['launchHook']),
        'appRecipient': address_word(manifest['appRecipient']),
    }


def verify_reactor(args, manifest, deployment, tag, live):
    """The compiler profile is selected by forge, so try each built variant and accept an exact match."""
    word = address_word(manifest['permit2'])
    owner = rpc_call(args.rpc, 'eth_call', [{'to': deployment['reactor'], 'data': '0x8da5cb5b'}, tag])
    owner = '0x' + owner[-40:]
    ctor = subprocess.run(
        ['cast', 'abi-encode', 'constructor(address,address)', manifest['permit2'], owner],
        capture_output=True, text=True, check=True,
    ).stdout.strip().removeprefix('0x')
    first = None
    for path in reactor_artifacts():
        artifact = json.loads(path.read_text())
        creation = '0x' + artifact['bytecode']['object'].removeprefix('0x') + ctor
        simulated = bytes.fromhex(rpc_call(args.rpc, 'eth_call', [{'data': creation}, tag]).removeprefix('0x'))
        expected, _ = expected_runtime(artifact, {'permit2': word}, simulated)
        if expected == live:
            return verify(f'reactor ({path.name})', artifact, {'permit2': word}, live, simulated)
        first = first or (path, artifact, simulated)
    path, artifact, simulated = first
    verify(f'reactor ({path.name})', artifact, {'permit2': word}, live, simulated)
    return False


def self_test(flip):
    manifest = load('deployments/manifest-5042002.json')
    filler = load('out/MercuriOrderFiller.sol/MercuriOrderFiller.json')
    fake_reactor = '0x00000000000000000000000000000000000000aa'
    values = manifest_values(manifest, fake_reactor)
    live, ranges = expected_runtime(filler, values)
    live = bytearray(live)
    if flip:
        # Flip one byte inside the usdc immutable, as a wrong constructor argument would.
        start = next(s for s, e, n in ranges if n == 'usdc')
        live[start + 31] ^= 0x01
    ok = verify('filler self-test' + (' (one immutable byte flipped)' if flip else ''), filler, values, bytes(live))
    return ok


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--rpc', default=DEFAULT_RPC)
    parser.add_argument('--block', type=int)
    parser.add_argument('--deployment', help='JSON with reactor, filler and reactorFeeOwner')
    parser.add_argument('--manifest', default='deployments/manifest-5042002.json')
    parser.add_argument('--self-test', action='store_true', help='offline: unmodified bytes must match, a flipped immutable byte must not')
    parser.add_argument('--self-test-flipped', action='store_true', help='offline: verify with one immutable byte flipped; exits non-zero')
    args = parser.parse_args()

    if args.self_test_flipped:
        sys.exit(0 if self_test(True) else 1)
    if args.self_test:
        good = self_test(False)
        bad = self_test(True)
        if not good or bad:
            print('self-test FAILED: verifier did not behave as required')
            sys.exit(1)
        print('self-test ok: unmodified runtime matches, flipped immutable byte is rejected')
        return
    if args.block is None or not args.deployment:
        parser.error('--block and --deployment are required')

    manifest = load(args.manifest)
    deployment = json.loads(Path(args.deployment).read_text())
    chain = int(rpc_call(args.rpc, 'eth_chainId', []), 16)
    assert chain == manifest['chainId'], f'chain id {chain} != manifest {manifest["chainId"]}'
    tag = hex(args.block)
    block = rpc_call(args.rpc, 'eth_getBlockByNumber', [tag, False])
    print(f'block {args.block} hash {block["hash"]}')

    def code(address):
        return bytes.fromhex(rpc_call(args.rpc, 'eth_getCode', [address, tag]).removeprefix('0x'))

    ok = verify_reactor(args, manifest, deployment, tag, code(deployment['reactor']))
    filler = load('out/MercuriOrderFiller.sol/MercuriOrderFiller.json')
    ok &= verify('filler', filler, manifest_values(manifest, deployment['reactor']), code(deployment['filler']))
    owner = rpc_call(args.rpc, 'eth_call', [{'to': deployment['reactor'], 'data': '0x8da5cb5b'}, tag])
    owner = '0x' + owner[-40:]
    if 'reactorFeeOwner' in deployment and owner.lower() != deployment['reactorFeeOwner'].lower():
        print(f'reactor owner {owner} != recorded reactorFeeOwner {deployment["reactorFeeOwner"]}')
        ok = False
    else:
        print(f'reactor owner {owner}')
    sys.exit(0 if ok else 1)


if __name__ == '__main__':
    main()
