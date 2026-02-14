const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // WebSocket dependency (same as ZSC)
    const websocket = b.dependency("websocket", .{
        .target = target,
        .optimize = optimize,
    });

    // Ziggy-core shared library (logging, profiling, utilities)
    const ziggy_core = b.dependency("ziggy_core", .{
        .target = target,
        .optimize = optimize,
    });

    // Main CLI executable
    const exe = b.addExecutable(.{
        .name = "ziggystarspider",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    exe.root_module.addImport("websocket", websocket.module("websocket"));
    exe.root_module.addImport("ziggy-core", ziggy_core.module("ziggy-core"));

    b.installArtifact(exe);

    // Run command
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    // Tests
    const unit_tests = b.addTest(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    unit_tests.root_module.addImport("websocket", websocket.module("websocket"));
    unit_tests.root_module.addImport("ziggy-core", ziggy_core.module("ziggy-core"));

    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}
