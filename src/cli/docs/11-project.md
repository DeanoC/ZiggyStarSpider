# Project Commands

Projects are the top-level organization for work in Spiderweb.

## project list

List all projects.

**Examples:**
```bash
spider project list
```

**Output (example):**
```
Projects:
  proj-1  [active]  mounts=2  name=Spiderweb
* proj-2  [active]  mounts=1  name=Game AI
```

## project use <project_id> [project_token]

Select a project and optionally activate it.

**Arguments:**
- `project_id` - Project id (for example `proj-1`)
- `project_token` (optional) - Project token for activation

**Examples:**
```bash
spider project use proj-1
spider project use proj-1 proj-abc123
spider --project-token proj-abc123 project use proj-1
```

## project create <name> [vision]

Create a new project and persist it as the selected project in local config.

**Arguments:**
- `name` - Project display name
- `vision` (optional) - Freeform vision/description text

**Examples:**
```bash
spider project create "Distributed Workspace"
spider project create "Distributed Workspace" "unified node mounts"
spider --operator-token op-secret project create "Secure Project"
```

## project info <project_id>

Show information about a project.

**Examples:**
```bash
spider project info proj-1
```

**Output (example):**
```
Project proj-1
  Name: Distributed Workspace
  Vision: unified node mounts
  Status: active
  Created: 1739999999999
  Updated: 1739999999999
  Mounts (2):
    - /src <= node-a:work
    - /cache <= node-b:cache
```

## project up <name>

Create/update and activate a project with desired mounts in one command.

**Examples:**
```bash
spider project up "Distributed Workspace"
spider project up "Distributed Workspace" --mount /nodes/local/fs=node-1:work
```

## project doctor

Run readiness checks for nodes, project selection, and active mounts.

**Examples:**
```bash
spider project doctor
spider --project proj-1 project doctor
```
