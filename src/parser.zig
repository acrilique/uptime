const std = @import("std");
const clap = @import("clap");
const zdt = @import("zdt");
const logfile = @import("logfile");

const Event = logfile.Event;

/// Less-than for sorting Events by timestamp (Unix time incl. nanoseconds).
fn eventLessThan(
    _: void,
    a: Event,
    b: Event,
) bool {
    return (zdt.Datetime.compareUT(a.ts, b.ts) catch unreachable) == .lt;
}

pub fn parseFile(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
) !std.ArrayList(Event) {
    var events: std.ArrayList(Event) = .empty;

    const file = if (std.fs.path.isAbsolute(path))
        try std.Io.Dir.openFileAbsolute(io, path, .{})
    else
        try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);

    var buf: [1 << 16]u8 = undefined;
    var r = file.readerStreaming(io, &buf);
    const data = try r.interface.allocRemaining(allocator, .unlimited);
    defer allocator.free(data);

    var it = std.mem.tokenizeScalar(u8, data, '\n');
    var line_no: usize = 0;
    while (it.next()) |line| {
        line_no += 1;
        const ev = logfile.parseLine(line) catch |e| {
            std.log.warn("Couldn't parse log line {d} ({s}): {s}", .{
                line_no,
                @errorName(e),
                line,
            });
            continue;
        };
        if (ev) |e| try events.append(allocator, e);
    }

    if (events.items.len > 1)
        for (events.items[1..]) |ev|
            if (ev.ts.isAware() != events.items[0].ts.isAware())
                return error.MixedNaiveAwareEvents;

    std.mem.sort(Event, events.items, {}, eventLessThan);

    return events;
}

/// The result of the analyze() function.
pub const Result = struct {
    window_start: zdt.Datetime,
    window_end: zdt.Datetime,
    up_time: zdt.Duration,
    down_time: zdt.Duration,
    observed_time: zdt.Duration,
    lost_time: zdt.Duration,
    window_length: zdt.Duration,
    outage_count: u32,

    pub fn uptime_pct(self: Result) f32 {
        const observed = self.observed_time.totalSeconds();
        return if (observed > 0)
            @floatCast(self.up_time.totalSeconds() / observed * 100.0)
        else
            0.0;
    }

    pub fn confidence_pct(self: Result) f32 {
        const period = self.window_length.totalSeconds();
        return if (period > 0)
            @floatCast(self.observed_time.totalSeconds() / period * 100.0)
        else
            0.0;
    }
};

/// Analyze a list of events given a specific time span and threshold, and
/// obtain a result containing the uptime percentage amongst other things.
pub fn analyze(
    events: std.ArrayList(Event),
    window_start: ?zdt.Datetime,
    window_end: ?zdt.Datetime,
    threshold: zdt.Duration,
    duration: ?zdt.Duration,
) !Result {
    if (window_start != null and window_end != null and duration != null)
        return error.DurationPassedAlongsideBothWindowBounds;

    if (events.items.len <= 0)
        return error.EmptyLogFile;

    const first_ts = events.items[0].ts;
    const last_ts = events.items[events.items.len - 1].ts;

    // Window end: explicit --end wins; with a duration, derive it from
    // --start or fall back to the last logged event.
    const we = if (duration) |dur|
        if (window_end) |e|
            e
        else if (window_start) |s|
            try s.add(dur)
        else
            last_ts
    else
        window_end orelse last_ts;

    // Window start: explicit --start wins; otherwise derive it from --end
    // (or, with no bounds at all, from the window end).
    const ws = if (duration) |dur|
        if (window_start) |s|
            s
        else if (window_end) |e|
            try e.sub(dur)
        else
            try we.sub(dur)
    else
        window_start orelse first_ts;

    if (try zdt.Datetime.compareUT(we, ws) == .lt)
        return error.MisorderedWindowBounds;

    var uptime: zdt.Duration = .{};
    var downtime: zdt.Duration = .{};
    var outage_count: u32 = 0;
    var prev_state: ?bool = null;

    for (events.items, 0..) |event, index| {
        const next_ts = if ((index + 1) < events.items.len)
            events.items[index + 1].ts
        else
            we;

        const interval_start =
            if (try zdt.Datetime.compareUT(event.ts, ws) == .gt)
                event.ts
            else
                ws;

        const event_plus_th = try event.ts.add(threshold);

        const temp_min =
            if (try zdt.Datetime.compareUT(event_plus_th, next_ts) == .gt)
                next_ts
            else
                event_plus_th;

        const interval_end =
            if (try zdt.Datetime.compareUT(temp_min, we) == .gt)
                we
            else
                temp_min;

        if (try zdt.Datetime.compareUT(interval_end, interval_start) == .gt) {
            const observed = interval_end.diff(interval_start);
            if (event.state)
                uptime = try uptime.add(observed)
            else {
                downtime = try downtime.add(observed);
                if (prev_state orelse true) outage_count += 1;
            }
        }

        prev_state = event.state;
    }

    const observed_time = try uptime.add(downtime);
    const window_length = we.diff(ws);
    const zerodur: zdt.Duration = .{};
    const lost_time =
        if (window_length.asNanoseconds() - observed_time.asNanoseconds() > 0)
            try window_length.sub(observed_time)
        else
            zerodur;

    return Result{
        .window_start = ws,
        .window_end = we,
        .up_time = uptime,
        .down_time = downtime,
        .observed_time = observed_time,
        .lost_time = lost_time,
        .window_length = window_length,
        .outage_count = outage_count,
    };
}

/// Parse a --start/--end argument into its canonical timestamp form.
fn parseBound(s: []const u8) !zdt.Datetime {
    return logfile.canonicalTs(try zdt.Datetime.fromISO8601(s));
}

/// Name the window bound(s) whose awareness differs from the log's.
fn reportMixedAwareness(
    log_path: []const u8,
    events: []const Event,
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
        parseBound(s) catch {
            std.log.err("Error parsing `--start` argument. ISO8601 format is expected.", .{});
            return error.ParseError;
        }
    else
        null;

    const end = if (res.args.end) |e|
        parseBound(e) catch {
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

    var events = parseFile(
        init.io,
        init.gpa,
        log_path,
    ) catch |e| {
        std.log.err("Error parsing log file: {s}", .{@errorName(e)});
        return e;
    };
    defer events.deinit(init.gpa);

    const result = analyze(
        events,
        start,
        end,
        zdt.Duration.fromTimespanMultiple(
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
