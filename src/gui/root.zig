const std = @import("std");
const zui = @import("ziggy-ui");
const ws_client_mod = @import("websocket_client.zig");
const config_mod = @import("client-config");

const zapp = zui.ui.app;
const c = zapp.sdl_app.c;

const widgets = zui.widgets;
const zcolors = zui.theme.colors;
const ui_draw_context = zui.ui.draw_context;
const ui_input_router = zui.ui.input.input_router;
const ui_input_state = zui.ui.input.input_state;
const ui_input_backend = zui.ui.input.input_backend;
const ui_sdl_input_backend = zui.ui.input.sdl_input_backend;
const ui_command_inbox = zui.ui.ui_command_inbox;
const ui_command_queue = zui.ui.render.command_queue;
const client_state = zui.client.state;
const client_agents = zui.client.agent_registry;
const font_system = zui.ui.font_system;
const protocol_messages = @import("protocol_messages.zig");

const workspace = zui.ui.workspace;
const panel_manager = zui.ui.panel_manager;
const dock_graph = zui.ui.layout.dock_graph;
const dock_drop = zui.ui.layout.dock_drop;

const Rect = zui.core.Rect;
const UiRect = ui_draw_context.Rect;
const Paint = zui.theme_engine.Paint;

const ConnectionState = enum {
    disconnected,
    connecting,
    connected,
    error_state,
};

const MAX_REASONABLE_PANEL_COUNT: usize = 4096;
const MAX_REASONABLE_DOCK_NODE_COUNT: usize = 16384;
const MAX_REASONABLE_NEXT_PANEL_ID: workspace.PanelId = 4097;
const WORKSPACE_RECOVERY_COOLDOWN_FRAMES: u64 = 60;
const WORKSPACE_RECOVERY_SUSPEND_FRAMES: u64 = 9000;
const WORKSPACE_RECOVERY_ATTEMPTS_BEFORE_SUSPEND: u8 = 1;

const ChatAttachment = zui.protocol.types.ChatAttachment;
const ChatMessage = zui.protocol.types.ChatMessage;
const ChatMessageState = zui.protocol.types.LocalChatMessageState;
const ChatSession = zui.protocol.types.Session;

const ChatPanel = zui.ChatPanel(ChatMessage, ChatSession);

const SettingsFocusField = enum {
    none,
    server_url,
    default_session,
    ui_theme,
    ui_profile,
    ui_theme_pack,
};

const SettingsPanel = struct {
    server_url: std.ArrayList(u8) = .empty,
    default_session: std.ArrayList(u8) = .empty,
    ui_theme: std.ArrayList(u8) = .empty,
    ui_profile: std.ArrayList(u8) = .empty,
    ui_theme_pack: std.ArrayList(u8) = .empty,
    watch_theme_pack: bool = false,
    auto_connect_on_launch: bool = true,
    focused_field: SettingsFocusField = .server_url,

    pub fn init(allocator: std.mem.Allocator) SettingsPanel {
        var panel = SettingsPanel{};
        panel.server_url.appendSlice(allocator, "ws://127.0.0.1:18790") catch {};
        panel.default_session.appendSlice(allocator, "main") catch {};
        return panel;
    }

    pub fn deinit(self: *SettingsPanel, allocator: std.mem.Allocator) void {
        self.server_url.deinit(allocator);
        self.default_session.deinit(allocator);
        self.ui_theme.deinit(allocator);
        self.ui_profile.deinit(allocator);
        self.ui_theme_pack.deinit(allocator);
    }
};

const UiWindow = struct {
    window: *c.SDL_Window,
    id: u32,
    queue: ui_input_state.InputQueue,
    swapchain: zapp.multi_window_renderer.WindowSwapchain,
    manager: *panel_manager.PanelManager,
    ui_state: zui.ui.main_window.WindowUiState = .{},
    title: []u8,
    persist_in_workspace: bool = false,
    owns_manager: bool = true,
    owns_swapchain: bool = true,
};

const SessionMessageState = struct {
    key: []const u8,
    messages: std.ArrayList(ChatMessage) = .empty,
    streaming_request_id: ?[]const u8 = null,
};

const DockTabHit = struct {
    panel_id: workspace.PanelId,
    node_id: dock_graph.NodeId,
    tab_index: usize,
    rect: UiRect,
};

const DockDropTarget = struct {
    node_id: dock_graph.NodeId,
    location: dock_graph.DropLocation,
    rect: UiRect,
};

const DockTabHitList = struct {
    items: [96]DockTabHit = undefined,
    len: usize = 0,

    fn append(self: *DockTabHitList, item: DockTabHit) void {
        if (self.len >= self.items.len) return;
        self.items[self.len] = item;
        self.len += 1;
    }

    fn slice(self: *const DockTabHitList) []const DockTabHit {
        return self.items[0..self.len];
    }
};

const DockDropTargetList = struct {
    items: [96]DockDropTarget = undefined,
    len: usize = 0,

    fn append(self: *DockDropTargetList, item: DockDropTarget) void {
        if (self.len >= self.items.len) return;
        self.items[self.len] = item;
        self.len += 1;
    }

    fn findAt(self: *const DockDropTargetList, pos: [2]f32) ?DockDropTarget {
        for (self.items[0..self.len]) |tgt| {
            if (tgt.location != .center) continue;
            if (tgt.rect.contains(pos)) return tgt;
        }
        for (self.items[0..self.len]) |tgt| {
            if (tgt.location == .center) continue;
            if (tgt.rect.contains(pos)) return tgt;
        }
        return null;
    }

    fn clear(self: *DockDropTargetList) void {
        self.len = 0;
    }
};

const DockInteractionResult = struct {
    focus_panel_id: ?workspace.PanelId = null,
    changed_layout: bool = false,
    detach_panel_id: ?workspace.PanelId = null,
};

const WindowMouseHit = struct {
    win: *UiWindow,
    local_pos: [2]f32,
};

fn findTabHitAt(tab_hits: *const DockTabHitList, pos: [2]f32) ?DockTabHit {
    var idx = tab_hits.len;
    while (idx > 0) {
        idx -= 1;
        const hit = tab_hits.items[idx];
        if (hit.rect.contains(pos)) return hit;
    }
    return null;
}

fn dockDropTargetLabel(location: dock_graph.DropLocation) []const u8 {
    return switch (location) {
        .center => "Dock Center",
        .left => "Dock Left",
        .right => "Dock Right",
        .top => "Dock Top",
        .bottom => "Dock Bottom",
    };
}


const App = struct {
    allocator: std.mem.Allocator,
    window: *c.SDL_Window,
    gpu: zapp.multi_window_renderer.Shared,
    swapchain: zapp.multi_window_renderer.WindowSwapchain,

    ui_windows: std.ArrayList(*UiWindow) = .empty,
    main_window_id: u32 = 0,

    // Panel state
    settings_panel: SettingsPanel,
    chat_panel_state: zui.ui.workspace.ChatPanel = .{},

    // Workspace and panel management
    next_panel_id: workspace.PanelId = 1,
    manager: panel_manager.PanelManager,

    // Chat state
    chat_input: std.ArrayList(u8) = .empty,
    chat_sessions: std.ArrayList(ChatSession) = .empty,
    session_messages: std.ArrayList(SessionMessageState) = .empty,
    current_session_key: ?[]const u8 = null,
    pending_send_request_id: ?[]const u8 = null,
    pending_send_message_id: ?[]const u8 = null,
    pending_send_session_key: ?[]const u8 = null,
    awaiting_reply: bool = false,
    ui_commands: zui.ui.render.command_list.CommandList,

    ws_client: ?ws_client_mod.WebSocketClient = null,

    connection_state: ConnectionState = .disconnected,
    status_text: []u8,

    theme: *const zui.Theme,
    ui_scale: f32 = 1.0,
    config: config_mod.Config,
    client_context: client_state.ClientContext,
    agent_registry: client_agents.AgentRegistry,

    running: bool = true,

    // Input state
    mouse_x: f32 = 0,
    mouse_y: f32 = 0,
    mouse_down: bool = false,
    mouse_clicked: bool = false,
    mouse_released: bool = false,
    render_input_queue: ?*ui_input_state.InputQueue = null,
    frame_dt_seconds: f32 = 1.0 / 60.0,

    pending_close_window_id: ?u32 = null,

    message_counter: u64 = 0,
    debug_frame_counter: u64 = 0,
    frame_clock: zapp.frame_clock.FrameClock,
    workspace_recovery_blocked_until: u64 = 0,
    workspace_recovery_blocked_for_manager: usize = 0,
    workspace_recovery_suspended_until: u64 = 0,
    workspace_recovery_suspended_for_manager: usize = 0,
    workspace_recovery_failures: u8 = 0,
    workspace_snapshot_restore_cooldown_until: u64 = 0,

    // UI State for dock
    ui_state: zui.ui.main_window.WindowUiState = .{},
    workspace_snapshot: ?workspace.WorkspaceSnapshot = null,
    workspace_snapshot_stale: bool = false,
    workspace_snapshot_restore_attempted: bool = false,

    pub fn init(allocator: std.mem.Allocator) !App {
        try zapp.sdl_app.init(.{ .video = true, .events = true, .gamepad = false });
        zapp.clipboard.init();

        const window = zapp.sdl_app.createWindow("ZiggyStarSpider GUI", 1024, 720, c.SDL_WINDOW_RESIZABLE) catch {
            return error.SdlWindowCreateFailed;
        };
        errdefer c.SDL_DestroyWindow(window);

        var gpu = try zapp.multi_window_renderer.Shared.init(allocator, window);
        errdefer gpu.deinit();

        const swapchain = zapp.multi_window_renderer.WindowSwapchain.initMain(&gpu, window);

        zapp.sdl_app.startTextInput(window);

        // Initialize theme - use clean theme (light mode as default for clean look)
        zui.theme.setMode(.light);

        // Initialize workspace with default panels
        var ws = try workspace.Workspace.initDefault(allocator);
        errdefer ws.deinit(allocator);

        // Replace the default chat panel session key with null for now
        for (ws.panels.items) |*panel| {
            if (panel.kind == .Chat) {
                if (panel.data.Chat.session_key) |key| {
                    allocator.free(key);
                    panel.data.Chat.session_key = null;
                }
                if (panel.data.Chat.agent_id) |id| {
                    allocator.free(id);
                    panel.data.Chat.agent_id = try allocator.dupe(u8, "zss");
                }
            }
        }

        // Load config
        var config = config_mod.Config.load(allocator) catch |err| blk: {
            std.log.warn("Failed to load config: {s}, using defaults", .{@errorName(err)});
            break :blk try config_mod.Config.init(allocator);
        };
        errdefer config.deinit();

        // Initialize settings panel with config values
        var settings_panel = SettingsPanel.init(allocator);
        settings_panel.server_url.clearRetainingCapacity();
        settings_panel.server_url.appendSlice(allocator, config.server_url) catch {};
        settings_panel.default_session.clearRetainingCapacity();
        if (config.default_session) |value| {
            settings_panel.default_session.appendSlice(allocator, value) catch {};
        } else {
            settings_panel.default_session.appendSlice(allocator, "main") catch {};
        }
        if (config.ui_theme) |value| {
            settings_panel.ui_theme.clearRetainingCapacity();
            settings_panel.ui_theme.appendSlice(allocator, value) catch {};
        }
        if (config.ui_profile) |value| {
            settings_panel.ui_profile.clearRetainingCapacity();
            settings_panel.ui_profile.appendSlice(allocator, value) catch {};
        }
        if (config.ui_theme_pack) |value| {
            settings_panel.ui_theme_pack.clearRetainingCapacity();
            settings_panel.ui_theme_pack.appendSlice(allocator, value) catch {};
        }
        settings_panel.watch_theme_pack = config.ui_watch_theme_pack;
        settings_panel.auto_connect_on_launch = config.auto_connect_on_launch;

        var app = App{
            .allocator = allocator,
            .window = window,
            .gpu = gpu,
            .swapchain = swapchain,
            .settings_panel = settings_panel,
            .client_context = undefined,
            .agent_registry = undefined,
            .status_text = try allocator.dupe(u8, "Not connected"),
            .theme = zui.theme.current(),
            .ui_scale = 1.0,
            .config = config,
            .ui_commands = zui.ui.render.command_list.CommandList.init(allocator),
            .frame_clock = zapp.frame_clock.FrameClock.init(60),
            .manager = undefined,
        };
        app.applyThemeFromSettings();

        app.client_context = try client_state.ClientContext.init(allocator);
        errdefer app.client_context.deinit();
        app.agent_registry = client_agents.AgentRegistry.initEmpty(allocator);
        errdefer app.agent_registry.deinit(allocator);

        app.manager = panel_manager.PanelManager.init(allocator, ws, &app.next_panel_id);
        app.bindNextPanelId(&app.manager);
        errdefer app.manager.deinit();

        app.captureWorkspaceSnapshot(&app.manager);

        if (app.config.default_session) |default_session| {
            const seed = if (default_session.len > 0) default_session else "main";
            app.ensureSessionExists(seed, seed) catch {};
        } else {
            app.ensureSessionExists("main", "Main") catch {};
        }

        const main_window = try app.createUiWindowFromExisting(
            window,
            "ZiggyStarSpider GUI",
            &app.manager,
            true,
            false,
            false,
            false,
        );
        try app.ui_windows.append(allocator, main_window);
        app.main_window_id = main_window.id;

        errdefer app.settings_panel.deinit(allocator);
        errdefer allocator.free(app.status_text);

        ui_sdl_input_backend.init(allocator);
        ui_input_router.setBackend(ui_input_backend.sdl3);

        // Cleanup on initialization failure after this point
        errdefer {
            var i: usize = 0;
            while (i < app.ui_windows.items.len) : (i += 1) {
                app.destroyUiWindow(app.ui_windows.items[i]);
            }
            app.ui_windows.clearRetainingCapacity();
            app.ui_windows.deinit(app.allocator);
        }
        return app;
    }

    pub fn deinit(self: *App) void {
        self.disconnect();
        self.clearSessions();
        self.chat_sessions.deinit(self.allocator);
        self.session_messages.deinit(self.allocator);
        self.invalidateWorkspaceSnapshot();
        if (self.pending_send_request_id) |request_id| self.allocator.free(request_id);
        if (self.pending_send_message_id) |message_id| self.allocator.free(message_id);
        if (self.pending_send_session_key) |session_key| self.allocator.free(session_key);

        zui.ChatView(ChatMessage).deinit(&self.chat_panel_state.view, self.allocator);

        self.settings_panel.deinit(self.allocator);
        self.chat_input.deinit(self.allocator);
        self.client_context.deinit();
        self.agent_registry.deinit(self.allocator);

        self.ui_commands.deinit();
        self.manager.deinit();
        while (self.ui_windows.items.len > 0) {
            const maybe_window = self.ui_windows.pop();
            if (maybe_window) |window| self.destroyUiWindow(window);
        }
        self.ui_windows.deinit(self.allocator);
        zui.ui.main_window.deinit(self.allocator);
        ui_input_router.deinit(self.allocator);
        ui_sdl_input_backend.deinit();

        self.allocator.free(self.status_text);
        self.config.deinit();

        self.swapchain.deinit();
        self.gpu.deinit();

        zapp.sdl_app.stopTextInput(self.window);
        c.SDL_DestroyWindow(self.window);
        zapp.sdl_app.deinit();
    }

    pub fn run(self: *App) !void {
        while (self.running) {
            self.bindMainWindowManager();
            self.debug_frame_counter += 1;
            _ = self.frame_clock.beginFrame();
            const polled = zapp.sdl_app.pollEventsToInput();
            _ = ui_input_router.beginFrame(self.allocator);
            if (polled.quit_requested) {
                self.running = false;
            }

            if (polled.window_close_requested and polled.window_close_id == self.main_window_id) {
                self.running = false;
            }

            if (polled.window_close_requested and polled.window_close_id != self.main_window_id) {
                self.closeUiWindowById(polled.window_close_id);
            }

            var requested_spawn_window = false;
            var i: usize = 0;
            while (i < self.ui_windows.items.len) : (i += 1) {
                const window = self.ui_windows.items[i];
                const manager = self.managerForWindow(window);
                if ((window.id == self.main_window_id or window.window == self.window) and window.manager != manager) {
                    window.manager = manager;
                    window.owns_manager = false;
                }
                if (@intFromPtr(manager) == 0) {
                    std.log.err("run: window manager pointer is null (window_id={d})", .{window.id});
                    self.drawUnavailableWorkspaceFrame(window, "Workspace manager pointer is null");
                    continue;
                }
                self.bindNextPanelId(manager);
                const manager_healthy = self.ensureWindowManagerHealthy(manager);
                window.queue.clear(self.allocator);
                self.mouse_clicked = false;
                self.mouse_released = false;

                // Get DPI scale for window-specific rendering
                const dpi_scale_raw: f32 = c.SDL_GetWindowDisplayScale(window.window);
                const dpi_scale: f32 = if (dpi_scale_raw > 0.0) dpi_scale_raw else 1.0;
                self.ui_scale = dpi_scale;
                zui.ui.theme.applyTypography(dpi_scale);

                if (!manager_healthy) {
                    ui_input_router.setExternalQueue(&window.queue);
                    zapp.sdl_app.collectWindowInput(self.allocator, window.window, &window.queue);
                    self.drawUnavailableWorkspaceFrame(window, "Unable to recover workspace state");
                    ui_input_state.endFrame(&window.queue);
                    ui_input_router.setExternalQueue(null);
                    continue;
                }

                ui_input_router.setExternalQueue(&window.queue);
                zapp.sdl_app.collectWindowInput(self.allocator, window.window, &window.queue);
                try self.processInputEvents(&window.queue, &requested_spawn_window, window, manager);

                ui_input_router.setExternalQueue(&window.queue);
                self.drawFrame(window);
                ui_input_state.endFrame(&window.queue);
                ui_input_router.setExternalQueue(null);
            }

            if (requested_spawn_window) {
                self.spawnUiWindow() catch |err| {
                    std.log.err("Failed to spawn additional window: {s}", .{@errorName(err)});
                };
            }

            if (self.pending_close_window_id) |window_id| {
                self.pending_close_window_id = null;
                self.closeUiWindowById(window_id);
            }

            try self.pollWebSocket();
            self.frame_clock.endFrame();
        }
    }

    fn bindMainWindowManager(self: *App) void {
        var i: usize = 0;
        while (i < self.ui_windows.items.len) : (i += 1) {
            const window = self.ui_windows.items[i];
            if (window.id != self.main_window_id and window.window != self.window) continue;
            if (window.manager != &self.manager) {
                if (self.shouldLogDebug(1200)) {
                    std.log.debug(
                        "bindMainWindowManager: repairing stale main window manager pointer (old=0x{x}, expected=0x{x})",
                        .{ @intFromPtr(window.manager), @intFromPtr(&self.manager) },
                    );
                }
                window.manager = &self.manager;
                window.owns_manager = false;
            }
            return;
        }
    }

    fn managerForWindow(self: *App, ui_window: *UiWindow) *panel_manager.PanelManager {
        if (ui_window.id == self.main_window_id or ui_window.window == self.window) {
            return &self.manager;
        }
        return ui_window.manager;
    }

    fn createUiWindowFromExisting(
        self: *App,
        window: *c.SDL_Window,
        title: []const u8,
        manager: *panel_manager.PanelManager,
        is_main_swapchain: bool,
        persist_in_workspace: bool,
        owns_manager: bool,
        owns_swapchain: bool,
    ) !*UiWindow {
        const title_copy = try self.allocator.dupe(u8, title);
        errdefer self.allocator.free(title_copy);

        const swapchain = if (is_main_swapchain)
            zapp.multi_window_renderer.WindowSwapchain.initMain(&self.gpu, window)
        else
            try zapp.multi_window_renderer.WindowSwapchain.initOwned(&self.gpu, window);

        const out = try self.allocator.create(UiWindow);
        errdefer self.allocator.destroy(out);

        out.* = .{
            .window = window,
            .id = c.SDL_GetWindowID(window),
            .queue = ui_input_state.InputQueue.init(self.allocator),
            .swapchain = swapchain,
            .manager = manager,
            .title = title_copy,
            .persist_in_workspace = persist_in_workspace,
            .owns_manager = owns_manager,
            .owns_swapchain = owns_swapchain,
        };
        return out;
    }

    fn destroyUiWindow(self: *App, w: *UiWindow) void {
        w.queue.deinit(self.allocator);

        if (w.owns_swapchain) {
            w.swapchain.deinit();
        }
        if (w.owns_manager) {
            w.manager.deinit();
            self.allocator.destroy(w.manager);
        }
        self.allocator.free(w.title);
        if (w.window != self.window) {
            c.SDL_DestroyWindow(w.window);
        }
        self.allocator.destroy(w);
    }

    fn closeUiWindowById(self: *App, window_id: u32) void {
        var i: usize = 0;
        while (i < self.ui_windows.items.len) : (i += 1) {
            const w = self.ui_windows.items[i];
            if (w.id == window_id and w.id != self.main_window_id) {
                _ = self.ui_windows.swapRemove(i);
                if (w.persist_in_workspace) {
                    self.attachDetachedPanelsToMain(w.manager);
                }
                self.destroyUiWindow(w);
                return;
            }
        }
    }

    fn attachDetachedPanelsToMain(self: *App, source_manager: *panel_manager.PanelManager) void {
        if (source_manager == &self.manager) return;
        self.bindNextPanelId(source_manager);
        self.bindNextPanelId(&self.manager);

        if (!self.isWorkspaceStateReasonable(source_manager)) {
            std.log.warn("attachDetachedPanelsToMain: source workspace unhealthy, attempting recovery", .{});
            self.tryDeinitWorkspaceForReset(source_manager);
            if (!self.isWorkspaceStateReasonable(source_manager)) {
                source_manager.workspace = workspace.Workspace.initEmpty(self.allocator);
                return;
            }
        }

        if (source_manager.workspace.panels.items.len > MAX_REASONABLE_PANEL_COUNT) {
            std.log.warn("attachDetachedPanelsToMain: source panels unreasonable ({d}), discarding source workspace", .{
                source_manager.workspace.panels.items.len,
            });
            self.tryDeinitWorkspaceForReset(source_manager);
            source_manager.workspace = workspace.Workspace.initEmpty(self.allocator);
            return;
        }

        if (source_manager.workspace.panels.items.len == 0) {
            source_manager.workspace.focused_panel_id = null;
            source_manager.workspace.dock_layout.clear();
            source_manager.workspace.dock_layout.root = null;
            source_manager.workspace.markDirty();
            return;
        }

        while (source_manager.workspace.panels.items.len > 0) {
            const panel_id = source_manager.workspace.panels.items[source_manager.workspace.panels.items.len - 1].id;
            if (source_manager.takePanel(panel_id)) |moved_panel| {
                self.appendPanelToManager(&self.manager, moved_panel) catch {
                    var fallback = moved_panel;
                    fallback.deinit(self.allocator);
                };
            } else {
                break;
            }
        }

        if (self.manager.workspace.syncDockLayout() catch false) {
            self.manager.workspace.markDirty();
        }

        source_manager.workspace.dock_layout.clear();
        source_manager.workspace.dock_layout.root = null;
        source_manager.workspace.focused_panel_id = null;
        source_manager.workspace.markDirty();
        self.recomputeManagerNextId(source_manager);
    }

    fn cloneWorkspace(self: *App, src: *const workspace.Workspace) !workspace.Workspace {
        var snapshot = try src.toSnapshot(self.allocator);
        defer snapshot.deinit(self.allocator);
        return try workspace.Workspace.fromSnapshot(self.allocator, snapshot);
    }

    fn remapWorkspacePanelIds(
        self: *App,
        ws: *workspace.Workspace,
        next_panel_id: *workspace.PanelId,
    ) !void {
        var map = std.AutoHashMap(workspace.PanelId, workspace.PanelId).init(self.allocator);
        defer map.deinit();

        for (ws.panels.items) |*panel| {
            const old_id = panel.id;
            const new_id = next_panel_id.*;
            next_panel_id.* += 1;
            panel.id = new_id;
            try map.put(old_id, new_id);
        }

        if (ws.focused_panel_id) |old_focus| {
            ws.focused_panel_id = map.get(old_focus);
        }
    }

    fn cloneWorkspaceRemap(
        self: *App,
        src: *const workspace.Workspace,
        next_panel_id: *workspace.PanelId,
    ) !workspace.Workspace {
        var ws = try self.cloneWorkspace(src);
        errdefer ws.deinit(self.allocator);
        try self.remapWorkspacePanelIds(&ws, next_panel_id);
        _ = try ws.syncDockLayout();
        return ws;
    }

    fn spawnUiWindow(self: *App) !void {
        const width: c_int = 960;
        const height: c_int = 720;
        const title = try std.fmt.allocPrint(self.allocator, "ZiggyStarSpider GUI ({d})", .{self.ui_windows.items.len});
        defer self.allocator.free(title);
        const title_with_null = try self.allocator.alloc(u8, title.len + 1);
        defer self.allocator.free(title_with_null);
        @memcpy(title_with_null[0..title.len], title);
        title_with_null[title.len] = 0;
        const title_z: [:0]const u8 = title_with_null[0..title.len :0];

        const win = zapp.sdl_app.createWindow(title_z, width, height, c.SDL_WINDOW_RESIZABLE) catch {
            return error.SdlWindowCreateFailed;
        };
        errdefer c.SDL_DestroyWindow(win);

        var pos_x: c_int = 0;
        var pos_y: c_int = 0;
        _ = c.SDL_GetWindowPosition(self.window, &pos_x, &pos_y);
        const offset: c_int = @intCast(@min(self.ui_windows.items.len * 24, 220));
        _ = c.SDL_SetWindowPosition(win, pos_x + offset, pos_y + offset);

        var cloned_workspace = try self.cloneWorkspaceRemap(&self.manager.workspace, &self.next_panel_id);
        var should_cleanup_workspace = true;
        errdefer if (should_cleanup_workspace) cloned_workspace.deinit(self.allocator);

        const new_manager = try self.allocator.create(panel_manager.PanelManager);
        errdefer self.allocator.destroy(new_manager);

        var should_cleanup_new_manager = true;
        new_manager.* = panel_manager.PanelManager.init(
            self.allocator,
            cloned_workspace,
            &self.next_panel_id,
        );
        self.bindNextPanelId(new_manager);
        should_cleanup_workspace = false;
        errdefer if (should_cleanup_new_manager) {
            new_manager.deinit();
            self.allocator.destroy(new_manager);
        };

        const new_window = try self.createUiWindowFromExisting(
            win,
            title,
            new_manager,
            false,
            true,
            true,
            true,
        );
        should_cleanup_new_manager = false;
        self.ui_windows.append(self.allocator, new_window) catch |err| {
            self.destroyUiWindow(new_window);
            return err;
        };
    }

    fn processInputEvents(
        self: *App,
        queue: *ui_input_state.InputQueue,
        request_spawn_window: *bool,
        ui_window: *UiWindow,
        manager: *panel_manager.PanelManager,
    ) !void {
        self.mouse_x = queue.state.mouse_pos[0];
        self.mouse_y = queue.state.mouse_pos[1];
        self.mouse_down = queue.state.mouse_down_left;

        for (queue.events.items) |evt| {
            switch (evt) {
                .mouse_down => |md| {
                    if (md.button == .left) self.mouse_clicked = true;
                },
                .mouse_up => |mu| {
                    if (mu.button == .left) self.mouse_released = true;
                },
                .key_down => |ke| {
                    try self.handleKeyDownEvent(ke, request_spawn_window, manager);
                },
                .text_input => |txt| {
                    try self.handleTextInput(txt.text);
                },
                else => {},
            }
        }

        var dock_area = self.dockViewportForWindow(ui_window) orelse blk: {
            var fb_w: c_int = 0;
            var fb_h: c_int = 0;
            _ = c.SDL_GetWindowSizeInPixels(ui_window.window, &fb_w, &fb_h);
            break :blk UiRect.fromMinSize(
                .{ 0.0, 0.0 },
                .{
                    if (fb_w > 0) @floatFromInt(fb_w) else 1.0,
                    if (fb_h > 0) @floatFromInt(fb_h) else 1.0,
                },
            );
        };
        const dock_area_size = dock_area.size();
        if (dock_area_size[0] <= 1.0 or dock_area_size[1] <= 1.0) {
            var fb_w: c_int = 0;
            var fb_h: c_int = 0;
            _ = c.SDL_GetWindowSizeInPixels(ui_window.window, &fb_w, &fb_h);
            dock_area = UiRect.fromMinSize(
                .{ 0.0, 0.0 },
                .{
                    if (fb_w > 0) @floatFromInt(fb_w) else 1.0,
                    if (fb_h > 0) @floatFromInt(fb_h) else 1.0,
                },
            );
        }

        var tab_hits = DockTabHitList{};
        var drop_targets = DockDropTargetList{};
        self.collectDockInteractionGeometry(manager, dock_area, &tab_hits, &drop_targets);

        const splitters = manager.workspace.dock_layout.computeSplitters(dock_area);
        if (self.handleDockSplitInteractions(queue, ui_window, manager, &splitters)) {
            manager.workspace.markDirty();
        }

        const dock_result = self.handleDockTabInteractions(
            queue,
            manager,
            ui_window,
            &tab_hits,
            &drop_targets,
            dock_area,
        );
        if (dock_result.changed_layout) {
            manager.workspace.markDirty();
        }
        if (dock_result.focus_panel_id) |panel_id| {
            manager.focusPanel(panel_id);
        }
        if (dock_result.detach_panel_id) |panel_id| {
            self.handleDockDetachRequest(ui_window, panel_id);
        }
    }

    fn findSplitterAt(splitters: *const dock_graph.SplitterResult, pos: [2]f32) ?dock_graph.Splitter {
        var idx: usize = splitters.len;
        while (idx > 0) {
            idx -= 1;
            const splitter = splitters.splitters[idx];
            if (splitter.handle_rect.contains(pos)) return splitter;
        }
        return null;
    }

    fn findSplitterByNode(
        splitters: *const dock_graph.SplitterResult,
        node_id: dock_graph.NodeId,
    ) ?dock_graph.Splitter {
        for (splitters.slice()) |splitter| {
            if (splitter.node_id == node_id) return splitter;
        }
        return null;
    }

    fn handleDockSplitInteractions(
        self: *App,
        queue: *ui_input_state.InputQueue,
        ui_window: *UiWindow,
        manager: *panel_manager.PanelManager,
        splitters: *const dock_graph.SplitterResult,
    ) bool {
        _ = self;
        const split_drag = &ui_window.ui_state.split_drag;
        var changed = false;

        for (queue.events.items) |evt| {
            switch (evt) {
                .focus_lost => split_drag.clear(),
                .mouse_down => |md| {
                    if (md.button != .left) continue;
                    if (findSplitterAt(splitters, md.pos)) |splitter| {
                        split_drag.node_id = splitter.node_id;
                        split_drag.axis = splitter.axis;
                    }
                },
                .mouse_up => |mu| {
                    if (mu.button == .left) split_drag.clear();
                },
                else => {},
            }
        }

        const dragging_node = split_drag.node_id orelse return changed;
        const active_splitter = findSplitterByNode(splitters, dragging_node) orelse {
            split_drag.clear();
            return changed;
        };

        const container = active_splitter.container_rect;
        const size = container.size();
        const min_px: f32 = 120.0;

        if (active_splitter.axis == .vertical and size[0] > 0.0) {
            const min_ratio = std.math.clamp(min_px / size[0], 0.05, 0.45);
            const max_ratio = 1.0 - min_ratio;
            const ratio = std.math.clamp((queue.state.mouse_pos[0] - container.min[0]) / size[0], min_ratio, max_ratio);
            if (manager.workspace.dock_layout.setSplitRatio(active_splitter.node_id, ratio)) {
                changed = true;
            }
        } else if (active_splitter.axis == .horizontal and size[1] > 0.0) {
            const min_ratio = std.math.clamp(min_px / size[1], 0.05, 0.45);
            const max_ratio = 1.0 - min_ratio;
            const ratio = std.math.clamp((queue.state.mouse_pos[1] - container.min[1]) / size[1], min_ratio, max_ratio);
            if (manager.workspace.dock_layout.setSplitRatio(active_splitter.node_id, ratio)) {
                changed = true;
            }
        }

        if (!queue.state.mouse_down_left) split_drag.clear();
        return changed;
    }

    fn handleDockTabInteractions(
        self: *App,
        queue: *ui_input_state.InputQueue,
        manager: *panel_manager.PanelManager,
        ui_window: *UiWindow,
        tab_hits: *const DockTabHitList,
        drop_targets: *const DockDropTargetList,
        dock_rect: UiRect,
    ) DockInteractionResult {
        const drag_state = &ui_window.ui_state.dock_drag;
        var out = DockInteractionResult{};
        var left_release = false;
        var mouse_up_pos: ?[2]f32 = null;

        for (queue.events.items) |evt| {
            switch (evt) {
                .focus_lost => {
                    if (drag_state.panel_id) |pid| {
                        if (drag_state.dragging) {
                            out.detach_panel_id = pid;
                            out.focus_panel_id = pid;
                        }
                    }
                    drag_state.clear();
                },
                .mouse_down => |md| {
                    if (md.button != .left) continue;
                    if (findTabHitAt(tab_hits, md.pos)) |hit| {
                        drag_state.panel_id = hit.panel_id;
                        drag_state.source_node_id = hit.node_id;
                        drag_state.source_tab_index = hit.tab_index;
                        drag_state.press_pos = md.pos;
                        drag_state.dragging = false;
                    }
                },
                .mouse_up => |mu| {
                    if (mu.button == .left) {
                        left_release = true;
                        mouse_up_pos = mu.pos;
                    }
                },
                else => {},
            }
        }

        if (drag_state.panel_id) |panel_id| {
            if (self.findPanelById(manager, panel_id) == null) {
                drag_state.clear();
            }
        }

        if (drag_state.panel_id != null and queue.state.mouse_down_left and !left_release) {
            if (!drag_state.dragging) {
                const dx = queue.state.mouse_pos[0] - drag_state.press_pos[0];
                const dy = queue.state.mouse_pos[1] - drag_state.press_pos[1];
                if (dx * dx + dy * dy >= 16.0) {
                    drag_state.dragging = true;
                }
            }
        }

        if (left_release and drag_state.panel_id != null) {
            const drag_panel_id = drag_state.panel_id.?;
            const release_pos = mouse_up_pos orelse queue.state.mouse_pos;
            if (drag_state.dragging) {
                if (drop_targets.findAt(release_pos)) |target| {
                    const changed = if (target.location == .center)
                        manager.workspace.dock_layout.movePanelToTabs(drag_panel_id, target.node_id, null) catch false
                    else
                        manager.workspace.dock_layout.splitNodeWithPanel(target.node_id, drag_panel_id, target.location) catch false;
                    const repaired = manager.workspace.syncDockLayout() catch false;
                    if (changed or repaired) {
                        out.changed_layout = true;
                        out.focus_panel_id = drag_panel_id;
                    }
                } else if (!dock_rect.contains(release_pos)) {
                    out.detach_panel_id = drag_panel_id;
                    out.focus_panel_id = drag_panel_id;
                } else {
                    out.focus_panel_id = drag_panel_id;
                }
            } else if (findTabHitAt(tab_hits, release_pos)) |hit| {
                if (hit.panel_id == drag_panel_id) {
                    if (manager.workspace.dock_layout.setActiveTab(hit.node_id, hit.tab_index)) {
                        out.changed_layout = true;
                    }
                    out.focus_panel_id = hit.panel_id;
                }
            }
            drag_state.clear();
        } else if (!queue.state.mouse_down_left and drag_state.panel_id != null) {
            const drag_panel_id = drag_state.panel_id.?;
            if (drag_state.dragging) {
                const release_pos = queue.state.mouse_pos;
                if (drop_targets.findAt(release_pos)) |target| {
                    const changed = if (target.location == .center)
                        manager.workspace.dock_layout.movePanelToTabs(drag_panel_id, target.node_id, null) catch false
                    else
                        manager.workspace.dock_layout.splitNodeWithPanel(target.node_id, drag_panel_id, target.location) catch false;
                    const repaired = manager.workspace.syncDockLayout() catch false;
                    const committed = changed or repaired;
                    if (committed) {
                        out.changed_layout = true;
                        out.focus_panel_id = drag_panel_id;
                    } else if (!dock_rect.contains(release_pos)) {
                        out.detach_panel_id = drag_panel_id;
                        out.focus_panel_id = drag_panel_id;
                    } else {
                        out.focus_panel_id = drag_panel_id;
                    }
                } else if (!dock_rect.contains(release_pos)) {
                    out.detach_panel_id = drag_panel_id;
                    out.focus_panel_id = drag_panel_id;
                } else {
                    out.focus_panel_id = drag_panel_id;
                }
            }
            drag_state.clear();
        }

        return out;
    }

    fn handleDockDetachRequest(
        self: *App,
        source_window: *UiWindow,
        panel_id: workspace.PanelId,
    ) void {
        const source_manager = self.managerForWindow(source_window);
        const moved = source_manager.takePanel(panel_id) orelse return;
        if (source_manager.workspace.syncDockLayout() catch false) {
            source_manager.workspace.markDirty();
        }

        const remaining_panel = self.tryAttachPanelToOtherWindow(source_window, moved);
        if (remaining_panel) |panel| {
            if (!self.createDetachedWindowFromPanel(source_window, panel)) {
                source_manager.putPanel(panel) catch {
                    var tmp = panel;
                    tmp.deinit(self.allocator);
                    return;
                };
                source_manager.workspace.markDirty();
                if (source_manager.workspace.syncDockLayout() catch false) {
                    source_manager.workspace.markDirty();
                }
                source_manager.focusPanel(panel.id);
            } else {
                self.queueCloseIfNowEmptyDetachedWindow(source_window);
            }
        }
    }

    fn tryAttachPanelToOtherWindow(
        self: *App,
        source_window: *UiWindow,
        panel: workspace.Panel,
    ) ?workspace.Panel {
        var target_window: ?*UiWindow = null;
        var target_local_pos: [2]f32 = .{ 0.0, 0.0 };

        if (self.focusedWindowMouseHit(source_window.id)) |hit| {
            target_window = hit.win;
            target_local_pos = hit.local_pos;
        } else if (self.windowUnderGlobalMouse(source_window.id)) |hit| {
            target_window = hit.win;
            target_local_pos = hit.local_pos;
        } else {
            return panel;
        }

        const destination = target_window orelse return panel;
        const destination_manager = self.managerForWindow(destination);
        const drop = self.dockDropTargetForWindow(destination, target_local_pos) orelse {
            const source_manager = self.managerForWindow(source_window);
            source_manager.putPanel(panel) catch {
                var tmp = panel;
                tmp.deinit(self.allocator);
                return null;
            };
            if (source_manager.workspace.syncDockLayout() catch false) {
                source_manager.workspace.markDirty();
            }
            source_manager.focusPanel(panel.id);
            return null;
        };

        destination_manager.putPanel(panel) catch {
            const source_manager = self.managerForWindow(source_window);
            source_manager.putPanel(panel) catch {
                var tmp = panel;
                tmp.deinit(self.allocator);
                return null;
            };
            if (source_manager.workspace.syncDockLayout() catch false) {
                source_manager.workspace.markDirty();
            }
            source_manager.focusPanel(panel.id);
            return null;
        };
        destination_manager.workspace.markDirty();
        if (destination_manager.workspace.syncDockLayout() catch false) {
            destination_manager.workspace.markDirty();
        }

        const moved = if (drop.location == .center)
            destination_manager.workspace.dock_layout.movePanelToTabs(panel.id, drop.node_id, null) catch false
        else
            destination_manager.workspace.dock_layout.splitNodeWithPanel(drop.node_id, panel.id, drop.location) catch false;
        var moved_final = moved;
        if (!moved_final and drop.location != .center) {
            if (destination_manager.workspace.dock_layout.root) |root_id| {
                moved_final = destination_manager.workspace.dock_layout.splitNodeWithPanel(root_id, panel.id, drop.location) catch false;
            }
        }

        const panel_loc = destination_manager.workspace.dock_layout.findPanel(panel.id);
        const is_reachable = self.panelIsReachableInWindowLayout(destination, panel.id);
        const side_drop = drop.location != .center;
        const center_committed = if (!side_drop and panel_loc != null)
            panel_loc.?.node_id == drop.node_id
        else
            false;
        const side_committed = if (side_drop and panel_loc != null)
            moved_final and panel_loc.?.node_id != drop.node_id and is_reachable
        else
            false;
        const attach_committed = if (side_drop)
            side_committed
        else
            (moved_final or center_committed) and is_reachable;

        if (attach_committed and panel_loc != null) {
            destination_manager.focusPanel(panel.id);
            self.queueCloseIfNowEmptyDetachedWindow(source_window);
            return null;
        }

        const restored = destination_manager.takePanel(panel.id) orelse panel;
        const source_manager = self.managerForWindow(source_window);
        source_manager.putPanel(restored) catch {
            var tmp = restored;
            tmp.deinit(self.allocator);
            return null;
        };
        if (source_manager.workspace.syncDockLayout() catch false) {
            source_manager.workspace.markDirty();
        }
        source_manager.focusPanel(restored.id);
        return null;
    }

    fn queueCloseIfNowEmptyDetachedWindow(self: *App, window: *UiWindow) void {
        if (window.id == self.main_window_id) return;
        const manager = self.managerForWindow(window);
        if (manager.workspace.panels.items.len != 0) return;
        self.pending_close_window_id = window.id;
    }

    fn dockDropTargetForWindow(
        self: *App,
        window: *UiWindow,
        local_pos: [2]f32,
    ) ?dock_drop.DropTarget {
        const viewport = self.dockViewportForWindow(window) orelse return null;
        if (!viewport.contains(local_pos)) return null;
        const manager = self.managerForWindow(window);
        return dock_drop.pickDropTarget(&manager.workspace.dock_layout, viewport, local_pos);
    }

    fn dockViewportForWindow(self: *App, window: *UiWindow) ?UiRect {
        _ = self;
        const viewport = window.ui_state.last_dock_content_rect;
        const size = viewport.size();
        if (size[0] <= 1.0 or size[1] <= 1.0) return null;
        return viewport;
    }

    fn panelIsReachableInWindowLayout(
        self: *App,
        window: *UiWindow,
        panel_id: workspace.PanelId,
    ) bool {
        const manager = self.managerForWindow(window);
        const loc = manager.workspace.dock_layout.findPanel(panel_id) orelse return false;
        const viewport = self.dockViewportForWindow(window) orelse return false;
        const layout = manager.workspace.dock_layout.computeLayout(viewport);
        for (layout.slice()) |group| {
            if (group.node_id == loc.node_id) return true;
        }
        return false;
    }

    fn windowUnderGlobalMouse(self: *App, exclude_window_id: u32) ?WindowMouseHit {
        var mouse_global_x: f32 = 0.0;
        var mouse_global_y: f32 = 0.0;
        _ = c.SDL_GetGlobalMouseState(&mouse_global_x, &mouse_global_y);

        var i: usize = self.ui_windows.items.len;
        while (i > 0) {
            i -= 1;
            const window = self.ui_windows.items[i];
            if (window.id == exclude_window_id) continue;

            var window_x: c_int = 0;
            var window_y: c_int = 0;
            _ = c.SDL_GetWindowPosition(window.window, &window_x, &window_y);
            var border_top: c_int = 0;
            var border_left: c_int = 0;
            var border_bottom: c_int = 0;
            var border_right: c_int = 0;
            if (!c.SDL_GetWindowBordersSize(window.window, &border_top, &border_left, &border_bottom, &border_right)) {
                border_top = 0;
                border_left = 0;
                border_bottom = 0;
                border_right = 0;
            }
            var window_width: c_int = 0;
            var window_height: c_int = 0;
            _ = c.SDL_GetWindowSize(window.window, &window_width, &window_height);
            if (window_width <= 0 or window_height <= 0) continue;

            const content_x: c_int = window_x + border_left;
            const content_y: c_int = window_y + border_top;
            const min_x: f32 = @floatFromInt(content_x);
            const min_y: f32 = @floatFromInt(content_y);
            const max_x = min_x + @as(f32, @floatFromInt(window_width));
            const max_y = min_y + @as(f32, @floatFromInt(window_height));
            if (mouse_global_x < min_x or mouse_global_x >= max_x or mouse_global_y < min_y or mouse_global_y >= max_y) continue;

            return .{
                .win = window,
                .local_pos = .{ mouse_global_x - min_x, mouse_global_y - min_y },
            };
        }
        return null;
    }

    fn focusedWindowMouseHit(self: *App, exclude_window_id: u32) ?WindowMouseHit {
        const mouse_focus = c.SDL_GetMouseFocus();
        const hover_window_id: u32 = if (mouse_focus) |window| c.SDL_GetWindowID(window) else 0;
        if (hover_window_id == 0 or hover_window_id == exclude_window_id) return null;

        var target_window: ?*UiWindow = null;
        for (self.ui_windows.items) |window| {
            if (window.id == hover_window_id) {
                target_window = window;
                break;
            }
        }
        if (target_window == null) return null;

        var local_mouse_x: f32 = 0.0;
        var local_mouse_y: f32 = 0.0;
        _ = c.SDL_GetMouseState(&local_mouse_x, &local_mouse_y);
        return .{
            .win = target_window.?,
            .local_pos = .{ local_mouse_x, local_mouse_y },
        };
    }

    fn rebuildDockLayoutFromPanels(self: *App, manager: *panel_manager.PanelManager) bool {
        const panel_count = manager.workspace.panels.items.len;
        if (panel_count == 0 or panel_count > 4096) return false;

        const graph = &manager.workspace.dock_layout;
        graph.clear();
        const fresh_graph = graph;

        var chat_ids = std.ArrayList(workspace.PanelId).empty;
        defer chat_ids.deinit(fresh_graph.allocator);
        var other_ids = std.ArrayList(workspace.PanelId).empty;
        defer other_ids.deinit(fresh_graph.allocator);
        var all_ids = std.ArrayList(workspace.PanelId).empty;
        defer all_ids.deinit(fresh_graph.allocator);

        chat_ids.ensureTotalCapacity(fresh_graph.allocator, panel_count) catch return false;
        other_ids.ensureTotalCapacity(fresh_graph.allocator, panel_count) catch return false;
        all_ids.ensureTotalCapacity(fresh_graph.allocator, panel_count) catch return false;

        var chat_count: usize = 0;
        var other_count: usize = 0;
        for (manager.workspace.panels.items) |panel| {
            if (panel.kind == .Chat) {
                chat_count += 1;
                chat_ids.append(fresh_graph.allocator, panel.id) catch return false;
            } else {
                other_count += 1;
                other_ids.append(fresh_graph.allocator, panel.id) catch return false;
            }
            all_ids.append(fresh_graph.allocator, panel.id) catch return false;
        }
        if (self.shouldLogDebug(120)) {
            std.log.info("rebuildDockLayoutFromPanels: panel_count={} chat={} other={}", .{ panel_count, chat_count, other_count });
        }

        if (chat_ids.items.len > 0 and other_ids.items.len > 0) {
            const left = fresh_graph.addTabsNode(chat_ids.items, 0) catch return false;
            const right = fresh_graph.addTabsNode(other_ids.items, 0) catch return false;
            const root = fresh_graph.addSplitNode(.vertical, manager.workspace.custom_layout.left_ratio, left, right) catch return false;
            fresh_graph.root = root;
            manager.workspace.markDirty();
            return true;
        }

        if (all_ids.items.len == 0) return false;
        const root = fresh_graph.addTabsNode(all_ids.items, 0) catch return false;
        fresh_graph.root = root;
        manager.workspace.markDirty();
        return true;
    }

    fn recoverDockLayoutFromPanels(self: *App, manager: *panel_manager.PanelManager) bool {
        const panel_count = manager.workspace.panels.items.len;
        if (self.shouldLogDebug(120)) {
            std.log.info("recoverDockLayoutFromPanels: panel_count={}", .{panel_count});
        }
        if (panel_count == 0 or panel_count > 4096) return false;

        var graph = &manager.workspace.dock_layout;
        graph.clear();

        var panel_ids = std.ArrayList(workspace.PanelId).empty;
        defer panel_ids.deinit(graph.allocator);
        panel_ids.ensureTotalCapacity(graph.allocator, panel_count) catch return false;

        for (manager.workspace.panels.items) |panel| {
            panel_ids.append(graph.allocator, panel.id) catch return false;
        }

        const root = graph.addTabsNode(panel_ids.items, 0) catch return false;
        graph.root = root;
        manager.workspace.markDirty();
        if (self.shouldLogDebug(120)) {
            std.log.info("recoverDockLayoutFromPanels: built root={}", .{@as(i64, @intCast(root))});
        }
        return true;
    }

    fn collectDockLayoutSafe(
        self: *App,
        manager: *panel_manager.PanelManager,
        dock_area: UiRect,
        out: *dock_graph.LayoutResult,
    ) bool {
        if (!self.isWorkspaceStateReasonable(manager)) {
            std.log.err("collectDockLayoutSafe: manager unhealthy", .{});
            return false;
        }

        out.len = 0;
        if (manager.workspace.panels.items.len > 4096 or manager.workspace.dock_layout.nodes.items.len > 16384)
        {
            std.log.err(
                "collectDockLayoutSafe: invalid workspace sizes (panels={} nodes={})",
                .{
                    manager.workspace.panels.items.len,
                    manager.workspace.dock_layout.nodes.items.len,
                },
            );
            return false;
        }
        if (!self.isDockLayoutGraphHeaderSane(&manager.workspace.dock_layout)) {
            std.log.err("collectDockLayoutSafe: dock graph header failed sanity check", .{});
            return false;
        }

        if (manager.workspace.panels.items.len == 0) {
            std.log.err("collectDockLayoutSafe: no panels available", .{});
            return false;
        }

        if (self.collectDockLayout(manager, dock_area, out)) {
            return true;
        }

        if (self.rebuildDockLayoutFromPanels(manager)) {
            _ = manager.workspace.syncDockLayout() catch {};
            if (self.collectDockLayout(manager, dock_area, out)) {
                return true;
            }
            std.log.err("collectDockLayoutSafe: rebuilt layout still invalid", .{});
        }

        if (self.recoverDockLayoutFromPanels(manager)) {
            if (self.collectDockLayout(manager, dock_area, out)) {
                return true;
            }
            std.log.err("collectDockLayoutSafe: recovered layout still invalid", .{});
        }

        if (self.buildSingleTabPanelLayout(manager, dock_area, out)) {
            return true;
        }
        std.log.err("collectDockLayoutSafe: single-tab fallback failed", .{});
        return false;
    }

    fn isDockLayoutGraphHeaderSane(self: *App, graph: *const dock_graph.Graph) bool {
        _ = self;
        if (graph.nodes.capacity > MAX_REASONABLE_DOCK_NODE_COUNT * 2) return false;
        if (graph.nodes.items.len > graph.nodes.capacity) return false;
        if (graph.nodes.items.len > MAX_REASONABLE_DOCK_NODE_COUNT) return false;
        if (graph.nodes.items.len == 0) return true;
        const ptr = graph.nodes.items.ptr;
        if (@intFromPtr(ptr) == 0) return false;
        if (!std.mem.isAligned(@intFromPtr(ptr), @alignOf(?dock_graph.Node))) return false;
        return true;
    }

    fn ensureWindowManagerHealthy(self: *App, manager: *panel_manager.PanelManager) bool {
        if (@intFromPtr(manager) == 0) {
            std.log.err("ensureWindowManagerHealthy: null manager pointer", .{});
            return false;
        }
        self.bindNextPanelId(manager);
        if (self.isWorkspaceRecoverySuspended(manager)) {
            if (self.shouldLogDebug(240) or self.shouldLogStartup()) {
                std.log.warn(
                    "ensureWindowManagerHealthy: recovery suspended (manager=0x{x})",
                    .{@intFromPtr(manager)},
                );
            }
            return false;
        }

        if (self.workspace_recovery_failures >= WORKSPACE_RECOVERY_ATTEMPTS_BEFORE_SUSPEND) {
            if (self.shouldLogDebug(120) or self.shouldLogStartup()) {
                std.log.warn(
                    "ensureWindowManagerHealthy: recovery attempts exceeded, forcing safe reset",
                    .{},
                );
            }
            self.workspace_recovery_failures = 0;
            self.invalidateWorkspaceSnapshot();
            if (!self.resetManagerToDefaultSafe(manager)) {
                self.suspendWorkspaceRecovery(manager);
                self.resetWorkspaceToSafeEmpty(manager);
                return false;
            }
            self.clearWorkspaceRecoveryCooldown();
            self.clearWorkspaceRecoverySuspend();
            return self.isWorkspaceStateReasonable(manager) and manager.workspace.panels.items.len > 0;
        }

        const is_recovery_allowed = self.canRecoverManagerWorkspace(manager);
        if (!is_recovery_allowed) {
            if (self.shouldLogDebug(240) or self.shouldLogStartup()) {
                std.log.warn(
                    "ensureWindowManagerHealthy: skipping recovery due cooldown (manager=0x{x})",
                    .{@intFromPtr(manager)},
                );
            }
            return false;
        }

        if (!self.isWorkspaceStateReasonable(manager)) {
            self.logWorkspaceState(manager, "invalid-before-reset", self.debug_frame_counter);
            if (self.shouldLogDebug(120) or self.shouldLogStartup()) {
                std.log.err(
                    "ensureWindowManagerHealthy: invalid workspace state, resetting (panels={d} nodes={d} root={d})",
                    .{
                        manager.workspace.panels.items.len,
                        manager.workspace.dock_layout.nodes.items.len,
                        if (manager.workspace.dock_layout.root) |root| @as(i64, @intCast(root)) else -1,
                    },
                );
            }

            if (!self.workspace_snapshot_stale and self.workspace_snapshot != null and !self.workspace_snapshot_restore_attempted) {
                if (self.shouldLogDebug(120) or self.shouldLogStartup()) {
                    std.log.info("ensureWindowManagerHealthy: trying snapshot restore during recovery", .{});
                }
                if (
                    self.debug_frame_counter >= self.workspace_snapshot_restore_cooldown_until and
                    self.restoreWorkspaceFromSnapshot(manager)
                ) {
                    self.workspace_snapshot_stale = false;
                    self.workspace_snapshot_restore_attempted = false;
                    self.workspace_recovery_failures = 0;
                    self.clearWorkspaceRecoveryCooldown();
                    self.clearWorkspaceRecoverySuspend();
                    self.workspace_snapshot_restore_cooldown_until = self.debug_frame_counter + WORKSPACE_RECOVERY_COOLDOWN_FRAMES;
                    return true;
                }
                self.invalidateWorkspaceSnapshot();
                self.workspace_snapshot_stale = true;
                self.workspace_snapshot_restore_attempted = true;
                self.workspace_snapshot_restore_cooldown_until = self.debug_frame_counter + WORKSPACE_RECOVERY_COOLDOWN_FRAMES;
                if (self.workspace_recovery_failures < 250) self.workspace_recovery_failures +%= 1;
                if (self.shouldLogDebug(120) or self.shouldLogStartup()) {
                    std.log.warn("ensureWindowManagerHealthy: snapshot restore failed; disabling repeated restore", .{});
                }
            } else if (self.workspace_snapshot_stale) {
                if (self.shouldLogDebug(120) or self.shouldLogStartup()) {
                    std.log.warn(
                        "ensureWindowManagerHealthy: skipping restore because workspace snapshot is stale",
                        .{},
                    );
                }
                if (self.workspace_recovery_failures < 250) self.workspace_recovery_failures +%= 1;
            } else if (self.debug_frame_counter < self.workspace_snapshot_restore_cooldown_until) {
                if (self.shouldLogDebug(120) or self.shouldLogStartup()) {
                    std.log.warn(
                        "ensureWindowManagerHealthy: snapshot restore cooldown active (frame {} < {})",
                        .{ self.debug_frame_counter, self.workspace_snapshot_restore_cooldown_until },
                    );
                }
                if (self.workspace_recovery_failures < 250) self.workspace_recovery_failures +%= 1;
            }

            if (!self.resetManagerToDefaultSafe(manager)) {
                self.logWorkspaceState(manager, "invalid-after-reset", self.debug_frame_counter);
                if (self.shouldLogDebug(120) or self.shouldLogStartup()) {
                    std.log.err(
                        "ensureWindowManagerHealthy: reset did not produce a valid default workspace",
                        .{},
                    );
                }
                self.workspace_recovery_failures +%= 1;
                self.suspendWorkspaceRecovery(manager);
                return false;
            }

            if (!self.isWorkspaceStateReasonable(manager) or manager.workspace.panels.items.len == 0) {
                self.logWorkspaceState(manager, "invalid-after-reset-verify", self.debug_frame_counter);
                self.workspace_recovery_failures +%= 1;
                self.suspendWorkspaceRecovery(manager);
                self.resetWorkspaceToSafeEmpty(manager);
                return false;
            }

            self.captureWorkspaceSnapshot(manager);
            self.workspace_recovery_failures = 0;
            self.clearWorkspaceRecoveryCooldown();
            self.clearWorkspaceRecoverySuspend();
            return true;
        }

        if (manager.workspace.panels.items.len == 0) {
            if (self.shouldLogDebug(120) or self.shouldLogStartup()) {
                std.log.warn("ensureWindowManagerHealthy: no panels; restoring default workspace", .{});
            }
            if (!self.resetManagerToDefaultSafe(manager)) {
                self.suspendWorkspaceRecovery(manager);
                self.resetWorkspaceToSafeEmpty(manager);
                return false;
            }
            if (!self.isWorkspaceStateReasonable(manager) or manager.workspace.panels.items.len == 0) {
                self.suspendWorkspaceRecovery(manager);
                self.resetWorkspaceToSafeEmpty(manager);
                return false;
            }
            self.clearWorkspaceRecoveryCooldown();
            self.clearWorkspaceRecoverySuspend();
            return manager.workspace.panels.items.len > 0;
        }

        if (manager.workspace.dock_layout.nodes.items.len == 0 and manager.workspace.panels.items.len > 0) {
            if (self.shouldLogDebug(120) or self.shouldLogStartup()) {
                std.log.info("ensureWindowManagerHealthy: no dock nodes; syncing layout", .{});
            }
            const synced = manager.workspace.syncDockLayout() catch {
                if (self.shouldLogDebug(120) or self.shouldLogStartup()) {
                    std.log.warn("ensureWindowManagerHealthy: sync failed; restoring defaults", .{});
                }
                if (!self.resetManagerToDefaultSafe(manager)) {
                    self.suspendWorkspaceRecovery(manager);
                    self.resetWorkspaceToSafeEmpty(manager);
                    return false;
                }
                if (!self.isWorkspaceStateReasonable(manager)) {
                    self.suspendWorkspaceRecovery(manager);
                    self.resetWorkspaceToSafeEmpty(manager);
                }
                return false;
            };
            if (!synced) {
                if (!self.resetManagerToDefaultSafe(manager)) {
                    self.suspendWorkspaceRecovery(manager);
                    self.resetWorkspaceToSafeEmpty(manager);
                    return false;
                }
                if (!self.isWorkspaceStateReasonable(manager)) {
                    self.suspendWorkspaceRecovery(manager);
                    self.resetWorkspaceToSafeEmpty(manager);
                }
                return false;
            }
        } else if (self.isDockLayoutCorrupt(manager)) {
            if (self.shouldLogDebug(120) or self.shouldLogStartup()) {
                std.log.warn("ensureWindowManagerHealthy: dock layout corrupt; repairing", .{});
            }
            _ = self.repairDockLayout(manager);
            if (self.isDockLayoutCorrupt(manager)) {
                if (self.shouldLogDebug(120) or self.shouldLogStartup()) {
                    std.log.warn("ensureWindowManagerHealthy: repair ineffective; restoring defaults", .{});
                }
                if (!self.resetManagerToDefaultSafe(manager)) {
                    self.suspendWorkspaceRecovery(manager);
                    self.resetWorkspaceToSafeEmpty(manager);
                    return false;
                }
                if (!self.isWorkspaceStateReasonable(manager)) {
                    self.suspendWorkspaceRecovery(manager);
                    self.resetWorkspaceToSafeEmpty(manager);
                }
            }
        }

        if (self.isWorkspaceStateReasonable(manager)) {
            self.clearWorkspaceRecoveryCooldown();
            self.clearWorkspaceRecoverySuspend();
            if (self.workspace_snapshot_stale and self.shouldLogDebug(600)) {
                std.log.warn("ensureWindowManagerHealthy: skipping snapshot capture while snapshot is stale", .{});
            }
        } else {
            self.suspendWorkspaceRecovery(manager);
        }

        if (self.isWorkspaceStateReasonable(manager) and self.workspace_snapshot == null) {
            self.captureWorkspaceSnapshot(manager);
            self.workspace_snapshot_restore_attempted = false;
        }

        return self.isWorkspaceStateReasonable(manager) and manager.workspace.panels.items.len > 0;
    }

    fn canRecoverManagerWorkspace(self: *App, manager: *panel_manager.PanelManager) bool {
        if (self.workspace_recovery_blocked_until == 0) return true;
        if (self.workspace_recovery_blocked_for_manager != @intFromPtr(manager)) return true;
        if (self.debug_frame_counter < self.workspace_recovery_blocked_until) return false;
        self.workspace_recovery_blocked_until = 0;
        self.workspace_recovery_blocked_for_manager = 0;
        return true;
    }

    fn blockWorkspaceRecovery(self: *App, manager: *panel_manager.PanelManager) void {
        self.workspace_recovery_blocked_for_manager = @intFromPtr(manager);
        self.workspace_recovery_blocked_until = self.debug_frame_counter + WORKSPACE_RECOVERY_COOLDOWN_FRAMES;
    }

    fn isWorkspaceRecoverySuspended(self: *App, manager: *panel_manager.PanelManager) bool {
        if (self.workspace_recovery_suspended_for_manager != @intFromPtr(manager)) return false;
        if (self.workspace_recovery_suspended_until == 0) return true;
        if (self.debug_frame_counter < self.workspace_recovery_suspended_until) return true;
        self.workspace_recovery_suspended_for_manager = 0;
        self.workspace_recovery_suspended_until = 0;
        return false;
    }

    fn suspendWorkspaceRecovery(self: *App, manager: *panel_manager.PanelManager) void {
        if (self.workspace_recovery_suspended_for_manager == 0) {
            self.workspace_recovery_suspended_for_manager = @intFromPtr(manager);
        }
        self.workspace_recovery_suspended_until = self.debug_frame_counter + WORKSPACE_RECOVERY_SUSPEND_FRAMES;
        self.blockWorkspaceRecovery(manager);
    }

    fn clearWorkspaceRecoverySuspend(self: *App) void {
        if (self.workspace_recovery_suspended_until != 0) {
            self.workspace_recovery_suspended_until = 0;
            self.workspace_recovery_suspended_for_manager = 0;
        }
    }

    fn resetWorkspaceToSafeEmpty(self: *App, manager: *panel_manager.PanelManager) void {
        self.tryDeinitWorkspaceForReset(manager);
        manager.workspace = workspace.Workspace.initEmpty(self.allocator);
        self.recomputeManagerNextId(manager);
    }

    fn clearWorkspaceRecoveryCooldown(self: *App) void {
        self.workspace_recovery_blocked_until = 0;
        self.workspace_recovery_blocked_for_manager = 0;
    }

    fn captureWorkspaceSnapshot(self: *App, manager: *panel_manager.PanelManager) void {
        if (!self.isWorkspaceStateReasonable(manager)) return;
        const snapshot = manager.workspace.toSnapshot(self.allocator) catch {
            if (self.shouldLogDebug(120) or self.shouldLogStartup()) {
                std.log.warn("captureWorkspaceSnapshot: unable to snapshot workspace", .{});
            }
            return;
        };
        if (self.workspace_snapshot) |*previous| {
            previous.deinit(self.allocator);
        }
        self.workspace_snapshot = snapshot;
        self.workspace_snapshot_stale = false;
        self.workspace_snapshot_restore_attempted = false;
    }

    fn invalidateWorkspaceSnapshot(self: *App) void {
        if (self.workspace_snapshot) |*snapshot| {
            snapshot.deinit(self.allocator);
            self.workspace_snapshot = null;
        }
        self.workspace_snapshot_stale = true;
        self.workspace_snapshot_restore_attempted = true;
    }

    fn bindNextPanelId(self: *App, manager: *panel_manager.PanelManager) void {
        if (@intFromPtr(manager.next_panel_id) != @intFromPtr(&self.next_panel_id)) {
            if (self.shouldLogDebug(1200)) {
                std.log.debug(
                    "bindNextPanelId: repairing manager.next_panel_id (old=0x{x}, expected=0x{x})",
                    .{ @intFromPtr(manager.next_panel_id), @intFromPtr(&self.next_panel_id) },
                );
            }
            manager.next_panel_id = &self.next_panel_id;
        }
    }

    fn restoreWorkspaceFromSnapshot(self: *App, manager: *panel_manager.PanelManager) bool {
        const snapshot = self.workspace_snapshot orelse return false;
        if (!self.isWorkspaceSnapshotReasonable(snapshot)) {
            if (self.shouldLogDebug(120) or self.shouldLogStartup()) {
                std.log.warn("restoreWorkspaceFromSnapshot: snapshot failed sanity checks", .{});
            }
            self.invalidateWorkspaceSnapshot();
            return false;
        }
        var restored = workspace.Workspace.fromSnapshot(self.allocator, snapshot) catch |err| {
            if (self.shouldLogDebug(120) or self.shouldLogStartup()) {
                std.log.warn(
                    "restoreWorkspaceFromSnapshot: failed to restore from snapshot ({s})",
                    .{@errorName(err)},
                );
            }
            self.invalidateWorkspaceSnapshot();
            return false;
        };
        if (!self.restoreLooksReasonable(&restored)) {
            if (self.shouldLogDebug(120) or self.shouldLogStartup()) {
                std.log.warn("restoreWorkspaceFromSnapshot: restored workspace failed sanity checks", .{});
            }
            restored.deinit(self.allocator);
            self.invalidateWorkspaceSnapshot();
            return false;
        }

        self.tryDeinitWorkspaceForReset(manager);
        manager.workspace = restored;

        if (!self.isWorkspaceStateReasonable(manager)) {
            manager.workspace.deinit(self.allocator);
            manager.workspace = workspace.Workspace.initEmpty(self.allocator);
            self.invalidateWorkspaceSnapshot();
            return false;
        }
        self.recomputeManagerNextId(manager);
        self.captureWorkspaceSnapshot(manager);
        return true;
    }

    fn restoreLooksReasonable(self: *App, candidate: *const workspace.Workspace) bool {
        _ = self;
        if (candidate.panels.items.len > MAX_REASONABLE_PANEL_COUNT) return false;
        if (candidate.dock_layout.nodes.items.len > MAX_REASONABLE_DOCK_NODE_COUNT) return false;
        if (candidate.panels.items.len > 0 and candidate.dock_layout.nodes.items.len == 0) return false;
        if (candidate.dock_layout.nodes.capacity > MAX_REASONABLE_DOCK_NODE_COUNT * 2) return false;
        if (candidate.panels.capacity > MAX_REASONABLE_PANEL_COUNT * 2) return false;
        if (candidate.dock_layout.root) |root| {
            if (root >= candidate.dock_layout.nodes.items.len) return false;
            if (candidate.dock_layout.getNode(root) == null) return false;
        } else if (candidate.dock_layout.nodes.items.len > 0) {
            return false;
        }
        return true;
    }

    fn isWorkspaceSnapshotReasonable(self: *App, snapshot: workspace.WorkspaceSnapshot) bool {
        if (snapshot.next_panel_id == 0) return false;
        if (snapshot.next_panel_id == 1) return false;
        if (snapshot.next_panel_id > MAX_REASONABLE_NEXT_PANEL_ID) return false;

        const panel_count: usize = if (snapshot.panels) |panels| panels.len else 0;
        if (panel_count > MAX_REASONABLE_PANEL_COUNT) return false;

        if (snapshot.layout_v2) |layout| {
            const layout_nodes = if (layout.nodes) |nodes| nodes.len else 0;
            if (layout_nodes > MAX_REASONABLE_DOCK_NODE_COUNT) return false;
        }

        if (snapshot.collapsed_docks) |collapsed| {
            if (collapsed.len > MAX_REASONABLE_DOCK_NODE_COUNT) return false;
        }

        if (snapshot.detached_windows) |detached| {
            if (detached.len > 32) return false;
        }

        if (snapshot.panels) |panels| {
            var seen_panel_ids = std.AutoHashMap(workspace.PanelId, void).init(self.allocator);
            defer seen_panel_ids.deinit();
            for (panels) |panel| {
                if (panel.id == 0) return false;
                if (panel.id >= snapshot.next_panel_id) return false;
                if (seen_panel_ids.contains(panel.id)) return false;
                seen_panel_ids.put(panel.id, {}) catch return false;
            }
        }

        return true;
    }

    fn resetManagerWorkspaceToDefault(self: *App, manager: *panel_manager.PanelManager) bool {
        self.tryDeinitWorkspaceForReset(manager);
        const fresh = workspace.Workspace.initDefault(self.allocator) catch {
            std.log.err("ensureWindowManagerHealthy: fallback workspace build failed", .{});
            manager.workspace = workspace.Workspace.initEmpty(self.allocator);
            self.recomputeManagerNextId(manager);
            return false;
        };
        if (!self.restoreLooksReasonable(&fresh)) {
            std.log.err("ensureWindowManagerHealthy: fallback workspace failed post-creation sanity checks", .{});
            var disposable = fresh;
            disposable.deinit(self.allocator);
            manager.workspace = workspace.Workspace.initEmpty(self.allocator);
            self.recomputeManagerNextId(manager);
            return false;
        }
        manager.workspace = fresh;
        self.recomputeManagerNextId(manager);
        self.captureWorkspaceSnapshot(manager);
        return true;
    }

    fn resetMainManagerToDefault(self: *App) bool {
        var fresh = workspace.Workspace.initDefault(self.allocator) catch {
            std.log.err("ensureWindowManagerHealthy: main fallback workspace build failed", .{});
            return false;
        };
        if (!self.restoreLooksReasonable(&fresh)) {
            std.log.err("ensureWindowManagerHealthy: main fallback workspace failed post-creation sanity checks", .{});
            fresh.deinit(self.allocator);
            return false;
        }

        self.tryDeinitWorkspaceForReset(&self.manager);
        self.manager = panel_manager.PanelManager.init(self.allocator, fresh, &self.next_panel_id);
        self.bindNextPanelId(&self.manager);
        self.bindMainWindowManager();
        self.recomputeManagerNextId(&self.manager);
        self.captureWorkspaceSnapshot(&self.manager);
        return true;
    }

    fn resetManagerToDefaultSafe(self: *App, manager: *panel_manager.PanelManager) bool {
        if (manager == &self.manager) return self.resetMainManagerToDefault();
        return self.resetManagerWorkspaceToDefault(manager);
    }

    fn isWorkspaceStateReasonable(self: *App, manager: *panel_manager.PanelManager) bool {
        if (!self.isWorkspaceHeaderSane(manager)) return false;
        if (!self.isDockLayoutGraphHeaderSane(&manager.workspace.dock_layout)) return false;

        const panel_count = manager.workspace.panels.items.len;
        const node_count = manager.workspace.dock_layout.nodes.items.len;

        if (panel_count > MAX_REASONABLE_PANEL_COUNT or node_count > MAX_REASONABLE_DOCK_NODE_COUNT) return false;

        if (manager.workspace.dock_layout.root == null)
            return node_count == 0;

        if (node_count == 0) return false;
        const root = manager.workspace.dock_layout.root.?;
        if (root >= node_count) return false;
        return manager.workspace.dock_layout.getNode(root) != null;
    }

    fn resetManagerWorkspace(self: *App, manager: *panel_manager.PanelManager) void {
        self.bindNextPanelId(manager);
        _ = self.resetManagerWorkspaceToDefault(manager);
    }

    fn recomputeManagerNextId(self: *App, manager: *panel_manager.PanelManager) void {
        self.bindNextPanelId(manager);
        if (!self.isWorkspaceHeaderSane(manager)) {
            self.next_panel_id = 1;
            return;
        }
        var max_id: workspace.PanelId = 0;
        for (manager.workspace.panels.items) |panel| {
            if (panel.id > max_id) max_id = panel.id;
        }
        const candidate = max_id + 1;
        if (candidate > self.next_panel_id) {
            self.next_panel_id = candidate;
        }
    }

    fn appendPanelToManager(self: *App, manager: *panel_manager.PanelManager, panel: workspace.Panel) !void {
        self.bindNextPanelId(manager);
        try manager.workspace.panels.append(self.allocator, panel);
        manager.workspace.markDirty();
        self.recomputeManagerNextId(manager);
    }

    fn tryDeinitWorkspaceForReset(self: *App, manager: *panel_manager.PanelManager) void {
        if (!self.isWorkspaceHeaderSane(manager)) {
            self.logWorkspaceState(manager, "header-corrupt-bypass-deinit", self.debug_frame_counter);
            self.releaseCorruptWorkspaceStorage(manager);
            manager.workspace = workspace.Workspace.initEmpty(self.allocator);
            return;
        }
        if (self.isWorkspaceStateReasonable(manager)) {
            manager.workspace.deinit(self.allocator);
            manager.workspace = workspace.Workspace.initEmpty(self.allocator);
            return;
        }

        // On partially-corrupted state, avoid deep deinit paths that assume valid node
        // internals. Use bounded storage release only and replace with fresh structures.
        const panel_count = manager.workspace.panels.items.len;
        const node_count = manager.workspace.dock_layout.nodes.items.len;
        std.log.warn(
            "tryDeinitWorkspaceForReset: workspace header suspicious (panels=len={} cap={} nodes=len={} cap={})",
            .{
                panel_count,
                manager.workspace.panels.capacity,
                node_count,
                manager.workspace.dock_layout.nodes.capacity,
            },
        );
        self.releaseCorruptWorkspaceStorage(manager);
        manager.workspace = workspace.Workspace.initEmpty(self.allocator);
    }

    fn releaseCorruptWorkspaceStorage(self: *App, manager: *panel_manager.PanelManager) void {
        const panel_len = manager.workspace.panels.items.len;
        const panel_cap = manager.workspace.panels.capacity;
        const panel_ptr = manager.workspace.panels.items.ptr;
        const panel_reasonable = panel_len <= panel_cap and
            panel_cap > 0 and
            panel_cap <= MAX_REASONABLE_PANEL_COUNT * 2 and
            @intFromPtr(panel_ptr) != 0 and
            std.mem.isAligned(@intFromPtr(panel_ptr), @alignOf(workspace.Panel));
        if (panel_reasonable) {
            if (panel_len <= MAX_REASONABLE_PANEL_COUNT) {
                var idx: usize = 0;
                while (idx < panel_len) : (idx += 1) {
                    manager.workspace.panels.items[idx].deinit(self.allocator);
                }
            } else if (self.shouldLogDebug(120) or self.shouldLogStartup()) {
                std.log.warn(
                    "releaseCorruptWorkspaceStorage: skipping panel deinit due suspicious panel count ({})",
                    .{panel_len},
                );
            }
            self.allocator.free(panel_ptr[0..panel_cap]);
        } else if (self.shouldLogDebug(120) or self.shouldLogStartup()) {
            std.log.warn(
                "releaseCorruptWorkspaceStorage: skipped panel storage release (len={} cap={} ptr=0x{x})",
                .{
                    panel_len,
                    panel_cap,
                    @intFromPtr(panel_ptr),
                },
            );
        }
        manager.workspace.panels = std.ArrayList(workspace.Panel).empty;
        const node_cap = manager.workspace.dock_layout.nodes.capacity;
        const node_len = manager.workspace.dock_layout.nodes.items.len;
        const node_ptr = manager.workspace.dock_layout.nodes.items.ptr;
        const node_reasonable = node_len <= node_cap and
            node_cap > 0 and
            @intFromPtr(node_ptr) != 0 and
            node_cap <= MAX_REASONABLE_DOCK_NODE_COUNT * 2 and
            std.mem.isAligned(@intFromPtr(node_ptr), @alignOf(?dock_graph.Node));
        if (node_reasonable) {
            if (node_len <= MAX_REASONABLE_DOCK_NODE_COUNT) {
                var node_idx: usize = 0;
                while (node_idx < node_len) : (node_idx += 1) {
                    if (manager.workspace.dock_layout.nodes.items[node_idx]) |*node| {
                        node.deinit(self.allocator);
                    }
                }
            }
            self.allocator.free(node_ptr[0..node_cap]);
            if (self.shouldLogDebug(120) or self.shouldLogStartup()) {
                std.log.warn(
                    "releaseCorruptWorkspaceStorage: released dock node storage (len={} cap={} ptr=0x{x})",
                    .{
                        node_len,
                        node_cap,
                        @intFromPtr(node_ptr),
                    },
                );
            }
        } else if (self.shouldLogDebug(120) or self.shouldLogStartup()) {
            std.log.warn(
                "releaseCorruptWorkspaceStorage: skipped dock node storage release (len={} cap={} ptr=0x{x})",
                .{
                    node_len,
                    node_cap,
                    @intFromPtr(node_ptr),
                },
            );
        }
        manager.workspace.dock_layout.nodes = std.ArrayList(?dock_graph.Node).empty;
        manager.workspace.dock_layout.root = null;
    }

    fn isWorkspaceHeaderSane(_: *App, manager: *panel_manager.PanelManager) bool {
        const ws = &manager.workspace;

        if (ws.panels.items.len > MAX_REASONABLE_PANEL_COUNT) return false;
        if (ws.panels.capacity > MAX_REASONABLE_PANEL_COUNT * 2) return false;
        if (ws.panels.items.len > ws.panels.capacity) return false;
        if (ws.panels.items.len > 0 and @intFromPtr(ws.panels.items.ptr) == 0) return false;
        if (ws.panels.items.len > 0 and !std.mem.isAligned(@intFromPtr(ws.panels.items.ptr), @alignOf(workspace.Panel))) return false;
        if (ws.panels.capacity == 0 and ws.panels.items.len > 0) return false;

        if (ws.dock_layout.nodes.items.len > MAX_REASONABLE_DOCK_NODE_COUNT) return false;
        if (ws.dock_layout.nodes.capacity > MAX_REASONABLE_DOCK_NODE_COUNT * 2) return false;
        if (ws.dock_layout.nodes.items.len > ws.dock_layout.nodes.capacity) return false;
        if (ws.dock_layout.nodes.items.len > 0 and @intFromPtr(ws.dock_layout.nodes.items.ptr) == 0) return false;
        if (ws.dock_layout.nodes.items.len > 0 and !std.mem.isAligned(@intFromPtr(ws.dock_layout.nodes.items.ptr), @alignOf(?dock_graph.Node))) return false;

        return true;
    }

    fn logWorkspaceState(self: *App, manager: *panel_manager.PanelManager, label: []const u8, frame_ctx: u64) void {
        _ = self;
        const dock_root = if (manager.workspace.dock_layout.root) |root|
            @as(i64, @intCast(root))
        else
            -1;
        std.log.err(
            "workspace-state[{s}] frame={d}: panels(len={d} cap={d} ptr=0x{x}) nodes(len={d} cap={d} ptr=0x{x}) root={d}",
            .{
                label,
                frame_ctx,
                manager.workspace.panels.items.len,
                manager.workspace.panels.capacity,
                @intFromPtr(manager.workspace.panels.items.ptr),
                manager.workspace.dock_layout.nodes.items.len,
                manager.workspace.dock_layout.nodes.capacity,
                @intFromPtr(manager.workspace.dock_layout.nodes.items.ptr),
                dock_root,
            },
        );
    }

    fn buildSingleTabPanelLayout(
        self: *App,
        manager: *panel_manager.PanelManager,
        dock_area: UiRect,
        out: *dock_graph.LayoutResult,
    ) bool {
        const panel_count = manager.workspace.panels.items.len;
        if (panel_count == 0 or panel_count > 4096) return false;

        out.len = 0;
        const graph = &manager.workspace.dock_layout;
        graph.clear();

        var panel_ids = std.ArrayList(workspace.PanelId).empty;
        defer panel_ids.deinit(graph.allocator);
        panel_ids.ensureTotalCapacity(graph.allocator, panel_count) catch return false;
        for (manager.workspace.panels.items) |panel| {
            panel_ids.append(graph.allocator, panel.id) catch return false;
        }

        const root = graph.addTabsNode(panel_ids.items, 0) catch return false;
        graph.root = root;
        manager.workspace.markDirty();
        if (self.shouldLogDebug(120)) {
            std.log.info("buildSingleTabPanelLayout: built root={} panels={}", .{ @as(i64, @intCast(root)), panel_count });
        }

        out.append(.{ .node_id = root, .rect = dock_area });
        return true;
    }

    fn collectDockInteractionGeometry(
        self: *App,
        manager: *panel_manager.PanelManager,
        dock_area: UiRect,
        out_tabs: *DockTabHitList,
        out_drop_targets: *DockDropTargetList,
    ) void {
        out_tabs.len = 0;
        out_drop_targets.clear();

        var layout: dock_graph.LayoutResult = .{};
        if (!self.collectDockLayoutSafe(manager, dock_area, &layout)) {
            if (self.shouldLogDebug(120)) {
                std.log.warn("collectDockInteractionGeometry: no valid dock layout", .{});
            }
            return;
        }

        const pad = self.theme.spacing.sm;
        const tab_height: f32 = 28.0 * self.ui_scale;
        if (tab_height <= 0.0) return;

        for (layout.slice()) |group| {
            if (!self.isLayoutGroupUsable(manager, group.node_id)) continue;

            const size = group.rect.size();
            if (size[0] > 1.0 and size[1] > 1.0) {
                const edge_ratio = dock_drop.edge_band_ratio;
                const edge_w = @max(1.0, size[0] * edge_ratio);
                const edge_h = @max(1.0, size[1] * edge_ratio);
                const inner_min_x = group.rect.min[0] + edge_w;
                const inner_max_x = group.rect.max[0] - edge_w;
                const inner_min_y = group.rect.min[1] + edge_h;
                const inner_max_y = group.rect.max[1] - edge_h;
                const center_w = @max(1.0, inner_max_x - inner_min_x);
                const center_h = @max(1.0, inner_max_y - inner_min_y);

                out_drop_targets.append(.{
                    .node_id = group.node_id,
                    .location = .center,
                    .rect = UiRect.fromMinSize(
                        .{ inner_min_x, inner_min_y },
                        .{ center_w, center_h },
                    ),
                });
                out_drop_targets.append(.{
                    .node_id = group.node_id,
                    .location = .left,
                    .rect = UiRect.fromMinSize(group.rect.min, .{ edge_w, size[1] }),
                });
                out_drop_targets.append(.{
                    .node_id = group.node_id,
                    .location = .right,
                    .rect = UiRect.fromMinSize(
                        .{ group.rect.max[0] - edge_w, group.rect.min[1] },
                        .{ edge_w, size[1] },
                    ),
                });
                out_drop_targets.append(.{
                    .node_id = group.node_id,
                    .location = .top,
                    .rect = UiRect.fromMinSize(group.rect.min, .{ size[0], edge_h }),
                });
                out_drop_targets.append(.{
                    .node_id = group.node_id,
                    .location = .bottom,
                    .rect = UiRect.fromMinSize(
                        .{ group.rect.min[0], group.rect.max[1] - edge_h },
                        .{ size[0], edge_h },
                    ),
                });
            }

            const node = manager.workspace.dock_layout.getNode(group.node_id) orelse continue;
            const tabs_node = switch (node.*) {
                .tabs => |tabs| tabs,
                .split => {
                    continue;
                },
            };
            if (!self.isTabsNodeUsable(manager, &tabs_node)) continue;

            if (tabs_node.tabs.items.len == 0) continue;

            var tab_x = group.rect.min[0] + pad;
            for (tabs_node.tabs.items, 0..) |panel_id, idx| {
                const panel = self.findPanelById(manager, panel_id) orelse continue;
                const tab_width = self.measureText(panel.title) + pad * 2.0;
                const tab_rect = UiRect.fromMinSize(
                    .{ tab_x, group.rect.min[1] },
                    .{ tab_width, tab_height },
                );
                if (tab_rect.min[0] + tab_width > group.rect.max[0]) break;
                out_tabs.append(.{
                    .panel_id = panel_id,
                    .node_id = group.node_id,
                    .tab_index = idx,
                    .rect = tab_rect,
                });
                tab_x = tab_rect.max[0] + pad;
            }
        }
    }

    fn shouldLogDebug(self: *App, every_frames: u64) bool {
        if (every_frames == 0) return false;
        return self.debug_frame_counter > 0 and (self.debug_frame_counter % every_frames) == 0;
    }

    fn shouldLogStartup(self: *App) bool {
        return self.debug_frame_counter <= 5;
    }

    fn safeWorkspaceCount(_: *App, value: usize, max: usize) usize {
        if (value > max) return max;
        return value;
    }

    fn detachPanelToNewWindow(self: *App, source_window: *UiWindow, panel_id: workspace.PanelId) void {
        const moved = source_window.manager.takePanel(panel_id) orelse return;
        if (source_window.manager.workspace.syncDockLayout() catch false) {
            source_window.manager.workspace.markDirty();
        }
        if (!self.createDetachedWindowFromPanel(source_window, moved)) {
            self.appendPanelToManager(source_window.manager, moved) catch {
                var tmp = moved;
                tmp.deinit(self.allocator);
            };
            source_window.manager.workspace.markDirty();
            if (source_window.manager.workspace.syncDockLayout() catch false) {
                source_window.manager.workspace.markDirty();
            }
        }
    }

    fn createDetachedWindowFromPanel(self: *App, source_window: *UiWindow, panel: workspace.Panel) bool {
        var ws = workspace.Workspace.initEmpty(self.allocator);
        var ws_owned = true;
        defer if (ws_owned) ws.deinit(self.allocator);

        ws.panels.append(self.allocator, panel) catch return false;
        ws.focused_panel_id = panel.id;
        _ = ws.syncDockLayout() catch false;

        const new_manager = self.allocator.create(panel_manager.PanelManager) catch return false;
        var owns_manager = true;
        defer if (owns_manager) {
            new_manager.deinit();
            self.allocator.destroy(new_manager);
        };

        new_manager.* = panel_manager.PanelManager.init(
            self.allocator,
            ws,
            &self.next_panel_id,
        );
        self.bindNextPanelId(new_manager);
        ws_owned = false;
        if (self.createDetachedWindowFromManager(source_window, new_manager, panel.title, true)) |_| {
            owns_manager = false;
            return true;
        } else |_| {
            return false;
        }
    }

    fn createDetachedWindowFromManager(
        self: *App,
        source_window: *UiWindow,
        manager: *panel_manager.PanelManager,
        title: []const u8,
        persist_in_workspace: bool,
    ) !*UiWindow {
        const width: c_int = 960;
        const height: c_int = 720;
        const title_with_null = try self.allocator.alloc(u8, title.len + 1);
        defer self.allocator.free(title_with_null);
        @memcpy(title_with_null[0..title.len], title);
        title_with_null[title.len] = 0;
        const title_z: [:0]const u8 = title_with_null[0..title.len :0];

        const win = zapp.sdl_app.createWindow(title_z, width, height, c.SDL_WINDOW_RESIZABLE) catch {
            return error.SdlWindowCreateFailed;
        };
        errdefer c.SDL_DestroyWindow(win);

        var pos_x: c_int = 0;
        var pos_y: c_int = 0;
        _ = c.SDL_GetWindowPosition(source_window.window, &pos_x, &pos_y);
        const offset: c_int = @intCast(@min(self.ui_windows.items.len * 24, 220));
        _ = c.SDL_SetWindowPosition(win, pos_x + offset, pos_y + offset);

        const out = try self.createUiWindowFromExisting(
            win,
            title,
            manager,
            false,
            persist_in_workspace,
            true,
            true,
        );
        errdefer self.destroyUiWindow(out);
        try self.ui_windows.append(self.allocator, out);
        return out;
    }

    fn pollWebSocket(self: *App) !void {
        if (self.ws_client) |*client| {
            var count: u32 = 0;
            // Drain all available messages (non-blocking, like ZSC)
            while (client.tryReceive()) |msg| {
                count += 1;
                std.log.info("[ZSS] Received frame ({d} bytes)", .{ msg.len });
                defer self.allocator.free(msg);

                self.handleIncomingMessage(msg) catch |err| {
                    const msg_text = try std.fmt.allocPrint(self.allocator, "Failed to parse message: {s}", .{@errorName(err)});
                    defer self.allocator.free(msg_text);
                    try self.appendMessage("system", msg_text, null);
                };
            }
            if (count > 0) {
                std.log.debug("[ZSS] Polled {d} messages this frame", .{count});
            }
        }
    }

    fn handleKeyDownEvent(self: *App, key_evt: anytype, request_spawn_window: *bool, manager: *panel_manager.PanelManager) !void {
        switch (key_evt.key) {
            .escape => {
                self.running = false;
            },
            .y => {
                if (key_evt.mods.ctrl and !key_evt.repeat) {
                    request_spawn_window.* = true;
                }
            },
            .enter, .keypad_enter => {
                // Check if we're focused on settings URL input
                if (self.settings_panel.focused_field != .none) {
                    try self.tryConnect(manager);
                }
            },
            .v => {
                if (self.settings_panel.focused_field != .none and key_evt.mods.ctrl and !key_evt.repeat) {
                    const clip = zapp.clipboard.getTextZ();
                    if (clip.len > 0) {
                        switch (self.settings_panel.focused_field) {
                            .server_url => try self.settings_panel.server_url.appendSlice(self.allocator, clip),
                            .default_session => try self.settings_panel.default_session.appendSlice(self.allocator, clip),
                            .ui_theme => try self.settings_panel.ui_theme.appendSlice(self.allocator, clip),
                            .ui_profile => try self.settings_panel.ui_profile.appendSlice(self.allocator, clip),
                            .ui_theme_pack => try self.settings_panel.ui_theme_pack.appendSlice(self.allocator, clip),
                            .none => {},
                        }
                    }
                }
            },
            .back_space => {
                if (self.settings_panel.focused_field == .server_url and self.settings_panel.server_url.items.len > 0) {
                    _ = self.settings_panel.server_url.pop();
                } else if (self.settings_panel.focused_field == .default_session and self.settings_panel.default_session.items.len > 0) {
                    _ = self.settings_panel.default_session.pop();
                } else if (self.settings_panel.focused_field == .ui_theme and self.settings_panel.ui_theme.items.len > 0) {
                    _ = self.settings_panel.ui_theme.pop();
                } else if (self.settings_panel.focused_field == .ui_profile and self.settings_panel.ui_profile.items.len > 0) {
                    _ = self.settings_panel.ui_profile.pop();
                } else if (self.settings_panel.focused_field == .ui_theme_pack and self.settings_panel.ui_theme_pack.items.len > 0) {
                    _ = self.settings_panel.ui_theme_pack.pop();
                }
            },
            .delete => {
                if (self.settings_panel.focused_field == .server_url and self.settings_panel.server_url.items.len > 0) {
                    _ = self.settings_panel.server_url.pop();
                } else if (self.settings_panel.focused_field == .default_session and self.settings_panel.default_session.items.len > 0) {
                    _ = self.settings_panel.default_session.pop();
                } else if (self.settings_panel.focused_field == .ui_theme and self.settings_panel.ui_theme.items.len > 0) {
                    _ = self.settings_panel.ui_theme.pop();
                } else if (self.settings_panel.focused_field == .ui_profile and self.settings_panel.ui_profile.items.len > 0) {
                    _ = self.settings_panel.ui_profile.pop();
                } else if (self.settings_panel.focused_field == .ui_theme_pack and self.settings_panel.ui_theme_pack.items.len > 0) {
                    _ = self.settings_panel.ui_theme_pack.pop();
                }
            },
            else => {},
        }
    }

    fn handleTextInput(self: *App, text: []const u8) !void {
        if (text.len == 0) return;

        switch (self.settings_panel.focused_field) {
            .server_url => {
                for (text) |ch| {
                    if (ch >= 32 and ch < 127) {
                        try self.settings_panel.server_url.append(self.allocator, ch);
                    }
                }
            },
            .default_session => {
                for (text) |ch| {
                    if (ch >= 32 and ch < 127) {
                        try self.settings_panel.default_session.append(self.allocator, ch);
                    }
                }
            },
            .ui_theme => {
                for (text) |ch| {
                    if (ch >= 32 and ch < 127) {
                        try self.settings_panel.ui_theme.append(self.allocator, ch);
                    }
                }
            },
            .ui_profile => {
                for (text) |ch| {
                    if (ch >= 32 and ch < 127) {
                        try self.settings_panel.ui_profile.append(self.allocator, ch);
                    }
                }
            },
            .ui_theme_pack => {
                for (text) |ch| {
                    if (ch >= 32 and ch < 127) {
                        try self.settings_panel.ui_theme_pack.append(self.allocator, ch);
                    }
                }
            },
            .none => {},
        }
    }

    fn syncSettingsToConfig(self: *App) !void {
        try self.config.setServerUrl(self.settings_panel.server_url.items);
        try self.config.setDefaultSession(self.settings_panel.default_session.items);
        self.config.auto_connect_on_launch = self.settings_panel.auto_connect_on_launch;
        try self.config.setTheme(if (self.settings_panel.ui_theme.items.len > 0) self.settings_panel.ui_theme.items else null);
        try self.config.setProfile(if (self.settings_panel.ui_profile.items.len > 0) self.settings_panel.ui_profile.items else null);
        try self.config.setThemePack(if (self.settings_panel.ui_theme_pack.items.len > 0) self.settings_panel.ui_theme_pack.items else null);
        self.config.setWatchThemePack(self.settings_panel.watch_theme_pack);
        try self.config.save();

        self.applyThemeFromSettings();
    }

    fn applyThemeFromSettings(self: *App) void {
        const label = if (self.settings_panel.ui_theme.items.len > 0)
            self.settings_panel.ui_theme.items
        else
            null;
        const mode: zui.theme.Mode = if (label) |value|
            if (std.ascii.eqlIgnoreCase(value, "dark"))
                .dark
            else
                .light
        else
            .light;
        zui.theme.setMode(mode);
        self.theme = zui.theme.current();
    }

    fn drawFrame(self: *App, ui_window: *UiWindow) void {
        self.theme = zui.theme.current();
        self.render_input_queue = &ui_window.queue;
        defer self.render_input_queue = null;

        ui_input_router.setExternalQueue(&ui_window.queue);
        defer ui_input_router.setExternalQueue(null);

        var fb_w: c_int = 0;
        var fb_h: c_int = 0;
        _ = c.SDL_GetWindowSizeInPixels(ui_window.window, &fb_w, &fb_h);
        const fb_width: u32 = @intCast(if (fb_w > 0) fb_w else 1);
        const fb_height: u32 = @intCast(if (fb_h > 0) fb_h else 1);

        ui_window.swapchain.beginFrame(&self.gpu, fb_width, fb_height);

        // Draw the dock-based UI
        self.drawDockUi(ui_window, fb_width, fb_height);

        // Render the UI commands through WebGPU
        self.gpu.ui_renderer.beginFrame(fb_width, fb_height);
        ui_window.swapchain.render(&self.gpu, &self.ui_commands);
    }

    fn drawDockUi(self: *App, ui_window: *UiWindow, fb_width: u32, fb_height: u32) void {
        self.ui_commands.clear();
        ui_draw_context.setGlobalCommandList(&self.ui_commands);
        defer ui_draw_context.clearGlobalCommandList();

        const viewport = UiRect.fromMinSize(
            .{ 0, 0 },
            .{ @floatFromInt(fb_width), @floatFromInt(fb_height) },
        );

        // Draw background
        self.ui_commands.pushRect(
            .{ .min = .{ 0, 0 }, .max = .{ @floatFromInt(fb_width), @floatFromInt(fb_height) } },
            .{ .fill = self.theme.colors.background },
        );

        ui_window.ui_state.last_dock_content_rect = viewport;

        var layout: dock_graph.LayoutResult = .{};
        if (!self.collectDockLayoutSafe(ui_window.manager, viewport, &layout)) {
            if (self.shouldLogDebug(120) or self.shouldLogStartup()) {
                std.log.warn("drawDockUi: unable to recover dock layout; no panels available", .{});
            }
            self.drawText(
                viewport.min[0] + 12.0,
                viewport.min[1] + 12.0,
                "Unable to recover dock layout; no panels available.",
                self.theme.colors.text_secondary,
            );
            self.drawStatusOverlay(fb_width, fb_height);
            return;
        }
        // Draw each dock group
        for (layout.slice()) |group| {
            if (!self.isLayoutGroupUsable(ui_window.manager, group.node_id)) continue;
            self.drawDockGroup(ui_window.manager, group.node_id, group.rect);
        }

        const splitters = ui_window.manager.workspace.dock_layout.computeSplitters(viewport);
        self.drawDockSplitters(&ui_window.queue, ui_window, &splitters);

        var drag_tab_hits = DockTabHitList{};
        var drag_drop_targets = DockDropTargetList{};
        self.collectDockInteractionGeometry(ui_window.manager, viewport, &drag_tab_hits, &drag_drop_targets);
        self.drawDockDragOverlay(&ui_window.queue, ui_window.manager, ui_window, &drag_drop_targets, viewport);

        // Draw connection status overlay
        self.drawStatusOverlay(fb_width, fb_height);
    }

    fn drawUnavailableWorkspaceFrame(self: *App, ui_window: *UiWindow, message: []const u8) void {
        var fb_w: c_int = 0;
        var fb_h: c_int = 0;
        _ = c.SDL_GetWindowSizeInPixels(ui_window.window, &fb_w, &fb_h);
        const fb_width: u32 = @intCast(if (fb_w > 0) fb_w else 1);
        const fb_height: u32 = @intCast(if (fb_h > 0) fb_h else 1);
        self.render_input_queue = &ui_window.queue;
        defer self.render_input_queue = null;

        self.ui_commands.clear();
        ui_draw_context.setGlobalCommandList(&self.ui_commands);
        defer ui_draw_context.clearGlobalCommandList();

        self.ui_commands.pushRect(
            .{ .min = .{ 0, 0 }, .max = .{ @floatFromInt(fb_width), @floatFromInt(fb_height) } },
            .{ .fill = self.theme.colors.background },
        );

        const viewport = UiRect.fromMinSize(
            .{ 0, 0 },
            .{ @floatFromInt(fb_width), @floatFromInt(fb_height) },
        );
        ui_window.ui_state.last_dock_content_rect = viewport;

        self.drawText(
            viewport.min[0] + 12.0,
            viewport.min[1] + 12.0,
            message,
            self.theme.colors.text_primary,
        );

        self.drawText(
            viewport.min[0] + 12.0,
            viewport.min[1] + 36.0,
            "Please wait; layout is being restored.",
            self.theme.colors.text_secondary,
        );

        self.drawStatusOverlay(fb_width, fb_height);

        ui_window.swapchain.beginFrame(&self.gpu, fb_width, fb_height);
        self.gpu.ui_renderer.beginFrame(fb_width, fb_height);
        ui_window.swapchain.render(&self.gpu, &self.ui_commands);
    }

    fn drawDockGroup(self: *App, manager: *panel_manager.PanelManager, node_id: dock_graph.NodeId, rect: UiRect) void {
        if (!self.isLayoutGroupUsable(manager, node_id)) return;
        const node = manager.workspace.dock_layout.getNode(node_id) orelse return;
        const tabs_node = switch (node.*) {
            .tabs => |tabs| tabs,
            .split => return,
        };
        if (!self.isTabsNodeUsable(manager, &tabs_node)) return;
        if (tabs_node.tabs.items.len == 0) return;
        if (tabs_node.tabs.items.len > manager.workspace.panels.items.len) {
            if (self.shouldLogDebug(120) or self.shouldLogStartup()) {
                std.log.warn("drawDockGroup: tabs node references unknown panel count; skipping render", .{});
            }
            return;
        }
        self.drawTabsPanel(manager, &tabs_node, rect);
    }

    fn drawDockSplitters(
        self: *App,
        queue: *ui_input_state.InputQueue,
        ui_window: *UiWindow,
        splitters: *const dock_graph.SplitterResult,
    ) void {
        for (splitters.slice()) |splitter| {
            const hovered = splitter.handle_rect.contains(queue.state.mouse_pos);
            const active = ui_window.ui_state.split_drag.node_id != null and ui_window.ui_state.split_drag.node_id.? == splitter.node_id;
            const fill = if (active)
                zcolors.withAlpha(self.theme.colors.primary, 0.22)
            else if (hovered)
                zcolors.withAlpha(self.theme.colors.primary, 0.12)
            else
                zcolors.withAlpha(self.theme.colors.border, 0.08);
            self.ui_commands.pushRect(
                .{ .min = splitter.handle_rect.min, .max = splitter.handle_rect.max },
                .{ .fill = fill },
            );
        }
    }

    fn drawDockDragOverlay(
        self: *App,
        queue: *ui_input_state.InputQueue,
        manager: *panel_manager.PanelManager,
        ui_window: *UiWindow,
        drop_targets: *const DockDropTargetList,
        dock_rect: UiRect,
    ) void {
        if (!ui_window.ui_state.dock_drag.dragging) return;

        const hovered_target = drop_targets.findAt(queue.state.mouse_pos);
        if (hovered_target) |target| {
            for (drop_targets.items[0..drop_targets.len]) |candidate| {
                if (candidate.node_id != target.node_id or candidate.location == target.location) continue;
                self.drawDockDropPreview(candidate, false);
            }
            self.drawDockDropPreview(target, true);
        }

        const panel_id = ui_window.ui_state.dock_drag.panel_id orelse return;
        const panel = self.findPanelById(manager, panel_id) orelse return;
        var hint: []const u8 = "No dock target";
        if (hovered_target) |target| {
            hint = dockDropTargetLabel(target.location);
        } else if (!dock_rect.contains(queue.state.mouse_pos)) {
            hint = "Detach to new window";
        }

        var label_buf: [256]u8 = undefined;
        const text = std.fmt.bufPrint(&label_buf, "{s} -> {s}", .{ panel.title, hint }) catch panel.title;
        const text_w = self.measureText(text);
        const pad = self.theme.spacing.xs;
        const label_rect = UiRect.fromMinSize(
            .{ queue.state.mouse_pos[0] + 14.0, queue.state.mouse_pos[1] + 14.0 },
            .{ text_w + pad * 2.0, (18.0 * self.ui_scale) + pad * 2.0 },
        );
        self.ui_commands.pushRect(
            .{ .min = label_rect.min, .max = label_rect.max },
            .{
                .fill = zcolors.withAlpha(self.theme.colors.background, 0.92),
                .stroke = zcolors.withAlpha(self.theme.colors.border, 0.9),
            },
        );
        self.drawText(
            label_rect.min[0] + pad,
            label_rect.min[1] + pad,
            text,
            self.theme.colors.text_primary,
        );
    }

    fn drawDockDropPreview(self: *App, target: DockDropTarget, active: bool) void {
        const fill = if (active)
            zcolors.withAlpha(self.theme.colors.primary, 0.20)
        else
            zcolors.withAlpha(self.theme.colors.primary, 0.07);
        const stroke = if (active)
            zcolors.withAlpha(self.theme.colors.primary, 0.86)
        else
            zcolors.withAlpha(self.theme.colors.primary, 0.35);
        self.ui_commands.pushRect(
            .{ .min = target.rect.min, .max = target.rect.max },
            .{ .fill = fill, .stroke = stroke },
        );
    }

    fn collectDockLayout(
        self: *App,
        manager: *panel_manager.PanelManager,
        root_rect: UiRect,
        out: *dock_graph.LayoutResult,
    ) bool {
        out.len = 0;

        const graph = &manager.workspace.dock_layout;
        if (manager.workspace.panels.items.len > 4096) return false;
        if (graph.nodes.items.len > 16384) return false;
        if (!self.isDockLayoutGraphHeaderSane(graph)) return false;
        const root = graph.root orelse return false;

        if (root >= graph.nodes.items.len) {
            if (self.shouldLogDebug(240)) {
                std.log.debug("collectDockLayout: root {} out of range nodes_len={}", .{ root, graph.nodes.items.len });
            }
            return false;
        }
        if (graph.nodes.items.len == 0) {
            if (self.shouldLogDebug(240)) {
                std.log.debug("collectDockLayout: empty node list", .{});
            }
            return false;
        }
        if (self.isDockLayoutCorrupt(manager)) return false;
        const computed = graph.computeLayout(root_rect);
        for (computed.slice()) |group| {
            if (self.isLayoutGroupUsable(manager, group.node_id)) {
                out.append(group);
            }
        }
        return out.len > 0;
    }

    fn isLayoutGroupUsable(self: *App, manager: *panel_manager.PanelManager, node_id: dock_graph.NodeId) bool {
        if (node_id >= manager.workspace.dock_layout.nodes.items.len) return false;
        if (!self.isDockLayoutGraphHeaderSane(&manager.workspace.dock_layout)) return false;
        const node = manager.workspace.dock_layout.getNode(node_id) orelse return false;
        const tabs_node = switch (node.*) {
            .tabs => |tabs| tabs,
            .split => return false,
        };
        if (tabs_node.tabs.items.len == 0) return false;
        if (tabs_node.tabs.items.len > manager.workspace.panels.items.len) return false;
        return true;
    }

fn computeSplitRect(rect: UiRect, axis: dock_graph.Axis, ratio: f32) struct { first: UiRect, second: UiRect } {
    const size = rect.size();
    const clamped_ratio = std.math.clamp(ratio, 0.1, 0.9);
    const gap: f32 = 6.0;
    if (axis == .vertical) {
        const avail = @max(0.0, size[0] - gap);
        const first_w = avail * clamped_ratio;
        const second_w = avail - first_w;
        const first_rect = UiRect.fromMinSize(rect.min, .{ first_w, size[1] });
        const second_min = .{ rect.min[0] + first_w + gap, rect.min[1] };
        const second_rect = UiRect.fromMinSize(second_min, .{ second_w, size[1] });
        return .{ .first = first_rect, .second = second_rect };
    }

    const avail = @max(0.0, size[1] - gap);
    const first_h = avail * clamped_ratio;
    const second_h = avail - first_h;
    const first_rect = UiRect.fromMinSize(rect.min, .{ size[0], first_h });
    const second_min = .{ rect.min[0], rect.min[1] + first_h + gap };
    const second_rect = UiRect.fromMinSize(second_min, .{ size[0], second_h });
    return .{ .first = first_rect, .second = second_rect };
}

    fn repairDockLayout(self: *App, manager: *panel_manager.PanelManager) bool {
        _ = self;
        if (manager.workspace.panels.items.len == 0) return false;
        var graph = &manager.workspace.dock_layout;
        const panel_count = manager.workspace.panels.items.len;
        if (panel_count > 4096) {
            graph.nodes.clearRetainingCapacity();
            graph.root = null;
            return false;
        }

        graph.nodes.clearRetainingCapacity();
        graph.root = null;
        return manager.workspace.syncDockLayout() catch false;
    }

    fn isDockLayoutCorrupt(self: *App, manager: *panel_manager.PanelManager) bool {
        const graph = &manager.workspace.dock_layout;
        if (!self.isDockLayoutGraphHeaderSane(graph)) return true;
        if (graph.root == null) {
            return graph.nodes.items.len > 0;
        }
        const root = graph.root.?;
        if (root >= graph.nodes.items.len) return true;
        if (graph.getNode(root) == null) return true;

        if (graph.nodes.items.len == 0) return true;
        const visited = self.allocator.alloc(bool, graph.nodes.items.len) catch return true;
        defer self.allocator.free(visited);
        const in_stack = self.allocator.alloc(bool, graph.nodes.items.len) catch return true;
        defer self.allocator.free(in_stack);
        @memset(visited, false);
        @memset(in_stack, false);

        return !self.validateDockNode(
            manager,
            root,
            graph,
            visited,
            in_stack,
        );
    }

    fn validateDockNode(
        self: *App,
        manager: *panel_manager.PanelManager,
        node_id: dock_graph.NodeId,
        graph: *const dock_graph.Graph,
        visited: []bool,
        in_stack: []bool,
    ) bool {
        if (node_id >= graph.nodes.items.len) return false;
        if (node_id >= visited.len) return false;
        const idx: usize = @intCast(node_id);
        if (visited[idx]) return true;
        if (in_stack[idx]) return false;
        visited[idx] = true;
        in_stack[idx] = true;
        defer in_stack[idx] = false;

        const node = graph.getNode(node_id) orelse return false;
        switch (node.*) {
            .tabs => |tabs| {
                if (tabs.tabs.items.len == 0) return false;
                if (tabs.active >= tabs.tabs.items.len) {
                    if (self.shouldLogDebug(480)) {
                        std.log.debug("validateDockNode: stale active tab index {d} for {} tabs", .{
                            tabs.active,
                            tabs.tabs.items.len,
                        });
                    }
                }
                if (tabs.tabs.items.len > 4096) return false;
                for (tabs.tabs.items) |panel_id| {
                    if (self.findPanelById(manager, panel_id) == null) {
                        if (self.shouldLogDebug(480)) {
                            std.log.debug("validateDockNode: panel id {} not in workspace", .{panel_id});
                        }
                        return false;
                    }
                }
                return true;
            },
            .split => |split| {
                if (!std.math.isFinite(split.ratio) or split.ratio < 0.0 or split.ratio > 1.0) return false;
                if (split.first >= graph.nodes.items.len or split.second >= graph.nodes.items.len) return false;
                if (split.first == split.second) return false;
                return self.validateDockNode(manager, split.first, graph, visited, in_stack) and
                    self.validateDockNode(manager, split.second, graph, visited, in_stack);
            },
        }
    }

    fn drawTabsPanel(self: *App, manager: *panel_manager.PanelManager, tabs: *const dock_graph.TabsNode, rect: UiRect) void {
        if (!self.isTabsNodeUsable(manager, tabs)) return;
        const pad = self.theme.spacing.sm;
        const tab_height: f32 = 28.0 * self.ui_scale;

        // Draw panel background
        self.ui_commands.pushRect(
            .{ .min = rect.min, .max = rect.max },
            .{ .fill = self.theme.colors.surface },
        );

        // Draw tab bar
        const tab_bar_rect = UiRect.fromMinSize(
            rect.min,
            .{ rect.max[0] - rect.min[0], tab_height },
        );
        self.ui_commands.pushRect(
            .{ .min = tab_bar_rect.min, .max = tab_bar_rect.max },
            .{ .fill = self.theme.colors.background },
        );

        var tab_x = rect.min[0] + pad;
        var active_tab_id = if (tabs.active < tabs.tabs.items.len)
            tabs.tabs.items[tabs.active]
        else
            null;
        if (active_tab_id == null) {
            for (tabs.tabs.items) |candidate_panel_id| {
                if (self.findPanelById(manager, candidate_panel_id) != null) {
                    active_tab_id = candidate_panel_id;
                    break;
                }
            }
        }

            // Draw each tab
            for (tabs.tabs.items) |panel_id| {
                const panel = self.findPanelById(manager, panel_id) orelse continue;
            const is_active = panel_id == active_tab_id;

            const tab_width = self.measureText(panel.title) + pad * 2.0;
            const tab_rect = UiRect.fromMinSize(
                .{ tab_x, rect.min[1] },
                .{ tab_width, tab_height },
            );

            // Tab background
            const tab_color = if (is_active)
                self.theme.colors.surface
            else
                self.theme.colors.background;
            self.ui_commands.pushRect(
                .{ .min = tab_rect.min, .max = tab_rect.max },
                .{ .fill = tab_color },
            );

            // Tab border
            self.ui_commands.pushRect(
                .{ .min = tab_rect.min, .max = tab_rect.max },
                .{ .stroke = self.theme.colors.border },
            );

            // Tab text
            self.drawText(
                tab_x + pad,
                rect.min[1] + 6.0,
                panel.title,
                self.theme.colors.text_primary,
            );

            tab_x += tab_width + pad;
        }

        // Draw content area for active tab
        const content_rect = UiRect.fromMinSize(
            .{ rect.min[0], rect.min[1] + tab_height },
            .{ rect.max[0] - rect.min[0], rect.max[1] - rect.min[1] - tab_height },
        );

        if (active_tab_id) |panel_id| {
            self.drawPanelContent(manager, panel_id, content_rect);
        }
    }

    fn isTabsNodeUsable(self: *App, manager: *panel_manager.PanelManager, tabs: *const dock_graph.TabsNode) bool {
        if (tabs.tabs.items.len == 0) return false;
        if (tabs.tabs.items.len > MAX_REASONABLE_PANEL_COUNT) return false;
        if (tabs.active >= tabs.tabs.items.len) {
            if (self.shouldLogDebug(480) or self.shouldLogStartup()) {
                std.log.debug("isTabsNodeUsable: stale active index {d} for {} tabs", .{
                    tabs.active,
                    tabs.tabs.items.len,
                });
            }
        }
        if (tabs.tabs.items.len > manager.workspace.panels.items.len) return false;

        for (tabs.tabs.items) |panel_id| {
            if (self.findPanelById(manager, panel_id) == null) {
                if (self.shouldLogDebug(480) or self.shouldLogStartup()) {
                    std.log.debug("isTabsNodeUsable: unknown panel id {d}", .{panel_id});
                }
                return false;
            }
        }
        return true;
    }

    fn findPanelById(_: *App, manager: *panel_manager.PanelManager, panel_id: workspace.PanelId) ?*workspace.Panel {
        for (manager.workspace.panels.items) |*panel| {
            if (panel.id == panel_id) return panel;
        }
        return null;
    }

    fn drawPanelContent(self: *App, manager: *panel_manager.PanelManager, panel_id: workspace.PanelId, rect: UiRect) void {
        const panel = self.findPanelById(manager, panel_id) orelse return;

        switch (panel.kind) {
            .Chat => {
                self.drawChatPanel(rect);
            },
            .Settings, .Control => {
                self.drawSettingsPanel(manager, rect);
            },
            else => {
                // Draw placeholder for other panel types
                self.drawText(
                    rect.min[0] + 20,
                    rect.min[1] + 20,
                    panel.title,
                    self.theme.colors.text_primary,
                );
            },
        }
    }

    fn drawSettingsPanel(self: *App, manager: *panel_manager.PanelManager, rect: UiRect) void {
        const pad = self.theme.spacing.md;
        var y = rect.min[1] + pad;
        const rect_width = rect.max[0] - rect.min[0];

        // Title
        self.drawLabel(
            rect.min[0] + pad,
            y,
            "ZiggyStarSpider - Settings",
            self.theme.colors.text_primary,
        );
        y += 30;

        // Server URL label
        self.drawLabel(
            rect.min[0] + pad,
            y,
            "Server URL",
            self.theme.colors.text_primary,
        );
        y += 20.0 * self.ui_scale;

        // URL Input
        const input_height: f32 = 32.0 * self.ui_scale;
        const input_rect = Rect.fromXYWH(
            rect.min[0] + pad,
            y,
            @max(200, rect_width - pad * 2.0),
            input_height,
        );

        const url_focused = self.drawTextInputWidget(
            input_rect,
            self.settings_panel.server_url.items,
            self.settings_panel.focused_field == .server_url,
            .{ .placeholder = "ws://127.0.0.1:18790" },
        );
        if (url_focused) self.settings_panel.focused_field = .server_url;

        y += input_height + pad;

        // Default Session label
        self.drawLabel(
            rect.min[0] + pad,
            y,
            "Default session",
            self.theme.colors.text_primary,
        );
        y += 20.0 * self.ui_scale;

        const default_session_rect = Rect.fromXYWH(
            rect.min[0] + pad,
            y,
            @max(200, rect_width - pad * 2.0),
            input_height,
        );
        const default_session_focused = self.drawTextInputWidget(
            default_session_rect,
            self.settings_panel.default_session.items,
            self.settings_panel.focused_field == .default_session,
            .{ .placeholder = "main" },
        );
        if (default_session_focused) self.settings_panel.focused_field = .default_session;

        y += input_height + pad;
        self.drawLabel(
            rect.min[0] + pad,
            y,
            "UI Theme",
            self.theme.colors.text_primary,
        );
        y += 20.0 * self.ui_scale;
        const ui_theme_rect = Rect.fromXYWH(
            rect.min[0] + pad,
            y,
            @max(200, rect_width - pad * 2.0),
            input_height,
        );
        const ui_theme_focused = self.drawTextInputWidget(
            ui_theme_rect,
            self.settings_panel.ui_theme.items,
            self.settings_panel.focused_field == .ui_theme,
            .{ .placeholder = "default" },
        );
        if (ui_theme_focused) self.settings_panel.focused_field = .ui_theme;

        y += input_height + pad;
        self.drawLabel(
            rect.min[0] + pad,
            y,
            "UI Profile",
            self.theme.colors.text_primary,
        );
        y += 20.0 * self.ui_scale;
        const ui_profile_rect = Rect.fromXYWH(
            rect.min[0] + pad,
            y,
            @max(200, rect_width - pad * 2.0),
            input_height,
        );
        const ui_profile_focused = self.drawTextInputWidget(
            ui_profile_rect,
            self.settings_panel.ui_profile.items,
            self.settings_panel.focused_field == .ui_profile,
            .{ .placeholder = "default" },
        );
        if (ui_profile_focused) self.settings_panel.focused_field = .ui_profile;

        y += input_height + pad;
        self.drawLabel(
            rect.min[0] + pad,
            y,
            "UI Theme Pack",
            self.theme.colors.text_primary,
        );
        y += 20.0 * self.ui_scale;
        const ui_theme_pack_rect = Rect.fromXYWH(
            rect.min[0] + pad,
            y,
            @max(200, rect_width - pad * 2.0),
            input_height,
        );
        const ui_theme_pack_focused = self.drawTextInputWidget(
            ui_theme_pack_rect,
            self.settings_panel.ui_theme_pack.items,
            self.settings_panel.focused_field == .ui_theme_pack,
            .{ .placeholder = "" },
        );
        if (ui_theme_pack_focused) self.settings_panel.focused_field = .ui_theme_pack;

        y += input_height + pad * 0.5;
        const watch_button_label = if (self.settings_panel.watch_theme_pack)
            "Watch Theme Pack: On"
        else
            "Watch Theme Pack: Off";
        const watch_button_rect = Rect.fromXYWH(
            rect.min[0] + pad,
            y,
            @max(200, rect_width * 0.65),
            input_height,
        );
        const watch_pack_clicked = self.drawButtonWidget(
            watch_button_rect,
            watch_button_label,
            .{ .variant = .secondary },
        );
        if (watch_pack_clicked) {
            self.settings_panel.watch_theme_pack = !self.settings_panel.watch_theme_pack;
        }

        // Auto connect toggle
        y += input_height + pad;
        const button_height: f32 = 32.0 * self.ui_scale;
        const auto_connect_label = if (self.settings_panel.auto_connect_on_launch)
            "Auto Connect: On"
        else
            "Auto Connect: Off";
        const auto_connect_rect = Rect.fromXYWH(
            rect.min[0] + pad,
            y,
            @max(200, rect_width * 0.55),
            button_height,
        );
        const auto_connect_clicked = self.drawButtonWidget(
            auto_connect_rect,
            auto_connect_label,
            .{ .variant = .secondary },
        );
        if (auto_connect_clicked) {
            self.settings_panel.auto_connect_on_launch = !self.settings_panel.auto_connect_on_launch;
        }

        // Handle click outside text fields
        if (self.mouse_clicked and
            !input_rect.contains(.{ self.mouse_x, self.mouse_y }) and
            !default_session_rect.contains(.{ self.mouse_x, self.mouse_y }) and
            !ui_theme_rect.contains(.{ self.mouse_x, self.mouse_y }) and
            !ui_profile_rect.contains(.{ self.mouse_x, self.mouse_y }) and
            !ui_theme_pack_rect.contains(.{ self.mouse_x, self.mouse_y }))
        {
            self.settings_panel.focused_field = .none;
        }

        // Connect button
        const button_width: f32 = 120.0 * self.ui_scale;
        const button_y = y + button_height * 1.6;
        const button_rect = Rect.fromXYWH(
            rect.min[0] + pad,
            button_y,
            button_width,
            button_height,
        );

        const connect_clicked = self.drawButtonWidget(
            button_rect,
            "Connect",
            .{ .variant = .primary, .disabled = self.connection_state == .connecting },
        );
        if (connect_clicked) {
            self.tryConnect(manager) catch {};
        }

        // Save Config button
        const save_button_x = button_rect.max[0] + pad;
        const save_button_rect = Rect.fromXYWH(
            save_button_x,
            button_y,
            button_width,
            button_height,
        );
        const save_clicked = self.drawButtonWidget(
            save_button_rect,
            "Save Config",
            .{ .variant = .secondary },
        );
        if (save_clicked) {
            self.saveConfig() catch |err| {
                self.setConnectionState(.error_state, "Failed to save config");
                std.log.err("Save config failed: {s}", .{@errorName(err)});
            };
        }

        y += button_height + pad * 2.0;

        // Status row
        const status_height: f32 = 32.0 * self.ui_scale;
        const status_rect = Rect.fromXYWH(
            rect.min[0] + pad,
            y,
            @max(200, rect_width - pad * 2.0),
            status_height,
        );
        self.drawStatusRow(status_rect);

        y += status_height + pad;

        // Tip
        self.drawLabel(
            rect.min[0] + pad,
            y,
            "Tip: Enter URL, press Connect, then chat.",
            self.theme.colors.text_secondary,
        );
    }

    fn drawChatPanel(self: *App, rect: UiRect) void {
        if (self.render_input_queue == null) {
            self.drawText(
                rect.min[0] + 8.0,
                rect.min[1] + 8.0,
            "Chat panel unavailable: input system not ready",
            self.theme.colors.text_secondary,
        );
        return;
        }

        const pad = self.theme.spacing.sm;
        const session_key_for_panel: ?[]const u8 = if (self.current_session_key) |key| key else if (self.connection_state == .connected) "main" else null;
        const panel_rect = UiRect.fromMinSize(
            .{ rect.min[0] + pad, rect.min[1] + pad },
            .{
                @max(120.0, rect.max[0] - rect.min[0] - pad * 2.0),
                @max(120.0, rect.max[1] - rect.min[1] - pad * 2.0),
            },
        );

        ui_input_router.setExternalQueue(self.render_input_queue);

        const action = ChatPanel.draw(
            self.allocator,
            &self.chat_panel_state,
            "zss-gui",
            session_key_for_panel,
            self.activeMessages(),
            null,
            null,
            "🕷",
            "ZSS",
            self.chat_sessions.items,
            0,
            panel_rect,
            null,
        );

        self.handleChatPanelAction(action);
    }

    fn drawStatusOverlay(self: *App, fb_width: u32, fb_height: u32) void {
        const status_height: f32 = 24.0 * self.ui_scale;
        const fb_w: f32 = @floatFromInt(fb_width);
        const fb_h: f32 = @floatFromInt(fb_height);
        const status_rect = UiRect.fromMinSize(
            .{ 0, fb_h - status_height },
            .{ fb_w, status_height },
        );

        // Semi-transparent background
        const bg_color = zcolors.withAlpha(self.theme.colors.background, 0.9);
        self.ui_commands.pushRect(
            .{ .min = status_rect.min, .max = status_rect.max },
            .{ .fill = bg_color },
        );

        // Status indicator
        const indicator_size: f32 = 8.0 * self.ui_scale;
        const indicator_color = switch (self.connection_state) {
            .disconnected => zcolors.rgba(200, 80, 80, 255),
            .connecting => zcolors.rgba(220, 200, 60, 255),
            .connected => zcolors.rgba(90, 210, 90, 255),
            .error_state => zcolors.rgba(230, 120, 70, 255),
        };

        self.ui_commands.pushRect(
            .{
                .min = .{ status_rect.min[0] + 8, status_rect.min[1] + 8 },
                .max = .{ status_rect.min[0] + 8 + indicator_size, status_rect.min[1] + 8 + indicator_size },
            },
            .{ .fill = indicator_color },
        );

        // Status text
        self.drawText(
            status_rect.min[0] + 24,
            status_rect.min[1] + 4,
            self.status_text,
            self.theme.colors.text_secondary,
        );
    }

    fn drawStatusRow(self: *App, rect: Rect) void {
        self.drawSurfacePanel(rect);

        const indicator = Rect.fromXYWH(rect.min[0] + 8.0, rect.min[1] + 8.0, 12.0, 12.0);
        const dot = switch (self.connection_state) {
            .disconnected => zcolors.rgba(200, 80, 80, 255),
            .connecting => zcolors.rgba(220, 200, 60, 255),
            .connected => zcolors.rgba(90, 210, 90, 255),
            .error_state => zcolors.rgba(230, 120, 70, 255),
        };
        self.drawFilledRect(indicator, dot);

        self.drawTextTrimmed(
            rect.min[0] + 28.0,
            rect.min[1] + 7.0,
            rect.width() - 34.0,
            self.status_text,
            self.theme.colors.text_primary,
        );
    }

    fn drawButtonWidget(self: *App, rect: Rect, label: []const u8, opts: widgets.button.Options) bool {
        const state = widgets.button.updateState(
            .{ .x = rect.min[0], .y = rect.min[1], .width = rect.width(), .height = rect.height() },
            .{ self.mouse_x, self.mouse_y },
            self.mouse_down,
            opts,
        );

        var fill: [4]f32 = switch (opts.variant) {
            .primary => self.theme.colors.primary,
            .secondary => self.theme.colors.surface,
            .ghost => zcolors.withAlpha(self.theme.colors.primary, 0.08),
        };

        if (opts.disabled) {
            fill = zcolors.blend(fill, self.theme.colors.background, 0.45);
        } else if (state.pressed) {
            fill = zcolors.blend(fill, zcolors.rgba(255, 255, 255, 255), 0.22);
        } else if (state.hovered) {
            fill = zcolors.blend(fill, self.theme.colors.primary, 0.12);
        }

        self.drawFilledRect(rect, fill);

        var border = self.theme.colors.border;
        if (state.hovered and !opts.disabled) {
            border = zcolors.blend(border, self.theme.colors.primary, 0.28);
        }
        self.drawRect(rect, border);

        var text_color = switch (opts.variant) {
            .primary => zcolors.rgba(255, 255, 255, 255),
            .secondary => self.theme.colors.text_primary,
            .ghost => self.theme.colors.primary,
        };
        if (opts.disabled) {
            text_color = zcolors.withAlpha(self.theme.colors.text_secondary, 0.7);
        }
        self.drawCenteredText(rect, label, text_color);

        return !opts.disabled and self.mouse_released and rect.contains(.{ self.mouse_x, self.mouse_y });
    }

    fn drawTextInputWidget(
        self: *App,
        rect: Rect,
        text: []const u8,
        currently_focused: bool,
        opts: widgets.text_input.Options,
    ) bool {
        const state = widgets.text_input.updateState(
            .{ .x = rect.min[0], .y = rect.min[1], .width = rect.width(), .height = rect.height() },
            .{ self.mouse_x, self.mouse_y },
            self.mouse_clicked,
            currently_focused,
        );

        const fill = widgets.text_input.getFillPaint(self.theme, state, opts);
        const border = widgets.text_input.getBorderColor(self.theme, state, opts);

        self.drawPaintRect(rect, fill);
        self.drawRect(rect, border);

        const text_x = rect.min[0] + 8.0;
        const text_y = rect.min[1] + 10.0;
        const max_w = rect.width() - 16.0;

        if (text.len == 0) {
            const placeholder = if (opts.placeholder.len > 0) opts.placeholder else "";
            if (placeholder.len > 0) {
                self.drawTextTrimmed(text_x, text_y, max_w, placeholder, widgets.text_input.getPlaceholderColor(self.theme));
            }
        } else {
            var text_color = self.theme.colors.text_primary;
            if (opts.disabled) text_color = zcolors.withAlpha(text_color, 0.45);
            self.drawTextTrimmed(text_x, text_y, max_w, text, text_color);
        }

        if (state.focused and !opts.disabled and !opts.read_only) {
            // Draw caret using same measurement as text
            const caret_width: f32 = 2.0 * self.ui_scale;
            const caret_height: f32 = 14.0 * self.ui_scale;

            // Measure text up to caret position for accurate placement
            const text_before_caret = text;
            const caret_offset = self.measureText(text_before_caret);
            const caret_x = text_x + @min(caret_offset, max_w - caret_width);

            const caret_rect = UiRect.fromMinSize(
                .{ caret_x, text_y },
                .{ caret_width, caret_height },
            );
            self.ui_commands.pushRect(
                .{ .min = caret_rect.min, .max = caret_rect.max },
                .{ .fill = self.theme.colors.primary },
            );
        }

        return state.focused;
    }

    fn tryConnect(self: *App, manager: *panel_manager.PanelManager) !void {
        if (self.settings_panel.server_url.items.len == 0) {
            self.setConnectionState(.error_state, "Server URL cannot be empty");
            return;
        }

        self.setConnectionState(.connecting, "Connecting...");
        self.disconnect();

        const effective_url = self.settings_panel.server_url.items;
        const connect_token = if (self.config.token.len > 0) self.config.token else self.config.auth_token;
        const client = ws_client_mod.WebSocketClient.init(self.allocator, effective_url, connect_token) catch |err| {
            const msg = try std.fmt.allocPrint(self.allocator, "Client init failed: {s}", .{@errorName(err)});
            defer self.allocator.free(msg);
            self.setConnectionState(.error_state, msg);
            return;
        };
        self.ws_client = client;

        self.ws_client.?.connect() catch |err| {
            self.ws_client.?.deinit();
            self.ws_client = null;
            const msg = try std.fmt.allocPrint(self.allocator, "Connect failed: {s}", .{@errorName(err)});
            defer self.allocator.free(msg);
            self.setConnectionState(.error_state, msg);
            return;
        };

        self.setConnectionState(.connected, "Connected");
        self.settings_panel.focused_field = .none;

        // Save URL to config on successful connect
        self.config.setAuthToken(connect_token) catch {};
        if (self.settings_panel.default_session.items.len == 0) {
            try self.settings_panel.default_session.appendSlice(self.allocator, "main");
        }
        self.syncSettingsToConfig() catch |err| {
            std.log.warn("Failed to save config on connect: {s}", .{@errorName(err)});
        };

        self.clearSessions();
        if (self.config.default_session) |default_session| {
            const seed = if (default_session.len > 0) default_session else "main";
            try self.ensureSessionExists(seed, seed);
        } else {
            try self.ensureSessionExists("main", "Main");
        }

        try self.appendMessage("system", "Connected to Spiderweb", null);

        // Switch to chat panel by focusing it
        for (manager.workspace.panels.items) |*panel| {
            if (panel.kind == .Chat) {
                manager.focusPanel(panel.id);
                break;
            }
        }
    }

    fn focusSettingsPanel(_: *App, manager: *panel_manager.PanelManager) void {
        for (manager.workspace.panels.items) |*panel| {
            if (panel.kind == .Settings or panel.kind == .Control) {
                manager.focusPanel(panel.id);
                break;
            }
        }
    }

    fn disconnect(self: *App) void {
        if (self.ws_client) |*client| {
            // Drain any pending messages before disconnecting
            while (client.tryReceive()) |msg| {
                self.allocator.free(msg);
            }
            client.deinit();
            self.ws_client = null;
        }
        self.clearPendingSend();
        self.clearSessions();
    }

    fn saveConfig(self: *App) !void {
        if (self.settings_panel.default_session.items.len == 0) {
            try self.settings_panel.default_session.appendSlice(self.allocator, "main");
        }
        try self.syncSettingsToConfig();
    }

    fn sendChatMessageText(self: *App, text: []const u8) !void {
        if (text.len == 0) return;
        std.log.info("[GUI] sendChatMessageText: text_len={d} connected={}", .{ text.len, self.ws_client != null });

        // Keep a session key for this send
        const session_key = try self.currentSessionOrDefault();
        if (session_key.len == 0) {
            try self.appendMessage("system", "No active session available", null);
            return;
        }

        const user_msg_id = try self.nextMessageId("msg");
        const appended_user_msg_id = try self.appendMessageWithIdForSession(session_key, "user", text, .sending, user_msg_id);
        defer self.allocator.free(appended_user_msg_id);
        self.allocator.free(user_msg_id);
        try self.setPendingSend(self.allocator, appended_user_msg_id, session_key);

        const request_id = try self.nextMessageId("req");
        if (self.pending_send_request_id) |request| {
            self.allocator.free(request);
        }
        self.pending_send_request_id = request_id;
        self.awaiting_reply = true;

        if (self.ws_client) |*client| {
            const payload = protocol_messages.buildChatSend(
                self.allocator,
                request_id,
                text,
                session_key,
            ) catch {
                try self.setMessageFailed(appended_user_msg_id);
                self.clearPendingSend();
                return;
            };
            defer self.allocator.free(payload);

            client.send(payload) catch |err| {
                std.log.err("[GUI] sendChatMessageText: websocket send failed: {s}", .{@errorName(err)});
                const err_text = try std.fmt.allocPrint(self.allocator, "Send failed: {s}", .{@errorName(err)});
                defer self.allocator.free(err_text);
                try self.appendMessage("system", err_text, null);
                if (self.pending_send_message_id) |message_id| {
                    try self.setMessageFailed(message_id);
                } else {
                    try self.setMessageFailed(appended_user_msg_id);
                }
                self.clearPendingSend();
                return;
            };
        } else {
            const err_text = try std.fmt.allocPrint(self.allocator, "Not connected", .{});
            defer self.allocator.free(err_text);
            try self.appendMessage("system", err_text, null);
            if (self.pending_send_message_id) |message_id| {
                try self.setMessageFailed(message_id);
            } else {
                try self.setMessageFailed(appended_user_msg_id);
            }
            self.clearPendingSend();
        }
    }

    fn nextMessageId(self: *App, prefix: []const u8) ![]const u8 {
        self.message_counter += 1;
        return try std.fmt.allocPrint(self.allocator, "{s}-{d}", .{ prefix, self.message_counter });
    }

    fn setPendingSend(
        self: *App,
        allocator: std.mem.Allocator,
        message_id: []const u8,
        session_key: []const u8,
    ) !void {
        if (self.pending_send_message_id) |value| allocator.free(value);
        if (self.pending_send_session_key) |value| allocator.free(value);
        self.pending_send_message_id = try allocator.dupe(u8, message_id);
        self.pending_send_session_key = try allocator.dupe(u8, session_key);
    }

    fn clearPendingSend(self: *App) void {
        if (self.pending_send_request_id) |value| {
            self.allocator.free(value);
            for (self.session_messages.items) |*state| {
                if (state.streaming_request_id) |stream_request_id| {
                    if (std.mem.eql(u8, value, stream_request_id)) {
                        self.clearSessionStreamingState(state);
                    }
                }
            }
            self.pending_send_request_id = null;
        }
        if (self.pending_send_message_id) |value| {
            self.allocator.free(value);
            self.pending_send_message_id = null;
        }
        if (self.pending_send_session_key) |value| {
            self.allocator.free(value);
            self.pending_send_session_key = null;
        }
        self.awaiting_reply = false;
    }

    fn currentSessionOrDefault(self: *App) ![]const u8 {
        self.sanitizeCurrentSessionSelection();

        if (self.current_session_key) |current| return current;
        if (self.chat_sessions.items.len > 0) {
            const fallback = self.chat_sessions.items[0].key;
            try self.setCurrentSessionKey(fallback);
            return fallback;
        }
        const fallback = "main";
        try self.ensureSessionExists(fallback, fallback);
        return fallback;
    }

    fn activeMessages(self: *App) []const ChatMessage {
        self.sanitizeCurrentSessionSelection();

        if (self.current_session_key) |key| {
            if (self.findSessionMessageState(key)) |state| {
                return state.messages.items;
            }
        }
        if (self.chat_sessions.items.len > 0) {
            if (self.findSessionMessageState(self.chat_sessions.items[0].key)) |state| {
                return state.messages.items;
            }
        }
        return &[_]ChatMessage{};
    }

    fn setMessageFailed(self: *App, message_id: []const u8) !void {
        for (self.session_messages.items) |*state| {
            for (state.messages.items) |*msg| {
                if (std.mem.eql(u8, msg.id, message_id)) {
                    msg.local_state = .failed;
                    return;
                }
            }
        }
    }

    fn setMessageState(self: *App, message_id: []const u8, state: ?ChatMessageState) !void {
        for (self.session_messages.items) |*session_state| {
            for (session_state.messages.items) |*msg| {
                if (std.mem.eql(u8, msg.id, message_id)) {
                    msg.local_state = state;
                    return;
                }
            }
        }
    }

    fn handleIncomingMessage(self: *App, msg: []const u8) !void {
        const parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, msg, .{});
        defer parsed.deinit();
        if (parsed.value != .object) return;
        const root = parsed.value.object;

        const mt = protocol_messages.parseMessageType(msg) orelse return;
        switch (mt) {
            .chat_receive => {
                const payload = if (root.get("payload")) |payload| switch (payload) {
                    .object => payload.object,
                    else => root,
                } else root;

                const request_id = if (root.get("request_id")) |value| switch (value) {
                    .string => value.string,
                    else => null,
                } else if (payload.get("request_id")) |value| switch (value) {
                    .string => value.string,
                    else => null,
                } else if (root.get("id")) |value| switch (value) {
                    .string => value.string,
                    else => null,
                } else if (payload.get("id")) |value| switch (value) {
                    .string => value.string,
                    else => null,
                } else null;
                const session_key = if (payload.get("session_key")) |value| switch (value) {
                    .string => value.string,
                    else => null,
                } else if (payload.get("sessionKey")) |value| switch (value) {
                    .string => value.string,
                    else => null,
                } else if (root.get("sessionKey")) |value| switch (value) {
                    .string => value.string,
                    else => null,
                } else null;
                if (session_key) |sk| {
                    self.ensureSessionInList(sk, sk) catch {};
                }
                const role = if (payload.get("role")) |value| switch (value) {
                    .string => value.string,
                    else => "assistant",
                } else "assistant";
                const timestamp = if (root.get("timestamp")) |value| switch (value) {
                    .integer => value.integer,
                    else => std.time.milliTimestamp(),
                } else if (payload.get("timestamp")) |value| switch (value) {
                    .integer => value.integer,
                    else => std.time.milliTimestamp(),
                } else std.time.milliTimestamp();
                const content = if (payload.get("content")) |value| switch (value) {
                    .string => value.string,
                    else => "",
                } else "";
                const content_delta = if (payload.get("content_delta")) |value| switch (value) {
                    .string => value.string,
                    else => null,
                } else null;
                const final = if (payload.get("final")) |value| switch (value) {
                    .bool => value.bool,
                    else => true,
                } else true;
                if (request_id) |req_id| {
                    if (self.pending_send_request_id) |pending| {
                        if (std.mem.eql(u8, pending, req_id)) {
                            if (self.pending_send_message_id) |msg_id| {
                                self.setMessageState(msg_id, null) catch {};
                            }
                            if (session_key) |sk| {
                                if (self.current_session_key) |current| {
                                    if (!std.mem.eql(u8, current, sk)) {
                                        self.setCurrentSessionKey(sk) catch {};
                                    }
                                } else {
                                    self.setCurrentSessionKey(sk) catch {};
                                }
                            }
                        }
                    }
                }

                if (content_delta) |delta| {
                    try self.appendOrUpdateStreamingMessage(request_id, session_key, delta, false, timestamp);
                    return;
                }
                if (content.len > 0) {
                    if (request_id != null) {
                        const is_final = final;
                        try self.appendOrUpdateStreamingMessage(request_id, session_key, content, is_final, timestamp);
                    } else {
                        try self.appendMessageWithState(role, content, null, null);
                    }
                }
            },
            .chat_ack => {
                const request_id = if (root.get("request_id")) |value| switch (value) {
                    .string => value.string,
                    else => null,
                } else if (root.get("id")) |value| switch (value) {
                    .string => value.string,
                    else => null,
                } else null;

                if (request_id) |rid| {
                    if (self.pending_send_request_id) |pending| {
                        if (std.mem.eql(u8, pending, rid)) {
                            if (self.pending_send_message_id) |message_id| {
                                self.setMessageState(message_id, null) catch {};
                            }
                            self.clearPendingSend();
                        }
                    }
                }
            },
            .error_response => {
                const payload = if (root.get("payload")) |payload| switch (payload) {
                    .object => payload.object,
                    else => root,
                } else root;
                const err_message = if (payload.get("message")) |value| switch (value) {
                    .string => value.string,
                    else => "Unknown error",
                } else "Unknown error";
                try self.appendMessage("system", err_message, null);
            },
            else => {
                if (self.connection_state == .connected) {
                    return;
                }
                try self.appendMessage("system", "Unhandled message", null);
            },
        }
    }

    fn appendOrUpdateStreamingMessage(
        self: *App,
        request_id: ?[]const u8,
        session_key_opt: ?[]const u8,
        chunk: []const u8,
        final: bool,
        timestamp: i64,
    ) !void {
        const target_session = if (request_id) |request| blk: {
            if (self.pending_send_request_id) |pending| {
                if (std.mem.eql(u8, pending, request)) {
                    if (self.pending_send_session_key) |key| break :blk key;
                }
            }
            break :blk session_key_opt;
        } else session_key_opt;

        const target = target_session orelse try self.currentSessionOrDefault();

        if (request_id) |request| {
            const state = try self.getSessionMessageState(target);

            if (state.streaming_request_id) |existing_request| {
                if (!std.mem.eql(u8, existing_request, request)) {
                    self.clearSessionStreamingState(state);
                }
            }

            if (state.streaming_request_id == null) {
                try self.setSessionStreamingRequest(state, request);
            }

            const stream_id = try self.makeStreamingMessageId(request);
            defer self.allocator.free(stream_id);

            if (self.findMessageIndex(target, stream_id)) |idx| {
                if (final) {
                    try self.setMessageContentByIndex(target, idx, chunk);
                } else {
                    try self.appendToMessage(target, idx, chunk);
                }
                if (state.messages.items.len > idx) {
                    state.messages.items[idx].timestamp = timestamp;
                }
            } else {
                _ = try self.appendMessageWithIdForSession(target, "assistant", chunk, null, stream_id);
            }

            if (self.pending_send_request_id) |pending| {
                if (std.mem.eql(u8, pending, request)) {
                    if (self.pending_send_message_id) |msg_id| {
                        self.setMessageState(msg_id, null) catch {};
                    }
                    if (final) {
                        self.clearSessionStreamingState(state);
                        self.clearPendingSend();
                    }
                }
            }

            if (final) {
                self.clearSessionStreamingState(state);
            }
            return;
        }

        try self.appendMessageForSession(target, "assistant", chunk, null);
    }

    fn findSessionMessageState(self: *App, key: []const u8) ?*SessionMessageState {
        for (self.session_messages.items) |*state| {
            if (std.mem.eql(u8, state.key, key)) return state;
        }
        return null;
    }

    fn getSessionMessageState(self: *App, key: []const u8) !*SessionMessageState {
        if (self.findSessionMessageState(key)) |state| return state;
        const key_copy = try self.allocator.dupe(u8, key);
        try self.session_messages.append(self.allocator, .{
            .key = key_copy,
            .messages = .empty,
        });
        return &self.session_messages.items[self.session_messages.items.len - 1];
    }

    fn makeStreamingMessageId(self: *App, request_id: []const u8) ![]const u8 {
        return std.fmt.allocPrint(self.allocator, "stream:{s}", .{request_id});
    }

    fn setSessionStreamingRequest(self: *App, state: *SessionMessageState, request_id: []const u8) !void {
        if (state.streaming_request_id) |existing_request| {
            if (std.mem.eql(u8, existing_request, request_id)) {
                return;
            }
            self.allocator.free(existing_request);
        }
        state.streaming_request_id = try self.allocator.dupe(u8, request_id);
    }

    fn clearSessionStreamingState(self: *App, state: *SessionMessageState) void {
        if (state.streaming_request_id) |existing_request| {
            self.allocator.free(existing_request);
            state.streaming_request_id = null;
        }
    }

    fn setMessageContentByIndex(self: *App, session_key: []const u8, index: usize, content: []const u8) !void {
        const state = try self.getSessionMessageState(session_key);
        if (index >= state.messages.items.len) return;
        const msg = &state.messages.items[index];
        self.allocator.free(msg.content);
        msg.content = try self.allocator.dupe(u8, content);
    }

    fn appendToMessage(self: *App, session_key: []const u8, index: usize, content: []const u8) !void {
        const state = try self.getSessionMessageState(session_key);
        var msg = &state.messages.items[index];
        const old_content = msg.content;
        const new_len = old_content.len + content.len;
        var combined = try self.allocator.alloc(u8, new_len);
        @memcpy(combined[0..old_content.len], old_content);
        @memcpy(combined[old_content.len..new_len], content);
        msg.content = combined;
        self.allocator.free(old_content);
    }

    fn findMessageIndex(self: *App, session_key: []const u8, message_id: []const u8) ?usize {
        const state = self.findSessionMessageState(session_key) orelse return null;
        for (state.messages.items, 0..) |*msg, idx| {
            if (std.mem.eql(u8, msg.id, message_id)) return idx;
        }
        return null;
    }

    fn appendMessage(self: *App, role: []const u8, content: []const u8, local_state: ?ChatMessageState) !void {
        const session_key = try self.currentSessionOrDefault();
        const id = try self.appendMessageWithIdForSession(session_key, role, content, local_state, "");
        self.allocator.free(id);
    }

    fn appendMessageForSession(
        self: *App,
        session_key: []const u8,
        role: []const u8,
        content: []const u8,
        local_state: ?ChatMessageState,
    ) !void {
        const id = try self.appendMessageWithIdForSession(session_key, role, content, local_state, "");
        self.allocator.free(id);
    }

    fn appendMessageWithId(
        self: *App,
        role: []const u8,
        content: []const u8,
        local_state: ?ChatMessageState,
        id_override: []const u8,
    ) ![]const u8 {
        const session_key = try self.currentSessionOrDefault();
        return self.appendMessageWithIdForSession(session_key, role, content, local_state, id_override);
    }

    fn appendMessageWithIdForSession(
        self: *App,
        session_key: []const u8,
        role: []const u8,
        content: []const u8,
        local_state: ?ChatMessageState,
        id_override: []const u8,
    ) ![]const u8 {
        const id = if (id_override.len > 0) try self.allocator.dupe(u8, id_override) else try self.nextMessageId("msg");
        errdefer self.allocator.free(id);

        const state = try self.getSessionMessageState(session_key);
        try state.messages.append(self.allocator, .{
            .id = try self.allocator.dupe(u8, id),
            .role = try self.allocator.dupe(u8, role),
            .content = try self.allocator.dupe(u8, content),
            .timestamp = std.time.milliTimestamp(),
            .attachments = null,
            .local_state = local_state,
        });

        if (state.messages.items.len > 500) {
            var oldest = state.messages.orderedRemove(0);
            if (state.streaming_request_id) |stream_request_id| {
                if (std.mem.startsWith(u8, oldest.id, "stream:")) {
                    const oldest_request_id = oldest.id["stream:".len..];
                    if (std.mem.eql(u8, oldest_request_id, stream_request_id)) {
                        self.allocator.free(stream_request_id);
                        state.streaming_request_id = null;
                    }
                }
            }
            if (self.pending_send_message_id) |pending_message_id| {
                if (std.mem.eql(u8, pending_message_id, oldest.id)) {
                    self.allocator.free(pending_message_id);
                    self.pending_send_message_id = null;
                }
            }
            self.freeMessage(&oldest);
        }

        return id;
    }

    fn appendMessageWithState(
        self: *App,
        role: []const u8,
        content: []const u8,
        local_state: ?ChatMessageState,
        id_override: ?[]const u8,
    ) !void {
        if (id_override) |id| {
            const id_out = try self.appendMessageWithId(role, content, local_state, id);
            self.allocator.free(id_out);
            return;
        }
        return self.appendMessage(role, content, local_state);
    }

    fn freeMessage(self: *App, msg: *ChatMessage) void {
        self.allocator.free(msg.id);
        self.allocator.free(msg.role);
        self.allocator.free(msg.content);

        if (msg.attachments) |attachments| {
            for (attachments) |attachment| {
                self.allocator.free(attachment.kind);
                self.allocator.free(attachment.url);
                if (attachment.name) |name| self.allocator.free(name);
            }
            self.allocator.free(attachments);
        }
    }

    fn clearAllMessages(self: *App) void {
        for (self.session_messages.items) |*state| {
            self.clearSessionStreamingState(state);
            for (state.messages.items) |*msg| {
                self.freeMessage(msg);
            }
            state.messages.clearRetainingCapacity();
        }
    }

    fn clearSessions(self: *App) void {
        self.clearAllMessages();

        if (self.current_session_key) |current_session| {
            self.allocator.free(current_session);
            self.current_session_key = null;
        }
        for (self.chat_sessions.items) |session| {
            self.allocator.free(session.key);
            if (session.display_name) |name| self.allocator.free(name);
        }
        self.chat_sessions.clearRetainingCapacity();

        for (self.session_messages.items) |*state| {
            state.messages.deinit(self.allocator);
            self.allocator.free(state.key);
        }
        self.session_messages.clearRetainingCapacity();
    }

    fn addSession(self: *App, key: []const u8, display_name: []const u8) !void {
        const key_copy = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(key_copy);
        const name_copy = try self.allocator.dupe(u8, display_name);
        errdefer self.allocator.free(name_copy);

        if (self.shouldLogDebug(1)) {
            std.log.debug("addSession: key={s} current={}", .{ key, self.chat_sessions.items.len });
        }
        try self.chat_sessions.append(self.allocator, .{
            .key = key_copy,
            .display_name = name_copy,
        });
    }

    fn ensureSessionExists(self: *App, key: []const u8, display_name: []const u8) !void {
        try self.ensureSessionInList(key, display_name);
        try self.setCurrentSessionKey(key);
    }

    fn ensureSessionInList(self: *App, key: []const u8, display_name: []const u8) !void {
        for (self.chat_sessions.items) |session| {
            if (std.mem.eql(u8, session.key, key)) {
                if (self.shouldLogDebug(120)) {
                    std.log.debug("ensureSessionInList: key exists {s}", .{key});
                }
                return;
            }
        }
        if (self.shouldLogDebug(120)) {
            std.log.debug("ensureSessionInList: adding new key {s}", .{key});
        }
        try self.addSession(key, display_name);
    }

    fn sanitizeCurrentSessionSelection(self: *App) void {
        if (self.current_session_key) |current| {
            for (self.chat_sessions.items) |session| {
                if (std.mem.eql(u8, current, session.key)) {
                    return;
                }
            }

            self.allocator.free(current);
            self.current_session_key = null;
        }

        if (self.current_session_key == null) {
            if (self.chat_sessions.items.len > 0) {
                self.setCurrentSessionKey(self.chat_sessions.items[0].key) catch {};
            }
        }
    }

    fn setCurrentSessionByKey(self: *App, session_key: []const u8) bool {
        for (self.chat_sessions.items) |session| {
            if (std.mem.eql(u8, session.key, session_key)) {
                self.setCurrentSessionKey(session.key) catch {};
                return true;
            }
        }
        return false;
    }

    fn setCurrentSessionByIndex(self: *App, index: usize) bool {
        if (index >= self.chat_sessions.items.len) return false;
        self.setCurrentSessionKey(self.chat_sessions.items[index].key) catch {};
        return true;
    }

    fn setCurrentSessionKey(self: *App, key: []const u8) !void {
        if (key.len == 0) return;
        const key_copy = try self.allocator.dupe(u8, key);
        self.setCurrentSessionKeyOwned(key_copy);
    }

    fn setCurrentSessionKeyOwned(self: *App, key_copy: []const u8) void {
        if (self.current_session_key) |current| {
            self.allocator.free(current);
        }
        self.current_session_key = key_copy;
    }

    fn handleChatPanelAction(self: *App, action: zui.ChatPanelAction) void {
        if (action.send_message) |message| {
            std.log.info("[GUI] handleChatPanelAction send_message len={d}", .{message.len});
            defer self.allocator.free(message);
            self.sendChatMessageText(message) catch {};
        }

        if (action.select_session) |session_key| {
            defer self.allocator.free(session_key);
            _ = self.setCurrentSessionByKey(session_key);
        }

        if (action.select_session_id) |sid| {
            defer self.allocator.free(sid);
            if (std.fmt.parseInt(usize, sid, 10)) |index| {
                if (self.setCurrentSessionByIndex(index)) return;
            } else |_| {
                _ = self.setCurrentSessionByKey(sid);
            }
        }

        if (action.new_chat_session_key) |new_key| {
            defer self.allocator.free(new_key);

            if (self.setCurrentSessionByKey(new_key)) {
                return;
            }
            self.addSession(new_key, new_key) catch {};
            _ = self.setCurrentSessionByKey(new_key);
        }
    }

    fn setConnectionState(self: *App, state: ConnectionState, text: []const u8) void {
        self.connection_state = state;
        const copy = self.allocator.dupe(u8, text) catch return;
        self.allocator.free(self.status_text);
        self.status_text = copy;
    }

    // Drawing helpers

    fn drawSurfacePanel(self: *App, rect: Rect) void {
        const fill = Paint{ .solid = self.theme.colors.surface };
        self.drawPaintRect(rect, fill);
        self.drawRect(rect, self.theme.colors.border);
    }

    fn drawPaintRect(self: *App, rect: Rect, paint: Paint) void {
        switch (paint) {
            .solid => |color| self.drawFilledRect(rect, color),
            .gradient4 => |g| {
                self.ui_commands.pushRectGradient(
                    .{ .min = rect.min, .max = rect.max },
                    .{
                        .tl = g.tl,
                        .tr = g.tr,
                        .bl = g.bl,
                        .br = g.br,
                    },
                );
            },
            .image => {
                self.drawFilledRect(rect, self.theme.colors.surface);
            },
        }
    }

    fn drawFilledRect(self: *App, rect: Rect, color: [4]f32) void {
        self.ui_commands.pushRect(
            .{ .min = rect.min, .max = rect.max },
            .{ .fill = color },
        );
    }

    fn drawRect(self: *App, rect: Rect, color: [4]f32) void {
        self.ui_commands.pushRect(
            .{ .min = rect.min, .max = rect.max },
            .{ .stroke = color },
        );
    }

    fn drawLabel(self: *App, x: f32, y: f32, text: []const u8, color: [4]f32) void {
        self.drawText(x, y, text, color);
    }

    fn drawCenteredText(self: *App, rect: Rect, text: []const u8, color: [4]f32) void {
        const text_w = @as(f32, @floatFromInt(text.len)) * 8.0;
        const x = rect.min[0] + @max(0.0, (rect.width() - text_w) * 0.5);
        const y = rect.min[1] + @max(0.0, (rect.height() - 12.0) * 0.5);
        self.drawText(x, y, text, color);
    }

    fn drawText(self: *App, x: f32, y: f32, text: []const u8, color: [4]f32) void {
        self.ui_commands.pushText(text, .{ x, y }, color, .body, @intFromFloat(14.0 * self.ui_scale));
    }

    fn measureText(self: *App, text: []const u8) f32 {
        // Tuned to match actual text rendering (was 7.0, caused offset)
        return @as(f32, @floatFromInt(text.len)) * 6.5 * self.ui_scale;
    }

    fn drawTextTrimmed(self: *App, x: f32, y: f32, max_w: f32, text: []const u8, color: [4]f32) void {
        // Use binary search to find how many chars fit
        if (self.measureText(text) <= max_w) {
            self.drawText(x, y, text, color);
            return;
        }

        // Binary search for max chars that fit
        var low: usize = 0;
        var high: usize = text.len;
        while (low < high) {
            const mid = low + (high - low + 1) / 2;
            const w = self.measureText(text[0..mid]);
            if (w <= max_w - self.measureText("...")) {
                low = mid;
            } else {
                high = mid - 1;
            }
        }

        if (low <= 3) {
            self.drawText(x, y, "...", color);
            return;
        }

        var tmp: [1024]u8 = undefined;
        const copy_len = @min(low, @min(text.len, tmp.len - 3));
        if (copy_len > 0) @memcpy(tmp[0..copy_len], text[0..copy_len]);
        tmp[copy_len] = '.';
        tmp[copy_len + 1] = '.';
        tmp[copy_len + 2] = '.';
        self.drawText(x, y, tmp[0 .. copy_len + 3], color);
    }
};

// Image loading stubs required by ziggy-ui
pub export fn zsc_load_icon_rgba_from_memory(data: [*c]const u8, len: c_int, width: [*c]c_int, height: [*c]c_int) [*c]u8 {
    _ = data;
    _ = len;
    if (width != null) width[0] = 0;
    if (height != null) height[0] = 0;
    return null;
}

pub export fn zsc_free_icon(pixels: ?*anyopaque) void {
    _ = pixels;
}

pub export fn zsc_load_image_rgba_from_memory(data: [*c]const u8, len: c_int, width: [*c]c_int, height: [*c]c_int) [*c]u8 {
    _ = data;
    _ = len;
    if (width != null) width[0] = 0;
    if (height != null) height[0] = 0;
    return null;
}

pub export fn zsc_free_image(pixels: ?*anyopaque) void {
    _ = pixels;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{ .thread_safe = true }){};
    defer _ = gpa.deinit();

    var app = try App.init(gpa.allocator());
    defer app.deinit();

    if (app.config.auto_connect_on_launch) {
        app.tryConnect(&app.manager) catch {};
    }

    try app.run();
}
