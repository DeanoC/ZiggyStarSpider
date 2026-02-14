# ZiggyStarSpider

> Native client for ZiggySpiderweb - a project-oriented AI assistant with pro-active agency.

## What This Is

ZiggyStarSpider (ZSS) is the native client for [ZiggySpiderweb](https://github.com/DeanoC/ZiggySpiderweb) - an AI assistant runtime built around:

- **Project-oriented work** - agents work on goals, not just chat
- **Pro-active agency** - PM agent plans, spawns workers, reports progress
- **Soft workflows** - AI-driven execution, not rigid pipelines  
- **Virtual filesystem** - unified workspace across local, remote, and cloud storage
- **Memory separation** - current chat, working context, long-term memory

## Relationship to ZiggyStarClaw

| | ZiggyStarClaw | ZiggyStarSpider |
|---|---|---|
| **Purpose** | OpenClaw protocol client | Spiderweb-native client |
| **Session model** | Channel-based (Discord/Slack style) | Project-based with chat |
| **Agent behavior** | Reactive (waits for user) | Pro-active (plans, reports) |
| **Use case** | General chat assistant | Project work, game dev, coding |

Both share a common core (`ziggy-core`) for WebSocket, Canvas, and platform abstractions.

## Quick Start

```bash
# Build
zig build

# Connect to Spiderweb
./zig-out/bin/ziggystarspider --url ws://100.101.192.123:18790

# Interactive mode
./zig-out/bin/ziggystarspider --interactive
```

## Architecture

See [ARCHITECTURE.md](./docs/ARCHITECTURE.md) for protocol design and client architecture.

## Protocol

ZSS speaks the Spiderweb protocol - an extension of OpenClaw that adds:

- Project/goal/task management
- Worker spawn/complete events
- Virtual filesystem operations
- Memory store/recall

See [PROTOCOL.md](./docs/PROTOCOL.md) for message formats.

## License

MIT - See LICENSE
