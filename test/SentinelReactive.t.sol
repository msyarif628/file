// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Test} from "forge-std/Test.sol";
import {IReactive} from "@reactive/interfaces/IReactive.sol";
import {SentinelReactive} from "../contracts/SentinelReactive.sol";

/// @notice End-to-end logic tests for the reactive contract, driven by
///         fabricated LogRecords — the same shape the system contract
///         delivers on Lasna.
///
/// @dev Why no mocked SYSTEM contract is needed here (DESIGN.md suggested
///      vm.etch): this build subscribes via the Omni system contract
///      0x8888..., which has no code in tests, so the constructor's
///      subscribe call succeeds as a no-op. react() is invoked directly
///      with msg.sender pranked to the system address, exactly as the
///      network would call it. See README.md ("Deviation log").
contract SentinelReactiveTest is Test {
    address internal constant SYSTEM = 0x8888888888888888888888888888888888888888;
    uint256 internal constant TRANSFER_TOPIC0 =
        0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef;

    address internal tokenAddr = makeAddr("sentinel-token");
    address internal vaultAddr = makeAddr("sentinel-vault");
    address internal callbackAddr = makeAddr("vault-callback");
    address internal alice = makeAddr("alice");

    SentinelReactive internal rsc;

    function setUp() public {
        vm.warp(1_000_000); // sane timestamps for the 60 s window math.
        rsc = new SentinelReactive{value: 0}(
            11155111, // origin: Sepolia
            tokenAddr,
            11155111, // destination: Sepolia
            vaultAddr
        );
        rsc.setRecipient(callbackAddr);
    }

    function _log(address from, address to, uint256 amount) internal view returns (IReactive.LogRecord memory) {
        return IReactive.LogRecord({
            chain_id: 11155111,
            _contract: tokenAddr,
            topic_0: TRANSFER_TOPIC0,
            topic_1: uint256(uint160(from)),
            topic_2: uint256(uint160(to)),
            topic_3: 0,
            data: abi.encode(amount),
            block_number: 1,
            op_code: 3,
            block_hash: 0,
            tx_hash: 0,
            log_index: 0
        });
    }

    function _react(IReactive.LogRecord memory log) internal {
        vm.prank(SYSTEM);
        rsc.react(log);
    }

    function testNormalTransfersDoNotRequestCallback() public {
        // Three small (10-token) withdrawals to the same known recipient.
        for (uint256 i = 0; i < 3; i++) {
            _react(_log(vaultAddr, alice, 10 ether));
        }
        assertEq(rsc.callbacksRequested(), 0, "normal flow requested a callback");
        assertFalse(rsc.paused());
        assertEq(rsc.windowOutflowCount(), 3);
    }

    function testDrainBurstRequestsCallback() public {
        // A single 800-token transfer to a fresh recipient already scores
        // ~9933 (sweep pattern) — the vault must pause on the first one.
        address fresh = makeAddr("fresh-1");
        _react(_log(vaultAddr, fresh, 800 ether));
        assertEq(rsc.callbacksRequested(), 1, "drain did not request a callback");
        assertTrue(rsc.paused());

        // Further drain transfers while latched: no duplicate callbacks.
        for (uint256 i = 2; i <= 5; i++) {
            _react(_log(vaultAddr, makeAddr(string(abi.encodePacked("fresh-", i))), 800 ether));
        }
        assertEq(rsc.callbacksRequested(), 1, "duplicate callback while paused");
    }

    function testBurstOfMediumTransfersRequestsCallback() public {
        // Five 150-token transfers to fresh recipients: the model scores
        // the 4th+ in the burst above threshold (see ml/vectors.json).
        for (uint256 i = 0; i < 5; i++) {
            _react(_log(vaultAddr, makeAddr(string(abi.encodePacked("m-", i))), 150 ether));
        }
        assertGe(rsc.callbacksRequested(), 1, "medium burst did not request a callback");
        assertTrue(rsc.paused());
    }

    function testNonVaultTransfersIgnored() public {
        _react(_log(alice, makeAddr("someone"), 5_000 ether));
        assertEq(rsc.windowOutflowCount(), 0, "non-vault transfer fed the window");
        assertEq(rsc.callbacksRequested(), 0);
    }

    function testWrongTopicAndOpcodeIgnored() public {
        IReactive.LogRecord memory wrongTopic = _log(vaultAddr, alice, 5_000 ether);
        wrongTopic.topic_0 = 0x1234;
        _react(wrongTopic);

        IReactive.LogRecord memory wrongOpcode = _log(vaultAddr, alice, 5_000 ether);
        wrongOpcode.op_code = 2; // not LOG3
        _react(wrongOpcode);

        assertEq(rsc.windowOutflowCount(), 0, "non-Transfer log fed the window");
        assertEq(rsc.callbacksRequested(), 0);
    }

    function testOnlySystemCanCallReact() public {
        vm.prank(alice);
        vm.expectRevert(SentinelReactive.NotSystem.selector);
        rsc.react(_log(vaultAddr, alice, 1 ether));
    }

    function testWindowExpiresAfter60Seconds() public {
        _react(_log(vaultAddr, alice, 10 ether));
        assertEq(rsc.windowOutflowCount(), 1);
        vm.warp(block.timestamp + 61);
        assertEq(rsc.windowOutflowCount(), 0, "stale outflow still in window");
        assertEq(rsc.windowOutflowSum(), 0);
    }

    function testCooldownAndResetRearm() public {
        _react(_log(vaultAddr, makeAddr("drain-1"), 800 ether));
        assertEq(rsc.callbacksRequested(), 1);

        // Still inside the 10-minute cooldown: reset + immediate re-drain
        // must NOT request a second callback.
        rsc.resetPauseFlag();
        assertFalse(rsc.paused());
        _react(_log(vaultAddr, makeAddr("drain-2"), 800 ether));
        assertEq(rsc.callbacksRequested(), 1, "callback inside cooldown");

        // After the cooldown, a fresh drain requests again.
        vm.warp(block.timestamp + 10 minutes + 1);
        _react(_log(vaultAddr, makeAddr("drain-3"), 800 ether));
        assertEq(rsc.callbacksRequested(), 2, "no callback after cooldown");
    }

    function testOnlyOwnerCanSetRecipientAndReset() public {
        vm.prank(alice);
        vm.expectRevert(SentinelReactive.NotOwner.selector);
        rsc.setRecipient(alice);
        vm.prank(alice);
        vm.expectRevert(SentinelReactive.NotOwner.selector);
        rsc.resetPauseFlag();
    }

    function testNoCallbackWithoutRecipient() public {
        // Recipient unset (fresh RSC): scoring still runs, but no callback
        // can be addressed anywhere.
        SentinelReactive fresh = new SentinelReactive{value: 0}(11155111, tokenAddr, 11155111, vaultAddr);
        vm.prank(SYSTEM);
        fresh.react(_log(vaultAddr, makeAddr("x"), 800 ether));
        assertEq(fresh.callbacksRequested(), 0);
    }
}
