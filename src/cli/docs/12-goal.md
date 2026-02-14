# Goal Commands

Goals represent objectives within a project. They break down into tasks.

## goal list

List goals for the current project.

**Examples:**
```bash
ziggystarspider goal list
```

**Output:**
```
Goals for project 'spiderweb':
  [1] Implement worker spawn      | Open       | High
  [2] Add virtual filesystem      | In Progress| Medium
  [3] Create project data model   | Completed  | High
```

## goal create <description>

Create a new goal.

**Arguments:**
- `description` - Goal description

**Options:**
- `--priority <1-10>` - Goal priority (default: 5)

**Examples:**
```bash
ziggystarspider goal create "Add logging system" --priority 8
```

## goal complete <id>

Mark a goal as completed.

**Arguments:**
- `id` - Goal ID

**Examples:**
```bash
ziggystarspider goal complete 1
```
