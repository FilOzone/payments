// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Payments} from "../src/Payments.sol";
import {ERC1967Proxy} from "../src/ERC1967Proxy.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract AccountLockupSettlementTest is Test {
    Payments payments;
    MockERC20 token;
    
    address owner = address(0x1);
    address user1 = address(0x2);
    address user2 = address(0x3);
    address operator = address(0x4);
    
    uint256 constant INITIAL_BALANCE = 1000 ether;
    uint256 constant DEPOSIT_AMOUNT = 100 ether;
    
    // Direct access to account storage
    struct AccountData {
        uint256 funds;
        uint256 lockupCurrent;
        uint256 lockupRate;
        uint256 lockupLastSettledAt;
    }
    
    function setUp() public {
        // Setup contracts through proxy for upgradeability
        vm.startPrank(owner);
        Payments paymentsImplementation = new Payments();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(paymentsImplementation),
            abi.encodeWithSelector(Payments.initialize.selector)
        );
        payments = Payments(address(proxy));
        vm.stopPrank();
        
        // Deploy test token
        token = new MockERC20("Test Token", "TEST");
        
        // Setup initial token balances
        token.mint(user1, INITIAL_BALANCE);
        token.mint(user2, INITIAL_BALANCE);
        
        // Approve payments contract to spend tokens
        vm.startPrank(user1);
        token.approve(address(payments), type(uint256).max);
        vm.stopPrank();
        
        vm.startPrank(user2);
        token.approve(address(payments), type(uint256).max);
        vm.stopPrank();
        
        // Setup operator approval for potential rails
        vm.startPrank(user1);
        payments.setOperatorApproval(
            address(token),
            operator,
            true,
            10 ether, // rateAllowance
            100 ether // lockupAllowance
        );
        vm.stopPrank();
    }
    
    // Helper to get full account data as a struct for easier testing
    function getAccount(address tokenAddress, address userAddress) internal view returns (AccountData memory) {
        (uint256 funds, uint256 lockupCurrent, uint256 lockupRate, uint256 lockupLastSettledAt) = 
            payments.accounts(tokenAddress, userAddress);
            
        return AccountData({
            funds: funds,
            lockupCurrent: lockupCurrent,
            lockupRate: lockupRate,
            lockupLastSettledAt: lockupLastSettledAt
        });
    }
    
    // Helper to directly set account values for testing
    function setAccountValues(
        address tokenAddress,
        address accountOwner,
        uint256 funds,
        uint256 lockupCurrent,
        uint256 lockupRate,
        uint256 lockupLastSettledAt
    ) internal {
        // Get the storage slot for the account
        bytes32 accountMapPosition = keccak256(abi.encode(
            tokenAddress, 
            uint256(0) // The position of 'accounts' in the contract
        ));
        
        bytes32 accountPosition = keccak256(abi.encode(
            accountOwner,
            accountMapPosition
        ));
        
        // Set each value in the struct (funds, lockupCurrent, lockupRate, lockupLastSettledAt)
        vm.store(address(payments), accountPosition, bytes32(funds));
        vm.store(address(payments), bytes32(uint256(accountPosition) + 1), bytes32(lockupCurrent));
        vm.store(address(payments), bytes32(uint256(accountPosition) + 2), bytes32(lockupRate));
        vm.store(address(payments), bytes32(uint256(accountPosition) + 3), bytes32(lockupLastSettledAt));
    }
    
    // Helper to deposit for test setup
    function setupDeposit(address from, address to, uint256 amount) internal {
        vm.startPrank(from);
        payments.deposit(address(token), to, amount);
        vm.stopPrank();
    }
    
    /*//////////////////////////////////////////////////////////////
                    ACCOUNT LOCKUP SETTLEMENT TESTS
    //////////////////////////////////////////////////////////////*/
    
    function testSettlementWithNoLockupRate() public {
        // Setup: deposit funds
        setupDeposit(user1, user1, DEPOSIT_AMOUNT);
        
        // Set account with no lockup rate but old settlement time
        uint256 oldBlockNumber = block.number - 10;
        setAccountValues(
            address(token),
            user1,
            DEPOSIT_AMOUNT,
            0, // no lockup
            0, // no rate
            oldBlockNumber // settled 10 blocks ago
        );
        
        // Trigger settlement with a new deposit
        setupDeposit(user1, user1, DEPOSIT_AMOUNT);
        
        // Verify settlement occurred
        AccountData memory account = getAccount(address(token), user1);
        assertEq(account.lockupLastSettledAt, block.number, "Lockup last settled at should be updated");
        assertEq(account.lockupCurrent, 0, "Lockup current should remain zero without a rate");
    }
    
    function testSimpleLockupAccumulation() public {
        // Setup: deposit funds
        setupDeposit(user1, user1, DEPOSIT_AMOUNT);
        
        // Set account with a lockup rate
        uint256 lockupRate = 2 ether; // 2 tokens per block
        uint256 oldBlockNumber = block.number - 5;
        setAccountValues(
            address(token),
            user1,
            DEPOSIT_AMOUNT,
            0, // start with no lockup
            lockupRate,
            oldBlockNumber // settled 5 blocks ago
        );
        
        // Trigger settlement with a new deposit
        setupDeposit(user1, user1, DEPOSIT_AMOUNT);
        
        // Verify settlement occurred
        AccountData memory account = getAccount(address(token), user1);
        assertEq(account.lockupLastSettledAt, block.number, "Lockup last settled at should be updated");
        assertEq(account.lockupCurrent, 5 * lockupRate, "Lockup current should accumulate properly");
    }
    
    function testPartialSettlement() public {
        // Setup: deposit a small amount
        setupDeposit(user1, user1, DEPOSIT_AMOUNT / 2); // Only deposit enough for partial settlement
        
        // Set account with a high lockup rate that will exceed available funds
        uint256 lockupRate = 20 ether; // Very high rate to force partial settlement
        uint256 oldBlockNumber = block.number - 10;
        setAccountValues(
            address(token),
            user1,
            DEPOSIT_AMOUNT / 2, // Less than what would be needed for full settlement
            0,                  // start with no lockup
            lockupRate,         // High lockup rate
            oldBlockNumber      // settled 10 blocks ago
        );
        
        // Attempt to trigger full settlement - this will deposit more funds
        // but the account should still only be partially settled
        setupDeposit(user1, user1, DEPOSIT_AMOUNT / 2);
        
        // Verify partial settlement
        AccountData memory account = getAccount(address(token), user1);
        
        // With a rate of 20 ether per block, and 10 blocks elapsed, full settlement would require 200 ether
        // But we only have DEPOSIT_AMOUNT (100 ether) in funds, so expect partial settlement
        
        // Expected settlement: 100 ether / 20 ether per block = 5 blocks settled
        uint256 expectedSettledBlocks = 5;
        uint256 expectedNewLastSettledAt = oldBlockNumber + expectedSettledBlocks;
        uint256 expectedLockupCurrent = expectedSettledBlocks * lockupRate;
        
        assertEq(account.lockupLastSettledAt, expectedNewLastSettledAt, "Partial settlement: lockup last settled at");
        assertEq(account.lockupCurrent, expectedLockupCurrent, "Partial settlement: lockup current");
        assertEq(account.funds, DEPOSIT_AMOUNT, "Funds should match total deposits");
    }
    
    function testSettlementAfterGap() public {
        // Setup: deposit funds
        setupDeposit(user1, user1, DEPOSIT_AMOUNT);
        
        // Set account with a lockup rate
        uint256 lockupRate = 1 ether;
        uint256 oldBlockNumber = block.number - 20;
        setAccountValues(
            address(token),
            user1,
            DEPOSIT_AMOUNT,
            10 ether,         // existing lockup
            lockupRate,       // 1 token per block
            oldBlockNumber    // settled 20 blocks ago
        );
        
        // Roll forward even more blocks
        vm.roll(block.number + 10);
        
        // Trigger settlement with a new deposit
        setupDeposit(user1, user1, DEPOSIT_AMOUNT);
        
        // Verify settlement occurred
        AccountData memory account = getAccount(address(token), user1);
        
        // Now we have a total gap of 30 blocks (20 initially + 10 more with roll)
        // Existing funds: DEPOSIT_AMOUNT (100 ether)
        // Existing lockup: 10 ether
        // Available for new lockup: 90 ether
        // Can cover: 90 ether / 1 ether per block = 90 blocks, which is more than the 30 block gap
        // So we expect full settlement
        
        assertEq(account.lockupLastSettledAt, block.number, "Lockup should be settled to current block");
        assertEq(account.lockupCurrent, 10 ether + (30 * lockupRate), "Lockup current should include existing + new lockup");
    }
    
    function testSettlementInvariants() public {
        // Setup: deposit a specific amount
        setupDeposit(user1, user1, DEPOSIT_AMOUNT);
        
        // Test various lockup scenarios to verify the invariant: funds >= lockupCurrent
        
        // Scenario 1: Lockup exactly matches funds - should pass
        setAccountValues(
            address(token),
            user1,
            DEPOSIT_AMOUNT,
            DEPOSIT_AMOUNT, // lockup equals funds
            0,
            block.number
        );
        
        // This should succeed as the invariant holds
        setupDeposit(user1, user1, 1); // Any operation that triggers settlement
        
        // Scenario 2: Attempt to set lockup greater than funds (invalid state)
        setAccountValues(
            address(token),
            user1,
            DEPOSIT_AMOUNT + 1, // Current funds
            DEPOSIT_AMOUNT + 2, // Trying to set lockup > funds (invalid)
            0,
            block.number
        );
        
        // This should revert due to invariant check
        vm.startPrank(user1);
        vm.expectRevert("invariant failure: insufficient funds to cover lockup before function execution");
        payments.deposit(address(token), user1, 1);
        vm.stopPrank();
    }
    
    function testWithdrawWithLockupSettlement() public {
        // Setup: deposit funds
        setupDeposit(user1, user1, DEPOSIT_AMOUNT * 2); // Deposit 200 ether
        
        // Set a lockup rate and an existing lockup
        uint256 lockupRate = 1 ether;
        uint256 initialLockup = 50 ether;
        uint256 oldBlockNumber = block.number - 10;
        
        setAccountValues(
            address(token),
            user1,
            DEPOSIT_AMOUNT * 2,  // 200 ether funds
            initialLockup,       // 50 ether locked
            lockupRate,          // 1 ether per block
            oldBlockNumber       // 10 blocks ago
        );
        
        // Calculate expected values after settlement
        // Total lockup after settlement: 50 ether + (10 blocks * 1 ether) = 60 ether
        // Available for withdrawal: 200 ether - 60 ether = 140 ether
        
        // Try to withdraw more than available (should fail)
        vm.startPrank(user1);
        vm.expectRevert("insufficient unlocked funds for withdrawal");
        payments.withdraw(address(token), 150 ether);
        
        // Withdraw exactly the available amount (should succeed)
        payments.withdraw(address(token), 140 ether);
        vm.stopPrank();
        
        // Verify account state
        AccountData memory account = getAccount(address(token), user1);
        assertEq(account.funds, 60 ether, "Remaining funds should match lockup");
        assertEq(account.lockupCurrent, 60 ether, "Lockup should be updated");
        assertEq(account.lockupLastSettledAt, block.number, "Settlement should be updated to current block");
    }
}