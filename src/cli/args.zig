const std = @import("std");
const logger = @import("ziggy-core").utils.logger;
const build_options = @import("build_options");

// CLI argument parsing for ZiggyStarSpider
// Uses simple iteration like ZSC - no ArrayList complexity for basic parsing

const default_server_url = "ws://127.0.0.1:18790/v1/agents/default/stream";

pub const Command = struct {
    noun: Noun,
    verb: Verb,
    args: []const []const u8,
};

pub const Noun = enum {
    chat,
    project,
    goal,
    task,
    worker,
    connect,
    disconnect,
    status,
    help,
    none,
};

pub const Verb = enum {
    send,
    history,
    list,
    use,
    create,
    info,
    complete,
    logs,
    none,
};

pub const Options = struct {
    url: []const u8 = default_server_url,
    url_explicitly_provided: bool = false,
    project: ?[]const u8 = null,
    interactive: bool = false,
    tui: bool = false,
    verbose: bool = false,
    show_help: bool = false,
    show_version: bool = false,
    command: ?Command = null,

    pub fn deinit(self: *Options, allocator: std.mem.Allocator) void {
        // Free copied URL if it's not the default
        if (self.url.ptr != default_server_url.ptr) {
            allocator.free(self.url);
        }

        // Free project name
        if (self.project) |p| {
            allocator.free(p);
        }

        // Free command args
        if (self.command) |cmd| {
            for (cmd.args) |arg| {
                allocator.free(arg);
            }
            allocator.free(cmd.args);
        }
    }
};

// Embedded help documentation
const help_overview = @embedFile("docs/01-overview.md");
const help_options = @embedFile("docs/02-options.md");
const help_chat = @embedFile("docs/10-chat.md");
const help_project = @embedFile("docs/11-project.md");
const help_goal = @embedFile("docs/12-goal.md");
const help_task = @embedFile("docs/13-task.md");
const help_worker = @embedFile("docs/14-worker.md");
const help_connection = @embedFile("docs/15-connection.md");
pub const help_tui = @embedFile("docs/tui-help.md");

pub fn printHelp() void {
    const stdout = std.fs.File.stdout().deprecatedWriter();
    stdout.print("{s}\n\n{s}\n", .{ help_overview, help_options }) catch {};
}

pub fn printTuiHelp() void {
    const stdout = std.fs.File.stdout().deprecatedWriter();
    stdout.print("{s}\n", .{help_tui}) catch {};
}

pub fn printHelpForNoun(noun: Noun) void {
    const stdout = std.fs.File.stdout().deprecatedWriter();
    const content = switch (noun) {
        .chat => help_chat,
        .project => help_project,
        .goal => help_goal,
        .task => help_task,
        .worker => help_worker,
        .connect, .disconnect, .status => help_connection,
        else => help_overview,
    };
    stdout.print("{s}\n", .{content}) catch {};
}

pub fn printVersion() void {
    const stdout = std.fs.File.stdout().deprecatedWriter();
    stdout.print("ZSS v{s}\n", .{build_options.version}) catch {};
}

fn parseNoun(arg: []const u8) ?Noun {
    if (std.mem.eql(u8, arg, "chat")) return .chat;
    if (std.mem.eql(u8, arg, "project")) return .project;
    if (std.mem.eql(u8, arg, "goal")) return .goal;
    if (std.mem.eql(u8, arg, "task")) return .task;
    if (std.mem.eql(u8, arg, "worker")) return .worker;
    if (std.mem.eql(u8, arg, "connect")) return .connect;
    if (std.mem.eql(u8, arg, "disconnect")) return .disconnect;
    if (std.mem.eql(u8, arg, "status")) return .status;
    if (std.mem.eql(u8, arg, "help")) return .help;
    return null;
}

fn parseVerb(noun: Noun, arg: []const u8) ?Verb {
    switch (noun) {
        .chat => {
            if (std.mem.eql(u8, arg, "send")) return .send;
            if (std.mem.eql(u8, arg, "history")) return .history;
        },
        .project => {
            if (std.mem.eql(u8, arg, "list")) return .list;
            if (std.mem.eql(u8, arg, "use")) return .use;
            if (std.mem.eql(u8, arg, "create")) return .create;
            if (std.mem.eql(u8, arg, "info")) return .info;
        },
        .goal => {
            if (std.mem.eql(u8, arg, "list")) return .list;
            if (std.mem.eql(u8, arg, "create")) return .create;
            if (std.mem.eql(u8, arg, "complete")) return .complete;
        },
        .task => {
            if (std.mem.eql(u8, arg, "list")) return .list;
            if (std.mem.eql(u8, arg, "info")) return .info;
        },
        .worker => {
            if (std.mem.eql(u8, arg, "list")) return .list;
            if (std.mem.eql(u8, arg, "logs")) return .logs;
        },
        else => {},
    }
    return null;
}

pub fn parseArgs(allocator: std.mem.Allocator) !Options {
    var options = Options{};

    const args = try std.process.argsAlloc(allocator);
    // NOTE: We don't free args here - the returned Options may reference slices from it
    // The caller is responsible for the allocator lifetime

    if (args.len <= 1) {
        options.interactive = true;
        std.process.argsFree(allocator, args);
        return options;
    }

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];

        // Global flags
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            options.show_help = true;
            std.process.argsFree(allocator, args);
            return options;
        }
        if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-v")) {
            options.show_version = true;
            std.process.argsFree(allocator, args);
            return options;
        }
        if (std.mem.eql(u8, arg, "--url")) {
            i += 1;
            if (i >= args.len) {
                std.process.argsFree(allocator, args);
                return error.InvalidArguments;
            }
            // Copy the URL string since args will be freed
            options.url = try allocator.dupe(u8, args[i]);
            options.url_explicitly_provided = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--project")) {
            i += 1;
            if (i >= args.len) {
                std.process.argsFree(allocator, args);
                return error.InvalidArguments;
            }
            // Copy the project string
            options.project = try allocator.dupe(u8, args[i]);
            continue;
        }
        if (std.mem.eql(u8, arg, "--interactive") or std.mem.eql(u8, arg, "-i")) {
            options.interactive = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--tui")) {
            options.tui = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--verbose")) {
            options.verbose = true;
            continue;
        }

        // Noun-verb commands
        const noun = parseNoun(arg);
        if (noun) |n| {
            if (options.command != null) {
                logger.err("Multiple commands provided; only one command is supported", .{});
                std.process.argsFree(allocator, args);
                return error.InvalidArguments;
            }

            if (n == .help) {
                options.show_help = true;
                std.process.argsFree(allocator, args);
                return options;
            }

            // Check if next arg is a verb
            if (i + 1 < args.len) {
                const verb = parseVerb(n, args[i + 1]);
                if (verb) |v| {
                    i += 1;

                    // Find where command args end (next flag or end)
                    const arg_start = i + 1;
                    var arg_end = arg_start;
                    while (arg_end < args.len and !std.mem.startsWith(u8, args[arg_end], "--")) {
                        arg_end += 1;
                    }

                    // Copy args since args array will be freed
                    const cmd_args_count = arg_end - arg_start;
                    const cmd_args = if (cmd_args_count > 0) blk: {
                        const copied = try allocator.alloc([]const u8, cmd_args_count);
                        for (0..cmd_args_count) |j| {
                            copied[j] = try allocator.dupe(u8, args[arg_start + j]);
                        }
                        break :blk copied;
                    } else &[_][]const u8{};

                    options.command = .{
                        .noun = n,
                        .verb = v,
                        .args = cmd_args,
                    };

                    // Skip consumed args
                    i = arg_end - 1;
                    continue;
                }
            }

            // Noun without verb
            if (n == .connect or n == .disconnect or n == .status) {
                options.command = .{
                    .noun = n,
                    .verb = .none,
                    .args = &[_][]const u8{},
                };
                continue;
            }

            logger.err("Unknown verb for noun '{s}'", .{arg});
            std.process.argsFree(allocator, args);
            return error.InvalidArguments;
        }

        logger.err("Unknown argument: {s}", .{arg});
        std.process.argsFree(allocator, args);
        return error.InvalidArguments;
    }

    std.process.argsFree(allocator, args);
    return options;
}

pub fn formatCommand(allocator: std.mem.Allocator, cmd: Command) ![]u8 {
    var parts: std.ArrayList([]const u8) = .empty;
    defer parts.deinit(allocator);

    try parts.append(allocator, @tagName(cmd.noun));
    if (cmd.verb != .none) {
        try parts.append(allocator, @tagName(cmd.verb));
    }
    for (cmd.args) |arg| {
        try parts.append(allocator, arg);
    }

    return std.mem.join(allocator, " ", parts.items);
}
