// venom_types.zig — View-model types for MCP management and workspace wizard.
//
// These are pure data structures (only std dependency) so they can be
// tested and used outside of the GUI rendering context.
//
// Note: VenomEntry is NOT here because it contains a VenomScope field whose
// color() method depends on zui.theme.colors — it stays in root.zig.

const std = @import("std");

// ── MCP catalog entry ─────────────────────────────────────────────────────────

pub const McpEntry = struct {
    node_id: []u8,
    venom_id: []u8,
    state: []u8,
    endpoint: []u8,

    pub fn deinit(self: *McpEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.node_id);
        allocator.free(self.venom_id);
        allocator.free(self.state);
        allocator.free(self.endpoint);
        self.* = undefined;
    }
};

// ── Workspace wizard types ────────────────────────────────────────────────────

pub const WizardMount = struct {
    path: []u8,
    node_id: []u8,

    pub fn deinit(self: *WizardMount, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.node_id);
        self.* = undefined;
    }
};

pub const WizardBind = struct {
    bind_path: []u8,
    target_path: []u8,

    pub fn deinit(self: *WizardBind, allocator: std.mem.Allocator) void {
        allocator.free(self.bind_path);
        allocator.free(self.target_path);
        self.* = undefined;
    }
};

// ── Tests ─────────────────────────────────────────────────────────────────────

test "McpEntry deinit frees all memory" {
    const allocator = std.testing.allocator;
    var entry = McpEntry{
        .node_id = try allocator.dupe(u8, "node-mcp-1"),
        .venom_id = try allocator.dupe(u8, "mcp-claude"),
        .state = try allocator.dupe(u8, "running"),
        .endpoint = try allocator.dupe(u8, "ws://localhost:9999"),
    };
    entry.deinit(allocator);
}

test "WizardMount deinit frees all memory" {
    const allocator = std.testing.allocator;
    var mount = WizardMount{
        .path = try allocator.dupe(u8, "/workspace/src"),
        .node_id = try allocator.dupe(u8, "node-dev"),
    };
    mount.deinit(allocator);
}

test "WizardBind deinit frees all memory" {
    const allocator = std.testing.allocator;
    var bind = WizardBind{
        .bind_path = try allocator.dupe(u8, "/agent/tools"),
        .target_path = try allocator.dupe(u8, "/workspace/tools"),
    };
    bind.deinit(allocator);
}

test "McpEntry list: multiple entries deinit cleanly" {
    const allocator = std.testing.allocator;
    var list = std.ArrayListUnmanaged(McpEntry){};
    defer list.deinit(allocator);

    try list.append(allocator, .{
        .node_id = try allocator.dupe(u8, "node-a"),
        .venom_id = try allocator.dupe(u8, "mcp-a"),
        .state = try allocator.dupe(u8, "running"),
        .endpoint = try allocator.dupe(u8, "ws://a:9000"),
    });
    try list.append(allocator, .{
        .node_id = try allocator.dupe(u8, "node-b"),
        .venom_id = try allocator.dupe(u8, "mcp-b"),
        .state = try allocator.dupe(u8, "stopped"),
        .endpoint = try allocator.dupe(u8, "ws://b:9001"),
    });

    for (list.items) |*item| item.deinit(allocator);
}

test "WizardMount list: multiple entries deinit cleanly" {
    const allocator = std.testing.allocator;
    var mounts = std.ArrayListUnmanaged(WizardMount){};
    defer mounts.deinit(allocator);

    try mounts.append(allocator, .{
        .path = try allocator.dupe(u8, "/proj/src"),
        .node_id = try allocator.dupe(u8, "node-1"),
    });
    try mounts.append(allocator, .{
        .path = try allocator.dupe(u8, "/proj/docs"),
        .node_id = try allocator.dupe(u8, "node-2"),
    });

    for (mounts.items) |*item| item.deinit(allocator);
}

test "WizardBind list: multiple entries deinit cleanly" {
    const allocator = std.testing.allocator;
    var binds = std.ArrayListUnmanaged(WizardBind){};
    defer binds.deinit(allocator);

    try binds.append(allocator, .{
        .bind_path = try allocator.dupe(u8, "/agent/tools"),
        .target_path = try allocator.dupe(u8, "/ws/tools"),
    });

    for (binds.items) |*item| item.deinit(allocator);
}
