const std = @import("std");

pub const MountView = struct {
    mount_path: []u8,
    node_id: []u8,
    node_name: ?[]u8 = null,
    fs_url: ?[]u8 = null,
    export_name: []u8,

    pub fn deinit(self: *MountView, allocator: std.mem.Allocator) void {
        allocator.free(self.mount_path);
        allocator.free(self.node_id);
        if (self.node_name) |value| allocator.free(value);
        if (self.fs_url) |value| allocator.free(value);
        allocator.free(self.export_name);
        self.* = undefined;
    }
};

pub const DriftItem = struct {
    mount_path: ?[]u8 = null,
    kind: ?[]u8 = null,
    severity: ?[]u8 = null,
    selected_node_id: ?[]u8 = null,
    desired_node_id: ?[]u8 = null,
    message: ?[]u8 = null,

    pub fn deinit(self: *DriftItem, allocator: std.mem.Allocator) void {
        if (self.mount_path) |value| allocator.free(value);
        if (self.kind) |value| allocator.free(value);
        if (self.severity) |value| allocator.free(value);
        if (self.selected_node_id) |value| allocator.free(value);
        if (self.desired_node_id) |value| allocator.free(value);
        if (self.message) |value| allocator.free(value);
        self.* = undefined;
    }
};

pub const ReconcileProjectStatus = struct {
    project_id: []u8,
    mounts: usize,
    drift_count: usize,
    queue_depth: usize,

    pub fn deinit(self: *ReconcileProjectStatus, allocator: std.mem.Allocator) void {
        allocator.free(self.project_id);
        self.* = undefined;
    }
};

pub const ReconcileStatus = struct {
    reconcile_state: ?[]u8 = null,
    last_reconcile_ms: i64 = 0,
    last_success_ms: i64 = 0,
    last_error: ?[]u8 = null,
    queue_depth: usize = 0,
    failed_ops_total: u64 = 0,
    cycles_total: u64 = 0,
    failed_ops: std.ArrayListUnmanaged([]u8) = .{},
    projects: std.ArrayListUnmanaged(ReconcileProjectStatus) = .{},

    pub fn deinit(self: *ReconcileStatus, allocator: std.mem.Allocator) void {
        if (self.reconcile_state) |value| allocator.free(value);
        if (self.last_error) |value| allocator.free(value);
        for (self.failed_ops.items) |value| allocator.free(value);
        self.failed_ops.deinit(allocator);
        for (self.projects.items) |*project| project.deinit(allocator);
        self.projects.deinit(allocator);
        self.* = undefined;
    }
};

pub const ProjectSummary = struct {
    id: []u8,
    name: []u8,
    vision: []u8,
    status: []u8,
    kind: ?[]u8 = null,
    is_delete_protected: bool = false,
    token_locked: bool = false,
    mount_count: usize,
    created_at_ms: i64,
    updated_at_ms: i64,

    pub fn deinit(self: *ProjectSummary, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.name);
        allocator.free(self.vision);
        allocator.free(self.status);
        if (self.kind) |value| allocator.free(value);
        self.* = undefined;
    }
};

pub const ProjectDetail = struct {
    id: []u8,
    name: []u8,
    vision: []u8,
    status: []u8,
    kind: ?[]u8 = null,
    is_delete_protected: bool = false,
    token_locked: bool = false,
    created_at_ms: i64,
    updated_at_ms: i64,
    project_token: ?[]u8 = null,
    mounts: std.ArrayListUnmanaged(MountView) = .{},

    pub fn deinit(self: *ProjectDetail, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.name);
        allocator.free(self.vision);
        allocator.free(self.status);
        if (self.kind) |value| allocator.free(value);
        if (self.project_token) |value| allocator.free(value);
        for (self.mounts.items) |*mount| mount.deinit(allocator);
        self.mounts.deinit(allocator);
        self.* = undefined;
    }
};

pub const NodeInfo = struct {
    node_id: []u8,
    node_name: []u8,
    fs_url: []u8,
    joined_at_ms: i64,
    last_seen_ms: i64,
    lease_expires_at_ms: i64,

    pub fn deinit(self: *NodeInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.node_id);
        allocator.free(self.node_name);
        allocator.free(self.fs_url);
        self.* = undefined;
    }
};

pub const AgentInfo = struct {
    id: []u8,
    name: []u8,
    description: []u8,
    is_default: bool = false,
    identity_loaded: bool = false,
    needs_hatching: bool = false,
    capabilities: std.ArrayListUnmanaged([]u8) = .{},

    pub fn deinit(self: *AgentInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.name);
        allocator.free(self.description);
        for (self.capabilities.items) |capability| allocator.free(capability);
        self.capabilities.deinit(allocator);
        self.* = undefined;
    }
};

pub const WorkspaceStatus = struct {
    agent_id: []u8,
    project_id: ?[]u8 = null,
    workspace_root: ?[]u8 = null,
    mounts: std.ArrayListUnmanaged(MountView) = .{},
    desired_mounts: std.ArrayListUnmanaged(MountView) = .{},
    actual_mounts: std.ArrayListUnmanaged(MountView) = .{},
    drift_items: std.ArrayListUnmanaged(DriftItem) = .{},
    drift_count: usize = 0,
    reconcile_state: ?[]u8 = null,
    last_reconcile_ms: i64 = 0,
    last_success_ms: i64 = 0,
    last_error: ?[]u8 = null,
    queue_depth: usize = 0,
    availability_mounts_total: usize = 0,
    availability_online: usize = 0,
    availability_degraded: usize = 0,
    availability_missing: usize = 0,

    pub fn deinit(self: *WorkspaceStatus, allocator: std.mem.Allocator) void {
        allocator.free(self.agent_id);
        if (self.project_id) |value| allocator.free(value);
        if (self.workspace_root) |value| allocator.free(value);
        for (self.mounts.items) |*mount| mount.deinit(allocator);
        self.mounts.deinit(allocator);
        for (self.desired_mounts.items) |*mount| mount.deinit(allocator);
        self.desired_mounts.deinit(allocator);
        for (self.actual_mounts.items) |*mount| mount.deinit(allocator);
        self.actual_mounts.deinit(allocator);
        for (self.drift_items.items) |*item| item.deinit(allocator);
        self.drift_items.deinit(allocator);
        if (self.reconcile_state) |value| allocator.free(value);
        if (self.last_error) |value| allocator.free(value);
        self.* = undefined;
    }
};

pub const SessionAttachStatus = struct {
    session_key: []u8,
    agent_id: []u8,
    project_id: ?[]u8 = null,
    state: []u8,
    runtime_ready: bool = false,
    mount_ready: bool = false,
    error_code: ?[]u8 = null,
    error_message: ?[]u8 = null,
    updated_at_ms: i64 = 0,

    pub fn deinit(self: *SessionAttachStatus, allocator: std.mem.Allocator) void {
        allocator.free(self.session_key);
        allocator.free(self.agent_id);
        if (self.project_id) |value| allocator.free(value);
        allocator.free(self.state);
        if (self.error_code) |value| allocator.free(value);
        if (self.error_message) |value| allocator.free(value);
        self.* = undefined;
    }
};

pub const SessionSummary = struct {
    session_key: []u8,
    agent_id: []u8,
    project_id: ?[]u8 = null,
    last_active_ms: i64 = 0,
    message_count: u64 = 0,
    summary: ?[]u8 = null,

    pub fn deinit(self: *SessionSummary, allocator: std.mem.Allocator) void {
        allocator.free(self.session_key);
        allocator.free(self.agent_id);
        if (self.project_id) |value| allocator.free(value);
        if (self.summary) |value| allocator.free(value);
        self.* = undefined;
    }
};

pub const SessionList = struct {
    active_session: []u8,
    sessions: std.ArrayListUnmanaged(SessionSummary) = .{},

    pub fn deinit(self: *SessionList, allocator: std.mem.Allocator) void {
        allocator.free(self.active_session);
        for (self.sessions.items) |*session| session.deinit(allocator);
        self.sessions.deinit(allocator);
        self.* = undefined;
    }
};

pub const SessionCloseResult = struct {
    session_key: []u8,
    closed: bool,
    active_session: []u8,

    pub fn deinit(self: *SessionCloseResult, allocator: std.mem.Allocator) void {
        allocator.free(self.session_key);
        allocator.free(self.active_session);
        self.* = undefined;
    }
};

pub const SessionRestoreResult = struct {
    found: bool,
    session: ?SessionSummary = null,

    pub fn deinit(self: *SessionRestoreResult, allocator: std.mem.Allocator) void {
        if (self.session) |*value| value.deinit(allocator);
        self.* = undefined;
    }
};

pub fn deinitProjectList(allocator: std.mem.Allocator, projects: *std.ArrayListUnmanaged(ProjectSummary)) void {
    for (projects.items) |*project| project.deinit(allocator);
    projects.deinit(allocator);
    projects.* = .{};
}

pub fn deinitNodeList(allocator: std.mem.Allocator, nodes: *std.ArrayListUnmanaged(NodeInfo)) void {
    for (nodes.items) |*node| node.deinit(allocator);
    nodes.deinit(allocator);
    nodes.* = .{};
}

pub fn deinitAgentList(allocator: std.mem.Allocator, agents: *std.ArrayListUnmanaged(AgentInfo)) void {
    for (agents.items) |*agent| agent.deinit(allocator);
    agents.deinit(allocator);
    agents.* = .{};
}
