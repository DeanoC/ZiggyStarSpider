const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const websocket = b.dependency("websocket", .{
        .target = target,
        .optimize = optimize,
    });

    const ziggy_core = b.dependency("ziggy_core", .{
        .target = target,
        .optimize = optimize,
    });

    const ziggy_ui = b.dependency("ziggy_ui", .{
        .target = target,
        .optimize = optimize,
    });

    const sdl3 = b.dependency("sdl3", .{
        .target = target,
        .optimize = optimize,
    });

    // ---------------------------------------------------------------------
    // CLI executable (default build)
    // ---------------------------------------------------------------------
    const cli_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    cli_module.addImport("websocket", websocket.module("websocket"));
    cli_module.addImport("ziggy-core", ziggy_core.module("ziggy-core"));

    const cli_exe = b.addExecutable(.{
        .name = "zss",
        .root_module = cli_module,
    });

    b.installArtifact(cli_exe);

    const run_cmd = b.addRunArtifact(cli_exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run the CLI app");
    run_step.dependOn(&run_cmd.step);

    // ---------------------------------------------------------------------
    // GUI executable (opt-in via `zig build gui`)
    // ---------------------------------------------------------------------
    const os_tag = target.result.os.tag;
    const desktop_target = os_tag == .linux or os_tag == .windows or os_tag == .macos;

    if (desktop_target) {
        const zui_theme_mod = b.createModule(.{
            .root_source_file = ziggy_ui.path("src/themes/theme.zig"),
            .target = target,
            .optimize = optimize,
        });

        const zui_profile_mod = b.createModule(.{
            .root_source_file = ziggy_ui.path("src/theme_engine/profile.zig"),
            .target = target,
            .optimize = optimize,
        });

        const gui_module = b.createModule(.{
            .root_source_file = b.path("src/gui/root.zig"),
            .target = target,
            .optimize = optimize,
        });
        gui_module.addImport("websocket", websocket.module("websocket"));
        gui_module.addImport("ziggy_ui_theme", zui_theme_mod);
        gui_module.addImport("ziggy_ui_profile", zui_profile_mod);
        gui_module.addIncludePath(sdl3.path("include"));

        const gui_exe = b.addExecutable(.{
            .name = "zss-gui",
            .root_module = gui_module,
        });

        gui_exe.linkLibrary(sdl3.artifact("SDL3"));

        switch (os_tag) {
            .windows => {
                gui_exe.root_module.linkSystemLibrary("ole32", .{});
                gui_exe.root_module.linkSystemLibrary("user32", .{});
                gui_exe.root_module.linkSystemLibrary("gdi32", .{});
            },
            .macos => {
                gui_exe.root_module.linkSystemLibrary("objc", .{});
                gui_exe.root_module.linkFramework("Cocoa", .{});
                gui_exe.root_module.linkFramework("IOKit", .{});
                gui_exe.root_module.linkFramework("Foundation", .{});
                gui_exe.root_module.linkFramework("QuartzCore", .{});
            },
            .linux => {
                gui_exe.root_module.linkSystemLibrary("X11", .{});
                gui_exe.root_module.linkSystemLibrary("pthread", .{});
                gui_exe.root_module.linkSystemLibrary("dl", .{});
            },
            else => {},
        }

        const install_gui = b.addInstallArtifact(gui_exe, .{});

        const gui_step = b.step("gui", "Build the GUI executable");
        gui_step.dependOn(&install_gui.step);

        const run_gui_cmd = b.addRunArtifact(gui_exe);
        run_gui_cmd.step.dependOn(&install_gui.step);
        if (b.args) |args| run_gui_cmd.addArgs(args);

        const run_gui_step = b.step("run-gui", "Run the GUI app");
        run_gui_step.dependOn(&run_gui_cmd.step);
    }

    // ---------------------------------------------------------------------
    // Tests
    // ---------------------------------------------------------------------
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
