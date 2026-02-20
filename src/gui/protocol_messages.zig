const std = @import("std");

pub const MessageType = enum {
    session_send,
    session_receive,
    connect_ack,
    debug_event,
    error_response,
    other,
};

pub fn buildSessionSend(allocator: std.mem.Allocator, id: []const u8, content: []const u8, context: ?[]const u8) ![]const u8 {
    var buffer = std.ArrayListUnmanaged(u8).empty;
    defer buffer.deinit(allocator);

    if (context) |ctx| {
        const SessionSendWithContext = struct {
            type: []const u8 = "session.send",
            id: []const u8,
            timestamp: i64,
            content: []const u8,
            session_key: []const u8,
        };

        const payload = SessionSendWithContext{
            .id = id,
            .timestamp = std.time.milliTimestamp(),
            .content = content,
            .session_key = ctx,
        };

        const formatter = std.json.fmt(payload, .{});
        try std.fmt.format(buffer.writer(allocator), "{f}", .{formatter});
    } else {
        const SessionSend = struct {
            type: []const u8 = "session.send",
            id: []const u8,
            timestamp: i64,
            content: []const u8,
        };

        const payload = SessionSend{
            .id = id,
            .timestamp = std.time.milliTimestamp(),
            .content = content,
        };

        const formatter = std.json.fmt(payload, .{});
        try std.fmt.format(buffer.writer(allocator), "{f}", .{formatter});
    }

    return try allocator.dupe(u8, buffer.items);
}

pub const buildChatSend = buildSessionSend;

pub fn buildConnect(allocator: std.mem.Allocator, id: []const u8) ![]const u8 {
    return std.fmt.allocPrint(
        allocator,
        "{{\"type\":\"connect\",\"id\":\"{s}\",\"timestamp\":{d}}}",
        .{ id, std.time.milliTimestamp() },
    );
}

pub fn buildAgentControl(
    allocator: std.mem.Allocator,
    id: []const u8,
    action: []const u8,
    content: ?[]const u8,
) ![]const u8 {
    var buffer = std.ArrayListUnmanaged(u8).empty;
    defer buffer.deinit(allocator);

    if (content) |value| {
        const AgentControlWithContent = struct {
            type: []const u8 = "agent.control",
            id: []const u8,
            action: []const u8,
            content: []const u8,
            timestamp: i64,
        };

        const payload = AgentControlWithContent{
            .id = id,
            .action = action,
            .content = value,
            .timestamp = std.time.milliTimestamp(),
        };

        const formatter = std.json.fmt(payload, .{});
        try std.fmt.format(buffer.writer(allocator), "{f}", .{formatter});
    } else {
        const AgentControl = struct {
            type: []const u8 = "agent.control",
            id: []const u8,
            action: []const u8,
            timestamp: i64,
        };

        const payload = AgentControl{
            .id = id,
            .action = action,
            .timestamp = std.time.milliTimestamp(),
        };

        const formatter = std.json.fmt(payload, .{});
        try std.fmt.format(buffer.writer(allocator), "{f}", .{formatter});
    }

    return try allocator.dupe(u8, buffer.items);
}

pub fn parseMessageType(json: []const u8) ?MessageType {
    const type_prefix = "\"type\":\"";

    const start = std.mem.indexOf(u8, json, type_prefix) orelse return null;
    const type_start = start + type_prefix.len;
    const end = std.mem.indexOfScalarPos(u8, json, type_start, '"') orelse return null;
    const type_str = json[type_start..end];

    if (std.mem.eql(u8, type_str, "session.send")) return .session_send;
    if (std.mem.eql(u8, type_str, "chat.send")) return .session_send; // legacy
    if (std.mem.eql(u8, type_str, "session.receive")) return .session_receive;
    if (std.mem.eql(u8, type_str, "chat.receive")) return .session_receive; // legacy
    if (std.mem.eql(u8, type_str, "connect.ack")) return .connect_ack;
    if (std.mem.eql(u8, type_str, "debug.event")) return .debug_event;
    if (std.mem.eql(u8, type_str, "session.ack")) return .connect_ack; // legacy
    if (std.mem.eql(u8, type_str, "chat_ack")) return .connect_ack; // legacy
    if (std.mem.eql(u8, type_str, "error")) return .error_response;
    return .other;
}

test "protocol_messages: parseMessageType recognizes debug.event" {
    try std.testing.expectEqual(MessageType.debug_event, parseMessageType("{\"type\":\"debug.event\"}").?);
}

test "protocol_messages: buildSessionSend escapes mixed text and JSON safely" {
    const allocator = std.testing.allocator;
    const input = "hello {\"a\":1}\nline2 \"quoted\"";
    const payload = try buildSessionSend(allocator, "req-1", input, "main");
    defer allocator.free(payload);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .object);
    const obj = parsed.value.object;

    try std.testing.expectEqualStrings("session.send", obj.get("type").?.string);
    try std.testing.expectEqualStrings("req-1", obj.get("id").?.string);
    try std.testing.expectEqualStrings(input, obj.get("content").?.string);
    try std.testing.expectEqualStrings("main", obj.get("session_key").?.string);
}

test "protocol_messages: buildAgentControl emits action envelope" {
    const allocator = std.testing.allocator;
    const payload = try buildAgentControl(allocator, "req-1", "debug.subscribe", null);
    defer allocator.free(payload);

    try std.testing.expect(std.mem.indexOf(u8, payload, "\"type\":\"agent.control\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"action\":\"debug.subscribe\"") != null);
}

test "protocol_messages: buildAgentControl escapes content safely" {
    const allocator = std.testing.allocator;
    const content = "{\"foo\":\"bar\"}\nnext line";
    const payload = try buildAgentControl(allocator, "req-2", "state", content);
    defer allocator.free(payload);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .object);
    const obj = parsed.value.object;

    try std.testing.expectEqualStrings("agent.control", obj.get("type").?.string);
    try std.testing.expectEqualStrings("state", obj.get("action").?.string);
    try std.testing.expectEqualStrings(content, obj.get("content").?.string);
}
