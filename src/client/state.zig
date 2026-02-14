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
    
    pub fn init() ChatState {
        return .{
            .messages = std.ArrayList(protocol.ChatReceiveResponse).empty,
        };
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
            .last_error = null,
        };
    }
    
    pub fn deinit(self: *ClientContext) void {
        // Cleanup
        self.chat.messages.deinit(self.allocator);
        self.projects.projects.deinit(self.allocator);
        self.projects.goals.deinit(self.allocator);
        self.projects.tasks.deinit(self.allocator);
        self.active_workers.deinit(self.allocator);
        self.vfs_mounts.deinit(self.allocator);
        if (self.pending_chat_request) |req| self.allocator.free(req);
        if (self.last_error) |err| self.allocator.free(err);
    }
};
