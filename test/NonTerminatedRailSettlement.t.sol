// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Payments, IArbiter} from "../src/Payments.sol";
import {ERC1967Proxy} from "../src/ERC1967Proxy.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockArbiter} from "./mocks/MockArbiter.sol";
import {PaymentsTestHelpers} from "./helpers/PaymentsTestHelpers.sol";
import {RailSettlementHelpers} from "./helpers/RailSettlementHelpers.sol";
import {console} from "forge-std/console.sol";

contract NonTerminatedRailSettlementTest is Test {
    Payments payments;
    MockERC20 token;
    PaymentsTestHelpers helper;
    RailSettlementHelpers settlementHelper;

    address owner = address(0x1);
    address client = address(0x2);
    address recipient = address(0x3);
    address operator = address(0x4);
    address recipient2 = address(0x5);

    uint256 constant INITIAL_BALANCE = 5000 ether;
    uint256 constant DEPOSIT_AMOUNT = 200 ether;

    function setUp() public {
        helper = new PaymentsTestHelpers();
        settlementHelper = new RailSettlementHelpers();
        payments = helper.deployPaymentsSystem(owner);

        // Set up users
        address[] memory users = new address[](3);
        users[0] = client;
        users[1] = recipient;
        users[2] = recipient2;

        // Deploy test token with initial balances and approvals
        token = helper.setupTestToken(
            "Test Token",
            "TEST",
            users,
            INITIAL_BALANCE,
            address(payments)
        );

        // Setup generous operator approval
        helper.setupOperatorApproval(
            payments,
            address(token),
            client,
            operator,
            100 ether, // rateAllowance - increased to support multiple rails
            1000 ether // lockupAllowance - increased to support multiple rails
        );

        // Make initial deposit
        helper.makeDeposit(
            payments,
            address(token),
            client,
            client,
            DEPOSIT_AMOUNT
        );
    }

    //--------------------------------
    // 1. Basic Settlement Flow Tests (No Arbitration, Empty Queue)
    //--------------------------------

    function testBasicSettlement() public {
        // Create a rail with a simple rate
        uint256 rate = 5 ether;
        uint256 railId = helper.setupRailWithParameters(
            payments,
            address(token),
            client,
            recipient,
            operator,
            rate,
            10, // lockupPeriod
            0 // No fixed lockup
        );

        // Record starting balances
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

        // Advance a few blocks
        helper.advanceBlocks(5);

        // Settle for the elapsed blocks
        vm.prank(client);
        (uint256 settledAmount, uint256 settledUpto, ) = payments.settleRail(
            railId,
            block.number
        );

        // Verify settled amount
        uint256 expectedAmount = rate * 5; // 5 blocks * 5 ether
        assertEq(settledAmount, expectedAmount, "Settlement amount incorrect");
        assertEq(
            settledUpto,
            block.number,
            "Settlement should reach current block"
        );

        // Verify balance changes
        settlementHelper.verifySettlementBalances(
            payments,
            address(token),
            client,
            recipient,
            settledAmount,
            clientBefore.funds,
            recipientBefore.funds
        );

        // Verify rail state
        settlementHelper.verifyRailSettlementState(
            payments,
            railId,
            block.number
        );
    }

    function testZeroRateRailSettlement() public {
        // Create a rail with zero rate
        uint256 railId = helper.setupRailWithParameters(
            payments,
            address(token),
            client,
            recipient,
            operator,
            0, // Zero rate
            10, // lockupPeriod
            0 // No fixed lockup
        );

        // Advance several blocks
        helper.advanceBlocks(10);

        // Settle - this should update the settled epoch but transfer no funds
        vm.prank(client);
        (
            uint256 settledAmount,
            uint256 settledUpto,
            string memory note
        ) = payments.settleRail(railId, block.number);

        // Verify no funds were transferred
        assertEq(settledAmount, 0, "Settlement amount should be zero");
        assertEq(
            settledUpto,
            block.number,
            "Settlement should reach current block"
        );
        assertEq(
            note,
            "zero rate payment rail",
            "Note should indicate zero rate rail"
        );

        // Balances should be unchanged
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

        assertEq(
            clientAfter.funds,
            DEPOSIT_AMOUNT,
            "Client funds should not change"
        );
        assertEq(recipientAfter.funds, 0, "Recipient funds should not change");
    }

    function testProgressiveSettlement() public {
        // Create a rail with a moderate rate
        uint256 rate = 10 ether;
        uint256 railId = helper.setupRailWithParameters(
            payments,
            address(token),
            client,
            recipient,
            operator,
            rate,
            10, // lockupPeriod
            0 // No fixed lockup
        );

        // First settlement: advance 3 blocks
        helper.advanceBlocks(3);

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

        // Settle first part
        vm.prank(client);
        (uint256 settledAmount1, uint256 settledUpto1, ) = payments.settleRail(
            railId,
            block.number
        );

        // Verify first settlement
        uint256 expectedAmount1 = rate * 3; // 3 blocks * 10 ether
        assertEq(
            settledAmount1,
            expectedAmount1,
            "First settlement amount incorrect"
        );
        assertEq(
            settledUpto1,
            block.number,
            "First settlement should reach current block"
        );

        // Second settlement: advance 4 more blocks
        helper.advanceBlocks(4);

        // Settle second part
        vm.prank(client);
        (uint256 settledAmount2, uint256 settledUpto2, ) = payments.settleRail(
            railId,
            block.number
        );

        // Verify second settlement
        uint256 expectedAmount2 = rate * 4; // 4 more blocks * 10 ether
        assertEq(
            settledAmount2,
            expectedAmount2,
            "Second settlement amount incorrect"
        );
        assertEq(
            settledUpto2,
            block.number,
            "Second settlement should reach current block"
        );

        // Total transfers should match sum of both settlements
        uint256 totalTransferred = settledAmount1 + settledAmount2;

        // Verify final balances
        settlementHelper.verifySettlementBalances(
            payments,
            address(token),
            client,
            recipient,
            totalTransferred,
            clientBefore.funds,
            recipientBefore.funds
        );
    }

    function testSettleRailInDebt() public {
        uint256 rate = 50 ether;
        uint256 railId = helper.setupRailWithParameters(
            payments,
            address(token),
            client,
            recipient,
            operator,
            rate,
            3, // lockupPeriod
            0 // No fixed lockup
        );

        // so total locked here is 150 (3 * 50 and 0 fixed lockup)

        // Record starting balances before we advance blocks
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

        // advance 7 blocks so we reach block 8
        helper.advanceBlocks(7);

        // at this point, rail needs to have 150 locked, this means rail can only pay out 50 so upto epoch 2
        // (deposit_amount is 200)

        uint256 settledAmount;
        uint256 settledUpto;
        string memory note;

        // Try to settle up to current block (should be limited by available funds)
        vm.prank(client);
        (settledAmount, settledUpto, note) = payments.settleRail(
            railId,
            block.number
        );

        // Expected values based on observed behavior
        uint256 expectedAmount = 50 ether;
        // after accounting for the lockup of 150
        uint256 expectedSettledUpto = 2;
        // Verify settlement was limited by available funds
        assertEq(
            settledAmount,
            expectedAmount,
            "Settlement amount should be limited by available funds"
        );
        assertEq(
            settledUpto,
            expectedSettledUpto,
            "Settlement should only go up to the epoch where funds ran out"
        );

        // Verify rail state reflects the partial settlement
        settlementHelper.verifyRailSettlementState(
            payments,
            railId,
            settledUpto
        );

        // Verify balance changes
        settlementHelper.verifySettlementBalances(
            payments,
            address(token),
            client,
            recipient,
            settledAmount,
            clientBefore.funds,
            recipientBefore.funds
        );

        // Client should have funds left (or zero in this case)
        Payments.Account memory clientAfter = helper.getAccountData(
            payments,
            address(token),
            client
        );
        assertEq(
            clientAfter.funds,
            150 ether,
            "Client should have 150 ether left based on the observed behavior"
        );

        // settling the rail again gets us no funds
        vm.prank(client);
        (settledAmount, settledUpto, note) = payments.settleRail(
            railId,
            block.number
        );

        // Verify no additional settlement occurred
        assertEq(
            settledAmount,
            0,
            "Settlement amount should be zero for second attempt"
        );
        assertEq(
            settledUpto,
            expectedSettledUpto,
            "Settlement should remain at same epoch"
        );

        Payments.Account memory clientAccount = helper.getAccountData(
            payments,
            address(token),
            client
        );
        assertEq(
            clientAccount.lockupCurrent,
            150 ether,
            "Client lockup current should be 150 ether"
        );

        // client deposits funds and then we can settle upto the current epoch
        uint256 additionalDeposit = 300 ether;
        helper.makeDeposit(
            payments,
            address(token),
            client,
            client,
            additionalDeposit
        );

        // we'd only settled upto epoch 2 earlier, this means we need to pay for 6 more epochs to fully settle account lockup
        // which will be 300 ether (rate is 50)

        // Verify client account has the expected lockup (300 for unsettled epochs and 150 for future lockup)
        clientBefore = helper.getAccountData(payments, address(token), client);
        assertEq(
            clientBefore.lockupCurrent,
            450 ether,
            "Client lockup current should be 450 ether"
        );

        recipientBefore = helper.getAccountData(
            payments,
            address(token),
            recipient
        );

        // Try to settle to the current block now with more funds
        vm.prank(client);
        (settledAmount, settledUpto, note) = payments.settleRail(
            railId,
            block.number
        );

        // Verify we can now settle up to the current block
        uint256 expectedNewAmount = rate * 6;

        assertEq(
            settledAmount,
            expectedNewAmount,
            "Settlement amount should match the remaining blocks"
        );
        assertEq(
            settledUpto,
            block.number,
            "Settlement should now reach current block"
        );

        // Verify balance changes after additional settlement
        settlementHelper.verifySettlementBalances(
            payments,
            address(token),
            client,
            recipient,
            settledAmount,
            clientBefore.funds,
            recipientBefore.funds
        );

        // rails still has funds locked for future lockup
        clientAccount = helper.getAccountData(payments, address(token), client);
        assertEq(
            clientAccount.lockupCurrent,
            150 ether,
            "Client lockup current should be 150 ether"
        );

        // advance by 5 blocks so rail is in debt again
        helper.advanceBlocks(7);

        // try to settle normally after debt
        vm.prank(client);
        (settledAmount, settledUpto, note) = payments.settleRail(
            railId,
            block.number
        );

        // Verify no additional settlement occurred
        assertEq(
            settledAmount,
            0,
            "Settlement amount should be zero when rail is in debt"
        );
        assertEq(
            settledUpto,
            8,
            "Settlement epoch should not change when rail is in debt"
        );

        // Now terminate the rail as operator
        vm.prank(operator);
        payments.terminateRail(railId);

        // Record balances before final settlement
        clientBefore = helper.getAccountData(payments, address(token), client);
        recipientBefore = helper.getAccountData(
            payments,
            address(token),
            recipient
        );

        // Settle rail after termination
        vm.prank(client);
        (settledAmount, settledUpto, note) = payments.settleRail(
            railId,
            block.number
        );

        // Verify settlement completed
        assertEq(
            settledAmount,
            150 ether,
            "Settlement amount should be 150 ether after termination"
        );
        assertEq(
            settledUpto,
            11, // 8 epochs fully settled earlier + lockup covers 3 more epochs
            "Settlement should reach current block 11  after termination"
        );

        // Verify balance changes after termination settlement
        settlementHelper.verifySettlementBalances(
            payments,
            address(token),
            client,
            recipient,
            settledAmount,
            clientBefore.funds,
            recipientBefore.funds
        );

        // Verify rail is completely finalized after full settlement
        vm.prank(client);
        vm.expectRevert(
            "rail does not exist or is beyond it's last settlement after termination"
        );
        payments.getRail(railId);

        // Check client's final account state
        clientAccount = helper.getAccountData(payments, address(token), client);
        assertEq(
            clientAccount.lockupCurrent,
            0,
            "Client lockup current should be 0 after rail finalization"
        );
    }

    function testOperatorWithTwoRails() public {
        // Make a larger deposit to support two rails
        uint256 additionalDeposit = 1000 ether;
        helper.makeDeposit(
            payments,
            address(token),
            client,
            client,
            additionalDeposit
        );

        // Total client balance: 1200 ether (200 initial + 1000 additional)

        // Create Rail 1
        uint256 rate1 = 50 ether;
        uint256 lockupPeriod1 = 3; // 3 blocks of lockup
        uint256 railId1 = helper.setupRailWithParameters(
            payments,
            address(token),
            client,
            recipient,
            operator,
            rate1,
            lockupPeriod1,
            0 // No fixed lockup
        );

        // Rail 1 lockup: 150 ether (50 ether * 3 blocks)

        // Create Rail 2 - this one will always have enough funds
        uint256 rate2 = 20 ether;
        uint256 lockupPeriod2 = 5; // 5 blocks of lockup
        uint256 fixedLockup2 = 10 ether; // Initial fixed lockup
        uint256 railId2 = helper.setupRailWithParameters(
            payments,
            address(token),
            client,
            recipient2,
            operator,
            rate2,
            lockupPeriod2,
            fixedLockup2
        );

        // Rail 2 lockup: 110 ether (20 ether * 5 blocks + 10 ether fixed)

        // Total lockup for both rails: 260 ether (150 + 110)

        // Verify initial account state
        Payments.Account memory initialClientAccount = helper.getAccountData(
            payments,
            address(token),
            client
        );
        assertEq(
            initialClientAccount.lockupCurrent,
            260 ether,
            "Initial client lockup current should be 260 ether"
        );
        assertEq(
            initialClientAccount.funds,
            1200 ether,
            "Initial client funds should be 1200 ether"
        );

        // Advance 7 blocks
        helper.advanceBlocks(7);

        // 1. Settle rail 1
        vm.prank(client);
        (uint256 settledAmount1, uint256 settledUpto1, ) = payments.settleRail(
            railId1,
            block.number
        );

        // Verify rail 1 settlement results
        // Total client funds = 1200 ether
        // Rail 1 lockup = 150 ether (50 ether * 3 blocks)
        // Rail 2 lockup = 110 ether (20 ether * 5 blocks + 10 ether fixed)
        // Total lockup = 260 ether
        // Available for settlement = 1200 - 260 = 940 ether
        // This can pay for 940 / 50 = 18.8 = 18 blocks (since rate1 is 50 ether)
        // Therefore, the settlement amount should be 50 ether * (8-1) = 350 ether
        // The -1 is because the rail is already settled at block 1 at creation

        uint256 expectedAmount1 = 350 ether; // 7 blocks * 50 ether
        assertEq(
            settledAmount1,
            expectedAmount1,
            "Rail 1 settlement amount should be 350 ether"
        );

        // Rail should be settled up to block 8
        assertEq(settledUpto1, 8, "Rail 1 should be settled up to block 8");

        Payments.Account memory clientAfterSettlement = helper.getAccountData(
            payments,
            address(token),
            client
        );
        console.log(
            "1. lockupLastSettledAt after settling rail 1:",
            clientAfterSettlement.lockupLastSettledAt
        );

        // 2. Settle rail 2 - should settle up to current epoch (since it has enough funds)
        Payments.Account memory clientBefore2 = helper.getAccountData(
            payments,
            address(token),
            client
        );

        Payments.Account memory recipient2Before = helper.getAccountData(
            payments,
            address(token),
            recipient2
        );

        vm.prank(client);
        (uint256 settledAmount2, uint256 settledUpto2, ) = payments.settleRail(
            railId2,
            block.number
        );

        // Expected settlement values for rail 2
        uint256 expectedAmount2 = rate2 * 7; // 7 blocks * 20 ether = 140 ether
        assertEq(
            settledAmount2,
            expectedAmount2,
            "Rail 2 settlement amount incorrect"
        );
        assertEq(
            settledUpto2,
            block.number,
            "Rail 2 should settle up to current block"
        );

        // Verify balance changes for rail 2
        settlementHelper.verifySettlementBalances(
            payments,
            address(token),
            client,
            recipient2,
            settledAmount2,
            clientBefore2.funds,
            recipient2Before.funds
        );

        // 3. Change rate, lockup period and fixed lockup on rail 2
        uint256 newRate2 = 25 ether;
        uint256 newLockupPeriod2 = 6;
        uint256 newFixedLockup2 = 15 ether;

        // Calculate expected lockup changes
        uint256 oldLockupAmount2 = rate2 * lockupPeriod2 + fixedLockup2; // 20*5 + 10 = 110 ether
        uint256 newLockupAmount2 = newRate2 *
            newLockupPeriod2 +
            newFixedLockup2; // 25*6 + 15 = 165 ether
        uint256 lockupDifference2 = newLockupAmount2 - oldLockupAmount2; // 165 - 110 = 55 ether

        Payments.Account memory clientBeforeModify = helper.getAccountData(
            payments,
            address(token),
            client
        );

        // Modify rail 2 settings
        settlementHelper.modifyRailSettingsAndVerify(
            payments,
            railId2,
            operator,
            newRate2,
            newLockupPeriod2,
            newFixedLockup2
        );

        // Verify client lockup was updated correctly
        Payments.Account memory clientAfterModify = helper.getAccountData(
            payments,
            address(token),
            client
        );
        assertEq(
            clientAfterModify.lockupCurrent,
            clientBeforeModify.lockupCurrent + lockupDifference2,
            "Client lockup should increase by the lockup difference"
        );

        // 4. Make one-time payment from rail 2
        uint256 oneTimePaymentAmount = 10 ether;
        helper.executeOneTimePayment(
            payments,
            railId2,
            operator,
            oneTimePaymentAmount
        );

        // Verify fixed lockup was reduced
        Payments.RailView memory rail2AfterPayment = payments.getRail(railId2);
        assertEq(
            rail2AfterPayment.lockupFixed,
            newFixedLockup2 - oneTimePaymentAmount,
            "Fixed lockup not reduced correctly after one-time payment"
        );

        helper.advanceBlocks(100);

        clientAfterSettlement = helper.getAccountData(
            payments,
            address(token),
            client
        );
        console.log(
            "2. lockupLastSettledAt before terminating rail 1:",
            clientAfterSettlement.lockupLastSettledAt
        );
        console.log(
            "   Current block number before termination:",
            block.number
        );

        // Get the rail details before termination
        Payments.RailView memory rail1BeforeTermination = payments.getRail(
            railId1
        );
        console.log(
            "   Rail 1 lockupPeriod:",
            rail1BeforeTermination.lockupPeriod
        );
        console.log(
            "   Expected endEpoch calculation:",
            clientAfterSettlement.lockupLastSettledAt +
                rail1BeforeTermination.lockupPeriod
        );

        console.log("CLIENT FUNDS:", clientAfterSettlement.funds);
        console.log("LOCKED FUNDS:", clientAfterSettlement.lockupCurrent);
        console.log("LOCKUP RATE:", clientAfterSettlement.lockupRate);

        // 5. Terminate and settle rail 1
        // IMPORTANT: When terminateRail is called, the settleAccountLockupBeforeAndAfterForRail
        // modifier runs first which calls settleAccountLockup on the client's account.
        //
        // This calculation happens:
        // - Current block: 108
        // - Last explicitly settled: 8
        // - Client has rate2 = 25 ether (after Rail 2 was modified)
        // - Available client funds after previous operations: ~700 ether
        // Out of that 305 is locked (50 *3 for rail 1 + 25 * 6 for rail 2 + 5 for rail2 fixed lockup = 305)
        // So remaining unlocked is 395. So account can be settled for (395 / 75) = 5 epochs.
        // - This advances lockupLastSettledAt from 8 to 13
        //
        // Then terminateRail uses this updated lockupLastSettledAt to calculate:
        // endEpoch = lockupLastSettledAt + lockupPeriod = 13 + 3 = 16 for rail1
        // for rail 2 it will 13 + 6 = 19

        (uint256 settledAmount1Final, uint256 settledUpto11) = settlementHelper
            .terminateAndSettleRail(
                payments,
                railId1,
                client,
                operator,
                recipient,
                address(token)
            );

        assertEq(settledUpto11, 16, "Rail 1 should be settled up to epoch 16");

        (uint256 settledAmount2Final, uint256 settledUpto21) = settlementHelper
            .terminateAndSettleRail(
                payments,
                railId2,
                client,
                operator,
                recipient2,
                address(token)
            );

        assertEq(settledUpto21, 19, "Rail 2 should be settled up to epoch 19");

        // Final account check - all lockups should be gone
        Payments.Account memory finalClientAccount = helper.getAccountData(
            payments,
            address(token),
            client
        );

        // We're not checking lockupCurrent because the test is not fully finalizing all rails
        // which may leave some lockup still in place
        assertEq(
            finalClientAccount.lockupCurrent,
            0,
            "Final client lockup should be 0"
        );

        // But we do expect the lockup rate to be zero as both rails should have their rates removed
        assertEq(
            finalClientAccount.lockupRate,
            0,
            "Final client lockup rate should be 0"
        );

        // Calculate expected remaining funds:
        // Initial funds = 1200 ether (200 initial + 1000 additional)
        //
        // Outgoing funds:
        // - Rail 1 initial settlement: 350 ether (7 blocks * 50 ether)
        // - Rail 2 initial settlement: 140 ether (7 blocks * 20 ether)
        // - One-time payment from Rail 2: 10 ether
        // - Rail 1 final settlement: 400 ether (settled from epochs 9-16)
        // - Rail 2 final settlement: (settled amount varies, captured in settledAmount2Final)
        //
        // So remaining funds should be 1200 ether minus all the payments above
        uint256 expectedRemainingFunds = 1200 ether -
            (settledAmount1 +
                settledAmount1Final +
                settledAmount2 +
                oneTimePaymentAmount +
                settledAmount2Final);

        assertEq(
            finalClientAccount.funds,
            expectedRemainingFunds,
            "Final client funds incorrect"
        );
    }

    //--------------------------------
    // 2. Arbitration Scenarios (No Rate Changes)
    //--------------------------------

    function testBasicArbitrationFullApproval() public {
        // Deploy a standard arbiter that approves everything
        MockArbiter arbiter = new MockArbiter(MockArbiter.ArbiterMode.STANDARD);

        // Create a rail with the arbiter
        uint256 rate = 5 ether;
        uint256 railId = settlementHelper.setupRailWithArbiter(
            payments,
            address(token),
            client,
            recipient,
            operator,
            address(arbiter),
            rate, // 5 ether per block
            10, // lockupPeriod
            0 // No fixed lockup
        );

        // Record starting balances
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

        // Advance several blocks
        helper.advanceBlocks(5);

        // Settle with arbitration
        vm.prank(client);
        (
            uint256 settledAmount,
            uint256 settledUpto,
            string memory note
        ) = payments.settleRail(railId, block.number);

        // Verify that the arbiter approved the full amount
        uint256 expectedAmount = rate * 5; // 5 blocks * 5 ether
        assertEq(
            settledAmount,
            expectedAmount,
            "Arbiter should approve full amount"
        );
        assertEq(
            settledUpto,
            block.number,
            "Arbiter should approve full duration"
        );
        assertEq(
            note,
            "Standard approved payment",
            "Arbiter note should match"
        );

        // Verify balance changes
        settlementHelper.verifySettlementBalances(
            payments,
            address(token),
            client,
            recipient,
            settledAmount,
            clientBefore.funds,
            recipientBefore.funds
        );
    }

    function testArbitrationWithReducedAmount() public {
        // Deploy an arbiter that reduces payment amounts
        MockArbiter arbiter = new MockArbiter(
            MockArbiter.ArbiterMode.REDUCE_AMOUNT
        );
        arbiter.configure(80); // 80% of the original amount

        // Create a rail with the arbiter
        uint256 rate = 10 ether;
        uint256 railId = settlementHelper.setupRailWithArbiter(
            payments,
            address(token),
            client,
            recipient,
            operator,
            address(arbiter),
            rate, // 10 ether per block
            10, // lockupPeriod
            0 // No fixed lockup
        );

        // Record starting balances
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

        // Advance several blocks
        helper.advanceBlocks(5);

        // Settle with reduced amount arbitration
        vm.prank(client);
        (
            uint256 settledAmount,
            uint256 settledUpto,
            string memory note
        ) = payments.settleRail(railId, block.number);

        // Verify that the arbiter reduced the amount
        uint256 expectedAmount = (rate * 5 * 80) / 100; // 5 blocks * 10 ether * 80%
        assertEq(
            settledAmount,
            expectedAmount,
            "Amount should be reduced by arbiter"
        );
        assertEq(
            settledUpto,
            block.number,
            "Settlement should reach current block"
        );
        assertEq(
            note,
            "Arbiter reduced payment amount",
            "Arbiter note should match"
        );

        // Verify balance changes
        settlementHelper.verifySettlementBalances(
            payments,
            address(token),
            client,
            recipient,
            settledAmount,
            clientBefore.funds,
            recipientBefore.funds
        );
    }

    function testArbitrationWithReducedDuration() public {
        // Deploy an arbiter that reduces settlement duration
        MockArbiter arbiter = new MockArbiter(
            MockArbiter.ArbiterMode.REDUCE_DURATION
        );
        arbiter.configure(60); // 60% of the original duration

        // Create a rail with the arbiter
        uint256 rate = 5 ether;
        uint256 railId = settlementHelper.setupRailWithArbiter(
            payments,
            address(token),
            client,
            recipient,
            operator,
            address(arbiter),
            rate, // 5 ether per block
            10, // lockupPeriod
            0 // No fixed lockup
        );

        // Advance several blocks
        uint256 blocksToAdvance = 10;
        helper.advanceBlocks(blocksToAdvance);

        // Settle with reduced duration arbitration
        vm.prank(client);
        (
            ,
            // settledAmount not used
            uint256 settledUpto,
            string memory note
        ) = payments.settleRail(railId, block.number);

        // Verify settlement with reduced duration
        assertLt(
            settledUpto,
            block.number,
            "Settlement should not reach current block"
        );
        assertEq(
            note,
            "Arbiter reduced settlement duration",
            "Arbiter note should match"
        );

        // Verify rail state reflects the partial settlement
        settlementHelper.verifyRailSettlementState(
            payments,
            railId,
            settledUpto
        );
    }

    function testMaliciousArbiterHandling() public {
        // Deploy a malicious arbiter
        MockArbiter arbiter = new MockArbiter(
            MockArbiter.ArbiterMode.MALICIOUS
        );

        // Create a rail with the arbiter
        uint256 rate = 5 ether;
        uint256 railId = settlementHelper.setupRailWithArbiter(
            payments,
            address(token),
            client,
            recipient,
            operator,
            address(arbiter),
            rate, // 5 ether per block
            10, // lockupPeriod
            0 // No fixed lockup
        );

        // Advance several blocks
        helper.advanceBlocks(5);

        // Attempt settlement with malicious arbiter - should revert
        vm.prank(client);
        vm.expectRevert("arbiter settled beyond segment end"); // Contract should detect invalid end epoch
        payments.settleRail(railId, block.number);

        // Set the arbiter to return invalid amount but valid settlement duration
        arbiter.setMode(MockArbiter.ArbiterMode.CUSTOM_RETURN);
        uint256 proposedAmount = rate * 5; // 5 blocks * 5 ether
        uint256 invalidAmount = proposedAmount * 2; // Double the correct amount
        arbiter.setCustomValues(
            invalidAmount,
            block.number,
            "Attempting excessive payment"
        );

        // Attempt settlement with excessive amount
        vm.prank(client);
        vm.expectRevert(
            "arbiter modified amount exceeds maximum for settled duration"
        );
        payments.settleRail(railId, block.number);
    }

    //--------------------------------
    // 5. Edge Cases and Boundary Testing
    //--------------------------------

    function testSettlementAtCurrentBlockExactly() public {
        // Create a rail with a standard rate
        uint256 rate = 5 ether;
        uint256 railId = helper.setupRailWithParameters(
            payments,
            address(token),
            client,
            recipient,
            operator,
            rate,
            10, // lockupPeriod
            0 // No fixed lockup
        );

        // Record starting balances
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

        // Save initial block
        uint256 initialBlock = block.number;

        // Settle immediately - this should be a no-op since we're already settled to the current block
        vm.prank(client);
        (uint256 settledAmount, uint256 settledUpto, ) = payments.settleRail(
            railId,
            block.number
        );

        // Verify no settlement
        assertEq(settledAmount, 0, "Settlement amount should be zero");
        assertEq(
            settledUpto,
            initialBlock,
            "Settlement should already be at current block"
        );

        // Advance exactly one block
        helper.advanceBlocks(1);

        // Settle for one block
        vm.prank(client);
        (uint256 settledAmount2, uint256 settledUpto2, ) = payments.settleRail(
            railId,
            block.number
        );

        // Verify one-block settlement
        assertEq(
            settledAmount2,
            rate,
            "Settlement amount should be one block's rate"
        );
        assertEq(
            settledUpto2,
            block.number,
            "Settlement should reach current block"
        );

        // Verify balance changes
        settlementHelper.verifySettlementBalances(
            payments,
            address(token),
            client,
            recipient,
            settledAmount2,
            clientBefore.funds,
            recipientBefore.funds
        );
    }

    function testSettlementWithMinimumDuration() public {
        // Create a rail with minimum duration (1 epoch)
        uint256 rate = 5 ether;
        uint256 railId = helper.setupRailWithParameters(
            payments,
            address(token),
            client,
            recipient,
            operator,
            rate,
            1, // Minimum lockupPeriod
            0 // No fixed lockup
        );

        // Record starting balances
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

        // Advance one block
        helper.advanceBlocks(1);

        // Settle
        vm.prank(client);
        (uint256 settledAmount, uint256 settledUpto, ) = payments.settleRail(
            railId,
            block.number
        );

        // Verify settlement
        assertEq(
            settledAmount,
            rate,
            "Settlement amount should be one block's rate"
        );
        assertEq(
            settledUpto,
            block.number,
            "Settlement should reach current block"
        );

        // Verify rail state
        settlementHelper.verifyRailSettlementState(
            payments,
            railId,
            block.number
        );

        // Verify balance changes
        settlementHelper.verifySettlementBalances(
            payments,
            address(token),
            client,
            recipient,
            settledAmount,
            clientBefore.funds,
            recipientBefore.funds
        );
    }

    function testAttemptToSettleFutureEpochs() public {
        // Create a rail with standard rate
        uint256 rate = 5 ether;
        uint256 railId = helper.setupRailWithParameters(
            payments,
            address(token),
            client,
            recipient,
            operator,
            rate,
            10, // lockupPeriod
            0 // No fixed lockup
        );

        // Attempt to settle for a future block
        vm.prank(client);
        vm.expectRevert("failed to settle: cannot settle future epochs");
        payments.settleRail(railId, block.number + 5);
    }

    function testAttemptToSettleInvalidRail() public {
        // Try to settle a non-existent rail
        uint256 invalidRailId = 9999;

        vm.prank(client);
        vm.expectRevert(
            "rail does not exist or is beyond it's last settlement after termination"
        );
        payments.settleRail(invalidRailId, block.number);
    }

    function testSettleAlreadyFullySettledRail() public {
        // Create a rail with standard rate
        uint256 rate = 5 ether;
        uint256 railId = helper.setupRailWithParameters(
            payments,
            address(token),
            client,
            recipient,
            operator,
            rate,
            10, // lockupPeriod
            0 // No fixed lockup
        );

        // Settle immediately without advancing blocks - should be a no-op
        vm.prank(client);
        (
            uint256 settledAmount1, // settledUpto1 not used
            ,
            string memory note1
        ) = payments.settleRail(railId, block.number);

        // Verify no settlement occurred
        assertEq(settledAmount1, 0, "Settlement amount should be zero");
        assertTrue(
            bytes(note1).length > 0 &&
                stringsEqual(
                    note1,
                    string.concat(
                        "already settled up to epoch ",
                        vm.toString(block.number)
                    )
                ),
            "Note should indicate already settled"
        );
    }

    //--------------------------------
    // Helper Functions
    //--------------------------------

    // Helper to compare strings (not provided by Forge)
    function stringsEqual(
        string memory a,
        string memory b
    ) internal pure returns (bool) {
        return keccak256(abi.encodePacked(a)) == keccak256(abi.encodePacked(b));
    }
}
