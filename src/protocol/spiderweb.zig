const std = @import("std");

// Spiderweb Protocol for ZSS
// Re-exports from types.zig and messages.zig for convenience

// Core data types
pub const types = @import("types.zig");
pub const messages = @import("messages.zig");

// Re-export common types for convenience
pub const Project = types.Project;
pub const ProjectStatus = types.ProjectStatus;
pub const ProjectConfig = types.ProjectConfig;

pub const Goal = types.Goal;
pub const GoalStatus = types.GoalStatus;

pub const Task = types.Task;
pub const TaskStatus = types.TaskStatus;
pub const WorkerType = types.WorkerType;

pub const Agent = types.Agent;
pub const AgentStatus = types.AgentStatus;
pub const AgentRole = types.AgentRole;

pub const ProjectOverview = types.ProjectOverview;

// Re-export message types
pub const MessageType = messages.MessageType;
pub const ConnectRequest = messages.ConnectRequest;
pub const ConnectResponse = messages.ConnectResponse;
pub const ChatSendRequest = messages.ChatSendRequest;
pub const ChatReceiveResponse = messages.ChatReceiveResponse;

// Project messages
pub const ProjectCreateRequest = messages.ProjectCreateRequest;
pub const ProjectCreateResponse = messages.ProjectCreateResponse;
pub const ProjectListRequest = messages.ProjectListRequest;
pub const ProjectListResponse = messages.ProjectListResponse;
pub const ProjectGetRequest = messages.ProjectGetRequest;
pub const ProjectGetResponse = messages.ProjectGetResponse;
pub const ProjectUpdateRequest = messages.ProjectUpdateRequest;
pub const ProjectUpdateResponse = messages.ProjectUpdateResponse;
pub const ProjectDeleteRequest = messages.ProjectDeleteRequest;
pub const ProjectDeleteResponse = messages.ProjectDeleteResponse;

// Goal messages
pub const GoalCreateRequest = messages.GoalCreateRequest;
pub const GoalCreateResponse = messages.GoalCreateResponse;
pub const GoalListRequest = messages.GoalListRequest;
pub const GoalListResponse = messages.GoalListResponse;
pub const GoalGetRequest = messages.GoalGetRequest;
pub const GoalGetResponse = messages.GoalGetResponse;
pub const GoalUpdateRequest = messages.GoalUpdateRequest;
pub const GoalUpdateResponse = messages.GoalUpdateResponse;
pub const GoalDeleteRequest = messages.GoalDeleteRequest;
pub const GoalDeleteResponse = messages.GoalDeleteResponse;

// Task messages
pub const TaskCreateRequest = messages.TaskCreateRequest;
pub const TaskCreateResponse = messages.TaskCreateResponse;
pub const TaskListRequest = messages.TaskListRequest;
pub const TaskListResponse = messages.TaskListResponse;
pub const TaskGetRequest = messages.TaskGetRequest;
pub const TaskGetResponse = messages.TaskGetResponse;
pub const TaskUpdateRequest = messages.TaskUpdateRequest;
pub const TaskUpdateResponse = messages.TaskUpdateResponse;
pub const TaskDeleteRequest = messages.TaskDeleteRequest;
pub const TaskDeleteResponse = messages.TaskDeleteResponse;
pub const TaskAssignRequest = messages.TaskAssignRequest;
pub const TaskAssignResponse = messages.TaskAssignResponse;

// Worker messages
pub const WorkerSpawnRequest = messages.WorkerSpawnRequest;
pub const WorkerSpawnResponse = messages.WorkerSpawnResponse;
pub const WorkerStatusRequest = messages.WorkerStatusRequest;
pub const WorkerStatusResponse = messages.WorkerStatusResponse;
pub const WorkerProgressMessage = messages.WorkerProgressMessage;
pub const WorkerCompleteMessage = messages.WorkerCompleteMessage;
pub const WorkerFailedMessage = messages.WorkerFailedMessage;

// Error
pub const ErrorResponse = messages.ErrorResponse;

// Legacy compatibility types (deprecated, use types.zig directly)
// These are kept for backward compatibility with existing code

/// Legacy ChatMessage - use ChatReceiveResponse instead
pub const ChatMessage = struct {
    id: []const u8,
    content: []const u8,
    role: []const u8 = "user",
    timestamp: i64,
};

/// Legacy MemoryEntry - will be moved to memory module
pub const MemoryEntry = struct {
    id: []const u8,
    kind: []const u8,
    content: []const u8,
    tags: ?[][]const u8 = null,
    created_at: i64,
};

/// Legacy VfsMount - will be moved to vfs module
pub const VfsMount = struct {
    id: []const u8,
    name: []const u8,
    mount_point: []const u8,
    backend_type: []const u8,
    backend_config: ?std.json.Value = null,
};

// ============================================================================
// Utility Functions
// ============================================================================

/// Parse message type from JSON string (simple version)
/// For production, use proper JSON parsing
pub fn parseMessageType(json: []const u8) ?MessageType {
    return messages.parseMessageType(json);
}

/// Parse request ID from JSON string
pub fn parseRequestId(json: []const u8) ?[]const u8 {
    return messages.parseRequestId(json);
}

// ============================================================================
// Message Builders (Legacy compatibility)
// ============================================================================

/// Build chat.receive response
/// Deprecated: use messages.buildChatReceive instead
pub fn buildChatReceive(allocator: std.mem.Allocator, request_id: []const u8, content: []const u8) ![]const u8 {
    return messages.buildChatReceive(allocator, request_id, content, "assistant");
}

/// Build pong response
/// Deprecated: use messages.buildPong instead
pub fn buildPong(allocator: std.mem.Allocator) ![]const u8 {
    return messages.buildPong(allocator, std.time.milliTimestamp());
}

/// Build error response
/// Deprecated: use messages.buildError instead
pub fn buildErrorResponse(allocator: std.mem.Allocator, request_id: []const u8, code: []const u8, message: []const u8) ![]const u8 {
    return messages.buildError(allocator, request_id, code, message);
}

// ============================================================================
// Protocol Constants
// ============================================================================

pub const PROTOCOL_VERSION = "0.2.0";
pub const DEFAULT_PORT = 18790;

// ============================================================================
// Tests
// ============================================================================

test "protocol exports" {
    // Test that all types are accessible
    _ = Project{};
    _ = Goal{};
    _ = Task{};
    _ = Agent{};
    _ = MessageType.connect;
}

test "message type parsing" {
    const connect = "{\"type\":\"connect\"}";
    try std.testing.expect(parseMessageType(connect).? == .connect);

    const project_create = "{\"type\":\"project.create\"}";
    try std.testing.expect(parseMessageType(project_create).? == .project_create);

    const goal_create = "{\"type\":\"goal.create\"}";
    try std.testing.expect(parseMessageType(goal_create).? == .goal_create);

    const task_create = "{\"type\":\"task.create\"}";
    try std.testing.expect(parseMessageType(task_create).? == .task_create);

    const worker_progress = "{\"type\":\"worker.progress\"}";
    try std.testing.expect(parseMessageType(worker_progress).? == .worker_progress);
}
