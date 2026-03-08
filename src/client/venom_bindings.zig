const std = @import("std");

pub const BindingScope = struct {
    agent_id: ?[]const u8 = null,
    project_id: ?[]const u8 = null,
};

pub const VenomBinding = struct {
    venom_path: []u8,
    endpoint_path: ?[]u8 = null,
    invoke_path: ?[]u8 = null,
    provider_node_id: ?[]u8 = null,
    provider_venom_path: ?[]u8 = null,

    pub fn deinit(self: *VenomBinding, allocator: std.mem.Allocator) void {
        allocator.free(self.venom_path);
        if (self.endpoint_path) |value| allocator.free(value);
        if (self.invoke_path) |value| allocator.free(value);
        if (self.provider_node_id) |value| allocator.free(value);
        if (self.provider_venom_path) |value| allocator.free(value);
        self.* = undefined;
    }
};

pub const ChatBindingPaths = struct {
    chat_root: []u8,
    input_path: []u8,
    jobs_root: []u8,
    thoughts_root: []u8,
    status_leaf: []u8,
    result_leaf: []u8,

    pub fn deinit(self: *ChatBindingPaths, allocator: std.mem.Allocator) void {
        allocator.free(self.chat_root);
        allocator.free(self.input_path);
        allocator.free(self.jobs_root);
        allocator.free(self.thoughts_root);
        allocator.free(self.status_leaf);
        allocator.free(self.result_leaf);
        self.* = undefined;
    }
};

pub fn readPreferredVenomBinding(
    allocator: std.mem.Allocator,
    reader: anytype,
    scope: BindingScope,
    venom_id: []const u8,
) !VenomBinding {
    if (scope.agent_id) |agent_id| {
        const index_path = try std.fmt.allocPrint(allocator, "/agents/{s}/venoms/VENOMS.json", .{agent_id});
        defer allocator.free(index_path);
        const preferred_prefix = try std.fmt.allocPrint(allocator, "/agents/{s}/venoms/", .{agent_id});
        defer allocator.free(preferred_prefix);
        if (readVenomBindingFromIndexPath(allocator, reader, index_path, preferred_prefix, venom_id)) |binding| {
            return binding;
        } else |err| switch (err) {
            error.FileNotFound, error.InvalidResponse, error.ServiceNotFound => {},
            else => return err,
        }
    }

    if (scope.project_id) |project_id| {
        const index_path = try std.fmt.allocPrint(allocator, "/projects/{s}/venoms/VENOMS.json", .{project_id});
        defer allocator.free(index_path);
        const preferred_prefix = try std.fmt.allocPrint(allocator, "/projects/{s}/venoms/", .{project_id});
        defer allocator.free(preferred_prefix);
        if (readVenomBindingFromIndexPath(allocator, reader, index_path, preferred_prefix, venom_id)) |binding| {
            return binding;
        } else |err| switch (err) {
            error.FileNotFound, error.InvalidResponse, error.ServiceNotFound => {},
            else => return err,
        }
    }

    return readVenomBindingFromIndexPath(allocator, reader, "/global/venoms/VENOMS.json", "/global/", venom_id);
}

pub fn discoverChatBindingPaths(
    allocator: std.mem.Allocator,
    reader: anytype,
    scope: BindingScope,
) !ChatBindingPaths {
    var binding = readPreferredVenomBinding(allocator, reader, scope, "chat") catch VenomBinding{
        .venom_path = try allocator.dupe(u8, "/global/chat"),
    };
    defer binding.deinit(allocator);
    var jobs_binding = readPreferredVenomBinding(allocator, reader, scope, "jobs") catch null;
    defer if (jobs_binding) |*value| value.deinit(allocator);
    var thoughts_binding = readPreferredVenomBinding(allocator, reader, scope, "thoughts") catch null;
    defer if (thoughts_binding) |*value| value.deinit(allocator);
    const ops_base_path = binding.provider_venom_path orelse binding.venom_path;

    const invoke_target = if (binding.invoke_path) |value|
        try allocator.dupe(u8, value)
    else blk: {
        const discovered = try readVenomOpsPathValue(allocator, reader, ops_base_path, "invoke") orelse
            try allocator.dupe(u8, "control/input");
        break :blk discovered;
    };
    errdefer allocator.free(invoke_target);

    const input_path = if (invoke_target.len > 0 and invoke_target[0] == '/')
        invoke_target
    else
        try joinFsPath(allocator, binding.venom_path, invoke_target);
    errdefer allocator.free(input_path);
    if (input_path.ptr != invoke_target.ptr) allocator.free(invoke_target);

    const jobs_root = blk: {
        if (jobs_binding) |value| break :blk try allocator.dupe(u8, value.venom_path);
        const discovered = try readVenomOpsPathValue(allocator, reader, ops_base_path, "jobs_root");
        if (discovered) |value| break :blk value;
        if (try deriveSiblingVenomPath(allocator, binding.venom_path, "jobs")) |value| break :blk value;
        break :blk try allocator.dupe(u8, "/global/jobs");
    };
    errdefer allocator.free(jobs_root);

    const thoughts_root = blk: {
        if (thoughts_binding) |value| break :blk try allocator.dupe(u8, value.venom_path);
        const discovered = try readVenomOpsPathValue(allocator, reader, ops_base_path, "thoughts_root");
        if (discovered) |value| break :blk value;
        if (try deriveSiblingVenomPath(allocator, binding.venom_path, "thoughts")) |value| break :blk value;
        break :blk try allocator.dupe(u8, "/global/thoughts");
    };
    errdefer allocator.free(thoughts_root);

    const status_leaf = blk: {
        const discovered = try readVenomOpsPathValue(allocator, reader, ops_base_path, "status_leaf");
        if (discovered) |value| break :blk value;
        break :blk try allocator.dupe(u8, "status.json");
    };
    errdefer allocator.free(status_leaf);

    const result_leaf = blk: {
        const discovered = try readVenomOpsPathValue(allocator, reader, ops_base_path, "result_leaf");
        if (discovered) |value| break :blk value;
        break :blk try allocator.dupe(u8, "result.txt");
    };
    errdefer allocator.free(result_leaf);

    return .{
        .chat_root = try allocator.dupe(u8, ops_base_path),
        .input_path = input_path,
        .jobs_root = jobs_root,
        .thoughts_root = thoughts_root,
        .status_leaf = status_leaf,
        .result_leaf = result_leaf,
    };
}

fn readVenomBindingFromIndexPath(
    allocator: std.mem.Allocator,
    reader: anytype,
    index_path: []const u8,
    preferred_prefix: []const u8,
    venom_id: []const u8,
) !VenomBinding {
    const payload = try reader.readText(index_path);
    defer allocator.free(payload);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload, .{});
    defer parsed.deinit();
    if (parsed.value != .array) return error.InvalidResponse;

    var fallback_path: ?[]const u8 = null;
    var fallback_invoke: ?[]const u8 = null;

    for (parsed.value.array.items) |entry| {
        if (entry != .object) continue;
        const obj = entry.object;
        if (!std.mem.eql(u8, jsonObjectStringOr(obj, "venom_id", ""), venom_id)) continue;
        const venom_path = jsonObjectStringOr(obj, "venom_path", "");
        if (venom_path.len == 0 or venom_path[0] != '/') continue;
        const invoke_path_raw = jsonObjectStringOr(obj, "invoke_path", "");
        const invoke_path = if (invoke_path_raw.len > 0 and invoke_path_raw[0] == '/') invoke_path_raw else null;
        if (std.mem.startsWith(u8, venom_path, preferred_prefix)) {
            return .{
                .venom_path = try allocator.dupe(u8, venom_path),
                .endpoint_path = if (jsonObjectStringOr(obj, "endpoint_path", "").len > 0)
                    try allocator.dupe(u8, jsonObjectStringOr(obj, "endpoint_path", ""))
                else
                    null,
                .invoke_path = if (invoke_path) |value| try allocator.dupe(u8, value) else null,
                .provider_node_id = if (jsonObjectStringOr(obj, "provider_node_id", "").len > 0)
                    try allocator.dupe(u8, jsonObjectStringOr(obj, "provider_node_id", ""))
                else
                    null,
                .provider_venom_path = if (jsonObjectStringOr(obj, "provider_venom_path", "").len > 0)
                    try allocator.dupe(u8, jsonObjectStringOr(obj, "provider_venom_path", ""))
                else
                    null,
            };
        }
        if (fallback_path == null) {
            fallback_path = venom_path;
            fallback_invoke = invoke_path;
        }
    }

    if (fallback_path) |value| {
        return .{
            .venom_path = try allocator.dupe(u8, value),
            .invoke_path = if (fallback_invoke) |invoke| try allocator.dupe(u8, invoke) else null,
        };
    }
    return error.ServiceNotFound;
}

fn readVenomOpsPathValue(
    allocator: std.mem.Allocator,
    reader: anytype,
    venom_path: []const u8,
    key: []const u8,
) !?[]u8 {
    const ops_path = try joinFsPath(allocator, venom_path, "OPS.json");
    defer allocator.free(ops_path);
    const payload = reader.readText(ops_path) catch return null;
    defer allocator.free(payload);

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, payload, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;

    if (std.mem.eql(u8, key, "invoke")) {
        if (parsed.value.object.get("invoke")) |value| {
            if (value == .string and value.string.len > 0) return try allocator.dupe(u8, value.string);
        }
    }

    const paths_val = parsed.value.object.get("paths") orelse return null;
    if (paths_val != .object) return null;
    const value = paths_val.object.get(key) orelse return null;
    if (value != .string or value.string.len == 0) return null;
    return try allocator.dupe(u8, value.string);
}

fn deriveSiblingVenomPath(allocator: std.mem.Allocator, venom_path: []const u8, sibling_venom_id: []const u8) !?[]u8 {
    const slash_index = std.mem.lastIndexOfScalar(u8, venom_path, '/') orelse return null;
    if (slash_index == 0) return null;
    return try std.fmt.allocPrint(allocator, "{s}/{s}", .{ venom_path[0..slash_index], sibling_venom_id });
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

fn jsonObjectStringOr(obj: std.json.ObjectMap, name: []const u8, fallback: []const u8) []const u8 {
    const value = obj.get(name) orelse return fallback;
    if (value != .string) return fallback;
    return value.string;
}
