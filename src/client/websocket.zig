const std = @import("std");
const ws = @import("websocket");
const logger = @import("ziggy-core").utils.logger;

// Simplified WebSocket client for ZSS
// Connects to Spiderweb and handles basic message send/receive

pub const WebSocketClient = struct {
    allocator: std.mem.Allocator,
    url: []const u8,
    token: []const u8,
    is_connected: bool = false,
    client: ?ws.Client = null,
    read_timeout_ms: u32 = 5_000,
    session_key: ?[]const u8 = null,

    // Message handling
    message_queue: std.ArrayListUnmanaged([]const u8),

    pub fn init(allocator: std.mem.Allocator, url: []const u8, token: []const u8) WebSocketClient {
        return .{
            .allocator = allocator,
            .url = url,
            .token = token,
            .message_queue = .empty,
        };
    }

    pub fn deinit(self: *WebSocketClient) void {
        self.disconnect();
        if (self.session_key) |key| {
            self.allocator.free(key);
        }
        for (self.message_queue.items) |msg| {
            self.allocator.free(msg);
        }
        self.message_queue.deinit(self.allocator);
    }

    pub fn connect(self: *WebSocketClient) !void {
        if (self.is_connected) return;

        logger.info("Connecting to {s}...", .{self.url});

        // Parse URL
        const parsed = try parseUrl(self.allocator, self.url);
        defer parsed.deinit(self.allocator);

        // Create client
        var client = try ws.Client.init(self.allocator, .{
            .host = parsed.host,
            .port = parsed.port,
            .tls = parsed.tls,
        });
        errdefer client.deinit();

        // Connect with handshake
        var headers_buf: [256]u8 = undefined;
        const headers = if (self.token.len > 0) blk: {
            const h = try std.fmt.bufPrint(&headers_buf, "Authorization: {s}\r\n", .{self.token});
            break :blk h;
        } else null;

        try client.handshake(parsed.path, .{
            .timeout_ms = 10_000,
            .headers = headers,
        });

        self.client = client;
        self.is_connected = true;

        logger.info("Connected to Spiderweb", .{});
    }

    pub fn disconnect(self: *WebSocketClient) void {
        if (self.client) |*client| {
            client.close(.{}) catch {};
            client.deinit();
            self.client = null;
        }
        self.is_connected = false;
        logger.info("Disconnected from Spiderweb", .{});
    }

    pub fn send(self: *WebSocketClient, message: []const u8) !void {
        if (!self.is_connected) {
            return error.NotConnected;
        }

        if (self.client) |*client| {
            // Need to cast to []u8 because the API expects mutable
            try client.write(@constCast(message));
            logger.debug("Sent: {s}", .{message});
        }
    }

    pub fn read(self: *WebSocketClient) !?[]const u8 {
        if (!self.is_connected) {
            return error.NotConnected;
        }

        if (self.client) |*client| {
            const msg = client.read() catch |err| switch (err) {
                error.WouldBlock => return null,
                else => return err,
            };

            if (msg) |m| {
                defer client.done(m);
                if (m.type == .text) {
                    const copy = try self.allocator.dupe(u8, m.data);
                    return copy;
                }
            }
        }

        return null;
    }

    pub fn readTimeout(self: *WebSocketClient, timeout_ms: u32) !?[]const u8 {
        const start = std.time.milliTimestamp();
        while (std.time.milliTimestamp() - start < timeout_ms) {
            if (try self.read()) |msg| {
                return msg;
            }
            std.Thread.sleep(10 * std.time.ns_per_ms); // 10ms
        }
        return null;
    }
};

const ParsedUrl = struct {
    host: []const u8,
    port: u16,
    path: []const u8,
    tls: bool,

    fn deinit(self: ParsedUrl, allocator: std.mem.Allocator) void {
        allocator.free(self.host);
        allocator.free(self.path);
    }
};

fn parseUrl(allocator: std.mem.Allocator, url: []const u8) !ParsedUrl {
    // Parse ws://host:port/path or wss://host:port/path
    const ws_prefix = "ws://";
    const wss_prefix = "wss://";

    var remaining: []const u8 = undefined;
    var tls = false;
    var default_port: u16 = 18790;

    if (std.mem.startsWith(u8, url, wss_prefix)) {
        remaining = url[wss_prefix.len..];
        tls = true;
        default_port = 443;
    } else if (std.mem.startsWith(u8, url, ws_prefix)) {
        remaining = url[ws_prefix.len..];
        tls = false;
        default_port = 18790;
    } else {
        return error.InvalidUrl;
    }

    // Find path
    const path_start = std.mem.indexOf(u8, remaining, "/");
    const host_port = if (path_start) |i| remaining[0..i] else remaining;
    const path = if (path_start) |i| try allocator.dupe(u8, remaining[i..]) else try allocator.dupe(u8, "/");

    // Parse host:port
    const port_start = std.mem.lastIndexOf(u8, host_port, ":");
    const host = if (port_start) |i| try allocator.dupe(u8, host_port[0..i]) else try allocator.dupe(u8, host_port);
    const port = if (port_start) |i| try std.fmt.parseInt(u16, host_port[i + 1 ..], 10) else default_port;

    return .{
        .host = host,
        .port = port,
        .path = path,
        .tls = tls,
    };
}

// Simple connection test
pub fn testConnection(allocator: std.mem.Allocator, url: []const u8) !void {
    var client = WebSocketClient.init(allocator, url, "");
    defer client.deinit();

    try client.connect();

    // Send ping
    try client.send("{\"type\":\"ping\"}");

    // Wait for pong
    if (try client.readTimeout(5_000)) |response| {
        defer allocator.free(response);
        logger.info("Received: {s}", .{response});
    } else {
        logger.warn("No response received", .{});
    }

    client.disconnect();
}
