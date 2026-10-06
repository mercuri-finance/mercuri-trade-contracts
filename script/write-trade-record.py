#!/usr/bin/env python3
"""Writes the Trade deployment record `<chainId>.json` from completed forge broadcasts. No keys, no network.

The record has the shape of Launch's deployment records (one flat JSON object, sorted keys, two-space indent, chain id
and blocks as integers) with the Trade keys: reactor, filler, validator, executionFee, feeRecipient, reactorFeeOwner,
reactorFeeController, appRecipient, launchHook, poolManager, usdc, permit2, router, deployBlock (the reactor's block,
the first in which any of the contracts can emit), fillerDeployBlock (the filler's and its validator's block), deployer,
version and sourceRevision.

It only ever writes from a broadcast that completed: forge's `run-latest.json` (or a timestamped `run-*.json`) with no
pending transaction, exactly the one expected deployment, a receipt with status 1 for it, the broadcast's chain equal to
the manifest's and its commit a prefix of the source revision. The reactor is a CREATE whose receipt names the same
contract address. The filler is a CREATE2 through the standard deployer (spec D22): the transaction goes to that
deployer, its input is `FILLER_SALT ++ init code`, the init code is the built filler's creation code with the
recorded arguments, and the filler's address is that CREATE2 address; the one contract it creates in its constructor
is the validator, at the CREATE2 address from the filler with `VALIDATOR_SALT` and the built validator's creation code
with `(filler, poolManager)`. The constructor arguments must equal the manifest. Anything else is refused and nothing
is written. A dry run (`dry-run/`, no receipts) is refused.

The standard deployer is permissionless, so someone can replay the filler's init code before the operator's
transaction lands (re-audit C-05). DeployOrderFiller then adopts the pair, broadcasts nothing and leaves no filler
broadcast to read. `--adopted-filler-block N` records that pair instead: the filler is the CREATE2 address of the built
filler with the manifest's arguments (the recorded reactor and the manifest's keeper), the validator is its CREATE2
deployment, `fillerDeployBlock` is N, the block in which the pair appeared, and the record carries
`fillerAdopted: true`. Its `deployer` key is replaced by `reactorDeployer`, the sender of the reactor's CREATE,
because the filler's CREATE2 was not the operator's transaction. Nothing here reads the chain: verify-trade-filler.py at block N then requires every byte of
both runtimes to match and the filler to have had no code at block N - 1, so a wrong N or a different pair is refused.

  python3 script/write-trade-record.py --reactor-broadcast FILE --filler-broadcast FILE [--manifest FILE]
                                       [--out-dir deployments] [--source-revision SHA]
  python3 script/write-trade-record.py --filler-broadcast FILE --previous-record FILE   # a replacement filler on
                                                                                        # the recorded reactor
  python3 script/write-trade-record.py --reactor-broadcast FILE --adopted-filler-block N   # (or --previous-record)
                                       # a pair someone else landed first; verify it at block N before trusting it
  python3 script/write-trade-record.py ... --rehearsal --out-dir DIR    # loopback anvil rehearsal: overrides allowed,
                                                                        # never into deployments/
  python3 script/write-trade-record.py --self-test

It never overwrites a record: archive the current one first (as `archive/<chainId>-<deployBlock>.json`, the way
Launch's records.py does). Then verify the new record with verify-trade-filler.py at its block.
"""
import argparse
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

root = Path(__file__).resolve().parents[1]
VERSION = '1.0.0'
ANVIL_ACCOUNTS = {a.lower() for a in (
    '0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266', '0x70997970C51812dc3A010C7d01b50e0d17dc79C8',
    '0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC', '0x90F79bf6EB2c4f870365E785982E1f101E93b906',
    '0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65', '0x9965507D1a55bcC2695C58ba16FB37d819B0A4dc',
    '0x976EA74026E726554dB657fA54763abd0C3a0aa9', '0x14dC79964da2C08b23698B3D3cc7Ca32193d9955',
    '0x23618e81E3f5cdF7f54C3d65f7FBc0aBf5B21E8f', '0xa0Ee7A142d267C1f36714E4a8F75612F20a79720',
)}
ZERO = '0x' + '0' * 40
CREATE2_FACTORY = '0x4e59b44847b379578588920ca78fbf26c0b4956c'
FILLER_SALT = '00' * 32  # TradeManifest.FILLER_SALT
VALIDATOR_SALT = '00' * 32  # MercuriOrderFiller.VALIDATOR_SALT
FILLER_ARTIFACT = 'out/MercuriOrderFiller.sol/MercuriOrderFiller.json'
VALIDATOR_ARTIFACT = 'out/MercuriOrderValidator.sol/MercuriOrderValidator.json'


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


def create2_address(deployer, salt_hex, init_code):
    """EIP-1014: keccak256(0xff ++ deployer ++ salt ++ keccak256(init_code))[12:]."""
    raw = b'\xff' + bytes.fromhex(deployer.removeprefix('0x')) + bytes.fromhex(salt_hex) + keccak(init_code)
    return '0x' + keccak(raw)[12:].hex()


def word(value):
    """One ABI word: an address or an unsigned integer given as a string."""
    if is_address(value):
        return bytes(12) + bytes.fromhex(value[2:])
    return int(str(value)).to_bytes(32, 'big')


def creation_code(artifact):
    try:
        data = json.loads((root / artifact).read_text())
    except (OSError, ValueError) as error:
        raise Refused(f'cannot read {artifact} (run forge build): {error}')
    return bytes.fromhex(data['bytecode']['object'].removeprefix('0x'))


def validator_address(filler, pool_manager, code=None):
    """The validator the filler at `filler` deploys: CREATE2 from the filler with VALIDATOR_SALT."""
    code = creation_code(VALIDATOR_ARTIFACT) if code is None else code
    return create2_address(filler, VALIDATOR_SALT, code + word(filler) + word(pool_manager))


def completed_create(path, contract, chain, revision):
    """The (address, block, deployer, arguments, transaction) of the one deployment of `contract` in a completed
    broadcast: a CREATE for the reactor, a CREATE2 through the standard deployer for the filler."""
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
    if len(transactions) != 1:
        raise Refused(f'{path} has {len(transactions)} transactions; expected the one {contract} deployment')
    tx = transactions[0]
    name = str(tx.get('contractName') or '')
    kind = 'CREATE2' if contract == 'MercuriOrderFiller' else 'CREATE'
    if tx.get('transactionType') != kind or name.split('.')[0] != contract:
        raise Refused(f'{path} deploys {name or "nothing"} ({tx.get("transactionType")}), not {contract} by {kind}')
    receipts = {str(r.get('transactionHash', '')).lower(): r for r in data.get('receipts') or []}
    receipt = receipts.get(str(tx.get('hash', '')).lower())
    if receipt is None:
        raise Refused(f'{path} has no receipt for {tx.get("hash")}: the broadcast did not complete')
    if receipt.get('status') not in ('0x1', 1):
        raise Refused(f'{path}: the {contract} deployment {tx.get("hash")} failed (status {receipt.get("status")})')
    if kind == 'CREATE':
        address = receipt.get('contractAddress')
        if not is_address(address) or not same(address, tx.get('contractAddress')):
            raise Refused(f'{path}: receipt contract address {address} != transaction {tx.get("contractAddress")}')
    else:
        # A CREATE2 through the deployer is a call: its receipt has no contract address. The address follows from
        # the call's input, which must be the salt and an init code whose CREATE2 address is the recorded one.
        address = tx.get('contractAddress')
        body = (tx.get('transaction') or {})
        if not same(body.get('to'), CREATE2_FACTORY):
            raise Refused(f'{path}: the {contract} CREATE2 went to {body.get("to")}, not the standard deployer')
        data = str(body.get('input') or body.get('data') or '').removeprefix('0x')
        if len(data) < 64 or data[:64] != FILLER_SALT:
            raise Refused(f'{path}: the {contract} CREATE2 does not use FILLER_SALT')
        if not is_address(address) or not same(create2_address(CREATE2_FACTORY, data[:64], bytes.fromhex(data[64:])),
                                                address):
            raise Refused(f'{path}: transaction contract address {address} is not the CREATE2 address of its input')
    try:
        block = int(receipt['blockNumber'], 16) if isinstance(receipt['blockNumber'], str) else int(receipt['blockNumber'])
    except (KeyError, TypeError, ValueError):
        raise Refused(f'{path}: the receipt has no block number')
    deployer = (tx.get('transaction') or {}).get('from') or receipt.get('from')
    return checksum(address), block, checksum(deployer), list(tx.get('arguments') or []), tx


def checksum(address):
    if not is_address(address):
        raise Refused(f'not an address: {address!r}')
    out = subprocess.run(['cast', 'to-check-sum-address', address], capture_output=True, text=True)
    if out.returncode != 0:
        raise Refused(f'cast could not checksum {address}: {out.stderr.strip()}')
    return out.stdout.strip()


def chosen(manifest, key, value, rehearsal):
    """A constructor argument for an owner choice: the manifest's address, or under rehearsal an anvil account."""
    if rehearsal:
        if value.lower() not in ANVIL_ACCOUNTS and not same(value, manifest.get(key)):
            raise Refused(f'rehearsal {key} {value} is neither an anvil default account nor the manifest value')
        return value
    if not is_address(manifest.get(key)):
        raise Refused(f'manifest {key} is not chosen ({manifest.get(key)!r}); no record for a deployment that skipped it')
    if not same(value, manifest[key]):
        raise Refused(f'broadcast {key} {value} != manifest {manifest[key]}')
    return value


def build(args, manifest, revision):
    chain = manifest['chainId']
    if args.reactor_broadcast:
        reactor, block, reactor_deployer, reactor_args, _ = completed_create(
            args.reactor_broadcast, 'V3DutchOrderReactor', chain, revision)
        if len(reactor_args) != 2:
            raise Refused(f'reactor constructor arguments {reactor_args} are not (permit2, owner)')
        if not same(reactor_args[0], manifest['permit2']):
            raise Refused(f'reactor permit2 {reactor_args[0]} != manifest {manifest["permit2"]}')
        owner = chosen(manifest, 'reactorFeeOwner', reactor_args[1], args.rehearsal)
        controller = manifest.get('reactorFeeController', ZERO)
    else:
        previous = json.loads(Path(args.previous_record).read_text())
        if previous.get('chainId') != chain:
            raise Refused(f'previous record chainId {previous.get("chainId")} != manifest {chain}')
        reactor, block = previous['reactor'], int(previous['deployBlock'])
        # An adopted record names the reactor's sender as reactorDeployer; any other record's deployer sent both.
        reactor_deployer = previous.get('reactorDeployer') or previous.get('deployer')
        owner, controller = previous['reactorFeeOwner'], previous['reactorFeeController']
        if not args.rehearsal and not same(owner, manifest.get('reactorFeeOwner')):
            raise Refused(f'previous record reactorFeeOwner {owner} != manifest {manifest.get("reactorFeeOwner")}')
        if not same(controller, manifest.get('reactorFeeController', ZERO)):
            raise Refused(f'previous record reactorFeeController {controller} != manifest')
    if args.adopted_filler_block is not None:
        return adopted(args, manifest, revision, chain, reactor, block, reactor_deployer, owner, controller)
    filler, filler_block, deployer, filler_args, filler_tx = completed_create(
        args.filler_broadcast, 'MercuriOrderFiller', chain, revision)
    if len(filler_args) != 9:
        raise Refused(f'filler constructor arguments {filler_args} are not the nine the filler takes')
    for index, key in enumerate(('router', 'permit2', 'usdc', 'launchHook', 'appRecipient'), start=1):
        if not same(filler_args[index], manifest[key]):
            raise Refused(f'filler {key} {filler_args[index]} != manifest {manifest[key]}')
    if not same(filler_args[8], manifest.get('poolManager')):
        raise Refused(f'filler poolManager {filler_args[8]} != manifest {manifest.get("poolManager")}')
    # The CREATE2 input must be this build's filler creation code with exactly the recorded arguments.
    body = filler_tx.get('transaction') or {}
    init = bytes.fromhex(str(body.get('input') or body.get('data') or '').removeprefix('0x')[64:])
    expected_init = creation_code(FILLER_ARTIFACT) + b''.join(word(a) for a in filler_args)
    if init != expected_init:
        raise Refused('filler init code is not the built MercuriOrderFiller with the recorded arguments')
    created = filler_tx.get('additionalContracts') or []
    if len(created) != 1 or str(created[0].get('contractName') or '').split('.')[0] != 'MercuriOrderValidator':
        raise Refused(f'the filler deployment created {len(created)} contracts, not exactly its MercuriOrderValidator')
    validator = created[0].get('address')
    expected_validator = validator_address(filler, filler_args[8])
    if not same(validator, expected_validator):
        raise Refused(f'validator {validator} is not the CREATE2 address {expected_validator} from the filler')
    validator_init = bytes.fromhex(str(created[0].get('initCode') or '').removeprefix('0x'))
    if validator_init != creation_code(VALIDATOR_ARTIFACT) + word(filler) + word(filler_args[8]):
        raise Refused('validator init code is not the built MercuriOrderValidator bound to this filler')
    if not same(filler_args[0], reactor):
        raise Refused(f'filler reactor {filler_args[0]} != recorded reactor {reactor}')
    if filler_block < block:
        raise Refused(f'filler block {filler_block} precedes reactor block {block}')
    fee = manifest.get('executionFee')
    if type(fee) is not int or str(filler_args[6]) != str(fee):
        raise Refused(f'filler executionFee {filler_args[6]} != manifest {fee!r}')
    recipient = chosen(manifest, 'feeRecipient', filler_args[7], args.rehearsal)
    if not is_address(controller):
        raise Refused(f'reactorFeeController {controller!r} is not an address')
    return {
        'appRecipient': checksum(manifest['appRecipient']),
        'chainId': chain,
        'deployBlock': block,
        'deployer': deployer,
        'executionFee': fee,
        'feeRecipient': checksum(recipient),
        'filler': filler,
        'fillerDeployBlock': filler_block,
        'launchHook': checksum(manifest['launchHook']),
        'permit2': checksum(manifest['permit2']),
        'poolManager': checksum(manifest['poolManager']),
        'reactor': checksum(reactor),
        'reactorFeeController': checksum(controller),
        'reactorFeeOwner': checksum(owner),
        'router': checksum(manifest['router']),
        'sourceRevision': revision,
        'usdc': checksum(manifest['usdc']),
        'validator': checksum(validator),
        'version': VERSION,
    }


def adopted(args, manifest, revision, chain, reactor, block, deployer, owner, controller):
    """The record for a pair that someone else landed by replaying the filler's init code (re-audit C-05).

    Every address follows from the build and the manifest, so nothing is taken from the copier's transaction. The
    verifier must then prove the bytes on chain at `fillerDeployBlock`. The record has no `deployer`: that key means
    the sender of the release's transactions, and the filler's CREATE2 was someone else's. `reactorDeployer` names the
    sender of the reactor's CREATE instead (fix re-audit N-03).
    """
    filler_block = args.adopted_filler_block
    if filler_block < block:
        raise Refused(f'adopted filler block {filler_block} precedes reactor block {block}')
    fee = manifest.get('executionFee')
    if type(fee) is not int:
        raise Refused(f'manifest executionFee is not chosen ({fee!r}); no record for a deployment that skipped it')
    if args.rehearsal:
        if not is_address(args.fee_recipient):
            raise Refused('a rehearsal adoption needs --fee-recipient, the anvil account the rehearsal keeper used')
        recipient = chosen(manifest, 'feeRecipient', args.fee_recipient, True)
    else:
        if args.fee_recipient is not None:
            raise Refused('--fee-recipient is for a rehearsal only; the keeper is the manifest feeRecipient')
        recipient = chosen(manifest, 'feeRecipient', str(manifest.get('feeRecipient')), False)
    if not is_address(deployer):
        raise Refused(f'no deployer for the release (reactor deployer {deployer!r})')
    arguments = [reactor, manifest['router'], manifest['permit2'], manifest['usdc'], manifest['launchHook'],
                 manifest['appRecipient'], str(fee), recipient, manifest['poolManager']]
    init = creation_code(FILLER_ARTIFACT) + b''.join(word(a) for a in arguments)
    filler = checksum(create2_address(CREATE2_FACTORY, FILLER_SALT, init))
    validator = validator_address(filler, manifest['poolManager'])
    if not is_address(controller):
        raise Refused(f'reactorFeeController {controller!r} is not an address')
    return {
        'appRecipient': checksum(manifest['appRecipient']),
        'chainId': chain,
        'deployBlock': block,
        'executionFee': fee,
        'feeRecipient': checksum(recipient),
        'filler': filler,
        'fillerAdopted': True,
        'fillerDeployBlock': filler_block,
        'launchHook': checksum(manifest['launchHook']),
        'permit2': checksum(manifest['permit2']),
        'poolManager': checksum(manifest['poolManager']),
        'reactor': checksum(reactor),
        'reactorDeployer': checksum(deployer),
        'reactorFeeController': checksum(controller),
        'reactorFeeOwner': checksum(owner),
        'router': checksum(manifest['router']),
        'sourceRevision': revision,
        'usdc': checksum(manifest['usdc']),
        'validator': checksum(validator),
        'version': VERSION,
    }


def source_revision(args):
    if args.source_revision:
        return args.source_revision
    head = subprocess.run(['git', 'rev-parse', 'HEAD'], cwd=root, capture_output=True, text=True, check=True)
    dirty = subprocess.run(['git', 'status', '--porcelain', '--', 'src', 'script', 'deployments', 'foundry.toml'],
                           cwd=root, capture_output=True, text=True, check=True).stdout
    if dirty.strip():
        raise Refused(f'the source tree has uncommitted changes; the record must name a clean revision:\n{dirty}')
    return head.stdout.strip()


def write(args):
    if bool(args.reactor_broadcast) == bool(args.previous_record):
        raise Refused('give exactly one of --reactor-broadcast and --previous-record')
    if bool(args.filler_broadcast) == (args.adopted_filler_block is not None):
        raise Refused('give exactly one of --filler-broadcast and --adopted-filler-block')
    out_dir = Path(args.out_dir).resolve()
    if args.rehearsal and out_dir == (root / 'deployments').resolve():
        raise Refused('a rehearsal record never goes into deployments/; pass --out-dir')
    manifest = json.loads(Path(args.manifest).read_text())
    revision = source_revision(args)
    record = build(args, manifest, revision)
    target = out_dir / f'{record["chainId"]}.json'
    if target.exists():
        raise Refused(f'{target} exists; archive it as archive/{record["chainId"]}-<deployBlock>.json first')
    out_dir.mkdir(parents=True, exist_ok=True)
    tmp = target.with_suffix('.json.tmp')
    tmp.write_text(json.dumps(record, indent=2, sort_keys=True) + '\n')
    os.replace(tmp, target)
    print(f'wrote {target}')
    print(json.dumps(record, indent=2, sort_keys=True))


# ------------------------------------------------------------------------------------------------- self-test


def selftest():
    revision = 'b794a9c' + '0' * 33
    reactor = '0x6cd6aed7978839bbe6d64aff16fd1fa17ffb71bf'
    filler = '0x2d4a9ebb2c5d8cd84627e79f0aa64bb8f15fc3d9'
    keeper = '0x00000000000000000000000000000000000000bb'
    base = json.loads((root / 'deployments/manifest-5042002.json').read_text())
    chosen_manifest = dict(base, feeRecipient=keeper)

    filler_code = creation_code(FILLER_ARTIFACT)
    validator_code = creation_code(VALIDATOR_ARTIFACT)

    def broadcast(name, address, arguments, block, tx=None, receipt=None, **override):
        tx_hash = '0x' + (('aa' if name.startswith('V3') else 'bb') * 32)
        data = {
            'transactions': [dict({
                'hash': tx_hash, 'transactionType': 'CREATE', 'contractName': name, 'contractAddress': address,
                'function': None, 'arguments': arguments,
                'transaction': {'from': '0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266'},
            }, **(tx or {}))],
            'receipts': [dict({'status': '0x1', 'transactionHash': tx_hash, 'blockNumber': hex(block),
                               'contractAddress': address, 'from': '0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266'},
                              **(receipt or {}))],
            'libraries': [], 'pending': [], 'returns': {}, 'timestamp': 1, 'chain': 5042002, 'commit': 'b794a9c',
        }
        for key, value in override.items():
            if key == 'tx':
                data['transactions'][0].update(value)
            elif key == 'receipt':
                data['receipts'][0].update(value)
            else:
                data[key] = value
        return data

    def reactor_bc(**o):
        return broadcast('V3DutchOrderReactor.small', reactor, [base['permit2'], base['reactorFeeOwner']], 100, **o)

    def filler_args(owner_reactor=reactor, recipient=keeper, fee=None, pool_manager=None):
        return [owner_reactor, base['router'], base['permit2'], base['usdc'], base['launchHook'],
                base['appRecipient'], str(base['executionFee'] if fee is None else fee), recipient,
                pool_manager or base['poolManager']]

    def filler_bc(**o):
        """A CREATE2 of the built filler through the standard deployer, with its validator, as forge records it."""
        arguments = o.pop('arguments', filler_args())
        init = filler_code + b''.join(word(a) for a in arguments)
        address = create2_address(CREATE2_FACTORY, FILLER_SALT, init)
        validator = validator_address(address, arguments[8], validator_code)
        tx = {
            'transactionType': 'CREATE2',
            'transaction': {'from': '0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266', 'to': CREATE2_FACTORY,
                            'input': '0x' + FILLER_SALT + init.hex()},
            'additionalContracts': [{
                'transactionType': 'CREATE2', 'contractName': 'MercuriOrderValidator', 'address': validator,
                'initCode': '0x' + (validator_code + word(address) + word(arguments[8])).hex(),
            }],
        }
        tx.update(o.pop('tx', {}))
        receipt = dict({'contractAddress': None}, **o.pop('receipt', {}))
        return broadcast('MercuriOrderFiller', address, arguments, 101, tx=tx, receipt=receipt, **o)

    cases = []

    def case(name, manifest, rbc, fbc, expect_ok, extra=(), must=(), previous=None, dry_run=False, existing=False,
             must_not=()):
        with tempfile.TemporaryDirectory() as d:
            d = Path(d)
            (d / 'manifest.json').write_text(json.dumps(manifest))
            argv = [sys.executable, __file__, '--manifest', str(d / 'manifest.json'), '--out-dir', str(d / 'out'),
                    '--source-revision', revision, *extra]
            if rbc is not None:
                (d / 'r.json').write_text(json.dumps(rbc))
                argv += ['--reactor-broadcast', str(d / 'r.json')]
            if previous is not None:
                (d / 'prev.json').write_text(json.dumps(previous))
                argv += ['--previous-record', str(d / 'prev.json')]
            if fbc is not None:
                fpath = d / ('dry-run' if dry_run else '.') / 'f.json'
                fpath.parent.mkdir(exist_ok=True)
                fpath.write_text(json.dumps(fbc))
                argv += ['--filler-broadcast', str(fpath)]
            if existing:
                (d / 'out').mkdir()
                (d / 'out' / '5042002.json').write_text('{}\n')
            result = subprocess.run(argv, capture_output=True, text=True)
            text = result.stdout + result.stderr
            written = (d / 'out' / '5042002.json')
            record = json.loads(written.read_text()) if written.exists() and not existing else None
            ok = (result.returncode == 0) == expect_ok and all(m in text for m in must)
            ok &= not any(m in text for m in must_not)
            if expect_ok:
                ok &= record is not None
            else:
                ok &= record is None
            cases.append((name, ok, text, record))

    case('complete broadcasts', chosen_manifest, reactor_bc(), filler_bc(), True,
         must=['"fillerDeployBlock": 101', '"deployBlock": 100', '"reactorFeeOwner": "0x41129B5215cA24b29a4cABcaE26d3569744DEe2E"',
               '"validator": "0x', '"poolManager": "0x8366a39CC670B4001A1121B8F6A443A643e40951"'])
    case('pending transaction', chosen_manifest, reactor_bc(), filler_bc(pending=[{'hash': '0x01'}]), False,
         must=['pending'])
    case('no receipt', chosen_manifest, reactor_bc(receipts=[]), filler_bc(), False, must=['no receipt'])
    case('failed deployment', chosen_manifest, reactor_bc(), filler_bc(receipt={'status': '0x0'}), False,
         must=['failed'])
    case('other chain', chosen_manifest, reactor_bc(chain=5042), filler_bc(), False, must=['chain 5042'])
    case('other contract', chosen_manifest, reactor_bc(), filler_bc(tx={'contractName': 'CallbackFiller'}), False,
         must=['not MercuriOrderFiller'])
    case('filler by plain CREATE', chosen_manifest, reactor_bc(), filler_bc(tx={'transactionType': 'CREATE'}), False,
         must=['not MercuriOrderFiller by CREATE2'])
    case('receipt address differs', chosen_manifest, reactor_bc(receipt={'contractAddress': filler}), filler_bc(),
         False, must=['receipt contract address'])
    good = filler_bc()
    other_address = '0x' + '12' * 20
    case('filler not at the CREATE2 address of its input', chosen_manifest, reactor_bc(),
         filler_bc(tx={'contractAddress': other_address}), False, must=['not the CREATE2 address'])
    case('filler CREATE2 through another deployer', chosen_manifest, reactor_bc(),
         filler_bc(tx={'transaction': dict(good['transactions'][0]['transaction'], to=other_address)}), False,
         must=['not the standard deployer'])
    case('filler with another salt', chosen_manifest, reactor_bc(),
         filler_bc(tx={'transaction': dict(good['transactions'][0]['transaction'],
                                           input='0x' + '01' * 32 + good['transactions'][0]['transaction']['input'][66:])}),
         False, must=['FILLER_SALT'])
    tampered = bytearray.fromhex(good['transactions'][0]['transaction']['input'][2:])
    tampered[-1] ^= 1  # the recorded arguments name one pool manager, the init code another
    tampered_address = create2_address(CREATE2_FACTORY, FILLER_SALT, bytes(tampered[32:]))
    case('filler init code differs from its recorded arguments', chosen_manifest, reactor_bc(),
         filler_bc(tx={'contractAddress': tampered_address,
                       'transaction': dict(good['transactions'][0]['transaction'], input='0x' + tampered.hex())}),
         False, must=['not the built MercuriOrderFiller'])
    case('no validator created', chosen_manifest, reactor_bc(), filler_bc(tx={'additionalContracts': []}), False,
         must=['not exactly its MercuriOrderValidator'])
    wrong_validator = dict(good['transactions'][0]['additionalContracts'][0], address=other_address)
    case('validator elsewhere', chosen_manifest, reactor_bc(), filler_bc(tx={'additionalContracts': [wrong_validator]}),
         False, must=['is not the CREATE2 address'])
    case('filler poolManager differs', chosen_manifest, reactor_bc(),
         filler_bc(arguments=filler_args(pool_manager=other_address)), False, must=['poolManager'])
    case('commit is not the revision', chosen_manifest, reactor_bc(commit='deadbee'), filler_bc(), False,
         must=['commit deadbee'])
    case('owner is not the manifest timelock', chosen_manifest,
         reactor_bc(tx={'arguments': [base['permit2'], keeper]}), filler_bc(), False, must=['reactorFeeOwner'])
    case('filler on another reactor', chosen_manifest, reactor_bc(), filler_bc(arguments=filler_args(keeper)), False,
         must=['filler reactor'])
    case('fee differs', chosen_manifest, reactor_bc(), filler_bc(arguments=filler_args(fee=1)), False,
         must=['executionFee'])
    case('keeper still a sentinel', base, reactor_bc(), filler_bc(), False, must=['not chosen'])
    case('dry run', chosen_manifest, reactor_bc(), filler_bc(), False, must=['dry run'], dry_run=True)
    case('record exists', chosen_manifest, reactor_bc(), filler_bc(), False, must=['archive'], existing=True)
    anvil = '0x70997970C51812dc3A010C7d01b50e0d17dc79C8'
    case('rehearsal overrides', base, reactor_bc(tx={'arguments': [base['permit2'], anvil]}),
         filler_bc(arguments=filler_args(recipient=anvil)), True, extra=['--rehearsal'])
    case('rehearsal with a non-anvil owner', base, reactor_bc(tx={'arguments': [base['permit2'], keeper]}),
         filler_bc(arguments=filler_args(recipient=anvil)), False, extra=['--rehearsal'], must=['anvil'])
    previous = {'chainId': 5042002, 'reactor': reactor, 'deployBlock': 100, 'reactorFeeOwner': base['reactorFeeOwner'],
                'reactorFeeController': ZERO}
    case('replacement filler on the recorded reactor', chosen_manifest, None,
         filler_bc(receipt={'blockNumber': hex(500)}), True, previous=previous, must=['"fillerDeployBlock": 500'])
    # C-05: a pair someone else landed first. Its addresses are the ones our own broadcast would have recorded.
    own = filler_bc()['transactions'][0]
    own_filler = checksum(own['contractAddress'])
    own_validator = checksum(own['additionalContracts'][0]['address'])
    case('adopted pair', chosen_manifest, reactor_bc(), None, True, extra=['--adopted-filler-block', '150'],
         must=['"fillerAdopted": true', '"fillerDeployBlock": 150', f'"filler": "{own_filler}"',
               f'"validator": "{own_validator}"', '"reactorDeployer": "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"'],
         must_not=['"deployer"'])  # N-03: someone else sent the filler's CREATE2, so no field may say we did
    case('adopted pair on the recorded reactor', chosen_manifest, None, None, True,
         previous=dict(previous, deployer='0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266'),
         extra=['--adopted-filler-block', '600'], must=['"fillerAdopted": true', '"fillerDeployBlock": 600',
                                                        '"reactorDeployer": "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"'],
         must_not=['"deployer"'])
    case('adopted pair on a recorded adopted pair', chosen_manifest, None, None, True,
         previous={k: v for k, v in dict(previous, reactorDeployer='0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266',
                                         fillerAdopted=True).items() if k != 'deployer'},
         extra=['--adopted-filler-block', '700'],
         must=['"reactorDeployer": "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"'], must_not=['"deployer"'])
    case('adopted pair before the reactor', chosen_manifest, reactor_bc(), None, False,
         extra=['--adopted-filler-block', '99'], must=['precedes reactor block'])
    case('adopted pair and a filler broadcast', chosen_manifest, reactor_bc(), filler_bc(), False,
         extra=['--adopted-filler-block', '150'], must=['exactly one of --filler-broadcast'])
    case('adopted pair with the keeper still a sentinel', base, reactor_bc(), None, False,
         extra=['--adopted-filler-block', '150'], must=['not chosen'])
    case('adopted pair with an operator keeper outside a rehearsal', chosen_manifest, reactor_bc(), None, False,
         extra=['--adopted-filler-block', '150', '--fee-recipient', keeper], must=['rehearsal only'])
    case('rehearsal adoption', base, reactor_bc(tx={'arguments': [base['permit2'], anvil]}), None, True,
         extra=['--rehearsal', '--adopted-filler-block', '150', '--fee-recipient', anvil],
         must=['"fillerAdopted": true'])
    case('rehearsal adoption without its keeper', base, reactor_bc(tx={'arguments': [base['permit2'], anvil]}), None,
         False, extra=['--rehearsal', '--adopted-filler-block', '150'], must=['--fee-recipient'])
    with tempfile.TemporaryDirectory() as d:
        argv = [sys.executable, __file__, '--manifest', str(root / 'deployments/manifest-5042002.json'),
                '--reactor-broadcast', 'x', '--filler-broadcast', 'y', '--rehearsal', '--source-revision', revision,
                '--out-dir', str(root / 'deployments')]
        result = subprocess.run(argv, capture_output=True, text=True)
        cases.append(('rehearsal into deployments/', result.returncode != 0 and 'never goes into deployments' in
                      result.stderr, result.stderr, None))

    failed = 0
    for name, ok, text, _ in cases:
        print(f'  {"PASS" if ok else "FAIL"}  {name}')
        if not ok:
            failed += 1
            print('\n'.join('        | ' + line for line in text.splitlines()))
    print(f'write-trade-record.py self-test: {len(cases) - failed}/{len(cases)} passed')
    sys.exit(1 if failed else 0)


def main():
    parser = argparse.ArgumentParser(description='Write deployments/<chainId>.json from completed forge broadcasts.')
    parser.add_argument('--reactor-broadcast')
    parser.add_argument('--filler-broadcast')
    parser.add_argument('--previous-record', help='record whose reactor a replacement filler was deployed against')
    parser.add_argument('--manifest', default=str(root / 'deployments/manifest-5042002.json'))
    parser.add_argument('--out-dir', default=str(root / 'deployments'))
    parser.add_argument('--source-revision', help='full commit SHA; default: git HEAD of a clean tree')
    parser.add_argument('--rehearsal', action='store_true', help='loopback anvil rehearsal: anvil owner overrides')
    parser.add_argument('--adopted-filler-block', type=int,
                        help='record the pair someone else landed first, which appeared in this block (C-05)')
    parser.add_argument('--fee-recipient', help='with --rehearsal and --adopted-filler-block: the rehearsal keeper')
    parser.add_argument('--self-test', action='store_true')
    args = parser.parse_args()
    if args.self_test:
        selftest()
    if not args.filler_broadcast and args.adopted_filler_block is None:
        parser.error('--filler-broadcast or --adopted-filler-block is required')
    try:
        write(args)
    except Refused as error:
        print(f'write-trade-record.py: NOT WRITTEN: {error}', file=sys.stderr)
        sys.exit(1)


if __name__ == '__main__':
    main()
