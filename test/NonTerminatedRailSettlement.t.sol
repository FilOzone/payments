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

    uint256 constant INITIAL_BALANCE = 1000 ether;
    uint256 constant DEPOSIT_AMOUNT = 200 ether;

    function setUp() public {
        helper = new PaymentsTestHelpers();
        settlementHelper = new RailSettlementHelpers();
        payments = helper.deployPaymentsSystem(owner);

        // Set up users
        address[] memory users = new address[](2);
        users[0] = client;
        users[1] = recipient;

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
            50 ether, // rateAllowance
            500 ether // lockupAllowance
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
        uint256 expectedAmount = 200 ether;
        // after accounting for the lockup of 150
        uint256 expectedSettledUpto = 5; // we can only settle for 4 epochs here as we dont have more funds

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
            0,
            "Client should have 0 ether left based on the observed behavior"
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
            0 ether,
            "Client lockup current should be 0 ether"
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

        // Verify client account has the expected lockup
        clientAccount = helper.getAccountData(payments, address(token), client);
        assertEq(
            clientAccount.lockupCurrent,
            150 ether,
            "Client lockup current should be 150 ether"
        );

        // Record balances after deposit
        clientBefore = helper.getAccountData(payments, address(token), client);

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
        uint256 blocksToSettle = block.number - expectedSettledUpto;
        uint256 expectedNewAmount = rate * blocksToSettle;

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

        clientAccount = helper.getAccountData(payments, address(token), client);
        assertEq(
            clientAccount.lockupCurrent,
            0 ether,
            "Client lockup current should be 0 ether"
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
