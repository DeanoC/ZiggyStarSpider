// FS commands: fs ls, read, write, stat, tree

const std = @import("std");
const args = @import("../args.zig");
const logger = @import("ziggy-core").utils.logger;
const ctx = @import("../client_context.zig");
const fsrpc = @import("../fsrpc.zig");

pub fn executeFsLs(allocator: std.mem.Allocator, options: args.Options, cmd: args.Command) !void {
    const stdout = std.fs.File.stdout().deprecatedWriter();
    const client = try ctx.getOrCreateClient(allocator, options);
    try ctx.maybeApplyWorkspaceContext(allocator, options, client);
    try fsrpc.fsrpcBootstrap(allocator, client);

    const path = if (cmd.args.len > 0) cmd.args[0] else "/";
    const fid = try fsrpc.fsrpcWalkPath(allocator, client, path);
    defer fsrpc.fsrpcClunkBestEffort(allocator, client, fid);

    try fsrpc.fsrpcOpen(allocator, client, fid, "r");
    const content = try fsrpc.fsrpcReadAllText(allocator, client, fid);
    defer allocator.free(content);

    if (content.len == 0) {
        try stdout.print("(empty)\n", .{});
    } else {
        try stdout.print("{s}\n", .{content});
    }
}

pub fn executeFsRead(allocator: std.mem.Allocator, options: args.Options, cmd: args.Command) !void {
    if (cmd.args.len == 0) {
        logger.err("fs read requires a path", .{});
        return error.InvalidArguments;
    }

    const stdout = std.fs.File.stdout().deprecatedWriter();
    const client = try ctx.getOrCreateClient(allocator, options);
    try ctx.maybeApplyWorkspaceContext(allocator, options, client);
    try fsrpc.fsrpcBootstrap(allocator, client);

    const fid = try fsrpc.fsrpcWalkPath(allocator, client, cmd.args[0]);
    defer fsrpc.fsrpcClunkBestEffort(allocator, client, fid);

    try fsrpc.fsrpcOpen(allocator, client, fid, "r");
    const content = try fsrpc.fsrpcReadAllText(allocator, client, fid);
    defer allocator.free(content);
    try stdout.print("{s}\n", .{content});
}

pub fn executeFsWrite(allocator: std.mem.Allocator, options: args.Options, cmd: args.Command) !void {
    if (cmd.args.len < 2) {
        logger.err("fs write requires a path and content", .{});
        return error.InvalidArguments;
    }

    const stdout = std.fs.File.stdout().deprecatedWriter();
    const client = try ctx.getOrCreateClient(allocator, options);
    try ctx.maybeApplyWorkspaceContext(allocator, options, client);
    try fsrpc.fsrpcBootstrap(allocator, client);

    const fid = try fsrpc.fsrpcWalkPath(allocator, client, cmd.args[0]);
    defer fsrpc.fsrpcClunkBestEffort(allocator, client, fid);

    const content = try std.mem.join(allocator, " ", cmd.args[1..]);
    defer allocator.free(content);

    try fsrpc.fsrpcOpen(allocator, client, fid, "rw");
    var write = try fsrpc.fsrpcWriteText(allocator, client, fid, content, null);
    defer write.deinit(allocator);
    try stdout.print("wrote {d} byte(s)\n", .{write.written});
}

pub fn executeFsStat(allocator: std.mem.Allocator, options: args.Options, cmd: args.Command) !void {
    if (cmd.args.len == 0) {
        logger.err("fs stat requires a path", .{});
        return error.InvalidArguments;
    }

    const stdout = std.fs.File.stdout().deprecatedWriter();
    const client = try ctx.getOrCreateClient(allocator, options);
    try ctx.maybeApplyWorkspaceContext(allocator, options, client);
    try fsrpc.fsrpcBootstrap(allocator, client);

    const fid = try fsrpc.fsrpcWalkPath(allocator, client, cmd.args[0]);
    defer fsrpc.fsrpcClunkBestEffort(allocator, client, fid);

    const stat_json = try fsrpc.fsrpcStatRaw(allocator, client, fid);
    defer allocator.free(stat_json);
    try stdout.print("{s}\n", .{stat_json});
}

const FsTreeOptions = struct {
    root_path: []const u8 = "/",
    root_path_set: bool = false,
    max_depth: usize = 8,
    files_only: bool = false,
    dirs_only: bool = false,
};

fn fsTreeWalk(
    allocator: std.mem.Allocator,
    client: anytype,
    stdout: anytype,
    path: []const u8,
    display_name: []const u8,
    depth: usize,
    opts: FsTreeOptions,
) !void {
    const fid = try fsrpc.fsrpcWalkPath(allocator, client, path);
    defer fsrpc.fsrpcClunkBestEffort(allocator, client, fid);
    const is_dir = try fsrpc.fsrpcFidIsDir(allocator, client, fid);

    const print_entry = if (is_dir) !opts.files_only else !opts.dirs_only;
    if (print_entry) {
        var indent_idx: usize = 0;
        while (indent_idx < depth) : (indent_idx += 1) {
            try stdout.print("  ", .{});
        }
        try stdout.print("{s}\n", .{display_name});
    }

    if (!is_dir or depth >= opts.max_depth) return;
    try fsrpc.fsrpcOpen(allocator, client, fid, "r");
    const listing = try fsrpc.fsrpcReadAllText(allocator, client, fid);
    defer allocator.free(listing);

    var iter = std.mem.splitScalar(u8, listing, '\n');
    while (iter.next()) |raw| {
        const entry = std.mem.trim(u8, raw, " \t\r\n");
        if (entry.len == 0) continue;
        if (std.mem.eql(u8, entry, ".") or std.mem.eql(u8, entry, "..")) continue;

        const child_path = try fsrpc.joinFsPath(allocator, path, entry);
        defer allocator.free(child_path);
        try fsTreeWalk(allocator, client, stdout, child_path, entry, depth + 1, opts);
    }
}

pub fn executeFsTree(allocator: std.mem.Allocator, options: args.Options, cmd: args.Command) !void {
    const stdout = std.fs.File.stdout().deprecatedWriter();
    const client = try ctx.getOrCreateClient(allocator, options);
    try ctx.maybeApplyWorkspaceContext(allocator, options, client);
    try fsrpc.fsrpcBootstrap(allocator, client);

    var tree_opts = FsTreeOptions{};
    var i: usize = 0;
    while (i < cmd.args.len) : (i += 1) {
        const arg = cmd.args[i];
        if (std.mem.eql(u8, arg, "--max-depth")) {
            i += 1;
            if (i >= cmd.args.len) return error.InvalidArguments;
            tree_opts.max_depth = try std.fmt.parseInt(usize, cmd.args[i], 10);
            continue;
        }
        if (std.mem.eql(u8, arg, "--files-only")) {
            tree_opts.files_only = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--dirs-only")) {
            tree_opts.dirs_only = true;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--")) return error.InvalidArguments;
        if (tree_opts.root_path_set) return error.InvalidArguments;
        tree_opts.root_path = arg;
        tree_opts.root_path_set = true;
    }
    if (tree_opts.files_only and tree_opts.dirs_only) return error.InvalidArguments;

    const root_label = if (std.mem.eql(u8, tree_opts.root_path, "")) "/" else tree_opts.root_path;
    try fsTreeWalk(allocator, client, stdout, tree_opts.root_path, root_label, 0, tree_opts);
}
