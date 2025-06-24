#! /bin/bash
# upgrade-contract.sh upgrades the Payments contract on the specified network
# Usage: ./tools/upgrade-contract.sh <chain_id>
# Example: ./tools/upgrade-contract.sh 314159 (calibnet)
#          ./tools/upgrade-contract.sh 314 (mainnet)
#          ./tools/upgrade-contract.sh 12345 (devnet)
#
set -euo pipefail

CHAIN_ID=${1:-314159} # Default to calibnet

# Set default RPC_URL if not set
if [ -z "${RPC_URL:-}" ]; then
  if [ "$CHAIN_ID" = "314159" ]; then
    export RPC_URL="https://api.calibration.node.glif.io/rpc/v1"
  elif [ "$CHAIN_ID" = "314" ]; then
    export RPC_URL="https://api.node.glif.io/rpc/v1"
  else
    echo "Error: RPC_URL must be set for CHAIN_ID $CHAIN_ID"
    exit 1
  fi
fi

if [ -z "${KEYSTORE:-}" ]; then
  echo "Error: KEYSTORE is not set"
  exit 1
fi
if [ -z "${PASSWORD:-}" ]; then
  echo "Error: PASSWORD is not set"
  exit 1
fi
if [ -z "${PAYMENTS_CONTRACT_ADDRESS:-}" ]; then
  echo "Error: PAYMENTS_CONTRACT_ADDRESS is not set"
  exit 1
fi

# Use IMPLEMENTATION_PATH if set, otherwise default
if [ -z "${IMPLEMENTATION_PATH:-}" ]; then
  IMPLEMENTATION_PATH="src/Payments.sol:Payments"
fi

# Set default UPGRADE_DATA to empty if not provided
if [ -z "${UPGRADE_DATA:-}" ]; then
  UPGRADE_DATA="0x"
fi

ADDR=$(cast wallet address --keystore "$KEYSTORE" --password "$PASSWORD")
echo "Upgrading Payments contract from address $ADDR on chain $CHAIN_ID"

NONCE="$(cast nonce --rpc-url "$RPC_URL" "$ADDR")"
echo "Current nonce: $NONCE"

echo "Deploying new implementation ($IMPLEMENTATION_PATH)"
IMPLEMENTATION_ADDRESS=$(forge create --rpc-url "$RPC_URL" --keystore "$KEYSTORE" --password "$PASSWORD" --broadcast --nonce $NONCE --chain-id $CHAIN_ID $IMPLEMENTATION_PATH | grep "Deployed to" | awk '{print $3}')
if [ -z "$IMPLEMENTATION_ADDRESS" ]; then
    echo "Error: Failed to extract implementation contract address"
    exit 1
fi
echo "Implementation Address: $IMPLEMENTATION_ADDRESS"

NONCE=$(expr $NONCE + 1)
echo "Upgrading Payments Contract ($PAYMENTS_CONTRACT_ADDRESS) with nonce $NONCE"
cast send --rpc-url "$RPC_URL" --keystore "$KEYSTORE" --password "$PASSWORD" --chain-id $CHAIN_ID --nonce $NONCE "$PAYMENTS_CONTRACT_ADDRESS" "upgradeToAndCall(address,bytes)" "$IMPLEMENTATION_ADDRESS" "$UPGRADE_DATA"

echo ""
echo "=== UPGRADE SUMMARY ==="
echo "Payments Contract Address: $PAYMENTS_CONTRACT_ADDRESS"
echo "New Implementation: $IMPLEMENTATION_ADDRESS"
echo "Upgrade Data: $UPGRADE_DATA"
echo "==========================" 