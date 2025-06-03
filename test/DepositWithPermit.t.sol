// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {Payments} from "../src/Payments.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {PaymentsTestHelpers} from "./helpers/PaymentsTestHelpers.sol";
import {BaseTestHelper} from "./helpers/BaseTestHelper.sol";

contract DepositWithPermitTest is Test, BaseTestHelper {
    PaymentsTestHelpers helper;
    Payments payments;
    MockERC20 token;

    uint256 internal constant DEPOSIT_AMOUNT = 100 ether;
    uint256 internal constant INITIAL_BALANCE = 1000 ether;
    uint256 internal constant DEADLINE = 1 days;
    address tester;
    uint256 key;

    function setUp() public {
        helper = new PaymentsTestHelpers();
        helper.setupStandardTestEnvironment();
        payments = helper.payments();
        (tester, key) = makeAddrAndKey("tester");
        
        token = new MockERC20("Test Token", "TEST");
        token.mint(tester, INITIAL_BALANCE);
    }

    function testDepositWithPermit() public {

        (uint8 v, bytes32 r, bytes32 s) = _getPermitSignature(
            address(token),
            tester,
            address(payments),
            DEPOSIT_AMOUNT,
            token.nonces(tester),
            DEADLINE
        );

        vm.startPrank(tester);
        payments.depositWithPermit(
            address(token),
            tester,
            DEPOSIT_AMOUNT,
            DEADLINE,
            v,
            r,
            s
        );
        vm.stopPrank();

        (uint256 funds, , , ) = payments.accounts(address(token), tester);
        assertEq(funds, DEPOSIT_AMOUNT, "Deposit amount mismatch");
    }

    function testDepositWithPermitToAnotherUser() public {

        (uint8 v, bytes32 r, bytes32 s) = _getPermitSignature(
            address(token),
            tester,
            address(payments),
            DEPOSIT_AMOUNT,
            token.nonces(tester),
            DEADLINE
        );

        vm.startPrank(tester);
        payments.depositWithPermit(
            address(token),
            USER2,
            DEPOSIT_AMOUNT,
            DEADLINE,
            v,
            r,
            s
        );
        vm.stopPrank();

        (uint256 funds, , , ) = payments.accounts(address(token), USER2);
        assertEq(funds, DEPOSIT_AMOUNT, "Deposit amount mismatch");
    }

    function testDepositWithPermitWithExpiredDeadline() public {
        (uint8 v, bytes32 r, bytes32 s) = _getPermitSignature(
            address(token),
            tester,
            address(payments),
            DEPOSIT_AMOUNT,
            token.nonces(tester),
            block.timestamp - 1 
        );

        vm.startPrank(tester);
        vm.expectRevert(abi.encodeWithSignature("ERC2612ExpiredSignature(uint256)", block.timestamp - 1));
        payments.depositWithPermit(
            address(token),
            tester,
            DEPOSIT_AMOUNT,
            block.timestamp - 1,
            v,
            r,
            s
        );
        vm.stopPrank();
    }

    function testDepositWithPermitWithInvalidSignature() public {
        (uint8 v, bytes32 r, bytes32 s) = _getPermitSignature(
            address(token),
            tester,
            address(payments),
            DEPOSIT_AMOUNT,
            token.nonces(tester),
            DEADLINE
        );

        // Modify the signature to make it invalid
        s = bytes32(uint256(s) + 1);

        // Get the recovered signer address
        address recoveredSigner = _recoverPermitSigner(
            address(token),
            tester,
            address(payments),
            DEPOSIT_AMOUNT,
            token.nonces(tester),
            DEADLINE,
            v,
            r,
            s
        );

        vm.startPrank(tester);
        vm.expectRevert(abi.encodeWithSignature("ERC2612InvalidSigner(address,address)", recoveredSigner, tester));
        payments.depositWithPermit(
            address(token),
            tester,
            DEPOSIT_AMOUNT,
            DEADLINE,
            v,
            r,
            s
        );
        vm.stopPrank();
    }

    function _getPermitSignature(
        address tokenAddress,
        address owner,
        address spender,
        uint256 value,
        uint256 nonce,
        uint256 deadline
    ) internal view returns (uint8 v, bytes32 r, bytes32 s) {
        bytes32 domainSeparator = MockERC20(address(tokenAddress)).DOMAIN_SEPARATOR();

        bytes32 structHash = keccak256(
            abi.encode(
                keccak256(
                    "Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"
                ),
                owner,
                spender,
                value,
                nonce,
                deadline
            )
        );

        bytes32 hash = keccak256(
            abi.encodePacked("\x19\x01", domainSeparator, structHash)
        );

        (v, r, s) = vm.sign(key, hash);
    }

    function _recoverPermitSigner(
        address tokenAddress,
        address owner,
        address spender,
        uint256 value,
        uint256 nonce,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) internal view returns (address) {
        bytes32 domainSeparator = MockERC20(tokenAddress).DOMAIN_SEPARATOR();

        bytes32 structHash = keccak256(
            abi.encode(
                keccak256(
                    "Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"
                ),
                owner,
                spender,
                value,
                nonce,
                deadline
            )
        );

        bytes32 hash = keccak256(
            abi.encodePacked("\x19\x01", domainSeparator, structHash)
        );

        return ecrecover(hash, v, r, s);
    }
} 