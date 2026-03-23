const std = @import("std");

pub const default_control_timeout_ms: i64 = 15_000;

pub const JsonEnvelope = struct {
    raw: []u8,
    parsed: std.json.Parsed(std.json.Value),

    pub fn deinit(self: *JsonEnvelope, allocator: std.mem.Allocator) void {
        self.parsed.deinit();
        allocator.free(self.raw);
        self.* = undefined;
    }
};

const MAX_REMOTE_ERROR_LEN: usize = 512;
threadlocal var last_remote_error_len: usize = 0;
threadlocal var last_remote_error_buf: [MAX_REMOTE_ERROR_LEN]u8 = [_]u8{0} ** MAX_REMOTE_ERROR_LEN;

pub fn clearLastRemoteError() void {
    last_remote_error_len = 0;
}

pub fn lastRemoteError() ?[]const u8 {
    if (last_remote_error_len == 0) return null;
    return last_remote_error_buf[0..last_remote_error_len];
}

fn setLastRemoteError(message: []const u8) void {
    if (message.len == 0) {
        clearLastRemoteError();
        return;
    }
    const len = @min(message.len, MAX_REMOTE_ERROR_LEN);
    @memcpy(last_remote_error_buf[0..len], message[0..len]);
    last_remote_error_len = len;
}

fn controlErrorMessageFromRoot(root: std.json.ObjectMap) ?[]const u8 {
    if (root.get("error")) |error_value| {
        if (error_value == .object) {
            if (error_value.object.get("message")) |message| {
                if (message == .string and message.string.len > 0) return message.string;
            }
        } else if (error_value == .string and error_value.string.len > 0) {
            return error_value.string;
        }
    }
    if (root.get("payload")) |payload_value| {
        if (payload_value == .object) {
            if (payload_value.object.get("message")) |message| {
                if (message == .string and message.string.len > 0) return message.string;
            }
        }
    }
    return null;
}

fn controlErrorCodeFromRoot(root: std.json.ObjectMap) ?[]const u8 {
    if (root.get("error")) |error_value| {
        if (error_value == .object) {
            if (error_value.object.get("code")) |code| {
                if (code == .string and code.string.len > 0) return code.string;
            }
        }
    }
    if (root.get("payload")) |payload_value| {
        if (payload_value == .object) {
            if (payload_value.object.get("code")) |code| {
                if (code == .string and code.string.len > 0) return code.string;
            }
        }
    }
    return null;
}

fn appendGuiDiagnosticLogFmt(comptime fmt: []const u8, args: anytype) void {
    const allocator = std.heap.page_allocator;
    const line = std.fmt.allocPrint(allocator, fmt, args) catch return;
    defer allocator.free(line);
    appendGuiDiagnosticLog(line);
}

fn appendGuiDiagnosticLog(line: []const u8) void {
    const allocator = std.heap.page_allocator;
    const home = std.process.getEnvVarOwned(allocator, "HOME") catch return;
    defer allocator.free(home);

    const log_dir = std.fmt.allocPrint(allocator, "{s}/Library/Logs/SpiderApp", .{home}) catch return;
    defer allocator.free(log_dir);
    std.fs.makeDirAbsolute(log_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return,
    };

    const log_path = std.fmt.allocPrint(allocator, "{s}/gui.log", .{log_dir}) catch return;
    defer allocator.free(log_path);

    const file = std.fs.openFileAbsolute(log_path, .{ .mode = .read_write }) catch |err| switch (err) {
        error.FileNotFound => std.fs.createFileAbsolute(log_path, .{}) catch return,
        else => return,
    };
    defer file.close();

    file.seekFromEnd(0) catch return;
    const payload = std.fmt.allocPrint(allocator, "[{d}] {s}\n", .{ std.time.timestamp(), line }) catch return;
    defer allocator.free(payload);
    _ = file.writeAll(payload) catch return;
}

pub fn sendControlVersionAndConnect(
    allocator: std.mem.Allocator,
    client: anytype,
    message_counter: *u64,
    timeout_ms: i64,
) !void {
    const payload_json = try sendControlVersionAndConnectPayloadJson(
        allocator,
        client,
        message_counter,
        timeout_ms,
    );
    allocator.free(payload_json);
}

pub fn sendControlVersionAndConnectPayloadJson(
    allocator: std.mem.Allocator,
    client: anytype,
    message_counter: *u64,
    timeout_ms: i64,
) ![]u8 {
    const version_id = try nextRequestId(allocator, message_counter, "control-version");
    defer allocator.free(version_id);
    std.log.info("[control] sending control.version id={s}", .{version_id});
    appendGuiDiagnosticLogFmt("[control] sending control.version id={s}", .{version_id});
    var version = try sendControlRequest(
        allocator,
        client,
        "control.version",
        version_id,
        "{\"protocol\":\"spiderweb-control\"}",
        timeout_ms,
    );
    defer version.deinit(allocator);
    std.log.info("[control] received {s} id={s}", .{ controlReplyType(&version) orelse "<unknown>", version_id });
    appendGuiDiagnosticLogFmt("[control] received {s} id={s}", .{ controlReplyType(&version) orelse "<unknown>", version_id });

    const connect_id = try nextRequestId(allocator, message_counter, "control-connect");
    defer allocator.free(connect_id);
    std.log.info("[control] sending control.connect id={s}", .{connect_id});
    appendGuiDiagnosticLogFmt("[control] sending control.connect id={s}", .{connect_id});
    var connect = try sendControlRequest(
        allocator,
        client,
        "control.connect",
        connect_id,
        null,
        timeout_ms,
    );
    defer connect.deinit(allocator);
    std.log.info("[control] received {s} id={s}", .{ controlReplyType(&connect) orelse "<unknown>", connect_id });
    appendGuiDiagnosticLogFmt("[control] received {s} id={s}", .{ controlReplyType(&connect) orelse "<unknown>", connect_id });

    return controlReplyPayloadJson(allocator, &connect);
}

pub fn sendControlRequest(
    allocator: std.mem.Allocator,
    client: anytype,
    control_type: []const u8,
    request_id: []const u8,
    payload_json: ?[]const u8,
    timeout_ms: i64,
) !JsonEnvelope {
    clearLastRemoteError();
    const request_json = try buildControlRequestJson(allocator, control_type, request_id, payload_json);
    defer allocator.free(request_json);

    try sendClientFrame(client, request_json);

    const expected_type = expectedAckType(control_type);
    return awaitControlReply(allocator, client, request_id, expected_type, timeout_ms);
}

pub fn extractPayloadObject(envelope: *const JsonEnvelope) !std.json.ObjectMap {
    if (envelope.parsed.value != .object) return error.InvalidResponse;
    const payload = envelope.parsed.value.object.get("payload") orelse return error.InvalidResponse;
    if (payload != .object) return error.InvalidResponse;
    return payload.object;
}

pub fn controlReplyType(envelope: *const JsonEnvelope) ?[]const u8 {
    if (envelope.parsed.value != .object) return null;
    const typ = envelope.parsed.value.object.get("type") orelse return null;
    if (typ != .string) return null;
    return typ.string;
}

pub fn controlReplyPayloadJson(allocator: std.mem.Allocator, envelope: *const JsonEnvelope) ![]u8 {
    if (envelope.parsed.value != .object) return error.InvalidResponse;
    const payload = envelope.parsed.value.object.get("payload") orelse return allocator.dupe(u8, "{}");
    var out = std.ArrayListUnmanaged(u8){};
    defer out.deinit(allocator);
    const formatter = std.json.fmt(payload, .{ .whitespace = .indent_2 });
    try std.fmt.format(out.writer(allocator), "{f}", .{formatter});
    return out.toOwnedSlice(allocator);
}

pub fn responseErrorMessage(envelope: *const JsonEnvelope) ?[]const u8 {
    if (envelope.parsed.value != .object) return null;
    const root = envelope.parsed.value.object;
    const error_value = root.get("error") orelse return null;
    if (error_value == .object) {
        const message = error_value.object.get("message") orelse return null;
        if (message == .string) return message.string;
    }
    if (error_value == .string) return error_value.string;
    return null;
}

pub fn nextRequestId(allocator: std.mem.Allocator, counter: *u64, prefix: []const u8) ![]u8 {
    counter.* += 1;
    return std.fmt.allocPrint(allocator, "{s}-{d}", .{ prefix, counter.* });
}

fn buildControlRequestJson(
    allocator: std.mem.Allocator,
    control_type: []const u8,
    request_id: []const u8,
    payload_json: ?[]const u8,
) ![]u8 {
    const escaped_type = try jsonEscape(allocator, control_type);
    defer allocator.free(escaped_type);
    const escaped_id = try jsonEscape(allocator, request_id);
    defer allocator.free(escaped_id);

    if (payload_json) |payload| {
        return std.fmt.allocPrint(
            allocator,
            "{{\"channel\":\"control\",\"type\":\"{s}\",\"id\":\"{s}\",\"payload\":{s}}}",
            .{ escaped_type, escaped_id, payload },
        );
    }

    return std.fmt.allocPrint(
        allocator,
        "{{\"channel\":\"control\",\"type\":\"{s}\",\"id\":\"{s}\"}}",
        .{ escaped_type, escaped_id },
    );
}

fn expectedAckType(control_type: []const u8) []const u8 {
    if (std.mem.eql(u8, control_type, "control.version")) return "control.version_ack";
    if (std.mem.eql(u8, control_type, "control.connect")) return "control.connect_ack";
    if (std.mem.eql(u8, control_type, "control.ping")) return "control.pong";
    return control_type;
}

fn awaitControlReply(
    allocator: std.mem.Allocator,
    client: anytype,
    request_id: []const u8,
    expected_type: []const u8,
    timeout_ms: i64,
) !JsonEnvelope {
    const client_type = @TypeOf(client.*);
    if (comptime @hasDecl(client_type, "awaitControlFrame")) {
        if (try client.awaitControlFrame(request_id, @intCast(@max(timeout_ms, 0)))) |raw| {
            const parsed = std.json.parseFromSlice(std.json.Value, allocator, raw, .{}) catch {
                allocator.free(raw);
                return error.InvalidResponse;
            };
            errdefer {
                parsed.deinit();
                allocator.free(raw);
            }

            if (parsed.value != .object) return error.InvalidResponse;
            const obj = parsed.value.object;
            if (matchesControlReply(obj, request_id, expected_type)) {
                clearLastRemoteError();
                return .{ .raw = raw, .parsed = parsed };
            }
            if (matchesControlReplyType(obj, request_id, "control.error")) {
                const message = controlErrorMessageFromRoot(obj);
                const code = controlErrorCodeFromRoot(obj);
                if (message != null and code != null) {
                    var detail_buf: [MAX_REMOTE_ERROR_LEN]u8 = undefined;
                    const detail = std.fmt.bufPrint(&detail_buf, "{s} [{s}]", .{ message.?, code.? }) catch message.?;
                    setLastRemoteError(detail);
                } else if (message) |value| {
                    setLastRemoteError(value);
                } else if (code) |value| {
                    setLastRemoteError(value);
                } else {
                    setLastRemoteError("remote control error");
                }
                return error.RemoteError;
            }
            return error.InvalidResponse;
        }
        return error.Timeout;
    }

    const started = std.time.milliTimestamp();
    while (std.time.milliTimestamp() - started < timeout_ms) {
        if (try readClientFrameWithTimeout(client, 250)) |raw| {
            const parsed = std.json.parseFromSlice(std.json.Value, allocator, raw, .{}) catch {
                allocator.free(raw);
                continue;
            };

            if (parsed.value == .object) {
                const obj = parsed.value.object;
                if (matchesControlReply(obj, request_id, expected_type)) {
                    clearLastRemoteError();
                    return .{ .raw = raw, .parsed = parsed };
                }

                if (matchesControlReplyType(obj, request_id, "control.error")) {
                    const message = controlErrorMessageFromRoot(obj);
                    const code = controlErrorCodeFromRoot(obj);
                    if (message != null and code != null) {
                        var detail_buf: [MAX_REMOTE_ERROR_LEN]u8 = undefined;
                        const detail = std.fmt.bufPrint(&detail_buf, "{s} [{s}]", .{ message.?, code.? }) catch message.?;
                        setLastRemoteError(detail);
                    } else if (message) |value| {
                        setLastRemoteError(value);
                    } else if (code) |value| {
                        setLastRemoteError(value);
                    } else {
                        setLastRemoteError("remote control error");
                    }
                    parsed.deinit();
                    allocator.free(raw);
                    return error.RemoteError;
                }

            }

            parsed.deinit();
            allocator.free(raw);
        }
    }

    return error.Timeout;
}

fn matchesControlReply(root: std.json.ObjectMap, request_id: []const u8, expected_type: []const u8) bool {
    return matchesControlReplyType(root, request_id, expected_type);
}

fn matchesControlReplyType(root: std.json.ObjectMap, request_id: []const u8, expected_type: []const u8) bool {
    const channel = root.get("channel") orelse return false;
    if (channel != .string or !std.mem.eql(u8, channel.string, "control")) return false;

    const typ = root.get("type") orelse return false;
    if (typ != .string or !std.mem.eql(u8, typ.string, expected_type)) return false;

    const id = root.get("id") orelse return false;
    if (id != .string or !std.mem.eql(u8, id.string, request_id)) return false;
    return true;
}

fn sendClientFrame(client: anytype, payload: []const u8) !void {
    return client.send(payload);
}

fn readClientFrameWithTimeout(client: anytype, timeout_ms: u32) !?[]u8 {
    const client_type = @TypeOf(client.*);
    if (comptime @hasDecl(client_type, "receive")) {
        const result = client.receive(timeout_ms);
        if (result) |raw| return raw;
        if (comptime @hasDecl(client_type, "isAlive")) {
            if (!client.isAlive()) return error.ConnectionClosed;
        }
        return null;
    }

    if (comptime @hasDecl(client_type, "readTimeout")) {
        const result = try client.readTimeout(timeout_ms);
        return if (result) |value| @constCast(value) else null;
    }

    if (comptime @hasDecl(client_type, "read")) {
        const started = std.time.milliTimestamp();
        while (std.time.milliTimestamp() - started < @as(i64, @intCast(timeout_ms))) {
            const maybe = client.read() catch |err| switch (err) {
                error.WouldBlock => {
                    std.Thread.sleep(5 * std.time.ns_per_ms);
                    continue;
                },
                else => return err,
            };
            if (maybe) |raw| {
                return @constCast(raw);
            }
        }
        return null;
    }

    @compileError("Unsupported websocket client type for unified_v2_client");
}

pub fn jsonEscape(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var out = std.ArrayListUnmanaged(u8){};
    defer out.deinit(allocator);

    for (input) |char| {
        switch (char) {
            '\\' => try out.appendSlice(allocator, "\\\\"),
            '"' => try out.appendSlice(allocator, "\\\""),
            '\n' => try out.appendSlice(allocator, "\\n"),
            '\r' => try out.appendSlice(allocator, "\\r"),
            '\t' => try out.appendSlice(allocator, "\\t"),
            else => {
                if (char < 0x20) {
                    try out.writer(allocator).print("\\u00{x:0>2}", .{char});
                } else {
                    try out.append(allocator, char);
                }
            },
        }
    }

    return out.toOwnedSlice(allocator);
}
