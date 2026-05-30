//! topology_selector: v0.0.23 substrate from L91 fathom-fc.
//!
//! fathom-fc ships an Allocator that picks one of N pre-baked
//! topologies (allocation_quad_x, allocation_hex_y, ...) at
//! startup, based on hardware ID. The picked topology is fixed
//! for the life of the process; the runtime cost gate is "fits
//! the WCET budget on this hardware."
//!
//! Pattern generalized: caller supplies a finite slate of
//! candidate Topologies, each with a precomputed cost and a
//! caller-supplied boolean "fits" predicate. The selector
//! returns the cheapest topology whose predicate is true, or
//! null when no candidate fits.
//!
//! Distinct from the existing rule_library + pattern_match
//! firing: rules are fluid (any number, fire whenever predicate
//! holds, side-effects). Topologies are CLOSED at startup (slate
//! is fixed) and yield a single winner. Different shape, separate
//! primitive.
//!
//! Scope of this revision:
//!   Topology record carrying id, cost (u64), and an opaque
//!     payload pointer for callers that want to attach a baked
//!     plan or arena handle.
//!   FitPredicate alias for a fn(Topology) bool callback.
//!   selectCheapestFitting(slate, predicate) returns the cheapest
//!     fitting Topology or null.
//!   anyFits + cheapestCost convenience accessors.
//!
//! Out of scope: dynamic topology generation, per-context bandit
//! selection (linucb.zig already covers context-aware selection
//! over an open slate). This is the closed-slate fixed-cost
//! selector.

const std = @import("std");

pub const TopologyId = u32;

pub const Topology = struct {
    id: TopologyId,
    cost: u64,
    /// Opaque payload pointer; caller treats as a baked plan,
    /// arena handle, or topology-specific config. Selector does
    /// not dereference.
    payload: ?*const anyopaque = null,
};

pub const FitPredicate = *const fn (Topology) bool;

/// Return the cheapest Topology in the slate whose predicate is
/// true. Returns null if no candidate fits. Ties on cost are
/// broken by the first-seen winner (caller orders the slate to
/// reflect preference).
pub fn selectCheapestFitting(slate: []const Topology, fits: FitPredicate) ?Topology {
    var best: ?Topology = null;
    for (slate) |t| {
        if (!fits(t)) continue;
        if (best) |b| {
            if (t.cost < b.cost) best = t;
        } else {
            best = t;
        }
    }
    return best;
}

/// True iff at least one candidate fits. Cheaper alternative
/// when the caller does not need the winner record.
pub fn anyFits(slate: []const Topology, fits: FitPredicate) bool {
    for (slate) |t| {
        if (fits(t)) return true;
    }
    return false;
}

/// Cost of the cheapest fitting topology, or null if none fits.
pub fn cheapestFittingCost(slate: []const Topology, fits: FitPredicate) ?u64 {
    if (selectCheapestFitting(slate, fits)) |t| return t.cost;
    return null;
}

// --- Tests -----------------------------------------------------------------

const testing = std.testing;

fn always(_: Topology) bool {
    return true;
}

fn never(_: Topology) bool {
    return false;
}

fn costUnderHundred(t: Topology) bool {
    return t.cost < 100;
}

test "selectCheapestFitting returns null on empty slate" {
    try testing.expectEqual(@as(?Topology, null), selectCheapestFitting(&[_]Topology{}, always));
}

test "selectCheapestFitting returns the cheapest topology when all fit" {
    const slate = [_]Topology{
        .{ .id = 1, .cost = 300 },
        .{ .id = 2, .cost = 150 },
        .{ .id = 3, .cost = 200 },
    };
    const winner = selectCheapestFitting(&slate, always).?;
    try testing.expectEqual(@as(TopologyId, 2), winner.id);
    try testing.expectEqual(@as(u64, 150), winner.cost);
}

test "selectCheapestFitting skips candidates that fail the predicate" {
    const slate = [_]Topology{
        .{ .id = 1, .cost = 50 },
        .{ .id = 2, .cost = 75 },
        .{ .id = 3, .cost = 200 },
    };
    const winner = selectCheapestFitting(&slate, costUnderHundred).?;
    try testing.expectEqual(@as(TopologyId, 1), winner.id);
}

test "selectCheapestFitting returns null when nothing fits" {
    const slate = [_]Topology{
        .{ .id = 1, .cost = 100 },
        .{ .id = 2, .cost = 200 },
    };
    try testing.expectEqual(@as(?Topology, null), selectCheapestFitting(&slate, never));
}

test "ties on cost are broken by first-seen winner" {
    const slate = [_]Topology{
        .{ .id = 1, .cost = 100 },
        .{ .id = 2, .cost = 100 },
        .{ .id = 3, .cost = 100 },
    };
    const winner = selectCheapestFitting(&slate, always).?;
    try testing.expectEqual(@as(TopologyId, 1), winner.id);
}

test "anyFits true when at least one candidate qualifies" {
    const slate = [_]Topology{
        .{ .id = 1, .cost = 50 },
        .{ .id = 2, .cost = 500 },
    };
    try testing.expect(anyFits(&slate, costUnderHundred));
}

test "anyFits false when nothing qualifies" {
    const slate = [_]Topology{
        .{ .id = 1, .cost = 500 },
        .{ .id = 2, .cost = 600 },
    };
    try testing.expect(!anyFits(&slate, costUnderHundred));
}

test "cheapestFittingCost matches selectCheapestFitting cost" {
    const slate = [_]Topology{
        .{ .id = 1, .cost = 300 },
        .{ .id = 2, .cost = 50 },
        .{ .id = 3, .cost = 150 },
    };
    try testing.expectEqual(@as(?u64, 50), cheapestFittingCost(&slate, always));
}

test "payload survives selector round-trip" {
    var marker_a: u32 = 42;
    var marker_b: u32 = 99;
    const slate = [_]Topology{
        .{ .id = 1, .cost = 200, .payload = @ptrCast(&marker_a) },
        .{ .id = 2, .cost = 100, .payload = @ptrCast(&marker_b) },
    };
    const winner = selectCheapestFitting(&slate, always).?;
    const p: *const u32 = @ptrCast(@alignCast(winner.payload.?));
    try testing.expectEqual(@as(u32, 99), p.*);
}

test "L91 fathom-fc style: pick allocator topology by WCET budget" {
    const slate = [_]Topology{
        .{ .id = 100, .cost = 50 },
        .{ .id = 200, .cost = 150 },
        .{ .id = 300, .cost = 1000 },
    };
    const Local = struct {
        fn fits1kHzBudget(t: Topology) bool {
            return t.cost <= 200;
        }
    };
    const winner = selectCheapestFitting(&slate, Local.fits1kHzBudget).?;
    try testing.expectEqual(@as(TopologyId, 100), winner.id);
}
