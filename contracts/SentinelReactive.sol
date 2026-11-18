// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {ISystemContract} from "@reactive/interfaces/ISystemContract.sol";
import {IReactive} from "@reactive/interfaces/IReactive.sol";
import {AbstractReactive} from "@reactive/abstract-base/AbstractReactive.sol";
import {AnomalyModel} from "./AnomalyModel.sol";

/// @title SentinelReactive — the reactive vault circuit breaker (Lasna).
/// @notice Subscribes to SentinelToken `Transfer` events on Ethereum Sepolia.
///         For every transfer OUT of the vault, it feeds four features into
///         a tiny quantized neural network that runs ON-CHAIN inside react()
///         (see AnomalyModel.sol). If the anomaly score crosses the threshold,
///         it requests a cross-chain callback that pauses the vault on Sepolia.
///         No bot, no server: origin event -> reactive inference -> callback.
///
/// @dev Reactive binding — READ THIS before "fixing" it:
///         Written against the PUBLISHED reactive-lib (v0.2.0, the only
///         version on GitHub). The current docs describe a newer Omni API
///         (base contract at `src/base/AbstractReactive.sol` under the
///         reactive-lib remapping, a `SYSTEM` constant at
///         0x8888..., `onlySystem`, `requestCallbackV_1_0`) that does not
///         exist in the published library — see README.md ("Deviation log").
///         What this contract uses instead, and why each piece is safe:
///           - Types/constants: `LogRecord` (snake_case fields in this lib
///             version), `REACTIVE_IGNORE`, `service` (the legacy system
///             contract 0x0000...fffFfF) and `AbstractPayer` come from the lib.
///           - Subscription: called on the OMNI system contract
///             0x8888... (the address the current docs publish; the 2026-10-28
///             migration post says "a new system contract now handles"
///             subscriptions, keeping the same signature). The lib's
///             `service.subscribe` is NOT used — the legacy service is
///             superseded for subscriptions on Omni.
///           - `react()` guard: `msg.sender` must be the Omni system
///             contract OR the legacy service. NOT the lib demo's `vmOnly`:
///             `vmOnly` is RVM-era (it keys off whether the legacy system
///             contract has code at 0xfffFfF); on Omni's single deployment
///             that flag cannot distinguish the caller and would brick
///             react() if Lasna hosts code at 0xfffFfF. The explicit
///             sender check is the `onlySystem` semantics from the docs.
///           - Callbacks: `emit Callback(...)` — the legacy event the
///             migration post (2026-10-28) confirms still works on Omni
///             ("Old-style callbacks still work"). The docs' preferred
///             `requestCallbackV_1_0` does not exist in the published lib.
///           - Debt: the constructor authorizes the Omni system contract in
///             AbstractPayer's sender ACL so its `pay()` settlement works,
///             and `coverDebtOmni()` settles debt owed to it. The inherited
///             `coverDebt()` still settles with the legacy vendor.
///         LIVE VERIFICATION STILL REQUIRED (see script/DEPLOY.md): after
///         deploying to Lasna, confirm on Reactscan that the subscription is
///         registered and that a test Transfer produces a reactive tx. If
///         react() never fires, the fallback is a one-line change: subscribe
///         via the legacy `service` as well.
///
///         Deployment: NEVER with `forge script` — the constructor calls a
///         system contract that only exists on real Reactive nodes. Use
///         `cast send --create` (see script/DEPLOY.md).
contract SentinelReactive is IReactive, AbstractReactive {
    // keccak256("Transfer(address,address,uint256)") — ERC-20 Transfer topic.
    uint256 private constant TRANSFER_TOPIC0 =
        0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef;

    /// @notice Omni system contract (Lasna + mainnet), per current docs.
    address payable private constant SYSTEM_OMNI = payable(0x8888888888888888888888888888888888888888);

    uint256 public constant ANOMALY_THRESHOLD = 7000; // 70% — pause at/above.
    uint256 public constant PAUSE_COOLDOWN = 10 minutes;
    uint256 public constant WINDOW_SECONDS = 60;
    uint256 public constant WINDOW_SIZE = 8;
    uint64 private constant CALLBACK_GAS_LIMIT = 1_000_000; // docs example value (>= 100_000 min).

    uint256 public immutable originChainId;
    address public immutable originContract; // SentinelToken on Sepolia.
    uint256 public immutable destinationChainId; // Sepolia: 11155111.
    address public immutable vault; // SentinelVault on Sepolia.

    address public recipient; // set after deploying the vault (docs order).
    address public owner;

    /// @notice Local pause latch: set when a pause callback is requested,
    ///         cleared by the owner via resetPauseFlag() once the vault is
    ///         unpaused (the RSC cannot see Sepolia state by itself).
    bool public paused;
    uint256 public lastPauseRequestAt;
    uint256 public callbacksRequested; // observability + tests.

    struct Outflow {
        uint256 timestamp;
        uint256 amount;
    }

    Outflow[8] private window; // ring buffer of the last 8 vault outflows.
    uint256 private windowNext; // next slot to overwrite.
    uint256 private windowTotal; // total outflows ever recorded.
    mapping(address => bool) public seenRecipients;

    event Scored(address indexed from, address indexed to, uint256 amount, uint256 score);
    event CallbackRequested(address indexed recipient, uint256 score, uint256 timestamp);
    event RecipientSet(address indexed recipient);
    event PauseFlagReset(uint256 timestamp);

    error NotOwner();
    error NotSystem();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    /// @dev The `onlySystem` semantics from the docs, adapted to the
    ///      published lib: only the Omni system contract (which calls
    ///      react() on Lasna) or the legacy service may deliver logs.
    modifier onlySystem() {
        if (msg.sender != SYSTEM_OMNI && msg.sender != address(service)) revert NotSystem();
        _;
    }

    /// @param originChainId_ Sepolia chain id (11155111).
    /// @param originContract_ SentinelToken address on Sepolia.
    /// @param destinationChainId_ Sepolia chain id (11155111).
    /// @param vault_ SentinelVault address on Sepolia.
    /// @dev Payable so the RSC can be funded at deployment (lREACT for
    ///      reactive-tx fees). Subscribes in the constructor, as the docs
    ///      require — hence `cast send --create`, never `forge script`.
    constructor(uint256 originChainId_, address originContract_, uint256 destinationChainId_, address vault_)
        payable
    {
        originChainId = originChainId_;
        originContract = originContract_;
        destinationChainId = destinationChainId_;
        vault = vault_;
        owner = msg.sender;

        // Let the Omni system contract settle debt via AbstractPayer.pay().
        addAuthorizedSender(SYSTEM_OMNI);

        // Omni subscription (current docs: the new system contract handles
        // subscriptions; same subscribe() signature as the legacy service).
        // NOTE: this is a low-level call on purpose. A high-level
        // `ISystemContract(SYSTEM_OMNI).subscribe(...)` call REVERTS in
        // forge tests ("call to non-contract address") because the system
        // contract has no code in the test EVM; a low-level call to a
        // code-less address succeeds as a no-op there, while on Lasna it
        // executes the real subscribe. Success is still required, so a
        // subscribe that reverts on-chain fails the deployment loudly
        // instead of silently deploying a deaf contract.
        (bool subscribed,) = SYSTEM_OMNI.call(
            abi.encodeWithSignature(
                "subscribe(uint256,address,uint256,uint256,uint256,uint256)",
                originChainId_,
                originContract_,
                TRANSFER_TOPIC0,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE
            )
        );
        require(subscribed, "SentinelReactive: subscribe failed");

        // Legacy-service subscription AS WELL (Omni fallback, added
        // 2026-11-17 after live proof): the first deployment subscribed
        // Omni-only — react() fired 6/6 and the Callback event was
        // emitted, but the callback was NEVER delivered to Sepolia
        // (vault stayed unpaused, 0.05 ETH untouched, no VaultPaused
        // event after 8+ minutes). Old-style `emit Callback` callbacks
        // are only delivered for RSCs subscribed through the legacy
        // service, so subscribe there too. Low-level call for the same
        // reason as above (no code at 0xfffFfF in the test EVM).
        (bool subscribedLegacy,) = address(service).call(
            abi.encodeWithSignature(
                "subscribe(uint256,address,uint256,uint256,uint256,uint256)",
                originChainId_,
                originContract_,
                TRANSFER_TOPIC0,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE
            )
        );
        require(subscribedLegacy, "SentinelReactive: legacy subscribe failed");
    }

    /// @notice Set the callback recipient after deploying the vault
    ///         (docs deployment order: RSC first, vault second, then this).
    function setRecipient(address recipient_) external onlyOwner {
        recipient = recipient_;
        emit RecipientSet(recipient_);
    }

    /// @notice Re-arm after the vault is unpaused on Sepolia. Owner-only.
    function resetPauseFlag() external onlyOwner {
        paused = false;
        emit PauseFlagReset(block.timestamp);
    }

    /// @notice Settles outstanding reactive-tx debt owed to the OMNI system
    ///         contract, from this contract's own balance.
    function coverDebtOmni() external {
        uint256 amount = ISystemContract(SYSTEM_OMNI).debt(address(this));
        if (amount > 0) {
            (bool ok,) = payable(SYSTEM_OMNI).call{value: amount}("");
            require(ok, "coverDebtOmni: payment failed");
        }
    }

    /// @notice Callback configuration for the Omni system contract's
    ///         `requestCallbackV_1_0` (current docs). The published lib
    ///         (v0.2.0) does not declare it, so it is called via a
    ///         low-level call from react() — same technique as subscribe.
    struct CallbackConfiguration_V_1_0 {
        uint256 chainId;
        address recipient;
        uint64 gasLimit;
        bytes payload;
    }

    event CallbackRequestFailed(address indexed recipient, uint256 score, uint256 timestamp);

    // ---- window views (also used by tests) ----

    /// @notice Outflows in the trailing 60 s window (count).
    function windowOutflowCount() public view returns (uint256 count) {
        uint256 cutoff = block.timestamp > WINDOW_SECONDS ? block.timestamp - WINDOW_SECONDS : 0;
        for (uint256 i = 0; i < WINDOW_SIZE; i++) {
            if (window[i].timestamp >= cutoff && window[i].amount > 0) count++;
        }
    }

    /// @notice Outflows in the trailing 60 s window (cumulative amount).
    function windowOutflowSum() public view returns (uint256 sum) {
        uint256 cutoff = block.timestamp > WINDOW_SECONDS ? block.timestamp - WINDOW_SECONDS : 0;
        for (uint256 i = 0; i < WINDOW_SIZE; i++) {
            if (window[i].timestamp >= cutoff) sum += window[i].amount;
        }
    }

    // ---- fixed-point log10 (scale 1e4), for feature f1/f3 ----

    /// @notice log2(x) * 1e4, via binary expansion (20 fractional bits).
    /// @dev x must be >= 1. Amounts >= 2**200 saturate (their log10 is far
    ///      above the feature clamp anyway).
    function _log2_1e4(uint256 x) internal pure returns (int256) {
        uint256 n = 0;
        uint256 v = x;
        if (v >= (1 << 128)) { v >>= 128; n += 128; }
        if (v >= (1 << 64)) { v >>= 64; n += 64; }
        if (v >= (1 << 32)) { v >>= 32; n += 32; }
        if (v >= (1 << 16)) { v >>= 16; n += 16; }
        if (v >= (1 << 8)) { v >>= 8; n += 8; }
        if (v >= (1 << 4)) { v >>= 4; n += 4; }
        if (v >= (1 << 2)) { v >>= 2; n += 2; }
        if (v >= (1 << 1)) { v >>= 1; n += 1; }
        // n = floor(log2(x)); 2**n <= x < 2**(n+1). Saturate huge inputs.
        if (n >= 200) return int256(200 * 10000);
        // f = x / 2**n in [1, 2), held at 2**20 fixed point.
        uint256 f = (1 << 20) + (((x - (1 << n)) << 20) >> n);
        uint256 frac; // fractional part of log2, at 2**20 fixed point.
        for (uint256 k = 0; k < 20; k++) {
            f = (f * f) >> 20;
            if (f >= (1 << 21)) {
                frac += (1 << (19 - k));
                f >>= 1;
            }
        }
        return int256(n * 10000) + int256((frac * 10000) >> 20);
    }

    /// @notice log10(x) * 1e4. Returns 0 for x == 0 (callers clamp it).
    function _log10_1e4(uint256 x) internal pure returns (int256) {
        if (x == 0) return 0;
        return (_log2_1e4(x) * 3010) / 10000; // log10(2) = 0.30103
    }

    /// @notice log-scaled amount feature: clamp(log10(amountWei) - 18, -6, 6) * 1e4.
    function _amountFeature(uint256 amountWei) internal pure returns (int256) {
        if (amountWei == 0) return -60000;
        int256 v = _log10_1e4(amountWei) - 180000; // log10(tokens) * 1e4
        if (v < -60000) return -60000;
        if (v > 60000) return 60000;
        return v;
    }

    // ---- the reactive entry point ----

    /// @inheritdoc IReactive
    /// @dev Never reverts as a filter: non-matching / non-vault logs fall
    ///      through silently (a reverting react() is still charged in full).
    function react(LogRecord calldata log_) external override onlySystem {
        // ERC-20 Transfer: LOG3, from = topic_1, to = topic_2, value = data.
        if (log_.topic_0 != TRANSFER_TOPIC0 || log_.op_code != 3) return;
        address from = address(uint160(log_.topic_1));
        if (from != vault) return; // only vault outflows feed the model.
        address to = address(uint160(log_.topic_2));
        uint256 amount = abi.decode(log_.data, (uint256));

        // Record the outflow in the 60 s ring buffer.
        window[windowNext] = Outflow({timestamp: block.timestamp, amount: amount});
        windowNext = (windowNext + 1) % WINDOW_SIZE;
        windowTotal++;

        // Features (see DESIGN.md section 3; must match ml/train.py).
        uint256 count = windowOutflowCount();
        uint256 cum = windowOutflowSum();
        int256 f1 = _amountFeature(amount);
        int256 f2 = int256(count) * 10000;
        int256 f3 = _amountFeature(cum);
        bool isNew = !seenRecipients[to];
        int256 f4 = isNew ? int256(10000) : int256(0);
        seenRecipients[to] = true;

        uint256 score = AnomalyModel.score(f1, f2, f3, f4);
        emit Scored(from, to, amount, score);

        // Circuit breaker: threshold + local latch + 10-minute cooldown.
        if (
            score >= ANOMALY_THRESHOLD && !paused && recipient != address(0)
                && block.timestamp >= lastPauseRequestAt + PAUSE_COOLDOWN
        ) {
            bytes memory payload = abi.encodeWithSignature("onAnomaly(address,uint256)", address(0), score);
            // address(0) placeholder: the network overwrites it with this
            // contract's address, so the vault can authenticate the sender.
            //
            // Request the callback the Omni way (current docs prescribe
            // `requestCallbackV_1_0`; the published lib does not declare
            // it, so this is a low-level call — same technique as
            // subscribe). LIVE PROOF 2026-11-17 (two deployments): the
            // legacy `emit Callback(...)` event alone is NOT delivered on
            // this Omni deployment — react() fired, Callback emitted,
            // vault never paused, 0.05 ETH untouched, no delivery after
            // 8+ minutes, on BOTH the Omni-only and the Omni+legacy
            // subscription paths. Only requestCallbackV_1_0 causes the
            // system contract to emit CallbackRequest, which the network
            // picks up. The legacy event is kept as well (tests +
            // observability); a double delivery is harmless — onAnomaly
            // is idempotent (sets paused=true again).
            // The request is NOT required() to succeed: a failed request
            // must not roll back the window/score state, and the latch
            // must only set when a callback was actually requested.
            CallbackConfiguration_V_1_0 memory config = CallbackConfiguration_V_1_0({
                chainId: destinationChainId,
                recipient: recipient,
                gasLimit: CALLBACK_GAS_LIMIT,
                payload: payload
            });
            (bool ok,) = SYSTEM_OMNI.call(
                abi.encodeWithSignature(
                    "requestCallbackV_1_0((uint256,address,uint64,bytes))",
                    config
                )
            );
            emit Callback(destinationChainId, recipient, CALLBACK_GAS_LIMIT, payload);
            if (ok) {
                paused = true;
                lastPauseRequestAt = block.timestamp;
                callbacksRequested++;
                emit CallbackRequested(recipient, score, block.timestamp);
            } else {
                emit CallbackRequestFailed(recipient, score, block.timestamp);
            }
        }
    }
}
