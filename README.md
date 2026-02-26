# ZiggyStarSpider

Native CLI + GUI client for ZiggySpiderweb unified-v2 control and FS-RPC.

## Overview

ZiggyStarSpider exposes one project-oriented view of a distributed Spiderweb workspace:

- connect to Spiderweb over WebSocket
- select or create projects
- activate project workspace mounts
- inspect nodes and workspace topology
- browse and read/write the unified filesystem via `acheron.*`
- chat with the agent through FS-RPC chat capabilities

`control.*` is used for out-of-band control API operations.  
`acheron.*` is used for filesystem and capability IO.

## Build

```bash
zig build
zig build test
```

### CLI

```bash
zig build
./zig-out/bin/ziggystarspider --help
```

### GUI

```bash
zig build gui
zig build run-gui
```

GUI binary: `zig-out/bin/zss-gui`

## CLI Quickstart

```bash
# Connect
ziggystarspider connect --url ws://127.0.0.1:18790

# Project control
ziggystarspider project list
ziggystarspider --operator-token op-secret project create "Distributed Workspace" "unified mounts"
ziggystarspider project use proj-1 proj-token-abc
ziggystarspider workspace status

# Topology
ziggystarspider node list
ziggystarspider node info node-1

# Unified filesystem access
ziggystarspider fs ls /
ziggystarspider fs tree /spiderweb
ziggystarspider fs read /spiderweb/projects/proj-1/workspace/README.md

# Agent chat via FS-RPC capability path
ziggystarspider chat send "summarize current mounts"

# Session control
ziggystarspider session list
ziggystarspider session attach review mother --project system
ziggystarspider session resume review
```

Useful options:

- `--project <project_id>`
- `--project-token <token>`
- `--operator-token <token>`
- `--url <ws-url>`

## GUI Highlights

- server connect/disconnect
- project ID + project token selection
- onboarding wizard (`connect -> project -> mounts -> activate`)
- workspace refresh + activate project actions
- live project/node/mount summary in settings
- filesystem browser panel with path navigation and text preview
- chat send/receive bound to selected project context
- debug stream panel

## Protocol Notes

- unified-v2 only (no legacy compatibility path)
- control handshake: `control.version` then `control.connect`
- control-plane examples:
  - `control.project_list`
  - `control.project_get`
  - `control.project_create`
  - `control.project_activate`
  - `control.workspace_status`
  - `control.node_list`
  - `control.node_get`
- FS-RPC examples:
  - `acheron.t_version` / `acheron.r_version`
  - `acheron.t_attach` / `acheron.r_attach`
  - `acheron.t_walk`, `acheron.t_open`, `acheron.t_read`, `acheron.t_write`, `acheron.t_stat`, `acheron.t_clunk`

## Docs

- `docs/ARCHITECTURE.md`
- `docs/OPERATOR_RUNBOOK.md`
- `docs/TROUBLESHOOTING.md`
- `docs/DATA_MODEL.md`
- `docs/MILESTONES.md`

## Smoke Matrix

```bash
./scripts/smoke-matrix.sh
```

Environment knobs:
- `SPIDERWEB_URL`
- `SMOKE_SKIP_BUILD=1`
- `SMOKE_SKIP_GUI_BUILD=1`
- `SMOKE_SKIP_CHAT=1`

## License

MIT - See `LICENSE`
