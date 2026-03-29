const std = @import("std");
const ws = @import("websocket");
const control_plane = @import("control_plane");
const shared_node = @import("spiderweb_node");
const fs_protocol = @import("spiderweb_fs").fs_protocol;
const unified = @import("spider-protocol").unified;

const control_reply_timeout_ms: i32 = 10_000;
const tunnel_poll_timeout_ms: i32 = 250;
const tunnel_max_frame_bytes: usize = 4 * 1024 * 1024;

pub fn buildAppLocalNodeName(allocator: std.mem.Allocator, profile_id: []const u8) ![]u8 {
    var out = std.ArrayListUnmanaged(u8){};
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "spiderapp-");

    const trimmed = std.mem.trim(u8, profile_id, " \t\r\n");
    const source = if (trimmed.len > 0) trimmed else "default";
    for (source) |char| {
        if (std.ascii.isAlphanumeric(char) or char == '-' or char == '_' or char == '.') {
            try out.append(allocator, std.ascii.toLower(char));
        } else {
            try out.append(allocator, '-');
        }
    }
    return out.toOwnedSlice(allocator);
}

pub fn buildControlRoutedFsUrl(
    allocator: std.mem.Allocator,
    control_url: []const u8,
    node_id: []const u8,
) ![]u8 {
    const parsed = try parseWsUrlWithDefaultPath(allocator, control_url, "/");
    defer parsed.deinit(allocator);
    const routed_path = try joinControlPath(allocator, parsed.path, "/v2/fs/node");
    defer allocator.free(routed_path);
    return std.fmt.allocPrint(
        allocator,
        "{s}://{s}:{d}{s}/{s}",
        .{ if (parsed.tls) "wss" else "ws", parsed.host, parsed.port, routed_path, node_id },
    );
}

pub const AppVenomHost = struct {
    pub const InitOptions = struct {
        chat_wasm_backend: ?shared_node.wasm_chat_backend.OwnedConfig = null,
    };

    allocator: std.mem.Allocator,
    control_url: []u8,
    auth_token: []u8,
    node_name: []u8,
    node_id: []u8,
    node_secret: []u8,
    fs_root_path: []u8,
    service: shared_node.fs_node_service.NodeService,
    thread: ?std.Thread = null,
    stop_mutex: std.Thread.Mutex = .{},
    stop_requested: bool = false,
    job_mutex: std.Thread.Mutex = .{},
    next_job_seq: u64 = 1,
    chat_wasm_backend: ?shared_node.wasm_chat_backend.OwnedConfig = null,

    pub fn init(
        allocator: std.mem.Allocator,
        control_url: []const u8,
        auth_token: []const u8,
        identity: control_plane.EnsuredNodeIdentity,
    ) !AppVenomHost {
        return initWithOptions(allocator, control_url, auth_token, identity, .{});
    }

    pub fn initWithOptions(
        allocator: std.mem.Allocator,
        control_url: []const u8,
        auth_token: []const u8,
        identity: control_plane.EnsuredNodeIdentity,
        options: InitOptions,
    ) !AppVenomHost {
        var cloned_chat_wasm_backend = if (options.chat_wasm_backend) |cfg| try cfg.clone(allocator) else null;
        errdefer if (cloned_chat_wasm_backend) |*cfg| cfg.deinit(allocator);

        var out = AppVenomHost{
            .allocator = allocator,
            .control_url = try allocator.dupe(u8, control_url),
            .auth_token = try allocator.dupe(u8, auth_token),
            .node_name = try allocator.dupe(u8, identity.node_name),
            .node_id = try allocator.dupe(u8, identity.node_id),
            .node_secret = try allocator.dupe(u8, identity.node_secret),
            .fs_root_path = try std.fs.cwd().realpathAlloc(allocator, "."),
            .service = undefined,
            .chat_wasm_backend = cloned_chat_wasm_backend,
        };
        errdefer {
            allocator.free(out.control_url);
            allocator.free(out.auth_token);
            allocator.free(out.node_name);
            allocator.free(out.node_id);
            allocator.free(out.node_secret);
            allocator.free(out.fs_root_path);
            if (out.chat_wasm_backend) |*cfg| cfg.deinit(allocator);
        }
        out.service = try shared_node.fs_node_service.NodeService.initWithOptions(
            allocator,
            &[_]shared_node.fs_node_ops.ExportSpec{
                .{
                    .name = "fs",
                    .path = out.fs_root_path,
                    .ro = false,
                },
                .{
                    .name = "chat",
                    .path = "chat",
                    .source_kind = .namespace,
                    .source_id = "capabilities",
                    .ro = false,
                },
                .{
                    .name = "jobs",
                    .path = "jobs",
                    .source_kind = .namespace,
                    .source_id = "jobs",
                    .ro = false,
                },
                .{
                    .name = "events",
                    .path = "events",
                    .source_kind = .namespace,
                    .source_id = "events",
                    .ro = false,
                },
                .{
                    .name = "thoughts",
                    .path = "thoughts",
                    .source_kind = .namespace,
                    .source_id = "thoughts",
                    .ro = false,
                },
            },
            .{
                .chat_input_hook = .{
                    .ctx = null,
                    .on_submit = onChatSubmit,
                },
            },
        );
        return out;
    }

    pub fn deinit(self: *AppVenomHost) void {
        self.requestStop();
        if (self.thread) |thread| thread.join();
        self.service.deinit();
        if (self.chat_wasm_backend) |*cfg| cfg.deinit(self.allocator);
        self.allocator.free(self.control_url);
        self.allocator.free(self.auth_token);
        self.allocator.free(self.node_name);
        self.allocator.free(self.node_id);
        self.allocator.free(self.node_secret);
        self.allocator.free(self.fs_root_path);
        self.* = undefined;
    }

    pub fn matches(
        self: *const AppVenomHost,
        control_url: []const u8,
        auth_token: []const u8,
        identity: control_plane.EnsuredNodeIdentity,
    ) bool {
        return std.mem.eql(u8, self.control_url, control_url) and
            std.mem.eql(u8, self.auth_token, auth_token) and
            std.mem.eql(u8, self.node_name, identity.node_name) and
            std.mem.eql(u8, self.node_id, identity.node_id) and
            std.mem.eql(u8, self.node_secret, identity.node_secret);
    }

    pub fn bindSelf(self: *AppVenomHost) void {
        if (self.service.chat_input_hook) |*hook| {
            hook.ctx = self;
        }
    }

    pub fn bootstrap(
        self: *AppVenomHost,
        client: anytype,
        message_counter: *u64,
        lease_ttl_ms: u64,
    ) !void {
        const routed_fs_url = try buildControlRoutedFsUrl(self.allocator, self.control_url, self.node_id);
        defer self.allocator.free(routed_fs_url);

        const lease_payload = try buildNodeLeaseRefreshPayload(
            self.allocator,
            self.node_id,
            self.node_secret,
            routed_fs_url,
            lease_ttl_ms,
        );
        defer self.allocator.free(lease_payload);
        const lease_response = try control_plane.requestControlPayloadJson(
            self.allocator,
            client,
            message_counter,
            "control.node_lease_refresh",
            lease_payload,
        );
        defer self.allocator.free(lease_response);

        const upsert_payload = try self.buildVenomUpsertPayload();
        defer self.allocator.free(upsert_payload);
        const upsert_response = try control_plane.requestControlPayloadJson(
            self.allocator,
            client,
            message_counter,
            "control.venom_upsert",
            upsert_payload,
        );
        defer self.allocator.free(upsert_response);

        try self.seedCompanionVenomNamespaces();
        inline for ([_][]const u8{ "chat", "jobs", "events", "thoughts", "fs" }) |venom_id| {
            const bind_response = try control_plane.bindVenomProvider(
                self.allocator,
                client,
                message_counter,
                venom_id,
                self.node_id,
                "global",
                null,
                null,
            );
            defer self.allocator.free(bind_response);
        }

        if (self.thread == null) {
            self.thread = try std.Thread.spawn(.{}, tunnelThreadMain, .{self});
        }
    }

    fn buildVenomUpsertPayload(self: *AppVenomHost) ![]u8 {
        const escaped_node_id = try unified.jsonEscape(self.allocator, self.node_id);
        defer self.allocator.free(escaped_node_id);
        const escaped_node_secret = try unified.jsonEscape(self.allocator, self.node_secret);
        defer self.allocator.free(escaped_node_secret);

        const chat_endpoint = try std.fmt.allocPrint(self.allocator, "/nodes/{s}/chat", .{escaped_node_id});
        defer self.allocator.free(chat_endpoint);
        const jobs_endpoint = try std.fmt.allocPrint(self.allocator, "/nodes/{s}/jobs", .{escaped_node_id});
        defer self.allocator.free(jobs_endpoint);
        const events_endpoint = try std.fmt.allocPrint(self.allocator, "/nodes/{s}/events", .{escaped_node_id});
        defer self.allocator.free(events_endpoint);
        const thoughts_endpoint = try std.fmt.allocPrint(self.allocator, "/nodes/{s}/thoughts", .{escaped_node_id});
        defer self.allocator.free(thoughts_endpoint);
        const fs_endpoint = try std.fmt.allocPrint(self.allocator, "/nodes/{s}/fs", .{escaped_node_id});
        defer self.allocator.free(fs_endpoint);

        const chat_descriptor = try shared_node.venom_contracts.chat.renderDescriptorJson(
            self.allocator,
            chat_endpoint,
            chat_endpoint,
            jobs_endpoint,
            "spiderapp-user-chat",
        );
        defer self.allocator.free(chat_descriptor);
        const jobs_descriptor = try shared_node.venom_contracts.jobs.renderDescriptorJson(
            self.allocator,
            jobs_endpoint,
            jobs_endpoint,
            "spiderapp-user-jobs",
        );
        defer self.allocator.free(jobs_descriptor);
        const events_descriptor = try shared_node.venom_contracts.events.renderDescriptorJson(
            self.allocator,
            events_endpoint,
            events_endpoint,
            "spiderapp-user-events",
        );
        defer self.allocator.free(events_descriptor);
        const thoughts_descriptor = try shared_node.venom_contracts.thoughts.renderDescriptorJson(
            self.allocator,
            thoughts_endpoint,
            thoughts_endpoint,
            "spiderapp-user-thoughts",
        );
        defer self.allocator.free(thoughts_descriptor);
        const fs_descriptor = try shared_node.venom_contracts.fs.renderDescriptorJson(
            self.allocator,
            fs_endpoint,
            fs_endpoint,
            "spiderapp-user-fs",
            true,
            1,
        );
        defer self.allocator.free(fs_descriptor);

        return std.fmt.allocPrint(
            self.allocator,
            "{{\"node_id\":\"{s}\",\"node_secret\":\"{s}\",\"platform\":{{\"os\":\"{s}\",\"arch\":\"{s}\",\"runtime_kind\":\"spiderapp\"}},\"labels\":{{\"spider.host_type\":\"app_local\"}},\"venoms\":[{s},{s},{s},{s},{s}]}}",
            .{
                escaped_node_id,
                escaped_node_secret,
                @tagName(@import("builtin").os.tag),
                @tagName(@import("builtin").cpu.arch),
                chat_descriptor,
                jobs_descriptor,
                events_descriptor,
                thoughts_descriptor,
                fs_descriptor,
            },
        );
    }

    fn requestStop(self: *AppVenomHost) void {
        self.stop_mutex.lock();
        self.stop_requested = true;
        self.stop_mutex.unlock();
    }

    fn seedCompanionVenomNamespaces(self: *AppVenomHost) !void {
        const updates = [_]shared_node.fs_node_service.NodeService.NamespaceFileUpdate{
            .{ .source_id = "events", .path = "README.md", .content = shared_node.venom_contracts.events.readme_md, .writable = false },
            .{ .source_id = "events", .path = "SCHEMA.json", .content = shared_node.venom_contracts.events.schema_json, .writable = false },
            .{ .source_id = "events", .path = "CAPS.json", .content = shared_node.venom_contracts.events.caps_json, .writable = false },
            .{ .source_id = "events", .path = "OPS.json", .content = shared_node.venom_contracts.events.ops_json, .writable = false },
            .{ .source_id = "events", .path = "STATUS.json", .content = shared_node.venom_contracts.events.status_json, .writable = false },
            .{ .source_id = "events", .path = "control/README.md", .content = shared_node.venom_contracts.events.control_readme_md, .writable = false },
            .{ .source_id = "events", .path = "control/wait.json", .content = shared_node.venom_contracts.events.default_wait_json, .writable = true },
            .{ .source_id = "events", .path = "control/signal.json", .content = shared_node.venom_contracts.events.default_signal_json, .writable = true },
            .{ .source_id = "events", .path = "sources/README.md", .content = shared_node.venom_contracts.events.sources_readme_md, .writable = false },
            .{ .source_id = "events", .path = "sources/agent.json", .content = shared_node.venom_contracts.events.agent_source_help_md, .writable = false },
            .{ .source_id = "events", .path = "sources/hook.json", .content = shared_node.venom_contracts.events.hook_source_help_md, .writable = false },
            .{ .source_id = "events", .path = "sources/user.json", .content = shared_node.venom_contracts.events.user_source_help_md, .writable = false },
            .{ .source_id = "events", .path = "sources/time.json", .content = shared_node.venom_contracts.events.time_source_help_md, .writable = false },
            .{ .source_id = "events", .path = "next.json", .content = shared_node.venom_contracts.events.initial_next_json, .writable = false },
            .{ .source_id = "thoughts", .path = "README.md", .content = shared_node.venom_contracts.thoughts.readme_md, .writable = false },
            .{ .source_id = "thoughts", .path = "SCHEMA.json", .content = shared_node.venom_contracts.thoughts.schema_json, .writable = false },
            .{ .source_id = "thoughts", .path = "CAPS.json", .content = shared_node.venom_contracts.thoughts.caps_json, .writable = false },
            .{ .source_id = "thoughts", .path = "OPS.json", .content = shared_node.venom_contracts.thoughts.ops_json, .writable = false },
            .{ .source_id = "thoughts", .path = "latest.txt", .content = "", .writable = false },
            .{ .source_id = "thoughts", .path = "history.ndjson", .content = "", .writable = false },
            .{ .source_id = "thoughts", .path = "status.json", .content = shared_node.venom_contracts.thoughts.initial_status_json, .writable = false },
        };
        const events = try self.service.upsertNamespaceFilesWithEvents(&updates);
        defer self.allocator.free(events);
    }

    fn shouldStop(self: *AppVenomHost) bool {
        self.stop_mutex.lock();
        defer self.stop_mutex.unlock();
        return self.stop_requested;
    }

    fn nextJobId(self: *AppVenomHost) ![]u8 {
        self.job_mutex.lock();
        const seq = self.next_job_seq;
        self.next_job_seq += 1;
        self.job_mutex.unlock();
        return std.fmt.allocPrint(self.allocator, "app-chat-{d}", .{seq});
    }

    fn onChatSubmit(
        ctx: ?*anyopaque,
        allocator: std.mem.Allocator,
        input: []const u8,
        correlation_id: ?[]const u8,
    ) anyerror!shared_node.fs_node_service.NodeService.ChatInputSubmission {
        const self: *AppVenomHost = @ptrCast(@alignCast(ctx orelse return error.InvalidContext));
        const job_id = try self.nextJobId();
        errdefer allocator.free(job_id);
        if (self.chat_wasm_backend) |*backend| {
            return shared_node.wasm_chat_backend.buildSubmission(
                allocator,
                backend.asConfig(),
                job_id,
                input,
                correlation_id,
            );
        }

        const corr_copy = if (correlation_id) |value| try allocator.dupe(u8, value) else null;
        errdefer if (corr_copy) |value| allocator.free(value);
        const result_text = try allocator.dupe(u8, input);
        errdefer allocator.free(result_text);
        const log_text = try buildSessionReceiveLog(allocator, correlation_id orelse job_id, input);
        errdefer allocator.free(log_text);
        return .{
            .job_id = job_id,
            .correlation_id = corr_copy,
            .state = .done,
            .result_text = result_text,
            .log_text = log_text,
        };
    }

    fn tunnelThreadMain(self: *AppVenomHost) void {
        self.runTunnel() catch |err| {
            std.log.warn("SpiderApp Venom host tunnel stopped: {s}", .{@errorName(err)});
        };
    }

    fn runTunnel(self: *AppVenomHost) !void {
        const parsed = try parseWsUrlWithDefaultPath(self.allocator, self.control_url, "/");
        defer parsed.deinit(self.allocator);
        const tunnel_path = try joinControlPath(self.allocator, parsed.path, "/v2/node");
        defer self.allocator.free(tunnel_path);

        var client = try ws.Client.init(self.allocator, .{
            .host = parsed.host,
            .port = parsed.port,
            .tls = parsed.tls,
            .max_size = tunnel_max_frame_bytes,
            .buffer_size = 64 * 1024,
        });
        defer client.deinit();

        var headers_buf: [512]u8 = undefined;
        const headers = if (self.auth_token.len > 0)
            try std.fmt.bufPrint(&headers_buf, "Authorization: Bearer {s}\r\n", .{self.auth_token})
        else
            null;
        try client.handshake(tunnel_path, .{
            .timeout_ms = 10_000,
            .headers = headers,
        });
        try client.readTimeout(1);
        try negotiateNodeTunnelHello(self.allocator, &client, self.node_id, self.node_secret);

        while (!self.shouldStop()) {
            const maybe_message = client.read() catch |err| switch (err) {
                error.WouldBlock => {
                    std.Thread.sleep(@as(u64, @intCast(tunnel_poll_timeout_ms)) * std.time.ns_per_ms);
                    continue;
                },
                error.Closed, error.ConnectionResetByPeer => return,
                else => return err,
            };
            const message = maybe_message orelse {
                std.Thread.sleep(@as(u64, @intCast(tunnel_poll_timeout_ms)) * std.time.ns_per_ms);
                continue;
            };
            defer client.done(message);

            switch (message.type) {
                .text => {
                    var handled = self.service.handleRequestJsonWithEvents(message.data) catch |handle_err| blk: {
                        const fallback = try unified.buildFsrpcFsError(
                            self.allocator,
                            null,
                            fs_protocol.Errno.EIO,
                            @errorName(handle_err),
                        );
                        break :blk shared_node.fs_node_service.NodeService.HandledRequest{
                            .response_json = fallback,
                            .events = try self.allocator.alloc(fs_protocol.InvalidationEvent, 0),
                        };
                    };
                    defer handled.deinit(self.allocator);

                    for (handled.events) |event| {
                        const event_json = try shared_node.fs_node_service.buildInvalidationEventJson(self.allocator, event);
                        defer self.allocator.free(event_json);
                        try client.write(@constCast(event_json));
                    }
                    try client.write(@constCast(handled.response_json));
                },
                .close => {
                    client.close(.{}) catch {};
                    return;
                },
                .ping => try client.writePong(@constCast(message.data)),
                .pong, .binary => {},
            }
        }
    }
};

pub fn loadChatWasmBackendFromEnv(allocator: std.mem.Allocator) !?shared_node.wasm_chat_backend.OwnedConfig {
    const module_path = std.process.getEnvVarOwned(allocator, "SPIDERAPP_CHAT_WASM_MODULE") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => return null,
        else => return err,
    };
    errdefer allocator.free(module_path);

    const entrypoint = std.process.getEnvVarOwned(allocator, "SPIDERAPP_CHAT_WASM_ENTRYPOINT") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => null,
        else => return err,
    };
    errdefer if (entrypoint) |value| allocator.free(value);

    const max_output_bytes = blk: {
        const raw = std.process.getEnvVarOwned(allocator, "SPIDERAPP_CHAT_WASM_MAX_OUTPUT") catch |err| switch (err) {
            error.EnvironmentVariableNotFound => break :blk 256 * 1024,
            else => return err,
        };
        defer allocator.free(raw);
        break :blk try std.fmt.parseInt(usize, raw, 10);
    };
    const timeout_ms = blk: {
        const raw = std.process.getEnvVarOwned(allocator, "SPIDERAPP_CHAT_WASM_TIMEOUT_MS") catch |err| switch (err) {
            error.EnvironmentVariableNotFound => break :blk @as(u64, 30_000),
            else => return err,
        };
        defer allocator.free(raw);
        break :blk try std.fmt.parseInt(u64, raw, 10);
    };
    const fuel = blk: {
        const raw = std.process.getEnvVarOwned(allocator, "SPIDERAPP_CHAT_WASM_FUEL") catch |err| switch (err) {
            error.EnvironmentVariableNotFound => break :blk null,
            else => return err,
        };
        defer allocator.free(raw);
        break :blk @as(?u64, try std.fmt.parseInt(u64, raw, 10));
    };
    const max_memory_bytes = blk: {
        const raw = std.process.getEnvVarOwned(allocator, "SPIDERAPP_CHAT_WASM_MAX_MEMORY_BYTES") catch |err| switch (err) {
            error.EnvironmentVariableNotFound => break :blk null,
            else => return err,
        };
        defer allocator.free(raw);
        break :blk @as(?u64, try std.fmt.parseInt(u64, raw, 10));
    };

    return .{
        .module_path = module_path,
        .entrypoint = entrypoint,
        .timeout_ms = timeout_ms,
        .fuel = fuel,
        .max_memory_bytes = max_memory_bytes,
        .max_output_bytes = max_output_bytes,
    };
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

fn buildNodeLeaseRefreshPayload(
    allocator: std.mem.Allocator,
    node_id: []const u8,
    node_secret: []const u8,
    fs_url: []const u8,
    lease_ttl_ms: u64,
) ![]u8 {
    const escaped_node_id = try unified.jsonEscape(allocator, node_id);
    defer allocator.free(escaped_node_id);
    const escaped_node_secret = try unified.jsonEscape(allocator, node_secret);
    defer allocator.free(escaped_node_secret);
    const escaped_fs_url = try unified.jsonEscape(allocator, fs_url);
    defer allocator.free(escaped_fs_url);
    return std.fmt.allocPrint(
        allocator,
        "{{\"node_id\":\"{s}\",\"node_secret\":\"{s}\",\"fs_url\":\"{s}\",\"lease_ttl_ms\":{d}}}",
        .{ escaped_node_id, escaped_node_secret, escaped_fs_url, lease_ttl_ms },
    );
}

fn buildSessionReceiveLog(
    allocator: std.mem.Allocator,
    request_id: []const u8,
    content: []const u8,
) ![]u8 {
    const escaped_request = try unified.jsonEscape(allocator, request_id);
    defer allocator.free(escaped_request);
    const escaped_content = try unified.jsonEscape(allocator, content);
    defer allocator.free(escaped_content);
    return std.fmt.allocPrint(
        allocator,
        "{{\"type\":\"session.receive\",\"request\":\"{s}\",\"timestamp\":{d},\"content\":\"{s}\",\"role\":\"assistant\",\"final\":true}}\n",
        .{ escaped_request, std.time.milliTimestamp(), escaped_content },
    );
}

fn parseWsUrlWithDefaultPath(
    allocator: std.mem.Allocator,
    url: []const u8,
    default_path: []const u8,
) !ParsedUrl {
    const ws_prefix = "ws://";
    const wss_prefix = "wss://";

    var remaining: []const u8 = undefined;
    var default_port: u16 = 18790;
    var tls = false;
    if (std.mem.startsWith(u8, url, wss_prefix)) {
        remaining = url[wss_prefix.len..];
        default_port = 443;
        tls = true;
    } else if (std.mem.startsWith(u8, url, ws_prefix)) {
        remaining = url[ws_prefix.len..];
    } else {
        return error.InvalidUrl;
    }

    const path_start = std.mem.indexOfScalar(u8, remaining, '/');
    const host_port = if (path_start) |idx| remaining[0..idx] else remaining;
    const path = if (path_start) |idx|
        try allocator.dupe(u8, remaining[idx..])
    else
        try allocator.dupe(u8, default_path);
    errdefer allocator.free(path);

    const port_start = std.mem.lastIndexOfScalar(u8, host_port, ':');
    const host = if (port_start) |idx|
        try allocator.dupe(u8, host_port[0..idx])
    else
        try allocator.dupe(u8, host_port);
    errdefer allocator.free(host);
    const port = if (port_start) |idx|
        try std.fmt.parseInt(u16, host_port[idx + 1 ..], 10)
    else
        default_port;

    return .{ .host = host, .port = port, .path = path, .tls = tls };
}

fn negotiateNodeTunnelHello(
    allocator: std.mem.Allocator,
    client: *ws.Client,
    node_id: []const u8,
    node_secret: []const u8,
) !void {
    const escaped_node_id = try unified.jsonEscape(allocator, node_id);
    defer allocator.free(escaped_node_id);
    const escaped_node_secret = try unified.jsonEscape(allocator, node_secret);
    defer allocator.free(escaped_node_secret);
    const hello_request = try std.fmt.allocPrint(
        allocator,
        "{{\"channel\":\"acheron\",\"type\":\"acheron.t_fs_hello\",\"tag\":1,\"payload\":{{\"protocol\":\"unified-v2-fs\",\"proto\":2,\"node_id\":\"{s}\",\"node_secret\":\"{s}\"}}}}",
        .{ escaped_node_id, escaped_node_secret },
    );
    defer allocator.free(hello_request);

    try client.write(@constCast(hello_request));
    const deadline_ms = std.time.milliTimestamp() + @as(i64, control_reply_timeout_ms);
    while (true) {
        const now_ms = std.time.milliTimestamp();
        if (now_ms >= deadline_ms) return error.ControlRequestTimeout;
        const remaining_i64 = deadline_ms - now_ms;
        const timeout_ms: u32 = @intCast(@min(remaining_i64, @as(i64, std.math.maxInt(u32))));
        try client.readTimeout(timeout_ms);
        const maybe_message = client.read() catch |err| switch (err) {
            error.WouldBlock => return error.ControlRequestTimeout,
            error.Closed, error.ConnectionResetByPeer => return error.ConnectionClosed,
            else => return err,
        };
        const message = maybe_message orelse return error.ControlRequestTimeout;
        defer client.done(message);

        switch (message.type) {
            .text => {
                var parsed = try unified.parseMessage(allocator, message.data);
                defer parsed.deinit(allocator);
                if (parsed.channel != .acheron) continue;
                if (parsed.tag == null or parsed.tag.? != 1) continue;
                const msg_type = parsed.acheron_type orelse continue;
                if (msg_type == .fs_r_hello) return;
                if (msg_type == .fs_err) return error.ControlRequestFailed;
            },
            .close => return error.ConnectionClosed,
            .ping => try client.writePong(@constCast(message.data)),
            .pong, .binary => {},
        }
    }
}

fn joinControlPath(
    allocator: std.mem.Allocator,
    base_path: []const u8,
    suffix: []const u8,
) ![]u8 {
    const trimmed_base = std.mem.trimRight(u8, base_path, "/");
    const normalized_base = if (trimmed_base.len == 0) "/" else trimmed_base;
    const trimmed_suffix = std.mem.trimLeft(u8, suffix, "/");
    if (std.mem.eql(u8, normalized_base, "/")) {
        return std.fmt.allocPrint(allocator, "/{s}", .{trimmed_suffix});
    }
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ normalized_base, trimmed_suffix });
}

test "app venom host builds routed fs url and chat upsert payload" {
    const allocator = std.testing.allocator;
    const routed = try buildControlRoutedFsUrl(allocator, "ws://127.0.0.1:18790/", "node-7");
    defer allocator.free(routed);
    try std.testing.expectEqualStrings("ws://127.0.0.1:18790/v2/fs/node/node-7", routed);

    const routed_with_base = try buildControlRoutedFsUrl(allocator, "wss://example.com/spider/control", "node-8");
    defer allocator.free(routed_with_base);
    try std.testing.expectEqualStrings("wss://example.com:443/spider/control/v2/fs/node/node-8", routed_with_base);

    var host = try AppVenomHost.init(
        allocator,
        "ws://127.0.0.1:18790",
        "token",
        .{
            .node_id = try allocator.dupe(u8, "node-7"),
            .node_name = try allocator.dupe(u8, "spiderapp-default"),
            .node_secret = try allocator.dupe(u8, "secret-7"),
        },
    );
    defer host.deinit();

    const payload = try host.buildVenomUpsertPayload();
    defer allocator.free(payload);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"venom_id\":\"chat\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"venom_id\":\"jobs\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"venom_id\":\"events\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"venom_id\":\"thoughts\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"venom_id\":\"fs\"") != null);
}
