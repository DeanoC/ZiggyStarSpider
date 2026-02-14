# Worker Commands

Workers execute tasks. They report progress and results back to the chat.

## worker list

Show running workers.

**Examples:**
```bash
ziggystarspider worker list
```

**Output:**
```
Active Workers:
  worker-1 | Research | 45% | Researching logging libraries...
  worker-2 | Implement| 10% | Adding file read API
```

## worker logs <id>

Show logs for a specific worker.

**Arguments:**
- `id` - Worker ID

**Examples:**
```bash
ziggystarspider worker logs worker-1
```
