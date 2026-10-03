// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {AdversarialTradeToken} from "./AdversarialTradeToken.sol";

/// @dev Local test token whose `balanceOf` and `allowance` views can lie about one holder (overstate, understate or
///      revert) while transfers keep using the real balances and allowances.
contract MisreportingTradeToken is AdversarialTradeToken {
    enum Report {
        Honest,
        Overstate,
        Understate,
        Revert
    }

    Report public report;
    address public subject;

    constructor(address trader) AdversarialTradeToken(trader) {}

    function setReport(Report report_, address subject_) external {
        report = report_;
        subject = subject_;
    }

    function balanceOf(address account) public view override returns (uint256) {
        return account == subject ? _lie(super.balanceOf(account)) : super.balanceOf(account);
    }

    function allowance(address owner, address spender) public view override returns (uint256) {
        return owner == subject ? _lie(super.allowance(owner, spender)) : super.allowance(owner, spender);
    }

    /// Spending checks the real allowance, not the reported one.
    function _spendAllowance(address owner, address spender, uint256 value) internal override {
        uint256 current = super.allowance(owner, spender);
        if (current < type(uint256).max) {
            if (current < value) revert ERC20InsufficientAllowance(spender, current, value);
            _approve(owner, spender, current - value, false);
        }
    }

    function _lie(uint256 actual) private view returns (uint256) {
        if (report == Report.Overstate) return type(uint128).max;
        if (report == Report.Understate) return 0;
        if (report == Report.Revert) revert("misreporting view");
        return actual;
    }
}
