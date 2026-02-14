const std = @import("std");
const zui = @import("ziggy-ui");
const ws_client_mod = @import("websocket_client.zig");

const zapp = zui.ui.app;
const c = zapp.sdl_app.c;

const widgets = zui.widgets;
const zlayout = zui.core.layout;
const zcolors = zui.theme.colors;
const ui_draw_context = zui.ui.draw_context;
const ui_input_router = zui.ui.input.input_router;
const ui_input_state = zui.ui.input.input_state;
const ui_input_backend = zui.ui.input.input_backend;
const ui_sdl_input_backend = zui.ui.input.sdl_input_backend;

const Rect = zui.core.Rect;
const UiRect = ui_draw_context.Rect;
const Paint = zui.theme_engine.Paint;

const Screen = enum {
    settings,
    chat,
};

const FocusField = enum {
    none,
    server_url,
    chat_input,
};

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

const SettingsLayoutIds = struct {
    root: u64,
    title: u64,
    subtitle: u64,
    url_label: u64,
    url_input: u64,
    connect_button: u64,
    status: u64,
    tip: u64,
};

const ChatLayoutIds = struct {
    root: u64,
    header: u64,
    history: u64,
    composer: u64,
    chat_input: u64,
    send_button: u64,
};

const SettingsRects = struct {
    title: Rect,
    subtitle: Rect,
    url_label: Rect,
    url_input: Rect,
    connect_button: Rect,
    status: Rect,
    tip: Rect,
};

const ChatRects = struct {
    header: Rect,
    history: Rect,
    composer: Rect,
    chat_input: Rect,
    send_button: Rect,
};

const WindowSize = struct { w: i32, h: i32 };

const App = struct {
    allocator: std.mem.Allocator,
    window: *c.SDL_Window,
    gpu: zapp.multi_window_renderer.Shared,
    swapchain: zapp.multi_window_renderer.WindowSwapchain,

    screen: Screen = .settings,
    focus: FocusField = .server_url,

    server_url: std.ArrayList(u8) = .empty,
    chat_input: std.ArrayList(u8) = .empty,
    messages: std.ArrayList(ChatMessage) = .empty,
    chat_sessions: std.ArrayList(ChatSession) = .empty,
    current_session_key: ?[]const u8 = null,

    chat_panel_state: zui.ui.workspace.ChatPanel = .{},
    ui_commands: zui.ui.render.command_list.CommandList,

    ws_client: ?ws_client_mod.WebSocketClient = null,

    connection_state: ConnectionState = .disconnected,
    status_text: []u8,

    theme: *const zui.Theme,

    layout_engine: zlayout.LayoutEngine,
    settings_ids: SettingsLayoutIds,
    chat_ids: ChatLayoutIds,

    running: bool = true,

    mouse_x: f32 = 0,
    mouse_y: f32 = 0,
    mouse_down: bool = false,
    mouse_clicked: bool = false,
    mouse_released: bool = false,

    scroll_lines: i32 = 0,
    last_chat_history_rect: Rect = Rect.fromXYWH(0, 0, 0, 0),
    message_counter: u64 = 0,
    frame_clock: zapp.frame_clock.FrameClock,

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

        zui.theme.setMode(.dark);

        var app = App{
            .allocator = allocator,
            .window = window,
            .gpu = gpu,
            .swapchain = swapchain,
            .status_text = try allocator.dupe(u8, "Not connected"),
            .theme = zui.theme.current(),
            .layout_engine = zlayout.LayoutEngine.init(allocator),
            .settings_ids = undefined,
            .chat_ids = undefined,
            .ui_commands = zui.ui.render.command_list.CommandList.init(allocator),
            .frame_clock = zapp.frame_clock.FrameClock.init(60),
        };
        errdefer app.layout_engine.deinit();
        errdefer allocator.free(app.status_text);

        try app.initLayoutTrees();
        try app.server_url.appendSlice(allocator, "ws://127.0.0.1:18790");

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

        self.server_url.deinit(self.allocator);
        self.chat_input.deinit(self.allocator);

        self.ui_commands.deinit();
        ui_input_router.deinit(self.allocator);
        ui_sdl_input_backend.deinit();

        self.layout_engine.deinit();
        self.allocator.free(self.status_text);

        self.swapchain.deinit();
        self.gpu.deinit();

        zapp.sdl_app.stopTextInput(self.window);
        c.SDL_DestroyWindow(self.window);
        zapp.sdl_app.deinit();
    }

    fn initLayoutTrees(self: *App) !void {
        const s_root = try self.layout_engine.createNode(null);
        const s_title = try self.layout_engine.createNode(s_root);
        const s_subtitle = try self.layout_engine.createNode(s_root);
        const s_url_label = try self.layout_engine.createNode(s_root);
        const s_url_input = try self.layout_engine.createNode(s_root);
        const s_connect = try self.layout_engine.createNode(s_root);
        const s_status = try self.layout_engine.createNode(s_root);
        const s_tip = try self.layout_engine.createNode(s_root);

        self.settings_ids = .{
            .root = s_root,
            .title = s_title,
            .subtitle = s_subtitle,
            .url_label = s_url_label,
            .url_input = s_url_input,
            .connect_button = s_connect,
            .status = s_status,
            .tip = s_tip,
        };

        const c_root = try self.layout_engine.createNode(null);
        const c_header = try self.layout_engine.createNode(c_root);
        const c_history = try self.layout_engine.createNode(c_root);
        const c_composer = try self.layout_engine.createNode(c_root);
        const c_input = try self.layout_engine.createNode(c_composer);
        const c_send = try self.layout_engine.createNode(c_composer);

        self.chat_ids = .{
            .root = c_root,
            .header = c_header,
            .history = c_history,
            .composer = c_composer,
            .chat_input = c_input,
            .send_button = c_send,
        };
    }

    pub fn run(self: *App) !void {
        while (self.running) {
            _ = self.frame_clock.beginFrame();
            self.mouse_clicked = false;
            self.mouse_released = false;

            const queue = ui_input_router.beginFrame(self.allocator);
            const polled = zapp.sdl_app.pollEventsToInput();
            if (polled.quit_requested) {
                self.running = false;
            }
            if (polled.window_close_requested and polled.window_close_id == c.SDL_GetWindowID(self.window)) {
                self.running = false;
            }

            zapp.sdl_app.collectWindowInput(self.allocator, self.window, queue);
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
                .mouse_wheel => |mw| {
                    self.handleMouseWheel(mw.delta[1]);
                },
                .key_down => |ke| {
                    try self.handleKeyDownEvent(ke);
                },
                .text_input => |txt| {
                    try self.handleTextInput(txt.text);
                },
                .focus_lost => {
                    self.mouse_down = false;
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

    fn handleMouseWheel(self: *App, wheel_y: f32) void {
        if (self.screen != .chat) return;
        if (!self.last_chat_history_rect.contains(.{ self.mouse_x, self.mouse_y })) return;

        if (wheel_y > 0) {
            self.scroll_lines += 1;
        } else if (wheel_y < 0 and self.scroll_lines > 0) {
            self.scroll_lines -= 1;
        }

        self.clampScroll();
    }

    fn handleKeyDownEvent(self: *App, key_evt: anytype) !void {
        switch (key_evt.key) {
            .escape => {
                self.running = false;
            },
            .tab => {
                if (self.screen == .settings) {
                    self.focus = .server_url;
                }
            },
            .back_space => {
                if (self.screen == .settings and self.focus == .server_url) {
                    backspaceUtf8(&self.server_url);
                }
            },
            .enter, .keypad_enter => {
                if (self.screen == .settings) {
                    try self.tryConnect();
                }
            },
            .v => {
                if (self.screen == .settings and self.focus == .server_url and key_evt.mods.ctrl and !key_evt.repeat) {
                    const clip = zapp.clipboard.getTextZ();
                    if (clip.len > 0) {
                        try self.server_url.appendSlice(self.allocator, clip);
                    }
                }
            },
            else => {},
        }
    }

    fn handleTextInput(self: *App, text: []const u8) !void {
        if (text.len == 0) return;
        if (self.screen != .settings) return;

        if (self.focus == .server_url) {
            for (text) |ch| {
                if (ch >= 32 and ch < 127) {
                    try self.server_url.append(self.allocator, ch);
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

        switch (self.screen) {
            .settings => self.drawSettingsScreen(),
            .chat => self.drawChatScreen(),
        }

        // Render the UI commands through WebGPU
        self.gpu.ui_renderer.beginFrame(fb_width, fb_height);
        self.swapchain.render(&self.gpu, &self.ui_commands);
    }

    fn drawSettingsScreen(self: *App) void {
        self.ui_commands.clear();
        ui_draw_context.setGlobalCommandList(&self.ui_commands);
        defer ui_draw_context.clearGlobalCommandList();

        const dims = self.windowSize();
        const rects = self.computeSettingsRects(dims) catch return;

        // Draw background
        self.ui_commands.pushRect(
            .{ .min = .{ 0, 0 }, .max = .{ @floatFromInt(dims.w), @floatFromInt(dims.h) } },
            .{ .fill = self.theme.colors.background },
        );

        self.drawLabel(rects.title, "ZiggyStarSpider - GUI Client", self.theme.colors.text_primary);
        self.drawLabel(rects.subtitle, "Settings / Auth", self.theme.colors.text_secondary);
        self.drawLabel(rects.url_label, "Server URL", self.theme.colors.text_primary);

        const url_focused = self.drawTextInputWidget(
            rects.url_input,
            self.server_url.items,
            self.focus == .server_url,
            .{ .placeholder = "ws://127.0.0.1:18790" },
        );

        if (url_focused) {
            self.focus = .server_url;
        } else if (self.mouse_clicked and !rects.url_input.contains(.{ self.mouse_x, self.mouse_y })) {
            self.focus = .none;
        }

        const connect_clicked = self.drawButtonWidget(
            rects.connect_button,
            "Connect",
            .{ .variant = .primary, .disabled = self.connection_state == .connecting },
        );
        if (connect_clicked) {
            self.tryConnect() catch {};
        }

        self.drawStatusRow(rects.status);
        self.drawLabel(rects.tip, "Tip: Enter URL, press Connect, then chat.", self.theme.colors.text_secondary);
    }

    fn drawChatScreen(self: *App) void {
        const dims = self.windowSize();
        const pad = self.theme.spacing.md + 4.0;
        const panel_rect = UiRect.fromMinSize(
            .{ pad, pad },
            .{
                @max(120.0, @as(f32, @floatFromInt(dims.w)) - pad * 2.0),
                @max(120.0, @as(f32, @floatFromInt(dims.h)) - pad * 2.0),
            },
        );

        self.ui_commands.clear();
        ui_draw_context.setGlobalCommandList(&self.ui_commands);
        defer ui_draw_context.clearGlobalCommandList();

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

    fn computeSettingsRects(self: *App, dims: WindowSize) !SettingsRects {
        const pad = self.theme.spacing.lg;
        const root = Rect.fromXYWH(
            pad,
            pad,
            @max(120, @as(f32, @floatFromInt(dims.w)) - pad * 2.0),
            @max(120, @as(f32, @floatFromInt(dims.h)) - pad * 2.0),
        );

        const line_h: f32 = 14.0;
        const input_h = widgets.text_input.defaultHeight(self.theme, line_h);
        const button_h = widgets.button.defaultHeight(self.theme, line_h);

        self.layout_engine.setNodeRect(self.settings_ids.root, root);

        if (self.layout_engine.getNode(self.settings_ids.root)) |node| {
            node.padding = .{ 0, 0, 0, 0 };
        }

        self.setNodePreferred(self.settings_ids.title, .{ root.width(), line_h + 4.0 }, 0.0, null);
        self.setNodePreferred(self.settings_ids.subtitle, .{ root.width(), line_h + 2.0 }, 0.0, null);
        self.setNodePreferred(self.settings_ids.url_label, .{ root.width(), line_h + 2.0 }, 0.0, null);
        self.setNodePreferred(self.settings_ids.url_input, .{ root.width(), input_h }, 0.0, null);
        self.setNodePreferred(self.settings_ids.connect_button, .{ 150.0, button_h }, 0.0, .start);
        self.setNodePreferred(self.settings_ids.status, .{ root.width(), line_h + 18.0 }, 0.0, null);
        self.setNodePreferred(self.settings_ids.tip, .{ root.width(), line_h + 2.0 }, 0.0, null);

        try self.layout_engine.computeFlexLayout(self.settings_ids.root, root.size(), .{
            .direction = .vertical,
            .main_align = .start,
            .cross_align = .stretch,
            .spacing = .{ .main = self.theme.spacing.sm },
        });

        return .{
            .title = self.nodeRect(self.settings_ids.title),
            .subtitle = self.nodeRect(self.settings_ids.subtitle),
            .url_label = self.nodeRect(self.settings_ids.url_label),
            .url_input = self.nodeRect(self.settings_ids.url_input),
            .connect_button = self.nodeRect(self.settings_ids.connect_button),
            .status = self.nodeRect(self.settings_ids.status),
            .tip = self.nodeRect(self.settings_ids.tip),
        };
    }

    fn computeChatRects(self: *App, dims: WindowSize) !ChatRects {
        const pad = self.theme.spacing.md + 4.0;
        const root = Rect.fromXYWH(
            pad,
            pad,
            @max(120, @as(f32, @floatFromInt(dims.w)) - pad * 2.0),
            @max(120, @as(f32, @floatFromInt(dims.h)) - pad * 2.0),
        );

        const line_h: f32 = 14.0;
        const input_h = widgets.text_input.defaultHeight(self.theme, line_h);
        const button_h = widgets.button.defaultHeight(self.theme, line_h);

        self.layout_engine.setNodeRect(self.chat_ids.root, root);

        if (self.layout_engine.getNode(self.chat_ids.root)) |node| {
            node.padding = .{ 0, 0, 0, 0 };
        }

        self.setNodePreferred(self.chat_ids.header, .{ root.width(), line_h + 4.0 }, 0.0, null);
        self.setNodePreferred(self.chat_ids.history, .{ root.width(), 200.0 }, 1.0, null);
        self.setNodePreferred(self.chat_ids.composer, .{ root.width(), @max(input_h, button_h) }, 0.0, null);

        try self.layout_engine.computeFlexLayout(self.chat_ids.root, root.size(), .{
            .direction = .vertical,
            .main_align = .start,
            .cross_align = .stretch,
            .spacing = .{ .main = self.theme.spacing.sm },
        });

        const composer_rect = self.nodeRect(self.chat_ids.composer);
        self.layout_engine.setNodeRect(self.chat_ids.composer, composer_rect);

        if (self.layout_engine.getNode(self.chat_ids.composer)) |node| {
            node.padding = .{ 0, 0, 0, 0 };
        }

        self.setNodePreferred(self.chat_ids.chat_input, .{ composer_rect.width(), input_h }, 1.0, null);
        self.setNodePreferred(self.chat_ids.send_button, .{ 100.0, button_h }, 0.0, .stretch);

        try self.layout_engine.computeFlexLayout(self.chat_ids.composer, composer_rect.size(), .{
            .direction = .horizontal,
            .main_align = .start,
            .cross_align = .stretch,
            .spacing = .{ .main = self.theme.spacing.sm },
        });

        return .{
            .header = self.nodeRect(self.chat_ids.header),
            .history = self.nodeRect(self.chat_ids.history),
            .composer = composer_rect,
            .chat_input = self.nodeRect(self.chat_ids.chat_input),
            .send_button = self.nodeRect(self.chat_ids.send_button),
        };
    }

    fn nodeRect(self: *App, node_id: u64) Rect {
        if (self.layout_engine.getNode(node_id)) |node| {
            return node.rect;
        }
        return Rect.fromXYWH(0, 0, 0, 0);
    }

    fn setNodePreferred(
        self: *App,
        node_id: u64,
        preferred: [2]f32,
        flex: f32,
        align_self: ?zlayout.Alignment,
    ) void {
        if (self.layout_engine.getNode(node_id)) |node| {
            node.preferred_size = preferred;
            node.flex = flex;
            node.align_self = align_self;
            node.margin = .{ 0, 0, 0, 0 };
        }
    }

    fn drawSurfacePanel(self: *App, rect: Rect) void {
        const fill = Paint{ .solid = self.theme.colors.surface };
        self.drawPaintRect(rect, fill);
        self.drawRect(rect, self.theme.colors.border);
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

    fn drawMessageList(self: *App, rect: Rect) void {
        const line_h: f32 = 14.0;
        const usable_h = @max(0.0, rect.height() - 10.0);
        const visible_lines: usize = @as(usize, @intFromFloat(@floor(usable_h / line_h)));

        self.clampScroll();

        const total = self.messages.items.len;
        const scroll = @as(usize, @intCast(@max(0, self.scroll_lines)));

        const start = if (total > visible_lines + scroll)
            total - visible_lines - scroll
        else
            0;
        const end = @min(total, start + visible_lines);

        var y = rect.min[1] + 6.0;
        var i = start;
        while (i < end) : (i += 1) {
            const msg = self.messages.items[i];
            var line_buf: [1024]u8 = undefined;
            const raw = std.fmt.bufPrint(&line_buf, "[{s}] {s}", .{ msg.role, msg.content }) catch "";
            self.drawTextTrimmed(rect.min[0] + 6.0, y, rect.width() - 12.0, raw, self.theme.colors.text_primary);
            y += line_h;
        }
    }

    fn tryConnect(self: *App) !void {
        if (self.server_url.items.len == 0) {
            self.setConnectionState(.error_state, "Server URL cannot be empty");
            return;
        }

        self.setConnectionState(.connecting, "Connecting...");
        self.disconnect();

        var client = ws_client_mod.WebSocketClient.init(self.allocator, self.server_url.items, "") catch |err| {
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
        self.screen = .chat;
        self.focus = .none;
        self.scroll_lines = 0;

        self.clearSessions();
        try self.addSession("main", "Main");

        try self.appendMessage("system", "Connected to Spiderweb");
    }

    fn disconnect(self: *App) void {
        if (self.ws_client) |*client| {
            client.deinit();
            self.ws_client = null;
        }
        self.current_session_key = null;
        self.clearSessions();
    }

    fn sendChatMessage(self: *App) !void {
        if (self.chat_input.items.len == 0) return;
        try self.sendChatMessageText(self.chat_input.items);
        self.chat_input.clearRetainingCapacity();
        self.scroll_lines = 0;
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

        self.scroll_lines = 0;
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

    fn clampScroll(self: *App) void {
        const line_h: f32 = 14.0;
        const usable_h = @max(0.0, self.last_chat_history_rect.height() - 10.0);
        const visible_lines: usize = @as(usize, @intFromFloat(@floor(usable_h / line_h)));
        const total = self.messages.items.len;
        const max_scroll: i32 = @intCast(if (total > visible_lines) total - visible_lines else 0);

        if (self.scroll_lines < 0) self.scroll_lines = 0;
        if (self.scroll_lines > max_scroll) self.scroll_lines = max_scroll;
    }

    fn drawPaintRect(self: *App, rect: Rect, paint: Paint) void {
        switch (paint) {
            .solid => |color| self.drawFilledRect(rect, color),
            .gradient4 => |g| {
                // Use gradient for proper gradient support
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

    fn drawLabel(self: *App, rect: Rect, text: []const u8, color: [4]f32) void {
        self.drawTextTrimmed(rect.min[0], rect.min[1], rect.width(), text, color);
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

    fn windowSize(self: *App) WindowSize {
        var w: i32 = 0;
        var h: i32 = 0;
        _ = c.SDL_GetWindowSize(self.window, &w, &h);
        return .{ .w = w, .h = h };
    }
};

fn backspaceUtf8(list: *std.ArrayList(u8)) void {
    if (list.items.len == 0) return;

    var idx = list.items.len - 1;
    while (idx > 0 and (list.items[idx] & 0b1100_0000) == 0b1000_0000) {
        idx -= 1;
    }
    list.items.len = idx;
}

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
