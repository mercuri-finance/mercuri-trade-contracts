// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import {UniswapXFillerHarness} from "../integration/UniswapXFiller.t.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {SignedOrder, OrderInfo} from "../../lib/uniswapx/src/base/ReactorStructs.sol";
import {
    V3DutchOrder,
    V3DutchOrderLib,
    V3DutchInput,
    V3DutchOutput,
    NonlinearDutchDecay,
    CosignerData
} from "../../lib/uniswapx/src/lib/V3DutchOrderLib.sol";
import {IReactor} from "../../lib/uniswapx/src/interfaces/IReactor.sol";
import {ERC20 as XERC20} from "../../lib/uniswapx/lib/solmate/src/tokens/ERC20.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev Offline state export for the Go/Anvil late-cosigning test. Never broadcast. Four trader-signed, uncosigned
///      limit orders (buy and sell on a Launch pool and on a listed, hookless pool) carry the single-point expiry curve
///      and name the filler's validator with the signed condition (spec D22: version 1, limit, the order's pool, no
///      trigger), exactly as the web app submits them. The backend keeper cosigns them at fill time with Anvil's second
///      development key. The export holds the reactor, the filler and the validator the filler deployed.
///      For the pool stop capacity (spec §10 amendments, D30) it also names the Launch system the capacity reader
///      reads: the LiquidityLocker holding the Launch market's graduation position, the GraduationManager proxy
///      and its implementation, the PositionManager and the FeeManager. A decoy pool for the same Launch token
///      (the Launch hook, another tick spacing, initialised as the GraduationManager, with liquidity of its own)
///      is the pool an order could be pinned to while the locked position is another pool's: the reader must
///      refuse it (key mismatch). Its pool id sorts below the real pool's.
contract TradeLocalStateTest is UniswapXFillerHarness {
    using V3DutchOrderLib for V3DutchOrder;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    /// bytes32(uint256(keccak256("eip1967.proxy.implementation")) - 1)
    bytes32 internal constant IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    /// Anvil development account 1; the Go test signs with its public dev key.
    address internal constant LOCAL_COSIGNER = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8;
    string internal constant KEY = "anvil";

    /// Multicall3 at its canonical address with its canonical runtime, byte for byte as Arc mainnet serves it
    /// (eth_getCode at MULTICALL3 on rpc.mainnet.arc.io, read 4 Oct 2026: 3,808 bytes, keccak256
    /// MULTICALL3_CODEHASH). Etched so the keeper's batched reads take the aggregate3 path on Anvil as on Arc.
    address internal constant MULTICALL3 = 0xcA11bde05977b3631167028862bE2a173976CA11;
    bytes32 internal constant MULTICALL3_CODEHASH = 0xd5c15df687b16f2ff992fc8d767b4216323184a2bbc6ee2f9c398c318e770891;
    bytes internal constant MULTICALL3_CODE =
        hex"6080604052600436106100f35760003560e01c80634d2301cc1161008a578063a8b0574e11610059578063a8b0574e1461025a578063bce38bd714610275578063c3077fa914610288578063ee82ac5e1461029b57600080fd5b80634d2301cc146101ec57806372425d9d1461022157806382ad56cb1461023457806386d516e81461024757600080fd5b80633408e470116100c65780633408e47014610191578063399542e9146101a45780633e64a696146101c657806342cbb15c146101d957600080fd5b80630f28c97d146100f8578063174dea711461011a578063252dba421461013a57806327e86d6e1461015b575b600080fd5b34801561010457600080fd5b50425b6040519081526020015b60405180910390f35b61012d610128366004610a85565b6102ba565b6040516101119190610bbe565b61014d610148366004610a85565b6104ef565b604051610111929190610bd8565b34801561016757600080fd5b50437fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff0140610107565b34801561019d57600080fd5b5046610107565b6101b76101b2366004610c60565b610690565b60405161011193929190610cba565b3480156101d257600080fd5b5048610107565b3480156101e557600080fd5b5043610107565b3480156101f857600080fd5b50610107610207366004610ce2565b73ffffffffffffffffffffffffffffffffffffffff163190565b34801561022d57600080fd5b5044610107565b61012d610242366004610a85565b6106ab565b34801561025357600080fd5b5045610107565b34801561026657600080fd5b50604051418152602001610111565b61012d610283366004610c60565b61085a565b6101b7610296366004610a85565b610a1a565b3480156102a757600080fd5b506101076102b6366004610d18565b4090565b60606000828067ffffffffffffffff8111156102d8576102d8610d31565b60405190808252806020026020018201604052801561031e57816020015b6040805180820190915260008152606060208201528152602001906001900390816102f65790505b5092503660005b8281101561047757600085828151811061034157610341610d60565b6020026020010151905087878381811061035d5761035d610d60565b905060200281019061036f9190610d8f565b6040810135958601959093506103886020850185610ce2565b73ffffffffffffffffffffffffffffffffffffffff16816103ac6060870187610dcd565b6040516103ba929190610e32565b60006040518083038185875af1925050503d80600081146103f7576040519150601f19603f3d011682016040523d82523d6000602084013e6103fc565b606091505b50602080850191909152901515808452908501351761046d577f08c379a000000000000000000000000000000000000000000000000000000000600052602060045260176024527f4d756c746963616c6c333a2063616c6c206661696c656400000000000000000060445260846000fd5b5050600101610325565b508234146104e6576040517f08c379a000000000000000000000000000000000000000000000000000000000815260206004820152601a60248201527f4d756c746963616c6c333a2076616c7565206d69736d6174636800000000000060448201526064015b60405180910390fd5b50505092915050565b436060828067ffffffffffffffff81111561050c5761050c610d31565b60405190808252806020026020018201604052801561053f57816020015b606081526020019060019003908161052a5790505b5091503660005b8281101561068657600087878381811061056257610562610d60565b90506020028101906105749190610e42565b92506105836020840184610ce2565b73ffffffffffffffffffffffffffffffffffffffff166105a66020850185610dcd565b6040516105b4929190610e32565b6000604051808303816000865af19150503d80600081146105f1576040519150601f19603f3d011682016040523d82523d6000602084013e6105f6565b606091505b5086848151811061060957610609610d60565b602090810291909101015290508061067d576040517f08c379a000000000000000000000000000000000000000000000000000000000815260206004820152601760248201527f4d756c746963616c6c333a2063616c6c206661696c656400000000000000000060448201526064016104dd565b50600101610546565b5050509250929050565b43804060606106a086868661085a565b905093509350939050565b6060818067ffffffffffffffff8111156106c7576106c7610d31565b60405190808252806020026020018201604052801561070d57816020015b6040805180820190915260008152606060208201528152602001906001900390816106e55790505b5091503660005b828110156104e657600084828151811061073057610730610d60565b6020026020010151905086868381811061074c5761074c610d60565b905060200281019061075e9190610e76565b925061076d6020840184610ce2565b73ffffffffffffffffffffffffffffffffffffffff166107906040850185610dcd565b60405161079e929190610e32565b6000604051808303816000865af19150503d80600081146107db576040519150601f19603f3d011682016040523d82523d6000602084013e6107e0565b606091505b506020808401919091529015158083529084013517610851577f08c379a000000000000000000000000000000000000000000000000000000000600052602060045260176024527f4d756c746963616c6c333a2063616c6c206661696c656400000000000000000060445260646000fd5b50600101610714565b6060818067ffffffffffffffff81111561087657610876610d31565b6040519080825280602002602001820160405280156108bc57816020015b6040805180820190915260008152606060208201528152602001906001900390816108945790505b5091503660005b82811015610a105760008482815181106108df576108df610d60565b602002602001015190508686838181106108fb576108fb610d60565b905060200281019061090d9190610e42565b925061091c6020840184610ce2565b73ffffffffffffffffffffffffffffffffffffffff1661093f6020850185610dcd565b60405161094d929190610e32565b6000604051808303816000865af19150503d806000811461098a576040519150601f19603f3d011682016040523d82523d6000602084013e61098f565b606091505b506020830152151581528715610a07578051610a07576040517f08c379a000000000000000000000000000000000000000000000000000000000815260206004820152601760248201527f4d756c746963616c6c333a2063616c6c206661696c656400000000000000000060448201526064016104dd565b506001016108c3565b5050509392505050565b6000806060610a2b60018686610690565b919790965090945092505050565b60008083601f840112610a4b57600080fd5b50813567ffffffffffffffff811115610a6357600080fd5b6020830191508360208260051b8501011115610a7e57600080fd5b9250929050565b60008060208385031215610a9857600080fd5b823567ffffffffffffffff811115610aaf57600080fd5b610abb85828601610a39565b90969095509350505050565b6000815180845260005b81811015610aed57602081850181015186830182015201610ad1565b81811115610aff576000602083870101525b50601f017fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe0169290920160200192915050565b600082825180855260208086019550808260051b84010181860160005b84811015610bb1578583037fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe001895281518051151584528401516040858501819052610b9d81860183610ac7565b9a86019a9450505090830190600101610b4f565b5090979650505050505050565b602081526000610bd16020830184610b32565b9392505050565b600060408201848352602060408185015281855180845260608601915060608160051b870101935082870160005b82811015610c52577fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffa0888703018452610c40868351610ac7565b95509284019290840190600101610c06565b509398975050505050505050565b600080600060408486031215610c7557600080fd5b83358015158114610c8557600080fd5b9250602084013567ffffffffffffffff811115610ca157600080fd5b610cad86828701610a39565b9497909650939450505050565b838152826020820152606060408201526000610cd96060830184610b32565b95945050505050565b600060208284031215610cf457600080fd5b813573ffffffffffffffffffffffffffffffffffffffff81168114610bd157600080fd5b600060208284031215610d2a57600080fd5b5035919050565b7f4e487b7100000000000000000000000000000000000000000000000000000000600052604160045260246000fd5b7f4e487b7100000000000000000000000000000000000000000000000000000000600052603260045260246000fd5b600082357fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff81833603018112610dc357600080fd5b9190910192915050565b60008083357fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe1843603018112610e0257600080fd5b83018035915067ffffffffffffffff821115610e1d57600080fd5b602001915036819003821315610a7e57600080fd5b8183823760009101908152919050565b600082357fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffc1833603018112610dc357600080fd5b600082357fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffa1833603018112610dc357600080fdfea2646970667358221220bb2b5c71a328032f97c676ae39a1ec2148d3e5d6f73d95e9b17910152d61f16264736f6c634300080c0033";

    function setUp() public override {
        if (!vm.envOr("TRADE_EXPORT_STATE", false)) vm.skip(true);
    }

    function test_exportState() external {
        // dumpState exports accounts touched in this invocation. Deploy here
        // so constructor storage and untouched reactor/router code are included.
        super.setUp();
        vm.warp(1800000000);
        // Markets are built while USDC is the native shim, as on Arc.
        Market memory launch = _market(true, true);
        Market memory listed = _market(false, false);
        _serializeMarket("launch", launch);
        _serializeMarket("listed", listed);
        // A fresh Launch pool locks about 18,000 USDC, so its stop capacity (κ · f · Y_lock) is about 36 USDC. A
        // wallet's share is max(25% of it, the 10 USDC order minimum), so the fresh pool admits one minimum-size
        // stop-loss per wallet as it is: no trade is needed first.
        PoolKey memory decoy = _decoyPool(launch);
        vm.serializeUint(KEY, "decoyFee", decoy.fee);
        vm.serializeInt(KEY, "decoyTickSpacing", decoy.tickSpacing);
        _exportOrder("launchBuy", launch, true, 1);
        _exportOrder("launchSell", launch, false, 2);
        _exportOrder("listedBuy", listed, true, 3);
        _exportOrder("listedSell", listed, false, 4);
        // Anvil has neither Arc's native USDC precompile nor cheatcodes, so the
        // shim cannot run there. Replace it with a plain ERC-20 holding the same
        // balances for every account that moves USDC in these fills.
        address[3] memory holders = [address(poolManager), trader, appRecipient];
        uint256[3] memory balances;
        for (uint256 i; i < holders.length; ++i) {
            balances[i] = holders[i].balance / 1e12;
        }
        vm.etch(USDC, address(new MockERC20("USDC", "USDC", 6)).code);
        for (uint256 i; i < holders.length; ++i) {
            MockERC20(USDC).mint(holders[i], balances[i]);
        }
        vm.prank(trader);
        MockERC20(USDC).approve(address(permit2), type(uint256).max);
        // FeeManager checks its native balance backs every hook fee; ERC-20 USDC
        // moved by the pool no longer touches native balance, so pre-fund it.
        vm.deal(address(feeManager), address(feeManager).balance + 1_000_000e18);
        vm.etch(MULTICALL3, MULTICALL3_CODE);
        require(MULTICALL3.code.length == 3808 && MULTICALL3.codehash == MULTICALL3_CODEHASH, "multicall3 code");
        vm.serializeAddress(KEY, "multicall3", MULTICALL3);
        vm.serializeAddress(KEY, "reactor", address(reactor));
        vm.serializeAddress(KEY, "permit2", address(permit2));
        vm.serializeAddress(KEY, "filler", address(filler));
        vm.serializeAddress(KEY, "validator", address(filler.validator()));
        vm.serializeAddress(KEY, "quoter", address(quoter));
        vm.serializeAddress(KEY, "poolManager", address(poolManager));
        vm.serializeAddress(KEY, "launchHook", address(hook));
        vm.serializeAddress(KEY, "liquidityLocker", address(locker));
        vm.serializeAddress(KEY, "graduationManager", address(gm));
        vm.serializeAddress(
            KEY, "graduationManagerImpl", address(uint160(uint256(vm.load(address(gm), IMPLEMENTATION_SLOT))))
        );
        vm.serializeAddress(KEY, "positionManager", address(posm));
        vm.serializeAddress(KEY, "feeManager", address(feeManager));
        vm.serializeAddress(KEY, "cosigner", LOCAL_COSIGNER);
        vm.serializeAddress(KEY, "trader", trader);
        vm.serializeAddress(KEY, "feeRecipient", feeRecipient);
        vm.serializeUint(KEY, "executionFee", filler.executionFee());
        string memory output = vm.serializeAddress(KEY, "usdc", USDC);
        vm.createDir("test-export/trade-orders", true);
        vm.writeJson(output, "test-export/trade-orders/anvil-order.json");
        vm.dumpState("test-export/trade-orders/anvil-state.json");
    }

    /// A second pool for the Launch market's token under the Launch hook, at the market's price: only the
    /// GraduationManager may initialise a Launch-hook pool, so it is initialised as the GraduationManager (as an
    /// upgraded one could), and holds about 1,000 USDC of full-range liquidity that no locker holds. The tick
    /// spacing is the first whose pool id sorts below the real pool's, so an order for the token is pinned to it
    /// once the index lists it.
    function _decoyPool(Market memory m) internal returns (PoolKey memory k) {
        bytes32 real = PoolId.unwrap(m.key.toId());
        // A copy, not an alias of m.key.
        k = PoolKey(m.key.currency0, m.key.currency1, m.key.fee, m.key.tickSpacing, m.key.hooks);
        for (int24 ts = 1; ts < 200; ++ts) {
            k.tickSpacing = ts;
            if (ts != m.key.tickSpacing && PoolId.unwrap(k.toId()) < real) break;
        }
        require(PoolId.unwrap(k.toId()) < real, "no decoy spacing");
        (uint160 sqrtP,,,) = poolManager.getSlot0(m.key.toId());
        vm.prank(address(gm));
        poolManager.initialize(k, sqrtP);
        uint256 q96 = 1 << 96;
        uint256 usdcAmount = 1_000e6;
        uint128 liquidity =
            uint128(m.usdcIs0 ? FullMath.mulDiv(usdcAmount, sqrtP, q96) : FullMath.mulDiv(usdcAmount, q96, sqrtP));
        PoolModifyLiquidityTest lp = new PoolModifyLiquidityTest(poolManager);
        uint256 held = m.token.balanceOf(bob); // read before the prank, which the next external call consumes
        vm.prank(bob);
        m.token.transfer(address(this), held);
        m.token.approve(address(lp), type(uint256).max);
        IERC20(USDC).approve(address(lp), type(uint256).max);
        lp.modifyLiquidity(
            k,
            ModifyLiquidityParams(
                TickMath.minUsableTick(k.tickSpacing),
                TickMath.maxUsableTick(k.tickSpacing),
                int256(uint256(liquidity)),
                0
            ),
            ""
        );
    }

    function _serializeMarket(string memory name, Market memory m) internal {
        vm.serializeAddress(KEY, string.concat(name, "Token"), address(m.token));
        vm.serializeAddress(KEY, string.concat(name, "Currency0"), Currency.unwrap(m.key.currency0));
        vm.serializeAddress(KEY, string.concat(name, "Currency1"), Currency.unwrap(m.key.currency1));
        vm.serializeAddress(KEY, string.concat(name, "Hooks"), address(m.key.hooks));
        vm.serializeUint(KEY, string.concat(name, "Fee"), m.key.fee);
        vm.serializeInt(KEY, string.concat(name, "TickSpacing"), m.key.tickSpacing);
    }

    /// The signed minimum is half of today's net quote, so the keeper's raised
    /// output (the live net quote less 1%) is visibly above it.
    function _exportOrder(string memory name, Market memory m, bool buy, uint256 nonce) internal {
        bool mercuri = address(m.key.hooks) == address(hook);
        uint128 amount = buy || !mercuri ? 100e6 : 1000000e18;
        uint128 netInput = !mercuri && buy ? amount - amount * 50 / 10000 : amount;
        bytes memory data = mercuri ? abi.encode(uint256(uint160(trader))) : bytes("");
        uint256 gross = _quote(m, buy, netInput, data);
        uint256 net = !mercuri && !buy ? gross - gross * 50 / 10000 : gross;
        address input = buy ? USDC : address(m.token);
        address output = buy ? address(m.token) : USDC;
        SignedOrder memory signed = _uncosigned(input, output, amount, net / 2, nonce);
        vm.serializeBytes(KEY, string.concat(name, "Order"), signed.order);
        vm.serializeBytes(KEY, string.concat(name, "Signature"), signed.sig);
    }

    function _uncosigned(address input, address output, uint256 amount, uint256 minimum, uint256 nonce)
        internal
        view
        returns (SignedOrder memory)
    {
        NonlinearDutchDecay memory flat = NonlinearDutchDecay(0, new int256[](0));
        V3DutchOutput[] memory outputs = new V3DutchOutput[](1);
        outputs[0] = V3DutchOutput(output, minimum, _expiryCurve(), trader, minimum, 0);
        V3DutchOrder memory order;
        order.info = OrderInfo(
            IReactor(address(reactor)),
            trader,
            nonce,
            block.timestamp + 1 days,
            filler.validator(),
            _limitData(input, output) // the signed condition: a limit order on this market's pool
        );
        order.cosigner = LOCAL_COSIGNER;
        order.startingBaseFee = 0;
        order.baseInput = V3DutchInput(XERC20(input), amount, flat, amount, 0);
        order.baseOutputs = outputs;
        order.cosignerData = CosignerData(0, address(0), 0, 0, new uint256[](1));
        bytes32 h = order.hash();
        return SignedOrder(abi.encode(order), _traderSig(input, amount, nonce, order.info.deadline, h));
    }
}
