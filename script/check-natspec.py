#!/usr/bin/env python3
"""Check compiler-emitted NatSpec for the protocol's own public ABI after forge build.

Functions, the constructor, custom errors and events are all checked.

Standard inherited ERC-20/UUPS/ownership methods use vendored documentation. Own
overrides are checked. Public-variable getters require notices; functions also
require named inputs and all outputs. This checks completeness, not semantic truth.
"""
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CONTRACTS = {
    "MercuriOrderFiller": "src/MercuriOrderFiller.sol",
    "MercuriOrderValidator": "src/MercuriOrderValidator.sol",
    "IOrderSwapRouter": "src/interfaces/IOrderSwapRouter.sol",
    "AgentAccount": "src/agents/AgentAccount.sol",
    "AgentAccountFactory": "src/agents/AgentAccountFactory.sol",
    "AgentPolicyRegistry": "src/agents/AgentPolicyRegistry.sol",
    "IAgentAccount": "src/agents/interfaces/IAgentAccount.sol",
    "IAgentAccountFactory": "src/agents/interfaces/IAgentAccountFactory.sol",
    "IAgentPolicyRegistry": "src/agents/interfaces/IAgentPolicyRegistry.sol",
}
INHERITED = {
    "UPGRADE_INTERFACE_VERSION", "acceptOwnership", "owner", "pendingOwner",
    "proxiableUUID", "transferOwnership", "upgradeToAndCall", "paused",
    "allowance", "approve", "balanceOf", "decimals", "name", "symbol",
    "totalSupply", "transfer", "transferFrom",
    # IERC1271, inherited by IAgentAccount; AgentAccount's own override is checked.
    "isValidSignature",
}


def abi_type(item):
    if item["type"].startswith("tuple"):
        return "(" + ",".join(abi_type(c) for c in item["components"]) + ")" + item["type"][5:]
    return item["type"]


failures = []
checked = 0
for contract, path in CONTRACTS.items():
    source = (ROOT / path).read_text()
    declarations = set(re.findall(r"\bfunction\s+(\w+)\s*\(", source))
    artifact = json.loads((ROOT / "out" / (contract + ".sol") / (contract + ".json")).read_text())
    metadata = artifact["metadata"]
    if isinstance(metadata, str):
        metadata = json.loads(metadata)
    user = metadata["output"]["userdoc"].get("methods", {})
    dev = metadata["output"]["devdoc"].get("methods", {})
    # Custom errors and events need a @notice too: they are what a reverted fill
    # or an indexer shows to someone reading the contract.
    # Forge's parsed `metadata` drops userdoc errors and events; the compiler's
    # own rawMetadata keeps them.
    raw_userdoc = json.loads(artifact["rawMetadata"])["output"]["userdoc"]
    for kind, section in (("error", "errors"), ("event", "events")):
        documented = raw_userdoc.get(section, {})
        for item in artifact["abi"]:
            # Library errors (SafeERC20) carry their vendored documentation.
            if item["type"] != kind or not re.search(r"\b" + kind + r"\s+" + item["name"] + r"\s*\(", source):
                continue
            signature = item["name"] + "(" + ",".join(abi_type(i) for i in item["inputs"]) + ")"
            entry = documented.get(signature, {})
            # Solidity lists error docs per overload, event docs as one object.
            notices = [e.get("notice", "") for e in entry] if isinstance(entry, list) else [entry.get("notice", "")]
            checked += 1
            if not any(n.strip() for n in notices):
                failures.append(contract + "." + signature + ": missing @notice on " + kind)
    for item in artifact["abi"]:
        kind = item["type"]
        if kind not in ("function", "constructor"):
            continue
        name = item.get("name", "constructor")
        if name in INHERITED and name not in declarations:
            continue
        signature = ("constructor" if kind == "constructor" else name) + "(" + ",".join(
            abi_type(i) for i in item["inputs"]
        ) + ")"
        # Solidity keys constructor documentation by "constructor", without parameters.
        key = "constructor" if kind == "constructor" else signature
        label = contract + "." + signature
        checked += 1
        if not user.get(key, {}).get("notice", "").strip():
            failures.append(label + ": missing @notice")
        is_getter = kind == "function" and name not in declarations
        if is_getter:
            continue
        doc = dev.get(key, {})
        for parameter in item["inputs"]:
            if parameter["name"] and not doc.get("params", {}).get(parameter["name"], "").strip():
                failures.append(label + ": missing @param " + parameter["name"])
        if len(doc.get("returns", {})) < len(item.get("outputs", [])):
            failures.append(label + ": missing @return")

for failure in failures:
    print("FAIL " + failure)
print(f"NatSpec: {checked} ABI entries checked; {len(failures)} failures")
raise SystemExit(bool(failures))
