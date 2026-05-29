//! vectorised_validity — v0.0.16 Batch + bit-packed validity buffer integration.
//!
//! v0.0.13 Batch ships column data without nulls. v0.0.14 ships a
//! byte-per-row NullMask. v0.0.15 ships an Arrow-standard bit-packed
//! validity buffer. v0.0.16 wires them: every Batch column carries
//! its own optional validity buffer (`[]const u8`), and vectorised
//! rules receive a per-column validity pointer so null-aware ops
//! match Arrow wire format directly.
//!
//! Composition:
//!   v0.0.13 Batch ── column-shape data
//!   v0.0.15 null_bits ── bit-packed Arrow validity
//!   v0.0.16 ValidityBatch ── Batch + per-column validity slice
//!
//! Rules consuming a ValidityBatch can call countValid() per column
//! to skip null work entirely if all rows are null in a column.

const std = @import("std");
const vectorised = @import("vectorised.zig");
const null_bits = @import("null_bits.zig");

pub const Batch = vectorised.Batch;
pub const max_columns: usize = vectorised.max_columns;

pub const ValidityBatch = struct {
    batch: Batch,
    /// One bit-packed validity slice per column. `null` means "all
    /// rows valid" (no validity tracking).
    validity: [max_columns]?[]const u8 = .{ null, null, null, null, null, null, null, null },

    pub fn columnValidity(self: *const ValidityBatch, col: usize) ?[]const u8 {
        if (col >= self.batch.column_count) return null;
        return self.validity[col];
    }

    pub fn validCount(self: *const ValidityBatch, col: usize) usize {
        if (col >= self.batch.column_count) return 0;
        const bits = self.validity[col] orelse return self.batch.rows;
        return null_bits.countValid(bits, self.batch.rows);
    }

    pub fn isRowValid(self: *const ValidityBatch, col: usize, row: usize) bool {
        if (col >= self.batch.column_count) return false;
        if (row >= self.batch.rows) return false;
        const bits = self.validity[col] orelse return true;
        return null_bits.isValid(bits, row);
    }
};

// --- Tests ----------------------------------------------------------------

const testing = std.testing;

test "ValidityBatch with no validity slice reports every row valid" {
    var data = [_]i64{ 1, 2, 3, 4 };
    const batch: Batch = .{
        .rows = 4,
        .columns = .{
            .{ .kind = .i64, .i64_slice = &data },
            .{ .kind = .i64 },
            .{ .kind = .i64 },
            .{ .kind = .i64 },
            .{ .kind = .i64 },
            .{ .kind = .i64 },
            .{ .kind = .i64 },
            .{ .kind = .i64 },
        },
        .column_count = 1,
    };
    const vb: ValidityBatch = .{ .batch = batch };
    try testing.expectEqual(@as(usize, 4), vb.validCount(0));
    var i: usize = 0;
    while (i < 4) : (i += 1) try testing.expect(vb.isRowValid(0, i));
}

test "ValidityBatch with validity slice reports only valid rows" {
    var data = [_]i64{ 10, 20, 30, 40 };
    const batch: Batch = .{
        .rows = 4,
        .columns = .{
            .{ .kind = .i64, .i64_slice = &data },
            .{ .kind = .i64 },
            .{ .kind = .i64 },
            .{ .kind = .i64 },
            .{ .kind = .i64 },
            .{ .kind = .i64 },
            .{ .kind = .i64 },
            .{ .kind = .i64 },
        },
        .column_count = 1,
    };
    // Validity: row 0 valid, row 1 null, row 2 valid, row 3 null.
    var validity_bits = [_]u8{0b0000_0101};
    var vb: ValidityBatch = .{ .batch = batch };
    vb.validity[0] = &validity_bits;
    try testing.expectEqual(@as(usize, 2), vb.validCount(0));
    try testing.expect(vb.isRowValid(0, 0));
    try testing.expect(!vb.isRowValid(0, 1));
    try testing.expect(vb.isRowValid(0, 2));
    try testing.expect(!vb.isRowValid(0, 3));
}

test "ValidityBatch.columnValidity returns null for out-of-range column" {
    const batch: Batch = .{ .rows = 0, .columns = undefined, .column_count = 0 };
    const vb: ValidityBatch = .{ .batch = batch };
    try testing.expectEqual(@as(?[]const u8, null), vb.columnValidity(0));
}

test "validCount over 10 rows respects bit-packed layout" {
    var data: [10]i64 = [_]i64{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    const batch: Batch = .{
        .rows = 10,
        .columns = .{
            .{ .kind = .i64, .i64_slice = &data },
            .{ .kind = .i64 },
            .{ .kind = .i64 },
            .{ .kind = .i64 },
            .{ .kind = .i64 },
            .{ .kind = .i64 },
            .{ .kind = .i64 },
            .{ .kind = .i64 },
        },
        .column_count = 1,
    };
    // First 8 bits in byte 0, last 2 bits in byte 1.
    var validity_bits = [_]u8{ 0b1010_1010, 0b0000_0001 };
    var vb: ValidityBatch = .{ .batch = batch };
    vb.validity[0] = &validity_bits;
    // Byte 0 has 4 set bits, byte 1 has 1 — but only the first 2 bits
    // of byte 1 are in scope. So total = 4 + 1 = 5.
    try testing.expectEqual(@as(usize, 5), vb.validCount(0));
}

test "isRowValid rejects out-of-range row" {
    var data = [_]i64{ 1, 2 };
    const batch: Batch = .{
        .rows = 2,
        .columns = .{
            .{ .kind = .i64, .i64_slice = &data },
            .{ .kind = .i64 },
            .{ .kind = .i64 },
            .{ .kind = .i64 },
            .{ .kind = .i64 },
            .{ .kind = .i64 },
            .{ .kind = .i64 },
            .{ .kind = .i64 },
        },
        .column_count = 1,
    };
    const vb: ValidityBatch = .{ .batch = batch };
    try testing.expect(!vb.isRowValid(0, 999));
}
