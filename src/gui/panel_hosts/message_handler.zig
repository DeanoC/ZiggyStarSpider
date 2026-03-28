// message_handler.zig — Incoming message handling and session/streaming message state functions.

const std = @import("std");
const zui = @import("ziggy-ui");
const protocol_messages = @import("../protocol_messages.zig");

const SessionMessageState = @import("../root.zig").SessionMessageState;
const ChatMessage = zui.protocol.types.ChatMessage;
const ChatMessageState = zui.protocol.types.LocalChatMessageState;

pub fn handleDebugEventMessage(self: anytype, root_map: std.json.ObjectMap) !void {
    const timestamp = if (root_map.get("timestamp")) |value| switch (value) {
        .integer => value.integer,
        else => std.time.milliTimestamp(),
    } else std.time.milliTimestamp();
    const category = if (root_map.get("category")) |value| switch (value) {
        .string => value.string,
        else => "unknown",
    } else "unknown";

    // Render payload directly to keep debug streaming resilient for large/complex payloads.
    const payload_json = if (root_map.get("payload")) |payload| blk: {
        if (self.formatDebugPayloadJson(payload)) |pretty| break :blk pretty else |_| {
            break :blk try self.allocator.dupe(u8, "{\"error\":\"failed to format debug payload\"}");
        }
    } else try self.allocator.dupe(u8, "{}");
    defer self.allocator.free(payload_json);

    const payload_obj = if (root_map.get("payload")) |payload| switch (payload) {
        .object => payload.object,
        else => null,
    } else null;
    const correlation_id = extractCorrelationId(root_map, payload_obj);
    try self.appendDebugEvent(timestamp, category, correlation_id, payload_json);
}

pub fn handleNodeServiceEventMessage(self: anytype, root_map: std.json.ObjectMap) !void {
    const timestamp = if (root_map.get("timestamp")) |value| switch (value) {
        .integer => value.integer,
        else => std.time.milliTimestamp(),
    } else if (root_map.get("timestamp_ms")) |value| switch (value) {
        .integer => value.integer,
        else => std.time.milliTimestamp(),
    } else std.time.milliTimestamp();

    const payload_value = root_map.get("payload") orelse {
        try self.appendDebugEvent(timestamp, "control.node_service_event", null, "{}");
        return;
    };
    const payload_json = if (self.formatDebugPayloadJson(payload_value)) |pretty|
        pretty
    else |_|
        try self.allocator.dupe(u8, "{\"error\":\"failed to format node service payload\"}");
    defer self.allocator.free(payload_json);

    const payload_obj = if (payload_value == .object) payload_value.object else null;
    const correlation_id = extractCorrelationId(root_map, payload_obj);
    try self.appendDebugEvent(timestamp, "control.node_service_event", correlation_id, payload_json);

    if (try self.buildNodeServiceDeltaDiagnosticsTextFromValue(payload_value)) |diag| {
        self.clearNodeServiceReloadDiagnostics();
        self.debug.node_service_latest_reload_diag = diag;
    }
}

pub fn handleIncomingMessage(self: anytype, msg: []const u8) !void {
    const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, msg, .{}) catch |err| {
        self.recordDecodeError(@errorName(err), msg) catch {};
        return;
    };
    defer parsed.deinit();
    if (parsed.value != .object) {
        self.recordDecodeError("non-object json", msg) catch {};
        return;
    }
    const root_map = parsed.value.object;

    const mt = if (root_map.get("type")) |type_value| switch (type_value) {
        .string => protocol_messages.classifyTypeString(type_value.string),
        else => protocol_messages.parseMessageType(msg) orelse return,
    } else protocol_messages.parseMessageType(msg) orelse return;
    switch (mt) {
        .session_receive => {
            const payload = if (root_map.get("payload")) |payload| switch (payload) {
                .object => payload.object,
                else => root_map,
            } else root_map;

            const request_id = if (root_map.get("request_id")) |value| switch (value) {
                .string => value.string,
                else => null,
            } else if (payload.get("request_id")) |value| switch (value) {
                .string => value.string,
                else => null,
            } else if (root_map.get("request")) |value| switch (value) {
                .string => value.string,
                else => null,
            } else if (payload.get("request")) |value| switch (value) {
                .string => value.string,
                else => null,
            } else if (root_map.get("id")) |value| switch (value) {
                .string => value.string,
                else => null,
            } else if (payload.get("id")) |value| switch (value) {
                .string => value.string,
                else => null,
            } else null;
            const session_key = if (payload.get("session_key")) |value| switch (value) {
                .string => value.string,
                else => null,
            } else if (root_map.get("session_key")) |value| switch (value) {
                .string => value.string,
                else => null,
            } else if (payload.get("sessionKey")) |value| switch (value) {
                .string => value.string,
                else => null,
            } else if (root_map.get("sessionKey")) |value| switch (value) {
                .string => value.string,
                else => null,
            } else null;
            if (session_key) |sk| {
                self.ensureSessionInList(sk, sk) catch {};
            }
            const role = if (payload.get("role")) |value| switch (value) {
                .string => value.string,
                else => "assistant",
            } else "assistant";
            const timestamp = if (root_map.get("timestamp")) |value| switch (value) {
                .integer => value.integer,
                else => std.time.milliTimestamp(),
            } else if (payload.get("timestamp")) |value| switch (value) {
                .integer => value.integer,
                else => std.time.milliTimestamp(),
            } else std.time.milliTimestamp();
            const content = if (payload.get("content")) |value| switch (value) {
                .string => value.string,
                else => "",
            } else "";
            const content_delta = if (payload.get("content_delta")) |value| switch (value) {
                .string => value.string,
                else => null,
            } else null;
            const final = if (payload.get("final")) |value| switch (value) {
                .bool => value.bool,
                else => true,
            } else true;
            if (request_id) |req_id| {
                if (self.chat.pending_send_request_id) |pending| {
                    if (std.mem.eql(u8, pending, req_id)) {
                        if (self.chat.pending_send_message_id) |msg_id| {
                            self.setMessageState(msg_id, null) catch {};
                        }
                        if (session_key) |sk| {
                            if (self.chat.current_session_key) |current| {
                                if (!std.mem.eql(u8, current, sk)) {
                                    self.setCurrentSessionKey(sk) catch {};
                                }
                            } else {
                                self.setCurrentSessionKey(sk) catch {};
                            }
                        }
                    }
                }
            }

            if (content_delta) |delta| {
                try appendOrUpdateStreamingMessage(self, request_id, session_key, delta, false, timestamp);
                return;
            }
            if (content.len > 0) {
                if (request_id != null) {
                    const is_final = final;
                    try appendOrUpdateStreamingMessage(self, request_id, session_key, content, is_final, timestamp);
                } else {
                    try appendMessageWithState(self, role, content, null, null);
                }
            }
        },
        .connect_ack => {
            const request_id = if (root_map.get("request_id")) |value| switch (value) {
                .string => value.string,
                else => null,
            } else if (root_map.get("request")) |value| switch (value) {
                .string => value.string,
                else => null,
            } else if (root_map.get("id")) |value| switch (value) {
                .string => value.string,
                else => null,
            } else null;

            if (request_id) |rid| {
                if (self.chat.pending_send_request_id) |pending| {
                    if (std.mem.eql(u8, pending, rid)) {
                        if (self.chat.pending_send_message_id) |message_id| {
                            self.setMessageState(message_id, null) catch {};
                        }
                        self.clearPendingSend();
                    }
                }
            }
        },
        .error_response => {
            const payload = if (root_map.get("payload")) |payload| switch (payload) {
                .object => payload.object,
                else => root_map,
            } else root_map;
            const err_message = if (payload.get("message")) |value| switch (value) {
                .string => value.string,
                else => "Unknown error",
            } else if (root_map.get("error")) |value| switch (value) {
                .object => if (value.object.get("message")) |err_msg| switch (err_msg) {
                    .string => err_msg.string,
                    else => "Unknown error",
                } else "Unknown error",
                else => "Unknown error",
            } else "Unknown error";
            const err_code = if (payload.get("code")) |value| switch (value) {
                .string => value.string,
                else => null,
            } else if (root_map.get("error")) |value| switch (value) {
                .object => if (value.object.get("code")) |err_code_value| switch (err_code_value) {
                    .string => err_code_value.string,
                    else => null,
                } else null,
                else => null,
            } else null;
            if (extractRequestId(root_map, payload)) |request_id| {
                if (self.chat.pending_send_request_id) |pending| {
                    if (std.mem.eql(u8, pending, request_id)) {
                        if (self.chat.pending_send_message_id) |message_id| {
                            self.setMessageFailed(message_id) catch {};
                        }
                        self.clearPendingSend();
                    }
                }
            }
            const detail = if (err_code) |code|
                try std.fmt.allocPrint(self.allocator, "{s} [{s}]", .{ err_message, code })
            else
                try self.allocator.dupe(u8, err_message);
            defer self.allocator.free(detail);
            try appendMessage(self, "system", detail, null);
        },
        else => {
            if (self.connection_state == .connected) {
                return;
            }
            try appendMessage(self, "system", "Unhandled message", null);
        },
    }
}

pub fn appendOrUpdateStreamingMessage(
    self: anytype,
    request_id: ?[]const u8,
    session_key_opt: ?[]const u8,
    chunk: []const u8,
    final: bool,
    timestamp: i64,
) !void {
    // Best-effort: unescape common JSON escapes for display ONLY if chunk starts and ends with quotes,
    // which strongly suggests it's a JSON-encoded string literal.
    var use = chunk;
    var owned = false;
    if (chunk.len >= 2 and chunk[0] == '"' and chunk[chunk.len - 1] == '"') {
        if (looksLikeEscaped(chunk)) {
            if (self.unescapeJsonStringAlloc(chunk)) |tmp| {
                use = tmp;
                owned = true;
            } else |_| {}
        }
    }
    defer if (owned) self.allocator.free(use);

    const target_session = if (request_id) |request| blk: {
        if (self.chat.pending_send_request_id) |pending| {
            if (std.mem.eql(u8, pending, request)) {
                if (self.chat.pending_send_session_key) |key| break :blk key;
            }
        }
        break :blk session_key_opt;
    } else session_key_opt;

    const target = target_session orelse try self.currentSessionOrDefault();

    if (request_id) |request| {
        const state = try getSessionMessageState(self, target);

        if (state.streaming_request_id) |existing_request| {
            if (!std.mem.eql(u8, existing_request, request)) {
                clearSessionStreamingState(self, state);
            }
        }

        if (state.streaming_request_id == null) {
            try setSessionStreamingRequest(self, state, request);
        }

        const stream_id = try makeStreamingMessageId(self, request);
        defer self.allocator.free(stream_id);

        if (findMessageIndex(self, target, stream_id)) |idx| {
            if (final) {
                try setMessageContentByIndex(self, target, idx, use);
            } else {
                try appendToMessage(self, target, idx, use);
            }
            if (state.messages.items.len > idx) {
                state.messages.items[idx].timestamp = timestamp;
            }
        } else {
            const new_id = try appendMessageWithIdForSession(self, target, "assistant", use, null, stream_id);
            self.allocator.free(new_id);
        }

        if (self.chat.pending_send_request_id) |pending| {
            if (std.mem.eql(u8, pending, request)) {
                if (self.chat.pending_send_message_id) |msg_id| {
                    self.setMessageState(msg_id, null) catch {};
                }
                if (final) {
                    clearSessionStreamingState(self, state);
                    self.clearPendingSend();
                }
            }
        }

        if (final) {
            clearSessionStreamingState(self, state);
        }
        return;
    }

    try appendMessageForSession(self, target, "assistant", use, null);
}

pub fn findSessionMessageState(self: anytype, key: []const u8) ?*SessionMessageState {
    for (self.chat.session_messages.items) |*state| {
        if (std.mem.eql(u8, state.key, key)) return state;
    }
    return null;
}

pub fn getSessionMessageState(self: anytype, key: []const u8) !*SessionMessageState {
    if (findSessionMessageState(self, key)) |state| return state;
    const key_copy = try self.allocator.dupe(u8, key);
    try self.chat.session_messages.append(self.allocator, .{
        .key = key_copy,
        .messages = .empty,
    });
    return &self.chat.session_messages.items[self.chat.session_messages.items.len - 1];
}

pub fn makeStreamingMessageId(self: anytype, request_id: []const u8) ![]const u8 {
    return std.fmt.allocPrint(self.allocator, "stream:{s}", .{request_id});
}

pub fn setSessionStreamingRequest(self: anytype, state: *SessionMessageState, request_id: []const u8) !void {
    if (state.streaming_request_id) |existing_request| {
        if (std.mem.eql(u8, existing_request, request_id)) {
            return;
        }
        self.allocator.free(existing_request);
    }
    state.streaming_request_id = try self.allocator.dupe(u8, request_id);
}

pub fn clearSessionStreamingState(self: anytype, state: *SessionMessageState) void {
    if (state.streaming_request_id) |existing_request| {
        self.allocator.free(existing_request);
        state.streaming_request_id = null;
    }
}

pub fn setMessageContentByIndex(self: anytype, session_key: []const u8, index: usize, content: []const u8) !void {
    const state = try getSessionMessageState(self, session_key);
    if (index >= state.messages.items.len) return;
    const msg = &state.messages.items[index];
    self.allocator.free(msg.content);
    msg.content = try self.allocator.dupe(u8, content);
}

pub fn appendToMessage(self: anytype, session_key: []const u8, index: usize, content: []const u8) !void {
    const state = try getSessionMessageState(self, session_key);
    var msg = &state.messages.items[index];
    const old_content = msg.content;
    const new_len = old_content.len + content.len;
    var combined = try self.allocator.alloc(u8, new_len);
    @memcpy(combined[0..old_content.len], old_content);
    @memcpy(combined[old_content.len..new_len], content);
    msg.content = combined;
    self.allocator.free(old_content);
}

pub fn findMessageIndex(self: anytype, session_key: []const u8, message_id: []const u8) ?usize {
    const state = findSessionMessageState(self, session_key) orelse return null;
    for (state.messages.items, 0..) |*msg, idx| {
        if (std.mem.eql(u8, msg.id, message_id)) return idx;
    }
    return null;
}

pub fn removeMessageById(self: anytype, session_key: []const u8, message_id: []const u8) void {
    const state = findSessionMessageState(self, session_key) orelse return;
    const idx = findMessageIndex(self, session_key, message_id) orelse return;
    var removed = state.messages.orderedRemove(idx);
    freeMessage(self, &removed);
}

pub fn clearPendingThoughtMessage(self: anytype) void {
    if (self.chat.pending_send_thought_message_id) |message_id| {
        if (self.chat.pending_send_session_key) |session_key| {
            removeMessageById(self, session_key, message_id);
        }
        self.allocator.free(message_id);
        self.chat.pending_send_thought_message_id = null;
    }
}

pub fn appendMessage(self: anytype, role: []const u8, content: []const u8, local_state: ?ChatMessageState) !void {
    const session_key = try self.currentSessionOrDefault();
    const id = try appendMessageWithIdForSession(self, session_key, role, content, local_state, "");
    self.allocator.free(id);
}

pub fn appendMessageForSession(
    self: anytype,
    session_key: []const u8,
    role: []const u8,
    content: []const u8,
    local_state: ?ChatMessageState,
) !void {
    const id = try appendMessageWithIdForSession(self, session_key, role, content, local_state, "");
    self.allocator.free(id);
}

pub fn appendMessageWithId(
    self: anytype,
    role: []const u8,
    content: []const u8,
    local_state: ?ChatMessageState,
    id_override: []const u8,
) ![]const u8 {
    const session_key = try self.currentSessionOrDefault();
    return appendMessageWithIdForSession(self, session_key, role, content, local_state, id_override);
}

pub fn appendMessageWithIdForSession(
    self: anytype,
    session_key: []const u8,
    role: []const u8,
    content: []const u8,
    local_state: ?ChatMessageState,
    id_override: []const u8,
) ![]const u8 {
    const id = if (id_override.len > 0) try self.allocator.dupe(u8, id_override) else try self.nextMessageId("msg");
    errdefer self.allocator.free(id);

    const state = try getSessionMessageState(self, session_key);
    try state.messages.append(self.allocator, .{
        .id = try self.allocator.dupe(u8, id),
        .role = try self.allocator.dupe(u8, role),
        .content = try self.allocator.dupe(u8, content),
        .timestamp = std.time.milliTimestamp(),
        .attachments = null,
        .local_state = local_state,
    });

    if (state.messages.items.len > 500) {
        var oldest = state.messages.orderedRemove(0);
        if (state.streaming_request_id) |stream_request_id| {
            if (std.mem.startsWith(u8, oldest.id, "stream:")) {
                const oldest_request_id = oldest.id["stream:".len..];
                if (std.mem.eql(u8, oldest_request_id, stream_request_id)) {
                    self.allocator.free(stream_request_id);
                    state.streaming_request_id = null;
                }
            }
        }
        if (self.chat.pending_send_message_id) |pending_message_id| {
            if (std.mem.eql(u8, pending_message_id, oldest.id)) {
                self.allocator.free(pending_message_id);
                self.chat.pending_send_message_id = null;
            }
        }
        freeMessage(self, &oldest);
    }

    return id;
}

pub fn appendMessageWithState(
    self: anytype,
    role: []const u8,
    content: []const u8,
    local_state: ?ChatMessageState,
    id_override: ?[]const u8,
) !void {
    if (id_override) |id| {
        const id_out = try appendMessageWithId(self, role, content, local_state, id);
        self.allocator.free(id_out);
        return;
    }
    return appendMessage(self, role, content, local_state);
}

pub fn freeMessage(self: anytype, msg: *ChatMessage) void {
    self.allocator.free(msg.id);
    self.allocator.free(msg.role);
    self.allocator.free(msg.content);

    if (msg.attachments) |attachments| {
        for (attachments) |attachment| {
            self.allocator.free(attachment.kind);
            self.allocator.free(attachment.url);
            if (attachment.name) |name| self.allocator.free(name);
        }
        self.allocator.free(attachments);
    }
}

pub fn clearAllMessages(self: anytype) void {
    for (self.chat.session_messages.items) |*state| {
        clearSessionStreamingState(self, state);
        for (state.messages.items) |*msg| {
            freeMessage(self, msg);
        }
        state.messages.clearRetainingCapacity();
    }
}

pub fn clearSessions(self: anytype) void {
    clearAllMessages(self);

    if (self.chat.current_session_key) |current_session| {
        self.allocator.free(current_session);
        self.chat.current_session_key = null;
    }
    for (self.chat.chat_sessions.items) |session| {
        self.allocator.free(session.key);
        if (session.display_name) |name| self.allocator.free(name);
    }
    self.chat.chat_sessions.clearRetainingCapacity();

    for (self.chat.session_messages.items) |*state| {
        state.messages.deinit(self.allocator);
        self.allocator.free(state.key);
        if (state.streaming_request_id) |rid| self.allocator.free(rid);
    }
    self.chat.session_messages.clearRetainingCapacity();
}

// --- Private helpers (not methods, no self parameter) ---

fn looksLikeEscaped(s: []const u8) bool {
    var i: usize = 0;
    while (i + 1 < s.len) : (i += 1) {
        if (s[i] == '\\') {
            const next_ch = s[i + 1];
            switch (next_ch) {
                'n', 'r', 't', '"', '\\' => return true,
                'u' => return true, // unicode escape
                else => {},
            }
        }
    }
    return false;
}

fn extractRequestId(root_map: std.json.ObjectMap, payload: std.json.ObjectMap) ?[]const u8 {
    if (root_map.get("request_id")) |value| {
        if (value == .string) return value.string;
    }
    if (payload.get("request_id")) |value| {
        if (value == .string) return value.string;
    }
    if (root_map.get("request")) |value| {
        if (value == .string) return value.string;
    }
    if (payload.get("request")) |value| {
        if (value == .string) return value.string;
    }
    if (root_map.get("id")) |value| {
        if (value == .string) return value.string;
    }
    if (payload.get("id")) |value| {
        if (value == .string) return value.string;
    }
    return null;
}

fn extractCorrelationId(root_map: std.json.ObjectMap, payload: ?std.json.ObjectMap) ?[]const u8 {
    if (root_map.get("correlation_id")) |value| {
        if (value == .string and value.string.len > 0) return value.string;
    }
    if (payload) |obj| {
        if (obj.get("correlation_id")) |value| {
            if (value == .string and value.string.len > 0) return value.string;
        }
    }
    return extractRequestId(root_map, payload orelse root_map);
}
