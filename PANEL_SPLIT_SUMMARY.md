# Panel Split Summary

## Purpose

This document summarizes the current UI panel split after the reusable panel extraction work.
It is intended as a stable reference for future PRs, especially before further Debug and Terminal redesign work.

## Target Layering

Final layering in current code:

`ziggy-ui` <- `ZiggyUIPanels` <- `SpiderApp`

### `ziggy-ui`
Owns:
- low-level widgets
- shared input/render primitives
- canonical panel contract types in `src/ui/panels/interfaces.zig`
- panel runtime abstractions in `src/ui/panels/runtime.zig`
- generic chat implementation

Must not own:
- SpiderApp-specific app state
- SpiderApp-specific side effects
- concrete SpiderApp panel behavior

### `ZiggyUIPanels`
Owns:
- reusable panel implementations built on `ziggy-ui`
- reusable panel shells, forms, viewports, and wrappers
- typed action emission back to the host

Must not own:
- SpiderApp network/filesystem/workspace operations
- SpiderApp global application state
- SpiderApp-specific service wiring

### `SpiderApp`
Owns:
- application state
- host adapters
- model building for each panel
- execution of emitted panel actions
- panel-specific side effects (filesystem, websocket, workspace, clipboard, etc.)
- host rendering callbacks where a reusable panel still delegates drawing details

## Current Extracted Panels

### Extracted to `ZiggyUIPanels`
- Launcher Settings panel
- Workspace Settings panel variant
- Filesystem panel
- Project panel
- Debug panel shell
- Debug event stream viewport algorithm
- Terminal panel shell
- Terminal output viewport algorithm
- Chat workspace wrapper

### Still host-owned in `SpiderApp`
These are not architecture failures; they are current host seams.

- Debug chart rasterization callback
- Debug event entry rendering/details callback
- Terminal per-line styled output rendering callback
- All side effects and state mutation for every extracted panel

## Canonical Contract Location

Shared panel contracts live in:

- `deps/ziggy-ui/src/ui/panels/interfaces.zig`

SpiderApp consumes those contracts through:

- `src/gui/panels_bridge.zig`

That bridge is the local alias layer used by SpiderApp host code.

## Reusable Panel Implementation Location

Reusable panels currently live in:

- `D:/Projects/Ziggy/ZiggyUIPanels/src/panels/`

Current important modules:
- `launcher_settings_panel.zig`
- `chat_workspace_panel.zig`
- `filesystem_panel.zig`
- `project_panel.zig`
- `debug_panel.zig`
- `debug_event_stream.zig`
- `terminal_panel.zig`
- `terminal_output_panel.zig`

Exports are wired through:
- `D:/Projects/Ziggy/ZiggyUIPanels/src/root.zig`

## SpiderApp Host Integration Location

SpiderApp host integration currently lives primarily in:

- `src/gui/root.zig`

Typical per-panel pattern in SpiderApp is now:
1. Build a typed `Model`
2. Build an owned `View`
3. Call the reusable panel `draw(...)`
4. Translate returned focus state
5. Execute emitted typed actions in a host handler

Examples in `root.zig`:
- `launcherSettingsModel()` / `performLauncherSettingsAction(...)`
- `filesystemPanelModel()` / `buildFilesystemPanelView()` / `performFilesystemPanelAction(...)`
- `projectPanelModel()` / `buildProjectPanelView()` / `performProjectPanelAction(...)`
- `debugPanelModel()` / `buildDebugPanelView()` / `performDebugPanelAction(...)`
- `terminalPanelModel()` / `terminalPanelView()` / `performTerminalPanelAction(...)`

## Chat Status

Chat is slightly different from the other extracted panels.

- The generic chat implementation still lives in `ziggy-ui`
- `ZiggyUIPanels` provides a wrapper module: `chat_workspace_panel.zig`
- SpiderApp now consumes chat through that wrapper instead of directly calling `zui.ChatPanel(...)`
- The canonical chat action surface is now also exposed through `interfaces.zig`

This means Chat now follows the same package boundary even though the underlying generic implementation remains in `ziggy-ui`.

## Runtime and Legacy Host Panels

SpiderApp still contains host-panel runtime integration for workspace panel dispatch.
Relevant runtime-related code is in:

- `deps/ziggy-ui/src/ui/panels/runtime.zig`
- `src/gui/root.zig`

Legacy host panel migration logic still exists because older panel kinds/titles may need upgrading in-place.
That logic should remain until old workspace state compatibility is no longer needed.

## Current Design Rules

When adding or refactoring a panel:

1. Put shared panel contracts in `ziggy-ui`
2. Put reusable panel implementation in `ZiggyUIPanels`
3. Keep SpiderApp-specific side effects in `SpiderApp`
4. Pass host state into panels as typed model/view data
5. Return typed actions from panels instead of mutating host state directly
6. If a panel still needs host rendering callbacks, keep the callback surface narrow and render-only where possible
7. Do not add SpiderApp-specific types to `ziggy-ui` contracts

## What To Do Next For Future Panels

Recommended pattern for new extraction work:

1. Define or extend canonical contract types in `ziggy-ui`
2. Add aliases in `src/gui/panels_bridge.zig`
3. Implement reusable panel module in `ZiggyUIPanels`
4. Replace inline SpiderApp draw body with:
   - model builder
   - owned view builder if needed
   - host action executor
5. Keep any remaining host callbacks explicit and narrow
6. Only then remove old inline panel UI code

## Debug and Terminal Note

Debug and Terminal were intentionally not pushed to full host-independence yet.
That was deliberate to avoid mixing architecture cleanup with higher-risk behavior changes.

Current expectation:
- future Debug work can redesign the debug UX against the cleaner panel seam now in place
- future Terminal work can redesign terminal behavior/rendering against the cleaner panel seam now in place

## Practical Mental Model

If a change is about:
- widgets, render primitives, panel contracts: `ziggy-ui`
- reusable panel layout/viewports/wrappers: `ZiggyUIPanels`
- app state, services, network/filesystem/workspace effects: `SpiderApp`

That is the intended split.
