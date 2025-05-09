// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Payments, IArbiter} from "../src/Payments.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockArbiter} from "./mocks/MockArbiter.sol";
import {PaymentsTestHelpers} from "./helpers/PaymentsTestHelpers.sol";
import {RailSettlementHelpers} from "./helpers/RailSettlementHelpers.sol";
import {console} from "forge-std/console.sol";
import {BaseTestHelper} from "./helpers/BaseTestHelper.sol";

contract RailSettlementTest is Test, BaseTestHelper {
    PaymentsTestHelpers helper;
    RailSettlementHelpers settlementHelper;
    Payments payments;
    MockERC20 token;

    uint256 constant INITIAL_BALANCE = 5000 ether;
    uint256 constant DEPOSIT_AMOUNT = 200 ether;

    function setUp() public {
        helper = new PaymentsTestHelpers();
        helper.setupStandardTestEnvironment();
        payments = helper.payments();
        token = MockERC20(address(helper.testToken()));
        
        // Create settlement helper with the helper that has the initialized payment contract
        settlementHelper = new RailSettlementHelpers();
        // Initialize the settlement helper with our Payments instance
        settlementHelper.initialize(payments, helper);
        
        // Make deposits to test accounts for testing
        helper.makeDeposit(USER1, USER1, DEPOSIT_AMOUNT);
    }

    //--------------------------------
    // 1. Basic Settlement Flow Tests
    //--------------------------------

    function testBasicSettlement() public {
        // Create a rail with a simple rate
        uint256 rate = 5 ether;
        uint256 railId = helper.setupRailWithParameters(
            USER1,
            USER2,
            OPERATOR,
            rate,
            10, // lockupPeriod
            0, // No fixed lockup
            address(0) // No arbiter
        );

        // Advance a few blocks
        helper.advanceBlocks(5);

        // Settle for the elapsed blocks
        uint256 expectedAmount = rate * 5; // 5 blocks * 5 ether
        console.log("block.number", block.number);

        settlementHelper.settleRailAndVerify(railId, block.number, expectedAmount, block.number);
    }

    function testSettleRailInDebt() public {
        uint256 rate = 50 ether;
        uint256 railId = helper.setupRailWithParameters(
            USER1,
            USER2,
            OPERATOR,
            rate,
            3, // lockupPeriod - total locked: 150 ether (3 * 50)
            0, // No fixed lockup
            address(0)
        );

        // Advance 7 blocks
        helper.advanceBlocks(7);
        
        // With 200 ether deposit and 150 ether locked, we can only pay for 1 epoch (50 ether)
        uint256 expectedAmount = 50 ether;
        uint256 expectedEpoch = 2; // Initial epoch (1) + 1 epoch
        
        // First settlement
        settlementHelper.settleRailAndVerify(railId, block.number, expectedAmount, expectedEpoch);
        
        // Settle again - should be a no-op since we're already settled to the expected epoch
        settlementHelper.settleRailAndVerify(railId, block.number, 0, expectedEpoch);
        
        // Add more funds and settle again
        uint256 additionalDeposit = 300 ether;
        helper.makeDeposit(USER1, USER1, additionalDeposit);
        
        // Should be able to settle the remaining 6 epochs
        uint256 expectedAmount2 = rate * 6; // 6 more epochs * 50 ether
        
        // Third settlement
        settlementHelper.settleRailAndVerify(railId, block.number, expectedAmount2, block.number);
    }

    //--------------------------------
    // 2. Arbitration Scenarios
    //--------------------------------

    function testArbitrationWithStandardApproval() public {
        // Deploy a standard arbiter that approves everything
        MockArbiter arbiter = new MockArbiter(MockArbiter.ArbiterMode.STANDARD);

        // Create a rail with the arbiter
        uint256 rate = 5 ether;
        uint256 railId = helper.setupRailWithParameters(
            USER1,
            USER2,
            OPERATOR,
            rate,
            10, // lockupPeriod
            0, // No fixed lockup
            address(arbiter) // Standard arbiter
        );

        // Advance several blocks
        helper.advanceBlocks(5);

        // Verify standard arbiter approves full amount
        uint256 expectedAmount = rate * 5; // 5 blocks * 5 ether

        // Settle with arbitration
        RailSettlementHelpers.SettlementResult memory result = 
            settlementHelper.settleRailAndVerify(railId, block.number, expectedAmount, block.number);
        
        // Verify arbiter note
        assertEq(result.note, "Standard approved payment", "Arbiter note should match");
    }

    function testArbitrationWithMultipleRateChanges() public {
        // Deploy a standard arbiter that approves everything
        MockArbiter arbiter = new MockArbiter(MockArbiter.ArbiterMode.STANDARD);

        // Setup operator approval first
        helper.setupOperatorApproval(
            USER1, // from
            OPERATOR,
            10,
            100 ether
        );

        // Create a rail with the arbiter
        uint256 rate = 1;
        uint256 expectedAmount = 0;
        uint256 railId = helper.setupRailWithParameters(
            USER1,
            USER2,
            OPERATOR,
            rate,
            10, // lockupPeriod
            0, // No fixed lockup
            address(arbiter) // Standard arbiter
        );

        vm.startPrank(OPERATOR);
        while (rate++ < 10) {
            // Advance several blocks
            payments.modifyRailPayment(railId, rate, 0);
            expectedAmount += rate * 5;
            helper.advanceBlocks(5);
        }
        vm.stopPrank();

        // Settle with arbitration
        RailSettlementHelpers.SettlementResult memory result =
            settlementHelper.settleRailAndVerify(railId, block.number, expectedAmount, block.number);

         // Verify arbiter note
         assertEq(result.note, "Standard approved payment", "Arbiter note should match");
    }

    function testArbitrationWithReducedAmount() public {
        // Deploy an arbiter that reduces payment amounts
        MockArbiter arbiter = new MockArbiter(MockArbiter.ArbiterMode.REDUCE_AMOUNT);
        arbiter.configure(80); // 80% of the original amount

        // Create a rail with the arbiter
        uint256 rate = 10 ether;
        uint256 railId = helper.setupRailWithParameters(
            USER1,
            USER2,
            OPERATOR,
            rate,
            10, // lockupPeriod
            0, // No fixed lockup
            address(arbiter) // Reduced amount arbiter
        );

        // Advance several blocks
        helper.advanceBlocks(5);

        // Verify reduced amount (80% of original)
        uint256 expectedAmount = (rate * 5 * 80) / 100; // 5 blocks * 10 ether * 80%

        // Calculate expected contract fee (1% of the arbitrated amount)
        uint256 paymentFee = (expectedAmount * payments.PAYMENT_FEE_BPS()) / payments.COMMISSION_MAX_BPS();
        uint256 netPayeeAmount = expectedAmount - paymentFee;

        // Capture fee balance before settlement
        uint256 feesBefore = payments.accumulatedFees(address(token));

        // Settle with arbitration - verify against NET payee amount
        RailSettlementHelpers.SettlementResult memory result = 
            settlementHelper.settleRailAndVerify(railId, block.number, expectedAmount, block.number);
        
        // Verify accumulated fees increased correctly
        uint256 feesAfter = payments.accumulatedFees(address(token));
        assertEq(feesAfter, feesBefore + paymentFee, "Accumulated fees did not increase correctly");
        assertEq(result.netPayeeAmount, netPayeeAmount, "Net payee amount incorrect");
        assertEq(result.paymentFee, paymentFee, "Payment fee incorrect");
        assertEq(result.operatorCommission, 0, "Operator commission incorrect");

        // Verify arbiter note
        assertEq(result.note, "Arbiter reduced payment amount", "Arbiter note should match");
    }

    function testArbitrationWithReducedDuration() public {
        // Deploy an arbiter that reduces settlement duration
        MockArbiter arbiter = new MockArbiter(MockArbiter.ArbiterMode.REDUCE_DURATION);
        arbiter.configure(60); // 60% of the original duration

        // Create a rail with the arbiter
        uint256 rate = 10 ether;
        uint256 railId = helper.setupRailWithParameters(
            USER1,
            USER2,
            OPERATOR,
            rate,
            10, // lockupPeriod
            0, // No fixed lockup
            address(arbiter) // Reduced duration arbiter
        );

        // Advance several blocks
        uint256 advanceBlocks = 5;
        helper.advanceBlocks(advanceBlocks);

        // Calculate expected settlement duration (60% of 5 blocks)
        uint256 expectedDuration = (advanceBlocks * 60) / 100;
        uint256 expectedSettledUpto = block.number - advanceBlocks + expectedDuration;
        uint256 expectedAmount = rate * expectedDuration; // expectedDuration blocks * 10 ether

        // Settle with arbitration
        RailSettlementHelpers.SettlementResult memory result = 
            settlementHelper.settleRailAndVerify(railId, block.number, expectedAmount, expectedSettledUpto);
        
        // Verify arbiter note
        assertEq(result.note, "Arbiter reduced settlement duration", "Arbiter note should match");
    }

    function testMaliciousArbiterHandling() public {
        // Deploy a malicious arbiter
        MockArbiter arbiter = new MockArbiter(MockArbiter.ArbiterMode.MALICIOUS);

        // Create a rail with the arbiter
        uint256 rate = 5 ether;
        uint256 railId = helper.setupRailWithParameters(
            USER1,
            USER2,
            OPERATOR,
            rate,
            10, // lockupPeriod
            0, // No fixed lockup
            address(arbiter) // Malicious arbiter
        );

        // Advance several blocks
        helper.advanceBlocks(5);

        // Attempt settlement with malicious arbiter - should revert
        vm.prank(USER1);
        vm.expectRevert("arbiter settled beyond segment end");
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

        // Attempt settlement with excessive amount - should also revert
        vm.prank(USER1);
        vm.expectRevert("arbiter modified amount exceeds maximum for settled duration");
        payments.settleRail(railId, block.number);
    }

    //--------------------------------
    // 3. Termination and Edge Cases
    //--------------------------------

    function testRailTerminationAndSettlement() public {
        uint256 rate = 10 ether;
        uint256 lockupPeriod = 5;
        uint256 railId = helper.setupRailWithParameters(
            USER1,
            USER2,
            OPERATOR,
            rate,
            lockupPeriod, // lockupPeriod
            0, // No fixed lockup
            address(0) // No arbiter
        );

        // Advance several blocks
        helper.advanceBlocks(3);

        // First settlement
        uint256 expectedAmount1 = rate * 3; // 3 blocks * 10 ether
        settlementHelper.settleRailAndVerify(railId, block.number, expectedAmount1, block.number);
        
        // Terminate the rail
        vm.prank(OPERATOR);
        payments.terminateRail(railId);

        // Verify rail was terminated - check endEpoch is set
        Payments.RailView memory rail = payments.getRail(railId);
        assertTrue(rail.endEpoch > 0, "Rail should be terminated");
        
        // Verify endEpoch calculation: should be the lockupLastSettledAt (current block) + lockupPeriod
        Payments.Account memory account = helper.getAccountData(USER1);
        assertEq(rail.endEpoch, account.lockupLastSettledAt + rail.lockupPeriod, 
            "End epoch should be account lockup last settled at + lockup period");

        // Advance more blocks
        helper.advanceBlocks(10);

        // Get balances before final settlement
        Payments.Account memory userBefore = helper.getAccountData(USER1);
        Payments.Account memory recipientBefore = helper.getAccountData(USER2);

        // Final settlement after termination 
        vm.prank(USER1);

        (uint256 settledAmount, uint256 netPayeeAmount, uint256 paymentFee, , uint256 settledUpto,) = 

            payments.settleRail(railId, block.number);
        
        // Should settle up to endEpoch, which is lockupPeriod blocks after the last settlement
        uint256 expectedAmount2 = rate * lockupPeriod; // lockupPeriod = 5 blocks
        assertEq(settledAmount, expectedAmount2, "Final settlement amount incorrect");
        assertEq(settledUpto, rail.endEpoch, "Final settled up to incorrect");

        // Get balances after settlement
        Payments.Account memory userAfter = helper.getAccountData(USER1);
        Payments.Account memory recipientAfter = helper.getAccountData(USER2);
        
        assertEq(userBefore.funds - userAfter.funds, expectedAmount2, "User funds not reduced correctly in final settlement");
        assertEq(recipientAfter.funds - recipientBefore.funds, netPayeeAmount, "Recipient funds not increased correctly in final settlement");
        
        // Verify account lockup is cleared after full settlement
        assertEq(userAfter.lockupCurrent, 0, "Account lockup should be cleared after full rail settlement");
        assertEq(userAfter.lockupRate, 0, "Account lockup rate should be zero after full rail settlement");
    }

    function testSettleAlreadyFullySettledRail() public {
        // Create a rail with standard rate
        uint256 rate = 5 ether;
        uint256 railId = helper.setupRailWithParameters(
            USER1,
            USER2,
            OPERATOR,
            rate,
            10, // lockupPeriod
            0, // No fixed lockup
            address(0) // No arbiter
        );

        // Settle immediately without advancing blocks - should be a no-op
        RailSettlementHelpers.SettlementResult memory result = 
            settlementHelper.settleRailAndVerify(railId, block.number, 0, block.number);

        console.log("result.note", result.note);

        // Verify the note indicates already settled
        assertTrue(
            bytes(result.note).length > 0 &&
                stringsEqual(
                    result.note,
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

    // Helper to compare strings
    function stringsEqual(
        string memory a,
        string memory b
    ) internal pure returns (bool) {
        return keccak256(abi.encodePacked(a)) == keccak256(abi.encodePacked(b));
    }

    function testPayeeCommissionLimitEnforcement() public {
        // Setup operator approval first
        helper.setupOperatorApproval(
            USER1, // from
            OPERATOR,
            10 ether, // rate allowance (arbitrary for this test)
            100 ether // lockup allowance (arbitrary for this test)
        );

        // Payee (USER2) sets a max commission limit of 5% (500 BPS)
        uint256 payeeLimitBps = 500;
        vm.startPrank(USER2);
        payments.setPayeeMaxCommission(address(token), payeeLimitBps);
        vm.stopPrank();

        // Attempt 1: Operator tries to create rail exceeding the limit (501 BPS)
        uint256 exceedingCommissionBps = payeeLimitBps + 1;
        vm.startPrank(OPERATOR);
        vm.expectRevert(bytes("commission exceeds payee limit"));
        payments.createRail(
            address(token),
            USER1,          // from
            USER2,          // to (payee with limit)
            address(0),     // arbiter
            exceedingCommissionBps
        );
        vm.stopPrank();

        // Attempt 2: Operator tries to create rail exactly at the limit (500 BPS)
        uint256 matchingCommissionBps = payeeLimitBps;
        vm.startPrank(OPERATOR);
        // This call should succeed (no revert)
        uint256 railId1 = payments.createRail(
            address(token),
            USER1,
            USER2,
            address(0),
            matchingCommissionBps
        );
        vm.stopPrank();
        // Verify commission was set
        Payments.RailView memory rail1 = payments.getRail(railId1);
        assertEq(rail1.commissionRateBps, matchingCommissionBps, "Rail 1 commission mismatch");

        // Attempt 3: Operator tries to create rail below the limit (0 BPS)
        uint256 lowerCommissionBps = 0;
        vm.startPrank(OPERATOR);
        // This call should also succeed (no revert)
        uint256 railId2 = payments.createRail(
            address(token),
            USER1,
            USER2,
            address(0),
            lowerCommissionBps
        );
        vm.stopPrank();
        // Verify commission was set
        Payments.RailView memory rail2 = payments.getRail(railId2);
        assertEq(rail2.commissionRateBps, lowerCommissionBps, "Rail 2 commission mismatch");
    }

    function testSettlementWithOperatorCommission() public {
        // Setup operator approval first
        helper.setupOperatorApproval(
            USER1, // from
            OPERATOR,
            10 ether, // rate allowance 
            100 ether // lockup allowance
        );

        // Create rail with 2% operator commission (200 BPS)
        uint256 operatorCommissionBps = 200;
        uint256 railId;
        vm.startPrank(OPERATOR);
        railId = payments.createRail(
            address(token),
            USER1,
            USER2,
            address(0), // no arbiter
            operatorCommissionBps
        );
        vm.stopPrank();

        // Set rail parameters using modify functions
        uint256 rate = 10 ether;
        uint256 lockupPeriod = 5;
        vm.startPrank(OPERATOR);
        payments.modifyRailPayment(railId, rate, 0);
        payments.modifyRailLockup(railId, lockupPeriod, 0); // no fixed lockup
        vm.stopPrank();

        // Advance time
        uint256 elapsedBlocks = 5;
        helper.advanceBlocks(elapsedBlocks);

        // --- Balances Before ---        
        Payments.Account memory payerBefore = helper.getAccountData(USER1);
        Payments.Account memory payeeBefore = helper.getAccountData(USER2);
        Payments.Account memory operatorBefore = helper.getAccountData(OPERATOR);
        uint256 feesBefore = payments.accumulatedFees(address(token));

        // --- Settle Rail --- 
        vm.startPrank(USER1); // Any participant can settle
        (uint256 settledAmount, uint256 netPayeeAmount, uint256 paymentFee, uint256 operatorCommission, uint256 settledUpto,) =
            payments.settleRail(railId, block.number);
        vm.stopPrank();

        // --- Expected Calculations --- 
        uint256 expectedSettledAmount = rate * elapsedBlocks;
        uint256 expectedPaymentFee = (expectedSettledAmount * payments.PAYMENT_FEE_BPS()) / payments.COMMISSION_MAX_BPS();
        uint256 amountAfterPaymentFee = expectedSettledAmount - expectedPaymentFee;
        uint256 expectedOperatorCommission = (amountAfterPaymentFee * operatorCommissionBps) / payments.COMMISSION_MAX_BPS();
        uint256 expectedNetPayeeAmount = amountAfterPaymentFee - expectedOperatorCommission;

        // --- Verification --- 

        // 1. Return values from settleRail
        assertEq(settledAmount, expectedSettledAmount, "Returned settledAmount incorrect");
        assertEq(netPayeeAmount, expectedNetPayeeAmount, "Returned netPayeeAmount incorrect");
        assertEq(paymentFee, expectedPaymentFee, "Returned paymentFee incorrect");
        assertEq(operatorCommission, expectedOperatorCommission, "Returned operatorCommission incorrect");
        assertEq(settledUpto, block.number, "Returned settledUpto incorrect");

        // 2. Balances after settlement
        Payments.Account memory payerAfter = helper.getAccountData(USER1);
        Payments.Account memory payeeAfter = helper.getAccountData(USER2);
        Payments.Account memory operatorAfter = helper.getAccountData(OPERATOR);
        uint256 feesAfter = payments.accumulatedFees(address(token));

        assertEq(payerAfter.funds, payerBefore.funds - expectedSettledAmount, "Payer funds mismatch");
        assertEq(payeeAfter.funds, payeeBefore.funds + expectedNetPayeeAmount, "Payee funds mismatch");
        assertEq(operatorAfter.funds, operatorBefore.funds + expectedOperatorCommission, "Operator funds mismatch");
        assertEq(feesAfter, feesBefore + expectedPaymentFee, "Accumulated fees mismatch");

        // --- Test Fees Withdrawal and Subsequent Fee Accumulation ---

        // 3. Check the fee tokens array before withdrawal
        (address[] memory tokensBeforeWithdrawal, uint256[] memory amountsBeforeWithdrawal, uint256 countBeforeWithdrawal) =
            payments.getAllAccumulatedFees();
            
        // Should only have one token with accumulated fees
        assertEq(countBeforeWithdrawal, 1, "Should have 1 fee token before withdrawal");
        assertEq(tokensBeforeWithdrawal[0], address(token), "Fee token address mismatch");
        assertEq(amountsBeforeWithdrawal[0], feesAfter, "Fee amount mismatch");
        
        // 4. Withdraw all accumulated fees
        vm.prank(OWNER);
        payments.withdrawFees(address(token), OWNER, feesAfter);
        
        // Verify fees are now zero but token is still in the array
        (address[] memory tokensAfterWithdrawal, uint256[] memory amountsAfterWithdrawal, uint256 countAfterWithdrawal) = 
            payments.getAllAccumulatedFees();
            
        assertEq(countAfterWithdrawal, 1, "Fee token count should not change after withdrawal");
        assertEq(tokensAfterWithdrawal[0], address(token), "Fee token should remain in array after withdrawal");
        assertEq(amountsAfterWithdrawal[0], 0, "Fee amount should be zero after withdrawal");
        assertEq(payments.accumulatedFees(address(token)), 0, "Accumulated fees should be zero after withdrawal");
        
        // 5. Accumulate more fees by settling again
        // Advance more blocks
        helper.advanceBlocks(5);
        
        vm.prank(USER1);
        (uint256 newSettledAmount, , uint256 newPaymentFee, , ,) = payments.settleRail(railId, block.number);
        
        uint256 expectedNewFee = (newSettledAmount * payments.PAYMENT_FEE_BPS()) / payments.COMMISSION_MAX_BPS();
        assertEq(newPaymentFee, expectedNewFee, "New payment fee incorrect");
        
        // 6. Verify no duplicate tokens were added after resettlement
        (address[] memory tokensAfterResettlement, uint256[] memory amountsAfterResettlement, uint256 countAfterResettlement) = 
            payments.getAllAccumulatedFees();
            
        assertEq(countAfterResettlement, 1, "Should still have only 1 fee token after resettlement");
        assertEq(tokensAfterResettlement[0], address(token), "Fee token address should not change");
        assertEq(amountsAfterResettlement[0], expectedNewFee, "New fee amount incorrect");
        assertEq(payments.accumulatedFees(address(token)), expectedNewFee, "Accumulated fees incorrect after resettlement");
    }
}
