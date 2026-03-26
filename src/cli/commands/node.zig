// Node commands: list, info, pending, approve, deny, join-request,
//                service-get, service-upsert, service-runtime, watch

const std = @import("std");
const args = @import("../args.zig");
const logger = @import("ziggy-core").utils.logger;
const unified = @import("spider-protocol").unified;
const control_plane = @import("control_plane");
const workspace_types = control_plane.workspace_types;
const Config = @import("../../client/config.zig").Config;
const ctx = @import("../client_context.zig");
const fsrpc = @import("../fsrpc.zig");
const vd = @import("../venom_discovery.zig");
const output = @import("../output.zig");

// ── JSON helpers (re-exported from venom_discovery for local use) ─────────────

const jsonObjectStringOr = vd.jsonObjectStringOr;
const jsonObjectI64Or = vd.jsonObjectI64Or;
const jsonObjectBoolOr = vd.jsonObjectBoolOr;
const jsonPlatformFieldOr = vd.jsonPlatformFieldOr;

fn jsonArrayLenOr(obj: std.json.ObjectMap, name: []const u8) usize {
    const value = obj.get(name) orelse return 0;
    if (value != .array) return 0;
    return value.array.items.len;
}

// ── Internal helpers ──────────────────────────────────────────────────────────

fn resolveOperatorToken(options: args.Options, cfg: *const Config) ?[]const u8 {
    if (options.operator_token) |value| {
        if (value.len > 0) return value;
    }
    if (cfg.getRoleToken(.admin).len > 0) return cfg.getRoleToken(.admin);
    return null;
}

const NodeLabelArg = struct {
    key: []const u8,
    value: []const u8,
};

fn parseNodeLabelArg(raw: []const u8) !NodeLabelArg {
    const eq_idx = std.mem.indexOfScalar(u8, raw, '=') orelse return error.InvalidArguments;
    if (eq_idx == 0) return error.InvalidArguments;
    return .{
        .key = raw[0..eq_idx],
        .value = raw[eq_idx + 1 ..],
    };
}

fn printNodeServiceCatalogPayload(
    allocator: std.mem.Allocator,
    stdout: anytype,
    payload_json: []const u8,
) !void {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, payload_json, .{}) catch {
        try stdout.print("{s}\n", .{payload_json});
        return;
    };
    defer parsed.deinit();
    if (parsed.value != .object) {
        try stdout.print("{s}\n", .{payload_json});
        return;
    }

    const root = parsed.value.object;
    try stdout.print(
        "Node venoms for {s} ({s})\n",
        .{
            jsonObjectStringOr(root, "node_id", "(unknown)"),
            jsonObjectStringOr(root, "node_name", "(unknown)"),
        },
    );
    try stdout.print(
        "  Platform: os={s} arch={s} runtime={s}\n",
        .{
            jsonPlatformFieldOr(root, "os", "unknown"),
            jsonPlatformFieldOr(root, "arch", "unknown"),
            jsonPlatformFieldOr(root, "runtime_kind", "unknown"),
        },
    );

    if (root.get("labels")) |labels_val| {
        if (labels_val == .object and labels_val.object.count() > 0) {
            try stdout.print("  Labels:\n", .{});
            var label_it = labels_val.object.iterator();
            while (label_it.next()) |entry| {
                if (entry.value_ptr.* != .string) continue;
                try stdout.print("    - {s}={s}\n", .{ entry.key_ptr.*, entry.value_ptr.*.string });
            }
        } else {
            try stdout.print("  Labels: (none)\n", .{});
        }
    } else {
        try stdout.print("  Labels: (none)\n", .{});
    }

    if (root.get("venoms")) |venoms_val| {
        if (venoms_val == .array and venoms_val.array.items.len > 0) {
            try stdout.print("  Venoms ({d}):\n", .{venoms_val.array.items.len});
            for (venoms_val.array.items) |venom_val| {
                if (venom_val != .object) continue;
                const venom = venom_val.object;
                try stdout.print(
                    "    - {s} kind={s} version={s} state={s}\n",
                    .{
                        jsonObjectStringOr(venom, "venom_id", "(unknown)"),
                        jsonObjectStringOr(venom, "kind", "(unknown)"),
                        jsonObjectStringOr(venom, "version", "1"),
                        jsonObjectStringOr(venom, "state", "(unknown)"),
                    },
                );
                if (venom.get("endpoints")) |endpoints_val| {
                    if (endpoints_val == .array and endpoints_val.array.items.len > 0) {
                        for (endpoints_val.array.items) |endpoint| {
                            if (endpoint != .string) continue;
                            try stdout.print("      endpoint: {s}\n", .{endpoint.string});
                        }
                    }
                }
                if (venom.get("capabilities")) |caps| {
                    try stdout.print("      capabilities: {f}\n", .{std.json.fmt(caps, .{})});
                }
            }
        } else {
            try stdout.print("  Venoms: (none)\n", .{});
        }
    } else {
        try stdout.print("  Venoms: (none)\n", .{});
    }
}

fn printNodeServiceEventPayload(
    allocator: std.mem.Allocator,
    stdout: anytype,
    payload_value: std.json.Value,
    verbose: bool,
) !void {
    if (payload_value != .object) {
        try stdout.print("node_service_event payload is not an object\n", .{});
        return;
    }
    const payload = payload_value.object;
    const node_id = jsonObjectStringOr(payload, "node_id", "(unknown)");
    const delta_value = payload.get("service_delta");
    if (delta_value) |value| {
        if (value == .object) {
            const delta = value.object;
            try stdout.print(
                "node_service_event node={s} changed={} added={d} updated={d} removed={d} ts_ms={d}\n",
                .{
                    node_id,
                    jsonObjectBoolOr(delta, "changed", false),
                    jsonArrayLenOr(delta, "added"),
                    jsonArrayLenOr(delta, "updated"),
                    jsonArrayLenOr(delta, "removed"),
                    jsonObjectI64Or(delta, "timestamp_ms", 0),
                },
            );
        } else {
            try stdout.print("node_service_event node={s} (delta malformed)\n", .{node_id});
        }
    } else {
        try stdout.print("node_service_event node={s}\n", .{node_id});
    }

    if (!verbose) return;
    const payload_json = try std.fmt.allocPrint(
        allocator,
        "{f}",
        .{std.json.fmt(payload_value, .{ .whitespace = .indent_2 })},
    );
    defer allocator.free(payload_json);
    try stdout.print("{s}\n", .{payload_json});
}

fn nodeServiceSnapshotLineMatchesFilter(
    allocator: std.mem.Allocator,
    line: []const u8,
    node_filter: ?[]const u8,
) !bool {
    const filter = node_filter orelse return true;
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch return false;
    defer parsed.deinit();
    if (parsed.value != .object) return false;
    const root = parsed.value.object;
    const node_id = root.get("node_id") orelse return false;
    if (node_id != .string) return false;
    return std.mem.eql(u8, node_id.string, filter);
}

fn printNodeServiceSnapshotChunk(
    allocator: std.mem.Allocator,
    stdout: anytype,
    snapshot: []const u8,
    node_filter: ?[]const u8,
    replay_limit: usize,
    verbose: bool,
    full_refresh: bool,
) !void {
    var matching_lines = std.ArrayListUnmanaged([]const u8){};
    defer matching_lines.deinit(allocator);

    var lines = std.mem.splitScalar(u8, snapshot, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r\n");
        if (line.len == 0) continue;
        if (!try nodeServiceSnapshotLineMatchesFilter(allocator, line, node_filter)) continue;
        try matching_lines.append(allocator, line);
    }

    const start_index = if (full_refresh and replay_limit > 0 and matching_lines.items.len > replay_limit)
        matching_lines.items.len - replay_limit
    else
        0;

    for (matching_lines.items[start_index..]) |line| {
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch continue;
        defer parsed.deinit();
        if (parsed.value != .object) continue;
        const payload = parsed.value.object.get("payload") orelse continue;
        try printNodeServiceEventPayload(allocator, stdout, payload, verbose);
    }
}

fn validateJsonObjectPayload(allocator: std.mem.Allocator, payload: []const u8, context: []const u8) !void {
    const trimmed = std.mem.trim(u8, payload, " \t\r\n");
    if (trimmed.len == 0) {
        logger.err("{s} payload must be a non-empty JSON object", .{context});
        return error.InvalidArguments;
    }
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, trimmed, .{}) catch {
        logger.err("{s} payload must be valid JSON", .{context});
        return error.InvalidArguments;
    };
    defer parsed.deinit();
    if (parsed.value != .object) {
        logger.err("{s} payload must be a JSON object", .{context});
        return error.InvalidArguments;
    }
}

fn readNodeVenomRuntimeFile(
    allocator: std.mem.Allocator,
    client: anytype,
    runtime_root: []const u8,
    name: []const u8,
) ![]u8 {
    const path = try fsrpc.joinFsPath(allocator, runtime_root, name);
    defer allocator.free(path);
    return fsrpc.fsrpcReadPathText(allocator, client, path);
}

fn readNodeVenomRuntimeFileFallback(
    allocator: std.mem.Allocator,
    client: anytype,
    runtime_root: []const u8,
    primary_name: []const u8,
    fallback_name: []const u8,
) ![]u8 {
    return readNodeVenomRuntimeFile(allocator, client, runtime_root, primary_name) catch {
        return readNodeVenomRuntimeFile(allocator, client, runtime_root, fallback_name);
    };
}

fn resolveNodeVenomRuntimeInvokePayload(
    allocator: std.mem.Allocator,
    client: anytype,
    runtime_root: []const u8,
    payload_arg: ?[]const u8,
) ![]u8 {
    if (payload_arg) |value| {
        const trimmed = std.mem.trim(u8, value, " \t\r\n");
        try validateJsonObjectPayload(allocator, trimmed, "invoke");
        return allocator.dupe(u8, trimmed);
    }

    const template_text = readNodeVenomRuntimeFileFallback(
        allocator,
        client,
        runtime_root,
        "TEMPLATE.json",
        "template.json",
    ) catch {
        return allocator.dupe(u8, "{}");
    };
    defer allocator.free(template_text);
    const trimmed = std.mem.trim(u8, template_text, " \t\r\n");
    if (trimmed.len == 0) return allocator.dupe(u8, "{}");

    validateJsonObjectPayload(allocator, trimmed, "invoke template") catch {
        logger.warn("service invoke template is not a JSON object; falling back to {{}}", .{});
        return allocator.dupe(u8, "{}");
    };
    return allocator.dupe(u8, trimmed);
}

fn writeNodeVenomRuntimeControl(
    allocator: std.mem.Allocator,
    client: anytype,
    runtime_root: []const u8,
    name: []const u8,
    payload: []const u8,
) !void {
    const control_dir = try fsrpc.joinFsPath(allocator, runtime_root, "control");
    defer allocator.free(control_dir);
    const path = try fsrpc.joinFsPath(allocator, control_dir, name);
    defer allocator.free(path);
    try fsrpc.fsrpcWritePathText(allocator, client, path, payload);
}

// ── Public execute functions ──────────────────────────────────────────────────

pub fn executeNodeList(allocator: std.mem.Allocator, options: args.Options, cmd: args.Command) !void {
    _ = cmd;
    const stdout = std.fs.File.stdout().deprecatedWriter();
    const client = try ctx.getOrCreateClient(allocator, options);
    try ctx.ensureUnifiedV2Control(allocator, client);

    var nodes = try control_plane.listNodes(allocator, client, &ctx.g_control_request_counter);
    defer workspace_types.deinitNodeList(allocator, &nodes);
    if (nodes.items.len == 0) {
        try stdout.print("(no nodes)\n", .{});
        return;
    }

    if (options.json) {
        try stdout.writeAll("[\n");
        for (nodes.items, 0..) |node, idx| {
            try stdout.print(
                "  {{\"id\":\"{s}\",\"name\":\"{s}\",\"fs_url\":\"{s}\",\"lease_expires_at_ms\":{d}}}",
                .{ node.node_id, node.node_name, node.fs_url, node.lease_expires_at_ms },
            );
            if (idx + 1 < nodes.items.len) try stdout.writeByte(',');
            try stdout.writeByte('\n');
        }
        try stdout.writeAll("]\n");
        return;
    }

    const ansi = ctx.stdoutSupportsAnsi();
    var tbl = try output.Table.init(allocator, &.{ "ID", "Name", "FS URL", "Lease Expires (ms)" });
    defer tbl.deinit();
    for (nodes.items) |node| {
        const lease_str = try std.fmt.allocPrint(allocator, "{d}", .{node.lease_expires_at_ms});
        defer allocator.free(lease_str);
        try tbl.row(&.{ node.node_id, node.node_name, node.fs_url, lease_str });
    }
    try tbl.print(stdout, ansi);
}

pub fn executeNodeInfo(allocator: std.mem.Allocator, options: args.Options, cmd: args.Command) !void {
    if (cmd.args.len == 0) {
        logger.err("node info requires a node ID", .{});
        return error.InvalidArguments;
    }

    const stdout = std.fs.File.stdout().deprecatedWriter();
    const client = try ctx.getOrCreateClient(allocator, options);
    try ctx.ensureUnifiedV2Control(allocator, client);

    var node = try control_plane.getNode(allocator, client, &ctx.g_control_request_counter, cmd.args[0]);
    defer node.deinit(allocator);
    try stdout.print("Node {s}\n", .{node.node_id});
    try stdout.print("  Name: {s}\n", .{node.node_name});
    try stdout.print("  FS URL: {s}\n", .{node.fs_url});
    try stdout.print("  Joined: {d}\n", .{node.joined_at_ms});
    try stdout.print("  Last seen: {d}\n", .{node.last_seen_ms});
    try stdout.print("  Lease expires: {d}\n", .{node.lease_expires_at_ms});
}

pub fn executeNodePendingList(allocator: std.mem.Allocator, options: args.Options, cmd: args.Command) !void {
    if (cmd.args.len != 0) {
        logger.err("node pending does not accept arguments", .{});
        return error.InvalidArguments;
    }

    var cfg = try ctx.loadCliConfig(allocator);
    defer cfg.deinit();

    const stdout = std.fs.File.stdout().deprecatedWriter();
    const client = try ctx.getOrCreateClient(allocator, options);
    try ctx.ensureUnifiedV2Control(allocator, client);

    var payload = std.ArrayListUnmanaged(u8){};
    defer payload.deinit(allocator);
    try payload.append(allocator, '{');
    if (resolveOperatorToken(options, &cfg)) |token| {
        const escaped_token = try unified.jsonEscape(allocator, token);
        defer allocator.free(escaped_token);
        try payload.writer(allocator).print("\"operator_token\":\"{s}\"", .{escaped_token});
    }
    try payload.append(allocator, '}');

    const payload_json = try control_plane.requestControlPayloadJson(
        allocator,
        client,
        &ctx.g_control_request_counter,
        "control.node_join_pending_list",
        payload.items,
    );
    defer allocator.free(payload_json);

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, payload_json, .{}) catch {
        try stdout.print("{s}\n", .{payload_json});
        return;
    };
    defer parsed.deinit();
    if (parsed.value != .object) {
        try stdout.print("{s}\n", .{payload_json});
        return;
    }
    const pending_val = parsed.value.object.get("pending") orelse {
        try stdout.print("{s}\n", .{payload_json});
        return;
    };
    if (pending_val != .array) {
        try stdout.print("{s}\n", .{payload_json});
        return;
    }

    if (pending_val.array.items.len == 0) {
        try stdout.print("(no pending join requests)\n", .{});
        return;
    }

    try stdout.print("Pending join requests:\n", .{});
    for (pending_val.array.items) |item| {
        if (item != .object) continue;
        const request = item.object;
        try stdout.print(
            "  - {s} node={s} fs={s} platform={s}/{s}/{s} requested_at_ms={d}\n",
            .{
                jsonObjectStringOr(request, "request_id", "(unknown)"),
                jsonObjectStringOr(request, "node_name", "(unknown)"),
                jsonObjectStringOr(request, "fs_url", ""),
                jsonPlatformFieldOr(request, "os", "unknown"),
                jsonPlatformFieldOr(request, "arch", "unknown"),
                jsonPlatformFieldOr(request, "runtime_kind", "unknown"),
                jsonObjectI64Or(request, "requested_at_ms", 0),
            },
        );
    }
}

pub fn executeNodeApprove(allocator: std.mem.Allocator, options: args.Options, cmd: args.Command) !void {
    if (cmd.args.len == 0) {
        logger.err("node approve requires <request_id>", .{});
        return error.InvalidArguments;
    }

    var lease_ttl_ms: ?u64 = null;
    var i: usize = 1;
    while (i < cmd.args.len) : (i += 1) {
        const arg = cmd.args[i];
        if (std.mem.eql(u8, arg, "--lease-ttl-ms")) {
            i += 1;
            if (i >= cmd.args.len) return error.InvalidArguments;
            lease_ttl_ms = try std.fmt.parseInt(u64, cmd.args[i], 10);
            continue;
        }
        return error.InvalidArguments;
    }

    var cfg = try ctx.loadCliConfig(allocator);
    defer cfg.deinit();

    const stdout = std.fs.File.stdout().deprecatedWriter();
    const client = try ctx.getOrCreateClient(allocator, options);
    try ctx.ensureUnifiedV2Control(allocator, client);

    var payload = std.ArrayListUnmanaged(u8){};
    defer payload.deinit(allocator);
    try payload.append(allocator, '{');
    var appended = false;

    const escaped_request = try unified.jsonEscape(allocator, cmd.args[0]);
    defer allocator.free(escaped_request);
    try payload.writer(allocator).print("\"request_id\":\"{s}\"", .{escaped_request});
    appended = true;

    if (lease_ttl_ms) |value| {
        if (appended) try payload.append(allocator, ',');
        try payload.writer(allocator).print("\"lease_ttl_ms\":{d}", .{value});
        appended = true;
    }
    if (resolveOperatorToken(options, &cfg)) |token| {
        const escaped_token = try unified.jsonEscape(allocator, token);
        defer allocator.free(escaped_token);
        if (appended) try payload.append(allocator, ',');
        try payload.writer(allocator).print("\"operator_token\":\"{s}\"", .{escaped_token});
    }
    try payload.append(allocator, '}');

    const payload_json = try control_plane.requestControlPayloadJson(
        allocator,
        client,
        &ctx.g_control_request_counter,
        "control.node_join_approve",
        payload.items,
    );
    defer allocator.free(payload_json);

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, payload_json, .{}) catch {
        try stdout.print("{s}\n", .{payload_json});
        return;
    };
    defer parsed.deinit();
    if (parsed.value != .object) {
        try stdout.print("{s}\n", .{payload_json});
        return;
    }
    const root = parsed.value.object;
    try stdout.print("Pending join approved\n", .{});
    try stdout.print("  Node ID: {s}\n", .{jsonObjectStringOr(root, "node_id", "(unknown)")});
    try stdout.print("  Node name: {s}\n", .{jsonObjectStringOr(root, "node_name", "(unknown)")});
    try stdout.print("  FS URL: {s}\n", .{jsonObjectStringOr(root, "fs_url", "")});
    try stdout.print(
        "  Platform: os={s} arch={s} runtime={s}\n",
        .{
            jsonPlatformFieldOr(root, "os", "unknown"),
            jsonPlatformFieldOr(root, "arch", "unknown"),
            jsonPlatformFieldOr(root, "runtime_kind", "unknown"),
        },
    );
    try stdout.print("  Node secret: {s}\n", .{jsonObjectStringOr(root, "node_secret", "(missing)")});
    try stdout.print("  Lease token: {s}\n", .{jsonObjectStringOr(root, "lease_token", "(missing)")});
    try stdout.print("  Lease expires: {d}\n", .{jsonObjectI64Or(root, "lease_expires_at_ms", 0)});
}

pub fn executeNodeDeny(allocator: std.mem.Allocator, options: args.Options, cmd: args.Command) !void {
    if (cmd.args.len != 1) {
        logger.err("node deny requires <request_id>", .{});
        return error.InvalidArguments;
    }

    var cfg = try ctx.loadCliConfig(allocator);
    defer cfg.deinit();

    const stdout = std.fs.File.stdout().deprecatedWriter();
    const client = try ctx.getOrCreateClient(allocator, options);
    try ctx.ensureUnifiedV2Control(allocator, client);

    var payload = std.ArrayListUnmanaged(u8){};
    defer payload.deinit(allocator);
    try payload.append(allocator, '{');

    const escaped_request = try unified.jsonEscape(allocator, cmd.args[0]);
    defer allocator.free(escaped_request);
    try payload.writer(allocator).print("\"request_id\":\"{s}\"", .{escaped_request});
    if (resolveOperatorToken(options, &cfg)) |token| {
        const escaped_token = try unified.jsonEscape(allocator, token);
        defer allocator.free(escaped_token);
        try payload.writer(allocator).print(",\"operator_token\":\"{s}\"", .{escaped_token});
    }
    try payload.append(allocator, '}');

    const payload_json = try control_plane.requestControlPayloadJson(
        allocator,
        client,
        &ctx.g_control_request_counter,
        "control.node_join_deny",
        payload.items,
    );
    defer allocator.free(payload_json);

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, payload_json, .{}) catch {
        try stdout.print("{s}\n", .{payload_json});
        return;
    };
    defer parsed.deinit();
    if (parsed.value != .object) {
        try stdout.print("{s}\n", .{payload_json});
        return;
    }
    const root = parsed.value.object;
    try stdout.print(
        "Pending join {s}: {s}\n",
        .{
            if (jsonObjectBoolOr(root, "denied", false)) "denied" else "processed",
            jsonObjectStringOr(root, "request_id", cmd.args[0]),
        },
    );
}

pub fn executeNodeJoinRequest(allocator: std.mem.Allocator, options: args.Options, cmd: args.Command) !void {
    if (cmd.args.len == 0) {
        logger.err("node join-request requires <node_name> [fs_url]", .{});
        return error.InvalidArguments;
    }

    var fs_url: ?[]const u8 = null;
    var platform_os: ?[]const u8 = null;
    var platform_arch: ?[]const u8 = null;
    var platform_runtime_kind: ?[]const u8 = null;

    var i: usize = 1;
    if (i < cmd.args.len and !std.mem.startsWith(u8, cmd.args[i], "--")) {
        fs_url = cmd.args[i];
        i += 1;
    }

    while (i < cmd.args.len) : (i += 1) {
        const arg = cmd.args[i];
        if (std.mem.eql(u8, arg, "--os")) {
            i += 1;
            if (i >= cmd.args.len) return error.InvalidArguments;
            platform_os = cmd.args[i];
            continue;
        }
        if (std.mem.eql(u8, arg, "--arch")) {
            i += 1;
            if (i >= cmd.args.len) return error.InvalidArguments;
            platform_arch = cmd.args[i];
            continue;
        }
        if (std.mem.eql(u8, arg, "--runtime-kind")) {
            i += 1;
            if (i >= cmd.args.len) return error.InvalidArguments;
            platform_runtime_kind = cmd.args[i];
            continue;
        }
        return error.InvalidArguments;
    }

    const stdout = std.fs.File.stdout().deprecatedWriter();
    const client = try ctx.getOrCreateClient(allocator, options);
    try ctx.ensureUnifiedV2Control(allocator, client);

    var payload = std.ArrayListUnmanaged(u8){};
    defer payload.deinit(allocator);
    try payload.append(allocator, '{');

    const escaped_name = try unified.jsonEscape(allocator, cmd.args[0]);
    defer allocator.free(escaped_name);
    try payload.writer(allocator).print("\"node_name\":\"{s}\"", .{escaped_name});
    if (fs_url) |value| {
        const escaped_url = try unified.jsonEscape(allocator, value);
        defer allocator.free(escaped_url);
        try payload.writer(allocator).print(",\"fs_url\":\"{s}\"", .{escaped_url});
    }

    if (platform_os != null or platform_arch != null or platform_runtime_kind != null) {
        try payload.appendSlice(allocator, ",\"platform\":{");
        var platform_fields: usize = 0;
        if (platform_os) |value| {
            const escaped = try unified.jsonEscape(allocator, value);
            defer allocator.free(escaped);
            try payload.writer(allocator).print("\"os\":\"{s}\"", .{escaped});
            platform_fields += 1;
        }
        if (platform_arch) |value| {
            const escaped = try unified.jsonEscape(allocator, value);
            defer allocator.free(escaped);
            if (platform_fields > 0) try payload.append(allocator, ',');
            try payload.writer(allocator).print("\"arch\":\"{s}\"", .{escaped});
            platform_fields += 1;
        }
        if (platform_runtime_kind) |value| {
            const escaped = try unified.jsonEscape(allocator, value);
            defer allocator.free(escaped);
            if (platform_fields > 0) try payload.append(allocator, ',');
            try payload.writer(allocator).print("\"runtime_kind\":\"{s}\"", .{escaped});
        }
        try payload.append(allocator, '}');
    }
    try payload.append(allocator, '}');

    const payload_json = try control_plane.requestControlPayloadJson(
        allocator,
        client,
        &ctx.g_control_request_counter,
        "control.node_join_request",
        payload.items,
    );
    defer allocator.free(payload_json);

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, payload_json, .{}) catch {
        try stdout.print("{s}\n", .{payload_json});
        return;
    };
    defer parsed.deinit();
    if (parsed.value != .object) {
        try stdout.print("{s}\n", .{payload_json});
        return;
    }

    const root = parsed.value.object;
    try stdout.print("Pending node join request created\n", .{});
    try stdout.print("  Request: {s}\n", .{jsonObjectStringOr(root, "request_id", "(unknown)")});
    try stdout.print("  Node: {s}\n", .{jsonObjectStringOr(root, "node_name", "(unknown)")});
    try stdout.print("  FS URL: {s}\n", .{jsonObjectStringOr(root, "fs_url", "")});
    try stdout.print(
        "  Platform: os={s} arch={s} runtime={s}\n",
        .{
            jsonPlatformFieldOr(root, "os", "unknown"),
            jsonPlatformFieldOr(root, "arch", "unknown"),
            jsonPlatformFieldOr(root, "runtime_kind", "unknown"),
        },
    );
    try stdout.print("  Requested at: {d}\n", .{jsonObjectI64Or(root, "requested_at_ms", 0)});
}

pub fn executeNodeServiceGet(allocator: std.mem.Allocator, options: args.Options, cmd: args.Command) !void {
    if (cmd.args.len != 1) {
        logger.err("node service-get requires <node_id>", .{});
        return error.InvalidArguments;
    }

    const stdout = std.fs.File.stdout().deprecatedWriter();
    const client = try ctx.getOrCreateClient(allocator, options);
    try ctx.ensureUnifiedV2Control(allocator, client);

    const payload_json = try vd.requestNodeVenomCatalogPayload(allocator, client, cmd.args[0]);
    defer allocator.free(payload_json);

    try printNodeServiceCatalogPayload(allocator, stdout, payload_json);
}

const NodeServiceRuntimeAction = enum {
    help,
    schema,
    template,
    status,
    metrics,
    health,
    config_get,
    config_set,
    invoke,
    enable,
    disable,
    restart,
    reset,
};

fn parseNodeServiceRuntimeAction(raw: []const u8) ?NodeServiceRuntimeAction {
    if (std.mem.eql(u8, raw, "help")) return .help;
    if (std.mem.eql(u8, raw, "schema")) return .schema;
    if (std.mem.eql(u8, raw, "template")) return .template;
    if (std.mem.eql(u8, raw, "status")) return .status;
    if (std.mem.eql(u8, raw, "metrics")) return .metrics;
    if (std.mem.eql(u8, raw, "health")) return .health;
    if (std.mem.eql(u8, raw, "config-get")) return .config_get;
    if (std.mem.eql(u8, raw, "config-set")) return .config_set;
    if (std.mem.eql(u8, raw, "invoke")) return .invoke;
    if (std.mem.eql(u8, raw, "enable")) return .enable;
    if (std.mem.eql(u8, raw, "disable")) return .disable;
    if (std.mem.eql(u8, raw, "restart")) return .restart;
    if (std.mem.eql(u8, raw, "reset")) return .reset;
    return null;
}

pub fn executeNodeServiceRuntime(allocator: std.mem.Allocator, options: args.Options, cmd: args.Command) !void {
    if (cmd.args.len < 3) {
        logger.err("node service-runtime requires <node_id> <venom_id> <action> [payload]", .{});
        return error.InvalidArguments;
    }

    const node_id = cmd.args[0];
    const venom_id = cmd.args[1];
    const action = parseNodeServiceRuntimeAction(cmd.args[2]) orelse {
        logger.err("node service-runtime action must be help|schema|template|status|metrics|health|config-get|config-set|invoke|enable|disable|restart|reset", .{});
        return error.InvalidArguments;
    };
    const payload_arg = if (cmd.args.len > 3) cmd.args[3] else null;

    switch (action) {
        .config_set => if (payload_arg == null) {
            logger.err("node service-runtime config-set requires JSON payload", .{});
            return error.InvalidArguments;
        },
        .invoke => {},
        else => if (payload_arg != null) {
            logger.err("node service-runtime {s} does not accept payload", .{@tagName(action)});
            return error.InvalidArguments;
        },
    }
    if (cmd.args.len > 4) {
        logger.err("node service-runtime accepts at most one payload argument", .{});
        return error.InvalidArguments;
    }

    if (action == .config_set) {
        try validateJsonObjectPayload(allocator, payload_arg.?, "config-set");
    }

    const stdout = std.fs.File.stdout().deprecatedWriter();
    const client = try ctx.getOrCreateClient(allocator, options);
    try ctx.ensureUnifiedV2Control(allocator, client);

    const catalog_payload = try vd.requestNodeVenomCatalogPayload(allocator, client, node_id);
    defer allocator.free(catalog_payload);
    const runtime_root = vd.findNodeVenomRuntimeRootPath(
        allocator,
        catalog_payload,
        node_id,
        venom_id,
    ) catch |err| {
        if (err == error.ServiceNotFound) {
            logger.err("venom {s} not found for node {s}", .{ venom_id, node_id });
            return err;
        }
        if (err == error.ServiceMountNotFound) {
            logger.err("venom {s} does not expose a runtime mount path", .{venom_id});
            return err;
        }
        return err;
    };
    defer allocator.free(runtime_root);

    try fsrpc.fsrpcBootstrap(allocator, client);

    switch (action) {
        .help => {
            const text = try readNodeVenomRuntimeFile(allocator, client, runtime_root, "README.md");
            defer allocator.free(text);
            try stdout.print("{s}\n", .{text});
        },
        .schema => {
            const text = try readNodeVenomRuntimeFileFallback(
                allocator,
                client,
                runtime_root,
                "SCHEMA.json",
                "schema.json",
            );
            defer allocator.free(text);
            try stdout.print("{s}\n", .{text});
        },
        .template => {
            const text = try readNodeVenomRuntimeFileFallback(
                allocator,
                client,
                runtime_root,
                "TEMPLATE.json",
                "template.json",
            );
            defer allocator.free(text);
            try stdout.print("{s}\n", .{text});
        },
        .status => {
            const text = try readNodeVenomRuntimeFile(allocator, client, runtime_root, "status.json");
            defer allocator.free(text);
            try stdout.print("{s}\n", .{text});
        },
        .metrics => {
            const text = try readNodeVenomRuntimeFile(allocator, client, runtime_root, "metrics.json");
            defer allocator.free(text);
            try stdout.print("{s}\n", .{text});
        },
        .health => {
            const text = try readNodeVenomRuntimeFile(allocator, client, runtime_root, "health.json");
            defer allocator.free(text);
            try stdout.print("{s}\n", .{text});
        },
        .config_get => {
            const text = try readNodeVenomRuntimeFile(allocator, client, runtime_root, "config.json");
            defer allocator.free(text);
            try stdout.print("{s}\n", .{text});
        },
        .config_set => {
            const path = try fsrpc.joinFsPath(allocator, runtime_root, "config.json");
            defer allocator.free(path);
            try fsrpc.fsrpcWritePathText(allocator, client, path, std.mem.trim(u8, payload_arg.?, " \t\r\n"));
            const health = try readNodeVenomRuntimeFile(allocator, client, runtime_root, "health.json");
            defer allocator.free(health);
            try stdout.print("updated config for {s}/{s}\n{s}\n", .{ node_id, venom_id, health });
        },
        .invoke => {
            const invoke_payload = try resolveNodeVenomRuntimeInvokePayload(
                allocator,
                client,
                runtime_root,
                payload_arg,
            );
            defer allocator.free(invoke_payload);
            try writeNodeVenomRuntimeControl(allocator, client, runtime_root, "invoke.json", invoke_payload);
            const status = try readNodeVenomRuntimeFile(allocator, client, runtime_root, "status.json");
            defer allocator.free(status);
            const result = try readNodeVenomRuntimeFile(allocator, client, runtime_root, "result.json");
            defer allocator.free(result);
            const last_error = try readNodeVenomRuntimeFile(allocator, client, runtime_root, "last_error.txt");
            defer allocator.free(last_error);
            try stdout.print("status:\n{s}\n", .{status});
            if (std.mem.trim(u8, last_error, " \t\r\n").len > 0) {
                try stdout.print("last_error:\n{s}\n", .{last_error});
            }
            try stdout.print("result:\n{s}\n", .{result});
        },
        .enable, .disable, .restart, .reset => {
            const control_name = switch (action) {
                .enable => "enable",
                .disable => "disable",
                .restart => "restart",
                .reset => "reset",
                else => unreachable,
            };
            try writeNodeVenomRuntimeControl(allocator, client, runtime_root, control_name, "{}");
            const health = try readNodeVenomRuntimeFile(allocator, client, runtime_root, "health.json");
            defer allocator.free(health);
            const status = try readNodeVenomRuntimeFile(allocator, client, runtime_root, "status.json");
            defer allocator.free(status);
            try stdout.print("{s} applied for {s}/{s}\n", .{ control_name, node_id, venom_id });
            try stdout.print("health:\n{s}\n", .{health});
            try stdout.print("status:\n{s}\n", .{status});
        },
    }
}

pub fn executeNodeServiceUpsert(allocator: std.mem.Allocator, options: args.Options, cmd: args.Command) !void {
    if (cmd.args.len < 2) {
        logger.err("node service-upsert requires <node_id> <node_secret>", .{});
        return error.InvalidArguments;
    }

    const node_id = cmd.args[0];
    const node_secret = cmd.args[1];
    var platform_os: ?[]const u8 = null;
    var platform_arch: ?[]const u8 = null;
    var platform_runtime_kind: ?[]const u8 = null;
    var labels = std.ArrayListUnmanaged(NodeLabelArg){};
    defer labels.deinit(allocator);
    var venoms_json: ?[]const u8 = null;
    var venoms_file_raw: ?[]u8 = null;
    defer if (venoms_file_raw) |raw| allocator.free(raw);

    var i: usize = 2;
    while (i < cmd.args.len) : (i += 1) {
        const arg = cmd.args[i];
        if (std.mem.eql(u8, arg, "--os")) {
            i += 1;
            if (i >= cmd.args.len) return error.InvalidArguments;
            platform_os = cmd.args[i];
            continue;
        }
        if (std.mem.eql(u8, arg, "--arch")) {
            i += 1;
            if (i >= cmd.args.len) return error.InvalidArguments;
            platform_arch = cmd.args[i];
            continue;
        }
        if (std.mem.eql(u8, arg, "--runtime-kind")) {
            i += 1;
            if (i >= cmd.args.len) return error.InvalidArguments;
            platform_runtime_kind = cmd.args[i];
            continue;
        }
        if (std.mem.eql(u8, arg, "--label")) {
            i += 1;
            if (i >= cmd.args.len) return error.InvalidArguments;
            try labels.append(allocator, try parseNodeLabelArg(cmd.args[i]));
            continue;
        }
        if (std.mem.eql(u8, arg, "--services-json") or std.mem.eql(u8, arg, "--venoms-json")) {
            i += 1;
            if (i >= cmd.args.len or venoms_json != null or venoms_file_raw != null) return error.InvalidArguments;
            venoms_json = std.mem.trim(u8, cmd.args[i], " \t\r\n");
            continue;
        }
        if (std.mem.eql(u8, arg, "--services-file") or std.mem.eql(u8, arg, "--venoms-file")) {
            i += 1;
            if (i >= cmd.args.len or venoms_json != null or venoms_file_raw != null) return error.InvalidArguments;
            venoms_file_raw = try std.fs.cwd().readFileAlloc(allocator, cmd.args[i], 2 * 1024 * 1024);
            venoms_json = std.mem.trim(u8, venoms_file_raw.?, " \t\r\n");
            continue;
        }
        return error.InvalidArguments;
    }

    if (venoms_json) |raw| {
        if (raw.len == 0) return error.InvalidArguments;
        var parsed_venoms = try std.json.parseFromSlice(std.json.Value, allocator, raw, .{});
        defer parsed_venoms.deinit();
        if (parsed_venoms.value != .array) {
            logger.err("venoms payload must be a JSON array", .{});
            return error.InvalidArguments;
        }
    }

    const stdout = std.fs.File.stdout().deprecatedWriter();
    const client = try ctx.getOrCreateClient(allocator, options);
    try ctx.ensureUnifiedV2Control(allocator, client);

    var payload = std.ArrayListUnmanaged(u8){};
    defer payload.deinit(allocator);
    try payload.append(allocator, '{');

    const escaped_node_id = try unified.jsonEscape(allocator, node_id);
    defer allocator.free(escaped_node_id);
    const escaped_node_secret = try unified.jsonEscape(allocator, node_secret);
    defer allocator.free(escaped_node_secret);
    try payload.writer(allocator).print(
        "\"node_id\":\"{s}\",\"node_secret\":\"{s}\"",
        .{ escaped_node_id, escaped_node_secret },
    );

    if (platform_os != null or platform_arch != null or platform_runtime_kind != null) {
        try payload.appendSlice(allocator, ",\"platform\":{");
        var platform_fields: usize = 0;
        if (platform_os) |value| {
            const escaped = try unified.jsonEscape(allocator, value);
            defer allocator.free(escaped);
            try payload.writer(allocator).print("\"os\":\"{s}\"", .{escaped});
            platform_fields += 1;
        }
        if (platform_arch) |value| {
            const escaped = try unified.jsonEscape(allocator, value);
            defer allocator.free(escaped);
            if (platform_fields > 0) try payload.append(allocator, ',');
            try payload.writer(allocator).print("\"arch\":\"{s}\"", .{escaped});
            platform_fields += 1;
        }
        if (platform_runtime_kind) |value| {
            const escaped = try unified.jsonEscape(allocator, value);
            defer allocator.free(escaped);
            if (platform_fields > 0) try payload.append(allocator, ',');
            try payload.writer(allocator).print("\"runtime_kind\":\"{s}\"", .{escaped});
        }
        try payload.append(allocator, '}');
    }

    if (labels.items.len > 0) {
        try payload.appendSlice(allocator, ",\"labels\":{");
        for (labels.items, 0..) |label, idx| {
            if (idx != 0) try payload.append(allocator, ',');
            const escaped_key = try unified.jsonEscape(allocator, label.key);
            defer allocator.free(escaped_key);
            const escaped_value = try unified.jsonEscape(allocator, label.value);
            defer allocator.free(escaped_value);
            try payload.writer(allocator).print("\"{s}\":\"{s}\"", .{ escaped_key, escaped_value });
        }
        try payload.append(allocator, '}');
    }

    if (venoms_json) |raw| {
        try payload.writer(allocator).print(",\"venoms\":{s}", .{raw});
    }

    try payload.append(allocator, '}');

    const payload_json = try control_plane.requestControlPayloadJson(
        allocator,
        client,
        &ctx.g_control_request_counter,
        "control.venom_upsert",
        payload.items,
    );
    defer allocator.free(payload_json);

    try printNodeServiceCatalogPayload(allocator, stdout, payload_json);
}

pub fn executeNodeServiceWatch(allocator: std.mem.Allocator, options: args.Options, cmd: args.Command) !void {
    var node_filter: ?[]const u8 = null;
    var replay_limit: usize = 25;
    var i: usize = 0;
    while (i < cmd.args.len) : (i += 1) {
        const arg = cmd.args[i];
        if (std.mem.eql(u8, arg, "--replay-limit")) {
            i += 1;
            if (i >= cmd.args.len) {
                logger.err("node watch --replay-limit requires a numeric value", .{});
                return error.InvalidArguments;
            }
            replay_limit = std.fmt.parseUnsigned(usize, cmd.args[i], 10) catch {
                logger.err("node watch --replay-limit must be an unsigned integer", .{});
                return error.InvalidArguments;
            };
            if (replay_limit > 10_000) replay_limit = 10_000;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--replay-limit=")) {
            const value = arg["--replay-limit=".len..];
            replay_limit = std.fmt.parseUnsigned(usize, value, 10) catch {
                logger.err("node watch --replay-limit must be an unsigned integer", .{});
                return error.InvalidArguments;
            };
            if (replay_limit > 10_000) replay_limit = 10_000;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--")) {
            logger.err("node watch unknown option: {s}", .{arg});
            return error.InvalidArguments;
        }
        if (node_filter != null) {
            logger.err("node watch accepts at most one optional <node_id> filter", .{});
            return error.InvalidArguments;
        }
        node_filter = arg;
    }

    const stdout = std.fs.File.stdout().deprecatedWriter();
    const client = try ctx.getOrCreateClient(allocator, options);
    try ctx.maybeApplyWorkspaceContext(allocator, options, client);
    try fsrpc.fsrpcBootstrap(allocator, client);

    if (node_filter) |node_id| {
        try stdout.print(
            "Watching node service events for node {s} via /global/services/node-service-events.ndjson (replay_limit={d}, Ctrl+C to stop)\n",
            .{ node_id, replay_limit },
        );
    } else {
        try stdout.print(
            "Watching node service events for all nodes via /global/services/node-service-events.ndjson (replay_limit={d}, Ctrl+C to stop)\n",
            .{replay_limit},
        );
    }

    var previous_snapshot: ?[]u8 = null;
    defer if (previous_snapshot) |value| allocator.free(value);

    while (true) {
        const fid = fsrpc.fsrpcWalkPath(allocator, client, "/global/services/node-service-events.ndjson") catch |err| {
            logger.err("node watch open failed: {s}", .{@errorName(err)});
            return err;
        };
        defer fsrpc.fsrpcClunkBestEffort(allocator, client, fid);
        try fsrpc.fsrpcOpen(allocator, client, fid, "r");

        const snapshot = fsrpc.fsrpcReadAllText(allocator, client, fid) catch |err| {
            logger.err("node watch read failed: {s}", .{@errorName(err)});
            return err;
        };
        defer allocator.free(snapshot);

        if (previous_snapshot) |previous| {
            if (std.mem.eql(u8, previous, snapshot)) {
                std.Thread.sleep(1 * std.time.ns_per_s);
                continue;
            }
            if (snapshot.len >= previous.len and std.mem.startsWith(u8, snapshot, previous)) {
                try printNodeServiceSnapshotChunk(
                    allocator,
                    stdout,
                    snapshot[previous.len..],
                    node_filter,
                    replay_limit,
                    options.verbose,
                    false,
                );
            } else {
                try printNodeServiceSnapshotChunk(
                    allocator,
                    stdout,
                    snapshot,
                    node_filter,
                    replay_limit,
                    options.verbose,
                    true,
                );
            }
            allocator.free(previous);
            previous_snapshot = try allocator.dupe(u8, snapshot);
        } else {
            try printNodeServiceSnapshotChunk(
                allocator,
                stdout,
                snapshot,
                node_filter,
                replay_limit,
                options.verbose,
                true,
            );
            previous_snapshot = try allocator.dupe(u8, snapshot);
        }

        std.Thread.sleep(1 * std.time.ns_per_s);
    }
}
