#!/usr/bin/env python3
"""
Sentinel — off-chain trainer for the on-chain 4 -> 4 -> 1 anomaly MLP.

What it does
------------
1. Generates a synthetic dataset of vault outflows (normal vs drain).
2. Trains a tiny MLP (4 inputs -> 4 tanh hidden -> 1 sigmoid output)
   with numpy only (stdlib + numpy, no other dependencies).
3. Quantizes the trained weights to fixed point (scale 1e4) and runs an
   EXACT integer simulation of the Solidity model (same lookup tables,
   same truncating division) so the exported test vectors match what
   `AnomalyModel.score()` returns on-chain, bit for bit up to a tiny
   tolerance.
4. Writes:
   - ml/weights.json          (float + quantized weights, feature stats)
   - ml/vectors.json         (reference test vectors: raw features -> score)
   - contracts/ModelWeights.sol (generated constants — never hand-edit)

Feature definitions (MUST match SentinelReactive.sol exactly)
-------------------------------------------------------------
All features are fixed-point ints, scale 1e4 (SCALE = 10000).
  f1 = clamp(log10(amountWei) - 18, -6, 6) * 1e4   (log-scaled amount)
  f2 = outflow count in trailing 60 s window * 1e4
  f3 = clamp(log10(cumulativeWei) - 18, -6, 6) * 1e4
  f4 = 1e4 if `to` never received from the vault before, else 0
Standardization (inside the model, both in Python sim and Solidity):
  x_i = (f_i - MEAN_i) * SCALE // STD_i        (truncating division)

Reproduce:  python3 ml/train.py
"""

import json
import math
import os
import random

import numpy as np

SCALE = 10000
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# ---------------------------------------------------------------------------
# Fixed-point helpers (mirror Solidity semantics exactly)
# ---------------------------------------------------------------------------

def tdiv(a: int, b: int) -> int:
    """Integer division truncating toward zero (Solidity semantics)."""
    q = abs(a) // abs(b)
    return q if (a >= 0) == (b >= 0) else -q


# Lookup tables — MUST be identical to AnomalyModel.sol.
# tanh: input z in [-4, 4] (fixed point), step 0.25, 33 points, values * 1e4.
# sigmoid: input z in [-8, 8] (fixed point), step 0.5, 33 points, values 0..1e4.
def _tanh_table():
    return [round(math.tanh(-4.0 + 0.25 * i) * SCALE) for i in range(33)]


def _sigmoid_table():
    return [round(1.0 / (1.0 + math.exp(-(-8.0 + 0.5 * i))) * SCALE) for i in range(33)]


TANH_TABLE = _tanh_table()
SIGMOID_TABLE = _sigmoid_table()
TANH_MIN, TANH_STEP = -4 * SCALE, SCALE // 4
SIG_MIN, SIG_STEP = -8 * SCALE, SCALE // 2


def _interp_table(x: int, table, lo: int, step: int) -> int:
    """Piecewise-linear table lookup with truncating integer division."""
    if x <= lo:
        return table[0]
    hi = lo + step * (len(table) - 1)
    if x >= hi:
        return table[-1]
    idx = (x - lo) // step
    rem = (x - lo) - idx * step
    y0, y1 = table[idx], table[idx + 1]
    return y0 + tdiv((y1 - y0) * rem, step)


def tanh_fixed(x: int) -> int:
    return _interp_table(x, TANH_TABLE, TANH_MIN, TANH_STEP)


def sigmoid_fixed(x: int) -> int:
    return _interp_table(x, SIGMOID_TABLE, SIG_MIN, SIG_STEP)


def score_fixed(f1: int, f2: int, f3: int, f4: int, w) -> int:
    """Exact integer replica of AnomalyModel.score()."""
    feats = [f1, f2, f3, f4]
    xs = [tdiv((feats[i] - w["mean"][i]) * SCALE, w["std"][i]) for i in range(4)]
    hidden = []
    for j in range(4):
        acc = w["b1"][j]
        for i in range(4):
            acc += tdiv(w["w1"][j][i] * xs[i], SCALE)
        hidden.append(tanh_fixed(acc))
    z = w["b2"]
    for j in range(4):
        z += tdiv(w["w2"][j] * hidden[j], SCALE)
    return sigmoid_fixed(z)


# ---------------------------------------------------------------------------
# Synthetic data — features in FLOAT (log10 tokens etc.), labels 0/1
# ---------------------------------------------------------------------------

def gen_normal(rng: np.random.Generator, n: int):
    """Ordinary withdrawals: small amounts, few per minute, known recipients."""
    amt = 10 ** rng.uniform(-2.0, 1.7, n)          # 0.01 .. 50 tokens
    cnt = rng.integers(1, 4, n)                    # 1..3 outflows / 60 s
    cum = amt * rng.uniform(1.0, 2.5, n)           # cumulative in window
    fresh = (rng.random(n) < 0.15).astype(float)    # mostly known recipients
    return amt, cnt, cum, fresh


def gen_drain_burst(rng: np.random.Generator, n: int):
    """Drain bursts: large amounts, many rapid outflows, fresh recipients."""
    amt = 10 ** rng.uniform(2.0, 3.7, n)           # 100 .. 5000 tokens
    cnt = rng.integers(4, 9, n)                    # 4..8 outflows / 60 s
    cum = amt * rng.uniform(2.5, 6.0, n)
    fresh = (rng.random(n) < 0.85).astype(float)
    return amt, cnt, cum, fresh


def gen_drain_sweep(rng: np.random.Generator, n: int):
    """Single-transfer sweeps: one enormous transfer to a fresh address."""
    amt = 10 ** rng.uniform(2.7, 4.0, n)           # 500 .. 10000 tokens
    cnt = np.ones(n)
    cum = amt * rng.uniform(1.0, 1.2, n)
    fresh = (rng.random(n) < 0.90).astype(float)
    return amt, cnt, cum, fresh


def gen_ambiguous(rng: np.random.Generator, n: int):
    """Grey zone: medium amounts / counts, labelled by a deterministic rule
    (not coin flips — random labels would cap accuracy at ~87% and teach
    the model that medium transfers are unpredictable). Rule: a drain is
    a large single amount, or a medium amount repeated rapidly.
    Returns (amt, cnt, cum, fresh, label)."""
    amt = 10 ** rng.uniform(1.3, 2.3, n)           # 20 .. 200 tokens
    cnt = rng.integers(2, 6, n)
    cum = amt * rng.uniform(1.0, 3.5, n)
    fresh = (rng.random(n) < 0.5).astype(float)
    lab = ((amt >= 100) & (cnt >= 4)) | (amt >= 1000)
    return amt, cnt, cum, fresh, lab.astype(int)


def to_features(amt, cnt, cum, fresh):
    """Float features, same definitions as the contract (before standardizing)."""
    f1 = np.clip(np.log10(np.maximum(amt, 1e-9)), -6.0, 6.0)
    f2 = cnt.astype(float)
    f3 = np.clip(np.log10(np.maximum(cum, 1e-9)), -6.0, 6.0)
    f4 = fresh
    return np.stack([f1, f2, f3, f4], axis=1)


def raw_fixed(amt_tok: float, cnt: int, cum_tok: float, fresh: int):
    """Raw fixed-point features exactly as SentinelReactive computes them.

    amount in wei = tokens * 1e18, so log10(amountWei) - 18 == log10(tokens).
    """
    f1 = int(round(max(-6.0, min(6.0, math.log10(max(amt_tok, 1e-9)))) * SCALE))
    f2 = int(cnt) * SCALE
    f3 = int(round(max(-6.0, min(6.0, math.log10(max(cum_tok, 1e-9)))) * SCALE))
    f4 = int(fresh) * SCALE
    return [f1, f2, f3, f4]


def build_dataset(seed: int = 42):
    rng = np.random.default_rng(seed)
    parts, labels = [], []
    for gen, n, lab in [
        (gen_normal, 1500, 0),
        (gen_drain_burst, 1100, 1),
        (gen_drain_sweep, 400, 1),
    ]:
        amt, cnt, cum, fresh = gen(rng, n)
        parts.append(to_features(amt, cnt, cum, fresh))
        labels.append(np.full(n, lab))
    # Grey zone carries its own rule-based labels (see gen_ambiguous).
    amt, cnt, cum, fresh, lab = gen_ambiguous(rng, 1000)
    parts.append(to_features(amt, cnt, cum, fresh))
    labels.append(lab)
    X = np.vstack(parts)
    y = np.concatenate(labels).astype(float)
    idx = rng.permutation(len(y))
    return X[idx], y[idx]


# ---------------------------------------------------------------------------
# Training — plain numpy MLP, Adam, binary cross-entropy
# ---------------------------------------------------------------------------

def sigmoid(x):
    return 1.0 / (1.0 + np.exp(-np.clip(x, -30, 30)))


def train(X, y, epochs=900, lr=0.01, seed=7):
    rng = np.random.default_rng(seed)
    W1 = rng.normal(0, 0.7, (4, 4))
    b1 = np.zeros(4)
    W2 = rng.normal(0, 0.7, 4)
    b2 = np.zeros(1)
    params = [W1, b1, W2, b2]
    m = [np.zeros_like(p) for p in params]
    v = [np.zeros_like(p) for p in params]
    b1_, b2_, eps = 0.9, 0.999, 1e-8
    n = len(y)
    for t in range(1, epochs + 1):
        h_pre = X @ W1.T + b1
        h = np.tanh(h_pre)
        z = h @ W2 + b2
        p = sigmoid(z)
        loss = -np.mean(y * np.log(p + 1e-12) + (1 - y) * np.log(1 - p + 1e-12))
        dz = (p - y) / n
        gW2 = h.T @ dz
        gb2 = np.array([dz.sum()])
        dh = np.outer(dz, W2) * (1 - h ** 2)
        gW1 = dh.T @ X
        gb1 = dh.sum(axis=0)
        grads = [gW1, gb1, gW2, gb2]
        for k in range(4):
            m[k] = b1_ * m[k] + (1 - b1_) * grads[k]
            v[k] = b2_ * v[k] + (1 - b2_) * grads[k] ** 2
            mh = m[k] / (1 - b1_ ** t)
            vh = v[k] / (1 - b2_ ** t)
            params[k] -= lr * mh / (np.sqrt(vh) + eps)
        W1, b1, W2, b2 = params
        if t % 300 == 0 or t == 1:
            acc = float(np.mean((p > 0.5) == y))
            print(f"  epoch {t:4d}  loss {loss:.4f}  train-acc {acc:.4f}")
    return W1, b1, W2, b2


def predict_float(X, W1, b1, W2, b2):
    return sigmoid(np.tanh(X @ W1.T + b1) @ W2 + b2)


def confusion(y_true, y_pred):
    tp = int(np.sum((y_true == 1) & (y_pred == 1)))
    tn = int(np.sum((y_true == 0) & (y_pred == 0)))
    fp = int(np.sum((y_true == 0) & (y_pred == 1)))
    fn = int(np.sum((y_true == 1) & (y_pred == 0)))
    return tp, tn, fp, fn


def quantize(W1, b1, W2, b2, mean, std):
    return {
        "mean": [int(round(float(v) * SCALE)) for v in mean],
        "std": [max(1, int(round(float(v) * SCALE))) for v in std],
        "w1": [[int(round(float(v) * SCALE)) for v in row] for row in W1],
        "b1": [int(round(float(v) * SCALE)) for v in b1],
        "w2": [int(round(float(v) * SCALE)) for v in W2],
        "b2": int(round(float(b2[0]) * SCALE)),
    }


def main():
    print("Sentinel trainer — synthetic normal-vs-drain, 4->4->1 MLP")
    X, y = build_dataset()
    n_test = 800
    X_train, y_train = X[:-n_test], y[:-n_test]
    X_test, y_test = X[-n_test:], y[-n_test:]
    mean, std = X_train.mean(axis=0), X_train.std(axis=0)
    std = np.where(std == 0, 1.0, std)
    Xs_train = (X_train - mean) / std
    Xs_test = (X_test - mean) / std
    print(f"dataset: {len(y)} rows ({int(np.sum(y == 0))} normal, "
          f"{int(np.sum(y == 1))} drain); train {len(y_train)}, test {n_test}")
    print(f"feature mean {np.round(mean, 3).tolist()} std {np.round(std, 3).tolist()}")
    print("training...")
    W1, b1, W2, b2 = train(Xs_train, y_train)

    # Float evaluation.
    p_test = predict_float(Xs_test, W1, b1, W2, b2)
    pred = (p_test > 0.5).astype(int)
    tp, tn, fp, fn = confusion(y_test, pred)
    acc = (tp + tn) / len(y_test)
    print(f"\nFLOAT model — test accuracy {acc:.4f}")
    print(f"confusion matrix (rows=true, cols=pred): "
          f"[[TN {tn}, FP {fp}], [FN {fn}, TP {tp}]]")
    print(f"drain recall {tp / max(1, tp + fn):.4f} | "
          f"normal precision {tn / max(1, tn + fp):.4f}")

    # Quantize + exact fixed-point simulation on the test set.
    w = quantize(W1, b1, W2, b2, mean, std)
    X_test_fixed = []
    for row in X_test:
        # Recover raw fixed-point features from the float ones:
        # f1/f3 were log10(tokens) clipped; f2 count; f4 0/1.
        X_test_fixed.append([
            int(round(float(row[0]) * SCALE)),
            int(round(float(row[1]) * SCALE)),
            int(round(float(row[2]) * SCALE)),
            int(round(float(row[3]) * SCALE)),
        ])
    fp_pred = np.array([
        1 if score_fixed(*f, w) >= 5000 else 0 for f in X_test_fixed
    ])
    tp, tn, fp, fn = confusion(y_test, fp_pred)
    fp_acc = (tp + tn) / len(y_test)
    print(f"\nFIXED-POINT model (what runs on-chain) — test accuracy {fp_acc:.4f}")
    print(f"confusion matrix (rows=true, cols=pred): "
          f"[[TN {tn}, FP {fp}], [FN {fn}, TP {tp}]]")
    print(f"drain recall {tp / max(1, tp + fn):.4f} | "
          f"normal precision {tn / max(1, tn + fp):.4f}")

    # Sanity: fixed-point score distribution on clearly-normal / clearly-drain.
    normal_ex = raw_fixed(0.5, 1, 0.5, 0)
    drain_ex = raw_fixed(2000.0, 8, 12000.0, 1)
    print(f"\nsanity scores (0..10000, threshold 7000): "
          f"tiny normal {score_fixed(*normal_ex, w)}, "
          f"big drain burst {score_fixed(*drain_ex, w)}")

    # ---- exports ----
    weights_path = os.path.join(ROOT, "ml", "weights.json")
    with open(weights_path, "w") as fh:
        json.dump({"scale": SCALE, "float_accuracy": acc,
                   "fixed_accuracy": fp_acc, **w}, fh, indent=2)
    print(f"wrote {weights_path}")

    # Reference test vectors: raw fixed-point features -> fixed-point score.
    cases = [
        ("tiny normal withdrawal", 0.5, 1, 0.5, 0),
        ("normal withdrawal, known recipient", 10.0, 2, 15.0, 0),
        ("normal withdrawal, fresh recipient", 25.0, 3, 60.0, 1),
        ("medium transfer, burst of 4", 150.0, 4, 400.0, 1),
        ("drain burst, 5 x 800 tokens", 800.0, 5, 3000.0, 1),
        ("drain burst, 8 x 2000 tokens", 2000.0, 8, 12000.0, 1),
        ("single sweep, 5000 tokens", 5000.0, 1, 5000.0, 1),
        ("medium single, known recipient", 100.0, 1, 100.0, 0),
    ]
    vectors = []
    for name, amt, cnt, cum, fresh in cases:
        feats = raw_fixed(amt, cnt, cum, fresh)
        vectors.append({"name": name, "features": feats,
                        "expected_score": score_fixed(*feats, w)})
    vectors_path = os.path.join(ROOT, "ml", "vectors.json")
    with open(vectors_path, "w") as fh:
        json.dump({"scale": SCALE, "threshold": 7000,
                   "vectors": vectors}, fh, indent=2)
    print(f"wrote {vectors_path}")
    for v in vectors:
        print(f"  {v['name']:38s} features={v['features']} -> {v['expected_score']}")

    # ---- generate contracts/ModelWeights.sol ----
    lines = []
    lines.append("// SPDX-License-Identifier: MIT")
    lines.append("pragma solidity ^0.8.29;")
    lines.append("")
    lines.append("/// @title ModelWeights — GENERATED FILE, do not hand-edit.")
    lines.append("/// @notice Quantized weights + feature standardization constants for")
    lines.append("///         Sentinel's 4->4->1 anomaly MLP, exported by ml/train.py.")
    lines.append("///         All values are fixed point, scale 1e4, unless noted.")
    lines.append("/// @dev Regenerate with: python3 ml/train.py")
    lines.append("library ModelWeights {")
    lines.append(f"    int256 internal constant SCALE = {SCALE};")
    lines.append("")
    lines.append("    // Feature standardization: x_i = (f_i - MEAN_i) * SCALE / STD_i")
    lines.append("    int256 internal constant MEAN_F1 = %d;" % w["mean"][0])
    lines.append("    int256 internal constant MEAN_F2 = %d;" % w["mean"][1])
    lines.append("    int256 internal constant MEAN_F3 = %d;" % w["mean"][2])
    lines.append("    int256 internal constant MEAN_F4 = %d;" % w["mean"][3])
    lines.append("    int256 internal constant STD_F1 = %d;" % w["std"][0])
    lines.append("    int256 internal constant STD_F2 = %d;" % w["std"][1])
    lines.append("    int256 internal constant STD_F3 = %d;" % w["std"][2])
    lines.append("    int256 internal constant STD_F4 = %d;" % w["std"][3])
    lines.append("")
    lines.append("    // Layer 1: 4 hidden units. W1[j] is row j (one weight per input).")
    lines.append("    /// @notice Row j of the layer-1 weight matrix (length 4).")
    lines.append("    function w1Row(uint256 j) internal pure returns (int256[4] memory) {")
    for j in range(4):
        row = ", ".join("int256(%d)" % v for v in w["w1"][j])
        lines.append(f"        if (j == {j}) return [{row}];")
    lines.append("        revert(\"ModelWeights: bad hidden index\");")
    lines.append("    }")
    lines.append("")
    lines.append("    // Layer-1 biases.")
    lines.append("    int256 internal constant B1_0 = %d;" % w["b1"][0])
    lines.append("    int256 internal constant B1_1 = %d;" % w["b1"][1])
    lines.append("    int256 internal constant B1_2 = %d;" % w["b1"][2])
    lines.append("    int256 internal constant B1_3 = %d;" % w["b1"][3])
    lines.append("")
    lines.append("    // Layer 2: single output unit, W2[hidden], b2.")
    lines.append("    int256 internal constant W2_0 = %d;" % w["w2"][0])
    lines.append("    int256 internal constant W2_1 = %d;" % w["w2"][1])
    lines.append("    int256 internal constant W2_2 = %d;" % w["w2"][2])
    lines.append("    int256 internal constant W2_3 = %d;" % w["w2"][3])
    lines.append("    int256 internal constant B2 = %d;" % w["b2"])
    lines.append("}")
    sol_path = os.path.join(ROOT, "contracts", "ModelWeights.sol")
    with open(sol_path, "w") as fh:
        fh.write("\n".join(lines) + "\n")
    print(f"wrote {sol_path}")


if __name__ == "__main__":
    main()
