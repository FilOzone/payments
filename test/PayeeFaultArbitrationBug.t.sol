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


    function testLockupReturnedWithFaultTermination() public {
        uint256 paymentRate = 5 ether;
        uint256 lockupPeriod = 12;
        uint256 fixedLockup = 10 ether;
        
        uint256 railId = helper.setupRailWithParameters(
            USER1,
            USER2,
            OPERATOR,
            paymentRate,
            lockupPeriod,
            fixedLockup,
            address(arbiter)
        );

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
        
        console.log("Lockup after:", payerFinal.lockupCurrent);
        console.log("Expected lockup:", expectedTotalLockup);


        require(payerFinal.lockupCurrent == 0, "Payee fault bug: Fixed lockup not fully returned");
    }

     function testLockupReturnedWithFault() public {
        uint256 paymentRate = 5 ether;
        uint256 lockupPeriod = 12;
        uint256 fixedLockup = 10 ether;
        
        uint256 railId = helper.setupRailWithParameters(
            USER1,
            USER2,
            OPERATOR,
            paymentRate,
            lockupPeriod,
            fixedLockup,
            address(arbiter)
        );

        uint256 expectedTotalLockup = fixedLockup + (paymentRate * lockupPeriod);
        
        console.log("\n=== FIXED LOCKUP TEST ===");
        console.log("Fixed lockup:", fixedLockup);
        console.log("Rate-based lockup:", paymentRate * lockupPeriod);
        console.log("Expected total lockup:", expectedTotalLockup);

        // SP fails immediately, terminate
        vm.prank(OPERATOR);
        helper.advanceBlocks(15);

        vm.prank(USER1);
        payments.settleRail(railId, block.number);
        
        Payments.Account memory payerFinal = helper.getAccountData(USER1);
        
        console.log("Lockup after:", payerFinal.lockupCurrent);
        console.log("Expected lockup:", expectedTotalLockup);

        require(payerFinal.lockupCurrent == expectedTotalLockup, "Payee fault bug: Fixed lockup not fully returned");
    }
}