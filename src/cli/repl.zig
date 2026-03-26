// repl.zig — Interactive REPL for the Spider CLI.
//
// Invoked by `spider` (no command) or `spider -i / --interactive`.
//
// Input syntax:
//   /<noun> <verb> [args...]   run any spider CLI command
//   /help                      show REPL help
//   /quit  or  /exit           exit the REPL
//   plain text                 send as a chat message to the active workspace
//
// The connection is established once at startup and reused for the session.
// If the workspace context changes (e.g. /workspace use <id>) the prompt
// updates on the next iteration.

const std = @import("std");
const args = @import("args.zig");
const tui = @import("tui.zig");
const ctx = @import("client_context.zig");
const fsrpc = @import("fsrpc.zig");
const vd = @import("venom_discovery.zig");
const cmd_chat = @import("commands/chat.zig");

// Import executeCommand from main via a peer module reference isn't possible,
// so we duplicate the dispatch here. This is the accepted pattern for CLIs
// that expose both batch and interactive surfaces.
const cmd_workspace = @import("commands/workspace.zig");
const cmd_node = @import("commands/node.zig");
const cmd_session = @import("commands/session.zig");
const cmd_agent = @import("commands/agent.zig");
const cmd_auth = @import("commands/auth.zig");
const cmd_fs = @import("commands/fs.zig");
const cmd_complete = @import("commands/complete.zig");

// ── History ───────────────────────────────────────────────────────────────────

const HISTORY_MAX = 50;

const History = struct {
    items: [HISTORY_MAX][]u8 = undefined,
    len: usize = 0,
    allocator: std.mem.Allocator,

    fn init(allocator: std.mem.Allocator) History {
        return .{ .allocator = allocator };
    }

    fn deinit(self: *History) void {
        for (self.items[0..self.len]) |item| self.allocator.free(item);
        self.len = 0;
    }

    fn push(self: *History, line: []const u8) void {
        if (line.len == 0) return;
        // Avoid consecutive duplicates
        if (self.len > 0 and std.mem.eql(u8, self.items[self.len - 1], line)) return;
        if (self.len == HISTORY_MAX) {
            self.allocator.free(self.items[0]);
            std.mem.copyForwards(u8, std.mem.sliceAsBytes(self.items[0 .. HISTORY_MAX - 1]), std.mem.sliceAsBytes(self.items[1..HISTORY_MAX]));
            self.len -= 1;
        }
        self.items[self.len] = self.allocator.dupe(u8, line) catch return;
        self.len += 1;
    }
};

// ── Prompt ────────────────────────────────────────────────────────────────────

fn printPrompt(stdout: anytype, workspace_id: ?[]const u8) void {
    tui.writeAnsi(stdout, tui.BOLD ++ tui.CYAN);
    if (workspace_id) |id| {
        // Use at most 20 chars of the workspace id to keep prompt short
        const display_len = @min(id.len, 20);
        stdout.print("spider@{s}> ", .{id[0..display_len]}) catch {};
    } else {
        stdout.writeAll("spider> ") catch {};
    }
    tui.writeAnsi(stdout, tui.RESET);
}

// ── Command parsing ───────────────────────────────────────────────────────────

/// Tokenise `line` (shell-style, no quoting) into owned slice of slices.
fn tokenize(allocator: std.mem.Allocator, line: []const u8) ![][]u8 {
    var tokens = std.ArrayListUnmanaged([]u8){};
    errdefer {
        for (tokens.items) |t| allocator.free(t);
        tokens.deinit(allocator);
    }
    var it = std.mem.tokenizeAny(u8, line, " \t");
    while (it.next()) |tok| {
        try tokens.append(allocator, try allocator.dupe(u8, tok));
    }
    return tokens.toOwnedSlice(allocator);
}

fn freeTokens(allocator: std.mem.Allocator, tokens: [][]u8) void {
    for (tokens) |t| allocator.free(t);
    allocator.free(tokens);
}

// ── REPL dispatch ─────────────────────────────────────────────────────────────

fn dispatchCommand(
    allocator: std.mem.Allocator,
    options: args.Options,
    noun: args.Noun,
    verb: args.Verb,
    cmd_args: []const []const u8,
) !void {
    // Build a temporary Command (args slice borrows cmd_args — no copies needed)
    const cmd = args.Command{
        .noun = noun,
        .verb = verb,
        .args = cmd_args,
    };
    const stdout = std.fs.File.stdout().deprecatedWriter();
    switch (noun) {
        .chat => switch (verb) {
            .send => try cmd_chat.executeChatSend(allocator, options, cmd),
            .resume_job => try cmd_chat.executeChatResume(allocator, options, cmd),
            else => try stdout.print("Unknown chat verb\n", .{}),
        },
        .workspace => switch (verb) {
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
            else => try stdout.print("Unknown workspace verb\n", .{}),
        },
        .node => switch (verb) {
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
            else => try stdout.print("Unknown node verb\n", .{}),
        },
        .session => switch (verb) {
            .list => try cmd_session.executeSessionList(allocator, options, cmd),
            .status => try cmd_session.executeSessionStatus(allocator, options, cmd),
            .attach => try cmd_session.executeSessionAttach(allocator, options, cmd),
            .resume_job => try cmd_session.executeSessionResume(allocator, options, cmd),
            .close => try cmd_session.executeSessionClose(allocator, options, cmd),
            .history => try cmd_session.executeSessionHistory(allocator, options, cmd),
            .restore => try cmd_session.executeSessionRestore(allocator, options, cmd),
            else => try stdout.print("Unknown session verb\n", .{}),
        },
        .agent => switch (verb) {
            .list => try cmd_agent.executeAgentList(allocator, options, cmd),
            .info => try cmd_agent.executeAgentInfo(allocator, options, cmd),
            else => try stdout.print("Unknown agent verb\n", .{}),
        },
        .auth => switch (verb) {
            .status => try cmd_auth.executeAuthStatus(allocator, options, cmd),
            .rotate => try cmd_auth.executeAuthRotate(allocator, options, cmd),
            else => try stdout.print("Unknown auth verb\n", .{}),
        },
        .fs => switch (verb) {
            .ls => try cmd_fs.executeFsLs(allocator, options, cmd),
            .read => try cmd_fs.executeFsRead(allocator, options, cmd),
            .write => try cmd_fs.executeFsWrite(allocator, options, cmd),
            .stat => try cmd_fs.executeFsStat(allocator, options, cmd),
            .tree => try cmd_fs.executeFsTree(allocator, options, cmd),
            else => try stdout.print("Unknown fs verb\n", .{}),
        },
        .complete => try cmd_complete.executeComplete(allocator, options, cmd),
        .status => {
            try stdout.print("Connection: {s}\n", .{if (ctx.g_connected) "connected" else "disconnected"});
        },
        else => try stdout.print("Unknown command\n", .{}),
    }
}

fn printReplHelp(stdout: anytype) void {
    tui.writeAnsi(stdout, tui.BOLD);
    stdout.writeAll("\nSpider REPL — available commands\n") catch {};
    tui.writeAnsi(stdout, tui.RESET);
    stdout.writeAll(
        \\  /workspace list|use|up|status|doctor|info|...
        \\  /node list|info|pending|approve|deny|...
        \\  /session list|status|attach|close|history
        \\  /agent list|info
        \\  /auth status|rotate
        \\  /fs ls|read|write|stat|tree
        \\  /status          — show connection info
        \\  /help            — show this help
        \\  /quit /exit      — exit the REPL
        \\
        \\  <plain text>     — send as a chat message to the active workspace
        \\
    ) catch {};
}

// ── Entry point ───────────────────────────────────────────────────────────────

pub fn run(allocator: std.mem.Allocator, options: args.Options) !void {
    const stdout = std.fs.File.stdout().deprecatedWriter();

    // Banner
    tui.writeAnsi(stdout, tui.BOLD ++ tui.BLUE);
    stdout.writeAll("\n╔══════════════════════════════════╗\n") catch {};
    stdout.writeAll("║   Spider Interactive REPL        ║\n") catch {};
    stdout.writeAll("╚══════════════════════════════════╝\n") catch {};
    tui.writeAnsi(stdout, tui.RESET);
    tui.printInfo("Type /help for commands, /quit to exit.");
    tui.printInfo("Plain text sends a chat message to the active workspace.");
    stdout.writeByte('\n') catch {};

    // Establish connection
    const client = ctx.getOrCreateClient(allocator, options) catch |err| {
        tui.printError("Failed to connect to Spider server.");
        return err;
    };
    ctx.maybeApplyWorkspaceContext(allocator, options, client) catch {
        tui.printError("Failed to apply workspace context (try /workspace use <id>).");
        // Non-fatal — continue without workspace context
    };

    var history = History.init(allocator);
    defer history.deinit();

    // ── Main loop ─────────────────────────────────────────────────────────────
    while (true) {
        // Refresh workspace display name each iteration (workspace use may have changed it)
        var cfg = ctx.loadCliConfig(allocator) catch null;
        defer if (cfg) |*c| c.deinit();
        const workspace_id: ?[]const u8 = if (cfg) |*c| ctx.resolveWorkspaceSelection(options, c) else null;

        printPrompt(stdout, workspace_id);

        const raw = tui.readLine(allocator) catch |err| switch (err) {
            error.EndOfStream => {
                stdout.writeByte('\n') catch {};
                break;
            },
            else => return err,
        };
        defer allocator.free(raw);

        const line = std.mem.trim(u8, raw, " \t\r\n");
        if (line.len == 0) continue;
        history.push(line);

        // ── Meta-commands ──────────────────────────────────────────────────
        if (std.mem.eql(u8, line, "/quit") or std.mem.eql(u8, line, "/exit")) {
            tui.printInfo("Goodbye.");
            break;
        }
        if (std.mem.eql(u8, line, "/help")) {
            printReplHelp(stdout);
            continue;
        }

        // ── Slash command: /<noun> [<verb>] [args...] ──────────────────────
        if (line[0] == '/') {
            const cmd_line = line[1..];
            if (cmd_line.len == 0) {
                printReplHelp(stdout);
                continue;
            }

            const tokens = tokenize(allocator, cmd_line) catch {
                tui.printError("Out of memory");
                continue;
            };
            defer freeTokens(allocator, tokens);

            if (tokens.len == 0) continue;

            const noun = args.parseNoun(tokens[0]) orelse {
                const msg = std.fmt.allocPrint(
                    allocator,
                    "Unknown command: {s}. Type /help for available commands.",
                    .{tokens[0]},
                ) catch "Unknown command.";
                defer allocator.free(msg);
                tui.printError(msg);
                continue;
            };

            // status is noun-only
            if (noun == .status or noun == .help or noun == .complete) {
                const cmd_args: []const []const u8 = if (tokens.len > 1) tokens[1..] else &.{};
                dispatchCommand(allocator, options, noun, .status, cmd_args) catch |err| {
                    const msg = std.fmt.allocPrint(allocator, "Error: {s}", .{@errorName(err)}) catch "Error";
                    defer allocator.free(msg);
                    tui.printError(msg);
                };
                continue;
            }

            // All other nouns require a verb
            if (tokens.len < 2) {
                const msg = std.fmt.allocPrint(
                    allocator,
                    "Usage: /{s} <verb> [args...]",
                    .{tokens[0]},
                ) catch "Missing verb.";
                defer allocator.free(msg);
                tui.printError(msg);
                continue;
            }

            const verb = args.parseVerb(noun, tokens[1]) orelse {
                const msg = std.fmt.allocPrint(
                    allocator,
                    "Unknown verb '{s}' for {s}.",
                    .{ tokens[1], tokens[0] },
                ) catch "Unknown verb.";
                defer allocator.free(msg);
                tui.printError(msg);
                continue;
            };

            const cmd_args: []const []const u8 = if (tokens.len > 2) tokens[2..] else &.{};
            dispatchCommand(allocator, options, noun, verb, cmd_args) catch |err| {
                const msg = std.fmt.allocPrint(allocator, "Error: {s}", .{@errorName(err)}) catch "Error";
                defer allocator.free(msg);
                tui.printError(msg);
            };
            continue;
        }

        // ── Plain text → chat send ─────────────────────────────────────────
        const msg_parts = [_][]const u8{line};
        const chat_cmd = args.Command{
            .noun = .chat,
            .verb = .send,
            .args = &msg_parts,
        };
        cmd_chat.executeChatSend(allocator, options, chat_cmd) catch |err| {
            if (err == error.ServiceNotFound or err == error.NotConnected) {
                tui.printError("No chat service available. Connect to a workspace first (/workspace use <id>).");
            } else {
                const errmsg = std.fmt.allocPrint(allocator, "Chat error: {s}", .{@errorName(err)}) catch "Chat error";
                defer allocator.free(errmsg);
                tui.printError(errmsg);
            }
        };
    }
}
