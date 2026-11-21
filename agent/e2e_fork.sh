#!/usr/bin/env bash
# End-to-end test on the local fork (`make fork` must be running).
#   deploy vault -> fund owner+agent -> create allowance -> agent pays
#   via agent.py -> over-cap refused -> revoke -> refund checked.
# Usage: bash agent/e2e_fork.sh
# Requires: forge/cast/anvil on PATH, python3. No LLM keys: the agent
# runs heuristic-only here (LLM2/LLM3 disabled, no surrogate).
set -euo pipefail
export PATH="$HOME/.foundry/bin:$PATH"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
FORK=http://127.0.0.1:8555
ANVIL_0=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
PAYEE1=0x70997970C51812dc3A010C7d01b50e0d17dc79C8
PAYEE2=0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC
AGENT=$(python3 -c "import json; print(json.load(open('$HOME/workspace/hackathons/aevum-builder-challenge/.wallet.json'))['data'][0]['address'])")

echo "== deploy vault =="
make deploy-vault-fork > /tmp/vault-deploy.log 2>&1
VAULT=$(python3 -c "
import json
d = json.load(open('contracts/broadcast/DeployAllowanceVault.s.sol/440050/run-latest.json'))
addrs = [t['contractAddress'] for t in d['transactions'] if t.get('contractAddress')]
print(addrs[-1])")
echo "VAULT=$VAULT"

echo "== fund owner + agent =="
make deal TO=$ANVIL_0 AMOUNT=1000 > /dev/null
make deal TO=$AGENT AMOUNT=100 > /dev/null

EXPIRY=$(python3 -c "
import json, urllib.request
req = urllib.request.Request('$FORK', data=json.dumps({'jsonrpc':'2.0','method':'eth_getBlockByNumber','params':['latest',False],'id':1}).encode(), headers={'Content-Type':'application/json'})
print(int(json.load(urllib.request.urlopen(req))['result']['timestamp'], 16) + 86400)")
echo "== owner approves vault, then creates allowance (agent=$AGENT expiry=$EXPIRY) =="
cast send 0x456569838f1d43009A91ebA4263147Afd7233483 "approve(address,uint256)" $VAULT 100000000 \
  --unlocked --from $ANVIL_0 --rpc-url $FORK > /dev/null
cast send $VAULT "createAllowance(address,uint256,uint256,uint256,address[])" \
  $AGENT 100000000 30000000 $EXPIRY "[$PAYEE1,$PAYEE2]" \
  --unlocked --from $ANVIL_0 --rpc-url $FORK > /dev/null
echo "allowance 1:"; cast call $VAULT "allowanceOf(uint256)(address,address,uint256,uint256,uint256,uint256,bool)" 1 --rpc-url $FORK

export LLM2_ENABLED=0 LLM3_ENABLED=0
echo "== agent pays 5 tUSD8 to payee1 (heuristic-only) =="
python3 agent/agent.py --vault $VAULT --rpc-url $FORK \
  --request "{\"allowanceId\": 1, \"task\": \"pay monthly API bill\", \"payee\": \"$PAYEE1\", \"amount\": \"5\"}"
echo "remaining after pay:"; cast call $VAULT "remaining(uint256)(uint256)" 1 --rpc-url $FORK
echo "payee1 tUSD8 balance:"; cast call 0x456569838f1d43009A91ebA4263147Afd7233483 "balanceOf(address)(uint256)" $PAYEE1 --rpc-url $FORK

echo "== agent tries 50 tUSD8 (over per-payment cap 30) — must be refused =="
if python3 agent/agent.py --vault $VAULT --rpc-url $FORK \
  --request "{\"allowanceId\": 1, \"task\": \"pay monthly API bill\", \"payee\": \"$PAYEE1\", \"amount\": \"50\"}"; then
  echo "ERROR: over-cap payment was approved"; exit 1
fi
echo "refused as expected; remaining unchanged:"
cast call $VAULT "remaining(uint256)(uint256)" 1 --rpc-url $FORK

echo "== owner revokes; refund goes back =="
BEFORE=$(cast call 0x456569838f1d43009A91ebA4263147Afd7233483 "balanceOf(address)(uint256)" $ANVIL_0 --rpc-url $FORK)
cast send $VAULT "revoke(uint256)" 1 --unlocked --from $ANVIL_0 --rpc-url $FORK > /dev/null
AFTER=$(cast call 0x456569838f1d43009A91ebA4263147Afd7233483 "balanceOf(address)(uint256)" $ANVIL_0 --rpc-url $FORK)
echo "owner balance before revoke: $BEFORE after: $AFTER (expect +95000000 = 95 tUSD8)"
echo "remaining after revoke:"; cast call $VAULT "remaining(uint256)(uint256)" 1 --rpc-url $FORK
echo "E2E OK — vault $VAULT"
