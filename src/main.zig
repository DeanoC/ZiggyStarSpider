const std = @import("std");
const cli = @import("src/cli/main.zig");

// ZiggyStarSpider - Native client for ZiggySpiderweb

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    std.log.info("ZiggyStarSpider v0.1.0", .{});
    
    // TODO: Parse command line args
    // TODO: Initialize config
    // TODO: Connect to Spiderweb
    // TODO: Run CLI or TUI
    
    try cli.run(allocator, .{});
}
