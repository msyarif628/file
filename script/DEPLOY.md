# Sentinel — Deployment Runbook (testnets only)

> No real money, no mainnet. Every command below uses `<PLACEHOLDERS>` —
> never paste a real private key into a file, a chat log, or a commit.
> Deployed live on 2026-11-17 (v3, the working deployment — see the
> addresses table at the bottom and DEPLOYED.md at the project root).

## 0. Prerequisites

- Foundry 1.9.0: `export PATH="$PATH:$HOME/.foundry/bin"`
- Python 3 + numpy (trainer): `python3 -c "import numpy"`
- Two funded testnet accounts (same deployer key can be used on both chains):
  - **Sepolia ETH** — any public Sepolia faucet.
  - **lREACT** — send Sepolia ETH to the faucet contract
    `0x9b9BB25f1A81078C544C829c5EB7822d747Cf434`
    (1 ETH → 100 lREACT, **max 5 ETH per tx** — more is lost):
    ```bash
    export SEPOLIA_RPC=<YOUR_SEPOLIA_RPC_URL>          # e.g. from Chainlist
    export LASNA_RPC=https://lasna-rpc.rnk.dev/
    export DEPLOYER=<YOUR_DEPLOYER_ADDRESS>
    cast send 0x9b9BB25f1A81078C544C829c5EB7822d747Cf434 \
      --rpc-url $SEPOLIA_RPC --private-key <PRIVATE_KEY> \
      "request(address)" $DEPLOYER --value 0.1ether
    # 0.1 ETH -> 10 lREACT, sent to $DEPLOYER on Lasna. Suggested split:
    # 0.1 Sepolia ETH -> 10 lREACT for the RSC; 0.05 Sepolia ETH to the
    # vault for callback-delivery fees (the deploy script sends it).
    ```

## 1. Train the model + run the tests (local, no keys)

```bash
python3 ml/train.py        # expect: fixed-point accuracy ~98%, writes
                           # ml/weights.json, ml/vectors.json and
                           # contracts/ModelWeights.sol
forge build
forge test                 # expect: 23 passed, 0 failed
```

## 2. Predict the RSC address (needed BEFORE deploying the vault)

The vault's `callbackSender` is immutable, so it must be deployed with the
RSC address — but the RSC is deployed after the vault (docs order). The
bridge is address prediction: the RSC will be deployed from `$DEPLOYER`
as its next Lasna transaction, so its address is computable in advance.

```bash
export LASNA_NONCE=$(cast nonce $DEPLOYER --rpc-url $LASNA_RPC)
export RSC_PREDICTED=$(cast compute-address --rpc-url $LASNA_RPC \
  --nonce $LASNA_NONCE $DEPLOYER)
echo "Predicted RSC address: $RSC_PREDICTED"
# DO NOT send any other transaction from $DEPLOYER on Lasna until step 4,
# or the nonce (and the prediction) changes.
```

## 3. Deploy token + vault on Sepolia

```bash
export RSC_ADDRESS=$RSC_PREDICTED
forge script script/DeploySepolia.s.sol --rpc-url $SEPOLIA_RPC \
  --private-key <PRIVATE_KEY> --broadcast
# Note the printed addresses:
export TOKEN=<PRINTED_SENTINELTOKEN_ADDRESS>
export VAULT=<PRINTED_SENTINELVAULT_ADDRESS>
# Sanity: the vault holds 50,000 SENT and 0.05 ETH.
cast call $VAULT "paused()" --rpc-url $SEPOLIA_RPC
cast call $TOKEN "balanceOf(address)" $VAULT --rpc-url $SEPOLIA_RPC
```

## 4. Deploy the reactive contract on Lasna — NEVER with `forge script`

The RSC constructor calls the system contract (`subscribe`), which only
exists on real Reactive nodes — it reverts in Forge simulation. Deploy
with a real broadcast transaction instead. `forge create` (primary) or
`cast send --create` (alternative) both work because the constructor
executes on-chain.

```bash
# Primary: forge create (broadcasts one real transaction).
forge create --rpc-url $LASNA_RPC --private-key <PRIVATE_KEY> \
  --value 0.1ether \
  contracts/SentinelReactive.sol:SentinelReactive \
  --constructor-args 11155111 $TOKEN 11155111 $VAULT

# Alternative: cast send --create (same effect).
# BYTECODE=$(jq -r '.bytecode.object' out/SentinelReactive.sol/SentinelReactive.json)
# cast send --create $BYTECODE --rpc-url $LASNA_RPC \
#   --private-key <PRIVATE_KEY> --value 0.1ether \
#   $(cast abi-encode "constructor(uint256,address,uint256,address)" \
#     11155111 $TOKEN 11155111 $VAULT)

export RSC=<DEPLOYED_RSC_ADDRESS>
# The deployed address MUST equal $RSC_PREDICTED (same deployer + nonce).
# If it does not, the vault was deployed with the wrong callbackSender:
# redeploy the vault (step 3) with RSC_ADDRESS=$RSC and redeploy the RSC
# only if its own address also changed (it cannot — same nonce).
```

## 5. Point the RSC at the vault + fund both sides

```bash
# (a) Recipient (docs deployment order, step 3).
cast send $RSC "setRecipient(address)" $VAULT \
  --rpc-url $LASNA_RPC --private-key <PRIVATE_KEY>

# (b) Fund the RSC with lREACT reserves (settles reactive-tx fees).
#     depositTo credits the RSC; sending lREACT directly to the system
#     contract would credit the sender, not the RSC.
export SYSTEM=0x8888888888888888888888888888888888888888
cast send $SYSTEM "depositTo(address)" $RSC --value 1ether \
  --rpc-url $LASNA_RPC --private-key <PRIVATE_KEY>
# 1 lREACT of reserves to start; watch debt()/reserves() and top up:
cast call $SYSTEM "debt(address)" $RSC --rpc-url $LASNA_RPC
cast call $SYSTEM "reserves(address)" $RSC --rpc-url $LASNA_RPC

# (c) The vault already holds 0.05 Sepolia ETH (step 3) for callback fees.
#     If its debt ever rises above zero, settle it:
#     cast send $VAULT "coverDebt()" --rpc-url $SEPOLIA_RPC --private-key <PRIVATE_KEY>
#     Same for the RSC (Omni system contract):
#     cast send $RSC "coverDebtOmni()" --rpc-url $LASNA_RPC --private-key <PRIVATE_KEY>
```

## 6. Verify on Reactscan (Lasna) — LIVE CHECK, do not skip

```bash
# https://lasna.reactscan.net/address/$RSC
#   - Status must be `active` (not `inactive` / in debt).
#   - The Subscriptions view must list the Transfer subscription on
#     Sepolia chain 11155111, contract $TOKEN, topic0 0xddf252ad...
```

Then run the demo (`script/demo.sh`, below). After the first normal
transfer, the RSC must show a reactive transaction on Reactscan. **If no
reactive transaction ever appears**, the subscription did not register on
Omni — the documented fallback is a one-line change in
`SentinelReactive.sol`: subscribe via the legacy `service` as well
(`service.subscribe(...)` next to the Omni call), redeploy the RSC, and
re-run from step 4. **That fallback was tried on 2026-11-17 (v2) and did
NOT fix callback delivery** — react() fired on both paths but the
callback was still never delivered. The real fix is in `react()` itself:
request the callback via the Omni `requestCallbackV_1_0` low-level call
(§3.2 of docs-research.md), not the legacy `emit Callback(...)` event —
see README.md ("Deviation log") and DEPLOYED.md. v3 (2026-11-17) is the
first deployment that delivers the callback and pauses the vault.

## 7. Demo

```bash
export SEPOLIA_RPC=<...> TOKEN=<...> VAULT=<...> RSC=<...>
bash script/demo.sh
```

The script performs: a normal 10-SENT withdrawal (vault stays unpaused),
then a 5×800-SENT drain burst to fresh addresses (vault pauses), and
prints every transaction hash. Record the three hashes for the submission:
Sepolia drain tx → Lasna reactive tx → Sepolia callback tx.

## 8. (Optional) Verify contracts on Sourcify

```bash
forge verify-contract --verifier sourcify --chain-id 5318007 \
  $RSC SentinelReactive
forge verify-contract --verifier sourcify --chain-id 11155111 \
  $VAULT SentinelVault
forge verify-contract --verifier sourcify --chain-id 11155111 \
  $TOKEN SentinelToken
```

## Deployed addresses — v3 (2026-11-17, the working deployment)

Deployer (throwaway, testnet-only): `0x5eEF4e0Aa8a43346fAa12CBD15DDFe78CF1b2e53`

| Contract | Chain | Address | Tx hash |
|---|---|---|---|
| SentinelToken (v3) | Sepolia (11155111) | `0x572B05c0cA43100BF485C2ddedA5eB405fCf842c` | `0xa3becc3f65a1843e7f4353b5b2de24ff6edbf01ce44eeaba19d9345eae88d5ba` |
| SentinelVault (v3) | Sepolia (11155111) | `0x4019e0A7A0cc6C9A3f5B040784Dff6d23A1Fbe5C` | `0xa78c998641f8f74ce689f1c26039c1ee6e61be5825be196fc7f4cc05e7aaa2e0` |
| SentinelReactive (v3) | Lasna (5318007) | `0x68335C83ceFAd79316d5808BffD46141BC747495` | `0xb3b67f87d550923b767ac84847ccf1ae0316779f1f74aae9c14b1daf06ff827b` |
| setRecipient (v3) | Lasna | — | `0x73bc2a45c2b05e988c799846440ba1bca31e81c5f920e815da8c69d5aeff4f74` |
| depositTo 1 lREACT (v3) | Lasna | — | `0x8ed730b317d9ae1780e5d2bea4460eed5418dbb21c3edeacc438d369bf9623a5` |
| Demo: normal withdrawal (score 3, no pause) | Sepolia | — | `0x8d1e29b1cbdaaba82efff905a7422d9f763e6ba0b0cebb80883b110b9cf212ed` |
| Demo: drain burst 1 (trigger, 800 SENT) | Sepolia | — | `0x92377ecb89f9b43e53ce81a59282847534b976a1a859f6af1562768413700540` |
| Demo: drain burst 2 (800 SENT, before pause landed) | Sepolia | — | `0x043fdce2124a54eff5795ade8c7294290105ffbd5488c09d9390c0e7e0fce225` |
| Demo: drain bursts 3–5 | Sepolia | — | reverted — vault already paused (circuit breaker working) |
| Reactive tx (drain, score 9985) | Lasna | — | `0x3e9c86bf24c527af4c78ab3ee04e08ca903f517ee09996890dd816fd2fce5a8b` |
| Callback tx (pause, VaultPaused, block 12154292) | Sepolia | — | `0x6fa26e8e4a7d9e0261ffd4ea6c8246a43eb236899193ea1c75d0535f980ec3e0` |

Vault v3 after the demo: `paused() = true`, balance 50,390 SENT (52,000 − 10 − 800 − 800; bursts 3–5 reverted), ETH 0.04999999996941836 (0.05 minus ~3.06e-11 ETH callback-delivery fee). Reactscan RSC v3: status `active`, subscription listed.

Superseded deployments (kept for the record; do NOT use):
- v1 (Omni-only subscribe): token `0x2d4333f07e15f35D7597FA09D64f5Fef21195085`, vault `0x4017963dA1e3fd8D3D02cB0CfDb7b515F6BF28C9`, RSC `0xfB20d78FDFf8b633d68f6077B713c073de58BecD` — react() fired, legacy Callback emitted, callback NEVER delivered.
- v2 (Omni + legacy subscribe): token `0x186388852E8a123524eb5A97E604C6a57d5ecD38`, vault `0xA1F8F6FCB964a244256179Dd9138BfA23B22eCf0`, RSC `0xf12025C983534504e57E94cD2094F7904C5b1989` — react() fired once per transfer (no double delivery), legacy Callback emitted, callback NEVER delivered.

## Funding recap (testnet only)

| Side | Asset | Suggested | Purpose |
|---|---|---|---|
| RSC (Lasna) | lREACT | 10 (from 0.1 Sepolia ETH) | reactive-tx fees + reserves |
| Vault (Sepolia) | ETH | 0.05 | callback-delivery fees |
| RSC deploy | lREACT | 0.1 (constructor `--value`) | initial balance for `pay()` settlement |
