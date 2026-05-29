//! pattern_match — Catalyst-style pattern matching over PlanNode AST.
//!
//! v0.0.7 OptimizerRule pairs a `matches(node) bool` predicate with
//! an `apply(allocator, node)` transformation. v0.0.8 adds a richer
//! pattern algebra: a `PlanPattern` is a recursive descriptor over
//! `PlanNode` shapes that can be tested for match, and on success
//! produces a `Match` with bound captures.
//!
//! Shapes supported:
//!   - any            — matches any node
//!   - scan_with(table) — matches `.scan{table}` (or any scan if
//!     table is null)
//!   - filter(inner)  — matches `.filter{...}` whose input matches
//!     `inner`
//!   - project(inner) — matches `.project{...}` whose input matches
//!     `inner`
//!
//! Captures:
//!   - inner-node pointers are recorded in `Match.captures` by index
//!     order of the wrapping pattern's traversal.
//!
//! Builders pair a `PlanPattern` with a `build(allocator, match) →
//! PlanNode` callback so the rule applies only when the pattern
//! matches. Composes with v0.0.7 OptimizerRule via a thin adapter.

const std = @import("std");
const plan_rule = @import("rule.zig");

pub const PlanNode = plan_rule.PlanNode;

pub const PatternKind = enum {
    any,
    scan,
    filter,
    project,
};

pub const PlanPattern = struct {
    kind: PatternKind,
    /// Only meaningful for `.scan`: null = match any table; non-null =
    /// match only nodes whose `scan.table` equals this value.
    scan_table: ?u64 = null,
    /// Only meaningful for `.filter` and `.project`. Tree of subordinate
    /// patterns. Owned by caller for `init` lifetime.
    child: ?*const PlanPattern = null,
    /// Capture index for this pattern's matched node. Allocated at
    /// match time; v0.0.8 caps captures at 4.
    capture_index: ?u8 = null,
};

pub const max_captures: usize = 4;

pub const Match = struct {
    captures: [max_captures]?*const PlanNode = .{ null, null, null, null },
};

pub fn matches(pattern: PlanPattern, node: *const PlanNode, m: *Match) bool {
    const node_match = switch (pattern.kind) {
        .any => true,
        .scan => switch (node.*) {
            .scan => |s| (pattern.scan_table == null) or (s.table == pattern.scan_table.?),
            else => false,
        },
        .filter => switch (node.*) {
            .filter => |f| (pattern.child == null) or matches(pattern.child.?.*, f.input, m),
            else => false,
        },
        .project => switch (node.*) {
            .project => |p| (pattern.child == null) or matches(pattern.child.?.*, p.input, m),
            else => false,
        },
    };
    if (!node_match) return false;
    if (pattern.capture_index) |idx| {
        if (idx < max_captures) m.captures[idx] = node;
    }
    return true;
}

pub fn match(pattern: PlanPattern, node: *const PlanNode) ?Match {
    var m: Match = .{};
    if (matches(pattern, node, &m)) return m;
    return null;
}

pub const BuilderFn = *const fn (allocator: std.mem.Allocator, m: Match) ?PlanNode;

pub const PatternRule = struct {
    name: []const u8,
    pattern: PlanPattern,
    build: BuilderFn,

    /// Apply once at the root. Returns true if the rule fired.
    pub fn applyOnce(self: PatternRule, allocator: std.mem.Allocator, node: *PlanNode) bool {
        const m = match(self.pattern, node) orelse return false;
        const built = self.build(allocator, m) orelse return false;
        node.* = built;
        return true;
    }
};

// --- Tests ----------------------------------------------------------------

const testing = std.testing;

fn buildDropFilter(allocator: std.mem.Allocator, m: Match) ?PlanNode {
    _ = allocator;
    const filter_node = m.captures[0] orelse return null;
    return switch (filter_node.*) {
        .filter => |f| f.input.*,
        else => null,
    };
}

test "pattern .any matches any node" {
    var scan: PlanNode = .{ .scan = .{ .table = 1, .projected = &[_]u32{1} } };
    const p: PlanPattern = .{ .kind = .any };
    try testing.expect(match(p, &scan) != null);
}

test "pattern .scan with table filter matches only matching scans" {
    var scan42: PlanNode = .{ .scan = .{ .table = 42, .projected = &[_]u32{1} } };
    var scan7: PlanNode = .{ .scan = .{ .table = 7, .projected = &[_]u32{1} } };
    const p: PlanPattern = .{ .kind = .scan, .scan_table = 42 };
    try testing.expect(match(p, &scan42) != null);
    try testing.expect(match(p, &scan7) == null);
}

test "pattern .scan with null table accepts any scan" {
    var scan: PlanNode = .{ .scan = .{ .table = 1, .projected = &[_]u32{1} } };
    var filter: PlanNode = .{ .filter = .{ .input = &scan, .predicate = 1 } };
    const p: PlanPattern = .{ .kind = .scan };
    try testing.expect(match(p, &scan) != null);
    try testing.expect(match(p, &filter) == null);
}

test "pattern .filter(.scan) matches filter wrapping scan" {
    var scan: PlanNode = .{ .scan = .{ .table = 1, .projected = &[_]u32{1} } };
    var filter_node: PlanNode = .{ .filter = .{ .input = &scan, .predicate = 1 } };
    const scan_pat: PlanPattern = .{ .kind = .scan };
    const filter_pat: PlanPattern = .{ .kind = .filter, .child = &scan_pat };
    try testing.expect(match(filter_pat, &filter_node) != null);
}

test "pattern .filter(.project(.scan)) — three-level nest" {
    var scan: PlanNode = .{ .scan = .{ .table = 1, .projected = &[_]u32{1} } };
    var prj: PlanNode = .{ .project = .{ .input = &scan, .columns = &[_]u32{1} } };
    var fil: PlanNode = .{ .filter = .{ .input = &prj, .predicate = 1 } };
    const scan_pat: PlanPattern = .{ .kind = .scan };
    const prj_pat: PlanPattern = .{ .kind = .project, .child = &scan_pat };
    const fil_pat: PlanPattern = .{ .kind = .filter, .child = &prj_pat };
    try testing.expect(match(fil_pat, &fil) != null);
    // Negative: mismatched intermediate (filter→filter→scan).
    var fil_outer: PlanNode = .{ .filter = .{ .input = &fil, .predicate = 1 } };
    try testing.expect(match(fil_pat, &fil_outer) == null);
}

test "capture_index records the matched node pointer" {
    var scan: PlanNode = .{ .scan = .{ .table = 1, .projected = &[_]u32{1} } };
    var filter_node: PlanNode = .{ .filter = .{ .input = &scan, .predicate = 0 } };
    const fil_pat: PlanPattern = .{ .kind = .filter, .capture_index = 0 };
    const m = match(fil_pat, &filter_node).?;
    try testing.expect(m.captures[0] == &filter_node);
}

test "PatternRule.applyOnce fires when pattern matches" {
    var scan: PlanNode = .{ .scan = .{ .table = 1, .projected = &[_]u32{1} } };
    var filter_node: PlanNode = .{ .filter = .{ .input = &scan, .predicate = 0 } };
    const fil_pat: PlanPattern = .{ .kind = .filter, .capture_index = 0 };
    const rule: PatternRule = .{ .name = "drop-filter", .pattern = fil_pat, .build = buildDropFilter };
    try testing.expect(rule.applyOnce(testing.allocator, &filter_node));
    try testing.expect(filter_node == .scan);
}

test "PatternRule.applyOnce does not fire when pattern misses" {
    var scan: PlanNode = .{ .scan = .{ .table = 1, .projected = &[_]u32{1} } };
    // Pattern needs filter, but node is scan.
    const fil_pat: PlanPattern = .{ .kind = .filter, .capture_index = 0 };
    const rule: PatternRule = .{ .name = "drop-filter", .pattern = fil_pat, .build = buildDropFilter };
    try testing.expect(!rule.applyOnce(testing.allocator, &scan));
}
