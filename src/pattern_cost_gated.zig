//! pattern_cost_gated — v0.0.10 cost-aware pattern rule firing.
//!
//! v0.0.6 ships `cost_gated_rules.applyGated` for `Rule` (which
//! matches via the v0.0.3 RuleEngine pattern abstraction). v0.0.9
//! ships `pattern_recursive.applyRecursive` for `PatternRule` (which
//! matches via the v0.0.8 PlanPattern algebra).
//!
//! v0.0.10 closes the gap: gate `PatternRule.applyOnce` on the same
//! cost-model + bandit posterior that gates `Rule.apply`. Per-subtree
//! dispatch from `applyRecursive` is the call-site; each fire goes
//! through `applyPatternGated` which:
//!   1. Estimates BEFORE cost of the subtree.
//!   2. Speculatively applies the pattern rule + builder.
//!   3. Estimates AFTER cost.
//!   4. Keeps the rewrite iff AFTER < BEFORE*threshold OR the bandit
//!      posterior on this rule (keyed by name hash) Thompson-samples
//!      in favour.
//!
//! Reinforcement: callers reinforce via `recordOutcome(posteriors,
//! rule_name, succeeded)` against the per-rule posterior; the bandit
//! recovers rules whose historical wins dominate the cost heuristic.

const std = @import("std");
const pattern_match = @import("pattern_match.zig");
const pattern_recursive = @import("pattern_recursive.zig");
const cost_gated = @import("cost_gated_rules.zig");
const bandit = @import("thompson_bandit");

pub const PlanNode = pattern_match.PlanNode;
pub const PatternRule = pattern_match.PatternRule;
pub const Match = pattern_match.Match;
pub const RulePosteriors = cost_gated.RulePosteriors;
pub const ruleSignature = cost_gated.ruleSignature;
pub const Verdict = cost_gated.Verdict;
pub const estimateNodeCost = cost_gated.estimateNodeCost;

pub const Error = error{ OutOfMemory };

/// Apply a PatternRule iff the cost gate or the bandit allows.
/// Returns `.fired` if the rule applied (and node mutated).
pub fn applyPatternGated(
    allocator: std.mem.Allocator,
    rule: PatternRule,
    node: *PlanNode,
    posteriors: *RulePosteriors,
    rng: *std.Random.DefaultPrng,
    cost_drop_threshold: f64,
) Error!Verdict {
    const sig = ruleSignature(rule.name);
    const before = estimateNodeCost(node.*);
    const snapshot = node.*;
    const fired = rule.applyOnce(allocator, node);
    if (!fired) return .blocked;
    const after = estimateNodeCost(node.*);

    const cost_won = after < before * cost_drop_threshold;
    const gop = posteriors.getOrPut(sig) catch return Error.OutOfMemory;
    if (!gop.found_existing) gop.value_ptr.* = .uniform();
    const posterior_sample = gop.value_ptr.sample(rng);
    const bandit_won = posterior_sample > 0.5;

    if (cost_won or bandit_won) return .fired;
    // Rollback.
    node.* = snapshot;
    return .blocked;
}

/// Recursive cost-gated walk: descend into children, then attempt at
/// the current node. Each fire is gated through `applyPatternGated`.
/// Returns the count of accepted (post-gate) firings.
pub fn applyRecursiveGated(
    allocator: std.mem.Allocator,
    rule: PatternRule,
    node: *PlanNode,
    posteriors: *RulePosteriors,
    rng: *std.Random.DefaultPrng,
    cost_drop_threshold: f64,
) Error!usize {
    var total: usize = 0;
    switch (node.*) {
        .scan => {},
        .filter => |*f| {
            const inner = @constCast(f.input);
            total += try applyRecursiveGated(allocator, rule, inner, posteriors, rng, cost_drop_threshold);
        },
        .project => |*p| {
            const inner = @constCast(p.input);
            total += try applyRecursiveGated(allocator, rule, inner, posteriors, rng, cost_drop_threshold);
        },
    }
    const v = try applyPatternGated(allocator, rule, node, posteriors, rng, cost_drop_threshold);
    if (v == .fired) total += 1;
    return total;
}

pub fn recordOutcome(
    posteriors: *RulePosteriors,
    rule_name: []const u8,
    succeeded: bool,
) Error!void {
    const sig = ruleSignature(rule_name);
    const gop = posteriors.getOrPut(sig) catch return Error.OutOfMemory;
    if (!gop.found_existing) gop.value_ptr.* = .uniform();
    if (succeeded) gop.value_ptr.recordSuccess() else gop.value_ptr.recordFailure();
}

// --- Tests ----------------------------------------------------------------

const testing = std.testing;

fn buildDropFilter(allocator: std.mem.Allocator, m: Match) ?PlanNode {
    _ = allocator;
    const filter_node = m.captures[0] orelse return null;
    return switch (filter_node.*) {
        .filter => |f| f.input.*,
        else => null,
    };
}

test "cost-gated drop-filter fires when filter strictly reduces cost" {
    var scan: PlanNode = .{ .scan = .{ .table = 1, .projected = &[_]u32{1} } };
    var fil: PlanNode = .{ .filter = .{ .input = &scan, .predicate = 0 } };
    // Filter adds 50 to scan cost (100). Dropping it reduces 150→100.
    const fil_pat: pattern_match.PlanPattern = .{ .kind = .filter, .capture_index = 0 };
    const rule: PatternRule = .{ .name = "drop-filter", .pattern = fil_pat, .build = buildDropFilter };
    var posteriors: RulePosteriors = .init(testing.allocator);
    defer posteriors.deinit();
    var rng = bandit.rngFromSeed(1);
    const v = try applyPatternGated(testing.allocator, rule, &fil, &posteriors, &rng, 0.95);
    try testing.expectEqual(Verdict.fired, v);
    try testing.expect(fil == .scan);
}

test "cost-gated rule is blocked when AFTER >= BEFORE * threshold AND posterior low" {
    // Build a no-op-style rule that returns a more expensive plan.
    const heavy_scan: PlanNode = .{ .scan = .{ .table = 1, .projected = &[_]u32{ 1, 2, 3, 4, 5, 6, 7, 8 } } };
    var scan: PlanNode = .{ .scan = .{ .table = 1, .projected = &[_]u32{1} } };
    var fil: PlanNode = .{ .filter = .{ .input = &scan, .predicate = 0 } };
    const Builder = struct {
        var replacement: PlanNode = undefined;
        fn build(allocator: std.mem.Allocator, m: Match) ?PlanNode {
            _ = allocator;
            _ = m;
            return replacement;
        }
    };
    Builder.replacement = heavy_scan;
    const fil_pat: pattern_match.PlanPattern = .{ .kind = .filter, .capture_index = 0 };
    const bad_rule: PatternRule = .{ .name = "make-it-worse", .pattern = fil_pat, .build = Builder.build };
    var posteriors: RulePosteriors = .init(testing.allocator);
    defer posteriors.deinit();
    // Seed posterior with 20 failures / 0 successes so bandit blocks.
    var i: usize = 0;
    while (i < 20) : (i += 1) try recordOutcome(&posteriors, "make-it-worse", false);
    var rng = bandit.rngFromSeed(2026);

    const v = try applyPatternGated(testing.allocator, bad_rule, &fil, &posteriors, &rng, 0.95);
    try testing.expectEqual(Verdict.blocked, v);
    // Should have rolled back to the original filter.
    try testing.expect(fil == .filter);
}

test "cost-gated rule fires when bandit posterior recovers it despite weak cost win" {
    var scan: PlanNode = .{ .scan = .{ .table = 1, .projected = &[_]u32{1} } };
    var fil: PlanNode = .{ .filter = .{ .input = &scan, .predicate = 0 } };
    const fil_pat: pattern_match.PlanPattern = .{ .kind = .filter, .capture_index = 0 };
    const rule: PatternRule = .{ .name = "drop-filter", .pattern = fil_pat, .build = buildDropFilter };
    var posteriors: RulePosteriors = .init(testing.allocator);
    defer posteriors.deinit();
    // Seed strong bandit support.
    var i: usize = 0;
    while (i < 30) : (i += 1) try recordOutcome(&posteriors, "drop-filter", true);
    var rng = bandit.rngFromSeed(2027);

    // Even with a strict cost threshold (require 99.999% drop, ≈0
    // tolerance), the bandit will recover this fire.
    const v = try applyPatternGated(testing.allocator, rule, &fil, &posteriors, &rng, 0.00001);
    try testing.expectEqual(Verdict.fired, v);
}

test "applyRecursiveGated walks tree + gates each subtree" {
    // Tree: filter(filter(scan)) — both filters drop under cost gate.
    var scan: PlanNode = .{ .scan = .{ .table = 1, .projected = &[_]u32{1} } };
    var inner_fil: PlanNode = .{ .filter = .{ .input = &scan, .predicate = 1 } };
    var outer_fil: PlanNode = .{ .filter = .{ .input = &inner_fil, .predicate = 2 } };
    const fil_pat: pattern_match.PlanPattern = .{ .kind = .filter, .capture_index = 0 };
    const rule: PatternRule = .{ .name = "drop-filter", .pattern = fil_pat, .build = buildDropFilter };
    var posteriors: RulePosteriors = .init(testing.allocator);
    defer posteriors.deinit();
    var rng = bandit.rngFromSeed(7);

    const fired = try applyRecursiveGated(testing.allocator, rule, &outer_fil, &posteriors, &rng, 0.95);
    try testing.expectEqual(@as(usize, 2), fired);
    try testing.expect(outer_fil == .scan);
}

test "recordOutcome reinforces per-rule posterior" {
    var posteriors: RulePosteriors = .init(testing.allocator);
    defer posteriors.deinit();
    var i: usize = 0;
    while (i < 10) : (i += 1) try recordOutcome(&posteriors, "rule-a", true);
    while (i < 30) : (i += 1) {
        try recordOutcome(&posteriors, "rule-a", false);
        i += 1;
    }
    const p = posteriors.get(ruleSignature("rule-a")).?;
    try testing.expect(p.mean() > 0.0);
    try testing.expect(p.mean() < 1.0);
}
