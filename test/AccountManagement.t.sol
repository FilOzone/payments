// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Payments} from "../src/Payments.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {PaymentsTestHelpers} from "./helpers/PaymentsTestHelpers.sol";
import {BaseTestHelper} from "./helpers/BaseTestHelper.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract AccountManagementTest is Test, BaseTestHelper {
    PaymentsTestHelpers helper;
    Payments payments;

    uint256 internal constant DEPOSIT_AMOUNT = 100 ether;
    uint256 internal constant INITIAL_BALANCE = 1000 ether;
    uint256 internal constant MAX_LOCKUP_PERIOD = 100;

    function setUp() public {
        // Create test helpers and setup environment
        helper = new PaymentsTestHelpers();
        helper.setupStandardTestEnvironment();
        payments = helper.payments();
    }

    function testBasicDeposit() public {
        helper.makeDeposit(USER1, USER1, DEPOSIT_AMOUNT);
    }

    function testNativeDeposit() public {
        helper.makeNativeDeposit(USER1, USER1, DEPOSIT_AMOUNT);
    }

    function testMultipleDeposits() public {
        helper.makeDeposit(USER1, USER1, DEPOSIT_AMOUNT);
        helper.makeDeposit(USER1, USER1, DEPOSIT_AMOUNT + 1);
    }

    function testDepositToAnotherUser() public {
        helper.makeDeposit(USER1, USER2, DEPOSIT_AMOUNT);
    }

    function testNativeDepositWithInsufficientNativeTokens() public {
        vm.startPrank(USER1);

        // Test zero token address
        vm.expectRevert("must send an equal amount of native tokens");
        payments.deposit{value: DEPOSIT_AMOUNT - 1}(
            address(0),
            USER1,
            DEPOSIT_AMOUNT
        );

        vm.stopPrank();
    }

    function testDepositWithZeroRecipient() public {
        address testTokenAddr = address(helper.testToken());
        vm.startPrank(USER1);

        // Using straightforward expectRevert without message
        vm.expectRevert();
        payments.deposit(testTokenAddr, address(0), DEPOSIT_AMOUNT);

        vm.stopPrank();
    }

    function testDepositWithInsufficientBalance() public {
        vm.startPrank(USER1);
        vm.expectRevert();
        helper.makeDeposit(USER1, USER1, INITIAL_BALANCE + 1);
        vm.stopPrank();
    }

    function testDepositWithInsufficientAllowance() public {
        // Reset allowance to a small amount
        vm.startPrank(USER1);
        IERC20 testToken = helper.testToken();
        testToken.approve(address(payments), DEPOSIT_AMOUNT / 2);

        // Attempt deposit with more than approved
        vm.expectRevert();
        payments.deposit(address(testToken), USER1, DEPOSIT_AMOUNT);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                           WITHDRAWAL TESTS
    //////////////////////////////////////////////////////////////*/

    function testBasicWithdrawal() public {
        helper.makeDeposit(USER1, USER1, DEPOSIT_AMOUNT);
        helper.makeWithdrawal(USER1, DEPOSIT_AMOUNT / 2);
    }

    function testNativeWithdrawal() public {
        helper.makeNativeDeposit(USER1, USER1, DEPOSIT_AMOUNT);
        helper.makeNativeWithdrawal(USER1, DEPOSIT_AMOUNT / 2);
    }

    function testMultipleWithdrawals() public {
        // Setup: deposit first
        helper.makeDeposit(USER1, USER1, DEPOSIT_AMOUNT);

        // Test multiple withdrawals
        helper.makeWithdrawal(USER1, DEPOSIT_AMOUNT / 4);
        helper.makeWithdrawal(USER1, DEPOSIT_AMOUNT / 4);
    }

    function testWithdrawToAnotherAddress() public {
        // Setup: deposit first
        helper.makeDeposit(USER1, USER1, DEPOSIT_AMOUNT);

        // Test withdrawTo
        helper.makeWithdrawalTo(USER1, USER2, DEPOSIT_AMOUNT / 2);
    }

    function testWithdrawEntireBalance() public {
        // Setup: deposit first
        helper.makeDeposit(USER1, USER1, DEPOSIT_AMOUNT);

        // Withdraw everything
        helper.makeWithdrawal(USER1, DEPOSIT_AMOUNT);
    }

    function testWithdrawExcessAmount() public {
        // Setup: deposit first
        helper.makeDeposit(USER1, USER1, DEPOSIT_AMOUNT);

        // Try to withdraw more than available
        helper.expectWithdrawalToFail(
            USER1,
            DEPOSIT_AMOUNT + 1,
            bytes("insufficient unlocked funds for withdrawal")
        );
    }

    function testWithdrawToWithZeroRecipient() public {
        address testTokenAddr = address(helper.testToken());
        vm.startPrank(USER1);

        // Test zero recipient address
        vm.expectRevert();
        payments.withdrawTo(testTokenAddr, address(0), DEPOSIT_AMOUNT);

        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                          LOCKUP/SETTLEMENT TESTS
    //////////////////////////////////////////////////////////////*/

    function testWithdrawWithLockedFunds() public {
        // First, deposit funds
        helper.makeDeposit(USER1, USER1, DEPOSIT_AMOUNT);

        // Define locked amount to be half of the deposit
        uint256 lockedAmount = DEPOSIT_AMOUNT / 2;

        // Create a rail with a fixed lockup amount to achieve the required locked funds
        helper.setupOperatorApproval(
            USER1,
            OPERATOR,
            100 ether, // rateAllowance
            lockedAmount, // lockupAllowance exactly matches what we need
            MAX_LOCKUP_PERIOD // max lockup period
        );

        // Create rail with the fixed lockup
        helper.setupRailWithParameters(
            USER1,
            USER2,
            OPERATOR,
            0, // no payment rate
            0, // no lockup period
            lockedAmount, // fixed lockup of half the deposit
            address(0) // no fixed lockup
        );

        // Verify lockup worked by checking account state
        helper.assertAccountState(
            USER1,
            DEPOSIT_AMOUNT, // expected funds
            lockedAmount, // expected lockup
            0, // expected rate (not set in this test)
            block.number // expected last settled
        );

        // Try to withdraw more than unlocked funds
        helper.expectWithdrawalToFail(
            USER1,
            DEPOSIT_AMOUNT,
            bytes("insufficient unlocked funds for withdrawal")
        );

        // Should be able to withdraw up to unlocked amount
        helper.makeWithdrawal(USER1, DEPOSIT_AMOUNT - lockedAmount);
    }

    function testSettlementDuringDeposit() public {
        // First deposit
        helper.makeDeposit(USER1, USER1, DEPOSIT_AMOUNT);

        // Setup operator approval with sufficient allowances
        helper.setupOperatorApproval(
            USER1,
            OPERATOR,
            100 ether, // rateAllowance
            1000 ether, // lockupAllowance
            MAX_LOCKUP_PERIOD // max lockup period
        );

        uint256 lockupRate = 0.5 ether; // 0.5 token per block

        // Create a rail that will set the lockup rate to 0.5 ether per block
        // This creates a lockup rate of 0.5 ether/block for the account
        helper.setupRailWithParameters(
            USER1,
            USER2,
            OPERATOR,
            lockupRate, // payment rate (creates lockup rate)
            10, // lockup period
            0, // no fixed lockup
            address(0) // no fixed lockup
        );

        // Create a second rail to get to 1 ether lockup rate on the account
        helper.setupRailWithParameters(
            USER1,
            USER2,
            OPERATOR,
            lockupRate, // payment rate (creates another 0.5 ether/block lockup rate)
            10, // lockup period
            0, // no fixed lockup
            address(0) // no fixed lockup
        );

        // Advance 10 blocks to create settlement gap
        helper.advanceBlocks(10);

        // Make another deposit to trigger settlement
        helper.makeDeposit(USER1, USER1, DEPOSIT_AMOUNT);

        // Check all states match expectations using assertAccountState helper
        helper.assertAccountState(
            USER1,
            DEPOSIT_AMOUNT * 2, // expected funds
            20 ether, // expected lockup (2 rails × 0.5 ether per block × 10 blocks + future lockup of 10 ether)
            lockupRate * 2, // expected rate (2 * 0.5 ether)
            block.number // expected last settled
        );
    }
}
