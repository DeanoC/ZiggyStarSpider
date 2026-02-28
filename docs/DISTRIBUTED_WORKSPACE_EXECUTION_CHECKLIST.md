# Distributed Workspace Execution Checklist

This checklist breaks delivery into small PR slices across:

- `ZiggySpiderweb` (server/control/reconciler/FUSE topology source)
- `ZiggyStarSpider` (CLI + GUI operator/client experience)

Status legend:

- `[ ]` not started
- `[~]` in progress
- `[x]` implemented in current branch

## Phase 0: Baseline (already delivered in this branch)

- `[x]` ZSS unified-v2 shared client/control modules.
- `[x]` ZSS project/node/workspace CLI commands.
- `[x]` ZSS GUI project selection + activation + workspace/node/project visibility.
- `[x]` ZSS docs aligned to unified-v2 and control/acheron split.

## Phase 1: Desired-State Topology API

### [x] PR-S1 (ZiggySpiderweb): `control.workspace_status` desired/actual/drift payload
- Add `desired_mounts`, `actual_mounts`, `drift` sections in control payload.
- Include reconciliation state fields (`reconcile_state`, `last_reconcile_ms`, `last_error`).
- Add tests for payload schema.

### [x] PR-C1 (ZiggyStarSpider): parse + render desired/actual/drift
- Extend `src/client/workspace_types.zig` and parsers.
- CLI `workspace status` prints drift summary.
- GUI settings summary shows drift count and first errors.

## Phase 2: Reconciler Engine (Server)

### [x] PR-S2 (ZiggySpiderweb): background reconcile loop
- Add periodic reconcile worker keyed by project.
- Converge actual mounts to desired mounts.
- Backoff and retry model with bounded retries per cycle.

### [x] PR-S3 (ZiggySpiderweb): event-driven reconcile triggers
- Trigger reconcile on node join/leave/lease transitions.
- Debounce rapid topology churn.
- Emit structured control debug events.

## Phase 3: Failure Handling + Auto-Heal

### [x] PR-S4 (ZiggySpiderweb): lease-aware failover mount selection
- Prefer healthy node export for shared mount paths.
- Preserve mount path continuity during failover.

### [x] PR-S5 (ZiggySpiderweb): reconcile diagnostics API
- Add `control.reconcile_status` (optional) for operator introspection.
- Include queue depth, failed ops, last success time.

### [x] PR-C2 (ZiggyStarSpider): diagnostics UX
- CLI `workspace status --verbose` includes reconcile diagnostics.
- GUI debug panel tags reconcile errors distinctly.

## Phase 4: One-Shot Bootstrap UX

### [x] PR-S6 (ZiggySpiderweb): high-level project bootstrap control op
- Add `control.project_up` (or equivalent orchestration endpoint).
- Input: project + desired mounts + optional activation.
- Output: created/updated topology + activation result.

### [x] PR-C3 (ZiggyStarSpider CLI): `project up` and `project doctor`
- `project up`: guided non-interactive bootstrap.
- `project doctor`: readiness checks with actionable failures.

### [x] PR-C4 (ZiggyStarSpider GUI): onboarding wizard
- 4-step flow: connect -> project -> mounts -> activate.
- Inline validation and retry actions.

## Phase 5: Filesystem UX

### [x] PR-C5 (ZiggyStarSpider CLI): true `fs tree`
- Recursive walk output (depth-limited).
- Optional filters (`--max-depth`, `--files-only`, `--dirs-only`).

### [x] PR-C6 (ZiggyStarSpider GUI): filesystem browser panel
- Project-root browser with node/mount badges.
- Open/read text file preview and refresh.

## Phase 6: Durable Job Model

### [x] PR-S7 (ZiggySpiderweb): persistent chat/capability job index
- Store job metadata + states (`queued/running/done/failed`).
- TTL + retention policy.

### [x] PR-C7 (ZiggyStarSpider): reconnect/resume job state
- Rehydrate pending sends after reconnect.
- Surface resumed results in active chat session.

## Phase 7: Security + Audit + Observability

### [x] PR-S8 (ZiggySpiderweb): scoped token policy + audit stream
- Separate operator/project/node scopes with validation.
- Emit structured audit records for mutating ops.

### [x] PR-S9 (ZiggySpiderweb): correlation IDs end-to-end
- Require/pass correlation IDs on control mutations and Acheron capability jobs.
- Include IDs in error payloads and metrics labels.

### [x] PR-C8 (ZiggyStarSpider): correlation visibility
- Show request/job correlation IDs in CLI verbose output.
- GUI debug panel includes correlation badges.

## Phase 8: Integration Coverage + Release Readiness

### [x] PR-S10 (ZiggySpiderweb): distributed workspace integration matrix
- Expand `test-env` scenarios for drift, failover, reconnect, and bootstrap.
- Add CI entrypoint for the matrix.

### [x] PR-C9 (ZiggyStarSpider): CLI/GUI smoke matrix
- Add scripted smoke checks for connect/project/node/workspace/fs/chat.

### [x] PR-C10 (Docs): runbook + troubleshooting
- Operator runbook for production usage.
- Failure cookbook: auth, lease, mount conflicts, reconcile stuck.

## Recommended merge order

1. `PR-S1` -> `PR-C1`
2. `PR-S2` -> `PR-S3`
3. `PR-S4` -> `PR-S5` -> `PR-C2`
4. `PR-S6` -> `PR-C3` -> `PR-C4`
5. `PR-C5` -> `PR-C6`
6. `PR-S7` -> `PR-C7`
7. `PR-S8` -> `PR-S9` -> `PR-C8`
8. `PR-S10` -> `PR-C9` -> `PR-C10`

## Definition of done (system-wide)

- New project can be bootstrapped from one CLI command or GUI flow.
- Workspace topology self-heals after node loss/rejoin.
- Drift and reconcile failures are visible without log scraping.
- Chat + filesystem workflows survive reconnect without manual repair.
- Auth, audit, and correlation are sufficient for operator debugging.
