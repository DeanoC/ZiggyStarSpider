const std = @import("std");
const tui = @import("tui");

const cli_args = @import("cli_args");
const WebSocketClient = @import("websocket_client").WebSocketClient;
const Config = @import("client_config").Config;

const ConnectScreen = @import("screens/connect.zig").ConnectScreen;
const ChatScreen = @import("screens/chat.zig").ChatScreen;

pub const ConnectionState = enum {
    disconnected,
    connecting,
    connected,
    err,
};

pub const Screen = enum {
    connect,
    chat,
};

pub const AppState = struct {
    allocator: std.mem.Allocator,

    // Connection
    ws_client: ?WebSocketClient = null,
    connection_state: ConnectionState = .disconnected,
    connection_error: ?[]const u8 = null,

    // Session
    session_key: ?[]const u8 = null,

    // Config
    config: Config,
    options: cli_args.Options,

    // UI State
    current_screen: Screen = .connect,
    should_quit: bool = false,

    // Messages for chat
    messages: std.ArrayListUnmanaged(Message),

    pub const Message = struct {
        sender: []const u8,
        content: []const u8,
        timestamp: i64,
        is_user: bool,
    };

    pub fn init(allocator: std.mem.Allocator, options: cli_args.Options) !AppState {
        const config = try Config.load(allocator);

        return .{
            .allocator = allocator,
            .config = config,
            .options = options,
            .messages = .empty,
        };
    }

    pub fn deinit(self: *AppState) void {
        if (self.ws_client) |*client| {
            client.deinit();
        }
        if (self.session_key) |key| {
            self.allocator.free(key);
        }
        if (self.connection_error) |err| {
            self.allocator.free(err);
        }
        
        for (self.messages.items) |msg| {
            self.allocator.free(msg.sender);
            self.allocator.free(msg.content);
        }
        self.messages.deinit(self.allocator);
        
        self.config.deinit();
    }

    pub fn connect(self: *AppState, url: []const u8) !void {
        self.connection_state = .connecting;

        // Clean up existing client if any
        if (self.ws_client) |*client| {
            client.deinit();
        }

        // Create new client
        self.ws_client = WebSocketClient.init(self.allocator, url, self.config.token);

        // Attempt connection
        self.ws_client.?.connect() catch |err| {
            self.connection_state = .err;
            if (self.connection_error) |old_err| {
                self.allocator.free(old_err);
            }
            self.connection_error = try std.fmt.allocPrint(self.allocator, "{s}", .{@errorName(err)});
            return err;
        };

        self.connection_state = .connected;
        self.current_screen = .chat;
    }

    pub fn disconnect(self: *AppState) void {
        if (self.ws_client) |*client| {
            client.disconnect();
            client.deinit();
            self.ws_client = null;
        }
        self.connection_state = .disconnected;
        self.current_screen = .connect;
    }

    pub fn sendMessage(self: *AppState, content: []const u8) !void {
        if (self.ws_client == null or self.connection_state != .connected) {
            return error.NotConnected;
        }

        const client = &self.ws_client.?;

        var payload = std.ArrayListUnmanaged(u8).empty;
        defer payload.deinit(self.allocator);

        try payload.appendSlice(self.allocator, "{\"type\":\"chat.send\",");
        if (client.session_key) |key| {
            try payload.appendSlice(self.allocator, "\"sessionKey\":\"");
            try payload.appendSlice(self.allocator, key);
            try payload.appendSlice(self.allocator, "\",");
        }
        try payload.appendSlice(self.allocator, "\"content\":\"");
        
        // Escape the content
        for (content) |c| {
            if (c == '"' or c == '\\') {
                try payload.append(self.allocator, '\\');
            }
            try payload.append(self.allocator, c);
        }
        
        try payload.appendSlice(self.allocator, "\"}");

        try client.send(payload.items);

        // Add to local messages
        const msg = Message{
            .sender = try self.allocator.dupe(u8, "You"),
            .content = try self.allocator.dupe(u8, content),
            .timestamp = std.time.timestamp(),
            .is_user = true,
        };
        try self.messages.append(self.allocator, msg);
    }

    pub fn pollMessages(self: *AppState) !void {
        if (self.ws_client == null or self.connection_state != .connected) {
            return;
        }

        const client = &self.ws_client.?;

        // Try to read any pending messages
        while (try client.read()) |response| {
            defer self.allocator.free(response);

            // Try to parse message
            const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, response, .{}) catch continue;
            defer parsed.deinit();

            if (parsed.value != .object) continue;
            const msg_obj = parsed.value.object;

            // Handle sessionKey
            if (msg_obj.get("sessionKey")) |sk| {
                if (sk == .string) {
                    if (client.session_key) |old| self.allocator.free(old);
                    client.session_key = try self.allocator.dupe(u8, sk.string);
                }
            }

            // Handle content
            const msg_type = msg_obj.get("type");
            if (msg_type) |mt| {
                if (mt == .string) {
                    if (std.mem.eql(u8, mt.string, "chat.receive") or 
                        std.mem.eql(u8, mt.string, "session.receive")) {
                        if (msg_obj.get("content")) |content| {
                            if (content == .string) {
                                const msg = Message{
                                    .sender = try self.allocator.dupe(u8, "AI"),
                                    .content = try self.allocator.dupe(u8, content.string),
                                    .timestamp = std.time.timestamp(),
                                    .is_user = false,
                                };
                                try self.messages.append(self.allocator, msg);
                            }
                        }
                    }
                }
            }
        }
    }
};

/// Root widget that manages screen switching
pub const RootWidget = struct {
    state: *AppState,
    connect_screen: ConnectScreen,
    chat_screen: ChatScreen,

    pub fn init(state: *AppState) RootWidget {
        return .{
            .state = state,
            .connect_screen = ConnectScreen.init(state),
            .chat_screen = ChatScreen.init(state),
        };
    }

    pub fn deinit(self: *RootWidget) void {
        self.connect_screen.deinit();
        self.chat_screen.deinit();
    }

    pub fn render(self: *RootWidget, ctx: *tui.RenderContext) void {
        switch (self.state.current_screen) {
            .connect => self.connect_screen.render(ctx),
            .chat => self.chat_screen.render(ctx),
        }
    }

    pub fn handleEvent(self: *RootWidget, event: tui.Event) tui.EventResult {
        switch (self.state.current_screen) {
            .connect => return self.connect_screen.handleEvent(event),
            .chat => return self.chat_screen.handleEvent(event),
        }
    }
};

pub const App = struct {
    allocator: std.mem.Allocator,
    state: AppState,
    
    // TUI App
    tui_app: tui.App,

    // Root widget
    root_widget: RootWidget,

    pub fn init(allocator: std.mem.Allocator, options: cli_args.Options) !App {
        var state = try AppState.init(allocator, options);
        errdefer state.deinit();

        var tui_app = try tui.App.initWithAllocator(allocator, .{
            .alternate_screen = true,
            .hide_cursor = false,
            .enable_mouse = true,
        });
        errdefer tui_app.deinit();

        var root_widget = RootWidget.init(&state);
        errdefer root_widget.deinit();

        return .{
            .allocator = allocator,
            .state = state,
            .tui_app = tui_app,
            .root_widget = root_widget,
        };
    }

    pub fn deinit(self: *App) void {
        self.root_widget.deinit();
        self.tui_app.deinit();
        self.state.deinit();
    }

    pub fn run(self: *App) !void {
        // Auto-connect if configured
        if (self.state.config.auto_connect_on_launch) {
            const url = self.state.config.connect_host_override orelse self.state.config.server_url;
            _ = self.state.connect(url) catch {};
        }

        // Set root widget
        try self.tui_app.setRoot(&self.root_widget);

        // Run the app
        try self.tui_app.run();
    }
};
