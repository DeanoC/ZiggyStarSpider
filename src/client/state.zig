const std = @import("std");
const websocket = @import("websocket");
const protocol = @import("../protocol/spiderweb.zig");
const Config = @import("config.zig").Config;

// Client state for Spiderweb connection
// Simpler than OpenClaw - no sessions, just chat + projects

pub const ClientState = enum {
    disconnected,
    connecting,
    authenticating,
    connected,
    error_state,
};

pub const ChatState = struct {
    messages: std.ArrayList(protocol.ChatReceiveResponse),
    awaiting_reply: bool = false,
    stream_request_id: ?[]const u8 = null,
    stream_message_id: ?[]const u8 = null,
    stream_run_id: ?[]const u8 = null,

    pub fn init() ChatState {
        return .{
            .messages = std.ArrayList(protocol.ChatReceiveResponse).empty,
        };
    }

    pub fn deinit(self: *ChatState, allocator: std.mem.Allocator) void {
        if (self.stream_request_id) |request_id| {
            allocator.free(request_id);
            self.stream_request_id = null;
        }
        if (self.stream_message_id) |message_id| {
            allocator.free(message_id);
            self.stream_message_id = null;
        }
        if (self.stream_run_id) |run_id| {
            allocator.free(run_id);
            self.stream_run_id = null;
        }
        self.messages.deinit(allocator);
    }

    pub fn setStreamRun(
        self: *ChatState,
        allocator: std.mem.Allocator,
        request_id: ?[]const u8,
        message_id: ?[]const u8,
        run_id: ?[]const u8,
    ) !void {
        if (self.stream_request_id) |current| allocator.free(current);
        if (self.stream_message_id) |current| allocator.free(current);
        if (self.stream_run_id) |current| allocator.free(current);

        self.stream_request_id = if (request_id) |value| try allocator.dupe(u8, value) else null;
        self.stream_message_id = if (message_id) |value| try allocator.dupe(u8, value) else null;
        self.stream_run_id = if (run_id) |value| try allocator.dupe(u8, value) else null;
    }
};

pub const ProjectContext = struct {
    current_project: ?[]const u8,
    projects: std.ArrayList(protocol.Project),
    goals: std.ArrayList(protocol.Goal),
    tasks: std.ArrayList(protocol.Task),
};

pub const ClientContext = struct {
    allocator: std.mem.Allocator,
    state: ClientState,

    // Chat
    chat: ChatState,

    // Project context
    projects: ProjectContext,

    // Workers (active tasks)
    active_workers: std.ArrayList(protocol.Task),

    // VFS mounts
    vfs_mounts: std.ArrayList(protocol.VfsMount),

    // Pending requests
    pending_chat_request: ?[]const u8,
    pending_send_request_id: ?[]const u8,
    pending_send_message_id: ?[]const u8,
    pending_send_session_key: ?[]const u8,

    // Error handling
    last_error: ?[]const u8,

    pub fn init(allocator: std.mem.Allocator) !ClientContext {
        return .{
            .allocator = allocator,
            .state = .disconnected,
            .chat = ChatState.init(),
            .projects = .{
                .current_project = null,
                .projects = std.ArrayList(protocol.Project).empty,
                .goals = std.ArrayList(protocol.Goal).empty,
                .tasks = std.ArrayList(protocol.Task).empty,
            },
            .active_workers = std.ArrayList(protocol.Task).empty,
            .vfs_mounts = std.ArrayList(protocol.VfsMount).empty,
            .pending_chat_request = null,
            .pending_send_request_id = null,
            .pending_send_message_id = null,
            .pending_send_session_key = null,
            .last_error = null,
        };
    }

    pub fn deinit(self: *ClientContext) void {
        self.chat.deinit(self.allocator);

        self.projects.projects.deinit(self.allocator);
        self.projects.goals.deinit(self.allocator);
        self.projects.tasks.deinit(self.allocator);
        self.active_workers.deinit(self.allocator);
        self.vfs_mounts.deinit(self.allocator);
        if (self.pending_chat_request) |req| self.allocator.free(req);
        if (self.pending_send_request_id) |id| self.allocator.free(id);
        if (self.pending_send_message_id) |id| self.allocator.free(id);
        if (self.pending_send_session_key) |key| self.allocator.free(key);
        if (self.last_error) |err| self.allocator.free(err);
    }
};
