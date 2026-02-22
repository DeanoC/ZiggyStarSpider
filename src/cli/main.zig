const std = @import("std");
const args = @import("args.zig");
const logger = @import("ziggy-core").utils.logger;
const WebSocketClient = @import("../client/websocket.zig").WebSocketClient;
const unified = @import("ziggy-spider-protocol").unified;

// Main CLI entry point for ZiggyStarSpider

var g_client: ?WebSocketClient = null;
var g_connected: bool = false;
var g_fsrpc_tag: u32 = 1;
var g_fsrpc_fid: u32 = 2;

pub fn run(allocator: std.mem.Allocator) !void {
    defer cleanupGlobalClient();

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
        // TUI mode is only available when built with the TUI target
        // Use zig build run-tui instead
        std.log.err("TUI mode must be built with 'zig build tui' or run with 'zig build run-tui'", .{});
        return error.TuiNotAvailable;
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

fn getOrCreateClient(allocator: std.mem.Allocator, url: []const u8) !*WebSocketClient {
    if (g_client == null) {
        g_client = WebSocketClient.init(allocator, url, "");
    }

    if (!g_connected) {
        g_client.?.connect() catch |err| {
            cleanupGlobalClient();
            return err;
        };
        g_connected = true;
    }

    return &g_client.?;
}

fn cleanupGlobalClient() void {
    if (g_client) |*client| {
        client.deinit();
    }
    g_client = null;
    g_connected = false;
}

fn executeCommand(allocator: std.mem.Allocator, options: args.Options, cmd: args.Command) !void {
    const stdout = std.fs.File.stdout().deprecatedWriter();

    switch (cmd.noun) {
        .chat => {
            switch (cmd.verb) {
                .send => try executeChatSend(allocator, options, cmd),
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
                .ls => try executeFsLs(allocator, options, cmd),
                .read => try executeFsRead(allocator, options, cmd),
                .write => try executeFsWrite(allocator, options, cmd),
                .stat => try executeFsStat(allocator, options, cmd),
                else => {
                    logger.err("Unknown fs verb", .{});
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

            cleanupGlobalClient();
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

const JsonEnvelope = struct {
    raw: []const u8,
    parsed: std.json.Parsed(std.json.Value),

    fn deinit(self: *JsonEnvelope, allocator: std.mem.Allocator) void {
        self.parsed.deinit();
        allocator.free(self.raw);
        self.* = undefined;
    }
};

const FsrpcWriteResult = struct {
    written: u64,
    job: ?[]u8 = null,

    fn deinit(self: *FsrpcWriteResult, allocator: std.mem.Allocator) void {
        if (self.job) |value| allocator.free(value);
        self.* = undefined;
    }
};

fn nextFsrpcTag() u32 {
    const tag = g_fsrpc_tag;
    g_fsrpc_tag +%= 1;
    if (g_fsrpc_tag == 0) g_fsrpc_tag = 1;
    return tag;
}

fn nextFsrpcFid() u32 {
    const fid = g_fsrpc_fid;
    g_fsrpc_fid +%= 1;
    if (g_fsrpc_fid == 0 or g_fsrpc_fid == 1) g_fsrpc_fid = 2;
    return fid;
}

fn executeChatSend(allocator: std.mem.Allocator, options: args.Options, cmd: args.Command) !void {
    if (cmd.args.len == 0) {
        logger.err("chat send requires a message", .{});
        return error.InvalidArguments;
    }

    const stdout = std.fs.File.stdout().deprecatedWriter();
    const message = try std.mem.join(allocator, " ", cmd.args);
    defer allocator.free(message);

    const client = try getOrCreateClient(allocator, options.url);
    try fsrpcBootstrap(allocator, client);

    const chat_input_fid = try fsrpcWalkPath(allocator, client, "/capabilities/chat/control/input");
    defer fsrpcClunkBestEffort(allocator, client, chat_input_fid);
    try fsrpcOpen(allocator, client, chat_input_fid, "rw");

    var write = try fsrpcWriteText(allocator, client, chat_input_fid, message);
    defer write.deinit(allocator);
    const job_name = write.job orelse {
        logger.err("chat send did not return a job identifier", .{});
        return error.InvalidResponse;
    };

    const result_path = try std.fmt.allocPrint(allocator, "/jobs/{s}/result.txt", .{job_name});
    defer allocator.free(result_path);

    const result_fid = try fsrpcWalkPath(allocator, client, result_path);
    defer fsrpcClunkBestEffort(allocator, client, result_fid);
    try fsrpcOpen(allocator, client, result_fid, "r");

    const content = try fsrpcReadAllText(allocator, client, result_fid);
    defer allocator.free(content);

    try stdout.print("Sent: \"{s}\"\n", .{message});
    if (content.len == 0) {
        try stdout.print("AI: (no content)\n", .{});
    } else {
        try stdout.print("AI: {s}\n", .{content});
    }
}

fn executeFsLs(allocator: std.mem.Allocator, options: args.Options, cmd: args.Command) !void {
    const stdout = std.fs.File.stdout().deprecatedWriter();
    const client = try getOrCreateClient(allocator, options.url);
    try fsrpcBootstrap(allocator, client);

    const path = if (cmd.args.len > 0) cmd.args[0] else "/";
    const fid = try fsrpcWalkPath(allocator, client, path);
    defer fsrpcClunkBestEffort(allocator, client, fid);

    try fsrpcOpen(allocator, client, fid, "r");
    const content = try fsrpcReadAllText(allocator, client, fid);
    defer allocator.free(content);

    if (content.len == 0) {
        try stdout.print("(empty)\n", .{});
    } else {
        try stdout.print("{s}\n", .{content});
    }
}

fn executeFsRead(allocator: std.mem.Allocator, options: args.Options, cmd: args.Command) !void {
    if (cmd.args.len == 0) {
        logger.err("fs read requires a path", .{});
        return error.InvalidArguments;
    }

    const stdout = std.fs.File.stdout().deprecatedWriter();
    const client = try getOrCreateClient(allocator, options.url);
    try fsrpcBootstrap(allocator, client);

    const fid = try fsrpcWalkPath(allocator, client, cmd.args[0]);
    defer fsrpcClunkBestEffort(allocator, client, fid);

    try fsrpcOpen(allocator, client, fid, "r");
    const content = try fsrpcReadAllText(allocator, client, fid);
    defer allocator.free(content);
    try stdout.print("{s}\n", .{content});
}

fn executeFsWrite(allocator: std.mem.Allocator, options: args.Options, cmd: args.Command) !void {
    if (cmd.args.len < 2) {
        logger.err("fs write requires a path and content", .{});
        return error.InvalidArguments;
    }

    const stdout = std.fs.File.stdout().deprecatedWriter();
    const client = try getOrCreateClient(allocator, options.url);
    try fsrpcBootstrap(allocator, client);

    const fid = try fsrpcWalkPath(allocator, client, cmd.args[0]);
    defer fsrpcClunkBestEffort(allocator, client, fid);

    const content = try std.mem.join(allocator, " ", cmd.args[1..]);
    defer allocator.free(content);

    try fsrpcOpen(allocator, client, fid, "rw");
    var write = try fsrpcWriteText(allocator, client, fid, content);
    defer write.deinit(allocator);
    try stdout.print("wrote {d} byte(s)\n", .{write.written});
}

fn executeFsStat(allocator: std.mem.Allocator, options: args.Options, cmd: args.Command) !void {
    if (cmd.args.len == 0) {
        logger.err("fs stat requires a path", .{});
        return error.InvalidArguments;
    }

    const stdout = std.fs.File.stdout().deprecatedWriter();
    const client = try getOrCreateClient(allocator, options.url);
    try fsrpcBootstrap(allocator, client);

    const fid = try fsrpcWalkPath(allocator, client, cmd.args[0]);
    defer fsrpcClunkBestEffort(allocator, client, fid);

    const stat_json = try fsrpcStatRaw(allocator, client, fid);
    defer allocator.free(stat_json);
    try stdout.print("{s}\n", .{stat_json});
}

fn fsrpcBootstrap(allocator: std.mem.Allocator, client: *WebSocketClient) !void {
    const connect_id = try std.fmt.allocPrint(allocator, "ctl-{d}", .{std.time.milliTimestamp()});
    defer allocator.free(connect_id);

    const connect_payload = try std.fmt.allocPrint(
        allocator,
        "{{\"channel\":\"control\",\"type\":\"control.connect\",\"id\":\"{s}\"}}",
        .{connect_id},
    );
    defer allocator.free(connect_payload);
    try client.send(connect_payload);

    const version_tag = nextFsrpcTag();
    const version_req = try std.fmt.allocPrint(
        allocator,
        "{{\"channel\":\"fsrpc\",\"type\":\"fsrpc.t_version\",\"tag\":{d},\"msize\":1048576,\"version\":\"styx-lite-1\"}}",
        .{version_tag},
    );
    defer allocator.free(version_req);
    var version = try sendAndAwaitFsrpc(allocator, client, version_req, version_tag);
    defer version.deinit(allocator);
    try ensureFsrpcOk(&version);

    const attach_tag = nextFsrpcTag();
    const attach_req = try std.fmt.allocPrint(
        allocator,
        "{{\"channel\":\"fsrpc\",\"type\":\"fsrpc.t_attach\",\"tag\":{d},\"fid\":1}}",
        .{attach_tag},
    );
    defer allocator.free(attach_req);
    var attach = try sendAndAwaitFsrpc(allocator, client, attach_req, attach_tag);
    defer attach.deinit(allocator);
    try ensureFsrpcOk(&attach);
}

fn fsrpcWalkPath(allocator: std.mem.Allocator, client: *WebSocketClient, path: []const u8) !u32 {
    const segments = try splitPathSegments(allocator, path);
    defer freeSegments(allocator, segments);

    const path_json = try buildPathArrayJson(allocator, segments);
    defer allocator.free(path_json);

    const new_fid = nextFsrpcFid();
    const tag = nextFsrpcTag();
    const req = try std.fmt.allocPrint(
        allocator,
        "{{\"channel\":\"fsrpc\",\"type\":\"fsrpc.t_walk\",\"tag\":{d},\"fid\":1,\"newfid\":{d},\"path\":{s}}}",
        .{ tag, new_fid, path_json },
    );
    defer allocator.free(req);

    var response = try sendAndAwaitFsrpc(allocator, client, req, tag);
    defer response.deinit(allocator);
    try ensureFsrpcOk(&response);
    return new_fid;
}

fn fsrpcOpen(allocator: std.mem.Allocator, client: *WebSocketClient, fid: u32, mode: []const u8) !void {
    const escaped_mode = try unified.jsonEscape(allocator, mode);
    defer allocator.free(escaped_mode);

    const tag = nextFsrpcTag();
    const req = try std.fmt.allocPrint(
        allocator,
        "{{\"channel\":\"fsrpc\",\"type\":\"fsrpc.t_open\",\"tag\":{d},\"fid\":{d},\"mode\":\"{s}\"}}",
        .{ tag, fid, escaped_mode },
    );
    defer allocator.free(req);

    var response = try sendAndAwaitFsrpc(allocator, client, req, tag);
    defer response.deinit(allocator);
    try ensureFsrpcOk(&response);
}

fn fsrpcReadAllText(allocator: std.mem.Allocator, client: *WebSocketClient, fid: u32) ![]u8 {
    const tag = nextFsrpcTag();
    const req = try std.fmt.allocPrint(
        allocator,
        "{{\"channel\":\"fsrpc\",\"type\":\"fsrpc.t_read\",\"tag\":{d},\"fid\":{d},\"offset\":0,\"count\":1048576}}",
        .{ tag, fid },
    );
    defer allocator.free(req);

    var response = try sendAndAwaitFsrpc(allocator, client, req, tag);
    defer response.deinit(allocator);
    try ensureFsrpcOk(&response);

    const payload = try getPayloadObject(response.parsed.value.object);
    const data_b64 = payload.get("data_b64") orelse return error.InvalidResponse;
    if (data_b64 != .string) return error.InvalidResponse;

    const decoded_len = std.base64.standard.Decoder.calcSizeForSlice(data_b64.string) catch return error.InvalidResponse;
    const decoded = try allocator.alloc(u8, decoded_len);
    _ = std.base64.standard.Decoder.decode(decoded, data_b64.string) catch {
        allocator.free(decoded);
        return error.InvalidResponse;
    };
    return decoded;
}

fn fsrpcWriteText(allocator: std.mem.Allocator, client: *WebSocketClient, fid: u32, content: []const u8) !FsrpcWriteResult {
    const encoded = try unified.encodeDataB64(allocator, content);
    defer allocator.free(encoded);

    const tag = nextFsrpcTag();
    const req = try std.fmt.allocPrint(
        allocator,
        "{{\"channel\":\"fsrpc\",\"type\":\"fsrpc.t_write\",\"tag\":{d},\"fid\":{d},\"offset\":0,\"data_b64\":\"{s}\"}}",
        .{ tag, fid, encoded },
    );
    defer allocator.free(req);

    var response = try sendAndAwaitFsrpc(allocator, client, req, tag);
    defer response.deinit(allocator);
    try ensureFsrpcOk(&response);

    const payload = try getPayloadObject(response.parsed.value.object);
    const n = payload.get("n") orelse return error.InvalidResponse;
    if (n != .integer or n.integer < 0) return error.InvalidResponse;

    var job: ?[]u8 = null;
    if (payload.get("job")) |job_value| {
        if (job_value != .string) return error.InvalidResponse;
        job = try allocator.dupe(u8, job_value.string);
    }

    return .{
        .written = @intCast(n.integer),
        .job = job,
    };
}

fn fsrpcStatRaw(allocator: std.mem.Allocator, client: *WebSocketClient, fid: u32) ![]u8 {
    const tag = nextFsrpcTag();
    const req = try std.fmt.allocPrint(
        allocator,
        "{{\"channel\":\"fsrpc\",\"type\":\"fsrpc.t_stat\",\"tag\":{d},\"fid\":{d}}}",
        .{ tag, fid },
    );
    defer allocator.free(req);

    var response = try sendAndAwaitFsrpc(allocator, client, req, tag);
    defer response.deinit(allocator);
    try ensureFsrpcOk(&response);

    const payload = response.parsed.value.object.get("payload") orelse return error.InvalidResponse;
    var out = std.ArrayListUnmanaged(u8){};
    defer out.deinit(allocator);
    const formatter = std.json.fmt(payload, .{ .whitespace = .indent_2 });
    try std.fmt.format(out.writer(allocator), "{f}", .{formatter});
    return out.toOwnedSlice(allocator);
}

fn fsrpcClunkBestEffort(allocator: std.mem.Allocator, client: *WebSocketClient, fid: u32) void {
    const tag = nextFsrpcTag();
    const req = std.fmt.allocPrint(
        allocator,
        "{{\"channel\":\"fsrpc\",\"type\":\"fsrpc.t_clunk\",\"tag\":{d},\"fid\":{d}}}",
        .{ tag, fid },
    ) catch return;
    defer allocator.free(req);
    var response = sendAndAwaitFsrpc(allocator, client, req, tag) catch return;
    response.deinit(allocator);
}

fn sendAndAwaitFsrpc(allocator: std.mem.Allocator, client: *WebSocketClient, request_json: []const u8, tag: u32) !JsonEnvelope {
    try client.send(request_json);

    const started = std.time.milliTimestamp();
    while (std.time.milliTimestamp() - started < 15_000) {
        const maybe_raw = try client.readTimeout(2_000);
        if (maybe_raw) |raw| {
            const parsed = std.json.parseFromSlice(std.json.Value, allocator, raw, .{}) catch {
                allocator.free(raw);
                continue;
            };

            var matched = false;
            if (parsed.value == .object) {
                const obj = parsed.value.object;
                if (obj.get("channel")) |channel| {
                    if (channel == .string and std.mem.eql(u8, channel.string, "fsrpc")) {
                        if (obj.get("tag")) |raw_tag| {
                            if (raw_tag == .integer and raw_tag.integer >= 0 and @as(u32, @intCast(raw_tag.integer)) == tag) {
                                matched = true;
                            }
                        }
                    }
                }
            }

            if (matched) {
                return .{
                    .raw = raw,
                    .parsed = parsed,
                };
            }

            if (parsed.value == .object) {
                logOutOfBandFrame(parsed.value.object);
            }
            parsed.deinit();
            allocator.free(raw);
        }
    }

    return error.Timeout;
}

fn logOutOfBandFrame(root: std.json.ObjectMap) void {
    const type_value = root.get("type") orelse return;
    if (type_value != .string) return;

    if (std.mem.eql(u8, type_value.string, "debug.event")) {
        const category = if (root.get("category")) |value| switch (value) {
            .string => value.string,
            else => "unknown",
        } else "unknown";
        logger.info("Debug event: {s}", .{category});
        return;
    }

    if (std.mem.eql(u8, type_value.string, "control.error")) {
        const message = if (root.get("message")) |value| switch (value) {
            .string => value.string,
            else => "control.error",
        } else "control.error";
        logger.warn("Control error while awaiting FS-RPC response: {s}", .{message});
    }
}

fn ensureFsrpcOk(envelope: *JsonEnvelope) !void {
    if (envelope.parsed.value != .object) return error.InvalidResponse;
    const obj = envelope.parsed.value.object;
    const ok_value = obj.get("ok") orelse return error.InvalidResponse;
    if (ok_value != .bool) return error.InvalidResponse;
    if (!ok_value.bool) {
        const error_value = obj.get("error") orelse return error.RemoteError;
        if (error_value == .object) {
            if (error_value.object.get("message")) |message| {
                if (message == .string) logger.err("FS-RPC error: {s}", .{message.string});
            }
        }
        return error.RemoteError;
    }
}

fn getPayloadObject(root: std.json.ObjectMap) !std.json.ObjectMap {
    const payload = root.get("payload") orelse return error.InvalidResponse;
    if (payload != .object) return error.InvalidResponse;
    return payload.object;
}

fn splitPathSegments(allocator: std.mem.Allocator, path: []const u8) ![][]u8 {
    if (path.len == 0 or std.mem.eql(u8, path, "/")) return &.{};

    var out = std.ArrayListUnmanaged([]u8){};
    errdefer {
        for (out.items) |segment| allocator.free(segment);
        out.deinit(allocator);
    }

    var it = std.mem.tokenizeAny(u8, path, "/");
    while (it.next()) |segment| {
        if (segment.len == 0) continue;
        try out.append(allocator, try allocator.dupe(u8, segment));
    }

    return out.toOwnedSlice(allocator);
}

fn freeSegments(allocator: std.mem.Allocator, segments: [][]u8) void {
    for (segments) |segment| allocator.free(segment);
    if (segments.len > 0) allocator.free(segments);
}

fn buildPathArrayJson(allocator: std.mem.Allocator, segments: [][]u8) ![]u8 {
    var out = std.ArrayListUnmanaged(u8){};
    defer out.deinit(allocator);

    try out.append(allocator, '[');
    for (segments, 0..) |segment, idx| {
        if (idx > 0) try out.append(allocator, ',');
        const escaped = try unified.jsonEscape(allocator, segment);
        defer allocator.free(escaped);
        try out.writer(allocator).print("\"{s}\"", .{escaped});
    }
    try out.append(allocator, ']');

    return out.toOwnedSlice(allocator);
}
