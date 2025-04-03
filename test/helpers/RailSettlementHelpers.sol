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

    function setupRailWithArbitrerAndRateChangeQueue(
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

        // Setup operator approval with sufficient allowances
        uint256 maxRate = 0;
        for (uint256 i = 0; i < rates.length; i++) {
            if (rates[i] > maxRate) {
                maxRate = rates[i];
            }
        }

        // Calculate total lockup needed
        uint256 totalLockupAllowance = lockupFixed + (maxRate * lockupPeriod);

        // Setup operator approval with the necessary allowances
        baseHelper.setupOperatorApproval(
            from,
            operator,
            maxRate, // Rate allowance
            totalLockupAllowance // Lockup allowance
        );

        // Create rail with parameters
        uint256 railId = baseHelper.setupRailWithParameters(
            from,
            to,
            operator,
            rates[0], // Initial rate
            lockupPeriod,
            lockupFixed,
            arbiter
        );

        // Apply rate changes for the rest of the rates
        vm.startPrank(operator);
        for (uint256 i = 1; i < rates.length; i++) {
            // Each change will enqueue the previous rate
            baseHelper.payments().modifyRailPayment(railId, rates[i], 0);

            // Advance one block to ensure the changes are at different epochs
            baseHelper.advanceBlocks(1);
        }
        vm.stopPrank();

        // Verify the rate change queue length
        Payments.RailView memory rail = baseHelper.payments().getRail(railId);
        assertEq(
            rail.rateChangeQueueLength,
            rates.length - 1,
            "Rate change queue length does not match expected"
        );

        return railId;
    }

    function createInDebtRail(
        address from,
        address to,
        address operator,
        uint256 paymentRate,
        uint256 lockupPeriod,
        uint256 fundAmount,
        uint256 fixedLockup
    ) public returns (uint256) {
        baseHelper.makeDeposit(from, from, fundAmount);

        // Create a rail with specified parameters
        uint256 railId = baseHelper.setupRailWithParameters(
            from,
            to,
            operator,
            paymentRate,
            lockupPeriod,
            fixedLockup,
            address(0)
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
        uint256 railId,
        uint256 untilEpoch,
        uint256 expectedAmount,
        uint256 expectedUpto
    ) public returns (SettlementResult memory result) {
        // Get the rail details to identify payer and payee
        Payments.RailView memory rail = baseHelper.payments().getRail(railId);
        address payer = rail.from;
        address payee = rail.to;

        // Get balances before settlement
        Payments.Account memory payerBefore = baseHelper.getAccountData(payer);
        Payments.Account memory payeeBefore = baseHelper.getAccountData(payee);

        uint256 settlementAmount;
        uint256 settledUpto;
        string memory note;

        (settlementAmount, settledUpto, note) = baseHelper
            .payments()
            .settleRail(railId, untilEpoch);

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

        // Verify payer and payee balance changes
        Payments.Account memory payerAfter = baseHelper.getAccountData(payer);
        Payments.Account memory payeeAfter = baseHelper.getAccountData(payee);

        assertEq(
            payerBefore.funds - payerAfter.funds,
            settlementAmount,
            "Payer's balance reduction doesn't match settlement amount"
        );
        assertEq(
            payeeAfter.funds - payeeBefore.funds,
            settlementAmount,
            "Payee's balance increase doesn't match settlement amount"
        );

        assertEq(rail.settledUpTo, expectedUpto, "Rail settled upto incorrect");

        return SettlementResult(settlementAmount, settledUpto, note);
    }

    function terminateAndSettleRail(
        uint256 railId,
        uint256 expectedAmount,
        uint256 expectedUpto
    ) public returns (SettlementResult memory result) {
        // Get rail details to extract client and operator addresses
        Payments.RailView memory rail = baseHelper.payments().getRail(railId);
        address client = rail.from;
        address operator = rail.operator;

        // Terminate the rail as operator
        vm.prank(operator);
        baseHelper.payments().terminateRail(railId);

        // Verify rail was properly terminated
        rail = baseHelper.payments().getRail(railId);
        Payments.Account memory clientAccount = baseHelper.getAccountData(
            client
        );
        assertTrue(rail.endEpoch > 0, "Rail should be terminated");
        assertEq(
            rail.endEpoch,
            clientAccount.lockupLastSettledAt + rail.lockupPeriod,
            "Rail end epoch should be account lockup last settled at + rail lockup period"
        );

        return
            settleRailAndVerify(
                railId,
                block.number,
                expectedAmount,
                expectedUpto
            );
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
        address client = railBefore.from;

        // Get operator allowance usage before modifications
        (, , , uint256 rateUsageBefore, uint256 lockupUsageBefore) = payments
            .operatorApprovals(
                address(baseHelper.testToken()),
                client,
                operator
            );

        // Calculate current lockup total
        uint256 oldLockupTotal = railBefore.lockupFixed +
            (railBefore.paymentRate * railBefore.lockupPeriod);

        // Calculate new lockup total
        uint256 newLockupTotal = newFixedLockup + (newRate * newLockupPeriod);

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

        // Get operator allowance usage after modifications
        (, , , uint256 rateUsageAfter, uint256 lockupUsageAfter) = payments
            .operatorApprovals(
                address(baseHelper.testToken()),
                client,
                operator
            );

        // Verify rate usage changes correctly
        if (newRate > railBefore.paymentRate) {
            // Rate increased
            assertEq(
                rateUsageAfter,
                rateUsageBefore + (newRate - railBefore.paymentRate),
                "Rate usage not increased correctly after rate increase"
            );
        } else if (newRate < railBefore.paymentRate) {
            // Rate decreased
            assertEq(
                rateUsageBefore,
                rateUsageAfter + (railBefore.paymentRate - newRate),
                "Rate usage not decreased correctly after rate decrease"
            );
        } else {
            // Rate unchanged
            assertEq(
                rateUsageBefore,
                rateUsageAfter,
                "Rate usage changed unexpectedly when rate was not modified"
            );
        }

        // Verify lockup usage changes correctly
        if (newLockupTotal > oldLockupTotal) {
            // Lockup increased
            assertEq(
                lockupUsageAfter,
                lockupUsageBefore + (newLockupTotal - oldLockupTotal),
                "Lockup usage not increased correctly after lockup increase"
            );
        } else if (newLockupTotal < oldLockupTotal) {
            // Lockup decreased
            assertEq(
                lockupUsageBefore,
                lockupUsageAfter + (oldLockupTotal - newLockupTotal),
                "Lockup usage not decreased correctly after lockup decrease"
            );
        } else {
            // Lockup unchanged
            assertEq(
                lockupUsageBefore,
                lockupUsageAfter,
                "Lockup usage changed unexpectedly when lockup was not modified"
            );
        }
    }
}
