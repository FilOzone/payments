// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {Payments} from "../src/Payments.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {PaymentsTestHelpers} from "./helpers/PaymentsTestHelpers.sol";
import {BaseTestHelper} from "./helpers/BaseTestHelper.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {console} from "forge-std/console.sol";

contract DepositWithPermitAndOperatorApproval is Test, BaseTestHelper {
    MockERC20 testToken;
    PaymentsTestHelpers helper;
    Payments payments;

    uint256 constant DEPOSIT_AMOUNT = 1000 ether;
    uint256 constant RATE_ALLOWANCE = 100 ether;
    uint256 constant LOCKUP_ALLOWANCE = 1000 ether;
    uint256 constant MAX_LOCKUP_PERIOD = 100;
    uint256 internal constant INITIAL_BALANCE = 1000 ether;

    function setUp() public {
        helper = new PaymentsTestHelpers();
        helper.setupStandardTestEnvironment();
        payments = helper.payments();

        testToken = helper.testToken();
    }

    function testDepositWithPermitAndOperatorApproval_HappyPath() public {
        helper.makeDepositWithPermitAndOperatorApproval(
            user1Sk, DEPOSIT_AMOUNT, OPERATOR, RATE_ALLOWANCE, LOCKUP_ALLOWANCE, MAX_LOCKUP_PERIOD
        );
    }

    function testDepositWithPermitAndOperatorApproval_ZeroAmount() public {
        helper.makeDepositWithPermitAndOperatorApproval(
            user1Sk, 0, OPERATOR, RATE_ALLOWANCE, LOCKUP_ALLOWANCE, MAX_LOCKUP_PERIOD
        );
    }

    function testDepositWithPermitAndOperatorApproval_MultipleDeposits() public {
        uint256 firstDepositAmount = 500 ether;
        uint256 secondDepositAmount = 300 ether;

        helper.makeDepositWithPermitAndOperatorApproval(
            user1Sk, firstDepositAmount, OPERATOR, RATE_ALLOWANCE, LOCKUP_ALLOWANCE, MAX_LOCKUP_PERIOD
        );
        helper.makeDepositWithPermitAndOperatorApproval(
            user1Sk, secondDepositAmount, OPERATOR, RATE_ALLOWANCE, LOCKUP_ALLOWANCE, MAX_LOCKUP_PERIOD
        );
    }

    function testDepositWithPermitAndOperatorApproval_InvalidPermitReverts() public {
        helper.expectInvalidPermitAndOperatorApprovalToRevert(
            user1Sk, DEPOSIT_AMOUNT, OPERATOR, RATE_ALLOWANCE, LOCKUP_ALLOWANCE, MAX_LOCKUP_PERIOD
        );
    }
}
