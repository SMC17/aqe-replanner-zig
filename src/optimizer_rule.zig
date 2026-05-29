//! optimizer_rule — DataFusion-style OptimizerRule trait.
//!
//! v0.0.3 Rule has a single `apply` fn that always tries to rewrite
//! the node and returns `true` iff it fired. DataFusion (L1450)
//! separates the contract into TWO phases:
//!
//!   matches(node) -> bool      — pattern guard
//!   apply(allocator, node)     — transformation (only called if
//!                                 matches returned true)
//!
//! This is strictly safer: the apply phase can assume preconditions
//! the matcher checked. It also opens the door to a rule LIBRARY
//! where rules compose into named families (filter-pushdown,
//! projection-pruning, predicate-normalisation).
//!
//! v0.0.7 ships:
//!   - `OptimizerRule { name, matches, apply }` value type.
//!   - `OptimizerEngine` runs every rule whose `matches` returns true
//!     until fixed point or `max_iterations` trips.
//!   - Compatibility: the v0.0.3 `Rule` shape is still exported by
//!     `rule.zig`; this is an alternative — both can coexist.
//!   - `rule_library.zig` registers cross-engine rules.

const std = @import("std");
const plan_rule = @import("rule.zig");

pub const PlanNode = plan_rule.PlanNode;

pub const OptimizerRule = struct {
    name: []const u8,
    matches: *const fn (node: PlanNode) bool,
    apply: *const fn (allocator: std.mem.Allocator, node: *PlanNode) bool,
};

pub const OptimizerEngine = struct {
    allocator: std.mem.Allocator,
    rules: std.array_list.Managed(OptimizerRule),
    max_iterations: u32 = 32,
    last_iterations: u32 = 0,
    fire_count: u64 = 0,
    block_count: u64 = 0,

    pub fn init(allocator: std.mem.Allocator) OptimizerEngine {
        return .{ .allocator = allocator, .rules = .init(allocator) };
    }

    pub fn deinit(self: *OptimizerEngine) void {
        self.rules.deinit();
    }

    pub fn addRule(self: *OptimizerEngine, rule: OptimizerRule) !void {
        try self.rules.append(rule);
    }

    pub fn run(self: *OptimizerEngine, root: *PlanNode) u32 {
        var iter: u32 = 0;
        while (iter < self.max_iterations) : (iter += 1) {
            var fired_any = false;
            for (self.rules.items) |r| {
                if (!r.matches(root.*)) {
                    self.block_count += 1;
                    continue;
                }
                if (r.apply(self.allocator, root)) {
                    self.fire_count += 1;
                    fired_any = true;
                } else {
                    self.block_count += 1;
                }
            }
            if (!fired_any) {
                self.last_iterations = iter + 1;
                return iter + 1;
            }
        }
        self.last_iterations = self.max_iterations;
        return self.max_iterations;
    }
};

// --- Tests ----------------------------------------------------------------

const testing = std.testing;

fn matchAlwaysTrue(_: PlanNode) bool {
    return true;
}

fn applyNoOp(_: std.mem.Allocator, _: *PlanNode) bool {
    return false;
}

test "OptimizerEngine reaches fixed point when no rule fires" {
    var eng: OptimizerEngine = .init(testing.allocator);
    defer eng.deinit();
    try eng.addRule(.{ .name = "noop", .matches = matchAlwaysTrue, .apply = applyNoOp });
    var scan: PlanNode = .{ .scan = .{ .table = 1, .projected = &[_]u32{1} } };
    const passes = eng.run(&scan);
    try testing.expectEqual(@as(u32, 1), passes);
}

fn matchFilterWithZeroPredicate(node: PlanNode) bool {
    return switch (node) {
        .filter => |f| f.predicate == 0,
        else => false,
    };
}

fn applyDropEmptyFilter(allocator: std.mem.Allocator, node: *PlanNode) bool {
    _ = allocator;
    switch (node.*) {
        .filter => |f| {
            if (f.predicate == 0) {
                node.* = f.input.*;
                return true;
            }
        },
        else => {},
    }
    return false;
}

test "rule with matches gate fires only on matching nodes" {
    var eng: OptimizerEngine = .init(testing.allocator);
    defer eng.deinit();
    try eng.addRule(.{
        .name = "drop-empty-filter",
        .matches = matchFilterWithZeroPredicate,
        .apply = applyDropEmptyFilter,
    });

    var scan: PlanNode = .{ .scan = .{ .table = 1, .projected = &[_]u32{1} } };
    var filter_node: PlanNode = .{ .filter = .{ .input = &scan, .predicate = 0 } };
    _ = eng.run(&filter_node);
    try testing.expect(filter_node == .scan);

    // A filter with predicate != 0 should not match.
    var scan2: PlanNode = .{ .scan = .{ .table = 1, .projected = &[_]u32{1} } };
    var nonzero_filter: PlanNode = .{ .filter = .{ .input = &scan2, .predicate = 42 } };
    _ = eng.run(&nonzero_filter);
    try testing.expect(nonzero_filter == .filter);
}

test "fire_count + block_count track engine telemetry" {
    var eng: OptimizerEngine = .init(testing.allocator);
    defer eng.deinit();
    try eng.addRule(.{
        .name = "drop-empty",
        .matches = matchFilterWithZeroPredicate,
        .apply = applyDropEmptyFilter,
    });

    var scan: PlanNode = .{ .scan = .{ .table = 1, .projected = &[_]u32{1} } };
    var filter_node: PlanNode = .{ .filter = .{ .input = &scan, .predicate = 0 } };
    _ = eng.run(&filter_node);
    try testing.expect(eng.fire_count >= 1);
}
