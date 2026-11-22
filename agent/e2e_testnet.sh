#!/usr/bin/env bash
# End-to-end demo on Aevum testnet (chain 44005) — mirrors agent/e2e_fork.sh.
#   create allowance (cap 3, per-payment 1, expiry +1 day) -> agent pays
#   1 tUSD8 via agent.py (LLM chain) -> agent tries 2 tUSD8, must be
#   refused at the policy layer -> owner revokes, 2 tUSD8 refunded.
#
# Usage: bash agent/e2e_testnet.sh [VAULT_ADDRESS]
#   VAULT defaults to the Fase 3 deployment. Needs:
#   - a Foundry keystore ACCOUNT holding the project wallet
#     (cast wallet import <name> --interactive; testnet-only key!)
#   - the project wallet funded with 1 tQDAY + 5 tUSD8 (see README)
#   - cast/forge on PATH; python3. LLM keys are optional: without them
#     the agent runs heuristic-only (same as the fork script).
# Owner and agent are the same project wallet here, and the payee is the
# project wallet itself, so all demo funds stay under project control.
# Total tUSD8 that leaves the vault: 1 (paid) + 2 (refund) = 3, all back
# to the owner by the end. Set ACCOUNT=<keystore name> (default:
# aevum-deployer). You will be asked for the keystore password.
set -euo pipefail
export PATH="$HOME/.foundry/bin:$PATH"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
RPC=https://rpc-test.qday.info
VAULT="${1:-0x7FBaa28bEF2c02B2287a8504C18e0B39dA8cA0a7}"
ACCOUNT="${ACCOUNT:-aevum-deployer}"
TUSD8=0x456569838f1d43009A91ebA4263147Afd7233483
OWNER=$(cast wallet address --account "$ACCOUNT")
echo "vault:  $VAULT"
echo "owner/agent/payee: $OWNER"
echo "owner tUSD8 before: $(cast call $TUSD8 'balanceOf(address)(uint256)' $OWNER --rpc-url $RPC)"
echo "owner tQDAY before: $(cast balance $OWNER --rpc-url $RPC)"

NOW=$(python3 -c "
import json, urllib.request
body=json.dumps({'jsonrpc':'2.0','method':'eth_getBlockByNumber','params':['latest',False],'id':1}).encode()
req=urllib.request.Request('$RPC', data=body, headers={'Content-Type':'application/json'})
print(int(json.load(urllib.request.urlopen(req, timeout=30))['result']['timestamp'], 16))")
EXPIRY=$((NOW + 86400))

echo "== owner approves vault (3 tUSD8), then creates allowance (cap 3, per-pay 1) =="
ID=$(cast call $VAULT "nextAllowanceId()(uint256)" --rpc-url $RPC)
echo "new allowance id will be: $ID"
cast send $TUSD8 "approve(address,uint256)" $VAULT 3000000 \
  --account "$ACCOUNT" --rpc-url $RPC --legacy --json | python3 -c "import json,sys; print('approve tx:', json.load(sys.stdin)['transactionHash'])"
cast send $VAULT "createAllowance(address,uint256,uint256,uint256,address[])" \
  $OWNER 3000000 1000000 $EXPIRY "[$OWNER]" \
  --account "$ACCOUNT" --rpc-url $RPC --legacy --json | python3 -c "import json,sys; print('createAllowance tx:', json.load(sys.stdin)['transactionHash'])"
echo "allowance #$ID:"
cast call $VAULT "allowanceOf(uint256)(address,address,uint256,uint256,uint256,uint256,bool)" $ID --rpc-url $RPC

echo "== agent pays 1 tUSD8 (LLM chain decides; needs no key to run heuristic-only) =="
python3 agent/agent.py --vault $VAULT --rpc-url $RPC \
  --request "{\"allowanceId\": $ID, \"task\": \"pay monthly API bill\", \"payee\": \"$OWNER\", \"amount\": \"1\"}"
echo "remaining after pay: $(cast call $VAULT "remaining(uint256)(uint256)" $ID --rpc-url $RPC)"

echo "== agent tries 2 tUSD8 (over per-payment cap 1) — must be refused =="
if python3 agent/agent.py --vault $VAULT --rpc-url $RPC \
  --request "{\"allowanceId\": $ID, \"task\": \"pay monthly API bill\", \"payee\": \"$OWNER\", \"amount\": \"2\"}"; then
  echo "ERROR: over-cap payment was approved"; exit 1
fi
echo "refused as expected; remaining unchanged:"
cast call $VAULT "remaining(uint256)(uint256)" $ID --rpc-url $RPC

echo "== owner revokes; refund goes back =="
BEFORE=$(cast call $TUSD8 "balanceOf(address)(uint256)" $OWNER --rpc-url $RPC)
cast send $VAULT "revoke(uint256)" $ID --account "$ACCOUNT" --rpc-url $RPC --legacy --json \
  | python3 -c "import json,sys; print('revoke tx:', json.load(sys.stdin)['transactionHash'])"
AFTER=$(cast call $TUSD8 "balanceOf(address)(uint256)" $OWNER --rpc-url $RPC)
echo "owner balance before revoke: $BEFORE after: $AFTER (expect +2000000 = 2 tUSD8)"
echo "owner tUSD8 final: $AFTER (expect 5000000 = 5 tUSD8, i.e. exactly what we started with)"
echo "E2E OK — vault $VAULT — https://explorer-test.qday.info/address/$VAULT"
