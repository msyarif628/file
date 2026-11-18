# Toolchain — Reactive Omni Buildathon (DoraHacks)

Set up 17 Nov 2026 in this VM. **No contracts for the hackathon are written here yet**
— only a placeholder (`contracts/HelloReactive.sol`) to prove the toolchain works.
Nothing has been deployed to any network and no wallet/account was created.

## What was installed (path (a) — Foundry, worked first try)

| Tool | Version | How |
|---|---|---|
| Foundry (`forge`, `cast`, `anvil`, `chisel`) | **1.9.0** (commit `6056c5845d`, built 2026-11-02) | `curl -L https://foundry.paradigm.xyz \| bash` then `foundryup` |
| forge-std (test/script library) | **v1.17.0** (`f3dae6e6`) | `forge install foundry-rs/forge-std` |
| solc (via Foundry) | **0.8.26** (pinned in `foundry.toml`) | auto-downloaded by `forge build` |
| node / npm | v24.22.1 / 10.9.4 | pre-installed in VM |
| git | 2.43.0 | pre-installed in VM |

Foundry lives in `~/.foundry/bin` — add it to PATH before use:

```bash
export PATH="$PATH:$HOME/.foundry/bin"
```

Fallback paths (b) npm `solc` and (c) pip `py-solc-x` were **not needed** and not
attempted — Foundry worked on the first try.

## Network reachability (17 Nov 2026, all OK)

- `curl -sI https://registry.npmjs.org` → HTTP 200
- `curl -sI https://github.com` → HTTP 200
- `curl -sI https://foundry.paradigm.xyz` → HTTP 301 (redirect to installer, expected)
- `npm ping` → PONG (791 ms)

## Project layout

```
reactive/
├── foundry.toml                 # solc 0.8.26, optimizer on, src=contracts
├── contracts/
│   └── HelloReactive.sol        # placeholder contract (to be replaced)
├── test/
│   └── HelloReactive.t.sol      # 2 forge-std tests
├── script/
│   └── Deploy.s.sol             # deploy script (simulation only, see below)
├── lib/
│   └── forge-std/               # v1.17.0
└── TOOLCHAIN.md                 # this file
```

Git repo initialized (`git init`, no remote yet — **nothing pushed**).

## Commands (run from this directory, with Foundry on PATH)

```bash
# Compile
forge build

# Test
forge test

# Test with traces / verbosity
forge test -vvv

# Simulate the deploy script locally (NO broadcast, NO network)
forge script script/Deploy.s.sol

# Deploy for real (ONLY with explicit approval + RPC URL + funded key):
# forge script script/Deploy.s.sol --rpc-url <RPC_URL> --broadcast --private-key <KEY>
```

## Verification results (17 Nov 2026)

- `forge build` → `Compiler run successful!` (Solc 0.8.26, 23 files, 1.21 s)
- `forge test` → **2 passed, 0 failed** (`testInitialGreeting`, `testSetGreeting`)
- `forge script script/Deploy.s.sol` (local simulation, no broadcast) →
  `Script ran successfully`, deployed to `0x7FA9385bE102ac3EAc297483Dd6233D62b3e1496`
  (local simulated address only — nothing on any chain)

## gh CLI

- `gh` is installed (`/usr/bin/gh`) but **NOT authenticated**
  (`gh auth status` → "You are not logged into any GitHub hosts").
  No login was attempted and nothing was pushed.

## Addendum — 2026-11-17 (build complete)

The placeholder is gone and the real contracts are built: see README.md.
`contracts/` now holds SentinelToken, SentinelVault, SentinelReactive,
AnomalyModel, ModelWeights (generated); `ml/train.py` trains the model;
`test/` holds 23 passing forge tests; `script/` holds DeploySepolia.s.sol,
DEPLOY.md and demo.sh. Nothing has been deployed to any network.
