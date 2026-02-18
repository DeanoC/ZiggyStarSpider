const std = @import("std");

const GuiArtifact = struct {
    exe: *std.Build.Step.Compile,
    install: *std.Build.Step.InstallArtifact,
};

fn addGuiArtifact(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
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
        .root_source_file = b.path("src/client/config.zig"),
        .target = target,
        .optimize = optimize,
    });

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

    const cli_exe = b.addExecutable(.{
        .name = "zss",
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
    // GUI executables (only when 'gui' step is requested)
    // ---------------------------------------------------------------------
    const gui_step = b.step("gui", "Build Linux and Windows GUI executables");
    
    // Create GUI artifacts lazily when gui_step is evaluated
    const host_arch = target.result.cpu.arch;
    const linux_arch: std.Target.Cpu.Arch = switch (host_arch) {
        .aarch64 => .aarch64,
        else => .x86_64,
    };
    const linux_target = if (target.result.os.tag == .linux)
        target
    else
        b.resolveTargetQuery(.{
            .cpu_arch = linux_arch,
            .os_tag = .linux,
            .abi = .gnu,
        });
    const windows_target = b.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .os_tag = .windows,
        .abi = .gnu,
    });

    const linux_gui = addGuiArtifact(b, linux_target, optimize) orelse unreachable;
    const windows_gui = addGuiArtifact(b, windows_target, optimize) orelse unreachable;

    gui_step.dependOn(&linux_gui.install.step);
    gui_step.dependOn(&windows_gui.install.step);

    const run_gui_step = b.step("run-gui", "Run the GUI app");
    switch (target.result.os.tag) {
        .linux => {
            const run_gui_cmd = b.addRunArtifact(linux_gui.exe);
            run_gui_cmd.step.dependOn(&linux_gui.install.step);
            if (b.args) |args| run_gui_cmd.addArgs(args);
            run_gui_step.dependOn(&run_gui_cmd.step);
        },
        .windows => {
            const run_gui_cmd = b.addRunArtifact(windows_gui.exe);
            run_gui_cmd.step.dependOn(&windows_gui.install.step);
            if (b.args) |args| run_gui_cmd.addArgs(args);
            run_gui_step.dependOn(&run_gui_cmd.step);
        },
        else => {},
    }

    // ---------------------------------------------------------------------
    // TUI executable (opt-in via `zig build tui`)
    // ---------------------------------------------------------------------
    // Only fetch TUI dependency when building TUI target
    const tui_dep = b.lazyDependency("tui", .{
        .target = target,
        .optimize = optimize,
    });
    
    if (tui_dep) |dep| {
        const tui_module = b.createModule(.{
            .root_source_file = b.path("src/tui/main.zig"),
            .target = target,
            .optimize = optimize,
        });
        tui_module.addImport("tui", dep.module("tui"));
        tui_module.addImport("websocket", websocket.module("websocket"));
        tui_module.addImport("ziggy-core", ziggy_core.module("ziggy-core"));
        
        // Add CLI and client modules for TUI
        const cli_args_module = b.createModule(.{
            .root_source_file = b.path("src/cli/args.zig"),
            .target = target,
            .optimize = optimize,
        });
        cli_args_module.addImport("ziggy-core", ziggy_core.module("ziggy-core"));
        tui_module.addImport("cli_args", cli_args_module);
        
        const client_config_module = b.createModule(.{
            .root_source_file = b.path("src/client/config.zig"),
            .target = target,
            .optimize = optimize,
        });
        client_config_module.addImport("ziggy-core", ziggy_core.module("ziggy-core"));
        tui_module.addImport("client_config", client_config_module);
        
        const websocket_client_module = b.createModule(.{
            .root_source_file = b.path("src/client/websocket.zig"),
            .target = target,
            .optimize = optimize,
        });
        websocket_client_module.addImport("websocket", websocket.module("websocket"));
        websocket_client_module.addImport("ziggy-core", ziggy_core.module("ziggy-core"));
        tui_module.addImport("websocket_client", websocket_client_module);

        const tui_exe = b.addExecutable(.{
            .name = "zss-tui",
            .root_module = tui_module,
        });

        const install_tui = b.addInstallArtifact(tui_exe, .{});

        const tui_step = b.step("tui", "Build the TUI executable");
        tui_step.dependOn(&install_tui.step);

        const run_tui_cmd = b.addRunArtifact(tui_exe);
        run_tui_cmd.step.dependOn(&install_tui.step);
        if (b.args) |args| run_tui_cmd.addArgs(args);

        const run_tui_step = b.step("run-tui", "Run the TUI app");
        run_tui_step.dependOn(&run_tui_cmd.step);
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

    // ---------------------------------------------------------------------
    // TUI Tests
    // ---------------------------------------------------------------------
    const tui_test_module = b.createModule(.{
        .root_source_file = b.path("tests/tui/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    
    // Add TUI dependency to test module if available
    if (tui_dep) |dep| {
        tui_test_module.addImport("tui", dep.module("tui"));
        tui_test_module.addImport("websocket", websocket.module("websocket"));
        tui_test_module.addImport("ziggy-core", ziggy_core.module("ziggy-core"));
        
        // Add CLI and client modules for TUI tests
        const cli_args_module_test = b.createModule(.{
            .root_source_file = b.path("src/cli/args.zig"),
            .target = target,
            .optimize = optimize,
        });
        cli_args_module_test.addImport("ziggy-core", ziggy_core.module("ziggy-core"));
        tui_test_module.addImport("cli_args", cli_args_module_test);
        
        const client_config_module_test = b.createModule(.{
            .root_source_file = b.path("src/client/config.zig"),
            .target = target,
            .optimize = optimize,
        });
        client_config_module_test.addImport("ziggy-core", ziggy_core.module("ziggy-core"));
        tui_test_module.addImport("client_config", client_config_module_test);
        
        const websocket_client_module_test = b.createModule(.{
            .root_source_file = b.path("src/client/websocket.zig"),
            .target = target,
            .optimize = optimize,
        });
        websocket_client_module_test.addImport("websocket", websocket.module("websocket"));
        websocket_client_module_test.addImport("ziggy-core", ziggy_core.module("ziggy-core"));
        tui_test_module.addImport("websocket_client", websocket_client_module_test);
    }

    const tui_tests = b.addTest(.{
        .root_module = tui_test_module,
        .name = "tui_tests",
    });

    const run_tui_tests = b.addRunArtifact(tui_tests);
    const test_tui_step = b.step("test-tui", "Run TUI tests (headless)");
    test_tui_step.dependOn(&run_tui_tests.step);

    // TUI test executable for debugging
    const tui_test_exe = b.addExecutable(.{
        .name = "zss-tui-test",
        .root_module = tui_test_module,
    });
    const install_tui_test = b.addInstallArtifact(tui_test_exe, .{});
    
    const tui_test_build_step = b.step("build-tui-test", "Build TUI test executable");
    tui_test_build_step.dependOn(&install_tui_test.step);

    // ---------------------------------------------------------------------
    // TUI Diagnostic Tool
    // ---------------------------------------------------------------------
    const tui_diagnostic_module = b.createModule(.{
        .root_source_file = b.path("src/tui_diagnostic.zig"),
        .target = target,
        .optimize = optimize,
    });
    
    // Add dependencies for diagnostic tool
    tui_diagnostic_module.addImport("websocket", websocket.module("websocket"));
    tui_diagnostic_module.addImport("ziggy-core", ziggy_core.module("ziggy-core"));
    
    const cli_args_module_diag = b.createModule(.{
        .root_source_file = b.path("src/cli/args.zig"),
        .target = target,
        .optimize = optimize,
    });
    cli_args_module_diag.addImport("ziggy-core", ziggy_core.module("ziggy-core"));
    tui_diagnostic_module.addImport("cli_args", cli_args_module_diag);
    
    const client_config_module_diag = b.createModule(.{
        .root_source_file = b.path("src/client/config.zig"),
        .target = target,
        .optimize = optimize,
    });
    client_config_module_diag.addImport("ziggy-core", ziggy_core.module("ziggy-core"));
    tui_diagnostic_module.addImport("client_config", client_config_module_diag);
    
    const websocket_client_module_diag = b.createModule(.{
        .root_source_file = b.path("src/client/websocket.zig"),
        .target = target,
        .optimize = optimize,
    });
    websocket_client_module_diag.addImport("websocket", websocket.module("websocket"));
    websocket_client_module_diag.addImport("ziggy-core", ziggy_core.module("ziggy-core"));
    tui_diagnostic_module.addImport("websocket_client", websocket_client_module_diag);
    
    // Add TUI testing framework module
    const tui_testing_module = b.createModule(.{
        .root_source_file = b.path("tests/tui/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    
    // Add same imports to tui_testing_module as tui_test_module
    if (tui_dep) |dep| {
        tui_testing_module.addImport("tui", dep.module("tui"));
        tui_testing_module.addImport("websocket", websocket.module("websocket"));
        tui_testing_module.addImport("ziggy-core", ziggy_core.module("ziggy-core"));
        
        const cli_args_module_testing = b.createModule(.{
            .root_source_file = b.path("src/cli/args.zig"),
            .target = target,
            .optimize = optimize,
        });
        cli_args_module_testing.addImport("ziggy-core", ziggy_core.module("ziggy-core"));
        tui_testing_module.addImport("cli_args", cli_args_module_testing);
        
        const client_config_module_testing = b.createModule(.{
            .root_source_file = b.path("src/client/config.zig"),
            .target = target,
            .optimize = optimize,
        });
        client_config_module_testing.addImport("ziggy-core", ziggy_core.module("ziggy-core"));
        tui_testing_module.addImport("client_config", client_config_module_testing);
        
        const websocket_client_module_testing = b.createModule(.{
            .root_source_file = b.path("src/client/websocket.zig"),
            .target = target,
            .optimize = optimize,
        });
        websocket_client_module_testing.addImport("websocket", websocket.module("websocket"));
        websocket_client_module_testing.addImport("ziggy-core", ziggy_core.module("ziggy-core"));
        tui_testing_module.addImport("websocket_client", websocket_client_module_testing);
    }
    
    tui_diagnostic_module.addImport("tui_testing", tui_testing_module);
    
    // Add TUI dependency if available (for real TUI types)
    if (tui_dep) |dep| {
        tui_diagnostic_module.addImport("tui", dep.module("tui"));
    }

    const tui_diagnostic_exe = b.addExecutable(.{
        .name = "zss-tui-diagnostic",
        .root_module = tui_diagnostic_module,
    });
    
    const install_tui_diagnostic = b.addInstallArtifact(tui_diagnostic_exe, .{});

    const run_tui_diagnostic_cmd = b.addRunArtifact(tui_diagnostic_exe);
    run_tui_diagnostic_cmd.step.dependOn(&install_tui_diagnostic.step);

    const tui_diagnostic_step = b.step("tui-diagnostic", "Run TUI diagnostic tool (tests components for hang issues)");
    tui_diagnostic_step.dependOn(&run_tui_diagnostic_cmd.step);
}
