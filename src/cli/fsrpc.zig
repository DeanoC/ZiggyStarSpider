// FS-RPC helpers: Acheron protocol primitives for the CLI.
// Callers MUST call ensureUnifiedV2Control before calling fsrpcBootstrap.
// Import as:
//   const fsrpc = @import("fsrpc.zig");

const std = @import("std");
const logger = @import("ziggy-core").utils.logger;
const unified = @import("spider-protocol").unified;
const WebSocketClient = @import("../client/websocket.zig").WebSocketClient;

// ── FS-RPC global state ───────────────────────────────────────────────────────

var g_fsrpc_tag: u32 = 1;
var g_fsrpc_fid: u32 = 2;

pub const fsrpc_default_timeout_ms: i64 = 15_000;
pub const fsrpc_chat_write_timeout_ms: i64 = 180_000;

// ── Types ────────────────────────────────────────────────────────────────────

pub const JsonEnvelope = struct {
    raw: []const u8,
    parsed: std.json.Parsed(std.json.Value),

    pub fn deinit(self: *JsonEnvelope, allocator: std.mem.Allocator) void {
        self.parsed.deinit();
        allocator.free(self.raw);
        self.* = undefined;
    }
};

pub const FsrpcWriteResult = struct {
    written: u64,
    job: ?[]u8 = null,
    correlation_id: ?[]u8 = null,

    pub fn deinit(self: *FsrpcWriteResult, allocator: std.mem.Allocator) void {
        if (self.job) |value| allocator.free(value);
        if (self.correlation_id) |value| allocator.free(value);
        self.* = undefined;
    }
};

/// Adapter that lets venom_bindings.readPreferredVenomBinding use the CLI's FS-RPC transport.
pub const CliFsPathReader = struct {
    allocator: std.mem.Allocator,
    client: *WebSocketClient,

    pub fn readText(self: @This(), path: []const u8) ![]u8 {
        return fsrpcReadPathText(self.allocator, self.client, path);
    }
};

// ── Tag / FID counters ────────────────────────────────────────────────────────

pub fn nextFsrpcTag() u32 {
    const tag = g_fsrpc_tag;
    g_fsrpc_tag +%= 1;
    if (g_fsrpc_tag == 0) g_fsrpc_tag = 1;
    return tag;
}

pub fn nextFsrpcFid() u32 {
    const fid = g_fsrpc_fid;
    g_fsrpc_fid +%= 1;
    if (g_fsrpc_fid == 0 or g_fsrpc_fid == 1) g_fsrpc_fid = 2;
    return fid;
}

// ── High-level path helpers ───────────────────────────────────────────────────

pub fn fsrpcReadPathText(allocator: std.mem.Allocator, client: *WebSocketClient, path: []const u8) ![]u8 {
    const fid = try fsrpcWalkPath(allocator, client, path);
    defer fsrpcClunkBestEffort(allocator, client, fid);
    try fsrpcOpen(allocator, client, fid, "r");
    return fsrpcReadAllText(allocator, client, fid);
}

pub fn fsrpcWritePathText(allocator: std.mem.Allocator, client: *WebSocketClient, path: []const u8, content: []const u8) !void {
    const fid = try fsrpcWalkPath(allocator, client, path);
    defer fsrpcClunkBestEffort(allocator, client, fid);
    try fsrpcOpen(allocator, client, fid, "rw");
    var write = try fsrpcWriteText(allocator, client, fid, content, null);
    defer write.deinit(allocator);
}

// ── Bootstrap ────────────────────────────────────────────────────────────────

/// Bootstrap the Acheron FS-RPC session.
/// Caller MUST have already called ensureUnifiedV2Control on the client.
pub fn fsrpcBootstrap(allocator: std.mem.Allocator, client: *WebSocketClient) !void {
    const version_tag = nextFsrpcTag();
    const version_req = try std.fmt.allocPrint(
        allocator,
        "{{\"channel\":\"acheron\",\"type\":\"acheron.t_version\",\"tag\":{d},\"msize\":1048576,\"version\":\"acheron-1\"}}",
        .{version_tag},
    );
    defer allocator.free(version_req);
    var version = try sendAndAwaitFsrpcWithTimeout(allocator, client, version_req, version_tag, fsrpc_default_timeout_ms);
    defer version.deinit(allocator);
    try ensureFsrpcOk(&version);

    const attach_tag = nextFsrpcTag();
    const attach_req = try std.fmt.allocPrint(
        allocator,
        "{{\"channel\":\"acheron\",\"type\":\"acheron.t_attach\",\"tag\":{d},\"fid\":1}}",
        .{attach_tag},
    );
    defer allocator.free(attach_req);
    var attach = try sendAndAwaitFsrpcWithTimeout(allocator, client, attach_req, attach_tag, fsrpc_default_timeout_ms);
    defer attach.deinit(allocator);
    try ensureFsrpcOk(&attach);
}

// ── Core operations ───────────────────────────────────────────────────────────

pub fn fsrpcWalkPath(allocator: std.mem.Allocator, client: *WebSocketClient, path: []const u8) !u32 {
    const segments = try splitPathSegments(allocator, path);
    defer freeSegments(allocator, segments);

    const path_json = try buildPathArrayJson(allocator, segments);
    defer allocator.free(path_json);

    const new_fid = nextFsrpcFid();
    const tag = nextFsrpcTag();
    const req = try std.fmt.allocPrint(
        allocator,
        "{{\"channel\":\"acheron\",\"type\":\"acheron.t_walk\",\"tag\":{d},\"fid\":1,\"newfid\":{d},\"path\":{s}}}",
        .{ tag, new_fid, path_json },
    );
    defer allocator.free(req);

    var response = try sendAndAwaitFsrpcWithTimeout(allocator, client, req, tag, fsrpc_default_timeout_ms);
    defer response.deinit(allocator);
    try ensureFsrpcOk(&response);
    return new_fid;
}

pub fn fsrpcOpen(allocator: std.mem.Allocator, client: *WebSocketClient, fid: u32, mode: []const u8) !void {
    const escaped_mode = try unified.jsonEscape(allocator, mode);
    defer allocator.free(escaped_mode);

    const tag = nextFsrpcTag();
    const req = try std.fmt.allocPrint(
        allocator,
        "{{\"channel\":\"acheron\",\"type\":\"acheron.t_open\",\"tag\":{d},\"fid\":{d},\"mode\":\"{s}\"}}",
        .{ tag, fid, escaped_mode },
    );
    defer allocator.free(req);

    var response = try sendAndAwaitFsrpcWithTimeout(allocator, client, req, tag, fsrpc_default_timeout_ms);
    defer response.deinit(allocator);
    try ensureFsrpcOk(&response);
}

pub fn fsrpcReadAllText(allocator: std.mem.Allocator, client: *WebSocketClient, fid: u32) ![]u8 {
    const tag = nextFsrpcTag();
    const req = try std.fmt.allocPrint(
        allocator,
        "{{\"channel\":\"acheron\",\"type\":\"acheron.t_read\",\"tag\":{d},\"fid\":{d},\"offset\":0,\"count\":1048576}}",
        .{ tag, fid },
    );
    defer allocator.free(req);

    var response = try sendAndAwaitFsrpcWithTimeout(allocator, client, req, tag, fsrpc_default_timeout_ms);
    defer response.deinit(allocator);
    try ensureFsrpcOk(&response);

    const payload = try getPayloadObject(response.parsed.value.object);
    const data_b64 = payload.get("data_b64") orelse return error.InvalidResponse;
    if (data_b64 != .string) return error.InvalidResponse;

    const decoded_len = try std.base64.standard.Decoder.calcSizeForSlice(data_b64.string);
    const decoded = try allocator.alloc(u8, decoded_len);
    _ = std.base64.standard.Decoder.decode(decoded, data_b64.string) catch {
        allocator.free(decoded);
        return error.InvalidResponse;
    };
    return decoded;
}

pub fn fsrpcWriteText(
    allocator: std.mem.Allocator,
    client: *WebSocketClient,
    fid: u32,
    content: []const u8,
    correlation_id: ?[]const u8,
) !FsrpcWriteResult {
    const encoded = try unified.encodeDataB64(allocator, content);
    defer allocator.free(encoded);

    const tag = nextFsrpcTag();
    const req = if (correlation_id) |value| blk: {
        const escaped = try unified.jsonEscape(allocator, value);
        defer allocator.free(escaped);
        break :blk try std.fmt.allocPrint(
            allocator,
            "{{\"channel\":\"acheron\",\"type\":\"acheron.t_write\",\"tag\":{d},\"fid\":{d},\"offset\":0,\"data_b64\":\"{s}\",\"correlation_id\":\"{s}\"}}",
            .{ tag, fid, encoded, escaped },
        );
    } else try std.fmt.allocPrint(
        allocator,
        "{{\"channel\":\"acheron\",\"type\":\"acheron.t_write\",\"tag\":{d},\"fid\":{d},\"offset\":0,\"data_b64\":\"{s}\"}}",
        .{ tag, fid, encoded },
    );
    defer allocator.free(req);

    var response = try sendAndAwaitFsrpcWithTimeout(allocator, client, req, tag, fsrpc_chat_write_timeout_ms);
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
    var response_correlation_id: ?[]u8 = null;
    if (payload.get("correlation_id")) |corr_val| {
        if (corr_val != .string) return error.InvalidResponse;
        response_correlation_id = try allocator.dupe(u8, corr_val.string);
    }

    return .{
        .written = @intCast(n.integer),
        .job = job,
        .correlation_id = response_correlation_id,
    };
}

pub fn fsrpcStatRaw(allocator: std.mem.Allocator, client: *WebSocketClient, fid: u32) ![]u8 {
    const tag = nextFsrpcTag();
    const req = try std.fmt.allocPrint(
        allocator,
        "{{\"channel\":\"acheron\",\"type\":\"acheron.t_stat\",\"tag\":{d},\"fid\":{d}}}",
        .{ tag, fid },
    );
    defer allocator.free(req);

    var response = try sendAndAwaitFsrpcWithTimeout(allocator, client, req, tag, fsrpc_default_timeout_ms);
    defer response.deinit(allocator);
    try ensureFsrpcOk(&response);

    const payload = try getPayloadObject(response.parsed.value.object);
    const stat = payload.get("stat") orelse return error.InvalidResponse;
    if (stat != .object) return error.InvalidResponse;

    return try std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(stat, .{})});
}

pub fn fsrpcClunkBestEffort(allocator: std.mem.Allocator, client: *WebSocketClient, fid: u32) void {
    const tag = nextFsrpcTag();
    const req = std.fmt.allocPrint(
        allocator,
        "{{\"channel\":\"acheron\",\"type\":\"acheron.t_clunk\",\"tag\":{d},\"fid\":{d}}}",
        .{ tag, fid },
    ) catch return;
    defer allocator.free(req);

    var response = sendAndAwaitFsrpcWithTimeout(allocator, client, req, tag, fsrpc_default_timeout_ms) catch return;
    response.deinit(allocator);
}

pub fn fsrpcFidIsDir(allocator: std.mem.Allocator, client: *WebSocketClient, fid: u32) !bool {
    const stat_json = try fsrpcStatRaw(allocator, client, fid);
    defer allocator.free(stat_json);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, stat_json, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidResponse;
    const kind = parsed.value.object.get("kind") orelse return error.InvalidResponse;
    if (kind != .string) return error.InvalidResponse;
    return std.mem.eql(u8, kind.string, "dir");
}

// ── Transport ─────────────────────────────────────────────────────────────────

pub fn sendAndAwaitFsrpc(allocator: std.mem.Allocator, client: *WebSocketClient, request_json: []const u8, tag: u32) !JsonEnvelope {
    return sendAndAwaitFsrpcWithTimeout(allocator, client, request_json, tag, fsrpc_default_timeout_ms);
}

pub fn sendAndAwaitFsrpcWithTimeout(
    allocator: std.mem.Allocator,
    client: *WebSocketClient,
    request_json: []const u8,
    tag: u32,
    timeout_ms: i64,
) !JsonEnvelope {
    try client.send(request_json);

    const started = std.time.milliTimestamp();
    while (std.time.milliTimestamp() - started < timeout_ms) {
        const maybe_raw = client.readTimeout(2_000) catch |err| {
            if (err == error.Closed or err == error.BrokenPipe or err == error.ConnectionResetByPeer or err == error.EndOfStream) {
                logger.err("Connection closed while waiting for FS-RPC response", .{});
            }
            return err;
        };
        if (maybe_raw) |raw| {
            const parsed = std.json.parseFromSlice(std.json.Value, allocator, raw, .{}) catch {
                allocator.free(raw);
                continue;
            };

            var matched = false;
            if (parsed.value == .object) {
                const obj = parsed.value.object;
                if (obj.get("channel")) |channel| {
                    if (channel == .string and std.mem.eql(u8, channel.string, "acheron")) {
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
    const msg_type = if (root.get("type")) |t|
        if (t == .string) t.string else "unknown"
    else
        "unknown";
    if (std.mem.startsWith(u8, msg_type, "control.")) {
        const message = if (root.get("message")) |m|
            if (m == .string) m.string else msg_type
        else
            msg_type;
        logger.warn("Control error while awaiting FS-RPC response: {s}", .{message});
    }
}

pub fn ensureFsrpcOk(envelope: *JsonEnvelope) !void {
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

pub fn getPayloadObject(root: std.json.ObjectMap) !std.json.ObjectMap {
    const payload = root.get("payload") orelse return error.InvalidResponse;
    if (payload != .object) return error.InvalidResponse;
    return payload.object;
}

// ── Path utilities ────────────────────────────────────────────────────────────

pub fn joinFsPath(allocator: std.mem.Allocator, parent: []const u8, child: []const u8) ![]u8 {
    if (std.mem.eql(u8, parent, "/")) {
        return std.fmt.allocPrint(allocator, "/{s}", .{child});
    }
    if (std.mem.endsWith(u8, parent, "/")) {
        return std.fmt.allocPrint(allocator, "{s}{s}", .{ parent, child });
    }
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ parent, child });
}

pub fn splitPathSegments(allocator: std.mem.Allocator, path: []const u8) ![][]u8 {
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

pub fn freeSegments(allocator: std.mem.Allocator, segments: [][]u8) void {
    for (segments) |segment| allocator.free(segment);
    if (segments.len > 0) allocator.free(segments);
}

pub fn buildPathArrayJson(allocator: std.mem.Allocator, segments: [][]u8) ![]u8 {
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
