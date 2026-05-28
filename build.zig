const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const bandit_dep = b.dependency("thompson_bandit", .{
        .target = target,
        .optimize = optimize,
    });
    const bandit_mod = bandit_dep.module("thompson_bandit");

    const wflog_dep = b.dependency("workflow_event_log", .{
        .target = target,
        .optimize = optimize,
    });
    const wflog_mod = wflog_dep.module("workflow_event_log");

    const mod = b.addModule("aqe_replanner", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    mod.addImport("thompson_bandit", bandit_mod);
    mod.addImport("workflow_event_log", wflog_mod);

    const root_tests = b.addTest(.{ .root_module = mod });
    const run_root_tests = b.addRunArtifact(root_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_root_tests.step);
}
