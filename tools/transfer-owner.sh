#! /bin/bash
# transfer-owner transfers ownership of the Payments contract to a new owner
# Assumption: KEYSTORE, PASSWORD, RPC_URL, PAYMENTS_CONTRACT_ADDRESS, NEW_OWNER env vars are set
# Assumption: forge, cast, jq are in the PATH
#
echo "Transferring ownership of Payments contract"

if [ -z "$RPC_URL" ]; then
  echo "Error: RPC_URL is not set"
  exit 1
fi

if [ -z "$KEYSTORE" ]; then
  echo "Error: KEYSTORE is not set"
  exit 1
fi

if [ -z "$PAYMENTS_CONTRACT_ADDRESS" ]; then
  echo "Error: PAYMENTS_CONTRACT_ADDRESS is not set"
  exit 1
fi

if [ -z "$NEW_OWNER" ]; then
  echo "Error: NEW_OWNER is not set"
  exit 1
fi

ADDR=$(cast wallet address --keystore "$KEYSTORE" --password "$PASSWORD")
echo "Transferring ownership from $ADDR to $NEW_OWNER"

# Get current owner before transfer
echo "Getting current owner..."
CURRENT_OWNER=$(cast call --rpc-url "$RPC_URL" "$PAYMENTS_CONTRACT_ADDRESS" "owner()")
echo "Current owner: $CURRENT_OWNER"

echo "Transferring ownership of Payments Contract at $PAYMENTS_CONTRACT_ADDRESS"
cast send --rpc-url "$RPC_URL" --keystore "$KEYSTORE" --password "$PASSWORD" "$PAYMENTS_CONTRACT_ADDRESS" "transferOwnership(address)" "$NEW_OWNER"

# Get new owner after transfer
echo "Verifying new owner..."
NEW_OWNER_VERIFIED=$(cast call --rpc-url "$RPC_URL" "$PAYMENTS_CONTRACT_ADDRESS" "owner()")
echo "New owner: $NEW_OWNER_VERIFIED"

echo ""
echo "=== OWNERSHIP TRANSFER SUMMARY ==="
echo "Payments Contract Address: $PAYMENTS_CONTRACT_ADDRESS"
echo "Previous Owner: $CURRENT_OWNER"
echo "New Owner: $NEW_OWNER_VERIFIED"
echo "================================" 