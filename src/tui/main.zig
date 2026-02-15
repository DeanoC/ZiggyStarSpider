const std = @import("std");
const tui = @import("tui");
const cli_args = @import("../cli/args.zig");

const App = @import("app.zig").App;

pub fn run(allocator: std.mem.Allocator, options: cli_args.Options) !void {
    var app = try App.init(allocator, options);
    defer app.deinit();

    try app.run();
}
