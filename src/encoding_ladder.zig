//! encoding_ladder — v0.0.22 port of P1153 (Velox encoding ladder).
//!
//! Ports P1153 (Velox encoding ladder from L69-query-engine-internals).
//! Velox picks a column encoding at materialization time from a ladder
//! ordered by typical compression ratio:
//!
//!   1. raw          — no compression
//!   2. bitpacked    — n-bit fixed-width for [0, max-min] range
//!   3. dictionary   — when distinct values << total values
//!   4. RLE          — when sorted/runs dominate
//!
//! v0.0.22 ships the policy primitive: score each encoding against a
//! column's stats + pick the smallest. v0.0.18 + v0.0.20 already ship
//! the actual encoders (DictColumnI64, RleColumnI64); the ladder
//! decides which to use.

const std = @import("std");
const dict_column = @import("dict_column.zig");
const rle_column = @import("rle_column.zig");

pub const Encoding = enum {
    raw,
    bitpacked,
    dictionary,
    rle,
};

pub const ColumnStats = struct {
    row_count: u64,
    distinct_count: u64,
    /// Number of distinct runs (1 = constant column).
    run_count: u64,
    min_value: i64,
    max_value: i64,
};

/// Estimate the byte size of a column under each encoding given its
/// stats. Returns the encoding with the smallest estimate.
pub fn pickEncoding(stats: ColumnStats) Encoding {
    const raw_bytes = stats.row_count * 8; // i64

    // Bitpacked: ceil(log2(range + 1)) bits per row.
    const range: u64 = blk: {
        const diff = @subWithOverflow(stats.max_value, stats.min_value);
        if (diff[1] != 0) break :blk std.math.maxInt(u64);
        break :blk @intCast(diff[0]);
    };
    const bits_needed: u64 = if (range == 0) 1 else @as(u64, 64 - @clz(range));
    const bitpacked_bytes = ((stats.row_count * bits_needed) + 7) / 8;

    // Dictionary: 8 bytes per distinct + 1 byte per row (u8 index;
    // assume distinct ≤ 256 which the substrate enforces).
    const dict_bytes = (stats.distinct_count * 8) + stats.row_count;

    // RLE: (8 + 4) bytes per run.
    const rle_bytes = stats.run_count * 12;

    var best: Encoding = .raw;
    var best_bytes: u64 = raw_bytes;
    if (bitpacked_bytes < best_bytes) {
        best_bytes = bitpacked_bytes;
        best = .bitpacked;
    }
    // Only consider dictionary if distinct fits in u8.
    if (stats.distinct_count <= 256 and dict_bytes < best_bytes) {
        best_bytes = dict_bytes;
        best = .dictionary;
    }
    if (rle_bytes < best_bytes) {
        best_bytes = rle_bytes;
        best = .rle;
    }
    return best;
}

/// Estimated bytes for a given encoding choice.
pub fn estimateBytes(stats: ColumnStats, enc: Encoding) u64 {
    return switch (enc) {
        .raw => stats.row_count * 8,
        .bitpacked => blk: {
            const range: u64 = @intCast(stats.max_value - stats.min_value);
            const bits_needed: u64 = if (range == 0) 1 else @as(u64, 64 - @clz(range));
            break :blk ((stats.row_count * bits_needed) + 7) / 8;
        },
        .dictionary => (stats.distinct_count * 8) + stats.row_count,
        .rle => stats.run_count * 12,
    };
}

// --- Tests ----------------------------------------------------------------

const testing = std.testing;

test "pickEncoding selects RLE for constant column" {
    const stats: ColumnStats = .{
        .row_count = 1000,
        .distinct_count = 1,
        .run_count = 1,
        .min_value = 7,
        .max_value = 7,
    };
    try testing.expectEqual(Encoding.rle, pickEncoding(stats));
}

test "pickEncoding selects dictionary when distinct count is low" {
    const stats: ColumnStats = .{
        .row_count = 1000,
        .distinct_count = 5,
        .run_count = 800, // not runlike
        .min_value = 0,
        .max_value = 1_000_000, // bitpacked is 1000 * 20 / 8 = 2500 bytes
    };
    // raw = 8000, bitpacked = 2500, dict = 40 + 1000 = 1040, rle = 9600.
    // Dict wins.
    try testing.expectEqual(Encoding.dictionary, pickEncoding(stats));
}

test "pickEncoding selects bitpacked for narrow range + high distinct" {
    const stats: ColumnStats = .{
        .row_count = 1000,
        .distinct_count = 500, // exceeds u8 cap → dictionary disqualified
        .run_count = 800,
        .min_value = 0,
        .max_value = 7,
    };
    // raw = 8000, bitpacked = 1000 * 3 / 8 = 375, dict disqualified, rle = 9600.
    try testing.expectEqual(Encoding.bitpacked, pickEncoding(stats));
}

test "pickEncoding selects raw when nothing wins" {
    const stats: ColumnStats = .{
        .row_count = 100,
        .distinct_count = 100,
        .run_count = 100,
        .min_value = std.math.minInt(i64),
        .max_value = std.math.maxInt(i64),
    };
    // All-distinct, no runs, full range → raw is the smallest.
    try testing.expectEqual(Encoding.raw, pickEncoding(stats));
}

test "estimateBytes matches the formula for each encoding" {
    const stats: ColumnStats = .{
        .row_count = 100,
        .distinct_count = 10,
        .run_count = 5,
        .min_value = 0,
        .max_value = 15,
    };
    try testing.expectEqual(@as(u64, 800), estimateBytes(stats, .raw));
    // range=15 → 4 bits → 100*4/8 = 50
    try testing.expectEqual(@as(u64, 50), estimateBytes(stats, .bitpacked));
    // dict = 10*8 + 100 = 180
    try testing.expectEqual(@as(u64, 180), estimateBytes(stats, .dictionary));
    // rle = 5*12 = 60
    try testing.expectEqual(@as(u64, 60), estimateBytes(stats, .rle));
}

test "estimateBytes range=0 → 1-bit bitpacked floor" {
    const stats: ColumnStats = .{
        .row_count = 64,
        .distinct_count = 1,
        .run_count = 1,
        .min_value = 5,
        .max_value = 5,
    };
    // 1 bit per row, 64 rows → 8 bytes.
    try testing.expectEqual(@as(u64, 8), estimateBytes(stats, .bitpacked));
}
