#!/usr/bin/env python3
"""Writes the agent accounts deployment record `agent-accounts-<chainId>.json` from a completed forge broadcast of
script/DeployAgentAccounts.s.sol. No keys, no network.

The record has the shape of Launch's deployment records (one flat JSON object, sorted keys, two-space indent, chain id
and blocks as integers) with the agent keys: implementation, factory, registry, deployBlock (the implementation's
block), factoryDeployBlock, deployer, the manifest inputs (launchFactory, feeManager, graduationManager, launchHook,
poolManager, universalRouter, permit2, usdc, admin, guardian, ceilings), version (the factory's VERSION) and
sourceRevision.

It only ever writes from a broadcast that completed: forge's `run-latest.json` (or a timestamped `run-*.json`) with no
pending transaction, exactly the two expected deployments in order (AgentAccount, then AgentAccountFactory), each a
CREATE from the same sender at consecutive nonces with a receipt of status 1 naming the same contract address, the
broadcast's chain equal to the manifest's and its commit a prefix of the source revision. The implementation's
constructor arguments must name the factory and the registry (the factory's first CREATE) and the manifest's Launch
and Uniswap addresses; the factory's must name the implementation, the manifest's admin and guardian and its ceilings.
Each transaction's input must be the built creation code with exactly those arguments, and the one contract the
factory's constructor creates must be the built AgentPolicyRegistry at that address. Anything else is refused and
nothing is written. A dry run (`dry-run/`, no receipts) is refused. The manifest must first pass
`verify-agent-accounts.py --preflight` (exactly the input keys, Launch's record, the Trade router pin and the spec
4.5 ceilings).

  python3 script/write-agent-accounts-record.py --broadcast FILE [--manifest FILE] [--out-dir deployments]
                                                [--source-revision SHA [--allow-unverified-revision]]
  python3 script/write-agent-accounts-record.py --self-test

It never overwrites a record: archive the current one first (as `archive/agent-accounts-<chainId>-<deployBlock>.json`).
The record is written to a temporary file and hard-linked into place, which fails if the name exists, so even a record
written by a racing run between the check and the write is never replaced.
The record names the source revision: HEAD of a tree whose src/, script/, deployments/ and foundry.toml have no
uncommitted changes. A `--source-revision` must be that HEAD (full SHA); `--allow-unverified-revision` names a full SHA
as given, for a record written from another checkout, and should be reviewed by hand.
Then verify the new record with `verify-agent-accounts.py --record` at its block.
"""
import argparse
import importlib.util
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

root = Path(__file__).resolve().parents[1]
VERSION = '1.0.0-beta.1'  # AgentAccountFactory.VERSION
ACCOUNT_ARTIFACT = 'out/AgentAccount.sol/AgentAccount.json'
FACTORY_ARTIFACT = 'out/AgentAccountFactory.sol/AgentAccountFactory.json'
REGISTRY_ARTIFACT = 'out/AgentPolicyRegistry.sol/AgentPolicyRegistry.json'
# The implementation's constructor arguments after (factory, registry), in order, as manifest keys.
ACCOUNT_INPUTS = ('launchFactory', 'feeManager', 'graduationManager', 'launchHook', 'poolManager', 'universalRouter',
                  'permit2', 'usdc')
# The Policy struct's fields, in order (the factory's fourth constructor argument).
CEILING_FIELDS = ('maxTradeUsdc', 'periodSpendCap', 'perTokenPeriodCap', 'periodSellCap', 'maxActionsPerPeriod',
                  'launchesPerPeriod', 'maxPriceImpactBps', 'maxSnipeBps', 'minTokenAgeBlocks', 'maxDeadlineSeconds',
                  'allowlistOnly')
RECORD_KEYS = {'chainId', 'implementation', 'factory', 'registry', 'deployBlock', 'factoryDeployBlock', 'deployer',
               'admin', 'guardian', 'ceilings', 'version', 'sourceRevision'} | set(ACCOUNT_INPUTS)


class Refused(Exception):
    """The record was not written; the message says why."""


def is_address(text):
    return (isinstance(text, str) and len(text) == 42 and text[:2] == '0x'
            and all(c in '0123456789abcdefABCDEF' for c in text[2:]))


def same(a, b):
    return isinstance(a, str) and isinstance(b, str) and a.lower() == b.lower()


def keccak(data):
    out = subprocess.run(['cast', 'keccak', '0x' + data.hex()], capture_output=True, text=True)
    if out.returncode != 0:
        raise Refused(f'cast keccak failed: {out.stderr.strip()}')
    return bytes.fromhex(out.stdout.strip().removeprefix('0x'))


def rlp_uint(value):
    if value == 0:
        return b'\x80'
    raw = value.to_bytes((value.bit_length() + 7) // 8, 'big')
    return raw if len(raw) == 1 and raw[0] < 0x80 else bytes([0x80 + len(raw)]) + raw


def create_address(sender, nonce):
    """keccak256(rlp([sender, nonce]))[12:], lower case."""
    body = b'\x94' + bytes.fromhex(sender.removeprefix('0x')) + rlp_uint(nonce)
    return '0x' + keccak(bytes([0xc0 + len(body)]) + body)[12:].hex()


def word(value):
    """One ABI word: an address, a bool or an unsigned integer given as a string."""
    if is_address(value):
        return bytes(12) + bytes.fromhex(value[2:])
    if isinstance(value, bool) or str(value) in ('true', 'false'):
        return int(value is True or str(value) == 'true').to_bytes(32, 'big')
    return int(str(value)).to_bytes(32, 'big')


def creation_code(artifact):
    try:
        data = json.loads((root / artifact).read_text())
    except (OSError, ValueError) as error:
        raise Refused(f'cannot read {artifact} (run forge build): {error}')
    return bytes.fromhex(data['bytecode']['object'].removeprefix('0x'))


def checksum(address):
    if not is_address(address):
        raise Refused(f'not an address: {address!r}')
    out = subprocess.run(['cast', 'to-check-sum-address', address], capture_output=True, text=True)
    if out.returncode != 0:
        raise Refused(f'cast could not checksum {address}: {out.stderr.strip()}')
    return out.stdout.strip()


def tuple_values(text):
    """forge records a struct argument as `(a, b, ...)`; returns its fields as strings."""
    text = str(text).strip()
    if not (text.startswith('(') and text.endswith(')')):
        raise Refused(f'factory ceilings argument {text!r} is not a tuple')
    # A display annotation such as `1000000000 [1e9]` is not part of the value.
    return [part.strip().split(' [')[0] for part in text[1:-1].split(',')]


def as_int(value, what):
    try:
        return int(value, 16) if isinstance(value, str) and value.startswith('0x') else int(value)
    except (TypeError, ValueError):
        raise Refused(f'{what} {value!r} is not a number')


def completed_broadcast(path, chain, revision):
    """The two (transaction, receipt) pairs of a completed DeployAgentAccounts broadcast."""
    path = Path(path)
    if 'dry-run' in path.parts:
        raise Refused(f'{path} is a dry run: nothing was broadcast')
    try:
        data = json.loads(path.read_text())
    except (OSError, ValueError) as error:
        raise Refused(f'{path} is not a readable broadcast file: {error}')
    if not isinstance(data, dict) or not isinstance(data.get('transactions'), list):
        raise Refused(f'{path} is not a forge broadcast file')
    if data.get('pending'):
        raise Refused(f'{path} still lists pending transactions: the broadcast did not complete')
    if data.get('chain') != chain:
        raise Refused(f'{path} was broadcast on chain {data.get("chain")}, not {chain}')
    commit = str(data.get('commit') or '')
    if not commit or not revision.lower().startswith(commit.lower()):
        raise Refused(f'{path} was broadcast from commit {commit or "(none)"}, not source revision {revision}')
    transactions = data['transactions']
    if len(transactions) != 2:
        raise Refused(f'{path} has {len(transactions)} transactions; expected AgentAccount then AgentAccountFactory')
    receipts = {str(r.get('transactionHash', '')).lower(): r for r in data.get('receipts') or []}
    pairs = []
    for tx, contract in zip(transactions, ('AgentAccount', 'AgentAccountFactory')):
        name = str(tx.get('contractName') or '')
        if tx.get('transactionType') != 'CREATE' or name.split('.')[0] != contract:
            raise Refused(f'{path} deploys {name or "nothing"} ({tx.get("transactionType")}) where {contract} by '
                          f'CREATE belongs')
        receipt = receipts.get(str(tx.get('hash', '')).lower())
        if receipt is None:
            raise Refused(f'{path} has no receipt for {tx.get("hash")}: the broadcast did not complete')
        if receipt.get('status') not in ('0x1', 1):
            raise Refused(f'{path}: the {contract} deployment {tx.get("hash")} failed (status {receipt.get("status")})')
        address = receipt.get('contractAddress')
        if not is_address(address) or not same(address, tx.get('contractAddress')):
            raise Refused(f'{path}: {contract} receipt contract address {address} != transaction '
                          f'{tx.get("contractAddress")}')
        pairs.append((tx, receipt))
    return pairs


def block_of(receipt, what):
    try:
        value = receipt['blockNumber']
        return int(value, 16) if isinstance(value, str) else int(value)
    except (KeyError, TypeError, ValueError):
        raise Refused(f'the {what} receipt has no block number')


def build(args, manifest, revision):
    chain = manifest.get('chainId')
    (impl_tx, impl_receipt), (factory_tx, factory_receipt) = completed_broadcast(args.broadcast, chain, revision)
    impl_body, factory_body = impl_tx.get('transaction') or {}, factory_tx.get('transaction') or {}
    deployer = impl_body.get('from') or impl_receipt.get('from')
    if not is_address(deployer) or not same(deployer, factory_body.get('from') or factory_receipt.get('from')):
        raise Refused(f'the two deployments have different senders: {deployer} and {factory_body.get("from")}')
    nonce = as_int(impl_body.get('nonce'), 'implementation transaction nonce')
    if as_int(factory_body.get('nonce'), 'factory transaction nonce') != nonce + 1:
        raise Refused(f'factory nonce {factory_body.get("nonce")} is not the implementation nonce {nonce} + 1')
    implementation, factory = impl_tx['contractAddress'], factory_tx['contractAddress']
    if not same(implementation, create_address(deployer, nonce)):
        raise Refused(f'implementation {implementation} is not the CREATE address of {deployer} at nonce {nonce}')
    if not same(factory, create_address(deployer, nonce + 1)):
        raise Refused(f'factory {factory} is not the CREATE address of {deployer} at nonce {nonce + 1}')
    registry = create_address(factory, 1)

    impl_args = list(impl_tx.get('arguments') or [])
    if len(impl_args) != 10:
        raise Refused(f'implementation constructor arguments {impl_args} are not the ten AgentAccount takes')
    if not same(impl_args[0], factory):
        raise Refused(f'implementation FACTORY argument {impl_args[0]} != deployed factory {factory}')
    if not same(impl_args[1], registry):
        raise Refused(f'implementation REGISTRY argument {impl_args[1]} != the factory\'s first CREATE {registry}')
    for value, key in zip(impl_args[2:], ACCOUNT_INPUTS):
        if not same(value, manifest.get(key)):
            raise Refused(f'implementation {key} {value} != manifest {manifest.get(key)}')
    if bytes.fromhex(str(impl_body.get('input') or impl_body.get('data') or '').removeprefix('0x')) != (
            creation_code(ACCOUNT_ARTIFACT) + b''.join(word(a) for a in impl_args)):
        raise Refused('implementation init code is not the built AgentAccount with the recorded arguments')

    factory_args = list(factory_tx.get('arguments') or [])
    if len(factory_args) != 4:
        raise Refused(f'factory constructor arguments {factory_args} are not (implementation, admin, guardian, '
                      f'ceilings)')
    if not same(factory_args[0], implementation):
        raise Refused(f'factory implementation argument {factory_args[0]} != deployed implementation {implementation}')
    for value, key in ((factory_args[1], 'admin'), (factory_args[2], 'guardian')):
        if not same(value, manifest.get(key)):
            raise Refused(f'factory {key} {value} != manifest {manifest.get(key)}')
    ceilings = tuple_values(factory_args[3])
    wanted = manifest.get('ceilings') or {}
    if len(ceilings) != len(CEILING_FIELDS):
        raise Refused(f'factory ceilings {ceilings} do not have {len(CEILING_FIELDS)} fields')
    for value, key in zip(ceilings, CEILING_FIELDS):
        want = wanted.get(key)
        if str(value) != (str(want).lower() if isinstance(want, bool) else str(want)):
            raise Refused(f'factory ceilings.{key} {value} != manifest {want!r}')
    factory_init = (creation_code(FACTORY_ARTIFACT) + b''.join(word(a) for a in factory_args[:3])
                    + b''.join(word(v) for v in ceilings))
    if bytes.fromhex(str(factory_body.get('input') or factory_body.get('data') or '').removeprefix('0x')) != factory_init:
        raise Refused('factory init code is not the built AgentAccountFactory with the recorded arguments')
    created = factory_tx.get('additionalContracts') or []
    name = str((created[0].get('contractName') if created else '') or '')
    if len(created) != 1 or (name and name.split('.')[0] != 'AgentPolicyRegistry'):
        raise Refused(f'the factory deployment created {len(created)} contracts, not exactly its AgentPolicyRegistry')
    if not same(created[0].get('address'), registry):
        raise Refused(f'registry {created[0].get("address")} is not the factory\'s first CREATE {registry}')
    if bytes.fromhex(str(created[0].get('initCode') or '').removeprefix('0x')) != creation_code(REGISTRY_ARTIFACT):
        raise Refused('registry init code is not the built AgentPolicyRegistry')

    block, factory_block = block_of(impl_receipt, 'implementation'), block_of(factory_receipt, 'factory')
    if factory_block < block:
        raise Refused(f'factory block {factory_block} precedes implementation block {block}')
    record = {key: checksum(manifest[key]) for key in ACCOUNT_INPUTS}
    record.update({
        'chainId': chain,
        'implementation': checksum(implementation),
        'factory': checksum(factory),
        'registry': checksum(registry),
        'deployBlock': block,
        'factoryDeployBlock': factory_block,
        'deployer': checksum(deployer),
        'admin': checksum(manifest['admin']),
        'guardian': checksum(manifest['guardian']),
        'ceilings': {key: wanted[key] for key in CEILING_FIELDS},
        'version': VERSION,
        'sourceRevision': revision,
    })
    assert set(record) == RECORD_KEYS
    return record


SOURCE_PATHS = ('src', 'script', 'deployments', 'foundry.toml')


def git_state(repo):
    """(HEAD's full SHA, porcelain status of the source paths) of `repo`; HEAD is None outside a git checkout."""
    head = subprocess.run(['git', 'rev-parse', '--verify', 'HEAD'], cwd=repo, capture_output=True, text=True)
    if head.returncode != 0:
        return None, ''
    dirty = subprocess.run(['git', 'status', '--porcelain', '--', *SOURCE_PATHS], cwd=repo, capture_output=True,
                           text=True, check=True).stdout
    return head.stdout.strip().lower(), dirty


def check_revision(given, head, dirty, override):
    """The source revision the record names. Without `override` it must be HEAD of a tree whose source paths have no
    uncommitted changes (a given revision must equal HEAD); with `override` a given full SHA is taken as is."""
    if given is not None:
        given = given.strip().lower()
        if len(given) != 40 or any(ch not in '0123456789abcdef' for ch in given):
            raise Refused(f'--source-revision {given!r} is not a full 40-hex commit SHA')
        if override:
            return given
    if head is None:
        raise Refused('the source tree is not a git checkout; pass --source-revision with --allow-unverified-revision')
    if given is not None and given != head:
        raise Refused(f'--source-revision {given} is not HEAD ({head}); check out that revision, or pass '
                      f'--allow-unverified-revision to name it anyway')
    if dirty.strip():
        raise Refused(f'the source tree has uncommitted changes; the record must name a clean revision:\n{dirty}')
    return head


def source_revision(args):
    head, dirty = git_state(root)
    return check_revision(args.source_revision, head, dirty, args.allow_unverified_revision)


def manifest_problems(manifest):
    """The verifier's preflight of `manifest` (key set, Launch record, Trade router pin, spec 4.5 ceilings)."""
    # Loaded here, not at import: the verifier imports this module.
    spec = importlib.util.spec_from_file_location('verify_agent_accounts', root / 'script' / 'verify-agent-accounts.py')
    verifier = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(verifier)
    try:
        return verifier.preflight(manifest)
    except (OSError, ValueError) as error:
        return [f'preflight could not read its references: {error}']


def publish(text, target):
    """Writes `text` to `target` only if no file of that name exists, atomically: the full text goes to a temporary
    file in the same directory, which is then hard-linked to `target` (the link fails if `target` exists, even when
    another run created it after any earlier check)."""
    fd, tmp = tempfile.mkstemp(prefix=f'.{target.name}.', suffix='.tmp', dir=target.parent)
    try:
        with os.fdopen(fd, 'w') as handle:
            handle.write(text)
            handle.flush()
            os.fsync(handle.fileno())
        try:
            os.link(tmp, target)
        except FileExistsError:
            raise Refused(f'{target} appeared while the record was being written; it was not replaced')
    finally:
        os.unlink(tmp)


def write(args):
    manifest = json.loads(Path(args.manifest).read_text())
    if not isinstance(manifest, dict) or manifest.get('chainId') not in (5042, 5042002):
        chain = manifest.get('chainId') if isinstance(manifest, dict) else None
        raise Refused(f'manifest chainId {chain!r} is not an Arc network')
    problems = manifest_problems(manifest)
    if problems:
        raise Refused(f'{args.manifest} fails the preflight: ' + '; '.join(problems))
    revision = source_revision(args)
    record = build(args, manifest, revision)
    out_dir = Path(args.out_dir).resolve()
    target = out_dir / f'agent-accounts-{record["chainId"]}.json'
    if target.exists():
        raise Refused(f'{target} exists; archive it as archive/agent-accounts-{record["chainId"]}-<deployBlock>.json '
                      f'first')
    out_dir.mkdir(parents=True, exist_ok=True)
    publish(json.dumps(record, indent=2, sort_keys=True) + '\n', target)
    print(f'wrote {target}')
    print(json.dumps(record, indent=2, sort_keys=True))


# ------------------------------------------------------------------------------------------------- self-test


def selftest():
    revision = 'b794a9c' + '0' * 33
    manifest = json.loads((root / 'deployments/agent-accounts-manifest-5042002.json').read_text())
    sender = '0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266'
    nonce = 7
    implementation = create_address(sender, nonce)
    factory = create_address(sender, nonce + 1)
    registry = create_address(factory, 1)
    other = '0x' + '12' * 20
    ceilings_text = '(' + ', '.join(str(manifest['ceilings'][k]).lower() for k in CEILING_FIELDS) + ')'
    account_code, factory_code, registry_code = (creation_code(a) for a in
                                                 (ACCOUNT_ARTIFACT, FACTORY_ARTIFACT, REGISTRY_ARTIFACT))

    def impl_args(**o):
        args = [o.get('factory', factory), o.get('registry', registry)] + [o.get(k, manifest[k]) for k in ACCOUNT_INPUTS]
        return args

    def factory_args(**o):
        return [o.get('implementation', implementation), o.get('admin', manifest['admin']),
                o.get('guardian', manifest['guardian']), o.get('ceilings', ceilings_text)]

    def bc(impl=None, fac=None, impl_tx=None, fac_tx=None, impl_receipt=None, fac_receipt=None, **top):
        ia = impl if impl is not None else impl_args()
        fa = fac if fac is not None else factory_args()
        txs = [
            {'hash': '0x' + 'aa' * 32, 'transactionType': 'CREATE', 'contractName': 'AgentAccount',
             'contractAddress': implementation, 'function': None, 'arguments': ia,
             'transaction': {'from': sender, 'nonce': hex(nonce),
                             'input': '0x' + (account_code + b''.join(word(a) for a in ia)).hex()},
             'additionalContracts': []},
            {'hash': '0x' + 'bb' * 32, 'transactionType': 'CREATE', 'contractName': 'AgentAccountFactory',
             'contractAddress': factory, 'function': None, 'arguments': fa,
             'transaction': {'from': sender, 'nonce': hex(nonce + 1),
                             'input': '0x' + (factory_code + b''.join(word(a) for a in fa[:3])
                                              + b''.join(word(v) for v in tuple_values(fa[3]))).hex()},
             'additionalContracts': [{'transactionType': 'CREATE', 'contractName': 'AgentPolicyRegistry',
                                      'address': registry, 'initCode': '0x' + registry_code.hex()}]},
        ]
        txs[0].update(impl_tx or {})
        txs[1].update(fac_tx or {})
        receipts = [
            dict({'status': '0x1', 'transactionHash': '0x' + 'aa' * 32, 'blockNumber': hex(100),
                  'contractAddress': implementation, 'from': sender}, **(impl_receipt or {})),
            dict({'status': '0x1', 'transactionHash': '0x' + 'bb' * 32, 'blockNumber': hex(101),
                  'contractAddress': factory, 'from': sender}, **(fac_receipt or {})),
        ]
        data = {'transactions': txs, 'receipts': receipts, 'libraries': [], 'pending': [], 'returns': {},
                'timestamp': 1, 'chain': 5042002, 'commit': 'b794a9c'}
        data.update(top)
        return data

    good = bc()
    cases = []
    # The CREATE formula against known vectors, including a nonce that needs a length-prefixed RLP integer.
    for vector_sender, vector_nonce, want in (
        ('0x6ac7ea33f8831ea9dcc53393aaa88b25a785dbf0', 0, '0xcd234a471b72ba2f1ccf0a70fcaba648a5eecd8d'),
        ('0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266', 1, '0xe7f1725e7734ce288f8367e1bb143e90bb3f0512'),
    ):
        cases.append((f'CREATE address of {vector_sender} at nonce {vector_nonce}',
                      create_address(vector_sender, vector_nonce) == want, ''))
    big = create_address(sender, 0x1234)
    expected = subprocess.run(['cast', 'compute-address', sender, '--nonce', str(0x1234)], capture_output=True,
                              text=True).stdout.strip().split()[-1]
    cases.append(('CREATE address at a two-byte nonce matches cast', same(big, expected), expected))

    def case(name, broadcast, expect_ok, must=(), man=manifest, dry_run=False, existing=False, override=True,
             rev=revision):
        with tempfile.TemporaryDirectory() as d:
            d = Path(d)
            (d / 'manifest.json').write_text(json.dumps(man))
            path = d / ('dry-run' if dry_run else '.') / 'run-latest.json'
            path.parent.mkdir(exist_ok=True)
            path.write_text(json.dumps(broadcast))
            out = d / 'out'
            if existing:
                out.mkdir()
                (out / 'agent-accounts-5042002.json').write_text('{}\n')
            argv = [sys.executable, __file__, '--broadcast', str(path), '--manifest', str(d / 'manifest.json'),
                    '--out-dir', str(out), '--source-revision', rev]
            if override:
                argv.append('--allow-unverified-revision')
            result = subprocess.run(argv, capture_output=True, text=True)
            text = result.stdout + result.stderr
            written = out / 'agent-accounts-5042002.json'
            record = json.loads(written.read_text()) if written.exists() and not existing else None
            ok = (result.returncode == 0) == expect_ok and all(m in text for m in must)
            ok &= (record is not None) if expect_ok else (record is None)
            if expect_ok and record is not None:
                ok &= set(record) == RECORD_KEYS and same(record['registry'], registry)
                ok &= same(record['factory'], factory) and same(record['implementation'], implementation)
                ok &= record['deployBlock'] == 100 and record['factoryDeployBlock'] == 101
                ok &= record['ceilings'] == {k: manifest['ceilings'][k] for k in CEILING_FIELDS}
            cases.append((name, ok, text))

    impl_input = good['transactions'][0]['transaction']
    case('complete broadcast', good, True, must=['"factoryDeployBlock": 101', '"version": "1.0.0-beta.1"'])
    case('dry run', good, False, must=['dry run'], dry_run=True)
    case('pending transaction', bc(pending=[{'hash': '0x01'}]), False, must=['pending'])
    case('other chain', bc(chain=5042), False, must=['chain 5042'])
    case('commit is not the revision', bc(commit='deadbee'), False, must=['commit deadbee'])
    case('no receipt', bc(receipts=[]), False, must=['no receipt'])
    case('failed deployment', bc(fac_receipt={'status': '0x0'}), False, must=['failed'])
    case('receipt address differs', bc(impl_receipt={'contractAddress': other}), False,
         must=['receipt contract address'])
    case('one transaction', dict(good, transactions=good['transactions'][:1]), False, must=['1 transactions'])
    case('three transactions', dict(good, transactions=good['transactions'] + good['transactions'][:1]), False,
         must=['3 transactions'])
    case('wrong order', dict(good, transactions=good['transactions'][::-1]), False, must=['AgentAccount by CREATE'])
    case('another contract', bc(fac_tx={'contractName': 'AgentFixture'}), False, must=['AgentAccountFactory by CREATE'])
    case('different senders', bc(fac_tx={'transaction': dict(good['transactions'][1]['transaction'], **{'from': other})}),
         False, must=['different senders'])
    case('factory not at the next nonce',
         bc(fac_tx={'transaction': dict(good['transactions'][1]['transaction'], nonce=hex(nonce + 2))}), False,
         must=['is not the implementation nonce'])
    case('implementation not at its CREATE address', bc(impl_tx={'contractAddress': other},
                                                        impl_receipt={'contractAddress': other}), False,
         must=['implementation 0x1212'])
    case('implementation bound to another factory', bc(impl=impl_args(factory=other)), False,
         must=['FACTORY argument'])
    case('implementation bound to another registry', bc(impl=impl_args(registry=other)), False,
         must=['REGISTRY argument'])
    case('implementation router differs', bc(impl=impl_args(universalRouter=other)), False,
         must=['implementation universalRouter'])
    tampered = bytearray.fromhex(impl_input['input'][2:])
    tampered[-1] ^= 1
    case('implementation init code differs from its arguments',
         bc(impl_tx={'transaction': dict(impl_input, input='0x' + tampered.hex())}), False,
         must=['not the built AgentAccount'])
    case('factory bound to another implementation', bc(fac=factory_args(implementation=other)), False,
         must=['factory implementation argument'])
    case('factory admin differs', bc(fac=factory_args(admin=other)), False, must=['factory admin'])
    case('factory guardian differs', bc(fac=factory_args(guardian=other)), False, must=['factory guardian'])
    case('factory ceiling differs', bc(fac=factory_args(ceilings=ceilings_text.replace('1000000000,', '1000000001,', 1))),
         False, must=['factory ceilings.maxTradeUsdc'])
    case('factory init code differs from its arguments',
         bc(fac_tx={'transaction': dict(good['transactions'][1]['transaction'],
                                        input=good['transactions'][1]['transaction']['input'][:-2] + '01')}),
         False, must=['not the built AgentAccountFactory'])
    case('no registry created', bc(fac_tx={'additionalContracts': []}), False, must=['not exactly its'])
    case('registry elsewhere', bc(fac_tx={'additionalContracts': [dict(
        good['transactions'][1]['additionalContracts'][0], address=other)]}), False, must=['first CREATE'])
    case('registry init code differs', bc(fac_tx={'additionalContracts': [dict(
        good['transactions'][1]['additionalContracts'][0], initCode='0x00')]}), False,
         must=['not the built AgentPolicyRegistry'])
    case('factory block before implementation block', bc(fac_receipt={'blockNumber': hex(99)}), False,
         must=['precedes'])
    mainnet = json.loads((root / 'deployments/agent-accounts-manifest-5042.json').read_text())
    case('manifest of another chain', good, False, must=['chain 5042002, not 5042'], man=mainnet)
    case('existing record is never overwritten', good, False, must=['exists'], existing=True)
    case('manifest with an extra key', good, False, must=['fails the preflight', 'manifest keys differ'],
         man=dict(manifest, factory=other))
    case('manifest missing a key', good, False, must=['fails the preflight', 'missing [\'routerCodeHash\']'],
         man={k: v for k, v in manifest.items() if k != 'routerCodeHash'})
    case('manifest with a raised ceiling', good, False, must=['fails the preflight', 'ceilings.maxTradeUsdc'],
         man=dict(manifest, ceilings=dict(manifest['ceilings'], maxTradeUsdc=manifest['ceilings']['maxTradeUsdc'] + 1)))
    case('manifest Launch address differs from the record', good, False, must=['fails the preflight', 'feeManager'],
         man=dict(manifest, feeManager=other))

    # --source-revision: without the override it must be HEAD of a clean tree; the override takes a full SHA as is.
    case('source revision that is not HEAD, no override', good, False, must=['is not HEAD'], override=False)
    case('abbreviated source revision refused even with the override', good, False,
         must=['not a full 40-hex commit SHA'], rev='b794a9c')
    head_sha = 'ab' * 20

    def checked(given, head, dirty, override):
        try:
            return check_revision(given, head, dirty, override)
        except Refused as error:
            return f'refused: {error}'

    for name, got, want in (
        ('given HEAD of a clean tree is accepted', checked(head_sha.upper(), head_sha, '', False), head_sha),
        ('no revision given: HEAD of a clean tree', checked(None, head_sha, '', False), head_sha),
        ('given revision other than HEAD is refused', checked('cd' * 20, head_sha, '', False), 'is not HEAD'),
        ('given HEAD of a dirty tree is refused', checked(head_sha, head_sha, ' M src/x.sol\n', False),
         'uncommitted changes'),
        ('no revision given, dirty tree is refused', checked(None, head_sha, '?? script/x.py\n', False),
         'uncommitted changes'),
        ('override names another revision', checked('cd' * 20, head_sha, '', True), 'cd' * 20),
        ('override accepts a dirty tree', checked(head_sha, head_sha, ' M src/x.sol\n', True), head_sha),
        ('outside a git checkout without the override is refused', checked(head_sha, None, '', False),
         'not a git checkout'),
    ):
        cases.append((f'revision check: {name}', got == want or (got.startswith('refused') and want in got), got))

    # git_state against a real throwaway repository: clean, then a change under src/ and an untracked script.
    with tempfile.TemporaryDirectory() as d:
        git = ['git', '-c', 'user.name=self-test', '-c', 'user.email=self-test@invalid', '-c', 'commit.gpgsign=false']
        (Path(d) / 'src').mkdir()
        (Path(d) / 'src' / 'A.sol').write_text('a\n')
        (Path(d) / 'notes.txt').write_text('n\n')
        for argv in (['init', '-q'], ['add', '-A'], ['commit', '-q', '-m', 'init']):
            subprocess.run(git + argv, cwd=d, check=True, capture_output=True)
        want_head = subprocess.run(['git', 'rev-parse', 'HEAD'], cwd=d, capture_output=True, text=True,
                                   check=True).stdout.strip()
        head, dirty = git_state(d)
        cases.append(('git state of a clean checkout', head == want_head and dirty == '', f'{head} {dirty!r}'))
        (Path(d) / 'notes.txt').write_text('changed outside the source paths\n')
        head, dirty = git_state(d)
        cases.append(('git state ignores changes outside the source paths', dirty == '', repr(dirty)))
        (Path(d) / 'src' / 'A.sol').write_text('b\n')
        (Path(d) / 'script').mkdir()
        (Path(d) / 'script' / 'new.py').write_text('x\n')
        head, dirty = git_state(d)
        cases.append(('git state sees a modified source and an untracked script',
                      'src/A.sol' in dirty and 'script/' in dirty, repr(dirty)))
        cases.append(('dirty throwaway checkout is refused', checked(want_head, head, dirty, False).startswith(
            'refused') and 'uncommitted' in checked(want_head, head, dirty, False), checked(want_head, head, dirty,
                                                                                            False)))
    with tempfile.TemporaryDirectory() as d:
        head, dirty = git_state(d)
        cases.append(('git state outside a checkout', head is None, f'{head} {dirty!r}'))

    # A racing run creates the record after the existence check: the link refuses and the racing file survives.
    with tempfile.TemporaryDirectory() as d:
        target = Path(d) / 'agent-accounts-5042002.json'
        target.write_text('{"racing": true}\n')
        try:
            publish('{"ours": true}\n', target)
            raced = 'publish replaced an existing record'
        except Refused as error:
            raced = str(error)
        leftovers = sorted(p.name for p in Path(d).iterdir() if p != target)
        cases.append(('a record that appears mid-write is never overwritten',
                      'not replaced' in raced and target.read_text() == '{"racing": true}\n' and not leftovers,
                      f'{raced}; leftovers {leftovers}'))
        target.unlink()
        publish('{"ours": true}\n', target)
        leftovers = sorted(p.name for p in Path(d).iterdir() if p != target)
        cases.append(('publish writes the full record when the name is free',
                      target.read_text() == '{"ours": true}\n' and not leftovers, f'leftovers {leftovers}'))

    failed = 0
    for name, ok, text in cases:
        print(f'  {"PASS" if ok else "FAIL"}  {name}')
        if not ok:
            failed += 1
            print('\n'.join('        | ' + line for line in text.splitlines()))
    print(f'write-agent-accounts-record.py self-test: {len(cases) - failed}/{len(cases)} passed')
    sys.exit(1 if failed else 0)


def main():
    parser = argparse.ArgumentParser(description='Write deployments/agent-accounts-<chainId>.json from a completed '
                                                 'forge broadcast of DeployAgentAccounts.')
    parser.add_argument('--broadcast', help="forge's run-latest.json (or run-*.json) of DeployAgentAccounts")
    parser.add_argument('--manifest', default=str(root / 'deployments/agent-accounts-manifest-5042002.json'))
    parser.add_argument('--out-dir', default=str(root / 'deployments'))
    parser.add_argument('--source-revision', help='full commit SHA; must be HEAD of a clean tree (the default)')
    parser.add_argument('--allow-unverified-revision', action='store_true',
                        help='name --source-revision as given even when it is not HEAD or the tree is dirty')
    parser.add_argument('--self-test', action='store_true')
    args = parser.parse_args()
    if args.self_test:
        selftest()
    if not args.broadcast:
        parser.error('--broadcast is required')
    try:
        write(args)
    except Refused as error:
        print(f'write-agent-accounts-record.py: NOT WRITTEN: {error}', file=sys.stderr)
        sys.exit(1)


if __name__ == '__main__':
    main()
