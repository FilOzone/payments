// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Payments, IArbiter} from "../../src/Payments.sol";

contract MockArbiter is IArbiter {
    enum ArbiterMode {
        STANDARD, // Approves all payments as proposed
        REDUCE_AMOUNT, // Reduces payment amount by a percentage
        REDUCE_DURATION, // Settles for fewer epochs than requested
        CUSTOM_RETURN, // Returns specific values set by the test
        MALICIOUS // Returns invalid values

    }

    ArbiterMode public mode = ArbiterMode.STANDARD; // Default to STANDARD mode
    uint256 public modificationFactor; // Percentage (0-100) for reductions
    uint256 public customAmount;
    uint256 public customUpto;
    string public customNote;

    constructor(ArbiterMode _mode) {
        mode = _mode;
        modificationFactor = 100; // 100% = no modification by default
    }

    function configure(uint256 _modificationFactor) external {
        require(_modificationFactor <= 100, "Factor must be between 0-100");
        modificationFactor = _modificationFactor;
    }

    // Set custom return values for CUSTOM_RETURN mode
    function setCustomValues(uint256 _amount, uint256 _upto, string calldata _note) external {
        customAmount = _amount;
        customUpto = _upto;
        customNote = _note;
    }

    // Change the arbiter's mode
    function setMode(ArbiterMode _mode) external {
        mode = _mode;
    }

    function arbitratePayment(
        uint256, /* railId */
        uint256 proposedAmount,
        uint256 fromEpoch,
        uint256 toEpoch,
        uint256 /* rate */
    ) external view override returns (ArbitrationResult memory result) {
        if (mode == ArbiterMode.STANDARD) {
            return ArbitrationResult({
                modifiedAmount: proposedAmount,
                settleUpto: toEpoch,
                note: "Standard approved payment"
            });
        } else if (mode == ArbiterMode.REDUCE_AMOUNT) {
            uint256 reducedAmount = (proposedAmount * modificationFactor) / 100;
            return ArbitrationResult({
                modifiedAmount: reducedAmount,
                settleUpto: toEpoch,
                note: "Arbiter reduced payment amount"
            });
        } else if (mode == ArbiterMode.REDUCE_DURATION) {
            uint256 totalEpochs = toEpoch - fromEpoch;
            uint256 reducedEpochs = (totalEpochs * modificationFactor) / 100;
            uint256 reducedEndEpoch = fromEpoch + reducedEpochs;

            // Calculate reduced amount proportionally
            uint256 reducedAmount = (proposedAmount * reducedEpochs) / totalEpochs;

            return ArbitrationResult({
                modifiedAmount: reducedAmount,
                settleUpto: reducedEndEpoch,
                note: "Arbiter reduced settlement duration"
            });
        } else if (mode == ArbiterMode.CUSTOM_RETURN) {
            return ArbitrationResult({modifiedAmount: customAmount, settleUpto: customUpto, note: customNote});
        } else {
            // Malicious mode attempts to return invalid values
            return ArbitrationResult({
                modifiedAmount: proposedAmount * 2, // Try to double the payment
                settleUpto: toEpoch + 10, // Try to settle beyond the requested range
                note: "Malicious arbiter attempting to manipulate payment"
            });
        }
    }
}
