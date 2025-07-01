# FWS Payments Contract

The FWS Payments contract enables ERC20 token payment flows through "rails" - automated payment channels between clients and recipients. The contract supports continuous payments, one-time transfers, and payment validation/arbitration.

- [Deployment Info](#deployment-info)
- [Key Concepts](#key-concepts)
- [Core Functions](#core-functions)
  - [Account Management](#account-management)
  - [Operator Management](#operator-management)
  - [Rail Management](#rail-management)
  - [Settlement](#settlement)
  - [Validation](#validation)
- [Worked Example](#worked-example)
- [Emergency Scenarios](#emergency-scenarios)

## Deployment Info
- On calibration net at `0x0E690D3e60B0576D01352AB03b258115eb84A047`
- Coming soon to mainnet...

## Key Concepts

- **Account**: Represents a user's token balance and locked funds
- **Rail**: A payment channel between a client and recipient with configurable terms
- **Validator**: An optional contract that validates and, if necessary, mediates payment disputes
- **Operator**: An authorized third party who can manage rails on behalf of clients

### Account

Tracks the funds, lockup, obligations, etc. associated with a single “owner” (where the owner is a smart contract or a wallet). Accounts can be both *clients* and *SPs* but we’ll often talk about them as if they were separate types.

- **Client —** An account that *pays* an SP (also referred to as the *payer*)
- **SP** — An account managed by a service provider to receive payment from a client (also referred to as the *payee*).

### Rail

A rail along which payments flow from a client to an SP. Rails track lockup, maximum payment rates, and obligations between a client and an SP. Client-SP pairs can have multiple payment rails between them but they can also reuse the same rail across multiple deals. Importantly, rails:
    - Specify the maximum rate at which the client will pay the SP, the actual amount paid for any given period is subject to validation by the **validator** described below.
    - Specify the period in advanced the client is required to lock funds (the **lockup period**). There’s no way to force clients to lock funds in advanced, but we can prevent them from *withdrawing* them and make it easy for SPs to tell if their clients haven’t met their lockup minimums, giving them time to settle their accounts.

### **Validator**

An validator is an (optional) smart contract that can validate/arbitrate payments associated with a single rail. For example, a payment rail used for PDP will specify the PDP service as its validator. A validator can:

- Prevent settlement of a payment rail entirely.
- Refuse to settle a payment rail past some epoch.
- Reduce the amount paid out by a rail for a period of time (e.g., to account for actual services rendered, penalties, etc.).

### Operator

An operator is a smart contract (likely the service contract) that manages rails on behalf of clients & SPs, with approval from the client (the client approves the operator to spend its funds at a specific rate). The operator smart contract must be trusted by both the client and the SP as it can arbitrarily alter payments (within the allowance specified by the client). It:

- Creates rails from clients to service providers.
- Changes payment rates, lockups, etc. of payment rails created by this operator.
    - The sum of payment rates across all rails operated by this contract for a specific client must be at most the maximum per-operator spend rate specified by the client.
    - The sum of the lockup across all rails operated by this contract for a specific client must be at most the maximum per-operator lockup specified by the client.
- Specify/change the payment rail validator of payment rails created by this operator.

## Core Functions

### Account Management

#### `deposit(address token, address to, uint256 amount)`

Deposits tokens into a specified account.

- **Parameters**:
  - `token`: ERC20 token contract address
  - `to`: Recipient account address
  - `amount`: Token amount to deposit
- **Requirements**:
  - Caller must have approved the contract to transfer tokens

#### `depositWithPermit(address token, address to, uint256 amount, uint256 deadline, uint8 v, bytes32 r, bytes32 s)`

Deposits tokens using EIP-2612 permit.

- **Parameters**:
  - `token`: ERC20 token contract address supporting EIP-2612 permits
  - `to`: Recipient account address (must be the signer of the permit)
  - `amount`: Token amount to deposit
  - `deadline`: Permit expiration timestamp
  - `v`, `r`, `s`: Signature components for EIP-2612 permit signature

- **Requirements**:
  - Token must support EIP-2612 permit
  - Caller must have signed the permit
  - Permit must be valid and not expired

#### `depositWithPermitAndApproveOperator(address token, address to, uint256 amount, uint256 deadline, uint8 v, bytes32 r, bytes32 s, address operator, uint256 rateAllowance, uint256 lockupAllowance, uint256 maxLockupPeriod)`

Deposits tokens using EIP-2612 permit and sets operator approval in a single transaction.

- **Parameters**:
  - `token`: ERC20 token contract address supporting EIP-2612 permits
  - `to`: Recipient account address (must be the signer of the permit)
  - `amount`: Token amount to deposit
  - `deadline`: Permit expiration timestamp
  - `v`, `r`, `s`: Signature components for EIP-2612 permit signature
  - `operator`: Address to grant permissions to
  - `rateAllowance`: Maximum payment rate the operator can set across all rails
  - `lockupAllowance`: Maximum funds the operator can lock for future payments
  - `maxLockupPeriod`: Maximum allowed lockup period in epochs

#### `withdraw(address token, uint256 amount)`

Withdraws available tokens from caller's account to caller's wallet.

- **Parameters**:
  - `token`: ERC20 token contract address
  - `amount`: Token amount to withdraw
- **Requirements**:
  - Amount must not exceed unlocked funds

#### `withdrawTo(address token, address to, uint256 amount)`

Withdraws available tokens from caller's account to a specified address.

- **Parameters**:
  - `token`: ERC20 token contract address
  - `to`: Recipient address
  - `amount`: Token amount to withdraw
- **Requirements**:
  - Amount must not exceed unlocked funds

### Operator Management

#### `setOperatorApproval(address token, address operator, bool approved, uint256 rateAllowance, uint256 lockupAllowance, uint256 maxLockupPeriod)`

Configures an operator's permissions to manage rails on behalf of the caller.

- **Parameters**:
  - `token`: ERC20 token contract address
  - `operator`: Address to grant permissions to
  - `approved`: Whether the operator is approved
  - `rateAllowance`: Maximum payment rate the operator can set across all rails
  - `lockupAllowance`: Maximum funds the operator can lock for future payments
  - `maxLockupPeriod`: Maximum allowed lockup period in epochs

### Rail Management

#### `createRail(address token, address from, address to, address validator)`

Creates a new payment rail between two parties.

- **Parameters**:
  - `token`: ERC20 token contract address
  - `from`: Client (payer) address
  - `to`: Recipient address
  - `validator`: Optional validation contract address (0x0 for none)
- **Returns**: Unique rail ID
- **Requirements**:
  - Caller must be approved as an operator by the client

#### `getRail(uint256 railId)`

Retrieves the current state of a payment rail.
- **Parameters**:
  - `railId`: Rail identifier
- **Returns**: RailView struct with rail details
- **Requirements**:
  - Rail must exist

#### `terminateRail(uint256 railId)`

Emergency termination of a payment rail, preventing new payments after the lockup period. This should only be used in exceptional cases where the operator contract is malfunctioning and refusing to cancel deals.

- **Parameters**:
  - `railId`: Rail identifier
- **Requirements**:
  - Caller must be the rail's client and must have a fully funded account, or it must be the rail operator
  - Rail must not be already terminated

#### `modifyRailLockup(uint256 railId, uint256 period, uint256 lockupFixed)`

Changes a rail's lockup parameters.

- **Parameters**:
  - `railId`: Rail identifier
  - `period`: New lockup period in epochs
  - `lockupFixed`: New fixed lockup amount
- **Requirements**:
  - Caller must be the rail operator
  - For terminated rails: cannot change period or increase fixed lockup
  - For active rails: changes restricted if client's account isn't fully funded
  - Operator must have sufficient allowances

#### `modifyRailPayment(uint256 railId, uint256 newRate, uint256 oneTimePayment)`

Modifies a rail's payment rate and/or makes a one-time payment.

- **Parameters**:
  - `railId`: Rail identifier
  - `newRate`: New per-epoch payment rate
  - `oneTimePayment`: Optional immediate payment amount
- **Requirements**:
  - Caller must be the rail operator
  - For terminated rails: cannot increase rate
  - For active rails: rate changes restricted if client's account isn't fully funded
  - One-time payment must not exceed fixed lockup

#### `getRailsForPayerAndToken(address payer, address token)`

Retrieves all rails where the given address is the payer for a specific token.
- **Parameters**:
  - `payer`: Payer address
  - `token`: ERC20 token contract address
- **Returns**: Array of `RailInfo` structs containing rail IDs and termination status.
- **Requirements**: None (returns an array, empty if no matching rails).

#### `getRailsForPayeeAndToken(address payee, address token)`

Retrieves all rails where the given address is the payee for a specific token.
- **Parameters**:
  - `payee`: Payee address
  - `token`: ERC20 token contract address
- **Returns**: Array of `RailInfo` structs containing rail IDs and termination status.
- **Requirements**: None (returns an array, empty if no matching rails).

### One-Time Payments

One-time payments enable operators to transfer fixed amounts immediately from payer to payee, bypassing the regular rate-based payment flow. These payments are deducted from the rail's fixed lockup amount.

#### Key Characteristics

- **Operator-Initiated**: Only the rail operator can execute one-time payments through `modifyRailPayment`
- **Fixed Lockup Source**: Payments are drawn from `rail.lockupFixed`, which must be pre-allocated via `modifyRailLockup`
- **Always Available**: Once locked, these funds remain available regardless of the payer's account balance
- **Operator Approval**: Counts against the operator's `lockupAllowance` and reduces `lockupUsage` when spent
- **Commission Applied**: One-time payments are subject to the rail's operator commission rate, just like regular payments

#### Usage

One-time payments require a two-step process:

1. **Lock funds** using `modifyRailLockup` to allocate fixed lockup:

```solidity
// Allocate 10 tokens for one-time payments
Payments.modifyRailLockup(
    railId,       // Rail ID
    lockupPeriod, // Lockup period (unchanged or new value)
    10 * 10**18   // Fixed lockup amount
);
```

This will revert if:
- The client lacks sufficient unlocked funds to cover the requested lockup
- The operator exceeds their `lockupAllowance` or `maxLockupPeriod` limits

2. **Make payments** using `modifyRailPayment` with a non-zero `oneTimePayment`:

```solidity
// Make a 5 token one-time payment from the locked funds
Payments.modifyRailPayment(
    railId,      // Rail ID
    newRate,     // Payment rate (can remain unchanged)
    5 * 10**18   // One-time payment amount (must be ≤ rail.lockupFixed)
);
```

#### Lifecycle

1. **Allocation**: Fixed lockup is set when creating/modifying a rail via `modifyRailLockup`
2. **Usage**: Operator makes one-time payments, reducing the available fixed lockup
3. **Termination**: Unused fixed lockup remains available for one-time payments even after rail termination
4. **Finalization**: After full rail settlement, any remaining fixed lockup is automatically refunded to the client

#### Example Use Cases

- Onboarding fees or setup costs
- Performance bonuses or penalties
- Urgent payments outside regular settlement cycles
- Termination fees when canceling services

### Operator One-Time Payment Window

**Lifecycle:**  
  1. **Rail Active:**  
     While the rail is active, the operator can make one-time payments at any time, provided there is sufficient fixed lockup remaining.
  2. **Rail Termination:**  
     When a rail is terminated (either by the client or operator), the payment stream stops, but the fixed lockup is not immediately released. Instead, the lockup period acts as a grace period, allowing the operator to continue making one-time payments for a limited time after termination.  
     **The end of this window is calculated as the last epoch up to which the payer's account lockup was settled (`lockupLastSettledAt`) plus the rail's lockup period.** If the account was only settled up to an earlier epoch, the window will close sooner than if it was fully up to date at the time of termination.
  3. **End of Window:**  
     Once the current epoch surpasses `(rail termination epoch + rail lockup period)`, the one-time payment window closes. At this point, any unused fixed lockup is automatically refunded to the client, and no further one-time payments can be made.

**Example Timeline:**  
  - Rail is created at epoch 100, with a lockup period of 20 epochs.
  - At epoch 150, the operator calls `terminateRail`, but the payer's lockup is only settled up to epoch 120.
  - The rail's termination epoch is set to 120 (the last settled lockup epoch).
  - The operator can make one-time payments from the fixed lockup until epoch 140 (`120 + 20`).
  - After epoch 140, any remaining fixed lockup is refunded to the client.

**Note:**  
  - The one-time payment window after termination is **not** always the epoch at which `terminateRail` is called plus the lockup period. It depends on how far the payer's account lockup has been settled at the time of termination. If the account is not fully settled, the window will be shorter.

### Handling Reductions to maxLockupPeriod

A client can reduce the operator's `maxLockupPeriod` or `lockupAllowance` after a deal proposal, which may prevent the operator from setting a meaningful lockup period and thus block one-time payments.

**Edge Case Explanation:**
  - If the client reduces the operator's `maxLockupPeriod` or `lockupAllowance` after a deal is proposed but before the operator has set the lockup, the operator may be unable to allocate enough fixed lockup for one-time payments. This can hamper the operator's ability to secure payment for work performed, especially if the lockup period is set to a very low value or zero.
  - This risk exists because the operator's ability to set or increase the lockup is always subject to the current allowances set by the client. If the client reduces these allowances before the operator calls `modifyRailLockup`, the transaction will fail, and the operator cannot secure the funds.

**Best Practice:**
  - Before performing any work or incurring costs, the operator should always call `modifyRailLockup` to allocate the required fixed lockup. Only if this call is successful should the operator proceed with the work. This guarantees that the fixed lockup amount is secured for one-time payments, regardless of any future reductions to operator allowances by the client.

**Practical Scenario:**
  1. Operator and client agree on a deal, and the operator intends to lock 10 tokens for one-time payments.
  2. Before the operator calls `modifyRailLockup`, the client reduces the operator's `maxLockupPeriod` to 0 or lowers the `lockupAllowance` below 10 tokens.
  3. The operator's attempt to set the lockup fails, and they cannot secure the funds for one-time payments.
  4. If the operator had called `modifyRailLockup` and succeeded before the client reduced the allowance, the lockup would be secured, and the operator could draw one-time payments as needed, even if the client later reduces the allowance.

**Summary:**
  - Always secure the fixed lockup before starting work. This is the only way to guarantee access to one-time payments, regardless of changes to operator allowances by the client.

### Settlement

#### `settleRail(uint256 railId, uint256 untilEpoch)`

Settles payments for a rail up to a specified epoch.

- **Parameters**:
  - `railId`: Rail identifier
  - `untilEpoch`: Target epoch (must not exceed current epoch)
- **Returns**:
  - `totalSettledAmount`: Amount transferred
  - `finalSettledEpoch`: Epoch to which settlement was completed
  - `note`: Additional settlement information
- **Requirements**:
  - Client must have sufficient funds to cover the payment
  - Client's account must be fully funded _or_ the rail must be terminated
  - Cannot settle future epochs

#### `settleTerminatedRailWithoutValidation(uint256 railId)`

Emergency settlement method for terminated rails with stuck validation.

- **Parameters**:
  - `railId`: Rail identifier
- **Returns**:
  - `totalSettledAmount`: Amount transferred
  - `finalSettledEpoch`: Epoch to which settlement was completed
  - `note`: Additional settlement information
- **Requirements**:
  - Caller must be rail client
  - Rail must be terminated
  - Current epoch must be past the rail's maximum settlement epoch

### Validation

The contract supports optional payment validation through the `IValidator` interface. When a rail has a validator:

1. During settlement, the validator contract is called
2. The validator can adjust payment amounts or partially settle epochs
3. This provides dispute resolution capabilities for complex payment arrangements

## Worked Example

This worked example demonstrates how users interact with the FWS Payments contract through a typical service deal lifecycle.

### 1. Initial Funding

A client first deposits tokens to fund their account in the payments contract:

```solidity
// 1. Client approves the Payments contract to spend tokens
IERC20(tokenAddress).approve(paymentsContractAddress, 100 * 10**18); // 100 tokens

// A client or anyone else can deposit to the client's account
Payments(paymentsContractAddress).deposit(
    tokenAddress,   // ERC20 token address
    clientAddress,  // Recipient's address (the client)
    100 * 10**18    // Amount to deposit (100 tokens)
);
```

After this operation, the client's `Account.funds` is credited with 100 tokens, enabling them to use services within the FWS ecosystem.

This operation _may_ be deferred until the funds are actually required, funding is always "on-demand".

### 2. Operator Approval

Before using a service, the client must approve the service's contract as an operator:

```solidity
// Client approves a service contract as an operator
Payments(paymentsContractAddress).setOperatorApproval(
    tokenAddress,           // ERC20 token address
    serviceContractAddress, // Operator address (service contract)
    true,                   // Approval status
    5 * 10**18,             // Maximum rate (tokens per epoch) the operator can allocate
    20 * 10**18             // Maximum lockup the operator can set
);
```

This approval has two key components:

- The `rateAllowance` (5 tokens/epoch) limits the total continuous payment rate across all rails created by this operator
- The `lockupAllowance` (20 tokens) limits the total fixed amount the operator can lock up for one-time payments or escrow

### 3. Deal Proposal (Rail Creation)

When a client proposes a deal with a service provider, the service contract (acting as an operator) creates a payment rail:

```solidity
// Service contract creates a rail
uint256 railId = Payments(paymentsContractAddress).createRail(
    tokenAddress,     // Token used for payments
    clientAddress,    // Payer (client)
    serviceProvider,  // Payee (service provider)
    validatorAddress    // Optional validator (can be address(0) for no validation/arbitration)
);

// Set up initial lockup for onboarding costs - for example, 10 tokens as fixed lockup
Payments(paymentsContractAddress).modifyRailLockup(
    railId,         // Rail ID
    100,            // Lockup period (100 epochs)
    10 * 10**18     // Fixed lockup amount (10 tokens for onboarding)
);
```

At this point:

- A rail is established between the client and service provider
- The rail has a `fixedLockup` of 10 tokens and a `lockupPeriod` of 100 epochs
- The payment `rate` is still 0 (service hasn't started yet)
- The client's account lockup threshold is increased by 10 tokens

### 4. Deal Acceptance and Service Start

When the service provider accepts the deal:

```solidity
// Service contract (operator) increases the payment rate and makes a one-time payment
Payments(paymentsContractAddress).modifyRailPayment(
    railId,           // Rail ID
    2 * 10**18,       // New payment rate (2 tokens per epoch)
    3 * 10**18        // One-time onboarding payment (3 tokens)
);
```

This operation:

- Makes an immediate one-time payment of 3 tokens to the service provider, deducted from the rail's fixed lockup
- Updates the client's `lockupCurrent` to include rate × `lockupPeriod`
- The client's account now locks `2 × 100 + (10-3) = 207` tokens including the remaining fixed lockup, locking an additional 2 tokens every epoch

### 5. Periodic Settlement

Payment settlement can be triggered by any rail participant:

```solidity
// Settlement call - can be made by client, service provider, or operator
(uint256 amount, uint256 settledEpoch, string memory note) = Payments(paymentsContractAddress).settleRail(
    railId,        // Rail ID
    block.number   // Settle up to current epoch
);
```

This settlement:

- Calculates amount owed based on rail's rate and time elapsed
- Transfers tokens from client's account to service provider's account
- If a validator is specified, it may modify the payment amount or limit settlement epochs
- Records the epoch up to which the rail has been settled

A rail may only be settled if either (a) the client's account is fully funded or (b) the rail is terminated (in which case the rail may be settled up to the rail's "end epoch").

### 6. Deal Modification

If service terms change during the deal:

```solidity
// Operator modifies payment parameters
Payments(paymentsContractAddress).modifyRailPayment(
    railId,           // Rail ID
    4 * 10**18,       // Increased rate (4 tokens per epoch)
    0                 // No one-time payment
);

// If lockup terms need changing
Payments(paymentsContractAddress).modifyRailLockup(
    railId,         // Rail ID
    150,            // Extended lockup period (150 epochs)
    15 * 10**18     // Increased fixed lockup (15 tokens)
);
```

### 7. Deal Cancellation

When a user cancels a deal, the service contract will modify the rail's payment to take that into account. In this case, the service contract sets the rail's payment rate to zero and pays a fixed termination fee out of the rail's "fixed" lockup.

```solidity
// Service contract reduces payment rate and possibly issues a termination payment
Payments(paymentsContractAddress).modifyRailPayment(
    railId,        // Rail ID
    0,             // Zero out payment rate
    5 * 10**18     // Termination fee (5 tokens)
);
```

### 9. Final Settlement and Withdrawal

After a terminated rail reaches its `endEpoch`, it can be fully settled to unlock all remaining funds.

```solidity
// Final settlement
(uint256 amount, uint256 settledEpoch, string memory note) = Payments(paymentsContractAddress).settleRail(
    railId,        // Rail ID
    rails[railId].endEpoch // Settle up to end epoch
);

// Client withdraws remaining funds
Payments(paymentsContractAddress).withdraw(
    tokenAddress,    // Token address
    remainingAmount  // Amount to withdraw
);
```

## Emergency Scenarios

If some component in the system (operator, validator, client, SP) misbehaves, all parties have escape hatches that allow them to walk away with predictable losses.

### Reducing Operator Allowance

At any time, the client can reduce the operator's allowance (e.g., to zero) and/or change whether or not the operator is allowed to create new rails. Such modifications won't affect existing rails, although the operator will not be able to increase the payment rates on any rails they manage until they're back under their limits.

### Rail Termination (by client)

If something goes wrong (e.g., the operator is buggy and is refusing to terminate deals, stop payment, etc.), the client may terminate the to prevent future payment beyond the rail's lockup period. The client must ensure that their account is fully funded before they can terminate any rails.

```solidity
// Client terminates the rail
Payments(paymentsContractAddress).terminateRail(railId);
```

Termination:

- Forcibly reduces the rail's payment rate to zero `lockupPeriod` epochs into the future.
- Immediately stops locking new funds to the rail.
- Causes any fixed funds locked to the rail to automatically unlock after the `lockupPeriod` elapses.

### Rail Termination (by operator)

At any time, even if the client's account isn't fully funded, the operator can terminate a rail. This will allow the recipient to settle any funds available in the rail to receive partial payment.

### Rail Settlement Without Validation

If a validator contract is malfunctioning, the _client_ may forcibly settle the rail the rail "in full" (skipping validation) to prevent the funds from getting stuck in the rail pending final validation. This can only be done after the rail has been terminated (either by the client or by the operator), and should be used as a last resort.

```solidity
// Emergency settlement for terminated rails with stuck validation
(uint256 amount, uint256 settledEpoch, string memory note) = Payments(paymentsContractAddress).settleTerminatedRailWithoutValidation(railId);
```

### Client Reducing Operator Allowance After Deal Proposal

#### Scenario
If a client reduces an operator’s `rateAllowance` after a deal proposal but before the service provider (SP) accepts the deal, the following can occur:
1. The operator has already locked a fixed amount in a rail for the deal.
2. The SP, seeing the locked funds, does the work and tries to accept the deal.
3. The client reduces the operator’s `rateAllowance` before the operator can start the payment stream.
4. When the operator tries to begin payments (by setting the payment rate), the contract checks the current allowance and **the operation fails** if the new rate exceeds the reduced allowance—even if there is enough fixed lockup.

#### Contract Behavior
- The contract enforces that operators cannot lock funds at a rate higher than their current allowance.
- The operator might not be able to initiate the payment stream as planned if the allowance is decreased after the rail setup.

#### Resolution: One-Time Payment from Fixed Lockup
From the fixed lockup, the operator can still use the `modifyRailPayment` function to make a **one-time payment** to the SP. Even if the rate allowance was lowered following the deal proposal, this still enables the SP to be compensated for their work.

**Example Usage:**
```solidity
Payments.modifyRailPayment(
    railId,
    0,
    oneTimePayment
);
```

#### Best Practice
- Unless absolutely required, clients should refrain from cutting operator allowances for ongoing transactions.
- In the event that the rate stream cannot be initiated, operators should be prepared for this possibility and utilize one-time payments as a backup.
