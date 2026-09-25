// SPDX-FileCopyrightText: 2026 Lluc Simó Margalef
//
// SPDX-License-Identifier: MIT

//! `uptime-dashboard`: a read-only web dashboard over an uptime log.

const std = @import("std");
const Io = std.Io;
const clap = @import("clap");
const zdt = @import("zdt");
const uptime = @import("uptime");
const datastar = @import("datastar");

/// filters only the `uptime` library's logging (its info notices would
/// repeat on every SSE tick); the app itself writes to the streams directly
pub const std_options: std.Options = .{
    .log_level = .warn,
};

const shell_tpl = @embedFile("shell.html");
const archive_tpl = @embedFile("archive.html");
const style_css = @embedFile("style.css");
const datastar_js = @embedFile("vendor/datastar.js");

const default_address = "0.0.0.0";
const default_port: u16 = 8080;
const default_refresh_s: u32 = 30;
const default_threshold_min: f32 = 35.0;
const default_tz = "localtime";

/// family-sized: a handful of devices, each holding one SSE stream
const max_connections: u32 = 32;
const keepalive_ms: u64 = 15_000;
/// outages per archive page; older pages are reached via `before=` cursors
const outage_page_size: usize = 15;
/// rows the dashboard's outage teaser shows before linking to `/outages`
const outage_teaser_rows: usize = 3;
/// SVG timeline is drawn in a 1000-unit-wide viewBox
const svg_width: f64 = 1000;
/// minimum visible width of a downtime slice, in viewBox units
const min_down_width: f64 = 2.0;

// ---------------------------------------------------------------------------
// windows

const Window = enum { h24, d7, d30 };

const WindowSpec = struct {
    id: []const u8,
    label: []const u8,
    tab: []const u8,
    hours: i96,
};

const window_specs = [_]WindowSpec{
    .{ .id = "24h", .label = "24 hours", .tab = "24 h", .hours = 24 },
    .{ .id = "7d", .label = "7 days", .tab = "7 days", .hours = 7 * 24 },
    .{ .id = "30d", .label = "30 days", .tab = "30 days", .hours = 30 * 24 },
};

fn windowSpec(window: Window) WindowSpec {
    return switch (window) {
        .h24 => window_specs[0],
        .d7 => window_specs[1],
        .d30 => window_specs[2],
    };
}

fn windowFromId(id: []const u8) ?Window {
    for (window_specs, 0..) |spec, i| {
        if (std.mem.eql(u8, spec.id, id)) return @enumFromInt(i);
    }
    return null;
}

fn windowDuration(window: Window) zdt.Duration {
    return zdt.Duration.fromTimespanMultiple(windowSpec(window).hours, .hour) catch unreachable;
}

// ---------------------------------------------------------------------------
// datetime helpers

fn nsBetween(a: zdt.Datetime, b: zdt.Datetime) i128 {
    return a.diff(b).asNanoseconds();
}

fn durSecs(s: i64) zdt.Duration {
    return zdt.Duration.fromTimespanMultiple(s, .second) catch unreachable;
}

/// Same instant in UTC; naive datetimes pass through untouched.
fn utcOf(when: zdt.Datetime) zdt.Datetime {
    return when.tzConvert(.{ .tz = &zdt.Timezone.UTC }) catch when;
}

// ---------------------------------------------------------------------------
// formatting helpers

fn secondsOf(dur: zdt.Duration) i64 {
    const ns = dur.asNanoseconds();
    if (ns <= 0) return 0;
    return @intCast(@divTrunc(ns, std.time.ns_per_s));
}

fn writeDuration(w: *Io.Writer, dur: zdt.Duration) !void {
    const s = secondsOf(dur);
    const d = @divTrunc(s, 86400);
    const h = @divTrunc(@mod(s, 86400), 3600);
    const m = @divTrunc(@mod(s, 3600), 60);
    const sec = @mod(s, 60);
    if (d > 0) {
        try w.print("{d}d {d}h", .{ d, h });
    } else if (h > 0) {
        try w.print("{d}h {d}m", .{ h, m });
    } else if (m > 0) {
        try w.print("{d}m {d}s", .{ m, sec });
    } else {
        try w.print("{d}s", .{sec});
    }
}

/// "Thu 25 Sep, 14:32" in the display timezone; raw fields on tz failure.
fn writeTimestamp(w: *Io.Writer, when: zdt.Datetime, tz: *const zdt.Timezone) !void {
    const local = when.tzConvert(.{ .tz = tz }) catch {
        try w.print("{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}", .{
            @as(u32, @intCast(@max(when.year, 0))), when.month, when.day, when.hour, when.minute,
        });
        return;
    };
    try w.print("{s} {d} {s}, {d:0>2}:{d:0>2}", .{
        local.weekday().shortName(),
        local.day,
        @tagName(local.monthEnum())[0..3],
        local.hour,
        local.minute,
    });
}

// ---------------------------------------------------------------------------
// snapshot: everything one render tick needs, built from the log

const HeroState = enum { up, down, none };

const Snapshot = struct {
    /// false when the log could not be parsed; `err_msg` says why
    ok: bool,
    err_msg: []const u8 = "",

    state: HeroState = .none,
    since: zdt.Datetime = undefined,
    since_dur: zdt.Duration = .{},
    stale: bool = false,

    result: uptime.Result = undefined,
    segs: []const uptime.Segment = &.{},
    outage_rows: []const uptime.Outage = &.{},

    /// outage-list cursor: only outages that started strictly before it
    /// are rendered; null means the newest page
    before: ?zdt.Datetime = null,
    window: Window,
    ws: zdt.Datetime,
    we: zdt.Datetime,
};

fn errSnapshot(window: Window, ws: zdt.Datetime, we: zdt.Datetime, msg: []const u8) Snapshot {
    return .{ .ok = false, .err_msg = msg, .window = window, .ws = ws, .we = we };
}

fn buildSnapshot(
    io: Io,
    arena: std.mem.Allocator,
    log_path: []const u8,
    view: View,
    threshold: zdt.Duration,
    now: zdt.Datetime,
) Snapshot {
    const window = view.window;
    const dur = windowDuration(window);
    const ws = now.sub(dur) catch unreachable;
    const we = now;

    var events = uptime.parseFile(io, arena, log_path) catch |e| {
        return errSnapshot(window, ws, we, switch (e) {
            error.FileNotFound => "Log file not found — is the monitor running?",
            error.AccessDenied => "Cannot read the log file.",
            error.IsDir => "The log path is a directory.",
            error.LogTooLarge => "Log file exceeds 1 GiB.",
            error.MixedNaiveAwareEvents => "Log mixes aware and naive timestamps.",
            else => "Could not read the log.",
        });
    };
    defer events.deinit(arena);

    if (events.items.len == 0)
        return errSnapshot(window, ws, we, "No checks recorded yet — waiting for data.");

    const result = uptime.analyze(events, null, we, threshold, dur) catch
        return errSnapshot(window, ws, we, "Could not analyze the log.");

    const segs = uptime.buildSegments(arena, events.items, ws, we, threshold) catch
        return errSnapshot(window, ws, we, "Could not analyze the log.");
    const outage_rows = uptime.outagesFromSegments(arena, segs, we) catch
        return errSnapshot(window, ws, we, "Could not analyze the log.");

    var snap = Snapshot{
        .ok = true,
        .result = result,
        .segs = segs,
        .outage_rows = outage_rows,
        .before = view.before,
        .window = window,
        .ws = ws,
        .we = we,
    };

    // hero: current state = last event; run start = first event of that
    // state's run (heartbeats of the same state belong to the run)
    const items = events.items;
    const last = items[items.len - 1];
    var run_start_idx = items.len - 1;
    while (run_start_idx > 0 and items[run_start_idx - 1].state == last.state)
        run_start_idx -= 1;

    snap.state = if (last.state) .up else .down;
    snap.since = items[run_start_idx].ts;
    snap.since_dur = we.diff(snap.since);
    snap.stale = we.diff(last.ts).asNanoseconds() > threshold.asNanoseconds();

    return snap;
}

// ---------------------------------------------------------------------------
// fragment rendering (server-side HTML; roots carry the ids Datastar morphs)

fn renderHero(arena: std.mem.Allocator, snap: Snapshot, tz: *const zdt.Timezone) ![]const u8 {
    var buf: Io.Writer.Allocating = .init(arena);
    const w = &buf.writer;

    if (!snap.ok) {
        try w.print(
            \\<div id="hero" class="hero unknown"><div class="state"><span class="dot"></span> ?</div>
            \\<div class="meta"><p>{s}</p></div></div>
        , .{snap.err_msg});
        return buf.written();
    }

    const cls = switch (snap.state) {
        .up => "up",
        .down => "down",
        .none => "unknown",
    };
    const label = switch (snap.state) {
        .up => "UP",
        .down => "DOWN",
        .none => "no data",
    };

    try w.print(
        \\<div id="hero" class="hero {s}"><div class="state"><span class="dot"></span> {s}</div>
    , .{ cls, label });
    if (snap.state != .none) {
        try w.writeAll("<div class=\"meta\"><p>Since <strong>");
        try writeTimestamp(w, snap.since, tz);
        try w.writeAll("</strong> (");
        try writeDuration(w, snap.since_dur);
        try w.writeAll(")</p>");
        if (snap.stale) try w.writeAll("<p><span class=\"stale-badge\">stale</span></p>");
        try w.writeAll("</div>");
    } else {
        try w.writeAll("<div class=\"meta\"><p>No data.</p></div>");
    }
    try w.writeAll("</div>");

    return buf.written();
}

fn renderSummary(arena: std.mem.Allocator, snap: Snapshot) ![]const u8 {
    var buf: Io.Writer.Allocating = .init(arena);
    const w = &buf.writer;

    if (!snap.ok) {
        try w.print(
            \\<section id="summary" class="grid"><p class="empty">{s}</p></section>
        , .{snap.err_msg});
        return buf.written();
    }

    const pct = snap.result.uptime_pct();
    const pct_cls: []const u8 = if (pct >= 99.9) "good" else if (pct < 99.0) "bad" else "";

    try w.writeAll(
        \\<section id="summary" class="grid">
        \\<div class="card"><span class="k">Uptime</span><span class="v
    );
    if (pct_cls.len > 0) try w.print(" {s}", .{pct_cls});
    try w.print(
        \\">{d:.2}%</span></div>
        \\<div class="card"><span class="k">Downtime</span><span class="v
    , .{pct});
    if (snap.result.down_time.asNanoseconds() > 0) try w.writeAll(" bad");
    try w.writeAll("\">");
    try writeDuration(w, snap.result.down_time);
    try w.print(
        \\</span></div>
        \\<div class="card"><span class="k">Outages</span><span class="v">{d}</span></div>
        \\<div class="card"><span class="k">Coverage</span><span class="v">{d:.1}%</span></div>
        \\</section>
    , .{ snap.result.outage_count, snap.result.confidence_pct() });

    return buf.written();
}

fn renderTimeline(arena: std.mem.Allocator, snap: Snapshot, tz: *const zdt.Timezone) ![]const u8 {
    var buf: Io.Writer.Allocating = .init(arena);
    const w = &buf.writer;

    if (!snap.ok) {
        try w.print(
            \\<section id="timeline" class="timeline"><p class="empty">{s}</p></section>
        , .{snap.err_msg});
        return buf.written();
    }

    const spec = windowSpec(snap.window);
    const total_ns: f64 = @floatFromInt(@max(nsBetween(snap.we, snap.ws), 1));

    try w.print(
        \\<section id="timeline" class="timeline"><h2>Last {s}</h2>
        \\<svg viewBox="0 0 {d:.0} 48" preserveAspectRatio="none" shape-rendering="crispEdges" role="img" aria-label="uptime timeline for the last {s}">
    , .{ spec.label, svg_width, spec.label });

    for (snap.segs) |seg| {
        const start_ns: f64 = @floatFromInt(nsBetween(seg.start, snap.ws));
        const end_ns: f64 = @floatFromInt(nsBetween(seg.end, snap.ws));
        var x = start_ns / total_ns * svg_width;
        var width = (end_ns - start_ns) / total_ns * svg_width;
        if (width <= 0) continue;
        // keep short outages visible on long windows
        if (seg.state == .down and width < min_down_width) {
            width = min_down_width;
            x = @min(x, svg_width - min_down_width);
        }
        try w.print(
            \\<rect class="seg-{s}" x="{d:.2}" y="4" width="{d:.2}" height="40"/>
        , .{ @tagName(seg.state), x, width });
    }

    const half = zdt.Duration.fromTimespanMultiple(spec.hours * 1800, .second) catch unreachable;
    const mid = snap.ws.add(half) catch snap.we;

    try w.writeAll("</svg><div class=\"axis\"><span>");
    try writeTimestamp(w, snap.ws, tz);
    try w.writeAll("</span><span>");
    try writeTimestamp(w, mid, tz);
    try w.writeAll("</span><span>now</span></div>");
    try w.writeAll(
        \\<div class="legend"><span class="l-up">up</span><span class="l-down">down</span><span class="l-unknown">no data</span></div>
        \\</section>
    );

    return buf.written();
}

/// The dashboard's outage section: a short peek at the newest outages,
/// linking to the full paginated list on `/outages`.
fn renderOutageTeaser(arena: std.mem.Allocator, snap: Snapshot, tz: *const zdt.Timezone) ![]const u8 {
    var buf: Io.Writer.Allocating = .init(arena);
    const w = &buf.writer;

    if (!snap.ok) {
        try w.print(
            \\<section id="outages"><p class="empty">{s}</p></section>
        , .{snap.err_msg});
        return buf.written();
    }

    try w.print(
        \\<section id="outages"><h2>Outages ({d})</h2>
    , .{snap.result.outage_count});

    if (snap.outage_rows.len == 0) {
        try w.writeAll("<p class=\"empty\">No downtime recorded in this window.</p></section>");
        return buf.written();
    }

    try w.writeAll("<table><thead><tr><th>Started</th><th>Lasted</th></tr></thead><tbody>");
    var i = snap.outage_rows.len;
    while (i > 0 and snap.outage_rows.len - i < outage_teaser_rows) {
        i -= 1;
        try writeOutageRow(w, snap.outage_rows[i], tz);
    }
    try w.writeAll("</tbody></table>");
    if (snap.outage_rows.len > outage_teaser_rows) {
        try w.print(
            "<a class=\"more\" href=\"/outages?window={s}\">All outages →</a>",
            .{windowSpec(snap.window).id},
        );
    }
    try w.writeAll("</section>");

    return buf.written();
}

/// One page of the outage archive: the `outage_page_size` newest outages
/// that started strictly before `snap.before` (the newest ones when it is
/// null). Cursor links keep deeper pages anchored while outages arrive.
fn renderOutages(arena: std.mem.Allocator, snap: Snapshot, tz: *const zdt.Timezone) ![]const u8 {
    var buf: Io.Writer.Allocating = .init(arena);
    const w = &buf.writer;

    if (!snap.ok) {
        try w.print(
            \\<section id="outages"><p class="empty">{s}</p></section>
        , .{snap.err_msg});
        return buf.written();
    }

    try w.print(
        \\<section id="outages"><h2>Outages ({d})</h2>
    , .{snap.result.outage_count});

    if (snap.outage_rows.len == 0) {
        try w.writeAll("<p class=\"empty\">No downtime recorded in this window.</p></section>");
        return buf.written();
    }

    // rows are chronological; walk the newest boundary down to the cursor
    const rows = snap.outage_rows;
    var end = rows.len;
    if (snap.before) |cursor| {
        while (end > 0 and
            (zdt.Datetime.compareUT(rows[end - 1].start, cursor) catch unreachable) != .lt)
        {
            end -= 1;
        }
    }

    if (end == 0) {
        try w.writeAll("<p class=\"empty\">No outages before this point.</p>");
        try writePager(w, snap, 0, 0);
        try w.writeAll("</section>");
        return buf.written();
    }

    const start = end -| outage_page_size;

    try w.writeAll("<table><thead><tr><th>Started</th><th>Lasted</th></tr></thead><tbody>");
    var i = end;
    while (i > start) {
        i -= 1;
        try writeOutageRow(w, rows[i], tz);
    }
    try w.writeAll("</tbody></table>");
    try writePager(w, snap, start, end);
    try w.writeAll("</section>");

    return buf.written();
}

fn writeOutageRow(w: *Io.Writer, row: uptime.Outage, tz: *const zdt.Timezone) !void {
    try w.writeAll("<tr><td>");
    try writeTimestamp(w, row.start, tz);
    if (row.end != null) {
        try w.writeAll("</td><td>");
        try writeDuration(w, row.dur);
    } else {
        try w.writeAll("</td><td class=\"ongoing\">still down");
    }
    try w.writeAll("</td></tr>");
}

/// Prev/next links around one archive page. "Older" anchors at the oldest
/// visible row; "Newer" at the row one full page above it, dropping the
/// cursor when that page already reaches the newest outages.
fn writePager(w: *Io.Writer, snap: Snapshot, start: usize, end: usize) !void {
    const rows = snap.outage_rows;
    const id = windowSpec(snap.window).id;

    const has_newer = end < rows.len;
    const newer_before: ?zdt.Datetime = if (has_newer and end + outage_page_size < rows.len)
        rows[end + outage_page_size].start
    else
        null;
    const older_before: ?zdt.Datetime = if (start > 0) rows[start].start else null;

    if (!has_newer and older_before == null) return;

    try w.writeAll("<nav class=\"pager\">");
    if (has_newer) {
        if (newer_before) |cursor| {
            try w.print("<a href=\"/outages?window={s}&before={f}\">← Newer</a>", .{ id, utcOf(cursor) });
        } else {
            try w.print("<a href=\"/outages?window={s}\">← Newer</a>", .{id});
        }
    }
    if (older_before) |cursor| {
        try w.print(
            "<a class=\"older\" href=\"/outages?window={s}&before={f}\">Older →</a>",
            .{ id, utcOf(cursor) },
        );
    }
    try w.writeAll("</nav>");
}

fn renderGenerated(arena: std.mem.Allocator, now: zdt.Datetime, tz: *const zdt.Timezone, refresh_s: u32) ![]const u8 {
    var buf: Io.Writer.Allocating = .init(arena);
    const w = &buf.writer;
    try w.writeAll("Updated ");
    try writeTimestamp(w, now, tz);
    try w.print(" · refreshes every {d} s", .{refresh_s});
    return buf.written();
}

fn tabCls(current: Window, tab: Window) []const u8 {
    return if (current == tab) "active" else "";
}

/// The window tabs; `base` ("/" or "/outages") keeps them on the current
/// surface.
fn renderTabs(arena: std.mem.Allocator, base: []const u8, current: Window) ![]const u8 {
    var buf: Io.Writer.Allocating = .init(arena);
    const w = &buf.writer;
    try w.writeAll("<nav class=\"tabs\" aria-label=\"Time window\">");
    for (window_specs, 0..) |spec, i| {
        try w.print("<a href=\"{s}?window={s}\" class=\"{s}\">{s}</a>", .{
            base, spec.id, tabCls(current, @enumFromInt(i)), spec.tab,
        });
    }
    try w.writeAll("</nav>");
    return buf.written();
}

fn renderPage(
    arena: std.mem.Allocator,
    snap: Snapshot,
    tz: *const zdt.Timezone,
    refresh_s: u32,
    now: zdt.Datetime,
) ![]const u8 {
    const hero = try renderHero(arena, snap, tz);
    const summary = try renderSummary(arena, snap);
    const timeline = try renderTimeline(arena, snap, tz);
    const outages = try renderOutageTeaser(arena, snap, tz);
    const generated = try wrapGenerated(arena, try renderGenerated(arena, now, tz, refresh_s));
    const tabs = try renderTabs(arena, "/", snap.window);

    return std.fmt.allocPrint(arena, shell_tpl, .{
        windowSpec(snap.window).id, // <body data-init> SSE bootstrap, first {s} in the shell
        hero,
        tabs,
        summary,
        timeline,
        outages,
        generated,
    });
}

/// The `/outages` page: a breadcrumb back to the dashboard, the window
/// tabs and one full page of the outage list.
fn renderArchive(arena: std.mem.Allocator, snap: Snapshot, tz: *const zdt.Timezone) ![]const u8 {
    var head: Io.Writer.Allocating = .init(arena);
    try head.writer.print(
        "<p class=\"back\"><a href=\"/?window={s}\">← Dashboard</a></p>",
        .{windowSpec(snap.window).id},
    );
    return std.fmt.allocPrint(arena, archive_tpl, .{
        head.written(),
        try renderTabs(arena, "/outages", snap.window),
        try renderOutages(arena, snap, tz),
    });
}

/// All live regions as one concatenated SSE payload.
fn snapshotBlocks(
    arena: std.mem.Allocator,
    snap: Snapshot,
    tz: *const zdt.Timezone,
    refresh_s: u32,
    now: zdt.Datetime,
) ![]const u8 {
    const hero = try datastar.patchElements(arena, try renderHero(arena, snap, tz), .{});
    const summary = try datastar.patchElements(arena, try renderSummary(arena, snap), .{});
    const timeline = try datastar.patchElements(arena, try renderTimeline(arena, snap, tz), .{});
    const outages = try datastar.patchElements(arena, try renderOutageTeaser(arena, snap, tz), .{});
    const generated = try datastar.patchElements(
        arena,
        try wrapGenerated(arena, try renderGenerated(arena, now, tz, refresh_s)),
        .{},
    );
    return std.mem.concat(arena, u8, &.{ hero, summary, timeline, outages, generated });
}

/// the SSE patch for the footer must morph a <p id="generated">, so wrap
/// the plain-text fragment in the element the shell ships
fn wrapGenerated(arena: std.mem.Allocator, inner: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena, "<p id=\"generated\">{s}</p>", .{inner});
}

// ---------------------------------------------------------------------------
// HTTP server

const Config = struct {
    log_path: []const u8,
    refresh_ms: u64,
    refresh_s: u32,
    threshold: zdt.Duration,
    tz: *const zdt.Timezone,
};

var active_conns: std.atomic.Value(u32) = .init(0);

pub fn main(init: std.process.Init) !void {
    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    const desc =
        \\This program serves a read-only web dashboard over an uptime log
        \\written by `uptime-monitor`: current status, uptime percentage for
        \\the last 24 hours / 7 days / 30 days, a timeline and an outage
        \\list. The page updates live in the browser via Server-Sent Events.
        \\
        \\The log is never written to; keep `uptime-monitor` running on its
        \\timer as usual and point this server at the same log file.
        \\
        \\
    ;

    const params = comptime clap.parseParamsComptime(
        \\-h, --help                      Display this help and exit.
        \\-a, --address <str>             Address to bind (default: 0.0.0.0).
        \\-p, --port <u16>                Port to listen on (default: 8080).
        \\    --refresh <u32>             Seconds between live updates (default: 30).
        \\    --threshold <f32>           Minutes a state is trusted after its last event (default: 35).
        \\    --tz <str>                  Display timezone, IANA name or `localtime` (default: localtime).
        \\<str>                           Path to the uptime log file.
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
        var stderr_buffer: [1024]u8 = undefined;
        var stderr_writer = std.Io.File.stderr().writer(init.io, &stderr_buffer);
        const stderr = &stderr_writer.interface;
        try stderr.writeAll("error: Missing log file path argument.\nUsage:");
        try clap.usage(stderr, clap.Help, &params);
        try stderr.writeAll("\n");
        try stderr.flush();
        return error.MissingLogFile;
    };

    const address = res.args.address orelse default_address;
    const port = res.args.port orelse default_port;
    const refresh = res.args.refresh orelse default_refresh_s;
    const threshold_min = res.args.threshold orelse default_threshold_min;
    const tz_name = res.args.tz orelse default_tz;

    if (refresh == 0) {
        std.debug.print("error: Invalid refresh value: {d}\n", .{refresh});
        return error.InvalidArgumentValue;
    }

    const threshold_sec = @round(threshold_min * 60);
    if (!std.math.isFinite(threshold_min) or threshold_min <= 0 or
        threshold_sec >= @as(f32, @floatFromInt(std.math.maxInt(i96))))
    {
        std.debug.print("error: Invalid threshold value: {d}\n", .{threshold_min});
        return error.InvalidArgumentValue;
    }

    // fail early and clearly on a bad --address, before listening
    const addr = Io.net.IpAddress.parse(address, port) catch {
        std.debug.print("error: Error parsing `--address` argument. An IP address is expected.\n", .{});
        return error.ParseError;
    };

    // fixed-size rules, no allocation and no deinit needed
    const tz: zdt.Timezone = zdt.Timezone.fromTzdata(init.io, tz_name, null) catch blk: {
        std.debug.print("warning: Timezone `{s}` not available, falling back to UTC\n", .{tz_name});
        break :blk zdt.Timezone.UTC;
    };

    const cfg = Config{
        .log_path = log_path,
        .refresh_ms = @as(u64, refresh) * std.time.ms_per_s,
        .refresh_s = refresh,
        .threshold = try zdt.Duration.fromTimespanMultiple(
            @intFromFloat(threshold_sec),
            .second,
        ),
        .tz = &tz,
    };

    var listener = try addr.listen(init.io, .{ .reuse_address = true });
    defer listener.deinit(init.io);

    var group: Io.Group = .init;
    defer group.cancel(init.io);

    try stdout.print(
        "uptime-dashboard serving on {f} (log: {s}, refresh: {d}s, tz: {s})\n",
        .{ addr, log_path, refresh, tz_name },
    );
    try stdout.flush();

    while (true) {
        const conn = listener.accept(init.io) catch |err| {
            std.debug.print("error: accept error: {s}\n", .{@errorName(err)});
            continue;
        };
        const n = active_conns.fetchAdd(1, .acq_rel) + 1;
        const refused = n > max_connections;
        group.concurrent(init.io, handleConnection, .{
            init.io, init.gpa, &cfg, conn, refused,
        }) catch |err| {
            _ = active_conns.fetchSub(1, .acq_rel);
            std.debug.print("error: spawn handler error: {s}\n", .{@errorName(err)});
            conn.close(init.io);
        };
    }
}

fn handleConnection(
    io: Io,
    allocator: std.mem.Allocator,
    cfg: *const Config,
    conn: Io.net.Stream,
    refused: bool,
) Io.Cancelable!void {
    defer _ = active_conns.fetchSub(1, .acq_rel);
    defer conn.close(io);

    var read_buffer: [4096]u8 = undefined;
    var write_buffer: [4096]u8 = undefined;
    var reader = conn.reader(io, &read_buffer);
    var writer = conn.writer(io, &write_buffer);

    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();

    while (true) {
        defer _ = arena.reset(.retain_capacity);

        var server = std.http.Server.init(&reader.interface, &writer.interface);
        var request = server.receiveHead() catch break;

        if (refused) {
            request.respond("too many connections", .{ .status = .service_unavailable }) catch {};
            return;
        }

        handleRequest(io, allocator, arena.allocator(), cfg, &request) catch |err| {
            std.debug.print("error: handler error: {s}\n", .{@errorName(err)});
            request.respond("internal error", .{ .status = .internal_server_error }) catch {};
            break;
        };
    }
}

fn handleRequest(
    io: Io,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    cfg: *const Config,
    request: *std.http.Server.Request,
) !void {
    if (request.head.method != .GET) {
        // close rather than drain: a body-carrying method without framing
        // headers cannot be safely skipped for a next request on this pipe
        return request.respond("method not allowed", .{
            .status = .method_not_allowed,
            .keep_alive = false,
            .extra_headers = &.{.{ .name = "allow", .value = "GET" }},
        });
    }

    const target = request.head.target;
    const q_idx = std.mem.indexOfScalar(u8, target, '?');
    const path = if (q_idx) |i| target[0..i] else target;
    const query = if (q_idx) |i| target[i + 1 ..] else "";

    if (std.mem.eql(u8, path, "/")) {
        const view = viewFromQuery(query) catch |e| return badQuery(request, e);
        const now = zdt.Datetime.nowUTC(io);
        const snap = buildSnapshot(io, arena, cfg.log_path, view, cfg.threshold, now);
        const body = try renderPage(arena, snap, cfg.tz, cfg.refresh_s, now);
        return request.respond(body, .{
            .extra_headers = &.{.{ .name = "content-type", .value = "text/html; charset=UTF-8" }},
        });
    }

    if (std.mem.eql(u8, path, "/outages")) {
        const view = viewFromQuery(query) catch |e| return badQuery(request, e);
        const now = zdt.Datetime.nowUTC(io);
        const snap = buildSnapshot(io, arena, cfg.log_path, view, cfg.threshold, now);
        const body = try renderArchive(arena, snap, cfg.tz);
        return request.respond(body, .{
            .extra_headers = &.{.{ .name = "content-type", .value = "text/html; charset=UTF-8" }},
        });
    }

    if (std.mem.eql(u8, path, "/events")) {
        const view = viewFromQuery(query) catch |e| return badQuery(request, e);
        return handleEvents(io, gpa, cfg, request, view);
    }

    if (std.mem.eql(u8, path, "/style.css")) {
        return request.respond(style_css, .{
            .extra_headers = &.{.{ .name = "content-type", .value = "text/css; charset=UTF-8" }},
        });
    }

    if (std.mem.eql(u8, path, "/datastar.js")) {
        return request.respond(datastar_js, .{
            .extra_headers = &.{
                .{ .name = "content-type", .value = "text/javascript; charset=UTF-8" },
            },
        });
    }

    return request.respond("not found", .{ .status = .not_found });
}

/// The query parameters that pick what a page renders: `window` (default
/// when absent, error when unknown) and `before`, the outage-list cursor.
const View = struct {
    window: Window = .h24,
    before: ?zdt.Datetime = null,
};

fn viewFromQuery(query: []const u8) !View {
    var view: View = .{};
    var it = std.mem.splitScalar(u8, query, '&');
    while (it.next()) |pair| {
        if (std.mem.startsWith(u8, pair, "window=")) {
            view.window = windowFromId(pair["window=".len..]) orelse
                return error.UnknownWindow;
        } else if (std.mem.startsWith(u8, pair, "before=")) {
            const ts = zdt.Datetime.fromISO8601(pair["before=".len..]) catch
                return error.BadCursor;
            // normalize to UTC so the cursor survives the URL round-trip
            view.before = utcOf(ts);
        }
    }
    return view;
}

fn badQuery(request: *std.http.Server.Request, err: anyerror) !void {
    const msg = switch (err) {
        error.UnknownWindow => "unknown window",
        error.BadCursor => "invalid `before` value",
        else => "invalid query",
    };
    return request.respond(msg, .{ .status = .bad_request });
}

fn handleEvents(
    io: Io,
    gpa: std.mem.Allocator,
    cfg: *const Config,
    request: *std.http.Server.Request,
    view: View,
) !void {
    var body_buffer: [4096]u8 = undefined;
    var body = try request.respondStreaming(&body_buffer, .{
        .respond_options = .{
            .extra_headers = &.{
                .{ .name = "content-type", .value = "text/event-stream; charset=UTF-8" },
                .{ .name = "cache-control", .value = "no-cache" },
            },
        },
    });
    // push the headers before the first (possibly slow) tick
    try body.flush();

    var tick: std.heap.ArenaAllocator = .init(gpa);
    defer tick.deinit();

    while (true) {
        defer _ = tick.reset(.retain_capacity);

        const now = zdt.Datetime.nowUTC(io);
        const snap = buildSnapshot(io, tick.allocator(), cfg.log_path, view, cfg.threshold, now);
        const block = try snapshotBlocks(tick.allocator(), snap, cfg.tz, cfg.refresh_s, now);

        body.writer.writeAll(block) catch return;
        body.writer.flush() catch return;
        body.flush() catch return;

        // sleep until the next tick, emitting a keepalive comment so
        // intermediaries and the browser do not drop the stream
        var slept: u64 = 0;
        while (slept < cfg.refresh_ms) {
            const step = @min(keepalive_ms, cfg.refresh_ms - slept);
            io.sleep(.fromMilliseconds(step), .real) catch return;
            slept += step;
            if (slept < cfg.refresh_ms) {
                body.writer.writeAll(": keepalive\n\n") catch return;
                body.writer.flush() catch return;
                body.flush() catch return;
            }
        }
    }
}

// ---------------------------------------------------------------------------
// tests

const testing = std.testing;

fn dt(iso: []const u8) zdt.Datetime {
    return zdt.Datetime.fromISO8601(iso) catch unreachable;
}

test "windowFromId: known and unknown ids" {
    try testing.expectEqual(Window.h24, windowFromId("24h").?);
    try testing.expectEqual(Window.d7, windowFromId("7d").?);
    try testing.expectEqual(Window.d30, windowFromId("30d").?);
    try testing.expect(windowFromId("1h") == null);
    try testing.expect(windowFromId("") == null);
    try testing.expect(windowFromId("24H") == null);
}

test "viewFromQuery: defaults, window and cursor parsing" {
    var view = try viewFromQuery("");
    try testing.expect(view.window == .h24);
    try testing.expect(view.before == null);

    view = try viewFromQuery("window=7d");
    try testing.expect(view.window == .d7);
    try testing.expect(view.before == null);

    view = try viewFromQuery("a=1&window=30d&before=2026-09-24T01:00:00Z");
    try testing.expect(view.window == .d30);
    try testing.expect(view.before != null);

    try testing.expectError(error.UnknownWindow, viewFromQuery("window=99d"));
    try testing.expectError(error.BadCursor, viewFromQuery("before=yesterday"));
}

test "writeDuration: human scales" {
    const cases = [_]struct { secs: i64, want: []const u8 }{
        .{ .secs = 45, .want = "45s" },
        .{ .secs = 750, .want = "12m 30s" },
        .{ .secs = 7500, .want = "2h 5m" },
        .{ .secs = 276_480, .want = "3d 4h" },
    };
    for (cases) |c| {
        var buf: Io.Writer.Allocating = .init(testing.allocator);
        defer buf.deinit();
        try writeDuration(&buf.writer, durSecs(c.secs));
        try testing.expectEqualStrings(c.want, buf.written());
    }
}

fn testArena(backing: std.mem.Allocator) std.heap.ArenaAllocator {
    return .init(backing);
}

test "renderHero: up, down, stale and error variants" {
    var arena_state = testArena(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var snap = Snapshot{
        .ok = true,
        .state = .up,
        .since = dt("2026-09-24T10:00:00Z"),
        .since_dur = durSecs(7200),
        .window = .h24,
        .ws = dt("2026-09-24T00:00:00Z"),
        .we = dt("2026-09-25T00:00:00Z"),
    };

    {
        const html = try renderHero(arena, snap, &zdt.Timezone.UTC);
        try testing.expect(std.mem.indexOf(u8, html, "class=\"hero up\"") != null);
        try testing.expect(std.mem.indexOf(u8, html, "stale") == null);
    }
    {
        snap.state = .down;
        snap.stale = true;
        const html = try renderHero(arena, snap, &zdt.Timezone.UTC);
        try testing.expect(std.mem.indexOf(u8, html, "class=\"hero down\"") != null);
        try testing.expect(std.mem.indexOf(u8, html, "stale-badge") != null);
    }
    {
        const err = errSnapshot(.h24, snap.ws, snap.we, "boom");
        const html = try renderHero(arena, err, &zdt.Timezone.UTC);
        try testing.expect(std.mem.indexOf(u8, html, "hero unknown") != null);
        try testing.expect(std.mem.indexOf(u8, html, "boom") != null);
    }
}

test "renderTimeline: segment geometry and error variant" {
    var arena_state = testArena(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const ws = dt("2026-09-24T00:00:00Z");
    const we = dt("2026-09-25T00:00:00Z");

    // one hour of downtime, one hour into a 24h window: a svg_width/24-wide
    // slice, clamped the same way the renderer clamps short outages
    const slice = svg_width / 24.0;
    const want_w = @max(slice, min_down_width);
    const want_x = @min(slice, svg_width - want_w);
    const want_x_str = try std.fmt.allocPrint(arena, "x=\"{d:.2}\"", .{want_x});
    const want_w_str = try std.fmt.allocPrint(arena, "width=\"{d:.2}\"", .{want_w});
    const snap = Snapshot{
        .ok = true,
        .window = .h24,
        .ws = ws,
        .we = we,
        .segs = &.{
            .{ .state = .up, .start = ws, .end = dt("2026-09-24T01:00:00Z") },
            .{ .state = .down, .start = dt("2026-09-24T01:00:00Z"), .end = dt("2026-09-24T02:00:00Z") },
            .{ .state = .up, .start = dt("2026-09-24T02:00:00Z"), .end = we },
        },
    };
    const html = try renderTimeline(arena, snap, &zdt.Timezone.UTC);
    try testing.expect(std.mem.indexOf(u8, html, want_x_str) != null);
    try testing.expect(std.mem.indexOf(u8, html, want_w_str) != null);
    try testing.expect(std.mem.indexOf(u8, html, "seg-down") != null);
    try testing.expect(std.mem.indexOf(u8, html, "Last 24 hours") != null);

    const err = errSnapshot(.h24, ws, we, "nope");
    const html2 = try renderTimeline(arena, err, &zdt.Timezone.UTC);
    try testing.expect(std.mem.indexOf(u8, html2, "nope") != null);
}

/// one full archive page plus the teaser overhang: hourly outages starting
/// at `ws`, chronological; the newest ongoing
fn fillTestOutages(rows: []uptime.Outage, ws: zdt.Datetime) void {
    for (rows, 0..) |*row, i| {
        const start = ws.add(durSecs(@intCast(i * 3600))) catch unreachable;
        row.* = .{
            .start = start,
            .end = if (i == rows.len - 1) null else start.add(durSecs(300)) catch unreachable,
            .dur = durSecs(300),
        };
    }
}

test "renderOutageTeaser: newest rows capped, link to the archive" {
    var arena_state = testArena(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const ws = dt("2026-09-24T00:00:00Z");
    var rows_buf: [outage_page_size + outage_teaser_rows]uptime.Outage = undefined;
    fillTestOutages(&rows_buf, ws);

    const we = dt("2026-09-25T00:00:00Z");
    const snap = Snapshot{
        .ok = true,
        .window = .h24,
        .ws = ws,
        .we = we,
        .result = zero_result,
        .outage_rows = &rows_buf,
    };
    const html = try renderOutageTeaser(arena, snap, &zdt.Timezone.UTC);
    try testing.expectEqual(outage_teaser_rows, std.mem.count(u8, html, "<tr><td>"));
    try testing.expect(std.mem.indexOf(u8, html, "All outages →") != null);
    try testing.expect(std.mem.indexOf(u8, html, "href=\"/outages?window=24h\"") != null);
    try testing.expect(std.mem.indexOf(u8, html, "pager") == null);

    // exactly one teaser's worth of outages: everything shown, no archive link
    const few = Snapshot{
        .ok = true,
        .window = .h24,
        .ws = ws,
        .we = we,
        .result = zero_result,
        .outage_rows = rows_buf[0..outage_teaser_rows],
    };
    const html2 = try renderOutageTeaser(arena, few, &zdt.Timezone.UTC);
    try testing.expectEqual(outage_teaser_rows, std.mem.count(u8, html2, "<tr><td>"));
    try testing.expect(std.mem.indexOf(u8, html2, "All outages") == null);
}

test "renderArchive: breadcrumb, tabs and one full page wired" {
    var arena_state = testArena(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const ws = dt("2026-09-24T00:00:00Z");
    var rows_buf: [outage_page_size + outage_teaser_rows]uptime.Outage = undefined;
    fillTestOutages(&rows_buf, ws);

    const snap = Snapshot{
        .ok = true,
        .window = .d7,
        .ws = ws,
        .we = dt("2026-09-25T00:00:00Z"),
        .result = zero_result,
        .outage_rows = &rows_buf,
    };
    const html = try renderArchive(arena, snap, &zdt.Timezone.UTC);

    try testing.expect(
        std.mem.indexOf(u8, html, "<p class=\"back\"><a href=\"/?window=7d\">← Dashboard</a></p>") != null,
    );
    try testing.expect(std.mem.indexOf(u8, html, "href=\"/outages?window=7d\"") != null);
    try testing.expectEqual(outage_page_size, std.mem.count(u8, html, "<tr><td>"));
    try testing.expect(std.mem.indexOf(u8, html, "Older →") != null);
}

test "renderOutages: cursor paging, ongoing row and empty states" {
    var arena_state = testArena(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const we = dt("2026-09-25T00:00:00Z");
    const ws = dt("2026-09-24T00:00:00Z");

    var rows_buf: [outage_page_size + outage_teaser_rows]uptime.Outage = undefined;
    fillTestOutages(&rows_buf, ws);

    var snap = Snapshot{
        .ok = true,
        .window = .h24,
        .ws = ws,
        .we = we,
        .result = zero_result,
        .outage_rows = &rows_buf,
    };

    {
        // newest page: the outage_page_size newest rows, Older link, no Newer
        const html = try renderOutages(arena, snap, &zdt.Timezone.UTC);
        try testing.expect(std.mem.indexOf(u8, html, "still down") != null);
        try testing.expect(std.mem.indexOf(u8, html, "Older →") != null);
        try testing.expect(std.mem.indexOf(u8, html, "href=\"/outages?window=24h&before=") != null);
        try testing.expect(std.mem.indexOf(u8, html, "Newer") == null);
        // cursors must be URL-safe UTC ISO, never `+hh:mm` offsets
        try testing.expect(std.mem.indexOf(u8, html, "+") == null);
    }
    {
        // cursor one full page up: exactly that page remains, Older gone, Newer back
        snap.before = rows_buf[outage_page_size].start;
        const html = try renderOutages(arena, snap, &zdt.Timezone.UTC);
        try testing.expect(std.mem.indexOf(u8, html, "Older →") == null);
        try testing.expect(std.mem.indexOf(u8, html, "Newer") != null);
        try testing.expect(std.mem.indexOf(u8, html, "still down") == null);
    }
    {
        // cursor older than every row: empty page, Newer remains
        snap.before = ws;
        const html = try renderOutages(arena, snap, &zdt.Timezone.UTC);
        try testing.expect(std.mem.indexOf(u8, html, "No outages before this point") != null);
        try testing.expect(std.mem.indexOf(u8, html, "Newer") != null);
    }

    const empty = Snapshot{
        .ok = true,
        .window = .h24,
        .ws = we,
        .we = we,
        .result = zero_result,
    };
    const html2 = try renderOutages(arena, empty, &zdt.Timezone.UTC);
    try testing.expect(std.mem.indexOf(u8, html2, "No downtime recorded") != null);
}

// Results for renderers: fully defined, zeroed durations
const zero_result: uptime.Result = .{
    .window_start = dt("2026-09-24T00:00:00Z"),
    .window_end = dt("2026-09-25T00:00:00Z"),
    .up_time = .{},
    .down_time = .{},
    .observed_time = .{},
    .lost_time = .{},
    .window_length = .{},
    .outage_count = 0,
};

test "snapshotBlocks: five datastar patch events concatenated" {
    var arena_state = testArena(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const snap = Snapshot{
        .ok = true,
        .window = .h24,
        .ws = dt("2026-09-24T00:00:00Z"),
        .we = dt("2026-09-25T00:00:00Z"),
        .result = zero_result,
    };
    const blocks = try snapshotBlocks(arena, snap, &zdt.Timezone.UTC, 30, dt("2026-09-25T00:00:00Z"));

    const n = std.mem.count(u8, blocks, "event: datastar-patch-elements");
    try testing.expectEqual(@as(usize, 5), n);
    try testing.expect(std.mem.indexOf(u8, blocks, "id=\"hero\"") != null);
    try testing.expect(std.mem.indexOf(u8, blocks, "id=\"generated\"") != null);
}

test "renderPage: shell wires fragments, tabs and the SSE bootstrap" {
    var arena_state = testArena(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const snap = Snapshot{
        .ok = true,
        .window = .d7,
        .ws = dt("2026-09-18T00:00:00Z"),
        .we = dt("2026-09-25T00:00:00Z"),
        .result = zero_result,
    };
    const html = try renderPage(arena, snap, &zdt.Timezone.UTC, 30, dt("2026-09-25T00:00:00Z"));

    try testing.expect(std.mem.indexOf(u8, html, "class=\"active\"") != null);
    // guards the placeholder order: the body bootstrap must stay intact
    try testing.expect(std.mem.indexOf(u8, html, "<body data-init=\"@get('/events?window=7d', {openWhenHidden: true})\">") != null);
    try testing.expect(std.mem.indexOf(u8, html, "<div id=\"hero\"") != null);
    try testing.expect(std.mem.indexOf(u8, html, "Last 7 days") != null);
}
