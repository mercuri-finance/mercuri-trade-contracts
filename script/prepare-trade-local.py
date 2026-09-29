#!/usr/bin/env python3
"""Create ignored local testnet configuration; never edit a tracked deployment."""
import argparse
import json
from pathlib import Path
import re
root = Path(__file__).resolve().parents[1]
p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--recipient', help='explicit local app-fee recipient; omitted disables fees')
p.add_argument('--bps', type=int, default=50)
args = p.parse_args()
if not 0 <= args.bps <= 100:
    p.error('fee cap is 100 bps')
if args.recipient and (not re.fullmatch(r'0x[0-9a-fA-F]{40}', args.recipient) or int(args.recipient, 16) == 0):
    p.error('recipient must be a nonzero address')
record = json.loads((root / 'lib/mercuri-launch-contracts/deployments/5042002.json').read_text())
if record['chainId'] != 5042002:
    p.error('expected the testnet record')
record.update(universalRouter='0x4fcA4a51Ab4F23A7447b3284fBd7D73289A89Fb1',
              quoter='0x8Dc178eFB8111BB0973Dd9d722ebeFF267c98F94',
              stateView='0xF3334192D15450CdD385c8B70e03f9A6bD9E673b',
              appFeeRecipient=args.recipient or '0x' + '0' * 40,
              appFeeBps=args.bps if args.recipient else 0)
out = root / 'test-export/trade-config'
out.mkdir(parents=True, exist_ok=True)
(out / '5042002.json').write_text(json.dumps(record, indent=2) + '\n')
# A generated public configuration contract for Trade consumers; no secrets.
public = {k: record[k] for k in ('chainId', 'universalRouter', 'quoter', 'stateView', 'appFeeRecipient', 'appFeeBps')}
(out / 'trade-config.json').write_text(json.dumps(public, indent=2) + '\n')
print('Wrote ignored local testnet configuration:', out)
