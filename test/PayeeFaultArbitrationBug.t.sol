// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Payments} from "../src/Payments.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockArbiter} from "./mocks/MockArbiter.sol";
import {PaymentsTestHelpers} from "./helpers/PaymentsTestHelpers.sol";
import {BaseTestHelper} from "./helpers/BaseTestHelper.sol";
import {console} from "forge-std/console.sol";

contract PayeeFaultArbitrationBugTest is Test, BaseTestHelper {
    PaymentsTestHelpers helper;
    Payments payments;
    MockERC20 token;
    MockArbiter arbiter;

    uint256 constant DEPOSIT_AMOUNT = 200 ether;

    function setUp() public {
        helper = new PaymentsTestHelpers();
        helper.setupStandardTestEnvironment();
        payments = helper.payments();
        token = MockERC20(address(helper.testToken()));

        // Create an arbiter that will reduce payment when payee fails
        arbiter = new MockArbiter(MockArbiter.ArbiterMode.REDUCE_AMOUNT);
        arbiter.configure(20); // Only approve 20% of requested payment (simulating payee fault)

        helper.makeDeposit(USER1, USER1, DEPOSIT_AMOUNT);
    }

    function testPayeeFaultLockupBug() public {
        // Scenario: Client locks up for 12 blocks of service, SP fails after 2 blocks
        uint256 paymentRate = 5 ether;
        uint256 lockupPeriod = 12; // Client locks funds for 12 blocks of service
        uint256 fixedLockup = 0;
        
        console.log("=== SETUP ===");
        console.log("Payment rate:", paymentRate);
        console.log("Lockup period:", lockupPeriod);
        console.log("Expected initial lockup:", paymentRate * lockupPeriod);

        // Get initial payer state
        Payments.Account memory payerInitial = helper.getAccountData(USER1);
        
        // Create rail with arbiter
        uint256 railId = helper.setupRailWithParameters(
            USER1,
            USER2,
            OPERATOR,
            paymentRate,
            lockupPeriod,
            fixedLockup,
            address(arbiter)
        );

        // Verify initial lockup
        Payments.Account memory payerAfterCreate = helper.getAccountData(USER1);
        uint256 initialLockupIncrease = payerAfterCreate.lockupCurrent - payerInitial.lockupCurrent;
        console.log("\n=== AFTER RAIL CREATION ===");
        console.log("Initial lockup increase:", initialLockupIncrease);
        console.log("Payer lockup current:", payerAfterCreate.lockupCurrent);

        // SP provides service for 2 blocks, then FAILS
        helper.advanceBlocks(2);
        
        // Terminate rail due to SP failure
        vm.prank(OPERATOR);
        payments.terminateRail(railId);
        
        console.log("\n=== AFTER TERMINATION (SP FAILED) ===");
        console.log("Current block:", block.number);

        // Advance time to enable settlement
        helper.advanceBlocks(15);

        // Settlement with arbitration - arbiter should only approve payment for partial service
        console.log("\n=== SETTLEMENT WITH ARBITRATION ===");
        
        vm.prank(USER1);
        (uint256 settledAmount, uint256 netPayeeAmount, , , ,) = payments.settleRail(railId, block.number);
        
        console.log("Settled amount (before arbitration):", settledAmount);
        console.log("Net payee amount (after arbitration):", netPayeeAmount);
        
        // Check final lockup state
        Payments.Account memory payerFinal = helper.getAccountData(USER1);
        console.log("Final payer lockup:", payerFinal.lockupCurrent);
        
        // Calculate what SHOULD have happened
        uint256 totalLockupReduction = payerAfterCreate.lockupCurrent - payerFinal.lockupCurrent;
        
        console.log("\n=== ANALYSIS ===");
        console.log("Initial lockup:", initialLockupIncrease);
        console.log("Actual lockup reduction:", totalLockupReduction);
        
        // BUG CHECK: If lockup reduction < initial lockup, then unused lockup is stuck
        if (totalLockupReduction < initialLockupIncrease) {
            uint256 stuckLockup = initialLockupIncrease - totalLockupReduction;
            console.log("BUG DETECTED: Stuck lockup:", stuckLockup);
            console.log("This represents funds that should have been returned to the payer");
            
            // This assertion will fail if the bug exists
            assertEq(
                totalLockupReduction,
                initialLockupIncrease,
                "Payee fault bug: Unused lockup not returned when arbiter reduces payment"
            );
        } else {
            console.log("No bug detected - full lockup properly returned");
        }
    }

    function testPayeeFaultWithFixedLockup() public {
        // Similar test but with fixed lockup component to isolate the rate-based issue
        uint256 paymentRate = 5 ether;
        uint256 lockupPeriod = 12;
        uint256 fixedLockup = 10 ether;
        
        Payments.Account memory payerInitial = helper.getAccountData(USER1);
        
        uint256 railId = helper.setupRailWithParameters(
            USER1,
            USER2,
            OPERATOR,
            paymentRate,
            lockupPeriod,
            fixedLockup,
            address(arbiter)
        );

        Payments.Account memory payerAfterCreate = helper.getAccountData(USER1);
        uint256 expectedTotalLockup = fixedLockup + (paymentRate * lockupPeriod);
        
        console.log("\n=== FIXED LOCKUP TEST ===");
        console.log("Fixed lockup:", fixedLockup);
        console.log("Rate-based lockup:", paymentRate * lockupPeriod);
        console.log("Expected total lockup:", expectedTotalLockup);

        // SP fails immediately, terminate
        vm.prank(OPERATOR);
        payments.terminateRail(railId);
        
        helper.advanceBlocks(15);

        vm.prank(USER1);
        payments.settleRail(railId, block.number);
        
        Payments.Account memory payerFinal = helper.getAccountData(USER1);
        uint256 lockupReduction = payerAfterCreate.lockupCurrent - payerFinal.lockupCurrent;
        
        console.log("Lockup reduction:", lockupReduction);
        console.log("Expected reduction:", expectedTotalLockup);
        
        // The bug manifests as: only fixed lockup gets returned, not unused rate-based
        if (lockupReduction < expectedTotalLockup) {
            console.log("BUG: Rate-based lockup not fully returned");
        }
    }
}