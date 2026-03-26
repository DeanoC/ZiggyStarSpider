// mission_types.zig — View-model types for the Mission panel.
//
// These are pure data structures (only std dependency) so they can be
// tested and used outside of the GUI rendering context.

const std = @import("std");

// ── Leaf types ────────────────────────────────────────────────────────────────

pub const MissionActorView = struct {
    actor_type: []u8,
    actor_id: []u8,

    pub fn deinit(self: *MissionActorView, allocator: std.mem.Allocator) void {
        allocator.free(self.actor_type);
        allocator.free(self.actor_id);
        self.* = undefined;
    }
};

pub const MissionArtifactView = struct {
    kind: []u8,
    path: ?[]u8 = null,
    summary: ?[]u8 = null,
    created_at_ms: i64 = 0,

    pub fn deinit(self: *MissionArtifactView, allocator: std.mem.Allocator) void {
        allocator.free(self.kind);
        if (self.path) |value| allocator.free(value);
        if (self.summary) |value| allocator.free(value);
        self.* = undefined;
    }
};

pub const MissionEventView = struct {
    seq: u64,
    event_type: []u8,
    payload_json: []u8,
    created_at_ms: i64,

    pub fn deinit(self: *MissionEventView, allocator: std.mem.Allocator) void {
        allocator.free(self.event_type);
        allocator.free(self.payload_json);
        self.* = undefined;
    }
};

pub const MissionApprovalView = struct {
    approval_id: []u8,
    action_kind: []u8,
    message: []u8,
    payload_json: ?[]u8 = null,
    requested_at_ms: i64 = 0,
    requested_by: MissionActorView,
    resolved_at_ms: i64 = 0,
    resolved_by: ?MissionActorView = null,
    resolution_note: ?[]u8 = null,
    resolution: ?[]u8 = null,

    pub fn deinit(self: *MissionApprovalView, allocator: std.mem.Allocator) void {
        allocator.free(self.approval_id);
        allocator.free(self.action_kind);
        allocator.free(self.message);
        if (self.payload_json) |value| allocator.free(value);
        self.requested_by.deinit(allocator);
        if (self.resolved_by) |*value| value.deinit(allocator);
        if (self.resolution_note) |value| allocator.free(value);
        if (self.resolution) |value| allocator.free(value);
        self.* = undefined;
    }
};

pub const MissionAgentPackView = struct {
    agent_id: []u8,
    persona_pack: ?[]u8 = null,

    pub fn deinit(self: *MissionAgentPackView, allocator: std.mem.Allocator) void {
        allocator.free(self.agent_id);
        if (self.persona_pack) |value| allocator.free(value);
        self.* = undefined;
    }
};

// ── MissionRecordView ─────────────────────────────────────────────────────────

pub const MissionRecordView = struct {
    mission_id: []u8,
    use_case: []u8,
    title: ?[]u8 = null,
    stage: []u8,
    state: []u8,
    agent_id: ?[]u8 = null,
    persona_pack: ?[]u8 = null,
    project_id: ?[]u8 = null,
    run_id: ?[]u8 = null,
    workspace_root: ?[]u8 = null,
    worktree_name: ?[]u8 = null,
    contract_id: ?[]u8 = null,
    contract_context_path: ?[]u8 = null,
    contract_state_path: ?[]u8 = null,
    contract_artifact_root: ?[]u8 = null,
    created_by: MissionActorView,
    created_at_ms: i64 = 0,
    updated_at_ms: i64 = 0,
    last_heartbeat_ms: i64 = 0,
    checkpoint_seq: u64 = 0,
    recovery_count: u64 = 0,
    recovery_reason: ?[]u8 = null,
    blocked_reason: ?[]u8 = null,
    summary: ?[]u8 = null,
    pending_approval: ?MissionApprovalView = null,
    artifacts: std.ArrayListUnmanaged(MissionArtifactView) = .{},
    events: std.ArrayListUnmanaged(MissionEventView) = .{},

    pub fn deinit(self: *MissionRecordView, allocator: std.mem.Allocator) void {
        allocator.free(self.mission_id);
        allocator.free(self.use_case);
        if (self.title) |value| allocator.free(value);
        allocator.free(self.stage);
        allocator.free(self.state);
        if (self.agent_id) |value| allocator.free(value);
        if (self.persona_pack) |value| allocator.free(value);
        if (self.project_id) |value| allocator.free(value);
        if (self.run_id) |value| allocator.free(value);
        if (self.workspace_root) |value| allocator.free(value);
        if (self.worktree_name) |value| allocator.free(value);
        if (self.contract_id) |value| allocator.free(value);
        if (self.contract_context_path) |value| allocator.free(value);
        if (self.contract_state_path) |value| allocator.free(value);
        if (self.contract_artifact_root) |value| allocator.free(value);
        self.created_by.deinit(allocator);
        if (self.recovery_reason) |value| allocator.free(value);
        if (self.blocked_reason) |value| allocator.free(value);
        if (self.summary) |value| allocator.free(value);
        if (self.pending_approval) |*value| value.deinit(allocator);
        for (self.artifacts.items) |*item| item.deinit(allocator);
        self.artifacts.deinit(allocator);
        for (self.events.items) |*item| item.deinit(allocator);
        self.events.deinit(allocator);
        self.* = undefined;
    }
};

// ── Tests ─────────────────────────────────────────────────────────────────────

test "MissionActorView deinit frees all memory" {
    const allocator = std.testing.allocator;
    var actor = MissionActorView{
        .actor_type = try allocator.dupe(u8, "human"),
        .actor_id = try allocator.dupe(u8, "user-123"),
    };
    actor.deinit(allocator);
}

test "MissionArtifactView deinit with optional fields" {
    const allocator = std.testing.allocator;
    var artifact = MissionArtifactView{
        .kind = try allocator.dupe(u8, "file"),
        .path = try allocator.dupe(u8, "/output/result.txt"),
        .summary = try allocator.dupe(u8, "Main result"),
    };
    artifact.deinit(allocator);
}

test "MissionArtifactView deinit with nulls" {
    const allocator = std.testing.allocator;
    var artifact = MissionArtifactView{
        .kind = try allocator.dupe(u8, "file"),
    };
    artifact.deinit(allocator);
}

test "MissionEventView deinit frees all memory" {
    const allocator = std.testing.allocator;
    var event = MissionEventView{
        .seq = 42,
        .event_type = try allocator.dupe(u8, "mission.started"),
        .payload_json = try allocator.dupe(u8, "{}"),
        .created_at_ms = 1000,
    };
    event.deinit(allocator);
}

test "MissionApprovalView deinit with resolved_by" {
    const allocator = std.testing.allocator;
    var approval = MissionApprovalView{
        .approval_id = try allocator.dupe(u8, "appr-1"),
        .action_kind = try allocator.dupe(u8, "deploy"),
        .message = try allocator.dupe(u8, "Please approve deployment"),
        .payload_json = try allocator.dupe(u8, "{\"target\":\"prod\"}"),
        .requested_by = .{
            .actor_type = try allocator.dupe(u8, "agent"),
            .actor_id = try allocator.dupe(u8, "agent-spider"),
        },
        .resolved_by = .{
            .actor_type = try allocator.dupe(u8, "human"),
            .actor_id = try allocator.dupe(u8, "user-1"),
        },
        .resolution_note = try allocator.dupe(u8, "Approved for staging"),
        .resolution = try allocator.dupe(u8, "approved"),
    };
    approval.deinit(allocator);
}

test "MissionApprovalView deinit without optional fields" {
    const allocator = std.testing.allocator;
    var approval = MissionApprovalView{
        .approval_id = try allocator.dupe(u8, "appr-2"),
        .action_kind = try allocator.dupe(u8, "run"),
        .message = try allocator.dupe(u8, "Run tests"),
        .requested_by = .{
            .actor_type = try allocator.dupe(u8, "agent"),
            .actor_id = try allocator.dupe(u8, "agent-ci"),
        },
    };
    approval.deinit(allocator);
}

test "MissionRecordView deinit with artifacts and events" {
    const allocator = std.testing.allocator;
    var record = MissionRecordView{
        .mission_id = try allocator.dupe(u8, "mission-abc"),
        .use_case = try allocator.dupe(u8, "code-review"),
        .title = try allocator.dupe(u8, "Review PR #42"),
        .stage = try allocator.dupe(u8, "running"),
        .state = try allocator.dupe(u8, "active"),
        .project_id = try allocator.dupe(u8, "proj-xyz"),
        .created_by = .{
            .actor_type = try allocator.dupe(u8, "human"),
            .actor_id = try allocator.dupe(u8, "user-1"),
        },
        .summary = try allocator.dupe(u8, "Review in progress"),
    };
    try record.artifacts.append(allocator, .{
        .kind = try allocator.dupe(u8, "diff"),
        .path = try allocator.dupe(u8, "/pr/42.diff"),
    });
    try record.events.append(allocator, .{
        .seq = 1,
        .event_type = try allocator.dupe(u8, "started"),
        .payload_json = try allocator.dupe(u8, "{}"),
        .created_at_ms = 1234567890,
    });
    record.deinit(allocator);
}

test "MissionRecordView deinit with minimal fields" {
    const allocator = std.testing.allocator;
    var record = MissionRecordView{
        .mission_id = try allocator.dupe(u8, "mission-min"),
        .use_case = try allocator.dupe(u8, "lint"),
        .stage = try allocator.dupe(u8, "done"),
        .state = try allocator.dupe(u8, "completed"),
        .created_by = .{
            .actor_type = try allocator.dupe(u8, "system"),
            .actor_id = try allocator.dupe(u8, "ci"),
        },
    };
    record.deinit(allocator);
}
