const std = @import("std");
const ws = @import("websocket");
const builtin = @import("builtin");

const MessageQueue = struct {
    mutex: std.Thread.Mutex,
    cond: std.Thread.Condition,
    items: std.ArrayList([]u8),
    allocator: std.mem.Allocator,

    fn init(allocator: std.mem.Allocator) MessageQueue {
        return .{
            .mutex = .{},
            .cond = .{},
            .items = .empty,
            .allocator = allocator,
        };
    }

    fn deinit(self: *MessageQueue) void {
        self.mutex.lock();
        for (self.items.items) |item| {
            self.allocator.free(item);
        }
        self.items.deinit(self.allocator);
        self.mutex.unlock();
    }

    fn push(self: *MessageQueue, msg: []u8) void {
        self.mutex.lock();
        self.items.append(self.allocator, msg) catch {};
        self.cond.signal();
        self.mutex.unlock();
    }

    fn pop(self: *MessageQueue) ?[]u8 {
        self.mutex.lock();
        if (self.items.items.len == 0) {
            self.mutex.unlock();
            return null;
        }
        const msg = self.items.orderedRemove(0);
        self.mutex.unlock();
        return msg;
    }

    fn popWait(self: *MessageQueue, timeout_ms: u32) ?[]u8 {
        self.mutex.lock();
        if (self.items.items.len == 0) {
            self.cond.timedWait(&self.mutex, timeout_ms * std.time.ns_per_ms) catch {};
        }
        if (self.items.items.len == 0) {
            self.mutex.unlock();
            return null;
        }
        const msg = self.items.orderedRemove(0);
        self.mutex.unlock();
        return msg;
    }
};

// Handler for websocket library's readLoop
const WsHandler = struct {
    allocator: std.mem.Allocator,
    queue: *MessageQueue,

    pub fn serverMessage(self: *WsHandler, data: []const u8) !void {
        const copy = self.allocator.dupe(u8, data) catch return;
        self.queue.push(copy);
    }

    pub fn serverPing(self: *WsHandler, data: []const u8) !void {
        _ = self;
        _ = data;
        // Pong is handled automatically by the library
    }

    pub fn serverClose(self: *WsHandler, data: []const u8) !void {
        _ = self;
        _ = data;
        std.log.info("WebSocket server closed connection", .{});
    }
};

pub const WebSocketClient = struct {
    allocator: std.mem.Allocator,
    url_buf: []u8,
    token_buf: []u8,
    client: ?ws.Client = null,
    connected: bool = false,

    // Threading - using library's readLoopInNewThread
    read_thread: ?std.Thread = null,
    handler: ?WsHandler = null,
    message_queue: MessageQueue,

    pub fn init(allocator: std.mem.Allocator, url: []const u8, token: []const u8) !WebSocketClient {
        return .{
            .allocator = allocator,
            .url_buf = try allocator.dupe(u8, url),
            .token_buf = try allocator.dupe(u8, token),
            .message_queue = MessageQueue.init(allocator),
        };
    }

    pub fn deinit(self: *WebSocketClient) void {
        self.disconnect();
        self.allocator.free(self.url_buf);
        self.allocator.free(self.token_buf);
        self.message_queue.deinit();
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

        // Ensure read() returns immediately when no bytes are available.
        try setClientSocketNonBlocking(&client);

        self.client = client;
        client_owned_locally = false;
        self.connected = true;

        // Setup handler and start library's read loop in new thread
        self.handler = WsHandler{
            .allocator = self.allocator,
            .queue = &self.message_queue,
        };

        self.read_thread = try client.readLoopInNewThread(&self.handler.?);
    }

    pub fn disconnect(self: *WebSocketClient) void {
        // Close connection (this will stop the read loop)
        if (self.client) |*client| {
            client.close(.{}) catch {};
            
            // Wait for read thread to finish
            if (self.read_thread) |thread| {
                thread.join();
                self.read_thread = null;
            }
            
            client.deinit();
            self.client = null;
        }
        self.connected = false;
        self.handler = null;
    }

    pub fn send(self: *WebSocketClient, payload: []const u8) !void {
        if (!self.connected) return error.NotConnected;
        if (self.client) |*client| {
            try client.write(@constCast(payload));
            return;
        }
        return error.NotConnected;
    }

    /// Non-blocking check for messages. Returns null if none available.
    pub fn tryReceive(self: *WebSocketClient) ?[]u8 {
        return self.message_queue.pop();
    }

    /// Wait up to timeout_ms for a message. Returns null on timeout.
    pub fn receive(self: *WebSocketClient, timeout_ms: u32) ?[]u8 {
        return self.message_queue.popWait(timeout_ms);
    }

    /// Backwards compatibility - polls for a message (non-blocking)
    /// Returns error.WouldBlock if no message available (matching original API)
    /// Returns error.ConnectionClosed when connection is closed
    pub fn read(self: *WebSocketClient) (error{ NotConnected, WouldBlock, ConnectionClosed, Closed }!?[]u8) {
        if (!self.connected) return error.NotConnected;
        if (self.tryReceive()) |msg| {
            return msg;
        }
        return error.WouldBlock;
    }
};

fn setClientSocketNonBlocking(client: *ws.Client) !void {
    if (comptime builtin.os.tag == .windows) {
        return;
    }

    const socket = client.stream.stream.handle;
    const flags = try std.posix.fcntl(socket, std.posix.F.GETFL, 0);
    const nonblock_mask_u32: u32 = @bitCast(std.posix.O{ .NONBLOCK = true });
    const nonblock_mask: usize = @intCast(nonblock_mask_u32);
    _ = try std.posix.fcntl(socket, std.posix.F.SETFL, flags | nonblock_mask);
}

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
