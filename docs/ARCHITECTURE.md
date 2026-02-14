# ZiggyStarSpider Architecture

> Design principles and protocol specification for the Spiderweb-native client.

## Core Philosophy

**User-first, project-oriented.** Unlike chat assistants that wait for messages, Spiderweb agents work on user goals with pro-active planning and reporting.

## Architecture Principles

### 1. Chat-First Interface
All agent activity surfaces in chat. The user always knows what the agent is doing.

```
User: "Refactor the rendering system"
    ↓
Agent: "I'll analyze the current code and plan the refactor. This may take a few minutes."
    ↓
[Worker spawned: analyze_rendering_code]
[Worker complete: Found 12 files using RenderContext]
    ↓
Agent: "Found 12 files. Here's my plan:
        1. Extract RenderContext interface
        2. Migrate OpenGL backend
        3. Update tests
        Proceed? (yes/no/modify)"
```

### 2. Soft Workflows
AI-driven execution rather than rigid pipelines.

- **Goals, not scripts** - Agent decides implementation path
- **Adaptive** - If approach fails, tries alternatives
- **Human gates** - Significant changes require approval
- **Transparent** - Agent explains reasoning in chat

### 3. Memory Model

Three distinct concepts OpenClaw conflates:

| Concept | Scope | Persistence |
|---------|-------|-------------|
| **Current Chat** | Active conversation | Yes (for continuity) |
| **Working Memory** | Task context, partial results | Ephemeral (task lifetime) |
| **Long-term Memory** | Past chats, lessons learned | Searchable, retrievable |

**Chat lifecycle:**
```
Chat 1: "Design the asset pipeline"
    ↓
/new  → Chat 1 stored to memory
    ↓  
Chat 2: "Implement texture compression"
    ↓
"Continue yesterday's pipeline discussion"
    ↓
Memory recall → Chat 1 context loaded into Chat 2
```

### 4. Virtual Filesystem

Plan9/Inferno-style unified namespace aggregating multiple backends.

```
/spiderweb/
├── workspace/              # Agent's working directory
├── nodes/
│   ├── user-windows/       # Windows machine (WebSocket node)
│   │   └── D:/Projects/
│   ├── user-mac/           # Mac via node
│   └── build-server/       # Remote builder
├── cloud/
│   ├── dropbox/
│   └── s3-bucket/
└── shared/
    └── assets/             # Game textures, sounds
```

**Benefits:**
- Game dev: Agent reads textures from Windows D:, processes, writes to cloud
- No SFTP/SMB: Uses existing WebSocket node transport
- Unified: Agent uses normal file operations regardless of backend

### 5. Hierarchical Agency

```
User (sets goals, direction)
    ↓
PM Agent (orchestrates)
    ├── Plans approach
    ├── Spawns workers
    ├── Handles blockers
    └── Reports to user
        ↓
Workers (execute)
    ├── Research workers
    ├── Implementation workers
    └── Test workers
```

**Pro-active when blocked:**
- Current tasks blocked? PM adds speculative work that fits project
- Always reports: "Couldn't do X, so I started Y which helps with Z"

## Protocol Design

### Message Types

**OpenClaw Compatible:**
- `connect` / `chat_ack` - Connection handshake
- `chat_send` / `chat_receive` - Messaging
- `ping` / `pong` - Heartbeat

**Spiderweb Extensions:**

**Project Management:**
```zig
project_create { name, description }
project_list { }
project_update { id, status }
goal_create { project_id, description, priority }
goal_complete { id, result }
```

**Worker Management:**
```zig
worker_spawn { task_description, type }
worker_progress { task_id, percent, message }
worker_complete { task_id, result }
worker_failed { task_id, error }
```

**Memory:**
```zig
memory_store { kind, content, tags }
memory_recall { query, limit }
memory_search { keywords }
```

**Virtual Filesystem:**
```zig
vfs_mount { name, backend_type, config }
vfs_unmount { mount_point }
vfs_list { path }
```

## Client State

Simpler than OpenClaw - no session management:

```zig
ClientContext {
    chat: ChatState,           // Current conversation
    projects: ProjectContext,  // Goals, tasks
    workers: []Task,           // Active workers
    vfs: []Mount,              // Mounted filesystems
}
```

## Roadmap

### v0.1 - Foundation
- [ ] Basic connection to Spiderweb
- [ ] Chat send/receive
- [ ] Simple project commands

### v0.2 - Worker Support
- [ ] Display worker progress
- [ ] Task list view
- [ ] Goal tracking

### v0.3 - Virtual Filesystem
- [ ] Mount/unmount commands
- [ ] File browser UI
- [ ] Cross-platform path handling

### v0.4 - Memory
- [ ] /new command
- [ ] Memory recall
- [ ] Search interface

### v1.0 - Complete
- [ ] Full pro-active agent support
- [ ] TUI with project dashboard
- [ ] Canvas integration

## Comparison

### ZiggyStarSpider vs ZiggyStarClaw

| | ZSC (OpenClaw) | ZSS (Spiderweb) |
|---|---|---|
| **Protocol** | OpenClaw | Spiderweb (extended) |
| **Focus** | Chat channels | Project goals |
| **Session** | Multiple channels | Single chat + memory |
| **Agent** | Reactive | Pro-active |
| **Use case** | General assistant | Project work, game dev |

Both share `ziggy-core` for common components.

## Open Questions

1. **Protocol versioning** - How to extend without breaking OpenClaw compatibility?
2. **Error handling** - Graceful degradation when Spiderweb features unavailable?
3. **File sync** - How much to cache vs stream for VFS?
4. **Security** - Node authentication for VFS mounts?

---

*This doc evolves with implementation. Update as decisions are made.*
