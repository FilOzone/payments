#! /bin/bash
# get-owner displays the current owner of the Payments contract
# Assumption: RPC_URL, PAYMENTS_CONTRACT_ADDRESS env vars are set
# Assumption: forge, cast, jq are in the PATH
#
echo "Getting current owner of Payments contract"

if [ -z "$RPC_URL" ]; then
  echo "Error: RPC_URL is not set"
  exit 1
fi

if [ -z "$PAYMENTS_CONTRACT_ADDRESS" ]; then
  echo "Error: PAYMENTS_CONTRACT_ADDRESS is not set"
  exit 1
fi

echo "Getting current owner of Payments Contract at $PAYMENTS_CONTRACT_ADDRESS"
CURRENT_OWNER=$(cast call --rpc-url "$RPC_URL" "$PAYMENTS_CONTRACT_ADDRESS" "owner()")

echo ""
echo "=== OWNER INFORMATION ==="
echo "Payments Contract Address: $PAYMENTS_CONTRACT_ADDRESS"
echo "Current Owner: $CURRENT_OWNER"
echo "=========================" 