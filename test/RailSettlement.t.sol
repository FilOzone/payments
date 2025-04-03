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
    Payments payments;
    MockERC20 token;

    uint256 constant INITIAL_BALANCE = 5000 ether;
    uint256 constant DEPOSIT_AMOUNT = 200 ether;

    function setUp() public {
        helper = new PaymentsTestHelpers();
        helper.setupStandardTestEnvironment();
        payments = helper.payments();
        token = MockERC20(address(helper.testToken()));
        
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

        // Get payment data before settlement
        Payments.Account memory fromBefore = helper.getAccountData(USER1);
        Payments.Account memory toBefore = helper.getAccountData(USER2);

        // Settle rail
        vm.prank(USER1);
        (uint256 settledAmount, uint256 settledUpto,) = 
            payments.settleRail(railId, block.number);

        // Verify settlement amount
        assertEq(settledAmount, expectedAmount, "Settlement amount incorrect");
        assertEq(settledUpto, block.number, "Settled upto incorrect");

        // Verify account balances changed correctly
        Payments.Account memory fromAfter = helper.getAccountData(USER1);
        Payments.Account memory toAfter = helper.getAccountData(USER2);

        assertEq(fromBefore.funds - fromAfter.funds, settledAmount, "Payer balance not reduced correctly");
        assertEq(toAfter.funds - toBefore.funds, settledAmount, "Recipient balance not increased correctly");
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
        // Get payment data before settlement
        Payments.Account memory fromBefore = helper.getAccountData(USER1);
        Payments.Account memory toBefore = helper.getAccountData(USER2);

        // Settle rail
        vm.prank(USER1);
        (uint256 settledAmount, uint256 settledUpto,) = 
            payments.settleRail(railId, block.number);

        // Verification: With 200 ether deposit and 150 ether locked, the rail can only settle 1 epoch beyond initial
        uint256 expectedAmount = 50 ether;
        uint256 expectedEpoch = 2; // Initial epoch (1) + 1 epoch

        assertEq(settledAmount, expectedAmount, "Settlement amount incorrect");
        assertEq(settledUpto, expectedEpoch, "Settled upto incorrect");

        // Verify account balances changed correctly
        Payments.Account memory fromAfter = helper.getAccountData(USER1);
        Payments.Account memory toAfter = helper.getAccountData(USER2);

        assertEq(fromBefore.funds - fromAfter.funds, settledAmount, "Payer balance not reduced correctly");
        assertEq(toAfter.funds - toBefore.funds, settledAmount, "Recipient balance not increased correctly");

        // Add more funds and settle again
        uint256 additionalDeposit = 300 ether;
        helper.makeDeposit(USER1, USER1, additionalDeposit);

        // Get balances before second settlement
        fromBefore = helper.getAccountData(USER1);
        toBefore = helper.getAccountData(USER2);

        // Settle rail again
        vm.prank(USER1);
        (settledAmount, settledUpto,) = payments.settleRail(railId, block.number);

        // Should be able to settle the remaining 6 epochs
        expectedAmount = rate * 6; // 6 more epochs * 50 ether
        assertEq(settledAmount, expectedAmount, "Second settlement amount incorrect");
        assertEq(settledUpto, block.number, "Second settled upto incorrect");

        // Verify account balances changed correctly
        fromAfter = helper.getAccountData(USER1);
        toAfter = helper.getAccountData(USER2);

        assertEq(fromBefore.funds - fromAfter.funds, settledAmount, "Second payer balance reduction incorrect");
        assertEq(toAfter.funds - toBefore.funds, settledAmount, "Second recipient balance increase incorrect");
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

        // Get payment data before settlement
        Payments.Account memory fromBefore = helper.getAccountData(USER1);
        Payments.Account memory toBefore = helper.getAccountData(USER2);

        // Settle with arbitration
        vm.prank(USER1);
        (uint256 settledAmount, uint256 settledUpto, string memory note) = 
            payments.settleRail(railId, block.number);

        // Verify standard arbiter approves full amount
        uint256 expectedAmount = rate * 5; // 5 blocks * 5 ether
        assertEq(settledAmount, expectedAmount, "Arbiter should approve full amount");
        assertEq(settledUpto, block.number, "Arbiter should approve full duration");
        assertEq(note, "Standard approved payment", "Arbiter note should match");

        // Verify account balances changed correctly
        Payments.Account memory fromAfter = helper.getAccountData(USER1);
        Payments.Account memory toAfter = helper.getAccountData(USER2);

        assertEq(fromBefore.funds - fromAfter.funds, settledAmount, "Payer balance not reduced correctly");
        assertEq(toAfter.funds - toBefore.funds, settledAmount, "Recipient balance not increased correctly");
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

        // Get payment data before settlement
        Payments.Account memory fromBefore = helper.getAccountData(USER1);
        Payments.Account memory toBefore = helper.getAccountData(USER2);

        // Settle with arbitration
        vm.prank(USER1);
        (uint256 settledAmount, uint256 settledUpto, string memory note) = 
            payments.settleRail(railId, block.number);

        // Verify reduced amount (80% of original)
        uint256 expectedAmount = (rate * 5 * 80) / 100; // 5 blocks * 10 ether * 80%
        assertEq(settledAmount, expectedAmount, "Amount should be reduced by arbiter");
        assertEq(settledUpto, block.number, "Settlement should reach current block");
        assertEq(note, "Arbiter reduced payment amount", "Arbiter note should match");

        // Verify account balances changed correctly
        Payments.Account memory fromAfter = helper.getAccountData(USER1);
        Payments.Account memory toAfter = helper.getAccountData(USER2);

        assertEq(fromBefore.funds - fromAfter.funds, settledAmount, "Payer balance not reduced correctly");
        assertEq(toAfter.funds - toBefore.funds, settledAmount, "Recipient balance not increased correctly");
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

        // Settle rail to the current point
        vm.prank(USER1);
        (uint256 settledAmount1, uint256 settledUpto1,) = 
            payments.settleRail(railId, block.number);
        
        uint256 expectedAmount1 = rate * 3; // 3 blocks * 10 ether
        assertEq(settledAmount1, expectedAmount1, "First settlement amount incorrect");
        assertEq(settledUpto1, block.number, "First settled upto incorrect");

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
        Payments.Account memory fromBefore = helper.getAccountData(USER1);
        Payments.Account memory toBefore = helper.getAccountData(USER2);

        // Settle after termination - should be limited to the endEpoch
        vm.prank(USER1);
        (uint256 settledAmount2, uint256 settledUpto2,) = 
            payments.settleRail(railId, block.number);

        // Should settle up to endEpoch, which is 5 more blocks after the last settlement
        uint256 expectedAmount2 = rate * 5; // lockupPeriod = 5 blocks
        assertEq(settledAmount2, expectedAmount2, "Final settlement amount incorrect");
        assertEq(settledUpto2, rail.endEpoch, "Final settled upto should match endEpoch");

        // Verify account balances changed correctly
        Payments.Account memory fromAfter = helper.getAccountData(USER1);
        Payments.Account memory toAfter = helper.getAccountData(USER2);

        assertEq(fromBefore.funds - fromAfter.funds, settledAmount2, "Payer balance not reduced correctly after termination");
        assertEq(toAfter.funds - toBefore.funds, settledAmount2, "Recipient balance not increased correctly after termination");

        // Verify account lockup is cleared after full settlement
        assertEq(fromAfter.lockupCurrent, 0, "Account lockup should be cleared after full rail settlement");
        assertEq(fromAfter.lockupRate, 0, "Account lockup rate should be zero after full rail settlement");
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
        vm.prank(USER1);
        (uint256 settledAmount, uint256 settledUpto, string memory note) = 
            payments.settleRail(railId, block.number);

        // Verify no settlement occurred
        assertEq(settledAmount, 0, "Settlement amount should be zero");
        assertTrue(
            bytes(note).length > 0 &&
                stringsEqual(
                    note,
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
}
