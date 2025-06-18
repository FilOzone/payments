# Filecoin Payment services Tools

A place for all tools related to deploying, upgrading, and managing the Payments contract.

## Tools

### Deployment Scripts

#### deploy-devnet.sh
This script deploys the Payments contract to a local filecoin devnet. It assumes lotus binary is in path and local devnet is running with eth API enabled. The keystore will be funded automatically from lotus default address.

#### deploy-calibnet.sh
This script deploys the Payments contract to Filecoin Calibration Testnet. Requires environment variables for RPC_URL, KEYSTORE, and PASSWORD.

#### deploy-mainnet.sh
This script deploys the Payments contract to Filecoin Mainnet. Requires environment variables for RPC_URL, KEYSTORE, and PASSWORD.

### Upgrade Scripts

#### upgrade-contract-calibnet.sh
This script upgrades the proxy contract to a new implementation on Calibration Testnet. Requires PROXY_ADDRESS, IMPLEMENTATION_PATH, and UPGRADE_DATA environment variables.

#### upgrade-contract-mainnet.sh
This script upgrades the proxy contract to a new implementation on Mainnet. Requires PROXY_ADDRESS, IMPLEMENTATION_PATH, and UPGRADE_DATA environment variables.

### Ownership Management Scripts

#### get-owner.sh
This script displays the current owner of the proxy contract. Requires PROXY_ADDRESS environment variable.

#### transfer-owner.sh
This script transfers ownership of the proxy contract to a new owner. Requires NEW_OWNER environment variable.

### Environment Variables

To use these scripts, set the following environment variables:
- `RPC_URL` - The RPC URL for the network (devnet/calibnet/mainnet)
- `KEYSTORE` - Path to the keystore file
- `PASSWORD` - Password for the keystore
- `PROXY_ADDRESS` - Address of the proxy contract (for upgrades and ownership operations)
- `IMPLEMENTATION_PATH` - Path to the implementation contract (e.g., "src/Payments.sol:Payments")
- `UPGRADE_DATA` - Calldata for the upgrade (usually empty for simple upgrades)
- `NEW_OWNER` - Address of the new owner (for ownership transfers)

### Example Usage

```bash
# Get current owner
export PROXY_ADDRESS="0x..."
./tools/get-owner.sh

# Deploy to calibnet
export RPC_URL="https://api.calibration.node.glif.io/rpc/v1"
export KEYSTORE="/path/to/keystore"
export PASSWORD="your-password"
./tools/deploy-calibnet.sh

# Upgrade contract
export PROXY_ADDRESS="0x..."
export IMPLEMENTATION_PATH="src/Payments.sol:Payments"
export UPGRADE_DATA="0x"
./tools/upgrade-contract-calibnet.sh

# Transfer ownership
export NEW_OWNER="0x..."
./tools/transfer-owner.sh
``` 