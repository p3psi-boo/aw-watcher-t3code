const std = @import("std");
const builtin = @import("builtin");
const c = std.c;
const linux = std.os.linux;
extern "c" fn inotify_init1(flags: c_int) c_int;
extern "c" fn inotify_add_watch(fd: c_int, path: [*:0]const u8, mask: u32) c_int;
extern "c" fn inotify_rm_watch(fd: c_int, wd: c_int) c_int;

pub const Watcher = struct {
    allocator: std.mem.Allocator,
    base_path: [:0]u8,
    logs_path: [:0]u8,
    fd: c_int,
    base_watch: c_int = -1,
    logs_watch: c_int = -1,
    file_paths: [4]?[:0]u8 = @splat(null),
    file_watches: [4]c_int = @splat(-1),

    pub fn init(allocator: std.mem.Allocator, base_dir: []const u8) !Watcher {
        const base = try allocator.dupeSentinel(u8, base_dir, 0);
        const logs = std.fmt.allocPrintSentinel(allocator, "{s}/logs", .{std.mem.trimEnd(u8, base_dir, "/")}, 0) catch |err| {
            allocator.free(base);
            return err;
        };
        const fd = if (builtin.os.tag == .linux) inotify_init1(linux.IN.NONBLOCK | linux.IN.CLOEXEC) else c.kqueue();
        if (fd < 0) {
            allocator.free(base);
            allocator.free(logs);
            return error.NotificationUnavailable;
        }
        var self: Watcher = .{ .allocator = allocator, .base_path = base, .logs_path = logs, .fd = fd };
        errdefer self.deinit();
        if (builtin.os.tag != .linux) {
            if (c.fcntl(fd, c.F.SETFD, @as(c_int, c.FD_CLOEXEC)) < 0) return error.NotificationUnavailable;
            for ([_][]const u8{ "statev2.sqlite", "statev2.sqlite-wal", "server-runtime.json", "logs/server.trace.ndjson" }, 0..) |name, index| {
                self.file_paths[index] = try std.fmt.allocPrintSentinel(allocator, "{s}/{s}", .{ std.mem.trimEnd(u8, base_dir, "/"), name }, 0);
            }
        }
        try self.refresh();
        return self;
    }

    pub fn deinit(self: *Watcher) void {
        if (builtin.os.tag != .linux) {
            if (self.base_watch >= 0) _ = c.close(self.base_watch);
            if (self.logs_watch >= 0) _ = c.close(self.logs_watch);
            for (self.file_watches) |watch| if (watch >= 0) {
                _ = c.close(watch);
            };
        }
        _ = c.close(self.fd);
        self.allocator.free(self.base_path);
        self.allocator.free(self.logs_path);
        for (self.file_paths) |path| if (path) |p| self.allocator.free(p);
    }

    fn add(self: *Watcher, path: [:0]const u8) !c_int {
        if (builtin.os.tag == .linux) {
            const wd = inotify_add_watch(self.fd, path.ptr, linux.IN.MODIFY | linux.IN.CREATE | linux.IN.MOVED_TO | linux.IN.MOVED_FROM | linux.IN.DELETE | linux.IN.DELETE_SELF | linux.IN.MOVE_SELF | linux.IN.ONLYDIR);
            if (wd >= 0) return wd;
            return switch (std.c.errno(wd)) {
                .NOENT, .NOTDIR => -1,
                else => error.WatchPathFailed,
            };
        } else {
            const fd = c.open(path.ptr, .{ .EVTONLY = true, .CLOEXEC = true });
            if (fd < 0) return switch (std.c.errno(fd)) {
                .NOENT, .NOTDIR => -1,
                else => error.WatchPathFailed,
            };
            errdefer _ = c.close(fd);
            var event: c.Kevent = .{
                .ident = @intCast(fd),
                .filter = c.EVFILT.VNODE,
                .flags = c.EV.ADD | c.EV.CLEAR,
                .fflags = c.NOTE.WRITE | c.NOTE.EXTEND | c.NOTE.ATTRIB | c.NOTE.RENAME | c.NOTE.DELETE | c.NOTE.REVOKE,
                .data = 0,
                .udata = 0,
            };
            if (c.kevent(self.fd, @ptrCast(&event), 1, @as([*]c.Kevent, undefined), 0, null) < 0) return error.WatchPathFailed;
            return fd;
        }
    }

    fn refresh(self: *Watcher) !void {
        if (self.base_watch < 0) self.base_watch = try self.add(self.base_path);
        if (self.logs_watch < 0) self.logs_watch = try self.add(self.logs_path);
        if (builtin.os.tag != .linux) {
            for (&self.file_watches, self.file_paths) |*watch, path| {
                if (watch.* < 0) watch.* = try self.add(path.?);
            }
        }
    }

    fn invalidate(self: *Watcher, watch: *c_int) void {
        if (watch.* < 0) return;
        if (builtin.os.tag == .linux) {
            _ = inotify_rm_watch(self.fd, watch.*);
        } else {
            _ = c.close(watch.*);
        }
        watch.* = -1;
    }

    pub fn wait(self: *Watcher, timeout_ms: u32) !void {
        try self.refresh();
        if (builtin.os.tag == .linux) {
            var poll_fd: c.pollfd = .{ .fd = self.fd, .events = c.POLL.IN, .revents = 0 };
            const ready = c.poll(@ptrCast(&poll_fd), 1, @intCast(@min(timeout_ms, std.math.maxInt(c_int))));
            if (ready < 0) {
                if (std.c.errno(ready) == .INTR) return;
                return error.NotificationWaitFailed;
            }
            if (ready == 0) return;
            if (poll_fd.revents & (c.POLL.ERR | c.POLL.NVAL) != 0) return error.NotificationWaitFailed;
            var buffer: [8192]u8 align(@alignOf(linux.inotify_event)) = undefined;
            while (true) {
                const count = c.read(self.fd, &buffer, buffer.len);
                if (count < 0) {
                    if (std.c.errno(count) == .AGAIN) break;
                    if (std.c.errno(count) == .INTR) continue;
                    return error.NotificationReadFailed;
                }
                if (count == 0) break;
                var offset: usize = 0;
                while (offset + @sizeOf(linux.inotify_event) <= count) {
                    const event: *const linux.inotify_event = @ptrCast(@alignCast(buffer[offset..].ptr));
                    if (event.mask & (linux.IN.DELETE_SELF | linux.IN.MOVE_SELF | linux.IN.IGNORED) != 0) {
                        if (event.wd == self.base_watch) {
                            self.invalidate(&self.base_watch);
                            self.invalidate(&self.logs_watch);
                        } else if (event.wd == self.logs_watch) self.invalidate(&self.logs_watch);
                    }
                    offset += @sizeOf(linux.inotify_event) + event.len;
                }
            }
        } else {
            var events: [6]c.Kevent = undefined;
            const timeout: c.timespec = .{ .sec = @intCast(timeout_ms / 1000), .nsec = @intCast((timeout_ms % 1000) * 1_000_000) };
            const count = c.kevent(self.fd, @as([*]const c.Kevent, undefined), 0, &events, events.len, &timeout);
            if (count < 0) {
                if (std.c.errno(count) == .INTR) return;
                return error.NotificationWaitFailed;
            }
            for (events[0..@intCast(count)]) |event| {
                if (event.flags & c.EV.ERROR != 0) return error.NotificationReadFailed;
                if (event.fflags & (c.NOTE.RENAME | c.NOTE.DELETE | c.NOTE.REVOKE) != 0) {
                    if (event.ident == self.base_watch) {
                        self.invalidate(&self.base_watch);
                        self.invalidate(&self.logs_watch);
                        for (&self.file_watches) |*watch| self.invalidate(watch);
                    } else if (event.ident == self.logs_watch) {
                        self.invalidate(&self.logs_watch);
                        self.invalidate(&self.file_watches[3]);
                    }
                    for (&self.file_watches) |*watch| {
                        if (event.ident == watch.*) self.invalidate(watch);
                    }
                }
            }
        }
        try self.refresh();
    }
};

test "watcher attaches after missing userdata and logs appear" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try temporary.dir.realPath(std.testing.io, &path_buf);
    const root = path_buf[0..root_len];
    const base = try std.fmt.allocPrint(std.testing.allocator, "{s}/userdata", .{root});
    defer std.testing.allocator.free(base);
    var watcher = try Watcher.init(std.testing.allocator, base);
    defer watcher.deinit();
    try std.testing.expectEqual(-1, watcher.base_watch);
    try temporary.dir.createDirPath(std.testing.io, "userdata/logs");
    try watcher.wait(0);
    try std.testing.expect(watcher.base_watch >= 0 and watcher.logs_watch >= 0);
    const file = try temporary.dir.createFile(std.testing.io, "userdata/statev2.sqlite-wal", .{});
    file.close(std.testing.io);
    try watcher.wait(100);
    try temporary.dir.deleteTree(std.testing.io, "userdata");
    try watcher.wait(100);
    try std.testing.expectEqual(-1, watcher.base_watch);
    try temporary.dir.createDirPath(std.testing.io, "userdata/logs");
    try watcher.wait(0);
    try std.testing.expect(watcher.base_watch >= 0 and watcher.logs_watch >= 0);
}
