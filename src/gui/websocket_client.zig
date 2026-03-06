const std = @import("std");
const ws = @import("websocket");

const ws_client_max_message_bytes: usize = 16 * 1024 * 1024;
const ws_client_read_buffer_bytes: usize = 16 * 1024;

const MessageQueue = struct {
    const capacity: usize = 4096;

    // Single-producer (read thread) / single-consumer (UI thread) ring queue.
    slots: [capacity]?[]u8,
    head: std.atomic.Value(usize),
    tail: std.atomic.Value(usize),
    dropped_messages: std.atomic.Value(u32),
    allocator: std.mem.Allocator,
    label: []const u8,
    wait_mutex: std.Thread.Mutex = .{},
    wait_cond: std.Thread.Condition = .{},

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
        self.wait_mutex.lock();
        self.wait_cond.broadcast();
        self.wait_mutex.unlock();
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
        const deadline_ns: i128 = std.time.nanoTimestamp() + @as(i128, @intCast(timeout_ms)) * std.time.ns_per_ms;
        self.wait_mutex.lock();
        defer self.wait_mutex.unlock();
        while (true) {
            if (self.pop()) |item| return item;
            const now_ns = std.time.nanoTimestamp();
            if (now_ns >= deadline_ns) return null;
            const remaining_ns: u64 = @intCast(deadline_ns - now_ns);
            self.wait_cond.timedWait(&self.wait_mutex, remaining_ns) catch |err| switch (err) {
                error.Timeout => return null,
            };
        }
    }
};

const PendingFrameWaiter = struct {
    mutex: std.Thread.Mutex = .{},
    cond: std.Thread.Condition = .{},
    done: bool = false,
    failed: bool = false,
    frame: ?[]u8 = null,

    fn deinit(self: *PendingFrameWaiter, allocator: std.mem.Allocator) void {
        if (self.frame) |value| allocator.free(value);
        self.* = undefined;
    }
};

pub const Mode = enum {
    threaded_queue,
    direct,
};

const InboundMessageQueues = struct {
    protocol: MessageQueue,

    fn init(allocator: std.mem.Allocator) InboundMessageQueues {
        return .{
            .protocol = MessageQueue.init(allocator, "protocol"),
        };
    }

    fn deinit(self: *InboundMessageQueues) void {
        self.protocol.deinit();
    }

    fn push(self: *InboundMessageQueues, msg: []u8) void {
        _ = self.protocol.push(msg);
    }

    fn pop(self: *InboundMessageQueues) ?[]u8 {
        return self.protocol.pop();
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
    mode: Mode = .threaded_queue,
    client: ?ws.Client = null,

    // Threading - using manual read loop (like ZSC)
    read_thread: ?std.Thread = null,
    should_stop: std.atomic.Value(bool),
    connection_alive: std.atomic.Value(bool),
    inbound_queues: InboundMessageQueues,
    verbose_logs: bool = false,
    send_mutex: std.Thread.Mutex = .{},
    waiters_mutex: std.Thread.Mutex = .{},
    acheron_waiters: std.AutoHashMapUnmanaged(u32, *PendingFrameWaiter) = .{},
    control_waiters: std.StringHashMapUnmanaged(*PendingFrameWaiter) = .{},
    next_acheron_tag: std.atomic.Value(u32) = std.atomic.Value(u32).init(1),
    next_acheron_fid: std.atomic.Value(u32) = std.atomic.Value(u32).init(2),

    pub fn init(allocator: std.mem.Allocator, url: []const u8, token: []const u8) !WebSocketClient {
        return initWithMode(allocator, url, token, .threaded_queue);
    }

    pub fn initWithMode(
        allocator: std.mem.Allocator,
        url: []const u8,
        token: []const u8,
        mode: Mode,
    ) !WebSocketClient {
        return .{
            .allocator = allocator,
            .url_buf = try allocator.dupe(u8, url),
            .token_buf = try allocator.dupe(u8, token),
            .mode = mode,
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

    pub fn setVerboseLogs(self: *WebSocketClient, enabled: bool) void {
        self.verbose_logs = enabled;
    }

    fn logVerbose(self: *const WebSocketClient, comptime format: []const u8, args: anytype) void {
        if (!self.verbose_logs) return;
        std.log.debug(format, args);
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
        self.clearWaiters();
    }

    pub fn connect(self: *WebSocketClient) !void {
        if (self.client != null) return;

        const parsed = try parseUrl(self.allocator, self.url_buf);
        defer parsed.deinit(self.allocator);

        var client = try ws.Client.init(self.allocator, .{
            .host = parsed.host,
            .port = parsed.port,
            .tls = parsed.tls,
            .max_size = ws_client_max_message_bytes,
            .buffer_size = ws_client_read_buffer_bytes,
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

        // Match CLI behavior: use a short socket read timeout so readLoop's
        // client.read() returns WouldBlock quickly instead of blocking.
        try client.readTimeout(1);

        self.client = client;
        client_owned_locally = false;
        self.should_stop.store(false, .release);
        self.connection_alive.store(true, .release);
        self.next_acheron_tag.store(1, .release);
        self.next_acheron_fid.store(2, .release);

        // Threaded mode mirrors the GUI main websocket usage.
        if (self.mode == .threaded_queue) {
            self.read_thread = try std.Thread.spawn(.{}, readLoop, .{self});
        }
        std.log.info("WebSocket connected to {s}:{d}", .{ parsed.host, parsed.port });
    }

    fn readLoop(self: *WebSocketClient) void {
        self.logVerbose("[WS] readLoop thread started", .{});

        while (!self.should_stop.load(.acquire)) {
            if (self.client) |*client| {
                const msg = blk: {
                    self.send_mutex.lock();
                    defer self.send_mutex.unlock();
                    break :blk client.read();
                } catch |err| switch (err) {
                    error.WouldBlock => {
                        std.Thread.sleep(1 * std.time.ns_per_ms);
                        continue;
                    },
                    error.InvalidMessageType => {
                        // Some servers can emit control/extension frames the current parser
                        // does not map into normal message variants. Treat as non-fatal.
                        std.log.warn("[WS] ignoring unsupported frame type", .{});
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
                        if (self.dispatchPendingReply(copy)) continue;
                        self.inbound_queues.push(copy);
                    },
                    .ping => {
                        self.send_mutex.lock();
                        defer self.send_mutex.unlock();
                        if (self.connection_alive.load(.acquire) and !self.should_stop.load(.acquire)) {
                            client.writePong(@constCast(msg.data)) catch |err| {
                                std.log.warn("[WS] Pong write failed: {s}", .{@errorName(err)});
                                self.connection_alive.store(false, .release);
                                self.failAllWaiters();
                            };
                        }
                    },
                    .close => {
                        self.logVerbose("[WS] Got close frame", .{});
                        break;
                    },
                    .pong => {},
                }
            } else {
                self.logVerbose("[WS] self.client is null, breaking", .{});
                break;
            }
        }

        self.connection_alive.store(false, .release);
        self.failAllWaiters();
        self.logVerbose("[WS] readLoop thread stopped (should_stop={})", .{self.should_stop.load(.acquire)});
    }

    pub fn disconnect(self: *WebSocketClient) void {
        // Signal thread to stop
        self.should_stop.store(true, .release);
        self.connection_alive.store(false, .release);
        self.failAllWaiters();

        // Serialize close/deinit against send() to avoid socket-handle races.
        self.send_mutex.lock();
        if (self.client) |*client| {
            client.close(.{}) catch {};
        }
        self.send_mutex.unlock();

        // Wait for read thread to finish after close wakes the read loop.
        if (self.read_thread) |thread| {
            thread.join();
            self.read_thread = null;
        }

        self.send_mutex.lock();
        defer self.send_mutex.unlock();
        if (self.client) |*client| {
            client.deinit();
            self.client = null;
        }
    }

    pub fn send(self: *WebSocketClient, payload: []const u8) !void {
        self.send_mutex.lock();
        defer self.send_mutex.unlock();
        if (self.client == null) return error.NotConnected;
        if (!self.connection_alive.load(.acquire) or self.should_stop.load(.acquire)) {
            return error.ConnectionClosed;
        }
        self.logVerbose("[WS] Sending {d} bytes", .{payload.len});
        if (self.client) |*client| {
            client.write(@constCast(payload)) catch |err| {
                std.log.err("[WS] Send failed: {s}", .{@errorName(err)});
                self.connection_alive.store(false, .release);
                self.failAllWaiters();
                return err;
            };
            self.logVerbose("[WS] Send successful", .{});
            return;
        }
        return error.NotConnected;
    }

    pub fn isAlive(self: *WebSocketClient) bool {
        return self.client != null and self.connection_alive.load(.acquire);
    }

    pub fn nextAcheronTag(self: *WebSocketClient) u32 {
        while (true) {
            const current = self.next_acheron_tag.load(.acquire);
            const next = if (current == std.math.maxInt(u32)) 1 else current + 1;
            if (self.next_acheron_tag.cmpxchgWeak(current, next, .acq_rel, .acquire) == null) {
                return if (current == 0) 1 else current;
            }
        }
    }

    pub fn nextAcheronFid(self: *WebSocketClient) u32 {
        while (true) {
            const current = self.next_acheron_fid.load(.acquire);
            var next = current +% 1;
            if (next == 0 or next == 1) next = 2;
            if (self.next_acheron_fid.cmpxchgWeak(current, next, .acq_rel, .acquire) == null) {
                return if (current == 0 or current == 1) 2 else current;
            }
        }
    }

    pub fn awaitAcheronFrame(self: *WebSocketClient, tag: u32, timeout_ms: u32) !?[]u8 {
        if (self.mode != .threaded_queue) return self.receive(timeout_ms);

        var waiter = try self.allocator.create(PendingFrameWaiter);
        waiter.* = .{};
        errdefer self.allocator.destroy(waiter);

        self.waiters_mutex.lock();
        var lock_held = true;
        errdefer if (lock_held) self.waiters_mutex.unlock();
        if (self.acheron_waiters.contains(tag)) {
            waiter.deinit(self.allocator);
            self.allocator.destroy(waiter);
            return error.Busy;
        }
        try self.acheron_waiters.put(self.allocator, tag, waiter);
        self.waiters_mutex.unlock();
        lock_held = false;
        defer self.removeAcheronWaiter(tag, waiter);
        return try self.waitForPendingFrame(waiter, timeout_ms);
    }

    pub fn awaitControlFrame(self: *WebSocketClient, request_id: []const u8, timeout_ms: u32) !?[]u8 {
        if (self.mode != .threaded_queue) return self.receive(timeout_ms);

        const key = try self.allocator.dupe(u8, request_id);
        errdefer self.allocator.free(key);

        var waiter = try self.allocator.create(PendingFrameWaiter);
        waiter.* = .{};
        errdefer self.allocator.destroy(waiter);

        self.waiters_mutex.lock();
        var lock_held = true;
        errdefer if (lock_held) self.waiters_mutex.unlock();
        if (self.control_waiters.contains(request_id)) {
            waiter.deinit(self.allocator);
            self.allocator.destroy(waiter);
            return error.Busy;
        }
        try self.control_waiters.put(self.allocator, key, waiter);
        self.waiters_mutex.unlock();
        lock_held = false;
        defer self.removeControlWaiter(request_id, waiter);
        return try self.waitForPendingFrame(waiter, timeout_ms);
    }

    /// Non-blocking check for messages. Returns null if none available.
    pub fn tryReceive(self: *WebSocketClient) ?[]u8 {
        if (self.mode == .direct) {
            return self.tryReceiveDirect();
        }
        return self.inbound_queues.pop();
    }

    /// Wait up to timeout_ms for a message. Returns null on timeout.
    pub fn receive(self: *WebSocketClient, timeout_ms: u32) ?[]u8 {
        if (self.mode == .direct) {
            const deadline_ms = std.time.milliTimestamp() + @as(i64, @intCast(timeout_ms));
            while (std.time.milliTimestamp() <= deadline_ms) {
                if (self.tryReceiveDirect()) |msg| return msg;
                if (!self.connection_alive.load(.acquire)) return null;
                std.Thread.sleep(1 * std.time.ns_per_ms);
            }
            return null;
        }
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

    fn tryReceiveDirect(self: *WebSocketClient) ?[]u8 {
        if (self.client == null) return null;
        if (!self.connection_alive.load(.acquire)) return null;

        if (self.client) |*client| {
            const msg = blk: {
                self.send_mutex.lock();
                defer self.send_mutex.unlock();
                break :blk client.read();
            } catch |err| switch (err) {
                error.WouldBlock => return null,
                error.InvalidMessageType => {
                    std.log.warn("[WS] ignoring unsupported frame type", .{});
                    return null;
                },
                error.Closed, error.ConnectionResetByPeer => {
                    std.log.info("[WS] Connection closed", .{});
                    self.connection_alive.store(false, .release);
                    self.failAllWaiters();
                    return null;
                },
                else => {
                    std.log.err("[WS] read error: {s}", .{@errorName(err)});
                    self.connection_alive.store(false, .release);
                    self.failAllWaiters();
                    return null;
                },
            } orelse return null;
            defer client.done(msg);

            switch (msg.type) {
                .text, .binary => {
                    return self.allocator.dupe(u8, msg.data) catch |err| {
                        std.log.err("[WS] Failed to allocate copy: {s}", .{@errorName(err)});
                        return null;
                    };
                },
                .ping => {
                    self.send_mutex.lock();
                    defer self.send_mutex.unlock();
                    if (self.connection_alive.load(.acquire) and !self.should_stop.load(.acquire)) {
                        client.writePong(@constCast(msg.data)) catch |err| {
                            std.log.warn("[WS] Pong write failed: {s}", .{@errorName(err)});
                            self.connection_alive.store(false, .release);
                            self.failAllWaiters();
                        };
                    }
                    return null;
                },
                .close => {
                    self.connection_alive.store(false, .release);
                    self.failAllWaiters();
                    return null;
                },
                .pong => return null,
            }
        }

        return null;
    }

    fn waitForPendingFrame(self: *WebSocketClient, waiter: *PendingFrameWaiter, timeout_ms: u32) !?[]u8 {
        _ = self;
        const deadline_ns: i128 = std.time.nanoTimestamp() + @as(i128, @intCast(timeout_ms)) * std.time.ns_per_ms;
        waiter.mutex.lock();
        defer waiter.mutex.unlock();
        while (!waiter.done) {
            const now_ns = std.time.nanoTimestamp();
            if (now_ns >= deadline_ns) return null;
            const remaining_ns: u64 = @intCast(deadline_ns - now_ns);
            waiter.cond.timedWait(&waiter.mutex, remaining_ns) catch |err| switch (err) {
                error.Timeout => return null,
            };
        }
        if (waiter.failed) return error.ConnectionClosed;
        if (waiter.frame) |value| {
            waiter.frame = null;
            return value;
        }
        return null;
    }

    fn removeAcheronWaiter(self: *WebSocketClient, tag: u32, waiter: *PendingFrameWaiter) void {
        self.waiters_mutex.lock();
        _ = self.acheron_waiters.remove(tag);
        self.waiters_mutex.unlock();
        waiter.deinit(self.allocator);
        self.allocator.destroy(waiter);
    }

    fn removeControlWaiter(self: *WebSocketClient, request_id: []const u8, waiter: *PendingFrameWaiter) void {
        self.waiters_mutex.lock();
        if (self.control_waiters.fetchRemove(request_id)) |entry| {
            self.allocator.free(entry.key);
        }
        self.waiters_mutex.unlock();
        waiter.deinit(self.allocator);
        self.allocator.destroy(waiter);
    }

    fn dispatchPendingReply(self: *WebSocketClient, msg: []u8) bool {
        if (extractAcheronTag(msg)) |tag| {
            self.waiters_mutex.lock();
            const waiter = self.acheron_waiters.get(tag);
            self.waiters_mutex.unlock();
            if (waiter) |matched| {
                self.signalWaiter(matched, msg);
                return true;
            }
        }

        if (extractControlRequestId(msg)) |request_id| {
            self.waiters_mutex.lock();
            const waiter = self.control_waiters.get(request_id);
            self.waiters_mutex.unlock();
            if (waiter) |matched| {
                self.signalWaiter(matched, msg);
                return true;
            }
        }
        return false;
    }

    fn signalWaiter(self: *WebSocketClient, waiter: *PendingFrameWaiter, msg: []u8) void {
        waiter.mutex.lock();
        if (waiter.done) {
            waiter.mutex.unlock();
            self.allocator.free(msg);
            return;
        }
        waiter.frame = msg;
        waiter.done = true;
        waiter.failed = false;
        waiter.cond.broadcast();
        waiter.mutex.unlock();
    }

    fn failAllWaiters(self: *WebSocketClient) void {
        self.waiters_mutex.lock();
        defer self.waiters_mutex.unlock();

        var acheron_it = self.acheron_waiters.iterator();
        while (acheron_it.next()) |entry| {
            failPendingWaiter(entry.value_ptr.*);
        }
        self.acheron_waiters.clearRetainingCapacity();

        var control_it = self.control_waiters.iterator();
        while (control_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            failPendingWaiter(entry.value_ptr.*);
        }
        self.control_waiters.clearRetainingCapacity();
    }

    fn clearWaiters(self: *WebSocketClient) void {
        self.waiters_mutex.lock();
        defer self.waiters_mutex.unlock();

        var acheron_it = self.acheron_waiters.iterator();
        while (acheron_it.next()) |entry| {
            var waiter = entry.value_ptr.*;
            waiter.deinit(self.allocator);
            self.allocator.destroy(waiter);
        }
        self.acheron_waiters.deinit(self.allocator);

        var control_it = self.control_waiters.iterator();
        while (control_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            var waiter = entry.value_ptr.*;
            waiter.deinit(self.allocator);
            self.allocator.destroy(waiter);
        }
        self.control_waiters.deinit(self.allocator);
    }
};

fn failPendingWaiter(waiter: *PendingFrameWaiter) void {
    waiter.mutex.lock();
    waiter.done = true;
    waiter.failed = true;
    waiter.cond.broadcast();
    waiter.mutex.unlock();
}

fn extractJsonStringFieldValue(msg: []const u8, key: []const u8) ?[]const u8 {
    var prefix_buf: [64]u8 = undefined;
    const prefix = std.fmt.bufPrint(&prefix_buf, "\"{s}\":\"", .{key}) catch return null;
    const start = std.mem.indexOf(u8, msg, prefix) orelse return null;
    const value_start = start + prefix.len;
    const value_end = std.mem.indexOfScalarPos(u8, msg, value_start, '"') orelse return null;
    return msg[value_start..value_end];
}

fn extractJsonUnsignedFieldValue(msg: []const u8, key: []const u8) ?u32 {
    var prefix_buf: [64]u8 = undefined;
    const prefix = std.fmt.bufPrint(&prefix_buf, "\"{s}\":", .{key}) catch return null;
    const start = std.mem.indexOf(u8, msg, prefix) orelse return null;
    const value_start = start + prefix.len;
    var value_end = value_start;
    while (value_end < msg.len and std.ascii.isDigit(msg[value_end])) : (value_end += 1) {}
    if (value_end == value_start) return null;
    return std.fmt.parseInt(u32, msg[value_start..value_end], 10) catch null;
}

fn extractAcheronTag(msg: []const u8) ?u32 {
    const channel = extractJsonStringFieldValue(msg, "channel") orelse return null;
    if (!std.mem.eql(u8, channel, "acheron")) return null;
    return extractJsonUnsignedFieldValue(msg, "tag");
}

fn extractControlRequestId(msg: []const u8) ?[]const u8 {
    const channel = extractJsonStringFieldValue(msg, "channel") orelse return null;
    if (!std.mem.eql(u8, channel, "control")) return null;
    return extractJsonStringFieldValue(msg, "id");
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

test "InboundMessageQueues preserves FIFO order for unmatched frames" {
    const allocator = std.testing.allocator;
    var queues = InboundMessageQueues.init(allocator);
    defer queues.deinit();

    queues.push(try allocator.dupe(u8, "{\"type\":\"control.error\",\"error\":{}}"));
    queues.push(try allocator.dupe(u8, "{\"type\":\"session.receive\",\"payload\":{\"content\":\"ok\"}}"));

    const first = queues.pop().?;
    defer allocator.free(first);
    try std.testing.expectEqualStrings("{\"type\":\"control.error\",\"error\":{}}", first);

    const second = queues.pop().?;
    defer allocator.free(second);
    try std.testing.expectEqualStrings("{\"type\":\"session.receive\",\"payload\":{\"content\":\"ok\"}}", second);
}
