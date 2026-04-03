const std = @import("std");
const WebSocketClient = @import("client_websocket").WebSocketClient;
const control_plane = @import("control_plane");
const unified_v2_client = control_plane.unified_v2;
const workspace_types = control_plane.workspace_types;
const unified = @import("spider-protocol").unified;

const allocator = std.heap.c_allocator;
const packages_control_root = "/.spiderweb/control/packages";
const session_status_timeout_ms: i64 = 5_000;
const session_warming_wait_timeout_ms: i64 = 30_000;
const session_warming_poll_interval_ms: u64 = 250;
const mount_read_chunk_bytes: u32 = 64 * 1024;
const mount_read_max_total_bytes: usize = 2 * 1024 * 1024;
const system_workspace_id = "system";
const system_agent_id = "spiderweb";
const ConnectedClient = struct {
    client: WebSocketClient,
    url: []u8,
    token: []u8,
    message_counter: u64,
};

fn allocJsonEnvelopeFromError(err: anyerror) ?[*:0]u8 {
    var out = std.io.Writer.Allocating.init(allocator);
    errdefer out.deinit();

    const remote = control_plane.lastRemoteError();
    const message = remote orelse @errorName(err);

    var jw: std.json.Stringify = .{ .writer = &out.writer, .options = .{} };
    jw.beginObject() catch return null;
    jw.objectField("ok") catch return null;
    jw.write(false) catch return null;
    jw.objectField("error") catch return null;
    jw.write(message) catch return null;
    jw.endObject() catch return null;
    return out.toOwnedSliceSentinel(0) catch null;
}

fn connectClient(url_z: [*:0]const u8, token_z: [*:0]const u8) !ConnectedClient {
    const url = try allocator.dupe(u8, std.mem.span(url_z));
    errdefer allocator.free(url);
    const token = try allocator.dupe(u8, std.mem.span(token_z));
    errdefer allocator.free(token);

    var client = WebSocketClient.init(allocator, url, token);
    errdefer client.deinit();
    try client.connect();

    var message_counter: u64 = 0;
    try control_plane.ensureUnifiedV2Connection(allocator, &client, &message_counter);

    return .{
        .client = client,
        .url = url,
        .token = token,
        .message_counter = message_counter,
    };
}

fn deinitConnectedClient(state: *ConnectedClient) void {
    state.client.deinit();
    allocator.free(state.url);
    allocator.free(state.token);
}

fn packageControlRaw(
    url_z: [*:0]const u8,
    token_z: [*:0]const u8,
    workspace_id_z: [*:0]const u8,
    workspace_token_z: [*:0]const u8,
    control_name: []const u8,
    payload: []const u8,
) ![]u8 {
    var state = try connectClient(url_z, token_z);
    defer deinitConnectedClient(&state);

    try applyWorkspaceSessionContext(&state, std.mem.span(workspace_id_z), workspaceTokenFromZ(workspace_token_z));
    try mountAttach(&state, "/.spiderweb/control", 2);
    return writePackageControlAndReadResult(&state, control_name, payload);
}

fn workspaceCatalogRaw(
    url_z: [*:0]const u8,
    token_z: [*:0]const u8,
    workspace_id_z: [*:0]const u8,
    workspace_token_z: [*:0]const u8,
    relative_path: []const u8,
) ![]u8 {
    var state = try connectClient(url_z, token_z);
    defer deinitConnectedClient(&state);

    try applyWorkspaceSessionContext(&state, std.mem.span(workspace_id_z), workspaceTokenFromZ(workspace_token_z));
    try mountAttach(&state, "/.spiderweb/catalog", 2);
    return mountReadAllText(&state.client, &state.message_counter, relative_path);
}

fn workspaceManagedReadRaw(
    url_z: [*:0]const u8,
    token_z: [*:0]const u8,
    workspace_id_z: [*:0]const u8,
    workspace_token_z: [*:0]const u8,
    attach_root: []const u8,
    path: []const u8,
) ![]u8 {
    var state = try connectClient(url_z, token_z);
    defer deinitConnectedClient(&state);

    try applyWorkspaceSessionContext(&state, std.mem.span(workspace_id_z), workspaceTokenFromZ(workspace_token_z));
    try mountAttach(&state, attach_root, 2);
    return mountReadAllText(&state.client, &state.message_counter, path);
}

fn terminalExecRaw(
    url_z: [*:0]const u8,
    token_z: [*:0]const u8,
    workspace_id_z: [*:0]const u8,
    workspace_token_z: [*:0]const u8,
    payload: []const u8,
) ![]u8 {
    const workspace_id = std.mem.span(workspace_id_z);
    const workspace_token = workspaceTokenFromZ(workspace_token_z);
    var state = connectClient(url_z, token_z) catch return error.TerminalControlConnectFailed;
    defer deinitConnectedClient(&state);
    return terminalExecViaMountControl(&state, workspace_id, workspace_token, payload) catch |err| switch (err) {
        error.RemoteError,
        error.InvalidResponse,
        error.ResponseTooLarge,
        => return wrapRemoteErrorEnvelope(unified_v2_client.lastRemoteError() orelse @errorName(err)),
        else => return err,
    };
}

fn terminalExecViaMountControl(
    state: *ConnectedClient,
    workspace_id: []const u8,
    workspace_token: ?[]const u8,
    payload: []const u8,
) ![]u8 {
    try applyWorkspaceSessionContext(state, workspace_id, workspace_token);
    const candidates = [_]TerminalMountCandidate{
        .{
            .attach_root = "/.spiderweb/venoms/terminal",
            .attach_depth = 2,
            .control_path = "/.spiderweb/venoms/terminal/control/invoke.json",
            .status_path = "/.spiderweb/venoms/terminal/status.json",
            .result_path = "/.spiderweb/venoms/terminal/result.json",
            .use_invoke_envelope = true,
        },
        .{
            .attach_root = "/.spiderweb/venoms/terminal",
            .attach_depth = 2,
            .control_path = "/.spiderweb/venoms/terminal/control/exec.json",
            .status_path = "/.spiderweb/venoms/terminal/status.json",
            .result_path = "/.spiderweb/venoms/terminal/result.json",
            .use_invoke_envelope = false,
        },
        .{
            .attach_root = "/.spiderweb",
            .attach_depth = 4,
            .control_path = "/.spiderweb/venoms/terminal/control/invoke.json",
            .status_path = "/.spiderweb/venoms/terminal/status.json",
            .result_path = "/.spiderweb/venoms/terminal/result.json",
            .use_invoke_envelope = true,
        },
        .{
            .attach_root = "/.spiderweb",
            .attach_depth = 4,
            .control_path = "/.spiderweb/venoms/terminal/control/exec.json",
            .status_path = "/.spiderweb/venoms/terminal/status.json",
            .result_path = "/.spiderweb/venoms/terminal/result.json",
            .use_invoke_envelope = false,
        },
        .{
            .attach_root = "/nodes/local/fs/.spiderweb/venoms/terminal",
            .attach_depth = 2,
            .control_path = "/nodes/local/fs/.spiderweb/venoms/terminal/control/invoke.json",
            .status_path = "/nodes/local/fs/.spiderweb/venoms/terminal/status.json",
            .result_path = "/nodes/local/fs/.spiderweb/venoms/terminal/result.json",
            .use_invoke_envelope = true,
        },
        .{
            .attach_root = "/nodes/local/fs/.spiderweb/venoms/terminal",
            .attach_depth = 2,
            .control_path = "/nodes/local/fs/.spiderweb/venoms/terminal/control/exec.json",
            .status_path = "/nodes/local/fs/.spiderweb/venoms/terminal/status.json",
            .result_path = "/nodes/local/fs/.spiderweb/venoms/terminal/result.json",
            .use_invoke_envelope = false,
        },
        .{
            .attach_root = "/nodes/local/fs/.spiderweb",
            .attach_depth = 4,
            .control_path = "/nodes/local/fs/.spiderweb/venoms/terminal/control/invoke.json",
            .status_path = "/nodes/local/fs/.spiderweb/venoms/terminal/status.json",
            .result_path = "/nodes/local/fs/.spiderweb/venoms/terminal/result.json",
            .use_invoke_envelope = true,
        },
        .{
            .attach_root = "/nodes/local/fs/.spiderweb",
            .attach_depth = 4,
            .control_path = "/nodes/local/fs/.spiderweb/venoms/terminal/control/exec.json",
            .status_path = "/nodes/local/fs/.spiderweb/venoms/terminal/status.json",
            .result_path = "/nodes/local/fs/.spiderweb/venoms/terminal/result.json",
            .use_invoke_envelope = false,
        },
        .{
            .attach_root = "/nodes/local/fs",
            .attach_depth = 6,
            .control_path = "/nodes/local/fs/.spiderweb/venoms/terminal/control/invoke.json",
            .status_path = "/nodes/local/fs/.spiderweb/venoms/terminal/status.json",
            .result_path = "/nodes/local/fs/.spiderweb/venoms/terminal/result.json",
            .use_invoke_envelope = true,
        },
        .{
            .attach_root = "/nodes/local/fs",
            .attach_depth = 6,
            .control_path = "/nodes/local/fs/.spiderweb/venoms/terminal/control/exec.json",
            .status_path = "/nodes/local/fs/.spiderweb/venoms/terminal/status.json",
            .result_path = "/nodes/local/fs/.spiderweb/venoms/terminal/result.json",
            .use_invoke_envelope = false,
        },
        .{
            .attach_root = "/nodes/local/venoms/terminal",
            .attach_depth = 2,
            .control_path = "/nodes/local/venoms/terminal/control/invoke.json",
            .status_path = "/nodes/local/venoms/terminal/status.json",
            .result_path = "/nodes/local/venoms/terminal/result.json",
            .use_invoke_envelope = true,
        },
        .{
            .attach_root = "/nodes/local/venoms/terminal",
            .attach_depth = 2,
            .control_path = "/nodes/local/venoms/terminal/control/exec.json",
            .status_path = "/nodes/local/venoms/terminal/status.json",
            .result_path = "/nodes/local/venoms/terminal/result.json",
            .use_invoke_envelope = false,
        },
        .{
            .attach_root = "/nodes/local/venoms",
            .attach_depth = 3,
            .control_path = "/nodes/local/venoms/terminal/control/invoke.json",
            .status_path = "/nodes/local/venoms/terminal/status.json",
            .result_path = "/nodes/local/venoms/terminal/result.json",
            .use_invoke_envelope = true,
        },
        .{
            .attach_root = "/nodes/local/venoms",
            .attach_depth = 3,
            .control_path = "/nodes/local/venoms/terminal/control/exec.json",
            .status_path = "/nodes/local/venoms/terminal/status.json",
            .result_path = "/nodes/local/venoms/terminal/result.json",
            .use_invoke_envelope = false,
        },
    };

    var last_err: anyerror = error.FileNotFound;
    for (candidates) |candidate| {
        if (terminalExecViaMountCandidate(state, payload, candidate)) |raw| {
            return raw;
        } else |err| {
            last_err = err;
            if (unified_v2_client.lastRemoteError()) |remote| {
                std.debug.print(
                    "terminal mount candidate failed: root={s} control={s} err={s} remote={s}\n",
                    .{ candidate.attach_root, candidate.control_path, @errorName(err), remote },
                );
            } else {
                std.debug.print(
                    "terminal mount candidate failed: root={s} control={s} err={s}\n",
                    .{ candidate.attach_root, candidate.control_path, @errorName(err) },
                );
            }
        }
    }
    return last_err;
}

const TerminalMountCandidate = struct {
    attach_root: []const u8,
    attach_depth: u32,
    control_path: []const u8,
    status_path: []const u8,
    result_path: []const u8,
    use_invoke_envelope: bool,
};

fn terminalExecViaMountCandidate(
    state: *ConnectedClient,
    payload: []const u8,
    candidate: TerminalMountCandidate,
) ![]u8 {
    const write_payload = if (candidate.use_invoke_envelope)
        try wrapTerminalInvokePayload(payload)
    else
        try allocator.dupe(u8, payload);
    defer allocator.free(write_payload);

    mountAttach(state, candidate.attach_root, candidate.attach_depth) catch |err| {
        if (unified_v2_client.lastRemoteError()) |remote| {
            std.debug.print("terminal mount attach failed: root={s} err={s} remote={s}\n", .{ candidate.attach_root, @errorName(err), remote });
        } else {
            std.debug.print("terminal mount attach failed: root={s} err={s}\n", .{ candidate.attach_root, @errorName(err) });
        }
        return err;
    };
    mountWriteAllText(&state.client, &state.message_counter, candidate.control_path, write_payload) catch |err| {
        if (unified_v2_client.lastRemoteError()) |remote| {
            std.debug.print("terminal mount write failed: path={s} err={s} remote={s}\n", .{ candidate.control_path, @errorName(err), remote });
        } else {
            std.debug.print("terminal mount write failed: path={s} err={s}\n", .{ candidate.control_path, @errorName(err) });
        }
        return err;
    };
    const status_json = mountReadAllText(&state.client, &state.message_counter, candidate.status_path) catch |err| {
        if (unified_v2_client.lastRemoteError()) |remote| {
            std.debug.print("terminal mount read status failed: path={s} err={s} remote={s}\n", .{ candidate.status_path, @errorName(err), remote });
        } else {
            std.debug.print("terminal mount read status failed: path={s} err={s}\n", .{ candidate.status_path, @errorName(err) });
        }
        return err;
    };
    defer allocator.free(status_json);
    const result_json = mountReadAllText(&state.client, &state.message_counter, candidate.result_path) catch |err| {
        if (unified_v2_client.lastRemoteError()) |remote| {
            std.debug.print("terminal mount read result failed: path={s} err={s} remote={s}\n", .{ candidate.result_path, @errorName(err), remote });
        } else {
            std.debug.print("terminal mount read result failed: path={s} err={s}\n", .{ candidate.result_path, @errorName(err) });
        }
        return err;
    };
    defer allocator.free(result_json);
    return wrapTerminalExecEnvelope(status_json, result_json);
}

fn wrapTerminalInvokePayload(payload: []const u8) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidPayload;

    var out = std.io.Writer.Allocating.init(allocator);
    errdefer out.deinit();
    var jw: std.json.Stringify = .{ .writer = &out.writer, .options = .{} };
    try jw.beginObject();
    try jw.objectField("op");
    try jw.write("exec");
    try jw.objectField("arguments");
    try parsed.value.jsonStringify(&jw);
    try jw.endObject();
    return out.toOwnedSlice() catch error.OutOfMemory;
}

fn wrapRemoteErrorEnvelope(message: []const u8) ![]u8 {
    const escaped = try unified.jsonEscape(allocator, message);
    defer allocator.free(escaped);
    return std.fmt.allocPrint(allocator, "{{\"ok\":false,\"error\":\"{s}\"}}", .{escaped});
}

fn workspaceTokenFromZ(token_z: [*:0]const u8) ?[]const u8 {
    const token = std.mem.span(token_z);
    const trimmed = std.mem.trim(u8, token, " \t\r\n");
    if (trimmed.len == 0) return null;
    return trimmed;
}

fn wrapCatalogArrayEnvelope(raw_array: []const u8) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "{{\"ok\":true,\"result\":{{\"catalog\":{s}}}}}",
        .{raw_array},
    );
}

fn wrapTerminalExecEnvelope(status_json: []const u8, result_json: []const u8) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "{{\"ok\":true,\"status\":{s},\"response\":{s}}}",
        .{ status_json, result_json },
    );
}

fn buildPackagesControlPath(leaf: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ packages_control_root, leaf });
}

fn writePackageControlAndReadResult(
    state: *ConnectedClient,
    control_name: []const u8,
    payload: []const u8,
) ![]u8 {
    const control_dir = try buildPackagesControlPath("control");
    defer allocator.free(control_dir);
    const control_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ control_dir, control_name });
    defer allocator.free(control_path);
    try mountWriteAllText(&state.client, &state.message_counter, control_path, payload);

    const result_path = try buildPackagesControlPath("result.json");
    defer allocator.free(result_path);
    return mountReadAllText(&state.client, &state.message_counter, result_path);
}

fn rawCString(raw: []const u8) ?[*:0]u8 {
    const copied = allocator.dupeZ(u8, raw) catch return null;
    return copied.ptr;
}

fn optionalJsonString(value: ?[]const u8) ![]u8 {
    if (value) |text| {
        const escaped = try unified.jsonEscape(allocator, text);
        defer allocator.free(escaped);
        return std.fmt.allocPrint(allocator, "\"{s}\"", .{escaped});
    }
    return allocator.dupe(u8, "null");
}

fn buildCatalogPayload(package_id: ?[]const u8, channel: ?[]const u8) ![]u8 {
    const id_json = try optionalJsonString(package_id);
    defer allocator.free(id_json);
    const channel_json = try optionalJsonString(channel);
    defer allocator.free(channel_json);
    return std.fmt.allocPrint(
        allocator,
        "{{\"venom_id\":{s},\"channel\":{s}}}",
        .{ id_json, channel_json },
    );
}

fn buildIdPayload(package_id: []const u8, release_version: ?[]const u8) ![]u8 {
    const escaped_id = try unified.jsonEscape(allocator, package_id);
    defer allocator.free(escaped_id);
    const release_json = try optionalJsonString(release_version);
    defer allocator.free(release_json);
    return std.fmt.allocPrint(
        allocator,
        "{{\"venom_id\":\"{s}\",\"release_version\":{s}}}",
        .{ escaped_id, release_json },
    );
}

fn buildInstallPayload(package_id: []const u8) ![]u8 {
    const escaped_id = try unified.jsonEscape(allocator, package_id);
    defer allocator.free(escaped_id);
    return std.fmt.allocPrint(
        allocator,
        "{{\"venom_id\":\"{s}\",\"source\":\"registry\",\"release_version\":null,\"channel\":null}}",
        .{escaped_id},
    );
}

fn buildTerminalExecPayload(command: []const u8, cwd: ?[]const u8) ![]u8 {
    const escaped_command = try unified.jsonEscape(allocator, command);
    defer allocator.free(escaped_command);
    if (cwd) |cwd_value| {
        const escaped_cwd = try unified.jsonEscape(allocator, cwd_value);
        defer allocator.free(escaped_cwd);
        return std.fmt.allocPrint(
            allocator,
            "{{\"command\":\"{s}\",\"cwd\":\"{s}\"}}",
            .{ escaped_command, escaped_cwd },
        );
    }
    return std.fmt.allocPrint(
        allocator,
        "{{\"command\":\"{s}\"}}",
        .{escaped_command},
    );
}

fn ensureMountControlReady(state: *ConnectedClient) !void {
    try control_plane.ensureUnifiedV2Connection(allocator, &state.client, &state.message_counter);
}

fn sendMountControlRequest(
    client: *WebSocketClient,
    message_counter: *u64,
    control_type: []const u8,
    payload_json: []const u8,
    timeout_ms: i64,
) !unified_v2_client.JsonEnvelope {
    unified_v2_client.clearLastRemoteError();
    const request_id = try unified_v2_client.nextRequestId(allocator, message_counter, "mount");
    defer allocator.free(request_id);
    return unified_v2_client.sendControlRequest(
        allocator,
        client,
        control_type,
        request_id,
        payload_json,
        timeout_ms,
    ) catch |err| {
        if (err == error.RemoteError) {
            if (unified_v2_client.lastRemoteError()) |remote| {
                _ = remote;
            }
        }
        return err;
    };
}

fn controlPayloadObject(envelope: *unified_v2_client.JsonEnvelope) !std.json.ObjectMap {
    return unified_v2_client.extractPayloadObject(envelope);
}

fn mountAttach(state: *ConnectedClient, path: []const u8, depth: u32) !void {
    const escaped_path = try unified.jsonEscape(allocator, path);
    defer allocator.free(escaped_path);
    const payload = try std.fmt.allocPrint(
        allocator,
        "{{\"path\":\"{s}\",\"depth\":{d}}}",
        .{ escaped_path, depth },
    );
    defer allocator.free(payload);
    var envelope = try sendMountControlRequest(&state.client, &state.message_counter, "control.mount_attach", payload, unified_v2_client.default_control_timeout_ms);
    defer envelope.deinit(allocator);
    _ = try controlPayloadObject(&envelope);
}

fn mountReadAllText(client: *WebSocketClient, message_counter: *u64, path: []const u8) ![]u8 {
    var out = std.ArrayListUnmanaged(u8){};
    errdefer out.deinit(allocator);
    var offset: u64 = 0;
    while (true) {
        const escaped_path = try unified.jsonEscape(allocator, path);
        defer allocator.free(escaped_path);
        const payload = try std.fmt.allocPrint(
            allocator,
            "{{\"path\":\"{s}\",\"offset\":{d},\"length\":{d}}}",
            .{ escaped_path, offset, mount_read_chunk_bytes },
        );
        defer allocator.free(payload);
        var envelope = try sendMountControlRequest(client, message_counter, "control.mount_file_read", payload, unified_v2_client.default_control_timeout_ms);
        defer envelope.deinit(allocator);
        const response = try controlPayloadObject(&envelope);
        const data_b64 = response.get("data_b64") orelse return error.InvalidResponse;
        if (data_b64 != .string) return error.InvalidResponse;
        const eof = if (response.get("eof")) |value| value == .bool and value.bool else false;
        const decoded_len = std.base64.standard.Decoder.calcSizeForSlice(data_b64.string) catch return error.InvalidResponse;
        const decoded = try allocator.alloc(u8, decoded_len);
        defer allocator.free(decoded);
        _ = std.base64.standard.Decoder.decode(decoded, data_b64.string) catch return error.InvalidResponse;
        if (decoded.len != 0) {
            if (out.items.len + decoded.len > mount_read_max_total_bytes) return error.ResponseTooLarge;
            try out.appendSlice(allocator, decoded);
            offset += @as(u64, @intCast(decoded.len));
        }
        if (eof or decoded.len == 0 or decoded.len < @as(usize, mount_read_chunk_bytes)) break;
    }
    return out.toOwnedSlice(allocator);
}

fn mountWriteAllText(client: *WebSocketClient, message_counter: *u64, path: []const u8, content: []const u8) !void {
    const escaped_path = try unified.jsonEscape(allocator, path);
    defer allocator.free(escaped_path);
    const encoded = try unified.encodeDataB64(allocator, content);
    defer allocator.free(encoded);
    const payload = try std.fmt.allocPrint(
        allocator,
        "{{\"path\":\"{s}\",\"offset\":0,\"truncate_to_size\":{d},\"data_b64\":\"{s}\"}}",
        .{ escaped_path, content.len, encoded },
    );
    defer allocator.free(payload);
    var envelope = try sendMountControlRequest(client, message_counter, "control.mount_file_write", payload, 180_000);
    defer envelope.deinit(allocator);
    _ = try controlPayloadObject(&envelope);
}

fn writeWorkspaceSummaryJson(jw: *std.json.Stringify, workspace: workspace_types.WorkspaceSummary) !void {
    try jw.beginObject();
    try jw.objectField("id");
    try jw.write(workspace.id);
    try jw.objectField("name");
    try jw.write(workspace.name);
    try jw.objectField("vision");
    try jw.write(workspace.vision);
    try jw.objectField("status");
    try jw.write(workspace.status);
    try jw.objectField("template");
    try jw.write(workspace.template_id orelse "dev");
    try jw.objectField("mounts");
    try jw.write(workspace.mount_count);
    try jw.objectField("binds");
    try jw.write(workspace.bind_count);
    try jw.endObject();
}

fn writeWorkspaceDetailJson(jw: *std.json.Stringify, workspace: workspace_types.WorkspaceDetail) !void {
    try jw.beginObject();
    try jw.objectField("id");
    try jw.write(workspace.id);
    try jw.objectField("name");
    try jw.write(workspace.name);
    try jw.objectField("vision");
    try jw.write(workspace.vision);
    try jw.objectField("status");
    try jw.write(workspace.status);
    try jw.objectField("template");
    try jw.write(workspace.template_id orelse "dev");
    try jw.objectField("workspace_token");
    try jw.write(workspace.workspace_token);

    try jw.objectField("mounts");
    try jw.beginArray();
    for (workspace.mounts.items) |mount| {
        try jw.beginObject();
        try jw.objectField("mount_path");
        try jw.write(mount.mount_path);
        try jw.objectField("node_id");
        try jw.write(mount.node_id);
        try jw.objectField("export_name");
        try jw.write(mount.export_name);
        try jw.endObject();
    }
    try jw.endArray();

    try jw.objectField("binds");
    try jw.beginArray();
    for (workspace.binds.items) |bind| {
        try jw.beginObject();
        try jw.objectField("bind_path");
        try jw.write(bind.bind_path);
        try jw.objectField("target_path");
        try jw.write(bind.target_path);
        try jw.endObject();
    }
    try jw.endArray();

    try jw.endObject();
}

fn isSystemWorkspaceId(workspace_id: []const u8) bool {
    return std.mem.eql(u8, workspace_id, system_workspace_id);
}

fn isSystemAgentId(agent_id: []const u8) bool {
    return std.mem.eql(u8, agent_id, system_agent_id);
}

fn fetchDefaultAgentFromSessionList(state: *ConnectedClient, preferred_session_key: []const u8) ![]u8 {
    var sessions = try control_plane.listSessions(allocator, &state.client, &state.message_counter);
    defer sessions.deinit(allocator);

    var preferred_agent: ?[]const u8 = null;
    var active_agent: ?[]const u8 = null;
    var fallback_agent: ?[]const u8 = null;

    for (sessions.sessions.items) |session| {
        if (fallback_agent == null) fallback_agent = session.agent_id;
        if (std.mem.eql(u8, session.session_key, preferred_session_key)) preferred_agent = session.agent_id;
        if (std.mem.eql(u8, session.session_key, sessions.active_session)) active_agent = session.agent_id;
    }

    const selected = preferred_agent orelse active_agent orelse fallback_agent orelse return error.InvalidResponse;
    return allocator.dupe(u8, selected);
}

fn fetchFirstNonSystemAgent(state: *ConnectedClient) ![]u8 {
    var agents = try control_plane.listAgents(allocator, &state.client, &state.message_counter);
    defer workspace_types.deinitAgentList(allocator, &agents);

    var fallback_non_system: ?[]const u8 = null;
    for (agents.items) |agent| {
        if (isSystemAgentId(agent.id)) continue;
        if (agent.is_default) return allocator.dupe(u8, agent.id);
        if (fallback_non_system == null) fallback_non_system = agent.id;
    }

    if (fallback_non_system) |agent_id| return allocator.dupe(u8, agent_id);
    return error.NoProjectCompatibleAgent;
}

fn resolveAttachAgentForWorkspace(state: *ConnectedClient, workspace_id: []const u8) ![]u8 {
    var resolved_agent = try fetchDefaultAgentFromSessionList(state, "main");
    errdefer allocator.free(resolved_agent);

    if (isSystemWorkspaceId(workspace_id)) {
        if (!isSystemAgentId(resolved_agent)) {
            allocator.free(resolved_agent);
            resolved_agent = try allocator.dupe(u8, system_agent_id);
        }
        return resolved_agent;
    }

    if (isSystemAgentId(resolved_agent)) {
        allocator.free(resolved_agent);
        resolved_agent = try fetchFirstNonSystemAgent(state);
    }

    return resolved_agent;
}

fn sessionStatusMatchesTarget(
    status: *const workspace_types.SessionAttachStatus,
    agent_id: []const u8,
    workspace_id: []const u8,
) bool {
    if (!std.mem.eql(u8, status.agent_id, agent_id)) return false;
    const attached_workspace_id = status.workspace_id orelse return false;
    return std.mem.eql(u8, attached_workspace_id, workspace_id);
}

fn waitForSessionReady(state: *ConnectedClient, session_key: []const u8, agent_id: []const u8, workspace_id: []const u8) !void {
    const start_ms = std.time.milliTimestamp();

    while (true) {
        var status = try control_plane.sessionStatusWithTimeout(
            allocator,
            &state.client,
            &state.message_counter,
            session_key,
            session_status_timeout_ms,
        );
        defer status.deinit(allocator);

        if (!sessionStatusMatchesTarget(&status, agent_id, workspace_id)) {
            return error.SessionAttachMismatch;
        }
        if (std.mem.eql(u8, status.state, "ready")) return;
        if (std.mem.eql(u8, status.state, "error")) return error.RemoteError;
        if (std.time.milliTimestamp() - start_ms >= session_warming_wait_timeout_ms) {
            return error.RuntimeWarming;
        }
        std.Thread.sleep(session_warming_poll_interval_ms * std.time.ns_per_ms);
    }
}

fn applyWorkspaceSessionContext(state: *ConnectedClient, workspace_id: []const u8, workspace_token: ?[]const u8) !void {
    const session_key = "main";
    const attach_agent = try resolveAttachAgentForWorkspace(state, workspace_id);
    defer allocator.free(attach_agent);

    var attach_state: []const u8 = "ready";
    var active_agent: []const u8 = attach_agent;
    var did_attach = true;

    var existing_status = control_plane.sessionStatusWithTimeout(
        allocator,
        &state.client,
        &state.message_counter,
        session_key,
        session_status_timeout_ms,
    ) catch null;
    defer if (existing_status) |*value| value.deinit(allocator);

    if (existing_status) |*status| {
        if (sessionStatusMatchesTarget(status, attach_agent, workspace_id)) {
            did_attach = false;
            active_agent = status.agent_id;
            attach_state = status.state;
            if (std.mem.eql(u8, status.state, "warming")) {
                try waitForSessionReady(state, session_key, status.agent_id, workspace_id);
                attach_state = "ready";
            } else if (!std.mem.eql(u8, status.state, "ready")) {
                did_attach = true;
            }
        }
    }

    if (did_attach) {
        var attached = try control_plane.sessionAttach(
            allocator,
            &state.client,
            &state.message_counter,
            session_key,
            attach_agent,
            workspace_id,
            workspace_token,
        );
        defer attached.deinit(allocator);
        active_agent = attached.agent_id;
        attach_state = attached.state;
    }

    if (std.mem.eql(u8, attach_state, "warming")) {
        try waitForSessionReady(state, session_key, active_agent, workspace_id);
    } else if (!std.mem.eql(u8, attach_state, "ready")) {
        return error.SessionNotReady;
    }
}

export fn spider_core_workspace_list_json(url_z: [*:0]const u8, token_z: [*:0]const u8) ?[*:0]u8 {
    var state = connectClient(url_z, token_z) catch |err| return allocJsonEnvelopeFromError(err);
    defer deinitConnectedClient(&state);

    var workspaces = control_plane.listWorkspaces(allocator, &state.client, &state.message_counter) catch |err| {
        return allocJsonEnvelopeFromError(err);
    };
    defer workspace_types.deinitWorkspaceList(allocator, &workspaces);

    var out = std.io.Writer.Allocating.init(allocator);
    errdefer out.deinit();
    var jw: std.json.Stringify = .{ .writer = &out.writer, .options = .{} };
    jw.beginObject() catch |err| return allocJsonEnvelopeFromError(err);
    jw.objectField("ok") catch |err| return allocJsonEnvelopeFromError(err);
    jw.write(true) catch |err| return allocJsonEnvelopeFromError(err);
    jw.objectField("workspaces") catch |err| return allocJsonEnvelopeFromError(err);
    jw.beginArray() catch |err| return allocJsonEnvelopeFromError(err);
    for (workspaces.items) |workspace| {
        writeWorkspaceSummaryJson(&jw, workspace) catch |err| return allocJsonEnvelopeFromError(err);
    }
    jw.endArray() catch |err| return allocJsonEnvelopeFromError(err);
    jw.endObject() catch |err| return allocJsonEnvelopeFromError(err);
    return out.toOwnedSliceSentinel(0) catch null;
}

export fn spider_core_connection_probe_json(url_z: [*:0]const u8, token_z: [*:0]const u8) ?[*:0]u8 {
    var state = connectClient(url_z, token_z) catch |err| return allocJsonEnvelopeFromError(err);
    defer deinitConnectedClient(&state);

    var out = std.io.Writer.Allocating.init(allocator);
    errdefer out.deinit();
    var jw: std.json.Stringify = .{ .writer = &out.writer, .options = .{} };
    jw.beginObject() catch |err| return allocJsonEnvelopeFromError(err);
    jw.objectField("ok") catch |err| return allocJsonEnvelopeFromError(err);
    jw.write(true) catch |err| return allocJsonEnvelopeFromError(err);
    jw.objectField("reachable") catch |err| return allocJsonEnvelopeFromError(err);
    jw.write(true) catch |err| return allocJsonEnvelopeFromError(err);
    jw.endObject() catch |err| return allocJsonEnvelopeFromError(err);
    return out.toOwnedSliceSentinel(0) catch null;
}

export fn spider_core_package_list_json(
    url_z: [*:0]const u8,
    token_z: [*:0]const u8,
    workspace_id_z: [*:0]const u8,
    workspace_token_z: [*:0]const u8,
) ?[*:0]u8 {
    const raw = packageControlRaw(url_z, token_z, workspace_id_z, workspace_token_z, "list.json", "{}") catch |err| return allocJsonEnvelopeFromError(err);
    defer allocator.free(raw);
    return rawCString(raw);
}

export fn spider_core_package_catalog_json(
    url_z: [*:0]const u8,
    token_z: [*:0]const u8,
    workspace_id_z: [*:0]const u8,
    workspace_token_z: [*:0]const u8,
) ?[*:0]u8 {
    const raw = workspaceCatalogRaw(url_z, token_z, workspace_id_z, workspace_token_z, "/.spiderweb/catalog/packages.json") catch |err| return allocJsonEnvelopeFromError(err);
    defer allocator.free(raw);
    const wrapped = wrapCatalogArrayEnvelope(raw) catch |err| return allocJsonEnvelopeFromError(err);
    defer allocator.free(wrapped);
    return rawCString(wrapped);
}

export fn spider_core_workspace_venoms_json(
    url_z: [*:0]const u8,
    token_z: [*:0]const u8,
    workspace_id_z: [*:0]const u8,
    workspace_token_z: [*:0]const u8,
) ?[*:0]u8 {
    const raw = workspaceManagedReadRaw(
        url_z,
        token_z,
        workspace_id_z,
        workspace_token_z,
        "/.spiderweb/venoms",
        "/.spiderweb/venoms/VENOMS.json",
    ) catch |err| return allocJsonEnvelopeFromError(err);
    defer allocator.free(raw);
    const wrapped = std.fmt.allocPrint(
        allocator,
        "{{\"ok\":true,\"venoms\":{s}}}",
        .{raw},
    ) catch |err| return allocJsonEnvelopeFromError(err);
    defer allocator.free(wrapped);
    return rawCString(wrapped);
}

export fn spider_core_package_install_json(
    url_z: [*:0]const u8,
    token_z: [*:0]const u8,
    workspace_id_z: [*:0]const u8,
    workspace_token_z: [*:0]const u8,
    package_id_z: [*:0]const u8,
) ?[*:0]u8 {
    const payload = buildInstallPayload(std.mem.span(package_id_z)) catch |err| return allocJsonEnvelopeFromError(err);
    defer allocator.free(payload);
    const raw = packageControlRaw(url_z, token_z, workspace_id_z, workspace_token_z, "install.json", payload) catch |err| return allocJsonEnvelopeFromError(err);
    defer allocator.free(raw);
    return rawCString(raw);
}

export fn spider_core_package_enable_json(
    url_z: [*:0]const u8,
    token_z: [*:0]const u8,
    workspace_id_z: [*:0]const u8,
    workspace_token_z: [*:0]const u8,
    package_id_z: [*:0]const u8,
) ?[*:0]u8 {
    const payload = buildIdPayload(std.mem.span(package_id_z), null) catch |err| return allocJsonEnvelopeFromError(err);
    defer allocator.free(payload);
    const raw = packageControlRaw(url_z, token_z, workspace_id_z, workspace_token_z, "enable.json", payload) catch |err| return allocJsonEnvelopeFromError(err);
    defer allocator.free(raw);
    return rawCString(raw);
}

export fn spider_core_package_disable_json(
    url_z: [*:0]const u8,
    token_z: [*:0]const u8,
    workspace_id_z: [*:0]const u8,
    workspace_token_z: [*:0]const u8,
    package_id_z: [*:0]const u8,
) ?[*:0]u8 {
    const payload = buildIdPayload(std.mem.span(package_id_z), null) catch |err| return allocJsonEnvelopeFromError(err);
    defer allocator.free(payload);
    const raw = packageControlRaw(url_z, token_z, workspace_id_z, workspace_token_z, "disable.json", payload) catch |err| return allocJsonEnvelopeFromError(err);
    defer allocator.free(raw);
    return rawCString(raw);
}

export fn spider_core_terminal_exec_json(
    url_z: [*:0]const u8,
    token_z: [*:0]const u8,
    workspace_id_z: [*:0]const u8,
    workspace_token_z: [*:0]const u8,
    command_z: [*:0]const u8,
    cwd_z: [*:0]const u8,
) ?[*:0]u8 {
    const payload = buildTerminalExecPayload(std.mem.span(command_z), workspaceTokenFromZ(cwd_z)) catch |err| return allocJsonEnvelopeFromError(err);
    defer allocator.free(payload);
    const raw = terminalExecRaw(url_z, token_z, workspace_id_z, workspace_token_z, payload) catch |err| return allocJsonEnvelopeFromError(err);
    defer allocator.free(raw);
    return rawCString(raw);
}

export fn spider_core_workspace_info_json(
    url_z: [*:0]const u8,
    token_z: [*:0]const u8,
    workspace_id_z: [*:0]const u8,
) ?[*:0]u8 {
    var state = connectClient(url_z, token_z) catch |err| return allocJsonEnvelopeFromError(err);
    defer deinitConnectedClient(&state);

    var detail = control_plane.getWorkspace(
        allocator,
        &state.client,
        &state.message_counter,
        std.mem.span(workspace_id_z),
    ) catch |err| return allocJsonEnvelopeFromError(err);
    defer detail.deinit(allocator);

    var out = std.io.Writer.Allocating.init(allocator);
    errdefer out.deinit();
    var jw: std.json.Stringify = .{ .writer = &out.writer, .options = .{} };
    jw.beginObject() catch |err| return allocJsonEnvelopeFromError(err);
    jw.objectField("ok") catch |err| return allocJsonEnvelopeFromError(err);
    jw.write(true) catch |err| return allocJsonEnvelopeFromError(err);
    jw.objectField("workspace") catch |err| return allocJsonEnvelopeFromError(err);
    writeWorkspaceDetailJson(&jw, detail) catch |err| return allocJsonEnvelopeFromError(err);
    jw.endObject() catch |err| return allocJsonEnvelopeFromError(err);
    return out.toOwnedSliceSentinel(0) catch null;
}

export fn spider_core_workspace_create_json(
    url_z: [*:0]const u8,
    token_z: [*:0]const u8,
    name_z: [*:0]const u8,
) ?[*:0]u8 {
    var state = connectClient(url_z, token_z) catch |err| return allocJsonEnvelopeFromError(err);
    defer deinitConnectedClient(&state);

    var detail = control_plane.createWorkspace(
        allocator,
        &state.client,
        &state.message_counter,
        std.mem.span(name_z),
        null,
        null,
        std.mem.span(token_z),
    ) catch |err| return allocJsonEnvelopeFromError(err);
    defer detail.deinit(allocator);

    var out = std.io.Writer.Allocating.init(allocator);
    errdefer out.deinit();
    var jw: std.json.Stringify = .{ .writer = &out.writer, .options = .{} };
    jw.beginObject() catch |err| return allocJsonEnvelopeFromError(err);
    jw.objectField("ok") catch |err| return allocJsonEnvelopeFromError(err);
    jw.write(true) catch |err| return allocJsonEnvelopeFromError(err);
    jw.objectField("workspace") catch |err| return allocJsonEnvelopeFromError(err);
    writeWorkspaceDetailJson(&jw, detail) catch |err| return allocJsonEnvelopeFromError(err);
    jw.endObject() catch |err| return allocJsonEnvelopeFromError(err);
    return out.toOwnedSliceSentinel(0) catch null;
}

export fn spider_core_workspace_bind_set_json(
    url_z: [*:0]const u8,
    token_z: [*:0]const u8,
    workspace_id_z: [*:0]const u8,
    bind_path_z: [*:0]const u8,
    target_path_z: [*:0]const u8,
) ?[*:0]u8 {
    var state = connectClient(url_z, token_z) catch |err| return allocJsonEnvelopeFromError(err);
    defer deinitConnectedClient(&state);

    var detail = control_plane.setWorkspaceBind(
        allocator,
        &state.client,
        &state.message_counter,
        std.mem.span(workspace_id_z),
        null,
        std.mem.span(bind_path_z),
        std.mem.span(target_path_z),
    ) catch |err| return allocJsonEnvelopeFromError(err);
    defer detail.deinit(allocator);

    var out = std.io.Writer.Allocating.init(allocator);
    errdefer out.deinit();
    var jw: std.json.Stringify = .{ .writer = &out.writer, .options = .{} };
    jw.beginObject() catch |err| return allocJsonEnvelopeFromError(err);
    jw.objectField("ok") catch |err| return allocJsonEnvelopeFromError(err);
    jw.write(true) catch |err| return allocJsonEnvelopeFromError(err);
    jw.objectField("workspace") catch |err| return allocJsonEnvelopeFromError(err);
    writeWorkspaceDetailJson(&jw, detail) catch |err| return allocJsonEnvelopeFromError(err);
    jw.endObject() catch |err| return allocJsonEnvelopeFromError(err);
    return out.toOwnedSliceSentinel(0) catch null;
}

export fn spider_core_workspace_bind_remove_json(
    url_z: [*:0]const u8,
    token_z: [*:0]const u8,
    workspace_id_z: [*:0]const u8,
    bind_path_z: [*:0]const u8,
) ?[*:0]u8 {
    var state = connectClient(url_z, token_z) catch |err| return allocJsonEnvelopeFromError(err);
    defer deinitConnectedClient(&state);

    var detail = control_plane.removeWorkspaceBind(
        allocator,
        &state.client,
        &state.message_counter,
        std.mem.span(workspace_id_z),
        null,
        std.mem.span(bind_path_z),
    ) catch |err| return allocJsonEnvelopeFromError(err);
    defer detail.deinit(allocator);

    var out = std.io.Writer.Allocating.init(allocator);
    errdefer out.deinit();
    var jw: std.json.Stringify = .{ .writer = &out.writer, .options = .{} };
    jw.beginObject() catch |err| return allocJsonEnvelopeFromError(err);
    jw.objectField("ok") catch |err| return allocJsonEnvelopeFromError(err);
    jw.write(true) catch |err| return allocJsonEnvelopeFromError(err);
    jw.objectField("workspace") catch |err| return allocJsonEnvelopeFromError(err);
    writeWorkspaceDetailJson(&jw, detail) catch |err| return allocJsonEnvelopeFromError(err);
    jw.endObject() catch |err| return allocJsonEnvelopeFromError(err);
    return out.toOwnedSliceSentinel(0) catch null;
}

export fn spider_core_string_free(ptr: ?[*:0]u8) void {
    const value = ptr orelse return;
    const len = std.mem.len(value);
    allocator.free(value[0..len :0]);
}
