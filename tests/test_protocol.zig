const std = @import("std");
const protocol = @import("../src/protocol/spiderweb.zig");
const types = @import("../src/protocol/types.zig");
const messages = @import("../src/protocol/messages.zig");

// ============================================================================
// Type Tests
// ============================================================================

test "Project type" {
    const allocator = std.testing.allocator;

    var project = types.Project.init("proj_test123", "Test Project", "user_001");
    project.description = "A test project";

    try std.testing.expectEqualStrings("proj_test123", project.id);
    try std.testing.expectEqualStrings("Test Project", project.name);
    try std.testing.expectEqualStrings("user_001", project.created_by);
    try std.testing.expectEqual(types.ProjectStatus.active, project.status);

    // Test JSON serialization
    const json = try types.projectToJson(allocator, project);
    defer allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "proj_test123") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "Test Project") != null);
}

test "Goal type" {
    const allocator = std.testing.allocator;

    var goal = types.Goal.init("goal_test456", "proj_test123", "Implement feature", "agent_pm_001");
    goal.description = "Implement the core feature";
    goal.priority = 8;

    try std.testing.expectEqualStrings("goal_test456", goal.id);
    try std.testing.expectEqualStrings("Implement feature", goal.title);
    try std.testing.expectEqual(types.GoalStatus.open, goal.status);
    try std.testing.expectEqual(@as(u8, 8), goal.priority);

    // Test progress calculation
    goal.task_count = 10;
    goal.completed_tasks = 5;
    goal.updateProgress();
    try std.testing.expectEqual(@as(u8, 50), goal.progress_percent);

    // Test JSON serialization
    const json = try types.goalToJson(allocator, goal);
    defer allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "goal_test456") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "Implement feature") != null);
}

test "Task type" {
    const allocator = std.testing.allocator;

    var task = types.Task.init(
        "task_test789",
        "goal_test456",
        "proj_test123",
        "Design the API",
        .research,
        "agent_pm_001",
    );
    task.priority = 9;

    try std.testing.expectEqualStrings("task_test789", task.id);
    try std.testing.expectEqualStrings("Design the API", task.description);
    try std.testing.expectEqual(types.WorkerType.research, task.worker_type);
    try std.testing.expectEqual(types.TaskStatus.pending, task.status);

    // Test JSON serialization
    const json = try types.taskToJson(allocator, task);
    defer allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "task_test789") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "research") != null);
}

test "Agent type" {
    const allocator = std.testing.allocator;

    var agent = types.Agent.init("agent_001", "Test Agent", .pm);
    try std.testing.expectEqualStrings("agent_001", agent.id);
    try std.testing.expectEqualStrings("Test Agent", agent.name);
    try std.testing.expectEqual(types.AgentRole.pm, agent.role);
    try std.testing.expectEqual(types.AgentStatus.idle, agent.status);
    try std.testing.expect(agent.isAvailable());

    agent.status = .busy;
    try std.testing.expect(!agent.isAvailable());

    // Test JSON serialization
    const json = try types.agentToJson(allocator, agent);
    defer allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "agent_001") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "pm") != null);
}

// ============================================================================
// Enum Tests
// ============================================================================

test "ProjectStatus enum conversions" {
    try std.testing.expectEqualStrings("active", types.ProjectStatus.active.toString());
    try std.testing.expectEqual(types.ProjectStatus.paused, types.ProjectStatus.fromString("paused").?);
    try std.testing.expectEqual(types.ProjectStatus.completed, types.ProjectStatus.fromString("completed").?);
    try std.testing.expect(types.ProjectStatus.fromString("invalid") == null);
}

test "GoalStatus enum conversions" {
    try std.testing.expectEqualStrings("in_progress", types.GoalStatus.in_progress.toString());
    try std.testing.expectEqual(types.GoalStatus.open, types.GoalStatus.fromString("open").?);
    try std.testing.expectEqual(types.GoalStatus.blocked, types.GoalStatus.fromString("blocked").?);
    try std.testing.expect(types.GoalStatus.fromString("invalid") == null);
}

test "TaskStatus enum conversions" {
    try std.testing.expectEqualStrings("completed", types.TaskStatus.completed.toString());
    try std.testing.expectEqual(types.TaskStatus.pending, types.TaskStatus.fromString("pending").?);
    try std.testing.expectEqual(types.TaskStatus.failed, types.TaskStatus.fromString("failed").?);
    try std.testing.expect(types.TaskStatus.fromString("invalid") == null);
}

test "WorkerType enum conversions" {
    try std.testing.expectEqualStrings("implement", types.WorkerType.implement.toString());
    try std.testing.expectEqual(types.WorkerType.research, types.WorkerType.fromString("research").?);
    try std.testing.expectEqual(types.WorkerType.test_type, types.WorkerType.fromString("test").?);
    try std.testing.expect(types.WorkerType.fromString("invalid") == null);
}

test "AgentRole enum conversions" {
    try std.testing.expectEqualStrings("pm", types.AgentRole.pm.toString());
    try std.testing.expectEqual(types.AgentRole.user, types.AgentRole.fromString("user").?);
    try std.testing.expectEqual(types.AgentRole.worker, types.AgentRole.fromString("worker").?);
    try std.testing.expect(types.AgentRole.fromString("invalid") == null);
}

// ============================================================================
// Message Tests
// ============================================================================

test "MessageType enum conversions" {
    try std.testing.expectEqualStrings("project.create", messages.MessageType.project_create.toString());
    try std.testing.expectEqual(messages.MessageType.goal_create, messages.MessageType.fromString("goal.create").?);
    try std.testing.expectEqual(messages.MessageType.task_update, messages.MessageType.fromString("task.update").?);
    try std.testing.expect(messages.MessageType.fromString("invalid.type") == null);
}

test "message type parsing" {
    const connect = "{\"type\":\"connect\"}";
    try std.testing.expect(messages.parseMessageType(connect).? == .connect);

    const chat_send = "{\"type\":\"chat.send\"}";
    try std.testing.expect(messages.parseMessageType(chat_send).? == .chat_send);

    const project_create = "{\"type\":\"project.create\"}";
    try std.testing.expect(messages.parseMessageType(project_create).? == .project_create);

    const goal_create = "{\"type\":\"goal.create\"}";
    try std.testing.expect(messages.parseMessageType(goal_create).? == .goal_create);

    const task_create = "{\"type\":\"task.create\"}";
    try std.testing.expect(messages.parseMessageType(task_create).? == .task_create);

    const worker_progress = "{\"type\":\"worker.progress\"}";
    try std.testing.expect(messages.parseMessageType(worker_progress).? == .worker_progress);
}

test "buildChatReceive" {
    const allocator = std.testing.allocator;

    const response = try messages.buildChatReceive(allocator, "msg123", "Hello, world!", "assistant");
    defer allocator.free(response);

    try std.testing.expect(std.mem.indexOf(u8, response, "chat.receive") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "msg123") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "Hello, world!") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "assistant") != null);
}

test "buildPing and buildPong" {
    const allocator = std.testing.allocator;

    const ping = try messages.buildPing(allocator);
    defer allocator.free(ping);
    try std.testing.expect(std.mem.indexOf(u8, ping, "ping") != null);

    const pong = try messages.buildPong(allocator, 1234567890);
    defer allocator.free(pong);
    try std.testing.expect(std.mem.indexOf(u8, pong, "pong") != null);
    try std.testing.expect(std.mem.indexOf(u8, pong, "1234567890") != null);
}

test "buildWorkerProgress" {
    const allocator = std.testing.allocator;

    const progress = try messages.buildWorkerProgress(
        allocator,
        "worker_001",
        "task_001",
        75,
        "Processing data...",
    );
    defer allocator.free(progress);

    try std.testing.expect(std.mem.indexOf(u8, progress, "worker.progress") != null);
    try std.testing.expect(std.mem.indexOf(u8, progress, "worker_001") != null);
    try std.testing.expect(std.mem.indexOf(u8, progress, "task_001") != null);
    try std.testing.expect(std.mem.indexOf(u8, progress, "75") != null);
    try std.testing.expect(std.mem.indexOf(u8, progress, "Processing data...") != null);
}

test "buildError" {
    const allocator = std.testing.allocator;

    const error_msg = try messages.buildError(allocator, "req_001", "NOT_FOUND", "Resource not found");
    defer allocator.free(error_msg);

    try std.testing.expect(std.mem.indexOf(u8, error_msg, "error") != null);
    try std.testing.expect(std.mem.indexOf(u8, error_msg, "NOT_FOUND") != null);
    try std.testing.expect(std.mem.indexOf(u8, error_msg, "Resource not found") != null);
}

// ============================================================================
// Legacy Compatibility Tests
// ============================================================================

test "legacy protocol message parsing" {
    const connect = "{\"type\":\"connect\"}";
    try std.testing.expect(protocol.parseMessageType(connect).? == .connect);

    const chat_send = "{\"type\":\"chat.send\"}";
    try std.testing.expect(protocol.parseMessageType(chat_send).? == .chat_send);

    const project_create = "{\"type\":\"project.create\"}";
    try std.testing.expect(protocol.parseMessageType(project_create).? == .project_create);
}

test "legacy buildChatReceive" {
    const allocator = std.testing.allocator;

    const response = try protocol.buildChatReceive(allocator, "msg123", "Hello");
    defer allocator.free(response);

    try std.testing.expect(std.mem.indexOf(u8, response, "chat.receive") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "msg123") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "Hello") != null);
}

// ============================================================================
// Integration Test - Full Flow
// ============================================================================

test "full project-goal-task flow" {
    const allocator = std.testing.allocator;

    // 1. Create a project
    var project = types.Project.init("proj_flow", "Flow Test Project", "user_001");
    project.description = "Testing the full flow";
    try std.testing.expectEqualStrings("proj_flow", project.id);

    // 2. Create a goal for the project
    var goal = types.Goal.init("goal_flow", project.id, "Implement feature X", "agent_pm_001");
    goal.priority = 8;
    try std.testing.expectEqualStrings("proj_flow", goal.project_id);

    // 3. Create tasks for the goal
    var task1 = types.Task.init("task_1", goal.id, project.id, "Design API", .research, "agent_pm_001");
    var task2 = types.Task.init("task_2", goal.id, project.id, "Implement code", .implement, "agent_pm_001");

    try std.testing.expectEqualStrings("goal_flow", task1.goal_id);
    try std.testing.expectEqualStrings("goal_flow", task2.goal_id);

    // 4. Assign worker to task
    task1.assigned_to = "agent_worker_001";
    task1.status = .in_progress;
    try std.testing.expectEqualStrings("agent_worker_001", task1.assigned_to.?);
    try std.testing.expectEqual(types.TaskStatus.in_progress, task1.status);

    // 5. Update progress
    task1.progress_percent = 50;
    task1.progress_message = "Halfway done";

    // 6. Complete task
    task1.status = .completed;
    task1.progress_percent = 100;
    goal.completed_tasks = 1;
    goal.task_count = 2;
    goal.updateProgress();

    try std.testing.expectEqual(@as(u8, 50), goal.progress_percent);

    // 7. Serialize everything
    const project_json = try types.projectToJson(allocator, project);
    defer allocator.free(project_json);

    const goal_json = try types.goalToJson(allocator, goal);
    defer allocator.free(goal_json);

    const task1_json = try types.taskToJson(allocator, task1);
    defer allocator.free(task1_json);

    // Verify JSON contains expected fields
    try std.testing.expect(std.mem.indexOf(u8, project_json, "proj_flow") != null);
    try std.testing.expect(std.mem.indexOf(u8, goal_json, "goal_flow") != null);
    try std.testing.expect(std.mem.indexOf(u8, task1_json, "task_1") != null);
}
