// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

/// @title ModelWeights — GENERATED FILE, do not hand-edit.
/// @notice Quantized weights + feature standardization constants for
///         Sentinel's 4->4->1 anomaly MLP, exported by ml/train.py.
///         All values are fixed point, scale 1e4, unless noted.
/// @dev Regenerate with: python3 ml/train.py
library ModelWeights {
    int256 internal constant SCALE = 10000;

    // Feature standardization: x_i = (f_i - MEAN_i) * SCALE / STD_i
    int256 internal constant MEAN_F1 = 14757;
    int256 internal constant MEAN_F2 = 33344;
    int256 internal constant MEAN_F3 = 18157;
    int256 internal constant MEAN_F4 = 5056;
    int256 internal constant STD_F1 = 15677;
    int256 internal constant STD_F2 = 20333;
    int256 internal constant STD_F3 = 16522;
    int256 internal constant STD_F4 = 5000;

    // Layer 1: 4 hidden units. W1[j] is row j (one weight per input).
    /// @notice Row j of the layer-1 weight matrix (length 4).
    function w1Row(uint256 j) internal pure returns (int256[4] memory) {
        if (j == 0) return [int256(-15692), int256(-4677), int256(-11821), int256(-244)];
        if (j == 1) return [int256(-29932), int256(-7488), int256(-10565), int256(-111)];
        if (j == 2) return [int256(-16228), int256(-4293), int256(-5566), int256(-331)];
        if (j == 3) return [int256(-15101), int256(-4254), int256(-9465), int256(-202)];
        revert("ModelWeights: bad hidden index");
    }

    // Layer-1 biases.
    int256 internal constant B1_0 = 12073;
    int256 internal constant B1_1 = 18526;
    int256 internal constant B1_2 = 9672;
    int256 internal constant B1_3 = 10567;

    // Layer 2: single output unit, W2[hidden], b2.
    int256 internal constant W2_0 = -23139;
    int256 internal constant W2_1 = -26993;
    int256 internal constant W2_2 = -35774;
    int256 internal constant W2_3 = -29805;
    int256 internal constant B2 = -3976;
}
