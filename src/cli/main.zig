const std = @import("std");
const args = @import("args.zig");
const logger = @import("ziggy-core").utils.logger;
const WebSocketClient = @import("../client/websocket.zig").WebSocketClient;

// Main CLI entry point for ZiggyStarSpider

var g_client: ?WebSocketClient = null;
var g_connected: bool = false;

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
    
    // Route to TUI mode if requested
    if (options.tui) {
        try @import("../tui/main.zig").run(allocator, options);
        return;
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
    
    // Cleanup global client if exists
    if (g_client) |*client| {
        client.deinit();
        g_client = null;
        g_connected = false;
    }
}

fn getOrCreateClient(allocator: std.mem.Allocator, url: []const u8) !*WebSocketClient {
    if (g_client == null) {
        g_client = WebSocketClient.init(allocator, url, "");
        try g_client.?.connect();
        g_connected = true;
    }
    return &g_client.?;
}

fn executeCommand(allocator: std.mem.Allocator, options: args.Options, cmd: args.Command) !void {
    const stdout = std.fs.File.stdout().deprecatedWriter();
    
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
                    
                    // Connect and send
                    const client = try getOrCreateClient(allocator, options.url);
                    
                    var payload = std.ArrayListUnmanaged(u8).empty;
                    defer payload.deinit(allocator);
                    
                    try payload.appendSlice(allocator, "{\"type\":\"chat.send\",");
                    if (client.session_key) |key| {
                        try payload.appendSlice(allocator, "\"sessionKey\":\"");
                        try payload.appendSlice(allocator, key);
                        try payload.appendSlice(allocator, "\",");
                    }
                    try payload.appendSlice(allocator, "\"content\":\"");
                    try payload.appendSlice(allocator, message);
                    try payload.appendSlice(allocator, "\"}");
                    
                    try client.send(payload.items);
                    try stdout.print("Sent: \"{s}\"\n", .{message});
                    
                    // Wait for response(s)
                    const start_time = std.time.milliTimestamp();
                    var got_content = false;
                    while (std.time.milliTimestamp() - start_time < 15_000) {
                        if (try client.readTimeout(5_000)) |response| {
                            defer allocator.free(response);
                            
                            // Try to parse message
                            const parsed = std.json.parseFromSlice(std.json.Value, allocator, response, .{}) catch null;
                            if (parsed) |p| {
                                defer p.deinit();
                                if (p.value == .object) {
                                    const msg_obj = p.value.object;
                                    
                                    // Handle sessionKey
                                    if (msg_obj.get("sessionKey")) |sk| {
                                        if (sk == .string) {
                                            if (client.session_key) |old| allocator.free(old);
                                            client.session_key = try allocator.dupe(u8, sk.string);
                                        }
                                    }

                                    // Handle content
                                    const msg_type = msg_obj.get("type");
                                    if (msg_type) |mt| {
                                        if (mt == .string) {
                                            if (std.mem.eql(u8, mt.string, "chat.receive") or std.mem.eql(u8, mt.string, "session.receive")) {
                                                if (msg_obj.get("content")) |content| {
                                                    if (content == .string) {
                                                        try stdout.print("AI: {s}\n", .{content.string});
                                                        got_content = true;
                                                        break;
                                                    }
                                                }
                                            } else if (std.mem.eql(u8, mt.string, "error")) {
                                                if (msg_obj.get("message")) |msg| {
                                                    if (msg == .string) {
                                                        try stdout.print("Error: {s}\n", .{msg.string});
                                                    }
                                                }
                                                break;
                                            } else if (std.mem.eql(u8, mt.string, "session.ack")) {
                                                // Already handled sessionKey above, just log it if verbose
                                                logger.debug("Received session.ack", .{});
                                            } else {
                                                logger.debug("Received other message type: {s}", .{mt.string});
                                            }
                                        }
                                    }
                                }
                            } else {
                                try stdout.print("Raw Response: {s}\n", .{response});
                            }
                        } else {
                            // Timeout on single read
                            if (got_content) break;
                        }
                    }
                    if (!got_content) {
                        try stdout.print("(Timed out waiting for AI response)\n", .{});
                    }
                },
                .history => {
                    try stdout.print("Chat history not yet implemented\n", .{});
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
                    try stdout.print("Project list not yet implemented\n", .{});
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
                    try stdout.print("Project info not yet implemented\n", .{});
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
                    try stdout.print("Goal list not yet implemented\n", .{});
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
                    try stdout.print("Task list not yet implemented\n", .{});
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
                    try stdout.print("Worker list not yet implemented\n", .{});
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
            if (g_connected) {
                try stdout.print("Already connected to {s}\n", .{options.url});
                return;
            }
            
            const client = try getOrCreateClient(allocator, options.url);
            _ = client;
            try stdout.print("Connected to {s}\n", .{options.url});
        },
        .disconnect => {
            if (!g_connected) {
                try stdout.print("Not connected\n", .{});
                return;
            }
            
            if (g_client) |*client| {
                client.disconnect();
                client.deinit();
            }
            g_client = null;
            g_connected = false;
            try stdout.print("Disconnected\n", .{});
        },
        .status => {
            try stdout.print("Connection status:\n", .{});
            try stdout.print("  Server: {s}\n", .{options.url});
            try stdout.print("  Connected: {s}\n", .{if (g_connected) "Yes" else "No"});
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
    
    try stdout.print("\nZiggyStarSpider Interactive Mode\n", .{});
    try stdout.print("Type 'help' for commands, 'quit' to exit.\n\n", .{});
    
    // TODO: Implement actual interactive REPL with connection
    try stdout.print("Interactive mode not yet implemented.\n", .{});
    try stdout.print("Use command mode for now: ziggystarspider chat send \"hello\"\n", .{});
}
