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
        uint256 lockupAllowance,
        uint256 maxLockupPeriod
    ) public {
        vm.startPrank(from);
        payments.setOperatorApproval(
            token,
            operator,
            true,
            rateAllowance,
            lockupAllowance,
            maxLockupPeriod
        );
        vm.stopPrank();
    }
    
    // Overloaded method for backward compatibility with tests that don't specify maxLockupPeriod
    function setupOperatorApproval(
        Payments payments,
        address token,
        address from,
        address operator,
        uint256 rateAllowance,
        uint256 lockupAllowance
    ) public {
        // Use a very large default max lockup period to avoid affecting existing tests
        setupOperatorApproval(
            payments,
            token,
            from,
            operator,
            rateAllowance,
            lockupAllowance,
            type(uint256).max
        );
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

    function verifyOperatorAllowances(
        Payments payments,
        address token,
        address client,
        address operator,
        bool expectedIsApproved,
        uint256 expectedRateAllowance,
        uint256 expectedLockupAllowance,
        uint256 expectedMaxLockupPeriod,
        uint256 expectedRateUsage,
        uint256 expectedLockupUsage
    ) public view {
        (
            bool isApproved,
            uint256 rateAllowance,
            uint256 lockupAllowance,
            uint256 maxLockupPeriod,
            uint256 rateUsage,
            uint256 lockupUsage
        ) = payments.operatorApprovals(token, client, operator);

        assertEq(
            isApproved,
            expectedIsApproved,
            "Operator approval status mismatch"
        );
        assertEq(
            rateAllowance,
            expectedRateAllowance,
            "Rate allowance mismatch"
        );
        assertEq(
            lockupAllowance,
            expectedLockupAllowance,
            "Lockup allowance mismatch"
        );
        assertEq(
            maxLockupPeriod,
            expectedMaxLockupPeriod,
            "Max lockup period mismatch"
        );
        assertEq(rateUsage, expectedRateUsage, "Rate usage mismatch");
        assertEq(lockupUsage, expectedLockupUsage, "Lockup usage mismatch");
    }
    
    // Overloaded method for backward compatibility with tests that don't specify maxLockupPeriod
    function verifyOperatorAllowances(
        Payments payments,
        address token,
        address client,
        address operator,
        bool expectedIsApproved,
        uint256 expectedRateAllowance,
        uint256 expectedLockupAllowance,
        uint256 expectedRateUsage,
        uint256 expectedLockupUsage
    ) public view {
        (
            bool isApproved,
            uint256 rateAllowance,
            uint256 lockupAllowance,
            uint256 maxLockupPeriod,
            uint256 rateUsage,
            uint256 lockupUsage
        ) = payments.operatorApprovals(token, client, operator);

        assertEq(
            isApproved,
            expectedIsApproved,
            "Operator approval status mismatch"
        );
        assertEq(
            rateAllowance,
            expectedRateAllowance,
            "Rate allowance mismatch"
        );
        assertEq(
            lockupAllowance,
            expectedLockupAllowance,
            "Lockup allowance mismatch"
        );
        // Don't verify maxLockupPeriod in this overload
        assertEq(rateUsage, expectedRateUsage, "Rate usage mismatch");
        assertEq(lockupUsage, expectedLockupUsage, "Lockup usage mismatch");
    }

    // Setup a rail with specific parameters and return balances
    function setupRailWithFixedLockup(
        Payments payments,
        address token,
        address client,
        address recipient,
        address operator,
        uint256 paymentRate,
        uint256 fixedLockup,
        uint256 lockupPeriod
    )
        public
        returns (
            uint256 railId,
            Payments.Account memory clientBefore,
            Payments.Account memory recipientBefore
        )
    {
        // Create rail
        railId = createRail(
            payments,
            token,
            client,
            recipient,
            operator,
            address(0)
        );

        // Set payment rate and fixed lockup
        vm.startPrank(operator);
        payments.modifyRailPayment(railId, paymentRate, 0);
        payments.modifyRailLockup(railId, lockupPeriod, fixedLockup);
        vm.stopPrank();

        // Get account states before any payment
        clientBefore = getAccountData(payments, token, client);
        recipientBefore = getAccountData(payments, token, recipient);

        return (railId, clientBefore, recipientBefore);
    }

    // Verify one-time payment effects
    function verifyOneTimePayment(
        Payments payments,
        uint256 railId,
        uint256 paymentAmount,
        address token,
        address client,
        address recipient,
        address operator,
        Payments.Account memory clientBefore,
        Payments.Account memory recipientBefore,
        uint256 expectedRemainingLockup
    ) public {
        // Make the payment
        vm.startPrank(operator);
        payments.modifyRailPayment(railId, 0, paymentAmount);
        vm.stopPrank();

        // Check account balances after payment
        Payments.Account memory clientAfter = getAccountData(
            payments,
            token,
            client
        );
        Payments.Account memory recipientAfter = getAccountData(
            payments,
            token,
            recipient
        );

        // Verify funds transferred correctly
        assertEq(
            clientAfter.funds,
            clientBefore.funds - paymentAmount,
            "Client balance incorrect"
        );
        assertEq(
            recipientAfter.funds,
            recipientBefore.funds + paymentAmount,
            "Recipient balance incorrect"
        );

        // Verify remaining fixed lockup
        Payments.RailView memory rail = payments.getRail(railId);
        assertEq(
            rail.lockupFixed,
            expectedRemainingLockup,
            "Fixed lockup not updated correctly"
        );
    }

    // Get current operator allowance and usage
    function getOperatorAllowanceAndUsage(
        Payments payments,
        address token,
        address client,
        address operator
    )
        public
        view
        returns (
            bool isApproved,
            uint256 rateAllowance,
            uint256 lockupAllowance,
            uint256 maxLockupPeriod,
            uint256 rateUsage,
            uint256 lockupUsage
        )
    {
        return payments.operatorApprovals(token, client, operator);
    }

    // Execute one-time payment and verify
    function executeOneTimePayment(
        Payments payments,
        uint256 railId,
        address operator,
        uint256 oneTimeAmount
    ) public {
        Payments.RailView memory railBefore = payments.getRail(railId);
        address token = railBefore.token;
        address client = railBefore.from;
        address recipient = railBefore.to;

        // Get initial balances
        Payments.Account memory clientBefore = getAccountData(
            payments,
            token,
            client
        );
        Payments.Account memory recipientBefore = getAccountData(
            payments,
            token,
            recipient
        );

        // Make one-time payment
        vm.startPrank(operator);
        payments.modifyRailPayment(
            railId,
            railBefore.paymentRate,
            oneTimeAmount
        );
        vm.stopPrank();

        // Verify balance changes
        Payments.Account memory clientAfter = getAccountData(
            payments,
            token,
            client
        );
        Payments.Account memory recipientAfter = getAccountData(
            payments,
            token,
            recipient
        );

        assertEq(
            clientAfter.funds,
            clientBefore.funds - oneTimeAmount,
            "Client funds not reduced correctly after one-time payment"
        );

        assertEq(
            recipientAfter.funds,
            recipientBefore.funds + oneTimeAmount,
            "Recipient funds not increased correctly after one-time payment"
        );

        // Verify fixed lockup was reduced
        Payments.RailView memory railAfter = payments.getRail(railId);
        assertEq(
            railAfter.lockupFixed,
            railBefore.lockupFixed - oneTimeAmount,
            "Fixed lockup not reduced by one-time payment amount"
        );

        // Verify account lockup is also reduced
        assertEq(
            clientAfter.lockupCurrent,
            clientBefore.lockupCurrent - oneTimeAmount,
            "Client lockup not reduced correctly after one-time payment"
        );
    }
}
