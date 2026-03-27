// Workspace commands: list, info, create, use, up, doctor, status,
//                     template, bind, mount, handoff

const std = @import("std");
const args = @import("../args.zig");
const logger = @import("ziggy-core").utils.logger;
const unified = @import("spider-protocol").unified;
const control_plane = @import("control_plane");
const workspace_types = control_plane.workspace_types;
const Config = @import("../../client/config.zig").Config;
const ctx = @import("../client_context.zig");
const vd = @import("../venom_discovery.zig");
const output = @import("../output.zig");
const workspace_wizard = @import("../wizards/workspace_setup.zig");
const health_checks = @import("../../client/health_checks.zig");

// ── Internal helpers ──────────────────────────────────────────────────────────

fn resolveOperatorToken(options: args.Options, cfg: *const Config) ?[]const u8 {
    if (options.operator_token) |value| {
        if (value.len > 0) return value;
    }
    if (cfg.getRoleToken(.admin).len > 0) return cfg.getRoleToken(.admin);
    return null;
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

// ── Public execute functions ──────────────────────────────────────────────────

pub fn executeWorkspaceList(allocator: std.mem.Allocator, options: args.Options, cmd: args.Command) !void {
    _ = cmd;
    const stdout = std.fs.File.stdout().deprecatedWriter();
    const client = try ctx.getOrCreateClient(allocator, options);
    try ctx.ensureUnifiedV2Control(allocator, client);

    var cfg = try ctx.loadCliConfig(allocator);
    defer cfg.deinit();
    const selected_project = ctx.resolveWorkspaceSelection(options, &cfg);

    var projects = try control_plane.listWorkspaces(allocator, client, &ctx.g_control_request_counter);
    defer workspace_types.deinitWorkspaceList(allocator, &projects);

    if (projects.items.len == 0) {
        try stdout.print("(no workspaces)\n", .{});
        return;
    }

    if (options.json) {
        try stdout.writeAll("[\n");
        for (projects.items, 0..) |project, idx| {
            try stdout.print(
                "  {{\"id\":\"{s}\",\"name\":\"{s}\",\"status\":\"{s}\",\"template\":\"{s}\",\"mounts\":{d},\"binds\":{d}}}",
                .{
                    project.id,
                    project.name,
                    project.status,
                    project.template_id orelse "dev",
                    project.mount_count,
                    project.bind_count,
                },
            );
            if (idx + 1 < projects.items.len) try stdout.writeByte(',');
            try stdout.writeByte('\n');
        }
        try stdout.writeAll("]\n");
        return;
    }

    const ansi = ctx.stdoutSupportsAnsi();
    var tbl = try output.Table.init(allocator, &.{ "", "ID", "Name", "Status", "Template", "Mounts", "Binds" });
    defer tbl.deinit();
    for (projects.items) |project| {
        const marker = if (selected_project != null and std.mem.eql(u8, selected_project.?, project.id)) "*" else "";
        const mounts_str = try std.fmt.allocPrint(allocator, "{d}", .{project.mount_count});
        defer allocator.free(mounts_str);
        const binds_str = try std.fmt.allocPrint(allocator, "{d}", .{project.bind_count});
        defer allocator.free(binds_str);
        try tbl.row(&.{
            marker,
            project.id,
            project.name,
            project.status,
            project.template_id orelse "dev",
            mounts_str,
            binds_str,
        });
    }
    try tbl.print(stdout, ansi);
}

pub fn executeWorkspaceInfo(allocator: std.mem.Allocator, options: args.Options, cmd: args.Command) !void {
    if (cmd.args.len == 0) {
        logger.err("workspace info requires a workspace ID", .{});
        return error.InvalidArguments;
    }

    const stdout = std.fs.File.stdout().deprecatedWriter();
    const client = try ctx.getOrCreateClient(allocator, options);
    try ctx.ensureUnifiedV2Control(allocator, client);

    var detail = try control_plane.getWorkspace(allocator, client, &ctx.g_control_request_counter, cmd.args[0]);
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

pub fn executeWorkspaceCreate(allocator: std.mem.Allocator, options: args.Options, cmd: args.Command) !void {
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

    var cfg = try ctx.loadCliConfig(allocator);
    defer cfg.deinit();

    const stdout = std.fs.File.stdout().deprecatedWriter();
    const client = try ctx.getOrCreateClient(allocator, options);
    try ctx.ensureUnifiedV2Control(allocator, client);

    var created = try control_plane.createWorkspace(
        allocator,
        client,
        &ctx.g_control_request_counter,
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
            &ctx.g_control_request_counter,
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

pub fn executeWorkspaceUse(allocator: std.mem.Allocator, options: args.Options, cmd: args.Command) !void {
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

    var cfg = try ctx.loadCliConfig(allocator);
    defer cfg.deinit();
    if (cli_token) |token| {
        try cfg.setWorkspaceToken(project_id, token);
    }
    try cfg.setSelectedWorkspace(project_id);

    const stdout = std.fs.File.stdout().deprecatedWriter();
    const client = try ctx.getOrCreateClient(allocator, options);
    try ctx.ensureUnifiedV2Control(allocator, client);

    const effective_token = if (cli_token) |token| token else cfg.getWorkspaceToken(project_id);
    var status = try control_plane.activateWorkspace(
        allocator,
        client,
        &ctx.g_control_request_counter,
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

pub fn executeWorkspaceUp(allocator: std.mem.Allocator, options: args.Options, cmd: args.Command) !void {
    // Check for --interactive flag in sub-args first
    for (cmd.args) |arg| {
        if (std.mem.eql(u8, arg, "--interactive") or std.mem.eql(u8, arg, "-i")) {
            return workspace_wizard.run(allocator, options);
        }
    }
    if (options.interactive) {
        return workspace_wizard.run(allocator, options);
    }

    const stdout = std.fs.File.stdout().deprecatedWriter();
    const client = try ctx.getOrCreateClient(allocator, options);
    try ctx.ensureUnifiedV2Control(allocator, client);

    var cfg = try ctx.loadCliConfig(allocator);
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
        var default_fs_mount = vd.discoverDefaultFsMount(allocator, client, .{
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
        &ctx.g_control_request_counter,
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
        &ctx.g_control_request_counter,
        response_project_id,
        response_token,
    );
    defer status.deinit(allocator);
    try ctx.printWorkspaceStatus(stdout, &status, false);
}

test "effectiveWorkspaceUpTemplateId defaults only on create paths" {
    try std.testing.expectEqualStrings("dev", effectiveWorkspaceUpTemplateId(null, null).?);
    try std.testing.expectEqualStrings("custom", effectiveWorkspaceUpTemplateId(null, "custom").?);
    try std.testing.expect(effectiveWorkspaceUpTemplateId("ws-123", null) == null);
    try std.testing.expectEqualStrings("custom", effectiveWorkspaceUpTemplateId("ws-123", "custom").?);
}

pub fn executeWorkspaceDoctor(allocator: std.mem.Allocator, options: args.Options, cmd: args.Command) !void {
    _ = cmd;
    const stdout = std.fs.File.stdout().deprecatedWriter();
    const client = try ctx.getOrCreateClient(allocator, options);
    try ctx.ensureUnifiedV2Control(allocator, client);

    var cfg = try ctx.loadCliConfig(allocator);
    defer cfg.deinit();
    const project_id = ctx.resolveWorkspaceSelection(options, &cfg);
    const workspace_token: ?[]const u8 = if (project_id) |id|
        options.workspace_token orelse cfg.getWorkspaceToken(id)
    else
        null;

    var checks = try health_checks.runHealthChecks(
        allocator,
        client,
        &ctx.g_control_request_counter,
        project_id,
        workspace_token,
    );
    defer health_checks.deinitHealthChecks(allocator, &checks);

    for (checks) |check| {
        const prefix: []const u8 = switch (check.status) {
            .ok => "[OK]  ",
            .fail => "[FAIL]",
            .warning => "[WARN]",
        };
        try stdout.print("{s} {s}\n", .{ prefix, check.message });
    }

    const failures = health_checks.failureCount(checks);
    if (failures == 0) {
        try stdout.print("workspace doctor: ready\n", .{});
    } else {
        try stdout.print("workspace doctor: {d} issue(s) detected\n", .{failures});
        return error.InvalidResponse;
    }
}

pub fn executeWorkspaceStatus(allocator: std.mem.Allocator, options: args.Options, cmd: args.Command) !void {
    const stdout = std.fs.File.stdout().deprecatedWriter();
    const client = try ctx.getOrCreateClient(allocator, options);
    try ctx.ensureUnifiedV2Control(allocator, client);

    var cfg = try ctx.loadCliConfig(allocator);
    defer cfg.deinit();
    const project_id = if (cmd.args.len > 0)
        cmd.args[0]
    else
        ctx.resolveWorkspaceSelection(options, &cfg);

    var status = try control_plane.workspaceStatus(
        allocator,
        client,
        &ctx.g_control_request_counter,
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
    try ctx.printWorkspaceStatus(stdout, &status, options.verbose);

    if (options.verbose) {
        var reconcile = try control_plane.reconcileStatus(
            allocator,
            client,
            &ctx.g_control_request_counter,
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

pub fn executeWorkspaceTemplateCommand(allocator: std.mem.Allocator, options: args.Options, cmd: args.Command) !void {
    const stdout = std.fs.File.stdout().deprecatedWriter();
    const client = try ctx.getOrCreateClient(allocator, options);
    try ctx.ensureUnifiedV2Control(allocator, client);

    const action = if (cmd.args.len > 0) cmd.args[0] else "list";
    if (std.mem.eql(u8, action, "list")) {
        var templates = try control_plane.listWorkspaceTemplates(allocator, client, &ctx.g_control_request_counter);
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
        var template = try control_plane.getWorkspaceTemplate(allocator, client, &ctx.g_control_request_counter, cmd.args[1]);
        defer template.deinit(allocator);

        try stdout.print("Workspace template {s}\n", .{template.id});
        try stdout.print("  Description: {s}\n", .{template.description});
        try stdout.print("  Binds ({d}):\n", .{template.binds.items.len});
        for (template.binds.items) |bind| {
            try stdout.print(
                "    - {s} <= venom:{s} scope={s}\n",
                .{ bind.bind_path, bind.venom_id, bind.host_role },
            );
        }
        return;
    }

    logger.err("workspace template supports only list|info", .{});
    return error.InvalidArguments;
}

pub fn executeWorkspaceBindCommand(allocator: std.mem.Allocator, options: args.Options, cmd: args.Command) !void {
    if (cmd.args.len == 0) {
        logger.err("workspace bind requires add|remove|list", .{});
        return error.InvalidArguments;
    }

    const stdout = std.fs.File.stdout().deprecatedWriter();
    const client = try ctx.getOrCreateClient(allocator, options);
    try ctx.ensureUnifiedV2Control(allocator, client);

    var cfg = try ctx.loadCliConfig(allocator);
    defer cfg.deinit();

    const action = cmd.args[0];
    if (std.mem.eql(u8, action, "list")) {
        const workspace_id = if (cmd.args.len > 1)
            cmd.args[1]
        else
            ctx.resolveWorkspaceSelection(options, &cfg) orelse {
                logger.err("workspace bind list requires a workspace ID or selected workspace", .{});
                return error.InvalidArguments;
            };
        var detail = try control_plane.getWorkspace(allocator, client, &ctx.g_control_request_counter, workspace_id);
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

    const workspace_id = ctx.resolveWorkspaceSelection(options, &cfg) orelse {
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
            &ctx.g_control_request_counter,
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
            &ctx.g_control_request_counter,
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

pub fn executeWorkspaceMountCommand(allocator: std.mem.Allocator, options: args.Options, cmd: args.Command) !void {
    if (cmd.args.len == 0) {
        logger.err("workspace mount requires add|remove|list", .{});
        return error.InvalidArguments;
    }

    const stdout = std.fs.File.stdout().deprecatedWriter();
    const client = try ctx.getOrCreateClient(allocator, options);
    try ctx.ensureUnifiedV2Control(allocator, client);

    var cfg = try ctx.loadCliConfig(allocator);
    defer cfg.deinit();

    const action = cmd.args[0];
    if (std.mem.eql(u8, action, "list")) {
        const workspace_id = if (cmd.args.len > 1)
            cmd.args[1]
        else
            ctx.resolveWorkspaceSelection(options, &cfg) orelse {
                logger.err("workspace mount list requires a workspace ID or selected workspace", .{});
                return error.InvalidArguments;
            };
        var detail = try control_plane.getWorkspace(allocator, client, &ctx.g_control_request_counter, workspace_id);
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

    const workspace_id = ctx.resolveWorkspaceSelection(options, &cfg) orelse {
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
            &ctx.g_control_request_counter,
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
            &ctx.g_control_request_counter,
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

pub fn executeWorkspaceHandoffCommand(allocator: std.mem.Allocator, options: args.Options, cmd: args.Command) !void {
    const action = if (cmd.args.len > 0) cmd.args[0] else "show";
    if (!std.mem.eql(u8, action, "show")) {
        logger.err("workspace handoff supports only show", .{});
        return error.InvalidArguments;
    }

    const stdout = std.fs.File.stdout().deprecatedWriter();
    const client = try ctx.getOrCreateClient(allocator, options);
    try ctx.ensureUnifiedV2Control(allocator, client);

    var cfg = try ctx.loadCliConfig(allocator);
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
    const workspace_id = explicit_workspace_id orelse ctx.resolveWorkspaceSelection(options, &cfg) orelse {
        logger.err("workspace handoff show requires a workspace ID or selected workspace", .{});
        return error.InvalidArguments;
    };
    const workspace_token = if (options.workspace_token) |token| token else cfg.getWorkspaceToken(workspace_id);
    const auth_token = cfg.activeRoleToken();

    var detail = try control_plane.getWorkspace(allocator, client, &ctx.g_control_request_counter, workspace_id);
    defer detail.deinit(allocator);
    var status = try control_plane.workspaceStatus(
        allocator,
        client,
        &ctx.g_control_request_counter,
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
        try stdout.print("\nGeneric external worker:\n", .{});
        try stdout.print("  Open {s} in your external worker after the mount is ready.\n", .{mount_path});
    }
}
