pub const packages = struct {
    pub const @"../thompson-bandit-zig" = struct {
        pub const build_root = "/home/stax/aqe-replanner-zig/../thompson-bandit-zig";
        pub const build_zig = @import("../thompson-bandit-zig");
        pub const deps: []const struct { []const u8, []const u8 } = &.{
        };
    };
    pub const @"../workflow-event-log-zig" = struct {
        pub const build_root = "/home/stax/aqe-replanner-zig/../workflow-event-log-zig";
        pub const build_zig = @import("../workflow-event-log-zig");
        pub const deps: []const struct { []const u8, []const u8 } = &.{
        };
    };
};

pub const root_deps: []const struct { []const u8, []const u8 } = &.{
    .{ "thompson_bandit", "../thompson-bandit-zig" },
    .{ "workflow_event_log", "../workflow-event-log-zig" },
};
