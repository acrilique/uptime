const std = @import("std");
const zdt = @import("zdt");

pub const Event = struct {
    ts: zdt.Datetime,
    /// true is UP, false is DOWN
    state: bool,
};

/// Less-than for sorting Events by timestamp (Unix time incl. nanoseconds).
fn eventLessThan(
    _: void,
    a: Event,
    b: Event,
) bool {
    return (zdt.Datetime.compareUT(a.ts, b.ts) catch unreachable) == .lt;
}

/// Parse one log line into an Event, or return null if unparseable
pub fn parseLine(line: []const u8) !?Event {
    const whitespace = " \t\n\r";
    const trimmed_line = std.mem.trim(u8, line, whitespace);

    if (std.mem.eql(
        u8,
        trimmed_line,
        "",
    ) or std.mem.startsWith(
        u8,
        trimmed_line,
        "#",
    )) {
        return null;
    }

    var it = std.mem.tokenizeAny(u8, trimmed_line, whitespace);
    const first = it.next() orelse return null;
    const second = it.next() orelse return null;

    var buf: [32]u8 = undefined;
    const combined = try std.fmt.bufPrint(
        &buf,
        "{s} {s}",
        .{ first, second },
    );
    const ts =
        zdt.Datetime.fromString(combined, "%Y-%m-%d %H:%M:%S") catch return null;

    var state: ?[]const u8 = null;
    while (it.next()) |token|
        state = token;

    if (state) |s| {
        if (std.mem.eql(u8, s, "UP")) {
            return Event{ .ts = ts, .state = true };
        } else if (std.mem.eql(u8, s, "DOWN")) {
            return Event{ .ts = ts, .state = false };
        } else return null;
    } else return null;
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
    while (it.next()) |line| {
        const ev = parseLine(line) catch continue;
        if (ev) |e| try events.append(allocator, e);
    }

    std.mem.sort(Event, events.items, {}, eventLessThan);

    return events;
}

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

    var uptime: zdt.Duration = zdt.Duration{ .__nsec = 0, .__sec = 0 };
    var downtime: zdt.Duration = zdt.Duration{ .__nsec = 0, .__sec = 0 };
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
    const zerodur = zdt.Duration{ .__nsec = 0, .__sec = 0 };
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
