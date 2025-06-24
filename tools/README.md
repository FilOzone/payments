# Filecoin Payment Services Tools

A place for all tools related to deploying, upgrading, and managing the Payments contract.

## Tools

### Available Tools

- **Deployment Script**: `deploy.sh` (all networks)
- **Upgrade Script**: `upgrade-contract.sh` (all networks)
- **Ownership Management**: `transfer-owner.sh`, `get-owner.sh`

### Deployment Script

#### deploy.sh
This script deploys the Payments contract to the specified network. Usage:

```bash
./tools/deploy.sh <chain_id>
# Example: 314159 (calibnet), 314 (mainnet), 12345 (devnet)
```
- Uses `IMPLEMENTATION_PATH` if set, otherwise defaults to `src/Payments.sol:Payments`.
- Sets a default `RPC_URL` if not provided, based on `CHAIN_ID`.
- Outputs the Payments Contract Address (proxy) and Implementation Address.

### Upgrade Script

#### upgrade-contract.sh
This script upgrades the Payments contract on the specified network. Usage:

```bash
./tools/upgrade-contract.sh <chain_id>
# Example: 314159 (calibnet), 314 (mainnet), 12345 (devnet)
```
- Uses `IMPLEMENTATION_PATH` if set, otherwise defaults to `src/Payments.sol:Payments`.
- Sets a default `RPC_URL` if not provided, based on `CHAIN_ID`.
- Requires `PAYMENTS_CONTRACT_ADDRESS` environment variable.
- Outputs the Payments Contract Address and new Implementation Address.

### Ownership Management Scripts

#### get-owner.sh
This script displays the current owner of the Payments contract. Requires `PAYMENTS_CONTRACT_ADDRESS` environment variable.

#### transfer-owner.sh
This script transfers ownership of the Payments contract to a new owner. Requires `PAYMENTS_CONTRACT_ADDRESS` and `NEW_OWNER` environment variables.

### Environment Variables

To use these scripts, set the following environment variables:
- `RPC_URL` - The RPC URL for the network. For Calibration Testnet (314159) and Mainnet (314), a default is set if not provided. For devnet or any custom CHAIN_ID, you must set `RPC_URL` explicitly.
- `KEYSTORE` - Path to the keystore file
- `PASSWORD` - Password for the keystore
- `PAYMENTS_CONTRACT_ADDRESS` - Address of the Payments contract (proxy, for upgrades and ownership operations)
- `IMPLEMENTATION_PATH` - Path to the implementation contract (e.g., "src/Payments.sol:Payments")
- `UPGRADE_DATA` - Calldata for the upgrade (usually empty for simple upgrades)
- `NEW_OWNER` - Address of the new owner (for ownership transfers)

### Make Targets

```bash
# Deployment
make deploy-devnet                  # Deploy to local devnet
make deploy-calibnet                # Deploy to Calibration Testnet
make deploy-mainnet                 # Deploy to Mainnet

# Upgrades
make upgrade-devnet                 # Upgrade on local devnet
make upgrade-calibnet               # Upgrade on Calibration Testnet
make upgrade-mainnet                # Upgrade on Mainnet

# Ownership
make transfer-owner     # Transfer ownership
make get-owner          # Display current owner
```

---

### Direct Script Usage (without Make)

You can run all scripts directly from the `tools/` directory without using Makefile targets.  
Set the required environment variables as shown below, then invoke the scripts with the appropriate arguments.

**Note:**  
- For Calibration Testnet (314159) and Mainnet (314), the script sets a default `RPC_URL` if not provided.  
- For devnet or any custom `CHAIN_ID`, you must set `RPC_URL` explicitly or the script will exit with an error.  
- You can always inspect each script for more details on required and optional environment variables.

#### Deploy

```bash
export KEYSTORE="/path/to/keystore"
export PASSWORD="your-password"
# Optionally set IMPLEMENTATION_PATH and RPC_URL
./tools/deploy.sh <chain_id>
# Example: ./tools/deploy.sh 314159
```

#### Upgrade

```bash
export KEYSTORE="/path/to/keystore"
export PASSWORD="your-password"
export PAYMENTS_CONTRACT_ADDRESS="0x..."
# Optionally set IMPLEMENTATION_PATH, UPGRADE_DATA, and RPC_URL
./tools/upgrade-contract.sh <chain_id>
# Example: ./tools/upgrade-contract.sh 314
```

#### Get Owner

```bash
export PAYMENTS_CONTRACT_ADDRESS="0x..."
# Optionally set RPC_URL
./tools/get-owner.sh
```

#### Transfer Ownership

```bash
export KEYSTORE="/path/to/keystore"
export PASSWORD="your-password"
export PAYMENTS_CONTRACT_ADDRESS="0x..."
export NEW_OWNER="0x..."
# Optionally set RPC_URL
./tools/transfer-owner.sh
```

### Example Usage

```bash
# Get current owner
export PAYMENTS_CONTRACT_ADDRESS="0x..."
make get-owner

# Deploy to calibnet
export KEYSTORE="/path/to/keystore"
export PASSWORD="your-password"
make deploy-calibnet

# Upgrade contract
export PAYMENTS_CONTRACT_ADDRESS="0x..."
export IMPLEMENTATION_PATH="src/Payments.sol:Payments"
export UPGRADE_DATA="0x"
make upgrade-calibnet

# Transfer ownership
export PAYMENTS_CONTRACT_ADDRESS="0x..."
export NEW_OWNER="0x..."
make transfer-owner
``` 