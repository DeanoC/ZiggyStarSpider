const std = @import("std");
const ws_client_mod = @import("websocket_client.zig");
const control_plane = @import("control_plane");

const fsrpc_default_timeout_ms: u32 = 30_000;
const fsrpc_clunk_timeout_ms: u32 = 1_000;
const control_session_attach_timeout_ms: i64 = 20_000;
const fsrpc_read_chunk_bytes: u32 = 128 * 1024;
const fsrpc_read_max_total_bytes: usize = 8 * 1024 * 1024;

pub const RequestKind = enum {
    list_dir,
    read_file,
    resolve_kind,
};

const Request = struct {
    id: u64,
    kind: RequestKind,
    path: []u8,
};

pub const Result = struct {
    id: u64,
    kind: RequestKind,
    path: []u8,
    listing: ?[]u8 = null,
    content: ?[]u8 = null,
    is_dir: ?bool = null,
    error_text: ?[]u8 = null,

    pub fn deinit(self: *Result, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        if (self.listing) |value| allocator.free(value);
        if (self.content) |value| allocator.free(value);
        if (self.error_text) |value| allocator.free(value);
        self.* = undefined;
    }
};

const FsrpcEnvelope = struct {
    raw: []u8,
    parsed: std.json.Parsed(std.json.Value),

    fn deinit(self: *FsrpcEnvelope, allocator: std.mem.Allocator) void {
        self.parsed.deinit();
        allocator.free(self.raw);
        self.* = undefined;
    }
};

const RequestQueue = struct {
    const capacity: usize = 128;

    slots: [capacity]?Request,
    head: std.atomic.Value(usize),
    tail: std.atomic.Value(usize),
    dropped: std.atomic.Value(u32),
    allocator: std.mem.Allocator,

    fn init(allocator: std.mem.Allocator) RequestQueue {
        return .{
            .slots = [_]?Request{null} ** capacity,
            .head = std.atomic.Value(usize).init(0),
            .tail = std.atomic.Value(usize).init(0),
            .dropped = std.atomic.Value(u32).init(0),
            .allocator = allocator,
        };
    }

    fn deinit(self: *RequestQueue) void {
        while (self.pop()) |req| {
            self.allocator.free(req.path);
        }
    }

    fn push(self: *RequestQueue, req: Request) bool {
        const tail = self.tail.load(.monotonic);
        const head = self.head.load(.acquire);
        if (tail - head >= capacity) {
            const dropped = self.dropped.fetchAdd(1, .monotonic) + 1;
            if (dropped == 1 or dropped % 64 == 0) {
                std.log.warn("[FS worker] request queue full, dropped {d} requests", .{dropped});
            }
            self.allocator.free(req.path);
            return false;
        }
        const slot_index = tail % capacity;
        self.slots[slot_index] = req;
        self.tail.store(tail + 1, .release);
        return true;
    }

    fn pop(self: *RequestQueue) ?Request {
        const head = self.head.load(.monotonic);
        const tail = self.tail.load(.acquire);
        if (head == tail) return null;
        const slot_index = head % capacity;
        const req = self.slots[slot_index] orelse return null;
        self.slots[slot_index] = null;
        self.head.store(head + 1, .release);
        return req;
    }
};

const ResultQueue = struct {
    const capacity: usize = 128;

    slots: [capacity]?Result,
    head: std.atomic.Value(usize),
    tail: std.atomic.Value(usize),
    backpressure_events: std.atomic.Value(u32),
    allocator: std.mem.Allocator,

    fn init(allocator: std.mem.Allocator) ResultQueue {
        return .{
            .slots = [_]?Result{null} ** capacity,
            .head = std.atomic.Value(usize).init(0),
            .tail = std.atomic.Value(usize).init(0),
            .backpressure_events = std.atomic.Value(u32).init(0),
            .allocator = allocator,
        };
    }

    fn deinit(self: *ResultQueue) void {
        while (self.pop()) |result| {
            var owned = result;
            owned.deinit(self.allocator);
        }
    }

    fn push(self: *ResultQueue, result: Result) bool {
        const tail = self.tail.load(.monotonic);
        const head = self.head.load(.acquire);
        if (tail - head >= capacity) {
            const events = self.backpressure_events.fetchAdd(1, .monotonic) + 1;
            if (events == 1 or events % 256 == 0) {
                std.log.warn("[FS worker] result queue full; waiting for UI drain ({d} stalls)", .{events});
            }
            return false;
        }
        const slot_index = tail % capacity;
        self.slots[slot_index] = result;
        self.tail.store(tail + 1, .release);
        return true;
    }

    fn pop(self: *ResultQueue) ?Result {
        const head = self.head.load(.monotonic);
        const tail = self.tail.load(.acquire);
        if (head == tail) return null;
        const slot_index = head % capacity;
        const result = self.slots[slot_index] orelse return null;
        self.slots[slot_index] = null;
        self.head.store(head + 1, .release);
        return result;
    }
};

pub const FilesystemWorker = struct {
    allocator: std.mem.Allocator,
    url: []u8,
    token: []u8,
    session_key: ?[]u8 = null,
    agent_id: ?[]u8 = null,
    project_id: ?[]u8 = null,
    project_token: ?[]u8 = null,
    should_stop: std.atomic.Value(bool),
    worker_thread: ?std.Thread = null,
    requests: RequestQueue,
    results: ResultQueue,
    client: ?ws_client_mod.WebSocketClient = null,
    control_ready: bool = false,
    session_attached: bool = false,
    acheron_ready: bool = false,
    message_counter: u64 = 0,
    next_tag: u32 = 1,
    next_fid: u32 = 2,
    last_remote_error: ?[]u8 = null,

    pub fn init(
        allocator: std.mem.Allocator,
        url: []const u8,
        token: []const u8,
        session_key: ?[]const u8,
        agent_id: ?[]const u8,
        project_id: ?[]const u8,
        project_token: ?[]const u8,
    ) !FilesystemWorker {
        const url_copy = try allocator.dupe(u8, url);
        errdefer allocator.free(url_copy);
        const token_copy = try allocator.dupe(u8, token);
        errdefer allocator.free(token_copy);
        const session_key_copy = if (session_key) |value| try allocator.dupe(u8, value) else null;
        errdefer if (session_key_copy) |value| allocator.free(value);
        const agent_id_copy = if (agent_id) |value| try allocator.dupe(u8, value) else null;
        errdefer if (agent_id_copy) |value| allocator.free(value);
        const project_id_copy = if (project_id) |value| try allocator.dupe(u8, value) else null;
        errdefer if (project_id_copy) |value| allocator.free(value);
        const project_token_copy = if (project_token) |value| try allocator.dupe(u8, value) else null;
        errdefer if (project_token_copy) |value| allocator.free(value);

        return .{
            .allocator = allocator,
            .url = url_copy,
            .token = token_copy,
            .session_key = session_key_copy,
            .agent_id = agent_id_copy,
            .project_id = project_id_copy,
            .project_token = project_token_copy,
            .should_stop = std.atomic.Value(bool).init(false),
            .requests = RequestQueue.init(allocator),
            .results = ResultQueue.init(allocator),
        };
    }

    pub fn start(self: *FilesystemWorker) !void {
        if (self.worker_thread != null) return;
        self.should_stop.store(false, .release);
        self.worker_thread = try std.Thread.spawn(.{}, workerMain, .{self});
    }

    pub fn deinit(self: *FilesystemWorker) void {
        self.should_stop.store(true, .release);
        if (self.worker_thread) |thread| {
            thread.join();
            self.worker_thread = null;
        }
        self.disconnectClient();
        self.requests.deinit();
        self.results.deinit();
        self.clearRemoteError();
        if (self.session_key) |value| self.allocator.free(value);
        if (self.agent_id) |value| self.allocator.free(value);
        if (self.project_id) |value| self.allocator.free(value);
        if (self.project_token) |value| self.allocator.free(value);
        self.allocator.free(self.url);
        self.allocator.free(self.token);
    }

    pub fn submit(self: *FilesystemWorker, request_id: u64, kind: RequestKind, path: []const u8) !void {
        const path_copy = try self.allocator.dupe(u8, path);
        if (!self.requests.push(.{
            .id = request_id,
            .kind = kind,
            .path = path_copy,
        })) return error.RequestQueueFull;
    }

    pub fn tryPopResult(self: *FilesystemWorker) ?Result {
        return self.results.pop();
    }

    fn workerMain(self: *FilesystemWorker) void {
        while (!self.should_stop.load(.acquire)) {
            const request = self.requests.pop() orelse {
                std.Thread.sleep(1 * std.time.ns_per_ms);
                continue;
            };

            var result = self.processRequest(request);
            while (!self.results.push(result)) {
                if (self.should_stop.load(.acquire)) {
                    result.deinit(self.allocator);
                    return;
                }
                std.Thread.sleep(1 * std.time.ns_per_ms);
            }
        }
    }

    fn processRequest(self: *FilesystemWorker, request: Request) Result {
        self.clearRemoteError();

        const result = switch (request.kind) {
            .list_dir => blk: {
                const listing = self.listDirectory(request.path) catch |err| break :blk self.errorResult(request, err);
                break :blk Result{
                    .id = request.id,
                    .kind = request.kind,
                    .path = request.path,
                    .listing = listing,
                };
            },
            .read_file => blk: {
                const content = self.readFileText(request.path) catch |err| break :blk self.errorResult(request, err);
                break :blk Result{
                    .id = request.id,
                    .kind = request.kind,
                    .path = request.path,
                    .content = content,
                };
            },
            .resolve_kind => blk: {
                const is_dir = self.resolvePathIsDir(request.path) catch |err| break :blk self.errorResult(request, err);
                break :blk Result{
                    .id = request.id,
                    .kind = request.kind,
                    .path = request.path,
                    .is_dir = is_dir,
                };
            },
        };

        return result;
    }

    fn errorResult(self: *FilesystemWorker, request: Request, err: anyerror) Result {
        if (isDisconnectError(err)) self.disconnectClient();
        const op = switch (request.kind) {
            .list_dir => "list directory",
            .read_file => "read file",
            .resolve_kind => "resolve path kind",
        };
        const detail = if (self.last_remote_error) |remote|
            std.fmt.allocPrint(self.allocator, "{s}: {s}", .{ op, remote }) catch self.allocator.dupe(u8, @errorName(err)) catch null
        else
            std.fmt.allocPrint(self.allocator, "{s}: {s}", .{ op, @errorName(err) }) catch null;
        return .{
            .id = request.id,
            .kind = request.kind,
            .path = request.path,
            .error_text = detail,
        };
    }

    fn ensureConnected(self: *FilesystemWorker) !*ws_client_mod.WebSocketClient {
        if (self.client == null) {
            var client = try ws_client_mod.WebSocketClient.initWithMode(
                self.allocator,
                self.url,
                self.token,
                .direct,
            );
            errdefer client.deinit();
            try client.connect();
            self.client = client;
            self.control_ready = false;
            self.session_attached = false;
            self.acheron_ready = false;
        }

        if (self.client) |*client| {
            if (!client.isAlive()) {
                self.disconnectClient();
                return error.ConnectionClosed;
            }
            if (!self.control_ready) {
                try control_plane.ensureUnifiedV2Connection(self.allocator, client, &self.message_counter);
                self.control_ready = true;
            }
            if (!self.session_attached) {
                try self.ensureSessionAttached(client);
            }
            return client;
        }
        return error.NotConnected;
    }

    fn disconnectClient(self: *FilesystemWorker) void {
        if (self.client) |*client| {
            while (client.tryReceive()) |msg| {
                self.allocator.free(msg);
            }
            client.deinit();
            self.client = null;
        }
        self.control_ready = false;
        self.session_attached = false;
        self.acheron_ready = false;
    }

    fn clearRemoteError(self: *FilesystemWorker) void {
        if (self.last_remote_error) |value| {
            self.allocator.free(value);
            self.last_remote_error = null;
        }
    }

    fn setRemoteError(self: *FilesystemWorker, message: []const u8) void {
        self.clearRemoteError();
        self.last_remote_error = self.allocator.dupe(u8, message) catch null;
    }

    fn nextTag(self: *FilesystemWorker) u32 {
        const out = self.next_tag;
        self.next_tag +%= 1;
        if (self.next_tag == 0) self.next_tag = 1;
        return out;
    }

    fn nextFid(self: *FilesystemWorker) u32 {
        const out = self.next_fid;
        self.next_fid +%= 1;
        if (self.next_fid == 0 or self.next_fid == 1) self.next_fid = 2;
        return out;
    }

    fn ensureSessionAttached(self: *FilesystemWorker, client: *ws_client_mod.WebSocketClient) !void {
        const session_key = self.session_key orelse {
            self.session_attached = true;
            return;
        };
        const agent_id = self.agent_id orelse {
            self.session_attached = true;
            return;
        };

        const escaped_session = try jsonEscape(self.allocator, session_key);
        defer self.allocator.free(escaped_session);
        const escaped_agent = try jsonEscape(self.allocator, agent_id);
        defer self.allocator.free(escaped_agent);

        var payload = std.ArrayListUnmanaged(u8){};
        defer payload.deinit(self.allocator);
        try payload.writer(self.allocator).print(
            "{{\"session_key\":\"{s}\",\"agent_id\":\"{s}\"",
            .{ escaped_session, escaped_agent },
        );
        if (self.project_id) |project_id| {
            const escaped_project = try jsonEscape(self.allocator, project_id);
            defer self.allocator.free(escaped_project);
            try payload.writer(self.allocator).print(",\"project_id\":\"{s}\"", .{escaped_project});
        }
        if (self.project_token) |project_token| {
            const escaped_token = try jsonEscape(self.allocator, project_token);
            defer self.allocator.free(escaped_token);
            try payload.writer(self.allocator).print(",\"project_token\":\"{s}\"", .{escaped_token});
        }
        try payload.append(self.allocator, '}');

        const response_payload = try control_plane.requestControlPayloadJsonWithTimeout(
            self.allocator,
            client,
            &self.message_counter,
            "control.session_attach",
            payload.items,
            control_session_attach_timeout_ms,
        );
        defer self.allocator.free(response_payload);
        self.session_attached = true;
    }

    fn ensureFsrpcReady(self: *FilesystemWorker, client: *ws_client_mod.WebSocketClient) !void {
        if (self.acheron_ready) return;

        const version_tag = self.nextTag();
        const version_req = try std.fmt.allocPrint(
            self.allocator,
            "{{\"channel\":\"acheron\",\"type\":\"acheron.t_version\",\"tag\":{d},\"msize\":1048576,\"version\":\"acheron-1\"}}",
            .{version_tag},
        );
        defer self.allocator.free(version_req);
        var version = try self.sendAndAwaitFsrpc(client, version_req, version_tag, fsrpc_default_timeout_ms);
        defer version.deinit(self.allocator);
        try self.ensureFsrpcOk(&version);

        const attach_tag = self.nextTag();
        const attach_req = try std.fmt.allocPrint(
            self.allocator,
            "{{\"channel\":\"acheron\",\"type\":\"acheron.t_attach\",\"tag\":{d},\"fid\":1}}",
            .{attach_tag},
        );
        defer self.allocator.free(attach_req);
        var attach = try self.sendAndAwaitFsrpc(client, attach_req, attach_tag, fsrpc_default_timeout_ms);
        defer attach.deinit(self.allocator);
        try self.ensureFsrpcOk(&attach);

        self.acheron_ready = true;
    }

    fn sendAndAwaitFsrpc(
        self: *FilesystemWorker,
        client: *ws_client_mod.WebSocketClient,
        request_json: []const u8,
        tag: u32,
        timeout_ms: u32,
    ) !FsrpcEnvelope {
        try client.send(request_json);

        const started = std.time.milliTimestamp();
        while (std.time.milliTimestamp() - started < timeout_ms) {
            if (self.should_stop.load(.acquire)) return error.Stopped;
            if (client.receive(250)) |raw| {
                const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, raw, .{}) catch {
                    self.allocator.free(raw);
                    continue;
                };

                var matched = false;
                if (parsed.value == .object) {
                    const obj = parsed.value.object;
                    if (obj.get("channel")) |channel| {
                        if (channel == .string and std.mem.eql(u8, channel.string, "acheron")) {
                            if (obj.get("tag")) |raw_tag| {
                                if (raw_tag == .integer and raw_tag.integer >= 0 and @as(u32, @intCast(raw_tag.integer)) == tag) {
                                    matched = true;
                                }
                            }
                        }
                    }
                }

                if (matched) {
                    return .{
                        .raw = raw,
                        .parsed = parsed,
                    };
                }

                parsed.deinit();
                self.allocator.free(raw);
                continue;
            }
            if (!client.isAlive()) return error.ConnectionClosed;
        }

        return error.Timeout;
    }

    fn ensureFsrpcOk(self: *FilesystemWorker, envelope: *FsrpcEnvelope) !void {
        if (envelope.parsed.value != .object) return error.InvalidResponse;
        const obj = envelope.parsed.value.object;
        const ok_value = obj.get("ok") orelse return error.InvalidResponse;
        if (ok_value != .bool) return error.InvalidResponse;
        if (ok_value.bool) {
            self.clearRemoteError();
            return;
        }

        var detail: ?[]u8 = null;
        var runtime_warming = false;
        if (obj.get("error")) |err_value| {
            if (err_value == .object) {
                const err_obj = err_value.object;
                const message = if (err_obj.get("message")) |value|
                    if (value == .string) value.string else null
                else
                    null;
                const code = if (err_obj.get("code")) |value|
                    if (value == .string) value.string else null
                else
                    null;
                const errno = if (err_obj.get("errno")) |value|
                    if (value == .integer) value.integer else null
                else
                    null;
                if (code) |value| {
                    if (std.mem.eql(u8, value, "runtime_warming")) runtime_warming = true;
                }
                if (message != null and code != null and errno != null) {
                    detail = std.fmt.allocPrint(self.allocator, "{s} [{s}] (errno={d})", .{ message.?, code.?, errno.? }) catch null;
                } else if (message != null and code != null) {
                    detail = std.fmt.allocPrint(self.allocator, "{s} [{s}]", .{ message.?, code.? }) catch null;
                } else if (message != null) {
                    detail = self.allocator.dupe(u8, message.?) catch null;
                } else if (code != null) {
                    detail = std.fmt.allocPrint(self.allocator, "remote fsrpc error [{s}]", .{code.?}) catch null;
                } else if (errno != null) {
                    detail = std.fmt.allocPrint(self.allocator, "remote fsrpc error (errno={d})", .{errno.?}) catch null;
                }
            } else if (err_value == .string) {
                detail = self.allocator.dupe(u8, err_value.string) catch null;
            }
        }

        if (detail) |value| {
            defer self.allocator.free(value);
            self.setRemoteError(value);
        } else {
            self.setRemoteError("remote fsrpc error");
        }

        if (runtime_warming) return error.RuntimeWarming;
        return error.RemoteError;
    }

    fn splitPathSegments(self: *FilesystemWorker, path: []const u8) !std.ArrayListUnmanaged([]u8) {
        var out = std.ArrayListUnmanaged([]u8){};
        errdefer {
            for (out.items) |segment| self.allocator.free(segment);
            out.deinit(self.allocator);
        }

        const trimmed = std.mem.trim(u8, path, " \t\r\n");
        if (trimmed.len == 0 or std.mem.eql(u8, trimmed, "/")) return out;

        var iter = std.mem.splitScalar(u8, trimmed, '/');
        while (iter.next()) |raw| {
            const part = std.mem.trim(u8, raw, " \t\r\n");
            if (part.len == 0) continue;
            try out.append(self.allocator, try self.allocator.dupe(u8, part));
        }
        return out;
    }

    fn freePathSegments(self: *FilesystemWorker, segments: *std.ArrayListUnmanaged([]u8)) void {
        for (segments.items) |segment| self.allocator.free(segment);
        segments.deinit(self.allocator);
        segments.* = .{};
    }

    fn buildPathArrayJson(self: *FilesystemWorker, segments: []const []const u8) ![]u8 {
        var out = std.ArrayListUnmanaged(u8){};
        defer out.deinit(self.allocator);
        try out.append(self.allocator, '[');
        for (segments, 0..) |segment, idx| {
            if (idx > 0) try out.append(self.allocator, ',');
            const escaped = try jsonEscape(self.allocator, segment);
            defer self.allocator.free(escaped);
            try out.writer(self.allocator).print("\"{s}\"", .{escaped});
        }
        try out.append(self.allocator, ']');
        return out.toOwnedSlice(self.allocator);
    }

    fn walkPath(self: *FilesystemWorker, client: *ws_client_mod.WebSocketClient, path: []const u8) !u32 {
        var segments = try self.splitPathSegments(path);
        defer self.freePathSegments(&segments);
        const path_json = try self.buildPathArrayJson(segments.items);
        defer self.allocator.free(path_json);

        const new_fid = self.nextFid();
        const tag = self.nextTag();
        const request_json = try std.fmt.allocPrint(
            self.allocator,
            "{{\"channel\":\"acheron\",\"type\":\"acheron.t_walk\",\"tag\":{d},\"fid\":1,\"newfid\":{d},\"path\":{s}}}",
            .{ tag, new_fid, path_json },
        );
        defer self.allocator.free(request_json);
        var response = try self.sendAndAwaitFsrpc(client, request_json, tag, fsrpc_default_timeout_ms);
        defer response.deinit(self.allocator);
        try self.ensureFsrpcOk(&response);
        return new_fid;
    }

    fn openFid(self: *FilesystemWorker, client: *ws_client_mod.WebSocketClient, fid: u32, mode: []const u8) !void {
        const escaped_mode = try jsonEscape(self.allocator, mode);
        defer self.allocator.free(escaped_mode);
        const tag = self.nextTag();
        const request_json = try std.fmt.allocPrint(
            self.allocator,
            "{{\"channel\":\"acheron\",\"type\":\"acheron.t_open\",\"tag\":{d},\"fid\":{d},\"mode\":\"{s}\"}}",
            .{ tag, fid, escaped_mode },
        );
        defer self.allocator.free(request_json);
        var response = try self.sendAndAwaitFsrpc(client, request_json, tag, fsrpc_default_timeout_ms);
        defer response.deinit(self.allocator);
        try self.ensureFsrpcOk(&response);
    }

    fn readChunkText(
        self: *FilesystemWorker,
        client: *ws_client_mod.WebSocketClient,
        fid: u32,
        offset: u64,
        count: u32,
    ) ![]u8 {
        const tag = self.nextTag();
        const request_json = try std.fmt.allocPrint(
            self.allocator,
            "{{\"channel\":\"acheron\",\"type\":\"acheron.t_read\",\"tag\":{d},\"fid\":{d},\"offset\":{d},\"count\":{d}}}",
            .{ tag, fid, offset, count },
        );
        defer self.allocator.free(request_json);
        var response = try self.sendAndAwaitFsrpc(client, request_json, tag, fsrpc_default_timeout_ms);
        defer response.deinit(self.allocator);
        try self.ensureFsrpcOk(&response);

        if (response.parsed.value != .object) return error.InvalidResponse;
        const root = response.parsed.value.object;
        const payload = root.get("payload") orelse return error.InvalidResponse;
        if (payload != .object) return error.InvalidResponse;
        const data_b64 = payload.object.get("data_b64") orelse return error.InvalidResponse;
        if (data_b64 != .string) return error.InvalidResponse;
        const decoded_len = std.base64.standard.Decoder.calcSizeForSlice(data_b64.string) catch return error.InvalidResponse;
        const decoded = try self.allocator.alloc(u8, decoded_len);
        errdefer self.allocator.free(decoded);
        _ = std.base64.standard.Decoder.decode(decoded, data_b64.string) catch return error.InvalidResponse;
        return decoded;
    }

    fn readAllText(self: *FilesystemWorker, client: *ws_client_mod.WebSocketClient, fid: u32) ![]u8 {
        var out = std.ArrayListUnmanaged(u8){};
        errdefer out.deinit(self.allocator);

        var offset: u64 = 0;
        while (true) {
            const chunk = try self.readChunkText(client, fid, offset, fsrpc_read_chunk_bytes);
            defer self.allocator.free(chunk);

            if (chunk.len == 0) break;
            if (out.items.len + chunk.len > fsrpc_read_max_total_bytes) {
                return error.ResponseTooLarge;
            }

            try out.appendSlice(self.allocator, chunk);
            offset += @as(u64, @intCast(chunk.len));
            if (chunk.len < @as(usize, fsrpc_read_chunk_bytes)) break;
        }

        return out.toOwnedSlice(self.allocator);
    }

    fn fidIsDir(self: *FilesystemWorker, client: *ws_client_mod.WebSocketClient, fid: u32) !bool {
        const tag = self.nextTag();
        const request_json = try std.fmt.allocPrint(
            self.allocator,
            "{{\"channel\":\"acheron\",\"type\":\"acheron.t_stat\",\"tag\":{d},\"fid\":{d}}}",
            .{ tag, fid },
        );
        defer self.allocator.free(request_json);
        var response = try self.sendAndAwaitFsrpc(client, request_json, tag, fsrpc_default_timeout_ms);
        defer response.deinit(self.allocator);
        try self.ensureFsrpcOk(&response);

        if (response.parsed.value != .object) return error.InvalidResponse;
        const root = response.parsed.value.object;
        const payload = root.get("payload") orelse return error.InvalidResponse;
        if (payload != .object) return error.InvalidResponse;
        const kind = payload.object.get("kind") orelse return error.InvalidResponse;
        if (kind != .string) return error.InvalidResponse;
        return std.mem.eql(u8, kind.string, "dir");
    }

    fn clunkBestEffort(self: *FilesystemWorker, client: *ws_client_mod.WebSocketClient, fid: u32) void {
        const tag = self.nextTag();
        const request_json = std.fmt.allocPrint(
            self.allocator,
            "{{\"channel\":\"acheron\",\"type\":\"acheron.t_clunk\",\"tag\":{d},\"fid\":{d}}}",
            .{ tag, fid },
        ) catch return;
        defer self.allocator.free(request_json);
        var response = self.sendAndAwaitFsrpc(client, request_json, tag, fsrpc_clunk_timeout_ms) catch return;
        response.deinit(self.allocator);
    }

    fn listDirectory(self: *FilesystemWorker, path: []const u8) ![]u8 {
        return self.listDirectoryOnce(path) catch |err| {
            if (shouldRetryTransient(err)) {
                std.log.warn("[FS worker] listDirectory retry after {s} for path {s}", .{ @errorName(err), path });
                self.disconnectClient();
                return self.listDirectoryOnce(path);
            }
            return err;
        };
    }

    fn listDirectoryOnce(self: *FilesystemWorker, path: []const u8) ![]u8 {
        const client = try self.ensureConnected();
        try self.ensureFsrpcReady(client);
        const fid = try self.walkPath(client, path);
        defer self.clunkBestEffort(client, fid);
        const is_dir = try self.fidIsDir(client, fid);
        if (!is_dir) return error.NotDir;
        try self.openFid(client, fid, "r");
        return self.readAllText(client, fid);
    }

    fn readFileText(self: *FilesystemWorker, path: []const u8) ![]u8 {
        return self.readFileTextOnce(path) catch |err| {
            if (shouldRetryTransient(err)) {
                std.log.warn("[FS worker] readFile retry after {s} for path {s}", .{ @errorName(err), path });
                self.disconnectClient();
                return self.readFileTextOnce(path);
            }
            return err;
        };
    }

    fn readFileTextOnce(self: *FilesystemWorker, path: []const u8) ![]u8 {
        const client = try self.ensureConnected();
        try self.ensureFsrpcReady(client);
        const fid = try self.walkPath(client, path);
        defer self.clunkBestEffort(client, fid);
        try self.openFid(client, fid, "r");
        return self.readAllText(client, fid);
    }

    fn resolvePathIsDir(self: *FilesystemWorker, path: []const u8) !bool {
        return self.resolvePathIsDirOnce(path) catch |err| {
            if (shouldRetryTransient(err)) {
                std.log.warn("[FS worker] resolvePath retry after {s} for path {s}", .{ @errorName(err), path });
                self.disconnectClient();
                return self.resolvePathIsDirOnce(path);
            }
            return err;
        };
    }

    fn resolvePathIsDirOnce(self: *FilesystemWorker, path: []const u8) !bool {
        const client = try self.ensureConnected();
        try self.ensureFsrpcReady(client);
        const fid = try self.walkPath(client, path);
        defer self.clunkBestEffort(client, fid);
        return self.fidIsDir(client, fid);
    }
};

fn isDisconnectError(err: anyerror) bool {
    return err == error.NotConnected or
        err == error.ConnectionClosed or
        err == error.ConnectionResetByPeer or
        err == error.Closed;
}

fn shouldRetryTransient(err: anyerror) bool {
    return err == error.Timeout or isDisconnectError(err);
}

fn jsonEscape(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var out = std.ArrayListUnmanaged(u8){};
    defer out.deinit(allocator);

    for (input) |char| {
        switch (char) {
            '\\' => try out.appendSlice(allocator, "\\\\"),
            '"' => try out.appendSlice(allocator, "\\\""),
            '\n' => try out.appendSlice(allocator, "\\n"),
            '\r' => try out.appendSlice(allocator, "\\r"),
            '\t' => try out.appendSlice(allocator, "\\t"),
            else => {
                if (char < 0x20) {
                    try out.writer(allocator).print("\\u00{x:0>2}", .{char});
                } else {
                    try out.append(allocator, char);
                }
            },
        }
    }

    return out.toOwnedSlice(allocator);
}
