#! /bin/bash
# deploy-calibnet deploys the Payments contract to Filecoin Calibration Testnet
# Assumption: KEYSTORE, PASSWORD, RPC_URL env vars are set to an appropriate eth keystore path and password
# and to a valid RPC_URL for the calibnet.
# Assumption: forge, cast, jq are in the PATH
# Assumption: called from contracts directory so forge paths work out
#
echo "Deploying Payments to calibnet"

if [ -z "$RPC_URL" ]; then
  echo "Error: RPC_URL is not set"
  exit 1
fi

if [ -z "$KEYSTORE" ]; then
  echo "Error: KEYSTORE is not set"
  exit 1
fi

ADDR=$(cast wallet address --keystore "$KEYSTORE" --password "$PASSWORD")
echo "Deploying Payments from address $ADDR"
# Parse the output of forge create to extract the contract address
 
NONCE="$(cast nonce --rpc-url "$RPC_URL" "$ADDR")"

echo "Deploying Payments implementation"
PAYMENTS_IMPLEMENTATION_ADDRESS=$(forge create --rpc-url "$RPC_URL" --keystore "$KEYSTORE" --password "$PASSWORD" --broadcast --nonce $NONCE --chain-id 314159 src/Payments.sol:Payments | grep "Deployed to" | awk '{print $3}')
if [ -z "$PAYMENTS_IMPLEMENTATION_ADDRESS" ]; then
    echo "Error: Failed to extract Payments implementation contract address"
    exit 1
fi
echo "Payments implementation deployed at: $PAYMENTS_IMPLEMENTATION_ADDRESS"

echo "Deploying Payments proxy"
NONCE=$(expr $NONCE + "1")

INIT_DATA=$(cast calldata "initialize()")
PAYMENTS_PROXY_ADDRESS=$(forge create --rpc-url "$RPC_URL" --keystore "$KEYSTORE" --password "$PASSWORD" --broadcast --nonce $NONCE --chain-id 314159 src/ERC1967Proxy.sol:PaymentsERC1967Proxy --constructor-args $PAYMENTS_IMPLEMENTATION_ADDRESS $INIT_DATA | grep "Deployed to" | awk '{print $3}')
if [ -z "$PAYMENTS_PROXY_ADDRESS" ]; then
    echo "Error: Failed to extract Payments proxy contract address"
    exit 1
fi
echo "Payments proxy deployed at: $PAYMENTS_PROXY_ADDRESS"

echo ""
echo "=== DEPLOYMENT SUMMARY ==="
echo "Payments Implementation: $PAYMENTS_IMPLEMENTATION_ADDRESS"
echo "Payments Proxy: $PAYMENTS_PROXY_ADDRESS"
echo "=========================="
echo ""
echo "Use the proxy address ($PAYMENTS_PROXY_ADDRESS) for all interactions with the contract." 