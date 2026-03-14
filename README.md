# SpiderApp

Client for the Spiderweb AI agent system.

## Overview

SpiderApp exposes a workspace-first view of a distributed Spiderweb:

- connect to Spiderweb over WebSocket
- select or create workspaces
- configure workspace mounts and binds
- generate worker handoff commands
- inspect Spider nodes topology

## Build

```bash
git submodule update --init --recursive
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

### macOS App Bundle

```bash
./scripts/package-macos-app.sh
```

This creates:
- `zig-out/SpiderApp.app`
- `zig-out/SpiderApp-macos-arm64.zip`

Terminal backend notes:
- build option sets the default (`plain` or `ghostty-vt`)
- runtime selection is available in **Settings -> Terminal renderer**
- selection is persisted in config when using **Save Config**

## CLI Quickstart

```bash
# Connect
spider --url ws://127.0.0.1:18790 connect

# Workspace control
spider workspace list
spider --operator-token op-secret workspace create --template dev "Distributed Workspace" "unified mounts"
spider workspace use ws-demo ws-token-abc
spider workspace template list
spider workspace bind list
spider workspace handoff show codex_app

# Topology
spider node list
spider node info node-1

# Unified filesystem access
spider fs ls /
spider fs tree /
spider fs read /nodes/local/fs/README.md

# Agent chat via FS-RPC capability path
spider chat send "summarize current mounts"

# Session control
spider session list
spider session history --limit 5
spider session attach review mother --workspace system
spider session resume review
spider session restore
```

Useful options:

- `--workspace <workspace_id>`
- `--workspace-token <token>`
- `--operator-token <token>`
- `--url <ws-url>`

## GUI Highlights

- server connect/disconnect
- workspace ID + workspace token selection
- onboarding wizard (`connect -> workspace -> mounts -> binds -> handoff`)
- workspace refresh + activate workspace actions
- live workspace/node/mount summary in settings
- filesystem browser panel with path navigation and text preview
- chat activation only after attaching a Spiderweb session to the selected workspace
- debug stream panel

## Protocol Notes

- unified-v2 only (no legacy compatibility path)
- control handshake: `control.version` then `control.connect`
- control-plane examples:
  - `control.workspace_list`
  - `control.workspace_get`
  - `control.workspace_create`
  - `control.workspace_activate`
  - `control.workspace_template_list`
  - `control.workspace_bind_set`
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
