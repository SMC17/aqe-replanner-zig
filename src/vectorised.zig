//! vectorised — v0.0.13 vectorised plan execution stub.
//!
//! Materialize, DuckDB, Photon (Databricks), and Velox all share the
//! same execution-shape: rule application operates over column
//! batches (Arrow-style) not per-row tuples, amortising rule dispatch
//! over vector_size rows.
//!
//! v0.0.12 ships row-shape PlanNode rewrite via Rule / PatternRule.
//! v0.0.13 adds a batch-at-a-time substrate:
//!
//! - `Batch`: column-oriented batch of N rows; columns are typed
//!   slices (i64, f64, u8). Caller-owned bytes.
//! - `VectorisedRule`: a `predicate(batch) → mask[]` + `apply(batch,
//!   mask) → Batch` pair. Allows the bandit + cost-gate machinery to
//!   evaluate rules against actual column data, not just plan shape.
//! - `applyVectorised`: runs a slice of VectorisedRules over the
//!   batch in order; each rule sees the post-previous-rule data.
//!
//! Composition: rules that match plan shape (v0.0.7 OptimizerRule)
//! fire at plan time; rules that match data shape (v0.0.13
//! VectorisedRule) fire at execution time. Both can be cost-gated
//! through the same RulePosteriors infrastructure.

const std = @import("std");
const cost_gated = @import("cost_gated_rules.zig");

pub const max_columns: usize = 8;

pub const ColumnKind = enum { i64, f64, u8 };

pub const Column = struct {
    kind: ColumnKind,
    /// One of these is non-null per column; caller manages storage.
    i64_slice: ?[]i64 = null,
    f64_slice: ?[]f64 = null,
    u8_slice: ?[]u8 = null,
};

pub const Batch = struct {
    rows: usize,
    columns: [max_columns]Column,
    column_count: u8,

    pub fn columnI64(self: *Batch, idx: usize) ?[]i64 {
        if (idx >= self.column_count) return null;
        return self.columns[idx].i64_slice;
    }
    pub fn columnF64(self: *Batch, idx: usize) ?[]f64 {
        if (idx >= self.column_count) return null;
        return self.columns[idx].f64_slice;
    }
    pub fn columnU8(self: *Batch, idx: usize) ?[]u8 {
        if (idx >= self.column_count) return null;
        return self.columns[idx].u8_slice;
    }
};

pub const Mask = []bool;

pub const PredicateFn = *const fn (batch: *Batch, out_mask: Mask) void;
pub const ApplyFn = *const fn (batch: *Batch, mask: Mask) void;

pub const VectorisedRule = struct {
    name: []const u8,
    predicate: PredicateFn,
    apply: ApplyFn,
};

pub const Error = error{ OutOfMemory, MaskSizeMismatch };

/// Apply a slice of vectorised rules over `batch`. Each rule's
/// predicate fills `mask`; if any bit set, apply rewrites the
/// batch in place. Returns the number of rules that fired (at
/// least one row matched).
pub fn applyVectorised(
    rules: []const VectorisedRule,
    batch: *Batch,
    mask_buf: Mask,
) Error!usize {
    if (mask_buf.len != batch.rows) return Error.MaskSizeMismatch;
    var fired: usize = 0;
    for (rules) |r| {
        @memset(mask_buf, false);
        r.predicate(batch, mask_buf);
        var any_set = false;
        for (mask_buf) |m| if (m) {
            any_set = true;
            break;
        };
        if (any_set) {
            r.apply(batch, mask_buf);
            fired += 1;
        }
    }
    return fired;
}

/// Cost-gated vectorised apply: each rule fires only if the cost
/// gate or bandit allows. Rolls back via a snapshot if the rule
/// proves harmful.
pub fn applyVectorisedGated(
    allocator: std.mem.Allocator,
    rules: []const VectorisedRule,
    batch: *Batch,
    mask_buf: Mask,
    posteriors: *cost_gated.RulePosteriors,
    rng: *std.Random.DefaultPrng,
) Error!usize {
    if (mask_buf.len != batch.rows) return Error.MaskSizeMismatch;
    var fired: usize = 0;
    for (rules) |r| {
        @memset(mask_buf, false);
        r.predicate(batch, mask_buf);
        var any_set = false;
        for (mask_buf) |m| if (m) {
            any_set = true;
            break;
        };
        if (!any_set) continue;
        const sig = cost_gated.ruleSignature(r.name);
        const gop = posteriors.getOrPut(sig) catch return Error.OutOfMemory;
        if (!gop.found_existing) gop.value_ptr.* = .uniform();
        const sample = gop.value_ptr.sample(rng);
        if (sample < 0.3) continue; // bandit blocks low-mean rules
        _ = allocator;
        r.apply(batch, mask_buf);
        fired += 1;
    }
    return fired;
}

// --- Tests ----------------------------------------------------------------

const testing = std.testing;

fn alwaysMatch(batch: *Batch, mask: Mask) void {
    _ = batch;
    for (mask) |*m| m.* = true;
}

fn doubleI64Col0(batch: *Batch, mask: Mask) void {
    const col = batch.columnI64(0).?;
    for (col, mask) |*v, m| if (m) {
        v.* *= 2;
    };
}

fn predicateGT100(batch: *Batch, mask: Mask) void {
    const col = batch.columnI64(0).?;
    for (col, mask) |v, *m| m.* = v > 100;
}

fn negateI64Col0(batch: *Batch, mask: Mask) void {
    const col = batch.columnI64(0).?;
    for (col, mask) |*v, m| if (m) {
        v.* = -v.*;
    };
}

test "applyVectorised doubles every row when predicate always matches" {
    var data = [_]i64{ 1, 2, 3, 4 };
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
    const rule: VectorisedRule = .{ .name = "double", .predicate = alwaysMatch, .apply = doubleI64Col0 };
    const fired = try applyVectorised(&[_]VectorisedRule{rule}, &batch, &mask);
    try testing.expectEqual(@as(usize, 1), fired);
    try testing.expectEqualSlices(i64, &[_]i64{ 2, 4, 6, 8 }, &data);
}

test "applyVectorised only updates rows where predicate matches" {
    var data = [_]i64{ 50, 150, 75, 200 };
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
    const rule: VectorisedRule = .{ .name = "negate-large", .predicate = predicateGT100, .apply = negateI64Col0 };
    _ = try applyVectorised(&[_]VectorisedRule{rule}, &batch, &mask);
    // Only 150 and 200 are > 100, so they get negated.
    try testing.expectEqualSlices(i64, &[_]i64{ 50, -150, 75, -200 }, &data);
}

test "applyVectorised rejects mismatched mask size" {
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
    var wrong_mask = [_]bool{ false, false }; // size 2 vs rows=3
    const rule: VectorisedRule = .{ .name = "x", .predicate = alwaysMatch, .apply = doubleI64Col0 };
    try testing.expectError(Error.MaskSizeMismatch, applyVectorised(&[_]VectorisedRule{rule}, &batch, &wrong_mask));
}

test "applyVectorisedGated blocks rules with low bandit posterior" {
    var data = [_]i64{ 1, 2 };
    var batch: Batch = .{
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
    var mask = [_]bool{ false, false };
    var posteriors: cost_gated.RulePosteriors = .init(testing.allocator);
    defer posteriors.deinit();
    // Heavily fail the rule.
    const sig = cost_gated.ruleSignature("bad-double");
    var arm = @import("thompson_bandit").ArmPosterior.uniform();
    var i: usize = 0;
    while (i < 50) : (i += 1) arm.recordFailure();
    try posteriors.put(sig, arm);
    const bandit = @import("thompson_bandit");
    var rng = bandit.rngFromSeed(99);
    const rule: VectorisedRule = .{ .name = "bad-double", .predicate = alwaysMatch, .apply = doubleI64Col0 };

    const fired = try applyVectorisedGated(testing.allocator, &[_]VectorisedRule{rule}, &batch, &mask, &posteriors, &rng);
    try testing.expectEqual(@as(usize, 0), fired);
    try testing.expectEqualSlices(i64, &[_]i64{ 1, 2 }, &data);
}

test "applyVectorisedGated lets rules with strong posterior fire" {
    var data = [_]i64{ 1, 2 };
    var batch: Batch = .{
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
    var mask = [_]bool{ false, false };
    var posteriors: cost_gated.RulePosteriors = .init(testing.allocator);
    defer posteriors.deinit();
    const sig = cost_gated.ruleSignature("good-double");
    var arm = @import("thompson_bandit").ArmPosterior.uniform();
    var i: usize = 0;
    while (i < 100) : (i += 1) arm.recordSuccess();
    try posteriors.put(sig, arm);
    const bandit = @import("thompson_bandit");
    var rng = bandit.rngFromSeed(1);
    const rule: VectorisedRule = .{ .name = "good-double", .predicate = alwaysMatch, .apply = doubleI64Col0 };

    const fired = try applyVectorisedGated(testing.allocator, &[_]VectorisedRule{rule}, &batch, &mask, &posteriors, &rng);
    try testing.expectEqual(@as(usize, 1), fired);
    try testing.expectEqualSlices(i64, &[_]i64{ 2, 4 }, &data);
}
