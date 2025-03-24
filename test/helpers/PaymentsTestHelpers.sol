// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Payments} from "../../src/Payments.sol";
import {ERC1967Proxy} from "../../src/ERC1967Proxy.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {ReentrantERC20} from "../mocks/ReentrantERC20.sol";

contract PaymentsTestHelpers is Test {
    function deployPaymentsSystem(address owner) public returns (Payments) {
        vm.startPrank(owner);
        Payments paymentsImplementation = new Payments();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(paymentsImplementation),
            abi.encodeWithSelector(Payments.initialize.selector)
        );
        Payments payments = Payments(address(proxy));
        vm.stopPrank();

        return payments;
    }

    function setupTestToken(
        string memory name,
        string memory symbol,
        address[] memory users,
        uint256 initialBalance,
        address paymentsContract
    ) public returns (MockERC20) {
        MockERC20 token = new MockERC20(name, symbol);

        // Mint tokens to users
        for (uint256 i = 0; i < users.length; i++) {
            token.mint(users[i], initialBalance);

            // Approve payments contract to spend tokens (i.e. allowance)
            vm.startPrank(users[i]);
            token.approve(paymentsContract, type(uint256).max);
            vm.stopPrank();
        }

        return token;
    }

    // Helper to deploy a malicious token for reentrancy testing
    function setupReentrantToken(
        string memory name,
        string memory symbol,
        address[] memory users,
        uint256 initialBalance,
        address paymentsContract
    ) public returns (ReentrantERC20) {
        ReentrantERC20 token = new ReentrantERC20(name, symbol);

        // Mint tokens to users
        for (uint256 i = 0; i < users.length; i++) {
            token.mint(users[i], initialBalance);

            // Approve payments contract to spend tokens
            vm.startPrank(users[i]);
            token.approve(paymentsContract, type(uint256).max);
            vm.stopPrank();
        }

        return token;
    }

    function getAccountData(
        Payments payments,
        address token,
        address user
    ) public view returns (Payments.Account memory) {
        (
            uint256 funds,
            uint256 lockupCurrent,
            uint256 lockupRate,
            uint256 lockupLastSettledAt
        ) = payments.accounts(token, user);

        return
            Payments.Account({
                funds: funds,
                lockupCurrent: lockupCurrent,
                lockupRate: lockupRate,
                lockupLastSettledAt: lockupLastSettledAt
            });
    }

    function makeDeposit(
        Payments payments,
        address token,
        address from,
        address to,
        uint256 amount
    ) public {
        vm.startPrank(from);
        payments.deposit(token, to, amount);
        vm.stopPrank();
    }

    function makeWithdrawal(
        Payments payments,
        address token,
        address from,
        uint256 amount
    ) public {
        vm.startPrank(from);
        payments.withdraw(token, amount);
        vm.stopPrank();
    }

    function expectWithdrawalToFail(
        Payments payments,
        address token,
        address from,
        uint256 amount,
        bytes memory expectedError
    ) public {
        vm.startPrank(from);
        vm.expectRevert(expectedError);
        payments.withdraw(token, amount);
        vm.stopPrank();
    }

    function makeWithdrawalTo(
        Payments payments,
        address token,
        address from,
        address to,
        uint256 amount
    ) public {
        vm.startPrank(from);
        payments.withdrawTo(token, to, amount);
        vm.stopPrank();
    }

    function createRail(
        Payments payments,
        address token,
        address from,
        address to,
        address railOperator,
        address arbiter
    ) public returns (uint256) {
        vm.startPrank(railOperator);
        uint256 railId = payments.createRail(token, from, to, arbiter);
        vm.stopPrank();
        return railId;
    }

    function setupRailWithParameters(
        Payments payments,
        address token,
        address from,
        address to,
        address railOperator,
        uint256 paymentRate,
        uint256 lockupPeriod,
        uint256 lockupFixed
    ) public returns (uint256) {
        uint256 railId = createRail(
            payments,
            token,
            from,
            to,
            railOperator,
            address(0)
        );

        // Set payment rate
        vm.startPrank(railOperator);
        payments.modifyRailPayment(railId, paymentRate, 0);

        // Set lockup parameters
        payments.modifyRailLockup(railId, lockupPeriod, lockupFixed);
        vm.stopPrank();

        return railId;
    }

    function setupOperatorApproval(
        Payments payments,
        address token,
        address from,
        address operator,
        uint256 rateAllowance,
        uint256 lockupAllowance
    ) public {
        vm.startPrank(from);
        payments.setOperatorApproval(
            token,
            operator,
            true,
            rateAllowance,
            lockupAllowance
        );
        vm.stopPrank();
    }

    function advanceBlocks(uint256 blocks) public {
        vm.roll(block.number + blocks);
    }

    function assertAccountState(
        Payments payments,
        address token,
        address user,
        uint256 expectedFunds,
        uint256 expectedLockup,
        uint256 expectedRate,
        uint256 expectedLastSettled
    ) public view {
        Payments.Account memory account = getAccountData(payments, token, user);
        assertEq(account.funds, expectedFunds, "Account funds incorrect");
        assertEq(
            account.lockupCurrent,
            expectedLockup,
            "Account lockup incorrect"
        );
        assertEq(
            account.lockupRate,
            expectedRate,
            "Account lockup rate incorrect"
        );
        assertEq(
            account.lockupLastSettledAt,
            expectedLastSettled,
            "Account last settled at incorrect"
        );
    }
}
