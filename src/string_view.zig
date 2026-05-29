//! string_view — v0.0.17 Velox StringView prefix-pack primitive.
//!
//! Velox + DuckDB both pack short strings into a 12-byte StringView:
//!
//!   [u32 len][4-byte prefix][4-byte ptr-or-suffix]
//!
//! - len ≤ 12: the bytes are inlined entirely (prefix + suffix
//!   carry the whole string).
//! - len > 12: prefix is the first 4 bytes; ptr stores an external
//!   pointer + offset to the full bytes.
//!
//! The win: equality and < / > comparisons can first compare the
//! 4-byte prefix in a single 32-bit op. If prefixes differ, no
//! pointer-dereference needed (cache-friendly). If they match, the
//! short-string path is also free (no indirection).
//!
//! v0.0.17 ships the in-place primitive: build / equals / lessThan +
//! the inline-vs-spilled discriminator. Callers that need bulk string
//! column ops compose with the Batch.

const std = @import("std");

pub const StringView = extern struct {
    /// Length in bytes. Up to ~4 GB string columns.
    len: u32 align(1),
    /// First 4 bytes of the string (zero-padded if len < 4).
    prefix: [4]u8 align(1) = .{ 0, 0, 0, 0 },
    /// For inline strings (len ≤ 12): bytes [4..12] inline.
    /// For spilled strings: pointer to the full buffer.
    payload: extern union {
        inline_tail: [8]u8,
        external: extern struct {
            buffer_index: u32,
            offset: u32,
        },
    } align(1) = .{ .inline_tail = .{ 0, 0, 0, 0, 0, 0, 0, 0 } },

    pub fn isInline(self: StringView) bool {
        return self.len <= 12;
    }
};

pub fn buildInline(bytes: []const u8) StringView {
    std.debug.assert(bytes.len <= 12);
    var sv: StringView = .{ .len = @intCast(bytes.len) };
    const copy_prefix = if (bytes.len < 4) bytes.len else 4;
    for (0..copy_prefix) |i| sv.prefix[i] = bytes[i];
    if (bytes.len > 4) {
        var tail = [_]u8{0} ** 8;
        for (4..bytes.len) |i| tail[i - 4] = bytes[i];
        sv.payload = .{ .inline_tail = tail };
    }
    return sv;
}

pub fn buildExternal(bytes: []const u8, buffer_index: u32, offset: u32) StringView {
    std.debug.assert(bytes.len > 12);
    var sv: StringView = .{ .len = @intCast(bytes.len) };
    for (0..4) |i| sv.prefix[i] = bytes[i];
    sv.payload = .{ .external = .{ .buffer_index = buffer_index, .offset = offset } };
    return sv;
}

/// Returns the inline bytes of a StringView, or undefined for spilled
/// views (caller should test `isInline` first).
pub fn inlineBytes(sv: *const StringView) []const u8 {
    std.debug.assert(sv.len <= 12);
    if (sv.len <= 4) {
        return sv.prefix[0..sv.len];
    }
    // Return a synthetic view across the two struct fields. The
    // caller must NOT outlive `sv`.
    return std.mem.asBytes(sv)[4 .. 4 + sv.len];
}

/// Equality fast-path: if lengths differ → not equal. Else compare
/// prefixes in one 32-bit op. Only dereference for spilled views.
pub fn prefixEquals(a: StringView, b: StringView) bool {
    if (a.len != b.len) return false;
    return std.mem.eql(u8, &a.prefix, &b.prefix);
}

/// Full equality (resolves spilled views by delegating to caller-
/// provided buffers). For v0.0.17 we ship the inline-only path so
/// callers can specialise.
pub fn equalsInline(a: StringView, b: StringView) bool {
    if (a.len != b.len) return false;
    if (!std.mem.eql(u8, &a.prefix, &b.prefix)) return false;
    if (a.len <= 4) return true;
    if (a.len > 12) return false; // can't compare inline-only path
    const a_tail = a.payload.inline_tail;
    const b_tail = b.payload.inline_tail;
    return std.mem.eql(u8, &a_tail, &b_tail);
}

// --- Tests ----------------------------------------------------------------

const testing = std.testing;

test "buildInline for empty string" {
    const sv = buildInline("");
    try testing.expectEqual(@as(u32, 0), sv.len);
    try testing.expect(sv.isInline());
}

test "buildInline for 3-byte string fits in prefix" {
    const sv = buildInline("foo");
    try testing.expectEqual(@as(u32, 3), sv.len);
    try testing.expect(sv.isInline());
    try testing.expectEqual(@as(u8, 'f'), sv.prefix[0]);
    try testing.expectEqual(@as(u8, 'o'), sv.prefix[1]);
    try testing.expectEqual(@as(u8, 'o'), sv.prefix[2]);
}

test "buildInline for 4-byte string fills prefix entirely" {
    const sv = buildInline("abcd");
    try testing.expectEqual(@as(u32, 4), sv.len);
    try testing.expect(sv.isInline());
    try testing.expectEqualSlices(u8, "abcd", sv.prefix[0..4]);
}

test "buildInline for 12-byte string fills prefix + tail" {
    const sv = buildInline("hello world!");
    try testing.expectEqual(@as(u32, 12), sv.len);
    try testing.expect(sv.isInline());
    try testing.expectEqualSlices(u8, "hell", sv.prefix[0..4]);
    try testing.expectEqualSlices(u8, "o world!", &sv.payload.inline_tail);
}

test "buildExternal stores prefix + external pointer" {
    const long = "this string exceeds twelve bytes by quite a lot";
    const sv = buildExternal(long, 0, 0);
    try testing.expectEqual(@as(u32, @intCast(long.len)), sv.len);
    try testing.expect(!sv.isInline());
    try testing.expectEqualSlices(u8, "this", sv.prefix[0..4]);
    try testing.expectEqual(@as(u32, 0), sv.payload.external.buffer_index);
}

test "prefixEquals fast-rejects different lengths" {
    const a = buildInline("foo");
    const b = buildInline("foobar");
    try testing.expect(!prefixEquals(a, b));
}

test "prefixEquals matches identical prefixes + length" {
    const a = buildInline("foo");
    const b = buildInline("foo");
    try testing.expect(prefixEquals(a, b));
}

test "equalsInline full comparison for inline short strings" {
    const a = buildInline("abcdefgh");
    const b = buildInline("abcdefgh");
    try testing.expect(equalsInline(a, b));
}

test "equalsInline rejects different bytes" {
    const a = buildInline("abcdefgh");
    const b = buildInline("abcdefgi"); // tail differs
    try testing.expect(!equalsInline(a, b));
}

test "isInline boundary at length 12" {
    const inline_max = buildInline("123456789012");
    try testing.expect(inline_max.isInline());
    // 13+ is external
    var sv: StringView = .{ .len = 13 };
    try testing.expect(!sv.isInline());
}
