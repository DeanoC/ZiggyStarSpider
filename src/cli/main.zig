const std = @import("std");
const builtin = @import("builtin");
const args = @import("args.zig");
const logger = @import("ziggy-core").utils.logger;
const WebSocketClient = @import("../client/websocket.zig").WebSocketClient;
const Config = @import("../client/config.zig").Config;
const control_plane = @import("control_plane");
const venom_bindings = @import("../client/venom_bindings.zig");
const app_venom_host = if (builtin.os.tag == .windows)
    @import("../client/app_venom_host_windows_stub.zig")
else
    @import("../client/app_venom_host.zig");
const workspace_types = control_plane.workspace_types;
const unified = @import("spider-protocol").unified;

// Main CLI entry point for SpiderApp

var g_client: ?WebSocketClient = null;
var g_connected: bool = false;
var g_control_ready: bool = false;
var g_client_allocator: ?std.mem.Allocator = null;
var g_client_url_owned: ?[]u8 = null;
var g_client_token_owned: ?[]u8 = null;
var g_control_request_counter: u64 = 0;
var g_fsrpc_tag: u32 = 1;
var g_fsrpc_fid: u32 = 2;
var g_app_local_node_bootstrap_done: bool = false;
var g_app_local_venom_host: ?app_venom_host.AppVenomHost = null;
const fsrpc_default_timeout_ms: i64 = 15_000;
const fsrpc_chat_write_timeout_ms: i64 = 180_000;
const mount_read_chunk_bytes: u32 = 128 * 1024;
const mount_read_max_total_bytes: usize = 8 * 1024 * 1024;
const chat_job_poll_interval_ms: u64 = 500;
const session_status_timeout_ms: i64 = 5_000;
const session_warming_wait_timeout_ms: i64 = 30_000;
const session_warming_poll_interval_ms: u64 = 250;
const app_local_node_lease_ttl_ms: u64 = 15 * 60 * 1000;
const system_workspace_id = "system";
const system_agent_id = "spiderweb";

const ChatProgressOptions = struct {
    args: []const []const u8,
    show_thoughts: bool = true,
    quiet_progress: bool = false,

    fn deinit(self: *ChatProgressOptions, allocator: std.mem.Allocator) void {
        allocator.free(self.args);
        self.* = undefined;
    }
};

const CliFsPathReader = struct {
    allocator: std.mem.Allocator,
    client: *WebSocketClient,

    pub fn readText(self: @This(), path: []const u8) ![]u8 {
        return mountReadPathText(self.allocator, self.client, path);
    }
};

fn parseChatProgressOptions(
    allocator: std.mem.Allocator,
    raw_args: []const []const u8,
) !ChatProgressOptions {
    var filtered = std.ArrayListUnmanaged([]const u8){};
    errdefer filtered.deinit(allocator);

    var show_thoughts = true;
    var quiet_progress = false;
    for (raw_args) |arg| {
        if (std.mem.eql(u8, arg, "--no-thoughts")) {
            show_thoughts = false;
            continue;
        }
        if (std.mem.eql(u8, arg, "--quiet-progress")) {
            quiet_progress = true;
            continue;
        }
        try filtered.append(allocator, arg);
    }

    return .{
        .args = try filtered.toOwnedSlice(allocator),
        .show_thoughts = show_thoughts,
        .quiet_progress = quiet_progress,
    };
}

fn stdoutSupportsAnsi() bool {
    return std.fs.File.stdout().isTty();
}

fn printThoughtProgress(stdout: anytype, thought: []const u8) !void {
    if (stdoutSupportsAnsi()) {
        try stdout.print("\x1b[2mThought: {s}\x1b[0m\n", .{thought});
    } else {
        try stdout.print("Thought: {s}\n", .{thought});
    }
}

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

    if (std.mem.eql(u8, args.gitRevision(), "unknown")) {
        logger.info("SpiderApp v{s}", .{args.appVersion()});
    } else {
        logger.info("SpiderApp v{s} ({s})", .{ args.appVersion(), args.gitRevision() });
    }
    logger.info("Server: {s}", .{options.url});
    if (options.workspace) |p| {
        logger.info("Workspace: {s}", .{p});
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

fn resolveConnectToken(allocator: std.mem.Allocator, options: args.Options) ![]u8 {
    if (options.operator_token) |value| {
        if (value.len > 0) return allocator.dupe(u8, value);
    }

    var cfg = try loadCliConfig(allocator);
    defer cfg.deinit();
    if (options.role) |selected_role| {
        const token_role: Config.TokenRole = if (selected_role == .admin) .admin else .user;
        const role_token = cfg.getRoleToken(token_role);
        if (role_token.len > 0) return allocator.dupe(u8, role_token);
    }
    const active_token = cfg.activeRoleToken();
    if (active_token.len > 0) return allocator.dupe(u8, active_token);
    return allocator.dupe(u8, "");
}

fn getOrCreateClient(allocator: std.mem.Allocator, options: args.Options) !*WebSocketClient {
    if (g_client == null) {
        g_client_allocator = allocator;
        g_client_url_owned = try allocator.dupe(u8, options.url);
        errdefer {
            if (g_client_url_owned) |value| allocator.free(value);
            g_client_url_owned = null;
        }
        g_client_token_owned = try resolveConnectToken(allocator, options);
        errdefer {
            if (g_client_token_owned) |value| allocator.free(value);
            g_client_token_owned = null;
        }
        g_client = WebSocketClient.init(allocator, g_client_url_owned.?, g_client_token_owned.?);
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
    var maybe_allocator: ?std.mem.Allocator = g_client_allocator;
    if (g_app_local_venom_host) |*host| {
        maybe_allocator = host.allocator;
        host.deinit();
    }
    g_app_local_venom_host = null;
    if (g_client) |*client| {
        maybe_allocator = client.allocator;
        client.deinit();
    }
    g_client = null;
    if (g_client_url_owned) |value| {
        if (maybe_allocator) |allocator| allocator.free(value);
        g_client_url_owned = null;
    }
    if (g_client_token_owned) |value| {
        if (maybe_allocator) |allocator| allocator.free(value);
        g_client_token_owned = null;
    }
    g_connected = false;
    g_control_ready = false;
    g_app_local_node_bootstrap_done = false;
    g_client_allocator = null;
}

fn ensureUnifiedV2Control(allocator: std.mem.Allocator, client: *WebSocketClient) !void {
    if (g_control_ready) return;
    try control_plane.ensureUnifiedV2Connection(allocator, client, &g_control_request_counter);
    g_control_ready = true;
    if (!g_app_local_node_bootstrap_done) {
        ensureAppLocalNodeBootstrap(allocator, client) catch |err| {
            std.log.warn("SpiderApp local node bootstrap skipped: {s}", .{@errorName(err)});
        };
        g_app_local_node_bootstrap_done = true;
    }
}

fn ensureAppLocalNodeBootstrap(allocator: std.mem.Allocator, client: *WebSocketClient) !void {
    var cfg = try loadCliConfig(allocator);
    defer cfg.deinit();

    const profile_id = cfg.selectedProfileId();
    const node_name = try app_venom_host.buildAppLocalNodeName(allocator, profile_id);
    defer allocator.free(node_name);
    const active_token = g_client_token_owned orelse "";
    var bootstrap_token = active_token;
    var bootstrap_client = client;
    var used_admin_fallback = false;
    var admin_client_storage: ?WebSocketClient = null;
    defer {
        if (admin_client_storage) |*admin_client| {
            admin_client.deinit();
        }
    }

    var ensured = control_plane.ensureNode(
        allocator,
        client,
        &g_control_request_counter,
        node_name,
        null,
        app_local_node_lease_ttl_ms,
    ) catch |primary_err| blk: {
        const admin_token = cfg.getRoleToken(.admin);
        if (admin_token.len == 0) return primary_err;
        if (std.mem.eql(u8, active_token, admin_token)) return primary_err;
        const ws_url = g_client_url_owned orelse return primary_err;
        admin_client_storage = WebSocketClient.init(allocator, ws_url, admin_token);
        try admin_client_storage.?.connect();
        try control_plane.ensureUnifiedV2Connection(allocator, &admin_client_storage.?, &g_control_request_counter);
        bootstrap_token = admin_token;
        bootstrap_client = &admin_client_storage.?;
        used_admin_fallback = true;
        break :blk try control_plane.ensureNode(
            allocator,
            &admin_client_storage.?,
            &g_control_request_counter,
            node_name,
            null,
            app_local_node_lease_ttl_ms,
        );
    };
    defer ensured.deinit(allocator);

    startAppLocalVenomHost(
        allocator,
        bootstrap_client,
        bootstrap_token,
        ensured,
        app_local_node_lease_ttl_ms,
    ) catch |start_err| {
        const admin_token = cfg.getRoleToken(.admin);
        if (admin_token.len == 0) return start_err;
        if (used_admin_fallback or std.mem.eql(u8, bootstrap_token, admin_token)) return start_err;
        const ws_url = g_client_url_owned orelse return start_err;
        admin_client_storage = WebSocketClient.init(allocator, ws_url, admin_token);
        try admin_client_storage.?.connect();
        try control_plane.ensureUnifiedV2Connection(allocator, &admin_client_storage.?, &g_control_request_counter);
        try startAppLocalVenomHost(
            allocator,
            &admin_client_storage.?,
            admin_token,
            ensured,
            app_local_node_lease_ttl_ms,
        );
        bootstrap_token = admin_token;
        bootstrap_client = &admin_client_storage.?;
        used_admin_fallback = true;
    };

    if (cfg.appLocalNode(profile_id)) |existing| {
        if (std.mem.eql(u8, existing.node_name, ensured.node_name) and
            std.mem.eql(u8, existing.node_id, ensured.node_id) and
            std.mem.eql(u8, existing.node_secret, ensured.node_secret))
        {
            return;
        }
    }

    try cfg.setAppLocalNode(profile_id, ensured.node_name, ensured.node_id, ensured.node_secret);
    try cfg.save();
}

fn startAppLocalVenomHost(
    allocator: std.mem.Allocator,
    client: *WebSocketClient,
    control_token: []const u8,
    ensured: control_plane.EnsuredNodeIdentity,
    lease_ttl_ms: u64,
) !void {
    const control_url = g_client_url_owned orelse return error.ClientUrlUnavailable;
    if (g_app_local_venom_host) |*existing| {
        if (existing.matches(control_url, control_token, ensured)) return;
        existing.deinit();
        g_app_local_venom_host = null;
    }

    var wasm_chat_backend = try app_venom_host.loadChatWasmBackendFromEnv(allocator);
    defer if (wasm_chat_backend) |*cfg| cfg.deinit(allocator);

    g_app_local_venom_host = try app_venom_host.AppVenomHost.initWithOptions(
        allocator,
        control_url,
        control_token,
        ensured,
        .{
            .chat_wasm_backend = wasm_chat_backend,
        },
    );
    errdefer {
        if (g_app_local_venom_host) |*host| host.deinit();
        g_app_local_venom_host = null;
    }
    g_app_local_venom_host.?.bindSelf();
    try g_app_local_venom_host.?.bootstrap(client, &g_control_request_counter, lease_ttl_ms);
}

fn executeCommand(allocator: std.mem.Allocator, options: args.Options, cmd: args.Command) !void {
    const stdout = std.fs.File.stdout().deprecatedWriter();

    switch (cmd.noun) {
        .chat => {
            try stdout.print(
                "Chat is temporarily unavailable while SpiderApp moves fully to the mount-based workspace model.\n",
                .{},
            );
            return;
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
        .agent => {
            switch (cmd.verb) {
                .list => try executeAgentList(allocator, options, cmd),
                .info => try executeAgentInfo(allocator, options, cmd),
                else => {
                    logger.err("Unknown agent verb", .{});
                    return error.InvalidArguments;
                },
            }
        },
        .session => {
            switch (cmd.verb) {
                .list => try executeSessionList(allocator, options, cmd),
                .history => try executeSessionHistory(allocator, options, cmd),
                .status => try executeSessionStatus(allocator, options, cmd),
                .attach => try executeSessionAttach(allocator, options, cmd),
                .resume_job => try executeSessionResume(allocator, options, cmd),
                .close => try executeSessionClose(allocator, options, cmd),
                .restore => try executeSessionRestore(allocator, options, cmd),
                else => {
                    logger.err("Unknown session verb", .{});
                    return error.InvalidArguments;
                },
            }
        },
        .node => {
            switch (cmd.verb) {
                .list => try executeNodeList(allocator, options, cmd),
                .info => try executeNodeInfo(allocator, options, cmd),
                .pending => try executeNodePendingList(allocator, options, cmd),
                .approve => try executeNodeApprove(allocator, options, cmd),
                .deny => try executeNodeDeny(allocator, options, cmd),
                .join_request => try executeNodeJoinRequest(allocator, options, cmd),
                .service_get => try executeNodeServiceGet(allocator, options, cmd),
                .service_upsert => try executeNodeServiceUpsert(allocator, options, cmd),
                .service_runtime => try executeNodeServiceRuntime(allocator, options, cmd),
                .watch => try executeNodeServiceWatch(allocator, options, cmd),
                else => {
                    logger.err("Unknown node verb", .{});
                    return error.InvalidArguments;
                },
            }
        },
        .workspace => {
            switch (cmd.verb) {
                .list => try executeWorkspaceList(allocator, options, cmd),
                .use => try executeWorkspaceUse(allocator, options, cmd),
                .create => try executeWorkspaceCreate(allocator, options, cmd),
                .up => try executeWorkspaceUp(allocator, options, cmd),
                .doctor => try executeWorkspaceDoctor(allocator, options, cmd),
                .info => try executeWorkspaceInfo(allocator, options, cmd),
                .status => try executeWorkspaceStatus(allocator, options, cmd),
                .template => try executeWorkspaceTemplateCommand(allocator, options, cmd),
                .bind => try executeWorkspaceBindCommand(allocator, options, cmd),
                .mount => try executeWorkspaceMountCommand(allocator, options, cmd),
                .handoff => try executeWorkspaceHandoffCommand(allocator, options, cmd),
                else => {
                    logger.err("Unknown workspace verb", .{});
                    return error.InvalidArguments;
                },
            }
        },
        .package => {
            switch (cmd.verb) {
                .list, .info, .install, .enable, .disable, .remove => try executePackageCommand(allocator, options, cmd),
                else => {
                    logger.err("Unknown package verb", .{});
                    return error.InvalidArguments;
                },
            }
        },
        .auth => {
            switch (cmd.verb) {
                .status => try executeAuthStatus(allocator, options, cmd),
                .rotate => try executeAuthRotate(allocator, options, cmd),
                else => {
                    logger.err("Unknown auth verb", .{});
                    return error.InvalidArguments;
                },
            }
        },
        .connect => {
            if (g_connected) {
                try stdout.print("Already connected to {s}\n", .{options.url});
                return;
            }

            const client = try getOrCreateClient(allocator, options);
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

    try stdout.print("\nSpiderApp Interactive Mode\n", .{});
    try stdout.print("Type 'help' for commands, 'quit' to exit.\n\n", .{});

    // TODO: Implement actual interactive REPL with connection
    try stdout.print("Interactive mode not yet implemented.\n", .{});
    try stdout.print("Use command mode for now: spider chat send \"hello\"\n", .{});
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

fn resolveWorkspaceSelection(options: args.Options, cfg: *const Config) ?[]const u8 {
    if (options.workspace) |project_id| return project_id;
    return cfg.selectedWorkspace();
}

fn effectiveRole(options: args.Options, cfg: *const Config) Config.TokenRole {
    if (options.role) |role| {
        return if (role == .admin) .admin else .user;
    }
    return cfg.active_role;
}

fn resolveSessionKey(cfg: *const Config) []const u8 {
    if (cfg.default_session) |session_key| {
        if (session_key.len > 0) return session_key;
    }
    return "main";
}

fn isUserScopedAgentId(agent_id: []const u8) bool {
    return std.mem.eql(u8, agent_id, "user") or std.mem.eql(u8, agent_id, "user-isolated");
}

fn isSystemWorkspaceId(workspace_id: []const u8) bool {
    return std.mem.eql(u8, workspace_id, system_workspace_id);
}

fn isSystemAgentId(agent_id: []const u8) bool {
    return std.mem.eql(u8, agent_id, system_agent_id);
}

fn fetchDefaultAgentFromSessionList(
    allocator: std.mem.Allocator,
    client: *WebSocketClient,
    preferred_session_key: []const u8,
) ![]u8 {
    var sessions = try control_plane.listSessions(allocator, client, &g_control_request_counter);
    defer sessions.deinit(allocator);

    var preferred_agent: ?[]const u8 = null;
    var active_agent: ?[]const u8 = null;
    var fallback_agent: ?[]const u8 = null;

    for (sessions.sessions.items) |session| {
        if (fallback_agent == null) fallback_agent = session.agent_id;
        if (std.mem.eql(u8, session.session_key, preferred_session_key)) {
            preferred_agent = session.agent_id;
        }
        if (std.mem.eql(u8, session.session_key, sessions.active_session)) {
            active_agent = session.agent_id;
        }
    }

    const selected = preferred_agent orelse active_agent orelse fallback_agent orelse return error.InvalidResponse;
    return allocator.dupe(u8, selected);
}

fn fetchFirstNonSystemAgent(
    allocator: std.mem.Allocator,
    client: *WebSocketClient,
) ![]u8 {
    var agents = try control_plane.listAgents(allocator, client, &g_control_request_counter);
    defer workspace_types.deinitAgentList(allocator, &agents);

    var fallback_non_system: ?[]const u8 = null;
    for (agents.items) |agent| {
        if (isSystemAgentId(agent.id)) continue;
        if (agent.is_default) return allocator.dupe(u8, agent.id);
        if (fallback_non_system == null) fallback_non_system = agent.id;
    }

    if (fallback_non_system) |agent_id| return allocator.dupe(u8, agent_id);
    return error.NoProjectCompatibleAgent;
}

fn resolveAttachAgentForWorkspace(
    allocator: std.mem.Allocator,
    options: args.Options,
    cfg: *const Config,
    client: *WebSocketClient,
    preferred_session_key: []const u8,
    project_id: []const u8,
) ![]u8 {
    const role = effectiveRole(options, cfg);
    if (role == .user and isSystemWorkspaceId(project_id)) {
        return error.UserRoleCannotAttachSystemProject;
    }
    var resolved_agent = if (cfg.selectedAgent()) |selected_agent| blk: {
        if (selected_agent.len == 0) break :blk try fetchDefaultAgentFromSessionList(allocator, client, preferred_session_key);
        break :blk try allocator.dupe(u8, selected_agent);
    } else try fetchDefaultAgentFromSessionList(allocator, client, preferred_session_key);
    errdefer allocator.free(resolved_agent);

    if (role == .admin and isUserScopedAgentId(resolved_agent)) {
        allocator.free(resolved_agent);
        resolved_agent = try fetchDefaultAgentFromSessionList(allocator, client, preferred_session_key);
    }

    if (isSystemWorkspaceId(project_id)) {
        if (!isSystemAgentId(resolved_agent)) {
            allocator.free(resolved_agent);
            resolved_agent = try allocator.dupe(u8, system_agent_id);
        }
        return resolved_agent;
    }

    if (isSystemAgentId(resolved_agent)) {
        allocator.free(resolved_agent);
        resolved_agent = try fetchFirstNonSystemAgent(allocator, client);
    }

    return resolved_agent;
}

fn sessionStatusMatchesTarget(
    status: *const workspace_types.SessionAttachStatus,
    agent_id: []const u8,
    project_id: []const u8,
) bool {
    if (!std.mem.eql(u8, status.agent_id, agent_id)) return false;
    const attached_project_id = status.workspace_id orelse return false;
    return std.mem.eql(u8, attached_project_id, project_id);
}

fn waitForSessionReady(
    allocator: std.mem.Allocator,
    client: *WebSocketClient,
    session_key: []const u8,
    agent_id: []const u8,
    project_id: []const u8,
) !void {
    const start_ms = std.time.milliTimestamp();
    var printed_warming = false;

    while (true) {
        var status = control_plane.sessionStatusWithTimeout(
            allocator,
            client,
            &g_control_request_counter,
            session_key,
            session_status_timeout_ms,
        ) catch |err| {
            if (err == error.RemoteError) {
                if (control_plane.lastRemoteError()) |remote| {
                    logger.err("session status failed while waiting for ready: {s}", .{remote});
                }
            }
            return err;
        };
        defer status.deinit(allocator);

        if (!sessionStatusMatchesTarget(&status, agent_id, project_id)) {
            logger.err(
                "session binding changed while waiting: expected {s}@{s}, got {s}@{s}",
                .{ agent_id, project_id, status.agent_id, status.workspace_id orelse "(none)" },
            );
            return error.SessionAttachMismatch;
        }

        if (std.mem.eql(u8, status.state, "ready")) return;

        if (std.mem.eql(u8, status.state, "error")) {
            const code = status.error_code orelse "runtime_unavailable";
            const message = status.error_message orelse "runtime unavailable";
            logger.err("session attach error: {s} [{s}]", .{ message, code });
            return error.RemoteError;
        }

        if (std.mem.eql(u8, status.state, "warming")) {
            if (!printed_warming) {
                printed_warming = true;
                logger.info(
                    "Session runtime warming for {s}@{s}; waiting up to {d}ms...",
                    .{ agent_id, project_id, session_warming_wait_timeout_ms },
                );
            }
        } else {
            logger.info("Session attach pending state={s}; waiting...", .{status.state});
        }

        if (std.time.milliTimestamp() - start_ms >= session_warming_wait_timeout_ms) {
            logger.err(
                "Session runtime did not become ready within {d}ms",
                .{session_warming_wait_timeout_ms},
            );
            return error.RuntimeWarming;
        }

        std.Thread.sleep(session_warming_poll_interval_ms * std.time.ns_per_ms);
    }
}

fn printWorkspaceStatus(stdout: anytype, status: *const workspace_types.WorkspaceStatus, verbose: bool) !void {
    try stdout.print("Agent: {s}\n", .{status.agent_id});
    if (status.workspace_id) |project_id| {
        try stdout.print("Workspace: {s}\n", .{project_id});
    } else {
        try stdout.print("Workspace: (none)\n", .{});
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

fn maybeApplyWorkspaceContext(
    allocator: std.mem.Allocator,
    options: args.Options,
    client: *WebSocketClient,
) !void {
    var cfg = try loadCliConfig(allocator);
    defer cfg.deinit();

    const project_id = resolveWorkspaceSelection(options, &cfg) orelse return;
    try ensureUnifiedV2Control(allocator, client);

    const token = if (options.workspace_token) |value| value else cfg.getWorkspaceToken(project_id);
    const session_key = resolveSessionKey(&cfg);
    const attach_agent = resolveAttachAgentForWorkspace(
        allocator,
        options,
        &cfg,
        client,
        session_key,
        project_id,
    ) catch |err| {
        if (err == error.UserRoleCannotAttachSystemProject) {
            logger.err("user role cannot attach to the system workspace; choose a non-system workspace", .{});
        } else if (err == error.NoProjectCompatibleAgent) {
            logger.err("no non-system agent is available for workspace {s}", .{project_id});
        }
        return err;
    };
    defer allocator.free(attach_agent);

    var attach_state: []const u8 = "ready";
    var active_agent: []const u8 = attach_agent;
    var did_attach = true;

    var existing_status = control_plane.sessionStatusWithTimeout(
        allocator,
        client,
        &g_control_request_counter,
        session_key,
        session_status_timeout_ms,
    ) catch null;
    defer if (existing_status) |*value| value.deinit(allocator);

    if (existing_status) |*status| {
        if (sessionStatusMatchesTarget(status, attach_agent, project_id)) {
            did_attach = false;
            active_agent = status.agent_id;
            attach_state = status.state;
            if (std.mem.eql(u8, status.state, "warming")) {
                try waitForSessionReady(
                    allocator,
                    client,
                    session_key,
                    status.agent_id,
                    project_id,
                );
                attach_state = "ready";
            } else if (std.mem.eql(u8, status.state, "error")) {
                // Re-attach below to attempt self-heal from stale error state.
                did_attach = true;
            } else if (!std.mem.eql(u8, status.state, "ready")) {
                // Unknown/non-ready state: fall through to explicit attach.
                did_attach = true;
            }
        }
    }

    if (did_attach) {
        var attached = control_plane.sessionAttach(
            allocator,
            client,
            &g_control_request_counter,
            session_key,
            attach_agent,
            project_id,
            token,
        ) catch |err| {
            if (err == error.RemoteError) {
                if (control_plane.lastRemoteError()) |remote| {
                    logger.err("session attach failed: {s}", .{remote});
                }
            }
            return err;
        };
        defer attached.deinit(allocator);

        active_agent = attached.agent_id;
        attach_state = attached.state;

        if (std.mem.eql(u8, attached.state, "warming")) {
            try waitForSessionReady(
                allocator,
                client,
                session_key,
                attached.agent_id,
                project_id,
            );
            attach_state = "ready";
        } else if (std.mem.eql(u8, attached.state, "error")) {
            const code = attached.error_code orelse "runtime_unavailable";
            const message = attached.error_message orelse "runtime unavailable";
            logger.err("session attach error: {s} [{s}]", .{ message, code });
            return error.RemoteError;
        }
    }

    cfg.setDefaultSession(session_key) catch {};
    cfg.setDefaultAgent(active_agent) catch {};
    cfg.save() catch {};

    logger.info(
        "Workspace context active: workspace={s} session={s} agent={s} state={s}",
        .{ project_id, session_key, active_agent, attach_state },
    );
}

const packages_control_root = "/.spiderweb/control/packages";

fn buildPackagesControlPath(allocator: std.mem.Allocator, leaf: []const u8) ![]u8 {
    return joinFsPath(allocator, packages_control_root, leaf);
}

fn loadPackagePayloadArg(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return error.InvalidArguments;
    if (trimmed[0] == '@') {
        if (trimmed.len == 1) return error.InvalidArguments;
        const file_raw = try std.fs.cwd().readFileAlloc(allocator, trimmed[1..], 1024 * 1024);
        errdefer allocator.free(file_raw);
        const file_trimmed = std.mem.trim(u8, file_raw, " \t\r\n");
        if (file_trimmed.len == 0) return error.InvalidArguments;
        if (file_trimmed.ptr == file_raw.ptr and file_trimmed.len == file_raw.len) return file_raw;
        const out = try allocator.dupe(u8, file_trimmed);
        allocator.free(file_raw);
        return out;
    }
    return allocator.dupe(u8, trimmed);
}

fn writePackageControlAndReadResult(
    allocator: std.mem.Allocator,
    client: *WebSocketClient,
    control_name: []const u8,
    payload: []const u8,
) ![]u8 {
    const control_dir = try buildPackagesControlPath(allocator, "control");
    defer allocator.free(control_dir);
    const control_path = try joinFsPath(allocator, control_dir, control_name);
    defer allocator.free(control_path);
    try fsrpcWritePathText(allocator, client, control_path, payload);
    const result_path = try buildPackagesControlPath(allocator, "result.json");
    defer allocator.free(result_path);
    return fsrpcReadPathText(allocator, client, result_path);
}

fn printPackageResult(stdout: anytype, result_json: []const u8) !void {
    var parsed = std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, result_json, .{}) catch {
        try stdout.print("{s}\n", .{result_json});
        return;
    };
    defer parsed.deinit();
    if (parsed.value != .object) {
        try stdout.print("{s}\n", .{result_json});
        return;
    }
    const root = parsed.value.object;
    if (!jsonObjectBoolOr(root, "ok", false)) {
        if (root.get("error")) |error_val| {
            if (error_val == .object) {
                try stdout.print(
                    "Package operation failed: {s} [{s}]\n",
                    .{
                        jsonObjectStringOr(error_val.object, "message", "unknown error"),
                        jsonObjectStringOr(error_val.object, "code", "error"),
                    },
                );
                return error.RemoteError;
            }
        }
        try stdout.print("{s}\n", .{result_json});
        return error.RemoteError;
    }

    const operation = jsonObjectStringOr(root, "operation", "unknown");
    const result_val = root.get("result") orelse {
        try stdout.print("{s}\n", .{result_json});
        return;
    };
    if (result_val != .object) {
        try stdout.print("{s}\n", .{result_json});
        return;
    }
    const result_obj = result_val.object;

    if (result_obj.get("packages")) |packages_val| {
        if (packages_val != .array) return error.InvalidResponse;
        try stdout.print("Packages ({d}):\n", .{packages_val.array.items.len});
        for (packages_val.array.items) |item| {
            if (item != .object) continue;
            try stdout.print(
                "  - {s} kind={s} version={s} enabled={s} runtime={s}\n",
                .{
                    jsonObjectStringOr(item.object, "package_id", jsonObjectStringOr(item.object, "venom_id", "(unknown)")),
                    jsonObjectStringOr(item.object, "kind", "(unknown)"),
                    jsonObjectStringOr(item.object, "version", "1"),
                    if (jsonObjectBoolOr(item.object, "enabled", true)) "true" else "false",
                    jsonObjectStringOr(item.object, "runtime_kind", "native"),
                },
            );
        }
        return;
    }

    if (result_obj.get("package")) |package_val| {
        if (package_val != .object) return error.InvalidResponse;
        const package = package_val.object;
        try stdout.print("Package: {s}\n", .{jsonObjectStringOr(package, "package_id", jsonObjectStringOr(package, "venom_id", "(unknown)"))});
        try stdout.print("  Kind: {s}\n", .{jsonObjectStringOr(package, "kind", "(unknown)")});
        try stdout.print("  Version: {s}\n", .{jsonObjectStringOr(package, "version", "1")});
        try stdout.print("  Enabled: {s}\n", .{if (jsonObjectBoolOr(package, "enabled", true)) "true" else "false"});
        try stdout.print("  Runtime: {s}\n", .{jsonObjectStringOr(package, "runtime_kind", "native")});
        if (package.get("host_roles")) |host_roles| {
            try stdout.print("  Host roles: {f}\n", .{std.json.fmt(host_roles, .{})});
        }
        if (package.get("binding_scopes")) |binding_scopes| {
            try stdout.print("  Binding scopes: {f}\n", .{std.json.fmt(binding_scopes, .{})});
        }
        if (package.get("help_md")) |help_md| {
            if (help_md == .string and help_md.string.len > 0) {
                try stdout.print("  Help: {s}\n", .{help_md.string});
            }
        }
        return;
    }

    if (jsonObjectBoolOr(result_obj, "removed", false)) {
        try stdout.print(
            "{s} package {s}\n",
            .{ operation, jsonObjectStringOr(result_obj, "venom_id", "(unknown)") },
        );
        return;
    }

    try stdout.print("{s}\n", .{result_json});
}

fn executePackageCommand(allocator: std.mem.Allocator, options: args.Options, cmd: args.Command) !void {
    const stdout = std.fs.File.stdout().deprecatedWriter();
    const client = try getOrCreateClient(allocator, options);
    try ensureUnifiedV2Control(allocator, client);
    try maybeApplyWorkspaceContext(allocator, options, client);
    try ensureUnifiedV2Control(allocator, client);

    const control_name: []const u8 = switch (cmd.verb) {
        .list => "list.json",
        .info => "get.json",
        .install => "install.json",
        .enable => "enable.json",
        .disable => "disable.json",
        .remove => "remove.json",
        else => return error.InvalidArguments,
    };

    const payload = switch (cmd.verb) {
        .list => try allocator.dupe(u8, "{}"),
        .info, .enable, .disable, .remove => blk: {
            if (cmd.args.len != 1) {
                logger.err("package {s} requires <package_id>", .{@tagName(cmd.verb)});
                return error.InvalidArguments;
            }
            const escaped_id = try unified.jsonEscape(allocator, cmd.args[0]);
            defer allocator.free(escaped_id);
            break :blk try std.fmt.allocPrint(allocator, "{{\"venom_id\":\"{s}\"}}", .{escaped_id});
        },
        .install => blk: {
            if (cmd.args.len != 1) {
                logger.err("package install requires <json_or_@file>", .{});
                return error.InvalidArguments;
            }
            break :blk try loadPackagePayloadArg(allocator, cmd.args[0]);
        },
        else => unreachable,
    };
    defer allocator.free(payload);

    const result_json = try writePackageControlAndReadResult(allocator, client, control_name, payload);
    defer allocator.free(result_json);
    try printPackageResult(stdout, result_json);
}

fn executeWorkspaceList(allocator: std.mem.Allocator, options: args.Options, cmd: args.Command) !void {
    _ = cmd;
    const stdout = std.fs.File.stdout().deprecatedWriter();
    const client = try getOrCreateClient(allocator, options);
    try ensureUnifiedV2Control(allocator, client);

    var cfg = try loadCliConfig(allocator);
    defer cfg.deinit();
    const selected_project = resolveWorkspaceSelection(options, &cfg);

    var projects = try control_plane.listWorkspaces(allocator, client, &g_control_request_counter);
    defer workspace_types.deinitWorkspaceList(allocator, &projects);

    if (projects.items.len == 0) {
        try stdout.print("(no workspaces)\n", .{});
        return;
    }

    try stdout.print("Workspaces:\n", .{});
    for (projects.items) |project| {
        const marker = if (selected_project != null and std.mem.eql(u8, selected_project.?, project.id)) "*" else " ";
        try stdout.print(
            "{s} {s}  [{s}]  mounts={d}  binds={d}  template={s}  name={s}\n",
            .{
                marker,
                project.id,
                project.status,
                project.mount_count,
                project.bind_count,
                project.template_id orelse "dev",
                project.name,
            },
        );
    }
}

fn executeWorkspaceInfo(allocator: std.mem.Allocator, options: args.Options, cmd: args.Command) !void {
    if (cmd.args.len == 0) {
        logger.err("workspace info requires a workspace ID", .{});
        return error.InvalidArguments;
    }

    const stdout = std.fs.File.stdout().deprecatedWriter();
    const client = try getOrCreateClient(allocator, options);
    try ensureUnifiedV2Control(allocator, client);

    var detail = try control_plane.getWorkspace(allocator, client, &g_control_request_counter, cmd.args[0]);
    defer detail.deinit(allocator);

    try stdout.print("Workspace {s}\n", .{detail.id});
    try stdout.print("  Name: {s}\n", .{detail.name});
    try stdout.print("  Vision: {s}\n", .{detail.vision});
    try stdout.print("  Status: {s}\n", .{detail.status});
    try stdout.print("  Template: {s}\n", .{detail.template_id orelse "dev"});
    try stdout.print("  Created: {d}\n", .{detail.created_at_ms});
    try stdout.print("  Updated: {d}\n", .{detail.updated_at_ms});
    if (detail.workspace_token) |token| {
        try stdout.print("  Workspace token: {s}\n", .{token});
    }
    try stdout.print("  Mounts ({d}):\n", .{detail.mounts.items.len});
    for (detail.mounts.items) |mount| {
        try stdout.print("    - {s} <= {s}:{s}\n", .{ mount.mount_path, mount.node_id, mount.export_name });
    }
    try stdout.print("  Binds ({d}):\n", .{detail.binds.items.len});
    for (detail.binds.items) |bind| {
        try stdout.print("    - {s} <= {s}\n", .{ bind.bind_path, bind.target_path });
    }
}

fn resolveOperatorToken(options: args.Options, cfg: *const Config) ?[]const u8 {
    if (options.operator_token) |value| {
        if (value.len > 0) return value;
    }
    if (cfg.getRoleToken(.admin).len > 0) return cfg.getRoleToken(.admin);
    return null;
}

fn executeWorkspaceCreate(allocator: std.mem.Allocator, options: args.Options, cmd: args.Command) !void {
    if (cmd.args.len == 0) {
        logger.err("workspace create requires a name", .{});
        return error.InvalidArguments;
    }

    var template_id: ?[]const u8 = "dev";
    var name: ?[]const u8 = null;
    var vision_parts = std.ArrayListUnmanaged([]const u8){};
    defer vision_parts.deinit(allocator);
    var i: usize = 0;
    while (i < cmd.args.len) : (i += 1) {
        const arg = cmd.args[i];
        if (std.mem.eql(u8, arg, "--template")) {
            i += 1;
            if (i >= cmd.args.len) return error.InvalidArguments;
            template_id = cmd.args[i];
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--")) return error.InvalidArguments;
        if (name == null) {
            name = arg;
        } else {
            try vision_parts.append(allocator, arg);
        }
    }
    if (name == null) return error.InvalidArguments;
    const vision = if (vision_parts.items.len > 0)
        try std.mem.join(allocator, " ", vision_parts.items)
    else
        null;
    defer if (vision) |value| allocator.free(value);

    var cfg = try loadCliConfig(allocator);
    defer cfg.deinit();

    const stdout = std.fs.File.stdout().deprecatedWriter();
    const client = try getOrCreateClient(allocator, options);
    try ensureUnifiedV2Control(allocator, client);

    var created = try control_plane.createWorkspace(
        allocator,
        client,
        &g_control_request_counter,
        name.?,
        vision,
        template_id,
        resolveOperatorToken(options, &cfg),
    );
    defer created.deinit(allocator);

    try cfg.setSelectedWorkspace(created.id);
    if (created.workspace_token) |token| {
        try cfg.setWorkspaceToken(created.id, token);
    }
    try cfg.save();

    try stdout.print("Created workspace {s}\n", .{created.id});
    try stdout.print("  Name: {s}\n", .{created.name});
    try stdout.print("  Vision: {s}\n", .{created.vision});
    try stdout.print("  Status: {s}\n", .{created.status});
    try stdout.print("  Template: {s}\n", .{created.template_id orelse "dev"});
    try stdout.print("  Created: {d}\n", .{created.created_at_ms});
    if (created.workspace_token) |token| {
        try stdout.print("  Workspace token: {s}\n", .{token});
    }
    try stdout.print("  Saved as selected workspace in local config\n", .{});

    if (created.workspace_token) |token| {
        var status = control_plane.activateWorkspace(
            allocator,
            client,
            &g_control_request_counter,
            created.id,
            token,
        ) catch |err| {
            logger.warn("workspace created but activation failed: {s}", .{@errorName(err)});
            return;
        };
        defer status.deinit(allocator);
        if (status.workspace_root) |workspace_root| {
            try stdout.print("  Workspace root: {s}\n", .{workspace_root});
        }
    }
}

fn executeWorkspaceUse(allocator: std.mem.Allocator, options: args.Options, cmd: args.Command) !void {
    if (cmd.args.len == 0) {
        logger.err("workspace use requires a workspace ID", .{});
        return error.InvalidArguments;
    }

    const project_id = cmd.args[0];
    const cli_token = if (options.workspace_token) |token|
        token
    else if (cmd.args.len > 1)
        cmd.args[1]
    else
        null;

    var cfg = try loadCliConfig(allocator);
    defer cfg.deinit();
    if (cli_token) |token| {
        try cfg.setWorkspaceToken(project_id, token);
    }
    try cfg.setSelectedWorkspace(project_id);

    const stdout = std.fs.File.stdout().deprecatedWriter();
    const client = try getOrCreateClient(allocator, options);
    try ensureUnifiedV2Control(allocator, client);

    const effective_token = if (cli_token) |token| token else cfg.getWorkspaceToken(project_id);
    var status = try control_plane.activateWorkspace(
        allocator,
        client,
        &g_control_request_counter,
        project_id,
        effective_token,
    );
    defer status.deinit(allocator);
    try stdout.print("Selected and activated workspace: {s}\n", .{project_id});
    if (status.workspace_root) |workspace_root| {
        try stdout.print("Workspace root: {s}\n", .{workspace_root});
    }

    try cfg.save();
}

const WorkspaceUpMountSpec = struct {
    mount_path: []const u8,
    node_id: []const u8,
    export_name: []const u8,
};

const WorkspaceBindSpec = struct {
    bind_path: []const u8,
    target_path: []const u8,
};

fn parseWorkspaceUpMountSpec(raw: []const u8) !WorkspaceUpMountSpec {
    const eq_idx = std.mem.indexOfScalar(u8, raw, '=') orelse return error.InvalidArguments;
    const colon_idx = std.mem.lastIndexOfScalar(u8, raw, ':') orelse return error.InvalidArguments;
    if (eq_idx == 0 or colon_idx <= eq_idx + 1 or colon_idx + 1 >= raw.len) return error.InvalidArguments;
    return .{
        .mount_path = raw[0..eq_idx],
        .node_id = raw[eq_idx + 1 .. colon_idx],
        .export_name = raw[colon_idx + 1 ..],
    };
}

fn parseWorkspaceBindSpec(raw: []const u8) !WorkspaceBindSpec {
    const eq_idx = std.mem.indexOfScalar(u8, raw, '=') orelse return error.InvalidArguments;
    if (eq_idx == 0 or eq_idx + 1 >= raw.len) return error.InvalidArguments;
    return .{
        .bind_path = raw[0..eq_idx],
        .target_path = raw[eq_idx + 1 ..],
    };
}

fn effectiveWorkspaceUpTemplateId(workspace_id: ?[]const u8, requested_template_id: ?[]const u8) ?[]const u8 {
    return requested_template_id orelse if (workspace_id == null) "dev" else null;
}

fn executeWorkspaceUp(allocator: std.mem.Allocator, options: args.Options, cmd: args.Command) !void {
    const stdout = std.fs.File.stdout().deprecatedWriter();
    const client = try getOrCreateClient(allocator, options);
    try ensureUnifiedV2Control(allocator, client);

    var cfg = try loadCliConfig(allocator);
    defer cfg.deinit();

    var positional_project_name: ?[]const u8 = null;
    var explicit_project_id: ?[]const u8 = options.workspace;
    var requested_template_id: ?[]const u8 = null;
    var activate = true;
    var mounts = std.ArrayListUnmanaged(WorkspaceUpMountSpec){};
    defer mounts.deinit(allocator);
    var binds = std.ArrayListUnmanaged(WorkspaceBindSpec){};
    defer binds.deinit(allocator);

    var i: usize = 0;
    while (i < cmd.args.len) : (i += 1) {
        const arg = cmd.args[i];
        if (std.mem.eql(u8, arg, "--mount")) {
            i += 1;
            if (i >= cmd.args.len) return error.InvalidArguments;
            try mounts.append(allocator, try parseWorkspaceUpMountSpec(cmd.args[i]));
            continue;
        }
        if (std.mem.eql(u8, arg, "--bind")) {
            i += 1;
            if (i >= cmd.args.len) return error.InvalidArguments;
            try binds.append(allocator, try parseWorkspaceBindSpec(cmd.args[i]));
            continue;
        }
        if (std.mem.eql(u8, arg, "--workspace-id")) {
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
        if (std.mem.eql(u8, arg, "--template")) {
            i += 1;
            if (i >= cmd.args.len) return error.InvalidArguments;
            requested_template_id = cmd.args[i];
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
        var default_fs_mount = discoverDefaultFsMount(allocator, client, .{
            .agent_id = cfg.selectedAgent(),
            .workspace_id = explicit_project_id orelse cfg.selectedWorkspace(),
        }) catch |err| {
            if (err == error.ServiceNotFound) {
                logger.err("workspace up requires at least one registered fs Venom (or explicit --mount)", .{});
                return error.InvalidArguments;
            }
            return err;
        };
        defer default_fs_mount.deinit(allocator);
        if (default_fs_mount.mount_path.len == 0) {
            logger.err("workspace up requires at least one registered node (or explicit --mount)", .{});
            return error.InvalidArguments;
        }
        try mounts.append(allocator, .{
            .mount_path = default_fs_mount.mount_path,
            .node_id = default_fs_mount.node_id,
            .export_name = "work",
        });
    }

    const project_id = explicit_project_id orelse cfg.selectedWorkspace();
    const template_id = effectiveWorkspaceUpTemplateId(project_id, requested_template_id);
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
        try payload.writer(allocator).print("\"workspace_id\":\"{s}\"", .{escaped});
        appended = true;
    }
    if (project_name) |value| {
        const escaped = try unified.jsonEscape(allocator, value);
        defer allocator.free(escaped);
        if (appended) try payload.append(allocator, ',');
        try payload.writer(allocator).print("\"name\":\"{s}\"", .{escaped});
        appended = true;
    }
    if (template_id) |value| {
        const escaped = try unified.jsonEscape(allocator, value);
        defer allocator.free(escaped);
        if (appended) try payload.append(allocator, ',');
        try payload.writer(allocator).print("\"template_id\":\"{s}\"", .{escaped});
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
    try payload.append(allocator, ']');
    if (binds.items.len > 0) {
        try payload.appendSlice(allocator, ",\"desired_binds\":[");
        for (binds.items, 0..) |bind, idx| {
            if (idx != 0) try payload.append(allocator, ',');
            const escaped_bind = try unified.jsonEscape(allocator, bind.bind_path);
            defer allocator.free(escaped_bind);
            const escaped_target = try unified.jsonEscape(allocator, bind.target_path);
            defer allocator.free(escaped_target);
            try payload.writer(allocator).print(
                "{{\"bind_path\":\"{s}\",\"target_path\":\"{s}\"}}",
                .{ escaped_bind, escaped_target },
            );
        }
        try payload.append(allocator, ']');
    }
    try payload.append(allocator, '}');

    const payload_json = try control_plane.requestControlPayloadJson(
        allocator,
        client,
        &g_control_request_counter,
        "control.workspace_up",
        payload.items,
    );
    defer allocator.free(payload_json);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload_json, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidResponse;

    const response_project_id_val = parsed.value.object.get("workspace_id") orelse parsed.value.object.get("project_id") orelse return error.InvalidResponse;
    if (response_project_id_val != .string) return error.InvalidResponse;
    const response_project_id = response_project_id_val.string;

    const response_token = if (parsed.value.object.get("workspace_token")) |value|
        if (value == .string) value.string else null
    else if (parsed.value.object.get("project_token")) |value|
        if (value == .string) value.string else null
    else
        null;

    try cfg.setSelectedWorkspace(response_project_id);
    if (response_token) |token| {
        try cfg.setWorkspaceToken(response_project_id, token);
    }
    try cfg.save();

    try stdout.print("workspace up complete\n", .{});
    try stdout.print("  workspace_id: {s}\n", .{response_project_id});
    try stdout.print(
        "  created: {s}\n",
        .{if (parsed.value.object.get("created")) |value|
            if (value == .bool and value.bool) "true" else "false"
        else
            "false"},
    );
    try stdout.print("  activate: {s}\n", .{if (activate) "true" else "false"});
    try stdout.print("  template: {s}\n", .{template_id orelse "unchanged"});
    try stdout.print("  mounts requested: {d}\n", .{mounts.items.len});
    try stdout.print("  binds requested: {d}\n", .{binds.items.len});

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

test "effectiveWorkspaceUpTemplateId defaults only on create paths" {
    try std.testing.expectEqualStrings("dev", effectiveWorkspaceUpTemplateId(null, null).?);
    try std.testing.expectEqualStrings("custom", effectiveWorkspaceUpTemplateId(null, "custom").?);
    try std.testing.expect(effectiveWorkspaceUpTemplateId("ws-123", null) == null);
    try std.testing.expectEqualStrings("custom", effectiveWorkspaceUpTemplateId("ws-123", "custom").?);
}

fn executeWorkspaceDoctor(allocator: std.mem.Allocator, options: args.Options, cmd: args.Command) !void {
    _ = cmd;
    const stdout = std.fs.File.stdout().deprecatedWriter();
    const client = try getOrCreateClient(allocator, options);
    try ensureUnifiedV2Control(allocator, client);

    var cfg = try loadCliConfig(allocator);
    defer cfg.deinit();
    const project_id = resolveWorkspaceSelection(options, &cfg);

    var failures: usize = 0;

    var nodes = try control_plane.listNodes(allocator, client, &g_control_request_counter);
    defer workspace_types.deinitNodeList(allocator, &nodes);
    if (nodes.items.len == 0) {
        failures += 1;
        try stdout.print("[FAIL] No nodes are registered. Add at least one node before activation.\n", .{});
    } else {
        try stdout.print("[OK] Registered nodes: {d}\n", .{nodes.items.len});
    }

    var projects = try control_plane.listWorkspaces(allocator, client, &g_control_request_counter);
    defer workspace_types.deinitWorkspaceList(allocator, &projects);
    if (projects.items.len == 0) {
        failures += 1;
        try stdout.print("[FAIL] No workspaces exist. Run `workspace up <name>`.\n", .{});
    } else {
        try stdout.print("[OK] Workspaces: {d}\n", .{projects.items.len});
    }

    if (project_id == null) {
        failures += 1;
        try stdout.print("[FAIL] No workspace selected. Use `--workspace` or `workspace use`.\n", .{});
    } else {
        var status = try control_plane.workspaceStatus(
            allocator,
            client,
            &g_control_request_counter,
            project_id,
            if (project_id) |id|
                if (options.workspace_token) |token|
                    token
                else
                    cfg.getWorkspaceToken(id)
            else
                null,
        );
        defer status.deinit(allocator);
        if (status.mounts.items.len == 0 and status.actual_mounts.items.len == 0) {
            failures += 1;
            try stdout.print("[FAIL] Selected workspace has no active mounts.\n", .{});
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
        try stdout.print("workspace doctor: ready\n", .{});
    } else {
        try stdout.print("workspace doctor: {d} issue(s) detected\n", .{failures});
        return error.InvalidResponse;
    }
}

fn executeWorkspaceTemplateCommand(allocator: std.mem.Allocator, options: args.Options, cmd: args.Command) !void {
    const stdout = std.fs.File.stdout().deprecatedWriter();
    const client = try getOrCreateClient(allocator, options);
    try ensureUnifiedV2Control(allocator, client);

    const action = if (cmd.args.len > 0) cmd.args[0] else "list";
    if (std.mem.eql(u8, action, "list")) {
        var templates = try control_plane.listWorkspaceTemplates(allocator, client, &g_control_request_counter);
        defer workspace_types.deinitWorkspaceTemplateList(allocator, &templates);

        if (templates.items.len == 0) {
            try stdout.print("(no workspace templates)\n", .{});
            return;
        }

        try stdout.print("Workspace templates:\n", .{});
        for (templates.items) |template| {
            try stdout.print(
                "  - {s}  binds={d}  {s}\n",
                .{ template.id, template.binds.items.len, template.description },
            );
        }
        return;
    }

    if (std.mem.eql(u8, action, "info")) {
        if (cmd.args.len < 2) {
            logger.err("workspace template info requires a template ID", .{});
            return error.InvalidArguments;
        }
        var template = try control_plane.getWorkspaceTemplate(allocator, client, &g_control_request_counter, cmd.args[1]);
        defer template.deinit(allocator);

        try stdout.print("Workspace template {s}\n", .{template.id});
        try stdout.print("  Description: {s}\n", .{template.description});
        try stdout.print("  Binds ({d}):\n", .{template.binds.items.len});
        for (template.binds.items) |bind| {
            try stdout.print(
                "    - {s} <= venom:{s} host={s}\n",
                .{ bind.bind_path, bind.venom_id, bind.host_role },
            );
        }
        return;
    }

    logger.err("workspace template supports only list|info", .{});
    return error.InvalidArguments;
}

fn executeWorkspaceBindCommand(allocator: std.mem.Allocator, options: args.Options, cmd: args.Command) !void {
    if (cmd.args.len == 0) {
        logger.err("workspace bind requires add|remove|list", .{});
        return error.InvalidArguments;
    }

    const stdout = std.fs.File.stdout().deprecatedWriter();
    const client = try getOrCreateClient(allocator, options);
    try ensureUnifiedV2Control(allocator, client);

    var cfg = try loadCliConfig(allocator);
    defer cfg.deinit();

    const action = cmd.args[0];
    if (std.mem.eql(u8, action, "list")) {
        const workspace_id = if (cmd.args.len > 1)
            cmd.args[1]
        else
            resolveWorkspaceSelection(options, &cfg) orelse {
                logger.err("workspace bind list requires a workspace ID or selected workspace", .{});
                return error.InvalidArguments;
            };
        var detail = try control_plane.getWorkspace(allocator, client, &g_control_request_counter, workspace_id);
        defer detail.deinit(allocator);

        if (detail.binds.items.len == 0) {
            try stdout.print("(no workspace binds)\n", .{});
            return;
        }
        try stdout.print("Workspace binds for {s}:\n", .{workspace_id});
        for (detail.binds.items) |bind| {
            try stdout.print("  - {s} <= {s}\n", .{ bind.bind_path, bind.target_path });
        }
        return;
    }

    const workspace_id = resolveWorkspaceSelection(options, &cfg) orelse {
        logger.err("select a workspace first with --workspace or workspace use", .{});
        return error.InvalidArguments;
    };
    const workspace_token = if (options.workspace_token) |token| token else cfg.getWorkspaceToken(workspace_id);

    if (std.mem.eql(u8, action, "add")) {
        if (cmd.args.len < 3) {
            logger.err("workspace bind add requires <bind_path> <target_path>", .{});
            return error.InvalidArguments;
        }
        var detail = try control_plane.setWorkspaceBind(
            allocator,
            client,
            &g_control_request_counter,
            workspace_id,
            workspace_token,
            cmd.args[1],
            cmd.args[2],
        );
        defer detail.deinit(allocator);
        try stdout.print("Added bind to workspace {s}: {s} <= {s}\n", .{ workspace_id, cmd.args[1], cmd.args[2] });
        return;
    }

    if (std.mem.eql(u8, action, "remove")) {
        if (cmd.args.len < 2) {
            logger.err("workspace bind remove requires <bind_path>", .{});
            return error.InvalidArguments;
        }
        var detail = try control_plane.removeWorkspaceBind(
            allocator,
            client,
            &g_control_request_counter,
            workspace_id,
            workspace_token,
            cmd.args[1],
        );
        defer detail.deinit(allocator);
        try stdout.print("Removed bind from workspace {s}: {s}\n", .{ workspace_id, cmd.args[1] });
        return;
    }

    logger.err("workspace bind supports only add|remove|list", .{});
    return error.InvalidArguments;
}

fn executeWorkspaceMountCommand(allocator: std.mem.Allocator, options: args.Options, cmd: args.Command) !void {
    if (cmd.args.len == 0) {
        logger.err("workspace mount requires add|remove|list", .{});
        return error.InvalidArguments;
    }

    const stdout = std.fs.File.stdout().deprecatedWriter();
    const client = try getOrCreateClient(allocator, options);
    try ensureUnifiedV2Control(allocator, client);

    var cfg = try loadCliConfig(allocator);
    defer cfg.deinit();

    const action = cmd.args[0];
    if (std.mem.eql(u8, action, "list")) {
        const workspace_id = if (cmd.args.len > 1)
            cmd.args[1]
        else
            resolveWorkspaceSelection(options, &cfg) orelse {
                logger.err("workspace mount list requires a workspace ID or selected workspace", .{});
                return error.InvalidArguments;
            };
        var detail = try control_plane.getWorkspace(allocator, client, &g_control_request_counter, workspace_id);
        defer detail.deinit(allocator);

        if (detail.mounts.items.len == 0) {
            try stdout.print("(no workspace mounts)\n", .{});
            return;
        }
        try stdout.print("Workspace mounts for {s}:\n", .{workspace_id});
        for (detail.mounts.items) |mount| {
            try stdout.print("  - {s} <= {s}:{s}\n", .{ mount.mount_path, mount.node_id, mount.export_name });
        }
        return;
    }

    const workspace_id = resolveWorkspaceSelection(options, &cfg) orelse {
        logger.err("select a workspace first with --workspace or workspace use", .{});
        return error.InvalidArguments;
    };
    const workspace_token = if (options.workspace_token) |token| token else cfg.getWorkspaceToken(workspace_id);

    if (std.mem.eql(u8, action, "add")) {
        if (cmd.args.len < 4) {
            logger.err("workspace mount add requires <mount_path> <node_id> <export_name>", .{});
            return error.InvalidArguments;
        }
        var detail = try control_plane.setWorkspaceMount(
            allocator,
            client,
            &g_control_request_counter,
            workspace_id,
            workspace_token,
            cmd.args[2],
            cmd.args[3],
            cmd.args[1],
        );
        defer detail.deinit(allocator);
        try stdout.print("Added mount to workspace {s}: {s} <= {s}:{s}\n", .{ workspace_id, cmd.args[1], cmd.args[2], cmd.args[3] });
        return;
    }

    if (std.mem.eql(u8, action, "remove")) {
        if (cmd.args.len < 2) {
            logger.err("workspace mount remove requires <mount_path> [node_id export_name]", .{});
            return error.InvalidArguments;
        }
        const node_id_filter: ?[]const u8 = if (cmd.args.len >= 4) cmd.args[2] else null;
        const export_name_filter: ?[]const u8 = if (cmd.args.len >= 4) cmd.args[3] else null;
        if (cmd.args.len == 3 or cmd.args.len > 4) return error.InvalidArguments;
        var detail = try control_plane.removeWorkspaceMount(
            allocator,
            client,
            &g_control_request_counter,
            workspace_id,
            workspace_token,
            cmd.args[1],
            node_id_filter,
            export_name_filter,
        );
        defer detail.deinit(allocator);
        try stdout.print("Removed mount from workspace {s}: {s}\n", .{ workspace_id, cmd.args[1] });
        return;
    }

    logger.err("workspace mount supports only add|remove|list", .{});
    return error.InvalidArguments;
}

fn executeWorkspaceHandoffCommand(allocator: std.mem.Allocator, options: args.Options, cmd: args.Command) !void {
    const action = if (cmd.args.len > 0) cmd.args[0] else "show";
    if (!std.mem.eql(u8, action, "show")) {
        logger.err("workspace handoff supports only show", .{});
        return error.InvalidArguments;
    }

    const stdout = std.fs.File.stdout().deprecatedWriter();
    const client = try getOrCreateClient(allocator, options);
    try ensureUnifiedV2Control(allocator, client);

    var cfg = try loadCliConfig(allocator);
    defer cfg.deinit();

    var profile: []const u8 = "generic";
    var mount_path: []const u8 = "./workspace";
    var explicit_workspace_id: ?[]const u8 = null;
    var i: usize = 1;
    while (i < cmd.args.len) : (i += 1) {
        const arg = cmd.args[i];
        if (std.mem.eql(u8, arg, "--mount-path")) {
            i += 1;
            if (i >= cmd.args.len) return error.InvalidArguments;
            mount_path = cmd.args[i];
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--")) return error.InvalidArguments;
        if (std.mem.eql(u8, arg, "generic") or std.mem.eql(u8, arg, "codex_app") or std.mem.eql(u8, arg, "spider_monkey")) {
            profile = arg;
            continue;
        }
        if (explicit_workspace_id != null) return error.InvalidArguments;
        explicit_workspace_id = arg;
    }
    const workspace_id = explicit_workspace_id orelse resolveWorkspaceSelection(options, &cfg) orelse {
        logger.err("workspace handoff show requires a workspace ID or selected workspace", .{});
        return error.InvalidArguments;
    };
    const workspace_token = if (options.workspace_token) |token| token else cfg.getWorkspaceToken(workspace_id);
    const auth_token = cfg.activeRoleToken();

    var detail = try control_plane.getWorkspace(allocator, client, &g_control_request_counter, workspace_id);
    defer detail.deinit(allocator);
    var status = try control_plane.workspaceStatus(
        allocator,
        client,
        &g_control_request_counter,
        workspace_id,
        workspace_token,
    );
    defer status.deinit(allocator);

    try stdout.print("Workspace handoff for {s}\n", .{workspace_id});
    try stdout.print("  Profile: {s}\n", .{profile});
    try stdout.print("  Template: {s}\n", .{detail.template_id orelse "dev"});
    try stdout.print("  Mounts: {d}\n", .{detail.mounts.items.len});
    try stdout.print("  Binds: {d}\n", .{detail.binds.items.len});
    if (status.workspace_root) |workspace_root| {
        try stdout.print("  Workspace root: {s}\n", .{workspace_root});
    }
    try stdout.print("  Local mount path: {s}\n", .{mount_path});

    try stdout.print("\nWorkspace mount:\n", .{});
    try stdout.print(
        "  spiderweb-fs-mount --workspace-url {s} --auth-token {s} --workspace-id {s} mount {s}\n",
        .{
            client.url,
            if (auth_token.len > 0) auth_token else "<auth-token>",
            workspace_id,
            mount_path,
        },
    );
    if (workspace_token) |token| {
        try stdout.print(
            "  spiderweb-fs-mount --workspace-url {s} --workspace-id {s} --workspace-token {s} mount {s}\n",
            .{ client.url, workspace_id, token, mount_path },
        );
    } else {
        try stdout.print(
            "  spiderweb-fs-mount --workspace-url {s} --workspace-id {s} --workspace-token <workspace-token> mount {s}\n",
            .{ client.url, workspace_id, mount_path },
        );
    }

    try stdout.print("\nNamespace fallback:\n", .{});
    try stdout.print(
        "  spiderweb-fs-mount --namespace-url {s} --workspace-id {s} mount {s}\n",
        .{ client.url, workspace_id, mount_path },
    );

    if (std.mem.eql(u8, profile, "codex_app")) {
        try stdout.print("\nCodex App:\n", .{});
        try stdout.print("  1. Mount the workspace using one of the commands above.\n", .{});
        try stdout.print("  2. Open {s} in Codex App.\n", .{mount_path});
    } else if (std.mem.eql(u8, profile, "spider_monkey")) {
        try stdout.print("\nSpiderMonkey:\n", .{});
        try stdout.print("  spider-monkey run --workspace-root {s}\n", .{mount_path});
    } else {
        try stdout.print("\nGeneric external runtime:\n", .{});
        try stdout.print("  Open {s} in your external runtime after the mount is ready.\n", .{mount_path});
    }
}

fn executeAgentList(allocator: std.mem.Allocator, options: args.Options, cmd: args.Command) !void {
    _ = cmd;
    const stdout = std.fs.File.stdout().deprecatedWriter();
    const client = try getOrCreateClient(allocator, options);
    try ensureUnifiedV2Control(allocator, client);

    var agents = try control_plane.listAgents(allocator, client, &g_control_request_counter);
    defer workspace_types.deinitAgentList(allocator, &agents);
    if (agents.items.len == 0) {
        try stdout.print("(no agents)\n", .{});
        return;
    }

    try stdout.print("Agents:\n", .{});
    for (agents.items) |agent| {
        const default_marker = if (agent.is_default) " [default]" else "";
        const hatching_marker = if (agent.needs_hatching) " [needs_hatching]" else "";
        try stdout.print(
            "  - {s} ({s}){s}{s}\n",
            .{ agent.id, agent.name, default_marker, hatching_marker },
        );
    }
}

fn executeAgentInfo(allocator: std.mem.Allocator, options: args.Options, cmd: args.Command) !void {
    if (cmd.args.len == 0) {
        logger.err("agent info requires an agent ID", .{});
        return error.InvalidArguments;
    }

    const stdout = std.fs.File.stdout().deprecatedWriter();
    const client = try getOrCreateClient(allocator, options);
    try ensureUnifiedV2Control(allocator, client);

    var agent = try control_plane.getAgent(allocator, client, &g_control_request_counter, cmd.args[0]);
    defer agent.deinit(allocator);

    try stdout.print("Agent {s}\n", .{agent.id});
    try stdout.print("  Name: {s}\n", .{agent.name});
    try stdout.print("  Description: {s}\n", .{agent.description});
    try stdout.print("  Default: {s}\n", .{if (agent.is_default) "yes" else "no"});
    try stdout.print("  Identity loaded: {s}\n", .{if (agent.identity_loaded) "yes" else "no"});
    try stdout.print("  Needs hatching: {s}\n", .{if (agent.needs_hatching) "yes" else "no"});
    if (agent.capabilities.items.len == 0) {
        try stdout.print("  Capabilities: (none)\n", .{});
    } else {
        try stdout.print("  Capabilities:\n", .{});
        for (agent.capabilities.items) |capability| {
            try stdout.print("    - {s}\n", .{capability});
        }
    }
}

fn printSessionAttachStatus(stdout: anytype, status: *const workspace_types.SessionAttachStatus) !void {
    try stdout.print("Session: {s}\n", .{status.session_key});
    try stdout.print("  Agent: {s}\n", .{status.agent_id});
    if (status.workspace_id) |project_id| {
        try stdout.print("  Workspace: {s}\n", .{project_id});
    } else {
        try stdout.print("  Workspace: (none)\n", .{});
    }
    try stdout.print(
        "  Attach state: {s} (runtime_ready={s}, mount_ready={s})\n",
        .{
            status.state,
            if (status.runtime_ready) "yes" else "no",
            if (status.mount_ready) "yes" else "no",
        },
    );
    try stdout.print("  Updated: {d}\n", .{status.updated_at_ms});
    if (status.error_code) |code| {
        try stdout.print(
            "  Error: {s}{s}{s}\n",
            .{
                code,
                if (status.error_message != null) " - " else "",
                if (status.error_message) |message| message else "",
            },
        );
    }
}

fn executeSessionList(allocator: std.mem.Allocator, options: args.Options, cmd: args.Command) !void {
    _ = cmd;
    const stdout = std.fs.File.stdout().deprecatedWriter();
    const client = try getOrCreateClient(allocator, options);
    try ensureUnifiedV2Control(allocator, client);

    var list = try control_plane.listSessions(allocator, client, &g_control_request_counter);
    defer list.deinit(allocator);

    try stdout.print("Active session: {s}\n", .{list.active_session});
    if (list.sessions.items.len == 0) {
        try stdout.print("(no sessions)\n", .{});
        return;
    }

    try stdout.print("Sessions:\n", .{});
    for (list.sessions.items) |session| {
        const marker = if (std.mem.eql(u8, session.session_key, list.active_session)) "*" else " ";
        if (session.workspace_id) |project_id| {
            try stdout.print(
                "{s} {s}  agent={s}  workspace={s}\n",
                .{ marker, session.session_key, session.agent_id, project_id },
            );
        } else {
            try stdout.print(
                "{s} {s}  agent={s}  workspace=(none)\n",
                .{ marker, session.session_key, session.agent_id },
            );
        }
    }
}

const SessionHistoryArgs = struct {
    agent_id: ?[]const u8 = null,
    limit: usize = 10,
};

fn parseSessionHistoryArgs(cmd: args.Command) !SessionHistoryArgs {
    var parsed = SessionHistoryArgs{};
    var i: usize = 0;
    while (i < cmd.args.len) : (i += 1) {
        const arg = cmd.args[i];
        if (std.mem.eql(u8, arg, "--limit")) {
            i += 1;
            if (i >= cmd.args.len) return error.InvalidArguments;
            const value = try std.fmt.parseUnsigned(usize, cmd.args[i], 10);
            parsed.limit = value;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--")) return error.InvalidArguments;
        if (parsed.agent_id != null) return error.InvalidArguments;
        parsed.agent_id = arg;
    }
    return parsed;
}

fn executeSessionHistory(allocator: std.mem.Allocator, options: args.Options, cmd: args.Command) !void {
    const parsed = parseSessionHistoryArgs(cmd) catch {
        logger.err("session history usage: session history [agent_id] [--limit <n>]", .{});
        return error.InvalidArguments;
    };

    const stdout = std.fs.File.stdout().deprecatedWriter();
    const client = try getOrCreateClient(allocator, options);
    try ensureUnifiedV2Control(allocator, client);

    var sessions = try control_plane.sessionHistory(
        allocator,
        client,
        &g_control_request_counter,
        parsed.agent_id,
        parsed.limit,
    );
    defer {
        for (sessions.items) |*entry| entry.deinit(allocator);
        sessions.deinit(allocator);
    }
    if (sessions.items.len == 0) {
        try stdout.print("(no persisted sessions)\n", .{});
        return;
    }

    try stdout.print("Persisted sessions:\n", .{});
    for (sessions.items) |session| {
        try stdout.print(
            "  - {s}  agent={s}  workspace={s}  last_active_ms={d}  messages={d}",
            .{
                session.session_key,
                session.agent_id,
                session.workspace_id orelse "(none)",
                session.last_active_ms,
                session.message_count,
            },
        );
        if (session.summary) |summary| {
            try stdout.print("  summary={s}", .{summary});
        }
        try stdout.print("\n", .{});
    }
}

fn executeSessionStatus(allocator: std.mem.Allocator, options: args.Options, cmd: args.Command) !void {
    if (cmd.args.len > 1) {
        logger.err("session status accepts zero or one session_key", .{});
        return error.InvalidArguments;
    }

    const stdout = std.fs.File.stdout().deprecatedWriter();
    const client = try getOrCreateClient(allocator, options);
    try ensureUnifiedV2Control(allocator, client);

    var status = try control_plane.sessionStatus(
        allocator,
        client,
        &g_control_request_counter,
        if (cmd.args.len == 1) cmd.args[0] else null,
    );
    defer status.deinit(allocator);
    try printSessionAttachStatus(stdout, &status);
}

const SessionAttachArgs = struct {
    session_key: []const u8,
    agent_id: []const u8,
    workspace_id: ?[]const u8 = null,
    workspace_token: ?[]const u8 = null,
};

fn parseSessionAttachArgs(options: args.Options, cmd: args.Command) !SessionAttachArgs {
    var parsed = SessionAttachArgs{
        .session_key = undefined,
        .agent_id = undefined,
        .workspace_id = options.workspace,
        .workspace_token = options.workspace_token,
    };

    var positional: [2][]const u8 = undefined;
    var positional_count: usize = 0;
    var i: usize = 0;
    while (i < cmd.args.len) : (i += 1) {
        const arg = cmd.args[i];
        if (std.mem.eql(u8, arg, "--workspace")) {
            i += 1;
            if (i >= cmd.args.len) return error.InvalidArguments;
            parsed.workspace_id = cmd.args[i];
            continue;
        }
        if (std.mem.eql(u8, arg, "--workspace-token")) {
            i += 1;
            if (i >= cmd.args.len) return error.InvalidArguments;
            parsed.workspace_token = cmd.args[i];
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--")) return error.InvalidArguments;
        if (positional_count >= positional.len) return error.InvalidArguments;
        positional[positional_count] = arg;
        positional_count += 1;
    }

    if (positional_count != 2) return error.InvalidArguments;
    parsed.session_key = positional[0];
    parsed.agent_id = positional[1];
    return parsed;
}

fn executeSessionAttach(allocator: std.mem.Allocator, options: args.Options, cmd: args.Command) !void {
    const parsed = parseSessionAttachArgs(options, cmd) catch {
        logger.err("session attach usage: session attach <session_key> <agent_id> --workspace <workspace_id> [--workspace-token <token>]", .{});
        return error.InvalidArguments;
    };
    const workspace_id = parsed.workspace_id orelse {
        logger.err("session attach requires --workspace <workspace_id>", .{});
        return error.InvalidArguments;
    };

    const stdout = std.fs.File.stdout().deprecatedWriter();
    const client = try getOrCreateClient(allocator, options);
    try ensureUnifiedV2Control(allocator, client);

    var status = try control_plane.sessionAttach(
        allocator,
        client,
        &g_control_request_counter,
        parsed.session_key,
        parsed.agent_id,
        workspace_id,
        parsed.workspace_token,
    );
    defer status.deinit(allocator);
    try printSessionAttachStatus(stdout, &status);
}

fn executeSessionResume(allocator: std.mem.Allocator, options: args.Options, cmd: args.Command) !void {
    if (cmd.args.len != 1) {
        logger.err("session resume requires a session_key", .{});
        return error.InvalidArguments;
    }

    const stdout = std.fs.File.stdout().deprecatedWriter();
    const client = try getOrCreateClient(allocator, options);
    try ensureUnifiedV2Control(allocator, client);

    var status = try control_plane.sessionResume(allocator, client, &g_control_request_counter, cmd.args[0]);
    defer status.deinit(allocator);
    try printSessionAttachStatus(stdout, &status);
}

fn executeSessionClose(allocator: std.mem.Allocator, options: args.Options, cmd: args.Command) !void {
    if (cmd.args.len != 1) {
        logger.err("session close requires a session_key", .{});
        return error.InvalidArguments;
    }

    const stdout = std.fs.File.stdout().deprecatedWriter();
    const client = try getOrCreateClient(allocator, options);
    try ensureUnifiedV2Control(allocator, client);

    var result = try control_plane.closeSession(allocator, client, &g_control_request_counter, cmd.args[0]);
    defer result.deinit(allocator);

    try stdout.print("Closed: {s}\n", .{if (result.closed) "yes" else "no"});
    try stdout.print("Session: {s}\n", .{result.session_key});
    try stdout.print("Active session: {s}\n", .{result.active_session});
}

fn executeSessionRestore(allocator: std.mem.Allocator, options: args.Options, cmd: args.Command) !void {
    if (cmd.args.len > 1) {
        logger.err("session restore accepts zero or one agent_id", .{});
        return error.InvalidArguments;
    }

    const stdout = std.fs.File.stdout().deprecatedWriter();
    const client = try getOrCreateClient(allocator, options);
    try ensureUnifiedV2Control(allocator, client);
    var cfg = try loadCliConfig(allocator);
    defer cfg.deinit();

    var restored = try control_plane.sessionRestore(
        allocator,
        client,
        &g_control_request_counter,
        if (cmd.args.len == 1) cmd.args[0] else null,
    );
    defer restored.deinit(allocator);

    if (!restored.found or restored.session == null) {
        try stdout.print("(no persisted session found)\n", .{});
        return;
    }
    const session = restored.session.?;
    const attach_project_id = session.workspace_id orelse {
        logger.err(
            "restored session has no workspace_id; choose a workspace and run: session attach {s} {s} --workspace <workspace_id>",
            .{ session.session_key, session.agent_id },
        );
        return error.InvalidResponse;
    };
    const project_token = if (options.workspace_token) |token|
        token
    else
        cfg.getWorkspaceToken(attach_project_id);
    try stdout.print(
        "Restoring session {s} (agent={s}, workspace={s})\n",
        .{ session.session_key, session.agent_id, session.workspace_id orelse "(none)" },
    );

    const attach_agent = if (isSystemWorkspaceId(attach_project_id))
        try allocator.dupe(u8, system_agent_id)
    else if (isSystemAgentId(session.agent_id))
        resolveAttachAgentForWorkspace(
            allocator,
            options,
            &cfg,
            client,
            session.session_key,
            attach_project_id,
        ) catch |err| {
            if (err == error.UserRoleCannotAttachSystemProject) {
                logger.err("user role cannot attach to the system workspace; choose a non-system workspace", .{});
            } else if (err == error.NoProjectCompatibleAgent) {
                logger.err("no non-system agent is available for workspace {s}", .{attach_project_id});
            }
            return err;
        }
    else
        try allocator.dupe(u8, session.agent_id);
    defer allocator.free(attach_agent);

    var status = try control_plane.sessionAttach(
        allocator,
        client,
        &g_control_request_counter,
        session.session_key,
        attach_agent,
        attach_project_id,
        project_token,
    );
    defer status.deinit(allocator);
    try printSessionAttachStatus(stdout, &status);
}

fn executeNodeList(allocator: std.mem.Allocator, options: args.Options, cmd: args.Command) !void {
    _ = cmd;
    const stdout = std.fs.File.stdout().deprecatedWriter();
    const client = try getOrCreateClient(allocator, options);
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
    const client = try getOrCreateClient(allocator, options);
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

const NodeLabelArg = struct {
    key: []const u8,
    value: []const u8,
};

fn parseNodeLabelArg(raw: []const u8) !NodeLabelArg {
    const eq_idx = std.mem.indexOfScalar(u8, raw, '=') orelse return error.InvalidArguments;
    if (eq_idx == 0) return error.InvalidArguments;
    return .{
        .key = raw[0..eq_idx],
        .value = raw[eq_idx + 1 ..],
    };
}

fn jsonObjectStringOr(obj: std.json.ObjectMap, name: []const u8, fallback: []const u8) []const u8 {
    const value = obj.get(name) orelse return fallback;
    if (value != .string) return fallback;
    return value.string;
}

fn jsonObjectI64Or(obj: std.json.ObjectMap, name: []const u8, fallback: i64) i64 {
    const value = obj.get(name) orelse return fallback;
    if (value != .integer) return fallback;
    return value.integer;
}

fn jsonObjectBoolOr(obj: std.json.ObjectMap, name: []const u8, fallback: bool) bool {
    const value = obj.get(name) orelse return fallback;
    if (value != .bool) return fallback;
    return value.bool;
}

fn jsonPlatformFieldOr(root: std.json.ObjectMap, name: []const u8, fallback: []const u8) []const u8 {
    const platform = root.get("platform") orelse return fallback;
    if (platform != .object) return fallback;
    return jsonObjectStringOr(platform.object, name, fallback);
}

fn printNodeServiceCatalogPayload(
    allocator: std.mem.Allocator,
    stdout: anytype,
    payload_json: []const u8,
) !void {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, payload_json, .{}) catch {
        try stdout.print("{s}\n", .{payload_json});
        return;
    };
    defer parsed.deinit();
    if (parsed.value != .object) {
        try stdout.print("{s}\n", .{payload_json});
        return;
    }

    const root = parsed.value.object;
    try stdout.print(
        "Node venoms for {s} ({s})\n",
        .{
            jsonObjectStringOr(root, "node_id", "(unknown)"),
            jsonObjectStringOr(root, "node_name", "(unknown)"),
        },
    );
    try stdout.print(
        "  Platform: os={s} arch={s} runtime={s}\n",
        .{
            jsonPlatformFieldOr(root, "os", "unknown"),
            jsonPlatformFieldOr(root, "arch", "unknown"),
            jsonPlatformFieldOr(root, "runtime_kind", "unknown"),
        },
    );

    if (root.get("labels")) |labels_val| {
        if (labels_val == .object and labels_val.object.count() > 0) {
            try stdout.print("  Labels:\n", .{});
            var label_it = labels_val.object.iterator();
            while (label_it.next()) |entry| {
                if (entry.value_ptr.* != .string) continue;
                try stdout.print("    - {s}={s}\n", .{ entry.key_ptr.*, entry.value_ptr.*.string });
            }
        } else {
            try stdout.print("  Labels: (none)\n", .{});
        }
    } else {
        try stdout.print("  Labels: (none)\n", .{});
    }

    if (root.get("venoms")) |venoms_val| {
        if (venoms_val == .array and venoms_val.array.items.len > 0) {
            try stdout.print("  Venoms ({d}):\n", .{venoms_val.array.items.len});
            for (venoms_val.array.items) |venom_val| {
                if (venom_val != .object) continue;
                const venom = venom_val.object;
                try stdout.print(
                    "    - {s} kind={s} version={s} state={s}\n",
                    .{
                        jsonObjectStringOr(venom, "venom_id", "(unknown)"),
                        jsonObjectStringOr(venom, "kind", "(unknown)"),
                        jsonObjectStringOr(venom, "version", "1"),
                        jsonObjectStringOr(venom, "state", "(unknown)"),
                    },
                );
                if (venom.get("endpoints")) |endpoints_val| {
                    if (endpoints_val == .array and endpoints_val.array.items.len > 0) {
                        for (endpoints_val.array.items) |endpoint| {
                            if (endpoint != .string) continue;
                            try stdout.print("      endpoint: {s}\n", .{endpoint.string});
                        }
                    }
                }
                if (venom.get("capabilities")) |caps| {
                    try stdout.print("      capabilities: {f}\n", .{std.json.fmt(caps, .{})});
                }
            }
        } else {
            try stdout.print("  Venoms: (none)\n", .{});
        }
    } else {
        try stdout.print("  Venoms: (none)\n", .{});
    }
}

fn jsonArrayLenOr(obj: std.json.ObjectMap, name: []const u8) usize {
    const value = obj.get(name) orelse return 0;
    if (value != .array) return 0;
    return value.array.items.len;
}

fn printNodeServiceEventPayload(
    allocator: std.mem.Allocator,
    stdout: anytype,
    payload_value: std.json.Value,
    verbose: bool,
) !void {
    if (payload_value != .object) {
        try stdout.print("node_service_event payload is not an object\n", .{});
        return;
    }
    const payload = payload_value.object;
    const node_id = jsonObjectStringOr(payload, "node_id", "(unknown)");
    const delta_value = payload.get("service_delta");
    if (delta_value) |value| {
        if (value == .object) {
            const delta = value.object;
            try stdout.print(
                "node_service_event node={s} changed={} added={d} updated={d} removed={d} ts_ms={d}\n",
                .{
                    node_id,
                    jsonObjectBoolOr(delta, "changed", false),
                    jsonArrayLenOr(delta, "added"),
                    jsonArrayLenOr(delta, "updated"),
                    jsonArrayLenOr(delta, "removed"),
                    jsonObjectI64Or(delta, "timestamp_ms", 0),
                },
            );
        } else {
            try stdout.print("node_service_event node={s} (delta malformed)\n", .{node_id});
        }
    } else {
        try stdout.print("node_service_event node={s}\n", .{node_id});
    }

    if (!verbose) return;
    const payload_json = try std.fmt.allocPrint(
        allocator,
        "{f}",
        .{std.json.fmt(payload_value, .{ .whitespace = .indent_2 })},
    );
    defer allocator.free(payload_json);
    try stdout.print("{s}\n", .{payload_json});
}

fn nodeServiceSnapshotLineMatchesFilterCli(
    allocator: std.mem.Allocator,
    line: []const u8,
    node_filter: ?[]const u8,
) !bool {
    const filter = node_filter orelse return true;
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch return false;
    defer parsed.deinit();
    if (parsed.value != .object) return false;
    const root = parsed.value.object;
    const node_id = root.get("node_id") orelse return false;
    if (node_id != .string) return false;
    return std.mem.eql(u8, node_id.string, filter);
}

fn printNodeServiceSnapshotChunk(
    allocator: std.mem.Allocator,
    stdout: anytype,
    snapshot: []const u8,
    node_filter: ?[]const u8,
    replay_limit: usize,
    verbose: bool,
    full_refresh: bool,
) !void {
    var matching_lines = std.ArrayListUnmanaged([]const u8){};
    defer matching_lines.deinit(allocator);

    var lines = std.mem.splitScalar(u8, snapshot, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r\n");
        if (line.len == 0) continue;
        if (!try nodeServiceSnapshotLineMatchesFilterCli(allocator, line, node_filter)) continue;
        try matching_lines.append(allocator, line);
    }

    const start_index = if (full_refresh and replay_limit > 0 and matching_lines.items.len > replay_limit)
        matching_lines.items.len - replay_limit
    else
        0;

    for (matching_lines.items[start_index..]) |line| {
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch continue;
        defer parsed.deinit();
        if (parsed.value != .object) continue;
        const payload = parsed.value.object.get("payload") orelse continue;
        try printNodeServiceEventPayload(allocator, stdout, payload, verbose);
    }
}

fn executeNodeServiceWatch(allocator: std.mem.Allocator, options: args.Options, cmd: args.Command) !void {
    var node_filter: ?[]const u8 = null;
    var replay_limit: usize = 25;
    var i: usize = 0;
    while (i < cmd.args.len) : (i += 1) {
        const arg = cmd.args[i];
        if (std.mem.eql(u8, arg, "--replay-limit")) {
            i += 1;
            if (i >= cmd.args.len) {
                logger.err("node watch --replay-limit requires a numeric value", .{});
                return error.InvalidArguments;
            }
            replay_limit = std.fmt.parseUnsigned(usize, cmd.args[i], 10) catch {
                logger.err("node watch --replay-limit must be an unsigned integer", .{});
                return error.InvalidArguments;
            };
            if (replay_limit > 10_000) replay_limit = 10_000;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--replay-limit=")) {
            const value = arg["--replay-limit=".len..];
            replay_limit = std.fmt.parseUnsigned(usize, value, 10) catch {
                logger.err("node watch --replay-limit must be an unsigned integer", .{});
                return error.InvalidArguments;
            };
            if (replay_limit > 10_000) replay_limit = 10_000;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--")) {
            logger.err("node watch unknown option: {s}", .{arg});
            return error.InvalidArguments;
        }
        if (node_filter != null) {
            logger.err("node watch accepts at most one optional <node_id> filter", .{});
            return error.InvalidArguments;
        }
        node_filter = arg;
    }

    const stdout = std.fs.File.stdout().deprecatedWriter();
    const client = try getOrCreateClient(allocator, options);
    try maybeApplyWorkspaceContext(allocator, options, client);
    try ensureUnifiedV2Control(allocator, client);

    if (node_filter) |node_id| {
        try stdout.print(
            "Watching node venom events for node {s} via /.spiderweb/catalog/node-venom-events.ndjson (replay_limit={d}, Ctrl+C to stop)\n",
            .{ node_id, replay_limit },
        );
    } else {
        try stdout.print(
            "Watching node venom events for all nodes via /.spiderweb/catalog/node-venom-events.ndjson (replay_limit={d}, Ctrl+C to stop)\n",
            .{replay_limit},
        );
    }

    var previous_snapshot: ?[]u8 = null;
    defer if (previous_snapshot) |value| allocator.free(value);

    while (true) {
        const snapshot = mountReadPathText(allocator, client, "/.spiderweb/catalog/node-venom-events.ndjson") catch |err| {
            logger.err("node watch read failed: {s}", .{@errorName(err)});
            return err;
        };
        defer allocator.free(snapshot);

        if (previous_snapshot) |previous| {
            if (std.mem.eql(u8, previous, snapshot)) {
                std.Thread.sleep(1 * std.time.ns_per_s);
                continue;
            }
            if (snapshot.len >= previous.len and std.mem.startsWith(u8, snapshot, previous)) {
                try printNodeServiceSnapshotChunk(
                    allocator,
                    stdout,
                    snapshot[previous.len..],
                    node_filter,
                    replay_limit,
                    options.verbose,
                    false,
                );
            } else {
                try printNodeServiceSnapshotChunk(
                    allocator,
                    stdout,
                    snapshot,
                    node_filter,
                    replay_limit,
                    options.verbose,
                    true,
                );
            }
            allocator.free(previous);
            previous_snapshot = try allocator.dupe(u8, snapshot);
        } else {
            try printNodeServiceSnapshotChunk(
                allocator,
                stdout,
                snapshot,
                node_filter,
                replay_limit,
                options.verbose,
                true,
            );
            previous_snapshot = try allocator.dupe(u8, snapshot);
        }

        std.Thread.sleep(1 * std.time.ns_per_s);
    }
}

fn executeNodeJoinRequest(allocator: std.mem.Allocator, options: args.Options, cmd: args.Command) !void {
    if (cmd.args.len == 0) {
        logger.err("node join-request requires <node_name> [fs_url]", .{});
        return error.InvalidArguments;
    }

    var fs_url: ?[]const u8 = null;
    var platform_os: ?[]const u8 = null;
    var platform_arch: ?[]const u8 = null;
    var platform_runtime_kind: ?[]const u8 = null;

    var i: usize = 1;
    if (i < cmd.args.len and !std.mem.startsWith(u8, cmd.args[i], "--")) {
        fs_url = cmd.args[i];
        i += 1;
    }

    while (i < cmd.args.len) : (i += 1) {
        const arg = cmd.args[i];
        if (std.mem.eql(u8, arg, "--os")) {
            i += 1;
            if (i >= cmd.args.len) return error.InvalidArguments;
            platform_os = cmd.args[i];
            continue;
        }
        if (std.mem.eql(u8, arg, "--arch")) {
            i += 1;
            if (i >= cmd.args.len) return error.InvalidArguments;
            platform_arch = cmd.args[i];
            continue;
        }
        if (std.mem.eql(u8, arg, "--runtime-kind")) {
            i += 1;
            if (i >= cmd.args.len) return error.InvalidArguments;
            platform_runtime_kind = cmd.args[i];
            continue;
        }
        return error.InvalidArguments;
    }

    const stdout = std.fs.File.stdout().deprecatedWriter();
    const client = try getOrCreateClient(allocator, options);
    try ensureUnifiedV2Control(allocator, client);

    var payload = std.ArrayListUnmanaged(u8){};
    defer payload.deinit(allocator);
    try payload.append(allocator, '{');

    const escaped_name = try unified.jsonEscape(allocator, cmd.args[0]);
    defer allocator.free(escaped_name);
    try payload.writer(allocator).print("\"node_name\":\"{s}\"", .{escaped_name});
    if (fs_url) |value| {
        const escaped_url = try unified.jsonEscape(allocator, value);
        defer allocator.free(escaped_url);
        try payload.writer(allocator).print(",\"fs_url\":\"{s}\"", .{escaped_url});
    }

    if (platform_os != null or platform_arch != null or platform_runtime_kind != null) {
        try payload.appendSlice(allocator, ",\"platform\":{");
        var platform_fields: usize = 0;
        if (platform_os) |value| {
            const escaped = try unified.jsonEscape(allocator, value);
            defer allocator.free(escaped);
            try payload.writer(allocator).print("\"os\":\"{s}\"", .{escaped});
            platform_fields += 1;
        }
        if (platform_arch) |value| {
            const escaped = try unified.jsonEscape(allocator, value);
            defer allocator.free(escaped);
            if (platform_fields > 0) try payload.append(allocator, ',');
            try payload.writer(allocator).print("\"arch\":\"{s}\"", .{escaped});
            platform_fields += 1;
        }
        if (platform_runtime_kind) |value| {
            const escaped = try unified.jsonEscape(allocator, value);
            defer allocator.free(escaped);
            if (platform_fields > 0) try payload.append(allocator, ',');
            try payload.writer(allocator).print("\"runtime_kind\":\"{s}\"", .{escaped});
        }
        try payload.append(allocator, '}');
    }
    try payload.append(allocator, '}');

    const payload_json = try control_plane.requestControlPayloadJson(
        allocator,
        client,
        &g_control_request_counter,
        "control.node_join_request",
        payload.items,
    );
    defer allocator.free(payload_json);

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, payload_json, .{}) catch {
        try stdout.print("{s}\n", .{payload_json});
        return;
    };
    defer parsed.deinit();
    if (parsed.value != .object) {
        try stdout.print("{s}\n", .{payload_json});
        return;
    }

    const root = parsed.value.object;
    try stdout.print("Pending node join request created\n", .{});
    try stdout.print("  Request: {s}\n", .{jsonObjectStringOr(root, "request_id", "(unknown)")});
    try stdout.print("  Node: {s}\n", .{jsonObjectStringOr(root, "node_name", "(unknown)")});
    try stdout.print("  FS URL: {s}\n", .{jsonObjectStringOr(root, "fs_url", "")});
    try stdout.print(
        "  Platform: os={s} arch={s} runtime={s}\n",
        .{
            jsonPlatformFieldOr(root, "os", "unknown"),
            jsonPlatformFieldOr(root, "arch", "unknown"),
            jsonPlatformFieldOr(root, "runtime_kind", "unknown"),
        },
    );
    try stdout.print("  Requested at: {d}\n", .{jsonObjectI64Or(root, "requested_at_ms", 0)});
}

fn executeNodePendingList(allocator: std.mem.Allocator, options: args.Options, cmd: args.Command) !void {
    if (cmd.args.len != 0) {
        logger.err("node pending does not accept arguments", .{});
        return error.InvalidArguments;
    }

    var cfg = try loadCliConfig(allocator);
    defer cfg.deinit();

    const stdout = std.fs.File.stdout().deprecatedWriter();
    const client = try getOrCreateClient(allocator, options);
    try ensureUnifiedV2Control(allocator, client);

    var payload = std.ArrayListUnmanaged(u8){};
    defer payload.deinit(allocator);
    try payload.append(allocator, '{');
    if (resolveOperatorToken(options, &cfg)) |token| {
        const escaped_token = try unified.jsonEscape(allocator, token);
        defer allocator.free(escaped_token);
        try payload.writer(allocator).print("\"operator_token\":\"{s}\"", .{escaped_token});
    }
    try payload.append(allocator, '}');

    const payload_json = try control_plane.requestControlPayloadJson(
        allocator,
        client,
        &g_control_request_counter,
        "control.node_join_pending_list",
        payload.items,
    );
    defer allocator.free(payload_json);

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, payload_json, .{}) catch {
        try stdout.print("{s}\n", .{payload_json});
        return;
    };
    defer parsed.deinit();
    if (parsed.value != .object) {
        try stdout.print("{s}\n", .{payload_json});
        return;
    }
    const pending_val = parsed.value.object.get("pending") orelse {
        try stdout.print("{s}\n", .{payload_json});
        return;
    };
    if (pending_val != .array) {
        try stdout.print("{s}\n", .{payload_json});
        return;
    }

    if (pending_val.array.items.len == 0) {
        try stdout.print("(no pending join requests)\n", .{});
        return;
    }

    try stdout.print("Pending join requests:\n", .{});
    for (pending_val.array.items) |item| {
        if (item != .object) continue;
        const request = item.object;
        try stdout.print(
            "  - {s} node={s} fs={s} platform={s}/{s}/{s} requested_at_ms={d}\n",
            .{
                jsonObjectStringOr(request, "request_id", "(unknown)"),
                jsonObjectStringOr(request, "node_name", "(unknown)"),
                jsonObjectStringOr(request, "fs_url", ""),
                jsonPlatformFieldOr(request, "os", "unknown"),
                jsonPlatformFieldOr(request, "arch", "unknown"),
                jsonPlatformFieldOr(request, "runtime_kind", "unknown"),
                jsonObjectI64Or(request, "requested_at_ms", 0),
            },
        );
    }
}

fn executeNodeApprove(allocator: std.mem.Allocator, options: args.Options, cmd: args.Command) !void {
    if (cmd.args.len == 0) {
        logger.err("node approve requires <request_id>", .{});
        return error.InvalidArguments;
    }

    var lease_ttl_ms: ?u64 = null;
    var i: usize = 1;
    while (i < cmd.args.len) : (i += 1) {
        const arg = cmd.args[i];
        if (std.mem.eql(u8, arg, "--lease-ttl-ms")) {
            i += 1;
            if (i >= cmd.args.len) return error.InvalidArguments;
            lease_ttl_ms = try std.fmt.parseInt(u64, cmd.args[i], 10);
            continue;
        }
        return error.InvalidArguments;
    }

    var cfg = try loadCliConfig(allocator);
    defer cfg.deinit();

    const stdout = std.fs.File.stdout().deprecatedWriter();
    const client = try getOrCreateClient(allocator, options);
    try ensureUnifiedV2Control(allocator, client);

    var payload = std.ArrayListUnmanaged(u8){};
    defer payload.deinit(allocator);
    try payload.append(allocator, '{');
    var appended = false;

    const escaped_request = try unified.jsonEscape(allocator, cmd.args[0]);
    defer allocator.free(escaped_request);
    try payload.writer(allocator).print("\"request_id\":\"{s}\"", .{escaped_request});
    appended = true;

    if (lease_ttl_ms) |value| {
        if (appended) try payload.append(allocator, ',');
        try payload.writer(allocator).print("\"lease_ttl_ms\":{d}", .{value});
        appended = true;
    }
    if (resolveOperatorToken(options, &cfg)) |token| {
        const escaped_token = try unified.jsonEscape(allocator, token);
        defer allocator.free(escaped_token);
        if (appended) try payload.append(allocator, ',');
        try payload.writer(allocator).print("\"operator_token\":\"{s}\"", .{escaped_token});
    }
    try payload.append(allocator, '}');

    const payload_json = try control_plane.requestControlPayloadJson(
        allocator,
        client,
        &g_control_request_counter,
        "control.node_join_approve",
        payload.items,
    );
    defer allocator.free(payload_json);

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, payload_json, .{}) catch {
        try stdout.print("{s}\n", .{payload_json});
        return;
    };
    defer parsed.deinit();
    if (parsed.value != .object) {
        try stdout.print("{s}\n", .{payload_json});
        return;
    }
    const root = parsed.value.object;
    try stdout.print("Pending join approved\n", .{});
    try stdout.print("  Node ID: {s}\n", .{jsonObjectStringOr(root, "node_id", "(unknown)")});
    try stdout.print("  Node name: {s}\n", .{jsonObjectStringOr(root, "node_name", "(unknown)")});
    try stdout.print("  FS URL: {s}\n", .{jsonObjectStringOr(root, "fs_url", "")});
    try stdout.print(
        "  Platform: os={s} arch={s} runtime={s}\n",
        .{
            jsonPlatformFieldOr(root, "os", "unknown"),
            jsonPlatformFieldOr(root, "arch", "unknown"),
            jsonPlatformFieldOr(root, "runtime_kind", "unknown"),
        },
    );
    try stdout.print("  Node secret: {s}\n", .{jsonObjectStringOr(root, "node_secret", "(missing)")});
    try stdout.print("  Lease token: {s}\n", .{jsonObjectStringOr(root, "lease_token", "(missing)")});
    try stdout.print("  Lease expires: {d}\n", .{jsonObjectI64Or(root, "lease_expires_at_ms", 0)});
}

fn executeNodeDeny(allocator: std.mem.Allocator, options: args.Options, cmd: args.Command) !void {
    if (cmd.args.len != 1) {
        logger.err("node deny requires <request_id>", .{});
        return error.InvalidArguments;
    }

    var cfg = try loadCliConfig(allocator);
    defer cfg.deinit();

    const stdout = std.fs.File.stdout().deprecatedWriter();
    const client = try getOrCreateClient(allocator, options);
    try ensureUnifiedV2Control(allocator, client);

    var payload = std.ArrayListUnmanaged(u8){};
    defer payload.deinit(allocator);
    try payload.append(allocator, '{');

    const escaped_request = try unified.jsonEscape(allocator, cmd.args[0]);
    defer allocator.free(escaped_request);
    try payload.writer(allocator).print("\"request_id\":\"{s}\"", .{escaped_request});
    if (resolveOperatorToken(options, &cfg)) |token| {
        const escaped_token = try unified.jsonEscape(allocator, token);
        defer allocator.free(escaped_token);
        try payload.writer(allocator).print(",\"operator_token\":\"{s}\"", .{escaped_token});
    }
    try payload.append(allocator, '}');

    const payload_json = try control_plane.requestControlPayloadJson(
        allocator,
        client,
        &g_control_request_counter,
        "control.node_join_deny",
        payload.items,
    );
    defer allocator.free(payload_json);

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, payload_json, .{}) catch {
        try stdout.print("{s}\n", .{payload_json});
        return;
    };
    defer parsed.deinit();
    if (parsed.value != .object) {
        try stdout.print("{s}\n", .{payload_json});
        return;
    }
    const root = parsed.value.object;
    try stdout.print(
        "Pending join {s}: {s}\n",
        .{
            if (jsonObjectBoolOr(root, "denied", false)) "denied" else "processed",
            jsonObjectStringOr(root, "request_id", cmd.args[0]),
        },
    );
}

const MountNodeKind = enum {
    directory,
    file,
    unknown,
};

const MountSnapshotRootInfo = struct {
    root_node_id: u64,
    kind: MountNodeKind,
};

fn jsonObjectU64Or(obj: std.json.ObjectMap, name: []const u8, fallback: u64) u64 {
    const value = obj.get(name) orelse return fallback;
    if (value != .integer or value.integer < 0) return fallback;
    return @intCast(value.integer);
}

fn jsonObjectFirstU64(obj: std.json.ObjectMap, names: []const []const u8) ?u64 {
    for (names) |name| {
        const value = obj.get(name) orelse continue;
        if (value == .integer and value.integer >= 0) return @intCast(value.integer);
    }
    return null;
}

fn mountNodeKind(kind_label: []const u8) MountNodeKind {
    if (std.mem.indexOf(u8, kind_label, "directory") != null) return .directory;
    if (std.mem.indexOf(u8, kind_label, "file") != null) return .file;
    if (std.mem.eql(u8, kind_label, "export_root")) return .directory;
    if (std.mem.eql(u8, kind_label, "dir")) return .directory;
    if (std.mem.eql(u8, kind_label, "file")) return .file;
    return .unknown;
}

fn requestMountPayloadJson(
    allocator: std.mem.Allocator,
    client: *WebSocketClient,
    control_type: []const u8,
    payload_json: []const u8,
    timeout_ms: i64,
) ![]u8 {
    try ensureUnifiedV2Control(allocator, client);
    return control_plane.requestControlPayloadJsonWithTimeout(
        allocator,
        client,
        &g_control_request_counter,
        control_type,
        payload_json,
        timeout_ms,
    );
}

fn mountAttachPayloadJson(
    allocator: std.mem.Allocator,
    client: *WebSocketClient,
    path: []const u8,
    depth: u32,
) ![]u8 {
    const escaped_path = try unified.jsonEscape(allocator, path);
    defer allocator.free(escaped_path);
    const payload = try std.fmt.allocPrint(
        allocator,
        "{{\"path\":\"{s}\",\"depth\":{d}}}",
        .{ escaped_path, depth },
    );
    defer allocator.free(payload);
    return requestMountPayloadJson(allocator, client, "control.mount_attach", payload, fsrpc_default_timeout_ms);
}

fn mountSnapshotRootInfoFromParsed(parsed: *const std.json.Parsed(std.json.Value)) !MountSnapshotRootInfo {
    if (parsed.value != .object) return error.InvalidResponse;
    const root = parsed.value.object;
    const root_node_id = jsonObjectFirstU64(root, &.{"root_node_id"}) orelse return error.InvalidResponse;
    const nodes_value = root.get("nodes") orelse return error.InvalidResponse;
    if (nodes_value != .array) return error.InvalidResponse;
    for (nodes_value.array.items) |node_value| {
        if (node_value != .object) continue;
        const node_obj = node_value.object;
        const node_id = jsonObjectFirstU64(node_obj, &.{"id"}) orelse continue;
        if (node_id != root_node_id) continue;
        const kind_label = jsonObjectStringOr(node_obj, "kind", "");
        return .{
            .root_node_id = root_node_id,
            .kind = mountNodeKind(kind_label),
        };
    }
    return error.InvalidResponse;
}

fn mountListPathText(allocator: std.mem.Allocator, client: *WebSocketClient, path: []const u8) ![]u8 {
    const payload_json = try mountAttachPayloadJson(allocator, client, path, 1);
    defer allocator.free(payload_json);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload_json, .{});
    defer parsed.deinit();
    const info = try mountSnapshotRootInfoFromParsed(&parsed);
    if (parsed.value != .object) return error.InvalidResponse;
    const nodes_value = parsed.value.object.get("nodes") orelse return error.InvalidResponse;
    if (nodes_value != .array) return error.InvalidResponse;

    var out = std.ArrayListUnmanaged(u8){};
    defer out.deinit(allocator);
    var first = true;
    for (nodes_value.array.items) |node_value| {
        if (node_value != .object) continue;
        const node_obj = node_value.object;
        const parent_id = jsonObjectFirstU64(node_obj, &.{"parent_id"}) orelse continue;
        if (parent_id != info.root_node_id) continue;
        const name = jsonObjectStringOr(node_obj, "name", "");
        if (name.len == 0) continue;
        if (!first) try out.append(allocator, '\n');
        first = false;
        try out.appendSlice(allocator, name);
    }
    return out.toOwnedSlice(allocator);
}

fn mountStatRaw(allocator: std.mem.Allocator, client: *WebSocketClient, path: []const u8) ![]u8 {
    const payload_json = try mountAttachPayloadJson(allocator, client, path, 0);
    defer allocator.free(payload_json);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload_json, .{});
    defer parsed.deinit();
    const info = try mountSnapshotRootInfoFromParsed(&parsed);
    if (parsed.value != .object) return error.InvalidResponse;
    const nodes_value = parsed.value.object.get("nodes") orelse return error.InvalidResponse;
    if (nodes_value != .array) return error.InvalidResponse;
    for (nodes_value.array.items) |node_value| {
        if (node_value != .object) continue;
        const node_obj = node_value.object;
        const node_id = jsonObjectFirstU64(node_obj, &.{"id"}) orelse continue;
        if (node_id != info.root_node_id) continue;
        var out = std.ArrayListUnmanaged(u8){};
        defer out.deinit(allocator);
        try std.fmt.format(out.writer(allocator), "{f}", .{std.json.fmt(node_value, .{ .whitespace = .indent_2 })});
        return out.toOwnedSlice(allocator);
    }
    return error.InvalidResponse;
}

fn mountPathIsDir(allocator: std.mem.Allocator, client: *WebSocketClient, path: []const u8) !bool {
    const payload_json = try mountAttachPayloadJson(allocator, client, path, 0);
    defer allocator.free(payload_json);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload_json, .{});
    defer parsed.deinit();
    const info = try mountSnapshotRootInfoFromParsed(&parsed);
    return info.kind == .directory;
}

fn mountReadPathText(allocator: std.mem.Allocator, client: *WebSocketClient, path: []const u8) ![]u8 {
    var out = std.ArrayListUnmanaged(u8){};
    errdefer out.deinit(allocator);
    var offset: u64 = 0;
    while (true) {
        const escaped_path = try unified.jsonEscape(allocator, path);
        defer allocator.free(escaped_path);
        const payload = try std.fmt.allocPrint(
            allocator,
            "{{\"path\":\"{s}\",\"offset\":{d},\"length\":{d}}}",
            .{ escaped_path, offset, mount_read_chunk_bytes },
        );
        defer allocator.free(payload);
        const payload_json = try requestMountPayloadJson(
            allocator,
            client,
            "control.mount_file_read",
            payload,
            fsrpc_default_timeout_ms,
        );
        defer allocator.free(payload_json);

        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload_json, .{});
        defer parsed.deinit();
        if (parsed.value != .object) return error.InvalidResponse;
        const root = parsed.value.object;
        const data_b64 = jsonObjectStringOr(root, "data_b64", "");
        const eof = jsonObjectBoolOr(root, "eof", false);

        const decoded_len = std.base64.standard.Decoder.calcSizeForSlice(data_b64) catch return error.InvalidResponse;
        const decoded = try allocator.alloc(u8, decoded_len);
        defer allocator.free(decoded);
        _ = std.base64.standard.Decoder.decode(decoded, data_b64) catch return error.InvalidResponse;

        if (decoded.len != 0) {
            if (out.items.len + decoded.len > mount_read_max_total_bytes) return error.ResponseTooLarge;
            try out.appendSlice(allocator, decoded);
            offset += decoded.len;
        }
        if (eof or decoded.len == 0 or decoded.len < @as(usize, mount_read_chunk_bytes)) break;
    }
    return out.toOwnedSlice(allocator);
}

fn mountWritePathText(allocator: std.mem.Allocator, client: *WebSocketClient, path: []const u8, content: []const u8) !void {
    const escaped_path = try unified.jsonEscape(allocator, path);
    defer allocator.free(escaped_path);
    const encoded = try unified.encodeDataB64(allocator, content);
    defer allocator.free(encoded);
    const payload = try std.fmt.allocPrint(
        allocator,
        "{{\"path\":\"{s}\",\"offset\":0,\"truncate_to_size\":{d},\"data_b64\":\"{s}\"}}",
        .{ escaped_path, content.len, encoded },
    );
    defer allocator.free(payload);
    const payload_json = try requestMountPayloadJson(
        allocator,
        client,
        "control.mount_file_write",
        payload,
        fsrpc_chat_write_timeout_ms,
    );
    allocator.free(payload_json);
}

fn fsrpcReadPathText(allocator: std.mem.Allocator, client: *WebSocketClient, path: []const u8) ![]u8 {
    return mountReadPathText(allocator, client, path);
}

fn fsrpcWritePathText(allocator: std.mem.Allocator, client: *WebSocketClient, path: []const u8, content: []const u8) !void {
    return mountWritePathText(allocator, client, path, content);
}

fn executeNodeServiceGet(allocator: std.mem.Allocator, options: args.Options, cmd: args.Command) !void {
    if (cmd.args.len != 1) {
        logger.err("node service-get requires <node_id>", .{});
        return error.InvalidArguments;
    }

    const stdout = std.fs.File.stdout().deprecatedWriter();
    const client = try getOrCreateClient(allocator, options);
    try ensureUnifiedV2Control(allocator, client);

    const escaped_node = try unified.jsonEscape(allocator, cmd.args[0]);
    defer allocator.free(escaped_node);
    const payload_req = try std.fmt.allocPrint(allocator, "{{\"node_id\":\"{s}\"}}", .{escaped_node});
    defer allocator.free(payload_req);

    const payload_json = try control_plane.requestControlPayloadJson(
        allocator,
        client,
        &g_control_request_counter,
        "control.venom_get",
        payload_req,
    );
    defer allocator.free(payload_json);

    try printNodeServiceCatalogPayload(allocator, stdout, payload_json);
}

const NodeServiceRuntimeAction = enum {
    help,
    schema,
    template,
    status,
    metrics,
    health,
    config_get,
    config_set,
    invoke,
    enable,
    disable,
    restart,
    reset,
};

fn parseNodeServiceRuntimeAction(raw: []const u8) ?NodeServiceRuntimeAction {
    if (std.mem.eql(u8, raw, "help")) return .help;
    if (std.mem.eql(u8, raw, "schema")) return .schema;
    if (std.mem.eql(u8, raw, "template")) return .template;
    if (std.mem.eql(u8, raw, "status")) return .status;
    if (std.mem.eql(u8, raw, "metrics")) return .metrics;
    if (std.mem.eql(u8, raw, "health")) return .health;
    if (std.mem.eql(u8, raw, "config-get")) return .config_get;
    if (std.mem.eql(u8, raw, "config-set")) return .config_set;
    if (std.mem.eql(u8, raw, "invoke")) return .invoke;
    if (std.mem.eql(u8, raw, "enable")) return .enable;
    if (std.mem.eql(u8, raw, "disable")) return .disable;
    if (std.mem.eql(u8, raw, "restart")) return .restart;
    if (std.mem.eql(u8, raw, "reset")) return .reset;
    return null;
}

fn validateJsonObjectPayload(allocator: std.mem.Allocator, payload: []const u8, context: []const u8) !void {
    const trimmed = std.mem.trim(u8, payload, " \t\r\n");
    if (trimmed.len == 0) {
        logger.err("{s} payload must be a non-empty JSON object", .{context});
        return error.InvalidArguments;
    }
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, trimmed, .{}) catch {
        logger.err("{s} payload must be valid JSON", .{context});
        return error.InvalidArguments;
    };
    defer parsed.deinit();
    if (parsed.value != .object) {
        logger.err("{s} payload must be a JSON object", .{context});
        return error.InvalidArguments;
    }
}

const WorkspaceBindingScope = venom_bindings.WorkspaceBindingScope;

const OwnedWorkspaceBindingScope = struct {
    agent_id: ?[]u8 = null,
    workspace_id: ?[]u8 = null,

    fn deinit(self: *OwnedWorkspaceBindingScope, allocator: std.mem.Allocator) void {
        if (self.agent_id) |value| allocator.free(value);
        if (self.workspace_id) |value| allocator.free(value);
        self.* = .{};
    }

    fn asBorrowed(self: OwnedWorkspaceBindingScope) WorkspaceBindingScope {
        return .{
            .agent_id = self.agent_id,
            .workspace_id = self.workspace_id,
        };
    }
};
const ChatBindingPaths = venom_bindings.ChatBindingPaths;

const DefaultFsMount = struct {
    node_id: []u8,
    mount_path: []u8,

    fn deinit(self: *DefaultFsMount, allocator: std.mem.Allocator) void {
        allocator.free(self.node_id);
        allocator.free(self.mount_path);
        self.* = undefined;
    }
};

fn discoverChatBindingPaths(
    allocator: std.mem.Allocator,
    client: *WebSocketClient,
    scope: WorkspaceBindingScope,
) !venom_bindings.ChatBindingPaths {
    return venom_bindings.discoverChatBindingPaths(
        allocator,
        CliFsPathReader{ .allocator = allocator, .client = client },
        .{ .agent_id = scope.agent_id, .workspace_id = scope.workspace_id },
    );
}

fn resolveAttachedWorkspaceBindingScope(
    allocator: std.mem.Allocator,
    client: *WebSocketClient,
) !OwnedWorkspaceBindingScope {
    var cfg = try loadCliConfig(allocator);
    defer cfg.deinit();

    var scope = OwnedWorkspaceBindingScope{};
    errdefer scope.deinit(allocator);

    const session_key = resolveSessionKey(&cfg);
    var status = control_plane.sessionStatusWithTimeout(
        allocator,
        client,
        &g_control_request_counter,
        session_key,
        session_status_timeout_ms,
    ) catch null;
    defer if (status) |*value| value.deinit(allocator);

    if (status) |*value| {
        if (value.agent_id.len > 0) {
            scope.agent_id = try allocator.dupe(u8, value.agent_id);
        }
        if (value.workspace_id) |workspace_id| {
            if (workspace_id.len > 0) {
                scope.workspace_id = try allocator.dupe(u8, workspace_id);
            }
        }
        return scope;
    }

    if (cfg.selectedAgent()) |agent_id| {
        scope.agent_id = try allocator.dupe(u8, agent_id);
    }
    if (cfg.selectedWorkspace()) |workspace_id| {
        scope.workspace_id = try allocator.dupe(u8, workspace_id);
    }
    return scope;
}

fn buildJobLeafPath(
    allocator: std.mem.Allocator,
    jobs_root: []const u8,
    job_name: []const u8,
    leaf: []const u8,
) ![]u8 {
    const job_root = try joinFsPath(allocator, jobs_root, job_name);
    defer allocator.free(job_root);
    return joinFsPath(allocator, job_root, leaf);
}

fn readLatestThoughtText(
    allocator: std.mem.Allocator,
    client: *WebSocketClient,
    thoughts_root: []const u8,
) !?[]u8 {
    const latest_path = try joinFsPath(allocator, thoughts_root, "latest.txt");
    defer allocator.free(latest_path);
    const raw = fsrpcReadPathText(allocator, client, latest_path) catch return null;
    errdefer allocator.free(raw);
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) {
        allocator.free(raw);
        return null;
    }
    if (trimmed.ptr == raw.ptr and trimmed.len == raw.len) return raw;
    const out = try allocator.dupe(u8, trimmed);
    allocator.free(raw);
    return out;
}

fn requestNodeVenomCatalogPayload(
    allocator: std.mem.Allocator,
    client: *WebSocketClient,
    node_id: []const u8,
) ![]u8 {
    const escaped_node = try unified.jsonEscape(allocator, node_id);
    defer allocator.free(escaped_node);
    const payload_req = try std.fmt.allocPrint(allocator, "{{\"node_id\":\"{s}\"}}", .{escaped_node});
    defer allocator.free(payload_req);

    return control_plane.requestControlPayloadJson(
        allocator,
        client,
        &g_control_request_counter,
        "control.venom_get",
        payload_req,
    );
}

fn findNodeVenomRuntimeRootPath(
    allocator: std.mem.Allocator,
    catalog_payload_json: []const u8,
    expected_node_id: []const u8,
    venom_id: []const u8,
) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, catalog_payload_json, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidResponse;
    const root = parsed.value.object;

    const node_id = jsonObjectStringOr(root, "node_id", "");
    if (node_id.len == 0) return error.InvalidResponse;
    if (!std.mem.eql(u8, node_id, expected_node_id)) return error.InvalidResponse;

    const venoms_val = root.get("venoms") orelse return error.ServiceNotFound;
    if (venoms_val != .array) return error.InvalidResponse;

    for (venoms_val.array.items) |venom_val| {
        if (venom_val != .object) continue;
        const venom_obj = venom_val.object;
        if (!std.mem.eql(u8, jsonObjectStringOr(venom_obj, "venom_id", ""), venom_id)) continue;

        if (venom_obj.get("mounts")) |mounts_val| {
            if (mounts_val == .array) {
                for (mounts_val.array.items) |mount_val| {
                    if (mount_val != .object) continue;
                    const mount_path = jsonObjectStringOr(mount_val.object, "mount_path", "");
                    if (mount_path.len == 0 or mount_path[0] != '/') continue;
                    return allocator.dupe(u8, mount_path);
                }
            }
        }

        if (venom_obj.get("endpoints")) |endpoints_val| {
            if (endpoints_val == .array) {
                for (endpoints_val.array.items) |endpoint| {
                    if (endpoint != .string) continue;
                    if (endpoint.string.len == 0 or endpoint.string[0] != '/') continue;
                    return allocator.dupe(u8, endpoint.string);
                }
            }
        }

        return error.ServiceMountNotFound;
    }

    return error.ServiceNotFound;
}

fn discoverDefaultFsMount(
    allocator: std.mem.Allocator,
    client: *WebSocketClient,
    scope: WorkspaceBindingScope,
) !DefaultFsMount {
    var global_binding = venom_bindings.readPreferredVenomBinding(
        allocator,
        CliFsPathReader{ .allocator = allocator, .client = client },
        .{ .agent_id = scope.agent_id, .workspace_id = scope.workspace_id },
        "fs",
    ) catch null;
    defer if (global_binding) |*binding| binding.deinit(allocator);

    if (global_binding) |binding| {
        if (binding.endpoint_path) |mount_path| {
            return .{
                .node_id = if (binding.provider_node_id) |value|
                    try allocator.dupe(u8, value)
                else
                    try allocator.dupe(u8, "local"),
                .mount_path = try allocator.dupe(u8, mount_path),
            };
        }
    }

    var nodes = try control_plane.listNodes(allocator, client, &g_control_request_counter);
    defer workspace_types.deinitNodeList(allocator, &nodes);

    if (nodes.items.len == 0) return error.ServiceNotFound;

    var local_index: ?usize = null;
    for (nodes.items, 0..) |node, idx| {
        if (std.mem.eql(u8, node.node_id, "local") or
            std.mem.eql(u8, node.node_name, "local") or
            std.mem.eql(u8, node.node_name, "spiderweb-local"))
        {
            local_index = idx;
            break;
        }
    }

    var order = std.ArrayListUnmanaged(usize){};
    defer order.deinit(allocator);
    if (local_index) |idx| try order.append(allocator, idx);
    for (nodes.items, 0..) |_, idx| {
        if (local_index != null and idx == local_index.?) continue;
        try order.append(allocator, idx);
    }

    for (order.items) |idx| {
        const node = nodes.items[idx];
        const catalog_payload = requestNodeVenomCatalogPayload(allocator, client, node.node_id) catch continue;
        defer allocator.free(catalog_payload);
        const mount_path = findNodeVenomRuntimeRootPath(allocator, catalog_payload, node.node_id, "fs") catch continue;
        return .{
            .node_id = try allocator.dupe(u8, node.node_id),
            .mount_path = mount_path,
        };
    }

    return error.ServiceNotFound;
}

fn readNodeVenomRuntimeFile(
    allocator: std.mem.Allocator,
    client: *WebSocketClient,
    runtime_root: []const u8,
    name: []const u8,
) ![]u8 {
    const path = try joinFsPath(allocator, runtime_root, name);
    defer allocator.free(path);
    return fsrpcReadPathText(allocator, client, path);
}

fn readNodeVenomRuntimeFileFallback(
    allocator: std.mem.Allocator,
    client: *WebSocketClient,
    runtime_root: []const u8,
    primary_name: []const u8,
    fallback_name: []const u8,
) ![]u8 {
    return readNodeVenomRuntimeFile(allocator, client, runtime_root, primary_name) catch {
        return readNodeVenomRuntimeFile(allocator, client, runtime_root, fallback_name);
    };
}

fn resolveNodeVenomRuntimeInvokePayload(
    allocator: std.mem.Allocator,
    client: *WebSocketClient,
    runtime_root: []const u8,
    payload_arg: ?[]const u8,
) ![]u8 {
    if (payload_arg) |value| {
        const trimmed = std.mem.trim(u8, value, " \t\r\n");
        try validateJsonObjectPayload(allocator, trimmed, "invoke");
        return allocator.dupe(u8, trimmed);
    }

    const template_text = readNodeVenomRuntimeFileFallback(
        allocator,
        client,
        runtime_root,
        "TEMPLATE.json",
        "template.json",
    ) catch {
        return allocator.dupe(u8, "{}");
    };
    defer allocator.free(template_text);
    const trimmed = std.mem.trim(u8, template_text, " \t\r\n");
    if (trimmed.len == 0) return allocator.dupe(u8, "{}");

    validateJsonObjectPayload(allocator, trimmed, "invoke template") catch {
        logger.warn("service invoke template is not a JSON object; falling back to {{}}", .{});
        return allocator.dupe(u8, "{}");
    };
    return allocator.dupe(u8, trimmed);
}

fn writeNodeVenomRuntimeControl(
    allocator: std.mem.Allocator,
    client: *WebSocketClient,
    runtime_root: []const u8,
    name: []const u8,
    payload: []const u8,
) !void {
    const control_dir = try joinFsPath(allocator, runtime_root, "control");
    defer allocator.free(control_dir);
    const path = try joinFsPath(allocator, control_dir, name);
    defer allocator.free(path);
    try fsrpcWritePathText(allocator, client, path, payload);
}

fn executeNodeServiceRuntime(allocator: std.mem.Allocator, options: args.Options, cmd: args.Command) !void {
    if (cmd.args.len < 3) {
        logger.err("node service-runtime requires <node_id> <venom_id> <action> [payload]", .{});
        return error.InvalidArguments;
    }

    const node_id = cmd.args[0];
    const venom_id = cmd.args[1];
    const action = parseNodeServiceRuntimeAction(cmd.args[2]) orelse {
        logger.err("node service-runtime action must be help|schema|template|status|metrics|health|config-get|config-set|invoke|enable|disable|restart|reset", .{});
        return error.InvalidArguments;
    };
    const payload_arg = if (cmd.args.len > 3) cmd.args[3] else null;

    switch (action) {
        .config_set => if (payload_arg == null) {
            logger.err("node service-runtime config-set requires JSON payload", .{});
            return error.InvalidArguments;
        },
        .invoke => {},
        else => if (payload_arg != null) {
            logger.err("node service-runtime {s} does not accept payload", .{@tagName(action)});
            return error.InvalidArguments;
        },
    }
    if (cmd.args.len > 4) {
        logger.err("node service-runtime accepts at most one payload argument", .{});
        return error.InvalidArguments;
    }

    if (action == .config_set) {
        try validateJsonObjectPayload(allocator, payload_arg.?, "config-set");
    }

    const stdout = std.fs.File.stdout().deprecatedWriter();
    const client = try getOrCreateClient(allocator, options);
    try ensureUnifiedV2Control(allocator, client);

    const catalog_payload = try requestNodeVenomCatalogPayload(allocator, client, node_id);
    defer allocator.free(catalog_payload);
    const runtime_root = findNodeVenomRuntimeRootPath(
        allocator,
        catalog_payload,
        node_id,
        venom_id,
    ) catch |err| {
        if (err == error.ServiceNotFound) {
            logger.err("venom {s} not found for node {s}", .{ venom_id, node_id });
            return err;
        }
        if (err == error.ServiceMountNotFound) {
            logger.err("venom {s} does not expose a runtime mount path", .{venom_id});
            return err;
        }
        return err;
    };
    defer allocator.free(runtime_root);

    try ensureUnifiedV2Control(allocator, client);

    switch (action) {
        .help => {
            const text = try readNodeVenomRuntimeFile(allocator, client, runtime_root, "README.md");
            defer allocator.free(text);
            try stdout.print("{s}\n", .{text});
        },
        .schema => {
            const text = try readNodeVenomRuntimeFileFallback(
                allocator,
                client,
                runtime_root,
                "SCHEMA.json",
                "schema.json",
            );
            defer allocator.free(text);
            try stdout.print("{s}\n", .{text});
        },
        .template => {
            const text = try readNodeVenomRuntimeFileFallback(
                allocator,
                client,
                runtime_root,
                "TEMPLATE.json",
                "template.json",
            );
            defer allocator.free(text);
            try stdout.print("{s}\n", .{text});
        },
        .status => {
            const text = try readNodeVenomRuntimeFile(allocator, client, runtime_root, "status.json");
            defer allocator.free(text);
            try stdout.print("{s}\n", .{text});
        },
        .metrics => {
            const text = try readNodeVenomRuntimeFile(allocator, client, runtime_root, "metrics.json");
            defer allocator.free(text);
            try stdout.print("{s}\n", .{text});
        },
        .health => {
            const text = try readNodeVenomRuntimeFile(allocator, client, runtime_root, "health.json");
            defer allocator.free(text);
            try stdout.print("{s}\n", .{text});
        },
        .config_get => {
            const text = try readNodeVenomRuntimeFile(allocator, client, runtime_root, "config.json");
            defer allocator.free(text);
            try stdout.print("{s}\n", .{text});
        },
        .config_set => {
            const path = try joinFsPath(allocator, runtime_root, "config.json");
            defer allocator.free(path);
            try fsrpcWritePathText(allocator, client, path, std.mem.trim(u8, payload_arg.?, " \t\r\n"));
            const health = try readNodeVenomRuntimeFile(allocator, client, runtime_root, "health.json");
            defer allocator.free(health);
            try stdout.print("updated config for {s}/{s}\n{s}\n", .{ node_id, venom_id, health });
        },
        .invoke => {
            const invoke_payload = try resolveNodeVenomRuntimeInvokePayload(
                allocator,
                client,
                runtime_root,
                payload_arg,
            );
            defer allocator.free(invoke_payload);
            try writeNodeVenomRuntimeControl(allocator, client, runtime_root, "invoke.json", invoke_payload);
            const status = try readNodeVenomRuntimeFile(allocator, client, runtime_root, "status.json");
            defer allocator.free(status);
            const result = try readNodeVenomRuntimeFile(allocator, client, runtime_root, "result.json");
            defer allocator.free(result);
            const last_error = try readNodeVenomRuntimeFile(allocator, client, runtime_root, "last_error.txt");
            defer allocator.free(last_error);
            try stdout.print("status:\n{s}\n", .{status});
            if (std.mem.trim(u8, last_error, " \t\r\n").len > 0) {
                try stdout.print("last_error:\n{s}\n", .{last_error});
            }
            try stdout.print("result:\n{s}\n", .{result});
        },
        .enable, .disable, .restart, .reset => {
            const control_name = switch (action) {
                .enable => "enable",
                .disable => "disable",
                .restart => "restart",
                .reset => "reset",
                else => unreachable,
            };
            try writeNodeVenomRuntimeControl(allocator, client, runtime_root, control_name, "{}");
            const health = try readNodeVenomRuntimeFile(allocator, client, runtime_root, "health.json");
            defer allocator.free(health);
            const status = try readNodeVenomRuntimeFile(allocator, client, runtime_root, "status.json");
            defer allocator.free(status);
            try stdout.print("{s} applied for {s}/{s}\n", .{ control_name, node_id, venom_id });
            try stdout.print("health:\n{s}\n", .{health});
            try stdout.print("status:\n{s}\n", .{status});
        },
    }
}

fn executeNodeServiceUpsert(allocator: std.mem.Allocator, options: args.Options, cmd: args.Command) !void {
    if (cmd.args.len < 2) {
        logger.err("node service-upsert requires <node_id> <node_secret>", .{});
        return error.InvalidArguments;
    }

    const node_id = cmd.args[0];
    const node_secret = cmd.args[1];
    var platform_os: ?[]const u8 = null;
    var platform_arch: ?[]const u8 = null;
    var platform_runtime_kind: ?[]const u8 = null;
    var labels = std.ArrayListUnmanaged(NodeLabelArg){};
    defer labels.deinit(allocator);
    var venoms_json: ?[]const u8 = null;
    var venoms_file_raw: ?[]u8 = null;
    defer if (venoms_file_raw) |raw| allocator.free(raw);

    var i: usize = 2;
    while (i < cmd.args.len) : (i += 1) {
        const arg = cmd.args[i];
        if (std.mem.eql(u8, arg, "--os")) {
            i += 1;
            if (i >= cmd.args.len) return error.InvalidArguments;
            platform_os = cmd.args[i];
            continue;
        }
        if (std.mem.eql(u8, arg, "--arch")) {
            i += 1;
            if (i >= cmd.args.len) return error.InvalidArguments;
            platform_arch = cmd.args[i];
            continue;
        }
        if (std.mem.eql(u8, arg, "--runtime-kind")) {
            i += 1;
            if (i >= cmd.args.len) return error.InvalidArguments;
            platform_runtime_kind = cmd.args[i];
            continue;
        }
        if (std.mem.eql(u8, arg, "--label")) {
            i += 1;
            if (i >= cmd.args.len) return error.InvalidArguments;
            try labels.append(allocator, try parseNodeLabelArg(cmd.args[i]));
            continue;
        }
        if (std.mem.eql(u8, arg, "--services-json") or std.mem.eql(u8, arg, "--venoms-json")) {
            i += 1;
            if (i >= cmd.args.len or venoms_json != null or venoms_file_raw != null) return error.InvalidArguments;
            venoms_json = std.mem.trim(u8, cmd.args[i], " \t\r\n");
            continue;
        }
        if (std.mem.eql(u8, arg, "--services-file") or std.mem.eql(u8, arg, "--venoms-file")) {
            i += 1;
            if (i >= cmd.args.len or venoms_json != null or venoms_file_raw != null) return error.InvalidArguments;
            venoms_file_raw = try std.fs.cwd().readFileAlloc(allocator, cmd.args[i], 2 * 1024 * 1024);
            venoms_json = std.mem.trim(u8, venoms_file_raw.?, " \t\r\n");
            continue;
        }
        return error.InvalidArguments;
    }

    if (venoms_json) |raw| {
        if (raw.len == 0) return error.InvalidArguments;
        var parsed_venoms = try std.json.parseFromSlice(std.json.Value, allocator, raw, .{});
        defer parsed_venoms.deinit();
        if (parsed_venoms.value != .array) {
            logger.err("venoms payload must be a JSON array", .{});
            return error.InvalidArguments;
        }
    }

    const stdout = std.fs.File.stdout().deprecatedWriter();
    const client = try getOrCreateClient(allocator, options);
    try ensureUnifiedV2Control(allocator, client);

    var payload = std.ArrayListUnmanaged(u8){};
    defer payload.deinit(allocator);
    try payload.append(allocator, '{');

    const escaped_node_id = try unified.jsonEscape(allocator, node_id);
    defer allocator.free(escaped_node_id);
    const escaped_node_secret = try unified.jsonEscape(allocator, node_secret);
    defer allocator.free(escaped_node_secret);
    try payload.writer(allocator).print(
        "\"node_id\":\"{s}\",\"node_secret\":\"{s}\"",
        .{ escaped_node_id, escaped_node_secret },
    );

    if (platform_os != null or platform_arch != null or platform_runtime_kind != null) {
        try payload.appendSlice(allocator, ",\"platform\":{");
        var platform_fields: usize = 0;
        if (platform_os) |value| {
            const escaped = try unified.jsonEscape(allocator, value);
            defer allocator.free(escaped);
            try payload.writer(allocator).print("\"os\":\"{s}\"", .{escaped});
            platform_fields += 1;
        }
        if (platform_arch) |value| {
            const escaped = try unified.jsonEscape(allocator, value);
            defer allocator.free(escaped);
            if (platform_fields > 0) try payload.append(allocator, ',');
            try payload.writer(allocator).print("\"arch\":\"{s}\"", .{escaped});
            platform_fields += 1;
        }
        if (platform_runtime_kind) |value| {
            const escaped = try unified.jsonEscape(allocator, value);
            defer allocator.free(escaped);
            if (platform_fields > 0) try payload.append(allocator, ',');
            try payload.writer(allocator).print("\"runtime_kind\":\"{s}\"", .{escaped});
        }
        try payload.append(allocator, '}');
    }

    if (labels.items.len > 0) {
        try payload.appendSlice(allocator, ",\"labels\":{");
        for (labels.items, 0..) |label, idx| {
            if (idx != 0) try payload.append(allocator, ',');
            const escaped_key = try unified.jsonEscape(allocator, label.key);
            defer allocator.free(escaped_key);
            const escaped_value = try unified.jsonEscape(allocator, label.value);
            defer allocator.free(escaped_value);
            try payload.writer(allocator).print("\"{s}\":\"{s}\"", .{ escaped_key, escaped_value });
        }
        try payload.append(allocator, '}');
    }

    if (venoms_json) |raw| {
        try payload.writer(allocator).print(",\"venoms\":{s}", .{raw});
    }

    try payload.append(allocator, '}');

    const payload_json = try control_plane.requestControlPayloadJson(
        allocator,
        client,
        &g_control_request_counter,
        "control.venom_upsert",
        payload.items,
    );
    defer allocator.free(payload_json);

    try printNodeServiceCatalogPayload(allocator, stdout, payload_json);
}

fn executeWorkspaceStatus(allocator: std.mem.Allocator, options: args.Options, cmd: args.Command) !void {
    const stdout = std.fs.File.stdout().deprecatedWriter();
    const client = try getOrCreateClient(allocator, options);
    try ensureUnifiedV2Control(allocator, client);

    var cfg = try loadCliConfig(allocator);
    defer cfg.deinit();
    const project_id = if (cmd.args.len > 0)
        cmd.args[0]
    else
        resolveWorkspaceSelection(options, &cfg);

    var status = try control_plane.workspaceStatus(
        allocator,
        client,
        &g_control_request_counter,
        project_id,
        if (project_id) |id|
            if (options.workspace_token) |token|
                token
            else
                cfg.getWorkspaceToken(id)
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
            status.workspace_id,
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

fn setLocalRoleToken(cfg: *Config, role: Config.TokenRole, token: []const u8) !void {
    try cfg.setRoleToken(role, token);
    try cfg.setActiveRole(role);
}

fn maskTokenForDisplay(allocator: std.mem.Allocator, token: []const u8) ![]u8 {
    if (token.len == 0) return allocator.dupe(u8, "(empty)");
    if (token.len <= 8) return allocator.dupe(u8, "****");
    return std.fmt.allocPrint(
        allocator,
        "{s}...{s}",
        .{ token[0..4], token[token.len - 4 ..] },
    );
}

fn executeAuthStatus(allocator: std.mem.Allocator, options: args.Options, cmd: args.Command) !void {
    var reveal_tokens = false;
    for (cmd.args) |arg| {
        if (std.mem.eql(u8, arg, "--reveal")) {
            reveal_tokens = true;
            continue;
        }
        logger.err("auth status only accepts --reveal", .{});
        return error.InvalidArguments;
    }
    const stdout = std.fs.File.stdout().deprecatedWriter();
    const client = try getOrCreateClient(allocator, options);
    try ensureUnifiedV2Control(allocator, client);

    const payload_json = try control_plane.requestControlPayloadJson(
        allocator,
        client,
        &g_control_request_counter,
        "control.auth_status",
        null,
    );
    defer allocator.free(payload_json);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload_json, .{});
    defer parsed.deinit();
    if (parsed.value != .object) {
        try stdout.print("{s}\n", .{payload_json});
        return;
    }

    const admin_token = if (parsed.value.object.get("admin_token")) |value|
        if (value == .string) value.string else "(invalid)"
    else
        "(missing)";
    const user_token = if (parsed.value.object.get("user_token")) |value|
        if (value == .string) value.string else "(invalid)"
    else
        "(missing)";
    const path = if (parsed.value.object.get("path")) |value| switch (value) {
        .string => value.string,
        .null => "(none)",
        else => "(invalid)",
    } else "(missing)";

    const mask_admin = !reveal_tokens and admin_token.len > 0 and admin_token[0] != '(';
    const mask_user = !reveal_tokens and user_token.len > 0 and user_token[0] != '(';
    const display_admin_owned = if (mask_admin)
        try maskTokenForDisplay(allocator, admin_token)
    else
        null;
    defer if (display_admin_owned) |value| allocator.free(value);
    const display_user_owned = if (mask_user)
        try maskTokenForDisplay(allocator, user_token)
    else
        null;
    defer if (display_user_owned) |value| allocator.free(value);
    const display_admin = if (display_admin_owned) |value| value else admin_token;
    const display_user = if (display_user_owned) |value| value else user_token;

    try stdout.print("Auth status\n", .{});
    try stdout.print("  admin_token: {s}\n", .{display_admin});
    try stdout.print("  user_token:  {s}\n", .{display_user});
    try stdout.print("  path:        {s}\n", .{path});
    if (!reveal_tokens) {
        try stdout.print("  note: tokens are masked; run `auth status --reveal` to show full values\n", .{});
    }
}

fn executeAuthRotate(allocator: std.mem.Allocator, options: args.Options, cmd: args.Command) !void {
    if (cmd.args.len == 0) {
        logger.err("auth rotate requires a role: admin|user", .{});
        return error.InvalidArguments;
    }
    const role = cmd.args[0];
    var reveal_token = false;
    for (cmd.args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--reveal")) {
            reveal_token = true;
            continue;
        }
        logger.err("auth rotate only accepts role plus optional --reveal", .{});
        return error.InvalidArguments;
    }
    if (!std.mem.eql(u8, role, "admin") and !std.mem.eql(u8, role, "user")) {
        logger.err("auth rotate role must be admin or user", .{});
        return error.InvalidArguments;
    }

    const stdout = std.fs.File.stdout().deprecatedWriter();
    const client = try getOrCreateClient(allocator, options);
    try ensureUnifiedV2Control(allocator, client);

    const escaped_role = try unified.jsonEscape(allocator, role);
    defer allocator.free(escaped_role);
    const request_payload = try std.fmt.allocPrint(allocator, "{{\"role\":\"{s}\"}}", .{escaped_role});
    defer allocator.free(request_payload);

    const payload_json = try control_plane.requestControlPayloadJson(
        allocator,
        client,
        &g_control_request_counter,
        "control.auth_rotate",
        request_payload,
    );
    defer allocator.free(payload_json);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload_json, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidResponse;
    const out_role = parsed.value.object.get("role") orelse return error.InvalidResponse;
    if (out_role != .string) return error.InvalidResponse;
    const token = parsed.value.object.get("token") orelse return error.InvalidResponse;
    if (token != .string) return error.InvalidResponse;
    const token_display_owned = if (reveal_token)
        null
    else
        try maskTokenForDisplay(allocator, token.string);
    defer if (token_display_owned) |value| allocator.free(value);
    const token_display = if (token_display_owned) |value| value else token.string;

    try stdout.print("Rotated auth token\n", .{});
    try stdout.print("  role:  {s}\n", .{out_role.string});
    try stdout.print("  token: {s}\n", .{token_display});
    if (!reveal_token) {
        try stdout.print("  note: token is masked; rerun with `--reveal` to print full value\n", .{});
    }

    var cfg = try loadCliConfig(allocator);
    defer cfg.deinit();
    const token_role: Config.TokenRole = if (std.mem.eql(u8, out_role.string, "admin")) .admin else .user;
    try setLocalRoleToken(&cfg, token_role, token.string);
    try cfg.save();
    try stdout.print("  saved: local {s} token updated\n", .{if (token_role == .admin) "admin" else "user"});
}

fn executeChatSend(allocator: std.mem.Allocator, options: args.Options, cmd: args.Command) !void {
    var progress = try parseChatProgressOptions(allocator, cmd.args);
    defer progress.deinit(allocator);

    if (progress.args.len == 0) {
        logger.err("chat send requires a message", .{});
        return error.InvalidArguments;
    }

    const stdout = std.fs.File.stdout().deprecatedWriter();
    const message = try std.mem.join(allocator, " ", progress.args);
    defer allocator.free(message);

    const client = try getOrCreateClient(allocator, options);
    try maybeApplyWorkspaceContext(allocator, options, client);
    logger.info("Negotiating FS-RPC session...", .{});
    try fsrpcBootstrap(allocator, client);
    var binding_scope = try resolveAttachedWorkspaceBindingScope(allocator, client);
    defer binding_scope.deinit(allocator);
    var chat_paths = try discoverChatBindingPaths(allocator, client, binding_scope.asBorrowed());
    defer chat_paths.deinit(allocator);

    logger.info("Submitting chat job...", .{});
    const chat_input_fid = try fsrpcWalkPath(allocator, client, chat_paths.input_path);
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

    const result_path = try buildJobLeafPath(allocator, chat_paths.jobs_root, job_name, chat_paths.result_leaf);
    defer allocator.free(result_path);

    const result_fid = try fsrpcWalkPath(allocator, client, result_path);
    defer fsrpcClunkBestEffort(allocator, client, result_fid);
    try fsrpcOpen(allocator, client, result_fid, "r");

    try stdout.print("Sent: \"{s}\"\n", .{message});
    try stdout.print("Chat job queued: {s}\n", .{job_name});
    if (write.correlation_id) |value| {
        try stdout.print("Correlation ID: {s}\n", .{value});
    }

    logger.info("Waiting for chat result...", .{});
    var status = try waitForChatJobCompletion(
        allocator,
        client,
        stdout,
        &chat_paths,
        job_name,
        progress.show_thoughts,
        progress.quiet_progress,
    );
    defer status.deinit(allocator);

    const content = try fsrpcReadAllText(allocator, client, result_fid);
    defer allocator.free(content);

    if (std.mem.eql(u8, status.state, "failed")) {
        if (status.error_text) |value| {
            try stdout.print("AI failed: {s}\n", .{value});
        } else if (content.len > 0) {
            try stdout.print("AI failed: {s}\n", .{content});
        } else {
            try stdout.print("AI failed\n", .{});
        }
        return;
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

fn readJobStatus(
    allocator: std.mem.Allocator,
    client: *WebSocketClient,
    jobs_root: []const u8,
    status_leaf: []const u8,
    job_name: []const u8,
) !JobStatusInfo {
    const status_path = try buildJobLeafPath(allocator, jobs_root, job_name, status_leaf);
    defer allocator.free(status_path);
    const status_fid = try fsrpcWalkPath(allocator, client, status_path);
    defer fsrpcClunkBestEffort(allocator, client, status_fid);
    try fsrpcOpen(allocator, client, status_fid, "r");
    const status_json = try fsrpcReadAllText(allocator, client, status_fid);
    defer allocator.free(status_json);
    return parseJobStatusInfo(allocator, status_json);
}

fn waitForChatJobCompletion(
    allocator: std.mem.Allocator,
    client: *WebSocketClient,
    stdout: anytype,
    chat_paths: *const ChatBindingPaths,
    job_name: []const u8,
    show_thoughts: bool,
    quiet_progress: bool,
) !JobStatusInfo {
    var last_state: ?[]u8 = null;
    defer if (last_state) |value| allocator.free(value);
    var last_thought: ?[]u8 = null;
    defer if (last_thought) |value| allocator.free(value);

    while (true) {
        var status = try readJobStatus(allocator, client, chat_paths.jobs_root, chat_paths.status_leaf, job_name);
        errdefer status.deinit(allocator);

        if (!quiet_progress and (last_state == null or !std.mem.eql(u8, last_state.?, status.state))) {
            try stdout.print("State: {s}\n", .{status.state});
            if (last_state) |value| allocator.free(value);
            last_state = try allocator.dupe(u8, status.state);
        } else if (last_state == null or !std.mem.eql(u8, last_state.?, status.state)) {
            if (last_state) |value| allocator.free(value);
            last_state = try allocator.dupe(u8, status.state);
        }

        if (show_thoughts) if (try readLatestThoughtText(allocator, client, chat_paths.thoughts_root)) |thought| {
            defer allocator.free(thought);
            if (last_thought == null or !std.mem.eql(u8, last_thought.?, thought)) {
                if (!quiet_progress) try printThoughtProgress(stdout, thought);
                if (last_thought) |value| allocator.free(value);
                last_thought = try allocator.dupe(u8, thought);
            }
        };

        if (std.mem.eql(u8, status.state, "done") or std.mem.eql(u8, status.state, "failed")) {
            return status;
        }

        status.deinit(allocator);
        std.Thread.sleep(chat_job_poll_interval_ms * std.time.ns_per_ms);
    }
}

fn executeChatResume(allocator: std.mem.Allocator, options: args.Options, cmd: args.Command) !void {
    var progress = try parseChatProgressOptions(allocator, cmd.args);
    defer progress.deinit(allocator);

    const stdout = std.fs.File.stdout().deprecatedWriter();
    const client = try getOrCreateClient(allocator, options);
    try maybeApplyWorkspaceContext(allocator, options, client);
    try fsrpcBootstrap(allocator, client);
    var binding_scope = try resolveAttachedWorkspaceBindingScope(allocator, client);
    defer binding_scope.deinit(allocator);
    var chat_paths = try discoverChatBindingPaths(allocator, client, binding_scope.asBorrowed());
    defer chat_paths.deinit(allocator);

    if (progress.args.len == 0) {
        const jobs_fid = try fsrpcWalkPath(allocator, client, chat_paths.jobs_root);
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
            var status = readJobStatus(allocator, client, chat_paths.jobs_root, chat_paths.status_leaf, job) catch |err| {
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

    const job_name = progress.args[0];
    var status = try waitForChatJobCompletion(
        allocator,
        client,
        stdout,
        &chat_paths,
        job_name,
        progress.show_thoughts,
        progress.quiet_progress,
    );
    defer status.deinit(allocator);
    if (status.correlation_id) |value| {
        try stdout.print("Correlation ID: {s}\n", .{value});
    }

    const result_path = try buildJobLeafPath(allocator, chat_paths.jobs_root, job_name, chat_paths.result_leaf);
    defer allocator.free(result_path);
    const result_fid = try fsrpcWalkPath(allocator, client, result_path);
    defer fsrpcClunkBestEffort(allocator, client, result_fid);
    try fsrpcOpen(allocator, client, result_fid, "r");
    const content = try fsrpcReadAllText(allocator, client, result_fid);
    defer allocator.free(content);

    if (std.mem.eql(u8, status.state, "failed")) {
        if (status.error_text) |value| {
            try stdout.print("AI failed: {s}\n", .{value});
        } else if (content.len > 0) {
            try stdout.print("AI failed: {s}\n", .{content});
        } else {
            try stdout.print("AI failed\n", .{});
        }
        return;
    }
    if (content.len == 0) {
        try stdout.print("AI: (no content)\n", .{});
    } else {
        try stdout.print("AI: {s}\n", .{content});
    }
}

fn executeFsLs(allocator: std.mem.Allocator, options: args.Options, cmd: args.Command) !void {
    const stdout = std.fs.File.stdout().deprecatedWriter();
    const client = try getOrCreateClient(allocator, options);
    try maybeApplyWorkspaceContext(allocator, options, client);
    const path = if (cmd.args.len > 0) cmd.args[0] else "/";
    const content = try mountListPathText(allocator, client, path);
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
    const client = try getOrCreateClient(allocator, options);
    try maybeApplyWorkspaceContext(allocator, options, client);
    const content = try mountReadPathText(allocator, client, cmd.args[0]);
    defer allocator.free(content);
    try stdout.print("{s}\n", .{content});
}

fn executeFsWrite(allocator: std.mem.Allocator, options: args.Options, cmd: args.Command) !void {
    if (cmd.args.len < 2) {
        logger.err("fs write requires a path and content", .{});
        return error.InvalidArguments;
    }

    const stdout = std.fs.File.stdout().deprecatedWriter();
    const client = try getOrCreateClient(allocator, options);
    try maybeApplyWorkspaceContext(allocator, options, client);
    const content = try std.mem.join(allocator, " ", cmd.args[1..]);
    defer allocator.free(content);

    try mountWritePathText(allocator, client, cmd.args[0], content);
    try stdout.print("wrote {d} byte(s)\n", .{content.len});
}

fn executeFsStat(allocator: std.mem.Allocator, options: args.Options, cmd: args.Command) !void {
    if (cmd.args.len == 0) {
        logger.err("fs stat requires a path", .{});
        return error.InvalidArguments;
    }

    const stdout = std.fs.File.stdout().deprecatedWriter();
    const client = try getOrCreateClient(allocator, options);
    try maybeApplyWorkspaceContext(allocator, options, client);
    const stat_json = try mountStatRaw(allocator, client, cmd.args[0]);
    defer allocator.free(stat_json);
    try stdout.print("{s}\n", .{stat_json});
}

fn executeFsTree(allocator: std.mem.Allocator, options: args.Options, cmd: args.Command) !void {
    const stdout = std.fs.File.stdout().deprecatedWriter();
    const client = try getOrCreateClient(allocator, options);
    try maybeApplyWorkspaceContext(allocator, options, client);
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
    const is_dir = try mountPathIsDir(allocator, client, path);

    const print_entry = if (is_dir) !opts.files_only else !opts.dirs_only;
    if (print_entry) {
        var indent_idx: usize = 0;
        while (indent_idx < depth) : (indent_idx += 1) {
            try stdout.print("  ", .{});
        }
        try stdout.print("{s}\n", .{display_name});
    }

    if (!is_dir or depth >= opts.max_depth) return;
    const listing = try mountListPathText(allocator, client, path);
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
        "{{\"channel\":\"acheron\",\"type\":\"acheron.t_version\",\"tag\":{d},\"msize\":1048576,\"version\":\"acheron-1\"}}",
        .{version_tag},
    );
    defer allocator.free(version_req);
    var version = try sendAndAwaitFsrpcWithTimeout(allocator, client, version_req, version_tag, fsrpc_default_timeout_ms);
    defer version.deinit(allocator);
    try ensureFsrpcOk(&version);

    const attach_tag = nextFsrpcTag();
    const attach_req = try std.fmt.allocPrint(
        allocator,
        "{{\"channel\":\"acheron\",\"type\":\"acheron.t_attach\",\"tag\":{d},\"fid\":1}}",
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
        "{{\"channel\":\"acheron\",\"type\":\"acheron.t_walk\",\"tag\":{d},\"fid\":1,\"newfid\":{d},\"path\":{s}}}",
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
        "{{\"channel\":\"acheron\",\"type\":\"acheron.t_open\",\"tag\":{d},\"fid\":{d},\"mode\":\"{s}\"}}",
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
        "{{\"channel\":\"acheron\",\"type\":\"acheron.t_read\",\"tag\":{d},\"fid\":{d},\"offset\":0,\"count\":1048576}}",
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
            "{{\"channel\":\"acheron\",\"type\":\"acheron.t_write\",\"tag\":{d},\"fid\":{d},\"offset\":0,\"data_b64\":\"{s}\",\"correlation_id\":\"{s}\"}}",
            .{ tag, fid, encoded, escaped },
        );
    } else try std.fmt.allocPrint(
        allocator,
        "{{\"channel\":\"acheron\",\"type\":\"acheron.t_write\",\"tag\":{d},\"fid\":{d},\"offset\":0,\"data_b64\":\"{s}\"}}",
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
        "{{\"channel\":\"acheron\",\"type\":\"acheron.t_stat\",\"tag\":{d},\"fid\":{d}}}",
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
        "{{\"channel\":\"acheron\",\"type\":\"acheron.t_clunk\",\"tag\":{d},\"fid\":{d}}}",
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
                    if (channel == .string and std.mem.eql(u8, channel.string, "acheron")) {
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
