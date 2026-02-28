# Node Commands

Nodes are FS endpoints registered in Spiderweb's unified-v2 control plane.

## node list

List known nodes.

**Examples:**
```bash
ziggystarspider node list
```

## node info <node_id>

Show details for one node.

**Arguments:**
- `node_id` - Node identifier (for example `node-1`)

**Examples:**
```bash
ziggystarspider node info node-1
```

## node join-request <node_name> [fs_url] [--os <os>] [--arch <arch>] [--runtime-kind <kind>]

Submit a pending join request for manual approval.

**Examples:**
```bash
ziggystarspider node join-request desktop-west ws://10.0.0.8:18891/v2/fs --os linux --arch amd64 --runtime-kind native
```

## node pending

List pending node join requests.

If an operator token is configured (via `--operator-token` or local config), it is included automatically.

**Examples:**
```bash
ziggystarspider node pending
```

## node approve <request_id> [--lease-ttl-ms <ms>]

Approve a pending join request and mint node credentials.

If an operator token is configured (via `--operator-token` or local config), it is included automatically.

**Examples:**
```bash
ziggystarspider node approve pending-join-1 --lease-ttl-ms 900000
```

## node deny <request_id>

Deny a pending join request.

If an operator token is configured (via `--operator-token` or local config), it is included automatically.

**Examples:**
```bash
ziggystarspider node deny pending-join-1
```

## node service-get <node_id>

Show the node service catalog (platform, labels, and services).

**Examples:**
```bash
ziggystarspider node service-get node-1
```

## node service-upsert <node_id> <node_secret> [options]

Update node service catalog metadata.

**Options:**
- `--os <os>` - Platform OS value
- `--arch <arch>` - Platform arch value
- `--runtime-kind <kind>` - Platform runtime kind
- `--label <key=value>` - Add/update a label (repeatable)
- `--services-json '<json-array>'` - Inline JSON array for services
- `--services-file <path>` - Read services JSON array from file

**Examples:**
```bash
ziggystarspider node service-upsert node-1 secret-abc --label site=hq --label tier=edge --services-json '[{"service_id":"camera","kind":"camera","state":"online","endpoints":["/nodes/node-1/camera"],"capabilities":{"still":true}}]'
```

## node service-runtime <node_id> <service_id> <action> [payload]

Interact with a service runtime namespace via control files resolved from the node service catalog.

**Actions:**
- `help` - Read `README.md`
- `schema` - Read `SCHEMA.json` (falls back to `schema.json`)
- `template` - Read `TEMPLATE.json` (falls back to `template.json`)
- `status` - Read `status.json`
- `metrics` - Read `metrics.json`
- `health` - Read `health.json`
- `config-get` - Read `config.json`
- `config-set <json-object>` - Write `config.json`
- `invoke [json-object]` - Write `control/invoke.json` (uses `TEMPLATE.json` when omitted, otherwise `{}`), then read status/result/error
- `enable` - Write `control/enable`
- `disable` - Write `control/disable`
- `restart` - Write `control/restart`
- `reset` - Write `control/reset`

**Examples:**
```bash
ziggystarspider node service-runtime node-2 camera-main health
ziggystarspider node service-runtime node-2 camera-main template
ziggystarspider node service-runtime node-2 camera-main config-set '{"supervision":{"cooldown_ms":5000}}'
ziggystarspider node service-runtime node-2 camera-main invoke '{"op":"capture"}'
ziggystarspider node service-runtime node-2 camera-main restart
```

## node watch [node_id] [--replay-limit <n>]

Subscribe to live `control.node_service_event` updates pushed by Spiderweb when node service catalogs change.

Use `node_id` to filter to one node, or omit it to watch all nodes.
Use `--replay-limit <n>` (or `--replay-limit=<n>`) to request recent historical
events first before live streaming. Default is `25` and maximum is `10000`.

**Examples:**
```bash
ziggystarspider node watch
ziggystarspider node watch node-2
ziggystarspider node watch --replay-limit 100
ziggystarspider node watch node-2 --replay-limit=250
```
