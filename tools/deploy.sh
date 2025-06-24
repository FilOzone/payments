#! /bin/bash
# deploy.sh deploys the Payments contract to the specified network
# Usage: ./tools/deploy.sh <chain_id>
# Example: ./tools/deploy.sh 314159 (calibnet)
#          ./tools/deploy.sh 314 (mainnet)
#          ./tools/deploy.sh 31415926 (devnet)
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

ADDR=$(cast wallet address --keystore "$KEYSTORE" --password "$PASSWORD")
echo "Deploying Payments from address $ADDR to chain $CHAIN_ID"
NONCE="$(cast nonce --rpc-url "$RPC_URL" "$ADDR")"

# Use IMPLEMENTATION_PATH if set, otherwise default
if [ -z "${IMPLEMENTATION_PATH:-}" ]; then
  IMPLEMENTATION_PATH="src/Payments.sol:Payments"
fi

echo "Deploying Payments implementation ($IMPLEMENTATION_PATH)"
PAYMENTS_IMPLEMENTATION_ADDRESS=$(forge create --rpc-url "$RPC_URL" --keystore "$KEYSTORE" --password "$PASSWORD" --broadcast --nonce $NONCE --chain-id $CHAIN_ID $IMPLEMENTATION_PATH | grep "Deployed to" | awk '{print $3}')
if [ -z "$PAYMENTS_IMPLEMENTATION_ADDRESS" ]; then
    echo "Error: Failed to extract Payments implementation contract address"
    exit 1
fi
echo "Implementation Address: $PAYMENTS_IMPLEMENTATION_ADDRESS"

NONCE=$(expr $NONCE + 1)

echo "Deploying Payments Contract (proxy)"
INIT_DATA=$(cast calldata "initialize()")
PAYMENTS_CONTRACT_ADDRESS=$(forge create --rpc-url "$RPC_URL" --keystore "$KEYSTORE" --password "$PASSWORD" --broadcast --nonce $NONCE --chain-id $CHAIN_ID src/ERC1967Proxy.sol:PaymentsERC1967Proxy --constructor-args $PAYMENTS_IMPLEMENTATION_ADDRESS $INIT_DATA | grep "Deployed to" | awk '{print $3}')
if [ -z "$PAYMENTS_CONTRACT_ADDRESS" ]; then
    echo "Error: Failed to extract Payments contract address"
    exit 1
fi
echo "Payments Contract Address: $PAYMENTS_CONTRACT_ADDRESS"

echo ""
echo "=== DEPLOYMENT SUMMARY ==="
echo "Implementation Address: $PAYMENTS_IMPLEMENTATION_ADDRESS"
echo "Payments Contract Address: $PAYMENTS_CONTRACT_ADDRESS"
echo "=========================="
echo "Use the Payments Contract Address ($PAYMENTS_CONTRACT_ADDRESS) for all interactions with the contract." 