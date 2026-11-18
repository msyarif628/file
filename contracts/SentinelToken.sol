// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title SentinelToken — demo ERC-20 held by the SentinelVault.
/// @notice Plain OpenZeppelin ERC-20 (18 decimals). The owner mints demo
///         supply to fund the vault; there is no sale, no fee, no real value.
///         Testnet demo token only.
contract SentinelToken is ERC20, Ownable {
    constructor() ERC20("Sentinel Token", "SENT") Ownable(msg.sender) {}

    /// @notice Mint demo tokens. Owner-only; used to fund the vault for demos.
    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }
}
