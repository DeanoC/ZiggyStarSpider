# Connection Commands

## connect

Connect to Spiderweb server.

Connection uses Spiderweb control negotiation:
`control.version` (`protocol=spiderweb-control`) then `control.connect`.

**Options:**
- `--url <url>` - Server URL (required if not configured)

**Examples:**
```bash
spider connect
spider --url ws://100.101.192.123:18790 connect
```

## disconnect

Disconnect from Spiderweb server.

**Examples:**
```bash
spider disconnect
```

## status

Show connection status.

**Examples:**
```bash
spider status
```

**Output:**
```
Server: ws://100.101.192.123:18790
Connected: Yes
```
