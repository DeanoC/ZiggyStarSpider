const std = @import("std");
const zui_theme = @import("ziggy_ui_theme");
const zui_profile = @import("ziggy_ui_profile");
const ws_client_mod = @import("websocket_client.zig");

const c = @cImport({
    @cInclude("SDL3/SDL.h");
});

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

const Rect = struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,

    fn contains(self: Rect, px: f32, py: f32) bool {
        return px >= self.x and px <= self.x + self.w and py >= self.y and py <= self.y + self.h;
    }
};

const widgets = struct {
    pub const ButtonState = struct {
        hovered: bool,
        pressed: bool,
    };

    pub fn buttonState(rect: Rect, mouse_pos: [2]f32, mouse_down: bool) ButtonState {
        const inside = rect.contains(mouse_pos[0], mouse_pos[1]);
        return .{
            .hovered = inside,
            .pressed = inside and mouse_down,
        };
    }

    pub const TextInputState = struct {
        hovered: bool,
        focused: bool,
    };

    pub fn textInputState(rect: Rect, mouse_pos: [2]f32, mouse_clicked: bool, currently_focused: bool) TextInputState {
        const inside = rect.contains(mouse_pos[0], mouse_pos[1]);
        return .{
            .hovered = inside,
            .focused = if (mouse_clicked) inside else currently_focused,
        };
    }
};

const ChatMessage = struct {
    role: []u8,
    content: []u8,
};

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
    ui_profile: zui_profile.Profile,
    theme: *const zui_theme.Theme,

    running: bool = true,

    mouse_x: f32 = 0,
    mouse_y: f32 = 0,
    mouse_down: bool = false,
    mouse_clicked: bool = false,
    mouse_released: bool = false,

    scroll_lines: i32 = 0,

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

        const caps = zui_profile.PlatformCaps.defaultForTarget();
        const profile = zui_profile.defaultsFor(.desktop, caps);

        var app = App{
            .allocator = allocator,
            .window = window,
            .renderer = renderer,
            .status_text = try allocator.dupe(u8, "Not connected"),
            .ui_profile = profile,
            .theme = zui_theme.get(.dark),
        };

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

        self.allocator.free(self.status_text);

        _ = c.SDL_StopTextInput(self.window);
        c.SDL_DestroyRenderer(self.renderer);
        c.SDL_DestroyWindow(self.window);
        c.SDL_Quit();
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
                c.SDL_EVENT_MOUSE_WHEEL => {
                    self.handleMouseWheel(event.wheel.y);
                },
                c.SDL_EVENT_KEY_DOWN => {
                    try self.handleKeyDown(event.key.key);
                },
                c.SDL_EVENT_TEXT_INPUT => {
                    try self.handleTextInput(std.mem.span(event.text.text));
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

        const dims = self.windowSize();
        const control_h = self.ui_profile.hit_target_min_px + 4;
        const history_rect = Rect{
            .x = 20,
            .y = 50,
            .w = @as(f32, @floatFromInt(dims.w)) - 40,
            .h = @as(f32, @floatFromInt(dims.h)) - 50 - (control_h + 34),
        };

        if (!history_rect.contains(self.mouse_x, self.mouse_y)) return;

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
                .settings => {
                    self.focus = .server_url;
                },
                .chat => {
                    self.focus = if (self.focus == .chat_input) .none else .chat_input;
                },
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

        self.drawText(24, 18, "ZiggyStarSpider - GUI Client");
        self.drawText(24, 36, "Settings / Auth");

        self.drawText(24, 74, "Server URL:");

        const control_h = self.ui_profile.hit_target_min_px + 4;
        const url_rect = Rect{ .x = 24, .y = 92, .w = @as(f32, @floatFromInt(dims.w)) - 48, .h = control_h };
        const connect_rect = Rect{ .x = 24, .y = 144, .w = 140, .h = control_h };

        const url_state = widgets.textInputState(
            url_rect,
            .{ self.mouse_x, self.mouse_y },
            self.mouse_clicked,
            self.focus == .server_url,
        );
        if (url_state.focused) self.focus = .server_url;
        if (self.mouse_clicked and !url_rect.contains(self.mouse_x, self.mouse_y)) {
            self.focus = .none;
        }

        self.drawInput(url_rect, self.server_url.items, self.focus == .server_url);

        const connect_state = widgets.buttonState(
            connect_rect,
            .{ self.mouse_x, self.mouse_y },
            self.mouse_down,
        );

        self.drawButton(connect_rect, "Connect", connect_state.hovered, self.connection_state == .connecting);

        if (self.mouse_released and connect_rect.contains(self.mouse_x, self.mouse_y) and self.connection_state != .connecting) {
            self.tryConnect() catch {};
        }

        self.drawConnectionIndicator(24, 204);
        self.drawText(48, 206, self.status_text);
        self.drawText(24, 240, "Tip: Enter URL, press Connect, then chat.");
    }

    fn drawChatScreen(self: *App) void {
        const dims = self.windowSize();

        const top_h: f32 = 32;
        const control_h = self.ui_profile.hit_target_min_px + 4;
        const history_rect = Rect{
            .x = 20,
            .y = top_h + 18,
            .w = @as(f32, @floatFromInt(dims.w)) - 40,
            .h = @as(f32, @floatFromInt(dims.h)) - (top_h + 18) - (control_h + 34),
        };
        const input_rect = Rect{ .x = 20, .y = @as(f32, @floatFromInt(dims.h)) - (control_h + 24), .w = @as(f32, @floatFromInt(dims.w)) - 150, .h = control_h };
        const send_rect = Rect{ .x = @as(f32, @floatFromInt(dims.w)) - 118, .y = @as(f32, @floatFromInt(dims.h)) - (control_h + 24), .w = 98, .h = control_h };

        self.drawText(20, 10, "Connected");
        self.drawText(120, 10, self.server_url.items);

        self.drawBox(history_rect, 36, 38, 44, true);
        self.drawBox(input_rect, 36, 38, 44, true);

        if (self.mouse_clicked and history_rect.contains(self.mouse_x, self.mouse_y)) {
            self.focus = .none;
        }

        const input_state = widgets.textInputState(
            input_rect,
            .{ self.mouse_x, self.mouse_y },
            self.mouse_clicked,
            self.focus == .chat_input,
        );
        if (input_state.focused) self.focus = .chat_input;

        self.drawInput(input_rect, self.chat_input.items, self.focus == .chat_input);

        const send_state = widgets.buttonState(
            send_rect,
            .{ self.mouse_x, self.mouse_y },
            self.mouse_down,
        );

        self.drawButton(send_rect, "Send", send_state.hovered, false);
        if (self.mouse_released and send_rect.contains(self.mouse_x, self.mouse_y)) {
            self.sendChatMessage() catch {};
        }

        self.drawMessageList(history_rect);
    }

    fn drawMessageList(self: *App, rect: Rect) void {
        const line_h: f32 = 14;
        const max_visible_f = @max(0, @floor((rect.h - 10) / line_h));
        const visible_lines: usize = @as(usize, @intFromFloat(max_visible_f));

        self.clampScroll();

        const total = self.messages.items.len;
        const scroll = @as(usize, @intCast(@max(0, self.scroll_lines)));

        const start = if (total > visible_lines + scroll)
            total - visible_lines - scroll
        else
            0;
        const end = @min(total, start + visible_lines);

        var y = rect.y + 6;
        var i = start;
        while (i < end) : (i += 1) {
            const msg = self.messages.items[i];
            var line_buf: [1024]u8 = undefined;
            const raw = std.fmt.bufPrint(&line_buf, "[{s}] {s}", .{ msg.role, msg.content }) catch "";
            self.drawTextTrimmed(rect.x + 6, y, rect.w - 12, raw);
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

        // Keep memory bounded.
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
        const dims = self.windowSize();
        const control_h = self.ui_profile.hit_target_min_px + 4;
        const history_h = @as(f32, @floatFromInt(dims.h)) - 50 - (control_h + 34);
        const line_h: f32 = 14;
        const visible_lines: usize = @as(usize, @intFromFloat(@max(0, @floor((history_h - 10) / line_h))));
        const total = self.messages.items.len;
        const max_scroll: i32 = @intCast(if (total > visible_lines) total - visible_lines else 0);

        if (self.scroll_lines < 0) self.scroll_lines = 0;
        if (self.scroll_lines > max_scroll) self.scroll_lines = max_scroll;
    }

    fn drawConnectionIndicator(self: *App, x: f32, y: f32) void {
        const color = switch (self.connection_state) {
            .disconnected => [_]u8{ 200, 80, 80, 255 },
            .connecting => [_]u8{ 220, 200, 60, 255 },
            .connected => [_]u8{ 90, 210, 90, 255 },
            .error_state => [_]u8{ 230, 120, 70, 255 },
        };

        const r = Rect{ .x = x, .y = y, .w = 14, .h = 14 };
        self.drawFilledRect(r, color[0], color[1], color[2], color[3]);
    }

    fn drawInput(self: *App, rect: Rect, text: []const u8, focused: bool) void {
        const border: [4]u8 = if (focused) .{ 120, 180, 255, 255 } else .{ 90, 95, 110, 255 };
        self.drawBox(rect, 32, 34, 40, true);
        self.drawRect(rect, border[0], border[1], border[2], border[3]);

        if (text.len == 0 and focused) {
            self.drawText(rect.x + 8, rect.y + 11, "_");
        } else {
            self.drawTextTrimmed(rect.x + 8, rect.y + 11, rect.w - 16, text);
            if (focused) {
                const caret_x = rect.x + 8 + @as(f32, @floatFromInt(@min(text.len, @as(usize, @intFromFloat((rect.w - 16) / 8.0))))) * 8;
                self.drawText(caret_x, rect.y + 11, "_");
            }
        }
    }

    fn drawButton(self: *App, rect: Rect, label: []const u8, hovered: bool, disabled: bool) void {
        if (disabled) {
            self.drawBox(rect, 70, 70, 74, true);
        } else if (hovered) {
            self.drawBox(rect, 82, 116, 198, true);
        } else {
            self.drawBox(rect, 62, 92, 164, true);
        }
        self.drawRect(rect, 120, 130, 160, 255);
        self.drawText(rect.x + 12, rect.y + 12, label);
    }

    fn drawBox(self: *App, rect: Rect, r: u8, g: u8, b: u8, fill: bool) void {
        if (fill) {
            self.drawFilledRect(rect, r, g, b, 255);
        } else {
            self.drawRect(rect, r, g, b, 255);
        }
    }

    fn drawFilledRect(self: *App, rect: Rect, r: u8, g: u8, b: u8, a: u8) void {
        _ = c.SDL_SetRenderDrawColor(self.renderer, r, g, b, a);
        var sdl_rect = c.SDL_FRect{ .x = rect.x, .y = rect.y, .w = rect.w, .h = rect.h };
        _ = c.SDL_RenderFillRect(self.renderer, &sdl_rect);
    }

    fn drawRect(self: *App, rect: Rect, r: u8, g: u8, b: u8, a: u8) void {
        _ = c.SDL_SetRenderDrawColor(self.renderer, r, g, b, a);
        var sdl_rect = c.SDL_FRect{ .x = rect.x, .y = rect.y, .w = rect.w, .h = rect.h };
        _ = c.SDL_RenderRect(self.renderer, &sdl_rect);
    }

    fn drawText(self: *App, x: f32, y: f32, text: []const u8) void {
        var buf: [1024]u8 = undefined;
        const z = std.fmt.bufPrintZ(&buf, "{s}", .{text}) catch return;
        const fg = self.theme.colors.text_primary;
        _ = c.SDL_SetRenderDrawColor(self.renderer, colorToU8(fg[0]), colorToU8(fg[1]), colorToU8(fg[2]), 255);
        _ = c.SDL_RenderDebugText(self.renderer, x, y, z.ptr);
    }

    fn drawTextTrimmed(self: *App, x: f32, y: f32, max_w: f32, text: []const u8) void {
        const max_chars = @as(usize, @intFromFloat(@max(0, @floor(max_w / 8.0))));
        if (text.len <= max_chars) {
            self.drawText(x, y, text);
            return;
        }

        if (max_chars <= 3) {
            self.drawText(x, y, "...");
            return;
        }

        var tmp: [1024]u8 = undefined;
        const copy_len = @min(max_chars - 3, @min(text.len, tmp.len - 3));
        if (copy_len > 0) @memcpy(tmp[0..copy_len], text[0..copy_len]);
        tmp[copy_len] = '.';
        tmp[copy_len + 1] = '.';
        tmp[copy_len + 2] = '.';
        self.drawText(x, y, tmp[0 .. copy_len + 3]);
    }

    fn windowSize(self: *App) struct { w: i32, h: i32 } {
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
