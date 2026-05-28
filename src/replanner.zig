//! aqe-replanner — adaptive query replanner composing thompson-bandit
//! + workflow-event-log.
//!
//! Ports Spark AQE L846 + Materialize L987 arrangement-reuse +
//! Catalyst L844 rule engine into a single Zig substrate.
//!
//! The seed: a query plan is a workflow. Each shuffle boundary
//! (Spark) or join site (Materialize) is a decision point at which
//! the optimiser picks one of K candidate variants. Each variant has
//! a Beta(α, β) posterior over its success rate, where success is
//! defined as "produced result within the cost budget."  At each
//! plan-time, sample posteriors → pick variant → record outcome →
//! update posterior. The workflow-event-log records every decision
//! + outcome so subsequent replays + audits stay deterministic.
//!
//! v0.0.1 ships:
//!   - QueryPlan / PlanVariant value types.
//!   - Replanner with per-(decision_site, variant) ArmPosterior.
//!   - `decide(rng, site, variants[])` samples posteriors + returns
//!     the chosen variant id.
//!   - `recordOutcome(site, variant, succeeded, log, seq, ts,
//!     workflow_id)` updates the posterior + writes an event to the
//!     log so the decision is replay-deterministic.
//!
//! v0.0.2 ships:
//!   - Context-aware bandit (LinUCB-style): per-feature posterior.
//!   - Workflow-event-log replay re-derives decisions from prior
//!     outcomes; no fresh sampling on replay.
//!
//! v0.0.3 ships:
//!   - Arrangement cache + delta-join planner (L987).
//!   - Cost model + late-materialisation rule.

const std = @import("std");
const bandit = @import("thompson_bandit");
const wflog = @import("workflow_event_log");

pub const DecisionSiteId = u64;
pub const VariantId = u32;

pub const PlanVariant = struct {
    id: VariantId,
    label: []const u8, // for debug; "broadcast-join" / "sort-merge-join" / etc.
};

pub const Error = error{
    UnknownSite,
    UnknownVariant,
    EmptyVariantList,
    LogAppendFailed,
    OutOfMemory,
};

/// Per (site_id, variant_id) lookup → ArmPosterior.
const SiteKey = struct {
    site: DecisionSiteId,
    variant: VariantId,

    fn hash(self: SiteKey) u64 {
        var x: u64 = self.site ^ (@as(u64, self.variant) +% 0x9E3779B97F4A7C15);
        x = (x ^ (x >> 30)) *% 0xBF58476D1CE4E5B9;
        x = (x ^ (x >> 27)) *% 0x94D049BB133111EB;
        return x ^ (x >> 31);
    }

    pub fn eql(a: SiteKey, b: SiteKey) bool {
        return a.site == b.site and a.variant == b.variant;
    }
};

const SiteKeyContext = struct {
    pub fn hash(_: SiteKeyContext, k: SiteKey) u64 {
        return k.hash();
    }
    pub fn eql(_: SiteKeyContext, a: SiteKey, b: SiteKey) bool {
        return SiteKey.eql(a, b);
    }
};

pub const Replanner = struct {
    allocator: std.mem.Allocator,
    posteriors: std.HashMap(SiteKey, bandit.ArmPosterior, SiteKeyContext, std.hash_map.default_max_load_percentage),

    pub fn init(allocator: std.mem.Allocator) Replanner {
        return .{
            .allocator = allocator,
            .posteriors = .init(allocator),
        };
    }

    pub fn deinit(self: *Replanner) void {
        self.posteriors.deinit();
    }

    fn posteriorFor(self: *Replanner, site: DecisionSiteId, variant: VariantId) !*bandit.ArmPosterior {
        const key: SiteKey = .{ .site = site, .variant = variant };
        const gop = try self.posteriors.getOrPut(key);
        if (!gop.found_existing) gop.value_ptr.* = .uniform();
        return gop.value_ptr;
    }

    /// Choose a variant for `site` by Thompson sampling across all
    /// supplied `variants`. Returns the chosen `VariantId`. The
    /// caller must subsequently run the variant and call
    /// `recordOutcome` to update the posterior + log the decision.
    pub fn decide(
        self: *Replanner,
        rng: *std.Random.DefaultPrng,
        site: DecisionSiteId,
        variants: []const PlanVariant,
    ) Error!VariantId {
        if (variants.len == 0) return Error.EmptyVariantList;
        var best_id: VariantId = variants[0].id;
        var best_sample: f64 = -1.0;
        for (variants) |v| {
            const post = try self.posteriorFor(site, v.id);
            const s = post.sample(rng);
            if (s > best_sample) {
                best_sample = s;
                best_id = v.id;
            }
        }
        return best_id;
    }

    /// Record the outcome of executing a chosen variant + log the
    /// decision to the workflow event log. Returns after both the
    /// posterior update and the log append succeed.
    ///
    /// `success_bytes` is the 4-byte encoded (site_u32, variant_u16,
    /// succeeded_u8, pad_u8) tuple borrowed by the log; caller owns
    /// the lifetime.
    pub fn recordOutcome(
        self: *Replanner,
        site: DecisionSiteId,
        variant: VariantId,
        succeeded: bool,
        log: *wflog.WorkflowLog,
        workflow_id: wflog.WorkflowId,
        seq: wflog.EventSeq,
        timestamp: wflog.Timestamp,
        success_bytes: []const u8,
    ) Error!void {
        const post = try self.posteriorFor(site, variant);
        if (succeeded) post.recordSuccess() else post.recordFailure();
        const kind: wflog.EventKind = if (succeeded) .activity_completed else .activity_failed;
        log.append(workflow_id, seq, timestamp, kind, success_bytes) catch return Error.LogAppendFailed;
    }

    /// Inspect the posterior mean for a (site, variant) pair. Useful
    /// for telemetry + audit. Returns null if the arm has never been
    /// sampled.
    pub fn meanFor(self: *Replanner, site: DecisionSiteId, variant: VariantId) ?f64 {
        const key: SiteKey = .{ .site = site, .variant = variant };
        const post = self.posteriors.get(key) orelse return null;
        return post.mean();
    }
};

/// Encode a (site, variant, succeeded) tuple to a 16-byte payload
/// for the workflow event log. Caller owns the returned slice.
pub fn encodeDecisionPayload(
    allocator: std.mem.Allocator,
    site: DecisionSiteId,
    variant: VariantId,
    succeeded: bool,
) ![]const u8 {
    var buf = try allocator.alloc(u8, 16);
    std.mem.writeInt(u64, buf[0..8], site, .little);
    std.mem.writeInt(u32, buf[8..12], variant, .little);
    buf[12] = if (succeeded) 1 else 0;
    @memset(buf[13..16], 0);
    return buf;
}

// --- Tests ----------------------------------------------------------------

const testing = std.testing;

test "decide chooses some variant from the supplied list" {
    const alloc = testing.allocator;
    var rp: Replanner = .init(alloc);
    defer rp.deinit();
    var rng = bandit.rngFromSeed(1);
    const variants = [_]PlanVariant{
        .{ .id = 10, .label = "broadcast" },
        .{ .id = 20, .label = "sort-merge" },
        .{ .id = 30, .label = "shuffle-hash" },
    };
    const chosen = try rp.decide(&rng, 1, &variants);
    try testing.expect(chosen == 10 or chosen == 20 or chosen == 30);
}

test "decide rejects empty variant list" {
    const alloc = testing.allocator;
    var rp: Replanner = .init(alloc);
    defer rp.deinit();
    var rng = bandit.rngFromSeed(1);
    try testing.expectError(Error.EmptyVariantList, rp.decide(&rng, 1, &.{}));
}

test "recordOutcome updates posterior + appends a log event" {
    const alloc = testing.allocator;
    var rp: Replanner = .init(alloc);
    defer rp.deinit();
    var log: wflog.WorkflowLog = .init(alloc);
    defer log.deinit();

    // Bootstrap a workflow.
    try log.append(99, 1, 100, .workflow_started, "");

    const payload = try encodeDecisionPayload(alloc, 42, 7, true);
    defer alloc.free(payload);
    try rp.recordOutcome(42, 7, true, &log, 99, 2, 200, payload);

    // Posterior mean now > 0.5 (a single success).
    try testing.expect(rp.meanFor(42, 7).? > 0.5);
    // Log has the activity_completed event at seq 2.
    const e = log.eventAt(99, 2).?;
    try testing.expectEqual(wflog.EventKind.activity_completed, e.kind);
}

test "winning variant attracts more allocation over time" {
    const alloc = testing.allocator;
    var rp: Replanner = .init(alloc);
    defer rp.deinit();
    var log: wflog.WorkflowLog = .init(alloc);
    defer log.deinit();
    try log.append(7, 1, 0, .workflow_started, "");
    var rng = bandit.rngFromSeed(2026);

    // Seed posteriors: variant 1 wins 40/45; variant 2 wins 5/45.
    var i: usize = 0;
    while (i < 40) : (i += 1) {
        const p = try rp.posteriorFor(1, 1);
        p.recordSuccess();
    }
    i = 0;
    while (i < 5) : (i += 1) {
        const p = try rp.posteriorFor(1, 1);
        p.recordFailure();
    }
    i = 0;
    while (i < 5) : (i += 1) {
        const p = try rp.posteriorFor(1, 2);
        p.recordSuccess();
    }
    i = 0;
    while (i < 40) : (i += 1) {
        const p = try rp.posteriorFor(1, 2);
        p.recordFailure();
    }

    const variants = [_]PlanVariant{
        .{ .id = 1, .label = "hot" },
        .{ .id = 2, .label = "cold" },
    };

    // 200 decisions; variant 1 should win >65%.
    var v1: usize = 0;
    var v2: usize = 0;
    var t: usize = 0;
    while (t < 200) : (t += 1) {
        const chosen = try rp.decide(&rng, 1, &variants);
        if (chosen == 1) v1 += 1 else v2 += 1;
    }
    const v1_rate = @as(f64, @floatFromInt(v1)) / 200.0;
    try testing.expect(v1_rate > 0.65);
    // No upper bound: with strong posteriors (40/5 vs 5/40) Thompson
    // sampling can land at 100% on the winner; the bandit
    // exploration discipline lives at the posterior level, not the
    // per-trial picker.
}

test "encodeDecisionPayload round-trips fields" {
    const alloc = testing.allocator;
    const buf = try encodeDecisionPayload(alloc, 0xABCD_1234, 42, true);
    defer alloc.free(buf);
    try testing.expectEqual(@as(usize, 16), buf.len);
    try testing.expectEqual(@as(u64, 0xABCD_1234), std.mem.readInt(u64, buf[0..8], .little));
    try testing.expectEqual(@as(u32, 42), std.mem.readInt(u32, buf[8..12], .little));
    try testing.expectEqual(@as(u8, 1), buf[12]);
}

test "two independent sites maintain disjoint posteriors" {
    const alloc = testing.allocator;
    var rp: Replanner = .init(alloc);
    defer rp.deinit();

    // Site 1 variant 5 → 10 successes.
    var i: usize = 0;
    while (i < 10) : (i += 1) {
        const p = try rp.posteriorFor(1, 5);
        p.recordSuccess();
    }
    // Site 2 variant 5 → 10 failures.
    i = 0;
    while (i < 10) : (i += 1) {
        const p = try rp.posteriorFor(2, 5);
        p.recordFailure();
    }

    const m1 = rp.meanFor(1, 5).?;
    const m2 = rp.meanFor(2, 5).?;
    try testing.expect(m1 > 0.75);
    try testing.expect(m2 < 0.25);
}
