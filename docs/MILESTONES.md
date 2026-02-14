# Spiderweb + ZSS Self-Hosting MVP Plan

> The goal: Use Spiderweb/ZSS to develop Spiderweb/ZSS.

## Success Criteria

The MVP is achieved when:
1. User can chat with ZSS: "Add a feature to log all chat messages"
2. PM Agent plans the work, spawns workers
3. Workers modify Spiderweb source code
4. Changes are tested (build passes)
5. User reviews and approves
6. Code is committed
7. System can continue operating with new feature

## Phase 0: Foundation (Current)

**Goal:** Basic connectivity, manual workflow

### Spiderweb v0.2 ✓
- [x] WebSocket server
- [x] Pi AI integration
- [x] Echo/chat response

### ZSS v0.1 (In Progress)
- [ ] Basic CLI
- [ ] Connect to Spiderweb
- [ ] Send/receive chat

### Milestone: "Hello World"
**Deliverable:** ZSS can chat with Spiderweb, get Pi AI responses

---

## Phase 1: Project Awareness

**Goal:** Spiderweb knows about its own codebase

### Spiderweb v0.3
- [ ] Project data model (goals, tasks)
- [ ] File system access (read source files)
- [ ] Code indexing (basic grep/symbol tracking)

### ZSS v0.2
- [ ] Project view (list goals/tasks)
- [ ] File browser (view source)
- [ ] Basic commands: `/project`, `/goal`, `/task`

### Milestone: "Know Thyself"
**Deliverable:** Can ask "What files are in the src/ directory?" and get accurate answer

**GitHub Issues:**
- `#1` - Design project/goal/task data model
- `#2` - Implement file system access in Spiderweb
- `#3` - Add project commands to ZSS
- `#4` - Create code indexer (symbol extraction)

---

## Phase 2: Worker Spawn

**Goal:** Can spawn workers that do things

### Spiderweb v0.4
- [ ] Job queue
- [ ] Worker pool (execute commands)
- [ ] Worker types: `research`, `implement`, `test`
- [ ] Worker progress reporting

### ZSS v0.3
- [ ] Display worker progress
- [ ] Show active workers
- [ ] Worker output in chat

### Milestone: "First Worker"
**Deliverable:** Can say "Research how to add logging" and get a worker that searches codebase, reports findings

**GitHub Issues:**
- `#5` - Implement job queue in Spiderweb
- `#6` - Create worker pool
- `#7` - Define worker types and lifecycle
- `#8` - Add worker progress UI to ZSS

---

## Phase 3: Code Modification

**Goal:** Workers can modify source code

### Spiderweb v0.5
- [ ] File modification API (safe writes)
- [ ] Git integration (stage, diff, commit)
- [ ] Code templates (for common patterns)
- [ ] Validation (build after changes)

### ZSS v0.4
- [ ] Review changes UI (diff view)
- [ ] Approve/reject workflow
- [ ] Commit on approval

### Milestone: "First Edit"
**Deliverable:** Can say "Add a comment to main.zig" and see the change, approve it, have it committed

**GitHub Issues:**
- `#9` - Safe file modification API
- `#10` - Git integration (libgit2 or git CLI)
- `#11` - Build validation after changes
- `#12` - Change review UI in ZSS

---

## Phase 4: Self-Hosting Loop

**Goal:** Full self-modification cycle

### Spiderweb v0.6
- [ ] PM Agent with planning capability
- [ ] Task breakdown (goals → tasks)
- [ ] Pro-active behavior (plan ahead when blocked)
- [ ] Error recovery (retry, report)

### ZSS v0.5
- [ ] Goal creation from chat
- [ ] Project dashboard
- [ ] Memory integration (`/new`, recall)

### Milestone: "Self-Hosting MVP"
**Deliverable:** Can say "Add logging to track all incoming WebSocket messages" and:
1. PM plans: "1. Find WebSocket handler, 2. Add logging, 3. Test"
2. Workers execute each step
3. Changes shown for review
4. User approves
5. Code committed and tested
6. System continues working

**GitHub Issues:**
- `#13` - Implement PM Agent planning
- `#14` - Task breakdown logic
- `#15` - Pro-active worker behavior
- `#16` - Self-hosting end-to-end test

---

## Phase 5: Polish

**Goal:** Production-ready for dogfooding

### Spiderweb v1.0
- [ ] Virtual filesystem (FUSE)
- [ ] Memory system (chat storage/recall)
- [ ] Multiple node support
- [ ] Robust error handling

### ZSS v1.0
- [ ] TUI (not just REPL)
- [ ] Canvas integration
- [ ] File editor integration

### Milestone: "Daily Driver"
**Deliverable:** Use Spiderweb/ZSS for all Spiderweb/ZSS development

---

## GitHub Issues Template

Each issue should have:
- **Label:** `spiderweb`, `zss`, `protocol`, `ui`, `core`
- **Milestone:** One of Phase 0-5
- **Size:** `small`, `medium`, `large`
- **Dependencies:** Other issues that must be done first

Example:
```
Title: Implement job queue in Spiderweb
Labels: spiderweb, core
Milestone: Phase 2 - Worker Spawn
Size: medium
Dependencies: #1 (data model)
```

## Next Steps

1. Create GitHub repos for ZiggyStarSpider
2. Create issues for Phase 0-1 (immediate work)
3. Set up milestones in GitHub
4. Start with #1: Design project data model

Want me to create the initial GitHub issues as a batch?