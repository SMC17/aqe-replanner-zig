//! costed_rule_chain: v0.0.29 — rule_chain x CostAccumulator composition.
//!
//! v0.0.26 rule_chain applies rules to fixed point; v0.0.25
//! CostAccumulator sums multi-stage cost + variance + latency.
//! Real planners want both: apply rules to fixed point AND
//! track the cost of each rule application so the final cost
//! is integrated.
//!
//! Scope of this revision:
//!   CostedRuleFn(PlanT): fn(*PlanT) ?CostSample — returns the
//!     CostSample for the change, or null if no change.
//!   applyCostedChain(plan, rules, accumulator, max_iters)
//!     runs the slice to fixed point, accumulating cost on
//!     every rule that returns non-null. Returns the iteration
//!     count.
//!
//! Out of scope: per-rule rollback on cost-explosion (caller
//! checks accumulator after each rule and rolls back if
//! needed), parallel application (sequential by design).

const std = @import("std");
const cost_aggregator = @import("cost_aggregator.zig");

pub const CostSample = cost_aggregator.CostSample;
pub const CostAccumulator = cost_aggregator.CostAccumulator;

pub fn CostedRuleFn(comptime PlanT: type) type {
    return *const fn (*PlanT) ?CostSample;
}

pub fn applyCostedChain(
    comptime PlanT: type,
    plan: *PlanT,
    rules: []const CostedRuleFn(PlanT),
    accumulator: *CostAccumulator,
    max_iters: usize,
) usize {
    var iters: usize = 0;
    while (iters < max_iters) : (iters += 1) {
        var changed = false;
        for (rules) |r| {
            if (r(plan)) |sample| {
                accumulator.addStage(sample);
                changed = true;
            }
        }
        if (!changed) return iters;
    }
    return max_iters;
}

// --- Tests -----------------------------------------------------------------

const testing = std.testing;

const TestPlan = struct {
    value: i32,
};

fn decRule(p: *TestPlan) ?CostSample {
    if (p.value <= 0) return null;
    p.value -= 1;
    return .{ .cost = 1.5, .variance = 0.1, .latency_us = 100 };
}

fn neverRule(_: *TestPlan) ?CostSample {
    return null;
}

test "applyCostedChain accumulates cost across iterations" {
    var p: TestPlan = .{ .value = 3 };
    var acc: CostAccumulator = .init();
    const rules = [_]CostedRuleFn(TestPlan){decRule};
    const iters = applyCostedChain(TestPlan, &p, &rules, &acc, 100);
    try testing.expectEqual(@as(i32, 0), p.value);
    try testing.expect(iters > 0);
    try testing.expectApproxEqAbs(@as(f64, 4.5), acc.running_cost, 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0.3), acc.running_variance, 1e-12);
    try testing.expectEqual(@as(u64, 100), acc.worst_latency_us);
    try testing.expectEqual(@as(u32, 3), acc.n_stages);
}

test "applyCostedChain returns 0 with no-op rules" {
    var p: TestPlan = .{ .value = 5 };
    var acc: CostAccumulator = .init();
    const rules = [_]CostedRuleFn(TestPlan){neverRule};
    const iters = applyCostedChain(TestPlan, &p, &rules, &acc, 100);
    try testing.expectEqual(@as(usize, 0), iters);
    try testing.expectEqual(@as(f64, 0.0), acc.running_cost);
}

test "applyCostedChain stops at max_iters when rule never settles" {
    const Inf = struct {
        fn r(_: *TestPlan) ?CostSample {
            return .{ .cost = 0.1 };
        }
    };
    var p: TestPlan = .{ .value = 0 };
    var acc: CostAccumulator = .init();
    const rules = [_]CostedRuleFn(TestPlan){Inf.r};
    const iters = applyCostedChain(TestPlan, &p, &rules, &acc, 5);
    try testing.expectEqual(@as(usize, 5), iters);
    try testing.expectApproxEqAbs(@as(f64, 0.5), acc.running_cost, 1e-12);
}

test "applyCostedChain skips null-returning rules within an iteration" {
    var p: TestPlan = .{ .value = 1 };
    var acc: CostAccumulator = .init();
    const rules = [_]CostedRuleFn(TestPlan){ neverRule, decRule, neverRule };
    const iters = applyCostedChain(TestPlan, &p, &rules, &acc, 100);
    try testing.expectEqual(@as(i32, 0), p.value);
    try testing.expectEqual(@as(u32, 1), acc.n_stages);
    try testing.expect(iters > 0);
}

test "applyCostedChain on empty rule set returns 0 and no cost" {
    var p: TestPlan = .{ .value = 5 };
    var acc: CostAccumulator = .init();
    const rules: []const CostedRuleFn(TestPlan) = &.{};
    const iters = applyCostedChain(TestPlan, &p, rules, &acc, 100);
    try testing.expectEqual(@as(usize, 0), iters);
    try testing.expectEqual(@as(f64, 0.0), acc.running_cost);
}
