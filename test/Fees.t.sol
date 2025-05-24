// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Payments, IArbiter} from "../src/Payments.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {PaymentsTestHelpers} from "./helpers/PaymentsTestHelpers.sol";
import {RailSettlementHelpers} from "./helpers/RailSettlementHelpers.sol";
import {BaseTestHelper} from "./helpers/BaseTestHelper.sol";
import {console} from "forge-std/console.sol";

contract FeesTest is Test, BaseTestHelper {
    PaymentsTestHelpers helper;
    RailSettlementHelpers settlementHelper;
    Payments payments;

    // Multiple tokens for testing
    MockERC20 token1;
    MockERC20 token2;
    MockERC20 token3;

    uint256 constant INITIAL_BALANCE = 5000 ether;
    uint256 constant DEPOSIT_AMOUNT = 200 ether;
    uint256 constant MAX_LOCKUP_PERIOD = 100;

    // Payment rates for each rail
    uint256 constant RAIL1_RATE = 5 ether;
    uint256 constant RAIL2_RATE = 10 ether;
    uint256 constant RAIL3_RATE = 15 ether;

    // Rail IDs
    uint256 rail1Id;
    uint256 rail2Id;
    uint256 rail3Id;

    function setUp() public {
        // Initialize helpers
        helper = new PaymentsTestHelpers();
        helper.setupStandardTestEnvironment();
        payments = helper.payments();

        settlementHelper = new RailSettlementHelpers();
        settlementHelper.initialize(payments, helper);

        // Set up 3 different tokens
        token1 = MockERC20(address(helper.testToken())); // Use the default token from the helper
        token2 = new MockERC20("Token 2", "TK2");
        token3 = new MockERC20("Token 3", "TK3");

        // Initialize tokens and make deposits
        setupTokensAndDeposits();

        // Create rails with different tokens
        createRails();
    }

    function setupTokensAndDeposits() internal {
        // Mint tokens to users
        // Token 1 is already handled by the helper
        token2.mint(USER1, INITIAL_BALANCE);
        token3.mint(USER1, INITIAL_BALANCE);

        // Approve transfers for all tokens
        vm.startPrank(USER1);
        token1.approve(address(payments), type(uint256).max);
        token2.approve(address(payments), type(uint256).max);
        token3.approve(address(payments), type(uint256).max);
        vm.stopPrank();

        // Make deposits with all tokens
        helper.makeDeposit(USER1, USER1, DEPOSIT_AMOUNT); // Uses token1

        // Make deposits with token2 and token3
        vm.startPrank(USER1);
        payments.deposit(address(token2), USER1, DEPOSIT_AMOUNT);
        payments.deposit(address(token3), USER1, DEPOSIT_AMOUNT);
        vm.stopPrank();
    }

    function createRails() internal {
        // Set up operator approvals for each token
        helper.setupOperatorApproval(
            USER1, // from
            OPERATOR, // operator
            RAIL1_RATE, // rate allowance for token1
            RAIL1_RATE * 10, // lockup allowance (enough for the period)
            MAX_LOCKUP_PERIOD // max lockup period
        );

        // Operator approvals for token2 and token3
        vm.startPrank(USER1);
        payments.setOperatorApproval(
            address(token2),
            OPERATOR,
            true, // approved
            RAIL2_RATE, // rate allowance for token2
            RAIL2_RATE * 10, // lockup allowance (enough for the period)
            MAX_LOCKUP_PERIOD // max lockup period
        );

        payments.setOperatorApproval(
            address(token3),
            OPERATOR,
            true, // approved
            RAIL3_RATE, // rate allowance for token3
            RAIL3_RATE * 10, // lockup allowance (enough for the period)
            MAX_LOCKUP_PERIOD // max lockup period
        );
        vm.stopPrank();

        // Create rails with different tokens
        rail1Id = helper.setupRailWithParameters(
            USER1,
            USER2,
            OPERATOR,
            RAIL1_RATE,
            10, // lockupPeriod
            0, // No fixed lockup
            address(0) // No arbiter
        );

        // Create a rail with token2
        vm.startPrank(OPERATOR);
        rail2Id = payments.createRail(
            address(token2),
            USER1, // from
            USER2, // to
            address(0), // no arbiter
            0 // no commission
        );

        // Set rail2 parameters
        payments.modifyRailPayment(rail2Id, RAIL2_RATE, 0);
        payments.modifyRailLockup(rail2Id, 10, 0); // 10 blocks, no fixed lockup

        // Create a rail with token3
        rail3Id = payments.createRail(
            address(token3),
            USER1, // from
            USER2, // to
            address(0), // no arbiter
            0 // no commission
        );

        // Set rail3 parameters
        payments.modifyRailPayment(rail3Id, RAIL3_RATE, 0);
        payments.modifyRailLockup(rail3Id, 10, 0); // 10 blocks, no fixed lockup
        vm.stopPrank();
    }

    function testGetAllAccumulatedFees() public {
        // First, verify there are no fees initially
        (
            address[] memory initialTokens,
            uint256[] memory initialAmounts,
            uint256 initialCount
        ) = payments.getAllAccumulatedFees();

        // Initially there should be no fees
        assertEq(initialCount, 0, "Initial fee token count should be 0");
        assertEq(
            initialTokens.length,
            0,
            "Initial fee tokens array should be empty"
        );
        assertEq(
            initialAmounts.length,
            0,
            "Initial fee amounts array should be empty"
        );

        // Advance blocks to enable settlement
        helper.advanceBlocks(5); // Advance 5 blocks

        // First round of settlements for all rails
        uint256 rail1FirstExpectedAmount = RAIL1_RATE * 5; // 5 blocks * 5 ether

        // Settle rail1 (token1)
        settlementHelper.settleRailAndVerify(
            rail1Id,
            block.number,
            rail1FirstExpectedAmount,
            block.number
        );

        // Settle rail2 (token2)
        vm.prank(USER1);
        (uint256 settledAmount2, , , , , ) = payments.settleRail(
            rail2Id,
            block.number
        );

        // Settle rail3 (token3)
        vm.prank(USER1);
        (uint256 settledAmount3, , , , , ) = payments.settleRail(
            rail3Id,
            block.number
        );

        // Calculate expected fees based on actual settled amounts (0.1% of settled amounts)
        uint256 rail1FirstFee = (rail1FirstExpectedAmount *
            payments.PAYMENT_FEE_BPS()) / payments.COMMISSION_MAX_BPS();
        uint256 rail2FirstFee = (settledAmount2 * payments.PAYMENT_FEE_BPS()) /
            payments.COMMISSION_MAX_BPS();
        uint256 rail3FirstFee = (settledAmount3 * payments.PAYMENT_FEE_BPS()) /
            payments.COMMISSION_MAX_BPS();

        // Verify fees after first round
        (
            address[] memory firstTokens,
            uint256[] memory firstAmounts,
            uint256 firstCount
        ) = payments.getAllAccumulatedFees();

        assertEq(
            firstCount,
            3,
            "Should have 3 fee tokens after first settlement"
        );
        assertEq(
            firstTokens.length,
            3,
            "Fee tokens array should have 3 elements"
        );
        assertEq(
            firstAmounts.length,
            3,
            "Fee amounts array should have 3 elements"
        );

        // Check the accumulated fees match expected values
        // Need to identify which index corresponds to which token
        uint256 token1Index = findTokenIndex(firstTokens, address(token1));
        uint256 token2Index = findTokenIndex(firstTokens, address(token2));
        uint256 token3Index = findTokenIndex(firstTokens, address(token3));

        assertEq(
            firstAmounts[token1Index],
            rail1FirstFee,
            "Token1 fees incorrect after first settlement"
        );
        assertEq(
            firstAmounts[token2Index],
            rail2FirstFee,
            "Token2 fees incorrect after first settlement"
        );
        assertEq(
            firstAmounts[token3Index],
            rail3FirstFee,
            "Token3 fees incorrect after first settlement"
        );

        // Advance more blocks for the second round of settlements
        helper.advanceBlocks(7); // Advance 7 blocks

        // Second round of settlements
        uint256 rail1SecondExpectedAmount = RAIL1_RATE * 7; // 7 blocks * 5 ether

        // Settle rail1 (token1) again
        settlementHelper.settleRailAndVerify(
            rail1Id,
            block.number,
            rail1SecondExpectedAmount,
            block.number
        );

        // Settle rail2 (token2) again
        vm.prank(USER1);
        (uint256 secondSettledAmount2, , , , , ) = payments.settleRail(
            rail2Id,
            block.number
        );

        // Settle rail3 (token3) again
        vm.prank(USER1);
        (uint256 secondSettledAmount3, , , , , ) = payments.settleRail(
            rail3Id,
            block.number
        );

        // Calculate expected fees for second round - use actual settled amounts
        uint256 rail1SecondFee = (rail1SecondExpectedAmount *
            payments.PAYMENT_FEE_BPS()) / payments.COMMISSION_MAX_BPS();
        uint256 rail2SecondFee = (secondSettledAmount2 *
            payments.PAYMENT_FEE_BPS()) / payments.COMMISSION_MAX_BPS();
        uint256 rail3SecondFee = (secondSettledAmount3 *
            payments.PAYMENT_FEE_BPS()) / payments.COMMISSION_MAX_BPS();

        // Verify total accumulated fees after both rounds
        (
            address[] memory finalTokens,
            uint256[] memory finalAmounts,
            uint256 finalCount
        ) = payments.getAllAccumulatedFees();

        assertEq(
            finalCount,
            3,
            "Should still have 3 fee tokens after second settlement"
        );
        assertEq(
            finalTokens.length,
            3,
            "Fee tokens array should still have 3 elements"
        );
        assertEq(
            finalAmounts.length,
            3,
            "Fee amounts array should still have 3 elements"
        );

        // Get indices again in case the order changed
        token1Index = findTokenIndex(finalTokens, address(token1));
        token2Index = findTokenIndex(finalTokens, address(token2));
        token3Index = findTokenIndex(finalTokens, address(token3));

        // Total expected fees are the sum of both rounds
        uint256 totalExpectedToken1Fees = rail1FirstFee + rail1SecondFee;
        uint256 totalExpectedToken2Fees = rail2FirstFee + rail2SecondFee;
        uint256 totalExpectedToken3Fees = rail3FirstFee + rail3SecondFee;

        // Verify the array values from getAllAccumulatedFees match the direct mapping access
        assertEq(
            finalAmounts[token1Index],
            payments.accumulatedFees(address(token1)),
            "Array token1 fees mismatch"
        );
        assertEq(
            finalAmounts[token2Index],
            payments.accumulatedFees(address(token2)),
            "Array token2 fees mismatch"
        );
        assertEq(
            finalAmounts[token3Index],
            payments.accumulatedFees(address(token3)),
            "Array token3 fees mismatch"
        );

        // Verify the expected calculated fees match the actual accumulated fees
        assertEq(
            payments.accumulatedFees(address(token1)),
            totalExpectedToken1Fees,
            "Direct token1 fees mismatch"
        );
        assertEq(
            payments.accumulatedFees(address(token2)),
            totalExpectedToken2Fees,
            "Direct token2 fees mismatch"
        );
        assertEq(
            payments.accumulatedFees(address(token3)),
            totalExpectedToken3Fees,
            "Direct token3 fees mismatch"
        );
    }

    // Helper function to find a token's index in the returned array
    function findTokenIndex(
        address[] memory tokens,
        address token
    ) internal pure returns (uint256) {
        for (uint256 i = 0; i < tokens.length; i++) {
            if (tokens[i] == token) {
                return i;
            }
        }
        revert("Token not found in array");
    }
}
