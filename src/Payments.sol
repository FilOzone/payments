// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "./RateChangeQueue.sol";

interface IArbiter {
    struct ArbitrationResult {
        uint256 modifiedAmount;
        // The epoch up to and including which settlement should occur.
        // This is used to indicate how far the arbitration has settled the payment.
        uint256 settleUpto;
        string note;
    }

    function arbitratePayment(
        uint256 railId,
        uint256 proposedAmount,
        // the epoch up to and including which the rail has already been settled
        uint256 fromEpoch,
        // the epoch up to which arbitration is requested; payment will be arbitrated for (toEpoch - fromEpoch) epochs
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
        // The epoch up to and including which lockup has been settled for the account
        uint256 lockupLastSettledAt;
    }

    struct Rail {
        bool isActive;
        address token;
        address from;
        address to;
        address operator;
        address arbiter;
        uint256 paymentRate;
        uint256 lockupPeriod;
        uint256 lockupFixed;
        // The epoch up to and including which this rail has been settled
        uint256 settledUpTo;
        RateChangeQueue.Queue rateChangeQueue;
        bool isLocked; // Indicates if the rail is currently being modified
    }

    struct OperatorApproval {
        bool isApproved;
        uint256 rateAllowance;
        uint256 lockupAllowance;
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

    // client => operator => railIds
    mapping(address => mapping(address => uint256[]))
        public clientOperatorRails;

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
        require(rails[railId].from != address(0), "rail does not exist");
        require(rails[railId].isActive, "rail is inactive");
        _;
    }

    modifier noRailModificationInProgress(uint256 railId) {
        require(!rails[railId].isLocked, "Modification already in progress");
        rails[railId].isLocked = true;
        _;
        rails[railId].isLocked = false;
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

    function approveOperator(
        address token,
        address operator,
        uint256 rateAllowance,
        uint256 lockupAllowance
    ) external {
        require(token != address(0), "token address cannot be zero");
        require(operator != address(0), "operator address cannot be zero");

        OperatorApproval storage approval = operatorApprovals[token][
            msg.sender
        ][operator];
        approval.rateAllowance = rateAllowance;
        approval.lockupAllowance = lockupAllowance;
        approval.isApproved = true;
    }

    // TODO: Implement Me
    // https://github.com/FilOzone/payments/pull/1/files#r1974415624
    function terminateOperator(address operator) external {}

    function deposit(
        address token,
        address to,
        uint256 amount
    ) external nonReentrant {
        require(token != address(0), "token address cannot be zero");
        require(to != address(0), "to address cannot be zero");
        require(amount > 0, "amount must be greater than 0");

        // Create account if it doesn't exist
        Account storage account = accounts[token][to];

        // Transfer tokens from sender to contract
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);

        // Update account balance
        account.funds += amount;

        // settle account lockup now that we have more funds
        settleAccountLockup(account);
    }

    function withdraw(address token, uint256 amount) external nonReentrant {
        withdrawTo(token, msg.sender, amount);
    }

    function withdrawTo(
        address token,
        address to,
        uint256 amount
    ) public nonReentrant {
        require(token != address(0), "token address cannot be zero");
        require(to != address(0), "recipient address cannot be zero");

        Account storage acct = accounts[token][msg.sender];

        (bool funded, uint256 settleEpoch) = settleAccountLockup(acct);
        require(funded && settleEpoch == block.number, "insufficient funds");

        uint256 available = acct.funds > acct.lockupCurrent
            ? acct.funds - acct.lockupCurrent
            : 0;

        require(
            amount <= available,
            "insufficient unlocked funds for withdrawal"
        );
        acct.funds -= amount;
        IERC20(token).safeTransfer(to, amount);
    }

    function createRail(
        address token,
        address from,
        address to,
        address arbiter
    ) external noRailModificationInProgress(_nextRailId) returns (uint256) {
        address operator = msg.sender;
        require(token != address(0), "token address cannot be zero");
        require(from != address(0), "from address cannot be zero");
        require(to != address(0), "to address cannot be zero");

        // Check if operator is approved
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
        rail.isActive = true;
        rail.settledUpTo = block.number;

        clientOperatorRails[from][operator].push(railId);
        return railId;
    }

    function terminateRail(
        uint256 railId
    )
        external
        validateRailActive(railId)
        onlyRailClient(railId)
        noRailModificationInProgress(railId)
    {
        Rail storage rail = rails[railId];

        Account storage payer = accounts[rail.token][rail.from];
        // Settle account lockup and ensure it's fully settled up to the current block
        (bool fullySettled, uint256 settledEpoch) = settleAccountLockup(payer);
        require(
            fullySettled && settledEpoch == block.number,
            "account lockup must be fully settled to terminate rail"
        );

        // If there is no arbiter, settle the rail immediately and ensure it is fully settled upto and including
        // the current epoch
        if (rail.arbiter == address(0)) {
            (, uint256 settledUpto, ) = settleRail(railId, block.number);
            require(
                settledUpto == block.number,
                "rail must be fully settled to terminate"
            );
        } else {
            // For arbitrated rails, push the current rate to the queue
            // This ensures proper settlement when the operator later settles this rail as we're setting the current rail rate to zero in this function
            rail.rateChangeQueue.enqueue(rail.paymentRate, block.number);
        }

        // Update payer's lockup rate and current lockup
        require(
            payer.lockupRate >= rail.paymentRate,
            "payer lockup rate must be at least rail payment rate"
        );
        payer.lockupRate = payer.lockupRate - rail.paymentRate;

        // Set rail payment rate to 0 for future periods and mark the rail as inactive
        rail.paymentRate = 0;
        rail.isActive = false;

        // Ensure account invariants hold
        require(
            payer.lockupCurrent <= payer.funds,
            "payer lockup cannot exceed funds after termination"
        );
    }

    function modifyRailLockup(
        uint256 railId,
        uint256 period,
        uint256 lockupFixed
    )
        external
        validateRailActive(railId)
        onlyRailOperator(railId)
        noRailModificationInProgress(railId)
    {
        Rail storage rail = rails[railId];
        Account storage payer = accounts[rail.token][rail.from];
        OperatorApproval storage approval = operatorApprovals[rail.token][
            rail.from
        ][rail.operator];

        require(approval.isApproved, "operator not approved");

        // settle account lockup and if account lockup is not settled upto to the current epoch; revert
        (bool fullySettled, uint256 lockupSettledUpto) = settleAccountLockup(
            payer
        );
        require(
            fullySettled && lockupSettledUpto == block.number,
            "cannot modify lockup as client does not have enough funds for current account lockup"
        );

        // Calculate the change in base lockup
        uint256 oldLockup = rail.lockupFixed +
            (rail.paymentRate * rail.lockupPeriod);
        uint256 newLockup = lockupFixed + (rail.paymentRate * period);

        // assert that operator allowance is respected
        require(
            newLockup <= oldLockup + approval.lockupAllowance,
            "exceeds operator lockup allowance"
        );
        approval.lockupAllowance =
            approval.lockupAllowance +
            oldLockup -
            newLockup;

        // Update payer's lockup
        require(
            payer.lockupCurrent >= oldLockup,
            "payer's current lockup cannot be less than old lockup"
        );
        payer.lockupCurrent = payer.lockupCurrent - oldLockup + newLockup;

        // Update rail lockup parameters
        rail.lockupPeriod = period;
        rail.lockupFixed = lockupFixed;

        require(
            payer.lockupCurrent <= payer.funds,
            "payer's current lockup cannot be greater than their funds"
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
        noRailModificationInProgress(railId)
    {
        Rail storage rail = rails[railId];
        Account storage payer = accounts[rail.token][rail.from];
        Account storage payee = accounts[rail.token][rail.to];

        OperatorApproval storage approval = operatorApprovals[rail.token][
            rail.from
        ][rail.operator];
        require(approval.isApproved, "Operator not approved");

        uint256 oldRate = rail.paymentRate;

        // Settle the payer's lockup to account for elapsed time
        (bool fullySettled, uint256 lockupSettledUpto) = settleAccountLockup(
            payer
        );

        // If we're increasing the rate, we require full account lockup setlement before we can proceed
        require(
            newRate <= oldRate ||
                (fullySettled && lockupSettledUpto == block.number),
            "account lockup not fully settled; cannot increase rate"
        );

        // We just settled the account lockup. If the client is still not able to guaruantee
        // enough funds to lock up for the rail upto and including the current epoch, it means that the rail is in "debt"
        // i.e. the client does not have enough funds to pay for services already taken on this rail.
        // In this case, we should not allow rate modifications at all.
        // The client should first deposit enough funds to pay for this "debt" and then the rate can be changed.
        require(
            newRate == oldRate ||
                block.number < payer.lockupLastSettledAt + rail.lockupPeriod,
            "rail is in-debt; cannot change rate"
        );

        // --- Operator Approval Checks ---
        validateAndModifyRateChangeApproval(
            rail,
            approval,
            oldRate,
            newRate,
            oneTimePayment
        );

        // --- Settlement Prior to Rate Change ---
        // Only settle and update rate queue if the rate has changed
        if (newRate != oldRate) {
            // If there is no arbiter, settle the rail immediately.
            if (rail.arbiter == address(0)) {
                (, uint256 settledUpto, ) = settleRail(railId, block.number);
                require(
                    settledUpto == block.number,
                    "not able to settle rail upto current epoch"
                );
            } else {
                // handle multiple rate changes by the operator in a single epoch
                // by queueuing the previous rate only once
                if (
                    rail.rateChangeQueue.isEmpty() ||
                    rail.rateChangeQueue.peek().untilEpoch != block.number
                ) {
                    // For arbitrated rails, we need to enqueue the old rate.
                    // This ensures that the old rate is applied up to and including the current block.
                    // The new rate will be applicable starting from the next block.
                    rail.rateChangeQueue.enqueue(oldRate, block.number);
                }
            }
        }

        // Calculate the effective lockup period (remaining period that hasn't been settled)
        require(
            payer.lockupLastSettledAt <= block.number,
            "lockup settlement epoch cannot be in the future"
        );
        uint256 effectiveLockupPeriod = rail.lockupPeriod -
            (block.number - payer.lockupLastSettledAt);

        // Verify current lockup is sufficient for the old rate component
        uint256 oldRateLockupNeeded = (oldRate * effectiveLockupPeriod) +
            oneTimePayment;

        require(
            payer.lockupCurrent >= oldRateLockupNeeded,
            "failed to modify rail payment: insufficient current lockup"
        );
        // Verify one-time payment doesn't exceed fixed lockup
        require(
            rail.lockupFixed >= oneTimePayment,
            "one time payment cannot be greater than rail lockupFixed"
        );

        // Update the rail fixed lockup and payment rate
        rail.lockupFixed = rail.lockupFixed - oneTimePayment;
        rail.paymentRate = newRate;

        // Update payer's lockup rate
        require(
            payer.lockupRate >= oldRate,
            "payer lockup rate cannot be less than old rate"
        );
        payer.lockupRate = payer.lockupRate - oldRate + newRate;

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
            "payer lockup cannot exceed funds"
        );

        // If we've reduced the rate, settle lockup again to account for changes
        // and ensure that account lockup is settled upto and including the current epoch
        if (newRate < oldRate) {
            (bool settled, uint256 settledUpto) = settleAccountLockup(payer);
            require(
                settled && settledUpto == block.number,
                "account lockup must be fully settled after rate decrease"
            );
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

    function validateAndModifyRateChangeApproval(
        Rail storage rail,
        OperatorApproval storage approval,
        uint256 oldRate,
        uint256 newRate,
        uint256 oneTimePayment
    ) internal {
        // Ensure the one-time payment does not exceed the available fixed lockup on the rail.
        require(
            oneTimePayment <= rail.lockupFixed,
            "one-time payment exceeds rail fixed lockup"
        );

        // Calculate the original total lockup amount:
        uint256 oldTotalLockup = (oldRate * rail.lockupPeriod) +
            rail.lockupFixed;
        uint256 newTotalLockup = (newRate * rail.lockupPeriod) +
            rail.lockupFixed;

        require(
            newTotalLockup <= oldTotalLockup + approval.lockupAllowance,
            "exceeds operator lockup allowance"
        );

        approval.lockupAllowance =
            approval.lockupAllowance +
            oldTotalLockup -
            newTotalLockup;

        require(
            newRate <= oldRate + approval.rateAllowance,
            "new rate exceeds operator rate allowance"
        );
        approval.rateAllowance = approval.rateAllowance + oldRate - newRate;
    }

    function settleRail(
        uint256 railId,
        uint256 untilEpoch
    )
        public
        nonReentrant
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

        // Update the payer's lockup to account for elapsed time
        Account storage payer = accounts[rail.token][rail.from];
        settleAccountLockup(payer);

        uint256 maxSettlementEpoch = min(
            untilEpoch,
            payer.lockupLastSettledAt + rail.lockupPeriod
        );

        uint256 startEpoch = rail.settledUpTo;

        // nothing to settle (already settled or zero-duration)
        if (startEpoch >= maxSettlementEpoch) {
            return (0, startEpoch, "already settled upto requested epoch");
        }

        // for zero rate rails with empty queue, just advance the settlement epoch
        // without transferring funds
        uint256 currentRate = rail.paymentRate;
        if (currentRate == 0 && rail.rateChangeQueue.isEmpty()) {
            rail.settledUpTo = maxSettlementEpoch;
            return (0, maxSettlementEpoch, "zero rate payment rail");
        }

        // Process settlement depending on whether rate changes exist
        if (rail.rateChangeQueue.isEmpty()) {
            (uint256 amount, string memory segmentNote) = _settleSegment(
                railId,
                startEpoch,
                maxSettlementEpoch,
                currentRate
            );

            require(rail.settledUpTo > startEpoch, "No progress in settlement");
            return (amount, rail.settledUpTo, segmentNote);
        } else {
            return
                _settleWithRateChanges(
                    railId,
                    currentRate,
                    startEpoch,
                    maxSettlementEpoch
                );
        }
    }

    function _settleWithRateChanges(
        uint256 railId,
        uint256 currentRate,
        uint256 startEpoch,
        uint256 targetEpoch
    )
        internal
        returns (uint256 totalSettled, uint256 finalEpoch, string memory note)
    {
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
                    return (
                        totalSettled,
                        rail.settledUpTo,
                        "Zero rate payment rail"
                    );
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
                    segmentRate
                );

            // If arbiter returned no progress, exit early without updating state
            if (rail.settledUpTo <= processedEpoch) {
                return (totalSettled, rail.settledUpTo, arbitrationNote);
            }

            // Add the settled amount to our running total
            totalSettled += segmentAmount;

            // If arbiter partially settled the segment, exit early
            if (rail.settledUpTo < segmentEndBoundary) {
                return (totalSettled, rail.settledUpTo, arbitrationNote);
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
        return (totalSettled, rail.settledUpTo, note);
    }

    function _settleSegment(
        uint256 railId,
        uint256 epochStart,
        uint256 epochEnd,
        uint256 rate
    ) internal returns (uint256 settledAmount, string memory note) {
        Rail storage rail = rails[railId];
        Account storage payer = accounts[rail.token][rail.from];
        Account storage payee = accounts[rail.token][rail.to];

        // Calculate the default settlement values (without arbitration)
        uint256 duration = epochEnd - epochStart;
        settledAmount = rate * duration;
        uint256 settledUntilEpoch = epochEnd;
        note = "";

        // If this rail has an arbiter, let it decide on the final settlement amount
        if (rail.arbiter != address(0)) {
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
            "failed to settle: insufficient funds to cover lockup after settlement"
        );

        return (settledAmount, note);
    }

    function min(uint256 a, uint256 b) public pure returns (uint256) {
        return a < b ? a : b;
    }

    function settleAccountLockup(
        Account storage account
    ) internal returns (bool fullySettled, uint256 settledUpto) {
        uint256 currentEpoch = block.number;
        uint256 elapsedTime = currentEpoch - account.lockupLastSettledAt;

        if (elapsedTime <= 0) {
            return (true, account.lockupLastSettledAt);
        }

        if (account.lockupRate == 0) {
            account.lockupLastSettledAt = currentEpoch;
            return (true, currentEpoch);
        }

        uint256 additionalLockup = account.lockupRate * elapsedTime;

        if (account.funds >= account.lockupCurrent + additionalLockup) {
            // If sufficient, apply full lockup
            account.lockupCurrent += additionalLockup;
            account.lockupLastSettledAt = currentEpoch;
            return (true, currentEpoch);
        } else {
            // If insufficient, calculate the fractional epoch where funds became insufficient
            uint256 availableFunds = account.funds > account.lockupCurrent
                ? account.funds - account.lockupCurrent
                : 0;

            if (availableFunds == 0) {
                return (false, account.lockupLastSettledAt);
            }

            // Round down to the nearest whole epoch
            uint256 fractionalEpochs = availableFunds / account.lockupRate;
            settledUpto = account.lockupLastSettledAt + fractionalEpochs;

            // Apply lockup up to this point
            account.lockupCurrent += account.lockupRate * fractionalEpochs;
            account.lockupLastSettledAt = settledUpto;
            return (false, settledUpto);
        }
    }
}
