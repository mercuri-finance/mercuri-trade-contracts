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
# Every check below reads out/. Start from an empty one so no artifact the current configuration no longer builds (a
# profile-suffixed reactor from an earlier two-profile build, say) can satisfy a check (fix re-audit N-01).
forge clean
bash script/build-trade-router.sh
forge fmt --check
forge build
python3 script/check-natspec.py
# Both manifests must agree with Launch's records and the reproduced router; only owner choices may be pending, and
# without --allow-pending a pending choice must be refused. Both shipped manifests have every owner choice made, so
# each must pass without --allow-pending; a copy of the testnet manifest with the keeper sentinel put back and a copy
# of the mainnet manifest with the fee sentinel put back must each be refused with a pending report.
python3 script/verify-trade-filler.py --preflight
python3 script/verify-trade-filler.py --preflight --manifest deployments/manifest-5042.json
pending_dir=$(mktemp -d)
trap 'rm -rf "$pending_dir"' EXIT
python3 -c 'import json, sys; m = json.load(open(sys.argv[1])); m["feeRecipient"] = "REQUIRED_AT_D3_OWNER_GO"; json.dump(m, open(sys.argv[2], "w"))' \
  deployments/manifest-5042002.json "$pending_dir/manifest-5042002.json"
python3 -c 'import json, sys; m = json.load(open(sys.argv[1])); m["executionFee"] = "REQUIRED_AT_MAINNET_OWNER_GO"; json.dump(m, open(sys.argv[2], "w"))' \
  deployments/manifest-5042.json "$pending_dir/manifest-5042.json"
for manifest in "$pending_dir/manifest-5042002.json" "$pending_dir/manifest-5042.json"; do
  if pending=$(python3 script/verify-trade-filler.py --preflight --manifest "$manifest" 2>&1); then
    echo "verify-trade-filler.py --preflight accepted $manifest with a pending owner choice" >&2
    exit 1
  fi
  grep -q 'owner choices still pending' <<<"$pending" || { echo "preflight failed without a pending report: $pending" >&2; exit 1; }
done
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
# The filler and its validator name each other (spec D22): a flipped byte in the filler's `validator` or in the
# validator's `filler` or `poolManager` must be reported against its own name.
for pair in 'flipped-validator:validator' 'validator-flipped-filler:filler' 'validator-flipped-pool-manager:poolManager'; do
  if flipped=$(python3 script/verify-trade-filler.py --self-test-${pair%%:*} 2>&1); then
    echo "verify-trade-filler.py accepted a runtime with a flipped ${pair##*:} byte (${pair%%:*})" >&2
    exit 1
  fi
  grep -q "MISMATCH at offsets.*inside immutables: ${pair##*:}" <<<"$flipped" || { echo "${pair%%:*} self-test failed without its mismatch report: $flipped" >&2; exit 1; }
done
# The reactor's via-IR function-pointer immutable comes from a constructor simulation; a flipped pointer byte must fail.
if flipped=$(python3 script/verify-trade-filler.py --self-test-reactor-flipped 2>&1); then
  echo 'verify-trade-filler.py accepted a reactor runtime with a flipped function-pointer byte' >&2
  exit 1
fi
grep -q 'MISMATCH at offsets.*inside immutables: _getBlockNumberish' <<<"$flipped" || { echo "reactor pointer self-test failed without a pointer mismatch report: $flipped" >&2; exit 1; }
# The deployment record is written only from a completed broadcast; every incomplete or inconsistent one is refused.
python3 script/write-trade-record.py --self-test
# The agent accounts record likewise: only from a completed DeployAgentAccounts broadcast, never overwritten.
python3 script/write-agent-accounts-record.py --self-test
# Agent accounts (spec of 9 Oct 2026). Both manifests must agree with Launch's records, the Trade router pin and the
# spec 4.5 beta ceilings, and a copy of the mainnet manifest with one ceiling raised must be refused.
python3 script/verify-agent-accounts.py --preflight
python3 script/verify-agent-accounts.py --preflight --manifest deployments/agent-accounts-manifest-5042.json
python3 -c 'import json, sys; m = json.load(open(sys.argv[1])); m["ceilings"]["maxTradeUsdc"] += 1; json.dump(m, open(sys.argv[2], "w"))' \
  deployments/agent-accounts-manifest-5042.json "$pending_dir/agent-accounts-manifest-5042.json"
if raised=$(python3 script/verify-agent-accounts.py --preflight --manifest "$pending_dir/agent-accounts-manifest-5042.json" 2>&1); then
  echo 'verify-agent-accounts.py --preflight accepted a manifest with a ceiling above spec 4.5' >&2
  exit 1
fi
grep -q 'ceilings.maxTradeUsdc .* != spec 4.5 beta ceiling' <<<"$raised" || { echo "raised-ceiling preflight failed without its report: $raised" >&2; exit 1; }
# Runtime identity: the verifier must accept the rebuilt implementation, factory and registry runtimes with every
# immutable substituted and reject a flipped byte in each immutable by name (the full sweep runs in --self-test; the
# pairs below are re-run here so the gate itself sees each contract's mismatch report).
python3 script/verify-agent-accounts.py --self-test
for pair in 'account:FACTORY' 'account:REGISTRY' 'account:LAUNCH_FACTORY' 'account:UNIVERSAL_ROUTER' \
  'factory:implementation' 'factory:registry' 'factory:admin' 'factory:guardianDisabled' 'factory:C_MAX_TRADE_USDC' \
  'registry:FACTORY'; do
  if flipped=$(python3 script/verify-agent-accounts.py --self-test-flipped "$pair" 2>&1); then
    echo "verify-agent-accounts.py accepted a runtime with a flipped ${pair#*:} byte (${pair%%:*})" >&2
    exit 1
  fi
  grep -q "MISMATCH at offsets.*inside immutables: ${pair#*:})" <<<"$flipped" || { echo "${pair} self-test failed without its mismatch report: $flipped" >&2; exit 1; }
done
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
# Agent account gas: deterministic agent tests, in their own snapshot so the order suite's baseline is untouched.
forge snapshot --check .gas-snapshot-agents --match-path 'test/agents/*.t.sol' \
  --no-match-contract 'Fork|Invariant' --no-match-test '^testFuzz_' --fuzz-seed 0x5042
# Slither over the agent contracts: offline, about 15 s, on a temporary copy of the tree. It runs when Slither 0.11.3
# is installed (or SLITHER names it) and then every result must match the triaged baseline; otherwise a notice only,
# since Slither is a Python tool outside the repo. The release evidence always records a full run of the script.
slither_bin=${SLITHER:-slither}
if command -v "$slither_bin" > /dev/null && [[ $("$slither_bin" --version 2> /dev/null) == 0.11.3 ]]; then
  SLITHER="$slither_bin" bash script/run-slither.sh
else
  echo "notice: Slither 0.11.3 not installed (set SLITHER to it); skipping the agent Slither baseline check"
fi

if [[ ${1:-} == "--stress" ]]; then
  : "${ARC_LOCAL_FORK_RPC:?set ARC_LOCAL_FORK_RPC to an approved Arc RPC or local fork}"
  : "${TRADE_FORK_CHAIN_ID:?set TRADE_FORK_CHAIN_ID to 5042 or 5042002}"
  python3 script/verify-trade-router.py
  # Every invariant suite runs in a deep campaign below, so the 10,000-run fuzz step leaves them out.
  FOUNDRY_FUZZ_RUNS=10000 forge test --no-match-path 'test/invariant/*' --no-match-contract 'AgentInvariantsTest' \
    --fuzz-seed 0x5042
  campaign_dir=$(mktemp -d -t mercuri-trade-invariant)
  echo "Invariant counterexamples, if any: $campaign_dir"
  FOUNDRY_INVARIANT_RUNS=1024 FOUNDRY_INVARIANT_DEPTH=256 \
    FOUNDRY_INVARIANT_FAIL_ON_REVERT=true \
    FOUNDRY_INVARIANT_FAILURE_PERSIST_DIR="$campaign_dir" \
    forge test --match-path 'test/invariant/*' --fuzz-seed 0x5042002
  # Agent account invariants (spec section 5), same depth, their own counterexample directory.
  agent_campaign_dir=$(mktemp -d -t mercuri-agent-invariant)
  echo "Agent invariant counterexamples, if any: $agent_campaign_dir"
  FOUNDRY_INVARIANT_RUNS=1024 FOUNDRY_INVARIANT_DEPTH=256 \
    FOUNDRY_INVARIANT_FAIL_ON_REVERT=true \
    FOUNDRY_INVARIANT_FAILURE_PERSIST_DIR="$agent_campaign_dir" \
    forge test --match-path 'test/agents/AgentInvariants.t.sol' --match-contract 'AgentInvariantsTest' \
    --fuzz-seed 0x5042002
fi
