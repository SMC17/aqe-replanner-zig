//! rle_column — v0.0.20 run-length-encoded i64 column primitive.
//!
//! Parquet RLE pages + Velox RLE encoding both compress sorted or
//! low-cardinality columns by storing (value, run_length) pairs
//! rather than per-row values. v0.0.20 ships the in-memory primitive
//! bound to i64.
//!
//! Best case: monotone constant runs collapse N rows to a single
//! (value, N) pair. Worst case: every row distinct → no savings (in
//! fact slightly worse than raw).
//!
//! Composition: wflog deletion-vector primitives are bit-packed; a
//! sorted-id workflow stream is RLE-compressible. The compaction
//! plan can emit RLE row-groups for storage-tier-friendly cold paths.

const std = @import("std");

pub const Error = error{ OutOfMemory, RowOutOfRange };

pub const Run = struct {
    value: i64,
    length: u32,
};

pub const RleColumnI64 = struct {
    runs: std.array_list.Managed(Run),
    total_rows: u64,

    pub fn init(allocator: std.mem.Allocator) RleColumnI64 {
        return .{
            .runs = .init(allocator),
            .total_rows = 0,
        };
    }

    pub fn deinit(self: *RleColumnI64) void {
        self.runs.deinit();
    }

    /// Append one row. Extends the trailing run if value matches.
    pub fn appendValue(self: *RleColumnI64, value: i64) Error!void {
        if (self.runs.items.len > 0) {
            const last = &self.runs.items[self.runs.items.len - 1];
            if (last.value == value and last.length < std.math.maxInt(u32)) {
                last.length += 1;
                self.total_rows += 1;
                return;
            }
        }
        self.runs.append(.{ .value = value, .length = 1 }) catch return Error.OutOfMemory;
        self.total_rows += 1;
    }

    pub fn valueAtRow(self: RleColumnI64, row: u64) Error!i64 {
        if (row >= self.total_rows) return Error.RowOutOfRange;
        var consumed: u64 = 0;
        for (self.runs.items) |r| {
            const end = consumed + r.length;
            if (row < end) return r.value;
            consumed = end;
        }
        unreachable;
    }

    pub fn runCount(self: RleColumnI64) usize {
        return self.runs.items.len;
    }

    pub fn byteSize(self: RleColumnI64) usize {
        return self.runs.items.len * @sizeOf(Run);
    }

    pub fn rawByteSize(self: RleColumnI64) usize {
        return @intCast(self.total_rows * 8);
    }
};

// --- Tests ----------------------------------------------------------------

const testing = std.testing;

test "RleColumnI64 collapses repeated values into one run" {
    var col: RleColumnI64 = .init(testing.allocator);
    defer col.deinit();
    var i: u64 = 0;
    while (i < 100) : (i += 1) try col.appendValue(42);
    try testing.expectEqual(@as(usize, 1), col.runCount());
    try testing.expectEqual(@as(u64, 100), col.total_rows);
}

test "RleColumnI64 starts a new run when value changes" {
    var col: RleColumnI64 = .init(testing.allocator);
    defer col.deinit();
    try col.appendValue(1);
    try col.appendValue(1);
    try col.appendValue(2);
    try col.appendValue(2);
    try col.appendValue(3);
    try testing.expectEqual(@as(usize, 3), col.runCount());
    try testing.expectEqual(@as(u64, 5), col.total_rows);
}

test "valueAtRow round-trips through multiple runs" {
    var col: RleColumnI64 = .init(testing.allocator);
    defer col.deinit();
    try col.appendValue(1);
    try col.appendValue(1);
    try col.appendValue(2);
    try col.appendValue(3);
    try col.appendValue(3);
    try col.appendValue(3);
    try testing.expectEqual(@as(i64, 1), try col.valueAtRow(0));
    try testing.expectEqual(@as(i64, 1), try col.valueAtRow(1));
    try testing.expectEqual(@as(i64, 2), try col.valueAtRow(2));
    try testing.expectEqual(@as(i64, 3), try col.valueAtRow(3));
    try testing.expectEqual(@as(i64, 3), try col.valueAtRow(4));
    try testing.expectEqual(@as(i64, 3), try col.valueAtRow(5));
}

test "valueAtRow rejects out-of-range row" {
    var col: RleColumnI64 = .init(testing.allocator);
    defer col.deinit();
    try col.appendValue(5);
    try testing.expectError(Error.RowOutOfRange, col.valueAtRow(99));
}

test "byteSize collapses dramatically for constant column" {
    var col: RleColumnI64 = .init(testing.allocator);
    defer col.deinit();
    var i: u64 = 0;
    while (i < 1000) : (i += 1) try col.appendValue(7);
    // Single run = 12 bytes (i64 + u32). Raw = 1000 * 8 = 8000.
    try testing.expect(col.byteSize() < col.rawByteSize());
}

test "byteSize matches rawByteSize for all-distinct column" {
    var col: RleColumnI64 = .init(testing.allocator);
    defer col.deinit();
    var i: i64 = 0;
    while (i < 10) : (i += 1) try col.appendValue(i);
    // 10 runs of length 1 each = 10 * 12 = 120 bytes; raw = 80 bytes.
    // RLE is WORSE for all-distinct, which is the expected tradeoff.
    try testing.expect(col.byteSize() > col.rawByteSize());
}

test "empty RleColumnI64 reports zero" {
    var col: RleColumnI64 = .init(testing.allocator);
    defer col.deinit();
    try testing.expectEqual(@as(u64, 0), col.total_rows);
    try testing.expectEqual(@as(usize, 0), col.runCount());
}
