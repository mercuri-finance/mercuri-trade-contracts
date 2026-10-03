#!/usr/bin/env python3
"""Writes the Trade deployment record `<chainId>.json` from completed forge broadcasts. No keys, no network.

The record has the shape of Launch's deployment records (one flat JSON object, sorted keys, two-space indent, chain id
and blocks as integers) with the Trade keys: reactor, filler, executionFee, feeRecipient, reactorFeeOwner,
reactorFeeController, appRecipient, launchHook, usdc, permit2, router, deployBlock (the reactor's block, the first in
which either contract can emit), fillerDeployBlock, deployer, version and sourceRevision.

It only ever writes from a broadcast that completed: forge's `run-latest.json` (or a timestamped `run-*.json`) with no
pending transaction, exactly the one expected CREATE, a receipt with status 1 for it, the receipt's contract address
equal to the transaction's, the broadcast's chain equal to the manifest's and its commit a prefix of the source
revision. The constructor arguments recorded in the broadcast must equal the manifest. Anything else is refused and
nothing is written. A dry run (`dry-run/`, no receipts) is refused.

  python3 script/write-trade-record.py --reactor-broadcast FILE --filler-broadcast FILE [--manifest FILE]
                                       [--out-dir deployments] [--source-revision SHA]
  python3 script/write-trade-record.py --filler-broadcast FILE --previous-record FILE   # a replacement filler on
                                                                                        # the recorded reactor
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


class Refused(Exception):
    """The record was not written; the message says why."""


def is_address(text):
    return (isinstance(text, str) and len(text) == 42 and text[:2] == '0x'
            and all(c in '0123456789abcdefABCDEF' for c in text[2:]))


def same(a, b):
    return isinstance(a, str) and isinstance(b, str) and a.lower() == b.lower()


def completed_create(path, contract, chain, revision):
    """The (address, block, deployer, arguments) of the one CREATE of `contract` in a completed broadcast."""
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
    if tx.get('transactionType') != 'CREATE' or name.split('.')[0] != contract:
        raise Refused(f'{path} deploys {name or "nothing"} ({tx.get("transactionType")}), not {contract}')
    receipts = {str(r.get('transactionHash', '')).lower(): r for r in data.get('receipts') or []}
    receipt = receipts.get(str(tx.get('hash', '')).lower())
    if receipt is None:
        raise Refused(f'{path} has no receipt for {tx.get("hash")}: the broadcast did not complete')
    if receipt.get('status') not in ('0x1', 1):
        raise Refused(f'{path}: the {contract} deployment {tx.get("hash")} failed (status {receipt.get("status")})')
    address = receipt.get('contractAddress')
    if not is_address(address) or not same(address, tx.get('contractAddress')):
        raise Refused(f'{path}: receipt contract address {address} != transaction {tx.get("contractAddress")}')
    try:
        block = int(receipt['blockNumber'], 16) if isinstance(receipt['blockNumber'], str) else int(receipt['blockNumber'])
    except (KeyError, TypeError, ValueError):
        raise Refused(f'{path}: the receipt has no block number')
    deployer = (tx.get('transaction') or {}).get('from') or receipt.get('from')
    return checksum(address), block, checksum(deployer), list(tx.get('arguments') or [])


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
        reactor, block, _, reactor_args = completed_create(args.reactor_broadcast, 'V3DutchOrderReactor', chain, revision)
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
        owner, controller = previous['reactorFeeOwner'], previous['reactorFeeController']
        if not args.rehearsal and not same(owner, manifest.get('reactorFeeOwner')):
            raise Refused(f'previous record reactorFeeOwner {owner} != manifest {manifest.get("reactorFeeOwner")}')
        if not same(controller, manifest.get('reactorFeeController', ZERO)):
            raise Refused(f'previous record reactorFeeController {controller} != manifest')
    filler, filler_block, deployer, filler_args = completed_create(
        args.filler_broadcast, 'MercuriOrderFiller', chain, revision)
    if len(filler_args) != 8:
        raise Refused(f'filler constructor arguments {filler_args} are not the eight the filler takes')
    for index, key in enumerate(('router', 'permit2', 'usdc', 'launchHook', 'appRecipient'), start=1):
        if not same(filler_args[index], manifest[key]):
            raise Refused(f'filler {key} {filler_args[index]} != manifest {manifest[key]}')
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
        'reactor': checksum(reactor),
        'reactorFeeController': checksum(controller),
        'reactorFeeOwner': checksum(owner),
        'router': checksum(manifest['router']),
        'sourceRevision': revision,
        'usdc': checksum(manifest['usdc']),
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

    def broadcast(name, address, arguments, block, **override):
        tx_hash = '0x' + (('aa' if name.startswith('V3') else 'bb') * 32)
        data = {
            'transactions': [{
                'hash': tx_hash, 'transactionType': 'CREATE', 'contractName': name, 'contractAddress': address,
                'function': None, 'arguments': arguments,
                'transaction': {'from': '0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266'},
            }],
            'receipts': [{'status': '0x1', 'transactionHash': tx_hash, 'blockNumber': hex(block),
                          'contractAddress': address, 'from': '0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266'}],
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

    def filler_args(owner_reactor=reactor, recipient=keeper, fee=None):
        return [owner_reactor, base['router'], base['permit2'], base['usdc'], base['launchHook'],
                base['appRecipient'], str(base['executionFee'] if fee is None else fee), recipient]

    def filler_bc(**o):
        arguments = o.pop('arguments', filler_args())
        return broadcast('MercuriOrderFiller', filler, arguments, 101, **o)

    cases = []

    def case(name, manifest, rbc, fbc, expect_ok, extra=(), must=(), previous=None, dry_run=False, existing=False):
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
            if expect_ok:
                ok &= record is not None
            else:
                ok &= record is None
            cases.append((name, ok, text, record))

    case('complete broadcasts', chosen_manifest, reactor_bc(), filler_bc(), True,
         must=['"fillerDeployBlock": 101', '"deployBlock": 100', '"reactorFeeOwner": "0x41129B5215cA24b29a4cABcaE26d3569744DEe2E"'])
    case('pending transaction', chosen_manifest, reactor_bc(), filler_bc(pending=[{'hash': '0x01'}]), False,
         must=['pending'])
    case('no receipt', chosen_manifest, reactor_bc(receipts=[]), filler_bc(), False, must=['no receipt'])
    case('failed deployment', chosen_manifest, reactor_bc(), filler_bc(receipt={'status': '0x0'}), False,
         must=['failed'])
    case('other chain', chosen_manifest, reactor_bc(chain=5042), filler_bc(), False, must=['chain 5042'])
    case('other contract', chosen_manifest, reactor_bc(), filler_bc(tx={'contractName': 'CallbackFiller'}), False,
         must=['not MercuriOrderFiller'])
    case('receipt address differs', chosen_manifest, reactor_bc(), filler_bc(receipt={'contractAddress': reactor}),
         False, must=['receipt contract address'])
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
    parser.add_argument('--self-test', action='store_true')
    args = parser.parse_args()
    if args.self_test:
        selftest()
    if not args.filler_broadcast:
        parser.error('--filler-broadcast is required')
    try:
        write(args)
    except Refused as error:
        print(f'write-trade-record.py: NOT WRITTEN: {error}', file=sys.stderr)
        sys.exit(1)


if __name__ == '__main__':
    main()
