# Global Options

## Connection Options

### `--url <url>`
Spiderweb server WebSocket URL.

**Default:** `ws://127.0.0.1:18790`

**Examples:**
```bash
spider --url ws://100.101.192.123:18790 chat send "Hello"
spider --url ws://localhost:18790 workspace list
```

### `--workspace <workspace_id>`
Set the current workspace for this session.

**Examples:**
```bash
spider --workspace ws-demo workspace status
spider --workspace mygame chat send "What's next?"
```

### `--workspace-token <token>`
Workspace token used for `control.workspace_activate`.

If provided with `workspace use`, the token is also persisted in local config for that workspace.

**Examples:**
```bash
spider --workspace ws-demo --workspace-token ws-secret workspace status
spider --workspace-token ws-secret workspace use ws-demo
```

### `--operator-token <token>`
Operator token used for protected control mutations (for example `control.workspace_create`).

If omitted, SpiderApp CLI uses the saved admin role token when available.

### `--role <admin|user>`
Select which saved role token is used for connection/auth on this command.

If omitted, SpiderApp CLI uses the locally saved active role.

**Examples:**
```bash
spider --operator-token op-secret workspace create demo "Distributed workspace"
spider --operator-token op-secret workspace create "Game AI"
```

## Mode Options

### `--interactive`
Start interactive REPL mode instead of running a single command.

Note: the interactive REPL is not implemented yet; command mode is currently required.

**Examples:**
```bash
spider --interactive
spider --url ws://remote:18790 --interactive
```

### `--verbose`
Enable verbose debug logging.

**Examples:**
```bash
spider --verbose chat send "Test"
spider --verbose --interactive
```

## Information Options

### `--help`
Show help message and exit.

### `--version`
Show version information and exit.
