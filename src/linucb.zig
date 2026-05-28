//! linucb — Disjoint LinUCB contextual bandit (Li et al. 2010).
//!
//! Where Thompson sampling treats every (site, variant) as an
//! independent arm, LinUCB exploits a per-decision **feature
//! vector** x ∈ ℝ^d (cardinality estimate, partition count, join
//! type, etc.). Each arm maintains:
//!
//!   A ∈ ℝ^(d×d)   identity-seeded design matrix (X^T X + λI).
//!   b ∈ ℝ^d       cumulative reward vector (X^T r).
//!   θ = A^-1 b    least-squares estimate of arm-conditional reward.
//!
//! For a new context x:
//!   predicted_mean(arm)   = θ^T x.
//!   exploration_bonus     = α · √(x^T A^-1 x).
//!   ucb(arm) = mean + bonus.
//! Choose argmax(ucb).
//!
//! Update on observed reward r:
//!   A ← A + x x^T.
//!   b ← b + r · x.
//!
//! v0.0.1 (this commit) ships d ≤ 8 (small fixed-dim) and the matrix
//! algebra via the determinant-free 8×8 Gauss-Jordan inverse from
//! `solveLinear`. v0.0.2 (future) ships d up to ≈64 + an arena-
//! allocated workspace.
//!
//! v0.0.1 keeps the substrate single-bandit per (site, variant); the
//! existing `Replanner` substrate handles routing. LinUCB swaps in
//! where you previously had a single ArmPosterior.

const std = @import("std");

/// Maximum context dimension. v0.0.1 caps at 8 to keep the inverse
/// O(d^3) cheap + the storage layout fixed-size.
pub const max_dim: usize = 8;

pub const Error = error{
    DimensionMismatch,
    SingularMatrix,
    OutOfMemory,
};

/// Disjoint LinUCB arm. Per-arm A + b + d.  v0.0.1 stores A as a
/// flat row-major `[max_dim*max_dim]` so the algebra avoids slicing.
pub const LinUcbArm = struct {
    d: usize,
    A: [max_dim * max_dim]f64,
    b: [max_dim]f64,

    pub fn init(d: usize, ridge_lambda: f64) LinUcbArm {
        std.debug.assert(d >= 1 and d <= max_dim);
        var arm: LinUcbArm = .{ .d = d, .A = .{0} ** (max_dim * max_dim), .b = .{0} ** max_dim };
        // A starts as λ * I (the ridge-regression prior).
        var i: usize = 0;
        while (i < d) : (i += 1) arm.A[i * max_dim + i] = ridge_lambda;
        return arm;
    }

    /// θ = A^-1 b.  Caller-supplied scratch holds the working matrix.
    /// Returns θ in `out_theta[0..d]`.
    pub fn theta(self: LinUcbArm, out_theta: *[max_dim]f64) Error!void {
        // Solve A θ = b via Gauss-Jordan elimination.
        var aug: [max_dim * (max_dim + 1)]f64 = undefined;
        const d = self.d;
        var i: usize = 0;
        while (i < d) : (i += 1) {
            var j: usize = 0;
            while (j < d) : (j += 1) aug[i * (d + 1) + j] = self.A[i * max_dim + j];
            aug[i * (d + 1) + d] = self.b[i];
        }
        try gaussJordanSolve(&aug, d);
        var k: usize = 0;
        while (k < d) : (k += 1) out_theta.*[k] = aug[k * (d + 1) + d];
    }

    /// UCB score for the supplied context vector x.
    /// score = θ^T x + α √(x^T A^-1 x).
    pub fn ucb(
        self: LinUcbArm,
        x: []const f64,
        alpha: f64,
    ) Error!f64 {
        if (x.len != self.d) return Error.DimensionMismatch;
        var theta_buf: [max_dim]f64 = undefined;
        try self.theta(&theta_buf);

        // mean = θ · x
        var mean: f64 = 0;
        var i: usize = 0;
        while (i < self.d) : (i += 1) mean += theta_buf[i] * x[i];

        // Compute v = A^-1 x via Gauss-Jordan (re-solve, since v0.0.1
        // doesn't cache A^-1).
        var aug: [max_dim * (max_dim + 1)]f64 = undefined;
        var r: usize = 0;
        while (r < self.d) : (r += 1) {
            var c: usize = 0;
            while (c < self.d) : (c += 1) aug[r * (self.d + 1) + c] = self.A[r * max_dim + c];
            aug[r * (self.d + 1) + self.d] = x[r];
        }
        try gaussJordanSolve(&aug, self.d);
        var v: [max_dim]f64 = undefined;
        r = 0;
        while (r < self.d) : (r += 1) v[r] = aug[r * (self.d + 1) + self.d];

        // bonus = α √(x · v)
        var dot: f64 = 0;
        r = 0;
        while (r < self.d) : (r += 1) dot += x[r] * v[r];
        if (dot < 0) dot = 0; // numerical floor
        const bonus = alpha * std.math.sqrt(dot);

        return mean + bonus;
    }

    pub fn update(self: *LinUcbArm, x: []const f64, reward: f64) Error!void {
        if (x.len != self.d) return Error.DimensionMismatch;
        // A ← A + x x^T
        var i: usize = 0;
        while (i < self.d) : (i += 1) {
            var j: usize = 0;
            while (j < self.d) : (j += 1) {
                self.A[i * max_dim + j] += x[i] * x[j];
            }
        }
        // b ← b + r · x
        i = 0;
        while (i < self.d) : (i += 1) self.b[i] += reward * x[i];
    }
};

/// In-place Gauss-Jordan elimination on a `d × (d+1)` augmented
/// matrix stored row-major as `[d * (d+1)]f64`. After return, the
/// solution sits in column `d` of each row. Partial pivot for
/// numerical stability.
fn gaussJordanSolve(aug: []f64, d: usize) Error!void {
    var row: usize = 0;
    while (row < d) : (row += 1) {
        // Partial-pivot: find the row with the largest |aug[r][row]|
        // for r >= row.
        var pivot_row: usize = row;
        var pivot_mag: f64 = @abs(aug[row * (d + 1) + row]);
        var r: usize = row + 1;
        while (r < d) : (r += 1) {
            const mag = @abs(aug[r * (d + 1) + row]);
            if (mag > pivot_mag) {
                pivot_mag = mag;
                pivot_row = r;
            }
        }
        if (pivot_mag < 1e-12) return Error.SingularMatrix;
        if (pivot_row != row) {
            // Swap rows.
            var c: usize = 0;
            while (c <= d) : (c += 1) {
                const tmp = aug[row * (d + 1) + c];
                aug[row * (d + 1) + c] = aug[pivot_row * (d + 1) + c];
                aug[pivot_row * (d + 1) + c] = tmp;
            }
        }
        // Scale pivot row.
        const piv = aug[row * (d + 1) + row];
        var c: usize = 0;
        while (c <= d) : (c += 1) aug[row * (d + 1) + c] /= piv;
        // Eliminate other rows.
        r = 0;
        while (r < d) : (r += 1) {
            if (r == row) continue;
            const factor = aug[r * (d + 1) + row];
            if (factor == 0) continue;
            c = 0;
            while (c <= d) : (c += 1) aug[r * (d + 1) + c] -= factor * aug[row * (d + 1) + c];
        }
    }
}

/// Choose the highest-UCB arm from `arms` for the given context.
pub fn selectArm(arms: []const LinUcbArm, x: []const f64, alpha: f64) Error!usize {
    var best_idx: usize = 0;
    var best_score: f64 = -std.math.inf(f64);
    for (arms, 0..) |arm, i| {
        const s = try arm.ucb(x, alpha);
        if (s > best_score) {
            best_score = s;
            best_idx = i;
        }
    }
    return best_idx;
}

// --- Tests ----------------------------------------------------------------

const testing = std.testing;

test "init seeds A as ridge-prior λI + b = 0" {
    const arm: LinUcbArm = .init(3, 1.0);
    try testing.expectEqual(@as(f64, 1.0), arm.A[0 * max_dim + 0]);
    try testing.expectEqual(@as(f64, 1.0), arm.A[1 * max_dim + 1]);
    try testing.expectEqual(@as(f64, 1.0), arm.A[2 * max_dim + 2]);
    try testing.expectEqual(@as(f64, 0.0), arm.A[0 * max_dim + 1]);
    try testing.expectEqual(@as(f64, 0.0), arm.b[0]);
}

test "theta is zero for an untouched arm" {
    const arm: LinUcbArm = .init(2, 1.0);
    var theta_buf: [max_dim]f64 = undefined;
    try arm.theta(&theta_buf);
    try testing.expectApproxEqAbs(@as(f64, 0.0), theta_buf[0], 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0.0), theta_buf[1], 1e-12);
}

test "update on one observation drives theta toward observed reward" {
    var arm: LinUcbArm = .init(2, 1.0);
    // Context x = (1, 0); reward = 10. Expect θ to grow in dim 0.
    const x = [_]f64{ 1.0, 0.0 };
    try arm.update(&x, 10.0);
    var theta_buf: [max_dim]f64 = undefined;
    try arm.theta(&theta_buf);
    // With ridge λ=1: A = I + x x^T; (1,1,(0,0)) → solve.
    // A·θ = b ⇒ (2,0; 0,1) θ = (10, 0) ⇒ θ = (5, 0).
    try testing.expectApproxEqAbs(@as(f64, 5.0), theta_buf[0], 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0.0), theta_buf[1], 1e-12);
}

test "ucb returns mean + non-negative bonus" {
    var arm: LinUcbArm = .init(2, 1.0);
    const x = [_]f64{ 1.0, 0.0 };
    try arm.update(&x, 4.0);
    // mean predicted = θ·x = (4/2)·1 = 2; bonus = α √(x·(A^-1 x)).
    const u = try arm.ucb(&x, 1.0);
    try testing.expect(u >= 2.0);
}

test "selectArm picks higher-UCB arm" {
    var arm_a: LinUcbArm = .init(2, 1.0);
    var arm_b: LinUcbArm = .init(2, 1.0);
    const x = [_]f64{ 1.0, 0.0 };
    // Arm A gets +10 rewards; Arm B stays at zero.
    var i: usize = 0;
    while (i < 5) : (i += 1) try arm_a.update(&x, 10.0);
    while (i < 5) : (i += 1) try arm_b.update(&x, 0.0);
    const arms = [_]LinUcbArm{ arm_a, arm_b };
    const chosen = try selectArm(&arms, &x, 0.1);
    try testing.expectEqual(@as(usize, 0), chosen);
}

test "convergence — LinUCB learns the better arm under stable context" {
    var arm_a: LinUcbArm = .init(2, 1.0);
    var arm_b: LinUcbArm = .init(2, 1.0);
    const x = [_]f64{ 1.0, 1.0 };
    // 50 rounds: arm_a always rewards 1; arm_b always rewards 0.
    var picks: [50]usize = undefined;
    var t: usize = 0;
    while (t < picks.len) : (t += 1) {
        const arms = [_]LinUcbArm{ arm_a, arm_b };
        const idx = try selectArm(&arms, &x, 0.5);
        picks[t] = idx;
        if (idx == 0) try arm_a.update(&x, 1.0) else try arm_b.update(&x, 0.0);
    }
    // After enough trials, the last 20 should mostly be arm 0.
    var arm_a_count: usize = 0;
    var k: usize = 30;
    while (k < 50) : (k += 1) if (picks[k] == 0) {
        arm_a_count += 1;
    };
    try testing.expect(arm_a_count >= 17); // >= 85%
}

test "DimensionMismatch on x.len != d" {
    var arm: LinUcbArm = .init(3, 1.0);
    const x = [_]f64{ 1.0, 2.0 }; // d=2 != 3
    try testing.expectError(Error.DimensionMismatch, arm.update(&x, 1.0));
    try testing.expectError(Error.DimensionMismatch, arm.ucb(&x, 1.0));
}

test "gaussJordan solves a known 2x2 system" {
    // A = (2, 1; 1, 3), b = (5, 10). Expect (1, 3).
    var aug = [_]f64{ 2.0, 1.0, 5.0, 1.0, 3.0, 10.0 };
    try gaussJordanSolve(&aug, 2);
    try testing.expectApproxEqAbs(@as(f64, 1.0), aug[0 * 3 + 2], 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 3.0), aug[1 * 3 + 2], 1e-9);
}
