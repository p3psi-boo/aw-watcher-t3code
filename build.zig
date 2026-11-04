const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    module.addCSourceFile(.{
        .file = b.path("vendor/sqlite/sqlite3.c"),
        .flags = &.{ "-DSQLITE_THREADSAFE=1", "-DSQLITE_OMIT_LOAD_EXTENSION", "-DSQLITE_DEFAULT_MEMSTATUS=0", "-DSQLITE_DQS=0" },
    });
    module.addIncludePath(b.path("vendor/sqlite"));
    module.addCSourceFile(.{ .file = b.path("src/readonly_vfs.c"), .flags = &.{} });
    const exe = b.addExecutable(.{ .name = "aw-watcher-t3code", .root_module = module });
    b.installArtifact(exe);
    const run = b.addRunArtifact(exe);
    run.addPassthruArgs();
    b.step("run", "Run the watcher").dependOn(&run.step);
    const tests = b.addTest(.{ .root_module = module });
    b.step("test", "Run the offline tests").dependOn(&b.addRunArtifact(tests).step);
}
