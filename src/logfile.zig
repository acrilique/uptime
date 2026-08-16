//! Shared knowledge of the uptime log format, used by both the monitor
//! (which appends to the log) and the parser (which analyzes it).
//!
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

/// This is needed because zdt's Datetime.add/sub drop a plain utc_offset in
/// version 0.9.4 of zdt. [Opened an issue.](https://codeberg.org/FObersteiner/zdt/issues/41)
pub fn canonicalTs(ts: zdt.Datetime) !zdt.Datetime {
    if (ts.isNaive()) return ts;
    return ts.tzConvert(.{ .tz = &zdt.Timezone.UTC });
}

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

    const ts = canonicalTs(
        zdt.Datetime.fromISO8601(ts_token) catch return error.BadTimestamp,
    ) catch return error.BadTimestamp;

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
};

/// Extract the last known state and the last heartbeat timestamp from log
/// data, normally the tail of the log file. Malformed lines are ignored
pub fn lastKnown(data: []const u8) LastKnown {
    var known: LastKnown = .{ .state = null, .heartbeat = null };
    var it = std.mem.tokenizeScalar(u8, data, '\n');
    while (it.next()) |line| {
        const event = parseLine(line) catch continue;
        if (event) |e| {
            known.state = e.state;
            if (e.heartbeat) known.heartbeat = e.ts;
        }
    }
    return known;
}

/// Format a "<timestamp> <rest>\n" log line into `buf`.
pub fn formatLine(buf: []u8, ts: zdt.Datetime, rest: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buf, "{f} {s}\n", .{ ts, rest });
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

test "parseLine: offset timestamps are canonicalized to Z form" {
    const ev = try parseLine("2026-08-01T12:30:00+02:30 HEARTBEAT UP");
    try std.testing.expect(ev != null);
    try std.testing.expectEqual(
        try zdt.Datetime.fromISO8601("2026-08-01T10:00:00Z"),
        ev.?.ts,
    );
    // the whole point: arithmetic must not turn a canonical ts naive
    const later = try ev.?.ts.add(zdt.Duration.fromTimespanMultiple(60, .second));
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
    try std.testing.expectEqual(
        try zdt.Datetime.fromISO8601("2026-08-01T10:30:00Z"),
        known.heartbeat.?,
    );
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
