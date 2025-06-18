#! /bin/bash
# get-owner displays the current owner of the proxy contract
# Assumption: RPC_URL, PROXY_ADDRESS env vars are set
# Assumption: forge, cast, jq are in the PATH
#
echo "Getting current owner of Payments contract"

if [ -z "$RPC_URL" ]; then
  echo "Error: RPC_URL is not set"
  exit 1
fi

if [ -z "$PROXY_ADDRESS" ]; then
  echo "Error: PROXY_ADDRESS is not set"
  exit 1
fi

echo "Getting current owner of proxy at $PROXY_ADDRESS"
CURRENT_OWNER=$(cast call --rpc-url "$RPC_URL" "$PROXY_ADDRESS" "owner()")

echo ""
echo "=== OWNER INFORMATION ==="
echo "Proxy Address: $PROXY_ADDRESS"
echo "Current Owner: $CURRENT_OWNER"
echo "=========================" 