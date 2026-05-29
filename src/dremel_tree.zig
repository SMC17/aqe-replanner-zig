//! dremel_tree — v0.0.21 port of P796 (BigQuery Dremel multi-stage tree).
//!
//! Ports P796 (Dremel multi-stage execution tree from L58-bigquery-
//! snowflake-hybrid-MINED.md). Dremel splits query execution into
//! three levels:
//!   1. **Leaf workers** scan columnar storage and emit per-partition
//!      partial aggregates.
//!   2. **Mixers** fan-in partial aggregates from multiple leaves and
//!      emit a tree-reduced partial.
//!   3. **Root** does the final reduction + emits the result.
//!
//! v0.0.21 ships the in-memory primitive bound to i64 SUM aggregates
//! over u64 partition keys. The same shape composes with Spark L841
//! DAG, Trino L1143 exchange, Doris L1467 MSQ — across-engine.
//!
//! Composition with shipped substrate: AQE v0.0.13 Batch is the leaf
//! input shape; AQE v0.0.11 join_reorder picks the reduction tree
//! topology; AQE v0.0.10 cost gate decides whether to fan-in vs
//! aggregate locally.

const std = @import("std");

pub const Error = error{ OutOfMemory };

pub const PartitionKey = u64;
pub const AggValue = i64;

pub const PartialAgg = struct {
    key: PartitionKey,
    sum: AggValue,
    count: u32,
};

/// Leaf worker: scans a slice of (key, value) tuples and emits one
/// PartialAgg per distinct key.
pub fn leafAggregate(
    allocator: std.mem.Allocator,
    keys: []const PartitionKey,
    values: []const AggValue,
) Error![]PartialAgg {
    std.debug.assert(keys.len == values.len);
    var map: std.AutoHashMap(PartitionKey, PartialAgg) = .init(allocator);
    defer map.deinit();
    for (keys, values) |k, v| {
        const gop = map.getOrPut(k) catch return Error.OutOfMemory;
        if (!gop.found_existing) {
            gop.value_ptr.* = .{ .key = k, .sum = 0, .count = 0 };
        }
        gop.value_ptr.sum += v;
        gop.value_ptr.count += 1;
    }
    var out = allocator.alloc(PartialAgg, map.count()) catch return Error.OutOfMemory;
    var i: usize = 0;
    var it = map.valueIterator();
    while (it.next()) |p| {
        out[i] = p.*;
        i += 1;
    }
    return out;
}

/// Mixer: fan-in K partial-agg slices and merge by key into a single
/// slice. Used between leaf and root in the Dremel tree (Mixer
/// nodes).
pub fn mix(
    allocator: std.mem.Allocator,
    partials: []const []const PartialAgg,
) Error![]PartialAgg {
    var map: std.AutoHashMap(PartitionKey, PartialAgg) = .init(allocator);
    defer map.deinit();
    for (partials) |slice| {
        for (slice) |pa| {
            const gop = map.getOrPut(pa.key) catch return Error.OutOfMemory;
            if (!gop.found_existing) {
                gop.value_ptr.* = .{ .key = pa.key, .sum = 0, .count = 0 };
            }
            gop.value_ptr.sum += pa.sum;
            gop.value_ptr.count += pa.count;
        }
    }
    var out = allocator.alloc(PartialAgg, map.count()) catch return Error.OutOfMemory;
    var i: usize = 0;
    var it = map.valueIterator();
    while (it.next()) |p| {
        out[i] = p.*;
        i += 1;
    }
    return out;
}

/// Root: final reduction. Same algebra as Mixer; the distinction is
/// positional (root is the last reducer in the tree).
pub fn root(
    allocator: std.mem.Allocator,
    partials: []const []const PartialAgg,
) Error![]PartialAgg {
    return mix(allocator, partials);
}

// --- Tests ----------------------------------------------------------------

const testing = std.testing;

test "leafAggregate sums per-key values from raw input" {
    const alloc = testing.allocator;
    const keys = [_]PartitionKey{ 1, 2, 1, 3, 2, 1 };
    const vals = [_]AggValue{ 10, 20, 30, 40, 50, 60 };
    const result = try leafAggregate(alloc, &keys, &vals);
    defer alloc.free(result);
    try testing.expectEqual(@as(usize, 3), result.len);
    var sum_for_1: AggValue = 0;
    var sum_for_2: AggValue = 0;
    var sum_for_3: AggValue = 0;
    for (result) |r| {
        switch (r.key) {
            1 => sum_for_1 = r.sum,
            2 => sum_for_2 = r.sum,
            3 => sum_for_3 = r.sum,
            else => unreachable,
        }
    }
    try testing.expectEqual(@as(AggValue, 100), sum_for_1); // 10 + 30 + 60
    try testing.expectEqual(@as(AggValue, 70), sum_for_2); // 20 + 50
    try testing.expectEqual(@as(AggValue, 40), sum_for_3);
}

test "mix combines two partial slices by key" {
    const alloc = testing.allocator;
    const left = [_]PartialAgg{
        .{ .key = 1, .sum = 100, .count = 3 },
        .{ .key = 2, .sum = 50, .count = 2 },
    };
    const right = [_]PartialAgg{
        .{ .key = 1, .sum = 25, .count = 1 },
        .{ .key = 3, .sum = 80, .count = 2 },
    };
    const partials = [_][]const PartialAgg{ &left, &right };
    const result = try mix(alloc, &partials);
    defer alloc.free(result);
    try testing.expectEqual(@as(usize, 3), result.len);
    for (result) |r| {
        switch (r.key) {
            1 => try testing.expectEqual(@as(AggValue, 125), r.sum),
            2 => try testing.expectEqual(@as(AggValue, 50), r.sum),
            3 => try testing.expectEqual(@as(AggValue, 80), r.sum),
            else => unreachable,
        }
    }
}

test "full Dremel pipeline: leaf → mixer → root" {
    const alloc = testing.allocator;
    // Two leaf scans.
    const left_keys = [_]PartitionKey{ 1, 2, 1 };
    const left_vals = [_]AggValue{ 10, 20, 30 };
    const right_keys = [_]PartitionKey{ 1, 3 };
    const right_vals = [_]AggValue{ 5, 50 };

    const leaf_left = try leafAggregate(alloc, &left_keys, &left_vals);
    defer alloc.free(leaf_left);
    const leaf_right = try leafAggregate(alloc, &right_keys, &right_vals);
    defer alloc.free(leaf_right);

    // Mixer.
    const mixer_input = [_][]const PartialAgg{ leaf_left, leaf_right };
    const mixer_out = try mix(alloc, &mixer_input);
    defer alloc.free(mixer_out);

    // Root (single mixer in this small tree).
    const root_input = [_][]const PartialAgg{mixer_out};
    const final = try root(alloc, &root_input);
    defer alloc.free(final);

    try testing.expectEqual(@as(usize, 3), final.len);
    for (final) |r| {
        switch (r.key) {
            1 => try testing.expectEqual(@as(AggValue, 45), r.sum), // 10 + 30 + 5
            2 => try testing.expectEqual(@as(AggValue, 20), r.sum),
            3 => try testing.expectEqual(@as(AggValue, 50), r.sum),
            else => unreachable,
        }
    }
}

test "leafAggregate on empty input yields empty slice" {
    const alloc = testing.allocator;
    const result = try leafAggregate(alloc, &[_]PartitionKey{}, &[_]AggValue{});
    defer alloc.free(result);
    try testing.expectEqual(@as(usize, 0), result.len);
}

test "mix on single partial slice is a copy" {
    const alloc = testing.allocator;
    const input = [_]PartialAgg{
        .{ .key = 1, .sum = 100, .count = 3 },
        .{ .key = 2, .sum = 50, .count = 2 },
    };
    const partials = [_][]const PartialAgg{&input};
    const result = try mix(alloc, &partials);
    defer alloc.free(result);
    try testing.expectEqual(@as(usize, 2), result.len);
}

test "mix preserves count alongside sum" {
    const alloc = testing.allocator;
    const left = [_]PartialAgg{.{ .key = 1, .sum = 100, .count = 5 }};
    const right = [_]PartialAgg{.{ .key = 1, .sum = 200, .count = 3 }};
    const partials = [_][]const PartialAgg{ &left, &right };
    const result = try mix(alloc, &partials);
    defer alloc.free(result);
    try testing.expectEqual(@as(usize, 1), result.len);
    try testing.expectEqual(@as(u32, 8), result[0].count);
    try testing.expectEqual(@as(AggValue, 300), result[0].sum);
}
