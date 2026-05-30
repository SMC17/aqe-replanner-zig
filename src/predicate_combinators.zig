//! predicate_combinators: v0.0.24 — and/or/not over FitPredicate.
//!
//! topology_selector (v0.0.23) takes a single FitPredicate. Real
//! consumers want to compose multiple constraints (cost <= budget
//! AND topology_id != blacklisted AND has_required_capability).
//! Without combinators the caller writes a bespoke predicate per
//! site, fragmenting the slate-selection logic.
//!
//! Port standard AND / OR / NOT plus an "all of slice" helper.
//! Each combinator returns a new FitPredicate via a closure so
//! the caller can pass it straight to selectCheapestFitting.
//!
//! Scope of this revision:
//!   andP(a, b), orP(a, b), notP(a) take comptime FitPredicate
//!     references and synthesize a new FitPredicate.
//!   alwaysTrue, alwaysFalse identity constants for partial
//!     composition.
//!
//! Out of scope: dynamic (non-comptime) predicate lists (caller
//! composes via a small struct holding a slice of fns + a
//! foldAll loop), short-circuit benchmark variants.

const std = @import("std");
const topology_selector = @import("topology_selector.zig");

pub const Topology = topology_selector.Topology;
pub const FitPredicate = topology_selector.FitPredicate;

pub fn alwaysTrue(_: Topology) bool {
    return true;
}

pub fn alwaysFalse(_: Topology) bool {
    return false;
}

pub fn andP(comptime a: FitPredicate, comptime b: FitPredicate) FitPredicate {
    const Local = struct {
        fn pred(t: Topology) bool {
            return a(t) and b(t);
        }
    };
    return Local.pred;
}

pub fn orP(comptime a: FitPredicate, comptime b: FitPredicate) FitPredicate {
    const Local = struct {
        fn pred(t: Topology) bool {
            return a(t) or b(t);
        }
    };
    return Local.pred;
}

pub fn notP(comptime a: FitPredicate) FitPredicate {
    const Local = struct {
        fn pred(t: Topology) bool {
            return !a(t);
        }
    };
    return Local.pred;
}

// --- Tests -----------------------------------------------------------------

const testing = std.testing;

fn costUnder100(t: Topology) bool {
    return t.cost < 100;
}

fn idEvenAndNonZero(t: Topology) bool {
    return t.id != 0 and (t.id % 2) == 0;
}

test "alwaysTrue and alwaysFalse identity" {
    const t: Topology = .{ .id = 1, .cost = 50 };
    try testing.expect(alwaysTrue(t));
    try testing.expect(!alwaysFalse(t));
}

test "andP composes two predicates with short-circuit AND" {
    const both = andP(costUnder100, idEvenAndNonZero);
    try testing.expect(both(.{ .id = 2, .cost = 50 }));
    try testing.expect(!both(.{ .id = 1, .cost = 50 }));
    try testing.expect(!both(.{ .id = 2, .cost = 200 }));
}

test "orP composes two predicates with OR" {
    const either = orP(costUnder100, idEvenAndNonZero);
    try testing.expect(either(.{ .id = 2, .cost = 200 }));
    try testing.expect(either(.{ .id = 1, .cost = 50 }));
    try testing.expect(!either(.{ .id = 1, .cost = 200 }));
}

test "notP inverts the inner predicate" {
    const not_cheap = notP(costUnder100);
    try testing.expect(not_cheap(.{ .id = 1, .cost = 200 }));
    try testing.expect(!not_cheap(.{ .id = 1, .cost = 50 }));
}

test "andP with alwaysTrue is identity" {
    const same = andP(costUnder100, alwaysTrue);
    try testing.expectEqual(costUnder100(.{ .id = 1, .cost = 50 }), same(.{ .id = 1, .cost = 50 }));
    try testing.expectEqual(costUnder100(.{ .id = 1, .cost = 200 }), same(.{ .id = 1, .cost = 200 }));
}

test "orP with alwaysFalse is identity" {
    const same = orP(costUnder100, alwaysFalse);
    try testing.expectEqual(costUnder100(.{ .id = 1, .cost = 50 }), same(.{ .id = 1, .cost = 50 }));
}

test "notP twice is involutive" {
    const same = notP(notP(costUnder100));
    try testing.expectEqual(costUnder100(.{ .id = 1, .cost = 50 }), same(.{ .id = 1, .cost = 50 }));
    try testing.expectEqual(costUnder100(.{ .id = 1, .cost = 200 }), same(.{ .id = 1, .cost = 200 }));
}

test "combinators compose with selectCheapestFitting" {
    const slate = [_]Topology{
        .{ .id = 1, .cost = 50 },
        .{ .id = 2, .cost = 75 },
        .{ .id = 4, .cost = 200 },
    };
    const cheap_and_even = andP(costUnder100, idEvenAndNonZero);
    const winner = topology_selector.selectCheapestFitting(&slate, cheap_and_even).?;
    try testing.expectEqual(@as(u32, 2), winner.id);
}
