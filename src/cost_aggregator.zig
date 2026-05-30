//! cost_aggregator: v0.0.25 — additive cost composition primitive.
//!
//! cost_model (v0.0.4) carries per-rule cost; topology_selector
//! (v0.0.23) picks topologies by single-rule cost. Missing for
//! multi-stage plans: a way to sum costs across a chain of
//! stages where each stage may also have a discrete latency
//! component plus a probabilistic cost (mean + stddev).
//!
//! Port a small CostAccumulator that tracks running sum of
//! deterministic cost, sum of variances (for stddev compose),
//! and worst-case latency. Composes additively across plan
//! stages.
//!
//! Scope of this revision:
//!   CostSample { cost, variance, latency_us }.
//!   CostAccumulator { running_cost, running_variance,
//!     worst_latency_us, n_stages }.
//!   addStage(sample) increments the accumulator additively
//!     (cost + cost, variance + variance, max latency).
//!   stddev() returns sqrt(running_variance).
//!   reset() zeros the accumulator.
//!
//! Out of scope: per-stage skew correlation (caller composes a
//! covariance term if needed), non-additive cost models (caller
//! provides a custom reducer).

const std = @import("std");

pub const CostSample = struct {
    cost: f64,
    variance: f64 = 0.0,
    latency_us: u64 = 0,
};

pub const CostAccumulator = struct {
    running_cost: f64 = 0.0,
    running_variance: f64 = 0.0,
    worst_latency_us: u64 = 0,
    n_stages: u32 = 0,

    pub fn init() CostAccumulator {
        return .{};
    }

    pub fn addStage(self: *CostAccumulator, s: CostSample) void {
        if (std.math.isFinite(s.cost)) self.running_cost += s.cost;
        if (std.math.isFinite(s.variance) and s.variance > 0.0) self.running_variance += s.variance;
        if (s.latency_us > self.worst_latency_us) self.worst_latency_us = s.latency_us;
        self.n_stages += 1;
    }

    pub fn stddev(self: CostAccumulator) f64 {
        if (self.running_variance <= 0.0) return 0.0;
        return @sqrt(self.running_variance);
    }

    pub fn reset(self: *CostAccumulator) void {
        self.running_cost = 0.0;
        self.running_variance = 0.0;
        self.worst_latency_us = 0;
        self.n_stages = 0;
    }
};

// --- Tests -----------------------------------------------------------------

const testing = std.testing;

test "empty accumulator is zero" {
    const a: CostAccumulator = .init();
    try testing.expectEqual(@as(f64, 0.0), a.running_cost);
    try testing.expectEqual(@as(f64, 0.0), a.stddev());
    try testing.expectEqual(@as(u64, 0), a.worst_latency_us);
    try testing.expectEqual(@as(u32, 0), a.n_stages);
}

test "addStage sums cost additively" {
    var a: CostAccumulator = .init();
    a.addStage(.{ .cost = 1.0 });
    a.addStage(.{ .cost = 2.5 });
    a.addStage(.{ .cost = 0.5 });
    try testing.expectApproxEqAbs(@as(f64, 4.0), a.running_cost, 1e-12);
    try testing.expectEqual(@as(u32, 3), a.n_stages);
}

test "addStage sums variance additively (independent stages)" {
    var a: CostAccumulator = .init();
    a.addStage(.{ .cost = 0.0, .variance = 1.0 });
    a.addStage(.{ .cost = 0.0, .variance = 4.0 });
    try testing.expectApproxEqAbs(@as(f64, 5.0), a.running_variance, 1e-12);
    try testing.expectApproxEqAbs(@as(f64, @sqrt(5.0)), a.stddev(), 1e-12);
}

test "addStage takes max latency" {
    var a: CostAccumulator = .init();
    a.addStage(.{ .cost = 0.0, .latency_us = 100 });
    a.addStage(.{ .cost = 0.0, .latency_us = 50 });
    a.addStage(.{ .cost = 0.0, .latency_us = 200 });
    try testing.expectEqual(@as(u64, 200), a.worst_latency_us);
}

test "non-finite cost is dropped" {
    var a: CostAccumulator = .init();
    a.addStage(.{ .cost = 1.0 });
    a.addStage(.{ .cost = std.math.nan(f64) });
    a.addStage(.{ .cost = std.math.inf(f64) });
    a.addStage(.{ .cost = 2.0 });
    try testing.expectApproxEqAbs(@as(f64, 3.0), a.running_cost, 1e-12);
}

test "negative variance is dropped" {
    var a: CostAccumulator = .init();
    a.addStage(.{ .cost = 0.0, .variance = -5.0 });
    try testing.expectEqual(@as(f64, 0.0), a.running_variance);
}

test "reset zeros all running fields" {
    var a: CostAccumulator = .init();
    a.addStage(.{ .cost = 5.0, .variance = 1.0, .latency_us = 100 });
    a.reset();
    try testing.expectEqual(@as(f64, 0.0), a.running_cost);
    try testing.expectEqual(@as(f64, 0.0), a.running_variance);
    try testing.expectEqual(@as(u64, 0), a.worst_latency_us);
    try testing.expectEqual(@as(u32, 0), a.n_stages);
}

test "multi-stage plan with mixed cost/variance/latency" {
    var a: CostAccumulator = .init();
    a.addStage(.{ .cost = 10.0, .variance = 1.5, .latency_us = 250 });
    a.addStage(.{ .cost = 5.0, .variance = 0.5, .latency_us = 100 });
    a.addStage(.{ .cost = 2.0, .variance = 0.1, .latency_us = 500 });
    try testing.expectApproxEqAbs(@as(f64, 17.0), a.running_cost, 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 2.1), a.running_variance, 1e-12);
    try testing.expectEqual(@as(u64, 500), a.worst_latency_us);
}
