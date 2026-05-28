//! replay_replanner — replay-side re-derivation of plan decisions.
//!
//! On a fresh workflow run, the `Replanner` Thompson-samples per
//! decision site + writes the chosen `(site, variant, succeeded)`
//! payload to the workflow event log via `recordOutcome`. On a
//! replay, the workflow code wants to ask "what variant did I pick
//! at this site on the original run?" — re-sampling would not
//! reproduce the same choice unless the RNG seed is locked.
//!
//! `ReplayReplanner` reads the log once and builds a `site → variant`
//! map. `decideOrReplay(rng, site, variants)` returns the recorded
//! variant if one exists for the site, else delegates to fresh
//! Thompson sampling via the supplied `Replanner` (which also bumps
//! the in-memory posterior).
//!
//! v0.0.2 (this commit) ships the in-memory scan + map.
//! v0.0.3 wires a streaming cursor (no full scan per call) + handles
//! revisits: a workflow that re-enters the same site at a higher
//! seq picks the latest recorded variant.

const std = @import("std");
const replanner_mod = @import("replanner.zig");
const wflog = @import("workflow_event_log");

pub const DecisionSiteId = replanner_mod.DecisionSiteId;
pub const VariantId = replanner_mod.VariantId;
pub const Replanner = replanner_mod.Replanner;
pub const PlanVariant = replanner_mod.PlanVariant;

pub const Error = error{
    LogReadFailed,
    UnknownVariantInLog,
    OutOfMemory,
};

pub const ReplayReplanner = struct {
    allocator: std.mem.Allocator,
    inner: *Replanner,
    /// `site_id → variant_id` recorded in the supplied log for this
    /// workflow. Populated by `loadFromLog`.
    recorded: std.AutoHashMap(DecisionSiteId, VariantId),

    pub fn init(allocator: std.mem.Allocator, inner: *Replanner) ReplayReplanner {
        return .{
            .allocator = allocator,
            .inner = inner,
            .recorded = .init(allocator),
        };
    }

    pub fn deinit(self: *ReplayReplanner) void {
        self.recorded.deinit();
    }

    /// Walk every event in the workflow stream and ingest every
    /// `activity_completed` or `activity_failed` event whose payload
    /// matches the `aqe-replanner` 16-byte wire format. Later events
    /// overwrite earlier ones (the workflow may revisit a site).
    pub fn loadFromLog(
        self: *ReplayReplanner,
        log: *wflog.WorkflowLog,
        workflow_id: wflog.WorkflowId,
    ) Error!void {
        const stream_len = log.streamLen(workflow_id) orelse return Error.LogReadFailed;
        var seq: wflog.EventSeq = 1;
        while (seq <= stream_len) : (seq += 1) {
            const e = log.eventAt(workflow_id, seq) orelse continue;
            if (e.kind != .activity_completed and e.kind != .activity_failed) continue;
            if (e.bytes.len < 16) continue; // not aqe-replanner wire format
            const site = std.mem.readInt(u64, e.bytes[0..8], .little);
            const variant = std.mem.readInt(u32, e.bytes[8..12], .little);
            self.recorded.put(site, variant) catch return Error.OutOfMemory;
        }
    }

    pub fn recordedVariantFor(
        self: *ReplayReplanner,
        site: DecisionSiteId,
    ) ?VariantId {
        return self.recorded.get(site);
    }

    /// If the log has a recorded variant for `site`, return it
    /// (replay path — no fresh sampling). Otherwise, fall through to
    /// the inner `Replanner.decide` (first-run path — samples
    /// posterior, advances RNG).
    pub fn decideOrReplay(
        self: *ReplayReplanner,
        rng: *std.Random.DefaultPrng,
        site: DecisionSiteId,
        variants: []const PlanVariant,
    ) replanner_mod.Error!VariantId {
        if (self.recorded.get(site)) |v| return v;
        return self.inner.decide(rng, site, variants);
    }
};

// --- Tests ----------------------------------------------------------------

const testing = std.testing;
const bandit = @import("thompson_bandit");

test "loadFromLog ingests one decision per site" {
    const alloc = testing.allocator;
    var log: wflog.WorkflowLog = .init(alloc);
    defer log.deinit();
    try log.append(1, 1, 100, .workflow_started, "");

    // Append two decisions: (site=42, variant=7) + (site=43, variant=99).
    const a = try replanner_mod.encodeDecisionPayload(alloc, 42, 7, true);
    defer alloc.free(a);
    try log.append(1, 2, 200, .activity_completed, a);
    const b = try replanner_mod.encodeDecisionPayload(alloc, 43, 99, false);
    defer alloc.free(b);
    try log.append(1, 3, 300, .activity_failed, b);

    var inner: Replanner = .init(alloc);
    defer inner.deinit();
    var rr: ReplayReplanner = .init(alloc, &inner);
    defer rr.deinit();
    try rr.loadFromLog(&log, 1);

    try testing.expectEqual(@as(?VariantId, 7), rr.recordedVariantFor(42));
    try testing.expectEqual(@as(?VariantId, 99), rr.recordedVariantFor(43));
    try testing.expectEqual(@as(?VariantId, null), rr.recordedVariantFor(99));
}

test "decideOrReplay returns recorded variant + does not advance RNG" {
    const alloc = testing.allocator;
    var log: wflog.WorkflowLog = .init(alloc);
    defer log.deinit();
    try log.append(1, 1, 100, .workflow_started, "");

    // Pre-seed log with (site=10, variant=22).
    const payload = try replanner_mod.encodeDecisionPayload(alloc, 10, 22, true);
    defer alloc.free(payload);
    try log.append(1, 2, 200, .activity_completed, payload);

    var inner: Replanner = .init(alloc);
    defer inner.deinit();
    var rr: ReplayReplanner = .init(alloc, &inner);
    defer rr.deinit();
    try rr.loadFromLog(&log, 1);

    // Use two distinct RNGs to verify decideOrReplay does NOT consume
    // a draw on the replay path.
    var rng_a = bandit.rngFromSeed(7);
    var rng_b = bandit.rngFromSeed(7);
    const variants = [_]PlanVariant{
        .{ .id = 22, .label = "x" },
        .{ .id = 33, .label = "y" },
    };
    const v = try rr.decideOrReplay(&rng_a, 10, &variants);
    try testing.expectEqual(@as(VariantId, 22), v);
    // rng_a is untouched on the replay path, so should still equal rng_b.
    try testing.expectEqual(rng_a.next(), rng_b.next());
}

test "decideOrReplay falls through to inner Replanner.decide on unknown site" {
    const alloc = testing.allocator;
    var log: wflog.WorkflowLog = .init(alloc);
    defer log.deinit();
    try log.append(1, 1, 100, .workflow_started, "");

    var inner: Replanner = .init(alloc);
    defer inner.deinit();
    var rr: ReplayReplanner = .init(alloc, &inner);
    defer rr.deinit();
    try rr.loadFromLog(&log, 1);

    var rng = bandit.rngFromSeed(99);
    const variants = [_]PlanVariant{
        .{ .id = 1, .label = "a" },
        .{ .id = 2, .label = "b" },
    };
    const v = try rr.decideOrReplay(&rng, 7, &variants);
    try testing.expect(v == 1 or v == 2);
}

test "loadFromLog skips short payloads (not aqe-replanner wire format)" {
    const alloc = testing.allocator;
    var log: wflog.WorkflowLog = .init(alloc);
    defer log.deinit();
    try log.append(1, 1, 100, .workflow_started, "");
    // Some other module's activity_completed payload (only 4 bytes).
    try log.append(1, 2, 200, .activity_completed, "abcd");

    var inner: Replanner = .init(alloc);
    defer inner.deinit();
    var rr: ReplayReplanner = .init(alloc, &inner);
    defer rr.deinit();
    try rr.loadFromLog(&log, 1);
    // Nothing recorded.
    try testing.expectEqual(@as(usize, 0), rr.recorded.count());
}

test "later entries overwrite earlier ones for the same site" {
    const alloc = testing.allocator;
    var log: wflog.WorkflowLog = .init(alloc);
    defer log.deinit();
    try log.append(1, 1, 100, .workflow_started, "");
    const first = try replanner_mod.encodeDecisionPayload(alloc, 99, 1, true);
    defer alloc.free(first);
    try log.append(1, 2, 200, .activity_completed, first);
    const second = try replanner_mod.encodeDecisionPayload(alloc, 99, 7, true);
    defer alloc.free(second);
    try log.append(1, 3, 300, .activity_completed, second);

    var inner: Replanner = .init(alloc);
    defer inner.deinit();
    var rr: ReplayReplanner = .init(alloc, &inner);
    defer rr.deinit();
    try rr.loadFromLog(&log, 1);
    try testing.expectEqual(@as(?VariantId, 7), rr.recordedVariantFor(99));
}
