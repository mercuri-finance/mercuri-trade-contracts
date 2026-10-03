#!/usr/bin/env python3
"""Read-only reproduction of the Trade reactor, filler and validator runtime bytes at a pinned block.

Rebuilds each expected runtime from out/ (deployedBytecode + immutableReferences) with the manifest and
deployment immutables substituted, then compares byte for byte with eth_getCode. Prints MATCH or the
differing offsets and exits non-zero on any mismatch. No keys, no signing, no writes.

The filler and its validator name each other (spec D22), and the binding is checked both ways: the filler's
`validator` immutable is the recorded validator, the validator's `filler` immutable is the recorded filler, the
validator is the CREATE2 address the filler's constructor deploys to (from the filler, VALIDATOR_SALT, the built
validator creation code with (filler, poolManager)), and the filler is the CREATE2 address of the built filler creation
code with the manifest's arguments through the standard deployer with FILLER_SALT. Both getters are also read with
eth_call.

  python3 script/verify-trade-filler.py --rpc URL --block N --deployment FILE   # FILE has reactor, filler,
                                                                                # validator, reactorFeeOwner,
                                                                                # feeRecipient, reactorFeeController
  python3 script/verify-trade-filler.py --reactor-only --rpc URL --block N --deployment FILE
                                                    # the reactor alone, before any filler: FILE has reactor,
                                                    # reactorFeeOwner and reactorFeeController
  python3 script/verify-trade-filler.py --preflight [--manifest FILE] [--allow-pending]
                                                    # offline: manifest against Launch's record and the router
  python3 script/verify-trade-filler.py --self-test                             # offline, no network

Every live run first runs the preflight: the manifest's permit2, USDC, Launch hook, app fee recipient (Launch's
treasury) and reactor fee owner (Launch's timelock) must equal Launch's deployment record for the chain, and its
routerCodeHash must be the reproduced router runtime whose PERMIT2 immutable holds the manifest permit2. The live run
then reads the router at the pinned block and requires that code hash and those PERMIT2 bytes.
  python3 script/verify-trade-filler.py --self-test-reactor-flipped             # offline; must report MISMATCH
"""
import argparse
import hashlib
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
    'filler': {'reactor', 'router', 'permit2', 'usdc', 'launchHook', 'appRecipient', 'executionFee', 'feeRecipient',
               'validator'},
    'validator': {'filler', 'poolManager'},
    'reactor': {'permit2', POINTER},
}
FILLER_ARTIFACT = 'out/MercuriOrderFiller.sol/MercuriOrderFiller.json'
VALIDATOR_ARTIFACT = 'out/MercuriOrderValidator.sol/MercuriOrderValidator.json'
CREATE2_FACTORY = '0x4e59b44847b379578588920ca78fbf26c0b4956c'
CREATE2_FACTORY_CODEHASH = '0x2fa86add0aed31f33a762c9d88e807c475bd51d0f52bd0955754b2608f7e4989'
FILLER_SALT = bytes(32)  # TradeManifest.FILLER_SALT
VALIDATOR_SALT = bytes(32)  # MercuriOrderFiller.VALIDATOR_SALT


def cast_keccak(raw):
    return subprocess.run(['cast', 'keccak', '0x' + raw.hex()], capture_output=True, text=True, check=True).stdout.strip()


def create2_address(deployer, salt, init_code):
    """EIP-1014: keccak256(0xff ++ deployer ++ salt ++ keccak256(init_code))[12:], lower case."""
    init_hash = bytes.fromhex(cast_keccak(init_code).removeprefix('0x'))
    raw = b'\xff' + bytes.fromhex(deployer.removeprefix('0x')) + salt + init_hash
    return '0x' + cast_keccak(raw)[-40:]


def creation_code(path):
    return bytes.fromhex(load(path)['bytecode']['object'].removeprefix('0x'))


def predicted_validator(filler, pool_manager):
    """The validator the filler at `filler` deploys in its constructor."""
    init = creation_code(VALIDATOR_ARTIFACT) + address_word(filler) + address_word(pool_manager)
    return create2_address(filler, VALIDATOR_SALT, init)


def predicted_filler(manifest, reactor, fee_recipient):
    """The filler the deploy script lands through the standard CREATE2 deployer for these arguments."""
    args = [address_word(reactor), address_word(manifest['router']), address_word(manifest['permit2']),
            address_word(manifest['usdc']), address_word(manifest['launchHook']),
            address_word(manifest['appRecipient']), uint_word(execution_fee(manifest)), address_word(fee_recipient),
            address_word(manifest['poolManager'])]
    return create2_address(CREATE2_FACTORY, FILLER_SALT, creation_code(FILLER_ARTIFACT) + b''.join(args))


def create2_self_test():
    """EIP-1014's own examples 0 and 5, so the address formula itself is checked offline."""
    ok = True
    for deployer, salt, init, want in (
        ('0x0000000000000000000000000000000000000000', bytes(32), bytes(1), '0x4d1a2e2bb4f88f0250f26ffff098b0b30b26bf38'),
        ('0x00000000000000000000000000000000deadbeef', bytes.fromhex('00000000000000000000000000000000000000000000000000000000cafebabe'),
         bytes.fromhex('deadbeef'), '0x60f3f640a8508fc6a86d45df051962668e1e8ac7'),
    ):
        got = create2_address(deployer, salt, init)
        print(f'create2 {deployer} {init.hex()}: {got} ({"ok" if got == want else "WRONG, want " + want})')
        ok &= got == want
    return ok


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


def manifest_values(manifest, reactor, fee_recipient, validator):
    return {
        'reactor': address_word(reactor),
        'router': address_word(manifest['router']),
        'permit2': address_word(manifest['permit2']),
        'usdc': address_word(manifest['usdc']),
        'launchHook': address_word(manifest['launchHook']),
        'appRecipient': address_word(manifest['appRecipient']),
        'executionFee': uint_word(execution_fee(manifest)),
        'feeRecipient': address_word(fee_recipient),
        'validator': address_word(validator),
    }


def validator_values(manifest, filler):
    return {'filler': address_word(filler), 'poolManager': address_word(manifest['poolManager'])}


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
    if not (isinstance(recipient, str) and len(recipient) == 42 and recipient.startswith('0x')
            and all(c in '0123456789abcdefABCDEF' for c in recipient[2:])):
        raise SystemExit(f'manifest feeRecipient is not an address: {recipient!r}')
    if int(recipient, 16) == 0:
        raise SystemExit('manifest feeRecipient is the zero address')
    recorded = deployment.get('feeRecipient')
    if recorded is None or recorded.lower() != recipient.lower():
        raise SystemExit(f'deployment feeRecipient {recorded!r} != manifest {recipient}')
    return recipient


ZERO_ADDRESS = '0x' + '0' * 40
FEE_CONTROLLER_SELECTOR = '0x6999b377'  # feeController()
OWNER_SELECTOR = '0x8da5cb5b'  # owner()


def is_address(text):
    return (isinstance(text, str) and len(text) == 42 and text[:2] == '0x'
            and all(c in '0123456789abcdefABCDEF' for c in text[2:]))


def expected_fee_controller(manifest, deployment):
    """The reactor's protocol fee controller: the manifest value (zero when absent), recorded identically."""
    controller = manifest.get('reactorFeeController', ZERO_ADDRESS)
    if not is_address(controller):
        raise SystemExit(f'manifest reactorFeeController is not an address: {controller!r}')
    recorded = deployment.get('reactorFeeController')
    if not is_address(recorded) or recorded.lower() != controller.lower():
        raise SystemExit(f'deployment reactorFeeController {recorded!r} != manifest {controller}')
    return controller


def check_fee_controller(word, manifest, deployment):
    """Compares the reactor's `feeController()` return word with the record; prints and returns the verdict."""
    expected = expected_fee_controller(manifest, deployment)
    raw = word.removeprefix('0x')
    if len(raw) != 64 or int(raw[:24] or '0', 16) != 0:
        print(f'reactor feeController() returned a malformed word {word!r}')
        return False
    onchain = '0x' + raw[-40:]
    if onchain.lower() != expected.lower():
        print(f'reactor feeController {onchain} != recorded reactorFeeController {expected}')
        return False
    print(f'reactor feeController {onchain} matches the record')
    return True


def fee_controller_self_test():
    """The feeController comparison must accept the recorded value and refuse any other, or a missing record."""
    zero_word = '0x' + '0' * 64
    other_word = '0x' + '0' * 62 + 'ee'
    manifest = {'reactorFeeController': ZERO_ADDRESS}
    ok = check_fee_controller(zero_word, manifest, {'reactorFeeController': ZERO_ADDRESS})
    ok &= not check_fee_controller(other_word, manifest, {'reactorFeeController': ZERO_ADDRESS})
    ok &= check_fee_controller(other_word, {'reactorFeeController': '0x' + '0' * 38 + 'ee'},
                               {'reactorFeeController': '0x' + '0' * 38 + 'ee'})
    ok &= check_fee_controller(zero_word, {}, {'reactorFeeController': ZERO_ADDRESS})  # absent manifest key: zero
    for deployment in ({}, {'reactorFeeController': '0x' + '0' * 38 + 'ee'}):
        try:
            check_fee_controller(zero_word, manifest, deployment)
            print(f'deployment {deployment}: NOT refused')
            ok = False
        except SystemExit as error:
            print(f'deployment {deployment}: refused ({error})')
    return ok


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


# Offline self-tests stand in for the deployed pair with these placeholder addresses.
SELF_TEST_FILLER = '0x00000000000000000000000000000000000000f1'
SELF_TEST_VALIDATOR = '0x00000000000000000000000000000000000000f2'


def immutable_set_self_test():
    import copy
    manifest = load('deployments/manifest-5042002.json')
    filler = load('out/MercuriOrderFiller.sol/MercuriOrderFiller.json')
    values = manifest_values(manifest, '0x00000000000000000000000000000000000000aa', SELF_TEST_RECIPIENT,
                             SELF_TEST_VALIDATOR)
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


def recipient_input_self_test():
    """A non-hex recipient of the right length must be a clean refusal, not a traceback."""
    ok = True
    for bad in ('0x' + 'zz' * 20, '0x' + '1' * 39 + 'g', '0x' + '-1' + '0' * 38):
        try:
            required_fee_recipient({'feeRecipient': bad}, {'feeRecipient': bad})
            print(f'feeRecipient {bad!r}: NOT refused')
            ok = False
        except SystemExit as error:
            print(f'feeRecipient {bad!r}: refused ({error})')
    return ok


def self_test(flip, name='usdc'):
    manifest = load('deployments/manifest-5042002.json')
    filler = load(FILLER_ARTIFACT)
    fake_reactor = '0x00000000000000000000000000000000000000aa'
    values = manifest_values(manifest, fake_reactor, SELF_TEST_RECIPIENT, SELF_TEST_VALIDATOR)
    live, ranges = expected_runtime(filler, values, 'filler')
    live = bytearray(live)
    if flip:
        # Flip one byte inside the named immutable, as a wrong constructor argument would.
        start = next(s for s, e, n in ranges if n == name)
        live[start + 31] ^= 0x01
    ok = verify('filler self-test' + (f' (one {name} byte flipped)' if flip else ''), 'filler', filler, values, bytes(live))
    return ok


def validator_self_test(flip, name='filler'):
    """The validator's runtime with its two immutables; a flipped byte in either must be reported by name."""
    manifest = load('deployments/manifest-5042002.json')
    validator = load(VALIDATOR_ARTIFACT)
    values = validator_values(manifest, SELF_TEST_FILLER)
    live, ranges = expected_runtime(validator, values, 'validator')
    live = bytearray(live)
    if flip:
        start = next(s for s, e, n in ranges if n == name)
        live[start + 31] ^= 0x01
    label = 'validator self-test' + (f' (one {name} byte flipped)' if flip else '')
    return verify(label, 'validator', validator, values, bytes(live))


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


LAUNCH_RECORDS = 'lib/mercuri-launch-contracts/deployments'
ROUTER_REPORT = 'docs/reports/2026-09-27-trade-router-comparison.json'
ROUTER_ARTIFACT = 'out/trade-router/UniversalRouter.sol/UniversalRouter.json'
PENDING_PREFIX = 'REQUIRED_'
# Manifest key -> Launch record key; each must be equal.
LAUNCH_FIELDS = {'permit2': 'permit2', 'usdc': 'usdc', 'launchHook': 'launchHook', 'poolManager': 'poolManager',
                 'appRecipient': 'treasury'}
# Owner choices that may still be pending sentinels during review.
CHOICES = ('reactorFeeOwner', 'executionFee', 'feeRecipient')


def pending(value):
    return isinstance(value, str) and value.startswith(PENDING_PREFIX)


def router_names():
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

    for path in sorted((root / 'out/trade-router').glob('*/*.json')):
        visit(json.loads(path.read_text()).get('ast', {}))
    return names


def router_runtime(chain):
    """The reproduced router runtime for `chain`, its PERMIT2 offsets and the report's entry for that network.

    Rebuilt from the pinned router build with every immutable taken from the router comparison report, which records
    the bytes observed on chain (sha256). Returns (runtime, permit2 offsets, report network entry, report immutables).
    """
    report = load(ROUTER_REPORT)
    artifact = load(ROUTER_ARTIFACT)
    names = router_names()
    proofs = {entry['chainId']: entry['immutables'] for entry in report['immutableProof']}
    network = next((n for n in report['networks'] if n['chainId'] == chain), None)
    if network is None or chain not in proofs:
        raise SystemExit(f'router report has no entry for chain {chain}')
    code = bytearray.fromhex(artifact['deployedBytecode']['object'].removeprefix('0x'))
    offsets = []
    for key, refs in artifact['deployedBytecode']['immutableReferences'].items():
        value = bytes.fromhex(proofs[chain][names[key]].removeprefix('0x'))
        for ref in refs:
            if len(value) != ref['length']:
                raise SystemExit(f'router immutable {names[key]} has the wrong length')
            code[ref['start']:ref['start'] + ref['length']] = value
            if names[key] == 'PERMIT2':
                offsets.append(ref['start'])
    if not offsets:
        raise SystemExit('router artifact has no PERMIT2 immutable')
    return bytes(code), offsets, network, proofs[chain]


def check_router_code(live, manifest, label):
    """A router runtime is accepted when its keccak is the manifest's routerCodeHash and every PERMIT2 slot holds the
    manifest permit2. Prints and returns the verdict."""
    _, offsets, _, _ = router_runtime(manifest['chainId'])
    ok = True
    keccak = cast_keccak(live)
    if keccak.lower() != str(manifest.get('routerCodeHash', '')).lower():
        print(f'{label}: router code hash {keccak} != manifest routerCodeHash {manifest.get("routerCodeHash")}')
        ok = False
    word = address_word(manifest['permit2'])
    for offset in offsets:
        if live[offset:offset + 32] != word:
            print(f'{label}: router PERMIT2 at offset {offset} is 0x{live[offset:offset + 32].hex()}, not the manifest permit2')
            ok = False
    if ok:
        print(f'{label}: router code hash {keccak} and PERMIT2 at offsets {offsets} match the manifest')
    return ok


def preflight(manifest, rehearsal=False):
    """Offline cross-checks of a manifest. Returns (problems, pending choices); prints each result.

    With `rehearsal` (a loopback anvil fork only) the reactor fee owner is an anvil account, not Launch's timelock.
    """
    problems = []
    chain = manifest.get('chainId')
    record_path = root / LAUNCH_RECORDS / f'{chain}.json'
    if not record_path.exists():
        return [f'no Launch deployment record {record_path.relative_to(root)}'], []
    record = json.loads(record_path.read_text())
    if record.get('chainId') != chain:
        problems.append(f'Launch record chainId {record.get("chainId")} != manifest {chain}')
    for key, record_key in LAUNCH_FIELDS.items():
        value = manifest.get(key)
        if not is_address(value) or value.lower() != str(record.get(record_key)).lower():
            problems.append(f'manifest {key} {value!r} != Launch record {record_key} {record.get(record_key)}')
    waiting = [key for key in CHOICES if pending(manifest.get(key))]
    owner = manifest.get('reactorFeeOwner')
    if rehearsal:
        print(f'preflight {chain}: WARNING: LOCAL REHEARSAL; reactorFeeOwner {owner} is not checked against the timelock')
    elif 'reactorFeeOwner' not in waiting and (not is_address(owner) or owner.lower() != record['timelock'].lower()):
        problems.append(f'manifest reactorFeeOwner {owner!r} != Launch record timelock {record["timelock"]}')
    if 'executionFee' not in waiting:
        try:
            execution_fee(manifest)
        except SystemExit as error:
            problems.append(str(error))
    recipient = manifest.get('feeRecipient')
    if 'feeRecipient' not in waiting and (not is_address(recipient) or int(recipient, 16) == 0):
        problems.append(f'manifest feeRecipient is not a nonzero address: {recipient!r}')
    if not is_address(manifest.get('reactorFeeController', ZERO_ADDRESS)):
        problems.append(f'manifest reactorFeeController is not an address: {manifest.get("reactorFeeController")!r}')
    try:
        runtime, offsets, network, immutables = router_runtime(chain)
        if hashlib.sha256(runtime).hexdigest() != network['contracts']['router']['sha256']:
            problems.append('reproduced router runtime differs from the bytes the router report observed on chain')
        if str(manifest.get('router', '')).lower() != network['contracts']['router']['address'].lower():
            problems.append(f'manifest router {manifest.get("router")} != report {network["contracts"]["router"]["address"]}')
        if immutables['PERMIT2'].lower() != '0x' + address_word(str(manifest.get('permit2', ZERO_ADDRESS))).hex():
            problems.append('router report PERMIT2 immutable is not the manifest permit2')
        if not check_router_code(runtime, manifest, f'preflight {chain}'):
            problems.append('manifest routerCodeHash or permit2 does not match the reproduced router')
    except (SystemExit, KeyError, ValueError) as error:
        problems.append(f'router: {error}')
    for problem in problems:
        print(f'preflight {chain}: FAIL {problem}')
    for key in waiting:
        print(f'preflight {chain}: PENDING owner choice {key} = {manifest[key]}')
    if not problems:
        print(f'preflight {chain}: manifest matches Launch record {record_path.relative_to(root)} and the reproduced router')
    return problems, waiting


def run_preflight(manifest, allowed_pending, rehearsal=False):
    problems, waiting = preflight(manifest, rehearsal)
    blocked = [key for key in waiting if key not in allowed_pending]
    if blocked:
        print(f'preflight {manifest.get("chainId")}: owner choices still pending: {", ".join(blocked)}')
    return not problems and not blocked


ANVIL_ACCOUNTS = {a.lower() for a in (
    '0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266', '0x70997970C51812dc3A010C7d01b50e0d17dc79C8',
    '0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC', '0x90F79bf6EB2c4f870365E785982E1f101E93b906',
    '0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65', '0x9965507D1a55bcC2695C58ba16FB37d819B0A4dc',
    '0x976EA74026E726554dB657fA54763abd0C3a0aa9', '0x14dC79964da2C08b23698B3D3cc7Ca32193d9955',
    '0x23618e81E3f5cdF7f54C3d65f7FBc0aBf5B21E8f', '0xa0Ee7A142d267C1f36714E4a8F75612F20a79720',
)}


def rehearsal_choice(deployment, key):
    """Under --rehearsal an owner choice is the record's value, and it must be one of anvil's public accounts."""
    value = deployment.get(key)
    if not is_address(value) or value.lower() not in ANVIL_ACCOUNTS:
        raise SystemExit(f'rehearsal {key} {value!r} is not one of anvil\'s default accounts')
    print(f'WARNING: LOCAL REHEARSAL; {key} is the anvil account {value}')
    return value


def required_reactor_fields(deployment, reactor_only):
    """The deployment record keys a live run needs."""
    keys = ['reactor', 'reactorFeeOwner', 'reactorFeeController'] + (
        [] if reactor_only else ['filler', 'validator', 'feeRecipient'])
    missing = [key for key in keys if not is_address(deployment.get(key))]
    if missing:
        raise SystemExit(f'deployment record lacks {", ".join(missing)}')


def preflight_self_test():
    """Both manifests pass with only their owner choices pending; each tampered field and a pending choice fail."""
    import copy
    ok = True
    for path, expected in (('deployments/manifest-5042002.json', ['feeRecipient']),
                           ('deployments/manifest-5042.json', ['executionFee', 'feeRecipient'])):
        manifest = load(path)
        problems, waiting = preflight(manifest)
        if problems or waiting != expected:
            print(f'{path}: expected a clean preflight with {expected} pending, got {problems} {waiting}')
            ok = False
        if run_preflight(manifest, ()):
            print(f'{path}: pending owner choices were NOT refused without --allow-pending')
            ok = False
    base = load('deployments/manifest-5042002.json')
    other = '0x00000000000000000000000000000000000000Ab'
    cases = {key: other for key in ('permit2', 'usdc', 'launchHook', 'poolManager', 'appRecipient', 'reactorFeeOwner',
                                    'router')}
    cases.update(routerCodeHash='0x' + '11' * 32, executionFee=100_001, feeRecipient='0x' + '0' * 40,
                 reactorFeeController='none', chainId=1)
    mainnet_owner = load(f'{LAUNCH_RECORDS}/5042.json')['timelock']
    tampered_cases = list(cases.items()) + [('reactorFeeOwner', mainnet_owner)]
    for key, value in tampered_cases:
        manifest = copy.deepcopy(base)
        manifest[key] = value
        problems, _ = preflight(manifest)
        if not problems:
            print(f'tampered {key}={value!r}: NOT refused')
            ok = False
        else:
            print(f'tampered {key}={value!r}: refused')
    # The testnet router runtime fails the mainnet manifest (another EIP-712 domain) and a flipped PERMIT2 byte fails.
    runtime, offsets, _, _ = router_runtime(5042002)
    if check_router_code(runtime, load('deployments/manifest-5042.json'), 'testnet router vs mainnet manifest'):
        ok = False
    flipped = bytearray(runtime)
    flipped[offsets[0] + 31] ^= 0x01
    if check_router_code(bytes(flipped), base, 'router with a flipped PERMIT2 byte'):
        ok = False
    for deployment, reactor_only, good in (
        ({'reactor': other, 'reactorFeeOwner': other, 'reactorFeeController': ZERO_ADDRESS}, True, True),
        ({'reactor': other, 'reactorFeeOwner': other, 'reactorFeeController': ZERO_ADDRESS}, False, False),
        ({'reactor': other, 'reactorFeeOwner': other, 'reactorFeeController': ZERO_ADDRESS, 'filler': other,
          'feeRecipient': other}, False, False),
        ({'reactor': other, 'reactorFeeOwner': other, 'reactorFeeController': ZERO_ADDRESS, 'filler': other,
          'validator': other, 'feeRecipient': other}, False, True),
        ({'reactor': other, 'reactorFeeOwner': other}, True, False),
    ):
        try:
            required_reactor_fields(deployment, reactor_only)
            accepted = True
        except SystemExit as error:
            print(f'deployment record (reactor-only={reactor_only}) refused: {error}')
            accepted = False
        ok &= accepted == good
    # A rehearsal owner choice must be one of anvil's public accounts, never another address.
    try:
        rehearsal_choice({'feeRecipient': '0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC'}, 'feeRecipient')
        rehearsal_choice({'reactorFeeOwner': base['reactorFeeOwner']}, 'reactorFeeOwner')
        print('rehearsal owner that is not an anvil account: NOT refused')
        ok = False
    except SystemExit as error:
        print(f'rehearsal owner that is not an anvil account: refused ({error})')
    return ok


VALIDATOR_SELECTOR = '0x3a5381b5'  # validator()
FILLER_SELECTOR = '0xcaac9dca'  # filler()


def check_binding(rpc, tag, manifest, deployment, fee_recipient, factory_code):
    """Both directions of the filler-validator binding and both CREATE2 derivations. Prints and returns the verdict."""
    ok = True
    filler, validator = deployment['filler'].lower(), deployment['validator'].lower()
    want_validator = predicted_validator(filler, manifest['poolManager'])
    if want_validator != validator:
        print(f'validator {validator} is not the CREATE2 address {want_validator} the filler deploys')
        ok = False
    else:
        print(f'validator {validator} is the filler\'s own CREATE2 deployment (VALIDATOR_SALT, poolManager {manifest["poolManager"]})')
    want_filler = predicted_filler(manifest, deployment['reactor'], fee_recipient)
    if want_filler != filler:
        print(f'filler {filler} is not the standard deployer\'s CREATE2 address {want_filler} for the built code and manifest')
        ok = False
    else:
        print(f'filler {filler} is the standard deployer\'s CREATE2 of the built code with the manifest arguments')
    if cast_keccak(factory_code) != CREATE2_FACTORY_CODEHASH:
        print(f'CREATE2 deployer {CREATE2_FACTORY} code hash {cast_keccak(factory_code)} != {CREATE2_FACTORY_CODEHASH}')
        ok = False
    def getter(to, selector):
        """The address a getter returns, or a description of why it returned none (a revert or no code)."""
        try:
            word = rpc_call(rpc, 'eth_call', [{'to': to, 'data': selector}, tag]).removeprefix('0x')
        except SystemExit as error:
            return f'(reverted: {error})'
        return '0x' + word[-40:] if len(word) == 64 else f'(returned {len(word) // 2} bytes)'

    onchain_validator = getter(filler, VALIDATOR_SELECTOR)
    onchain_filler = getter(validator, FILLER_SELECTOR)
    if onchain_validator.lower() != validator or onchain_filler.lower() != filler:
        print(f'binding read on chain: filler.validator() {onchain_validator}, validator.filler() {onchain_filler}')
        ok = False
    else:
        print('binding read on chain: filler.validator() and validator.filler() name each other')
    return ok


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--rpc', default=DEFAULT_RPC)
    parser.add_argument('--block', type=int)
    parser.add_argument('--deployment', help='JSON with reactor, filler, reactorFeeOwner, reactorFeeController and feeRecipient')
    parser.add_argument('--manifest', default='deployments/manifest-5042002.json')
    parser.add_argument('--reactor-only', action='store_true', help='verify the reactor alone, before any filler exists')
    parser.add_argument('--preflight', action='store_true', help='offline: manifest against Launch record and router')
    parser.add_argument('--allow-pending', action='store_true', help='with --preflight: owner choices may be sentinels')
    parser.add_argument('--rehearsal', action='store_true',
                        help='loopback anvil fork only: the reactor fee owner is an anvil account, not the timelock')
    parser.add_argument('--self-test', action='store_true', help='offline: unmodified bytes must match, a flipped immutable byte must not')
    parser.add_argument('--self-test-flipped', action='store_true', help='offline: verify with one immutable byte flipped; exits non-zero')
    parser.add_argument('--self-test-flipped-fee', action='store_true', help='offline: verify with one executionFee byte flipped; exits non-zero')
    parser.add_argument('--self-test-flipped-recipient', action='store_true', help='offline: verify with one feeRecipient byte flipped; exits non-zero')
    parser.add_argument('--self-test-flipped-validator', action='store_true', help="offline: verify with one byte of the filler's validator flipped; exits non-zero")
    parser.add_argument('--self-test-validator-flipped-filler', action='store_true', help="offline: verify the validator with one byte of its filler flipped; exits non-zero")
    parser.add_argument('--self-test-validator-flipped-pool-manager', action='store_true', help="offline: verify the validator with one byte of its poolManager flipped; exits non-zero")
    parser.add_argument('--self-test-reactor-flipped', action='store_true', help='offline: verify the reactor with one function-pointer byte flipped; exits non-zero')
    args = parser.parse_args()

    if args.self_test_flipped:
        sys.exit(0 if self_test(True) else 1)
    if args.self_test_flipped_fee:
        sys.exit(0 if self_test(True, 'executionFee') else 1)
    if args.self_test_flipped_recipient:
        sys.exit(0 if self_test(True, 'feeRecipient') else 1)
    if args.self_test_flipped_validator:
        sys.exit(0 if self_test(True, 'validator') else 1)
    if args.self_test_validator_flipped_filler:
        sys.exit(0 if validator_self_test(True, 'filler') else 1)
    if args.self_test_validator_flipped_pool_manager:
        sys.exit(0 if validator_self_test(True, 'poolManager') else 1)
    if args.self_test_reactor_flipped:
        sys.exit(0 if reactor_self_test(True) else 1)
    if args.self_test:
        good = self_test(False) and validator_self_test(False)
        bad = (self_test(True) or self_test(True, 'executionFee') or self_test(True, 'feeRecipient')
               or self_test(True, 'validator') or validator_self_test(True, 'filler')
               or validator_self_test(True, 'poolManager'))
        if not create2_self_test():
            print('self-test FAILED: the CREATE2 address formula does not reproduce EIP-1014')
            sys.exit(1)
        if not recipient_input_self_test():
            print('self-test FAILED: a non-hex feeRecipient was not refused cleanly')
            sys.exit(1)
        if not fee_controller_self_test():
            print('self-test FAILED: the reactor feeController check did not behave as required')
            sys.exit(1)
        if not preflight_self_test():
            print('self-test FAILED: the manifest preflight did not behave as required')
            sys.exit(1)
        sets = immutable_set_self_test()
        reactor_good = reactor_self_test(False)
        reactor_bad = reactor_self_test(True)
        if not good or bad or not sets or not reactor_good or reactor_bad:
            print('self-test FAILED: verifier did not behave as required')
            sys.exit(1)
        print('self-test ok: unmodified runtimes match; a flipped filler usdc, executionFee, feeRecipient or validator byte, a flipped validator filler or poolManager byte and a flipped reactor function-pointer byte are rejected; the CREATE2 formula reproduces EIP-1014; the reactor feeController check and the manifest preflight refuse every tampered value')
        return
    if args.preflight:
        sys.exit(0 if run_preflight(load(args.manifest), CHOICES if args.allow_pending else ()) else 1)
    if args.block is None or not args.deployment:
        parser.error('--block and --deployment are required')

    manifest = load(args.manifest)
    deployment = json.loads(Path(args.deployment).read_text())
    required_reactor_fields(deployment, args.reactor_only)
    if args.rehearsal:
        client = rpc_call(args.rpc, 'web3_clientVersion', [])
        if 'anvil' not in client.lower():
            raise SystemExit(f'--rehearsal needs a loopback anvil RPC; {args.rpc} reports {client!r}')
    # The reactor step precedes the keeper choice (D2 before D3); a rehearsal takes both owner choices from the record.
    allowed = ('executionFee', 'feeRecipient') if args.reactor_only else ()
    if args.rehearsal:
        allowed += ('reactorFeeOwner', 'feeRecipient')
    if not run_preflight(manifest, allowed, args.rehearsal):
        raise SystemExit('preflight failed; nothing was read from the chain')
    chain = int(rpc_call(args.rpc, 'eth_chainId', []), 16)
    if chain != manifest['chainId']:
        raise SystemExit(f'chain id {chain} != manifest {manifest["chainId"]}')
    tag = hex(args.block)
    block = rpc_call(args.rpc, 'eth_getBlockByNumber', [tag, False])
    print(f'block {args.block} hash {block["hash"]}')

    def code(address):
        return bytes.fromhex(rpc_call(args.rpc, 'eth_getCode', [address, tag]).removeprefix('0x'))

    owner = rehearsal_choice(deployment, 'reactorFeeOwner') if args.rehearsal else required_owner(manifest, deployment)
    ok = verify_reactor(args, manifest, owner, tag, code(deployment['reactor']))
    if not args.reactor_only:
        if args.rehearsal:
            fee_recipient = rehearsal_choice(deployment, 'feeRecipient')
        else:
            fee_recipient = required_fee_recipient(manifest, deployment)
        filler = load(FILLER_ARTIFACT)
        values = manifest_values(manifest, deployment['reactor'], fee_recipient, deployment['validator'])
        ok &= verify('filler', 'filler', filler, values, code(deployment['filler']))
        ok &= verify('validator', 'validator', load(VALIDATOR_ARTIFACT), validator_values(manifest, deployment['filler']),
                     code(deployment['validator']))
        ok &= check_binding(args.rpc, tag, manifest, deployment, fee_recipient, code(CREATE2_FACTORY))
        ok &= check_router_code(code(manifest['router']), manifest, f'router at block {args.block}')
    onchain = rpc_call(args.rpc, 'eth_call', [{'to': deployment['reactor'], 'data': OWNER_SELECTOR}, tag])
    onchain = '0x' + onchain[-40:]
    if onchain.lower() != owner.lower():
        print(f'reactor owner {onchain} != manifest reactorFeeOwner {owner}')
        ok = False
    else:
        print(f'reactor owner {onchain} matches the expected owner')
    word = rpc_call(args.rpc, 'eth_call', [{'to': deployment['reactor'], 'data': FEE_CONTROLLER_SELECTOR}, tag])
    ok &= check_fee_controller(word, manifest, deployment)
    sys.exit(0 if ok else 1)


if __name__ == '__main__':
    main()
