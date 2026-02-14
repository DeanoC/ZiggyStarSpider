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

    // Create the root module
    const root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    root_module.addImport("websocket", websocket.module("websocket"));
    root_module.addImport("ziggy-core", ziggy_core.module("ziggy-core"));

    // Main CLI executable
    const exe = b.addExecutable(.{
        .name = "ziggystarspider",
        .root_module = root_module,
    });

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
    const test_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_module.addImport("websocket", websocket.module("websocket"));
    test_module.addImport("ziggy-core", ziggy_core.module("ziggy-core"));

    const unit_tests = b.addTest(.{
        .root_module = test_module,
    });

    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}
