# Global Options

## Connection Options

### `--url <url>`
Spiderweb server WebSocket URL.

**Default:** `ws://127.0.0.1:18790`

**Examples:**
```bash
ziggystarspider --url ws://100.101.192.123:18790 chat send "Hello"
ziggystarspider --url ws://localhost:18790 project list
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
ziggystarspider --url ws://remote --interactive
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
