const std = @import("std");

pub const Config = struct {
    base_dir: []const u8,
    aw_url: []const u8 = "http://127.0.0.1:5600",
    hostname: []const u8,
    heartbeat_ms: u64 = 1000,
    pulse_ms: u64 = 2000,
    focus_ms: u64 = 60000,
    timeout_ms: u64 = 5000,
    dry_run: bool = false,
    verbose: bool = false,
    version: bool = false,
    help: bool = false,
};

pub const usage =
    \\Usage: aw-watcher-t3code [options]
    \\       aw-watcher-t3code doctor [options]
    \\       aw-watcher-t3code service install|uninstall|start|stop|restart|status [options]
    \\
    \\Options:
    \\  --base-dir PATH          T3 userdata directory (T3CODE_DATA_DIR or ~/.t3/userdata)
    \\  --aw-url URL             ActivityWatch URL (default http://127.0.0.1:5600)
    \\  --hostname NAME          Bucket hostname (default system hostname)
    \\  --heartbeat-interval 1s  Sampling and heartbeat interval
    \\  --pulsetime 2s           Merge window, greater than heartbeat interval
    \\  --focus-window 60s       Recent thread visit window (heuristic, not OS focus)
    \\  --timeout 5s             HTTP request deadline
    \\  --dry-run                Print one snapshot without contacting ActivityWatch
    \\  --verbose                Log skipped snapshots and state changes
    \\  --version                Print version
    \\  --help                   Show this help
    \\
;

pub fn parseDuration(raw: []const u8) !u64 {
    var split: usize = 0;
    while (split < raw.len and (std.ascii.isDigit(raw[split]) or raw[split] == '.')) : (split += 1) {}
    if (split == 0) return error.InvalidDuration;
    const multiplier: f64 = if (std.mem.eql(u8, raw[split..], "ms")) 1 else if (std.mem.eql(u8, raw[split..], "s")) 1000 else if (std.mem.eql(u8, raw[split..], "m")) 60000 else if (std.mem.eql(u8, raw[split..], "h")) 3600000 else return error.InvalidDuration;
    const value = (std.fmt.parseFloat(f64, raw[0..split]) catch return error.InvalidDuration) * multiplier;
    if (!std.math.isFinite(value) or value < 1 or value > std.math.maxInt(u32)) return error.InvalidDuration;
    return @intFromFloat(value);
}

pub fn parse(allocator: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, args: []const []const u8) !Config {
    var c: Config = .{ .base_dir = "", .hostname = "" };
    var base_dir = env.get("T3CODE_DATA_DIR");
    var hostname: ?[]const u8 = null;
    var durations: struct { heartbeat_ms: []const u8, pulse_ms: []const u8, focus_ms: []const u8, timeout_ms: []const u8 } = .{
        .heartbeat_ms = env.get("AW_WATCHER_T3CODE_HEARTBEAT_INTERVAL") orelse "1s",
        .pulse_ms = env.get("AW_WATCHER_T3CODE_PULSETIME") orelse "2s",
        .focus_ms = env.get("AW_WATCHER_T3CODE_FOCUS_WINDOW") orelse "60s",
        .timeout_ms = "5s",
    };
    if (env.get("AW_WATCHER_T3CODE_AW_URL")) |v| c.aw_url = v;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--dry-run")) {
            c.dry_run = true;
        } else if (std.mem.eql(u8, arg, "--verbose")) {
            c.verbose = true;
        } else if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-v")) {
            c.version = true;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            c.help = true;
        } else {
            const equals = std.mem.indexOfScalar(u8, arg, '=');
            const key = arg[0 .. equals orelse arg.len];
            const value = if (equals) |e| arg[e + 1 ..] else blk: {
                i += 1;
                if (i >= args.len) return error.MissingOptionValue;
                break :blk args[i];
            };
            if (std.mem.eql(u8, key, "--base-dir")) base_dir = value else if (std.mem.eql(u8, key, "--aw-url")) c.aw_url = value else if (std.mem.eql(u8, key, "--hostname")) hostname = value else if (std.mem.eql(u8, key, "--heartbeat-interval")) durations.heartbeat_ms = value else if (std.mem.eql(u8, key, "--pulsetime")) durations.pulse_ms = value else if (std.mem.eql(u8, key, "--focus-window")) durations.focus_ms = value else if (std.mem.eql(u8, key, "--timeout")) durations.timeout_ms = value else return error.UnknownOption;
        }
    }
    if (c.help or c.version) return c;
    const home = env.get("HOME") orelse return error.HomeNotSet;
    c.base_dir = base_dir orelse try std.fs.path.join(allocator, &.{ home, ".t3", "userdata" });
    if (hostname) |value| {
        c.hostname = value;
    } else {
        var name: [std.posix.HOST_NAME_MAX]u8 = undefined;
        c.hostname = try allocator.dupe(u8, try std.posix.gethostname(&name));
    }
    inline for (.{ "heartbeat_ms", "pulse_ms", "focus_ms", "timeout_ms" }) |field| {
        @field(c, field) = try parseDuration(@field(durations, field));
    }
    if (c.base_dir.len == 0 or c.hostname.len == 0) return error.EmptyOption;
    if (c.pulse_ms <= c.heartbeat_ms) return error.PulsetimeMustExceedHeartbeat;
    const uri = std.Uri.parse(c.aw_url) catch return error.InvalidActivityWatchURL;
    if ((!std.mem.eql(u8, uri.scheme, "http") and !std.mem.eql(u8, uri.scheme, "https")) or uri.host == null or uri.user != null or uri.password != null or uri.query != null or uri.fragment != null) return error.InvalidActivityWatchURL;
    if (std.mem.eql(u8, c.base_dir, "~")) c.base_dir = home else if (std.mem.startsWith(u8, c.base_dir, "~/")) c.base_dir = try std.fs.path.join(allocator, &.{ home, c.base_dir[2..] });
    c.base_dir = try std.fs.path.resolve(allocator, &.{ try std.process.currentPathAlloc(io, allocator), c.base_dir });
    return c;
}

test "duration units and invalid values" {
    try std.testing.expectEqual(1500, try parseDuration("1.5s"));
    try std.testing.expectEqual(60000, try parseDuration("1m"));
    try std.testing.expectError(error.InvalidDuration, parseDuration("0s"));
    try std.testing.expectError(error.InvalidDuration, parseDuration("1"));
    try std.testing.expectError(error.InvalidDuration, parseDuration("-2s"));
}

test "help and version ignore missing home and invalid environment values" {
    const a = std.testing.allocator;
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("AW_WATCHER_T3CODE_HEARTBEAT_INTERVAL", "invalid");
    try env.put("AW_WATCHER_T3CODE_AW_URL", "invalid");
    for ([_][]const u8{ "--help", "-h", "--version", "-v" }, 0..) |flag, i| {
        const c = try parse(a, std.testing.io, &env, &.{flag});
        try std.testing.expect(if (i < 2) c.help else c.version);
    }
    const c = try parse(a, std.testing.io, &env, &.{ "--heartbeat-interval", "invalid", "--help" });
    try std.testing.expect(c.help);
}

test "CLI overrides environment before validating final values" {
    const a = std.testing.allocator;
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("HOME", "/home/test");
    try env.put("T3CODE_DATA_DIR", "");
    try env.put("AW_WATCHER_T3CODE_AW_URL", "invalid");
    try env.put("AW_WATCHER_T3CODE_HEARTBEAT_INTERVAL", "invalid");
    try env.put("AW_WATCHER_T3CODE_PULSETIME", "invalid");
    try env.put("AW_WATCHER_T3CODE_FOCUS_WINDOW", "invalid");
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const c = try parse(arena.allocator(), std.testing.io, &env, &.{
        "--base-dir",           "/data",   "--aw-url",             "http://localhost:5600", "--hostname",  "explicit-host",
        "--heartbeat-interval", "invalid", "--heartbeat-interval", "250ms",                 "--pulsetime", "500ms",
        "--focus-window",       "30s",     "--timeout",            "750ms",
    });
    try std.testing.expectEqualStrings("/data", c.base_dir);
    try std.testing.expectEqualStrings("http://localhost:5600", c.aw_url);
    try std.testing.expectEqualStrings("explicit-host", c.hostname);
    try std.testing.expectEqual(250, c.heartbeat_ms);
    try std.testing.expectEqual(500, c.pulse_ms);
    try std.testing.expectEqual(30000, c.focus_ms);
    try std.testing.expectEqual(750, c.timeout_ms);
    try std.testing.expectError(error.InvalidDuration, parse(arena.allocator(), std.testing.io, &env, &.{ "--hostname", "host" }));
    try std.testing.expectError(error.UnknownOption, parse(a, std.testing.io, &env, &.{"--unknown=value"}));
    try std.testing.expectError(error.MissingOptionValue, parse(a, std.testing.io, &env, &.{"--heartbeat-interval"}));
}
