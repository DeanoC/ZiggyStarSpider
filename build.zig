const std = @import("std");
const android = @import("android");
const mach_gpu_dawn = @import("mach_gpu_dawn");

const GuiArtifact = struct {
    exe: *std.Build.Step.Compile,
    install: *std.Build.Step.InstallArtifact,
};

fn unzipToOutputDir(b: *std.Build, zip_file: std.Build.LazyPath, basename: []const u8) std.Build.LazyPath {
    if (b.graph.host.result.os.tag == .windows) {
        const unzip = b.addSystemCommand(&.{ "tar", "-xf" });
        unzip.addFileArg(zip_file);
        unzip.addArg("-C");
        return unzip.addOutputDirectoryArg(basename);
    }

    const unzip = b.addSystemCommand(&.{ "unzip", "-q" });
    unzip.addFileArg(zip_file);
    unzip.addArg("-d");
    return unzip.addOutputDirectoryArg(basename);
}

fn downloadToOutputFile(b: *std.Build, url: []const u8, basename: []const u8) std.Build.LazyPath {
    const curl = b.addSystemCommand(&.{ "curl", "-L", "--fail", "--silent", "--show-error", "-o" });
    const out = curl.addOutputFileArg(basename);
    curl.addArg(url);
    return out;
}

fn runCommand(allocator: std.mem.Allocator, cwd: []const u8, argv: []const []const u8) !void {
    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv,
        .cwd = cwd,
    });
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }
    if (result.term.Exited != 0) return error.CommandFailed;
}

fn gitRevision(allocator: std.mem.Allocator, cwd: []const u8) ![]u8 {
    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "git", "rev-parse", "HEAD" },
        .cwd = cwd,
    });
    allocator.free(result.stderr);
    if (result.term.Exited != 0) {
        allocator.free(result.stdout);
        return error.CommandFailed;
    }
    const trimmed = std.mem.trimRight(u8, result.stdout, "\r\n");
    if (trimmed.len == result.stdout.len) return result.stdout;

    const owned = try allocator.dupe(u8, trimmed);
    allocator.free(result.stdout);
    return owned;
}

fn ensureGitCheckout(
    allocator: std.mem.Allocator,
    parent_dir: []const u8,
    checkout_dir: []const u8,
    clone_url: []const u8,
    revision: []const u8,
) !void {
    var existing = std.fs.cwd().openDir(checkout_dir, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            try runCommand(allocator, parent_dir, &.{ "git", "clone", "-c", "core.longpaths=true", clone_url, checkout_dir });
            try runCommand(allocator, checkout_dir, &.{ "git", "checkout", "--quiet", "--force", revision });
            try runCommand(allocator, checkout_dir, &.{ "git", "submodule", "update", "--init", "--recursive" });
            return;
        },
        else => return err,
    };
    existing.close();

    const current_revision = try gitRevision(allocator, checkout_dir);
    defer allocator.free(current_revision);
    if (std.mem.eql(u8, current_revision, revision)) return;

    _ = runCommand(allocator, checkout_dir, &.{ "git", "fetch" }) catch {};
    try runCommand(allocator, checkout_dir, &.{ "git", "checkout", "--quiet", "--force", revision });
    try runCommand(allocator, checkout_dir, &.{ "git", "submodule", "update", "--init", "--recursive" });
}

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
    const spider_protocol = b.dependency("spider_protocol", .{
        .target = target,
        .optimize = optimize,
    });
    const spider_protocol_module = spider_protocol.module("spider-protocol");
    const ziggy_ui = b.dependency("ziggy_ui", .{
        .target = target,
        .optimize = optimize,
    });
    const zgpu = ziggy_ui.builder.dependency("zgpu", .{
        .target = target,
        .optimize = optimize,
    });
    const freetype = b.dependency("freetype", .{
        .target = target,
        .optimize = optimize,
        .enable_brotli = false,
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

    const platform_storage_module = b.createModule(.{
        .root_source_file = b.path("src/platform/storage.zig"),
        .target = target,
        .optimize = optimize,
    });

    const client_config_module = b.createModule(.{
        .root_source_file = b.path("src/client/config_root.zig"),
        .target = target,
        .optimize = optimize,
    });
    client_config_module.addImport("platform_storage", platform_storage_module);
    const control_plane_module = b.createModule(.{
        .root_source_file = b.path("src/client/control_plane.zig"),
        .target = target,
        .optimize = optimize,
    });
    const app_venom_host_source = if (os_tag == .windows)
        b.path("src/client/app_venom_host_windows_stub.zig")
    else
        b.path("src/client/app_venom_host.zig");
    const app_venom_host_module = b.createModule(.{
        .root_source_file = app_venom_host_source,
        .target = target,
        .optimize = optimize,
    });
    app_venom_host_module.addImport("control_plane", control_plane_module);
    if (os_tag != .windows) {
        const spiderweb_node_module = spider_protocol.module("spiderweb_node");
        const spiderweb_fs_module = spider_protocol.module("spiderweb_fs");
        app_venom_host_module.addImport("websocket", websocket.module("websocket"));
        app_venom_host_module.addImport("spider-protocol", spider_protocol_module);
        app_venom_host_module.addImport("spiderweb_node", spiderweb_node_module);
        app_venom_host_module.addImport("spiderweb_fs", spiderweb_fs_module);
    }
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
    gui_module.addImport("platform_storage", platform_storage_module);
    gui_module.addImport("app_venom_host", app_venom_host_module);
    gui_module.addIncludePath(freetype.path("include"));
    gui_module.addIncludePath(sdl3.path("include"));
    gui_module.addIncludePath(ziggy_ui_src);

    const gui_exe = b.addExecutable(.{
        .name = "spider-gui",
        .root_module = gui_module,
    });

    gui_exe.linkLibrary(sdl3.artifact("SDL3"));
    gui_exe.linkLibrary(freetype.artifact("freetype"));
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
    const android_targets = android.standardTargets(b, target);
    const build_android = android_targets.len > 0;
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
    const platform_storage_module = b.createModule(.{
        .root_source_file = b.path("src/platform/storage.zig"),
        .target = target,
        .optimize = optimize,
    });
    const control_plane_module = b.createModule(.{
        .root_source_file = b.path("src/client/control_plane.zig"),
        .target = target,
        .optimize = optimize,
    });

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
    const os_tag = target.result.os.tag;
    const spider_protocol_module = spider_protocol.module("spider-protocol");

    const ziggy_ui = b.dependency("ziggy_ui", .{
        .target = target,
        .optimize = optimize,
    });

    const zgpu = ziggy_ui.builder.dependency("zgpu", .{
        .target = target,
        .optimize = optimize,
    });
    const freetype = b.dependency("freetype", .{
        .target = target,
        .optimize = optimize,
        .enable_brotli = false,
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
    ziggy_ui_module.addIncludePath(freetype.path("include"));

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
        cli_module.addImport("spiderweb_node", spider_protocol.module("spiderweb_node"));
        cli_module.addImport("spiderweb_fs", spider_protocol.module("spiderweb_fs"));
    }
    cli_module.addImport("build_options", build_options_module);
    cli_module.addImport("platform_storage", platform_storage_module);
    cli_module.addImport("control_plane", control_plane_module);

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

    if (build_android) {
        ensureGitCheckout(
            b.allocator,
            b.pathFromRoot("."),
            b.pathFromRoot("libs/dawn"),
            "https://github.com/hexops/dawn",
            "generated-2023-08-10.1691685418",
        ) catch |err| {
            std.debug.panic("failed to prepare Android Dawn checkout: {s}", .{@errorName(err)});
        };

        const android_sdk = android.Sdk.create(b, .{});
        const build_tools_version = b.option(
            []const u8,
            "android-build-tools",
            "Android build tools version (eg. 35.0.0)",
        ) orelse "35.0.0";
        const ndk_version = b.option(
            []const u8,
            "android-ndk",
            "Android NDK version (eg. 27.0.12077973)",
        ) orelse "27.0.12077973";
        const api_level_value = b.option(
            u32,
            "android-api",
            "Android API level (eg. 34)",
        ) orelse 34;

        const apk = android_sdk.createApk(.{
            .build_tools_version = build_tools_version,
            .ndk_version = ndk_version,
            .api_level = @enumFromInt(api_level_value),
        });
        apk.setAndroidManifest(b.path("android/AndroidManifest.xml"));
        const android_res = b.addWriteFiles();
        _ = android_res.addCopyFile(b.path("android/res/values/strings.xml"), "values/strings.xml");
        _ = android_res.addCopyFile(b.path("android/res/values/styles.xml"), "values/styles.xml");
        _ = android_res.addCopyFile(b.path("android/res/drawable/app_icon.png"), "drawable/app_icon.png");
        apk.addResourceDirectory(android_res.getDirectory());
        apk.setKeyStore(android_sdk.createKeyStore(.example));

        const sdl3_android_zip = b.dependency("sdl3_android_zip", .{});
        const sdl3_aar = sdl3_android_zip.path("SDL3-3.2.28.aar");
        const sdl3_aar_extracted = unzipToOutputDir(b, sdl3_aar, "sdl3_android_aar");
        apk.addJavaLibraryJar(sdl3_aar_extracted.path(b, "classes.jar"));

        for (android_targets) |android_target| {
            const android_abi, const sdl3_prefab_dir, const android_system_target = switch (android_target.result.cpu.arch) {
                .aarch64 => .{ "arm64-v8a", "android.arm64-v8a", "aarch64-linux-android" },
                .x86_64 => .{ "x86_64", "android.x86_64", "x86_64-linux-android" },
                else => continue,
            };

            const websocket_android = b.dependency("websocket", .{
                .target = android_target,
                .optimize = optimize,
            });
            const spider_protocol_android = b.dependency("spider_protocol", .{
                .target = android_target,
                .optimize = optimize,
            });
            const spider_protocol_module_android = spider_protocol_android.module("spider-protocol");
            const spiderweb_node_module_android = spider_protocol_android.module("spiderweb_node");
            const spiderweb_fs_module_android = spider_protocol_android.module("spiderweb_fs");
            const ziggy_ui_android = b.dependency("ziggy_ui", .{
                .target = android_target,
                .optimize = optimize,
            });
            const zgpu_android = ziggy_ui_android.builder.dependency("zgpu", .{
                .target = android_target,
                .optimize = optimize,
            });
            const freetype_android = b.dependency("freetype", .{
                .target = android_target,
                .optimize = optimize,
                .enable_brotli = false,
            });
            const sdl3_headers = b.dependency("sdl3", .{
                .target = android_target,
                .optimize = optimize,
            });
            const ziggy_ui_module_android = ziggy_ui_android.module("ziggy-ui");
            const ziggy_ui_src_android = ziggy_ui_android.path("src");
            ziggy_ui_module_android.addIncludePath(ziggy_ui_src_android);
            ziggy_ui_module_android.addIncludePath(freetype_android.path("include"));
            ziggy_ui_module_android.addImport("zgpu", zgpu_android.module("root"));

            const zsc_bridge_module_android = b.createModule(.{
                .root_source_file = b.path("src/gui/zsc_bridge.zig"),
                .target = android_target,
                .optimize = optimize,
            });
            zsc_bridge_module_android.addIncludePath(sdl3_headers.path("include"));
            ziggy_ui_module_android.addImport("zsc", zsc_bridge_module_android);

            const platform_storage_module_android = b.createModule(.{
                .root_source_file = b.path("src/platform/storage.zig"),
                .target = android_target,
                .optimize = optimize,
            });
            const app_venom_host_module_android = b.createModule(.{
                .root_source_file = b.path("src/client/app_venom_host.zig"),
                .target = android_target,
                .optimize = optimize,
            });

            const client_config_module_android = b.createModule(.{
                .root_source_file = b.path("src/client/config_root.zig"),
                .target = android_target,
                .optimize = optimize,
            });
            client_config_module_android.addImport("platform_storage", platform_storage_module_android);
            const control_plane_module_android = b.createModule(.{
                .root_source_file = b.path("src/client/control_plane.zig"),
                .target = android_target,
                .optimize = optimize,
            });
            app_venom_host_module_android.addImport("websocket", websocket_android.module("websocket"));
            app_venom_host_module_android.addImport("control_plane", control_plane_module_android);
            app_venom_host_module_android.addImport("spider-protocol", spider_protocol_module_android);
            app_venom_host_module_android.addImport("spiderweb_node", spiderweb_node_module_android);
            app_venom_host_module_android.addImport("spiderweb_fs", spiderweb_fs_module_android);
            const venom_bindings_module_android = b.createModule(.{
                .root_source_file = b.path("src/client/venom_bindings.zig"),
                .target = android_target,
                .optimize = optimize,
            });
            const ziggy_ui_panels_android = b.dependency("ziggy_ui_panels", .{
                .target = android_target,
                .optimize = optimize,
            });
            const ziggy_ui_panels_module_android = b.createModule(.{
                .root_source_file = ziggy_ui_panels_android.path("src/root.zig"),
                .target = android_target,
                .optimize = optimize,
            });
            ziggy_ui_panels_module_android.addImport("ziggy-ui", ziggy_ui_module_android);

            const android_module = b.createModule(.{
                .root_source_file = b.path("src/main_android.zig"),
                .target = android_target,
                .optimize = optimize,
            });
            android_module.addImport("websocket", websocket_android.module("websocket"));
            android_module.addImport("ziggy-ui", ziggy_ui_module_android);
            android_module.addImport("ziggy-ui-panels", ziggy_ui_panels_module_android);
            android_module.addImport("client-config", client_config_module_android);
            android_module.addImport("control_plane", control_plane_module_android);
            android_module.addImport("venom_bindings", venom_bindings_module_android);
            android_module.addImport("build_options", build_options_module);
            android_module.addImport("platform_storage", platform_storage_module_android);
            android_module.addImport("app_venom_host", app_venom_host_module_android);
            android_module.addIncludePath(freetype_android.path("include"));
            android_module.addIncludePath(sdl3_headers.path("include"));
            android_module.addIncludePath(ziggy_ui_src_android);

            const android_lib = b.addLibrary(.{
                .name = "main",
                .root_module = android_module,
                .linkage = .dynamic,
            });
            android_lib.root_module.link_libc = true;
            android_lib.root_module.linkSystemLibrary("c++_shared", .{});
            android_lib.root_module.addSystemIncludePath(.{ .cwd_relative = apk.ndk.include_path });
            android_lib.linkLibrary(freetype_android.artifact("freetype"));
            android_lib.root_module.addIncludePath(b.path("libs/dawn/out/Debug/gen/include"));
            android_lib.root_module.addIncludePath(b.path("libs/dawn/include"));
            android_lib.addCSourceFile(.{
                .file = zgpu_android.path("src/dawn.cpp"),
                .flags = &.{"-std=c++17"},
            });
            android_lib.addCSourceFile(.{
                .file = b.path("libs/dawn/out/Debug/gen/src/dawn/dawn_proc.c"),
                .flags = &.{},
            });
            mach_gpu_dawn.link(b, android_lib, android_lib.root_module, .{
                .from_source = true,
                .vulkan = true,
                .install_libs = false,
                .debug = optimize == .Debug,
            });

            const sdl3_lib_dir = sdl3_aar_extracted.path(
                b,
                b.fmt("prefab/modules/SDL3-shared/libs/{s}", .{sdl3_prefab_dir}),
            );
            android_lib.root_module.addLibraryPath(sdl3_lib_dir);
            android_lib.root_module.linkSystemLibrary("SDL3", .{});
            apk.addNativeLibraryFile(.{
                .file = sdl3_lib_dir.path(b, "libSDL3.so"),
                .abi = android_abi,
                .dest_name = "libSDL3.so",
            });
            apk.addNativeLibraryFile(.{
                .file = .{
                    .cwd_relative = b.fmt(
                        "{s}/usr/lib/{s}/libc++_shared.so",
                        .{ apk.ndk.sysroot_path, android_system_target },
                    ),
                },
                .abi = android_abi,
                .dest_name = "libc++_shared.so",
            });

            android_lib.root_module.linkSystemLibrary("log", .{});
            android_lib.root_module.linkSystemLibrary("android", .{});
            android_lib.root_module.linkSystemLibrary("dl", .{});

            apk.addArtifact(android_lib);
        }

        const apk_install = apk.addInstallApk();
        const apk_step = b.step("apk", "Build Android APK");
        apk_step.dependOn(&apk_install.step);
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
        test_module.addImport("spiderweb_node", spider_protocol.module("spiderweb_node"));
        test_module.addImport("spiderweb_fs", spider_protocol.module("spiderweb_fs"));
    }
    test_module.addImport("build_options", build_options_module);
    test_module.addImport("platform_storage", platform_storage_module);
    test_module.addImport("control_plane", control_plane_module);

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
