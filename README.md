# Tool for internet uptime monitoring

Simple solution to track internet uptime based on a readable log file. This
repository provides a library and three cli applications.

  - `uptime` is the name of the module you can import from your own zig project
  - `uptime-monitor` is the main application. It's intended to be invoked
  periodically by some kind of system timer (e.g. systemd).
  - `uptime-parser` is an application that parses the generated logfile and
  obtains the total uptime percent in a specific time window.
  - `uptime-dashboard` is a read-only web dashboard over the same logfile,
  to easily check stats. The page updates live in the browser via Server-Sent
  Events ([Datastar]).

Build everything with `zig build`. The latest stable zig (0.16.0 at the time of
writing) is required.

To add the library to your zig project, run the following command from the
project directory:

```
zig fetch --save https://github.com/acrilique/uptime/archive/refs/tags/<VERSION>.tar.gz
```

Where `<VERSION>` corresponds to a git tag (e.g. `v0.1.0`).

## Deployment

Both `uptime-monitor` and `uptime-dashboard` are meant to run on the same
host, pointed at the same log file:

- `uptime-monitor <log>` on a systemd timer or cron
- `uptime-dashboard <log> [--address 0.0.0.0] [--port 8080] [--refresh 30]
  [--tz localtime]` as a long-running service

The dashboard is read-only by construction and is intended for a trusted home LAN.

[Datastar]: https://data-star.dev
