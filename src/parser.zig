// SPDX-FileCopyrightText: 2026 Lluc Simó Margalef
//
// SPDX-License-Identifier: MIT

const std = @import("std");
const clap = @import("clap");
const uptime = @import("uptime");
const zdt = @import("zdt");

pub fn main(init: std.process.Init) !void {
    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    const desc =
        \\This program takes a file containing an uptime log (e.g.:
        \\        2026-07-24T23:58:34Z HEARTBEAT UP
        \\        2026-07-25T00:15:31Z DOWN
        \\        2026-07-25T00:16:06Z UP
        \\        2026-07-25T00:17:51Z DOWN
        \\        2026-07-25T00:20:44Z UP
        \\) and calculates the uptime percent in a specific window.
        \\
        \\`--start` and `--end` can be used to specify the window. Alternatively, the
        \\`--duration` shortcut can be used in two ways: either pass it alone (and the
        \\window will be e.g. the last two days) or pass it alongside `--start` or
        \\`--end` (not both).
        \\
        \\If none of these options are passed, the window will be as big as the timespan
        \\represented in the logfile.
        \\
        \\
    ;

    const params = comptime clap.parseParamsComptime(
        \\-h, --help             Display this help and exit.
        \\-s, --start <str>      Window start (ISO8601).
        \\-e, --end <str>        Window end (ISO8601).
        \\-t, --threshold <f32>  Missing-segment theshold in minutes (default 35).
        \\-d, --duration <str>   Window duration (ISO8601).
        \\<str>                  Path to the uptime log file.
    );

    var diag = clap.Diagnostic{};
    var res = clap.parse(
        clap.Help,
        &params,
        clap.parsers.default,
        init.minimal.args,
        .{
            .diagnostic = &diag,
            .allocator = init.gpa,
        },
    ) catch |err| {
        try diag.reportToFile(init.io, .stderr(), err);
        return err;
    };
    defer res.deinit();

    if (res.args.help != 0) {
        try stdout.print(desc, .{});
        try stdout.flush();
        return clap.helpToFile(
            init.io,
            .stdout(),
            clap.Help,
            &params,
            .{},
        );
    }

    const log_path = if (res.positionals[0]) |l| l else {
        std.log.err("Missing log file path argument.\nUsage:", .{});
        var stderr_buffer: [1024]u8 = undefined;
        var stderr_writer = std.Io.File.stderr().writer(init.io, &stderr_buffer);
        const stderr = &stderr_writer.interface;
        try clap.usage(stderr, clap.Help, &params);
        try stderr.writeAll("\n");
        try stderr.flush();
        return error.MissingLogFile;
    };

    const start = if (res.args.start) |s|
        uptime.parseBound(s) catch {
            std.log.err("Error parsing `--start` argument. ISO8601 format is expected.", .{});
            return error.ParseError;
        }
    else
        null;

    const end = if (res.args.end) |e|
        uptime.parseBound(e) catch {
            std.log.err("Error parsing `--end` argument. ISO8601 format is expected.", .{});
            return error.ParseError;
        }
    else
        null;

    const threshold = if (res.args.threshold) |t| t else 35.0;

    // consumed as whole seconds, which must fit the i64 that
    // Duration.fromTimespanMultiple takes
    const threshold_sec = @round(threshold * 60);

    if (!std.math.isFinite(threshold) or threshold <= 0 or
        threshold_sec >= @as(f32, @floatFromInt(std.math.maxInt(i64))))
    {
        std.log.err("Invalid threshold value: {d}", .{threshold});
        return error.InvalidArgumentValue;
    }

    const duration = if (res.args.duration) |d|
        zdt.Duration.fromISO8601(d) catch {
            std.log.err("Error parsing `--duration` argument. ISO8601 format is expected.", .{});
            return error.ParseError;
        }
    else
        null;

    var events = uptime.parseFile(
        init.io,
        init.gpa,
        log_path,
    ) catch |e| {
        std.log.err("Error parsing log file: {s}", .{@errorName(e)});
        return e;
    };
    defer events.deinit(init.gpa);

    const result = uptime.analyze(
        events,
        start,
        end,
        try zdt.Duration.fromTimespanMultiple(
            @intFromFloat(threshold_sec),
            .second,
        ),
        duration,
    ) catch |e| {
        if (e == error.CompareNaiveAware)
            reportMixedAwareness(log_path, events.items, start, end)
        else
            std.log.err("Error during analysis: {s}", .{@errorName(e)});
        return e;
    };

    try stdout.print(
        \\Period:     {f} → {f}  ({f})
        \\Uptime:     {d:.2}%
        \\Confidence: {d:.2}%  ({f} observed / {f} period)
        \\Downtime:   {f}  across {d} outage{s}
        \\Lost time:  {f}  (no heartbeat within {d} min)
        \\
    ,
        .{
            result.window_start,
            result.window_end,
            result.window_length,
            result.uptime_pct(),
            result.confidence_pct(),
            result.observed_time,
            result.window_length,
            result.down_time,
            result.outage_count,
            if (result.outage_count == 1) "" else "s",
            result.lost_time,
            threshold,
        },
    );
    try stdout.flush();
}

/// Name the window bound(s) whose awareness differs from the log's.
fn reportMixedAwareness(
    log_path: []const u8,
    events: []const uptime.Event,
    start: ?zdt.Datetime,
    end: ?zdt.Datetime,
) void {
    const log_aware = events[0].ts.isAware();
    const other = if (log_aware) "naive" else "aware";
    std.log.err(
        "Error during analysis: CompareNaiveAware: the log '{s}' has {s} timestamps, but",
        .{ log_path, if (log_aware) "aware" else "naive" },
    );
    if (start) |s| if (s.isAware() != log_aware)
        std.log.err("  --start {f} is {s}", .{ s, other });
    if (end) |e| if (e.isAware() != log_aware)
        std.log.err("  --end {f} is {s}", .{ e, other });
    std.log.err(
        "Hint: {s}",
        .{if (log_aware) "give --start/--end a UTC offset (Z, +02:00)" else "drop the UTC offset from --start/--end"},
    );
}
