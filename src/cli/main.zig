const std = @import("std");
const args = @import("args.zig");
const logger = @import("ziggy-core").utils.logger;
const profiler = @import("ziggy-core").utils.profiler;

// Main CLI entry point for ZiggyStarSpider

pub fn run(allocator: std.mem.Allocator) !void {
    // Parse arguments
    var options = args.parseArgs(allocator) catch |err| {
        if (err == error.InvalidArguments) {
            std.log.err("Invalid arguments. Use --help for usage.", .{});
            std.process.exit(1);
        }
        return err;
    };
    defer options.deinit(allocator);
    
    // Handle help/version
    if (options.show_help) {
        args.printHelp();
        return;
    }
    if (options.show_version) {
        args.printVersion();
        return;
    }
    
    // Set log level based on verbose flag
    if (options.verbose) {
        logger.setLevel(.debug);
    }
    
    logger.info("ZiggyStarSpider v0.1.0", .{});
    logger.info("Server: {s}", .{options.url});
    if (options.project) |p| {
        logger.info("Project: {s}", .{p});
    }
    
    // Handle commands or interactive mode
    if (options.command) |cmd| {
        // Execute single command
        try executeCommand(allocator, options, cmd);
    } else if (options.interactive) {
        // Enter interactive REPL
        try runInteractive(allocator, options);
    } else {
        // No command and not interactive - show help
        args.printHelp();
    }
}

fn executeCommand(allocator: std.mem.Allocator, options: args.Options, cmd: args.Command) !void {
    
    const stdout = std.fs.File.stdout().deprecatedWriter();
    
    // TODO: Implement actual command execution
    // For now, just print what would be executed
    
    switch (cmd.noun) {
        .chat => {
            switch (cmd.verb) {
                .send => {
                    if (cmd.args.len == 0) {
                        logger.err("chat send requires a message", .{});
                        return error.InvalidArguments;
                    }
                    const message = try std.mem.join(allocator, " ", cmd.args);
                    defer allocator.free(message);
                    try stdout.print("Would send: \"{s}\"\n", .{message});
                },
                .history => {
                    try stdout.print("Would show chat history\n", .{});
                },
                else => {
                    logger.err("Unknown chat verb", .{});
                    return error.InvalidArguments;
                },
            }
        },
        .project => {
            switch (cmd.verb) {
                .list => {
                    try stdout.print("Would list projects\n", .{});
                },
                .use => {
                    if (cmd.args.len == 0) {
                        logger.err("project use requires a project name", .{});
                        return error.InvalidArguments;
                    }
                    try stdout.print("Would switch to project: {s}\n", .{cmd.args[0]});
                },
                .create => {
                    if (cmd.args.len == 0) {
                        logger.err("project create requires a name", .{});
                        return error.InvalidArguments;
                    }
                    try stdout.print("Would create project: {s}\n", .{cmd.args[0]});
                },
                .info => {
                    try stdout.print("Would show project info\n", .{});
                },
                else => {
                    logger.err("Unknown project verb", .{});
                    return error.InvalidArguments;
                },
            }
        },
        .goal => {
            switch (cmd.verb) {
                .list => {
                    try stdout.print("Would list goals\n", .{});
                },
                .create => {
                    if (cmd.args.len == 0) {
                        logger.err("goal create requires a description", .{});
                        return error.InvalidArguments;
                    }
                    const desc = try std.mem.join(allocator, " ", cmd.args);
                    defer allocator.free(desc);
                    try stdout.print("Would create goal: \"{s}\"\n", .{desc});
                },
                .complete => {
                    if (cmd.args.len == 0) {
                        logger.err("goal complete requires a goal ID", .{});
                        return error.InvalidArguments;
                    }
                    try stdout.print("Would complete goal: {s}\n", .{cmd.args[0]});
                },
                else => {
                    logger.err("Unknown goal verb", .{});
                    return error.InvalidArguments;
                },
            }
        },
        .task => {
            switch (cmd.verb) {
                .list => {
                    try stdout.print("Would list tasks\n", .{});
                },
                .info => {
                    if (cmd.args.len == 0) {
                        logger.err("task info requires a task ID", .{});
                        return error.InvalidArguments;
                    }
                    try stdout.print("Would show task info: {s}\n", .{cmd.args[0]});
                },
                else => {
                    logger.err("Unknown task verb", .{});
                    return error.InvalidArguments;
                },
            }
        },
        .worker => {
            switch (cmd.verb) {
                .list => {
                    try stdout.print("Would list workers\n", .{});
                },
                .logs => {
                    if (cmd.args.len == 0) {
                        logger.err("worker logs requires a worker ID", .{});
                        return error.InvalidArguments;
                    }
                    try stdout.print("Would show logs for worker: {s}\n", .{cmd.args[0]});
                },
                else => {
                    logger.err("Unknown worker verb", .{});
                    return error.InvalidArguments;
                },
            }
        },
        .connect => {
            try stdout.print("Would connect to {s}\n", .{options.url});
        },
        .disconnect => {
            try stdout.print("Would disconnect\n", .{});
        },
        .status => {
            try stdout.print("Connection status:\n", .{});
            try stdout.print("  Server: {s}\n", .{options.url});
            try stdout.print("  Connected: No (not implemented)\n", .{});
        },
        .help => {
            args.printHelp();
        },
        else => {
            logger.err("Command not yet implemented", .{});
            return error.NotImplemented;
        },
    }
}

fn runInteractive(allocator: std.mem.Allocator, options: args.Options) !void {
    _ = allocator;
    _ = options;
    
    const stdout = std.fs.File.stdout().deprecatedWriter();
    // const stdin = std.io.getStdIn().reader();
    
    try stdout.print("\nZiggyStarSpider Interactive Mode\n", .{});
    try stdout.print("Type 'help' for commands, 'quit' to exit.\n\n", .{});
    
    // TODO: Implement actual interactive REPL with connection
    try stdout.print("Interactive mode not yet implemented.\n", .{});
    try stdout.print("Use command mode for now: ziggystarspider chat send \"hello\"\n", .{});
}
