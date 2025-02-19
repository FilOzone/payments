// SPDX-License-Identifier: UNLICENSED
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
        bool approved;
        uint256 modifiedAmount;
        uint256 settleUpto;
        string note;
    }

    function arbitratePayment(
        uint256 railId,
        uint256 proposedAmount,
        uint256 fromEpoch,
        uint256 toEpoch
    ) external returns (ArbitrationResult memory result);
}

contract Payments is Initializable, UUPSUpgradeable, OwnableUpgradeable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using RateChangeQueue for RateChangeQueue.Queue;

    struct Account {
        address ownerAddress;
        uint256 funds;
        uint256 lockupCurrent;
        uint256 lockupRate;
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
        uint256 settledUpTo;
    }

    struct OperatorApproval {
        bool isApproved;
        address arbitrer;
        uint256 rateAllowance;
        uint256 lockupAllowance;
    }

    // railId => RateChangeQueue
    mapping(uint256 => RateChangeQueue.Queue) public railRateChangeQueues;

    // Counter for generating unique rail IDs
    uint256 private _nextRailId;

    // token => owner => Account
    mapping(address => mapping(address => Account)) public accounts;

    // railId => Rail
    mapping(uint256 => Rail) public rails;

    // token => client => operator => Approval
    mapping(address => mapping(address => mapping(address => OperatorApproval))) public operatorApprovals;

    // client => operator => railIds
    mapping(address => mapping(address => uint256[])) public clientOperatorRails;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize() public initializer {
        __Ownable_init(msg.sender);
        __UUPSUpgradeable_init();
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    modifier validateRailActive(uint256 railId) {
        require(rails[railId].from != address(0), "rail does not exist");
        require(rails[railId].isActive, "rail is inactive");
        _;
    }

    modifier validateRailAccountsExist(uint256 railId) {
        Rail storage rail = rails[railId];
        require(rail.from != address(0), "rail does not exist");
        require(accounts[rail.token][rail.from].ownerAddress != address(0), "from account does not exist");
        require(accounts[rail.token][rail.to].ownerAddress != address(0), "to account does not exist");
        _;
    }

    modifier onlyRailOperator(uint256 railId) {
        require(rails[railId].operator == msg.sender, "only the rail operator can perform this action");
        _;
    }

    modifier onlyAccountOwner(address token) {
        address owner = accounts[token][msg.sender].ownerAddress;
        require(owner != address(0), "account does not exist");
        require(owner == msg.sender, "not account owner");
        _;
    }

    function approveOperator(
        address token,
        address operator,
        address arbiter,
        uint256 rateAllowance,
        uint256 lockupAllowance
    ) external onlyAccountOwner(token) {
        require(token != address(0), "token address cannot be zero");
        require(operator != address(0), "operator address cannot be zero");

        OperatorApproval storage approval = operatorApprovals[token][msg.sender][operator];
        approval.arbitrer = arbiter;
        approval.rateAllowance = rateAllowance;
        approval.lockupAllowance = lockupAllowance;
        approval.isApproved = true;
    }

    // TODO: Revisit
    function terminateOperator(address operator) external  {
        require(operator != address(0), "operator address invalid");

        uint256[] memory railIds = clientOperatorRails[msg.sender][operator];
        for (uint256 i = 0; i < railIds.length; i++) {
            Rail storage rail = rails[railIds[i]];
            require(rail.from == msg.sender, "Not rail payer");
            if (!rail.isActive) {
                continue;
            }

            settleRail(railIds[i], block.number);

            Account storage account = accounts[rail.token][msg.sender];
            account.lockupCurrent -= rail.lockupFixed + (rail.paymentRate * rail.lockupPeriod);
            account.lockupRate -= rail.paymentRate;

            rail.paymentRate = 0;
            rail.lockupFixed = 0;
            rail.lockupPeriod = 0;
            rail.isActive = false;

            OperatorApproval storage approval = operatorApprovals[rail.token][msg.sender][operator];
            approval.rateAllowance = 0;
            approval.lockupAllowance = 0;
            approval.isApproved = false;
        }
    }

    // TODO: implement
    function terminateRail() public {

    }

    function deposit(address token, address to, uint256 amount) external {
        require(token != address(0), "token address cannot be zero");
        require(to != address(0), "to address cannot be zero");
        require(amount > 0, "amount must be greater than 0");

        // Create account if it doesn't exist
        Account storage account = accounts[token][to];
        if (account.ownerAddress == address(0)) {
            account.ownerAddress = to;
        }

        // Transfer tokens from sender to contract
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);

        // Update account balance
        account.funds += amount;

        // settle account lockup now that we have more funds
        settleAccountLockup(account);
    }

    function withdraw(address token, uint256 amount) external onlyAccountOwner(token) nonReentrant {
        Account storage acct = accounts[token][msg.sender];

        (bool funded, uint256 settleEpoch) = settleAccountLockup(acct);
        require(funded && settleEpoch == block.number, "insufficient funds");

        uint256 available = acct.funds > acct.lockupCurrent
            ? acct.funds - acct.lockupCurrent
            : 0;

        require(amount <= available, "insufficient unlocked funds for withdrawal");
        acct.funds -= amount;
        IERC20(token).safeTransfer(msg.sender, amount);
    }

    function createRail(
        address token,
        address from,
        address to,
        address operator,
        address arbiter
    ) external returns (uint256) {
        require(token != address(0), "token address cannot be zero");
        require(from != address(0), "from address cannot be zero");
        require(to != address(0), "to address cannot be zero");
        require(operator != address(0), "operator address cannot be zero");

        OperatorApproval memory approval = operatorApprovals[token][from][operator];
        require(approval.isApproved, "operator not approved");

        Account storage toAccount = accounts[token][to];
        require(toAccount.ownerAddress != address(0), "to account does not exist");
        require(toAccount.funds > 0, "to account has no funds");

        Account storage fromAccount = accounts[token][from];
        require(fromAccount.ownerAddress != address(0), "from account does not exist");
        require(fromAccount.funds > 0, "from account has no funds");

        if (approval.arbitrer != address(0)) {
            require(arbiter == approval.arbitrer, "arbiter mismatch");
        }

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

    function modifyRailLockup(
        uint256 railId,
        uint256 period,
        uint256 lockupFixed
    ) external validateRailActive(railId) validateRailAccountsExist(railId) onlyRailOperator(railId) {
        Rail storage rail = rails[railId];

        Account storage payer = accounts[rail.token][rail.from];

        OperatorApproval storage approval = operatorApprovals[rail.token][rail.from][rail.operator];
        require(approval.isApproved, "operator not approved");

        // settle account lockup and if account lockup is not settled upto to the current epoch; revert
        (bool fullySettled, uint256 lockupSettledUpto) = settleAccountLockup(payer);
        require(fullySettled && lockupSettledUpto == block.number, "cannot modify lockup as client does not have enough funds for current account lockup");

        // Calculate the change in base lockup
        uint256 oldLockup = rail.lockupFixed + (rail.paymentRate * rail.lockupPeriod);
        uint256 newLockup = lockupFixed + (rail.paymentRate * period);

        // assert that operator allowance is respected
        require(newLockup <= oldLockup + approval.lockupAllowance, "exceeds operator lockup allowance");
        approval.lockupAllowance = approval.lockupAllowance + oldLockup - newLockup;

        // Update payer's lockup
        require(payer.lockupCurrent >= oldLockup, "payer's current lockup cannot be less than old lockup");
        payer.lockupCurrent = payer.lockupCurrent - oldLockup + newLockup;

        // Update rail lockup parameters
        rail.lockupPeriod = period;
        rail.lockupFixed = lockupFixed;

        require(payer.lockupCurrent <= payer.funds, "payer's current lockup cannot be greater than their funds");
    }

    function modifyRailPayment(
        uint256 railId,
        uint256 newRate,
        uint256 oneTimePayment
    ) external validateRailActive(railId) validateRailAccountsExist(railId) onlyRailOperator(railId) {
        Rail storage rail = rails[railId];
        Account storage payer = accounts[rail.token][rail.from];
        Account storage payee = accounts[rail.token][rail.to];

        OperatorApproval storage approval = operatorApprovals[rail.token][rail.from][rail.operator];
        require(approval.isApproved, "Operator not approved");

        // Settle the payer's lockup.
        // If we're changing the rate, we require full settlement.
        (bool fullySettled, uint256 lockupSettledUpto) = settleAccountLockup(payer);
        if (newRate != rail.paymentRate) {
            require(fullySettled && lockupSettledUpto == block.number, "account lockup not fully settled; cannot change rate");
        }

        uint256 oldRate = rail.paymentRate;
        // --- Operator Approval Checks ---
        validateAndModifyRateChangeApproval(rail, approval, oldRate, newRate, oneTimePayment);

        // --- Settlement Prior to Rate Change ---
        // If there is no arbiter, settle the rail immediately.
        if (rail.arbiter == address(0)) {
            (, uint256 settledUpto, ) = settleRail(railId, block.number);
            require(settledUpto == block.number, "not able to settle rail upto current epoch");
        } else {
            railRateChangeQueues[railId].enqueue(rail.paymentRate, block.number);
        }

        require(rail.lockupFixed >= oneTimePayment, "one time payment cannot be greater than rail lockupFixed");
        rail.lockupFixed = rail.lockupFixed - oneTimePayment;
        rail.paymentRate = newRate;

        require(payer.lockupRate >= oldRate, "payer lockup rate cannot be less than old rate");
        payer.lockupRate = payer.lockupRate - oldRate + newRate;

        require(payer.lockupCurrent >= ((oldRate * rail.lockupPeriod) + oneTimePayment), "failed to modify rail payment: insufficient current lockup");
        payer.lockupCurrent = payer.lockupCurrent - (oldRate * rail.lockupPeriod) + (newRate * rail.lockupPeriod) - oneTimePayment;        

        // --- Process the One-Time Payment ---
        processOneTimePayment(payer, payee, oneTimePayment);

        require(payer.lockupCurrent <= payer.funds, "payer lockup cannot exceed funds");
    }

    function processOneTimePayment(
        Account storage payer,
        Account storage payee,
        uint256 oneTimePayment
    ) internal {
        if (oneTimePayment > 0) {
            require(payer.funds >= oneTimePayment, "insufficient funds for one-time payment");
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
        uint256 oldTotalLockup = (oldRate * rail.lockupPeriod) + rail.lockupFixed;
        uint256 newTotalLockup = (newRate * rail.lockupPeriod) + rail.lockupFixed;

        require(
            newTotalLockup <= oldTotalLockup + approval.lockupAllowance,
            "exceeds operator lockup allowance"
        );

        approval.lockupAllowance = approval.lockupAllowance + oldTotalLockup - newTotalLockup;

        require(newRate <= oldRate + approval.rateAllowance, "new rate exceeds operator rate allowance");
        approval.rateAllowance = approval.rateAllowance + oldRate - newRate;
        
    }

    function updateRailArbiter(uint256 railId, address newArbiter) external validateRailActive(railId) onlyRailOperator(railId) {
        Rail storage rail = rails[railId];
        OperatorApproval storage approval = operatorApprovals[rail.token][rail.from][rail.operator];
        require(approval.isApproved, "operator not approved");
        if (approval.arbitrer != address(0)) {
            require(newArbiter == approval.arbitrer, "arbiter mismatch");
        }
        // Update the arbiter
        rail.arbiter = newArbiter;
    }

    function settleRail(uint256 railId, uint256 untilEpoch) public validateRailActive(railId) validateRailAccountsExist(railId)    
    returns (
        uint256 totalSettledAmount,
        uint256 finalSettledEpoch,
        string memory note
    ) {
        require(untilEpoch <= block.number, "failed to settle: cannot settle future epochs");

        Rail storage paymentRail = rails[railId];
        Account storage payer = accounts[paymentRail.token][paymentRail.from];
        Account storage payee = accounts[paymentRail.token][paymentRail.to];

        settleAccountLockup(payer);

        // Determine the maximum allowed epoch we can settle to based on the payer's lockupPeriod.
        uint256 maxSettlementEpoch = min(untilEpoch, payer.lockupLastSettledAt + paymentRail.lockupPeriod);

        // Begin from the last epoch that was actually settled.
        uint256 lastSettledEpoch = paymentRail.settledUpTo;
        uint256 currentPaymentRate = paymentRail.paymentRate;

        // Retrieve any queued rate changes for this rail.
        RateChangeQueue.Queue storage rateQueue = railRateChangeQueues[railId];

        // If no rate changes are queued, settle the entire segment from lastSettledEpoch to maxSettlementEpoch.
        if (rateQueue.isEmpty()) {
            (totalSettledAmount, finalSettledEpoch, note) = _settleSegment(
                railId,
                paymentRail,
                lastSettledEpoch,
                maxSettlementEpoch,
                currentPaymentRate
            );
        } else {
            // Otherwise, handle each segment up to the next rate–change boundary.
            (totalSettledAmount, finalSettledEpoch, note) = _settleWithRateChanges(
                railId,
                paymentRail,
                rateQueue,
                currentPaymentRate,
                lastSettledEpoch,
                maxSettlementEpoch
            );
        }

        // Check and reduce the payer's funds and lockup after we know how much is settled.
        require(payer.lockupCurrent >= totalSettledAmount, "failed to settle: insufficient lockup funds");
        payer.funds -= totalSettledAmount;
        payee.funds += totalSettledAmount;
        payer.lockupCurrent -= totalSettledAmount;

        // Update the final settled epoch on the rail record.
        paymentRail.settledUpTo = finalSettledEpoch;

        // Sanity check: the lockup should never exceed total funds.
        require(payer.lockupCurrent <= payer.funds, "failed to settle: insufficient funds");

        return (totalSettledAmount, finalSettledEpoch, note);
    }

    /**
     * @notice Settles a payment segment for the specified epoch range at the given rate.
     *         If an arbiter is set, an external arbitration call is made to potentially
     *         modify the final settlement amount or end epoch.
     * @param railId The identifier of the rail being settled.
     * @param rail A storage reference to the rail.
     * @param epochStart The starting epoch of this settlement segment.
     * @param epochEnd The ending epoch of this settlement segment.
     * @param rate The rate for this settlement segment.
     * @return settledAmount The final amount to settle for this segment.
     * @return settledUntil The final epoch that effectively got settled.
     * @return note An optional note returned by the arbitrator.
     */
    function _settleSegment(
        uint256 railId,
        Rail storage rail,
        uint256 epochStart,
        uint256 epochEnd,
        uint256 rate
    ) 
        internal 
        returns (
            uint256 settledAmount, 
            uint256 settledUntil, 
            string memory note
        ) 
    {
        // Calculate the intended settlement amount for the time span.
        uint256 duration = epochEnd - epochStart;
        settledAmount = rate * duration;
        settledUntil = epochEnd;

        // If the rail has an assigned arbiter, call it for arbitration on this segment.
        if (rail.arbiter != address(0)) {
            IArbiter arbiter = IArbiter(rail.arbiter);
            IArbiter.ArbitrationResult memory arbResult = arbiter.arbitratePayment(
                railId,
                settledAmount,
                epochStart,
                epochEnd
            );

            require(arbResult.approved, "failed to settle: arbiter refused payment");
            require(
                arbResult.settleUpto <= epochEnd,
                "failed to settle: arbiter settled beyond segment end"
            );
            require(
                arbResult.modifiedAmount <= rate * (arbResult.settleUpto - epochStart),
                "failed to settle: arbiter modified amount exceeds maximum for settled duration"
            );

            // Adjust the amount and the final epoch according to the arbiter's decision.
            settledUntil = arbResult.settleUpto;
            settledAmount = arbResult.modifiedAmount;
            note = arbResult.note;
        }

        // Revert if no progress was made (i.e., the final epoch did not advance).
        require(settledUntil > epochStart, "failed to settle: no progress made in settlement");

        return (settledAmount, settledUntil, note);
    }

    function _settleWithRateChanges(
        uint256 railId,
        Rail storage rail,
        RateChangeQueue.Queue storage rateQueue,
        uint256 initialRate,
        uint256 startEpoch,
        uint256 targetEpoch
    ) internal returns (uint256 totalSettled, uint256 finalEpoch, string memory note) {
        totalSettled = 0;
        uint256 currentEpoch = startEpoch;
        uint256 activeRate = initialRate;
        note = "";

        while (currentEpoch <= targetEpoch) {
            uint256 nextBoundary = targetEpoch;

            // If there's an upcoming rate change, check if it applies within our current range.
            if (!rateQueue.isEmpty()) {
                RateChangeQueue.RateChange memory upcomingChange = rateQueue.peek();
                bool isWithinRange = (
                    upcomingChange.untilEpoch >= currentEpoch &&
                    upcomingChange.untilEpoch <= targetEpoch
                );
                require(isWithinRange, "rate queue is in an invalid state");
                nextBoundary = upcomingChange.untilEpoch;
                activeRate = upcomingChange.rate;
            }

            // Settle the segment from the current epoch up to the next boundary (or early if arbitration says so).
            (uint256 segmentAmount, uint256 segmentEndEpoch, string memory arbNote) = _settleSegment(
                railId,
                rail,
                currentEpoch,
                nextBoundary,
                activeRate
            );

            // Update the total settled. 
            totalSettled += segmentAmount;

            // If the arbitration shortened the segment, stop and return immediately.
            // but keep the rate change in the queue as we've not fully settled the segment.
            if (segmentEndEpoch < nextBoundary) {
                return (totalSettled, segmentEndEpoch, arbNote);
            }

            // Otherwise, we have fully settled up to nextBoundary.
            currentEpoch = segmentEndEpoch;
            note = arbNote;

            // Dequeue the rate change we just passed (if it was indeed used this round).
            if (!rateQueue.isEmpty()) {
                // Peek again to confirm it's the one we used.
                RateChangeQueue.RateChange memory frontChange = rateQueue.peek();
                if (frontChange.untilEpoch == nextBoundary) {
                    rateQueue.dequeue();
                }
            }
        }

        // If we reach here, we've settled up to our target epoch.
        finalEpoch = currentEpoch;
        return (totalSettled, finalEpoch, note);
    }

    function min(uint256 a, uint256 b) public pure returns (uint256) {
        return a < b ? a : b;
    }

    function settleAccountLockup(Account storage account) internal returns (bool fullySettled, uint256 settledUpto) {
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
            uint256 availableFunds = account.funds > account.lockupCurrent ? account.funds - account.lockupCurrent : 0;

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