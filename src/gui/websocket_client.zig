const std = @import("std");
const ws = @import("websocket");

pub const WebSocketClient = struct {
    allocator: std.mem.Allocator,
    url_buf: []u8,
    token_buf: []u8,
    client: ?ws.Client = null,
    connected: bool = false,

    pub fn init(allocator: std.mem.Allocator, url: []const u8, token: []const u8) !WebSocketClient {
        return .{
            .allocator = allocator,
            .url_buf = try allocator.dupe(u8, url),
            .token_buf = try allocator.dupe(u8, token),
        };
    }

    pub fn deinit(self: *WebSocketClient) void {
        self.disconnect();
        self.allocator.free(self.url_buf);
        self.allocator.free(self.token_buf);
    }

    pub fn connect(self: *WebSocketClient) !void {
        if (self.connected) return;

        const parsed = try parseUrl(self.allocator, self.url_buf);
        defer parsed.deinit(self.allocator);

        var client = try ws.Client.init(self.allocator, .{
            .host = parsed.host,
            .port = parsed.port,
            .tls = parsed.tls,
        });
        var client_owned_locally = true;
        errdefer if (client_owned_locally) client.deinit();

        var headers_storage: [512]u8 = undefined;
        const headers = if (self.token_buf.len > 0)
            try std.fmt.bufPrint(&headers_storage, "Authorization: {s}\r\n", .{self.token_buf})
        else
            null;

        try client.handshake(parsed.path, .{
            .timeout_ms = 10_000,
            .headers = headers,
        });

        // Non-blocking reads for frame polling.
        try client.readTimeout(0);

        self.client = client;
        client_owned_locally = false;
        self.connected = true;
    }

    pub fn disconnect(self: *WebSocketClient) void {
        if (self.client) |*client| {
            client.close(.{}) catch {};
            client.deinit();
            self.client = null;
        }
        self.connected = false;
    }

    pub fn send(self: *WebSocketClient, payload: []const u8) !void {
        if (!self.connected) return error.NotConnected;
        if (self.client) |*client| {
            try client.write(@constCast(payload));
            return;
        }
        return error.NotConnected;
    }

    pub fn read(self: *WebSocketClient) !?[]u8 {
        if (!self.connected) return error.NotConnected;
        if (self.client) |*client| {
            const msg = client.read() catch |err| switch (err) {
                error.WouldBlock => return null,
                else => return err,
            } orelse return null;
            var should_done = true;
            defer if (should_done) client.done(msg);

            switch (msg.type) {
                .text, .binary => return try self.allocator.dupe(u8, msg.data),
                .ping => {
                    // Keepalive
                    client.writePong(@constCast(msg.data)) catch {};
                    return null;
                },
                .close => {
                    should_done = false;
                    client.done(msg);
                    self.disconnect();
                    return error.ConnectionClosed;
                },
                else => return null,
            }
        }
        return error.NotConnected;
    }
};

const ParsedUrl = struct {
    host: []u8,
    port: u16,
    path: []u8,
    tls: bool,

    fn deinit(self: ParsedUrl, allocator: std.mem.Allocator) void {
        allocator.free(self.host);
        allocator.free(self.path);
    }
};

fn parseUrl(allocator: std.mem.Allocator, input: []const u8) !ParsedUrl {
    const ws_prefix = "ws://";
    const wss_prefix = "wss://";

    var rest: []const u8 = undefined;
    var tls = false;
    var default_port: u16 = 18790;

    if (std.mem.startsWith(u8, input, ws_prefix)) {
        rest = input[ws_prefix.len..];
    } else if (std.mem.startsWith(u8, input, wss_prefix)) {
        rest = input[wss_prefix.len..];
        tls = true;
        default_port = 443;
    } else {
        return error.InvalidUrl;
    }

    const slash = std.mem.indexOfScalar(u8, rest, '/');
    const host_port = if (slash) |idx| rest[0..idx] else rest;
    const path = if (slash) |idx| try allocator.dupe(u8, rest[idx..]) else try allocator.dupe(u8, "/");
    errdefer allocator.free(path);

    const colon = std.mem.lastIndexOfScalar(u8, host_port, ':');
    const host = if (colon) |idx| try allocator.dupe(u8, host_port[0..idx]) else try allocator.dupe(u8, host_port);
    errdefer allocator.free(host);

    const port = if (colon) |idx| try std.fmt.parseInt(u16, host_port[idx + 1 ..], 10) else default_port;

    return .{
        .host = host,
        .port = port,
        .path = path,
        .tls = tls,
    };
}
