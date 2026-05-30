//! pattern_recursive: v0.0.9 recursive subtree pattern matching.
//!
//! v0.0.8 ships `PatternRule.applyOnce` which tests the pattern
//! against the root `PlanNode`. Real DataFusion + Catalyst rules
//! recurse: the rule fires at every subtree where the pattern
//! matches.
//!
//! v0.0.9 adds `applyRecursive` that walks the PlanNode tree
//! bottom-up, attempting `applyOnce` at every child first then at
//! the current node. Bottom-up matches DataFusion's
//! `OptimizerRule::rewrite` semantics (children rewritten before
//! the parent's predicate is checked).
//!
//! Composition path:
//!   v0.0.7 OptimizerRule (matches + apply at root)
//!   v0.0.8 PatternRule + PlanPattern (root-only)
//!   v0.0.9 PatternRule.applyRecursive (every subtree, bottom-up)

const std = @import("std");
const plan_rule = @import("rule.zig");
const pattern_match = @import("pattern_match.zig");

pub const PlanNode = plan_rule.PlanNode;
pub const PatternRule = pattern_match.PatternRule;
pub const PlanPattern = pattern_match.PlanPattern;

pub const RecursiveResult = struct {
    fired_count: usize,
};

/// Bottom-up recursive apply: descend into children first, applying
/// the rule at each subtree, then attempt at the current node. Each
/// match advances a counter and rewrites the node in-place. Heap-
/// allocated child slots are mutated through pointer indirection.
///
/// Caller-owned children are mutated through their existing storage;
/// rewrites at the top of a subtree may invalidate child pointers,
/// so callers should not retain raw inner-pointer captures across
/// `applyRecursive`.
pub fn applyRecursive(rule: PatternRule, allocator: std.mem.Allocator, node: *PlanNode) RecursiveResult {
    var total: usize = 0;

    // Bottom-up: descend children first.
    switch (node.*) {
        .scan => {},
        .filter => |*f| {
            // f.input is a *const PlanNode; cast away const for in-
            // place rewrite. The pattern_match module's PlanNode
            // representation stores child pointers as *const; in
            // practice callers in this module construct mutable
            // backing storage.
            const inner = @constCast(f.input);
            total += applyRecursive(rule, allocator, inner).fired_count;
        },
        .project => |*p| {
            const inner = @constCast(p.input);
            total += applyRecursive(rule, allocator, inner).fired_count;
        },
    }

    // Now apply at current node.
    if (rule.applyOnce(allocator, node)) total += 1;
    return .{ .fired_count = total };
}

/// `applyRecursiveAll` runs a slice of rules over the tree until
/// quiescence (no rule fires across one full pass), capped at
/// `max_passes` to bound work. Returns total firings.
pub fn applyRecursiveAll(
    rules: []const PatternRule,
    allocator: std.mem.Allocator,
    node: *PlanNode,
    max_passes: usize,
) RecursiveResult {
    var total: usize = 0;
    var pass: usize = 0;
    while (pass < max_passes) : (pass += 1) {
        var fired_this_pass: usize = 0;
        for (rules) |r| {
            const r_res = applyRecursive(r, allocator, node);
            fired_this_pass += r_res.fired_count;
        }
        total += fired_this_pass;
        if (fired_this_pass == 0) break;
    }
    return .{ .fired_count = total };
}

// --- Tests ----------------------------------------------------------------

const testing = std.testing;

fn buildDropFilter(allocator: std.mem.Allocator, m: pattern_match.Match) ?PlanNode {
    _ = allocator;
    const filter_node = m.captures[0] orelse return null;
    return switch (filter_node.*) {
        .filter => |f| f.input.*,
        else => null,
    };
}

test "applyRecursive fires at root when pattern matches root" {
    var scan: PlanNode = .{ .scan = .{ .table = 1, .projected = &[_]u32{1} } };
    var fil: PlanNode = .{ .filter = .{ .input = &scan, .predicate = 0 } };
    const fil_pat: PlanPattern = .{ .kind = .filter, .capture_index = 0 };
    const rule: PatternRule = .{ .name = "drop-filter", .pattern = fil_pat, .build = buildDropFilter };
    const res = applyRecursive(rule, testing.allocator, &fil);
    try testing.expectEqual(@as(usize, 1), res.fired_count);
    try testing.expect(fil == .scan);
}

test "applyRecursive descends into project's child and fires there" {
    // Tree: project(filter(scan)). Drop-filter rule fires inside.
    var scan: PlanNode = .{ .scan = .{ .table = 1, .projected = &[_]u32{1} } };
    var fil: PlanNode = .{ .filter = .{ .input = &scan, .predicate = 0 } };
    var prj: PlanNode = .{ .project = .{ .input = &fil, .columns = &[_]u32{1} } };
    const fil_pat: PlanPattern = .{ .kind = .filter, .capture_index = 0 };
    const rule: PatternRule = .{ .name = "drop-filter", .pattern = fil_pat, .build = buildDropFilter };

    const res = applyRecursive(rule, testing.allocator, &prj);
    try testing.expectEqual(@as(usize, 1), res.fired_count);
    // prj's child is now the scan (filter dropped).
    try testing.expect(prj.project.input.* == .scan);
}

test "applyRecursive does not fire when no subtree matches" {
    var scan: PlanNode = .{ .scan = .{ .table = 1, .projected = &[_]u32{1} } };
    const fil_pat: PlanPattern = .{ .kind = .filter, .capture_index = 0 };
    const rule: PatternRule = .{ .name = "drop-filter", .pattern = fil_pat, .build = buildDropFilter };
    const res = applyRecursive(rule, testing.allocator, &scan);
    try testing.expectEqual(@as(usize, 0), res.fired_count);
}

test "applyRecursive walks bottom-up so child filter drops before parent sees it" {
    // Tree: filter(filter(scan)). Bottom-up: inner filter drops
    // first (child becomes scan), then outer filter sees its child
    // is a scan and drops too.
    var scan: PlanNode = .{ .scan = .{ .table = 1, .projected = &[_]u32{1} } };
    var inner_fil: PlanNode = .{ .filter = .{ .input = &scan, .predicate = 1 } };
    var outer_fil: PlanNode = .{ .filter = .{ .input = &inner_fil, .predicate = 2 } };
    const fil_pat: PlanPattern = .{ .kind = .filter, .capture_index = 0 };
    const rule: PatternRule = .{ .name = "drop-filter", .pattern = fil_pat, .build = buildDropFilter };

    const res = applyRecursive(rule, testing.allocator, &outer_fil);
    // Inner filter drops + outer filter drops = 2 firings.
    try testing.expectEqual(@as(usize, 2), res.fired_count);
    try testing.expect(outer_fil == .scan);
}

test "applyRecursiveAll runs many rules to quiescence" {
    var scan: PlanNode = .{ .scan = .{ .table = 1, .projected = &[_]u32{1} } };
    var fil: PlanNode = .{ .filter = .{ .input = &scan, .predicate = 0 } };
    var prj: PlanNode = .{ .project = .{ .input = &fil, .columns = &[_]u32{1} } };
    const fil_pat: PlanPattern = .{ .kind = .filter, .capture_index = 0 };
    const rule: PatternRule = .{ .name = "drop-filter", .pattern = fil_pat, .build = buildDropFilter };
    const rules = [_]PatternRule{rule};
    const res = applyRecursiveAll(&rules, testing.allocator, &prj, 8);
    try testing.expectEqual(@as(usize, 1), res.fired_count);
    try testing.expect(prj.project.input.* == .scan);
}

test "applyRecursive on deep nested filters drops all of them" {
    // Tree: filter(filter(filter(scan)))
    var scan: PlanNode = .{ .scan = .{ .table = 1, .projected = &[_]u32{1} } };
    var f1: PlanNode = .{ .filter = .{ .input = &scan, .predicate = 1 } };
    var f2: PlanNode = .{ .filter = .{ .input = &f1, .predicate = 2 } };
    var f3: PlanNode = .{ .filter = .{ .input = &f2, .predicate = 3 } };
    const fil_pat: PlanPattern = .{ .kind = .filter, .capture_index = 0 };
    const rule: PatternRule = .{ .name = "drop-filter", .pattern = fil_pat, .build = buildDropFilter };
    const res = applyRecursive(rule, testing.allocator, &f3);
    try testing.expectEqual(@as(usize, 3), res.fired_count);
    try testing.expect(f3 == .scan);
}

// Allocation budget for the applyRecursive walk under a never-firing
// rule. Demonstrates the substrate testing itself against the
// Landseed zero-alloc hot-path shape (S-L83-6 shipped in
// thompson-bandit v0.0.4). The walk descends the tree and invokes
// applyOnce at each subtree; for a rule whose pattern does not
// match any node, applyOnce never calls its build callback, so the
// recursion machinery itself must be allocation-free.
const tb = @import("thompson_bandit");

const NoFireCtx = struct {
    rule: PatternRule,
    node: *PlanNode,
};

fn applyRecursiveBody(ctx: NoFireCtx, alloc: std.mem.Allocator) void {
    _ = applyRecursive(ctx.rule, alloc, ctx.node);
}

fn neverMatchBuild(allocator: std.mem.Allocator, m: pattern_match.Match) ?PlanNode {
    _ = allocator;
    _ = m;
    return null;
}

test "applyRecursive on a never-firing rule is allocation-free" {
    var scan: PlanNode = .{ .scan = .{ .table = 1, .projected = &[_]u32{1} } };
    var f1: PlanNode = .{ .filter = .{ .input = &scan, .predicate = 1 } };
    var prj: PlanNode = .{ .project = .{ .input = &f1, .columns = &[_]u32{1} } };

    // A pattern that asks for an unknown table id. applyOnce will
    // refuse to match every node in the tree, so no build call lands.
    const never_pat: PlanPattern = .{ .kind = .scan, .scan_table = 0xDEAD_BEEF };
    const rule: PatternRule = .{
        .name = "never-fire",
        .pattern = never_pat,
        .build = neverMatchBuild,
    };
    try tb.expectNoAllocations(
        testing.allocator,
        NoFireCtx,
        .{ .rule = rule, .node = &prj },
        applyRecursiveBody,
    );
}
