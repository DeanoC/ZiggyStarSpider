// SpiderApp CLI entry point.
// Parses arguments and dispatches to per-noun command modules.

const std = @import("std");
const args = @import("args.zig");
const logger = @import("ziggy-core").utils.logger;
const ctx = @import("client_context.zig");

// ── Command modules ───────────────────────────────────────────────────────────

const cmd_workspace = @import("commands/workspace.zig");
const cmd_node = @import("commands/node.zig");
const cmd_session = @import("commands/session.zig");
const cmd_agent = @import("commands/agent.zig");
const cmd_auth = @import("commands/auth.zig");
const cmd_chat = @import("commands/chat.zig");
const cmd_fs = @import("commands/fs.zig");
const cmd_complete = @import("commands/complete.zig");
const repl = @import("repl.zig");

// ── Interactive REPL ──────────────────────────────────────────────────────────

fn runInteractive(allocator: std.mem.Allocator, options: args.Options) !void {
    try repl.run(allocator, options);
}

// ── Command dispatch ──────────────────────────────────────────────────────────

fn executeCommand(allocator: std.mem.Allocator, options: args.Options, cmd: args.Command) !void {
    const stdout = std.fs.File.stdout().deprecatedWriter();

    switch (cmd.noun) {
        .chat => {
            switch (cmd.verb) {
                .send => try cmd_chat.executeChatSend(allocator, options, cmd),
                .resume_job => try cmd_chat.executeChatResume(allocator, options, cmd),
                .history => {
                    try stdout.print("Chat history not yet implemented\n", .{});
                },
                else => {
                    logger.err("Unknown chat verb", .{});
                    return error.InvalidArguments;
                },
            }
        },
        .fs => {
            switch (cmd.verb) {
                .ls => try cmd_fs.executeFsLs(allocator, options, cmd),
                .read => try cmd_fs.executeFsRead(allocator, options, cmd),
                .write => try cmd_fs.executeFsWrite(allocator, options, cmd),
                .stat => try cmd_fs.executeFsStat(allocator, options, cmd),
                .tree => try cmd_fs.executeFsTree(allocator, options, cmd),
                else => {
                    logger.err("Unknown fs verb", .{});
                    return error.InvalidArguments;
                },
            }
        },
        .agent => {
            switch (cmd.verb) {
                .list => try cmd_agent.executeAgentList(allocator, options, cmd),
                .info => try cmd_agent.executeAgentInfo(allocator, options, cmd),
                else => {
                    logger.err("Unknown agent verb", .{});
                    return error.InvalidArguments;
                },
            }
        },
        .session => {
            switch (cmd.verb) {
                .list => try cmd_session.executeSessionList(allocator, options, cmd),
                .history => try cmd_session.executeSessionHistory(allocator, options, cmd),
                .status => try cmd_session.executeSessionStatus(allocator, options, cmd),
                .attach => try cmd_session.executeSessionAttach(allocator, options, cmd),
                .resume_job => try cmd_session.executeSessionResume(allocator, options, cmd),
                .close => try cmd_session.executeSessionClose(allocator, options, cmd),
                .restore => try cmd_session.executeSessionRestore(allocator, options, cmd),
                else => {
                    logger.err("Unknown session verb", .{});
                    return error.InvalidArguments;
                },
            }
        },
        .node => {
            switch (cmd.verb) {
                .list => try cmd_node.executeNodeList(allocator, options, cmd),
                .info => try cmd_node.executeNodeInfo(allocator, options, cmd),
                .pending => try cmd_node.executeNodePendingList(allocator, options, cmd),
                .approve => try cmd_node.executeNodeApprove(allocator, options, cmd),
                .deny => try cmd_node.executeNodeDeny(allocator, options, cmd),
                .join_request => try cmd_node.executeNodeJoinRequest(allocator, options, cmd),
                .service_get => try cmd_node.executeNodeServiceGet(allocator, options, cmd),
                .service_upsert => try cmd_node.executeNodeServiceUpsert(allocator, options, cmd),
                .service_runtime => try cmd_node.executeNodeServiceRuntime(allocator, options, cmd),
                .watch => try cmd_node.executeNodeServiceWatch(allocator, options, cmd),
                else => {
                    logger.err("Unknown node verb", .{});
                    return error.InvalidArguments;
                },
            }
        },
        .workspace => {
            switch (cmd.verb) {
                .list => try cmd_workspace.executeWorkspaceList(allocator, options, cmd),
                .use => try cmd_workspace.executeWorkspaceUse(allocator, options, cmd),
                .create => try cmd_workspace.executeWorkspaceCreate(allocator, options, cmd),
                .up => try cmd_workspace.executeWorkspaceUp(allocator, options, cmd),
                .doctor => try cmd_workspace.executeWorkspaceDoctor(allocator, options, cmd),
                .info => try cmd_workspace.executeWorkspaceInfo(allocator, options, cmd),
                .status => try cmd_workspace.executeWorkspaceStatus(allocator, options, cmd),
                .template => try cmd_workspace.executeWorkspaceTemplateCommand(allocator, options, cmd),
                .bind => try cmd_workspace.executeWorkspaceBindCommand(allocator, options, cmd),
                .mount => try cmd_workspace.executeWorkspaceMountCommand(allocator, options, cmd),
                .handoff => try cmd_workspace.executeWorkspaceHandoffCommand(allocator, options, cmd),
                else => {
                    logger.err("Unknown workspace verb", .{});
                    return error.InvalidArguments;
                },
            }
        },
        .auth => {
            switch (cmd.verb) {
                .status => try cmd_auth.executeAuthStatus(allocator, options, cmd),
                .rotate => try cmd_auth.executeAuthRotate(allocator, options, cmd),
                else => {
                    logger.err("Unknown auth verb", .{});
                    return error.InvalidArguments;
                },
            }
        },
        .connect => {
            if (ctx.g_connected) {
                try stdout.print("Already connected to {s}\n", .{options.url});
                return;
            }
            const client = try ctx.getOrCreateClient(allocator, options);
            try ctx.ensureUnifiedV2Control(allocator, client);
            try stdout.print("Connected to {s}\n", .{options.url});
        },
        .disconnect => {
            if (!ctx.g_connected) {
                try stdout.print("Not connected\n", .{});
                return;
            }
            ctx.cleanupGlobalClient();
            try stdout.print("Disconnected\n", .{});
        },
        .status => {
            try stdout.print("Connection status:\n", .{});
            try stdout.print("  Server: {s}\n", .{options.url});
            try stdout.print("  Connected: {s}\n", .{if (ctx.g_connected) "Yes" else "No"});
        },
        .help => {
            args.printHelp();
        },
        .complete => {
            try cmd_complete.executeComplete(allocator, options, cmd);
        },
        else => {
            logger.err("Command not yet implemented", .{});
            return error.NotImplemented;
        },
    }
}

// ── Entry point ───────────────────────────────────────────────────────────────

pub fn run(allocator: std.mem.Allocator) !void {
    defer ctx.cleanupGlobalClient();

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

    if (std.mem.eql(u8, args.gitRevision(), "unknown")) {
        logger.info("SpiderApp v{s}", .{args.appVersion()});
    } else {
        logger.info("SpiderApp v{s} ({s})", .{ args.appVersion(), args.gitRevision() });
    }
    logger.info("Server: {s}", .{options.url});
    if (options.workspace) |p| {
        logger.info("Workspace: {s}", .{p});
    }

    // Handle commands or interactive mode
    if (options.command) |cmd| {
        try executeCommand(allocator, options, cmd);
    } else if (options.interactive) {
        try runInteractive(allocator, options);
    } else {
        args.printHelp();
    }
}
