// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Payments} from "../src/Payments.sol";
import {ERC1967Proxy} from "../src/ERC1967Proxy.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {PaymentsTestHelpers} from "./helpers/PaymentsTestHelpers.sol";

contract AccountLockupSettlementTest is Test {
    Payments payments;
    MockERC20 token;
    PaymentsTestHelpers helper;

    address owner = address(0x1);
    address user1 = address(0x2);
    address user2 = address(0x3);
    address operator = address(0x4);

    uint256 constant INITIAL_BALANCE = 1000 ether;
    uint256 constant DEPOSIT_AMOUNT = 100 ether;

    function setUp() public {
        helper = new PaymentsTestHelpers();
        payments = helper.deployPaymentsSystem(owner);

        // Set up users for the token
        address[] memory users = new address[](2);
        users[0] = user1;
        users[1] = user2;

        // Deploy test token with initial balances and approvals
        token = helper.setupTestToken(
            "Test Token",
            "TEST",
            users,
            INITIAL_BALANCE,
            address(payments)
        );

        // Setup operator approval for potential rails
        helper.setupOperatorApproval(
            payments,
            address(token),
            user1,
            operator,
            10 ether, // rateAllowance
            100 ether, // lockupAllowance
            100 // max lockup period
        );
    }

    function testSettlementWithNoLockupRate() public {
        // Setup: deposit funds
        helper.makeDeposit(
            payments,
            address(token),
            user1,
            user1,
            DEPOSIT_AMOUNT
        );

        // No rails created, so lockup rate should be 0

        // Advance blocks to create a settlement gap without a rate
        helper.advanceBlocks(10);

        // Trigger settlement with a new deposit
        helper.makeDeposit(
            payments,
            address(token),
            user1,
            user1,
            DEPOSIT_AMOUNT
        );

        // Verify settlement occurred
        Payments.Account memory account = helper.getAccountData(
            payments,
            address(token),
            user1
        );
        assertEq(
            account.lockupLastSettledAt,
            block.number,
            "Lockup last settled at should be updated"
        );
        assertEq(
            account.lockupCurrent,
            0,
            "Lockup current should remain zero without a rate"
        );
        assertEq(
            account.funds,
            DEPOSIT_AMOUNT * 2,
            "Funds should match total deposits"
        );
    }

    function testSimpleLockupAccumulation() public {
        // Setup: deposit funds
        helper.makeDeposit(
            payments,
            address(token),
            user1,
            user1,
            DEPOSIT_AMOUNT
        );

        // Define a lockup rate
        uint256 lockupRate = 2 ether;
        uint256 lockupPeriod = 2;

        // Create a rail with this rate
        vm.startPrank(user1);
        payments.setOperatorApproval(
            address(token),
            operator,
            true,
            lockupRate, // rate allowance
            100 ether, // lockupAllowance
            100 // max lockup period
        );
        vm.stopPrank();

        // Create rail with the desired rate
        helper.setupRailWithParameters(
            payments,
            address(token),
            user1,
            user2,
            operator,
            lockupRate, // payment rate
            lockupPeriod, // lockup period
            0 // no fixed lockup
        );

        // Note: Settlement begins at the current block

        // Advance blocks to create a settlement gap
        uint256 elapsedBlocks = 5;
        helper.advanceBlocks(elapsedBlocks);

        // Trigger settlement with a new deposit
        helper.makeDeposit(
            payments,
            address(token),
            user1,
            user1,
            DEPOSIT_AMOUNT
        );

        // Verify settlement occurred
        Payments.Account memory account = helper.getAccountData(
            payments,
            address(token),
            user1
        );
        assertEq(
            account.lockupLastSettledAt,
            block.number,
            "Lockup last settled at should be updated"
        );

        // The correct expected value is:
        uint256 initialLockup = lockupRate * lockupPeriod;
        uint256 accumulatedLockup = lockupRate * elapsedBlocks;
        uint256 expectedLockup = initialLockup + accumulatedLockup;

        // The account has both initial lockup from rail creation and accumulated lockup from settlement
        assertEq(
            account.lockupCurrent,
            expectedLockup,
            "Lockup current should match expected value"
        );
        assertEq(
            account.lockupRate,
            lockupRate,
            "Lockup rate should match rail rate"
        );

        // Also verify the account funds match the sum of the deposits
        assertEq(
            account.funds,
            DEPOSIT_AMOUNT * 2,
            "Account funds should match total deposits"
        );
    }

    function testPartialSettlement() public {
        uint256 lockupRate = 20 ether;

        helper.makeDeposit(
            payments,
            address(token),
            user1,
            user1,
            DEPOSIT_AMOUNT / 2 // 50
        );

        // Create a rail with this high rate
        vm.startPrank(user1);
        payments.setOperatorApproval(
            address(token),
            operator,
            true,
            lockupRate, // Higher rate allowance
            100000 ether, // lockupAllowance
            100 // max lockup period
        );
        vm.stopPrank();

        // Create rail with the high rate (this will set the railway's settledUpTo to the current block)
        helper.setupRailWithParameters(
            payments,
            address(token),
            user1,
            user2,
            operator,
            lockupRate, // Very high payment rate (20 ether per block)
            1, // lockup period
            0 // no fixed lockup
        );

        // When a rail is created, its settledUpTo is set to the current block
        // Initial account lockup value should be lockupRate * lockupPeriod = 20 ether * 1 = 20 ether
        // Initial funds are DEPOSIT_AMOUNT / 2 = 50 ether

        // Advance many blocks to exceed available funds
        uint256 advancedBlocks = 10;
        helper.advanceBlocks(advancedBlocks);

        // Deposit additional funds, which will trigger settlement
        helper.makeDeposit(
            payments,
            address(token),
            user1,
            user1,
            DEPOSIT_AMOUNT / 2
        );

        // Verify partial settlement
        Payments.Account memory account = helper.getAccountData(
            payments,
            address(token),
            user1
        );

        uint256 expectedSettlementBlock = 5; // lockupRate is 20, so we only have enough funds to pay for 5 epochs)

        assertEq(
            account.lockupLastSettledAt,
            expectedSettlementBlock,
            "Account should be settled to the correct block number"
        );

        uint256 expectedLockup = DEPOSIT_AMOUNT;

        assertEq(
            account.lockupCurrent,
            expectedLockup,
            "Lockup current should equal total deposits"
        );

        assertEq(
            account.funds,
            DEPOSIT_AMOUNT,
            "Funds should match total deposits"
        );
    }

    function testSettlementAfterGap() public {
        helper.makeDeposit(
            payments,
            address(token),
            user1,
            user1,
            DEPOSIT_AMOUNT * 2 // 200 ether
        );

        uint256 lockupRate = 1 ether; // 1 token per block
        uint256 lockupPeriod = 30;
        uint256 initialLockup = 10 ether;

        // Create rail
        helper.setupRailWithParameters(
            payments,
            address(token),
            user1,
            user2,
            operator,
            lockupRate, // 1 token per block
            lockupPeriod, // Lockup period of 30 blocks
            initialLockup // initial fixed lockup of 10 ether
        );

        // Roll forward many blocks
        helper.advanceBlocks(30);

        // Trigger settlement with a new deposit
        helper.makeDeposit(
            payments,
            address(token),
            user1,
            user1,
            DEPOSIT_AMOUNT
        );

        // Verify settlement occurred
        Payments.Account memory account = helper.getAccountData(
            payments,
            address(token),
            user1
        );

        assertEq(
            account.lockupLastSettledAt,
            block.number,
            "Lockup should be settled to current block"
        );

        uint256 expectedLockup = initialLockup +
            (lockupRate * 30) + // accumulated lockup
            (lockupRate * lockupPeriod); // future lockup
        assertEq(
            account.lockupCurrent,
            expectedLockup,
            "Lockup current should match rail's lockup requirements"
        );
        // Verify account funds match expected value after deposits
        assertEq(
            account.funds,
            DEPOSIT_AMOUNT * 3,
            "Account funds should match total deposits after settlement"
        );
    }

    function testSettlementInvariants() public {
        // Setup: deposit a specific amount
        helper.makeDeposit(
            payments,
            address(token),
            user1,
            user1,
            DEPOSIT_AMOUNT
        );

        // Scenario 1: Lockup exactly matches funds by creating a rail with fixed lockup
        // exactly matching the deposit amount

        // Create a rail with fixed lockup = all available funds
        helper.setupRailWithParameters(
            payments,
            address(token),
            user1,
            user2,
            operator,
            0, // no payment rate
            10, // Lockup period
            DEPOSIT_AMOUNT // fixed lockup equal to all funds
        );

        // Verify the account state
        Payments.Account memory accountAfterRail = helper.getAccountData(
            payments,
            address(token),
            user1
        );
        assertEq(
            accountAfterRail.lockupCurrent,
            DEPOSIT_AMOUNT,
            "Lockup should equal funds"
        );
        assertEq(
            accountAfterRail.funds,
            DEPOSIT_AMOUNT,
            "Funds should match deposit"
        );

        helper.makeDeposit(payments, address(token), user1, user1, 1); // Adding more funds

        // Scenario 2: Verify we can't create a situation where lockup > funds
        // We'll try to create a rail with an impossibly high fixed lockup

        // Increase operator approval allowance
        vm.startPrank(user1);
        payments.setOperatorApproval(
            address(token),
            operator,
            true,
            0, // no rate allowance needed
            DEPOSIT_AMOUNT * 3, // much higher lockup allowance
            100 // max lockup period
        );
        vm.stopPrank();

        // Try to set up a rail with lockup > funds which should fail
        vm.startPrank(operator);
        uint256 railId = payments.createRail(
            address(token),
            user1,
            user2,
            address(0)
        );

        // This should fail because lockupFixed > available funds
        vm.expectRevert(
            "invariant failure: insufficient funds to cover lockup after function execution"
        );
        payments.modifyRailLockup(railId, 10, DEPOSIT_AMOUNT * 2);
        vm.stopPrank();
    }

    function testWithdrawWithLockupSettlement() public {
        helper.makeDeposit(
            payments,
            address(token),
            user1,
            user1,
            DEPOSIT_AMOUNT * 2 // Deposit 200 ether
        );
        // Set a lockup rate and an existing lockup via a rail
        uint256 lockupRate = 1 ether;
        uint256 initialLockup = 50 ether;
        uint256 lockupPeriod = 10;

        // Create rail with fixed + rate-based lockup
        helper.setupRailWithParameters(
            payments,
            address(token),
            user1,
            user2,
            operator,
            lockupRate, // 1 ether per block
            lockupPeriod, // Lockup period of 10 blocks
            initialLockup // 50 ether fixed lockup
        );

        // Total lockup at rail creation: 50 ether fixed + (1 ether * 10 blocks) = 60 ether
        // Available for withdrawal at creation: 200 ether - 60 ether = 140 ether

        // Try to withdraw more than available (should fail)
        helper.expectWithdrawalToFail(
            payments,
            address(token),
            user1,
            150 ether,
            bytes("insufficient unlocked funds for withdrawal")
        );

        // Withdraw exactly the available amount (should succeed and also settle account lockup)
        helper.makeWithdrawal(payments, address(token), user1, 140 ether);

        // Verify account state
        Payments.Account memory account = helper.getAccountData(
            payments,
            address(token),
            user1
        );

        // Remaining funds: 200 - 140 = 60 ether
        // Remaining lockup: 60 ether (unchanged because no blocks passed)
        assertEq(
            account.funds,
            60 ether,
            "Remaining funds should match lockup"
        );
        assertEq(account.lockupCurrent, 60 ether, "Lockup should be updated");

        // Settlement happens during withdrawal
        assertEq(
            account.lockupLastSettledAt,
            block.number,
            "Settlement should be updated to current block"
        );
    }
}
