# Connection Commands

## connect

Connect to Spiderweb server.

Note: On first connect to a newly bootstrapped agent, the server may send
an immediate `session.receive` bootstrap message right after `control.connect_ack`.

**Options:**
- `--url <url>` - Server URL (required if not configured)

**Examples:**
```bash
ziggystarspider connect
ziggystarspider connect --url ws://100.101.192.123:18790
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
Server: ws://100.101.192.123:18790
Project: spiderweb
Uptime: 45 minutes
```
