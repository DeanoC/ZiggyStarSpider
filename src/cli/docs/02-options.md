# Global Options

## Connection Options

### `--url <url>`
Spiderweb server WebSocket URL.

**Default:** `ws://127.0.0.1:18790/v1/agents/default/stream`

**Examples:**
```bash
ziggystarspider --url ws://127.0.0.1:18790/v1/agents/default/stream chat send "Hello"
ziggystarspider --url ws://localhost:18790/v1/agents/default/stream project list
```

### `--project <name>`
Set the current project for this session.

**Examples:**
```bash
ziggystarspider --project spiderweb goal list
ziggystarspider --project mygame chat send "What's next?"
```

## Mode Options

### `--interactive`
Start interactive REPL mode instead of running a single command.

**Examples:**
```bash
ziggystarspider --interactive
ziggystarspider --url ws://remote:18790/v1/agents/default/stream --interactive
```

### `--verbose`
Enable verbose debug logging.

**Examples:**
```bash
ziggystarspider --verbose chat send "Test"
ziggystarspider --verbose --interactive
```

## Information Options

### `--help`
Show help message and exit.

### `--version`
Show version information and exit.
