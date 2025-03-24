// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Payments} from "../../src/Payments.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

contract PaymentsTestHelpers is Test {
    // Helper to get account data from the contract
    function getAccountData(Payments payments, address token, address user) public view returns (Payments.Account memory) {
        (uint256 funds, uint256 lockupCurrent, uint256 lockupRate, uint256 lockupLastSettledAt) = 
            payments.accounts(token, user);
            
        return Payments.Account({
            funds: funds,
            lockupCurrent: lockupCurrent,
            lockupRate: lockupRate,
            lockupLastSettledAt: lockupLastSettledAt
        });
    }
    
    // Helper to make a deposit
    function makeDeposit(Payments payments, address token, address from, address to, uint256 amount) public {
        vm.startPrank(from);
        payments.deposit(token, to, amount);
        vm.stopPrank();
    }
    
    // Helper to make a withdrawal
    function makeWithdrawal(Payments payments, address token, address from, uint256 amount) public {
        vm.startPrank(from);
        payments.withdraw(token, amount);
        vm.stopPrank();
    }
    
    // Helper to attempt a withdrawal and expect it to fail with specific error
    function expectWithdrawalToFail(Payments payments, address token, address from, uint256 amount, bytes memory expectedError) public {
        vm.startPrank(from);
        vm.expectRevert(expectedError);
        payments.withdraw(token, amount);
        vm.stopPrank();
    }
    
    // Helper to make a withdrawal to another address
    function makeWithdrawalTo(Payments payments, address token, address from, address to, uint256 amount) public {
        vm.startPrank(from);
        payments.withdrawTo(token, to, amount);
        vm.stopPrank();
    }
    
    // Creates a new payment rail and returns the railId
    function createRail(Payments payments, address token, address from, address to, address railOperator, address arbiter) public returns (uint256) {
        vm.startPrank(railOperator);
        uint256 railId = payments.createRail(token, from, to, arbiter);
        vm.stopPrank();
        return railId;
    }
    
    // Sets up a payment rail with specified rate and lockup parameters
    function setupRailWithParameters(
        Payments payments,
        address token,
        address from,
        address to,
        address railOperator,
        uint256 paymentRate,
        uint256 lockupPeriod,
        uint256 lockupFixed
    ) public returns (uint256) {
        // Create the rail
        uint256 railId = createRail(payments, token, from, to, railOperator, address(0));
        
        // Set payment rate
        vm.startPrank(railOperator);
        payments.modifyRailPayment(railId, paymentRate, 0);
        
        // Set lockup parameters
        payments.modifyRailLockup(railId, lockupPeriod, lockupFixed);
        vm.stopPrank();
        
        return railId;
    }
    
    // Helper to setup operator approval
    function setupOperatorApproval(
        Payments payments,
        address token, 
        address from, 
        address operator, 
        uint256 rateAllowance, 
        uint256 lockupAllowance
    ) public {
        vm.startPrank(from);
        payments.setOperatorApproval(token, operator, true, rateAllowance, lockupAllowance);
        vm.stopPrank();
    }
    
    // Helper to advance blocks
    function advanceBlocks(uint256 blocks) public {
        vm.roll(block.number + blocks);
    }
    
    // Helper to settle a rail
    function settleRail(Payments payments, uint256 railId, uint256 untilEpoch) public returns (uint256 amount, uint256 finalEpoch, string memory note) {
        return payments.settleRail(railId, untilEpoch);
    }
    
    // Helper to assert account state
    function assertAccountState(
        Payments payments,
        address token, 
        address user, 
        uint256 expectedFunds, 
        uint256 expectedLockup, 
        uint256 expectedRate, 
        uint256 expectedLastSettled
    ) public {
        Payments.Account memory account = getAccountData(payments, token, user);
        assertEq(account.funds, expectedFunds, "Account funds incorrect");
        assertEq(account.lockupCurrent, expectedLockup, "Account lockup incorrect");
        assertEq(account.lockupRate, expectedRate, "Account lockup rate incorrect");
        assertEq(account.lockupLastSettledAt, expectedLastSettled, "Account last settled at incorrect");
    }
}