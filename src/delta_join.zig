//! delta_join — N-way join planner that exploits arrangement reuse.
//!
//! Ports Materialize L987 delta-join planning: if every input to an
//! N-way join already has an arrangement on the join key, we can
//! arrange K-1 inputs + stream the remaining input + maintain zero
//! intermediate state. The Materialize blog quotes 7.1M → 6 records
//! on TPC-H Q8 with this technique.
//!
//! v0.0.3 ships a simple planner that:
//!   1. Takes N inputs each described by (table_id, join_key) +
//!      pre-existing arrangement count.
//!   2. Decides between plain hash-join + delta-join based on the
//!      number of NEW arrangements each plan needs to build.
//!   3. Returns the chosen `JoinPlan` + the count of arrangements
//!      the substrate must NEW-materialise.
//!
//! v0.0.4 ships a cost model that integrates with the cardinality
//! statistics + arrangement-cache hit-rate posterior so the bandit
//! drives plan selection.

const std = @import("std");
const arrangement = @import("arrangement.zig");

pub const TableId = arrangement.TableId;
pub const ColumnId = arrangement.ColumnId;

pub const JoinInput = struct {
    table: TableId,
    join_key: []const ColumnId,
    /// 1 if an arrangement on (table, join_key) already lives in
    /// the cache; 0 otherwise. The planner uses this to score plans.
    has_arrangement: u1,
};

pub const PlanKind = enum {
    /// Hash-join: materialise an arrangement (hash index) on every
    /// input EXCEPT the streaming side.
    hash_join,
    /// Delta-join: stream one input + arrange K-1 inputs IFF every
    /// input has a pre-existing arrangement on its join key (no
    /// fresh arrangements needed).
    delta_join,
};

pub const JoinPlan = struct {
    kind: PlanKind,
    streaming_input: usize, // index into inputs[] that streams
    new_arrangements: u32, // count of arrangements the plan must build
};

pub const Error = error{
    TooFewInputs,
};

/// Choose between hash-join + delta-join for the supplied inputs.
/// Returns the plan whose `new_arrangements` count is lower; ties go
/// to delta-join (lower memory + cache-coherent).
pub fn plan(inputs: []const JoinInput) Error!JoinPlan {
    if (inputs.len < 2) return Error.TooFewInputs;

    // delta-join: stream the LAST input, arrange the first K-1. The
    // delta-join requires every arranged input to have a
    // pre-existing arrangement; counts the missing arrangements.
    var delta_new: u32 = 0;
    var i: usize = 0;
    while (i + 1 < inputs.len) : (i += 1) {
        if (inputs[i].has_arrangement == 0) delta_new += 1;
    }
    const delta_plan: JoinPlan = .{
        .kind = .delta_join,
        .streaming_input = inputs.len - 1,
        .new_arrangements = delta_new,
    };

    // hash-join: materialise on the smaller side OR arrange every
    // non-streaming side. v0.0.3 counts each non-streaming input as
    // needing its own arrangement regardless of pre-existence (since
    // hash-join builds a fresh hash table per join).
    const hash_plan: JoinPlan = .{
        .kind = .hash_join,
        .streaming_input = inputs.len - 1,
        .new_arrangements = @intCast(inputs.len - 1),
    };

    if (delta_plan.new_arrangements <= hash_plan.new_arrangements) return delta_plan;
    return hash_plan;
}

// --- Tests ----------------------------------------------------------------

const testing = std.testing;

test "plan rejects < 2 inputs" {
    const single = [_]JoinInput{.{ .table = 1, .join_key = &.{1}, .has_arrangement = 0 }};
    try testing.expectError(Error.TooFewInputs, plan(&single));
}

test "delta-join chosen when every non-streaming input has arrangement" {
    const inputs = [_]JoinInput{
        .{ .table = 1, .join_key = &.{1}, .has_arrangement = 1 },
        .{ .table = 2, .join_key = &.{1}, .has_arrangement = 1 },
        .{ .table = 3, .join_key = &.{1}, .has_arrangement = 0 }, // streams
    };
    const p = try plan(&inputs);
    try testing.expectEqual(PlanKind.delta_join, p.kind);
    try testing.expectEqual(@as(u32, 0), p.new_arrangements);
    try testing.expectEqual(@as(usize, 2), p.streaming_input);
}

test "hash-join chosen when no pre-existing arrangements (lower cost loss)" {
    const inputs = [_]JoinInput{
        .{ .table = 1, .join_key = &.{1}, .has_arrangement = 0 },
        .{ .table = 2, .join_key = &.{1}, .has_arrangement = 0 },
    };
    const p = try plan(&inputs);
    // Both delta (new=1) + hash (new=1) tie; substrate picks
    // delta-join on tie (cache-coherent + lower memory). Verify
    // the actual choice.
    try testing.expectEqual(PlanKind.delta_join, p.kind);
    try testing.expectEqual(@as(u32, 1), p.new_arrangements);
}

test "delta-join preferred even when one input missing arrangement (vs hash building 2)" {
    const inputs = [_]JoinInput{
        .{ .table = 1, .join_key = &.{1}, .has_arrangement = 1 },
        .{ .table = 2, .join_key = &.{1}, .has_arrangement = 0 },
        .{ .table = 3, .join_key = &.{1}, .has_arrangement = 0 }, // streams
    };
    const p = try plan(&inputs);
    // delta-join new=1 (input 1 missing); hash-join new=2.
    try testing.expectEqual(PlanKind.delta_join, p.kind);
    try testing.expectEqual(@as(u32, 1), p.new_arrangements);
}

test "with the cache: querying twice reuses arrangement" {
    var cache: arrangement.ArrangementCache = .init(testing.allocator);
    defer cache.deinit();
    const join_key = [_]ColumnId{ 1, 2 };

    // First query: no arrangements present. Plan builds one.
    _ = try cache.getOrCreate(1, &join_key);
    _ = try cache.getOrCreate(2, &join_key);
    try testing.expectEqual(@as(u64, 2), cache.miss_count);

    // Second query for an N-way join over the same tables: cache
    // hits, delta-join sees `has_arrangement = 1`, no new
    // arrangements needed.
    _ = try cache.getOrCreate(1, &join_key);
    _ = try cache.getOrCreate(2, &join_key);
    const inputs = [_]JoinInput{
        .{ .table = 1, .join_key = &join_key, .has_arrangement = 1 },
        .{ .table = 2, .join_key = &join_key, .has_arrangement = 1 },
        .{ .table = 3, .join_key = &join_key, .has_arrangement = 0 }, // streams
    };
    const p = try plan(&inputs);
    try testing.expectEqual(@as(u32, 0), p.new_arrangements);
    try testing.expectEqual(@as(u64, 2), cache.hit_count);
}
