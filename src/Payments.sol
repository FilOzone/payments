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
        uint256 terminationEpoch; // Epoch at which the rail was terminated (0 if not terminated)
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
            "rail does not exist or is inactive"
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
        require(rails[railId].terminationEpoch == 0, "rail already terminated");
        _;
    }

    modifier validateRailTerminated(uint256 railId) {
        require(
            isRailTerminated(rails[railId]),
            "can only be used on terminated rails"
        );
        _;
    }

    modifier validateRailNotInDebt(uint256 railId) {
        Rail storage rail = rails[railId];
        Account storage payer = accounts[rail.token][rail.from];
        require(!isRailInDebt(rail, payer), "rail is in debt");
        _;
    }

    modifier validateNonZeroAddress(address addr, string memory varName) {
        require(
            addr != address(0),
            string.concat(varName, " address cannot be zero")
        );
        _;
    }

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

    function terminateRail(
        uint256 railId
    )
        external
        validateRailActive(railId)
        nonReentrant
        onlyRailParticipant(railId)
        validateRailNotTerminated(railId)
    {
        Rail storage rail = rails[railId];
        Account storage payer = accounts[rail.token][rail.from];
        OperatorApproval storage approval = operatorApprovals[rail.token][
            rail.from
        ][rail.operator];

        // Settle account lockup to ensure we're up to date
        uint256 settledUntil = settleAccountLockup(payer);

        // Verify that the account is fully settled up to the current epoch
        // This ensures that the client has enough funds locked to settle the rail upto
        // and including (termination epoch aka current epoch + rail lockup period)
        require(
            settledUntil >= block.number,
            "cannot terminate rail: failed to settle account lockup completely"
        );

        rail.terminationEpoch = block.number;

        // Remove the rail rate from account lockup rate but don't set rail rate to zero yet.
        // The rail rate will be used to settle the rail and so we can't zero it yet.
        // However, we remove the rail rate from the client lockup rate because we don't want to
        // lock funds for the rail beyond (current epoch + rail.lockup Period) as we're exiting the rail
        // after that epoch.
        // Since we fully settled the account lockup upto and including the current epoch above,
        // we have enough client funds locked to settle the rail upto and including the (termination epoch + rail.lockupPeriod)
        require(
            payer.lockupRate >= rail.paymentRate,
            "lockup rate inconsistency"
        );
        payer.lockupRate -= rail.paymentRate;

        // Update operator approval rate usage
        require(
            approval.rateUsage >= rail.paymentRate,
            "invariant violation: operator rate usage must be at least the rail payment rate"
        );
        approval.rateUsage -= rail.paymentRate;
    }

    function deposit(
        address token,
        address to,
        uint256 amount
    )
        external
        nonReentrant
        validateNonZeroAddress(token, "token")
        validateNonZeroAddress(to, "to")
    {
        require(amount > 0, "amount must be greater than 0");

        // Create account if it doesn't exist
        Account storage account = accounts[token][to];

        // Transfer tokens from sender to contract
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);

        // Update account balance
        account.funds += amount;
    }

    function withdraw(
        address token,
        uint256 amount
    ) external nonReentrant validateNonZeroAddress(token, "token") {
        return withdrawToInternal(token, msg.sender, amount);
    }

    function withdrawTo(
        address token,
        address to,
        uint256 amount
    )
        external
        nonReentrant
        validateNonZeroAddress(token, "token")
        validateNonZeroAddress(to, "to")
    {
        return withdrawToInternal(token, to, amount);
    }

    function withdrawToInternal(
        address token,
        address to,
        uint256 amount
    ) 
        internal 
        validateNonZeroAddress(token, "token")
        validateNonZeroAddress(to, "recipient")
    {
        Account storage account = accounts[token][msg.sender];
        uint256 available = account.funds - account.lockupCurrent;
        require(
            amount <= available,
            "insufficient unlocked funds for withdrawal"
        );
        account.funds -= amount;
        IERC20(token).safeTransfer(to, amount);
    }

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
        rail.terminationEpoch = 0;

        return railId;
    }

    function modifyRailLockup(
        uint256 railId,
        uint256 period,
        uint256 lockupFixed
    )
        external
        validateRailActive(railId)
        onlyRailOperator(railId)
        nonReentrant
        validateRailNotInDebt(railId)
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
        OperatorApproval storage approval = operatorApprovals[rail.token][
            rail.from
        ][rail.operator];

        // we don't need to ensure that the account lockup is fully settled here
        // because we already ensure that enough funds are locked for a terminated rail during
        // `terminateRail`
        settleAccountLockup(payer);

        // Calculate the fixed lockup reduction - this is the only change allowed for terminated rails
        uint256 lockupReduction = rail.lockupFixed - lockupFixed;

        // For terminated rails (whether fully settled or still in settlement period),
        // we only need to reduce the fixed lockup amount directly because:
        // 1. Period remains unchanged (enforced by the require statement above)
        // 2. The rate-based portion of the lockup doesn't change
        // 3. The only thing changing is the fixed lockup, which is being reduced

        // Update operator allowance - reduce usage by the exact reduction amount
        approval.lockupUsage -= lockupReduction;

        // Update payer's lockup - subtract the exact reduction amount
        require(
            payer.lockupCurrent >= lockupReduction,
            "payer's current lockup cannot be less than lockup reduction"
        );
        payer.lockupCurrent -= lockupReduction;

        rail.lockupFixed = lockupFixed;

        // Final safety check
        require(
            payer.lockupCurrent <= payer.funds,
            "invariant violation: payer's current lockup cannot be greater than their funds"
        );
    }

    function modifyNonTerminatedRailLockup(
        Rail storage rail,
        uint256 period,
        uint256 lockupFixed
    ) internal {
        Account storage payer = accounts[rail.token][rail.from];
        OperatorApproval storage approval = operatorApprovals[rail.token][
            rail.from
        ][rail.operator];

        // Settle account lockup as much as possible
        uint256 lockupSettledUpto = settleAccountLockup(payer);
        // Only require full settlement if increasing period or fixed lockup
        if (period > rail.lockupPeriod || lockupFixed > rail.lockupFixed) {
            require(
                lockupSettledUpto == block.number,
                "cannot increase lockup: client funds insufficient for current account lockup settlement"
            );
        } else if (period < rail.lockupPeriod) {
            // When reducing period, ensure we still cover all unsettled epochs
            require(
                payer.lockupLastSettledAt + period >= block.number,
                "cannot reduce lockup period below what's needed for unsettled epochs"
            );
        }

        // Calculate effective lockup period for the old period
        uint256 oldEffectiveLockupPeriod = rail.lockupPeriod -
            (block.number - payer.lockupLastSettledAt);

        // Calculate effective lockup period for the updated period
        uint256 newEffectiveLockupPeriod = period -
            (block.number - payer.lockupLastSettledAt);

        // Calculate current (old) lockup using effective lockup period
        uint256 oldLockup = rail.lockupFixed +
            (rail.paymentRate * oldEffectiveLockupPeriod);

        // Calculate new lockup amount with new parameters
        // We can safely use min(period, effectiveLockupPeriod) here now that we've added
        // the explicit check to ensure period doesn't fall below unsettled epochs
        uint256 newLockup = lockupFixed +
            (rail.paymentRate * newEffectiveLockupPeriod);

        // Update operator allowance tracking based on lockup changes
        updateOperatorLockupTracking(approval, oldLockup, newLockup);

        require(
            payer.lockupCurrent >= oldLockup,
            "payer's current lockup cannot be less than old lockup"
        );

        payer.lockupCurrent = payer.lockupCurrent - oldLockup + newLockup;

        // Update rail lockup parameters
        rail.lockupPeriod = period;
        rail.lockupFixed = lockupFixed;

        // Final safety check: ensure lockup doesn't exceed available funds
        require(
            payer.lockupCurrent <= payer.funds,
            "invariant violation: payer's current lockup cannot be greater than their funds"
        );
    }

    function modifyRailPayment(
        uint256 railId,
        uint256 newRate,
        uint256 oneTimePayment
    )
        external
        validateRailActive(railId)
        onlyRailOperator(railId)
        nonReentrant
    {
        Rail storage rail = rails[railId];
        Account storage payer = accounts[rail.token][rail.from];
        Account storage payee = accounts[rail.token][rail.to];

        uint256 oldRate = rail.paymentRate;
        bool isTerminated = isRailTerminated(rail);

        // Settle the payer's lockup to account for elapsed time
        uint256 lockupSettledUpto = settleAccountLockup(payer);

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
                newRate <= oldRate,
                "failed to modify rail: cannot increase rate on terminated rail"
            );
        } else {
            validateRateChangeRequirementsForNonTerminatedRail(
                rail,
                payer,
                oldRate,
                newRate,
                lockupSettledUpto
            );
        }

        // --- Settlement Prior to Rate Change ---
        handleRateChangeSettlement(railId, rail, oldRate, newRate);

        // Calculate the effective lockup period
        uint256 effectiveLockupPeriod;
        if (isTerminated) {
            effectiveLockupPeriod = remainingEpochsForTerminatedRail(rail);
        } else {
            effectiveLockupPeriod = isRailInDebt(rail, payer)
                ? 0
                : rail.lockupPeriod -
                    (block.number - payer.lockupLastSettledAt);
        }

        // Verify one-time payment doesn't exceed fixed lockup
        require(
            rail.lockupFixed >= oneTimePayment,
            "one time payment cannot be greater than rail lockupFixed"
        );

        // --- Operator Approval Checks
        OperatorApproval storage approval = operatorApprovals[rail.token][
            rail.from
        ][rail.operator];
        validateAndModifyRateChangeApproval(
            rail,
            approval,
            oldRate,
            newRate,
            oneTimePayment,
            effectiveLockupPeriod
        );

        // Update the rail fixed lockup and payment rate
        rail.lockupFixed = rail.lockupFixed - oneTimePayment;
        rail.paymentRate = newRate;

        // Update payer's lockup rate - only if the rail is not terminated
        // for terminated rails, the payer's lockup rate is already updated during rail termination
        if (!isTerminated) {
            require(
                payer.lockupRate >= oldRate,
                "payer lockup rate cannot be less than old rate"
            );
            payer.lockupRate = payer.lockupRate - oldRate + newRate;
        }

        // Update payer's current lockup with effective lockup period calculation
        // Remove old rate lockup for the effective period, add new rate lockup for the same period
        payer.lockupCurrent =
            payer.lockupCurrent -
            (oldRate * effectiveLockupPeriod) +
            (newRate * effectiveLockupPeriod) -
            oneTimePayment;

        // --- Process the One-Time Payment ---
        processOneTimePayment(payer, payee, oneTimePayment);

        // Ensure the modified lockup doesn't exceed available funds
        require(
            payer.lockupCurrent <= payer.funds,
            "invariant violation: payer lockup cannot exceed funds"
        );
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

    function validateRateChangeRequirementsForNonTerminatedRail(
        Rail storage rail,
        Account storage payer,
        uint256 oldRate,
        uint256 newRate,
        uint256 lockupSettledUpto
    ) internal view {
        if (lockupSettledUpto == block.number) {
            // if account lockup is fully settled; there's nothing to check
            return;
        }

        // Case 2.A: Lockup not fully settled -> check if rail is in debt
        if (isRailInDebt(rail, payer)) {
            require(newRate == oldRate, "rail is in-debt; cannot change rate");
            return;
        }

        // Case 2.B: Lockup not fully settled but rail is not in debt -> check if rate is being increased
        require(
            newRate <= oldRate,
            "account lockup not fully settled; cannot increase rate"
        );
    }

    function updateOperatorLockupTracking(
        OperatorApproval storage approval,
        uint256 oldLockup,
        uint256 newLockup
    ) internal {
        if (newLockup < oldLockup) {
            uint256 lockupDecrease = oldLockup - newLockup;
            approval.lockupUsage -= lockupDecrease;
            return;
        }

        // Handle lockup increase
        uint256 lockupIncrease = newLockup - oldLockup;

        // Verify against allowance
        require(
            approval.lockupUsage + lockupIncrease <= approval.lockupAllowance,
            "exceeds operator lockup allowance"
        );

        // Update usage
        approval.lockupUsage += lockupIncrease;
    }

    function validateAndModifyRateChangeApproval(
        Rail storage rail,
        OperatorApproval storage approval,
        uint256 oldRate,
        uint256 newRate,
        uint256 oneTimePayment,
        uint256 effectiveLockupPeriod
    ) internal {
        // Handle rate-based lockup changes
        uint256 oldLockup = (oldRate * effectiveLockupPeriod) +
            rail.lockupFixed;
        uint256 newLockup = (newRate * effectiveLockupPeriod) +
            (rail.lockupFixed - oneTimePayment);

        updateOperatorLockupTracking(approval, oldLockup, newLockup);

        if (oneTimePayment > 0) {
            // one-time payments count towards lockup usage
            require(
                approval.lockupUsage + oneTimePayment <=
                    approval.lockupAllowance,
                "one-time payment exceeds operator lockup allowance"
            );
            approval.lockupUsage += oneTimePayment;
        }

        // handle a rate decrease
        if (newRate < oldRate) {
            uint256 rateDecrease = oldRate - newRate;
            approval.rateUsage -= rateDecrease;
            return;
        }

        // Rate increase
        uint256 rateIncrease = newRate - oldRate;
        require(
            approval.rateUsage + rateIncrease <= approval.rateAllowance,
            "new rate exceeds operator rate allowance"
        );
        approval.rateUsage += rateIncrease;
    }

    function settleTerminatedRailWithoutArbitration(
        uint256 railId
    )
        external
        validateRailActive(railId)
        validateRailTerminated(railId)
        onlyRailClient(railId)
        nonReentrant
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

    function settleRail(
        uint256 railId,
        uint256 untilEpoch
    )
        public
        validateRailActive(railId)
        nonReentrant
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

        // Update the payer's lockup to account for elapsed time
        settleAccountLockup(payer);

        // Handle terminated rails
        if (isRailTerminated(rail)) {
            uint256 maxTerminatedRailSettlementEpoch = maxSettlementEpochForTerminatedRail(
                    rail
                );

            // If rail is already fully settled but still active, finalize it
            if (rail.settledUpTo >= maxTerminatedRailSettlementEpoch) {
                finalizeTerminatedRail(rail, payer);
                return (
                    0,
                    rail.settledUpTo,
                    "rail fully settled and finalized"
                );
            }

            // For terminated but not fully settled rails, limit settlement window
            untilEpoch = min(untilEpoch, maxTerminatedRailSettlementEpoch);
        }

        uint256 maxLockupSettlementEpoch = payer.lockupLastSettledAt +
            rail.lockupPeriod;
        uint256 maxSettlementEpoch = min(untilEpoch, maxLockupSettlementEpoch);

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

    // Helper function to finalize a terminated rail
    function finalizeTerminatedRail(
        Rail storage rail,
        Account storage payer
    ) internal {
        // Get operator approval to reduce usage
        OperatorApproval storage approval = operatorApprovals[rail.token][
            rail.from
        ][rail.operator];

        // Reduce operator's lockup usage by the fixed amount
        require(
            approval.lockupUsage >= rail.lockupFixed,
            "invariant violation: operator lockup usage cannot be less than rail fixed lockup"
        );
        approval.lockupUsage -= rail.lockupFixed;

        // Reduce the lockup by the fixed amount
        require(
            payer.lockupCurrent >= rail.lockupFixed,
            "lockup inconsistency during rail finalization"
        );
        payer.lockupCurrent -= rail.lockupFixed;

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

    function maxSettlementEpochForTerminatedRail(
        Rail storage rail
    ) internal view returns (uint256) {
        require(isRailTerminated(rail), "rail is not terminated");
        return rail.terminationEpoch + rail.lockupPeriod;
    }

    function remainingEpochsForTerminatedRail(
        Rail storage rail
    ) internal view returns (uint256) {
        require(isRailTerminated(rail), "rail is not terminated");

        // Calculate the maximum settlement epoch for this terminated rail
        uint256 maxSettlementEpoch = maxSettlementEpochForTerminatedRail(rail);

        // If current block beyond max settlement, return 0
        if (block.number > maxSettlementEpoch) {
            return 0;
        }

        // Return the number of epochs (blocks) remaining until max settlement
        return maxSettlementEpoch - block.number;
    }

    function isRailTerminated(Rail storage rail) internal view returns (bool) {
        require(
            rail.from != address(0),
            "failed to check: rail does not exist"
        );
        return rail.terminationEpoch > 0;
    }

    function isRailInDebt(
        Rail storage rail,
        Account storage payer
    ) internal view returns (bool) {
        return block.number > payer.lockupLastSettledAt + rail.lockupPeriod;
    }

    function _zeroOutRail(Rail storage rail) internal {
        rail.token = address(0);
        rail.from = address(0); // This now marks the rail as inactive
        rail.to = address(0);
        rail.operator = address(0);
        rail.arbiter = address(0);
        rail.paymentRate = 0;
        rail.lockupFixed = 0;
        rail.lockupPeriod = 0;
        rail.settledUpTo = 0;
        rail.terminationEpoch = 0;

        // Clear the rate change queue
        rail.rateChangeQueue.clear();
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
}

function min(uint256 a, uint256 b) pure returns (uint256) {
    return a < b ? a : b;
}
