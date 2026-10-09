#!/usr/bin/env bash
# Slither over the agent account contracts, one target file at a time, for the release evidence
# (docs/agents/agent-accounts.md section 10; every result is triaged in docs/reports/2026-10-09-agent-accounts-slither.md).
#
#   bash script/run-slither.sh [output-dir]
#
# Slither is pinned to 0.11.3 (pip install slither-analyzer==0.11.3, or set SLITHER to that binary). It runs per file
# because whole-repo mode fails on this repository: several vendored dependencies declare a contract named ERC20 and
# Slither 0.11.3 stops with "Type not found contract ERC20". The two targets cover all three deployed contracts:
# AgentAccount.sol, and AgentAccountFactory.sol, which compiles AgentPolicyRegistry (its constructor deploys it).
#
# crytic-compile runs `forge clean` before building, so the analysis runs on a copy of the working tree in a temporary
# directory and never touches this checkout's out/ or cache/. No network, no RPC, no keys.
# Results in vendored dependencies (lib/) are filtered out; only src/ is triaged.
#
# The script fails when Slither's version differs, when it cannot analyse a target, or when the result counts per
# target and detector differ from the triaged baseline below: a new or vanished result must be triaged before the
# evidence can be updated.
set -euo pipefail

SLITHER_VERSION=0.11.3
root=$(cd "$(dirname "$0")/.." && pwd)
slither=${SLITHER:-slither}
out_dir=${1:-$(mktemp -d -t mercuri-slither)}
mkdir -p "$out_dir"
out_dir=$(cd "$out_dir" && pwd)

if ! command -v "$slither" > /dev/null; then
  echo "slither not found; install slither-analyzer==$SLITHER_VERSION or set SLITHER" >&2
  exit 1
fi
version=$("$slither" --version)
if [[ $version != "$SLITHER_VERSION" ]]; then
  echo "slither $version found; the evidence is pinned to $SLITHER_VERSION" >&2
  exit 1
fi

work=$(mktemp -d -t mercuri-slither-tree)
trap 'rm -rf "$work"' EXIT
rsync -a --exclude .git --exclude out --exclude cache --exclude broadcast --exclude test-export "$root"/ "$work"/

# Triaged baseline at 6a559b3 (code candidate): target|detector|count. Detector names as in Slither's JSON `check`.
expected=$(cat << 'EOF'
src/agents/AgentAccount.sol|arbitrary-send-eth|3
src/agents/AgentAccount.sol|calls-loop|3
src/agents/AgentAccount.sol|costly-loop|1
src/agents/AgentAccount.sol|cyclomatic-complexity|1
src/agents/AgentAccount.sol|incorrect-equality|2
src/agents/AgentAccount.sol|low-level-calls|1
src/agents/AgentAccount.sol|naming-convention|21
src/agents/AgentAccount.sol|redundant-statements|2
src/agents/AgentAccount.sol|reentrancy-benign|3
src/agents/AgentAccount.sol|reentrancy-no-eth|2
src/agents/AgentAccount.sol|shadowing-local|1
src/agents/AgentAccount.sol|uninitialized-local|1
src/agents/AgentAccount.sol|unused-return|9
src/agents/AgentAccountFactory.sol|calls-loop|1
src/agents/AgentAccountFactory.sol|naming-convention|23
src/agents/AgentAccountFactory.sol|reentrancy-benign|1
src/agents/AgentAccountFactory.sol|reentrancy-events|1
src/agents/AgentAccountFactory.sol|shadowing-local|1
src/agents/AgentAccountFactory.sol|timestamp|9
src/agents/AgentAccountFactory.sol|unused-return|1
EOF
)

actual=""
total=0
for target in src/agents/AgentAccount.sol src/agents/AgentAccountFactory.sol; do
  name=$(basename "$target" .sol)
  echo "== slither $target"
  # Slither exits non-zero whenever it reports results; success is judged from the JSON instead.
  (cd "$work" && "$slither" "$target" --filter-paths "lib/" --json "$out_dir/$name.json" > "$out_dir/$name.txt" 2>&1) || true
  if ! python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d.get("success") else 1)' \
    "$out_dir/$name.json" 2> /dev/null; then
    echo "slither could not analyse $target; see $out_dir/$name.txt" >&2
    exit 1
  fi
  counts=$(python3 - "$out_dir/$name.json" "$target" << 'EOF'
import collections, json, sys
results = json.load(open(sys.argv[1]))['results'].get('detectors', [])
for check, n in sorted(collections.Counter(r['check'] for r in results).items()):
    print(f'{sys.argv[2]}|{check}|{n}')
EOF
)
  n=$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["results"].get("detectors", [])))' \
    "$out_dir/$name.json")
  echo "$target: $n results"
  total=$((total + n))
  actual+="$counts"$'\n'
done
actual=$(printf '%s' "$actual" | sed '/^$/d' | sort)

echo "Slither $SLITHER_VERSION: $total results; text and JSON in $out_dir"
if [[ $actual != "$(printf '%s\n' "$expected" | sort)" ]]; then
  echo "results differ from the triaged baseline (expected vs actual):" >&2
  diff <(printf '%s\n' "$expected" | sort) <(printf '%s\n' "$actual") >&2 || true
  exit 1
fi
echo "every result matches the triaged baseline (docs/reports/2026-10-09-agent-accounts-slither.md)"
