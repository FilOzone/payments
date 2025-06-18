#! /bin/bash
# deploy-devnet deploys the Payments contract to a local filecoin devnet
# Assumption: KEYSTORE, PASSWORD, RPC_URL env vars are set to an appropriate eth keystore path and password
# and to a valid RPC_URL for the devnet.
# Assumption: forge, cast, lotus, jq are in the PATH
# Assumption: called from contracts directory so forge paths work out
#
echo "Deploying Payments to devnet"

if [ -z "$RPC_URL" ]; then
  echo "Error: RPC_URL is not set"
  exit 1
fi

if [ -z "$KEYSTORE" ]; then
  echo "Error: KEYSTORE is not set"
  exit 1
fi

# Send funds from default to keystore address
# assumes lotus binary in path
clientAddr=$(cat $KEYSTORE | jq '.address' | sed -e 's/\"//g')
echo "Sending funds to $clientAddr"
lotus send $clientAddr 10000
sleep 5 ## Sleep for 5 seconds so fund are available and actor is registered

NONCE="$(cast nonce --rpc-url "$RPC_URL" "$clientAddr")"

echo "Deploying Payments implementation"
# Parse the output of forge create to extract the contract address
PAYMENTS_IMPLEMENTATION_ADDRESS=$(forge create --rpc-url "$RPC_URL" --keystore "$KEYSTORE" --password "$PASSWORD" --nonce $NONCE --broadcast src/Payments.sol:Payments | grep "Deployed to" | awk '{print $3}')
if [ -z "$PAYMENTS_IMPLEMENTATION_ADDRESS" ]; then
    echo "Error: Failed to extract Payments implementation contract address"
    exit 1
fi
echo "Payments implementation deployed at: $PAYMENTS_IMPLEMENTATION_ADDRESS"

NONCE=$(expr $NONCE + "1")

echo "Deploying Payments proxy"
INIT_DATA=$(cast calldata "initialize()")
PAYMENTS_PROXY_ADDRESS=$(forge create --rpc-url "$RPC_URL" --keystore "$KEYSTORE" --password "$PASSWORD" --nonce $NONCE --broadcast src/ERC1967Proxy.sol:PaymentsERC1967Proxy --constructor-args $PAYMENTS_IMPLEMENTATION_ADDRESS $INIT_DATA | grep "Deployed to" | awk '{print $3}')
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