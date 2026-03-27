// Chat commands: chat send, chat resume

const std = @import("std");
const args = @import("../args.zig");
const logger = @import("ziggy-core").utils.logger;
const WebSocketClient = @import("../../client/websocket.zig").WebSocketClient;
const venom_bindings = @import("../../client/venom_bindings.zig");
const ctx = @import("../client_context.zig");
const fsrpc = @import("../fsrpc.zig");
const vd = @import("../venom_discovery.zig");

const ChatBindingPaths = vd.ChatBindingPaths;

const ChatProgressOptions = struct {
    args: []const []const u8,
    show_thoughts: bool = true,
    quiet_progress: bool = false,

    fn deinit(self: *ChatProgressOptions, allocator: std.mem.Allocator) void {
        allocator.free(self.args);
        self.* = undefined;
    }
};

fn parseChatProgressOptions(
    allocator: std.mem.Allocator,
    raw_args: []const []const u8,
) !ChatProgressOptions {
    var filtered = std.ArrayListUnmanaged([]const u8){};
    errdefer filtered.deinit(allocator);

    var show_thoughts = true;
    var quiet_progress = false;
    for (raw_args) |arg| {
        if (std.mem.eql(u8, arg, "--no-thoughts")) {
            show_thoughts = false;
            continue;
        }
        if (std.mem.eql(u8, arg, "--quiet-progress")) {
            quiet_progress = true;
            continue;
        }
        try filtered.append(allocator, arg);
    }

    return .{
        .args = try filtered.toOwnedSlice(allocator),
        .show_thoughts = show_thoughts,
        .quiet_progress = quiet_progress,
    };
}

fn printThoughtProgress(stdout: anytype, thought: []const u8) !void {
    if (ctx.stdoutSupportsAnsi()) {
        try stdout.print("\x1b[2mThought: {s}\x1b[0m\n", .{thought});
    } else {
        try stdout.print("Thought: {s}\n", .{thought});
    }
}

const JobStatusInfo = struct {
    state: []u8,
    correlation_id: ?[]u8 = null,
    error_text: ?[]u8 = null,

    fn deinit(self: *JobStatusInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.state);
        if (self.correlation_id) |value| allocator.free(value);
        if (self.error_text) |value| allocator.free(value);
        self.* = undefined;
    }
};

fn parseJobStatusInfo(allocator: std.mem.Allocator, status_json: []const u8) !JobStatusInfo {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, status_json, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidResponse;
    const state_val = parsed.value.object.get("state") orelse return error.InvalidResponse;
    if (state_val != .string or state_val.string.len == 0) return error.InvalidResponse;
    return .{
        .state = try allocator.dupe(u8, state_val.string),
        .correlation_id = if (parsed.value.object.get("correlation_id")) |value|
            if (value == .string and value.string.len > 0) try allocator.dupe(u8, value.string) else null
        else
            null,
        .error_text = if (parsed.value.object.get("error")) |value|
            if (value == .string and value.string.len > 0) try allocator.dupe(u8, value.string) else null
        else
            null,
    };
}

fn readJobStatus(
    allocator: std.mem.Allocator,
    client: *WebSocketClient,
    jobs_root: []const u8,
    status_leaf: []const u8,
    job_name: []const u8,
) !JobStatusInfo {
    const status_path = try vd.buildJobLeafPath(allocator, jobs_root, job_name, status_leaf);
    defer allocator.free(status_path);
    const status_fid = try fsrpc.fsrpcWalkPath(allocator, client, status_path);
    defer fsrpc.fsrpcClunkBestEffort(allocator, client, status_fid);
    try fsrpc.fsrpcOpen(allocator, client, status_fid, "r");
    const status_json = try fsrpc.fsrpcReadAllText(allocator, client, status_fid);
    defer allocator.free(status_json);
    return parseJobStatusInfo(allocator, status_json);
}

fn waitForChatJobCompletion(
    allocator: std.mem.Allocator,
    client: *WebSocketClient,
    stdout: anytype,
    chat_paths: *const ChatBindingPaths,
    job_name: []const u8,
    show_thoughts: bool,
    quiet_progress: bool,
) !JobStatusInfo {
    var last_state: ?[]u8 = null;
    defer if (last_state) |value| allocator.free(value);
    var last_thought: ?[]u8 = null;
    defer if (last_thought) |value| allocator.free(value);

    while (true) {
        var status = try readJobStatus(allocator, client, chat_paths.jobs_root, chat_paths.status_leaf, job_name);
        errdefer status.deinit(allocator);

        if (!quiet_progress and (last_state == null or !std.mem.eql(u8, last_state.?, status.state))) {
            try stdout.print("State: {s}\n", .{status.state});
            if (last_state) |value| allocator.free(value);
            last_state = try allocator.dupe(u8, status.state);
        } else if (last_state == null or !std.mem.eql(u8, last_state.?, status.state)) {
            if (last_state) |value| allocator.free(value);
            last_state = try allocator.dupe(u8, status.state);
        }

        if (show_thoughts) if (try vd.readLatestThoughtText(allocator, client, chat_paths.thoughts_root)) |thought| {
            defer allocator.free(thought);
            if (last_thought == null or !std.mem.eql(u8, last_thought.?, thought)) {
                if (!quiet_progress) try printThoughtProgress(stdout, thought);
                if (last_thought) |value| allocator.free(value);
                last_thought = try allocator.dupe(u8, thought);
            }
        };

        if (std.mem.eql(u8, status.state, "done") or std.mem.eql(u8, status.state, "failed")) {
            return status;
        }

        status.deinit(allocator);
        std.Thread.sleep(ctx.chat_job_poll_interval_ms * std.time.ns_per_ms);
    }
}

pub fn executeChatSend(allocator: std.mem.Allocator, options: args.Options, cmd: args.Command) !void {
    var progress = try parseChatProgressOptions(allocator, cmd.args);
    defer progress.deinit(allocator);

    if (progress.args.len == 0) {
        logger.err("chat send requires a message", .{});
        return error.InvalidArguments;
    }

    const stdout = std.fs.File.stdout().deprecatedWriter();
    const message = try std.mem.join(allocator, " ", progress.args);
    defer allocator.free(message);

    const client = try ctx.getOrCreateClient(allocator, options);
    try ctx.maybeApplyWorkspaceContext(allocator, options, client);
    logger.info("Negotiating FS-RPC session...", .{});
    try fsrpc.fsrpcBootstrap(allocator, client);
    var binding_scope = try vd.resolveAttachedWorkspaceBindingScope(allocator, client);
    defer binding_scope.deinit(allocator);
    var chat_paths = try vd.discoverChatBindingPaths(allocator, client, binding_scope.asBorrowed());
    defer chat_paths.deinit(allocator);

    logger.info("Submitting chat job...", .{});
    const chat_input_fid = try fsrpc.fsrpcWalkPath(allocator, client, chat_paths.input_path);
    defer fsrpc.fsrpcClunkBestEffort(allocator, client, chat_input_fid);
    try fsrpc.fsrpcOpen(allocator, client, chat_input_fid, "rw");

    const correlation_id = try ctx.nextCorrelationId(allocator, "chat");
    defer allocator.free(correlation_id);

    var write = try fsrpc.fsrpcWriteText(allocator, client, chat_input_fid, message, correlation_id);
    defer write.deinit(allocator);
    const job_name = write.job orelse {
        logger.err("chat send did not return a job identifier", .{});
        return error.InvalidResponse;
    };

    const result_path = try vd.buildJobLeafPath(allocator, chat_paths.jobs_root, job_name, chat_paths.result_leaf);
    defer allocator.free(result_path);

    const result_fid = try fsrpc.fsrpcWalkPath(allocator, client, result_path);
    defer fsrpc.fsrpcClunkBestEffort(allocator, client, result_fid);
    try fsrpc.fsrpcOpen(allocator, client, result_fid, "r");

    try stdout.print("Sent: \"{s}\"\n", .{message});
    try stdout.print("Chat job queued: {s}\n", .{job_name});
    if (write.correlation_id) |value| {
        try stdout.print("Correlation ID: {s}\n", .{value});
    }

    logger.info("Waiting for chat result...", .{});
    var status = try waitForChatJobCompletion(
        allocator,
        client,
        stdout,
        &chat_paths,
        job_name,
        progress.show_thoughts,
        progress.quiet_progress,
    );
    defer status.deinit(allocator);

    const content = try fsrpc.fsrpcReadAllText(allocator, client, result_fid);
    defer allocator.free(content);

    if (std.mem.eql(u8, status.state, "failed")) {
        if (status.error_text) |value| {
            try stdout.print("AI failed: {s}\n", .{value});
        } else if (content.len > 0) {
            try stdout.print("AI failed: {s}\n", .{content});
        } else {
            try stdout.print("AI failed\n", .{});
        }
        return;
    }
    if (content.len == 0) {
        try stdout.print("AI: (no content)\n", .{});
    } else {
        try stdout.print("AI: {s}\n", .{content});
    }
}

pub fn executeChatResume(allocator: std.mem.Allocator, options: args.Options, cmd: args.Command) !void {
    var progress = try parseChatProgressOptions(allocator, cmd.args);
    defer progress.deinit(allocator);

    const stdout = std.fs.File.stdout().deprecatedWriter();
    const client = try ctx.getOrCreateClient(allocator, options);
    try ctx.maybeApplyWorkspaceContext(allocator, options, client);
    try fsrpc.fsrpcBootstrap(allocator, client);
    var binding_scope = try vd.resolveAttachedWorkspaceBindingScope(allocator, client);
    defer binding_scope.deinit(allocator);
    var chat_paths = try vd.discoverChatBindingPaths(allocator, client, binding_scope.asBorrowed());
    defer chat_paths.deinit(allocator);

    if (progress.args.len == 0) {
        const jobs_fid = try fsrpc.fsrpcWalkPath(allocator, client, chat_paths.jobs_root);
        defer fsrpc.fsrpcClunkBestEffort(allocator, client, jobs_fid);
        try fsrpc.fsrpcOpen(allocator, client, jobs_fid, "r");
        const listing = try fsrpc.fsrpcReadAllText(allocator, client, jobs_fid);
        defer allocator.free(listing);

        if (listing.len == 0) {
            try stdout.print("(no jobs)\n", .{});
            return;
        }
        var iter = std.mem.splitScalar(u8, listing, '\n');
        while (iter.next()) |raw| {
            const job = std.mem.trim(u8, raw, " \t\r\n");
            if (job.len == 0) continue;
            var status = readJobStatus(allocator, client, chat_paths.jobs_root, chat_paths.status_leaf, job) catch |err| {
                try stdout.print("{s}: status unavailable ({s})\n", .{ job, @errorName(err) });
                continue;
            };
            defer status.deinit(allocator);
            try stdout.print("{s}: {s}", .{ job, status.state });
            if (status.correlation_id) |value| {
                try stdout.print(" correlation={s}", .{value});
            }
            if (status.error_text) |value| {
                try stdout.print(" error={s}", .{value});
            }
            try stdout.print("\n", .{});
        }
        return;
    }

    const job_name = progress.args[0];
    var status = try waitForChatJobCompletion(
        allocator,
        client,
        stdout,
        &chat_paths,
        job_name,
        progress.show_thoughts,
        progress.quiet_progress,
    );
    defer status.deinit(allocator);
    if (status.correlation_id) |value| {
        try stdout.print("Correlation ID: {s}\n", .{value});
    }

    const result_path = try vd.buildJobLeafPath(allocator, chat_paths.jobs_root, job_name, chat_paths.result_leaf);
    defer allocator.free(result_path);
    const result_fid = try fsrpc.fsrpcWalkPath(allocator, client, result_path);
    defer fsrpc.fsrpcClunkBestEffort(allocator, client, result_fid);
    try fsrpc.fsrpcOpen(allocator, client, result_fid, "r");
    const content = try fsrpc.fsrpcReadAllText(allocator, client, result_fid);
    defer allocator.free(content);

    if (std.mem.eql(u8, status.state, "failed")) {
        if (status.error_text) |value| {
            try stdout.print("AI failed: {s}\n", .{value});
        } else if (content.len > 0) {
            try stdout.print("AI failed: {s}\n", .{content});
        } else {
            try stdout.print("AI failed\n", .{});
        }
        return;
    }
    if (content.len == 0) {
        try stdout.print("AI: (no content)\n", .{});
    } else {
        try stdout.print("AI: {s}\n", .{content});
    }
}
