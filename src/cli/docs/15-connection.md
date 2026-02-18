# Connection Commands

## connect

Connect to Spiderweb server.

**Options:**
- `--url <url>` - Server URL (required if not configured)

**Examples:**
```bash
ziggystarspider connect
ziggystarspider connect --url ws://100.101.192.123:18790/v1/agents/default/stream
```

## disconnect

Disconnect from Spiderweb server.

**Examples:**
```bash
ziggystarspider disconnect
```

## status

Show connection status.

**Examples:**
```bash
ziggystarspider status
```

**Output:**
```
Connected: Yes
Server: ws://100.101.192.123:18790/v1/agents/default/stream
Project: spiderweb
Uptime: 45 minutes
```
