# ZSS Data Model Documentation

> Project/Goal/Task data model for ZiggyStarSpider (ZSS) - Issue #4

## Overview

This document describes the core data structures and protocol messages for ZSS, a native client for Spiderweb with a project-oriented assistant architecture.

### Key Principles

- **Agent-centric**: Assistants are first-class entities, not just session handlers
- **Hierarchical agency**: User → PM Agent → Workers
- **Soft workflows**: Flexible execution, not rigid pipelines
- **Project-oriented**: Work is organized around projects, not just chat sessions

---

## Core Entities

### 1. Project

A **Project** is the top-level container for work. It has metadata, configuration, and linked agents.

```zig
pub const Project = struct {
    id: Id,                    // Unique identifier (UUID)
    name: []const u8,          // Project name
    description: ?[]const u8,  // Optional description
    status: ProjectStatus,     // active | paused | completed | archived

    // Ownership
    owner_id: Id,              // PM agent that owns this project
    created_by: Id,            // User who created the project

    // Configuration
    config: ProjectConfig,

    // Timestamps
    created_at: Timestamp,
    updated_at: Timestamp,
    completed_at: ?Timestamp,

    // Statistics (computed)
    goal_count: u32,
    completed_goals: u32,
    active_tasks: u32,
};
```

**Project Status Values:**
- `active` - Project is ongoing
- `paused` - Temporarily suspended
- `completed` - All goals achieved
- `archived` - Stored for reference

**Project Configuration:**
```zig
pub const ProjectConfig = struct {
    auto_spawn_workers: bool = true,   // PM auto-spawns workers for goals
    require_approval: bool = true,     // Require user approval for changes
    notify_on_goal_complete: bool = true,
    notify_on_task_failed: bool = true,
    max_concurrent_workers: u8 = 3,
};
```

#### JSON Example:
```json
{
  "id": "proj_abc123",
  "name": "Spiderweb Development",
  "description": "Build the AI gateway system",
  "status": "active",
  "owner_id": "agent_pm_001",
  "created_by": "user_deano",
  "created_at": 1707830400000,
  "updated_at": 1707830400000,
  "completed_at": null,
  "goal_count": 5,
  "completed_goals": 2,
  "active_tasks": 3
}
```

---

### 2. Goal

A **Goal** is a high-level objective within a project. Goals are broken down into tasks by the PM agent.

```zig
pub const Goal = struct {
    id: Id,
    project_id: Id,

    // Content
    title: []const u8,
    description: ?[]const u8,

    // Status
    status: GoalStatus,        // open | in_progress | blocked | completed | cancelled
    priority: u8,              // 1-10, higher = more important

    // Assignment
    owner_id: Id,              // PM agent responsible

    // Timestamps
    created_at: Timestamp,
    updated_at: Timestamp,
    started_at: ?Timestamp,
    completed_at: ?Timestamp,

    // Progress (computed from tasks)
    task_count: u32,
    completed_tasks: u32,
    progress_percent: u8,      // 0-100
};
```

**Goal Status Values:**
- `open` - Created but not started
- `in_progress` - Active work ongoing
- `blocked` - Blocked (waiting on dependency)
- `completed` - All tasks done
- `cancelled` - No longer relevant

#### JSON Example:
```json
{
  "id": "goal_xyz789",
  "project_id": "proj_abc123",
  "title": "Implement worker spawn",
  "description": "Create the worker spawn system for task execution",
  "status": "in_progress",
  "priority": 8,
  "owner_id": "agent_pm_001",
  "progress_percent": 60,
  "task_count": 5,
  "completed_tasks": 3,
  "created_at": 1707831000000,
  "updated_at": 1707835000000
}
```

---

### 3. Task

A **Task** is a concrete unit of work, assigned to workers for execution.

```zig
pub const Task = struct {
    id: Id,
    goal_id: Id,
    project_id: Id,

    // Content
    description: []const u8,
    worker_type: WorkerType,   // research | implement | test | review | doc | pm | custom

    // Status
    status: TaskStatus,        // pending | in_progress | completed | failed | cancelled
    priority: u8,              // 1-10

    // Assignment
    assigned_to: ?Id,          // Worker agent ID (null if unassigned)
    spawned_by: Id,            // PM agent that spawned this task

    // Input/Output
    input_data: ?[]const u8,   // JSON string with task inputs
    result_data: ?[]const u8,  // JSON string with task results
    error_message: ?[]const u8,

    // Timestamps
    created_at: Timestamp,
    updated_at: Timestamp,
    started_at: ?Timestamp,
    completed_at: ?Timestamp,

    // Progress
    progress_percent: u8,
    progress_message: ?[]const u8,
};
```

**Task Status Values:**
- `pending` - Waiting to be assigned
- `in_progress` - Currently executing
- `completed` - Successfully finished
- `failed` - Execution failed
- `cancelled` - Cancelled before completion

**Worker Types:**
- `research` - Research and analysis tasks
- `implement` - Code implementation
- `test` - Testing and validation
- `review` - Code review
- `doc` - Documentation
- `pm` - Project management
- `custom` - Custom worker type

#### JSON Example:
```json
{
  "id": "task_def456",
  "goal_id": "goal_xyz789",
  "project_id": "proj_abc123",
  "description": "Design worker spawn API",
  "worker_type": "research",
  "status": "completed",
  "priority": 9,
  "assigned_to": "agent_worker_001",
  "spawned_by": "agent_pm_001",
  "progress_percent": 100,
  "input_data": "{\"context\": \"Need to design the worker spawn API for async task execution\"}",
  "result_data": "{\"design\": \"...\", \"recommendations\": [...]}",
  "created_at": 1707832000000,
  "updated_at": 1707834000000,
  "started_at": 1707832500000,
  "completed_at": 1707834000000
}
```

---

### 4. Agent

An **Agent** is an entity that can own projects, goals, or tasks. Agents can be users, PMs, or workers.

```zig
pub const Agent = struct {
    id: Id,
    name: []const u8,

    // Classification
    role: AgentRole,           // user | pm | worker | system
    status: AgentStatus,       // idle | busy | offline | error

    // Capabilities (for workers)
    capabilities: ?[]const u8, // JSON array of capability strings

    // Assignment tracking
    current_project: ?Id,
    current_task: ?Id,

    // Timestamps
    created_at: Timestamp,
    last_seen_at: Timestamp,
};
```

**Agent Roles:**
- `user` - Human user
- `pm` - Project manager agent
- `worker` - Worker agent
- `system` - System agent

**Agent Status Values:**
- `idle` - Available for work
- `busy` - Currently working
- `offline` - Not connected
- `error` - Error state

#### JSON Example:
```json
{
  "id": "agent_pm_001",
  "name": "Project Manager Alpha",
  "role": "pm",
  "status": "busy",
  "current_project": "proj_abc123",
  "current_task": null,
  "created_at": 1707820000000,
  "last_seen_at": 1707835000000
}
```

---

## Entity Relationships

```
┌─────────────────────────────────────────────────────────────────┐
│                           USER (Agent)                          │
│                         role: user                              │
└────────────────────────────┬────────────────────────────────────┘
                             │ creates
                             ▼
┌─────────────────────────────────────────────────────────────────┐
│                          PROJECT                                │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │  owner_id → PM Agent (role: pm)                         │   │
│  │                                                         │   │
│  │  ┌─────────────────────────────────────────────────┐   │   │
│  │  │              GOAL 1                             │   │   │
│  │  │  owner_id → PM Agent                            │   │   │
│  │  │                                                 │   │   │
│  │  │  ┌───────────────┐  ┌───────────────┐          │   │   │
│  │  │  │   TASK 1      │  │   TASK 2      │          │   │   │
│  │  │  │   assigned_to │  │   assigned_to │          │   │   │
│  │  │  │   → WORKER 1  │  │   → WORKER 2  │          │   │   │
│  │  │  │   spawned_by  │  │   spawned_by  │          │   │   │
│  │  │  │   → PM Agent  │  │   → PM Agent  │          │   │   │
│  │  │  └───────────────┘  └───────────────┘          │   │   │
│  │  └─────────────────────────────────────────────────┘   │   │
│  │                                                         │   │
│  │  ┌─────────────────────────────────────────────────┐   │   │
│  │  │              GOAL 2                             │   │   │
│  │  │  ...                                            │   │   │
│  │  └─────────────────────────────────────────────────┘   │   │
│  └─────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────┘
```

### Relationship Rules

1. **Project Ownership**
   - A Project has one `owner_id` (PM Agent)
   - A Project has one `created_by` (User Agent)
   - A PM Agent can own multiple Projects

2. **Goal Ownership**
   - A Goal belongs to one Project (`project_id`)
   - A Goal has one `owner_id` (PM Agent)
   - A Project can have multiple Goals

3. **Task Assignment**
   - A Task belongs to one Goal (`goal_id`)
   - A Task belongs to one Project (`project_id`)
   - A Task has one `spawned_by` (PM Agent)
   - A Task has zero or one `assigned_to` (Worker Agent)
   - A Worker Agent can have zero or one active Task

4. **Progress Aggregation**
   - Goal progress = (completed_tasks / task_count) * 100
   - Project statistics aggregate from Goals and Tasks

---

## Protocol Messages

All messages are JSON-encoded and sent over WebSocket.

### Message Format

```json
{
  "type": "message.type",
  "id": "unique-request-id",
  "timestamp": 1234567890,
  "payload": { ... }
}
```

### Project Messages

#### project.create

**Request:**
```json
{
  "type": "project.create",
  "id": "req_001",
  "timestamp": 1707830400000,
  "payload": {
    "name": "Spiderweb Development",
    "description": "Build the AI gateway system",
    "config": {
      "auto_spawn_workers": true,
      "require_approval": true,
      "max_concurrent_workers": 3
    }
  }
}
```

**Response:**
```json
{
  "type": "project.create_response",
  "request_id": "req_001",
  "timestamp": 1707830400100,
  "payload": {
    "success": true,
    "project": {
      "id": "proj_abc123",
      "name": "Spiderweb Development",
      "description": "Build the AI gateway system",
      "status": "active",
      "owner_id": "agent_pm_001",
      "created_by": "user_deano",
      "created_at": 1707830400000,
      "updated_at": 1707830400000
    }
  }
}
```

#### project.list

**Request:**
```json
{
  "type": "project.list",
  "id": "req_002",
  "timestamp": 1707830400200,
  "payload": {
    "status_filter": null
  }
}
```

**Response:**
```json
{
  "type": "project.list_response",
  "request_id": "req_002",
  "timestamp": 1707830400300,
  "payload": {
    "projects": [
      {
        "id": "proj_abc123",
        "name": "Spiderweb Development",
        "status": "active",
        "goal_count": 5,
        "completed_goals": 2
      },
      {
        "id": "proj_def456",
        "name": "Game Project",
        "status": "paused",
        "goal_count": 10,
        "completed_goals": 3
      }
    ]
  }
}
```

#### project.get

**Request:**
```json
{
  "type": "project.get",
  "id": "req_003",
  "timestamp": 1707830400400,
  "payload": {
    "project_id": "proj_abc123"
  }
}
```

**Response:**
```json
{
  "type": "project.get_response",
  "request_id": "req_003",
  "timestamp": 1707830400500,
  "payload": {
    "success": true,
    "project": { ... },
    "goals": [ ... ]
  }
}
```

#### project.update

**Request:**
```json
{
  "type": "project.update",
  "id": "req_004",
  "timestamp": 1707830400600,
  "payload": {
    "project_id": "proj_abc123",
    "status": "paused",
    "config": {
      "max_concurrent_workers": 5
    }
  }
}
```

#### project.delete

**Request:**
```json
{
  "type": "project.delete",
  "id": "req_005",
  "timestamp": 1707830400700,
  "payload": {
    "project_id": "proj_abc123"
  }
}
```

---

### Goal Messages

#### goal.create

**Request:**
```json
{
  "type": "goal.create",
  "id": "req_006",
  "timestamp": 1707831000000,
  "payload": {
    "project_id": "proj_abc123",
    "title": "Implement worker spawn",
    "description": "Create the worker spawn system",
    "priority": 8
  }
}
```

**Response:**
```json
{
  "type": "goal.create_response",
  "request_id": "req_006",
  "timestamp": 1707831000100,
  "payload": {
    "success": true,
    "goal": {
      "id": "goal_xyz789",
      "project_id": "proj_abc123",
      "title": "Implement worker spawn",
      "status": "open",
      "priority": 8,
      "owner_id": "agent_pm_001",
      "progress_percent": 0,
      "created_at": 1707831000000
    }
  }
}
```

#### goal.list

**Request:**
```json
{
  "type": "goal.list",
  "id": "req_007",
  "timestamp": 1707831000200,
  "payload": {
    "project_id": "proj_abc123",
    "status_filter": null
  }
}
```

#### goal.get

**Request:**
```json
{
  "type": "goal.get",
  "id": "req_008",
  "timestamp": 1707831000300,
  "payload": {
    "goal_id": "goal_xyz789"
  }
}
```

**Response:**
```json
{
  "type": "goal.get_response",
  "request_id": "req_008",
  "timestamp": 1707831000400,
  "payload": {
    "success": true,
    "goal": { ... },
    "tasks": [ ... ]
  }
}
```

#### goal.update

**Request:**
```json
{
  "type": "goal.update",
  "id": "req_009",
  "timestamp": 1707831000500,
  "payload": {
    "goal_id": "goal_xyz789",
    "status": "in_progress",
    "priority": 9
  }
}
```

#### goal.delete

**Request:**
```json
{
  "type": "goal.delete",
  "id": "req_010",
  "timestamp": 1707831000600,
  "payload": {
    "goal_id": "goal_xyz789"
  }
}
```

---

### Task Messages

#### task.create

**Request:**
```json
{
  "type": "task.create",
  "id": "req_011",
  "timestamp": 1707832000000,
  "payload": {
    "goal_id": "goal_xyz789",
    "project_id": "proj_abc123",
    "description": "Design worker spawn API",
    "worker_type": "research",
    "priority": 9,
    "input_data": "{\"context\": \"Need to design the worker spawn API\"}"
  }
}
```

**Response:**
```json
{
  "type": "task.create_response",
  "request_id": "req_011",
  "timestamp": 1707832000100,
  "payload": {
    "success": true,
    "task": {
      "id": "task_def456",
      "goal_id": "goal_xyz789",
      "project_id": "proj_abc123",
      "description": "Design worker spawn API",
      "worker_type": "research",
      "status": "pending",
      "priority": 9,
      "spawned_by": "agent_pm_001",
      "progress_percent": 0,
      "created_at": 1707832000000
    }
  }
}
```

#### task.list

**Request:**
```json
{
  "type": "task.list",
  "id": "req_012",
  "timestamp": 1707832000200,
  "payload": {
    "project_id": "proj_abc123",
    "goal_id": null,
    "status_filter": "in_progress"
  }
}
```

#### task.get

**Request:**
```json
{
  "type": "task.get",
  "id": "req_013",
  "timestamp": 1707832000300,
  "payload": {
    "task_id": "task_def456"
  }
}
```

#### task.update

**Request:**
```json
{
  "type": "task.update",
  "id": "req_014",
  "timestamp": 1707832000400,
  "payload": {
    "task_id": "task_def456",
    "status": "in_progress",
    "progress_percent": 25,
    "progress_message": "Analyzing existing codebase..."
  }
}
```

#### task.delete

**Request:**
```json
{
  "type": "task.delete",
  "id": "req_015",
  "timestamp": 1707832000500,
  "payload": {
    "task_id": "task_def456"
  }
}
```

#### task.assign

**Request:**
```json
{
  "type": "task.assign",
  "id": "req_016",
  "timestamp": 1707832000600,
  "payload": {
    "task_id": "task_def456",
    "agent_id": "agent_worker_001"
  }
}
```

---

### Worker Messages

#### worker.spawn

**Request:**
```json
{
  "type": "worker.spawn",
  "id": "req_017",
  "timestamp": 1707833000000,
  "payload": {
    "task_id": "task_def456",
    "worker_type": "research",
    "context": "Focus on async execution patterns"
  }
}
```

**Response:**
```json
{
  "type": "worker.spawn_response",
  "request_id": "req_017",
  "timestamp": 1707833000100,
  "payload": {
    "success": true,
    "worker_id": "agent_worker_001",
    "task": {
      "id": "task_def456",
      "status": "in_progress",
      "assigned_to": "agent_worker_001",
      "started_at": 1707833000100
    }
  }
}
```

#### worker.status

**Request:**
```json
{
  "type": "worker.status",
  "id": "req_018",
  "timestamp": 1707833000200,
  "payload": {
    "worker_id": "agent_worker_001"
  }
}
```

**Response:**
```json
{
  "type": "worker.status_response",
  "request_id": "req_018",
  "timestamp": 1707833000300,
  "payload": {
    "success": true,
    "worker_id": "agent_worker_001",
    "status": "busy",
    "current_task": "task_def456"
  }
}
```

#### worker.progress (async notification)

```json
{
  "type": "worker.progress",
  "timestamp": 1707833000400,
  "worker_id": "agent_worker_001",
  "task_id": "task_def456",
  "percent": 50,
  "message": "Drafting API specification..."
}
```

#### worker.complete (async notification)

```json
{
  "type": "worker.complete",
  "timestamp": 1707833000500,
  "worker_id": "agent_worker_001",
  "task_id": "task_def456",
  "result_data": "{\"design\": \"...\", \"api_endpoints\": [...]}"
}
```

#### worker.failed (async notification)

```json
{
  "type": "worker.failed",
  "timestamp": 1707833000600,
  "worker_id": "agent_worker_001",
  "task_id": "task_def456",
  "error_message": "Failed to access codebase: permission denied"
}
```

---

### Chat Messages (OpenClaw Compatible)

#### chat.send

```json
{
  "type": "chat.send",
  "id": "req_019",
  "timestamp": 1707834000000,
  "content": "Implement the worker spawn system",
  "context": "proj_abc123"
}
```

#### chat.receive

```json
{
  "type": "chat.receive",
  "request_id": "req_019",
  "timestamp": 1707834001000,
  "content": "I'll analyze the requirements and create a plan for implementing the worker spawn system. This may take a few minutes.",
  "role": "assistant"
}
```

---

### Error Response

```json
{
  "type": "error",
  "request_id": "req_020",
  "timestamp": 1707835000000,
  "payload": {
    "code": "PROJECT_NOT_FOUND",
    "message": "Project with id 'proj_invalid' does not exist"
  }
}
```

---

## Example Flows

### Flow 1: Create Project → Spawn PM → Delegate Tasks

```
1. User creates project
   User → project.create → Spiderweb
   Spiderweb → project.create_response (with PM assigned)

2. PM analyzes project and creates goals
   PM Agent → goal.create ("Implement feature X")
   Spiderweb → goal.create_response

3. PM breaks down goals into tasks
   PM Agent → task.create ("Design API")
   PM Agent → task.create ("Implement handler")
   PM Agent → task.create ("Write tests")
   Spiderweb → task.create_response (x3)

4. PM spawns workers for tasks
   PM Agent → worker.spawn (task 1)
   Spiderweb → worker.spawn_response (worker_001 assigned)

5. Workers report progress
   Worker → worker.progress (25%)
   Worker → worker.progress (50%)
   Worker → worker.progress (75%)
   Worker → worker.complete (with results)

6. PM updates goal progress
   Spiderweb auto-updates goal.progress_percent based on task completion
   PM Agent → goal.update (status: completed when all tasks done)

7. PM reports to user
   PM Agent → chat.receive ("Goal completed: Implemented feature X")
```

### Flow 2: Worker Reports Progress → PM Updates Goal

```
1. Worker updates task progress
   Worker → task.update (progress_percent: 50, progress_message: "...")
   Spiderweb → task.update_response

2. Spiderweb recalculates goal progress
   Goal.progress_percent = (completed_tasks / task_count) * 100

3. If task completed:
   Worker → task.update (status: completed, result_data: "...")
   Spiderweb → updates goal.completed_tasks
   Spiderweb → recalculates goal.progress_percent

4. If all tasks completed:
   Spiderweb → goal.update (status: completed)

5. PM notifies user
   PM Agent → chat.receive ("All tasks for goal 'X' are complete")
```

---

## Storage Considerations

### Spiderweb Server Storage

For the MVP, Spiderweb uses simple JSON file storage:

```
~/.spiderweb/
├── projects/
│   ├── proj_abc123.json
│   ├── proj_def456.json
│   └── index.json          # Project list with metadata
├── goals/
│   ├── goal_xyz789.json
│   └── index_by_project/   # goal_xyz789 -> proj_abc123 mapping
├── tasks/
│   ├── task_def456.json
│   └── index_by_goal/
└── agents/
    ├── agent_pm_001.json
    └── agent_worker_001.json
```

**Future:** Migrate to SQLite or other DB for better querying.

### ZSS Client Caching

ZSS maintains a local cache for offline viewing:

```
~/.zss/
├── cache/
│   ├── projects.json       # Last known project list
│   ├── goals_<project_id>.json
│   └── tasks_<goal_id>.json
└── config.json
```

Cache is updated on each sync with Spiderweb.

---

## Extensibility

The data model is designed to be extended:

1. **New fields**: Add optional fields without breaking existing code
2. **New worker types**: Extend WorkerType enum
3. **New statuses**: Extend status enums
4. **Custom metadata**: Use JSON strings for flexible data (input_data, result_data)

### Future Extensions

- **Tags**: Add tagging to projects, goals, tasks
- **Dependencies**: Task A depends on Task B
- **Milestones**: Group goals into milestones
- **Time tracking**: Track time spent on tasks
- **Comments**: Add discussion threads to entities

---

## Files

- `src/protocol/types.zig` - Core data structures (Project, Goal, Task, Agent)
- `src/protocol/messages.zig` - Protocol message definitions
- `src/protocol/spiderweb.zig` - Protocol specifics and utilities
