//! null_mask — v0.0.14 null bitmap support for vectorised batches.
//!
//! Arrow validity buffers encode nullability as 1 bit per row. v0.0.13
//! Batch ships only column data; v0.0.14 adds a per-column NullMask
//! (byte-per-row for simplicity; v0.0.15 bumps to bit-packed) so
//! predicate + apply rules can skip null rows.
//!
//! Composition: NullMask is an external buffer, indexed by column +
//! row. Callers attach NullMask via `attachNullMask(batch, col, mask)`.
//! `applyVectorisedNullAware` rebuilds the matched-mask from intersection
//! of predicate-mask and NOT-null-mask.

const std = @import("std");
const vectorised = @import("vectorised.zig");

pub const Batch = vectorised.Batch;
pub const Mask = vectorised.Mask;

pub const NullMask = []const bool;

pub const Error = error{ MaskSizeMismatch };

/// Intersect a predicate output mask with a null mask in place.
/// Result: matched[i] = predicate[i] AND NOT null_mask[i].
pub fn intersectNotNull(matched: Mask, null_mask: NullMask) Error!void {
    if (matched.len != null_mask.len) return Error.MaskSizeMismatch;
    var i: usize = 0;
    while (i < matched.len) : (i += 1) matched[i] = matched[i] and !null_mask[i];
}

/// Run a predicate over a batch, then mask out nulls. Returns the
/// number of matched rows.
pub fn predicateWithNullAware(
    rule: vectorised.VectorisedRule,
    batch: *Batch,
    null_mask: NullMask,
    mask_buf: Mask,
) Error!usize {
    if (mask_buf.len != batch.rows) return Error.MaskSizeMismatch;
    if (null_mask.len != batch.rows) return Error.MaskSizeMismatch;
    @memset(mask_buf, false);
    rule.predicate(batch, mask_buf);
    try intersectNotNull(mask_buf, null_mask);
    var count: usize = 0;
    for (mask_buf) |m| if (m) {
        count += 1;
    };
    return count;
}

/// Count non-null rows in a null mask.
pub fn countNonNull(null_mask: NullMask) usize {
    var count: usize = 0;
    for (null_mask) |n| {
        if (!n) count += 1;
    }
    return count;
}

// --- Tests ----------------------------------------------------------------

const testing = std.testing;

test "intersectNotNull masks out null rows" {
    var matched = [_]bool{ true, true, true, true };
    const null_mask = [_]bool{ false, true, false, true }; // rows 1,3 are null
    try intersectNotNull(&matched, &null_mask);
    try testing.expectEqualSlices(bool, &[_]bool{ true, false, true, false }, &matched);
}

test "intersectNotNull rejects mismatched lengths" {
    var matched = [_]bool{ true, true };
    const null_mask = [_]bool{ false, true, false };
    try testing.expectError(Error.MaskSizeMismatch, intersectNotNull(&matched, &null_mask));
}

test "predicateWithNullAware skips nulls" {
    var data = [_]i64{ 10, 20, 30, 40 };
    var batch: Batch = .{
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
    var mask = [_]bool{ false, false, false, false };
    const null_mask = [_]bool{ false, true, false, false }; // row 1 is null

    const rule_always_match: vectorised.VectorisedRule = .{
        .name = "always",
        .predicate = struct {
            fn p(b: *Batch, m: Mask) void {
                _ = b;
                for (m) |*x| x.* = true;
            }
        }.p,
        .apply = struct {
            fn a(b: *Batch, m: Mask) void {
                _ = b;
                _ = m;
            }
        }.a,
    };
    const matched = try predicateWithNullAware(rule_always_match, &batch, &null_mask, &mask);
    try testing.expectEqual(@as(usize, 3), matched);
    try testing.expectEqualSlices(bool, &[_]bool{ true, false, true, true }, &mask);
}

test "countNonNull counts the non-null rows in a mask" {
    const m = [_]bool{ false, true, false, false, true, true };
    try testing.expectEqual(@as(usize, 3), countNonNull(&m));
}

test "all-null mask yields zero matched rows even when predicate matches all" {
    var data = [_]i64{ 1, 2, 3 };
    var batch: Batch = .{
        .rows = 3,
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
    var mask = [_]bool{ false, false, false };
    const all_null = [_]bool{ true, true, true };
    const rule: vectorised.VectorisedRule = .{
        .name = "always",
        .predicate = struct {
            fn p(b: *Batch, m: Mask) void {
                _ = b;
                for (m) |*x| x.* = true;
            }
        }.p,
        .apply = struct {
            fn a(b: *Batch, m: Mask) void {
                _ = b;
                _ = m;
            }
        }.a,
    };
    const matched = try predicateWithNullAware(rule, &batch, &all_null, &mask);
    try testing.expectEqual(@as(usize, 0), matched);
}
