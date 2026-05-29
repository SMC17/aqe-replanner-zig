//! dict_column_sv — v0.0.19 StringView dictionary column.
//!
//! Extends v0.0.18 DictColumnI64 to short strings via StringView.
//! Repeated short strings get a single dictionary entry; per-row
//! index is u8 (capped at 256 distinct values).
//!
//! Composition: workflow-event-log payloads, kind enum strings,
//! tenant labels, etc. — anywhere a high-cardinality column has a
//! tail of repeated values.

const std = @import("std");
const string_view = @import("string_view.zig");

pub const StringView = string_view.StringView;

pub const Error = error{
    OutOfMemory,
    DictionaryFull,
    IndexOutOfRange,
};

pub const max_dict_size_u8: usize = 256;

pub const DictColumnStringView = struct {
    /// Distinct StringViews.
    values: std.array_list.Managed(StringView),
    /// Per-row dictionary index.
    indices: std.array_list.Managed(u8),

    pub fn init(allocator: std.mem.Allocator) DictColumnStringView {
        return .{
            .values = .init(allocator),
            .indices = .init(allocator),
        };
    }

    pub fn deinit(self: *DictColumnStringView) void {
        self.values.deinit();
        self.indices.deinit();
    }

    /// Append a row. Inline strings (len ≤ 12) are fully dedup-able
    /// via equalsInline. External strings are compared by prefix
    /// only (caller responsible for tail-comparison correctness).
    pub fn appendInline(self: *DictColumnStringView, sv: StringView) Error!void {
        const idx = blk: {
            for (self.values.items, 0..) |existing, i| {
                if (string_view.equalsInline(existing, sv)) break :blk i;
            }
            if (self.values.items.len >= max_dict_size_u8) return Error.DictionaryFull;
            self.values.append(sv) catch return Error.OutOfMemory;
            break :blk self.values.items.len - 1;
        };
        self.indices.append(@intCast(idx)) catch return Error.OutOfMemory;
    }

    pub fn rowCount(self: DictColumnStringView) usize {
        return self.indices.items.len;
    }

    pub fn dictSize(self: DictColumnStringView) usize {
        return self.values.items.len;
    }

    pub fn valueAtRow(self: DictColumnStringView, row: usize) Error!StringView {
        if (row >= self.indices.items.len) return Error.IndexOutOfRange;
        const idx = self.indices.items[row];
        if (idx >= self.values.items.len) return Error.IndexOutOfRange;
        return self.values.items[idx];
    }
};

// --- Tests ----------------------------------------------------------------

const testing = std.testing;

test "DictColumnStringView dedup repeated inline strings" {
    var col: DictColumnStringView = .init(testing.allocator);
    defer col.deinit();
    try col.appendInline(string_view.buildInline("foo"));
    try col.appendInline(string_view.buildInline("bar"));
    try col.appendInline(string_view.buildInline("foo"));
    try col.appendInline(string_view.buildInline("baz"));
    try col.appendInline(string_view.buildInline("foo"));
    try testing.expectEqual(@as(usize, 5), col.rowCount());
    try testing.expectEqual(@as(usize, 3), col.dictSize()); // foo, bar, baz
}

test "valueAtRow round-trips appended strings" {
    var col: DictColumnStringView = .init(testing.allocator);
    defer col.deinit();
    try col.appendInline(string_view.buildInline("aaa"));
    try col.appendInline(string_view.buildInline("bbb"));
    try col.appendInline(string_view.buildInline("aaa"));
    const r0 = try col.valueAtRow(0);
    const r1 = try col.valueAtRow(1);
    const r2 = try col.valueAtRow(2);
    try testing.expectEqualSlices(u8, "aaa", r0.prefix[0..3]);
    try testing.expectEqualSlices(u8, "bbb", r1.prefix[0..3]);
    try testing.expectEqualSlices(u8, "aaa", r2.prefix[0..3]);
}

test "valueAtRow rejects out-of-range row" {
    var col: DictColumnStringView = .init(testing.allocator);
    defer col.deinit();
    try col.appendInline(string_view.buildInline("x"));
    try testing.expectError(Error.IndexOutOfRange, col.valueAtRow(99));
}

test "DictColumnStringView with all distinct uses one dict per row" {
    var col: DictColumnStringView = .init(testing.allocator);
    defer col.deinit();
    try col.appendInline(string_view.buildInline("a"));
    try col.appendInline(string_view.buildInline("b"));
    try col.appendInline(string_view.buildInline("c"));
    try testing.expectEqual(@as(usize, 3), col.rowCount());
    try testing.expectEqual(@as(usize, 3), col.dictSize());
}

test "DictionaryFull when distinct values exceed u8 cap" {
    var col: DictColumnStringView = .init(testing.allocator);
    defer col.deinit();
    var buf: [4]u8 = undefined;
    var i: u32 = 0;
    while (i < 256) : (i += 1) {
        buf[0] = @intCast(i % 256);
        buf[1] = @intCast((i / 256) % 256);
        buf[2] = 0;
        buf[3] = 0;
        const sv = string_view.buildInline(buf[0..4]);
        try col.appendInline(sv);
    }
    try testing.expectError(Error.DictionaryFull, col.appendInline(string_view.buildInline("zzzz")));
}
