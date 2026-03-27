// Shared venom and service discovery helpers.
// Used by workspace, node, and chat commands.

const std = @import("std");
const logger = @import("ziggy-core").utils.logger;
const unified = @import("spider-protocol").unified;
const WebSocketClient = @import("../client/websocket.zig").WebSocketClient;
const control_plane = @import("control_plane");
const workspace_types = control_plane.workspace_types;
const venom_bindings = @import("../client/venom_bindings.zig");
const ctx = @import("client_context.zig");
const fsrpc = @import("fsrpc.zig");

// ── Type aliases ─────────────────────────────────────────────────────────────

pub const WorkspaceBindingScope = venom_bindings.WorkspaceBindingScope;
pub const ChatBindingPaths = venom_bindings.ChatBindingPaths;

pub const OwnedWorkspaceBindingScope = struct {
    agent_id: ?[]u8 = null,
    workspace_id: ?[]u8 = null,

    pub fn deinit(self: *OwnedWorkspaceBindingScope, allocator: std.mem.Allocator) void {
        if (self.agent_id) |value| allocator.free(value);
        if (self.workspace_id) |value| allocator.free(value);
        self.* = .{};
    }

    pub fn asBorrowed(self: OwnedWorkspaceBindingScope) WorkspaceBindingScope {
        return .{
            .agent_id = self.agent_id,
            .workspace_id = self.workspace_id,
        };
    }
};

pub const DefaultFsMount = struct {
    node_id: []u8,
    mount_path: []u8,

    pub fn deinit(self: *DefaultFsMount, allocator: std.mem.Allocator) void {
        allocator.free(self.node_id);
        allocator.free(self.mount_path);
        self.* = undefined;
    }
};

// ── JSON utilities (used by venom catalog parsing) ────────────────────────────

pub fn jsonObjectStringOr(obj: std.json.ObjectMap, name: []const u8, fallback: []const u8) []const u8 {
    const value = obj.get(name) orelse return fallback;
    if (value != .string) return fallback;
    return value.string;
}

pub fn jsonObjectI64Or(obj: std.json.ObjectMap, name: []const u8, fallback: i64) i64 {
    const value = obj.get(name) orelse return fallback;
    if (value != .integer) return fallback;
    return value.integer;
}

pub fn jsonObjectBoolOr(obj: std.json.ObjectMap, name: []const u8, fallback: bool) bool {
    const value = obj.get(name) orelse return fallback;
    if (value != .bool) return fallback;
    return value.bool;
}

pub fn jsonPlatformFieldOr(root: std.json.ObjectMap, name: []const u8, fallback: []const u8) []const u8 {
    const platform = root.get("platform") orelse return fallback;
    if (platform != .object) return fallback;
    return jsonObjectStringOr(platform.object, name, fallback);
}

// ── Chat path discovery ───────────────────────────────────────────────────────

pub fn discoverChatBindingPaths(
    allocator: std.mem.Allocator,
    client: *WebSocketClient,
    scope: WorkspaceBindingScope,
) !venom_bindings.ChatBindingPaths {
    return venom_bindings.discoverChatBindingPaths(
        allocator,
        fsrpc.CliFsPathReader{ .allocator = allocator, .client = client },
        .{ .agent_id = scope.agent_id, .workspace_id = scope.workspace_id },
    );
}

pub fn resolveAttachedWorkspaceBindingScope(
    allocator: std.mem.Allocator,
    client: *WebSocketClient,
) !OwnedWorkspaceBindingScope {
    var cfg = try ctx.loadCliConfig(allocator);
    defer cfg.deinit();

    var scope = OwnedWorkspaceBindingScope{};
    errdefer scope.deinit(allocator);

    const session_key = ctx.resolveSessionKey(&cfg);
    var status = control_plane.sessionStatusWithTimeout(
        allocator,
        client,
        &ctx.g_control_request_counter,
        session_key,
        ctx.session_status_timeout_ms,
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

pub fn buildJobLeafPath(
    allocator: std.mem.Allocator,
    jobs_root: []const u8,
    job_name: []const u8,
    leaf: []const u8,
) ![]u8 {
    const job_root = try fsrpc.joinFsPath(allocator, jobs_root, job_name);
    defer allocator.free(job_root);
    return fsrpc.joinFsPath(allocator, job_root, leaf);
}

pub fn readLatestThoughtText(
    allocator: std.mem.Allocator,
    client: *WebSocketClient,
    thoughts_root: []const u8,
) !?[]u8 {
    const latest_path = try fsrpc.joinFsPath(allocator, thoughts_root, "latest.txt");
    defer allocator.free(latest_path);
    const raw = fsrpc.fsrpcReadPathText(allocator, client, latest_path) catch return null;
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

// ── Venom catalog discovery ───────────────────────────────────────────────────

pub fn requestNodeVenomCatalogPayload(
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
        &ctx.g_control_request_counter,
        "control.venom_get",
        payload_req,
    );
}

pub fn findNodeVenomRuntimeRootPath(
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

pub fn discoverDefaultFsMount(
    allocator: std.mem.Allocator,
    client: *WebSocketClient,
    scope: WorkspaceBindingScope,
) !DefaultFsMount {
    var global_binding = venom_bindings.readPreferredVenomBinding(
        allocator,
        fsrpc.CliFsPathReader{ .allocator = allocator, .client = client },
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

    var nodes = try control_plane.listNodes(allocator, client, &ctx.g_control_request_counter);
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
