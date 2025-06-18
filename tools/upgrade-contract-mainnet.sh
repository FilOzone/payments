#! /bin/bash
# upgrade-contract-mainnet upgrades proxy at $PROXY_ADDRESS to a new deployment of the implementation 
# of the contract at $IMPLEMENTATION_PATH (i.e. src/Payments.sol:Payments)
# Assumption: KEYSTORE, PASSWORD, RPC_URL env vars are set to an appropriate eth keystore path and password
# and to a valid RPC_URL for the mainnet.
# Assumption: forge, cast, jq are in the PATH
#
echo "Upgrading Payments contract on mainnet"

if [ -z "$RPC_URL" ]; then
  echo "Error: RPC_URL is not set"
  exit 1
fi

if [ -z "$KEYSTORE" ]; then
  echo "Error: KEYSTORE is not set"
  exit 1
fi

if [ -z "$PROXY_ADDRESS" ]; then
  echo "Error: PROXY_ADDRESS is not set"
  exit 1
fi

if [ -z "$IMPLEMENTATION_PATH" ]; then
  echo "Error: IMPLEMENTATION_PATH is not set (i.e. src/Payments.sol:Payments)"
  exit 1
fi

# Set default UPGRADE_DATA to empty if not provided
if [ -z "$UPGRADE_DATA" ]; then
  UPGRADE_DATA="0x"
fi

ADDR=$(cast wallet address --keystore "$KEYSTORE" --password "$PASSWORD")
echo "Upgrading from address $ADDR"

# Get current nonce
NONCE="$(cast nonce --rpc-url "$RPC_URL" "$ADDR")"
echo "Current nonce: $NONCE"

echo "Deploying new $IMPLEMENTATION_PATH implementation contract"
# Parse the output of forge create to extract the contract address
IMPLEMENTATION_ADDRESS=$(forge create --rpc-url "$RPC_URL" --keystore "$KEYSTORE" --password "$PASSWORD" --broadcast --nonce $NONCE --chain-id 314 "$IMPLEMENTATION_PATH" | grep "Deployed to" | awk '{print $3}')

if [ -z "$IMPLEMENTATION_ADDRESS" ]; then
    echo "Error: Failed to extract implementation contract address"
    exit 1
fi
echo "$IMPLEMENTATION_PATH implementation deployed at: $IMPLEMENTATION_ADDRESS"

# Increment nonce for the upgrade transaction
NONCE=$(expr $NONCE + "1")
echo "Upgrading proxy at $PROXY_ADDRESS with nonce $NONCE"
cast send --rpc-url "$RPC_URL" --keystore "$KEYSTORE" --password "$PASSWORD" --chain-id 314 --nonce $NONCE "$PROXY_ADDRESS" "upgradeToAndCall(address,bytes)" "$IMPLEMENTATION_ADDRESS" "$UPGRADE_DATA"

echo ""
echo "=== UPGRADE SUMMARY ==="
echo "Proxy Address: $PROXY_ADDRESS"
echo "New Implementation: $IMPLEMENTATION_ADDRESS"
echo "Upgrade Data: $UPGRADE_DATA"
echo "==========================" 