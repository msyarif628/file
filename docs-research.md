# Reactive Network (Omni) — RSC API Reference for the DoraHacks Buildathon

> Research date: **2026-11-17**. All facts below come from pages fetched on that date
> (official docs at `dev.reactive.network`, official blog at `blog.reactive.network`,
> GitHub). Every address, chain ID, signature and topic hash carries its source URL.
> Anything I could not verify from a fetched page is marked **UNVERIFIED**.

## 0. TL;DR — the model

- Reactive contracts are ordinary Solidity contracts deployed **once, on Reactive
  Network itself** (mainnet chain ID **1597**, Lasna testnet **5318007**). They
  subscribe to event logs on origin chains; when a matching log appears the
  system contract calls `react()`; `react()` can request a cross-chain callback
  to a destination chain. No off-chain bot, no dual deployment.
- Omni (CometBFT, ~1s blocks, instant finality) removed the old RVM
  dual-deployment model: "No more RVM. Reactive contracts no longer require
  dual deployments across RVM and Reactive Network. Everything deploys to a
  single environment, the way standard smart contracts do."
  — https://blog.reactive.network/reactives-next-chapter-starts-testnet-launch-team-news/
- System contract (same on mainnet and Lasna):
  `0x8888888888888888888888888888888888888888`
  — https://dev.reactive.network/reactive-mainnet

---

## 1. Development flow (Omni) + minimal complete example

### 1.1 Base contracts and imports

Source: https://dev.reactive.network/reactive-contracts

- **Inherit `AbstractReactive`.** It supplies `SYSTEM`, `REACTIVE_IGNORE`,
  `onlySystem`, and brings `AbstractPayer` with it.
- **`IReactive`** is needed for the `/// @inheritdoc IReactive` tag (and it
  defines `LogRecord`).
- **`ISystemContract`** is needed when you name the callback configuration
  struct (`CallbackConfiguration_V_1_0`).
- Import paths (verbatim from the docs):

```solidity
// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.29;

import { ISystemContract } from "@reactive/src/interfaces/ISystemContract.sol";
import { IReactive } from "@reactive/src/interfaces/IReactive.sol";
import { AbstractReactive } from "@reactive/src/base/AbstractReactive.sol";
```

- The library is the official `reactive-lib` repo:
  https://github.com/Reactive-Network/reactive-lib
  (install seen in the wild as `forge install Reactive-Network/reactive-lib`;
  the docs themselves only give the `@reactive/...` import paths — **the exact
  `forge install` command is UNVERIFIED from docs**; confirm against the
  repo README before use.)
- Callback-side base: `AbstractCallback` +
  `IPayable` — imports `@reactive/src/base/AbstractCallback.sol` and
  `@reactive/src/interfaces/IPayable.sol`.
  Source: https://dev.reactive.network/callback-contracts
- **A contract cannot be both reactive and callback**: `AbstractPayer` holds a
  single immutable `_SERVICE_PROVIDER`; `AbstractReactive` hardcodes it to
  `SYSTEM` while `AbstractCallback` sets it to the proxy, so inheriting both
  won't compile. (Same source.)

### 1.2 Minimal complete example (subscribe + react + callback)

Adapted verbatim from the two official docs pages
(https://dev.reactive.network/reactive-contracts and
https://dev.reactive.network/callback-contracts). The only additions are the
`owner` + `setRecipient` setter, which the docs' "Deployment Order" section
requires (see §3.3), and the ERC-20 `Transfer` decoding, which follows the
docs' own `LogRecord` decoding example.

**Reactive contract (deploy on Lasna, chain 5318007):**

```solidity
// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.29;

import { ISystemContract } from "@reactive/src/interfaces/ISystemContract.sol";
import { IReactive } from "@reactive/src/interfaces/IReactive.sol";
import { AbstractReactive } from "@reactive/src/base/AbstractReactive.sol";

contract TransferWatcher is AbstractReactive {
    // keccak256("Transfer(address,address,uint256)") — verified locally, see §2.3
    uint256 private constant TRANSFER_TOPIC0 =
        0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef;

    uint256 private immutable _originChainId;
    address private immutable _originContract;
    address public recipient;          // destination callback contract
    uint256 public destinationChainId;
    address public owner;

    uint64 private constant CALLBACK_GAS_LIMIT = 1_000_000; // docs example value

    // `payable` so the contract can be funded at deployment.
    constructor(uint256 originChainId_, address originContract_, uint256 destinationChainId_)
        payable
    {
        _originChainId = originChainId_;
        _originContract = originContract_;
        destinationChainId = destinationChainId_;
        owner = msg.sender;

        SYSTEM.subscribe(
            originChainId_,
            originContract_,
            TRANSFER_TOPIC0,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE
        );
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    // Docs deployment order: deploy RSC first, then the callback contract,
    // then set the recipient here via an owner-only setter.
    function setRecipient(address recipient_) external onlyOwner {
        recipient = recipient_;
    }

    /// @inheritdoc IReactive
    function react(LogRecord memory log_) external onlySystem {
        // ERC-20 Transfer(address indexed from, address indexed to, uint256 value):
        // 3 topics (LOG3); from = topic1, to = topic2, value in data.
        if (log_.topic0 == TRANSFER_TOPIC0 && log_.opCode == 3) {
            address from = address(uint160(log_.topic1));
            address to = address(uint160(log_.topic2));
            uint256 amount = abi.decode(log_.data, (uint256));
            // ... your logic here (thresholds, dedup, etc.) ...
            _requestCallback(from, to, amount);
        }
    }

    function _requestCallback(address from_, address to_, uint256 amount_) internal {
        bytes memory payload = abi.encodeWithSignature(
            "onTransfer(address,address,address,uint256)",
            address(0), // placeholder: network overwrites with THIS contract's address
            from_,
            to_,
            amount_
        );
        SYSTEM.requestCallbackV_1_0(ISystemContract.CallbackConfiguration_V_1_0({
            chainId: destinationChainId,
            recipient: recipient,
            gasLimit: CALLBACK_GAS_LIMIT,
            payload: payload
        }));
    }

    /// @notice Settles outstanding debt from this contract's own balance.
    function coverDebt() external {
        _coverDebt();
    }
}
```

**Callback contract (deploy on the destination chain):**

```solidity
// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.29;

import { IPayable } from "@reactive/src/interfaces/IPayable.sol";
import { AbstractCallback } from "@reactive/src/base/AbstractCallback.sol";

contract TransferReceiver is AbstractCallback {
    event Handled(address indexed reactive_, address from_, address to_, uint256 amount_);

    // `payable` so the contract can be funded at deployment.
    constructor(IPayable callbackProxy_, address callbackSender_)
        payable
        AbstractCallback(callbackProxy_, callbackSender_)
    {}

    function onTransfer(address reactive_, address from_, address to_, uint256 amount_)
        external
        onlyServiceProvider
        onlyCallbackSender(reactive_)
    {
        emit Handled(reactive_, from_, to_, amount_);
        // ... your destination-side logic here ...
    }

    /// @notice Settles outstanding debt from this contract's own balance.
    function coverDebt() external {
        _coverDebt();
    }
}
```

### 1.3 Deployment gotchas (verified)

- **Do NOT deploy the RSC with `forge script`.** Its constructor calls
  Reactive's `subscribe` precompile (at `0x64`), which reverts in Forge's
  local execution/simulation — the precompile only exists on real Reactive
  nodes. Deploy with `cast send --create` instead, so the constructor runs
  only on-chain. (Lambda runbook, confirmed against live Lasna behavior:
  https://github.com/jeevan-sparkout/lambda-protocol/blob/HEAD/DEPLOY_TESTNET.md
  — note: this is a third-party project runbook, not official docs, but it
  documents a real failure mode; EvenFlow's README repeats the same
  `cast send --create` instruction:
  https://github.com/Hebx/EvenFlow)
- Verify with Sourcify: `forge verify-contract --verifier sourcify
  --chain-id 5318007 <addr> <ContractName>` (Lasna) / `1597` (mainnet).
  Source: https://dev.reactive.network/reactive-contracts
- Standard tooling works out of the box on Omni (Hardhat, Foundry, Remix,
  `cast`); no custom RPC methods needed.
  Source: https://blog.reactive.network/reactives-next-chapter-starts-testnet-launch-team-news/

---

## 2. subscribe()

Source: https://dev.reactive.network/reactive-contracts

### 2.1 Signature

```solidity
function subscribe(
    uint256 chainId_,
    address contract_,
    uint256 topic0_,
    uint256 topic1_,
    uint256 topic2_,
    uint256 topic3_
) external;

function unsubscribe(
    uint256 chainId_,
    address contract_,
    uint256 topic0_,
    uint256 topic1_,
    uint256 topic2_,
    uint256 topic3_
) external;
```

- Called on `SYSTEM` (the system contract at
  `0x8888888888888888888888888888888888888888`).
- `topic0` is normally the event signature hash; topics 1–3 hold indexed
  parameters. Any position can be left open with the wildcard `REACTIVE_IGNORE`.
- Wildcards: `chainId_ = 0` matches any chain; `contract_ = address(0)`
  matches any contract on the chain; any topic position = `REACTIVE_IGNORE`
  matches any value.
- **At least one criterion must be specific** — subscribing to every event on
  every contract on every chain is not allowed.
- Criteria match by **equality only** (no ranges/comparisons). One criteria set
  per subscription — no `OR` within a subscription; call `subscribe()` once per
  combination. Duplicates are allowed but pointless (you pay gas for both).
- Subscriptions live in the node, not in contract storage — you cannot read
  your own back on-chain; track them yourself.
- Subscribing is not limited to the constructor: a contract can
  subscribe/unsubscribe at any point, including from inside `react()`.
  `unsubscribe()` removes a subscription matching **all six arguments
  exactly** — any drift leaves the subscription in place and fails silently.
  Wrap both calls in internal helpers with identical arguments.
- A contract in debt receives nothing — settle up (e.g. `_coverDebt()`)
  before resubscribing.

### 2.2 Supported origin/destination chains on Lasna testnet

Source: https://dev.reactive.network/origins-and-destinations (fetched 2026-11-17)

**Rule: mainnets and testnets must not be mixed.** If the origin is a testnet,
the destination must also be a testnet.

| Chain | Origin / Destination | Chain ID | Callback proxy | RPC |
|---|---|---|---|---|
| Base Sepolia | ✅ | 84532 | `0x476F44b11F5C942c58f4c8E3d0300E5710743585` | Chainlist |
| Ethereum Sepolia | ✅ | 11155111 | `0xAa14d9Cd0f788Ca23d11805986C1d8bd035D23b4` | Chainlist |
| Reactive Lasna | ✅ | 5318007 | `0x8888888888888888888888888888888888888888` | https://lasna-rpc.rnk.dev/ |
| Unichain Sepolia | ✅ | 1301 | `0x775c9B990ADe401060B78D0e98684eEf8d2466C1` | Chainlist |

Mainnet chains (for reference only — do not mix with testnet): Arbitrum 42161,
Avalanche 43114, Base 8453, BSC 56, Ethereum 1, HyperEVM 999, Reactive 1597,
Robinhood 4663, Unichain 130.

> ⚠️ **Proxy-address conflict (flagged, not resolved):** the Lambda runbook
> (May 2026) gives the Unichain Sepolia callback proxy as
> `0x9299472A6399Fd1027ebF067571Eb3e3D7837FC4`, while the current docs table
> above gives `0x775c9B990ADe401060B78D0e98684eEf8d2466C1`. **Trust the docs
> table fetched 2026-11-17**, but verify on-chain (read the proxy / check
> Reactscan) before hardcoding — proxies may have been redeployed since May.
> Sources: https://dev.reactive.network/origins-and-destinations vs
> https://github.com/jeevan-sparkout/lambda-protocol/blob/HEAD/DEPLOY_TESTNET.md

> ⚠️ **HyperEVM testnet (998) is NOT a Lasna destination.** Lasna can deliver
> callbacks to Ethereum Sepolia, Base Sepolia, Unichain Sepolia and Lasna
> itself, but not HyperEVM testnet. HyperEVM is a destination only on mainnet
> (999). (Lambda runbook, citing the same docs page; consistent with the
> testnet table above, which lists no HyperEVM testnet row.)

### 2.3 Subscribing to an ERC-20 Transfer

- Event: `Transfer(address indexed from, address indexed to, uint256 value)`.
- `topic0 = keccak256("Transfer(address,address,uint256)")` =
  **`0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef`**
  — computed locally with keccak-256 during this research (not copied from
  memory); the standard ERC-20 Transfer topic hash. The docs confirm the
  decoding shape: "An ERC-20 `Transfer(address indexed from, address indexed
  to, uint256 value)` is the familiar case: three topics, both addresses
  already in the record, and only the amount left in `data`."
  Source: https://dev.reactive.network/reactive-contracts
- In `react()`: `topic1` = `from`, `topic2` = `to` (each as `uint256`
  holding a 160-bit address — cast with `address(uint160(...))`),
  `abi.decode(log_.data, (uint256))` = `value`. Check `log_.opCode == 3`
  (LOG3) before decoding. A zero in a topic position does **not** prove the
  log had fewer topics (a mint emits `Transfer` with `from == address(0)`);
  `opCode` is the reliable topic count.
- For reference: `Approval(address,address,uint256)` topic0 =
  `0x8c5be1e5ebec7d5bd14f71427d1e84f3dd0314c0f7b2291e5b200ac8c7c3b925`
  (also computed locally with keccak-256; **UNVERIFIED against docs**).

### 2.4 LogRecord struct (what react() receives)

Source: https://dev.reactive.network/reactive-contracts

```solidity
struct LogRecord {
    uint256 chainId;
    address contractAddress;
    uint256 topic0;
    uint256 topic1;
    uint256 topic2;
    uint256 topic3;
    bytes data;
    uint256 blockNumber;
    uint256 opCode;
    uint256 blockHash;
    uint256 txHash;
    uint256 logIndex;
}
```

- `data` holds the ABI-encoded **non-indexed** parameters only.
- `opCode` = how many topics the original log had (LOG3 → `3`).
- `blockHash` and `txHash` are `uint256`, not `bytes32` — cast before comparing.
- With more than one subscription, route on `topic0` first.
- Logs that don't match should fall through silently — **do not revert as a
  filter**: the system contract catches the revert, emits
  `ReactiveContractReverted`, and still bills you for the gas burned.

---

## 3. react() and callbacks

Sources: https://dev.reactive.network/reactive-contracts,
https://dev.reactive.network/callback-contracts,
https://dev.reactive.network/economy

### 3.1 How react() is invoked

- When a matching log appears on an origin chain, the system contract calls
  `react(LogRecord)` on the RSC. Signature (from docs):
  `function react(LogRecord memory log_) external onlySystem`.
- `onlySystem` checks `msg.sender` against the service provider — `SYSTEM`
  at `0x8888888888888888888888888888888888888888` — and reverts with
  `NotAuthorized` for anyone else. **Without it, anyone can hand your
  contract a fabricated log record.**
- `react()` is a normal transaction on Reactive Network, not a restricted
  callback context: it can do anything an ordinary function can, including
  subscribing, unsubscribing, and requesting callbacks.
- Every reactive transaction runs through the system contract's `trigger()`
  (6 steps): debt check first (before any gas is spent — an indebted contract
  goes quiet rather than failing loudly), then execution, then the charge
  (from gas actually consumed). A reverting `react()` is caught, logged as
  `ReactiveContractReverted`, and **charged in full**.
- **Max gas for a reactive transaction: 900,000.**

### 3.2 Requesting a callback (Omni / current API)

```solidity
enum CallbackVersion { V_1_0 }

function requestCallback(CallbackVersion version_, bytes memory config_) external;
function requestCallbackV_1_0(CallbackConfiguration_V_1_0 memory config_) external;

struct CallbackConfiguration_V_1_0 {
    uint256 chainId;    // destination network
    address recipient;  // target contract on the destination chain
    uint64 gasLimit;    // execution gas limit
    bytes payload;      // ABI-encoded function call
}
```

- **Use `requestCallbackV_1_0()`** — it takes the struct directly, no manual
  encoding or version flag. `requestCallback()` is the generic entry point
  (reverts with `InvalidCallbackVersion` on unknown versions). V_1_0 is the
  only version today.
- Either call causes the system contract to emit `CallbackRequest(chainId,
  sender, recipient, version, configuration)` (first three fields indexed),
  which the network picks up to submit the destination transaction.
- **The old `emit Callback(...)` event still works but is deprecated.**
  (Do not copy it from pre-Omni examples/blog posts — Lambda and EvenFlow blog
  posts show the old style; the current docs prescribe `requestCallbackV_1_0`.)
- Requesting a callback does not require an incoming event — it is an ordinary
  call on `SYSTEM`, so a plain external method can do it too, though most
  requests come from inside `react()`.
- **Minimum callback gas limit: 100,000 gas.** Requests below it are ignored.
  The proxy reserves overhead for its own accounting (`_extraGas`) and for
  settling payment (`_maxChargeGas`) — **not all requested gas reaches the
  target**. Size limits with both deductions in mind; too little fails with
  `InsufficientGas` before your method runs.
- A callback can target Reactive Network itself (`chainId: block.chainid`,
  `recipient: address(this)`) to run work in a fresh transaction. The
  receiving method still needs the guards in §3.3.

### 3.3 Who the destination sees as msg.sender, and how to authorize

- **The destination contract's `msg.sender` is the destination chain's
  callback proxy** (see table in §2.2), NOT the RSC address and NOT the system
  contract. "Callbacks are delivered by Reactive Signer, which posts
  transactions to destination chains. These transactions pass through a
  callback proxy contract… A destination contract can validate a callback by
  checking that `msg.sender` is the relevant callback proxy and the original
  sender from Reactive Network is Reactive Signer."
  Source: https://dev.reactive.network/origins-and-destinations
- **The RSC's identity arrives inside the payload**: "Reactive Network
  replaces the first 160 bits of the payload with the address of the reactive
  contract that requested the callback, so the destination can authenticate
  the sender. Your payload has to declare an `address` there and pass
  `address(0)` as a placeholder… Forgetting it is the most common way to
  break a callback." Source: https://dev.reactive.network/reactive-contracts
- **Authorize with BOTH modifiers, always** (from `AbstractCallback`):
  - `onlyServiceProvider` — caller must be the callback proxy. Without it,
    anyone can call your callback directly and pass any address as the first
    argument, defeating the second check.
  - `onlyCallbackSender(reactive_)` — the injected first-argument address
    must equal the authorized RSC (`_CALLBACK_SENDER`, immutable, set in the
    constructor). Without it, any reactive contract on the network can drive
    your callback through the legitimate proxy.
  - "Together they establish that the call came through the network and
    originated from the contract you trust. Use both, always."
    Source: https://dev.reactive.network/callback-contracts
- The proxy checks the target holds code before calling, reverting with
  `NotAContract` otherwise; a callback to an EOA is never charged.
- **Deployment order** (breaks the address chicken-and-egg, since
  `_CALLBACK_SENDER` is immutable):
  1. Deploy the reactive contract.
  2. Deploy the callback contract, passing the callback proxy address and the
     reactive contract's address.
  3. Set the recipient on the reactive contract through an owner-only setter.
  4. Fund both (see §3.4).
  Getting `callbackSender_` wrong is unrecoverable — redeploy.
  Source: https://dev.reactive.network/callback-contracts

### 3.4 Gas and funding — who pays, how much, minimums

Source: https://dev.reactive.network/economy

- **Two separate bills, two separate currencies, both sides must stay funded:**
  - RSC side (on Reactive): the system contract charges the RSC for executing
    `react()`, paid in **REACT / lREACT**.
  - Callback side (on the destination chain): the callback proxy charges the
    **recipient** contract for delivering the callback, in **that chain's
    native token** (ETH on Ethereum Sepolia, etc.) — **never REACT, and never
    billed to the requesting RSC**.
- **Any debt blocks execution.** Execution stops whenever debt > 0. The system
  contract won't call `react()` and the proxy won't deliver a callback while
  any amount is outstanding. Status is visible on Reactscan (`active` /
  `inactive`); a `BlacklistContract` event is emitted when debt rises above
  zero, `WhitelistContract` when it clears.
- Fee formula (same on both sides): `fee = p_base · C · (g_used + K)`, where
  `p_base` = max(`tx.gasprice`, `block.basefee`), `C` = pricing coefficient
  (`_gasPriceCoeffPer1000` / 1000), `g_used` = gas consumed, `K` = fixed
  surcharge (`_extraGas`). On Reactive the system contract initializes the
  coefficient to **1000**, the surcharge to **100,000 gas**, and the payment
  gas budget (`_maxChargeGas`) to **50,000** — but the owner can change them,
  so query them with `cast call` rather than relying on defaults. Each
  callback proxy is configured at deployment with no defaults — read values
  from the proxy itself.
- **A reverting `react()` and a failing callback are both charged in full**
  (logged as `ReactiveContractReverted` / `CallbackFailure`). No refunds. A
  contract that reverts on every notification will still exhaust its funds.
  Exception: a callback to an address holding no code is rejected before any
  charge.
- **Funding routes:**
  - `depositTo(address)` on the system contract / callback proxy — credits
    reserves held by the system contract/proxy; settles outstanding debt
    first, then adds the remainder to reserves. Always pass the target
    contract: sending REACT directly to the system contract credits the
    sender's own address, not the contract.
    `cast send $SYSTEM_CONTRACT_ADDR "depositTo(address)" $REACTIVE_CONTRACT_ADDR --value 1ether`
  - Direct transfer to the contract raises its own balance — but a balance
    settles nothing on its own. When a fee is charged and reserves are empty,
    the system contract calls `pay()` on the contract (implemented by
    `AbstractPayer`, inherited via `AbstractReactive`/`AbstractCallback`),
    asking for its entire outstanding debt; settlement happens inside the same
    transaction. The `pay()` call is capped at `_maxChargeGas` — keep custom
    payment logic minimal.
  - Or expose `_coverDebt()` publicly as `coverDebt()` (see example in §1.2)
    and call it manually after funding the contract directly.
  - Funding at deployment works only if the contract declares a **payable
    constructor** (the base contracts don't, so `--value` on deployment
    reverts otherwise).
- **No documented minimum funding amount** in the docs fetched — the Reactor
  blog post (older, pre-Omni) mentions recommended values of 0.03 ETH for a
  destination contract and 0.05 REACT for a reactive contract, but that is a
  no-code-tool recommendation, **not a protocol minimum — treat as
  UNVERIFIED for Omni**. Practical approach: fund with a few lREACT / a
  little Sepolia ETH, watch `debt()` / `reserves()` and Reactscan status, top
  up before it runs dry.
- **Balance queries** (`cast`):
  - `cast balance $REACTIVE_CONTRACT_ADDR --rpc-url $REACTIVE_RPC`
  - `cast call $SYSTEM_CONTRACT_ADDR "debt(address)" $ADDR --rpc-url $REACTIVE_RPC`
  - `cast call $SYSTEM_CONTRACT_ADDR "reserves(address)" $ADDR --rpc-url $REACTIVE_RPC`
  - Same three reads against the callback proxy on the destination RPC for
    callback contracts. (`debts(address)` is a kept-for-compatibility alias;
    new integrations should use `debt(address)`.)
- **Inspecting delivered callbacks:**
  `cast call $SYSTEM_CONTRACT_ADDR "getCallbacks(uint256)((uint256,address,uint256,uint256,uint256,bytes)[])" $REACTIVE_TX_HASH --rpc-url $REACTIVE_RPC`
  — returns block number, requesting RSC, callback index, destination chain
  ID, destination tx hash, and error data (`err` empty = success). Validators
  write these records after delivery, so an empty array means "not recorded
  yet", not "failed".

---

## 4. CRON topics (periodic ticks)

Source: https://dev.reactive.network/reactive-contracts

- The **legacy** system contract at
  `0x0000000000000000000000000000000000fffFfF` emits `Cron` events at fixed
  block intervals. Only authorized validator root addresses can call its
  `cron()` method, so these events come from the network itself.
- Subscribe with `chainId = block.chainid`, `contract = 0x0000…fffFfF`
  (the legacy address — NOT the `0x8888…` system contract), `topic0` = the
  value below, topics 1–3 = `REACTIVE_IGNORE`.

| Event | Interval | Approx. time | Topic 0 |
|---|---|---|---|
| `Cron1` | Every block | ~1 second | `0xf02d6ea5c22a71cffe930a4523fcb4f129be6c804db50e4202fb4e0b07ccb514` |
| `Cron10` | Every 10 blocks | ~10 seconds | `0x04463f7c1651e6b9774d7f85c85bb94654e3c46ca79b0c16fb16d4183307b687` |
| `Cron100` | Every 100 blocks | ~2 minutes | `0xb49937fb8970e19fd46d48f7e3fb00d659deac0347f79cd7cb542f0fc1503c70` |
| `Cron1000` | Every 1000 blocks | ~17 minutes | `0xe20b31294d84c3661ddc8f423abb9c70310d0cf172aa2714ead78029b325e3f4` |
| `Cron10000` | Every 10,000 blocks | ~3 hours | `0xd214e1d84db704ed42d37f538ea9bf71e44ba28bc1cc088b2f5deca654677a56` |

- Each `Cron` event carries one parameter, `number` (the block it fired for),
  **not indexed** — it arrives in `log_.data` as a single `uint256`. Inside
  `react()` you can usually read `block.number` instead and ignore the payload.
- A block divisible by several intervals emits several events. A contract
  subscribed to both `Cron1` and `Cron10` gets **two separate reactive
  transactions on every tenth block, and pays for both**.
- **Cron subscriptions bill on every tick whether or not `react()` does
  anything.** Pick the longest interval that fits, and build in a way to
  switch it off (unsubscribe to pause, resubscribe to resume).
- Ticks arrive at the same `react()` as every other subscription — tell them
  apart by `topic0`.
- Example subscription (from docs):

```solidity
address internal constant LEGACY_SYSTEM_ADDR = 0x0000000000000000000000000000000000fffFfF;
uint256 internal constant CRON100_TOPIC_0 = 0xb49937fb8970e19fd46d48f7e3fb00d659deac0347f79cd7cb542f0fc1503c70;

function _subscribeToCron() internal {
    SYSTEM.subscribe(
        block.chainid,
        LEGACY_SYSTEM_ADDR,
        CRON100_TOPIC_0,
        REACTIVE_IGNORE,
        REACTIVE_IGNORE,
        REACTIVE_IGNORE
    );
}
```

- **UNVERIFIED / open question:** the docs describe CRON as emitted by the
  *legacy* system contract. Whether the legacy `0x0000…fffFfF` emitter still
  fires on Omni Lasna exactly as documented was not independently confirmed
  from a fetched page — EvenFlow (live on Lasna, 2026) demonstrably uses a
  Reactive CRON drip, so it works in practice, but confirm the topic hash
  against a live tick / Reactscan before relying on it in the build.

---

## 5. Lasna testnet connection details

Source: https://dev.reactive.network/reactive-mainnet (fetched 2026-11-17)

| Parameter | Value |
|---|---|
| Network name | Reactive Lasna |
| RPC URL (current docs) | **https://lasna-rpc.rnk.dev/** |
| Chain ID | **5318007** |
| Currency symbol | **lREACT** |
| Block explorer | **https://lasna.reactscan.net/** |
| System contract | `0x8888888888888888888888888888888888888888` |
| Mainnet (reference) | RPC https://mainnet-rpc.rnk.dev/, chain ID 1597, REACT, https://reactscan.net/ |

### 5.1 RPC URL — which one is current?

- **Current docs (fetched 2026-11-17) say `https://lasna-rpc.rnk.dev/`** — on
  the network page, the origins/destinations table, the RNK RPC methods page
  (all `curl` examples), and the Sourcify verify example.
- The May 2026 Omni launch blog post gave **`https://lasna-omni-rpc.rnk.dev`**
  (explorer `https://lasna-omni.reactscan.net`):
  https://blog.reactive.network/reactives-next-chapter-starts-testnet-launch-team-news/
- **Verdict: use `https://lasna-rpc.rnk.dev/`** (current docs). The `-omni-`
  host was the Omni-launch-era endpoint; it may still resolve, but it is no
  longer what the docs publish. If `lasna-rpc` fails, try the `-omni-` host as
  a fallback — **UNVERIFIED whether the omni host still serves traffic**.

### 5.2 Faucet — how to get lREACT (verified current)

Source: https://dev.reactive.network/reactive-mainnet

There is no web-form faucet. You **send Sepolia ETH to a faucet contract**,
which sends lREACT back to the sender:

- **Ethereum Sepolia faucet:** `0x9b9BB25f1A81078C544C829c5EB7822d747Cf434`
  ✅ — matches the address in the task brief; still current in docs.
- **Base Sepolia faucet:** `0x2afaFD298b23b62760711756088F75B7409f5967`
- **Exchange rate: 1 ETH → 100 lREACT.**
- **Do NOT send more than 5 ETH per transaction.** Max sent 5 ETH, max
  received 500 lREACT. Amounts above 5 ETH are lost and will not generate
  additional lREACT.
- Transfers can be made with MetaMask or any Ethereum-compatible wallet.
- Alternative terminal form — call `request(address)` on the faucet contract:

```
cast send 0x9b9BB25f1A81078C544C829c5EB7822d747Cf434 \
  --rpc-url $ETHEREUM_SEPOLIA_RPC --private-key $ETHEREUM_SEPOLIA_PRIVATE_KEY \
  "request(address)" $WALLET_ADDR --value 0.1ether
```

```
cast send 0x2afaFD298b23b62760711756088F75B7409f5967 \
  --rpc-url $BASE_SEPOLIA_RPC --private-key $BASE_SEPOLIA_PRIVATE_KEY \
  "request(address)" $WALLET_ADDR --value 0.1ether
```

- **Sepolia ETH itself:** the docs do not name a Sepolia ETH faucet. You need
  Sepolia ETH first (from a public Sepolia faucet) before you can mint lREACT.
  Which Sepolia faucet to use is **UNVERIFIED from Reactive docs** — use any
  standard public Sepolia faucet; this is outside Reactive's docs.

---

## 6. Buildathon gotchas

Source: https://blog.reactive.network/reactive-omni-buildathon-thirty-days-to-find-out-what-one-second-buys/
(published 2026-11-04; buildathon 5 Nov – 5 Dec 2026, $5,500 in prizes paid in
REACT; registration/submission via DoraHacks)

- **Tracks:** (1) Every Second Counts — DeFi where reaction time matters,
  built on **Unichain Sepolia, Base Sepolia, or both**, with Lasna in the
  middle ($2,000 first / $250 runner-up). (2) Set It and Forget It — personal
  automations, any supported chain ($2,000 / $250). (3) Reactive Meets AI —
  a neural network must be part of the *running system*, not just the tool
  used to write the code ($1,000 first).
- **"Every Second Counts runs on Lasna testnet. The other two tracks can use
  Reactive mainnet or Lasna."**
- **Submission must include:** link to a public repo, deployed contract
  addresses, a few transaction hashes showing the full loop from origin event
  to callback, and a demo video under three minutes.
- **Repos must be public and open-source by submission time.** Everything
  should be built during the event; prior work can be a dependency, not the
  submission.
- **Judging (1–5 on four equally weighted criteria):** Execution (does it run
  — reactive txs and the callbacks they trigger on-chain; entries without
  them aren't scored further), Integration (does the reactive contract do real
  work, or is it bolted on?), Usefulness, Craft (readable code, working demo,
  docs someone else could follow). Judged by the Reactive team.
- **Testnet↔testnet pairing rule:** mainnets and testnets must not be mixed —
  testnet origin ⇒ testnet destination (see §2.2).
- **Base Sepolia 200ms blocks — use timestamps, not block counts:** "On Base
  Sepolia, use timestamps rather than block counts for timers, cooldowns, or
  deadlines. Blocks now arrive every 200ms, so block-based timers run ten
  times faster than they used to." Unichain Sepolia produces 1s blocks; Base
  Sepolia 200ms blocks since its Denim upgrade. Lasna/Omni: ~1s blocks,
  instant finality (no confirmation waiting).
- **Latency is the point of Track 1:** "The strongest entries will show their
  latency numbers measured across the full loop, not just one leg of it."
- **Reactive Omni mainnet has been live since 28 Oct 2026** (buildathon post).

---

## 7. Example projects (origin event → callback loops)

1. **Lambda** — https://github.com/Hijanhv/lambda-protocol
   Uniswap v4 hook on Unichain Sepolia emits `HedgeRequested` when LP delta
   drifts; `LambdaReactive` on Lasna subscribes, checks a per-pool nonce
   (drops replays/stale), and callbacks a hedge receiver (stand-in on Unichain
   Sepolia for testnet; real Hyperliquid perp on mainnet). UHI9 winner (Uniswap
   $1,000 + Reactive $1,500). Includes a full testnet deploy runbook
   (`DEPLOY_TESTNET.md`) with the `cast send --create` gotcha and the Lasna
   topology constraints. Blog walkthrough:
   https://blog.reactive.network/lambda-keeping-a-hedge-in-sync-across-chains/
   ⚠️ Note: its code uses the **deprecated `emit Callback(...)`** style — use
   it as an architecture reference, not as API reference.

2. **EvenFlow** — https://github.com/Hebx/EvenFlow
   Uniswap v4 hook that captures a directional-toxicity premium into a reserve
   and drips it back to in-range LPs; a Reactive CRON subscription on Lasna
   fires the drip cross-chain to Base Sepolia even when zero swaps happen
   (the "pool has no clock" problem). Live Base Sepolia ← Lasna drip tx is
   documented in the README. Blog walkthrough:
   https://blog.reactive.network/evenflow-the-problem-with-waiting-for-a-swap/
   ⚠️ Same caveat: blog code shows the old `emit Callback(...)` style.

3. **Official demos repo** — https://github.com/Reactive-Network/reactive-smart-contract-demos
   Reactive's own demo collection: Basic Demo (origin event → callback
   lifecycle — start here), Uniswap V2 Stop Order (subscribes to `Sync`,
   callbacks a swap), Approval Magic (ERC-20 approval-triggered automation),
   CRON Demo (periodic system events). Docs demos index:
   https://dev.reactive.network/legacy/demos (listed under "legacy" in docs
   nav — **verify each demo against the current Omni API before copying**;
   the repo predates Omni and may use pre-Omni patterns).
   Supporting official repos: `reactive-lib`
   (https://github.com/Reactive-Network/reactive-lib) and
   `system-smart-contracts`
   (https://github.com/Reactive-Network/system-smart-contracts — **URL
   UNVERIFIED from a fetched page; it appears in a third-party repo listing
   only, do not rely on it without checking**).

---

## 8. Source list (all pages fetched 2026-11-17)

- https://dev.reactive.network/reactive-contracts — RSC dev flow, subscribe,
  react, callbacks, CRON, verification
- https://dev.reactive.network/callback-contracts — callback auth, funding,
  deployment order
- https://dev.reactive.network/economy — fee model, gas limits, funding,
  debt/reserves, balance queries
- https://dev.reactive.network/reactive-mainnet — Lasna/mainnet params, faucet
- https://dev.reactive.network/origins-and-destinations — origin/destination
  chains + callback proxies, testnet↔testnet rule
- https://dev.reactive.network/rnk-rpc-methods — `rnk_getFilters`,
  `rnk_getCallBackLogs`, `rnk_getBlockSequences` (useful for debugging)
- https://dev.reactive.network/reactscan — Reactscan: contract status
  active/inactive, subscriptions view
- https://blog.reactive.network/reactive-omni-buildathon-thirty-days-to-find-out-what-one-second-buys/
  — buildathon tracks, prizes, rules, gotchas
- https://blog.reactive.network/reactives-next-chapter-starts-testnet-launch-team-news/
  — Omni launch (May 2026): no more RVM, CometBFT ~1s blocks, original
  `lasna-omni-rpc.rnk.dev` endpoint
- https://blog.reactive.network/lambda-keeping-a-hedge-in-sync-across-chains/
  — Lambda walkthrough
- https://blog.reactive.network/evenflow-the-problem-with-waiting-for-a-swap/
  — EvenFlow walkthrough
- https://github.com/Hijanhv/lambda-protocol — Lambda repo + DEPLOY_TESTNET.md
- https://github.com/Hebx/EvenFlow — EvenFlow repo
- https://github.com/Reactive-Network/reactive-smart-contract-demos — official
  demos
- https://github.com/Reactive-Network/reactive-lib — official Solidity library
  (`@reactive/...` imports)

## 9. UNVERIFIED items (need a live check before building on them)

1. Whether `https://lasna-omni-rpc.rnk.dev` still serves traffic (docs now
   publish `https://lasna-rpc.rnk.dev/`).
2. Which Sepolia ETH faucet to use (Reactive docs don't name one).
3. The exact `forge install Reactive-Network/reactive-lib` command / remapping
   for `@reactive/...` imports (docs give only import paths).
4. Whether the legacy CRON emitter `0x0000…fffFfF` still fires on Omni Lasna
   exactly as documented (EvenFlow proves CRON works live, but the topic
   hashes should be confirmed against a live tick).
5. The Unichain Sepolia callback proxy conflict: docs table
   `0x775c9B990ADe401060B78D0e98684eEf8d2466C1` vs Lambda runbook
   `0x9299472A6399Fd1027ebF067571Eb3e3D7837FC4` — verify on-chain.
6. Any protocol minimum funding amount (none documented; the 0.05 REACT /
   0.03 ETH figures are from an old no-code-tool blog post, not the protocol).
7. `system-smart-contracts` repo URL (seen only in a third-party listing).
