//! cost_model — per-plan cost estimate driven by cardinality + the
//! arrangement-cache hit rate.
//!
//! v0.0.3 chose between hash-join and delta-join by counting NEW
//! arrangements each plan must build. v0.0.4 adds a real cost model:
//!
//!   cost(plan) = build_cost * new_arrangements * (1 - hit_rate)
//!              + scan_cost  * total_cardinality
//!              + shuffle_cost * (kind == .hash_join ? 1 : 0)
//!
//! The arrangement-cache hit rate dampens the build cost for the
//! plan that can reuse existing arrangements. With a cold cache,
//! delta-join + hash-join still compete on cardinality + shuffle.
//!
//! `CostAwareReplanner` picks a plan by Thompson-sampling per-(plan
//! signature) ArmPosterior with the cost-model estimate as the
//! reward signal. Lower cost = success; the bandit reinforces.

const std = @import("std");
const arrangement = @import("arrangement.zig");
const delta_join = @import("delta_join.zig");
const bandit = @import("thompson_bandit");

pub const PlanKind = delta_join.PlanKind;
pub const JoinInput = delta_join.JoinInput;
pub const JoinPlan = delta_join.JoinPlan;

pub const CostWeights = struct {
    /// Per-arrangement build cost (cycles, abstract units).
    build_cost: f64 = 1000.0,
    /// Per-row scan cost.
    scan_cost: f64 = 1.0,
    /// Hash-join requires a shuffle; delta-join doesn't.
    shuffle_cost: f64 = 500.0,
};

pub const CostEstimate = struct {
    plan: JoinPlan,
    cardinality_sum: u64,
    cost: f64,
};

/// `estimate(plan, cardinalities, weights, hit_rate)` returns a cost
/// estimate. `cardinalities[i]` is the row count of `inputs[i]`.
pub fn estimate(
    plan: JoinPlan,
    cardinalities: []const u64,
    weights: CostWeights,
    hit_rate: f64,
) CostEstimate {
    var total_card: u64 = 0;
    for (cardinalities) |c| total_card +|= c;

    const build = weights.build_cost *
        @as(f64, @floatFromInt(plan.new_arrangements)) *
        @max(0.0, 1.0 - hit_rate);
    const scan = weights.scan_cost * @as(f64, @floatFromInt(total_card));
    const shuffle = if (plan.kind == .hash_join) weights.shuffle_cost else 0.0;
    return .{ .plan = plan, .cardinality_sum = total_card, .cost = build + scan + shuffle };
}

pub const PlanSignature = u64;

/// Compute a deterministic signature for `(kind, streaming_input)`.
pub fn signatureFor(plan: JoinPlan) PlanSignature {
    var s: u64 = if (plan.kind == .hash_join) 0xA1B1 else 0xB2A2;
    s ^= @as(u64, plan.streaming_input) +% 0x9E3779B97F4A7C15;
    s = (s ^ (s >> 30)) *% 0xBF58476D1CE4E5B9;
    return s ^ (s >> 27);
}

/// Pick a plan via cost-weighted Thompson sampling.
///
/// For each candidate plan:
/// 1. Sample its `ArmPosterior` once.
/// 2. Weight the sample by `1 / cost(plan)` — lower cost = larger
///    weight.
/// 3. Pick the plan with the highest weighted score.
///
/// Caller-supplied `posteriors` is a `PlanSignature → ArmPosterior`
/// map that this function mutates (uniform prior on first contact).
pub fn pickByCostThompson(
    rng: *std.Random.DefaultPrng,
    posteriors: *std.AutoHashMap(PlanSignature, bandit.ArmPosterior),
    candidates: []const CostEstimate,
) !JoinPlan {
    if (candidates.len == 0) return error.EmptyCandidates;

    var best_idx: usize = 0;
    var best_score: f64 = -std.math.inf(f64);
    for (candidates, 0..) |c, i| {
        const sig = signatureFor(c.plan);
        const gop = try posteriors.getOrPut(sig);
        if (!gop.found_existing) gop.value_ptr.* = .uniform();
        const draw = gop.value_ptr.sample(rng);
        // Avoid divide-by-zero; cost should always be >0 because of
        // the scan_cost term unless total_card == 0 AND no shuffle
        // AND no new arrangements.
        const score = draw / @max(1.0, c.cost);
        if (score > best_score) {
            best_score = score;
            best_idx = i;
        }
    }
    return candidates[best_idx].plan;
}

/// Update the posterior for a plan based on observed cost.
/// `target_cost` defines the success threshold; lower than target =
/// posterior success.
pub fn recordObservedCost(
    posteriors: *std.AutoHashMap(PlanSignature, bandit.ArmPosterior),
    plan: JoinPlan,
    observed_cost: f64,
    target_cost: f64,
) !void {
    const sig = signatureFor(plan);
    const gop = try posteriors.getOrPut(sig);
    if (!gop.found_existing) gop.value_ptr.* = .uniform();
    if (observed_cost < target_cost) gop.value_ptr.recordSuccess() else gop.value_ptr.recordFailure();
}

// --- Tests ----------------------------------------------------------------

const testing = std.testing;

test "estimate — empty plan with no arrangements + no cardinality is shuffle-cost only" {
    const plan: JoinPlan = .{ .kind = .hash_join, .streaming_input = 0, .new_arrangements = 0 };
    const cost = estimate(plan, &.{}, .{}, 0.0);
    try testing.expectEqual(@as(f64, 500.0), cost.cost);
}

test "estimate — delta_join with no arrangements + no cardinality is zero cost" {
    const plan: JoinPlan = .{ .kind = .delta_join, .streaming_input = 0, .new_arrangements = 0 };
    const cost = estimate(plan, &.{}, .{}, 0.0);
    try testing.expectEqual(@as(f64, 0.0), cost.cost);
}

test "estimate — hit-rate dampens build cost for new arrangements" {
    const plan: JoinPlan = .{ .kind = .delta_join, .streaming_input = 0, .new_arrangements = 2 };
    const cold = estimate(plan, &.{}, .{}, 0.0);
    const warm = estimate(plan, &.{}, .{}, 0.9);
    try testing.expect(warm.cost < cold.cost);
    try testing.expectEqual(@as(f64, 2000.0), cold.cost);
    try testing.expectApproxEqAbs(@as(f64, 200.0), warm.cost, 1e-9);
}

test "estimate — cardinality scales scan cost linearly" {
    const plan: JoinPlan = .{ .kind = .delta_join, .streaming_input = 0, .new_arrangements = 0 };
    const card_small = estimate(plan, &.{100}, .{}, 0.0);
    const card_big = estimate(plan, &.{ 100, 100 }, .{}, 0.0);
    try testing.expect(card_big.cost > card_small.cost);
    try testing.expectApproxEqAbs(@as(f64, 100.0), card_small.cost, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 200.0), card_big.cost, 1e-9);
}

test "signatureFor — same plan kind + streaming_input → same signature" {
    const a: JoinPlan = .{ .kind = .delta_join, .streaming_input = 3, .new_arrangements = 1 };
    const b: JoinPlan = .{ .kind = .delta_join, .streaming_input = 3, .new_arrangements = 7 };
    try testing.expectEqual(signatureFor(a), signatureFor(b));
}

test "signatureFor — hash vs delta yields distinct signatures" {
    const h: JoinPlan = .{ .kind = .hash_join, .streaming_input = 2, .new_arrangements = 1 };
    const d: JoinPlan = .{ .kind = .delta_join, .streaming_input = 2, .new_arrangements = 1 };
    try testing.expect(signatureFor(h) != signatureFor(d));
}

test "pickByCostThompson selects from candidates" {
    const alloc = testing.allocator;
    var posteriors: std.AutoHashMap(PlanSignature, bandit.ArmPosterior) = .init(alloc);
    defer posteriors.deinit();
    var rng = bandit.rngFromSeed(7);

    const a: JoinPlan = .{ .kind = .delta_join, .streaming_input = 0, .new_arrangements = 1 };
    const b: JoinPlan = .{ .kind = .hash_join, .streaming_input = 0, .new_arrangements = 1 };
    const candidates = [_]CostEstimate{
        .{ .plan = a, .cardinality_sum = 100, .cost = 1_000.0 },
        .{ .plan = b, .cardinality_sum = 100, .cost = 1_500.0 },
    };
    const chosen = try pickByCostThompson(&rng, &posteriors, &candidates);
    try testing.expect(chosen.kind == .delta_join or chosen.kind == .hash_join);
}

test "recordObservedCost reinforces a low-cost plan + de-reinforces a high one" {
    const alloc = testing.allocator;
    var posteriors: std.AutoHashMap(PlanSignature, bandit.ArmPosterior) = .init(alloc);
    defer posteriors.deinit();

    const cheap: JoinPlan = .{ .kind = .delta_join, .streaming_input = 0, .new_arrangements = 0 };
    const expensive: JoinPlan = .{ .kind = .hash_join, .streaming_input = 0, .new_arrangements = 4 };
    // Cheap plan observed at 100 < target 1000 → success.
    try recordObservedCost(&posteriors, cheap, 100.0, 1000.0);
    // Expensive plan observed at 5000 > target → failure.
    try recordObservedCost(&posteriors, expensive, 5000.0, 1000.0);

    const cheap_post = posteriors.get(signatureFor(cheap)).?;
    const exp_post = posteriors.get(signatureFor(expensive)).?;
    try testing.expect(cheap_post.mean() > 0.5);
    try testing.expect(exp_post.mean() < 0.5);
}

test "convergence — bandit favors the consistently-lower-cost plan over many trials" {
    const alloc = testing.allocator;
    var posteriors: std.AutoHashMap(PlanSignature, bandit.ArmPosterior) = .init(alloc);
    defer posteriors.deinit();
    var rng = bandit.rngFromSeed(2026);

    const cheap: JoinPlan = .{ .kind = .delta_join, .streaming_input = 0, .new_arrangements = 1 };
    const expensive: JoinPlan = .{ .kind = .hash_join, .streaming_input = 0, .new_arrangements = 1 };

    // Seed the posteriors over 50 simulated trials to make the test
    // bounded.
    var i: usize = 0;
    while (i < 50) : (i += 1) {
        try recordObservedCost(&posteriors, cheap, 200.0, 1000.0);
        try recordObservedCost(&posteriors, expensive, 5000.0, 1000.0);
    }

    var cheap_picks: usize = 0;
    var t: usize = 0;
    while (t < 200) : (t += 1) {
        const candidates = [_]CostEstimate{
            .{ .plan = cheap, .cardinality_sum = 100, .cost = 200.0 },
            .{ .plan = expensive, .cardinality_sum = 100, .cost = 5000.0 },
        };
        const chosen = try pickByCostThompson(&rng, &posteriors, &candidates);
        if (chosen.kind == .delta_join) cheap_picks += 1;
    }
    try testing.expect(cheap_picks >= 170); // >= 85% — bandit + cost both prefer cheap
}
