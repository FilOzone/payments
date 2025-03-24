// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract ReentrantERC20 is ERC20 {
    address public target;
    bytes public attackData;
    bool public attacking;
    
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {}
    
    function mint(address to, uint256 amount) public {
        _mint(to, amount);
    }
    
    function setAttack(address _target, bytes calldata _data) external {
        target = _target;
        attackData = _data;
    }

    /**
     * @dev Hook that is called during token transfers.
     */
    function _update(
        address from,
        address to,
        uint256 amount
    ) internal virtual override {
        super._update(from, to, amount);
        
        // Only try to reenter during a withdrawal (when tokens are being transferred FROM the contract)
        if (from == target && !attacking && target != address(0)) {
            attacking = true;
            // Ignore return value - we're just testing reentrancy protection
            (bool success,) = target.call(attackData);
            // Suppress unused variable warning
            if (success) { /* do nothing */ }
            attacking = false;
        }
    }
}