const std = @import("std");
const control_plane = @import("control_plane");

pub const WasmChatOwnedConfig = struct {
    module_path: []u8,
    entrypoint: ?[]u8 = null,
    timeout_ms: u64 = 30_000,
    fuel: ?u64 = null,
    max_memory_bytes: ?u64 = null,
    max_output_bytes: usize = 256 * 1024,

    pub fn deinit(self: *WasmChatOwnedConfig, allocator: std.mem.Allocator) void {
        allocator.free(self.module_path);
        if (self.entrypoint) |value| allocator.free(value);
        self.* = undefined;
    }
};

pub fn buildAppLocalNodeName(allocator: std.mem.Allocator, profile_id: []const u8) ![]u8 {
    var out = std.ArrayListUnmanaged(u8){};
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "spiderapp-");

    const trimmed = std.mem.trim(u8, profile_id, " \t\r\n");
    const source = if (trimmed.len > 0) trimmed else "default";
    for (source) |char| {
        if (std.ascii.isAlphanumeric(char) or char == '-' or char == '_' or char == '.') {
            try out.append(allocator, std.ascii.toLower(char));
        } else {
            try out.append(allocator, '-');
        }
    }
    return out.toOwnedSlice(allocator);
}

pub const AppVenomHost = struct {
    pub const InitOptions = struct {
        chat_wasm_backend: ?WasmChatOwnedConfig = null,
    };

    allocator: std.mem.Allocator,
    control_url: []u8,
    auth_token: []u8,
    node_name: []u8,
    node_id: []u8,
    node_secret: []u8,

    pub fn init(
        allocator: std.mem.Allocator,
        control_url: []const u8,
        auth_token: []const u8,
        identity: control_plane.EnsuredNodeIdentity,
    ) !AppVenomHost {
        return initWithOptions(allocator, control_url, auth_token, identity, .{});
    }

    pub fn initWithOptions(
        allocator: std.mem.Allocator,
        control_url: []const u8,
        auth_token: []const u8,
        identity: control_plane.EnsuredNodeIdentity,
        options: InitOptions,
    ) !AppVenomHost {
        _ = options;
        const out = AppVenomHost{
            .allocator = allocator,
            .control_url = try allocator.dupe(u8, control_url),
            .auth_token = try allocator.dupe(u8, auth_token),
            .node_name = try allocator.dupe(u8, identity.node_name),
            .node_id = try allocator.dupe(u8, identity.node_id),
            .node_secret = try allocator.dupe(u8, identity.node_secret),
        };
        errdefer {
            allocator.free(out.control_url);
            allocator.free(out.auth_token);
            allocator.free(out.node_name);
            allocator.free(out.node_id);
            allocator.free(out.node_secret);
        }
        return out;
    }

    pub fn deinit(self: *AppVenomHost) void {
        self.allocator.free(self.control_url);
        self.allocator.free(self.auth_token);
        self.allocator.free(self.node_name);
        self.allocator.free(self.node_id);
        self.allocator.free(self.node_secret);
        self.* = undefined;
    }

    pub fn matches(
        self: *const AppVenomHost,
        control_url: []const u8,
        auth_token: []const u8,
        identity: control_plane.EnsuredNodeIdentity,
    ) bool {
        return std.mem.eql(u8, self.control_url, control_url) and
            std.mem.eql(u8, self.auth_token, auth_token) and
            std.mem.eql(u8, self.node_name, identity.node_name) and
            std.mem.eql(u8, self.node_id, identity.node_id) and
            std.mem.eql(u8, self.node_secret, identity.node_secret);
    }

    pub fn bindSelf(self: *AppVenomHost) void {
        _ = self;
    }

    pub fn bootstrap(
        self: *AppVenomHost,
        client: anytype,
        message_counter: *u64,
        lease_ttl_ms: u64,
    ) !void {
        _ = self;
        _ = client;
        _ = message_counter;
        _ = lease_ttl_ms;
        return error.UnsupportedPlatform;
    }
};

pub fn loadChatWasmBackendFromEnv(allocator: std.mem.Allocator) !?WasmChatOwnedConfig {
    const module_path = std.process.getEnvVarOwned(allocator, "SPIDERAPP_CHAT_WASM_MODULE") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => return null,
        else => return err,
    };
    errdefer allocator.free(module_path);

    const entrypoint = std.process.getEnvVarOwned(allocator, "SPIDERAPP_CHAT_WASM_ENTRYPOINT") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => null,
        else => return err,
    };
    errdefer if (entrypoint) |value| allocator.free(value);

    const max_output_bytes = blk: {
        const raw = std.process.getEnvVarOwned(allocator, "SPIDERAPP_CHAT_WASM_MAX_OUTPUT") catch |err| switch (err) {
            error.EnvironmentVariableNotFound => break :blk 256 * 1024,
            else => return err,
        };
        defer allocator.free(raw);
        break :blk try std.fmt.parseInt(usize, raw, 10);
    };
    const timeout_ms = blk: {
        const raw = std.process.getEnvVarOwned(allocator, "SPIDERAPP_CHAT_WASM_TIMEOUT_MS") catch |err| switch (err) {
            error.EnvironmentVariableNotFound => break :blk @as(u64, 30_000),
            else => return err,
        };
        defer allocator.free(raw);
        break :blk try std.fmt.parseInt(u64, raw, 10);
    };
    const fuel = blk: {
        const raw = std.process.getEnvVarOwned(allocator, "SPIDERAPP_CHAT_WASM_FUEL") catch |err| switch (err) {
            error.EnvironmentVariableNotFound => break :blk null,
            else => return err,
        };
        defer allocator.free(raw);
        break :blk @as(?u64, try std.fmt.parseInt(u64, raw, 10));
    };
    const max_memory_bytes = blk: {
        const raw = std.process.getEnvVarOwned(allocator, "SPIDERAPP_CHAT_WASM_MAX_MEMORY_BYTES") catch |err| switch (err) {
            error.EnvironmentVariableNotFound => break :blk null,
            else => return err,
        };
        defer allocator.free(raw);
        break :blk @as(?u64, try std.fmt.parseInt(u64, raw, 10));
    };

    return .{
        .module_path = module_path,
        .entrypoint = entrypoint,
        .timeout_ms = timeout_ms,
        .fuel = fuel,
        .max_memory_bytes = max_memory_bytes,
        .max_output_bytes = max_output_bytes,
    };
}
