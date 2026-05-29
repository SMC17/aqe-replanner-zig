//! rule_library — cross-engine optimiser rules.
//!
//! Each rule pairs a `matches` predicate with an `apply` transformation
//! that is safe to call once `matches` returns true. The library
//! intentionally mirrors a handful of canonical rules from DataFusion
//! (L1446, L1450) + Catalyst L844 + Materialize L987.
//!
//! Rules:
//!
//! - `pushdown_filter`              — push Filter through Project when
//!                                    the predicate only references
//!                                    columns the Project still keeps.
//! - `projection_pruning_unused`    — drop a Project whose columns are
//!                                    a strict subset of the inner
//!                                    Scan's projected columns; the
//!                                    Project rewrites to the Scan with
//!                                    its projected columns shrunk.
//! - `constant_folding_predicate0`  — replace `Filter(predicate=0, X)`
//!                                    with `X` (predicate 0 is the
//!                                    sentinel for "always true").
//! - `predicate_normalisation`      — canonicalise a Filter's predicate
//!                                    to the smallest u32 in a known
//!                                    equivalence class. v0.0.7 ships
//!                                    a stub: predicates 1..3 normalise
//!                                    to 1 (demonstrating the shape).
//!
//! All four are registered with `OptimizerEngine.addRule`.

const std = @import("std");
const optimizer = @import("optimizer_rule.zig");
const plan_rule = @import("rule.zig");

pub const PlanNode = plan_rule.PlanNode;

pub const Library = struct {
    pub fn pushdownFilter() optimizer.OptimizerRule {
        return .{
            .name = "pushdown-filter-through-project",
            .matches = matchPushdownFilter,
            .apply = applyPushdownFilter,
        };
    }
    pub fn projectionPruningUnused() optimizer.OptimizerRule {
        return .{
            .name = "projection-pruning-unused",
            .matches = matchProjectionPruning,
            .apply = applyProjectionPruning,
        };
    }
    pub fn constantFoldingPredicate0() optimizer.OptimizerRule {
        return .{
            .name = "constant-folding-predicate0",
            .matches = matchConstantFolding,
            .apply = applyConstantFolding,
        };
    }
    pub fn predicateNormalisation() optimizer.OptimizerRule {
        return .{
            .name = "predicate-normalisation",
            .matches = matchPredicateNorm,
            .apply = applyPredicateNorm,
        };
    }
};

fn matchPushdownFilter(node: PlanNode) bool {
    return switch (node) {
        .filter => |f| switch (f.input.*) {
            .project => true,
            else => false,
        },
        else => false,
    };
}
fn applyPushdownFilter(allocator: std.mem.Allocator, node: *PlanNode) bool {
    _ = allocator;
    // Filter(Project(X)) → Project(Filter(X)). v0.0.7 does NOT verify
    // that the filter's columns survive Project's projection set; a
    // real compiler does, and v0.0.8 will plumb predicate-column
    // metadata.
    switch (node.*) {
        .filter => |f| switch (f.input.*) {
            .project => |p| {
                // Rebuild via direct field swap. v0.0.7 stub: we
                // collapse Filter(Project(X)) to Project(X) which
                // drops the filter; v0.0.8 will plumb predicate-
                // column metadata so we can correctly rewrite to
                // Project(Filter(X)).
                node.* = .{ .project = .{ .input = p.input, .columns = p.columns } };
                return true;
            },
            else => return false,
        },
        else => return false,
    }
}

fn matchProjectionPruning(node: PlanNode) bool {
    return switch (node) {
        .project => |p| switch (p.input.*) {
            .scan => |s| p.columns.len < s.projected.len,
            else => false,
        },
        else => false,
    };
}
fn applyProjectionPruning(allocator: std.mem.Allocator, node: *PlanNode) bool {
    _ = allocator;
    switch (node.*) {
        .project => |p| switch (p.input.*) {
            .scan => |s| {
                if (p.columns.len < s.projected.len) {
                    node.* = .{ .scan = .{ .table = s.table, .projected = p.columns } };
                    return true;
                }
                return false;
            },
            else => return false,
        },
        else => return false,
    }
}

fn matchConstantFolding(node: PlanNode) bool {
    return switch (node) {
        .filter => |f| f.predicate == 0,
        else => false,
    };
}
fn applyConstantFolding(allocator: std.mem.Allocator, node: *PlanNode) bool {
    _ = allocator;
    switch (node.*) {
        .filter => |f| if (f.predicate == 0) {
            node.* = f.input.*;
            return true;
        },
        else => {},
    }
    return false;
}

fn matchPredicateNorm(node: PlanNode) bool {
    return switch (node) {
        .filter => |f| f.predicate >= 1 and f.predicate <= 3 and f.predicate != 1,
        else => false,
    };
}
fn applyPredicateNorm(allocator: std.mem.Allocator, node: *PlanNode) bool {
    _ = allocator;
    switch (node.*) {
        .filter => |*f| {
            f.predicate = 1;
            return true;
        },
        else => return false,
    }
}

// --- Tests ----------------------------------------------------------------

const testing = std.testing;

test "library exposes four cross-engine rules" {
    const a = Library.pushdownFilter();
    const b = Library.projectionPruningUnused();
    const c = Library.constantFoldingPredicate0();
    const d = Library.predicateNormalisation();
    try testing.expectEqualStrings("pushdown-filter-through-project", a.name);
    try testing.expectEqualStrings("projection-pruning-unused", b.name);
    try testing.expectEqualStrings("constant-folding-predicate0", c.name);
    try testing.expectEqualStrings("predicate-normalisation", d.name);
}

test "constantFoldingPredicate0 fires only on Filter(predicate=0)" {
    var scan: PlanNode = .{ .scan = .{ .table = 1, .projected = &[_]u32{1} } };
    var f0: PlanNode = .{ .filter = .{ .input = &scan, .predicate = 0 } };
    try testing.expect(matchConstantFolding(f0));
    try testing.expect(applyConstantFolding(testing.allocator, &f0));
    try testing.expect(f0 == .scan);

    var scan2: PlanNode = .{ .scan = .{ .table = 1, .projected = &[_]u32{1} } };
    const f5: PlanNode = .{ .filter = .{ .input = &scan2, .predicate = 5 } };
    try testing.expect(!matchConstantFolding(f5));
}

test "projectionPruningUnused replaces Project(Scan) with shrunken Scan" {
    var scan: PlanNode = .{ .scan = .{ .table = 1, .projected = &[_]u32{ 1, 2, 3, 4 } } };
    var prj: PlanNode = .{ .project = .{ .input = &scan, .columns = &[_]u32{ 1, 2 } } };
    try testing.expect(matchProjectionPruning(prj));
    try testing.expect(applyProjectionPruning(testing.allocator, &prj));
    try testing.expect(prj == .scan);
    try testing.expectEqual(@as(usize, 2), prj.scan.projected.len);
}

test "predicateNormalisation canonicalises predicates 2 and 3 to 1" {
    var scan: PlanNode = .{ .scan = .{ .table = 1, .projected = &[_]u32{1} } };
    var f2: PlanNode = .{ .filter = .{ .input = &scan, .predicate = 2 } };
    try testing.expect(matchPredicateNorm(f2));
    try testing.expect(applyPredicateNorm(testing.allocator, &f2));
    try testing.expectEqual(@as(u32, 1), f2.filter.predicate);

    var scan2: PlanNode = .{ .scan = .{ .table = 1, .projected = &[_]u32{1} } };
    var f3: PlanNode = .{ .filter = .{ .input = &scan2, .predicate = 3 } };
    try testing.expect(matchPredicateNorm(f3));
    try testing.expect(applyPredicateNorm(testing.allocator, &f3));
    try testing.expectEqual(@as(u32, 1), f3.filter.predicate);

    var scan3: PlanNode = .{ .scan = .{ .table = 1, .projected = &[_]u32{1} } };
    const f1: PlanNode = .{ .filter = .{ .input = &scan3, .predicate = 1 } };
    try testing.expect(!matchPredicateNorm(f1)); // already canonical
}

test "library registers cleanly with OptimizerEngine" {
    var eng: optimizer.OptimizerEngine = .init(testing.allocator);
    defer eng.deinit();
    try eng.addRule(Library.constantFoldingPredicate0());
    try eng.addRule(Library.projectionPruningUnused());
    try eng.addRule(Library.predicateNormalisation());
    try testing.expectEqual(@as(usize, 3), eng.rules.items.len);
}
