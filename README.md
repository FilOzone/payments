# FWS Payments Contract

The FWS Payments contract enables ERC20 token payment flows through "rails" - automated payment channels between clients and recipients. The contract supports continuous payments, one-time transfers, and payment arbitration.

## Key Concepts

- **Account**: Represents a user's token balance and locked funds
- **Rail**: A payment channel between a client and recipient with configurable terms
- **Arbiter**: An optional contract that can mediate payment disputes
- **Operator**: An authorized third party who can manage rails on behalf of clients

### Account

Tracks the funds, lockup, obligations, etc. associated with a single “owner” (where the owner is a smart contract or a wallet). Accounts can be both *clients* and *SPs* but we’ll often talk about them as if they were separate types.

- **Client —** An account that *pays* an SP (also referred to as the *payer*)
- **SP** — An account managed by a service provider to receive payment from a client (also referred to as the *payee).*

### Rail

A rail along which payments flow from a client to an SP. Rails track lockup, maximum payment rates, and obligations between a client and an SP. Client-SP pairs can have multiple payment rails between them but they can also reuse the same rail across multiple deals. Importantly, rails:
    - Specify the maximum rate at which the client will pay the SP, the actual amount paid for any given period is subject to arbitration by the **arbiter** described below.
    - Specify the period in advanced the client is required to lock funds (the **lockup period**). There’s no way to force clients to lock funds in advanced, but we can prevent them from *withdrawing* them and make it easy for SPs to tell if their clients haven’t met their lockup minimums, giving them time to settle their accounts.

### **Arbiter**

An arbiter is an (optional) smart contract that can arbitrate payments associated with a single rail. For example, a payment rail used for PDP will specify the PDP service as its arbiter An arbiter can:

- Prevent settlement of a payment rail entirely.
- Refuse to settle a payment rail past some epoch.
- Reduce the amount paid out by a rail for a period of time (e.g., to account for actual services rendered, penalties, etc.).

### Operator

An operator is a smart contract (likely the service contract) that manages rails on behalf of clients & SPs, with approval from the client (the client approves the operator to spend its funds at a specific rate). The operator smart contract must be trusted by both the client and the SP as it can arbitrarily alter payments (within the allowance specified by the client). It:

- Creates rails from clients to service providers.
- Changes payment rates, lockups, etc. of payment rails created by this operator.
    - The sum of payment rates across all rails operated by this contract for a specific client must be at most the maximum per-operator spend rate specified by the client.
    - The sum of the lockup across all rails operated by this contract for a specific client must be at most the maximum per-operator lockup specified by the client.
- Specify/change the payment rail arbiter of payment rails created by this operator.

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

#### `setOperatorApproval(address token, address operator, bool approved, uint256 rateAllowance, uint256 lockupAllowance)`

Configures an operator's permissions to manage rails on behalf of the caller.

- **Parameters**:
  - `token`: ERC20 token contract address
  - `operator`: Address to grant permissions to
  - `approved`: Whether the operator is approved
  - `rateAllowance`: Maximum payment rate the operator can set across all rails
  - `lockupAllowance`: Maximum funds the operator can lock for future payments

### Rail Management

#### `createRail(address token, address from, address to, address arbiter)`

Creates a new payment rail between two parties.

- **Parameters**:
  - `token`: ERC20 token contract address
  - `from`: Client (payer) address
  - `to`: Recipient address
  - `arbiter`: Optional arbitration contract address (0x0 for none)
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

#### `settleTerminatedRailWithoutArbitration(uint256 railId)`

Emergency settlement method for terminated rails with stuck arbitration.

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

### Arbitration

The contract supports optional payment arbitration through the `IArbiter` interface. When a rail has an arbiter:

1. During settlement, the arbiter contract is called
2. The arbiter can adjust payment amounts or partially settle epochs
3. This provides dispute resolution capabilities for complex payment arrangements
