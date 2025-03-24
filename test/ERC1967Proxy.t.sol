// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Payments} from "../src/Payments.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract ERC1967ProxyTest is Test {
    Payments public implementation;
    Payments public proxy;
    address owner = address(0x123);

    function setUp() public {
        // Set owner for testing
        vm.startPrank(owner);
        // Deploy implementation contract
        implementation = new Payments();

        // Deploy proxy pointing to implementation
        bytes memory initData = abi.encodeWithSelector(
            Payments.initialize.selector
        );

        ERC1967Proxy proxyContract = new ERC1967Proxy(
            address(implementation),
            initData
        );

        // Get Payments interface on proxy address
        proxy = Payments(address(proxyContract));
    }

    function testInitialSetup() public view {
        assertEq(proxy.owner(), owner);
    }

    function assertImplementationEquals(address checkImpl) public view {
        bytes32 implementationSlot = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
        assertEq(
            address(
                uint160(uint256(vm.load(address(proxy), implementationSlot)))
            ),
            address(checkImpl)
        );
    }

    function testUpgradeImplementation() public {
        assertImplementationEquals(address(implementation));

        // Deploy new implementation
        Payments newImplementation = new Payments();

        // Upgrade proxy to new implementation
        proxy.upgradeToAndCall(address(newImplementation), "");

        // Verify upgrade was successful
        assertImplementationEquals(address(newImplementation));
        assertEq(proxy.owner(), owner); // Owner is preserved
    }

    function test_RevertWhen_UpgradeFromNonOwner() public {
        Payments newImplementation = new Payments();

        vm.stopPrank();
        vm.startPrank(address(0xdead));

        vm.expectRevert(
            abi.encodeWithSignature(
                "OwnableUnauthorizedAccount(address)",
                address(0xdead)
            )
        );
        proxy.upgradeToAndCall(address(newImplementation), "");
        assertEq(proxy.owner(), owner); // Owner is preserved
    }

    function testOwnershipTransfer() public {
        vm.stopPrank();
        vm.startPrank(owner);
        // Verify initial owner
        assertEq(proxy.owner(), owner);

        address newOwner = address(0x456);

        // Transfer ownership
        proxy.transferOwnership(newOwner);

        // Verify ownership changed
        assertEq(proxy.owner(), newOwner);
    }

    function test_RevertWhen_TransferFromNonOwner() public {
        // Switch to non-owner account
        vm.stopPrank();
        vm.startPrank(address(0xdead));

        address newOwner = address(0x456);

        // Attempt transfer should fail
        vm.expectRevert(
            abi.encodeWithSignature(
                "OwnableUnauthorizedAccount(address)",
                address(0xdead)
            )
        );
        proxy.transferOwnership(newOwner);

        // Verify owner unchanged
        assertEq(proxy.owner(), owner);
    }
}
