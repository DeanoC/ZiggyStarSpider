const std = @import("std");
const ws = @import("websocket");
const builtin = @import("builtin");
const protocol_messages = @import("protocol_messages.zig");

const MessageQueue = struct {
    const capacity: usize = 4096;

    // Single-producer (read thread) / single-consumer (UI thread) ring queue.
    slots: [capacity]?[]u8,
    head: std.atomic.Value(usize),
    tail: std.atomic.Value(usize),
    dropped_messages: std.atomic.Value(u32),
    allocator: std.mem.Allocator,
    label: []const u8,

    fn init(allocator: std.mem.Allocator, label: []const u8) MessageQueue {
        return .{
            .slots = [_]?[]u8{null} ** capacity,
            .head = std.atomic.Value(usize).init(0),
            .tail = std.atomic.Value(usize).init(0),
            .dropped_messages = std.atomic.Value(u32).init(0),
            .allocator = allocator,
            .label = label,
        };
    }

    fn deinit(self: *MessageQueue) void {
        while (self.pop()) |item| {
            self.allocator.free(item);
        }
    }

    fn push(self: *MessageQueue, msg: []u8) bool {
        const tail = self.tail.load(.monotonic);
        const head = self.head.load(.acquire);
        if (tail - head >= capacity) {
            const dropped = self.dropped_messages.fetchAdd(1, .monotonic) + 1;
            if (dropped == 1 or dropped % 256 == 0) {
                std.log.warn("[WS] {s} queue full, dropped {d} messages", .{ self.label, dropped });
            }
            self.allocator.free(msg);
            return false;
        }

        const slot_index = tail % capacity;
        self.slots[slot_index] = msg;
        self.tail.store(tail + 1, .release);
        return true;
    }

    fn pop(self: *MessageQueue) ?[]u8 {
        const head = self.head.load(.monotonic);
        const tail = self.tail.load(.acquire);
        if (head == tail) {
            return null;
        }

        const slot_index = head % capacity;
        const item = self.slots[slot_index] orelse return null;
        self.slots[slot_index] = null;
        self.head.store(head + 1, .release);
        return item;
    }

    fn popWait(self: *MessageQueue, timeout_ms: u32) ?[]u8 {
        const deadline_ms = std.time.milliTimestamp() + @as(i64, @intCast(timeout_ms));
        while (std.time.milliTimestamp() <= deadline_ms) {
            if (self.pop()) |item| return item;
            std.Thread.sleep(1 * std.time.ns_per_ms);
        }
        return null;
    }
};

const InboundLane = enum {
    protocol,
    debug,
};

const InboundMessageQueues = struct {
    protocol: MessageQueue,
    debug: MessageQueue,

    fn init(allocator: std.mem.Allocator) InboundMessageQueues {
        return .{
            .protocol = MessageQueue.init(allocator, "protocol"),
            .debug = MessageQueue.init(allocator, "debug"),
        };
    }

    fn deinit(self: *InboundMessageQueues) void {
        self.protocol.deinit();
        self.debug.deinit();
    }

    fn push(self: *InboundMessageQueues, msg: []u8) void {
        switch (classifyInboundLane(msg)) {
            .protocol => _ = self.protocol.push(msg),
            .debug => _ = self.debug.push(msg),
        }
    }

    fn pop(self: *InboundMessageQueues) ?[]u8 {
        return self.protocol.pop() orelse self.debug.pop();
    }

    fn popWait(self: *InboundMessageQueues, timeout_ms: u32) ?[]u8 {
        const deadline_ms = std.time.milliTimestamp() + @as(i64, @intCast(timeout_ms));
        while (std.time.milliTimestamp() <= deadline_ms) {
            if (self.pop()) |item| return item;
            std.Thread.sleep(1 * std.time.ns_per_ms);
        }
        return null;
    }
};

fn classifyInboundLane(msg: []const u8) InboundLane {
    const message_type = protocol_messages.parseMessageType(msg) orelse return .protocol;
    return if (message_type == .debug_event) .debug else .protocol;
}

fn normalizedAuthorizationToken(token: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, token, " \t");
    if (trimmed.len == 0) return null;
    if (std.ascii.startsWithIgnoreCase(trimmed, "Bearer ")) return trimmed;
    return null;
}

pub const WebSocketClient = struct {
    allocator: std.mem.Allocator,
    url_buf: []u8,
    token_buf: []u8,
    client: ?ws.Client = null,

    // Threading - using manual read loop (like ZSC)
    read_thread: ?std.Thread = null,
    should_stop: std.atomic.Value(bool),
    connection_alive: std.atomic.Value(bool),
    inbound_queues: InboundMessageQueues,

    pub fn init(allocator: std.mem.Allocator, url: []const u8, token: []const u8) !WebSocketClient {
        return .{
            .allocator = allocator,
            .url_buf = try allocator.dupe(u8, url),
            .token_buf = try allocator.dupe(u8, token),
            .should_stop = std.atomic.Value(bool).init(false),
            .connection_alive = std.atomic.Value(bool).init(false),
            .inbound_queues = InboundMessageQueues.init(allocator),
        };
    }

    pub fn create(allocator: std.mem.Allocator, url: []const u8, token: []const u8) !*WebSocketClient {
        const self = try allocator.create(WebSocketClient);
        self.* = try init(allocator, url, token);
        return self;
    }

    pub fn destroy(self: *WebSocketClient) void {
        const allocator = self.allocator;
        self.deinit();
        allocator.destroy(self);
    }

    pub fn deinit(self: *WebSocketClient) void {
        self.disconnect();
        self.allocator.free(self.url_buf);
        self.allocator.free(self.token_buf);
        self.inbound_queues.deinit();
    }

    pub fn connect(self: *WebSocketClient) !void {
        if (self.client != null) return;

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
        const headers = if (normalizedAuthorizationToken(self.token_buf)) |existing_bearer|
            try std.fmt.bufPrint(&headers_storage, "Authorization: {s}\r\n", .{existing_bearer})
        else if (std.mem.trim(u8, self.token_buf, " \t").len > 0)
            try std.fmt.bufPrint(
                &headers_storage,
                "Authorization: Bearer {s}\r\n",
                .{std.mem.trim(u8, self.token_buf, " \t")},
            )
        else
            null;

        try client.handshake(parsed.path, .{
            .timeout_ms = 10_000,
            .headers = headers,
        });

        // Set socket to non-blocking so read() returns WouldBlock immediately
        // when no data is available (required for proper thread behavior)
        try setClientSocketNonBlocking(&client);

        self.client = client;
        client_owned_locally = false;
        self.should_stop.store(false, .release);
        self.connection_alive.store(true, .release);

        // Start our own read loop thread (like ZSC does)
        self.read_thread = try std.Thread.spawn(.{}, readLoop, .{self});
        std.log.info("WebSocket connected to {s}:{d}", .{ parsed.host, parsed.port });
    }

    fn readLoop(self: *WebSocketClient) void {
        std.log.debug("[WS] readLoop thread started", .{});

        while (!self.should_stop.load(.acquire)) {
            if (self.client) |*client| {
                const msg = client.read() catch |err| switch (err) {
                    error.WouldBlock => {
                        std.Thread.sleep(1 * std.time.ns_per_ms);
                        continue;
                    },
                    error.Closed, error.ConnectionResetByPeer => {
                        std.log.info("[WS] Connection closed", .{});
                        self.connection_alive.store(false, .release);
                        break;
                    },
                    else => {
                        std.log.err("[WS] read error: {s}", .{@errorName(err)});
                        self.connection_alive.store(false, .release);
                        break;
                    },
                } orelse {
                    std.Thread.sleep(1 * std.time.ns_per_ms);
                    continue;
                };

                defer client.done(msg);

                switch (msg.type) {
                    .text, .binary => {
                        const copy = self.allocator.dupe(u8, msg.data) catch |err| {
                            std.log.err("[WS] Failed to allocate copy: {s}", .{@errorName(err)});
                            continue;
                        };
                        self.inbound_queues.push(copy);
                    },
                    .ping => {
                        client.writePong(@constCast(msg.data)) catch {};
                    },
                    .close => {
                        std.log.debug("[WS] Got close frame", .{});
                        break;
                    },
                    .pong => {},
                }
            } else {
                std.log.debug("[WS] self.client is null, breaking", .{});
                break;
            }
        }

        self.connection_alive.store(false, .release);
        std.log.debug("[WS] readLoop thread stopped (should_stop={})", .{self.should_stop.load(.acquire)});
    }

    pub fn disconnect(self: *WebSocketClient) void {
        // Signal thread to stop
        self.should_stop.store(true, .release);
        self.connection_alive.store(false, .release);

        // Close connection
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
    }

    pub fn send(self: *WebSocketClient, payload: []const u8) !void {
        if (self.client == null) return error.NotConnected;
        if (!self.connection_alive.load(.acquire)) return error.ConnectionClosed;
        std.log.debug("[WS] Sending {d} bytes", .{payload.len});
        if (self.client) |*client| {
            client.write(@constCast(payload)) catch |err| {
                std.log.err("[WS] Send failed: {s}", .{@errorName(err)});
                self.connection_alive.store(false, .release);
                return err;
            };
            std.log.debug("[WS] Send successful", .{});
            return;
        }
        return error.NotConnected;
    }

    pub fn isAlive(self: *WebSocketClient) bool {
        return self.client != null and self.connection_alive.load(.acquire);
    }

    /// Non-blocking check for messages. Returns null if none available.
    pub fn tryReceive(self: *WebSocketClient) ?[]u8 {
        return self.inbound_queues.pop();
    }

    /// Wait up to timeout_ms for a message. Returns null on timeout.
    pub fn receive(self: *WebSocketClient, timeout_ms: u32) ?[]u8 {
        return self.inbound_queues.popWait(timeout_ms);
    }

    /// Backwards compatibility - polls for a message (non-blocking)
    /// Returns error.WouldBlock if no message available (matching original API)
    /// Returns error.ConnectionClosed when connection is closed
    pub fn read(self: *WebSocketClient) (error{ NotConnected, WouldBlock, ConnectionClosed, Closed }!?[]u8) {
        if (self.client == null) return error.NotConnected;
        if (self.tryReceive()) |msg| {
            return msg;
        }
        if (!self.connection_alive.load(.acquire)) return error.ConnectionClosed;
        return error.WouldBlock;
    }
};

fn setClientSocketNonBlocking(client: *ws.Client) !void {
    const handle = client.stream.stream.handle;
    if (comptime builtin.os.tag == .windows) {
        var mode: u32 = 1;
        const result = std.os.windows.ws2_32.ioctlsocket(handle, std.os.windows.ws2_32.FIONBIO, &mode);
        if (result != 0) {
            return error.Unexpected;
        }
        return;
    }

    const socket = handle;
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
    const raw_path = if (slash) |idx| rest[idx..] else "/";
    const path = try normalizeControlPath(allocator, raw_path);
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

fn normalizeControlPath(allocator: std.mem.Allocator, raw_path: []const u8) ![]u8 {
    if (raw_path.len == 0 or std.mem.eql(u8, raw_path, "/")) {
        return allocator.dupe(u8, "/");
    }

    const trimmed = std.mem.trimRight(u8, raw_path, "/");
    if (trimmed.len == 0) return allocator.dupe(u8, "/");
    if (std.mem.eql(u8, trimmed, "/v2/fs")) {
        std.log.warn(
            "[WS] URL path /v2/fs is FSRPC-only; forcing control connection path to '/'",
            .{},
        );
        return allocator.dupe(u8, "/");
    }

    return allocator.dupe(u8, raw_path);
}

test "parseUrl rewrites /v2/fs path to root for control websocket" {
    const allocator = std.testing.allocator;
    const parsed = try parseUrl(allocator, "ws://127.0.0.1:18790/v2/fs");
    defer parsed.deinit(allocator);

    try std.testing.expectEqualStrings("/", parsed.path);
}

test "parseUrl preserves non-fsrpc websocket path" {
    const allocator = std.testing.allocator;
    const parsed = try parseUrl(allocator, "ws://127.0.0.1:18790/custom");
    defer parsed.deinit(allocator);

    try std.testing.expectEqualStrings("/custom", parsed.path);
}

test "MessageQueue preserves FIFO order" {
    const allocator = std.testing.allocator;
    var q = MessageQueue.init(allocator, "test");
    defer q.deinit();

    try std.testing.expect(q.push(try allocator.dupe(u8, "one")));
    try std.testing.expect(q.push(try allocator.dupe(u8, "two")));
    try std.testing.expect(q.push(try allocator.dupe(u8, "three")));

    const first = q.pop().?;
    defer allocator.free(first);
    try std.testing.expectEqualStrings("one", first);

    const second = q.pop().?;
    defer allocator.free(second);
    try std.testing.expectEqualStrings("two", second);

    const third = q.pop().?;
    defer allocator.free(third);
    try std.testing.expectEqualStrings("three", third);

    try std.testing.expect(q.pop() == null);
}

test "InboundMessageQueues prioritizes protocol frames over debug frames" {
    const allocator = std.testing.allocator;
    var queues = InboundMessageQueues.init(allocator);
    defer queues.deinit();

    queues.push(try allocator.dupe(u8, "{\"type\":\"debug.event\",\"payload\":{}}"));
    queues.push(try allocator.dupe(u8, "{\"type\":\"session.receive\",\"payload\":{\"content\":\"ok\"}}"));

    const first = queues.pop().?;
    defer allocator.free(first);
    try std.testing.expectEqualStrings("{\"type\":\"session.receive\",\"payload\":{\"content\":\"ok\"}}", first);

    const second = queues.pop().?;
    defer allocator.free(second);
    try std.testing.expectEqualStrings("{\"type\":\"debug.event\",\"payload\":{}}", second);
}
