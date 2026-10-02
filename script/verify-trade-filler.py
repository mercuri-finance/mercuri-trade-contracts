#!/usr/bin/env python3
"""Read-only reproduction of the Trade reactor and filler runtime bytes at a pinned block.

Rebuilds each expected runtime from out/ (deployedBytecode + immutableReferences) with the manifest and
deployment immutables substituted, then compares byte for byte with eth_getCode. Prints MATCH or the
differing offsets and exits non-zero on any mismatch. No keys, no signing, no writes.

  python3 script/verify-trade-filler.py --rpc URL --block N --deployment FILE   # FILE has reactor, filler,
                                                                                # reactorFeeOwner, feeRecipient
  python3 script/verify-trade-filler.py --self-test                             # offline, no network
  python3 script/verify-trade-filler.py --self-test-reactor-flipped             # offline; must report MISMATCH
"""
import argparse
import json
import subprocess
import sys
import urllib.request
from pathlib import Path

root = Path(__file__).resolve().parents[1]
DEFAULT_RPC = 'https://rpc.testnet.arc.network'
SENTINEL = 'REQUIRED_AT_D2_OWNER_GO'
RECIPIENT_SENTINEL = 'REQUIRED_AT_D3_OWNER_GO'
MAX_EXECUTION_FEE = 100_000
POINTER = '_getBlockNumberish'
# The only immutables each contract may carry. A different set in either direction is a reviewed-source change.
EXPECTED_IMMUTABLES = {
    'filler': {'reactor', 'router', 'permit2', 'usdc', 'launchHook', 'appRecipient', 'executionFee', 'feeRecipient'},
    'reactor': {'permit2', POINTER},
}


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


def expected_runtime(artifact, values, kind, pointers=None):
    """Return (expected bytes, immutable ranges). Values map immutable name to a 32-byte word.

    A name missing from values is an internal function pointer. Via-IR stores a small compiler-assigned function id
    there, which source and manifest cannot supply, so it is read from `pointers`: the runtime a simulated
    constructor call returns for the same creation bytecode and arguments. It must be a small id.
    """
    code = bytearray.fromhex(artifact['deployedBytecode']['object'].removeprefix('0x'))
    names = immutable_names(artifact)
    found = {names[key] for key in artifact['deployedBytecode']['immutableReferences']}
    if found != EXPECTED_IMMUTABLES[kind]:
        raise SystemExit(
            f'{kind}: immutable set differs: unexpected {sorted(found - EXPECTED_IMMUTABLES[kind])}, '
            f'missing {sorted(EXPECTED_IMMUTABLES[kind] - found)}'
        )
    ranges = []
    for key, refs in artifact['deployedBytecode']['immutableReferences'].items():
        name = names[key]
        for ref in refs:
            start, length = ref['start'], ref['length']
            ranges.append((start, start + length, name))
            if name in values:
                if length != 32 or len(values[name]) != 32:
                    raise SystemExit(f'{kind}: immutable {name} is not one 32-byte word')
                code[start:start + length] = values[name]
            elif name != POINTER:
                raise SystemExit(f'{kind}: no value supplied for immutable {name}')
            elif pointers is None or len(pointers) < start + length:
                raise SystemExit(f'{kind}: no constructor simulation for {name}')
            else:
                if int.from_bytes(pointers[start:start + length], 'big') > 0xFF:
                    raise SystemExit(f'immutable {name} is not a small function id')
                code[start:start + length] = pointers[start:start + length]
    return bytes(code), ranges


def differing(expected, live):
    if len(expected) != len(live):
        return [f'length {len(live)} != expected {len(expected)}']
    offsets = [i for i in range(len(live)) if expected[i] != live[i]]
    return offsets


def verify(label, kind, artifact, values, live, pointers=None):
    expected, ranges = expected_runtime(artifact, values, kind, pointers)
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


def uint_word(value):
    return value.to_bytes(32, 'big')


def execution_fee(manifest):
    """The manifest fee as the filler stores it: an integer in USDC units, at most MAX_EXECUTION_FEE."""
    fee = manifest.get('executionFee')
    if type(fee) is not int or not 0 <= fee <= MAX_EXECUTION_FEE:
        raise SystemExit(f'manifest executionFee is not an integer in [0, {MAX_EXECUTION_FEE}]: {fee!r}')
    return fee


def manifest_values(manifest, reactor, fee_recipient):
    return {
        'reactor': address_word(reactor),
        'router': address_word(manifest['router']),
        'permit2': address_word(manifest['permit2']),
        'usdc': address_word(manifest['usdc']),
        'launchHook': address_word(manifest['launchHook']),
        'appRecipient': address_word(manifest['appRecipient']),
        'executionFee': uint_word(execution_fee(manifest)),
        'feeRecipient': address_word(fee_recipient),
    }


def verify_reactor(args, manifest, owner, tag, live):
    """The compiler profile is selected by forge, so try each built variant and accept an exact match."""
    word = address_word(manifest['permit2'])
    ctor = subprocess.run(
        ['cast', 'abi-encode', 'constructor(address,address)', manifest['permit2'], owner],
        capture_output=True, text=True, check=True,
    ).stdout.strip().removeprefix('0x')
    first = None
    for path in reactor_artifacts():
        artifact = json.loads(path.read_text())
        creation = '0x' + artifact['bytecode']['object'].removeprefix('0x') + ctor
        simulated = bytes.fromhex(rpc_call(args.rpc, 'eth_call', [{'data': creation}, tag]).removeprefix('0x'))
        expected, _ = expected_runtime(artifact, {'permit2': word}, 'reactor', simulated)
        if expected == live:
            return verify(f'reactor ({path.name})', 'reactor', artifact, {'permit2': word}, live, simulated)
        first = first or (path, artifact, simulated)
    path, artifact, simulated = first
    verify(f'reactor ({path.name})', 'reactor', artifact, {'permit2': word}, live, simulated)
    return False


def required_owner(manifest, deployment):
    """The fee owner is mandatory: an address in the manifest, never the sentinel, and equal to the record."""
    owner = manifest.get('reactorFeeOwner', '')
    if owner == SENTINEL:
        raise SystemExit('manifest reactorFeeOwner is still the sentinel; the owner choice has not been recorded')
    if not (isinstance(owner, str) and len(owner) == 42 and owner.startswith('0x')):
        raise SystemExit(f'manifest reactorFeeOwner is not an address: {owner!r}')
    int(owner, 16)
    recorded = deployment.get('reactorFeeOwner')
    if recorded is None or recorded.lower() != owner.lower():
        raise SystemExit(f'deployment reactorFeeOwner {recorded!r} != manifest {owner}')
    return owner


def required_fee_recipient(manifest, deployment):
    """The execution fee recipient is mandatory: an address in the manifest, never the sentinel, equal to the record."""
    recipient = manifest.get('feeRecipient', '')
    if recipient == RECIPIENT_SENTINEL:
        raise SystemExit('manifest feeRecipient is still the sentinel; the owner choice has not been recorded')
    if not (isinstance(recipient, str) and len(recipient) == 42 and recipient.startswith('0x')):
        raise SystemExit(f'manifest feeRecipient is not an address: {recipient!r}')
    if int(recipient, 16) == 0:
        raise SystemExit('manifest feeRecipient is the zero address')
    recorded = deployment.get('feeRecipient')
    if recorded is None or recorded.lower() != recipient.lower():
        raise SystemExit(f'deployment feeRecipient {recorded!r} != manifest {recipient}')
    return recipient


# Offline self-tests stand in for the owner's D3 choice with this placeholder recipient.
SELF_TEST_RECIPIENT = '0x00000000000000000000000000000000000000bb'


def expect_rejected(label, artifact, values, kind):
    try:
        expected_runtime(artifact, values, kind)
    except SystemExit as error:
        print(f'{label}: rejected ({error})')
        return True
    print(f'{label}: NOT rejected')
    return False


def immutable_set_self_test():
    import copy
    manifest = load('deployments/manifest-5042002.json')
    filler = load('out/MercuriOrderFiller.sol/MercuriOrderFiller.json')
    values = manifest_values(manifest, '0x00000000000000000000000000000000000000aa', SELF_TEST_RECIPIENT)
    extra = copy.deepcopy(filler)
    extra['deployedBytecode']['immutableReferences']['999999999'] = [{'start': 0, 'length': 32}]
    extra.setdefault('ast', {}).setdefault('nodes', []).append(
        {'nodeType': 'VariableDeclaration', 'mutability': 'immutable', 'id': 999999999, 'name': 'sneakyZero'}
    )
    missing = copy.deepcopy(filler)
    del missing['deployedBytecode']['immutableReferences'][next(iter(missing['deployedBytecode']['immutableReferences']))]
    return expect_rejected('unknown immutable', extra, values, 'filler') & expect_rejected(
        'missing immutable', missing, values, 'filler'
    )


def self_test(flip):
    manifest = load('deployments/manifest-5042002.json')
    filler = load('out/MercuriOrderFiller.sol/MercuriOrderFiller.json')
    fake_reactor = '0x00000000000000000000000000000000000000aa'
    values = manifest_values(manifest, fake_reactor, SELF_TEST_RECIPIENT)
    live, ranges = expected_runtime(filler, values, 'filler')
    live = bytearray(live)
    if flip:
        # Flip one byte inside the usdc immutable, as a wrong constructor argument would.
        start = next(s for s, e, n in ranges if n == 'usdc')
        live[start + 31] ^= 0x01
    ok = verify('filler self-test' + (' (one immutable byte flipped)' if flip else ''), 'filler', filler, values, bytes(live))
    return ok


# A known via-IR function id for the reactor's _getBlockNumberish pointer. Offline there is no constructor to
# simulate, so the self-test stands in for eth_call's returned runtime with this id written into the slots.
KNOWN_POINTER_ID = 0x2A


def simulated_reactor_runtime(artifact, permit2_word, pointer_id):
    """The runtime a constructor simulation would return: permit2 filled in, each pointer slot set to the id."""
    code = bytearray.fromhex(artifact['deployedBytecode']['object'].removeprefix('0x'))
    names = immutable_names(artifact)
    for key, refs in artifact['deployedBytecode']['immutableReferences'].items():
        for ref in refs:
            start, length = ref['start'], ref['length']
            word = permit2_word if names[key] == 'permit2' else pointer_id.to_bytes(32, 'big')
            code[start:start + length] = word
    return bytes(code)


def reactor_self_test(flip):
    """Exercise the function-pointer path for every built reactor profile.

    Unmodified, the live code equals the simulation and must MATCH. With flip, one byte of the pointer slot in the
    live code differs from the simulation (a different compiler profile or a tampered runtime) and must MISMATCH.
    A simulated pointer that is not a small id must be refused before any comparison.
    """
    manifest = load('deployments/manifest-5042002.json')
    word = address_word(manifest['permit2'])
    artifacts = reactor_artifacts()
    if not artifacts:
        raise SystemExit('no V3DutchOrderReactor artifacts in out/; run forge build')
    ok = True
    for path in artifacts:
        artifact = json.loads(path.read_text())
        simulated = simulated_reactor_runtime(artifact, word, KNOWN_POINTER_ID)
        live = bytearray(simulated)
        if flip:
            _, ranges = expected_runtime(artifact, {'permit2': word}, 'reactor', simulated)
            start = next(s for s, e, n in ranges if n == POINTER)
            live[start + 31] ^= 0x01
        label = f'reactor self-test ({path.name})' + (' (pointer byte flipped)' if flip else '')
        ok &= verify(label, 'reactor', artifact, {'permit2': word}, bytes(live), simulated)
        if not flip:
            try:
                expected_runtime(artifact, {'permit2': word}, 'reactor', simulated_reactor_runtime(artifact, word, 0x1FF))
                print(f'{path.name}: a pointer id above 0xff was NOT rejected')
                ok = False
            except SystemExit as error:
                print(f'{path.name}: large pointer id rejected ({error})')
    return ok


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--rpc', default=DEFAULT_RPC)
    parser.add_argument('--block', type=int)
    parser.add_argument('--deployment', help='JSON with reactor, filler, reactorFeeOwner and feeRecipient')
    parser.add_argument('--manifest', default='deployments/manifest-5042002.json')
    parser.add_argument('--self-test', action='store_true', help='offline: unmodified bytes must match, a flipped immutable byte must not')
    parser.add_argument('--self-test-flipped', action='store_true', help='offline: verify with one immutable byte flipped; exits non-zero')
    parser.add_argument('--self-test-reactor-flipped', action='store_true', help='offline: verify the reactor with one function-pointer byte flipped; exits non-zero')
    args = parser.parse_args()

    if args.self_test_flipped:
        sys.exit(0 if self_test(True) else 1)
    if args.self_test_reactor_flipped:
        sys.exit(0 if reactor_self_test(True) else 1)
    if args.self_test:
        good = self_test(False)
        bad = self_test(True)
        sets = immutable_set_self_test()
        reactor_good = reactor_self_test(False)
        reactor_bad = reactor_self_test(True)
        if not good or bad or not sets or not reactor_good or reactor_bad:
            print('self-test FAILED: verifier did not behave as required')
            sys.exit(1)
        print('self-test ok: unmodified runtimes match; a flipped filler immutable byte and a flipped reactor function-pointer byte are rejected')
        return
    if args.block is None or not args.deployment:
        parser.error('--block and --deployment are required')

    manifest = load(args.manifest)
    deployment = json.loads(Path(args.deployment).read_text())
    chain = int(rpc_call(args.rpc, 'eth_chainId', []), 16)
    if chain != manifest['chainId']:
        raise SystemExit(f'chain id {chain} != manifest {manifest["chainId"]}')
    tag = hex(args.block)
    block = rpc_call(args.rpc, 'eth_getBlockByNumber', [tag, False])
    print(f'block {args.block} hash {block["hash"]}')

    def code(address):
        return bytes.fromhex(rpc_call(args.rpc, 'eth_getCode', [address, tag]).removeprefix('0x'))

    owner = required_owner(manifest, deployment)
    fee_recipient = required_fee_recipient(manifest, deployment)
    ok = verify_reactor(args, manifest, owner, tag, code(deployment['reactor']))
    filler = load('out/MercuriOrderFiller.sol/MercuriOrderFiller.json')
    ok &= verify('filler', 'filler', filler, manifest_values(manifest, deployment['reactor'], fee_recipient), code(deployment['filler']))
    onchain = rpc_call(args.rpc, 'eth_call', [{'to': deployment['reactor'], 'data': '0x8da5cb5b'}, tag])
    onchain = '0x' + onchain[-40:]
    if onchain.lower() != owner.lower():
        print(f'reactor owner {onchain} != manifest reactorFeeOwner {owner}')
        ok = False
    else:
        print(f'reactor owner {onchain} matches the manifest')
    sys.exit(0 if ok else 1)


if __name__ == '__main__':
    main()
