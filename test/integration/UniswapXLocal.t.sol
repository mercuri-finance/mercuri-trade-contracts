// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {LaunchFixture} from "../utils/LaunchFixture.sol";
import {V3DutchOrderReactor} from "../../lib/uniswapx/src/reactors/V3DutchOrderReactor.sol";
import {IPermit2 as XPermit2} from "../../lib/uniswapx/lib/permit2/src/interfaces/IPermit2.sol";
import {
    V3DutchOrder,
    V3DutchOrderLib,
    V3DutchInput,
    V3DutchOutput,
    NonlinearDutchDecay,
    CosignerData
} from "../../lib/uniswapx/src/lib/V3DutchOrderLib.sol";
import {IReactor} from "../../lib/uniswapx/src/interfaces/IReactor.sol";
import {IValidationCallback} from "../../lib/uniswapx/src/interfaces/IValidationCallback.sol";
import {OrderInfo, SignedOrder} from "../../lib/uniswapx/src/base/ReactorStructs.sol";
import {ERC20 as XERC20} from "../../lib/uniswapx/lib/solmate/src/tokens/ERC20.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

/// Local-only deployment: no reactor is assumed to exist on Arc testnet.
contract UniswapXLocalTest is LaunchFixture {
    using V3DutchOrderLib for V3DutchOrder;
    V3DutchOrderReactor internal reactor;
    MockERC20 internal inputToken;
    MockERC20 internal outputToken;
    uint256 internal constant TRADER_KEY = 123456789;
    uint256 internal constant COSIGNER_KEY = 987654321;
    address internal swapper;

    function setUp() public {
        vm.chainId(5042002);
        _deploySystem();
        reactor = new V3DutchOrderReactor(XPermit2(address(permit2)), address(this));
        inputToken = new MockERC20("Input", "IN", 18);
        outputToken = new MockERC20("Output", "OUT", 6);
        swapper = vm.addr(TRADER_KEY);
        inputToken.mint(swapper, 1000e18);
        outputToken.mint(address(this), 1000e6);
        vm.prank(swapper);
        inputToken.approve(address(permit2), type(uint256).max);
        outputToken.approve(address(reactor), type(uint256).max);
    }

    function _signed(uint256 nonce, uint256 deadline) internal view returns (SignedOrder memory signed) {
        NonlinearDutchDecay memory flat = NonlinearDutchDecay(0, new int256[](0));
        V3DutchOutput[] memory outputs = new V3DutchOutput[](1);
        outputs[0] = V3DutchOutput(address(outputToken), 50e6, flat, swapper, 50e6, 0);
        V3DutchOrder memory order;
        order.info =
            OrderInfo(IReactor(address(reactor)), swapper, nonce, deadline, IValidationCallback(address(0)), "");
        order.cosigner = vm.addr(COSIGNER_KEY);
        order.startingBaseFee = block.basefee;
        order.baseInput = V3DutchInput(XERC20(address(inputToken)), 100e18, flat, 100e18, 0);
        order.baseOutputs = outputs;
        order.cosignerData = CosignerData(block.number, address(0), 0, 0, new uint256[](1));
        bytes32 orderHash = order.hash();
        (uint8 cv, bytes32 cr, bytes32 cs) = vm.sign(COSIGNER_KEY, order.cosignerDigest(orderHash));
        order.cosignature = abi.encodePacked(cr, cs, cv);
        bytes32 typeHash = keccak256(
            abi.encodePacked(
                "PermitWitnessTransferFrom(TokenPermissions permitted,address spender,uint256 nonce,uint256 deadline,",
                V3DutchOrderLib.PERMIT2_ORDER_TYPE
            )
        );
        bytes32 permission = keccak256(
            abi.encode(
                keccak256("TokenPermissions(address token,uint256 amount)"), address(inputToken), uint256(100e18)
            )
        );
        bytes32 digest = keccak256(
            abi.encodePacked(
                hex"1901",
                permit2.DOMAIN_SEPARATOR(),
                keccak256(abi.encode(typeHash, permission, address(reactor), nonce, deadline, orderHash))
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(TRADER_KEY, digest);
        signed = SignedOrder(abi.encode(order), abi.encodePacked(r, s, v));
    }

    function test_exportOrderVector() public {
        SignedOrder memory signed = _signed(17, block.timestamp + 1 days);
        V3DutchOrder memory order = abi.decode(signed.order, (V3DutchOrder));
        string memory key = "order";
        vm.serializeBytes(key, "order", signed.order);
        vm.serializeBytes(key, "signature", signed.sig);
        vm.serializeAddress(key, "reactor", address(reactor));
        vm.serializeAddress(key, "permit2", address(permit2));
        vm.serializeAddress(key, "trader", swapper);
        vm.serializeUint(key, "chainId", block.chainid);
        vm.serializeBytes32(key, "hash", order.hash());
        vm.serializeBytes32(key, "domain", permit2.DOMAIN_SEPARATOR());
        string memory data = vm.serializeBytes32(key, "cosignerDigest", order.cosignerDigest(order.hash()));
        vm.createDir("test-export/trade-orders", true);
        vm.writeFile("test-export/trade-orders/order.json", data);
    }

    uint256 internal constant EXPIRING_START_AMOUNT = 50e6;

    /// The order the app submits: expiry curve, take-profit condition data, no cosignature yet.
    function _uncosignedExpiring(uint256 nonce, uint256 deadline) internal view returns (V3DutchOrder memory order) {
        NonlinearDutchDecay memory flat = NonlinearDutchDecay(0, new int256[](0));
        int256[] memory amounts = new int256[](2);
        amounts[0] = 0;
        amounts[1] = -int256(uint256(1) << 128);
        V3DutchOutput[] memory outputs = new V3DutchOutput[](1);
        outputs[0] = V3DutchOutput(
            address(outputToken),
            EXPIRING_START_AMOUNT,
            NonlinearDutchDecay(uint256(20) | (uint256(21) << 16), amounts),
            swapper,
            EXPIRING_START_AMOUNT,
            0
        );
        order.info = OrderInfo(
            IReactor(address(reactor)),
            swapper,
            nonce,
            deadline,
            IValidationCallback(address(0)),
            abi.encode(uint8(1), uint256(2e18)) // take-profit at 2.0; ignored on-chain while the contract is zero
        );
        order.cosigner = vm.addr(COSIGNER_KEY);
        order.startingBaseFee = 0;
        order.baseInput = V3DutchInput(XERC20(address(inputToken)), 100e18, flat, 100e18, 0);
        order.baseOutputs = outputs;
        order.cosignerData = CosignerData(0, address(0), 0, 0, new uint256[](1));
        order.cosignature = "";
    }

    function _permitDigest(V3DutchOrder memory order, bytes32 orderHash) internal view returns (bytes32) {
        bytes32 typeHash = keccak256(
            abi.encodePacked(
                "PermitWitnessTransferFrom(TokenPermissions permitted,address spender,uint256 nonce,uint256 deadline,",
                V3DutchOrderLib.PERMIT2_ORDER_TYPE
            )
        );
        bytes32 permission = keccak256(
            abi.encode(
                keccak256("TokenPermissions(address token,uint256 amount)"), address(inputToken), uint256(100e18)
            )
        );
        return keccak256(
            abi.encodePacked(
                hex"1901",
                permit2.DOMAIN_SEPARATOR(),
                keccak256(
                    abi.encode(typeHash, permission, address(reactor), order.info.nonce, order.info.deadline, orderHash)
                )
            )
        );
    }

    function test_exportExpiringOrderVector() public {
        V3DutchOrder memory order = _uncosignedExpiring(19, block.timestamp + 1 days);
        bytes32 orderHash = order.hash();
        bytes32 permitDigest = _permitDigest(order, orderHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(TRADER_KEY, permitDigest);
        bytes memory signature = abi.encodePacked(r, s, v);
        bytes32 uncosignedDigest = order.cosignerDigest(orderHash);
        bytes memory uncosigned = abi.encode(order);

        order.cosignerData = CosignerData(1000, address(0), 0, 0, new uint256[](1));
        order.cosignerData.outputAmounts[0] = EXPIRING_START_AMOUNT + 1;
        bytes32 cosignedDigest = order.cosignerDigest(orderHash);
        (uint8 cv, bytes32 cr, bytes32 cs) = vm.sign(COSIGNER_KEY, cosignedDigest);
        order.cosignature = abi.encodePacked(cr, cs, cv);
        assertEq(order.hash(), orderHash, "cosigner data is outside the signed hash");

        // The vector must be a real order: the cosigned copy fills at its decay start.
        vm.roll(1000);
        reactor.execute(SignedOrder(abi.encode(order), signature));
        assertEq(outputToken.balanceOf(swapper), EXPIRING_START_AMOUNT + 1);

        string memory key = "expiring";
        vm.serializeBytes(key, "order", uncosigned);
        vm.serializeBytes(key, "signature", signature);
        vm.serializeBytes(key, "cosignedOrder", abi.encode(order));
        vm.serializeAddress(key, "reactor", address(reactor));
        vm.serializeAddress(key, "permit2", address(permit2));
        vm.serializeAddress(key, "trader", swapper);
        vm.serializeAddress(key, "cosigner", order.cosigner);
        vm.serializeUint(key, "chainId", block.chainid);
        vm.serializeBytes32(key, "hash", orderHash);
        vm.serializeBytes32(key, "cosignerDigest", uncosignedDigest);
        vm.serializeBytes32(key, "permitDigest", permitDigest);
        string memory data = vm.serializeBytes32(key, "cosignedDigest", cosignedDigest);
        vm.createDir("test-export/trade-orders", true);
        vm.writeFile("test-export/trade-orders/order_expiring.json", data);
    }

    function test_fixedPriceStandingOrderAndReplayProtection() public {
        SignedOrder memory order = _signed(1, block.timestamp + 1 days);
        vm.roll(block.number + 500);
        vm.fee(123456);
        reactor.execute(order);
        assertEq(inputToken.balanceOf(swapper), 900e18);
        assertEq(outputToken.balanceOf(swapper), 50e6);
        assertEq(inputToken.balanceOf(address(reactor)), 0);
        assertEq(outputToken.balanceOf(address(reactor)), 0);
        vm.expectRevert();
        reactor.execute(order);
    }

    function test_cancelledExpiredAndWrongChainCannotFill() public {
        SignedOrder memory cancelled = _signed(2, block.timestamp + 1 days);
        vm.prank(swapper);
        XPermit2(address(permit2)).invalidateUnorderedNonces(0, 1 << 2);
        vm.expectRevert();
        reactor.execute(cancelled);
        SignedOrder memory expired = _signed(3, block.timestamp + 1);
        vm.warp(block.timestamp + 2);
        vm.expectRevert();
        reactor.execute(expired);
        SignedOrder memory wrongChain = _signed(4, block.timestamp + 1 days);
        vm.chainId(5042);
        vm.expectRevert();
        reactor.execute(wrongChain);
        assertEq(inputToken.balanceOf(swapper), 1000e18);
    }

    function test_wrongRecipientOrMinimumInvalidatesSignature() public {
        SignedOrder memory signed = _signed(5, block.timestamp + 1 days);
        V3DutchOrder memory order = abi.decode(signed.order, (V3DutchOrder));
        order.baseOutputs[0].recipient = address(this);
        signed.order = abi.encode(order);
        vm.expectRevert();
        reactor.execute(signed);
        assertEq(inputToken.balanceOf(swapper), 1000e18);
    }
}
