// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "./RateChangeQueue.sol";
import "@openzeppelin/contracts/utils/Strings.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";

interface IValidator {
    struct ValidationResult {
        // The actual payment amount determined by the validator after validation of a rail during settlement
        uint256 modifiedAmount;
        // The epoch up to and including which settlement should occur.
        uint256 settleUpto;
        // A placeholder note for any additional information the validator wants to send to the caller of `settleRail`
        string note;
    }

    function validatePayment(
        uint256 railId,
        uint256 proposedAmount,
        // the epoch up to and including which the rail has already been settled
        uint256 fromEpoch,
        // the epoch up to and including which validation is requested; payment will be validated for (toEpoch - fromEpoch) epochs
        uint256 toEpoch,
        uint256 rate
    ) external returns (ValidationResult memory result);
}

// @title Payments contract.
contract Payments is Initializable, UUPSUpgradeable, OwnableUpgradeable, ReentrancyGuardUpgradeable {
    using SafeERC20 for IERC20;
    using RateChangeQueue for RateChangeQueue.Queue;

    // Maximum commission rate in basis points (100% = 10000 BPS)
    uint256 public constant COMMISSION_MAX_BPS = 10000;

    uint256 public constant NETWORK_FEE = 1300000 gwei; // equivalent to 130000 nFIL

    // Events
    event AccountLockupSettled(
        address indexed token,
        address indexed owner,
        uint256 lockupCurrent,
        uint256 lockupRate,
        uint256 lockupLastSettledAt
    );
    event OperatorApprovalUpdated(
        address indexed token,
        address indexed client,
        address indexed operator,
        bool approved,
        uint256 rateAllowance,
        uint256 lockupAllowance,
        uint256 maxLockupPeriod
    );

    event RailCreated(
        uint256 indexed railId,
        address indexed payer,
        address indexed payee,
        address token,
        address operator,
        address validator,
        address serviceFeeRecipient,
        uint256 commissionRateBps
    );
    event RailLockupModified(
        uint256 indexed railId,
        uint256 oldLockupPeriod,
        uint256 newLockupPeriod,
        uint256 oldLockupFixed,
        uint256 newLockupFixed
    );
    event RailOneTimePaymentProcessed(uint256 indexed railId, uint256 netPayeeAmount, uint256 operatorCommission);
    event RailRateModified(uint256 indexed railId, uint256 oldRate, uint256 newRate);
    event RailSettled(
        uint256 indexed railId,
        uint256 totalSettledAmount,
        uint256 totalNetPayeeAmount,
        uint256 operatorCommission,
        uint256 settledUpTo
    );
    event RailTerminated(uint256 indexed railId, address indexed by, uint256 endEpoch);
    event RailFinalized(uint256 indexed railId);

    event DepositRecorded(
        address indexed token, address indexed from, address indexed to, uint256 amount, bool usedPermit
    );
    event WithdrawRecorded(address indexed token, address indexed from, address indexed to, uint256 amount);

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
        address validator;
        uint256 paymentRate;
        uint256 lockupPeriod;
        uint256 lockupFixed;
        // epoch up to and including which this rail has been settled
        uint256 settledUpTo;
        RateChangeQueue.Queue rateChangeQueue;
        uint256 endEpoch; // Final epoch up to which the rail can be settled (0 if not terminated)
        // Operator commission rate in basis points (e.g., 100 BPS = 1%)
        uint256 commissionRateBps;
        address serviceFeeRecipient; // address to collect operator comission
    }

    struct OperatorApproval {
        bool isApproved;
        uint256 rateAllowance;
        uint256 lockupAllowance;
        uint256 rateUsage; // Track actual usage for rate
        uint256 lockupUsage; // Track actual usage for lockup
        uint256 maxLockupPeriod; // Maximum lockup period the operator can set for rails created on behalf of the client
    }

    // Counter for generating unique rail IDs
    uint256 private _nextRailId = 1;

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
        address validator;
        uint256 paymentRate;
        uint256 lockupPeriod;
        uint256 lockupFixed;
        uint256 settledUpTo;
        uint256 endEpoch;
        // Operator commission rate in basis points (e.g., 100 BPS = 1%)
        uint256 commissionRateBps;
        address serviceFeeRecipient; // address to collect operator commission
    }

    // token => client => operator => Approval
    mapping(address => mapping(address => mapping(address => OperatorApproval))) public operatorApprovals;

    // Define a struct for rails by payee information
    struct RailInfo {
        uint256 railId; // The rail ID
        bool isTerminated; // True if rail is terminated
        uint256 endEpoch; // End epoch for terminated rails (0 for active rails)
    }

    // token => payee => array of railIds
    mapping(address => mapping(address => uint256[])) private payeeRails;

    // token => payer => array of railIds
    mapping(address => mapping(address => uint256[])) private payerRails;

    // Tracks whether a token has ever had fees collected, to prevent duplicates in feeTokens
    mapping(address => bool) public hasCollectedFees;

    struct SettlementState {
        uint256 totalSettledAmount;
        uint256 totalNetPayeeAmount;
        uint256 totalOperatorCommission;
        uint256 processedEpoch;
        string note;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize() public initializer {
        __Ownable_init(msg.sender);
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();
        _nextRailId = 1;
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    modifier validateRailActive(uint256 railId) {
        require(
            rails[railId].from != address(0), "rail does not exist or is beyond it's last settlement after termination"
        );
        _;
    }

    modifier onlyRailClient(uint256 railId) {
        require(rails[railId].from == msg.sender, "only the rail client can perform this action");
        _;
    }

    modifier onlyRailOperator(uint256 railId) {
        require(rails[railId].operator == msg.sender, "only the rail operator can perform this action");
        _;
    }

    modifier onlyRailParticipant(uint256 railId) {
        require(
            rails[railId].from == msg.sender || rails[railId].operator == msg.sender || rails[railId].to == msg.sender,
            "failed to authorize: caller is not a rail participant"
        );
        _;
    }

    modifier validateRailNotTerminated(uint256 railId) {
        require(rails[railId].endEpoch == 0, "rail already terminated");
        _;
    }

    modifier validateRailTerminated(uint256 railId) {
        require(isRailTerminated(rails[railId]), "can only be used on terminated rails");
        _;
    }

    modifier validateNonZeroAddress(address addr, string memory varName) {
        require(addr != address(0), string.concat(varName, " address cannot be zero"));
        _;
    }

    modifier settleAccountLockupBeforeAndAfter(address token, address owner, bool settleFull) {
        Account storage payer = accounts[token][owner];

        // Before function execution
        performSettlementCheck(token, owner, payer, settleFull, true);

        _;

        // After function execution
        performSettlementCheck(token, owner, payer, settleFull, false);
    }

    modifier settleAccountLockupBeforeAndAfterForRail(uint256 railId, bool settleFull, uint256 oneTimePayment) {
        Rail storage rail = rails[railId];
        require(rails[railId].from != address(0), "rail is inactive");

        Account storage payer = accounts[rail.token][rail.from];

        require(rail.lockupFixed >= oneTimePayment, "one time payment cannot be greater than rail lockupFixed");

        // Before function execution
        performSettlementCheck(rail.token, rail.from, payer, settleFull, true);

        // ---- EXECUTE FUNCTION
        _;
        // ---- FUNCTION EXECUTION COMPLETE

        // After function execution
        performSettlementCheck(rail.token, rail.from, payer, settleFull, false);
    }

    function performSettlementCheck(address token, address owner, Account storage payer, bool settleFull, bool isBefore)
        internal
    {
        require(
            payer.funds >= payer.lockupCurrent,
            isBefore
                ? "invariant failure: insufficient funds to cover lockup before function execution"
                : "invariant failure: insufficient funds to cover lockup after function execution"
        );

        settleAccountLockup(token, owner, payer);

        // Verify full settlement if required
        // TODO: give the user feedback on what they need to deposit in their account to complete the operation.
        require(
            !settleFull || isAccountLockupFullySettled(payer),
            isBefore
                ? "payers's account lockup target was not met as a precondition of the requested operation"
                :
                "the requested operation would cause the payer's account lockup target to exceed the funds available in the account"
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
    function getRail(uint256 railId) external view validateRailActive(railId) returns (RailView memory) {
        Rail storage rail = rails[railId];
        return RailView({
            token: rail.token,
            from: rail.from,
            to: rail.to,
            operator: rail.operator,
            validator: rail.validator,
            paymentRate: rail.paymentRate,
            lockupPeriod: rail.lockupPeriod,
            lockupFixed: rail.lockupFixed,
            settledUpTo: rail.settledUpTo,
            endEpoch: rail.endEpoch,
            commissionRateBps: rail.commissionRateBps,
            serviceFeeRecipient: rail.serviceFeeRecipient
        });
    }

    /// @notice Updates the approval status and allowances for an operator on behalf of the message sender.
    /// @param token The ERC20 token address for which the approval is being set.
    /// @param operator The address of the operator whose approval is being modified.
    /// @param approved Whether the operator is approved (true) or not (false) to create new rails.
    /// @param rateAllowance The maximum payment rate the operator can set across all rails created by the operator on behalf of the message sender. If this is less than the current payment rate, the operator will only be able to reduce rates until they fall below the target.
    /// @param lockupAllowance The maximum amount of funds the operator can lock up on behalf of the message sender towards future payments. If this exceeds the current total amount of funds locked towards future payments, the operator will only be able to reduce future lockup.
    /// @param maxLockupPeriod The maximum number of epochs (blocks) the operator can lock funds for. If this is less than the current lockup period for a rail, the operator will only be able to reduce the lockup period.
    function setOperatorApproval(
        address token,
        address operator,
        bool approved,
        uint256 rateAllowance,
        uint256 lockupAllowance,
        uint256 maxLockupPeriod
    ) external nonReentrant validateNonZeroAddress(operator, "operator") {
        _setOperatorApproval(token, operator, approved, rateAllowance, lockupAllowance, maxLockupPeriod);
    }

    function _setOperatorApproval(
        address token,
        address operator,
        bool approved,
        uint256 rateAllowance,
        uint256 lockupAllowance,
        uint256 maxLockupPeriod
    ) internal {
        OperatorApproval storage approval = operatorApprovals[token][msg.sender][operator];

        // Update approval status and allowances
        approval.isApproved = approved;
        approval.rateAllowance = rateAllowance;
        approval.lockupAllowance = lockupAllowance;
        approval.maxLockupPeriod = maxLockupPeriod;

        emit OperatorApprovalUpdated(
            token, msg.sender, operator, approved, rateAllowance, lockupAllowance, maxLockupPeriod
        );
    }

    /// @notice Terminates a payment rail, preventing further payments after the rail's lockup period. After calling this method, the lockup period cannot be changed, and the rail's rate and fixed lockup may only be reduced.
    /// @param railId The ID of the rail to terminate.
    /// @custom:constraint Caller must be a rail client or operator.
    /// @custom:constraint Rail must be active and not already terminated.
    /// @custom:constraint If called by the client, the payer's account must be fully funded.
    /// @custom:constraint If called by the operator, the payer's funding status isn't checked.
    function terminateRail(uint256 railId)
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
            (msg.sender == rail.from && isAccountLockupFullySettled(payer)) || msg.sender == rail.operator,
            "caller is not authorized: must be operator or client with settled lockup"
        );

        rail.endEpoch = payer.lockupLastSettledAt + rail.lockupPeriod;

        emit RailTerminated(railId, msg.sender, rail.endEpoch);

        // Remove the rail rate from account lockup rate but don't set rail rate to zero yet.
        // The rail rate will be used to settle the rail and so we can't zero it yet.
        // However, we remove the rail rate from the client lockup rate because we don't want to
        // lock funds for the rail beyond `rail.endEpoch` as we're exiting the rail
        // after that epoch.
        require(payer.lockupRate >= rail.paymentRate, "lockup rate inconsistency");
        payer.lockupRate -= rail.paymentRate;

        // Reduce operator rate allowance
        OperatorApproval storage operatorApproval = operatorApprovals[rail.token][rail.from][rail.operator];
        updateOperatorRateUsage(operatorApproval, rail.paymentRate, 0);
    }

    /// @notice Deposits tokens from the message sender's account into `to`'s account.
    /// @param token The ERC20 token address to deposit.
    /// @param to The address whose account will be credited.
    /// @param amount The amount of tokens to deposit.
    /// @custom:constraint The message sender must have approved this contract to spend the requested amount via the ERC-20 token (`token`).
    function deposit(address token, address to, uint256 amount)
        external
        payable
        nonReentrant
        validateNonZeroAddress(to, "to")
        settleAccountLockupBeforeAndAfter(token, to, false)
    {
        // Create account if it doesn't exist
        Account storage account = accounts[token][to];

        uint256 actualAmount;
        
        // Transfer tokens from sender to contract
        if (token == address(0)) {
            require(msg.value == amount, "must send an equal amount of native tokens");
            actualAmount = amount; 
        } else {
            require(msg.value == 0, "must not send native tokens");

            // Use balance-before/balance-after accounting for fee-on-transfer tokens
            uint256 balanceBefore = IERC20(token).balanceOf(address(this));
            IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
            uint256 balanceAfter = IERC20(token).balanceOf(address(this));
            
            actualAmount = balanceAfter - balanceBefore;
        }

        account.funds += actualAmount;

        emit DepositRecorded(token, msg.sender, to, actualAmount, false);
    }

    /**
     * @notice Deposits tokens using permit (EIP-2612) approval in a single transaction.
     * @param token The ERC20 token address to deposit.
     * @param to The address whose account will be credited (must be the permit signer).
     * @param amount The amount of tokens to deposit.
     * @param deadline Permit deadline (timestamp).
     * @param v,r,s Permit signature.
     */
    function depositWithPermit(
        address token,
        address to,
        uint256 amount,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external nonReentrant validateNonZeroAddress(to, "to") settleAccountLockupBeforeAndAfter(token, to, false) {
        _depositWithPermit(token, to, amount, deadline, v, r, s);
    }

    function _depositWithPermit(
        address token,
        address to,
        uint256 amount,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) internal {
        // Revert if token is address(0) as permit is not supported for native tokens
        require(token != address(0), "depositWithPermit: native token not supported");

        // Use 'to' as the owner in permit call (the address that signed the permit)
        IERC20Permit(token).permit(to, address(this), amount, deadline, v, r, s);

        Account storage account = accounts[token][to];
        
        // Use balance-before/balance-after accounting for fee-on-transfer tokens
        uint256 balanceBefore = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransferFrom(to, address(this), amount);
        uint256 balanceAfter = IERC20(token).balanceOf(address(this));
        
        uint256 actualAmount = balanceAfter - balanceBefore;
        
        account.funds += actualAmount;

        emit DepositRecorded(token, to, to, actualAmount, true);
    }

    /**
     * @notice Deposits tokens using permit (EIP-2612) approval in a single transaction,
     *         while also setting operator approval.
     * @param token The ERC20 token address to deposit and for which the operator approval is being set.
     *             Note: The token must support EIP-2612 permit functionality.
     * @param to The address whose account will be credited (must be the permit signer).
     * @param amount The amount of tokens to deposit.
     * @param deadline Permit deadline (timestamp).
     * @param v,r,s Permit signature.
     * @param operator The address of the operator whose approval is being modified.
     * @param rateAllowance The maximum payment rate the operator can set across all rails created by the operator
     *             on behalf of the message sender. If this is less than the current payment rate, the operator will
     *             only be able to reduce rates until they fall below the target.
     * @param lockupAllowance The maximum amount of funds the operator can lock up on behalf of the message sender
     *             towards future payments. If this exceeds the current total amount of funds locked towards future payments,
     *             the operator will only be able to reduce future lockup.
     * @param maxLockupPeriod The maximum number of epochs (blocks) the operator can lock funds for. If this is less than
     *             the current lockup period for a rail, the operator will only be able to reduce the lockup period.
     */
    function depositWithPermitAndApproveOperator(
        address token,
        address to,
        uint256 amount,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s,
        address operator,
        uint256 rateAllowance,
        uint256 lockupAllowance,
        uint256 maxLockupPeriod
    )
        external
        nonReentrant
        validateNonZeroAddress(operator, "operator")
        validateNonZeroAddress(to, "to")
        settleAccountLockupBeforeAndAfter(token, to, false)
    {
        _setOperatorApproval(token, operator, true, rateAllowance, lockupAllowance, maxLockupPeriod);
        _depositWithPermit(token, to, amount, deadline, v, r, s);
    }

    /// @notice Withdraws tokens from the caller's account to the caller's account, up to the amount of currently available tokens (the tokens not currently locked in rails).
    /// @param token The ERC20 token address to withdraw.
    /// @param amount The amount of tokens to withdraw.
    function withdraw(address token, uint256 amount)
        external
        nonReentrant
        settleAccountLockupBeforeAndAfter(token, msg.sender, true)
    {
        return withdrawToInternal(token, msg.sender, amount);
    }

    /// @notice Withdraws tokens (`token`) from the caller's account to `to`, up to the amount of currently available tokens (the tokens not currently locked in rails).
    /// @param token The ERC20 token address to withdraw.
    /// @param to The address to receive the withdrawn tokens.
    /// @param amount The amount of tokens to withdraw.
    function withdrawTo(address token, address to, uint256 amount)
        external
        nonReentrant
        validateNonZeroAddress(to, "to")
        settleAccountLockupBeforeAndAfter(token, msg.sender, true)
    {
        return withdrawToInternal(token, to, amount);
    }

    function withdrawToInternal(address token, address to, uint256 amount) internal {
        Account storage account = accounts[token][msg.sender];
        uint256 available = account.funds - account.lockupCurrent;
        require(amount <= available, "insufficient unlocked funds for withdrawal");
        account.funds -= amount;
        if (token == address(0)) {
            (bool success,) = payable(to).call{value: amount}("");
            require(success, "receiving contract rejected funds");
        } else {
            IERC20(token).safeTransfer(to, amount);
        }

        emit WithdrawRecorded(token, msg.sender, to, amount);
    }

    /// @notice Create a new rail from `from` to `to`, operated by the caller.
    /// @param token The ERC20 token address for payments on this rail.
    /// @param from The client address (payer) for this rail.
    /// @param to The recipient address for payments on this rail.
    /// @param validator Optional address of an validator contract (can be address(0) for no validation).
    /// @param commissionRateBps Optional operator commission in basis points (0-10000).
    /// @param serviceFeeRecipient Address to receive operator commission
    /// @return The ID of the newly created rail.
    /// @custom:constraint Caller must be approved as an operator by the client (from address).
    function createRail(
        address token,
        address from,
        address to,
        address validator,
        uint256 commissionRateBps,
        address serviceFeeRecipient
    ) external nonReentrant validateNonZeroAddress(from, "from") validateNonZeroAddress(to, "to") returns (uint256) {
        address operator = msg.sender;

        // Check if operator is approved - approval is required for rail creation
        OperatorApproval storage approval = operatorApprovals[token][from][operator];
        require(approval.isApproved, "operator not approved");

        // Validate commission rate
        require(commissionRateBps <= COMMISSION_MAX_BPS, "commission rate exceeds maximum");

        require(
            commissionRateBps == 0 || serviceFeeRecipient != address(0),
            "non-zero commission requires service fee recipient"
        );

        uint256 railId = _nextRailId++;

        Rail storage rail = rails[railId];
        rail.token = token;
        rail.from = from;
        rail.to = to;
        rail.operator = operator;
        rail.validator = validator;
        rail.settledUpTo = block.number;
        rail.endEpoch = 0;
        rail.commissionRateBps = commissionRateBps;
        rail.serviceFeeRecipient = serviceFeeRecipient;

        // Record this rail in the payee's and payer's lists
        payeeRails[token][to].push(railId);
        payerRails[token][from].push(railId);

        emit RailCreated(railId, from, to, token, operator, validator, serviceFeeRecipient, commissionRateBps);

        return railId;
    }

    /// @notice Modifies the fixed lockup and lockup period of a rail.
    /// - If the rail has already been terminated, the lockup period may not be altered and the fixed lockup may only be reduced.
    /// - If the rail is active, the lockup may only be modified if the payer's account is fully funded and will remain fully funded after the operation.
    /// @param railId The ID of the rail to modify.
    /// @param period The new lockup period (in epochs/blocks).
    /// @param lockupFixed The new fixed lockup amount.
    /// @custom:constraint Caller must be the rail operator.
    /// @custom:constraint Operator must have sufficient lockup allowance to cover any increases the lockup period or the fixed lockup.
    function modifyRailLockup(uint256 railId, uint256 period, uint256 lockupFixed)
        external
        validateRailActive(railId)
        onlyRailOperator(railId)
        nonReentrant
        settleAccountLockupBeforeAndAfterForRail(railId, false, 0)
    {
        Rail storage rail = rails[railId];
        bool isTerminated = isRailTerminated(rail);

        uint256 oldLockupPeriod = rail.lockupPeriod;
        uint256 oldLockupFixed = rail.lockupFixed;

        if (isTerminated) {
            modifyTerminatedRailLockup(rail, period, lockupFixed);
        } else {
            modifyNonTerminatedRailLockup(rail, period, lockupFixed);
        }

        emit RailLockupModified(railId, oldLockupPeriod, period, oldLockupFixed, lockupFixed);
    }

    function modifyTerminatedRailLockup(Rail storage rail, uint256 period, uint256 lockupFixed) internal {
        require(
            period == rail.lockupPeriod && lockupFixed <= rail.lockupFixed,
            "failed to modify terminated rail: cannot change period or increase fixed lockup"
        );

        Account storage payer = accounts[rail.token][rail.from];

        // Calculate the fixed lockup reduction - this is the only change allowed for terminated rails
        uint256 lockupReduction = rail.lockupFixed - lockupFixed;

        // Update payer's lockup - subtract the exact reduction amount
        require(payer.lockupCurrent >= lockupReduction, "payer's current lockup cannot be less than lockup reduction");
        payer.lockupCurrent -= lockupReduction;

        // Reduce operator rate allowance
        OperatorApproval storage operatorApproval = operatorApprovals[rail.token][rail.from][rail.operator];
        updateOperatorLockupUsage(operatorApproval, rail.lockupFixed, lockupFixed);

        rail.lockupFixed = lockupFixed;
    }

    function modifyNonTerminatedRailLockup(Rail storage rail, uint256 period, uint256 lockupFixed) internal {
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

        // Get operator approval
        OperatorApproval storage operatorApproval = operatorApprovals[rail.token][rail.from][rail.operator];

        // Check if period exceeds the max lockup period allowed for this operator
        // Only enforce this constraint when increasing the period, not when decreasing
        if (period > rail.lockupPeriod) {
            require(
                period <= operatorApproval.maxLockupPeriod,
                "requested lockup period exceeds operator's maximum allowed lockup period"
            );
        }

        // Calculate current (old) lockup.
        uint256 oldLockup = rail.lockupFixed + (rail.paymentRate * rail.lockupPeriod);

        // Calculate new lockup amount with new parameters
        uint256 newLockup = lockupFixed + (rail.paymentRate * period);

        require(payer.lockupCurrent >= oldLockup, "payer's current lockup cannot be less than old lockup");

        // We blindly update the payer's lockup. If they don't have enough funds to cover the new
        // amount, we'll revert in the post-condition.
        payer.lockupCurrent = payer.lockupCurrent - oldLockup + newLockup;

        updateOperatorLockupUsage(operatorApproval, oldLockup, newLockup);

        // Update rail lockup parameters
        rail.lockupPeriod = period;
        rail.lockupFixed = lockupFixed;
    }

    /// @notice Modifies the payment rate and optionally makes a one-time payment.
    /// - If the rail has already been terminated, one-time payments can be made and the rate may always be decreased (but never increased) regardless of the status of the payer's account.
    /// - If the payer's account isn't fully funded and the rail is active (not terminated), the rail's payment rate may not be changed at all (increased or decreased).
    /// - Regardless of the payer's account status, one-time payments will always go through provided that the rail has sufficient fixed lockup to cover the payment.
    /// @param railId The ID of the rail to modify.
    /// @param newRate The new payment rate (per epoch). This new rate applies starting the next epoch after the current one.
    /// @param oneTimePayment Optional one-time payment amount to transfer immediately, taken out of the rail's fixed lockup.
    /// @custom:constraint Caller must be the rail operator.
    /// @custom:constraint Operator must have sufficient rate and lockup allowances for any increases.
    function modifyRailPayment(uint256 railId, uint256 newRate, uint256 oneTimePayment)
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
                revert("cannot modify terminated rail beyond it's end epoch");
            }

            require(newRate <= oldRate, "failed to modify rail: cannot change rate on terminated rail");
        } else {
            require(
                isAccountLockupFullySettled(payer) || newRate == oldRate,
                "account lockup not fully settled; cannot change rate"
            );
        }

        // enqueuing rate change
        enqueueRateChange(rail, oldRate, newRate);

        // Calculate the effective lockup period
        uint256 effectiveLockupPeriod;
        if (isTerminated) {
            effectiveLockupPeriod = remainingEpochsForTerminatedRail(rail);
        } else {
            effectiveLockupPeriod =
                isAccountLockupFullySettled(payer) ? rail.lockupPeriod - (block.number - payer.lockupLastSettledAt) : 0;
        }

        // Verify one-time payment doesn't exceed fixed lockup
        require(rail.lockupFixed >= oneTimePayment, "one time payment cannot be greater than rail lockupFixed");

        // Update the rail fixed lockup and payment rate
        rail.lockupFixed = rail.lockupFixed - oneTimePayment;
        rail.paymentRate = newRate;

        OperatorApproval storage operatorApproval = operatorApprovals[rail.token][rail.from][rail.operator];

        // Update payer's lockup rate - only if the rail is not terminated
        // for terminated rails, the payer's lockup rate is already updated during rail termination
        if (!isTerminated) {
            require(payer.lockupRate >= oldRate, "payer lockup rate cannot be less than old rate");
            payer.lockupRate = payer.lockupRate - oldRate + newRate;
            updateOperatorRateUsage(operatorApproval, oldRate, newRate);
        }

        // Update payer's current lockup with effective lockup period calculation
        // Remove old rate lockup for the effective period, add new rate lockup for the same period
        payer.lockupCurrent =
            payer.lockupCurrent - (oldRate * effectiveLockupPeriod) + (newRate * effectiveLockupPeriod) - oneTimePayment;

        updateOperatorLockupUsage(operatorApproval, oldRate * effectiveLockupPeriod, newRate * effectiveLockupPeriod);

        // Update operator allowance for one-time payment
        updateOperatorAllowanceForOneTimePayment(operatorApproval, oneTimePayment);

        emit RailRateModified(railId, oldRate, newRate);

        // --- Process the One-Time Payment ---
        processOneTimePayment(railId, payer, payee, rail, oneTimePayment);
    }

    function enqueueRateChange(Rail storage rail, uint256 oldRate, uint256 newRate) internal {
        // If rate hasn't changed or rail is already settled up to current block, nothing to do
        if (newRate == oldRate || rail.settledUpTo == block.number) {
            return;
        }

        // Skip putting a 0-rate entry on an empty queue
        if (oldRate == 0 && rail.rateChangeQueue.isEmpty()) {
            rail.settledUpTo = block.number;
            return;
        }

        // Only queue the previous rate once per epoch
        if (rail.rateChangeQueue.isEmpty() || rail.rateChangeQueue.peekTail().untilEpoch != block.number) {
            // For validated rails, we need to enqueue the old rate.
            // This ensures that the old rate is applied up to and including the current block.
            // The new rate will be applicable starting from the next block.
            rail.rateChangeQueue.enqueue(oldRate, block.number);
        }
    }

    function calculateAndPayFees(uint256 amount, address token, address serviceFeeRecipient, uint256 commissionRateBps)
        internal
        returns (uint256 netPayeeAmount, uint256 operatorCommission)
    {
        // Calculate operator commission (if any) based on remaining amount
        operatorCommission = 0;
        if (commissionRateBps > 0) {
            operatorCommission = (amount * commissionRateBps) / COMMISSION_MAX_BPS;
        }

        // Calculate net amount for payee
        netPayeeAmount = amount - operatorCommission;

        // Credit operator (if commission exists)
        if (operatorCommission > 0) {
            Account storage serviceFeeRecipientAccount = accounts[token][serviceFeeRecipient];
            serviceFeeRecipientAccount.funds += operatorCommission;
        }

        return (netPayeeAmount, operatorCommission);
    }

    function processOneTimePayment(
        uint256 railId,
        Account storage payer,
        Account storage payee,
        Rail storage rail,
        uint256 oneTimePayment
    ) internal {
        if (oneTimePayment > 0) {
            require(payer.funds >= oneTimePayment, "insufficient funds for one-time payment");

            // Transfer funds from payer (full amount)
            payer.funds -= oneTimePayment;

            // Calculate fees, pay operator commission and track platform fees
            (uint256 netPayeeAmount, uint256 operatorCommission) =
                calculateAndPayFees(oneTimePayment, rail.token, rail.serviceFeeRecipient, rail.commissionRateBps);

            // Credit payee (net amount after fees)
            payee.funds += netPayeeAmount;

            emit RailOneTimePaymentProcessed(railId, netPayeeAmount, operatorCommission);
        }
    }

    /// @notice Settles payments for a terminated rail without validation. This may only be called by the payee and after the terminated rail's max settlement epoch has passed. It's an escape-hatch to unblock payments in an otherwise stuck rail (e.g., due to a buggy validator contract) and it always pays in full.
    /// @param railId The ID of the rail to settle.
    /// @return totalSettledAmount The total amount settled and transferred.
    /// @return totalNetPayeeAmount The net amount credited to the payee after fees.
    /// @return totalOperatorCommission The commission credited to the operator.
    /// @return finalSettledEpoch The epoch up to which settlement was actually completed.
    /// @return note Additional information about the settlement.
    function settleTerminatedRailWithoutValidation(uint256 railId)
        external
        nonReentrant
        validateRailActive(railId)
        validateRailTerminated(railId)
        onlyRailClient(railId)
        settleAccountLockupBeforeAndAfterForRail(railId, false, 0)
        returns (
            uint256 totalSettledAmount,
            uint256 totalNetPayeeAmount,
            uint256 totalOperatorCommission,
            uint256 finalSettledEpoch,
            string memory note
        )
    {
        // Verify the current epoch is greater than the max settlement epoch
        uint256 maxSettleEpoch = maxSettlementEpochForTerminatedRail(rails[railId]);
        require(
            block.number > maxSettleEpoch,
            "terminated rail can only be settled without validation after max settlement epoch"
        );

        return settleRailInternal(railId, maxSettleEpoch, true);
    }

    function burnAndRefundRest(uint256 _amount) internal {
        require(msg.value >= _amount, "insufficient transfer of native token to burn");
        // f099 burn address
        (bool success,) = address(0xff00000000000000000000000000000000000063).call{value: _amount}("");
        require(success, "native token burn failed");

        if (msg.value > _amount) {
            (success,) = msg.sender.call{value: msg.value - _amount}("");
            require(success, "refund failed");
        }
    }

    /// @notice Settles payments for a rail up to the specified epoch. Settlement may fail to reach the target epoch if either the client lacks the funds to pay up to the current epoch or the validator refuses to settle the entire requested range.
    /// @notice In the call to this function, the caller must include NETWORK_FEE amount of native token as a fee.
    /// @param railId The ID of the rail to settle.
    /// @param untilEpoch The epoch up to which to settle (must not exceed current block number).
    /// @return totalSettledAmount The total amount settled and transferred.
    /// @return totalNetPayeeAmount The net amount credited to the payee after fees.
    /// @return totalOperatorCommission The commission credited to the operator.
    /// @return finalSettledEpoch The epoch up to which settlement was actually completed.
    /// @return note Additional information about the settlement (especially from validation).
    function settleRail(uint256 railId, uint256 untilEpoch)
        public
        payable
        nonReentrant
        validateRailActive(railId)
        onlyRailParticipant(railId)
        settleAccountLockupBeforeAndAfterForRail(railId, false, 0)
        returns (
            uint256 totalSettledAmount,
            uint256 totalNetPayeeAmount,
            uint256 totalOperatorCommission,
            uint256 finalSettledEpoch,
            string memory note
        )
    {
        if (NETWORK_FEE > 0) {
            burnAndRefundRest(NETWORK_FEE);
        }
        return settleRailInternal(railId, untilEpoch, false);
    }

    function settleRailInternal(uint256 railId, uint256 untilEpoch, bool skipValidation)
        internal
        returns (
            uint256 totalSettledAmount,
            uint256 totalNetPayeeAmount,
            uint256 totalOperatorCommission,
            uint256 finalSettledEpoch,
            string memory note
        )
    {
        require(untilEpoch <= block.number, "failed to settle: cannot settle future epochs");

        Rail storage rail = rails[railId];
        Account storage payer = accounts[rail.token][rail.from];

        // Handle terminated and fully settled rails that are still not finalised
        if (isRailTerminated(rail) && rail.settledUpTo >= rail.endEpoch) {
            finalizeTerminatedRail(railId, rail, payer);
            return (0, 0, 0, rail.settledUpTo, "rail fully settled and finalized");
        }

        // Calculate the maximum settlement epoch based on account lockup
        uint256 maxSettlementEpoch;
        if (!isRailTerminated(rail)) {
            maxSettlementEpoch = min(untilEpoch, payer.lockupLastSettledAt);
        } else {
            maxSettlementEpoch = min(untilEpoch, rail.endEpoch);
        }

        uint256 startEpoch = rail.settledUpTo;
        // Nothing to settle (already settled or zero-duration)
        if (startEpoch >= maxSettlementEpoch) {
            return (
                0, 0, 0, startEpoch, string.concat("already settled up to epoch ", Strings.toString(maxSettlementEpoch))
            );
        }

        // Declare variables for settlement results
        uint256 amount;
        uint256 netPayeeAmount;
        uint256 operatorCommission;
        string memory segmentNote;

        // Process settlement depending on whether rate changes exist
        if (rail.rateChangeQueue.isEmpty()) {
            (amount, netPayeeAmount, operatorCommission, segmentNote) =
                _settleSegment(railId, startEpoch, maxSettlementEpoch, rail.paymentRate, skipValidation);

            require(rail.settledUpTo > startEpoch, "No progress in settlement");
        } else {
            (amount, netPayeeAmount, operatorCommission, segmentNote) =
                _settleWithRateChanges(railId, rail.paymentRate, startEpoch, maxSettlementEpoch, skipValidation);
        }
        (totalSettledAmount, totalNetPayeeAmount, totalOperatorCommission, finalSettledEpoch, note) =
        checkAndFinalizeTerminatedRail(
            railId,
            rail,
            payer,
            amount,
            netPayeeAmount,
            operatorCommission,
            rail.settledUpTo,
            segmentNote,
            string.concat(segmentNote, "terminated rail fully settled and finalized.")
        );

        emit RailSettled(railId, totalSettledAmount, totalNetPayeeAmount, totalOperatorCommission, finalSettledEpoch);

        return (totalSettledAmount, totalNetPayeeAmount, totalOperatorCommission, finalSettledEpoch, note);
    }

    function checkAndFinalizeTerminatedRail(
        uint256 railId,
        Rail storage rail,
        Account storage payer,
        uint256 totalSettledAmount,
        uint256 totalNetPayeeAmount,
        uint256 totalOperatorCommission,
        uint256 finalEpoch,
        string memory regularNote,
        string memory finalizedNote
    ) internal returns (uint256, uint256, uint256, uint256, string memory) {
        // Check if rail is a terminated rail that's now fully settled
        if (isRailTerminated(rail) && rail.settledUpTo >= maxSettlementEpochForTerminatedRail(rail)) {
            finalizeTerminatedRail(railId, rail, payer);
            return (totalSettledAmount, totalNetPayeeAmount, totalOperatorCommission, finalEpoch, finalizedNote);
        }

        return (totalSettledAmount, totalNetPayeeAmount, totalOperatorCommission, finalEpoch, regularNote);
    }

    function finalizeTerminatedRail(uint256 railId, Rail storage rail, Account storage payer) internal {
        // Reduce the lockup by the fixed amount
        require(payer.lockupCurrent >= rail.lockupFixed, "lockup inconsistency during rail finalization");
        payer.lockupCurrent -= rail.lockupFixed;

        // Get operator approval for finalization update
        OperatorApproval storage operatorApproval = operatorApprovals[rail.token][rail.from][rail.operator];
        // Calculate current (old) lockup.
        uint256 oldLockup = rail.lockupFixed + (rail.paymentRate * rail.lockupPeriod);

        updateOperatorLockupUsage(operatorApproval, oldLockup, 0);

        // Zero out the rail to mark it as inactive
        _zeroOutRail(rail);

        emit RailFinalized(railId);
    }

    function _settleWithRateChanges(
        uint256 railId,
        uint256 currentRate,
        uint256 startEpoch,
        uint256 targetEpoch,
        bool skipValidation
    )
        internal
        returns (
            uint256 totalSettledAmount,
            uint256 totalNetPayeeAmount,
            uint256 totalOperatorCommission,
            string memory note
        )
    {
        Rail storage rail = rails[railId];
        RateChangeQueue.Queue storage rateQueue = rail.rateChangeQueue;

        SettlementState memory state = SettlementState({
            totalSettledAmount: 0,
            totalNetPayeeAmount: 0,
            totalOperatorCommission: 0,
            processedEpoch: startEpoch,
            note: ""
        });

        // Process each segment until we reach the target epoch or hit an early exit condition
        while (state.processedEpoch < targetEpoch) {
            (uint256 segmentEndBoundary, uint256 segmentRate) =
                _getNextSegmentBoundary(rateQueue, currentRate, state.processedEpoch, targetEpoch);

            // if current segment rate is zero, advance settlement to end of this segment and continue
            if (segmentRate == 0) {
                rail.settledUpTo = segmentEndBoundary;
                state.processedEpoch = segmentEndBoundary;

                // Remove the processed rate change from the queue if it exists
                if (!rateQueue.isEmpty()) {
                    rateQueue.dequeue();
                }

                // Continue to next segment
                continue;
            }

            // Settle the current segment with potentially validated outcomes
            (
                uint256 segmentSettledAmount,
                uint256 segmentNetPayeeAmount,
                uint256 segmentOperatorCommission,
                string memory validationNote
            ) = _settleSegment(railId, state.processedEpoch, segmentEndBoundary, segmentRate, skipValidation);

            // If validator returned no progress, exit early without updating state
            if (rail.settledUpTo <= state.processedEpoch) {
                return
                    (state.totalSettledAmount, state.totalNetPayeeAmount, state.totalOperatorCommission, validationNote);
            }

            // Add the settled amounts to our running totals
            state.totalSettledAmount += segmentSettledAmount;
            state.totalNetPayeeAmount += segmentNetPayeeAmount;
            state.totalOperatorCommission += segmentOperatorCommission;

            // If validator partially settled the segment, exit early
            if (rail.settledUpTo < segmentEndBoundary) {
                return
                    (state.totalSettledAmount, state.totalNetPayeeAmount, state.totalOperatorCommission, validationNote);
            }

            // Successfully settled full segment, update tracking values
            state.processedEpoch = rail.settledUpTo;
            state.note = validationNote;

            // Remove the processed rate change from the queue
            if (!rateQueue.isEmpty()) {
                rateQueue.dequeue();
            }
        }

        // We've successfully settled up to the target epoch
        return (state.totalSettledAmount, state.totalNetPayeeAmount, state.totalOperatorCommission, state.note);
    }

    function _getNextSegmentBoundary(
        RateChangeQueue.Queue storage rateQueue,
        uint256 currentRate,
        uint256 processedEpoch,
        uint256 targetEpoch
    ) internal view returns (uint256 segmentEndBoundary, uint256 segmentRate) {
        // Default boundary is the target we want to reach
        segmentEndBoundary = targetEpoch;
        segmentRate = currentRate;

        // If we have rate changes in the queue, use the rate from the next change
        if (!rateQueue.isEmpty()) {
            RateChangeQueue.RateChange memory nextRateChange = rateQueue.peek();

            // Validate rate change queue consistency
            require(nextRateChange.untilEpoch >= processedEpoch, "rate queue is in an invalid state");

            // Boundary is the minimum of our target or the next rate change epoch
            segmentEndBoundary = min(targetEpoch, nextRateChange.untilEpoch);
            segmentRate = nextRateChange.rate;
        }
    }

    function _settleSegment(uint256 railId, uint256 epochStart, uint256 epochEnd, uint256 rate, bool skipValidation)
        internal
        returns (uint256 totalSettledAmount, uint256 netPayeeAmount, uint256 operatorCommission, string memory note)
    {
        Rail storage rail = rails[railId];
        Account storage payer = accounts[rail.token][rail.from];
        Account storage payee = accounts[rail.token][rail.to];

        if (rate == 0) {
            rail.settledUpTo = epochEnd;
            return (0, 0, 0, "Zero rate payment rail");
        }

        // Calculate the default settlement values (without validation)
        uint256 duration = epochEnd - epochStart;
        uint256 settledAmount = rate * duration;
        uint256 settledUntilEpoch = epochEnd;
        note = "";

        // If this rail has an validator and we're not skipping validation, let it decide on the final settlement amount
        if (rail.validator != address(0) && !skipValidation) {
            IValidator validator = IValidator(rail.validator);
            IValidator.ValidationResult memory result =
                validator.validatePayment(railId, settledAmount, epochStart, epochEnd, rate);

            // Ensure validator doesn't settle beyond our segment's end boundary
            require(result.settleUpto <= epochEnd, "validator settled beyond segment end");
            require(result.settleUpto >= epochStart, "validator settled before segment start");

            settledUntilEpoch = result.settleUpto;
            settledAmount = result.modifiedAmount;
            note = result.note;

            // Ensure validator doesn't allow more payment than the maximum possible
            // for the epochs they're confirming
            uint256 maxAllowedAmount = rate * (settledUntilEpoch - epochStart);
            require(
                result.modifiedAmount <= maxAllowedAmount,
                "validator modified amount exceeds maximum for settled duration"
            );
        }

        // Verify payer has sufficient funds for the settlement
        require(payer.funds >= settledAmount, "failed to settle: insufficient funds to cover settlement");

        // Verify payer has sufficient lockup for the settlement
        require(payer.lockupCurrent >= settledAmount, "failed to settle: insufficient lockup to cover settlement");
        uint256 actualSettledDuration = settledUntilEpoch - epochStart;
        uint256 requiredLockup = rate * actualSettledDuration;

        // Transfer funds from payer (always pays full settled amount)
        payer.funds -= settledAmount;

        // Calculate fees, pay operator commission and track platform fees
        (netPayeeAmount, operatorCommission) =
            calculateAndPayFees(settledAmount, rail.token, rail.serviceFeeRecipient, rail.commissionRateBps);

        // Credit payee
        payee.funds += netPayeeAmount;

        // Reduce lockup based on actual settled duration, not requested duration
        // so that if the validator only settles for a partial duration, we only reduce the client lockup by the actual locked amount
        // for that reduced duration.
        payer.lockupCurrent -= requiredLockup;

        // Update the rail's settled epoch
        rail.settledUpTo = settledUntilEpoch;

        // Invariant check: lockup should never exceed funds
        require(
            payer.lockupCurrent <= payer.funds,
            "failed to settle: invariant violation: insufficient funds to cover lockup after settlement"
        );

        return (settledAmount, netPayeeAmount, operatorCommission, note);
    }

    function isAccountLockupFullySettled(Account storage account) internal view returns (bool) {
        return account.lockupLastSettledAt == block.number;
    }

    // attempts to settle account lockup up to and including the current epoch
    // returns the actual epoch upto and including which the lockup was settled
    function settleAccountLockup(address token, address owner, Account storage account) internal returns (uint256) {
        uint256 currentEpoch = block.number;
        uint256 elapsedTime = currentEpoch - account.lockupLastSettledAt;

        if (elapsedTime <= 0) {
            return account.lockupLastSettledAt;
        }

        if (account.lockupRate == 0) {
            account.lockupLastSettledAt = currentEpoch;

            // Emit event for zero rate case
            emit AccountLockupSettled(
                token, owner, account.lockupCurrent, account.lockupRate, account.lockupLastSettledAt
            );
            return currentEpoch;
        }

        uint256 additionalLockup = account.lockupRate * elapsedTime;

        // we have sufficient funds to cover account lockup upto and including the current epoch
        if (account.funds >= account.lockupCurrent + additionalLockup) {
            account.lockupCurrent += additionalLockup;
            account.lockupLastSettledAt = currentEpoch;
        } else {
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
            account.lockupLastSettledAt = account.lockupLastSettledAt + fractionalEpochs;
        }

        // event emission for all other cases where state changed
        emit AccountLockupSettled(token, owner, account.lockupCurrent, account.lockupRate, account.lockupLastSettledAt);
        return account.lockupLastSettledAt;
    }

    function remainingEpochsForTerminatedRail(Rail storage rail) internal view returns (uint256) {
        require(isRailTerminated(rail), "rail is not terminated");

        // If current block beyond end epoch, return 0
        if (block.number > rail.endEpoch) {
            return 0;
        }

        // Return the number of epochs (blocks) remaining until end epoch
        return rail.endEpoch - block.number;
    }

    function isRailTerminated(Rail storage rail) internal view returns (bool) {
        require(rail.from != address(0), "failed to check: rail does not exist");
        return rail.endEpoch > 0;
    }

    // Get the final settlement epoch for a terminated rail
    function maxSettlementEpochForTerminatedRail(Rail storage rail) internal view returns (uint256) {
        require(isRailTerminated(rail), "rail is not terminated");
        return rail.endEpoch;
    }

    function _zeroOutRail(Rail storage rail) internal {
        // Check if queue is empty before clearing
        require(rail.rateChangeQueue.isEmpty(), "rate change queue must be empty post full settlement");

        rail.token = address(0);
        rail.from = address(0); // This now marks the rail as inactive
        rail.to = address(0);
        rail.operator = address(0);
        rail.validator = address(0);
        rail.paymentRate = 0;
        rail.lockupFixed = 0;
        rail.lockupPeriod = 0;
        rail.settledUpTo = 0;
        rail.endEpoch = 0;
        rail.commissionRateBps = 0;
    }

    function updateOperatorRateUsage(OperatorApproval storage approval, uint256 oldRate, uint256 newRate) internal {
        if (newRate > oldRate) {
            uint256 rateIncrease = newRate - oldRate;
            require(
                approval.rateUsage + rateIncrease <= approval.rateAllowance, "operation exceeds operator rate allowance"
            );
            approval.rateUsage += rateIncrease;
        } else if (oldRate > newRate) {
            uint256 rateDecrease = oldRate - newRate;
            approval.rateUsage = approval.rateUsage > rateDecrease ? approval.rateUsage - rateDecrease : 0;
        }
    }

    function updateOperatorLockupUsage(OperatorApproval storage approval, uint256 oldLockup, uint256 newLockup)
        internal
    {
        if (newLockup > oldLockup) {
            uint256 lockupIncrease = newLockup - oldLockup;
            require(
                approval.lockupUsage + lockupIncrease <= approval.lockupAllowance,
                "operation exceeds operator lockup allowance"
            );
            approval.lockupUsage += lockupIncrease;
        } else if (oldLockup > newLockup) {
            uint256 lockupDecrease = oldLockup - newLockup;
            approval.lockupUsage = approval.lockupUsage > lockupDecrease ? approval.lockupUsage - lockupDecrease : 0;
        }
    }

    function updateOperatorAllowanceForOneTimePayment(OperatorApproval storage approval, uint256 oneTimePayment)
        internal
    {
        if (oneTimePayment == 0) return;

        // Reduce lockup usage
        approval.lockupUsage = approval.lockupUsage - oneTimePayment;

        // Reduce lockup allowance
        approval.lockupAllowance =
            oneTimePayment > approval.lockupAllowance ? 0 : approval.lockupAllowance - oneTimePayment;
    }

    /**
     * @notice Gets all rails where the given address is the payer for a specific token.
     * @param payer The address of the payer to get rails for.
     * @param token The token address to filter rails by.
     * @return Array of RailInfo structs containing rail IDs and termination status.
     */
    function getRailsForPayerAndToken(address payer, address token) external view returns (RailInfo[] memory) {
        return _getRailsForAddressAndToken(payer, token, true);
    }

    /**
     * @notice Gets all rails where the given address is the payee for a specific token.
     * @param payee The address of the payee to get rails for.
     * @param token The token address to filter rails by.
     * @return Array of RailInfo structs containing rail IDs and termination status.
     */
    function getRailsForPayeeAndToken(address payee, address token) external view returns (RailInfo[] memory) {
        return _getRailsForAddressAndToken(payee, token, false);
    }

    /**
     * @dev Internal function to get rails for either a payer or payee.
     * @param addr The address to get rails for (either payer or payee).
     * @param token The token address to filter rails by.
     * @param isPayer If true, search for rails where addr is the payer, otherwise search for rails where addr is the payee.
     * @return Array of RailInfo structs containing rail IDs and termination status.
     */
    function _getRailsForAddressAndToken(address addr, address token, bool isPayer)
        internal
        view
        returns (RailInfo[] memory)
    {
        // Get the appropriate list of rails based on whether we're looking for payer or payee
        uint256[] storage allRailIds = isPayer ? payerRails[token][addr] : payeeRails[token][addr];
        uint256 railsLength = allRailIds.length;

        RailInfo[] memory tempResults = new RailInfo[](railsLength);
        uint256 resultCount = 0;

        for (uint256 i = 0; i < railsLength; i++) {
            uint256 railId = allRailIds[i];
            Rail storage rail = rails[railId];

            // Skip non-existent rails
            if (rail.from == address(0)) continue;

            // Add rail to our temporary array
            tempResults[resultCount] =
                RailInfo({railId: railId, isTerminated: rail.endEpoch > 0, endEpoch: rail.endEpoch});
            resultCount++;
        }

        // Create correctly sized final result array
        RailInfo[] memory result = new RailInfo[](resultCount);

        // Only copy if we have results (avoid unnecessary operations)
        if (resultCount > 0) {
            for (uint256 i = 0; i < resultCount; i++) {
                result[i] = tempResults[i];
            }
        }

        return result;
    }

    /// @notice Number of pending rate-change entries for a rail
    function getRateChangeQueueSize(uint256 railId) external view returns (uint256) {
        return rails[railId].rateChangeQueue.size();
    }

    /**
     * @notice Gets information about an account - when it would go into debt, total balance, available balance, and lockup rate.
     * @param token The token address to get account info for.
     * @param owner The address of the account owner.
     * @return fundedUntilEpoch The epoch at which the account would go into debt given current lockup rate and balance.
     * @return currentFunds The current funds in the account.
     * @return availableFunds The funds available after accounting for simulated lockup.
     * @return currentLockupRate The current lockup rate per epoch.
     */
    function getAccountInfoIfSettled(address token, address owner)
        external
        view
        returns (uint256 fundedUntilEpoch, uint256 currentFunds, uint256 availableFunds, uint256 currentLockupRate)
    {
        Account storage account = accounts[token][owner];

        currentFunds = account.funds;
        currentLockupRate = account.lockupRate;

        uint256 currentEpoch = block.number;

        fundedUntilEpoch = account.lockupRate == 0
            ? type(uint256).max
            : account.lockupLastSettledAt + (account.funds - account.lockupCurrent) / account.lockupRate;
        uint256 simulatedSettledAt = fundedUntilEpoch >= currentEpoch ? currentEpoch : fundedUntilEpoch;
        uint256 simulatedLockupCurrent =
            account.lockupCurrent + account.lockupRate * (simulatedSettledAt - account.lockupLastSettledAt);
        availableFunds = account.funds - simulatedLockupCurrent;

        return (fundedUntilEpoch, currentFunds, availableFunds, currentLockupRate);
    }
}

function min(uint256 a, uint256 b) pure returns (uint256) {
    return a < b ? a : b;
}
