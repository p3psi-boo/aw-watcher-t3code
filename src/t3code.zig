const std = @import("std");
const Config = @import("config.zig").Config;
const model = @import("model.zig");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const sqlite3 = opaque {};
const sqlite3_stmt = opaque {};
extern "c" fn t3code_readonly_vfs_init() c_int;
extern "c" fn sqlite3_open_v2([*:0]const u8, *?*sqlite3, c_int, ?[*:0]const u8) c_int;
extern "c" fn sqlite3_close(*sqlite3) c_int;
extern "c" fn sqlite3_busy_timeout(*sqlite3, c_int) c_int;
extern "c" fn sqlite3_exec(*sqlite3, [*:0]const u8, ?*const anyopaque, ?*anyopaque, ?*?[*:0]u8) c_int;
extern "c" fn sqlite3_prepare_v2(*sqlite3, [*:0]const u8, c_int, *?*sqlite3_stmt, ?*?[*:0]const u8) c_int;
extern "c" fn sqlite3_step(*sqlite3_stmt) c_int;
extern "c" fn sqlite3_finalize(*sqlite3_stmt) c_int;
extern "c" fn sqlite3_column_text(*sqlite3_stmt, c_int) ?[*]const u8;
extern "c" fn sqlite3_column_bytes(*sqlite3_stmt, c_int) c_int;
extern "c" fn sqlite3_column_int64(*sqlite3_stmt, c_int) i64;
extern "c" fn sqlite3_errmsg(*sqlite3) [*:0]const u8;
extern "c" fn sqlite3_db_readonly(*sqlite3, [*:0]const u8) c_int;
extern "c" fn kill(c_int, c_int) c_int;
extern "c" fn getpid() c_int;
extern "c" fn fork() c_int;
extern "c" fn pipe(*[2]c_int) c_int;
extern "c" fn close(c_int) c_int;
extern "c" fn read(c_int, [*]u8, usize) isize;
extern "c" fn write(c_int, [*]const u8, usize) isize;
extern "c" fn waitpid(c_int, *c_int, c_int) c_int;
extern "c" fn _exit(c_int) noreturn;

fn sqliteResult(db: *sqlite3, result: c_int) !void {
    if (result == 0) return;
    std.log.debug("SQLite query failed ({d}): {s}", .{ result, sqlite3_errmsg(db) });
    return switch (result & 0xff) {
        5, 6 => error.DatabaseBusy,
        8 => error.DatabaseReadOnly,
        14 => error.DatabaseUnavailable,
        17, 1 => error.DatabaseSchemaNotReady,
        else => error.DatabaseQueryFailed,
    };
}

fn openDatabase(allocator: Allocator, base_dir: []const u8) !*sqlite3 {
    const path = try std.fs.path.join(allocator, &.{ base_dir, "statev2.sqlite" });
    defer allocator.free(path);
    var uri: std.ArrayList(u8) = .empty;
    defer uri.deinit(allocator);
    try uri.appendSlice(allocator, "file:");
    for (path) |ch| {
        if (std.ascii.isAlphanumeric(ch) or std.mem.indexOfScalar(u8, "/-_.~", ch) != null) {
            try uri.append(allocator, ch);
        } else {
            const hex = "0123456789ABCDEF";
            try uri.appendSlice(allocator, &.{ '%', hex[ch >> 4], hex[ch & 15] });
        }
    }
    // readonly_shm prevents SQLite from creating or write-mapping the WAL index.
    try uri.appendSlice(allocator, "?mode=ro&readonly_shm=1");
    const filename = try allocator.dupeSentinel(u8, uri.items, 0);
    defer allocator.free(filename);
    if (t3code_readonly_vfs_init() != 0) return error.DatabaseVfsUnavailable;
    var db: ?*sqlite3 = null;
    const result = sqlite3_open_v2(filename, &db, 0x00000001 | 0x00000040, "t3code-readonly");
    errdefer if (db) |connection| {
        _ = sqlite3_close(connection);
    };
    if (db == null) return error.DatabaseUnavailable;
    try sqliteResult(db.?, result);
    try sqliteResult(db.?, sqlite3_busy_timeout(db.?, 2000));
    try sqliteResult(db.?, sqlite3_exec(db.?, "PRAGMA query_only = ON; PRAGMA temp_store = MEMORY", null, null, null));
    if (sqlite3_db_readonly(db.?, "main") != 1) return error.DatabaseNotReadOnly;
    return db.?;
}

pub fn processAlive(allocator: Allocator, io: Io, base_dir: []const u8) !bool {
    const path = try std.fs.path.join(allocator, &.{ base_dir, "server-runtime.json" });
    defer allocator.free(path);
    const raw = Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(64 * 1024)) catch |err| switch (err) {
        error.FileNotFound, error.StreamTooLong => return false,
        else => return err,
    };
    defer allocator.free(raw);
    const parsed = std.json.parseFromSlice(struct { pid: i64 }, allocator, raw, .{ .ignore_unknown_fields = true }) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return false,
    };
    defer parsed.deinit();
    if (parsed.value.pid <= 0 or parsed.value.pid > std.math.maxInt(c_int)) return false;
    return switch (std.posix.errno(kill(@intCast(parsed.value.pid), 0))) {
        .SUCCESS, .PERM => true,
        .SRCH => false,
        else => error.ProcessProbeFailed,
    };
}

const query =
    \\WITH visible AS (
    \\ SELECT t.*, p.title AS project_title, p.workspace_root,
    \\  max(coalesce(CAST(strftime('%s', json_extract(t.payload_json,'$.lastVisitedAt')) AS INTEGER)*1000
    \\    + CAST(substr(strftime('%f', json_extract(t.payload_json,'$.lastVisitedAt')),4,3) AS INTEGER),0),
    \\   coalesce(json_extract(t.payload_json,'$.opens.openedAt'),0)) AS last_active_ms
    \\ FROM orchestration_v2_projection_threads t JOIN projection_projects p ON p.project_id=t.project_id
    \\ WHERE t.deleted_at IS NULL AND t.archived_at IS NULL AND p.deleted_at IS NULL
    \\), runs AS (
    \\ SELECT *, row_number() OVER (PARTITION BY thread_id ORDER BY ordinal DESC,run_id DESC) AS rank
    \\ FROM orchestration_v2_projection_runs
    \\ WHERE status IN ('queued','preparing','starting','running','waiting')
    \\), requests AS (
    \\ SELECT *, row_number() OVER (PARTITION BY thread_id ORDER BY created_at DESC,runtime_request_id DESC) AS rank
    \\ FROM orchestration_v2_projection_runtime_requests WHERE status='pending'
    \\), candidate AS (SELECT thread_id FROM visible ORDER BY last_active_ms DESC,thread_id LIMIT 1)
    \\SELECT t.thread_id,t.title,t.project_title,t.workspace_root,t.default_provider,t.runtime_mode,
    \\ json_extract(t.payload_json,'$.branch'),json_extract(t.payload_json,'$.worktreePath'),
    \\ json_extract(t.payload_json,'$.modelSelection.model'),json_extract(t.payload_json,'$.lineage.parentThreadId'),
    \\ r.run_id,r.provider,r.status,json_extract(r.payload_json,'$.modelSelection.model'),
    \\ json_extract(r.payload_json,'$.workspacePreparation.branch'),q.kind,t.last_active_ms,q.runtime_request_id IS NOT NULL
    \\FROM visible t
    \\LEFT JOIN runs r ON r.thread_id=t.thread_id AND r.rank=1
    \\LEFT JOIN requests q ON q.thread_id=t.thread_id AND q.rank=1
    \\WHERE r.run_id IS NOT NULL OR q.runtime_request_id IS NOT NULL OR t.thread_id IN candidate
    \\ORDER BY t.thread_id
;

fn text(allocator: Allocator, statement: *sqlite3_stmt, column: c_int) ![]const u8 {
    const ptr = sqlite3_column_text(statement, column) orelse return "";
    return allocator.dupe(u8, ptr[0..@intCast(sqlite3_column_bytes(statement, column))]);
}

fn loadThreads(allocator: Allocator, base_dir: []const u8) ![]model.Thread {
    const db = try openDatabase(allocator, base_dir);
    defer _ = sqlite3_close(db);
    var statement: ?*sqlite3_stmt = null;
    try sqliteResult(db, sqlite3_prepare_v2(db, query, -1, &statement, null));
    defer _ = sqlite3_finalize(statement.?);
    var threads: std.ArrayList(model.Thread) = .empty;
    while (true) {
        const result = sqlite3_step(statement.?);
        if (result == 101) break;
        if (result != 100) try sqliteResult(db, result);
        const s = statement.?;
        var info: model.ThreadInfo = .{
            .thread_id = try text(allocator, s, 0),
            .thread_title = try text(allocator, s, 1),
            .project = try text(allocator, s, 2),
            .cwd = try text(allocator, s, 7),
            .agent = try text(allocator, s, 11),
            .runtime_mode = try text(allocator, s, 5),
            .branch = try text(allocator, s, 14),
            .model = try text(allocator, s, 13),
            .is_subagent = (try text(allocator, s, 9)).len > 0,
            .run_id = try text(allocator, s, 10),
        };
        if (info.cwd.len == 0) info.cwd = try text(allocator, s, 3);
        if (info.agent.len == 0) info.agent = try text(allocator, s, 4);
        if (info.branch.len == 0) info.branch = try text(allocator, s, 6);
        if (info.model.len == 0) info.model = try text(allocator, s, 8);
        const pending = try text(allocator, s, 15);
        const run_status = try text(allocator, s, 12);
        if (sqlite3_column_int64(s, 17) != 0) {
            info.status = .blocked;
            info.phase = if (std.mem.eql(u8, pending, "user_input")) "waiting_user_input" else "waiting_approval";
        } else if (std.mem.eql(u8, run_status, "waiting")) {
            info.status = .blocked;
            info.phase = "waiting";
        } else if (run_status.len > 0) {
            info.status = .working;
            info.phase = run_status;
        }
        try threads.append(allocator, .{ .info = info, .last_active_ms = sqlite3_column_int64(s, 16) });
    }
    return threads.toOwnedSlice(allocator);
}

fn recentPulse(allocator: Allocator, io: Io, base_dir: []const u8, now_ms: i64) !bool {
    const path = try std.fs.path.join(allocator, &.{ base_dir, "logs", "server.trace.ndjson" });
    defer allocator.free(path);
    const file = Io.Dir.cwd().openFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    defer file.close(io);
    const stat = try file.stat(io);
    const age = now_ms - stat.mtime.toMilliseconds();
    if (age < 0 or age > 45000) return false;
    var buffer: [16384]u8 = undefined;
    const offset = stat.size -| buffer.len;
    const len = try file.readPositionalAll(io, &buffer, offset);
    var lines = std.mem.splitScalar(u8, buffer[0..len], '\n');
    if (offset > 0) _ = lines.next();
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const parsed = std.json.parseFromSlice(struct {
            name: []const u8 = "",
            startTimeUnixNano: []const u8 = "",
        }, allocator, line, .{ .ignore_unknown_fields = true }) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => continue,
        };
        defer parsed.deinit();
        if (!std.mem.eql(u8, parsed.value.name, "ws.rpc.server.reportClientActivity")) continue;
        const nanos = std.fmt.parseInt(i128, parsed.value.startTimeUnixNano, 10) catch continue;
        const timestamp = @divTrunc(nanos, std.time.ns_per_ms);
        if (timestamp <= now_ms and timestamp >= @as(i128, now_ms) - 45000) return true;
    }
    return false;
}

pub fn readSnapshot(allocator: Allocator, io: Io, c: Config, now_ms: i64) !?model.Snapshot {
    if (!try processAlive(allocator, io, c.base_dir)) return null;
    const threads = try loadThreads(allocator, c.base_dir);
    const pulse = recentPulse(allocator, io, c.base_dir, now_ms) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => blk: {
            std.log.debug("Optional client activity trace is unavailable: {s}", .{@errorName(err)});
            break :blk false;
        },
    };
    return model.summarize(allocator, threads, now_ms, c.focus_ms, pulse);
}

pub fn checkDatabase(allocator: Allocator, io: Io, base_dir: []const u8) !usize {
    _ = io;
    const threads = try loadThreads(allocator, base_dir);
    var count: usize = 0;
    for (threads) |thread| {
        if (thread.info.status != .idle) count += 1;
    }
    return count;
}

const fixture_schema =
    \\CREATE TABLE projection_projects(project_id TEXT PRIMARY KEY,title TEXT,workspace_root TEXT,deleted_at TEXT);
    \\CREATE TABLE orchestration_v2_projection_threads(thread_id TEXT PRIMARY KEY,project_id TEXT,title TEXT,default_provider TEXT,runtime_mode TEXT,archived_at TEXT,deleted_at TEXT,payload_json TEXT);
    \\CREATE TABLE orchestration_v2_projection_runs(run_id TEXT PRIMARY KEY,thread_id TEXT,ordinal INTEGER,provider TEXT,status TEXT,payload_json TEXT);
    \\CREATE TABLE orchestration_v2_projection_runtime_requests(runtime_request_id TEXT PRIMARY KEY,thread_id TEXT,kind TEXT,status TEXT,created_at TEXT);
    \\INSERT INTO projection_projects VALUES('p','project','/workspace',NULL);
    \\INSERT INTO orchestration_v2_projection_threads VALUES('a','p','Thread','codex','full-access',NULL,NULL,
    \\ '{"lastVisitedAt":"2024-01-01T00:00:00.123Z","opens":{"openedAt":1704067200000},"modelSelection":{"model":"thread-model"},"branch":"main","lineage":{"parentThreadId":"parent"}}');
    \\INSERT INTO orchestration_v2_projection_runs VALUES('old','a',1,'codex','running','{}');
    \\INSERT INTO orchestration_v2_projection_runs VALUES('new','a',2,'antigravity','waiting','{"modelSelection":{"model":"run-model"},"workspacePreparation":{"branch":"run-branch"}}');
;

fn createFixture(allocator: Allocator, base_dir: []const u8) !*sqlite3 {
    const path = try std.fs.path.join(allocator, &.{ base_dir, "statev2.sqlite" });
    defer allocator.free(path);
    const filename = try allocator.dupeSentinel(u8, path, 0);
    defer allocator.free(filename);
    var db: ?*sqlite3 = null;
    const result = sqlite3_open_v2(filename, &db, 0x00000002 | 0x00000004, null);
    if (db == null) return error.DatabaseUnavailable;
    errdefer _ = sqlite3_close(db.?);
    try sqliteResult(db.?, result);
    try sqliteResult(db.?, sqlite3_exec(db.?, fixture_schema, null, null, null));
    return db.?;
}

test "SQLite latest run pending requests paths models and readonly guard" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const base = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    const fixture = try createFixture(a, base);
    defer _ = sqlite3_close(fixture);
    var threads = try loadThreads(a, base);
    try std.testing.expectEqual(@as(usize, 1), threads.len);
    try std.testing.expectEqual(model.State.blocked, threads[0].info.status);
    try std.testing.expectEqualStrings("waiting", threads[0].info.phase);
    try std.testing.expectEqualStrings("new", threads[0].info.run_id);
    try std.testing.expectEqualStrings("run-model", threads[0].info.model);
    try std.testing.expectEqualStrings("antigravity", threads[0].info.agent);
    try std.testing.expectEqualStrings("run-branch", threads[0].info.branch);
    try std.testing.expectEqualStrings("/workspace", threads[0].info.cwd);
    try std.testing.expect(threads[0].info.is_subagent);
    try std.testing.expectEqual(@as(i64, 1704067200123), threads[0].last_active_ms);
    try sqliteResult(fixture, sqlite3_exec(fixture, "INSERT INTO orchestration_v2_projection_runtime_requests VALUES('r','a','user_input','pending','1')", null, null, null));
    threads = try loadThreads(a, base);
    try std.testing.expectEqualStrings("waiting_user_input", threads[0].info.phase);
    try sqliteResult(fixture, sqlite3_exec(fixture, "INSERT INTO orchestration_v2_projection_runtime_requests VALUES('r2','a','approval','pending','2')", null, null, null));
    threads = try loadThreads(a, base);
    try std.testing.expectEqualStrings("waiting_approval", threads[0].info.phase);
    const db = try openDatabase(a, base);
    defer _ = sqlite3_close(db);
    try std.testing.expectEqual(@as(c_int, 8), sqlite3_exec(db, "DELETE FROM projection_projects", null, null, null));
    try sqliteResult(fixture, sqlite3_exec(fixture, "DELETE FROM orchestration_v2_projection_runtime_requests; UPDATE orchestration_v2_projection_runs SET status='completed';" ++
        "UPDATE orchestration_v2_projection_threads SET payload_json=json_set(payload_json,'$.worktreePath','/worktree');" ++
        "UPDATE orchestration_v2_projection_runs SET payload_json='{}' WHERE run_id='new';", null, null, null));
    for ([_][]const u8{ "queued", "preparing", "starting", "running" }) |status| {
        const update = try std.fmt.allocPrintSentinel(a, "UPDATE orchestration_v2_projection_runs SET status='{s}' WHERE run_id='new'", .{status}, 0);
        try sqliteResult(fixture, sqlite3_exec(fixture, update, null, null, null));
        threads = try loadThreads(a, base);
        try std.testing.expectEqual(model.State.working, threads[0].info.status);
        try std.testing.expectEqualStrings(status, threads[0].info.phase);
        try std.testing.expectEqualStrings("/worktree", threads[0].info.cwd);
        try std.testing.expectEqualStrings("thread-model", threads[0].info.model);
        try std.testing.expectEqualStrings("main", threads[0].info.branch);
    }
    try sqliteResult(fixture, sqlite3_exec(fixture, "UPDATE orchestration_v2_projection_threads SET archived_at='1'", null, null, null));
    try std.testing.expectEqual(@as(usize, 0), (try loadThreads(a, base)).len);
}

test "dead missing invalid process metadata suppresses stale runs" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const base = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    const c: Config = .{ .base_dir = base, .hostname = "test" };
    try std.testing.expect(!try processAlive(a, std.testing.io, base));
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "server-runtime.json", .data = "invalid" });
    try std.testing.expect(!try processAlive(a, std.testing.io, base));
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "server-runtime.json", .data = "{\"pid\":0}" });
    try std.testing.expect((try readSnapshot(a, std.testing.io, c, 1000)) == null);
    const runtime = try std.fmt.allocPrint(a, "{{\"pid\":{d}}}", .{getpid()});
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "server-runtime.json", .data = runtime });
    try std.testing.expect(try processAlive(a, std.testing.io, base));
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "server-runtime.json", .data = "{\"pid\":2147483647}" });
    try std.testing.expect((try readSnapshot(a, std.testing.io, c, 1000)) == null);
}

test "WAL reads latest committed rows without SHM writes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const base = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    const fixture = try createFixture(a, base);
    try sqliteResult(fixture, sqlite3_close(fixture));
    const path = try std.fmt.allocPrintSentinel(a, "{s}/statev2.sqlite", .{base}, 0);
    var ready: [2]c_int = undefined;
    var stop: [2]c_int = undefined;
    if (pipe(&ready) != 0) return error.PipeFailed;
    defer _ = close(ready[0]);
    if (pipe(&stop) != 0) return error.PipeFailed;
    defer _ = close(stop[1]);
    const pid = fork();
    if (pid < 0) {
        _ = close(ready[1]);
        _ = close(stop[0]);
        return error.ForkFailed;
    }
    if (pid == 0) {
        _ = close(ready[0]);
        _ = close(stop[1]);
        var db: ?*sqlite3 = null;
        if (sqlite3_open_v2(path, &db, 0x00000002, null) != 0) _exit(1);
        if (sqlite3_exec(db.?, "PRAGMA journal_mode=WAL; UPDATE orchestration_v2_projection_runs SET status='running' WHERE run_id='new';", null, null, null) != 0) _exit(2);
        if (write(ready[1], "1", 1) != 1) _exit(3);
        var signal: [1]u8 = undefined;
        if (read(stop[0], &signal, 1) != 1) _exit(4);
        if (sqlite3_close(db.?) != 0) _exit(5);
        _exit(0);
    }
    _ = close(ready[1]);
    _ = close(stop[0]);
    defer {
        _ = write(stop[1], "1", 1);
        var status: c_int = 0;
        _ = waitpid(pid, &status, 0);
    }
    var signal: [1]u8 = undefined;
    if (read(ready[0], &signal, 1) != 1) return error.WriterNotReady;
    const before = try tmp.dir.readFileAlloc(std.testing.io, "statev2.sqlite-shm", a, .limited(1024 * 1024));
    const threads = try loadThreads(a, base);
    try std.testing.expectEqual(model.State.working, threads[0].info.status);
    const after = try tmp.dir.readFileAlloc(std.testing.io, "statev2.sqlite-shm", a, .limited(1024 * 1024));
    try std.testing.expectEqualSlices(u8, before, after);
}

test "trace pulse requires matching recent timestamp and tolerates partial lines" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const base = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    try tmp.dir.createDirPath(std.testing.io, "logs");
    const now = Io.Timestamp.now(std.testing.io, .real).toMilliseconds();
    const pulse = try std.fmt.allocPrint(a, "partial\n{{\"name\":\"ws.rpc.server.reportClientActivity\",\"startTimeUnixNano\":\"{d}\"}}\n", .{@as(i128, now) * std.time.ns_per_ms});
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "logs/server.trace.ndjson", .data = pulse });
    try std.testing.expect(try recentPulse(a, std.testing.io, base, Io.Timestamp.now(std.testing.io, .real).toMilliseconds()));
    const old = try std.fmt.allocPrint(a, "{{\"name\":\"ws.rpc.server.reportClientActivity\",\"startTimeUnixNano\":\"{d}\"}}\n", .{@as(i128, now - 45001) * std.time.ns_per_ms});
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "logs/server.trace.ndjson", .data = old });
    try std.testing.expect(!try recentPulse(a, std.testing.io, base, Io.Timestamp.now(std.testing.io, .real).toMilliseconds()));
}

test "missing WAL and SHM files are never created by a snapshot" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const base = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    const fixture = try createFixture(a, base);
    try sqliteResult(fixture, sqlite3_exec(fixture, "PRAGMA journal_mode=WAL", null, null, null));
    try sqliteResult(fixture, sqlite3_close(fixture));
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(std.testing.io, "statev2.sqlite-wal", .{}));
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(std.testing.io, "statev2.sqlite-shm", .{}));
    _ = loadThreads(a, base) catch |err| switch (err) {
        error.DatabaseUnavailable, error.DatabaseReadOnly => null,
        else => return err,
    };
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(std.testing.io, "statev2.sqlite-wal", .{}));
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(std.testing.io, "statev2.sqlite-shm", .{}));
}
