// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {LaunchToken} from "@mercuri/launch/LaunchToken.sol";
import {AgentFixture} from "./AgentFixture.sol";
import {DeployAgentAccounts} from "../../script/DeployAgentAccounts.s.sol";
import {TradeManifest} from "../../script/TradeManifest.sol";
import {AgentAccount} from "../../src/agents/AgentAccount.sol";
import {AgentAccountFactory} from "../../src/agents/AgentAccountFactory.sol";
import {AgentPolicyRegistry} from "../../src/agents/AgentPolicyRegistry.sol";
import {Policy, InitParams} from "../../src/agents/AgentTypes.sol";

/// @dev Exposes the deploy script's internal steps.
contract AgentDeployHarness is DeployAgentAccounts {
    function inputs(string memory manifest, string memory launchRecord, string memory tradeManifest)
        external
        view
        returns (Inputs memory)
    {
        return _inputs(manifest, launchRecord, tradeManifest);
    }

    function predict(address deployer, uint256 nonce) external pure returns (address, address, address) {
        return _predict(deployer, nonce);
    }

    function deploy(Inputs memory a) external returns (AgentAccount, AgentAccountFactory) {
        return _deploy(a);
    }

    function requireWiring(AgentAccount implementation, AgentAccountFactory factory, Inputs memory a) external view {
        _requireWiring(implementation, factory, a);
    }

    function betaCeilings() external pure returns (Policy memory) {
        return _betaCeilings();
    }
}

/// @dev The script's `run()` end to end against a manifest fixture.
contract AgentDeployRunHarness is DeployAgentAccounts {
    string internal fixture;

    constructor(string memory manifest) {
        fixture = manifest;
    }

    function _agentManifest() internal view override returns (string memory) {
        return fixture;
    }
}

/// @dev Task 7: the deployment script, run in process (never broadcast) against the Launch fixture, and the shipped
///      manifests against Launch's records, the Trade manifests and spec section 4.5.
contract DeployAgentAccountsTest is AgentFixture {
    /// @dev forge's default broadcaster: the script's CREATEs come from it in a test.
    address internal constant BROADCASTER = 0x1804c8AB1F12E6bbf3894d4083f33e07309d1f38;

    AgentDeployHarness internal h;

    function setUp() public override {
        super.setUp();
        h = new AgentDeployHarness();
    }

    function _fixtureInputs() internal view returns (DeployAgentAccounts.Inputs memory a) {
        a.launchFactory = address(factory);
        a.feeManager = address(feeManager);
        a.graduationManager = address(gm);
        a.launchHook = address(hook);
        a.poolManager = address(poolManager);
        a.universalRouter = address(router);
        a.permit2 = address(permit2);
        a.usdc = USDC;
        a.admin = agentAdmin;
        a.guardian = agentGuardian;
        a.ceilings = h.betaCeilings();
    }

    function _files(uint256 chain) internal view returns (string memory m, string memory rec, string memory trade) {
        m = vm.readFile(string.concat("deployments/agent-accounts-manifest-", vm.toString(chain), ".json"));
        rec = vm.readFile(string.concat("lib/mercuri-launch-contracts/deployments/", vm.toString(chain), ".json"));
        trade = vm.readFile(string.concat("deployments/manifest-", vm.toString(chain), ".json"));
    }

    // ---------------------------------------------------------------- in-process deployment

    /// The script lands the implementation and factory at the addresses it predicts from the broadcaster's nonce, the
    /// registry at the factory's first CREATE, everything wired as the inputs say, and the result creates working
    /// accounts.
    function test_deployLandsAtPredictionAgainstFixture() public {
        DeployAgentAccounts.Inputs memory a = _fixtureInputs();
        uint256 nonce = vm.getNonce(BROADCASTER);
        (address pImpl, address pFactory, address pRegistry) = h.predict(BROADCASTER, nonce);
        assertEq(pFactory, vm.computeCreateAddress(BROADCASTER, nonce + 1));

        uint256 g = gasleft();
        (AgentAccount impl, AgentAccountFactory f) = h.deploy(a);
        emit log_named_uint("deploy implementation + factory (+ registry) gas, incl. checks", g - gasleft());
        assertEq(address(impl), pImpl, "implementation at its prediction");
        assertEq(address(f), pFactory, "factory at its prediction");
        assertEq(f.registry(), pRegistry, "registry at its prediction");
        assertEq(impl.FACTORY(), address(f), "implementation FACTORY");
        assertEq(address(impl.REGISTRY()), pRegistry, "implementation REGISTRY");
        assertEq(AgentPolicyRegistry(pRegistry).FACTORY(), address(f), "registry FACTORY");
        assertEq(f.implementation(), address(impl));
        assertEq(f.admin(), agentAdmin);
        assertEq(f.guardian(), agentGuardian);
        assertFalse(f.guardianDisabled());
        assertEq(keccak256(abi.encode(f.ceilings())), keccak256(abi.encode(_ceilings())), "ceilings are spec 4.5");

        // The deployed pair works: an owner creates an account and its agent buys on a Launch curve.
        (LaunchToken token,) = _create(bytes32(uint256(7)));
        InitParams memory p = _defaults();
        vm.prank(accountOwner);
        g = gasleft();
        AgentAccount account = AgentAccount(payable(f.createAccount(bytes32(0), p)));
        emit log_named_uint("createAccount gas (referrer bound, first agent)", g - gasleft());
        assertTrue(f.isAccount(address(account)));
        vm.deal(address(account), 10e18);
        vm.prank(agentKey);
        assertGt(account.buy(address(token), 1e6, 1, vm.getBlockTimestamp() + 60), 0);
    }

    /// The wiring check refuses a deployment whose inputs differ from the manifest's, naming the field.
    function test_wiringMismatchRefused() public {
        DeployAgentAccounts.Inputs memory a = _fixtureInputs();
        (AgentAccount impl, AgentAccountFactory f) = h.deploy(a);
        h.requireWiring(impl, f, a);

        DeployAgentAccounts.Inputs memory b = _fixtureInputs();
        b.admin = address(0xBEEF);
        vm.expectRevert(abi.encodeWithSelector(TradeManifest.DeploymentMismatch.selector, "admin"));
        h.requireWiring(impl, f, b);

        b = _fixtureInputs();
        b.universalRouter = address(0xBEEF);
        vm.expectRevert(abi.encodeWithSelector(TradeManifest.DeploymentMismatch.selector, "UNIVERSAL_ROUTER"));
        h.requireWiring(impl, f, b);

        b = _fixtureInputs();
        b.ceilings.maxTradeUsdc -= 1;
        vm.expectRevert(abi.encodeWithSelector(TradeManifest.DeploymentMismatch.selector, "ceilings"));
        h.requireWiring(impl, f, b);

        // A factory bound to another implementation is refused.
        (AgentAccount other,) = h.deploy(a);
        vm.expectRevert(abi.encodeWithSelector(TradeManifest.DeploymentMismatch.selector, "implementation"));
        h.requireWiring(other, f, a);
    }

    // ---------------------------------------------------------------- shipped manifests

    /// Both manifests: Launch addresses from Launch's record, admin = timelock, guardian = the record's guardian,
    /// router and its pinned hash from the Trade manifest, ceilings exactly spec 4.5.
    function test_manifestsMatchRecordsAndSpec() public {
        uint256[2] memory chains = [uint256(5042002), uint256(5042)];
        for (uint256 i; i < 2; ++i) {
            vm.chainId(chains[i]);
            (string memory m, string memory rec, string memory trade) = _files(chains[i]);
            DeployAgentAccounts.Inputs memory a = h.inputs(m, rec, trade);
            assertEq(a.launchFactory, vm.parseJsonAddress(rec, ".factory"));
            assertEq(a.feeManager, vm.parseJsonAddress(rec, ".feeManager"));
            assertEq(a.graduationManager, vm.parseJsonAddress(rec, ".graduationManager"));
            assertEq(a.launchHook, vm.parseJsonAddress(rec, ".launchHook"));
            assertEq(a.poolManager, vm.parseJsonAddress(rec, ".poolManager"));
            assertEq(a.permit2, vm.parseJsonAddress(rec, ".permit2"));
            assertEq(a.usdc, USDC);
            assertEq(a.admin, vm.parseJsonAddress(rec, ".timelock"));
            assertEq(a.guardian, vm.parseJsonAddress(rec, ".guardian"));
            assertEq(a.universalRouter, vm.parseJsonAddress(trade, ".router"));
            assertEq(keccak256(abi.encode(a.ceilings)), keccak256(abi.encode(_ceilings())), "spec 4.5 ceilings");
        }
        // The network timelocks and guardians named in spec section 4.1.
        vm.chainId(5042);
        (string memory mm, string memory mrec, string memory mtrade) = _files(5042);
        DeployAgentAccounts.Inputs memory main = h.inputs(mm, mrec, mtrade);
        assertEq(main.admin, 0x94aFdf4cF8fD025E8421C936f5647a175515eb40);
        assertEq(main.guardian, 0xbcD634D133Ec05abFAB018e78138b370c4f912B0);
        vm.chainId(5042002);
        (string memory tm, string memory trec, string memory ttrade) = _files(5042002);
        DeployAgentAccounts.Inputs memory test_ = h.inputs(tm, trec, ttrade);
        assertEq(test_.admin, 0x41129B5215cA24b29a4cABcaE26d3569744DEe2E);
        assertEq(test_.guardian, 0xc914763d1652931dc3874B75387B3886aBAcF891);
    }

    /// The manifests carry inputs only: exactly these keys, no deployed address.
    function test_manifestsHoldInputsOnly() public view {
        string[13] memory keys = [
            "admin",
            "ceilings",
            "chainId",
            "feeManager",
            "graduationManager",
            "guardian",
            "launchFactory",
            "launchHook",
            "permit2",
            "poolManager",
            "routerCodeHash",
            "universalRouter",
            "usdc"
        ];
        uint256[2] memory chains = [uint256(5042002), uint256(5042)];
        for (uint256 i; i < 2; ++i) {
            (string memory m,,) = _files(chains[i]);
            string[] memory found = vm.parseJsonKeys(m, "$");
            assertEq(found.length, keys.length, "key count");
            for (uint256 k; k < keys.length; ++k) {
                assertTrue(vm.keyExistsJson(m, string.concat(".", keys[k])), keys[k]);
            }
            assertEq(vm.parseJsonKeys(m, ".ceilings").length, 11, "ceiling keys");
        }
    }

    /// A manifest that differs from Launch's record, the Trade manifest or the beta ceilings is refused by name.
    function test_tamperedManifestRefused() public {
        vm.chainId(5042002);
        (string memory m, string memory rec, string memory trade) = _files(5042002);
        _expectRefused(
            vm.replace(m, '"maxTradeUsdc": 1000000000', '"maxTradeUsdc": 1000000001'),
            rec,
            trade,
            "ceilings.maxTradeUsdc"
        );
        _expectRefused(vm.replace(m, '"maxSnipeBps": 9900', '"maxSnipeBps": 10000'), rec, trade, "ceilings.maxSnipeBps");
        _expectRefused(
            vm.replace(m, '"allowlistOnly": false', '"allowlistOnly": true'), rec, trade, "ceilings.allowlistOnly"
        );
        _expectRefused(
            vm.replace(m, vm.toString(vm.parseJsonAddress(rec, ".timelock")), vm.toString(address(0xBEEF))),
            rec,
            trade,
            ".admin"
        );
        _expectRefused(
            vm.replace(m, vm.toString(vm.parseJsonAddress(rec, ".graduationManager")), vm.toString(address(0xBEEF))),
            rec,
            trade,
            ".graduationManager"
        );
        _expectRefused(
            vm.replace(m, vm.toString(vm.parseJsonAddress(trade, ".router")), vm.toString(address(0xBEEF))),
            rec,
            trade,
            ".universalRouter"
        );
        _expectRefused(
            vm.replace(m, vm.parseJsonString(trade, ".routerCodeHash"), vm.toString(bytes32(uint256(1)))),
            rec,
            trade,
            ".routerCodeHash"
        );
        // The testnet guardian is also the testnet deployer, so replace only the guardian key's value.
        string memory g = string.concat('"guardian": "', vm.toString(vm.parseJsonAddress(rec, ".guardian")), '"');
        _expectRefused(
            vm.replace(m, g, string.concat('"guardian": "', vm.toString(address(0xBEEF)), '"')), rec, trade, ".guardian"
        );
        // Another network's manifest is refused on this chain.
        (string memory mainnet,,) = _files(5042);
        _expectRefused(mainnet, rec, trade, "chainId");
    }

    function _expectRefused(string memory m, string memory rec, string memory trade, string memory field) internal {
        vm.expectRevert(abi.encodeWithSelector(DeployAgentAccounts.AgentManifestMismatch.selector, field));
        h.inputs(m, rec, trade);
    }

    /// `run()` refuses any chain other than Arc, and on Arc refuses dependencies without code (none exist locally).
    function test_runRefusesOtherChainAndMissingCode() public {
        (string memory m,,) = _files(5042002);
        AgentDeployRunHarness script = new AgentDeployRunHarness(m);
        vm.chainId(1);
        vm.expectRevert(abi.encodeWithSelector(TradeManifest.WrongChain.selector, 1));
        script.run();

        vm.chainId(5042002);
        vm.expectRevert(
            abi.encodeWithSelector(
                TradeManifest.NoCode.selector, "launchFactory", 0x08D8CDDA59b5ce9216F7eD9B34E1F0391C80cC0E
            )
        );
        script.run();
    }
}
