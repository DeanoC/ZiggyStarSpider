const std = @import("std");
const unified_v2 = @import("unified_v2_client.zig");
pub const workspace_types = @import("workspace_types.zig");

pub const default_timeout_ms: i64 = unified_v2.default_control_timeout_ms;

pub const EnsuredNodeIdentity = struct {
    node_id: []u8,
    node_name: []u8,
    node_secret: []u8,

    pub fn deinit(self: *EnsuredNodeIdentity, allocator: std.mem.Allocator) void {
        allocator.free(self.node_id);
        allocator.free(self.node_name);
        allocator.free(self.node_secret);
        self.* = undefined;
    }
};

fn normalizeProjectToken(project_token: ?[]const u8) ?[]const u8 {
    const token = project_token orelse return null;
    const trimmed = std.mem.trim(u8, token, " \t\r\n");
    if (trimmed.len == 0) return null;
    return trimmed;
}

pub fn lastRemoteError() ?[]const u8 {
    return unified_v2.lastRemoteError();
}

pub fn ensureUnifiedV2Connection(
    allocator: std.mem.Allocator,
    client: anytype,
    message_counter: *u64,
) !void {
    try ensureUnifiedV2ConnectionWithTimeout(allocator, client, message_counter, default_timeout_ms);
}

pub fn ensureUnifiedV2ConnectionWithTimeout(
    allocator: std.mem.Allocator,
    client: anytype,
    message_counter: *u64,
    timeout_ms: i64,
) !void {
    const payload_json = try ensureUnifiedV2ConnectionPayloadJsonWithTimeout(
        allocator,
        client,
        message_counter,
        timeout_ms,
    );
    allocator.free(payload_json);
}

pub fn ensureUnifiedV2ConnectionPayloadJsonWithTimeout(
    allocator: std.mem.Allocator,
    client: anytype,
    message_counter: *u64,
    timeout_ms: i64,
) ![]u8 {
    return unified_v2.sendControlVersionAndConnectPayloadJson(allocator, client, message_counter, timeout_ms);
}

pub fn requestControlPayloadJson(
    allocator: std.mem.Allocator,
    client: anytype,
    message_counter: *u64,
    control_type: []const u8,
    payload_json: ?[]const u8,
) ![]u8 {
    return requestControlPayloadJsonWithTimeout(
        allocator,
        client,
        message_counter,
        control_type,
        payload_json,
        default_timeout_ms,
    );
}

pub fn requestControlPayloadJsonWithTimeout(
    allocator: std.mem.Allocator,
    client: anytype,
    message_counter: *u64,
    control_type: []const u8,
    payload_json: ?[]const u8,
    timeout_ms: i64,
) ![]u8 {
    const request_id = try unified_v2.nextRequestId(allocator, message_counter, "control");
    defer allocator.free(request_id);

    var response = try unified_v2.sendControlRequest(
        allocator,
        client,
        control_type,
        request_id,
        payload_json,
        timeout_ms,
    );
    defer response.deinit(allocator);

    return unified_v2.controlReplyPayloadJson(allocator, &response);
}

pub fn listProjects(
    allocator: std.mem.Allocator,
    client: anytype,
    message_counter: *u64,
) !std.ArrayListUnmanaged(workspace_types.ProjectSummary) {
    const payload_json = try requestControlPayloadJson(
        allocator,
        client,
        message_counter,
        "control.project_list",
        null,
    );
    defer allocator.free(payload_json);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload_json, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidResponse;
    const projects_val = parsed.value.object.get("projects") orelse return error.InvalidResponse;
    if (projects_val != .array) return error.InvalidResponse;

    var projects = std.ArrayListUnmanaged(workspace_types.ProjectSummary){};
    errdefer workspace_types.deinitProjectList(allocator, &projects);

    for (projects_val.array.items) |item| {
        if (item != .object) return error.InvalidResponse;
        try projects.append(allocator, try parseProjectSummary(allocator, item.object));
    }
    return projects;
}

pub fn getProject(
    allocator: std.mem.Allocator,
    client: anytype,
    message_counter: *u64,
    project_id: []const u8,
) !workspace_types.ProjectDetail {
    const escaped_id = try unified_v2.jsonEscape(allocator, project_id);
    defer allocator.free(escaped_id);
    const payload_req = try std.fmt.allocPrint(allocator, "{{\"project_id\":\"{s}\"}}", .{escaped_id});
    defer allocator.free(payload_req);

    const payload_json = try requestControlPayloadJson(
        allocator,
        client,
        message_counter,
        "control.project_get",
        payload_req,
    );
    defer allocator.free(payload_json);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload_json, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidResponse;

    return parseProjectDetail(allocator, parsed.value.object);
}

pub fn createProject(
    allocator: std.mem.Allocator,
    client: anytype,
    message_counter: *u64,
    name: []const u8,
    vision: ?[]const u8,
    operator_token: ?[]const u8,
) !workspace_types.ProjectDetail {
    const escaped_name = try unified_v2.jsonEscape(allocator, name);
    defer allocator.free(escaped_name);

    const escaped_vision = if (vision) |value| blk: {
        if (value.len == 0) break :blk null;
        break :blk try unified_v2.jsonEscape(allocator, value);
    } else null;
    defer if (escaped_vision) |value| allocator.free(value);

    const escaped_operator_token = if (operator_token) |value| blk: {
        if (value.len == 0) break :blk null;
        break :blk try unified_v2.jsonEscape(allocator, value);
    } else null;
    defer if (escaped_operator_token) |value| allocator.free(value);

    var payload = std.ArrayListUnmanaged(u8){};
    defer payload.deinit(allocator);
    try payload.append(allocator, '{');
    try payload.writer(allocator).print("\"name\":\"{s}\"", .{escaped_name});
    if (escaped_vision) |value| {
        try payload.writer(allocator).print(",\"vision\":\"{s}\"", .{value});
    }
    if (escaped_operator_token) |value| {
        try payload.writer(allocator).print(",\"operator_token\":\"{s}\"", .{value});
    }
    try payload.append(allocator, '}');

    const payload_json = try requestControlPayloadJson(
        allocator,
        client,
        message_counter,
        "control.project_create",
        payload.items,
    );
    defer allocator.free(payload_json);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload_json, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidResponse;

    return parseProjectDetail(allocator, parsed.value.object);
}

pub fn activateProject(
    allocator: std.mem.Allocator,
    client: anytype,
    message_counter: *u64,
    project_id: []const u8,
    project_token: ?[]const u8,
) !workspace_types.WorkspaceStatus {
    const normalized_project_token = normalizeProjectToken(project_token);
    const escaped_project = try unified_v2.jsonEscape(allocator, project_id);
    defer allocator.free(escaped_project);
    const payload_req = if (normalized_project_token) |token| blk: {
        const escaped_token = try unified_v2.jsonEscape(allocator, token);
        defer allocator.free(escaped_token);
        break :blk try std.fmt.allocPrint(
            allocator,
            "{{\"project_id\":\"{s}\",\"project_token\":\"{s}\"}}",
            .{ escaped_project, escaped_token },
        );
    } else try std.fmt.allocPrint(
        allocator,
        "{{\"project_id\":\"{s}\"}}",
        .{escaped_project},
    );
    defer allocator.free(payload_req);

    const payload_json = try requestControlPayloadJson(
        allocator,
        client,
        message_counter,
        "control.project_activate",
        payload_req,
    );
    defer allocator.free(payload_json);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload_json, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidResponse;

    return parseWorkspaceStatus(allocator, parsed.value.object);
}

pub fn setProjectMount(
    allocator: std.mem.Allocator,
    client: anytype,
    message_counter: *u64,
    project_id: []const u8,
    project_token: ?[]const u8,
    node_id: []const u8,
    export_name: []const u8,
    mount_path: []const u8,
) !workspace_types.ProjectDetail {
    const normalized_project_token = normalizeProjectToken(project_token);
    const escaped_project = try unified_v2.jsonEscape(allocator, project_id);
    defer allocator.free(escaped_project);
    const escaped_token = if (normalized_project_token) |value|
        try unified_v2.jsonEscape(allocator, value)
    else
        null;
    defer if (escaped_token) |value| allocator.free(value);
    const escaped_node = try unified_v2.jsonEscape(allocator, node_id);
    defer allocator.free(escaped_node);
    const escaped_export = try unified_v2.jsonEscape(allocator, export_name);
    defer allocator.free(escaped_export);
    const escaped_mount = try unified_v2.jsonEscape(allocator, mount_path);
    defer allocator.free(escaped_mount);

    var payload = std.ArrayListUnmanaged(u8){};
    defer payload.deinit(allocator);
    try payload.append(allocator, '{');
    try payload.writer(allocator).print(
        "\"project_id\":\"{s}\",\"node_id\":\"{s}\",\"export_name\":\"{s}\",\"mount_path\":\"{s}\"",
        .{ escaped_project, escaped_node, escaped_export, escaped_mount },
    );
    if (escaped_token) |value| {
        try payload.writer(allocator).print(",\"project_token\":\"{s}\"", .{value});
    }
    try payload.append(allocator, '}');

    const payload_json = try requestControlPayloadJson(
        allocator,
        client,
        message_counter,
        "control.project_mount_set",
        payload.items,
    );
    defer allocator.free(payload_json);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload_json, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidResponse;
    return parseProjectDetail(allocator, parsed.value.object);
}

pub fn removeProjectMount(
    allocator: std.mem.Allocator,
    client: anytype,
    message_counter: *u64,
    project_id: []const u8,
    project_token: ?[]const u8,
    mount_path: []const u8,
    node_id_filter: ?[]const u8,
    export_name_filter: ?[]const u8,
) !workspace_types.ProjectDetail {
    if ((node_id_filter == null) != (export_name_filter == null)) return error.InvalidArguments;

    const normalized_project_token = normalizeProjectToken(project_token);
    const escaped_project = try unified_v2.jsonEscape(allocator, project_id);
    defer allocator.free(escaped_project);
    const escaped_token = if (normalized_project_token) |value|
        try unified_v2.jsonEscape(allocator, value)
    else
        null;
    defer if (escaped_token) |value| allocator.free(value);
    const escaped_mount = try unified_v2.jsonEscape(allocator, mount_path);
    defer allocator.free(escaped_mount);

    var payload = std.ArrayListUnmanaged(u8){};
    defer payload.deinit(allocator);
    try payload.append(allocator, '{');
    try payload.writer(allocator).print(
        "\"project_id\":\"{s}\",\"mount_path\":\"{s}\"",
        .{ escaped_project, escaped_mount },
    );
    if (escaped_token) |value| {
        try payload.writer(allocator).print(",\"project_token\":\"{s}\"", .{value});
    }
    if (node_id_filter) |node_id| {
        const escaped_node = try unified_v2.jsonEscape(allocator, node_id);
        defer allocator.free(escaped_node);
        const escaped_export = try unified_v2.jsonEscape(allocator, export_name_filter.?);
        defer allocator.free(escaped_export);
        try payload.writer(allocator).print(
            ",\"node_id\":\"{s}\",\"export_name\":\"{s}\"",
            .{ escaped_node, escaped_export },
        );
    }
    try payload.append(allocator, '}');

    const payload_json = try requestControlPayloadJson(
        allocator,
        client,
        message_counter,
        "control.project_mount_remove",
        payload.items,
    );
    defer allocator.free(payload_json);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload_json, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidResponse;
    return parseProjectDetail(allocator, parsed.value.object);
}

pub const ProjectTokenMutation = struct {
    project_id: []u8,
    project_token: ?[]u8 = null,
    updated_at_ms: i64 = 0,
    rotated: bool = false,
    revoked: bool = false,

    pub fn deinit(self: *ProjectTokenMutation, allocator: std.mem.Allocator) void {
        allocator.free(self.project_id);
        if (self.project_token) |value| allocator.free(value);
        self.* = undefined;
    }
};

pub fn rotateProjectToken(
    allocator: std.mem.Allocator,
    client: anytype,
    message_counter: *u64,
    project_id: []const u8,
    current_project_token: ?[]const u8,
) !ProjectTokenMutation {
    const normalized_project_token = normalizeProjectToken(current_project_token);
    const escaped_project = try unified_v2.jsonEscape(allocator, project_id);
    defer allocator.free(escaped_project);
    const escaped_token = if (normalized_project_token) |value|
        try unified_v2.jsonEscape(allocator, value)
    else
        null;
    defer if (escaped_token) |value| allocator.free(value);

    var payload = std.ArrayListUnmanaged(u8){};
    defer payload.deinit(allocator);
    try payload.append(allocator, '{');
    try payload.writer(allocator).print("\"project_id\":\"{s}\"", .{escaped_project});
    if (escaped_token) |value| {
        try payload.writer(allocator).print(",\"project_token\":\"{s}\"", .{value});
    }
    try payload.append(allocator, '}');

    const payload_json = try requestControlPayloadJson(
        allocator,
        client,
        message_counter,
        "control.project_token_rotate",
        payload.items,
    );
    defer allocator.free(payload_json);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload_json, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidResponse;
    return parseProjectTokenMutation(allocator, parsed.value.object);
}

pub fn revokeProjectToken(
    allocator: std.mem.Allocator,
    client: anytype,
    message_counter: *u64,
    project_id: []const u8,
    current_project_token: ?[]const u8,
) !ProjectTokenMutation {
    const normalized_project_token = normalizeProjectToken(current_project_token);
    const escaped_project = try unified_v2.jsonEscape(allocator, project_id);
    defer allocator.free(escaped_project);
    const escaped_token = if (normalized_project_token) |value|
        try unified_v2.jsonEscape(allocator, value)
    else
        null;
    defer if (escaped_token) |value| allocator.free(value);

    var payload = std.ArrayListUnmanaged(u8){};
    defer payload.deinit(allocator);
    try payload.append(allocator, '{');
    try payload.writer(allocator).print("\"project_id\":\"{s}\"", .{escaped_project});
    if (escaped_token) |value| {
        try payload.writer(allocator).print(",\"project_token\":\"{s}\"", .{value});
    }
    try payload.append(allocator, '}');

    const payload_json = try requestControlPayloadJson(
        allocator,
        client,
        message_counter,
        "control.project_token_revoke",
        payload.items,
    );
    defer allocator.free(payload_json);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload_json, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidResponse;
    return parseProjectTokenMutation(allocator, parsed.value.object);
}

pub fn listNodes(
    allocator: std.mem.Allocator,
    client: anytype,
    message_counter: *u64,
) !std.ArrayListUnmanaged(workspace_types.NodeInfo) {
    const payload_json = try requestControlPayloadJson(
        allocator,
        client,
        message_counter,
        "control.node_list",
        null,
    );
    defer allocator.free(payload_json);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload_json, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidResponse;
    const nodes_val = parsed.value.object.get("nodes") orelse return error.InvalidResponse;
    if (nodes_val != .array) return error.InvalidResponse;

    var nodes = std.ArrayListUnmanaged(workspace_types.NodeInfo){};
    errdefer workspace_types.deinitNodeList(allocator, &nodes);

    for (nodes_val.array.items) |item| {
        if (item != .object) return error.InvalidResponse;
        try nodes.append(allocator, try parseNodeInfo(allocator, item.object));
    }
    return nodes;
}

pub fn ensureNode(
    allocator: std.mem.Allocator,
    client: anytype,
    message_counter: *u64,
    node_name: []const u8,
    fs_url: ?[]const u8,
    lease_ttl_ms: ?u64,
) !EnsuredNodeIdentity {
    const escaped_node_name = try unified_v2.jsonEscape(allocator, node_name);
    defer allocator.free(escaped_node_name);

    var payload = std.ArrayListUnmanaged(u8){};
    defer payload.deinit(allocator);
    try payload.writer(allocator).print("{{\"node_name\":\"{s}\"", .{escaped_node_name});

    if (fs_url) |value| {
        const escaped_fs_url = try unified_v2.jsonEscape(allocator, value);
        defer allocator.free(escaped_fs_url);
        try payload.writer(allocator).print(",\"fs_url\":\"{s}\"", .{escaped_fs_url});
    }
    if (lease_ttl_ms) |value| {
        try payload.writer(allocator).print(",\"lease_ttl_ms\":{d}", .{value});
    }
    try payload.append(allocator, '}');

    const payload_json = try requestControlPayloadJson(
        allocator,
        client,
        message_counter,
        "control.node_ensure",
        payload.items,
    );
    defer allocator.free(payload_json);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload_json, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidResponse;

    return .{
        .node_id = try dupRequiredString(allocator, parsed.value.object, "node_id"),
        .node_name = try dupRequiredString(allocator, parsed.value.object, "node_name"),
        .node_secret = try dupRequiredString(allocator, parsed.value.object, "node_secret"),
    };
}

pub fn bindVenomProvider(
    allocator: std.mem.Allocator,
    client: anytype,
    message_counter: *u64,
    venom_id: []const u8,
    node_id: ?[]const u8,
    scope: ?[]const u8,
    project_id: ?[]const u8,
    agent_id: ?[]const u8,
) ![]u8 {
    const escaped_venom = try unified_v2.jsonEscape(allocator, venom_id);
    defer allocator.free(escaped_venom);

    var payload = std.ArrayListUnmanaged(u8){};
    defer payload.deinit(allocator);
    try payload.writer(allocator).print("{{\"venom_id\":\"{s}\"", .{escaped_venom});
    if (node_id) |value| {
        const escaped_node = try unified_v2.jsonEscape(allocator, value);
        defer allocator.free(escaped_node);
        try payload.writer(allocator).print(",\"node_id\":\"{s}\"", .{escaped_node});
    }
    if (scope) |value| {
        const escaped_scope = try unified_v2.jsonEscape(allocator, value);
        defer allocator.free(escaped_scope);
        try payload.writer(allocator).print(",\"scope\":\"{s}\"", .{escaped_scope});
    }
    if (project_id) |value| {
        const escaped_project = try unified_v2.jsonEscape(allocator, value);
        defer allocator.free(escaped_project);
        try payload.writer(allocator).print(",\"project_id\":\"{s}\"", .{escaped_project});
    }
    if (agent_id) |value| {
        const escaped_agent = try unified_v2.jsonEscape(allocator, value);
        defer allocator.free(escaped_agent);
        try payload.writer(allocator).print(",\"agent_id\":\"{s}\"", .{escaped_agent});
    }
    try payload.append(allocator, '}');

    return requestControlPayloadJson(
        allocator,
        client,
        message_counter,
        "control.venom_bind",
        payload.items,
    );
}

pub fn getNode(
    allocator: std.mem.Allocator,
    client: anytype,
    message_counter: *u64,
    node_id: []const u8,
) !workspace_types.NodeInfo {
    const escaped_id = try unified_v2.jsonEscape(allocator, node_id);
    defer allocator.free(escaped_id);
    const payload_req = try std.fmt.allocPrint(allocator, "{{\"node_id\":\"{s}\"}}", .{escaped_id});
    defer allocator.free(payload_req);

    const payload_json = try requestControlPayloadJson(
        allocator,
        client,
        message_counter,
        "control.node_get",
        payload_req,
    );
    defer allocator.free(payload_json);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload_json, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidResponse;

    const node_val = parsed.value.object.get("node") orelse return error.InvalidResponse;
    if (node_val != .object) return error.InvalidResponse;
    return parseNodeInfo(allocator, node_val.object);
}

pub fn listAgents(
    allocator: std.mem.Allocator,
    client: anytype,
    message_counter: *u64,
) !std.ArrayListUnmanaged(workspace_types.AgentInfo) {
    const payload_json = try requestControlPayloadJson(
        allocator,
        client,
        message_counter,
        "control.agent_list",
        null,
    );
    defer allocator.free(payload_json);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload_json, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidResponse;
    const agents_val = parsed.value.object.get("agents") orelse return error.InvalidResponse;
    if (agents_val != .array) return error.InvalidResponse;

    var agents = std.ArrayListUnmanaged(workspace_types.AgentInfo){};
    errdefer workspace_types.deinitAgentList(allocator, &agents);

    for (agents_val.array.items) |item| {
        if (item != .object) return error.InvalidResponse;
        try agents.append(allocator, try parseAgentInfo(allocator, item.object));
    }
    return agents;
}

pub fn getAgent(
    allocator: std.mem.Allocator,
    client: anytype,
    message_counter: *u64,
    agent_id: []const u8,
) !workspace_types.AgentInfo {
    const escaped_id = try unified_v2.jsonEscape(allocator, agent_id);
    defer allocator.free(escaped_id);
    const payload_req = try std.fmt.allocPrint(allocator, "{{\"agent_id\":\"{s}\"}}", .{escaped_id});
    defer allocator.free(payload_req);

    const payload_json = try requestControlPayloadJson(
        allocator,
        client,
        message_counter,
        "control.agent_get",
        payload_req,
    );
    defer allocator.free(payload_json);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload_json, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidResponse;
    const agent_val = parsed.value.object.get("agent") orelse return error.InvalidResponse;
    if (agent_val != .object) return error.InvalidResponse;
    return parseAgentInfo(allocator, agent_val.object);
}

pub fn workspaceStatus(
    allocator: std.mem.Allocator,
    client: anytype,
    message_counter: *u64,
    project_id: ?[]const u8,
    project_token: ?[]const u8,
) !workspace_types.WorkspaceStatus {
    const normalized_project_token = normalizeProjectToken(project_token);
    var payload_req: ?[]u8 = null;
    defer if (payload_req) |value| allocator.free(value);

    if (project_id) |project| {
        const escaped_project = try unified_v2.jsonEscape(allocator, project);
        defer allocator.free(escaped_project);
        if (normalized_project_token) |token| {
            const escaped_token = try unified_v2.jsonEscape(allocator, token);
            defer allocator.free(escaped_token);
            payload_req = try std.fmt.allocPrint(
                allocator,
                "{{\"project_id\":\"{s}\",\"project_token\":\"{s}\"}}",
                .{ escaped_project, escaped_token },
            );
        } else {
            payload_req = try std.fmt.allocPrint(allocator, "{{\"project_id\":\"{s}\"}}", .{escaped_project});
        }
    }

    const payload_json = try requestControlPayloadJson(
        allocator,
        client,
        message_counter,
        "control.workspace_status",
        if (payload_req) |value| value else null,
    );
    defer allocator.free(payload_json);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload_json, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidResponse;

    return parseWorkspaceStatus(allocator, parsed.value.object);
}

pub fn sessionStatus(
    allocator: std.mem.Allocator,
    client: anytype,
    message_counter: *u64,
    session_key: ?[]const u8,
) !workspace_types.SessionAttachStatus {
    return sessionStatusWithTimeout(
        allocator,
        client,
        message_counter,
        session_key,
        default_timeout_ms,
    );
}

pub fn sessionStatusWithTimeout(
    allocator: std.mem.Allocator,
    client: anytype,
    message_counter: *u64,
    session_key: ?[]const u8,
    timeout_ms: i64,
) !workspace_types.SessionAttachStatus {
    var payload_req: ?[]u8 = null;
    defer if (payload_req) |value| allocator.free(value);
    if (session_key) |value| {
        const escaped_session = try unified_v2.jsonEscape(allocator, value);
        defer allocator.free(escaped_session);
        payload_req = try std.fmt.allocPrint(
            allocator,
            "{{\"session_key\":\"{s}\"}}",
            .{escaped_session},
        );
    }

    const payload_json = try requestControlPayloadJsonWithTimeout(
        allocator,
        client,
        message_counter,
        "control.session_status",
        if (payload_req) |value| value else null,
        timeout_ms,
    );
    defer allocator.free(payload_json);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload_json, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidResponse;
    return parseSessionAttachStatus(allocator, parsed.value.object);
}

pub fn sessionAttach(
    allocator: std.mem.Allocator,
    client: anytype,
    message_counter: *u64,
    session_key: []const u8,
    agent_id: []const u8,
    project_id: ?[]const u8,
    project_token: ?[]const u8,
) !workspace_types.SessionAttachStatus {
    const project = project_id orelse return error.ProjectIdRequired;
    const trimmed_project = std.mem.trim(u8, project, " \t\r\n");
    if (trimmed_project.len == 0) return error.ProjectIdRequired;
    const normalized_project_token = normalizeProjectToken(project_token);

    const escaped_session = try unified_v2.jsonEscape(allocator, session_key);
    defer allocator.free(escaped_session);
    const escaped_agent = try unified_v2.jsonEscape(allocator, agent_id);
    defer allocator.free(escaped_agent);
    const escaped_project = try unified_v2.jsonEscape(allocator, trimmed_project);
    defer allocator.free(escaped_project);

    const escaped_token = if (normalized_project_token) |value|
        try unified_v2.jsonEscape(allocator, value)
    else
        null;
    defer if (escaped_token) |value| allocator.free(value);

    var payload = std.ArrayListUnmanaged(u8){};
    defer payload.deinit(allocator);
    try payload.writer(allocator).print(
        "{{\"session_key\":\"{s}\",\"agent_id\":\"{s}\",\"project_id\":\"{s}\"",
        .{ escaped_session, escaped_agent, escaped_project },
    );
    if (escaped_token) |value| {
        try payload.writer(allocator).print(",\"project_token\":\"{s}\"", .{value});
    }
    try payload.append(allocator, '}');

    const payload_json = try requestControlPayloadJson(
        allocator,
        client,
        message_counter,
        "control.session_attach",
        payload.items,
    );
    defer allocator.free(payload_json);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload_json, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidResponse;
    return parseSessionAttachStatus(allocator, parsed.value.object);
}

pub fn sessionResume(
    allocator: std.mem.Allocator,
    client: anytype,
    message_counter: *u64,
    session_key: []const u8,
) !workspace_types.SessionAttachStatus {
    const escaped_session = try unified_v2.jsonEscape(allocator, session_key);
    defer allocator.free(escaped_session);
    const payload_req = try std.fmt.allocPrint(
        allocator,
        "{{\"session_key\":\"{s}\"}}",
        .{escaped_session},
    );
    defer allocator.free(payload_req);

    const payload_json = try requestControlPayloadJson(
        allocator,
        client,
        message_counter,
        "control.session_resume",
        payload_req,
    );
    defer allocator.free(payload_json);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload_json, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidResponse;
    return parseSessionAttachStatus(allocator, parsed.value.object);
}

pub fn listSessions(
    allocator: std.mem.Allocator,
    client: anytype,
    message_counter: *u64,
) !workspace_types.SessionList {
    const payload_json = try requestControlPayloadJson(
        allocator,
        client,
        message_counter,
        "control.session_list",
        null,
    );
    defer allocator.free(payload_json);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload_json, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidResponse;
    return parseSessionList(allocator, parsed.value.object);
}

pub fn closeSession(
    allocator: std.mem.Allocator,
    client: anytype,
    message_counter: *u64,
    session_key: []const u8,
) !workspace_types.SessionCloseResult {
    const escaped_session = try unified_v2.jsonEscape(allocator, session_key);
    defer allocator.free(escaped_session);
    const payload_req = try std.fmt.allocPrint(
        allocator,
        "{{\"session_key\":\"{s}\"}}",
        .{escaped_session},
    );
    defer allocator.free(payload_req);

    const payload_json = try requestControlPayloadJson(
        allocator,
        client,
        message_counter,
        "control.session_close",
        payload_req,
    );
    defer allocator.free(payload_json);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload_json, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidResponse;
    return parseSessionCloseResult(allocator, parsed.value.object);
}

pub fn sessionRestore(
    allocator: std.mem.Allocator,
    client: anytype,
    message_counter: *u64,
    agent_id: ?[]const u8,
) !workspace_types.SessionRestoreResult {
    var payload_req: ?[]u8 = null;
    defer if (payload_req) |value| allocator.free(value);
    if (agent_id) |value| {
        const escaped_agent = try unified_v2.jsonEscape(allocator, value);
        defer allocator.free(escaped_agent);
        payload_req = try std.fmt.allocPrint(
            allocator,
            "{{\"agent_id\":\"{s}\"}}",
            .{escaped_agent},
        );
    }

    const payload_json = try requestControlPayloadJson(
        allocator,
        client,
        message_counter,
        "control.session_restore",
        if (payload_req) |value| value else null,
    );
    defer allocator.free(payload_json);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload_json, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidResponse;
    return parseSessionRestoreResult(allocator, parsed.value.object);
}

pub fn sessionHistory(
    allocator: std.mem.Allocator,
    client: anytype,
    message_counter: *u64,
    agent_id: ?[]const u8,
    limit: usize,
) !std.ArrayListUnmanaged(workspace_types.SessionSummary) {
    const escaped_agent = if (agent_id) |value|
        try unified_v2.jsonEscape(allocator, value)
    else
        null;
    defer if (escaped_agent) |value| allocator.free(value);

    var payload = std.ArrayListUnmanaged(u8){};
    defer payload.deinit(allocator);
    try payload.append(allocator, '{');
    var appended = false;
    if (escaped_agent) |value| {
        try payload.writer(allocator).print("\"agent_id\":\"{s}\"", .{value});
        appended = true;
    }
    if (limit > 0) {
        if (appended) try payload.append(allocator, ',');
        try payload.writer(allocator).print("\"limit\":{d}", .{limit});
    }
    try payload.append(allocator, '}');

    const payload_json = try requestControlPayloadJson(
        allocator,
        client,
        message_counter,
        "control.session_history",
        payload.items,
    );
    defer allocator.free(payload_json);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload_json, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidResponse;
    return parseSessionHistory(allocator, parsed.value.object);
}

pub fn reconcileStatus(
    allocator: std.mem.Allocator,
    client: anytype,
    message_counter: *u64,
    project_id: ?[]const u8,
) !workspace_types.ReconcileStatus {
    var payload_req: ?[]u8 = null;
    defer if (payload_req) |value| allocator.free(value);
    if (project_id) |value| {
        const escaped_project = try unified_v2.jsonEscape(allocator, value);
        defer allocator.free(escaped_project);
        payload_req = try std.fmt.allocPrint(allocator, "{{\"project_id\":\"{s}\"}}", .{escaped_project});
    }

    const payload_json = try requestControlPayloadJson(
        allocator,
        client,
        message_counter,
        "control.reconcile_status",
        if (payload_req) |value| value else null,
    );
    defer allocator.free(payload_json);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload_json, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidResponse;

    return parseReconcileStatus(allocator, parsed.value.object);
}

fn parseProjectSummary(
    allocator: std.mem.Allocator,
    obj: std.json.ObjectMap,
) !workspace_types.ProjectSummary {
    return .{
        .id = try dupRequiredStringAny(allocator, obj, &.{ "id", "project_id" }),
        .name = try dupRequiredString(allocator, obj, "name"),
        .vision = try dupOptionalString(allocator, obj, "vision") orelse try allocator.dupe(u8, ""),
        .status = try dupOptionalString(allocator, obj, "status") orelse try allocator.dupe(u8, "active"),
        .kind = try dupOptionalString(allocator, obj, "kind"),
        .is_delete_protected = try getOptionalBool(obj, "is_delete_protected", false),
        .token_locked = try getOptionalBool(obj, "token_locked", false),
        .mount_count = @intCast(try getOptionalU64(obj, "mount_count", 0)),
        .created_at_ms = try getOptionalI64(obj, "created_at_ms", 0),
        .updated_at_ms = try getOptionalI64(obj, "updated_at_ms", 0),
    };
}

fn parseProjectDetail(
    allocator: std.mem.Allocator,
    obj: std.json.ObjectMap,
) !workspace_types.ProjectDetail {
    var detail = workspace_types.ProjectDetail{
        .id = try dupRequiredStringAny(allocator, obj, &.{ "id", "project_id" }),
        .name = try dupRequiredString(allocator, obj, "name"),
        .vision = try dupOptionalString(allocator, obj, "vision") orelse try allocator.dupe(u8, ""),
        .status = try dupOptionalString(allocator, obj, "status") orelse try allocator.dupe(u8, "active"),
        .kind = try dupOptionalString(allocator, obj, "kind"),
        .is_delete_protected = try getOptionalBool(obj, "is_delete_protected", false),
        .token_locked = try getOptionalBool(obj, "token_locked", false),
        .created_at_ms = try getOptionalI64(obj, "created_at_ms", 0),
        .updated_at_ms = try getOptionalI64(obj, "updated_at_ms", 0),
        .project_token = try dupOptionalString(allocator, obj, "project_token"),
    };
    errdefer detail.deinit(allocator);

    const mounts_val = obj.get("mounts") orelse return detail;
    if (mounts_val != .array) return error.InvalidResponse;
    for (mounts_val.array.items) |item| {
        if (item != .object) return error.InvalidResponse;
        try detail.mounts.append(allocator, try parseMount(allocator, item.object));
    }

    return detail;
}

fn parseProjectTokenMutation(
    allocator: std.mem.Allocator,
    obj: std.json.ObjectMap,
) !ProjectTokenMutation {
    return .{
        .project_id = try dupRequiredStringAny(allocator, obj, &.{ "project_id", "id" }),
        .project_token = try dupOptionalNullableString(allocator, obj, "project_token"),
        .updated_at_ms = try getOptionalI64(obj, "updated_at_ms", 0),
        .rotated = try getOptionalBool(obj, "rotated", false),
        .revoked = try getOptionalBool(obj, "revoked", false),
    };
}

fn parseNodeInfo(
    allocator: std.mem.Allocator,
    obj: std.json.ObjectMap,
) !workspace_types.NodeInfo {
    return .{
        .node_id = try dupRequiredString(allocator, obj, "node_id"),
        .node_name = try dupRequiredString(allocator, obj, "node_name"),
        .fs_url = try dupOptionalString(allocator, obj, "fs_url") orelse try allocator.dupe(u8, ""),
        .joined_at_ms = try getOptionalI64(obj, "joined_at_ms", 0),
        .last_seen_ms = try getOptionalI64(obj, "last_seen_ms", 0),
        .lease_expires_at_ms = try getOptionalI64(obj, "lease_expires_at_ms", 0),
    };
}

fn parseAgentInfo(
    allocator: std.mem.Allocator,
    obj: std.json.ObjectMap,
) !workspace_types.AgentInfo {
    var info = workspace_types.AgentInfo{
        .id = try dupRequiredStringAny(allocator, obj, &.{ "id", "agent_id" }),
        .name = try dupRequiredString(allocator, obj, "name"),
        .description = try dupOptionalString(allocator, obj, "description") orelse try allocator.dupe(u8, ""),
        .is_default = try getOptionalBool(obj, "is_default", false),
        .identity_loaded = try getOptionalBool(obj, "identity_loaded", false),
        .needs_hatching = try getOptionalBool(obj, "needs_hatching", false),
    };
    errdefer info.deinit(allocator);

    if (obj.get("capabilities")) |caps_val| {
        if (caps_val != .array) return error.InvalidResponse;
        for (caps_val.array.items) |item| {
            if (item != .string) return error.InvalidResponse;
            try info.capabilities.append(allocator, try allocator.dupe(u8, item.string));
        }
    }
    return info;
}

fn parseWorkspaceStatus(
    allocator: std.mem.Allocator,
    obj: std.json.ObjectMap,
) !workspace_types.WorkspaceStatus {
    var status = workspace_types.WorkspaceStatus{
        .agent_id = try dupRequiredString(allocator, obj, "agent_id"),
        .project_id = try dupOptionalNullableString(allocator, obj, "project_id"),
        .workspace_root = try dupOptionalNullableString(allocator, obj, "workspace_root"),
    };
    errdefer status.deinit(allocator);

    if (obj.get("mounts")) |mounts_val| {
        if (mounts_val != .array) return error.InvalidResponse;
        for (mounts_val.array.items) |item| {
            if (item != .object) return error.InvalidResponse;
            try status.mounts.append(allocator, try parseMount(allocator, item.object));
        }
    }

    if (obj.get("desired_mounts")) |desired_val| {
        if (desired_val != .array) return error.InvalidResponse;
        for (desired_val.array.items) |item| {
            if (item != .object) return error.InvalidResponse;
            try status.desired_mounts.append(allocator, try parseMount(allocator, item.object));
        }
    }

    if (obj.get("actual_mounts")) |actual_val| {
        if (actual_val != .array) return error.InvalidResponse;
        for (actual_val.array.items) |item| {
            if (item != .object) return error.InvalidResponse;
            try status.actual_mounts.append(allocator, try parseMount(allocator, item.object));
        }
    }

    if (obj.get("drift")) |drift_val| {
        if (drift_val != .object) return error.InvalidResponse;
        status.drift_count = @intCast(try getOptionalU64(drift_val.object, "count", 0));
        if (drift_val.object.get("items")) |items_val| {
            if (items_val != .array) return error.InvalidResponse;
            for (items_val.array.items) |item| {
                if (item != .object) return error.InvalidResponse;
                try status.drift_items.append(allocator, try parseDriftItem(allocator, item.object));
            }
        }
    }
    if (obj.get("availability")) |availability_val| {
        if (availability_val != .object) return error.InvalidResponse;
        status.availability_mounts_total = @intCast(try getOptionalU64(availability_val.object, "mounts_total", 0));
        status.availability_online = @intCast(try getOptionalU64(availability_val.object, "online", 0));
        status.availability_degraded = @intCast(try getOptionalU64(availability_val.object, "degraded", 0));
        status.availability_missing = @intCast(try getOptionalU64(availability_val.object, "missing", 0));
    }

    status.reconcile_state = try dupOptionalNullableString(allocator, obj, "reconcile_state");
    status.last_reconcile_ms = try getOptionalI64(obj, "last_reconcile_ms", 0);
    status.last_success_ms = try getOptionalI64(obj, "last_success_ms", 0);
    status.last_error = try dupOptionalNullableString(allocator, obj, "last_error");
    status.queue_depth = @intCast(try getOptionalU64(obj, "queue_depth", 0));

    return status;
}

fn parseSessionAttachStatus(
    allocator: std.mem.Allocator,
    obj: std.json.ObjectMap,
) !workspace_types.SessionAttachStatus {
    var status = workspace_types.SessionAttachStatus{
        .session_key = try dupRequiredString(allocator, obj, "session_key"),
        .agent_id = try dupRequiredString(allocator, obj, "agent_id"),
        .project_id = try dupOptionalNullableString(allocator, obj, "project_id"),
        .state = try allocator.dupe(u8, ""),
        .runtime_ready = false,
        .mount_ready = false,
        .error_code = null,
        .error_message = null,
        .updated_at_ms = 0,
    };
    errdefer status.deinit(allocator);

    const attach_val = obj.get("attach") orelse return error.InvalidResponse;
    if (attach_val != .object) return error.InvalidResponse;
    const attach_state = try dupRequiredString(allocator, attach_val.object, "state");
    allocator.free(status.state);
    status.state = attach_state;
    status.runtime_ready = try getOptionalBool(attach_val.object, "runtime_ready", false);
    status.mount_ready = try getOptionalBool(attach_val.object, "mount_ready", false);
    status.error_code = try dupOptionalNullableString(allocator, attach_val.object, "error_code");
    status.error_message = try dupOptionalNullableString(allocator, attach_val.object, "error_message");
    status.updated_at_ms = try getOptionalI64(attach_val.object, "updated_at_ms", 0);
    return status;
}

fn parseSessionSummary(
    allocator: std.mem.Allocator,
    obj: std.json.ObjectMap,
) !workspace_types.SessionSummary {
    return .{
        .session_key = try dupRequiredString(allocator, obj, "session_key"),
        .agent_id = try dupRequiredString(allocator, obj, "agent_id"),
        .project_id = try dupOptionalNullableString(allocator, obj, "project_id"),
        .last_active_ms = try getOptionalI64(obj, "last_active_ms", 0),
        .message_count = try getOptionalU64(obj, "message_count", 0),
        .summary = try dupOptionalNullableString(allocator, obj, "summary"),
    };
}

fn parseSessionList(
    allocator: std.mem.Allocator,
    obj: std.json.ObjectMap,
) !workspace_types.SessionList {
    var list = workspace_types.SessionList{
        .active_session = try dupRequiredString(allocator, obj, "active_session"),
    };
    errdefer list.deinit(allocator);

    const sessions_val = obj.get("sessions") orelse return error.InvalidResponse;
    if (sessions_val != .array) return error.InvalidResponse;
    for (sessions_val.array.items) |item| {
        if (item != .object) return error.InvalidResponse;
        try list.sessions.append(allocator, try parseSessionSummary(allocator, item.object));
    }
    return list;
}

fn parseSessionCloseResult(
    allocator: std.mem.Allocator,
    obj: std.json.ObjectMap,
) !workspace_types.SessionCloseResult {
    return .{
        .session_key = try dupRequiredString(allocator, obj, "session_key"),
        .closed = try getOptionalBool(obj, "closed", false),
        .active_session = try dupRequiredString(allocator, obj, "active_session"),
    };
}

fn parseSessionRestoreResult(
    allocator: std.mem.Allocator,
    obj: std.json.ObjectMap,
) !workspace_types.SessionRestoreResult {
    var result = workspace_types.SessionRestoreResult{
        .found = try getOptionalBool(obj, "found", false),
        .session = null,
    };
    errdefer result.deinit(allocator);
    if (!result.found) return result;

    const session_val = obj.get("session") orelse return error.InvalidResponse;
    if (session_val != .object) return error.InvalidResponse;
    result.session = try parseSessionSummary(allocator, session_val.object);
    return result;
}

fn parseSessionHistory(
    allocator: std.mem.Allocator,
    obj: std.json.ObjectMap,
) !std.ArrayListUnmanaged(workspace_types.SessionSummary) {
    const sessions_val = obj.get("sessions") orelse return error.InvalidResponse;
    if (sessions_val != .array) return error.InvalidResponse;

    var sessions = std.ArrayListUnmanaged(workspace_types.SessionSummary){};
    errdefer {
        for (sessions.items) |*entry| entry.deinit(allocator);
        sessions.deinit(allocator);
    }
    for (sessions_val.array.items) |item| {
        if (item != .object) return error.InvalidResponse;
        try sessions.append(allocator, try parseSessionSummary(allocator, item.object));
    }
    return sessions;
}

fn parseReconcileStatus(
    allocator: std.mem.Allocator,
    obj: std.json.ObjectMap,
) !workspace_types.ReconcileStatus {
    var status = workspace_types.ReconcileStatus{
        .reconcile_state = try dupOptionalNullableString(allocator, obj, "reconcile_state"),
        .last_reconcile_ms = try getOptionalI64(obj, "last_reconcile_ms", 0),
        .last_success_ms = try getOptionalI64(obj, "last_success_ms", 0),
        .last_error = try dupOptionalNullableString(allocator, obj, "last_error"),
        .queue_depth = @intCast(try getOptionalU64(obj, "queue_depth", 0)),
        .failed_ops_total = try getOptionalU64(obj, "failed_ops_total", 0),
        .cycles_total = try getOptionalU64(obj, "cycles_total", 0),
    };
    errdefer status.deinit(allocator);

    if (obj.get("failed_ops")) |failed_val| {
        if (failed_val != .array) return error.InvalidResponse;
        for (failed_val.array.items) |item| {
            if (item != .string) return error.InvalidResponse;
            try status.failed_ops.append(allocator, try allocator.dupe(u8, item.string));
        }
    }

    if (obj.get("projects")) |projects_val| {
        if (projects_val != .array) return error.InvalidResponse;
        for (projects_val.array.items) |item| {
            if (item != .object) return error.InvalidResponse;
            const project_id = try dupRequiredStringAny(allocator, item.object, &.{ "project_id", "id" });
            errdefer allocator.free(project_id);
            try status.projects.append(allocator, .{
                .project_id = project_id,
                .mounts = @intCast(try getOptionalU64(item.object, "mounts", 0)),
                .drift_count = @intCast(try getOptionalU64(item.object, "drift_count", 0)),
                .queue_depth = @intCast(try getOptionalU64(item.object, "queue_depth", 0)),
            });
        }
    }
    return status;
}

fn parseMount(allocator: std.mem.Allocator, obj: std.json.ObjectMap) !workspace_types.MountView {
    return .{
        .mount_path = try dupRequiredString(allocator, obj, "mount_path"),
        .node_id = try dupRequiredString(allocator, obj, "node_id"),
        .node_name = try dupOptionalNullableString(allocator, obj, "node_name"),
        .fs_url = try dupOptionalNullableString(allocator, obj, "fs_url"),
        .export_name = try dupRequiredString(allocator, obj, "export_name"),
    };
}

fn parseDriftItem(allocator: std.mem.Allocator, obj: std.json.ObjectMap) !workspace_types.DriftItem {
    return .{
        .mount_path = try dupOptionalNullableString(allocator, obj, "mount_path"),
        .kind = try dupOptionalNullableString(allocator, obj, "kind"),
        .severity = try dupOptionalNullableString(allocator, obj, "severity"),
        .selected_node_id = try dupOptionalNullableString(allocator, obj, "selected_node_id"),
        .desired_node_id = try dupOptionalNullableString(allocator, obj, "desired_node_id"),
        .message = try dupOptionalNullableString(allocator, obj, "message"),
    };
}

fn dupRequiredString(
    allocator: std.mem.Allocator,
    obj: std.json.ObjectMap,
    name: []const u8,
) ![]u8 {
    const value = obj.get(name) orelse return error.InvalidResponse;
    if (value != .string) return error.InvalidResponse;
    return allocator.dupe(u8, value.string);
}

fn dupRequiredStringAny(
    allocator: std.mem.Allocator,
    obj: std.json.ObjectMap,
    names: []const []const u8,
) ![]u8 {
    for (names) |name| {
        const value = obj.get(name) orelse continue;
        if (value != .string) return error.InvalidResponse;
        return allocator.dupe(u8, value.string);
    }
    return error.InvalidResponse;
}

fn dupOptionalString(
    allocator: std.mem.Allocator,
    obj: std.json.ObjectMap,
    name: []const u8,
) !?[]u8 {
    const value = obj.get(name) orelse return null;
    if (value != .string) return error.InvalidResponse;
    const copied = try allocator.dupe(u8, value.string);
    return @as(?[]u8, copied);
}

fn dupOptionalNullableString(
    allocator: std.mem.Allocator,
    obj: std.json.ObjectMap,
    name: []const u8,
) !?[]u8 {
    const value = obj.get(name) orelse return null;
    if (value == .null) return null;
    if (value != .string) return error.InvalidResponse;
    const copied = try allocator.dupe(u8, value.string);
    return @as(?[]u8, copied);
}

fn getOptionalU64(obj: std.json.ObjectMap, name: []const u8, default_value: u64) !u64 {
    const value = obj.get(name) orelse return default_value;
    if (value != .integer or value.integer < 0) return error.InvalidResponse;
    return @intCast(value.integer);
}

fn getOptionalBool(obj: std.json.ObjectMap, name: []const u8, default_value: bool) !bool {
    const value = obj.get(name) orelse return default_value;
    if (value != .bool) return error.InvalidResponse;
    return value.bool;
}

fn getOptionalI64(obj: std.json.ObjectMap, name: []const u8, default_value: i64) !i64 {
    const value = obj.get(name) orelse return default_value;
    if (value != .integer) return error.InvalidResponse;
    return value.integer;
}

test "normalizeProjectToken trims empty and preserves non-empty tokens" {
    try std.testing.expect(normalizeProjectToken(null) == null);
    try std.testing.expect(normalizeProjectToken("   \t\r\n") == null);
    try std.testing.expectEqualStrings("proj-secret", normalizeProjectToken("  proj-secret  ").?);
    const long_token =
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";
    try std.testing.expectEqualStrings(long_token, normalizeProjectToken(long_token).?);
}

test "parseProjectSummary accepts project_id key" {
    const allocator = std.testing.allocator;
    const json =
        \\{
        \\  "project_id":"proj-1",
        \\  "name":"Demo",
        \\  "status":"active",
        \\  "token_locked":true,
        \\  "mount_count":2
        \\}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .object);

    var summary = try parseProjectSummary(allocator, parsed.value.object);
    defer summary.deinit(allocator);

    try std.testing.expectEqualStrings("proj-1", summary.id);
    try std.testing.expectEqualStrings("Demo", summary.name);
    try std.testing.expectEqualStrings("active", summary.status);
    try std.testing.expectEqual(true, summary.token_locked);
    try std.testing.expectEqual(@as(usize, 2), summary.mount_count);
}

test "parseProjectDetail accepts project_id key" {
    const allocator = std.testing.allocator;
    const json =
        \\{
        \\  "project_id":"proj-7",
        \\  "name":"Topology",
        \\  "vision":"dist fs",
        \\  "status":"active",
        \\  "token_locked":true,
        \\  "project_token":"proj-secret",
        \\  "mounts":[{"mount_path":"/src","node_id":"node-1","export_name":"work"}]
        \\}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .object);

    var detail = try parseProjectDetail(allocator, parsed.value.object);
    defer detail.deinit(allocator);

    try std.testing.expectEqualStrings("proj-7", detail.id);
    try std.testing.expectEqualStrings("Topology", detail.name);
    try std.testing.expectEqualStrings("dist fs", detail.vision);
    try std.testing.expectEqual(true, detail.token_locked);
    try std.testing.expectEqual(@as(usize, 1), detail.mounts.items.len);
}

test "parseProjectTokenMutation accepts nullable token" {
    const allocator = std.testing.allocator;
    const json =
        \\{
        \\  "project_id":"proj-9",
        \\  "project_token":null,
        \\  "revoked":true,
        \\  "updated_at_ms":1234
        \\}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .object);

    var mutation = try parseProjectTokenMutation(allocator, parsed.value.object);
    defer mutation.deinit(allocator);

    try std.testing.expectEqualStrings("proj-9", mutation.project_id);
    try std.testing.expect(mutation.project_token == null);
    try std.testing.expectEqual(true, mutation.revoked);
    try std.testing.expectEqual(@as(i64, 1234), mutation.updated_at_ms);
}

test "parseAgentInfo reads capabilities and flags" {
    const allocator = std.testing.allocator;
    const json =
        \\{
        \\  "id":"mother",
        \\  "name":"Mother",
        \\  "description":"Primary orchestrator",
        \\  "is_default":true,
        \\  "identity_loaded":true,
        \\  "needs_hatching":false,
        \\  "capabilities":["chat","plan"]
        \\}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .object);

    var info = try parseAgentInfo(allocator, parsed.value.object);
    defer info.deinit(allocator);

    try std.testing.expectEqualStrings("mother", info.id);
    try std.testing.expectEqualStrings("Mother", info.name);
    try std.testing.expect(info.is_default);
    try std.testing.expect(info.identity_loaded);
    try std.testing.expect(!info.needs_hatching);
    try std.testing.expectEqual(@as(usize, 2), info.capabilities.items.len);
    try std.testing.expectEqualStrings("chat", info.capabilities.items[0]);
    try std.testing.expectEqualStrings("plan", info.capabilities.items[1]);
}

test "parseSessionList reads active session and entries" {
    const allocator = std.testing.allocator;
    const json =
        \\{
        \\  "active_session":"main",
        \\  "sessions":[
        \\    {"session_key":"main","agent_id":"mother","project_id":"system"},
        \\    {"session_key":"work","agent_id":"bob","project_id":null}
        \\  ]
        \\}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .object);

    var list = try parseSessionList(allocator, parsed.value.object);
    defer list.deinit(allocator);

    try std.testing.expectEqualStrings("main", list.active_session);
    try std.testing.expectEqual(@as(usize, 2), list.sessions.items.len);
    try std.testing.expectEqualStrings("work", list.sessions.items[1].session_key);
    try std.testing.expectEqualStrings("bob", list.sessions.items[1].agent_id);
    try std.testing.expect(list.sessions.items[1].project_id == null);
}

test "parseSessionCloseResult reads close response" {
    const allocator = std.testing.allocator;
    const json =
        \\{
        \\  "session_key":"work",
        \\  "closed":true,
        \\  "active_session":"main"
        \\}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .object);

    var result = try parseSessionCloseResult(allocator, parsed.value.object);
    defer result.deinit(allocator);

    try std.testing.expectEqualStrings("work", result.session_key);
    try std.testing.expect(result.closed);
    try std.testing.expectEqualStrings("main", result.active_session);
}

test "parseSessionRestoreResult reads found session payload" {
    const allocator = std.testing.allocator;
    const json =
        \\{
        \\  "found":true,
        \\  "session":{
        \\    "session_key":"work-1",
        \\    "agent_id":"mother",
        \\    "project_id":"system",
        \\    "last_active_ms":1234,
        \\    "message_count":7,
        \\    "summary":"API design"
        \\  }
        \\}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .object);

    var result = try parseSessionRestoreResult(allocator, parsed.value.object);
    defer result.deinit(allocator);

    try std.testing.expect(result.found);
    try std.testing.expect(result.session != null);
    try std.testing.expectEqualStrings("work-1", result.session.?.session_key);
    try std.testing.expectEqual(@as(i64, 1234), result.session.?.last_active_ms);
    try std.testing.expectEqual(@as(u64, 7), result.session.?.message_count);
}

test "parseSessionHistory reads entry list" {
    const allocator = std.testing.allocator;
    const json =
        \\{
        \\  "sessions":[
        \\    {"session_key":"a","agent_id":"mother","project_id":"system","last_active_ms":10,"message_count":1},
        \\    {"session_key":"b","agent_id":"bob","project_id":"proj-2","last_active_ms":9,"message_count":0,"summary":"todo"}
        \\  ]
        \\}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .object);

    var sessions = try parseSessionHistory(allocator, parsed.value.object);
    defer {
        for (sessions.items) |*entry| entry.deinit(allocator);
        sessions.deinit(allocator);
    }

    try std.testing.expectEqual(@as(usize, 2), sessions.items.len);
    try std.testing.expectEqualStrings("a", sessions.items[0].session_key);
    try std.testing.expectEqual(@as(u64, 1), sessions.items[0].message_count);
    try std.testing.expectEqualStrings("todo", sessions.items[1].summary.?);
}
