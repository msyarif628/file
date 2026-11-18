# Sentinel — Demo Video Script (< 3 minutes)

> Target length: ~2:45. One continuous screen recording + voiceover.
> Record after deployment (addresses + tx hashes from `script/DEPLOY.md`).
> Show the terminal, Reactscan (Lasna), and Sepolia Etherscan — no slides
> except the architecture diagram in section 2 (README.md has it).

## 0:00–0:20 — The problem

**On screen:** a Sepolia Etherscan page showing rapid outgoing transfers
from a vault contract (or the terminal showing the vault balance dropping).

**Voiceover:** "Vault drains happen in seconds. By the time a human — or
an off-chain bot — notices, the money is gone. What if the chain itself
could notice, and pull the circuit breaker before the next withdrawal?"

## 0:20–0:50 — Architecture

**On screen:** the architecture diagram (README.md), then the three
contract files in the editor.

**Voiceover:** "Sentinel is a vault on Sepolia, watched by a reactive
contract on Reactive Lasna. Every transfer out of the vault is scored by
a tiny neural network that runs on-chain, inside the reactive contract.
If the score says 'drain', Lasna sends a cross-chain callback that pauses
the vault. No bot, no server — event, inference, callback."

## 0:50–1:40 — Live demo

**On screen:** terminal running `bash script/demo.sh`, then Reactscan and
Etherscan.

**Voiceover + actions:**
- "First, a normal withdrawal — ten tokens." (Run the script; show
  `paused: false`.)
- "Now a drain: five withdrawals of 800 tokens in seconds."
- "The first one already scores 9933 out of 10000. Watch the vault."
  (Show `paused: true` appearing in the poll.)
- "Three transactions, one loop: the Sepolia drain transaction, the
  Lasna reactive transaction" — (show it on Reactscan, on the RSC page)
  — "and the Sepolia callback that paused the vault." (Show the
  `onAnomaly` call on Etherscan.)
- Read the three hashes on screen; also paste them in the video
  description and the repo README.

**Timing note:** the callback takes seconds to land — the script polls
for up to 120 s. If it lands fast, the pause appears within the first
polls; do not cut the waiting out entirely, it proves the loop is live.

## 1:40–2:30 — The model

**On screen:** `ml/train.py` output, the confusion matrix, and
`contracts/AnomalyModel.sol` (the lookup tables + `score()`).

**Voiceover:** "The model is deliberately tiny — four inputs, four hidden
units, one output — trained off-chain on synthetic normal-versus-drain
data, then quantized to fixed-point integers and exported as Solidity
constants. On the held-out test set it scores 98.25% accuracy with
97.7% drain recall, and the Solidity model reproduces the Python model
exactly — zero difference on all eight reference vectors. Four features:
amount, burst count, cumulative outflow, and whether the recipient is new.
That's the whole model, and it is honest about being small."

**Latency numbers (fill in from the demo run):** "Full loop, drain
transaction to vault paused: ___ seconds." (Measure from the drain tx
timestamp to the callback tx timestamp; report the real number, not an
estimate.)

## 2:30–3:00 — Wrap-up + links

**On screen:** repo README, Reactscan RSC page, DoraHacks project page.

**Voiceover:** "Sentinel: a vault that defends itself, with the neural
network as part of the running system — not just a tool that wrote the
code. Testnet only, demo tokens only. Repo, addresses, and transaction
hashes are in the description. Built by lovefratz for the Reactive
Omni Buildathon, Reactive Meets AI track."

## Checklist before recording

- [ ] Contracts deployed (addresses in README + `script/DEPLOY.md` table).
- [ ] RSC funded (lREACT reserves) and `active` on Reactscan.
- [ ] Demo run once end-to-end (fresh vault state; unpause + reset the
      RSC pause flag with `resetPauseFlag()` before the recorded take).
- [ ] Three tx hashes noted: Sepolia drain tx, Lasna reactive tx,
      Sepolia callback tx.
- [ ] Full-loop latency measured from the two Sepolia tx timestamps.
- [ ] Voiceover recorded in one take if possible; keep it under 3:00.
