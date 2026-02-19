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
    if (context) |ctx| {
        return std.fmt.allocPrint(
            allocator,
            "{{\"type\":\"session.send\",\"id\":\"{s}\",\"timestamp\":{d},\"content\":\"{s}\",\"session_key\":\"{s}\"}}",
            .{ id, std.time.milliTimestamp(), content, ctx },
        );
    }

    return std.fmt.allocPrint(
        allocator,
        "{{\"type\":\"session.send\",\"id\":\"{s}\",\"timestamp\":{d},\"content\":\"{s}\"}}",
        .{ id, std.time.milliTimestamp(), content },
    );
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
    if (content) |value| {
        return std.fmt.allocPrint(
            allocator,
            "{{\"type\":\"agent.control\",\"id\":\"{s}\",\"action\":\"{s}\",\"content\":\"{s}\",\"timestamp\":{d}}}",
            .{ id, action, value, std.time.milliTimestamp() },
        );
    }
    return std.fmt.allocPrint(
        allocator,
        "{{\"type\":\"agent.control\",\"id\":\"{s}\",\"action\":\"{s}\",\"timestamp\":{d}}}",
        .{ id, action, std.time.milliTimestamp() },
    );
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

test "protocol_messages: buildAgentControl emits action envelope" {
    const allocator = std.testing.allocator;
    const payload = try buildAgentControl(allocator, "req-1", "debug.subscribe", null);
    defer allocator.free(payload);

    try std.testing.expect(std.mem.indexOf(u8, payload, "\"type\":\"agent.control\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"action\":\"debug.subscribe\"") != null);
}
