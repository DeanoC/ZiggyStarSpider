// Agent commands: agent list, agent info

const std = @import("std");
const args = @import("../args.zig");
const logger = @import("ziggy-core").utils.logger;
const control_plane = @import("control_plane");
const workspace_types = control_plane.workspace_types;
const ctx = @import("../client_context.zig");
const output = @import("../output.zig");

pub fn executeAgentList(allocator: std.mem.Allocator, options: args.Options, cmd: args.Command) !void {
    _ = cmd;
    const stdout = std.fs.File.stdout().deprecatedWriter();
    const client = try ctx.getOrCreateClient(allocator, options);
    try ctx.ensureUnifiedV2Control(allocator, client);

    var agents = try control_plane.listAgents(allocator, client, &ctx.g_control_request_counter);
    defer workspace_types.deinitAgentList(allocator, &agents);
    if (agents.items.len == 0) {
        try stdout.print("(no agents)\n", .{});
        return;
    }

    if (options.json) {
        try stdout.writeAll("[\n");
        for (agents.items, 0..) |agent, idx| {
            try stdout.print(
                "  {{\"id\":\"{s}\",\"name\":\"{s}\",\"is_default\":{s},\"needs_hatching\":{s}}}",
                .{
                    agent.id,
                    agent.name,
                    if (agent.is_default) "true" else "false",
                    if (agent.needs_hatching) "true" else "false",
                },
            );
            if (idx + 1 < agents.items.len) try stdout.writeByte(',');
            try stdout.writeByte('\n');
        }
        try stdout.writeAll("]\n");
        return;
    }

    const ansi = ctx.stdoutSupportsAnsi();
    var tbl = try output.Table.init(allocator, &.{ "ID", "Name", "Default", "Needs Hatching" });
    defer tbl.deinit();
    for (agents.items) |agent| {
        try tbl.row(&.{
            agent.id,
            agent.name,
            if (agent.is_default) "yes" else "no",
            if (agent.needs_hatching) "yes" else "no",
        });
    }
    try tbl.print(stdout, ansi);
}

pub fn executeAgentInfo(allocator: std.mem.Allocator, options: args.Options, cmd: args.Command) !void {
    if (cmd.args.len == 0) {
        logger.err("agent info requires an agent ID", .{});
        return error.InvalidArguments;
    }

    const stdout = std.fs.File.stdout().deprecatedWriter();
    const client = try ctx.getOrCreateClient(allocator, options);
    try ctx.ensureUnifiedV2Control(allocator, client);

    var agent = try control_plane.getAgent(allocator, client, &ctx.g_control_request_counter, cmd.args[0]);
    defer agent.deinit(allocator);

    try stdout.print("Agent {s}\n", .{agent.id});
    try stdout.print("  Name: {s}\n", .{agent.name});
    try stdout.print("  Description: {s}\n", .{agent.description});
    try stdout.print("  Default: {s}\n", .{if (agent.is_default) "yes" else "no"});
    try stdout.print("  Identity loaded: {s}\n", .{if (agent.identity_loaded) "yes" else "no"});
    try stdout.print("  Needs hatching: {s}\n", .{if (agent.needs_hatching) "yes" else "no"});
    if (agent.capabilities.items.len == 0) {
        try stdout.print("  Capabilities: (none)\n", .{});
    } else {
        try stdout.print("  Capabilities:\n", .{});
        for (agent.capabilities.items) |capability| {
            try stdout.print("    - {s}\n", .{capability});
        }
    }
}
