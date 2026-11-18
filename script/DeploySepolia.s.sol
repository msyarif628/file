// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPayable} from "@reactive/interfaces/IPayable.sol";
import {SentinelToken} from "../contracts/SentinelToken.sol";
import {SentinelVault} from "../contracts/SentinelVault.sol";

/// @title DeploySepolia — deploy SentinelToken + SentinelVault to Sepolia.
/// @notice This script deploys ONLY the Sepolia side. The reactive contract
///         (SentinelReactive, on Lasna) is deployed separately with
///         `forge create` / `cast send --create` — NEVER with `forge script`,
///         because its constructor calls the system contract, which only
///         exists on real Reactive nodes (it reverts in simulation).
///
///         Deployment order (see script/DEPLOY.md for the full runbook):
///           1. Predict the RSC address with `cast compute-address`
///              (deployer + next Lasna nonce).
///           2. Run this script with RSC_ADDRESS=<predicted address>.
///              It deploys the token, the vault (callbackSender = predicted
///              RSC address), mints demo supply and funds the vault.
///           3. Deploy the RSC from the same deployer account (next nonce)
///              and verify the deployed address matches the prediction.
///              If it does not, redeploy the vault with the real address.
///           4. setRecipient(vault) on the RSC, then fund both sides.
///
///         Env / CLI (placeholders only — NEVER commit a real key):
///           RSC_ADDRESS   — predicted (then real) SentinelReactive address.
///           PRIVATE_KEY   — pass via --private-key on the CLI, not in env.
///           RPC           — pass via --rpc-url on the CLI.
///         Run (dry-run first, no --broadcast):
///           forge script script/DeploySepolia.s.sol --rpc-url $SEPOLIA_RPC
///         Broadcast:
///           forge script script/DeploySepolia.s.sol --rpc-url $SEPOLIA_RPC \
///               --private-key $PRIVATE_KEY --broadcast
contract DeploySepolia is Script {
    /// @notice Sepolia callback proxy (docs, 2026-11-17).
    address internal constant SEPOLIA_PROXY = 0xAa14d9Cd0f788Ca23d11805986C1d8bd035D23b4;

    /// @notice ETH sent with the vault deployment, for callback-delivery fees.
    uint256 internal constant VAULT_FUNDING = 0.05 ether;

    /// @notice Demo supply minted to the deployer; half is deposited.
    uint256 internal constant DEMO_SUPPLY = 100_000 ether;
    uint256 internal constant VAULT_DEPOSIT = 50_000 ether;

    function run() external returns (SentinelToken token, SentinelVault vault) {
        address rsc = vm.envAddress("RSC_ADDRESS");
        require(rsc != address(0), "RSC_ADDRESS env var is not set");

        vm.startBroadcast();

        token = new SentinelToken();
        console.log("SentinelToken deployed at:", address(token));

        vault = new SentinelVault{value: VAULT_FUNDING}(
            IERC20(address(token)), IPayable(payable(SEPOLIA_PROXY)), rsc
        );
        console.log("SentinelVault deployed at:", address(vault));
        console.log("  callbackSender (RSC):", rsc);

        token.mint(msg.sender, DEMO_SUPPLY);
        token.approve(address(vault), VAULT_DEPOSIT);
        vault.deposit(VAULT_DEPOSIT);
        console.log("Deposited into vault:", VAULT_DEPOSIT / 1 ether, "SENT");

        vm.stopBroadcast();
    }
}
