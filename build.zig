const std = @import("std");

const GuiArtifact = struct {
    exe: *std.Build.Step.Compile,
    install: *std.Build.Step.InstallArtifact,
};

fn detectGitRevision(b: *std.Build) []const u8 {
    const result = std.process.Child.run(.{
        .allocator = b.allocator,
        .argv = &.{ "git", "rev-parse", "--short=12", "HEAD" },
        .cwd = b.pathFromRoot("."),
    }) catch return "unknown";
    defer b.allocator.free(result.stdout);
    defer b.allocator.free(result.stderr);

    switch (result.term) {
        .Exited => |code| {
            if (code != 0) return "unknown";
        },
        else => return "unknown",
    }

    const trimmed = std.mem.trim(u8, result.stdout, " \r\n\t");
    if (trimmed.len == 0) return "unknown";
    return b.allocator.dupe(u8, trimmed) catch "unknown";
}

fn addGuiArtifact(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    build_options_module: *std.Build.Module,
) ?GuiArtifact {
    const os_tag = target.result.os.tag;
    const desktop_target = os_tag == .linux or os_tag == .windows or os_tag == .macos;
    if (!desktop_target) return null;

    const websocket = b.dependency("websocket", .{
        .target = target,
        .optimize = optimize,
    });
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

    const client_config_module = b.createModule(.{
        .root_source_file = b.path("src/client/config_root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const control_plane_module = b.createModule(.{
        .root_source_file = b.path("src/client/control_plane.zig"),
        .target = target,
        .optimize = optimize,
    });
    const venom_bindings_module = b.createModule(.{
        .root_source_file = b.path("src/client/venom_bindings.zig"),
        .target = target,
        .optimize = optimize,
    });
    const ziggy_ui_panels = b.dependency("ziggy_ui_panels", .{
        .target = target,
        .optimize = optimize,
    });
    const ziggy_ui_panels_module = b.createModule(.{
        .root_source_file = ziggy_ui_panels.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    ziggy_ui_panels_module.addImport("ziggy-ui", ziggy_ui_module);

    const gui_module = b.createModule(.{
        .root_source_file = b.path("src/gui/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    gui_module.addImport("websocket", websocket.module("websocket"));
    gui_module.addImport("ziggy-ui", ziggy_ui_module);
    gui_module.addImport("ziggy-ui-panels", ziggy_ui_panels_module);
    gui_module.addImport("client-config", client_config_module);
    gui_module.addImport("control_plane", control_plane_module);
    gui_module.addImport("venom_bindings", venom_bindings_module);
    gui_module.addImport("build_options", build_options_module);
    gui_module.addIncludePath(sdl3.path("include"));
    gui_module.addIncludePath(ziggy_ui_src);

    const gui_exe = b.addExecutable(.{
        .name = "spider-gui",
        .root_module = gui_module,
    });

    gui_exe.linkLibrary(sdl3.artifact("SDL3"));
    gui_exe.root_module.addIncludePath(zgpu.path("libs/dawn/include"));
    gui_exe.addCSourceFile(.{ .file = zgpu.path("src/dawn.cpp"), .flags = &.{"-std=c++17"} });
    gui_exe.addCSourceFile(.{ .file = zgpu.path("src/dawn_proc.c"), .flags = &.{} });
    gui_exe.root_module.link_libcpp = true;

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
    // Note: Don't add to default install step - GUI is built only when requested
    return .{
        .exe = gui_exe,
        .install = install_gui,
    };
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const os_tag = target.result.os.tag;
    const git_revision = detectGitRevision(b);
    const terminal_backend_option = b.option(
        []const u8,
        "terminal-backend",
        "GUI terminal renderer backend: plain | ghostty-vt (dynamic/fallback)",
    ) orelse "plain";
    const build_options = b.addOptions();
    build_options.addOption([]const u8, "app_version", "0.1.0");
    build_options.addOption([]const u8, "git_revision", git_revision);
    build_options.addOption([]const u8, "terminal_backend", terminal_backend_option);
    const build_options_module = build_options.createModule();

    const websocket = b.dependency("websocket", .{
        .target = target,
        .optimize = optimize,
    });

    const ziggy_core = b.dependency("ziggy_core", .{
        .target = target,
        .optimize = optimize,
    });
    const spider_protocol = b.dependency("spider_protocol", .{
        .target = target,
        .optimize = optimize,
    });
    const spider_protocol_module = spider_protocol.module("spider-protocol");
    const spiderweb_node_module = spider_protocol.module("spiderweb_node");
    const spiderweb_fs_module = spider_protocol.module("spiderweb_fs");

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
    cli_module.addImport("spider-protocol", spider_protocol_module);
    if (os_tag != .windows) {
        cli_module.addImport("spiderweb_node", spiderweb_node_module);
        cli_module.addImport("spiderweb_fs", spiderweb_fs_module);
    }
    cli_module.addImport("build_options", build_options_module);

    const cli_exe = b.addExecutable(.{
        .name = "spider",
        .root_module = cli_module,
    });

    b.installArtifact(cli_exe);

    // Add explicit 'cli' step for building just the CLI
    const cli_install = b.addInstallArtifact(cli_exe, .{});
    const cli_step = b.step("cli", "Build the CLI executable");
    cli_step.dependOn(&cli_install.step);

    const run_cmd = b.addRunArtifact(cli_exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run the CLI app");
    run_step.dependOn(&run_cmd.step);

    // ---------------------------------------------------------------------
    // GUI executable (host target only)
    // ---------------------------------------------------------------------
    const gui_step = b.step("gui", "Build GUI executable for host target");
    const run_gui_step = b.step("run-gui", "Run the GUI app");

    if (addGuiArtifact(b, target, optimize, build_options_module)) |host_gui| {
        gui_step.dependOn(&host_gui.install.step);

        const run_gui_cmd = b.addRunArtifact(host_gui.exe);
        run_gui_cmd.step.dependOn(&host_gui.install.step);
        if (b.args) |args| run_gui_cmd.addArgs(args);
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
    test_module.addImport("spider-protocol", spider_protocol_module);
    if (os_tag != .windows) {
        test_module.addImport("spiderweb_node", spiderweb_node_module);
        test_module.addImport("spiderweb_fs", spiderweb_fs_module);
    }
    test_module.addImport("build_options", build_options_module);

    const unit_tests = b.addTest(.{
        .root_module = test_module,
    });

    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);

    const control_plane_test_module = b.createModule(.{
        .root_source_file = b.path("src/client/control_plane.zig"),
        .target = target,
        .optimize = optimize,
    });
    const control_plane_tests = b.addTest(.{
        .root_module = control_plane_test_module,
        .name = "control_plane_tests",
    });
    const run_control_plane_tests = b.addRunArtifact(control_plane_tests);
    test_step.dependOn(&run_control_plane_tests.step);
}
