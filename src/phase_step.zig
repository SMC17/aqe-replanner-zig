//! phase_step: v0.0.27 substrate from L110 zphotonic_tesla.
//!
//! L110 named PhaseInterlacedFieldComposition as the orchestration
//! shape the v0.2 capstone collapses to: N coupled subsystems
//! sharing one allocation, executing in fixed phase order per
//! timestep. Generic beyond physics: pipeline stages with
//! shared mutable state and declared phase order (DB write-then-
//! flush, network send-then-confirm, build compile-then-link).
//!
//! Port a small executor that takes an opaque shared-state
//! pointer, a slice of PhaseStepFn(StateT), and runs them in
//! the slice order. Each phase mutates the shared state in-place;
//! the executor just sequences. Returns the n_steps it executed
//! plus the running tick count.
//!
//! Scope of this revision:
//!   PhaseStepFn(StateT): fn(*StateT, tick: u64) void.
//!   PhaseStepExecutor { state, phases, tick_count }.
//!   init(state, phases) wraps a state pointer + the phase slice.
//!   tick() runs every phase in order, increments tick_count.
//!   tickN(n) runs n ticks.
//!
//! Out of scope: per-phase conditional skip (caller writes that
//! into the phase fn), parallel phase execution (sequential by
//! design for determinism), dynamic phase reordering (caller
//! reinitializes with a new slice).

const std = @import("std");

pub fn PhaseStepFn(comptime StateT: type) type {
    return *const fn (*StateT, tick: u64) void;
}

pub fn PhaseStepExecutor(comptime StateT: type) type {
    return struct {
        state: *StateT,
        phases: []const PhaseStepFn(StateT),
        tick_count: u64,

        const Self = @This();

        pub fn init(state: *StateT, phases: []const PhaseStepFn(StateT)) Self {
            return .{ .state = state, .phases = phases, .tick_count = 0 };
        }

        pub fn tick(self: *Self) void {
            for (self.phases) |p| p(self.state, self.tick_count);
            self.tick_count += 1;
        }

        pub fn tickN(self: *Self, n: u64) void {
            var i: u64 = 0;
            while (i < n) : (i += 1) self.tick();
        }
    };
}

// --- Tests -----------------------------------------------------------------

const testing = std.testing;

const TestState = struct {
    counter: u64,
    last_tick: u64,
    phase_a_count: u64,
    phase_b_count: u64,
    phase_c_count: u64,
};

fn phaseA(s: *TestState, _: u64) void {
    s.counter += 1;
    s.phase_a_count += 1;
}

fn phaseB(s: *TestState, t: u64) void {
    s.last_tick = t;
    s.phase_b_count += 1;
}

fn phaseC(s: *TestState, _: u64) void {
    s.counter *= 2;
    s.phase_c_count += 1;
}

test "tick runs every phase once per tick in slice order" {
    var s: TestState = .{
        .counter = 0,
        .last_tick = 0,
        .phase_a_count = 0,
        .phase_b_count = 0,
        .phase_c_count = 0,
    };
    const phases = [_]PhaseStepFn(TestState){ phaseA, phaseB, phaseC };
    var exec = PhaseStepExecutor(TestState).init(&s, &phases);
    exec.tick();
    try testing.expectEqual(@as(u64, 1), s.phase_a_count);
    try testing.expectEqual(@as(u64, 1), s.phase_b_count);
    try testing.expectEqual(@as(u64, 1), s.phase_c_count);
    try testing.expectEqual(@as(u64, 2), s.counter);
    try testing.expectEqual(@as(u64, 1), exec.tick_count);
}

test "phase order matters: A then C gives (counter+1)*2" {
    var s: TestState = .{
        .counter = 5,
        .last_tick = 0,
        .phase_a_count = 0,
        .phase_b_count = 0,
        .phase_c_count = 0,
    };
    const phases = [_]PhaseStepFn(TestState){ phaseA, phaseC };
    var exec = PhaseStepExecutor(TestState).init(&s, &phases);
    exec.tick();
    try testing.expectEqual(@as(u64, 12), s.counter);
}

test "phase order reverse: C then A gives counter*2+1" {
    var s: TestState = .{
        .counter = 5,
        .last_tick = 0,
        .phase_a_count = 0,
        .phase_b_count = 0,
        .phase_c_count = 0,
    };
    const phases = [_]PhaseStepFn(TestState){ phaseC, phaseA };
    var exec = PhaseStepExecutor(TestState).init(&s, &phases);
    exec.tick();
    try testing.expectEqual(@as(u64, 11), s.counter);
}

test "tickN runs N ticks" {
    var s: TestState = .{
        .counter = 0,
        .last_tick = 0,
        .phase_a_count = 0,
        .phase_b_count = 0,
        .phase_c_count = 0,
    };
    const phases = [_]PhaseStepFn(TestState){phaseA};
    var exec = PhaseStepExecutor(TestState).init(&s, &phases);
    exec.tickN(10);
    try testing.expectEqual(@as(u64, 10), s.phase_a_count);
    try testing.expectEqual(@as(u64, 10), exec.tick_count);
}

test "tick provides current tick number to each phase" {
    var s: TestState = .{
        .counter = 0,
        .last_tick = 999,
        .phase_a_count = 0,
        .phase_b_count = 0,
        .phase_c_count = 0,
    };
    const phases = [_]PhaseStepFn(TestState){phaseB};
    var exec = PhaseStepExecutor(TestState).init(&s, &phases);
    exec.tick();
    try testing.expectEqual(@as(u64, 0), s.last_tick);
    exec.tick();
    try testing.expectEqual(@as(u64, 1), s.last_tick);
    exec.tick();
    try testing.expectEqual(@as(u64, 2), s.last_tick);
}

test "empty phase slice is valid no-op tick" {
    var s: TestState = .{
        .counter = 0,
        .last_tick = 0,
        .phase_a_count = 0,
        .phase_b_count = 0,
        .phase_c_count = 0,
    };
    const phases: []const PhaseStepFn(TestState) = &.{};
    var exec = PhaseStepExecutor(TestState).init(&s, phases);
    exec.tick();
    try testing.expectEqual(@as(u64, 1), exec.tick_count);
    try testing.expectEqual(@as(u64, 0), s.counter);
}

test "L110 zphotonic_tesla style: phase-interlaced shared state" {
    var s: TestState = .{
        .counter = 0,
        .last_tick = 0,
        .phase_a_count = 0,
        .phase_b_count = 0,
        .phase_c_count = 0,
    };
    const phases = [_]PhaseStepFn(TestState){ phaseA, phaseB, phaseC };
    var exec = PhaseStepExecutor(TestState).init(&s, &phases);
    exec.tickN(5);
    try testing.expectEqual(@as(u64, 5), s.phase_a_count);
    try testing.expectEqual(@as(u64, 5), s.phase_b_count);
    try testing.expectEqual(@as(u64, 5), s.phase_c_count);
    try testing.expectEqual(@as(u64, 4), s.last_tick);
}
