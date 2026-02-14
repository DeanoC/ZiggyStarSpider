const std = @import("std");
const cli = @import("cli/main.zig");
const ziggy_core = @import("ziggy-core");
const logger = ziggy_core.utils.logger;

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

    // Run CLI
    try cli.run(allocator);
}
