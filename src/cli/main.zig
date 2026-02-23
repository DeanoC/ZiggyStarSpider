const std = @import("std");
const args = @import("args.zig");
const logger = @import("ziggy-core").utils.logger;
const WebSocketClient = @import("../client/websocket.zig").WebSocketClient;
const Config = @import("../client/config.zig").Config;
const control_plane = @import("../client/control_plane.zig");
const workspace_types = @import("../client/workspace_types.zig");
const unified = @import("ziggy-spider-protocol").unified;

// Main CLI entry point for ZiggyStarSpider

var g_client: ?WebSocketClient = null;
var g_connected: bool = false;
var g_control_ready: bool = false;
var g_control_request_counter: u64 = 0;
var g_fsrpc_tag: u32 = 1;
var g_fsrpc_fid: u32 = 2;
const fsrpc_default_timeout_ms: i64 = 15_000;
const fsrpc_chat_write_timeout_ms: i64 = 180_000;

pub fn run(allocator: std.mem.Allocator) !void {
    defer cleanupGlobalClient();

    // Parse arguments
    var options = args.parseArgs(allocator) catch |err| {
        if (err == error.InvalidArguments) {
            std.log.err("Invalid arguments. Use --help for usage.", .{});
            std.process.exit(1);
        }
        return err;
    };
    defer options.deinit(allocator);

    // Handle help/version
    if (options.show_help) {
        args.printHelp();
        return;
    }
    if (options.show_version) {
        args.printVersion();
        return;
    }

    // Set log level based on verbose flag
    if (options.verbose) {
        logger.setLevel(.debug);
    }

    // Route to TUI mode if requested
    if (options.tui) {
        // TUI mode is only available when built with the TUI target
        // Use zig build run-tui instead
        std.log.err("TUI mode must be built with 'zig build tui' or run with 'zig build run-tui'", .{});
        return error.TuiNotAvailable;
    }

    if (std.mem.eql(u8, args.gitRevision(), "unknown")) {
        logger.info("ZiggyStarSpider v{s}", .{args.appVersion()});
    } else {
        logger.info("ZiggyStarSpider v{s} ({s})", .{ args.appVersion(), args.gitRevision() });
    }
    logger.info("Server: {s}", .{options.url});
    if (options.project) |p| {
        logger.info("Project: {s}", .{p});
    }

    // Handle commands or interactive mode
    if (options.command) |cmd| {
        // Execute single command
        try executeCommand(allocator, options, cmd);
    } else if (options.interactive) {
        // Enter interactive REPL
        try runInteractive(allocator, options);
    } else {
        // No command and not interactive - show help
        args.printHelp();
    }
}

fn getOrCreateClient(allocator: std.mem.Allocator, url: []const u8) !*WebSocketClient {
    if (g_client == null) {
        g_client = WebSocketClient.init(allocator, url, "");
    }

    if (!g_connected) {
        g_client.?.connect() catch |err| {
            cleanupGlobalClient();
            return err;
        };
        g_connected = true;
        g_control_ready = false;
    }

    return &g_client.?;
}

fn cleanupGlobalClient() void {
    if (g_client) |*client| {
        client.deinit();
    }
    g_client = null;
    g_connected = false;
    g_control_ready = false;
}

fn ensureUnifiedV2Control(allocator: std.mem.Allocator, client: *WebSocketClient) !void {
    if (g_control_ready) return;
    try control_plane.ensureUnifiedV2Connection(allocator, client, &g_control_request_counter);
    g_control_ready = true;
}

fn executeCommand(allocator: std.mem.Allocator, options: args.Options, cmd: args.Command) !void {
    const stdout = std.fs.File.stdout().deprecatedWriter();

    switch (cmd.noun) {
        .chat => {
            switch (cmd.verb) {
                .send => try executeChatSend(allocator, options, cmd),
                .resume_job => try executeChatResume(allocator, options, cmd),
                .history => {
                    try stdout.print("Chat history not yet implemented\n", .{});
                },
                else => {
                    logger.err("Unknown chat verb", .{});
                    return error.InvalidArguments;
                },
            }
        },
        .fs => {
            switch (cmd.verb) {
                .ls => try executeFsLs(allocator, options, cmd),
                .read => try executeFsRead(allocator, options, cmd),
                .write => try executeFsWrite(allocator, options, cmd),
                .stat => try executeFsStat(allocator, options, cmd),
                .tree => try executeFsTree(allocator, options, cmd),
                else => {
                    logger.err("Unknown fs verb", .{});
                    return error.InvalidArguments;
                },
            }
        },
        .project => {
            switch (cmd.verb) {
                .list => try executeProjectList(allocator, options, cmd),
                .use => try executeProjectUse(allocator, options, cmd),
                .create => try executeProjectCreate(allocator, options, cmd),
                .up => try executeProjectUp(allocator, options, cmd),
                .doctor => try executeProjectDoctor(allocator, options, cmd),
                .info => try executeProjectInfo(allocator, options, cmd),
                else => {
                    logger.err("Unknown project verb", .{});
                    return error.InvalidArguments;
                },
            }
        },
        .node => {
            switch (cmd.verb) {
                .list => try executeNodeList(allocator, options, cmd),
                .info => try executeNodeInfo(allocator, options, cmd),
                else => {
                    logger.err("Unknown node verb", .{});
                    return error.InvalidArguments;
                },
            }
        },
        .workspace => {
            switch (cmd.verb) {
                .status => try executeWorkspaceStatus(allocator, options, cmd),
                else => {
                    logger.err("Unknown workspace verb", .{});
                    return error.InvalidArguments;
                },
            }
        },
        .goal => {
            switch (cmd.verb) {
                .list => {
                    try stdout.print("Goal list not yet implemented\n", .{});
                },
                .create => {
                    if (cmd.args.len == 0) {
                        logger.err("goal create requires a description", .{});
                        return error.InvalidArguments;
                    }
                    const desc = try std.mem.join(allocator, " ", cmd.args);
                    defer allocator.free(desc);
                    try stdout.print("Would create goal: \"{s}\"\n", .{desc});
                },
                .complete => {
                    if (cmd.args.len == 0) {
                        logger.err("goal complete requires a goal ID", .{});
                        return error.InvalidArguments;
                    }
                    try stdout.print("Would complete goal: {s}\n", .{cmd.args[0]});
                },
                else => {
                    logger.err("Unknown goal verb", .{});
                    return error.InvalidArguments;
                },
            }
        },
        .task => {
            switch (cmd.verb) {
                .list => {
                    try stdout.print("Task list not yet implemented\n", .{});
                },
                .info => {
                    if (cmd.args.len == 0) {
                        logger.err("task info requires a task ID", .{});
                        return error.InvalidArguments;
                    }
                    try stdout.print("Would show task info: {s}\n", .{cmd.args[0]});
                },
                else => {
                    logger.err("Unknown task verb", .{});
                    return error.InvalidArguments;
                },
            }
        },
        .worker => {
            switch (cmd.verb) {
                .list => {
                    try stdout.print("Worker list not yet implemented\n", .{});
                },
                .logs => {
                    if (cmd.args.len == 0) {
                        logger.err("worker logs requires a worker ID", .{});
                        return error.InvalidArguments;
                    }
                    try stdout.print("Would show logs for worker: {s}\n", .{cmd.args[0]});
                },
                else => {
                    logger.err("Unknown worker verb", .{});
                    return error.InvalidArguments;
                },
            }
        },
        .connect => {
            if (g_connected) {
                try stdout.print("Already connected to {s}\n", .{options.url});
                return;
            }

            const client = try getOrCreateClient(allocator, options.url);
            try ensureUnifiedV2Control(allocator, client);
            try stdout.print("Connected to {s}\n", .{options.url});
        },
        .disconnect => {
            if (!g_connected) {
                try stdout.print("Not connected\n", .{});
                return;
            }

            cleanupGlobalClient();
            try stdout.print("Disconnected\n", .{});
        },
        .status => {
            try stdout.print("Connection status:\n", .{});
            try stdout.print("  Server: {s}\n", .{options.url});
            try stdout.print("  Connected: {s}\n", .{if (g_connected) "Yes" else "No"});
        },
        .help => {
            args.printHelp();
        },
        else => {
            logger.err("Command not yet implemented", .{});
            return error.NotImplemented;
        },
    }
}

fn runInteractive(allocator: std.mem.Allocator, options: args.Options) !void {
    _ = allocator;
    _ = options;

    const stdout = std.fs.File.stdout().deprecatedWriter();

    try stdout.print("\nZiggyStarSpider Interactive Mode\n", .{});
    try stdout.print("Type 'help' for commands, 'quit' to exit.\n\n", .{});

    // TODO: Implement actual interactive REPL with connection
    try stdout.print("Interactive mode not yet implemented.\n", .{});
    try stdout.print("Use command mode for now: ziggystarspider chat send \"hello\"\n", .{});
}

const JsonEnvelope = struct {
    raw: []const u8,
    parsed: std.json.Parsed(std.json.Value),

    fn deinit(self: *JsonEnvelope, allocator: std.mem.Allocator) void {
        self.parsed.deinit();
        allocator.free(self.raw);
        self.* = undefined;
    }
};

const FsrpcWriteResult = struct {
    written: u64,
    job: ?[]u8 = null,
    correlation_id: ?[]u8 = null,

    fn deinit(self: *FsrpcWriteResult, allocator: std.mem.Allocator) void {
        if (self.job) |value| allocator.free(value);
        if (self.correlation_id) |value| allocator.free(value);
        self.* = undefined;
    }
};

fn nextFsrpcTag() u32 {
    const tag = g_fsrpc_tag;
    g_fsrpc_tag +%= 1;
    if (g_fsrpc_tag == 0) g_fsrpc_tag = 1;
    return tag;
}

fn nextFsrpcFid() u32 {
    const fid = g_fsrpc_fid;
    g_fsrpc_fid +%= 1;
    if (g_fsrpc_fid == 0 or g_fsrpc_fid == 1) g_fsrpc_fid = 2;
    return fid;
}

fn nextCorrelationId(allocator: std.mem.Allocator, prefix: []const u8) ![]u8 {
    g_control_request_counter +%= 1;
    return std.fmt.allocPrint(allocator, "{s}-{d}", .{ prefix, g_control_request_counter });
}

fn loadCliConfig(allocator: std.mem.Allocator) !Config {
    return Config.load(allocator) catch try Config.init(allocator);
}

fn resolveProjectSelection(options: args.Options, cfg: *const Config) ?[]const u8 {
    if (options.project) |project_id| return project_id;
    return cfg.selectedProject();
}

fn printWorkspaceStatus(stdout: anytype, status: *const workspace_types.WorkspaceStatus, verbose: bool) !void {
    try stdout.print("Agent: {s}\n", .{status.agent_id});
    if (status.project_id) |project_id| {
        try stdout.print("Project: {s}\n", .{project_id});
    } else {
        try stdout.print("Project: (none)\n", .{});
    }
    if (status.workspace_root) |workspace_root| {
        try stdout.print("Workspace root: {s}\n", .{workspace_root});
    } else {
        try stdout.print("Workspace root: (none)\n", .{});
    }
    const mounted = if (status.actual_mounts.items.len > 0) status.actual_mounts.items else status.mounts.items;
    try stdout.print("Mounts: {d}\n", .{mounted.len});
    if (status.desired_mounts.items.len > 0) {
        try stdout.print("Desired mounts: {d}\n", .{status.desired_mounts.items.len});
    }
    if (status.actual_mounts.items.len > 0) {
        try stdout.print("Actual mounts: {d}\n", .{status.actual_mounts.items.len});
    }
    try stdout.print("Drift: {d}\n", .{if (status.drift_count > 0) status.drift_count else status.drift_items.items.len});
    if (status.reconcile_state) |state| {
        try stdout.print(
            "Reconcile: {s} (queue_depth={d}, last_reconcile_ms={d}, last_success_ms={d})\n",
            .{ state, status.queue_depth, status.last_reconcile_ms, status.last_success_ms },
        );
    }
    if (status.last_error) |value| {
        try stdout.print("Reconcile last error: {s}\n", .{value});
    }

    for (mounted) |mount| {
        try stdout.print(
            "  - {s} <= {s}:{s}",
            .{ mount.mount_path, mount.node_id, mount.export_name },
        );
        if (mount.node_name) |name| {
            try stdout.print(" ({s})", .{name});
        }
        if (mount.fs_url) |url| {
            try stdout.print(" [{s}]", .{url});
        }
        try stdout.print("\n", .{});
    }

    if (!verbose) return;

    if (status.drift_items.items.len > 0) {
        try stdout.print("Drift items:\n", .{});
        for (status.drift_items.items) |item| {
            try stdout.print(
                "  - {s} [{s}] {s}\n",
                .{
                    item.mount_path orelse "(unknown)",
                    item.severity orelse "info",
                    item.message orelse item.kind orelse "(no detail)",
                },
            );
        }
    }
}

fn maybeApplyProjectContext(
    allocator: std.mem.Allocator,
    options: args.Options,
    client: *WebSocketClient,
) !void {
    var cfg = try loadCliConfig(allocator);
    defer cfg.deinit();

    const project_id = resolveProjectSelection(options, &cfg) orelse return;
    try ensureUnifiedV2Control(allocator, client);

    const token = if (options.project_token) |value| value else cfg.getProjectToken(project_id);
    var activated = try control_plane.activateProject(
        allocator,
        client,
        &g_control_request_counter,
        project_id,
        token,
    );
    defer activated.deinit(allocator);
    logger.info(
        "Project context active: {s} ({d} mount(s))",
        .{ project_id, activated.mounts.items.len },
    );
}

fn executeProjectList(allocator: std.mem.Allocator, options: args.Options, cmd: args.Command) !void {
    _ = cmd;
    const stdout = std.fs.File.stdout().deprecatedWriter();
    const client = try getOrCreateClient(allocator, options.url);
    try ensureUnifiedV2Control(allocator, client);

    var cfg = try loadCliConfig(allocator);
    defer cfg.deinit();
    const selected_project = resolveProjectSelection(options, &cfg);

    var projects = try control_plane.listProjects(allocator, client, &g_control_request_counter);
    defer workspace_types.deinitProjectList(allocator, &projects);

    if (projects.items.len == 0) {
        try stdout.print("(no projects)\n", .{});
        return;
    }

    try stdout.print("Projects:\n", .{});
    for (projects.items) |project| {
        const marker = if (selected_project != null and std.mem.eql(u8, selected_project.?, project.id)) "*" else " ";
        try stdout.print(
            "{s} {s}  [{s}]  mounts={d}  name={s}\n",
            .{ marker, project.id, project.status, project.mount_count, project.name },
        );
    }
}

fn executeProjectInfo(allocator: std.mem.Allocator, options: args.Options, cmd: args.Command) !void {
    if (cmd.args.len == 0) {
        logger.err("project info requires a project ID", .{});
        return error.InvalidArguments;
    }

    const stdout = std.fs.File.stdout().deprecatedWriter();
    const client = try getOrCreateClient(allocator, options.url);
    try ensureUnifiedV2Control(allocator, client);

    var detail = try control_plane.getProject(allocator, client, &g_control_request_counter, cmd.args[0]);
    defer detail.deinit(allocator);

    try stdout.print("Project {s}\n", .{detail.id});
    try stdout.print("  Name: {s}\n", .{detail.name});
    try stdout.print("  Vision: {s}\n", .{detail.vision});
    try stdout.print("  Status: {s}\n", .{detail.status});
    try stdout.print("  Created: {d}\n", .{detail.created_at_ms});
    try stdout.print("  Updated: {d}\n", .{detail.updated_at_ms});
    if (detail.project_token) |token| {
        try stdout.print("  Project token: {s}\n", .{token});
    }
    try stdout.print("  Mounts ({d}):\n", .{detail.mounts.items.len});
    for (detail.mounts.items) |mount| {
        try stdout.print("    - {s} <= {s}:{s}\n", .{ mount.mount_path, mount.node_id, mount.export_name });
    }
}

fn resolveOperatorToken(options: args.Options, cfg: *const Config) ?[]const u8 {
    if (options.operator_token) |value| {
        if (value.len > 0) return value;
    }
    if (cfg.auth_token.len > 0) return cfg.auth_token;
    if (cfg.token.len > 0) return cfg.token;
    return null;
}

fn executeProjectCreate(allocator: std.mem.Allocator, options: args.Options, cmd: args.Command) !void {
    if (cmd.args.len == 0) {
        logger.err("project create requires a name", .{});
        return error.InvalidArguments;
    }

    const name = cmd.args[0];
    const vision = if (cmd.args.len > 1)
        try std.mem.join(allocator, " ", cmd.args[1..])
    else
        null;
    defer if (vision) |value| allocator.free(value);

    var cfg = try loadCliConfig(allocator);
    defer cfg.deinit();

    const stdout = std.fs.File.stdout().deprecatedWriter();
    const client = try getOrCreateClient(allocator, options.url);
    try ensureUnifiedV2Control(allocator, client);

    var created = try control_plane.createProject(
        allocator,
        client,
        &g_control_request_counter,
        name,
        vision,
        resolveOperatorToken(options, &cfg),
    );
    defer created.deinit(allocator);

    try cfg.setSelectedProject(created.id);
    if (created.project_token) |token| {
        try cfg.setProjectToken(created.id, token);
    }
    try cfg.save();

    try stdout.print("Created project {s}\n", .{created.id});
    try stdout.print("  Name: {s}\n", .{created.name});
    try stdout.print("  Vision: {s}\n", .{created.vision});
    try stdout.print("  Status: {s}\n", .{created.status});
    try stdout.print("  Created: {d}\n", .{created.created_at_ms});
    if (created.project_token) |token| {
        try stdout.print("  Project token: {s}\n", .{token});
    }
    try stdout.print("  Saved as selected project in local config\n", .{});

    if (created.project_token) |token| {
        var status = control_plane.activateProject(
            allocator,
            client,
            &g_control_request_counter,
            created.id,
            token,
        ) catch |err| {
            logger.warn("project created but activation failed: {s}", .{@errorName(err)});
            return;
        };
        defer status.deinit(allocator);
        if (status.workspace_root) |workspace_root| {
            try stdout.print("  Workspace root: {s}\n", .{workspace_root});
        }
    } else {
        logger.warn("project created without project token in response", .{});
    }
}

fn executeProjectUse(allocator: std.mem.Allocator, options: args.Options, cmd: args.Command) !void {
    if (cmd.args.len == 0) {
        logger.err("project use requires a project ID", .{});
        return error.InvalidArguments;
    }

    const project_id = cmd.args[0];
    const cli_token = if (options.project_token) |token|
        token
    else if (cmd.args.len > 1)
        cmd.args[1]
    else
        null;

    var cfg = try loadCliConfig(allocator);
    defer cfg.deinit();
    if (cli_token) |token| {
        try cfg.setProjectToken(project_id, token);
    }
    try cfg.setSelectedProject(project_id);

    const stdout = std.fs.File.stdout().deprecatedWriter();
    const client = try getOrCreateClient(allocator, options.url);
    try ensureUnifiedV2Control(allocator, client);

    const effective_token = if (cli_token) |token| token else cfg.getProjectToken(project_id);
    var status = try control_plane.activateProject(
        allocator,
        client,
        &g_control_request_counter,
        project_id,
        effective_token,
    );
    defer status.deinit(allocator);
    try stdout.print("Selected and activated project: {s}\n", .{project_id});
    if (status.workspace_root) |workspace_root| {
        try stdout.print("Workspace root: {s}\n", .{workspace_root});
    }

    try cfg.save();
}

const ProjectUpMountSpec = struct {
    mount_path: []const u8,
    node_id: []const u8,
    export_name: []const u8,
};

fn parseProjectUpMountSpec(raw: []const u8) !ProjectUpMountSpec {
    const eq_idx = std.mem.indexOfScalar(u8, raw, '=') orelse return error.InvalidArguments;
    const colon_idx = std.mem.lastIndexOfScalar(u8, raw, ':') orelse return error.InvalidArguments;
    if (eq_idx == 0 or colon_idx <= eq_idx + 1 or colon_idx + 1 >= raw.len) return error.InvalidArguments;
    return .{
        .mount_path = raw[0..eq_idx],
        .node_id = raw[eq_idx + 1 .. colon_idx],
        .export_name = raw[colon_idx + 1 ..],
    };
}

fn executeProjectUp(allocator: std.mem.Allocator, options: args.Options, cmd: args.Command) !void {
    const stdout = std.fs.File.stdout().deprecatedWriter();
    const client = try getOrCreateClient(allocator, options.url);
    try ensureUnifiedV2Control(allocator, client);

    var cfg = try loadCliConfig(allocator);
    defer cfg.deinit();

    var positional_project_name: ?[]const u8 = null;
    var explicit_project_id: ?[]const u8 = options.project;
    var activate = true;
    var mounts = std.ArrayListUnmanaged(ProjectUpMountSpec){};
    defer mounts.deinit(allocator);

    var i: usize = 0;
    while (i < cmd.args.len) : (i += 1) {
        const arg = cmd.args[i];
        if (std.mem.eql(u8, arg, "--mount")) {
            i += 1;
            if (i >= cmd.args.len) return error.InvalidArguments;
            try mounts.append(allocator, try parseProjectUpMountSpec(cmd.args[i]));
            continue;
        }
        if (std.mem.eql(u8, arg, "--project-id")) {
            i += 1;
            if (i >= cmd.args.len) return error.InvalidArguments;
            explicit_project_id = cmd.args[i];
            continue;
        }
        if (std.mem.eql(u8, arg, "--no-activate")) {
            activate = false;
            continue;
        }
        if (std.mem.eql(u8, arg, "--activate")) {
            activate = true;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--")) return error.InvalidArguments;
        if (positional_project_name == null) {
            positional_project_name = arg;
        } else {
            return error.InvalidArguments;
        }
    }

    if (mounts.items.len == 0) {
        var nodes = try control_plane.listNodes(allocator, client, &g_control_request_counter);
        defer workspace_types.deinitNodeList(allocator, &nodes);
        if (nodes.items.len == 0) {
            logger.err("project up requires at least one registered node (or explicit --mount)", .{});
            return error.InvalidArguments;
        }
        try mounts.append(allocator, .{
            .mount_path = "/workspace",
            .node_id = nodes.items[0].node_id,
            .export_name = "work",
        });
    }

    const project_id = explicit_project_id orelse cfg.selectedProject();
    const project_name: ?[]const u8 = if (positional_project_name) |value|
        value
    else if (project_id == null)
        "Workspace"
    else
        null;

    var payload = std.ArrayListUnmanaged(u8){};
    defer payload.deinit(allocator);
    try payload.append(allocator, '{');

    var appended = false;
    if (project_id) |value| {
        const escaped = try unified.jsonEscape(allocator, value);
        defer allocator.free(escaped);
        try payload.writer(allocator).print("\"project_id\":\"{s}\"", .{escaped});
        appended = true;
    }
    if (project_name) |value| {
        const escaped = try unified.jsonEscape(allocator, value);
        defer allocator.free(escaped);
        if (appended) try payload.append(allocator, ',');
        try payload.writer(allocator).print("\"name\":\"{s}\"", .{escaped});
        appended = true;
    }
    if (appended) try payload.append(allocator, ',');
    try payload.writer(allocator).print("\"activate\":{s},\"desired_mounts\":[", .{if (activate) "true" else "false"});

    for (mounts.items, 0..) |mount, idx| {
        if (idx != 0) try payload.append(allocator, ',');
        const escaped_path = try unified.jsonEscape(allocator, mount.mount_path);
        defer allocator.free(escaped_path);
        const escaped_node = try unified.jsonEscape(allocator, mount.node_id);
        defer allocator.free(escaped_node);
        const escaped_export = try unified.jsonEscape(allocator, mount.export_name);
        defer allocator.free(escaped_export);
        try payload.writer(allocator).print(
            "{{\"mount_path\":\"{s}\",\"node_id\":\"{s}\",\"export_name\":\"{s}\"}}",
            .{ escaped_path, escaped_node, escaped_export },
        );
    }
    try payload.appendSlice(allocator, "]}");

    const payload_json = try control_plane.requestControlPayloadJson(
        allocator,
        client,
        &g_control_request_counter,
        "control.project_up",
        payload.items,
    );
    defer allocator.free(payload_json);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload_json, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidResponse;

    const response_project_id_val = parsed.value.object.get("project_id") orelse return error.InvalidResponse;
    if (response_project_id_val != .string) return error.InvalidResponse;
    const response_project_id = response_project_id_val.string;

    const response_token = if (parsed.value.object.get("project_token")) |value|
        if (value == .string) value.string else null
    else
        null;

    try cfg.setSelectedProject(response_project_id);
    if (response_token) |token| {
        try cfg.setProjectToken(response_project_id, token);
    }
    try cfg.save();

    try stdout.print("project up complete\n", .{});
    try stdout.print("  project_id: {s}\n", .{response_project_id});
    try stdout.print(
        "  created: {s}\n",
        .{if (parsed.value.object.get("created")) |value|
            if (value == .bool and value.bool) "true" else "false"
        else
            "false"},
    );
    try stdout.print("  activate: {s}\n", .{if (activate) "true" else "false"});
    try stdout.print("  mounts requested: {d}\n", .{mounts.items.len});

    var status = try control_plane.workspaceStatus(
        allocator,
        client,
        &g_control_request_counter,
        response_project_id,
        response_token,
    );
    defer status.deinit(allocator);
    try printWorkspaceStatus(stdout, &status, false);
}

fn executeProjectDoctor(allocator: std.mem.Allocator, options: args.Options, cmd: args.Command) !void {
    _ = cmd;
    const stdout = std.fs.File.stdout().deprecatedWriter();
    const client = try getOrCreateClient(allocator, options.url);
    try ensureUnifiedV2Control(allocator, client);

    var cfg = try loadCliConfig(allocator);
    defer cfg.deinit();
    const project_id = resolveProjectSelection(options, &cfg);

    var failures: usize = 0;

    var nodes = try control_plane.listNodes(allocator, client, &g_control_request_counter);
    defer workspace_types.deinitNodeList(allocator, &nodes);
    if (nodes.items.len == 0) {
        failures += 1;
        try stdout.print("[FAIL] No nodes are registered. Add at least one node before activation.\n", .{});
    } else {
        try stdout.print("[OK] Registered nodes: {d}\n", .{nodes.items.len});
    }

    var projects = try control_plane.listProjects(allocator, client, &g_control_request_counter);
    defer workspace_types.deinitProjectList(allocator, &projects);
    if (projects.items.len == 0) {
        failures += 1;
        try stdout.print("[FAIL] No projects exist. Run `project up <name>`.\n", .{});
    } else {
        try stdout.print("[OK] Projects: {d}\n", .{projects.items.len});
    }

    if (project_id == null) {
        failures += 1;
        try stdout.print("[FAIL] No project selected. Use `--project` or `project use`.\n", .{});
    } else {
        var status = try control_plane.workspaceStatus(
            allocator,
            client,
            &g_control_request_counter,
            project_id,
            if (project_id) |id|
                if (options.project_token) |token|
                    token
                else
                    cfg.getProjectToken(id)
            else
                null,
        );
        defer status.deinit(allocator);
        if (status.mounts.items.len == 0 and status.actual_mounts.items.len == 0) {
            failures += 1;
            try stdout.print("[FAIL] Selected project has no active mounts.\n", .{});
        } else {
            try stdout.print("[OK] Active mounts: {d}\n", .{if (status.actual_mounts.items.len > 0) status.actual_mounts.items.len else status.mounts.items.len});
        }
        const drift_count = if (status.drift_count > 0) status.drift_count else status.drift_items.items.len;
        if (drift_count > 0) {
            failures += 1;
            try stdout.print("[FAIL] Workspace drift detected: {d}\n", .{drift_count});
        } else {
            try stdout.print("[OK] Workspace drift: none\n", .{});
        }

        var reconcile = try control_plane.reconcileStatus(
            allocator,
            client,
            &g_control_request_counter,
            project_id,
        );
        defer reconcile.deinit(allocator);
        if (reconcile.queue_depth > 0 or reconcile.failed_ops.items.len > 0) {
            failures += 1;
            try stdout.print(
                "[FAIL] Reconcile queue_depth={d} failed_ops={d}\n",
                .{ reconcile.queue_depth, reconcile.failed_ops.items.len },
            );
        } else {
            try stdout.print("[OK] Reconcile queue empty\n", .{});
        }
    }

    if (failures == 0) {
        try stdout.print("project doctor: ready\n", .{});
    } else {
        try stdout.print("project doctor: {d} issue(s) detected\n", .{failures});
        return error.InvalidResponse;
    }
}

fn executeNodeList(allocator: std.mem.Allocator, options: args.Options, cmd: args.Command) !void {
    _ = cmd;
    const stdout = std.fs.File.stdout().deprecatedWriter();
    const client = try getOrCreateClient(allocator, options.url);
    try ensureUnifiedV2Control(allocator, client);

    var nodes = try control_plane.listNodes(allocator, client, &g_control_request_counter);
    defer workspace_types.deinitNodeList(allocator, &nodes);
    if (nodes.items.len == 0) {
        try stdout.print("(no nodes)\n", .{});
        return;
    }

    try stdout.print("Nodes:\n", .{});
    for (nodes.items) |node| {
        try stdout.print(
            "  - {s} ({s})  fs={s}  lease_expires_at_ms={d}\n",
            .{ node.node_id, node.node_name, node.fs_url, node.lease_expires_at_ms },
        );
    }
}

fn executeNodeInfo(allocator: std.mem.Allocator, options: args.Options, cmd: args.Command) !void {
    if (cmd.args.len == 0) {
        logger.err("node info requires a node ID", .{});
        return error.InvalidArguments;
    }

    const stdout = std.fs.File.stdout().deprecatedWriter();
    const client = try getOrCreateClient(allocator, options.url);
    try ensureUnifiedV2Control(allocator, client);

    var node = try control_plane.getNode(allocator, client, &g_control_request_counter, cmd.args[0]);
    defer node.deinit(allocator);
    try stdout.print("Node {s}\n", .{node.node_id});
    try stdout.print("  Name: {s}\n", .{node.node_name});
    try stdout.print("  FS URL: {s}\n", .{node.fs_url});
    try stdout.print("  Joined: {d}\n", .{node.joined_at_ms});
    try stdout.print("  Last seen: {d}\n", .{node.last_seen_ms});
    try stdout.print("  Lease expires: {d}\n", .{node.lease_expires_at_ms});
}

fn executeWorkspaceStatus(allocator: std.mem.Allocator, options: args.Options, cmd: args.Command) !void {
    const stdout = std.fs.File.stdout().deprecatedWriter();
    const client = try getOrCreateClient(allocator, options.url);
    try ensureUnifiedV2Control(allocator, client);

    var cfg = try loadCliConfig(allocator);
    defer cfg.deinit();
    const project_id = if (cmd.args.len > 0)
        cmd.args[0]
    else
        resolveProjectSelection(options, &cfg);

    var status = try control_plane.workspaceStatus(
        allocator,
        client,
        &g_control_request_counter,
        project_id,
        if (project_id) |id|
            if (options.project_token) |token|
                token
            else
                cfg.getProjectToken(id)
        else
            null,
    );
    defer status.deinit(allocator);
    try printWorkspaceStatus(stdout, &status, options.verbose);

    if (options.verbose) {
        var reconcile = try control_plane.reconcileStatus(
            allocator,
            client,
            &g_control_request_counter,
            status.project_id,
        );
        defer reconcile.deinit(allocator);
        try stdout.print(
            "Reconcile diagnostics: state={s} queue_depth={d} failed_ops_total={d} cycles_total={d}\n",
            .{
                reconcile.reconcile_state orelse "(unknown)",
                reconcile.queue_depth,
                reconcile.failed_ops_total,
                reconcile.cycles_total,
            },
        );
        if (reconcile.last_error) |value| {
            try stdout.print("Reconcile diagnostics last_error: {s}\n", .{value});
        }
        if (reconcile.failed_ops.items.len > 0) {
            try stdout.print("Reconcile failed ops:\n", .{});
            for (reconcile.failed_ops.items) |op| {
                try stdout.print("  - {s}\n", .{op});
            }
        }
    }
}

fn executeChatSend(allocator: std.mem.Allocator, options: args.Options, cmd: args.Command) !void {
    if (cmd.args.len == 0) {
        logger.err("chat send requires a message", .{});
        return error.InvalidArguments;
    }

    const stdout = std.fs.File.stdout().deprecatedWriter();
    const message = try std.mem.join(allocator, " ", cmd.args);
    defer allocator.free(message);

    const client = try getOrCreateClient(allocator, options.url);
    try maybeApplyProjectContext(allocator, options, client);
    logger.info("Negotiating FS-RPC session...", .{});
    try fsrpcBootstrap(allocator, client);

    logger.info("Submitting chat job...", .{});
    const chat_input_fid = try fsrpcWalkPath(allocator, client, "/capabilities/chat/control/input");
    defer fsrpcClunkBestEffort(allocator, client, chat_input_fid);
    try fsrpcOpen(allocator, client, chat_input_fid, "rw");

    const correlation_id = try nextCorrelationId(allocator, "chat");
    defer allocator.free(correlation_id);

    var write = try fsrpcWriteText(allocator, client, chat_input_fid, message, correlation_id);
    defer write.deinit(allocator);
    const job_name = write.job orelse {
        logger.err("chat send did not return a job identifier", .{});
        return error.InvalidResponse;
    };

    const result_path = try std.fmt.allocPrint(allocator, "/jobs/{s}/result.txt", .{job_name});
    defer allocator.free(result_path);

    const result_fid = try fsrpcWalkPath(allocator, client, result_path);
    defer fsrpcClunkBestEffort(allocator, client, result_fid);
    try fsrpcOpen(allocator, client, result_fid, "r");

    logger.info("Waiting for chat result...", .{});
    const content = fsrpcReadAllText(allocator, client, result_fid) catch |err| {
        try stdout.print("Sent: \"{s}\"\n", .{message});
        try stdout.print("Chat job queued: {s}\n", .{job_name});
        if (write.correlation_id) |value| {
            try stdout.print("Correlation ID: {s}\n", .{value});
        }
        try stdout.print("Result is not ready yet ({s}). Resume with: ziggystarspider chat resume {s}\n", .{ @errorName(err), job_name });
        return;
    };
    defer allocator.free(content);

    try stdout.print("Sent: \"{s}\"\n", .{message});
    if (write.correlation_id) |value| {
        try stdout.print("Correlation ID: {s}\n", .{value});
    }
    if (content.len == 0) {
        try stdout.print("AI: (no content)\n", .{});
    } else {
        try stdout.print("AI: {s}\n", .{content});
    }
}

const JobStatusInfo = struct {
    state: []u8,
    correlation_id: ?[]u8 = null,
    error_text: ?[]u8 = null,

    fn deinit(self: *JobStatusInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.state);
        if (self.correlation_id) |value| allocator.free(value);
        if (self.error_text) |value| allocator.free(value);
        self.* = undefined;
    }
};

fn parseJobStatusInfo(allocator: std.mem.Allocator, status_json: []const u8) !JobStatusInfo {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, status_json, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidResponse;
    const state_val = parsed.value.object.get("state") orelse return error.InvalidResponse;
    if (state_val != .string or state_val.string.len == 0) return error.InvalidResponse;
    return .{
        .state = try allocator.dupe(u8, state_val.string),
        .correlation_id = if (parsed.value.object.get("correlation_id")) |value|
            if (value == .string and value.string.len > 0) try allocator.dupe(u8, value.string) else null
        else
            null,
        .error_text = if (parsed.value.object.get("error")) |value|
            if (value == .string and value.string.len > 0) try allocator.dupe(u8, value.string) else null
        else
            null,
    };
}

fn readJobStatus(allocator: std.mem.Allocator, client: *WebSocketClient, job_name: []const u8) !JobStatusInfo {
    const status_path = try std.fmt.allocPrint(allocator, "/jobs/{s}/status.json", .{job_name});
    defer allocator.free(status_path);
    const status_fid = try fsrpcWalkPath(allocator, client, status_path);
    defer fsrpcClunkBestEffort(allocator, client, status_fid);
    try fsrpcOpen(allocator, client, status_fid, "r");
    const status_json = try fsrpcReadAllText(allocator, client, status_fid);
    defer allocator.free(status_json);
    return parseJobStatusInfo(allocator, status_json);
}

fn executeChatResume(allocator: std.mem.Allocator, options: args.Options, cmd: args.Command) !void {
    const stdout = std.fs.File.stdout().deprecatedWriter();
    const client = try getOrCreateClient(allocator, options.url);
    try maybeApplyProjectContext(allocator, options, client);
    try fsrpcBootstrap(allocator, client);

    if (cmd.args.len == 0) {
        const jobs_fid = try fsrpcWalkPath(allocator, client, "/jobs");
        defer fsrpcClunkBestEffort(allocator, client, jobs_fid);
        try fsrpcOpen(allocator, client, jobs_fid, "r");
        const listing = try fsrpcReadAllText(allocator, client, jobs_fid);
        defer allocator.free(listing);

        if (listing.len == 0) {
            try stdout.print("(no jobs)\n", .{});
            return;
        }
        var iter = std.mem.splitScalar(u8, listing, '\n');
        while (iter.next()) |raw| {
            const job = std.mem.trim(u8, raw, " \t\r\n");
            if (job.len == 0) continue;
            var status = readJobStatus(allocator, client, job) catch |err| {
                try stdout.print("{s}: status unavailable ({s})\n", .{ job, @errorName(err) });
                continue;
            };
            defer status.deinit(allocator);
            try stdout.print("{s}: {s}", .{ job, status.state });
            if (status.correlation_id) |value| {
                try stdout.print(" correlation={s}", .{value});
            }
            if (status.error_text) |value| {
                try stdout.print(" error={s}", .{value});
            }
            try stdout.print("\n", .{});
        }
        return;
    }

    const job_name = cmd.args[0];
    var status = try readJobStatus(allocator, client, job_name);
    defer status.deinit(allocator);
    try stdout.print("Job {s} state: {s}\n", .{ job_name, status.state });
    if (status.correlation_id) |value| {
        try stdout.print("Correlation ID: {s}\n", .{value});
    }
    if (!std.mem.eql(u8, status.state, "done") and !std.mem.eql(u8, status.state, "failed")) {
        try stdout.print("Result not ready yet\n", .{});
        return;
    }

    const result_path = try std.fmt.allocPrint(allocator, "/jobs/{s}/result.txt", .{job_name});
    defer allocator.free(result_path);
    const result_fid = try fsrpcWalkPath(allocator, client, result_path);
    defer fsrpcClunkBestEffort(allocator, client, result_fid);
    try fsrpcOpen(allocator, client, result_fid, "r");
    const content = try fsrpcReadAllText(allocator, client, result_fid);
    defer allocator.free(content);

    if (content.len == 0) {
        try stdout.print("AI: (no content)\n", .{});
    } else {
        try stdout.print("AI: {s}\n", .{content});
    }
}

fn executeFsLs(allocator: std.mem.Allocator, options: args.Options, cmd: args.Command) !void {
    const stdout = std.fs.File.stdout().deprecatedWriter();
    const client = try getOrCreateClient(allocator, options.url);
    try maybeApplyProjectContext(allocator, options, client);
    try fsrpcBootstrap(allocator, client);

    const path = if (cmd.args.len > 0) cmd.args[0] else "/";
    const fid = try fsrpcWalkPath(allocator, client, path);
    defer fsrpcClunkBestEffort(allocator, client, fid);

    try fsrpcOpen(allocator, client, fid, "r");
    const content = try fsrpcReadAllText(allocator, client, fid);
    defer allocator.free(content);

    if (content.len == 0) {
        try stdout.print("(empty)\n", .{});
    } else {
        try stdout.print("{s}\n", .{content});
    }
}

fn executeFsRead(allocator: std.mem.Allocator, options: args.Options, cmd: args.Command) !void {
    if (cmd.args.len == 0) {
        logger.err("fs read requires a path", .{});
        return error.InvalidArguments;
    }

    const stdout = std.fs.File.stdout().deprecatedWriter();
    const client = try getOrCreateClient(allocator, options.url);
    try maybeApplyProjectContext(allocator, options, client);
    try fsrpcBootstrap(allocator, client);

    const fid = try fsrpcWalkPath(allocator, client, cmd.args[0]);
    defer fsrpcClunkBestEffort(allocator, client, fid);

    try fsrpcOpen(allocator, client, fid, "r");
    const content = try fsrpcReadAllText(allocator, client, fid);
    defer allocator.free(content);
    try stdout.print("{s}\n", .{content});
}

fn executeFsWrite(allocator: std.mem.Allocator, options: args.Options, cmd: args.Command) !void {
    if (cmd.args.len < 2) {
        logger.err("fs write requires a path and content", .{});
        return error.InvalidArguments;
    }

    const stdout = std.fs.File.stdout().deprecatedWriter();
    const client = try getOrCreateClient(allocator, options.url);
    try maybeApplyProjectContext(allocator, options, client);
    try fsrpcBootstrap(allocator, client);

    const fid = try fsrpcWalkPath(allocator, client, cmd.args[0]);
    defer fsrpcClunkBestEffort(allocator, client, fid);

    const content = try std.mem.join(allocator, " ", cmd.args[1..]);
    defer allocator.free(content);

    try fsrpcOpen(allocator, client, fid, "rw");
    var write = try fsrpcWriteText(allocator, client, fid, content, null);
    defer write.deinit(allocator);
    try stdout.print("wrote {d} byte(s)\n", .{write.written});
}

fn executeFsStat(allocator: std.mem.Allocator, options: args.Options, cmd: args.Command) !void {
    if (cmd.args.len == 0) {
        logger.err("fs stat requires a path", .{});
        return error.InvalidArguments;
    }

    const stdout = std.fs.File.stdout().deprecatedWriter();
    const client = try getOrCreateClient(allocator, options.url);
    try maybeApplyProjectContext(allocator, options, client);
    try fsrpcBootstrap(allocator, client);

    const fid = try fsrpcWalkPath(allocator, client, cmd.args[0]);
    defer fsrpcClunkBestEffort(allocator, client, fid);

    const stat_json = try fsrpcStatRaw(allocator, client, fid);
    defer allocator.free(stat_json);
    try stdout.print("{s}\n", .{stat_json});
}

fn executeFsTree(allocator: std.mem.Allocator, options: args.Options, cmd: args.Command) !void {
    const stdout = std.fs.File.stdout().deprecatedWriter();
    const client = try getOrCreateClient(allocator, options.url);
    try maybeApplyProjectContext(allocator, options, client);
    try fsrpcBootstrap(allocator, client);

    var tree_opts = FsTreeOptions{};
    var i: usize = 0;
    while (i < cmd.args.len) : (i += 1) {
        const arg = cmd.args[i];
        if (std.mem.eql(u8, arg, "--max-depth")) {
            i += 1;
            if (i >= cmd.args.len) return error.InvalidArguments;
            tree_opts.max_depth = try std.fmt.parseInt(usize, cmd.args[i], 10);
            continue;
        }
        if (std.mem.eql(u8, arg, "--files-only")) {
            tree_opts.files_only = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--dirs-only")) {
            tree_opts.dirs_only = true;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--")) return error.InvalidArguments;
        if (tree_opts.root_path_set) return error.InvalidArguments;
        tree_opts.root_path = arg;
        tree_opts.root_path_set = true;
    }
    if (tree_opts.files_only and tree_opts.dirs_only) return error.InvalidArguments;

    const root_label = if (std.mem.eql(u8, tree_opts.root_path, "")) "/" else tree_opts.root_path;
    try fsTreeWalk(
        allocator,
        client,
        stdout,
        tree_opts.root_path,
        root_label,
        0,
        tree_opts,
    );
}

const FsTreeOptions = struct {
    root_path: []const u8 = "/",
    root_path_set: bool = false,
    max_depth: usize = 8,
    files_only: bool = false,
    dirs_only: bool = false,
};

fn fsTreeWalk(
    allocator: std.mem.Allocator,
    client: *WebSocketClient,
    stdout: anytype,
    path: []const u8,
    display_name: []const u8,
    depth: usize,
    opts: FsTreeOptions,
) !void {
    const fid = try fsrpcWalkPath(allocator, client, path);
    defer fsrpcClunkBestEffort(allocator, client, fid);
    const is_dir = try fsrpcFidIsDir(allocator, client, fid);

    const print_entry = if (is_dir) !opts.files_only else !opts.dirs_only;
    if (print_entry) {
        var indent_idx: usize = 0;
        while (indent_idx < depth) : (indent_idx += 1) {
            try stdout.print("  ", .{});
        }
        try stdout.print("{s}\n", .{display_name});
    }

    if (!is_dir or depth >= opts.max_depth) return;
    try fsrpcOpen(allocator, client, fid, "r");
    const listing = try fsrpcReadAllText(allocator, client, fid);
    defer allocator.free(listing);

    var iter = std.mem.splitScalar(u8, listing, '\n');
    while (iter.next()) |raw| {
        const entry = std.mem.trim(u8, raw, " \t\r\n");
        if (entry.len == 0) continue;
        if (std.mem.eql(u8, entry, ".") or std.mem.eql(u8, entry, "..")) continue;

        const child_path = try joinFsPath(allocator, path, entry);
        defer allocator.free(child_path);
        try fsTreeWalk(
            allocator,
            client,
            stdout,
            child_path,
            entry,
            depth + 1,
            opts,
        );
    }
}

fn fsrpcFidIsDir(allocator: std.mem.Allocator, client: *WebSocketClient, fid: u32) !bool {
    const stat_json = try fsrpcStatRaw(allocator, client, fid);
    defer allocator.free(stat_json);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, stat_json, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidResponse;
    const kind = parsed.value.object.get("kind") orelse return error.InvalidResponse;
    if (kind != .string) return error.InvalidResponse;
    return std.mem.eql(u8, kind.string, "dir");
}

fn joinFsPath(allocator: std.mem.Allocator, parent: []const u8, child: []const u8) ![]u8 {
    if (std.mem.eql(u8, parent, "/")) {
        return std.fmt.allocPrint(allocator, "/{s}", .{child});
    }
    if (std.mem.endsWith(u8, parent, "/")) {
        return std.fmt.allocPrint(allocator, "{s}{s}", .{ parent, child });
    }
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ parent, child });
}

fn fsrpcBootstrap(allocator: std.mem.Allocator, client: *WebSocketClient) !void {
    try ensureUnifiedV2Control(allocator, client);

    const version_tag = nextFsrpcTag();
    const version_req = try std.fmt.allocPrint(
        allocator,
        "{{\"channel\":\"fsrpc\",\"type\":\"fsrpc.t_version\",\"tag\":{d},\"msize\":1048576,\"version\":\"styx-lite-1\"}}",
        .{version_tag},
    );
    defer allocator.free(version_req);
    var version = try sendAndAwaitFsrpcWithTimeout(allocator, client, version_req, version_tag, fsrpc_default_timeout_ms);
    defer version.deinit(allocator);
    try ensureFsrpcOk(&version);

    const attach_tag = nextFsrpcTag();
    const attach_req = try std.fmt.allocPrint(
        allocator,
        "{{\"channel\":\"fsrpc\",\"type\":\"fsrpc.t_attach\",\"tag\":{d},\"fid\":1}}",
        .{attach_tag},
    );
    defer allocator.free(attach_req);
    var attach = try sendAndAwaitFsrpcWithTimeout(allocator, client, attach_req, attach_tag, fsrpc_default_timeout_ms);
    defer attach.deinit(allocator);
    try ensureFsrpcOk(&attach);
}

fn fsrpcWalkPath(allocator: std.mem.Allocator, client: *WebSocketClient, path: []const u8) !u32 {
    const segments = try splitPathSegments(allocator, path);
    defer freeSegments(allocator, segments);

    const path_json = try buildPathArrayJson(allocator, segments);
    defer allocator.free(path_json);

    const new_fid = nextFsrpcFid();
    const tag = nextFsrpcTag();
    const req = try std.fmt.allocPrint(
        allocator,
        "{{\"channel\":\"fsrpc\",\"type\":\"fsrpc.t_walk\",\"tag\":{d},\"fid\":1,\"newfid\":{d},\"path\":{s}}}",
        .{ tag, new_fid, path_json },
    );
    defer allocator.free(req);

    var response = try sendAndAwaitFsrpcWithTimeout(allocator, client, req, tag, fsrpc_default_timeout_ms);
    defer response.deinit(allocator);
    try ensureFsrpcOk(&response);
    return new_fid;
}

fn fsrpcOpen(allocator: std.mem.Allocator, client: *WebSocketClient, fid: u32, mode: []const u8) !void {
    const escaped_mode = try unified.jsonEscape(allocator, mode);
    defer allocator.free(escaped_mode);

    const tag = nextFsrpcTag();
    const req = try std.fmt.allocPrint(
        allocator,
        "{{\"channel\":\"fsrpc\",\"type\":\"fsrpc.t_open\",\"tag\":{d},\"fid\":{d},\"mode\":\"{s}\"}}",
        .{ tag, fid, escaped_mode },
    );
    defer allocator.free(req);

    var response = try sendAndAwaitFsrpcWithTimeout(allocator, client, req, tag, fsrpc_default_timeout_ms);
    defer response.deinit(allocator);
    try ensureFsrpcOk(&response);
}

fn fsrpcReadAllText(allocator: std.mem.Allocator, client: *WebSocketClient, fid: u32) ![]u8 {
    const tag = nextFsrpcTag();
    const req = try std.fmt.allocPrint(
        allocator,
        "{{\"channel\":\"fsrpc\",\"type\":\"fsrpc.t_read\",\"tag\":{d},\"fid\":{d},\"offset\":0,\"count\":1048576}}",
        .{ tag, fid },
    );
    defer allocator.free(req);

    var response = try sendAndAwaitFsrpcWithTimeout(allocator, client, req, tag, fsrpc_default_timeout_ms);
    defer response.deinit(allocator);
    try ensureFsrpcOk(&response);

    const payload = try getPayloadObject(response.parsed.value.object);
    const data_b64 = payload.get("data_b64") orelse return error.InvalidResponse;
    if (data_b64 != .string) return error.InvalidResponse;

    const decoded_len = std.base64.standard.Decoder.calcSizeForSlice(data_b64.string) catch return error.InvalidResponse;
    const decoded = try allocator.alloc(u8, decoded_len);
    _ = std.base64.standard.Decoder.decode(decoded, data_b64.string) catch {
        allocator.free(decoded);
        return error.InvalidResponse;
    };
    return decoded;
}

fn fsrpcWriteText(
    allocator: std.mem.Allocator,
    client: *WebSocketClient,
    fid: u32,
    content: []const u8,
    correlation_id: ?[]const u8,
) !FsrpcWriteResult {
    const encoded = try unified.encodeDataB64(allocator, content);
    defer allocator.free(encoded);

    const tag = nextFsrpcTag();
    const req = if (correlation_id) |value| blk: {
        const escaped = try unified.jsonEscape(allocator, value);
        defer allocator.free(escaped);
        break :blk try std.fmt.allocPrint(
            allocator,
            "{{\"channel\":\"fsrpc\",\"type\":\"fsrpc.t_write\",\"tag\":{d},\"fid\":{d},\"offset\":0,\"data_b64\":\"{s}\",\"correlation_id\":\"{s}\"}}",
            .{ tag, fid, encoded, escaped },
        );
    } else try std.fmt.allocPrint(
        allocator,
        "{{\"channel\":\"fsrpc\",\"type\":\"fsrpc.t_write\",\"tag\":{d},\"fid\":{d},\"offset\":0,\"data_b64\":\"{s}\"}}",
        .{ tag, fid, encoded },
    );
    defer allocator.free(req);

    var response = try sendAndAwaitFsrpcWithTimeout(allocator, client, req, tag, fsrpc_chat_write_timeout_ms);
    defer response.deinit(allocator);
    try ensureFsrpcOk(&response);

    const payload = try getPayloadObject(response.parsed.value.object);
    const n = payload.get("n") orelse return error.InvalidResponse;
    if (n != .integer or n.integer < 0) return error.InvalidResponse;

    var job: ?[]u8 = null;
    if (payload.get("job")) |job_value| {
        if (job_value != .string) return error.InvalidResponse;
        job = try allocator.dupe(u8, job_value.string);
    }
    var response_correlation_id: ?[]u8 = null;
    if (payload.get("correlation_id")) |corr_val| {
        if (corr_val != .string) return error.InvalidResponse;
        response_correlation_id = try allocator.dupe(u8, corr_val.string);
    }

    return .{
        .written = @intCast(n.integer),
        .job = job,
        .correlation_id = response_correlation_id,
    };
}

fn fsrpcStatRaw(allocator: std.mem.Allocator, client: *WebSocketClient, fid: u32) ![]u8 {
    const tag = nextFsrpcTag();
    const req = try std.fmt.allocPrint(
        allocator,
        "{{\"channel\":\"fsrpc\",\"type\":\"fsrpc.t_stat\",\"tag\":{d},\"fid\":{d}}}",
        .{ tag, fid },
    );
    defer allocator.free(req);

    var response = try sendAndAwaitFsrpcWithTimeout(allocator, client, req, tag, fsrpc_default_timeout_ms);
    defer response.deinit(allocator);
    try ensureFsrpcOk(&response);

    const payload = response.parsed.value.object.get("payload") orelse return error.InvalidResponse;
    var out = std.ArrayListUnmanaged(u8){};
    defer out.deinit(allocator);
    const formatter = std.json.fmt(payload, .{ .whitespace = .indent_2 });
    try std.fmt.format(out.writer(allocator), "{f}", .{formatter});
    return out.toOwnedSlice(allocator);
}

fn fsrpcClunkBestEffort(allocator: std.mem.Allocator, client: *WebSocketClient, fid: u32) void {
    const tag = nextFsrpcTag();
    const req = std.fmt.allocPrint(
        allocator,
        "{{\"channel\":\"fsrpc\",\"type\":\"fsrpc.t_clunk\",\"tag\":{d},\"fid\":{d}}}",
        .{ tag, fid },
    ) catch return;
    defer allocator.free(req);
    var response = sendAndAwaitFsrpcWithTimeout(allocator, client, req, tag, 1_000) catch return;
    response.deinit(allocator);
}

fn sendAndAwaitFsrpc(allocator: std.mem.Allocator, client: *WebSocketClient, request_json: []const u8, tag: u32) !JsonEnvelope {
    return sendAndAwaitFsrpcWithTimeout(allocator, client, request_json, tag, fsrpc_default_timeout_ms);
}

fn sendAndAwaitFsrpcWithTimeout(
    allocator: std.mem.Allocator,
    client: *WebSocketClient,
    request_json: []const u8,
    tag: u32,
    timeout_ms: i64,
) !JsonEnvelope {
    try client.send(request_json);

    const started = std.time.milliTimestamp();
    while (std.time.milliTimestamp() - started < timeout_ms) {
        const maybe_raw = client.readTimeout(2_000) catch |err| {
            if (err == error.Closed or err == error.BrokenPipe or err == error.ConnectionResetByPeer or err == error.EndOfStream) {
                logger.err("Connection closed while waiting for FS-RPC response", .{});
            }
            return err;
        };
        if (maybe_raw) |raw| {
            const parsed = std.json.parseFromSlice(std.json.Value, allocator, raw, .{}) catch {
                allocator.free(raw);
                continue;
            };

            var matched = false;
            if (parsed.value == .object) {
                const obj = parsed.value.object;
                if (obj.get("channel")) |channel| {
                    if (channel == .string and std.mem.eql(u8, channel.string, "fsrpc")) {
                        if (obj.get("tag")) |raw_tag| {
                            if (raw_tag == .integer and raw_tag.integer >= 0 and @as(u32, @intCast(raw_tag.integer)) == tag) {
                                matched = true;
                            }
                        }
                    }
                }
            }

            if (matched) {
                return .{
                    .raw = raw,
                    .parsed = parsed,
                };
            }

            if (parsed.value == .object) {
                logOutOfBandFrame(parsed.value.object);
            }
            parsed.deinit();
            allocator.free(raw);
        }
    }

    return error.Timeout;
}

fn logOutOfBandFrame(root: std.json.ObjectMap) void {
    const type_value = root.get("type") orelse return;
    if (type_value != .string) return;

    if (std.mem.eql(u8, type_value.string, "debug.event")) {
        const category = if (root.get("category")) |value| switch (value) {
            .string => value.string,
            else => "unknown",
        } else "unknown";
        logger.info("Debug event: {s}", .{category});
        return;
    }

    if (std.mem.eql(u8, type_value.string, "control.error")) {
        const message = if (root.get("message")) |value| switch (value) {
            .string => value.string,
            else => "control.error",
        } else "control.error";
        logger.warn("Control error while awaiting FS-RPC response: {s}", .{message});
    }
}

fn ensureFsrpcOk(envelope: *JsonEnvelope) !void {
    if (envelope.parsed.value != .object) return error.InvalidResponse;
    const obj = envelope.parsed.value.object;
    const ok_value = obj.get("ok") orelse return error.InvalidResponse;
    if (ok_value != .bool) return error.InvalidResponse;
    if (!ok_value.bool) {
        const error_value = obj.get("error") orelse return error.RemoteError;
        if (error_value == .object) {
            if (error_value.object.get("message")) |message| {
                if (message == .string) logger.err("FS-RPC error: {s}", .{message.string});
            }
        }
        return error.RemoteError;
    }
}

fn getPayloadObject(root: std.json.ObjectMap) !std.json.ObjectMap {
    const payload = root.get("payload") orelse return error.InvalidResponse;
    if (payload != .object) return error.InvalidResponse;
    return payload.object;
}

fn splitPathSegments(allocator: std.mem.Allocator, path: []const u8) ![][]u8 {
    if (path.len == 0 or std.mem.eql(u8, path, "/")) return &.{};

    var out = std.ArrayListUnmanaged([]u8){};
    errdefer {
        for (out.items) |segment| allocator.free(segment);
        out.deinit(allocator);
    }

    var it = std.mem.tokenizeAny(u8, path, "/");
    while (it.next()) |segment| {
        if (segment.len == 0) continue;
        try out.append(allocator, try allocator.dupe(u8, segment));
    }

    return out.toOwnedSlice(allocator);
}

fn freeSegments(allocator: std.mem.Allocator, segments: [][]u8) void {
    for (segments) |segment| allocator.free(segment);
    if (segments.len > 0) allocator.free(segments);
}

fn buildPathArrayJson(allocator: std.mem.Allocator, segments: [][]u8) ![]u8 {
    var out = std.ArrayListUnmanaged(u8){};
    defer out.deinit(allocator);

    try out.append(allocator, '[');
    for (segments, 0..) |segment, idx| {
        if (idx > 0) try out.append(allocator, ',');
        const escaped = try unified.jsonEscape(allocator, segment);
        defer allocator.free(escaped);
        try out.writer(allocator).print("\"{s}\"", .{escaped});
    }
    try out.append(allocator, ']');

    return out.toOwnedSlice(allocator);
}
