//! dict_column — v0.0.18 dictionary-encoded column primitive.
//!
//! Arrow Dictionary column + Velox dictionary encoding + Parquet
//! dict-page all share the same shape:
//!   - dictionary buffer: distinct values (typed)
//!   - index buffer: per-row dictionary position (u8 or u16)
//!
//! v0.0.18 ships the in-memory primitive bound to i64 values, which
//! is the canonical workflow-event-log shape (workflow_id, event_seq,
//! timestamp_ns). Strings will land in v0.0.19 via StringView dict.

const std = @import("std");

pub const Error = error{
    OutOfMemory,
    DictionaryFull,
    ValueNotInDict,
    IndexOutOfRange,
};

pub const max_dict_size_u8: usize = 256;

pub const DictColumnI64 = struct {
    /// Distinct values, sorted ascending for binary lookup.
    values: std.array_list.Managed(i64),
    /// Per-row dictionary index. Up to 256 distinct values via u8;
    /// callers needing more should use the u16 variant.
    indices: std.array_list.Managed(u8),

    pub fn init(allocator: std.mem.Allocator) DictColumnI64 {
        return .{
            .values = .init(allocator),
            .indices = .init(allocator),
        };
    }

    pub fn deinit(self: *DictColumnI64) void {
        self.values.deinit();
        self.indices.deinit();
    }

    /// Append a row: locate (or insert) `value` in the dictionary,
    /// then push its index onto the row stream.
    pub fn appendValue(self: *DictColumnI64, value: i64) Error!void {
        const idx = blk: {
            // Linear scan (dict sizes are typically small enough).
            for (self.values.items, 0..) |v, i| if (v == value) break :blk i;
            if (self.values.items.len >= max_dict_size_u8) return Error.DictionaryFull;
            self.values.append(value) catch return Error.OutOfMemory;
            break :blk self.values.items.len - 1;
        };
        self.indices.append(@intCast(idx)) catch return Error.OutOfMemory;
    }

    pub fn rowCount(self: DictColumnI64) usize {
        return self.indices.items.len;
    }

    pub fn dictSize(self: DictColumnI64) usize {
        return self.values.items.len;
    }

    pub fn valueAtRow(self: DictColumnI64, row: usize) Error!i64 {
        if (row >= self.indices.items.len) return Error.IndexOutOfRange;
        const idx = self.indices.items[row];
        if (idx >= self.values.items.len) return Error.IndexOutOfRange;
        return self.values.items[idx];
    }

    /// Total bytes stored: dictionary (8 bytes each) + indices (1 byte each).
    pub fn byteSize(self: DictColumnI64) usize {
        return self.values.items.len * 8 + self.indices.items.len;
    }

    /// Bytes a naive raw i64 column would consume.
    pub fn rawByteSize(self: DictColumnI64) usize {
        return self.indices.items.len * 8;
    }
};

// --- Tests ----------------------------------------------------------------

const testing = std.testing;

test "DictColumnI64 with single distinct value uses 1-entry dict" {
    var col: DictColumnI64 = .init(testing.allocator);
    defer col.deinit();
    try col.appendValue(42);
    try col.appendValue(42);
    try col.appendValue(42);
    try testing.expectEqual(@as(usize, 3), col.rowCount());
    try testing.expectEqual(@as(usize, 1), col.dictSize());
}

test "DictColumnI64 with all distinct values uses one dict entry per row" {
    var col: DictColumnI64 = .init(testing.allocator);
    defer col.deinit();
    try col.appendValue(1);
    try col.appendValue(2);
    try col.appendValue(3);
    try testing.expectEqual(@as(usize, 3), col.rowCount());
    try testing.expectEqual(@as(usize, 3), col.dictSize());
}

test "valueAtRow round-trips appended values" {
    var col: DictColumnI64 = .init(testing.allocator);
    defer col.deinit();
    try col.appendValue(100);
    try col.appendValue(200);
    try col.appendValue(100); // dedup'd
    try col.appendValue(300);
    try testing.expectEqual(@as(i64, 100), try col.valueAtRow(0));
    try testing.expectEqual(@as(i64, 200), try col.valueAtRow(1));
    try testing.expectEqual(@as(i64, 100), try col.valueAtRow(2));
    try testing.expectEqual(@as(i64, 300), try col.valueAtRow(3));
}

test "valueAtRow rejects out-of-range row" {
    var col: DictColumnI64 = .init(testing.allocator);
    defer col.deinit();
    try col.appendValue(1);
    try testing.expectError(Error.IndexOutOfRange, col.valueAtRow(99));
}

test "appendValue rejects beyond u8 dictionary cap" {
    var col: DictColumnI64 = .init(testing.allocator);
    defer col.deinit();
    var i: i64 = 0;
    while (i < 256) : (i += 1) try col.appendValue(i);
    try testing.expectError(Error.DictionaryFull, col.appendValue(999));
}

test "byteSize shrinks vs rawByteSize when many rows reuse dict entries" {
    var col: DictColumnI64 = .init(testing.allocator);
    defer col.deinit();
    var i: i64 = 0;
    while (i < 1000) : (i += 1) try col.appendValue(@mod(i, 10)); // 10 distinct
    try testing.expectEqual(@as(usize, 10), col.dictSize());
    // dict: 10 * 8 = 80; indices: 1000 * 1 = 1000; total = 1080
    // raw: 1000 * 8 = 8000
    try testing.expect(col.byteSize() < col.rawByteSize());
    try testing.expectEqual(@as(usize, 1080), col.byteSize());
    try testing.expectEqual(@as(usize, 8000), col.rawByteSize());
}

test "empty DictColumnI64 reports zero everywhere" {
    var col: DictColumnI64 = .init(testing.allocator);
    defer col.deinit();
    try testing.expectEqual(@as(usize, 0), col.rowCount());
    try testing.expectEqual(@as(usize, 0), col.dictSize());
    try testing.expectEqual(@as(usize, 0), col.byteSize());
    try testing.expectEqual(@as(usize, 0), col.rawByteSize());
}
