const std = @import("std");
const tui = @import("tui");

const AppState = @import("../app.zig").AppState;

pub const ChatScreen = struct {
    state: *AppState,
    message_input: tui.InputField,
    scroll_offset: usize = 0,
    
    pub fn init(state: *AppState) ChatScreen {
        var message_input = tui.InputField.init(state.allocator);
        message_input.placeholder = "Type a message...";
        
        return .{
            .state = state,
            .message_input = message_input,
        };
    }

    pub fn deinit(self: *ChatScreen) void {
        self.message_input.deinit();
    }

    pub fn render(self: *ChatScreen, ctx: *tui.RenderContext) void {
        const width = ctx.bounds.width;
        const height = ctx.bounds.height;

        // Clear background
        ctx.screen.clear();

        // Header
        const header = "ZiggyStarSpider - Chat";
        const header_style = tui.Style{
            .fg = tui.Color.cyan,
            .attrs = .{ .bold = true },
        };
        
        ctx.screen.moveCursor(2, 0);
        ctx.screen.setStyle(header_style);
        ctx.screen.putString(header);

        // Status
        const status_text = if (self.state.connection_state == .connected) "● Connected" else "● Disconnected";
        const status_style = if (self.state.connection_state == .connected) 
            tui.Style{ .fg = tui.Color.green } 
        else 
            tui.Style{ .fg = tui.Color.red };
        
        ctx.screen.moveCursor(width - @as(u16, @intCast(status_text.len)) - 2, 0);
        ctx.screen.setStyle(status_style);
        ctx.screen.putString(status_text);

        // Separator line
        ctx.screen.moveCursor(0, 1);
        ctx.screen.setStyle(tui.Style{ .fg = tui.Color.gray });
        for (0..width) |_| {
            ctx.screen.putString("─");
        }

        // Message area
        const message_area_height = height - 4;
        const message_area_y = 2;
        
        // Draw message border
        self.renderMessageArea(ctx, width, message_area_height, message_area_y);

        // Input area separator
        const input_y = height - 2;
        ctx.screen.moveCursor(0, input_y - 1);
        ctx.screen.setStyle(tui.Style{ .fg = tui.Color.gray });
        for (0..width) |_| {
            ctx.screen.putString("─");
        }

        // Input label
        ctx.screen.moveCursor(2, input_y);
        ctx.screen.setStyle(tui.Style{ .fg = tui.Color.white });
        ctx.screen.putString("> ");

        // Input field
        var input_ctx = tui.RenderContext{
            .screen = ctx.screen,
            .theme = ctx.theme,
            .bounds = .{
                .x = 4,
                .y = input_y,
                .width = width - 6,
                .height = 1,
            },
            .clip = .{
                .x = 4,
                .y = input_y,
                .width = width - 6,
                .height = 1,
            },
            .focused_id = null,
            .time_ns = ctx.time_ns,
        };
        
        self.message_input.render(&input_ctx);

        // Help text
        const help_text = "Enter: Send | Ctrl+D: Disconnect | Ctrl+C: Quit";
        const help_style = tui.Style{
            .fg = tui.Color.gray,
        };
        
        ctx.screen.moveCursor(2, height - 1);
        ctx.screen.setStyle(help_style);
        ctx.screen.putString(help_text);
    }

    fn renderMessageArea(self: *ChatScreen, ctx: *tui.RenderContext, width: u16, height: u16, y_offset: u16) void {
        const messages = self.state.messages.items;
        
        // Calculate visible messages
        const visible_count = @min(messages.len, height);
        const start_idx = if (messages.len > height) messages.len - height else 0;
        
        for (0..visible_count) |i| {
            const msg_idx = start_idx + i;
            const msg = messages[msg_idx];
            const row = y_offset + @as(u16, @intCast(i));
            
            // Clear line
            ctx.screen.moveCursor(0, row);
            ctx.screen.setStyle(tui.Style{});
            for (0..width) |_| {
                ctx.screen.putString(" ");
            }
            
            // Render sender
            const sender_style = if (msg.is_user) 
                tui.Style{ .fg = tui.Color.green, .attrs = .{ .bold = true } }
            else 
                tui.Style{ .fg = tui.Color.cyan, .attrs = .{ .bold = true } };
            
            ctx.screen.moveCursor(2, row);
            ctx.screen.setStyle(sender_style);
            ctx.screen.putString(msg.sender);
            ctx.screen.putString(": ");
            
            // Render content (truncated if needed)
            const content_x = 2 + @as(u16, @intCast(msg.sender.len)) + 2;
            const max_content_width = width - content_x - 2;
            
            ctx.screen.setStyle(tui.Style{ .fg = tui.Color.white });
            
            if (msg.content.len <= max_content_width) {
                ctx.screen.putString(msg.content);
            } else {
                ctx.screen.putString(msg.content[0..max_content_width]);
                ctx.screen.putString("...");
            }
        }
        
        // Fill remaining lines
        for (visible_count..height) |i| {
            const row = y_offset + @as(u16, @intCast(i));
            ctx.screen.moveCursor(0, row);
            ctx.screen.setStyle(tui.Style{});
            for (0..width) |_| {
                ctx.screen.putString(" ");
            }
        }
    }

    pub fn handleEvent(self: *ChatScreen, event: tui.Event) tui.EventResult {
        // Poll for new messages
        self.state.pollMessages() catch {};

        switch (event) {
            .key => |key_event| {
                // Check for Ctrl+D to disconnect
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
                
                // Check for Enter to send message
                switch (key_event.key) {
                    .enter => {
                        const content = self.message_input.getValue();
                        if (content.len > 0) {
                            self.state.sendMessage(content) catch {};
                            self.message_input.clear();
                        }
                        return .consumed;
                    },
                    else => {
                        // Pass to input field
                        return self.message_input.handleEvent(event);
                    },
                }
            },
            else => {},
        }
        
        return .ignored;
    }
};
