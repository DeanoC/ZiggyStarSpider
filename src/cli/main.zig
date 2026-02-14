const std = @import("std");
const App = @import("../main.zig");

// CLI entry point for ZiggyStarSpider

pub const CliOptions = struct {
    server_url: ?[]const u8 = null,
    auth_token: ?[]const u8 = null,
    interactive: bool = false,
    project: ?[]const u8 = null,
    
    // Commands
    command: ?[]const u8 = null,
};

pub fn run(allocator: std.mem.Allocator, options: CliOptions) !void {
    _ = allocator;
    _ = options;
    
    std.log.info("ZiggyStarSpider CLI starting...", .{});
    
    // TODO: Implement CLI
    // 1. Parse arguments
    // 2. Connect to Spiderweb
    // 3. Run command or interactive mode
    
    std.log.info("CLI not yet implemented - see ARCHITECTURE.md for design", .{});
}
