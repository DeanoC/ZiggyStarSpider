// Auth commands: auth status, auth rotate

const std = @import("std");
const args = @import("../args.zig");
const logger = @import("ziggy-core").utils.logger;
const unified = @import("spider-protocol").unified;
const control_plane = @import("control_plane");
const Config = @import("../../client/config.zig").Config;
const ctx = @import("../client_context.zig");

fn setLocalRoleToken(cfg: *Config, role: Config.TokenRole, token: []const u8) !void {
    try cfg.setRoleToken(role, token);
    try cfg.setActiveRole(role);
}

fn maskTokenForDisplay(allocator: std.mem.Allocator, token: []const u8) ![]u8 {
    if (token.len == 0) return allocator.dupe(u8, "(empty)");
    if (token.len <= 8) return allocator.dupe(u8, "****");
    return std.fmt.allocPrint(
        allocator,
        "{s}...{s}",
        .{ token[0..4], token[token.len - 4 ..] },
    );
}

pub fn executeAuthStatus(allocator: std.mem.Allocator, options: args.Options, cmd: args.Command) !void {
    var reveal_tokens = false;
    for (cmd.args) |arg| {
        if (std.mem.eql(u8, arg, "--reveal")) {
            reveal_tokens = true;
            continue;
        }
        logger.err("auth status only accepts --reveal", .{});
        return error.InvalidArguments;
    }
    const stdout = std.fs.File.stdout().deprecatedWriter();
    const client = try ctx.getOrCreateClient(allocator, options);
    try ctx.ensureUnifiedV2Control(allocator, client);

    const payload_json = try control_plane.requestControlPayloadJson(
        allocator,
        client,
        &ctx.g_control_request_counter,
        "control.auth_status",
        null,
    );
    defer allocator.free(payload_json);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload_json, .{});
    defer parsed.deinit();
    if (parsed.value != .object) {
        try stdout.print("{s}\n", .{payload_json});
        return;
    }

    const admin_token = if (parsed.value.object.get("admin_token")) |value|
        if (value == .string) value.string else "(invalid)"
    else
        "(missing)";
    const user_token = if (parsed.value.object.get("user_token")) |value|
        if (value == .string) value.string else "(invalid)"
    else
        "(missing)";
    const path = if (parsed.value.object.get("path")) |value| switch (value) {
        .string => value.string,
        .null => "(none)",
        else => "(invalid)",
    } else "(missing)";

    const mask_admin = !reveal_tokens and admin_token.len > 0 and admin_token[0] != '(';
    const mask_user = !reveal_tokens and user_token.len > 0 and user_token[0] != '(';
    const display_admin_owned = if (mask_admin)
        try maskTokenForDisplay(allocator, admin_token)
    else
        null;
    defer if (display_admin_owned) |value| allocator.free(value);
    const display_user_owned = if (mask_user)
        try maskTokenForDisplay(allocator, user_token)
    else
        null;
    defer if (display_user_owned) |value| allocator.free(value);
    const display_admin = if (display_admin_owned) |value| value else admin_token;
    const display_user = if (display_user_owned) |value| value else user_token;

    try stdout.print("Auth status\n", .{});
    try stdout.print("  admin_token: {s}\n", .{display_admin});
    try stdout.print("  user_token:  {s}\n", .{display_user});
    try stdout.print("  path:        {s}\n", .{path});
    if (!reveal_tokens) {
        try stdout.print("  note: tokens are masked; run `auth status --reveal` to show full values\n", .{});
    }
}

pub fn executeAuthRotate(allocator: std.mem.Allocator, options: args.Options, cmd: args.Command) !void {
    if (cmd.args.len == 0) {
        logger.err("auth rotate requires a role: admin|user", .{});
        return error.InvalidArguments;
    }
    const role = cmd.args[0];
    var reveal_token = false;
    for (cmd.args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--reveal")) {
            reveal_token = true;
            continue;
        }
        logger.err("auth rotate only accepts role plus optional --reveal", .{});
        return error.InvalidArguments;
    }
    if (!std.mem.eql(u8, role, "admin") and !std.mem.eql(u8, role, "user")) {
        logger.err("auth rotate role must be admin or user", .{});
        return error.InvalidArguments;
    }

    const stdout = std.fs.File.stdout().deprecatedWriter();
    const client = try ctx.getOrCreateClient(allocator, options);
    try ctx.ensureUnifiedV2Control(allocator, client);

    const escaped_role = try unified.jsonEscape(allocator, role);
    defer allocator.free(escaped_role);
    const request_payload = try std.fmt.allocPrint(allocator, "{{\"role\":\"{s}\"}}", .{escaped_role});
    defer allocator.free(request_payload);

    const payload_json = try control_plane.requestControlPayloadJson(
        allocator,
        client,
        &ctx.g_control_request_counter,
        "control.auth_rotate",
        request_payload,
    );
    defer allocator.free(payload_json);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload_json, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidResponse;
    const out_role = parsed.value.object.get("role") orelse return error.InvalidResponse;
    if (out_role != .string) return error.InvalidResponse;
    const token = parsed.value.object.get("token") orelse return error.InvalidResponse;
    if (token != .string) return error.InvalidResponse;
    const token_display_owned = if (reveal_token)
        null
    else
        try maskTokenForDisplay(allocator, token.string);
    defer if (token_display_owned) |value| allocator.free(value);
    const token_display = if (token_display_owned) |value| value else token.string;

    try stdout.print("Rotated auth token\n", .{});
    try stdout.print("  role:  {s}\n", .{out_role.string});
    try stdout.print("  token: {s}\n", .{token_display});
    if (!reveal_token) {
        try stdout.print("  note: token is masked; rerun with `--reveal` to print full value\n", .{});
    }

    var cfg = try ctx.loadCliConfig(allocator);
    defer cfg.deinit();
    const token_role: Config.TokenRole = if (std.mem.eql(u8, out_role.string, "admin")) .admin else .user;
    try setLocalRoleToken(&cfg, token_role, token.string);
    try cfg.save();
    try stdout.print("  saved: local {s} token updated\n", .{if (token_role == .admin) "admin" else "user"});
}
