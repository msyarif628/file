// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Test, console} from "forge-std/Test.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {AnomalyModel} from "../contracts/AnomalyModel.sol";

/// @notice Harness: AnomalyModel.score is an internal library function, so
///         tests call it through this thin wrapper.
contract AnomalyModelHarness {
    function score(int256 f1, int256 f2, int256 f3, int256 f4) external pure returns (uint256) {
        return AnomalyModel.score(f1, f2, f3, f4);
    }
}

/// @notice The on-chain MLP must reproduce the trainer's fixed-point
///         simulation (ml/vectors.json) — the same tables, same truncating
///         division — so a mismatch here means the Solidity port drifted
///         from the Python model.
contract AnomalyModelTest is Test {
    AnomalyModelHarness internal model;

    // Tolerance in basis points. The Solidity port mirrors the Python
    // fixed-point simulation exactly, so the observed diff should be ~0;
    // the tolerance only absorbs the float->fixed log10 rounding in the
    // trainer's feature computation.
    uint256 internal constant TOLERANCE = 150;

    function setUp() public {
        model = new AnomalyModelHarness();
    }

    function testMatchesTrainerVectors() public view {
        string memory json = vm.readFile("ml/vectors.json");
        uint256 n = vm.parseJsonArrayLength(json, ".vectors");
        assertGt(n, 0, "no vectors in ml/vectors.json");
        uint256 maxDiff = 0;
        for (uint256 i = 0; i < n; i++) {
            string memory base = string.concat(".vectors[", vm.toString(i), "]");
            int256[] memory f = stdJson.readIntArray(json, string.concat(base, ".features"));
            uint256 expected = stdJson.readUint(json, string.concat(base, ".expected_score"));
            uint256 got = model.score(f[0], f[1], f[2], f[3]);
            uint256 diff = got > expected ? got - expected : expected - got;
            if (diff > maxDiff) maxDiff = diff;
            assertLe(diff, TOLERANCE, string.concat("vector ", vm.toString(i), " diverged from trainer"));
            assertEq(got, expected, string.concat("vector ", vm.toString(i), " mismatch (exact)"));
        }
        console.log("vectors checked:", n, "| max abs diff:", maxDiff);
    }

    function testMonotoneInAmount() public view {
        // Bigger single transfer (same window, same recipient novelty) must
        // never score lower. Sweep log10(amount) from 0.01 to 10,000 tokens.
        uint256 prev = 0;
        for (int256 logAmt = -20000; logAmt <= 40000; logAmt += 5000) {
            uint256 s = model.score(logAmt, 10000, logAmt, 10000);
            assertGe(s, prev, "score decreased as amount grew");
            prev = s;
        }
    }

    function testOutputRange() public view {
        // Extreme corners of the feature space must stay in 0..10000.
        int256[2] memory edges = [int256(-60000), int256(60000)];
        for (uint256 a = 0; a < 2; a++) {
            for (uint256 b = 0; b < 2; b++) {
                uint256 s = model.score(edges[a], 80000, edges[b], 10000);
                assertLe(s, 10000, "score above 10000");
                s = model.score(edges[a], 0, edges[b], 0);
                assertLe(s, 10000, "score above 10000");
            }
        }
        // Zero features: must not revert and must be in range.
        uint256 z = model.score(0, 0, 0, 0);
        assertLe(z, 10000);
    }

    function testThresholdSeparation() public view {
        // The trainer's headline cases: a tiny normal withdrawal scores ~0,
        // a drain burst scores ~10000. The 7000 threshold sits between them.
        uint256 normal = model.score(-3010, 10000, -3010, 0);
        uint256 drain = model.score(33010, 80000, 40792, 10000);
        assertLt(normal, 7000, "normal withdrawal above threshold");
        assertGe(drain, 7000, "drain burst below threshold");
    }
}
