const std = @import("std");
const protocol = @import("../src/protocol/spiderweb.zig");

test "protocol message parsing" {
    const allocator = std.testing.allocator;
    
    // Test chat.receive building
    const response = try protocol.buildChatReceive(allocator, "msg123", "Hello");
    defer allocator.free(response);
    
    try std.testing.expect(std.mem.indexOf(u8, response, "chat.receive") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "msg123") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "Hello") != null);
}

test "message type parsing" {
    const connect = "{\"type\":\"connect\"}";
    try std.testing.expect(protocol.parseMessageType(connect) == .connect);
    
    const chat_send = "{\"type\":\"chat.send\"}";
    try std.testing.expect(protocol.parseMessageType(chat_send) == .chat_send);
    
    const project_create = "{\"type\":\"project.create\"}";
    try std.testing.expect(protocol.parseMessageType(project_create) == .project_create);
}
