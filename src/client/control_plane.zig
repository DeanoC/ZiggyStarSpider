const std = @import("std");
const unified_v2 = @import("unified_v2_client.zig");
pub const workspace_types = @import("workspace_types.zig");

pub const default_timeout_ms: i64 = unified_v2.default_control_timeout_ms;

pub fn lastRemoteError() ?[]const u8 {
    return unified_v2.lastRemoteError();
}

pub fn ensureUnifiedV2Connection(
    allocator: std.mem.Allocator,
    client: anytype,
    message_counter: *u64,
) !void {
    try unified_v2.sendControlVersionAndConnect(allocator, client, message_counter, default_timeout_ms);
}

pub fn requestControlPayloadJson(
    allocator: std.mem.Allocator,
    client: anytype,
    message_counter: *u64,
    control_type: []const u8,
    payload_json: ?[]const u8,
) ![]u8 {
    const request_id = try unified_v2.nextRequestId(allocator, message_counter, "control");
    defer allocator.free(request_id);

    var response = try unified_v2.sendControlRequest(
        allocator,
        client,
        control_type,
        request_id,
        payload_json,
        default_timeout_ms,
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
    const escaped_project = try unified_v2.jsonEscape(allocator, project_id);
    defer allocator.free(escaped_project);
    const payload_req = if (project_token) |token| blk: {
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

pub fn workspaceStatus(
    allocator: std.mem.Allocator,
    client: anytype,
    message_counter: *u64,
    project_id: ?[]const u8,
    project_token: ?[]const u8,
) !workspace_types.WorkspaceStatus {
    var payload_req: ?[]u8 = null;
    defer if (payload_req) |value| allocator.free(value);

    if (project_id) |project| {
        const escaped_project = try unified_v2.jsonEscape(allocator, project);
        defer allocator.free(escaped_project);
        if (project_token) |token| {
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

    status.reconcile_state = try dupOptionalNullableString(allocator, obj, "reconcile_state");
    status.last_reconcile_ms = try getOptionalI64(obj, "last_reconcile_ms", 0);
    status.last_success_ms = try getOptionalI64(obj, "last_success_ms", 0);
    status.last_error = try dupOptionalNullableString(allocator, obj, "last_error");
    status.queue_depth = @intCast(try getOptionalU64(obj, "queue_depth", 0));

    return status;
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

test "parseProjectSummary accepts project_id key" {
    const allocator = std.testing.allocator;
    const json =
        \\{
        \\  "project_id":"proj-1",
        \\  "name":"Demo",
        \\  "status":"active",
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
    try std.testing.expectEqual(@as(usize, 1), detail.mounts.items.len);
}
