//! arrangement — per-(table_id, key_columns) Arrangement cache.
//!
//! Ports Materialize L987 + L263 arrangement-based incremental join
//! semantics into a single-process cache that the replanner consults
//! before materialising a new arrangement.
//!
//! Shape:
//!   Arrangement = (key_columns, materialized: bool, ref_count)
//!   ArrangementCache = (table_id, sorted key_columns) → Arrangement
//!
//! Reuse rule: identical (table, key_columns) → reuse + bump ref_count.
//! Subset rule (v0.0.4): when querying for keys K and the cache holds
//! a strict-superset K' ⊃ K, we can derive K from K' by additional
//! projection. v0.0.3 ships exact-match reuse only.
//!
//! "Arrangement" is a name borrowed from differential-dataflow; the
//! substrate is content-agnostic — keys are u32 column ids; values
//! are an opaque payload byte slice that the caller owns.

const std = @import("std");

pub const TableId = u64;
pub const ColumnId = u32;

pub const ArrangementKey = struct {
    table: TableId,
    /// Sorted-ascending list of column ids. The cache normalises keys
    /// before hashing so callers don't have to.
    key_columns: []const ColumnId,

    pub fn hash(self: ArrangementKey) u64 {
        var h: u64 = self.table ^ 0x9E3779B97F4A7C15;
        for (self.key_columns) |c| {
            h = (h ^ @as(u64, c)) *% 0xBF58476D1CE4E5B9;
            h ^= h >> 27;
        }
        return h ^ (h >> 31);
    }
};

pub const Arrangement = struct {
    table: TableId,
    key_columns: []ColumnId, // owned
    ref_count: u32,
    materialized: bool,
};

pub const Error = error{
    EmptyKeyColumns,
    OutOfMemory,
};

const KeyCtx = struct {
    pub fn hash(_: KeyCtx, k: ArrangementKey) u64 {
        return k.hash();
    }
    pub fn eql(_: KeyCtx, a: ArrangementKey, b: ArrangementKey) bool {
        if (a.table != b.table) return false;
        if (a.key_columns.len != b.key_columns.len) return false;
        for (a.key_columns, b.key_columns) |x, y| if (x != y) return false;
        return true;
    }
};

pub const ArrangementCache = struct {
    allocator: std.mem.Allocator,
    map: std.HashMap(ArrangementKey, *Arrangement, KeyCtx, std.hash_map.default_max_load_percentage),
    hit_count: u64,
    miss_count: u64,

    pub fn init(allocator: std.mem.Allocator) ArrangementCache {
        return .{
            .allocator = allocator,
            .map = .init(allocator),
            .hit_count = 0,
            .miss_count = 0,
        };
    }

    pub fn deinit(self: *ArrangementCache) void {
        var it = self.map.iterator();
        while (it.next()) |kv| {
            self.allocator.free(kv.value_ptr.*.key_columns);
            self.allocator.destroy(kv.value_ptr.*);
        }
        self.map.deinit();
    }

    /// Get-or-create an arrangement for (table, key_columns). The
    /// caller hands an unsorted key column list; we normalise.
    /// Returns a pointer into the cache; do NOT mutate `key_columns`
    /// through it.
    pub fn getOrCreate(
        self: *ArrangementCache,
        table: TableId,
        key_columns: []const ColumnId,
    ) Error!*Arrangement {
        if (key_columns.len == 0) return Error.EmptyKeyColumns;
        const sorted = try self.allocator.dupe(ColumnId, key_columns);
        std.mem.sort(ColumnId, sorted, {}, std.sort.asc(ColumnId));

        const probe: ArrangementKey = .{ .table = table, .key_columns = sorted };
        if (self.map.get(probe)) |arr| {
            self.allocator.free(sorted); // not needed; reuse existing
            arr.ref_count += 1;
            self.hit_count += 1;
            return arr;
        }

        const arr = self.allocator.create(Arrangement) catch {
            self.allocator.free(sorted);
            return Error.OutOfMemory;
        };
        arr.* = .{ .table = table, .key_columns = sorted, .ref_count = 1, .materialized = true };
        const key: ArrangementKey = .{ .table = table, .key_columns = arr.key_columns };
        self.map.put(key, arr) catch {
            self.allocator.free(sorted);
            self.allocator.destroy(arr);
            return Error.OutOfMemory;
        };
        self.miss_count += 1;
        return arr;
    }

    pub fn release(self: *ArrangementCache, arr: *Arrangement) void {
        _ = self;
        if (arr.ref_count > 0) arr.ref_count -= 1;
    }

    pub fn count(self: ArrangementCache) usize {
        return self.map.count();
    }

    pub fn hitRate(self: ArrangementCache) f64 {
        const total = self.hit_count + self.miss_count;
        if (total == 0) return 0;
        return @as(f64, @floatFromInt(self.hit_count)) / @as(f64, @floatFromInt(total));
    }
};

// --- Tests ----------------------------------------------------------------

const testing = std.testing;

test "first getOrCreate is a miss; second on same key is a hit" {
    var cache: ArrangementCache = .init(testing.allocator);
    defer cache.deinit();
    const k = [_]ColumnId{ 3, 7 };
    const arr1 = try cache.getOrCreate(42, &k);
    try testing.expectEqual(@as(u32, 1), arr1.ref_count);
    try testing.expectEqual(@as(u64, 1), cache.miss_count);

    const arr2 = try cache.getOrCreate(42, &k);
    try testing.expect(arr1 == arr2);
    try testing.expectEqual(@as(u32, 2), arr2.ref_count);
    try testing.expectEqual(@as(u64, 1), cache.hit_count);
}

test "different column ORDER on the same table hits the same arrangement" {
    var cache: ArrangementCache = .init(testing.allocator);
    defer cache.deinit();
    const k1 = [_]ColumnId{ 3, 7, 9 };
    const k2 = [_]ColumnId{ 9, 3, 7 };
    const arr1 = try cache.getOrCreate(42, &k1);
    const arr2 = try cache.getOrCreate(42, &k2);
    try testing.expect(arr1 == arr2);
    try testing.expectEqual(@as(u64, 1), cache.hit_count);
}

test "different tables — distinct arrangements" {
    var cache: ArrangementCache = .init(testing.allocator);
    defer cache.deinit();
    const k = [_]ColumnId{ 1, 2 };
    const a = try cache.getOrCreate(1, &k);
    const b = try cache.getOrCreate(2, &k);
    try testing.expect(a != b);
    try testing.expectEqual(@as(usize, 2), cache.count());
}

test "getOrCreate rejects empty key list" {
    var cache: ArrangementCache = .init(testing.allocator);
    defer cache.deinit();
    try testing.expectError(Error.EmptyKeyColumns, cache.getOrCreate(1, &.{}));
}

test "release decrements ref_count" {
    var cache: ArrangementCache = .init(testing.allocator);
    defer cache.deinit();
    const k = [_]ColumnId{1};
    const arr = try cache.getOrCreate(1, &k);
    _ = try cache.getOrCreate(1, &k);
    try testing.expectEqual(@as(u32, 2), arr.ref_count);
    cache.release(arr);
    try testing.expectEqual(@as(u32, 1), arr.ref_count);
}

test "hitRate reflects access pattern" {
    var cache: ArrangementCache = .init(testing.allocator);
    defer cache.deinit();
    const k = [_]ColumnId{1};
    _ = try cache.getOrCreate(1, &k); // miss
    _ = try cache.getOrCreate(1, &k); // hit
    _ = try cache.getOrCreate(1, &k); // hit
    _ = try cache.getOrCreate(2, &k); // miss
    // 2 hits / 4 total = 0.5
    try testing.expectApproxEqAbs(@as(f64, 0.5), cache.hitRate(), 1e-9);
}
