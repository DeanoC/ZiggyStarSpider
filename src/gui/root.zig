const std = @import("std");
const zui = @import("ziggy-ui");
const ws_client_mod = @import("websocket_client.zig");

const c = @cImport({
    @cInclude("SDL3/SDL.h");
});

const widgets = zui.widgets;
const zlayout = zui.core.layout;
const zcolors = zui.theme.colors;

const Rect = zui.core.Rect;
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

const ChatMessage = struct {
    role: []u8,
    content: []u8,
};

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
    renderer: *c.SDL_Renderer,

    screen: Screen = .settings,
    focus: FocusField = .server_url,

    server_url: std.ArrayList(u8) = .empty,
    chat_input: std.ArrayList(u8) = .empty,
    messages: std.ArrayList(ChatMessage) = .empty,

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

    pub fn init(allocator: std.mem.Allocator) !App {
        if (!c.SDL_Init(c.SDL_INIT_VIDEO | c.SDL_INIT_EVENTS)) {
            return error.SdlInitFailed;
        }

        const window = c.SDL_CreateWindow("ZiggyStarSpider GUI", 1024, 720, c.SDL_WINDOW_RESIZABLE) orelse {
            return error.CreateWindowFailed;
        };

        const renderer = c.SDL_CreateRenderer(window, null) orelse {
            c.SDL_DestroyWindow(window);
            return error.CreateRendererFailed;
        };

        _ = c.SDL_StartTextInput(window);

        zui.theme.setMode(.dark);

        var app = App{
            .allocator = allocator,
            .window = window,
            .renderer = renderer,
            .status_text = try allocator.dupe(u8, "Not connected"),
            .theme = zui.theme.current(),
            .layout_engine = zlayout.LayoutEngine.init(allocator),
            .settings_ids = undefined,
            .chat_ids = undefined,
        };
        errdefer app.layout_engine.deinit();
        errdefer allocator.free(app.status_text);

        try app.initLayoutTrees();
        try app.server_url.appendSlice(allocator, "ws://127.0.0.1:18790");
        return app;
    }

    pub fn deinit(self: *App) void {
        self.disconnect();

        for (self.messages.items) |msg| {
            self.allocator.free(msg.role);
            self.allocator.free(msg.content);
        }
        self.messages.deinit(self.allocator);
        self.server_url.deinit(self.allocator);
        self.chat_input.deinit(self.allocator);

        self.layout_engine.deinit();
        self.allocator.free(self.status_text);

        _ = c.SDL_StopTextInput(self.window);
        c.SDL_DestroyRenderer(self.renderer);
        c.SDL_DestroyWindow(self.window);
        c.SDL_Quit();
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
            self.mouse_clicked = false;
            self.mouse_released = false;

            try self.pollEvents();
            try self.pollWebSocket();

            self.drawFrame();
            _ = c.SDL_Delay(16);
        }
    }

    fn pollEvents(self: *App) !void {
        var event: c.SDL_Event = undefined;
        while (c.SDL_PollEvent(&event)) {
            switch (event.type) {
                c.SDL_EVENT_QUIT => self.running = false,
                c.SDL_EVENT_MOUSE_MOTION => {
                    self.mouse_x = event.motion.x;
                    self.mouse_y = event.motion.y;
                },
                c.SDL_EVENT_MOUSE_BUTTON_DOWN => {
                    if (event.button.button == c.SDL_BUTTON_LEFT) {
                        self.mouse_down = true;
                        self.mouse_clicked = true;
                    }
                },
                c.SDL_EVENT_MOUSE_BUTTON_UP => {
                    if (event.button.button == c.SDL_BUTTON_LEFT) {
                        self.mouse_down = false;
                        self.mouse_released = true;
                    }
                },
                c.SDL_EVENT_MOUSE_WHEEL => self.handleMouseWheel(event.wheel.y),
                c.SDL_EVENT_KEY_DOWN => try self.handleKeyDown(event.key.key),
                c.SDL_EVENT_TEXT_INPUT => try self.handleTextInput(std.mem.span(event.text.text)),
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

    fn handleKeyDown(self: *App, key: c.SDL_Keycode) !void {
        if (key == c.SDLK_ESCAPE) {
            self.running = false;
            return;
        }

        if (key == c.SDLK_TAB) {
            switch (self.screen) {
                .settings => self.focus = .server_url,
                .chat => self.focus = if (self.focus == .chat_input) .none else .chat_input,
            }
            return;
        }

        if (key == c.SDLK_BACKSPACE) {
            switch (self.focus) {
                .server_url => backspaceUtf8(&self.server_url),
                .chat_input => backspaceUtf8(&self.chat_input),
                .none => {},
            }
            return;
        }

        if (key == c.SDLK_RETURN or key == c.SDLK_KP_ENTER) {
            switch (self.screen) {
                .settings => try self.tryConnect(),
                .chat => try self.sendChatMessage(),
            }
            return;
        }
    }

    fn handleTextInput(self: *App, text: []const u8) !void {
        if (text.len == 0) return;

        switch (self.focus) {
            .server_url => {
                for (text) |ch| {
                    if (ch >= 32 and ch < 127) {
                        try self.server_url.append(self.allocator, ch);
                    }
                }
            },
            .chat_input => {
                for (text) |ch| {
                    if (ch >= 32 and ch < 127) {
                        try self.chat_input.append(self.allocator, ch);
                    }
                }
            },
            .none => {},
        }
    }

    fn drawFrame(self: *App) void {
        self.theme = zui.theme.current();

        const bg = self.theme.colors.background;
        _ = c.SDL_SetRenderDrawColor(self.renderer, colorToU8(bg[0]), colorToU8(bg[1]), colorToU8(bg[2]), 255);
        _ = c.SDL_RenderClear(self.renderer);

        switch (self.screen) {
            .settings => self.drawSettingsScreen(),
            .chat => self.drawChatScreen(),
        }

        _ = c.SDL_RenderPresent(self.renderer);
    }

    fn drawSettingsScreen(self: *App) void {
        const dims = self.windowSize();
        const rects = self.computeSettingsRects(dims) catch return;

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
        const rects = self.computeChatRects(dims) catch return;

        self.last_chat_history_rect = rects.history;
        self.clampScroll();

        var header_buf: [1024]u8 = undefined;
        const header = std.fmt.bufPrint(&header_buf, "Connected: {s}", .{self.server_url.items}) catch "Connected";
        self.drawLabel(rects.header, header, self.theme.colors.text_primary);

        self.drawSurfacePanel(rects.history);
        self.drawMessageList(rects.history);

        const chat_focused = self.drawTextInputWidget(
            rects.chat_input,
            self.chat_input.items,
            self.focus == .chat_input,
            .{ .placeholder = "Type your message..." },
        );

        if (chat_focused) {
            self.focus = .chat_input;
        } else if (self.mouse_clicked and rects.history.contains(.{ self.mouse_x, self.mouse_y })) {
            self.focus = .none;
        }

        const send_clicked = self.drawButtonWidget(rects.send_button, "Send", .{ .variant = .primary });
        if (send_clicked) {
            self.sendChatMessage() catch {};
        }
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
        self.focus = .chat_input;
        self.scroll_lines = 0;

        try self.appendMessage("system", "Connected to Spiderweb");
    }

    fn disconnect(self: *App) void {
        if (self.ws_client) |*client| {
            client.deinit();
            self.ws_client = null;
        }
    }

    fn sendChatMessage(self: *App) !void {
        if (self.chat_input.items.len == 0) return;

        const msg_copy = try self.allocator.dupe(u8, self.chat_input.items);
        defer self.allocator.free(msg_copy);

        try self.appendMessage("user", msg_copy);

        if (self.ws_client) |*client| {
            var payload = std.ArrayList(u8).empty;
            defer payload.deinit(self.allocator);

            try payload.appendSlice(self.allocator, "{\"type\":\"chat\",\"content\":\"");
            for (msg_copy) |ch| {
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

        self.chat_input.clearRetainingCapacity();
        self.scroll_lines = 0;
    }

    fn appendMessage(self: *App, role: []const u8, content: []const u8) !void {
        try self.messages.append(self.allocator, .{
            .role = try self.allocator.dupe(u8, role),
            .content = try self.allocator.dupe(u8, content),
        });

        if (self.messages.items.len > 500) {
            const oldest = self.messages.orderedRemove(0);
            self.allocator.free(oldest.role);
            self.allocator.free(oldest.content);
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
                const avg: [4]f32 = .{
                    (g.tl[0] + g.tr[0] + g.bl[0] + g.br[0]) * 0.25,
                    (g.tl[1] + g.tr[1] + g.bl[1] + g.br[1]) * 0.25,
                    (g.tl[2] + g.tr[2] + g.bl[2] + g.br[2]) * 0.25,
                    (g.tl[3] + g.tr[3] + g.bl[3] + g.br[3]) * 0.25,
                };
                self.drawFilledRect(rect, avg);
            },
            .image => {
                self.drawFilledRect(rect, self.theme.colors.surface);
            },
        }
    }

    fn drawFilledRect(self: *App, rect: Rect, color: [4]f32) void {
        _ = c.SDL_SetRenderDrawColor(
            self.renderer,
            colorToU8(color[0]),
            colorToU8(color[1]),
            colorToU8(color[2]),
            colorToU8(color[3]),
        );
        var sdl_rect = c.SDL_FRect{ .x = rect.min[0], .y = rect.min[1], .w = rect.width(), .h = rect.height() };
        _ = c.SDL_RenderFillRect(self.renderer, &sdl_rect);
    }

    fn drawRect(self: *App, rect: Rect, color: [4]f32) void {
        _ = c.SDL_SetRenderDrawColor(
            self.renderer,
            colorToU8(color[0]),
            colorToU8(color[1]),
            colorToU8(color[2]),
            colorToU8(color[3]),
        );
        var sdl_rect = c.SDL_FRect{ .x = rect.min[0], .y = rect.min[1], .w = rect.width(), .h = rect.height() };
        _ = c.SDL_RenderRect(self.renderer, &sdl_rect);
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
        var buf: [1024]u8 = undefined;
        const z = std.fmt.bufPrintZ(&buf, "{s}", .{text}) catch return;
        _ = c.SDL_SetRenderDrawColor(
            self.renderer,
            colorToU8(color[0]),
            colorToU8(color[1]),
            colorToU8(color[2]),
            colorToU8(color[3]),
        );
        _ = c.SDL_RenderDebugText(self.renderer, x, y, z.ptr);
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

fn colorToU8(component: f32) u8 {
    const scaled = @round(std.math.clamp(component, 0.0, 1.0) * 255.0);
    return @as(u8, @intFromFloat(scaled));
}

fn backspaceUtf8(list: *std.ArrayList(u8)) void {
    if (list.items.len == 0) return;

    var idx = list.items.len - 1;
    while (idx > 0 and (list.items[idx] & 0b1100_0000) == 0b1000_0000) {
        idx -= 1;
    }
    list.items.len = idx;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var app = try App.init(gpa.allocator());
    defer app.deinit();

    try app.run();
}
