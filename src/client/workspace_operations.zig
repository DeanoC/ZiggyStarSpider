// workspace_operations.zig — Shared workspace setup logic used by both
// the CLI wizard and the GUI workspace setup wizard.
//
// Both surfaces collect a WorkspaceSetupPlan and call executeSetupPlan.
// This ensures consistent behaviour regardless of how the plan was gathered.

const std = @import("std");
const unified = @import("spider-protocol").unified;
const control_plane = @import("control_plane");

// ── Plan types ───────────────────────────────────────────────────────────────

pub const MountSpec = struct {
    mount_path: []const u8,
    node_id: []const u8,
    export_name: []const u8 = "work",
};

pub const BindSpec = struct {
    bind_path: []const u8,
    target_path: []const u8,
};

pub const WorkspaceSetupPlan = struct {
    workspace_id: ?[]const u8 = null,
    name: ?[]const u8 = null,
    vision: ?[]const u8 = null,
    template_id: ?[]const u8 = null,
    activate: bool = true,
    mounts: []const MountSpec = &.{},
    binds: []const BindSpec = &.{},
};

// ── Result ───────────────────────────────────────────────────────────────────

pub const WorkspaceSetupResult = struct {
    workspace_id: []u8,
    workspace_token: ?[]u8,
    created: bool,

    pub fn deinit(self: *WorkspaceSetupResult, allocator: std.mem.Allocator) void {
        allocator.free(self.workspace_id);
        if (self.workspace_token) |v| allocator.free(v);
        self.* = undefined;
    }
};

// ── validateSetupPlan ────────────────────────────────────────────────────────

/// Returns error.MissingField when the plan is insufficient to submit.
pub fn validateSetupPlan(plan: *const WorkspaceSetupPlan) !void {
    if (plan.mounts.len == 0) return error.MissingField;
    for (plan.mounts) |m| {
        if (m.mount_path.len == 0 or m.node_id.len == 0) return error.MissingField;
    }
}

// ── executeSetupPlan ─────────────────────────────────────────────────────────

/// Sends a `control.workspace_up` RPC with the given plan and returns the
/// workspace ID and token from the response. Caller owns the result.
pub fn executeSetupPlan(
    allocator: std.mem.Allocator,
    client: anytype,
    message_counter: *u64,
    plan: *const WorkspaceSetupPlan,
) !WorkspaceSetupResult {
    var payload = std.ArrayListUnmanaged(u8){};
    defer payload.deinit(allocator);
    try payload.append(allocator, '{');

    var appended = false;
    if (plan.workspace_id) |value| {
        const escaped = try unified.jsonEscape(allocator, value);
        defer allocator.free(escaped);
        try payload.writer(allocator).print("\"workspace_id\":\"{s}\"", .{escaped});
        appended = true;
    }
    if (plan.name) |value| {
        const escaped = try unified.jsonEscape(allocator, value);
        defer allocator.free(escaped);
        if (appended) try payload.append(allocator, ',');
        try payload.writer(allocator).print("\"name\":\"{s}\"", .{escaped});
        appended = true;
    }
    if (plan.vision) |value| {
        const escaped = try unified.jsonEscape(allocator, value);
        defer allocator.free(escaped);
        if (appended) try payload.append(allocator, ',');
        try payload.writer(allocator).print("\"vision\":\"{s}\"", .{escaped});
        appended = true;
    }
    if (plan.template_id) |value| {
        const escaped = try unified.jsonEscape(allocator, value);
        defer allocator.free(escaped);
        if (appended) try payload.append(allocator, ',');
        try payload.writer(allocator).print("\"template_id\":\"{s}\"", .{escaped});
        appended = true;
    }
    if (appended) try payload.append(allocator, ',');
    try payload.writer(allocator).print(
        "\"activate\":{s},\"desired_mounts\":[",
        .{if (plan.activate) "true" else "false"},
    );
    for (plan.mounts, 0..) |mount, idx| {
        if (idx != 0) try payload.append(allocator, ',');
        const ep = try unified.jsonEscape(allocator, mount.mount_path);
        defer allocator.free(ep);
        const en = try unified.jsonEscape(allocator, mount.node_id);
        defer allocator.free(en);
        const ee = try unified.jsonEscape(allocator, mount.export_name);
        defer allocator.free(ee);
        try payload.writer(allocator).print(
            "{{\"mount_path\":\"{s}\",\"node_id\":\"{s}\",\"export_name\":\"{s}\"}}",
            .{ ep, en, ee },
        );
    }
    try payload.append(allocator, ']');
    if (plan.binds.len > 0) {
        try payload.appendSlice(allocator, ",\"desired_binds\":[");
        for (plan.binds, 0..) |bind, idx| {
            if (idx != 0) try payload.append(allocator, ',');
            const eb = try unified.jsonEscape(allocator, bind.bind_path);
            defer allocator.free(eb);
            const et = try unified.jsonEscape(allocator, bind.target_path);
            defer allocator.free(et);
            try payload.writer(allocator).print(
                "{{\"bind_path\":\"{s}\",\"target_path\":\"{s}\"}}",
                .{ eb, et },
            );
        }
        try payload.append(allocator, ']');
    }
    try payload.append(allocator, '}');

    const payload_json = try control_plane.requestControlPayloadJson(
        allocator,
        client,
        message_counter,
        "control.workspace_up",
        payload.items,
    );
    defer allocator.free(payload_json);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload_json, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidResponse;

    const id_val = parsed.value.object.get("workspace_id") orelse
        parsed.value.object.get("project_id") orelse
        return error.InvalidResponse;
    if (id_val != .string) return error.InvalidResponse;
    const workspace_id = try allocator.dupe(u8, id_val.string);
    errdefer allocator.free(workspace_id);

    const token: ?[]u8 = blk: {
        if (parsed.value.object.get("workspace_token")) |v| {
            if (v == .string) break :blk try allocator.dupe(u8, v.string);
        }
        if (parsed.value.object.get("project_token")) |v| {
            if (v == .string) break :blk try allocator.dupe(u8, v.string);
        }
        break :blk null;
    };

    const created = if (parsed.value.object.get("created")) |v|
        v == .bool and v.bool
    else
        false;

    return WorkspaceSetupResult{
        .workspace_id = workspace_id,
        .workspace_token = token,
        .created = created,
    };
}
