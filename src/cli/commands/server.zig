const std = @import("std");
const args = @import("../args.zig");
const tui = @import("../tui.zig");
const linux = @import("../linux_support.zig");

const default_bind = "0.0.0.0";
const default_port: u16 = 18790;
const service_name = "spiderweb.service";

const ConfigSnapshot = struct {
    exists: bool,
    config_path: []u8,
    bind: []u8,
    port: u16,
    spider_web_root: []u8,
    state_directory: []u8,

    fn deinit(self: *ConfigSnapshot, allocator: std.mem.Allocator) void {
        allocator.free(self.config_path);
        allocator.free(self.bind);
        allocator.free(self.spider_web_root);
        allocator.free(self.state_directory);
        self.* = undefined;
    }
};

const StatusSnapshot = struct {
    user: linux.ServiceUser,
    config: ConfigSnapshot,
    auth_present: bool,
    runtime_assets_present: bool,
    local_node_binary_present: bool,
    node_service_installed: bool,
    node_service_active: bool,
    service_installed: bool,
    service_enabled: bool,
    service_active: bool,

    fn deinit(self: *StatusSnapshot, allocator: std.mem.Allocator) void {
        self.user.deinit(allocator);
        self.config.deinit(allocator);
        self.* = undefined;
    }
};

fn loadConfigSnapshot(allocator: std.mem.Allocator, user: linux.ServiceUser) !ConfigSnapshot {
    const config_path = try linux.resolveSpiderwebConfigPath(allocator, user);
    errdefer allocator.free(config_path);
    if (!linux.pathExists(config_path)) {
        return .{
            .exists = false,
            .config_path = config_path,
            .bind = try allocator.dupe(u8, default_bind),
            .port = default_port,
            .spider_web_root = try std.fs.path.join(allocator, &.{ user.home, "Spiderweb" }),
            .state_directory = try allocator.dupe(u8, ".spiderweb-state"),
        };
    }

    const payload = try linux.readFileAllocAny(allocator, config_path, 256 * 1024);
    defer allocator.free(payload);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload, .{});
    defer parsed.deinit();

    const root = if (parsed.value == .object) parsed.value.object else return error.InvalidResponse;
    const server = root.get("server") orelse return error.InvalidResponse;
    const runtime = root.get("runtime") orelse return error.InvalidResponse;

    const bind = if (server == .object)
        if (server.object.get("bind")) |value|
            if (value == .string) value.string else default_bind
        else
            default_bind
    else
        default_bind;
    const port = if (server == .object)
        if (server.object.get("port")) |value|
            switch (value) {
                .integer => if (value.integer > 0) @as(u16, @intCast(value.integer)) else default_port,
                else => default_port,
            }
        else
            default_port
    else
        default_port;
    const spider_web_root = if (runtime == .object)
        if (runtime.object.get("spider_web_root")) |value|
            if (value == .string and value.string.len > 0) value.string else ""
        else
            ""
    else
        "";
    const state_directory = if (runtime == .object)
        if (runtime.object.get("state_directory")) |value|
            if (value == .string and value.string.len > 0) value.string else ".spiderweb-state"
        else
            ".spiderweb-state"
    else
        ".spiderweb-state";

    return .{
        .exists = true,
        .config_path = config_path,
        .bind = try allocator.dupe(u8, bind),
        .port = port,
        .spider_web_root = if (spider_web_root.len > 0)
            try allocator.dupe(u8, spider_web_root)
        else
            try std.fs.path.join(allocator, &.{ user.home, "Spiderweb" }),
        .state_directory = try allocator.dupe(u8, state_directory),
    };
}

fn loadAuthPresence(
    allocator: std.mem.Allocator,
    user: linux.ServiceUser,
    spiderweb_config_bin: []const u8,
) !bool {
    var argv = std.ArrayListUnmanaged([]const u8){};
    defer argv.deinit(allocator);
    try argv.appendSlice(allocator, &.{ spiderweb_config_bin, "auth", "status", "--json" });
    var result = try linux.runCommandAsServiceUser(allocator, user, argv.items);
    defer result.deinit(allocator);
    if (!result.ok()) return false;

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, result.stdout, .{}) catch return false;
    defer parsed.deinit();
    if (parsed.value != .object) return false;
    const access_present = parsed.value.object.get("access_present") orelse return false;
    return access_present == .bool and access_present.bool;
}

fn ensureAuthPresent(
    allocator: std.mem.Allocator,
    user: linux.ServiceUser,
    spiderweb_config_bin: []const u8,
) !bool {
    if (try loadAuthPresence(allocator, user, spiderweb_config_bin)) return false;
    var argv = std.ArrayListUnmanaged([]const u8){};
    defer argv.deinit(allocator);
    try argv.appendSlice(allocator, &.{ spiderweb_config_bin, "auth", "reset", "--yes" });
    var result = try linux.runCommandAsServiceUser(allocator, user, argv.items);
    defer result.deinit(allocator);
    if (!result.ok()) return error.CommandFailed;
    return true;
}

fn runtimeAssetsPresent(allocator: std.mem.Allocator, spiderweb_bin: []const u8) !bool {
    const bin_dir = std.fs.path.dirname(spiderweb_bin) orelse return false;
    const prefix = std.fs.path.dirname(bin_dir) orelse return false;
    const templates = try std.fs.path.join(allocator, &.{ prefix, "share", "spiderweb", "templates" });
    defer allocator.free(templates);
    const venoms = try std.fs.path.join(allocator, &.{ prefix, "share", "spidervenoms", "bundles", "managed-local", "release.json" });
    defer allocator.free(venoms);
    return linux.pathExists(templates) and linux.pathExists(venoms);
}

fn writeSystemServiceUnit(
    allocator: std.mem.Allocator,
    user: linux.ServiceUser,
    spiderweb_bin: []const u8,
    working_dir: []const u8,
) !void {
    const unit_path = try linux.resolveSystemdUnitPath(allocator, user, service_name);
    defer allocator.free(unit_path);
    try linux.makePathAny(working_dir);
    try linux.ensureOwnedByServiceUser(allocator, user, working_dir);
    const payload = try std.fmt.allocPrint(
        allocator,
        \\[Unit]
        \\Description=Spiderweb Workspace Host
        \\After=network.target
        \\
        \\[Service]
        \\Type=simple
        \\User={s}
        \\Environment=HOME={s}
        \\Environment=XDG_CONFIG_HOME={s}
        \\ExecStart={s}
        \\WorkingDirectory={s}
        \\Restart=on-failure
        \\RestartSec=5
        \\
        \\[Install]
        \\WantedBy=multi-user.target
        \\
    ,
        .{ user.name, user.home, user.config_home, spiderweb_bin, working_dir },
    );
    defer allocator.free(payload);
    try linux.writeFileAny(unit_path, payload);
}

fn gatherStatusSnapshot(allocator: std.mem.Allocator) !StatusSnapshot {
    var user = try linux.resolveServiceUser(allocator);
    errdefer user.deinit(allocator);
    var config = try loadConfigSnapshot(allocator, user);
    errdefer config.deinit(allocator);

    const spiderweb_bin = try linux.resolveInstalledBinary(allocator, "spiderweb");
    defer allocator.free(spiderweb_bin);
    const spiderweb_config_bin = try linux.resolveInstalledBinary(allocator, "spiderweb-config");
    defer allocator.free(spiderweb_config_bin);
    const node_binary = try linux.resolveInstalledBinary(allocator, "spiderweb-fs-node");
    defer allocator.free(node_binary);

    const service_state = try linux.systemdState(allocator, user, service_name);
    const node_service_state = try linux.systemdState(allocator, user, "spider-node.service");

    return .{
        .user = user,
        .config = config,
        .auth_present = try loadAuthPresence(allocator, user, spiderweb_config_bin),
        .runtime_assets_present = try runtimeAssetsPresent(allocator, spiderweb_bin),
        .local_node_binary_present = linux.pathExists(node_binary),
        .node_service_installed = node_service_state.installed,
        .node_service_active = node_service_state.active,
        .service_installed = service_state.installed,
        .service_enabled = service_state.enabled,
        .service_active = service_state.active,
    };
}

pub fn runInstallFlow(
    allocator: std.mem.Allocator,
    bind: []const u8,
    port: u16,
) !void {
    try linux.ensureLinuxSupported();
    const stdout = std.fs.File.stdout().deprecatedWriter();
    var user = try linux.resolveServiceUser(allocator);
    defer user.deinit(allocator);

    const spiderweb_bin = try linux.resolveInstalledBinary(allocator, "spiderweb");
    defer allocator.free(spiderweb_bin);
    const spiderweb_config_bin = try linux.resolveInstalledBinary(allocator, "spiderweb-config");
    defer allocator.free(spiderweb_config_bin);

    var first_run = std.ArrayListUnmanaged([]const u8){};
    defer first_run.deinit(allocator);
    try first_run.appendSlice(allocator, &.{ spiderweb_config_bin, "first-run", "--non-interactive" });
    var first_run_result = try linux.runCommandAsServiceUser(allocator, user, first_run.items);
    defer first_run_result.deinit(allocator);
    if (!first_run_result.ok()) return error.CommandFailed;

    var set_server = std.ArrayListUnmanaged([]const u8){};
    defer set_server.deinit(allocator);
    const port_text = try std.fmt.allocPrint(allocator, "{d}", .{port});
    defer allocator.free(port_text);
    try set_server.appendSlice(allocator, &.{ spiderweb_config_bin, "config", "set-server", "--bind", bind, "--port", port_text });
    var set_server_result = try linux.runCommandAsServiceUser(allocator, user, set_server.items);
    defer set_server_result.deinit(allocator);
    if (!set_server_result.ok()) return error.CommandFailed;

    const auth_created = try ensureAuthPresent(allocator, user, spiderweb_config_bin);

    if (user.scope == .system) {
        const working_dir = try std.fs.path.join(allocator, &.{ user.home, "Spiderweb" });
        defer allocator.free(working_dir);
        try writeSystemServiceUnit(allocator, user, spiderweb_bin, working_dir);

        var reload = try linux.systemctlAction(allocator, user, &.{ "daemon-reload" });
        defer reload.deinit(allocator);
        if (!reload.ok()) return error.CommandFailed;
        var enable_now = try linux.systemctlAction(allocator, user, &.{ "enable", "--now", service_name });
        defer enable_now.deinit(allocator);
        if (!enable_now.ok()) return error.CommandFailed;
    } else {
        var install_user = std.ArrayListUnmanaged([]const u8){};
        defer install_user.deinit(allocator);
        try install_user.appendSlice(allocator, &.{ spiderweb_config_bin, "config", "install-service" });
        var install_result = try linux.runCommandAsServiceUser(allocator, user, install_user.items);
        defer install_result.deinit(allocator);
        if (!install_result.ok()) return error.CommandFailed;
    }

    try stdout.print("Spiderweb is ready on this Linux machine\n", .{});
    try stdout.print("  Managed user: {s}\n", .{user.name});
    try stdout.print("  Service: {s}\n", .{if (user.scope == .system) "systemd system service" else "systemd user service"});
    try stdout.print("  Server URL: ws://{s}:{d}\n", .{ bind, port });
    try stdout.print("  Reachability: {s}\n", .{if (linux.serverBindAllowsRemoteConnections(bind)) "other machines can connect" else "local machine only"});
    try stdout.print("  Access auth: {s}\n", .{if (auth_created) "created during setup" else "already present"});
    try stdout.print("  Next: spider workspace create \"Linux Workspace\"\n", .{});
    try stdout.print("  Check health any time with: spider server doctor\n", .{});
}

pub fn executeServerInstall(allocator: std.mem.Allocator, _: args.Options, cmd: args.Command) !void {
    var bind: []const u8 = default_bind;
    var port: u16 = default_port;

    var i: usize = 0;
    while (i < cmd.args.len) : (i += 1) {
        const arg = cmd.args[i];
        if (std.mem.eql(u8, arg, "--bind")) {
            i += 1;
            if (i >= cmd.args.len) return error.InvalidArguments;
            bind = cmd.args[i];
            continue;
        }
        if (std.mem.eql(u8, arg, "--port")) {
            i += 1;
            if (i >= cmd.args.len) return error.InvalidArguments;
            port = try std.fmt.parseInt(u16, cmd.args[i], 10);
            continue;
        }
        return error.InvalidArguments;
    }

    try runInstallFlow(allocator, bind, port);
}

pub fn executeServerStatus(allocator: std.mem.Allocator, options: args.Options, cmd: args.Command) !void {
    _ = options;
    if (cmd.args.len != 0) return error.InvalidArguments;

    const stdout = std.fs.File.stdout().deprecatedWriter();
    var status = try gatherStatusSnapshot(allocator);
    defer status.deinit(allocator);

    try stdout.print("Spiderweb server status\n", .{});
    try stdout.print("  Managed user: {s}\n", .{status.user.name});
    try stdout.print("  Service scope: {s}\n", .{if (status.user.scope == .system) "systemd system" else "systemd user"});
    try stdout.print("  Service installed: {s}\n", .{if (status.service_installed) "yes" else "no"});
    try stdout.print("  Service enabled: {s}\n", .{if (status.service_enabled) "yes" else "no"});
    try stdout.print("  Service active: {s}\n", .{if (status.service_active) "yes" else "no"});
    try stdout.print("  Config: {s}\n", .{status.config.config_path});
    try stdout.print("  Server URL: ws://{s}:{d}\n", .{ status.config.bind, status.config.port });
    try stdout.print("  Reachability: {s}\n", .{if (linux.serverBindAllowsRemoteConnections(status.config.bind)) "other machines can connect" else "local machine only"});
    try stdout.print("  Workspace root: {s}\n", .{status.config.spider_web_root});
    try stdout.print("  Auth present: {s}\n", .{if (status.auth_present) "yes" else "no"});
    try stdout.print("  Runtime assets: {s}\n", .{if (status.runtime_assets_present) "ready" else "missing"});
    try stdout.print("  Local node binary: {s}\n", .{if (status.local_node_binary_present) "present" else "missing"});
    try stdout.print("  Linux node service: {s}\n", .{if (status.node_service_active) "active" else if (status.node_service_installed) "installed" else "not installed"});

    if (status.service_active and status.auth_present and status.runtime_assets_present) {
        try stdout.print("  Summary: ready\n", .{});
    } else {
        try stdout.print("  Summary: needs attention\n", .{});
    }
}

pub fn executeServerDoctor(allocator: std.mem.Allocator, options: args.Options, cmd: args.Command) !void {
    _ = options;
    if (cmd.args.len != 0) return error.InvalidArguments;

    const stdout = std.fs.File.stdout().deprecatedWriter();
    var status = try gatherStatusSnapshot(allocator);
    defer status.deinit(allocator);

    try stdout.print("Spiderweb doctor\n", .{});
    try stdout.print("  [{s}] service installed\n", .{if (status.service_installed) "ready" else "missing"});
    try stdout.print("  [{s}] service running\n", .{if (status.service_active) "ready" else "missing"});
    try stdout.print("  [{s}] access auth\n", .{if (status.auth_present) "ready" else "missing"});
    try stdout.print("  [{s}] runtime assets\n", .{if (status.runtime_assets_present) "ready" else "missing"});
    try stdout.print("  [{s}] reachability ({s})\n", .{
        if (linux.serverBindAllowsRemoteConnections(status.config.bind)) "ready" else "local-only",
        status.config.bind,
    });
    try stdout.print("  [{s}] local node binary\n", .{if (status.local_node_binary_present) "ready" else "missing"});

    if (status.service_active and status.auth_present and status.runtime_assets_present) {
        try stdout.print("  Result: server ready\n", .{});
        try stdout.print("  Next: spider workspace create \"Linux Workspace\"\n", .{});
    } else {
        try stdout.print("  Result: repair needed\n", .{});
        try stdout.print("  Suggested next step: spider server install\n", .{});
    }
}

pub fn executeServerRemove(allocator: std.mem.Allocator, _: args.Options, cmd: args.Command) !void {
    if (cmd.args.len != 0) return error.InvalidArguments;

    const stdout = std.fs.File.stdout().deprecatedWriter();
    var user = try linux.resolveServiceUser(allocator);
    defer user.deinit(allocator);
    const spiderweb_config_bin = try linux.resolveInstalledBinary(allocator, "spiderweb-config");
    defer allocator.free(spiderweb_config_bin);

    if (user.scope == .system) {
        var disable = try linux.systemctlAction(allocator, user, &.{ "disable", "--now", service_name });
        defer disable.deinit(allocator);
        if (!disable.ok()) return error.CommandFailed;
        const unit_path = try linux.resolveSystemdUnitPath(allocator, user, service_name);
        defer allocator.free(unit_path);
        if (linux.pathExists(unit_path)) {
            std.fs.deleteFileAbsolute(unit_path) catch {};
        }
        var reload = try linux.systemctlAction(allocator, user, &.{ "daemon-reload" });
        defer reload.deinit(allocator);
        if (!reload.ok()) return error.CommandFailed;
    } else {
        var uninstall = std.ArrayListUnmanaged([]const u8){};
        defer uninstall.deinit(allocator);
        try uninstall.appendSlice(allocator, &.{ spiderweb_config_bin, "config", "uninstall-service" });
        var uninstall_result = try linux.runCommandAsServiceUser(allocator, user, uninstall.items);
        defer uninstall_result.deinit(allocator);
        if (!uninstall_result.ok()) return error.CommandFailed;
    }

    try stdout.print("Spiderweb service removed. Config and auth were left in place.\n", .{});
}

pub fn runInstallWizard(allocator: std.mem.Allocator) !void {
    tui.printInfo("This sets up Spiderweb as a Linux service on this machine.");
    const bind = try tui.prompt(allocator, "Spiderweb bind address", default_bind);
    defer allocator.free(bind);
    const port_text = try tui.prompt(allocator, "Spiderweb port", "18790");
    defer allocator.free(port_text);
    const port = try std.fmt.parseInt(u16, port_text, 10);
    try runInstallFlow(allocator, bind, port);
}
