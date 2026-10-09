#!/usr/bin/env python3
"""Read-only checks for the Mercurifi agent account deployment: manifest preflight and runtime identity.

Rebuilds the expected runtime of the AgentAccount implementation, the AgentAccountFactory and the AgentPolicyRegistry
from out/ (deployedBytecode + immutableReferences) with the manifest and deployment values substituted, then compares
byte for byte with eth_getCode at a pinned block. Every immutable of all three contracts is named and checked; a
different immutable set in either direction is a reviewed-source change and is refused. An account (an EIP-1167
clone) can be checked too: its runtime is the standard clone code naming the recorded implementation. No keys, no
signing, no writes. The helpers (immutable naming, substitution, mismatch report) are those of
verify-trade-filler.py, so both contracts families are checked the same way.

  python3 script/verify-agent-accounts.py --preflight [--manifest FILE]     # offline: manifest against records
  python3 script/verify-agent-accounts.py --self-test                       # offline, no network
  python3 script/verify-agent-accounts.py --self-test-flipped KIND:NAME     # offline; must report MISMATCH
  python3 script/verify-agent-accounts.py --simulate [--rpc URL] [--block N] [--manifest FILE]
                                       # read-only: eth_call constructor simulations equal the reconstruction
  python3 script/verify-agent-accounts.py --rpc URL --block N --record FILE [--account ADDR] [--manifest FILE]
                                       # FILE: deployments/agent-accounts-<chainId>.json, written only by
                                       # write-agent-accounts-record.py from a completed broadcast; N must be at
                                       # or after the record's factoryDeployBlock

The preflight requires the manifest to hold exactly the input keys: the Launch addresses equal to Launch's deployment
record for the chain, admin = the record's timelock, guardian = the record's guardian (non-zero), the Universal Router
and its pinned runtime hash equal to the Trade manifest's (which verify-trade-filler.py --preflight reproduces from the
pinned router source), and the ceilings exactly the beta ceilings of spec section 4.5. The default RPC is Arc's public
testnet endpoint; never point this at a paid provider for tests.
"""
import argparse
import copy
import importlib.util
import json
import sys
import tempfile
from pathlib import Path

root = Path(__file__).resolve().parents[1]
_spec = importlib.util.spec_from_file_location('verify_trade_filler', root / 'script' / 'verify-trade-filler.py')
vtf = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(vtf)
_wspec = importlib.util.spec_from_file_location('write_agent_accounts_record',
                                                root / 'script' / 'write-agent-accounts-record.py')
war = importlib.util.module_from_spec(_wspec)
_wspec.loader.exec_module(war)

DEFAULT_RPC = 'https://rpc.testnet.arc.io'
ACCOUNT_ARTIFACT = 'out/AgentAccount.sol/AgentAccount.json'
FACTORY_ARTIFACT = 'out/AgentAccountFactory.sol/AgentAccountFactory.json'
REGISTRY_ARTIFACT = 'out/AgentPolicyRegistry.sol/AgentPolicyRegistry.json'
ARTIFACTS = {'account': ACCOUNT_ARTIFACT, 'factory': FACTORY_ARTIFACT, 'registry': REGISTRY_ARTIFACT}
# Manifest ceiling key -> factory immutable, with the spec section 4.5 beta value (amounts usdc6).
CEILINGS = {
    'maxTradeUsdc': ('C_MAX_TRADE_USDC', 1_000_000_000),
    'periodSpendCap': ('C_PERIOD_SPEND_CAP', 10_000_000_000),
    'perTokenPeriodCap': ('C_PER_TOKEN_PERIOD_CAP', 2_000_000_000),
    'periodSellCap': ('C_PERIOD_SELL_CAP', 10_000_000_000),
    'maxActionsPerPeriod': ('C_MAX_ACTIONS_PER_PERIOD', 5_000),
    'launchesPerPeriod': ('C_LAUNCHES_PER_PERIOD', 20),
    'maxPriceImpactBps': ('C_MAX_PRICE_IMPACT_BPS', 2_000),
    'maxSnipeBps': ('C_MAX_SNIPE_BPS', 9_900),
    'minTokenAgeBlocks': ('C_MIN_TOKEN_AGE_BLOCKS', 0),
    'maxDeadlineSeconds': ('C_MAX_DEADLINE_SECONDS', 600),
}
# Manifest key -> the implementation immutable holding it.
ACCOUNT_INPUTS = {
    'launchFactory': 'LAUNCH_FACTORY', 'feeManager': 'FEE_MANAGER', 'graduationManager': 'GRADUATION_MANAGER',
    'launchHook': 'LAUNCH_HOOK', 'poolManager': 'POOL_MANAGER', 'universalRouter': 'UNIVERSAL_ROUTER',
    'permit2': 'PERMIT2', 'usdc': 'USDC',
}
# Manifest key -> Launch deployment record key.
RECORD_KEYS = {
    'launchFactory': 'factory', 'feeManager': 'feeManager', 'graduationManager': 'graduationManager',
    'launchHook': 'launchHook', 'poolManager': 'poolManager', 'permit2': 'permit2', 'usdc': 'usdc',
    'admin': 'timelock', 'guardian': 'guardian',
}
MANIFEST_KEYS = set(RECORD_KEYS) | {'chainId', 'universalRouter', 'routerCodeHash', 'ceilings'}
vtf.EXPECTED_IMMUTABLES.update({
    'account': {'FACTORY', 'REGISTRY'} | set(ACCOUNT_INPUTS.values()),
    'registry': {'FACTORY'},
    'factory': {'implementation', 'registry', 'admin', 'guardianDisabled'} | {v[0] for v in CEILINGS.values()},
})
# EIP-1167 minimal proxy runtime around the implementation address.
CLONE_PREFIX = bytes.fromhex('363d3d373d3d3d363d73')
CLONE_SUFFIX = bytes.fromhex('5af43d82803e903d91602b57fd5bf3')
GUARDIAN_SELECTOR = '0x452a9320'  # guardian()
PAUSED_UNTIL_SELECTOR = '0xda748b10'  # pausedUntil()
# Offline self-tests stand in for the deployed contracts with these placeholder addresses.
SELF_TEST = {'implementation': '0x00000000000000000000000000000000000000a1',
             'factory': '0x00000000000000000000000000000000000000f1',
             'registry': '0x00000000000000000000000000000000000000e1'}


def create_address(sender, nonce):
    """CREATE address for a nonce below 0x80: keccak256(rlp([sender, nonce]))[12:]."""
    if not 0 <= nonce < 0x80:
        raise SystemExit(f'nonce {nonce} outside the supported range')
    raw = bytes([0xd6, 0x94]) + bytes.fromhex(sender.removeprefix('0x')) + bytes([nonce or 0x80])
    return '0x' + vtf.cast_keccak(raw)[-40:]


def account_values(manifest, factory, registry):
    values = {name: vtf.address_word(manifest[key]) for key, name in ACCOUNT_INPUTS.items()}
    values['FACTORY'] = vtf.address_word(factory)
    values['REGISTRY'] = vtf.address_word(registry)
    return values


def factory_values(manifest, implementation, registry):
    values = {name: vtf.uint_word(manifest['ceilings'][key]) for key, (name, _) in CEILINGS.items()}
    values['implementation'] = vtf.address_word(implementation)
    values['registry'] = vtf.address_word(registry)
    values['admin'] = vtf.address_word(manifest['admin'])
    values['guardianDisabled'] = vtf.uint_word(int(int(manifest['guardian'], 16) == 0))
    return values


def registry_values(factory):
    return {'FACTORY': vtf.address_word(factory)}


def expected_values(kind, manifest, d):
    if kind == 'account':
        return account_values(manifest, d['factory'], d['registry'])
    if kind == 'factory':
        return factory_values(manifest, d['implementation'], d['registry'])
    return registry_values(d['factory'])


def clone_runtime(implementation):
    return CLONE_PREFIX + bytes.fromhex(implementation.removeprefix('0x')) + CLONE_SUFFIX


def verify_clone(label, implementation, live):
    expected = clone_runtime(implementation)
    if live != expected:
        diff = vtf.differing(expected, live)
        print(f'{label}: MISMATCH at offsets {diff[:32]} (not the EIP-1167 clone of {implementation})')
        return False
    print(f'{label}: MATCH EIP-1167 clone of {implementation}')
    return True


# ------------------------------------------------------------------------------------------------- preflight


def preflight(manifest):
    """Problems with the manifest, as a list of strings; empty means it passes."""
    problems = []
    chain = manifest.get('chainId')
    if chain not in (5042, 5042002):
        return [f'chainId {chain!r} is not an Arc network']
    keys = set(manifest)
    if keys != MANIFEST_KEYS:
        problems.append(f'manifest keys differ: unexpected {sorted(keys - MANIFEST_KEYS)}, '
                        f'missing {sorted(MANIFEST_KEYS - keys)} (inputs only, no deployed addresses)')
    record = json.loads((root / 'lib' / 'mercuri-launch-contracts' / 'deployments' / f'{chain}.json').read_text())
    trade = json.loads((root / 'deployments' / f'manifest-{chain}.json').read_text())
    if record.get('chainId') != chain or trade.get('chainId') != chain:
        problems.append('Launch record or Trade manifest is for another chain')
    for key, record_key in RECORD_KEYS.items():
        value = manifest.get(key)
        if not vtf.is_address(value) or value.lower() != str(record.get(record_key, '')).lower():
            problems.append(f'{key} {value!r} != Launch record {record_key} {record.get(record_key)!r}')
    if vtf.is_address(manifest.get('guardian')) and int(manifest['guardian'], 16) == 0:
        problems.append('guardian is zero: the D2 decision is a guardian pause, so the zero guardian is refused')
    if str(manifest.get('universalRouter', '')).lower() != str(trade.get('router', '')).lower():
        problems.append(f'universalRouter {manifest.get("universalRouter")!r} != Trade manifest router')
    if str(manifest.get('routerCodeHash', '')).lower() != str(trade.get('routerCodeHash', '')).lower():
        problems.append(f'routerCodeHash {manifest.get("routerCodeHash")!r} != Trade manifest routerCodeHash')
    ceilings = manifest.get('ceilings')
    if not isinstance(ceilings, dict):
        return problems + ['ceilings missing']
    if set(ceilings) != set(CEILINGS) | {'allowlistOnly'}:
        problems.append(f'ceiling keys differ: {sorted(ceilings)}')
    for key, (_, want) in CEILINGS.items():
        got = ceilings.get(key)
        if type(got) is not int or got != want:
            problems.append(f'ceilings.{key} {got!r} != spec 4.5 beta ceiling {want}')
    if ceilings.get('allowlistOnly') is not False:
        problems.append(f'ceilings.allowlistOnly {ceilings.get("allowlistOnly")!r} != false')
    return problems


def run_preflight(manifest, label='manifest'):
    problems = preflight(manifest)
    for problem in problems:
        print(f'{label}: {problem}')
    if not problems:
        print(f'{label}: chain {manifest["chainId"]} matches Launch record, Trade router pin and spec 4.5 ceilings')
    return not problems


# ------------------------------------------------------------------------------------------------- self-tests


def self_test_kind(kind, flip=None, manifest=None):
    """The built runtime with the testnet manifest's values; with `flip`, one byte of that immutable flipped."""
    manifest = manifest or vtf.load('deployments/agent-accounts-manifest-5042002.json')
    artifact = vtf.load(ARTIFACTS[kind])
    values = expected_values(kind, manifest, SELF_TEST)
    live, ranges = vtf.expected_runtime(artifact, values, kind)
    live = bytearray(live)
    if flip:
        start = next((s for s, e, n in ranges if n == flip), None)
        if start is None:
            raise SystemExit(f'{kind} has no immutable {flip}')
        live[start + 31] ^= 0x01
    label = f'{kind} self-test' + (f' (one {flip} byte flipped)' if flip else '')
    return vtf.verify(label, kind, artifact, values, bytes(live))


def immutable_set_self_test():
    """An extra or a missing immutable in any of the three artifacts must be refused."""
    manifest = vtf.load('deployments/agent-accounts-manifest-5042002.json')
    ok = True
    for kind, path in ARTIFACTS.items():
        artifact = vtf.load(path)
        values = expected_values(kind, manifest, SELF_TEST)
        extra = copy.deepcopy(artifact)
        extra['deployedBytecode']['immutableReferences']['999999999'] = [{'start': 0, 'length': 32}]
        extra.setdefault('ast', {}).setdefault('nodes', []).append(
            {'nodeType': 'VariableDeclaration', 'mutability': 'immutable', 'id': 999999999, 'name': 'sneaky'})
        missing = copy.deepcopy(artifact)
        refs = missing['deployedBytecode']['immutableReferences']
        del refs[next(iter(refs))]
        ok &= vtf.expect_rejected(f'{kind} unknown immutable', extra, values, kind)
        ok &= vtf.expect_rejected(f'{kind} missing immutable', missing, values, kind)
    return ok


def preflight_self_test():
    """Both shipped manifests pass; every tampered input is refused."""
    ok = True
    for chain in (5042002, 5042):
        manifest = vtf.load(f'deployments/agent-accounts-manifest-{chain}.json')
        ok &= run_preflight(manifest, f'shipped {chain}')
        tampers = {f'{key} changed': (key, '0x' + '0' * 38 + 'ee') for key in RECORD_KEYS}
        tampers['universalRouter changed'] = ('universalRouter', '0x' + '0' * 38 + 'ee')
        tampers['routerCodeHash changed'] = ('routerCodeHash', '0x' + '11' * 32)
        tampers['deployed address added'] = ('factory', '0x' + '0' * 38 + 'ee')
        for label, (key, value) in tampers.items():
            bad = copy.deepcopy(manifest)
            bad[key] = value
            if not preflight(bad):
                print(f'{chain} {label}: NOT refused')
                ok = False
        for key in list(CEILINGS) + ['allowlistOnly']:
            bad = copy.deepcopy(manifest)
            bad['ceilings'][key] = True if key == 'allowlistOnly' else bad['ceilings'][key] + 1
            if not preflight(bad):
                print(f'{chain} ceilings.{key} raised: NOT refused')
                ok = False
        other = copy.deepcopy(manifest)
        other['chainId'] = 5042 if chain == 5042002 else 5042002
        if not preflight(other):
            print(f'{chain} manifest relabelled as the other chain: NOT refused')
            ok = False
    print('preflight self-test: ' + ('every tampered manifest refused' if ok else 'FAILED'))
    return ok


def clone_self_test():
    good = verify_clone('clone self-test', SELF_TEST['implementation'], clone_runtime(SELF_TEST['implementation']))
    flipped = bytearray(clone_runtime(SELF_TEST['implementation']))
    flipped[len(CLONE_PREFIX) + 19] ^= 0x01
    bad = verify_clone('clone self-test (implementation byte flipped)', SELF_TEST['implementation'], bytes(flipped))
    return good and not bad


def create_self_test():
    """The CREATE formula against two known vectors (Ethereum's first contract and a nonce-1 CREATE)."""
    ok = True
    for sender, nonce, want in (
        ('0x6ac7ea33f8831ea9dcc53393aaa88b25a785dbf0', 1, '0x343c43a37d37dff08ae8c4a11544c718abb4fcf8'),
        ('0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266', 1, '0xe7f1725e7734ce288f8367e1bb143e90bb3f0512'),
        ('0x6ac7ea33f8831ea9dcc53393aaa88b25a785dbf0', 0, '0xcd234a471b72ba2f1ccf0a70fcaba648a5eecd8d'),
    ):
        got = create_address(sender, nonce)
        print(f'create {sender} nonce {nonce}: {got} ({"ok" if got == want else "WRONG, want " + want})')
        ok &= got == want
    return ok


def full_self_test():
    good = all(self_test_kind(kind) for kind in ARTIFACTS)
    bad = False
    for kind in ARTIFACTS:
        for name in sorted(vtf.EXPECTED_IMMUTABLES[kind]):
            bad |= self_test_kind(kind, name)
    checks = {
        'immutable set': immutable_set_self_test(),
        'preflight': preflight_self_test(),
        'clone': clone_self_test(),
        'CREATE formula': create_self_test(),
        'deployment record': record_self_test(),
    }
    if not good or bad or not all(checks.values()):
        failed = [k for k, v in checks.items() if not v]
        print(f'self-test FAILED: unmodified match {good}, a flipped byte accepted {bad}, failed checks {failed}')
        return False
    print('self-test ok: the implementation, factory and registry runtimes match with every immutable substituted; a '
          'flipped byte in any of their immutables is rejected by name; an extra or missing immutable is refused; '
          'both manifests pass the preflight and every tampered input is refused; a flipped clone byte is rejected; '
          'the CREATE formula reproduces known addresses; only a writer-shaped record matching the manifest is read, '
          'and never at a block before its factory')
    return True


# ------------------------------------------------------------------------------------------------- simulation

# A sender with no transactions on either Arc network: its first CREATE is at nonce 0.
SIMULATION_SENDER = '0x00000000000000000000000000000000000a6e47'
SIMULATION_IMPLEMENTATION = '0x00000000000000000000000000000000000a6e48'
POLICY_TUPLE = '(uint64,uint64,uint64,uint64,uint32,uint16,uint16,uint16,uint32,uint32,bool)'


def abi_encode(signature, *values):
    out = vtf.subprocess.run(['cast', 'abi-encode', signature, *values], capture_output=True, text=True, check=True)
    return out.stdout.strip().removeprefix('0x')


def simulate(args):
    """Independent check of the substitution itself: the runtimes the built creation code actually returns from a
    constructor simulation (eth_call, no transaction) with the manifest's inputs must equal the runtimes this script
    reconstructs from deployedBytecode and immutableReferences. The factory's constructor reads the implementation, so
    its simulation carries the simulated implementation runtime as a state override."""
    manifest = vtf.load(args.manifest)
    if not run_preflight(manifest):
        raise SystemExit('preflight failed; nothing was simulated')
    chain = int(vtf.rpc_call(args.rpc, 'eth_chainId', []), 16)
    if chain != manifest['chainId']:
        raise SystemExit(f'chain id {chain} != manifest {manifest["chainId"]}')
    tag = hex(args.block) if args.block is not None else 'latest'
    if int(vtf.rpc_call(args.rpc, 'eth_getTransactionCount', [SIMULATION_SENDER, tag]), 16) != 0:
        raise SystemExit(f'{SIMULATION_SENDER} has a non-zero nonce; pick another simulation sender')
    factory = create_address(SIMULATION_SENDER, 0)
    registry = create_address(factory, 1)
    d = {'implementation': SIMULATION_IMPLEMENTATION, 'factory': factory, 'registry': registry}

    def run(data, sender, override=None):
        params = [{'from': sender, 'data': '0x' + data}, tag] + ([override] if override else [])
        return bytes.fromhex(vtf.rpc_call(args.rpc, 'eth_call', params).removeprefix('0x'))

    creation = {kind: vtf.load(path)['bytecode']['object'].removeprefix('0x') for kind, path in ARTIFACTS.items()}
    impl_args = abi_encode('constructor(address,address,address,address,address,address,address,address,address,'
                           'address)', factory, registry, *(manifest[k] for k in ACCOUNT_INPUTS))
    impl_runtime = run(creation['account'] + impl_args, SIMULATION_SENDER)
    c = manifest['ceilings']
    ceilings = '(' + ','.join([str(c[k]) for k in CEILINGS] + ['false']) + ')'
    factory_args = abi_encode(f'constructor(address,address,address,{POLICY_TUPLE})', SIMULATION_IMPLEMENTATION,
                              manifest['admin'], manifest['guardian'], ceilings)
    factory_runtime = run(creation['factory'] + factory_args, SIMULATION_SENDER,
                          {SIMULATION_IMPLEMENTATION: {'code': '0x' + impl_runtime.hex()}})
    registry_runtime = run(creation['registry'], factory)
    ok = True
    for kind, runtime in (('account', impl_runtime), ('factory', factory_runtime), ('registry', registry_runtime)):
        ok &= vtf.verify(f'{kind} constructor simulation at {tag}', kind, vtf.load(ARTIFACTS[kind]),
                         expected_values(kind, manifest, d), runtime)
    return ok


# ------------------------------------------------------------------------------------------------- live


def load_record(path, manifest):
    """The deployment record written by write-agent-accounts-record.py, and only that: the file name, the exact key set,
    the version and every input must agree with the manifest, so a hand-written or stale record is refused."""
    path = Path(path)
    if path.name != f'agent-accounts-{manifest["chainId"]}.json':
        raise SystemExit(f'{path.name} is not agent-accounts-{manifest["chainId"]}.json, the record the writer emits')
    record = json.loads(path.read_text())
    if set(record) != war.RECORD_KEYS:
        raise SystemExit(f'record keys differ from the writer\'s: unexpected {sorted(set(record) - war.RECORD_KEYS)}, '
                         f'missing {sorted(war.RECORD_KEYS - set(record))}')
    if record['chainId'] != manifest['chainId'] or record['version'] != war.VERSION:
        raise SystemExit(f'record chainId {record["chainId"]} / version {record["version"]} != manifest chain '
                         f'{manifest["chainId"]} / writer version {war.VERSION}')
    for key in ('implementation', 'factory', 'registry', 'deployer'):
        if not vtf.is_address(record.get(key)):
            raise SystemExit(f'record {key} is not an address: {record.get(key)!r}')
    for key in war.ACCOUNT_INPUTS + ('admin', 'guardian'):
        if str(record[key]).lower() != str(manifest[key]).lower():
            raise SystemExit(f'record {key} {record[key]} != manifest {manifest[key]}')
    if record['ceilings'] != manifest['ceilings']:
        raise SystemExit('record ceilings != manifest ceilings')
    if not isinstance(record['deployBlock'], int) or not isinstance(record['factoryDeployBlock'], int):
        raise SystemExit('record blocks are not integers')
    return record


def record_self_test():
    """A record shaped as the writer emits it is accepted; a renamed, extended or tampered one is refused."""
    manifest = vtf.load('deployments/agent-accounts-manifest-5042002.json')
    record = {key: manifest[key] for key in war.ACCOUNT_INPUTS + ('admin', 'guardian', 'ceilings')}
    record.update(chainId=5042002, implementation=SELF_TEST['implementation'], factory=SELF_TEST['factory'],
                  registry=SELF_TEST['registry'], deployer=SELF_TEST['implementation'], deployBlock=1,
                  factoryDeployBlock=1, version=war.VERSION, sourceRevision='0' * 40)
    variants = {
        'writer-shaped record': (record, 'agent-accounts-5042002.json', True),
        'other file name': (record, 'deployment.json', False),
        'extra key': (dict(record, filler=SELF_TEST['factory']), 'agent-accounts-5042002.json', False),
        'admin differs': (dict(record, admin=SELF_TEST['factory']), 'agent-accounts-5042002.json', False),
        'ceilings differ': (dict(record, ceilings=dict(record['ceilings'], maxTradeUsdc=1)),
                            'agent-accounts-5042002.json', False),
        'other version': (dict(record, version='0'), 'agent-accounts-5042002.json', False),
    }
    ok = True
    with tempfile.TemporaryDirectory() as d:
        for label, (body, name, accept) in variants.items():
            path = Path(d) / name
            path.write_text(json.dumps(body))
            try:
                load_record(path, manifest)
                accepted = True
            except SystemExit:
                accepted = False
            print(f'record {label}: {"accepted" if accepted else "refused"}')
            ok &= accepted == accept
            path.unlink()
        # live() refuses a block before the factory existed, before any RPC call (the URL here is never reached).
        path = Path(d) / 'agent-accounts-5042002.json'
        path.write_text(json.dumps(dict(record, deployBlock=99, factoryDeployBlock=100)))
        for block, accept in ((99, False), (100, True)):
            args = argparse.Namespace(manifest='deployments/agent-accounts-manifest-5042002.json', record=str(path),
                                      block=block, rpc='http://127.0.0.1:9/never-called', account=None)
            try:
                live(args)
                message = ''
            except SystemExit as error:
                message = str(error)
            except Exception as error:  # the RPC call fails: the block check passed
                message = f'reached the RPC: {type(error).__name__}'
            refused = 'before the factory was deployed' in message
            print(f'record live --block {block} with factoryDeployBlock 100: {"refused" if refused else "passed"}')
            ok &= refused != accept
    return ok


def live(args):
    manifest = vtf.load(args.manifest)
    if not run_preflight(manifest):
        raise SystemExit('preflight failed; nothing was read from the chain')
    deployment = load_record(args.record, manifest)
    if args.block < deployment['factoryDeployBlock']:
        # Before the factory existed every getCode is empty, so a comparison there proves nothing.
        raise SystemExit(f'--block {args.block} is before the factory was deployed (record factoryDeployBlock '
                         f'{deployment["factoryDeployBlock"]}); pass a block at or after it')
    chain = int(vtf.rpc_call(args.rpc, 'eth_chainId', []), 16)
    if chain != manifest['chainId']:
        raise SystemExit(f'chain id {chain} != manifest {manifest["chainId"]}')
    tag = hex(args.block)
    block = vtf.rpc_call(args.rpc, 'eth_getBlockByNumber', [tag, False])
    print(f'block {args.block} hash {block["hash"]}')

    def code(address):
        return bytes.fromhex(vtf.rpc_call(args.rpc, 'eth_getCode', [address, tag]).removeprefix('0x'))

    ok = True
    want_registry = create_address(deployment['factory'], 1)
    if want_registry != deployment['registry'].lower():
        print(f'registry {deployment["registry"]} is not the factory\'s first CREATE {want_registry}')
        ok = False
    addresses = {'account': deployment['implementation'], 'factory': deployment['factory'],
                 'registry': deployment['registry']}
    for kind, address in addresses.items():
        ok &= vtf.verify(f'{kind} at {address}', kind, vtf.load(ARTIFACTS[kind]),
                         expected_values(kind, manifest, deployment), code(address))
    router = code(manifest['universalRouter'])
    router_hash = vtf.cast_keccak(router)
    if router_hash.lower() != manifest['routerCodeHash'].lower():
        print(f'router code hash {router_hash} != manifest routerCodeHash')
        ok = False
    else:
        print(f'router code hash {router_hash} is the manifest routerCodeHash')
    guardian = '0x' + vtf.rpc_call(args.rpc, 'eth_call', [{'to': deployment['factory'], 'data': GUARDIAN_SELECTOR},
                                                          tag])[-40:]
    if guardian.lower() != manifest['guardian'].lower():
        print(f'factory guardian {guardian} != manifest guardian {manifest["guardian"]} (replaced by the admin?)')
        ok = False
    else:
        print(f'factory guardian {guardian} matches the manifest')
    paused = int(vtf.rpc_call(args.rpc, 'eth_call', [{'to': deployment['factory'], 'data': PAUSED_UNTIL_SELECTOR},
                                                     tag]), 16)
    print(f'factory pausedUntil {paused} (informational)')
    if args.account:
        ok &= verify_clone(f'account {args.account}', deployment['implementation'], code(args.account))
    return ok


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--rpc', default=DEFAULT_RPC)
    parser.add_argument('--block', type=int)
    parser.add_argument('--record', help='deployments/agent-accounts-<chainId>.json from write-agent-accounts-record.py')
    parser.add_argument('--account', help='also check one account clone')
    parser.add_argument('--manifest', default='deployments/agent-accounts-manifest-5042002.json')
    parser.add_argument('--preflight', action='store_true', help='offline: manifest against records and spec')
    parser.add_argument('--self-test', action='store_true', help='offline: every check must behave as required')
    parser.add_argument('--simulate', action='store_true',
                        help='read-only: constructor simulations (eth_call) must equal the reconstructed runtimes')
    parser.add_argument('--self-test-flipped', metavar='KIND:NAME',
                        help='offline: verify KIND (account, factory, registry) with one byte of NAME flipped; '
                             'exits non-zero')
    args = parser.parse_args()
    if args.self_test_flipped:
        kind, _, name = args.self_test_flipped.partition(':')
        if kind not in ARTIFACTS or not name:
            parser.error('--self-test-flipped takes account|factory|registry:IMMUTABLE')
        sys.exit(0 if self_test_kind(kind, name) else 1)
    if args.self_test:
        sys.exit(0 if full_self_test() else 1)
    if args.preflight:
        sys.exit(0 if run_preflight(vtf.load(args.manifest)) else 1)
    if args.simulate:
        sys.exit(0 if simulate(args) else 1)
    if args.block is None or not args.record:
        parser.error('--block and --record are required')
    sys.exit(0 if live(args) else 1)


if __name__ == '__main__':
    main()
