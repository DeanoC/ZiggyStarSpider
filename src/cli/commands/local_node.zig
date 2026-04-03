const std = @import("std");
const args = @import("../args.zig");
const tui = @import("../tui.zig");
const linux = @import("../linux_support.zig");

const service_name = "spider-node.service";
const default_port: u16 = 18891;

const NodeConfigFile = struct {
    bind: []const u8,
    port: u16,
    control_url: []const u8,
    control_auth_token: ?[]const u8 = null,
    pair_mode: []const u8,
    invite_token: ?[]const u8 = null,
    node_name: []const u8,
    state_file: []const u8,
    enable_fs_venom: bool,
    terminal_ids: []const []const u8,
    exports: []const NodeConfigExport,
};

const NodeConfigExport = struct {
    name: []const u8,
    path: []const u8,
    readonly: bool,
};

const ExportEntry = struct {
    name: []u8,
    path: []u8,
    readonly: bool,

    fn deinit(self: *ExportEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.path);
        self.* = undefined;
    }
};

const NodeConfigSnapshot = struct {
    exists: bool,
    config_path: []u8,
    state_file: []u8,
    control_url: ?[]u8 = null,
    control_auth_token_present: bool = false,
    pair_mode: []u8,
    invite_token: ?[]u8 = null,
    node_name: []u8,
    terminal_ids: std.ArrayListUnmanaged([]u8) = .{},
    exports: std.ArrayListUnmanaged(ExportEntry) = .{},

    fn deinit(self: *NodeConfigSnapshot, allocator: std.mem.Allocator) void {
        allocator.free(self.config_path);
        allocator.free(self.state_file);
        if (self.control_url) |value| allocator.free(value);
        allocator.free(self.pair_mode);
        if (self.invite_token) |value| allocator.free(value);
        allocator.free(self.node_name);
        for (self.terminal_ids.items) |item| allocator.free(item);
        self.terminal_ids.deinit(allocator);
        for (self.exports.items) |*entry| entry.deinit(allocator);
        self.exports.deinit(allocator);
        self.* = undefined;
    }
};

const PairStateSnapshot = struct {
    node_id: ?[]u8 = null,
    request_id: ?[]u8 = null,

    fn deinit(self: *PairStateSnapshot, allocator: std.mem.Allocator) void {
        if (self.node_id) |value| allocator.free(value);
        if (self.request_id) |value| allocator.free(value);
        self.* = undefined;
    }
};

fn defaultNodeName(allocator: std.mem.Allocator) ![]u8 {
    var result = try linux.runCommandCapture(allocator, &.{ "hostname" });
    defer result.deinit(allocator);
    if (result.ok()) {
        const trimmed = std.mem.trim(u8, result.stdout, " \t\r\n");
        if (trimmed.len > 0) return allocator.dupe(u8, trimmed);
    }
    return allocator.dupe(u8, "linux-node");
}

fn loadNodeConfigSnapshot(allocator: std.mem.Allocator, user: linux.ServiceUser) !NodeConfigSnapshot {
    const config_path = try linux.resolveLinuxNodeConfigPath(allocator, user);
    errdefer allocator.free(config_path);
    const default_state_path = try linux.resolveLinuxNodeStatePath(allocator, user);
    errdefer allocator.free(default_state_path);
    const default_name = try defaultNodeName(allocator);
    errdefer allocator.free(default_name);

    if (!linux.pathExists(config_path)) {
        return .{
            .exists = false,
            .config_path = config_path,
            .state_file = default_state_path,
            .pair_mode = try allocator.dupe(u8, "request"),
            .node_name = default_name,
        };
    }

    const payload = try linux.readFileAllocAny(allocator, config_path, 256 * 1024);
    defer allocator.free(payload);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidResponse;

    var snapshot = NodeConfigSnapshot{
        .exists = true,
        .config_path = config_path,
        .state_file = default_state_path,
        .pair_mode = try allocator.dupe(u8, "request"),
        .node_name = default_name,
    };
    errdefer snapshot.deinit(allocator);

    const root = parsed.value.object;
    if (root.get("state_file")) |value| {
        if (value == .string and value.string.len > 0) {
            allocator.free(snapshot.state_file);
            snapshot.state_file = try allocator.dupe(u8, value.string);
        }
    }
    if (root.get("control_url")) |value| {
        if (value == .string and value.string.len > 0) {
            snapshot.control_url = try allocator.dupe(u8, value.string);
        }
    }
    if (root.get("control_auth_token")) |value| {
        if (value == .string and value.string.len > 0) {
            snapshot.control_auth_token_present = true;
        }
    }
    if (root.get("pair_mode")) |value| {
        if (value == .string and value.string.len > 0) {
            allocator.free(snapshot.pair_mode);
            snapshot.pair_mode = try allocator.dupe(u8, value.string);
        }
    }
    if (root.get("invite_token")) |value| {
        if (value == .string and value.string.len > 0) {
            snapshot.invite_token = try allocator.dupe(u8, value.string);
        }
    }
    if (root.get("node_name")) |value| {
        if (value == .string and value.string.len > 0) {
            allocator.free(snapshot.node_name);
            snapshot.node_name = try allocator.dupe(u8, value.string);
        }
    }
    if (root.get("terminal_ids")) |value| {
        if (value == .array) {
            for (value.array.items) |entry| {
                if (entry != .string or entry.string.len == 0) continue;
                try snapshot.terminal_ids.append(allocator, try allocator.dupe(u8, entry.string));
            }
        }
    }
    if (root.get("exports")) |value| {
        if (value == .array) {
            for (value.array.items) |entry| {
                if (entry != .object) continue;
                const name_val = entry.object.get("name") orelse continue;
                const path_val = entry.object.get("path") orelse continue;
                if (name_val != .string or path_val != .string) continue;
                try snapshot.exports.append(allocator, .{
                    .name = try allocator.dupe(u8, name_val.string),
                    .path = try allocator.dupe(u8, path_val.string),
                    .readonly = if (entry.object.get("readonly")) |readonly|
                        readonly == .bool and readonly.bool
                    else
                        false,
                });
            }
        }
    }
    if (snapshot.terminal_ids.items.len == 0) {
        try snapshot.terminal_ids.append(allocator, try allocator.dupe(u8, "main"));
    }
    return snapshot;
}

fn loadPairState(allocator: std.mem.Allocator, state_path: []const u8) !PairStateSnapshot {
    if (!linux.pathExists(state_path)) return .{};
    const payload = try linux.readFileAllocAny(allocator, state_path, 128 * 1024);
    defer allocator.free(payload);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return .{};

    var snapshot = PairStateSnapshot{};
    errdefer snapshot.deinit(allocator);
    if (parsed.value.object.get("node_id")) |value| {
        if (value == .string and value.string.len > 0) snapshot.node_id = try allocator.dupe(u8, value.string);
    }
    if (parsed.value.object.get("request_id")) |value| {
        if (value == .string and value.string.len > 0) snapshot.request_id = try allocator.dupe(u8, value.string);
    }
    return snapshot;
}

fn writeSystemServiceUnit(
    allocator: std.mem.Allocator,
    user: linux.ServiceUser,
    fs_node_bin: []const u8,
    config_path: []const u8,
    working_dir: []const u8,
) !void {
    const unit_path = try linux.resolveSystemdUnitPath(allocator, user, service_name);
    defer allocator.free(unit_path);
    try linux.ensureParentPath(unit_path);
    const payload = try std.fmt.allocPrint(
        allocator,
        \\[Unit]
        \\Description=Spider Linux Node
        \\After=network.target
        \\
        \\[Service]
        \\Type=simple
        \\User={s}
        \\Environment=HOME={s}
        \\Environment=XDG_CONFIG_HOME={s}
        \\ExecStart={s} --config {s}
        \\WorkingDirectory={s}
        \\Restart=on-failure
        \\RestartSec=5
        \\
        \\[Install]
        \\WantedBy=multi-user.target
        \\
    ,
        .{ user.name, user.home, user.config_home, fs_node_bin, config_path, working_dir },
    );
    defer allocator.free(payload);
    try linux.writeFileAny(unit_path, payload);
}

fn writeNodeConfig(
    allocator: std.mem.Allocator,
    config_path: []const u8,
    state_path: []const u8,
    control_url: []const u8,
    control_auth_token: ?[]const u8,
    pair_mode: []const u8,
    invite_token: ?[]const u8,
    node_name: []const u8,
    exports: []const []const u8,
) !void {
    const terminal_ids = [_][]const u8{ "main" };
    var export_entries = try allocator.alloc(NodeConfigExport, exports.len);
    defer allocator.free(export_entries);
    for (exports, 0..) |path, idx| {
        const base_name = std.fs.path.basename(path);
        export_entries[idx] = .{
            .name = if (base_name.len > 0) base_name else "export",
            .path = path,
            .readonly = false,
        };
    }

    const payload = try std.json.Stringify.valueAlloc(
        allocator,
        NodeConfigFile{
            .bind = "127.0.0.1",
            .port = default_port,
            .control_url = control_url,
            .control_auth_token = control_auth_token,
            .pair_mode = pair_mode,
            .invite_token = invite_token,
            .node_name = node_name,
            .state_file = state_path,
            .enable_fs_venom = false,
            .terminal_ids = &terminal_ids,
            .exports = export_entries,
        },
        .{ .whitespace = .indent_2 },
    );
    defer allocator.free(payload);
    try linux.writeFileAny(config_path, payload);
}

fn ensureInstallScaffold(allocator: std.mem.Allocator) !struct { user: linux.ServiceUser, config_path: []u8, state_path: []u8 } {
    var user = try linux.resolveServiceUser(allocator);
    errdefer user.deinit(allocator);
    const config_path = try linux.resolveLinuxNodeConfigPath(allocator, user);
    errdefer allocator.free(config_path);
    const state_path = try linux.resolveLinuxNodeStatePath(allocator, user);
    errdefer allocator.free(state_path);
    const working_dir = try linux.resolveSpiderConfigDir(allocator, user);
    defer allocator.free(working_dir);

    try linux.makePathAny(working_dir);
    try linux.ensureOwnedByServiceUser(allocator, user, working_dir);

    if (!linux.pathExists(config_path)) {
        const default_name = try defaultNodeName(allocator);
        defer allocator.free(default_name);
        try writeNodeConfig(allocator, config_path, state_path, "", null, "request", null, default_name, &.{});
        try linux.ensureOwnedByServiceUser(allocator, user, working_dir);
    }

    const fs_node_bin = try linux.resolveInstalledBinary(allocator, "spiderweb-fs-node");
    defer allocator.free(fs_node_bin);

    if (user.scope == .system) {
        try writeSystemServiceUnit(allocator, user, fs_node_bin, config_path, working_dir);
        var reload = try linux.systemctlAction(allocator, user, &.{ "daemon-reload" });
        defer reload.deinit(allocator);
        if (!reload.ok()) return error.CommandFailed;
    } else {
        const unit_path = try linux.resolveSystemdUnitPath(allocator, user, service_name);
        defer allocator.free(unit_path);
        const payload = try std.fmt.allocPrint(
            allocator,
            \\[Unit]
            \\Description=Spider Linux Node
            \\After=network.target
            \\
            \\[Service]
            \\Type=simple
            \\ExecStart={s} --config {s}
            \\WorkingDirectory={s}
            \\Restart=on-failure
            \\RestartSec=5
            \\
            \\[Install]
            \\WantedBy=default.target
            \\
        ,
            .{ fs_node_bin, config_path, working_dir },
        );
        defer allocator.free(payload);
        try linux.writeFileAny(unit_path, payload);
        var reload = try linux.systemctlAction(allocator, user, &.{ "daemon-reload" });
        defer reload.deinit(allocator);
        if (!reload.ok()) return error.CommandFailed;
    }

    return .{ .user = user, .config_path = config_path, .state_path = state_path };
}

pub fn executeLocalNodeInstall(allocator: std.mem.Allocator, _: args.Options, cmd: args.Command) !void {
    if (cmd.args.len != 0) return error.InvalidArguments;
    const stdout = std.fs.File.stdout().deprecatedWriter();
    var install = try ensureInstallScaffold(allocator);
    defer install.user.deinit(allocator);
    defer allocator.free(install.config_path);
    defer allocator.free(install.state_path);
    try stdout.print("Linux node scaffolding is ready\n", .{});
    try stdout.print("  Managed user: {s}\n", .{install.user.name});
    try stdout.print("  Service scope: {s}\n", .{if (install.user.scope == .system) "systemd system" else "systemd user"});
    try stdout.print("  Config: {s}\n", .{install.config_path});
    try stdout.print("  Next: spider local-node connect --control-url ws://host:18790/ --request-approval\n", .{});
}

pub fn executeLocalNodeConnect(allocator: std.mem.Allocator, _: args.Options, cmd: args.Command) !void {
    var control_url: ?[]const u8 = null;
    var control_auth_token: ?[]const u8 = null;
    var prompted_control_auth_token = false;
    var invite_token: ?[]const u8 = null;
    var node_name: ?[]const u8 = null;
    var exports = std.ArrayListUnmanaged([]u8){};
    defer {
        for (exports.items) |item| allocator.free(item);
        exports.deinit(allocator);
    }
    var prompted_control_url = false;

    var i: usize = 0;
    while (i < cmd.args.len) : (i += 1) {
        const arg = cmd.args[i];
        if (std.mem.eql(u8, arg, "--control-url")) {
            i += 1;
            if (i >= cmd.args.len) return error.InvalidArguments;
            control_url = cmd.args[i];
            continue;
        }
        if (std.mem.eql(u8, arg, "--invite-token")) {
            i += 1;
            if (i >= cmd.args.len) return error.InvalidArguments;
            invite_token = cmd.args[i];
            continue;
        }
        if (std.mem.eql(u8, arg, "--control-auth-token")) {
            i += 1;
            if (i >= cmd.args.len) return error.InvalidArguments;
            control_auth_token = cmd.args[i];
            continue;
        }
        if (std.mem.eql(u8, arg, "--request-approval")) {
            continue;
        }
        if (std.mem.eql(u8, arg, "--node-name")) {
            i += 1;
            if (i >= cmd.args.len) return error.InvalidArguments;
            node_name = cmd.args[i];
            continue;
        }
        if (std.mem.eql(u8, arg, "--export")) {
            i += 1;
            if (i >= cmd.args.len) return error.InvalidArguments;
            try exports.append(allocator, try allocator.dupe(u8, cmd.args[i]));
            continue;
        }
        return error.InvalidArguments;
    }

    if (control_url == null and std.fs.File.stdin().isTty()) {
        control_url = try tui.prompt(allocator, "Remote Spiderweb URL", "ws://127.0.0.1:18790/");
        prompted_control_url = true;
    }
    const target_url = control_url orelse return error.InvalidArguments;
    defer if (prompted_control_url) allocator.free(target_url);

    const pair_mode = if (invite_token != null) "invite" else "request";

    const chosen_name = if (node_name) |value|
        try allocator.dupe(u8, value)
    else if (std.fs.File.stdin().isTty())
        try tui.prompt(allocator, "Node name", "linux-node")
    else
        try allocator.dupe(u8, "linux-node");
    defer allocator.free(chosen_name);

    if (control_auth_token == null and std.fs.File.stdin().isTty()) {
        const prompted_token = try tui.prompt(allocator, "Remote Spiderweb access token (optional)", null);
        if (prompted_token.len == 0) {
            allocator.free(prompted_token);
        } else {
            control_auth_token = prompted_token;
            prompted_control_auth_token = true;
        }
    }
    defer if (prompted_control_auth_token) allocator.free(control_auth_token.?);

    if (std.fs.File.stdin().isTty()) {
        while (try tui.confirm("Add an export path for this node?", false)) {
            const export_path = try tui.prompt(allocator, "Export path", null);
            if (export_path.len == 0) {
                allocator.free(export_path);
                break;
            }
            try exports.append(allocator, export_path);
        }
    }

    var install = try ensureInstallScaffold(allocator);
    defer install.user.deinit(allocator);
    defer allocator.free(install.config_path);
    defer allocator.free(install.state_path);

    try writeNodeConfig(
        allocator,
        install.config_path,
        install.state_path,
        target_url,
        control_auth_token,
        if (invite_token != null) "invite" else "request",
        invite_token,
        chosen_name,
        exports.items,
    );
    const working_dir = try linux.resolveSpiderConfigDir(allocator, install.user);
    defer allocator.free(working_dir);
    try linux.ensureOwnedByServiceUser(allocator, install.user, working_dir);

    var enable_now = try linux.systemctlAction(allocator, install.user, &.{ "enable", "--now", service_name });
    defer enable_now.deinit(allocator);
    if (!enable_now.ok()) return error.CommandFailed;

    const stdout = std.fs.File.stdout().deprecatedWriter();
    std.Thread.sleep(1 * std.time.ns_per_s);
    const service_state = try linux.systemdState(allocator, install.user, service_name);
    var pair_state = try loadPairState(allocator, install.state_path);
    defer pair_state.deinit(allocator);

    try stdout.print("Linux node is configured\n", .{});
    try stdout.print("  Managed user: {s}\n", .{install.user.name});
    try stdout.print("  Service scope: {s}\n", .{if (install.user.scope == .system) "systemd system" else "systemd user"});
    try stdout.print("  Control URL: {s}\n", .{target_url});
    try stdout.print("  Pair mode: {s}\n", .{pair_mode});
    try stdout.print("  Node name: {s}\n", .{chosen_name});
    try stdout.print("  Access token: {s}\n", .{if (control_auth_token != null) "configured" else "not provided"});
    try stdout.print("  Terminal: Workspace Shell enabled by default\n", .{});
    try stdout.print("  Service: {s}\n", .{if (service_state.active) "active" else "starting or failed"});
    if (pair_state.node_id) |node_id| {
        try stdout.print("  Pairing: connected as {s}\n", .{node_id});
    } else if (pair_state.request_id) |request_id| {
        try stdout.print("  Pairing: waiting for approval ({s})\n", .{request_id});
    } else {
        try stdout.print("  Pairing: pending service startup\n", .{});
    }
    if (exports.items.len == 0) {
        try stdout.print("  Exports: none\n", .{});
    } else {
        try stdout.print("  Exports:\n", .{});
        for (exports.items) |path| try stdout.print("    - {s}\n", .{path});
    }
    if (pair_state.node_id == null) {
        try stdout.print("  Host next step: spider node pending\n", .{});
        try stdout.print("  Host approve: spider node approve <request-id>\n", .{});
    }
}

pub fn executeLocalNodeStatus(allocator: std.mem.Allocator, _: args.Options, cmd: args.Command) !void {
    if (cmd.args.len != 0) return error.InvalidArguments;
    const stdout = std.fs.File.stdout().deprecatedWriter();
    var user = try linux.resolveServiceUser(allocator);
    defer user.deinit(allocator);
    var config = try loadNodeConfigSnapshot(allocator, user);
    defer config.deinit(allocator);
    var pair_state = try loadPairState(allocator, config.state_file);
    defer pair_state.deinit(allocator);
    const service_state = try linux.systemdState(allocator, user, service_name);

    try stdout.print("Linux node status\n", .{});
    try stdout.print("  Managed user: {s}\n", .{user.name});
    try stdout.print("  Service scope: {s}\n", .{if (user.scope == .system) "systemd system" else "systemd user"});
    try stdout.print("  Service installed: {s}\n", .{if (service_state.installed) "yes" else "no"});
    try stdout.print("  Service active: {s}\n", .{if (service_state.active) "yes" else "no"});
    try stdout.print("  Config: {s}\n", .{config.config_path});
    try stdout.print("  State file: {s}\n", .{config.state_file});
    try stdout.print("  Control URL: {s}\n", .{config.control_url orelse "(not configured)"});
    try stdout.print("  Access token: {s}\n", .{if (config.control_auth_token_present) "configured" else "not configured"});
    try stdout.print("  Pair mode: {s}\n", .{config.pair_mode});
    try stdout.print("  Pairing: {s}\n", .{
        if (pair_state.node_id != null) "connected"
        else if (pair_state.request_id != null) "waiting for approval"
        else "not paired",
    });
    if (pair_state.node_id) |node_id| try stdout.print("  Node ID: {s}\n", .{node_id});
    if (pair_state.request_id) |request_id| try stdout.print("  Request ID: {s}\n", .{request_id});
    try stdout.print("  Node name: {s}\n", .{config.node_name});
    try stdout.print("  Terminal published: {s}\n", .{if (config.terminal_ids.items.len > 0) "yes" else "no"});
    if (config.exports.items.len == 0) {
        try stdout.print("  Exports: none\n", .{});
    } else {
        try stdout.print("  Exports:\n", .{});
        for (config.exports.items) |entry| {
            try stdout.print("    - {s} => {s}\n", .{ entry.name, entry.path });
        }
    }
    if (!service_state.active) {
        try stdout.print("  Suggested next step: spider local-node connect --control-url ws://host:18790/ --request-approval\n", .{});
    }
}

pub fn executeLocalNodeRemove(allocator: std.mem.Allocator, _: args.Options, cmd: args.Command) !void {
    if (cmd.args.len != 0) return error.InvalidArguments;
    const stdout = std.fs.File.stdout().deprecatedWriter();
    var user = try linux.resolveServiceUser(allocator);
    defer user.deinit(allocator);
    const config_path = try linux.resolveLinuxNodeConfigPath(allocator, user);
    defer allocator.free(config_path);
    const state_path = try linux.resolveLinuxNodeStatePath(allocator, user);
    defer allocator.free(state_path);
    const unit_path = try linux.resolveSystemdUnitPath(allocator, user, service_name);
    defer allocator.free(unit_path);

    var disable = try linux.systemctlAction(allocator, user, &.{ "disable", "--now", service_name });
    defer disable.deinit(allocator);
    if (linux.pathExists(unit_path)) {
        if (std.fs.path.isAbsolute(unit_path)) std.fs.deleteFileAbsolute(unit_path) catch {} else std.fs.cwd().deleteFile(unit_path) catch {};
    }
    if (linux.pathExists(config_path)) {
        if (std.fs.path.isAbsolute(config_path)) std.fs.deleteFileAbsolute(config_path) catch {} else std.fs.cwd().deleteFile(config_path) catch {};
    }
    if (linux.pathExists(state_path)) {
        if (std.fs.path.isAbsolute(state_path)) std.fs.deleteFileAbsolute(state_path) catch {} else std.fs.cwd().deleteFile(state_path) catch {};
    }
    var reload = try linux.systemctlAction(allocator, user, &.{ "daemon-reload" });
    defer reload.deinit(allocator);
    try stdout.print("Linux node service and local config removed.\n", .{});
    try stdout.print("Remote node registrations on Spiderweb were left in place.\n", .{});
}

pub fn runConnectWizard(allocator: std.mem.Allocator) !void {
    tui.printInfo("This Linux machine will connect to another Spiderweb as a node.");
    const control_url = try tui.prompt(allocator, "Remote Spiderweb URL", "ws://127.0.0.1:18790/");
    defer allocator.free(control_url);
    const control_auth_token = try tui.prompt(allocator, "Remote Spiderweb access token", null);
    defer allocator.free(control_auth_token);
    const invite = try tui.confirm("Use an invite token instead of request/approve?", false);
    var invite_token: ?[]u8 = null;
    defer if (invite_token) |value| allocator.free(value);
    if (invite) {
        invite_token = try tui.prompt(allocator, "Invite token", null);
    }
    const node_name = try tui.prompt(allocator, "Node name", "linux-node");
    defer allocator.free(node_name);

    const fake_args = args.Command{
        .noun = .local_node,
        .verb = .connect,
        .args = &.{ "--control-url", control_url, if (invite) "--invite-token" else "--request-approval", if (invite) invite_token.? else "" },
    };
    _ = fake_args;
    // Run the real command path with the gathered defaults so the wizard
    // stays thin and the non-interactive command remains canonical.
    var cmd_args = std.ArrayListUnmanaged([]const u8){};
    defer cmd_args.deinit(allocator);
    try cmd_args.appendSlice(allocator, &.{ "--control-url", control_url, "--node-name", node_name });
    if (control_auth_token.len > 0) {
        try cmd_args.appendSlice(allocator, &.{ "--control-auth-token", control_auth_token });
    }
    if (invite) {
        try cmd_args.appendSlice(allocator, &.{ "--invite-token", invite_token.? });
    } else {
        try cmd_args.append(allocator, "--request-approval");
    }
    try executeLocalNodeConnect(allocator, .{}, .{ .noun = .local_node, .verb = .connect, .args = cmd_args.items });
}

test "writeNodeConfig escapes user-provided JSON strings" {
    const allocator = std.testing.allocator;
    const temp_dir = std.testing.tmpDir(.{});
    defer temp_dir.cleanup();

    const config_path = try std.fs.path.join(allocator, &.{ temp_dir.dir_path, "linux-node.json" });
    defer allocator.free(config_path);

    const exports = [_][]const u8{ "/tmp/export\"quote" };
    try writeNodeConfig(
        allocator,
        config_path,
        "/tmp/state\"file.json",
        "ws://host/\"quoted\"",
        "token-with-quote-\"-and-backslash-\\",
        "invite",
        "invite-\"token\"",
        "node-\"name\"",
        &exports,
    );

    const payload = try linux.readFileAllocAny(allocator, config_path, 64 * 1024);
    defer allocator.free(payload);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .object);
}
