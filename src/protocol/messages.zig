const std = @import("std");
const types = @import("types.zig");

// Protocol message definitions for ZiggyStarSpider (ZSS)
// All messages are JSON-encoded for WebSocket transport
//
// Message format:
// {
//   "type": "message.type",
//   "id": "unique-request-id",
//   "timestamp": 1234567890,
//   ...payload
// }

// ============================================================================
// Message Type Enumeration
// ============================================================================

pub const MessageType = enum {
    // Connection lifecycle (OpenClaw compatible)
    connect,
    connect_ack,
    chat_ack,
    disconnect,

    // Messaging (OpenClaw compatible)
    chat_send,
    chat_receive,

    // Project management
    project_create,
    project_create_response,
    project_list,
    project_list_response,
    project_get,
    project_get_response,
    project_update,
    project_update_response,
    project_delete,
    project_delete_response,

    // Goal management
    goal_create,
    goal_create_response,
    goal_list,
    goal_list_response,
    goal_get,
    goal_get_response,
    goal_update,
    goal_update_response,
    goal_delete,
    goal_delete_response,

    // Task management
    task_create,
    task_create_response,
    task_list,
    task_list_response,
    task_get,
    task_get_response,
    task_update,
    task_update_response,
    task_delete,
    task_delete_response,
    task_assign,
    task_assign_response,

    // Worker management
    worker_spawn,
    worker_spawn_response,
    worker_status,
    worker_status_response,
    worker_progress,
    worker_complete,
    worker_failed,

    // Memory
    memory_store,
    memory_recall,
    memory_search,

    // Virtual filesystem
    vfs_mount,
    vfs_unmount,
    vfs_list,

    // Heartbeat
    ping,
    pong,

    // Errors
    error_response,

    pub fn toString(self: MessageType) []const u8 {
        return switch (self) {
            .connect => "connect",
            .connect_ack => "connect.ack",
            .chat_ack => "connect.ack",
            .disconnect => "disconnect",
            .chat_send => "session.send",
            .chat_receive => "session.receive",
            .project_create => "project.create",
            .project_create_response => "project.create_response",
            .project_list => "project.list",
            .project_list_response => "project.list_response",
            .project_get => "project.get",
            .project_get_response => "project.get_response",
            .project_update => "project.update",
            .project_update_response => "project.update_response",
            .project_delete => "project.delete",
            .project_delete_response => "project.delete_response",
            .goal_create => "goal.create",
            .goal_create_response => "goal.create_response",
            .goal_list => "goal.list",
            .goal_list_response => "goal.list_response",
            .goal_get => "goal.get",
            .goal_get_response => "goal.get_response",
            .goal_update => "goal.update",
            .goal_update_response => "goal.update_response",
            .goal_delete => "goal.delete",
            .goal_delete_response => "goal.delete_response",
            .task_create => "task.create",
            .task_create_response => "task.create_response",
            .task_list => "task.list",
            .task_list_response => "task.list_response",
            .task_get => "task.get",
            .task_get_response => "task.get_response",
            .task_update => "task.update",
            .task_update_response => "task.update_response",
            .task_delete => "task.delete",
            .task_delete_response => "task.delete_response",
            .task_assign => "task.assign",
            .task_assign_response => "task.assign_response",
            .worker_spawn => "worker.spawn",
            .worker_spawn_response => "worker.spawn_response",
            .worker_status => "worker.status",
            .worker_status_response => "worker.status_response",
            .worker_progress => "worker.progress",
            .worker_complete => "worker.complete",
            .worker_failed => "worker.failed",
            .memory_store => "memory.store",
            .memory_recall => "memory.recall",
            .memory_search => "memory.search",
            .vfs_mount => "vfs.mount",
            .vfs_unmount => "vfs.unmount",
            .vfs_list => "vfs.list",
            .ping => "ping",
            .pong => "pong",
            .error_response => "error",
        };
    }

    pub fn fromString(s: []const u8) ?MessageType {
        // Connection
        if (std.mem.eql(u8, s, "connect")) return .connect;
        if (std.mem.eql(u8, s, "control.connect")) return .connect;
        if (std.mem.eql(u8, s, "connect_ack")) return .connect_ack;
        if (std.mem.eql(u8, s, "connect.ack")) return .connect_ack;
        if (std.mem.eql(u8, s, "control.connect_ack")) return .connect_ack;
        if (std.mem.eql(u8, s, "control.session_attach")) return .connect_ack;
        if (std.mem.eql(u8, s, "control.session_resume")) return .connect_ack;
        if (std.mem.eql(u8, s, "chat_ack")) return .chat_ack;
        if (std.mem.eql(u8, s, "session.ack")) return .chat_ack;
        if (std.mem.eql(u8, s, "disconnect")) return .disconnect;

        // Chat
        if (std.mem.eql(u8, s, "session.send")) return .chat_send;
        if (std.mem.eql(u8, s, "chat.send")) return .chat_send;
        if (std.mem.eql(u8, s, "session.receive")) return .chat_receive;
        if (std.mem.eql(u8, s, "chat.receive")) return .chat_receive;

        // Project
        if (std.mem.eql(u8, s, "project.create")) return .project_create;
        if (std.mem.eql(u8, s, "project.create_response")) return .project_create_response;
        if (std.mem.eql(u8, s, "project.list")) return .project_list;
        if (std.mem.eql(u8, s, "project.list_response")) return .project_list_response;
        if (std.mem.eql(u8, s, "project.get")) return .project_get;
        if (std.mem.eql(u8, s, "project.get_response")) return .project_get_response;
        if (std.mem.eql(u8, s, "project.update")) return .project_update;
        if (std.mem.eql(u8, s, "project.update_response")) return .project_update_response;
        if (std.mem.eql(u8, s, "project.delete")) return .project_delete;
        if (std.mem.eql(u8, s, "project.delete_response")) return .project_delete_response;

        // Goal
        if (std.mem.eql(u8, s, "goal.create")) return .goal_create;
        if (std.mem.eql(u8, s, "goal.create_response")) return .goal_create_response;
        if (std.mem.eql(u8, s, "goal.list")) return .goal_list;
        if (std.mem.eql(u8, s, "goal.list_response")) return .goal_list_response;
        if (std.mem.eql(u8, s, "goal.get")) return .goal_get;
        if (std.mem.eql(u8, s, "goal.get_response")) return .goal_get_response;
        if (std.mem.eql(u8, s, "goal.update")) return .goal_update;
        if (std.mem.eql(u8, s, "goal.update_response")) return .goal_update_response;
        if (std.mem.eql(u8, s, "goal.delete")) return .goal_delete;
        if (std.mem.eql(u8, s, "goal.delete_response")) return .goal_delete_response;

        // Task
        if (std.mem.eql(u8, s, "task.create")) return .task_create;
        if (std.mem.eql(u8, s, "task.create_response")) return .task_create_response;
        if (std.mem.eql(u8, s, "task.list")) return .task_list;
        if (std.mem.eql(u8, s, "task.list_response")) return .task_list_response;
        if (std.mem.eql(u8, s, "task.get")) return .task_get;
        if (std.mem.eql(u8, s, "task.get_response")) return .task_get_response;
        if (std.mem.eql(u8, s, "task.update")) return .task_update;
        if (std.mem.eql(u8, s, "task.update_response")) return .task_update_response;
        if (std.mem.eql(u8, s, "task.delete")) return .task_delete;
        if (std.mem.eql(u8, s, "task.delete_response")) return .task_delete_response;
        if (std.mem.eql(u8, s, "task.assign")) return .task_assign;
        if (std.mem.eql(u8, s, "task.assign_response")) return .task_assign_response;

        // Worker
        if (std.mem.eql(u8, s, "worker.spawn")) return .worker_spawn;
        if (std.mem.eql(u8, s, "worker.spawn_response")) return .worker_spawn_response;
        if (std.mem.eql(u8, s, "worker.status")) return .worker_status;
        if (std.mem.eql(u8, s, "worker.status_response")) return .worker_status_response;
        if (std.mem.eql(u8, s, "worker.progress")) return .worker_progress;
        if (std.mem.eql(u8, s, "worker.complete")) return .worker_complete;
        if (std.mem.eql(u8, s, "worker.failed")) return .worker_failed;

        // Memory
        if (std.mem.eql(u8, s, "memory.store")) return .memory_store;
        if (std.mem.eql(u8, s, "memory.recall")) return .memory_recall;
        if (std.mem.eql(u8, s, "memory.search")) return .memory_search;

        // VFS
        if (std.mem.eql(u8, s, "vfs.mount")) return .vfs_mount;
        if (std.mem.eql(u8, s, "vfs.unmount")) return .vfs_unmount;
        if (std.mem.eql(u8, s, "vfs.list")) return .vfs_list;

        // Heartbeat
        if (std.mem.eql(u8, s, "ping")) return .ping;
        if (std.mem.eql(u8, s, "control.ping")) return .ping;
        if (std.mem.eql(u8, s, "pong")) return .pong;
        if (std.mem.eql(u8, s, "control.pong")) return .pong;

        // Error
        if (std.mem.eql(u8, s, "error")) return .error_response;
        if (std.mem.eql(u8, s, "control.error")) return .error_response;

        return null;
    }
};

// ============================================================================
// Request/Response Messages
// ============================================================================

// Connection
pub const ConnectRequest = struct {
    client_version: []const u8,
    auth_token: ?[]const u8,
};

pub const ConnectResponse = struct {
    server_version: []const u8,
    agent_id: []const u8,
    success: bool,
    error_message: ?[]const u8,
};

// Chat
pub const ChatSendRequest = struct {
    content: []const u8,
    context: ?[]const u8 = null, // Optional project/goal context
};

pub const ChatReceiveResponse = struct {
    id: []const u8,
    content: []const u8,
    role: []const u8, // "user" | "assistant" | "system"
    timestamp: i64,
};

// Project
pub const ProjectCreateRequest = struct {
    name: []const u8,
    description: ?[]const u8 = null,
    config: ?types.ProjectConfig = null,
};

pub const ProjectCreateResponse = struct {
    success: bool,
    project: ?types.Project = null,
    error_message: ?[]const u8 = null,
};

pub const ProjectListRequest = struct {
    status_filter: ?types.ProjectStatus = null, // null = all
};

pub const ProjectListResponse = struct {
    projects: []const types.Project,
};

pub const ProjectGetRequest = struct {
    project_id: []const u8,
};

pub const ProjectGetResponse = struct {
    success: bool,
    project: ?types.Project = null,
    goals: ?[]const types.Goal = null,
    error_message: ?[]const u8 = null,
};

pub const ProjectUpdateRequest = struct {
    project_id: []const u8,
    name: ?[]const u8 = null,
    description: ?[]const u8 = null,
    status: ?types.ProjectStatus = null,
    config: ?types.ProjectConfig = null,
};

pub const ProjectUpdateResponse = struct {
    success: bool,
    project: ?types.Project = null,
    error_message: ?[]const u8 = null,
};

pub const ProjectDeleteRequest = struct {
    project_id: []const u8,
};

pub const ProjectDeleteResponse = struct {
    success: bool,
    error_message: ?[]const u8 = null,
};

// Goal
pub const GoalCreateRequest = struct {
    project_id: []const u8,
    title: []const u8,
    description: ?[]const u8 = null,
    priority: ?u8 = null, // 1-10, default 5
};

pub const GoalCreateResponse = struct {
    success: bool,
    goal: ?types.Goal = null,
    error_message: ?[]const u8 = null,
};

pub const GoalListRequest = struct {
    project_id: []const u8,
    status_filter: ?types.GoalStatus = null,
};

pub const GoalListResponse = struct {
    success: bool,
    goals: []const types.Goal,
    error_message: ?[]const u8 = null,
};

pub const GoalGetRequest = struct {
    goal_id: []const u8,
};

pub const GoalGetResponse = struct {
    success: bool,
    goal: ?types.Goal = null,
    tasks: ?[]const types.Task = null,
    error_message: ?[]const u8 = null,
};

pub const GoalUpdateRequest = struct {
    goal_id: []const u8,
    title: ?[]const u8 = null,
    description: ?[]const u8 = null,
    status: ?types.GoalStatus = null,
    priority: ?u8 = null,
};

pub const GoalUpdateResponse = struct {
    success: bool,
    goal: ?types.Goal = null,
    error_message: ?[]const u8 = null,
};

pub const GoalDeleteRequest = struct {
    goal_id: []const u8,
};

pub const GoalDeleteResponse = struct {
    success: bool,
    error_message: ?[]const u8 = null,
};

// Task
pub const TaskCreateRequest = struct {
    goal_id: []const u8,
    project_id: []const u8,
    description: []const u8,
    worker_type: types.WorkerType = .custom,
    priority: ?u8 = null,
    input_data: ?[]const u8 = null, // JSON string
};

pub const TaskCreateResponse = struct {
    success: bool,
    task: ?types.Task = null,
    error_message: ?[]const u8 = null,
};

pub const TaskListRequest = struct {
    project_id: ?[]const u8 = null,
    goal_id: ?[]const u8 = null,
    status_filter: ?types.TaskStatus = null,
    assigned_to: ?[]const u8 = null, // Filter by worker agent
};

pub const TaskListResponse = struct {
    success: bool,
    tasks: []const types.Task,
    error_message: ?[]const u8 = null,
};

pub const TaskGetRequest = struct {
    task_id: []const u8,
};

pub const TaskGetResponse = struct {
    success: bool,
    task: ?types.Task = null,
    error_message: ?[]const u8 = null,
};

pub const TaskUpdateRequest = struct {
    task_id: []const u8,
    description: ?[]const u8 = null,
    status: ?types.TaskStatus = null,
    priority: ?u8 = null,
    progress_percent: ?u8 = null,
    progress_message: ?[]const u8 = null,
    result_data: ?[]const u8 = null,
    error_message: ?[]const u8 = null,
};

pub const TaskUpdateResponse = struct {
    success: bool,
    task: ?types.Task = null,
    error_message: ?[]const u8 = null,
};

pub const TaskDeleteRequest = struct {
    task_id: []const u8,
};

pub const TaskDeleteResponse = struct {
    success: bool,
    error_message: ?[]const u8 = null,
};

pub const TaskAssignRequest = struct {
    task_id: []const u8,
    agent_id: []const u8, // Worker agent to assign
};

pub const TaskAssignResponse = struct {
    success: bool,
    task: ?types.Task = null,
    error_message: ?[]const u8 = null,
};

// Worker
pub const WorkerSpawnRequest = struct {
    task_id: []const u8,
    worker_type: types.WorkerType,
    context: ?[]const u8 = null, // Additional context for the worker
};

pub const WorkerSpawnResponse = struct {
    success: bool,
    worker_id: ?[]const u8 = null,
    task: ?types.Task = null,
    error_message: ?[]const u8 = null,
};

pub const WorkerStatusRequest = struct {
    worker_id: []const u8,
};

pub const WorkerStatusResponse = struct {
    success: bool,
    worker_id: []const u8,
    status: types.AgentStatus,
    current_task: ?[]const u8 = null,
    error_message: ?[]const u8 = null,
};

/// Worker progress update (sent by worker to server)
pub const WorkerProgressMessage = struct {
    worker_id: []const u8,
    task_id: []const u8,
    percent: u8, // 0-100
    message: ?[]const u8 = null,
    timestamp: i64,
};

/// Worker completion notification
pub const WorkerCompleteMessage = struct {
    worker_id: []const u8,
    task_id: []const u8,
    result_data: ?[]const u8 = null, // JSON string with results
    timestamp: i64,
};

/// Worker failure notification
pub const WorkerFailedMessage = struct {
    worker_id: []const u8,
    task_id: []const u8,
    error_message: []const u8,
    timestamp: i64,
};

// Error
pub const ErrorResponse = struct {
    code: []const u8,
    message: []const u8,
    request_id: ?[]const u8 = null,
};

// ============================================================================
// Message Builders
// ============================================================================

/// Build a request message envelope
pub fn buildRequest(allocator: std.mem.Allocator, msg_type: MessageType, id: []const u8, payload: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{{\"type\":\"{s}\",\"id\":\"{s}\",\"timestamp\":{d},\"payload\":{s}}}", .{ msg_type.toString(), id, std.time.milliTimestamp(), payload });
}

/// Build a simple response message
pub fn buildResponse(allocator: std.mem.Allocator, msg_type: MessageType, request_id: []const u8, payload: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{{\"type\":\"{s}\",\"request_id\":\"{s}\",\"timestamp\":{d},\"payload\":{s}}}", .{ msg_type.toString(), request_id, std.time.milliTimestamp(), payload });
}

/// Build an error response
pub fn buildError(allocator: std.mem.Allocator, request_id: []const u8, code: []const u8, message: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{{\"type\":\"error\",\"request_id\":\"{s}\",\"timestamp\":{d},\"payload\":{{\"code\":\"{s}\",\"message\":\"{s}\"}}}}", .{ request_id, std.time.milliTimestamp(), code, message });
}

/// Build a ping message
pub fn buildPing(allocator: std.mem.Allocator) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{{\"type\":\"ping\",\"timestamp\":{d}}}", .{std.time.milliTimestamp()});
}

/// Build a pong message
pub fn buildPong(allocator: std.mem.Allocator, ping_timestamp: i64) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{{\"type\":\"pong\",\"ping_timestamp\":{d},\"timestamp\":{d}}}", .{ ping_timestamp, std.time.milliTimestamp() });
}

/// Build a session.send message
pub fn buildChatSend(allocator: std.mem.Allocator, id: []const u8, content: []const u8, context: ?[]const u8) ![]const u8 {
    if (context) |ctx| {
        return std.fmt.allocPrint(allocator, "{{\"type\":\"session.send\",\"id\":\"{s}\",\"timestamp\":{d},\"content\":\"{s}\",\"session_key\":\"{s}\"}}", .{ id, std.time.milliTimestamp(), content, ctx });
    } else {
        return std.fmt.allocPrint(allocator, "{{\"type\":\"session.send\",\"id\":\"{s}\",\"timestamp\":{d},\"content\":\"{s}\"}}", .{ id, std.time.milliTimestamp(), content });
    }
}

/// Build a session.receive message
pub fn buildChatReceive(allocator: std.mem.Allocator, request_id: []const u8, content: []const u8, role: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{{\"type\":\"session.receive\",\"request\":\"{s}\",\"timestamp\":{d},\"content\":\"{s}\",\"role\":\"{s}\"}}", .{ request_id, std.time.milliTimestamp(), content, role });
}

/// Build a worker.progress message
pub fn buildWorkerProgress(allocator: std.mem.Allocator, worker_id: []const u8, task_id: []const u8, percent: u8, message: ?[]const u8) ![]const u8 {
    if (message) |msg| {
        return std.fmt.allocPrint(allocator, "{{\"type\":\"worker.progress\",\"timestamp\":{d},\"worker_id\":\"{s}\",\"task_id\":\"{s}\",\"percent\":{d},\"message\":\"{s}\"}}", .{ std.time.milliTimestamp(), worker_id, task_id, percent, msg });
    } else {
        return std.fmt.allocPrint(allocator, "{{\"type\":\"worker.progress\",\"timestamp\":{d},\"worker_id\":\"{s}\",\"task_id\":\"{s}\",\"percent\":{d}}}", .{ std.time.milliTimestamp(), worker_id, task_id, percent });
    }
}

// ============================================================================
// Message Parsing
// ============================================================================

/// Parse message type from JSON string (simple version)
/// In production, use proper JSON parsing
pub fn parseMessageType(json: []const u8) ?MessageType {
    // Look for "type":"..." pattern
    const type_prefix = "\"type\":\"";
    if (std.mem.indexOf(u8, json, type_prefix)) |start| {
        const type_start = start + type_prefix.len;
        if (std.mem.indexOfScalarPos(u8, json, type_start, '"')) |end| {
            const type_str = json[type_start..end];
            return MessageType.fromString(type_str);
        }
    }
    return null;
}

/// Parse request ID from JSON string
pub fn parseRequestId(json: []const u8) ?[]const u8 {
    const id_prefix = "\"id\":\"";
    if (std.mem.indexOf(u8, json, id_prefix)) |start| {
        const id_start = start + id_prefix.len;
        if (std.mem.indexOfScalarPos(u8, json, id_start, '"')) |end| {
            return json[id_start..end];
        }
    }
    return null;
}
