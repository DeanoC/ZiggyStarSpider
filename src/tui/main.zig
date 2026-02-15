const std = @import("std");
const tui = @import("tui");
const cli_args = @import("cli_args");

const App = @import("app.zig").App;

// Entry point when compiled as standalone executable
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Parse CLI args
    var options = cli_args.parseArgs(allocator) catch |err| {
        if (err == error.InvalidArguments) {
            std.log.err("Invalid arguments. Use --help for usage.", .{});
            std.process.exit(1);
        }
        return err;
    };
    defer options.deinit(allocator);

    var app = try App.init(allocator, options);
    defer app.deinit();

    try app.run();
}

// Entry point when called from CLI main
pub fn run(allocator: std.mem.Allocator, options: cli_args.Options) !void {
    var app = try App.init(allocator, options);
    defer app.deinit();

    try app.run();
}
