// Session commands: session list, history, status, attach, resume, close, restore

const std = @import("std");
const args = @import("../args.zig");
const logger = @import("ziggy-core").utils.logger;
const control_plane = @import("control_plane");
const workspace_types = control_plane.workspace_types;
const ctx = @import("../client_context.zig");
const output = @import("../output.zig");

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

pub fn executeSessionList(allocator: std.mem.Allocator, options: args.Options, cmd: args.Command) !void {
    _ = cmd;
    const stdout = std.fs.File.stdout().deprecatedWriter();
    const client = try ctx.getOrCreateClient(allocator, options);
    try ctx.ensureUnifiedV2Control(allocator, client);

    var list = try control_plane.listSessions(allocator, client, &ctx.g_control_request_counter);
    defer list.deinit(allocator);

    if (options.json) {
        try stdout.print("{{\"active_session\":\"{s}\",\"sessions\":[\n", .{list.active_session});
        for (list.sessions.items, 0..) |session, idx| {
            const ws = session.workspace_id orelse "";
            try stdout.print(
                "  {{\"session_key\":\"{s}\",\"agent_id\":\"{s}\",\"workspace_id\":\"{s}\",\"is_active\":{s}}}",
                .{
                    session.session_key,
                    session.agent_id,
                    ws,
                    if (std.mem.eql(u8, session.session_key, list.active_session)) "true" else "false",
                },
            );
            if (idx + 1 < list.sessions.items.len) try stdout.writeByte(',');
            try stdout.writeByte('\n');
        }
        try stdout.writeAll("]}\n");
        return;
    }

    const ansi = ctx.stdoutSupportsAnsi();
    try stdout.print("Active session: {s}\n", .{list.active_session});
    if (list.sessions.items.len == 0) {
        try stdout.print("(no sessions)\n", .{});
        return;
    }

    var tbl = try output.Table.init(allocator, &.{ "", "Session Key", "Agent", "Workspace" });
    defer tbl.deinit();
    for (list.sessions.items) |session| {
        const marker = if (std.mem.eql(u8, session.session_key, list.active_session)) "*" else "";
        try tbl.row(&.{
            marker,
            session.session_key,
            session.agent_id,
            session.workspace_id orelse "(none)",
        });
    }
    try tbl.print(stdout, ansi);
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

pub fn executeSessionHistory(allocator: std.mem.Allocator, options: args.Options, cmd: args.Command) !void {
    const parsed = parseSessionHistoryArgs(cmd) catch {
        logger.err("session history usage: session history [agent_id] [--limit <n>]", .{});
        return error.InvalidArguments;
    };

    const stdout = std.fs.File.stdout().deprecatedWriter();
    const client = try ctx.getOrCreateClient(allocator, options);
    try ctx.ensureUnifiedV2Control(allocator, client);

    var sessions = try control_plane.sessionHistory(
        allocator,
        client,
        &ctx.g_control_request_counter,
        parsed.agent_id,
        parsed.limit,
    );
    defer sessions.deinit(allocator);

    if (sessions.items.len == 0) {
        try stdout.print("(no session history)\n", .{});
        return;
    }

    const limit = @min(parsed.limit, sessions.items.len);
    try stdout.print("Session history (last {d}):\n", .{limit});
    for (sessions.items[0..limit]) |session| {
        if (session.workspace_id) |project_id| {
            try stdout.print(
                "  {s}  agent={s}  workspace={s}\n",
                .{ session.session_key, session.agent_id, project_id },
            );
        } else {
            try stdout.print(
                "  {s}  agent={s}  workspace=(none)\n",
                .{ session.session_key, session.agent_id },
            );
        }
    }
}

pub fn executeSessionStatus(allocator: std.mem.Allocator, options: args.Options, cmd: args.Command) !void {
    if (cmd.args.len > 1) {
        logger.err("session status accepts zero or one session_key", .{});
        return error.InvalidArguments;
    }

    const stdout = std.fs.File.stdout().deprecatedWriter();
    const client = try ctx.getOrCreateClient(allocator, options);
    try ctx.ensureUnifiedV2Control(allocator, client);

    var status = try control_plane.sessionStatus(
        allocator,
        client,
        &ctx.g_control_request_counter,
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

pub fn executeSessionAttach(allocator: std.mem.Allocator, options: args.Options, cmd: args.Command) !void {
    const parsed = parseSessionAttachArgs(options, cmd) catch {
        logger.err("session attach usage: session attach <session_key> <agent_id> --workspace <workspace_id> [--workspace-token <token>]", .{});
        return error.InvalidArguments;
    };
    const workspace_id = parsed.workspace_id orelse {
        logger.err("session attach requires --workspace <workspace_id>", .{});
        return error.InvalidArguments;
    };

    const stdout = std.fs.File.stdout().deprecatedWriter();
    const client = try ctx.getOrCreateClient(allocator, options);
    try ctx.ensureUnifiedV2Control(allocator, client);

    var status = try control_plane.sessionAttach(
        allocator,
        client,
        &ctx.g_control_request_counter,
        parsed.session_key,
        parsed.agent_id,
        workspace_id,
        parsed.workspace_token,
    );
    defer status.deinit(allocator);
    try printSessionAttachStatus(stdout, &status);
}

pub fn executeSessionResume(allocator: std.mem.Allocator, options: args.Options, cmd: args.Command) !void {
    if (cmd.args.len != 1) {
        logger.err("session resume requires a session_key", .{});
        return error.InvalidArguments;
    }

    const stdout = std.fs.File.stdout().deprecatedWriter();
    const client = try ctx.getOrCreateClient(allocator, options);
    try ctx.ensureUnifiedV2Control(allocator, client);

    var status = try control_plane.sessionResume(allocator, client, &ctx.g_control_request_counter, cmd.args[0]);
    defer status.deinit(allocator);
    try printSessionAttachStatus(stdout, &status);
}

pub fn executeSessionClose(allocator: std.mem.Allocator, options: args.Options, cmd: args.Command) !void {
    if (cmd.args.len != 1) {
        logger.err("session close requires a session_key", .{});
        return error.InvalidArguments;
    }

    const stdout = std.fs.File.stdout().deprecatedWriter();
    const client = try ctx.getOrCreateClient(allocator, options);
    try ctx.ensureUnifiedV2Control(allocator, client);

    var result = try control_plane.closeSession(allocator, client, &ctx.g_control_request_counter, cmd.args[0]);
    defer result.deinit(allocator);

    try stdout.print("Closed: {s}\n", .{if (result.closed) "yes" else "no"});
    try stdout.print("Session: {s}\n", .{result.session_key});
    try stdout.print("Active session: {s}\n", .{result.active_session});
}

pub fn executeSessionRestore(allocator: std.mem.Allocator, options: args.Options, cmd: args.Command) !void {
    if (cmd.args.len > 1) {
        logger.err("session restore accepts zero or one agent_id", .{});
        return error.InvalidArguments;
    }

    const stdout = std.fs.File.stdout().deprecatedWriter();
    const client = try ctx.getOrCreateClient(allocator, options);
    try ctx.ensureUnifiedV2Control(allocator, client);
    var cfg = try ctx.loadCliConfig(allocator);
    defer cfg.deinit();

    var restored = try control_plane.sessionRestore(
        allocator,
        client,
        &ctx.g_control_request_counter,
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

    const attach_agent = if (ctx.isSystemWorkspaceId(attach_project_id))
        try allocator.dupe(u8, ctx.system_agent_id)
    else if (ctx.isSystemAgentId(session.agent_id))
        ctx.resolveAttachAgentForWorkspace(
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
        &ctx.g_control_request_counter,
        session.session_key,
        attach_agent,
        attach_project_id,
        project_token,
    );
    defer status.deinit(allocator);
    try printSessionAttachStatus(stdout, &status);
}
