# Plan: Port Main Window, Chat, and Settings Parity from ZiggyStarClaw

## Goal
Advance `ZiggyStarSpider` UI parity with `ZiggyStarClaw` for:

- main window/workspace behavior
- chat session + streaming behavior
- settings lifecycle and persistence

while avoiding risky protocol changes outside GUI scope.

## Scope

1. Main window shell and panel/container behavior in `src/gui/root.zig`.
2. Chat protocol/rendering/session state behavior in `src/gui/root.zig`.
3. Settings flow and persistence in `src/gui/root.zig` + `src/client/config.zig`.

## Out of scope

1. CLI or non-GUI protocol rewrites.
2. Full `ziggy-ui` feature parity across all features outside chat/settings.
3. Deep refactors to transport/client context outside Spider-specific paths.

## Phase 1 — Baseline parity boundaries

1. Keep `src/gui/root.zig` as the primary migration surface.
2. Validate assumptions against `ZiggyStarClaw/src/main_native.zig` and `ZiggyStarClaw/src/client/event_handler.zig`.
3. Preserve current single-window renderer baseline until multi-window support can be introduced cleanly.

### What this reveals from Claw

1. `main_native.zig` supports multi-window concepts (`UiWindow`, detach/attach, persisted workspace profiles) that Spider does not currently have.
2. `event_handler.zig` has stronger stream lifecycle handling (stream id/run id state, pending history correlation, and message replacement semantics).
3. Spider currently has simpler settings surface and a narrower config-to-UI sync loop.

## Phase 2 — Main window/session UX hardening

1. Keep existing dock-tab architecture and input loop stable.
2. Make session actions deterministic and safe:
   - session key switch by id/string
   - no stale pointer use when session collection mutates
   - deterministic fallback selection when session is missing
3. Ensure panel state uses active session as source of truth for message rendering.

## Phase 3 — Chat parity (incremental)

1. Implemented:
   - per-session message buffers (`session_messages`)
   - session-aware append/update helpers
   - request-tracked send state + streaming id tracking
   - trims with streaming/pending-id cleanup
   - `session_key` hydration when present in incoming `chat_receive` without forcing active-session flips
2. Next:
   - keep stream replacement behavior closer to Claw (if protocol exposes stream/run-like id)
   - add explicit chat history request path when possible
   - support message-state transitions beyond `.sending`/`.failed` if protocol updates

## Phase 4 — Settings parity (incremental)

1. Implemented:
   - startup and panel values for `server_url`, `default_session`, `auto_connect_on_launch`
   - save/apply persistence path integration
2. Next:
   - add richer settings surface where needed by request (theme/profile/theme pack/workspace-level options)
   - avoid regressions in existing manual connect/save behavior

## Phase 5 — Clean-up, safeguards, and deferred items

1. Do not alter protocol contracts until stream/session migration is stable.
2. Preserve single-window safety and avoid large refactors of state/client transport.
3. Keep multi-window runtime added to Spider and then grow toward Claw parity in smaller increments:
   - per-window queue/swapchain lifecycle
   - shared vs independent window workspace state
   - dock detach/reattach parity.

## Milestones

1. M1 — Session/message foundation stabilized in Spider UI.
2. M2 — Settings defaults + startup connect flow harmonized.
3. M3 — Chat action + stream lifecycle hardening.
4. M4 — Multi-window detach/reattach parity implementation.

## Implementation status (now)

1. ✅ Spider now keeps per-session message state (`session_messages`) and renders the active session’s messages in chat panel.
2. ✅ Incoming `chat_receive` processing now hydrates session list when `session_key` is present.
3. ✅ Send/pending-tracking now includes session context (`pending_send_session_key`), with safer pending + streaming cleanup on trim.
4. ✅ Session actions are deterministic (safe index/key selection and no stale-session activation).
5. ✅ `activeMessages` rendering now favors the current active session with deterministic fallback to first valid session.
6. ✅ Startup/session settings parity basics are implemented (`auto_connect_on_launch`, `default_session`, `ui_theme`, `ui_profile`, `ui_theme_pack`) and persisted via config.
7. ✅ Request-scoped stream replacement now tracks active `streaming_request_id` per session and updates stream message content on final chunk.
8. ✅ Multi-window lifecycle is implemented in Spider with main-window registration, non-main close routing, and Ctrl+Y window spawning.
9. ✅ Additional windows now use cloned panel managers from snapshots with workspace remap.
10. ✅ Detached windows can now carry `persist_in_workspace`, and when enabled close handlers reattach their panels back to the main workspace.
11. ✅ Dock-tab drag/drop interaction is now wired through thresholded press/drag/release handling with active-tab focus and detach fallback.
12. ✅ Settings theme persistence is now applied at runtime: loaded theme preference is applied on init and sync/save writes immediately updates active mode.
13. Remaining: richer settings (`workspace`-level) surface, and broader stream lifestyle parity for out-of-band/out-of-order stream ids.

## Open questions before next wave

1. Do we want to block on protocol confirmation for `chat.history` support before implementing a dedicated request/response flow?
2. Which settings additions should be shipped next for workspace-level parity (`workspace` profiles, window layout, theme pack browsing/watch UX)?
