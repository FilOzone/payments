// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Payments, IArbiter} from "../../src/Payments.sol";
import {MockArbiter} from "../mocks/MockArbiter.sol";
import {PaymentsTestHelpers} from "./PaymentsTestHelpers.sol";
import {console} from "forge-std/console.sol";

contract RailSettlementHelpers is Test {
    PaymentsTestHelpers public baseHelper;

    constructor() {
        baseHelper = new PaymentsTestHelpers();
    }

    struct SettlementResult {
        uint256 totalAmount;
        uint256 settledUpto;
        string note;
    }

    function createRailWithArbiter(
        Payments payments,
        address token,
        address from,
        address to,
        address operator,
        address arbiter
    ) public returns (uint256) {
        require(
            arbiter != address(0),
            "RailSettlementHelpers: arbiter cannot be zero address"
        );
        vm.startPrank(operator);
        uint256 railId = payments.createRail(token, from, to, arbiter);
        vm.stopPrank();
        return railId;
    }

    function setupRailWithArbiter(
        Payments payments,
        address token,
        address from,
        address to,
        address operator,
        address arbiter,
        uint256 paymentRate,
        uint256 lockupPeriod,
        uint256 lockupFixed
    ) public returns (uint256) {
        require(arbiter != address(0), "Arbiter address cannot be zero");
        uint256 railId = createRailWithArbiter(
            payments,
            token,
            from,
            to,
            operator,
            arbiter
        );

        vm.startPrank(operator);
        payments.modifyRailPayment(railId, paymentRate, 0);
        payments.modifyRailLockup(railId, lockupPeriod, lockupFixed);
        vm.stopPrank();

        return railId;
    }

    function setupRailWithArbitrerAndRateChangeQueue(
        Payments payments,
        address token,
        address from,
        address to,
        address operator,
        address arbiter,
        uint256[] memory rates,
        uint256 lockupPeriod,
        uint256 lockupFixed
    ) public returns (uint256) {
        require(
            arbiter != address(0),
            "RailSettlementHelpers: arbiter cannot be zero address"
        );
        // Initial setup with first rate
        uint256 railId = setupRailWithArbiter(
            payments,
            token,
            from,
            to,
            operator,
            arbiter,
            rates[0],
            lockupPeriod,
            lockupFixed
        );

        // Apply rate changes for the rest of the rates
        vm.startPrank(operator);
        for (uint256 i = 1; i < rates.length; i++) {
            // Each change will enqueue the previous rate
            payments.modifyRailPayment(railId, rates[i], 0);

            // Advance one block to ensure the changes are at different epochs
            vm.roll(block.number + 1);
        }
        vm.stopPrank();

        // Verify the rate change queue length
        Payments.RailView memory rail = payments.getRail(railId);
        assertEq(
            rail.rateChangeQueueLength,
            rates.length - 1,
            "Rate change queue length does not match expected"
        );

        return railId;
    }

    function createInDebtRail(
        Payments payments,
        address token,
        address from,
        address to,
        address operator,
        uint256 paymentRate,
        uint256 lockupPeriod,
        uint256 fundAmount
    ) public returns (uint256) {
        // Create deposit with limited funds
        baseHelper.makeDeposit(payments, token, from, from, fundAmount);

        // Create a rail with specified parameters
        uint256 railId = baseHelper.setupRailWithParameters(
            payments,
            token,
            from,
            to,
            operator,
            paymentRate,
            lockupPeriod,
            0 // No fixed lockup
        );

        // Advance blocks past the lockup period to force the rail into debt
        baseHelper.advanceBlocks(lockupPeriod + 1);

        return railId;
    }

    function deployMockArbiter(
        MockArbiter.ArbiterMode mode
    ) public returns (MockArbiter) {
        return new MockArbiter(mode);
    }

    function settleRailAndVerify(
        Payments payments,
        uint256 railId,
        uint256 untilEpoch,
        uint256 expectedAmount,
        uint256 expectedUpto
    ) public returns (SettlementResult memory result) {
        uint256 settlementAmount;
        uint256 settledUpto;
        string memory note;

        (settlementAmount, settledUpto, note) = payments.settleRail(
            railId,
            untilEpoch
        );

        // Verify results
        assertEq(
            settlementAmount,
            expectedAmount,
            "Settlement amount doesn't match expected"
        );
        assertEq(
            settledUpto,
            expectedUpto,
            "Settled upto doesn't match expected"
        );

        return SettlementResult(settlementAmount, settledUpto, note);
    }

    function verifyRailSettlementState(
        Payments payments,
        uint256 railId,
        uint256 expectedSettledUpto
    ) public view {
        Payments.RailView memory rail = payments.getRail(railId);
        assertEq(
            rail.settledUpTo,
            expectedSettledUpto,
            "Rail settled upto incorrect"
        );
    }

    function verifySettlementBalances(
        Payments payments,
        address token,
        address from,
        address to,
        uint256 settlementAmount,
        uint256 originalFromBalance,
        uint256 originalToBalance
    ) public view {
        Payments.Account memory fromAccount = baseHelper.getAccountData(
            payments,
            token,
            from
        );
        Payments.Account memory toAccount = baseHelper.getAccountData(
            payments,
            token,
            to
        );

        assertEq(
            fromAccount.funds,
            originalFromBalance - settlementAmount,
            "From account balance incorrect after settlement"
        );

        assertEq(
            toAccount.funds,
            originalToBalance + settlementAmount,
            "To account balance incorrect after settlement"
        );
    }

    function settleRailInDebt(
        Payments payments,
        uint256 railId,
        address client,
        address recipient,
        address token,
        uint256 rate,
        uint256 // lockupPeriod - unused but kept for interface compatibility
    ) public returns (uint256 settledUpto) {
        // Record starting balances
        Payments.Account memory clientBefore = baseHelper.getAccountData(
            payments,
            token,
            client
        );

        Payments.Account memory recipientBefore = baseHelper.getAccountData(
            payments,
            token,
            recipient
        );

        uint256 settledAmount;
        string memory note;

        // Try to settle up to current block (should be limited by available funds)
        vm.prank(client);
        (settledAmount, settledUpto, note) = payments.settleRail(
            railId,
            block.number
        );

        // Get rail details after settlement attempt
        Payments.RailView memory rail;
        try payments.getRail(railId) returns (
            Payments.RailView memory railView
        ) {
            rail = railView;
        } catch {
            // If rail doesn't exist anymore, just return the settled epoch
            return settledUpto;
        }

        // Just verify that settlement occurred as expected
        // We don't assume any specific amount because other rails might affect the available funds
        if (settledAmount > 0) {
            assertEq(
                settledAmount % rate,
                0,
                "Settlement amount should be a multiple of the rate"
            );
        }

        // Verify rail state reflects the partial settlement
        verifyRailSettlementState(payments, railId, settledUpto);

        // Verify balance changes
        verifySettlementBalances(
            payments,
            token,
            client,
            recipient,
            settledAmount,
            clientBefore.funds,
            recipientBefore.funds
        );

        return settledUpto;
    }

    function terminateAndSettleRail(
        Payments payments,
        uint256 railId,
        address client,
        address operator,
        address recipient,
        address token
    ) public returns (uint256 settledAmount, uint256 settledUpto) {
        // Debug log client account before terminating
        Payments.Account memory clientBeforeTermination = baseHelper.getAccountData(
            payments,
            token,
            client
        );
        console.log("Rail client lockupLastSettledAt right inside terminateAndSettleRail:", clientBeforeTermination.lockupLastSettledAt);
        
        // Terminate the rail as operator
        vm.prank(operator);
        payments.terminateRail(railId);

        // Log block number before settlement
        console.log("Current block number:", block.number);

        // Get rail details after termination
        Payments.RailView memory rail = payments.getRail(railId);
        console.log("Rail end epoch after termination:", rail.endEpoch);

        // Record balances before final settlement
        Payments.Account memory clientBefore = baseHelper.getAccountData(
            payments,
            token,
            client
        );

        Payments.Account memory recipientBefore = baseHelper.getAccountData(
            payments,
            token,
            recipient
        );

        string memory note;

        // Settle rail after termination
        vm.prank(client);
        (settledAmount, settledUpto, note) = payments.settleRail(
            railId,
            block.number
        );

        // Verify balance changes after termination settlement
        verifySettlementBalances(
            payments,
            token,
            client,
            recipient,
            settledAmount,
            clientBefore.funds,
            recipientBefore.funds
        );

        return (settledAmount, settledUpto);
    }

    function modifyRailSettingsAndVerify(
        Payments payments,
        uint256 railId,
        address operator,
        uint256 newRate,
        uint256 newLockupPeriod,
        uint256 newFixedLockup
    ) public {
        Payments.RailView memory railBefore = payments.getRail(railId);

        // Modify rail settings
        vm.startPrank(operator);

        // First modify rate if needed
        if (newRate != railBefore.paymentRate) {
            payments.modifyRailPayment(railId, newRate, 0);
        }

        // Then modify lockup parameters
        if (
            newLockupPeriod != railBefore.lockupPeriod ||
            newFixedLockup != railBefore.lockupFixed
        ) {
            payments.modifyRailLockup(railId, newLockupPeriod, newFixedLockup);
        }

        vm.stopPrank();

        // Verify changes
        Payments.RailView memory railAfter = payments.getRail(railId);

        assertEq(
            railAfter.paymentRate,
            newRate,
            "Rail payment rate not updated correctly"
        );

        assertEq(
            railAfter.lockupPeriod,
            newLockupPeriod,
            "Rail lockup period not updated correctly"
        );

        assertEq(
            railAfter.lockupFixed,
            newFixedLockup,
            "Rail fixed lockup not updated correctly"
        );
    }
}
