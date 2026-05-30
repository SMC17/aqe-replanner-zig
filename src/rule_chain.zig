//! rule_chain: v0.0.26 — ordered rule-application primitive.
//!
//! rule_library (v0.0.7) holds rules, pattern_match
//! (v0.0.8/0.0.9) fires individual rules, optimizer_rule
//! (v0.0.7) provides the trait. Missing for plan rewriting:
//! the deterministic ordered chain that applies rules in a
//! caller-specified sequence with fixed-point detection (stop
//! when no rule changed the plan).
//!
//! Port a small RuleChain helper that takes a slice of rule
//! functions over a generic PlanT and runs them to fixed point
//! within a caller-supplied max-iteration bound.
//!
//! Scope of this revision:
//!   RuleFn(comptime PlanT): fn(*PlanT) bool — returns true iff
//!     the plan changed.
//!   applyChain(plan, rules, max_iters) runs the chain to
//!     fixed point. Returns the iteration count (0 if no
//!     change ever happened, max_iters if it hit the cap).
//!
//! Out of scope: cost-aware rule ordering (cost_model already
//! ranks; caller composes), parallel rule application (sequential
//! by design for determinism), rule-conflict detection.

const std = @import("std");

pub fn RuleFn(comptime PlanT: type) type {
    return *const fn (*PlanT) bool;
}

/// Apply each rule in order, looping the whole chain until no
/// rule changes the plan or max_iters is reached. Returns the
/// number of whole-chain passes executed.
pub fn applyChain(
    comptime PlanT: type,
    plan: *PlanT,
    rules: []const RuleFn(PlanT),
    max_iters: usize,
) usize {
    var iters: usize = 0;
    while (iters < max_iters) : (iters += 1) {
        var changed = false;
        for (rules) |r| {
            if (r(plan)) changed = true;
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

fn decBy1(p: *TestPlan) bool {
    if (p.value <= 0) return false;
    p.value -= 1;
    return true;
}

fn always(_: *TestPlan) bool {
    return true;
}

fn never(_: *TestPlan) bool {
    return false;
}

test "applyChain reaches fixed point on monotone rule" {
    var p: TestPlan = .{ .value = 5 };
    const rules = [_]RuleFn(TestPlan){decBy1};
    const iters = applyChain(TestPlan, &p, &rules, 100);
    try testing.expectEqual(@as(i32, 0), p.value);
    try testing.expect(iters > 0 and iters < 100);
}

test "applyChain returns 0 when no rule changes the plan" {
    var p: TestPlan = .{ .value = 5 };
    const rules = [_]RuleFn(TestPlan){never};
    const iters = applyChain(TestPlan, &p, &rules, 100);
    try testing.expectEqual(@as(usize, 0), iters);
    try testing.expectEqual(@as(i32, 5), p.value);
}

test "applyChain stops at max_iters when a rule never settles" {
    var p: TestPlan = .{ .value = 0 };
    const rules = [_]RuleFn(TestPlan){always};
    const iters = applyChain(TestPlan, &p, &rules, 7);
    try testing.expectEqual(@as(usize, 7), iters);
}

test "applyChain runs every rule in order each iteration" {
    var p: TestPlan = .{ .value = 3 };
    const rules = [_]RuleFn(TestPlan){ decBy1, never };
    const iters = applyChain(TestPlan, &p, &rules, 100);
    try testing.expectEqual(@as(i32, 0), p.value);
    try testing.expect(iters > 0);
}

test "applyChain on empty rule set returns 0 immediately" {
    var p: TestPlan = .{ .value = 5 };
    const rules: []const RuleFn(TestPlan) = &.{};
    const iters = applyChain(TestPlan, &p, rules, 100);
    try testing.expectEqual(@as(usize, 0), iters);
    try testing.expectEqual(@as(i32, 5), p.value);
}

test "applyChain max_iters 0 is a no-op" {
    var p: TestPlan = .{ .value = 5 };
    const rules = [_]RuleFn(TestPlan){decBy1};
    const iters = applyChain(TestPlan, &p, &rules, 0);
    try testing.expectEqual(@as(usize, 0), iters);
    try testing.expectEqual(@as(i32, 5), p.value);
}
