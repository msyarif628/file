# DESIGN — "Sentinel": Reactive Vault Circuit Breaker with On-Chain Neural Anomaly Detection

> Track: **Reactive Meets AI** ($1,000 first place). Hackathon: Reactive Omni Buildathon, 5 Nov – 5 Dec 2026.
> Researcher: lovefratz (Muhammad Syarif). All API facts below come from
> `docs-research.md` (verified 2026-11-17 from dev.reactive.network / blog.reactive.network).
> Status: design only — no contracts written yet.

## 1. Concept (one paragraph)

A vault on Ethereum Sepolia holds demo ERC-20 tokens. A reactive contract on
Reactive Lasna subscribes to that token's `Transfer` events. For every
transfer **out of the vault**, it feeds four features into a tiny quantized
neural network (4→4→1 MLP) that runs **on-chain inside `react()`** — the model
decides, in the running system, whether the outflow pattern looks like a
drain. When the anomaly score crosses the threshold, the reactive contract
requests a cross-chain callback that **pauses the vault**, freezing further
withdrawals. No bot, no server: origin event → reactive inference → callback.
The model is trained off-chain in Python on synthetic normal-vs-drain data,
quantized to fixed-point integers, and exported as Solidity constants — the
repo contains the trainer, the dataset generator, and the weights, so anyone
can reproduce it.

## 2. Why this fits

- **Researcher's edge:** smart contract security / auditing. A drain detector
  + automatic circuit breaker is a security product, not a generic demo.
- **AI track rule (verified):** "the AI has to be part of the running system,
  not just the tool you used to write the code." Here the neural network IS
  the decision-maker inside `react()` — without it, no pause ever happens.
- **Execution criterion:** the full loop is demonstrable on testnets and
  produces the exact tx hashes judges require (Sepolia drain tx → Lasna
  reactive tx → Sepolia callback tx), with measurable full-loop latency.
- **Honest scope:** the model is a SMALL quantized MLP (4 inputs, 4 hidden,
  1 output). The README and video must say so — it is a proof that on-chain
  neural inference can drive a reactive security action, not a claim of a
  large model.

## 3. Architecture

```
Ethereum Sepolia (chain 11155111)                Reactive Lasna (chain 5318007)
┌─────────────────────────────┐                  ┌──────────────────────────────┐
│ SentinelToken (ERC-20 demo) │  Transfer events │ SentinelReactive             │
│ SentinelVault (holds tokens,│ ───────────────► │  (AbstractReactive)          │
│  pausable; AbstractCallback)│  via subscription│  - subscribes Transfer       │
│  - pause() via callback     │                  │  - tracks vault outflows     │
│  - unpause() owner-only     │  ◄───────────────│    (60s trailing window)     │
│  - withdraw() blocked while │   callback:      │  - AnomalyModel (4→4→1 MLP)  │
│    paused                   │   pause()        │  - score >= 7000 → callback  │
└─────────────────────────────┘                  └──────────────────────────────┘
```

### Contracts (all in `contracts/`)

1. **`SentinelToken.sol`** — minimal ERC-20 (OpenZeppelin or hand-rolled;
   prefer OpenZeppelin via `forge install OpenZeppelin/openzeppelin-contracts`
   if reachable, else a minimal self-contained ERC-20). Mintable by owner for
   demo funding. 18 decimals.
2. **`SentinelVault.sol`** — holds `SentinelToken`; `deposit(uint256)`,
   `withdraw(uint256)` (owner/any depositor; blocked while paused),
   `pause()` / `unpause()`. Inherits `AbstractCallback` from reactive-lib:
   constructor `(IPayable callbackProxy_, address callbackSender_)` where
   callbackProxy = Sepolia proxy
   `0xAa14d9Cd0f788Ca23d11805986C1d8bd035D23b4` and callbackSender = the
   deployed `SentinelReactive` address. `pause()` has TWO entry points: the
   callback entry `onAnomaly(address reactive_, uint256 score_)` guarded by
   BOTH `onlyServiceProvider` and `onlyCallbackSender(reactive_)`, and an
   owner-only `pause()` for manual override. Emits `VaultPaused(address
   indexed reactive, uint256 score, uint256 timestamp)` and
   `VaultUnpaused`. Must be payable-constructible (funding for callback fees).
3. **`SentinelReactive.sol`** — inherits `AbstractReactive`. Constructor
   `(uint256 originChainId_, address originContract_, uint256
   destinationChainId_, address vault_)` payable; subscribes in the
   constructor to `Transfer` topic0
   `0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef` on
   the origin chain/token. Owner-only `setRecipient(address)` (deploy vault
   after the RSC, then set recipient — the docs' deployment order).
   - **State (per vault outflow window, 60 s):** ring buffer of the last 8
     vault outflows `(timestamp, amount)`; `outflowCount`, `outflowSum`,
     `seenRecipients` mapping (for the new-recipient flag).
   - **`react(LogRecord)`** (`onlySystem`): ignore unless `topic0 ==
     TRANSFER_TOPIC0 && opCode == 3`; decode from=`topic1`, to=`topic2`,
     amount=`data`. Ignore unless `from == vault` (only vault outflows feed
     the model). Update the window (drop entries older than 60 s — use
     `log_.blockNumber`?? NO — use timestamps: the LogRecord has no
     timestamp; use `block.timestamp` on Lasna at react time, which is ~1 s
     after the Sepolia block; acceptable and documented). Compute features,
     run `AnomalyModel.score(...)`, emit `Scored(from, to, amount, score)`.
     If `score >= 7000` AND `!paused` (track a local `paused` flag set on
     callback request; reset by owner via `resetPauseFlag()` or by a
     `VaultUnpaused`-style callback — simplest: local flag + 10-minute
     cooldown `lastPauseRequestAt`) → `requestCallbackV_1_0` to
     `vault.onAnomaly(address(0) placeholder, score)` with gas limit
     1,000,000 (min callback gas is 100,000). Never revert as a filter.
   - `coverDebt()` public (exposes `_coverDebt()`).
4. **`AnomalyModel.sol`** — pure library: `function score(int256 f1, f2, f3,
   f4) returns (uint256)` — fixed-point (scale 1e4 or 1e6) 4→4→1 MLP with
   tanh-approximation on the hidden layer and sigmoid on the output; weights
   + biases as `int256` constants generated by `ml/train.py` (do NOT invent
   weights — they must come from the trainer). Output 0–10000 (basis points).
   Include the exact weight values the trainer exports.
5. **`ModelWeights.sol`** (generated) — constants only, produced by
   `ml/train.py` (script writes this file; check it in).

### Features (all computable from Transfer events alone)

- `f1` = log-scaled single transfer amount (log10, scaled to fixed point).
- `f2` = count of vault outflows in the trailing 60 s window (incl. this one).
- `f3` = log-scaled cumulative vault outflow in the trailing 60 s window.
- `f4` = 1 if `to` has never received from the vault before, else 0.

### Thresholds

- Anomaly threshold: score >= **7000** (70%). Cooldown between pause
  callbacks: **10 minutes**. Pause-request gas limit: **1,000,000**.

## 4. Off-chain ML (`ml/`)

- **`ml/train.py`** (stdlib + numpy only — check numpy availability first;
  if numpy is missing, pure-python implementation): generates a synthetic
  dataset (normal: small/regular withdrawals, known recipients, spaced
  out; drain: large amounts, rapid bursts, fresh recipients, near-full
  balance sweeps), trains the 4→4→1 MLP (plain gradient descent, ~a few
  hundred epochs), evaluates (accuracy + confusion matrix printed),
  quantizes weights to integers, writes `ml/weights.json` AND generates
  `contracts/ModelWeights.sol`.
- **`ml/vectors.json`** — 5+ reference test vectors (features → expected
  score) exported by the trainer; the forge test
  `test/AnomalyModel.t.sol` asserts the Solidity model matches them within
  a small tolerance (quantization error).

## 5. Tests (`test/`)

- `AnomalyModel.t.sol` — Solidity scores match `ml/vectors.json` (within
  tolerance); score is monotone in amount; output range 0–10000.
- `SentinelVault.t.sol` — deposit/withdraw, pause blocks withdraw, unpause
  restores, owner-only guards, callback auth (prank the Sepolia proxy
  address; wrong sender reverts; wrong reactive address reverts).
- `SentinelReactive.t.sol` — react() with a fabricated LogRecord (prank
  `msg.sender` = system contract `0x8888…8888`): normal transfer → no
  callback request recorded; drain pattern (several large rapid vault
  outflows) → callback requested (assert via a mocked SYSTEM — use
  `vm.etch` to place a mock at the system address that records
  `requestCallbackV_1_0` calls, since the real system contract has no code
  in tests; the constructor's `subscribe` call must not revert in tests —
  handle with the mock or `vm.etch` before deployment).
- All tests must pass with `forge test` before the build is called done.

## 6. Deployment (`script/`)

- `script/DeploySepolia.s.sol` — forge script: deploy token + vault
  (vault needs the RSC address — so deploy vault in TWO steps: first deploy
  token + vault with a placeholder callbackSender, OR deploy RSC first).
  **Order (docs §3.3):** (1) deploy RSC on Lasna with `cast send --create`
  (NOT forge script — constructor calls the subscribe precompile at `0x64`,
  which reverts in forge simulation); (2) deploy token + vault on Sepolia
  with `forge script` (vault constructor takes Sepolia proxy + RSC address);
  (3) `cast send` on Lasna: `setRecipient(vault)`; (4) fund: lREACT to the
  RSC (via `depositTo` on the system contract AND/OR direct transfer +
  `coverDebt()`), Sepolia ETH to the vault (for callback delivery fees).
  Provide `script/DEPLOY.md` with the exact commands (with `<PLACEHOLDERS>`
  for private key / RPCs — never commit a real key) and a
  `script/demo.sh` that drives the demo: fund vault, do a normal transfer
  (no pause), then a drain burst (pause), and prints the tx hashes.
- **Funding needs (user step):** Sepolia ETH (public faucet) → swap a little
  for lREACT via the faucet contract
  `0x9b9BB25f1A81078C544C829c5EB7822d747Cf434` (1 ETH → 100 lREACT, max 5
  ETH/tx). Suggested: 0.1 Sepolia ETH → 10 lREACT for the RSC; 0.05 Sepolia
  ETH to the vault for callback fees. All testnet, no real money.

## 7. Repo + submission package

- Repo: local git at `~/workspace/bugbounty-hunts/dorahacks/reactive/` —
  push to the researcher's GitHub (`msyarif628`) requires the user to
  authenticate `gh` / provide a remote (user step; builder must NOT invent
  credentials). README must include: what it is, architecture diagram,
  how to train the model, how to test, how to deploy (exact commands),
  deployed addresses + tx hashes (filled in after deployment), demo video
  link, and the honest scope note (tiny MLP; testnet only).
- Submission (DoraHacks page) needs a live browser + the researcher's
  DoraHacks session — the PARENT agent does this step; this build delivers
  the complete package (repo + addresses + tx hashes + video script).
- **Demo video script** (`docs/DEMO_SCRIPT.md`, < 3 min): 0:00–0:20 problem
  (vault drains happen in seconds); 0:20–0:50 architecture (event → Lasna
  inference → callback); 0:50–1:40 live demo (normal transfer: no pause;
  drain burst: vault pauses — show the three tx hashes + Reactscan);
  1:40–2:30 the model (tiny MLP, trained off-chain, runs on-chain) +
  latency numbers; 2:30–3:00 wrap-up + links. Voiceover is a user step.

## 8. If this concept fails (BIG rework, not a tweak)

If any load-bearing piece proves unworkable (e.g. reactive-lib won't compile
under Foundry, the Lasna subscription never fires in practice, or the
callback auth model differs from the docs), do NOT iterate the dead idea:
pivot the whole concept to **Concept B — "Cross-chain stop-loss" (Every
Second Counts, $2,000)**: RSC on Lasna subscribes to Uniswap v3/v4 `Swap`
events on Unichain Sepolia, tracks a TWAP-ish price move, and callbacks a
stop-loss executor on Unichain Sepolia. Report the pivot explicitly.
