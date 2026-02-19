# ZiggyStarSpider CLI

## Usage

```text
zss <noun> <verb> [args] [options]
zss --help
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

- `--url <url>` - Spiderweb server URL (default: ws://127.0.0.1:18790/v1/agents/default/stream)
- `--project <name>` - Set current project
- `--interactive` - Start interactive REPL mode
- `--tui` - Launch the Terminal User Interface
- `--verbose` - Enable verbose logging
- `--help` - Show this help
- `--version` - Show version

## Interactive Mode

Run without commands to enter interactive mode:

```bash
zss --url ws://127.0.0.1:18790/v1/agents/default/stream
```

Within interactive mode:
```text
ZSS> help
ZSS> project list
ZSS> chat send "Hello!"
```

## Design Philosophy

ZSS uses a noun-verb command structure (like OpenClaw) for consistency:
- **Noun** = What you're acting on (chat, project, goal, task)
- **Verb** = What you're doing (send, list, create, use)

This makes commands discoverable and consistent.
