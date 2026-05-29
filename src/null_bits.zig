//! null_bits — v0.0.15 Arrow-standard bit-packed null validity buffer.
//!
//! v0.0.14 ships byte-per-row NullMask. Arrow validity buffers
//! encode null as 1 bit per row: bit 0 set = NOT null, clear = null.
//! v0.0.15 ports the bit-packed layout so AQE batches match Arrow
//! wire format directly.
//!
//! Layout (little-endian byte order within bytes):
//!   For row i: byte at index (i / 8), bit (i % 8).
//!   bit = 1 → row is VALID (not null) — matches Arrow convention.
//!
//! popcount-based counting + intersection are O(N/8) byte loops.

const std = @import("std");

pub const Error = error{ MaskSizeMismatch };

pub fn requiredBytes(rows: usize) usize {
    return (rows + 7) / 8;
}

pub fn isValid(validity_bits: []const u8, row: usize) bool {
    const byte = validity_bits[row / 8];
    const bit_mask = @as(u8, 1) << @intCast(row % 8);
    return (byte & bit_mask) != 0;
}

pub fn setValid(validity_bits: []u8, row: usize) void {
    const bit_mask = @as(u8, 1) << @intCast(row % 8);
    validity_bits[row / 8] |= bit_mask;
}

pub fn setNull(validity_bits: []u8, row: usize) void {
    const bit_mask = @as(u8, 1) << @intCast(row % 8);
    validity_bits[row / 8] &= ~bit_mask;
}

/// Count valid (non-null) rows by popcount over the byte array.
/// `rows` is the logical row count (validity bytes may have trailing
/// padding bits that must not be counted).
pub fn countValid(validity_bits: []const u8, rows: usize) usize {
    if (rows == 0) return 0;
    var count: usize = 0;
    const full_bytes = rows / 8;
    for (validity_bits[0..full_bytes]) |b| count += @popCount(b);
    const remaining_bits = rows % 8;
    if (remaining_bits > 0 and validity_bits.len > full_bytes) {
        const last = validity_bits[full_bytes];
        const mask: u8 = (@as(u8, 1) << @intCast(remaining_bits)) - 1;
        count += @popCount(last & mask);
    }
    return count;
}

/// AND two validity buffers in place: dst[i] = dst[i] AND src[i].
/// Both must have the same byte length.
pub fn intersectInPlace(dst: []u8, src: []const u8) Error!void {
    if (dst.len != src.len) return Error.MaskSizeMismatch;
    for (dst, src) |*d, s| d.* &= s;
}

/// Build a validity buffer from a slice of booleans where `true` =
/// valid (matches the convention of v0.0.14 NullMask interpreted
/// inverted — easier comparison for callers migrating).
pub fn fromBooleans(allocator: std.mem.Allocator, valids: []const bool) ![]u8 {
    const bytes = try allocator.alloc(u8, requiredBytes(valids.len));
    @memset(bytes, 0);
    for (valids, 0..) |v, i| if (v) setValid(bytes, i);
    return bytes;
}

// --- Tests ----------------------------------------------------------------

const testing = std.testing;

test "requiredBytes is ceiling-division by 8" {
    try testing.expectEqual(@as(usize, 0), requiredBytes(0));
    try testing.expectEqual(@as(usize, 1), requiredBytes(1));
    try testing.expectEqual(@as(usize, 1), requiredBytes(7));
    try testing.expectEqual(@as(usize, 1), requiredBytes(8));
    try testing.expectEqual(@as(usize, 2), requiredBytes(9));
    try testing.expectEqual(@as(usize, 16), requiredBytes(128));
}

test "setValid + isValid round-trips for several rows" {
    var bits = [_]u8{ 0, 0 };
    setValid(&bits, 0);
    setValid(&bits, 5);
    setValid(&bits, 9);
    try testing.expect(isValid(&bits, 0));
    try testing.expect(!isValid(&bits, 1));
    try testing.expect(!isValid(&bits, 4));
    try testing.expect(isValid(&bits, 5));
    try testing.expect(!isValid(&bits, 7));
    try testing.expect(isValid(&bits, 9));
}

test "setNull clears the bit" {
    var bits = [_]u8{ 0xFF, 0xFF };
    try testing.expect(isValid(&bits, 3));
    setNull(&bits, 3);
    try testing.expect(!isValid(&bits, 3));
}

test "countValid handles row counts not a multiple of 8" {
    var bits = [_]u8{ 0b1111_1111, 0b0000_0011 }; // 10 rows: 8 valid + 2 valid = 10
    try testing.expectEqual(@as(usize, 10), countValid(&bits, 10));
    // But row count is 9 means we only consider 1 bit from the second byte.
    try testing.expectEqual(@as(usize, 9), countValid(&bits, 9));
    // Row count is 11 means we count 8 + 2 in 11 logical rows; the
    // 11th and beyond aren't set so total = 10 + 0 = 10.
    try testing.expectEqual(@as(usize, 10), countValid(&bits, 11));
}

test "countValid ignores padding bits past logical row count" {
    // 0xFF: 8 bits set. Row count 5 → only first 5 bits count = 5.
    const bits = [_]u8{0xFF};
    try testing.expectEqual(@as(usize, 5), countValid(&bits, 5));
}

test "intersectInPlace ANDs validity buffers byte-wise" {
    var a = [_]u8{ 0b1111_0000, 0b0101_0101 };
    const b = [_]u8{ 0b0011_1100, 0b1100_1100 };
    try intersectInPlace(&a, &b);
    try testing.expectEqual(@as(u8, 0b0011_0000), a[0]);
    try testing.expectEqual(@as(u8, 0b0100_0100), a[1]);
}

test "intersectInPlace rejects mismatched lengths" {
    var a = [_]u8{ 0, 0 };
    const b = [_]u8{0};
    try testing.expectError(Error.MaskSizeMismatch, intersectInPlace(&a, &b));
}

test "fromBooleans builds the matching validity buffer" {
    const alloc = testing.allocator;
    const valids = [_]bool{ true, false, true, true, false, false, true, true, false };
    const bits = try fromBooleans(alloc, &valids);
    defer alloc.free(bits);
    try testing.expectEqual(@as(usize, 2), bits.len);
    for (valids, 0..) |v, i| try testing.expectEqual(v, isValid(bits, i));
}

test "countValid + fromBooleans round-trip" {
    const alloc = testing.allocator;
    const valids = [_]bool{ true, true, false, true, true, false, true, true, true, true };
    const bits = try fromBooleans(alloc, &valids);
    defer alloc.free(bits);
    var expected: usize = 0;
    for (valids) |v| if (v) {
        expected += 1;
    };
    try testing.expectEqual(expected, countValid(bits, valids.len));
}
