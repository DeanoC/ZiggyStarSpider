const std = @import("std");
const logger = @import("ziggy-core").utils.logger;
const build_options = @import("build_options");

// CLI argument parsing for ZiggyStarSpider
// Uses simple iteration like ZSC - no ArrayList complexity for basic parsing

const default_server_url = "ws://127.0.0.1:18790";
const app_version = build_options.app_version;
const git_revision = build_options.git_revision;

pub const Command = struct {
    noun: Noun,
    verb: Verb,
    args: []const []const u8,
};

pub const Noun = enum {
    chat,
    fs,
    agent,
    session,
    project,
    node,
    pairing,
    workspace,
    auth,
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
    read,
    write,
    stat,
    tree,
    ls,
    status,
    rotate,
    history,
    resume_job,
    list,
    pending,
    attach,
    close,
    approve,
    deny,
    join_request,
    service_get,
    service_upsert,
    use,
    create,
    up,
    doctor,
    info,
    refresh,
    complete,
    logs,
    none,
};

pub const Options = struct {
    pub const Role = enum {
        admin,
        user,
    };

    url: []const u8 = default_server_url,
    url_explicitly_provided: bool = false,
    project: ?[]const u8 = null,
    project_token: ?[]const u8 = null,
    operator_token: ?[]const u8 = null,
    role: ?Role = null,
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
        if (self.project_token) |token| {
            allocator.free(token);
        }
        if (self.operator_token) |token| {
            allocator.free(token);
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
const help_node = @embedFile("docs/16-node.md");
const help_workspace = @embedFile("docs/17-workspace.md");
const help_auth = @embedFile("docs/18-auth.md");
const help_pairing = @embedFile("docs/19-pairing.md");
const help_agent = @embedFile("docs/20-agent.md");
const help_session = @embedFile("docs/21-session.md");

pub fn printHelp() void {
    const stdout = std.fs.File.stdout().deprecatedWriter();
    stdout.print("{s}\n\n{s}\n", .{ help_overview, help_options }) catch {};
}

pub fn printHelpForNoun(noun: Noun) void {
    const stdout = std.fs.File.stdout().deprecatedWriter();
    const content = switch (noun) {
        .chat => help_chat,
        .agent => help_agent,
        .session => help_session,
        .project => help_project,
        .node => help_node,
        .pairing => help_pairing,
        .workspace => help_workspace,
        .auth => help_auth,
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
    if (std.mem.eql(u8, git_revision, "unknown")) {
        stdout.print("ZiggyStarSpider v{s}\n", .{app_version}) catch {};
    } else {
        stdout.print("ZiggyStarSpider v{s} ({s})\n", .{ app_version, git_revision }) catch {};
    }
}

pub fn appVersion() []const u8 {
    return app_version;
}

pub fn gitRevision() []const u8 {
    return git_revision;
}

fn parseNoun(arg: []const u8) ?Noun {
    if (std.mem.eql(u8, arg, "chat")) return .chat;
    if (std.mem.eql(u8, arg, "fs")) return .fs;
    if (std.mem.eql(u8, arg, "agent")) return .agent;
    if (std.mem.eql(u8, arg, "session")) return .session;
    if (std.mem.eql(u8, arg, "project")) return .project;
    if (std.mem.eql(u8, arg, "node")) return .node;
    if (std.mem.eql(u8, arg, "pairing")) return .pairing;
    if (std.mem.eql(u8, arg, "workspace")) return .workspace;
    if (std.mem.eql(u8, arg, "auth")) return .auth;
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
            if (std.mem.eql(u8, arg, "resume")) return .resume_job;
        },
        .fs => {
            if (std.mem.eql(u8, arg, "ls")) return .ls;
            if (std.mem.eql(u8, arg, "read")) return .read;
            if (std.mem.eql(u8, arg, "write")) return .write;
            if (std.mem.eql(u8, arg, "stat")) return .stat;
            if (std.mem.eql(u8, arg, "tree")) return .tree;
        },
        .project => {
            if (std.mem.eql(u8, arg, "list")) return .list;
            if (std.mem.eql(u8, arg, "use")) return .use;
            if (std.mem.eql(u8, arg, "create")) return .create;
            if (std.mem.eql(u8, arg, "up")) return .up;
            if (std.mem.eql(u8, arg, "doctor")) return .doctor;
            if (std.mem.eql(u8, arg, "info")) return .info;
        },
        .agent => {
            if (std.mem.eql(u8, arg, "list")) return .list;
            if (std.mem.eql(u8, arg, "info")) return .info;
            if (std.mem.eql(u8, arg, "get")) return .info;
        },
        .session => {
            if (std.mem.eql(u8, arg, "list")) return .list;
            if (std.mem.eql(u8, arg, "status")) return .status;
            if (std.mem.eql(u8, arg, "attach")) return .attach;
            if (std.mem.eql(u8, arg, "resume")) return .resume_job;
            if (std.mem.eql(u8, arg, "close")) return .close;
            if (std.mem.eql(u8, arg, "history")) return .list;
        },
        .node => {
            if (std.mem.eql(u8, arg, "list")) return .list;
            if (std.mem.eql(u8, arg, "info")) return .info;
            if (std.mem.eql(u8, arg, "pending")) return .pending;
            if (std.mem.eql(u8, arg, "approve")) return .approve;
            if (std.mem.eql(u8, arg, "deny")) return .deny;
            if (std.mem.eql(u8, arg, "join-request")) return .join_request;
            if (std.mem.eql(u8, arg, "service-get")) return .service_get;
            if (std.mem.eql(u8, arg, "service-upsert")) return .service_upsert;
        },
        .pairing => {
            if (std.mem.eql(u8, arg, "pending")) return .pending;
            if (std.mem.eql(u8, arg, "approve")) return .approve;
            if (std.mem.eql(u8, arg, "deny")) return .deny;
            if (std.mem.eql(u8, arg, "list")) return .list;
            if (std.mem.eql(u8, arg, "create")) return .create;
            if (std.mem.eql(u8, arg, "refresh")) return .refresh;
        },
        .workspace => {
            if (std.mem.eql(u8, arg, "status")) return .status;
        },
        .auth => {
            if (std.mem.eql(u8, arg, "status")) return .status;
            if (std.mem.eql(u8, arg, "rotate")) return .rotate;
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

fn parseRole(arg: []const u8) ?Options.Role {
    if (std.mem.eql(u8, arg, "admin")) return .admin;
    if (std.mem.eql(u8, arg, "user")) return .user;
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

            if (options.url.ptr != default_server_url.ptr) {
                allocator.free(options.url);
            }

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
        if (std.mem.eql(u8, arg, "--project-token")) {
            i += 1;
            if (i >= args.len) {
                std.process.argsFree(allocator, args);
                return error.InvalidArguments;
            }
            options.project_token = try allocator.dupe(u8, args[i]);
            continue;
        }
        if (std.mem.eql(u8, arg, "--operator-token")) {
            i += 1;
            if (i >= args.len) {
                std.process.argsFree(allocator, args);
                return error.InvalidArguments;
            }
            options.operator_token = try allocator.dupe(u8, args[i]);
            continue;
        }
        if (std.mem.eql(u8, arg, "--role")) {
            i += 1;
            if (i >= args.len) {
                std.process.argsFree(allocator, args);
                return error.InvalidArguments;
            }
            options.role = parseRole(args[i]) orelse {
                std.process.argsFree(allocator, args);
                return error.InvalidArguments;
            };
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

                    // Command-specific args consume the remainder of argv.
                    const arg_start = i + 1;
                    var arg_end = arg_start;
                    while (arg_end < args.len) {
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
