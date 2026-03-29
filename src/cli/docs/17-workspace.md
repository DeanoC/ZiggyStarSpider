# Workspace Commands

Workspaces are the top-level organization for development flow in Spiderweb.

## workspace list

List all workspaces.

## workspace use <workspace_id> [workspace_token]

Select a workspace and optionally activate it.

## workspace create <name> [vision]

Create a new workspace. SpiderApp defaults new workspaces to the `dev` template, or use `--template <template_id>`.

## workspace info <workspace_id>

Show details for one workspace.

## workspace up <name>

Create or update a workspace and seed desired mounts and binds in one command.

Useful flags:
- `--template <template_id>` - Select a workspace template
- `--mount <mount_path>=<node_id>:<export_name>` - Add a desired mount
- `--bind <bind_path>=<target_path>` - Add a desired bind
- `--workspace-id <workspace_id>` - Update an existing workspace

## workspace doctor

Run readiness checks for nodes, workspace selection, mounts, drift, and reconcile state.

## workspace template list

List available workspace templates.

## workspace template info <template_id>

Show one template and its default binds.

## workspace bind list [workspace_id]

List the configured binds for a workspace.

## workspace bind add <bind_path> <target_path>

Bind a service or filesystem path into the selected workspace.

## workspace bind remove <bind_path>

Remove a bind from the selected workspace.

## workspace mount list [workspace_id]

List configured mounts for a workspace.

## workspace mount add <mount_path> <node_id> <export_name>

Add a mount to the selected workspace.

## workspace mount remove <mount_path> [node_id export_name]

Remove a mount from the selected workspace.

## workspace handoff show [generic|codex_app|spider_monkey]

Generate mount and external tool startup commands for an external handoff.

## workspace status [workspace_id]

Show the current workspace mount topology and mounted node exports.

**Examples:**
```bash
spider workspace list
spider workspace create "Distributed Workspace"
spider workspace create --template github "PR Review Workspace"
spider workspace use ws-demo ws-token-abc
spider workspace template list
spider workspace bind add /.spiderweb/venoms/git /nodes/node-1/venoms/git
spider workspace mount add /workspace node-1 work
spider workspace up "Distributed Workspace" --template dev --mount /workspace=node-1:work --bind /.spiderweb/venoms/git=/nodes/node-1/venoms/git
spider workspace doctor
spider workspace handoff show codex_app --mount-path ./workspace
spider workspace status
spider --verbose workspace status
spider workspace status ws-demo
spider --workspace ws-demo workspace status
```

`--verbose` also prints reconcile diagnostics (`state`, `queue_depth`, `failed_ops`, totals).
