// health_checks.zig — Shared workspace health check logic.
//
// Used by `spider workspace doctor` (CLI) and the Dashboard panel (GUI).
// Returns a slice of HealthCheck structs that callers can render however
// they choose.

const std = @import("std");
const control_plane = @import("control_plane");
const workspace_types = control_plane.workspace_types;

// ── Types ────────────────────────────────────────────────────────────────────

pub const HealthCheckStatus = enum { ok, fail, warning };

pub const HealthCheck = struct {
    label: []u8,
    status: HealthCheckStatus,
    message: []u8,

    pub fn deinit(self: *HealthCheck, allocator: std.mem.Allocator) void {
        allocator.free(self.label);
        allocator.free(self.message);
        self.* = undefined;
    }
};

pub fn deinitHealthChecks(allocator: std.mem.Allocator, checks: *[]HealthCheck) void {
    for (checks.*) |*c| c.deinit(allocator);
    allocator.free(checks.*);
    checks.* = &.{};
}

/// Returns the number of failed checks in a health check slice.
pub fn failureCount(checks: []const HealthCheck) usize {
    var n: usize = 0;
    for (checks) |c| {
        if (c.status == .fail) n += 1;
    }
    return n;
}

// ── runHealthChecks ──────────────────────────────────────────────────────────

/// Runs health checks against the Spiderweb control plane.
/// Returns an owned slice of HealthCheck; caller must call deinitHealthChecks.
pub fn runHealthChecks(
    allocator: std.mem.Allocator,
    client: anytype,
    message_counter: *u64,
    workspace_id: ?[]const u8,
    workspace_token: ?[]const u8,
) ![]HealthCheck {
    var list = std.ArrayListUnmanaged(HealthCheck){};
    errdefer {
        for (list.items) |*c| c.deinit(allocator);
        list.deinit(allocator);
    }

    // ── Check 1: registered nodes ─────────────────────────────────────────
    {
        var nodes = try control_plane.listNodes(allocator, client, message_counter);
        defer workspace_types.deinitNodeList(allocator, &nodes);
        if (nodes.items.len == 0) {
            try list.append(allocator, .{
                .label = try allocator.dupe(u8, "Nodes"),
                .status = .fail,
                .message = try allocator.dupe(u8, "No nodes registered. Add at least one node before activation."),
            });
        } else {
            const msg = try std.fmt.allocPrint(allocator, "Registered nodes: {d}", .{nodes.items.len});
            try list.append(allocator, .{
                .label = try allocator.dupe(u8, "Nodes"),
                .status = .ok,
                .message = msg,
            });
        }
    }

    // ── Check 2: workspaces exist ─────────────────────────────────────────
    {
        var projects = try control_plane.listWorkspaces(allocator, client, message_counter);
        defer workspace_types.deinitWorkspaceList(allocator, &projects);
        if (projects.items.len == 0) {
            try list.append(allocator, .{
                .label = try allocator.dupe(u8, "Workspaces"),
                .status = .fail,
                .message = try allocator.dupe(u8, "No workspaces exist. Run `workspace up <name>`."),
            });
        } else {
            const msg = try std.fmt.allocPrint(allocator, "Workspaces: {d}", .{projects.items.len});
            try list.append(allocator, .{
                .label = try allocator.dupe(u8, "Workspaces"),
                .status = .ok,
                .message = msg,
            });
        }
    }

    // ── Checks 3–5 require a selected workspace ───────────────────────────
    if (workspace_id == null) {
        try list.append(allocator, .{
            .label = try allocator.dupe(u8, "Workspace selected"),
            .status = .fail,
            .message = try allocator.dupe(u8, "No workspace selected. Use --workspace or `workspace use`."),
        });
        return try list.toOwnedSlice(allocator);
    }

    // ── Check 3 & 4: mounts + drift ──────────────────────────────────────
    {
        var status = try control_plane.workspaceStatus(
            allocator,
            client,
            message_counter,
            workspace_id,
            workspace_token,
        );
        defer status.deinit(allocator);
        const active_count = if (status.actual_mounts.items.len > 0)
            status.actual_mounts.items.len
        else
            status.mounts.items.len;
        if (active_count == 0) {
            try list.append(allocator, .{
                .label = try allocator.dupe(u8, "Mounts"),
                .status = .fail,
                .message = try allocator.dupe(u8, "Selected workspace has no active mounts."),
            });
        } else {
            const msg = try std.fmt.allocPrint(allocator, "Active mounts: {d}", .{active_count});
            try list.append(allocator, .{
                .label = try allocator.dupe(u8, "Mounts"),
                .status = .ok,
                .message = msg,
            });
        }

        const drift_count = if (status.drift_count > 0)
            status.drift_count
        else
            status.drift_items.items.len;
        if (drift_count > 0) {
            const msg = try std.fmt.allocPrint(allocator, "Workspace drift detected: {d}", .{drift_count});
            try list.append(allocator, .{
                .label = try allocator.dupe(u8, "Drift"),
                .status = .fail,
                .message = msg,
            });
        } else {
            try list.append(allocator, .{
                .label = try allocator.dupe(u8, "Drift"),
                .status = .ok,
                .message = try allocator.dupe(u8, "No workspace drift detected."),
            });
        }
    }

    // ── Check 5: reconcile queue ──────────────────────────────────────────
    {
        var reconcile = try control_plane.reconcileStatus(
            allocator,
            client,
            message_counter,
            workspace_id,
        );
        defer reconcile.deinit(allocator);
        if (reconcile.queue_depth > 0 or reconcile.failed_ops.items.len > 0) {
            const msg = try std.fmt.allocPrint(
                allocator,
                "Reconcile queue_depth={d} failed_ops={d}",
                .{ reconcile.queue_depth, reconcile.failed_ops.items.len },
            );
            try list.append(allocator, .{
                .label = try allocator.dupe(u8, "Reconcile"),
                .status = .fail,
                .message = msg,
            });
        } else {
            try list.append(allocator, .{
                .label = try allocator.dupe(u8, "Reconcile"),
                .status = .ok,
                .message = try allocator.dupe(u8, "Reconcile queue empty."),
            });
        }
    }

    return try list.toOwnedSlice(allocator);
}
