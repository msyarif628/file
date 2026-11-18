// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IPayable} from "@reactive/interfaces/IPayable.sol";
import {AbstractCallback} from "@reactive/abstract-base/AbstractCallback.sol";

/// @title SentinelVault — pausable demo vault on the destination chain.
/// @notice Holds SentinelToken. Depositors can withdraw their own balance
///         unless the vault is paused. The vault pauses in two ways:
///           1. Automatically, via the Reactive Network callback `onAnomaly`,
///              fired by SentinelReactive when its on-chain neural model
///              scores a vault outflow as a drain.
///           2. Manually, via the owner-only `pause()` override.
///         `unpause()` is owner-only.
///
/// @dev Reactive binding — READ THIS before "fixing" it:
///         This contract is written against the PUBLISHED reactive-lib
///         (v0.2.0, the only version on GitHub). The current docs describe a
///         newer Omni API (`AbstractCallback(IPayable, address)` with
///         `onlyServiceProvider` / `onlyCallbackSender`) that does not exist
///         in the published library, so the same two checks are implemented
///         here with what the library actually provides:
///           - Proxy check: `authorizedSenderOnly` (from AbstractPayer).
///             The constructor passes the destination-chain callback proxy
///             as the library's `_callback_sender`, exactly as Reactive's own
///             Basic Demo does — the library authorizes that address, so only
///             the proxy can deliver callbacks.
///           - RSC check: `reactive_ == callbackSender`, enforced explicitly
///             in `onAnomaly`. The network overwrites the first 160 bits of
///             the callback payload with the requesting reactive contract's
///             address (docs), so this pins the callback to our RSC.
///         The library's `rvmIdOnly` modifier is deliberately NOT used: it
///         compares the injected address against `rvm_id`, which the library
///         sets to the deployer's address in the constructor — that can never
///         equal the RSC address, so using it would brick every callback.
///         See README.md ("Deviation log") for the full story.
contract SentinelVault is AbstractCallback, Ownable {
    IERC20 public immutable token;

    /// @notice The Reactive Network callback proxy on this chain
    ///         (Sepolia: 0xAa14d9Cd0f788Ca23d11805986C1d8bd035D23b4).
    ///         Only this address can deliver callbacks (see above).
    IPayable public immutable callbackProxy;

    /// @notice The SentinelReactive contract on Reactive Lasna. Only
    ///         callbacks originating from this address can pause the vault.
    address public immutable callbackSender;

    bool public paused;

    /// @notice Per-depositor balances (depositors withdraw their own funds).
    mapping(address => uint256) public balances;

    event Deposited(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event VaultPaused(address indexed reactive, uint256 score, uint256 timestamp);
    event VaultUnpaused(uint256 timestamp);

    error VaultIsPaused();
    error NotAuthorizedReactive(address reactive);
    error InsufficientBalance(uint256 requested, uint256 available);

    /// @param token_ The SentinelToken this vault holds.
    /// @param callbackProxy_ The Reactive callback proxy on this chain.
    /// @param callbackSender_ The deployed SentinelReactive address on Lasna.
    /// @dev Payable so the vault can be funded at deployment for callback
    ///      delivery fees (the proxy charges the recipient, in native token).
    constructor(IERC20 token_, IPayable callbackProxy_, address callbackSender_)
        payable
        AbstractCallback(address(callbackProxy_))
        Ownable(msg.sender)
    {
        token = token_;
        callbackProxy = callbackProxy_;
        callbackSender = callbackSender_;
    }

    // ---- deposits / withdrawals (both blocked while paused) ----

    function deposit(uint256 amount) external {
        if (paused) revert VaultIsPaused();
        require(token.transferFrom(msg.sender, address(this), amount), "transfer failed");
        balances[msg.sender] += amount;
        emit Deposited(msg.sender, amount);
    }

    function withdraw(uint256 amount) external {
        if (paused) revert VaultIsPaused();
        uint256 bal = balances[msg.sender];
        if (amount > bal) revert InsufficientBalance(amount, bal);
        balances[msg.sender] = bal - amount;
        require(token.transfer(msg.sender, amount), "transfer failed");
        emit Withdrawn(msg.sender, amount);
    }

    // ---- pausing ----

    /// @notice Reactive callback entry: pause the vault on an anomaly.
    /// @param reactive_ Injected by the network: the RSC that requested this
    ///        callback (callers pass address(0) as a placeholder in the
    ///        payload; the network overwrites it). Must be our RSC.
    /// @param score_ The anomaly score (0..10000) the model produced.
    /// @dev `authorizedSenderOnly` = only the callback proxy may call this.
    ///      The explicit `reactive_ == callbackSender` check = only our RSC.
    ///      Together these are the two checks the current docs prescribe as
    ///      `onlyServiceProvider` + `onlyCallbackSender`.
    function onAnomaly(address reactive_, uint256 score_) external authorizedSenderOnly {
        if (reactive_ != callbackSender) revert NotAuthorizedReactive(reactive_);
        paused = true;
        emit VaultPaused(reactive_, score_, block.timestamp);
    }

    /// @notice Manual pause (owner override, e.g. during an incident).
    function pause() external onlyOwner {
        paused = true;
        emit VaultPaused(address(0), 0, block.timestamp);
    }

    /// @notice Resume withdrawals. Owner-only.
    function unpause() external onlyOwner {
        paused = false;
        emit VaultUnpaused(block.timestamp);
    }

    // NOTE on funding: AbstractPayer (inherited via AbstractCallback)
    // already exposes a public `coverDebt()` that settles this vault's
    // outstanding callback-delivery debt with the proxy from the vault's
    // own balance. It is inherited as-is; do not redeclare it here
    // (the base function is not virtual).
}
