# Workspace Commands

Workspace status shows the currently effective project mounts for the current agent.

## workspace status [project_id]

Show the current project's effective mount topology and mounted node exports.

**Arguments:**
- `project_id` (optional) - Resolve status for a specific project

**Examples:**
```bash
spider workspace status
spider --verbose workspace status
spider workspace status proj-1
spider --project proj-1 workspace status
```

`--verbose` also prints reconcile diagnostics (`state`, `queue_depth`, `failed_ops`, totals).
