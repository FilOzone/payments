// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Payments} from "../src/Payments.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {PaymentsTestHelpers} from "./helpers/PaymentsTestHelpers.sol";

contract OperatorApprovalTest is Test {
    Payments payments;
    MockERC20 token;
    MockERC20 secondToken;
    PaymentsTestHelpers helper;

    address owner = address(0x1);
    address client = address(0x2);
    address recipient = address(0x3);
    address operator = address(0x4);
    address secondOperator = address(0x5);
    address unauthorizedOperator = address(0x6);

    uint256 constant INITIAL_BALANCE = 10000 ether;
    uint256 constant DEPOSIT_AMOUNT = 1000 ether;
    uint256 constant RATE_ALLOWANCE = 100 ether;
    uint256 constant LOCKUP_ALLOWANCE = 1000 ether;

    function setUp() public {
        helper = new PaymentsTestHelpers();
        payments = helper.deployPaymentsSystem(owner);

        // Set up users for the token
        address[] memory users = new address[](4);
        users[0] = client;
        users[1] = recipient;
        users[2] = operator;
        users[3] = secondOperator;

        // Deploy test tokens with initial balances and approvals
        token = helper.setupTestToken(
            "Test Token",
            "TEST",
            users,
            INITIAL_BALANCE,
            address(payments)
        );

        secondToken = helper.setupTestToken(
            "Second Token",
            "SECOND",
            users,
            INITIAL_BALANCE,
            address(payments)
        );

        // Deposit funds for client
        helper.makeDeposit(
            payments,
            address(token),
            client,
            client,
            DEPOSIT_AMOUNT
        );
    }

    function testInvalidAddresses() public {
        // Test zero token address
        vm.startPrank(client);
        vm.expectRevert("token address cannot be zero");
        payments.setOperatorApproval(
            address(0),
            operator,
            true,
            RATE_ALLOWANCE,
            LOCKUP_ALLOWANCE
        );
        vm.stopPrank();

        // Test zero operator address
        vm.startPrank(client);
        vm.expectRevert("operator address cannot be zero");
        payments.setOperatorApproval(
            address(token),
            address(0),
            true,
            RATE_ALLOWANCE,
            LOCKUP_ALLOWANCE
        );
        vm.stopPrank();
    }

    function testModifyingAllowances() public {
        // Setup initial approval
        helper.setupOperatorApproval(
            payments,
            address(token),
            client,
            operator,
            RATE_ALLOWANCE,
            LOCKUP_ALLOWANCE
        );

        // Verify initial state
        helper.verifyOperatorAllowances(
            payments,
            address(token),
            client,
            operator,
            true,
            RATE_ALLOWANCE,
            LOCKUP_ALLOWANCE,
            0,
            0
        );

        // Increase allowances
        vm.startPrank(client);
        payments.setOperatorApproval(
            address(token),
            operator,
            true,
            RATE_ALLOWANCE * 2,
            LOCKUP_ALLOWANCE * 2
        );
        vm.stopPrank();

        // Verify increased allowances
        helper.verifyOperatorAllowances(
            payments,
            address(token),
            client,
            operator,
            true,
            RATE_ALLOWANCE * 2,
            LOCKUP_ALLOWANCE * 2,
            0,
            0
        );

        // Decrease allowances
        vm.startPrank(client);
        payments.setOperatorApproval(
            address(token),
            operator,
            true,
            RATE_ALLOWANCE / 2,
            LOCKUP_ALLOWANCE / 2
        );
        vm.stopPrank();

        // Verify decreased allowances
        helper.verifyOperatorAllowances(
            payments,
            address(token),
            client,
            operator,
            true,
            RATE_ALLOWANCE / 2,
            LOCKUP_ALLOWANCE / 2,
            0,
            0
        );
    }

    function testRevokingAndReapprovingOperator() public {
        // Setup initial approval
        helper.setupOperatorApproval(
            payments,
            address(token),
            client,
            operator,
            RATE_ALLOWANCE,
            LOCKUP_ALLOWANCE
        );

        // Revoke approval
        vm.startPrank(client);
        payments.setOperatorApproval(
            address(token),
            operator,
            false,
            RATE_ALLOWANCE,
            LOCKUP_ALLOWANCE
        );
        vm.stopPrank();

        // Verify revoked status (isApproved should be false)
        helper.verifyOperatorAllowances(
            payments,
            address(token),
            client,
            operator,
            false,
            RATE_ALLOWANCE,
            LOCKUP_ALLOWANCE,
            0,
            0
        );

        // Reapprove operator
        vm.startPrank(client);
        payments.setOperatorApproval(
            address(token),
            operator,
            true,
            RATE_ALLOWANCE,
            LOCKUP_ALLOWANCE
        );
        vm.stopPrank();

        // Verify reapproved status
        helper.verifyOperatorAllowances(
            payments,
            address(token),
            client,
            operator,
            true,
            RATE_ALLOWANCE,
            LOCKUP_ALLOWANCE,
            0,
            0
        );
    }

    function testRateTrackingWithMultipleRails() public {
        // Setup initial approval
        helper.setupOperatorApproval(
            payments,
            address(token),
            client,
            operator,
            RATE_ALLOWANCE,
            LOCKUP_ALLOWANCE
        );

        // Create a rail
        uint256 railId = helper.createRail(
            payments,
            address(token),
            client,
            recipient,
            operator,
            address(0)
        );

        // Verify no allowance consumed yet
        helper.verifyOperatorAllowances(
            payments,
            address(token),
            client,
            operator,
            true,
            RATE_ALLOWANCE,
            LOCKUP_ALLOWANCE,
            0,
            0
        );

        // 1. Set initial payment rate
        uint256 initialRate = 10 ether;
        vm.startPrank(operator);
        payments.modifyRailPayment(railId, initialRate, 0);
        vm.stopPrank();

        // Verify rate usage matches initial rate
        helper.verifyOperatorAllowances(
            payments,
            address(token),
            client,
            operator,
            true,
            RATE_ALLOWANCE,
            LOCKUP_ALLOWANCE,
            initialRate,
            0
        );

        // 2. Increase payment rate
        uint256 increasedRate = 15 ether;
        vm.startPrank(operator);
        payments.modifyRailPayment(railId, increasedRate, 0);
        vm.stopPrank();

        // Verify rate usage increased
        helper.verifyOperatorAllowances(
            payments,
            address(token),
            client,
            operator,
            true,
            RATE_ALLOWANCE,
            LOCKUP_ALLOWANCE,
            increasedRate,
            0
        );

        // 3. Decrease payment rate
        uint256 decreasedRate = 5 ether;
        vm.startPrank(operator);
        payments.modifyRailPayment(railId, decreasedRate, 0);
        vm.stopPrank();

        // Verify rate usage decreased
        helper.verifyOperatorAllowances(
            payments,
            address(token),
            client,
            operator,
            true,
            RATE_ALLOWANCE,
            LOCKUP_ALLOWANCE,
            decreasedRate,
            0
        );

        // 4. Create second rail and set rate
        uint256 railId2 = helper.createRail(
            payments,
            address(token),
            client,
            recipient,
            operator,
            address(0)
        );

        uint256 rate2 = 15 ether;
        vm.startPrank(operator);
        payments.modifyRailPayment(railId2, rate2, 0);
        vm.stopPrank();

        // Verify combined rate usage
        helper.verifyOperatorAllowances(
            payments,
            address(token),
            client,
            operator,
            true,
            RATE_ALLOWANCE,
            LOCKUP_ALLOWANCE,
            decreasedRate + rate2,
            0
        );
    }

    function testRateLimitEnforcement() public {
        // Setup initial approval with limited rate allowance
        uint256 limitedRateAllowance = 10 ether;
        helper.setupOperatorApproval(
            payments,
            address(token),
            client,
            operator,
            limitedRateAllowance,
            LOCKUP_ALLOWANCE
        );

        // Create rail
        uint256 railId = helper.createRail(
            payments,
            address(token),
            client,
            recipient,
            operator,
            address(0)
        );

        // Set rate to exactly the limit
        vm.startPrank(operator);
        payments.modifyRailPayment(railId, limitedRateAllowance, 0);
        vm.stopPrank();

        // Now try to exceed the limit - should revert
        vm.startPrank(operator);
        vm.expectRevert("operation exceeds operator rate allowance");
        payments.modifyRailPayment(railId, limitedRateAllowance + 1 ether, 0);
        vm.stopPrank();
    }

    // SECTION: Lockup Allowance Tracking

    function testLockupTracking() public {
        // Setup initial approval
        helper.setupOperatorApproval(
            payments,
            address(token),
            client,
            operator,
            RATE_ALLOWANCE,
            LOCKUP_ALLOWANCE
        );

        // Create rail
        uint256 railId = helper.createRail(
            payments,
            address(token),
            client,
            recipient,
            operator,
            address(0)
        );

        // Set payment rate
        uint256 paymentRate = 10 ether;
        vm.startPrank(operator);
        payments.modifyRailPayment(railId, paymentRate, 0);
        vm.stopPrank();

        // 1. Set initial lockup
        uint256 lockupPeriod = 5; // 5 blocks
        uint256 initialFixedLockup = 100 ether;

        vm.startPrank(operator);
        payments.modifyRailLockup(railId, lockupPeriod, initialFixedLockup);
        vm.stopPrank();

        // Calculate expected lockup usage
        uint256 expectedLockupUsage = initialFixedLockup +
            (paymentRate * lockupPeriod);

        // Verify lockup usage
        helper.verifyOperatorAllowances(
            payments,
            address(token),
            client,
            operator,
            true,
            RATE_ALLOWANCE,
            LOCKUP_ALLOWANCE,
            paymentRate,
            expectedLockupUsage
        );

        // 2. Increase fixed lockup
        uint256 increasedFixedLockup = 200 ether;
        vm.startPrank(operator);
        payments.modifyRailLockup(railId, lockupPeriod, increasedFixedLockup);
        vm.stopPrank();

        // Calculate updated expected lockup usage
        uint256 updatedExpectedLockupUsage = increasedFixedLockup +
            (paymentRate * lockupPeriod);

        // Verify increased lockup usage
        helper.verifyOperatorAllowances(
            payments,
            address(token),
            client,
            operator,
            true,
            RATE_ALLOWANCE,
            LOCKUP_ALLOWANCE,
            paymentRate,
            updatedExpectedLockupUsage
        );

        // 3. Decrease fixed lockup
        uint256 decreasedFixedLockup = 50 ether;
        vm.startPrank(operator);
        payments.modifyRailLockup(railId, lockupPeriod, decreasedFixedLockup);
        vm.stopPrank();

        // Calculate reduced expected lockup usage
        uint256 finalExpectedLockupUsage = decreasedFixedLockup +
            (paymentRate * lockupPeriod);

        // Verify decreased lockup usage
        helper.verifyOperatorAllowances(
            payments,
            address(token),
            client,
            operator,
            true,
            RATE_ALLOWANCE,
            LOCKUP_ALLOWANCE,
            paymentRate,
            finalExpectedLockupUsage
        );
    }

    function testLockupLimitEnforcement() public {
        // Setup initial approval with limited lockup allowance
        uint256 limitedLockupAllowance = 100 ether;
        helper.setupOperatorApproval(
            payments,
            address(token),
            client,
            operator,
            RATE_ALLOWANCE,
            limitedLockupAllowance
        );

        // Create rail
        uint256 railId = helper.createRail(
            payments,
            address(token),
            client,
            recipient,
            operator,
            address(0)
        );

        // Set payment rate
        uint256 paymentRate = 10 ether;
        vm.startPrank(operator);
        payments.modifyRailPayment(railId, paymentRate, 0);
        vm.stopPrank();

        // Try to set fixed lockup that exceeds allowance
        uint256 excessiveLockup = 110 ether;
        vm.startPrank(operator);
        vm.expectRevert("operation exceeds operator lockup allowance");
        payments.modifyRailLockup(railId, 0, excessiveLockup);
        vm.stopPrank();
    }

    function testAllowanceEdgeCases() public {
        // 1. Test exact allowance consumption
        uint256 exactRateAllowance = 10 ether;
        uint256 exactLockupAllowance = 100 ether;
        helper.setupOperatorApproval(
            payments,
            address(token),
            client,
            operator,
            exactRateAllowance,
            exactLockupAllowance
        );

        // Create rail
        uint256 railId = helper.createRail(
            payments,
            address(token),
            client,
            recipient,
            operator,
            address(0)
        );

        // Use exactly the available rate allowance
        vm.startPrank(operator);
        payments.modifyRailPayment(railId, exactRateAllowance, 0);
        vm.stopPrank();

        // Use exactly the available lockup allowance
        vm.startPrank(operator);
        payments.modifyRailLockup(railId, 0, exactLockupAllowance);
        vm.stopPrank();

        // Verify allowances are fully consumed
        helper.verifyOperatorAllowances(
            payments,
            address(token),
            client,
            operator,
            true,
            exactRateAllowance,
            exactLockupAllowance,
            exactRateAllowance,
            exactLockupAllowance
        );

        // 2. Test zero allowance behavior
        helper.setupOperatorApproval(
            payments,
            address(token),
            client,
            secondOperator,
            0,
            0
        );

        // Create rail with zero allowances
        uint256 railId2 = helper.createRail(
            payments,
            address(token),
            client,
            recipient,
            secondOperator,
            address(0)
        );

        // Attempt to set non-zero rate (should fail)
        vm.startPrank(secondOperator);
        vm.expectRevert("operation exceeds operator rate allowance");
        payments.modifyRailPayment(railId2, 1, 0);
        vm.stopPrank();

        // Attempt to set non-zero lockup (should fail)
        vm.startPrank(secondOperator);
        vm.expectRevert("operation exceeds operator lockup allowance");
        payments.modifyRailLockup(railId2, 0, 1);
        vm.stopPrank();
    }

    function testOperatorAuthorizationBoundaries() public {
        // 1. Test unapproved operator
        vm.startPrank(unauthorizedOperator);
        vm.expectRevert("operator not approved");
        payments.createRail(address(token), client, recipient, address(0));
        vm.stopPrank();

        // 2. Setup approval and create rail
        helper.setupOperatorApproval(
            payments,
            address(token),
            client,
            operator,
            RATE_ALLOWANCE,
            LOCKUP_ALLOWANCE
        );

        uint256 railId = helper.createRail(
            payments,
            address(token),
            client,
            recipient,
            operator,
            address(0)
        );

        // 3. Test non-operator rail modification
        vm.startPrank(secondOperator);
        vm.expectRevert("only the rail operator can perform this action");
        payments.modifyRailPayment(railId, 10 ether, 0);
        vm.stopPrank();

        // 4. Revoke approval and verify operator can't create new rails
        vm.startPrank(client);
        payments.setOperatorApproval(
            address(token),
            operator,
            false,
            RATE_ALLOWANCE,
            LOCKUP_ALLOWANCE
        );
        vm.stopPrank();

        vm.startPrank(operator);
        vm.expectRevert("operator not approved");
        payments.createRail(address(token), client, recipient, address(0));
        vm.stopPrank();

        // 5. Verify operator can still modify existing rails after approval revocation
        vm.startPrank(operator);
        payments.modifyRailPayment(railId, 5 ether, 0);
        vm.stopPrank();

        // 6. Test client authorization (operator can't set approvals for client)
        vm.startPrank(operator);
        payments.setOperatorApproval(
            address(token),
            secondOperator,
            true,
            RATE_ALLOWANCE,
            LOCKUP_ALLOWANCE
        );
        vm.stopPrank();

        // Verify operator approval was not set for client
        (bool isApproved, , , , ) = payments.operatorApprovals(
            address(token),
            client,
            secondOperator
        );
        assertFalse(
            isApproved,
            "Second operator should not be approved for client"
        );
    }

    function testOneTimePaymentScenarios() public {
        // Setup approval
        helper.setupOperatorApproval(
            payments,
            address(token),
            client,
            operator,
            RATE_ALLOWANCE,
            LOCKUP_ALLOWANCE
        );

        // Create rail with fixed lockup
        uint256 railId = helper.createRail(
            payments,
            address(token),
            client,
            recipient,
            operator,
            address(0)
        );

        uint256 paymentRate = 10 ether;
        uint256 fixedLockup = 100 ether;

        vm.startPrank(operator);
        payments.modifyRailPayment(railId, paymentRate, 0);
        payments.modifyRailLockup(railId, 0, fixedLockup);
        vm.stopPrank();

        // 1. Test basic one-time payment
        // Check balances before payment
        Payments.Account memory clientBefore = helper.getAccountData(
            payments,
            address(token),
            client
        );
        Payments.Account memory recipientBefore = helper.getAccountData(
            payments,
            address(token),
            recipient
        );

        uint256 oneTimeAmount = 30 ether;
        vm.startPrank(operator);
        payments.modifyRailPayment(railId, paymentRate, oneTimeAmount);
        vm.stopPrank();

        // Check balances after payment
        Payments.Account memory clientAfter = helper.getAccountData(
            payments,
            address(token),
            client
        );
        Payments.Account memory recipientAfter = helper.getAccountData(
            payments,
            address(token),
            recipient
        );

        // Verify funds transferred correctly
        assertEq(
            clientAfter.funds,
            clientBefore.funds - oneTimeAmount,
            "Client balance incorrect"
        );
        assertEq(
            recipientAfter.funds,
            recipientBefore.funds + oneTimeAmount,
            "Recipient balance incorrect"
        );

        // Verify fixed lockup reduced
        Payments.RailView memory rail = payments.getRail(railId);
        assertEq(
            rail.lockupFixed,
            fixedLockup - oneTimeAmount,
            "Fixed lockup not reduced correctly"
        );

        // 2. Test complete fixed lockup consumption
        uint256 remainingFixedLockup = fixedLockup - oneTimeAmount;
        vm.startPrank(operator);
        payments.modifyRailPayment(railId, paymentRate, remainingFixedLockup);
        vm.stopPrank();

        // Verify fixed lockup is now zero
        rail = payments.getRail(railId);
        assertEq(rail.lockupFixed, 0, "Fixed lockup should be zero");

        // 3. Test excessive payment reverts
        vm.startPrank(operator);
        vm.expectRevert(
            "one time payment cannot be greater than rail lockupFixed"
        );
        payments.modifyRailPayment(railId, paymentRate, 1); // Lockup is now 0, so any payment should fail
        vm.stopPrank();
    }

    function testAllowanceChangesWithOneTimePayments() public {
        // Setup approval
        helper.setupOperatorApproval(
            payments,
            address(token),
            client,
            operator,
            RATE_ALLOWANCE,
            1000 ether
        );

        // Create rail
        uint256 railId = helper.createRail(
            payments,
            address(token),
            client,
            recipient,
            operator,
            address(0)
        );

        uint256 paymentRate = 10 ether;
        uint256 fixedLockup = 800 ether;

        vm.startPrank(operator);
        payments.modifyRailPayment(railId, paymentRate, 0);
        payments.modifyRailLockup(railId, 0, fixedLockup);
        vm.stopPrank();

        // 1. Test allowance reduction after fixed lockup set
        vm.startPrank(client);
        payments.setOperatorApproval(
            address(token),
            operator,
            true,
            RATE_ALLOWANCE,
            500 ether // below fixed lockup of 800 ether
        );
        vm.stopPrank();

        // Operator should still be able to make one-time payments up to the fixed lockup
        vm.startPrank(operator);
        payments.modifyRailPayment(railId, paymentRate, 300 ether);
        vm.stopPrank();

        // Check that one-time payment succeeded despite reduced allowance
        Payments.RailView memory rail = payments.getRail(railId);
        assertEq(
            rail.lockupFixed,
            fixedLockup - 300 ether,
            "Fixed lockup not reduced correctly"
        );

        // 2. Test zero allowance after fixed lockup set
        vm.startPrank(client);
        payments.setOperatorApproval(
            address(token),
            operator,
            true,
            RATE_ALLOWANCE,
            0 // zero allowance
        );
        vm.stopPrank();

        // Operator should still be able to make one-time payments up to the fixed lockup
        vm.startPrank(operator);
        payments.modifyRailPayment(railId, paymentRate, 200 ether);
        vm.stopPrank();

        // Check that one-time payment succeeded despite zero allowance
        rail = payments.getRail(railId);
        assertEq(
            rail.lockupFixed,
            300 ether,
            "Fixed lockup not reduced correctly"
        );
    }

    function testAllowanceReductionScenarios() public {
        // 1. Test reducing rate allowance below current usage
        // Setup approval
        helper.setupOperatorApproval(
            payments,
            address(token),
            client,
            operator,
            100 ether, // 100 ether rate allowance
            LOCKUP_ALLOWANCE
        );

        // Create rail and set rate
        uint256 railId = helper.createRail(
            payments,
            address(token),
            client,
            recipient,
            operator,
            address(0)
        );

        vm.startPrank(operator);
        payments.modifyRailPayment(railId, 50 ether, 0);
        vm.stopPrank();

        // Client reduces rate allowance below current usage
        vm.startPrank(client);
        payments.setOperatorApproval(
            address(token),
            operator,
            true,
            30 ether, // below current usage of 50 ether
            LOCKUP_ALLOWANCE
        );
        vm.stopPrank();

        // Operator should be able to decrease rate
        vm.startPrank(operator);
        payments.modifyRailPayment(railId, 30 ether, 0); // Decrease to allowance
        vm.stopPrank();

        // Operator should not be able to increase rate above current allowance
        vm.startPrank(operator);
        vm.expectRevert("operation exceeds operator rate allowance");
        payments.modifyRailPayment(railId, 40 ether, 0); // Try to increase above allowance
        vm.stopPrank();

        // 2. Test zeroing rate allowance after usage
        vm.startPrank(client);
        payments.setOperatorApproval(
            address(token),
            operator,
            true,
            0, // zero allowance
            LOCKUP_ALLOWANCE
        );
        vm.stopPrank();

        // Operator should be able to decrease rate
        vm.startPrank(operator);
        payments.modifyRailPayment(railId, 20 ether, 0);
        vm.stopPrank();

        // Operator should not be able to increase rate at all
        vm.startPrank(operator);
        vm.expectRevert("operation exceeds operator rate allowance");
        payments.modifyRailPayment(railId, 21 ether, 0);
        vm.stopPrank();

        // 3. Test reducing lockup allowance below current usage
        // Create a new rail for lockup testing
        uint256 railId2 = helper.createRail(
            payments,
            address(token),
            client,
            recipient,
            operator,
            address(0)
        );

        // Reset approval with high lockup
        helper.setupOperatorApproval(
            payments,
            address(token),
            client,
            operator,
            50 ether,
            1000 ether
        );

        // Set fixed lockup
        vm.startPrank(operator);
        payments.modifyRailPayment(railId2, 10 ether, 0);
        payments.modifyRailLockup(railId2, 0, 500 ether);
        vm.stopPrank();

        // Client reduces lockup allowance below current usage
        vm.startPrank(client);
        payments.setOperatorApproval(
            address(token),
            operator,
            true,
            50 ether,
            300 ether // below current usage of 500 ether
        );
        vm.stopPrank();

        // Operator should be able to decrease fixed lockup
        vm.startPrank(operator);
        payments.modifyRailLockup(railId2, 0, 200 ether);
        vm.stopPrank();

        // Operator should not be able to increase fixed lockup above current allowance
        vm.startPrank(operator);
        vm.expectRevert("operation exceeds operator lockup allowance");
        payments.modifyRailLockup(railId2, 0, 400 ether);
        vm.stopPrank();
    }

    function testComprehensiveApprovalLifecycle() public {
        // This test combines multiple approval lifecycle aspects into one comprehensive test

        // Setup approval
        helper.setupOperatorApproval(
            payments,
            address(token),
            client,
            operator,
            RATE_ALLOWANCE,
            LOCKUP_ALLOWANCE
        );

        // Create two rails with different parameters
        uint256 railId1 = helper.createRail(
            payments,
            address(token),
            client,
            recipient,
            operator,
            address(0)
        );

        uint256 railId2 = helper.createRail(
            payments,
            address(token),
            client,
            recipient,
            operator,
            address(0)
        );

        // Set parameters for first rail
        uint256 rate1 = 10 ether;
        uint256 lockupPeriod1 = 5;
        uint256 fixedLockup1 = 50 ether;

        vm.startPrank(operator);
        payments.modifyRailPayment(railId1, rate1, 0);
        payments.modifyRailLockup(railId1, lockupPeriod1, fixedLockup1);
        vm.stopPrank();

        // Set parameters for second rail
        uint256 rate2 = 15 ether;
        uint256 lockupPeriod2 = 3;
        uint256 fixedLockup2 = 30 ether;

        vm.startPrank(operator);
        payments.modifyRailPayment(railId2, rate2, 0);
        payments.modifyRailLockup(railId2, lockupPeriod2, fixedLockup2);
        vm.stopPrank();

        // Calculate expected usage
        uint256 expectedRateUsage = rate1 + rate2;
        uint256 expectedLockupUsage = fixedLockup1 +
            (rate1 * lockupPeriod1) +
            fixedLockup2 +
            (rate2 * lockupPeriod2);

        // Verify combined usage
        helper.verifyOperatorAllowances(
            payments,
            address(token),
            client,
            operator,
            true,
            RATE_ALLOWANCE,
            LOCKUP_ALLOWANCE,
            expectedRateUsage,
            expectedLockupUsage
        );

        // Make one-time payment for first rail
        uint256 oneTimeAmount = 20 ether;
        vm.startPrank(operator);
        payments.modifyRailPayment(railId1, rate1, oneTimeAmount);
        vm.stopPrank();

        // Revoke approval
        vm.startPrank(client);
        payments.setOperatorApproval(
            address(token),
            operator,
            false,
            RATE_ALLOWANCE,
            LOCKUP_ALLOWANCE
        );
        vm.stopPrank();

        // Operator should still be able to modify existing rails
        vm.startPrank(operator);
        payments.modifyRailPayment(railId1, rate1 - 2 ether, 0);
        payments.modifyRailLockup(
            railId2,
            lockupPeriod2,
            fixedLockup2 - 10 ether
        );
        vm.stopPrank();

        // But operator shouldn't be able to create a new rail
        vm.startPrank(operator);
        vm.expectRevert("operator not approved");
        payments.createRail(address(token), client, recipient, address(0));
        vm.stopPrank();

        // Reapprove with reduced allowances
        vm.startPrank(client);
        payments.setOperatorApproval(
            address(token),
            operator,
            true,
            20 ether, // Only enough for current rails
            100 ether
        );
        vm.stopPrank();

        // Operator should be able to create a new rail
        uint256 railId3 = helper.createRail(
            payments,
            address(token),
            client,
            recipient,
            operator,
            address(0)
        );

        // But should not be able to exceed the new allowance
        vm.startPrank(operator);
        vm.expectRevert("operation exceeds operator rate allowance");
        payments.modifyRailPayment(railId3, 10 ether, 0); // Would exceed new rate allowance
        vm.stopPrank();
    }

    function testMultiTokenAndClientScenarios() public {
        // Setup for multiple clients
        address secondClient = address(0x7);

        // Mint tokens for second client
        vm.startPrank(address(token));
        token.mint(secondClient, INITIAL_BALANCE);
        token.mint(secondClient, INITIAL_BALANCE);
        vm.stopPrank();

        vm.startPrank(address(secondToken));
        secondToken.mint(secondClient, INITIAL_BALANCE);
        vm.stopPrank();

        // Approve payments contract to spend tokens
        vm.startPrank(secondClient);
        token.approve(address(payments), type(uint256).max);
        secondToken.approve(address(payments), type(uint256).max);
        vm.stopPrank();

        // Make deposit for second client
        helper.makeDeposit(
            payments,
            address(token),
            secondClient,
            secondClient,
            DEPOSIT_AMOUNT
        );

        helper.makeDeposit(
            payments,
            address(secondToken),
            secondClient,
            secondClient,
            DEPOSIT_AMOUNT
        );

        // Setup approvals across tokens and clients
        // Client 1, Token 1
        helper.setupOperatorApproval(
            payments,
            address(token),
            client,
            operator,
            RATE_ALLOWANCE,
            LOCKUP_ALLOWANCE
        );

        // Client 1, Token 2
        helper.setupOperatorApproval(
            payments,
            address(secondToken),
            client,
            operator,
            RATE_ALLOWANCE * 2,
            LOCKUP_ALLOWANCE * 2
        );

        // Client 2, Token 1
        helper.setupOperatorApproval(
            payments,
            address(token),
            secondClient,
            operator,
            RATE_ALLOWANCE / 2,
            LOCKUP_ALLOWANCE / 2
        );

        // Create rails for different combinations
        // Client 1, Token 1
        uint256 railId1 = helper.createRail(
            payments,
            address(token),
            client,
            recipient,
            operator,
            address(0)
        );

        // Client 1, Token 2
        uint256 railId2 = helper.createRail(
            payments,
            address(secondToken),
            client,
            recipient,
            operator,
            address(0)
        );

        // Client 2, Token 1
        uint256 railId3 = helper.createRail(
            payments,
            address(token),
            secondClient,
            recipient,
            operator,
            address(0)
        );

        // Set different rates for each rail
        vm.startPrank(operator);
        payments.modifyRailPayment(railId1, 10 ether, 0);
        payments.modifyRailPayment(railId2, 20 ether, 0);
        payments.modifyRailPayment(railId3, 5 ether, 0);
        vm.stopPrank();

        // Verify rate usage is tracked separately per token and client
        helper.verifyOperatorAllowances(
            payments,
            address(token),
            client,
            operator,
            true,
            RATE_ALLOWANCE,
            LOCKUP_ALLOWANCE,
            10 ether,
            0
        );

        helper.verifyOperatorAllowances(
            payments,
            address(secondToken),
            client,
            operator,
            true,
            RATE_ALLOWANCE * 2,
            LOCKUP_ALLOWANCE * 2,
            20 ether,
            0
        );

        helper.verifyOperatorAllowances(
            payments,
            address(token),
            secondClient,
            operator,
            true,
            RATE_ALLOWANCE / 2,
            LOCKUP_ALLOWANCE / 2,
            5 ether,
            0
        );
    }
}
