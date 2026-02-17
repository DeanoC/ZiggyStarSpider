const std = @import("std");
const tui = @import("tui");

pub fn main() !void {
    std.log.info("Starting minimal TUI test...", .{});
    
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    std.log.info("Creating tui.App...", .{});
    
    // This is the exact call that hangs
    var app = try tui.App.initWithAllocator(allocator, .{
        .alternate_screen = true,
        .hide_cursor = false,
        .enable_mouse = true,
    });
    
    std.log.info("tui.App created successfully!", .{});
    
    app.deinit();
    
    std.log.info("Test completed successfully!", .{});
}
