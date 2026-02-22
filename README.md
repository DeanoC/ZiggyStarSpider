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

## Build

### CLI

```bash
zig build
./zig-out/bin/ziggystarspider --help
```

### GUI (Windows + Linux + macOS desktop builds)

```bash
# Build GUI executable
zig build gui

# Run GUI
zig build run-gui
```

Built GUI binary:

- `zig-out/bin/zss-gui`

## GUI Features (MVP)

### Settings / Auth Screen

- Server URL input (default `ws://127.0.0.1:18790/v1/agents/default/stream`)
- Connect button
- Connection status indicator

### Chat Screen

- Message input field
- Send button
- Message history list
- Mouse-wheel scrolling for history

## Notes

- GUI uses SDL3 for the native window/event loop and uses **ziggy-ui widget patterns** (`button` + `text_input` state handling) for interaction behavior.
- Current chat payload format is JSON:
  - `{"type":"chat","content":"..."}`

## Architecture

See [ARCHITECTURE.md](./docs/ARCHITECTURE.md) for protocol design and client architecture.

## Protocol

ZSS speaks the Spiderweb protocol - an extension of OpenClaw that adds:

- Project/goal/task management
- Worker spawn/complete events
- Virtual filesystem operations
- Memory store/recall

See [PROTOCOL.md](./docs/PROTOCOL.md) for message formats.

## Module Migration Notes

StarSpider now imports `ziggy-spider-protocol` directly for `session.send` envelope helpers. The local compatibility wrapper (`src/client/session_protocol.zig`) was marked for removal on February 22, 2026 with a target of `v0.3.0`, and is now removed.

## License

MIT - See LICENSE
