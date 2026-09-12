// SPDX-FileCopyrightText: 2026 Lluc Simó Margalef
//
// SPDX-License-Identifier: MIT

//! Log lines are "<timestamp> <event>\n", where <event> is one of:
//!   - "MONITOR STARTED" (informational, carries no state)
//!   - "UP" / "DOWN" (state transitions)
//!   - "HEARTBEAT UP" / "HEARTBEAT DOWN" (periodic state samples)
//! Timestamps are ISO8601, e.g. "2026-08-16T12:34:56.123456789Z".

const std = @import("std");
const zdt = @import("zdt");

/// A state-bearing log line.
pub const Event = struct {
    ts: zdt.Datetime,
    /// true is UP, false is DOWN
    state: bool,
    /// true when the state comes from a HEARTBEAT line
    heartbeat: bool,
};

/// Parse one log line into an Event. Returns null for lines that carry no
/// state to analyze (blank lines, comments, informational MONITOR entries);
/// returns an error for lines that look like log entries but fail to parse.
pub fn parseLine(line: []const u8) !?Event {
    const whitespace = " \t\n\r";
    const trimmed_line = std.mem.trim(u8, line, whitespace);

    if (std.mem.eql(u8, trimmed_line, "") or
        std.mem.startsWith(u8, trimmed_line, "#"))
    {
        return null;
    }

    var it = std.mem.tokenizeAny(u8, trimmed_line, whitespace);
    const ts_token = it.next().?; // trimmed_line is non-empty, so a token exists
    const command = it.next() orelse return error.MissingCommand;

    const ts = zdt.Datetime.fromISO8601(ts_token) catch return error.BadTimestamp;

    if (std.mem.eql(u8, command, "MONITOR")) return null;

    const is_heartbeat = std.mem.eql(u8, command, "HEARTBEAT");
    const state = if (is_heartbeat)
        it.next() orelse return error.MissingState
    else
        command;

    if (std.mem.eql(u8, state, "UP"))
        return Event{ .ts = ts, .state = true, .heartbeat = is_heartbeat };
    if (std.mem.eql(u8, state, "DOWN"))
        return Event{ .ts = ts, .state = false, .heartbeat = is_heartbeat };
    return error.UnknownState;
}

/// The freshest information recoverable from (the tail of) a log.
pub const LastKnown = struct {
    /// State on the last state-bearing line; null if there is none.
    state: ?bool,
    /// Timestamp of the last HEARTBEAT line; null if there is none.
    heartbeat: ?zdt.Datetime,
    /// True if any state-bearing line carried a naive timestamp. The monitor
    /// refuses such logs instead of making them mixed naive/aware.
    naive: bool,
};

/// Extract the last known state and the last heartbeat timestamp from log
/// data, normally the tail of the log file. Malformed lines are ignored
pub fn lastKnown(data: []const u8) LastKnown {
    var known: LastKnown = .{ .state = null, .heartbeat = null, .naive = false };
    var it = std.mem.tokenizeScalar(u8, data, '\n');
    while (it.next()) |line| {
        const event = parseLine(line) catch continue;
        if (event) |e| {
            known.state = e.state;
            if (e.heartbeat) known.heartbeat = e.ts;
            if (e.ts.isNaive()) known.naive = true;
        }
    }
    return known;
}

/// Format a "<timestamp> <rest>\n" log line into `buf`.
pub fn formatLine(buf: []u8, ts: zdt.Datetime, rest: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buf, "{f} {s}\n", .{ ts, rest });
}

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
    // on error the caller gets no way to free the partially-built list
    errdefer events.deinit(allocator);

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
        const ev = parseLine(line) catch |e| {
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

/// How the analysis window relates to the timespan covered by the log.
const WindowCoverage = enum {
    /// contained within the log's timespan
    inside,
    /// overlaps the timespan but sticks out on at least one end
    partial,
    /// no overlap with the timespan at all
    outside,
};

/// Classify where the window [ws, we] sits with respect to the log's
/// timespan [first_ts, last_ts]. A window touching an edge of the
/// timespan counts as inside.
fn windowCoverage(
    ws: zdt.Datetime,
    we: zdt.Datetime,
    first_ts: zdt.Datetime,
    last_ts: zdt.Datetime,
) !WindowCoverage {
    if ((try zdt.Datetime.compareUT(we, first_ts)) == .lt or
        (try zdt.Datetime.compareUT(ws, last_ts)) == .gt)
        return .outside;
    if ((try zdt.Datetime.compareUT(ws, first_ts)) == .lt or
        (try zdt.Datetime.compareUT(we, last_ts)) == .gt)
        return .partial;
    return .inside;
}

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

    // Bounds derived from the log equal its edges exactly, so a window that
    // reaches past the timespan can only come from caller-supplied bounds.
    switch (try windowCoverage(ws, we, first_ts, last_ts)) {
        .inside => {},
        .partial => std.log.warn(
            "Window {f} → {f} partially falls outside the log's timespan ({f} → {f})",
            .{ ws, we, first_ts, last_ts },
        ),
        .outside => std.log.warn(
            "Window {f} → {f} falls entirely outside the log's timespan ({f} → {f})",
            .{ ws, we, first_ts, last_ts },
        ),
    }

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

/// Parse a --start/--end argument.
pub fn parseBound(s: []const u8) !zdt.Datetime {
    return zdt.Datetime.fromISO8601(s);
}

fn testEvent(ts: []const u8, up: bool) !Event {
    return .{
        .ts = try zdt.Datetime.fromISO8601(ts),
        .state = up,
        .heartbeat = false,
    };
}

fn testThreshold() zdt.Duration {
    return zdt.Duration.fromTimespanMultiple(35, .minute) catch unreachable;
}

test "parseLine: state events" {
    const up = try parseLine("2026-08-01T10:00:00Z UP");
    try std.testing.expect(up != null);
    try std.testing.expect(up.?.state);
    try std.testing.expect(!up.?.heartbeat);

    const hb_down = try parseLine("2026-08-01T10:30:00+00:00 HEARTBEAT DOWN");
    try std.testing.expect(hb_down != null);
    try std.testing.expect(!hb_down.?.state);
    try std.testing.expect(hb_down.?.heartbeat);
}

test "parseLine: lines with no state are ignored" {
    try std.testing.expectEqual(@as(?Event, null), try parseLine(""));
    try std.testing.expectEqual(@as(?Event, null), try parseLine(" \t\r"));
    try std.testing.expectEqual(@as(?Event, null), try parseLine("# comment"));
    try std.testing.expectEqual(@as(?Event, null), try parseLine("2026-08-01T10:00:00Z MONITOR STARTED"));
}

test "parseLine: malformed lines return errors" {
    try std.testing.expectError(error.MissingCommand, parseLine("garbage"));
    try std.testing.expectError(error.MissingCommand, parseLine("2026-08-01T10:00:00Z"));
    try std.testing.expectError(error.BadTimestamp, parseLine("not-a-date UP"));
    try std.testing.expectError(error.BadTimestamp, parseLine("2026-13-45T25:99:99Z UP"));
    try std.testing.expectError(error.MissingState, parseLine("2026-08-01T10:30:00Z HEARTBEAT"));
    try std.testing.expectError(error.UnknownState, parseLine("2026-08-01T11:00:00Z MAYBE"));
}

test "parseLine: offset timestamps pass through unchanged" {
    const ev = try parseLine("2026-08-01T12:30:00+02:30 HEARTBEAT UP");
    try std.testing.expect(ev != null);
    try std.testing.expectEqual(
        try zdt.Datetime.fromISO8601("2026-08-01T12:30:00+02:30"),
        ev.?.ts,
    );
    // arithmetic must not turn an aware ts naive
    const later = try ev.?.ts.add(zdt.Duration.fromTimespanMultiple(60, .second) catch unreachable);
    try std.testing.expect(later.isAware());
}

test "parseLine: naive timestamps pass through unchanged" {
    const ev = try parseLine("2026-08-01T10:00:00 UP");
    try std.testing.expect(ev != null);
    try std.testing.expect(ev.?.ts.isNaive());
}

test "lastKnown: recovers state and heartbeat" {
    const known = lastKnown(
        \\2026-08-01T10:00:00Z MONITOR STARTED
        \\2026-08-01T10:01:00Z DOWN
        \\2026-08-01T10:30:00Z HEARTBEAT UP
        \\this line is corrupt
        \\
    );
    try std.testing.expect(known.state != null and known.state.?);
    try std.testing.expect(!known.naive);
    try std.testing.expectEqual(
        try zdt.Datetime.fromISO8601("2026-08-01T10:30:00Z"),
        known.heartbeat.?,
    );
}

test "lastKnown: flags naive timestamps" {
    const known = lastKnown(
        \\2026-08-01T10:00:00 HEARTBEAT UP
        \\2026-08-01T11:00:00 DOWN
    );
    try std.testing.expect(known.naive);
    try std.testing.expect(known.state != null and !known.state.?);
}

test "lastKnown: transition after heartbeat updates state only" {
    const known = lastKnown(
        \\2026-08-01T10:30:00Z HEARTBEAT UP
        \\2026-08-01T10:31:00Z DOWN
    );
    try std.testing.expect(known.state != null and !known.state.?);
    try std.testing.expectEqual(
        try zdt.Datetime.fromISO8601("2026-08-01T10:30:00Z"),
        known.heartbeat.?,
    );
}

test "lastKnown: empty or stateless data" {
    const none = lastKnown("");
    try std.testing.expect(none.state == null);
    try std.testing.expect(none.heartbeat == null);

    const started = lastKnown("2026-08-01T10:00:00Z MONITOR STARTED\n");
    try std.testing.expect(started.state == null);
    try std.testing.expect(started.heartbeat == null);
}

test "formatLine: matches the parseable log format" {
    const ts = try zdt.Datetime.fromISO8601(
        "2026-08-01T10:00:00.123456789Z",
    );
    var buf: [64]u8 = undefined;
    const line = try formatLine(&buf, ts, "HEARTBEAT DOWN");
    try std.testing.expectEqualStrings(
        "2026-08-01T10:00:00.123456789Z HEARTBEAT DOWN\n",
        line,
    );

    const event = try parseLine(line);
    try std.testing.expect(event != null);
    try std.testing.expect(!event.?.state);
    try std.testing.expect(event.?.heartbeat);
    try std.testing.expectEqual(ts, event.?.ts);
}

test "parseFile: parses a log into events sorted by timestamp" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const f = try tmp.dir.createFile(testing.io, "uptime.log", .{});
    defer f.close(testing.io);
    try f.writePositionalAll(
        testing.io,
        "2026-08-16T10:10:00Z UP\n" ++
            "2026-08-16T10:00:00Z DOWN\n" ++
            "2026-08-16T10:05:00Z HEARTBEAT UP\n",
        0,
    );

    var path_buf: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(
        &path_buf,
        ".zig-cache/tmp/{s}/uptime.log",
        .{tmp.sub_path},
    );

    var events = try parseFile(testing.io, testing.allocator, path);
    defer events.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 3), events.items.len);
    try testing.expect(eventLessThan({}, events.items[0], events.items[1]));
    try testing.expect(eventLessThan({}, events.items[1], events.items[2]));
    try testing.expect(!events.items[0].state);
    try testing.expect(events.items[1].heartbeat);
    try testing.expect(events.items[2].state);
}

test "parseFile: error paths free the events allocation" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const f = try tmp.dir.createFile(testing.io, "mixed.log", .{});
    defer f.close(testing.io);
    try f.writePositionalAll(
        testing.io,
        "2026-08-16T10:00:00Z UP\n" ++
            "2026-08-16T10:05:00 DOWN\n" ++
            "2026-08-16T10:10:00Z UP\n",
        0,
    );

    var path_buf: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(
        &path_buf,
        ".zig-cache/tmp/{s}/mixed.log",
        .{tmp.sub_path},
    );

    // the mixed naive/aware rejection fires after events have been appended;
    // std.testing.allocator fails the test if parseFile leaks them
    try testing.expectError(
        error.MixedNaiveAwareEvents,
        parseFile(testing.io, testing.allocator, path),
    );
}

test "analyze: outage already in progress at the start is counted" {
    var events: std.ArrayList(Event) = .empty;
    defer events.deinit(std.testing.allocator);
    // a monitor transition run appends DOWN and HEARTBEAT DOWN with one
    // timestamp, so the run's onset carries a zero-length interval
    try events.append(std.testing.allocator, try testEvent("2026-08-16T10:00:00Z", false));
    try events.append(std.testing.allocator, try testEvent("2026-08-16T10:00:00Z", false));
    try events.append(std.testing.allocator, try testEvent("2026-08-16T10:01:00Z", false));

    const result = try analyze(events, null, null, testThreshold(), null);
    try std.testing.expectEqual(@as(u32, 1), result.outage_count);
    try std.testing.expectEqual(@as(i128, 60 * std.time.ns_per_s), result.down_time.asNanoseconds());
}

test "analyze: each UP→DOWN transition is one outage" {
    var events: std.ArrayList(Event) = .empty;
    defer events.deinit(std.testing.allocator);
    try events.append(std.testing.allocator, try testEvent("2026-08-16T10:00:00Z", true));
    try events.append(std.testing.allocator, try testEvent("2026-08-16T10:15:00Z", false));
    try events.append(std.testing.allocator, try testEvent("2026-08-16T10:16:00Z", true));
    try events.append(std.testing.allocator, try testEvent("2026-08-16T10:17:00Z", false));
    try events.append(std.testing.allocator, try testEvent("2026-08-16T10:20:00Z", true));

    const result = try analyze(events, null, null, testThreshold(), null);
    try std.testing.expectEqual(@as(u32, 2), result.outage_count);
    try std.testing.expectEqual(@as(i128, 4 * 60 * std.time.ns_per_s), result.down_time.asNanoseconds());
}

test "analyze: outage entirely outside the window is not counted" {
    var events: std.ArrayList(Event) = .empty;
    defer events.deinit(std.testing.allocator);
    try events.append(std.testing.allocator, try testEvent("2026-08-16T10:00:00Z", true));
    try events.append(std.testing.allocator, try testEvent("2026-08-16T10:15:00Z", false));
    try events.append(std.testing.allocator, try testEvent("2026-08-16T10:20:00Z", true));
    // extends the timespan so the window below stays inside it
    try events.append(std.testing.allocator, try testEvent("2026-08-16T13:30:00Z", true));

    const start = try zdt.Datetime.fromISO8601("2026-08-16T12:00:00Z");
    const end = try zdt.Datetime.fromISO8601("2026-08-16T13:00:00Z");
    const result = try analyze(events, start, end, testThreshold(), null);
    try std.testing.expectEqual(@as(u32, 0), result.outage_count);
    try std.testing.expectEqual(@as(i128, 0), result.down_time.asNanoseconds());
}

test "analyze: outage straddling the window start is counted" {
    var events: std.ArrayList(Event) = .empty;
    defer events.deinit(std.testing.allocator);
    try events.append(std.testing.allocator, try testEvent("2026-08-16T10:00:00Z", true));
    try events.append(std.testing.allocator, try testEvent("2026-08-16T10:45:00Z", false));
    try events.append(std.testing.allocator, try testEvent("2026-08-16T11:30:00Z", true));
    // extends the timespan so the window below stays inside it
    try events.append(std.testing.allocator, try testEvent("2026-08-16T12:30:00Z", true));

    // DOWN at 10:45 is observed until 11:20 (35 min threshold), so 20 of
    // its minutes fall inside the window
    const start = try zdt.Datetime.fromISO8601("2026-08-16T11:00:00Z");
    const end = try zdt.Datetime.fromISO8601("2026-08-16T12:00:00Z");
    const result = try analyze(events, start, end, testThreshold(), null);
    try std.testing.expectEqual(@as(u32, 1), result.outage_count);
    try std.testing.expectEqual(@as(i128, 20 * 60 * std.time.ns_per_s), result.down_time.asNanoseconds());
}

fn testTs(ts: []const u8) !zdt.Datetime {
    return zdt.Datetime.fromISO8601(ts);
}

test "windowCoverage: window within the timespan" {
    const first = try testTs("2026-08-16T10:00:00Z");
    const last = try testTs("2026-08-16T12:00:00Z");
    // a window touching the edges is still inside
    try std.testing.expectEqual(
        WindowCoverage.inside,
        try windowCoverage(first, last, first, last),
    );
    try std.testing.expectEqual(
        WindowCoverage.inside,
        try windowCoverage(
            try testTs("2026-08-16T10:30:00Z"),
            try testTs("2026-08-16T11:00:00Z"),
            first,
            last,
        ),
    );
}

test "windowCoverage: window sticking out of the timespan" {
    const first = try testTs("2026-08-16T10:00:00Z");
    const last = try testTs("2026-08-16T12:00:00Z");
    try std.testing.expectEqual(
        WindowCoverage.partial,
        try windowCoverage(
            try testTs("2026-08-16T09:00:00Z"),
            last,
            first,
            last,
        ),
    );
    try std.testing.expectEqual(
        WindowCoverage.partial,
        try windowCoverage(
            first,
            try testTs("2026-08-16T13:00:00Z"),
            first,
            last,
        ),
    );
    // sticking out on both ends still counts as partial
    try std.testing.expectEqual(
        WindowCoverage.partial,
        try windowCoverage(
            try testTs("2026-08-16T09:00:00Z"),
            try testTs("2026-08-16T13:00:00Z"),
            first,
            last,
        ),
    );
}

test "windowCoverage: window disjoint from the timespan" {
    const first = try testTs("2026-08-16T10:00:00Z");
    const last = try testTs("2026-08-16T12:00:00Z");
    try std.testing.expectEqual(
        WindowCoverage.outside,
        try windowCoverage(
            try testTs("2026-08-16T08:00:00Z"),
            try testTs("2026-08-16T09:00:00Z"),
            first,
            last,
        ),
    );
    try std.testing.expectEqual(
        WindowCoverage.outside,
        try windowCoverage(
            try testTs("2026-08-16T13:00:00Z"),
            try testTs("2026-08-16T14:00:00Z"),
            first,
            last,
        ),
    );
}
