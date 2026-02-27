# ZiggyStarSpider CLI

## Usage

```text
ziggystarspider <noun> <verb> [args] [options]
ziggystarspider --help
```

## Noun-Verb Commands

- `chat send <message>` - Send a message to the AI
- `chat history` - Show recent chat history
- `chat resume [job_id]` - Resume/inspect queued chat jobs
- `fs ls <path>` - List entries for a virtual filesystem path
- `fs tree [path] [--max-depth N] [--files-only|--dirs-only]` - Recursive directory walk
- `fs read <path>` - Read a virtual filesystem file
- `fs write <path> <content>` - Write text to a virtual filesystem file
- `fs stat <path>` - Show file metadata for a virtual filesystem path
- `project list` - List all projects
- `project use <project_id> [project_token]` - Select/activate a project
- `project info <project_id>` - Show project details
- `project create <name> [vision]` - Create a project and store selection/token locally
- `project up <name>` - One-shot project + mount bootstrap
- `project doctor` - Readiness checks with actionable failures
- `agent list` - List discoverable agents
- `agent info <agent_id>` - Show one agent's metadata
- `session list` - List known sessions for this connection
- `session history [agent_id] [--limit N]` - List persisted sessions
- `session status [session_key]` - Show attach/runtime state for a session
- `session attach <session_key> <agent_id>` - Create/rebind a session
- `session resume <session_key>` - Switch active session
- `session close <session_key>` - Close a non-main session
- `session restore [agent_id]` - Attach the latest persisted session
- `node list` - List registered nodes
- `node info <node_id>` - Show node details
- `node join-request <node_name> [fs_url]` - Submit pending node join request
- `node pending` - List pending node join requests
- `node approve <request_id>` - Approve pending node join request
- `node deny <request_id>` - Deny pending node join request
- `node service-get <node_id>` - Show node service catalog
- `node service-upsert <node_id> <node_secret>` - Update node service catalog metadata
- `node service-runtime <node_id> <service_id> <action>` - Read/write runtime control files for a service mount
- `pairing pending` - Refresh and list pending pairing join requests
- `pairing approve <request_id> [--lease-ttl-ms <ms>]` - Approve pending pairing request
- `pairing deny <request_id>` - Deny pending pairing request
- `pairing list` - Refresh and list active pairing invites
- `pairing create [--expires-in-ms <ms>]` - Create a new pairing invite
- `pairing refresh [pending|invites|all]` - Refresh pairing snapshots and print results
- `workspace status [project_id]` - Show active workspace mounts
- `auth status` - Show Spiderweb auth token status (admin only)
- `auth rotate <admin|user>` - Rotate Spiderweb auth token (admin only)
- `goal list` - List goals for current project
- `goal create <description>` - Create a new goal
- `task list` - List active tasks
- `worker list` - Show running workers
- `connect` - Connect to Spiderweb
- `disconnect` - Disconnect from Spiderweb

## Global Options

- `--url <url>` - Spiderweb server URL (default: ws://127.0.0.1:18790)
- `--project <project_id>` - Set current project
- `--project-token <token>` - Token used to activate project context
- `--operator-token <token>` - Token for operator-scoped control mutations (for example `project create`)
- `--role <admin|user>` - Select saved auth role token for this command
- `--interactive` - Start interactive REPL mode
- `--verbose` - Enable verbose logging
- `--help` - Show this help
- `--version` - Show version

## Interactive Mode

Interactive mode entry exists, but the REPL is not implemented yet.

Current behavior:

```
ziggystarspider --url ws://100.101.192.123:18790

Interactive mode not yet implemented.
Use command mode for now.
```

## Design Philosophy

ZSS uses a noun-verb command structure:
- **Noun** = What you're acting on (chat, project, goal, task)
- **Verb** = What you're doing (send, list, create, use)

This makes commands discoverable and consistent.
