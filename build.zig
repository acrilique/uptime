const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const clap = b.dependency("clap", .{});
    const zdt = b.dependency("zdt", .{});

    const logfile = b.createModule(.{
        .root_source_file = b.path("src/logfile.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zdt", .module = zdt.module("zdt") },
        },
        .link_libc = true,
    });

    const parser_mod = b.createModule(.{
        .root_source_file = b.path("src/parser.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zdt", .module = zdt.module("zdt") },
            .{ .name = "clap", .module = clap.module("clap") },
            .{ .name = "logfile", .module = logfile },
        },
        .link_libc = true,
    });

    const parser = b.addExecutable(.{
        .name = "uptime-parser",
        .root_module = parser_mod,
    });

    const monitor = b.addExecutable(.{
        .name = "uptime-monitor",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/monitor.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zdt", .module = zdt.module("zdt") },
                .{ .name = "clap", .module = clap.module("clap") },
                .{ .name = "logfile", .module = logfile },
            },
            .link_libc = true,
        }),
    });

    b.installArtifact(parser);
    b.installArtifact(monitor);

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

    const logfile_tests = b.addTest(.{
        .root_module = logfile,
    });

    const run_logfile_tests = b.addRunArtifact(logfile_tests);
    const logfile_test_step = b.step("test-logfile", "Run logfile tests");
    logfile_test_step.dependOn(&run_logfile_tests.step);

    const parser_tests = b.addTest(.{
        .root_module = parser_mod,
    });

    const run_parser_tests = b.addRunArtifact(parser_tests);
    const parser_test_step = b.step("test-parser", "Run parser tests");
    parser_test_step.dependOn(&run_parser_tests.step);

    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(logfile_test_step);
    test_step.dependOn(parser_test_step);
}
