const std = @import("std");
const zui = @import("ziggy-ui");
const ws_client_mod = @import("websocket_client.zig");

const zapp = zui.ui.app;
const c = zapp.sdl_app.c;

const widgets = zui.widgets;
const zcolors = zui.theme.colors;
const ui_draw_context = zui.ui.draw_context;
const ui_input_router = zui.ui.input.input_router;
const ui_input_state = zui.ui.input.input_state;
const ui_input_backend = zui.ui.input.input_backend;
const ui_sdl_input_backend = zui.ui.input.sdl_input_backend;

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
const ChatSession = zui.protocol.types.Session;

const ChatPanel = zui.ChatPanel(ChatMessage, ChatSession);

const SettingsPanel = struct {
    server_url: std.ArrayList(u8) = .empty,
    focused: bool = true,
    
    pub fn init(allocator: std.mem.Allocator) SettingsPanel {
        var panel = SettingsPanel{};
        panel.server_url.appendSlice(allocator, "ws://127.0.0.1:18790") catch {};
        return panel;
    }
    
    pub fn deinit(self: *SettingsPanel, allocator: std.mem.Allocator) void {
        self.server_url.deinit(allocator);
    }
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
    messages: std.ArrayList(ChatMessage) = .empty,
    chat_sessions: std.ArrayList(ChatSession) = .empty,
    current_session_key: ?[]const u8 = null,

    ui_commands: zui.ui.render.command_list.CommandList,

    ws_client: ?ws_client_mod.WebSocketClient = null,

    connection_state: ConnectionState = .disconnected,
    status_text: []u8,

    theme: *const zui.Theme,

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

        var app = App{
            .allocator = allocator,
            .window = window,
            .gpu = gpu,
            .swapchain = swapchain,
            .settings_panel = SettingsPanel.init(allocator),
            .status_text = try allocator.dupe(u8, "Not connected"),
            .theme = zui.theme.current(),
            .ui_commands = zui.ui.render.command_list.CommandList.init(allocator),
            .frame_clock = zapp.frame_clock.FrameClock.init(60),
            .manager = undefined, // Will be initialized below
        };
        
        app.manager = panel_manager.PanelManager.init(allocator, ws, &app.next_panel_id);
        errdefer app.manager.deinit();
        
        errdefer app.settings_panel.deinit(allocator);
        errdefer allocator.free(app.status_text);

        ui_sdl_input_backend.init(allocator);
        ui_input_router.setBackend(ui_input_backend.sdl3);

        return app;
    }

    pub fn deinit(self: *App) void {
        self.disconnect();

        self.clearMessages();
        self.messages.deinit(self.allocator);
        self.clearSessions();
        self.chat_sessions.deinit(self.allocator);

        zui.ChatView(ChatMessage).deinit(&self.chat_panel_state.view, self.allocator);

        self.settings_panel.deinit(self.allocator);
        self.chat_input.deinit(self.allocator);

        self.ui_commands.deinit();
        self.manager.deinit();
        ui_input_router.deinit(self.allocator);
        ui_sdl_input_backend.deinit();

        self.allocator.free(self.status_text);

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
            self.theme.applyTypography(dpi_scale);

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
            while (true) {
                const maybe_msg = client.read() catch |err| switch (err) {
                    error.WouldBlock => break,
                    error.ConnectionClosed, error.Closed => {
                        self.setConnectionState(.disconnected, "Disconnected");
                        self.disconnect();
                        break;
                    },
                    else => {
                        const msg = try std.fmt.allocPrint(self.allocator, "Read error: {s}", .{@errorName(err)});
                        defer self.allocator.free(msg);
                        self.setConnectionState(.error_state, msg);
                        self.disconnect();
                        break;
                    },
                };

                if (maybe_msg) |msg| {
                    defer self.allocator.free(msg);
                    try self.appendMessage("assistant", msg);
                } else break;
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
                if (self.settings_panel.focused) {
                    try self.tryConnect();
                }
            },
            .v => {
                if (self.settings_panel.focused and key_evt.mods.ctrl and !key_evt.repeat) {
                    const clip = zapp.clipboard.getTextZ();
                    if (clip.len > 0) {
                        try self.settings_panel.server_url.appendSlice(self.allocator, clip);
                    }
                }
            },
            else => {},
        }
    }

    fn handleTextInput(self: *App, text: []const u8) !void {
        if (text.len == 0) return;
        
        if (self.settings_panel.focused) {
            for (text) |ch| {
                if (ch >= 32 and ch < 127) {
                    try self.settings_panel.server_url.append(self.allocator, ch);
                }
            }
        }
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
        const tab_height: f32 = 28.0;
        
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
        y += 20;
        
        // URL Input
        const input_height: f32 = 32.0;
        const rect_width = rect.max[0] - rect.min[0];
        const input_rect = Rect.fromXYWH(
            rect.min[0] + pad,
            y,
            @max(200, rect_width - pad * 2.0),
            input_height,
        );
        
        const url_focused = self.drawTextInputWidget(
            input_rect,
            self.settings_panel.server_url.items,
            self.settings_panel.focused,
            .{ .placeholder = "ws://127.0.0.1:18790" },
        );
        self.settings_panel.focused = url_focused;
        
        // Handle click outside to unfocus
        if (self.mouse_clicked and !input_rect.contains(.{ self.mouse_x, self.mouse_y })) {
            self.settings_panel.focused = false;
        }
        
        y += input_height + pad;
        
        // Connect button
        const button_width: f32 = 120.0;
        const button_height: f32 = 32.0;
        const button_rect = Rect.fromXYWH(
            rect.min[0] + pad,
            y,
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
        
        y += button_height + pad * 2.0;
        
        // Status row
        const status_height: f32 = 32.0;
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
            self.messages.items,
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
        const status_height: f32 = 24.0;
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
        const indicator_size: f32 = 8.0;
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
            const max_chars = @as(usize, @intFromFloat(@max(0, @floor(max_w / 8.0))));
            const caret_chars = @min(text.len, max_chars);
            const caret_x = text_x + @as(f32, @floatFromInt(caret_chars)) * 8.0;
            self.drawText(caret_x, text_y, "_", widgets.text_input.getCaretColor(self.theme));
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

        var client = ws_client_mod.WebSocketClient.init(self.allocator, self.settings_panel.server_url.items, "") catch |err| {
            const msg = try std.fmt.allocPrint(self.allocator, "Client init failed: {s}", .{@errorName(err)});
            defer self.allocator.free(msg);
            self.setConnectionState(.error_state, msg);
            return;
        };

        client.connect() catch |err| {
            client.deinit();
            const msg = try std.fmt.allocPrint(self.allocator, "Connect failed: {s}", .{@errorName(err)});
            defer self.allocator.free(msg);
            self.setConnectionState(.error_state, msg);
            return;
        };

        self.ws_client = client;
        self.setConnectionState(.connected, "Connected");
        self.settings_panel.focused = false;

        self.clearSessions();
        try self.addSession("main", "Main");

        try self.appendMessage("system", "Connected to Spiderweb");
        
        // Switch to chat panel by focusing it
        for (self.manager.workspace.panels.items) |*panel| {
            if (panel.kind == .Chat) {
                self.manager.focusPanel(panel.id);
                break;
            }
        }
    }

    fn disconnect(self: *App) void {
        if (self.ws_client) |*client| {
            client.deinit();
            self.ws_client = null;
        }
        self.current_session_key = null;
        self.clearSessions();
    }

    fn sendChatMessageText(self: *App, text: []const u8) !void {
        if (text.len == 0) return;

        try self.appendMessage("user", text);

        if (self.ws_client) |*client| {
            var payload = std.ArrayList(u8).empty;
            defer payload.deinit(self.allocator);

            try payload.appendSlice(self.allocator, "{\"type\":\"chat\",\"content\":\"");
            for (text) |ch| {
                switch (ch) {
                    '"' => try payload.appendSlice(self.allocator, "\\\""),
                    '\\' => try payload.appendSlice(self.allocator, "\\\\"),
                    '\n' => try payload.appendSlice(self.allocator, "\\n"),
                    '\r' => {},
                    else => try payload.append(self.allocator, ch),
                }
            }
            try payload.appendSlice(self.allocator, "\"}");

            client.send(payload.items) catch |err| {
                const err_text = try std.fmt.allocPrint(self.allocator, "Send failed: {s}", .{@errorName(err)});
                defer self.allocator.free(err_text);
                try self.appendMessage("system", err_text);
            };
        }
    }

    fn appendMessage(self: *App, role: []const u8, content: []const u8) !void {
        self.message_counter += 1;
        const id = try std.fmt.allocPrint(self.allocator, "msg-{d}", .{self.message_counter});
        errdefer self.allocator.free(id);

        try self.messages.append(self.allocator, .{
            .id = id,
            .role = try self.allocator.dupe(u8, role),
            .content = try self.allocator.dupe(u8, content),
            .timestamp = std.time.milliTimestamp(),
            .attachments = null,
            .local_state = null,
        });

        if (self.messages.items.len > 500) {
            var oldest = self.messages.orderedRemove(0);
            self.freeMessage(&oldest);
        }
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

    fn clearMessages(self: *App) void {
        for (self.messages.items) |*msg| {
            self.freeMessage(msg);
        }
        self.messages.clearRetainingCapacity();
    }

    fn clearSessions(self: *App) void {
        for (self.chat_sessions.items) |session| {
            self.allocator.free(session.key);
            if (session.display_name) |name| self.allocator.free(name);
        }
        self.chat_sessions.clearRetainingCapacity();
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
        self.current_session_key = key_copy;
    }

    fn handleChatPanelAction(self: *App, action: zui.ChatPanelAction) void {
        if (action.send_message) |message| {
            defer self.allocator.free(message);
            self.sendChatMessageText(message) catch {};
        }

        if (action.select_session) |session_key| {
            defer self.allocator.free(session_key);
            for (self.chat_sessions.items) |session| {
                if (std.mem.eql(u8, session.key, session_key)) {
                    self.current_session_key = session.key;
                    break;
                }
            }
        }

        if (action.select_session_id) |sid| {
            self.allocator.free(sid);
        }

        if (action.new_chat_session_key) |new_key| {
            defer self.allocator.free(new_key);

            var found = false;
            for (self.chat_sessions.items) |session| {
                if (std.mem.eql(u8, session.key, new_key)) {
                    self.current_session_key = session.key;
                    found = true;
                    break;
                }
            }

            if (!found) {
                self.addSession(new_key, new_key) catch {};
            }
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
        self.ui_commands.pushText(text, .{ x, y }, color, .body, 14);
    }
    
    fn measureText(self: *App, text: []const u8) f32 {
        _ = self;
        return @as(f32, @floatFromInt(text.len)) * 8.0;
    }

    fn drawTextTrimmed(self: *App, x: f32, y: f32, max_w: f32, text: []const u8, color: [4]f32) void {
        const max_chars = @as(usize, @intFromFloat(@max(0, @floor(max_w / 8.0))));
        if (text.len <= max_chars) {
            self.drawText(x, y, text, color);
            return;
        }

        if (max_chars <= 3) {
            self.drawText(x, y, "...", color);
            return;
        }

        var tmp: [1024]u8 = undefined;
        const copy_len = @min(max_chars - 3, @min(text.len, tmp.len - 3));
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

    try app.run();
}
