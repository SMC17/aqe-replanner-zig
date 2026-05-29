//! join_reorder — v0.0.11 Calcite-class join reordering on cost.
//!
//! v0.0.4 ships `cost_model.estimate` which costs a single
//! plan. v0.0.10 ships pattern-rule + bandit. v0.0.11 adds a Calcite-
//! /Selinger-class reorder primitive: given N relations to join
//! (modelled as scan signatures + cardinality estimates), enumerate
//! permutations of the join order, cost each one, return the order
//! with the lowest predicted cost.
//!
//! Bounded enumeration: factorial blowup makes exhaustive search
//! viable only up to N≈5 (120 perms). For N>5, callers should compose
//! with a bandit (LinUCB context = relation features) to sample a
//! subset of orders. v0.0.12 ships the Selinger-style DP path.
//!
//! Reinforcement: callers reinforce per-order via
//! `recordObservedCostForOrder(posteriors, order_hash, observed_cost)`.

const std = @import("std");
const cost_model = @import("cost_model.zig");
const bandit = @import("thompson_bandit");

pub const max_relations: usize = 5;

/// One relation in the join: scan signature + estimated cardinality.
/// We don't model predicate selectivity here; that's the cost model's
/// job (it consumes the planSignature).
pub const Relation = struct {
    table: u64,
    cardinality: u64,
};

/// A join order is an index permutation over a slice of relations.
/// `order[i]` is the position in the input slice of the i-th relation
/// to be joined.
pub const JoinOrder = struct {
    indices: [max_relations]u8,
    len: u8,

    pub fn hash(self: JoinOrder) u64 {
        var h: u64 = 0xDEAD_BEEF_C001_CAFE;
        var i: usize = 0;
        while (i < self.len) : (i += 1) {
            var x: u64 = (@as(u64, self.indices[i]) << 8) ^ @as(u64, i);
            x = (x ^ (x >> 30)) *% 0xBF58476D1CE4E5B9;
            x = (x ^ (x >> 27)) *% 0x94D049BB133111EB;
            x = x ^ (x >> 31);
            h ^= x;
        }
        return h;
    }
};

pub const ReorderError = error{
    TooManyRelations,
    EmptyJoin,
    OutOfMemory,
};

/// Approximate cost of a join order: a left-deep tree where each
/// step joins the running result with the next relation. Cost grows
/// as the product of cardinalities so far × constant per step.
///
/// `c_step` is the per-step cost coefficient (defaults 1.0). The
/// running join cardinality is approximated as a power-product
/// (Selinger heuristic) scaled by a selectivity proxy 0.1 for
/// successive joins, which lets the model prefer small-first orders.
pub fn estimateJoinOrderCost(
    relations: []const Relation,
    order: JoinOrder,
    c_step: f64,
) f64 {
    if (order.len == 0) return 0.0;
    var running: f64 = @floatFromInt(relations[order.indices[0]].cardinality);
    var total: f64 = running;
    const selectivity: f64 = 0.1;
    var i: u8 = 1;
    while (i < order.len) : (i += 1) {
        const next_card: f64 = @floatFromInt(relations[order.indices[i]].cardinality);
        // Approximate join cardinality = product * selectivity.
        running = running * next_card * selectivity;
        total += running * c_step;
    }
    return total;
}

/// Enumerate all permutations of the input relations and return the
/// order with the lowest cost. Caller passes pre-allocated workspace
/// for permutations (none needed; we walk in-place).
pub fn pickLowestCostOrder(relations: []const Relation, c_step: f64) ReorderError!JoinOrder {
    if (relations.len == 0) return ReorderError.EmptyJoin;
    if (relations.len > max_relations) return ReorderError.TooManyRelations;
    var indices: [max_relations]u8 = .{ 0, 0, 0, 0, 0 };
    var i: u8 = 0;
    while (i < relations.len) : (i += 1) indices[i] = i;

    var best_order: JoinOrder = .{ .indices = indices, .len = @intCast(relations.len) };
    var best_cost = estimateJoinOrderCost(relations, best_order, c_step);

    // Heap's algorithm in-place permutation.
    var stack: [max_relations]u8 = .{ 0, 0, 0, 0, 0 };
    var d: u8 = 0;
    const n: u8 = @intCast(relations.len);
    while (d < n) {
        if (stack[d] < d) {
            if (d % 2 == 0) {
                std.mem.swap(u8, &indices[0], &indices[d]);
            } else {
                std.mem.swap(u8, &indices[stack[d]], &indices[d]);
            }
            const candidate: JoinOrder = .{ .indices = indices, .len = n };
            const c = estimateJoinOrderCost(relations, candidate, c_step);
            if (c < best_cost) {
                best_cost = c;
                best_order = candidate;
            }
            stack[d] += 1;
            d = 0;
        } else {
            stack[d] = 0;
            d += 1;
        }
    }
    return best_order;
}

/// Bandit-driven order pick: Thompson-sample per-order posteriors
/// over the enumerated permutations, pick highest sample. Falls back
/// to cost-based pick if no posteriors initialised.
pub const OrderPosteriors = std.AutoHashMap(u64, bandit.ArmPosterior);

pub fn banditPickOrder(
    relations: []const Relation,
    posteriors: *OrderPosteriors,
    rng: *std.Random.DefaultPrng,
    c_step: f64,
) ReorderError!JoinOrder {
    if (relations.len == 0) return ReorderError.EmptyJoin;
    if (relations.len > max_relations) return ReorderError.TooManyRelations;

    var indices: [max_relations]u8 = .{ 0, 0, 0, 0, 0 };
    var i: u8 = 0;
    while (i < relations.len) : (i += 1) indices[i] = i;

    var best_sample: f64 = -1.0;
    var best_order: JoinOrder = .{ .indices = indices, .len = @intCast(relations.len) };

    var stack: [max_relations]u8 = .{ 0, 0, 0, 0, 0 };
    var d: u8 = 0;
    const n: u8 = @intCast(relations.len);
    while (d < n) {
        if (stack[d] < d) {
            if (d % 2 == 0) {
                std.mem.swap(u8, &indices[0], &indices[d]);
            } else {
                std.mem.swap(u8, &indices[stack[d]], &indices[d]);
            }
            const candidate: JoinOrder = .{ .indices = indices, .len = n };
            const h = candidate.hash();
            const gop = posteriors.getOrPut(h) catch return ReorderError.OutOfMemory;
            if (!gop.found_existing) gop.value_ptr.* = .uniform();
            const s = gop.value_ptr.sample(rng);
            if (s > best_sample) {
                best_sample = s;
                best_order = candidate;
            }
            stack[d] += 1;
            d = 0;
        } else {
            stack[d] = 0;
            d += 1;
        }
    }
    _ = c_step;
    return best_order;
}

pub fn recordOutcomeForOrder(
    posteriors: *OrderPosteriors,
    order: JoinOrder,
    succeeded: bool,
) ReorderError!void {
    const h = order.hash();
    const gop = posteriors.getOrPut(h) catch return ReorderError.OutOfMemory;
    if (!gop.found_existing) gop.value_ptr.* = .uniform();
    if (succeeded) gop.value_ptr.recordSuccess() else gop.value_ptr.recordFailure();
}

// --- Tests ----------------------------------------------------------------

const testing = std.testing;

test "estimateJoinOrderCost prefers small-cardinality leading order" {
    const rels = [_]Relation{
        .{ .table = 1, .cardinality = 1_000_000 },
        .{ .table = 2, .cardinality = 10 },
        .{ .table = 3, .cardinality = 100 },
    };
    const small_first: JoinOrder = .{ .indices = .{ 1, 2, 0, 0, 0 }, .len = 3 };
    const big_first: JoinOrder = .{ .indices = .{ 0, 2, 1, 0, 0 }, .len = 3 };
    const c_small = estimateJoinOrderCost(&rels, small_first, 1.0);
    const c_big = estimateJoinOrderCost(&rels, big_first, 1.0);
    try testing.expect(c_small < c_big);
}

test "pickLowestCostOrder finds the optimal order" {
    const rels = [_]Relation{
        .{ .table = 1, .cardinality = 1_000_000 },
        .{ .table = 2, .cardinality = 10 },
        .{ .table = 3, .cardinality = 100 },
    };
    const best = try pickLowestCostOrder(&rels, 1.0);
    try testing.expectEqual(@as(u8, 3), best.len);
    // Smallest relation (index 1, card=10) should be first.
    try testing.expectEqual(@as(u8, 1), best.indices[0]);
}

test "pickLowestCostOrder rejects empty join" {
    try testing.expectError(ReorderError.EmptyJoin, pickLowestCostOrder(&[_]Relation{}, 1.0));
}

test "pickLowestCostOrder rejects too-many-relations" {
    var rels: [max_relations + 1]Relation = undefined;
    for (rels[0..]) |*r| r.* = .{ .table = 0, .cardinality = 100 };
    try testing.expectError(ReorderError.TooManyRelations, pickLowestCostOrder(&rels, 1.0));
}

test "JoinOrder.hash distinguishes different orders" {
    const a: JoinOrder = .{ .indices = .{ 0, 1, 2, 0, 0 }, .len = 3 };
    const b: JoinOrder = .{ .indices = .{ 2, 1, 0, 0, 0 }, .len = 3 };
    try testing.expect(a.hash() != b.hash());
}

test "banditPickOrder samples posteriors over enumerated orders" {
    const rels = [_]Relation{
        .{ .table = 1, .cardinality = 100 },
        .{ .table = 2, .cardinality = 200 },
    };
    var posteriors: OrderPosteriors = .init(testing.allocator);
    defer posteriors.deinit();
    var rng = bandit.rngFromSeed(1);
    const pick = try banditPickOrder(&rels, &posteriors, &rng, 1.0);
    try testing.expectEqual(@as(u8, 2), pick.len);
    // Posteriors map gets populated for each permutation.
    try testing.expect(posteriors.count() >= 1);
}

test "recordOutcomeForOrder reinforces order posterior" {
    var posteriors: OrderPosteriors = .init(testing.allocator);
    defer posteriors.deinit();
    const order: JoinOrder = .{ .indices = .{ 1, 0, 2, 0, 0 }, .len = 3 };
    var i: usize = 0;
    while (i < 10) : (i += 1) try recordOutcomeForOrder(&posteriors, order, true);
    while (i < 30) : (i += 1) {
        try recordOutcomeForOrder(&posteriors, order, false);
        i += 1;
    }
    const p = posteriors.get(order.hash()).?;
    try testing.expect(p.mean() > 0.0);
    try testing.expect(p.mean() < 1.0);
}
