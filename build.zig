const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Dependencies
    const ziggy_core = b.dependency("ziggy_core", .{
        .target = target,
        .optimize = optimize,
    });
    const websocket = b.dependency("websocket", .{
        .target = target,
        .optimize = optimize,
    });

    // ---------------------------------------------------------------------
    // CLI Module (always built)
    // ---------------------------------------------------------------------
    const cli_args_module = b.createModule(.{
        .root_source_file = b.path("src/cli/args.zig"),
        .target = target,
        .optimize = optimize,
    });
    cli_args_module.addImport("ziggy-core", ziggy_core.module("ziggy-core"));

    const client_config_module = b.createModule(.{
        .root_source_file = b.path("src/client/config.zig"),
        .target = target,
        .optimize = optimize,
    });
    client_config_module.addImport("ziggy-core", ziggy_core.module("ziggy-core"));

    const session_protocol_module = b.createModule(.{
        .root_source_file = b.path("src/client/session_protocol.zig"),
        .target = target,
        .optimize = optimize,
    });

    const cli_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    cli_module.addImport("websocket", websocket.module("websocket"));
    cli_module.addImport("cli-args", cli_args_module);
    cli_module.addImport("client-config", client_config_module);
    cli_module.addImport("ziggy-core", ziggy_core.module("ziggy-core"));

    const cli_exe = b.addExecutable(.{
        .name = "zss",
        .root_module = cli_module,
    });

    // Install CLI as default step
    b.installArtifact(cli_exe);

    // Also add explicit 'cli' step
    const install_cli = b.addInstallArtifact(cli_exe, .{});
    const cli_step = b.step("cli", "Build the CLI executable (default)");
    cli_step.dependOn(&install_cli.step);

    const run_cli = b.addRunArtifact(cli_exe);
    if (b.args) |args| run_cli.addArgs(args);
    const run_step = b.step("run", "Run the CLI app");
    run_step.dependOn(&run_cli.step);

    // ---------------------------------------------------------------------
    // TUI Module (separate step)
    // ---------------------------------------------------------------------
    const tui_dep = b.lazyDependency("tui", .{
        .target = target,
        .optimize = optimize,
    });

    if (tui_dep) |dep| {
        const websocket_client_module = b.createModule(.{
            .root_source_file = b.path("src/client/websocket.zig"),
            .target = target,
            .optimize = optimize,
        });
        websocket_client_module.addImport("websocket", websocket.module("websocket"));
        websocket_client_module.addImport("ziggy-core", ziggy_core.module("ziggy-core"));

        const tui_module = b.createModule(.{
            .root_source_file = b.path("src/tui/main.zig"),
            .target = target,
            .optimize = optimize,
        });
        tui_module.addImport("tui", dep.module("tui"));
        tui_module.addImport("websocket", websocket.module("websocket"));
        tui_module.addImport("ziggy-core", ziggy_core.module("ziggy-core"));
        tui_module.addImport("cli_args", cli_args_module);
        tui_module.addImport("client_config", client_config_module);
        tui_module.addImport("websocket_client", websocket_client_module);
        tui_module.addImport("session_protocol", session_protocol_module);

        const tui_exe = b.addExecutable(.{
            .name = "zss-tui",
            .root_module = tui_module,
        });

        const install_tui = b.addInstallArtifact(tui_exe, .{});
        const tui_step = b.step("tui", "Build the TUI executable");
        tui_step.dependOn(&install_tui.step);

        const run_tui = b.addRunArtifact(tui_exe);
        if (b.args) |args| run_tui.addArgs(args);
        const run_tui_step = b.step("run-tui", "Run the TUI app");
        run_tui_step.dependOn(&run_tui.step);
    }

    // ---------------------------------------------------------------------
    // GUI Module (separate step, desktop only)
    // ---------------------------------------------------------------------
    const os_tag = target.result.os.tag;
    const desktop_target = os_tag == .linux or os_tag == .windows or os_tag == .macos;

    if (desktop_target) {
        const ziggy_ui = b.dependency("ziggy_ui", .{
            .target = target,
            .optimize = optimize,
        });
        const zgpu = ziggy_ui.builder.dependency("zgpu", .{
            .target = target,
            .optimize = optimize,
        });
        const sdl3 = b.dependency("sdl3", .{
            .target = target,
            .optimize = optimize,
        });

        const ziggy_ui_module = ziggy_ui.module("ziggy-ui");
        const ziggy_ui_src = ziggy_ui.path("src");
        ziggy_ui_module.addIncludePath(ziggy_ui_src);
        ziggy_ui_module.addImport("zgpu", zgpu.module("root"));

        const zsc_bridge_module = b.createModule(.{
            .root_source_file = b.path("src/gui/zsc_bridge.zig"),
            .target = target,
            .optimize = optimize,
        });
        zsc_bridge_module.addIncludePath(sdl3.path("include"));
        ziggy_ui_module.addImport("zsc", zsc_bridge_module);

        const gui_module = b.createModule(.{
            .root_source_file = b.path("src/gui/root.zig"),
            .target = target,
            .optimize = optimize,
        });
        gui_module.addImport("websocket", websocket.module("websocket"));
        gui_module.addImport("ziggy-ui", ziggy_ui_module);
        gui_module.addImport("client-config", client_config_module);
        gui_module.addIncludePath(sdl3.path("include"));
        gui_module.addIncludePath(ziggy_ui_src);

        const gui_exe = b.addExecutable(.{
            .name = "zss-gui",
            .root_module = gui_module,
        });
        gui_exe.linkLibrary(sdl3.artifact("SDL3"));
        gui_exe.root_module.addIncludePath(zgpu.path("libs/dawn/include"));
        gui_exe.addCSourceFile(.{ .file = zgpu.path("src/dawn.cpp"), .flags = &.{"-std=c++17"} });
        gui_exe.addCSourceFile(.{ .file = zgpu.path("src/dawn_proc.c"), .flags = &.{} });
        gui_exe.root_module.link_libcpp = true;

        // Link dawn
        if (os_tag == .windows) {
            if (b.lazyDependency("dawn_x86_64_windows_gnu", .{})) |dawn| {
                gui_exe.addLibraryPath(dawn.path(""));
            }
        } else if (os_tag == .linux) {
            if (target.result.cpu.arch.isX86()) {
                if (b.lazyDependency("dawn_x86_64_linux_gnu", .{})) |dawn| {
                    gui_exe.addLibraryPath(dawn.path(""));
                }
            } else if (target.result.cpu.arch.isAARCH64()) {
                if (b.lazyDependency("dawn_aarch64_linux_gnu", .{})) |dawn| {
                    gui_exe.addLibraryPath(dawn.path(""));
                }
            }
        } else if (os_tag == .macos) {
            if (target.result.cpu.arch.isX86()) {
                if (b.lazyDependency("dawn_x86_64_macos", .{})) |dawn| {
                    gui_exe.addLibraryPath(dawn.path(""));
                }
            } else if (target.result.cpu.arch.isAARCH64()) {
                if (b.lazyDependency("dawn_aarch64_macos", .{})) |dawn| {
                    gui_exe.addLibraryPath(dawn.path(""));
                }
            }
        }
        gui_exe.root_module.linkSystemLibrary("dawn", .{});

        const install_gui = b.addInstallArtifact(gui_exe, .{});
        const gui_step = b.step("gui", "Build the GUI executable");
        gui_step.dependOn(&install_gui.step);

        const run_gui = b.addRunArtifact(gui_exe);
        if (b.args) |args| run_gui.addArgs(args);
        const run_gui_step = b.step("run-gui", "Run the GUI app");
        run_gui_step.dependOn(&run_gui.step);
    }

    // ---------------------------------------------------------------------
    // Tests
    // ---------------------------------------------------------------------
    const tests = b.addTest(.{
        .root_module = cli_module,
        .name = "unit_tests",
    });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}
