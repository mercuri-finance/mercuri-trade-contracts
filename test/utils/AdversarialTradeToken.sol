// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// Local test token for transfer-tax and callback behaviour.
contract AdversarialTradeToken is ERC20 {
    uint256 public taxBps;
    address public callbackTarget;
    bytes public callbackData;
    bool public attempted;
    bool public callbackSucceeded;

    constructor(address trader) ERC20("Local adversarial token", "LOCAL") {
        _mint(msg.sender, 1e24);
        _mint(trader, 1e24);
    }

    function configure(uint256 tax, address target, bytes calldata data) external {
        taxBps = tax;
        callbackTarget = target;
        callbackData = data;
    }

    function _update(address from, address to, uint256 amount) internal override {
        if (callbackTarget != address(0) && !attempted) {
            attempted = true;
            (callbackSucceeded,) = callbackTarget.call(callbackData);
        }
        uint256 tax = amount * taxBps / 10000;
        if (tax > 0 && from != address(0) && to != address(0)) super._update(from, address(0), tax);
        super._update(from, to, amount - tax);
    }
}
