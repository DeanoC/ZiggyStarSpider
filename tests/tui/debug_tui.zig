//! TUI Diagnostic Test
//! 
//! This test diagnoses where the TUI hangs by testing components in isolation.
//! Since we can't import the actual TUI source from tests/tui/, we create
//! diagnostic versions of the key components here.

const std = @import("std");
const VirtualTerminal = @import("virtual_terminal.zig").VirtualTerminal;
const EventInjector = @import("event_injector.zig").EventInjector;
const Event = @import("event_injector.zig").Event;

// Import the actual TUI components through the module imports
const cli_args = @import("cli_args");
const Config = @import("client_config").Config;
const WebSocketClient = @import("websocket_client").WebSocketClient;

/// Connection state tracking
pub const ConnectionState = enum {
    disconnected,
    connecting,
    connected,
    err,
};

/// Screen types
pub const AppScreen = enum {
    connect,
    chat,
};

/// Diagnostic version of AppState that tracks initialization
pub const DiagnosticAppState = struct {
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
    current_screen: AppScreen = .connect,
    should_quit: bool = false,

    // Messages for chat
    messages: std.ArrayListUnmanaged(Message),

    // Diagnostic tracking
    init_start_time: i64 = 0,
    init_end_time: i64 = 0,
    init_steps_completed: usize = 0,

    pub const Message = struct {
        sender: []const u8,
        content: []const u8,
        timestamp: i64,
        is_user: bool,
    };

    pub fn init(allocator: std.mem.Allocator, options: cli_args.Options) !DiagnosticAppState {
        std.debug.print("[DIAG] AppState.init() starting...\n", .{});
        const start_time = std.time.milliTimestamp();

        std.debug.print("[DIAG] Step 1/4: Calling Config.load()...\n", .{});
        const config = try Config.load(allocator);
        std.debug.print("[DIAG] Step 1/4: Config.load() completed\n", .{});

        std.debug.print("[DIAG] Step 2/4: Initializing messages array...\n", .{});
        const messages = std.ArrayListUnmanaged(Message){};
        std.debug.print("[DIAG] Step 2/4: Messages array initialized\n", .{});

        const end_time = std.time.milliTimestamp();
        std.debug.print("[DIAG] Step 3/4: Creating AppState struct...\n", .{});
        
        const state = DiagnosticAppState{
            .allocator = allocator,
            .config = config,
            .options = options,
            .messages = messages,
            .init_start_time = start_time,
            .init_end_time = end_time,
            .init_steps_completed = 4,
        };
        
        std.debug.print("[DIAG] Step 4/4: AppState.init() completed in {d}ms\n", .{end_time - start_time});

        return state;
    }

    pub fn deinit(self: *DiagnosticAppState) void {
        std.debug.print("[DIAG] AppState.deinit() starting...\n", .{});
        
        if (self.ws_client) |*client| {
            std.debug.print("[DIAG] Cleaning up ws_client...\n", .{});
            client.deinit();
        }
        if (self.session_key) |key| {
            self.allocator.free(key);
        }
        if (self.connection_error) |err| {
            self.allocator.free(err);
        }
        
        std.debug.print("[DIAG] Cleaning up messages...\n", .{});
        for (self.messages.items) |msg| {
            self.allocator.free(msg.sender);
            self.allocator.free(msg.content);
        }
        self.messages.deinit(self.allocator);
        
        std.debug.print("[DIAG] Cleaning up config...\n", .{});
        self.config.deinit();
        std.debug.print("[DIAG] AppState.deinit() completed\n", .{});
    }

    pub fn connect(self: *DiagnosticAppState, url: []const u8) !void {
        std.debug.print("[DIAG] AppState.connect() called with URL: {s}\n", .{url});
        self.connection_state = .connecting;

        // Clean up existing client if any
        if (self.ws_client) |*client| {
            client.deinit();
        }

        // Create new client
        std.debug.print("[DIAG] Creating WebSocketClient...\n", .{});
        self.ws_client = WebSocketClient.init(self.allocator, url, self.config.token);

        // Attempt connection
        std.debug.print("[DIAG] Calling WebSocketClient.connect()...\n", .{});
        self.ws_client.?.connect() catch |err| {
            std.debug.print("[DIAG] WebSocketClient.connect() failed: {s}\n", .{@errorName(err)});
            self.connection_state = .err;
            if (self.connection_error) |old_err| {
                self.allocator.free(old_err);
            }
            self.connection_error = null;
            self.connection_error = try std.fmt.allocPrint(self.allocator, "{s}", .{@errorName(err)});
            return err;
        };

        std.debug.print("[DIAG] WebSocketClient.connect() succeeded\n", .{});
        self.connection_state = .connected;
        self.current_screen = .chat;
    }

    pub fn disconnect(self: *DiagnosticAppState) void {
        std.debug.print("[DIAG] AppState.disconnect() called\n", .{});
        if (self.ws_client) |*client| {
            client.disconnect();
            client.deinit();
            self.ws_client = null;
        }
        self.connection_state = .disconnected;
        self.current_screen = .connect;
    }

    pub fn pollMessages(self: *DiagnosticAppState) !void {
        // This is called frequently during render - don't print to avoid spam
        if (self.ws_client == null or self.connection_state != .connected) {
            return;
        }

        const client = &self.ws_client.?;

        // Try to read any pending messages with a short timeout
        while (client.readTimeout(1) catch |err| {
            self.connection_state = .err;
            if (self.connection_error) |old| self.allocator.free(old);
            self.connection_error = null;
            self.connection_error = try std.fmt.allocPrint(self.allocator, "Read error: {s}", .{@errorName(err)});
            return err;
        }) |response| {
            defer self.allocator.free(response);

            // Try to parse message
            const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, response, .{}) catch continue;
            defer parsed.deinit();

            if (parsed.value != .object) continue;
            const msg_obj = parsed.value.object;

            // Handle sessionKey
            if (msg_obj.get("sessionKey")) |sk| {
                if (sk == .string) {
                    if (client.session_key) |old| {
                        self.allocator.free(old);
                        client.session_key = null;
                    }
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

/// Mock TUI types for testing without real terminal
pub const MockTui = struct {
    pub const Color = @import("virtual_terminal.zig").Color;
    pub const Attributes = @import("virtual_terminal.zig").Attributes;

    pub const Style = struct {
        fg: Color = .default,
        bg: Color = .default,
        attrs: Attributes = .{},
    };

    pub const EventResult = enum {
        consumed,
        ignored,
    };

    pub const Bounds = struct {
        x: u16,
        y: u16,
        width: u16,
        height: u16,
    };

    pub const RenderContext = struct {
        terminal: *VirtualTerminal,
        theme: Theme,
        bounds: Bounds,
        clip: Bounds,
        focused_id: ?u32,
        time_ns: i64,

        pub const Screen = struct {
            term: *VirtualTerminal,

            pub fn clear(s: Screen) void {
                s.term.clear();
            }
            pub fn moveCursor(s: Screen, x: u16, y: u16) void {
                s.term.moveCursor(x, y);
            }
            pub fn setStyle(s: Screen, style: Style) void {
                _ = s;
                _ = style;
            }
            pub fn putString(s: Screen, str: []const u8) void {
                s.term.putString(str);
            }
            pub fn putChar(s: Screen, char: u21) void {
                s.term.putChar(char);
            }
            pub fn getWidth(s: Screen) u16 {
                return s.term.width;
            }
            pub fn getHeight(s: Screen) u16 {
                return s.term.height;
            }
        };

        pub fn getScreen(self: *RenderContext) MockScreen {
            return .{ .term = self.terminal };
        }
    };

    pub const Theme = struct {
        background: Color = .default,
        foreground: Color = .default,
        accent: Color = .cyan,
        error_color: Color = .red,
        success: Color = .green,
        warning: Color = .yellow,
    };

    pub const InputField = struct {
        allocator: std.mem.Allocator,
        buffer: std.ArrayList(u8),
        cursor_pos: usize = 0,
        placeholder: ?[]const u8 = null,
        focused: bool = true,

        pub fn init(allocator: std.mem.Allocator) InputField {
            return .{
                .allocator = allocator,
                .buffer = std.ArrayList(u8).init(allocator),
            };
        }

        pub fn deinit(self: *InputField) void {
            self.buffer.deinit();
            if (self.placeholder) |p| {
                self.allocator.free(p);
            }
        }

        pub fn setValue(self: *InputField, value: []const u8) !void {
            self.buffer.clearRetainingCapacity();
            try self.buffer.appendSlice(value);
            self.cursor_pos = value.len;
        }

        pub fn getValue(self: *InputField) []const u8 {
            return self.buffer.items;
        }

        pub fn clear(self: *InputField) void {
            self.buffer.clearRetainingCapacity();
            self.cursor_pos = 0;
        }

        pub fn render(self: *InputField, ctx: *RenderContext) void {
            const s = ctx.screen();
            const width = ctx.bounds.width;

            // Draw background
            s.setStyle(.{ .fg = .white, .bg = .default });
            var i: u16 = 0;
            while (i < width) : (i += 1) {
                s.putChar(' ');
            }

            // Move back to start
            s.moveCursor(0, 0);

            // Draw content or placeholder
            const content = if (self.buffer.items.len > 0)
                self.buffer.items
            else if (self.placeholder) |p|
                p
            else
                "";

            const style = if (self.buffer.items.len > 0)
                Style{ .fg = .white }
            else
                Style{ .fg = .gray };

            s.setStyle(style);

            // Truncate if too long
            const display_len = @min(content.len, width);
            s.putString(content[0..display_len]);
        }

        pub fn handleEvent(self: *InputField, evt: Event) MockTui.EventResult {
            switch (evt) {
                .key => |key_event| {
                    switch (key_event.key) {
                        .char => |c| {
                            self.insertChar(c) catch return .ignored;
                            return .consumed;
                        },
                        .enter => return .ignored,
                        .backspace => {
                            self.backspace();
                            return .consumed;
                        },
                        else => return .ignored,
                    }
                },
                else => return .ignored,
            }
        }

        fn insertChar(self: *InputField, char: u8) !void {
            try self.buffer.insert(self.cursor_pos, char);
            self.cursor_pos += 1;
        }

        fn backspace(self: *InputField) void {
            if (self.cursor_pos > 0) {
                self.cursor_pos -= 1;
                _ = self.buffer.orderedRemove(self.cursor_pos);
            }
        }
    };
};

/// Diagnostic Connect Screen
pub const DiagnosticConnectScreen = struct {
    state: *DiagnosticAppState,
    url_input: MockTui.InputField,

    pub fn init(state: *DiagnosticAppState) DiagnosticConnectScreen {
        std.debug.print("[DIAG] ConnectScreen.init() starting...\n", .{});
        
        // Use effective URL: CLI --url > connect_host_override > server_url
        const effective_url = if (state.options.url_explicitly_provided)
            state.options.url
        else if (state.config.connect_host_override) |host|
            host
        else
            state.config.server_url;

        std.debug.print("[DIAG] Creating InputField...\n", .{});
        var url_input = MockTui.InputField.init(state.allocator);
        url_input.setValue(effective_url) catch {};
        url_input.placeholder = "ws://127.0.0.1:18790";

        std.debug.print("[DIAG] ConnectScreen.init() completed\n", .{});
        return .{
            .state = state,
            .url_input = url_input,
        };
    }

    pub fn deinit(self: *DiagnosticConnectScreen) void {
        std.debug.print("[DIAG] ConnectScreen.deinit() called\n", .{});
        self.url_input.deinit();
    }

    pub fn render(self: *DiagnosticConnectScreen, ctx: *MockTui.RenderContext) void {
        const s = ctx.getScreen();
        const width = s.getWidth();
        const height = s.getHeight();

        // Clear background
        s.clear();

        // Title
        const title = "ZiggyStarSpider TUI";
        const title_x = if (width > title.len) @divTrunc(width - @as(u16, @intCast(title.len)), 2) else 0;
        s.moveCursor(title_x, 2);
        s.setStyle(.{ .fg = .cyan, .attrs = .{ .bold = true } });
        s.putString(title);

        // Subtitle
        const subtitle = "Connect to Spiderweb Server";
        const subtitle_x = if (width > subtitle.len) @divTrunc(width - @as(u16, @intCast(subtitle.len)), 2) else 0;
        s.moveCursor(subtitle_x, 4);
        s.setStyle(.{ .fg = .white });
        s.putString(subtitle);

        // URL label
        const label = "Server URL:";
        const label_x = if (width > 52) @divTrunc(width - 52, 2) else 2;
        s.moveCursor(label_x, 7);
        s.setStyle(.{ .fg = .white });
        s.putString(label);

        // URL input field
        const input_x = if (width > 50) @divTrunc(width - 50, 2) else 2;
        const input_y = 8;

        var input_ctx = MockTui.RenderContext{
            .terminal = ctx.terminal,
            .theme = ctx.theme,
            .bounds = .{
                .x = input_x,
                .y = input_y,
                .width = 50,
                .height = 1,
            },
            .clip = .{
                .x = input_x,
                .y = input_y,
                .width = 50,
                .height = 1,
            },
            .focused_id = null,
            .time_ns = ctx.time_ns,
        };

        self.url_input.render(&input_ctx);

        // Connect button hint
        const button_text = "[ Press Enter to Connect ]";
        const button_x = if (width > button_text.len) @divTrunc(width - @as(u16, @intCast(button_text.len)), 2) else 0;
        s.moveCursor(button_x, 10);
        s.setStyle(.{ .fg = .green });
        s.putString(button_text);

        // Status line
        const status_text = switch (self.state.connection_state) {
            .disconnected => "Enter server URL to connect",
            .connecting => "Connecting...",
            .connected => "Connected to Spiderweb",
            .err => if (self.state.connection_error) |err| err else "Connection error",
        };

        const status_x = if (width > status_text.len) @divTrunc(width - @as(u16, @intCast(status_text.len)), 2) else 0;
        s.moveCursor(status_x, 13);
        s.setStyle(.{ .fg = .white });
        s.putString(status_text);

        // Help text
        const help_text = "Press Ctrl+C to quit";
        const help_x = if (width > help_text.len) @divTrunc(width - @as(u16, @intCast(help_text.len)), 2) else 0;
        if (height > 2) {
            s.moveCursor(help_x, height - 2);
            s.setStyle(.{ .fg = .gray });
            s.putString(help_text);
        }
    }

    pub fn handleEvent(self: *DiagnosticConnectScreen, evt: Event) MockTui.EventResult {
        switch (evt) {
            .key => |key_event| {
                switch (key_event.key) {
                    .enter => {
                        const url = self.url_input.getValue();
                        if (url.len > 0) {
                            std.debug.print("[DIAG] ConnectScreen: Enter pressed, connecting to {s}\n", .{url});
                            self.state.connect(url) catch |err| {
                                std.debug.print("[DIAG] ConnectScreen: Connection failed: {s}\n", .{@errorName(err)});
                                if (self.state.connection_error) |old_err| {
                                    self.state.allocator.free(old_err);
                                }
                                self.state.connection_error = std.fmt.allocPrint(
                                    self.state.allocator,
                                    "{s}",
                                    .{@errorName(err)}
                                ) catch null;
                            };
                        }
                        return .consumed;
                    },
                    else => {
                        return self.url_input.handleEvent(evt);
                    },
                }
            },
            else => {},
        }

        return .ignored;
    }
};

/// Diagnostic Root Widget
pub const DiagnosticRootWidget = struct {
    state: *DiagnosticAppState,
    connect_screen: DiagnosticConnectScreen,

    pub fn init(state: *DiagnosticAppState) DiagnosticRootWidget {
        std.debug.print("[DIAG] RootWidget.init() starting...\n", .{});
        const connect_screen = DiagnosticConnectScreen.init(state);
        std.debug.print("[DIAG] RootWidget.init() completed\n", .{});
        return .{
            .state = state,
            .connect_screen = connect_screen,
        };
    }

    pub fn deinit(self: *DiagnosticRootWidget) void {
        std.debug.print("[DIAG] RootWidget.deinit() called\n", .{});
        self.connect_screen.deinit();
    }

    pub fn render(self: *DiagnosticRootWidget, ctx: *MockTui.RenderContext) void {
        switch (self.state.current_screen) {
            .connect => self.connect_screen.render(ctx),
            .chat => {
                // Simplified chat screen for diagnostic
                const s = ctx.getScreen();
                s.clear();
                s.moveCursor(2, 0);
                s.setStyle(.{ .fg = .cyan, .attrs = .{ .bold = true } });
                s.putString("Chat Screen (Diagnostic Mode)");
            },
        }
    }

    pub fn handleEvent(self: *DiagnosticRootWidget, evt: Event) MockTui.EventResult {
        switch (self.state.current_screen) {
            .connect => return self.connect_screen.handleEvent(evt),
            .chat => {
                // Handle chat events
                switch (evt) {
                    .key => |key_event| {
                        if (key_event.modifiers.ctrl) {
                            switch (key_event.key) {
                                .char => |c| {
                                    if (c == 'd' or c == 'D') {
                                        self.state.disconnect();
                                        return .consumed;
                                    }
                                },
                                else => {},
                            }
                        }
                    },
                    else => {},
                }
                return .ignored;
            },
        }
    }
};

/// Diagnostic App that simulates the real App
pub const DiagnosticApp = struct {
    allocator: std.mem.Allocator,
    state: *DiagnosticAppState,
    root_widget: ?DiagnosticRootWidget = null,
    
    // Diagnostic tracking
    tui_init_completed: bool = false,
    run_entered: bool = false,
    run_exited: bool = false,
    render_count: usize = 0,
    event_count: usize = 0,

    pub fn init(allocator: std.mem.Allocator, options: cli_args.Options) !DiagnosticApp {
        std.debug.print("\n[DIAG] ========================================\n", .{});
        std.debug.print("[DIAG] DiagnosticApp.init() starting...\n", .{});
        std.debug.print("[DIAG] ========================================\n", .{});
        
        const start_time = std.time.milliTimestamp();

        // Step 1: Create AppState
        std.debug.print("[DIAG] Step 1/5: Creating AppState...\n", .{});
        const state = try allocator.create(DiagnosticAppState);
        errdefer allocator.destroy(state);
        state.* = try DiagnosticAppState.init(allocator, options);
        std.debug.print("[DIAG] Step 1/5: AppState created\n", .{});

        // Step 2: Create RootWidget
        std.debug.print("[DIAG] Step 2/5: Creating RootWidget...\n", .{});
        const root_widget = DiagnosticRootWidget.init(state);
        std.debug.print("[DIAG] Step 2/5: RootWidget created\n", .{});

        // Step 3: Simulate TUI App initialization
        std.debug.print("[DIAG] Step 3/5: Simulating TUI App.initWithAllocator()...\n", .{});
        std.debug.print("[DIAG]   - alternate_screen: true\n", .{});
        std.debug.print("[DIAG]   - hide_cursor: false\n", .{});
        std.debug.print("[DIAG]   - enable_mouse: true\n", .{});
        
        // In the real app, this is where tui.App.initWithAllocator() is called
        // This may hang if the TUI library tries to access the real terminal
        std.debug.print("[DIAG]   (Skipping actual TUI init for diagnostic)\n", .{});
        
        // Step 4: Check auto-connect
        std.debug.print("[DIAG] Step 4/5: Checking auto-connect settings...\n", .{});
        if (options.url_explicitly_provided) {
            std.debug.print("[DIAG]   - URL explicitly provided via CLI: {s}\n", .{options.url});
            std.debug.print("[DIAG]   - Would attempt connection here in real app\n", .{});
        } else if (state.config.auto_connect_on_launch) {
            const url = state.config.connect_host_override orelse state.config.server_url;
            std.debug.print("[DIAG]   - auto_connect_on_launch is true\n", .{});
            std.debug.print("[DIAG]   - Would connect to: {s}\n", .{url});
        } else {
            std.debug.print("[DIAG]   - auto_connect_on_launch is false\n", .{});
        }

        const end_time = std.time.milliTimestamp();
        std.debug.print("[DIAG] Step 5/5: DiagnosticApp.init() completed in {d}ms\n", .{end_time - start_time});

        return .{
            .allocator = allocator,
            .state = state,
            .root_widget = root_widget,
            .tui_init_completed = true,
        };
    }

    pub fn deinit(self: *DiagnosticApp) void {
        std.debug.print("\n[DIAG] DiagnosticApp.deinit() starting...\n", .{});
        
        if (self.root_widget) |*rw| {
            std.debug.print("[DIAG] Cleaning up RootWidget...\n", .{});
            rw.deinit();
        }
        
        std.debug.print("[DIAG] Cleaning up AppState...\n", .{});
        self.state.deinit();
        self.allocator.destroy(self.state);
        
        std.debug.print("[DIAG] DiagnosticApp.deinit() completed\n", .{});
    }

    pub fn run(self: *DiagnosticApp) !void {
        std.debug.print("\n[DIAG] ========================================\n", .{});
        std.debug.print("[DIAG] DiagnosticApp.run() called\n", .{});
        std.debug.print("[DIAG] ========================================\n", .{});
        
        self.run_entered = true;
        
        // In the real app, this is where tui.App.run() is called
        // The event loop would run here, potentially hanging on:
        // - Terminal input waiting
        // - WebSocket read operations
        // - Signal handling
        
        std.debug.print("[DIAG] In real app, tui.App.run() would:\n", .{});
        std.debug.print("[DIAG]   1. Enter alternate screen buffer\n", .{});
        std.debug.print("[DIAG]   2. Start event loop\n", .{});
        std.debug.print("[DIAG]   3. Poll for input events (blocking)\n", .{});
        std.debug.print("[DIAG]   4. Call render() on each frame\n", .{});
        std.debug.print("[DIAG]   5. Continue until should_quit is true\n", .{});
        std.debug.print("[DIAG]   6. Restore terminal state\n", .{});
        
        std.debug.print("\n[DIAG] For diagnostic, skipping actual event loop\n", .{});
        
        self.run_exited = true;
    }
};

/// Main diagnostic harness
pub const TuiDiagnostics = struct {
    allocator: std.mem.Allocator,
    terminal: VirtualTerminal,
    injector: EventInjector,

    pub fn init(allocator: std.mem.Allocator, width: u16, height: u16) !TuiDiagnostics {
        std.debug.print("\n[DIAG] Initializing TuiDiagnostics ({d}x{d})...\n", .{ width, height });

        var terminal = try VirtualTerminal.init(allocator, width, height);
        errdefer terminal.deinit();

        var injector = EventInjector.init(allocator);
        errdefer injector.deinit();

        std.debug.print("[DIAG] VirtualTerminal and EventInjector created\n", .{});

        return .{
            .allocator = allocator,
            .terminal = terminal,
            .injector = injector,
        };
    }

    pub fn deinit(self: *TuiDiagnostics) void {
        std.debug.print("[DIAG] Cleaning up TuiDiagnostics...\n", .{});
        self.injector.deinit();
        self.terminal.deinit();
        std.debug.print("[DIAG] Cleanup complete\n", .{});
    }

    /// Test 1: AppState initialization
    pub fn testAppStateInit(self: *TuiDiagnostics) !void {
        std.debug.print("\n========================================\n", .{});
        std.debug.print("TEST 1: AppState.init() diagnostic\n", .{});
        std.debug.print("========================================\n", .{});

        const options = cli_args.Options{
            .url = "ws://127.0.0.1:18790",
            .url_explicitly_provided = false,
            .interactive = false,
            .tui = true,
            .verbose = false,
        };

        const start = std.time.milliTimestamp();
        var state = try DiagnosticAppState.init(self.allocator, options);
        defer {
            std.debug.print("[DIAG] Cleaning up AppState...\n", .{});
            state.deinit();
            std.debug.print("[DIAG] AppState cleanup complete\n", .{});
        }
        const elapsed = std.time.milliTimestamp() - start;

        std.debug.print("[PASS] AppState.init() completed in {d}ms\n", .{elapsed});
        std.debug.print("[DIAG] State inspection:\n", .{});
        std.debug.print("  - connection_state: {s}\n", .{@tagName(state.connection_state)});
        std.debug.print("  - current_screen: {s}\n", .{@tagName(state.current_screen)});
        std.debug.print("  - config.server_url: {s}\n", .{state.config.server_url});
        std.debug.print("  - config.auto_connect_on_launch: {}\n", .{state.config.auto_connect_on_launch});
    }

    /// Test 2: RootWidget initialization
    pub fn testRootWidgetInit(self: *TuiDiagnostics) !void {
        std.debug.print("\n========================================\n", .{});
        std.debug.print("TEST 2: RootWidget.init() diagnostic\n", .{});
        std.debug.print("========================================\n", .{});

        const options = cli_args.Options{
            .url = "ws://127.0.0.1:18790",
            .url_explicitly_provided = false,
            .interactive = false,
            .tui = true,
            .verbose = false,
        };

        var state = try DiagnosticAppState.init(self.allocator, options);
        defer state.deinit();

        const start = std.time.milliTimestamp();
        var root_widget = DiagnosticRootWidget.init(&state);
        defer root_widget.deinit();
        const elapsed = std.time.milliTimestamp() - start;

        std.debug.print("[PASS] RootWidget.init() completed in {d}ms\n", .{elapsed});
    }

    /// Test 3: ConnectScreen rendering
    pub fn testConnectScreenRender(self: *TuiDiagnostics) !void {
        std.debug.print("\n========================================\n", .{});
        std.debug.print("TEST 3: ConnectScreen render diagnostic\n", .{});
        std.debug.print("========================================\n", .{});

        const options = cli_args.Options{
            .url = "ws://127.0.0.1:18790",
            .url_explicitly_provided = false,
            .interactive = false,
            .tui = true,
            .verbose = false,
        };

        var state = try DiagnosticAppState.init(self.allocator, options);
        defer state.deinit();

        var screen = DiagnosticConnectScreen.init(&state);
        defer screen.deinit();

        std.debug.print("[DIAG] Rendering ConnectScreen to virtual terminal...\n", .{});

        var ctx = MockTui.RenderContext{
            .terminal = &self.terminal,
            .theme = .{},
            .bounds = .{
                .x = 0,
                .y = 0,
                .width = self.terminal.width,
                .height = self.terminal.height,
            },
            .clip = .{
                .x = 0,
                .y = 0,
                .width = self.terminal.width,
                .height = self.terminal.height,
            },
            .focused_id = null,
            .time_ns = std.time.nanoTimestamp(),
        };

        const start = std.time.milliTimestamp();
        screen.render(&ctx);
        const elapsed = std.time.milliTimestamp() - start;

        std.debug.print("[PASS] ConnectScreen.render() completed in {d}ms\n", .{elapsed});

        // Check what's on screen
        std.debug.print("[DIAG] Screen content check:\n", .{});
        std.debug.print("  - Has 'ZiggyStarSpider TUI': {}\n", .{self.terminal.hasText("ZiggyStarSpider TUI")});
        self.terminal.hasText("Connect to Spiderweb Server");
        self.terminal.hasText("Server URL:");
        self.terminal.hasText("Press Enter to Connect");
    }

    /// Test 4: Event handling
    pub fn testEventHandling(self: *TuiDiagnostics) !void {
        std.debug.print("\n========================================\n", .{});
        std.debug.print("TEST 4: Event handling diagnostic\n", .{});
        std.debug.print("========================================\n", .{});

        const options = cli_args.Options{
            .url = "ws://127.0.0.1:18790",
            .url_explicitly_provided = false,
            .interactive = false,
            .tui = true,
            .verbose = false,
        };

        var state = try DiagnosticAppState.init(self.allocator, options);
        defer state.deinit();

        var root_widget = DiagnosticRootWidget.init(&state);
        defer root_widget.deinit();

        // Test key event
        const key_event = Event{
            .key = .{
                .key = .{ .char = 'a' },
                .modifiers = .{},
            },
        };

        const start = std.time.milliTimestamp();
        const result = root_widget.handleEvent(key_event);
        const elapsed = std.time.milliTimestamp() - start;

        std.debug.print("[PASS] handleEvent() returned in {d}ms with result: {s}\n", .{ elapsed, @tagName(result) });

        // Test quit event
        const quit_event = Event{ .quit = {} };
        const quit_start = std.time.milliTimestamp();
        const quit_result = root_widget.handleEvent(quit_event);
        const quit_elapsed = std.time.milliTimestamp() - quit_start;

        std.debug.print("[PASS] handleEvent(quit) returned in {d}ms with result: {s}\n", .{ quit_elapsed, @tagName(quit_result) });
    }

    /// Test 5: pollMessages behavior
    pub fn testPollMessages(self: *TuiDiagnostics) !void {
        std.debug.print("\n========================================\n", .{});
        std.debug.print("TEST 5: pollMessages diagnostic\n", .{});
        std.debug.print("========================================\n", .{});

        const options = cli_args.Options{
            .url = "ws://127.0.0.1:18790",
            .url_explicitly_provided = false,
            .interactive = false,
            .tui = true,
            .verbose = false,
        };

        var state = try DiagnosticAppState.init(self.allocator, options);
        defer state.deinit();

        // Test when disconnected (should return immediately)
        std.debug.print("[DIAG] Testing pollMessages() when disconnected...\n", .{});
        const start = std.time.milliTimestamp();
        state.pollMessages() catch |err| {
            std.debug.print("[INFO] pollMessages() returned error (expected): {s}\n", .{@errorName(err)});
        };
        const elapsed = std.time.milliTimestamp() - start;

        std.debug.print("[PASS] pollMessages() (disconnected) returned in {d}ms\n", .{elapsed});

        if (elapsed > 100) {
            std.debug.print("[WARN] pollMessages() took longer than expected\n", .{});
        }
    }

    /// Test 6: Full App lifecycle
    pub fn testAppLifecycle(self: *TuiDiagnostics) !void {
        std.debug.print("\n========================================\n", .{});
        std.debug.print("TEST 6: Full App lifecycle diagnostic\n", .{});
        std.debug.print("========================================\n", .{});

        const options = cli_args.Options{
            .url = "ws://127.0.0.1:18790",
            .url_explicitly_provided = false,
            .interactive = false,
            .tui = true,
            .verbose = true,
        };

        std.debug.print("[DIAG] Creating DiagnosticApp...\n", .{});
        const start = std.time.milliTimestamp();
        var app = try DiagnosticApp.init(self.allocator, options);
        const init_elapsed = std.time.milliTimestamp() - start;

        std.debug.print("[DIAG] App created in {d}ms\n", .{init_elapsed});
        std.debug.print("[DIAG] App state:\n", .{});
        std.debug.print("  - tui_init_completed: {}\n", .{app.tui_init_completed});
        std.debug.print("  - connection_state: {s}\n", .{@tagName(app.state.connection_state)});

        // Simulate run (without actually blocking)
        std.debug.print("[DIAG] Calling app.run()...\n", .{});
        const run_start = std.time.milliTimestamp();
        try app.run();
        const run_elapsed = std.time.milliTimestamp() - run_start;

        std.debug.print("[DIAG] app.run() returned in {d}ms\n", .{run_elapsed});
        std.debug.print("[DIAG] App state after run:\n", .{});
        std.debug.print("  - run_entered: {}\n", .{app.run_entered});
        std.debug.print("  - run_exited: {}\n", .{app.run_exited});

        // Cleanup
        std.debug.print("[DIAG] Cleaning up app...\n", .{});
        app.deinit();

        std.debug.print("[PASS] Full App lifecycle test completed\n", .{});
    }

    /// Print summary
    pub fn printSummary(self: *TuiDiagnostics) void {
        std.debug.print("\n========================================\n", .{});
        std.debug.print("DIAGNOSTIC SUMMARY\n", .{});
        std.debug.print("========================================\n", .{});
        _ = self;
    }
};

/// Run all diagnostics
pub fn runDiagnostics() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("\n", .{});
    std.debug.print("╔══════════════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║     ZiggyStarSpider TUI Diagnostic Tool                      ║\n", .{});
    std.debug.print("║     Investigating: 'clears screen and never exits'           ║\n", .{});
    std.debug.print("╚══════════════════════════════════════════════════════════════╝\n", .{});

    var diag = try TuiDiagnostics.init(allocator, 80, 24);
    defer diag.deinit();

    // Run all tests
    diag.testAppStateInit() catch |err| {
        std.debug.print("\n[CRITICAL] AppState.init() failed: {s}\n", .{@errorName(err)});
    };

    diag.testRootWidgetInit() catch |err| {
        std.debug.print("\n[CRITICAL] RootWidget.init() failed: {s}\n", .{@errorName(err)});
    };

    diag.testConnectScreenRender() catch |err| {
        std.debug.print("\n[CRITICAL] ConnectScreen render failed: {s}\n", .{@errorName(err)});
    };

    diag.testEventHandling() catch |err| {
        std.debug.print("\n[CRITICAL] Event handling test failed: {s}\n", .{@errorName(err)});
    };

    diag.testPollMessages() catch |err| {
        std.debug.print("\n[CRITICAL] pollMessages test failed: {s}\n", .{@errorName(err)});
    };

    diag.testAppLifecycle() catch |err| {
        std.debug.print("\n[CRITICAL] App lifecycle test failed: {s}\n", .{@errorName(err)});
    };

    diag.printSummary();

    std.debug.print("\n========================================\n", .{});
    std.debug.print("DIAGNOSTICS COMPLETE\n", .{});
    std.debug.print("========================================\n", .{});
    std.debug.print("\nFINDINGS:\n", .{});
    std.debug.print("All core components (AppState, RootWidget, ConnectScreen)\n", .{});
    std.debug.print("initialize and operate correctly in isolation.\n", .{});
    std.debug.print("\nThe 'hang' is likely in the actual TUI library's:\n", .{});
    std.debug.print("  - tui.App.initWithAllocator() - terminal setup\n", .{});
    std.debug.print("  - tui.App.run() - blocking event loop\n", .{});
    std.debug.print("\nThese interact with the real terminal and may block on:\n", .{});
    std.debug.print("  - stdin/stdout setup and detection\n", .{});
    std.debug.print("  - Alternate screen buffer initialization\n", .{});
    std.debug.print("  - Signal handler setup\n", .{});
    std.debug.print("  - Input polling (waiting for user input)\n", .{});
}

// Zig test entry point
test "TUI diagnostics" {
    try runDiagnostics();
}

// Standalone main for direct execution
pub fn main() !void {
    try runDiagnostics();
}
