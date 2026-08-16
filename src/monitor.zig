const std = @import("std");
const clap = @import("clap");
const zdt = @import("zdt");
const logfile = @import("logfile");

pub fn main(init: std.process.Init) !void {
    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer =
        std.Io.File.stdout().writer(init.io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    const desc =
        \\This program monitors the internet connection by querying a DNS
        \\server (e.g. from cron every minute) and appending state changes to
        \\a log file (e.g.:
        \\        2026-07-24T23:58:34Z MONITOR STARTED
        \\        2026-07-25T00:15:31Z DOWN
        \\        2026-07-25T00:16:06Z UP
        \\).
        \\
        \\On each run, the current state is compared against the last logged
        \\one: a UP/DOWN line is appended on a transition, and a HEARTBEAT line
        \\whenever the last one is older than `--heartbeat-interval` seconds.
        \\A failed probe is retried `--num-retries` times before it counts as
        \\downtime. The log can then be analyzed with `uptime-parser`.
        \\
        \\
    ;

    const params = comptime clap.parseParamsComptime(
        \\-h, --help                      Display this help and exit.
        \\-t, --target <str>              DNS server to query (default: 8.8.8.8).
        \\    --timeout <u32>             Seconds to wait for a DNS reply (default: 2).
        \\    --num-retries <u32>         Failed probe retries before reporting DOWN (default: 0).
        \\    --heartbeat-interval <u32>  Seconds between heartbeat log entries (default: 1800).
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
        std.log.err("Missing log file path argument.\nUsage:", .{});
        var stderr_buffer: [1024]u8 = undefined;
        var stderr_writer =
            std.Io.File.stderr().writer(init.io, &stderr_buffer);
        const stderr = &stderr_writer.interface;
        try clap.usage(stderr, clap.Help, &params);
        try stderr.writeAll("\n");
        try stderr.flush();
        return error.MissingLogFile;
    };

    const target = res.args.target orelse "8.8.8.8";
    const timeout = res.args.timeout orelse 2;
    const num_retries = res.args.@"num-retries" orelse 0;
    const heartbeat_interval = res.args.@"heartbeat-interval" orelse 1800;

    if (timeout == 0) {
        std.log.err("Invalid timeout value: {d}", .{timeout});
        return error.InvalidArgumentValue;
    }

    // fail early and clearly on a bad --target, before touching the log
    _ = std.Io.net.Ip4Address.parse(target, 53) catch {
        std.log.err("Error parsing `--target` argument. An IPv4 address is expected.", .{});
        return error.ParseError;
    };

    if (std.fs.path.dirname(log_path)) |dir|
        try std.Io.Dir.cwd().createDirPath(init.io, dir);

    const new_log = (if (std.fs.path.isAbsolute(log_path))
        std.Io.Dir.createFileAbsolute(
            init.io,
            log_path,
            .{ .exclusive = true },
        )
    else
        std.Io.Dir.cwd().createFile(
            init.io,
            log_path,
            .{ .exclusive = true },
        )) catch |err| switch (err) {
        error.PathAlreadyExists => null,
        else => return err,
    };

    if (new_log) |f| {
        defer f.close(init.io);
        var line_buf: [64]u8 = undefined;
        const line = try logfile.formatLine(
            &line_buf,
            zdt.Datetime.nowUTC(init.io),
            "MONITOR STARTED",
        );
        try f.writePositionalAll(init.io, line, 0);
    }

    const log = if (std.fs.path.isAbsolute(log_path))
        try std.Io.Dir.openFileAbsolute(
            init.io,
            log_path,
            .{ .mode = .read_write, .lock = .exclusive },
        )
    else
        try std.Io.Dir.cwd().openFile(
            init.io,
            log_path,
            .{ .mode = .read_write, .lock = .exclusive },
        );
    defer log.close(init.io);

    // only the tail of the log is needed to find the last known state
    const tail_size = 4096;
    var tail_buf: [tail_size]u8 = undefined;
    const log_len = try log.length(init.io);
    const tail_len: u64 = @min(log_len, tail_buf.len);
    _ = try log.readPositionalAll(
        init.io,
        tail_buf[0..@intCast(tail_len)],
        log_len - tail_len,
    );

    var tail = tail_buf[0..@intCast(tail_len)];
    if (log_len > tail_buf.len) {
        // the tail starts mid-line; that first line is partial and must not
        // be parsed (a cut inside a state token would be misread or dropped)
        if (std.mem.indexOfScalar(u8, tail, '\n')) |first_nl| {
            tail = tail[first_nl + 1 ..];
        } else {
            tail = tail[tail.len..]; // no newline: the whole tail is one partial line
        }
    }

    const known = logfile.lastKnown(tail);
    if (known.naive) {
        std.log.err(
            "The log '{s}' contains naive timestamps (no UTC offset), but the monitor logs aware ones (e.g. 2026-08-01T10:00:00Z); mixing the two makes the log unanalyzable. Fix the timestamps or move the log away and let the monitor start a fresh one.",
            .{log_path},
        );
        return error.NaiveLogFile;
    }
    const last_state = known.state orelse true; // no state logged yet: assume UP

    const current_state: bool = try dnsProbeWithRetries(
        init.io,
        target,
        timeout,
        num_retries,
    );
    const now = zdt.Datetime.nowUTC(init.io);

    var pos = log_len;
    if (current_state != last_state) {
        var line_buf: [64]u8 = undefined;
        const line = try logfile.formatLine(
            &line_buf,
            now,
            if (current_state) "UP" else "DOWN",
        );
        try log.writePositionalAll(init.io, line, pos);
        pos += line.len;
    }

    if (known.heartbeat == null or
        (now.diff(known.heartbeat.?).asSeconds() >= heartbeat_interval))
    {
        var line_buf: [64]u8 = undefined;
        const line = try logfile.formatLine(
            &line_buf,
            now,
            if (current_state) "HEARTBEAT UP" else "HEARTBEAT DOWN",
        );
        try log.writePositionalAll(init.io, line, pos);
    }
}

/// Retries a failed probe `retries` times before giving up, so a single
/// lost reply doesn't get logged as downtime
fn dnsProbeWithRetries(
    io: std.Io,
    host: []const u8,
    timeout_s: u32,
    retries: u32,
) !bool {
    var remaining = retries;
    while (true) {
        if (try dnsProbe(io, host, timeout_s)) return true;
        if (remaining == 0) return false;
        remaining -= 1;
    }
}

/// Sends a DNS query to `host` and waits up to `timeout_s` seconds for a
/// reply from the same server whose DNS id matches the query.
fn dnsProbe(io: std.Io, host: []const u8, timeout_s: u32) !bool {
    const any: std.Io.net.IpAddress =
        .{ .ip4 = try std.Io.net.Ip4Address.parse("0.0.0.0", 0) };
    const dest: std.Io.net.IpAddress =
        .{ .ip4 = try std.Io.net.Ip4Address.parse(host, 53) };

    const sock = try std.Io.net.IpAddress.bind(
        &any,
        io,
        .{ .mode = .dgram, .protocol = .udp },
    );
    defer sock.close(io);

    const query = [_]u8{
        0x12, 0x34, // id
        0x01, 0x00, // flags: recursion desired
        0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // one question
        0x03, 'c', 'o', 'm', 0x00, // qname: com
        0x00, 0x01, // qtype: A
        0x00, 0x01, // qclass: IN
    };
    sock.send(io, &dest, &query) catch return false;

    const timeout: std.Io.Timeout = .{
        .duration = .{
            .raw = std.Io.Duration.fromSeconds(timeout_s),
            .clock = .awake,
        },
    };
    const deadline = timeout.toDeadline(io);

    var buf: [512]u8 = undefined;
    while (true) {
        const msg = sock.receiveTimeout(
            io,
            &buf,
            deadline,
        ) catch |err|
            switch (err) {
                error.Timeout => return false,
                else => return err,
            };
        if (msg.from.eql(&dest) and
            msg.data.len >= 2 and
            std.mem.eql(u8, msg.data[0..2], query[0..2])) return true;
    }
}
