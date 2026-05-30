//! customer_pipeline: v0.0.28 substrate from L95 fathom-companion.
//!
//! L95 named the CustomerPipeline trait pattern: one envelope
//! type (Frame) with N adapter implementations, each consuming a
//! Frame and producing a customer-derived value (Derived).
//! emit_frame is the generic orchestrator that loops over the
//! adapter slate.
//!
//! Generic shape: any pipeline that translates one upstream
//! event into multiple downstream consumers, each with its own
//! transformation. ETL fan-out, multi-format event broadcast,
//! per-customer billing adapters.
//!
//! Scope of this revision:
//!   AdapterFn(comptime FrameT, comptime DerivedT): fn(FrameT)
//!     DerivedT.
//!   CustomerPipeline(FrameT, DerivedT) holds a slice of
//!     AdapterFn pointers.
//!   init(adapters) wraps the slate.
//!   emitFrame(self, allocator, frame) loops every adapter,
//!     returns a slice of Derived (caller owns).
//!   nAdapters accessor.
//!
//! Out of scope: parallel adapter dispatch (caller composes a
//! thread pool), per-adapter filtering (caller wraps with an
//! AdapterFn that returns a sentinel), backpressure (caller-
//! policy at the boundary).

const std = @import("std");

pub const Error = error{
    OutOfMemory,
};

pub fn AdapterFn(comptime FrameT: type, comptime DerivedT: type) type {
    return *const fn (FrameT) DerivedT;
}

pub fn CustomerPipeline(comptime FrameT: type, comptime DerivedT: type) type {
    return struct {
        adapters: []const AdapterFn(FrameT, DerivedT),

        const Self = @This();

        pub fn init(adapters: []const AdapterFn(FrameT, DerivedT)) Self {
            return .{ .adapters = adapters };
        }

        pub fn nAdapters(self: Self) usize {
            return self.adapters.len;
        }

        pub fn emitFrame(
            self: Self,
            allocator: std.mem.Allocator,
            frame: FrameT,
        ) Error![]DerivedT {
            const out = allocator.alloc(DerivedT, self.adapters.len) catch return Error.OutOfMemory;
            for (self.adapters, 0..) |a, i| out[i] = a(frame);
            return out;
        }
    };
}

// --- Tests -----------------------------------------------------------------

const testing = std.testing;

const TestFrame = struct { value: i32 };
const TestDerived = struct { computed: i64 };

fn doubleAdapter(f: TestFrame) TestDerived {
    return .{ .computed = @as(i64, f.value) * 2 };
}

fn squareAdapter(f: TestFrame) TestDerived {
    return .{ .computed = @as(i64, f.value) * @as(i64, f.value) };
}

fn negateAdapter(f: TestFrame) TestDerived {
    return .{ .computed = -@as(i64, f.value) };
}

test "emitFrame produces one Derived per adapter in order" {
    const adapters = [_]AdapterFn(TestFrame, TestDerived){ doubleAdapter, squareAdapter, negateAdapter };
    const pipe = CustomerPipeline(TestFrame, TestDerived).init(&adapters);
    const out = try pipe.emitFrame(testing.allocator, .{ .value = 5 });
    defer testing.allocator.free(out);
    try testing.expectEqual(@as(usize, 3), out.len);
    try testing.expectEqual(@as(i64, 10), out[0].computed);
    try testing.expectEqual(@as(i64, 25), out[1].computed);
    try testing.expectEqual(@as(i64, -5), out[2].computed);
}

test "empty adapter slate returns empty slice" {
    const adapters: []const AdapterFn(TestFrame, TestDerived) = &.{};
    const pipe = CustomerPipeline(TestFrame, TestDerived).init(adapters);
    const out = try pipe.emitFrame(testing.allocator, .{ .value = 5 });
    defer testing.allocator.free(out);
    try testing.expectEqual(@as(usize, 0), out.len);
}

test "single adapter pipeline" {
    const adapters = [_]AdapterFn(TestFrame, TestDerived){doubleAdapter};
    const pipe = CustomerPipeline(TestFrame, TestDerived).init(&adapters);
    const out = try pipe.emitFrame(testing.allocator, .{ .value = 7 });
    defer testing.allocator.free(out);
    try testing.expectEqual(@as(usize, 1), out.len);
    try testing.expectEqual(@as(i64, 14), out[0].computed);
}

test "nAdapters reports slate size" {
    const adapters = [_]AdapterFn(TestFrame, TestDerived){ doubleAdapter, squareAdapter };
    const pipe = CustomerPipeline(TestFrame, TestDerived).init(&adapters);
    try testing.expectEqual(@as(usize, 2), pipe.nAdapters());
}

test "same pipeline can emit multiple frames" {
    const adapters = [_]AdapterFn(TestFrame, TestDerived){doubleAdapter};
    const pipe = CustomerPipeline(TestFrame, TestDerived).init(&adapters);
    const out1 = try pipe.emitFrame(testing.allocator, .{ .value = 3 });
    defer testing.allocator.free(out1);
    const out2 = try pipe.emitFrame(testing.allocator, .{ .value = 4 });
    defer testing.allocator.free(out2);
    try testing.expectEqual(@as(i64, 6), out1[0].computed);
    try testing.expectEqual(@as(i64, 8), out2[0].computed);
}

test "L95 fathom-companion style: one Frame fans out to N derived" {
    const adapters = [_]AdapterFn(TestFrame, TestDerived){ doubleAdapter, squareAdapter, negateAdapter };
    const pipe = CustomerPipeline(TestFrame, TestDerived).init(&adapters);
    const frames = [_]TestFrame{ .{ .value = 1 }, .{ .value = 2 }, .{ .value = 3 } };
    for (frames) |f| {
        const out = try pipe.emitFrame(testing.allocator, f);
        defer testing.allocator.free(out);
        try testing.expectEqual(@as(usize, 3), out.len);
    }
}
