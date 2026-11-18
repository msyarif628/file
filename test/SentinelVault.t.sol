// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPayable} from "@reactive/interfaces/IPayable.sol";
import {SentinelToken} from "../contracts/SentinelToken.sol";
import {SentinelVault} from "../contracts/SentinelVault.sol";

contract SentinelVaultTest is Test {
    // Real Sepolia callback proxy (docs) — used here as an address to prank.
    address internal constant PROXY = 0xAa14d9Cd0f788Ca23d11805986C1d8bd035D23b4;
    address internal rsc = makeAddr("sentinel-reactive");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    SentinelToken internal token;
    SentinelVault internal vault;

    function setUp() public {
        vm.deal(address(this), 1 ether);
        token = new SentinelToken();
        vault = new SentinelVault(IERC20(address(token)), IPayable(payable(PROXY)), rsc);
        token.mint(alice, 10_000 ether);
        token.mint(bob, 10_000 ether);
        vm.prank(alice);
        token.approve(address(vault), type(uint256).max);
        vm.prank(bob);
        token.approve(address(vault), type(uint256).max);
    }

    function testDepositAndWithdraw() public {
        vm.prank(alice);
        vault.deposit(1_000 ether);
        assertEq(vault.balances(alice), 1_000 ether);
        assertEq(token.balanceOf(address(vault)), 1_000 ether);

        vm.prank(alice);
        vault.withdraw(400 ether);
        assertEq(vault.balances(alice), 600 ether);
        assertEq(token.balanceOf(alice), 10_000 ether - 1_000 ether + 400 ether);
    }

    function testWithdrawMoreThanBalanceReverts() public {
        vm.prank(alice);
        vault.deposit(100 ether);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(SentinelVault.InsufficientBalance.selector, 101 ether, 100 ether));
        vault.withdraw(101 ether);
    }

    function testPauseBlocksDepositAndWithdraw() public {
        vm.prank(alice);
        vault.deposit(500 ether);
        vault.pause(); // owner (this test contract) pauses.

        vm.prank(alice);
        vm.expectRevert(SentinelVault.VaultIsPaused.selector);
        vault.deposit(1 ether);

        vm.prank(alice);
        vm.expectRevert(SentinelVault.VaultIsPaused.selector);
        vault.withdraw(1 ether);

        vault.unpause();
        vm.prank(alice);
        vault.withdraw(100 ether);
        assertEq(vault.balances(alice), 400 ether);
    }

    function testOnlyOwnerCanPauseAndUnpause() public {
        vm.prank(alice);
        vm.expectRevert();
        vault.pause();
        vm.prank(alice);
        vm.expectRevert();
        vault.unpause();
    }

    function testCallbackPausesVault() public {
        // Delivered by the proxy, originating from our RSC: must pause.
        vm.prank(PROXY);
        vault.onAnomaly(rsc, 9933);
        assertTrue(vault.paused());

        vm.prank(alice);
        vm.expectRevert(SentinelVault.VaultIsPaused.selector);
        vault.withdraw(1 ether);
    }

    function testCallbackFromNonProxyReverts() public {
        // Anyone other than the callback proxy must not be able to pause
        // the vault — even if they pass the correct RSC address.
        vm.prank(alice);
        vm.expectRevert("Authorized sender only");
        vault.onAnomaly(rsc, 9933);
        assertFalse(vault.paused());
    }

    function testCallbackFromWrongReactiveReverts() public {
        // Delivered by the real proxy, but from a different reactive
        // contract: must not pause (only our RSC is authorized).
        vm.prank(PROXY);
        vm.expectRevert(
            abi.encodeWithSelector(SentinelVault.NotAuthorizedReactive.selector, address(0xBEEF))
        );
        vault.onAnomaly(address(0xBEEF), 9933);
        assertFalse(vault.paused());
    }

    function testCallbackFromWrongReactiveWithZeroAddressReverts() public {
        // address(0) is the payload placeholder — if the network ever failed
        // to overwrite it, the vault must still refuse.
        vm.prank(PROXY);
        vm.expectRevert(
            abi.encodeWithSelector(SentinelVault.NotAuthorizedReactive.selector, address(0))
        );
        vault.onAnomaly(address(0), 9933);
        assertFalse(vault.paused());
    }

    function testVaultAcceptsFunding() public {
        // Payable constructor + receive(): the vault must hold ETH for
        // callback-delivery fees.
        (bool ok,) = payable(address(vault)).call{value: 0.05 ether}("");
        assertTrue(ok);
        assertEq(address(vault).balance, 0.05 ether);
    }
}
