// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Payments} from "../src/Payments.sol";
import {ERC1967Proxy} from "../src/ERC1967Proxy.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {PaymentsTestHelpers} from "./helpers/PaymentsTestHelpers.sol";

contract AccessControlTest is Test {
    Payments payments;
    MockERC20 token;
    PaymentsTestHelpers helper;

    address owner = address(0x1);
    address client = address(0x2);
    address recipient = address(0x3);
    address operator = address(0x4);
    address arbiter = address(0x5);
    address unauthorized = address(0x6);

    uint256 constant INITIAL_BALANCE = 1000 ether;
    uint256 constant DEPOSIT_AMOUNT = 100 ether;
    uint256 railId;

    function setUp() public {
        helper = new PaymentsTestHelpers();
        payments = helper.deployPaymentsSystem(owner);

        // Set up users for the token
        address[] memory users = new address[](3);
        users[0] = client;
        users[1] = recipient;
        users[2] = operator;

        // Deploy test token with initial balances and approvals
        token = helper.setupTestToken(
            "Test Token",
            "TEST",
            users,
            INITIAL_BALANCE,
            address(payments)
        );

        // Setup operator approval
        helper.setupOperatorApproval(
            payments,
            address(token),
            client,
            operator,
            10 ether, // rateAllowance
            100 ether // lockupAllowance
        );

        // Deposit funds for client
        helper.makeDeposit(
            payments,
            address(token),
            client,
            client,
            DEPOSIT_AMOUNT
        );

        // Create a rail for testing
        railId = helper.createRail(
            payments,
            address(token),
            client,
            recipient,
            operator,
            arbiter
        );

        // Set up rail parameters
        vm.startPrank(operator);
        payments.modifyRailPayment(railId, 1 ether, 0); // 1 ether per block
        payments.modifyRailLockup(railId, 10, 10 ether); // 10 block lockup period, 10 ether fixed
        vm.stopPrank();
    }

    function testTerminateRail_SucceedsWhenCalledByClient() public {
        vm.startPrank(client);
        payments.terminateRail(railId);
        vm.stopPrank();
    }

    function testTerminateRail_SucceedsWhenCalledByOperator() public {
        vm.startPrank(operator);
        payments.terminateRail(railId);
        vm.stopPrank();
    }

    function testTerminateRail_FailsWhenCalledByRecipient() public {
        vm.startPrank(recipient);
        vm.expectRevert();
        payments.terminateRail(railId);
        vm.stopPrank();
    }

    function testTerminateRail_RevertsWhenCalledByUnauthorized() public {
        vm.startPrank(unauthorized);
        vm.expectRevert(
            "caller is not authorized: must be operator or client with settled lockup"
        );
        payments.terminateRail(railId);
        vm.stopPrank();
    }

    function testModifyRailLockup_SucceedsWhenCalledByOperator() public {
        vm.startPrank(operator);
        payments.modifyRailLockup(railId, 20, 20 ether);
        vm.stopPrank();
    }

    function testModifyRailLockup_RevertsWhenCalledByClient() public {
        vm.startPrank(client);
        vm.expectRevert("only the rail operator can perform this action");
        payments.modifyRailLockup(railId, 20, 20 ether);
        vm.stopPrank();
    }

    function testModifyRailLockup_RevertsWhenCalledByRecipient() public {
        vm.startPrank(recipient);
        vm.expectRevert("only the rail operator can perform this action");
        payments.modifyRailLockup(railId, 20, 20 ether);
        vm.stopPrank();
    }

    function testModifyRailLockup_RevertsWhenCalledByUnauthorized() public {
        vm.startPrank(unauthorized);
        vm.expectRevert("only the rail operator can perform this action");
        payments.modifyRailLockup(railId, 20, 20 ether);
        vm.stopPrank();
    }

    function testModifyRailPayment_SucceedsWhenCalledByOperator() public {
        vm.startPrank(operator);
        payments.modifyRailPayment(railId, 2 ether, 0);
        vm.stopPrank();
    }

    function testModifyRailPayment_RevertsWhenCalledByClient() public {
        vm.startPrank(client);
        vm.expectRevert("only the rail operator can perform this action");
        payments.modifyRailPayment(railId, 2 ether, 0);
        vm.stopPrank();
    }

    function testModifyRailPayment_RevertsWhenCalledByRecipient() public {
        vm.startPrank(recipient);
        vm.expectRevert("only the rail operator can perform this action");
        payments.modifyRailPayment(railId, 2 ether, 0);
        vm.stopPrank();
    }

    function testModifyRailPayment_RevertsWhenCalledByUnauthorized() public {
        vm.startPrank(unauthorized);
        vm.expectRevert("only the rail operator can perform this action");
        payments.modifyRailPayment(railId, 2 ether, 0);
        vm.stopPrank();
    }

    function testSettleTerminatedRailWithoutArbitration_RevertsWhenCalledByOperator()
        public
    {
        // 2. Add more funds
        helper.makeDeposit(
            payments,
            address(token),
            client,
            client,
            100 ether // Plenty of funds
        );

        // Terminate the rail
        vm.startPrank(client);
        payments.terminateRail(railId);
        vm.stopPrank();

        // Attempt to settle from operator account
        vm.startPrank(operator);
        vm.expectRevert("only the rail client can perform this action");
        payments.settleTerminatedRailWithoutArbitration(railId);
        vm.stopPrank();
    }
}
