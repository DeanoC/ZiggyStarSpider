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
const protocol_messages = @import("protocol_messages.zig");

const workspace = zui.ui.workspace;
const panel_manager = zui.ui.panel_manager;
const dock_graph = zui.ui.layout.dock_graph;

const Rect = zui.core.Rect;
const UiRect = ui_draw_context.Rect;
const Paint = zui.theme_engine.Paint;

const ConnectionState = enum {
    disconnected,
    connecting,
    connected,
    error_state,
};

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

const SessionMessageState = struct {
    key: []const u8,
    messages: std.ArrayList(ChatMessage) = .empty,
    streaming_request_id: ?[]const u8 = null,
};

const App = struct {
    allocator: std.mem.Allocator,
    window: *c.SDL_Window,
    gpu: zapp.multi_window_renderer.Shared,
    swapchain: zapp.multi_window_renderer.WindowSwapchain,

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

    running: bool = true,

    // Input state
    mouse_x: f32 = 0,
    mouse_y: f32 = 0,
    mouse_down: bool = false,
    mouse_clicked: bool = false,
    mouse_released: bool = false,

    message_counter: u64 = 0,
    frame_clock: zapp.frame_clock.FrameClock,

    // UI State for dock
    ui_state: zui.ui.main_window.WindowUiState = .{},

    pub fn init(allocator: std.mem.Allocator) !App {
        try zapp.sdl_app.init(.{ .video = true, .events = true, .gamepad = false });
        zapp.clipboard.init();

        const window = zapp.sdl_app.createWindow("ZiggyStarSpider GUI", 1024, 720, c.SDL_WINDOW_RESIZABLE) catch {
            return error.CreateWindowFailed;
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
            .status_text = try allocator.dupe(u8, "Not connected"),
            .theme = zui.theme.current(),
            .ui_scale = 1.0,
            .config = config,
            .ui_commands = zui.ui.render.command_list.CommandList.init(allocator),
            .frame_clock = zapp.frame_clock.FrameClock.init(60),
            .manager = undefined, // Will be initialized below
        };

        app.manager = panel_manager.PanelManager.init(allocator, ws, &app.next_panel_id);
        errdefer app.manager.deinit();

        if (app.config.default_session) |default_session| {
            const seed = if (default_session.len > 0) default_session else "main";
            app.ensureSessionExists(seed, seed) catch {};
        } else {
            app.ensureSessionExists("main", "Main") catch {};
        }

        errdefer app.settings_panel.deinit(allocator);
        errdefer allocator.free(app.status_text);

        ui_sdl_input_backend.init(allocator);
        ui_input_router.setBackend(ui_input_backend.sdl3);

        return app;
    }

    pub fn deinit(self: *App) void {
        self.disconnect();
        self.clearSessions();
        if (self.pending_send_request_id) |request_id| self.allocator.free(request_id);
        if (self.pending_send_message_id) |message_id| self.allocator.free(message_id);
        if (self.pending_send_session_key) |session_key| self.allocator.free(session_key);

        zui.ChatView(ChatMessage).deinit(&self.chat_panel_state.view, self.allocator);

        self.settings_panel.deinit(self.allocator);
        self.chat_input.deinit(self.allocator);

        self.ui_commands.deinit();
        self.manager.deinit();
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
            _ = self.frame_clock.beginFrame();
            self.mouse_clicked = false;
            self.mouse_released = false;

            // Get DPI scale and apply to theme
            const dpi_scale_raw: f32 = c.SDL_GetWindowDisplayScale(self.window);
            const dpi_scale: f32 = if (dpi_scale_raw > 0.0) dpi_scale_raw else 1.0;
            self.ui_scale = dpi_scale;
            zui.ui.theme.applyTypography(dpi_scale);

            const queue = ui_input_router.beginFrame(self.allocator);
            const polled = zapp.sdl_app.pollEventsToInput();
            if (polled.quit_requested) {
                self.running = false;
            }
            if (polled.window_close_requested and polled.window_close_id == c.SDL_GetWindowID(self.window)) {
                self.running = false;
            }

            zapp.sdl_app.collectWindowInput(self.allocator, self.window, queue);
            ui_input_router.setExternalQueue(queue); // Restore queue after collectWindowInput clears it
            try self.processInputEvents(queue);
            try self.pollWebSocket();

            self.drawFrame();
            ui_input_state.endFrame(queue);
            self.frame_clock.endFrame();
        }
    }

    fn processInputEvents(self: *App, queue: *ui_input_state.InputQueue) !void {
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
                    try self.handleKeyDownEvent(ke);
                },
                .text_input => |txt| {
                    try self.handleTextInput(txt.text);
                },
                else => {},
            }
        }
    }

    fn pollWebSocket(self: *App) !void {
        if (self.ws_client) |*client| {
            var count: u32 = 0;
            // Drain all available messages (non-blocking, like ZSC)
            while (client.tryReceive()) |msg| {
                count += 1;
                std.log.info("[ZSS] Received raw ({d} bytes): {s}", .{ msg.len, msg });
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

    fn handleKeyDownEvent(self: *App, key_evt: anytype) !void {
        switch (key_evt.key) {
            .escape => {
                self.running = false;
            },
            .enter, .keypad_enter => {
                // Check if we're focused on settings URL input
                if (self.settings_panel.focused_field != .none) {
                    try self.tryConnect();
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
    }

    fn drawFrame(self: *App) void {
        self.theme = zui.theme.current();

        var fb_w: c_int = 0;
        var fb_h: c_int = 0;
        _ = c.SDL_GetWindowSizeInPixels(self.window, &fb_w, &fb_h);
        const fb_width: u32 = @intCast(if (fb_w > 0) fb_w else 1);
        const fb_height: u32 = @intCast(if (fb_h > 0) fb_h else 1);

        self.swapchain.beginFrame(&self.gpu, fb_width, fb_height);

        // Draw the dock-based UI
        self.drawDockUi(fb_width, fb_height);

        // Render the UI commands through WebGPU
        self.gpu.ui_renderer.beginFrame(fb_width, fb_height);
        self.swapchain.render(&self.gpu, &self.ui_commands);
    }

    fn drawDockUi(self: *App, fb_width: u32, fb_height: u32) void {
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

        // Compute dock layout
        const layout = self.manager.workspace.dock_layout.computeLayout(viewport);

        // Draw each dock group
        for (layout.slice()) |group| {
            self.drawDockGroup(group.node_id, group.rect);
        }

        // Draw connection status overlay
        self.drawStatusOverlay(fb_width, fb_height);
    }

    fn drawDockGroup(self: *App, node_id: dock_graph.NodeId, rect: UiRect) void {
        const node = self.manager.workspace.dock_layout.getNode(node_id) orelse return;

        switch (node.*) {
            .tabs => |tabs| {
                self.drawTabsPanel(&tabs, rect);
            },
            .split => |_| {
                // Split nodes are handled by layout computation, children drawn separately
            },
        }
    }

    fn drawTabsPanel(self: *App, tabs: *const dock_graph.TabsNode, rect: UiRect) void {
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
        const active_tab_id = if (tabs.active < tabs.tabs.items.len)
            tabs.tabs.items[tabs.active]
        else
            null;

        // Draw each tab
        for (tabs.tabs.items) |panel_id| {
            const panel = self.findPanelById(panel_id) orelse continue;
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
            self.drawPanelContent(panel_id, content_rect);
        }
    }

    fn findPanelById(self: *App, panel_id: workspace.PanelId) ?*workspace.Panel {
        for (self.manager.workspace.panels.items) |*panel| {
            if (panel.id == panel_id) return panel;
        }
        return null;
    }

    fn drawPanelContent(self: *App, panel_id: workspace.PanelId, rect: UiRect) void {
        const panel = self.findPanelById(panel_id) orelse return;

        switch (panel.kind) {
            .Chat => {
                self.drawChatPanel(rect);
            },
            .Settings, .Control => {
                self.drawSettingsPanel(rect);
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

    fn drawSettingsPanel(self: *App, rect: UiRect) void {
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
            self.tryConnect() catch {};
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
        const pad = self.theme.spacing.sm;
        const panel_rect = UiRect.fromMinSize(
            .{ rect.min[0] + pad, rect.min[1] + pad },
            .{
                @max(120.0, rect.max[0] - rect.min[0] - pad * 2.0),
                @max(120.0, rect.max[1] - rect.min[1] - pad * 2.0),
            },
        );

        const action = ChatPanel.draw(
            self.allocator,
            &self.chat_panel_state,
            "zss-gui",
            self.current_session_key,
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

    fn tryConnect(self: *App) !void {
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
        for (self.manager.workspace.panels.items) |*panel| {
            if (panel.kind == .Chat) {
                self.manager.focusPanel(panel.id);
                break;
            }
        }
    }

    fn focusSettingsPanel(self: *App) void {
        for (self.manager.workspace.panels.items) |*panel| {
            if (panel.kind == .Settings or panel.kind == .Control) {
                self.manager.focusPanel(panel.id);
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
        self.current_session_key = null;
        self.clearPendingSend();
        if (self.current_session_key) |key| {
            self.allocator.free(key);
            self.current_session_key = null;
        }
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
                } else null;
                const session_key = if (payload.get("session_key")) |value| switch (value) {
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
                // Optional: could clear pending state in the future
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
                return;
            }
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
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var app = try App.init(gpa.allocator());
    defer app.deinit();

    if (app.config.auto_connect_on_launch) {
        app.tryConnect() catch {};
    }

    try app.run();
}
