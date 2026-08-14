const std = @import("std");
const clap = @import("clap");
const zdt = @import("zdt");
const uptime = @import("uptime");

pub fn main(init: std.process.Init) !void {
    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    const desc =
        \\This program takes a file containing an uptime log (e.g.:
        \\        2026-07-24 23:58:34 HEARTBEAT UP
        \\        2026-07-25 00:15:31 DOWN
        \\        2026-07-25 00:16:06 UP
        \\        2026-07-25 00:17:51 DOWN
        \\        2026-07-25 00:20:44 UP
        \\) and calculates the uptime percent in a specific window.
        \\
        \\`--start` and `--end` can be used to specify the window. Alternatively, the
        \\`--duration`, shortcut can be used in two ways: either pass it alone (and the
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

    const logfile = if (res.positionals[0]) |l| l else {
        std.debug.print("Missing log file path argument.\nUsage: ", .{});
        try clap.usageToFile(
            init.io,
            .stderr(),
            clap.Help,
            &params,
        );
        return error.MissingLogFile;
    };

    const start = if (res.args.start) |s|
        zdt.Datetime.fromISO8601(s) catch {
            std.debug.print("Error parsing `--start` argument. ISO8601 format is expected.\n", .{});
            return error.ParseError;
        }
    else
        null;

    const end = if (res.args.end) |e|
        zdt.Datetime.fromISO8601(e) catch {
            std.debug.print("Error parsing `--end` argument. ISO8601 format is expected.\n", .{});
            return error.ParseError;
        }
    else
        null;

    const threshold = if (res.args.threshold) |t| t else 35.0;

    if (!std.math.isFinite(threshold) or threshold <= 0) {
        std.debug.print("Invalid threshold value: {d}\n", .{threshold});
        return error.InvalidArgumentValue;
    }

    const duration = if (res.args.duration) |d|
        zdt.Duration.fromISO8601(d) catch {
            std.debug.print("Error parsing `--duration` argument. ISO8601 format is expected.\n", .{});
            return error.ParseError;
        }
    else
        null;

    var events = uptime.parseFile(
        init.io,
        init.gpa,
        logfile,
    ) catch |e| {
        std.debug.print("Error parsing log file: {s}\n", .{@errorName(e)});
        return e;
    };
    defer events.deinit(init.gpa);

    const result = uptime.analyze(
        events,
        start,
        end,
        zdt.Duration.fromTimespanMultiple(
            @intFromFloat(threshold * 60),
            .second,
        ),
        duration,
    ) catch |e| {
        std.debug.print("Error during analysis: {s}\n", .{@errorName(e)});
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
