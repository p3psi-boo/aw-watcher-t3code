const std = @import("std");
const Allocator = std.mem.Allocator;

pub const State = enum { working, blocked, idle };
pub const Interaction = enum { supervised, autonomous, manual };

pub const ThreadInfo = struct {
    thread_id: []const u8 = "",
    thread_title: []const u8 = "",
    run_id: []const u8 = "",
    agent: []const u8 = "",
    model: []const u8 = "",
    status: State = .idle,
    phase: []const u8 = "idle",
    project: []const u8 = "",
    cwd: []const u8 = "",
    branch: []const u8 = "",
    runtime_mode: []const u8 = "",
    is_focused: bool = false,
    execution_mode: Interaction = .manual,
    is_subagent: bool = false,
};

pub const Thread = struct {
    info: ThreadInfo,
    last_active_ms: i64 = 0,
};

pub const Snapshot = struct {
    app: []const u8 = "T3 Code",
    title: []const u8,
    project: []const u8,
    dominant_state: State,
    interaction: Interaction,
    active_count: usize,
    working_count: usize,
    blocked_count: usize,
    supervised_count: usize,
    autonomous_count: usize,
    focused: ?ThreadInfo,
    agents: []ThreadInfo,
};

pub fn summarize(allocator: Allocator, threads: []const Thread, now_ms: i64, focus_ms: u64, pulse: bool) !?Snapshot {
    var candidate: ?usize = null;
    for (threads, 0..) |thread, i| {
        if (candidate == null or thread.last_active_ms > threads[candidate.?].last_active_ms or
            (thread.last_active_ms == threads[candidate.?].last_active_ms and std.mem.order(u8, thread.info.thread_id, threads[candidate.?].info.thread_id) == .lt))
            candidate = i;
    }
    var focused: ?ThreadInfo = null;
    if (candidate) |i| {
        const thread = threads[i];
        const age = now_ms - thread.last_active_ms;
        if (thread.last_active_ms > 0 and age >= 0 and
            (@as(u64, @intCast(age)) <= focus_ms or (pulse and
                (std.mem.eql(u8, thread.info.phase, "running") or @as(u64, @intCast(age)) <= focus_ms *| 3))))
        {
            focused = thread.info;
            focused.?.is_focused = true;
            focused.?.execution_mode = if (thread.info.status == .idle) .manual else .supervised;
        }
    }
    var agents: std.ArrayList(ThreadInfo) = .empty;
    var working: usize = 0;
    var blocked: usize = 0;
    var supervised: usize = 0;
    for (threads) |thread| {
        if (thread.info.status == .idle) continue;
        var info = thread.info;
        info.is_focused = if (focused) |f| std.mem.eql(u8, f.thread_id, info.thread_id) else false;
        info.execution_mode = if (info.is_focused) .supervised else .autonomous;
        if (info.status == .working) working += 1 else blocked += 1;
        if (info.is_focused) supervised += 1;
        try agents.append(allocator, info);
    }
    if (focused == null and agents.items.len == 0) return null;
    std.mem.sort(ThreadInfo, agents.items, {}, struct {
        fn lessThan(_: void, a: ThreadInfo, b: ThreadInfo) bool {
            return std.mem.order(u8, a.thread_id, b.thread_id) == .lt;
        }
    }.lessThan);
    const state: State = if (working > 0) .working else if (blocked > 0) .blocked else .idle;
    const interaction: Interaction = if (focused != null and focused.?.status != .idle) .supervised else if (agents.items.len > 0) .autonomous else .manual;
    var project: []const u8 = if (focused) |f| f.project else "";
    if (project.len == 0) {
        var selected: ?ThreadInfo = null;
        for (agents.items) |info| {
            if (info.project.len == 0) continue;
            if (selected == null or (info.status == .working and selected.?.status != .working) or
                (info.status == selected.?.status and std.mem.order(u8, info.project, selected.?.project) == .lt))
                selected = info;
        }
        project = if (selected) |info| info.project else "unknown";
    }
    return .{
        .title = try std.fmt.allocPrint(allocator, "[{s}] {s} ({s})", .{ project, @tagName(state), @tagName(interaction) }),
        .project = project,
        .dominant_state = state,
        .interaction = interaction,
        .active_count = agents.items.len,
        .working_count = working,
        .blocked_count = blocked,
        .supervised_count = supervised,
        .autonomous_count = agents.items.len - supervised,
        .focused = focused,
        .agents = try agents.toOwnedSlice(allocator),
    };
}

test "supervised autonomous manual and focus expiry" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var threads = [_]Thread{
        .{ .info = .{ .thread_id = "b", .project = "z", .status = .blocked, .phase = "waiting_approval" }, .last_active_ms = 1000 },
        .{ .info = .{ .thread_id = "a", .project = "a", .status = .working, .phase = "running" }, .last_active_ms = 2000 },
    };
    const supervised = (try summarize(a, &threads, 3000, 1000, false)).?;
    try std.testing.expectEqual(Interaction.supervised, supervised.interaction);
    try std.testing.expectEqual(@as(usize, 1), supervised.supervised_count);
    try std.testing.expectEqualStrings("a", supervised.agents[0].thread_id);
    try std.testing.expectEqual(State.working, supervised.dominant_state);
    const autonomous = (try summarize(a, &threads, 5000, 1000, false)).?;
    try std.testing.expectEqual(Interaction.autonomous, autonomous.interaction);
    try std.testing.expectEqualStrings("a", autonomous.project);
    threads[1].info.status = .idle;
    threads[1].info.phase = "idle";
    const browsing = (try summarize(a, &threads, 3000, 1000, false)).?;
    try std.testing.expectEqual(Interaction.autonomous, browsing.interaction);
    try std.testing.expectEqualStrings("a", browsing.project);
    threads[0].info.status = .idle;
    const manual = (try summarize(a, &threads, 3000, 1000, false)).?;
    try std.testing.expectEqual(Interaction.manual, manual.interaction);
    try std.testing.expectEqual(@as(usize, 0), manual.active_count);
    try std.testing.expect((try summarize(a, &threads, 5000, 1000, false)) == null);
}

test "pulse extension is bounded for idle threads and supports running thread" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var threads = [_]Thread{.{ .info = .{ .thread_id = "a" }, .last_active_ms = 1000 }};
    try std.testing.expect((try summarize(a, &threads, 4000, 1000, true)) != null);
    try std.testing.expect((try summarize(a, &threads, 4001, 1000, true)) == null);
    threads[0].info.status = .working;
    threads[0].info.phase = "running";
    try std.testing.expect((try summarize(a, &threads, 9000, 1000, true)).?.focused != null);
    try std.testing.expect((try summarize(a, &threads, 999, 1000, true)).?.focused == null);
}

test "working project outranks blocked project and uses alphabetical tie break" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const threads = [_]Thread{
        .{ .info = .{ .thread_id = "c", .project = "a", .status = .blocked } },
        .{ .info = .{ .thread_id = "b", .project = "z", .status = .working } },
        .{ .info = .{ .thread_id = "a", .project = "b", .status = .working } },
    };
    const result = (try summarize(arena.allocator(), &threads, 1000, 1000, false)).?;
    try std.testing.expectEqualStrings("b", result.project);
    try std.testing.expectEqualStrings("[b] working (autonomous)", result.title);
}
