const std = @import("std");

pub const MessageType = enum {
    session_send,
    session_receive,
    connect_ack,
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
    if (std.mem.eql(u8, type_str, "session.ack")) return .connect_ack; // legacy
    if (std.mem.eql(u8, type_str, "chat_ack")) return .connect_ack; // legacy
    if (std.mem.eql(u8, type_str, "error")) return .error_response;
    return .other;
}
