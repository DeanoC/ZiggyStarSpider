const std = @import("std");
const tui = @import("tui");

const AppState = @import("../app.zig").AppState;
const ConnectionState = @import("../app.zig").ConnectionState;

pub const ConnectScreen = struct {
    state: *AppState,
    url_input: tui.InputField,
    
    pub fn init(state: *AppState) ConnectScreen {
        const default_url = state.config.server_url;
        
        var url_input = tui.InputField.init(state.allocator);
        url_input.setValue(default_url) catch {};
        url_input.placeholder = "ws://127.0.0.1:18790";
        
        return .{
            .state = state,
            .url_input = url_input,
        };
    }

    pub fn deinit(self: *ConnectScreen) void {
        self.url_input.deinit();
    }

    pub fn render(self: *ConnectScreen, ctx: *tui.RenderContext) void {
        const width = ctx.bounds.width;
        const height = ctx.bounds.height;

        // Clear background
        ctx.screen.clear();

        // Title
        const title = "ZiggyStarSpider TUI";
        const title_style = tui.Style{
            .fg = tui.Color.cyan,
            .attrs = .{ .bold = true },
        };
        
        const title_x = @divTrunc(width - @as(u16, @intCast(title.len)), 2);
        ctx.screen.moveCursor(title_x, 2);
        ctx.screen.setStyle(title_style);
        ctx.screen.putString(title);

        // Subtitle
        const subtitle = "Connect to Spiderweb Server";
        const subtitle_style = tui.Style{
            .fg = tui.Color.white,
        };
        
        const subtitle_x = @divTrunc(width - @as(u16, @intCast(subtitle.len)), 2);
        ctx.screen.moveCursor(subtitle_x, 4);
        ctx.screen.setStyle(subtitle_style);
        ctx.screen.putString(subtitle);

        // URL label
        const label = "Server URL:";
        const label_x = @divTrunc(width - 52, 2);
        ctx.screen.moveCursor(label_x, 7);
        ctx.screen.setStyle(tui.Style{ .fg = tui.Color.white });
        ctx.screen.putString(label);

        // URL input field
        const input_x = @divTrunc(width - 50, 2);
        const input_y = 8;
        
        var input_ctx = tui.RenderContext{
            .screen = ctx.screen,
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
        const button_style = tui.Style{
            .fg = tui.Color.green,
        };
        
        const button_x = @divTrunc(width - @as(u16, @intCast(button_text.len)), 2);
        ctx.screen.moveCursor(button_x, 10);
        ctx.screen.setStyle(button_style);
        ctx.screen.putString(button_text);

        // Status line
        const status_text = switch (self.state.connection_state) {
            .disconnected => "Enter server URL to connect",
            .connecting => "Connecting...",
            .connected => "Connected to Spiderweb",
            .err => if (self.state.connection_error) |err| err else "Connection error",
        };

        const status_style = switch (self.state.connection_state) {
            .disconnected => tui.Style{ .fg = tui.Color.white },
            .connecting => tui.Style{ .fg = tui.Color.yellow },
            .connected => tui.Style{ .fg = tui.Color.green },
            .err => tui.Style{ .fg = tui.Color.red },
        };
        
        const status_x = @divTrunc(width - @as(u16, @intCast(status_text.len)), 2);
        ctx.screen.moveCursor(status_x, 13);
        ctx.screen.setStyle(status_style);
        ctx.screen.putString(status_text);

        // Help text
        const help_text = "Press Ctrl+C to quit";
        const help_style = tui.Style{
            .fg = tui.Color.gray,
        };
        
        const help_x = @divTrunc(width - @as(u16, @intCast(help_text.len)), 2);
        ctx.screen.moveCursor(help_x, height - 2);
        ctx.screen.setStyle(help_style);
        ctx.screen.putString(help_text);
    }

    pub fn handleEvent(self: *ConnectScreen, event: tui.Event) tui.EventResult {
        switch (event) {
            .key => |key_event| {
                // Check for Enter to connect
                switch (key_event.key) {
                    .enter => {
                        const url = self.url_input.getValue();
                        if (url.len > 0) {
                            self.state.connect(url) catch |err| {
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
                        // Pass to input field
                        return self.url_input.handleEvent(event);
                    },
                }
            },
            else => {},
        }
        
        return .ignored;
    }
};
