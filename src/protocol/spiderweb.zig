const std = @import("std");

// Spiderweb protocol message types
// Extends OpenClaw with project-oriented primitives

pub const MessageType = enum {
    // Connection lifecycle (OpenClaw compatible)
    connect,
    connect_ack,
    chat_ack,           // Renamed from session_ack
    disconnect,
    
    // Messaging (OpenClaw compatible)
    chat_send,          // Renamed from session_send
    chat_receive,       // Renamed from session_receive
    
    // Project management (Spiderweb extension)
    project_create,
    project_list,
    project_update,
    project_delete,
    
    // Goal/Task management
    goal_create,
    goal_update,
    goal_complete,
    goal_list,
    
    task_create,
    task_update,
    task_complete,
    task_list,
    
    // Worker management
    worker_spawn,
    worker_complete,
    worker_failed,
    worker_progress,
    
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
    err,
};

// Chat message (replaces session)
pub const ChatMessage = struct {
    id: []const u8,
    content: []const u8,
    role: []const u8 = "user",  // "user" | "assistant" | "system"
    timestamp: i64,
};

// Project definition
pub const Project = struct {
    id: []const u8,
    name: []const u8,
    description: ?[]const u8 = null,
    status: []const u8 = "active",  // "active" | "paused" | "completed"
    created_at: i64,
    updated_at: i64,
};

// Goal within a project
pub const Goal = struct {
    id: []const u8,
    project_id: []const u8,
    description: []const u8,
    status: []const u8 = "open",  // "open" | "in_progress" | "completed" | "blocked"
    priority: u8 = 5,  // 1-10
    created_at: i64,
    completed_at: ?i64 = null,
};

// Task (spawned by PM agent)
pub const Task = struct {
    id: []const u8,
    goal_id: []const u8,
    description: []const u8,
    worker_type: []const u8,  // "research" | "implement" | "test" | "review"
    status: []const u8 = "pending",  // "pending" | "running" | "completed" | "failed"
    result: ?[]const u8 = null,
    created_at: i64,
    started_at: ?i64 = null,
    completed_at: ?i64 = null,
};

// Worker progress update
pub const WorkerProgress = struct {
    task_id: []const u8,
    percent: u8,  // 0-100
    message: ?[]const u8 = null,
};

// Memory entry
pub const MemoryEntry = struct {
    id: []const u8,
    kind: []const u8,  // "chat" | "context" | "lesson" | "note"
    content: []const u8,
    tags: ?[][]const u8 = null,
    created_at: i64,
};

// VFS mount point
pub const VfsMount = struct {
    id: []const u8,
    name: []const u8,
    mount_point: []const u8,  // e.g., "/nodes/user-windows"
    backend_type: []const u8,  // "node" | "s3" | "dropbox" | "local"
    backend_config: ?std.json.Value = null,
};

// Build chat.receive response
pub fn buildChatReceive(allocator: std.mem.Allocator, request_id: []const u8, content: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator,
        "{{\"type\":\"chat.receive\",\"id\":\"{s}\",\"content\":\"{s}\",\"timestamp\":{d}}}",
        .{ request_id, content, std.time.milliTimestamp() }
    );
}

// Build pong response
pub fn buildPong(allocator: std.mem.Allocator) ![]u8 {
    return std.fmt.allocPrint(allocator,
        "{{\"type\":\"pong\",\"timestamp\":{d}}}",
        .{std.time.milliTimestamp()}
    );
}

// Parse message type from JSON
pub fn parseMessageType(json: []const u8) ?MessageType {
    // Simple string search for type field
    // In production, use proper JSON parsing
    if (std.mem.indexOf(u8, json, "\"type\":\"connect\"") != null) return .connect;
    if (std.mem.indexOf(u8, json, "\"type\":\"chat.send\"") != null) return .chat_send;
    if (std.mem.indexOf(u8, json, "\"type\":\"project.create\"") != null) return .project_create;
    if (std.mem.indexOf(u8, json, "\"type\":\"goal.create\"") != null) return .goal_create;
    if (std.mem.indexOf(u8, json, "\"type\":\"task.create\"") != null) return .task_create;
    if (std.mem.indexOf(u8, json, "\"type\":\"worker.progress\"") != null) return .worker_progress;
    if (std.mem.indexOf(u8, json, "\"type\":\"memory.store\"") != null) return .memory_store;
    if (std.mem.indexOf(u8, json, "\"type\":\"vfs.mount\"") != null) return .vfs_mount;
    if (std.mem.indexOf(u8, json, "\"type\":\"ping\"") != null) return .ping;
    if (std.mem.indexOf(u8, json, "\"type\":\"pong\"") != null) return .pong;
    if (std.mem.indexOf(u8, json, "\"type\":\"disconnect\"") != null) return .disconnect;
    return null;
}
