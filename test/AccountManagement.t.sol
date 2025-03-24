// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Payments} from "../src/Payments.sol";
import {ERC1967Proxy} from "../src/ERC1967Proxy.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {ReentrantERC20} from "./mocks/ReentrantERC20.sol";
import {PaymentsTestHelpers} from "./helpers/PaymentsTestHelpers.sol";

contract AccountManagementTest is Test {
    Payments payments;
    MockERC20 standardToken;
    ReentrantERC20 maliciousToken;

    address owner = address(0x1);
    address user1 = address(0x2);
    address user2 = address(0x3);

    uint256 constant INITIAL_BALANCE = 1000 ether;
    uint256 constant DEPOSIT_AMOUNT = 100 ether;

    function setUp() public {
        // Create test helpers
        PaymentsTestHelpers helper = new PaymentsTestHelpers();
        
        // Setup payments system
        payments = helper.deployPaymentsSystem(owner);
        
        // Set up users for standard token
        address[] memory standardUsers = new address[](2);
        standardUsers[0] = user1;
        standardUsers[1] = user2;
        
        // Set up users for malicious token
        address[] memory maliciousUsers = new address[](1);
        maliciousUsers[0] = user1;
        
        // Deploy test tokens
        standardToken = helper.setupTestToken(
            "Test Token", 
            "TEST", 
            standardUsers, 
            INITIAL_BALANCE, 
            address(payments)
        );
        
        // Deploy malicious token for reentrancy tests
        maliciousToken = helper.setupReentrantToken(
            "Malicious Token", 
            "EVIL", 
            maliciousUsers, 
            INITIAL_BALANCE, 
            address(payments)
        );
    }

    function assertAccountBalance(
        address tokenAddress,
        address userAddress,
        uint256 expectedAmount
    ) internal view {
        (uint256 funds, , , ) = payments.accounts(tokenAddress, userAddress);
        assertEq(funds, expectedAmount, "Account balance incorrect");
    }

    function testBasicDeposit() public {
        PaymentsTestHelpers helper = new PaymentsTestHelpers();
        helper.makeDeposit(
            payments,
            address(standardToken),
            user1,
            user1,
            DEPOSIT_AMOUNT
        );

        assertAccountBalance(address(standardToken), user1, DEPOSIT_AMOUNT);
        assertEq(
            standardToken.balanceOf(address(payments)),
            DEPOSIT_AMOUNT,
            "Contract token balance incorrect"
        );
    }

    function testMultipleDeposits() public {
        PaymentsTestHelpers helper = new PaymentsTestHelpers();
        helper.makeDeposit(
            payments,
            address(standardToken),
            user1,
            user1,
            DEPOSIT_AMOUNT
        );
        helper.makeDeposit(
            payments,
            address(standardToken),
            user1,
            user1,
            DEPOSIT_AMOUNT + 1
        );

        assertAccountBalance(
            address(standardToken),
            user1,
            (DEPOSIT_AMOUNT * 2) + 1
        );
    }

    function testDepositToAnotherUser() public {
        PaymentsTestHelpers helper = new PaymentsTestHelpers();
        helper.makeDeposit(
            payments,
            address(standardToken),
            user1,
            user2,
            DEPOSIT_AMOUNT
        );

        assertAccountBalance(address(standardToken), user2, DEPOSIT_AMOUNT);
        assertEq(
            standardToken.balanceOf(user1),
            INITIAL_BALANCE - DEPOSIT_AMOUNT,
            "User1 token balance incorrect"
        );
    }

    function testDepositWithZeroAddress() public {
        vm.startPrank(user1);

        // Test zero token address
        vm.expectRevert("token address cannot be zero");
        payments.deposit(address(0), user1, DEPOSIT_AMOUNT);

        // Test zero recipient address
        vm.expectRevert("to address cannot be zero");
        payments.deposit(address(standardToken), address(0), DEPOSIT_AMOUNT);

        vm.stopPrank();
    }

    function testDepositWithInsufficientBalance() public {
        vm.startPrank(user1);
        vm.expectRevert();
        payments.deposit(address(standardToken), user1, INITIAL_BALANCE + 1);
        vm.stopPrank();
    }

    function testDepositWithInsufficientAllowance() public {
        // Reset allowance to a small amount
        vm.startPrank(user1);
        standardToken.approve(address(payments), DEPOSIT_AMOUNT / 2);

        // Attempt deposit with more than approved
        vm.expectRevert();
        payments.deposit(address(standardToken), user1, DEPOSIT_AMOUNT);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                           WITHDRAWAL TESTS
    //////////////////////////////////////////////////////////////*/

    function testBasicWithdrawal() public {
        PaymentsTestHelpers helper = new PaymentsTestHelpers();
        helper.makeDeposit(
            payments,
            address(standardToken),
            user1,
            user1,
            DEPOSIT_AMOUNT
        );

        uint256 preBalance = standardToken.balanceOf(user1);
        helper.makeWithdrawal(
            payments,
            address(standardToken),
            user1,
            DEPOSIT_AMOUNT / 2
        );

        assertAccountBalance(address(standardToken), user1, DEPOSIT_AMOUNT / 2);
        assertEq(
            standardToken.balanceOf(user1),
            preBalance + DEPOSIT_AMOUNT / 2,
            "User token balance incorrect after withdrawal"
        );
    }

    function testMultipleWithdrawals() public {
        PaymentsTestHelpers helper = new PaymentsTestHelpers();
        // Setup: deposit first
        helper.makeDeposit(
            payments,
            address(standardToken),
            user1,
            user1,
            DEPOSIT_AMOUNT
        );

        // Test multiple withdrawals
        helper.makeWithdrawal(
            payments,
            address(standardToken),
            user1,
            DEPOSIT_AMOUNT / 4
        );
        helper.makeWithdrawal(
            payments,
            address(standardToken),
            user1,
            DEPOSIT_AMOUNT / 4
        );

        assertAccountBalance(address(standardToken), user1, DEPOSIT_AMOUNT / 2);
    }

    function testWithdrawToAnotherAddress() public {
        PaymentsTestHelpers helper = new PaymentsTestHelpers();
        // Setup: deposit first
        helper.makeDeposit(
            payments,
            address(standardToken),
            user1,
            user1,
            DEPOSIT_AMOUNT
        );

        // Test withdrawTo
        uint256 user2PreBalance = standardToken.balanceOf(user2);
        helper.makeWithdrawalTo(
            payments,
            address(standardToken),
            user1,
            user2,
            DEPOSIT_AMOUNT / 2
        );

        assertAccountBalance(address(standardToken), user1, DEPOSIT_AMOUNT / 2);
        assertEq(
            standardToken.balanceOf(user2),
            user2PreBalance + DEPOSIT_AMOUNT / 2,
            "Recipient token balance incorrect"
        );
    }

    function testWithdrawEntireBalance() public {
        PaymentsTestHelpers helper = new PaymentsTestHelpers();
        // Setup: deposit first
        helper.makeDeposit(
            payments,
            address(standardToken),
            user1,
            user1,
            DEPOSIT_AMOUNT
        );

        // Withdraw everything
        helper.makeWithdrawal(
            payments,
            address(standardToken),
            user1,
            DEPOSIT_AMOUNT
        );

        assertAccountBalance(address(standardToken), user1, 0);
    }

    function testWithdrawExcessAmount() public {
        PaymentsTestHelpers helper = new PaymentsTestHelpers();
        // Setup: deposit first
        helper.makeDeposit(
            payments,
            address(standardToken),
            user1,
            user1,
            DEPOSIT_AMOUNT
        );

        // Try to withdraw more than available
        helper.expectWithdrawalToFail(
            payments,
            address(standardToken),
            user1,
            DEPOSIT_AMOUNT + 1,
            bytes("insufficient unlocked funds for withdrawal")
        );
    }

    function testWithdrawWithZeroAddress() public {
        vm.startPrank(user1);

        // Test zero token address
        vm.expectRevert("token address cannot be zero");
        payments.withdraw(address(0), DEPOSIT_AMOUNT);

        // Test zero recipient address
        vm.expectRevert("to address cannot be zero");
        payments.withdrawTo(address(standardToken), address(0), DEPOSIT_AMOUNT);

        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                          LOCKUP/SETTLEMENT TESTS
    //////////////////////////////////////////////////////////////*/

    function testWithdrawWithLockedFunds() public {
        PaymentsTestHelpers helper = new PaymentsTestHelpers();

        // First, deposit funds
        helper.makeDeposit(
            payments,
            address(standardToken),
            user1,
            user1,
            DEPOSIT_AMOUNT
        );

        // Define locked amount to be half of the deposit
        uint256 lockedAmount = DEPOSIT_AMOUNT / 2;

        address testOperator = address(0x4);

        // Create a rail with a fixed lockup amount to achieve the required locked funds
        helper.setupOperatorApproval(
            payments,
            address(standardToken),
            user1,
            testOperator,
            100 ether, // rateAllowance
            lockedAmount // lockupAllowance exactly matches what we need
        );

        // Create rail with the fixed lockup
        helper.setupRailWithParameters(
            payments,
            address(standardToken),
            user1,
            user2,
            testOperator,
            0, // no payment rate
            0, // no lockup period
            lockedAmount // fixed lockup of half the deposit
        );

        // Verify lockup worked by checking account state
        helper.assertAccountState(
            payments,
            address(standardToken),
            user1,
            DEPOSIT_AMOUNT, // expected funds
            lockedAmount, // expected lockup
            0, // expected rate (not set in this test)
            block.number // expected last settled
        );

        // Try to withdraw more than unlocked funds
        helper.expectWithdrawalToFail(
            payments,
            address(standardToken),
            user1,
            DEPOSIT_AMOUNT,
            bytes("insufficient unlocked funds for withdrawal")
        );

        // Should be able to withdraw up to unlocked amount
        helper.makeWithdrawal(
            payments,
            address(standardToken),
            user1,
            DEPOSIT_AMOUNT - lockedAmount
        );

        // Verify remaining balance
        assertAccountBalance(address(standardToken), user1, lockedAmount);
    }

    function testSettlementDuringDeposit() public {
        PaymentsTestHelpers helper = new PaymentsTestHelpers();

        helper.makeDeposit(
            payments,
            address(standardToken),
            user1,
            user1,
            DEPOSIT_AMOUNT
        );

        address testOperator = address(0x4);

        // Setup operator approval with sufficient allowances
        helper.setupOperatorApproval(
            payments,
            address(standardToken),
            user1,
            testOperator,
            100 ether, // rateAllowance
            1000 ether // lockupAllowance
        );

        uint256 lockupRate = 0.5 ether; // 0.5 token per block

        // Create a rail that will set the lockup rate to 0.5 ether per block
        // This creates a lockup rate of 0.5 ether/block for the account
        helper.setupRailWithParameters(
            payments,
            address(standardToken),
            user1,
            user2,
            testOperator,
            lockupRate, // payment rate (creates lockup rate)
            10, // lockup period
            0 // no fixed lockup
        );

        // Create a second rail to get to 1 ether lockup rate on the account
        helper.setupRailWithParameters(
            payments,
            address(standardToken),
            user1,
            user2,
            testOperator,
            lockupRate, // payment rate (creates another 0.5 ether/block lockup rate)
            10, // lockup period
            0 // no fixed lockup
        );

        // Advance 10 blocks to create settlement gap
        helper.advanceBlocks(10);

        // Make another deposit to trigger settlement
        helper.makeDeposit(
            payments,
            address(standardToken),
            user1,
            user1,
            DEPOSIT_AMOUNT
        );

        // Check all states match expectations using assertAccountState helper
        helper.assertAccountState(
            payments,
            address(standardToken),
            user1,
            DEPOSIT_AMOUNT * 2, // expected funds
            20 ether, // expected lockup (2 rails × 0.5 ether per block × 20 blocks)
            2 * lockupRate, // expected rate (2 * 0.5 ether)
            block.number // expected last settled
        );
    }

    function testReentrancyProtection() public {
        PaymentsTestHelpers helper = new PaymentsTestHelpers();
        helper.makeDeposit(
            payments,
            address(maliciousToken),
            user1,
            user1,
            DEPOSIT_AMOUNT
        );

        uint256 initialBalance = maliciousToken.balanceOf(user1);

        // Prepare reentrant attack - try to call withdraw again during the token transfer
        bytes memory attackCalldata = abi.encodeWithSelector(
            Payments.withdraw.selector,
            address(maliciousToken),
            DEPOSIT_AMOUNT / 2
        );

        vm.startPrank(user1);
        maliciousToken.setAttack(address(payments), attackCalldata);

        payments.withdraw(address(maliciousToken), DEPOSIT_AMOUNT / 2);

        // Verify only one withdrawal occurred
        uint256 finalBalance = maliciousToken.balanceOf(user1);

        // If reentrancy protection works, only DEPOSIT_AMOUNT/2 should be withdrawn
        assertEq(
            finalBalance,
            initialBalance + DEPOSIT_AMOUNT / 2,
            "Reentrancy protection failed: more tokens withdrawn than expected"
        );

        Payments.Account memory account = helper.getAccountData(
            payments,
            address(maliciousToken),
            user1
        );

        assertEq(
            account.funds,
            DEPOSIT_AMOUNT / 2,
            "Reentrancy protection failed: account balance incorrect"
        );

        vm.stopPrank();
    }
}
