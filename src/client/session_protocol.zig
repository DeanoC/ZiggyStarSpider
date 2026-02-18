const std = @import("std");

pub fn buildSessionSendJson(
    allocator: std.mem.Allocator,
    session_key: ?[]const u8,
    content: []const u8,
) ![]u8 {
    var buffer = std.ArrayListUnmanaged(u8).empty;
    defer buffer.deinit(allocator);

    if (session_key) |key| {
        const MessagePayloadWithSession = struct {
            type: []const u8 = "session.send",
            session_key: []const u8,
            content: []const u8,
        };
        const payload = MessagePayloadWithSession{
            .session_key = key,
            .content = content,
        };
        const formatter = std.json.fmt(payload, .{});
        try std.fmt.format(buffer.writer(allocator), "{f}", .{formatter});
    } else {
        const MessagePayload = struct {
            type: []const u8 = "session.send",
            content: []const u8,
        };
        const payload = MessagePayload{
            .content = content,
        };
        const formatter = std.json.fmt(payload, .{});
        try std.fmt.format(buffer.writer(allocator), "{f}", .{formatter});
    }

    return try allocator.dupe(u8, buffer.items);
}

test "session_protocol: buildSessionSendJson emits current session.send envelope" {
    const allocator = std.testing.allocator;

    const payload = try buildSessionSendJson(allocator, "main", "hello");
    defer allocator.free(payload);

    try std.testing.expect(std.mem.indexOf(u8, payload, "\"type\":\"session.send\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"session_key\":\"main\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"content\":\"hello\"") != null);
}

test "session_protocol: buildSessionSendJson keeps session_key optional" {
    const allocator = std.testing.allocator;

    const payload = try buildSessionSendJson(allocator, null, "hello");
    defer allocator.free(payload);

    try std.testing.expect(std.mem.indexOf(u8, payload, "\"type\":\"session.send\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"content\":\"hello\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"session_key\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"session_key\":null") == null);
}
