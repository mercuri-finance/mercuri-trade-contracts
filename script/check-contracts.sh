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
forge test --fuzz-seed 0x5042
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
