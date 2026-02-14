const std = @import("std");
const cli = @import("src/cli/main.zig");
const ziggy_core = @import("ziggy-core");
const logger = ziggy_core.utils.logger;
const profiler = ziggy_core.utils.profiler;

// ZiggyStarSpider - Native client for ZiggySpiderweb

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Initialize logging
    logger.initAsync(allocator) catch |err| {
        std.log.warn("Failed to initialize async logging: {s}", .{@errorName(err)});
    };
    defer logger.deinit();

    // Initialize profiler
    profiler.init(allocator);
    defer profiler.deinit();

    logger.info("ZiggyStarSpider v0.1.0 starting...", .{});

    // TODO: Parse command line args
    // TODO: Initialize config
    // TODO: Connect to Spiderweb
    // TODO: Run CLI or TUI

    try cli.run(allocator, .{});
}
