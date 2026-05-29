//! rule — pattern-match transformation rules + fixed-point iterator.
//!
//! Ports Catalyst L844 + Materialize L987 rule-based optimisation
//! into a Zig substrate. A `Rule` is an arbitrary node transformer
//! function. The `RuleEngine` runs every rule repeatedly until either
//! no rule fires for a full pass (fixed point reached) OR a
//! caller-bounded max-iterations cap trips.
//!
//! The node type is opaque — the engine is over a `Plan` value that
//! supports `clone(allocator)` + equality. v0.0.3 ships a tagged
//! `PlanNode` enum with three demo node kinds (Scan, Filter, Project)
//! + three demo rules (push-projection-through-filter, drop-empty-
//! filter, fold-double-projection). v0.0.4 will turn `PlanNode` into
//! a generic + ship a richer rule library.

const std = @import("std");

pub const NodeId = u32;
pub const ColumnSet = []const u32;

/// Demo plan AST. Real users supply their own; we ship a small one
/// to exercise the rule engine end-to-end.
pub const PlanNode = union(enum) {
    scan: struct { table: u64, projected: []const u32 },
    filter: struct { input: *PlanNode, predicate: u32 },
    project: struct { input: *PlanNode, columns: []const u32 },

    pub fn isEmptyFilter(self: PlanNode) bool {
        return switch (self) {
            .filter => |f| f.predicate == 0,
            else => false,
        };
    }
};

pub const Rule = struct {
    name: []const u8,
    /// Returns true if the rule fired (mutated `node`). The engine
    /// keeps looping as long as some rule fires. Mutations are
    /// expected to be O(1) at the local node + caller-arena-allocated.
    apply: *const fn (allocator: std.mem.Allocator, node: *PlanNode) bool,
};

pub const RuleEngine = struct {
    allocator: std.mem.Allocator,
    rules: std.array_list.Managed(Rule),
    /// Soft cap on rule-engine iterations; v0.0.3 default 32.
    max_iterations: u32 = 32,
    last_iterations: u32 = 0,

    pub fn init(allocator: std.mem.Allocator) RuleEngine {
        return .{ .allocator = allocator, .rules = .init(allocator) };
    }

    pub fn deinit(self: *RuleEngine) void {
        self.rules.deinit();
    }

    pub fn addRule(self: *RuleEngine, rule: Rule) !void {
        try self.rules.append(rule);
    }

    /// Run every rule against `root` repeatedly until no rule fires
    /// in a single pass or `max_iterations` trips. Mutates `root`
    /// in place. Returns the number of passes the engine performed.
    pub fn run(self: *RuleEngine, root: *PlanNode) u32 {
        var iter: u32 = 0;
        while (iter < self.max_iterations) : (iter += 1) {
            var fired = false;
            for (self.rules.items) |r| {
                if (r.apply(self.allocator, root)) fired = true;
            }
            if (!fired) {
                self.last_iterations = iter + 1;
                return iter + 1;
            }
        }
        self.last_iterations = self.max_iterations;
        return self.max_iterations;
    }
};

// --- Demo rules -----------------------------------------------------------

/// drop-empty-filter: replace `Filter(predicate=0, X)` with `X`.
/// (predicate=0 is our sentinel for "always true".)
pub fn dropEmptyFilter(allocator: std.mem.Allocator, node: *PlanNode) bool {
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

/// fold-double-projection: `Project(c1, Project(c2, X))` becomes
/// `Project(c1 ∩ c2, X)` (assuming c1 ⊆ c2 — v0.0.3 ships the
/// strict-subset variant).
pub fn foldDoubleProjection(allocator: std.mem.Allocator, node: *PlanNode) bool {
    _ = allocator;
    switch (node.*) {
        .project => |outer| switch (outer.input.*) {
            .project => |inner| {
                // v0.0.3: only fold when outer columns are a subset
                // of inner columns. We trust the caller's ordering;
                // a real planner runs a `containsAll` check.
                var subset = true;
                for (outer.columns) |c| {
                    var found = false;
                    for (inner.columns) |c2| if (c == c2) {
                        found = true;
                        break;
                    };
                    if (!found) {
                        subset = false;
                        break;
                    }
                }
                if (subset) {
                    node.* = .{ .project = .{ .input = inner.input, .columns = outer.columns } };
                    return true;
                }
            },
            else => {},
        },
        else => {},
    }
    return false;
}

/// push-projection-through-filter: `Project(c, Filter(p, X))`
/// becomes `Filter(p, Project(c ∪ p_cols, X))`. v0.0.3 doesn't
/// know which columns the predicate touches so this rule is a stub
/// that always returns false; v0.0.4 wires predicate-column metadata.
pub fn pushProjectionThroughFilter(allocator: std.mem.Allocator, node: *PlanNode) bool {
    _ = allocator;
    _ = node;
    return false;
}

// --- Tests ----------------------------------------------------------------

const testing = std.testing;

test "dropEmptyFilter — Filter(predicate=0, Scan) collapses to Scan" {
    var scan: PlanNode = .{ .scan = .{ .table = 1, .projected = &.{ 1, 2 } } };
    var filter: PlanNode = .{ .filter = .{ .input = &scan, .predicate = 0 } };

    const fired = dropEmptyFilter(testing.allocator, &filter);
    try testing.expect(fired);
    try testing.expect(filter == .scan);
    try testing.expectEqual(@as(u64, 1), filter.scan.table);
}

test "dropEmptyFilter does not fire on Filter(predicate=42)" {
    var scan: PlanNode = .{ .scan = .{ .table = 1, .projected = &.{1} } };
    var filter: PlanNode = .{ .filter = .{ .input = &scan, .predicate = 42 } };
    const fired = dropEmptyFilter(testing.allocator, &filter);
    try testing.expect(!fired);
}

test "foldDoubleProjection collapses Project(outer ⊆ inner)" {
    var scan: PlanNode = .{ .scan = .{ .table = 1, .projected = &.{ 1, 2, 3, 4 } } };
    var inner: PlanNode = .{ .project = .{ .input = &scan, .columns = &[_]u32{ 1, 2, 3 } } };
    var outer: PlanNode = .{ .project = .{ .input = &inner, .columns = &[_]u32{ 1, 2 } } };

    const fired = foldDoubleProjection(testing.allocator, &outer);
    try testing.expect(fired);
    // After fold, outer's input should be the original scan.
    try testing.expect(outer.project.input == &scan);
}

test "foldDoubleProjection does not fire when outer ⊄ inner" {
    var scan: PlanNode = .{ .scan = .{ .table = 1, .projected = &.{1} } };
    var inner: PlanNode = .{ .project = .{ .input = &scan, .columns = &[_]u32{ 1, 2 } } };
    var outer: PlanNode = .{ .project = .{ .input = &inner, .columns = &[_]u32{ 1, 3 } } };
    const fired = foldDoubleProjection(testing.allocator, &outer);
    try testing.expect(!fired);
}

test "RuleEngine reaches fixed point in a bounded number of iterations" {
    var engine: RuleEngine = .init(testing.allocator);
    defer engine.deinit();
    try engine.addRule(.{ .name = "drop-empty-filter", .apply = dropEmptyFilter });

    var scan: PlanNode = .{ .scan = .{ .table = 1, .projected = &.{1} } };
    var filter: PlanNode = .{ .filter = .{ .input = &scan, .predicate = 0 } };
    const passes = engine.run(&filter);
    // First pass fires; second pass nothing fires → engine exits.
    try testing.expect(passes <= 3);
    try testing.expect(filter == .scan);
}

test "RuleEngine caps at max_iterations on a non-terminating rule" {
    var engine: RuleEngine = .init(testing.allocator);
    defer engine.deinit();
    engine.max_iterations = 5;
    const always_fires = Rule{
        .name = "loop",
        .apply = struct {
            fn f(_: std.mem.Allocator, _: *PlanNode) bool {
                return true;
            }
        }.f,
    };
    try engine.addRule(always_fires);
    var scan: PlanNode = .{ .scan = .{ .table = 1, .projected = &.{1} } };
    const passes = engine.run(&scan);
    try testing.expectEqual(@as(u32, 5), passes);
    try testing.expectEqual(@as(u32, 5), engine.last_iterations);
}

test "RuleEngine returns 1 when no rules fire at all" {
    var engine: RuleEngine = .init(testing.allocator);
    defer engine.deinit();
    try engine.addRule(.{ .name = "noop", .apply = pushProjectionThroughFilter });
    var scan: PlanNode = .{ .scan = .{ .table = 1, .projected = &.{1} } };
    const passes = engine.run(&scan);
    try testing.expectEqual(@as(u32, 1), passes);
}
