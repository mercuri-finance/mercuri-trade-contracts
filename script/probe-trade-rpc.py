#!/usr/bin/env python3
"""Bounded, read-only public Arc RPC consistency campaign. Never reads .env."""
import argparse, concurrent.futures, hashlib, json, pathlib, statistics, subprocess, time

NETWORKS = {'testnet': ('https://rpc.testnet.arc.io', 5042002), 'mainnet': ('https://rpc.mainnet.arc.io', 5042)}
ADDRESSES = ['0x4fcA4a51Ab4F23A7447b3284fBd7D73289A89Fb1', '0x8366a39CC670B4001A1121B8F6A443A643e40951', '0x8Dc178eFB8111BB0973Dd9d722ebeFF267c98F94', '0x000000000022D473030F116dDEE9F6B43aC78BA3']
ALLOWED = {'eth_chainId', 'eth_blockNumber', 'eth_getBlockByNumber', 'eth_getCode', 'eth_getLogs', 'eth_getTransactionReceipt'}

def campaign(name, seconds, interval, output):
    url, chain = NETWORKS[name]
    start = time.monotonic()
    metrics, failures, last, identities = [], [], None, None
    requests = 0
    cycles = 0
    def rpc(method, *params):
        nonlocal requests
        assert method in ALLOWED
        before = time.monotonic()
        p = subprocess.run(['cast', 'rpc', '--rpc-url', url, method, *params], capture_output=True, text=True, timeout=20)
        requests += 1
        metrics.append(time.monotonic() - before)
        if p.returncode: raise RuntimeError(method + ' transport/RPC failure')
        return json.loads(p.stdout)
    with (output / (name + '-rpc.jsonl')).open('w') as log:
        while time.monotonic() - start < seconds:
            cycle_start = time.monotonic()
            row = {'elapsed_seconds': round(cycle_start-start, 3), 'cycle': cycles}
            try:
                assert int(rpc('eth_chainId'), 16) == chain, 'wrong chain'
                head = rpc('eth_blockNumber')
                header = rpc('eth_getBlockByNumber', head, 'false')
                assert header and header['number'] == head, 'missing head'
                parent = rpc('eth_getBlockByNumber', hex(int(head,16)-1), 'false')
                assert parent and parent['hash'] == header['parentHash'], 'broken parent link'
                if last:
                    assert int(head,16) >= int(last['number'],16), 'decreasing head'
                    historical = rpc('eth_getBlockByNumber', last['number'], 'false')
                    assert historical and historical['hash'] == last['hash'], 'previous block changed'
                if cycles % 6 == 0:
                    current = []
                    for address in ADDRESSES:
                        code = rpc('eth_getCode', address, head)
                        assert len(code)>2, 'dependency code missing'
                        current.append(hashlib.sha256(bytes.fromhex(code[2:])).hexdigest())
                    if identities: assert current == identities, 'dependency runtime changed'
                    identities = current
                logs = rpc('eth_getLogs', json.dumps({'address': ADDRESSES[1], 'fromBlock': head, 'toBlock': head}))
                assert all(x['blockHash']==header['hash'] and not x.get('removed',False) for x in logs), 'log/header disagreement'
                if logs:
                    receipt = rpc('eth_getTransactionReceipt', logs[0]['transactionHash'])
                    assert receipt and receipt['blockHash']==header['hash'], 'receipt/header disagreement'
                    assert any(x['logIndex']==logs[0]['logIndex'] and x['address'].lower()==ADDRESSES[1].lower() and x['topics']==logs[0]['topics'] and x['data']==logs[0]['data'] for x in receipt['logs']), 'log absent from receipt'
                last = header
                row.update(ok=True, head=int(head,16), block_hash=header['hash'], logs=len(logs))
            except Exception as e:
                # Only fixed errors or local parser/assertion text; never log raw transport URLs.
                row.update(ok=False, error=str(e) if isinstance(e, (AssertionError,RuntimeError)) else type(e).__name__)
                failures.append(row)
            row['duration_seconds'] = round(time.monotonic()-cycle_start,3)
            log.write(json.dumps(row)+'\n'); log.flush()
            cycles += 1
            time.sleep(max(0,min(interval-(time.monotonic()-cycle_start),seconds-(time.monotonic()-start))))
    values=sorted(metrics)
    result={'network':name,'chain_id':chain,'duration_seconds':round(time.monotonic()-start,3),'cycles':cycles,'rpc_requests':requests,'failed_cycles':len(failures),'last_head':int(last['number'],16) if last else None,'latency_includes_cast_process_start':True,'rpc_p50_seconds':statistics.median(values) if values else None,'rpc_p95_seconds':values[int((len(values)-1)*.95)] if values else None,'runtime_sha256':identities,'failures':failures}
    (output/(name+'-rpc-summary.json')).write_text(json.dumps(result,indent=2)+'\n')
    return result

def main():
    p=argparse.ArgumentParser();p.add_argument('--seconds',type=int,default=1800);p.add_argument('--interval',type=int,default=10);p.add_argument('--output',type=pathlib.Path,required=True);a=p.parse_args()
    if a.seconds<1 or a.seconds>7200 or a.interval<10: p.error('duration 1..7200 seconds; interval at least 10 seconds')
    a.output.mkdir(parents=True,exist_ok=True)
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        results=list(pool.map(lambda n:campaign(n,a.seconds,a.interval,a.output),NETWORKS))
    print(json.dumps(results,indent=2))
    raise SystemExit(1 if any(r['failed_cycles'] for r in results) else 0)
if __name__=='__main__':main()
