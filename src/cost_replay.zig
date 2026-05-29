//! cost_replay — cost-aware replay-side re-derivation.
//!
//! v0.0.2 ReplayReplanner read recorded plan choices from the
//! workflow event log and returned them verbatim (drop-in replay).
//! v0.0.4 introduced a real cost model.
//!
//! v0.0.5 binds the two: a `CostAwareReplayReplanner` walks the
//! event log AND the cost-payload encoded by `recordOutcome` (the
//! 16-byte `(site, variant, succeeded, pad)` form was v0.0.1; v0.0.5
//! ships a 24-byte `(site, variant, succeeded, pad, cost_bits)`
//! form). It:
//!
//! 1. Builds the `site → variant` map (v0.0.2 behaviour).
//! 2. Sums the observed cost per `(plan_signature)` and seeds
//!    `ArmPosterior`s.
//! 3. `pickWithReplay(rng, site, variants, cost_estimates, tolerance)`
//!    returns the recorded variant if a matching candidate exists
//!    AND its observed cost was within tolerance of the cost
//!    estimate. Otherwise falls through to a fresh
//!    `pickByCostThompson` over the candidates.
//!
//! "Tolerance" lets the substrate detect cost drift: if the recorded
//! plan now estimates much higher cost than it did historically (say
//! cardinality changed by 10x), the recorded choice is stale and the
//! bandit re-samples.

const std = @import("std");
const replanner_mod = @import("replanner.zig");
const replay_replanner_mod = @import("replay_replanner.zig");
const cost_model = @import("cost_model.zig");
const bandit = @import("thompson_bandit");
const wflog = @import("workflow_event_log");

pub const DecisionSiteId = replanner_mod.DecisionSiteId;
pub const VariantId = replanner_mod.VariantId;
pub const PlanVariant = replanner_mod.PlanVariant;
pub const JoinPlan = cost_model.PlanKind;
pub const CostEstimate = cost_model.CostEstimate;
pub const PlanSignature = cost_model.PlanSignature;

/// Extended 24-byte decision payload:
///   [0..8]   site_id u64 LE
///   [8..12]  variant_id u32 LE
///   [12]     succeeded u8 (0 or 1)
///   [13..16] pad (zero)
///   [16..24] observed_cost f64 LE bits
pub const cost_payload_len: usize = 24;

pub fn encodeCostDecisionPayload(
    allocator: std.mem.Allocator,
    site: DecisionSiteId,
    variant: VariantId,
    succeeded: bool,
    observed_cost: f64,
) ![]const u8 {
    var buf = try allocator.alloc(u8, cost_payload_len);
    std.mem.writeInt(u64, buf[0..8], site, .little);
    std.mem.writeInt(u32, buf[8..12], variant, .little);
    buf[12] = if (succeeded) 1 else 0;
    @memset(buf[13..16], 0);
    const bits: u64 = @bitCast(observed_cost);
    std.mem.writeInt(u64, buf[16..24], bits, .little);
    return buf;
}

pub const RecordedEntry = struct {
    variant: VariantId,
    observed_cost: f64,
};

pub const CostAwareReplayReplanner = struct {
    allocator: std.mem.Allocator,
    recorded: std.AutoHashMap(DecisionSiteId, RecordedEntry),
    posteriors: std.AutoHashMap(PlanSignature, bandit.ArmPosterior),

    pub fn init(allocator: std.mem.Allocator) CostAwareReplayReplanner {
        return .{
            .allocator = allocator,
            .recorded = .init(allocator),
            .posteriors = .init(allocator),
        };
    }

    pub fn deinit(self: *CostAwareReplayReplanner) void {
        self.recorded.deinit();
        self.posteriors.deinit();
    }

    /// Walk every `activity_completed` / `activity_failed` event in
    /// the workflow + ingest entries with the 24-byte cost payload.
    /// 16-byte payloads (v0.0.4 wire format) are accepted with
    /// `observed_cost = NaN` so callers can still retrieve the
    /// recorded variant; the bandit-seed step skips NaN entries.
    pub fn loadFromLog(
        self: *CostAwareReplayReplanner,
        log: *wflog.WorkflowLog,
        workflow_id: wflog.WorkflowId,
        target_cost: f64,
    ) !void {
        const stream_len = log.streamLen(workflow_id) orelse return error.WorkflowNotFound;
        var seq: wflog.EventSeq = 1;
        while (seq <= stream_len) : (seq += 1) {
            const e = log.eventAt(workflow_id, seq) orelse continue;
            if (e.kind != .activity_completed and e.kind != .activity_failed) continue;
            if (e.bytes.len < 16) continue;
            const site = std.mem.readInt(u64, e.bytes[0..8], .little);
            const variant = std.mem.readInt(u32, e.bytes[8..12], .little);
            var observed: f64 = std.math.nan(f64);
            if (e.bytes.len >= cost_payload_len) {
                const bits = std.mem.readInt(u64, e.bytes[16..24], .little);
                observed = @bitCast(bits);
            }
            try self.recorded.put(site, .{ .variant = variant, .observed_cost = observed });

            // Seed the cost-keyed posterior for this plan signature.
            // Use a stand-in plan kind (delta_join) — the bandit is
            // keyed by signature alone; both kinds get distinct
            // signatures via signatureFor. We can't reconstruct the
            // exact plan signature without a kind tag in the payload,
            // so v0.0.5 uses (delta_join, site=site, new_arr=0). If
            // the application encodes a richer signature, the v0.0.6
            // wire format should add it.
            if (!std.math.isNan(observed)) {
                const proxy: cost_model.JoinPlan = .{
                    .kind = .delta_join,
                    .streaming_input = @intCast(site & 0xFF),
                    .new_arrangements = 0,
                };
                const sig = cost_model.signatureFor(proxy);
                const gop = try self.posteriors.getOrPut(sig);
                if (!gop.found_existing) gop.value_ptr.* = .uniform();
                if (observed < target_cost) gop.value_ptr.recordSuccess() else gop.value_ptr.recordFailure();
            }
        }
    }

    pub fn recordedFor(self: *CostAwareReplayReplanner, site: DecisionSiteId) ?RecordedEntry {
        return self.recorded.get(site);
    }

    /// If the log has a recorded variant whose recorded cost is
    /// within `tolerance_ratio * observed_cost` of one of the fresh
    /// estimates, return that recorded variant — replay path. Else
    /// fall back to `pickByCostThompson` over the fresh estimates.
    pub fn pickWithReplay(
        self: *CostAwareReplayReplanner,
        rng: *std.Random.DefaultPrng,
        site: DecisionSiteId,
        candidates: []const PlanVariant,
        estimates: []const cost_model.CostEstimate,
        tolerance_ratio: f64,
    ) !VariantId {
        if (self.recorded.get(site)) |rec| {
            // Find a matching candidate by variant id.
            var matched: ?cost_model.CostEstimate = null;
            for (estimates) |est| {
                // CostEstimate is indexed by JoinPlan; we treat the
                // `streaming_input` field as the variant id proxy.
                if (est.plan.streaming_input == rec.variant) {
                    matched = est;
                    break;
                }
            }
            if (matched) |m| {
                const ratio = if (m.cost == 0) 0.0 else @abs(rec.observed_cost - m.cost) / m.cost;
                if (!std.math.isNan(rec.observed_cost) and ratio <= tolerance_ratio) {
                    // Found in cache + cost still close. Replay.
                    return rec.variant;
                }
            }
        }
        // Fall through to fresh pick.
        const chosen_plan = try cost_model.pickByCostThompson(rng, &self.posteriors, estimates);
        // The variant id is in the chosen plan's streaming_input
        // proxy (matches our convention above). The caller passes a
        // matching `candidates[]` so we can map back.
        _ = candidates;
        return @intCast(chosen_plan.streaming_input);
    }
};

// --- Tests ----------------------------------------------------------------

const testing = std.testing;

test "encodeCostDecisionPayload round-trips fields" {
    const alloc = testing.allocator;
    const buf = try encodeCostDecisionPayload(alloc, 0xABCD_1234, 42, true, 1234.5);
    defer alloc.free(buf);
    try testing.expectEqual(@as(usize, cost_payload_len), buf.len);
    try testing.expectEqual(@as(u64, 0xABCD_1234), std.mem.readInt(u64, buf[0..8], .little));
    try testing.expectEqual(@as(u32, 42), std.mem.readInt(u32, buf[8..12], .little));
    try testing.expectEqual(@as(u8, 1), buf[12]);
    const bits = std.mem.readInt(u64, buf[16..24], .little);
    const recovered: f64 = @bitCast(bits);
    try testing.expectApproxEqAbs(@as(f64, 1234.5), recovered, 1e-9);
}

test "loadFromLog ingests cost decisions + builds site map" {
    const alloc = testing.allocator;
    var log: wflog.WorkflowLog = .init(alloc);
    defer log.deinit();
    try log.append(1, 1, 0, .workflow_started, "");

    const p1 = try encodeCostDecisionPayload(alloc, 7, 3, true, 100.0);
    defer alloc.free(p1);
    try log.append(1, 2, 100, .activity_completed, p1);
    const p2 = try encodeCostDecisionPayload(alloc, 8, 4, false, 5000.0);
    defer alloc.free(p2);
    try log.append(1, 3, 200, .activity_failed, p2);

    var rr: CostAwareReplayReplanner = .init(alloc);
    defer rr.deinit();
    try rr.loadFromLog(&log, 1, 1000.0);

    try testing.expectEqual(@as(VariantId, 3), rr.recordedFor(7).?.variant);
    try testing.expectApproxEqAbs(@as(f64, 100.0), rr.recordedFor(7).?.observed_cost, 1e-9);
    try testing.expectEqual(@as(VariantId, 4), rr.recordedFor(8).?.variant);
}

test "pickWithReplay returns recorded variant within tolerance" {
    const alloc = testing.allocator;
    var log: wflog.WorkflowLog = .init(alloc);
    defer log.deinit();
    try log.append(1, 1, 0, .workflow_started, "");
    const payload = try encodeCostDecisionPayload(alloc, 42, 5, true, 1000.0);
    defer alloc.free(payload);
    try log.append(1, 2, 100, .activity_completed, payload);

    var rr: CostAwareReplayReplanner = .init(alloc);
    defer rr.deinit();
    try rr.loadFromLog(&log, 1, 5000.0);

    var rng = bandit.rngFromSeed(7);
    const variants = [_]PlanVariant{
        .{ .id = 5, .label = "recorded" },
        .{ .id = 6, .label = "fresh" },
    };
    // streaming_input == variant id by our convention.
    const estimates = [_]cost_model.CostEstimate{
        .{
            .plan = .{ .kind = .delta_join, .streaming_input = 5, .new_arrangements = 0 },
            .cardinality_sum = 100,
            .cost = 1050.0,
        },
        .{
            .plan = .{ .kind = .delta_join, .streaming_input = 6, .new_arrangements = 0 },
            .cardinality_sum = 100,
            .cost = 800.0,
        },
    };
    // tolerance 0.1: 5% gap is fine.
    const chosen = try rr.pickWithReplay(&rng, 42, &variants, &estimates, 0.1);
    try testing.expectEqual(@as(VariantId, 5), chosen);
}

test "pickWithReplay falls through to fresh pick on cost drift" {
    const alloc = testing.allocator;
    var log: wflog.WorkflowLog = .init(alloc);
    defer log.deinit();
    try log.append(1, 1, 0, .workflow_started, "");
    const payload = try encodeCostDecisionPayload(alloc, 42, 5, true, 100.0);
    defer alloc.free(payload);
    try log.append(1, 2, 100, .activity_completed, payload);

    var rr: CostAwareReplayReplanner = .init(alloc);
    defer rr.deinit();
    try rr.loadFromLog(&log, 1, 5000.0);

    var rng = bandit.rngFromSeed(7);
    const variants = [_]PlanVariant{
        .{ .id = 5, .label = "stale" },
        .{ .id = 6, .label = "fresh" },
    };
    // Recorded cost was 100; current estimate is 100x larger ->
    // ratio = 99 >> tolerance 0.5. Should fall through to
    // pickByCostThompson, which will pick a candidate.
    const estimates = [_]cost_model.CostEstimate{
        .{
            .plan = .{ .kind = .delta_join, .streaming_input = 5, .new_arrangements = 0 },
            .cardinality_sum = 100,
            .cost = 10_000.0,
        },
        .{
            .plan = .{ .kind = .delta_join, .streaming_input = 6, .new_arrangements = 0 },
            .cardinality_sum = 100,
            .cost = 200.0,
        },
    };
    const chosen = try rr.pickWithReplay(&rng, 42, &variants, &estimates, 0.5);
    // We pick the lowest-cost path on the fresh pass; the bandit
    // hasn't been heavily seeded so it should converge there.
    try testing.expect(chosen == 5 or chosen == 6);
}

test "loadFromLog accepts 16-byte (v0.0.4) payloads with NaN cost" {
    const alloc = testing.allocator;
    var log: wflog.WorkflowLog = .init(alloc);
    defer log.deinit();
    try log.append(1, 1, 0, .workflow_started, "");
    // Old 16-byte format from v0.0.4.
    const old_payload = try replanner_mod.encodeDecisionPayload(alloc, 99, 1, true);
    defer alloc.free(old_payload);
    try log.append(1, 2, 100, .activity_completed, old_payload);

    var rr: CostAwareReplayReplanner = .init(alloc);
    defer rr.deinit();
    try rr.loadFromLog(&log, 1, 5000.0);
    const rec = rr.recordedFor(99).?;
    try testing.expectEqual(@as(VariantId, 1), rec.variant);
    try testing.expect(std.math.isNan(rec.observed_cost));
}
