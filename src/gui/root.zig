const std = @import("std");
const zui = @import("ziggy-ui");
const ws_client_mod = @import("websocket_client.zig");
const config_mod = @import("client-config");
const control_plane = @import("control_plane");
const workspace_types = control_plane.workspace_types;
const panels_bridge = @import("panels_bridge.zig");

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
const form_layout = zui.ui.layout.form_layout;
const text_buffer = zui.ui.text_buffer;

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
const MAX_DEBUG_EVENTS: usize = 500;
const FSRPC_DEFAULT_TIMEOUT_MS: u32 = 15_000;
const FSRPC_CHAT_WRITE_TIMEOUT_MS: u32 = 180_000;
const FSRPC_CLUNK_TIMEOUT_MS: u32 = 1_000;
const CONTROL_SESSION_ATTACH_TIMEOUT_MS: i64 = 45_000;

const ChatAttachment = zui.protocol.types.ChatAttachment;
const ChatMessage = zui.protocol.types.ChatMessage;
const ChatMessageState = zui.protocol.types.LocalChatMessageState;
const ChatSession = zui.protocol.types.Session;

const ChatPanel = zui.ChatPanel(ChatMessage, ChatSession);

const PanelLayoutMetrics = form_layout.Metrics;

const DockTabMetrics = struct {
    pad: f32,
    height: f32,
    min_width: f32,
    max_width_ratio: f32,
};

const FormScrollTarget = enum {
    none,
    settings,
    projects,
};

const FsrpcEnvelope = struct {
    raw: []u8,
    parsed: std.json.Parsed(std.json.Value),

    fn deinit(self: *FsrpcEnvelope, allocator: std.mem.Allocator) void {
        self.parsed.deinit();
        allocator.free(self.raw);
        self.* = undefined;
    }
};

const FilesystemEntry = struct {
    name: []u8,
    path: []u8,
    is_dir: bool,

    fn deinit(self: *FilesystemEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.path);
        self.* = undefined;
    }
};

const JobStatusInfo = struct {
    state: []u8,
    error_text: ?[]u8 = null,
    correlation_id: ?[]u8 = null,

    fn deinit(self: *JobStatusInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.state);
        if (self.error_text) |value| allocator.free(value);
        if (self.correlation_id) |value| allocator.free(value);
        self.* = undefined;
    }
};

const AuthStatusSnapshot = struct {
    admin_token: []u8,
    user_token: []u8,
    path: ?[]u8 = null,

    fn deinit(self: *AuthStatusSnapshot, allocator: std.mem.Allocator) void {
        allocator.free(self.admin_token);
        allocator.free(self.user_token);
        if (self.path) |value| allocator.free(value);
        self.* = undefined;
    }
};

fn encodeDataB64(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    const encoder = std.base64.standard.Encoder;
    const encoded_len = encoder.calcSize(data.len);
    const out = try allocator.alloc(u8, encoded_len);
    _ = encoder.encode(out, data);
    return out;
}

fn jsonEscape(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var out = std.ArrayListUnmanaged(u8){};
    defer out.deinit(allocator);

    for (input) |char| {
        switch (char) {
            '\\' => try out.appendSlice(allocator, "\\\\"),
            '"' => try out.appendSlice(allocator, "\\\""),
            '\n' => try out.appendSlice(allocator, "\\n"),
            '\r' => try out.appendSlice(allocator, "\\r"),
            '\t' => try out.appendSlice(allocator, "\\t"),
            else => {
                if (char < 0x20) {
                    try out.writer(allocator).print("\\u00{x:0>2}", .{char});
                } else {
                    try out.append(allocator, char);
                }
            },
        }
    }

    return out.toOwnedSlice(allocator);
}

fn maskTokenForDisplay(allocator: std.mem.Allocator, token: []const u8) ![]u8 {
    if (token.len == 0) return allocator.dupe(u8, "(empty)");
    if (token.len <= 8) return allocator.dupe(u8, "****");
    return std.fmt.allocPrint(
        allocator,
        "{s}...{s}",
        .{ token[0..4], token[token.len - 4 ..] },
    );
}

const SettingsFocusField = enum {
    none,
    server_url,
    project_id,
    project_token,
    project_create_name,
    project_create_vision,
    project_operator_token,
    default_session,
    default_agent,
    ui_theme,
    ui_profile,
    ui_theme_pack,
};

fn isSettingsPanelFocusField(field: SettingsFocusField) bool {
    return switch (field) {
        .server_url,
        .default_session,
        .default_agent,
        .ui_theme,
        .ui_profile,
        .ui_theme_pack,
        => true,
        else => false,
    };
}

fn isProjectPanelFocusField(field: SettingsFocusField) bool {
    return switch (field) {
        .project_id,
        .project_token,
        .project_create_name,
        .project_create_vision,
        .project_operator_token,
        => true,
        else => false,
    };
}

fn isUserScopedAgentId(agent_id: []const u8) bool {
    return std.mem.eql(u8, agent_id, "user") or std.mem.eql(u8, agent_id, "user-isolated");
}

const SettingsPanel = struct {
    server_url: std.ArrayList(u8) = .empty,
    project_id: std.ArrayList(u8) = .empty,
    project_token: std.ArrayList(u8) = .empty,
    project_create_name: std.ArrayList(u8) = .empty,
    project_create_vision: std.ArrayList(u8) = .empty,
    project_operator_token: std.ArrayList(u8) = .empty,
    default_session: std.ArrayList(u8) = .empty,
    default_agent: std.ArrayList(u8) = .empty,
    ui_theme: std.ArrayList(u8) = .empty,
    ui_profile: std.ArrayList(u8) = .empty,
    ui_theme_pack: std.ArrayList(u8) = .empty,
    watch_theme_pack: bool = false,
    auto_connect_on_launch: bool = true,
    focused_field: SettingsFocusField = .server_url,
    // Vertical scroll offsets per form panel
    settings_scroll_y: f32 = 0.0,
    projects_scroll_y: f32 = 0.0,

    pub fn init(allocator: std.mem.Allocator) SettingsPanel {
        var panel = SettingsPanel{};
        panel.server_url.appendSlice(allocator, "ws://127.0.0.1:18790") catch {};
        panel.project_id.appendSlice(allocator, "") catch {};
        panel.project_token.appendSlice(allocator, "") catch {};
        panel.project_create_name.appendSlice(allocator, "") catch {};
        panel.project_create_vision.appendSlice(allocator, "") catch {};
        panel.project_operator_token.appendSlice(allocator, "") catch {};
        panel.default_session.appendSlice(allocator, "main") catch {};
        panel.default_agent.appendSlice(allocator, "") catch {};
        return panel;
    }

    pub fn deinit(self: *SettingsPanel, allocator: std.mem.Allocator) void {
        self.server_url.deinit(allocator);
        self.project_id.deinit(allocator);
        self.project_token.deinit(allocator);
        self.project_create_name.deinit(allocator);
        self.project_create_vision.deinit(allocator);
        self.project_operator_token.deinit(allocator);
        self.default_session.deinit(allocator);
        self.default_agent.deinit(allocator);
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

const DebugEventEntry = struct {
    id: u64,
    timestamp_ms: i64,
    category: []u8,
    correlation_id: ?[]u8 = null,
    payload_json: []u8,
    payload_lines: std.ArrayList(DebugPayloadLine) = .empty,

    fn deinit(self: *DebugEventEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.category);
        if (self.correlation_id) |value| allocator.free(value);
        allocator.free(self.payload_json);
        self.payload_lines.deinit(allocator);
    }
};

const DebugPayloadLine = struct {
    start: usize,
    end: usize,
    indent_spaces: usize,
    opens_block: bool = false,
    matching_close_index: ?u32 = null,
};

const DebugFoldKey = struct {
    event_id: u64,
    line_index: u32,
};

const JsonTokenKind = enum {
    key,
    string,
    number,
    keyword,
    punctuation,
    plain,
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
    pending_send_job_id: ?[]u8 = null,
    pending_send_correlation_id: ?[]u8 = null,
    pending_send_resume_notified: bool = false,
    pending_send_last_resume_attempt_ms: i64 = 0,
    awaiting_reply: bool = false,
    debug_stream_enabled: bool = false,
    debug_stream_pending: bool = false,
    pending_debug_request_id: ?[]u8 = null,
    debug_panel_id: ?workspace.PanelId = null,
    debug_events: std.ArrayList(DebugEventEntry) = .empty,
    debug_next_event_id: u64 = 1,
    debug_folded_blocks: std.AutoHashMap(DebugFoldKey, void),
    debug_scroll_y: f32 = 0.0,
    debug_selected_index: ?usize = null,
    debug_output_rect: Rect = Rect.fromXYWH(0, 0, 0, 0),
    debug_scrollbar_dragging: bool = false,
    debug_scrollbar_drag_start_y: f32 = 0.0,
    debug_scrollbar_drag_start_scroll_y: f32 = 0.0,
    form_scroll_drag_target: FormScrollTarget = .none,
    form_scroll_drag_start_y: f32 = 0.0,
    form_scroll_drag_start_scroll_y: f32 = 0.0,
    ui_commands: zui.ui.render.command_list.CommandList,

    projects: std.ArrayListUnmanaged(workspace_types.ProjectSummary) = .{},
    nodes: std.ArrayListUnmanaged(workspace_types.NodeInfo) = .{},
    workspace_state: ?workspace_types.WorkspaceStatus = null,
    workspace_last_error: ?[]u8 = null,
    workspace_last_refresh_ms: i64 = 0,
    project_panel_id: ?workspace.PanelId = null,
    project_selector_open: bool = false,
    filesystem_panel_id: ?workspace.PanelId = null,
    filesystem_path: std.ArrayList(u8) = .empty,
    filesystem_entries: std.ArrayListUnmanaged(FilesystemEntry) = .{},
    filesystem_preview_path: ?[]u8 = null,
    filesystem_preview_text: ?[]u8 = null,
    filesystem_error: ?[]u8 = null,
    fsrpc_last_remote_error: ?[]u8 = null,

    ws_client: ?ws_client_mod.WebSocketClient = null,

    connection_state: ConnectionState = .disconnected,
    status_text: []u8,

    theme: *const zui.Theme,
    ui_scale: f32 = 1.0,
    metrics_context: ui_draw_context.DrawContext,
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
    next_fsrpc_tag: u32 = 1,
    next_fsrpc_fid: u32 = 2,
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
    windows_menu_open_window_id: ?u32 = null,
    workspace_snapshot: ?workspace.WorkspaceSnapshot = null,
    workspace_snapshot_stale: bool = false,
    workspace_snapshot_restore_attempted: bool = false,

    pub fn init(allocator: std.mem.Allocator) !App {
        panels_bridge.assertAvailable();
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
        zui.ui.theme.setMode(.light);

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
        settings_panel.project_id.clearRetainingCapacity();
        if (config.selectedProject()) |value| {
            settings_panel.project_id.appendSlice(allocator, value) catch {};
            if (config.getProjectToken(value)) |project_token| {
                settings_panel.project_token.clearRetainingCapacity();
                settings_panel.project_token.appendSlice(allocator, project_token) catch {};
            }
        }
        if (config.getRoleToken(.admin).len > 0) {
            settings_panel.project_operator_token.clearRetainingCapacity();
            settings_panel.project_operator_token.appendSlice(allocator, config.getRoleToken(.admin)) catch {};
        }
        settings_panel.default_session.clearRetainingCapacity();
        if (config.default_session) |value| {
            settings_panel.default_session.appendSlice(allocator, value) catch {};
        } else {
            settings_panel.default_session.appendSlice(allocator, "main") catch {};
        }
        settings_panel.default_agent.clearRetainingCapacity();
        if (config.selectedAgent()) |value| {
            settings_panel.default_agent.appendSlice(allocator, value) catch {};
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
            .metrics_context = undefined,
            .config = config,
            .ui_commands = zui.ui.render.command_list.CommandList.init(allocator),
            .frame_clock = zapp.frame_clock.FrameClock.init(60),
            .debug_folded_blocks = std.AutoHashMap(DebugFoldKey, void).init(allocator),
            .manager = undefined,
        };
        app.applyThemeFromSettings();
        app.metrics_context = ui_draw_context.DrawContext.init(
            allocator,
            .{ .direct = .{} },
            zui.ui.theme.activeTheme(),
            UiRect.fromMinSize(.{ 0.0, 0.0 }, .{ 1.0, 1.0 }),
        );
        errdefer app.metrics_context.deinit();

        app.client_context = try client_state.ClientContext.init(allocator);
        errdefer app.client_context.deinit();
        app.agent_registry = client_agents.AgentRegistry.initEmpty(allocator);
        errdefer app.agent_registry.deinit(allocator);

        app.manager = panel_manager.PanelManager.init(allocator, ws, &app.next_panel_id);
        app.bindNextPanelId(&app.manager);
        errdefer app.manager.deinit();
        _ = app.ensureProjectPanel(&app.manager) catch {};
        app.focusSettingsPanel(&app.manager);

        app.captureWorkspaceSnapshot(&app.manager);
        try app.filesystem_path.appendSlice(allocator, "/");

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
        workspace_types.deinitProjectList(self.allocator, &self.projects);
        workspace_types.deinitNodeList(self.allocator, &self.nodes);
        if (self.workspace_state) |*status| {
            status.deinit(self.allocator);
            self.workspace_state = null;
        }
        if (self.workspace_last_error) |value| {
            self.allocator.free(value);
            self.workspace_last_error = null;
        }
        self.clearFsrpcRemoteError();
        self.clearDebugEvents();
        self.debug_events.deinit(self.allocator);
        self.debug_folded_blocks.deinit();
        self.invalidateWorkspaceSnapshot();
        if (self.pending_send_request_id) |request_id| self.allocator.free(request_id);
        if (self.pending_send_message_id) |message_id| self.allocator.free(message_id);
        if (self.pending_send_session_key) |session_key| self.allocator.free(session_key);
        if (self.pending_send_job_id) |job_id| self.allocator.free(job_id);
        if (self.pending_send_correlation_id) |corr| self.allocator.free(corr);
        self.clearFilesystemData();
        self.filesystem_path.deinit(self.allocator);

        zui.ChatView(ChatMessage).deinit(&self.chat_panel_state.view, self.allocator);

        self.settings_panel.deinit(self.allocator);
        self.chat_input.deinit(self.allocator);
        self.client_context.deinit();
        self.agent_registry.deinit(self.allocator);

        self.metrics_context.deinit();
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
            if (self.pending_send_job_id != null and self.ws_client != null) {
                _ = self.tryResumePendingSendJob() catch {};
            }
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
                if (self.windows_menu_open_window_id != null and self.windows_menu_open_window_id.? == w.id) {
                    self.windows_menu_open_window_id = null;
                }
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
                .mouse_wheel => |mw| {
                    if (self.debug_panel_id) |panel_id| {
                        if (self.isPanelFocused(manager, panel_id)) {
                            self.debug_scroll_y -= mw.delta[1] * 40.0 * self.ui_scale;
                        }
                    }
                    if (self.focusedFormScrollY(manager)) |scroll_y| {
                        scroll_y.* -= mw.delta[1] * 40.0 * self.ui_scale;
                    }
                },
                else => {},
            }
        }
        // Only clear active form-scroll drag while processing the main window.
        // Secondary windows can report mouse-up while the drag is still active
        // in the source window.
        if (!self.mouse_down and ui_window.id == self.main_window_id) {
            self.form_scroll_drag_target = .none;
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
        if (manager.workspace.panels.items.len > 4096 or manager.workspace.dock_layout.nodes.items.len > 16384) {
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
                if (self.debug_frame_counter >= self.workspace_snapshot_restore_cooldown_until and
                    self.restoreWorkspaceFromSnapshot(manager))
                {
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

        const tab_metrics = self.dockTabMetrics();
        if (tab_metrics.height <= 0.0) return;

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

            const group_width = group.rect.max[0] - group.rect.min[0];
            var tab_x = group.rect.min[0] + tab_metrics.pad;
            for (tabs_node.tabs.items, 0..) |panel_id, idx| {
                const panel = self.findPanelById(manager, panel_id) orelse continue;
                const tab_width = self.dockTabWidth(panel.title, group_width, tab_metrics);
                const tab_rect = UiRect.fromMinSize(
                    .{ tab_x, group.rect.min[1] },
                    .{ tab_width, tab_metrics.height },
                );
                if (tab_rect.min[0] + tab_width > group.rect.max[0] - tab_metrics.pad) break;
                out_tabs.append(.{
                    .panel_id = panel_id,
                    .node_id = group.node_id,
                    .tab_index = idx,
                    .rect = tab_rect,
                });
                tab_x = tab_rect.max[0] + tab_metrics.pad;
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
            if (!client.isAlive()) {
                const has_pending_send = self.pending_send_message_id != null;
                self.debug_stream_pending = false;
                self.clearPendingDebugRequest();

                client.deinit();
                self.ws_client = null;
                self.setConnectionState(.error_state, "Connection lost. Please reconnect.");
                if (has_pending_send) {
                    if (!self.pending_send_resume_notified) {
                        if (self.pending_send_job_id) |job_id| {
                            const msg = try std.fmt.allocPrint(
                                self.allocator,
                                "Connection lost while waiting for job {s}. Reconnect to resume.",
                                .{job_id},
                            );
                            defer self.allocator.free(msg);
                            try self.appendMessage("system", msg, null);
                        } else {
                            try self.appendMessage("system", "Connection lost while waiting for assistant response. Reconnect to resume.", null);
                        }
                        self.pending_send_resume_notified = true;
                    }
                } else {
                    try self.appendMessage("system", "Connection lost. Please reconnect.", null);
                }
                return;
            }

            var count: u32 = 0;
            // Drain all available messages (non-blocking, like ZSC)
            while (client.tryReceive()) |msg| {
                count += 1;
                std.log.info("[ZSS] Received frame ({d} bytes)", .{msg.len});
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

    fn isPanelFocused(_: *App, manager: *panel_manager.PanelManager, panel_id: workspace.PanelId) bool {
        return manager.workspace.focused_panel_id != null and manager.workspace.focused_panel_id.? == panel_id;
    }

    fn focusedSettingsBuffer(self: *App) ?*std.ArrayList(u8) {
        return switch (self.settings_panel.focused_field) {
            .server_url => &self.settings_panel.server_url,
            .project_id => &self.settings_panel.project_id,
            .project_token => &self.settings_panel.project_token,
            .project_create_name => &self.settings_panel.project_create_name,
            .project_create_vision => &self.settings_panel.project_create_vision,
            .project_operator_token => &self.settings_panel.project_operator_token,
            .default_session => &self.settings_panel.default_session,
            .default_agent => &self.settings_panel.default_agent,
            .ui_theme => &self.settings_panel.ui_theme,
            .ui_profile => &self.settings_panel.ui_profile,
            .ui_theme_pack => &self.settings_panel.ui_theme_pack,
            .none => null,
        };
    }

    fn popLastUtf8Codepoint(buf: *std.ArrayList(u8)) void {
        if (buf.items.len == 0) return;
        var idx = buf.items.len;
        while (idx > 0) {
            idx -= 1;
            if ((buf.items[idx] & 0xC0) != 0x80) {
                buf.shrinkRetainingCapacity(idx);
                return;
            }
        }
        buf.clearRetainingCapacity();
    }

    fn appendSingleLineText(
        self: *App,
        buf: *std.ArrayList(u8),
        text: []const u8,
    ) !void {
        for (text) |ch| {
            if (ch == '\n' or ch == '\r') continue;
            if (ch < 0x20) continue;
            try buf.append(self.allocator, ch);
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
                if (self.settings_panel.focused_field == .server_url) {
                    try self.tryConnect(manager);
                }
            },
            .v => {
                if (key_evt.mods.ctrl and !key_evt.repeat) {
                    const clip = zapp.clipboard.getTextZ();
                    if (clip.len > 0) {
                        if (self.focusedSettingsBuffer()) |buf| {
                            try self.appendSingleLineText(buf, clip);
                        }
                    }
                }
                // Also allow copying selected debug line with Ctrl+C when debug panel is focused
                if (key_evt.mods.ctrl and !key_evt.repeat and self.debug_panel_id != null and self.isPanelFocused(manager, self.debug_panel_id.?)) {
                    // Ctrl+V handled above; we also treat Ctrl+C here
                }
            },
            .c => {
                if (key_evt.mods.ctrl and !key_evt.repeat and self.debug_selected_index != null) {
                    var allow_copy = false;
                    if (self.debug_panel_id != null and self.isPanelFocused(manager, self.debug_panel_id.?)) {
                        allow_copy = true;
                    }
                    // Also allow Ctrl+C when mouse is over the debug output area
                    if (self.debug_output_rect.contains(.{ self.mouse_x, self.mouse_y })) {
                        allow_copy = true;
                    }
                    if (allow_copy) {
                        if (self.debug_selected_index) |sel_idx| {
                            if (sel_idx < self.debug_events.items.len) {
                                const entry = self.debug_events.items[sel_idx];
                                const to_copy = std.fmt.allocPrint(
                                    self.allocator,
                                    "{d} {s} {s}",
                                    .{ entry.timestamp_ms, entry.category, entry.payload_json },
                                ) catch "";
                                if (to_copy.len > 0) {
                                    const buf = self.allocator.alloc(u8, to_copy.len + 1) catch {
                                        self.allocator.free(to_copy);
                                        return;
                                    };
                                    @memcpy(buf[0..to_copy.len], to_copy);
                                    buf[to_copy.len] = 0;
                                    const zslice: [:0]const u8 = buf[0..to_copy.len :0];
                                    zapp.clipboard.setTextZ(zslice);
                                    self.allocator.free(buf);
                                    self.allocator.free(to_copy);
                                }
                            }
                        }
                    }
                }
            },
            .back_space => {
                if (self.focusedSettingsBuffer()) |buf| {
                    popLastUtf8Codepoint(buf);
                }
            },
            .delete => {
                if (self.focusedSettingsBuffer()) |buf| {
                    popLastUtf8Codepoint(buf);
                }
            },
            .page_up => {
                if (self.debug_panel_id) |panel_id| {
                    if (self.isPanelFocused(manager, panel_id)) {
                        self.debug_scroll_y -= 200.0 * self.ui_scale;
                        if (self.debug_scroll_y < 0.0) self.debug_scroll_y = 0.0;
                    }
                }
                if (self.focusedFormScrollY(manager)) |scroll_y| {
                    scroll_y.* -= 200.0 * self.ui_scale;
                    if (scroll_y.* < 0.0) scroll_y.* = 0.0;
                }
            },
            .page_down => {
                if (self.debug_panel_id) |panel_id| {
                    if (self.isPanelFocused(manager, panel_id)) {
                        self.debug_scroll_y += 200.0 * self.ui_scale;
                    }
                }
                if (self.focusedFormScrollY(manager)) |scroll_y| {
                    scroll_y.* += 200.0 * self.ui_scale;
                }
            },
            .home => {
                if (self.debug_panel_id) |panel_id| {
                    if (self.isPanelFocused(manager, panel_id)) {
                        self.debug_scroll_y = 0.0;
                    }
                }
                if (self.focusedFormScrollY(manager)) |scroll_y| {
                    scroll_y.* = 0.0;
                }
            },
            .end => {
                if (self.debug_panel_id) |panel_id| {
                    if (self.isPanelFocused(manager, panel_id)) {
                        // Move far down; clamped during render
                        self.debug_scroll_y += 1_000_000.0;
                    }
                }
                if (self.focusedFormScrollY(manager)) |scroll_y| {
                    // Move far down; clamped during render
                    scroll_y.* += 1_000_000.0;
                }
            },
            .up_arrow => {
                if (self.debug_panel_id) |panel_id| {
                    if (self.isPanelFocused(manager, panel_id)) {
                        self.debug_scroll_y -= 40.0 * self.ui_scale;
                        if (self.debug_scroll_y < 0.0) self.debug_scroll_y = 0.0;
                    }
                }
                if (self.focusedFormScrollY(manager)) |scroll_y| {
                    scroll_y.* -= 40.0 * self.ui_scale;
                    if (scroll_y.* < 0.0) scroll_y.* = 0.0;
                }
            },
            .down_arrow => {
                if (self.debug_panel_id) |panel_id| {
                    if (self.isPanelFocused(manager, panel_id)) {
                        self.debug_scroll_y += 40.0 * self.ui_scale;
                    }
                }
                if (self.focusedFormScrollY(manager)) |scroll_y| {
                    scroll_y.* += 40.0 * self.ui_scale;
                }
            },
            else => {},
        }
    }

    fn handleTextInput(self: *App, text: []const u8) !void {
        if (text.len == 0) return;
        if (self.focusedSettingsBuffer()) |buf| {
            try self.appendSingleLineText(buf, text);
        }
    }

    fn syncSettingsToConfig(self: *App) !void {
        try self.config.setServerUrl(self.settings_panel.server_url.items);
        try self.config.setSelectedProject(
            if (self.settings_panel.project_id.items.len > 0)
                self.settings_panel.project_id.items
            else
                null,
        );
        if (self.settings_panel.project_id.items.len > 0) {
            try self.config.setProjectToken(
                self.settings_panel.project_id.items,
                self.settings_panel.project_token.items,
            );
        }
        if (self.settings_panel.project_operator_token.items.len > 0) {
            try self.config.setRoleToken(.admin, self.settings_panel.project_operator_token.items);
        }
        try self.config.setDefaultSession(self.settings_panel.default_session.items);
        try self.config.setDefaultAgent(
            if (self.settings_panel.default_agent.items.len > 0)
                self.settings_panel.default_agent.items
            else
                null,
        );
        self.config.auto_connect_on_launch = self.settings_panel.auto_connect_on_launch;
        try self.config.setTheme(if (self.settings_panel.ui_theme.items.len > 0) self.settings_panel.ui_theme.items else null);
        try self.config.setProfile(if (self.settings_panel.ui_profile.items.len > 0) self.settings_panel.ui_profile.items else null);
        try self.config.setThemePack(if (self.settings_panel.ui_theme_pack.items.len > 0) self.settings_panel.ui_theme_pack.items else null);
        self.config.setWatchThemePack(self.settings_panel.watch_theme_pack);
        try self.config.save();

        self.applyThemeFromSettings();
    }

    fn clearWorkspaceData(self: *App) void {
        workspace_types.deinitProjectList(self.allocator, &self.projects);
        workspace_types.deinitNodeList(self.allocator, &self.nodes);
        self.project_selector_open = false;
        if (self.workspace_state) |*status| {
            status.deinit(self.allocator);
            self.workspace_state = null;
        }
        if (self.workspace_last_error) |value| {
            self.allocator.free(value);
            self.workspace_last_error = null;
        }
        self.workspace_last_refresh_ms = 0;
    }

    fn clearFilesystemData(self: *App) void {
        for (self.filesystem_entries.items) |*entry| entry.deinit(self.allocator);
        self.filesystem_entries.deinit(self.allocator);
        self.filesystem_entries = .{};
        if (self.filesystem_preview_path) |value| {
            self.allocator.free(value);
            self.filesystem_preview_path = null;
        }
        if (self.filesystem_preview_text) |value| {
            self.allocator.free(value);
            self.filesystem_preview_text = null;
        }
        if (self.filesystem_error) |value| {
            self.allocator.free(value);
            self.filesystem_error = null;
        }
    }

    fn setFilesystemError(self: *App, message: []const u8) void {
        if (self.filesystem_error) |value| {
            self.allocator.free(value);
            self.filesystem_error = null;
        }
        self.filesystem_error = self.allocator.dupe(u8, message) catch null;
    }

    fn clearFilesystemError(self: *App) void {
        if (self.filesystem_error) |value| {
            self.allocator.free(value);
            self.filesystem_error = null;
        }
    }

    fn setFsrpcRemoteError(self: *App, message: []const u8) void {
        self.clearFsrpcRemoteError();
        self.fsrpc_last_remote_error = self.allocator.dupe(u8, message) catch null;
    }

    fn clearFsrpcRemoteError(self: *App) void {
        if (self.fsrpc_last_remote_error) |value| {
            self.allocator.free(value);
            self.fsrpc_last_remote_error = null;
        }
    }

    fn formatFilesystemOpError(self: *App, operation: []const u8, err: anyerror) ?[]u8 {
        if (err == error.RemoteError) {
            if (self.fsrpc_last_remote_error) |remote| {
                return std.fmt.allocPrint(self.allocator, "{s}: {s}", .{ operation, remote }) catch null;
            }
        }
        return std.fmt.allocPrint(self.allocator, "{s}: {s}", .{ operation, @errorName(err) }) catch null;
    }

    fn controlAuthHintForRemote(self: *App, remote: []const u8) ?[]u8 {
        if (std.mem.indexOf(u8, remote, "project_auth_failed") != null) {
            return self.allocator.dupe(
                u8,
                "Set Project Token in Project panel (token is returned when project is created/project_up).",
            ) catch null;
        }
        if (std.mem.indexOf(u8, remote, "project_assignment_forbidden") != null) {
            return self.allocator.dupe(
                u8,
                "This agent is not allowed on that project (Spider Web is primary-agent only).",
            ) catch null;
        }
        return null;
    }

    fn formatControlRemoteMessage(self: *App, operation: []const u8, remote: []const u8) ?[]u8 {
        const hint = self.controlAuthHintForRemote(remote);
        defer if (hint) |value| self.allocator.free(value);
        if (hint) |value| {
            return std.fmt.allocPrint(self.allocator, "{s}: {s} {s}", .{ operation, remote, value }) catch null;
        }
        return std.fmt.allocPrint(self.allocator, "{s}: {s}", .{ operation, remote }) catch null;
    }

    fn formatControlOpError(self: *App, operation: []const u8, err: anyerror) ?[]u8 {
        if (err == error.RemoteError) {
            if (control_plane.lastRemoteError()) |remote| {
                return self.formatControlRemoteMessage(operation, remote);
            }
        }
        return std.fmt.allocPrint(self.allocator, "{s}: {s}", .{ operation, @errorName(err) }) catch null;
    }

    fn setWorkspaceError(self: *App, message: []const u8) void {
        if (self.workspace_last_error) |value| {
            self.allocator.free(value);
            self.workspace_last_error = null;
        }
        self.workspace_last_error = self.allocator.dupe(u8, message) catch null;
    }

    fn clearWorkspaceError(self: *App) void {
        if (self.workspace_last_error) |value| {
            self.allocator.free(value);
            self.workspace_last_error = null;
        }
    }

    fn selectedProjectId(self: *App) ?[]const u8 {
        if (self.settings_panel.project_id.items.len > 0) return self.settings_panel.project_id.items;
        return self.config.selectedProject();
    }

    fn selectProjectInSettings(self: *App, project_id: []const u8) !void {
        self.settings_panel.project_id.clearRetainingCapacity();
        try self.settings_panel.project_id.appendSlice(self.allocator, project_id);
        self.project_selector_open = false;
        self.settings_panel.project_token.clearRetainingCapacity();
        if (self.config.getProjectToken(project_id)) |token| {
            try self.settings_panel.project_token.appendSlice(self.allocator, token);
        }
        try self.syncSettingsToConfig();
    }

    fn refreshWorkspaceData(self: *App) !void {
        const client = if (self.ws_client) |*value| value else return error.NotConnected;
        try control_plane.ensureUnifiedV2Connection(self.allocator, client, &self.message_counter);

        var projects = try control_plane.listProjects(self.allocator, client, &self.message_counter);
        errdefer workspace_types.deinitProjectList(self.allocator, &projects);
        var nodes = try control_plane.listNodes(self.allocator, client, &self.message_counter);
        errdefer workspace_types.deinitNodeList(self.allocator, &nodes);
        const selected_project_id = self.selectedProjectId();
        const selected_project_token = if (selected_project_id) |project_id|
            if (self.settings_panel.project_token.items.len > 0)
                self.settings_panel.project_token.items
            else
                self.config.getProjectToken(project_id)
        else
            null;

        var selected_project_warning: ?[]u8 = null;
        defer if (selected_project_warning) |value| self.allocator.free(value);

        var workspace_status = control_plane.workspaceStatus(
            self.allocator,
            client,
            &self.message_counter,
            selected_project_id,
            selected_project_token,
        ) catch |err| blk: {
            if (selected_project_id != null and err == error.RemoteError) {
                if (control_plane.lastRemoteError()) |remote| {
                    selected_project_warning = self.formatControlRemoteMessage("Selected project unavailable", remote);
                } else {
                    selected_project_warning = std.fmt.allocPrint(self.allocator, "Selected project unavailable: {s}", .{@errorName(err)}) catch null;
                }
                break :blk try control_plane.workspaceStatus(
                    self.allocator,
                    client,
                    &self.message_counter,
                    null,
                    null,
                );
            }
            return err;
        };
        errdefer workspace_status.deinit(self.allocator);

        workspace_types.deinitProjectList(self.allocator, &self.projects);
        workspace_types.deinitNodeList(self.allocator, &self.nodes);
        if (self.workspace_state) |*status| status.deinit(self.allocator);

        self.projects = projects;
        self.nodes = nodes;
        self.workspace_state = workspace_status;
        self.workspace_last_refresh_ms = std.time.milliTimestamp();
        if (selected_project_warning) |message| {
            self.setWorkspaceError(message);
        } else {
            self.clearWorkspaceError();
        }
    }

    fn activateSelectedProject(self: *App) !void {
        const client = if (self.ws_client) |*value| value else return error.NotConnected;
        const project_id = self.selectedProjectId() orelse return error.MissingField;

        const token = if (self.settings_panel.project_token.items.len > 0)
            self.settings_panel.project_token.items
        else if (self.config.getProjectToken(project_id)) |value|
            value
        else
            null;

        var status = try control_plane.activateProject(
            self.allocator,
            client,
            &self.message_counter,
            project_id,
            token,
        );
        errdefer status.deinit(self.allocator);

        if (self.workspace_state) |*existing| existing.deinit(self.allocator);
        self.workspace_state = status;
        self.workspace_last_refresh_ms = std.time.milliTimestamp();
        self.clearWorkspaceError();

        if (self.settings_panel.project_token.items.len == 0) {
            if (token) |value| {
                try self.settings_panel.project_token.appendSlice(self.allocator, value);
            }
        }
        try self.syncSettingsToConfig();
    }

    fn resolveProjectOperatorToken(self: *App) ?[]const u8 {
        if (self.settings_panel.project_operator_token.items.len > 0) return self.settings_panel.project_operator_token.items;
        if (self.config.getRoleToken(.admin).len > 0) return self.config.getRoleToken(.admin);
        return null;
    }

    fn setRoleToken(
        self: *App,
        role: config_mod.Config.TokenRole,
        token: []const u8,
        set_active: bool,
    ) !void {
        if (role == .admin) {
            self.settings_panel.project_operator_token.clearRetainingCapacity();
            if (token.len > 0) {
                try self.settings_panel.project_operator_token.appendSlice(self.allocator, token);
            }
        }
        try self.config.setRoleToken(role, token);
        if (set_active) try self.config.setActiveRole(role);
        try self.config.save();
    }

    fn setOperatorToken(self: *App, token: []const u8) !void {
        try self.setRoleToken(.admin, token, true);
    }

    fn setUserToken(self: *App, token: []const u8) !void {
        try self.setRoleToken(.user, token, false);
    }

    fn setActiveConnectRole(self: *App, role: config_mod.Config.TokenRole) !void {
        if (self.config.active_role == role) return;
        try self.config.setActiveRole(role);
        try self.config.save();

        const role_name = if (role == .admin) "admin" else "user";
        const status = if (self.connection_state == .connected)
            try std.fmt.allocPrint(
                self.allocator,
                "Connect role set to {s}; reconnect to apply.",
                .{role_name},
            )
        else
            try std.fmt.allocPrint(
                self.allocator,
                "Connect role set to {s}.",
                .{role_name},
            );
        defer self.allocator.free(status);
        self.setConnectionState(self.connection_state, status);
    }

    fn parseRequiredTokenField(self: *App, payload_json: []const u8) ![]u8 {
        var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, payload_json, .{});
        defer parsed.deinit();
        if (parsed.value != .object) return error.InvalidResponse;
        const token_val = parsed.value.object.get("token") orelse return error.InvalidResponse;
        if (token_val != .string or token_val.string.len == 0) return error.InvalidResponse;
        return self.allocator.dupe(u8, token_val.string);
    }

    fn requestAuthStatusSnapshot(self: *App) !AuthStatusSnapshot {
        const client = if (self.ws_client) |*value| value else return error.NotConnected;
        try control_plane.ensureUnifiedV2Connection(self.allocator, client, &self.message_counter);

        const payload_json = try control_plane.requestControlPayloadJson(
            self.allocator,
            client,
            &self.message_counter,
            "control.auth_status",
            null,
        );
        defer self.allocator.free(payload_json);

        var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, payload_json, .{});
        defer parsed.deinit();
        if (parsed.value != .object) return error.InvalidResponse;
        const root = parsed.value.object;

        const admin_value = root.get("admin_token") orelse return error.InvalidResponse;
        if (admin_value != .string) return error.InvalidResponse;
        const user_value = root.get("user_token") orelse return error.InvalidResponse;
        if (user_value != .string) return error.InvalidResponse;

        return .{
            .admin_token = try self.allocator.dupe(u8, admin_value.string),
            .user_token = try self.allocator.dupe(u8, user_value.string),
            .path = if (root.get("path")) |value| switch (value) {
                .string => try self.allocator.dupe(u8, value.string),
                .null => null,
                else => return error.InvalidResponse,
            } else null,
        };
    }

    fn authSnapshotRoleToken(snapshot: *const AuthStatusSnapshot, role: []const u8) ![]const u8 {
        if (std.mem.eql(u8, role, "admin")) return snapshot.admin_token;
        if (std.mem.eql(u8, role, "user")) return snapshot.user_token;
        return error.InvalidArguments;
    }

    fn copyTextToClipboard(self: *App, text: []const u8) !void {
        if (text.len == 0) return;
        const buf = try self.allocator.alloc(u8, text.len + 1);
        defer self.allocator.free(buf);
        @memcpy(buf[0..text.len], text);
        buf[text.len] = 0;
        const zslice: [:0]const u8 = buf[0..text.len :0];
        zapp.clipboard.setTextZ(zslice);
    }

    fn fetchAuthStatusFromPanel(self: *App, reveal_tokens: bool) !void {
        var snapshot = try self.requestAuthStatusSnapshot();
        defer snapshot.deinit(self.allocator);

        const admin_display_owned = if (reveal_tokens)
            null
        else
            try maskTokenForDisplay(self.allocator, snapshot.admin_token);
        defer if (admin_display_owned) |value| self.allocator.free(value);
        const user_display_owned = if (reveal_tokens)
            null
        else
            try maskTokenForDisplay(self.allocator, snapshot.user_token);
        defer if (user_display_owned) |value| self.allocator.free(value);
        const admin_display = if (admin_display_owned) |value| value else snapshot.admin_token;
        const user_display = if (user_display_owned) |value| value else snapshot.user_token;
        const path = snapshot.path orelse "(none)";

        const msg = try std.fmt.allocPrint(
            self.allocator,
            "Auth status: admin={s} user={s} path={s}{s}",
            .{
                admin_display,
                user_display,
                path,
                if (reveal_tokens) "" else " (masked; use reveal/copy buttons for full token)",
            },
        );
        defer self.allocator.free(msg);
        try self.appendMessage("system", msg, null);
    }

    fn revealAuthTokenFromPanel(self: *App, role: []const u8) !void {
        var snapshot = try self.requestAuthStatusSnapshot();
        defer snapshot.deinit(self.allocator);
        const token = try authSnapshotRoleToken(&snapshot, role);
        const msg = try std.fmt.allocPrint(self.allocator, "Auth {s} token: {s}", .{ role, token });
        defer self.allocator.free(msg);
        try self.appendMessage("system", msg, null);
    }

    fn copyAuthTokenFromPanel(self: *App, role: []const u8) !void {
        var snapshot = try self.requestAuthStatusSnapshot();
        defer snapshot.deinit(self.allocator);
        const token = try authSnapshotRoleToken(&snapshot, role);
        try self.copyTextToClipboard(token);
        const msg = try std.fmt.allocPrint(self.allocator, "Copied auth {s} token to clipboard", .{role});
        defer self.allocator.free(msg);
        try self.appendMessage("system", msg, null);
    }

    fn rotateAuthTokenFromPanel(self: *App, role: []const u8) !void {
        if (!std.mem.eql(u8, role, "admin") and !std.mem.eql(u8, role, "user")) {
            return error.InvalidArguments;
        }

        const client = if (self.ws_client) |*value| value else return error.NotConnected;
        try control_plane.ensureUnifiedV2Connection(self.allocator, client, &self.message_counter);

        const escaped_role = try jsonEscape(self.allocator, role);
        defer self.allocator.free(escaped_role);
        const payload = try std.fmt.allocPrint(self.allocator, "{{\"role\":\"{s}\"}}", .{escaped_role});
        defer self.allocator.free(payload);

        const response_json = try control_plane.requestControlPayloadJson(
            self.allocator,
            client,
            &self.message_counter,
            "control.auth_rotate",
            payload,
        );
        defer self.allocator.free(response_json);

        const token = try self.parseRequiredTokenField(response_json);
        defer self.allocator.free(token);

        const masked = try maskTokenForDisplay(self.allocator, token);
        defer self.allocator.free(masked);
        if (std.mem.eql(u8, role, "admin")) {
            try self.setOperatorToken(token);
            const msg = try std.fmt.allocPrint(
                self.allocator,
                "Rotated admin token: {s} (saved; use reveal/copy buttons for full token)",
                .{masked},
            );
            defer self.allocator.free(msg);
            try self.appendMessage("system", msg, null);
            return;
        }

        try self.setUserToken(token);
        const msg = try std.fmt.allocPrint(
            self.allocator,
            "Rotated user token: {s} (saved; use reveal/copy buttons for full token)",
            .{masked},
        );
        defer self.allocator.free(msg);
        try self.appendMessage("system", msg, null);
    }

    fn createProjectFromPanel(self: *App) !void {
        const client = if (self.ws_client) |*value| value else return error.NotConnected;
        if (self.settings_panel.project_create_name.items.len == 0) return error.MissingField;
        try control_plane.ensureUnifiedV2Connection(self.allocator, client, &self.message_counter);

        const vision = if (self.settings_panel.project_create_vision.items.len > 0)
            self.settings_panel.project_create_vision.items
        else
            null;
        var created = try control_plane.createProject(
            self.allocator,
            client,
            &self.message_counter,
            self.settings_panel.project_create_name.items,
            vision,
            self.resolveProjectOperatorToken(),
        );
        defer created.deinit(self.allocator);

        self.settings_panel.project_id.clearRetainingCapacity();
        try self.settings_panel.project_id.appendSlice(self.allocator, created.id);
        self.settings_panel.project_token.clearRetainingCapacity();
        if (created.project_token) |token| {
            try self.settings_panel.project_token.appendSlice(self.allocator, token);
        }
        try self.syncSettingsToConfig();
        self.settings_panel.project_create_name.clearRetainingCapacity();
        self.activateSelectedProject() catch {};
        self.refreshWorkspaceData() catch {};
        self.clearWorkspaceError();
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
        const ui_mode: zui.ui.theme.Mode = switch (mode) {
            .light => .light,
            .dark => .dark,
        };
        zui.ui.theme.setMode(ui_mode);
        self.theme = zui.theme.current();
    }

    fn drawFrame(self: *App, ui_window: *UiWindow) void {
        self.theme = zui.theme.current();
        self.metrics_context.setTheme(zui.ui.theme.activeTheme());
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

        const status_height: f32 = 24.0 * self.ui_scale;
        const menu_height = self.windowMenuBarHeight();
        const dock_height = @max(1.0, @as(f32, @floatFromInt(fb_height)) - status_height - menu_height);
        const viewport = UiRect.fromMinSize(
            .{ 0, menu_height },
            .{ @floatFromInt(fb_width), dock_height },
        );

        // Draw background
        self.ui_commands.pushRect(
            .{ .min = .{ 0, 0 }, .max = .{ @floatFromInt(fb_width), @floatFromInt(fb_height) } },
            .{ .fill = self.theme.colors.background },
        );

        ui_window.ui_state.last_dock_content_rect = viewport;

        const mouse_in_viewport = self.mouse_x >= viewport.min[0] and
            self.mouse_x <= viewport.max[0] and
            self.mouse_y >= viewport.min[1] and
            self.mouse_y <= viewport.max[1];
        const saved_mouse_clicked = self.mouse_clicked;
        const saved_mouse_released = self.mouse_released;
        const saved_mouse_down = self.mouse_down;
        if (!mouse_in_viewport) {
            self.mouse_clicked = false;
            self.mouse_released = false;
            self.mouse_down = false;
        }

        self.ui_commands.pushClip(.{ .min = viewport.min, .max = viewport.max });

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
            self.ui_commands.popClip();
            self.mouse_clicked = saved_mouse_clicked;
            self.mouse_released = saved_mouse_released;
            self.mouse_down = saved_mouse_down;
            _ = self.drawWindowMenuBar(ui_window, fb_width);
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
        self.ui_commands.popClip();
        self.mouse_clicked = saved_mouse_clicked;
        self.mouse_released = saved_mouse_released;
        self.mouse_down = saved_mouse_down;

        _ = self.drawWindowMenuBar(ui_window, fb_width);
        self.drawStatusOverlay(fb_width, fb_height);
    }

    fn windowMenuBarHeight(self: *App) f32 {
        const layout = self.panelLayoutMetrics();
        return @max(layout.button_height + layout.inner_inset * 1.2, 30.0 * self.ui_scale);
    }

    fn drawWindowMenuBar(self: *App, ui_window: *UiWindow, fb_width: u32) f32 {
        const layout = self.panelLayoutMetrics();
        const bar_h = self.windowMenuBarHeight();
        const bar_rect = Rect.fromXYWH(0, 0, @floatFromInt(fb_width), bar_h);
        self.ui_commands.pushRect(
            .{ .min = bar_rect.min, .max = bar_rect.max },
            .{ .fill = self.theme.colors.background, .stroke = self.theme.colors.border },
        );

        const button_y = bar_rect.min[1] + @max(0.0, (bar_h - layout.button_height) * 0.5);
        const button_label_open = "Windows [^]";
        const button_label_closed = "Windows [v]";
        const button_w = @max(
            132.0 * self.ui_scale,
            self.measureText(button_label_open) + layout.inner_inset * 2.4,
        );
        const menu_button_rect = Rect.fromXYWH(layout.inset, button_y, button_w, layout.button_height);
        const menu_open_for_window = self.windows_menu_open_window_id != null and
            self.windows_menu_open_window_id.? == ui_window.id;

        if (self.drawButtonWidget(
            menu_button_rect,
            if (menu_open_for_window) button_label_open else button_label_closed,
            .{ .variant = .secondary },
        )) {
            if (menu_open_for_window) {
                self.windows_menu_open_window_id = null;
            } else {
                self.windows_menu_open_window_id = ui_window.id;
            }
        }

        var dropdown_rect: ?Rect = null;
        if (self.windows_menu_open_window_id != null and self.windows_menu_open_window_id.? == ui_window.id) {
            const row_h = layout.button_height;
            const row_gap = @max(1.0, layout.inner_inset * 0.2);
            const menu_w = @max(
                272.0 * self.ui_scale,
                self.measureText("Filesystem Browser (Open/Focus)") + layout.inner_inset * 2.8,
            );
            const rows: usize = 6;
            const menu_h = layout.inner_inset * 2.0 +
                row_h * @as(f32, @floatFromInt(rows)) +
                row_gap * @as(f32, @floatFromInt(rows - 1));
            const menu_x = layout.inset;
            const menu_y = bar_rect.max[1] + @max(1.0, layout.inner_inset * 0.3);
            const menu_rect = Rect.fromXYWH(menu_x, menu_y, menu_w, menu_h);
            dropdown_rect = menu_rect;

            self.drawSurfacePanel(menu_rect);
            self.drawRect(menu_rect, self.theme.colors.border);

            var row_y = menu_rect.min[1] + layout.inner_inset;
            const row_x = menu_rect.min[0] + layout.inner_inset;
            const row_w = menu_rect.width() - layout.inner_inset * 2.0;

            const workspace_open = ui_window.manager.hasPanel(.Control) or ui_window.manager.hasPanel(.Settings);
            if (self.drawButtonWidget(
                Rect.fromXYWH(row_x, row_y, row_w, row_h),
                if (workspace_open) "Workspace (Focus)" else "Workspace (Open)",
                .{ .variant = .secondary },
            )) {
                self.ensureWorkspacePanel(ui_window.manager);
                self.windows_menu_open_window_id = null;
            }
            row_y += row_h + row_gap;

            if (self.drawButtonWidget(
                Rect.fromXYWH(row_x, row_y, row_w, row_h),
                if (ui_window.manager.hasPanel(.Chat)) "Chat (Focus)" else "Chat (Open)",
                .{ .variant = .secondary },
            )) {
                ui_window.manager.ensurePanel(.Chat);
                self.windows_menu_open_window_id = null;
            }
            row_y += row_h + row_gap;

            if (self.drawButtonWidget(
                Rect.fromXYWH(row_x, row_y, row_w, row_h),
                if (self.hasPanelWithTitle(ui_window.manager, "Projects") or self.project_panel_id != null) "Projects (Focus)" else "Projects (Open)",
                .{ .variant = .secondary },
            )) {
                _ = self.ensureProjectPanel(ui_window.manager) catch |err| {
                    std.log.err("Windows menu failed to open Projects: {s}", .{@errorName(err)});
                };
                self.windows_menu_open_window_id = null;
            }
            row_y += row_h + row_gap;

            if (self.drawButtonWidget(
                Rect.fromXYWH(row_x, row_y, row_w, row_h),
                if (self.hasPanelWithTitle(ui_window.manager, "Filesystem Browser") or self.filesystem_panel_id != null) "Filesystem Browser (Focus)" else "Filesystem Browser (Open)",
                .{ .variant = .secondary },
            )) {
                _ = self.ensureFilesystemPanel(ui_window.manager) catch |err| {
                    std.log.err("Windows menu failed to open Filesystem Browser: {s}", .{@errorName(err)});
                };
                self.windows_menu_open_window_id = null;
            }
            row_y += row_h + row_gap;

            if (self.drawButtonWidget(
                Rect.fromXYWH(row_x, row_y, row_w, row_h),
                if (self.hasPanelWithTitle(ui_window.manager, "Debug Stream") or self.debug_panel_id != null) "Debug Stream (Focus)" else "Debug Stream (Open)",
                .{ .variant = .secondary },
            )) {
                _ = self.ensureDebugPanel(ui_window.manager) catch |err| {
                    std.log.err("Windows menu failed to open Debug Stream: {s}", .{@errorName(err)});
                };
                self.windows_menu_open_window_id = null;
            }
            row_y += row_h + row_gap;

            if (self.drawButtonWidget(
                Rect.fromXYWH(row_x, row_y, row_w, row_h),
                "Spawn New Window",
                .{ .variant = .secondary },
            )) {
                self.spawnUiWindow() catch |err| {
                    std.log.err("Windows menu failed to create window: {s}", .{@errorName(err)});
                };
                self.windows_menu_open_window_id = null;
            }
        }

        if (self.mouse_clicked and self.windows_menu_open_window_id != null and self.windows_menu_open_window_id.? == ui_window.id) {
            const in_button = menu_button_rect.contains(.{ self.mouse_x, self.mouse_y });
            const in_dropdown = if (dropdown_rect) |rect| rect.contains(.{ self.mouse_x, self.mouse_y }) else false;
            if (!in_button and !in_dropdown) {
                self.windows_menu_open_window_id = null;
            }
        }

        return bar_h;
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

        const status_height: f32 = 24.0 * self.ui_scale;
        const viewport = UiRect.fromMinSize(
            .{ 0, 0 },
            .{ @floatFromInt(fb_width), @as(f32, @floatFromInt(fb_height)) - status_height },
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
        const line_height = self.textLineHeight();
        const pad = @max(self.theme.spacing.xs, 4.0 * self.ui_scale);
        const offset = @max(self.theme.spacing.md * 0.9, 12.0 * self.ui_scale);
        const label_rect = UiRect.fromMinSize(
            .{ queue.state.mouse_pos[0] + offset, queue.state.mouse_pos[1] + offset },
            .{ text_w + pad * 2.0, line_height + pad * 2.0 },
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

    fn computeSplitRect(self: *App, rect: UiRect, axis: dock_graph.Axis, ratio: f32) struct { first: UiRect, second: UiRect } {
        const size = rect.size();
        const clamped_ratio = std.math.clamp(ratio, 0.1, 0.9);
        const gap = self.dockSplitGap();
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
        const line_height = self.textLineHeight();
        const tab_metrics = self.dockTabMetrics();
        const tab_height = tab_metrics.height;

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

        var tab_x = rect.min[0] + tab_metrics.pad;
        const rect_w = rect.max[0] - rect.min[0];
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

            const desired_tab_width = self.measureText(panel.title) + tab_metrics.pad * 2.0;
            const tab_width = self.dockTabWidth(panel.title, rect_w, tab_metrics);
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
            if (desired_tab_width > tab_width) {
                self.drawTextTrimmed(
                    tab_x + tab_metrics.pad,
                    rect.min[1] + @max(0.0, (tab_height - line_height) * 0.5),
                    tab_width - tab_metrics.pad * 2.0,
                    panel.title,
                    self.theme.colors.text_primary,
                );
            } else {
                self.drawText(
                    tab_x + tab_metrics.pad,
                    rect.min[1] + @max(0.0, (tab_height - line_height) * 0.5),
                    panel.title,
                    self.theme.colors.text_primary,
                );
            }

            tab_x += tab_width + tab_metrics.pad;
        }

        // Draw content area for active tab
        const content_rect = UiRect.fromMinSize(
            .{ rect.min[0], rect.min[1] + tab_height },
            .{ rect.max[0] - rect.min[0], rect.max[1] - rect.min[1] - tab_height },
        );

        if (active_tab_id) |panel_id| {
            self.ui_commands.pushClip(.{ .min = content_rect.min, .max = content_rect.max });
            defer self.ui_commands.popClip();
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
        const inset = self.panelLayoutMetrics().inset;

        switch (panel.kind) {
            .Chat => {
                self.drawChatPanel(rect);
            },
            .Settings, .Control => {
                self.drawSettingsPanel(manager, rect);
            },
            .ToolOutput => {
                if (self.debug_panel_id != null and self.debug_panel_id.? == panel.id) {
                    self.drawDebugPanel(manager, rect);
                } else if (self.project_panel_id != null and self.project_panel_id.? == panel.id) {
                    self.drawProjectPanel(manager, rect);
                } else if (self.filesystem_panel_id != null and self.filesystem_panel_id.? == panel.id) {
                    self.drawFilesystemPanel(manager, rect);
                } else if (std.mem.eql(u8, panel.title, "Debug Stream")) {
                    self.debug_panel_id = panel.id;
                    self.drawDebugPanel(manager, rect);
                } else if (std.mem.eql(u8, panel.title, "Projects")) {
                    self.project_panel_id = panel.id;
                    self.drawProjectPanel(manager, rect);
                } else if (std.mem.eql(u8, panel.title, "Filesystem Browser")) {
                    self.filesystem_panel_id = panel.id;
                    self.drawFilesystemPanel(manager, rect);
                } else {
                    self.drawText(
                        rect.min[0] + inset,
                        rect.min[1] + inset,
                        panel.title,
                        self.theme.colors.text_primary,
                    );
                }
            },
            else => {
                // Draw placeholder for other panel types
                self.drawText(
                    rect.min[0] + inset,
                    rect.min[1] + inset,
                    panel.title,
                    self.theme.colors.text_primary,
                );
            },
        }
    }

    fn drawSettingsPanel(self: *App, manager: *panel_manager.PanelManager, rect: UiRect) void {
        const layout = self.panelLayoutMetrics();
        const pad = layout.inset;
        var y = rect.min[1] + pad - self.settings_panel.settings_scroll_y;
        const rect_width = rect.max[0] - rect.min[0];
        const input_height = layout.input_height;
        const button_height = layout.button_height;
        const input_width = @max(220.0, rect_width - pad * 2.0);

        self.drawFormSectionTitle(rect.min[0] + pad, &y, input_width, layout, "ZiggyStarSpider - Settings");
        self.drawFormFieldLabel(rect.min[0] + pad, &y, input_width, layout, "Server URL");
        const input_rect = Rect.fromXYWH(
            rect.min[0] + pad,
            y,
            input_width,
            input_height,
        );
        const url_focused = self.drawTextInputWidget(
            input_rect,
            self.settings_panel.server_url.items,
            self.settings_panel.focused_field == .server_url,
            .{ .placeholder = "ws://127.0.0.1:18790" },
        );
        if (url_focused) self.settings_panel.focused_field = .server_url;

        y += input_height + pad * 0.5;
        self.drawLabel(
            rect.min[0] + pad,
            y,
            "Connect role",
            self.theme.colors.text_primary,
        );
        y += 20.0 * self.ui_scale;
        const role_button_width: f32 = @max(120.0, (rect_width - pad * 3.0) * 0.5);
        const connect_role_admin_rect = Rect.fromXYWH(
            rect.min[0] + pad,
            y,
            role_button_width,
            input_height,
        );
        const connect_role_user_rect = Rect.fromXYWH(
            connect_role_admin_rect.max[0] + pad,
            y,
            role_button_width,
            input_height,
        );
        if (self.drawButtonWidget(
            connect_role_admin_rect,
            "Admin",
            .{ .variant = if (self.config.active_role == .admin) .primary else .secondary },
        )) {
            self.setActiveConnectRole(.admin) catch |err| {
                std.log.err("Failed to set connect role admin: {s}", .{@errorName(err)});
            };
        }
        if (self.drawButtonWidget(
            connect_role_user_rect,
            "User",
            .{ .variant = if (self.config.active_role == .user) .primary else .secondary },
        )) {
            self.setActiveConnectRole(.user) catch |err| {
                std.log.err("Failed to set connect role user: {s}", .{@errorName(err)});
            };
        }
        y += input_height + 4.0 * self.ui_scale;
        self.drawLabel(
            rect.min[0] + pad,
            y,
            if (self.connection_state == .connected) "Role applies on next reconnect" else "Role applies on next connect",
            self.theme.colors.text_secondary,
        );

        y += 18.0 * self.ui_scale + pad * 0.5;
        self.drawFormFieldLabel(rect.min[0] + pad, &y, input_width, layout, "Default session");
        const default_session_rect = Rect.fromXYWH(
            rect.min[0] + pad,
            y,
            input_width,
            input_height,
        );
        const default_session_focused = self.drawTextInputWidget(
            default_session_rect,
            self.settings_panel.default_session.items,
            self.settings_panel.focused_field == .default_session,
            .{ .placeholder = "main" },
        );
        if (default_session_focused) self.settings_panel.focused_field = .default_session;

        y += input_height + layout.row_gap;
        self.drawFormFieldLabel(rect.min[0] + pad, &y, input_width, layout, "Default agent");
        const default_agent_rect = Rect.fromXYWH(
            rect.min[0] + pad,
            y,
            input_width,
            input_height,
        );
        const default_agent_focused = self.drawTextInputWidget(
            default_agent_rect,
            self.settings_panel.default_agent.items,
            self.settings_panel.focused_field == .default_agent,
            .{ .placeholder = "leave empty for role default" },
        );
        if (default_agent_focused) self.settings_panel.focused_field = .default_agent;

        y += input_height + layout.row_gap;
        self.drawFormFieldLabel(rect.min[0] + pad, &y, input_width, layout, "UI Theme");
        const ui_theme_rect = Rect.fromXYWH(
            rect.min[0] + pad,
            y,
            input_width,
            input_height,
        );
        const ui_theme_focused = self.drawTextInputWidget(
            ui_theme_rect,
            self.settings_panel.ui_theme.items,
            self.settings_panel.focused_field == .ui_theme,
            .{ .placeholder = "default" },
        );
        if (ui_theme_focused) self.settings_panel.focused_field = .ui_theme;

        y += input_height + layout.row_gap;
        self.drawFormFieldLabel(rect.min[0] + pad, &y, input_width, layout, "UI Profile");
        const ui_profile_rect = Rect.fromXYWH(
            rect.min[0] + pad,
            y,
            input_width,
            input_height,
        );
        const ui_profile_focused = self.drawTextInputWidget(
            ui_profile_rect,
            self.settings_panel.ui_profile.items,
            self.settings_panel.focused_field == .ui_profile,
            .{ .placeholder = "default" },
        );
        if (ui_profile_focused) self.settings_panel.focused_field = .ui_profile;

        y += input_height + layout.row_gap;
        self.drawFormFieldLabel(rect.min[0] + pad, &y, input_width, layout, "UI Theme Pack");
        const ui_theme_pack_rect = Rect.fromXYWH(
            rect.min[0] + pad,
            y,
            input_width,
            input_height,
        );
        const ui_theme_pack_focused = self.drawTextInputWidget(
            ui_theme_pack_rect,
            self.settings_panel.ui_theme_pack.items,
            self.settings_panel.focused_field == .ui_theme_pack,
            .{ .placeholder = "" },
        );
        if (ui_theme_pack_focused) self.settings_panel.focused_field = .ui_theme_pack;

        y += input_height + layout.section_gap * 0.55;
        const watch_button_label = if (self.settings_panel.watch_theme_pack)
            "Watch Theme Pack: On"
        else
            "Watch Theme Pack: Off";
        const watch_button_rect = Rect.fromXYWH(
            rect.min[0] + pad,
            y,
            @max(220.0, rect_width * 0.62),
            button_height,
        );
        if (self.drawButtonWidget(
            watch_button_rect,
            watch_button_label,
            .{ .variant = .secondary },
        )) {
            self.settings_panel.watch_theme_pack = !self.settings_panel.watch_theme_pack;
        }

        y += button_height + layout.row_gap;
        const auto_connect_label = if (self.settings_panel.auto_connect_on_launch)
            "Auto Connect: On"
        else
            "Auto Connect: Off";
        const auto_connect_rect = Rect.fromXYWH(
            rect.min[0] + pad,
            y,
            @max(220.0, rect_width * 0.52),
            button_height,
        );
        if (self.drawButtonWidget(
            auto_connect_rect,
            auto_connect_label,
            .{ .variant = .secondary },
        )) {
            self.settings_panel.auto_connect_on_launch = !self.settings_panel.auto_connect_on_launch;
        }

        if (self.mouse_released and
            isSettingsPanelFocusField(self.settings_panel.focused_field) and
            !input_rect.contains(.{ self.mouse_x, self.mouse_y }) and
            !default_session_rect.contains(.{ self.mouse_x, self.mouse_y }) and
            !default_agent_rect.contains(.{ self.mouse_x, self.mouse_y }) and
            !ui_theme_rect.contains(.{ self.mouse_x, self.mouse_y }) and
            !ui_profile_rect.contains(.{ self.mouse_x, self.mouse_y }) and
            !ui_theme_pack_rect.contains(.{ self.mouse_x, self.mouse_y }))
        {
            self.settings_panel.focused_field = .none;
        }

        const button_width: f32 = @max(148.0 * self.ui_scale, rect_width * 0.25);
        const action_row_y = y + button_height + layout.section_gap;
        const connect_rect = Rect.fromXYWH(
            rect.min[0] + pad,
            action_row_y,
            button_width,
            button_height,
        );
        if (self.drawButtonWidget(
            connect_rect,
            "Connect",
            .{ .variant = .primary, .disabled = self.connection_state == .connecting },
        )) {
            self.tryConnect(manager) catch {};
        }

        const save_rect = Rect.fromXYWH(
            connect_rect.max[0] + pad,
            action_row_y,
            button_width,
            button_height,
        );
        if (self.drawButtonWidget(
            save_rect,
            "Save Config",
            .{ .variant = .secondary },
        )) {
            self.saveConfig() catch |err| {
                self.setConnectionState(.error_state, "Failed to save config");
                std.log.err("Save config failed: {s}", .{@errorName(err)});
            };
        }

        self.drawTextTrimmed(
            save_rect.max[0] + pad,
            action_row_y + @max(0.0, (button_height - layout.line_height) * 0.5),
            @max(120.0, rect_width - (save_rect.max[0] - rect.min[0]) - pad * 2.0),
            "Open panels from Windows menu (top bar).",
            self.theme.colors.text_secondary,
        );

        const content_bottom_scrolled = action_row_y + button_height + layout.row_gap;
        const content_bottom = content_bottom_scrolled + self.settings_panel.settings_scroll_y;
        const total_height = content_bottom - (rect.min[1] + pad);
        const viewport_h = @max(0.0, rect.max[1] - rect.min[1] - pad * 2.0);
        const max_scroll = if (total_height > viewport_h) total_height - viewport_h else 0.0;
        if (self.settings_panel.settings_scroll_y < 0.0) self.settings_panel.settings_scroll_y = 0.0;
        if (self.settings_panel.settings_scroll_y > max_scroll) self.settings_panel.settings_scroll_y = max_scroll;
        const scroll_view_rect = Rect.fromXYWH(rect.min[0], rect.min[1] + pad, rect_width, viewport_h);
        self.drawVerticalScrollbar(.settings, scroll_view_rect, total_height, &self.settings_panel.settings_scroll_y);
    }

    fn drawProjectPanel(self: *App, manager: *panel_manager.PanelManager, rect: UiRect) void {
        _ = manager;
        const layout = self.panelLayoutMetrics();
        const pad = layout.inset;
        var y = rect.min[1] + pad - self.settings_panel.projects_scroll_y;
        const rect_width = rect.max[0] - rect.min[0];
        const input_height = layout.input_height;
        const button_height = layout.button_height;
        const input_width = @max(220.0, rect_width - pad * 2.0);

        self.drawFormSectionTitle(rect.min[0] + pad, &y, input_width, layout, "Project Workspace");

        if (self.settings_panel.focused_field == .project_id) {
            self.settings_panel.focused_field = .none;
        }

        self.drawFormFieldLabel(rect.min[0] + pad, &y, input_width, layout, "Selected Project");
        const project_rect = Rect.fromXYWH(
            rect.min[0] + pad,
            y,
            input_width,
            input_height,
        );
        if (self.projects.items.len == 0) self.project_selector_open = false;

        var selected_project_label_buf: ?[]u8 = null;
        defer if (selected_project_label_buf) |value| self.allocator.free(value);
        const selected_project_label: []const u8 = blk: {
            if (self.settings_panel.project_id.items.len == 0) break :blk "Select project";
            const selected_id = self.settings_panel.project_id.items;
            for (self.projects.items) |project| {
                if (std.mem.eql(u8, project.id, selected_id)) {
                    selected_project_label_buf = std.fmt.allocPrint(
                        self.allocator,
                        "{s} ({s})",
                        .{ project.name, project.id },
                    ) catch null;
                    if (selected_project_label_buf) |label| break :blk label;
                    break :blk selected_id;
                }
            }
            break :blk selected_id;
        };

        if (self.drawButtonWidget(
            project_rect,
            selected_project_label,
            .{ .variant = .secondary, .disabled = self.projects.items.len == 0 },
        )) {
            self.project_selector_open = false;
            self.settings_panel.focused_field = .none;
        }

        y += input_height;
        const project_dropdown_rect: ?Rect = null;
        self.project_selector_open = false;

        y += layout.row_gap * 0.65;
        self.drawFormFieldLabel(rect.min[0] + pad, &y, input_width, layout, "Project Token (required unless primary agent)");
        const project_token_rect = Rect.fromXYWH(
            rect.min[0] + pad,
            y,
            input_width,
            input_height,
        );
        const project_token_focused = self.drawTextInputWidget(
            project_token_rect,
            self.settings_panel.project_token.items,
            self.settings_panel.focused_field == .project_token,
            .{ .placeholder = "proj-..." },
        );
        if (project_token_focused) self.settings_panel.focused_field = .project_token;

        y += input_height + layout.row_gap;
        self.drawFormFieldLabel(rect.min[0] + pad, &y, input_width, layout, "Create Project Name");
        const create_name_rect = Rect.fromXYWH(
            rect.min[0] + pad,
            y,
            input_width,
            input_height,
        );
        const create_name_focused = self.drawTextInputWidget(
            create_name_rect,
            self.settings_panel.project_create_name.items,
            self.settings_panel.focused_field == .project_create_name,
            .{ .placeholder = "Distributed Workspace" },
        );
        if (create_name_focused) self.settings_panel.focused_field = .project_create_name;

        y += input_height + layout.row_gap * 0.8;
        self.drawFormFieldLabel(rect.min[0] + pad, &y, input_width, layout, "Create Vision (optional)");
        const create_vision_rect = Rect.fromXYWH(
            rect.min[0] + pad,
            y,
            input_width,
            input_height,
        );
        const create_vision_focused = self.drawTextInputWidget(
            create_vision_rect,
            self.settings_panel.project_create_vision.items,
            self.settings_panel.focused_field == .project_create_vision,
            .{ .placeholder = "unified node mounts" },
        );
        if (create_vision_focused) self.settings_panel.focused_field = .project_create_vision;

        y += input_height + layout.row_gap * 0.8;
        self.drawFormFieldLabel(rect.min[0] + pad, &y, input_width, layout, "Operator Token (optional)");
        const operator_token_rect = Rect.fromXYWH(
            rect.min[0] + pad,
            y,
            input_width,
            input_height,
        );
        const operator_token_focused = self.drawTextInputWidget(
            operator_token_rect,
            self.settings_panel.project_operator_token.items,
            self.settings_panel.focused_field == .project_operator_token,
            .{ .placeholder = "(fallback: saved admin token)" },
        );
        if (operator_token_focused) self.settings_panel.focused_field = .project_operator_token;

        y += input_height + layout.section_gap;
        const button_width: f32 = @max(152.0 * self.ui_scale, rect_width * 0.28);
        const create_rect = Rect.fromXYWH(rect.min[0] + pad, y, button_width, button_height);
        const refresh_rect = Rect.fromXYWH(create_rect.max[0] + pad, y, button_width, button_height);
        const activate_rect = Rect.fromXYWH(refresh_rect.max[0] + pad, y, button_width, button_height);

        if (self.drawButtonWidget(
            create_rect,
            "Create Project",
            .{
                .variant = .primary,
                .disabled = self.connection_state != .connected or self.settings_panel.project_create_name.items.len == 0,
            },
        )) {
            self.createProjectFromPanel() catch |err| {
                const msg = self.formatControlOpError("Project create failed", err);
                if (msg) |text| {
                    defer self.allocator.free(text);
                    self.setWorkspaceError(text);
                }
            };
        }

        if (self.drawButtonWidget(
            refresh_rect,
            "Refresh Workspace",
            .{ .variant = .secondary, .disabled = self.connection_state != .connected },
        )) {
            self.refreshWorkspaceData() catch |err| {
                const msg = self.formatControlOpError("Workspace refresh failed", err);
                if (msg) |text| {
                    defer self.allocator.free(text);
                    self.setWorkspaceError(text);
                }
            };
        }

        if (self.drawButtonWidget(
            activate_rect,
            "Activate Project",
            .{ .variant = .secondary, .disabled = self.connection_state != .connected or self.settings_panel.project_id.items.len == 0 },
        )) {
            self.activateSelectedProject() catch |err| {
                const msg = self.formatControlOpError("Project activate failed", err);
                if (msg) |text| {
                    defer self.allocator.free(text);
                    self.setWorkspaceError(text);
                }
            };
        }

        y += button_height + layout.row_gap;
        self.drawTextTrimmed(
            rect.min[0] + pad,
            y + @max(0.0, (button_height - layout.line_height) * 0.5),
            input_width,
            "Open Filesystem and Debug panels from the Windows menu.",
            self.theme.colors.text_secondary,
        );

        y += button_height + layout.section_gap;
        const auth_status_rect = Rect.fromXYWH(rect.min[0] + pad, y, button_width, button_height);
        const auth_rotate_user_rect = Rect.fromXYWH(auth_status_rect.max[0] + pad, y, button_width, button_height);
        const auth_rotate_admin_rect = Rect.fromXYWH(auth_rotate_user_rect.max[0] + pad, y, button_width, button_height);

        if (self.drawButtonWidget(
            auth_status_rect,
            "Auth Status",
            .{ .variant = .secondary, .disabled = self.connection_state != .connected },
        )) {
            self.fetchAuthStatusFromPanel(false) catch |err| {
                const msg = self.formatControlOpError("Auth status failed", err);
                if (msg) |text| {
                    defer self.allocator.free(text);
                    self.setWorkspaceError(text);
                }
            };
        }
        if (self.drawButtonWidget(
            auth_rotate_user_rect,
            "Rotate User",
            .{ .variant = .secondary, .disabled = self.connection_state != .connected },
        )) {
            self.rotateAuthTokenFromPanel("user") catch |err| {
                const msg = self.formatControlOpError("Auth rotate(user) failed", err);
                if (msg) |text| {
                    defer self.allocator.free(text);
                    self.setWorkspaceError(text);
                }
            };
        }
        if (self.drawButtonWidget(
            auth_rotate_admin_rect,
            "Rotate Admin",
            .{ .variant = .primary, .disabled = self.connection_state != .connected },
        )) {
            self.rotateAuthTokenFromPanel("admin") catch |err| {
                const msg = self.formatControlOpError("Auth rotate(admin) failed", err);
                if (msg) |text| {
                    defer self.allocator.free(text);
                    self.setWorkspaceError(text);
                }
            };
        }

        y += button_height + layout.row_gap;
        const auth_reveal_admin_rect = Rect.fromXYWH(rect.min[0] + pad, y, button_width, button_height);
        const auth_copy_admin_rect = Rect.fromXYWH(auth_reveal_admin_rect.max[0] + pad, y, button_width, button_height);
        const auth_reveal_user_rect = Rect.fromXYWH(auth_copy_admin_rect.max[0] + pad, y, button_width, button_height);
        if (self.drawButtonWidget(
            auth_reveal_admin_rect,
            "Reveal Admin",
            .{ .variant = .secondary, .disabled = self.connection_state != .connected },
        )) {
            self.revealAuthTokenFromPanel("admin") catch |err| {
                const msg = self.formatControlOpError("Reveal admin token failed", err);
                if (msg) |text| {
                    defer self.allocator.free(text);
                    self.setWorkspaceError(text);
                }
            };
        }
        if (self.drawButtonWidget(
            auth_copy_admin_rect,
            "Copy Admin",
            .{ .variant = .secondary, .disabled = self.connection_state != .connected },
        )) {
            self.copyAuthTokenFromPanel("admin") catch |err| {
                const msg = self.formatControlOpError("Copy admin token failed", err);
                if (msg) |text| {
                    defer self.allocator.free(text);
                    self.setWorkspaceError(text);
                }
            };
        }
        if (self.drawButtonWidget(
            auth_reveal_user_rect,
            "Reveal User",
            .{ .variant = .secondary, .disabled = self.connection_state != .connected },
        )) {
            self.revealAuthTokenFromPanel("user") catch |err| {
                const msg = self.formatControlOpError("Reveal user token failed", err);
                if (msg) |text| {
                    defer self.allocator.free(text);
                    self.setWorkspaceError(text);
                }
            };
        }

        y += button_height + layout.row_gap;
        const auth_copy_user_rect = Rect.fromXYWH(rect.min[0] + pad, y, button_width, button_height);
        if (self.drawButtonWidget(
            auth_copy_user_rect,
            "Copy User",
            .{ .variant = .secondary, .disabled = self.connection_state != .connected },
        )) {
            self.copyAuthTokenFromPanel("user") catch |err| {
                const msg = self.formatControlOpError("Copy user token failed", err);
                if (msg) |text| {
                    defer self.allocator.free(text);
                    self.setWorkspaceError(text);
                }
            };
        }

        y += button_height + layout.section_gap;
        const status_height: f32 = @max(layout.line_height + layout.inner_inset * 2.2, 32.0 * self.ui_scale);
        const status_rect = Rect.fromXYWH(
            rect.min[0] + pad,
            y,
            input_width,
            status_height,
        );
        self.drawStatusRow(status_rect);
        y += status_height + layout.row_gap;

        if (self.workspace_last_error) |err_text| {
            self.drawLabel(
                rect.min[0] + pad,
                y,
                err_text,
                zcolors.rgba(220, 80, 80, 255),
            );
            y += layout.line_height;
        }

        const selected_project_text = if (self.settings_panel.project_id.items.len > 0)
            self.settings_panel.project_id.items
        else
            "(none)";
        const selected_project_line = std.fmt.allocPrint(
            self.allocator,
            "Selected project: {s}",
            .{selected_project_text},
        ) catch null;
        if (selected_project_line) |line| {
            defer self.allocator.free(line);
            self.drawLabel(rect.min[0] + pad, y, line, self.theme.colors.text_secondary);
            y += layout.line_height;
        }

        if (self.workspace_state) |*status| {
            const root_text = status.workspace_root orelse "(none)";
            const workspace_line = std.fmt.allocPrint(
                self.allocator,
                "Workspace root: {s} | mounts: {d}",
                .{ root_text, status.mounts.items.len },
            ) catch null;
            if (workspace_line) |line| {
                defer self.allocator.free(line);
                self.drawLabel(rect.min[0] + pad, y, line, self.theme.colors.text_secondary);
                y += layout.line_height;
            }
        }

        const projects_line = std.fmt.allocPrint(
            self.allocator,
            "Projects: {d} | Nodes: {d}",
            .{ self.projects.items.len, self.nodes.items.len },
        ) catch null;
        if (projects_line) |line| {
            defer self.allocator.free(line);
            self.drawLabel(rect.min[0] + pad, y, line, self.theme.colors.text_secondary);
            y += layout.line_height;
        }
        y += layout.row_gap * 0.6;

        if (self.projects.items.len > 0) {
            self.drawLabel(rect.min[0] + pad, y, "Project List:", self.theme.colors.text_primary);
            y += layout.label_to_input_gap;
            const row_h = @max(layout.button_height * 0.86, layout.line_height + layout.inner_inset);
            const row_gap = @max(1.0, layout.inner_inset * 0.3);
            const row_step = row_h + row_gap;
            const list_top = y;
            const list_bottom = rect.max[1] + self.settings_panel.projects_scroll_y;
            const visible_start_idx: usize = @intFromFloat(@max(
                0.0,
                @floor((rect.min[1] - list_top) / row_step),
            ));
            const visible_end_idx_unclamped: usize = @intFromFloat(@max(
                0.0,
                @ceil((list_bottom - list_top) / row_step),
            ));
            const max_projects: usize = self.projects.items.len;
            const visible_end_idx = @min(max_projects, visible_end_idx_unclamped + 1);

            if (visible_start_idx > 0) {
                y += row_step * @as(f32, @floatFromInt(visible_start_idx));
            }

            var idx: usize = visible_start_idx;
            while (idx < max_projects) : (idx += 1) {
                if (idx >= visible_end_idx) {
                    const remaining = max_projects - idx;
                    y += row_step * @as(f32, @floatFromInt(remaining));
                    break;
                }
                const project = self.projects.items[idx];
                const line = std.fmt.allocPrint(
                    self.allocator,
                    "{s} [{s}] mounts={d}",
                    .{ project.id, project.status, project.mount_count },
                ) catch null;
                if (line) |value| {
                    defer self.allocator.free(value);
                    const button_w = @max(90.0 * self.ui_scale, rect_width * 0.17);
                    const text_max_w = @max(120.0, rect_width - (pad * 2.0) - button_w - pad);
                    const text_y = y + @max(0.0, (row_h - layout.line_height) * 0.5);
                    self.drawTextTrimmed(
                        rect.min[0] + pad,
                        text_y,
                        text_max_w,
                        value,
                        self.theme.colors.text_secondary,
                    );
                    const project_selected = self.settings_panel.project_id.items.len > 0 and
                        std.mem.eql(u8, self.settings_panel.project_id.items, project.id);
                    const use_rect = Rect.fromXYWH(
                        rect.min[0] + pad + text_max_w + pad,
                        y,
                        button_w,
                        row_h,
                    );
                    if (self.drawButtonWidget(
                        use_rect,
                        if (project_selected) "Selected" else "Use",
                        .{ .variant = .secondary, .disabled = project_selected },
                    )) {
                        self.selectProjectInSettings(project.id) catch |err| {
                            const msg = std.fmt.allocPrint(self.allocator, "Project select failed: {s}", .{@errorName(err)}) catch null;
                            if (msg) |text| {
                                defer self.allocator.free(text);
                                self.setWorkspaceError(text);
                            }
                        };
                    }
                    y += row_step;
                }
            }
        }

        if (self.nodes.items.len > 0) {
            y += layout.section_gap * 0.45;
            self.drawLabel(rect.min[0] + pad, y, "Nodes:", self.theme.colors.text_primary);
            y += layout.label_to_input_gap;
            const max_nodes: usize = @min(self.nodes.items.len, 8);
            var idx: usize = 0;
            while (idx < max_nodes) : (idx += 1) {
                const node = self.nodes.items[idx];
                const line = std.fmt.allocPrint(
                    self.allocator,
                    "  - {s} ({s})",
                    .{ node.node_id, node.node_name },
                ) catch null;
                if (line) |value| {
                    defer self.allocator.free(value);
                    self.drawLabel(rect.min[0] + pad, y, value, self.theme.colors.text_secondary);
                    y += layout.line_height;
                }
            }
        }

        const clicked_outside_project_selector = !project_rect.contains(.{ self.mouse_x, self.mouse_y }) and
            !(project_dropdown_rect != null and project_dropdown_rect.?.contains(.{ self.mouse_x, self.mouse_y }));

        if (self.mouse_released and clicked_outside_project_selector) {
            self.project_selector_open = false;
        }

        if (self.mouse_released and
            isProjectPanelFocusField(self.settings_panel.focused_field) and
            clicked_outside_project_selector and
            !project_token_rect.contains(.{ self.mouse_x, self.mouse_y }) and
            !create_name_rect.contains(.{ self.mouse_x, self.mouse_y }) and
            !create_vision_rect.contains(.{ self.mouse_x, self.mouse_y }) and
            !operator_token_rect.contains(.{ self.mouse_x, self.mouse_y }))
        {
            self.settings_panel.focused_field = .none;
        }

        const content_bottom_scrolled = y;
        const content_bottom = content_bottom_scrolled + self.settings_panel.projects_scroll_y;
        const total_height = content_bottom - (rect.min[1] + pad);
        const viewport_h = @max(0.0, rect.max[1] - rect.min[1] - pad * 2.0);
        const max_scroll = if (total_height > viewport_h) total_height - viewport_h else 0.0;
        if (self.settings_panel.projects_scroll_y < 0.0) self.settings_panel.projects_scroll_y = 0.0;
        if (self.settings_panel.projects_scroll_y > max_scroll) self.settings_panel.projects_scroll_y = max_scroll;
        const scroll_view_rect = Rect.fromXYWH(rect.min[0], rect.min[1] + pad, rect_width, viewport_h);
        self.drawVerticalScrollbar(.projects, scroll_view_rect, total_height, &self.settings_panel.projects_scroll_y);
    }

    fn pathWithinMount(path: []const u8, mount_path: []const u8) bool {
        if (std.mem.eql(u8, mount_path, "/")) return std.mem.startsWith(u8, path, "/");
        if (!std.mem.startsWith(u8, path, mount_path)) return false;
        if (path.len == mount_path.len) return true;
        return path.len > mount_path.len and path[mount_path.len] == '/';
    }

    fn findMountForPath(self: *App, path: []const u8) ?*const workspace_types.MountView {
        if (self.workspace_state) |*status| {
            var best: ?*const workspace_types.MountView = null;
            var best_len: usize = 0;
            for (status.mounts.items) |*mount| {
                if (!pathWithinMount(path, mount.mount_path)) continue;
                if (mount.mount_path.len > best_len) {
                    best = mount;
                    best_len = mount.mount_path.len;
                }
            }
            return best;
        }
        return null;
    }

    fn setFilesystemPath(self: *App, path: []const u8) !void {
        self.filesystem_path.clearRetainingCapacity();
        if (path.len == 0) {
            try self.filesystem_path.appendSlice(self.allocator, "/");
        } else {
            try self.filesystem_path.appendSlice(self.allocator, path);
        }
    }

    fn mapWorkspaceRootToFilesystemPath(self: *App, workspace_root: []const u8) ![]u8 {
        const trimmed = std.mem.trim(u8, workspace_root, " \t\r\n");
        if (trimmed.len == 0) return self.allocator.dupe(u8, "/");

        const legacy_prefix = "/spiderweb/projects/";
        if (std.mem.startsWith(u8, trimmed, legacy_prefix)) {
            const after_prefix = trimmed[legacy_prefix.len..];
            const slash_after_project = std.mem.indexOfScalar(u8, after_prefix, '/') orelse return self.allocator.dupe(u8, "/workspace");
            const after_project = after_prefix[slash_after_project + 1 ..];

            if (std.mem.eql(u8, after_project, "workspace")) {
                return self.allocator.dupe(u8, "/workspace");
            }
            if (std.mem.startsWith(u8, after_project, "workspace/")) {
                return std.fmt.allocPrint(self.allocator, "/workspace/{s}", .{after_project["workspace/".len..]});
            }
            return self.allocator.dupe(u8, trimmed);
        }

        return self.allocator.dupe(u8, trimmed);
    }

    fn refreshFilesystemBrowser(self: *App) !void {
        const client = if (self.ws_client) |*value| value else return error.NotConnected;
        self.clearFsrpcRemoteError();
        self.clearFilesystemData();
        self.clearFilesystemError();
        if (self.filesystem_path.items.len == 0) {
            try self.filesystem_path.appendSlice(self.allocator, "/");
        }

        try self.fsrpcBootstrapGui(client);
        const current_path = self.filesystem_path.items;
        const fid = try self.fsrpcWalkPathGui(client, current_path);
        defer self.fsrpcClunkBestEffort(client, fid);
        const is_dir = try self.fsrpcFidIsDirGui(client, fid);
        if (!is_dir) return error.NotDir;
        try self.fsrpcOpenGui(client, fid, "r");
        const listing = try self.fsrpcReadAllTextGui(client, fid);
        defer self.allocator.free(listing);

        var iter = std.mem.splitScalar(u8, listing, '\n');
        while (iter.next()) |raw| {
            const entry_name = std.mem.trim(u8, raw, " \t\r\n");
            if (entry_name.len == 0) continue;
            if (std.mem.eql(u8, entry_name, ".") or std.mem.eql(u8, entry_name, "..")) continue;

            const child_path = try self.joinFilesystemPath(current_path, entry_name);
            errdefer self.allocator.free(child_path);

            const child_fid = self.fsrpcWalkPathGui(client, child_path) catch {
                self.allocator.free(child_path);
                continue;
            };
            defer self.fsrpcClunkBestEffort(client, child_fid);
            const child_is_dir = self.fsrpcFidIsDirGui(client, child_fid) catch false;

            try self.filesystem_entries.append(self.allocator, .{
                .name = try self.allocator.dupe(u8, entry_name),
                .path = child_path,
                .is_dir = child_is_dir,
            });
        }
    }

    fn openFilesystemEntry(self: *App, entry: *const FilesystemEntry) !void {
        self.clearFsrpcRemoteError();
        if (entry.is_dir) {
            try self.setFilesystemPath(entry.path);
            try self.refreshFilesystemBrowser();
            return;
        }

        const client = if (self.ws_client) |*value| value else return error.NotConnected;
        try self.fsrpcBootstrapGui(client);
        const raw = try self.readFsPathTextGui(client, entry.path);
        defer self.allocator.free(raw);

        if (self.filesystem_preview_path) |value| self.allocator.free(value);
        self.filesystem_preview_path = try self.allocator.dupe(u8, entry.path);

        if (self.filesystem_preview_text) |value| self.allocator.free(value);
        if (raw.len > 16_384) {
            const suffix = "\n... (truncated)";
            const limit = 16_384;
            const buf = try self.allocator.alloc(u8, limit + suffix.len);
            @memcpy(buf[0..limit], raw[0..limit]);
            @memcpy(buf[limit .. limit + suffix.len], suffix);
            self.filesystem_preview_text = buf;
        } else {
            self.filesystem_preview_text = try self.allocator.dupe(u8, raw);
        }
        self.clearFilesystemError();
    }

    fn drawFilesystemPanel(self: *App, manager: *panel_manager.PanelManager, rect: UiRect) void {
        _ = manager;
        const layout = self.panelLayoutMetrics();
        const pad = layout.inset;
        const inner = layout.inner_inset;
        var y = rect.min[1] + pad;
        const width = rect.max[0] - rect.min[0];
        const row_h = layout.button_height;
        const content_width = @max(220.0, width - pad * 2.0);

        self.drawLabel(rect.min[0] + pad, y, "Filesystem Browser", self.theme.colors.text_primary);
        y += layout.title_gap;

        const path_label = if (self.filesystem_path.items.len > 0)
            self.filesystem_path.items
        else
            "/";
        const path_line = std.fmt.allocPrint(self.allocator, "Path: {s}", .{path_label}) catch null;
        if (path_line) |line| {
            defer self.allocator.free(line);
            self.drawTextTrimmed(rect.min[0] + pad, y, content_width, line, self.theme.colors.text_secondary);
        }
        y += layout.line_height + layout.row_gap * 0.55;

        const action_w: f32 = @max(124.0, width * 0.21);
        const refresh_rect = Rect.fromXYWH(rect.min[0] + pad, y, action_w, row_h);
        const up_rect = Rect.fromXYWH(refresh_rect.max[0] + pad, y, action_w, row_h);
        const root_rect = Rect.fromXYWH(up_rect.max[0] + pad, y, action_w * 1.35, row_h);

        if (self.drawButtonWidget(
            refresh_rect,
            "Refresh",
            .{ .variant = .secondary, .disabled = self.connection_state != .connected },
        )) {
            self.refreshFilesystemBrowser() catch |err| {
                const msg = self.formatFilesystemOpError("Filesystem refresh failed", err);
                if (msg) |text| {
                    defer self.allocator.free(text);
                    self.setFilesystemError(text);
                }
            };
        }
        if (self.drawButtonWidget(
            up_rect,
            "Up",
            .{ .variant = .secondary, .disabled = self.connection_state != .connected },
        )) {
            const next_path = self.parentFilesystemPath(path_label) catch null;
            if (next_path) |value| {
                defer self.allocator.free(value);
                self.setFilesystemPath(value) catch {};
                self.refreshFilesystemBrowser() catch |err| {
                    const msg = self.formatFilesystemOpError("Filesystem refresh failed", err);
                    if (msg) |text| {
                        defer self.allocator.free(text);
                        self.setFilesystemError(text);
                    }
                };
            }
        }
        if (self.drawButtonWidget(
            root_rect,
            "Use Workspace Root",
            .{ .variant = .secondary, .disabled = self.connection_state != .connected },
        )) {
            if (self.workspace_state) |*status| {
                if (status.workspace_root) |root| {
                    const mapped = self.mapWorkspaceRootToFilesystemPath(root) catch null;
                    if (mapped) |value| {
                        defer self.allocator.free(value);
                        self.setFilesystemPath(value) catch {};
                    } else {
                        self.setFilesystemPath("/") catch {};
                    }
                } else {
                    self.setFilesystemPath("/") catch {};
                }
            } else {
                self.setFilesystemPath("/") catch {};
            }
            self.refreshFilesystemBrowser() catch |err| {
                const msg = self.formatFilesystemOpError("Filesystem refresh failed", err);
                if (msg) |text| {
                    defer self.allocator.free(text);
                    self.setFilesystemError(text);
                }
            };
        }

        y += row_h + layout.row_gap;
        if (self.filesystem_error) |err_text| {
            self.drawTextTrimmed(
                rect.min[0] + pad,
                y,
                content_width,
                err_text,
                zcolors.rgba(220, 80, 80, 255),
            );
            y += layout.line_height;
        }

        const listing_height = @max(140.0, (rect.max[1] - y - pad * 2.0) * 0.52);
        const listing_rect = Rect.fromXYWH(rect.min[0] + pad, y, content_width, listing_height);
        self.drawSurfacePanel(listing_rect);

        const list_row_h = @max(layout.button_height * 0.8, layout.line_height + inner * 0.9);
        const list_row_gap = @max(1.0, inner * 0.35);
        var list_y = listing_rect.min[1] + inner;
        const max_rows: usize = @min(self.filesystem_entries.items.len, 14);
        var idx: usize = 0;
        while (idx < max_rows and idx < self.filesystem_entries.items.len) : (idx += 1) {
            const entry = self.filesystem_entries.items[idx];
            const row_rect = Rect.fromXYWH(
                listing_rect.min[0] + inner,
                list_y,
                listing_rect.width() - inner * 2.0,
                list_row_h,
            );
            const prefix = if (entry.is_dir) "[dir]" else "[file]";
            const label = std.fmt.allocPrint(self.allocator, "{s} {s}", .{ prefix, entry.name }) catch null;
            const clicked = if (label) |text| blk: {
                defer self.allocator.free(text);
                break :blk self.drawButtonWidget(row_rect, text, .{ .variant = .secondary });
            } else false;
            if (clicked) {
                self.openFilesystemEntry(&entry) catch |err| {
                    const msg = self.formatFilesystemOpError("Filesystem open failed", err);
                    if (msg) |text| {
                        defer self.allocator.free(text);
                        self.setFilesystemError(text);
                    }
                };
                // Opening a directory can replace filesystem_entries; stop iterating stale indices.
                break;
            }

            if (self.findMountForPath(entry.path)) |mount| {
                const badge = std.fmt.allocPrint(self.allocator, "{s}:{s}", .{ mount.node_id, mount.export_name }) catch null;
                if (badge) |text| {
                    defer self.allocator.free(text);
                    self.drawTextTrimmed(
                        row_rect.min[0] + @max(80.0, row_rect.width() * 0.5),
                        row_rect.min[1] + @max(0.0, (row_rect.height() - layout.line_height) * 0.5),
                        row_rect.width() * 0.46,
                        text,
                        self.theme.colors.primary,
                    );
                }
            }

            list_y += list_row_h + list_row_gap;
        }

        y = listing_rect.max[1] + pad;
        const preview_rect = Rect.fromXYWH(
            rect.min[0] + pad,
            y,
            content_width,
            @max(100.0, rect.max[1] - y - pad),
        );
        self.drawSurfacePanel(preview_rect);

        const preview_title = if (self.filesystem_preview_path) |value|
            value
        else
            "(select a file to preview)";
        self.drawTextTrimmed(
            preview_rect.min[0] + inner,
            preview_rect.min[1] + inner,
            preview_rect.width() - inner * 2.0,
            preview_title,
            self.theme.colors.text_secondary,
        );

        if (self.filesystem_preview_text) |text| {
            _ = self.drawTextWrapped(
                preview_rect.min[0] + inner,
                preview_rect.min[1] + inner + layout.line_height + layout.row_gap * 0.5,
                preview_rect.width() - inner * 2.0,
                text,
                self.theme.colors.text_primary,
            );
        }
    }

    fn drawDebugPanel(self: *App, manager: *panel_manager.PanelManager, rect: UiRect) void {
        _ = manager;

        const layout = self.panelLayoutMetrics();
        const pad = layout.inset;
        const inner = layout.inner_inset;
        const line_height = layout.line_height;
        const row_height = layout.button_height;
        const event_gap = @max(2.0 * self.ui_scale, inner * 0.35);
        var y = rect.min[1] + pad;
        const width = rect.max[0] - rect.min[0];
        const content_width = @max(240.0, width - pad * 2.0);
        const scrollbar_reserved = @max(14.0, 8.0 * self.ui_scale + inner);

        self.drawLabel(
            rect.min[0] + pad,
            y,
            "SpiderWeb Debug Stream",
            self.theme.colors.text_primary,
        );
        y += layout.title_gap;

        const status_text = if (self.debug_stream_pending)
            "Status: updating subscription..."
        else if (self.debug_stream_enabled)
            "Status: subscribed"
        else
            "Status: unsubscribed";
        self.drawLabel(
            rect.min[0] + pad,
            y,
            status_text,
            self.theme.colors.text_secondary,
        );
        y += line_height;

        self.drawLabel(
            rect.min[0] + pad,
            y,
            "Fold nested JSON with [+]/[-].",
            self.theme.colors.text_secondary,
        );
        y += line_height + layout.row_gap * 0.45;

        const toggle_rect = Rect.fromXYWH(
            rect.min[0] + pad,
            y,
            @max(220.0, width * 0.34),
            row_height,
        );
        const toggle_label = if (self.debug_stream_enabled) "Stop Debug Stream" else "Start Debug Stream";
        const toggle_clicked = self.drawButtonWidget(
            toggle_rect,
            toggle_label,
            .{ .variant = .primary, .disabled = self.debug_stream_pending },
        );
        if (toggle_clicked) {
            self.requestDebugSubscription(!self.debug_stream_enabled) catch |err| {
                std.log.err("Failed to send debug subscription request: {s}", .{@errorName(err)});
            };
        }

        y += row_height + layout.row_gap;
        const output_rect = Rect.fromXYWH(
            rect.min[0] + pad,
            y,
            content_width,
            @max(120.0, rect.max[1] - y - pad),
        );
        self.debug_output_rect = output_rect;
        self.drawSurfacePanel(output_rect);

        const usable_height = @max(0.0, output_rect.height() - inner * 2.0);
        if (usable_height <= 0) return;

        var have_copy_rect = false;
        var copy_btn_rect: Rect = Rect.fromXYWH(0, 0, 0, 0);
        if (self.debug_selected_index) |_| {
            const copy_btn_w: f32 = @max(84.0 * self.ui_scale, layout.line_height * 4.1);
            const copy_btn_h: f32 = @max(layout.button_height * 0.74, 24.0 * self.ui_scale);
            copy_btn_rect = Rect.fromXYWH(
                output_rect.max[0] - copy_btn_w - inner * 0.5,
                output_rect.min[1] + inner * 0.5,
                copy_btn_w,
                copy_btn_h,
            );
            have_copy_rect = true;
        }

        var total_content_height: f32 = inner * 2.0;
        for (self.debug_events.items) |entry| {
            const payload_visible_rows = self.countVisibleDebugPayloadRows(output_rect.min[0], output_rect.max[0] - scrollbar_reserved, entry);
            const visible_lines = 1 + payload_visible_rows;
            total_content_height += line_height * @as(f32, @floatFromInt(visible_lines)) + event_gap;
        }
        const max_scroll = @max(0.0, total_content_height - output_rect.height());
        if (self.debug_scroll_y < 0.0) self.debug_scroll_y = 0.0;
        if (self.debug_scroll_y > max_scroll) self.debug_scroll_y = max_scroll;

        self.ui_commands.pushClip(.{ .min = output_rect.min, .max = output_rect.max });
        defer self.ui_commands.popClip();

        var cur_y = output_rect.min[1] + inner - self.debug_scroll_y;
        for (self.debug_events.items, 0..) |entry, idx| {
            const payload_visible_rows = self.countVisibleDebugPayloadRows(output_rect.min[0], output_rect.max[0] - scrollbar_reserved, entry);
            const visible_lines = 1 + payload_visible_rows;
            const entry_h = line_height * @as(f32, @floatFromInt(visible_lines)) + event_gap;

            if (cur_y + entry_h < output_rect.min[1]) {
                cur_y += entry_h;
                continue;
            }
            if (cur_y > output_rect.max[1]) break;

            const entry_rect = Rect.fromXYWH(output_rect.min[0], cur_y, output_rect.width(), entry_h - event_gap);
            const is_selected = self.debug_selected_index != null and self.debug_selected_index.? == idx;
            if (is_selected) {
                const select_color = zcolors.withAlpha(self.theme.colors.primary, 0.25);
                self.drawFilledRect(entry_rect, select_color);
            }

            const content_max_x = output_rect.max[0] - scrollbar_reserved;
            self.drawDebugEventHeaderLine(output_rect.min[0] + inner + 2.0, cur_y, content_max_x, entry);

            var clicked_fold_marker = false;
            var line_y = cur_y + line_height;
            var payload_line_idx: usize = 0;
            while (payload_line_idx < entry.payload_lines.items.len) {
                const meta = entry.payload_lines.items[payload_line_idx];
                const line = entry.payload_json[meta.start..meta.end];
                const indent_width = @as(f32, @floatFromInt(meta.indent_spaces)) * self.measureText(" ");
                const line_x_base = output_rect.min[0] + inner + 2.0 + indent_width;
                const content_start = @min(meta.indent_spaces, line.len);
                const content = line[content_start..];

                var next_line_idx = payload_line_idx + 1;
                var text_x = line_x_base;

                const can_fold = meta.opens_block and meta.matching_close_index != null and
                    @as(usize, @intCast(meta.matching_close_index.?)) > payload_line_idx + 1;
                if (can_fold) {
                    const marker = if (self.isDebugBlockCollapsed(entry.id, payload_line_idx)) "[+]" else "[-]";
                    const marker_w = self.measureText(marker);
                    const marker_rect = Rect.fromXYWH(line_x_base, line_y, marker_w, line_height);
                    const marker_hovered = marker_rect.contains(.{ self.mouse_x, self.mouse_y });
                    if (self.mouse_clicked and marker_hovered) {
                        self.toggleDebugBlockCollapsed(entry.id, payload_line_idx);
                        clicked_fold_marker = true;
                    }

                    const marker_color = if (marker_hovered)
                        zcolors.blend(self.theme.colors.primary, self.theme.colors.text_primary, 0.22)
                    else
                        self.theme.colors.primary;
                    self.drawText(line_x_base, line_y, marker, marker_color);
                    text_x = line_x_base + marker_w + self.measureText(" ");
                }

                const rows_used = self.drawJsonLineColored(text_x, line_y, content_max_x, content);

                if (can_fold and self.isDebugBlockCollapsed(entry.id, payload_line_idx)) {
                    next_line_idx = @as(usize, @intCast(meta.matching_close_index.?)) + 1;
                }

                line_y += line_height * @as(f32, @floatFromInt(rows_used));
                payload_line_idx = next_line_idx;
            }

            const clicked_entry = self.mouse_clicked and entry_rect.contains(.{ self.mouse_x, self.mouse_y });
            const clicked_copy = have_copy_rect and copy_btn_rect.contains(.{ self.mouse_x, self.mouse_y });
            if (clicked_entry and !clicked_copy and !clicked_fold_marker) {
                self.debug_selected_index = idx;
            }

            cur_y += entry_h;
        }

        if (max_scroll > 0) {
            const sb_width: f32 = 8.0 * self.ui_scale;
            const sb_track_rect = Rect.fromXYWH(
                output_rect.max[0] - sb_width - inner * 0.35,
                output_rect.min[1] + inner * 0.35,
                sb_width,
                output_rect.height() - inner * 0.7,
            );

            const thumb_height = @max(20.0, sb_track_rect.height() * (output_rect.height() / total_content_height));
            const thumb_y_ratio = self.debug_scroll_y / max_scroll;
            const thumb_y = sb_track_rect.min[1] + thumb_y_ratio * (sb_track_rect.height() - thumb_height);
            const thumb_rect = Rect.fromXYWH(
                sb_track_rect.min[0],
                thumb_y,
                sb_width,
                thumb_height,
            );

            self.drawFilledRect(sb_track_rect, zcolors.withAlpha(self.theme.colors.border, 0.3));

            const is_hovered = thumb_rect.contains(.{ self.mouse_x, self.mouse_y });
            const thumb_color = if (self.debug_scrollbar_dragging)
                self.theme.colors.primary
            else if (is_hovered)
                zcolors.blend(self.theme.colors.border, self.theme.colors.primary, 0.5)
            else
                self.theme.colors.border;
            self.drawFilledRect(thumb_rect, thumb_color);

            if (self.mouse_clicked and is_hovered) {
                self.debug_scrollbar_dragging = true;
                self.debug_scrollbar_drag_start_y = self.mouse_y;
                self.debug_scrollbar_drag_start_scroll_y = self.debug_scroll_y;
            }

            if (self.debug_scrollbar_dragging) {
                if (self.mouse_down) {
                    const delta_y = self.mouse_y - self.debug_scrollbar_drag_start_y;
                    const scroll_per_pixel = max_scroll / (sb_track_rect.height() - thumb_height);
                    self.debug_scroll_y = self.debug_scrollbar_drag_start_scroll_y + delta_y * scroll_per_pixel;
                } else {
                    self.debug_scrollbar_dragging = false;
                }
            }
        } else {
            self.debug_scrollbar_dragging = false;
        }

        if (self.debug_selected_index) |sel_idx| {
            if (sel_idx < self.debug_events.items.len) {
                if (self.drawButtonWidget(copy_btn_rect, "Copy", .{ .variant = .secondary })) {
                    const entry = self.debug_events.items[sel_idx];
                    const to_copy = self.formatDebugEventLine(entry) catch "";
                    if (to_copy.len > 0) {
                        const buf = self.allocator.alloc(u8, to_copy.len + 1) catch {
                            self.allocator.free(to_copy);
                            return;
                        };
                        @memcpy(buf[0..to_copy.len], to_copy);
                        buf[to_copy.len] = 0;
                        const zslice: [:0]const u8 = buf[0..to_copy.len :0];
                        zapp.clipboard.setTextZ(zslice);
                        self.allocator.free(buf);
                        self.allocator.free(to_copy);
                    }
                }
            }
        }
    }

    fn makeDebugFoldKey(event_id: u64, line_index: usize) DebugFoldKey {
        return .{
            .event_id = event_id,
            .line_index = @intCast(line_index),
        };
    }

    fn isDebugBlockCollapsed(self: *App, event_id: u64, line_index: usize) bool {
        return self.debug_folded_blocks.contains(makeDebugFoldKey(event_id, line_index));
    }

    fn toggleDebugBlockCollapsed(self: *App, event_id: u64, line_index: usize) void {
        const key = makeDebugFoldKey(event_id, line_index);
        if (self.debug_folded_blocks.contains(key)) {
            _ = self.debug_folded_blocks.remove(key);
            return;
        }
        self.debug_folded_blocks.put(key, {}) catch {};
    }

    fn pruneDebugFoldStateForEvent(self: *App, event_id: u64) void {
        var to_remove: std.ArrayList(DebugFoldKey) = .empty;
        defer to_remove.deinit(self.allocator);

        var it = self.debug_folded_blocks.keyIterator();
        while (it.next()) |key_ptr| {
            if (key_ptr.*.event_id == event_id) {
                to_remove.append(self.allocator, key_ptr.*) catch return;
            }
        }
        for (to_remove.items) |key| {
            _ = self.debug_folded_blocks.remove(key);
        }
    }

    fn countVisibleDebugPayloadRows(self: *App, output_min_x: f32, content_max_x: f32, entry: DebugEventEntry) usize {
        const fold_marker_w = self.measureText("[-]") + self.measureText(" ");
        var rows: usize = 0;
        var line_index: usize = 0;
        while (line_index < entry.payload_lines.items.len) {
            const meta = entry.payload_lines.items[line_index];
            const line = entry.payload_json[meta.start..meta.end];
            const indent_width = @as(f32, @floatFromInt(meta.indent_spaces)) * self.measureText(" ");
            const line_x_base = output_min_x + 8.0 + indent_width;
            const content_start = @min(meta.indent_spaces, line.len);
            const content = line[content_start..];

            const can_fold = meta.opens_block and meta.matching_close_index != null and
                @as(usize, @intCast(meta.matching_close_index.?)) > line_index + 1;
            const text_x = if (can_fold) line_x_base + fold_marker_w else line_x_base;
            rows += self.measureJsonLineWrapRows(text_x, content_max_x, content);

            if (meta.opens_block and meta.matching_close_index != null and
                @as(usize, @intCast(meta.matching_close_index.?)) > line_index + 1 and
                self.isDebugBlockCollapsed(entry.id, line_index))
            {
                line_index = @as(usize, @intCast(meta.matching_close_index.?)) + 1;
            } else {
                line_index += 1;
            }
        }
        return rows;
    }

    fn measureJsonLineWrapRows(self: *App, line_x: f32, max_x: f32, line: []const u8) usize {
        const line_height = self.textLineHeight();
        const available_w = @max(1.0, max_x - line_x);
        const h = self.measureTextWrappedHeight(available_w, line);

        var rows: usize = 1;
        var remaining = h - line_height;
        while (remaining > line_height * 0.05) : (rows += 1) {
            remaining -= line_height;
        }
        return rows;
    }

    fn debugCategoryColor(self: *App, category: []const u8) [4]f32 {
        if (std.mem.indexOf(u8, category, "error") != null) {
            return zcolors.rgba(196, 74, 74, 255);
        }
        if (std.mem.startsWith(u8, category, "control.")) {
            return zcolors.blend(self.theme.colors.primary, self.theme.colors.text_primary, 0.32);
        }
        if (std.mem.startsWith(u8, category, "session.")) {
            return zcolors.rgba(64, 134, 196, 255);
        }
        return self.theme.colors.text_primary;
    }

    fn drawDebugEventHeaderLine(self: *App, x: f32, y: f32, max_x: f32, entry: DebugEventEntry) void {
        var ts_buf: [64]u8 = undefined;
        const ts = std.fmt.bufPrint(&ts_buf, "{d}", .{entry.timestamp_ms}) catch "0";
        const line_height = self.textLineHeight();

        // Use a fixed timestamp column so category text never overlaps when
        // text measurement is slightly off relative to actual glyph widths.
        const ts_col_w = 116.0 * self.ui_scale;
        const ts_max_w = @max(0.0, @min(ts_col_w, max_x - x));
        self.drawTextTrimmed(x, y, ts_max_w, ts, self.theme.colors.text_secondary);

        const cursor_x = x + ts_col_w + 6.0 * self.ui_scale;
        if (cursor_x >= max_x) return;

        const category_max = @max(0.0, max_x - cursor_x);
        var category_w = self.measureText(entry.category);
        if (category_w > category_max) category_w = category_max;
        self.drawTextTrimmed(cursor_x, y, category_max, entry.category, self.debugCategoryColor(entry.category));

        if (entry.correlation_id) |value| {
            const badge_text = std.fmt.allocPrint(self.allocator, "CID:{s}", .{value}) catch null;
            if (badge_text) |text| {
                defer self.allocator.free(text);
                const badge_x = cursor_x + category_w + 8.0 * self.ui_scale;
                const remaining = max_x - badge_x;
                if (remaining > 40.0 * self.ui_scale) {
                    const badge_w = @min(remaining, self.measureText(text) + 10.0 * self.ui_scale);
                    const badge_h = line_height;
                    const badge_rect = Rect.fromXYWH(
                        badge_x,
                        y + 1.0 * self.ui_scale,
                        badge_w,
                        badge_h,
                    );
                    self.drawFilledRect(
                        badge_rect,
                        zcolors.withAlpha(self.theme.colors.primary, 0.22),
                    );
                    self.drawTextTrimmed(
                        badge_rect.min[0] + 4.0 * self.ui_scale,
                        y,
                        badge_w - 6.0 * self.ui_scale,
                        text,
                        self.theme.colors.text_primary,
                    );
                }
            }
        }
    }

    fn jsonTokenColor(self: *App, kind: JsonTokenKind) [4]f32 {
        return switch (kind) {
            .key => zcolors.blend(self.theme.colors.text_primary, self.theme.colors.primary, 0.5),
            .string => zcolors.rgba(48, 140, 92, 255),
            .number => zcolors.rgba(193, 126, 54, 255),
            .keyword => zcolors.rgba(137, 88, 186, 255),
            .punctuation => self.theme.colors.text_secondary,
            .plain => self.theme.colors.text_primary,
        };
    }

    fn wrappedLineBreak(self: *App, wrap_x: f32, cursor_x: *f32, cursor_y: *f32, rows: *usize) void {
        const line_height = self.textLineHeight();
        cursor_x.* = wrap_x;
        cursor_y.* += line_height;
        rows.* += 1;
    }

    fn maxFittingPrefix(self: *App, text: []const u8, max_w: f32) usize {
        if (text.len == 0 or max_w <= 0.0) return 0;
        var width: f32 = 0.0;
        var idx: usize = 0;
        var best_end: usize = 0;
        while (idx < text.len) {
            const next = nextUtf8Boundary(text, idx);
            if (next <= idx) break;
            const glyph_w = self.measureText(text[idx..next]);
            if (width + glyph_w > max_w) break;
            width += glyph_w;
            best_end = next;
            idx = next;
        }
        return best_end;
    }

    fn drawJsonTokenWrapped(
        self: *App,
        wrap_x: f32,
        cursor_x: *f32,
        cursor_y: *f32,
        max_x: f32,
        token: []const u8,
        color: [4]f32,
        rows: *usize,
    ) void {
        if (token.len == 0) return;

        var start: usize = 0;
        while (start < token.len) {
            const remaining_w = max_x - cursor_x.*;
            if (remaining_w <= 0.0) {
                if (cursor_x.* > wrap_x) {
                    self.wrappedLineBreak(wrap_x, cursor_x, cursor_y, rows);
                    continue;
                }
                const next = nextUtf8Boundary(token, start);
                const single = token[start..next];
                self.drawText(cursor_x.*, cursor_y.*, single, color);
                cursor_x.* += self.measureText(single);
                start = next;
                continue;
            }

            const rest = token[start..];
            const fit = self.maxFittingPrefix(rest, remaining_w);
            if (fit == 0) {
                if (cursor_x.* > wrap_x) {
                    self.wrappedLineBreak(wrap_x, cursor_x, cursor_y, rows);
                    continue;
                }
                const next = nextUtf8Boundary(rest, 0);
                const single = rest[0..next];
                self.drawText(cursor_x.*, cursor_y.*, single, color);
                cursor_x.* += self.measureText(single);
                start += next;
                continue;
            }

            const piece = rest[0..fit];
            self.drawText(cursor_x.*, cursor_y.*, piece, color);
            cursor_x.* += self.measureText(piece);
            start += fit;

            if (start < token.len) {
                self.wrappedLineBreak(wrap_x, cursor_x, cursor_y, rows);
            }
        }
    }

    fn isJsonDelimiter(ch: u8) bool {
        return ch == ' ' or ch == '\t' or ch == ',' or ch == ':' or ch == ']' or ch == '}' or ch == '[' or ch == '{';
    }

    fn drawJsonLineColored(self: *App, x: f32, y: f32, max_x: f32, line: []const u8) usize {
        var cursor_x = x;
        var cursor_y = y;
        var rows: usize = 1;
        var i: usize = 0;
        while (i < line.len) {
            const ch = line[i];

            if (ch == ' ' or ch == '\t') {
                var j = i + 1;
                while (j < line.len and (line[j] == ' ' or line[j] == '\t')) : (j += 1) {}
                const ws_width = self.measureText(line[i..j]);
                if (cursor_x + ws_width <= max_x) {
                    cursor_x += ws_width;
                } else if (cursor_x > x) {
                    self.wrappedLineBreak(x, &cursor_x, &cursor_y, &rows);
                }
                i = j;
                continue;
            }

            if (ch == '"') {
                var j = i + 1;
                var escaped = false;
                while (j < line.len) : (j += 1) {
                    const cur = line[j];
                    if (escaped) {
                        escaped = false;
                        continue;
                    }
                    if (cur == '\\') {
                        escaped = true;
                        continue;
                    }
                    if (cur == '"') {
                        j += 1;
                        break;
                    }
                }
                if (j > line.len) j = line.len;

                var kind: JsonTokenKind = .string;
                var k = j;
                while (k < line.len and (line[k] == ' ' or line[k] == '\t')) : (k += 1) {}
                if (k < line.len and line[k] == ':') {
                    kind = .key;
                }
                self.drawJsonTokenWrapped(x, &cursor_x, &cursor_y, max_x, line[i..j], self.jsonTokenColor(kind), &rows);
                i = j;
                continue;
            }

            if (ch == '{' or ch == '}' or ch == '[' or ch == ']' or ch == ':' or ch == ',') {
                self.drawJsonTokenWrapped(x, &cursor_x, &cursor_y, max_x, line[i .. i + 1], self.jsonTokenColor(.punctuation), &rows);
                i += 1;
                continue;
            }

            if ((ch >= '0' and ch <= '9') or ch == '-') {
                var j = i + 1;
                while (j < line.len) : (j += 1) {
                    const cur = line[j];
                    if (!((cur >= '0' and cur <= '9') or cur == '.' or cur == 'e' or cur == 'E' or cur == '+' or cur == '-')) {
                        break;
                    }
                }
                self.drawJsonTokenWrapped(x, &cursor_x, &cursor_y, max_x, line[i..j], self.jsonTokenColor(.number), &rows);
                i = j;
                continue;
            }

            if (std.mem.startsWith(u8, line[i..], "true")) {
                const end = i + 4;
                if (end == line.len or isJsonDelimiter(line[end])) {
                    self.drawJsonTokenWrapped(x, &cursor_x, &cursor_y, max_x, line[i..end], self.jsonTokenColor(.keyword), &rows);
                    i = end;
                    continue;
                }
            }
            if (std.mem.startsWith(u8, line[i..], "false")) {
                const end = i + 5;
                if (end == line.len or isJsonDelimiter(line[end])) {
                    self.drawJsonTokenWrapped(x, &cursor_x, &cursor_y, max_x, line[i..end], self.jsonTokenColor(.keyword), &rows);
                    i = end;
                    continue;
                }
            }
            if (std.mem.startsWith(u8, line[i..], "null")) {
                const end = i + 4;
                if (end == line.len or isJsonDelimiter(line[end])) {
                    self.drawJsonTokenWrapped(x, &cursor_x, &cursor_y, max_x, line[i..end], self.jsonTokenColor(.keyword), &rows);
                    i = end;
                    continue;
                }
            }

            var j = i + 1;
            while (j < line.len) : (j += 1) {
                const cur = line[j];
                if (cur == '"' or cur == ' ' or cur == '\t' or cur == '{' or cur == '}' or cur == '[' or cur == ']' or cur == ',' or cur == ':') {
                    break;
                }
            }
            self.drawJsonTokenWrapped(x, &cursor_x, &cursor_y, max_x, line[i..j], self.jsonTokenColor(.plain), &rows);
            i = j;
        }
        return rows;
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

        const inner = @max(self.theme.spacing.xs, 6.0 * self.ui_scale);
        const line_height = self.textLineHeight();
        const indicator_size = @max(10.0 * self.ui_scale, line_height * 0.58);
        const indicator_y = rect.min[1] + @max(0.0, (rect.height() - indicator_size) * 0.5);
        const indicator = Rect.fromXYWH(rect.min[0] + inner, indicator_y, indicator_size, indicator_size);
        const dot = switch (self.connection_state) {
            .disconnected => zcolors.rgba(200, 80, 80, 255),
            .connecting => zcolors.rgba(220, 200, 60, 255),
            .connected => zcolors.rgba(90, 210, 90, 255),
            .error_state => zcolors.rgba(230, 120, 70, 255),
        };
        self.drawFilledRect(indicator, dot);

        self.drawTextTrimmed(
            indicator.max[0] + inner,
            rect.min[1] + @max(0.0, (rect.height() - line_height) * 0.5),
            rect.width() - (indicator.max[0] - rect.min[0]) - inner * 2.0,
            self.status_text,
            self.theme.colors.text_primary,
        );
    }

    fn drawVerticalScrollbar(
        self: *App,
        target: FormScrollTarget,
        viewport_rect: Rect,
        content_height: f32,
        scroll_y: *f32,
    ) void {
        const viewport_height = viewport_rect.height();
        const max_scroll = if (content_height > viewport_height) content_height - viewport_height else 0.0;
        if (scroll_y.* < 0.0) scroll_y.* = 0.0;
        if (scroll_y.* > max_scroll) scroll_y.* = max_scroll;
        if (max_scroll <= 0.0) {
            if (self.form_scroll_drag_target == target) self.form_scroll_drag_target = .none;
            return;
        }

        const inset = @max(1.0, 2.0 * self.ui_scale);
        const track_w = @max(self.theme.spacing.xs, 8.0 * self.ui_scale);
        const track_rect = Rect.fromXYWH(
            viewport_rect.max[0] - track_w - inset,
            viewport_rect.min[1] + inset,
            track_w,
            @max(8.0, viewport_rect.height() - inset * 2.0),
        );

        const thumb_height = @max(20.0 * self.ui_scale, track_rect.height() * (viewport_height / content_height));
        const thumb_range = @max(1.0, track_rect.height() - thumb_height);
        const thumb_ratio = if (max_scroll > 0.0) scroll_y.* / max_scroll else 0.0;
        const thumb_y = track_rect.min[1] + thumb_ratio * thumb_range;
        const thumb_rect = Rect.fromXYWH(track_rect.min[0], thumb_y, track_w, thumb_height);

        if (self.form_scroll_drag_target == target) {
            if (self.mouse_down) {
                const scroll_per_px = max_scroll / thumb_range;
                const delta_y = self.mouse_y - self.form_scroll_drag_start_y;
                scroll_y.* = std.math.clamp(
                    self.form_scroll_drag_start_scroll_y + delta_y * scroll_per_px,
                    0.0,
                    max_scroll,
                );
            } else {
                self.form_scroll_drag_target = .none;
            }
        } else if (self.mouse_clicked and track_rect.contains(.{ self.mouse_x, self.mouse_y })) {
            const raw = (self.mouse_y - track_rect.min[1] - thumb_height * 0.5) / thumb_range;
            const click_ratio = std.math.clamp(raw, 0.0, 1.0);
            scroll_y.* = click_ratio * max_scroll;
            self.form_scroll_drag_target = target;
            self.form_scroll_drag_start_y = self.mouse_y;
            self.form_scroll_drag_start_scroll_y = scroll_y.*;
        }

        self.drawFilledRect(track_rect, zcolors.withAlpha(self.theme.colors.border, 0.25));
        const hovered = thumb_rect.contains(.{ self.mouse_x, self.mouse_y });
        const active = self.form_scroll_drag_target == target;
        const thumb_color = if (active)
            self.theme.colors.primary
        else if (hovered)
            zcolors.blend(self.theme.colors.border, self.theme.colors.primary, 0.46)
        else
            self.theme.colors.border;
        self.drawFilledRect(thumb_rect, thumb_color);
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
            self.mouse_released,
            currently_focused,
        );

        const fill = widgets.text_input.getFillPaint(self.theme, state, opts);
        const border = widgets.text_input.getBorderColor(self.theme, state, opts);

        self.drawPaintRect(rect, fill);
        self.drawRect(rect, border);

        const text_pad_x = @max(self.theme.spacing.sm, 8.0 * self.ui_scale);
        const text_x = rect.min[0] + text_pad_x;
        const max_w = rect.width() - text_pad_x * 2.0;
        const line_height = self.textLineHeight();
        const text_y = rect.min[1] + @max(0.0, (rect.height() - line_height) * 0.5);

        if (text.len == 0) {
            const placeholder = if (opts.placeholder.len > 0) opts.placeholder else "";
            if (placeholder.len > 0) {
                self.drawTextTrimmed(text_x, text_y, max_w, placeholder, widgets.text_input.getPlaceholderColor(self.theme));
            }
        } else {
            var text_color = self.theme.colors.text_primary;
            if (opts.disabled) text_color = zcolors.withAlpha(text_color, 0.45);
            const visible_start = self.inputTailStartForWidth(text, max_w);
            self.drawText(text_x, text_y, text[visible_start..], text_color);
        }

        if (state.focused and !opts.disabled and !opts.read_only) {
            // Draw caret using same measurement as text
            const caret_width: f32 = 2.0 * self.ui_scale;
            const caret_height = line_height;

            const visible_start = self.inputTailStartForWidth(text, max_w);
            const caret_offset = self.measureText(text[visible_start..]);
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

    fn selectedProjectToken(self: *App, project_id: []const u8) ?[]const u8 {
        if (project_id.len == 0) return null;
        if (self.settings_panel.project_token.items.len > 0) return self.settings_panel.project_token.items;
        return self.config.getProjectToken(project_id);
    }

    fn selectedAgentId(self: *App) ?[]const u8 {
        if (self.settings_panel.default_agent.items.len > 0) return self.settings_panel.default_agent.items;
        return self.config.selectedAgent();
    }

    fn parseAgentFromSessionListPayload(
        self: *App,
        payload_json: []const u8,
        preferred_session_key: []const u8,
    ) ![]u8 {
        var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, payload_json, .{});
        defer parsed.deinit();
        if (parsed.value != .object) return error.InvalidResponse;

        const root = parsed.value.object;
        const active_session_key = if (root.get("active_session")) |value| switch (value) {
            .string => value.string,
            else => null,
        } else null;
        const sessions = root.get("sessions") orelse return error.InvalidResponse;
        if (sessions != .array) return error.InvalidResponse;

        var preferred_agent: ?[]const u8 = null;
        var active_agent: ?[]const u8 = null;
        var fallback_agent: ?[]const u8 = null;
        for (sessions.array.items) |entry| {
            if (entry != .object) continue;
            const session_key = if (entry.object.get("session_key")) |value| switch (value) {
                .string => value.string,
                else => null,
            } else null;
            const agent_id = if (entry.object.get("agent_id")) |value| switch (value) {
                .string => value.string,
                else => null,
            } else null;
            if (session_key == null or agent_id == null) continue;
            if (fallback_agent == null) fallback_agent = agent_id;
            if (active_session_key != null and std.mem.eql(u8, active_session_key.?, session_key.?)) {
                active_agent = agent_id;
            }
            if (std.mem.eql(u8, preferred_session_key, session_key.?)) {
                preferred_agent = agent_id;
            }
        }

        const selected = preferred_agent orelse active_agent orelse fallback_agent orelse return error.InvalidResponse;
        return self.allocator.dupe(u8, selected);
    }

    fn fetchDefaultAgentFromServer(
        self: *App,
        client: *ws_client_mod.WebSocketClient,
        preferred_session_key: []const u8,
    ) ![]u8 {
        const payload_json = try control_plane.requestControlPayloadJson(
            self.allocator,
            client,
            &self.message_counter,
            "control.session_list",
            null,
        );
        defer self.allocator.free(payload_json);
        return self.parseAgentFromSessionListPayload(payload_json, preferred_session_key);
    }

    fn buildSessionAttachPayload(
        self: *App,
        session_key: []const u8,
        agent_id: []const u8,
        project_id: ?[]const u8,
        project_token: ?[]const u8,
    ) ![]u8 {
        const escaped_session = try jsonEscape(self.allocator, session_key);
        defer self.allocator.free(escaped_session);
        const escaped_agent = try jsonEscape(self.allocator, agent_id);
        defer self.allocator.free(escaped_agent);

        var out = std.ArrayListUnmanaged(u8){};
        defer out.deinit(self.allocator);
        try out.writer(self.allocator).print(
            "{{\"session_key\":\"{s}\",\"agent_id\":\"{s}\"",
            .{ escaped_session, escaped_agent },
        );
        if (project_id) |project| {
            const escaped_project = try jsonEscape(self.allocator, project);
            defer self.allocator.free(escaped_project);
            try out.writer(self.allocator).print(",\"project_id\":\"{s}\"", .{escaped_project});
        }
        if (project_token) |token| {
            const escaped_token = try jsonEscape(self.allocator, token);
            defer self.allocator.free(escaped_token);
            try out.writer(self.allocator).print(",\"project_token\":\"{s}\"", .{escaped_token});
        }
        try out.append(self.allocator, '}');
        return out.toOwnedSlice(self.allocator);
    }

    fn setDefaultAgentInSettings(self: *App, agent_id: []const u8) !void {
        self.settings_panel.default_agent.clearRetainingCapacity();
        if (agent_id.len > 0) {
            try self.settings_panel.default_agent.appendSlice(self.allocator, agent_id);
        }
    }

    fn attachSessionBindingWithProject(
        self: *App,
        client: *ws_client_mod.WebSocketClient,
        session_key: []const u8,
        project_id: ?[]const u8,
        project_token: ?[]const u8,
    ) !void {
        const resolved_agent = if (self.selectedAgentId()) |value| blk: {
            // Prevent stale persisted user-scoped agent ids from being reused on admin connects.
            if (self.config.active_role == .admin and isUserScopedAgentId(value)) {
                break :blk try self.fetchDefaultAgentFromServer(client, session_key);
            }
            break :blk try self.allocator.dupe(u8, value);
        } else try self.fetchDefaultAgentFromServer(client, session_key);
        defer self.allocator.free(resolved_agent);

        const payload_json = try self.buildSessionAttachPayload(
            session_key,
            resolved_agent,
            project_id,
            project_token,
        );
        defer self.allocator.free(payload_json);

        const response_payload = try control_plane.requestControlPayloadJsonWithTimeout(
            self.allocator,
            client,
            &self.message_counter,
            "control.session_attach",
            payload_json,
            CONTROL_SESSION_ATTACH_TIMEOUT_MS,
        );
        defer self.allocator.free(response_payload);

        try self.setDefaultAgentInSettings(resolved_agent);
    }

    fn attachSessionBinding(self: *App, client: *ws_client_mod.WebSocketClient, session_key: []const u8) !void {
        const project_id = self.selectedProjectId();
        const project_token = if (project_id) |value|
            self.selectedProjectToken(value)
        else
            null;
        try self.attachSessionBindingWithProject(
            client,
            session_key,
            project_id,
            project_token,
        );
    }

    fn tryConnect(self: *App, manager: *panel_manager.PanelManager) !void {
        if (self.settings_panel.server_url.items.len == 0) {
            self.setConnectionState(.error_state, "Server URL cannot be empty");
            return;
        }

        const had_pending_send = self.pending_send_message_id != null;
        self.setConnectionState(.connecting, "Connecting...");
        if (self.ws_client) |*existing| {
            while (existing.tryReceive()) |msg| self.allocator.free(msg);
            existing.deinit();
            self.ws_client = null;
        }
        self.debug_stream_enabled = false;
        self.debug_stream_pending = false;
        self.clearPendingDebugRequest();

        const effective_url = self.settings_panel.server_url.items;

        // Keep the Project panel operator token authoritative for admin auth:
        // if the user typed one, sync it into config before selecting connect token.
        if (self.settings_panel.project_operator_token.items.len > 0) {
            const entered_admin_token = std.mem.trim(u8, self.settings_panel.project_operator_token.items, " \t");
            if (entered_admin_token.len > 0 and !std.mem.eql(u8, self.config.getRoleToken(.admin), entered_admin_token)) {
                self.config.setRoleToken(.admin, entered_admin_token) catch {};
                self.config.save() catch {};
            }
        }

        const selected_role_token = self.config.getRoleToken(self.config.active_role);
        const connect_token = if (selected_role_token.len > 0)
            selected_role_token
        else
            self.config.activeRoleToken();
        const ws_client = ws_client_mod.WebSocketClient.init(self.allocator, effective_url, connect_token) catch |err| {
            const msg = try std.fmt.allocPrint(self.allocator, "Client init failed: {s}", .{@errorName(err)});
            defer self.allocator.free(msg);
            self.setConnectionState(.error_state, msg);
            return;
        };
        self.ws_client = ws_client;

        self.ws_client.?.connect() catch |err| {
            self.ws_client.?.deinit();
            self.ws_client = null;
            const msg = try std.fmt.allocPrint(self.allocator, "Connect failed: {s}", .{@errorName(err)});
            defer self.allocator.free(msg);
            self.setConnectionState(.error_state, msg);
            return;
        };

        var attach_warning: ?[]u8 = null;
        defer if (attach_warning) |value| self.allocator.free(value);

        if (self.ws_client) |*client| {
            control_plane.ensureUnifiedV2Connection(self.allocator, client, &self.message_counter) catch |err| {
                client.deinit();
                self.ws_client = null;
                const msg = if (err == error.RemoteError) blk: {
                    if (control_plane.lastRemoteError()) |remote| {
                        break :blk try std.fmt.allocPrint(self.allocator, "Handshake failed: {s}", .{remote});
                    }
                    break :blk try std.fmt.allocPrint(self.allocator, "Handshake failed: {s}", .{@errorName(err)});
                } else try std.fmt.allocPrint(self.allocator, "Handshake failed: {s}", .{@errorName(err)});
                defer self.allocator.free(msg);
                self.setConnectionState(.error_state, msg);
                return;
            };

            if (self.settings_panel.default_session.items.len == 0) {
                if (self.config.default_session) |default_session| {
                    const seed = if (default_session.len > 0) default_session else "main";
                    try self.settings_panel.default_session.appendSlice(self.allocator, seed);
                } else {
                    try self.settings_panel.default_session.appendSlice(self.allocator, "main");
                }
            }
            const attach_session = self.settings_panel.default_session.items;
            try self.ensureSessionExists(attach_session, attach_session);

            self.attachSessionBinding(client, attach_session) catch |err| {
                const primary_detail_owned = try self.allocator.dupe(
                    u8,
                    control_plane.lastRemoteError() orelse @errorName(err),
                );
                defer self.allocator.free(primary_detail_owned);

                const has_selected_project = self.selectedProjectId() != null;
                if (has_selected_project) {
                    std.log.warn(
                        "Session attach with selected project failed; retrying default attach: {s}",
                        .{primary_detail_owned},
                    );
                    var fallback_ok = true;
                    self.attachSessionBindingWithProject(client, attach_session, null, null) catch |fallback_err| {
                        fallback_ok = false;
                        const fallback_detail = control_plane.lastRemoteError() orelse @errorName(fallback_err);
                        std.log.err(
                            "Session attach failed with selected project ({s}); fallback attach also failed ({s})",
                            .{ primary_detail_owned, fallback_detail },
                        );
                        attach_warning = try std.fmt.allocPrint(
                            self.allocator,
                            "Session attach failed: {s} (fallback also failed: {s}). Continuing with default server session binding.",
                            .{ primary_detail_owned, fallback_detail },
                        );
                    };
                    if (fallback_ok) {
                        attach_warning = try std.fmt.allocPrint(
                            self.allocator,
                            "Selected project attach failed ({s}); connected using default project. Update project/token in Settings.",
                            .{primary_detail_owned},
                        );
                    }
                } else {
                    std.log.err("Session attach failed: {s}", .{primary_detail_owned});
                    attach_warning = try std.fmt.allocPrint(
                        self.allocator,
                        "Session attach failed ({s}); continuing with default server session binding.",
                        .{primary_detail_owned},
                    );
                }
            };
        }

        self.setConnectionState(.connected, "Connected");
        self.settings_panel.focused_field = .none;

        // Save URL to config on successful connect.
        // Do not persist fallback tokens into the selected role.
        if (selected_role_token.len > 0) {
            self.config.setRoleToken(self.config.active_role, connect_token) catch {};
        }
        if (self.settings_panel.default_session.items.len == 0) {
            try self.settings_panel.default_session.appendSlice(self.allocator, "main");
        }
        self.syncSettingsToConfig() catch |err| {
            std.log.warn("Failed to save config on connect: {s}", .{@errorName(err)});
        };
        self.refreshWorkspaceData() catch |err| {
            const msg = self.formatControlOpError("Workspace refresh failed", err);
            if (msg) |text| {
                defer self.allocator.free(text);
                self.setWorkspaceError(text);
            }
        };

        if (self.chat_sessions.items.len == 0) {
            try self.ensureSessionExists("main", "Main");
        } else if (self.current_session_key == null) {
            try self.setCurrentSessionKey(self.chat_sessions.items[0].key);
        }

        if (attach_warning) |warning| {
            self.setWorkspaceError(warning);
            try self.appendMessage("system", warning, null);
        }

        if (had_pending_send and try self.tryResumePendingSendJob()) {
            try self.appendMessage("system", "Reconnected to Spiderweb and resumed pending job.", null);
        } else if (had_pending_send) {
            try self.appendMessage("system", "Reconnected to Spiderweb. Pending job not ready yet.", null);
        } else {
            try self.appendMessage("system", "Connected to Spiderweb", null);
        }

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

    fn ensureWorkspacePanel(self: *App, manager: *panel_manager.PanelManager) void {
        for (manager.workspace.panels.items) |*panel| {
            if (panel.kind == .Settings or panel.kind == .Control) {
                manager.focusPanel(panel.id);
                return;
            }
        }
        manager.ensurePanel(.Control);
        self.focusSettingsPanel(manager);
    }

    fn focusedFormScrollTarget(self: *App, manager: *panel_manager.PanelManager) FormScrollTarget {
        const focused_id = manager.workspace.focused_panel_id orelse return .none;
        const panel = self.findPanelById(manager, focused_id) orelse return .none;
        if (panel.kind == .Settings or panel.kind == .Control) return .settings;
        if (self.project_panel_id != null and self.project_panel_id.? == focused_id) return .projects;
        if (panel.kind == .ToolOutput and std.mem.eql(u8, panel.title, "Projects")) return .projects;
        return .none;
    }

    fn focusedFormScrollY(self: *App, manager: *panel_manager.PanelManager) ?*f32 {
        return switch (self.focusedFormScrollTarget(manager)) {
            .settings => &self.settings_panel.settings_scroll_y,
            .projects => &self.settings_panel.projects_scroll_y,
            .none => null,
        };
    }

    fn hasPanelWithTitle(_: *App, manager: *panel_manager.PanelManager, title: []const u8) bool {
        for (manager.workspace.panels.items) |*panel| {
            if (std.mem.eql(u8, panel.title, title)) return true;
        }
        return false;
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
        self.debug_stream_enabled = false;
        self.debug_stream_pending = false;
        self.clearPendingDebugRequest();
        self.clearWorkspaceData();
        self.clearFilesystemData();
    }

    fn saveConfig(self: *App) !void {
        if (self.settings_panel.default_session.items.len == 0) {
            try self.settings_panel.default_session.appendSlice(self.allocator, "main");
        }
        try self.syncSettingsToConfig();
    }

    fn requestDebugSubscription(self: *App, enable: bool) !void {
        if (self.debug_stream_pending) return;
        if (self.debug_stream_enabled == enable) return;

        if (self.ws_client) |*client| {
            const request_id = try self.nextMessageId("debug");
            defer self.allocator.free(request_id);
            const action = if (enable) "debug.subscribe" else "debug.unsubscribe";
            const payload = try protocol_messages.buildAgentControl(self.allocator, request_id, action, null);
            defer self.allocator.free(payload);
            try self.setPendingDebugRequest(request_id);
            self.debug_stream_pending = true;
            client.send(payload) catch |err| {
                self.debug_stream_pending = false;
                self.clearPendingDebugRequest();
                return err;
            };
            return;
        }

        try self.appendMessage("system", "Debug stream requires an active websocket connection", null);
    }

    fn sendChatMessageText(self: *App, text: []const u8) !void {
        if (text.len == 0) return;
        std.log.info("[GUI] sendChatMessageText: text_len={d} connected={}", .{ text.len, self.ws_client != null });
        if (self.awaiting_reply) {
            try self.appendMessage("system", "Wait for the current send to finish.", null);
            return;
        }
        const client = if (self.ws_client) |*value|
            value
        else {
            try self.appendMessage("system", "No active websocket connection", null);
            return;
        };

        // Keep a session key for this send
        const session_key = try self.currentSessionOrDefault();
        if (session_key.len == 0) {
            try self.appendMessage("system", "No active session available", null);
            return;
        }
        self.attachSessionBinding(client, session_key) catch |err| {
            const detail = control_plane.lastRemoteError() orelse @errorName(err);
            const err_text = try std.fmt.allocPrint(self.allocator, "Session attach failed: {s}", .{detail});
            defer self.allocator.free(err_text);
            try self.appendMessage("system", err_text, null);
            return err;
        };

        const user_msg_id = try self.nextMessageId("msg");
        const appended_user_msg_id = try self.appendMessageWithIdForSession(session_key, "user", text, .sending, user_msg_id);
        defer self.allocator.free(appended_user_msg_id);
        self.allocator.free(user_msg_id);
        try self.setPendingSend(self.allocator, appended_user_msg_id, session_key);

        const request_id = try self.nextMessageId("send");
        defer self.allocator.free(request_id);
        if (self.pending_send_request_id) |value| {
            self.allocator.free(value);
            self.pending_send_request_id = null;
        }
        self.pending_send_request_id = try self.allocator.dupe(u8, request_id);
        self.awaiting_reply = true;

        const payload = try protocol_messages.buildSessionSend(self.allocator, request_id, text, session_key);
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
            return err;
        };
    }

    fn nextFsrpcTag(self: *App) u32 {
        const tag = self.next_fsrpc_tag;
        self.next_fsrpc_tag +%= 1;
        if (self.next_fsrpc_tag == 0) self.next_fsrpc_tag = 1;
        return tag;
    }

    fn nextFsrpcFid(self: *App) u32 {
        const fid = self.next_fsrpc_fid;
        self.next_fsrpc_fid +%= 1;
        if (self.next_fsrpc_fid == 0 or self.next_fsrpc_fid == 1) self.next_fsrpc_fid = 2;
        return fid;
    }

    fn sendAndAwaitFsrpc(
        self: *App,
        client: *ws_client_mod.WebSocketClient,
        request_json: []const u8,
        tag: u32,
        timeout_ms: u32,
    ) !FsrpcEnvelope {
        try client.send(request_json);

        const started = std.time.milliTimestamp();
        while (std.time.milliTimestamp() - started < timeout_ms) {
            if (client.receive(500)) |raw| {
                const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, raw, .{}) catch {
                    self.allocator.free(raw);
                    continue;
                };

                var matched = false;
                if (parsed.value == .object) {
                    const obj = parsed.value.object;
                    if (obj.get("channel")) |channel| {
                        if (channel == .string and std.mem.eql(u8, channel.string, "fsrpc")) {
                            if (obj.get("tag")) |raw_tag| {
                                if (raw_tag == .integer and raw_tag.integer >= 0 and @as(u32, @intCast(raw_tag.integer)) == tag) {
                                    matched = true;
                                }
                            }
                        }
                    }
                }

                if (matched) {
                    return .{
                        .raw = raw,
                        .parsed = parsed,
                    };
                }

                parsed.deinit();
                self.handleIncomingMessage(raw) catch |err| {
                    std.log.warn("[GUI] dropped out-of-band frame while awaiting fsrpc tag={d}: {s}", .{ tag, @errorName(err) });
                };
                self.allocator.free(raw);
            }
        }

        return error.Timeout;
    }

    fn ensureFsrpcOk(self: *App, envelope: *FsrpcEnvelope) !void {
        if (envelope.parsed.value != .object) return error.InvalidResponse;
        const obj = envelope.parsed.value.object;
        const ok_value = obj.get("ok") orelse return error.InvalidResponse;
        if (ok_value != .bool) return error.InvalidResponse;
        if (ok_value.bool) {
            self.clearFsrpcRemoteError();
            return;
        }

        var detail: ?[]u8 = null;
        if (obj.get("error")) |err_value| {
            if (err_value == .object) {
                const err_obj = err_value.object;
                const message = if (err_obj.get("message")) |value|
                    if (value == .string) value.string else null
                else
                    null;
                const code = if (err_obj.get("code")) |value|
                    if (value == .string) value.string else null
                else
                    null;
                const errno = if (err_obj.get("errno")) |value|
                    if (value == .integer) value.integer else null
                else
                    null;

                if (message != null and code != null and errno != null) {
                    detail = std.fmt.allocPrint(self.allocator, "{s} [{s}] (errno={d})", .{ message.?, code.?, errno.? }) catch null;
                } else if (message != null and errno != null) {
                    detail = std.fmt.allocPrint(self.allocator, "{s} (errno={d})", .{ message.?, errno.? }) catch null;
                } else if (message != null and code != null) {
                    detail = std.fmt.allocPrint(self.allocator, "{s} [{s}]", .{ message.?, code.? }) catch null;
                } else if (message) |value| {
                    detail = self.allocator.dupe(u8, value) catch null;
                } else if (code) |value| {
                    detail = std.fmt.allocPrint(self.allocator, "remote fsrpc error [{s}]", .{value}) catch null;
                } else if (errno) |value| {
                    detail = std.fmt.allocPrint(self.allocator, "remote fsrpc error (errno={d})", .{value}) catch null;
                }
            } else if (err_value == .string) {
                detail = self.allocator.dupe(u8, err_value.string) catch null;
            }
        }

        if (detail) |value| {
            defer self.allocator.free(value);
            self.setFsrpcRemoteError(value);
        } else {
            self.setFsrpcRemoteError("remote fsrpc error");
        }
        return error.RemoteError;
    }

    fn getFsrpcPayloadObject(self: *App, root: std.json.ObjectMap) !std.json.ObjectMap {
        _ = self;
        const payload = root.get("payload") orelse return error.InvalidResponse;
        if (payload != .object) return error.InvalidResponse;
        return payload.object;
    }

    fn fsrpcBootstrapGui(self: *App, client: *ws_client_mod.WebSocketClient) !void {
        try control_plane.ensureUnifiedV2Connection(
            self.allocator,
            client,
            &self.message_counter,
        );

        const version_tag = self.nextFsrpcTag();
        const version_req = try std.fmt.allocPrint(
            self.allocator,
            "{{\"channel\":\"fsrpc\",\"type\":\"fsrpc.t_version\",\"tag\":{d},\"msize\":1048576,\"version\":\"styx-lite-1\"}}",
            .{version_tag},
        );
        defer self.allocator.free(version_req);
        var version = try self.sendAndAwaitFsrpc(client, version_req, version_tag, FSRPC_DEFAULT_TIMEOUT_MS);
        defer version.deinit(self.allocator);
        try self.ensureFsrpcOk(&version);

        const attach_tag = self.nextFsrpcTag();
        const attach_req = try std.fmt.allocPrint(
            self.allocator,
            "{{\"channel\":\"fsrpc\",\"type\":\"fsrpc.t_attach\",\"tag\":{d},\"fid\":1}}",
            .{attach_tag},
        );
        defer self.allocator.free(attach_req);
        var attach = try self.sendAndAwaitFsrpc(client, attach_req, attach_tag, FSRPC_DEFAULT_TIMEOUT_MS);
        defer attach.deinit(self.allocator);
        try self.ensureFsrpcOk(&attach);
    }

    fn fsrpcClunkBestEffort(self: *App, client: *ws_client_mod.WebSocketClient, fid: u32) void {
        const tag = self.nextFsrpcTag();
        const req = std.fmt.allocPrint(
            self.allocator,
            "{{\"channel\":\"fsrpc\",\"type\":\"fsrpc.t_clunk\",\"tag\":{d},\"fid\":{d}}}",
            .{ tag, fid },
        ) catch return;
        defer self.allocator.free(req);

        var response = self.sendAndAwaitFsrpc(client, req, tag, FSRPC_CLUNK_TIMEOUT_MS) catch return;
        response.deinit(self.allocator);
    }

    fn sendChatViaFsrpc(self: *App, client: *ws_client_mod.WebSocketClient, text: []const u8) ![]u8 {
        try self.fsrpcBootstrapGui(client);

        const input_fid = self.nextFsrpcFid();
        const result_fid = self.nextFsrpcFid();
        defer self.fsrpcClunkBestEffort(client, input_fid);
        defer self.fsrpcClunkBestEffort(client, result_fid);

        const walk_input_tag = self.nextFsrpcTag();
        const walk_input_req = try std.fmt.allocPrint(
            self.allocator,
            "{{\"channel\":\"fsrpc\",\"type\":\"fsrpc.t_walk\",\"tag\":{d},\"fid\":1,\"newfid\":{d},\"path\":[\"capabilities\",\"chat\",\"control\",\"input\"]}}",
            .{ walk_input_tag, input_fid },
        );
        defer self.allocator.free(walk_input_req);
        var walk_input = try self.sendAndAwaitFsrpc(client, walk_input_req, walk_input_tag, FSRPC_DEFAULT_TIMEOUT_MS);
        defer walk_input.deinit(self.allocator);
        try self.ensureFsrpcOk(&walk_input);

        const open_input_tag = self.nextFsrpcTag();
        const open_input_req = try std.fmt.allocPrint(
            self.allocator,
            "{{\"channel\":\"fsrpc\",\"type\":\"fsrpc.t_open\",\"tag\":{d},\"fid\":{d},\"mode\":\"rw\"}}",
            .{ open_input_tag, input_fid },
        );
        defer self.allocator.free(open_input_req);
        var open_input = try self.sendAndAwaitFsrpc(client, open_input_req, open_input_tag, FSRPC_DEFAULT_TIMEOUT_MS);
        defer open_input.deinit(self.allocator);
        try self.ensureFsrpcOk(&open_input);

        const encoded = try encodeDataB64(self.allocator, text);
        defer self.allocator.free(encoded);
        const write_tag = self.nextFsrpcTag();
        const write_req = try std.fmt.allocPrint(
            self.allocator,
            "{{\"channel\":\"fsrpc\",\"type\":\"fsrpc.t_write\",\"tag\":{d},\"fid\":{d},\"offset\":0,\"data_b64\":\"{s}\"}}",
            .{ write_tag, input_fid, encoded },
        );
        defer self.allocator.free(write_req);
        var write = try self.sendAndAwaitFsrpc(client, write_req, write_tag, FSRPC_CHAT_WRITE_TIMEOUT_MS);
        defer write.deinit(self.allocator);
        try self.ensureFsrpcOk(&write);

        const write_payload = try self.getFsrpcPayloadObject(write.parsed.value.object);
        const job_value = write_payload.get("job") orelse return error.InvalidResponse;
        if (job_value != .string) return error.InvalidResponse;
        const job_name = job_value.string;

        const escaped_job = try jsonEscape(self.allocator, job_name);
        defer self.allocator.free(escaped_job);
        const walk_result_tag = self.nextFsrpcTag();
        const walk_result_req = try std.fmt.allocPrint(
            self.allocator,
            "{{\"channel\":\"fsrpc\",\"type\":\"fsrpc.t_walk\",\"tag\":{d},\"fid\":1,\"newfid\":{d},\"path\":[\"jobs\",\"{s}\",\"result.txt\"]}}",
            .{ walk_result_tag, result_fid, escaped_job },
        );
        defer self.allocator.free(walk_result_req);
        var walk_result = try self.sendAndAwaitFsrpc(client, walk_result_req, walk_result_tag, FSRPC_DEFAULT_TIMEOUT_MS);
        defer walk_result.deinit(self.allocator);
        try self.ensureFsrpcOk(&walk_result);

        const open_result_tag = self.nextFsrpcTag();
        const open_result_req = try std.fmt.allocPrint(
            self.allocator,
            "{{\"channel\":\"fsrpc\",\"type\":\"fsrpc.t_open\",\"tag\":{d},\"fid\":{d},\"mode\":\"r\"}}",
            .{ open_result_tag, result_fid },
        );
        defer self.allocator.free(open_result_req);
        var open_result = try self.sendAndAwaitFsrpc(client, open_result_req, open_result_tag, FSRPC_DEFAULT_TIMEOUT_MS);
        defer open_result.deinit(self.allocator);
        try self.ensureFsrpcOk(&open_result);

        const read_tag = self.nextFsrpcTag();
        const read_req = try std.fmt.allocPrint(
            self.allocator,
            "{{\"channel\":\"fsrpc\",\"type\":\"fsrpc.t_read\",\"tag\":{d},\"fid\":{d},\"offset\":0,\"count\":1048576}}",
            .{ read_tag, result_fid },
        );
        defer self.allocator.free(read_req);
        var read = try self.sendAndAwaitFsrpc(client, read_req, read_tag, FSRPC_DEFAULT_TIMEOUT_MS);
        defer read.deinit(self.allocator);
        try self.ensureFsrpcOk(&read);

        const read_payload = try self.getFsrpcPayloadObject(read.parsed.value.object);
        const data_b64 = read_payload.get("data_b64") orelse return error.InvalidResponse;
        if (data_b64 != .string) return error.InvalidResponse;

        const decoded_len = std.base64.standard.Decoder.calcSizeForSlice(data_b64.string) catch return error.InvalidResponse;
        const decoded = try self.allocator.alloc(u8, decoded_len);
        errdefer self.allocator.free(decoded);
        _ = std.base64.standard.Decoder.decode(decoded, data_b64.string) catch return error.InvalidResponse;

        return decoded;
    }

    fn splitFsPathSegments(self: *App, path: []const u8) !std.ArrayListUnmanaged([]u8) {
        var out = std.ArrayListUnmanaged([]u8){};
        errdefer {
            for (out.items) |segment| self.allocator.free(segment);
            out.deinit(self.allocator);
        }

        const trimmed = std.mem.trim(u8, path, " \t\r\n");
        if (trimmed.len == 0 or std.mem.eql(u8, trimmed, "/")) return out;

        var iter = std.mem.splitScalar(u8, trimmed, '/');
        while (iter.next()) |raw| {
            const part = std.mem.trim(u8, raw, " \t\r\n");
            if (part.len == 0) continue;
            try out.append(self.allocator, try self.allocator.dupe(u8, part));
        }
        return out;
    }

    fn freeFsPathSegments(self: *App, segments: *std.ArrayListUnmanaged([]u8)) void {
        for (segments.items) |segment| self.allocator.free(segment);
        segments.deinit(self.allocator);
        segments.* = .{};
    }

    fn buildPathArrayJsonGui(self: *App, segments: []const []const u8) ![]u8 {
        var out = std.ArrayListUnmanaged(u8){};
        defer out.deinit(self.allocator);
        try out.append(self.allocator, '[');
        for (segments, 0..) |segment, idx| {
            if (idx > 0) try out.append(self.allocator, ',');
            const escaped = try jsonEscape(self.allocator, segment);
            defer self.allocator.free(escaped);
            try out.writer(self.allocator).print("\"{s}\"", .{escaped});
        }
        try out.append(self.allocator, ']');
        return out.toOwnedSlice(self.allocator);
    }

    fn fsrpcWalkPathGui(self: *App, client: *ws_client_mod.WebSocketClient, path: []const u8) !u32 {
        var segments = try self.splitFsPathSegments(path);
        defer self.freeFsPathSegments(&segments);
        const path_json = try self.buildPathArrayJsonGui(segments.items);
        defer self.allocator.free(path_json);

        const new_fid = self.nextFsrpcFid();
        const tag = self.nextFsrpcTag();
        const req = try std.fmt.allocPrint(
            self.allocator,
            "{{\"channel\":\"fsrpc\",\"type\":\"fsrpc.t_walk\",\"tag\":{d},\"fid\":1,\"newfid\":{d},\"path\":{s}}}",
            .{ tag, new_fid, path_json },
        );
        defer self.allocator.free(req);

        var response = try self.sendAndAwaitFsrpc(client, req, tag, FSRPC_DEFAULT_TIMEOUT_MS);
        defer response.deinit(self.allocator);
        try self.ensureFsrpcOk(&response);
        return new_fid;
    }

    fn fsrpcOpenGui(self: *App, client: *ws_client_mod.WebSocketClient, fid: u32, mode: []const u8) !void {
        const escaped_mode = try jsonEscape(self.allocator, mode);
        defer self.allocator.free(escaped_mode);
        const tag = self.nextFsrpcTag();
        const req = try std.fmt.allocPrint(
            self.allocator,
            "{{\"channel\":\"fsrpc\",\"type\":\"fsrpc.t_open\",\"tag\":{d},\"fid\":{d},\"mode\":\"{s}\"}}",
            .{ tag, fid, escaped_mode },
        );
        defer self.allocator.free(req);

        var response = try self.sendAndAwaitFsrpc(client, req, tag, FSRPC_DEFAULT_TIMEOUT_MS);
        defer response.deinit(self.allocator);
        try self.ensureFsrpcOk(&response);
    }

    fn fsrpcReadAllTextGui(self: *App, client: *ws_client_mod.WebSocketClient, fid: u32) ![]u8 {
        const tag = self.nextFsrpcTag();
        const req = try std.fmt.allocPrint(
            self.allocator,
            "{{\"channel\":\"fsrpc\",\"type\":\"fsrpc.t_read\",\"tag\":{d},\"fid\":{d},\"offset\":0,\"count\":1048576}}",
            .{ tag, fid },
        );
        defer self.allocator.free(req);

        var response = try self.sendAndAwaitFsrpc(client, req, tag, FSRPC_DEFAULT_TIMEOUT_MS);
        defer response.deinit(self.allocator);
        try self.ensureFsrpcOk(&response);

        const payload = try self.getFsrpcPayloadObject(response.parsed.value.object);
        const data_b64 = payload.get("data_b64") orelse return error.InvalidResponse;
        if (data_b64 != .string) return error.InvalidResponse;

        const decoded_len = std.base64.standard.Decoder.calcSizeForSlice(data_b64.string) catch return error.InvalidResponse;
        const decoded = try self.allocator.alloc(u8, decoded_len);
        errdefer self.allocator.free(decoded);
        _ = std.base64.standard.Decoder.decode(decoded, data_b64.string) catch return error.InvalidResponse;
        return decoded;
    }

    fn fsrpcFidIsDirGui(self: *App, client: *ws_client_mod.WebSocketClient, fid: u32) !bool {
        const tag = self.nextFsrpcTag();
        const req = try std.fmt.allocPrint(
            self.allocator,
            "{{\"channel\":\"fsrpc\",\"type\":\"fsrpc.t_stat\",\"tag\":{d},\"fid\":{d}}}",
            .{ tag, fid },
        );
        defer self.allocator.free(req);

        var response = try self.sendAndAwaitFsrpc(client, req, tag, FSRPC_DEFAULT_TIMEOUT_MS);
        defer response.deinit(self.allocator);
        try self.ensureFsrpcOk(&response);

        const payload = try self.getFsrpcPayloadObject(response.parsed.value.object);
        const kind = payload.get("kind") orelse return error.InvalidResponse;
        if (kind != .string) return error.InvalidResponse;
        return std.mem.eql(u8, kind.string, "dir");
    }

    fn readFsPathTextGui(self: *App, client: *ws_client_mod.WebSocketClient, path: []const u8) ![]u8 {
        const fid = try self.fsrpcWalkPathGui(client, path);
        defer self.fsrpcClunkBestEffort(client, fid);
        try self.fsrpcOpenGui(client, fid, "r");
        return self.fsrpcReadAllTextGui(client, fid);
    }

    fn joinFilesystemPath(self: *App, parent: []const u8, child: []const u8) ![]u8 {
        if (std.mem.eql(u8, parent, "/")) return std.fmt.allocPrint(self.allocator, "/{s}", .{child});
        if (std.mem.endsWith(u8, parent, "/")) return std.fmt.allocPrint(self.allocator, "{s}{s}", .{ parent, child });
        return std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ parent, child });
    }

    fn parentFilesystemPath(self: *App, path: []const u8) ![]u8 {
        const trimmed = std.mem.trimRight(u8, path, "/");
        if (trimmed.len == 0) return std.fmt.allocPrint(self.allocator, "/", .{});
        const idx = std.mem.lastIndexOfScalar(u8, trimmed, '/') orelse return std.fmt.allocPrint(self.allocator, "/", .{});
        if (idx == 0) return std.fmt.allocPrint(self.allocator, "/", .{});
        return std.fmt.allocPrint(self.allocator, "{s}", .{trimmed[0..idx]});
    }

    fn parseJobStatusInfo(self: *App, status_json: []const u8) !JobStatusInfo {
        var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, status_json, .{});
        defer parsed.deinit();
        if (parsed.value != .object) return error.InvalidResponse;
        const obj = parsed.value.object;

        const state_val = obj.get("state") orelse return error.InvalidResponse;
        if (state_val != .string) return error.InvalidResponse;
        var out = JobStatusInfo{
            .state = try self.allocator.dupe(u8, state_val.string),
        };
        errdefer out.deinit(self.allocator);

        if (obj.get("error")) |error_val| {
            if (error_val == .string and error_val.string.len > 0) {
                out.error_text = try self.allocator.dupe(u8, error_val.string);
            }
        }
        if (obj.get("correlation_id")) |corr_val| {
            if (corr_val == .string and corr_val.string.len > 0) {
                out.correlation_id = try self.allocator.dupe(u8, corr_val.string);
            }
        }
        return out;
    }

    fn readJobStatusGui(self: *App, client: *ws_client_mod.WebSocketClient, job_id: []const u8) !JobStatusInfo {
        const status_path = try std.fmt.allocPrint(self.allocator, "/jobs/{s}/status.json", .{job_id});
        defer self.allocator.free(status_path);
        const raw = try self.readFsPathTextGui(client, status_path);
        defer self.allocator.free(raw);
        return self.parseJobStatusInfo(raw);
    }

    fn tryResumePendingSendJob(self: *App) !bool {
        const job_id = self.pending_send_job_id orelse return false;
        const client = if (self.ws_client) |*value| value else return false;

        const now_ms = std.time.milliTimestamp();
        if (self.pending_send_last_resume_attempt_ms != 0 and now_ms - self.pending_send_last_resume_attempt_ms < 1_500) {
            return false;
        }
        self.pending_send_last_resume_attempt_ms = now_ms;

        try self.fsrpcBootstrapGui(client);
        var status = try self.readJobStatusGui(client, job_id);
        defer status.deinit(self.allocator);

        if (!std.mem.eql(u8, status.state, "done") and !std.mem.eql(u8, status.state, "failed")) {
            return false;
        }

        const result_path = try std.fmt.allocPrint(self.allocator, "/jobs/{s}/result.txt", .{job_id});
        defer self.allocator.free(result_path);
        const result = self.readFsPathTextGui(client, result_path) catch |err| blk: {
            const msg = try std.fmt.allocPrint(self.allocator, "resume read failed: {s}", .{@errorName(err)});
            break :blk msg;
        };
        defer self.allocator.free(result);

        if (std.mem.eql(u8, status.state, "failed")) {
            if (self.pending_send_message_id) |message_id| {
                try self.setMessageFailed(message_id);
            }
            if (status.error_text) |err_text| {
                const msg = try std.fmt.allocPrint(self.allocator, "Job {s} failed: {s}", .{ job_id, err_text });
                defer self.allocator.free(msg);
                try self.appendMessage("system", msg, null);
            } else {
                const msg = try std.fmt.allocPrint(self.allocator, "Job {s} failed: {s}", .{ job_id, result });
                defer self.allocator.free(msg);
                try self.appendMessage("system", msg, null);
            }
            self.clearPendingSend();
            return true;
        }

        if (self.pending_send_message_id) |message_id| {
            try self.setMessageState(message_id, null);
        }
        const session_key = if (self.pending_send_session_key) |value|
            value
        else
            try self.currentSessionOrDefault();
        try self.appendMessageForSession(session_key, "assistant", result, null);
        self.clearPendingSend();
        return true;
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
        if (self.pending_send_request_id) |value| {
            allocator.free(value);
            self.pending_send_request_id = null;
        }
        if (self.pending_send_message_id) |value| allocator.free(value);
        if (self.pending_send_session_key) |value| allocator.free(value);
        if (self.pending_send_job_id) |value| {
            allocator.free(value);
            self.pending_send_job_id = null;
        }
        if (self.pending_send_correlation_id) |value| {
            allocator.free(value);
            self.pending_send_correlation_id = null;
        }
        self.pending_send_message_id = try allocator.dupe(u8, message_id);
        self.pending_send_session_key = try allocator.dupe(u8, session_key);
        self.pending_send_resume_notified = false;
        self.pending_send_last_resume_attempt_ms = 0;
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
        if (self.pending_send_job_id) |value| {
            self.allocator.free(value);
            self.pending_send_job_id = null;
        }
        if (self.pending_send_correlation_id) |value| {
            self.allocator.free(value);
            self.pending_send_correlation_id = null;
        }
        self.pending_send_resume_notified = false;
        self.pending_send_last_resume_attempt_ms = 0;
        self.awaiting_reply = false;
    }

    fn setPendingDebugRequest(self: *App, request_id: []const u8) !void {
        self.clearPendingDebugRequest();
        self.pending_debug_request_id = try self.allocator.dupe(u8, request_id);
    }

    fn clearPendingDebugRequest(self: *App) void {
        if (self.pending_debug_request_id) |request_id| {
            self.allocator.free(request_id);
            self.pending_debug_request_id = null;
        }
    }

    fn isPendingDebugRequest(self: *App, request_id: []const u8) bool {
        if (self.pending_debug_request_id) |pending| {
            return std.mem.eql(u8, pending, request_id);
        }
        return false;
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

    fn extractRequestId(root: std.json.ObjectMap, payload: ?std.json.ObjectMap) ?[]const u8 {
        if (root.get("request_id")) |value| {
            if (value == .string) return value.string;
        }
        if (payload) |obj| {
            if (obj.get("request_id")) |value| {
                if (value == .string) return value.string;
            }
        }
        if (root.get("request")) |value| {
            if (value == .string) return value.string;
        }
        if (payload) |obj| {
            if (obj.get("request")) |value| {
                if (value == .string) return value.string;
            }
        }
        if (root.get("id")) |value| {
            if (value == .string) return value.string;
        }
        if (payload) |obj| {
            if (obj.get("id")) |value| {
                if (value == .string) return value.string;
            }
        }
        return null;
    }

    fn isJsonString(s: []const u8) bool {
        const trimmed = std.mem.trim(u8, s, " \n\r\t");
        if (trimmed.len < 2) return false;
        if (trimmed[0] == '{' and trimmed[trimmed.len - 1] == '}') return true;
        if (trimmed[0] == '[' and trimmed[trimmed.len - 1] == ']') return true;
        return false;
    }

    fn looksLikeEscaped(s: []const u8) bool {
        var i: usize = 0;
        while (i + 1 < s.len) : (i += 1) {
            if (s[i] == '\\') {
                const next_ch = s[i + 1];
                switch (next_ch) {
                    'n', 'r', 't', '"', '\\' => return true,
                    'u' => return true, // unicode escape
                    else => {},
                }
            }
        }
        return false;
    }

    fn hexVal(b: u8) ?u8 {
        if (b >= '0' and b <= '9') return b - '0';
        if (b >= 'a' and b <= 'f') return 10 + (b - 'a');
        if (b >= 'A' and b <= 'F') return 10 + (b - 'A');
        return null;
    }

    fn unescapeJsonStringAlloc(self: *App, s: []const u8) ![]u8 {
        // Allocate worst-case size; we'll slice down at the end
        var out = try self.allocator.alloc(u8, s.len);
        errdefer self.allocator.free(out);

        var j: usize = 0;
        var i: usize = 0;
        while (i < s.len) : (i += 1) {
            const ch = s[i];
            if (ch == '\\' and i + 1 < s.len) {
                const esc = s[i + 1];
                switch (esc) {
                    'n' => {
                        out[j] = '\n';
                        j += 1;
                        i += 1;
                        continue;
                    },
                    'r' => {
                        out[j] = '\r';
                        j += 1;
                        i += 1;
                        continue;
                    },
                    't' => {
                        out[j] = '\t';
                        j += 1;
                        i += 1;
                        continue;
                    },
                    '"' => {
                        out[j] = '"';
                        j += 1;
                        i += 1;
                        continue;
                    },
                    '\\' => {
                        out[j] = '\\';
                        j += 1;
                        i += 1;
                        continue;
                    },
                    'u' => {
                        // Minimal handling: keep as-is if malformed
                        if (i + 5 < s.len) {
                            // Try to parse 4 hex digits and encode as UTF-8
                            const h0 = s[i + 2];
                            const h1 = s[i + 3];
                            const h2 = s[i + 4];
                            const h3 = s[i + 5];
                            const v0 = hexVal(h0) orelse {
                                out[j] = ch;
                                j += 1;
                                continue;
                            };
                            const v1 = hexVal(h1) orelse {
                                out[j] = ch;
                                j += 1;
                                continue;
                            };
                            const v2 = hexVal(h2) orelse {
                                out[j] = ch;
                                j += 1;
                                continue;
                            };
                            const v3 = hexVal(h3) orelse {
                                out[j] = ch;
                                j += 1;
                                continue;
                            };
                            const code_unit: u16 = (@as(u16, v0) << 12) | (@as(u16, v1) << 8) | (@as(u16, v2) << 4) | @as(u16, v3);
                            var buf: [4]u8 = undefined;
                            const wrote = std.unicode.utf8Encode(@as(u21, code_unit), &buf) catch {
                                // Fallback: copy literally
                                out[j] = ch;
                                j += 1;
                                continue;
                            };
                            @memcpy(out[j .. j + wrote], buf[0..wrote]);
                            j += wrote;
                            i += 5; // consumed '\\uXXXX'
                            continue;
                        }
                        // Not enough bytes, just copy
                        out[j] = ch;
                        j += 1;
                        continue;
                    },
                    else => {
                        // Unknown escape; drop backslash and keep char
                        out[j] = esc;
                        j += 1;
                        i += 1;
                        continue;
                    },
                }
            }
            out[j] = ch;
            j += 1;
        }
        return self.allocator.realloc(out, j);
    }

    fn prettifyValue(self: *App, val: std.json.Value) error{OutOfMemory}!std.json.Value {
        switch (val) {
            .string => |s| {
                const s_trimmed = std.mem.trim(u8, s, " \n\r\t");
                if (isJsonString(s_trimmed)) {
                    const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, s_trimmed, .{}) catch null;
                    if (parsed) |p| {
                        defer p.deinit();
                        const cloned = try self.cloneJsonValue(p.value);
                        errdefer self.freePrettifiedValue(cloned);
                        const pretty = try self.prettifyValue(cloned);
                        if (!std.meta.eql(pretty, cloned)) {
                            self.freePrettifiedValue(cloned);
                        }
                        return pretty;
                    }
                }

                if (std.mem.indexOfScalar(u8, s, '\n') != null) {
                    var new_arr = std.json.Array.init(self.allocator);
                    errdefer self.freePrettifiedValue(.{ .array = new_arr });
                    var iter = std.mem.splitScalar(u8, s, '\n');
                    while (iter.next()) |line| {
                        const line_trimmed = std.mem.trimRight(u8, line, "\r");
                        // We must dupe the line because prettifyValue may transform/clone; we own and must free our duplicate
                        const duped_line = try self.allocator.dupe(u8, line_trimmed);
                        defer self.allocator.free(duped_line);
                        const v = try self.prettifyValue(.{ .string = duped_line });
                        // v is now owned. If append fails, we must free v.
                        errdefer self.freePrettifiedValue(v);
                        try new_arr.append(v);
                    }
                    return std.json.Value{ .array = new_arr };
                }

                if (looksLikeEscaped(s)) {
                    const un = self.unescapeJsonStringAlloc(s) catch return try self.cloneJsonValue(val);
                    defer self.allocator.free(un);
                    const v = try self.prettifyValue(.{ .string = un });
                    return v;
                }

                return try self.cloneJsonValue(val);
            },
            .object => |obj| {
                var new_obj = std.json.ObjectMap.init(self.allocator);
                errdefer self.freePrettifiedValue(.{ .object = new_obj });
                var iter = obj.iterator();
                while (iter.next()) |entry| {
                    const k = try self.allocator.dupe(u8, entry.key_ptr.*);
                    errdefer self.allocator.free(k);
                    const v = try self.prettifyValue(entry.value_ptr.*);
                    try new_obj.put(k, v);
                }
                return std.json.Value{ .object = new_obj };
            },
            .array => |arr| {
                var new_arr = std.json.Array.init(self.allocator);
                errdefer self.freePrettifiedValue(.{ .array = new_arr });
                for (arr.items) |v| {
                    try new_arr.append(try self.prettifyValue(v));
                }
                return std.json.Value{ .array = new_arr };
            },
            else => return val, // non-allocated types are safe to return by value
        }
    }

    fn freePrettifiedValue(self: *App, val: std.json.Value) void {
        switch (val) {
            .object => |obj| {
                var mut_obj = obj;
                var it = mut_obj.iterator();
                while (it.next()) |entry| {
                    self.allocator.free(entry.key_ptr.*);
                    self.freePrettifiedValue(entry.value_ptr.*);
                }
                mut_obj.deinit();
            },
            .array => |arr| {
                var mut_arr = arr;
                for (mut_arr.items) |v| {
                    self.freePrettifiedValue(v);
                }
                mut_arr.deinit();
            },
            .string => |s| {
                self.allocator.free(s);
            },
            else => {},
        }
    }

    fn cloneJsonValue(self: *App, val: std.json.Value) error{OutOfMemory}!std.json.Value {
        switch (val) {
            .object => |obj| {
                var new_obj = std.json.ObjectMap.init(self.allocator);
                errdefer {
                    var iter = new_obj.iterator();
                    while (iter.next()) |entry| {
                        self.allocator.free(entry.key_ptr.*);
                        self.freePrettifiedValue(entry.value_ptr.*);
                    }
                    new_obj.deinit();
                }
                var iter = obj.iterator();
                while (iter.next()) |entry| {
                    const key_copy = try self.allocator.dupe(u8, entry.key_ptr.*);
                    errdefer self.allocator.free(key_copy);
                    const value_copy = try self.cloneJsonValue(entry.value_ptr.*);
                    try new_obj.put(key_copy, value_copy);
                }
                return std.json.Value{ .object = new_obj };
            },
            .array => |arr| {
                var new_arr = std.json.Array.init(self.allocator);
                errdefer {
                    for (new_arr.items) |it| {
                        self.freePrettifiedValue(it);
                    }
                    new_arr.deinit();
                }
                for (arr.items) |it| {
                    try new_arr.append(try self.cloneJsonValue(it));
                }
                return std.json.Value{ .array = new_arr };
            },
            .string => |s| {
                const s_copy = try self.allocator.dupe(u8, s);
                return std.json.Value{ .string = s_copy };
            },
            else => return val,
        }
    }

    fn formatDebugPayloadJson(self: *App, payload: std.json.Value) ![]u8 {
        var pretty = payload;
        var used_pretty = false;
        if (self.prettifyValue(payload)) |val| {
            pretty = val;
            used_pretty = true;
        } else |_| {}
        defer if (used_pretty) self.freePrettifiedValue(pretty);

        return std.json.Stringify.valueAlloc(self.allocator, pretty, .{ .whitespace = .indent_2 });
    }

    fn recordDecodeError(self: *App, reason: []const u8, msg: []const u8) !void {
        const preview_max: usize = 1024;
        var preview = msg;
        var preview_owned: ?[]u8 = null;
        if (msg.len > preview_max) {
            const suffix = "...(truncated)";
            const total = preview_max + suffix.len;
            const buf = try self.allocator.alloc(u8, total);
            @memcpy(buf[0..preview_max], msg[0..preview_max]);
            @memcpy(buf[preview_max..total], suffix);
            preview_owned = buf;
            preview = buf;
        }
        defer if (preview_owned) |buf| self.allocator.free(buf);

        var obj = std.json.ObjectMap.init(self.allocator);
        errdefer self.freePrettifiedValue(.{ .object = obj });

        const key_error = try self.allocator.dupe(u8, "error");
        errdefer self.allocator.free(key_error);
        const val_error = try self.allocator.dupe(u8, reason);
        errdefer self.allocator.free(val_error);
        try obj.put(key_error, .{ .string = val_error });

        const key_bytes = try self.allocator.dupe(u8, "bytes");
        errdefer self.allocator.free(key_bytes);
        try obj.put(key_bytes, .{ .integer = @intCast(msg.len) });

        const key_preview = try self.allocator.dupe(u8, "preview");
        errdefer self.allocator.free(key_preview);
        const val_preview = try self.allocator.dupe(u8, preview);
        errdefer self.allocator.free(val_preview);
        try obj.put(key_preview, .{ .string = val_preview });

        const value = std.json.Value{ .object = obj };
        defer self.freePrettifiedValue(value);

        const payload_json = std.json.Stringify.valueAlloc(self.allocator, value, .{ .whitespace = .indent_2 }) catch |err| {
            std.log.err("Failed to format decode error payload: {s}", .{@errorName(err)});
            return;
        };
        defer self.allocator.free(payload_json);

        try self.appendDebugEvent(std.time.milliTimestamp(), "decode.error", null, payload_json);
    }

    fn formatDebugEventLine(self: *App, entry: DebugEventEntry) ![]u8 {
        if (std.mem.indexOfScalar(u8, entry.payload_json, '\n') == null) {
            return std.fmt.allocPrint(
                self.allocator,
                "{d} {s} {s}",
                .{ entry.timestamp_ms, entry.category, entry.payload_json },
            );
        }

        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(self.allocator);
        try out.writer(self.allocator).print("{d} {s}\n", .{ entry.timestamp_ms, entry.category });
        var iter = std.mem.splitScalar(u8, entry.payload_json, '\n');
        while (iter.next()) |line| {
            try out.writer(self.allocator).print("  {s}\n", .{line});
        }
        if (out.items.len > 0 and out.items[out.items.len - 1] == '\n') {
            _ = out.pop();
        }
        return out.toOwnedSlice(self.allocator);
    }

    fn lineStartsWithJsonClose(trimmed_line: []const u8) bool {
        if (trimmed_line.len == 0) return false;
        return trimmed_line[0] == '}' or trimmed_line[0] == ']';
    }

    fn lineEndsWithJsonOpen(trimmed_line: []const u8) bool {
        if (trimmed_line.len == 0) return false;
        var end = trimmed_line.len;
        while (end > 0 and trimmed_line[end - 1] == ',') : (end -= 1) {}
        if (end == 0) return false;
        const ch = trimmed_line[end - 1];
        return ch == '{' or ch == '[';
    }

    fn buildDebugPayloadLines(self: *App, payload_json: []const u8) !std.ArrayList(DebugPayloadLine) {
        var lines: std.ArrayList(DebugPayloadLine) = .empty;
        errdefer lines.deinit(self.allocator);

        var open_stack: std.ArrayList(usize) = .empty;
        defer open_stack.deinit(self.allocator);

        var line_start: usize = 0;
        while (true) {
            const maybe_nl = std.mem.indexOfScalarPos(u8, payload_json, line_start, '\n');
            const line_end = maybe_nl orelse payload_json.len;
            const line = payload_json[line_start..line_end];

            var indent_spaces: usize = 0;
            while (indent_spaces < line.len and line[indent_spaces] == ' ') : (indent_spaces += 1) {}

            const trimmed = std.mem.trim(u8, line, " \t\r");
            const is_close_line = lineStartsWithJsonClose(trimmed);
            const is_open_line = lineEndsWithJsonOpen(trimmed);

            const current_line_index = lines.items.len;
            try lines.append(self.allocator, .{
                .start = line_start,
                .end = line_end,
                .indent_spaces = indent_spaces,
                .opens_block = is_open_line,
            });

            if (is_close_line and open_stack.items.len > 0) {
                const open_line_index = open_stack.items[open_stack.items.len - 1];
                open_stack.items.len -= 1;
                lines.items[open_line_index].matching_close_index = @intCast(current_line_index);
            }

            if (is_open_line) {
                try open_stack.append(self.allocator, current_line_index);
            }

            if (maybe_nl == null) break;
            line_start = line_end + 1;
        }

        return lines;
    }

    fn handleDebugEventMessage(self: *App, root: std.json.ObjectMap) !void {
        try self.handleDebugEventMessageWithStateSync(root, true);
    }

    fn handleDebugEventMessageWithStateSync(
        self: *App,
        root: std.json.ObjectMap,
        apply_subscription_state: bool,
    ) !void {
        const timestamp = if (root.get("timestamp")) |value| switch (value) {
            .integer => value.integer,
            else => std.time.milliTimestamp(),
        } else std.time.milliTimestamp();
        const category = if (root.get("category")) |value| switch (value) {
            .string => value.string,
            else => "unknown",
        } else "unknown";

        // Render payload directly to keep debug streaming resilient for large/complex payloads.
        const payload_json = if (root.get("payload")) |payload| blk: {
            if (self.formatDebugPayloadJson(payload)) |pretty| break :blk pretty else |_| {
                break :blk try self.allocator.dupe(u8, "{\"error\":\"failed to format debug payload\"}");
            }
        } else try self.allocator.dupe(u8, "{}");
        defer self.allocator.free(payload_json);

        if (apply_subscription_state and std.mem.eql(u8, category, "control.subscription")) {
            const payload_obj = if (root.get("payload")) |payload| switch (payload) {
                .object => payload.object,
                else => null,
            } else null;
            const request_id = extractRequestId(root, payload_obj);
            if (payload_obj) |obj| {
                if (obj.get("enabled")) |enabled_value| {
                    if (enabled_value == .bool) {
                        self.debug_stream_enabled = enabled_value.bool;
                    }
                }
            }
            if (request_id) |rid| {
                if (self.isPendingDebugRequest(rid)) {
                    self.debug_stream_pending = false;
                    self.clearPendingDebugRequest();
                }
            }
        }

        const payload_obj = if (root.get("payload")) |payload| switch (payload) {
            .object => payload.object,
            else => null,
        } else null;
        const correlation_id = extractCorrelationId(root, payload_obj);
        try self.appendDebugEvent(timestamp, category, correlation_id, payload_json);
    }

    fn handleIncomingMessage(self: *App, msg: []const u8) !void {
        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, msg, .{}) catch |err| {
            self.recordDecodeError(@errorName(err), msg) catch {};
            return;
        };
        defer parsed.deinit();
        if (parsed.value != .object) {
            self.recordDecodeError("non-object json", msg) catch {};
            return;
        }
        const root = parsed.value.object;

        const mt = if (root.get("type")) |type_value| switch (type_value) {
            .string => protocol_messages.classifyTypeString(type_value.string),
            else => protocol_messages.parseMessageType(msg) orelse return,
        } else protocol_messages.parseMessageType(msg) orelse return;
        switch (mt) {
            .session_receive => {
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
                } else if (root.get("request")) |value| switch (value) {
                    .string => value.string,
                    else => null,
                } else if (payload.get("request")) |value| switch (value) {
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
                } else if (root.get("session_key")) |value| switch (value) {
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
            .connect_ack => {
                const request_id = if (root.get("request_id")) |value| switch (value) {
                    .string => value.string,
                    else => null,
                } else if (root.get("request")) |value| switch (value) {
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
                } else if (root.get("error")) |value| switch (value) {
                    .object => if (value.object.get("message")) |err_msg| switch (err_msg) {
                        .string => err_msg.string,
                        else => "Unknown error",
                    } else "Unknown error",
                    else => "Unknown error",
                } else "Unknown error";
                const err_code = if (payload.get("code")) |value| switch (value) {
                    .string => value.string,
                    else => null,
                } else if (root.get("error")) |value| switch (value) {
                    .object => if (value.object.get("code")) |err_code_value| switch (err_code_value) {
                        .string => err_code_value.string,
                        else => null,
                    } else null,
                    else => null,
                } else null;
                if (extractRequestId(root, payload)) |request_id| {
                    if (self.isPendingDebugRequest(request_id)) {
                        self.debug_stream_pending = false;
                        self.clearPendingDebugRequest();
                    }
                    if (self.pending_send_request_id) |pending| {
                        if (std.mem.eql(u8, pending, request_id)) {
                            if (self.pending_send_message_id) |message_id| {
                                self.setMessageFailed(message_id) catch {};
                            }
                            self.clearPendingSend();
                        }
                    }
                }
                const detail = if (err_code) |code|
                    try std.fmt.allocPrint(self.allocator, "{s} [{s}]", .{ err_message, code })
                else
                    try self.allocator.dupe(u8, err_message);
                defer self.allocator.free(detail);
                try self.appendMessage("system", detail, null);
            },
            .debug_event => {
                try self.handleDebugEventMessage(root);
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
        // Best-effort: unescape common JSON escapes for display ONLY if chunk starts and ends with quotes,
        // which strongly suggests it's a JSON-encoded string literal.
        var use = chunk;
        var owned = false;
        if (chunk.len >= 2 and chunk[0] == '"' and chunk[chunk.len - 1] == '"') {
            if (looksLikeEscaped(chunk)) {
                if (self.unescapeJsonStringAlloc(chunk)) |tmp| {
                    use = tmp;
                    owned = true;
                } else |_| {}
            }
        }
        defer if (owned) self.allocator.free(use);

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
                    try self.setMessageContentByIndex(target, idx, use);
                } else {
                    try self.appendToMessage(target, idx, use);
                }
                if (state.messages.items.len > idx) {
                    state.messages.items[idx].timestamp = timestamp;
                }
            } else {
                const new_id = try self.appendMessageWithIdForSession(target, "assistant", use, null, stream_id);
                self.allocator.free(new_id);
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

        try self.appendMessageForSession(target, "assistant", use, null);
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
            if (state.streaming_request_id) |rid| self.allocator.free(rid);
        }
        self.session_messages.clearRetainingCapacity();
    }

    fn clearDebugEvents(self: *App) void {
        for (self.debug_events.items) |*entry| {
            entry.deinit(self.allocator);
        }
        self.debug_events.clearRetainingCapacity();
        self.debug_folded_blocks.clearRetainingCapacity();
        self.debug_next_event_id = 1;
    }

    fn appendDebugEvent(self: *App, timestamp_ms: i64, category: []const u8, correlation_id: ?[]const u8, payload_json: []const u8) !void {
        while (self.debug_events.items.len >= MAX_DEBUG_EVENTS) {
            var removed = self.debug_events.orderedRemove(0);
            self.pruneDebugFoldStateForEvent(removed.id);
            removed.deinit(self.allocator);
        }

        const category_copy = try self.allocator.dupe(u8, category);
        errdefer self.allocator.free(category_copy);
        const correlation_copy = if (correlation_id) |value|
            try self.allocator.dupe(u8, value)
        else
            null;
        errdefer if (correlation_copy) |value| self.allocator.free(value);
        const payload_copy = try self.allocator.dupe(u8, payload_json);
        errdefer self.allocator.free(payload_copy);
        var payload_lines = try self.buildDebugPayloadLines(payload_copy);
        errdefer payload_lines.deinit(self.allocator);

        const event_id = self.debug_next_event_id;
        self.debug_next_event_id +%= 1;
        if (self.debug_next_event_id == 0) self.debug_next_event_id = 1;

        try self.debug_events.append(self.allocator, .{
            .id = event_id,
            .timestamp_ms = timestamp_ms,
            .category = category_copy,
            .correlation_id = correlation_copy,
            .payload_json = payload_copy,
            .payload_lines = payload_lines,
        });
    }

    fn ensureDebugPanel(self: *App, manager: *panel_manager.PanelManager) !workspace.PanelId {
        if (self.debug_panel_id) |panel_id| {
            if (self.findPanelById(manager, panel_id) != null) {
                manager.focusPanel(panel_id);
                return panel_id;
            }
            self.debug_panel_id = null;
        }

        for (manager.workspace.panels.items) |*panel| {
            if (panel.kind == .ToolOutput and std.mem.eql(u8, panel.title, "Debug Stream")) {
                self.debug_panel_id = panel.id;
                manager.focusPanel(panel.id);
                return panel.id;
            }
        }

        const tool_name = try self.allocator.dupe(u8, "SpiderWeb Debug");
        errdefer self.allocator.free(tool_name);
        var stdout_buf = try text_buffer.TextBuffer.init(self.allocator, "");
        errdefer stdout_buf.deinit(self.allocator);
        var stderr_buf = try text_buffer.TextBuffer.init(self.allocator, "");
        errdefer stderr_buf.deinit(self.allocator);
        const panel_data = workspace.PanelData{ .ToolOutput = .{
            .tool_name = tool_name,
            .stdout = stdout_buf,
            .stderr = stderr_buf,
            .exit_code = 0,
        } };
        const panel_id = try manager.openPanel(.ToolOutput, "Debug Stream", panel_data);
        self.debug_panel_id = panel_id;
        if (manager.workspace.syncDockLayout() catch false) {
            manager.workspace.markDirty();
        }
        manager.focusPanel(panel_id);
        return panel_id;
    }

    fn ensureProjectPanel(self: *App, manager: *panel_manager.PanelManager) !workspace.PanelId {
        if (self.project_panel_id) |panel_id| {
            if (self.findPanelById(manager, panel_id) != null) {
                manager.focusPanel(panel_id);
                return panel_id;
            }
            self.project_panel_id = null;
        }

        for (manager.workspace.panels.items) |*panel| {
            if (panel.kind == .ToolOutput and std.mem.eql(u8, panel.title, "Projects")) {
                self.project_panel_id = panel.id;
                manager.focusPanel(panel.id);
                return panel.id;
            }
        }

        const tool_name = try self.allocator.dupe(u8, "Project Workspace");
        errdefer self.allocator.free(tool_name);
        var stdout_buf = try text_buffer.TextBuffer.init(self.allocator, "");
        errdefer stdout_buf.deinit(self.allocator);
        var stderr_buf = try text_buffer.TextBuffer.init(self.allocator, "");
        errdefer stderr_buf.deinit(self.allocator);
        const panel_data = workspace.PanelData{ .ToolOutput = .{
            .tool_name = tool_name,
            .stdout = stdout_buf,
            .stderr = stderr_buf,
            .exit_code = 0,
        } };
        const panel_id = try manager.openPanel(.ToolOutput, "Projects", panel_data);
        self.project_panel_id = panel_id;
        if (manager.workspace.syncDockLayout() catch false) {
            manager.workspace.markDirty();
        }
        manager.focusPanel(panel_id);
        return panel_id;
    }

    fn ensureFilesystemPanel(self: *App, manager: *panel_manager.PanelManager) !workspace.PanelId {
        if (self.filesystem_panel_id) |panel_id| {
            if (self.findPanelById(manager, panel_id) != null) {
                manager.focusPanel(panel_id);
                return panel_id;
            }
            self.filesystem_panel_id = null;
        }

        for (manager.workspace.panels.items) |*panel| {
            if (panel.kind == .ToolOutput and std.mem.eql(u8, panel.title, "Filesystem Browser")) {
                self.filesystem_panel_id = panel.id;
                manager.focusPanel(panel.id);
                return panel.id;
            }
        }

        const tool_name = try self.allocator.dupe(u8, "Filesystem Browser");
        errdefer self.allocator.free(tool_name);
        var stdout_buf = try text_buffer.TextBuffer.init(self.allocator, "");
        errdefer stdout_buf.deinit(self.allocator);
        var stderr_buf = try text_buffer.TextBuffer.init(self.allocator, "");
        errdefer stderr_buf.deinit(self.allocator);
        const panel_data = workspace.PanelData{ .ToolOutput = .{
            .tool_name = tool_name,
            .stdout = stdout_buf,
            .stderr = stderr_buf,
            .exit_code = 0,
        } };
        const panel_id = try manager.openPanel(.ToolOutput, "Filesystem Browser", panel_data);
        self.filesystem_panel_id = panel_id;
        if (manager.workspace.syncDockLayout() catch false) {
            manager.workspace.markDirty();
        }
        manager.focusPanel(panel_id);
        self.refreshFilesystemBrowser() catch {};
        return panel_id;
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

    fn drawFormSectionTitle(
        self: *App,
        x: f32,
        y: *f32,
        max_w: f32,
        layout: PanelLayoutMetrics,
        text: []const u8,
    ) void {
        const width = @max(1.0, max_w);
        const row_h = form_layout.titleRowHeight(layout);
        const text_y = y.* + @max(0.0, (row_h - layout.line_height) * 0.5);
        self.drawTextTrimmed(x, text_y, width, text, self.theme.colors.text_primary);
        y.* += form_layout.advanceAfterTitle(layout);
    }

    fn drawFormFieldLabel(
        self: *App,
        x: f32,
        y: *f32,
        max_w: f32,
        layout: PanelLayoutMetrics,
        text: []const u8,
    ) void {
        const width = @max(1.0, max_w);
        const row_h = form_layout.labelRowHeight(layout);
        const text_y = y.* + @max(0.0, (row_h - layout.line_height) * 0.5);
        self.drawTextTrimmed(x, text_y, width, text, self.theme.colors.text_primary);
        y.* += form_layout.advanceLabelToInput(layout);
    }

    fn textLineHeight(self: *App) f32 {
        const measured = self.metrics_context.lineHeight();
        const px: f32 = @floatFromInt(self.textPixelSize());
        const min_from_font = px * 1.18;
        if (measured > 0.0) return @max(measured, min_from_font);
        return @max(@max(12.0, 16.0 * self.ui_scale), min_from_font);
    }

    fn textPixelSize(_: *App) u16 {
        const size_f = font_system.currentFontSize(zui.ui.theme.activeTheme());
        if (size_f <= 1.0) return 1;
        const clamped = @min(@as(u32, @intFromFloat(size_f)), 65535);
        return @intCast(clamped);
    }

    fn panelLayoutMetrics(self: *App) PanelLayoutMetrics {
        const line_height = self.textLineHeight();
        return form_layout.defaultMetrics(zui.ui.theme.activeTheme(), line_height, self.ui_scale);
    }

    fn dockTabMetrics(self: *App) DockTabMetrics {
        const line_height = self.textLineHeight();
        const tab_pad = @max(self.theme.spacing.sm, self.theme.spacing.xs * 1.4);
        return .{
            .pad = tab_pad,
            .height = @max(line_height + self.theme.spacing.sm * 1.4, 28.0 * self.ui_scale),
            .min_width = @max(96.0 * self.ui_scale, line_height * 4.8),
            .max_width_ratio = 0.34,
        };
    }

    fn dockTabWidth(self: *App, title: []const u8, group_width: f32, metrics: DockTabMetrics) f32 {
        const desired = self.measureText(title) + metrics.pad * 2.0;
        const max_width = @max(metrics.min_width, (group_width - metrics.pad * 2.0) * metrics.max_width_ratio);
        return @min(max_width, desired);
    }

    fn dockSplitGap(self: *App) f32 {
        return @max(self.theme.spacing.xs, 6.0 * self.ui_scale);
    }

    fn nextUtf8Boundary(text: []const u8, index: usize) usize {
        if (index >= text.len) return text.len;
        var i = index + 1;
        while (i < text.len and (text[i] & 0xC0) == 0x80) : (i += 1) {}
        return i;
    }

    fn skipLeadingSpaces(text: []const u8, start: usize) usize {
        var i = start;
        while (i < text.len and (text[i] == ' ' or text[i] == '\t')) : (i += 1) {}
        return i;
    }

    fn nextWrapBreak(self: *App, line: []const u8, start: usize, max_w: f32) usize {
        if (start >= line.len) return line.len;
        const max_width = @max(1.0, max_w);

        var cursor = start;
        var last_fit = start;
        var last_space_end: ?usize = null;
        while (cursor < line.len) {
            const next = nextUtf8Boundary(line, cursor);
            if (next <= cursor) break;
            const width = self.measureText(line[start..next]);
            if (width <= max_width or last_fit == start) {
                last_fit = next;
                if (line[cursor] == ' ' or line[cursor] == '\t') {
                    last_space_end = next;
                }
                cursor = next;
                continue;
            }
            break;
        }

        if (last_fit == start) {
            return nextUtf8Boundary(line, start);
        }
        if (last_space_end) |space_end| {
            if (space_end > start and space_end < line.len) {
                return space_end;
            }
        }
        return last_fit;
    }

    fn inputTailStartForWidth(self: *App, text: []const u8, max_w: f32) usize {
        if (text.len == 0 or self.measureText(text) <= max_w) return 0;
        var start: usize = 0;
        while (start < text.len) {
            const next = nextUtf8Boundary(text, start);
            if (next <= start) break;
            if (self.measureText(text[next..]) <= max_w) return next;
            start = next;
        }
        return text.len;
    }

    fn drawCenteredText(self: *App, rect: Rect, text: []const u8, color: [4]f32) void {
        const text_w = self.measureText(text);
        const line_height = self.textLineHeight();
        const x = rect.min[0] + @max(0.0, (rect.width() - text_w) * 0.5);
        const y = rect.min[1] + @max(0.0, (rect.height() - line_height) * 0.5);
        self.drawText(x, y, text, color);
    }

    fn drawText(self: *App, x: f32, y: f32, text: []const u8, color: [4]f32) void {
        self.ui_commands.pushText(text, .{ x, y }, color, .body, self.textPixelSize());
    }

    fn drawTextWrapped(self: *App, x: f32, y: f32, max_w: f32, text: []const u8, color: [4]f32) f32 {
        var current_y = y;
        const line_height = self.textLineHeight();
        const wrap_w = @max(1.0, max_w);

        // Split by existing newlines first
        var lines_iter = std.mem.splitScalar(u8, text, '\n');
        while (lines_iter.next()) |raw_line| {
            if (raw_line.len == 0) {
                current_y += line_height;
                continue;
            }

            var line_start: usize = 0;
            while (line_start < raw_line.len) {
                const best_end = self.nextWrapBreak(raw_line, line_start, wrap_w);
                self.drawText(x, current_y, raw_line[line_start..best_end], color);
                current_y += line_height;
                line_start = skipLeadingSpaces(raw_line, best_end);
            }
        }
        return current_y - y;
    }

    fn measureTextWrappedHeight(self: *App, max_w: f32, text: []const u8) f32 {
        const line_height = self.textLineHeight();
        const wrap_w = @max(1.0, max_w);
        var total_height: f32 = 0;

        if (text.len == 0) return line_height;

        // Split by existing newlines first
        var lines_iter = std.mem.splitScalar(u8, text, '\n');
        while (lines_iter.next()) |raw_line| {
            if (raw_line.len == 0) {
                total_height += line_height;
                continue;
            }

            var line_start: usize = 0;
            while (line_start < raw_line.len) {
                const best_end = self.nextWrapBreak(raw_line, line_start, wrap_w);
                total_height += line_height;
                line_start = skipLeadingSpaces(raw_line, best_end);
            }
        }
        return total_height;
    }

    fn measureText(self: *App, text: []const u8) f32 {
        return self.metrics_context.measureText(text, 0.0)[0];
    }

    fn drawTextTrimmed(self: *App, x: f32, y: f32, max_w: f32, text: []const u8, color: [4]f32) void {
        if (max_w <= 0.0) return;
        const text_w = self.measureText(text);
        if (text_w <= max_w) {
            self.drawText(x, y, text, color);
            return;
        }

        const ellipsis = "...";
        const ellipsis_w = self.measureText(ellipsis);
        if (ellipsis_w > max_w) return;

        const limit = max_w - ellipsis_w;
        var width: f32 = 0.0;
        var idx: usize = 0;
        var best_end: usize = 0;
        while (idx < text.len) {
            const next = nextUtf8Boundary(text, idx);
            if (next <= idx) break;
            const glyph_w = self.measureText(text[idx..next]);
            if (width + glyph_w > limit) break;
            width += glyph_w;
            best_end = next;
            idx = next;
        }

        if (best_end == 0) {
            self.drawText(x, y, "...", color);
            return;
        }
        self.drawText(x, y, text[0..best_end], color);
        self.drawText(x + width, y, ellipsis, color);
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

fn extractCorrelationId(root: std.json.ObjectMap, payload: ?std.json.ObjectMap) ?[]const u8 {
    if (root.get("correlation_id")) |value| {
        if (value == .string and value.string.len > 0) return value.string;
    }
    if (payload) |obj| {
        if (obj.get("correlation_id")) |value| {
            if (value == .string and value.string.len > 0) return value.string;
        }
    }
    return App.extractRequestId(root, payload);
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
