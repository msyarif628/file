#!/usr/bin/env bash
# Sentinel demo driver — normal transfer (no pause) vs drain burst (pause).
#
# Prerequisites: contracts deployed per script/DEPLOY.md; the deployer key
# holds SENT (DeploySepolia mints 100,000, deposits 50,000 into the vault).
# Env (placeholders only — NEVER commit a real key):
#   SEPOLIA_RPC   Sepolia RPC URL
#   PRIVATE_KEY   deployer key (0x...); used ONLY for these demo transactions
#   TOKEN         SentinelToken address on Sepolia
#   VAULT         SentinelVault address on Sepolia
#   RSC           SentinelReactive address on Lasna
#
# What it does:
#   1. Deposits 1,000 SENT so the vault is well funded.
#   2. Normal withdrawal of 10 SENT -> vault must stay UNPAUSED.
#   3. Drain burst: 5 x 800 SENT rapid withdrawals -> the on-chain model
#      scores the first transfer ~9933, the RSC requests a callback, and
#      the vault pauses. Later burst withdrawals may REVERT once the pause
#      lands — that IS the circuit breaker working, not an error.
#   4. Polls paused() until true (up to 120 s) and prints all tx hashes.
#      The Lasna reactive tx is found on the RSC's Reactscan page:
#      https://lasna.reactscan.net/address/$RSC
set -euo pipefail

: "${SEPOLIA_RPC:?set SEPOLIA_RPC}"
: "${PRIVATE_KEY:?set PRIVATE_KEY}"
: "${TOKEN:?set TOKEN}"
: "${VAULT:?set VAULT}"
: "${RSC:?set RSC}"

SEPOLIA_EXPLORER="https://sepolia.etherscan.io/tx"
REACTSCAN="https://lasna.reactscan.net/address/$RSC"

echo "== Sentinel demo =="
echo "TOKEN=$TOKEN"
echo "VAULT=$VAULT"
echo "RSC=$RSC"
echo "Reactscan (RSC): $REACTSCAN"
echo

paused() {
  # cast returns the raw 32-byte word (0x00..00 / 0x00..01); normalise to
  # true/false so the comparisons below work. (Before this fix the script
  # compared the raw hex against the string "true" and always printed
  # "vault did NOT pause" even when the vault had paused — the
  # 2026-11-17 live demo paused the vault but the script reported FAIL.)
  if [ "$(cast call "$VAULT" "paused()" --rpc-url "$SEPOLIA_RPC")" = "0x0000000000000000000000000000000000000000000000000000000000000001" ]; then
    echo true
  else
    echo false
  fi
}
balance_vault() { cast call "$TOKEN" "balanceOf(address)" "$VAULT" --rpc-url "$SEPOLIA_RPC"; }

echo "--- before: paused=$(paused) | vault balance=$(balance_vault) wei ---"
echo

# 1. Top up the vault.
echo "--- 1. deposit 1,000 SENT into the vault ---"
cast send "$TOKEN" "approve(address,uint256)" "$VAULT" 1000ether \
  --rpc-url "$SEPOLIA_RPC" --private-key "$PRIVATE_KEY" >/dev/null
DEPOSIT_TX=$(cast send "$VAULT" "deposit(uint256)" 1000ether \
  --rpc-url "$SEPOLIA_RPC" --private-key "$PRIVATE_KEY" --json | jq -r .transactionHash)
echo "deposit tx: $DEPOSIT_TX ($SEPOLIA_EXPLORER/$DEPOSIT_TX)"
echo "vault balance now: $(balance_vault) wei"
echo

# 2. Normal withdrawal — must NOT pause the vault.
echo "--- 2. normal withdrawal: 10 SENT (expect NO pause) ---"
NORMAL_TX=$(cast send "$VAULT" "withdraw(uint256)" 10ether \
  --rpc-url "$SEPOLIA_RPC" --private-key "$PRIVATE_KEY" --json | jq -r .transactionHash)
echo "normal withdraw tx: $NORMAL_TX ($SEPOLIA_EXPLORER/$NORMAL_TX)"
sleep 5
echo "paused after normal withdrawal: $(paused)   (want: false)"
echo

# 3. Drain burst — 5 rapid 800-SENT withdrawals.
#    NOTE: withdraw() pays msg.sender (the deployer), so all five go to the
#    same address — the model still scores the first one ~9933, because
#    amount + burst count + cumulative outflow dominate the score (the
#    fresh-recipient flag is a minor signal). Fresh-recipient bursts are
#    covered in the forge tests (test/SentinelReactive.t.sol), where the
#    fabricated logs use a distinct `to` per transfer.
echo "--- 3. drain burst: 5 x 800 SENT, rapid (expect PAUSE) ---"
for i in 1 2 3 4 5; do
  echo "  burst $i: withdraw 800 SENT"
  TX=$(cast send "$VAULT" "withdraw(uint256)" 800ether \
    --rpc-url "$SEPOLIA_RPC" --private-key "$PRIVATE_KEY" --json 2>/dev/null \
    | jq -r .transactionHash 2>/dev/null || true)
  if [ -n "${TX:-}" ] && [ "$TX" != "null" ]; then
    echo "    tx: $TX ($SEPOLIA_EXPLORER/$TX)"
  else
    echo "    reverted — vault already paused (circuit breaker working)"
  fi
  # NOTE: the burst uses withdraw() for simplicity; a real attacker would
  # call whatever moves tokens out of the vault. Any Transfer FROM the
  # vault feeds the model, regardless of which function emitted it.
done
echo

# 4. Wait for the callback to land and pause the vault.
echo "--- 4. waiting for the pause callback (up to 120 s) ---"
for _ in $(seq 1 24); do
  if [ "$(paused)" = "true" ]; then
    echo "VAULT PAUSED — circuit breaker fired."
    break
  fi
  sleep 5
done
echo "paused now: $(paused)"
echo "vault balance now: $(balance_vault) wei"
echo
echo "== demo summary =="
echo "normal withdraw tx : $NORMAL_TX"
echo "drain burst txs    : see above (first one is the trigger)"
echo "RSC (Lasna)        : $RSC — reactive tx visible at $REACTSCAN"
echo "callback tx        : find it on the vault's Sepolia Etherscan page;"
echo "                     it is the tx that called onAnomaly() on $VAULT"
if [ "$(paused)" = "true" ]; then
  echo "RESULT: PASS — drain detected, vault paused."
else
  echo "RESULT: vault did NOT pause within 120 s. Check: RSC funded"
  echo "(debt/reserves on Lasna), subscription on Reactscan, and that"
  echo "the burst transfers were FROM the vault (see script/DEPLOY.md §6)."
fi
