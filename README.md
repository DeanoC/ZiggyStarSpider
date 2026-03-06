# SpiderApp

Client for the Spiderweb AI agent system.

## Overview

SpiderApp exposes a project-oriented view of a distributed Spiderweb:

- connect to Spiderweb over WebSocket
- select or create projects
- activate project mounts
- inspect Spider nodes topology

## Build

```bash
zig build
zig build test
```

### CLI

```bash
zig build
./zig-out/bin/spider --help
```

### GUI

```bash
zig build gui
zig build run-gui
# optional backend selection (uses libghostty-vt dynamically when available)
zig build gui -Dterminal-backend=ghostty-vt
```

GUI binary: `zig-out/bin/spider-gui`

Terminal backend notes:
- build option sets the default (`plain` or `ghostty-vt`)
- runtime selection is available in **Settings -> Terminal renderer**
- selection is persisted in config when using **Save Config**

## CLI Quickstart

```bash
# Connect
spider connect --url ws://127.0.0.1:18790

# Project control
spider project list
spider --operator-token op-secret project create "Distributed Workspace" "unified mounts"
spider project use proj-1 proj-token-abc
spider workspace status

# Topology
spider node list
spider node info node-1

# Unified filesystem access
spider fs ls /
spider fs tree /spiderweb
spider fs read /spiderweb/projects/proj-1/workspace/README.md

# Agent chat via FS-RPC capability path
spider chat send "summarize current mounts"

# Session control
spider session list
spider session history --limit 5
spider session attach review mother --project system
spider session resume review
spider session restore
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
# GUI terminal backend matrix (Linux + Windows/Wine startup)
./scripts/smoke-gui-terminal-backends.sh
```

Environment knobs:
- `SPIDERWEB_URL`
- `SMOKE_SKIP_BUILD=1`
- `SMOKE_SKIP_GUI_BUILD=1`
- `SMOKE_SKIP_CHAT=1`
- `SMOKE_SKIP_WINDOWS=1` (for `smoke-gui-terminal-backends.sh`)

## License

MIT - See `LICENSE`
