#!/usr/bin/env bash
# Compile the pinned upstream router without changing Mercurifi's compiler profiles.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
forge build --root lib/universal-router contracts/UniversalRouter.sol \
  --out ../../out/trade-router --cache-path ../../cache/trade-router
