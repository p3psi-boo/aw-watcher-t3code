const std = @import("std");
const config = @import("config.zig");
const source = @import("t3code.zig");
const activitywatch = @import("activitywatch.zig");
const notify = @import("notify.zig");
const service = @import("service.zig");
const Config = config.Config;
const version = "0.1.0";
var running: std.atomic.Value(bool) = .init(true);

fn stop(_: std.posix.SIG) callconv(.c) void {
    running.store(false, .monotonic);
}

fn run(allocator: std.mem.Allocator, io: std.Io, c: Config) !void {
    var writer = activitywatch.Writer.init(allocator, io, c);
    defer writer.deinit();
    var watcher = try notify.Watcher.init(allocator, c.base_dir);
    defer watcher.deinit();
    var last_sample: i64 = 0;
    while (running.load(.monotonic)) {
        const awake_ms = std.Io.Clock.awake.now(io).toMilliseconds();
        const sample_interval: i64 = @intCast(c.heartbeat_ms);
        if (awake_ms - last_sample < sample_interval) try std.Io.sleep(io, .fromMilliseconds(sample_interval - (awake_ms - last_sample)), .awake);
        if (!running.load(.monotonic)) break;
        last_sample = std.Io.Clock.awake.now(io).toMilliseconds();
        {
            var arena = std.heap.ArenaAllocator.init(allocator);
            defer arena.deinit();
            const data = source.readSnapshot(arena.allocator(), io, c, std.Io.Clock.real.now(io).toMilliseconds()) catch |err| blk: {
                if (c.verbose) std.log.warn("snapshot skipped: {s}", .{@errorName(err)});
                break :blk null;
            };
            if (data) |snapshot| {
                const json = try std.json.Stringify.valueAlloc(arena.allocator(), snapshot, .{});
                writer.emit(json, std.Io.Clock.real.now(io).toMilliseconds()) catch |err| {
                    std.log.warn("ActivityWatch delivery failed: {s}", .{@errorName(err)});
                };
            } else writer.pause();
        }
        try watcher.wait(@intCast(@min(c.heartbeat_ms, 1000)));
    }
}

fn doctor(allocator: std.mem.Allocator, io: std.Io, c: Config) !void {
    var failed = false;
    const stdout = std.Io.File.stdout();
    if (std.Io.Dir.cwd().openDir(io, c.base_dir, .{})) |dir| {
        dir.close(io);
        try stdout.writeStreamingAll(io, "PASS userdata dir\n");
    } else |err| {
        failed = true;
        try stdout.writeStreamingAll(io, try std.fmt.allocPrint(allocator, "FAIL userdata dir: {s}\n", .{@errorName(err)}));
    }
    const alive = source.processAlive(allocator, io, c.base_dir) catch false;
    try stdout.writeStreamingAll(io, if (alive) "PASS t3code server process\n" else "FAIL t3code server process: not running or runtime file invalid\n");
    if (!alive) failed = true;
    if (source.checkDatabase(allocator, io, c.base_dir)) |count| {
        try stdout.writeStreamingAll(io, try std.fmt.allocPrint(allocator, "PASS statev2.sqlite read-only query ({d} eligible threads)\n", .{count}));
    } else |err| {
        failed = true;
        try stdout.writeStreamingAll(io, try std.fmt.allocPrint(allocator, "FAIL statev2.sqlite read-only query: {s}\n", .{@errorName(err)}));
    }
    if (activitywatch.Writer.check(allocator, io, c)) |_| {
        try stdout.writeStreamingAll(io, "PASS ActivityWatch server\n");
    } else |err| {
        failed = true;
        try stdout.writeStreamingAll(io, try std.fmt.allocPrint(allocator, "FAIL ActivityWatch server: {s}\n", .{@errorName(err)}));
    }
    if (source.readSnapshot(allocator, io, c, std.Io.Clock.real.now(io).toMilliseconds())) |snapshot| {
        try stdout.writeStreamingAll(io, try std.fmt.allocPrint(allocator, "Active sessions: {d}\n", .{if (snapshot) |s| s.active_count else @as(usize, 0)}));
    } else |err| {
        failed = true;
        try stdout.writeStreamingAll(io, try std.fmt.allocPrint(allocator, "Active sessions: unavailable ({s})\n", .{@errorName(err)}));
    }
    if (failed) return error.DoctorFailed;
}

fn execute(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    const command = if (args.len > 1 and std.mem.eql(u8, args[1], "doctor")) "doctor" else if (args.len > 1 and std.mem.eql(u8, args[1], "service")) "service" else "watch";
    const service_args = if (std.mem.eql(u8, command, "service") and args.len > 2 and !std.mem.startsWith(u8, args[2], "-")) args[2..3] else &.{};
    const options = if (std.mem.eql(u8, command, "doctor")) args[2..] else if (std.mem.eql(u8, command, "service")) args[2 + service_args.len ..] else args[1..];
    if (std.mem.eql(u8, command, "service") and (service_args.len == 0 or !std.mem.eql(u8, service_args[0], "install"))) {
        var c: Config = .{ .base_dir = "", .hostname = "" };
        for (options) |option| {
            if (std.mem.eql(u8, option, "--help") or std.mem.eql(u8, option, "-h")) c.help = true else if (std.mem.eql(u8, option, "--version") or std.mem.eql(u8, option, "-v")) c.version = true else return error.ServiceOptionsOnlySupportedDuringInstall;
        }
        if (c.version) return std.Io.File.stdout().writeStreamingAll(init.io, "aw-watcher-t3code " ++ version ++ "\n");
        const home = init.environ_map.get("HOME") orelse if (c.help or service_args.len == 0) "" else return error.HomeNotSet;
        return service.run(allocator, init.io, service_args, c, "", home, init.environ_map.get("XDG_CONFIG_HOME"));
    }
    const c = try config.parse(allocator, init.io, init.environ_map, options);
    if (c.version) return std.Io.File.stdout().writeStreamingAll(init.io, "aw-watcher-t3code " ++ version ++ "\n");
    if (std.mem.eql(u8, command, "service")) return service.run(allocator, init.io, service_args, c, try std.process.executablePathAlloc(init.io, allocator), init.environ_map.get("HOME").?, init.environ_map.get("XDG_CONFIG_HOME"));
    if (c.help) return std.Io.File.stdout().writeStreamingAll(init.io, config.usage);
    if (std.mem.eql(u8, command, "doctor")) return doctor(allocator, init.io, c);
    if (c.dry_run) {
        const snapshot = try source.readSnapshot(allocator, init.io, c, std.Io.Clock.real.now(init.io).toMilliseconds());
        try std.Io.File.stdout().writeStreamingAll(init.io, try std.json.Stringify.valueAlloc(allocator, snapshot, .{ .whitespace = .indent_2 }));
        return std.Io.File.stdout().writeStreamingAll(init.io, "\n");
    }
    const action: std.posix.Sigaction = .{ .handler = .{ .handler = stop }, .mask = std.posix.sigemptyset(), .flags = 0 };
    std.posix.sigaction(.INT, &action, null);
    std.posix.sigaction(.TERM, &action, null);
    return run(init.gpa, init.io, c);
}

pub fn main(init: std.process.Init) void {
    execute(init) catch |err| {
        std.log.err("{s}", .{@errorName(err)});
        std.process.exit(1);
    };
}

test {
    std.testing.refAllDecls(@import("config.zig"));
    std.testing.refAllDecls(@import("model.zig"));
    std.testing.refAllDecls(source);
    std.testing.refAllDecls(activitywatch);
    std.testing.refAllDecls(notify);
    std.testing.refAllDecls(service);
}
