# Task Commands

Tasks are spawned by the PM agent to accomplish goals. They run as workers.

## task list

List active tasks.

**Examples:**
```bash
ziggystarspider task list
```

**Output:**
```
Active Tasks:
  [T1] Research logging libraries | Running  | 45%
  [T2] Design VFS schema          | Pending  | 0%
```

## task info <id>

Show detailed information about a task.

**Arguments:**
- `id` - Task ID

**Examples:**
```bash
ziggystarspider task info T1
```

**Output:**
```
Task: T1
Description: Research logging libraries
Status: Running
Progress: 45%
Started: 2026-02-14 10:30
Worker: research
```
