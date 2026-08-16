const std = @import("std");
const clap = @import("clap");
const zdt = @import("zdt");
const logfile = @import("logfile");

pub const Event = logfile.Event;

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

    if (events.items.len > 1) {
        const first_is_aware = events.items[0].ts.isAware();
        for (events.items[1..]) |ev| {
            if (ev.ts.isAware() != first_is_aware)
                return error.MixedNaiveAwareEvents;
        }
    }

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
    /// Observed outages: each transition into DOWN within the window,
    /// including one already in progress when the window opens.
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
    var last_observed: ?bool = null;

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
            if (event.state) {
                uptime = try uptime.add(observed);
            } else {
                downtime = try downtime.add(observed);
                // null means nothing was observed before it: the outage was
                // already in progress when the window opened
                if (last_observed orelse true) outage_count += 1;
            }
            last_observed = event.state;
        }
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
pub fn parseBound(s: []const u8) !zdt.Datetime {
    return logfile.canonicalTs(try zdt.Datetime.fromISO8601(s));
}

const testing = std.testing;

fn testEvent(ts: []const u8, up: bool) !Event {
    return .{
        .ts = try logfile.canonicalTs(try zdt.Datetime.fromISO8601(ts)),
        .state = up,
        .heartbeat = false,
    };
}

fn testThreshold() zdt.Duration {
    return zdt.Duration.fromTimespanMultiple(35, .minute);
}

test "analyze: outage already in progress at the start is counted" {
    var events: std.ArrayList(Event) = .empty;
    defer events.deinit(testing.allocator);
    // a monitor transition run appends DOWN and HEARTBEAT DOWN with one
    // timestamp, so the run's onset carries a zero-length interval
    try events.append(testing.allocator, try testEvent("2026-08-16T10:00:00Z", false));
    try events.append(testing.allocator, try testEvent("2026-08-16T10:00:00Z", false));
    try events.append(testing.allocator, try testEvent("2026-08-16T10:01:00Z", false));

    const result = try analyze(events, null, null, testThreshold(), null);
    try testing.expectEqual(@as(u32, 1), result.outage_count);
    try testing.expectEqual(@as(i128, 60 * std.time.ns_per_s), result.down_time.asNanoseconds());
}

test "analyze: each UP→DOWN transition is one outage" {
    var events: std.ArrayList(Event) = .empty;
    defer events.deinit(testing.allocator);
    try events.append(testing.allocator, try testEvent("2026-08-16T10:00:00Z", true));
    try events.append(testing.allocator, try testEvent("2026-08-16T10:15:00Z", false));
    try events.append(testing.allocator, try testEvent("2026-08-16T10:16:00Z", true));
    try events.append(testing.allocator, try testEvent("2026-08-16T10:17:00Z", false));
    try events.append(testing.allocator, try testEvent("2026-08-16T10:20:00Z", true));

    const result = try analyze(events, null, null, testThreshold(), null);
    try testing.expectEqual(@as(u32, 2), result.outage_count);
    try testing.expectEqual(@as(i128, 4 * 60 * std.time.ns_per_s), result.down_time.asNanoseconds());
}

test "analyze: outage entirely outside the window is not counted" {
    var events: std.ArrayList(Event) = .empty;
    defer events.deinit(testing.allocator);
    try events.append(testing.allocator, try testEvent("2026-08-16T10:00:00Z", true));
    try events.append(testing.allocator, try testEvent("2026-08-16T10:15:00Z", false));
    try events.append(testing.allocator, try testEvent("2026-08-16T10:20:00Z", true));

    const start = try logfile.canonicalTs(try zdt.Datetime.fromISO8601("2026-08-16T12:00:00Z"));
    const end = try logfile.canonicalTs(try zdt.Datetime.fromISO8601("2026-08-16T13:00:00Z"));
    const result = try analyze(events, start, end, testThreshold(), null);
    try testing.expectEqual(@as(u32, 0), result.outage_count);
    try testing.expectEqual(@as(i128, 0), result.down_time.asNanoseconds());
}

test "analyze: outage straddling the window start is counted" {
    var events: std.ArrayList(Event) = .empty;
    defer events.deinit(testing.allocator);
    try events.append(testing.allocator, try testEvent("2026-08-16T10:00:00Z", true));
    try events.append(testing.allocator, try testEvent("2026-08-16T10:45:00Z", false));
    try events.append(testing.allocator, try testEvent("2026-08-16T11:30:00Z", true));

    // DOWN at 10:45 is observed until 11:20 (35 min threshold), so 20 of
    // its minutes fall inside the window
    const start = try logfile.canonicalTs(try zdt.Datetime.fromISO8601("2026-08-16T11:00:00Z"));
    const end = try logfile.canonicalTs(try zdt.Datetime.fromISO8601("2026-08-16T12:00:00Z"));
    const result = try analyze(events, start, end, testThreshold(), null);
    try testing.expectEqual(@as(u32, 1), result.outage_count);
    try testing.expectEqual(@as(i128, 20 * 60 * std.time.ns_per_s), result.down_time.asNanoseconds());
}
