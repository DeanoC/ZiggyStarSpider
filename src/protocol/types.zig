const std = @import("std");

// Core data types for ZiggyStarSpider (ZSS) protocol
// Defines Project, Goal, Task, and Agent entities

// ============================================================================
// Enums
// ============================================================================

/// Status of a project
pub const ProjectStatus = enum {
    active,
    paused,
    completed,
    archived,

    pub fn toString(self: ProjectStatus) []const u8 {
        return switch (self) {
            .active => "active",
            .paused => "paused",
            .completed => "completed",
            .archived => "archived",
        };
    }

    pub fn fromString(s: []const u8) ?ProjectStatus {
        if (std.mem.eql(u8, s, "active")) return .active;
        if (std.mem.eql(u8, s, "paused")) return .paused;
        if (std.mem.eql(u8, s, "completed")) return .completed;
        if (std.mem.eql(u8, s, "archived")) return .archived;
        return null;
    }
};

/// Status of a goal
pub const GoalStatus = enum {
    open,
    in_progress,
    blocked,
    completed,
    cancelled,

    pub fn toString(self: GoalStatus) []const u8 {
        return switch (self) {
            .open => "open",
            .in_progress => "in_progress",
            .blocked => "blocked",
            .completed => "completed",
            .cancelled => "cancelled",
        };
    }

    pub fn fromString(s: []const u8) ?GoalStatus {
        if (std.mem.eql(u8, s, "open")) return .open;
        if (std.mem.eql(u8, s, "in_progress")) return .in_progress;
        if (std.mem.eql(u8, s, "blocked")) return .blocked;
        if (std.mem.eql(u8, s, "completed")) return .completed;
        if (std.mem.eql(u8, s, "cancelled")) return .cancelled;
        return null;
    }
};

/// Status of a task
pub const TaskStatus = enum {
    pending,
    in_progress,
    completed,
    failed,
    cancelled,

    pub fn toString(self: TaskStatus) []const u8 {
        return switch (self) {
            .pending => "pending",
            .in_progress => "in_progress",
            .completed => "completed",
            .failed => "failed",
            .cancelled => "cancelled",
        };
    }

    pub fn fromString(s: []const u8) ?TaskStatus {
        if (std.mem.eql(u8, s, "pending")) return .pending;
        if (std.mem.eql(u8, s, "in_progress")) return .in_progress;
        if (std.mem.eql(u8, s, "completed")) return .completed;
        if (std.mem.eql(u8, s, "failed")) return .failed;
        if (std.mem.eql(u8, s, "cancelled")) return .cancelled;
        return null;
    }
};

/// Type of worker for a task
pub const WorkerType = enum {
    research, // Research and analysis tasks
    implement, // Code implementation
    testing, // Testing and validation
    review, // Code review
    doc, // Documentation
    pm, // Project management
    custom, // Custom worker type

    pub fn toString(self: WorkerType) []const u8 {
        return switch (self) {
            .research => "research",
            .implement => "implement",
            .testing => "test",
            .review => "review",
            .doc => "doc",
            .pm => "pm",
            .custom => "custom",
        };
    }

    pub fn fromString(s: []const u8) ?WorkerType {
        if (std.mem.eql(u8, s, "research")) return .research;
        if (std.mem.eql(u8, s, "implement")) return .implement;
        if (std.mem.eql(u8, s, "test")) return .testing;
        if (std.mem.eql(u8, s, "review")) return .review;
        if (std.mem.eql(u8, s, "doc")) return .doc;
        if (std.mem.eql(u8, s, "pm")) return .pm;
        if (std.mem.eql(u8, s, "custom")) return .custom;
        return null;
    }
};

/// Status of an agent
pub const AgentStatus = enum {
    idle,
    busy,
    offline,
    error_state,

    pub fn toString(self: AgentStatus) []const u8 {
        return switch (self) {
            .idle => "idle",
            .busy => "busy",
            .offline => "offline",
            .error_state => "error",
        };
    }

    pub fn fromString(s: []const u8) ?AgentStatus {
        if (std.mem.eql(u8, s, "idle")) return .idle;
        if (std.mem.eql(u8, s, "busy")) return .busy;
        if (std.mem.eql(u8, s, "offline")) return .offline;
        if (std.mem.eql(u8, s, "error")) return .error_state;
        return null;
    }
};

/// Role of an agent
pub const AgentRole = enum {
    user, // Human user
    pm, // Project manager agent
    worker, // Worker agent
    system, // System agent

    pub fn toString(self: AgentRole) []const u8 {
        return switch (self) {
            .user => "user",
            .pm => "pm",
            .worker => "worker",
            .system => "system",
        };
    }

    pub fn fromString(s: []const u8) ?AgentRole {
        if (std.mem.eql(u8, s, "user")) return .user;
        if (std.mem.eql(u8, s, "pm")) return .pm;
        if (std.mem.eql(u8, s, "worker")) return .worker;
        if (std.mem.eql(u8, s, "system")) return .system;
        return null;
    }
};

// ============================================================================
// Core Entities
// ============================================================================

/// Unique identifier type (UUID string)
pub const Id = []const u8;

/// Timestamp (milliseconds since epoch)
pub const Timestamp = i64;

/// Project - Container for work
/// A project has metadata, config, and linked agents
pub const Project = struct {
    id: Id,
    name: []const u8,
    description: ?[]const u8,
    status: ProjectStatus,

    // Ownership
    owner_id: Id, // Agent that owns this project (usually PM)
    created_by: Id, // User who created the project

    // Configuration
    config: ProjectConfig,

    // Timestamps
    created_at: Timestamp,
    updated_at: Timestamp,
    completed_at: ?Timestamp,

    // Statistics (computed)
    goal_count: u32 = 0,
    completed_goals: u32 = 0,
    active_tasks: u32 = 0,

    pub fn init(id: Id, name: []const u8, created_by: Id) Project {
        const now = std.time.milliTimestamp();
        return .{
            .id = id,
            .name = name,
            .description = null,
            .status = .active,
            .owner_id = created_by, // Initially owned by creator
            .created_by = created_by,
            .config = ProjectConfig.default(),
            .created_at = now,
            .updated_at = now,
            .completed_at = null,
        };
    }
};

/// Project configuration
pub const ProjectConfig = struct {
    // Workflow settings
    auto_spawn_workers: bool = true, // PM auto-spawns workers for goals
    require_approval: bool = true, // Require user approval for changes

    // Notification settings
    notify_on_goal_complete: bool = true,
    notify_on_task_failed: bool = true,

    // Worker settings
    max_concurrent_workers: u8 = 3,

    pub fn default() ProjectConfig {
        return .{};
    }
};

/// Goal - High-level objective within a project
/// Goals are broken down into tasks by the PM agent
pub const Goal = struct {
    id: Id,
    project_id: Id,

    // Content
    title: []const u8,
    description: ?[]const u8,

    // Status
    status: GoalStatus,
    priority: u8, // 1-10, higher = more important

    // Assignment
    owner_id: Id, // PM agent responsible

    // Timestamps
    created_at: Timestamp,
    updated_at: Timestamp,
    started_at: ?Timestamp,
    completed_at: ?Timestamp,

    // Progress (computed from tasks)
    task_count: u32 = 0,
    completed_tasks: u32 = 0,
    progress_percent: u8 = 0, // 0-100

    pub fn init(id: Id, project_id: Id, title: []const u8, owner_id: Id) Goal {
        const now = std.time.milliTimestamp();
        return .{
            .id = id,
            .project_id = project_id,
            .title = title,
            .description = null,
            .status = .open,
            .priority = 5,
            .owner_id = owner_id,
            .created_at = now,
            .updated_at = now,
            .started_at = null,
            .completed_at = null,
        };
    }

    /// Recalculate progress based on task completion
    pub fn updateProgress(self: *Goal) void {
        if (self.task_count == 0) {
            self.progress_percent = 0;
            return;
        }
        self.progress_percent = @intCast(@min(100, (self.completed_tasks * 100) / self.task_count));
    }
};

/// Task - Concrete unit of work
/// Tasks are assigned to workers for execution
pub const Task = struct {
    id: Id,
    goal_id: Id,
    project_id: Id,

    // Content
    description: []const u8,
    worker_type: WorkerType,

    // Status
    status: TaskStatus,
    priority: u8, // 1-10

    // Assignment
    assigned_to: ?Id, // Worker agent ID (null if unassigned)
    spawned_by: Id, // PM agent that spawned this task

    // Input/Output
    input_data: ?[]const u8, // JSON string with task inputs
    result_data: ?[]const u8, // JSON string with task results
    error_message: ?[]const u8,

    // Timestamps
    created_at: Timestamp,
    updated_at: Timestamp,
    started_at: ?Timestamp,
    completed_at: ?Timestamp,

    // Progress
    progress_percent: u8 = 0, // 0-100
    progress_message: ?[]const u8,

    pub fn init(id: Id, goal_id: Id, project_id: Id, description: []const u8, worker_type: WorkerType, spawned_by: Id) Task {
        const now = std.time.milliTimestamp();
        return .{
            .id = id,
            .goal_id = goal_id,
            .project_id = project_id,
            .description = description,
            .worker_type = worker_type,
            .status = .pending,
            .priority = 5,
            .assigned_to = null,
            .spawned_by = spawned_by,
            .input_data = null,
            .result_data = null,
            .error_message = null,
            .created_at = now,
            .updated_at = now,
            .started_at = null,
            .completed_at = null,
            .progress_percent = 0,
            .progress_message = null,
        };
    }
};

/// Agent - Entity that can own projects/goals/tasks
/// Agents can be users, PMs, or workers
pub const Agent = struct {
    id: Id,
    name: []const u8,

    // Classification
    role: AgentRole,
    status: AgentStatus,

    // Capabilities (for workers)
    capabilities: ?[]const u8, // JSON array of capability strings

    // Assignment tracking
    current_project: ?Id,
    current_task: ?Id,

    // Timestamps
    created_at: Timestamp,
    last_seen_at: Timestamp,

    pub fn init(id: Id, name: []const u8, role: AgentRole) Agent {
        const now = std.time.milliTimestamp();
        return .{
            .id = id,
            .name = name,
            .role = role,
            .status = .idle,
            .capabilities = null,
            .current_project = null,
            .current_task = null,
            .created_at = now,
            .last_seen_at = now,
        };
    }

    pub fn isAvailable(self: Agent) bool {
        return self.status == .idle;
    }
};

// ============================================================================
// Project Overview (Aggregated view)
// ============================================================================

/// Aggregated project status for UI display
pub const ProjectOverview = struct {
    project: Project,
    goals: []const Goal,
    active_tasks: []const Task,
    agents: []const Agent,
};

// ============================================================================
// JSON Serialization Helpers
// ============================================================================

/// Serialize a Project to JSON
pub fn projectToJson(allocator: std.mem.Allocator, project: Project) ![]const u8 {
    var buf = std.ArrayList(u8).init(allocator);
    defer buf.deinit();
    const writer = buf.writer();

    try writer.writeAll("{");
    try writer.print("\"id\":\"{s}\",", .{project.id});
    try writer.print("\"name\":\"{s}\",", .{project.name});
    try writer.print("\"description\":{s},", .{if (project.description) |d| try std.json.encodeJsonString(d, .{}, allocator) else "null"});
    try writer.print("\"status\":\"{s}\",", .{project.status.toString()});
    try writer.print("\"owner_id\":\"{s}\",", .{project.owner_id});
    try writer.print("\"created_by\":\"{s}\",", .{project.created_by});
    try writer.print("\"created_at\":{d},", .{project.created_at});
    try writer.print("\"updated_at\":{d},", .{project.updated_at});
    try writer.print("\"completed_at\":{s}", .{if (project.completed_at) |t| try std.fmt.allocPrint(allocator, "{d}", .{t}) else "null"});
    try writer.writeAll("}");

    return buf.toOwnedSlice();
}

/// Serialize a Goal to JSON
pub fn goalToJson(allocator: std.mem.Allocator, goal: Goal) ![]const u8 {
    var buf = std.ArrayList(u8).init(allocator);
    defer buf.deinit();
    const writer = buf.writer();

    try writer.writeAll("{");
    try writer.print("\"id\":\"{s}\",", .{goal.id});
    try writer.print("\"project_id\":\"{s}\",", .{goal.project_id});
    try writer.print("\"title\":\"{s}\",", .{goal.title});
    try writer.print("\"description\":{s},", .{if (goal.description) |d| try std.json.encodeJsonString(d, .{}, allocator) else "null"});
    try writer.print("\"status\":\"{s}\",", .{goal.status.toString()});
    try writer.print("\"priority\":{d},", .{goal.priority});
    try writer.print("\"owner_id\":\"{s}\",", .{goal.owner_id});
    try writer.print("\"progress_percent\":{d},", .{goal.progress_percent});
    try writer.print("\"task_count\":{d},", .{goal.task_count});
    try writer.print("\"completed_tasks\":{d},", .{goal.completed_tasks});
    try writer.print("\"created_at\":{d},", .{goal.created_at});
    try writer.print("\"updated_at\":{d}", .{goal.updated_at});
    try writer.writeAll("}");

    return buf.toOwnedSlice();
}

/// Serialize a Task to JSON
pub fn taskToJson(allocator: std.mem.Allocator, task: Task) ![]const u8 {
    var buf = std.ArrayList(u8).init(allocator);
    defer buf.deinit();
    const writer = buf.writer();

    try writer.writeAll("{");
    try writer.print("\"id\":\"{s}\",", .{task.id});
    try writer.print("\"goal_id\":\"{s}\",", .{task.goal_id});
    try writer.print("\"project_id\":\"{s}\",", .{task.project_id});
    try writer.print("\"description\":\"{s}\",", .{task.description});
    try writer.print("\"worker_type\":\"{s}\",", .{task.worker_type.toString()});
    try writer.print("\"status\":\"{s}\",", .{task.status.toString()});
    try writer.print("\"priority\":{d},", .{task.priority});
    try writer.print("\"assigned_to\":{s},", .{if (task.assigned_to) |id| try std.fmt.allocPrint(allocator, "\"{s}\"", .{id}) else "null"});
    try writer.print("\"spawned_by\":\"{s}\",", .{task.spawned_by});
    try writer.print("\"progress_percent\":{d},", .{task.progress_percent});
    try writer.print("\"created_at\":{d},", .{task.created_at});
    try writer.print("\"updated_at\":{d}", .{task.updated_at});
    try writer.writeAll("}");

    return buf.toOwnedSlice();
}

/// Serialize an Agent to JSON
pub fn agentToJson(allocator: std.mem.Allocator, agent: Agent) ![]const u8 {
    var buf = std.ArrayList(u8).init(allocator);
    defer buf.deinit();
    const writer = buf.writer();

    try writer.writeAll("{");
    try writer.print("\"id\":\"{s}\",", .{agent.id});
    try writer.print("\"name\":\"{s}\",", .{agent.name});
    try writer.print("\"role\":\"{s}\",", .{agent.role.toString()});
    try writer.print("\"status\":\"{s}\",", .{agent.status.toString()});
    try writer.print("\"current_project\":{s},", .{if (agent.current_project) |id| try std.fmt.allocPrint(allocator, "\"{s}\"", .{id}) else "null"});
    try writer.print("\"current_task\":{s},", .{if (agent.current_task) |id| try std.fmt.allocPrint(allocator, "\"{s}\"", .{id}) else "null"});
    try writer.print("\"created_at\":{d},", .{agent.created_at});
    try writer.print("\"last_seen_at\":{d}", .{agent.last_seen_at});
    try writer.writeAll("}");

    return buf.toOwnedSlice();
}
