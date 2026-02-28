# ZiggyStarSpider Operator Runbook

This runbook is for operating a distributed Spiderweb workspace from ZiggyStarSpider (CLI + GUI) using unified-v2.

## 1. Preconditions

- Spiderweb is reachable at a WebSocket URL (for example `ws://127.0.0.1:18790`).
- At least one filesystem node is registered in Spiderweb.
- If operator/project token gates are enabled, tokens are available.

## 2. Auth Setup + Rotation

Spiderweb uses two main roles (`admin`, `user`). ZiggyStarSpider stores them in local config as role-specific secrets.

CLI:

```bash
zss auth status
zss auth status --reveal
zss auth rotate admin
zss auth rotate user --reveal
```

Notes:
- `auth status` is masked by default.
- `auth rotate` stores rotated role tokens locally.
- GUI project panel includes `Auth Status`, `Reveal Admin/User`, and `Copy Admin/User` actions.

## 3. Basic Bring-Up (CLI)

```bash
zss --url ws://127.0.0.1:18790 connect
zss --url ws://127.0.0.1:18790 node list
zss --url ws://127.0.0.1:18790 project up "My Project"
zss --url ws://127.0.0.1:18790 --verbose workspace status
```

Expected outcome:
- `node list` returns at least one node.
- `project up` prints `project up complete`.
- `workspace status` shows project id, workspace root, desired/actual mounts, drift, and reconcile diagnostics.

## 4. Filesystem Validation

```bash
zss --url ws://127.0.0.1:18790 fs ls /
zss --url ws://127.0.0.1:18790 fs tree / --max-depth 2
zss --url ws://127.0.0.1:18790 fs read /capabilities/chat/control/help
```

Expected outcome:
- root and mount paths are visible.
- `fs tree` recursively traverses within depth.
- capability help file is readable.

## 5. Chat Capability Validation

```bash
zss --url ws://127.0.0.1:18790 chat send "summarize active mounts"
```

If the request is queued or interrupted, use:

```bash
zss --url ws://127.0.0.1:18790 chat resume
zss --url ws://127.0.0.1:18790 chat resume <job-id>
```

## 6. GUI Bring-Up

1. Run `zig build run-gui` (or launch `zig-out/bin/zss-gui`).
2. In Settings:
   - set server URL
   - choose connect role (`Admin` or `User`)
   - connect
   - select project
   - refresh workspace
   - activate project
3. Use the onboarding wizard steps in Settings (`connect -> project -> mounts -> activate`).
4. Open the `Filesystem Browser` panel from Settings.
5. Open the `Debug Stream` panel for control/acheron/audit visibility.

## 7. Reconnect + Resume Behavior

- If control connection drops during chat, reconnect from Settings.
- Pending job/result retrieval is resumed automatically when possible.
- If required, inspect jobs through CLI `chat resume`.

If `session_attach` fails with `session_busy`, wait for in-flight jobs to finish before switching project/agent context.

## 8. Smoke Matrix

Use the scripted matrix when you want one command that checks all critical surfaces:

```bash
./scripts/smoke-matrix.sh
```

Useful env vars:
- `SPIDERWEB_URL`
- `SMOKE_SKIP_BUILD=1`
- `SMOKE_SKIP_GUI_BUILD=1`
- `SMOKE_SKIP_CHAT=1`
- `SMOKE_SKIP_AUTH_SESSION=1`
- `SMOKE_ADMIN_TOKEN=<token>`
- `SMOKE_USER_TOKEN=<token>`

Auth/session-only smoke checks:

```bash
./scripts/smoke-auth-session.sh
```
