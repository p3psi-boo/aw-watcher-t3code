const std = @import("std");
const Config = @import("config.zig").Config;
const Allocator = std.mem.Allocator;

pub const Writer = struct {
    allocator: Allocator,
    io: std.Io,
    config: Config,
    client: std.http.Client,
    session: [16]u8,
    epoch: u64 = 0,
    bucket_ready: bool = false,
    paused: bool = false,
    last_data: ?[]const u8 = null,
    last_ms: i64 = 0,

    pub fn init(allocator: Allocator, io: std.Io, config: Config) Writer {
        var session: [16]u8 = undefined;
        io.random(&session);
        return .{ .allocator = allocator, .io = io, .config = config, .client = .{ .allocator = allocator, .io = io }, .session = session };
    }

    pub fn deinit(self: *Writer) void {
        if (self.last_data) |data| self.allocator.free(data);
        self.client.deinit();
    }

    pub fn pause(self: *Writer) void {
        if (!self.paused) self.epoch +%= 1;
        self.paused = true;
        self.bucket_ready = false;
        if (self.last_data) |data| self.allocator.free(data);
        self.last_data = null;
    }

    pub fn emit(self: *Writer, data_json: []const u8, now_ms: i64) !void {
        if (self.last_data) |last| {
            if (now_ms < self.last_ms) {
                self.pause();
            } else if (std.mem.eql(u8, last, data_json) and now_ms - self.last_ms < self.config.heartbeat_ms) return;
        }
        errdefer self.pause();
        const bucket_id = try std.fmt.allocPrint(self.allocator, "aw-watcher-t3code_{s}", .{self.config.hostname});
        defer self.allocator.free(bucket_id);
        var encoded: std.Io.Writer.Allocating = .init(self.allocator);
        defer encoded.deinit();
        try std.Uri.Component.percentEncode(&encoded.writer, bucket_id, isPathSegmentChar);
        const bucket_url = try std.fmt.allocPrint(self.allocator, "{s}/api/0/buckets/{s}", .{ std.mem.trimEnd(u8, self.config.aw_url, "/"), encoded.written() });
        defer self.allocator.free(bucket_url);
        if (!self.bucket_ready) {
            const name = try std.fmt.allocPrint(self.allocator, "T3 Code ({s})", .{self.config.hostname});
            defer self.allocator.free(name);
            const metadata = try std.json.Stringify.valueAlloc(self.allocator, .{
                .client = "aw-watcher-t3code",
                .type = "app.t3code.activity",
                .hostname = self.config.hostname,
                .name = name,
            }, .{});
            defer self.allocator.free(metadata);
            const response = try request(&self.client, self.config.timeout_ms, bucket_url, metadata);
            defer self.allocator.free(response.body);
            if (!successful(response.status) and response.status != .not_modified) return error.BucketCreationFailed;
            self.bucket_ready = true;
        }
        var timestamp_buf: [24]u8 = undefined;
        const timestamp = try formatTimestamp(&timestamp_buf, now_ms);
        const data = std.mem.trim(u8, data_json, " \t\r\n");
        const body = try std.fmt.allocPrint(self.allocator, "{{\"timestamp\":\"{s}\",\"duration\":0,\"data\":{{{s}{s}\"delivery_epoch\":\"{x}-{d}\"}}}}", .{ timestamp, data[1 .. data.len - 1], if (data.len > 2) "," else "", self.session, self.epoch });
        defer self.allocator.free(body);
        const heartbeat_url = try std.fmt.allocPrint(self.allocator, "{s}/heartbeat?pulsetime={d}.{d:0>3}", .{ bucket_url, self.config.pulse_ms / 1000, self.config.pulse_ms % 1000 });
        defer self.allocator.free(heartbeat_url);
        const response = try request(&self.client, self.config.timeout_ms, heartbeat_url, body);
        defer self.allocator.free(response.body);
        if (!successful(response.status)) return error.HeartbeatFailed;
        const saved = try self.allocator.dupe(u8, data_json);
        if (self.last_data) |last| self.allocator.free(last);
        self.last_data = saved;
        self.last_ms = now_ms;
        self.paused = false;
    }

    pub fn check(allocator: Allocator, io: std.Io, config: Config) !void {
        var client: std.http.Client = .{ .allocator = allocator, .io = io };
        defer client.deinit();
        const url = try std.fmt.allocPrint(allocator, "{s}/api/0/info", .{std.mem.trimEnd(u8, config.aw_url, "/")});
        defer allocator.free(url);
        const response = try request(&client, config.timeout_ms, url, null);
        defer allocator.free(response.body);
        if (response.status != .ok) return error.ActivityWatchUnavailable;
        const info = try std.json.parseFromSlice(struct { hostname: []const u8, version: []const u8 }, allocator, response.body, .{ .ignore_unknown_fields = true });
        defer info.deinit();
        if (info.value.hostname.len == 0 or info.value.version.len == 0) return error.InvalidActivityWatchInfo;
    }
};

fn successful(status: std.http.Status) bool {
    return @backingInt(status) >= 200 and @backingInt(status) < 300;
}

const Response = struct { status: std.http.Status, body: []const u8 };

fn request(client: *std.http.Client, timeout_ms: u64, url: []const u8, payload: ?[]const u8) !Response {
    const Result = union(enum) { request: anyerror!void, timeout: std.Io.Cancelable!void };
    var results: [2]Result = undefined;
    var select = std.Io.Select(Result).init(client.io, &results);
    defer select.cancelDiscard();
    var buffer: [64 * 1024]u8 = undefined;
    var output: std.Io.Writer = .fixed(&buffer);
    var status: std.http.Status = undefined;
    try select.concurrent(.request, performRequest, .{ client, url, payload, &output, &status });
    try select.concurrent(.timeout, std.Io.sleep, .{ client.io, std.Io.Duration.fromMilliseconds(@intCast(timeout_ms)), .awake });
    switch (try select.await()) {
        .request => |result| try result,
        .timeout => |result| {
            try result;
            return error.Timeout;
        },
    }
    return .{ .status = status, .body = try client.allocator.dupe(u8, output.buffered()) };
}

fn performRequest(client: *std.http.Client, url: []const u8, payload: ?[]const u8, output: *std.Io.Writer, status: *std.http.Status) !void {
    const response = try client.fetch(.{
        .location = .{ .url = url },
        .payload = payload,
        .response_writer = output,
        .redirect_behavior = .unhandled,
        .headers = .{ .content_type = .{ .override = "application/json" } },
    });
    status.* = response.status;
}

fn formatTimestamp(buffer: *[24]u8, now_ms: i64) ![]const u8 {
    if (now_ms < 0) return error.InvalidTimestamp;
    const seconds: std.time.epoch.EpochSeconds = .{ .secs = @intCast(@divTrunc(now_ms, 1000)) };
    const year_day = seconds.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day = seconds.getDaySeconds();
    return std.fmt.bufPrint(buffer, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}Z", .{
        year_day.year,                          month_day.month.numeric(), @as(u8, month_day.day_index) + 1,
        day.getHoursIntoDay(),                  day.getMinutesIntoHour(),  day.getSecondsIntoMinute(),
        @as(u16, @intCast(@mod(now_ms, 1000))),
    });
}

test "timestamp retains UTC milliseconds" {
    var buffer: [24]u8 = undefined;
    try std.testing.expectEqualStrings("2024-01-01T00:00:00.123Z", try formatTimestamp(&buffer, 1704067200123));
}

test "pause rotates delivery epoch only once until successful delivery" {
    const config: Config = .{ .base_dir = ".", .hostname = "test" };
    var writer = Writer.init(std.testing.allocator, std.testing.io, config);
    defer writer.deinit();
    writer.last_data = try std.testing.allocator.dupe(u8, "{}");
    writer.bucket_ready = true;
    writer.pause();
    try std.testing.expectEqual(1, writer.epoch);
    try std.testing.expect(!writer.bucket_ready and writer.last_data == null);
    writer.pause();
    try std.testing.expectEqual(1, writer.epoch);
}

fn isPathSegmentChar(char: u8) bool {
    return std.ascii.isAlphanumeric(char) or char == '-' or char == '_' or char == '.' or char == '~';
}

const Mock = struct {
    listener: std.Io.net.Server,
    statuses: []const std.http.Status,
    response_body: []const u8 = "{}",
    delay_ms: i64 = 0,
    requests: [8]?struct { path: []const u8, body: []const u8 } = @splat(null),

    fn init(statuses: []const std.http.Status) !Mock {
        const address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
        return .{ .listener = try address.listen(std.testing.io, .{}), .statuses = statuses };
    }

    fn deinit(self: *Mock) void {
        self.listener.deinit(std.testing.io);
        for (self.requests) |maybe_request| if (maybe_request) |req| {
            std.testing.allocator.free(req.path);
            std.testing.allocator.free(req.body);
        };
    }

    fn url(self: *const Mock) ![]const u8 {
        return std.fmt.allocPrint(std.testing.allocator, "http://127.0.0.1:{d}", .{self.listener.socket.address.getPort()});
    }

    fn serve(self: *Mock) !void {
        for (self.statuses, 0..) |status, index| {
            const stream = try self.listener.accept(std.testing.io);
            defer stream.close(std.testing.io);
            var read_buf: [4096]u8 = undefined;
            var write_buf: [4096]u8 = undefined;
            var reader = stream.reader(std.testing.io, &read_buf);
            var writer = stream.writer(std.testing.io, &write_buf);
            var server = std.http.Server.init(&reader.interface, &writer.interface);
            var req = try server.receiveHead();
            self.requests[index] = blk: {
                const path = try std.testing.allocator.dupe(u8, req.head.target);
                errdefer std.testing.allocator.free(path);
                var body_buf: [4096]u8 = undefined;
                const body = try req.readerExpectNone(&body_buf).allocRemaining(std.testing.allocator, .limited(64 * 1024));
                break :blk .{ .path = path, .body = body };
            };
            if (self.delay_ms > 0) try std.Io.sleep(std.testing.io, .fromMilliseconds(self.delay_ms), .awake);
            try req.respond(self.response_body, .{ .status = status, .keep_alive = false });
        }
    }
};

test "heartbeat coalesces unchanged data and cuts delivery after failure and pause" {
    const allocator = std.testing.allocator;
    var mock = try Mock.init(&.{ .ok, .ok, .ok, .service_unavailable, .not_modified, .ok, .not_modified, .ok });
    defer mock.deinit();
    const url = try mock.url();
    defer allocator.free(url);
    var server = try std.Io.concurrent(std.testing.io, Mock.serve, .{&mock});
    defer server.cancel(std.testing.io) catch |err| switch (err) {
        error.Canceled => {},
        else => @panic(@errorName(err)),
    };
    var writer = Writer.init(allocator, std.testing.io, .{ .base_dir = ".", .hostname = "host / escaped", .aw_url = url });
    defer writer.deinit();
    try writer.emit("{\"project\":\"one\"}", 10000);
    try writer.emit("{\"project\":\"one\"}", 10100);
    try writer.emit("{\"project\":\"two\"}", 10200);
    try std.testing.expectError(error.HeartbeatFailed, writer.emit("{\"project\":\"two\"}", 11200));
    try writer.emit("{\"project\":\"two\"}", 12200);
    writer.pause();
    try writer.emit("{\"project\":\"two\"}", 12300);
    try server.await(std.testing.io);
    try std.testing.expectEqualStrings("/api/0/buckets/aw-watcher-t3code_host%20%2F%20escaped", mock.requests[0].?.path);
    const metadata = try std.json.parseFromSlice(std.json.Value, allocator, mock.requests[0].?.body, .{});
    defer metadata.deinit();
    try std.testing.expectEqualStrings("app.t3code.activity", metadata.value.object.get("type").?.string);
    const before = try std.json.parseFromSlice(std.json.Value, allocator, mock.requests[1].?.body, .{});
    defer before.deinit();
    const changed = try std.json.parseFromSlice(std.json.Value, allocator, mock.requests[2].?.body, .{});
    defer changed.deinit();
    const recovered = try std.json.parseFromSlice(std.json.Value, allocator, mock.requests[5].?.body, .{});
    defer recovered.deinit();
    const resumed = try std.json.parseFromSlice(std.json.Value, allocator, mock.requests[7].?.body, .{});
    defer resumed.deinit();
    const epoch_before = before.value.object.get("data").?.object.get("delivery_epoch").?.string;
    const epoch_changed = changed.value.object.get("data").?.object.get("delivery_epoch").?.string;
    const epoch_recovered = recovered.value.object.get("data").?.object.get("delivery_epoch").?.string;
    const epoch_resumed = resumed.value.object.get("data").?.object.get("delivery_epoch").?.string;
    try std.testing.expectEqualStrings(epoch_before, epoch_changed);
    try std.testing.expect(!std.mem.eql(u8, epoch_before, epoch_recovered));
    try std.testing.expect(!std.mem.eql(u8, epoch_recovered, epoch_resumed));
    try std.testing.expectEqualStrings("two", recovered.value.object.get("data").?.object.get("project").?.string);
    try std.testing.expectEqualStrings("1970-01-01T00:00:12.200Z", recovered.value.object.get("timestamp").?.string);
}

test "doctor rejects non-ActivityWatch JSON despite HTTP success" {
    var mock = try Mock.init(&.{.ok});
    defer mock.deinit();
    const url = try mock.url();
    defer std.testing.allocator.free(url);
    var server = try std.Io.concurrent(std.testing.io, Mock.serve, .{&mock});
    defer server.cancel(std.testing.io) catch |err| switch (err) {
        error.Canceled => {},
        else => @panic(@errorName(err)),
    };
    try std.testing.expectError(error.MissingField, Writer.check(std.testing.allocator, std.testing.io, .{ .base_dir = ".", .hostname = "test", .aw_url = url }));
    try server.await(std.testing.io);
}

test "HTTP deadline cancels a server that never responds promptly" {
    var mock = try Mock.init(&.{.ok});
    defer mock.deinit();
    mock.delay_ms = 500;
    const url = try mock.url();
    defer std.testing.allocator.free(url);
    var server = try std.Io.concurrent(std.testing.io, Mock.serve, .{&mock});
    defer server.cancel(std.testing.io) catch |err| switch (err) {
        error.Canceled => {},
        else => @panic(@errorName(err)),
    };
    const started = std.Io.Clock.awake.now(std.testing.io);
    try std.testing.expectError(error.Timeout, Writer.check(std.testing.allocator, std.testing.io, .{ .base_dir = ".", .hostname = "test", .aw_url = url, .timeout_ms = 25 }));
    try std.testing.expect(started.durationTo(std.Io.Clock.awake.now(std.testing.io)).toMilliseconds() < 400);
}
