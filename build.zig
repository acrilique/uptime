const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zdt = b.dependency("zdt", .{});

    const uptime = b.addModule("uptime", .{
        .root_source_file = b.path("src/uptime.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zdt", .module = zdt.module("zdt") },
        },
        .link_libc = true,
    });

    if (b.dep_prefix.len != 0) return;

    // lazy deps return null until the parent has fetched them and re-run
    // this script, so the first configure pass ends early here
    const clap = b.lazyDependency("clap", .{}) orelse return;
    const datastar = b.lazyDependency("datastar", .{}) orelse return;

    const parser = b.addExecutable(.{
        .name = "uptime-parser",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/parser.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zdt", .module = zdt.module("zdt") },
                .{ .name = "clap", .module = clap.module("clap") },
                .{ .name = "uptime", .module = uptime },
            },
            .link_libc = true,
        }),
    });

    const monitor_module = b.createModule(.{
        .root_source_file = b.path("src/monitor.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zdt", .module = zdt.module("zdt") },
            .{ .name = "clap", .module = clap.module("clap") },
            .{ .name = "uptime", .module = uptime },
        },
        .link_libc = true,
    });

    const monitor = b.addExecutable(.{
        .name = "uptime-monitor",
        .root_module = monitor_module,
    });

    const dashboard_module = b.createModule(.{
        .root_source_file = b.path("src/dashboard/dashboard.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zdt", .module = zdt.module("zdt") },
            .{ .name = "clap", .module = clap.module("clap") },
            .{ .name = "uptime", .module = uptime },
            .{ .name = "datastar", .module = datastar.module("datastar") },
        },
        .link_libc = true,
    });

    const dashboard = b.addExecutable(.{
        .name = "uptime-dashboard",
        .root_module = dashboard_module,
    });

    b.installArtifact(parser);
    b.installArtifact(monitor);
    b.installArtifact(dashboard);

    const parser_run_step = b.step("run-parser", "Run the parser");

    const parser_run_cmd = b.addRunArtifact(parser);
    parser_run_step.dependOn(&parser_run_cmd.step);

    parser_run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        parser_run_cmd.addArgs(args);
    }

    const monitor_run_step = b.step("run-monitor", "Run the monitor");

    const monitor_run_cmd = b.addRunArtifact(monitor);
    monitor_run_step.dependOn(&monitor_run_cmd.step);

    monitor_run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        monitor_run_cmd.addArgs(args);
    }

    const dashboard_run_step = b.step("run-dashboard", "Run the dashboard");

    const dashboard_run_cmd = b.addRunArtifact(dashboard);
    dashboard_run_step.dependOn(&dashboard_run_cmd.step);

    dashboard_run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        dashboard_run_cmd.addArgs(args);
    }

    const uptime_tests = b.addTest(.{
        .root_module = uptime,
    });

    const run_uptime_tests = b.addRunArtifact(uptime_tests);

    const monitor_tests = b.addTest(.{
        .root_module = monitor_module,
    });

    const run_monitor_tests = b.addRunArtifact(monitor_tests);

    const dashboard_tests = b.addTest(.{
        .root_module = dashboard_module,
    });

    const run_dashboard_tests = b.addRunArtifact(dashboard_tests);

    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&run_uptime_tests.step);
    test_step.dependOn(&run_monitor_tests.step);
    test_step.dependOn(&run_dashboard_tests.step);
}
