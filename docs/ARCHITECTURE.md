# ZiggyStarSpider Architecture

## Scope

ZiggyStarSpider is the user-facing client (CLI + GUI) for Spiderweb distributed workspace control and FS-RPC access.

Primary goals:

1. Connect to Spiderweb using unified-v2.
2. Manage project context (list/get/create/use/activate).
3. Surface node topology and workspace mounts.
4. Route filesystem and capability IO through `acheron.*`.

## Protocol Model

### Unified-v2 only

No legacy compatibility path is maintained in this client.

### Channels

- `control`:
  - out-of-band control API and topology/project operations
  - includes handshake and project/node/workspace control calls
- `acheron`:
  - filesystem transport (`t_walk`, `t_open`, `t_read`, `t_write`, etc.)
  - capability IO (for example chat via `/capabilities/chat/control/input`)

### Required control handshake

All control/FS-RPC work starts with:

1. `control.version` with payload `{"protocol":"unified-v2"}`
2. `control.connect`

This is centralized in `src/client/unified_v2_client.zig` and wrapped by `src/client/control_plane.zig`.

## Client Modules

### `src/client/unified_v2_client.zig`

- control request envelope build/send
- request/response correlation by `id`
- handshake helper (`control.version` + `control.connect`)
- control timeout handling and payload extraction

### `src/client/control_plane.zig`

Typed control-plane operations:

- `listProjects`
- `getProject`
- `createProject`
- `activateProject`
- `reconcileStatus`
- `listNodes`
- `getNode`
- `workspaceStatus`

### `src/client/workspace_types.zig`

Shared typed models for CLI and GUI:

- `ProjectSummary`
- `ProjectDetail`
- `NodeInfo`
- `WorkspaceStatus`
- `MountView`
- `DriftItem`
- `ReconcileStatus`

### `src/client/config.zig`

Persistent local state:

- server/auth defaults
- selected project
- per-project tokens
- GUI preferences/theme/profile

## CLI Architecture

`src/cli/main.zig` maps noun/verb commands to:

1. control-plane operations (`project`, `node`, `workspace`)
2. FS-RPC filesystem operations (`fs`)
3. FS-RPC chat capability flow (`chat send`)

Project context handling:

- project id from `--project` or saved config
- project token from `--project-token` or saved per-project token
- activation via `control.project_activate` when token is available

## GUI Architecture

`src/gui/root.zig` maintains:

- connection state and handshake lifecycle
- settings panel project selection/token controls
- onboarding wizard (`connect -> project -> mounts -> activate`)
- workspace topology cache (projects, nodes, mounts)
- filesystem browser panel (path navigation + preview)
- non-blocking filesystem worker thread (dedicated FS-RPC websocket + request/result queues)
- incremental per-path filesystem cache (lazy load by navigated path, explicit refresh invalidation)
- async chat worker that applies project context before FS-RPC chat IO
- reconnect-aware chat job resume handling

The GUI refreshes workspace topology from control-plane APIs and shows selected project + mount state alongside chat.

## Filesystem + Capability Flow

FS-RPC bootstrap sequence:

1. `acheron.t_version`
2. `acheron.t_attach` (root fid)

Then path-based operations:

- `t_walk` to target path/capability file
- `t_open`
- `t_read` / `t_write`
- `t_clunk` for fid cleanup

Chat currently uses capability path:

- write prompt to `/capabilities/chat/control/input`
- read result from `/jobs/<job>/result.txt`
- resume from `/jobs/<job>/status.json` after reconnect when needed

## Current Limitations

- Interactive CLI REPL remains unimplemented.
- GUI smoke is currently validated by build + scripted workflow checks (not full headless rendering assertions).
