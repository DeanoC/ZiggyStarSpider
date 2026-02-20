const std = @import("std");
const ws = @import("websocket");
const builtin = @import("builtin");

const MessageQueue = struct {
    mutex: std.Thread.Mutex,
    cond: std.Thread.Condition,
    items: std.ArrayListUnmanaged([]u8),
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
        defer self.mutex.unlock();
        for (self.items.items) |item| {
            self.allocator.free(item);
        }
        self.items.deinit(self.allocator);
    }

    fn push(self: *MessageQueue, msg: []u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.items.append(self.allocator, msg) catch {
            std.log.err("[WS] MessageQueue.push failed to append", .{});
            return;
        };
        self.cond.signal();
    }

    fn pop(self: *MessageQueue) ?[]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.items.items.len == 0) {
            return null;
        }
        return self.items.swapRemove(0);
    }

    fn popWait(self: *MessageQueue, timeout_ms: u32) ?[]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.items.items.len == 0) {
            self.cond.timedWait(&self.mutex, timeout_ms * std.time.ns_per_ms) catch {};
        }
        if (self.items.items.len == 0) {
            return null;
        }
        return self.items.swapRemove(0);
    }
};

pub const WebSocketClient = struct {
    allocator: std.mem.Allocator,
    url_buf: []u8,
    token_buf: []u8,
    client: ?ws.Client = null,

    // Threading - using manual read loop (like ZSC)
    read_thread: ?std.Thread = null,
    should_stop: std.atomic.Value(bool),
    connection_alive: std.atomic.Value(bool),
    message_queue: MessageQueue,

    pub fn init(allocator: std.mem.Allocator, url: []const u8, token: []const u8) !WebSocketClient {
        return .{
            .allocator = allocator,
            .url_buf = try allocator.dupe(u8, url),
            .token_buf = try allocator.dupe(u8, token),
            .should_stop = std.atomic.Value(bool).init(false),
            .connection_alive = std.atomic.Value(bool).init(false),
            .message_queue = MessageQueue.init(allocator),
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
        self.message_queue.deinit();
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
        const headers = if (self.token_buf.len > 0)
            try std.fmt.bufPrint(&headers_storage, "Authorization: {s}\r\n", .{self.token_buf})
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
        std.log.info("[WS] readLoop thread started", .{});

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

                std.log.info("[WS] read() got message, type={s}, len={d}", .{@tagName(msg.type), msg.data.len});
                defer client.done(msg);

                switch (msg.type) {
                    .text, .binary => {
                        std.log.info("[WS] Pushing message to queue", .{});
                        const copy = self.allocator.dupe(u8, msg.data) catch |err| {
                            std.log.err("[WS] Failed to allocate copy: {s}", .{@errorName(err)});
                            continue;
                        };
                        self.message_queue.push(copy);
                        std.log.info("[WS] Message pushed to queue", .{});
                    },
                    .ping => {
                        client.writePong(@constCast(msg.data)) catch {};
                    },
                    .close => {
                        std.log.info("[WS] Got close frame", .{});
                        break;
                    },
                    .pong => {},
                }
            } else {
                std.log.info("[WS] self.client is null, breaking", .{});
                break;
            }
        }

        self.connection_alive.store(false, .release);
        std.log.info("[WS] readLoop thread stopped (should_stop={})", .{self.should_stop.load(.acquire)});
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
        std.log.info("[WS] Sending {d} bytes", .{ payload.len });
        if (self.client) |*client| {
            client.write(@constCast(payload)) catch |err| {
                std.log.err("[WS] Send failed: {s}", .{@errorName(err)});
                self.connection_alive.store(false, .release);
                return err;
            };
            std.log.info("[WS] Send successful", .{});
            return;
        }
        return error.NotConnected;
    }

    pub fn isAlive(self: *WebSocketClient) bool {
        return self.client != null and self.connection_alive.load(.acquire);
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
