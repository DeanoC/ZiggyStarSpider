const std = @import("std");

pub const MessageType = enum {
    chat_send,
    chat_receive,
    chat_ack,
    error_response,
    other,
};

pub fn buildChatSend(allocator: std.mem.Allocator, id: []const u8, content: []const u8, context: ?[]const u8) ![]const u8 {
    if (context) |ctx| {
        return std.fmt.allocPrint(allocator,
            "{{\"type\":\"chat.send\",\"id\":\"{s}\",\"timestamp\":{d},\"content\":\"{s}\",\"context\":\"{s}\"}}",
            .{ id, std.time.milliTimestamp(), content, ctx },
        );
    }

    return std.fmt.allocPrint(
        allocator,
        "{{\"type\":\"chat.send\",\"id\":\"{s}\",\"timestamp\":{d},\"content\":\"{s}\"}}",
        .{ id, std.time.milliTimestamp(), content },
    );
}

pub fn parseMessageType(json: []const u8) ?MessageType {
    const type_prefix = "\"type\":\"";

    const start = std.mem.indexOf(u8, json, type_prefix) orelse return null;
    const type_start = start + type_prefix.len;
    const end = std.mem.indexOfScalarPos(u8, json, type_start, '"') orelse return null;
    const type_str = json[type_start..end];

    if (std.mem.eql(u8, type_str, "chat.send")) return .chat_send;
    if (std.mem.eql(u8, type_str, "chat.receive")) return .chat_receive;
    if (std.mem.eql(u8, type_str, "session.receive")) return .chat_receive;
    if (std.mem.eql(u8, type_str, "chat_ack")) return .chat_ack;
    if (std.mem.eql(u8, type_str, "session.ack")) return .chat_ack;
    if (std.mem.eql(u8, type_str, "error")) return .error_response;
    return .other;
}
