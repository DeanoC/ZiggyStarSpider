# Session Commands

Session commands operate on unified-v2 control-plane session bindings.

## session list

List known sessions on the current connection and show the active session.

**Examples:**
```bash
ziggystarspider session list
ziggystarspider session history
```

## session status [session_key]

Show attach/runtime state for a session. Without `session_key`, uses the active session.

**Examples:**
```bash
ziggystarspider session status
ziggystarspider session status main
```

## session attach <session_key> <agent_id> [--project <project_id>] [--project-token <token>]

Create or rebind a session to an agent (and optional project context).

**Examples:**
```bash
ziggystarspider session attach review mother --project system
ziggystarspider session attach work bob --project proj-2 --project-token proj-secret
```

## session resume <session_key>

Switch the active session to an existing session key.

**Examples:**
```bash
ziggystarspider session resume main
ziggystarspider session resume review
```

## session close <session_key>

Close a non-`main` session.

**Examples:**
```bash
ziggystarspider session close review
```
