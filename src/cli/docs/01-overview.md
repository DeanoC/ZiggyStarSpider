# ZiggyStarSpider CLI

## Usage

```text
ziggystarspider <noun> <verb> [args] [options]
ziggystarspider --help
```

## Noun-Verb Commands

- `chat send <message>` - Send a message to the AI
- `chat history` - Show recent chat history
- `project list` - List all projects
- `project use <name>` - Switch to a project
- `project create <name>` - Create a new project
- `goal list` - List goals for current project
- `goal create <description>` - Create a new goal
- `task list` - List active tasks
- `worker list` - Show running workers
- `connect` - Connect to Spiderweb
- `disconnect` - Disconnect from Spiderweb

## Global Options

- `--url <url>` - Spiderweb server URL (default: ws://127.0.0.1:18790)
- `--project <name>` - Set current project
- `--interactive` - Start interactive REPL mode
- `--verbose` - Enable verbose logging
- `--help` - Show this help
- `--version` - Show version

## Interactive Mode

Run without commands to enter interactive mode:

```
ziggystarspider --url ws://100.101.192.123:18790

ZiggyStarSpider> help
ZiggyStarSpider> project list
ZiggyStarSpider> chat send "Hello!"
```

## Design Philosophy

ZSS uses a noun-verb command structure (like OpenClaw) for consistency:
- **Noun** = What you're acting on (chat, project, goal, task)
- **Verb** = What you're doing (send, list, create, use)

This makes commands discoverable and consistent.
