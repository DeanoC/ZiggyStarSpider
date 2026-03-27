// Client context: global connection state and shared helpers for the CLI.
// All command modules import this as:
//   const ctx = @import("client_context.zig");
// and access globals as ctx.g_client, ctx.g_control_request_counter, etc.

const std = @import("std");
const builtin = @import("builtin");
const args = @import("args.zig");
const logger = @import("ziggy-core").utils.logger;
const WebSocketClient = @import("../client/websocket.zig").WebSocketClient;
const Config = @import("../client/config.zig").Config;
const control_plane = @import("control_plane");
const app_venom_host = if (builtin.os.tag == .windows)
    @import("../client/app_venom_host_windows_stub.zig")
else
    @import("../client/app_venom_host.zig");
const workspace_types = control_plane.workspace_types;

// ── Global connection state ──────────────────────────────────────────────────

pub var g_client: ?WebSocketClient = null;
pub var g_connected: bool = false;
pub var g_control_ready: bool = false;
pub var g_client_allocator: ?std.mem.Allocator = null;
pub var g_client_url_owned: ?[]u8 = null;
pub var g_client_token_owned: ?[]u8 = null;
pub var g_control_request_counter: u64 = 0;
pub var g_app_local_node_bootstrap_done: bool = false;
pub var g_app_local_venom_host: ?app_venom_host.AppVenomHost = null;

// ── Shared constants ─────────────────────────────────────────────────────────

pub const chat_job_poll_interval_ms: u64 = 500;
pub const session_status_timeout_ms: i64 = 5_000;
pub const session_warming_wait_timeout_ms: i64 = 30_000;
pub const session_warming_poll_interval_ms: u64 = 250;
pub const app_local_node_lease_ttl_ms: u64 = 15 * 60 * 1000;
pub const system_workspace_id = "system";
pub const system_agent_id = "spiderweb";

// ── Terminal helpers ─────────────────────────────────────────────────────────

pub fn stdoutSupportsAnsi() bool {
    return std.fs.File.stdout().isTty();
}

// ── Connection management ────────────────────────────────────────────────────

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

pub fn getOrCreateClient(allocator: std.mem.Allocator, options: args.Options) !*WebSocketClient {
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

pub fn cleanupGlobalClient() void {
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

pub fn ensureUnifiedV2Control(allocator: std.mem.Allocator, client: *WebSocketClient) !void {
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

// ── Config utilities ─────────────────────────────────────────────────────────

pub fn loadCliConfig(allocator: std.mem.Allocator) !Config {
    return Config.load(allocator) catch try Config.init(allocator);
}

pub fn resolveWorkspaceSelection(options: args.Options, cfg: *const Config) ?[]const u8 {
    if (options.workspace) |project_id| return project_id;
    return cfg.selectedWorkspace();
}

pub fn effectiveRole(options: args.Options, cfg: *const Config) Config.TokenRole {
    if (options.role) |role| {
        return if (role == .admin) .admin else .user;
    }
    return cfg.active_role;
}

pub fn resolveSessionKey(cfg: *const Config) []const u8 {
    if (cfg.default_session) |session_key| {
        if (session_key.len > 0) return session_key;
    }
    return "main";
}

pub fn nextCorrelationId(allocator: std.mem.Allocator, prefix: []const u8) ![]u8 {
    g_control_request_counter +%= 1;
    return std.fmt.allocPrint(allocator, "{s}-{d}", .{ prefix, g_control_request_counter });
}

// ── Identity helpers ─────────────────────────────────────────────────────────

pub fn isUserScopedAgentId(agent_id: []const u8) bool {
    return std.mem.eql(u8, agent_id, "user") or std.mem.eql(u8, agent_id, "user-isolated");
}

pub fn isSystemWorkspaceId(workspace_id: []const u8) bool {
    return std.mem.eql(u8, workspace_id, system_workspace_id);
}

pub fn isSystemAgentId(agent_id: []const u8) bool {
    return std.mem.eql(u8, agent_id, system_agent_id);
}

// ── Agent/session resolution ─────────────────────────────────────────────────

pub fn fetchDefaultAgentFromSessionList(
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

pub fn fetchFirstNonSystemAgent(
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

pub fn resolveAttachAgentForWorkspace(
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

pub fn sessionStatusMatchesTarget(
    status: *const workspace_types.SessionAttachStatus,
    agent_id: []const u8,
    project_id: []const u8,
) bool {
    if (!std.mem.eql(u8, status.agent_id, agent_id)) return false;
    const attached_project_id = status.workspace_id orelse return false;
    return std.mem.eql(u8, attached_project_id, project_id);
}

pub fn waitForSessionReady(
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

// ── Workspace context application ────────────────────────────────────────────

pub fn printWorkspaceStatus(stdout: anytype, status: *const workspace_types.WorkspaceStatus, verbose: bool) !void {
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

pub fn maybeApplyWorkspaceContext(
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
                did_attach = true;
            } else if (!std.mem.eql(u8, status.state, "ready")) {
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
    }

    if (std.mem.eql(u8, attach_state, "warming")) {
        try waitForSessionReady(allocator, client, session_key, active_agent, project_id);
    } else if (!std.mem.eql(u8, attach_state, "ready")) {
        logger.err("session attach ended in unexpected state: {s}", .{attach_state});
        return error.SessionNotReady;
    }
}
