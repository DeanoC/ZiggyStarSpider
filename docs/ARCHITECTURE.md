# SpiderApp Architecture

## Scope

SpiderApp is the user-facing client (CLI + GUI) for Spiderweb workspace control, topology inspection, and mount-style filesystem access.

Primary goals:

1. Connect to Spiderweb using unified-v2.
2. Manage project context (list/get/create/use/activate).
3. Surface node topology and effective project mounts.
4. Route filesystem and capability IO through `control.mount_*`.

## Protocol Model

### Unified-v2 only

No legacy compatibility path is maintained in this client.

### Channels

- `control`:
  - out-of-band control API and topology/workspace operations
  - includes handshake and workspace/node/status control calls
  - also carries the mount-style filesystem message types `control.mount_attach`, `control.mount_file_read`, and `control.mount_file_write`

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
2. mount-style filesystem operations (`fs`)
3. package lifecycle control via `/.spiderweb/control/packages`

Workspace context handling:

- workspace id from `--workspace` or saved config
- workspace token from `--workspace-token` or saved per-workspace token
- activation via `control.workspace_activate` when token is available

## GUI Architecture

`src/gui/root.zig` maintains:

- connection state and handshake lifecycle
- settings panel project selection/token controls
- onboarding wizard (`connect -> project -> mounts -> activate`)
- topology cache (projects, nodes, mounts, drift/status)
- filesystem browser panel (path navigation + preview)
- non-blocking filesystem worker thread (dedicated control websocket + request/result queues)
- incremental per-path filesystem cache (lazy load by navigated path, explicit refresh invalidation)
- chat/jobs are intentionally deferred from the current public filesystem contract while their redesign is in progress

The GUI refreshes project topology from control-plane APIs and shows selected project + mount state alongside chat.

## Filesystem + Capability Flow

Mount-style filesystem access uses:

1. `control.version`
2. `control.connect`
3. `control.mount_attach` to snapshot a requested path
4. `control.mount_file_read` / `control.mount_file_write` for file IO

The public workspace contract exposed through that transport is:

- `/.spiderweb/control/*`
- `/.spiderweb/catalog/*`
- `/.spiderweb/venoms/VENOMS.json`
- `/.spiderweb/venoms/{terminal,git,search_code}`

SpiderApp reads `/.spiderweb/venoms/VENOMS.json` and the catalog files to discover the currently bound public capability set. Control substrate items like packages and runtimes are not presented as venoms.

## Current Limitations

- Interactive CLI REPL remains unimplemented.
- GUI smoke is currently validated by build + scripted workflow checks (not full headless rendering assertions).
- Chat/jobs remain intentionally out of the current public filesystem contract until the redesign lands.
