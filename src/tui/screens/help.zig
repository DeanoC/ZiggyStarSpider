const std = @import("std");
const tui = @import("tui");

const AppState = @import("../app.zig").AppState;

pub const HelpScreen = struct {
    state: *AppState,
    scroll_offset: usize = 0,
    help_text: []const u8,

    pub fn init(state: *AppState) HelpScreen {
        // We use the same help text as the CLI's TUI help
        const cli_args = @import("cli_args");
        return .{
            .state = state,
            .help_text = cli_args.help_tui,
        };
    }

    pub fn deinit(self: *HelpScreen) void {
        _ = self;
    }

    pub fn render(self: *HelpScreen, ctx: *tui.RenderContext) void {
        const width = ctx.bounds.width;
        const height = ctx.bounds.height;

        // Clear background
        ctx.screen.clear();

        // Header
        const header = "ZiggyStarSpider - Help";
        const header_style = tui.Style{
            .fg = tui.Color.cyan,
            .attrs = .{ .bold = true },
        };

        ctx.screen.moveCursor(2, 0);
        ctx.screen.setStyle(header_style);
        ctx.screen.putString(header);

        // Separator line
        ctx.screen.moveCursor(0, 1);
        ctx.screen.setStyle(tui.Style{ .fg = tui.Color.gray });
        for (0..width) |_| {
            ctx.screen.putString("─");
        }

        // Help text area
        const content_height = if (height > 4) height - 4 else 0;
        const content_y = 2;

        if (content_height > 0) {
            var it = std.mem.splitSequence(u8, self.help_text, "\n");
            var line_num: usize = 0;
            var visible_line: u16 = 0;

            while (it.next()) |line| : (line_num += 1) {
                if (line_num < self.scroll_offset) continue;
                if (visible_line >= content_height) break;

                const row = content_y + visible_line;
                ctx.screen.moveCursor(2, row);
                
                // Simple markdown-ish highlighting
                if (std.mem.startsWith(u8, line, "#")) {
                    ctx.screen.setStyle(tui.Style{ .fg = tui.Color.yellow, .attrs = .{ .bold = true } });
                } else if (std.mem.startsWith(u8, line, "##")) {
                    ctx.screen.setStyle(tui.Style{ .fg = tui.Color.yellow });
                } else if (std.mem.startsWith(u8, line, "- **")) {
                    ctx.screen.setStyle(tui.Style{ .fg = tui.Color.white });
                } else {
                    ctx.screen.setStyle(tui.Style{ .fg = tui.Color.gray });
                }
                
                // Truncate line if it's too long
                const display_line = if (line.len > width - 4) line[0..width-4] else line;
                ctx.screen.putString(display_line);
                visible_line += 1;
            }
        }

        // Footer separator
        const footer_y = if (height > 2) height - 2 else 0;
        if (footer_y > 1) {
            ctx.screen.moveCursor(0, footer_y - 1);
            ctx.screen.setStyle(tui.Style{ .fg = tui.Color.gray });
            for (0..width) |_| {
                ctx.screen.putString("─");
            }
        }

        // Footer help text
        const footer_text = "Press Esc to return";
        const footer_style = tui.Style{
            .fg = tui.Color.white,
        };

        if (height > 1) {
            ctx.screen.moveCursor(2, height - 1);
            ctx.screen.setStyle(footer_style);
            ctx.screen.putString(footer_text);
        }
    }

    pub fn handleEvent(self: *HelpScreen, event: tui.Event) tui.EventResult {
        switch (event) {
            .key => |key_event| {
                switch (key_event.key) {
                    .escape => {
                        // Return to previous screen
                        // For now we just go to chat if we were connected, else connect
                        if (self.state.connection_state == .connected) {
                            self.state.current_screen = .chat;
                        } else {
                            self.state.current_screen = .connect;
                        }
                        return .consumed;
                    },
                    .up => {
                        if (self.scroll_offset > 0) self.scroll_offset -= 1;
                        return .consumed;
                    },
                    .down => {
                        self.scroll_offset += 1;
                        return .consumed;
                    },
                    else => {},
                }
            },
            else => {},
        }

        return .ignored;
    }
};
