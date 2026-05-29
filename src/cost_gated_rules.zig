//! cost_gated_rules — gate rule firings on bandit-driven cost.
//!
//! v0.0.3 RuleEngine fires every rule that matches its pattern, every
//! pass. That's the Catalyst / Materialize default: every
//! transformation is a strict improvement so blind application
//! converges to a fixed point.
//!
//! In an adaptive query optimiser, rules can flip from "useful at
//! cardinality 1M" to "harmful at cardinality 10M" — the
//! arrangement-reuse rule needs to know whether the candidate plan
//! it would produce will actually beat the current plan.
//!
//! v0.0.6 wraps a rule with a `CostGatedRule`:
//!
//! 1. Before applying the rule, estimate the BEFORE cost.
//! 2. Speculatively apply the rule (on a clone if mutation is
//!    expensive; v0.0.6 mutates and reverts on rollback).
//! 3. Estimate the AFTER cost.
//! 4. Fire the rule iff AFTER < BEFORE * threshold OR the bandit
//!    posterior on this rule (keyed by name hash) Thompson-samples
//!    in favour of firing.
//!
//! The bandit recovers the rule when historical evidence dominates
//! the heuristic threshold.

const std = @import("std");
const rule = @import("rule.zig");
const bandit = @import("thompson_bandit");

pub const PlanNode = rule.PlanNode;
pub const Rule = rule.Rule;

/// Returns an approximate cost of the supplied plan node. v0.0.6
/// ships a stand-in that costs each node by its shape:
///   scan = 100 * |projected|
///   filter = 50 + cost(input)
///   project = 30 * |columns| + cost(input)
pub fn estimateNodeCost(node: PlanNode) f64 {
    return switch (node) {
        .scan => |s| 100.0 * @as(f64, @floatFromInt(s.projected.len)),
        .filter => |f| 50.0 + estimateNodeCost(f.input.*),
        .project => |p| 30.0 * @as(f64, @floatFromInt(p.columns.len)) + estimateNodeCost(p.input.*),
    };
}

/// A name-keyed Thompson posterior for whether the rule should fire.
pub const RulePosteriors = std.AutoHashMap(u64, bandit.ArmPosterior);

pub fn ruleSignature(name: []const u8) u64 {
    return std.hash.Wyhash.hash(0xCAFE_BEEF, name);
}

pub const Verdict = enum { fired, blocked };

/// Apply `inner` rule iff cost gate or bandit allows. Returns
/// `.fired` if the rule fired (and the node was mutated).
pub fn applyGated(
    allocator: std.mem.Allocator,
    inner: Rule,
    node: *PlanNode,
    posteriors: *RulePosteriors,
    rng: *std.Random.DefaultPrng,
    cost_drop_threshold: f64, // e.g. 0.95 = require ≥5% drop
) !Verdict {
    const sig = ruleSignature(inner.name);
    const before = estimateNodeCost(node.*);

    // Snapshot for possible rollback.
    const snapshot = node.*;
    const fired = inner.apply(allocator, node);
    if (!fired) return .blocked;

    const after = estimateNodeCost(node.*);

    // Cost gate: rule wins on cost reduction.
    const cost_won = after < before * cost_drop_threshold;

    // Bandit gate: sample posterior; high posterior means historical
    // evidence the rule has been useful.
    const gop = try posteriors.getOrPut(sig);
    if (!gop.found_existing) gop.value_ptr.* = .uniform();
    const bandit_sample = gop.value_ptr.sample(rng);
    const bandit_won = bandit_sample > 0.5;

    if (cost_won or bandit_won) {
        // Reinforce: rule was useful (or bandit thinks it was).
        if (after < before) gop.value_ptr.recordSuccess() else gop.value_ptr.recordFailure();
        return .fired;
    } else {
        // Rollback and reinforce against the rule.
        node.* = snapshot;
        gop.value_ptr.recordFailure();
        return .blocked;
    }
}

pub const CostGatedRuleEngine = struct {
    allocator: std.mem.Allocator,
    rules: std.array_list.Managed(Rule),
    posteriors: RulePosteriors,
    cost_drop_threshold: f64 = 0.95,
    max_iterations: u32 = 32,

    pub fn init(allocator: std.mem.Allocator) CostGatedRuleEngine {
        return .{ .allocator = allocator, .rules = .init(allocator), .posteriors = .init(allocator) };
    }

    pub fn deinit(self: *CostGatedRuleEngine) void {
        self.rules.deinit();
        self.posteriors.deinit();
    }

    pub fn addRule(self: *CostGatedRuleEngine, r: Rule) !void {
        try self.rules.append(r);
    }

    /// Returns the number of passes performed.
    pub fn run(self: *CostGatedRuleEngine, root: *PlanNode, rng: *std.Random.DefaultPrng) !u32 {
        var iter: u32 = 0;
        while (iter < self.max_iterations) : (iter += 1) {
            var any_fired = false;
            for (self.rules.items) |r| {
                const v = try applyGated(self.allocator, r, root, &self.posteriors, rng, self.cost_drop_threshold);
                if (v == .fired) any_fired = true;
            }
            if (!any_fired) return iter + 1;
        }
        return self.max_iterations;
    }

    pub fn meanFor(self: *CostGatedRuleEngine, name: []const u8) ?f64 {
        const p = self.posteriors.get(ruleSignature(name)) orelse return null;
        return p.mean();
    }
};

// --- Tests ----------------------------------------------------------------

const testing = std.testing;

test "estimateNodeCost scan + filter + project" {
    var scan: PlanNode = .{ .scan = .{ .table = 1, .projected = &[_]u32{ 1, 2, 3 } } };
    try testing.expectEqual(@as(f64, 300.0), estimateNodeCost(scan));
    var filter: PlanNode = .{ .filter = .{ .input = &scan, .predicate = 1 } };
    try testing.expectEqual(@as(f64, 350.0), estimateNodeCost(filter));
    const project: PlanNode = .{ .project = .{ .input = &filter, .columns = &[_]u32{ 1, 2 } } };
    try testing.expectEqual(@as(f64, 410.0), estimateNodeCost(project));
}

test "applyGated fires cost-reducing rule" {
    const alloc = testing.allocator;
    var posteriors: RulePosteriors = .init(alloc);
    defer posteriors.deinit();
    var rng = bandit.rngFromSeed(7);

    var scan: PlanNode = .{ .scan = .{ .table = 1, .projected = &[_]u32{ 1, 2, 3, 4 } } };
    var filter_node: PlanNode = .{ .filter = .{ .input = &scan, .predicate = 0 } };
    // dropEmptyFilter rule should reduce cost (filter overhead 50 →
    // removed).
    const r: Rule = .{ .name = "drop-empty", .apply = rule.dropEmptyFilter };
    const verdict = try applyGated(alloc, r, &filter_node, &posteriors, &rng, 0.95);
    try testing.expectEqual(Verdict.fired, verdict);
    // After: filter_node is now the scan.
    try testing.expect(filter_node == .scan);
}

test "applyGated blocks rule that doesn't reduce cost (and bandit is cold)" {
    const alloc = testing.allocator;
    var posteriors: RulePosteriors = .init(alloc);
    defer posteriors.deinit();
    var rng = bandit.rngFromSeed(2);

    // A rule that's a no-op but pretends to fire — should be blocked
    // by the cost gate since BEFORE == AFTER.
    const Identity = struct {
        fn f(_: std.mem.Allocator, _: *PlanNode) bool {
            return true; // claim "fired" but mutate nothing
        }
    };
    const r: Rule = .{ .name = "identity-noop", .apply = Identity.f };

    var scan: PlanNode = .{ .scan = .{ .table = 1, .projected = &[_]u32{1} } };
    // First call: bandit cold, will Thompson-sample close to 0.5;
    // result depends on the seed but we expect rejection often.
    // Run multiple times and check the posterior has been hit at all.
    var i: usize = 0;
    var blocked: usize = 0;
    while (i < 30) : (i += 1) {
        const v = try applyGated(alloc, r, &scan, &posteriors, &rng, 0.95);
        if (v == .blocked) blocked += 1;
    }
    try testing.expect(blocked > 0);
}

test "CostGatedRuleEngine reaches fixed point on cost-positive rules" {
    const alloc = testing.allocator;
    var eng: CostGatedRuleEngine = .init(alloc);
    defer eng.deinit();
    try eng.addRule(.{ .name = "drop-empty", .apply = rule.dropEmptyFilter });

    var scan: PlanNode = .{ .scan = .{ .table = 1, .projected = &[_]u32{1} } };
    var filter_node: PlanNode = .{ .filter = .{ .input = &scan, .predicate = 0 } };
    var rng = bandit.rngFromSeed(11);
    const passes = try eng.run(&filter_node, &rng);
    try testing.expect(passes <= 3);
    try testing.expect(filter_node == .scan);
}

test "convergence — bandit recovers a sometimes-useful rule over many trials" {
    const alloc = testing.allocator;
    var posteriors: RulePosteriors = .init(alloc);
    defer posteriors.deinit();
    var rng = bandit.rngFromSeed(2026);
    const r: Rule = .{ .name = "drop-empty", .apply = rule.dropEmptyFilter };

    // 30 trials where the rule reduces cost; each produces a success.
    var t: usize = 0;
    while (t < 30) : (t += 1) {
        var scan: PlanNode = .{ .scan = .{ .table = 1, .projected = &[_]u32{1} } };
        var filter_node: PlanNode = .{ .filter = .{ .input = &scan, .predicate = 0 } };
        _ = try applyGated(alloc, r, &filter_node, &posteriors, &rng, 0.95);
    }

    const sig = ruleSignature(r.name);
    const post = posteriors.get(sig).?;
    try testing.expect(post.mean() > 0.5);
}
