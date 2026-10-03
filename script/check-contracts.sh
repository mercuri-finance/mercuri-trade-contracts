#!/usr/bin/env bash
# Trade candidate checks. Local only: no .env loading, signing or broadcasting.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

if [[ $# -gt 1 || (${1:-} != "" && ${1:-} != "--stress") ]]; then
  echo 'usage: bash script/check-contracts.sh [--stress]' >&2
  exit 2
fi

python3 script/check-trade-sources.py
python3 script/check-local-source.py
bash script/build-trade-router.sh
forge fmt --check
forge build
python3 script/check-natspec.py
# Both manifests must agree with Launch's records and the reproduced router; only owner choices may be pending, and
# without --allow-pending a pending choice must be refused.
python3 script/verify-trade-filler.py --preflight --allow-pending
python3 script/verify-trade-filler.py --preflight --allow-pending --manifest deployments/manifest-5042.json
if pending=$(python3 script/verify-trade-filler.py --preflight 2>&1); then
  echo 'verify-trade-filler.py --preflight accepted a manifest with a pending owner choice' >&2
  exit 1
fi
grep -q 'owner choices still pending' <<<"$pending" || { echo "preflight failed without a pending report: $pending" >&2; exit 1; }
# Runtime identity: the verifier must accept the rebuilt filler runtime and reject one flipped immutable byte.
python3 script/verify-trade-filler.py --self-test
# Non-zero exit alone could be a crash, so require the verifier's own mismatch report as well.
if flipped=$(python3 script/verify-trade-filler.py --self-test-flipped 2>&1); then
  echo 'verify-trade-filler.py accepted a runtime with a flipped immutable byte' >&2
  exit 1
fi
grep -q 'MISMATCH at offsets' <<<"$flipped" || { echo "flipped-byte self-test failed without a mismatch report: $flipped" >&2; exit 1; }
# The execution fee and its recipient are immutables too: a flipped byte in either must be reported against its own name.
for pair in 'fee:executionFee' 'recipient:feeRecipient'; do
  if flipped=$(python3 script/verify-trade-filler.py --self-test-flipped-${pair%%:*} 2>&1); then
    echo "verify-trade-filler.py accepted a runtime with a flipped ${pair##*:} byte" >&2
    exit 1
  fi
  grep -q "MISMATCH at offsets.*inside immutables: ${pair##*:}" <<<"$flipped" || { echo "flipped ${pair##*:} self-test failed without its mismatch report: $flipped" >&2; exit 1; }
done
# The reactor's via-IR function-pointer immutable comes from a constructor simulation; a flipped pointer byte must fail.
if flipped=$(python3 script/verify-trade-filler.py --self-test-reactor-flipped 2>&1); then
  echo 'verify-trade-filler.py accepted a reactor runtime with a flipped function-pointer byte' >&2
  exit 1
fi
grep -q 'MISMATCH at offsets.*inside immutables: _getBlockNumberish' <<<"$flipped" || { echo "reactor pointer self-test failed without a pointer mismatch report: $flipped" >&2; exit 1; }
# The deployment record is written only from a completed broadcast; every incomplete or inconsistent one is refused.
python3 script/write-trade-record.py --self-test
forge test --fuzz-seed 0x5042
# The expiring-order vector is consumed by the backend and the web app. All three copies must be identical.
if [[ -n ${TRADE_VECTOR_BACKEND:-} && -n ${TRADE_VECTOR_WEBUI:-} ]]; then
  vector=test-export/trade-orders/order_expiring.json
  expected=$(shasum -a 256 "$vector" | cut -d' ' -f1)
  for copy in "$TRADE_VECTOR_BACKEND" "$TRADE_VECTOR_WEBUI"; do
    actual=$(shasum -a 256 "$copy" | cut -d' ' -f1)
    if [[ $actual != "$expected" ]]; then
      echo "order_expiring.json differs: $copy ($actual) vs $vector ($expected)" >&2
      exit 1
    fi
  done
  echo "order_expiring.json identical in contracts, backend and web app ($expected)"
else
  echo "notice: TRADE_VECTOR_BACKEND/TRADE_VECTOR_WEBUI not set; skipping order_expiring.json copy check"
fi
forge snapshot --check --match-path 'test/integration/*.t.sol' \
  --no-match-contract 'Fork' --no-match-test '^testFuzz_' --fuzz-seed 0x5042

if [[ ${1:-} == "--stress" ]]; then
  : "${ARC_LOCAL_FORK_RPC:?set ARC_LOCAL_FORK_RPC to an approved Arc RPC or local fork}"
  : "${TRADE_FORK_CHAIN_ID:?set TRADE_FORK_CHAIN_ID to 5042 or 5042002}"
  python3 script/verify-trade-router.py
  FOUNDRY_FUZZ_RUNS=10000 forge test --no-match-path 'test/invariant/*' --fuzz-seed 0x5042
  campaign_dir=$(mktemp -d -t mercuri-trade-invariant)
  echo "Invariant counterexamples, if any: $campaign_dir"
  FOUNDRY_INVARIANT_RUNS=1024 FOUNDRY_INVARIANT_DEPTH=256 \
    FOUNDRY_INVARIANT_FAIL_ON_REVERT=true \
    FOUNDRY_INVARIANT_FAILURE_PERSIST_DIR="$campaign_dir" \
    forge test --match-path 'test/invariant/*' --fuzz-seed 0x5042002
fi
