# ZiggyStarSpider Troubleshooting

## Auth Failures

Symptoms:
- control mutations fail (`Unauthorized`, `OperatorAuthFailed`, `ProjectAuthFailed`)
- project activation fails

Checks:
- verify `--operator-token` for operator-scoped mutations
- verify project token used by `project use` / `project activate`
- confirm selected project token in local config matches server token
- inspect auth role tokens:
  - `zss auth status`
  - `zss auth status --reveal` (full values)

Actions:
- rotate/reissue token server-side, then update local token
- retry command with explicit token flags
- emergency reset when admin token is lost:
  - `spiderweb-config auth reset --yes` (run on Spiderweb host)
  - restart Spiderweb and update local admin/user tokens

## session_busy on Session/Project Attach

Symptoms:
- `control.session_attach` fails with `code=session_busy`
- project/agent switch from GUI Settings fails while chat work is still running

Checks:
- confirm in-flight chat work (`zss chat resume`)
- wait for queued/running jobs to complete for the target/current agent

Actions:
- retry attach/switch once jobs are terminal (`done`/`failed`)
- avoid switching project context for an agent mid-job

## No Nodes / Lease Expiry

Symptoms:
- `node list` empty
- workspace shows no actual mounts
- drift increases after node drop

Checks:
- `zss node list`
- `zss --verbose workspace status` (drift + reconcile diagnostics)

Actions:
- rejoin nodes to Spiderweb
- refresh workspace / run `project doctor`
- verify node lease refresh path is healthy

## Mount Conflicts / Missing Mounts

Symptoms:
- `project up` or mount mutations fail with conflict-style errors
- workspace mount set diverges from desired

Checks:
- inspect desired vs actual vs drift in `workspace status`
- check mount path overlap in project configuration

Actions:
- adjust conflicting mount paths
- re-run `project up` with corrected desired mounts
- refresh workspace and confirm drift count returns to zero

## Reconcile Stuck / Degraded

Symptoms:
- `reconcile_state` remains `degraded`
- `queue_depth` or `failed_ops_total` keeps growing

Checks:
- `zss --verbose workspace status`
- inspect reconcile `failed_ops` and `last_error`

Actions:
- fix failing node/project references in desired mounts
- verify required auth tokens for mutations
- trigger refresh and observe `reconcile_state` transition back to `idle`

## Chat Send Interrupted

Symptoms:
- send fails during reconnect/timeout
- user message remains pending

Checks:
- reconnect GUI/CLI session
- inspect queued jobs:
  - `zss chat resume`
  - `zss chat resume <job-id>`

Actions:
- allow automatic resume after reconnect
- manually resume by job id if needed

## Filesystem Browser Issues (GUI)

Symptoms:
- filesystem panel shows errors or empty results

Checks:
- confirm connected state in Settings
- ensure project is selected/activated
- test same paths from CLI (`fs ls`, `fs read`)

Actions:
- use `Refresh` in filesystem panel
- reset to workspace root in panel
- verify mounts exist in workspace status

## Debugging Aids

- Enable Debug Stream panel in GUI for control/acheron events and correlation IDs.
- Use CLI `--verbose` for workspace diagnostics.
- Run `./scripts/smoke-matrix.sh` for a full workflow check.
