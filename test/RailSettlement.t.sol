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
        vm.prank(USER1);
        settlementHelper.settleRailAndVerify(railId, block.number, expectedAmount, expectedEpoch);
        
        // Settle again - should be a no-op since we're already settled to the expected epoch
        vm.prank(USER1);
        settlementHelper.settleRailAndVerify(railId, block.number, 0, expectedEpoch);
        
        // Add more funds and settle again
        uint256 additionalDeposit = 300 ether;
        helper.makeDeposit(USER1, USER1, additionalDeposit);
        
        // Should be able to settle the remaining 6 epochs
        uint256 expectedAmount2 = rate * 6; // 6 more epochs * 50 ether
        
        // Third settlement
        vm.prank(USER1);
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
        vm.prank(USER1);
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

        // Settle with arbitration
        vm.prank(USER1);
        RailSettlementHelpers.SettlementResult memory result = 
            settlementHelper.settleRailAndVerify(railId, block.number, expectedAmount, block.number);
        
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
        vm.prank(USER1);
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
        vm.prank(USER1);
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
        (uint256 settledAmount, uint256 settledUpto,) = 
            payments.settleRail(railId, block.number);
        
        // Should settle up to endEpoch, which is lockupPeriod blocks after the last settlement
        uint256 expectedAmount2 = rate * lockupPeriod; // lockupPeriod = 5 blocks
        assertEq(settledAmount, expectedAmount2, "Final settlement amount incorrect");
        assertEq(settledUpto, rail.endEpoch, "Final settled up to incorrect");

        // Get balances after settlement
        Payments.Account memory userAfter = helper.getAccountData(USER1);
        Payments.Account memory recipientAfter = helper.getAccountData(USER2);
        
        assertEq(userBefore.funds - userAfter.funds, expectedAmount2, "User funds not reduced correctly in final settlement");
        assertEq(recipientAfter.funds - recipientBefore.funds, expectedAmount2, "Recipient funds not increased correctly in final settlement");
        
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
        vm.prank(USER1);
        RailSettlementHelpers.SettlementResult memory result = 
            settlementHelper.settleRailAndVerify(railId, block.number, 0, block.number);

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
}
