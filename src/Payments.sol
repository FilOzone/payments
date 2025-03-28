// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "./RateChangeQueue.sol";
import "@openzeppelin/contracts/utils/Strings.sol";

interface IArbiter {
    struct ArbitrationResult {
        // The actual payment amount determined by the arbiter after arbitration of a rail during settlement
        uint256 modifiedAmount;
        // The epoch up to and including which settlement should occur.
        uint256 settleUpto;
        // A placeholder note for any additional information the arbiter wants to send to the caller of `settleRail`
        string note;
    }

    function arbitratePayment(
        uint256 railId,
        uint256 proposedAmount,
        // the epoch up to and including which the rail has already been settled
        uint256 fromEpoch,
        // the epoch up to and including which arbitration is requested; payment will be arbitrated for (toEpoch - fromEpoch) epochs
        uint256 toEpoch
    ) external returns (ArbitrationResult memory result);
}

// @title Payments contract.
contract Payments is
    Initializable,
    UUPSUpgradeable,
    OwnableUpgradeable,
    ReentrancyGuard
{
    using SafeERC20 for IERC20;
    using RateChangeQueue for RateChangeQueue.Queue;

    struct Account {
        uint256 funds;
        uint256 lockupCurrent;
        uint256 lockupRate;
        // epoch up to and including which lockup has been settled for the account
        uint256 lockupLastSettledAt;
    }

    struct Rail {
        address token;
        address from;
        address to;
        address operator;
        address arbiter;
        uint256 paymentRate;
        uint256 lockupPeriod;
        uint256 lockupFixed;
        // epoch up to and including which this rail has been settled
        uint256 settledUpTo;
        RateChangeQueue.Queue rateChangeQueue;
        uint256 endEpoch; // Final epoch up to which the rail can be settled (0 if not terminated)
    }

    struct OperatorApproval {
        bool isApproved;
        uint256 rateAllowance;
        uint256 lockupAllowance;
        uint256 rateUsage; // Track actual usage for rate
        uint256 lockupUsage; // Track actual usage for lockup
    }

    // Counter for generating unique rail IDs
    uint256 private _nextRailId;

    // token => owner => Account
    mapping(address => mapping(address => Account)) public accounts;

    // railId => Rail
    mapping(uint256 => Rail) internal rails;

    // Struct to hold rail data without the RateChangeQueue (for external returns)
    struct RailView {
        address token;
        address from;
        address to;
        address operator;
        address arbiter;
        uint256 paymentRate;
        uint256 lockupPeriod;
        uint256 lockupFixed;
        uint256 settledUpTo;
        uint256 endEpoch;
        uint256 rateChangeQueueLength;
    }

    // token => client => operator => Approval
    mapping(address => mapping(address => mapping(address => OperatorApproval)))
        public operatorApprovals;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize() public initializer {
        __Ownable_init(msg.sender);
        __UUPSUpgradeable_init();
    }

    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyOwner {}

    modifier validateRailActive(uint256 railId) {
        require(
            rails[railId].from != address(0),
            "rail does not exist or is beyond it's last settlement after termination"
        );
        _;
    }

    modifier onlyRailClient(uint256 railId) {
        require(
            rails[railId].from == msg.sender,
            "only the rail client can perform this action"
        );
        _;
    }

    modifier onlyRailOperator(uint256 railId) {
        require(
            rails[railId].operator == msg.sender,
            "only the rail operator can perform this action"
        );
        _;
    }

    modifier onlyRailParticipant(uint256 railId) {
        require(
            rails[railId].from == msg.sender ||
                rails[railId].operator == msg.sender ||
                rails[railId].to == msg.sender,
            "failed to authorize: caller is not a rail participant"
        );
        _;
    }

    modifier validateRailNotTerminated(uint256 railId) {
        require(rails[railId].endEpoch == 0, "rail already terminated");
        _;
    }

    modifier validateRailTerminated(uint256 railId) {
        require(
            isRailTerminated(rails[railId]),
            "can only be used on terminated rails"
        );
        _;
    }

    modifier validateNonZeroAddress(address addr, string memory varName) {
        require(
            addr != address(0),
            string.concat(varName, " address cannot be zero")
        );
        _;
    }

    modifier settleAccountLockupBeforeAndAfter(
        address token,
        address owner,
        bool settleFull
    ) {
        Account storage payer = accounts[token][owner];

        // Before function execution
        performSettlementCheck(payer, settleFull, true);

        _;

        // After function execution
        performSettlementCheck(payer, settleFull, false);
    }

    modifier settleAccountLockupBeforeAndAfterForRail(
        uint256 railId,
        bool settleFull,
        uint256 oneTimePayment
    ) {
        Rail storage rail = rails[railId];
        require(rails[railId].from != address(0), "rail is inactive");

        Account storage payer = accounts[rail.token][rail.from];

        require(
            rail.lockupFixed >= oneTimePayment,
            "one time payment cannot be greater than rail lockupFixed"
        );

        // Before function execution
        performSettlementCheck(payer, settleFull, true);

        // ---- EXECUTE FUNCTION
        _;
        // ---- FUNCTION EXECUTION COMPLETE

        // After function execution
        performSettlementCheck(payer, settleFull, false);
    }

    function performSettlementCheck(
        Account storage payer,
        bool settleFull,
        bool isBefore
    ) internal {
        require(
            payer.funds >= payer.lockupCurrent,
            isBefore
                ? "invariant failure: insufficient funds to cover lockup before function execution"
                : "invariant failure: insufficient funds to cover lockup after function execution"
        );

        settleAccountLockup(payer);

        // Verify full settlement if required
        require(
            !settleFull || isAccountLockupFullySettled(payer),
            isBefore
                ? "account lockup not fully settled before function execution"
                : "account lockup not fully settled after function execution"
        );

        require(
            payer.funds >= payer.lockupCurrent,
            isBefore
                ? "invariant failure: insufficient funds to cover lockup before function execution"
                : "invariant failure: insufficient funds to cover lockup after function execution"
        );
    }

    /// @notice Gets the current state of the target rail or reverts if the rail isn't active.
    /// @param railId the ID of the rail.
    function getRail(
        uint256 railId
    ) external view validateRailActive(railId) returns (RailView memory) {
        Rail storage rail = rails[railId];
        return
            RailView({
                token: rail.token,
                from: rail.from,
                to: rail.to,
                operator: rail.operator,
                arbiter: rail.arbiter,
                paymentRate: rail.paymentRate,
                lockupPeriod: rail.lockupPeriod,
                lockupFixed: rail.lockupFixed,
                settledUpTo: rail.settledUpTo,
                endEpoch: rail.endEpoch,
                rateChangeQueueLength: rail.rateChangeQueue.size()
            });
    }

    /// @notice Updates the approval status and allowances for an operator on behalf of the message sender.
    /// @param token The ERC20 token address for which the approval is being set.
    /// @param operator The address of the operator whose approval is being modified.
    /// @param approved Whether the operator is approved (true) or not (false) to create new rails>
    /// @param rateAllowance The maximum payment rate the operator can set across all rails created by the operator on behalf of the message sender. If this is less than the current payment rate, the operator will only be able to reduce rates until they fall below the target.
    /// @param lockupAllowance The maximum amount of funds the operator can lock up on behalf of the message sender towards future payments. If this exceeds the current total amount of funds locked towards future payments, the operator will only be able to reduce future lockup.
    function setOperatorApproval(
        address token,
        address operator,
        bool approved,
        uint256 rateAllowance,
        uint256 lockupAllowance
    )
        external
        validateNonZeroAddress(token, "token")
        validateNonZeroAddress(operator, "operator")
    {
        OperatorApproval storage approval = operatorApprovals[token][
            msg.sender
        ][operator];

        // Update approval status and allowances
        approval.isApproved = approved;
        approval.rateAllowance = rateAllowance;
        approval.lockupAllowance = lockupAllowance;
    }

    /// @notice Terminates a payment rail, preventing further payments after the rail's lockup period. After calling this method, the lockup period cannot be changed, and the rail's rate and fixed lockup may only be reduced.
    /// @param railId The ID of the rail to terminate.
    /// @custom:constraint Caller must be a rail client or operator.
    /// @custom:constraint Rail must be active and not already terminated.
    /// @custom:constraint If called by the client, the payer's account must be fully funded (lockup must be fully settled).
    /// @custom:constraint If called by the operator, the payer's account lockup settlement is not checked.
    function terminateRail(
        uint256 railId
    )
        external
        validateRailActive(railId)
        nonReentrant
        validateRailNotTerminated(railId)
        settleAccountLockupBeforeAndAfterForRail(railId, false, 0)
    {
        Rail storage rail = rails[railId];
        Account storage payer = accounts[rail.token][rail.from];

        // Only client with fully settled lockup or operator can terminate a rail
        require(
            (msg.sender == rail.from && isAccountLockupFullySettled(payer)) ||
                msg.sender == rail.operator,
            "caller is not authorized: must be operator or client with settled lockup"
        );

        rail.endEpoch = payer.lockupLastSettledAt + rail.lockupPeriod;

        // Remove the rail rate from account lockup rate but don't set rail rate to zero yet.
        // The rail rate will be used to settle the rail and so we can't zero it yet.
        // However, we remove the rail rate from the client lockup rate because we don't want to
        // lock funds for the rail beyond `rail.endEpoch` as we're exiting the rail
        // after that epoch.
        require(
            payer.lockupRate >= rail.paymentRate,
            "lockup rate inconsistency"
        );
        payer.lockupRate -= rail.paymentRate;

        // Reduce operator rate allowance
        OperatorApproval storage operatorApproval = operatorApprovals[
            rail.token
        ][rail.from][rail.operator];
        updateOperatorRateUsage(operatorApproval, rail.paymentRate, 0);
    }

    /// @notice Deposits tokens from the message sender's account into `to`'s account.
    /// @param token The ERC20 token address to deposit.
    /// @param to The address whose account will be credited.
    /// @param amount The amount of tokens to deposit.
    /// @custom:constraint The message sender must have approved this contract to spend the requested amount via the ERC-20 token (`token`).
    function deposit(
        address token,
        address to,
        uint256 amount
    )
        external
        nonReentrant
        validateNonZeroAddress(token, "token")
        validateNonZeroAddress(to, "to")
        settleAccountLockupBeforeAndAfter(token, to, false)
    {
        // Create account if it doesn't exist
        Account storage account = accounts[token][to];

        // Transfer tokens from sender to contract
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);

        // Update account balance
        account.funds += amount;
    }

    /// @notice Withdraws tokens from the caller's account to the caller's account, up to the amount of currently available tokens (the tokens not currently locked in rails).
    /// @param token The ERC20 token address to withdraw.
    /// @param amount The amount of tokens to withdraw.
    function withdraw(
        address token,
        uint256 amount
    )
        external
        nonReentrant
        validateNonZeroAddress(token, "token")
        settleAccountLockupBeforeAndAfter(token, msg.sender, true)
    {
        return withdrawToInternal(token, msg.sender, amount);
    }

    /// @notice Withdraws tokens (`token`) from the caller's account to `to`, up to the amount of currently available tokens (the tokens not currently locked in rails).
    /// @param token The ERC20 token address to withdraw.
    /// @param to The address to receive the withdrawn tokens.
    /// @param amount The amount of tokens to withdraw.
    function withdrawTo(
        address token,
        address to,
        uint256 amount
    )
        external
        nonReentrant
        validateNonZeroAddress(token, "token")
        validateNonZeroAddress(to, "to")
        settleAccountLockupBeforeAndAfter(token, msg.sender, true)
    {
        return withdrawToInternal(token, to, amount);
    }

    function withdrawToInternal(
        address token,
        address to,
        uint256 amount
    ) internal {
        Account storage account = accounts[token][msg.sender];
        uint256 available = account.funds - account.lockupCurrent;
        require(
            amount <= available,
            "insufficient unlocked funds for withdrawal"
        );
        account.funds -= amount;
        IERC20(token).safeTransfer(to, amount);
    }

    /// @notice Create a new rail from `from` to `to`, operated by the caller.
    /// @param token The ERC20 token address for payments on this rail.
    /// @param from The client address (payer) for this rail.
    /// @param to The recipient address for payments on this rail.
    /// @param arbiter Optional address of an arbiter contract (can be address(0) for no arbitration).
    /// @return The ID of the newly created rail.
    /// @custom:constraint Caller must be approved as an operator by the client (from address).
    function createRail(
        address token,
        address from,
        address to,
        address arbiter
    )
        external
        nonReentrant
        validateNonZeroAddress(token, "token")
        validateNonZeroAddress(from, "from")
        validateNonZeroAddress(to, "to")
        returns (uint256)
    {
        address operator = msg.sender;

        // Check if operator is approved - approval is required for rail creation
        OperatorApproval storage approval = operatorApprovals[token][from][
            operator
        ];
        require(approval.isApproved, "operator not approved");

        uint256 railId = _nextRailId++;

        Rail storage rail = rails[railId];
        rail.token = token;
        rail.from = from;
        rail.to = to;
        rail.operator = operator;
        rail.arbiter = arbiter;
        rail.settledUpTo = block.number;
        rail.endEpoch = 0;

        return railId;
    }

    /// @notice Modifies the fixed lockup and lockup period of a rail.
    /// - If the rail has already been terminated, the lockup period may not be altered and the fixed lockup may only be reduced.
    /// - If the rail is active, the lockup may only be modified if the payer's account is fully funded and the payer's account must have enough funds to cover the new lockup.
    /// @param railId The ID of the rail to modify.
    /// @param period The new lockup period (in epochs/blocks).
    /// @param lockupFixed The new fixed lockup amount.
    /// @custom:constraint Caller must be the rail operator.
    /// @custom:constraint Operator must have sufficient lockup allowance to cover any increases the lockup period or the fixed lockup.
    function modifyRailLockup(
        uint256 railId,
        uint256 period,
        uint256 lockupFixed
    )
        external
        validateRailActive(railId)
        onlyRailOperator(railId)
        nonReentrant
        settleAccountLockupBeforeAndAfterForRail(railId, false, 0)
    {
        Rail storage rail = rails[railId];
        bool isTerminated = isRailTerminated(rail);

        if (isTerminated) {
            modifyTerminatedRailLockup(rail, period, lockupFixed);
        } else {
            modifyNonTerminatedRailLockup(rail, period, lockupFixed);
        }
    }

    function modifyTerminatedRailLockup(
        Rail storage rail,
        uint256 period,
        uint256 lockupFixed
    ) internal {
        require(
            period == rail.lockupPeriod && lockupFixed <= rail.lockupFixed,
            "failed to modify terminated rail: cannot change period or increase fixed lockup"
        );

        Account storage payer = accounts[rail.token][rail.from];

        // Calculate the fixed lockup reduction - this is the only change allowed for terminated rails
        uint256 lockupReduction = rail.lockupFixed - lockupFixed;

        // Update payer's lockup - subtract the exact reduction amount
        require(
            payer.lockupCurrent >= lockupReduction,
            "payer's current lockup cannot be less than lockup reduction"
        );
        payer.lockupCurrent -= lockupReduction;

        // Reduce operator rate allowance
        OperatorApproval storage operatorApproval = operatorApprovals[
            rail.token
        ][rail.from][rail.operator];
        updateOperatorLockupUsage(
            operatorApproval,
            rail.lockupFixed,
            lockupFixed
        );

        rail.lockupFixed = lockupFixed;
    }

    function modifyNonTerminatedRailLockup(
        Rail storage rail,
        uint256 period,
        uint256 lockupFixed
    ) internal {
        Account storage payer = accounts[rail.token][rail.from];

        // Don't allow changing the lockup period or increasing the fixed lockup unless the payer's
        // account is fully settled.
        if (!isAccountLockupFullySettled(payer)) {
            require(
                period == rail.lockupPeriod,
                "cannot change the lockup period: insufficient funds to cover the current lockup"
            );
            require(
                lockupFixed <= rail.lockupFixed,
                "cannot increase the fixed lockup: insufficient funds to cover the current lockup"
            );
        }

        // Calculate current (old) lockup.
        uint256 oldLockup = rail.lockupFixed +
            (rail.paymentRate * rail.lockupPeriod);

        // Calculate new lockup amount with new parameters
        uint256 newLockup = lockupFixed + (rail.paymentRate * period);

        require(
            payer.lockupCurrent >= oldLockup,
            "payer's current lockup cannot be less than old lockup"
        );

        // We blindly update the payer's lockup. If they don't have enough funds to cover the new
        // amount, we'll revert in the post-condition.
        payer.lockupCurrent = payer.lockupCurrent - oldLockup + newLockup;

        OperatorApproval storage operatorApproval = operatorApprovals[
            rail.token
        ][rail.from][rail.operator];
        updateOperatorLockupUsage(operatorApproval, oldLockup, newLockup);

        // Update rail lockup parameters
        rail.lockupPeriod = period;
        rail.lockupFixed = lockupFixed;
    }

    /// @notice Modifies the payment rate and optionally makes a one-time payment.
    /// - If the rail has already been terminated, one-time payments can be made but the rate may not be increased (only decreased).
    /// - If the payer doesn't have enough funds in their account to settle the rail up to the current epoch, the rail's payment rate may not be changed at all (increased or decreased).
    /// - If the payer's account isn't fully funded, the rail's payment rate may not be increased but it may be decreased.
    /// - Regardless of the payer's account status, one-time payments will always go through provided that the rail has sufficient fixed lockup to cover the payment.
    /// @param railId The ID of the rail to modify.
    /// @param newRate The new payment rate (per epoch). This new rate applies starting the next epoch after the current one.
    /// @param oneTimePayment Optional one-time payment amount to transfer immediately, taken out of the rail's fixed lockup.
    /// @custom:constraint Caller must be the rail operator.
    /// @custom:constraint Operator must have sufficient rate and lockup allowances for any increases.
    function modifyRailPayment(
        uint256 railId,
        uint256 newRate,
        uint256 oneTimePayment
    )
        external
        nonReentrant
        validateRailActive(railId)
        onlyRailOperator(railId)
        settleAccountLockupBeforeAndAfterForRail(railId, false, oneTimePayment)
    {
        Rail storage rail = rails[railId];
        Account storage payer = accounts[rail.token][rail.from];
        Account storage payee = accounts[rail.token][rail.to];

        uint256 oldRate = rail.paymentRate;
        bool isTerminated = isRailTerminated(rail);

        // Validate rate changes based on rail state and account lockup
        if (isTerminated) {
            if (block.number >= maxSettlementEpochForTerminatedRail(rail)) {
                return
                    modifyPaymentForTerminatedRailBeyondLastEpoch(
                        rail,
                        newRate,
                        oneTimePayment
                    );
            }

            require(
                newRate == oldRate,
                "failed to modify rail: cannot change rate on terminated rail"
            );
        } else {
            require(
                isAccountLockupFullySettled(payer) || newRate == oldRate,
                "account lockup not fully settled; cannot change rate"
            );
        }

        // --- Settlement Prior to Rate Change ---
        handleRateChangeSettlement(railId, rail, oldRate, newRate);

        // Calculate the effective lockup period
        uint256 effectiveLockupPeriod;
        if (isTerminated) {
            effectiveLockupPeriod = remainingEpochsForTerminatedRail(rail);
        } else {
            effectiveLockupPeriod = isAccountLockupFullySettled(payer)
                ? rail.lockupPeriod - (block.number - payer.lockupLastSettledAt)
                : 0;
        }

        // Verify one-time payment doesn't exceed fixed lockup
        require(
            rail.lockupFixed >= oneTimePayment,
            "one time payment cannot be greater than rail lockupFixed"
        );

        // Update the rail fixed lockup and payment rate
        rail.lockupFixed = rail.lockupFixed - oneTimePayment;
        rail.paymentRate = newRate;

        OperatorApproval storage operatorApproval = operatorApprovals[
            rail.token
        ][rail.from][rail.operator];

        // Update payer's lockup rate - only if the rail is not terminated
        // for terminated rails, the payer's lockup rate is already updated during rail termination
        if (!isTerminated) {
            require(
                payer.lockupRate >= oldRate,
                "payer lockup rate cannot be less than old rate"
            );
            payer.lockupRate = payer.lockupRate - oldRate + newRate;
            updateOperatorRateUsage(operatorApproval, oldRate, newRate);
        }

        // Update payer's current lockup with effective lockup period calculation
        // Remove old rate lockup for the effective period, add new rate lockup for the same period
        payer.lockupCurrent =
            payer.lockupCurrent -
            (oldRate * effectiveLockupPeriod) +
            (newRate * effectiveLockupPeriod) -
            oneTimePayment;

        updateOperatorLockupUsage(
            operatorApproval,
            oldRate * effectiveLockupPeriod,
            newRate * effectiveLockupPeriod
        );

        // Update operator allowance for one-time payment
        updateOperatorAllowanceForOneTimePayment(
            operatorApproval,
            oneTimePayment
        );

        // --- Process the One-Time Payment ---
        processOneTimePayment(payer, payee, oneTimePayment);
    }

    function modifyPaymentForTerminatedRailBeyondLastEpoch(
        Rail storage rail,
        uint256 newRate,
        uint256 oneTimePayment
    ) internal {
        uint256 endEpoch = maxSettlementEpochForTerminatedRail(rail);
        require(
            newRate == 0 && oneTimePayment == 0,
            "for terminated rails beyond last settlement epoch, both new rate and one-time payment must be 0"
        );

        // Check if we need to record the current rate in the queue (should only do this once for the last epoch)
        if (
            rail.rateChangeQueue.isEmpty() ||
            rail.rateChangeQueue.peekTail().untilEpoch < endEpoch
        ) {
            // Queue the current rate up to the max settlement epoch
            rail.rateChangeQueue.enqueue(rail.paymentRate, endEpoch);
        }

        // Set payment rate to 0 as the rail is past its last settlement epoch
        rail.paymentRate = 0;
    }

    function handleRateChangeSettlement(
        uint256 railId,
        Rail storage rail,
        uint256 oldRate,
        uint256 newRate
    ) internal {
        // If rate hasn't changed, nothing to do
        if (newRate == oldRate) {
            return;
        }

        // No need to settle the rail or enqueue the rate change if the rail has already been settled upto
        // the current epoch
        if (rail.settledUpTo == block.number) {
            return;
        }

        // If there is no arbiter, settle the rail immediately
        if (rail.arbiter == address(0)) {
            (, uint256 settledUpto, ) = settleRail(railId, block.number);
            require(
                settledUpto == block.number,
                "failed to settle rail up to current epoch"
            );
            return;
        }

        // For arbitrated rails with rate change, handle queue
        // Only queue the previous rate once per epoch
        if (
            rail.rateChangeQueue.isEmpty() ||
            rail.rateChangeQueue.peekTail().untilEpoch != block.number
        ) {
            // For arbitrated rails, we need to enqueue the old rate.
            // This ensures that the old rate is applied up to and including the current block.
            // The new rate will be applicable starting from the next block.
            rail.rateChangeQueue.enqueue(oldRate, block.number);
        }
    }

    function processOneTimePayment(
        Account storage payer,
        Account storage payee,
        uint256 oneTimePayment
    ) internal {
        if (oneTimePayment > 0) {
            require(
                payer.funds >= oneTimePayment,
                "insufficient funds for one-time payment"
            );
            payer.funds -= oneTimePayment;
            payee.funds += oneTimePayment;
        }
    }

    /// @notice Settles payments for a terminated rail without arbitration. This may only be called by the payee and after the terminated rail's max settlement epoch has passed. It's an escape-hatch to unblock payments in an otherwise stuck rail (e.g., due to a buggy arbiter contract) and it always pays in full.
    /// @param railId The ID of the rail to settle.
    /// @return totalSettledAmount The total amount settled and transferred.
    /// @return finalSettledEpoch The epoch up to which settlement was actually completed.
    /// @return note Additional information about the settlement.
    function settleTerminatedRailWithoutArbitration(
        uint256 railId
    )
        external
        nonReentrant
        validateRailActive(railId)
        validateRailTerminated(railId)
        onlyRailClient(railId)
        settleAccountLockupBeforeAndAfterForRail(railId, false, 0)
        returns (
            uint256 totalSettledAmount,
            uint256 finalSettledEpoch,
            string memory note
        )
    {
        // Verify the current epoch is greater than the max settlement epoch
        uint256 maxSettleEpoch = maxSettlementEpochForTerminatedRail(
            rails[railId]
        );
        require(
            block.number > maxSettleEpoch,
            "terminated rail can only be settled without arbitration after max settlement epoch"
        );

        return settleRailInternal(railId, maxSettleEpoch, true);
    }

    /// @notice Settles payments for a rail up to the specified epoch. Settlement may fail to reach the target epoch if either the client lacks the funds to pay up to the current epoch or the arbiter refuses to settle the entire requested range.
    /// @param railId The ID of the rail to settle.
    /// @param untilEpoch The epoch up to which to settle (must not exceed current block number).
    /// @return totalSettledAmount The total amount settled and transferred.
    /// @return finalSettledEpoch The epoch up to which settlement was actually completed.
    /// @return note Additional information about the settlement (especially from arbitration).
    function settleRail(
        uint256 railId,
        uint256 untilEpoch
    )
        public
        nonReentrant
        validateRailActive(railId)
        settleAccountLockupBeforeAndAfterForRail(railId, false, 0)
        returns (
            uint256 totalSettledAmount,
            uint256 finalSettledEpoch,
            string memory note
        )
    {
        return settleRailInternal(railId, untilEpoch, false);
    }

    function settleRailInternal(
        uint256 railId,
        uint256 untilEpoch,
        bool skipArbitration
    )
        internal
        returns (
            uint256 totalSettledAmount,
            uint256 finalSettledEpoch,
            string memory note
        )
    {
        require(
            untilEpoch <= block.number,
            "failed to settle: cannot settle future epochs"
        );

        Rail storage rail = rails[railId];
        Account storage payer = accounts[rail.token][rail.from];

        // Handle terminated and fully settled rails that are still not finalised
        if (
            isRailTerminated(rail) &&
            rail.settledUpTo >= maxSettlementEpochForTerminatedRail(rail)
        ) {
            finalizeTerminatedRail(rail, payer);
            return (0, rail.settledUpTo, "rail fully settled and finalized");
        }

        // Calculate the maximum settlement epoch based on account lockup
        uint256 maxSettlementEpoch;
        if (!isRailTerminated(rail)) {
            maxSettlementEpoch = min(untilEpoch, payer.lockupLastSettledAt);
        } else {
            maxSettlementEpoch = min(
                untilEpoch,
                maxSettlementEpochForTerminatedRail(rail)
            );
        }

        uint256 startEpoch = rail.settledUpTo;
        // Nothing to settle (already settled or zero-duration)
        if (startEpoch >= maxSettlementEpoch) {
            return (
                0,
                startEpoch,
                string.concat(
                    "already settled up to epoch ",
                    Strings.toString(maxSettlementEpoch)
                )
            );
        }

        // For zero rate rails with empty queue, just advance the settlement epoch
        // without transferring funds
        uint256 currentRate = rail.paymentRate;
        if (currentRate == 0 && rail.rateChangeQueue.isEmpty()) {
            rail.settledUpTo = maxSettlementEpoch;

            return
                checkAndFinalizeTerminatedRail(
                    rail,
                    payer,
                    0,
                    maxSettlementEpoch,
                    "zero rate payment rail",
                    "zero rate terminated rail fully settled and finalized"
                );
        }

        // Process settlement depending on whether rate changes exist
        if (rail.rateChangeQueue.isEmpty()) {
            (uint256 amount, string memory segmentNote) = _settleSegment(
                railId,
                startEpoch,
                maxSettlementEpoch,
                currentRate,
                skipArbitration
            );

            require(rail.settledUpTo > startEpoch, "No progress in settlement");

            return
                checkAndFinalizeTerminatedRail(
                    rail,
                    payer,
                    amount,
                    rail.settledUpTo,
                    segmentNote,
                    string.concat(
                        segmentNote,
                        "terminated rail fully settled and finalized."
                    )
                );
        } else {
            (
                uint256 settledAmount,
                string memory settledNote
            ) = _settleWithRateChanges(
                    railId,
                    currentRate,
                    startEpoch,
                    maxSettlementEpoch,
                    skipArbitration
                );

            return
                checkAndFinalizeTerminatedRail(
                    rail,
                    payer,
                    settledAmount,
                    rail.settledUpTo,
                    settledNote,
                    string.concat(
                        settledNote,
                        "terminated rail fully settled and finalized."
                    )
                );
        }
    }

    // Helper function to check and finalize a terminated rail if needed
    function checkAndFinalizeTerminatedRail(
        Rail storage rail,
        Account storage payer,
        uint256 amount,
        uint256 finalEpoch,
        string memory regularNote,
        string memory finalizedNote
    ) internal returns (uint256, uint256, string memory) {
        // Check if rail is a terminated rail that's now fully settled
        if (
            isRailTerminated(rail) &&
            rail.settledUpTo >= maxSettlementEpochForTerminatedRail(rail)
        ) {
            finalizeTerminatedRail(rail, payer);
            return (amount, finalEpoch, finalizedNote);
        }

        return (amount, finalEpoch, regularNote);
    }

    function finalizeTerminatedRail(
        Rail storage rail,
        Account storage payer
    ) internal {
        // Reduce the lockup by the fixed amount
        require(
            payer.lockupCurrent >= rail.lockupFixed,
            "lockup inconsistency during rail finalization"
        );
        payer.lockupCurrent -= rail.lockupFixed;

        // Get operator approval for finalization update
        OperatorApproval storage operatorApproval = operatorApprovals[
            rail.token
        ][rail.from][rail.operator];

        updateOperatorLockupUsage(operatorApproval, rail.lockupFixed, 0);

        // Zero out the rail to mark it as inactive
        _zeroOutRail(rail);
    }

    function _settleWithRateChanges(
        uint256 railId,
        uint256 currentRate,
        uint256 startEpoch,
        uint256 targetEpoch,
        bool skipArbitration
    ) internal returns (uint256 totalSettled, string memory note) {
        Rail storage rail = rails[railId];
        RateChangeQueue.Queue storage rateQueue = rail.rateChangeQueue;

        totalSettled = 0;
        uint256 processedEpoch = startEpoch;
        note = "";

        // Process each segment until we reach the target epoch or hit an early exit condition
        while (processedEpoch < targetEpoch) {
            // Default boundary is the target we want to reach
            uint256 segmentEndBoundary = targetEpoch;
            uint256 segmentRate;

            // If we have rate changes in the queue, use the rate from the next change
            if (!rateQueue.isEmpty()) {
                RateChangeQueue.RateChange memory nextRateChange = rateQueue
                    .peek();

                // Validate rate change queue consistency
                require(
                    nextRateChange.untilEpoch >= processedEpoch,
                    "rate queue is in an invalid state"
                );

                // Boundary is the minimum of our target or the next rate change epoch
                segmentEndBoundary = min(
                    targetEpoch,
                    nextRateChange.untilEpoch
                );
                segmentRate = nextRateChange.rate;
            } else {
                // If queue is empty, use the current rail rate
                segmentRate = currentRate;

                // if current rate is zero, there's nothing left to do and we've finished settlement
                if (segmentRate == 0) {
                    rail.settledUpTo = targetEpoch;
                    return (totalSettled, "Zero rate payment rail");
                }
            }

            // Settle the current segment with potentially arbitrated outcomes
            (
                uint256 segmentAmount,
                string memory arbitrationNote
            ) = _settleSegment(
                    railId,
                    processedEpoch,
                    segmentEndBoundary,
                    segmentRate,
                    skipArbitration
                );

            // If arbiter returned no progress, exit early without updating state
            if (rail.settledUpTo <= processedEpoch) {
                return (totalSettled, arbitrationNote);
            }

            // Add the settled amount to our running total
            totalSettled += segmentAmount;

            // If arbiter partially settled the segment, exit early
            if (rail.settledUpTo < segmentEndBoundary) {
                return (totalSettled, arbitrationNote);
            }

            // Successfully settled full segment, update tracking values
            processedEpoch = rail.settledUpTo;
            note = arbitrationNote;

            // Remove the processed rate change from the queue
            if (!rateQueue.isEmpty()) {
                rateQueue.dequeue();
            }
        }

        // We've successfully settled up to the target epoch
        return (totalSettled, note);
    }

    function _settleSegment(
        uint256 railId,
        uint256 epochStart,
        uint256 epochEnd,
        uint256 rate,
        bool skipArbitration
    ) internal returns (uint256 settledAmount, string memory note) {
        Rail storage rail = rails[railId];
        Account storage payer = accounts[rail.token][rail.from];
        Account storage payee = accounts[rail.token][rail.to];

        // Calculate the default settlement values (without arbitration)
        uint256 duration = epochEnd - epochStart;
        settledAmount = rate * duration;
        uint256 settledUntilEpoch = epochEnd;
        note = "";

        // If this rail has an arbiter and we're not skipping arbitration, let it decide on the final settlement amount
        if (rail.arbiter != address(0) && !skipArbitration) {
            IArbiter arbiter = IArbiter(rail.arbiter);
            IArbiter.ArbitrationResult memory result = arbiter.arbitratePayment(
                railId,
                settledAmount,
                epochStart,
                epochEnd
            );

            // Ensure arbiter doesn't settle beyond our segment's end boundary
            require(
                result.settleUpto <= epochEnd,
                "arbiter settled beyond segment end"
            );
            require(
                result.settleUpto >= epochStart,
                "arbiter settled before segment start"
            );

            settledUntilEpoch = result.settleUpto;
            settledAmount = result.modifiedAmount;
            note = result.note;

            // Ensure arbiter doesn't allow more payment than the maximum possible
            // for the epochs they're confirming
            uint256 maxAllowedAmount = rate * (settledUntilEpoch - epochStart);
            require(
                result.modifiedAmount <= maxAllowedAmount,
                "arbiter modified amount exceeds maximum for settled duration"
            );
        }

        // Verify payer has sufficient funds for the settlement
        require(
            payer.funds >= settledAmount,
            "failed to settle: insufficient funds to cover settlement"
        );

        // Verify payer has sufficient lockup for the settlement
        require(
            payer.lockupCurrent >= settledAmount,
            "failed to settle: insufficient lockup to cover settlement"
        );

        // Transfer funds from payer to payee
        payer.funds -= settledAmount;
        payee.funds += settledAmount;

        // Reduce the lockup by the settled amount
        payer.lockupCurrent -= settledAmount;

        // Update the rail's settled epoch
        rail.settledUpTo = settledUntilEpoch;

        // Invariant check: lockup should never exceed funds
        require(
            payer.lockupCurrent <= payer.funds,
            "failed to settle: invariant violation: insufficient funds to cover lockup after settlement"
        );

        return (settledAmount, note);
    }

    function isAccountLockupFullySettled(
        Account storage account
    ) internal view returns (bool) {
        return account.lockupLastSettledAt == block.number;
    }

    // attempts to settle account lockup up to and including the current epoch
    // returns the actual epoch upto and including which the lockup was settled
    function settleAccountLockup(
        Account storage account
    ) internal returns (uint256) {
        uint256 currentEpoch = block.number;
        uint256 elapsedTime = currentEpoch - account.lockupLastSettledAt;

        if (elapsedTime <= 0) {
            return account.lockupLastSettledAt;
        }

        if (account.lockupRate == 0) {
            account.lockupLastSettledAt = currentEpoch;
            return currentEpoch;
        }

        uint256 additionalLockup = account.lockupRate * elapsedTime;

        // we have sufficient funds to cover account lockup upto and including the current epoch
        if (account.funds >= account.lockupCurrent + additionalLockup) {
            account.lockupCurrent += additionalLockup;
            account.lockupLastSettledAt = currentEpoch;
            return currentEpoch;
        }

        require(
            account.funds >= account.lockupCurrent,
            "failed to settle: invariant violation: insufficient funds to cover lockup"
        );
        // If insufficient, calculate the fractional epoch where funds became insufficient
        uint256 availableFunds = account.funds - account.lockupCurrent;

        if (availableFunds == 0) {
            return account.lockupLastSettledAt;
        }

        // Round down to the nearest whole epoch
        uint256 fractionalEpochs = availableFunds / account.lockupRate;

        // Apply lockup up to this point
        account.lockupCurrent += account.lockupRate * fractionalEpochs;
        account.lockupLastSettledAt =
            account.lockupLastSettledAt +
            fractionalEpochs;
        return account.lockupLastSettledAt;
    }

    function remainingEpochsForTerminatedRail(
        Rail storage rail
    ) internal view returns (uint256) {
        require(isRailTerminated(rail), "rail is not terminated");

        // If current block beyond end epoch, return 0
        if (block.number > rail.endEpoch) {
            return 0;
        }

        // Return the number of epochs (blocks) remaining until end epoch
        return rail.endEpoch - block.number;
    }

    function isRailTerminated(Rail storage rail) internal view returns (bool) {
        require(
            rail.from != address(0),
            "failed to check: rail does not exist"
        );
        return rail.endEpoch > 0;
    }

    // Get the final settlement epoch for a terminated rail
    function maxSettlementEpochForTerminatedRail(
        Rail storage rail
    ) internal view returns (uint256) {
        require(isRailTerminated(rail), "rail is not terminated");
        return rail.endEpoch;
    }

    function _zeroOutRail(Rail storage rail) internal {
        // Check if queue is empty before clearing
        require(
            rail.rateChangeQueue.isEmpty(),
            "rate change queue must be empty post full settlement"
        );

        // Clear the rate change queue
        rail.rateChangeQueue.clear();

        rail.token = address(0);
        rail.from = address(0); // This now marks the rail as inactive
        rail.to = address(0);
        rail.operator = address(0);
        rail.arbiter = address(0);
        rail.paymentRate = 0;
        rail.lockupFixed = 0;
        rail.lockupPeriod = 0;
        rail.settledUpTo = 0;
        rail.endEpoch = 0;
    }

    function updateOperatorRateUsage(
        OperatorApproval storage approval,
        uint256 oldRate,
        uint256 newRate
    ) internal {
        if (newRate > oldRate) {
            uint256 rateIncrease = newRate - oldRate;
            require(
                approval.rateUsage + rateIncrease <= approval.rateAllowance,
                "operation exceeds operator rate allowance"
            );
            approval.rateUsage += rateIncrease;
        } else if (oldRate > newRate) {
            uint256 rateDecrease = oldRate - newRate;
            approval.rateUsage = approval.rateUsage > rateDecrease
                ? approval.rateUsage - rateDecrease
                : 0;
        }
    }

    function updateOperatorLockupUsage(
        OperatorApproval storage approval,
        uint256 oldLockup,
        uint256 newLockup
    ) internal {
        if (newLockup > oldLockup) {
            uint256 lockupIncrease = newLockup - oldLockup;
            require(
                approval.lockupUsage + lockupIncrease <=
                    approval.lockupAllowance,
                "operation exceeds operator lockup allowance"
            );
            approval.lockupUsage += lockupIncrease;
        } else if (oldLockup > newLockup) {
            uint256 lockupDecrease = oldLockup - newLockup;
            approval.lockupUsage = approval.lockupUsage > lockupDecrease
                ? approval.lockupUsage - lockupDecrease
                : 0;
        }
    }

    function updateOperatorAllowanceForOneTimePayment(
        OperatorApproval storage approval,
        uint256 oneTimePayment
    ) internal {
        if (oneTimePayment == 0) return;

        // Reduce lockup usage
        approval.lockupUsage = approval.lockupUsage - oneTimePayment;

        // Reduce lockup allowance
        approval.lockupAllowance = oneTimePayment > approval.lockupAllowance
            ? 0
            : approval.lockupAllowance - oneTimePayment;
    }
}

function min(uint256 a, uint256 b) pure returns (uint256) {
    return a < b ? a : b;
}
