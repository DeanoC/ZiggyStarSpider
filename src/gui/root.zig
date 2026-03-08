const std = @import("std");
const zui = @import("ziggy-ui");
const zui_panels = @import("ziggy-ui-panels");
const ws_client_mod = @import("websocket_client.zig");
const config_mod = @import("client-config");
const credential_store_mod = config_mod.credential_store;
const control_plane = @import("control_plane");
const venom_bindings = @import("venom_bindings");
const build_options = @import("build_options");
const workspace_types = control_plane.workspace_types;
const panels_bridge = @import("panels_bridge.zig");
const stage_machine = @import("stage_machine.zig");

const zapp = zui.ui.app;
const c = zapp.sdl_app.c;

const widgets = zui.widgets;
const zcolors = zui.theme.colors;
const ui_draw_context = zui.ui.draw_context;
const ui_input_router = zui.ui.input.input_router;
const ui_input_state = zui.ui.input.input_state;
const ui_input_backend = zui.ui.input.input_backend;
const ui_sdl_input_backend = zui.ui.input.sdl_input_backend;
const ui_command_inbox = zui.ui.ui_command_inbox;
const ui_command_queue = zui.ui.render.command_queue;
const client_state = zui.client.state;
const client_agents = zui.client.agent_registry;
const font_system = zui.ui.font_system;
const protocol_messages = @import("protocol_messages.zig");
const terminal_render_backend = @import("terminal_render_backend.zig");

const workspace = zui.ui.workspace;
const panel_manager = zui.ui.panel_manager;
const dock_graph = zui.ui.layout.dock_graph;
const dock_drop = zui.ui.layout.dock_drop;
const form_layout = zui.ui.layout.form_layout;
const text_buffer = zui.ui.text_buffer;

const Rect = zui.core.Rect;
const UiRect = ui_draw_context.Rect;
const Paint = zui.theme_engine.Paint;

const ConnectionState = enum {
    disconnected,
    connecting,
    connected,
    error_state,
};

const UiStage = stage_machine.Stage;

const IdeMenuDomain = enum {
    file,
    edit,
    view,
    project,
    tools,
    window,
    help,
};

const MAX_REASONABLE_PANEL_COUNT: usize = 4096;
const MAX_REASONABLE_DOCK_NODE_COUNT: usize = 16384;
const MAX_REASONABLE_NEXT_PANEL_ID: workspace.PanelId = 4097;
const WORKSPACE_RECOVERY_COOLDOWN_FRAMES: u64 = 60;
const WORKSPACE_RECOVERY_SUSPEND_FRAMES: u64 = 9000;
const WORKSPACE_RECOVERY_ATTEMPTS_BEFORE_SUSPEND: u8 = 1;
const MAX_DEBUG_EVENTS: usize = 500;
const FSRPC_DEFAULT_TIMEOUT_MS: u32 = 15_000;
const FSRPC_CHAT_WRITE_TIMEOUT_MS: u32 = 180_000;
const FSRPC_CLUNK_TIMEOUT_MS: u32 = 1_000;
const FSRPC_READ_CHUNK_BYTES: u32 = 128 * 1024;
const FSRPC_READ_MAX_TOTAL_BYTES: usize = 8 * 1024 * 1024;
const CONTROL_CONNECT_TIMEOUT_MS: i64 = 2_500;
const CONTROL_SESSION_ATTACH_TIMEOUT_MS: i64 = 8_000;
const CONTROL_SESSION_STATUS_TIMEOUT_MS: i64 = 2_000;
const DEFAULT_MAIN_WINDOW_WIDTH: c_int = 1440;
const DEFAULT_MAIN_WINDOW_HEIGHT: c_int = 900;
const MIN_MAIN_WINDOW_WIDTH: c_int = 1100;
const MIN_MAIN_WINDOW_HEIGHT: c_int = 720;
const WS_MAX_MESSAGES_PER_FRAME: u32 = 32;
const WS_MAX_POLL_BUDGET_NS: i128 = 2 * std.time.ns_per_ms;
const FILESYSTEM_DIR_CACHE_TTL_MS: i64 = 5_000;
const FILESYSTEM_PREVIEW_MAX_BYTES: usize = 16_384;
const FILESYSTEM_PREVIEW_TEXT_SCAN_BYTES: usize = 512;
const DEBUG_STREAM_SNAPSHOT_RETRY_MS: i64 = 2_000;
const DEBUG_STREAM_PATH = "/debug/stream.log";
const NODE_SERVICE_EVENTS_PATH = "/global/services/node-service-events.ndjson";
const NODE_SERVICE_SNAPSHOT_RETRY_MS: i64 = 2_000;
const DEBUG_EVENT_DEDUPE_WINDOW: usize = 4096;
const DEBUG_SYNTAX_COLOR_MAX_PAYLOAD_BYTES: usize = 64 * 1024;
const DEBUG_SYNTAX_COLOR_MAX_LINE_BYTES: usize = 768;
const PERF_SAMPLE_INTERVAL_MS: i64 = 1_000;
const PERF_HISTORY_CAPACITY: usize = 600;
const PERF_SPARKLINE_MAX_COLUMNS: usize = 24;
const PERF_AUTOMATION_DEFAULT_DURATION_MS: i64 = 12_000;
const TERMINAL_OUTPUT_MAX_BYTES: usize = 512 * 1024;
const TERMINAL_READ_POLL_INTERVAL_MS: i64 = 120;
const TERMINAL_READ_TIMEOUT_MS: u32 = 1;
const TERMINAL_READ_MAX_BYTES: usize = 8 * 1024;
const TEXT_INPUT_DOUBLE_CLICK_MS: i64 = 350;
const TEXT_EDIT_HISTORY_LIMIT: usize = 128;
const TERMINAL_BACKEND_KIND = if (@hasDecl(build_options, "terminal_backend"))
    build_options.terminal_backend
else
    "plain";

const ChatAttachment = zui.protocol.types.ChatAttachment;
const ChatMessage = zui.protocol.types.ChatMessage;
const ChatMessageState = zui.protocol.types.LocalChatMessageState;
const ChatSession = zui.protocol.types.Session;

// Reusable panel implementations consumed through ZiggyUIPanels.
const ChatWorkspacePanel = zui_panels.chat_workspace_panel;
const LauncherSettingsPanel = zui_panels.launcher_settings_panel;
const FilesystemPanel = zui_panels.filesystem_panel;
const FilesystemToolsPanel = zui_panels.filesystem_tools_panel;
const ProjectPanel = zui_panels.project_panel;
const DebugPanel = zui_panels.debug_panel;
const DebugEventStreamPanel = zui_panels.debug_event_stream;
const TerminalPanel = zui_panels.terminal_panel;
const TerminalOutputPanel = zui_panels.terminal_output_panel;

const PanelLayoutMetrics = form_layout.Metrics;

const DockTabMetrics = struct {
    pad: f32,
    height: f32,
    min_width: f32,
    max_width_ratio: f32,
};

const FormScrollTarget = enum {
    none,
    settings,
    projects,
};

const TextEditSnapshot = struct {
    text: []u8,
    cursor: usize,
    selection_anchor: ?usize,

    fn deinit(self: *TextEditSnapshot, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
        self.* = undefined;
    }
};

const SessionAttachUiState = enum {
    unknown,
    warming,
    ready,
    err,
};

const ConnectSetupHint = struct {
    required: bool = false,
    message: ?[]u8 = null,
    project_id: ?[]u8 = null,
    project_vision: ?[]u8 = null,

    fn deinit(self: *ConnectSetupHint, allocator: std.mem.Allocator) void {
        if (self.message) |value| allocator.free(value);
        if (self.project_id) |value| allocator.free(value);
        if (self.project_vision) |value| allocator.free(value);
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

const FilesystemEntryKind = panels_bridge.FilesystemEntryKind;
const FilesystemSortKey = panels_bridge.FilesystemSortKey;
const FilesystemSortDirection = panels_bridge.FilesystemSortDirection;
const FilesystemPreviewMode = panels_bridge.FilesystemPreviewMode;

const FilesystemRequestKind = enum {
    list_dir,
    read_file,
    resolve_kind,
};

const FilesystemRequestResult = struct {
    id: u64,
    kind: FilesystemRequestKind,
    path: []u8,
    listing: ?[]u8 = null,
    content: ?[]u8 = null,
    is_dir: ?bool = null,
    error_text: ?[]u8 = null,

    fn deinit(self: *FilesystemRequestResult, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        if (self.listing) |value| allocator.free(value);
        if (self.content) |value| allocator.free(value);
        if (self.error_text) |value| allocator.free(value);
        self.* = undefined;
    }
};

const FilesystemEntry = struct {
    name: []u8,
    path: []u8,
    kind: FilesystemEntryKind = .unknown,
    type_label: []u8,
    hidden: bool = false,
    size_bytes: ?u64 = null,
    modified_unix_ms: ?i64 = null,
    previewable: bool = false,
    runtime_noise: bool = false,

    fn deinit(self: *FilesystemEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.path);
        allocator.free(self.type_label);
        self.* = undefined;
    }
};

const FilesystemStatInfo = struct {
    kind: FilesystemEntryKind = .unknown,
    size_bytes: ?u64 = null,
    modified_unix_ms: ?i64 = null,
};

const ContractServiceEntry = struct {
    service_id: []u8,
    service_path: []u8,
    invoke_path: []u8,
    help_path: []u8,
    schema_path: []u8,
    template_path: []u8,

    fn deinit(self: *ContractServiceEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.service_id);
        allocator.free(self.service_path);
        allocator.free(self.invoke_path);
        allocator.free(self.help_path);
        allocator.free(self.schema_path);
        allocator.free(self.template_path);
        self.* = undefined;
    }
};

const FilesystemDirCacheEntry = struct {
    listing: []u8,
    cached_at_ms: i64,

    fn deinit(self: *FilesystemDirCacheEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.listing);
        self.* = undefined;
    }
};

const FilesystemActiveRequest = struct {
    id: u64,
    kind: FilesystemRequestKind,
    open_after_resolve: bool = false,
    is_background: bool = false,
    started_at_ms: i64 = 0,
};

const JobStatusInfo = struct {
    state: []u8,
    error_text: ?[]u8 = null,
    correlation_id: ?[]u8 = null,

    fn deinit(self: *JobStatusInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.state);
        if (self.error_text) |value| allocator.free(value);
        if (self.correlation_id) |value| allocator.free(value);
        self.* = undefined;
    }
};

const ScopedChatBindingPaths = venom_bindings.ChatBindingPaths;

const SubmitChatJobResult = struct {
    job_id: []u8,
    jobs_root: []u8,
    thoughts_root: []u8,
    correlation_id: ?[]u8 = null,

    fn deinit(self: *SubmitChatJobResult, allocator: std.mem.Allocator) void {
        allocator.free(self.job_id);
        allocator.free(self.jobs_root);
        allocator.free(self.thoughts_root);
        if (self.correlation_id) |value| allocator.free(value);
        self.* = undefined;
    }
};

const AuthStatusSnapshot = struct {
    admin_token: []u8,
    user_token: []u8,
    path: ?[]u8 = null,

    fn deinit(self: *AuthStatusSnapshot, allocator: std.mem.Allocator) void {
        allocator.free(self.admin_token);
        allocator.free(self.user_token);
        if (self.path) |value| allocator.free(value);
        self.* = undefined;
    }
};

fn encodeDataB64(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    const encoder = std.base64.standard.Encoder;
    const encoded_len = encoder.calcSize(data.len);
    const out = try allocator.alloc(u8, encoded_len);
    _ = encoder.encode(out, data);
    return out;
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

fn defaultTerminalBackendKind() terminal_render_backend.Backend.Kind {
    return terminal_render_backend.Backend.parseKind(TERMINAL_BACKEND_KIND);
}

fn initTerminalBackend(kind: terminal_render_backend.Backend.Kind) terminal_render_backend.Backend {
    return terminal_render_backend.Backend.initForKind(kind, .{
        .max_bytes = TERMINAL_OUTPUT_MAX_BYTES,
    });
}

fn maskTokenForDisplay(allocator: std.mem.Allocator, token: []const u8) ![]u8 {
    if (token.len == 0) return allocator.dupe(u8, "(empty)");
    if (token.len <= 8) return allocator.dupe(u8, "****");
    return std.fmt.allocPrint(
        allocator,
        "{s}...{s}",
        .{ token[0..4], token[token.len - 4 ..] },
    );
}

fn normalizeProjectToken(project_token: ?[]const u8) ?[]const u8 {
    const token = project_token orelse return null;
    const trimmed = std.mem.trim(u8, token, " \t\r\n");
    if (trimmed.len == 0) return null;
    return trimmed;
}

fn containsCaseInsensitive(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    return std.ascii.indexOfIgnoreCase(haystack, needle) != null;
}

const SettingsFocusField = enum {
    none,
    server_url,
    project_id,
    launcher_project_filter,
    launcher_profile_name,
    launcher_profile_metadata,
    launcher_connect_token,
    project_token,
    project_create_name,
    project_create_vision,
    project_operator_token,
    project_mount_path,
    project_mount_node_id,
    project_mount_export_name,
    default_session,
    default_agent,
    ui_theme,
    ui_profile,
    ui_theme_pack,
    node_watch_filter,
    node_watch_replay_limit,
    debug_search_filter,
    perf_benchmark_label,
    filesystem_contract_payload,
    terminal_command_input,
};

const PointerInputLayer = enum {
    base,
    text_input_context_menu,
};

fn isSettingsPanelFocusField(field: SettingsFocusField) bool {
    return switch (field) {
        .server_url,
        .default_session,
        .default_agent,
        .ui_theme,
        .ui_profile,
        .ui_theme_pack,
        => true,
        else => false,
    };
}

// Panel extraction keeps host-owned text storage in SpiderApp, so these helpers
// translate between the shared panel state enums and the host-local focus enum.
fn settingsFocusFieldToExternal(field: SettingsFocusField) LauncherSettingsPanel.FocusField {
    return switch (field) {
        .server_url => .server_url,
        .default_session => .default_session,
        .default_agent => .default_agent,
        .ui_theme => .ui_theme,
        .ui_profile => .ui_profile,
        .ui_theme_pack => .ui_theme_pack,
        else => .none,
    };
}

fn settingsFocusFieldFromExternal(field: LauncherSettingsPanel.FocusField) SettingsFocusField {
    return switch (field) {
        .server_url => .server_url,
        .default_session => .default_session,
        .default_agent => .default_agent,
        .ui_theme => .ui_theme,
        .ui_profile => .ui_profile,
        .ui_theme_pack => .ui_theme_pack,
        .none => .none,
    };
}

fn filesystemToolsFocusFieldToExternal(field: SettingsFocusField) FilesystemToolsPanel.FocusField {
    return switch (field) {
        .filesystem_contract_payload => .contract_payload,
        else => .none,
    };
}

fn filesystemToolsFocusFieldFromExternal(field: FilesystemToolsPanel.FocusField) SettingsFocusField {
    return switch (field) {
        .contract_payload => .filesystem_contract_payload,
        .none => .none,
    };
}

fn isFilesystemToolsPanelFocusField(field: SettingsFocusField) bool {
    return switch (field) {
        .filesystem_contract_payload => true,
        else => false,
    };
}

fn debugFocusFieldToExternal(field: SettingsFocusField) DebugPanel.FocusField {
    return switch (field) {
        .perf_benchmark_label => .perf_benchmark_label,
        .node_watch_filter => .node_watch_filter,
        .node_watch_replay_limit => .node_watch_replay_limit,
        .debug_search_filter => .debug_search_filter,
        else => .none,
    };
}

fn debugFocusFieldFromExternal(field: DebugPanel.FocusField) SettingsFocusField {
    return switch (field) {
        .perf_benchmark_label => .perf_benchmark_label,
        .node_watch_filter => .node_watch_filter,
        .node_watch_replay_limit => .node_watch_replay_limit,
        .debug_search_filter => .debug_search_filter,
        .none => .none,
    };
}

fn isDebugPanelFocusField(field: SettingsFocusField) bool {
    return switch (field) {
        .perf_benchmark_label,
        .node_watch_filter,
        .node_watch_replay_limit,
        .debug_search_filter,
        => true,
        else => false,
    };
}

fn terminalFocusFieldToExternal(field: SettingsFocusField) TerminalPanel.FocusField {
    return switch (field) {
        .terminal_command_input => .command_input,
        else => .none,
    };
}

fn terminalFocusFieldFromExternal(field: TerminalPanel.FocusField) SettingsFocusField {
    return switch (field) {
        .command_input => .terminal_command_input,
        .none => .none,
    };
}

fn isTerminalPanelFocusField(field: SettingsFocusField) bool {
    return switch (field) {
        .terminal_command_input => true,
        else => false,
    };
}

fn projectFocusFieldToExternal(field: SettingsFocusField) ProjectPanel.FocusField {
    return switch (field) {
        .project_token => .project_token,
        .project_create_name => .create_name,
        .project_create_vision => .create_vision,
        .project_operator_token => .operator_token,
        .project_mount_path => .mount_path,
        .project_mount_node_id => .mount_node_id,
        .project_mount_export_name => .mount_export_name,
        else => .none,
    };
}

fn projectFocusFieldFromExternal(field: ProjectPanel.FocusField) SettingsFocusField {
    return switch (field) {
        .project_token => .project_token,
        .create_name => .project_create_name,
        .create_vision => .project_create_vision,
        .operator_token => .project_operator_token,
        .mount_path => .project_mount_path,
        .mount_node_id => .project_mount_node_id,
        .mount_export_name => .project_mount_export_name,
        .none => .none,
    };
}

fn isProjectPanelFocusField(field: SettingsFocusField) bool {
    return switch (field) {
        .project_token,
        .project_create_name,
        .project_create_vision,
        .project_operator_token,
        .project_mount_path,
        .project_mount_node_id,
        .project_mount_export_name,
        => true,
        else => false,
    };
}

fn isUserScopedAgentId(agent_id: []const u8) bool {
    return std.mem.eql(u8, agent_id, "user") or std.mem.eql(u8, agent_id, "user-isolated");
}

fn isValidSessionKeyForAttach(value: []const u8) bool {
    if (value.len == 0 or value.len > 128) return false;
    for (value) |char| {
        if (std.ascii.isAlphanumeric(char)) continue;
        if (char == '-' or char == '_' or char == '.' or char == ':') continue;
        return false;
    }
    return true;
}

fn isValidAgentIdForAttach(value: []const u8) bool {
    if (value.len == 0 or value.len > 128) return false;
    if (std.mem.eql(u8, value, ".")) return false;
    for (value) |char| {
        if (std.ascii.isAlphanumeric(char)) continue;
        if (char == '_' or char == '-') continue;
        return false;
    }
    return true;
}

fn isValidProjectIdForAttach(value: []const u8) bool {
    if (value.len == 0 or value.len > 128) return false;
    if (std.mem.eql(u8, value, ".") or std.mem.eql(u8, value, "..")) return false;
    for (value) |char| {
        if (std.ascii.isAlphanumeric(char)) continue;
        if (char == '_' or char == '-' or char == '.') continue;
        return false;
    }
    return true;
}

fn sanitizeSessionKey(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return allocator.dupe(u8, "main");

    var out = std.ArrayListUnmanaged(u8){};
    errdefer out.deinit(allocator);

    for (trimmed) |char| {
        if (out.items.len >= 128) break;
        if (std.ascii.isAlphanumeric(char) or char == '-' or char == '_' or char == '.' or char == ':') {
            try out.append(allocator, char);
        } else {
            try out.append(allocator, '-');
        }
    }

    if (out.items.len == 0) {
        try out.appendSlice(allocator, "main");
    }
    return out.toOwnedSlice(allocator);
}

const system_project_id = "system";
const system_agent_id = "mother";

fn isSystemProjectId(project_id: ?[]const u8) bool {
    const concrete = project_id orelse return false;
    return std.mem.eql(u8, concrete, system_project_id);
}

fn isSystemAgentId(agent_id: []const u8) bool {
    return std.mem.eql(u8, agent_id, system_agent_id);
}

const SettingsPanel = struct {
    server_url: std.ArrayList(u8) = .empty,
    project_id: std.ArrayList(u8) = .empty,
    project_token: std.ArrayList(u8) = .empty,
    project_create_name: std.ArrayList(u8) = .empty,
    project_create_vision: std.ArrayList(u8) = .empty,
    project_operator_token: std.ArrayList(u8) = .empty,
    project_mount_path: std.ArrayList(u8) = .empty,
    project_mount_node_id: std.ArrayList(u8) = .empty,
    project_mount_export_name: std.ArrayList(u8) = .empty,
    default_session: std.ArrayList(u8) = .empty,
    default_agent: std.ArrayList(u8) = .empty,
    ui_theme: std.ArrayList(u8) = .empty,
    ui_profile: std.ArrayList(u8) = .empty,
    ui_theme_pack: std.ArrayList(u8) = .empty,
    watch_theme_pack: bool = false,
    terminal_backend_kind: terminal_render_backend.Backend.Kind = .plain_text,
    ws_verbose_logs: bool = false,
    auto_connect_on_launch: bool = true,
    focused_field: SettingsFocusField = .server_url,
    // Vertical scroll offsets per form panel
    settings_scroll_y: f32 = 0.0,
    projects_scroll_y: f32 = 0.0,

    pub fn init(allocator: std.mem.Allocator) SettingsPanel {
        var panel = SettingsPanel{};
        panel.server_url.appendSlice(allocator, "ws://127.0.0.1:18790") catch {};
        panel.project_id.appendSlice(allocator, "") catch {};
        panel.project_token.appendSlice(allocator, "") catch {};
        panel.project_create_name.appendSlice(allocator, "") catch {};
        panel.project_create_vision.appendSlice(allocator, "") catch {};
        panel.project_operator_token.appendSlice(allocator, "") catch {};
        panel.project_mount_path.appendSlice(allocator, "/") catch {};
        panel.project_mount_node_id.appendSlice(allocator, "") catch {};
        panel.project_mount_export_name.appendSlice(allocator, "") catch {};
        panel.default_session.appendSlice(allocator, "main") catch {};
        panel.default_agent.appendSlice(allocator, "") catch {};
        panel.terminal_backend_kind = defaultTerminalBackendKind();
        return panel;
    }

    pub fn deinit(self: *SettingsPanel, allocator: std.mem.Allocator) void {
        self.server_url.deinit(allocator);
        self.project_id.deinit(allocator);
        self.project_token.deinit(allocator);
        self.project_create_name.deinit(allocator);
        self.project_create_vision.deinit(allocator);
        self.project_operator_token.deinit(allocator);
        self.project_mount_path.deinit(allocator);
        self.project_mount_node_id.deinit(allocator);
        self.project_mount_export_name.deinit(allocator);
        self.default_session.deinit(allocator);
        self.default_agent.deinit(allocator);
        self.ui_theme.deinit(allocator);
        self.ui_profile.deinit(allocator);
        self.ui_theme_pack.deinit(allocator);
    }
};

const UiWindow = struct {
    window: *c.SDL_Window,
    id: u32,
    queue: ui_input_state.InputQueue,
    swapchain: zapp.multi_window_renderer.WindowSwapchain,
    manager: *panel_manager.PanelManager,
    ui_state: zui.ui.main_window.WindowUiState = .{},
    title: []u8,
    persist_in_workspace: bool = false,
    owns_manager: bool = true,
    owns_swapchain: bool = true,
};

const SessionMessageState = struct {
    key: []const u8,
    messages: std.ArrayList(ChatMessage) = .empty,
    streaming_request_id: ?[]const u8 = null,
};

const DebugEventEntry = struct {
    id: u64,
    timestamp_ms: i64,
    category: []u8,
    correlation_id: ?[]u8 = null,
    payload_json: []u8,
    payload_lines: std.ArrayList(DebugPayloadLine) = .empty,
    payload_wrap_rows: std.ArrayList(u32) = .empty,
    payload_visible_line_indices: std.ArrayList(u32) = .empty,
    payload_visible_line_row_starts: std.ArrayList(u32) = .empty,
    payload_visible_lines_valid: bool = false,
    payload_wrap_rows_wrap_width: f32 = -1.0,
    payload_wrap_rows_valid: bool = false,
    cached_visible_rows: usize = 0,
    cached_visible_rows_wrap_width: f32 = -1.0,
    cached_visible_rows_fold_revision: u64 = 0,
    cached_visible_rows_valid: bool = false,

    fn deinit(self: *DebugEventEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.category);
        if (self.correlation_id) |value| allocator.free(value);
        allocator.free(self.payload_json);
        self.payload_visible_line_row_starts.deinit(allocator);
        self.payload_visible_line_indices.deinit(allocator);
        self.payload_wrap_rows.deinit(allocator);
        self.payload_lines.deinit(allocator);
    }
};

const DebugPayloadLine = struct {
    start: usize,
    end: usize,
    indent_spaces: usize,
    opens_block: bool = false,
    matching_close_index: ?u32 = null,
};

const DebugFoldKey = struct {
    event_id: u64,
    line_index: u32,
};

const JsonTokenKind = enum {
    key,
    string,
    number,
    keyword,
    punctuation,
    plain,
};

const DockTabHit = struct {
    panel_id: workspace.PanelId,
    node_id: dock_graph.NodeId,
    tab_index: usize,
    rect: UiRect,
};

const DockDropTarget = struct {
    node_id: dock_graph.NodeId,
    location: dock_graph.DropLocation,
    rect: UiRect,
};

const DockTabHitList = struct {
    items: [96]DockTabHit = undefined,
    len: usize = 0,

    fn append(self: *DockTabHitList, item: DockTabHit) void {
        if (self.len >= self.items.len) return;
        self.items[self.len] = item;
        self.len += 1;
    }

    fn slice(self: *const DockTabHitList) []const DockTabHit {
        return self.items[0..self.len];
    }
};

const DockDropTargetList = struct {
    items: [96]DockDropTarget = undefined,
    len: usize = 0,

    fn append(self: *DockDropTargetList, item: DockDropTarget) void {
        if (self.len >= self.items.len) return;
        self.items[self.len] = item;
        self.len += 1;
    }

    fn findAt(self: *const DockDropTargetList, pos: [2]f32) ?DockDropTarget {
        for (self.items[0..self.len]) |tgt| {
            if (tgt.location != .center) continue;
            if (tgt.rect.contains(pos)) return tgt;
        }
        for (self.items[0..self.len]) |tgt| {
            if (tgt.location == .center) continue;
            if (tgt.rect.contains(pos)) return tgt;
        }
        return null;
    }

    fn clear(self: *DockDropTargetList) void {
        self.len = 0;
    }
};

const DockInteractionResult = struct {
    focus_panel_id: ?workspace.PanelId = null,
    changed_layout: bool = false,
    detach_panel_id: ?workspace.PanelId = null,
};

const PerfSample = struct {
    timestamp_ms: i64,
    fps: f32,
    frame_ms: f32,
    ws_poll_ms: f32,
    fs_poll_ms: f32,
    ws_wait_ms: f32,
    fs_request_ms: f32,
    debug_ms: f32,
    terminal_ms: f32,
    draw_ms: f32,
    panel_chat_ms: f32,
    panel_settings_ms: f32,
    panel_debug_ms: f32,
    panel_projects_ms: f32,
    panel_filesystem_ms: f32,
    panel_terminal_ms: f32,
    panel_other_ms: f32,
    cmd_total_per_frame: f32,
    cmd_text_per_frame: f32,
    cmd_shape_per_frame: f32,
    cmd_line_per_frame: f32,
    cmd_image_per_frame: f32,
    cmd_clip_per_frame: f32,
    text_bytes_per_frame: f32,
    text_command_share_pct: f32,
};

fn perfSampleFrameMsAt(ctx: *const anyopaque, idx: usize) f32 {
    const samples = (@as(*const []const PerfSample, @ptrCast(@alignCast(ctx)))).*;
    return samples[idx].frame_ms;
}

fn perfSampleDrawMsAt(ctx: *const anyopaque, idx: usize) f32 {
    const samples = (@as(*const []const PerfSample, @ptrCast(@alignCast(ctx)))).*;
    return samples[idx].draw_ms;
}

fn perfSampleWsMsAt(ctx: *const anyopaque, idx: usize) f32 {
    const samples = (@as(*const []const PerfSample, @ptrCast(@alignCast(ctx)))).*;
    return samples[idx].ws_wait_ms;
}

fn perfSampleFsMsAt(ctx: *const anyopaque, idx: usize) f32 {
    const samples = (@as(*const []const PerfSample, @ptrCast(@alignCast(ctx)))).*;
    return samples[idx].fs_request_ms;
}

const PanelDrawFrameNs = struct {
    chat: i128 = 0,
    settings: i128 = 0,
    debug: i128 = 0,
    projects: i128 = 0,
    filesystem: i128 = 0,
    terminal: i128 = 0,
    other: i128 = 0,
};

const RenderCommandFrameStats = struct {
    total: u64 = 0,
    text: u64 = 0,
    shape: u64 = 0,
    line: u64 = 0,
    image: u64 = 0,
    clip: u64 = 0,
    text_bytes: u64 = 0,
};

const SelectedNodeServiceEventInfo = struct {
    index: ?usize = null,
    node_id: ?[]const u8 = null,
    diagnostics: ?[]const u8 = null,
};

const WindowMouseHit = struct {
    win: *UiWindow,
    local_pos: [2]f32,
};

fn findTabHitAt(tab_hits: *const DockTabHitList, pos: [2]f32) ?DockTabHit {
    var idx = tab_hits.len;
    while (idx > 0) {
        idx -= 1;
        const hit = tab_hits.items[idx];
        if (hit.rect.contains(pos)) return hit;
    }
    return null;
}

fn dockDropTargetLabel(location: dock_graph.DropLocation) []const u8 {
    return switch (location) {
        .center => "Dock Center",
        .left => "Dock Left",
        .right => "Dock Right",
        .top => "Dock Top",
        .bottom => "Dock Bottom",
    };
}

const App = struct {
    allocator: std.mem.Allocator,
    window: *c.SDL_Window,
    gpu: zapp.multi_window_renderer.Shared,
    swapchain: zapp.multi_window_renderer.WindowSwapchain,

    ui_windows: std.ArrayList(*UiWindow) = .empty,
    main_window_id: u32 = 0,

    // Panel state
    settings_panel: SettingsPanel,
    chat_panel_state: zui.ui.workspace.ChatPanel = .{},

    // Workspace and panel management
    next_panel_id: workspace.PanelId = 1,
    manager: panel_manager.PanelManager,

    // Chat state
    chat_input: std.ArrayList(u8) = .empty,
    chat_sessions: std.ArrayList(ChatSession) = .empty,
    session_messages: std.ArrayList(SessionMessageState) = .empty,
    current_session_key: ?[]const u8 = null,
    pending_send_request_id: ?[]const u8 = null,
    pending_send_message_id: ?[]const u8 = null,
    pending_send_session_key: ?[]const u8 = null,
    pending_send_job_id: ?[]u8 = null,
    pending_send_jobs_root: ?[]u8 = null,
    pending_send_thoughts_root: ?[]u8 = null,
    pending_send_correlation_id: ?[]u8 = null,
    pending_send_thought_message_id: ?[]u8 = null,
    pending_send_last_thought_text: ?[]u8 = null,
    pending_send_resume_notified: bool = false,
    pending_send_last_resume_attempt_ms: i64 = 0,
    pending_send_started_at_ms: i64 = 0,
    awaiting_reply: bool = false,
    debug_stream_enabled: bool = true,
    debug_stream_snapshot_pending: bool = false,
    debug_stream_snapshot_retry_at_ms: i64 = 0,
    debug_stream_snapshot: ?[]u8 = null,
    node_service_watch_enabled: bool = false,
    node_service_snapshot_pending: bool = false,
    node_service_snapshot_retry_at_ms: i64 = 0,
    node_service_watch_filter: std.ArrayList(u8) = .empty,
    node_service_watch_replay_limit: std.ArrayList(u8) = .empty,
    debug_search_filter: std.ArrayList(u8) = .empty,
    node_service_latest_reload_diag: ?[]u8 = null,
    node_service_diff_preview: ?[]u8 = null,
    node_service_diff_base_index: ?usize = null,
    debug_panel_id: ?workspace.PanelId = null,
    debug_events: std.ArrayList(DebugEventEntry) = .empty,
    debug_next_event_id: u64 = 1,
    debug_events_revision: u64 = 1,
    debug_filter_cache_valid: bool = false,
    debug_filter_cache_query_hash: u64 = 0,
    debug_filter_cache_query_len: usize = 0,
    debug_filter_cache_events_revision: u64 = 0,
    debug_filtered_indices: std.ArrayList(u32) = .empty,
    debug_folded_blocks: std.AutoHashMap(DebugFoldKey, void),
    debug_fold_revision: u64 = 1,
    debug_scroll_y: f32 = 0.0,
    debug_selected_index: ?usize = null,
    perf_benchmark_label_input: std.ArrayList(u8) = .empty,
    perf_benchmark_active: bool = false,
    perf_benchmark_start_sample_index: usize = 0,
    perf_benchmark_start_timestamp_ms: i64 = 0,
    perf_benchmark_active_label: ?[]u8 = null,
    perf_benchmark_last_start_sample_index: ?usize = null,
    perf_benchmark_last_end_sample_index: usize = 0,
    perf_benchmark_last_start_timestamp_ms: i64 = 0,
    perf_benchmark_last_end_timestamp_ms: i64 = 0,
    perf_benchmark_last_label: ?[]u8 = null,
    perf_automation_enabled: bool = false,
    perf_automation_started: bool = false,
    perf_automation_start_ms: i64 = 0,
    perf_automation_duration_ms: i64 = PERF_AUTOMATION_DEFAULT_DURATION_MS,
    perf_automation_min_fps: ?f32 = null,
    perf_automation_report_path: ?[]u8 = null,
    debug_selected_node_service_cache_event_id: u64 = 0,
    debug_selected_node_service_cache_index: ?usize = null,
    debug_selected_node_service_cache_node_id: ?[]u8 = null,
    debug_selected_node_service_cache_diagnostics: ?[]u8 = null,
    debug_event_fingerprint_set: std.AutoHashMapUnmanaged(u64, void) = .{},
    debug_event_fingerprint_ring: [DEBUG_EVENT_DEDUPE_WINDOW]u64 = [_]u64{0} ** DEBUG_EVENT_DEDUPE_WINDOW,
    debug_event_fingerprint_count: usize = 0,
    debug_event_fingerprint_next: usize = 0,
    debug_output_rect: Rect = Rect.fromXYWH(0, 0, 0, 0),
    debug_scrollbar_dragging: bool = false,
    debug_scrollbar_drag_start_y: f32 = 0.0,
    debug_scrollbar_drag_start_scroll_y: f32 = 0.0,
    form_scroll_drag_target: FormScrollTarget = .none,
    form_scroll_drag_start_y: f32 = 0.0,
    form_scroll_drag_start_scroll_y: f32 = 0.0,
    drag_mouse_capture_active: bool = false,
    ui_commands: zui.ui.render.command_list.CommandList,
    ui_inbox: ui_command_inbox.UiCommandInbox,

    projects: std.ArrayListUnmanaged(workspace_types.ProjectSummary) = .{},
    nodes: std.ArrayListUnmanaged(workspace_types.NodeInfo) = .{},
    workspace_state: ?workspace_types.WorkspaceStatus = null,
    workspace_last_error: ?[]u8 = null,
    workspace_last_refresh_ms: i64 = 0,
    project_panel_id: ?workspace.PanelId = null,
    project_selector_open: bool = false,
    filesystem_panel_id: ?workspace.PanelId = null,
    filesystem_tools_panel_id: ?workspace.PanelId = null,
    terminal_panel_id: ?workspace.PanelId = null,
    filesystem_path: std.ArrayList(u8) = .empty,
    filesystem_entries: std.ArrayListUnmanaged(FilesystemEntry) = .{},
    filesystem_sort_key: FilesystemSortKey = .name,
    filesystem_sort_direction: FilesystemSortDirection = .ascending,
    filesystem_hide_hidden: bool = false,
    filesystem_hide_directories: bool = false,
    filesystem_hide_files: bool = false,
    filesystem_hide_runtime_noise: bool = false,
    filesystem_selected_path: ?[]u8 = null,
    filesystem_entry_page: usize = 0,
    filesystem_last_clicked_entry_index: ?usize = null,
    filesystem_last_click_ms: i64 = 0,
    filesystem_type_column_width: f32 = 96.0,
    filesystem_modified_column_width: f32 = 122.0,
    filesystem_size_column_width: f32 = 72.0,
    filesystem_column_resize_handle: FilesystemPanel.ColumnResizeHandle = .none,
    filesystem_preview_split_ratio: f32 = 0.28,
    filesystem_preview_split_dragging: bool = false,
    filesystem_preview_path: ?[]u8 = null,
    filesystem_preview_text: ?[]u8 = null,
    filesystem_preview_status: ?[]u8 = null,
    filesystem_preview_mode: FilesystemPreviewMode = .empty,
    filesystem_preview_kind: FilesystemEntryKind = .unknown,
    filesystem_preview_size_bytes: ?u64 = null,
    filesystem_preview_modified_unix_ms: ?i64 = null,
    filesystem_error: ?[]u8 = null,
    filesystem_busy: bool = false,
    filesystem_next_request_id: u64 = 1,
    filesystem_active_request: ?FilesystemActiveRequest = null,
    filesystem_pending_path: ?[]u8 = null,
    filesystem_pending_use_cache: bool = false,
    filesystem_pending_force_refresh: bool = false,
    filesystem_pending_retry_at_ms: i64 = 0,
    filesystem_last_request_duration_ms: f32 = 0.0,
    filesystem_dir_cache: std.StringHashMapUnmanaged(FilesystemDirCacheEntry) = .{},
    fsrpc_last_remote_error: ?[]u8 = null,
    fsrpc_ready: bool = false,
    contract_services: std.ArrayListUnmanaged(ContractServiceEntry) = .{},
    contract_service_selected_index: usize = 0,
    contract_invoke_payload: std.ArrayList(u8) = .empty,
    terminal_backend_kind: terminal_render_backend.Backend.Kind = .plain_text,
    terminal_backend: terminal_render_backend.Backend,
    terminal_input: std.ArrayList(u8) = .empty,
    terminal_status: ?[]u8 = null,
    terminal_error: ?[]u8 = null,
    terminal_session_id: ?[]u8 = null,
    terminal_auto_poll: bool = true,
    terminal_next_poll_at_ms: i64 = 0,
    session_attach_state: SessionAttachUiState = .unknown,
    connect_setup_hint: ?ConnectSetupHint = null,

    ws_client: ?ws_client_mod.WebSocketClient = null,

    connection_state: ConnectionState = .disconnected,
    status_text: []u8,
    ui_stage: UiStage = .launcher,
    active_profile_id: ?[]u8 = null,
    active_project_id: ?[]u8 = null,
    launcher_notice: ?[]u8 = null,
    launcher_selected_profile_index: usize = 0,
    launcher_project_filter: std.ArrayList(u8) = .empty,
    launcher_profile_name: std.ArrayList(u8) = .empty,
    launcher_profile_metadata: std.ArrayList(u8) = .empty,
    launcher_connect_token: std.ArrayList(u8) = .empty,
    ide_menu_open: ?IdeMenuDomain = null,
    credential_store: credential_store_mod.CredentialStore,

    theme: *const zui.Theme,
    ui_scale: f32 = 1.0,
    metrics_context: ui_draw_context.DrawContext,
    ascii_glyph_width_cache: [128]f32 = [_]f32{-1.0} ** 128,
    config: config_mod.Config,
    client_context: client_state.ClientContext,
    agent_registry: client_agents.AgentRegistry,

    running: bool = true,

    // Input state
    mouse_x: f32 = 0,
    mouse_y: f32 = 0,
    mouse_down: bool = false,
    mouse_clicked: bool = false,
    mouse_released: bool = false,
    mouse_right_clicked: bool = false,
    text_input_cursor: usize = 0,
    text_input_selection_anchor: ?usize = null,
    text_input_dragging: bool = false,
    text_input_drag_anchor: usize = 0,
    text_input_cursor_initialized: bool = false,
    text_input_context_menu_open: bool = false,
    text_input_context_menu_anchor: [2]f32 = .{ 0.0, 0.0 },
    text_input_context_menu_rect: ?Rect = null,
    text_input_context_menu_rendering: bool = false,
    text_input_last_left_click_ms: i64 = 0,
    text_input_last_left_click_pos: [2]f32 = .{ 0.0, 0.0 },
    text_edit_history_field: SettingsFocusField = .none,
    text_edit_undo_stack: std.ArrayListUnmanaged(TextEditSnapshot) = .{},
    text_edit_redo_stack: std.ArrayListUnmanaged(TextEditSnapshot) = .{},
    active_pointer_layer: PointerInputLayer = .base,
    render_input_queue: ?*ui_input_state.InputQueue = null,
    frame_dt_seconds: f32 = 1.0 / 60.0,

    pending_close_window_id: ?u32 = null,

    message_counter: u64 = 0,
    next_fsrpc_tag: u32 = 1,
    next_fsrpc_fid: u32 = 2,
    debug_frame_counter: u64 = 0,
    perf_frame_panel_ns: PanelDrawFrameNs = .{},
    perf_frame_cmd_stats: RenderCommandFrameStats = .{},
    perf_sample_started_ms: i64 = 0,
    perf_sample_frames: u32 = 0,
    perf_sample_total_frame_ns: i128 = 0,
    perf_sample_total_ws_ns: i128 = 0,
    perf_sample_total_fs_ns: i128 = 0,
    perf_sample_total_debug_ns: i128 = 0,
    perf_sample_total_terminal_ns: i128 = 0,
    perf_sample_total_draw_ns: i128 = 0,
    perf_sample_total_panel_chat_ns: i128 = 0,
    perf_sample_total_panel_settings_ns: i128 = 0,
    perf_sample_total_panel_debug_ns: i128 = 0,
    perf_sample_total_panel_projects_ns: i128 = 0,
    perf_sample_total_panel_filesystem_ns: i128 = 0,
    perf_sample_total_panel_terminal_ns: i128 = 0,
    perf_sample_total_panel_other_ns: i128 = 0,
    perf_sample_total_cmd_total: u64 = 0,
    perf_sample_total_cmd_text: u64 = 0,
    perf_sample_total_cmd_shape: u64 = 0,
    perf_sample_total_cmd_line: u64 = 0,
    perf_sample_total_cmd_image: u64 = 0,
    perf_sample_total_cmd_clip: u64 = 0,
    perf_sample_total_text_bytes: u64 = 0,
    perf_last_fps: f32 = 0,
    perf_last_frame_ms: f32 = 0,
    perf_last_ws_ms: f32 = 0,
    perf_last_fs_ms: f32 = 0,
    perf_last_ws_wait_ms: f32 = 0,
    perf_last_fs_request_ms: f32 = 0,
    perf_last_debug_ms: f32 = 0,
    perf_last_terminal_ms: f32 = 0,
    perf_last_draw_ms: f32 = 0,
    perf_last_panel_chat_ms: f32 = 0,
    perf_last_panel_settings_ms: f32 = 0,
    perf_last_panel_debug_ms: f32 = 0,
    perf_last_panel_projects_ms: f32 = 0,
    perf_last_panel_filesystem_ms: f32 = 0,
    perf_last_panel_terminal_ms: f32 = 0,
    perf_last_panel_other_ms: f32 = 0,
    perf_last_cmd_total_per_frame: f32 = 0,
    perf_last_cmd_text_per_frame: f32 = 0,
    perf_last_cmd_shape_per_frame: f32 = 0,
    perf_last_cmd_line_per_frame: f32 = 0,
    perf_last_cmd_image_per_frame: f32 = 0,
    perf_last_cmd_clip_per_frame: f32 = 0,
    perf_last_text_bytes_per_frame: f32 = 0,
    perf_last_text_command_share_pct: f32 = 0,
    perf_history: std.ArrayListUnmanaged(PerfSample) = .{},
    frame_clock: zapp.frame_clock.FrameClock,
    workspace_recovery_blocked_until: u64 = 0,
    workspace_recovery_blocked_for_manager: usize = 0,
    workspace_recovery_suspended_until: u64 = 0,
    workspace_recovery_suspended_for_manager: usize = 0,
    workspace_recovery_failures: u8 = 0,
    workspace_snapshot_restore_cooldown_until: u64 = 0,

    // UI State for dock
    ui_state: zui.ui.main_window.WindowUiState = .{},
    windows_menu_open_window_id: ?u32 = null,
    workspace_snapshot: ?workspace.WorkspaceSnapshot = null,
    workspace_snapshot_stale: bool = false,
    workspace_snapshot_restore_attempted: bool = false,

    pub fn init(allocator: std.mem.Allocator) !App {
        panels_bridge.assertAvailable();
        // Load config before creating window so saved geometry can be restored.
        var config = config_mod.Config.load(allocator) catch |err| blk: {
            std.log.warn("Failed to load config: {s}, using defaults", .{@errorName(err)});
            break :blk try config_mod.Config.init(allocator);
        };
        errdefer config.deinit();

        const restored_width = config.window_width orelse DEFAULT_MAIN_WINDOW_WIDTH;
        const restored_height = config.window_height orelse DEFAULT_MAIN_WINDOW_HEIGHT;
        const initial_width: c_int = @intCast(@max(MIN_MAIN_WINDOW_WIDTH, restored_width));
        const initial_height: c_int = @intCast(@max(MIN_MAIN_WINDOW_HEIGHT, restored_height));

        try zapp.sdl_app.init(.{ .video = true, .events = true, .gamepad = false });
        zapp.clipboard.init();

        const window = zapp.sdl_app.createWindow("SpiderApp GUI", initial_width, initial_height, c.SDL_WINDOW_RESIZABLE) catch {
            return error.SdlWindowCreateFailed;
        };
        errdefer c.SDL_DestroyWindow(window);
        _ = c.SDL_SetWindowMinimumSize(window, MIN_MAIN_WINDOW_WIDTH, MIN_MAIN_WINDOW_HEIGHT);
        if (config.window_x) |window_x| {
            if (config.window_y) |window_y| {
                _ = c.SDL_SetWindowPosition(window, window_x, window_y);
            }
        }

        var gpu = try zapp.multi_window_renderer.Shared.init(allocator, window);
        errdefer gpu.deinit();

        const swapchain = zapp.multi_window_renderer.WindowSwapchain.initMain(&gpu, window);

        zapp.sdl_app.startTextInput(window);

        // Initialize theme - use clean theme (light mode as default for clean look)
        zui.theme.setMode(.light);
        zui.ui.theme.setMode(.light);

        // Initialize workspace with default panels
        var ws = try workspace.Workspace.initDefault(allocator);
        errdefer ws.deinit(allocator);

        // Replace the default chat panel session key with null for now
        for (ws.panels.items) |*panel| {
            if (panel.kind == .Chat) {
                if (panel.data.Chat.session_key) |key| {
                    allocator.free(key);
                    panel.data.Chat.session_key = null;
                }
                if (panel.data.Chat.agent_id) |id| {
                    allocator.free(id);
                    panel.data.Chat.agent_id = try allocator.dupe(u8, "spider");
                }
            }
        }

        var credential_store = credential_store_mod.CredentialStore.init(allocator) catch |err| blk: {
            std.log.warn("Failed to initialize credential store: {s}; using local fallback", .{@errorName(err)});
            break :blk try credential_store_mod.CredentialStore.initForTesting(allocator, .file_fallback, ".");
        };
        errdefer credential_store.deinit();
        const selected_profile_id = config.selectedProfileId();
        if (credential_store.load(selected_profile_id, "role_admin") catch null) |token| {
            defer allocator.free(token);
            config.setRoleToken(.admin, token) catch {};
        }
        if (credential_store.load(selected_profile_id, "role_user") catch null) |token| {
            defer allocator.free(token);
            config.setRoleToken(.user, token) catch {};
        }

        // Initialize settings panel with config values
        var settings_panel = SettingsPanel.init(allocator);
        settings_panel.server_url.clearRetainingCapacity();
        settings_panel.server_url.appendSlice(allocator, config.server_url) catch {};
        settings_panel.project_id.clearRetainingCapacity();
        if (config.selectedProject()) |value| {
            settings_panel.project_id.appendSlice(allocator, value) catch {};
            if (!isSystemProjectId(value)) {
                if (config.getProjectToken(value)) |project_token| {
                    settings_panel.project_token.clearRetainingCapacity();
                    settings_panel.project_token.appendSlice(allocator, project_token) catch {};
                }
            }
        }
        if (config.getRoleToken(.admin).len > 0) {
            settings_panel.project_operator_token.clearRetainingCapacity();
            settings_panel.project_operator_token.appendSlice(allocator, config.getRoleToken(.admin)) catch {};
        }
        settings_panel.default_session.clearRetainingCapacity();
        if (config.default_session) |value| {
            settings_panel.default_session.appendSlice(allocator, value) catch {};
        } else {
            settings_panel.default_session.appendSlice(allocator, "main") catch {};
        }
        settings_panel.default_agent.clearRetainingCapacity();
        if (config.selectedAgent()) |value| {
            settings_panel.default_agent.appendSlice(allocator, value) catch {};
        }
        if (config.ui_theme) |value| {
            settings_panel.ui_theme.clearRetainingCapacity();
            settings_panel.ui_theme.appendSlice(allocator, value) catch {};
        }
        if (config.ui_profile) |value| {
            settings_panel.ui_profile.clearRetainingCapacity();
            settings_panel.ui_profile.appendSlice(allocator, value) catch {};
        }
        if (config.ui_theme_pack) |value| {
            settings_panel.ui_theme_pack.clearRetainingCapacity();
            settings_panel.ui_theme_pack.appendSlice(allocator, value) catch {};
        }
        settings_panel.watch_theme_pack = config.ui_watch_theme_pack;
        settings_panel.ws_verbose_logs = config.gui_verbose_ws_logs;
        settings_panel.auto_connect_on_launch = config.auto_connect_on_launch;
        settings_panel.terminal_backend_kind = terminal_render_backend.Backend.parseKind(
            config.selectedTerminalBackend() orelse TERMINAL_BACKEND_KIND,
        );

        var app = App{
            .allocator = allocator,
            .window = window,
            .gpu = gpu,
            .swapchain = swapchain,
            .settings_panel = settings_panel,
            .client_context = undefined,
            .agent_registry = undefined,
            .status_text = try allocator.dupe(u8, "Not connected"),
            .theme = zui.theme.current(),
            .ui_scale = 1.0,
            .metrics_context = undefined,
            .config = config,
            .ui_commands = zui.ui.render.command_list.CommandList.init(allocator),
            .ui_inbox = ui_command_inbox.UiCommandInbox.init(allocator),
            .frame_clock = zapp.frame_clock.FrameClock.init(60),
            .debug_folded_blocks = std.AutoHashMap(DebugFoldKey, void).init(allocator),
            .terminal_backend_kind = settings_panel.terminal_backend_kind,
            .terminal_backend = initTerminalBackend(settings_panel.terminal_backend_kind),
            .manager = undefined,
            .credential_store = credential_store,
        };
        app.configurePerfAutomationFromEnv();
        app.launcher_project_filter.appendSlice(allocator, "") catch {};
        app.launcher_profile_name.appendSlice(allocator, "") catch {};
        app.launcher_profile_metadata.appendSlice(allocator, "") catch {};
        app.launcher_connect_token.appendSlice(allocator, "") catch {};
        app.syncLauncherSelectionFromConfig();
        app.applyLauncherSelectedProfile() catch {};
        app.node_service_watch_filter.appendSlice(allocator, "") catch {};
        app.node_service_watch_replay_limit.appendSlice(allocator, "25") catch {};
        app.debug_search_filter.appendSlice(allocator, "") catch {};
        app.perf_benchmark_label_input.appendSlice(allocator, "") catch {};
        app.contract_invoke_payload.appendSlice(allocator, "{}") catch {};
        app.applyThemeFromSettings();
        app.metrics_context = ui_draw_context.DrawContext.init(
            allocator,
            .{ .direct = .{} },
            zui.ui.theme.activeTheme(),
            UiRect.fromMinSize(.{ 0.0, 0.0 }, .{ 1.0, 1.0 }),
        );
        errdefer app.metrics_context.deinit();

        app.client_context = try client_state.ClientContext.init(allocator);
        errdefer app.client_context.deinit();
        app.agent_registry = client_agents.AgentRegistry.initEmpty(allocator);
        errdefer app.agent_registry.deinit(allocator);

        app.manager = panel_manager.PanelManager.init(allocator, ws, &app.next_panel_id);
        app.bindNextPanelId(&app.manager);
        errdefer app.manager.deinit();
        app.migrateLegacyHostPanels(&app.manager);
        app.focusSettingsPanel(&app.manager);

        app.captureWorkspaceSnapshot(&app.manager);
        try app.filesystem_path.appendSlice(allocator, "/");

        if (app.config.default_session) |default_session| {
            const seed = if (default_session.len > 0) default_session else "main";
            app.ensureSessionExists(seed, seed) catch {};
        } else {
            app.ensureSessionExists("main", "Main") catch {};
        }

        const main_window = try app.createUiWindowFromExisting(
            window,
            "SpiderApp GUI",
            &app.manager,
            true,
            false,
            false,
            false,
        );
        try app.ui_windows.append(allocator, main_window);
        app.main_window_id = main_window.id;
        _ = c.SDL_SetWindowTitle(window, "SpiderApp - Launcher");

        errdefer app.settings_panel.deinit(allocator);
        errdefer allocator.free(app.status_text);

        ui_sdl_input_backend.init(allocator);
        ui_input_router.setBackend(ui_input_backend.sdl3);

        // Cleanup on initialization failure after this point
        errdefer {
            var i: usize = 0;
            while (i < app.ui_windows.items.len) : (i += 1) {
                app.destroyUiWindow(app.ui_windows.items[i]);
            }
            app.ui_windows.clearRetainingCapacity();
            app.ui_windows.deinit(app.allocator);
        }
        return app;
    }

    pub fn deinit(self: *App) void {
        self.persistMainWindowGeometry();
        self.disconnect();
        self.clearSessions();
        self.chat_sessions.deinit(self.allocator);
        self.session_messages.deinit(self.allocator);
        workspace_types.deinitProjectList(self.allocator, &self.projects);
        workspace_types.deinitNodeList(self.allocator, &self.nodes);
        if (self.workspace_state) |*status| {
            status.deinit(self.allocator);
            self.workspace_state = null;
        }
        if (self.workspace_last_error) |value| {
            self.allocator.free(value);
            self.workspace_last_error = null;
        }
        self.stopFilesystemWorker();
        self.filesystem_active_request = null;
        self.clearPendingFilesystemPathLoad();
        self.clearFsrpcRemoteError();
        self.clearDebugStreamSnapshot();
        self.clearDebugEvents();
        self.debug_events.deinit(self.allocator);
        self.debug_filtered_indices.deinit(self.allocator);
        self.debug_folded_blocks.deinit();
        self.debug_event_fingerprint_set.deinit(self.allocator);
        self.invalidateWorkspaceSnapshot();
        if (self.pending_send_request_id) |request_id| self.allocator.free(request_id);
        if (self.pending_send_message_id) |message_id| self.allocator.free(message_id);
        if (self.pending_send_session_key) |session_key| self.allocator.free(session_key);
        if (self.pending_send_job_id) |job_id| self.allocator.free(job_id);
        if (self.pending_send_jobs_root) |jobs_root| self.allocator.free(jobs_root);
        if (self.pending_send_thoughts_root) |thoughts_root| self.allocator.free(thoughts_root);
        if (self.pending_send_correlation_id) |corr| self.allocator.free(corr);
        if (self.pending_send_thought_message_id) |message_id| self.allocator.free(message_id);
        if (self.pending_send_last_thought_text) |thought| self.allocator.free(thought);
        self.clearFilesystemData();
        self.clearFilesystemDirCache();
        self.filesystem_path.deinit(self.allocator);
        self.clearContractServices();
        self.contract_invoke_payload.deinit(self.allocator);
        self.clearTerminalState();
        self.terminal_input.deinit(self.allocator);
        self.terminal_backend.deinit(self.allocator);
        self.node_service_watch_filter.deinit(self.allocator);
        self.node_service_watch_replay_limit.deinit(self.allocator);
        self.debug_search_filter.deinit(self.allocator);
        self.perf_benchmark_label_input.deinit(self.allocator);
        if (self.perf_benchmark_active_label) |value| self.allocator.free(value);
        if (self.perf_benchmark_last_label) |value| self.allocator.free(value);
        if (self.perf_automation_report_path) |value| self.allocator.free(value);
        self.clearNodeServiceReloadDiagnostics();
        self.clearNodeServiceDiffPreview();
        self.clearTextEditHistory();
        self.text_edit_undo_stack.deinit(self.allocator);
        self.text_edit_redo_stack.deinit(self.allocator);
        self.perf_history.deinit(self.allocator);

        zui.ChatView(ChatMessage).deinit(&self.chat_panel_state.view, self.allocator);

        self.settings_panel.deinit(self.allocator);
        self.chat_input.deinit(self.allocator);
        self.launcher_project_filter.deinit(self.allocator);
        self.launcher_profile_name.deinit(self.allocator);
        self.launcher_profile_metadata.deinit(self.allocator);
        self.launcher_connect_token.deinit(self.allocator);
        if (self.launcher_notice) |value| self.allocator.free(value);
        if (self.active_profile_id) |value| self.allocator.free(value);
        if (self.active_project_id) |value| self.allocator.free(value);
        self.credential_store.deinit();
        self.client_context.deinit();
        self.agent_registry.deinit(self.allocator);

        self.metrics_context.deinit();
        self.ui_commands.deinit();
        self.ui_inbox.deinit(self.allocator);
        self.manager.deinit();
        while (self.ui_windows.items.len > 0) {
            const maybe_window = self.ui_windows.pop();
            if (maybe_window) |window| self.destroyUiWindow(window);
        }
        self.ui_windows.deinit(self.allocator);
        zui.ui.main_window.deinit(self.allocator);
        ui_input_router.deinit(self.allocator);
        ui_sdl_input_backend.deinit();

        self.allocator.free(self.status_text);
        self.config.deinit();

        self.swapchain.deinit();
        self.gpu.deinit();

        zapp.sdl_app.stopTextInput(self.window);
        c.SDL_DestroyWindow(self.window);
        zapp.sdl_app.deinit();
    }

    pub fn run(self: *App) !void {
        while (self.running) {
            const frame_started_ns = std.time.nanoTimestamp();
            var frame_draw_ns: i128 = 0;
            self.perf_frame_panel_ns = .{};
            self.perf_frame_cmd_stats = .{};
            self.bindMainWindowManager();
            self.debug_frame_counter += 1;
            _ = self.frame_clock.beginFrame();
            const polled = zapp.sdl_app.pollEventsToInput();
            _ = ui_input_router.beginFrame(self.allocator);
            if (polled.quit_requested) {
                self.running = false;
            }

            if (polled.window_close_requested and polled.window_close_id == self.main_window_id) {
                self.running = false;
            }

            if (polled.window_close_requested and polled.window_close_id != self.main_window_id) {
                self.closeUiWindowById(polled.window_close_id);
            }

            var requested_spawn_window = false;
            var i: usize = 0;
            while (i < self.ui_windows.items.len) : (i += 1) {
                const window = self.ui_windows.items[i];
                const manager = self.managerForWindow(window);
                if ((window.id == self.main_window_id or window.window == self.window) and window.manager != manager) {
                    window.manager = manager;
                    window.owns_manager = false;
                }
                if (@intFromPtr(manager) == 0) {
                    std.log.err("run: window manager pointer is null (window_id={d})", .{window.id});
                    self.drawUnavailableWorkspaceFrame(window, "Workspace manager pointer is null");
                    continue;
                }
                self.bindNextPanelId(manager);
                const manager_healthy = self.ensureWindowManagerHealthy(manager);
                window.queue.clear(self.allocator);
                self.mouse_clicked = false;
                self.mouse_released = false;
                self.mouse_right_clicked = false;

                // Get DPI scale for window-specific rendering
                const dpi_scale_raw: f32 = c.SDL_GetWindowDisplayScale(window.window);
                const dpi_scale: f32 = if (dpi_scale_raw > 0.0) dpi_scale_raw else 1.0;
                if (@abs(self.ui_scale - dpi_scale) > 0.001) {
                    self.ui_scale = dpi_scale;
                    self.invalidateGlyphWidthCache();
                } else {
                    self.ui_scale = dpi_scale;
                }
                zui.ui.theme.applyTypography(dpi_scale);

                if (!manager_healthy) {
                    ui_input_router.setExternalQueue(&window.queue);
                    zapp.sdl_app.collectWindowInput(self.allocator, window.window, &window.queue);
                    self.drawUnavailableWorkspaceFrame(window, "Unable to recover workspace state");
                    ui_input_state.endFrame(&window.queue);
                    ui_input_router.setExternalQueue(null);
                    continue;
                }

                ui_input_router.setExternalQueue(&window.queue);
                zapp.sdl_app.collectWindowInput(self.allocator, window.window, &window.queue);
                try self.processInputEvents(&window.queue, &requested_spawn_window, window, manager);

                ui_input_router.setExternalQueue(&window.queue);
                const draw_started_ns = std.time.nanoTimestamp();
                self.drawFrame(window);
                frame_draw_ns += std.time.nanoTimestamp() - draw_started_ns;
                ui_input_state.endFrame(&window.queue);
                ui_input_router.setExternalQueue(null);
            }

            if (requested_spawn_window) {
                self.spawnUiWindow() catch |err| {
                    std.log.err("Failed to spawn additional window: {s}", .{@errorName(err)});
                };
            }

            if (self.pending_close_window_id) |window_id| {
                self.pending_close_window_id = null;
                self.closeUiWindowById(window_id);
            }

            const ws_started_ns = std.time.nanoTimestamp();
            try self.pollWebSocket();
            const ws_elapsed_ns = std.time.nanoTimestamp() - ws_started_ns;

            const fs_started_ns = std.time.nanoTimestamp();
            self.pollFilesystemWorker();
            const fs_elapsed_ns = std.time.nanoTimestamp() - fs_started_ns;

            const debug_started_ns = std.time.nanoTimestamp();
            self.pollDebugStream();
            const debug_elapsed_ns = std.time.nanoTimestamp() - debug_started_ns;

            const node_service_started_ns = std.time.nanoTimestamp();
            self.pollNodeServiceSnapshot();
            const node_service_elapsed_ns = std.time.nanoTimestamp() - node_service_started_ns;

            const terminal_started_ns = std.time.nanoTimestamp();
            self.pollTerminalSession();
            const terminal_elapsed_ns = std.time.nanoTimestamp() - terminal_started_ns;
            if (self.pending_send_job_id != null and self.ws_client != null and self.pending_send_resume_notified) {
                _ = self.tryResumePendingSendJob() catch {};
            }
            const frame_elapsed_ns = std.time.nanoTimestamp() - frame_started_ns;
            self.recordPerfSample(frame_elapsed_ns, ws_elapsed_ns, fs_elapsed_ns, debug_elapsed_ns + node_service_elapsed_ns, terminal_elapsed_ns, frame_draw_ns);
            try self.pollPerfAutomation();
            self.frame_clock.endFrame();
        }
    }

    fn envTruthy(value: []const u8) bool {
        if (value.len == 0) return false;
        if (std.mem.eql(u8, value, "1")) return true;
        if (std.ascii.eqlIgnoreCase(value, "true")) return true;
        if (std.ascii.eqlIgnoreCase(value, "yes")) return true;
        if (std.ascii.eqlIgnoreCase(value, "on")) return true;
        return false;
    }

    fn configurePerfAutomationFromEnv(self: *App) void {
        const enabled_raw = std.process.getEnvVarOwned(self.allocator, "ZSS_GUI_PERF_AUTOMATION") catch null;
        defer if (enabled_raw) |value| self.allocator.free(value);
        if (enabled_raw == null or !envTruthy(enabled_raw.?)) return;

        self.perf_automation_enabled = true;

        const duration_raw = std.process.getEnvVarOwned(self.allocator, "ZSS_GUI_PERF_AUTOMATION_DURATION_MS") catch null;
        defer if (duration_raw) |value| self.allocator.free(value);
        if (duration_raw) |value| {
            const parsed = std.fmt.parseInt(i64, value, 10) catch self.perf_automation_duration_ms;
            self.perf_automation_duration_ms = std.math.clamp(parsed, 1_000, 120_000);
        }

        const min_fps_raw = std.process.getEnvVarOwned(self.allocator, "ZSS_GUI_PERF_AUTOMATION_MIN_FPS") catch null;
        defer if (min_fps_raw) |value| self.allocator.free(value);
        if (min_fps_raw) |value| {
            const parsed = std.fmt.parseFloat(f32, value) catch -1.0;
            if (parsed > 0.0) self.perf_automation_min_fps = parsed;
        }

        const report_raw = std.process.getEnvVarOwned(self.allocator, "ZSS_GUI_PERF_AUTOMATION_REPORT") catch null;
        defer if (report_raw) |value| self.allocator.free(value);
        if (report_raw) |value| {
            const trimmed = std.mem.trim(u8, value, " \t\r\n");
            if (trimmed.len > 0) {
                if (self.perf_automation_report_path) |existing| self.allocator.free(existing);
                self.perf_automation_report_path = self.allocator.dupe(u8, trimmed) catch null;
            }
        }
    }

    fn pollPerfAutomation(self: *App) !void {
        if (!self.perf_automation_enabled) return;

        const now_ms = std.time.milliTimestamp();
        if (!self.perf_automation_started) {
            self.perf_benchmark_label_input.clearRetainingCapacity();
            try self.perf_benchmark_label_input.appendSlice(self.allocator, "ci-auto");
            self.startPerfBenchmark() catch {};
            self.perf_automation_started = true;
            self.perf_automation_start_ms = now_ms;
            return;
        }

        if (now_ms - self.perf_automation_start_ms < self.perf_automation_duration_ms) return;

        if (self.perf_benchmark_active) self.stopPerfBenchmark() catch {};

        const report_opt = try self.buildBenchmarkPerfReportText();
        defer if (report_opt) |value| self.allocator.free(value);
        if (report_opt) |report| {
            if (self.perf_automation_report_path) |path| {
                std.fs.cwd().writeFile(.{ .sub_path = path, .data = report }) catch |err| {
                    std.log.warn("perf automation report write failed ({s}): {s}", .{ path, @errorName(err) });
                };
            }
        }

        if (self.perf_automation_min_fps) |min_fps| {
            if (self.perf_last_fps < min_fps) {
                std.log.err(
                    "GUI perf automation gate failed: fps={d:.2} min={d:.2}",
                    .{ self.perf_last_fps, min_fps },
                );
                return error.PerfGateFailed;
            }
        }

        self.running = false;
    }

    fn bindMainWindowManager(self: *App) void {
        var i: usize = 0;
        while (i < self.ui_windows.items.len) : (i += 1) {
            const window = self.ui_windows.items[i];
            if (window.id != self.main_window_id and window.window != self.window) continue;
            if (window.manager != &self.manager) {
                if (self.shouldLogDebug(1200)) {
                    std.log.debug(
                        "bindMainWindowManager: repairing stale main window manager pointer (old=0x{x}, expected=0x{x})",
                        .{ @intFromPtr(window.manager), @intFromPtr(&self.manager) },
                    );
                }
                window.manager = &self.manager;
                window.owns_manager = false;
            }
            return;
        }
    }

    fn managerForWindow(self: *App, ui_window: *UiWindow) *panel_manager.PanelManager {
        if (ui_window.id == self.main_window_id or ui_window.window == self.window) {
            return &self.manager;
        }
        return ui_window.manager;
    }

    fn createUiWindowFromExisting(
        self: *App,
        window: *c.SDL_Window,
        title: []const u8,
        manager: *panel_manager.PanelManager,
        is_main_swapchain: bool,
        persist_in_workspace: bool,
        owns_manager: bool,
        owns_swapchain: bool,
    ) !*UiWindow {
        const title_copy = try self.allocator.dupe(u8, title);
        errdefer self.allocator.free(title_copy);

        const swapchain = if (is_main_swapchain)
            zapp.multi_window_renderer.WindowSwapchain.initMain(&self.gpu, window)
        else
            try zapp.multi_window_renderer.WindowSwapchain.initOwned(&self.gpu, window);

        const out = try self.allocator.create(UiWindow);
        errdefer self.allocator.destroy(out);

        out.* = .{
            .window = window,
            .id = c.SDL_GetWindowID(window),
            .queue = ui_input_state.InputQueue.init(self.allocator),
            .swapchain = swapchain,
            .manager = manager,
            .title = title_copy,
            .persist_in_workspace = persist_in_workspace,
            .owns_manager = owns_manager,
            .owns_swapchain = owns_swapchain,
        };
        return out;
    }

    fn destroyUiWindow(self: *App, w: *UiWindow) void {
        w.queue.deinit(self.allocator);

        if (w.owns_swapchain) {
            w.swapchain.deinit();
        }
        if (w.owns_manager) {
            w.manager.deinit();
            self.allocator.destroy(w.manager);
        }
        self.allocator.free(w.title);
        if (w.window != self.window) {
            c.SDL_DestroyWindow(w.window);
        }
        self.allocator.destroy(w);
    }

    fn closeUiWindowById(self: *App, window_id: u32) void {
        var i: usize = 0;
        while (i < self.ui_windows.items.len) : (i += 1) {
            const w = self.ui_windows.items[i];
            if (w.id == window_id and w.id != self.main_window_id) {
                if (self.windows_menu_open_window_id != null and self.windows_menu_open_window_id.? == w.id) {
                    self.windows_menu_open_window_id = null;
                }
                _ = self.ui_windows.swapRemove(i);
                if (w.persist_in_workspace) {
                    self.attachDetachedPanelsToMain(w.manager);
                }
                self.destroyUiWindow(w);
                return;
            }
        }
    }

    fn attachDetachedPanelsToMain(self: *App, source_manager: *panel_manager.PanelManager) void {
        if (source_manager == &self.manager) return;
        self.bindNextPanelId(source_manager);
        self.bindNextPanelId(&self.manager);

        if (!self.isWorkspaceStateReasonable(source_manager)) {
            std.log.warn("attachDetachedPanelsToMain: source workspace unhealthy, attempting recovery", .{});
            self.tryDeinitWorkspaceForReset(source_manager);
            if (!self.isWorkspaceStateReasonable(source_manager)) {
                source_manager.workspace = workspace.Workspace.initEmpty(self.allocator);
                return;
            }
        }

        if (source_manager.workspace.panels.items.len > MAX_REASONABLE_PANEL_COUNT) {
            std.log.warn("attachDetachedPanelsToMain: source panels unreasonable ({d}), discarding source workspace", .{
                source_manager.workspace.panels.items.len,
            });
            self.tryDeinitWorkspaceForReset(source_manager);
            source_manager.workspace = workspace.Workspace.initEmpty(self.allocator);
            return;
        }

        if (source_manager.workspace.panels.items.len == 0) {
            source_manager.workspace.focused_panel_id = null;
            source_manager.workspace.dock_layout.clear();
            source_manager.workspace.dock_layout.root = null;
            source_manager.workspace.markDirty();
            return;
        }

        while (source_manager.workspace.panels.items.len > 0) {
            const panel_id = source_manager.workspace.panels.items[source_manager.workspace.panels.items.len - 1].id;
            if (source_manager.takePanel(panel_id)) |moved_panel| {
                self.appendPanelToManager(&self.manager, moved_panel) catch {
                    var fallback = moved_panel;
                    fallback.deinit(self.allocator);
                };
            } else {
                break;
            }
        }

        if (self.manager.workspace.syncDockLayout() catch false) {
            self.manager.workspace.markDirty();
        }

        source_manager.workspace.dock_layout.clear();
        source_manager.workspace.dock_layout.root = null;
        source_manager.workspace.focused_panel_id = null;
        source_manager.workspace.markDirty();
        self.recomputeManagerNextId(source_manager);
    }

    fn cloneWorkspace(self: *App, src: *const workspace.Workspace) !workspace.Workspace {
        var snapshot = try src.toSnapshot(self.allocator);
        defer snapshot.deinit(self.allocator);
        return try workspace.Workspace.fromSnapshot(self.allocator, snapshot);
    }

    fn remapWorkspacePanelIds(
        self: *App,
        ws: *workspace.Workspace,
        next_panel_id: *workspace.PanelId,
    ) !void {
        var map = std.AutoHashMap(workspace.PanelId, workspace.PanelId).init(self.allocator);
        defer map.deinit();

        for (ws.panels.items) |*panel| {
            const old_id = panel.id;
            const new_id = next_panel_id.*;
            next_panel_id.* += 1;
            panel.id = new_id;
            try map.put(old_id, new_id);
        }

        if (ws.focused_panel_id) |old_focus| {
            ws.focused_panel_id = map.get(old_focus);
        }
    }

    fn cloneWorkspaceRemap(
        self: *App,
        src: *const workspace.Workspace,
        next_panel_id: *workspace.PanelId,
    ) !workspace.Workspace {
        var ws = try self.cloneWorkspace(src);
        errdefer ws.deinit(self.allocator);
        try self.remapWorkspacePanelIds(&ws, next_panel_id);
        _ = try ws.syncDockLayout();
        return ws;
    }

    fn spawnUiWindow(self: *App) !void {
        const width: c_int = 960;
        const height: c_int = 720;
        const title = try std.fmt.allocPrint(self.allocator, "SpiderApp GUI ({d})", .{self.ui_windows.items.len});
        defer self.allocator.free(title);
        const title_with_null = try self.allocator.alloc(u8, title.len + 1);
        defer self.allocator.free(title_with_null);
        @memcpy(title_with_null[0..title.len], title);
        title_with_null[title.len] = 0;
        const title_z: [:0]const u8 = title_with_null[0..title.len :0];

        const win = zapp.sdl_app.createWindow(title_z, width, height, c.SDL_WINDOW_RESIZABLE) catch {
            return error.SdlWindowCreateFailed;
        };
        errdefer c.SDL_DestroyWindow(win);

        var pos_x: c_int = 0;
        var pos_y: c_int = 0;
        _ = c.SDL_GetWindowPosition(self.window, &pos_x, &pos_y);
        const offset: c_int = @intCast(@min(self.ui_windows.items.len * 24, 220));
        _ = c.SDL_SetWindowPosition(win, pos_x + offset, pos_y + offset);

        var cloned_workspace = try self.cloneWorkspaceRemap(&self.manager.workspace, &self.next_panel_id);
        var should_cleanup_workspace = true;
        errdefer if (should_cleanup_workspace) cloned_workspace.deinit(self.allocator);

        const new_manager = try self.allocator.create(panel_manager.PanelManager);
        errdefer self.allocator.destroy(new_manager);

        var should_cleanup_new_manager = true;
        new_manager.* = panel_manager.PanelManager.init(
            self.allocator,
            cloned_workspace,
            &self.next_panel_id,
        );
        self.bindNextPanelId(new_manager);
        should_cleanup_workspace = false;
        errdefer if (should_cleanup_new_manager) {
            new_manager.deinit();
            self.allocator.destroy(new_manager);
        };

        const new_window = try self.createUiWindowFromExisting(
            win,
            title,
            new_manager,
            false,
            true,
            true,
            true,
        );
        should_cleanup_new_manager = false;
        self.ui_windows.append(self.allocator, new_window) catch |err| {
            self.destroyUiWindow(new_window);
            return err;
        };
    }

    fn processInputEvents(
        self: *App,
        queue: *ui_input_state.InputQueue,
        request_spawn_window: *bool,
        ui_window: *UiWindow,
        manager: *panel_manager.PanelManager,
    ) !void {
        self.mouse_x = queue.state.mouse_pos[0];
        self.mouse_y = queue.state.mouse_pos[1];
        self.mouse_down = queue.state.mouse_down_left;
        if (self.drag_mouse_capture_active) {
            self.syncMouseStateFromGlobal(ui_window);
        }

        for (queue.events.items) |evt| {
            switch (evt) {
                .mouse_down => |md| {
                    if (md.button == .left) self.mouse_clicked = true;
                    if (md.button == .right) self.mouse_right_clicked = true;
                },
                .mouse_up => |mu| {
                    if (mu.button == .left) self.mouse_released = true;
                    if (mu.button == .left) self.text_input_dragging = false;
                },
                .key_down => |ke| {
                    try self.handleKeyDownEvent(ke, request_spawn_window, manager);
                },
                .text_input => |txt| {
                    try self.handleTextInput(txt.text);
                },
                .mouse_wheel => |mw| {
                    const mouse_pos = .{ self.mouse_x, self.mouse_y };
                    var handled_debug_scroll = self.debug_output_rect.contains(mouse_pos);
                    if (!handled_debug_scroll) {
                        if (self.debug_panel_id) |panel_id| {
                            handled_debug_scroll = self.isPanelFocused(manager, panel_id);
                        }
                    }
                    if (handled_debug_scroll) {
                        self.debug_scroll_y -= mw.delta[1] * 40.0 * self.ui_scale;
                        if (self.debug_scroll_y < 0.0) self.debug_scroll_y = 0.0;
                        if (self.debug_panel_id) |panel_id| {
                            manager.focusPanel(panel_id);
                        }
                    }
                    if (!handled_debug_scroll) {
                        if (self.focusedFormScrollY(manager)) |scroll_y| {
                            scroll_y.* -= mw.delta[1] * 40.0 * self.ui_scale;
                        }
                    }
                },
                else => {},
            }
        }
        // Only clear active form-scroll drag while processing the main window.
        // Secondary windows can report mouse-up while the drag is still active
        // in the source window.
        if (!self.mouse_down and ui_window.id == self.main_window_id) {
            self.form_scroll_drag_target = .none;
            self.debug_scrollbar_dragging = false;
            self.setDragMouseCapture(false);
        }
        if (self.settings_panel.focused_field == .none) {
            self.text_input_selection_anchor = null;
            self.text_input_context_menu_open = false;
            self.text_input_context_menu_rect = null;
            self.text_input_dragging = false;
            self.text_input_cursor_initialized = false;
        }

        if (self.ui_stage == .launcher) return;
        if (self.text_input_context_menu_open) return;

        var dock_area = self.dockViewportForWindow(ui_window) orelse blk: {
            var fb_w: c_int = 0;
            var fb_h: c_int = 0;
            _ = c.SDL_GetWindowSizeInPixels(ui_window.window, &fb_w, &fb_h);
            break :blk UiRect.fromMinSize(
                .{ 0.0, 0.0 },
                .{
                    if (fb_w > 0) @floatFromInt(fb_w) else 1.0,
                    if (fb_h > 0) @floatFromInt(fb_h) else 1.0,
                },
            );
        };
        const dock_area_size = dock_area.size();
        if (dock_area_size[0] <= 1.0 or dock_area_size[1] <= 1.0) {
            var fb_w: c_int = 0;
            var fb_h: c_int = 0;
            _ = c.SDL_GetWindowSizeInPixels(ui_window.window, &fb_w, &fb_h);
            dock_area = UiRect.fromMinSize(
                .{ 0.0, 0.0 },
                .{
                    if (fb_w > 0) @floatFromInt(fb_w) else 1.0,
                    if (fb_h > 0) @floatFromInt(fb_h) else 1.0,
                },
            );
        }

        var tab_hits = DockTabHitList{};
        var drop_targets = DockDropTargetList{};
        self.collectDockInteractionGeometry(manager, dock_area, &tab_hits, &drop_targets);

        const splitters = manager.workspace.dock_layout.computeSplitters(dock_area);
        if (self.handleDockSplitInteractions(queue, ui_window, manager, &splitters)) {
            manager.workspace.markDirty();
        }

        const dock_result = self.handleDockTabInteractions(
            queue,
            manager,
            ui_window,
            &tab_hits,
            &drop_targets,
            dock_area,
        );
        if (dock_result.changed_layout) {
            manager.workspace.markDirty();
        }
        if (dock_result.focus_panel_id) |panel_id| {
            manager.focusPanel(panel_id);
        }
        if (dock_result.detach_panel_id) |panel_id| {
            self.handleDockDetachRequest(ui_window, panel_id);
        }
    }

    fn findSplitterAt(splitters: *const dock_graph.SplitterResult, pos: [2]f32) ?dock_graph.Splitter {
        var idx: usize = splitters.len;
        while (idx > 0) {
            idx -= 1;
            const splitter = splitters.splitters[idx];
            if (splitter.handle_rect.contains(pos)) return splitter;
        }
        return null;
    }

    fn findSplitterByNode(
        splitters: *const dock_graph.SplitterResult,
        node_id: dock_graph.NodeId,
    ) ?dock_graph.Splitter {
        for (splitters.slice()) |splitter| {
            if (splitter.node_id == node_id) return splitter;
        }
        return null;
    }

    fn handleDockSplitInteractions(
        self: *App,
        queue: *ui_input_state.InputQueue,
        ui_window: *UiWindow,
        manager: *panel_manager.PanelManager,
        splitters: *const dock_graph.SplitterResult,
    ) bool {
        _ = self;
        const split_drag = &ui_window.ui_state.split_drag;
        var changed = false;

        for (queue.events.items) |evt| {
            switch (evt) {
                .focus_lost => split_drag.clear(),
                .mouse_down => |md| {
                    if (md.button != .left) continue;
                    if (findSplitterAt(splitters, md.pos)) |splitter| {
                        split_drag.node_id = splitter.node_id;
                        split_drag.axis = splitter.axis;
                    }
                },
                .mouse_up => |mu| {
                    if (mu.button == .left) split_drag.clear();
                },
                else => {},
            }
        }

        const dragging_node = split_drag.node_id orelse return changed;
        const active_splitter = findSplitterByNode(splitters, dragging_node) orelse {
            split_drag.clear();
            return changed;
        };

        const container = active_splitter.container_rect;
        const size = container.size();
        const min_px: f32 = 120.0;

        if (active_splitter.axis == .vertical and size[0] > 0.0) {
            const min_ratio = std.math.clamp(min_px / size[0], 0.05, 0.45);
            const max_ratio = 1.0 - min_ratio;
            const ratio = std.math.clamp((queue.state.mouse_pos[0] - container.min[0]) / size[0], min_ratio, max_ratio);
            if (manager.workspace.dock_layout.setSplitRatio(active_splitter.node_id, ratio)) {
                changed = true;
            }
        } else if (active_splitter.axis == .horizontal and size[1] > 0.0) {
            const min_ratio = std.math.clamp(min_px / size[1], 0.05, 0.45);
            const max_ratio = 1.0 - min_ratio;
            const ratio = std.math.clamp((queue.state.mouse_pos[1] - container.min[1]) / size[1], min_ratio, max_ratio);
            if (manager.workspace.dock_layout.setSplitRatio(active_splitter.node_id, ratio)) {
                changed = true;
            }
        }

        if (!queue.state.mouse_down_left) split_drag.clear();
        return changed;
    }

    fn handleDockTabInteractions(
        self: *App,
        queue: *ui_input_state.InputQueue,
        manager: *panel_manager.PanelManager,
        ui_window: *UiWindow,
        tab_hits: *const DockTabHitList,
        drop_targets: *const DockDropTargetList,
        dock_rect: UiRect,
    ) DockInteractionResult {
        const drag_state = &ui_window.ui_state.dock_drag;
        var out = DockInteractionResult{};
        var left_release = false;
        var mouse_up_pos: ?[2]f32 = null;

        for (queue.events.items) |evt| {
            switch (evt) {
                .focus_lost => {
                    if (drag_state.panel_id) |pid| {
                        if (drag_state.dragging) {
                            out.detach_panel_id = pid;
                            out.focus_panel_id = pid;
                        }
                    }
                    drag_state.clear();
                },
                .mouse_down => |md| {
                    if (md.button != .left) continue;
                    if (findTabHitAt(tab_hits, md.pos)) |hit| {
                        drag_state.panel_id = hit.panel_id;
                        drag_state.source_node_id = hit.node_id;
                        drag_state.source_tab_index = hit.tab_index;
                        drag_state.press_pos = md.pos;
                        drag_state.dragging = false;
                    }
                },
                .mouse_up => |mu| {
                    if (mu.button == .left) {
                        left_release = true;
                        mouse_up_pos = mu.pos;
                    }
                },
                else => {},
            }
        }

        if (drag_state.panel_id) |panel_id| {
            if (self.findPanelById(manager, panel_id) == null) {
                drag_state.clear();
            }
        }

        if (drag_state.panel_id != null and queue.state.mouse_down_left and !left_release) {
            if (!drag_state.dragging) {
                const dx = queue.state.mouse_pos[0] - drag_state.press_pos[0];
                const dy = queue.state.mouse_pos[1] - drag_state.press_pos[1];
                if (dx * dx + dy * dy >= 16.0) {
                    drag_state.dragging = true;
                }
            }
        }

        if (left_release and drag_state.panel_id != null) {
            const drag_panel_id = drag_state.panel_id.?;
            const release_pos = mouse_up_pos orelse queue.state.mouse_pos;
            if (drag_state.dragging) {
                if (drop_targets.findAt(release_pos)) |target| {
                    const changed = if (target.location == .center)
                        manager.workspace.dock_layout.movePanelToTabs(drag_panel_id, target.node_id, null) catch false
                    else
                        manager.workspace.dock_layout.splitNodeWithPanel(target.node_id, drag_panel_id, target.location) catch false;
                    const repaired = manager.workspace.syncDockLayout() catch false;
                    if (changed or repaired) {
                        out.changed_layout = true;
                        out.focus_panel_id = drag_panel_id;
                    }
                } else if (!dock_rect.contains(release_pos)) {
                    out.detach_panel_id = drag_panel_id;
                    out.focus_panel_id = drag_panel_id;
                } else {
                    out.focus_panel_id = drag_panel_id;
                }
            } else if (findTabHitAt(tab_hits, release_pos)) |hit| {
                if (hit.panel_id == drag_panel_id) {
                    if (manager.workspace.dock_layout.setActiveTab(hit.node_id, hit.tab_index)) {
                        out.changed_layout = true;
                    }
                    out.focus_panel_id = hit.panel_id;
                }
            }
            drag_state.clear();
        } else if (!queue.state.mouse_down_left and drag_state.panel_id != null) {
            const drag_panel_id = drag_state.panel_id.?;
            if (drag_state.dragging) {
                const release_pos = queue.state.mouse_pos;
                if (drop_targets.findAt(release_pos)) |target| {
                    const changed = if (target.location == .center)
                        manager.workspace.dock_layout.movePanelToTabs(drag_panel_id, target.node_id, null) catch false
                    else
                        manager.workspace.dock_layout.splitNodeWithPanel(target.node_id, drag_panel_id, target.location) catch false;
                    const repaired = manager.workspace.syncDockLayout() catch false;
                    const committed = changed or repaired;
                    if (committed) {
                        out.changed_layout = true;
                        out.focus_panel_id = drag_panel_id;
                    } else if (!dock_rect.contains(release_pos)) {
                        out.detach_panel_id = drag_panel_id;
                        out.focus_panel_id = drag_panel_id;
                    } else {
                        out.focus_panel_id = drag_panel_id;
                    }
                } else if (!dock_rect.contains(release_pos)) {
                    out.detach_panel_id = drag_panel_id;
                    out.focus_panel_id = drag_panel_id;
                } else {
                    out.focus_panel_id = drag_panel_id;
                }
            }
            drag_state.clear();
        }

        return out;
    }

    fn handleDockDetachRequest(
        self: *App,
        source_window: *UiWindow,
        panel_id: workspace.PanelId,
    ) void {
        const source_manager = self.managerForWindow(source_window);
        const moved = source_manager.takePanel(panel_id) orelse return;
        if (source_manager.workspace.syncDockLayout() catch false) {
            source_manager.workspace.markDirty();
        }

        const remaining_panel = self.tryAttachPanelToOtherWindow(source_window, moved);
        if (remaining_panel) |panel| {
            if (!self.createDetachedWindowFromPanel(source_window, panel)) {
                source_manager.putPanel(panel) catch {
                    var tmp = panel;
                    tmp.deinit(self.allocator);
                    return;
                };
                source_manager.workspace.markDirty();
                if (source_manager.workspace.syncDockLayout() catch false) {
                    source_manager.workspace.markDirty();
                }
                source_manager.focusPanel(panel.id);
            } else {
                self.queueCloseIfNowEmptyDetachedWindow(source_window);
            }
        }
    }

    fn tryAttachPanelToOtherWindow(
        self: *App,
        source_window: *UiWindow,
        panel: workspace.Panel,
    ) ?workspace.Panel {
        var target_window: ?*UiWindow = null;
        var target_local_pos: [2]f32 = .{ 0.0, 0.0 };

        if (self.focusedWindowMouseHit(source_window.id)) |hit| {
            target_window = hit.win;
            target_local_pos = hit.local_pos;
        } else if (self.windowUnderGlobalMouse(source_window.id)) |hit| {
            target_window = hit.win;
            target_local_pos = hit.local_pos;
        } else {
            return panel;
        }

        const destination = target_window orelse return panel;
        const destination_manager = self.managerForWindow(destination);
        const drop = self.dockDropTargetForWindow(destination, target_local_pos) orelse {
            const source_manager = self.managerForWindow(source_window);
            source_manager.putPanel(panel) catch {
                var tmp = panel;
                tmp.deinit(self.allocator);
                return null;
            };
            if (source_manager.workspace.syncDockLayout() catch false) {
                source_manager.workspace.markDirty();
            }
            source_manager.focusPanel(panel.id);
            return null;
        };

        destination_manager.putPanel(panel) catch {
            const source_manager = self.managerForWindow(source_window);
            source_manager.putPanel(panel) catch {
                var tmp = panel;
                tmp.deinit(self.allocator);
                return null;
            };
            if (source_manager.workspace.syncDockLayout() catch false) {
                source_manager.workspace.markDirty();
            }
            source_manager.focusPanel(panel.id);
            return null;
        };
        destination_manager.workspace.markDirty();
        if (destination_manager.workspace.syncDockLayout() catch false) {
            destination_manager.workspace.markDirty();
        }

        const moved = if (drop.location == .center)
            destination_manager.workspace.dock_layout.movePanelToTabs(panel.id, drop.node_id, null) catch false
        else
            destination_manager.workspace.dock_layout.splitNodeWithPanel(drop.node_id, panel.id, drop.location) catch false;
        var moved_final = moved;
        if (!moved_final and drop.location != .center) {
            if (destination_manager.workspace.dock_layout.root) |root_id| {
                moved_final = destination_manager.workspace.dock_layout.splitNodeWithPanel(root_id, panel.id, drop.location) catch false;
            }
        }

        const panel_loc = destination_manager.workspace.dock_layout.findPanel(panel.id);
        const is_reachable = self.panelIsReachableInWindowLayout(destination, panel.id);
        const side_drop = drop.location != .center;
        const center_committed = if (!side_drop and panel_loc != null)
            panel_loc.?.node_id == drop.node_id
        else
            false;
        const side_committed = if (side_drop and panel_loc != null)
            moved_final and panel_loc.?.node_id != drop.node_id and is_reachable
        else
            false;
        const attach_committed = if (side_drop)
            side_committed
        else
            (moved_final or center_committed) and is_reachable;

        if (attach_committed and panel_loc != null) {
            destination_manager.focusPanel(panel.id);
            self.queueCloseIfNowEmptyDetachedWindow(source_window);
            return null;
        }

        const restored = destination_manager.takePanel(panel.id) orelse panel;
        const source_manager = self.managerForWindow(source_window);
        source_manager.putPanel(restored) catch {
            var tmp = restored;
            tmp.deinit(self.allocator);
            return null;
        };
        if (source_manager.workspace.syncDockLayout() catch false) {
            source_manager.workspace.markDirty();
        }
        source_manager.focusPanel(restored.id);
        return null;
    }

    fn queueCloseIfNowEmptyDetachedWindow(self: *App, window: *UiWindow) void {
        if (window.id == self.main_window_id) return;
        const manager = self.managerForWindow(window);
        if (manager.workspace.panels.items.len != 0) return;
        self.pending_close_window_id = window.id;
    }

    fn dockDropTargetForWindow(
        self: *App,
        window: *UiWindow,
        local_pos: [2]f32,
    ) ?dock_drop.DropTarget {
        const viewport = self.dockViewportForWindow(window) orelse return null;
        if (!viewport.contains(local_pos)) return null;
        const manager = self.managerForWindow(window);
        return dock_drop.pickDropTarget(&manager.workspace.dock_layout, viewport, local_pos);
    }

    fn dockViewportForWindow(self: *App, window: *UiWindow) ?UiRect {
        _ = self;
        const viewport = window.ui_state.last_dock_content_rect;
        const size = viewport.size();
        if (size[0] <= 1.0 or size[1] <= 1.0) return null;
        return viewport;
    }

    fn panelIsReachableInWindowLayout(
        self: *App,
        window: *UiWindow,
        panel_id: workspace.PanelId,
    ) bool {
        const manager = self.managerForWindow(window);
        const loc = manager.workspace.dock_layout.findPanel(panel_id) orelse return false;
        const viewport = self.dockViewportForWindow(window) orelse return false;
        const layout = manager.workspace.dock_layout.computeLayout(viewport);
        for (layout.slice()) |group| {
            if (group.node_id == loc.node_id) return true;
        }
        return false;
    }

    fn windowUnderGlobalMouse(self: *App, exclude_window_id: u32) ?WindowMouseHit {
        var mouse_global_x: f32 = 0.0;
        var mouse_global_y: f32 = 0.0;
        _ = c.SDL_GetGlobalMouseState(&mouse_global_x, &mouse_global_y);

        var i: usize = self.ui_windows.items.len;
        while (i > 0) {
            i -= 1;
            const window = self.ui_windows.items[i];
            if (window.id == exclude_window_id) continue;

            var window_x: c_int = 0;
            var window_y: c_int = 0;
            _ = c.SDL_GetWindowPosition(window.window, &window_x, &window_y);
            var border_top: c_int = 0;
            var border_left: c_int = 0;
            var border_bottom: c_int = 0;
            var border_right: c_int = 0;
            if (!c.SDL_GetWindowBordersSize(window.window, &border_top, &border_left, &border_bottom, &border_right)) {
                border_top = 0;
                border_left = 0;
                border_bottom = 0;
                border_right = 0;
            }
            var window_width: c_int = 0;
            var window_height: c_int = 0;
            _ = c.SDL_GetWindowSize(window.window, &window_width, &window_height);
            if (window_width <= 0 or window_height <= 0) continue;

            const content_x: c_int = window_x + border_left;
            const content_y: c_int = window_y + border_top;
            const min_x: f32 = @floatFromInt(content_x);
            const min_y: f32 = @floatFromInt(content_y);
            const max_x = min_x + @as(f32, @floatFromInt(window_width));
            const max_y = min_y + @as(f32, @floatFromInt(window_height));
            if (mouse_global_x < min_x or mouse_global_x >= max_x or mouse_global_y < min_y or mouse_global_y >= max_y) continue;

            return .{
                .win = window,
                .local_pos = .{ mouse_global_x - min_x, mouse_global_y - min_y },
            };
        }
        return null;
    }

    fn focusedWindowMouseHit(self: *App, exclude_window_id: u32) ?WindowMouseHit {
        const mouse_focus = c.SDL_GetMouseFocus();
        const hover_window_id: u32 = if (mouse_focus) |window| c.SDL_GetWindowID(window) else 0;
        if (hover_window_id == 0 or hover_window_id == exclude_window_id) return null;

        var target_window: ?*UiWindow = null;
        for (self.ui_windows.items) |window| {
            if (window.id == hover_window_id) {
                target_window = window;
                break;
            }
        }
        if (target_window == null) return null;

        var local_mouse_x: f32 = 0.0;
        var local_mouse_y: f32 = 0.0;
        _ = c.SDL_GetMouseState(&local_mouse_x, &local_mouse_y);
        return .{
            .win = target_window.?,
            .local_pos = .{ local_mouse_x, local_mouse_y },
        };
    }

    fn rebuildDockLayoutFromPanels(self: *App, manager: *panel_manager.PanelManager) bool {
        const panel_count = manager.workspace.panels.items.len;
        if (panel_count == 0 or panel_count > 4096) return false;

        const graph = &manager.workspace.dock_layout;
        graph.clear();
        const fresh_graph = graph;

        var chat_ids = std.ArrayList(workspace.PanelId).empty;
        defer chat_ids.deinit(fresh_graph.allocator);
        var other_ids = std.ArrayList(workspace.PanelId).empty;
        defer other_ids.deinit(fresh_graph.allocator);
        var all_ids = std.ArrayList(workspace.PanelId).empty;
        defer all_ids.deinit(fresh_graph.allocator);

        chat_ids.ensureTotalCapacity(fresh_graph.allocator, panel_count) catch return false;
        other_ids.ensureTotalCapacity(fresh_graph.allocator, panel_count) catch return false;
        all_ids.ensureTotalCapacity(fresh_graph.allocator, panel_count) catch return false;

        var chat_count: usize = 0;
        var other_count: usize = 0;
        for (manager.workspace.panels.items) |panel| {
            if (panel.kind == .Chat) {
                chat_count += 1;
                chat_ids.append(fresh_graph.allocator, panel.id) catch return false;
            } else {
                other_count += 1;
                other_ids.append(fresh_graph.allocator, panel.id) catch return false;
            }
            all_ids.append(fresh_graph.allocator, panel.id) catch return false;
        }
        if (self.shouldLogDebug(120)) {
            std.log.info("rebuildDockLayoutFromPanels: panel_count={} chat={} other={}", .{ panel_count, chat_count, other_count });
        }

        if (chat_ids.items.len > 0 and other_ids.items.len > 0) {
            const left = fresh_graph.addTabsNode(chat_ids.items, 0) catch return false;
            const right = fresh_graph.addTabsNode(other_ids.items, 0) catch return false;
            const root = fresh_graph.addSplitNode(.vertical, manager.workspace.custom_layout.left_ratio, left, right) catch return false;
            fresh_graph.root = root;
            manager.workspace.markDirty();
            return true;
        }

        if (all_ids.items.len == 0) return false;
        const root = fresh_graph.addTabsNode(all_ids.items, 0) catch return false;
        fresh_graph.root = root;
        manager.workspace.markDirty();
        return true;
    }

    fn recoverDockLayoutFromPanels(self: *App, manager: *panel_manager.PanelManager) bool {
        const panel_count = manager.workspace.panels.items.len;
        if (self.shouldLogDebug(120)) {
            std.log.info("recoverDockLayoutFromPanels: panel_count={}", .{panel_count});
        }
        if (panel_count == 0 or panel_count > 4096) return false;

        var graph = &manager.workspace.dock_layout;
        graph.clear();

        var panel_ids = std.ArrayList(workspace.PanelId).empty;
        defer panel_ids.deinit(graph.allocator);
        panel_ids.ensureTotalCapacity(graph.allocator, panel_count) catch return false;

        for (manager.workspace.panels.items) |panel| {
            panel_ids.append(graph.allocator, panel.id) catch return false;
        }

        const root = graph.addTabsNode(panel_ids.items, 0) catch return false;
        graph.root = root;
        manager.workspace.markDirty();
        if (self.shouldLogDebug(120)) {
            std.log.info("recoverDockLayoutFromPanels: built root={}", .{@as(i64, @intCast(root))});
        }
        return true;
    }

    fn collectDockLayoutSafe(
        self: *App,
        manager: *panel_manager.PanelManager,
        dock_area: UiRect,
        out: *dock_graph.LayoutResult,
    ) bool {
        if (!self.isWorkspaceStateReasonable(manager)) {
            std.log.err("collectDockLayoutSafe: manager unhealthy", .{});
            return false;
        }

        out.len = 0;
        if (manager.workspace.panels.items.len > 4096 or manager.workspace.dock_layout.nodes.items.len > 16384) {
            std.log.err(
                "collectDockLayoutSafe: invalid workspace sizes (panels={} nodes={})",
                .{
                    manager.workspace.panels.items.len,
                    manager.workspace.dock_layout.nodes.items.len,
                },
            );
            return false;
        }
        if (!self.isDockLayoutGraphHeaderSane(&manager.workspace.dock_layout)) {
            std.log.err("collectDockLayoutSafe: dock graph header failed sanity check", .{});
            return false;
        }

        if (manager.workspace.panels.items.len == 0) {
            std.log.err("collectDockLayoutSafe: no panels available", .{});
            return false;
        }

        if (self.collectDockLayout(manager, dock_area, out)) {
            return true;
        }

        if (self.rebuildDockLayoutFromPanels(manager)) {
            _ = manager.workspace.syncDockLayout() catch {};
            if (self.collectDockLayout(manager, dock_area, out)) {
                return true;
            }
            std.log.err("collectDockLayoutSafe: rebuilt layout still invalid", .{});
        }

        if (self.recoverDockLayoutFromPanels(manager)) {
            if (self.collectDockLayout(manager, dock_area, out)) {
                return true;
            }
            std.log.err("collectDockLayoutSafe: recovered layout still invalid", .{});
        }

        if (self.buildSingleTabPanelLayout(manager, dock_area, out)) {
            return true;
        }
        std.log.err("collectDockLayoutSafe: single-tab fallback failed", .{});
        return false;
    }

    fn isDockLayoutGraphHeaderSane(self: *App, graph: *const dock_graph.Graph) bool {
        _ = self;
        if (graph.nodes.capacity > MAX_REASONABLE_DOCK_NODE_COUNT * 2) return false;
        if (graph.nodes.items.len > graph.nodes.capacity) return false;
        if (graph.nodes.items.len > MAX_REASONABLE_DOCK_NODE_COUNT) return false;
        if (graph.nodes.items.len == 0) return true;
        const ptr = graph.nodes.items.ptr;
        if (@intFromPtr(ptr) == 0) return false;
        if (!std.mem.isAligned(@intFromPtr(ptr), @alignOf(?dock_graph.Node))) return false;
        return true;
    }

    fn ensureWindowManagerHealthy(self: *App, manager: *panel_manager.PanelManager) bool {
        if (@intFromPtr(manager) == 0) {
            std.log.err("ensureWindowManagerHealthy: null manager pointer", .{});
            return false;
        }
        self.bindNextPanelId(manager);
        if (self.isWorkspaceRecoverySuspended(manager)) {
            if (self.shouldLogDebug(240) or self.shouldLogStartup()) {
                std.log.warn(
                    "ensureWindowManagerHealthy: recovery suspended (manager=0x{x})",
                    .{@intFromPtr(manager)},
                );
            }
            return false;
        }

        if (self.workspace_recovery_failures >= WORKSPACE_RECOVERY_ATTEMPTS_BEFORE_SUSPEND) {
            if (self.shouldLogDebug(120) or self.shouldLogStartup()) {
                std.log.warn(
                    "ensureWindowManagerHealthy: recovery attempts exceeded, forcing safe reset",
                    .{},
                );
            }
            self.workspace_recovery_failures = 0;
            self.invalidateWorkspaceSnapshot();
            if (!self.resetManagerToDefaultSafe(manager)) {
                self.suspendWorkspaceRecovery(manager);
                self.resetWorkspaceToSafeEmpty(manager);
                return false;
            }
            self.clearWorkspaceRecoveryCooldown();
            self.clearWorkspaceRecoverySuspend();
            return self.isWorkspaceStateReasonable(manager) and manager.workspace.panels.items.len > 0;
        }

        const is_recovery_allowed = self.canRecoverManagerWorkspace(manager);
        if (!is_recovery_allowed) {
            if (self.shouldLogDebug(240) or self.shouldLogStartup()) {
                std.log.warn(
                    "ensureWindowManagerHealthy: skipping recovery due cooldown (manager=0x{x})",
                    .{@intFromPtr(manager)},
                );
            }
            return false;
        }

        if (!self.isWorkspaceStateReasonable(manager)) {
            self.logWorkspaceState(manager, "invalid-before-reset", self.debug_frame_counter);
            if (self.shouldLogDebug(120) or self.shouldLogStartup()) {
                std.log.err(
                    "ensureWindowManagerHealthy: invalid workspace state, resetting (panels={d} nodes={d} root={d})",
                    .{
                        manager.workspace.panels.items.len,
                        manager.workspace.dock_layout.nodes.items.len,
                        if (manager.workspace.dock_layout.root) |root| @as(i64, @intCast(root)) else -1,
                    },
                );
            }

            if (!self.workspace_snapshot_stale and self.workspace_snapshot != null and !self.workspace_snapshot_restore_attempted) {
                if (self.shouldLogDebug(120) or self.shouldLogStartup()) {
                    std.log.info("ensureWindowManagerHealthy: trying snapshot restore during recovery", .{});
                }
                if (self.debug_frame_counter >= self.workspace_snapshot_restore_cooldown_until and
                    self.restoreWorkspaceFromSnapshot(manager))
                {
                    self.workspace_snapshot_stale = false;
                    self.workspace_snapshot_restore_attempted = false;
                    self.workspace_recovery_failures = 0;
                    self.clearWorkspaceRecoveryCooldown();
                    self.clearWorkspaceRecoverySuspend();
                    self.workspace_snapshot_restore_cooldown_until = self.debug_frame_counter + WORKSPACE_RECOVERY_COOLDOWN_FRAMES;
                    return true;
                }
                self.invalidateWorkspaceSnapshot();
                self.workspace_snapshot_stale = true;
                self.workspace_snapshot_restore_attempted = true;
                self.workspace_snapshot_restore_cooldown_until = self.debug_frame_counter + WORKSPACE_RECOVERY_COOLDOWN_FRAMES;
                if (self.workspace_recovery_failures < 250) self.workspace_recovery_failures +%= 1;
                if (self.shouldLogDebug(120) or self.shouldLogStartup()) {
                    std.log.warn("ensureWindowManagerHealthy: snapshot restore failed; disabling repeated restore", .{});
                }
            } else if (self.workspace_snapshot_stale) {
                if (self.shouldLogDebug(120) or self.shouldLogStartup()) {
                    std.log.warn(
                        "ensureWindowManagerHealthy: skipping restore because workspace snapshot is stale",
                        .{},
                    );
                }
                if (self.workspace_recovery_failures < 250) self.workspace_recovery_failures +%= 1;
            } else if (self.debug_frame_counter < self.workspace_snapshot_restore_cooldown_until) {
                if (self.shouldLogDebug(120) or self.shouldLogStartup()) {
                    std.log.warn(
                        "ensureWindowManagerHealthy: snapshot restore cooldown active (frame {} < {})",
                        .{ self.debug_frame_counter, self.workspace_snapshot_restore_cooldown_until },
                    );
                }
                if (self.workspace_recovery_failures < 250) self.workspace_recovery_failures +%= 1;
            }

            if (!self.resetManagerToDefaultSafe(manager)) {
                self.logWorkspaceState(manager, "invalid-after-reset", self.debug_frame_counter);
                if (self.shouldLogDebug(120) or self.shouldLogStartup()) {
                    std.log.err(
                        "ensureWindowManagerHealthy: reset did not produce a valid default workspace",
                        .{},
                    );
                }
                self.workspace_recovery_failures +%= 1;
                self.suspendWorkspaceRecovery(manager);
                return false;
            }

            if (!self.isWorkspaceStateReasonable(manager) or manager.workspace.panels.items.len == 0) {
                self.logWorkspaceState(manager, "invalid-after-reset-verify", self.debug_frame_counter);
                self.workspace_recovery_failures +%= 1;
                self.suspendWorkspaceRecovery(manager);
                self.resetWorkspaceToSafeEmpty(manager);
                return false;
            }

            self.captureWorkspaceSnapshot(manager);
            self.workspace_recovery_failures = 0;
            self.clearWorkspaceRecoveryCooldown();
            self.clearWorkspaceRecoverySuspend();
            return true;
        }

        if (manager.workspace.panels.items.len == 0) {
            if (self.shouldLogDebug(120) or self.shouldLogStartup()) {
                std.log.warn("ensureWindowManagerHealthy: no panels; restoring default workspace", .{});
            }
            if (!self.resetManagerToDefaultSafe(manager)) {
                self.suspendWorkspaceRecovery(manager);
                self.resetWorkspaceToSafeEmpty(manager);
                return false;
            }
            if (!self.isWorkspaceStateReasonable(manager) or manager.workspace.panels.items.len == 0) {
                self.suspendWorkspaceRecovery(manager);
                self.resetWorkspaceToSafeEmpty(manager);
                return false;
            }
            self.clearWorkspaceRecoveryCooldown();
            self.clearWorkspaceRecoverySuspend();
            return manager.workspace.panels.items.len > 0;
        }

        if (manager.workspace.dock_layout.nodes.items.len == 0 and manager.workspace.panels.items.len > 0) {
            if (self.shouldLogDebug(120) or self.shouldLogStartup()) {
                std.log.info("ensureWindowManagerHealthy: no dock nodes; syncing layout", .{});
            }
            const synced = manager.workspace.syncDockLayout() catch {
                if (self.shouldLogDebug(120) or self.shouldLogStartup()) {
                    std.log.warn("ensureWindowManagerHealthy: sync failed; restoring defaults", .{});
                }
                if (!self.resetManagerToDefaultSafe(manager)) {
                    self.suspendWorkspaceRecovery(manager);
                    self.resetWorkspaceToSafeEmpty(manager);
                    return false;
                }
                if (!self.isWorkspaceStateReasonable(manager)) {
                    self.suspendWorkspaceRecovery(manager);
                    self.resetWorkspaceToSafeEmpty(manager);
                }
                return false;
            };
            if (!synced) {
                if (!self.resetManagerToDefaultSafe(manager)) {
                    self.suspendWorkspaceRecovery(manager);
                    self.resetWorkspaceToSafeEmpty(manager);
                    return false;
                }
                if (!self.isWorkspaceStateReasonable(manager)) {
                    self.suspendWorkspaceRecovery(manager);
                    self.resetWorkspaceToSafeEmpty(manager);
                }
                return false;
            }
        } else if (self.isDockLayoutCorrupt(manager)) {
            if (self.shouldLogDebug(120) or self.shouldLogStartup()) {
                std.log.warn("ensureWindowManagerHealthy: dock layout corrupt; repairing", .{});
            }
            _ = self.repairDockLayout(manager);
            if (self.isDockLayoutCorrupt(manager)) {
                if (self.shouldLogDebug(120) or self.shouldLogStartup()) {
                    std.log.warn("ensureWindowManagerHealthy: repair ineffective; restoring defaults", .{});
                }
                if (!self.resetManagerToDefaultSafe(manager)) {
                    self.suspendWorkspaceRecovery(manager);
                    self.resetWorkspaceToSafeEmpty(manager);
                    return false;
                }
                if (!self.isWorkspaceStateReasonable(manager)) {
                    self.suspendWorkspaceRecovery(manager);
                    self.resetWorkspaceToSafeEmpty(manager);
                }
            }
        }

        if (self.isWorkspaceStateReasonable(manager)) {
            self.clearWorkspaceRecoveryCooldown();
            self.clearWorkspaceRecoverySuspend();
            if (self.workspace_snapshot_stale and self.shouldLogDebug(600)) {
                std.log.warn("ensureWindowManagerHealthy: skipping snapshot capture while snapshot is stale", .{});
            }
        } else {
            self.suspendWorkspaceRecovery(manager);
        }

        if (self.isWorkspaceStateReasonable(manager) and self.workspace_snapshot == null) {
            self.captureWorkspaceSnapshot(manager);
            self.workspace_snapshot_restore_attempted = false;
        }

        return self.isWorkspaceStateReasonable(manager) and manager.workspace.panels.items.len > 0;
    }

    fn canRecoverManagerWorkspace(self: *App, manager: *panel_manager.PanelManager) bool {
        if (self.workspace_recovery_blocked_until == 0) return true;
        if (self.workspace_recovery_blocked_for_manager != @intFromPtr(manager)) return true;
        if (self.debug_frame_counter < self.workspace_recovery_blocked_until) return false;
        self.workspace_recovery_blocked_until = 0;
        self.workspace_recovery_blocked_for_manager = 0;
        return true;
    }

    fn blockWorkspaceRecovery(self: *App, manager: *panel_manager.PanelManager) void {
        self.workspace_recovery_blocked_for_manager = @intFromPtr(manager);
        self.workspace_recovery_blocked_until = self.debug_frame_counter + WORKSPACE_RECOVERY_COOLDOWN_FRAMES;
    }

    fn isWorkspaceRecoverySuspended(self: *App, manager: *panel_manager.PanelManager) bool {
        if (self.workspace_recovery_suspended_for_manager != @intFromPtr(manager)) return false;
        if (self.workspace_recovery_suspended_until == 0) return true;
        if (self.debug_frame_counter < self.workspace_recovery_suspended_until) return true;
        self.workspace_recovery_suspended_for_manager = 0;
        self.workspace_recovery_suspended_until = 0;
        return false;
    }

    fn suspendWorkspaceRecovery(self: *App, manager: *panel_manager.PanelManager) void {
        if (self.workspace_recovery_suspended_for_manager == 0) {
            self.workspace_recovery_suspended_for_manager = @intFromPtr(manager);
        }
        self.workspace_recovery_suspended_until = self.debug_frame_counter + WORKSPACE_RECOVERY_SUSPEND_FRAMES;
        self.blockWorkspaceRecovery(manager);
    }

    fn clearWorkspaceRecoverySuspend(self: *App) void {
        if (self.workspace_recovery_suspended_until != 0) {
            self.workspace_recovery_suspended_until = 0;
            self.workspace_recovery_suspended_for_manager = 0;
        }
    }

    fn resetWorkspaceToSafeEmpty(self: *App, manager: *panel_manager.PanelManager) void {
        self.tryDeinitWorkspaceForReset(manager);
        manager.workspace = workspace.Workspace.initEmpty(self.allocator);
        self.recomputeManagerNextId(manager);
    }

    fn clearWorkspaceRecoveryCooldown(self: *App) void {
        self.workspace_recovery_blocked_until = 0;
        self.workspace_recovery_blocked_for_manager = 0;
    }

    fn captureWorkspaceSnapshot(self: *App, manager: *panel_manager.PanelManager) void {
        if (!self.isWorkspaceStateReasonable(manager)) return;
        const snapshot = manager.workspace.toSnapshot(self.allocator) catch {
            if (self.shouldLogDebug(120) or self.shouldLogStartup()) {
                std.log.warn("captureWorkspaceSnapshot: unable to snapshot workspace", .{});
            }
            return;
        };
        if (self.workspace_snapshot) |*previous| {
            previous.deinit(self.allocator);
        }
        self.workspace_snapshot = snapshot;
        self.workspace_snapshot_stale = false;
        self.workspace_snapshot_restore_attempted = false;
    }

    fn invalidateWorkspaceSnapshot(self: *App) void {
        if (self.workspace_snapshot) |*snapshot| {
            snapshot.deinit(self.allocator);
            self.workspace_snapshot = null;
        }
        self.workspace_snapshot_stale = true;
        self.workspace_snapshot_restore_attempted = true;
    }

    fn bindNextPanelId(self: *App, manager: *panel_manager.PanelManager) void {
        if (@intFromPtr(manager.next_panel_id) != @intFromPtr(&self.next_panel_id)) {
            if (self.shouldLogDebug(1200)) {
                std.log.debug(
                    "bindNextPanelId: repairing manager.next_panel_id (old=0x{x}, expected=0x{x})",
                    .{ @intFromPtr(manager.next_panel_id), @intFromPtr(&self.next_panel_id) },
                );
            }
            manager.next_panel_id = &self.next_panel_id;
        }
    }

    fn restoreWorkspaceFromSnapshot(self: *App, manager: *panel_manager.PanelManager) bool {
        const snapshot = self.workspace_snapshot orelse return false;
        if (!self.isWorkspaceSnapshotReasonable(snapshot)) {
            if (self.shouldLogDebug(120) or self.shouldLogStartup()) {
                std.log.warn("restoreWorkspaceFromSnapshot: snapshot failed sanity checks", .{});
            }
            self.invalidateWorkspaceSnapshot();
            return false;
        }
        var restored = workspace.Workspace.fromSnapshot(self.allocator, snapshot) catch |err| {
            if (self.shouldLogDebug(120) or self.shouldLogStartup()) {
                std.log.warn(
                    "restoreWorkspaceFromSnapshot: failed to restore from snapshot ({s})",
                    .{@errorName(err)},
                );
            }
            self.invalidateWorkspaceSnapshot();
            return false;
        };
        if (!self.restoreLooksReasonable(&restored)) {
            if (self.shouldLogDebug(120) or self.shouldLogStartup()) {
                std.log.warn("restoreWorkspaceFromSnapshot: restored workspace failed sanity checks", .{});
            }
            restored.deinit(self.allocator);
            self.invalidateWorkspaceSnapshot();
            return false;
        }

        self.tryDeinitWorkspaceForReset(manager);
        manager.workspace = restored;

        if (!self.isWorkspaceStateReasonable(manager)) {
            manager.workspace.deinit(self.allocator);
            manager.workspace = workspace.Workspace.initEmpty(self.allocator);
            self.invalidateWorkspaceSnapshot();
            return false;
        }
        self.recomputeManagerNextId(manager);
        self.captureWorkspaceSnapshot(manager);
        return true;
    }

    fn restoreLooksReasonable(self: *App, candidate: *const workspace.Workspace) bool {
        _ = self;
        if (candidate.panels.items.len > MAX_REASONABLE_PANEL_COUNT) return false;
        if (candidate.dock_layout.nodes.items.len > MAX_REASONABLE_DOCK_NODE_COUNT) return false;
        if (candidate.panels.items.len > 0 and candidate.dock_layout.nodes.items.len == 0) return false;
        if (candidate.dock_layout.nodes.capacity > MAX_REASONABLE_DOCK_NODE_COUNT * 2) return false;
        if (candidate.panels.capacity > MAX_REASONABLE_PANEL_COUNT * 2) return false;
        if (candidate.dock_layout.root) |root| {
            if (root >= candidate.dock_layout.nodes.items.len) return false;
            if (candidate.dock_layout.getNode(root) == null) return false;
        } else if (candidate.dock_layout.nodes.items.len > 0) {
            return false;
        }
        return true;
    }

    fn isWorkspaceSnapshotReasonable(self: *App, snapshot: workspace.WorkspaceSnapshot) bool {
        if (snapshot.next_panel_id == 0) return false;
        if (snapshot.next_panel_id == 1) return false;
        if (snapshot.next_panel_id > MAX_REASONABLE_NEXT_PANEL_ID) return false;

        const panel_count: usize = if (snapshot.panels) |panels| panels.len else 0;
        if (panel_count > MAX_REASONABLE_PANEL_COUNT) return false;

        if (snapshot.layout_v2) |layout| {
            const layout_nodes = if (layout.nodes) |nodes| nodes.len else 0;
            if (layout_nodes > MAX_REASONABLE_DOCK_NODE_COUNT) return false;
        }

        if (snapshot.collapsed_docks) |collapsed| {
            if (collapsed.len > MAX_REASONABLE_DOCK_NODE_COUNT) return false;
        }

        if (snapshot.detached_windows) |detached| {
            if (detached.len > 32) return false;
        }

        if (snapshot.panels) |panels| {
            var seen_panel_ids = std.AutoHashMap(workspace.PanelId, void).init(self.allocator);
            defer seen_panel_ids.deinit();
            for (panels) |panel| {
                if (panel.id == 0) return false;
                if (panel.id >= snapshot.next_panel_id) return false;
                if (seen_panel_ids.contains(panel.id)) return false;
                seen_panel_ids.put(panel.id, {}) catch return false;
            }
        }

        return true;
    }

    fn resetManagerWorkspaceToDefault(self: *App, manager: *panel_manager.PanelManager) bool {
        self.tryDeinitWorkspaceForReset(manager);
        const fresh = workspace.Workspace.initDefault(self.allocator) catch {
            std.log.err("ensureWindowManagerHealthy: fallback workspace build failed", .{});
            manager.workspace = workspace.Workspace.initEmpty(self.allocator);
            self.recomputeManagerNextId(manager);
            return false;
        };
        if (!self.restoreLooksReasonable(&fresh)) {
            std.log.err("ensureWindowManagerHealthy: fallback workspace failed post-creation sanity checks", .{});
            var disposable = fresh;
            disposable.deinit(self.allocator);
            manager.workspace = workspace.Workspace.initEmpty(self.allocator);
            self.recomputeManagerNextId(manager);
            return false;
        }
        manager.workspace = fresh;
        self.recomputeManagerNextId(manager);
        self.captureWorkspaceSnapshot(manager);
        return true;
    }

    fn resetMainManagerToDefault(self: *App) bool {
        var fresh = workspace.Workspace.initDefault(self.allocator) catch {
            std.log.err("ensureWindowManagerHealthy: main fallback workspace build failed", .{});
            return false;
        };
        if (!self.restoreLooksReasonable(&fresh)) {
            std.log.err("ensureWindowManagerHealthy: main fallback workspace failed post-creation sanity checks", .{});
            fresh.deinit(self.allocator);
            return false;
        }

        self.tryDeinitWorkspaceForReset(&self.manager);
        self.manager = panel_manager.PanelManager.init(self.allocator, fresh, &self.next_panel_id);
        self.bindNextPanelId(&self.manager);
        self.bindMainWindowManager();
        self.recomputeManagerNextId(&self.manager);
        self.captureWorkspaceSnapshot(&self.manager);
        return true;
    }

    fn resetManagerToDefaultSafe(self: *App, manager: *panel_manager.PanelManager) bool {
        if (manager == &self.manager) return self.resetMainManagerToDefault();
        return self.resetManagerWorkspaceToDefault(manager);
    }

    fn isWorkspaceStateReasonable(self: *App, manager: *panel_manager.PanelManager) bool {
        if (!self.isWorkspaceHeaderSane(manager)) return false;
        if (!self.isDockLayoutGraphHeaderSane(&manager.workspace.dock_layout)) return false;

        const panel_count = manager.workspace.panels.items.len;
        const node_count = manager.workspace.dock_layout.nodes.items.len;

        if (panel_count > MAX_REASONABLE_PANEL_COUNT or node_count > MAX_REASONABLE_DOCK_NODE_COUNT) return false;

        if (manager.workspace.dock_layout.root == null)
            return node_count == 0;

        if (node_count == 0) return false;
        const root = manager.workspace.dock_layout.root.?;
        if (root >= node_count) return false;
        return manager.workspace.dock_layout.getNode(root) != null;
    }

    fn resetManagerWorkspace(self: *App, manager: *panel_manager.PanelManager) void {
        self.bindNextPanelId(manager);
        _ = self.resetManagerWorkspaceToDefault(manager);
    }

    fn recomputeManagerNextId(self: *App, manager: *panel_manager.PanelManager) void {
        self.bindNextPanelId(manager);
        if (!self.isWorkspaceHeaderSane(manager)) {
            self.next_panel_id = 1;
            return;
        }
        var max_id: workspace.PanelId = 0;
        for (manager.workspace.panels.items) |panel| {
            if (panel.id > max_id) max_id = panel.id;
        }
        const candidate = max_id + 1;
        if (candidate > self.next_panel_id) {
            self.next_panel_id = candidate;
        }
    }

    fn appendPanelToManager(self: *App, manager: *panel_manager.PanelManager, panel: workspace.Panel) !void {
        self.bindNextPanelId(manager);
        try manager.workspace.panels.append(self.allocator, panel);
        manager.workspace.markDirty();
        self.recomputeManagerNextId(manager);
    }

    fn tryDeinitWorkspaceForReset(self: *App, manager: *panel_manager.PanelManager) void {
        if (!self.isWorkspaceHeaderSane(manager)) {
            self.logWorkspaceState(manager, "header-corrupt-bypass-deinit", self.debug_frame_counter);
            self.releaseCorruptWorkspaceStorage(manager);
            manager.workspace = workspace.Workspace.initEmpty(self.allocator);
            return;
        }
        if (self.isWorkspaceStateReasonable(manager)) {
            manager.workspace.deinit(self.allocator);
            manager.workspace = workspace.Workspace.initEmpty(self.allocator);
            return;
        }

        // On partially-corrupted state, avoid deep deinit paths that assume valid node
        // internals. Use bounded storage release only and replace with fresh structures.
        const panel_count = manager.workspace.panels.items.len;
        const node_count = manager.workspace.dock_layout.nodes.items.len;
        std.log.warn(
            "tryDeinitWorkspaceForReset: workspace header suspicious (panels=len={} cap={} nodes=len={} cap={})",
            .{
                panel_count,
                manager.workspace.panels.capacity,
                node_count,
                manager.workspace.dock_layout.nodes.capacity,
            },
        );
        self.releaseCorruptWorkspaceStorage(manager);
        manager.workspace = workspace.Workspace.initEmpty(self.allocator);
    }

    fn releaseCorruptWorkspaceStorage(self: *App, manager: *panel_manager.PanelManager) void {
        const panel_len = manager.workspace.panels.items.len;
        const panel_cap = manager.workspace.panels.capacity;
        const panel_ptr = manager.workspace.panels.items.ptr;
        const panel_reasonable = panel_len <= panel_cap and
            panel_cap > 0 and
            panel_cap <= MAX_REASONABLE_PANEL_COUNT * 2 and
            @intFromPtr(panel_ptr) != 0 and
            std.mem.isAligned(@intFromPtr(panel_ptr), @alignOf(workspace.Panel));
        if (panel_reasonable) {
            if (panel_len <= MAX_REASONABLE_PANEL_COUNT) {
                var idx: usize = 0;
                while (idx < panel_len) : (idx += 1) {
                    manager.workspace.panels.items[idx].deinit(self.allocator);
                }
            } else if (self.shouldLogDebug(120) or self.shouldLogStartup()) {
                std.log.warn(
                    "releaseCorruptWorkspaceStorage: skipping panel deinit due suspicious panel count ({})",
                    .{panel_len},
                );
            }
            self.allocator.free(panel_ptr[0..panel_cap]);
        } else if (self.shouldLogDebug(120) or self.shouldLogStartup()) {
            std.log.warn(
                "releaseCorruptWorkspaceStorage: skipped panel storage release (len={} cap={} ptr=0x{x})",
                .{
                    panel_len,
                    panel_cap,
                    @intFromPtr(panel_ptr),
                },
            );
        }
        manager.workspace.panels = std.ArrayList(workspace.Panel).empty;
        const node_cap = manager.workspace.dock_layout.nodes.capacity;
        const node_len = manager.workspace.dock_layout.nodes.items.len;
        const node_ptr = manager.workspace.dock_layout.nodes.items.ptr;
        const node_reasonable = node_len <= node_cap and
            node_cap > 0 and
            @intFromPtr(node_ptr) != 0 and
            node_cap <= MAX_REASONABLE_DOCK_NODE_COUNT * 2 and
            std.mem.isAligned(@intFromPtr(node_ptr), @alignOf(?dock_graph.Node));
        if (node_reasonable) {
            if (node_len <= MAX_REASONABLE_DOCK_NODE_COUNT) {
                var node_idx: usize = 0;
                while (node_idx < node_len) : (node_idx += 1) {
                    if (manager.workspace.dock_layout.nodes.items[node_idx]) |*node| {
                        node.deinit(self.allocator);
                    }
                }
            }
            self.allocator.free(node_ptr[0..node_cap]);
            if (self.shouldLogDebug(120) or self.shouldLogStartup()) {
                std.log.warn(
                    "releaseCorruptWorkspaceStorage: released dock node storage (len={} cap={} ptr=0x{x})",
                    .{
                        node_len,
                        node_cap,
                        @intFromPtr(node_ptr),
                    },
                );
            }
        } else if (self.shouldLogDebug(120) or self.shouldLogStartup()) {
            std.log.warn(
                "releaseCorruptWorkspaceStorage: skipped dock node storage release (len={} cap={} ptr=0x{x})",
                .{
                    node_len,
                    node_cap,
                    @intFromPtr(node_ptr),
                },
            );
        }
        manager.workspace.dock_layout.nodes = std.ArrayList(?dock_graph.Node).empty;
        manager.workspace.dock_layout.root = null;
    }

    fn isWorkspaceHeaderSane(_: *App, manager: *panel_manager.PanelManager) bool {
        const ws = &manager.workspace;

        if (ws.panels.items.len > MAX_REASONABLE_PANEL_COUNT) return false;
        if (ws.panels.capacity > MAX_REASONABLE_PANEL_COUNT * 2) return false;
        if (ws.panels.items.len > ws.panels.capacity) return false;
        if (ws.panels.items.len > 0 and @intFromPtr(ws.panels.items.ptr) == 0) return false;
        if (ws.panels.items.len > 0 and !std.mem.isAligned(@intFromPtr(ws.panels.items.ptr), @alignOf(workspace.Panel))) return false;
        if (ws.panels.capacity == 0 and ws.panels.items.len > 0) return false;

        if (ws.dock_layout.nodes.items.len > MAX_REASONABLE_DOCK_NODE_COUNT) return false;
        if (ws.dock_layout.nodes.capacity > MAX_REASONABLE_DOCK_NODE_COUNT * 2) return false;
        if (ws.dock_layout.nodes.items.len > ws.dock_layout.nodes.capacity) return false;
        if (ws.dock_layout.nodes.items.len > 0 and @intFromPtr(ws.dock_layout.nodes.items.ptr) == 0) return false;
        if (ws.dock_layout.nodes.items.len > 0 and !std.mem.isAligned(@intFromPtr(ws.dock_layout.nodes.items.ptr), @alignOf(?dock_graph.Node))) return false;

        return true;
    }

    fn logWorkspaceState(self: *App, manager: *panel_manager.PanelManager, label: []const u8, frame_ctx: u64) void {
        _ = self;
        const dock_root = if (manager.workspace.dock_layout.root) |root|
            @as(i64, @intCast(root))
        else
            -1;
        std.log.err(
            "workspace-state[{s}] frame={d}: panels(len={d} cap={d} ptr=0x{x}) nodes(len={d} cap={d} ptr=0x{x}) root={d}",
            .{
                label,
                frame_ctx,
                manager.workspace.panels.items.len,
                manager.workspace.panels.capacity,
                @intFromPtr(manager.workspace.panels.items.ptr),
                manager.workspace.dock_layout.nodes.items.len,
                manager.workspace.dock_layout.nodes.capacity,
                @intFromPtr(manager.workspace.dock_layout.nodes.items.ptr),
                dock_root,
            },
        );
    }

    fn buildSingleTabPanelLayout(
        self: *App,
        manager: *panel_manager.PanelManager,
        dock_area: UiRect,
        out: *dock_graph.LayoutResult,
    ) bool {
        const panel_count = manager.workspace.panels.items.len;
        if (panel_count == 0 or panel_count > 4096) return false;

        out.len = 0;
        const graph = &manager.workspace.dock_layout;
        graph.clear();

        var panel_ids = std.ArrayList(workspace.PanelId).empty;
        defer panel_ids.deinit(graph.allocator);
        panel_ids.ensureTotalCapacity(graph.allocator, panel_count) catch return false;
        for (manager.workspace.panels.items) |panel| {
            panel_ids.append(graph.allocator, panel.id) catch return false;
        }

        const root = graph.addTabsNode(panel_ids.items, 0) catch return false;
        graph.root = root;
        manager.workspace.markDirty();
        if (self.shouldLogDebug(120)) {
            std.log.info("buildSingleTabPanelLayout: built root={} panels={}", .{ @as(i64, @intCast(root)), panel_count });
        }

        out.append(.{ .node_id = root, .rect = dock_area });
        return true;
    }

    fn collectDockInteractionGeometry(
        self: *App,
        manager: *panel_manager.PanelManager,
        dock_area: UiRect,
        out_tabs: *DockTabHitList,
        out_drop_targets: *DockDropTargetList,
    ) void {
        out_tabs.len = 0;
        out_drop_targets.clear();

        var layout: dock_graph.LayoutResult = .{};
        if (!self.collectDockLayoutSafe(manager, dock_area, &layout)) {
            if (self.shouldLogDebug(120)) {
                std.log.warn("collectDockInteractionGeometry: no valid dock layout", .{});
            }
            return;
        }

        const tab_metrics = self.dockTabMetrics();
        if (tab_metrics.height <= 0.0) return;

        for (layout.slice()) |group| {
            if (!self.isLayoutGroupUsable(manager, group.node_id)) continue;

            const size = group.rect.size();
            if (size[0] > 1.0 and size[1] > 1.0) {
                const edge_ratio = dock_drop.edge_band_ratio;
                const edge_w = @max(1.0, size[0] * edge_ratio);
                const edge_h = @max(1.0, size[1] * edge_ratio);
                const inner_min_x = group.rect.min[0] + edge_w;
                const inner_max_x = group.rect.max[0] - edge_w;
                const inner_min_y = group.rect.min[1] + edge_h;
                const inner_max_y = group.rect.max[1] - edge_h;
                const center_w = @max(1.0, inner_max_x - inner_min_x);
                const center_h = @max(1.0, inner_max_y - inner_min_y);

                out_drop_targets.append(.{
                    .node_id = group.node_id,
                    .location = .center,
                    .rect = UiRect.fromMinSize(
                        .{ inner_min_x, inner_min_y },
                        .{ center_w, center_h },
                    ),
                });
                out_drop_targets.append(.{
                    .node_id = group.node_id,
                    .location = .left,
                    .rect = UiRect.fromMinSize(group.rect.min, .{ edge_w, size[1] }),
                });
                out_drop_targets.append(.{
                    .node_id = group.node_id,
                    .location = .right,
                    .rect = UiRect.fromMinSize(
                        .{ group.rect.max[0] - edge_w, group.rect.min[1] },
                        .{ edge_w, size[1] },
                    ),
                });
                out_drop_targets.append(.{
                    .node_id = group.node_id,
                    .location = .top,
                    .rect = UiRect.fromMinSize(group.rect.min, .{ size[0], edge_h }),
                });
                out_drop_targets.append(.{
                    .node_id = group.node_id,
                    .location = .bottom,
                    .rect = UiRect.fromMinSize(
                        .{ group.rect.min[0], group.rect.max[1] - edge_h },
                        .{ size[0], edge_h },
                    ),
                });
            }

            const node = manager.workspace.dock_layout.getNode(group.node_id) orelse continue;
            const tabs_node = switch (node.*) {
                .tabs => |tabs| tabs,
                .split => {
                    continue;
                },
            };
            if (!self.isTabsNodeUsable(manager, &tabs_node)) continue;

            if (tabs_node.tabs.items.len == 0) continue;

            const group_width = group.rect.max[0] - group.rect.min[0];
            var tab_x = group.rect.min[0] + tab_metrics.pad;
            for (tabs_node.tabs.items, 0..) |panel_id, idx| {
                const panel = self.findPanelById(manager, panel_id) orelse continue;
                const tab_width = self.dockTabWidth(panel.title, group_width, tab_metrics);
                const tab_rect = UiRect.fromMinSize(
                    .{ tab_x, group.rect.min[1] },
                    .{ tab_width, tab_metrics.height },
                );
                if (tab_rect.min[0] + tab_width > group.rect.max[0] - tab_metrics.pad) break;
                out_tabs.append(.{
                    .panel_id = panel_id,
                    .node_id = group.node_id,
                    .tab_index = idx,
                    .rect = tab_rect,
                });
                tab_x = tab_rect.max[0] + tab_metrics.pad;
            }
        }
    }

    fn shouldLogDebug(self: *App, every_frames: u64) bool {
        if (every_frames == 0) return false;
        return self.debug_frame_counter > 0 and (self.debug_frame_counter % every_frames) == 0;
    }

    fn shouldLogStartup(self: *App) bool {
        return self.debug_frame_counter <= 5;
    }

    fn nsToMs(ns: i128) f32 {
        return @as(f32, @floatFromInt(ns)) / @as(f32, @floatFromInt(std.time.ns_per_ms));
    }

    fn recordPerfSample(
        self: *App,
        frame_ns: i128,
        ws_ns: i128,
        fs_ns: i128,
        debug_ns: i128,
        terminal_ns: i128,
        draw_ns: i128,
    ) void {
        const now_ms = std.time.milliTimestamp();
        if (self.perf_sample_started_ms == 0) {
            self.perf_sample_started_ms = now_ms;
        }

        self.perf_sample_frames += 1;
        self.perf_sample_total_frame_ns += frame_ns;
        self.perf_sample_total_ws_ns += ws_ns;
        self.perf_sample_total_fs_ns += fs_ns;
        self.perf_sample_total_debug_ns += debug_ns;
        self.perf_sample_total_terminal_ns += terminal_ns;
        self.perf_sample_total_draw_ns += draw_ns;
        self.perf_sample_total_panel_chat_ns += self.perf_frame_panel_ns.chat;
        self.perf_sample_total_panel_settings_ns += self.perf_frame_panel_ns.settings;
        self.perf_sample_total_panel_debug_ns += self.perf_frame_panel_ns.debug;
        self.perf_sample_total_panel_projects_ns += self.perf_frame_panel_ns.projects;
        self.perf_sample_total_panel_filesystem_ns += self.perf_frame_panel_ns.filesystem;
        self.perf_sample_total_panel_terminal_ns += self.perf_frame_panel_ns.terminal;
        self.perf_sample_total_panel_other_ns += self.perf_frame_panel_ns.other;
        self.perf_sample_total_cmd_total += self.perf_frame_cmd_stats.total;
        self.perf_sample_total_cmd_text += self.perf_frame_cmd_stats.text;
        self.perf_sample_total_cmd_shape += self.perf_frame_cmd_stats.shape;
        self.perf_sample_total_cmd_line += self.perf_frame_cmd_stats.line;
        self.perf_sample_total_cmd_image += self.perf_frame_cmd_stats.image;
        self.perf_sample_total_cmd_clip += self.perf_frame_cmd_stats.clip;
        self.perf_sample_total_text_bytes += self.perf_frame_cmd_stats.text_bytes;

        const elapsed_ms = now_ms - self.perf_sample_started_ms;
        if (elapsed_ms < PERF_SAMPLE_INTERVAL_MS) return;

        const frames_u32 = @max(self.perf_sample_frames, 1);
        const frames = @as(f32, @floatFromInt(frames_u32));
        const elapsed_ms_f = @as(f32, @floatFromInt(@max(elapsed_ms, 1)));

        self.perf_last_fps = (frames * 1000.0) / elapsed_ms_f;
        self.perf_last_frame_ms = nsToMs(self.perf_sample_total_frame_ns) / frames;
        self.perf_last_ws_ms = nsToMs(self.perf_sample_total_ws_ns) / frames;
        self.perf_last_fs_ms = nsToMs(self.perf_sample_total_fs_ns) / frames;
        self.perf_last_ws_wait_ms = if (self.awaiting_reply and self.pending_send_started_at_ms > 0)
            @as(f32, @floatFromInt(@max(0, now_ms - self.pending_send_started_at_ms)))
        else
            0.0;
        self.perf_last_fs_request_ms = if (self.filesystem_active_request) |active|
            @as(f32, @floatFromInt(@max(0, now_ms - active.started_at_ms)))
        else
            self.filesystem_last_request_duration_ms;
        self.perf_last_debug_ms = nsToMs(self.perf_sample_total_debug_ns) / frames;
        self.perf_last_terminal_ms = nsToMs(self.perf_sample_total_terminal_ns) / frames;
        self.perf_last_draw_ms = nsToMs(self.perf_sample_total_draw_ns) / frames;
        self.perf_last_panel_chat_ms = nsToMs(self.perf_sample_total_panel_chat_ns) / frames;
        self.perf_last_panel_settings_ms = nsToMs(self.perf_sample_total_panel_settings_ns) / frames;
        self.perf_last_panel_debug_ms = nsToMs(self.perf_sample_total_panel_debug_ns) / frames;
        self.perf_last_panel_projects_ms = nsToMs(self.perf_sample_total_panel_projects_ns) / frames;
        self.perf_last_panel_filesystem_ms = nsToMs(self.perf_sample_total_panel_filesystem_ns) / frames;
        self.perf_last_panel_terminal_ms = nsToMs(self.perf_sample_total_panel_terminal_ns) / frames;
        self.perf_last_panel_other_ms = nsToMs(self.perf_sample_total_panel_other_ns) / frames;
        self.perf_last_cmd_total_per_frame = @as(f32, @floatFromInt(self.perf_sample_total_cmd_total)) / frames;
        self.perf_last_cmd_text_per_frame = @as(f32, @floatFromInt(self.perf_sample_total_cmd_text)) / frames;
        self.perf_last_cmd_shape_per_frame = @as(f32, @floatFromInt(self.perf_sample_total_cmd_shape)) / frames;
        self.perf_last_cmd_line_per_frame = @as(f32, @floatFromInt(self.perf_sample_total_cmd_line)) / frames;
        self.perf_last_cmd_image_per_frame = @as(f32, @floatFromInt(self.perf_sample_total_cmd_image)) / frames;
        self.perf_last_cmd_clip_per_frame = @as(f32, @floatFromInt(self.perf_sample_total_cmd_clip)) / frames;
        self.perf_last_text_bytes_per_frame = @as(f32, @floatFromInt(self.perf_sample_total_text_bytes)) / frames;
        self.perf_last_text_command_share_pct = if (self.perf_last_cmd_total_per_frame > 0.0)
            (self.perf_last_cmd_text_per_frame / self.perf_last_cmd_total_per_frame) * 100.0
        else
            0.0;
        self.perf_history.append(self.allocator, .{
            .timestamp_ms = now_ms,
            .fps = self.perf_last_fps,
            .frame_ms = self.perf_last_frame_ms,
            .ws_poll_ms = self.perf_last_ws_ms,
            .fs_poll_ms = self.perf_last_fs_ms,
            .ws_wait_ms = self.perf_last_ws_wait_ms,
            .fs_request_ms = self.perf_last_fs_request_ms,
            .debug_ms = self.perf_last_debug_ms,
            .terminal_ms = self.perf_last_terminal_ms,
            .draw_ms = self.perf_last_draw_ms,
            .panel_chat_ms = self.perf_last_panel_chat_ms,
            .panel_settings_ms = self.perf_last_panel_settings_ms,
            .panel_debug_ms = self.perf_last_panel_debug_ms,
            .panel_projects_ms = self.perf_last_panel_projects_ms,
            .panel_filesystem_ms = self.perf_last_panel_filesystem_ms,
            .panel_terminal_ms = self.perf_last_panel_terminal_ms,
            .panel_other_ms = self.perf_last_panel_other_ms,
            .cmd_total_per_frame = self.perf_last_cmd_total_per_frame,
            .cmd_text_per_frame = self.perf_last_cmd_text_per_frame,
            .cmd_shape_per_frame = self.perf_last_cmd_shape_per_frame,
            .cmd_line_per_frame = self.perf_last_cmd_line_per_frame,
            .cmd_image_per_frame = self.perf_last_cmd_image_per_frame,
            .cmd_clip_per_frame = self.perf_last_cmd_clip_per_frame,
            .text_bytes_per_frame = self.perf_last_text_bytes_per_frame,
            .text_command_share_pct = self.perf_last_text_command_share_pct,
        }) catch {};
        while (self.perf_history.items.len > PERF_HISTORY_CAPACITY) {
            _ = self.perf_history.orderedRemove(0);
        }

        self.perf_sample_started_ms = now_ms;
        self.perf_sample_frames = 0;
        self.perf_sample_total_frame_ns = 0;
        self.perf_sample_total_ws_ns = 0;
        self.perf_sample_total_fs_ns = 0;
        self.perf_sample_total_debug_ns = 0;
        self.perf_sample_total_terminal_ns = 0;
        self.perf_sample_total_draw_ns = 0;
        self.perf_sample_total_panel_chat_ns = 0;
        self.perf_sample_total_panel_settings_ns = 0;
        self.perf_sample_total_panel_debug_ns = 0;
        self.perf_sample_total_panel_projects_ns = 0;
        self.perf_sample_total_panel_filesystem_ns = 0;
        self.perf_sample_total_panel_terminal_ns = 0;
        self.perf_sample_total_panel_other_ns = 0;
        self.perf_sample_total_cmd_total = 0;
        self.perf_sample_total_cmd_text = 0;
        self.perf_sample_total_cmd_shape = 0;
        self.perf_sample_total_cmd_line = 0;
        self.perf_sample_total_cmd_image = 0;
        self.perf_sample_total_cmd_clip = 0;
        self.perf_sample_total_text_bytes = 0;
    }

    fn safeWorkspaceCount(_: *App, value: usize, max: usize) usize {
        if (value > max) return max;
        return value;
    }

    fn detachPanelToNewWindow(self: *App, source_window: *UiWindow, panel_id: workspace.PanelId) void {
        const moved = source_window.manager.takePanel(panel_id) orelse return;
        if (source_window.manager.workspace.syncDockLayout() catch false) {
            source_window.manager.workspace.markDirty();
        }
        if (!self.createDetachedWindowFromPanel(source_window, moved)) {
            self.appendPanelToManager(source_window.manager, moved) catch {
                var tmp = moved;
                tmp.deinit(self.allocator);
            };
            source_window.manager.workspace.markDirty();
            if (source_window.manager.workspace.syncDockLayout() catch false) {
                source_window.manager.workspace.markDirty();
            }
        }
    }

    fn createDetachedWindowFromPanel(self: *App, source_window: *UiWindow, panel: workspace.Panel) bool {
        var ws = workspace.Workspace.initEmpty(self.allocator);
        var ws_owned = true;
        defer if (ws_owned) ws.deinit(self.allocator);

        ws.panels.append(self.allocator, panel) catch return false;
        ws.focused_panel_id = panel.id;
        _ = ws.syncDockLayout() catch false;

        const new_manager = self.allocator.create(panel_manager.PanelManager) catch return false;
        var owns_manager = true;
        defer if (owns_manager) {
            new_manager.deinit();
            self.allocator.destroy(new_manager);
        };

        new_manager.* = panel_manager.PanelManager.init(
            self.allocator,
            ws,
            &self.next_panel_id,
        );
        self.bindNextPanelId(new_manager);
        ws_owned = false;
        if (self.createDetachedWindowFromManager(source_window, new_manager, panel.title, true)) |_| {
            owns_manager = false;
            return true;
        } else |_| {
            return false;
        }
    }

    fn createDetachedWindowFromManager(
        self: *App,
        source_window: *UiWindow,
        manager: *panel_manager.PanelManager,
        title: []const u8,
        persist_in_workspace: bool,
    ) !*UiWindow {
        const width: c_int = 960;
        const height: c_int = 720;
        const title_with_null = try self.allocator.alloc(u8, title.len + 1);
        defer self.allocator.free(title_with_null);
        @memcpy(title_with_null[0..title.len], title);
        title_with_null[title.len] = 0;
        const title_z: [:0]const u8 = title_with_null[0..title.len :0];

        const win = zapp.sdl_app.createWindow(title_z, width, height, c.SDL_WINDOW_RESIZABLE) catch {
            return error.SdlWindowCreateFailed;
        };
        errdefer c.SDL_DestroyWindow(win);

        var pos_x: c_int = 0;
        var pos_y: c_int = 0;
        _ = c.SDL_GetWindowPosition(source_window.window, &pos_x, &pos_y);
        const offset: c_int = @intCast(@min(self.ui_windows.items.len * 24, 220));
        _ = c.SDL_SetWindowPosition(win, pos_x + offset, pos_y + offset);

        const out = try self.createUiWindowFromExisting(
            win,
            title,
            manager,
            false,
            persist_in_workspace,
            true,
            true,
        );
        errdefer self.destroyUiWindow(out);
        try self.ui_windows.append(self.allocator, out);
        return out;
    }

    fn pollWebSocket(self: *App) !void {
        if (self.ws_client) |*client| {
            if (!client.isAlive()) {
                const has_pending_send = self.pending_send_message_id != null;
                self.debug_stream_snapshot_pending = true;
                self.debug_stream_snapshot_retry_at_ms = 0;
                self.clearDebugStreamSnapshot();
                self.stopFilesystemWorker();
                self.clearTerminalState();

                client.deinit();
                self.ws_client = null;
                self.session_attach_state = .unknown;
                self.setConnectionState(.error_state, "Connection lost. Please reconnect.");
                if (self.ui_stage == .workspace) {
                    self.returnToLauncher(.connection_lost);
                }
                if (has_pending_send) {
                    if (!self.pending_send_resume_notified) {
                        if (self.pending_send_job_id) |job_id| {
                            const msg = try std.fmt.allocPrint(
                                self.allocator,
                                "Connection lost while waiting for job {s}. Reconnect to resume.",
                                .{job_id},
                            );
                            defer self.allocator.free(msg);
                            try self.appendMessage("system", msg, null);
                        } else {
                            try self.appendMessage("system", "Connection lost while waiting for assistant response. Reconnect to resume.", null);
                        }
                        self.pending_send_resume_notified = true;
                    }
                } else {
                    try self.appendMessage("system", "Connection lost. Please reconnect.", null);
                }
                return;
            }

            var count: u32 = 0;
            const started_ns = std.time.nanoTimestamp();
            // Incremental drain: bounded receive work per frame to keep UI responsive.
            while (count < WS_MAX_MESSAGES_PER_FRAME) {
                const msg = client.tryReceive() orelse break;
                count += 1;
                defer self.allocator.free(msg);

                self.handleIncomingMessage(msg) catch |err| {
                    const msg_text = try std.fmt.allocPrint(self.allocator, "Failed to parse message: {s}", .{@errorName(err)});
                    defer self.allocator.free(msg_text);
                    try self.appendMessage("system", msg_text, null);
                };

                if (std.time.nanoTimestamp() - started_ns >= WS_MAX_POLL_BUDGET_NS) {
                    break;
                }
            }
            if (count > 0 and self.shouldLogDebug(120)) {
                std.log.debug("[ZSS] Polled {d} messages this frame", .{count});
            }
        }
    }

    fn pollFilesystemWorker(self: *App) void {
        if (self.filesystem_active_request != null) return;
        if (self.connection_state != .connected) return;
        const pending_path = self.filesystem_pending_path orelse return;

        const now = std.time.milliTimestamp();
        if (now < self.filesystem_pending_retry_at_ms) return;

        const path = self.allocator.dupe(u8, pending_path) catch return;
        defer self.allocator.free(path);
        const use_cache = self.filesystem_pending_use_cache;
        const force_refresh = self.filesystem_pending_force_refresh;
        self.clearPendingFilesystemPathLoad();
        self.queueFilesystemPathLoad(path, use_cache, force_refresh) catch |err| {
            if (err != error.Busy and err != error.NotConnected) {
                std.log.debug("filesystem pending load skipped: {s}", .{@errorName(err)});
            }
        };
    }

    fn pollDebugStream(self: *App) void {
        if (!self.debug_stream_enabled) return;
        if (self.connection_state != .connected) return;
        if (self.filesystem_active_request != null) return;
        if (self.awaiting_reply or self.pending_send_job_id != null) return;
        if (!self.debug_stream_snapshot_pending) return;

        const now = std.time.milliTimestamp();
        if (now < self.debug_stream_snapshot_retry_at_ms) return;

        self.submitFilesystemRequestWithMode(.read_file, DEBUG_STREAM_PATH, false, true) catch |err| {
            if (err != error.Busy and err != error.NotConnected) {
                std.log.debug("debug stream poll skipped: {s}", .{@errorName(err)});
            }
            self.debug_stream_snapshot_pending = true;
            self.debug_stream_snapshot_retry_at_ms = now + DEBUG_STREAM_SNAPSHOT_RETRY_MS;
            return;
        };
    }

    fn pollNodeServiceSnapshot(self: *App) void {
        if (!self.node_service_watch_enabled) return;
        if (self.connection_state != .connected) return;
        if (self.filesystem_active_request != null) return;
        if (self.awaiting_reply or self.pending_send_job_id != null) return;
        if (!self.node_service_snapshot_pending) return;

        const now = std.time.milliTimestamp();
        if (now < self.node_service_snapshot_retry_at_ms) return;

        self.submitFilesystemRequestWithMode(.read_file, NODE_SERVICE_EVENTS_PATH, false, true) catch |err| {
            if (err != error.Busy and err != error.NotConnected) {
                std.log.debug("node service snapshot poll skipped: {s}", .{@errorName(err)});
            }
            self.node_service_snapshot_pending = true;
            self.node_service_snapshot_retry_at_ms = now + NODE_SERVICE_SNAPSHOT_RETRY_MS;
            return;
        };
    }

    fn requestDebugStreamSnapshot(self: *App, immediate: bool) void {
        self.debug_stream_snapshot_pending = true;
        if (immediate) {
            self.debug_stream_snapshot_retry_at_ms = 0;
        } else if (self.debug_stream_snapshot_retry_at_ms == 0) {
            self.debug_stream_snapshot_retry_at_ms = std.time.milliTimestamp() + DEBUG_STREAM_SNAPSHOT_RETRY_MS;
        }
    }

    fn requestNodeServiceSnapshot(self: *App, immediate: bool) void {
        self.node_service_snapshot_pending = true;
        if (immediate) {
            self.node_service_snapshot_retry_at_ms = 0;
        } else if (self.node_service_snapshot_retry_at_ms == 0) {
            self.node_service_snapshot_retry_at_ms = std.time.milliTimestamp() + NODE_SERVICE_SNAPSHOT_RETRY_MS;
        }
    }

    fn handleFilesystemWorkerResult(self: *App, result: *const FilesystemRequestResult) void {
        const active = self.filesystem_active_request orelse return;
        if (active.id != result.id) return;
        const request_finished_ms = std.time.milliTimestamp();
        const request_duration_ms: f32 = @as(f32, @floatFromInt(@max(0, request_finished_ms - active.started_at_ms)));

        self.filesystem_active_request = null;
        if (!active.is_background) self.filesystem_busy = false;
        if (!active.is_background) {
            self.filesystem_last_request_duration_ms = request_duration_ms;
        }

        const is_debug_stream_result = std.mem.eql(u8, result.path, DEBUG_STREAM_PATH);
        if (is_debug_stream_result) {
            if (result.error_text) |_| {
                self.debug_stream_snapshot_pending = true;
                self.debug_stream_snapshot_retry_at_ms = std.time.milliTimestamp() + DEBUG_STREAM_SNAPSHOT_RETRY_MS;
                return;
            }
            const content = result.content orelse {
                self.debug_stream_snapshot_pending = true;
                self.debug_stream_snapshot_retry_at_ms = std.time.milliTimestamp() + DEBUG_STREAM_SNAPSHOT_RETRY_MS;
                return;
            };
            self.mergeDebugStreamSnapshot(content) catch |err| {
                std.log.warn("debug stream merge failed: {s}", .{@errorName(err)});
            };
            // Keep polling while debug stream is enabled so new events arrive
            // without requiring manual refresh.
            self.debug_stream_snapshot_pending = true;
            self.debug_stream_snapshot_retry_at_ms = std.time.milliTimestamp() + DEBUG_STREAM_SNAPSHOT_RETRY_MS;
            return;
        }

        const is_node_service_snapshot = std.mem.eql(u8, result.path, NODE_SERVICE_EVENTS_PATH);
        if (is_node_service_snapshot) {
            if (result.error_text) |_| {
                if (self.node_service_watch_enabled) {
                    self.node_service_snapshot_pending = true;
                    self.node_service_snapshot_retry_at_ms = std.time.milliTimestamp() + NODE_SERVICE_SNAPSHOT_RETRY_MS;
                }
                return;
            }
            const content = result.content orelse {
                if (self.node_service_watch_enabled) {
                    self.node_service_snapshot_pending = true;
                    self.node_service_snapshot_retry_at_ms = std.time.milliTimestamp() + NODE_SERVICE_SNAPSHOT_RETRY_MS;
                }
                return;
            };
            self.ingestNodeServiceSnapshotLines(content) catch |err| {
                std.log.warn("node service snapshot merge failed: {s}", .{@errorName(err)});
            };
            if (self.node_service_watch_enabled) {
                self.node_service_snapshot_pending = true;
                self.node_service_snapshot_retry_at_ms = std.time.milliTimestamp() + NODE_SERVICE_SNAPSHOT_RETRY_MS;
            }
            return;
        }

        if (result.error_text) |err_text| {
            self.setFsrpcRemoteError(err_text);
            self.setFilesystemError(err_text);
            return;
        }

        self.clearFsrpcRemoteError();
        self.clearFilesystemError();

        switch (result.kind) {
            .list_dir => {
                const listing = result.listing orelse {
                    self.setFilesystemError("filesystem request returned no directory listing");
                    return;
                };
                self.putFilesystemDirCache(result.path, listing) catch {};
                self.applyFilesystemListing(result.path, listing) catch |err| {
                    const msg = std.fmt.allocPrint(self.allocator, "Filesystem listing apply failed: {s}", .{@errorName(err)}) catch null;
                    defer if (msg) |value| self.allocator.free(value);
                    if (msg) |value| self.setFilesystemError(value);
                };
            },
            .read_file => {
                const content = result.content orelse {
                    self.setFilesystemError("filesystem request returned no file content");
                    return;
                };
                self.applyFilesystemPreview(result.path, content) catch |err| {
                    const msg = std.fmt.allocPrint(self.allocator, "Filesystem preview apply failed: {s}", .{@errorName(err)}) catch null;
                    defer if (msg) |value| self.allocator.free(value);
                    if (msg) |value| self.setFilesystemError(value);
                };
            },
            .resolve_kind => {
                const is_dir = result.is_dir orelse {
                    self.setFilesystemError("filesystem request returned no path-kind result");
                    return;
                };
                const resolved_kind: FilesystemEntryKind = if (is_dir) .directory else .file;
                self.updateFilesystemEntryKind(result.path, resolved_kind);
                if (!active.open_after_resolve) {
                    if (self.filesystem_selected_path) |selected| {
                        if (std.mem.eql(u8, selected, result.path)) {
                            self.refreshSelectedFilesystemPreview() catch |err| {
                                const msg = std.fmt.allocPrint(self.allocator, "Filesystem preview failed: {s}", .{@errorName(err)}) catch null;
                                defer if (msg) |value| self.allocator.free(value);
                                if (msg) |value| self.setFilesystemError(value);
                            };
                        }
                    }
                    return;
                }

                if (is_dir) {
                    self.queueFilesystemPathLoad(result.path, true, false) catch |err| {
                        const msg = std.fmt.allocPrint(self.allocator, "Filesystem open failed: {s}", .{@errorName(err)}) catch null;
                        defer if (msg) |value| self.allocator.free(value);
                        if (msg) |value| self.setFilesystemError(value);
                    };
                } else {
                    self.submitFilesystemRequest(.read_file, result.path, false) catch |err| {
                        const msg = std.fmt.allocPrint(self.allocator, "Filesystem file read failed: {s}", .{@errorName(err)}) catch null;
                        defer if (msg) |value| self.allocator.free(value);
                        if (msg) |value| self.setFilesystemError(value);
                    };
                }
            },
        }
    }

    fn isPanelFocused(_: *App, manager: *panel_manager.PanelManager, panel_id: workspace.PanelId) bool {
        return manager.workspace.focused_panel_id != null and manager.workspace.focused_panel_id.? == panel_id;
    }

    fn setDragMouseCapture(self: *App, enabled: bool) void {
        if (self.drag_mouse_capture_active == enabled) return;
        _ = c.SDL_CaptureMouse(enabled);
        self.drag_mouse_capture_active = enabled;
    }

    fn windowToFramebufferScale(win: *c.SDL_Window) [2]f32 {
        var w: c_int = 0;
        var h: c_int = 0;
        _ = c.SDL_GetWindowSize(win, &w, &h);
        var pw: c_int = 0;
        var ph: c_int = 0;
        _ = c.SDL_GetWindowSizeInPixels(win, &pw, &ph);
        if (w <= 0 or h <= 0 or pw <= 0 or ph <= 0) return .{ 1.0, 1.0 };
        return .{
            @as(f32, @floatFromInt(pw)) / @as(f32, @floatFromInt(w)),
            @as(f32, @floatFromInt(ph)) / @as(f32, @floatFromInt(h)),
        };
    }

    fn syncMouseStateFromGlobal(self: *App, ui_window: *UiWindow) void {
        var mouse_global_x: f32 = 0.0;
        var mouse_global_y: f32 = 0.0;
        const buttons = c.SDL_GetGlobalMouseState(&mouse_global_x, &mouse_global_y);

        var window_x: c_int = 0;
        var window_y: c_int = 0;
        _ = c.SDL_GetWindowPosition(ui_window.window, &window_x, &window_y);
        const scale = windowToFramebufferScale(ui_window.window);
        self.mouse_x = (mouse_global_x - @as(f32, @floatFromInt(window_x))) * scale[0];
        self.mouse_y = (mouse_global_y - @as(f32, @floatFromInt(window_y))) * scale[1];
        self.mouse_down = (buttons & c.SDL_BUTTON_LMASK) != 0;
    }

    fn focusedSettingsBuffer(self: *App) ?*std.ArrayList(u8) {
        return switch (self.settings_panel.focused_field) {
            .server_url => &self.settings_panel.server_url,
            .project_id => &self.settings_panel.project_id,
            .launcher_project_filter => &self.launcher_project_filter,
            .launcher_profile_name => &self.launcher_profile_name,
            .launcher_profile_metadata => &self.launcher_profile_metadata,
            .launcher_connect_token => &self.launcher_connect_token,
            .project_token => &self.settings_panel.project_token,
            .project_create_name => &self.settings_panel.project_create_name,
            .project_create_vision => &self.settings_panel.project_create_vision,
            .project_operator_token => &self.settings_panel.project_operator_token,
            .project_mount_path => &self.settings_panel.project_mount_path,
            .project_mount_node_id => &self.settings_panel.project_mount_node_id,
            .project_mount_export_name => &self.settings_panel.project_mount_export_name,
            .default_session => &self.settings_panel.default_session,
            .default_agent => &self.settings_panel.default_agent,
            .ui_theme => &self.settings_panel.ui_theme,
            .ui_profile => &self.settings_panel.ui_profile,
            .ui_theme_pack => &self.settings_panel.ui_theme_pack,
            .node_watch_filter => &self.node_service_watch_filter,
            .node_watch_replay_limit => &self.node_service_watch_replay_limit,
            .debug_search_filter => &self.debug_search_filter,
            .perf_benchmark_label => &self.perf_benchmark_label_input,
            .filesystem_contract_payload => &self.contract_invoke_payload,
            .terminal_command_input => &self.terminal_input,
            .none => null,
        };
    }

    fn clearTextEditSnapshotStack(self: *App, stack: *std.ArrayListUnmanaged(TextEditSnapshot)) void {
        while (stack.items.len > 0) {
            var snapshot = stack.items[stack.items.len - 1];
            stack.items.len -= 1;
            snapshot.deinit(self.allocator);
        }
    }

    fn clearTextEditHistory(self: *App) void {
        self.clearTextEditSnapshotStack(&self.text_edit_undo_stack);
        self.clearTextEditSnapshotStack(&self.text_edit_redo_stack);
        self.text_edit_history_field = .none;
    }

    fn ensureTextEditHistoryField(self: *App, field: SettingsFocusField) void {
        if (field == .none) return;
        if (self.text_edit_history_field == field) return;
        self.clearTextEditSnapshotStack(&self.text_edit_undo_stack);
        self.clearTextEditSnapshotStack(&self.text_edit_redo_stack);
        self.text_edit_history_field = field;
    }

    fn pushTextEditSnapshot(
        self: *App,
        stack: *std.ArrayListUnmanaged(TextEditSnapshot),
        text: []const u8,
        cursor: usize,
        selection_anchor: ?usize,
    ) !void {
        const clamped_cursor = @min(cursor, text.len);
        const clamped_anchor = if (selection_anchor) |value| @min(value, text.len) else null;
        if (stack.items.len > 0) {
            const top = stack.items[stack.items.len - 1];
            if (top.cursor == clamped_cursor and top.selection_anchor == clamped_anchor and std.mem.eql(u8, top.text, text)) {
                return;
            }
        }
        if (stack.items.len >= TEXT_EDIT_HISTORY_LIMIT) {
            var oldest = stack.items[0];
            oldest.deinit(self.allocator);
            if (stack.items.len > 1) {
                std.mem.copyForwards(
                    TextEditSnapshot,
                    stack.items[0 .. stack.items.len - 1],
                    stack.items[1..stack.items.len],
                );
            }
            stack.items.len -= 1;
        }

        const snapshot = TextEditSnapshot{
            .text = try self.allocator.dupe(u8, text),
            .cursor = clamped_cursor,
            .selection_anchor = clamped_anchor,
        };
        errdefer self.allocator.free(snapshot.text);
        try stack.append(self.allocator, snapshot);
    }

    fn recordFocusedTextUndoState(self: *App, buf: *std.ArrayList(u8)) !void {
        const focused_field = self.settings_panel.focused_field;
        if (focused_field == .none) return;
        self.ensureTextEditHistoryField(focused_field);
        self.clampFocusedTextInputState(buf.items);
        try self.pushTextEditSnapshot(
            &self.text_edit_undo_stack,
            buf.items,
            self.text_input_cursor,
            self.text_input_selection_anchor,
        );
        self.clearTextEditSnapshotStack(&self.text_edit_redo_stack);
    }

    fn applyTextEditSnapshot(self: *App, buf: *std.ArrayList(u8), snapshot: *const TextEditSnapshot) !void {
        buf.clearRetainingCapacity();
        try buf.appendSlice(self.allocator, snapshot.text);
        self.text_input_cursor = @min(snapshot.cursor, buf.items.len);
        self.text_input_selection_anchor = if (snapshot.selection_anchor) |value| @min(value, buf.items.len) else null;
        self.text_input_cursor_initialized = true;
    }

    fn undoFocusedTextEdit(self: *App, buf: *std.ArrayList(u8)) !bool {
        const focused_field = self.settings_panel.focused_field;
        if (focused_field == .none) return false;
        self.ensureTextEditHistoryField(focused_field);
        if (self.text_edit_undo_stack.items.len == 0) return false;

        self.clampFocusedTextInputState(buf.items);
        try self.pushTextEditSnapshot(
            &self.text_edit_redo_stack,
            buf.items,
            self.text_input_cursor,
            self.text_input_selection_anchor,
        );

        var snapshot = self.text_edit_undo_stack.items[self.text_edit_undo_stack.items.len - 1];
        self.text_edit_undo_stack.items.len -= 1;
        defer snapshot.deinit(self.allocator);
        try self.applyTextEditSnapshot(buf, &snapshot);
        return true;
    }

    fn redoFocusedTextEdit(self: *App, buf: *std.ArrayList(u8)) !bool {
        const focused_field = self.settings_panel.focused_field;
        if (focused_field == .none) return false;
        self.ensureTextEditHistoryField(focused_field);
        if (self.text_edit_redo_stack.items.len == 0) return false;

        self.clampFocusedTextInputState(buf.items);
        try self.pushTextEditSnapshot(
            &self.text_edit_undo_stack,
            buf.items,
            self.text_input_cursor,
            self.text_input_selection_anchor,
        );

        var snapshot = self.text_edit_redo_stack.items[self.text_edit_redo_stack.items.len - 1];
        self.text_edit_redo_stack.items.len -= 1;
        defer snapshot.deinit(self.allocator);
        try self.applyTextEditSnapshot(buf, &snapshot);
        return true;
    }

    fn hasSingleLineInsertableBytes(text: []const u8) bool {
        for (text) |ch| {
            if (ch == '\n' or ch == '\r') continue;
            if (ch < 0x20) continue;
            return true;
        }
        return false;
    }

    fn prevUtf8Boundary(text: []const u8, index: usize) usize {
        if (index == 0) return 0;
        var i = @min(index, text.len) - 1;
        while (i > 0 and (text[i] & 0xC0) == 0x80) : (i -= 1) {}
        return i;
    }

    fn clampFocusedTextInputState(self: *App, text: []const u8) void {
        if (self.text_input_cursor > text.len) self.text_input_cursor = text.len;
        if (self.text_input_selection_anchor) |anchor| {
            self.text_input_selection_anchor = @min(anchor, text.len);
        }
    }

    fn focusedTextSelectionRange(self: *App, text: []const u8) ?[2]usize {
        self.clampFocusedTextInputState(text);
        const anchor = self.text_input_selection_anchor orelse return null;
        if (anchor == self.text_input_cursor) return null;
        if (anchor < self.text_input_cursor) return .{ anchor, self.text_input_cursor };
        return .{ self.text_input_cursor, anchor };
    }

    fn clearFocusedTextSelection(self: *App) void {
        self.text_input_selection_anchor = null;
    }

    fn removeRangeFromBuffer(buf: *std.ArrayList(u8), start: usize, end: usize) void {
        if (end <= start) return;
        const len = buf.items.len;
        if (start >= len) return;
        const clamped_end = @min(end, len);
        if (clamped_end <= start) return;
        const tail_len = len - clamped_end;
        if (tail_len > 0) {
            std.mem.copyForwards(u8, buf.items[start..], buf.items[clamped_end..]);
        }
        buf.shrinkRetainingCapacity(len - (clamped_end - start));
    }

    fn deleteFocusedTextSelection(self: *App, buf: *std.ArrayList(u8)) bool {
        const range = self.focusedTextSelectionRange(buf.items) orelse return false;
        removeRangeFromBuffer(buf, range[0], range[1]);
        self.text_input_cursor = range[0];
        self.clearFocusedTextSelection();
        return true;
    }

    fn insertSingleLineTextAtCursor(
        self: *App,
        buf: *std.ArrayList(u8),
        text: []const u8,
    ) !bool {
        if (text.len == 0) return false;
        var changed = self.deleteFocusedTextSelection(buf);
        var inserted: usize = 0;
        for (text) |ch| {
            if (ch == '\n' or ch == '\r') continue;
            if (ch < 0x20) continue;
            try buf.insert(self.allocator, self.text_input_cursor + inserted, ch);
            inserted += 1;
        }
        if (inserted > 0) {
            self.text_input_cursor += inserted;
            changed = true;
        }
        self.clearFocusedTextSelection();
        return changed;
    }

    fn copyFocusedTextSelectionToClipboard(self: *App, text: []const u8) bool {
        const range = self.focusedTextSelectionRange(text) orelse return false;
        if (range[1] <= range[0]) return false;
        self.copyTextToClipboard(text[range[0]..range[1]]) catch return false;
        return true;
    }

    fn moveFocusedTextCursor(self: *App, text: []const u8, key: anytype, shift: bool) void {
        self.clampFocusedTextInputState(text);
        const old_cursor = self.text_input_cursor;
        switch (key) {
            .left_arrow => {
                if (self.text_input_cursor > 0) {
                    self.text_input_cursor = prevUtf8Boundary(text, self.text_input_cursor);
                }
            },
            .right_arrow => {
                if (self.text_input_cursor < text.len) {
                    self.text_input_cursor = nextUtf8Boundary(text, self.text_input_cursor);
                }
            },
            .home => self.text_input_cursor = 0,
            .end => self.text_input_cursor = text.len,
            else => {},
        }
        if (shift) {
            if (self.text_input_selection_anchor == null) {
                self.text_input_selection_anchor = old_cursor;
            }
            if (self.text_input_selection_anchor.? == self.text_input_cursor) {
                self.clearFocusedTextSelection();
            }
        } else {
            self.clearFocusedTextSelection();
        }
    }

    fn handleFocusedTextInputKey(self: *App, buf: *std.ArrayList(u8), key_evt: anytype) !bool {
        if (!self.text_input_cursor_initialized) {
            self.text_input_cursor = buf.items.len;
            self.text_input_cursor_initialized = true;
        }
        const focused_field = self.settings_panel.focused_field;
        if (focused_field == .none) return false;
        self.ensureTextEditHistoryField(focused_field);

        if (key_evt.repeat and (key_evt.key == .c or key_evt.key == .x or key_evt.key == .v or key_evt.key == .a)) {
            return true;
        }
        const ctrl = key_evt.mods.ctrl;
        const shift = key_evt.mods.shift;
        switch (key_evt.key) {
            .a => {
                if (ctrl) {
                    self.text_input_cursor = buf.items.len;
                    self.text_input_selection_anchor = 0;
                    return true;
                }
            },
            .c => {
                if (ctrl) {
                    _ = self.copyFocusedTextSelectionToClipboard(buf.items);
                    return true;
                }
            },
            .x => {
                if (ctrl) {
                    if (self.copyFocusedTextSelectionToClipboard(buf.items)) {
                        try self.recordFocusedTextUndoState(buf);
                        _ = self.deleteFocusedTextSelection(buf);
                    }
                    return true;
                }
            },
            .v => {
                if (ctrl) {
                    const clip = zapp.clipboard.getTextZ();
                    if (clip.len > 0 and (self.focusedTextSelectionRange(buf.items) != null or hasSingleLineInsertableBytes(clip))) {
                        try self.recordFocusedTextUndoState(buf);
                        _ = try self.insertSingleLineTextAtCursor(buf, clip);
                    }
                    return true;
                }
            },
            .z => {
                if (ctrl) {
                    if (shift) {
                        _ = try self.redoFocusedTextEdit(buf);
                    } else {
                        _ = try self.undoFocusedTextEdit(buf);
                    }
                    return true;
                }
            },
            .y => {
                if (ctrl) {
                    _ = try self.redoFocusedTextEdit(buf);
                    return true;
                }
            },
            .left_arrow, .right_arrow, .home, .end => {
                self.moveFocusedTextCursor(buf.items, key_evt.key, shift);
                return true;
            },
            .back_space => {
                self.clampFocusedTextInputState(buf.items);
                if (self.focusedTextSelectionRange(buf.items) != null) {
                    try self.recordFocusedTextUndoState(buf);
                    _ = self.deleteFocusedTextSelection(buf);
                    return true;
                }
                if (self.text_input_cursor > 0) {
                    try self.recordFocusedTextUndoState(buf);
                    const prev = prevUtf8Boundary(buf.items, self.text_input_cursor);
                    removeRangeFromBuffer(buf, prev, self.text_input_cursor);
                    self.text_input_cursor = prev;
                }
                return true;
            },
            .delete => {
                self.clampFocusedTextInputState(buf.items);
                if (self.focusedTextSelectionRange(buf.items) != null) {
                    try self.recordFocusedTextUndoState(buf);
                    _ = self.deleteFocusedTextSelection(buf);
                    return true;
                }
                if (self.text_input_cursor < buf.items.len) {
                    try self.recordFocusedTextUndoState(buf);
                    const next = nextUtf8Boundary(buf.items, self.text_input_cursor);
                    removeRangeFromBuffer(buf, self.text_input_cursor, next);
                }
                return true;
            },
            else => {},
        }
        return false;
    }

    fn handleKeyDownEvent(self: *App, key_evt: anytype, request_spawn_window: *bool, manager: *panel_manager.PanelManager) !void {
        if (self.focusedSettingsBuffer()) |buf| {
            if (try self.handleFocusedTextInputKey(buf, key_evt)) return;
        }

        switch (key_evt.key) {
            .escape => {
                self.running = false;
            },
            .y => {
                if (key_evt.mods.ctrl and !key_evt.repeat) {
                    request_spawn_window.* = true;
                }
            },
            .enter, .keypad_enter => {
                if (self.settings_panel.focused_field == .server_url) {
                    try self.tryConnect(manager);
                } else if (self.settings_panel.focused_field == .terminal_command_input) {
                    self.sendTerminalInputFromUi() catch |err| {
                        const msg = self.formatFilesystemOpError("Terminal send failed", err);
                        if (msg) |text| {
                            defer self.allocator.free(text);
                            self.setTerminalError(text);
                        }
                    };
                }
            },
            .c => {
                if (key_evt.mods.ctrl and !key_evt.repeat and self.debug_selected_index != null) {
                    var allow_copy = false;
                    if (self.debug_panel_id != null and self.isPanelFocused(manager, self.debug_panel_id.?)) {
                        allow_copy = true;
                    }
                    // Also allow Ctrl+C when mouse is over the debug output area
                    if (self.debug_output_rect.contains(.{ self.mouse_x, self.mouse_y })) {
                        allow_copy = true;
                    }
                    if (allow_copy) {
                        if (self.debug_selected_index) |sel_idx| {
                            if (sel_idx < self.debug_events.items.len) {
                                const entry = self.debug_events.items[sel_idx];
                                const to_copy = std.fmt.allocPrint(
                                    self.allocator,
                                    "{d} {s} {s}",
                                    .{ entry.timestamp_ms, entry.category, entry.payload_json },
                                ) catch "";
                                if (to_copy.len > 0) {
                                    const buf = self.allocator.alloc(u8, to_copy.len + 1) catch {
                                        self.allocator.free(to_copy);
                                        return;
                                    };
                                    @memcpy(buf[0..to_copy.len], to_copy);
                                    buf[to_copy.len] = 0;
                                    const zslice: [:0]const u8 = buf[0..to_copy.len :0];
                                    zapp.clipboard.setTextZ(zslice);
                                    self.allocator.free(buf);
                                    self.allocator.free(to_copy);
                                }
                            }
                        }
                    }
                }
            },
            .page_up => {
                if (self.debug_panel_id) |panel_id| {
                    if (self.isPanelFocused(manager, panel_id)) {
                        self.debug_scroll_y -= 200.0 * self.ui_scale;
                        if (self.debug_scroll_y < 0.0) self.debug_scroll_y = 0.0;
                    }
                }
                if (self.focusedFormScrollY(manager)) |scroll_y| {
                    scroll_y.* -= 200.0 * self.ui_scale;
                    if (scroll_y.* < 0.0) scroll_y.* = 0.0;
                }
            },
            .page_down => {
                if (self.debug_panel_id) |panel_id| {
                    if (self.isPanelFocused(manager, panel_id)) {
                        self.debug_scroll_y += 200.0 * self.ui_scale;
                    }
                }
                if (self.focusedFormScrollY(manager)) |scroll_y| {
                    scroll_y.* += 200.0 * self.ui_scale;
                }
            },
            .home => {
                if (self.debug_panel_id) |panel_id| {
                    if (self.isPanelFocused(manager, panel_id)) {
                        self.debug_scroll_y = 0.0;
                    }
                }
                if (self.focusedFormScrollY(manager)) |scroll_y| {
                    scroll_y.* = 0.0;
                }
            },
            .end => {
                if (self.debug_panel_id) |panel_id| {
                    if (self.isPanelFocused(manager, panel_id)) {
                        // Move far down; clamped during render
                        self.debug_scroll_y += 1_000_000.0;
                    }
                }
                if (self.focusedFormScrollY(manager)) |scroll_y| {
                    // Move far down; clamped during render
                    scroll_y.* += 1_000_000.0;
                }
            },
            .up_arrow => {
                if (self.debug_panel_id) |panel_id| {
                    if (self.isPanelFocused(manager, panel_id)) {
                        self.debug_scroll_y -= 40.0 * self.ui_scale;
                        if (self.debug_scroll_y < 0.0) self.debug_scroll_y = 0.0;
                    }
                }
                if (self.focusedFormScrollY(manager)) |scroll_y| {
                    scroll_y.* -= 40.0 * self.ui_scale;
                    if (scroll_y.* < 0.0) scroll_y.* = 0.0;
                }
            },
            .down_arrow => {
                if (self.debug_panel_id) |panel_id| {
                    if (self.isPanelFocused(manager, panel_id)) {
                        self.debug_scroll_y += 40.0 * self.ui_scale;
                    }
                }
                if (self.focusedFormScrollY(manager)) |scroll_y| {
                    scroll_y.* += 40.0 * self.ui_scale;
                }
            },
            else => {},
        }
    }

    fn handleTextInput(self: *App, text: []const u8) !void {
        if (text.len == 0) return;
        if (self.focusedSettingsBuffer()) |buf| {
            const focused_field = self.settings_panel.focused_field;
            if (focused_field == .none) return;
            self.ensureTextEditHistoryField(focused_field);
            if (!self.text_input_cursor_initialized) {
                self.text_input_cursor = buf.items.len;
                self.text_input_cursor_initialized = true;
            }
            if (self.focusedTextSelectionRange(buf.items) != null or hasSingleLineInsertableBytes(text)) {
                try self.recordFocusedTextUndoState(buf);
                _ = try self.insertSingleLineTextAtCursor(buf, text);
            }
        }
    }

    fn syncSettingsToConfig(self: *App) !void {
        try self.config.setServerUrl(self.settings_panel.server_url.items);
        try self.config.setSelectedProject(
            if (self.settings_panel.project_id.items.len > 0)
                self.settings_panel.project_id.items
            else
                null,
        );
        if (self.settings_panel.project_id.items.len > 0) {
            try self.config.setProjectToken(
                self.settings_panel.project_id.items,
                self.settings_panel.project_token.items,
            );
        }
        if (self.settings_panel.project_operator_token.items.len > 0) {
            try self.config.setRoleToken(.admin, self.settings_panel.project_operator_token.items);
        }
        try self.config.setDefaultSession(self.settings_panel.default_session.items);
        try self.config.setDefaultAgent(
            if (self.settings_panel.default_agent.items.len > 0)
                self.settings_panel.default_agent.items
            else
                null,
        );
        self.config.auto_connect_on_launch = self.settings_panel.auto_connect_on_launch;
        try self.config.setTheme(if (self.settings_panel.ui_theme.items.len > 0) self.settings_panel.ui_theme.items else null);
        try self.config.setProfile(if (self.settings_panel.ui_profile.items.len > 0) self.settings_panel.ui_profile.items else null);
        try self.config.setThemePack(if (self.settings_panel.ui_theme_pack.items.len > 0) self.settings_panel.ui_theme_pack.items else null);
        self.config.setWatchThemePack(self.settings_panel.watch_theme_pack);
        try self.config.setTerminalBackend(terminal_render_backend.Backend.kindName(self.settings_panel.terminal_backend_kind));
        self.config.gui_verbose_ws_logs = self.settings_panel.ws_verbose_logs;
        try self.config.syncSelectedProfileFromLegacyFields();
        const profile_id = self.config.selectedProfileId();
        if (self.config.getRoleToken(.admin).len > 0) {
            self.credential_store.save(profile_id, "role_admin", self.config.getRoleToken(.admin)) catch {};
        } else {
            self.credential_store.delete(profile_id, "role_admin") catch {};
        }
        if (self.config.getRoleToken(.user).len > 0) {
            self.credential_store.save(profile_id, "role_user", self.config.getRoleToken(.user)) catch {};
        } else {
            self.credential_store.delete(profile_id, "role_user") catch {};
        }
        try self.config.save();

        self.applySelectedTerminalBackend();
        self.applyThemeFromSettings();
    }

    fn clearWorkspaceData(self: *App) void {
        workspace_types.deinitProjectList(self.allocator, &self.projects);
        workspace_types.deinitNodeList(self.allocator, &self.nodes);
        self.project_selector_open = false;
        self.clearConnectSetupHint();
        if (self.workspace_state) |*status| {
            status.deinit(self.allocator);
            self.workspace_state = null;
        }
        if (self.workspace_last_error) |value| {
            self.allocator.free(value);
            self.workspace_last_error = null;
        }
        self.workspace_last_refresh_ms = 0;
    }

    fn clearFilesystemEntries(self: *App) void {
        for (self.filesystem_entries.items) |*entry| entry.deinit(self.allocator);
        self.filesystem_entries.deinit(self.allocator);
        self.filesystem_entries = .{};
    }

    fn setFilesystemSelectedPath(self: *App, path: ?[]const u8) void {
        if (self.filesystem_selected_path) |value| {
            self.allocator.free(value);
            self.filesystem_selected_path = null;
        }
        if (path) |value| {
            self.filesystem_selected_path = self.allocator.dupe(u8, value) catch null;
        }
    }

    fn clearFilesystemPreviewState(self: *App) void {
        if (self.filesystem_preview_path) |value| {
            self.allocator.free(value);
            self.filesystem_preview_path = null;
        }
        if (self.filesystem_preview_text) |value| {
            self.allocator.free(value);
            self.filesystem_preview_text = null;
        }
        if (self.filesystem_preview_status) |value| {
            self.allocator.free(value);
            self.filesystem_preview_status = null;
        }
        self.filesystem_preview_mode = .empty;
        self.filesystem_preview_kind = .unknown;
        self.filesystem_preview_size_bytes = null;
        self.filesystem_preview_modified_unix_ms = null;
    }

    fn clearFilesystemData(self: *App) void {
        self.clearFilesystemEntries();
        self.setFilesystemSelectedPath(null);
        self.clearFilesystemPreviewState();
        self.filesystem_entry_page = 0;
        self.filesystem_last_clicked_entry_index = null;
        self.filesystem_last_click_ms = 0;
        if (self.filesystem_error) |value| {
            self.allocator.free(value);
            self.filesystem_error = null;
        }
    }

    fn clearContractServices(self: *App) void {
        for (self.contract_services.items) |*entry| entry.deinit(self.allocator);
        self.contract_services.deinit(self.allocator);
        self.contract_services = .{};
        self.contract_service_selected_index = 0;
    }

    fn setFilesystemError(self: *App, message: []const u8) void {
        if (self.filesystem_error) |value| {
            self.allocator.free(value);
            self.filesystem_error = null;
        }
        self.filesystem_error = self.allocator.dupe(u8, message) catch null;
    }

    fn clearFilesystemError(self: *App) void {
        if (self.filesystem_error) |value| {
            self.allocator.free(value);
            self.filesystem_error = null;
        }
    }

    fn setTerminalStatus(self: *App, message: []const u8) void {
        if (self.terminal_status) |value| {
            self.allocator.free(value);
            self.terminal_status = null;
        }
        self.terminal_status = self.allocator.dupe(u8, message) catch null;
    }

    fn clearTerminalStatus(self: *App) void {
        if (self.terminal_status) |value| {
            self.allocator.free(value);
            self.terminal_status = null;
        }
    }

    fn setTerminalError(self: *App, message: []const u8) void {
        if (self.terminal_error) |value| {
            self.allocator.free(value);
            self.terminal_error = null;
        }
        self.terminal_error = self.allocator.dupe(u8, message) catch null;
    }

    fn clearTerminalError(self: *App) void {
        if (self.terminal_error) |value| {
            self.allocator.free(value);
            self.terminal_error = null;
        }
    }

    fn clearTerminalState(self: *App) void {
        if (self.terminal_session_id) |value| {
            self.allocator.free(value);
            self.terminal_session_id = null;
        }
        self.terminal_next_poll_at_ms = 0;
        self.clearTerminalStatus();
        self.clearTerminalError();
    }

    fn applySelectedTerminalBackend(self: *App) void {
        const next_kind = self.settings_panel.terminal_backend_kind;
        if (self.terminal_backend_kind == next_kind) return;

        const snapshot = self.allocator.dupe(u8, self.terminal_backend.text()) catch null;
        defer if (snapshot) |value| self.allocator.free(value);

        self.terminal_backend.deinit(self.allocator);
        self.terminal_backend = initTerminalBackend(next_kind);
        self.terminal_backend_kind = next_kind;

        if (snapshot) |value| {
            _ = self.terminal_backend.appendBytes(self.allocator, value) catch {};
        }

        const status = std.fmt.allocPrint(
            self.allocator,
            "Terminal backend switched to {s}",
            .{terminal_render_backend.Backend.kindName(self.terminal_backend_kind)},
        ) catch null;
        defer if (status) |value| self.allocator.free(value);
        self.setTerminalStatus(status orelse "Terminal backend switched");
    }

    fn clearFilesystemDirCache(self: *App) void {
        var it = self.filesystem_dir_cache.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(self.allocator);
        }
        self.filesystem_dir_cache.deinit(self.allocator);
        self.filesystem_dir_cache = .{};
    }

    fn clearPendingFilesystemPathLoad(self: *App) void {
        if (self.filesystem_pending_path) |value| {
            self.allocator.free(value);
            self.filesystem_pending_path = null;
        }
        self.filesystem_pending_use_cache = false;
        self.filesystem_pending_force_refresh = false;
        self.filesystem_pending_retry_at_ms = 0;
    }

    fn schedulePendingFilesystemPathLoad(self: *App, path: []const u8, use_cache: bool, force_refresh: bool) void {
        self.clearPendingFilesystemPathLoad();
        self.filesystem_pending_path = self.allocator.dupe(u8, path) catch null;
        self.filesystem_pending_use_cache = use_cache;
        self.filesystem_pending_force_refresh = force_refresh;
        self.filesystem_pending_retry_at_ms = std.time.milliTimestamp() + 50;
    }

    fn requestFilesystemBrowserRefresh(self: *App, force_refresh: bool) void {
        const current_path = if (self.filesystem_path.items.len > 0) self.filesystem_path.items else "/";
        self.schedulePendingFilesystemPathLoad(current_path, false, force_refresh);
        self.filesystem_pending_retry_at_ms = 0;
        self.pollFilesystemWorker();
    }

    fn invalidateFilesystemDirCachePath(self: *App, path: []const u8) void {
        if (self.filesystem_dir_cache.fetchRemove(path)) |removed| {
            self.allocator.free(removed.key);
            var value = removed.value;
            value.deinit(self.allocator);
        }
    }

    fn putFilesystemDirCache(self: *App, path: []const u8, listing: []const u8) !void {
        if (self.filesystem_dir_cache.getEntry(path)) |entry| {
            entry.value_ptr.deinit(self.allocator);
            entry.value_ptr.* = .{
                .listing = try self.allocator.dupe(u8, listing),
                .cached_at_ms = std.time.milliTimestamp(),
            };
            return;
        }

        const key_copy = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(key_copy);
        try self.filesystem_dir_cache.put(self.allocator, key_copy, .{
            .listing = try self.allocator.dupe(u8, listing),
            .cached_at_ms = std.time.milliTimestamp(),
        });
    }

    fn cachedFilesystemListing(self: *App, path: []const u8) ?[]const u8 {
        const now_ms = std.time.milliTimestamp();
        if (self.filesystem_dir_cache.getEntry(path)) |entry| {
            if (now_ms - entry.value_ptr.cached_at_ms <= FILESYSTEM_DIR_CACHE_TTL_MS) {
                return entry.value_ptr.listing;
            }
        }
        self.invalidateFilesystemDirCachePath(path);
        return null;
    }

    fn startFilesystemWorker(
        self: *App,
        url: []const u8,
        token: []const u8,
        session_key: ?[]const u8,
        agent_id: ?[]const u8,
        project_id: ?[]const u8,
        project_token: ?[]const u8,
    ) !void {
        _ = url;
        _ = token;
        _ = session_key;
        _ = agent_id;
        _ = project_id;
        _ = project_token;
        self.stopFilesystemWorker();
        self.filesystem_busy = false;
        self.filesystem_active_request = null;
        self.clearFilesystemError();
    }

    fn stopFilesystemWorker(self: *App) void {
        self.filesystem_busy = false;
        self.filesystem_active_request = null;
    }

    fn resetFsrpcConnectionState(self: *App) void {
        self.fsrpc_ready = false;
        self.next_fsrpc_tag = 1;
        self.next_fsrpc_fid = 2;
        self.clearFsrpcRemoteError();
    }

    fn invalidateFsrpcAttachment(self: *App) void {
        self.fsrpc_ready = false;
        self.clearFsrpcRemoteError();
    }

    fn submitFilesystemRequest(
        self: *App,
        kind: FilesystemRequestKind,
        path: []const u8,
        open_after_resolve: bool,
    ) !void {
        return self.submitFilesystemRequestWithMode(kind, path, open_after_resolve, false);
    }

    fn submitFilesystemRequestWithMode(
        self: *App,
        kind: FilesystemRequestKind,
        path: []const u8,
        open_after_resolve: bool,
        is_background: bool,
    ) !void {
        if (is_background and (self.awaiting_reply or self.pending_send_job_id != null)) {
            return error.Busy;
        }
        if (self.filesystem_active_request != null) return error.Busy;
        const client = if (self.ws_client) |*value| value else return error.NotConnected;
        const request_id = self.filesystem_next_request_id;
        self.filesystem_next_request_id +%= 1;
        if (self.filesystem_next_request_id == 0) self.filesystem_next_request_id = 1;

        self.filesystem_active_request = .{
            .id = request_id,
            .kind = kind,
            .open_after_resolve = open_after_resolve,
            .is_background = is_background,
            .started_at_ms = std.time.milliTimestamp(),
        };
        if (!is_background) self.filesystem_busy = true;

        var request_completed = false;
        errdefer {
            if (!request_completed) {
                self.filesystem_active_request = null;
                if (!is_background) self.filesystem_busy = false;
            }
        }

        var result = try self.performFilesystemRequestSync(request_id, kind, path, client);
        defer result.deinit(self.allocator);
        self.handleFilesystemWorkerResult(&result);
        request_completed = true;
    }

    fn performFilesystemRequestSync(
        self: *App,
        request_id: u64,
        kind: FilesystemRequestKind,
        path: []const u8,
        client: *ws_client_mod.WebSocketClient,
    ) !FilesystemRequestResult {
        const path_copy = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(path_copy);

        self.clearFsrpcRemoteError();
        const result = switch (kind) {
            .list_dir => blk: {
                const listing = self.readFilesystemDirectoryGui(client, path) catch |err| {
                    break :blk try self.buildFilesystemRequestErrorResult(request_id, kind, path_copy, err);
                };
                break :blk FilesystemRequestResult{
                    .id = request_id,
                    .kind = kind,
                    .path = path_copy,
                    .listing = listing,
                };
            },
            .read_file => blk: {
                const content = self.readFilesystemFileGui(client, path) catch |err| {
                    break :blk try self.buildFilesystemRequestErrorResult(request_id, kind, path_copy, err);
                };
                break :blk FilesystemRequestResult{
                    .id = request_id,
                    .kind = kind,
                    .path = path_copy,
                    .content = content,
                };
            },
            .resolve_kind => blk: {
                const is_dir = self.resolveFilesystemPathIsDirGui(client, path) catch |err| {
                    break :blk try self.buildFilesystemRequestErrorResult(request_id, kind, path_copy, err);
                };
                break :blk FilesystemRequestResult{
                    .id = request_id,
                    .kind = kind,
                    .path = path_copy,
                    .is_dir = is_dir,
                };
            },
        };
        return result;
    }

    fn buildFilesystemRequestErrorResult(
        self: *App,
        request_id: u64,
        kind: FilesystemRequestKind,
        path: []u8,
        err: anyerror,
    ) !FilesystemRequestResult {
        const operation = switch (kind) {
            .list_dir => "list directory",
            .read_file => "read file",
            .resolve_kind => "resolve path kind",
        };
        const detail = self.formatFilesystemOpError(operation, err) orelse try self.allocator.dupe(u8, @errorName(err));
        return .{
            .id = request_id,
            .kind = kind,
            .path = path,
            .error_text = detail,
        };
    }

    fn readFilesystemDirectoryGui(
        self: *App,
        client: *ws_client_mod.WebSocketClient,
        path: []const u8,
    ) ![]u8 {
        try self.fsrpcBootstrapGui(client);
        const fid = try self.fsrpcWalkPathGui(client, path);
        defer self.fsrpcClunkBestEffort(client, fid);
        const is_dir = try self.fsrpcFidIsDirGui(client, fid);
        if (!is_dir) return error.NotDir;
        try self.fsrpcOpenGui(client, fid, "r");
        return self.fsrpcReadAllTextGui(client, fid);
    }

    fn readFilesystemFileGui(
        self: *App,
        client: *ws_client_mod.WebSocketClient,
        path: []const u8,
    ) ![]u8 {
        try self.fsrpcBootstrapGui(client);
        return self.readFsPathTextGui(client, path);
    }

    fn resolveFilesystemPathIsDirGui(
        self: *App,
        client: *ws_client_mod.WebSocketClient,
        path: []const u8,
    ) !bool {
        const stat = try self.resolveFilesystemPathStatGui(client, path);
        return stat.kind == .directory;
    }

    fn filesystemHiddenName(name: []const u8) bool {
        return name.len > 0 and name[0] == '.';
    }

    fn filesystemRuntimeNoiseName(name: []const u8) bool {
        inline for ([_][]const u8{
            "control",
            "status.json",
            "health.json",
            "metrics.json",
            "config.json",
            "invoke.json",
            "result.json",
            "schema.json",
            "template.json",
            "help.md",
        }) |candidate| {
            if (std.mem.eql(u8, name, candidate)) return true;
        }
        return false;
    }

    fn filesystemPreviewableName(name: []const u8, kind: FilesystemEntryKind) bool {
        if (kind == .directory) return false;
        const ext = std.fs.path.extension(name);
        if (ext.len == 0) return true;
        inline for ([_][]const u8{
            ".png", ".jpg",   ".jpeg", ".gif",   ".bmp", ".webp", ".ico",
            ".pdf", ".zip",   ".gz",   ".tar",   ".7z",  ".exe",  ".dll",
            ".so",  ".dylib", ".bin",  ".mp3",   ".wav", ".ogg",  ".mp4",
            ".mov", ".avi",   ".woff", ".woff2", ".ttf", ".otf",
        }) |blocked| {
            if (std.ascii.eqlIgnoreCase(ext, blocked)) return false;
        }
        return true;
    }

    fn allocFilesystemTypeLabel(self: *App, name: []const u8, kind: FilesystemEntryKind) ![]u8 {
        if (kind == .directory) return self.allocator.dupe(u8, "Folder");

        const ext = std.fs.path.extension(name);
        if (ext.len == 0) return self.allocator.dupe(u8, "File");

        const label = blk: {
            if (std.ascii.eqlIgnoreCase(ext, ".json")) break :blk "JSON";
            if (std.ascii.eqlIgnoreCase(ext, ".ndjson")) break :blk "NDJSON";
            if (std.ascii.eqlIgnoreCase(ext, ".jsonl")) break :blk "JSONL";
            if (std.ascii.eqlIgnoreCase(ext, ".md") or std.ascii.eqlIgnoreCase(ext, ".markdown")) break :blk "Markdown";
            if (std.ascii.eqlIgnoreCase(ext, ".txt")) break :blk "Text";
            if (std.ascii.eqlIgnoreCase(ext, ".log")) break :blk "Log";
            if (std.ascii.eqlIgnoreCase(ext, ".yaml") or std.ascii.eqlIgnoreCase(ext, ".yml")) break :blk "YAML";
            if (std.ascii.eqlIgnoreCase(ext, ".toml")) break :blk "TOML";
            if (std.ascii.eqlIgnoreCase(ext, ".cfg") or std.ascii.eqlIgnoreCase(ext, ".conf") or std.ascii.eqlIgnoreCase(ext, ".ini")) break :blk "Config";
            if (std.ascii.eqlIgnoreCase(ext, ".zig")) break :blk "Zig";
            if (std.ascii.eqlIgnoreCase(ext, ".ts")) break :blk "TypeScript";
            if (std.ascii.eqlIgnoreCase(ext, ".js")) break :blk "JavaScript";
            if (std.ascii.eqlIgnoreCase(ext, ".html")) break :blk "HTML";
            if (std.ascii.eqlIgnoreCase(ext, ".css")) break :blk "CSS";
            if (std.ascii.eqlIgnoreCase(ext, ".sh")) break :blk "Shell";
            if (std.ascii.eqlIgnoreCase(ext, ".ps1")) break :blk "PowerShell";
            break :blk ext[1..];
        };
        return self.allocator.dupe(u8, label);
    }

    fn findFilesystemEntryByPath(self: *App, path: []const u8) ?*FilesystemEntry {
        for (self.filesystem_entries.items) |*entry| {
            if (std.mem.eql(u8, entry.path, path)) return entry;
        }
        return null;
    }

    fn selectedFilesystemEntry(self: *App) ?*FilesystemEntry {
        const selected = self.filesystem_selected_path orelse return null;
        return self.findFilesystemEntryByPath(selected);
    }

    fn truncateFilesystemPreviewText(self: *App, content: []const u8) ![]u8 {
        if (content.len > FILESYSTEM_PREVIEW_MAX_BYTES) {
            const suffix = "\n... (truncated)";
            const limit = FILESYSTEM_PREVIEW_MAX_BYTES;
            const buf = try self.allocator.alloc(u8, limit + suffix.len);
            @memcpy(buf[0..limit], content[0..limit]);
            @memcpy(buf[limit .. limit + suffix.len], suffix);
            return buf;
        }
        return self.allocator.dupe(u8, content);
    }

    fn filesystemContentLooksText(content: []const u8) bool {
        const scan_len = @min(content.len, FILESYSTEM_PREVIEW_TEXT_SCAN_BYTES);
        var idx: usize = 0;
        var suspicious: usize = 0;
        while (idx < scan_len) : (idx += 1) {
            const ch = content[idx];
            if (ch == 0) return false;
            if (ch < 0x09) {
                suspicious += 1;
                continue;
            }
            if (ch > 0x0D and ch < 0x20) suspicious += 1;
        }
        return suspicious * 8 < @max(scan_len, 1);
    }

    fn inferFilesystemPreviewMode(path: []const u8, content: []const u8) FilesystemPreviewMode {
        if (content.len == 0) return .empty;
        if (!filesystemContentLooksText(content)) return .unsupported;

        const ext = std.fs.path.extension(path);
        if (std.ascii.eqlIgnoreCase(ext, ".json") or std.ascii.eqlIgnoreCase(ext, ".ndjson") or std.ascii.eqlIgnoreCase(ext, ".jsonl")) {
            return .json;
        }

        const trimmed = std.mem.trim(u8, content, " \t\r\n");
        if (trimmed.len > 0 and (trimmed[0] == '{' or trimmed[0] == '[')) return .json;
        return .text;
    }

    fn setFilesystemPreviewPlaceholder(
        self: *App,
        path: []const u8,
        kind: FilesystemEntryKind,
        size_bytes: ?u64,
        modified_unix_ms: ?i64,
        mode: FilesystemPreviewMode,
        status: []const u8,
    ) !void {
        self.clearFilesystemPreviewState();
        self.filesystem_preview_path = try self.allocator.dupe(u8, path);
        self.filesystem_preview_kind = kind;
        self.filesystem_preview_size_bytes = size_bytes;
        self.filesystem_preview_modified_unix_ms = modified_unix_ms;
        self.filesystem_preview_mode = mode;
        self.filesystem_preview_status = try self.allocator.dupe(u8, status);
    }

    fn refreshSelectedFilesystemPreview(self: *App) !void {
        const entry = self.selectedFilesystemEntry() orelse {
            self.clearFilesystemPreviewState();
            return;
        };

        switch (entry.kind) {
            .directory => try self.setFilesystemPreviewPlaceholder(
                entry.path,
                entry.kind,
                entry.size_bytes,
                entry.modified_unix_ms,
                .empty,
                "Directory selected. Use Open Selected or double-click to browse.",
            ),
            .file => {
                if (!entry.previewable) {
                    try self.setFilesystemPreviewPlaceholder(
                        entry.path,
                        entry.kind,
                        entry.size_bytes,
                        entry.modified_unix_ms,
                        .unsupported,
                        "Preview unavailable for this file type.",
                    );
                    return;
                }
                try self.setFilesystemPreviewPlaceholder(
                    entry.path,
                    entry.kind,
                    entry.size_bytes,
                    entry.modified_unix_ms,
                    .loading,
                    "Loading preview…",
                );
                try self.submitFilesystemRequest(.read_file, entry.path, false);
            },
            .unknown => {
                try self.setFilesystemPreviewPlaceholder(
                    entry.path,
                    entry.kind,
                    entry.size_bytes,
                    entry.modified_unix_ms,
                    .loading,
                    "Resolving filesystem entry…",
                );
                try self.submitFilesystemRequest(.resolve_kind, entry.path, false);
            },
        }
    }

    fn applyFilesystemListing(self: *App, path: []const u8, listing: []const u8) !void {
        const previous_selected_path = if (self.filesystem_selected_path) |value|
            self.allocator.dupe(u8, value) catch null
        else
            null;
        defer if (previous_selected_path) |value| self.allocator.free(value);

        self.clearFilesystemData();
        try self.setFilesystemPath(path);
        var iter = std.mem.splitScalar(u8, listing, '\n');
        while (iter.next()) |raw| {
            const entry_name = std.mem.trim(u8, raw, " \t\r\n");
            if (entry_name.len == 0) continue;
            if (std.mem.eql(u8, entry_name, ".") or std.mem.eql(u8, entry_name, "..")) continue;

            const child_path = try self.joinFilesystemPath(path, entry_name);
            errdefer self.allocator.free(child_path);

            var entry = FilesystemEntry{
                .name = try self.allocator.dupe(u8, entry_name),
                .path = child_path,
                .kind = .unknown,
                .type_label = try self.allocFilesystemTypeLabel(entry_name, .unknown),
                .hidden = filesystemHiddenName(entry_name),
                .previewable = filesystemPreviewableName(entry_name, .unknown),
                .runtime_noise = filesystemRuntimeNoiseName(entry_name),
            };
            errdefer entry.deinit(self.allocator);

            if (self.ws_client) |*client| {
                const stat = self.resolveFilesystemPathStatGui(client, entry.path) catch null;
                if (stat) |value| {
                    entry.kind = value.kind;
                    entry.size_bytes = value.size_bytes;
                    entry.modified_unix_ms = value.modified_unix_ms;
                    self.allocator.free(entry.type_label);
                    entry.type_label = try self.allocFilesystemTypeLabel(entry.name, value.kind);
                    entry.previewable = filesystemPreviewableName(entry.name, value.kind);
                }
            }

            try self.filesystem_entries.append(self.allocator, entry);
        }

        if (previous_selected_path) |selected_path| {
            if (self.findFilesystemEntryByPath(selected_path) != null) {
                self.setFilesystemSelectedPath(selected_path);
                self.refreshSelectedFilesystemPreview() catch {};
            }
        }
    }

    fn applyFilesystemPreview(self: *App, path: []const u8, content: []const u8) !void {
        self.clearFilesystemPreviewState();
        self.filesystem_preview_path = try self.allocator.dupe(u8, path);

        if (self.findFilesystemEntryByPath(path)) |entry| {
            self.filesystem_preview_kind = entry.kind;
            self.filesystem_preview_size_bytes = entry.size_bytes orelse content.len;
            self.filesystem_preview_modified_unix_ms = entry.modified_unix_ms;
        } else {
            self.filesystem_preview_kind = .file;
            self.filesystem_preview_size_bytes = content.len;
        }

        const preview_mode = inferFilesystemPreviewMode(path, content);
        self.filesystem_preview_mode = preview_mode;
        switch (preview_mode) {
            .text => {
                self.filesystem_preview_status = try self.allocator.dupe(u8, "Text preview");
                self.filesystem_preview_text = try self.truncateFilesystemPreviewText(content);
            },
            .json => {
                self.filesystem_preview_status = try self.allocator.dupe(u8, "JSON preview");
                self.filesystem_preview_text = try self.truncateFilesystemPreviewText(content);
            },
            .empty => {
                self.filesystem_preview_status = try self.allocator.dupe(u8, "Empty file");
            },
            .unsupported => {
                self.filesystem_preview_status = try self.allocator.dupe(u8, "Preview unavailable for binary or unsupported content.");
            },
            .loading => {},
        }
    }

    fn setFsrpcRemoteError(self: *App, message: []const u8) void {
        self.clearFsrpcRemoteError();
        self.fsrpc_last_remote_error = self.allocator.dupe(u8, message) catch null;
    }

    fn clearFsrpcRemoteError(self: *App) void {
        if (self.fsrpc_last_remote_error) |value| {
            self.allocator.free(value);
            self.fsrpc_last_remote_error = null;
        }
    }

    fn formatFilesystemOpError(self: *App, operation: []const u8, err: anyerror) ?[]u8 {
        if (err == error.RemoteError or err == error.RuntimeWarming) {
            if (self.fsrpc_last_remote_error) |remote| {
                return std.fmt.allocPrint(self.allocator, "{s}: {s}", .{ operation, remote }) catch null;
            }
        }
        return std.fmt.allocPrint(self.allocator, "{s}: {s}", .{ operation, @errorName(err) }) catch null;
    }

    fn controlAuthHintForRemote(self: *App, remote: []const u8) ?[]u8 {
        if (std.mem.indexOf(u8, remote, "project_auth_failed") != null) {
            return self.allocator.dupe(
                u8,
                "Project access denied. If the project is locked, provide its Project Token.",
            ) catch null;
        }
        if (std.mem.indexOf(u8, remote, "project_not_found") != null) {
            return self.allocator.dupe(
                u8,
                "Selected project no longer exists. Clear project selection and reconnect.",
            ) catch null;
        }
        if (std.mem.indexOf(u8, remote, "project_assignment_forbidden") != null) {
            return self.allocator.dupe(
                u8,
                "This agent is not allowed on that project (system project is Mother-only).",
            ) catch null;
        }
        if (std.mem.indexOf(u8, remote, "control_plane_error") != null and
            std.mem.indexOf(u8, remote, "SyntaxError") != null)
        {
            return self.allocator.dupe(
                u8,
                "Selected project settings are invalid for this server. Clear project/token in Settings and retry.",
            ) catch null;
        }
        if (std.mem.indexOf(u8, remote, "provisioning_required") != null) {
            return self.allocator.dupe(
                u8,
                "This user token has no non-system project/agent target. Ask an admin to provision one via Mother.",
            ) catch null;
        }
        if (std.mem.indexOf(u8, remote, "last_target_invalid") != null) {
            return self.allocator.dupe(
                u8,
                "The remembered project/agent target is no longer valid. Ask an admin to re-provision access.",
            ) catch null;
        }
        return null;
    }

    fn nodeWatchHintForRemote(self: *App, remote: []const u8) ?[]u8 {
        if (std.mem.indexOf(u8, remote, "disabled for user role") != null) {
            return self.allocator.dupe(
                u8,
                "User watch is disabled server-side. Ask admin to enable SPIDERWEB_NODE_SERVICE_WATCH_ALLOW_USER.",
            ) catch null;
        }
        if (std.mem.indexOf(u8, remote, "disabled for admin role") != null) {
            return self.allocator.dupe(
                u8,
                "Admin watch is disabled server-side. Check SPIDERWEB_NODE_SERVICE_WATCH_ALLOW_ADMIN.",
            ) catch null;
        }
        if (std.mem.indexOf(u8, remote, "observe access denied for active project") != null) {
            return self.allocator.dupe(
                u8,
                "Project observe policy denied this stream. Check access_policy.actions.observe and agent overrides.",
            ) catch null;
        }
        if (std.mem.indexOf(u8, remote, "watch requires a project-scoped session binding") != null) {
            return self.allocator.dupe(
                u8,
                "Attach the session to a project first (project selection + reconnect/session attach).",
            ) catch null;
        }
        if (std.mem.indexOf(u8, remote, "forbidden") != null) {
            return self.allocator.dupe(
                u8,
                "Watch access is policy-gated for your role/session.",
            ) catch null;
        }
        return null;
    }

    fn formatControlRemoteMessage(self: *App, operation: []const u8, remote: []const u8) ?[]u8 {
        const hint = self.controlAuthHintForRemote(remote);
        defer if (hint) |value| self.allocator.free(value);
        if (hint) |value| {
            return std.fmt.allocPrint(self.allocator, "{s}: {s} {s}", .{ operation, remote, value }) catch null;
        }
        return std.fmt.allocPrint(self.allocator, "{s}: {s}", .{ operation, remote }) catch null;
    }

    fn formatControlOpError(self: *App, operation: []const u8, err: anyerror) ?[]u8 {
        if (err == error.RemoteError) {
            if (control_plane.lastRemoteError()) |remote| {
                return self.formatControlRemoteMessage(operation, remote);
            }
        }
        return std.fmt.allocPrint(self.allocator, "{s}: {s}", .{ operation, @errorName(err) }) catch null;
    }

    fn isProjectAuthRemoteError(remote: []const u8) bool {
        return std.mem.indexOf(u8, remote, "project_auth_failed") != null or
            std.mem.indexOf(u8, remote, "ProjectAuthFailed") != null;
    }

    fn isSelectedProjectAttachRemoteError(remote: []const u8) bool {
        if (isProjectAuthRemoteError(remote)) return true;
        if (std.mem.indexOf(u8, remote, "project_not_found") != null) return true;
        if (std.mem.indexOf(u8, remote, "project_assignment_forbidden") != null) return true;
        if (std.mem.indexOf(u8, remote, "invalid project_id") != null) return true;
        if (std.mem.indexOf(u8, remote, "project_id is required") != null) return true;
        if (std.mem.indexOf(u8, remote, "invalid_payload") != null and
            std.mem.indexOf(u8, remote, "project_id") != null)
        {
            return true;
        }
        if (std.mem.indexOf(u8, remote, "control_plane_error") != null and
            std.mem.indexOf(u8, remote, "SyntaxError") != null)
        {
            return true;
        }
        return false;
    }

    fn isTokenAuthRemoteError(remote: []const u8) bool {
        return std.mem.indexOf(u8, remote, "auth_failed") != null or
            std.mem.indexOf(u8, remote, "auth_required") != null or
            std.mem.indexOf(u8, remote, "invalid token") != null or
            std.mem.indexOf(u8, remote, "invalid_token") != null or
            std.mem.indexOf(u8, remote, "unauthorized") != null or
            std.mem.indexOf(u8, remote, "forbidden") != null;
    }

    fn isProvisioningRemoteError(remote: []const u8) bool {
        return std.mem.indexOf(u8, remote, "provisioning_required") != null or
            std.mem.indexOf(u8, remote, "last_target_invalid") != null;
    }

    fn disableAutoConnectAfterAuthFailure(self: *App) void {
        if (!self.settings_panel.auto_connect_on_launch and !self.config.auto_connect_on_launch) return;
        self.settings_panel.auto_connect_on_launch = false;
        self.config.auto_connect_on_launch = false;
        self.config.save() catch |err| {
            std.log.warn("Failed to persist auto-connect disable after auth failure: {s}", .{@errorName(err)});
        };
    }

    fn clearSelectedProjectAfterAttachFailure(self: *App) void {
        self.settings_panel.project_id.clearRetainingCapacity();
        self.settings_panel.project_token.clearRetainingCapacity();
        self.session_attach_state = .unknown;
        self.syncSettingsToConfig() catch |err| {
            std.log.warn("Failed to persist cleared selected project after attach failure: {s}", .{@errorName(err)});
        };
    }

    fn setWorkspaceError(self: *App, message: []const u8) void {
        if (self.workspace_last_error) |value| {
            self.allocator.free(value);
            self.workspace_last_error = null;
        }
        self.workspace_last_error = self.allocator.dupe(u8, message) catch null;
    }

    fn clearWorkspaceError(self: *App) void {
        if (self.workspace_last_error) |value| {
            self.allocator.free(value);
            self.workspace_last_error = null;
        }
    }

    fn clearConnectSetupHint(self: *App) void {
        if (self.connect_setup_hint) |*hint| {
            hint.deinit(self.allocator);
            self.connect_setup_hint = null;
        }
    }

    fn applyConnectSetupHintFromPayload(self: *App, payload_json: []const u8) !void {
        var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, payload_json, .{});
        defer parsed.deinit();
        if (parsed.value != .object) return error.InvalidResponse;
        const root = parsed.value.object;

        var hint = ConnectSetupHint{};
        errdefer hint.deinit(self.allocator);

        if (root.get("project_setup_required")) |value| {
            if (value != .bool) return error.InvalidResponse;
            hint.required = value.bool;
        } else if (root.get("bootstrap_only")) |value| {
            if (value != .bool) return error.InvalidResponse;
            hint.required = value.bool;
        }

        if (root.get("project_setup_message")) |value| {
            switch (value) {
                .string => hint.message = try self.allocator.dupe(u8, value.string),
                .null => {},
                else => return error.InvalidResponse,
            }
        } else if (root.get("bootstrap_message")) |value| {
            switch (value) {
                .string => hint.message = try self.allocator.dupe(u8, value.string),
                .null => {},
                else => return error.InvalidResponse,
            }
        }

        if (root.get("project_setup_project_id")) |value| {
            switch (value) {
                .string => hint.project_id = try self.allocator.dupe(u8, value.string),
                .null => {},
                else => return error.InvalidResponse,
            }
        } else if (root.get("project_id")) |value| {
            switch (value) {
                .string => hint.project_id = try self.allocator.dupe(u8, value.string),
                .null => {},
                else => return error.InvalidResponse,
            }
        }

        if (root.get("project_setup_project_vision")) |value| {
            switch (value) {
                .string => hint.project_vision = try self.allocator.dupe(u8, value.string),
                .null => {},
                else => return error.InvalidResponse,
            }
        }

        self.clearConnectSetupHint();
        self.connect_setup_hint = hint;
    }

    fn selectedProjectId(self: *const App) ?[]const u8 {
        if (self.settings_panel.project_id.items.len > 0) return self.settings_panel.project_id.items;
        return self.config.selectedProject();
    }

    fn defaultAttachProjectId(self: *const App) ?[]const u8 {
        if (self.connect_setup_hint) |hint| {
            if (hint.project_id) |project_id| {
                if (project_id.len > 0) return project_id;
            }
        }
        if (self.config.active_role == .admin) return "system";
        return null;
    }

    fn preferredAttachProjectId(self: *const App) ?[]const u8 {
        if (self.selectedProjectId()) |project_id| return project_id;
        return self.defaultAttachProjectId();
    }

    fn selectedProjectSummary(self: *const App) ?*const workspace_types.ProjectSummary {
        const project_id = self.selectedProjectId() orelse return null;
        for (self.projects.items) |*project| {
            if (std.mem.eql(u8, project.id, project_id)) return project;
        }
        return null;
    }

    fn selectedProjectTokenLocked(self: *const App) ?bool {
        const project = self.selectedProjectSummary() orelse return null;
        return project.token_locked;
    }

    fn ensureSelectedProjectInSettings(self: *App, project_id: []const u8) !void {
        if (self.settings_panel.project_id.items.len > 0 and
            std.mem.eql(u8, self.settings_panel.project_id.items, project_id))
        {
            return;
        }
        self.settings_panel.project_id.clearRetainingCapacity();
        try self.settings_panel.project_id.appendSlice(self.allocator, project_id);
    }

    fn selectProjectInSettings(self: *App, project_id: []const u8) !void {
        self.settings_panel.project_id.clearRetainingCapacity();
        try self.settings_panel.project_id.appendSlice(self.allocator, project_id);
        self.project_selector_open = false;
        self.settings_panel.project_token.clearRetainingCapacity();
        if (!isSystemProjectId(project_id)) {
            if (self.config.getProjectToken(project_id)) |token| {
                try self.settings_panel.project_token.appendSlice(self.allocator, token);
            }
        }
        self.session_attach_state = .unknown;
        try self.syncSettingsToConfig();
    }

    fn refreshWorkspaceData(self: *App) !void {
        const client = if (self.ws_client) |*value| value else return error.NotConnected;
        try control_plane.ensureUnifiedV2Connection(self.allocator, client, &self.message_counter);

        var projects = try control_plane.listProjects(self.allocator, client, &self.message_counter);
        errdefer workspace_types.deinitProjectList(self.allocator, &projects);
        var nodes = try control_plane.listNodes(self.allocator, client, &self.message_counter);
        errdefer workspace_types.deinitNodeList(self.allocator, &nodes);
        const selected_project_id = self.selectedProjectId();
        const selected_project_token = if (selected_project_id) |project_id|
            self.selectedProjectToken(project_id)
        else
            null;

        var selected_project_warning: ?[]u8 = null;
        defer if (selected_project_warning) |value| self.allocator.free(value);

        var workspace_status = control_plane.workspaceStatus(
            self.allocator,
            client,
            &self.message_counter,
            selected_project_id,
            selected_project_token,
        ) catch |err| blk: {
            if (selected_project_id != null and err == error.RemoteError) {
                if (control_plane.lastRemoteError()) |remote| {
                    if (isSelectedProjectAttachRemoteError(remote)) {
                        self.clearSelectedProjectAfterAttachFailure();
                    }
                    selected_project_warning = self.formatControlRemoteMessage("Selected project unavailable", remote);
                } else {
                    selected_project_warning = std.fmt.allocPrint(self.allocator, "Selected project unavailable: {s}", .{@errorName(err)}) catch null;
                }
                break :blk try control_plane.workspaceStatus(
                    self.allocator,
                    client,
                    &self.message_counter,
                    null,
                    null,
                );
            }
            return err;
        };
        errdefer workspace_status.deinit(self.allocator);

        workspace_types.deinitProjectList(self.allocator, &self.projects);
        workspace_types.deinitNodeList(self.allocator, &self.nodes);
        if (self.workspace_state) |*status| status.deinit(self.allocator);

        self.projects = projects;
        self.nodes = nodes;
        self.workspace_state = workspace_status;
        self.workspace_last_refresh_ms = std.time.milliTimestamp();
        if (selected_project_warning) |message| {
            self.setWorkspaceError(message);
        } else {
            self.clearWorkspaceError();
        }
    }

    fn activateSelectedProject(self: *App) !void {
        const client = if (self.ws_client) |*value| value else return error.NotConnected;
        const project_id = self.selectedProjectId() orelse return error.MissingField;

        const token = self.selectedProjectToken(project_id);

        var status = try control_plane.activateProject(
            self.allocator,
            client,
            &self.message_counter,
            project_id,
            token,
        );
        errdefer status.deinit(self.allocator);

        if (self.workspace_state) |*existing| existing.deinit(self.allocator);
        self.workspace_state = status;
        self.workspace_last_refresh_ms = std.time.milliTimestamp();
        self.clearWorkspaceError();
        self.session_attach_state = .unknown;

        if (self.settings_panel.project_token.items.len == 0) {
            if (token) |value| {
                try self.settings_panel.project_token.appendSlice(self.allocator, value);
            }
        }
        try self.syncSettingsToConfig();
    }

    fn resolveProjectOperatorToken(self: *App) ?[]const u8 {
        if (self.settings_panel.project_operator_token.items.len > 0) return self.settings_panel.project_operator_token.items;
        if (self.config.getRoleToken(.admin).len > 0) return self.config.getRoleToken(.admin);
        return null;
    }

    fn setRoleToken(
        self: *App,
        role: config_mod.Config.TokenRole,
        token: []const u8,
        set_active: bool,
    ) !void {
        if (role == .admin) {
            self.settings_panel.project_operator_token.clearRetainingCapacity();
            if (token.len > 0) {
                try self.settings_panel.project_operator_token.appendSlice(self.allocator, token);
            }
        }
        try self.config.setRoleToken(role, token);
        if (set_active) try self.config.setActiveRole(role);
        const profile_id = self.config.selectedProfileId();
        const key = switch (role) {
            .admin => "role_admin",
            .user => "role_user",
        };
        if (token.len > 0) {
            self.credential_store.save(profile_id, key, token) catch |err| {
                std.log.warn("Failed to persist credential in store: {s}", .{@errorName(err)});
            };
        } else {
            self.credential_store.delete(profile_id, key) catch {};
        }
        try self.config.save();
    }

    fn setOperatorToken(self: *App, token: []const u8) !void {
        try self.setRoleToken(.admin, token, true);
    }

    fn setUserToken(self: *App, token: []const u8) !void {
        try self.setRoleToken(.user, token, false);
    }

    fn syncLauncherConnectTokenFromConfig(self: *App) !void {
        self.launcher_connect_token.clearRetainingCapacity();
        const token = self.config.getRoleToken(self.config.active_role);
        if (token.len > 0) {
            try self.launcher_connect_token.appendSlice(self.allocator, token);
        }
    }

    fn persistLauncherConnectToken(self: *App) !void {
        const token = std.mem.trim(u8, self.launcher_connect_token.items, " \t\r\n");
        try self.setRoleToken(self.config.active_role, token, false);
    }

    fn activeRoleLabel(self: *const App) []const u8 {
        return if (self.config.active_role == .admin) "Admin" else "User";
    }

    fn setActiveConnectRole(self: *App, role: config_mod.Config.TokenRole) !void {
        if (self.config.active_role == role) return;
        try self.config.setActiveRole(role);
        try self.config.save();
        try self.syncLauncherConnectTokenFromConfig();

        const role_name = if (role == .admin) "admin" else "user";
        const status = if (self.connection_state == .connected)
            try std.fmt.allocPrint(
                self.allocator,
                "Connect role set to {s}; reconnect to apply.",
                .{role_name},
            )
        else
            try std.fmt.allocPrint(
                self.allocator,
                "Connect role set to {s}.",
                .{role_name},
            );
        defer self.allocator.free(status);
        self.setConnectionState(self.connection_state, status);
    }

    fn parseRequiredTokenField(self: *App, payload_json: []const u8) ![]u8 {
        var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, payload_json, .{});
        defer parsed.deinit();
        if (parsed.value != .object) return error.InvalidResponse;
        const token_val = parsed.value.object.get("token") orelse return error.InvalidResponse;
        if (token_val != .string or token_val.string.len == 0) return error.InvalidResponse;
        return self.allocator.dupe(u8, token_val.string);
    }

    fn requestAuthStatusSnapshot(self: *App) !AuthStatusSnapshot {
        const client = if (self.ws_client) |*value| value else return error.NotConnected;
        try control_plane.ensureUnifiedV2Connection(self.allocator, client, &self.message_counter);

        const payload_json = try control_plane.requestControlPayloadJson(
            self.allocator,
            client,
            &self.message_counter,
            "control.auth_status",
            null,
        );
        defer self.allocator.free(payload_json);

        var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, payload_json, .{});
        defer parsed.deinit();
        if (parsed.value != .object) return error.InvalidResponse;
        const root = parsed.value.object;

        const admin_value = root.get("admin_token") orelse return error.InvalidResponse;
        if (admin_value != .string) return error.InvalidResponse;
        const user_value = root.get("user_token") orelse return error.InvalidResponse;
        if (user_value != .string) return error.InvalidResponse;

        return .{
            .admin_token = try self.allocator.dupe(u8, admin_value.string),
            .user_token = try self.allocator.dupe(u8, user_value.string),
            .path = if (root.get("path")) |value| switch (value) {
                .string => try self.allocator.dupe(u8, value.string),
                .null => null,
                else => return error.InvalidResponse,
            } else null,
        };
    }

    fn authSnapshotRoleToken(snapshot: *const AuthStatusSnapshot, role: []const u8) ![]const u8 {
        if (std.mem.eql(u8, role, "admin")) return snapshot.admin_token;
        if (std.mem.eql(u8, role, "user")) return snapshot.user_token;
        return error.InvalidArguments;
    }

    fn copyTextToClipboard(self: *App, text: []const u8) !void {
        if (text.len == 0) return;
        const buf = try self.allocator.alloc(u8, text.len + 1);
        defer self.allocator.free(buf);
        @memcpy(buf[0..text.len], text);
        buf[text.len] = 0;
        const zslice: [:0]const u8 = buf[0..text.len :0];
        zapp.clipboard.setTextZ(zslice);
    }

    fn fetchAuthStatusFromPanel(self: *App, reveal_tokens: bool) !void {
        var snapshot = try self.requestAuthStatusSnapshot();
        defer snapshot.deinit(self.allocator);

        const admin_display_owned = if (reveal_tokens)
            null
        else
            try maskTokenForDisplay(self.allocator, snapshot.admin_token);
        defer if (admin_display_owned) |value| self.allocator.free(value);
        const user_display_owned = if (reveal_tokens)
            null
        else
            try maskTokenForDisplay(self.allocator, snapshot.user_token);
        defer if (user_display_owned) |value| self.allocator.free(value);
        const admin_display = if (admin_display_owned) |value| value else snapshot.admin_token;
        const user_display = if (user_display_owned) |value| value else snapshot.user_token;
        const path = snapshot.path orelse "(none)";

        const msg = try std.fmt.allocPrint(
            self.allocator,
            "Auth status: admin={s} user={s} path={s}{s}",
            .{
                admin_display,
                user_display,
                path,
                if (reveal_tokens) "" else " (masked; use reveal/copy buttons for full token)",
            },
        );
        defer self.allocator.free(msg);
        try self.appendMessage("system", msg, null);
    }

    fn revealAuthTokenFromPanel(self: *App, role: []const u8) !void {
        var snapshot = try self.requestAuthStatusSnapshot();
        defer snapshot.deinit(self.allocator);
        const token = try authSnapshotRoleToken(&snapshot, role);
        const msg = try std.fmt.allocPrint(self.allocator, "Auth {s} token: {s}", .{ role, token });
        defer self.allocator.free(msg);
        try self.appendMessage("system", msg, null);
    }

    fn copyAuthTokenFromPanel(self: *App, role: []const u8) !void {
        var snapshot = try self.requestAuthStatusSnapshot();
        defer snapshot.deinit(self.allocator);
        const token = try authSnapshotRoleToken(&snapshot, role);
        try self.copyTextToClipboard(token);
        const msg = try std.fmt.allocPrint(self.allocator, "Copied auth {s} token to clipboard", .{role});
        defer self.allocator.free(msg);
        try self.appendMessage("system", msg, null);
    }

    fn rotateAuthTokenFromPanel(self: *App, role: []const u8) !void {
        if (!std.mem.eql(u8, role, "admin") and !std.mem.eql(u8, role, "user")) {
            return error.InvalidArguments;
        }

        const client = if (self.ws_client) |*value| value else return error.NotConnected;
        try control_plane.ensureUnifiedV2Connection(self.allocator, client, &self.message_counter);

        const escaped_role = try jsonEscape(self.allocator, role);
        defer self.allocator.free(escaped_role);
        const payload = try std.fmt.allocPrint(self.allocator, "{{\"role\":\"{s}\"}}", .{escaped_role});
        defer self.allocator.free(payload);

        const response_json = try control_plane.requestControlPayloadJson(
            self.allocator,
            client,
            &self.message_counter,
            "control.auth_rotate",
            payload,
        );
        defer self.allocator.free(response_json);

        const token = try self.parseRequiredTokenField(response_json);
        defer self.allocator.free(token);

        const masked = try maskTokenForDisplay(self.allocator, token);
        defer self.allocator.free(masked);
        if (std.mem.eql(u8, role, "admin")) {
            try self.setOperatorToken(token);
            const msg = try std.fmt.allocPrint(
                self.allocator,
                "Rotated admin token: {s} (saved; use reveal/copy buttons for full token)",
                .{masked},
            );
            defer self.allocator.free(msg);
            try self.appendMessage("system", msg, null);
            return;
        }

        try self.setUserToken(token);
        const msg = try std.fmt.allocPrint(
            self.allocator,
            "Rotated user token: {s} (saved; use reveal/copy buttons for full token)",
            .{masked},
        );
        defer self.allocator.free(msg);
        try self.appendMessage("system", msg, null);
    }

    fn createProjectFromPanel(self: *App) !void {
        const client = if (self.ws_client) |*value| value else return error.NotConnected;
        if (self.settings_panel.project_create_name.items.len == 0) return error.MissingField;
        try control_plane.ensureUnifiedV2Connection(self.allocator, client, &self.message_counter);

        const vision = if (self.settings_panel.project_create_vision.items.len > 0)
            self.settings_panel.project_create_vision.items
        else
            null;
        var created = try control_plane.createProject(
            self.allocator,
            client,
            &self.message_counter,
            self.settings_panel.project_create_name.items,
            vision,
            self.resolveProjectOperatorToken(),
        );
        defer created.deinit(self.allocator);

        self.settings_panel.project_id.clearRetainingCapacity();
        try self.settings_panel.project_id.appendSlice(self.allocator, created.id);
        self.settings_panel.project_token.clearRetainingCapacity();
        if (created.project_token) |token| {
            try self.settings_panel.project_token.appendSlice(self.allocator, token);
        }
        try self.syncSettingsToConfig();
        self.settings_panel.project_create_name.clearRetainingCapacity();
        self.refreshWorkspaceData() catch {};
        self.clearWorkspaceError();
    }

    fn lockSelectedProjectFromPanel(self: *App) !void {
        const client = if (self.ws_client) |*value| value else return error.NotConnected;
        const project_id = self.selectedProjectId() orelse return error.MissingField;
        const current_token = self.selectedProjectToken(project_id);
        try control_plane.ensureUnifiedV2Connection(self.allocator, client, &self.message_counter);

        var result = try control_plane.rotateProjectToken(
            self.allocator,
            client,
            &self.message_counter,
            project_id,
            current_token,
        );
        defer result.deinit(self.allocator);

        const next_token = result.project_token orelse return error.InvalidResponse;
        try self.ensureSelectedProjectInSettings(project_id);
        self.settings_panel.project_token.clearRetainingCapacity();
        try self.settings_panel.project_token.appendSlice(self.allocator, next_token);
        try self.syncSettingsToConfig();

        self.refreshWorkspaceData() catch {};
        self.clearWorkspaceError();
    }

    fn unlockSelectedProjectFromPanel(self: *App) !void {
        const client = if (self.ws_client) |*value| value else return error.NotConnected;
        const project_id = self.selectedProjectId() orelse return error.MissingField;
        const current_token = self.selectedProjectToken(project_id);
        try control_plane.ensureUnifiedV2Connection(self.allocator, client, &self.message_counter);

        var result = try control_plane.revokeProjectToken(
            self.allocator,
            client,
            &self.message_counter,
            project_id,
            current_token,
        );
        defer result.deinit(self.allocator);

        try self.ensureSelectedProjectInSettings(project_id);
        self.settings_panel.project_token.clearRetainingCapacity();
        try self.syncSettingsToConfig();

        self.refreshWorkspaceData() catch {};
        self.clearWorkspaceError();
    }

    fn setProjectMountFromPanel(self: *App) !void {
        const client = if (self.ws_client) |*value| value else return error.NotConnected;
        const project_id = self.selectedProjectId() orelse return error.MissingField;
        const project_token = self.selectedProjectToken(project_id);
        const mount_path = std.mem.trim(u8, self.settings_panel.project_mount_path.items, " \t");
        const node_id = std.mem.trim(u8, self.settings_panel.project_mount_node_id.items, " \t");
        const export_name = std.mem.trim(u8, self.settings_panel.project_mount_export_name.items, " \t");
        if (mount_path.len == 0 or node_id.len == 0 or export_name.len == 0) return error.MissingField;
        try control_plane.ensureUnifiedV2Connection(self.allocator, client, &self.message_counter);

        var detail = try control_plane.setProjectMount(
            self.allocator,
            client,
            &self.message_counter,
            project_id,
            project_token,
            node_id,
            export_name,
            mount_path,
        );
        defer detail.deinit(self.allocator);

        self.refreshWorkspaceData() catch {};
        self.clearWorkspaceError();
    }

    fn validateProjectMountAddInput(self: *App) ?[]const u8 {
        _ = self.selectedProjectId() orelse return "Select a project before adding mounts.";
        const mount_path = std.mem.trim(u8, self.settings_panel.project_mount_path.items, " \t");
        if (mount_path.len == 0) return "Mount path is required.";
        const node_id = std.mem.trim(u8, self.settings_panel.project_mount_node_id.items, " \t");
        if (node_id.len == 0) return "Mount node ID is required.";
        const export_name = std.mem.trim(u8, self.settings_panel.project_mount_export_name.items, " \t");
        if (export_name.len == 0) return "Mount export name is required.";
        return null;
    }

    fn validateProjectMountRemoveInput(self: *App) ?[]const u8 {
        _ = self.selectedProjectId() orelse return "Select a project before removing mounts.";
        const mount_path = std.mem.trim(u8, self.settings_panel.project_mount_path.items, " \t");
        if (mount_path.len == 0) return "Mount path is required.";
        const node_id = std.mem.trim(u8, self.settings_panel.project_mount_node_id.items, " \t");
        const export_name = std.mem.trim(u8, self.settings_panel.project_mount_export_name.items, " \t");
        if ((node_id.len == 0) != (export_name.len == 0)) {
            return "For filtered remove, provide both node ID and export name, or leave both blank.";
        }
        return null;
    }

    fn removeProjectMountFromPanel(self: *App) !void {
        const client = if (self.ws_client) |*value| value else return error.NotConnected;
        const project_id = self.selectedProjectId() orelse return error.MissingField;
        const project_token = self.selectedProjectToken(project_id);
        const mount_path = std.mem.trim(u8, self.settings_panel.project_mount_path.items, " \t");
        if (mount_path.len == 0) return error.MissingField;

        const trimmed_node_id = std.mem.trim(u8, self.settings_panel.project_mount_node_id.items, " \t");
        const trimmed_export_name = std.mem.trim(u8, self.settings_panel.project_mount_export_name.items, " \t");
        const node_id_filter: ?[]const u8 = if (trimmed_node_id.len > 0) trimmed_node_id else null;
        const export_name_filter: ?[]const u8 = if (trimmed_export_name.len > 0) trimmed_export_name else null;
        if ((node_id_filter == null) != (export_name_filter == null)) return error.MissingField;
        try control_plane.ensureUnifiedV2Connection(self.allocator, client, &self.message_counter);

        var detail = try control_plane.removeProjectMount(
            self.allocator,
            client,
            &self.message_counter,
            project_id,
            project_token,
            mount_path,
            node_id_filter,
            export_name_filter,
        );
        defer detail.deinit(self.allocator);

        self.refreshWorkspaceData() catch {};
        self.clearWorkspaceError();
    }

    fn applyThemeFromSettings(self: *App) void {
        const label = if (self.settings_panel.ui_theme.items.len > 0)
            self.settings_panel.ui_theme.items
        else
            null;
        const mode: zui.theme.Mode = if (label) |value|
            if (std.ascii.eqlIgnoreCase(value, "dark"))
                .dark
            else
                .light
        else
            .light;
        zui.theme.setMode(mode);
        const ui_mode: zui.ui.theme.Mode = switch (mode) {
            .light => .light,
            .dark => .dark,
        };
        zui.ui.theme.setMode(ui_mode);
        self.theme = zui.theme.current();
        self.invalidateGlyphWidthCache();
    }

    fn invalidateGlyphWidthCache(self: *App) void {
        for (&self.ascii_glyph_width_cache) |*value| {
            value.* = -1.0;
        }
        for (self.debug_events.items) |*entry| {
            entry.payload_wrap_rows_valid = false;
            entry.cached_visible_rows_valid = false;
        }
        self.debug_fold_revision +%= 1;
        if (self.debug_fold_revision == 0) self.debug_fold_revision = 1;
    }

    fn resolvedTextInputContextMenuRect(self: *App, fb_width: u32, fb_height: u32) Rect {
        const line_height = self.textLineHeight();
        const item_h = @max(22.0 * self.ui_scale, line_height + self.theme.spacing.xs * 1.1);
        const menu_w = @max(128.0 * self.ui_scale, 146.0);
        const menu_h = item_h * 4.0 + self.theme.spacing.xs * 2.0;

        const fb_w = @as(f32, @floatFromInt(fb_width));
        const fb_h = @as(f32, @floatFromInt(fb_height));
        const anchor = self.text_input_context_menu_anchor;

        const space_right = fb_w - anchor[0];
        const space_left = anchor[0];
        const space_down = fb_h - anchor[1];
        const space_up = anchor[1];

        var menu_x = if (space_right >= menu_w or space_right >= space_left)
            anchor[0]
        else
            anchor[0] - menu_w;
        var menu_y = if (space_down >= menu_h or space_down >= space_up)
            anchor[1]
        else
            anchor[1] - menu_h;

        menu_x = std.math.clamp(menu_x, 0.0, @max(0.0, fb_w - menu_w));
        menu_y = std.math.clamp(menu_y, 0.0, @max(0.0, fb_h - menu_h));
        return Rect.fromXYWH(menu_x, menu_y, menu_w, menu_h);
    }

    fn resolvePointerInputLayer(self: *App, fb_width: u32, fb_height: u32) void {
        if (self.text_input_context_menu_open and self.focusedSettingsBuffer() != null) {
            self.text_input_context_menu_rect = self.resolvedTextInputContextMenuRect(fb_width, fb_height);
            self.active_pointer_layer = .text_input_context_menu;
            return;
        }
        self.text_input_context_menu_rect = null;
        self.active_pointer_layer = .base;
    }

    fn drawFrame(self: *App, ui_window: *UiWindow) void {
        self.theme = zui.theme.current();
        self.metrics_context.setTheme(zui.ui.theme.activeTheme());
        self.render_input_queue = &ui_window.queue;
        defer self.render_input_queue = null;

        ui_input_router.setExternalQueue(&ui_window.queue);
        defer ui_input_router.setExternalQueue(null);

        var fb_w: c_int = 0;
        var fb_h: c_int = 0;
        _ = c.SDL_GetWindowSizeInPixels(ui_window.window, &fb_w, &fb_h);
        const fb_width: u32 = @intCast(if (fb_w > 0) fb_w else 1);
        const fb_height: u32 = @intCast(if (fb_h > 0) fb_h else 1);

        self.resolvePointerInputLayer(fb_width, fb_height);
        const overlay_captures_pointer = self.active_pointer_layer != .base;
        const saved_mouse_down = self.mouse_down;
        const saved_mouse_clicked = self.mouse_clicked;
        const saved_mouse_released = self.mouse_released;
        const saved_mouse_right_clicked = self.mouse_right_clicked;
        const saved_mouse_x = self.mouse_x;
        const saved_mouse_y = self.mouse_y;
        const saved_queue_state = ui_window.queue.state;
        const saved_queue_event_len = ui_window.queue.events.items.len;
        if (overlay_captures_pointer) {
            // Stage widgets still render, but pointer/hover/events are routed only to top input layer.
            self.mouse_down = false;
            self.mouse_clicked = false;
            self.mouse_released = false;
            self.mouse_right_clicked = false;
            self.mouse_x = -1_000_000.0;
            self.mouse_y = -1_000_000.0;
            ui_window.queue.state.mouse_pos = .{ -1_000_000.0, -1_000_000.0 };
            ui_window.queue.state.mouse_down_left = false;
            ui_window.queue.state.mouse_down_right = false;
            ui_window.queue.state.mouse_down_middle = false;
            ui_window.queue.state.pointer_kind = .nav;
            ui_window.queue.state.pointer_drag_delta = .{ 0.0, 0.0 };
            ui_window.queue.state.pointer_dragging = false;
            ui_window.queue.events.items.len = 0;
        }

        ui_window.swapchain.beginFrame(&self.gpu, fb_width, fb_height);

        // Draw active UI stage (launcher or workspace).
        self.drawStageUi(ui_window, fb_width, fb_height);
        if (overlay_captures_pointer) {
            self.mouse_down = saved_mouse_down;
            self.mouse_clicked = saved_mouse_clicked;
            self.mouse_released = saved_mouse_released;
            self.mouse_right_clicked = saved_mouse_right_clicked;
            self.mouse_x = saved_mouse_x;
            self.mouse_y = saved_mouse_y;
            ui_window.queue.state = saved_queue_state;
            ui_window.queue.events.items.len = saved_queue_event_len;
        }
        self.drawTextInputContextMenuOverlay(fb_width, fb_height);
        self.accumulateFrameCommandStats();

        // Render the UI commands through WebGPU
        self.gpu.ui_renderer.beginFrame(fb_width, fb_height);
        ui_window.swapchain.render(&self.gpu, &self.ui_commands);
    }

    fn accumulateFrameCommandStats(self: *App) void {
        for (self.ui_commands.commands.items) |command| {
            self.perf_frame_cmd_stats.total += 1;
            switch (command) {
                .text => |text_cmd| {
                    self.perf_frame_cmd_stats.text += 1;
                    self.perf_frame_cmd_stats.text_bytes += text_cmd.text_len;
                },
                .line => {
                    self.perf_frame_cmd_stats.line += 1;
                },
                .image => {
                    self.perf_frame_cmd_stats.image += 1;
                },
                .clip_push, .clip_pop => {
                    self.perf_frame_cmd_stats.clip += 1;
                },
                .rect,
                .rect_gradient,
                .rounded_rect,
                .rounded_rect_gradient,
                .soft_rounded_rect,
                .nine_slice,
                => {
                    self.perf_frame_cmd_stats.shape += 1;
                },
            }
        }
    }

    fn drawStageUi(self: *App, ui_window: *UiWindow, fb_width: u32, fb_height: u32) void {
        if (self.ui_stage == .workspace and !self.canRenderWorkspaceStage()) {
            self.returnToLauncher(.disconnected);
        }

        switch (self.ui_stage) {
            .launcher => self.drawLauncherUi(ui_window, fb_width, fb_height),
            .workspace => self.drawWorkspaceUi(ui_window, fb_width, fb_height),
        }
    }

    fn drawLauncherUi(self: *App, ui_window: *UiWindow, fb_width: u32, fb_height: u32) void {
        self.ui_commands.clear();
        ui_draw_context.setGlobalCommandList(&self.ui_commands);
        defer ui_draw_context.clearGlobalCommandList();

        const menu_h = self.windowMenuBarHeight();
        const status_h: f32 = 24.0 * self.ui_scale;
        const content_rect = Rect.fromXYWH(
            0,
            menu_h,
            @floatFromInt(fb_width),
            @max(1.0, @as(f32, @floatFromInt(fb_height)) - menu_h - status_h),
        );
        ui_window.ui_state.last_dock_content_rect = UiRect.fromMinSize(content_rect.min, .{
            content_rect.width(),
            content_rect.height(),
        });

        self.ui_commands.pushRect(
            .{ .min = .{ 0, 0 }, .max = .{ @floatFromInt(fb_width), @floatFromInt(fb_height) } },
            .{ .fill = self.theme.colors.background },
        );

        const layout = self.panelLayoutMetrics();
        const pad = layout.inset;
        const gap = layout.section_gap;
        const left_width = @max(260.0 * self.ui_scale, content_rect.width() * 0.33);
        const right_width = @max(320.0 * self.ui_scale, content_rect.width() - left_width - gap - pad * 2.0);
        const left_rect = Rect.fromXYWH(
            content_rect.min[0] + pad,
            content_rect.min[1] + pad,
            left_width,
            @max(1.0, content_rect.height() - pad * 2.0),
        );
        const right_rect = Rect.fromXYWH(
            left_rect.max[0] + gap,
            content_rect.min[1] + pad,
            right_width,
            @max(1.0, content_rect.height() - pad * 2.0),
        );

        self.drawSurfacePanel(left_rect);
        self.drawRect(left_rect, self.theme.colors.border);
        self.drawSurfacePanel(right_rect);
        self.drawRect(right_rect, self.theme.colors.border);

        var left_y = left_rect.min[1] + pad;
        const title = "Spider Web Connections";
        self.drawLabel(left_rect.min[0] + pad, left_y, title, self.theme.colors.text_primary);
        left_y += layout.line_height + layout.row_gap;

        const profile_row_h = @max(layout.button_height, 34.0 * self.ui_scale);
        const profile_row_w = left_rect.width() - pad * 2.0;
        const profiles_rect_h = @max(140.0 * self.ui_scale, left_rect.height() * 0.30);
        const profiles_rect = Rect.fromXYWH(
            left_rect.min[0] + pad,
            left_y,
            profile_row_w,
            profiles_rect_h,
        );
        self.drawSurfacePanel(profiles_rect);
        self.drawRect(profiles_rect, self.theme.colors.border);

        const selected_index = @min(
            self.launcher_selected_profile_index,
            if (self.config.connection_profiles.len > 0) self.config.connection_profiles.len - 1 else 0,
        );
        var profile_row_y = profiles_rect.min[1] + layout.inner_inset;
        if (self.config.connection_profiles.len == 0) {
            self.drawTextTrimmed(
                profiles_rect.min[0] + layout.inner_inset,
                profile_row_y,
                profiles_rect.width() - layout.inner_inset * 2.0,
                "No connection profiles. Create one below.",
                self.theme.colors.text_secondary,
            );
        } else {
            for (self.config.connection_profiles, 0..) |profile, idx| {
                if (profile_row_y + profile_row_h > profiles_rect.max[1] - layout.inner_inset) break;
                const label = if (std.mem.eql(u8, profile.id, self.config.selectedProfileId()))
                    profile.name
                else
                    profile.server_url;
                if (self.drawButtonWidget(
                    Rect.fromXYWH(
                        profiles_rect.min[0] + layout.inner_inset,
                        profile_row_y,
                        profiles_rect.width() - layout.inner_inset * 2.0,
                        profile_row_h,
                    ),
                    label,
                    .{ .variant = if (idx == selected_index) .primary else .secondary },
                )) {
                    self.launcher_selected_profile_index = idx;
                    self.applyLauncherSelectedProfile() catch |err| {
                        std.log.warn("Failed to apply selected profile: {s}", .{@errorName(err)});
                    };
                }
                profile_row_y += profile_row_h + layout.row_gap * 0.6;
            }
        }
        left_y = profiles_rect.max[1] + layout.section_gap * 0.6;

        self.drawLabel(left_rect.min[0] + pad, left_y, "Profile Name", self.theme.colors.text_secondary);
        left_y += layout.line_height + layout.row_gap * 0.25;
        const profile_name_focused = self.drawTextInputWidget(
            Rect.fromXYWH(left_rect.min[0] + pad, left_y, profile_row_w, layout.input_height),
            self.launcher_profile_name.items,
            self.settings_panel.focused_field == .launcher_profile_name,
            .{ .placeholder = "Display name" },
        );
        if (profile_name_focused) self.settings_panel.focused_field = .launcher_profile_name;
        left_y += layout.input_height + layout.row_gap * 0.55;

        self.drawLabel(left_rect.min[0] + pad, left_y, "Server URL", self.theme.colors.text_secondary);
        left_y += layout.line_height + layout.row_gap * 0.25;
        const url_focused = self.drawTextInputWidget(
            Rect.fromXYWH(left_rect.min[0] + pad, left_y, profile_row_w, layout.input_height),
            self.settings_panel.server_url.items,
            self.settings_panel.focused_field == .server_url,
            .{ .placeholder = "ws://host:port" },
        );
        if (url_focused) self.settings_panel.focused_field = .server_url;
        left_y += layout.input_height + layout.row_gap * 0.55;

        self.drawLabel(left_rect.min[0] + pad, left_y, "Metadata", self.theme.colors.text_secondary);
        left_y += layout.line_height + layout.row_gap * 0.25;
        const metadata_focused = self.drawTextInputWidget(
            Rect.fromXYWH(left_rect.min[0] + pad, left_y, profile_row_w, layout.input_height),
            self.launcher_profile_metadata.items,
            self.settings_panel.focused_field == .launcher_profile_metadata,
            .{ .placeholder = "Optional notes" },
        );
        if (metadata_focused) self.settings_panel.focused_field = .launcher_profile_metadata;
        left_y += layout.input_height + layout.row_gap * 0.55;

        self.drawLabel(left_rect.min[0] + pad, left_y, "Role", self.theme.colors.text_secondary);
        left_y += layout.line_height + layout.row_gap * 0.25;
        const role_button_w = (profile_row_w - pad) * 0.5;
        if (self.drawButtonWidget(
            Rect.fromXYWH(left_rect.min[0] + pad, left_y, role_button_w, layout.button_height),
            "Admin",
            .{ .variant = if (self.config.active_role == .admin) .primary else .secondary },
        )) {
            self.setActiveConnectRole(.admin) catch {};
        }
        if (self.drawButtonWidget(
            Rect.fromXYWH(left_rect.min[0] + pad + role_button_w + pad, left_y, role_button_w, layout.button_height),
            "User",
            .{ .variant = if (self.config.active_role == .user) .primary else .secondary },
        )) {
            self.setActiveConnectRole(.user) catch {};
        }
        left_y += layout.button_height + layout.row_gap * 0.8;

        self.drawLabel(
            left_rect.min[0] + pad,
            left_y,
            if (self.config.active_role == .admin) "Admin Token" else "User Token",
            self.theme.colors.text_secondary,
        );
        left_y += layout.line_height + layout.row_gap * 0.25;
        const connect_token_focused = self.drawTextInputWidget(
            Rect.fromXYWH(left_rect.min[0] + pad, left_y, profile_row_w, layout.input_height),
            self.launcher_connect_token.items,
            self.settings_panel.focused_field == .launcher_connect_token,
            .{
                .placeholder = if (self.config.active_role == .admin)
                    "Admin auth token"
                else
                    "User auth token",
            },
        );
        if (connect_token_focused) self.settings_panel.focused_field = .launcher_connect_token;
        left_y += layout.input_height + layout.row_gap * 0.55;

        if (self.drawButtonWidget(
            Rect.fromXYWH(left_rect.min[0] + pad, left_y, role_button_w, profile_row_h),
            "New Profile",
            .{ .variant = .secondary },
        )) {
            self.createConnectionProfileFromLauncher() catch |err| {
                const msg = std.fmt.allocPrint(self.allocator, "Profile create failed: {s}", .{@errorName(err)}) catch null;
                defer if (msg) |value| self.allocator.free(value);
                if (msg) |value| self.setLauncherNotice(value);
            };
        }
        if (self.drawButtonWidget(
            Rect.fromXYWH(left_rect.min[0] + pad + role_button_w + pad, left_y, role_button_w, profile_row_h),
            "Save Profile",
            .{ .variant = .secondary, .disabled = self.config.connection_profiles.len == 0 },
        )) {
            self.saveSelectedProfileFromLauncher() catch |err| {
                const msg = std.fmt.allocPrint(self.allocator, "Profile save failed: {s}", .{@errorName(err)}) catch null;
                defer if (msg) |value| self.allocator.free(value);
                if (msg) |value| self.setLauncherNotice(value);
            };
        }
        left_y += profile_row_h + layout.row_gap;

        if (self.drawButtonWidget(
            Rect.fromXYWH(left_rect.min[0] + pad, left_y, role_button_w, profile_row_h),
            if (self.connection_state == .connected) "Disconnect" else "Connect",
            .{ .variant = .primary, .disabled = self.connection_state == .connecting },
        )) {
            if (self.connection_state == .connected) {
                self.disconnect();
                self.setConnectionState(.disconnected, "Disconnected");
            } else {
                self.persistLauncherConnectToken() catch |err| {
                    const msg = std.fmt.allocPrint(self.allocator, "Unable to persist token: {s}", .{@errorName(err)}) catch null;
                    defer if (msg) |value| self.allocator.free(value);
                    if (msg) |value| self.setLauncherNotice(value);
                    return;
                };
                self.tryConnect(&self.manager) catch {};
                if (self.connection_state == .connected) {
                    self.refreshWorkspaceData() catch {};
                }
            }
        }
        if (self.drawButtonWidget(
            Rect.fromXYWH(left_rect.min[0] + pad + role_button_w + pad, left_y, role_button_w, profile_row_h),
            "Refresh",
            .{ .variant = .secondary, .disabled = self.connection_state != .connected },
        )) {
            self.refreshWorkspaceData() catch |err| {
                const msg = std.fmt.allocPrint(self.allocator, "Refresh failed: {s}", .{@errorName(err)}) catch null;
                defer if (msg) |value| self.allocator.free(value);
                if (msg) |value| self.setLauncherNotice(value);
            };
        }

        var right_y = right_rect.min[1] + pad;
        self.drawLabel(right_rect.min[0] + pad, right_y, "Projects", self.theme.colors.text_primary);
        right_y += layout.line_height + layout.row_gap * 0.6;
        if (self.launcher_notice) |notice| {
            self.drawTextTrimmed(
                right_rect.min[0] + pad,
                right_y,
                right_rect.width() - pad * 2.0,
                notice,
                self.theme.colors.text_secondary,
            );
            right_y += layout.line_height + layout.row_gap * 0.7;
        }

        const filter_rect = Rect.fromXYWH(
            right_rect.min[0] + pad,
            right_y,
            right_rect.width() - pad * 2.0,
            layout.input_height,
        );
        const filter_focused = self.drawTextInputWidget(
            filter_rect,
            self.launcher_project_filter.items,
            self.settings_panel.focused_field == .launcher_project_filter,
            .{ .placeholder = "Search projects" },
        );
        if (filter_focused) self.settings_panel.focused_field = .launcher_project_filter;
        right_y += layout.input_height + layout.row_gap * 0.55;

        const create_name_rect = Rect.fromXYWH(
            right_rect.min[0] + pad,
            right_y,
            right_rect.width() - pad * 2.0,
            layout.input_height,
        );
        const create_name_focused = self.drawTextInputWidget(
            create_name_rect,
            self.settings_panel.project_create_name.items,
            self.settings_panel.focused_field == .project_create_name,
            .{ .placeholder = "New project name" },
        );
        if (create_name_focused) self.settings_panel.focused_field = .project_create_name;
        right_y += layout.input_height + layout.row_gap;

        const project_row_h = @max(layout.button_height, 32.0 * self.ui_scale);
        const list_h = @max(1.0, right_rect.max[1] - right_y - pad - project_row_h - layout.row_gap);
        const list_rect = Rect.fromXYWH(right_rect.min[0] + pad, right_y, right_rect.width() - pad * 2.0, list_h);
        self.drawSurfacePanel(list_rect);
        self.drawRect(list_rect, self.theme.colors.border);

        var project_row_y = list_rect.min[1] + layout.inner_inset;
        for (self.projects.items) |project| {
            if (project_row_y + project_row_h > list_rect.max[1] - layout.inner_inset) break;
            const matches_filter = self.launcher_project_filter.items.len == 0 or
                containsCaseInsensitive(project.name, self.launcher_project_filter.items) or
                containsCaseInsensitive(project.id, self.launcher_project_filter.items);
            if (!matches_filter) continue;
            const is_selected = self.settings_panel.project_id.items.len > 0 and std.mem.eql(u8, self.settings_panel.project_id.items, project.id);
            if (self.drawButtonWidget(
                Rect.fromXYWH(list_rect.min[0] + layout.inner_inset, project_row_y, list_rect.width() - layout.inner_inset * 2.0, project_row_h),
                project.name,
                .{ .variant = if (is_selected) .primary else .secondary },
            )) {
                self.selectProjectInSettings(project.id) catch {};
            }
            project_row_y += project_row_h + layout.row_gap * 0.5;
        }

        const open_rect = Rect.fromXYWH(
            right_rect.min[0] + pad,
            right_rect.max[1] - pad - project_row_h,
            @max(160.0 * self.ui_scale, right_rect.width() * 0.4),
            project_row_h,
        );
        if (self.drawButtonWidget(
            open_rect,
            "Open Project",
            .{ .variant = .primary, .disabled = self.connection_state != .connected or self.selectedProjectId() == null },
        )) {
            self.openSelectedProjectFromLauncher() catch |err| {
                const msg = self.formatControlOpError("Failed to open project", err);
                if (msg) |value| {
                    defer self.allocator.free(value);
                    self.setLauncherNotice(value);
                }
            };
        }

        const create_rect = Rect.fromXYWH(
            open_rect.max[0] + pad,
            right_rect.max[1] - pad - project_row_h,
            @max(160.0 * self.ui_scale, right_rect.width() * 0.4),
            project_row_h,
        );
        if (self.drawButtonWidget(
            create_rect,
            "Create Project",
            .{ .variant = .secondary, .disabled = self.connection_state != .connected or self.settings_panel.project_create_name.items.len == 0 },
        )) {
            self.createProjectFromPanel() catch |err| {
                const msg = self.formatControlOpError("Project create failed", err);
                if (msg) |value| {
                    defer self.allocator.free(value);
                    self.setLauncherNotice(value);
                }
            };
        }

        _ = self.drawWindowMenuBar(ui_window, fb_width);
        self.drawStatusOverlay(fb_width, fb_height);
    }

    fn drawWorkspaceUi(self: *App, ui_window: *UiWindow, fb_width: u32, fb_height: u32) void {
        self.ui_commands.clear();
        ui_draw_context.setGlobalCommandList(&self.ui_commands);
        defer ui_draw_context.clearGlobalCommandList();

        const status_height: f32 = 24.0 * self.ui_scale;
        const menu_height = self.windowMenuBarHeight();
        const dock_height = @max(1.0, @as(f32, @floatFromInt(fb_height)) - status_height - menu_height);
        const viewport = UiRect.fromMinSize(
            .{ 0, menu_height },
            .{ @floatFromInt(fb_width), dock_height },
        );

        // Draw background
        self.ui_commands.pushRect(
            .{ .min = .{ 0, 0 }, .max = .{ @floatFromInt(fb_width), @floatFromInt(fb_height) } },
            .{ .fill = self.theme.colors.background },
        );

        ui_window.ui_state.last_dock_content_rect = viewport;

        const mouse_in_viewport = self.mouse_x >= viewport.min[0] and
            self.mouse_x <= viewport.max[0] and
            self.mouse_y >= viewport.min[1] and
            self.mouse_y <= viewport.max[1];
        const saved_mouse_clicked = self.mouse_clicked;
        const saved_mouse_released = self.mouse_released;
        const saved_mouse_down = self.mouse_down;
        if (!mouse_in_viewport) {
            self.mouse_clicked = false;
            self.mouse_released = false;
            self.mouse_down = false;
        }

        self.ui_commands.pushClip(.{ .min = viewport.min, .max = viewport.max });

        var layout: dock_graph.LayoutResult = .{};
        if (!self.collectDockLayoutSafe(ui_window.manager, viewport, &layout)) {
            if (self.shouldLogDebug(120) or self.shouldLogStartup()) {
                std.log.warn("drawDockUi: unable to recover dock layout; no panels available", .{});
            }
            self.drawText(
                viewport.min[0] + 12.0,
                viewport.min[1] + 12.0,
                "Unable to recover dock layout; no panels available.",
                self.theme.colors.text_secondary,
            );
            self.ui_commands.popClip();
            self.mouse_clicked = saved_mouse_clicked;
            self.mouse_released = saved_mouse_released;
            self.mouse_down = saved_mouse_down;
            _ = self.drawWindowMenuBar(ui_window, fb_width);
            self.drawStatusOverlay(fb_width, fb_height);
            return;
        }
        // Draw each dock group
        for (layout.slice()) |group| {
            if (!self.isLayoutGroupUsable(ui_window.manager, group.node_id)) continue;
            self.drawDockGroup(ui_window.manager, group.node_id, group.rect);
        }

        const splitters = ui_window.manager.workspace.dock_layout.computeSplitters(viewport);
        self.drawDockSplitters(&ui_window.queue, ui_window, &splitters);

        var drag_tab_hits = DockTabHitList{};
        var drag_drop_targets = DockDropTargetList{};
        self.collectDockInteractionGeometry(ui_window.manager, viewport, &drag_tab_hits, &drag_drop_targets);
        self.drawDockDragOverlay(&ui_window.queue, ui_window.manager, ui_window, &drag_drop_targets, viewport);
        self.ui_commands.popClip();
        self.mouse_clicked = saved_mouse_clicked;
        self.mouse_released = saved_mouse_released;
        self.mouse_down = saved_mouse_down;

        _ = self.drawWindowMenuBar(ui_window, fb_width);
        self.drawStatusOverlay(fb_width, fb_height);
    }

    fn windowMenuBarHeight(self: *App) f32 {
        const layout = self.panelLayoutMetrics();
        return @max(layout.button_height + layout.inner_inset * 1.2, 30.0 * self.ui_scale);
    }

    fn ideMenuDomainLabel(domain: IdeMenuDomain) []const u8 {
        return switch (domain) {
            .file => "File",
            .edit => "Edit",
            .view => "View",
            .project => "Project",
            .tools => "Tools",
            .window => "Window",
            .help => "Help",
        };
    }

    fn ideMenuRowCount(domain: IdeMenuDomain, stage: UiStage) usize {
        return switch (domain) {
            .file => if (stage == .launcher) 1 else 2,
            .edit => 2,
            .view => 2,
            .project => 2,
            .tools => 2,
            .window => 1,
            .help => 1,
        };
    }

    fn drawWindowMenuBar(self: *App, ui_window: *UiWindow, fb_width: u32) f32 {
        const layout = self.panelLayoutMetrics();
        const bar_h = self.windowMenuBarHeight();
        const bar_rect = Rect.fromXYWH(0, 0, @floatFromInt(fb_width), bar_h);
        self.ui_commands.pushRect(
            .{ .min = bar_rect.min, .max = bar_rect.max },
            .{ .fill = self.theme.colors.background, .stroke = self.theme.colors.border },
        );

        const domains: []const IdeMenuDomain = if (self.ui_stage == .launcher)
            &[_]IdeMenuDomain{ .file, .help }
        else
            &[_]IdeMenuDomain{ .file, .edit, .view, .project, .tools, .window, .help };

        const button_y = bar_rect.min[1] + @max(0.0, (bar_h - layout.button_height) * 0.5);
        var x = layout.inset;
        var selected_button_rect: ?Rect = null;
        var dropdown_rect: ?Rect = null;

        for (domains) |domain| {
            const label = ideMenuDomainLabel(domain);
            const button_w = @max(86.0 * self.ui_scale, self.measureText(label) + layout.inner_inset * 2.0);
            const button_rect = Rect.fromXYWH(x, button_y, button_w, layout.button_height);
            const is_open = self.ide_menu_open != null and self.ide_menu_open.? == domain;
            if (self.drawButtonWidget(
                button_rect,
                label,
                .{ .variant = if (is_open) .primary else .secondary },
            )) {
                self.ide_menu_open = if (is_open) null else domain;
            }
            if (is_open) selected_button_rect = button_rect;
            x += button_w + layout.row_gap * 0.4;
        }

        if (self.ide_menu_open) |open_domain| {
            const menu_w = @max(228.0 * self.ui_scale, 200.0 * self.ui_scale);
            const row_h = layout.button_height;
            const row_gap = @max(1.0, layout.inner_inset * 0.2);
            const row_count: usize = ideMenuRowCount(open_domain, self.ui_stage);
            const menu_h = layout.inner_inset * 2.0 +
                @as(f32, @floatFromInt(row_count)) * row_h +
                @as(f32, @floatFromInt(@max(@as(usize, 1), row_count) - 1)) * row_gap;
            const menu_x = if (selected_button_rect) |rect| rect.min[0] else layout.inset;
            const menu_y = bar_rect.max[1] + @max(1.0, layout.inner_inset * 0.2);
            const menu_rect = Rect.fromXYWH(menu_x, menu_y, menu_w, menu_h);
            dropdown_rect = menu_rect;

            self.drawSurfacePanel(menu_rect);
            self.drawRect(menu_rect, self.theme.colors.border);

            var row_y = menu_rect.min[1] + layout.inner_inset;
            const row_x = menu_rect.min[0] + layout.inner_inset;
            const row_w = menu_rect.width() - layout.inner_inset * 2.0;

            switch (open_domain) {
                .file => {
                    if (self.ui_stage == .launcher) {
                        if (self.drawButtonWidget(
                            Rect.fromXYWH(row_x, row_y, row_w, row_h),
                            if (self.connection_state == .connected) "Disconnect" else "Connect",
                            .{ .variant = .secondary },
                        )) {
                            if (self.connection_state == .connected) {
                                self.disconnect();
                                self.setConnectionState(.disconnected, "Disconnected");
                            } else {
                                self.tryConnect(&self.manager) catch {};
                            }
                            self.ide_menu_open = null;
                        }
                        row_y += row_h + row_gap;
                    } else {
                        if (self.drawButtonWidget(
                            Rect.fromXYWH(row_x, row_y, row_w, row_h),
                            "Switch Project",
                            .{ .variant = .secondary },
                        )) {
                            self.returnToLauncher(.switched_project);
                            self.ide_menu_open = null;
                        }
                        row_y += row_h + row_gap;
                        if (self.drawButtonWidget(
                            Rect.fromXYWH(row_x, row_y, row_w, row_h),
                            "Disconnect",
                            .{ .variant = .secondary, .disabled = self.connection_state != .connected },
                        )) {
                            self.disconnect();
                            self.setConnectionState(.disconnected, "Disconnected");
                            self.returnToLauncher(.disconnected);
                            self.ide_menu_open = null;
                        }
                    }
                },
                .edit => {
                    _ = self.drawButtonWidget(
                        Rect.fromXYWH(row_x, row_y, row_w, row_h),
                        "Undo (coming soon)",
                        .{ .variant = .secondary, .disabled = true },
                    );
                    row_y += row_h + row_gap;
                    _ = self.drawButtonWidget(
                        Rect.fromXYWH(row_x, row_y, row_w, row_h),
                        "Redo (coming soon)",
                        .{ .variant = .secondary, .disabled = true },
                    );
                },
                .view => {
                    if (self.drawButtonWidget(
                        Rect.fromXYWH(row_x, row_y, row_w, row_h),
                        if (self.manager.hasPanel(.Chat)) "Chat (Focus)" else "Chat (Open)",
                        .{ .variant = .secondary },
                    )) {
                        self.manager.ensurePanel(.Chat);
                        self.ide_menu_open = null;
                    }
                    row_y += row_h + row_gap;
                    if (self.drawButtonWidget(
                        Rect.fromXYWH(row_x, row_y, row_w, row_h),
                        if (self.filesystem_panel_id != null) "Explorer (Focus)" else "Explorer (Open)",
                        .{ .variant = .secondary },
                    )) {
                        _ = self.ensureFilesystemPanel(&self.manager) catch {};
                        self.ide_menu_open = null;
                    }
                },
                .project => {
                    if (self.drawButtonWidget(
                        Rect.fromXYWH(row_x, row_y, row_w, row_h),
                        "Refresh Workspace",
                        .{ .variant = .secondary, .disabled = self.connection_state != .connected },
                    )) {
                        self.refreshWorkspaceData() catch {};
                        self.ide_menu_open = null;
                    }
                    row_y += row_h + row_gap;
                    if (self.drawButtonWidget(
                        Rect.fromXYWH(row_x, row_y, row_w, row_h),
                        "Activate Selected",
                        .{ .variant = .secondary, .disabled = self.connection_state != .connected or self.selectedProjectId() == null },
                    )) {
                        self.activateSelectedProject() catch {};
                        self.ide_menu_open = null;
                    }
                },
                .tools => {
                    if (self.drawButtonWidget(
                        Rect.fromXYWH(row_x, row_y, row_w, row_h),
                        "Settings",
                        .{ .variant = .secondary },
                    )) {
                        self.ensureWorkspacePanel(&self.manager);
                        self.ide_menu_open = null;
                    }
                    row_y += row_h + row_gap;
                    if (self.drawButtonWidget(
                        Rect.fromXYWH(row_x, row_y, row_w, row_h),
                        if (self.filesystem_tools_panel_id != null) "Explorer Tools (Focus)" else "Explorer Tools (Open)",
                        .{ .variant = .secondary },
                    )) {
                        _ = self.ensureFilesystemToolsPanel(&self.manager) catch {};
                        self.ide_menu_open = null;
                    }
                    row_y += row_h + row_gap;
                    if (self.drawButtonWidget(
                        Rect.fromXYWH(row_x, row_y, row_w, row_h),
                        "Terminal",
                        .{ .variant = .secondary },
                    )) {
                        _ = self.ensureTerminalPanel(&self.manager) catch {};
                        self.ide_menu_open = null;
                    }
                },
                .window => {
                    if (self.drawButtonWidget(
                        Rect.fromXYWH(row_x, row_y, row_w, row_h),
                        "New Window",
                        .{ .variant = .secondary },
                    )) {
                        self.spawnUiWindow() catch {};
                        self.ide_menu_open = null;
                    }
                },
                .help => {
                    if (self.drawButtonWidget(
                        Rect.fromXYWH(row_x, row_y, row_w, row_h),
                        "About SpiderApp",
                        .{ .variant = .secondary },
                    )) {
                        self.appendMessage("system", "SpiderApp IDE - launcher/workspace flow enabled.", null) catch {};
                        self.ide_menu_open = null;
                    }
                },
            }
        }

        if (self.mouse_clicked and self.ide_menu_open != null) {
            const in_button = if (selected_button_rect) |rect| rect.contains(.{ self.mouse_x, self.mouse_y }) else false;
            const in_dropdown = if (dropdown_rect) |rect| rect.contains(.{ self.mouse_x, self.mouse_y }) else false;
            if (!in_button and !in_dropdown) self.ide_menu_open = null;
        }

        _ = ui_window;

        return bar_h;
    }

    fn drawUnavailableWorkspaceFrame(self: *App, ui_window: *UiWindow, message: []const u8) void {
        var fb_w: c_int = 0;
        var fb_h: c_int = 0;
        _ = c.SDL_GetWindowSizeInPixels(ui_window.window, &fb_w, &fb_h);
        const fb_width: u32 = @intCast(if (fb_w > 0) fb_w else 1);
        const fb_height: u32 = @intCast(if (fb_h > 0) fb_h else 1);
        self.render_input_queue = &ui_window.queue;
        defer self.render_input_queue = null;

        self.ui_commands.clear();
        ui_draw_context.setGlobalCommandList(&self.ui_commands);
        defer ui_draw_context.clearGlobalCommandList();

        self.ui_commands.pushRect(
            .{ .min = .{ 0, 0 }, .max = .{ @floatFromInt(fb_width), @floatFromInt(fb_height) } },
            .{ .fill = self.theme.colors.background },
        );

        const status_height: f32 = 24.0 * self.ui_scale;
        const viewport = UiRect.fromMinSize(
            .{ 0, 0 },
            .{ @floatFromInt(fb_width), @as(f32, @floatFromInt(fb_height)) - status_height },
        );
        ui_window.ui_state.last_dock_content_rect = viewport;

        self.drawText(
            viewport.min[0] + 12.0,
            viewport.min[1] + 12.0,
            message,
            self.theme.colors.text_primary,
        );

        self.drawText(
            viewport.min[0] + 12.0,
            viewport.min[1] + 36.0,
            "Please wait; layout is being restored.",
            self.theme.colors.text_secondary,
        );

        self.drawStatusOverlay(fb_width, fb_height);

        ui_window.swapchain.beginFrame(&self.gpu, fb_width, fb_height);
        self.gpu.ui_renderer.beginFrame(fb_width, fb_height);
        ui_window.swapchain.render(&self.gpu, &self.ui_commands);
    }

    fn drawDockGroup(self: *App, manager: *panel_manager.PanelManager, node_id: dock_graph.NodeId, rect: UiRect) void {
        if (!self.isLayoutGroupUsable(manager, node_id)) return;
        const node = manager.workspace.dock_layout.getNode(node_id) orelse return;
        const tabs_node = switch (node.*) {
            .tabs => |tabs| tabs,
            .split => return,
        };
        if (!self.isTabsNodeUsable(manager, &tabs_node)) return;
        if (tabs_node.tabs.items.len == 0) return;
        if (tabs_node.tabs.items.len > manager.workspace.panels.items.len) {
            if (self.shouldLogDebug(120) or self.shouldLogStartup()) {
                std.log.warn("drawDockGroup: tabs node references unknown panel count; skipping render", .{});
            }
            return;
        }
        self.drawTabsPanel(manager, &tabs_node, rect);
    }

    fn drawDockSplitters(
        self: *App,
        queue: *ui_input_state.InputQueue,
        ui_window: *UiWindow,
        splitters: *const dock_graph.SplitterResult,
    ) void {
        for (splitters.slice()) |splitter| {
            const hovered = splitter.handle_rect.contains(queue.state.mouse_pos);
            const active = ui_window.ui_state.split_drag.node_id != null and ui_window.ui_state.split_drag.node_id.? == splitter.node_id;
            const fill = if (active)
                zcolors.withAlpha(self.theme.colors.primary, 0.22)
            else if (hovered)
                zcolors.withAlpha(self.theme.colors.primary, 0.12)
            else
                zcolors.withAlpha(self.theme.colors.border, 0.08);
            self.ui_commands.pushRect(
                .{ .min = splitter.handle_rect.min, .max = splitter.handle_rect.max },
                .{ .fill = fill },
            );
        }
    }

    fn drawDockDragOverlay(
        self: *App,
        queue: *ui_input_state.InputQueue,
        manager: *panel_manager.PanelManager,
        ui_window: *UiWindow,
        drop_targets: *const DockDropTargetList,
        dock_rect: UiRect,
    ) void {
        if (!ui_window.ui_state.dock_drag.dragging) return;

        const hovered_target = drop_targets.findAt(queue.state.mouse_pos);
        if (hovered_target) |target| {
            for (drop_targets.items[0..drop_targets.len]) |candidate| {
                if (candidate.node_id != target.node_id or candidate.location == target.location) continue;
                self.drawDockDropPreview(candidate, false);
            }
            self.drawDockDropPreview(target, true);
        }

        const panel_id = ui_window.ui_state.dock_drag.panel_id orelse return;
        const panel = self.findPanelById(manager, panel_id) orelse return;
        var hint: []const u8 = "No dock target";
        if (hovered_target) |target| {
            hint = dockDropTargetLabel(target.location);
        } else if (!dock_rect.contains(queue.state.mouse_pos)) {
            hint = "Detach to new window";
        }

        var label_buf: [256]u8 = undefined;
        const text = std.fmt.bufPrint(&label_buf, "{s} -> {s}", .{ panel.title, hint }) catch panel.title;
        const text_w = self.measureText(text);
        const line_height = self.textLineHeight();
        const pad = @max(self.theme.spacing.xs, 4.0 * self.ui_scale);
        const offset = @max(self.theme.spacing.md * 0.9, 12.0 * self.ui_scale);
        const label_rect = UiRect.fromMinSize(
            .{ queue.state.mouse_pos[0] + offset, queue.state.mouse_pos[1] + offset },
            .{ text_w + pad * 2.0, line_height + pad * 2.0 },
        );
        self.ui_commands.pushRect(
            .{ .min = label_rect.min, .max = label_rect.max },
            .{
                .fill = zcolors.withAlpha(self.theme.colors.background, 0.92),
                .stroke = zcolors.withAlpha(self.theme.colors.border, 0.9),
            },
        );
        self.drawText(
            label_rect.min[0] + pad,
            label_rect.min[1] + pad,
            text,
            self.theme.colors.text_primary,
        );
    }

    fn drawDockDropPreview(self: *App, target: DockDropTarget, active: bool) void {
        const fill = if (active)
            zcolors.withAlpha(self.theme.colors.primary, 0.20)
        else
            zcolors.withAlpha(self.theme.colors.primary, 0.07);
        const stroke = if (active)
            zcolors.withAlpha(self.theme.colors.primary, 0.86)
        else
            zcolors.withAlpha(self.theme.colors.primary, 0.35);
        self.ui_commands.pushRect(
            .{ .min = target.rect.min, .max = target.rect.max },
            .{ .fill = fill, .stroke = stroke },
        );
    }

    fn collectDockLayout(
        self: *App,
        manager: *panel_manager.PanelManager,
        root_rect: UiRect,
        out: *dock_graph.LayoutResult,
    ) bool {
        out.len = 0;

        const graph = &manager.workspace.dock_layout;
        if (manager.workspace.panels.items.len > 4096) return false;
        if (graph.nodes.items.len > 16384) return false;
        if (!self.isDockLayoutGraphHeaderSane(graph)) return false;
        const root = graph.root orelse return false;

        if (root >= graph.nodes.items.len) {
            if (self.shouldLogDebug(240)) {
                std.log.debug("collectDockLayout: root {} out of range nodes_len={}", .{ root, graph.nodes.items.len });
            }
            return false;
        }
        if (graph.nodes.items.len == 0) {
            if (self.shouldLogDebug(240)) {
                std.log.debug("collectDockLayout: empty node list", .{});
            }
            return false;
        }
        if (self.isDockLayoutCorrupt(manager)) return false;
        const computed = graph.computeLayout(root_rect);
        for (computed.slice()) |group| {
            if (self.isLayoutGroupUsable(manager, group.node_id)) {
                out.append(group);
            }
        }
        return out.len > 0;
    }

    fn isLayoutGroupUsable(self: *App, manager: *panel_manager.PanelManager, node_id: dock_graph.NodeId) bool {
        if (node_id >= manager.workspace.dock_layout.nodes.items.len) return false;
        if (!self.isDockLayoutGraphHeaderSane(&manager.workspace.dock_layout)) return false;
        const node = manager.workspace.dock_layout.getNode(node_id) orelse return false;
        const tabs_node = switch (node.*) {
            .tabs => |tabs| tabs,
            .split => return false,
        };
        if (tabs_node.tabs.items.len == 0) return false;
        if (tabs_node.tabs.items.len > manager.workspace.panels.items.len) return false;
        return true;
    }

    fn computeSplitRect(self: *App, rect: UiRect, axis: dock_graph.Axis, ratio: f32) struct { first: UiRect, second: UiRect } {
        const size = rect.size();
        const clamped_ratio = std.math.clamp(ratio, 0.1, 0.9);
        const gap = self.dockSplitGap();
        if (axis == .vertical) {
            const avail = @max(0.0, size[0] - gap);
            const first_w = avail * clamped_ratio;
            const second_w = avail - first_w;
            const first_rect = UiRect.fromMinSize(rect.min, .{ first_w, size[1] });
            const second_min = .{ rect.min[0] + first_w + gap, rect.min[1] };
            const second_rect = UiRect.fromMinSize(second_min, .{ second_w, size[1] });
            return .{ .first = first_rect, .second = second_rect };
        }

        const avail = @max(0.0, size[1] - gap);
        const first_h = avail * clamped_ratio;
        const second_h = avail - first_h;
        const first_rect = UiRect.fromMinSize(rect.min, .{ size[0], first_h });
        const second_min = .{ rect.min[0], rect.min[1] + first_h + gap };
        const second_rect = UiRect.fromMinSize(second_min, .{ size[0], second_h });
        return .{ .first = first_rect, .second = second_rect };
    }

    fn repairDockLayout(self: *App, manager: *panel_manager.PanelManager) bool {
        _ = self;
        if (manager.workspace.panels.items.len == 0) return false;
        var graph = &manager.workspace.dock_layout;
        const panel_count = manager.workspace.panels.items.len;
        if (panel_count > 4096) {
            graph.nodes.clearRetainingCapacity();
            graph.root = null;
            return false;
        }

        graph.nodes.clearRetainingCapacity();
        graph.root = null;
        return manager.workspace.syncDockLayout() catch false;
    }

    fn isDockLayoutCorrupt(self: *App, manager: *panel_manager.PanelManager) bool {
        const graph = &manager.workspace.dock_layout;
        if (!self.isDockLayoutGraphHeaderSane(graph)) return true;
        if (graph.root == null) {
            return graph.nodes.items.len > 0;
        }
        const root = graph.root.?;
        if (root >= graph.nodes.items.len) return true;
        if (graph.getNode(root) == null) return true;

        if (graph.nodes.items.len == 0) return true;
        const visited = self.allocator.alloc(bool, graph.nodes.items.len) catch return true;
        defer self.allocator.free(visited);
        const in_stack = self.allocator.alloc(bool, graph.nodes.items.len) catch return true;
        defer self.allocator.free(in_stack);
        @memset(visited, false);
        @memset(in_stack, false);

        return !self.validateDockNode(
            manager,
            root,
            graph,
            visited,
            in_stack,
        );
    }

    fn validateDockNode(
        self: *App,
        manager: *panel_manager.PanelManager,
        node_id: dock_graph.NodeId,
        graph: *const dock_graph.Graph,
        visited: []bool,
        in_stack: []bool,
    ) bool {
        if (node_id >= graph.nodes.items.len) return false;
        if (node_id >= visited.len) return false;
        const idx: usize = @intCast(node_id);
        if (visited[idx]) return true;
        if (in_stack[idx]) return false;
        visited[idx] = true;
        in_stack[idx] = true;
        defer in_stack[idx] = false;

        const node = graph.getNode(node_id) orelse return false;
        switch (node.*) {
            .tabs => |tabs| {
                if (tabs.tabs.items.len == 0) return false;
                if (tabs.active >= tabs.tabs.items.len) {
                    if (self.shouldLogDebug(480)) {
                        std.log.debug("validateDockNode: stale active tab index {d} for {} tabs", .{
                            tabs.active,
                            tabs.tabs.items.len,
                        });
                    }
                }
                if (tabs.tabs.items.len > 4096) return false;
                for (tabs.tabs.items) |panel_id| {
                    if (self.findPanelById(manager, panel_id) == null) {
                        if (self.shouldLogDebug(480)) {
                            std.log.debug("validateDockNode: panel id {} not in workspace", .{panel_id});
                        }
                        return false;
                    }
                }
                return true;
            },
            .split => |split| {
                if (!std.math.isFinite(split.ratio) or split.ratio < 0.0 or split.ratio > 1.0) return false;
                if (split.first >= graph.nodes.items.len or split.second >= graph.nodes.items.len) return false;
                if (split.first == split.second) return false;
                return self.validateDockNode(manager, split.first, graph, visited, in_stack) and
                    self.validateDockNode(manager, split.second, graph, visited, in_stack);
            },
        }
    }

    fn drawTabsPanel(self: *App, manager: *panel_manager.PanelManager, tabs: *const dock_graph.TabsNode, rect: UiRect) void {
        if (!self.isTabsNodeUsable(manager, tabs)) return;
        const line_height = self.textLineHeight();
        const tab_metrics = self.dockTabMetrics();
        const tab_height = tab_metrics.height;

        // Draw panel background
        self.ui_commands.pushRect(
            .{ .min = rect.min, .max = rect.max },
            .{ .fill = self.theme.colors.surface },
        );

        // Draw tab bar
        const tab_bar_rect = UiRect.fromMinSize(
            rect.min,
            .{ rect.max[0] - rect.min[0], tab_height },
        );
        self.ui_commands.pushRect(
            .{ .min = tab_bar_rect.min, .max = tab_bar_rect.max },
            .{ .fill = self.theme.colors.background },
        );

        var tab_x = rect.min[0] + tab_metrics.pad;
        const rect_w = rect.max[0] - rect.min[0];
        var active_tab_id = if (tabs.active < tabs.tabs.items.len)
            tabs.tabs.items[tabs.active]
        else
            null;
        if (active_tab_id == null) {
            for (tabs.tabs.items) |candidate_panel_id| {
                if (self.findPanelById(manager, candidate_panel_id) != null) {
                    active_tab_id = candidate_panel_id;
                    break;
                }
            }
        }

        // Draw each tab
        for (tabs.tabs.items) |panel_id| {
            const panel = self.findPanelById(manager, panel_id) orelse continue;
            const is_active = panel_id == active_tab_id;

            const desired_tab_width = self.measureText(panel.title) + tab_metrics.pad * 2.0;
            const tab_width = self.dockTabWidth(panel.title, rect_w, tab_metrics);
            const tab_rect = UiRect.fromMinSize(
                .{ tab_x, rect.min[1] },
                .{ tab_width, tab_height },
            );

            // Tab background
            const tab_color = if (is_active)
                self.theme.colors.surface
            else
                self.theme.colors.background;
            self.ui_commands.pushRect(
                .{ .min = tab_rect.min, .max = tab_rect.max },
                .{ .fill = tab_color },
            );

            // Tab border
            self.ui_commands.pushRect(
                .{ .min = tab_rect.min, .max = tab_rect.max },
                .{ .stroke = self.theme.colors.border },
            );

            // Tab text
            if (desired_tab_width > tab_width) {
                self.drawTextTrimmed(
                    tab_x + tab_metrics.pad,
                    rect.min[1] + @max(0.0, (tab_height - line_height) * 0.5),
                    tab_width - tab_metrics.pad * 2.0,
                    panel.title,
                    self.theme.colors.text_primary,
                );
            } else {
                self.drawText(
                    tab_x + tab_metrics.pad,
                    rect.min[1] + @max(0.0, (tab_height - line_height) * 0.5),
                    panel.title,
                    self.theme.colors.text_primary,
                );
            }

            tab_x += tab_width + tab_metrics.pad;
        }

        // Draw content area for active tab
        const content_rect = UiRect.fromMinSize(
            .{ rect.min[0], rect.min[1] + tab_height },
            .{ rect.max[0] - rect.min[0], rect.max[1] - rect.min[1] - tab_height },
        );

        if (active_tab_id) |panel_id| {
            self.ui_commands.pushClip(.{ .min = content_rect.min, .max = content_rect.max });
            defer self.ui_commands.popClip();
            self.drawPanelContent(manager, panel_id, content_rect);
        }
    }

    fn isTabsNodeUsable(self: *App, manager: *panel_manager.PanelManager, tabs: *const dock_graph.TabsNode) bool {
        if (tabs.tabs.items.len == 0) return false;
        if (tabs.tabs.items.len > MAX_REASONABLE_PANEL_COUNT) return false;
        if (tabs.active >= tabs.tabs.items.len) {
            if (self.shouldLogDebug(480) or self.shouldLogStartup()) {
                std.log.debug("isTabsNodeUsable: stale active index {d} for {} tabs", .{
                    tabs.active,
                    tabs.tabs.items.len,
                });
            }
        }
        if (tabs.tabs.items.len > manager.workspace.panels.items.len) return false;

        for (tabs.tabs.items) |panel_id| {
            if (self.findPanelById(manager, panel_id) == null) {
                if (self.shouldLogDebug(480) or self.shouldLogStartup()) {
                    std.log.debug("isTabsNodeUsable: unknown panel id {d}", .{panel_id});
                }
                return false;
            }
        }
        return true;
    }

    fn findPanelById(_: *App, manager: *panel_manager.PanelManager, panel_id: workspace.PanelId) ?*workspace.Panel {
        for (manager.workspace.panels.items) |*panel| {
            if (panel.id == panel_id) return panel;
        }
        return null;
    }

    fn drawPanelContent(self: *App, manager: *panel_manager.PanelManager, panel_id: workspace.PanelId, rect: UiRect) void {
        const panel = self.findPanelById(manager, panel_id) orelse return;
        self.promoteLegacyHostPanel(manager, panel);
        const inset = self.panelLayoutMetrics().inset;

        switch (panel.kind) {
            .Chat => {
                const started_ns = std.time.nanoTimestamp();
                self.drawChatPanel(rect);
                self.perf_frame_panel_ns.chat += std.time.nanoTimestamp() - started_ns;
            },
            .Settings, .Control => {
                const started_ns = std.time.nanoTimestamp();
                self.drawSettingsPanel(manager, rect);
                self.perf_frame_panel_ns.settings += std.time.nanoTimestamp() - started_ns;
            },
            .ProjectWorkspace => {
                const started_ns = std.time.nanoTimestamp();
                if (!self.drawHostPanelWithRuntime(manager, panel, rect)) {
                    self.drawProjectPanel(manager, rect);
                }
                self.project_panel_id = panel.id;
                self.perf_frame_panel_ns.projects += std.time.nanoTimestamp() - started_ns;
            },
            .FilesystemBrowser => {
                const started_ns = std.time.nanoTimestamp();
                if (!self.drawHostPanelWithRuntime(manager, panel, rect)) {
                    self.drawFilesystemPanel(manager, rect);
                }
                self.filesystem_panel_id = panel.id;
                self.perf_frame_panel_ns.filesystem += std.time.nanoTimestamp() - started_ns;
            },
            .FilesystemTools => {
                const started_ns = std.time.nanoTimestamp();
                if (!self.drawHostPanelWithRuntime(manager, panel, rect)) {
                    self.drawFilesystemToolsPanel(manager, rect);
                }
                self.filesystem_tools_panel_id = panel.id;
                self.perf_frame_panel_ns.filesystem += std.time.nanoTimestamp() - started_ns;
            },
            .DebugStream => {
                const started_ns = std.time.nanoTimestamp();
                if (!self.drawHostPanelWithRuntime(manager, panel, rect)) {
                    self.drawDebugPanel(manager, rect);
                }
                self.debug_panel_id = panel.id;
                self.perf_frame_panel_ns.debug += std.time.nanoTimestamp() - started_ns;
            },
            .ToolOutput => {
                if (self.terminal_panel_id != null and self.terminal_panel_id.? == panel.id) {
                    const started_ns = std.time.nanoTimestamp();
                    self.drawTerminalPanel(manager, rect);
                    self.perf_frame_panel_ns.terminal += std.time.nanoTimestamp() - started_ns;
                } else if (std.mem.eql(u8, panel.title, "Debug Stream") or
                    std.mem.eql(u8, panel.title, "Projects") or
                    std.mem.eql(u8, panel.title, "Filesystem Browser") or
                    std.mem.eql(u8, panel.title, "Filesystem Tools"))
                {
                    // Upgrade legacy ToolOutput-backed host panels in-place.
                    self.promoteLegacyHostPanel(manager, panel);
                    self.drawPanelContent(manager, panel_id, rect);
                } else if (std.mem.eql(u8, panel.title, "Terminal")) {
                    self.terminal_panel_id = panel.id;
                    const started_ns = std.time.nanoTimestamp();
                    self.drawTerminalPanel(manager, rect);
                    self.perf_frame_panel_ns.terminal += std.time.nanoTimestamp() - started_ns;
                } else {
                    const started_ns = std.time.nanoTimestamp();
                    self.drawText(
                        rect.min[0] + inset,
                        rect.min[1] + inset,
                        panel.title,
                        self.theme.colors.text_primary,
                    );
                    self.perf_frame_panel_ns.other += std.time.nanoTimestamp() - started_ns;
                }
            },
            else => {
                // Draw placeholder for other panel types
                const started_ns = std.time.nanoTimestamp();
                self.drawText(
                    rect.min[0] + inset,
                    rect.min[1] + inset,
                    panel.title,
                    self.theme.colors.text_primary,
                );
                self.perf_frame_panel_ns.other += std.time.nanoTimestamp() - started_ns;
            },
        }
    }

    const HostPanelRuntimeCtx = struct {
        app: *App,
    };

    fn drawHostPanelWithRuntime(self: *App, manager: *panel_manager.PanelManager, panel: *workspace.Panel, rect: UiRect) bool {
        if (panel.kind != .ProjectWorkspace and panel.kind != .FilesystemBrowser and panel.kind != .FilesystemTools and panel.kind != .DebugStream) {
            return false;
        }

        var runtime_ctx = HostPanelRuntimeCtx{ .app = self };
        var action: panels_bridge.UiAction = .{};
        var pending_attachment: ?panels_bridge.AttachmentOpen = null;
        const host_registry = panels_bridge.runtime.HostPanelRegistry{
            .project_workspace = .{ .ctx = @ptrCast(&runtime_ctx), .draw_fn = drawProjectWorkspaceHostPanel },
            .filesystem_browser = .{ .ctx = @ptrCast(&runtime_ctx), .draw_fn = drawFilesystemBrowserHostPanel },
            .filesystem_tools = .{ .ctx = @ptrCast(&runtime_ctx), .draw_fn = drawFilesystemToolsHostPanel },
            .debug_stream = .{ .ctx = @ptrCast(&runtime_ctx), .draw_fn = drawDebugStreamHostPanel },
        };
        _ = panels_bridge.runtime.drawHostPanel(
            self.allocator,
            panel,
            rect,
            manager,
            &action,
            &pending_attachment,
            &host_registry,
        );
        if (pending_attachment) |*value| {
            value.deinit(self.allocator);
        }
        return true;
    }

    fn drawProjectWorkspaceHostPanel(
        ctx: *anyopaque,
        allocator: std.mem.Allocator,
        panel: *workspace.Panel,
        panel_rect: ?UiRect,
        manager: *panel_manager.PanelManager,
        action: *panels_bridge.UiAction,
        pending_attachment: *?panels_bridge.AttachmentOpen,
    ) void {
        _ = allocator;
        _ = panel;
        _ = action;
        _ = pending_attachment;
        const runtime_ctx: *HostPanelRuntimeCtx = @ptrCast(@alignCast(ctx));
        runtime_ctx.app.drawProjectPanel(manager, panel_rect orelse return);
    }

    fn drawFilesystemBrowserHostPanel(
        ctx: *anyopaque,
        allocator: std.mem.Allocator,
        panel: *workspace.Panel,
        panel_rect: ?UiRect,
        manager: *panel_manager.PanelManager,
        action: *panels_bridge.UiAction,
        pending_attachment: *?panels_bridge.AttachmentOpen,
    ) void {
        _ = allocator;
        _ = panel;
        _ = action;
        _ = pending_attachment;
        const runtime_ctx: *HostPanelRuntimeCtx = @ptrCast(@alignCast(ctx));
        runtime_ctx.app.drawFilesystemPanel(manager, panel_rect orelse return);
    }

    fn drawFilesystemToolsHostPanel(
        ctx: *anyopaque,
        allocator: std.mem.Allocator,
        panel: *workspace.Panel,
        panel_rect: ?UiRect,
        manager: *panel_manager.PanelManager,
        action: *panels_bridge.UiAction,
        pending_attachment: *?panels_bridge.AttachmentOpen,
    ) void {
        _ = allocator;
        _ = panel;
        _ = action;
        _ = pending_attachment;
        const runtime_ctx: *HostPanelRuntimeCtx = @ptrCast(@alignCast(ctx));
        runtime_ctx.app.drawFilesystemToolsPanel(manager, panel_rect orelse return);
    }

    fn drawDebugStreamHostPanel(
        ctx: *anyopaque,
        allocator: std.mem.Allocator,
        panel: *workspace.Panel,
        panel_rect: ?UiRect,
        manager: *panel_manager.PanelManager,
        action: *panels_bridge.UiAction,
        pending_attachment: *?panels_bridge.AttachmentOpen,
    ) void {
        _ = allocator;
        _ = panel;
        _ = action;
        _ = pending_attachment;
        const runtime_ctx: *HostPanelRuntimeCtx = @ptrCast(@alignCast(ctx));
        runtime_ctx.app.drawDebugPanel(manager, panel_rect orelse return);
    }

    fn promoteLegacyHostPanel(self: *App, manager: *panel_manager.PanelManager, panel: *workspace.Panel) void {
        if (panel.kind != .ToolOutput) return;

        const target_kind: ?workspace.PanelKind = blk: {
            if (std.mem.eql(u8, panel.title, "Projects")) break :blk .ProjectWorkspace;
            if (std.mem.eql(u8, panel.title, "Filesystem Browser")) break :blk .FilesystemBrowser;
            if (std.mem.eql(u8, panel.title, "Filesystem Tools")) break :blk .FilesystemTools;
            if (std.mem.eql(u8, panel.title, "Debug Stream")) break :blk .DebugStream;
            break :blk null;
        };
        const kind = target_kind orelse return;

        panel.data.deinit(self.allocator);
        panel.kind = kind;
        panel.data = switch (kind) {
            .ProjectWorkspace => .{ .ProjectWorkspace = {} },
            .FilesystemBrowser => .{ .FilesystemBrowser = {} },
            .FilesystemTools => .{ .FilesystemTools = {} },
            .DebugStream => .{ .DebugStream = {} },
            else => unreachable,
        };
        switch (kind) {
            .ProjectWorkspace => self.project_panel_id = panel.id,
            .FilesystemBrowser => self.filesystem_panel_id = panel.id,
            .FilesystemTools => self.filesystem_tools_panel_id = panel.id,
            .DebugStream => self.debug_panel_id = panel.id,
            else => {},
        }
        manager.workspace.markDirty();
    }

    fn migrateLegacyHostPanels(self: *App, manager: *panel_manager.PanelManager) void {
        var changed = false;
        for (manager.workspace.panels.items) |*panel| {
            const before = panel.kind;
            self.promoteLegacyHostPanel(manager, panel);
            if (before != panel.kind) changed = true;
        }
        if (changed) {
            _ = manager.workspace.syncDockLayout() catch false;
            manager.workspace.markDirty();
        }
    }

    fn launcherSettingsDrawFormSectionTitle(
        ctx: *anyopaque,
        x: f32,
        y: *f32,
        max_w: f32,
        layout: PanelLayoutMetrics,
        text: []const u8,
    ) void {
        const self: *App = @ptrCast(@alignCast(ctx));
        self.drawFormSectionTitle(x, y, max_w, layout, text);
    }

    fn launcherSettingsDrawFormFieldLabel(
        ctx: *anyopaque,
        x: f32,
        y: *f32,
        max_w: f32,
        layout: PanelLayoutMetrics,
        text: []const u8,
    ) void {
        const self: *App = @ptrCast(@alignCast(ctx));
        self.drawFormFieldLabel(x, y, max_w, layout, text);
    }

    fn launcherSettingsDrawTextInput(
        ctx: *anyopaque,
        rect: Rect,
        text: []const u8,
        focused: bool,
        opts: widgets.text_input.Options,
    ) bool {
        const self: *App = @ptrCast(@alignCast(ctx));
        return self.drawTextInputWidget(rect, text, focused, opts);
    }

    fn launcherSettingsDrawButton(
        ctx: *anyopaque,
        rect: Rect,
        label: []const u8,
        opts: widgets.button.Options,
    ) bool {
        const self: *App = @ptrCast(@alignCast(ctx));
        return self.drawButtonWidget(rect, label, opts);
    }

    fn launcherSettingsDrawLabel(
        ctx: *anyopaque,
        x: f32,
        y: f32,
        text: []const u8,
        color: [4]f32,
    ) void {
        const self: *App = @ptrCast(@alignCast(ctx));
        self.drawLabel(x, y, text, color);
    }

    fn launcherSettingsDrawTextTrimmed(
        ctx: *anyopaque,
        x: f32,
        y: f32,
        max_w: f32,
        text: []const u8,
        color: [4]f32,
    ) void {
        const self: *App = @ptrCast(@alignCast(ctx));
        self.drawTextTrimmed(x, y, max_w, text, color);
    }

    fn launcherSettingsDrawVerticalScrollbar(
        ctx: *anyopaque,
        viewport_rect: Rect,
        content_height: f32,
        scroll_y: *f32,
    ) void {
        const self: *App = @ptrCast(@alignCast(ctx));
        self.drawVerticalScrollbar(.settings, viewport_rect, content_height, scroll_y);
    }

    fn projectDrawStatusRow(ctx: *anyopaque, rect: Rect) void {
        const self: *App = @ptrCast(@alignCast(ctx));
        self.drawStatusRow(rect);
    }

    fn projectDrawVerticalScrollbar(
        ctx: *anyopaque,
        viewport_rect: Rect,
        content_height: f32,
        scroll_y: *f32,
    ) void {
        const self: *App = @ptrCast(@alignCast(ctx));
        self.drawVerticalScrollbar(.projects, viewport_rect, content_height, scroll_y);
    }

    fn filesystemDrawSurfacePanel(ctx: *anyopaque, rect: Rect) void {
        const self: *App = @ptrCast(@alignCast(ctx));
        self.drawSurfacePanel(rect);
    }

    fn filesystemDrawFilledRect(ctx: *anyopaque, rect: Rect, color: [4]f32) void {
        const self: *App = @ptrCast(@alignCast(ctx));
        self.drawFilledRect(rect, color);
    }

    fn filesystemDrawRect(ctx: *anyopaque, rect: Rect, color: [4]f32) void {
        const self: *App = @ptrCast(@alignCast(ctx));
        self.drawRect(rect, color);
    }

    fn filesystemDrawTextWrapped(
        ctx: *anyopaque,
        x: f32,
        y: f32,
        max_w: f32,
        text: []const u8,
        color: [4]f32,
    ) f32 {
        const self: *App = @ptrCast(@alignCast(ctx));
        return self.drawTextWrapped(x, y, max_w, text, color);
    }

    fn terminalDrawOutput(ctx: *anyopaque, rect: Rect, inner: f32) void {
        const self: *App = @ptrCast(@alignCast(ctx));
        const host = TerminalOutputPanel.Host{
            .ctx = @ptrCast(self),
            .draw_text_trimmed = launcherSettingsDrawTextTrimmed,
            .draw_line = terminalDrawStyledLineAt,
        };
        TerminalOutputPanel.draw(
            host,
            rect,
            inner,
            .{ .text_secondary = self.theme.colors.text_secondary },
            .{
                .total_lines = self.terminal_backend.lineCount(),
                .line_height = self.textLineHeight(),
                .empty_text = "(terminal output empty)",
            },
        );
    }

    fn terminalDrawStyledLineAt(ctx: *anyopaque, line_index: usize, x: f32, y: f32, max_w: f32) void {
        const self: *App = @ptrCast(@alignCast(ctx));
        const line = self.terminal_backend.lineAt(line_index) orelse return;
        self.drawTerminalStyledLine(x, y, max_w, line);
    }

    fn debugDrawPerfCharts(
        ctx: *anyopaque,
        rect: Rect,
        layout: PanelLayoutMetrics,
        y: f32,
        perf_charts: []const panels_bridge.DebugSparklineSeriesView,
    ) f32 {
        const self: *App = @ptrCast(@alignCast(ctx));
        return self.drawDebugPerfCharts(rect, layout, y, perf_charts);
    }

    fn debugDrawEventStream(
        ctx: *anyopaque,
        output_rect: Rect,
        view: panels_bridge.DebugEventStreamView,
    ) void {
        const self: *App = @ptrCast(@alignCast(ctx));
        self.drawDebugEventStream(output_rect, view);
    }

    fn debugEventStreamSetOutputRect(ctx: *anyopaque, rect: Rect) void {
        const self: *App = @ptrCast(@alignCast(ctx));
        self.debug_output_rect = rect;
    }

    fn debugEventStreamFocusPanel(ctx: *anyopaque) void {
        const self: *App = @ptrCast(@alignCast(ctx));
        if (self.debug_panel_id) |panel_id| self.manager.focusPanel(panel_id);
    }

    fn debugEventStreamPushClip(ctx: *anyopaque, rect: Rect) void {
        const self: *App = @ptrCast(@alignCast(ctx));
        self.ui_commands.pushClip(.{ .min = rect.min, .max = rect.max });
    }

    fn debugEventStreamPopClip(ctx: *anyopaque) void {
        const self: *App = @ptrCast(@alignCast(ctx));
        self.ui_commands.popClip();
    }

    fn debugEventStreamDrawFilledRect(ctx: *anyopaque, rect: Rect, color: [4]f32) void {
        const self: *App = @ptrCast(@alignCast(ctx));
        self.drawFilledRect(rect, color);
    }

    fn debugEventStreamGetScrollY(ctx: *anyopaque) f32 {
        const self: *App = @ptrCast(@alignCast(ctx));
        return self.debug_scroll_y;
    }

    fn debugEventStreamSetScrollY(ctx: *anyopaque, value: f32) void {
        const self: *App = @ptrCast(@alignCast(ctx));
        self.debug_scroll_y = value;
    }

    fn debugEventStreamGetScrollbarDragging(ctx: *anyopaque) bool {
        const self: *App = @ptrCast(@alignCast(ctx));
        return self.debug_scrollbar_dragging;
    }

    fn debugEventStreamSetScrollbarDragging(ctx: *anyopaque, value: bool) void {
        const self: *App = @ptrCast(@alignCast(ctx));
        self.debug_scrollbar_dragging = value;
    }

    fn debugEventStreamGetDragStartY(ctx: *anyopaque) f32 {
        const self: *App = @ptrCast(@alignCast(ctx));
        return self.debug_scrollbar_drag_start_y;
    }

    fn debugEventStreamSetDragStartY(ctx: *anyopaque, value: f32) void {
        const self: *App = @ptrCast(@alignCast(ctx));
        self.debug_scrollbar_drag_start_y = value;
    }

    fn debugEventStreamGetDragStartScrollY(ctx: *anyopaque) f32 {
        const self: *App = @ptrCast(@alignCast(ctx));
        return self.debug_scrollbar_drag_start_scroll_y;
    }

    fn debugEventStreamSetDragStartScrollY(ctx: *anyopaque, value: f32) void {
        const self: *App = @ptrCast(@alignCast(ctx));
        self.debug_scrollbar_drag_start_scroll_y = value;
    }

    fn debugEventStreamSetDragCapture(ctx: *anyopaque, capture: bool) void {
        const self: *App = @ptrCast(@alignCast(ctx));
        self.setDragMouseCapture(capture);
    }

    fn debugEventStreamReleaseDragCapture(ctx: *anyopaque) void {
        const self: *App = @ptrCast(@alignCast(ctx));
        if (self.form_scroll_drag_target == .none) self.setDragMouseCapture(false);
    }

    fn debugEventStreamEntryHeight(
        ctx: *anyopaque,
        filtered_index: usize,
        content_min_x: f32,
        content_max_x: f32,
        selected: bool,
    ) f32 {
        const self: *App = @ptrCast(@alignCast(ctx));
        if (filtered_index >= self.debug_events.items.len) return 0.0;
        const layout = self.panelLayoutMetrics();
        const entry = &self.debug_events.items[filtered_index];
        const payload_visible_rows = if (selected)
            self.countVisibleDebugPayloadRows(content_min_x, content_max_x, entry)
        else
            0;
        const visible_lines = 1 + payload_visible_rows;
        return layout.line_height * @as(f32, @floatFromInt(visible_lines));
    }

    fn debugEventStreamDrawEntry(
        ctx: *anyopaque,
        filtered_index: usize,
        content_min_x: f32,
        y: f32,
        content_max_x: f32,
        output_rect: Rect,
        selected: bool,
        pointer: DebugEventStreamPanel.PointerState,
    ) bool {
        const self: *App = @ptrCast(@alignCast(ctx));
        if (filtered_index >= self.debug_events.items.len) return false;
        const layout = self.panelLayoutMetrics();
        const line_height = layout.line_height;
        const entry = &self.debug_events.items[filtered_index];
        if (selected) self.ensureDebugPayloadLines(entry);
        self.drawDebugEventHeaderLine(content_min_x, y, content_max_x, entry.*);
        var clicked_fold_marker = false;
        const payload_visible_rows = if (selected)
            self.countVisibleDebugPayloadRows(content_min_x, content_max_x, entry)
        else
            0;
        if (selected and payload_visible_rows > 0) {
            self.ensureDebugPayloadWrapRows(content_min_x, content_max_x, entry);
            self.ensureDebugVisiblePayloadLines(content_min_x, content_max_x, entry);
            const enable_syntax_color = entry.payload_json.len <= DEBUG_SYNTAX_COLOR_MAX_PAYLOAD_BYTES;
            const space_w = self.measureText(" ");
            const fold_marker_w_open = self.measureText("[-]");
            const fold_marker_w_closed = self.measureText("[+]");

            const body_top_y = y + line_height;
            const min_row: usize = if (output_rect.min[1] <= body_top_y)
                0
            else
                @as(usize, @intFromFloat((output_rect.min[1] - body_top_y) / line_height));
            const max_row_exclusive: usize = if (output_rect.max[1] <= body_top_y)
                0
            else
                @as(usize, @intFromFloat(((output_rect.max[1] - body_top_y) / line_height) + 1.0));

            var visible_idx = findFirstVisiblePayloadLine(entry, min_row);
            while (visible_idx < entry.payload_visible_line_indices.items.len) : (visible_idx += 1) {
                const payload_line_idx = @as(usize, @intCast(entry.payload_visible_line_indices.items[visible_idx]));
                const row_start = @as(usize, @intCast(entry.payload_visible_line_row_starts.items[visible_idx]));
                if (row_start >= max_row_exclusive) break;

                _ = payloadLineRowsFromCache(entry, payload_line_idx);
                const line_y = body_top_y + @as(f32, @floatFromInt(row_start)) * line_height;
                if (line_y > output_rect.max[1]) break;

                const meta = entry.payload_lines.items[payload_line_idx];
                const can_fold = meta.opens_block and meta.matching_close_index != null and
                    @as(usize, @intCast(meta.matching_close_index.?)) > payload_line_idx + 1;
                const collapsed = can_fold and self.isDebugBlockCollapsed(entry.id, payload_line_idx);

                const line = entry.payload_json[meta.start..meta.end];
                const indent_width = @as(f32, @floatFromInt(meta.indent_spaces)) * space_w;
                const line_x_base = content_min_x + indent_width;
                const content_start = @min(meta.indent_spaces, line.len);
                const content = line[content_start..];
                var text_x = line_x_base;
                if (can_fold) {
                    const marker = if (collapsed) "[+]" else "[-]";
                    const marker_w = if (collapsed) fold_marker_w_closed else fold_marker_w_open;
                    const marker_rect = Rect.fromXYWH(line_x_base, line_y, marker_w, line_height);
                    const marker_hovered = marker_rect.contains(.{ pointer.mouse_x, pointer.mouse_y });
                    if (pointer.mouse_clicked and marker_hovered) {
                        self.toggleDebugBlockCollapsed(entry.id, payload_line_idx);
                        clicked_fold_marker = true;
                    }

                    const marker_color = if (marker_hovered)
                        zcolors.blend(self.theme.colors.primary, self.theme.colors.text_primary, 0.22)
                    else
                        self.theme.colors.primary;
                    self.drawText(line_x_base, line_y, marker, marker_color);
                    text_x = line_x_base + marker_w + space_w;
                }

                if (enable_syntax_color and content.len <= DEBUG_SYNTAX_COLOR_MAX_LINE_BYTES) {
                    _ = self.drawJsonLineColored(text_x, line_y, content_max_x, content);
                } else {
                    _ = self.drawTextWrapped(
                        text_x,
                        line_y,
                        @max(1.0, content_max_x - text_x),
                        content,
                        self.theme.colors.text_primary,
                    );
                }
            }
        }
        return clicked_fold_marker;
    }

    fn debugEventStreamSelectEntry(ctx: *anyopaque, filtered_index: usize) void {
        const self: *App = @ptrCast(@alignCast(ctx));
        if (self.debug_selected_index == null or self.debug_selected_index.? != filtered_index) {
            self.debug_selected_index = filtered_index;
            self.clearSelectedNodeServiceEventCache();
        }
    }

    fn debugEventStreamCopySelectedEvent(ctx: *anyopaque) void {
        const self: *App = @ptrCast(@alignCast(ctx));
        self.performDebugPanelAction(&self.manager, .copy_selected_event);
    }

    fn debugEventStreamSelectedEventCount(ctx: *anyopaque) usize {
        const self: *App = @ptrCast(@alignCast(ctx));
        if (self.debug_selected_index) |sel_idx| {
            return if (sel_idx < self.debug_events.items.len) 1 else 0;
        }
        return 0;
    }

    fn drawSettingsPanel(self: *App, manager: *panel_manager.PanelManager, rect: UiRect) void {
        if (self.ui_stage == .workspace) {
            self.drawWorkspaceSettingsPanel(rect);
            return;
        }
        const host = LauncherSettingsPanel.Host{
            .ctx = @ptrCast(self),
            .draw_form_section_title = launcherSettingsDrawFormSectionTitle,
            .draw_form_field_label = launcherSettingsDrawFormFieldLabel,
            .draw_text_input = launcherSettingsDrawTextInput,
            .draw_button = launcherSettingsDrawButton,
            .draw_label = launcherSettingsDrawLabel,
            .draw_text_trimmed = launcherSettingsDrawTextTrimmed,
            .draw_vertical_scrollbar = launcherSettingsDrawVerticalScrollbar,
        };
        const panel_rect = Rect{ .min = rect.min, .max = rect.max };
        var panel_state = LauncherSettingsPanel.State{
            .focused_field = settingsFocusFieldToExternal(self.settings_panel.focused_field),
            .scroll_y = self.settings_panel.settings_scroll_y,
        };
        const action = LauncherSettingsPanel.draw(
            host,
            panel_rect,
            self.panelLayoutMetrics(),
            self.ui_scale,
            .{
                .text_primary = self.theme.colors.text_primary,
                .text_secondary = self.theme.colors.text_secondary,
            },
            self.launcherSettingsModel(),
            .{
                .server_url = self.settings_panel.server_url.items,
                .default_session = self.settings_panel.default_session.items,
                .default_agent = self.settings_panel.default_agent.items,
                .ui_theme = self.settings_panel.ui_theme.items,
                .ui_profile = self.settings_panel.ui_profile.items,
                .ui_theme_pack = self.settings_panel.ui_theme_pack.items,
            },
            .{
                .mouse_x = self.mouse_x,
                .mouse_y = self.mouse_y,
                .mouse_released = self.mouse_released,
            },
            &panel_state,
            .launcher,
        );
        const mapped_focus = settingsFocusFieldFromExternal(panel_state.focused_field);
        if (mapped_focus != .none or isSettingsPanelFocusField(self.settings_panel.focused_field)) {
            self.settings_panel.focused_field = mapped_focus;
        }
        self.settings_panel.settings_scroll_y = panel_state.scroll_y;
        if (action) |value| {
            self.performLauncherSettingsAction(manager, value);
        }
    }

    fn drawWorkspaceSettingsPanel(self: *App, rect: UiRect) void {
        const host = LauncherSettingsPanel.Host{
            .ctx = @ptrCast(self),
            .draw_form_section_title = launcherSettingsDrawFormSectionTitle,
            .draw_form_field_label = launcherSettingsDrawFormFieldLabel,
            .draw_text_input = launcherSettingsDrawTextInput,
            .draw_button = launcherSettingsDrawButton,
            .draw_label = launcherSettingsDrawLabel,
            .draw_text_trimmed = launcherSettingsDrawTextTrimmed,
            .draw_vertical_scrollbar = launcherSettingsDrawVerticalScrollbar,
        };
        const panel_rect = Rect{ .min = rect.min, .max = rect.max };
        var panel_state = LauncherSettingsPanel.State{
            .focused_field = settingsFocusFieldToExternal(self.settings_panel.focused_field),
            .scroll_y = self.settings_panel.settings_scroll_y,
        };
        const action = LauncherSettingsPanel.draw(
            host,
            panel_rect,
            self.panelLayoutMetrics(),
            self.ui_scale,
            .{
                .text_primary = self.theme.colors.text_primary,
                .text_secondary = self.theme.colors.text_secondary,
            },
            self.launcherSettingsModel(),
            .{
                .ui_theme = self.settings_panel.ui_theme.items,
                .ui_profile = self.settings_panel.ui_profile.items,
                .ui_theme_pack = self.settings_panel.ui_theme_pack.items,
            },
            .{
                .mouse_x = self.mouse_x,
                .mouse_y = self.mouse_y,
                .mouse_released = self.mouse_released,
            },
            &panel_state,
            .workspace,
        );
        const mapped_focus = settingsFocusFieldFromExternal(panel_state.focused_field);
        if (mapped_focus != .none or isSettingsPanelFocusField(self.settings_panel.focused_field)) {
            self.settings_panel.focused_field = mapped_focus;
        }
        self.settings_panel.settings_scroll_y = panel_state.scroll_y;
        if (action) |value| {
            self.performLauncherSettingsAction(&self.manager, value);
        }
    }

    fn drawProjectPanel(self: *App, manager: *panel_manager.PanelManager, rect: UiRect) void {
        _ = manager;
        var view = self.buildProjectPanelView();
        defer view.deinit(self.allocator);
        const host = ProjectPanel.Host{
            .ctx = @ptrCast(self),
            .draw_form_section_title = launcherSettingsDrawFormSectionTitle,
            .draw_form_field_label = launcherSettingsDrawFormFieldLabel,
            .draw_text_input = launcherSettingsDrawTextInput,
            .draw_button = launcherSettingsDrawButton,
            .draw_label = launcherSettingsDrawLabel,
            .draw_text_trimmed = launcherSettingsDrawTextTrimmed,
            .draw_status_row = projectDrawStatusRow,
            .draw_vertical_scrollbar = projectDrawVerticalScrollbar,
        };
        var panel_state = ProjectPanel.State{
            .focused_field = projectFocusFieldToExternal(self.settings_panel.focused_field),
            .scroll_y = self.settings_panel.projects_scroll_y,
        };
        const action = ProjectPanel.draw(
            host,
            Rect{ .min = rect.min, .max = rect.max },
            self.panelLayoutMetrics(),
            self.ui_scale,
            .{
                .text_primary = self.theme.colors.text_primary,
                .text_secondary = self.theme.colors.text_secondary,
                .warning_text = zcolors.rgba(236, 174, 36, 255),
                .error_text = zcolors.rgba(220, 80, 80, 255),
            },
            self.projectPanelModel(),
            view.view,
            .{
                .project_token = self.settings_panel.project_token.items,
                .create_name = self.settings_panel.project_create_name.items,
                .create_vision = self.settings_panel.project_create_vision.items,
                .operator_token = self.settings_panel.project_operator_token.items,
                .mount_path = self.settings_panel.project_mount_path.items,
                .mount_node_id = self.settings_panel.project_mount_node_id.items,
                .mount_export_name = self.settings_panel.project_mount_export_name.items,
            },
            .{
                .mouse_x = self.mouse_x,
                .mouse_y = self.mouse_y,
                .mouse_released = self.mouse_released,
            },
            &panel_state,
        );
        const mapped_focus = projectFocusFieldFromExternal(panel_state.focused_field);
        if (mapped_focus != .none or isProjectPanelFocusField(self.settings_panel.focused_field)) {
            self.settings_panel.focused_field = mapped_focus;
        }
        self.settings_panel.projects_scroll_y = panel_state.scroll_y;
        if (action) |value| self.performProjectPanelAction(value);
    }

    fn pathWithinMount(path: []const u8, mount_path: []const u8) bool {
        if (std.mem.eql(u8, mount_path, "/")) return std.mem.startsWith(u8, path, "/");
        if (!std.mem.startsWith(u8, path, mount_path)) return false;
        if (path.len == mount_path.len) return true;
        return path.len > mount_path.len and path[mount_path.len] == '/';
    }

    const WorkspaceHealthState = enum {
        healthy,
        degraded,
        missing,
        unknown,
    };

    fn workspaceHealthState(status: *const workspace_types.WorkspaceStatus) WorkspaceHealthState {
        if (status.availability_missing > 0) return .missing;
        const reconcile_state = status.reconcile_state orelse "";
        if (status.availability_degraded > 0 or
            status.drift_count > 0 or
            status.queue_depth > 0 or
            std.mem.eql(u8, reconcile_state, "degraded"))
        {
            return .degraded;
        }
        if (status.availability_mounts_total == 0 or std.mem.eql(u8, reconcile_state, "unknown")) return .unknown;
        return .healthy;
    }

    fn workspaceHealthStateLabel(state: WorkspaceHealthState) []const u8 {
        return switch (state) {
            .healthy => "healthy",
            .degraded => "degraded",
            .missing => "missing",
            .unknown => "unknown",
        };
    }

    fn findMountForPath(self: *App, path: []const u8) ?*const workspace_types.MountView {
        if (self.workspace_state) |*status| {
            var best: ?*const workspace_types.MountView = null;
            var best_len: usize = 0;
            for (status.mounts.items) |*mount| {
                if (!pathWithinMount(path, mount.mount_path)) continue;
                if (mount.mount_path.len > best_len) {
                    best = mount;
                    best_len = mount.mount_path.len;
                }
            }
            return best;
        }
        return null;
    }

    fn setFilesystemPath(self: *App, path: []const u8) !void {
        const existing = self.filesystem_path.items;
        const aliases_existing =
            existing.len > 0 and
            path.len > 0 and
            slicesOverlap(existing, path);
        const safe_path = if (aliases_existing)
            try self.allocator.dupe(u8, path)
        else
            path;
        defer if (aliases_existing) self.allocator.free(safe_path);

        self.filesystem_path.clearRetainingCapacity();
        if (safe_path.len == 0) {
            try self.filesystem_path.appendSlice(self.allocator, "/");
        } else {
            try self.filesystem_path.appendSlice(self.allocator, safe_path);
        }
    }

    fn slicesOverlap(a: []const u8, b: []const u8) bool {
        const a_start = @intFromPtr(a.ptr);
        const a_end = a_start + a.len;
        const b_start = @intFromPtr(b.ptr);
        const b_end = b_start + b.len;
        return a_start < b_end and b_start < a_end;
    }

    fn mapWorkspaceRootToFilesystemPath(self: *App, workspace_root: []const u8) ![]u8 {
        const trimmed = std.mem.trim(u8, workspace_root, " \t\r\n");
        if (trimmed.len == 0) return self.allocator.dupe(u8, "/");
        return self.allocator.dupe(u8, trimmed);
    }

    fn normalizeFilesystemPath(self: *App, path: []const u8) ![]u8 {
        const trimmed = std.mem.trim(u8, path, " \t\r\n");
        if (trimmed.len == 0) return self.allocator.dupe(u8, "/");
        return self.allocator.dupe(u8, trimmed);
    }

    fn applyCachedFilesystemListing(self: *App, path: []const u8) bool {
        const listing = self.cachedFilesystemListing(path) orelse return false;
        self.applyFilesystemListing(path, listing) catch return false;
        return true;
    }

    fn queueFilesystemPathLoad(
        self: *App,
        path: []const u8,
        use_cache: bool,
        force_refresh: bool,
    ) !void {
        const normalized_path = try self.normalizeFilesystemPath(path);
        defer self.allocator.free(normalized_path);

        try self.setFilesystemPath(normalized_path);
        self.clearFsrpcRemoteError();
        self.clearFilesystemError();

        if (force_refresh) {
            self.invalidateFilesystemDirCachePath(normalized_path);
        } else if (use_cache) {
            _ = self.applyCachedFilesystemListing(normalized_path);
        }

        self.submitFilesystemRequest(.list_dir, normalized_path, false) catch |err| {
            if (err == error.Busy) {
                self.schedulePendingFilesystemPathLoad(normalized_path, use_cache, force_refresh);
                return;
            }
            return err;
        };
    }

    fn refreshFilesystemBrowser(self: *App) !void {
        if (self.filesystem_path.items.len == 0) {
            try self.filesystem_path.appendSlice(self.allocator, "/");
        }
        self.requestFilesystemBrowserRefresh(true);
    }

    fn openFilesystemEntry(self: *App, entry: *const FilesystemEntry) !void {
        self.clearFsrpcRemoteError();
        self.setFilesystemSelectedPath(entry.path);
        switch (entry.kind) {
            .directory => try self.queueFilesystemPathLoad(entry.path, true, false),
            .file => {
                if (entry.previewable) {
                    try self.setFilesystemPreviewPlaceholder(
                        entry.path,
                        entry.kind,
                        entry.size_bytes,
                        entry.modified_unix_ms,
                        .loading,
                        "Loading preview…",
                    );
                    try self.submitFilesystemRequest(.read_file, entry.path, false);
                } else {
                    try self.setFilesystemPreviewPlaceholder(
                        entry.path,
                        entry.kind,
                        entry.size_bytes,
                        entry.modified_unix_ms,
                        .unsupported,
                        "Preview unavailable for this file type.",
                    );
                }
            },
            .unknown => {
                try self.setFilesystemPreviewPlaceholder(
                    entry.path,
                    entry.kind,
                    entry.size_bytes,
                    entry.modified_unix_ms,
                    .loading,
                    "Resolving filesystem entry…",
                );
                try self.submitFilesystemRequest(.resolve_kind, entry.path, true);
            },
        }
    }

    fn updateFilesystemEntryKind(self: *App, path: []const u8, kind: FilesystemEntryKind) void {
        for (self.filesystem_entries.items) |*item| {
            if (!std.mem.eql(u8, item.path, path)) continue;
            const next_label = self.allocFilesystemTypeLabel(item.name, kind) catch null;
            item.kind = kind;
            if (next_label) |value| {
                self.allocator.free(item.type_label);
                item.type_label = value;
            }
            item.previewable = filesystemPreviewableName(item.name, kind);
            return;
        }
    }

    fn filesystemEntryExists(self: *App, name: []const u8) bool {
        for (self.filesystem_entries.items) |entry| {
            if (std.mem.eql(u8, entry.name, name)) return true;
        }
        return false;
    }

    fn filesystemHasServiceRuntimeRoot(self: *App) bool {
        return self.filesystemEntryExists("control") and
            self.filesystemEntryExists("status.json") and
            self.filesystemEntryExists("health.json");
    }

    fn filesystemServiceRuntimePath(self: *App, name: []const u8) ![]u8 {
        const current_path = if (self.filesystem_path.items.len > 0) self.filesystem_path.items else "/";
        return self.joinFilesystemPath(current_path, name);
    }

    fn readFilesystemServiceRuntimeFile(self: *App, name: []const u8) !void {
        const client = if (self.ws_client) |*value| value else return error.NotConnected;
        try self.fsrpcBootstrapGui(client);
        const path = try self.filesystemServiceRuntimePath(name);
        defer self.allocator.free(path);
        const content = try self.readFsPathTextGui(client, path);
        defer self.allocator.free(content);
        try self.applyFilesystemPreview(path, content);
        self.clearFilesystemError();
    }

    fn writeFilesystemServiceRuntimeControl(self: *App, name: []const u8, payload: []const u8) !void {
        const client = if (self.ws_client) |*value| value else return error.NotConnected;
        try self.fsrpcBootstrapGui(client);

        const control_dir = try self.filesystemServiceRuntimePath("control");
        defer self.allocator.free(control_dir);
        const control_path = try self.joinFilesystemPath(control_dir, name);
        defer self.allocator.free(control_path);
        try self.writeFsPathTextGui(client, control_path, payload);

        if (std.mem.eql(u8, name, "invoke.json")) {
            const result_path = try self.filesystemServiceRuntimePath("result.json");
            defer self.allocator.free(result_path);
            const result = try self.readFsPathTextGui(client, result_path);
            defer self.allocator.free(result);
            try self.applyFilesystemPreview(result_path, result);
        } else {
            const status_path = try self.filesystemServiceRuntimePath("status.json");
            defer self.allocator.free(status_path);
            const status = try self.readFsPathTextGui(client, status_path);
            defer self.allocator.free(status);
            try self.applyFilesystemPreview(status_path, status);
        }

        self.clearFilesystemError();
    }

    fn selectedContractService(self: *App) ?*const ContractServiceEntry {
        if (self.contract_services.items.len == 0) return null;
        if (self.contract_service_selected_index >= self.contract_services.items.len) return null;
        return &self.contract_services.items[self.contract_service_selected_index];
    }

    fn contractStatusPathFromInvokePath(self: *App, invoke_path: []const u8) ![]u8 {
        const suffix = "/control/invoke.json";
        if (std.mem.endsWith(u8, invoke_path, suffix)) {
            const base = invoke_path[0 .. invoke_path.len - suffix.len];
            return std.fmt.allocPrint(self.allocator, "{s}/status.json", .{base});
        }
        const invoke_suffix = "/invoke.json";
        if (std.mem.endsWith(u8, invoke_path, invoke_suffix)) {
            const base = invoke_path[0 .. invoke_path.len - invoke_suffix.len];
            return std.fmt.allocPrint(self.allocator, "{s}/status.json", .{base});
        }
        return error.InvalidPath;
    }

    fn contractResultPathFromInvokePath(self: *App, invoke_path: []const u8) ![]u8 {
        const suffix = "/control/invoke.json";
        if (std.mem.endsWith(u8, invoke_path, suffix)) {
            const base = invoke_path[0 .. invoke_path.len - suffix.len];
            return std.fmt.allocPrint(self.allocator, "{s}/result.json", .{base});
        }
        const invoke_suffix = "/invoke.json";
        if (std.mem.endsWith(u8, invoke_path, invoke_suffix)) {
            const base = invoke_path[0 .. invoke_path.len - invoke_suffix.len];
            return std.fmt.allocPrint(self.allocator, "{s}/result.json", .{base});
        }
        return error.InvalidPath;
    }

    fn refreshContractServices(self: *App) !void {
        const client = if (self.ws_client) |*value| value else return error.NotConnected;
        try self.fsrpcBootstrapGui(client);
        const payload = try self.readFsPathTextGui(client, "/agents/self/services/SERVICES.json");
        defer self.allocator.free(payload);

        var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, payload, .{});
        defer parsed.deinit();
        if (parsed.value != .array) return error.InvalidResponse;

        self.clearContractServices();
        for (parsed.value.array.items) |entry| {
            if (entry != .object) continue;
            const obj = entry.object;
            const scope = if (obj.get("scope")) |value| switch (value) {
                .string => value.string,
                else => continue,
            } else continue;
            if (!std.mem.eql(u8, scope, "agent_contract")) continue;
            const has_invoke = if (obj.get("has_invoke")) |value| switch (value) {
                .bool => value.bool,
                else => false,
            } else false;
            if (!has_invoke) continue;

            const service_id = if (obj.get("service_id")) |value| switch (value) {
                .string => value.string,
                else => continue,
            } else continue;
            const service_path = if (obj.get("service_path")) |value| switch (value) {
                .string => value.string,
                else => continue,
            } else continue;
            const invoke_path = if (obj.get("invoke_path")) |value| switch (value) {
                .string => value.string,
                else => continue,
            } else continue;
            if (invoke_path.len == 0) continue;

            const help_path = try self.joinFilesystemPath(service_path, "README.md");
            errdefer self.allocator.free(help_path);
            const schema_path = try self.joinFilesystemPath(service_path, "SCHEMA.json");
            errdefer self.allocator.free(schema_path);
            const template_path = try self.joinFilesystemPath(service_path, "TEMPLATE.json");
            errdefer self.allocator.free(template_path);

            try self.contract_services.append(self.allocator, .{
                .service_id = try self.allocator.dupe(u8, service_id),
                .service_path = try self.allocator.dupe(u8, service_path),
                .invoke_path = try self.allocator.dupe(u8, invoke_path),
                .help_path = help_path,
                .schema_path = schema_path,
                .template_path = template_path,
            });
        }

        if (self.contract_services.items.len == 0) {
            self.contract_service_selected_index = 0;
        } else if (self.contract_service_selected_index >= self.contract_services.items.len) {
            self.contract_service_selected_index = 0;
        }
        self.clearFilesystemError();
    }

    fn readSelectedContractServiceStatus(self: *App) !void {
        const entry = self.selectedContractService() orelse return error.MissingField;
        const client = if (self.ws_client) |*value| value else return error.NotConnected;
        try self.fsrpcBootstrapGui(client);
        const status_path = try self.contractStatusPathFromInvokePath(entry.invoke_path);
        defer self.allocator.free(status_path);
        const status = try self.readFsPathTextGui(client, status_path);
        defer self.allocator.free(status);
        try self.applyFilesystemPreview(status_path, status);
        self.clearFilesystemError();
    }

    fn readContractServiceFileWithFallback(
        self: *App,
        client: *ws_client_mod.WebSocketClient,
        primary_path: []const u8,
        fallback_path: ?[]const u8,
    ) ![]u8 {
        return self.readFsPathTextGui(client, primary_path) catch |primary_err| {
            if (fallback_path) |path| return self.readFsPathTextGui(client, path);
            return primary_err;
        };
    }

    fn readSelectedContractServiceHelp(self: *App) !void {
        const entry = self.selectedContractService() orelse return error.MissingField;
        const client = if (self.ws_client) |*value| value else return error.NotConnected;
        try self.fsrpcBootstrapGui(client);
        const content = try self.readContractServiceFileWithFallback(client, entry.help_path, null);
        defer self.allocator.free(content);
        try self.applyFilesystemPreview(entry.help_path, content);
        self.clearFilesystemError();
    }

    fn readSelectedContractServiceSchema(self: *App) !void {
        const entry = self.selectedContractService() orelse return error.MissingField;
        const client = if (self.ws_client) |*value| value else return error.NotConnected;
        try self.fsrpcBootstrapGui(client);
        const fallback = try self.joinFilesystemPath(entry.service_path, "schema.json");
        defer self.allocator.free(fallback);
        const content = try self.readContractServiceFileWithFallback(client, entry.schema_path, fallback);
        defer self.allocator.free(content);
        try self.applyFilesystemPreview(entry.schema_path, content);
        self.clearFilesystemError();
    }

    fn useSelectedContractServiceTemplate(self: *App) !void {
        const entry = self.selectedContractService() orelse return error.MissingField;
        const client = if (self.ws_client) |*value| value else return error.NotConnected;
        try self.fsrpcBootstrapGui(client);
        const fallback = try self.joinFilesystemPath(entry.service_path, "template.json");
        defer self.allocator.free(fallback);
        const template_text = try self.readContractServiceFileWithFallback(client, entry.template_path, fallback);
        defer self.allocator.free(template_text);
        const trimmed = std.mem.trim(u8, template_text, " \t\r\n");
        const payload = if (trimmed.len > 0) trimmed else "{}";
        self.contract_invoke_payload.clearRetainingCapacity();
        try self.contract_invoke_payload.appendSlice(self.allocator, payload);
        try self.applyFilesystemPreview(entry.template_path, payload);
        self.clearFilesystemError();
    }

    fn readSelectedContractServiceResult(self: *App) !void {
        const entry = self.selectedContractService() orelse return error.MissingField;
        const client = if (self.ws_client) |*value| value else return error.NotConnected;
        try self.fsrpcBootstrapGui(client);
        const result_path = try self.contractResultPathFromInvokePath(entry.invoke_path);
        defer self.allocator.free(result_path);
        const result = try self.readFsPathTextGui(client, result_path);
        defer self.allocator.free(result);
        try self.applyFilesystemPreview(result_path, result);
        self.clearFilesystemError();
    }

    fn invokeSelectedContractService(self: *App) !void {
        const entry = self.selectedContractService() orelse return error.MissingField;
        const client = if (self.ws_client) |*value| value else return error.NotConnected;
        try self.fsrpcBootstrapGui(client);

        const payload_trimmed = std.mem.trim(u8, self.contract_invoke_payload.items, " \t\r\n");
        const payload = if (payload_trimmed.len > 0) payload_trimmed else "{}";
        try self.writeFsPathTextGui(client, entry.invoke_path, payload);

        const status_path = try self.contractStatusPathFromInvokePath(entry.invoke_path);
        defer self.allocator.free(status_path);
        const status = try self.readFsPathTextGui(client, status_path);
        defer self.allocator.free(status);

        const result_path = try self.contractResultPathFromInvokePath(entry.invoke_path);
        defer self.allocator.free(result_path);
        const result = try self.readFsPathTextGui(client, result_path);
        defer self.allocator.free(result);
        try self.applyFilesystemPreview(result_path, result);
        self.clearFilesystemError();
    }

    fn openSelectedContractServicePath(self: *App) !void {
        const entry = self.selectedContractService() orelse return error.MissingField;
        try self.queueFilesystemPathLoad(entry.service_path, true, false);
    }

    fn writeTerminalControl(self: *App, control_name: []const u8, payload: []const u8) !void {
        const client = if (self.ws_client) |*value| value else return error.NotConnected;
        try self.fsrpcBootstrapGui(client);
        const control_path = try std.fmt.allocPrint(
            self.allocator,
            "/agents/self/terminal/control/{s}",
            .{control_name},
        );
        defer self.allocator.free(control_path);
        try self.writeFsPathTextGui(client, control_path, payload);
    }

    fn readTerminalPath(self: *App, path: []const u8) ![]u8 {
        const client = if (self.ws_client) |*value| value else return error.NotConnected;
        try self.fsrpcBootstrapGui(client);
        return self.readFsPathTextGui(client, path);
    }

    fn ensureTerminalSession(self: *App) !void {
        if (self.terminal_session_id != null) return;

        const session_id = try std.fmt.allocPrint(self.allocator, "gui-{d}", .{std.time.milliTimestamp()});
        defer self.allocator.free(session_id);
        const escaped_session = try jsonEscape(self.allocator, session_id);
        defer self.allocator.free(escaped_session);

        const payload = try std.fmt.allocPrint(
            self.allocator,
            "{{\"session_id\":\"{s}\",\"label\":\"spider-gui\"}}",
            .{escaped_session},
        );
        defer self.allocator.free(payload);
        try self.writeTerminalControl("create.json", payload);

        self.clearTerminalState();
        self.terminal_session_id = try self.allocator.dupe(u8, session_id);
        self.setTerminalStatus("Terminal session ready");
        self.terminal_next_poll_at_ms = std.time.milliTimestamp() + TERMINAL_READ_POLL_INTERVAL_MS;
    }

    fn closeTerminalSession(self: *App) !void {
        if (self.terminal_session_id == null) return;
        const session_id = self.terminal_session_id.?;
        const escaped_session = try jsonEscape(self.allocator, session_id);
        defer self.allocator.free(escaped_session);
        const payload = try std.fmt.allocPrint(
            self.allocator,
            "{{\"session_id\":\"{s}\"}}",
            .{escaped_session},
        );
        defer self.allocator.free(payload);
        try self.writeTerminalControl("close.json", payload);
        self.clearTerminalState();
        self.setTerminalStatus("Terminal session closed");
    }

    fn resizeTerminalSession(self: *App, cols: u32, rows: u32) !void {
        if (self.terminal_session_id == null) return error.InvalidState;
        const session_id = self.terminal_session_id.?;
        const escaped_session = try jsonEscape(self.allocator, session_id);
        defer self.allocator.free(escaped_session);
        const payload = try std.fmt.allocPrint(
            self.allocator,
            "{{\"session_id\":\"{s}\",\"cols\":{d},\"rows\":{d}}}",
            .{ escaped_session, cols, rows },
        );
        defer self.allocator.free(payload);
        try self.writeTerminalControl("resize.json", payload);
        const status = try std.fmt.allocPrint(self.allocator, "Resized to {d}x{d}", .{ cols, rows });
        defer self.allocator.free(status);
        self.setTerminalStatus(status);
    }

    fn sendTerminalControlC(self: *App) !void {
        try self.ensureTerminalSession();
        if (self.terminal_session_id == null) return error.InvalidState;
        const session_id = self.terminal_session_id.?;
        const escaped_session = try jsonEscape(self.allocator, session_id);
        defer self.allocator.free(escaped_session);

        const payload = try std.fmt.allocPrint(
            self.allocator,
            "{{\"session_id\":\"{s}\",\"data_b64\":\"Aw==\",\"append_newline\":false}}",
            .{escaped_session},
        );
        defer self.allocator.free(payload);
        try self.writeTerminalControl("write.json", payload);
        self.clearTerminalError();
        self.setTerminalStatus("Sent Ctrl+C");
    }

    fn sendTerminalInputRaw(self: *App, input: []const u8, append_newline: bool) !void {
        try self.ensureTerminalSession();
        if (self.terminal_session_id == null) return error.InvalidState;

        const session_id = self.terminal_session_id.?;
        const escaped_session = try jsonEscape(self.allocator, session_id);
        defer self.allocator.free(escaped_session);
        const escaped_input = try jsonEscape(self.allocator, input);
        defer self.allocator.free(escaped_input);
        const payload = try std.fmt.allocPrint(
            self.allocator,
            "{{\"session_id\":\"{s}\",\"input\":\"{s}\",\"append_newline\":{s}}}",
            .{
                escaped_session,
                escaped_input,
                if (append_newline) "true" else "false",
            },
        );
        defer self.allocator.free(payload);
        try self.writeTerminalControl("write.json", payload);

        const status = try std.fmt.allocPrint(self.allocator, "Wrote {d} bytes", .{input.len});
        defer self.allocator.free(status);
        self.clearTerminalError();
        self.setTerminalStatus(status);
    }

    fn sendTerminalInputFromUi(self: *App) !void {
        const input = std.mem.trim(u8, self.terminal_input.items, " \t\r\n");
        if (input.len == 0) return;
        try self.sendTerminalInputRaw(input, true);
        self.terminal_input.clearRetainingCapacity();
        self.terminalReadOnce(25) catch |err| switch (err) {
            error.RemoteError => {},
            else => return err,
        };
    }

    fn terminalReadOnce(self: *App, timeout_ms: u32) !void {
        if (self.terminal_session_id == null) return;
        const session_id = self.terminal_session_id.?;
        const escaped_session = try jsonEscape(self.allocator, session_id);
        defer self.allocator.free(escaped_session);
        const payload = try std.fmt.allocPrint(
            self.allocator,
            "{{\"session_id\":\"{s}\",\"timeout_ms\":{d},\"max_bytes\":{d}}}",
            .{ escaped_session, timeout_ms, TERMINAL_READ_MAX_BYTES },
        );
        defer self.allocator.free(payload);
        try self.writeTerminalControl("read.json", payload);

        const result_payload = try self.readTerminalPath("/agents/self/terminal/result.json");
        defer self.allocator.free(result_payload);
        try self.applyTerminalReadResult(result_payload);
        self.terminal_next_poll_at_ms = std.time.milliTimestamp() + TERMINAL_READ_POLL_INTERVAL_MS;
    }

    fn applyTerminalReadResult(self: *App, payload: []const u8) !void {
        var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, payload, .{});
        defer parsed.deinit();
        if (parsed.value != .object) return error.InvalidResponse;
        const obj = parsed.value.object;

        const ok = if (obj.get("ok")) |value| switch (value) {
            .bool => value.bool,
            else => false,
        } else false;

        if (!ok) {
            var message: []const u8 = "terminal operation failed";
            if (obj.get("error")) |error_value| {
                if (error_value == .object) {
                    if (error_value.object.get("message")) |msg_value| {
                        if (msg_value == .string and msg_value.string.len > 0) {
                            message = msg_value.string;
                        }
                    }
                }
            }
            self.setTerminalError(message);
            return error.RemoteError;
        }

        const operation = if (obj.get("operation")) |value| switch (value) {
            .string => value.string,
            else => "",
        } else "";
        if (!std.mem.eql(u8, operation, "read")) return;

        const result_obj = if (obj.get("result")) |result_value| switch (result_value) {
            .object => result_value.object,
            else => return error.InvalidResponse,
        } else return error.InvalidResponse;

        const data_b64 = if (result_obj.get("data_b64")) |value| switch (value) {
            .string => value.string,
            else => "",
        } else "";
        const eof = if (result_obj.get("eof")) |value| switch (value) {
            .bool => value.bool,
            else => false,
        } else false;

        if (data_b64.len > 0) {
            const decoded_len = try std.base64.standard.Decoder.calcSizeForSlice(data_b64);
            const decoded = try self.allocator.alloc(u8, decoded_len);
            defer self.allocator.free(decoded);
            try std.base64.standard.Decoder.decode(decoded, data_b64);
            try self.terminal_backend.appendBytes(self.allocator, decoded);
        }

        if (eof) {
            if (self.terminal_session_id) |value| {
                self.allocator.free(value);
                self.terminal_session_id = null;
            }
            self.setTerminalStatus("Session closed (EOF)");
        } else {
            const count = if (result_obj.get("n")) |value| switch (value) {
                .integer => @max(@as(i64, 0), value.integer),
                else => 0,
            } else 0;
            const status = try std.fmt.allocPrint(self.allocator, "Read {d} bytes", .{count});
            defer self.allocator.free(status);
            self.setTerminalStatus(status);
        }
        self.clearTerminalError();
    }

    fn pollTerminalSession(self: *App) void {
        if (!self.terminal_auto_poll) return;
        if (self.terminal_session_id == null) return;
        if (self.ws_client == null) return;
        if (self.awaiting_reply or self.pending_send_job_id != null) return;

        const now_ms = std.time.milliTimestamp();
        if (now_ms < self.terminal_next_poll_at_ms) return;

        self.terminalReadOnce(TERMINAL_READ_TIMEOUT_MS) catch |err| {
            if (err != error.RemoteError) {
                const msg = self.formatFilesystemOpError("Terminal read failed", err);
                if (msg) |text| {
                    defer self.allocator.free(text);
                    self.setTerminalError(text);
                }
            }
            self.terminal_next_poll_at_ms = now_ms + 500;
            return;
        };
    }

    fn drawTerminalPanel(self: *App, manager: *panel_manager.PanelManager, rect: UiRect) void {
        _ = manager;
        const host = TerminalPanel.Host{
            .ctx = @ptrCast(self),
            .draw_label = launcherSettingsDrawLabel,
            .draw_text_trimmed = launcherSettingsDrawTextTrimmed,
            .draw_text_input = launcherSettingsDrawTextInput,
            .draw_button = launcherSettingsDrawButton,
            .draw_surface_panel = filesystemDrawSurfacePanel,
            .draw_output = terminalDrawOutput,
        };
        var panel_state = TerminalPanel.State{
            .focused_field = terminalFocusFieldToExternal(self.settings_panel.focused_field),
        };
        var owned_view = self.terminalPanelViewOwned();
        defer owned_view.deinit(self.allocator);
        const action = TerminalPanel.draw(
            host,
            Rect{ .min = rect.min, .max = rect.max },
            self.panelLayoutMetrics(),
            .{
                .text_primary = self.theme.colors.text_primary,
                .text_secondary = self.theme.colors.text_secondary,
                .error_text = zcolors.rgba(220, 80, 80, 255),
            },
            self.terminalPanelModel(),
            owned_view.view,
            .{
                .mouse_x = self.mouse_x,
                .mouse_y = self.mouse_y,
                .mouse_released = self.mouse_released,
            },
            &panel_state,
        );
        const mapped_focus = terminalFocusFieldFromExternal(panel_state.focused_field);
        if (mapped_focus != .none or isTerminalPanelFocusField(self.settings_panel.focused_field)) {
            self.settings_panel.focused_field = mapped_focus;
        }
        if (action) |value| self.performTerminalPanelAction(value);
    }

    fn terminalIndexedColor(index: u8) [4]f32 {
        const base16 = [_][3]u8{
            .{ 0, 0, 0 },
            .{ 205, 49, 49 },
            .{ 13, 188, 121 },
            .{ 229, 229, 16 },
            .{ 36, 114, 200 },
            .{ 188, 63, 188 },
            .{ 17, 168, 205 },
            .{ 229, 229, 229 },
            .{ 102, 102, 102 },
            .{ 241, 76, 76 },
            .{ 35, 209, 139 },
            .{ 245, 245, 67 },
            .{ 59, 142, 234 },
            .{ 214, 112, 214 },
            .{ 41, 184, 219 },
            .{ 255, 255, 255 },
        };
        if (index < 16) {
            const rgb = base16[index];
            return zcolors.rgba(rgb[0], rgb[1], rgb[2], 255);
        }
        if (index < 232) {
            const v = index - 16;
            const r = v / 36;
            const g = (v / 6) % 6;
            const b = v % 6;
            const scale = [_]u8{ 0, 95, 135, 175, 215, 255 };
            return zcolors.rgba(scale[r], scale[g], scale[b], 255);
        }
        const gray = @as(u8, @intCast(8 + (index - 232) * 10));
        return zcolors.rgba(gray, gray, gray, 255);
    }

    fn terminalColorToRgba(
        self: *App,
        color: terminal_render_backend.Color,
        default_color: [4]f32,
    ) [4]f32 {
        _ = self;
        return switch (color) {
            .default => default_color,
            .indexed => |idx| terminalIndexedColor(idx),
            .rgb => |rgb| zcolors.rgba(rgb[0], rgb[1], rgb[2], 255),
        };
    }

    fn terminalStyleColors(
        self: *App,
        style: terminal_render_backend.Style,
    ) struct { fg: [4]f32, bg: ?[4]f32 } {
        var fg = self.terminalColorToRgba(style.fg, self.theme.colors.text_primary);
        var bg_opt: ?[4]f32 = if (style.bg == .default)
            null
        else
            self.terminalColorToRgba(style.bg, self.theme.colors.background);

        if (style.inverse) {
            const swapped_fg = if (bg_opt) |bg| bg else self.theme.colors.background;
            const swapped_bg = self.terminalColorToRgba(style.fg, self.theme.colors.text_primary);
            fg = swapped_fg;
            bg_opt = swapped_bg;
        }
        if (style.dim) {
            fg = zcolors.blend(fg, self.theme.colors.background, 0.45);
        }
        if (style.bold) {
            fg = zcolors.blend(fg, zcolors.rgba(255, 255, 255, 255), 0.22);
        }
        if (style.italic) {
            fg = zcolors.blend(fg, self.theme.colors.primary, 0.12);
        }
        return .{ .fg = fg, .bg = bg_opt };
    }

    fn fitTextToWidth(self: *App, text: []const u8, max_w: f32) usize {
        if (text.len == 0 or max_w <= 0.0) return 0;
        if (self.measureText(text) <= max_w) return text.len;

        var idx: usize = 0;
        var best_end: usize = 0;
        while (idx < text.len) {
            const next = nextUtf8Boundary(text, idx);
            if (next <= idx) break;
            if (self.measureText(text[0..next]) > max_w) break;
            best_end = next;
            idx = next;
        }
        return best_end;
    }

    fn drawTerminalStyledLine(
        self: *App,
        x: f32,
        y: f32,
        max_w: f32,
        line: terminal_render_backend.StyledLine,
    ) void {
        var cursor_x = x;
        const max_x = x + @max(1.0, max_w);
        var i: usize = 0;
        while (i < line.bytes.len and i < line.styles.len and cursor_x < max_x) {
            const style = line.styles[i];
            var end = i + 1;
            while (end < line.bytes.len and end < line.styles.len and std.meta.eql(line.styles[end], style)) : (end += 1) {}
            const run_text = line.bytes[i..end];
            const remaining_w = max_x - cursor_x;
            const fit_end = self.fitTextToWidth(run_text, remaining_w);
            if (fit_end == 0) break;
            const segment = run_text[0..fit_end];
            const colors = self.terminalStyleColors(style);
            const segment_w = self.measureText(segment);
            if (colors.bg) |bg| {
                self.drawFilledRect(Rect.fromXYWH(cursor_x, y, segment_w, self.textLineHeight()), zcolors.withAlpha(bg, 0.22));
            }
            self.drawText(cursor_x, y, segment, colors.fg);
            if (style.underline) {
                self.drawFilledRect(
                    Rect.fromXYWH(cursor_x, y + self.textLineHeight() - @max(1.0, self.ui_scale), segment_w, @max(1.0, self.ui_scale)),
                    zcolors.withAlpha(colors.fg, 0.9),
                );
            }
            if (style.strikethrough) {
                self.drawFilledRect(
                    Rect.fromXYWH(cursor_x, y + self.textLineHeight() * 0.48, segment_w, @max(1.0, self.ui_scale)),
                    zcolors.withAlpha(colors.fg, 0.75),
                );
            }
            cursor_x += segment_w;
            if (fit_end < run_text.len) break;
            i = end;
        }
    }

    fn projectPanelModel(self: *App) panels_bridge.ProjectPanelModel {
        const selected_project_lock_state = self.selectedProjectTokenLocked();
        const selected_project_known = selected_project_lock_state != null;
        const selected_is_locked = if (selected_project_lock_state) |locked| locked else false;
        return .{
            .connected = self.connection_state == .connected,
            .has_projects = self.projects.items.len > 0,
            .has_nodes = self.nodes.items.len > 0,
            .can_create_project = self.connection_state == .connected and self.settings_panel.project_create_name.items.len > 0,
            .can_activate_project = self.connection_state == .connected and self.selectedProjectId() != null,
            .can_lock_project = self.connection_state == .connected and selected_project_known and !selected_is_locked,
            .can_unlock_project = self.connection_state == .connected and selected_project_known and selected_is_locked,
        };
    }

    fn handleProjectPanelError(self: *App, prefix: []const u8, err: anyerror) void {
        const msg = self.formatControlOpError(prefix, err);
        if (msg) |text| {
            defer self.allocator.free(text);
            self.setWorkspaceError(text);
        }
    }

    const OwnedProjectPanelView = struct {
        selected_project_button_label: ?[]u8 = null,
        selected_project_line: ?[]u8 = null,
        setup_status_line: ?[]u8 = null,
        setup_vision_line: ?[]u8 = null,
        workspace_summary_line: ?[]u8 = null,
        workspace_health_line: ?[]u8 = null,
        counts_line: ?[]u8 = null,
        project_lines: std.ArrayListUnmanaged([]u8) = .{},
        projects: std.ArrayListUnmanaged(panels_bridge.ProjectListEntryView) = .{},
        node_lines: std.ArrayListUnmanaged([]u8) = .{},
        nodes: std.ArrayListUnmanaged(panels_bridge.ProjectNodeEntryView) = .{},
        view: panels_bridge.ProjectPanelView = .{},

        fn deinit(self: *OwnedProjectPanelView, allocator: std.mem.Allocator) void {
            if (self.selected_project_button_label) |value| allocator.free(value);
            if (self.selected_project_line) |value| allocator.free(value);
            if (self.setup_status_line) |value| allocator.free(value);
            if (self.setup_vision_line) |value| allocator.free(value);
            if (self.workspace_summary_line) |value| allocator.free(value);
            if (self.workspace_health_line) |value| allocator.free(value);
            if (self.counts_line) |value| allocator.free(value);
            for (self.project_lines.items) |value| allocator.free(value);
            for (self.node_lines.items) |value| allocator.free(value);
            self.project_lines.deinit(allocator);
            self.projects.deinit(allocator);
            self.node_lines.deinit(allocator);
            self.nodes.deinit(allocator);
            self.* = undefined;
        }
    };

    fn buildProjectPanelView(self: *App) OwnedProjectPanelView {
        var owned: OwnedProjectPanelView = .{};
        const selected_project_lock_state = self.selectedProjectTokenLocked();

        const selected_project_button_label: []const u8 = blk: {
            if (self.settings_panel.project_id.items.len == 0) break :blk "Select project";
            const selected_id = self.settings_panel.project_id.items;
            for (self.projects.items) |project| {
                if (std.mem.eql(u8, project.id, selected_id)) {
                    const formatted = std.fmt.allocPrint(
                        self.allocator,
                        "{s} ({s}) [{s}]",
                        .{
                            project.name,
                            project.id,
                            if (project.token_locked) "locked" else "open",
                        },
                    ) catch null;
                    if (formatted) |value| {
                        owned.selected_project_button_label = value;
                        break :blk value;
                    }
                    break :blk selected_id;
                }
            }
            break :blk selected_id;
        };

        const lock_state_text: []const u8 = if (self.selectedProjectId() == null)
            "Project lock state: select a project"
        else if (selected_project_lock_state) |locked|
            if (locked)
                "Project lock state: locked (project token required for non-admin)"
            else
                "Project lock state: unlocked (project token optional)"
        else
            "Project lock state: unknown (project not in current list)";

        const add_mount_validation = self.validateProjectMountAddInput();
        const remove_mount_validation = self.validateProjectMountRemoveInput();
        const mount_hint = if (self.connection_state == .connected)
            (add_mount_validation orelse remove_mount_validation)
        else
            null;

        const selected_project_text = if (self.settings_panel.project_id.items.len > 0)
            self.settings_panel.project_id.items
        else
            "(none)";
        const selected_project_lock_suffix: []const u8 = if (selected_project_lock_state) |locked|
            if (locked) " [locked]" else " [open]"
        else
            "";
        owned.selected_project_line = std.fmt.allocPrint(
            self.allocator,
            "Selected project: {s}{s}",
            .{ selected_project_text, selected_project_lock_suffix },
        ) catch null;

        var setup_status_warning = false;
        if (self.connect_setup_hint) |hint| {
            const setup_status = if (hint.required) "required" else "ready";
            owned.setup_status_line = std.fmt.allocPrint(
                self.allocator,
                "Project setup: {s}",
                .{setup_status},
            ) catch null;
            setup_status_warning = hint.required;
            if (hint.project_vision) |vision| {
                owned.setup_vision_line = std.fmt.allocPrint(
                    self.allocator,
                    "Project vision: {s}",
                    .{vision},
                ) catch null;
            }
        }

        var workspace_health_warning = false;
        var workspace_health_error = false;
        if (self.workspace_state) |*status| {
            const root_text = status.workspace_root orelse "(none)";
            const mounted_count: usize = if (status.actual_mounts.items.len > 0)
                status.actual_mounts.items.len
            else
                status.mounts.items.len;
            owned.workspace_summary_line = std.fmt.allocPrint(
                self.allocator,
                "Workspace root: {s} | mounts: {d}",
                .{ root_text, mounted_count },
            ) catch null;

            const health_state = workspaceHealthState(status);
            owned.workspace_health_line = std.fmt.allocPrint(
                self.allocator,
                "Workspace health: {s} | online={d}/{d} degraded={d} missing={d} drift={d}",
                .{
                    workspaceHealthStateLabel(health_state),
                    status.availability_online,
                    status.availability_mounts_total,
                    status.availability_degraded,
                    status.availability_missing,
                    status.drift_count,
                },
            ) catch null;
            switch (health_state) {
                .healthy, .unknown => {},
                .degraded => workspace_health_warning = true,
                .missing => workspace_health_error = true,
            }
        }

        owned.counts_line = std.fmt.allocPrint(
            self.allocator,
            "Projects: {d} | Nodes: {d}",
            .{ self.projects.items.len, self.nodes.items.len },
        ) catch null;

        for (self.projects.items, 0..) |project, idx| {
            const line = std.fmt.allocPrint(
                self.allocator,
                "{s} [{s}] access={s} mounts={d}",
                .{
                    project.id,
                    project.status,
                    if (project.token_locked) "locked" else "open",
                    project.mount_count,
                },
            ) catch continue;
            owned.project_lines.append(self.allocator, line) catch {
                self.allocator.free(line);
                continue;
            };
            const project_selected = self.settings_panel.project_id.items.len > 0 and
                std.mem.eql(u8, self.settings_panel.project_id.items, project.id);
            owned.projects.append(self.allocator, .{
                .index = idx,
                .line = line,
                .selected = project_selected,
            }) catch {};
        }

        const now_ms = std.time.milliTimestamp();
        for (self.nodes.items) |node| {
            const node_online = node.lease_expires_at_ms > now_ms;
            const line = std.fmt.allocPrint(
                self.allocator,
                "  - {s} ({s}) [{s}]",
                .{ node.node_id, node.node_name, if (node_online) "online" else "degraded" },
            ) catch continue;
            owned.node_lines.append(self.allocator, line) catch {
                self.allocator.free(line);
                continue;
            };
            owned.nodes.append(self.allocator, .{
                .line = line,
                .degraded = !node_online,
            }) catch {};
        }

        owned.view = .{
            .title = "Project Workspace",
            .selected_project_button_label = selected_project_button_label,
            .lock_state_text = lock_state_text,
            .project_token = self.settings_panel.project_token.items,
            .create_name = self.settings_panel.project_create_name.items,
            .create_vision = self.settings_panel.project_create_vision.items,
            .operator_token = self.settings_panel.project_operator_token.items,
            .mount_path = self.settings_panel.project_mount_path.items,
            .mount_node_id = self.settings_panel.project_mount_node_id.items,
            .mount_export_name = self.settings_panel.project_mount_export_name.items,
            .mount_hint = mount_hint,
            .workspace_error_text = self.workspace_last_error,
            .selected_project_line = owned.selected_project_line,
            .setup_status_line = owned.setup_status_line,
            .setup_status_warning = setup_status_warning,
            .setup_vision_line = owned.setup_vision_line,
            .workspace_summary_line = owned.workspace_summary_line,
            .workspace_health_line = owned.workspace_health_line,
            .workspace_health_warning = workspace_health_warning,
            .workspace_health_error = workspace_health_error,
            .counts_line = owned.counts_line,
            .projects = owned.projects.items,
            .nodes = owned.nodes.items,
        };
        return owned;
    }

    fn performProjectPanelAction(self: *App, action: panels_bridge.ProjectPanelAction) void {
        switch (action) {
            .select_project_index => |project_index| {
                if (project_index >= self.projects.items.len) return;
                const project = self.projects.items[project_index];
                self.selectProjectInSettings(project.id) catch |err| {
                    const msg = std.fmt.allocPrint(self.allocator, "Project select failed: {s}", .{@errorName(err)}) catch null;
                    if (msg) |text| {
                        defer self.allocator.free(text);
                        self.setWorkspaceError(text);
                    }
                };
            },
            .create_project => {
                self.createProjectFromPanel() catch |err| {
                    self.handleProjectPanelError("Project create failed", err);
                };
            },
            .refresh_workspace => {
                self.refreshWorkspaceData() catch |err| {
                    self.handleProjectPanelError("Workspace refresh failed", err);
                };
            },
            .activate_project => {
                self.activateSelectedProject() catch |err| {
                    self.handleProjectPanelError("Project activate failed", err);
                };
            },
            .lock_project => {
                self.lockSelectedProjectFromPanel() catch |err| {
                    self.handleProjectPanelError("Project lock failed", err);
                };
            },
            .unlock_project => {
                self.unlockSelectedProjectFromPanel() catch |err| {
                    self.handleProjectPanelError("Project unlock failed", err);
                };
            },
            .add_mount => {
                if (self.validateProjectMountAddInput()) |message| {
                    self.setWorkspaceError(message);
                } else {
                    self.setProjectMountFromPanel() catch |err| {
                        self.handleProjectPanelError("Mount set failed", err);
                    };
                }
            },
            .remove_mount => {
                if (self.validateProjectMountRemoveInput()) |message| {
                    self.setWorkspaceError(message);
                } else {
                    self.removeProjectMountFromPanel() catch |err| {
                        self.handleProjectPanelError("Mount remove failed", err);
                    };
                }
            },
            .auth_status => {
                self.fetchAuthStatusFromPanel(false) catch |err| {
                    self.handleProjectPanelError("Auth status failed", err);
                };
            },
            .rotate_auth_user => {
                self.rotateAuthTokenFromPanel("user") catch |err| {
                    self.handleProjectPanelError("Auth rotate(user) failed", err);
                };
            },
            .rotate_auth_admin => {
                self.rotateAuthTokenFromPanel("admin") catch |err| {
                    self.handleProjectPanelError("Auth rotate(admin) failed", err);
                };
            },
            .reveal_auth_admin => {
                self.revealAuthTokenFromPanel("admin") catch |err| {
                    self.handleProjectPanelError("Reveal admin token failed", err);
                };
            },
            .copy_auth_admin => {
                self.copyAuthTokenFromPanel("admin") catch |err| {
                    self.handleProjectPanelError("Copy admin token failed", err);
                };
            },
            .reveal_auth_user => {
                self.revealAuthTokenFromPanel("user") catch |err| {
                    self.handleProjectPanelError("Reveal user token failed", err);
                };
            },
            .copy_auth_user => {
                self.copyAuthTokenFromPanel("user") catch |err| {
                    self.handleProjectPanelError("Copy user token failed", err);
                };
            },
        }
    }

    const VisibleFilesystemEntry = struct {
        index: usize,
        entry: *const FilesystemEntry,
    };

    fn filesystemEntryPassesFilters(self: *App, entry: *const FilesystemEntry) bool {
        if (self.filesystem_hide_hidden and entry.hidden) return false;
        if (self.filesystem_hide_runtime_noise and entry.runtime_noise) return false;
        if (self.filesystem_hide_directories and entry.kind == .directory) return false;
        if (self.filesystem_hide_files and entry.kind != .directory) return false;
        return true;
    }

    fn filesystemVisibleEntryCount(self: *App) usize {
        var count: usize = 0;
        for (self.filesystem_entries.items) |*entry| {
            if (self.filesystemEntryPassesFilters(entry)) count += 1;
        }
        return count;
    }

    fn filesystemTextOrder(lhs: []const u8, rhs: []const u8) std.math.Order {
        var idx: usize = 0;
        const common = @min(lhs.len, rhs.len);
        while (idx < common) : (idx += 1) {
            const a = std.ascii.toLower(lhs[idx]);
            const b = std.ascii.toLower(rhs[idx]);
            if (a < b) return .lt;
            if (a > b) return .gt;
        }
        if (lhs.len < rhs.len) return .lt;
        if (lhs.len > rhs.len) return .gt;
        return .eq;
    }

    fn filesystemNumericOrderU64(lhs: ?u64, rhs: ?u64, direction: FilesystemSortDirection) std.math.Order {
        if (lhs == null and rhs == null) return .eq;
        if (lhs == null) return .gt;
        if (rhs == null) return .lt;
        const base: std.math.Order = if (lhs.? < rhs.?) .lt else if (lhs.? > rhs.?) .gt else .eq;
        return switch (direction) {
            .ascending => base,
            .descending => switch (base) {
                .lt => .gt,
                .gt => .lt,
                .eq => .eq,
            },
        };
    }

    fn filesystemNumericOrderI64(lhs: ?i64, rhs: ?i64, direction: FilesystemSortDirection) std.math.Order {
        if (lhs == null and rhs == null) return .eq;
        if (lhs == null) return .gt;
        if (rhs == null) return .lt;
        const base: std.math.Order = if (lhs.? < rhs.?) .lt else if (lhs.? > rhs.?) .gt else .eq;
        return applyFilesystemSortDirection(base, direction);
    }

    fn applyFilesystemSortDirection(order: std.math.Order, direction: FilesystemSortDirection) std.math.Order {
        return switch (direction) {
            .ascending => order,
            .descending => switch (order) {
                .lt => .gt,
                .gt => .lt,
                .eq => .eq,
            },
        };
    }

    fn filesystemEntryLessThan(self: *App, lhs: VisibleFilesystemEntry, rhs: VisibleFilesystemEntry) bool {
        if (lhs.entry.kind != rhs.entry.kind) {
            if (lhs.entry.kind == .directory) return true;
            if (rhs.entry.kind == .directory) return false;
        }

        const direction = self.filesystem_sort_direction;
        const order = switch (self.filesystem_sort_key) {
            .name => blk: {
                const base = filesystemTextOrder(lhs.entry.name, rhs.entry.name);
                break :blk applyFilesystemSortDirection(base, direction);
            },
            .type => blk: {
                const primary = filesystemTextOrder(lhs.entry.type_label, rhs.entry.type_label);
                if (primary != .eq) {
                    break :blk applyFilesystemSortDirection(primary, direction);
                }
                const fallback = filesystemTextOrder(lhs.entry.name, rhs.entry.name);
                break :blk applyFilesystemSortDirection(fallback, direction);
            },
            .modified => blk: {
                const primary = filesystemNumericOrderI64(lhs.entry.modified_unix_ms, rhs.entry.modified_unix_ms, direction);
                if (primary != .eq) break :blk primary;
                const fallback = filesystemTextOrder(lhs.entry.name, rhs.entry.name);
                break :blk fallback;
            },
            .size => blk: {
                const primary = filesystemNumericOrderU64(lhs.entry.size_bytes, rhs.entry.size_bytes, direction);
                if (primary != .eq) break :blk primary;
                const fallback = filesystemTextOrder(lhs.entry.name, rhs.entry.name);
                break :blk fallback;
            },
        };
        return order == .lt;
    }

    fn sortVisibleFilesystemEntries(self: *App, items: []VisibleFilesystemEntry) void {
        var i: usize = 1;
        while (i < items.len) : (i += 1) {
            const value = items[i];
            var j = i;
            while (j > 0 and self.filesystemEntryLessThan(value, items[j - 1])) : (j -= 1) {
                items[j] = items[j - 1];
            }
            items[j] = value;
        }
    }

    fn formatFilesystemSizeLabel(self: *App, size_bytes: ?u64) ?[]u8 {
        const size = size_bytes orelse return null;
        if (size < 1024) return std.fmt.allocPrint(self.allocator, "{d} B", .{size}) catch null;

        const size_f = @as(f64, @floatFromInt(size));
        if (size < 1024 * 1024) return std.fmt.allocPrint(self.allocator, "{d:.1} KB", .{size_f / 1024.0}) catch null;
        if (size < 1024 * 1024 * 1024) return std.fmt.allocPrint(self.allocator, "{d:.1} MB", .{size_f / (1024.0 * 1024.0)}) catch null;
        return std.fmt.allocPrint(self.allocator, "{d:.1} GB", .{size_f / (1024.0 * 1024.0 * 1024.0)}) catch null;
    }

    fn formatFilesystemModifiedLabel(self: *App, modified_unix_ms: ?i64) ?[]u8 {
        const modified = modified_unix_ms orelse return null;
        if (modified < 0) return null;

        const epoch = std.time.epoch.EpochSeconds{ .secs = @intCast(@divTrunc(modified, std.time.ms_per_s)) };
        const day = epoch.getEpochDay();
        const year_day = day.calculateYearDay();
        const month_day = year_day.calculateMonthDay();
        const day_seconds = epoch.getDaySeconds();
        return std.fmt.allocPrint(
            self.allocator,
            "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2} UTC",
            .{
                year_day.year,
                month_day.month.numeric(),
                month_day.day_index + 1,
                day_seconds.getHoursIntoDay(),
                day_seconds.getMinutesIntoHour(),
            },
        ) catch null;
    }

    fn filesystemPreviewTypeLabel(self: *App, path: []const u8, kind: FilesystemEntryKind) ?[]u8 {
        return self.allocFilesystemTypeLabel(std.fs.path.basename(path), kind) catch null;
    }

    fn filesystemPanelModel(self: *App) panels_bridge.FilesystemPanelModel {
        return .{
            .connected = self.connection_state == .connected,
            .busy = self.filesystem_busy,
            .sort_key = self.filesystem_sort_key,
            .sort_direction = self.filesystem_sort_direction,
            .hide_hidden = self.filesystem_hide_hidden,
            .hide_directories = self.filesystem_hide_directories,
            .hide_files = self.filesystem_hide_files,
            .hide_runtime_noise = self.filesystem_hide_runtime_noise,
            .total_entry_count = self.filesystem_entries.items.len,
            .visible_entry_count = self.filesystemVisibleEntryCount(),
            .has_selected_entry = self.selectedFilesystemEntry() != null,
        };
    }

    fn handleFilesystemPanelError(self: *App, prefix: []const u8, err: anyerror) void {
        const msg = self.formatFilesystemOpError(prefix, err);
        if (msg) |text| {
            defer self.allocator.free(text);
            self.setFilesystemError(text);
        }
    }

    fn filesystemToolsPanelModel(self: *App) panels_bridge.FilesystemToolsPanelModel {
        return .{
            .connected = self.connection_state == .connected,
            .busy = self.filesystem_busy,
            .has_service_runtime_root = self.filesystemHasServiceRuntimeRoot(),
            .has_selected_contract_service = self.selectedContractService() != null,
            .contract_service_count = self.contract_services.items.len,
        };
    }

    fn performFilesystemPanelAction(self: *App, action: panels_bridge.FilesystemPanelAction, path_label: []const u8) void {
        switch (action) {
            .refresh => {
                self.refreshFilesystemBrowser() catch |err| {
                    self.handleFilesystemPanelError("Filesystem refresh failed", err);
                };
            },
            .navigate_up => {
                const next_path = self.parentFilesystemPath(path_label) catch null;
                if (next_path) |value| {
                    defer self.allocator.free(value);
                    self.queueFilesystemPathLoad(value, true, false) catch |err| {
                        self.handleFilesystemPanelError("Filesystem refresh failed", err);
                    };
                }
            },
            .use_workspace_root => {
                var target_path: ?[]u8 = null;
                defer if (target_path) |value| self.allocator.free(value);
                if (self.workspace_state) |*status| {
                    if (status.workspace_root) |root| {
                        const mapped = self.mapWorkspaceRootToFilesystemPath(root) catch null;
                        if (mapped) |value| {
                            target_path = value;
                        } else {
                            target_path = self.allocator.dupe(u8, "/") catch null;
                        }
                    } else {
                        target_path = self.allocator.dupe(u8, "/") catch null;
                    }
                } else {
                    target_path = self.allocator.dupe(u8, "/") catch null;
                }

                const resolved_target = if (target_path) |value| value else "/";
                self.queueFilesystemPathLoad(resolved_target, true, false) catch |err| {
                    self.handleFilesystemPanelError("Filesystem refresh failed", err);
                };
            },
            .select_entry_index => |entry_index| {
                if (entry_index >= self.filesystem_entries.items.len) return;
                const entry = self.filesystem_entries.items[entry_index];
                self.setFilesystemSelectedPath(entry.path);
                self.refreshSelectedFilesystemPreview() catch |err| {
                    self.handleFilesystemPanelError("Filesystem preview failed", err);
                };
            },
            .open_entry_index => |entry_index| {
                if (entry_index >= self.filesystem_entries.items.len) return;
                const entry = self.filesystem_entries.items[entry_index];
                self.openFilesystemEntry(&entry) catch |err| {
                    self.handleFilesystemPanelError("Filesystem open failed", err);
                };
            },
            .open_selected_entry => {
                const entry = self.selectedFilesystemEntry() orelse return;
                self.openFilesystemEntry(entry) catch |err| {
                    self.handleFilesystemPanelError("Filesystem open failed", err);
                };
            },
            .set_sort_key => |sort_key| {
                self.filesystem_sort_key = sort_key;
                self.filesystem_entry_page = 0;
            },
            .toggle_sort_direction => {
                self.filesystem_sort_direction = switch (self.filesystem_sort_direction) {
                    .ascending => .descending,
                    .descending => .ascending,
                };
                self.filesystem_entry_page = 0;
            },
            .toggle_hide_hidden => {
                self.filesystem_hide_hidden = !self.filesystem_hide_hidden;
                self.filesystem_entry_page = 0;
            },
            .toggle_hide_directories => {
                self.filesystem_hide_directories = !self.filesystem_hide_directories;
                self.filesystem_entry_page = 0;
            },
            .toggle_hide_files => {
                self.filesystem_hide_files = !self.filesystem_hide_files;
                self.filesystem_entry_page = 0;
            },
            .toggle_hide_runtime_noise => {
                self.filesystem_hide_runtime_noise = !self.filesystem_hide_runtime_noise;
                self.filesystem_entry_page = 0;
            },
            .reset_explorer_view => {
                self.filesystem_sort_key = .name;
                self.filesystem_sort_direction = .ascending;
                self.filesystem_hide_hidden = false;
                self.filesystem_hide_directories = false;
                self.filesystem_hide_files = false;
                self.filesystem_hide_runtime_noise = false;
                self.filesystem_entry_page = 0;
            },
            .refresh_preview => {
                self.refreshSelectedFilesystemPreview() catch |err| {
                    self.handleFilesystemPanelError("Filesystem preview failed", err);
                };
            },
        }
    }

    fn performFilesystemToolsPanelAction(self: *App, action: panels_bridge.FilesystemToolsPanelAction) void {
        switch (action) {
            .runtime_read => |target| {
                const file_name: []const u8 = switch (target) {
                    .status => "status.json",
                    .health => "health.json",
                    .metrics => "metrics.json",
                    .config => "config.json",
                };
                const label: []const u8 = switch (target) {
                    .status => "Runtime status failed",
                    .health => "Runtime health failed",
                    .metrics => "Runtime metrics failed",
                    .config => "Runtime config failed",
                };
                self.readFilesystemServiceRuntimeFile(file_name) catch |err| {
                    self.handleFilesystemPanelError(label, err);
                };
            },
            .runtime_control => |target| {
                const control_path: []const u8 = switch (target) {
                    .enable => "enable",
                    .disable => "disable",
                    .restart => "restart",
                    .reset => "reset",
                    .invoke => "invoke.json",
                };
                const label: []const u8 = switch (target) {
                    .enable => "Runtime enable failed",
                    .disable => "Runtime disable failed",
                    .restart => "Runtime restart failed",
                    .reset => "Runtime reset failed",
                    .invoke => "Runtime invoke failed",
                };
                self.writeFilesystemServiceRuntimeControl(control_path, "{}") catch |err| {
                    self.handleFilesystemPanelError(label, err);
                };
            },
            .contract_refresh => {
                self.refreshContractServices() catch |err| {
                    self.handleFilesystemPanelError("Contract refresh failed", err);
                };
            },
            .contract_select_prev => {
                if (self.contract_services.items.len > 1) {
                    if (self.contract_service_selected_index == 0) {
                        self.contract_service_selected_index = self.contract_services.items.len - 1;
                    } else {
                        self.contract_service_selected_index -= 1;
                    }
                }
            },
            .contract_select_next => {
                if (self.contract_services.items.len > 1) {
                    self.contract_service_selected_index = (self.contract_service_selected_index + 1) % self.contract_services.items.len;
                }
            },
            .contract_open_service_dir => {
                self.openSelectedContractServicePath() catch |err| {
                    self.handleFilesystemPanelError("Open contract service path failed", err);
                };
            },
            .contract_invoke => {
                self.invokeSelectedContractService() catch |err| {
                    self.handleFilesystemPanelError("Contract invoke failed", err);
                };
            },
            .contract_read_status => {
                self.readSelectedContractServiceStatus() catch |err| {
                    self.handleFilesystemPanelError("Contract status read failed", err);
                };
            },
            .contract_read_result => {
                self.readSelectedContractServiceResult() catch |err| {
                    self.handleFilesystemPanelError("Contract result read failed", err);
                };
            },
            .contract_read_help => {
                self.readSelectedContractServiceHelp() catch |err| {
                    self.handleFilesystemPanelError("Contract help read failed", err);
                };
            },
            .contract_read_schema => {
                self.readSelectedContractServiceSchema() catch |err| {
                    self.handleFilesystemPanelError("Contract schema read failed", err);
                };
            },
            .contract_use_template => {
                self.useSelectedContractServiceTemplate() catch |err| {
                    self.handleFilesystemPanelError("Contract template load failed", err);
                };
            },
        }
    }

    const OwnedFilesystemPanelView = struct {
        entries: std.ArrayListUnmanaged(panels_bridge.FilesystemEntryView) = .{},
        owned_strings: std.ArrayListUnmanaged([]u8) = .{},
        view: panels_bridge.FilesystemPanelView = .{},

        fn deinit(self: *OwnedFilesystemPanelView, allocator: std.mem.Allocator) void {
            for (self.owned_strings.items) |value| allocator.free(value);
            self.owned_strings.deinit(allocator);
            self.entries.deinit(allocator);
            self.* = undefined;
        }
    };

    const OwnedFilesystemToolsPanelView = struct {
        selected_contract_label: ?[]u8 = null,
        view: panels_bridge.FilesystemToolsPanelView = .{},

        fn deinit(self: *OwnedFilesystemToolsPanelView, allocator: std.mem.Allocator) void {
            if (self.selected_contract_label) |value| allocator.free(value);
            self.* = undefined;
        }
    };

    fn buildFilesystemPanelView(self: *App) OwnedFilesystemPanelView {
        var owned: OwnedFilesystemPanelView = .{};
        const path_label = if (self.filesystem_path.items.len > 0) self.filesystem_path.items else "/";

        var visible = std.ArrayListUnmanaged(VisibleFilesystemEntry){};
        defer visible.deinit(self.allocator);
        for (self.filesystem_entries.items, 0..) |*entry, idx| {
            if (!self.filesystemEntryPassesFilters(entry)) continue;
            visible.append(self.allocator, .{
                .index = idx,
                .entry = entry,
            }) catch {};
        }
        self.sortVisibleFilesystemEntries(visible.items);

        for (visible.items) |visible_entry| {
            const entry = visible_entry.entry;
            var badge: ?[]u8 = null;
            if (self.findMountForPath(entry.path)) |mount| {
                badge = std.fmt.allocPrint(self.allocator, "{s}:{s}", .{ mount.node_id, mount.export_name }) catch null;
                if (badge) |value| {
                    owned.owned_strings.append(self.allocator, value) catch {
                        self.allocator.free(value);
                        badge = null;
                    };
                }
            }

            var size_label: ?[]const u8 = null;
            if (self.formatFilesystemSizeLabel(entry.size_bytes)) |value| {
                if (owned.owned_strings.append(self.allocator, value)) |_| {
                    size_label = value;
                } else |_| {
                    self.allocator.free(value);
                }
            }

            var modified_label: ?[]const u8 = null;
            if (self.formatFilesystemModifiedLabel(entry.modified_unix_ms)) |value| {
                if (owned.owned_strings.append(self.allocator, value)) |_| {
                    modified_label = value;
                } else |_| {
                    self.allocator.free(value);
                }
            }

            owned.entries.append(self.allocator, .{
                .index = visible_entry.index,
                .name = entry.name,
                .path = entry.path,
                .kind = entry.kind,
                .type_label = entry.type_label,
                .hidden = entry.hidden,
                .size_bytes = entry.size_bytes,
                .size_label = size_label,
                .modified_unix_ms = entry.modified_unix_ms,
                .modified_label = modified_label,
                .badge = badge,
                .previewable = entry.previewable,
                .selected = self.filesystem_selected_path != null and std.mem.eql(u8, self.filesystem_selected_path.?, entry.path),
            }) catch {};
        }

        var preview_title: []const u8 = "(select a file to preview)";
        var preview_path = self.filesystem_preview_path;
        var preview_kind = self.filesystem_preview_kind;
        var preview_size_bytes = self.filesystem_preview_size_bytes;
        var preview_modified_unix_ms = self.filesystem_preview_modified_unix_ms;
        var preview_type_label: []const u8 = "unknown";

        if (self.selectedFilesystemEntry()) |entry| {
            if (preview_path == null or (preview_path != null and std.mem.eql(u8, preview_path.?, entry.path))) {
                preview_title = entry.name;
                preview_path = entry.path;
                preview_kind = entry.kind;
                preview_size_bytes = entry.size_bytes orelse preview_size_bytes;
                preview_modified_unix_ms = entry.modified_unix_ms orelse preview_modified_unix_ms;
                preview_type_label = entry.type_label;
            }
        }

        if (preview_path) |value| {
            if (preview_title.len == 0 or std.mem.eql(u8, preview_title, "(select a file to preview)")) {
                preview_title = std.fs.path.basename(value);
            }
            if (preview_type_label.len == 0 or std.mem.eql(u8, preview_type_label, "unknown")) {
                if (self.filesystemPreviewTypeLabel(value, preview_kind)) |label| {
                    if (owned.owned_strings.append(self.allocator, label)) |_| {
                        preview_type_label = label;
                    } else |_| {
                        self.allocator.free(label);
                    }
                }
            }
        }

        var preview_size_label: ?[]const u8 = null;
        if (self.formatFilesystemSizeLabel(preview_size_bytes)) |value| {
            if (owned.owned_strings.append(self.allocator, value)) |_| {
                preview_size_label = value;
            } else |_| {
                self.allocator.free(value);
            }
        }

        var preview_modified_label: ?[]const u8 = null;
        if (self.formatFilesystemModifiedLabel(preview_modified_unix_ms)) |value| {
            if (owned.owned_strings.append(self.allocator, value)) |_| {
                preview_modified_label = value;
            } else |_| {
                self.allocator.free(value);
            }
        }

        owned.view = .{
            .path_label = path_label,
            .error_text = self.filesystem_error,
            .entries = owned.entries.items,
            .total_entry_count = self.filesystem_entries.items.len,
            .visible_entry_count = visible.items.len,
            .preview_title = preview_title,
            .preview_path = preview_path,
            .preview_kind = preview_kind,
            .preview_type_label = preview_type_label,
            .preview_size_bytes = preview_size_bytes,
            .preview_size_label = preview_size_label,
            .preview_modified_unix_ms = preview_modified_unix_ms,
            .preview_modified_label = preview_modified_label,
            .preview_mode = self.filesystem_preview_mode,
            .preview_status = self.filesystem_preview_status,
            .preview_text = self.filesystem_preview_text,
        };
        return owned;
    }

    fn buildFilesystemToolsPanelView(self: *App) OwnedFilesystemToolsPanelView {
        var owned: OwnedFilesystemToolsPanelView = .{};
        owned.selected_contract_label = if (self.selectedContractService()) |entry|
            std.fmt.allocPrint(
                self.allocator,
                "Selected: {s} ({d}/{d})",
                .{ entry.service_id, self.contract_service_selected_index + 1, self.contract_services.items.len },
            ) catch null
        else
            self.allocator.dupe(u8, "Selected: (none loaded)") catch null;

        owned.view = .{
            .selected_contract_label = if (owned.selected_contract_label) |value| value else "Selected: (none loaded)",
            .contract_payload = self.contract_invoke_payload.items,
        };
        return owned;
    }

    fn debugPanelModel(self: *App) panels_bridge.DebugPanelModel {
        const search_trimmed = std.mem.trim(u8, self.debug_search_filter.items, " \t\r\n");
        const selected_node_event = self.selectedNodeServiceEventInfo();
        const selected_idx = selected_node_event.index;
        const base_idx_opt = self.node_service_diff_base_index;
        const can_generate_diff = if (selected_idx) |current_idx|
            if (base_idx_opt) |base_idx|
                base_idx < self.debug_events.items.len and base_idx != current_idx
            else
                false
        else
            false;
        return .{
            .connected = self.ws_client != null,
            .stream_enabled = self.debug_stream_enabled,
            .has_perf_history = self.perf_history.items.len > 0,
            .perf_benchmark_active = self.perf_benchmark_active,
            .has_perf_benchmark_capture = self.hasPerfBenchmarkCapture(),
            .node_watch_enabled = self.node_service_watch_enabled,
            .has_search_filter = search_trimmed.len > 0,
            .has_selected_event = self.debug_selected_index != null and self.debug_selected_index.? < self.debug_events.items.len,
            .has_selected_node_event = selected_node_event.index != null,
            .has_diff_base_or_preview = self.node_service_diff_base_index != null or self.node_service_diff_preview != null,
            .can_generate_diff = can_generate_diff,
        };
    }

    const OwnedDebugPanelView = struct {
        perf_summary: ?[]u8 = null,
        perf_history: ?[]u8 = null,
        perf_command_stats: ?[]u8 = null,
        perf_panel_stats: ?[]u8 = null,
        perf_chart_points: std.ArrayListUnmanaged([]f32) = .{},
        perf_charts: std.ArrayListUnmanaged(panels_bridge.DebugSparklineSeriesView) = .{},
        filtered_indices: std.ArrayListUnmanaged(u32) = .{},
        scope_preview: ?[]u8 = null,
        filter_status: ?[]u8 = null,
        jump_to_node_label: ?[]u8 = null,
        diff_base_label: ?[]u8 = null,
        view: panels_bridge.DebugPanelView = .{},
        event_stream_view: panels_bridge.DebugEventStreamView = .{},

        fn deinit(self: *OwnedDebugPanelView, allocator: std.mem.Allocator) void {
            if (self.perf_summary) |value| allocator.free(value);
            if (self.perf_history) |value| allocator.free(value);
            if (self.perf_command_stats) |value| allocator.free(value);
            if (self.perf_panel_stats) |value| allocator.free(value);
            for (self.perf_chart_points.items) |value| allocator.free(value);
            self.perf_chart_points.deinit(allocator);
            self.perf_charts.deinit(allocator);
            self.filtered_indices.deinit(allocator);
            if (self.scope_preview) |value| allocator.free(value);
            if (self.filter_status) |value| allocator.free(value);
            if (self.jump_to_node_label) |value| allocator.free(value);
            if (self.diff_base_label) |value| allocator.free(value);
            self.* = undefined;
        }
    };

    fn buildDebugPanelView(self: *App) OwnedDebugPanelView {
        var owned: OwnedDebugPanelView = .{};
        const perf_other_ms = @max(
            0.0,
            self.perf_last_frame_ms - (self.perf_last_draw_ms + self.perf_last_ws_ms + self.perf_last_fs_ms + self.perf_last_debug_ms + self.perf_last_terminal_ms),
        );
        owned.perf_summary = std.fmt.allocPrint(
            self.allocator,
            "Perf: {d:.1} fps | frame {d:.2} ms | draw {d:.2} | other {d:.2} | ws-wait {d:.1} | fs-req {d:.1}",
            .{
                self.perf_last_fps,
                self.perf_last_frame_ms,
                self.perf_last_draw_ms,
                perf_other_ms,
                self.perf_last_ws_wait_ms,
                self.perf_last_fs_request_ms,
            },
        ) catch null;

        const perf_span_ms: i64 = if (self.perf_history.items.len >= 2)
            self.perf_history.items[self.perf_history.items.len - 1].timestamp_ms - self.perf_history.items[0].timestamp_ms
        else
            0;
        owned.perf_history = std.fmt.allocPrint(
            self.allocator,
            "Perf history: {d} samples ({d:.1}s) | ws-poll {d:.3} | fs-poll {d:.3}",
            .{
                self.perf_history.items.len,
                @as(f32, @floatFromInt(@max(perf_span_ms, 0))) / 1000.0,
                self.perf_last_ws_ms,
                self.perf_last_fs_ms,
            },
        ) catch null;

        owned.perf_command_stats = std.fmt.allocPrint(
            self.allocator,
            "Cmd/frame: total {d:.0} text {d:.0} ({d:.1}%) shape {d:.0} line {d:.0} image {d:.0} clip {d:.0} text-bytes {d:.0}",
            .{
                self.perf_last_cmd_total_per_frame,
                self.perf_last_cmd_text_per_frame,
                self.perf_last_text_command_share_pct,
                self.perf_last_cmd_shape_per_frame,
                self.perf_last_cmd_line_per_frame,
                self.perf_last_cmd_image_per_frame,
                self.perf_last_cmd_clip_per_frame,
                self.perf_last_text_bytes_per_frame,
            },
        ) catch null;

        owned.perf_panel_stats = std.fmt.allocPrint(
            self.allocator,
            "Panel draw ms: debug {d:.2} settings {d:.2} chat {d:.2} fs {d:.2} terminal {d:.2} projects {d:.2} other {d:.2}",
            .{
                self.perf_last_panel_debug_ms,
                self.perf_last_panel_settings_ms,
                self.perf_last_panel_chat_ms,
                self.perf_last_panel_filesystem_ms,
                self.perf_last_panel_terminal_ms,
                self.perf_last_panel_projects_ms,
                self.perf_last_panel_other_ms,
            },
        ) catch null;

        const spark_samples: []const PerfSample = blk: {
            const window: usize = 240;
            if (self.perf_history.items.len > window) {
                break :blk self.perf_history.items[self.perf_history.items.len - window ..];
            }
            break :blk self.perf_history.items;
        };
        const chart_labels = [_][]const u8{ "Frame ms", "Draw ms", "WS wait ms", "FS req ms" };
        var chart_idx: usize = 0;
        while (chart_idx < chart_labels.len) : (chart_idx += 1) {
            const points = self.allocator.alloc(f32, spark_samples.len) catch break;
            var sample_idx: usize = 0;
            while (sample_idx < spark_samples.len) : (sample_idx += 1) {
                points[sample_idx] = switch (chart_idx) {
                    0 => spark_samples[sample_idx].frame_ms,
                    1 => spark_samples[sample_idx].draw_ms,
                    2 => spark_samples[sample_idx].ws_wait_ms,
                    3 => spark_samples[sample_idx].fs_request_ms,
                    else => 0.0,
                };
            }
            owned.perf_chart_points.append(self.allocator, points) catch {
                self.allocator.free(points);
                break;
            };
            owned.perf_charts.append(self.allocator, .{
                .label = chart_labels[chart_idx],
                .points = points,
            }) catch {};
        }

        const role_name = if (self.config.active_role == .admin) "admin" else "user";
        owned.scope_preview = if (self.selectedProjectId()) |project_id| blk: {
            const token_present = if (self.selectedProjectToken(project_id)) |token| token.len > 0 else false;
            break :blk std.fmt.allocPrint(
                self.allocator,
                "Node watch scope: role={s} project={s} token={s}",
                .{ role_name, project_id, if (token_present) "set" else "none" },
            ) catch null;
        } else std.fmt.allocPrint(
            self.allocator,
            "Node watch scope: role={s} project=(session default)",
            .{role_name},
        ) catch null;

        const search_trimmed = std.mem.trim(u8, self.debug_search_filter.items, " \t\r\n");
        const filtered_source = self.ensureDebugFilteredIndices(search_trimmed);
        owned.filtered_indices.appendSlice(self.allocator, filtered_source) catch {};
        const filtered_events = owned.filtered_indices.items.len;
        owned.filter_status = std.fmt.allocPrint(
            self.allocator,
            "Showing {d}/{d} events",
            .{ filtered_events, self.debug_events.items.len },
        ) catch null;

        const selected_node_event = self.selectedNodeServiceEventInfo();
        if (selected_node_event.node_id) |selected_node_id| {
            owned.jump_to_node_label = std.fmt.allocPrint(
                self.allocator,
                "Jump To Node FS ({s})",
                .{selected_node_id},
            ) catch null;
        }
        if (selected_node_event.index != null) {
            owned.diff_base_label = if (self.node_service_diff_base_index) |idx|
                if (idx < self.debug_events.items.len)
                    std.fmt.allocPrint(
                        self.allocator,
                        "Diff base event: #{d}",
                        .{self.debug_events.items[idx].id},
                    ) catch null
                else
                    self.allocator.dupe(u8, "Diff base event: (stale selection)") catch null
            else
                self.allocator.dupe(u8, "Diff base event: (not set)") catch null;
        }

        const show_large_payload_notice = if (selected_node_event.index) |selected_idx|
            selected_idx < self.debug_events.items.len and
                self.debug_events.items[selected_idx].payload_json.len > DEBUG_SYNTAX_COLOR_MAX_PAYLOAD_BYTES
        else
            false;

        owned.view = .{
            .title = "SpiderWeb Debug Stream",
            .stream_status = if (self.debug_stream_enabled) "Status: live WebSocket debug events" else "Status: paused",
            .snapshot_status = if (self.debug_stream_snapshot_pending)
                "Snapshot: refresh pending"
            else if (self.debug_stream_snapshot != null)
                "Snapshot: cached"
            else
                "Snapshot: none",
            .perf_summary = if (owned.perf_summary) |value| value else "Perf: collecting...",
            .perf_history = if (owned.perf_history) |value| value else "Perf history: unavailable",
            .perf_command_stats = if (owned.perf_command_stats) |value| value else "Cmd/frame: collecting...",
            .perf_panel_stats = if (owned.perf_panel_stats) |value| value else "Panel draw: collecting...",
            .benchmark_status = if (self.perf_benchmark_active)
                "Benchmark capture: active"
            else if (self.hasPerfBenchmarkCapture())
                "Benchmark capture: ready"
            else
                "Benchmark capture: idle",
            .perf_benchmark_label = self.perf_benchmark_label_input.items,
            .perf_charts = owned.perf_charts.items,
            .node_watch_status = if (self.node_service_watch_enabled)
                "Node service events: polling worldfs snapshot"
            else
                "Node service events: paused",
            .scope_preview = if (owned.scope_preview) |value| value else "Node watch scope: role/project unavailable",
            .show_user_scope_notice = self.config.active_role == .user,
            .node_watch_filter = self.node_service_watch_filter.items,
            .node_watch_replay_limit = self.node_service_watch_replay_limit.items,
            .debug_search_filter = self.debug_search_filter.items,
            .filter_status = if (owned.filter_status) |value| value else "Showing events",
            .jump_to_node_label = owned.jump_to_node_label,
            .diff_base_label = owned.diff_base_label,
            .latest_reload_diag = self.node_service_latest_reload_diag,
            .selected_diag = selected_node_event.diagnostics,
            .diff_preview = self.node_service_diff_preview,
            .show_large_payload_notice = show_large_payload_notice,
        };
        owned.event_stream_view = .{
            .filtered_indices = owned.filtered_indices.items,
            .selected_index = self.debug_selected_index,
        };
        return owned;
    }

    fn performDebugPanelAction(self: *App, manager: *panel_manager.PanelManager, action: panels_bridge.DebugPanelAction) void {
        switch (action) {
            .toggle_stream => {
                self.debug_stream_enabled = !self.debug_stream_enabled;
                if (self.debug_stream_enabled) {
                    self.requestDebugStreamSnapshot(true);
                }
            },
            .refresh_snapshot => {
                self.requestDebugStreamSnapshot(true);
            },
            .copy_perf => {
                const report = self.buildPerfReportText() catch null;
                defer if (report) |value| self.allocator.free(value);
                if (report) |value| {
                    self.copyTextToClipboard(value) catch {};
                    self.appendMessage("system", "Copied GUI perf report to clipboard.", null) catch {};
                }
            },
            .export_perf => {
                const report = self.buildPerfReportText() catch null;
                defer if (report) |value| self.allocator.free(value);
                if (report) |value| {
                    const export_path = self.exportPerfReport(value) catch null;
                    defer if (export_path) |path| self.allocator.free(path);
                    if (export_path) |path| {
                        const msg = std.fmt.allocPrint(self.allocator, "Exported GUI perf report to {s}", .{path}) catch null;
                        defer if (msg) |text| self.allocator.free(text);
                        if (msg) |text| self.appendMessage("system", text, null) catch {};
                    }
                }
            },
            .clear_perf => {
                self.perf_history.clearRetainingCapacity();
                self.clearPerfBenchmarkCapture();
                if (self.perf_benchmark_active) {
                    self.perf_benchmark_start_sample_index = 0;
                    self.perf_benchmark_start_timestamp_ms = std.time.milliTimestamp();
                }
                self.appendMessage("system", "Cleared GUI perf history.", null) catch {};
            },
            .toggle_benchmark => {
                if (self.perf_benchmark_active) {
                    self.stopPerfBenchmark() catch {};
                    const label = self.perf_benchmark_last_label orelse "benchmark";
                    const duration_ms = @max(0, self.perf_benchmark_last_end_timestamp_ms - self.perf_benchmark_last_start_timestamp_ms);
                    const msg = std.fmt.allocPrint(
                        self.allocator,
                        "Stopped benchmark '{s}' ({d:.2}s).",
                        .{ label, @as(f32, @floatFromInt(duration_ms)) / 1000.0 },
                    ) catch null;
                    defer if (msg) |text| self.allocator.free(text);
                    if (msg) |text| self.appendMessage("system", text, null) catch {};
                } else {
                    self.startPerfBenchmark() catch {};
                    const label = self.perf_benchmark_active_label orelse "benchmark";
                    const msg = std.fmt.allocPrint(self.allocator, "Started benchmark '{s}'.", .{label}) catch null;
                    defer if (msg) |text| self.allocator.free(text);
                    if (msg) |text| self.appendMessage("system", text, null) catch {};
                }
            },
            .copy_benchmark => {
                const report = self.buildBenchmarkPerfReportText() catch null;
                defer if (report) |value| self.allocator.free(value);
                if (report) |value| {
                    self.copyTextToClipboard(value) catch {};
                    self.appendMessage("system", "Copied benchmark perf report to clipboard.", null) catch {};
                }
            },
            .export_benchmark => {
                const report = self.buildBenchmarkPerfReportText() catch null;
                defer if (report) |value| self.allocator.free(value);
                if (report) |value| {
                    const export_path = self.exportPerfReport(value) catch null;
                    defer if (export_path) |path| self.allocator.free(path);
                    if (export_path) |path| {
                        const msg = std.fmt.allocPrint(self.allocator, "Exported benchmark perf report to {s}", .{path}) catch null;
                        defer if (msg) |text| self.allocator.free(text);
                        if (msg) |text| self.appendMessage("system", text, null) catch {};
                    }
                }
            },
            .clear_benchmark => {
                if (self.perf_benchmark_active) self.stopPerfBenchmark() catch {};
                self.clearPerfBenchmarkCapture();
                self.appendMessage("system", "Cleared benchmark capture.", null) catch {};
            },
            .refresh_node_feed => {
                self.subscribeNodeServiceEventsFromUi() catch |err| {
                    std.log.warn("node watch update failed: {s}", .{@errorName(err)});
                };
            },
            .pause_node_feed => {
                self.unsubscribeNodeServiceEventsFromUi() catch |err| {
                    std.log.warn("node unwatch failed: {s}", .{@errorName(err)});
                };
            },
            .clear_search => {
                self.debug_search_filter.clearRetainingCapacity();
                self.debug_selected_index = null;
                self.clearSelectedNodeServiceEventCache();
                self.debug_scroll_y = 0;
            },
            .jump_to_selected_node_fs => {
                const selected = self.selectedNodeServiceEventInfo();
                const node_id = selected.node_id orelse return;
                self.jumpFilesystemToNode(manager, node_id) catch |err| {
                    std.log.warn("jump to node fs failed: {s}", .{@errorName(err)});
                };
            },
            .set_diff_base => {
                const selected_idx = self.selectedNodeServiceEventInfo().index orelse return;
                self.node_service_diff_base_index = selected_idx;
                self.clearNodeServiceDiffPreview();
                const msg = std.fmt.allocPrint(self.allocator, "Node diff base set to event #{d}", .{self.debug_events.items[selected_idx].id}) catch null;
                defer if (msg) |value| self.allocator.free(value);
                if (msg) |value| self.appendMessage("system", value, null) catch {};
            },
            .clear_diff_base => {
                self.node_service_diff_base_index = null;
                self.clearNodeServiceDiffPreview();
            },
            .generate_diff => {
                const selected_idx = self.selectedNodeServiceEventInfo().index orelse return;
                const base_idx = self.node_service_diff_base_index orelse return;
                if (base_idx >= self.debug_events.items.len or base_idx == selected_idx) return;
                if (self.buildNodeServiceEventDiffText(base_idx, selected_idx) catch null) |diff| {
                    self.clearNodeServiceDiffPreview();
                    self.node_service_diff_preview = diff;
                } else {
                    self.appendMessage("system", "Unable to build node service diff from selected events.", null) catch {};
                }
            },
            .copy_diff => {
                const selected_idx = self.selectedNodeServiceEventInfo().index orelse return;
                const base_idx = self.node_service_diff_base_index orelse return;
                if (base_idx >= self.debug_events.items.len or base_idx == selected_idx) return;
                const diff_text = if (self.node_service_diff_preview) |value|
                    self.allocator.dupe(u8, value) catch null
                else
                    (self.buildNodeServiceEventDiffText(base_idx, selected_idx) catch null);
                defer if (diff_text) |value| self.allocator.free(value);
                if (diff_text) |value| {
                    self.copyTextToClipboard(value) catch {};
                    self.appendMessage("system", "Copied node service diff snapshot to clipboard.", null) catch {};
                }
            },
            .export_diff => {
                const selected_idx = self.selectedNodeServiceEventInfo().index orelse return;
                const base_idx = self.node_service_diff_base_index orelse return;
                if (base_idx >= self.debug_events.items.len or base_idx == selected_idx) return;
                const diff_text = if (self.node_service_diff_preview) |value|
                    self.allocator.dupe(u8, value) catch null
                else
                    (self.buildNodeServiceEventDiffText(base_idx, selected_idx) catch null);
                defer if (diff_text) |value| self.allocator.free(value);
                if (diff_text) |value| {
                    const export_path = self.exportNodeServiceDiffSnapshot(
                        value,
                        self.debug_events.items[base_idx].id,
                        self.debug_events.items[selected_idx].id,
                    ) catch null;
                    defer if (export_path) |path| self.allocator.free(path);
                    if (export_path) |path| {
                        const msg = std.fmt.allocPrint(self.allocator, "Exported node diff snapshot to {s}", .{path}) catch null;
                        defer if (msg) |text| self.allocator.free(text);
                        if (msg) |text| self.appendMessage("system", text, null) catch {};
                    } else {
                        self.appendMessage("system", "Failed to export node diff snapshot.", null) catch {};
                    }
                }
            },
            .copy_selected_event => {
                const sel_idx = self.debug_selected_index orelse return;
                if (sel_idx >= self.debug_events.items.len) return;
                const entry = self.debug_events.items[sel_idx];
                const to_copy = self.formatDebugEventLine(entry) catch "";
                defer if (to_copy.len > 0) self.allocator.free(to_copy);
                if (to_copy.len > 0) {
                    self.copyTextToClipboard(to_copy) catch {};
                    self.appendMessage("system", "Copied debug event.", null) catch {};
                }
            },
        }
    }

    fn launcherSettingsModel(self: *App) panels_bridge.LauncherSettingsModel {
        const connection_state: panels_bridge.SettingsConnectionState = switch (self.connection_state) {
            .disconnected => .disconnected,
            .connecting => .connecting,
            .connected => .connected,
            .error_state => .error_state,
        };
        const active_role: panels_bridge.ConnectRole = switch (self.config.active_role) {
            .admin => .admin,
            .user => .user,
        };
        const terminal_backend: panels_bridge.SettingsTerminalBackend = switch (self.settings_panel.terminal_backend_kind) {
            .plain_text => .plain_text,
            .ghostty_vt => .ghostty_vt,
        };
        return .{
            .connection_state = connection_state,
            .active_role = active_role,
            .watch_theme_pack = self.settings_panel.watch_theme_pack,
            .auto_connect_on_launch = self.settings_panel.auto_connect_on_launch,
            .ws_verbose_logs = self.settings_panel.ws_verbose_logs,
            .terminal_backend = terminal_backend,
        };
    }

    fn performLauncherSettingsAction(self: *App, manager: *panel_manager.PanelManager, action: panels_bridge.LauncherSettingsAction) void {
        switch (action) {
            .set_connect_role => |role| {
                const target_role = switch (role) {
                    .admin => config_mod.Config.TokenRole.admin,
                    .user => config_mod.Config.TokenRole.user,
                };
                self.setActiveConnectRole(target_role) catch |err| {
                    std.log.err("Failed to set connect role {s}: {s}", .{ @tagName(role), @errorName(err) });
                };
            },
            .toggle_watch_theme_pack => {
                self.settings_panel.watch_theme_pack = !self.settings_panel.watch_theme_pack;
            },
            .toggle_auto_connect_on_launch => {
                self.settings_panel.auto_connect_on_launch = !self.settings_panel.auto_connect_on_launch;
            },
            .toggle_ws_verbose_logs => {
                self.settings_panel.ws_verbose_logs = !self.settings_panel.ws_verbose_logs;
                if (self.ws_client) |*client| {
                    client.setVerboseLogs(self.settings_panel.ws_verbose_logs);
                }
            },
            .set_terminal_backend => |backend| {
                self.settings_panel.terminal_backend_kind = switch (backend) {
                    .plain_text => .plain_text,
                    .ghostty_vt => .ghostty_vt,
                };
                self.applySelectedTerminalBackend();
            },
            .connect => {
                self.tryConnect(manager) catch {};
            },
            .save_config => {
                self.saveConfig() catch |err| {
                    self.setConnectionState(.error_state, "Failed to save config");
                    std.log.err("Save config failed: {s}", .{@errorName(err)});
                };
            },
            .load_history => {
                self.loadSessionHistoryFromServer(true) catch |err| {
                    if (self.formatControlOpError("Session history failed", err)) |msg| {
                        defer self.allocator.free(msg);
                        self.setWorkspaceError(msg);
                    }
                };
            },
            .restore_last => {
                self.restoreLastSessionFromServer() catch |err| {
                    if (self.formatControlOpError("Session restore failed", err)) |msg| {
                        defer self.allocator.free(msg);
                        self.setWorkspaceError(msg);
                    }
                };
            },
        }
    }

    fn terminalPanelModel(self: *App) panels_bridge.TerminalPanelModel {
        return .{
            .connected = self.connection_state == .connected,
            .has_session = self.terminal_session_id != null,
            .auto_poll = self.terminal_auto_poll,
            .has_input = std.mem.trim(u8, self.terminal_input.items, " \t\r\n").len > 0,
            .has_output = self.terminal_backend.text().len > 0,
        };
    }

    const OwnedTerminalPanelView = struct {
        view: panels_bridge.TerminalPanelView,
        backend_line: ?[]u8 = null,
        session_line: ?[]u8 = null,

        fn deinit(self: *OwnedTerminalPanelView, allocator: std.mem.Allocator) void {
            if (self.backend_line) |value| allocator.free(value);
            if (self.session_line) |value| allocator.free(value);
            self.* = undefined;
        }
    };

    fn terminalPanelViewOwned(self: *App) OwnedTerminalPanelView {
        const backend_line = std.fmt.allocPrint(
            self.allocator,
            "Backend: {s} (selected: {s}, build default: {s})",
            .{
                self.terminal_backend.label(),
                terminal_render_backend.Backend.kindName(self.terminal_backend_kind),
                TERMINAL_BACKEND_KIND,
            },
        ) catch null;
        const session_line = if (self.terminal_session_id) |id|
            std.fmt.allocPrint(self.allocator, "Session: {s}", .{id}) catch null
        else
            self.allocator.dupe(u8, "Session: (not started)") catch null;
        return .{
            .view = .{
                .title = "Terminal",
                .backend_line = backend_line orelse "Backend: unknown",
                .backend_detail = self.terminal_backend.statusDetail(),
                .session_line = session_line orelse "Session: (unknown)",
                .status_text = self.terminal_status,
                .error_text = self.terminal_error,
                .input_text = self.terminal_input.items,
                .start_label = if (self.terminal_session_id == null) "Start" else "Restart",
            },
            .backend_line = backend_line,
            .session_line = session_line,
        };
    }

    fn performTerminalPanelAction(self: *App, action: panels_bridge.TerminalPanelAction) void {
        switch (action) {
            .start_or_restart => {
                if (self.terminal_session_id != null) {
                    self.closeTerminalSession() catch {};
                }
                self.ensureTerminalSession() catch |err| {
                    const msg = self.formatFilesystemOpError("Terminal start failed", err);
                    if (msg) |text| {
                        defer self.allocator.free(text);
                        self.setTerminalError(text);
                    }
                };
            },
            .stop => {
                self.closeTerminalSession() catch |err| {
                    const msg = self.formatFilesystemOpError("Terminal close failed", err);
                    if (msg) |text| {
                        defer self.allocator.free(text);
                        self.setTerminalError(text);
                    }
                };
            },
            .read => {
                self.terminalReadOnce(50) catch |err| {
                    const msg = self.formatFilesystemOpError("Terminal read failed", err);
                    if (msg) |text| {
                        defer self.allocator.free(text);
                        self.setTerminalError(text);
                    }
                };
            },
            .resize_default => {
                self.resizeTerminalSession(120, 36) catch |err| {
                    const msg = self.formatFilesystemOpError("Terminal resize failed", err);
                    if (msg) |text| {
                        defer self.allocator.free(text);
                        self.setTerminalError(text);
                    }
                };
            },
            .clear_output => {
                self.terminal_backend.clear(self.allocator);
                self.clearTerminalError();
                self.setTerminalStatus("Output cleared");
            },
            .toggle_auto_poll => {
                self.terminal_auto_poll = !self.terminal_auto_poll;
            },
            .send_ctrl_c => {
                self.sendTerminalControlC() catch |err| {
                    const msg = self.formatFilesystemOpError("Terminal control failed", err);
                    if (msg) |text| {
                        defer self.allocator.free(text);
                        self.setTerminalError(text);
                    }
                };
            },
            .send_input => {
                self.sendTerminalInputFromUi() catch |err| {
                    const msg = self.formatFilesystemOpError("Terminal send failed", err);
                    if (msg) |text| {
                        defer self.allocator.free(text);
                        self.setTerminalError(text);
                    }
                };
            },
            .copy_output => {
                self.copyTextToClipboard(self.terminal_backend.text()) catch {};
                self.setTerminalStatus("Copied terminal output");
            },
        }
    }

    fn drawFilesystemPanel(self: *App, manager: *panel_manager.PanelManager, rect: UiRect) void {
        _ = manager;
        if (self.connection_state == .connected and
            self.filesystem_entries.items.len == 0 and
            self.filesystem_active_request == null and
            self.filesystem_pending_path == null)
        {
            self.requestFilesystemBrowserRefresh(true);
        }

        const model = self.filesystemPanelModel();
        const host = FilesystemPanel.Host{
            .ctx = @ptrCast(self),
            .draw_label = launcherSettingsDrawLabel,
            .draw_text_trimmed = launcherSettingsDrawTextTrimmed,
            .draw_text_input = launcherSettingsDrawTextInput,
            .draw_button = launcherSettingsDrawButton,
            .draw_surface_panel = filesystemDrawSurfacePanel,
            .draw_text_wrapped = filesystemDrawTextWrapped,
            .draw_filled_rect = filesystemDrawFilledRect,
            .draw_rect = filesystemDrawRect,
        };
        const path_label = if (self.filesystem_path.items.len > 0) self.filesystem_path.items else "/";
        var view = self.buildFilesystemPanelView();
        defer view.deinit(self.allocator);
        var panel_state = FilesystemPanel.State{
            .entry_page = self.filesystem_entry_page,
            .last_clicked_entry_index = self.filesystem_last_clicked_entry_index,
            .last_click_ms = self.filesystem_last_click_ms,
            .type_column_width = self.filesystem_type_column_width,
            .modified_column_width = self.filesystem_modified_column_width,
            .size_column_width = self.filesystem_size_column_width,
            .column_resize = self.filesystem_column_resize_handle,
            .preview_split_ratio = self.filesystem_preview_split_ratio,
            .preview_split_dragging = self.filesystem_preview_split_dragging,
        };
        const action = FilesystemPanel.draw(
            host,
            Rect{ .min = rect.min, .max = rect.max },
            self.panelLayoutMetrics(),
            model,
            view.view,
            .{
                .text_primary = self.theme.colors.text_primary,
                .text_secondary = self.theme.colors.text_secondary,
                .primary = self.theme.colors.primary,
                .border = self.theme.colors.border,
                .surface = self.theme.colors.surface,
                .error_text = zcolors.rgba(220, 80, 80, 255),
            },
            .{
                .mouse_x = self.mouse_x,
                .mouse_y = self.mouse_y,
                .mouse_down = self.mouse_down,
                .mouse_clicked = self.mouse_clicked,
                .mouse_released = self.mouse_released,
            },
            &panel_state,
        );
        self.filesystem_entry_page = panel_state.entry_page;
        self.filesystem_last_clicked_entry_index = panel_state.last_clicked_entry_index;
        self.filesystem_last_click_ms = panel_state.last_click_ms;
        self.filesystem_type_column_width = panel_state.type_column_width;
        self.filesystem_modified_column_width = panel_state.modified_column_width;
        self.filesystem_size_column_width = panel_state.size_column_width;
        self.filesystem_column_resize_handle = panel_state.column_resize;
        self.filesystem_preview_split_ratio = panel_state.preview_split_ratio;
        self.filesystem_preview_split_dragging = panel_state.preview_split_dragging;
        if (action) |value| {
            self.performFilesystemPanelAction(value, path_label);
        }
    }

    fn drawFilesystemToolsPanel(self: *App, manager: *panel_manager.PanelManager, rect: UiRect) void {
        _ = manager;
        const model = self.filesystemToolsPanelModel();
        const host = FilesystemToolsPanel.Host{
            .ctx = @ptrCast(self),
            .draw_text_trimmed = launcherSettingsDrawTextTrimmed,
            .draw_text_input = launcherSettingsDrawTextInput,
            .draw_button = launcherSettingsDrawButton,
            .draw_surface_panel = filesystemDrawSurfacePanel,
            .draw_text_wrapped = filesystemDrawTextWrapped,
            .draw_rect = filesystemDrawRect,
        };
        var view = self.buildFilesystemToolsPanelView();
        defer view.deinit(self.allocator);
        var panel_state = FilesystemToolsPanel.State{
            .focused_field = filesystemToolsFocusFieldToExternal(self.settings_panel.focused_field),
        };
        const action = FilesystemToolsPanel.draw(
            host,
            Rect{ .min = rect.min, .max = rect.max },
            self.panelLayoutMetrics(),
            model,
            view.view,
            .{
                .mouse_x = self.mouse_x,
                .mouse_y = self.mouse_y,
                .mouse_released = self.mouse_released,
            },
            .{
                .text_primary = self.theme.colors.text_primary,
                .text_secondary = self.theme.colors.text_secondary,
                .primary = self.theme.colors.primary,
                .border = self.theme.colors.border,
                .surface = self.theme.colors.surface,
            },
            &panel_state,
        );
        const mapped_focus = filesystemToolsFocusFieldFromExternal(panel_state.focused_field);
        if (mapped_focus != .none or isFilesystemToolsPanelFocusField(self.settings_panel.focused_field)) {
            self.settings_panel.focused_field = mapped_focus;
        }
        if (action) |value| self.performFilesystemToolsPanelAction(value);
    }

    fn drawDebugPanel(self: *App, manager: *panel_manager.PanelManager, rect: UiRect) void {
        const host = DebugPanel.Host{
            .ctx = @ptrCast(self),
            .draw_label = launcherSettingsDrawLabel,
            .draw_text_trimmed = launcherSettingsDrawTextTrimmed,
            .draw_text_input = launcherSettingsDrawTextInput,
            .draw_button = launcherSettingsDrawButton,
            .draw_text_wrapped = filesystemDrawTextWrapped,
            .draw_perf_charts = debugDrawPerfCharts,
            .draw_event_stream = debugDrawEventStream,
        };
        var view = self.buildDebugPanelView();
        defer view.deinit(self.allocator);
        var panel_state = DebugPanel.State{
            .focused_field = debugFocusFieldToExternal(self.settings_panel.focused_field),
        };
        const action = DebugPanel.draw(
            host,
            Rect{ .min = rect.min, .max = rect.max },
            self.panelLayoutMetrics(),
            .{
                .text_primary = self.theme.colors.text_primary,
                .text_secondary = self.theme.colors.text_secondary,
            },
            self.debugPanelModel(),
            view.view,
            view.event_stream_view,
            .{
                .mouse_x = self.mouse_x,
                .mouse_y = self.mouse_y,
                .mouse_released = self.mouse_released,
            },
            &panel_state,
        );
        const mapped_focus = debugFocusFieldFromExternal(panel_state.focused_field);
        if (mapped_focus != .none or isDebugPanelFocusField(self.settings_panel.focused_field)) {
            self.settings_panel.focused_field = mapped_focus;
        }
        if (action) |value| self.performDebugPanelAction(manager, value);
    }

    const SparklinePointsCtx = struct {
        points: []const f32,
    };

    fn sparklinePointAt(ctx: *const anyopaque, idx: usize) f32 {
        const points_ctx: *const SparklinePointsCtx = @ptrCast(@alignCast(ctx));
        return if (idx < points_ctx.points.len) points_ctx.points[idx] else 0.0;
    }

    fn drawDebugPerfCharts(
        self: *App,
        rect: Rect,
        layout: PanelLayoutMetrics,
        y_start: f32,
        perf_charts: []const panels_bridge.DebugSparklineSeriesView,
    ) f32 {
        const pad = layout.inset;
        const line_height = layout.line_height;
        const row_height = layout.button_height;
        const width = rect.max[0] - rect.min[0];
        const content_width = @max(240.0, width - pad * 2.0);
        var y = y_start;
        if (perf_charts.len == 0) return y;
        const spark_gap = @max(6.0 * self.ui_scale, layout.inner_inset * 0.8);
        const spark_h = @max(52.0 * self.ui_scale, row_height * 1.9);
        const spark_min_card_w = @max(150.0 * self.ui_scale, 90.0);
        const spark_chart_count: usize = perf_charts.len;
        const spark_cols_float = @floor((content_width + spark_gap) / (spark_min_card_w + spark_gap));
        const spark_cols = std.math.clamp(@as(usize, @intFromFloat(@max(1.0, spark_cols_float))), 1, spark_chart_count);
        const spark_rows = @divTrunc(spark_chart_count + spark_cols - 1, spark_cols);
        const spark_card_w = @max(72.0 * self.ui_scale, (content_width - spark_gap * @as(f32, @floatFromInt(spark_cols - 1))) / @as(f32, @floatFromInt(spark_cols)));
        const spark_label_h = line_height;
        const spark_row_h = spark_label_h + spark_h + layout.row_gap * 0.35;
        self.drawTextTrimmed(rect.min[0] + pad, y, content_width, "Perf sparkline charts (recent window)", self.theme.colors.text_secondary);
        y += line_height;

        for (perf_charts, 0..) |chart, idx| {
            const row = @divTrunc(idx, spark_cols);
            const col = idx % spark_cols;
            const row_y = y + @as(f32, @floatFromInt(row)) * spark_row_h;
            const x = rect.min[0] + pad + @as(f32, @floatFromInt(col)) * (spark_card_w + spark_gap);
            const chart_rect = Rect.fromXYWH(x, row_y + spark_label_h, spark_card_w, spark_h);
            self.drawTextCenteredTrimmed(
                x + spark_card_w * 0.5,
                row_y,
                spark_card_w - @max(8.0 * self.ui_scale, 4.0),
                chart.label,
                self.theme.colors.text_secondary,
            );
            var points_ctx = SparklinePointsCtx{ .points = chart.points };
            const stroke_color = switch (idx) {
                0 => zcolors.rgba(92, 173, 255, 255),
                1 => zcolors.rgba(255, 170, 72, 255),
                2 => zcolors.rgba(175, 122, 255, 255),
                3 => zcolors.rgba(98, 205, 128, 255),
                else => self.theme.colors.primary,
            };
            widgets.sparkline.draw(
                &self.ui_commands,
                chart_rect,
                .{ .ctx = @as(*const anyopaque, @ptrCast(&points_ctx)), .count = chart.points.len, .at = &sparklinePointAt },
                .{
                    .stroke_color = stroke_color,
                    .fill_color = zcolors.withAlpha(stroke_color, 0.28),
                    .background_color = zcolors.withAlpha(self.theme.colors.surface, 0.96),
                    .border_color = self.theme.colors.border,
                    .max_columns = PERF_SPARKLINE_MAX_COLUMNS,
                },
            );
        }
        return y + @as(f32, @floatFromInt(spark_rows)) * spark_row_h + layout.row_gap * 0.2;
    }

    fn drawDebugEventStream(self: *App, output_rect: Rect, view: panels_bridge.DebugEventStreamView) void {
        const host = DebugEventStreamPanel.Host{
            .ctx = @ptrCast(self),
            .set_output_rect = debugEventStreamSetOutputRect,
            .focus_panel = debugEventStreamFocusPanel,
            .draw_surface_panel = filesystemDrawSurfacePanel,
            .push_clip = debugEventStreamPushClip,
            .pop_clip = debugEventStreamPopClip,
            .draw_filled_rect = debugEventStreamDrawFilledRect,
            .draw_button = launcherSettingsDrawButton,
            .get_scroll_y = debugEventStreamGetScrollY,
            .set_scroll_y = debugEventStreamSetScrollY,
            .get_scrollbar_dragging = debugEventStreamGetScrollbarDragging,
            .set_scrollbar_dragging = debugEventStreamSetScrollbarDragging,
            .get_drag_start_y = debugEventStreamGetDragStartY,
            .set_drag_start_y = debugEventStreamSetDragStartY,
            .get_drag_start_scroll_y = debugEventStreamGetDragStartScrollY,
            .set_drag_start_scroll_y = debugEventStreamSetDragStartScrollY,
            .set_drag_capture = debugEventStreamSetDragCapture,
            .release_drag_capture = debugEventStreamReleaseDragCapture,
            .entry_height = debugEventStreamEntryHeight,
            .draw_entry = debugEventStreamDrawEntry,
            .select_entry = debugEventStreamSelectEntry,
            .copy_selected_event = debugEventStreamCopySelectedEvent,
            .selected_event_count = debugEventStreamSelectedEventCount,
        };
        DebugEventStreamPanel.draw(
            host,
            output_rect,
            self.panelLayoutMetrics(),
            self.ui_scale,
            .{
                .primary = self.theme.colors.primary,
                .border = self.theme.colors.border,
            },
            view,
            .{
                .mouse_x = self.mouse_x,
                .mouse_y = self.mouse_y,
                .mouse_clicked = self.mouse_clicked,
                .mouse_down = self.mouse_down,
            },
        );
    }
    fn makeDebugFoldKey(event_id: u64, line_index: usize) DebugFoldKey {
        return .{
            .event_id = event_id,
            .line_index = @intCast(line_index),
        };
    }

    fn isDebugBlockCollapsed(self: *App, event_id: u64, line_index: usize) bool {
        return self.debug_folded_blocks.contains(makeDebugFoldKey(event_id, line_index));
    }

    fn toggleDebugBlockCollapsed(self: *App, event_id: u64, line_index: usize) void {
        const key = makeDebugFoldKey(event_id, line_index);
        if (self.debug_folded_blocks.contains(key)) {
            _ = self.debug_folded_blocks.remove(key);
            self.debug_fold_revision +%= 1;
            if (self.debug_fold_revision == 0) self.debug_fold_revision = 1;
            return;
        }
        self.debug_folded_blocks.put(key, {}) catch {};
        self.debug_fold_revision +%= 1;
        if (self.debug_fold_revision == 0) self.debug_fold_revision = 1;
    }

    fn pruneDebugFoldStateForEvent(self: *App, event_id: u64) void {
        var to_remove: std.ArrayList(DebugFoldKey) = .empty;
        defer to_remove.deinit(self.allocator);

        var it = self.debug_folded_blocks.keyIterator();
        while (it.next()) |key_ptr| {
            if (key_ptr.*.event_id == event_id) {
                to_remove.append(self.allocator, key_ptr.*) catch return;
            }
        }
        for (to_remove.items) |key| {
            _ = self.debug_folded_blocks.remove(key);
        }
        if (to_remove.items.len > 0) {
            self.debug_fold_revision +%= 1;
            if (self.debug_fold_revision == 0) self.debug_fold_revision = 1;
        }
    }

    fn ensureDebugPayloadLines(self: *App, entry: *DebugEventEntry) void {
        if (entry.payload_lines.items.len > 0) return;
        if (entry.payload_json.len == 0) return;
        entry.payload_lines = self.buildDebugPayloadLines(entry.payload_json) catch .empty;
        entry.payload_wrap_rows.clearRetainingCapacity();
        entry.payload_visible_line_indices.clearRetainingCapacity();
        entry.payload_visible_line_row_starts.clearRetainingCapacity();
        entry.payload_visible_lines_valid = false;
        entry.payload_wrap_rows_valid = false;
        entry.cached_visible_rows_valid = false;
    }

    fn ensureDebugPayloadWrapRows(self: *App, output_min_x: f32, content_max_x: f32, entry: *DebugEventEntry) void {
        if (entry.payload_lines.items.len == 0) return;
        const wrap_width = @max(1.0, content_max_x - output_min_x);
        if (entry.payload_wrap_rows_valid and
            @abs(entry.payload_wrap_rows_wrap_width - wrap_width) < 0.5 and
            entry.payload_wrap_rows.items.len == entry.payload_lines.items.len)
        {
            return;
        }

        entry.payload_wrap_rows.clearRetainingCapacity();
        entry.payload_wrap_rows_valid = false;
        entry.payload_wrap_rows.ensureTotalCapacity(self.allocator, entry.payload_lines.items.len) catch return;

        const space_w = self.measureText(" ");
        const fold_marker_w = self.measureText("[-]") + space_w;
        for (entry.payload_lines.items, 0..) |meta, line_index| {
            const line = entry.payload_json[meta.start..meta.end];
            const indent_width = @as(f32, @floatFromInt(meta.indent_spaces)) * space_w;
            const line_x_base = output_min_x + indent_width;
            const content_start = @min(meta.indent_spaces, line.len);
            const content = line[content_start..];
            const can_fold = meta.opens_block and meta.matching_close_index != null and
                @as(usize, @intCast(meta.matching_close_index.?)) > line_index + 1;
            const text_x = if (can_fold) line_x_base + fold_marker_w else line_x_base;
            const rows = self.measureJsonLineWrapRows(text_x, content_max_x, content);
            const clamped_rows: u32 = if (rows > std.math.maxInt(u32))
                std.math.maxInt(u32)
            else
                @intCast(rows);
            entry.payload_wrap_rows.appendAssumeCapacity(clamped_rows);
        }

        entry.payload_wrap_rows_wrap_width = wrap_width;
        entry.payload_wrap_rows_valid = true;
        entry.payload_visible_lines_valid = false;
        entry.cached_visible_rows_valid = false;
    }

    fn payloadLineRowsFromCache(entry: *const DebugEventEntry, line_index: usize) usize {
        if (line_index >= entry.payload_wrap_rows.items.len) return 1;
        const rows = @as(usize, @intCast(entry.payload_wrap_rows.items[line_index]));
        return if (rows == 0) 1 else rows;
    }

    fn ensureDebugVisiblePayloadLines(self: *App, output_min_x: f32, content_max_x: f32, entry: *DebugEventEntry) void {
        if (entry.payload_lines.items.len == 0) {
            entry.payload_visible_line_indices.clearRetainingCapacity();
            entry.payload_visible_line_row_starts.clearRetainingCapacity();
            entry.cached_visible_rows = 0;
            entry.cached_visible_rows_valid = true;
            entry.payload_visible_lines_valid = true;
            return;
        }

        self.ensureDebugPayloadWrapRows(output_min_x, content_max_x, entry);
        const wrap_width = @max(1.0, content_max_x - output_min_x);
        if (entry.payload_visible_lines_valid and
            @abs(entry.cached_visible_rows_wrap_width - wrap_width) < 0.5 and
            entry.cached_visible_rows_fold_revision == self.debug_fold_revision)
        {
            return;
        }

        entry.payload_visible_line_indices.clearRetainingCapacity();
        entry.payload_visible_line_row_starts.clearRetainingCapacity();
        entry.payload_visible_line_indices.ensureTotalCapacity(self.allocator, entry.payload_lines.items.len) catch return;
        entry.payload_visible_line_row_starts.ensureTotalCapacity(self.allocator, entry.payload_lines.items.len) catch return;

        var rows_u64: u64 = 0;
        var line_index: usize = 0;
        while (line_index < entry.payload_lines.items.len) {
            const meta = entry.payload_lines.items[line_index];
            const start_clamped: u32 = if (rows_u64 > std.math.maxInt(u32))
                std.math.maxInt(u32)
            else
                @intCast(rows_u64);
            entry.payload_visible_line_indices.appendAssumeCapacity(@intCast(line_index));
            entry.payload_visible_line_row_starts.appendAssumeCapacity(start_clamped);

            const rows_used = payloadLineRowsFromCache(entry, line_index);
            rows_u64 += rows_used;

            if (meta.opens_block and meta.matching_close_index != null and
                @as(usize, @intCast(meta.matching_close_index.?)) > line_index + 1 and
                self.isDebugBlockCollapsed(entry.id, line_index))
            {
                line_index = @as(usize, @intCast(meta.matching_close_index.?)) + 1;
            } else {
                line_index += 1;
            }
        }

        entry.cached_visible_rows = if (rows_u64 > std.math.maxInt(usize))
            std.math.maxInt(usize)
        else
            @intCast(rows_u64);
        entry.cached_visible_rows_wrap_width = wrap_width;
        entry.cached_visible_rows_fold_revision = self.debug_fold_revision;
        entry.cached_visible_rows_valid = true;
        entry.payload_visible_lines_valid = true;
    }

    fn countVisibleDebugPayloadRows(self: *App, output_min_x: f32, content_max_x: f32, entry: *DebugEventEntry) usize {
        if (entry.payload_lines.items.len == 0) return 0;
        self.ensureDebugVisiblePayloadLines(output_min_x, content_max_x, entry);
        return entry.cached_visible_rows;
    }

    fn findFirstVisiblePayloadLine(
        entry: *const DebugEventEntry,
        min_row: usize,
    ) usize {
        var lo: usize = 0;
        var hi: usize = entry.payload_visible_line_indices.items.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const line_index = @as(usize, @intCast(entry.payload_visible_line_indices.items[mid]));
            const start_row = @as(usize, @intCast(entry.payload_visible_line_row_starts.items[mid]));
            const rows_used = payloadLineRowsFromCache(entry, line_index);
            const end_row = start_row + rows_used;
            if (end_row <= min_row) {
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }
        return lo;
    }

    fn measureJsonLineWrapRows(self: *App, line_x: f32, max_x: f32, line: []const u8) usize {
        const line_height = self.textLineHeight();
        const available_w = @max(1.0, max_x - line_x);
        const h = self.measureTextWrappedHeight(available_w, line);

        var rows: usize = 1;
        var remaining = h - line_height;
        while (remaining > line_height * 0.05) : (rows += 1) {
            remaining -= line_height;
        }
        return rows;
    }

    fn debugCategoryColor(self: *App, category: []const u8) [4]f32 {
        if (std.mem.indexOf(u8, category, "error") != null) {
            return zcolors.rgba(196, 74, 74, 255);
        }
        if (std.mem.startsWith(u8, category, "control.")) {
            return zcolors.blend(self.theme.colors.primary, self.theme.colors.text_primary, 0.32);
        }
        if (std.mem.startsWith(u8, category, "session.")) {
            return zcolors.rgba(64, 134, 196, 255);
        }
        return self.theme.colors.text_primary;
    }

    fn drawDebugEventHeaderLine(self: *App, x: f32, y: f32, max_x: f32, entry: DebugEventEntry) void {
        var ts_buf: [64]u8 = undefined;
        const ts = std.fmt.bufPrint(&ts_buf, "{d}", .{entry.timestamp_ms}) catch "0";
        const line_height = self.textLineHeight();

        // Use a fixed timestamp column so category text never overlaps when
        // text measurement is slightly off relative to actual glyph widths.
        const ts_col_w = 116.0 * self.ui_scale;
        const ts_max_w = @max(0.0, @min(ts_col_w, max_x - x));
        self.drawTextTrimmed(x, y, ts_max_w, ts, self.theme.colors.text_secondary);

        const cursor_x = x + ts_col_w + 6.0 * self.ui_scale;
        if (cursor_x >= max_x) return;

        const category_max = @max(0.0, max_x - cursor_x);
        var category_w = self.measureText(entry.category);
        if (category_w > category_max) category_w = category_max;
        self.drawTextTrimmed(cursor_x, y, category_max, entry.category, self.debugCategoryColor(entry.category));

        if (entry.correlation_id) |value| {
            var badge_buf: [160]u8 = undefined;
            const text = std.fmt.bufPrint(&badge_buf, "CID:{s}", .{value}) catch "CID:(long)";
            const badge_x = cursor_x + category_w + 8.0 * self.ui_scale;
            const remaining = max_x - badge_x;
            if (remaining > 40.0 * self.ui_scale) {
                const badge_w = @min(remaining, self.measureText(text) + 10.0 * self.ui_scale);
                const badge_h = line_height;
                const badge_rect = Rect.fromXYWH(
                    badge_x,
                    y + 1.0 * self.ui_scale,
                    badge_w,
                    badge_h,
                );
                self.drawFilledRect(
                    badge_rect,
                    zcolors.withAlpha(self.theme.colors.primary, 0.22),
                );
                self.drawTextTrimmed(
                    badge_rect.min[0] + 4.0 * self.ui_scale,
                    y,
                    badge_w - 6.0 * self.ui_scale,
                    text,
                    self.theme.colors.text_primary,
                );
            }
        }
    }

    fn jsonTokenColor(self: *App, kind: JsonTokenKind) [4]f32 {
        return switch (kind) {
            .key => zcolors.blend(self.theme.colors.text_primary, self.theme.colors.primary, 0.5),
            .string => zcolors.rgba(48, 140, 92, 255),
            .number => zcolors.rgba(193, 126, 54, 255),
            .keyword => zcolors.rgba(137, 88, 186, 255),
            .punctuation => self.theme.colors.text_secondary,
            .plain => self.theme.colors.text_primary,
        };
    }

    fn wrappedLineBreak(self: *App, wrap_x: f32, cursor_x: *f32, cursor_y: *f32, rows: *usize) void {
        const line_height = self.textLineHeight();
        cursor_x.* = wrap_x;
        cursor_y.* += line_height;
        rows.* += 1;
    }

    fn measureGlyphWidth(self: *App, glyph: []const u8) f32 {
        if (glyph.len == 1) {
            const idx = glyph[0];
            if (idx < self.ascii_glyph_width_cache.len) {
                const cached = self.ascii_glyph_width_cache[idx];
                if (cached >= 0.0) return cached;
                const measured = self.measureText(glyph);
                self.ascii_glyph_width_cache[idx] = measured;
                return measured;
            }
        }
        return self.measureText(glyph);
    }

    fn maxFittingPrefix(self: *App, text: []const u8, max_w: f32) usize {
        if (text.len == 0 or max_w <= 0.0) return 0;
        var width: f32 = 0.0;
        var idx: usize = 0;
        var best_end: usize = 0;
        while (idx < text.len) {
            const next = nextUtf8Boundary(text, idx);
            if (next <= idx) break;
            const glyph_w = self.measureGlyphWidth(text[idx..next]);
            if (width + glyph_w > max_w) break;
            width += glyph_w;
            best_end = next;
            idx = next;
        }
        return best_end;
    }

    fn drawJsonTokenWrapped(
        self: *App,
        wrap_x: f32,
        cursor_x: *f32,
        cursor_y: *f32,
        max_x: f32,
        token: []const u8,
        color: [4]f32,
        rows: *usize,
    ) void {
        if (token.len == 0) return;

        var start: usize = 0;
        while (start < token.len) {
            const remaining_w = max_x - cursor_x.*;
            if (remaining_w <= 0.0) {
                if (cursor_x.* > wrap_x) {
                    self.wrappedLineBreak(wrap_x, cursor_x, cursor_y, rows);
                    continue;
                }
                const next = nextUtf8Boundary(token, start);
                const single = token[start..next];
                self.drawText(cursor_x.*, cursor_y.*, single, color);
                cursor_x.* += self.measureText(single);
                start = next;
                continue;
            }

            const rest = token[start..];
            const fit = self.maxFittingPrefix(rest, remaining_w);
            if (fit == 0) {
                if (cursor_x.* > wrap_x) {
                    self.wrappedLineBreak(wrap_x, cursor_x, cursor_y, rows);
                    continue;
                }
                const next = nextUtf8Boundary(rest, 0);
                const single = rest[0..next];
                self.drawText(cursor_x.*, cursor_y.*, single, color);
                cursor_x.* += self.measureText(single);
                start += next;
                continue;
            }

            const piece = rest[0..fit];
            self.drawText(cursor_x.*, cursor_y.*, piece, color);
            cursor_x.* += self.measureText(piece);
            start += fit;

            if (start < token.len) {
                self.wrappedLineBreak(wrap_x, cursor_x, cursor_y, rows);
            }
        }
    }

    fn isJsonDelimiter(ch: u8) bool {
        return ch == ' ' or ch == '\t' or ch == ',' or ch == ':' or ch == ']' or ch == '}' or ch == '[' or ch == '{';
    }

    fn drawJsonLineColored(self: *App, x: f32, y: f32, max_x: f32, line: []const u8) usize {
        var cursor_x = x;
        var cursor_y = y;
        var rows: usize = 1;
        var i: usize = 0;
        while (i < line.len) {
            const ch = line[i];

            if (ch == ' ' or ch == '\t') {
                var j = i + 1;
                while (j < line.len and (line[j] == ' ' or line[j] == '\t')) : (j += 1) {}
                const ws_width = self.measureText(line[i..j]);
                if (cursor_x + ws_width <= max_x) {
                    cursor_x += ws_width;
                } else if (cursor_x > x) {
                    self.wrappedLineBreak(x, &cursor_x, &cursor_y, &rows);
                }
                i = j;
                continue;
            }

            if (ch == '"') {
                var j = i + 1;
                var escaped = false;
                while (j < line.len) : (j += 1) {
                    const cur = line[j];
                    if (escaped) {
                        escaped = false;
                        continue;
                    }
                    if (cur == '\\') {
                        escaped = true;
                        continue;
                    }
                    if (cur == '"') {
                        j += 1;
                        break;
                    }
                }
                if (j > line.len) j = line.len;

                var kind: JsonTokenKind = .string;
                var k = j;
                while (k < line.len and (line[k] == ' ' or line[k] == '\t')) : (k += 1) {}
                if (k < line.len and line[k] == ':') {
                    kind = .key;
                }
                self.drawJsonTokenWrapped(x, &cursor_x, &cursor_y, max_x, line[i..j], self.jsonTokenColor(kind), &rows);
                i = j;
                continue;
            }

            if (ch == '{' or ch == '}' or ch == '[' or ch == ']' or ch == ':' or ch == ',') {
                self.drawJsonTokenWrapped(x, &cursor_x, &cursor_y, max_x, line[i .. i + 1], self.jsonTokenColor(.punctuation), &rows);
                i += 1;
                continue;
            }

            if ((ch >= '0' and ch <= '9') or ch == '-') {
                var j = i + 1;
                while (j < line.len) : (j += 1) {
                    const cur = line[j];
                    if (!((cur >= '0' and cur <= '9') or cur == '.' or cur == 'e' or cur == 'E' or cur == '+' or cur == '-')) {
                        break;
                    }
                }
                self.drawJsonTokenWrapped(x, &cursor_x, &cursor_y, max_x, line[i..j], self.jsonTokenColor(.number), &rows);
                i = j;
                continue;
            }

            if (std.mem.startsWith(u8, line[i..], "true")) {
                const end = i + 4;
                if (end == line.len or isJsonDelimiter(line[end])) {
                    self.drawJsonTokenWrapped(x, &cursor_x, &cursor_y, max_x, line[i..end], self.jsonTokenColor(.keyword), &rows);
                    i = end;
                    continue;
                }
            }
            if (std.mem.startsWith(u8, line[i..], "false")) {
                const end = i + 5;
                if (end == line.len or isJsonDelimiter(line[end])) {
                    self.drawJsonTokenWrapped(x, &cursor_x, &cursor_y, max_x, line[i..end], self.jsonTokenColor(.keyword), &rows);
                    i = end;
                    continue;
                }
            }
            if (std.mem.startsWith(u8, line[i..], "null")) {
                const end = i + 4;
                if (end == line.len or isJsonDelimiter(line[end])) {
                    self.drawJsonTokenWrapped(x, &cursor_x, &cursor_y, max_x, line[i..end], self.jsonTokenColor(.keyword), &rows);
                    i = end;
                    continue;
                }
            }

            var j = i + 1;
            while (j < line.len) : (j += 1) {
                const cur = line[j];
                if (cur == '"' or cur == ' ' or cur == '\t' or cur == '{' or cur == '}' or cur == '[' or cur == ']' or cur == ',' or cur == ':') {
                    break;
                }
            }
            self.drawJsonTokenWrapped(x, &cursor_x, &cursor_y, max_x, line[i..j], self.jsonTokenColor(.plain), &rows);
            i = j;
        }
        return rows;
    }

    fn clearSelectedNodeServiceEventCache(self: *App) void {
        if (self.debug_selected_node_service_cache_node_id) |value| {
            self.allocator.free(value);
            self.debug_selected_node_service_cache_node_id = null;
        }
        if (self.debug_selected_node_service_cache_diagnostics) |value| {
            self.allocator.free(value);
            self.debug_selected_node_service_cache_diagnostics = null;
        }
        self.debug_selected_node_service_cache_index = null;
        self.debug_selected_node_service_cache_event_id = 0;
    }

    fn selectedNodeServiceEventInfo(self: *App) SelectedNodeServiceEventInfo {
        const selected_idx = self.debug_selected_index orelse {
            self.clearSelectedNodeServiceEventCache();
            return .{};
        };
        if (selected_idx >= self.debug_events.items.len) {
            self.debug_selected_index = null;
            self.clearSelectedNodeServiceEventCache();
            return .{};
        }

        const entry = self.debug_events.items[selected_idx];
        if (!std.mem.eql(u8, entry.category, "control.node_service_event")) {
            self.clearSelectedNodeServiceEventCache();
            return .{};
        }

        if (self.debug_selected_node_service_cache_index == selected_idx and
            self.debug_selected_node_service_cache_event_id == entry.id)
        {
            return .{
                .index = selected_idx,
                .node_id = self.debug_selected_node_service_cache_node_id,
                .diagnostics = self.debug_selected_node_service_cache_diagnostics,
            };
        }

        self.clearSelectedNodeServiceEventCache();
        self.debug_selected_node_service_cache_index = selected_idx;
        self.debug_selected_node_service_cache_event_id = entry.id;

        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, entry.payload_json, .{}) catch null;
        if (parsed) |*parsed_value| {
            defer parsed_value.deinit();
            if (parsed_value.value == .object) {
                if (parsed_value.value.object.get("node_id")) |value| {
                    if (value == .string and value.string.len > 0) {
                        self.debug_selected_node_service_cache_node_id = self.allocator.dupe(u8, value.string) catch null;
                    }
                }
            }
        }
        self.debug_selected_node_service_cache_diagnostics =
            self.buildNodeServiceDeltaDiagnosticsTextFromJson(entry.payload_json) catch null;

        return .{
            .index = selected_idx,
            .node_id = self.debug_selected_node_service_cache_node_id,
            .diagnostics = self.debug_selected_node_service_cache_diagnostics,
        };
    }

    fn collectUniqueLinesOrdered(
        self: *App,
        text: []const u8,
        out: *std.ArrayListUnmanaged([]u8),
    ) !void {
        var iter = std.mem.splitScalar(u8, text, '\n');
        while (iter.next()) |raw_line| {
            const line = std.mem.trim(u8, raw_line, " \t\r");
            if (line.len == 0) continue;
            var exists = false;
            for (out.items) |existing| {
                if (std.mem.eql(u8, existing, line)) {
                    exists = true;
                    break;
                }
            }
            if (exists) continue;
            try out.append(self.allocator, try self.allocator.dupe(u8, line));
        }
    }

    fn freeOwnedLines(self: *App, lines: *std.ArrayListUnmanaged([]u8)) void {
        for (lines.items) |line| self.allocator.free(line);
        lines.deinit(self.allocator);
        lines.* = .{};
    }

    fn lineListContains(lines: []const []const u8, candidate: []const u8) bool {
        for (lines) |line| {
            if (std.mem.eql(u8, line, candidate)) return true;
        }
        return false;
    }

    fn buildNodeServiceEventDiffText(
        self: *App,
        base_idx: usize,
        compare_idx: usize,
    ) !?[]u8 {
        if (base_idx >= self.debug_events.items.len or compare_idx >= self.debug_events.items.len) return null;
        const base_entry = self.debug_events.items[base_idx];
        const compare_entry = self.debug_events.items[compare_idx];
        if (!std.mem.eql(u8, base_entry.category, "control.node_service_event")) return null;
        if (!std.mem.eql(u8, compare_entry.category, "control.node_service_event")) return null;

        const base_diag_opt = try self.buildNodeServiceDeltaDiagnosticsTextFromJson(base_entry.payload_json);
        defer if (base_diag_opt) |value| self.allocator.free(value);
        const compare_diag_opt = try self.buildNodeServiceDeltaDiagnosticsTextFromJson(compare_entry.payload_json);
        defer if (compare_diag_opt) |value| self.allocator.free(value);
        const base_diag = base_diag_opt orelse return null;
        const compare_diag = compare_diag_opt orelse return null;

        var base_lines: std.ArrayListUnmanaged([]u8) = .{};
        defer self.freeOwnedLines(&base_lines);
        var compare_lines: std.ArrayListUnmanaged([]u8) = .{};
        defer self.freeOwnedLines(&compare_lines);
        try self.collectUniqueLinesOrdered(base_diag, &base_lines);
        try self.collectUniqueLinesOrdered(compare_diag, &compare_lines);

        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(self.allocator);
        try out.writer(self.allocator).print(
            "node_service_event_diff\nbase_event_id={d} base_timestamp_ms={d}\ncompare_event_id={d} compare_timestamp_ms={d}",
            .{ base_entry.id, base_entry.timestamp_ms, compare_entry.id, compare_entry.timestamp_ms },
        );
        try out.appendSlice(self.allocator, "\n\n--- base_diagnostics ---\n");
        try out.appendSlice(self.allocator, base_diag);
        try out.appendSlice(self.allocator, "\n\n--- compare_diagnostics ---\n");
        try out.appendSlice(self.allocator, compare_diag);

        try out.appendSlice(self.allocator, "\n\n--- only_in_compare ---");
        var compare_delta_count: usize = 0;
        for (compare_lines.items) |line| {
            if (lineListContains(base_lines.items, line)) continue;
            compare_delta_count += 1;
            try out.writer(self.allocator).print("\n+ {s}", .{line});
        }
        if (compare_delta_count == 0) try out.appendSlice(self.allocator, "\n(none)");

        try out.appendSlice(self.allocator, "\n\n--- only_in_base ---");
        var base_delta_count: usize = 0;
        for (base_lines.items) |line| {
            if (lineListContains(compare_lines.items, line)) continue;
            base_delta_count += 1;
            try out.writer(self.allocator).print("\n- {s}", .{line});
        }
        if (base_delta_count == 0) try out.appendSlice(self.allocator, "\n(none)");

        try out.writer(self.allocator).print(
            "\n\nsummary: compare_only={d} base_only={d}",
            .{ compare_delta_count, base_delta_count },
        );

        return try out.toOwnedSlice(self.allocator);
    }

    fn exportNodeServiceDiffSnapshot(
        self: *App,
        diff_text: []const u8,
        base_event_id: u64,
        compare_event_id: u64,
    ) ![]u8 {
        const filename = try std.fmt.allocPrint(
            self.allocator,
            "node-service-diff-{d}-to-{d}-{d}.txt",
            .{ base_event_id, compare_event_id, std.time.milliTimestamp() },
        );
        defer self.allocator.free(filename);

        try std.fs.cwd().writeFile(.{
            .sub_path = filename,
            .data = diff_text,
        });

        const cwd = std.fs.cwd().realpathAlloc(self.allocator, ".") catch return self.allocator.dupe(u8, filename);
        defer self.allocator.free(cwd);
        return std.fmt.allocPrint(
            self.allocator,
            "{s}{s}{s}",
            .{ cwd, std.fs.path.sep_str, filename },
        );
    }

    fn hasPerfBenchmarkCapture(self: *const App) bool {
        if (self.perf_benchmark_active) return true;
        return self.perf_benchmark_last_start_timestamp_ms > 0 and
            self.perf_benchmark_last_end_timestamp_ms >= self.perf_benchmark_last_start_timestamp_ms;
    }

    fn clearPerfBenchmarkCapture(self: *App) void {
        self.perf_benchmark_last_start_sample_index = null;
        self.perf_benchmark_last_end_sample_index = 0;
        self.perf_benchmark_last_start_timestamp_ms = 0;
        self.perf_benchmark_last_end_timestamp_ms = 0;
        if (self.perf_benchmark_last_label) |value| {
            self.allocator.free(value);
            self.perf_benchmark_last_label = null;
        }
    }

    fn startPerfBenchmark(self: *App) !void {
        if (self.perf_benchmark_active) return;
        const now_ms = std.time.milliTimestamp();
        const trimmed = std.mem.trim(u8, self.perf_benchmark_label_input.items, " \t\r\n");
        const label = if (trimmed.len > 0)
            try self.allocator.dupe(u8, trimmed)
        else
            try std.fmt.allocPrint(self.allocator, "bench-{d}", .{now_ms});

        if (self.perf_benchmark_active_label) |value| self.allocator.free(value);
        self.perf_benchmark_active_label = label;
        self.perf_benchmark_active = true;
        self.perf_benchmark_start_sample_index = self.perf_history.items.len;
        self.perf_benchmark_start_timestamp_ms = now_ms;
    }

    fn stopPerfBenchmark(self: *App) !void {
        if (!self.perf_benchmark_active) return;
        const now_ms = std.time.milliTimestamp();

        self.clearPerfBenchmarkCapture();
        self.perf_benchmark_last_start_sample_index = self.perf_benchmark_start_sample_index;
        self.perf_benchmark_last_end_sample_index = self.perf_history.items.len;
        self.perf_benchmark_last_start_timestamp_ms = self.perf_benchmark_start_timestamp_ms;
        self.perf_benchmark_last_end_timestamp_ms = now_ms;
        if (self.perf_benchmark_active_label) |value| {
            self.perf_benchmark_last_label = value;
            self.perf_benchmark_active_label = null;
        }
        self.perf_benchmark_active = false;
        self.perf_benchmark_start_sample_index = 0;
        self.perf_benchmark_start_timestamp_ms = 0;
    }

    fn buildPerfReportTextForSlice(
        self: *App,
        report_name: []const u8,
        label: ?[]const u8,
        range_start_ms: ?i64,
        range_end_ms: ?i64,
        samples: []const PerfSample,
    ) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(self.allocator);

        const latest = if (samples.len > 0)
            samples[samples.len - 1]
        else
            PerfSample{
                .timestamp_ms = std.time.milliTimestamp(),
                .fps = self.perf_last_fps,
                .frame_ms = self.perf_last_frame_ms,
                .ws_poll_ms = self.perf_last_ws_ms,
                .fs_poll_ms = self.perf_last_fs_ms,
                .ws_wait_ms = self.perf_last_ws_wait_ms,
                .fs_request_ms = self.perf_last_fs_request_ms,
                .debug_ms = self.perf_last_debug_ms,
                .terminal_ms = self.perf_last_terminal_ms,
                .draw_ms = self.perf_last_draw_ms,
                .panel_chat_ms = self.perf_last_panel_chat_ms,
                .panel_settings_ms = self.perf_last_panel_settings_ms,
                .panel_debug_ms = self.perf_last_panel_debug_ms,
                .panel_projects_ms = self.perf_last_panel_projects_ms,
                .panel_filesystem_ms = self.perf_last_panel_filesystem_ms,
                .panel_terminal_ms = self.perf_last_panel_terminal_ms,
                .panel_other_ms = self.perf_last_panel_other_ms,
                .cmd_total_per_frame = self.perf_last_cmd_total_per_frame,
                .cmd_text_per_frame = self.perf_last_cmd_text_per_frame,
                .cmd_shape_per_frame = self.perf_last_cmd_shape_per_frame,
                .cmd_line_per_frame = self.perf_last_cmd_line_per_frame,
                .cmd_image_per_frame = self.perf_last_cmd_image_per_frame,
                .cmd_clip_per_frame = self.perf_last_cmd_clip_per_frame,
                .text_bytes_per_frame = self.perf_last_text_bytes_per_frame,
                .text_command_share_pct = self.perf_last_text_command_share_pct,
            };
        const latest_other_ms = @max(
            0.0,
            latest.frame_ms - (latest.draw_ms + latest.ws_poll_ms + latest.fs_poll_ms + latest.debug_ms + latest.terminal_ms),
        );

        try out.writer(self.allocator).print(
            "{s}\ncaptured_at_ms={d}\nsamples={d}\nlatest_fps={d:.2}\nlatest_frame_ms={d:.3}\nlatest_draw_ms={d:.3}\nlatest_other_ms={d:.3}\nlatest_ws_poll_ms={d:.3}\nlatest_fs_poll_ms={d:.3}\nlatest_ws_wait_ms={d:.3}\nlatest_fs_request_ms={d:.3}\nlatest_debug_ms={d:.3}\nlatest_terminal_ms={d:.3}\nlatest_panel_chat_ms={d:.3}\nlatest_panel_settings_ms={d:.3}\nlatest_panel_debug_ms={d:.3}\nlatest_panel_projects_ms={d:.3}\nlatest_panel_filesystem_ms={d:.3}\nlatest_panel_terminal_ms={d:.3}\nlatest_panel_other_ms={d:.3}\nlatest_cmd_total_per_frame={d:.3}\nlatest_cmd_text_per_frame={d:.3}\nlatest_cmd_shape_per_frame={d:.3}\nlatest_cmd_line_per_frame={d:.3}\nlatest_cmd_image_per_frame={d:.3}\nlatest_cmd_clip_per_frame={d:.3}\nlatest_text_bytes_per_frame={d:.3}\nlatest_text_command_share_pct={d:.3}\n",
            .{
                report_name,
                std.time.milliTimestamp(),
                samples.len,
                latest.fps,
                latest.frame_ms,
                latest.draw_ms,
                latest_other_ms,
                latest.ws_poll_ms,
                latest.fs_poll_ms,
                latest.ws_wait_ms,
                latest.fs_request_ms,
                latest.debug_ms,
                latest.terminal_ms,
                latest.panel_chat_ms,
                latest.panel_settings_ms,
                latest.panel_debug_ms,
                latest.panel_projects_ms,
                latest.panel_filesystem_ms,
                latest.panel_terminal_ms,
                latest.panel_other_ms,
                latest.cmd_total_per_frame,
                latest.cmd_text_per_frame,
                latest.cmd_shape_per_frame,
                latest.cmd_line_per_frame,
                latest.cmd_image_per_frame,
                latest.cmd_clip_per_frame,
                latest.text_bytes_per_frame,
                latest.text_command_share_pct,
            },
        );
        if (label) |value| {
            try out.writer(self.allocator).print("benchmark_label={s}\n", .{value});
        }
        if (range_start_ms != null and range_end_ms != null) {
            const start_ms = range_start_ms.?;
            const end_ms = range_end_ms.?;
            const duration_ms: i64 = @max(0, end_ms - start_ms);
            try out.writer(self.allocator).print(
                "range_start_ms={d}\nrange_end_ms={d}\nrange_duration_ms={d}\n",
                .{ start_ms, end_ms, duration_ms },
            );
        }

        try out.appendSlice(self.allocator, "\n# sample_table\ntimestamp_ms,fps,frame_ms,draw_ms,other_ms,ws_poll_ms,fs_poll_ms,ws_wait_ms,fs_request_ms,debug_ms,terminal_ms,panel_chat_ms,panel_settings_ms,panel_debug_ms,panel_projects_ms,panel_filesystem_ms,panel_terminal_ms,panel_other_ms,cmd_total_per_frame,cmd_text_per_frame,cmd_shape_per_frame,cmd_line_per_frame,cmd_image_per_frame,cmd_clip_per_frame,text_bytes_per_frame,text_command_share_pct\n");
        for (samples) |sample| {
            const other_ms = @max(
                0.0,
                sample.frame_ms - (sample.draw_ms + sample.ws_poll_ms + sample.fs_poll_ms + sample.debug_ms + sample.terminal_ms),
            );
            try out.writer(self.allocator).print(
                "{d},{d:.3},{d:.4},{d:.4},{d:.4},{d:.4},{d:.4},{d:.4},{d:.4},{d:.4},{d:.4},{d:.4},{d:.4},{d:.4},{d:.4},{d:.4},{d:.4},{d:.4},{d:.3},{d:.3},{d:.3},{d:.3},{d:.3},{d:.3},{d:.3},{d:.3}\n",
                .{
                    sample.timestamp_ms,
                    sample.fps,
                    sample.frame_ms,
                    sample.draw_ms,
                    other_ms,
                    sample.ws_poll_ms,
                    sample.fs_poll_ms,
                    sample.ws_wait_ms,
                    sample.fs_request_ms,
                    sample.debug_ms,
                    sample.terminal_ms,
                    sample.panel_chat_ms,
                    sample.panel_settings_ms,
                    sample.panel_debug_ms,
                    sample.panel_projects_ms,
                    sample.panel_filesystem_ms,
                    sample.panel_terminal_ms,
                    sample.panel_other_ms,
                    sample.cmd_total_per_frame,
                    sample.cmd_text_per_frame,
                    sample.cmd_shape_per_frame,
                    sample.cmd_line_per_frame,
                    sample.cmd_image_per_frame,
                    sample.cmd_clip_per_frame,
                    sample.text_bytes_per_frame,
                    sample.text_command_share_pct,
                },
            );
        }

        return out.toOwnedSlice(self.allocator);
    }

    fn buildPerfReportText(self: *App) ![]u8 {
        return self.buildPerfReportTextForSlice(
            "spider_gui_perf_report",
            null,
            null,
            null,
            self.perf_history.items,
        );
    }

    fn buildBenchmarkPerfReportText(self: *App) !?[]u8 {
        var label: ?[]const u8 = null;
        var start_ms: i64 = 0;
        var end_ms: i64 = 0;
        if (self.perf_benchmark_active) {
            label = self.perf_benchmark_active_label;
            start_ms = self.perf_benchmark_start_timestamp_ms;
            end_ms = std.time.milliTimestamp();
        } else if (self.perf_benchmark_last_start_timestamp_ms > 0 and
            self.perf_benchmark_last_end_timestamp_ms >= self.perf_benchmark_last_start_timestamp_ms)
        {
            label = self.perf_benchmark_last_label;
            start_ms = self.perf_benchmark_last_start_timestamp_ms;
            end_ms = self.perf_benchmark_last_end_timestamp_ms;
        } else {
            return null;
        }

        var start_idx: usize = 0;
        while (start_idx < self.perf_history.items.len and self.perf_history.items[start_idx].timestamp_ms < start_ms) : (start_idx += 1) {}
        var end_idx: usize = start_idx;
        while (end_idx < self.perf_history.items.len and self.perf_history.items[end_idx].timestamp_ms <= end_ms) : (end_idx += 1) {}

        return @as(?[]u8, try self.buildPerfReportTextForSlice(
            "spider_gui_perf_benchmark_report",
            label,
            start_ms,
            end_ms,
            self.perf_history.items[start_idx..end_idx],
        ));
    }

    fn exportPerfReport(self: *App, report_text: []const u8) ![]u8 {
        const filename = try std.fmt.allocPrint(
            self.allocator,
            "spider-gui-perf-{d}.txt",
            .{std.time.milliTimestamp()},
        );
        defer self.allocator.free(filename);

        try std.fs.cwd().writeFile(.{
            .sub_path = filename,
            .data = report_text,
        });

        const cwd = std.fs.cwd().realpathAlloc(self.allocator, ".") catch return self.allocator.dupe(u8, filename);
        defer self.allocator.free(cwd);
        return std.fmt.allocPrint(
            self.allocator,
            "{s}{s}{s}",
            .{ cwd, std.fs.path.sep_str, filename },
        );
    }

    fn buildNodeServiceDeltaDiagnosticsTextFromJson(self: *App, payload_json: []const u8) !?[]u8 {
        var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, payload_json, .{});
        defer parsed.deinit();
        return self.buildNodeServiceDeltaDiagnosticsTextFromValue(parsed.value);
    }

    fn buildNodeServiceDeltaDiagnosticsTextFromValue(self: *App, payload: std.json.Value) !?[]u8 {
        if (payload != .object) return null;
        const payload_obj = payload.object;
        const service_delta = payload_obj.get("service_delta") orelse return null;
        if (service_delta != .object) return null;
        const delta_obj = service_delta.object;

        const node_id = if (payload_obj.get("node_id")) |value| switch (value) {
            .string => value.string,
            else => "unknown",
        } else "unknown";
        const changed = if (delta_obj.get("changed")) |value| switch (value) {
            .bool => value.bool,
            else => false,
        } else false;
        const timestamp_ms: ?i64 = if (delta_obj.get("timestamp_ms")) |value| switch (value) {
            .integer => value.integer,
            else => null,
        } else null;

        const empty_values = &[_]std.json.Value{};
        const added_items: []const std.json.Value = if (delta_obj.get("added")) |value| switch (value) {
            .array => value.array.items,
            else => empty_values,
        } else empty_values;
        const updated_items: []const std.json.Value = if (delta_obj.get("updated")) |value| switch (value) {
            .array => value.array.items,
            else => empty_values,
        } else empty_values;
        const removed_items: []const std.json.Value = if (delta_obj.get("removed")) |value| switch (value) {
            .array => value.array.items,
            else => empty_values,
        } else empty_values;

        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(self.allocator);
        if (timestamp_ms) |value| {
            try out.writer(self.allocator).print(
                "node={s} changed={s} timestamp_ms={d}",
                .{ node_id, if (changed) "true" else "false", value },
            );
        } else {
            try out.writer(self.allocator).print(
                "node={s} changed={s}",
                .{ node_id, if (changed) "true" else "false" },
            );
        }
        try out.writer(self.allocator).print(
            "\nadded={d} updated={d} removed={d}",
            .{ added_items.len, updated_items.len, removed_items.len },
        );

        const max_entries: usize = 18;
        var shown_entries: usize = 0;
        try self.appendNodeServiceDeltaEntries(&out, "+", added_items, false, max_entries, &shown_entries);
        try self.appendNodeServiceDeltaEntries(&out, "~", updated_items, true, max_entries, &shown_entries);
        try self.appendNodeServiceDeltaEntries(&out, "-", removed_items, false, max_entries, &shown_entries);

        const total_entries = added_items.len + updated_items.len + removed_items.len;
        if (total_entries > shown_entries) {
            try out.writer(self.allocator).print("\n... {d} more service changes", .{total_entries - shown_entries});
        }
        try self.appendNodeServiceRuntimeDiagnostics(
            &out,
            payload_obj,
            added_items,
            updated_items,
        );
        const owned = try out.toOwnedSlice(self.allocator);
        return @as(?[]u8, owned);
    }

    fn appendNodeServiceDeltaEntries(
        self: *App,
        out: *std.ArrayList(u8),
        prefix: []const u8,
        entries: []const std.json.Value,
        include_previous: bool,
        max_entries: usize,
        shown_entries: *usize,
    ) !void {
        for (entries) |entry| {
            if (shown_entries.* >= max_entries) break;
            if (entry != .object) continue;
            const obj = entry.object;
            const service_id = if (obj.get("service_id")) |value| switch (value) {
                .string => value.string,
                else => "?",
            } else "?";
            const version = if (obj.get("version")) |value| switch (value) {
                .string => value.string,
                else => "?",
            } else "?";
            var hash_buf: [48]u8 = undefined;
            const hash = nodeServiceDeltaHashText(obj, "hash", "digest", &hash_buf);

            if (include_previous) {
                const previous_version = if (obj.get("previous_version")) |value| switch (value) {
                    .string => value.string,
                    else => "?",
                } else "?";
                var previous_hash_buf: [48]u8 = undefined;
                const previous_hash = nodeServiceDeltaHashText(obj, "previous_hash", "previous_digest", &previous_hash_buf);
                try out.writer(self.allocator).print(
                    "\n{s} {s}@{s} hash={s} prev={s}/{s}",
                    .{ prefix, service_id, version, hash, previous_version, previous_hash },
                );
            } else {
                try out.writer(self.allocator).print(
                    "\n{s} {s}@{s} hash={s}",
                    .{ prefix, service_id, version, hash },
                );
            }
            shown_entries.* += 1;
        }
    }

    fn nodeServiceDeltaHashText(
        obj: std.json.ObjectMap,
        primary_key: []const u8,
        fallback_key: []const u8,
        fallback_buffer: *[48]u8,
    ) []const u8 {
        if (obj.get(primary_key)) |value| {
            return switch (value) {
                .string => value.string,
                .integer => std.fmt.bufPrint(fallback_buffer, "{d}", .{value.integer}) catch "n/a",
                else => "n/a",
            };
        }
        if (obj.get(fallback_key)) |value| {
            return switch (value) {
                .string => value.string,
                .integer => std.fmt.bufPrint(fallback_buffer, "{d}", .{value.integer}) catch "n/a",
                else => "n/a",
            };
        }
        return "n/a";
    }

    fn appendNodeServiceRuntimeDiagnostics(
        self: *App,
        out: *std.ArrayList(u8),
        payload_obj: std.json.ObjectMap,
        added_items: []const std.json.Value,
        updated_items: []const std.json.Value,
    ) !void {
        const services_value = payload_obj.get("services") orelse return;
        if (services_value != .array) return;

        const max_runtime_lines: usize = 12;
        var runtime_lines: usize = 0;
        var appended_header = false;
        for (services_value.array.items) |service| {
            if (runtime_lines >= max_runtime_lines) break;
            if (service != .object) continue;
            const service_id = if (service.object.get("service_id")) |value| switch (value) {
                .string => value.string,
                else => continue,
            } else continue;
            if (!serviceIdPresentInDeltaItems(service_id, added_items, updated_items)) continue;
            if (!serviceHasRuntimeStatus(service.object)) continue;
            if (!appended_header) {
                try out.appendSlice(self.allocator, "\nruntime_status:");
                appended_header = true;
            }
            try out.writer(self.allocator).print("\n* {s}: ", .{service_id});
            try self.appendRuntimeStatusSummary(out, service.object);
            runtime_lines += 1;
        }
        if (runtime_lines == max_runtime_lines) {
            try out.appendSlice(self.allocator, "\n* ... more runtime status entries omitted");
        }
    }

    fn serviceIdPresentInDeltaItems(service_id: []const u8, items_a: []const std.json.Value, items_b: []const std.json.Value) bool {
        if (serviceIdPresentInDeltaArray(service_id, items_a)) return true;
        return serviceIdPresentInDeltaArray(service_id, items_b);
    }

    fn serviceIdPresentInDeltaArray(service_id: []const u8, items: []const std.json.Value) bool {
        for (items) |entry| {
            if (entry != .object) continue;
            const entry_service_id = if (entry.object.get("service_id")) |value| switch (value) {
                .string => value.string,
                else => continue,
            } else continue;
            if (std.mem.eql(u8, service_id, entry_service_id)) return true;
        }
        return false;
    }

    fn serviceHasRuntimeStatus(service_obj: std.json.ObjectMap) bool {
        const runtime_value = service_obj.get("runtime") orelse return false;
        if (runtime_value != .object) return false;
        const supervision_value = runtime_value.object.get("supervision_status") orelse return false;
        return supervision_value == .object;
    }

    fn appendRuntimeStatusSummary(
        self: *App,
        out: *std.ArrayList(u8),
        service_obj: std.json.ObjectMap,
    ) !void {
        const runtime_value = service_obj.get("runtime") orelse return;
        if (runtime_value != .object) return;
        const supervision_value = runtime_value.object.get("supervision_status") orelse return;
        if (supervision_value != .object) return;
        const status = supervision_value.object;

        const state = if (status.get("state")) |value| switch (value) {
            .string => value.string,
            else => "unknown",
        } else "unknown";
        const enabled = if (status.get("enabled")) |value| switch (value) {
            .bool => value.bool,
            else => false,
        } else false;
        const running = if (status.get("running")) |value| switch (value) {
            .bool => value.bool,
            else => false,
        } else false;
        const failures = if (status.get("consecutive_failures")) |value| switch (value) {
            .integer => value.integer,
            else => 0,
        } else 0;
        const transition_ms = if (status.get("last_transition_ms")) |value| switch (value) {
            .integer => value.integer,
            else => 0,
        } else 0;
        const healthy_ms = if (status.get("last_healthy_ms")) |value| switch (value) {
            .integer => value.integer,
            else => 0,
        } else 0;
        const last_error = if (status.get("last_error")) |value| switch (value) {
            .string => value.string,
            .null => null,
            else => null,
        } else null;

        try out.writer(self.allocator).print(
            "state={s} enabled={s} running={s} failures={d} transition_ms={d} healthy_ms={d} last_error={s}",
            .{
                state,
                if (enabled) "true" else "false",
                if (running) "true" else "false",
                failures,
                transition_ms,
                healthy_ms,
                if (last_error) |value| value else "none",
            },
        );
    }

    fn jumpFilesystemToNode(self: *App, manager: *panel_manager.PanelManager, node_id: []const u8) !void {
        const panel_id = try self.ensureFilesystemPanel(manager);
        manager.focusPanel(panel_id);

        const node_path = try std.fmt.allocPrint(
            self.allocator,
            "/nodes/{s}/fs",
            .{node_id},
        );
        defer self.allocator.free(node_path);
        self.filesystem_path.clearRetainingCapacity();
        try self.filesystem_path.appendSlice(self.allocator, node_path);
        try self.queueFilesystemPathLoad(node_path, true, false);
    }

    fn drawChatPanel(self: *App, rect: UiRect) void {
        if (self.render_input_queue == null) {
            self.drawText(
                rect.min[0] + 8.0,
                rect.min[1] + 8.0,
                "Chat panel unavailable: input system not ready",
                self.theme.colors.text_secondary,
            );
            return;
        }

        const pad = self.theme.spacing.sm;
        const session_key_for_panel: ?[]const u8 = if (self.current_session_key) |key| key else if (self.connection_state == .connected) "main" else null;
        const panel_rect = UiRect.fromMinSize(
            .{ rect.min[0] + pad, rect.min[1] + pad },
            .{
                @max(120.0, rect.max[0] - rect.min[0] - pad * 2.0),
                @max(120.0, rect.max[1] - rect.min[1] - pad * 2.0),
            },
        );

        ui_input_router.setExternalQueue(self.render_input_queue);

        const action = ChatWorkspacePanel.draw(
            ChatMessage,
            ChatSession,
            self.allocator,
            &self.chat_panel_state,
            "spider-gui",
            session_key_for_panel,
            self.activeMessages(),
            null,
            null,
            "🕷",
            "ZSS",
            self.chat_sessions.items,
            0,
            panel_rect,
        );

        self.handleChatPanelAction(action);
    }

    fn drawStatusOverlay(self: *App, fb_width: u32, fb_height: u32) void {
        const status_height: f32 = 24.0 * self.ui_scale;
        const fb_w: f32 = @floatFromInt(fb_width);
        const fb_h: f32 = @floatFromInt(fb_height);
        const status_rect = UiRect.fromMinSize(
            .{ 0, fb_h - status_height },
            .{ fb_w, status_height },
        );

        // Semi-transparent background
        const bg_color = zcolors.withAlpha(self.theme.colors.background, 0.9);
        self.ui_commands.pushRect(
            .{ .min = status_rect.min, .max = status_rect.max },
            .{ .fill = bg_color },
        );

        // Status indicator
        const indicator_size: f32 = 8.0 * self.ui_scale;
        const indicator_color = switch (self.connection_state) {
            .disconnected => zcolors.rgba(200, 80, 80, 255),
            .connecting => zcolors.rgba(220, 200, 60, 255),
            .connected => zcolors.rgba(90, 210, 90, 255),
            .error_state => zcolors.rgba(230, 120, 70, 255),
        };

        self.ui_commands.pushRect(
            .{
                .min = .{ status_rect.min[0] + 8, status_rect.min[1] + 8 },
                .max = .{ status_rect.min[0] + 8 + indicator_size, status_rect.min[1] + 8 + indicator_size },
            },
            .{ .fill = indicator_color },
        );

        // Status text
        self.drawText(
            status_rect.min[0] + 24,
            status_rect.min[1] + 4,
            self.status_text,
            self.theme.colors.text_secondary,
        );
    }

    fn drawStatusRow(self: *App, rect: Rect) void {
        self.drawSurfacePanel(rect);

        const inner = @max(self.theme.spacing.xs, 6.0 * self.ui_scale);
        const line_height = self.textLineHeight();
        const indicator_size = @max(10.0 * self.ui_scale, line_height * 0.58);
        const indicator_y = rect.min[1] + @max(0.0, (rect.height() - indicator_size) * 0.5);
        const indicator = Rect.fromXYWH(rect.min[0] + inner, indicator_y, indicator_size, indicator_size);
        const dot = switch (self.connection_state) {
            .disconnected => zcolors.rgba(200, 80, 80, 255),
            .connecting => zcolors.rgba(220, 200, 60, 255),
            .connected => zcolors.rgba(90, 210, 90, 255),
            .error_state => zcolors.rgba(230, 120, 70, 255),
        };
        self.drawFilledRect(indicator, dot);

        self.drawTextTrimmed(
            indicator.max[0] + inner,
            rect.min[1] + @max(0.0, (rect.height() - line_height) * 0.5),
            rect.width() - (indicator.max[0] - rect.min[0]) - inner * 2.0,
            self.status_text,
            self.theme.colors.text_primary,
        );
    }

    fn drawVerticalScrollbar(
        self: *App,
        target: FormScrollTarget,
        viewport_rect: Rect,
        content_height: f32,
        scroll_y: *f32,
    ) void {
        const viewport_height = viewport_rect.height();
        const max_scroll = if (content_height > viewport_height) content_height - viewport_height else 0.0;
        if (scroll_y.* < 0.0) scroll_y.* = 0.0;
        if (scroll_y.* > max_scroll) scroll_y.* = max_scroll;
        if (max_scroll <= 0.0) {
            if (self.form_scroll_drag_target == target) {
                self.form_scroll_drag_target = .none;
                if (!self.debug_scrollbar_dragging) self.setDragMouseCapture(false);
            }
            return;
        }

        const inset = @max(1.0, 2.0 * self.ui_scale);
        const track_w = @max(self.theme.spacing.xs, 8.0 * self.ui_scale);
        const track_rect = Rect.fromXYWH(
            viewport_rect.max[0] - track_w - inset,
            viewport_rect.min[1] + inset,
            track_w,
            @max(8.0, viewport_rect.height() - inset * 2.0),
        );

        const thumb_height = @max(20.0 * self.ui_scale, track_rect.height() * (viewport_height / content_height));
        const thumb_range = @max(1.0, track_rect.height() - thumb_height);
        const thumb_ratio = if (max_scroll > 0.0) scroll_y.* / max_scroll else 0.0;
        const thumb_y = track_rect.min[1] + thumb_ratio * thumb_range;
        const thumb_rect = Rect.fromXYWH(track_rect.min[0], thumb_y, track_w, thumb_height);

        if (self.form_scroll_drag_target == target) {
            if (self.mouse_down) {
                const scroll_per_px = max_scroll / thumb_range;
                const delta_y = self.mouse_y - self.form_scroll_drag_start_y;
                scroll_y.* = std.math.clamp(
                    self.form_scroll_drag_start_scroll_y + delta_y * scroll_per_px,
                    0.0,
                    max_scroll,
                );
            } else {
                self.form_scroll_drag_target = .none;
                if (!self.debug_scrollbar_dragging) self.setDragMouseCapture(false);
            }
        } else if (self.mouse_clicked and track_rect.contains(.{ self.mouse_x, self.mouse_y })) {
            const raw = (self.mouse_y - track_rect.min[1] - thumb_height * 0.5) / thumb_range;
            const click_ratio = std.math.clamp(raw, 0.0, 1.0);
            scroll_y.* = click_ratio * max_scroll;
            self.form_scroll_drag_target = target;
            self.form_scroll_drag_start_y = self.mouse_y;
            self.form_scroll_drag_start_scroll_y = scroll_y.*;
            self.setDragMouseCapture(true);
        }

        self.drawFilledRect(track_rect, zcolors.withAlpha(self.theme.colors.border, 0.25));
        const hovered = thumb_rect.contains(.{ self.mouse_x, self.mouse_y });
        const active = self.form_scroll_drag_target == target;
        const thumb_color = if (active)
            self.theme.colors.primary
        else if (hovered)
            zcolors.blend(self.theme.colors.border, self.theme.colors.primary, 0.46)
        else
            self.theme.colors.border;
        self.drawFilledRect(thumb_rect, thumb_color);
    }

    fn drawButtonWidget(self: *App, rect: Rect, label: []const u8, opts: widgets.button.Options) bool {
        const block_interaction = self.text_input_context_menu_open and !self.text_input_context_menu_rendering;
        const state = widgets.button.updateState(
            .{ .x = rect.min[0], .y = rect.min[1], .width = rect.width(), .height = rect.height() },
            .{ self.mouse_x, self.mouse_y },
            self.mouse_down,
            opts,
        );

        var fill: [4]f32 = switch (opts.variant) {
            .primary => self.theme.colors.primary,
            .secondary => self.theme.colors.surface,
            .ghost => zcolors.withAlpha(self.theme.colors.primary, 0.08),
        };

        if (opts.disabled) {
            fill = zcolors.blend(fill, self.theme.colors.background, 0.45);
        } else if (state.pressed) {
            fill = zcolors.blend(fill, zcolors.rgba(255, 255, 255, 255), 0.22);
        } else if (state.hovered) {
            fill = zcolors.blend(fill, self.theme.colors.primary, 0.12);
        }

        self.drawFilledRect(rect, fill);

        var border = self.theme.colors.border;
        if (state.hovered and !opts.disabled) {
            border = zcolors.blend(border, self.theme.colors.primary, 0.28);
        }
        self.drawRect(rect, border);

        var text_color = switch (opts.variant) {
            .primary => zcolors.rgba(255, 255, 255, 255),
            .secondary => self.theme.colors.text_primary,
            .ghost => self.theme.colors.primary,
        };
        if (opts.disabled) {
            text_color = zcolors.withAlpha(self.theme.colors.text_secondary, 0.7);
        }
        self.drawCenteredText(rect, label, text_color);

        return !block_interaction and !opts.disabled and self.mouse_released and rect.contains(.{ self.mouse_x, self.mouse_y });
    }

    fn drawTextInputWidget(
        self: *App,
        rect: Rect,
        text: []const u8,
        currently_focused: bool,
        opts: widgets.text_input.Options,
    ) bool {
        const state = widgets.text_input.updateState(
            .{ .x = rect.min[0], .y = rect.min[1], .width = rect.width(), .height = rect.height() },
            .{ self.mouse_x, self.mouse_y },
            self.mouse_released,
            currently_focused,
        );
        var focused = state.focused;
        const mouse_pos = .{ self.mouse_x, self.mouse_y };
        const suppress_interaction = self.text_input_context_menu_open and !self.text_input_context_menu_rendering;
        const left_clicked_inside = !suppress_interaction and self.mouse_clicked and rect.contains(mouse_pos) and !opts.disabled;
        const right_clicked_inside = !suppress_interaction and self.mouse_right_clicked and rect.contains(mouse_pos) and !opts.disabled;

        const fill = widgets.text_input.getFillPaint(self.theme, state, opts);
        const border = widgets.text_input.getBorderColor(self.theme, state, opts);

        self.drawPaintRect(rect, fill);
        self.drawRect(rect, border);

        const text_pad_x = @max(self.theme.spacing.sm, 8.0 * self.ui_scale);
        const text_x = rect.min[0] + text_pad_x;
        const max_w = rect.width() - text_pad_x * 2.0;
        const line_height = self.textLineHeight();
        const text_y = rect.min[1] + @max(0.0, (rect.height() - line_height) * 0.5);
        const visible_start = self.inputTailStartForWidth(text, max_w);

        if (focused) {
            if (!self.text_input_cursor_initialized) {
                self.text_input_cursor = text.len;
                self.clearFocusedTextSelection();
                self.text_input_cursor_initialized = true;
            }
            self.clampFocusedTextInputState(text);
        }

        if (left_clicked_inside) {
            focused = true;
            const clicked_cursor = self.textInputCursorFromMouse(text, visible_start, text_x, max_w, self.mouse_x);
            const now_ms = std.time.milliTimestamp();
            const elapsed_ms = now_ms - self.text_input_last_left_click_ms;
            const max_dist = 6.0 * self.ui_scale;
            const dx = self.mouse_x - self.text_input_last_left_click_pos[0];
            const dy = self.mouse_y - self.text_input_last_left_click_pos[1];
            const double_click = self.text_input_last_left_click_ms > 0 and
                elapsed_ms >= 0 and
                elapsed_ms <= TEXT_INPUT_DOUBLE_CLICK_MS and
                dx * dx + dy * dy <= max_dist * max_dist;
            self.text_input_last_left_click_ms = now_ms;
            self.text_input_last_left_click_pos = .{ self.mouse_x, self.mouse_y };

            if (double_click and text.len > 0) {
                self.text_input_selection_anchor = 0;
                self.text_input_cursor = text.len;
                self.text_input_drag_anchor = self.text_input_cursor;
                self.text_input_dragging = false;
            } else {
                self.text_input_cursor = clicked_cursor;
                self.text_input_drag_anchor = self.text_input_cursor;
                self.text_input_dragging = true;
                self.clearFocusedTextSelection();
            }
            self.text_input_cursor_initialized = true;
        }

        if (right_clicked_inside) {
            focused = true;
            const clicked_cursor = self.textInputCursorFromMouse(text, visible_start, text_x, max_w, self.mouse_x);
            const preserve_selection = blk: {
                const sel = self.focusedTextSelectionRange(text) orelse break :blk false;
                break :blk clicked_cursor >= sel[0] and clicked_cursor <= sel[1];
            };
            if (!preserve_selection) {
                self.text_input_cursor = clicked_cursor;
                self.clearFocusedTextSelection();
            }
            self.text_input_drag_anchor = self.text_input_cursor;
            self.text_input_dragging = false;
            self.text_input_cursor_initialized = true;
            self.text_input_context_menu_open = true;
            self.text_input_context_menu_anchor = .{
                self.mouse_x + 10.0 * self.ui_scale,
                self.mouse_y + 8.0 * self.ui_scale,
            };
            self.text_input_context_menu_rect = null;
        }

        if (focused and self.text_input_dragging and self.mouse_down and !opts.disabled) {
            const drag_cursor = self.textInputCursorFromMouse(text, visible_start, text_x, max_w, self.mouse_x);
            if (drag_cursor != self.text_input_drag_anchor) {
                if (self.text_input_selection_anchor == null) {
                    self.text_input_selection_anchor = self.text_input_drag_anchor;
                }
                self.text_input_cursor = drag_cursor;
            }
        }

        if (!self.mouse_down or self.mouse_released) {
            self.text_input_dragging = false;
        }

        if (text.len == 0) {
            const placeholder = if (opts.placeholder.len > 0) opts.placeholder else "";
            if (placeholder.len > 0) {
                self.drawTextTrimmed(text_x, text_y, max_w, placeholder, widgets.text_input.getPlaceholderColor(self.theme));
            }
        } else {
            if (focused) {
                if (self.focusedTextSelectionRange(text)) |sel| {
                    const start = @max(sel[0], visible_start);
                    const finish = @min(sel[1], text.len);
                    if (finish > start) {
                        const sel_left = self.measureTextFast(text[visible_start..start]);
                        const sel_right = self.measureTextFast(text[visible_start..finish]);
                        const sel_rect = Rect.fromXYWH(
                            text_x + sel_left,
                            text_y,
                            @max(0.0, sel_right - sel_left),
                            line_height,
                        );
                        self.drawFilledRect(sel_rect, widgets.text_input.getSelectionColor(self.theme));
                    }
                }
            }
            var text_color = self.theme.colors.text_primary;
            if (opts.disabled) text_color = zcolors.withAlpha(text_color, 0.45);
            self.drawText(text_x, text_y, text[visible_start..], text_color);
        }

        if (focused and !opts.disabled and !opts.read_only) {
            // Draw caret using same measurement as text
            const caret_width: f32 = 2.0 * self.ui_scale;
            const caret_height = line_height;

            const caret_index = @max(visible_start, @min(self.text_input_cursor, text.len));
            const caret_offset = self.measureTextFast(text[visible_start..caret_index]);
            const caret_x = text_x + @min(caret_offset, max_w - caret_width);

            const caret_rect = UiRect.fromMinSize(
                .{ caret_x, text_y },
                .{ caret_width, caret_height },
            );
            self.ui_commands.pushRect(
                .{ .min = caret_rect.min, .max = caret_rect.max },
                .{ .fill = self.theme.colors.primary },
            );
        }

        return focused;
    }

    fn drawTextInputContextMenuOverlay(self: *App, fb_width: u32, fb_height: u32) void {
        if (!self.text_input_context_menu_open) return;
        self.text_input_context_menu_rendering = true;
        defer self.text_input_context_menu_rendering = false;
        const buf = self.focusedSettingsBuffer() orelse {
            self.text_input_context_menu_open = false;
            self.text_input_context_menu_rect = null;
            return;
        };

        const line_height = self.textLineHeight();
        const item_h = @max(22.0 * self.ui_scale, line_height + self.theme.spacing.xs * 1.1);
        const menu_rect = self.text_input_context_menu_rect orelse self.resolvedTextInputContextMenuRect(fb_width, fb_height);
        self.text_input_context_menu_rect = menu_rect;
        const mouse_pos = .{ self.mouse_x, self.mouse_y };
        if (self.mouse_released and !menu_rect.contains(mouse_pos)) {
            self.text_input_context_menu_open = false;
            self.text_input_context_menu_rect = null;
            return;
        }

        self.drawSurfacePanel(menu_rect);
        self.drawRect(menu_rect, self.theme.colors.border);

        var y = menu_rect.min[1] + self.theme.spacing.xs;
        const row_x = menu_rect.min[0] + self.theme.spacing.xs;
        const row_w = menu_rect.width() - self.theme.spacing.xs * 2.0;
        const has_selection = self.focusedTextSelectionRange(buf.items) != null;
        const clip = zapp.clipboard.getTextZ();

        if (self.drawButtonWidget(
            Rect.fromXYWH(row_x, y, row_w, item_h),
            "Copy",
            .{ .variant = .ghost, .disabled = !has_selection },
        )) {
            _ = self.copyFocusedTextSelectionToClipboard(buf.items);
            self.text_input_context_menu_open = false;
            self.text_input_context_menu_rect = null;
            return;
        }
        y += item_h;

        if (self.drawButtonWidget(
            Rect.fromXYWH(row_x, y, row_w, item_h),
            "Cut",
            .{ .variant = .ghost, .disabled = !has_selection },
        )) {
            if (self.copyFocusedTextSelectionToClipboard(buf.items)) {
                self.recordFocusedTextUndoState(buf) catch {};
                _ = self.deleteFocusedTextSelection(buf);
            }
            self.text_input_context_menu_open = false;
            self.text_input_context_menu_rect = null;
            return;
        }
        y += item_h;

        if (self.drawButtonWidget(
            Rect.fromXYWH(row_x, y, row_w, item_h),
            "Paste",
            .{ .variant = .ghost, .disabled = clip.len == 0 },
        )) {
            if (clip.len > 0 and (self.focusedTextSelectionRange(buf.items) != null or hasSingleLineInsertableBytes(clip))) {
                self.recordFocusedTextUndoState(buf) catch {};
                _ = self.insertSingleLineTextAtCursor(buf, clip) catch false;
            }
            self.text_input_context_menu_open = false;
            self.text_input_context_menu_rect = null;
            return;
        }
        y += item_h;

        if (self.drawButtonWidget(
            Rect.fromXYWH(row_x, y, row_w, item_h),
            "Select All",
            .{ .variant = .ghost, .disabled = buf.items.len == 0 },
        )) {
            if (buf.items.len > 0) {
                self.text_input_selection_anchor = 0;
                self.text_input_cursor = buf.items.len;
            }
            self.text_input_context_menu_open = false;
            self.text_input_context_menu_rect = null;
        }
    }

    fn textInputCursorFromMouse(
        self: *App,
        text: []const u8,
        visible_start: usize,
        text_x: f32,
        max_w: f32,
        mouse_x: f32,
    ) usize {
        if (text.len == 0) return 0;
        const local_x = std.math.clamp(mouse_x - text_x, 0.0, max_w);
        var idx = visible_start;
        var width: f32 = 0.0;
        while (idx < text.len) {
            const next = nextUtf8Boundary(text, idx);
            if (next <= idx) break;
            const glyph_w = self.measureGlyphWidth(text[idx..next]);
            if (width + glyph_w * 0.5 >= local_x) break;
            width += glyph_w;
            idx = next;
        }
        return idx;
    }

    fn selectedProjectToken(self: *App, project_id: []const u8) ?[]const u8 {
        if (project_id.len == 0) return null;
        if (isSystemProjectId(project_id)) return null;
        if (self.settings_panel.project_token.items.len > 0) return self.settings_panel.project_token.items;
        return self.config.getProjectToken(project_id);
    }

    fn selectedAgentId(self: *App) ?[]const u8 {
        if (self.settings_panel.default_agent.items.len > 0) {
            if (isValidAgentIdForAttach(self.settings_panel.default_agent.items)) return self.settings_panel.default_agent.items;
            return null;
        }
        const configured = self.config.selectedAgent() orelse return null;
        if (!isValidAgentIdForAttach(configured)) return null;
        return configured;
    }

    fn sessionHistoryAgentFilter(self: *App) ?[]const u8 {
        const selected = self.selectedAgentId() orelse return null;
        if (selected.len == 0) return null;
        return selected;
    }

    fn formatSessionHistoryDisplayName(
        self: *App,
        session: *const workspace_types.SessionSummary,
    ) ![]u8 {
        if (session.summary) |summary| {
            return std.fmt.allocPrint(
                self.allocator,
                "{s} ({s}@{s}) - {s}",
                .{
                    session.session_key,
                    session.agent_id,
                    session.project_id orelse "(none)",
                    summary,
                },
            );
        }
        return std.fmt.allocPrint(
            self.allocator,
            "{s} ({s}@{s})",
            .{
                session.session_key,
                session.agent_id,
                session.project_id orelse "(none)",
            },
        );
    }

    fn sessionExists(self: *const App, session_key: []const u8) bool {
        for (self.chat_sessions.items) |session| {
            if (std.mem.eql(u8, session.key, session_key)) return true;
        }
        return false;
    }

    fn projectTokenForSessionProject(self: *App, project_id: ?[]const u8) ?[]const u8 {
        const pid = project_id orelse return null;
        if (isSystemProjectId(pid)) return null;
        if (self.settings_panel.project_id.items.len > 0 and
            std.mem.eql(u8, self.settings_panel.project_id.items, pid) and
            self.settings_panel.project_token.items.len > 0)
        {
            return self.settings_panel.project_token.items;
        }
        return self.config.getProjectToken(pid);
    }

    fn attachSessionBindingExplicit(
        self: *App,
        client: *ws_client_mod.WebSocketClient,
        session_key: []const u8,
        agent_id: []const u8,
        project_id: ?[]const u8,
        project_token: ?[]const u8,
    ) !void {
        const payload_json = try self.buildSessionAttachPayload(
            session_key,
            agent_id,
            project_id,
            project_token,
        );
        defer self.allocator.free(payload_json);
        const response_payload = try control_plane.requestControlPayloadJsonWithTimeout(
            self.allocator,
            client,
            &self.message_counter,
            "control.session_attach",
            payload_json,
            CONTROL_SESSION_ATTACH_TIMEOUT_MS,
        );
        defer self.allocator.free(response_payload);
        self.invalidateFsrpcAttachment();
        if (self.debug_stream_enabled) self.requestDebugStreamSnapshot(true);
        if (self.node_service_watch_enabled) self.requestNodeServiceSnapshot(true);
    }

    fn loadSessionHistoryFromServer(self: *App, show_feedback: bool) !void {
        const client = if (self.ws_client) |*value| value else return error.NotConnected;
        try control_plane.ensureUnifiedV2Connection(self.allocator, client, &self.message_counter);

        var history = try control_plane.sessionHistory(
            self.allocator,
            client,
            &self.message_counter,
            self.sessionHistoryAgentFilter(),
            24,
        );
        defer {
            for (history.items) |*entry| entry.deinit(self.allocator);
            history.deinit(self.allocator);
        }

        var added_count: usize = 0;
        for (history.items) |*entry| {
            const existed = self.sessionExists(entry.session_key);
            const display_name = try self.formatSessionHistoryDisplayName(entry);
            defer self.allocator.free(display_name);
            try self.ensureSessionInList(entry.session_key, display_name);
            if (!existed) added_count += 1;
        }

        if (self.current_session_key == null and history.items.len > 0) {
            try self.setCurrentSessionKey(history.items[0].session_key);
        }

        if (!show_feedback) return;
        if (history.items.len == 0) {
            try self.appendMessage("system", "No persisted sessions found.", null);
            return;
        }
        const message = try std.fmt.allocPrint(
            self.allocator,
            "Loaded {d} persisted session(s) ({d} new).",
            .{ history.items.len, added_count },
        );
        defer self.allocator.free(message);
        try self.appendMessage("system", message, null);
    }

    fn restoreLastSessionFromServer(self: *App) !void {
        const client = if (self.ws_client) |*value| value else return error.NotConnected;
        try control_plane.ensureUnifiedV2Connection(self.allocator, client, &self.message_counter);

        var restored = try control_plane.sessionRestore(
            self.allocator,
            client,
            &self.message_counter,
            self.sessionHistoryAgentFilter(),
        );
        defer restored.deinit(self.allocator);

        if (!restored.found or restored.session == null) {
            try self.appendMessage("system", "No persisted session available to restore.", null);
            return;
        }

        const session = restored.session.?;
        const display_name = try self.formatSessionHistoryDisplayName(&session);
        defer self.allocator.free(display_name);
        try self.ensureSessionInList(session.session_key, display_name);
        try self.setCurrentSessionKey(session.session_key);

        self.settings_panel.default_session.clearRetainingCapacity();
        try self.settings_panel.default_session.appendSlice(self.allocator, session.session_key);
        try self.setDefaultAgentInSettings(session.agent_id);

        var effective_project_id: ?[]const u8 = session.project_id;
        if (effective_project_id == null) {
            effective_project_id = self.preferredAttachProjectId();
        }
        const effective_project_token = self.projectTokenForSessionProject(effective_project_id);
        self.attachSessionBindingExplicit(
            client,
            session.session_key,
            session.agent_id,
            effective_project_id,
            effective_project_token,
        ) catch |err| return err;

        if (effective_project_id) |project_id| {
            try self.ensureSelectedProjectInSettings(project_id);
            self.settings_panel.project_token.clearRetainingCapacity();
            if (effective_project_token) |token| {
                try self.settings_panel.project_token.appendSlice(self.allocator, token);
            }
        }

        self.refreshSessionAttachStatusOnce(client, session.session_key);
        try self.syncSettingsToConfig();
        self.startFilesystemWorker(
            client.url_buf,
            client.token_buf,
            session.session_key,
            session.agent_id,
            effective_project_id,
            effective_project_token,
        ) catch |worker_err| {
            std.log.warn("Failed to rebind filesystem transport for restored session: {s}", .{@errorName(worker_err)});
        };
        self.requestDebugStreamSnapshot(true);
        self.node_service_watch_enabled = true;
        self.requestNodeServiceSnapshot(true);

        try self.loadSessionHistoryFromServer(false);
        self.clearWorkspaceError();
        const ok = try std.fmt.allocPrint(
            self.allocator,
            "Restored session {s}.",
            .{session.session_key},
        );
        defer self.allocator.free(ok);
        try self.appendMessage("system", ok, null);
    }

    fn parseAgentFromSessionListPayload(
        self: *App,
        payload_json: []const u8,
        preferred_session_key: []const u8,
    ) ![]u8 {
        var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, payload_json, .{});
        defer parsed.deinit();
        if (parsed.value != .object) return error.InvalidResponse;

        const root = parsed.value.object;
        const active_session_key = if (root.get("active_session")) |value| switch (value) {
            .string => value.string,
            else => null,
        } else null;
        const sessions = root.get("sessions") orelse return error.InvalidResponse;
        if (sessions != .array) return error.InvalidResponse;

        var preferred_agent: ?[]const u8 = null;
        var active_agent: ?[]const u8 = null;
        var fallback_agent: ?[]const u8 = null;
        for (sessions.array.items) |entry| {
            if (entry != .object) continue;
            const session_key = if (entry.object.get("session_key")) |value| switch (value) {
                .string => value.string,
                else => null,
            } else null;
            const agent_id = if (entry.object.get("agent_id")) |value| switch (value) {
                .string => value.string,
                else => null,
            } else null;
            if (session_key == null or agent_id == null) continue;
            if (fallback_agent == null) fallback_agent = agent_id;
            if (active_session_key != null and std.mem.eql(u8, active_session_key.?, session_key.?)) {
                active_agent = agent_id;
            }
            if (std.mem.eql(u8, preferred_session_key, session_key.?)) {
                preferred_agent = agent_id;
            }
        }

        const selected = preferred_agent orelse active_agent orelse fallback_agent orelse return error.InvalidResponse;
        return self.allocator.dupe(u8, selected);
    }

    fn fetchDefaultAgentFromServer(
        self: *App,
        client: *ws_client_mod.WebSocketClient,
        preferred_session_key: []const u8,
    ) ![]u8 {
        const payload_json = try control_plane.requestControlPayloadJson(
            self.allocator,
            client,
            &self.message_counter,
            "control.session_list",
            null,
        );
        defer self.allocator.free(payload_json);
        return self.parseAgentFromSessionListPayload(payload_json, preferred_session_key);
    }

    fn fetchFirstNonSystemAgentFromServer(
        self: *App,
        client: *ws_client_mod.WebSocketClient,
    ) ![]u8 {
        var agents = try control_plane.listAgents(
            self.allocator,
            client,
            &self.message_counter,
        );
        defer workspace_types.deinitAgentList(self.allocator, &agents);

        var fallback_non_system: ?[]const u8 = null;
        for (agents.items) |agent| {
            if (isSystemAgentId(agent.id)) continue;
            if (agent.is_default) return self.allocator.dupe(u8, agent.id);
            if (fallback_non_system == null) fallback_non_system = agent.id;
        }

        if (fallback_non_system) |agent_id| return self.allocator.dupe(u8, agent_id);
        return error.NoProjectCompatibleAgent;
    }

    fn resolveAttachAgentForProject(
        self: *App,
        client: *ws_client_mod.WebSocketClient,
        session_key: []const u8,
        project_id: ?[]const u8,
    ) ![]u8 {
        var resolved_agent = if (self.selectedAgentId()) |value| blk: {
            // Prevent stale persisted user-scoped agent ids from being reused on admin connects.
            if (self.config.active_role == .admin and isUserScopedAgentId(value)) {
                break :blk try self.fetchDefaultAgentFromServer(client, session_key);
            }
            break :blk try self.allocator.dupe(u8, value);
        } else try self.fetchDefaultAgentFromServer(client, session_key);
        errdefer self.allocator.free(resolved_agent);

        if (isSystemProjectId(project_id)) {
            if (!isSystemAgentId(resolved_agent)) {
                self.allocator.free(resolved_agent);
                resolved_agent = try self.allocator.dupe(u8, system_agent_id);
            }
            return resolved_agent;
        }

        if (project_id != null and isSystemAgentId(resolved_agent)) {
            self.allocator.free(resolved_agent);
            resolved_agent = try self.fetchFirstNonSystemAgentFromServer(client);
        }

        return resolved_agent;
    }

    fn buildSessionAttachPayload(
        self: *App,
        session_key: []const u8,
        agent_id: []const u8,
        project_id: ?[]const u8,
        project_token: ?[]const u8,
    ) ![]u8 {
        const project = project_id orelse return error.ProjectIdRequired;
        const trimmed_project = std.mem.trim(u8, project, " \t\r\n");
        if (trimmed_project.len == 0) return error.ProjectIdRequired;
        if (!isValidSessionKeyForAttach(session_key)) return error.InvalidSessionKey;
        if (!isValidAgentIdForAttach(agent_id)) return error.InvalidAgentId;
        if (!isValidProjectIdForAttach(trimmed_project)) return error.InvalidProjectId;
        const normalized_project_token = normalizeProjectToken(project_token);

        const escaped_session = try jsonEscape(self.allocator, session_key);
        defer self.allocator.free(escaped_session);
        const escaped_agent = try jsonEscape(self.allocator, agent_id);
        defer self.allocator.free(escaped_agent);
        const escaped_project = try jsonEscape(self.allocator, trimmed_project);
        defer self.allocator.free(escaped_project);

        var out = std.ArrayListUnmanaged(u8){};
        defer out.deinit(self.allocator);
        try out.writer(self.allocator).print(
            "{{\"session_key\":\"{s}\",\"agent_id\":\"{s}\",\"project_id\":\"{s}\"",
            .{ escaped_session, escaped_agent, escaped_project },
        );
        if (normalized_project_token) |token| {
            const escaped_token = try jsonEscape(self.allocator, token);
            defer self.allocator.free(escaped_token);
            try out.writer(self.allocator).print(",\"project_token\":\"{s}\"", .{escaped_token});
        }
        try out.append(self.allocator, '}');
        return out.toOwnedSlice(self.allocator);
    }

    fn setDefaultAgentInSettings(self: *App, agent_id: []const u8) !void {
        self.settings_panel.default_agent.clearRetainingCapacity();
        if (agent_id.len > 0) {
            try self.settings_panel.default_agent.appendSlice(self.allocator, agent_id);
        }
    }

    fn refreshSessionAttachStatusOnce(
        self: *App,
        client: *ws_client_mod.WebSocketClient,
        session_key: []const u8,
    ) void {
        var status = control_plane.sessionStatusWithTimeout(
            self.allocator,
            client,
            &self.message_counter,
            session_key,
            CONTROL_SESSION_STATUS_TIMEOUT_MS,
        ) catch {
            // Do not keep stale warming/error gate when status refresh fails.
            self.session_attach_state = .unknown;
            if (self.connection_state == .connected) {
                self.setConnectionState(.connected, "Connected");
            }
            return;
        };
        defer status.deinit(self.allocator);

        if (std.mem.eql(u8, status.state, "ready")) {
            self.session_attach_state = .ready;
            if (self.connection_state == .connected) {
                self.setConnectionState(.connected, "Connected");
            }
            return;
        }
        if (std.mem.eql(u8, status.state, "warming")) {
            // "warming" is a legacy backend state; do not gate chat/filesystem on it.
            self.session_attach_state = .unknown;
            if (self.connection_state == .connected) {
                self.setConnectionState(.connected, "Connected");
            }
            self.clearWorkspaceError();
            return;
        }
        if (std.mem.eql(u8, status.state, "error")) {
            self.session_attach_state = .err;
            const code = status.error_code orelse "runtime_unavailable";
            const message = status.error_message orelse "runtime unavailable";
            const formatted = std.fmt.allocPrint(
                self.allocator,
                "Sandbox attach error: {s} [{s}]",
                .{ message, code },
            ) catch return;
            defer self.allocator.free(formatted);
            self.setWorkspaceError(formatted);
            self.setConnectionState(.connected, "Connected (sandbox error)");
            return;
        }
        self.session_attach_state = .unknown;
    }

    fn attachSessionBindingWithProject(
        self: *App,
        client: *ws_client_mod.WebSocketClient,
        session_key: []const u8,
        project_id: ?[]const u8,
        project_token: ?[]const u8,
    ) !void {
        std.log.info(
            "[GUI] attachSessionBindingWithProject: session={s} project={s} token={} state={s}",
            .{
                session_key,
                project_id orelse "(none)",
                normalizeProjectToken(project_token) != null,
                @tagName(self.session_attach_state),
            },
        );
        const resolved_agent = try self.resolveAttachAgentForProject(
            client,
            session_key,
            project_id,
        );
        defer self.allocator.free(resolved_agent);
        std.log.info(
            "[GUI] attachSessionBindingWithProject: resolved_agent={s} project={s}",
            .{ resolved_agent, project_id orelse "(none)" },
        );

        const payload_json = try self.buildSessionAttachPayload(
            session_key,
            resolved_agent,
            project_id,
            project_token,
        );
        defer self.allocator.free(payload_json);

        const response_payload = control_plane.requestControlPayloadJsonWithTimeout(
            self.allocator,
            client,
            &self.message_counter,
            "control.session_attach",
            payload_json,
            CONTROL_SESSION_ATTACH_TIMEOUT_MS,
        ) catch |err| blk: {
            const has_project_token = normalizeProjectToken(project_token) != null;
            if (err == error.RemoteError and
                isSystemProjectId(project_id) and
                has_project_token)
            {
                const remote = control_plane.lastRemoteError() orelse "";
                const token_rejected = std.mem.indexOf(u8, remote, "project_token") != null;
                const invalid_payload = std.mem.indexOf(u8, remote, "invalid_payload") != null;
                if (token_rejected or invalid_payload) {
                    std.log.warn(
                        "Session attach for system project failed with token ({s}); retrying without project_token",
                        .{remote},
                    );
                    const retry_payload_json = try self.buildSessionAttachPayload(
                        session_key,
                        resolved_agent,
                        project_id,
                        null,
                    );
                    defer self.allocator.free(retry_payload_json);
                    break :blk try control_plane.requestControlPayloadJsonWithTimeout(
                        self.allocator,
                        client,
                        &self.message_counter,
                        "control.session_attach",
                        retry_payload_json,
                        CONTROL_SESSION_ATTACH_TIMEOUT_MS,
                    );
                }
            }
            std.log.err(
                "[GUI] attachSessionBindingWithProject failed: session={s} project={s} agent={s} err={s} detail={s}",
                .{
                    session_key,
                    project_id orelse "(none)",
                    resolved_agent,
                    @errorName(err),
                    if (err == error.RemoteError) (control_plane.lastRemoteError() orelse "(none)") else "(none)",
                },
            );
            return err;
        };
        defer self.allocator.free(response_payload);

        std.log.info(
            "[GUI] attachSessionBindingWithProject ok: session={s} project={s} agent={s}",
            .{ session_key, project_id orelse "(none)", resolved_agent },
        );
        self.invalidateFsrpcAttachment();
        if (self.debug_stream_enabled) self.requestDebugStreamSnapshot(true);
        if (self.node_service_watch_enabled) self.requestNodeServiceSnapshot(true);
        try self.setDefaultAgentInSettings(resolved_agent);
    }

    fn attachSessionBinding(self: *App, client: *ws_client_mod.WebSocketClient, session_key: []const u8) !void {
        const project_id = self.preferredAttachProjectId();
        const project_token = self.projectTokenForSessionProject(project_id);
        try self.attachSessionBindingWithProject(
            client,
            session_key,
            project_id,
            project_token,
        );
    }

    fn tryConnect(self: *App, manager: *panel_manager.PanelManager) !void {
        if (self.settings_panel.server_url.items.len == 0) {
            self.setConnectionState(.error_state, "Server URL cannot be empty");
            return;
        }

        const had_pending_send = self.pending_send_message_id != null;
        self.setConnectionState(.connecting, "Connecting...");
        self.session_attach_state = .unknown;
        self.clearConnectSetupHint();
        self.stopFilesystemWorker();
        self.clearFilesystemDirCache();
        self.clearContractServices();
        self.clearTerminalState();
        self.resetFsrpcConnectionState();
        if (self.ws_client) |*existing| {
            while (existing.tryReceive()) |msg| self.allocator.free(msg);
            existing.deinit();
            self.ws_client = null;
        }
        self.debug_stream_enabled = true;
        self.debug_stream_snapshot_pending = false;
        self.debug_stream_snapshot_retry_at_ms = 0;
        self.node_service_watch_enabled = false;
        self.node_service_snapshot_pending = false;
        self.node_service_snapshot_retry_at_ms = 0;
        self.clearDebugStreamSnapshot();

        const effective_url = self.settings_panel.server_url.items;
        try self.persistLauncherConnectToken();
        const connect_token = self.config.getRoleToken(self.config.active_role);
        if (connect_token.len == 0) {
            const msg = try std.fmt.allocPrint(
                self.allocator,
                "{s} token is required to connect.",
                .{self.activeRoleLabel()},
            );
            defer self.allocator.free(msg);
            self.setConnectionState(.error_state, msg);
            if (self.ui_stage == .launcher) self.setLauncherNotice(msg);
            return error.AuthTokenRequired;
        }
        var ws_client = ws_client_mod.WebSocketClient.init(self.allocator, effective_url, connect_token) catch |err| {
            const msg = try std.fmt.allocPrint(self.allocator, "Client init failed: {s}", .{@errorName(err)});
            defer self.allocator.free(msg);
            self.setConnectionState(.error_state, msg);
            return;
        };
        ws_client.setVerboseLogs(self.settings_panel.ws_verbose_logs);
        self.ws_client = ws_client;

        self.ws_client.?.connect() catch |err| {
            self.ws_client.?.deinit();
            self.ws_client = null;
            const msg = try std.fmt.allocPrint(self.allocator, "Connect failed: {s}", .{@errorName(err)});
            defer self.allocator.free(msg);
            self.setConnectionState(.error_state, msg);
            return;
        };

        var attach_warning: ?[]u8 = null;
        defer if (attach_warning) |value| self.allocator.free(value);
        var worker_attach_session: ?[]const u8 = null;
        var worker_attach_agent: ?[]const u8 = null;
        var worker_attach_project_id: ?[]const u8 = null;
        var worker_attach_project_token: ?[]const u8 = null;
        var fetched_worker_agent: ?[]u8 = null;
        defer if (fetched_worker_agent) |value| self.allocator.free(value);

        if (self.ws_client) |*client| {
            const connect_payload_json = control_plane.ensureUnifiedV2ConnectionPayloadJsonWithTimeout(
                self.allocator,
                client,
                &self.message_counter,
                CONTROL_CONNECT_TIMEOUT_MS,
            ) catch |err| {
                client.deinit();
                self.ws_client = null;
                const msg = if (err == error.RemoteError) blk: {
                    if (control_plane.lastRemoteError()) |remote| {
                        if (isProvisioningRemoteError(remote)) {
                            break :blk self.formatControlRemoteMessage("Connection blocked", remote) orelse
                                try std.fmt.allocPrint(self.allocator, "Connection blocked: {s}", .{remote});
                        }
                        if (isTokenAuthRemoteError(remote)) {
                            self.disableAutoConnectAfterAuthFailure();
                            self.settings_panel.focused_field = .project_operator_token;
                            break :blk try std.fmt.allocPrint(
                                self.allocator,
                                "Handshake failed: {s}. Update token in Projects and reconnect.",
                                .{remote},
                            );
                        }
                        break :blk try std.fmt.allocPrint(self.allocator, "Handshake failed: {s}", .{remote});
                    }
                    break :blk try std.fmt.allocPrint(self.allocator, "Handshake failed: {s}", .{@errorName(err)});
                } else try std.fmt.allocPrint(self.allocator, "Handshake failed: {s}", .{@errorName(err)});
                defer self.allocator.free(msg);
                self.setConnectionState(.error_state, msg);
                return;
            };
            defer self.allocator.free(connect_payload_json);
            self.applyConnectSetupHintFromPayload(connect_payload_json) catch |err| {
                std.log.warn("Failed to parse connect setup hint payload: {s}", .{@errorName(err)});
                self.clearConnectSetupHint();
            };

            if (self.settings_panel.default_session.items.len == 0) {
                if (self.config.default_session) |default_session| {
                    const seed = if (default_session.len > 0) default_session else "main";
                    try self.settings_panel.default_session.appendSlice(self.allocator, seed);
                } else {
                    try self.settings_panel.default_session.appendSlice(self.allocator, "main");
                }
            }
            const raw_attach_session = self.settings_panel.default_session.items;
            const attach_session_owned = try sanitizeSessionKey(self.allocator, raw_attach_session);
            defer self.allocator.free(attach_session_owned);
            if (!std.mem.eql(u8, attach_session_owned, raw_attach_session)) {
                self.settings_panel.default_session.clearRetainingCapacity();
                try self.settings_panel.default_session.appendSlice(self.allocator, attach_session_owned);
            }
            const attach_session = self.settings_panel.default_session.items;
            try self.ensureSessionExists(attach_session, attach_session);
            worker_attach_session = attach_session;
            worker_attach_project_id = self.preferredAttachProjectId();
            worker_attach_project_token = self.projectTokenForSessionProject(worker_attach_project_id);

            self.attachSessionBinding(client, attach_session) catch |err| {
                if (err == error.ProjectIdRequired) {
                    attach_warning = try self.allocator.dupe(
                        u8,
                        "Session attach requires an explicit project. Select a project in Settings and reconnect.",
                    );
                    worker_attach_project_id = null;
                    worker_attach_project_token = null;
                } else if (err == error.NoProjectCompatibleAgent) {
                    attach_warning = try self.allocator.dupe(
                        u8,
                        "No non-system agent is available for the selected project. Provision/select a project agent and reconnect.",
                    );
                    worker_attach_project_id = null;
                    worker_attach_project_token = null;
                } else {
                    const primary_detail_owned = try self.allocator.dupe(
                        u8,
                        if (err == error.RemoteError)
                            (control_plane.lastRemoteError() orelse @errorName(err))
                        else
                            @errorName(err),
                    );
                    defer self.allocator.free(primary_detail_owned);

                    if (isProvisioningRemoteError(primary_detail_owned)) {
                        std.log.err("Session attach blocked: {s}", .{primary_detail_owned});
                        client.deinit();
                        self.ws_client = null;
                        const msg = self.formatControlRemoteMessage("Session attach failed", primary_detail_owned) orelse
                            try std.fmt.allocPrint(self.allocator, "Session attach failed: {s}", .{primary_detail_owned});
                        defer self.allocator.free(msg);
                        self.setConnectionState(.error_state, msg);
                        return;
                    }

                    std.log.err("Session attach failed: {s}", .{primary_detail_owned});
                    worker_attach_project_id = null;
                    worker_attach_project_token = null;
                    attach_warning = try std.fmt.allocPrint(
                        self.allocator,
                        "Session attach failed ({s}). Select a project and reconnect.",
                        .{primary_detail_owned},
                    );
                }
            };

            worker_attach_agent = self.selectedAgentId();
            if (worker_attach_agent == null) {
                fetched_worker_agent = self.fetchDefaultAgentFromServer(client, attach_session) catch null;
                if (fetched_worker_agent) |agent_id| {
                    worker_attach_agent = agent_id;
                    self.setDefaultAgentInSettings(agent_id) catch {};
                }
            }
        }

        if (worker_attach_project_id != null) {
            self.startFilesystemWorker(
                effective_url,
                connect_token,
                worker_attach_session,
                worker_attach_agent,
                worker_attach_project_id,
                worker_attach_project_token,
            ) catch |err| {
                std.log.warn("Failed to ready filesystem transport: {s}", .{@errorName(err)});
                const warning = std.fmt.allocPrint(
                    self.allocator,
                    "Filesystem transport unavailable: {s}",
                    .{@errorName(err)},
                ) catch null;
                defer if (warning) |value| self.allocator.free(value);
                if (warning) |value| self.setFilesystemError(value);
            };
        } else {
            self.setFilesystemError("Filesystem transport unavailable until a project is selected and attached.");
        }

        self.setConnectionState(.connected, "Connected");
        if (self.ui_stage == .launcher) {
            self.setLauncherNotice("Connected. Select a project to open workspace.");
        }
        self.requestDebugStreamSnapshot(true);
        self.node_service_watch_enabled = true;
        self.requestNodeServiceSnapshot(true);
        self.settings_panel.focused_field = .none;
        if (self.ws_client) |*client| {
            const session_key_for_status = if (self.settings_panel.default_session.items.len > 0)
                self.settings_panel.default_session.items
            else
                "main";
            self.refreshSessionAttachStatusOnce(client, session_key_for_status);
        }
        self.refreshWorkspaceData() catch |err| {
            if (self.formatControlOpError("Workspace refresh failed", err)) |msg| {
                defer self.allocator.free(msg);
                self.setWorkspaceError(msg);
            }
        };
        self.loadSessionHistoryFromServer(false) catch |err| {
            std.log.warn("Failed to load session history on connect: {s}", .{@errorName(err)});
        };

        // Save selected role token + profile fields after successful connect.
        self.config.setRoleToken(self.config.active_role, connect_token) catch {};
        if (self.settings_panel.default_session.items.len == 0) {
            try self.settings_panel.default_session.appendSlice(self.allocator, "main");
        }
        self.syncSettingsToConfig() catch |err| {
            std.log.warn("Failed to save config on connect: {s}", .{@errorName(err)});
        };
        if (self.chat_sessions.items.len == 0) {
            try self.ensureSessionExists("main", "Main");
        } else if (self.current_session_key == null) {
            try self.setCurrentSessionKey(self.chat_sessions.items[0].key);
        }

        if (attach_warning) |warning| {
            self.setWorkspaceError(warning);
            try self.appendMessage("system", warning, null);
        }
        if (self.connect_setup_hint) |hint| {
            if (hint.required) {
                const base = hint.message orelse "Project setup is required. Ask Mother to gather setup details.";
                const setup_notice = if (hint.project_vision) |vision|
                    std.fmt.allocPrint(self.allocator, "{s} Project vision: {s}", .{ base, vision }) catch null
                else
                    self.allocator.dupe(u8, base) catch null;
                defer if (setup_notice) |value| self.allocator.free(value);
                if (setup_notice) |notice| {
                    if (attach_warning == null) self.setWorkspaceError(notice);
                    try self.appendMessage("system", notice, null);
                }
            }
        }

        if (had_pending_send) {
            self.pending_send_resume_notified = true;
        }
        if (had_pending_send and try self.tryResumePendingSendJob()) {
            try self.appendMessage("system", "Reconnected to Spiderweb and resumed pending job.", null);
        } else if (had_pending_send) {
            try self.appendMessage("system", "Reconnected to Spiderweb. Pending job not ready yet.", null);
        } else {
            try self.appendMessage("system", "Connected to Spiderweb", null);
        }

        // Switch to chat panel by focusing it
        for (manager.workspace.panels.items) |*panel| {
            if (panel.kind == .Chat) {
                manager.focusPanel(panel.id);
                break;
            }
        }
    }

    fn focusSettingsPanel(_: *App, manager: *panel_manager.PanelManager) void {
        for (manager.workspace.panels.items) |*panel| {
            if (panel.kind == .Settings or panel.kind == .Control) {
                manager.focusPanel(panel.id);
                break;
            }
        }
    }

    fn ensureWorkspacePanel(self: *App, manager: *panel_manager.PanelManager) void {
        for (manager.workspace.panels.items) |*panel| {
            if (panel.kind == .Settings or panel.kind == .Control) {
                manager.focusPanel(panel.id);
                return;
            }
        }
        manager.ensurePanel(.Control);
        self.focusSettingsPanel(manager);
    }

    fn focusChatPanel(_: *App, manager: *panel_manager.PanelManager) void {
        for (manager.workspace.panels.items) |*panel| {
            if (panel.kind == .Chat) {
                manager.focusPanel(panel.id);
                return;
            }
        }
    }

    fn focusedFormScrollTarget(self: *App, manager: *panel_manager.PanelManager) FormScrollTarget {
        const focused_id = manager.workspace.focused_panel_id orelse return .none;
        const panel = self.findPanelById(manager, focused_id) orelse return .none;
        if (panel.kind == .Settings or panel.kind == .Control) return .settings;
        return .none;
    }

    fn focusedFormScrollY(self: *App, manager: *panel_manager.PanelManager) ?*f32 {
        return switch (self.focusedFormScrollTarget(manager)) {
            .settings => &self.settings_panel.settings_scroll_y,
            .projects => &self.settings_panel.projects_scroll_y,
            .none => null,
        };
    }

    fn hasPanelWithTitle(_: *App, manager: *panel_manager.PanelManager, title: []const u8) bool {
        for (manager.workspace.panels.items) |*panel| {
            if (std.mem.eql(u8, panel.title, title)) return true;
        }
        return false;
    }

    fn syncLauncherSelectionFromConfig(self: *App) void {
        self.launcher_selected_profile_index = 0;
        const selected_id = self.config.selected_profile_id orelse return;
        for (self.config.connection_profiles, 0..) |profile, idx| {
            if (!std.mem.eql(u8, profile.id, selected_id)) continue;
            self.launcher_selected_profile_index = idx;
            return;
        }
    }

    fn nextConnectionProfileId(self: *App, profile_name: []const u8) ![]u8 {
        var slug = std.ArrayList(u8).empty;
        defer slug.deinit(self.allocator);

        var wrote_separator = false;
        for (profile_name) |ch| {
            if (std.ascii.isAlphanumeric(ch)) {
                try slug.append(self.allocator, std.ascii.toLower(ch));
                wrote_separator = false;
                continue;
            }
            if (!wrote_separator and slug.items.len > 0) {
                try slug.append(self.allocator, '-');
                wrote_separator = true;
            }
        }
        while (slug.items.len > 0 and slug.items[slug.items.len - 1] == '-') {
            slug.items.len -= 1;
        }
        if (slug.items.len == 0) {
            try slug.appendSlice(self.allocator, "profile");
        }

        var suffix: usize = 1;
        while (true) : (suffix += 1) {
            const candidate = if (suffix == 1)
                try self.allocator.dupe(u8, slug.items)
            else
                try std.fmt.allocPrint(self.allocator, "{s}-{d}", .{ slug.items, suffix });
            if (!self.config.hasConnectionProfileId(candidate)) return candidate;
            self.allocator.free(candidate);
        }
    }

    fn saveSelectedProfileFromLauncher(self: *App) !void {
        if (self.config.connection_profiles.len == 0) return error.ProfileNotFound;
        const profile_name = std.mem.trim(u8, self.launcher_profile_name.items, " \t\r\n");
        const server_url = std.mem.trim(u8, self.settings_panel.server_url.items, " \t\r\n");
        const metadata_trimmed = std.mem.trim(u8, self.launcher_profile_metadata.items, " \t\r\n");
        if (server_url.len == 0) return error.ServerUrlRequired;

        try self.config.updateSelectedConnectionProfile(
            profile_name,
            server_url,
            self.config.active_role,
            if (metadata_trimmed.len > 0) metadata_trimmed else null,
        );
        try self.persistLauncherConnectToken();
        try self.config.save();
        self.setLauncherNotice("Profile saved.");
    }

    fn createConnectionProfileFromLauncher(self: *App) !void {
        const profile_name = std.mem.trim(u8, self.launcher_profile_name.items, " \t\r\n");
        const server_url = std.mem.trim(u8, self.settings_panel.server_url.items, " \t\r\n");
        const metadata_trimmed = std.mem.trim(u8, self.launcher_profile_metadata.items, " \t\r\n");
        if (server_url.len == 0) return error.ServerUrlRequired;

        const display_name = if (profile_name.len > 0) profile_name else "Spider Web";
        const profile_id = try self.nextConnectionProfileId(display_name);
        defer self.allocator.free(profile_id);

        try self.config.addConnectionProfile(
            profile_id,
            display_name,
            server_url,
            self.config.active_role,
            if (metadata_trimmed.len > 0) metadata_trimmed else null,
        );
        try self.config.setSelectedProfileById(profile_id);
        self.syncLauncherSelectionFromConfig();
        try self.applyLauncherSelectedProfile();
        try self.config.save();
        self.setLauncherNotice("Profile created.");
    }

    fn applyLauncherSelectedProfile(self: *App) !void {
        if (self.config.connection_profiles.len == 0) return;
        const index = @min(self.launcher_selected_profile_index, self.config.connection_profiles.len - 1);
        const profile = self.config.connection_profiles[index];
        try self.config.setSelectedProfileById(profile.id);
        self.settings_panel.server_url.clearRetainingCapacity();
        try self.settings_panel.server_url.appendSlice(self.allocator, self.config.server_url);
        self.launcher_profile_name.clearRetainingCapacity();
        try self.launcher_profile_name.appendSlice(self.allocator, profile.name);
        self.launcher_profile_metadata.clearRetainingCapacity();
        if (profile.metadata) |value| {
            try self.launcher_profile_metadata.appendSlice(self.allocator, value);
        }
        try self.config.setRoleToken(.admin, "");
        try self.config.setRoleToken(.user, "");
        self.settings_panel.project_operator_token.clearRetainingCapacity();
        if (self.credential_store.load(profile.id, "role_admin") catch null) |token| {
            defer self.allocator.free(token);
            try self.config.setRoleToken(.admin, token);
            try self.settings_panel.project_operator_token.appendSlice(self.allocator, token);
        }
        if (self.credential_store.load(profile.id, "role_user") catch null) |token| {
            defer self.allocator.free(token);
            try self.config.setRoleToken(.user, token);
        }
        try self.syncLauncherConnectTokenFromConfig();
    }

    fn setLauncherNotice(self: *App, message: []const u8) void {
        if (self.launcher_notice) |existing| self.allocator.free(existing);
        self.launcher_notice = self.allocator.dupe(u8, message) catch null;
    }

    fn clearLauncherNotice(self: *App) void {
        if (self.launcher_notice) |existing| self.allocator.free(existing);
        self.launcher_notice = null;
    }

    fn canRenderWorkspaceStage(self: *const App) bool {
        if (self.connection_state != .connected) return false;
        if (self.ws_client == null) return false;
        if (self.active_project_id == null) return false;
        return true;
    }

    fn layoutPathForProject(
        self: *App,
        profile_id: []const u8,
        project_id: []const u8,
    ) ![]u8 {
        const config_dir = try config_mod.Config.getConfigDir(self.allocator);
        defer self.allocator.free(config_dir);
        const hash = std.hash.Wyhash.hash(0, profile_id) ^ (std.hash.Wyhash.hash(0, project_id) << 1);
        const file_name = try std.fmt.allocPrint(self.allocator, "{x:0>16}.workspace.json", .{hash});
        defer self.allocator.free(file_name);
        const layouts_dir = try std.fs.path.join(self.allocator, &.{ config_dir, "layouts" });
        defer self.allocator.free(layouts_dir);
        try std.fs.cwd().makePath(layouts_dir);
        return std.fs.path.join(self.allocator, &.{ layouts_dir, file_name });
    }

    fn saveActiveWorkspaceLayout(self: *App) void {
        const profile_id = self.active_profile_id orelse return;
        const project_id = self.active_project_id orelse return;
        const layout_path = self.layoutPathForProject(profile_id, project_id) catch return;
        defer self.allocator.free(layout_path);
        zui.ui.workspace_store.save(self.allocator, layout_path, &self.manager.workspace) catch return;
        self.config.setWorkspaceLayoutPath(profile_id, project_id, layout_path) catch {};
        self.config.save() catch {};
    }

    fn restoreWorkspaceLayout(self: *App, profile_id: []const u8, project_id: []const u8) !void {
        const configured_path = self.config.workspaceLayoutPath(profile_id, project_id);
        const layout_path = if (configured_path) |path|
            try self.allocator.dupe(u8, path)
        else blk: {
            break :blk try self.layoutPathForProject(profile_id, project_id);
        };
        defer self.allocator.free(layout_path);

        var next_workspace = zui.ui.workspace_store.loadOrDefault(self.allocator, layout_path) catch |err| blk: {
            std.log.warn("Failed to load project layout, using canonical default: {s}", .{@errorName(err)});
            break :blk try workspace.Workspace.initDefault(self.allocator);
        };
        errdefer next_workspace.deinit(self.allocator);
        if (next_workspace.panels.items.len == 0) {
            next_workspace.deinit(self.allocator);
            next_workspace = try workspace.Workspace.initDefault(self.allocator);
        }

        self.closeAllSecondaryWindows();
        self.manager.deinit();
        self.manager = panel_manager.PanelManager.init(self.allocator, next_workspace, &self.next_panel_id);
        self.bindNextPanelId(&self.manager);
        self.bindMainWindowManager();
        self.migrateLegacyHostPanels(&self.manager);
        self.removeWorkspaceSettingsPanels(&self.manager);
        self.focusChatPanel(&self.manager);
    }

    fn openSelectedProjectFromLauncher(self: *App) !void {
        if (self.connection_state != .connected) return error.NotConnected;
        if (self.ws_client == null) return error.NotConnected;
        const project_id = self.selectedProjectId() orelse return error.ProjectIdRequired;
        if (project_id.len == 0) return error.ProjectIdRequired;
        try self.activateSelectedProject();
        const profile_id = self.config.selectedProfileId();
        self.saveActiveWorkspaceLayout();
        if (self.active_profile_id) |existing| self.allocator.free(existing);
        if (self.active_project_id) |existing| self.allocator.free(existing);
        self.active_profile_id = try self.allocator.dupe(u8, profile_id);
        self.active_project_id = try self.allocator.dupe(u8, project_id);
        self.ui_stage = .workspace;
        self.ide_menu_open = null;
        self.windows_menu_open_window_id = null;
        self.setLauncherNotice("Project opened.");
        self.restoreWorkspaceLayout(profile_id, project_id) catch {};
        self.config.recordRecentProject(profile_id, project_id, null) catch {};
        self.config.save() catch {};
        _ = c.SDL_SetWindowTitle(self.window, "SpiderApp - Workspace");
    }

    fn returnToLauncher(self: *App, reason: stage_machine.ReturnReason) void {
        self.saveActiveWorkspaceLayout();
        self.ui_stage = .launcher;
        self.ide_menu_open = null;
        self.windows_menu_open_window_id = null;
        if (self.active_profile_id) |value| {
            self.allocator.free(value);
            self.active_profile_id = null;
        }
        if (self.active_project_id) |value| {
            self.allocator.free(value);
            self.active_project_id = null;
        }
        self.closeAllSecondaryWindows();
        _ = c.SDL_SetWindowTitle(self.window, "SpiderApp - Launcher");
        switch (reason) {
            .switched_project => self.setLauncherNotice("Switched back to launcher. Select another project."),
            .connection_lost => self.setLauncherNotice("Connection lost. Reconnect to continue."),
            .disconnected => self.setLauncherNotice("Disconnected from Spider Web."),
            .none => self.clearLauncherNotice(),
        }

        if (reason == .switched_project and self.connection_state == .connected and self.ws_client != null) {
            self.refreshWorkspaceData() catch |err| {
                const msg = std.fmt.allocPrint(self.allocator, "Project refresh failed: {s}", .{@errorName(err)}) catch null;
                defer if (msg) |value| self.allocator.free(value);
                if (msg) |value| self.setLauncherNotice(value);
            };
        }
    }

    fn closeAllSecondaryWindows(self: *App) void {
        var idx: usize = 0;
        while (idx < self.ui_windows.items.len) {
            const window = self.ui_windows.items[idx];
            if (window.id == self.main_window_id) {
                idx += 1;
                continue;
            }
            _ = self.ui_windows.swapRemove(idx);
            self.destroyUiWindow(window);
        }
    }

    fn persistMainWindowGeometry(self: *App) void {
        var window_x: c_int = 0;
        var window_y: c_int = 0;
        var window_w: c_int = 0;
        var window_h: c_int = 0;
        _ = c.SDL_GetWindowPosition(self.window, &window_x, &window_y);
        _ = c.SDL_GetWindowSize(self.window, &window_w, &window_h);
        if (window_w <= 0 or window_h <= 0) return;

        self.config.window_x = window_x;
        self.config.window_y = window_y;
        self.config.window_width = window_w;
        self.config.window_height = window_h;
        self.config.save() catch |err| {
            std.log.warn("Failed to persist window geometry: {s}", .{@errorName(err)});
        };
    }

    fn disconnect(self: *App) void {
        self.setDragMouseCapture(false);
        self.debug_scrollbar_dragging = false;
        self.form_scroll_drag_target = .none;
        self.stopFilesystemWorker();
        if (self.ws_client) |*client| {
            client.deinit();
            self.ws_client = null;
        }
        self.clearPendingSend();
        self.clearSessions();
        self.debug_stream_enabled = false;
        self.debug_stream_snapshot_pending = false;
        self.debug_stream_snapshot_retry_at_ms = 0;
        self.node_service_watch_enabled = false;
        self.node_service_snapshot_pending = false;
        self.node_service_snapshot_retry_at_ms = 0;
        self.session_attach_state = .unknown;
        self.resetFsrpcConnectionState();
        self.clearDebugStreamSnapshot();
        self.clearWorkspaceData();
        self.clearFilesystemData();
        self.clearFilesystemDirCache();
        self.clearTerminalState();
        self.clearNodeServiceReloadDiagnostics();
    }

    fn saveConfig(self: *App) !void {
        if (self.settings_panel.default_session.items.len == 0) {
            try self.settings_panel.default_session.appendSlice(self.allocator, "main");
        }
        try self.syncSettingsToConfig();
    }

    fn parseNodeServiceWatchReplayLimit(self: *App) usize {
        const trimmed = std.mem.trim(u8, self.node_service_watch_replay_limit.items, " \t\r\n");
        if (trimmed.len == 0) return 25;
        const parsed = std.fmt.parseUnsigned(usize, trimmed, 10) catch return 25;
        return @min(parsed, 10_000);
    }

    fn subscribeNodeServiceEvents(self: *App, client: *ws_client_mod.WebSocketClient) void {
        _ = client;
        self.node_service_watch_enabled = true;
        self.requestNodeServiceSnapshot(true);
    }

    fn subscribeNodeServiceEventsFromUi(self: *App) !void {
        const client = if (self.ws_client) |*value|
            value
        else
            return error.NotConnected;
        self.subscribeNodeServiceEvents(client);
        if (self.node_service_watch_enabled) {
            try self.appendMessage("system", "Node service feed refreshed", null);
            return;
        }
        const remote = control_plane.lastRemoteError() orelse "Node service snapshot request failed";
        const hint = self.nodeWatchHintForRemote(remote);
        defer if (hint) |value| self.allocator.free(value);
        const message = if (hint) |value|
            std.fmt.allocPrint(self.allocator, "Node service feed failed: {s} {s}", .{ remote, value }) catch null
        else
            std.fmt.allocPrint(self.allocator, "Node service feed failed: {s}", .{remote}) catch null;
        defer if (message) |value| self.allocator.free(value);
        try self.appendMessage("system", message orelse remote, null);
        return error.ControlRequestFailed;
    }

    fn unsubscribeNodeServiceEventsFromUi(self: *App) !void {
        const client = if (self.ws_client) |*value|
            value
        else
            return error.NotConnected;
        _ = client;
        self.node_service_watch_enabled = false;
        self.node_service_snapshot_pending = false;
        self.node_service_snapshot_retry_at_ms = 0;
        try self.appendMessage("system", "Node service feed paused", null);
    }

    fn sendChatMessageText(self: *App, text: []const u8) !void {
        if (text.len == 0) return;
        std.log.info("[GUI] sendChatMessageText: text_len={d} connected={}", .{ text.len, self.ws_client != null });
        if (self.awaiting_reply) {
            try self.appendMessage("system", "Wait for the current send to finish.", null);
            return;
        }
        const client = if (self.ws_client) |*value|
            value
        else {
            try self.appendMessage("system", "No active websocket connection", null);
            return;
        };

        // Keep a session key for this send
        const session_key = try self.currentSessionOrDefault();
        if (session_key.len == 0) {
            try self.appendMessage("system", "No active session available", null);
            return;
        }
        const attach_project_id = self.preferredAttachProjectId();
        std.log.info(
            "[GUI] sendChatMessageText: session={s} project={s} attach_state={s}",
            .{ session_key, attach_project_id orelse "(none)", @tagName(self.session_attach_state) },
        );
        var attached_during_send = false;
        if (self.session_attach_state == .unknown or self.session_attach_state == .err or self.session_attach_state == .warming) {
            self.attachSessionBinding(client, session_key) catch |err| {
                if (err == error.ProjectIdRequired) {
                    const msg = "Session attach requires an explicit project. Select a project in Settings.";
                    self.setWorkspaceError(msg);
                    try self.appendMessage("system", msg, null);
                    return err;
                }
                if (err == error.NoProjectCompatibleAgent) {
                    const msg = "No non-system agent is available for the selected project. Provision/select a project agent first.";
                    self.setWorkspaceError(msg);
                    try self.appendMessage("system", msg, null);
                    return err;
                }
                const primary_detail_owned = try self.allocator.dupe(
                    u8,
                    if (err == error.RemoteError)
                        (control_plane.lastRemoteError() orelse @errorName(err))
                    else
                        @errorName(err),
                );
                defer self.allocator.free(primary_detail_owned);

                if (isProvisioningRemoteError(primary_detail_owned)) {
                    const err_text = self.formatControlRemoteMessage("Session attach failed", primary_detail_owned) orelse
                        try std.fmt.allocPrint(self.allocator, "Session attach failed: {s}", .{primary_detail_owned});
                    defer self.allocator.free(err_text);
                    self.setWorkspaceError(err_text);
                    try self.appendMessage("system", err_text, null);
                    return err;
                }

                const err_text = try std.fmt.allocPrint(self.allocator, "Session attach failed: {s}", .{primary_detail_owned});
                defer self.allocator.free(err_text);
                self.setWorkspaceError(err_text);
                try self.appendMessage("system", err_text, null);
                return err;
            };
            attached_during_send = true;
            self.refreshSessionAttachStatusOnce(client, session_key);
            std.log.info(
                "[GUI] sendChatMessageText: attach completed session={s} state={s}",
                .{ session_key, @tagName(self.session_attach_state) },
            );
        }
        if (self.session_attach_state == .err) {
            const detail = self.workspace_last_error orelse "Sandbox runtime is unavailable for this session.";
            try self.appendMessage("system", detail, null);
            return error.RemoteError;
        }

        if (attached_during_send and attach_project_id != null) {
            self.clearFilesystemError();
        }

        const user_msg_id = try self.nextMessageId("msg");
        const appended_user_msg_id = try self.appendMessageWithIdForSession(session_key, "user", text, .sending, user_msg_id);
        defer self.allocator.free(appended_user_msg_id);
        self.allocator.free(user_msg_id);
        try self.setPendingSend(self.allocator, appended_user_msg_id, session_key);

        const request_id = try self.nextMessageId("send");
        defer self.allocator.free(request_id);
        if (self.pending_send_request_id) |value| {
            self.allocator.free(value);
            self.pending_send_request_id = null;
        }
        self.pending_send_request_id = try self.allocator.dupe(u8, request_id);
        self.awaiting_reply = true;
        std.log.info(
            "[GUI] sendChatMessageText: submit request_id={s} session={s}",
            .{ request_id, session_key },
        );

        const submit = self.submitChatJobViaFsrpc(client, text) catch |err| {
            std.log.err("[GUI] sendChatMessageText: fsrpc submit failed: {s}", .{@errorName(err)});
            const remote_detail = if (err == error.RemoteError)
                (control_plane.lastRemoteError() orelse (self.fsrpc_last_remote_error orelse @errorName(err)))
            else
                @errorName(err);
            const err_text = if (err == error.RemoteError and isTokenAuthRemoteError(remote_detail))
                try std.fmt.allocPrint(
                    self.allocator,
                    "Send failed: {s}. Verify the {s} token in Launcher.",
                    .{ remote_detail, self.activeRoleLabel() },
                )
            else
                try std.fmt.allocPrint(self.allocator, "Send failed: {s}", .{remote_detail});
            defer self.allocator.free(err_text);
            try self.appendMessage("system", err_text, null);
            if (self.pending_send_message_id) |message_id| {
                try self.setMessageFailed(message_id);
            } else {
                try self.setMessageFailed(appended_user_msg_id);
            }
            self.clearPendingSend();
            return err;
        };
        std.log.info(
            "[GUI] sendChatMessageText: submit ok request_id={s} job_id={s}",
            .{ request_id, submit.job_id },
        );
        if (self.pending_send_job_id) |value| {
            self.allocator.free(value);
            self.pending_send_job_id = null;
        }
        if (self.pending_send_jobs_root) |value| {
            self.allocator.free(value);
            self.pending_send_jobs_root = null;
        }
        if (self.pending_send_correlation_id) |value| {
            self.allocator.free(value);
            self.pending_send_correlation_id = null;
        }
        self.pending_send_job_id = submit.job_id;
        self.pending_send_jobs_root = submit.jobs_root;
        self.pending_send_thoughts_root = submit.thoughts_root;
        self.pending_send_correlation_id = submit.correlation_id;
    }

    fn nextFsrpcTag(self: *App) u32 {
        if (self.ws_client) |*client| {
            return client.nextAcheronTag();
        }
        const tag = self.next_fsrpc_tag;
        self.next_fsrpc_tag +%= 1;
        if (self.next_fsrpc_tag == 0) self.next_fsrpc_tag = 1;
        return tag;
    }

    fn nextFsrpcFid(self: *App) u32 {
        if (self.ws_client) |*client| {
            return client.nextAcheronFid();
        }
        const fid = self.next_fsrpc_fid;
        self.next_fsrpc_fid +%= 1;
        if (self.next_fsrpc_fid == 0 or self.next_fsrpc_fid == 1) self.next_fsrpc_fid = 2;
        return fid;
    }

    fn fsrpcRequestTypeForLog(request_json: []const u8) []const u8 {
        inline for ([_][]const u8{
            "acheron.t_version",
            "acheron.t_attach",
            "acheron.t_walk",
            "acheron.t_open",
            "acheron.t_read",
            "acheron.t_write",
            "acheron.t_clunk",
        }) |needle| {
            if (std.mem.indexOf(u8, request_json, needle) != null) return needle;
        }
        return "unknown";
    }

    fn sendAndAwaitFsrpc(
        self: *App,
        client: *ws_client_mod.WebSocketClient,
        request_json: []const u8,
        tag: u32,
        timeout_ms: u32,
    ) !FsrpcEnvelope {
        const req_type = fsrpcRequestTypeForLog(request_json);
        std.log.info(
            "[GUI][FSRPC] send type={s} tag={d} timeout_ms={d}",
            .{ req_type, tag, timeout_ms },
        );
        client.send(request_json) catch |err| {
            std.log.err(
                "[GUI][FSRPC] send failed type={s} tag={d} err={s}",
                .{ req_type, tag, @errorName(err) },
            );
            return err;
        };
        const raw = client.awaitAcheronFrame(tag, timeout_ms) catch |err| {
            std.log.err(
                "[GUI][FSRPC] await failed type={s} tag={d} err={s} alive={}",
                .{ req_type, tag, @errorName(err), client.isAlive() },
            );
            return err;
        } orelse {
            std.log.err(
                "[GUI][FSRPC] await timeout type={s} tag={d} alive={}",
                .{ req_type, tag, client.isAlive() },
            );
            return error.Timeout;
        };
        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, raw, .{}) catch {
            std.log.err(
                "[GUI][FSRPC] parse failed type={s} tag={d}",
                .{ req_type, tag },
            );
            self.allocator.free(raw);
            return error.InvalidResponse;
        };
        std.log.info(
            "[GUI][FSRPC] recv type={s} tag={d} bytes={d} alive={}",
            .{ req_type, tag, raw.len, client.isAlive() },
        );
        if (!client.isAlive()) {
            self.fsrpc_ready = false;
        }
        return .{
            .raw = raw,
            .parsed = parsed,
        };
    }

    fn ensureFsrpcOk(self: *App, envelope: *FsrpcEnvelope) !void {
        if (envelope.parsed.value != .object) return error.InvalidResponse;
        const obj = envelope.parsed.value.object;
        const ok_value = obj.get("ok") orelse return error.InvalidResponse;
        if (ok_value != .bool) return error.InvalidResponse;
        if (ok_value.bool) {
            self.session_attach_state = .ready;
            self.clearFsrpcRemoteError();
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
                if (code) |value| {
                    if (std.mem.eql(u8, value, "runtime_warming")) runtime_warming = true;
                }
                const errno = if (err_obj.get("errno")) |value|
                    if (value == .integer) value.integer else null
                else
                    null;

                if (message != null and code != null and errno != null) {
                    detail = std.fmt.allocPrint(self.allocator, "{s} [{s}] (errno={d})", .{ message.?, code.?, errno.? }) catch null;
                } else if (message != null and errno != null) {
                    detail = std.fmt.allocPrint(self.allocator, "{s} (errno={d})", .{ message.?, errno.? }) catch null;
                } else if (message != null and code != null) {
                    detail = std.fmt.allocPrint(self.allocator, "{s} [{s}]", .{ message.?, code.? }) catch null;
                } else if (message) |value| {
                    detail = self.allocator.dupe(u8, value) catch null;
                } else if (code) |value| {
                    detail = std.fmt.allocPrint(self.allocator, "remote fsrpc error [{s}]", .{value}) catch null;
                } else if (errno) |value| {
                    detail = std.fmt.allocPrint(self.allocator, "remote fsrpc error (errno={d})", .{value}) catch null;
                }
            } else if (err_value == .string) {
                detail = self.allocator.dupe(u8, err_value.string) catch null;
            }
        }

        if (detail) |value| {
            defer self.allocator.free(value);
            self.setFsrpcRemoteError(value);
            std.log.warn("[GUI][FSRPC] remote error: {s}", .{value});
        } else {
            self.setFsrpcRemoteError("remote fsrpc error");
            std.log.warn("[GUI][FSRPC] remote error: remote fsrpc error", .{});
        }
        if (runtime_warming) {
            self.session_attach_state = .unknown;
            if (self.connection_state == .connected) {
                self.setConnectionState(.connected, "Connected");
            }
            self.setFsrpcRemoteError("sandbox runtime unavailable");
            return error.RemoteError;
        }
        return error.RemoteError;
    }

    fn getFsrpcPayloadObject(self: *App, root: std.json.ObjectMap) !std.json.ObjectMap {
        _ = self;
        const payload = root.get("payload") orelse return error.InvalidResponse;
        if (payload != .object) return error.InvalidResponse;
        return payload.object;
    }

    fn fsrpcBootstrapGui(self: *App, client: *ws_client_mod.WebSocketClient) !void {
        if (self.fsrpc_ready) {
            std.log.info("[GUI][FSRPC] bootstrap skipped: already ready", .{});
            return;
        }

        std.log.info("[GUI][FSRPC] bootstrap start", .{});

        try control_plane.ensureUnifiedV2Connection(
            self.allocator,
            client,
            &self.message_counter,
        );
        std.log.info("[GUI][FSRPC] unified-v2 ready", .{});

        const version_tag = self.nextFsrpcTag();
        const version_req = try std.fmt.allocPrint(
            self.allocator,
            "{{\"channel\":\"acheron\",\"type\":\"acheron.t_version\",\"tag\":{d},\"msize\":1048576,\"version\":\"acheron-1\"}}",
            .{version_tag},
        );
        defer self.allocator.free(version_req);
        var version = try self.sendAndAwaitFsrpc(client, version_req, version_tag, FSRPC_DEFAULT_TIMEOUT_MS);
        defer version.deinit(self.allocator);
        try self.ensureFsrpcOk(&version);
        std.log.info("[GUI][FSRPC] version ok tag={d}", .{version_tag});

        const attach_tag = self.nextFsrpcTag();
        const attach_req = try std.fmt.allocPrint(
            self.allocator,
            "{{\"channel\":\"acheron\",\"type\":\"acheron.t_attach\",\"tag\":{d},\"fid\":1}}",
            .{attach_tag},
        );
        defer self.allocator.free(attach_req);
        var attach = try self.sendAndAwaitFsrpc(client, attach_req, attach_tag, FSRPC_DEFAULT_TIMEOUT_MS);
        defer attach.deinit(self.allocator);
        try self.ensureFsrpcOk(&attach);
        self.fsrpc_ready = true;
        std.log.info("[GUI][FSRPC] bootstrap ready attach_tag={d}", .{attach_tag});
    }

    fn fsrpcClunkBestEffort(self: *App, client: *ws_client_mod.WebSocketClient, fid: u32) void {
        const tag = self.nextFsrpcTag();
        const req = std.fmt.allocPrint(
            self.allocator,
            "{{\"channel\":\"acheron\",\"type\":\"acheron.t_clunk\",\"tag\":{d},\"fid\":{d}}}",
            .{ tag, fid },
        ) catch return;
        defer self.allocator.free(req);

        var response = self.sendAndAwaitFsrpc(client, req, tag, FSRPC_CLUNK_TIMEOUT_MS) catch return;
        response.deinit(self.allocator);
    }

    fn sendChatViaFsrpc(self: *App, client: *ws_client_mod.WebSocketClient, text: []const u8) ![]u8 {
        var submit = try self.submitChatJobViaFsrpc(client, text);
        defer submit.deinit(self.allocator);

        const result_fid = self.nextFsrpcFid();
        defer self.fsrpcClunkBestEffort(client, result_fid);

        const result_path = try std.fmt.allocPrint(
            self.allocator,
            "{s}/{s}/result.txt",
            .{ submit.jobs_root, submit.job_id },
        );
        defer self.allocator.free(result_path);
        try self.walkPathGui(client, result_fid, result_path);

        const open_result_tag = self.nextFsrpcTag();
        const open_result_req = try std.fmt.allocPrint(
            self.allocator,
            "{{\"channel\":\"acheron\",\"type\":\"acheron.t_open\",\"tag\":{d},\"fid\":{d},\"mode\":\"r\"}}",
            .{ open_result_tag, result_fid },
        );
        defer self.allocator.free(open_result_req);
        var open_result = try self.sendAndAwaitFsrpc(client, open_result_req, open_result_tag, FSRPC_DEFAULT_TIMEOUT_MS);
        defer open_result.deinit(self.allocator);
        try self.ensureFsrpcOk(&open_result);

        const read_tag = self.nextFsrpcTag();
        const read_req = try std.fmt.allocPrint(
            self.allocator,
            "{{\"channel\":\"acheron\",\"type\":\"acheron.t_read\",\"tag\":{d},\"fid\":{d},\"offset\":0,\"count\":1048576}}",
            .{ read_tag, result_fid },
        );
        defer self.allocator.free(read_req);
        var read = try self.sendAndAwaitFsrpc(client, read_req, read_tag, FSRPC_DEFAULT_TIMEOUT_MS);
        defer read.deinit(self.allocator);
        try self.ensureFsrpcOk(&read);

        const read_payload = try self.getFsrpcPayloadObject(read.parsed.value.object);
        const data_b64 = read_payload.get("data_b64") orelse return error.InvalidResponse;
        if (data_b64 != .string) return error.InvalidResponse;

        const decoded_len = std.base64.standard.Decoder.calcSizeForSlice(data_b64.string) catch return error.InvalidResponse;
        const decoded = try self.allocator.alloc(u8, decoded_len);
        errdefer self.allocator.free(decoded);
        _ = std.base64.standard.Decoder.decode(decoded, data_b64.string) catch return error.InvalidResponse;

        return decoded;
    }

    fn submitChatJobViaFsrpc(self: *App, client: *ws_client_mod.WebSocketClient, text: []const u8) !SubmitChatJobResult {
        std.log.info("[GUI][FSRPC] submitChatJobViaFsrpc start text_len={d}", .{text.len});
        try self.fsrpcBootstrapGui(client);
        var chat_paths = try self.discoverScopedChatBindingPathsGui(client);
        defer chat_paths.deinit(self.allocator);

        const input_fid = self.nextFsrpcFid();
        defer self.fsrpcClunkBestEffort(client, input_fid);
        std.log.info("[GUI][FSRPC] chat input fid={d}", .{input_fid});
        try self.walkPathGui(client, input_fid, chat_paths.input_path);

        const open_input_tag = self.nextFsrpcTag();
        const open_input_req = try std.fmt.allocPrint(
            self.allocator,
            "{{\"channel\":\"acheron\",\"type\":\"acheron.t_open\",\"tag\":{d},\"fid\":{d},\"mode\":\"rw\"}}",
            .{ open_input_tag, input_fid },
        );
        defer self.allocator.free(open_input_req);
        var open_input = try self.sendAndAwaitFsrpc(client, open_input_req, open_input_tag, FSRPC_DEFAULT_TIMEOUT_MS);
        defer open_input.deinit(self.allocator);
        try self.ensureFsrpcOk(&open_input);
        std.log.info("[GUI][FSRPC] chat input open ok fid={d}", .{input_fid});

        const encoded = try encodeDataB64(self.allocator, text);
        defer self.allocator.free(encoded);
        var generated_write_request_id: ?[]const u8 = null;
        defer if (generated_write_request_id) |value| self.allocator.free(value);
        const write_request_id = if (self.pending_send_request_id) |pending|
            pending
        else blk: {
            const generated = try self.nextMessageId("job");
            generated_write_request_id = generated;
            break :blk generated;
        };
        const escaped_write_request_id = try jsonEscape(self.allocator, write_request_id);
        defer self.allocator.free(escaped_write_request_id);
        const write_tag = self.nextFsrpcTag();
        const write_req = try std.fmt.allocPrint(
            self.allocator,
            "{{\"channel\":\"acheron\",\"type\":\"acheron.t_write\",\"tag\":{d},\"id\":\"{s}\",\"fid\":{d},\"offset\":0,\"data_b64\":\"{s}\"}}",
            .{ write_tag, escaped_write_request_id, input_fid, encoded },
        );
        defer self.allocator.free(write_req);
        var write = try self.sendAndAwaitFsrpc(client, write_req, write_tag, FSRPC_CHAT_WRITE_TIMEOUT_MS);
        defer write.deinit(self.allocator);
        try self.ensureFsrpcOk(&write);

        const write_payload = try self.getFsrpcPayloadObject(write.parsed.value.object);
        const job_value = write_payload.get("job") orelse return error.InvalidResponse;
        if (job_value != .string) return error.InvalidResponse;
        std.log.info(
            "[GUI][FSRPC] chat write ok fid={d} request_id={s} job={s}",
            .{ input_fid, write_request_id, job_value.string },
        );
        return .{
            .job_id = try self.allocator.dupe(u8, job_value.string),
            .jobs_root = try self.allocator.dupe(u8, chat_paths.jobs_root),
            .thoughts_root = try self.allocator.dupe(u8, chat_paths.thoughts_root),
            .correlation_id = if (write_payload.get("correlation_id")) |value|
                if (value == .string and value.string.len > 0) try self.allocator.dupe(u8, value.string) else null
            else
                null,
        };
    }

    fn walkPathGui(self: *App, client: *ws_client_mod.WebSocketClient, fid: u32, path: []const u8) !void {
        var segments = try self.splitFsPathSegments(path);
        defer self.freeFsPathSegments(&segments);
        const path_json = try self.buildPathArrayJsonGui(segments.items);
        defer self.allocator.free(path_json);

        const walk_tag = self.nextFsrpcTag();
        const walk_req = try std.fmt.allocPrint(
            self.allocator,
            "{{\"channel\":\"acheron\",\"type\":\"acheron.t_walk\",\"tag\":{d},\"fid\":1,\"newfid\":{d},\"path\":{s}}}",
            .{ walk_tag, fid, path_json },
        );
        defer self.allocator.free(walk_req);
        var walk = try self.sendAndAwaitFsrpc(client, walk_req, walk_tag, FSRPC_DEFAULT_TIMEOUT_MS);
        defer walk.deinit(self.allocator);
        try self.ensureFsrpcOk(&walk);
    }

    fn splitFsPathSegments(self: *App, path: []const u8) !std.ArrayListUnmanaged([]u8) {
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

    fn freeFsPathSegments(self: *App, segments: *std.ArrayListUnmanaged([]u8)) void {
        for (segments.items) |segment| self.allocator.free(segment);
        segments.deinit(self.allocator);
        segments.* = .{};
    }

    fn buildPathArrayJsonGui(self: *App, segments: []const []const u8) ![]u8 {
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

    fn fsrpcWalkPathGui(self: *App, client: *ws_client_mod.WebSocketClient, path: []const u8) !u32 {
        var segments = try self.splitFsPathSegments(path);
        defer self.freeFsPathSegments(&segments);
        const path_json = try self.buildPathArrayJsonGui(segments.items);
        defer self.allocator.free(path_json);

        const new_fid = self.nextFsrpcFid();
        const tag = self.nextFsrpcTag();
        const req = try std.fmt.allocPrint(
            self.allocator,
            "{{\"channel\":\"acheron\",\"type\":\"acheron.t_walk\",\"tag\":{d},\"fid\":1,\"newfid\":{d},\"path\":{s}}}",
            .{ tag, new_fid, path_json },
        );
        defer self.allocator.free(req);

        var response = try self.sendAndAwaitFsrpc(client, req, tag, FSRPC_DEFAULT_TIMEOUT_MS);
        defer response.deinit(self.allocator);
        try self.ensureFsrpcOk(&response);
        return new_fid;
    }

    fn fsrpcOpenGui(self: *App, client: *ws_client_mod.WebSocketClient, fid: u32, mode: []const u8) !void {
        const escaped_mode = try jsonEscape(self.allocator, mode);
        defer self.allocator.free(escaped_mode);
        const tag = self.nextFsrpcTag();
        const req = try std.fmt.allocPrint(
            self.allocator,
            "{{\"channel\":\"acheron\",\"type\":\"acheron.t_open\",\"tag\":{d},\"fid\":{d},\"mode\":\"{s}\"}}",
            .{ tag, fid, escaped_mode },
        );
        defer self.allocator.free(req);

        var response = try self.sendAndAwaitFsrpc(client, req, tag, FSRPC_DEFAULT_TIMEOUT_MS);
        defer response.deinit(self.allocator);
        try self.ensureFsrpcOk(&response);
    }

    fn fsrpcReadAllTextGui(self: *App, client: *ws_client_mod.WebSocketClient, fid: u32) ![]u8 {
        var out = std.ArrayListUnmanaged(u8){};
        errdefer out.deinit(self.allocator);

        var offset: u64 = 0;
        while (true) {
            const tag = self.nextFsrpcTag();
            const req = try std.fmt.allocPrint(
                self.allocator,
                "{{\"channel\":\"acheron\",\"type\":\"acheron.t_read\",\"tag\":{d},\"fid\":{d},\"offset\":{d},\"count\":{d}}}",
                .{ tag, fid, offset, FSRPC_READ_CHUNK_BYTES },
            );
            defer self.allocator.free(req);

            var response = try self.sendAndAwaitFsrpc(client, req, tag, FSRPC_DEFAULT_TIMEOUT_MS);
            defer response.deinit(self.allocator);
            try self.ensureFsrpcOk(&response);

            const payload = try self.getFsrpcPayloadObject(response.parsed.value.object);
            const data_b64 = payload.get("data_b64") orelse return error.InvalidResponse;
            if (data_b64 != .string) return error.InvalidResponse;

            const decoded_len = std.base64.standard.Decoder.calcSizeForSlice(data_b64.string) catch return error.InvalidResponse;
            const decoded = try self.allocator.alloc(u8, decoded_len);
            defer self.allocator.free(decoded);
            _ = std.base64.standard.Decoder.decode(decoded, data_b64.string) catch return error.InvalidResponse;

            if (decoded.len == 0) break;
            if (out.items.len + decoded.len > FSRPC_READ_MAX_TOTAL_BYTES) return error.ResponseTooLarge;
            try out.appendSlice(self.allocator, decoded);
            offset += @as(u64, @intCast(decoded.len));
            if (decoded.len < @as(usize, FSRPC_READ_CHUNK_BYTES)) break;
        }

        return out.toOwnedSlice(self.allocator);
    }

    fn jsonValueAsU64(value: std.json.Value) ?u64 {
        return switch (value) {
            .integer => if (value.integer >= 0) @intCast(value.integer) else null,
            .float => if (value.float >= 0) @intFromFloat(value.float) else null,
            .string => std.fmt.parseInt(u64, value.string, 10) catch null,
            else => null,
        };
    }

    fn jsonValueAsI64(value: std.json.Value) ?i64 {
        return switch (value) {
            .integer => value.integer,
            .float => @intFromFloat(value.float),
            .string => std.fmt.parseInt(i64, value.string, 10) catch null,
            else => null,
        };
    }

    fn jsonObjectFirstU64(obj: std.json.ObjectMap, keys: []const []const u8) ?u64 {
        for (keys) |key| {
            const value = obj.get(key) orelse continue;
            if (jsonValueAsU64(value)) |parsed| return parsed;
        }
        return null;
    }

    fn jsonObjectFirstI64(obj: std.json.ObjectMap, keys: []const []const u8) ?i64 {
        for (keys) |key| {
            const value = obj.get(key) orelse continue;
            if (jsonValueAsI64(value)) |parsed| return parsed;
        }
        return null;
    }

    fn normalizeFilesystemTimestampMs(value: ?i64) ?i64 {
        const raw = value orelse return null;
        if (raw > -100_000_000_000 and raw < 100_000_000_000) return raw * std.time.ms_per_s;
        return raw;
    }

    fn filesystemKindFromStatLabel(kind_label: []const u8) FilesystemEntryKind {
        if (std.mem.eql(u8, kind_label, "dir")) return .directory;
        if (std.mem.eql(u8, kind_label, "file")) return .file;
        if (std.mem.eql(u8, kind_label, "reg")) return .file;
        return .unknown;
    }

    fn fsrpcStatInfoGui(self: *App, client: *ws_client_mod.WebSocketClient, fid: u32) !FilesystemStatInfo {
        const tag = self.nextFsrpcTag();
        const req = try std.fmt.allocPrint(
            self.allocator,
            "{{\"channel\":\"acheron\",\"type\":\"acheron.t_stat\",\"tag\":{d},\"fid\":{d}}}",
            .{ tag, fid },
        );
        defer self.allocator.free(req);

        var response = try self.sendAndAwaitFsrpc(client, req, tag, FSRPC_DEFAULT_TIMEOUT_MS);
        defer response.deinit(self.allocator);
        try self.ensureFsrpcOk(&response);

        const payload = try self.getFsrpcPayloadObject(response.parsed.value.object);
        var info = FilesystemStatInfo{};
        const kind = payload.get("kind") orelse return error.InvalidResponse;
        if (kind != .string) return error.InvalidResponse;
        info.kind = filesystemKindFromStatLabel(kind.string);
        info.size_bytes = jsonObjectFirstU64(payload, &.{ "size", "size_bytes", "bytes", "length", "len" });
        info.modified_unix_ms = normalizeFilesystemTimestampMs(
            jsonObjectFirstI64(payload, &.{ "modified_ms", "mtime_ms", "mtime", "modified", "updated_at_ms", "modified_at", "updated_at" }),
        );
        return info;
    }

    fn fsrpcFidIsDirGui(self: *App, client: *ws_client_mod.WebSocketClient, fid: u32) !bool {
        const info = try self.fsrpcStatInfoGui(client, fid);
        return info.kind == .directory;
    }

    fn resolveFilesystemPathStatGui(
        self: *App,
        client: *ws_client_mod.WebSocketClient,
        path: []const u8,
    ) !FilesystemStatInfo {
        try self.fsrpcBootstrapGui(client);
        const fid = try self.fsrpcWalkPathGui(client, path);
        defer self.fsrpcClunkBestEffort(client, fid);
        return self.fsrpcStatInfoGui(client, fid);
    }

    fn readFsPathTextGui(self: *App, client: *ws_client_mod.WebSocketClient, path: []const u8) ![]u8 {
        const fid = try self.fsrpcWalkPathGui(client, path);
        defer self.fsrpcClunkBestEffort(client, fid);
        try self.fsrpcOpenGui(client, fid, "r");
        return self.fsrpcReadAllTextGui(client, fid);
    }

    fn fsrpcWriteTextGui(self: *App, client: *ws_client_mod.WebSocketClient, fid: u32, content: []const u8) !void {
        const encoded = try encodeDataB64(self.allocator, content);
        defer self.allocator.free(encoded);
        const tag = self.nextFsrpcTag();
        const req = try std.fmt.allocPrint(
            self.allocator,
            "{{\"channel\":\"acheron\",\"type\":\"acheron.t_write\",\"tag\":{d},\"fid\":{d},\"offset\":0,\"data_b64\":\"{s}\"}}",
            .{ tag, fid, encoded },
        );
        defer self.allocator.free(req);

        var response = try self.sendAndAwaitFsrpc(client, req, tag, FSRPC_CHAT_WRITE_TIMEOUT_MS);
        defer response.deinit(self.allocator);
        try self.ensureFsrpcOk(&response);
    }

    fn writeFsPathTextGui(self: *App, client: *ws_client_mod.WebSocketClient, path: []const u8, content: []const u8) !void {
        const fid = try self.fsrpcWalkPathGui(client, path);
        defer self.fsrpcClunkBestEffort(client, fid);
        try self.fsrpcOpenGui(client, fid, "rw");
        try self.fsrpcWriteTextGui(client, fid, content);
    }

    fn discoverScopedChatBindingPathsGui(self: *App, client: *ws_client_mod.WebSocketClient) !ScopedChatBindingPaths {
        const GuiFsPathReader = struct {
            app: *App,
            client: *ws_client_mod.WebSocketClient,

            pub fn readText(reader: @This(), path: []const u8) ![]u8 {
                return reader.app.readFsPathTextGui(reader.client, path);
            }
        };

        return venom_bindings.discoverChatBindingPaths(
            self.allocator,
            GuiFsPathReader{ .app = self, .client = client },
            .{
                .agent_id = self.selectedAgentId(),
                .project_id = self.selectedProjectId(),
            },
        );
    }

    fn joinFilesystemPath(self: *App, parent: []const u8, child: []const u8) ![]u8 {
        if (std.mem.eql(u8, parent, "/")) return std.fmt.allocPrint(self.allocator, "/{s}", .{child});
        if (std.mem.endsWith(u8, parent, "/")) return std.fmt.allocPrint(self.allocator, "{s}{s}", .{ parent, child });
        return std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ parent, child });
    }

    fn parentFilesystemPath(self: *App, path: []const u8) ![]u8 {
        const trimmed = std.mem.trimRight(u8, path, "/");
        if (trimmed.len == 0) return std.fmt.allocPrint(self.allocator, "/", .{});
        const idx = std.mem.lastIndexOfScalar(u8, trimmed, '/') orelse return std.fmt.allocPrint(self.allocator, "/", .{});
        if (idx == 0) return std.fmt.allocPrint(self.allocator, "/", .{});
        return std.fmt.allocPrint(self.allocator, "{s}", .{trimmed[0..idx]});
    }

    fn parseJobStatusInfo(self: *App, status_json: []const u8) !JobStatusInfo {
        var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, status_json, .{});
        defer parsed.deinit();
        if (parsed.value != .object) return error.InvalidResponse;
        const obj = parsed.value.object;

        const state_val = obj.get("state") orelse return error.InvalidResponse;
        if (state_val != .string) return error.InvalidResponse;
        var out = JobStatusInfo{
            .state = try self.allocator.dupe(u8, state_val.string),
        };
        errdefer out.deinit(self.allocator);

        if (obj.get("error")) |error_val| {
            if (error_val == .string and error_val.string.len > 0) {
                out.error_text = try self.allocator.dupe(u8, error_val.string);
            }
        }
        if (obj.get("correlation_id")) |corr_val| {
            if (corr_val == .string and corr_val.string.len > 0) {
                out.correlation_id = try self.allocator.dupe(u8, corr_val.string);
            }
        }
        return out;
    }

    fn readJobStatusGui(self: *App, client: *ws_client_mod.WebSocketClient, jobs_root: []const u8, job_id: []const u8) !JobStatusInfo {
        const raw = try self.readJobArtifactTextGui(client, jobs_root, job_id, "status.json");
        defer self.allocator.free(raw);
        return self.parseJobStatusInfo(raw);
    }

    fn readJobArtifactTextGui(
        self: *App,
        client: *ws_client_mod.WebSocketClient,
        jobs_root: []const u8,
        job_id: []const u8,
        leaf: []const u8,
    ) ![]u8 {
        const scoped_jobs_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}/{s}", .{ jobs_root, job_id, leaf });
        defer self.allocator.free(scoped_jobs_path);
        if (self.readFsPathTextGui(client, scoped_jobs_path) catch null) |raw| {
            return raw;
        }

        const jobs_path = try std.fmt.allocPrint(self.allocator, "/jobs/{s}/{s}", .{ job_id, leaf });
        defer self.allocator.free(jobs_path);
        if (self.readFsPathTextGui(client, jobs_path) catch null) |raw| {
            return raw;
        }

        const global_jobs_path = try std.fmt.allocPrint(self.allocator, "/global/jobs/{s}/{s}", .{ job_id, leaf });
        defer self.allocator.free(global_jobs_path);
        if (self.readFsPathTextGui(client, global_jobs_path) catch null) |raw| {
            return raw;
        }
        return error.FileNotFound;
    }

    fn replaySessionReceiveFromJobLog(self: *App, fallback_session_key: []const u8, log_text: []const u8) !bool {
        var replayed = false;
        var lines = std.mem.splitScalar(u8, log_text, '\n');
        while (lines.next()) |line_raw| {
            const line = std.mem.trim(u8, line_raw, " \t\r\n");
            if (line.len == 0) continue;

            var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, line, .{}) catch continue;
            defer parsed.deinit();
            if (parsed.value != .object) continue;

            const root = parsed.value.object;
            const type_val = root.get("type") orelse continue;
            if (type_val != .string or !std.mem.eql(u8, type_val.string, "session.receive")) continue;

            const payload_opt: ?std.json.ObjectMap = if (root.get("payload")) |payload_value| switch (payload_value) {
                .object => payload_value.object,
                else => null,
            } else root;
            const payload = payload_opt orelse root;
            const request_id = extractRequestId(root, payload_opt);
            const session_key = extractSessionKey(root, payload_opt) orelse fallback_session_key;
            const timestamp = if (payload.get("timestamp")) |value| switch (value) {
                .integer => value.integer,
                else => if (root.get("timestamp")) |root_value| switch (root_value) {
                    .integer => root_value.integer,
                    else => std.time.milliTimestamp(),
                } else std.time.milliTimestamp(),
            } else if (root.get("timestamp")) |value| switch (value) {
                .integer => value.integer,
                else => std.time.milliTimestamp(),
            } else std.time.milliTimestamp();
            const final = if (payload.get("final")) |value| switch (value) {
                .bool => value.bool,
                else => true,
            } else true;

            const content_delta = if (payload.get("content_delta")) |value| switch (value) {
                .string => value.string,
                else => null,
            } else if (root.get("content_delta")) |value| switch (value) {
                .string => value.string,
                else => null,
            } else null;
            if (content_delta) |delta| {
                if (delta.len > 0) {
                    try self.appendOrUpdateStreamingMessage(request_id, session_key, delta, false, timestamp);
                    replayed = true;
                }
            }

            const content = if (payload.get("content")) |value| switch (value) {
                .string => value.string,
                else => "",
            } else if (root.get("content")) |value| switch (value) {
                .string => value.string,
                else => "",
            } else "";
            if (content.len > 0) {
                try self.appendOrUpdateStreamingMessage(request_id, session_key, content, final, timestamp);
                replayed = true;
            }
        }

        return replayed;
    }

    fn extractLatestThoughtFromJobLog(self: *App, log_text: []const u8) !?[]u8 {
        var latest: ?[]u8 = null;
        errdefer if (latest) |value| self.allocator.free(value);

        var lines = std.mem.splitScalar(u8, log_text, '\n');
        while (lines.next()) |line_raw| {
            const line = std.mem.trim(u8, line_raw, " \t\r\n");
            if (line.len == 0 or line[0] != '{') continue;

            var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, line, .{}) catch continue;
            defer parsed.deinit();
            if (parsed.value != .object) continue;
            const root = parsed.value.object;
            const type_val = root.get("type") orelse continue;
            if (type_val != .string or !std.mem.eql(u8, type_val.string, "agent.thought")) continue;
            const content_val = root.get("content") orelse continue;
            if (content_val != .string) continue;
            const thought = std.mem.trim(u8, content_val.string, " \t\r\n");
            if (thought.len == 0) continue;

            if (latest) |value| self.allocator.free(value);
            latest = try self.allocator.dupe(u8, thought);
        }

        return latest;
    }

    fn syncPendingThoughtFromJobLog(self: *App, session_key: []const u8, log_text: []const u8) !void {
        const latest_thought = try self.extractLatestThoughtFromJobLog(log_text);
        defer if (latest_thought) |value| self.allocator.free(value);
        try self.syncPendingThoughtText(session_key, latest_thought);
    }

    fn syncPendingThoughtText(self: *App, session_key: []const u8, latest_thought: ?[]const u8) !void {
        const thought = latest_thought orelse return;

        if (self.pending_send_last_thought_text) |previous| {
            if (std.mem.eql(u8, previous, thought)) return;
            self.allocator.free(previous);
            self.pending_send_last_thought_text = null;
        }
        self.pending_send_last_thought_text = try self.allocator.dupe(u8, thought);

        if (self.pending_send_thought_message_id) |message_id| {
            if (self.findMessageIndex(session_key, message_id)) |idx| {
                try self.setMessageContentByIndex(session_key, idx, thought);
                return;
            }
            self.allocator.free(message_id);
            self.pending_send_thought_message_id = null;
        }

        const appended_id = try self.appendMessageWithIdForSession(session_key, "thought", thought, null, "");
        self.pending_send_thought_message_id = @constCast(appended_id);
    }

    fn tryResumePendingSendJob(self: *App) !bool {
        const job_id = self.pending_send_job_id orelse return false;
        const jobs_root = self.pending_send_jobs_root orelse "/global/jobs";
        const client = if (self.ws_client) |*value| value else return false;
        if (!self.pending_send_resume_notified) return false;
        const session_key = if (self.pending_send_session_key) |value|
            value
        else
            try self.currentSessionOrDefault();

        const now_ms = std.time.milliTimestamp();
        if (self.pending_send_last_resume_attempt_ms != 0 and now_ms - self.pending_send_last_resume_attempt_ms < 1_500) {
            return false;
        }
        self.pending_send_last_resume_attempt_ms = now_ms;
        std.log.info("[GUI] tryResumePendingSendJob: job_id={s}", .{job_id});

        try self.fsrpcBootstrapGui(client);
        var status = try self.readJobStatusGui(client, jobs_root, job_id);
        defer status.deinit(self.allocator);

        const maybe_log = self.readJobArtifactTextGui(client, jobs_root, job_id, "log.txt") catch null;
        defer if (maybe_log) |value| self.allocator.free(value);

        if (self.pending_send_thoughts_root) |thoughts_root| {
            const latest_path = try std.fmt.allocPrint(self.allocator, "{s}/latest.txt", .{thoughts_root});
            defer self.allocator.free(latest_path);
            const latest_thought_text = self.readFsPathTextGui(client, latest_path) catch null;
            defer if (latest_thought_text) |value| self.allocator.free(value);
            if (latest_thought_text) |value| {
                const trimmed = std.mem.trim(u8, value, " \t\r\n");
                try self.syncPendingThoughtText(session_key, if (trimmed.len > 0) trimmed else null);
            } else if (maybe_log) |log_text| {
                try self.syncPendingThoughtFromJobLog(session_key, log_text);
            }
        } else if (maybe_log) |log_text| {
            try self.syncPendingThoughtFromJobLog(session_key, log_text);
        }

        if (maybe_log) |log_text| {
            try self.ingestDebugEventsFromJobLog(log_text);
        }

        if (!std.mem.eql(u8, status.state, "done") and !std.mem.eql(u8, status.state, "failed")) {
            return false;
        }

        const result = self.readJobArtifactTextGui(client, jobs_root, job_id, "result.txt") catch |err| blk: {
            const msg = try std.fmt.allocPrint(self.allocator, "resume read failed: {s}", .{@errorName(err)});
            break :blk msg;
        };
        defer self.allocator.free(result);

        if (std.mem.eql(u8, status.state, "failed")) {
            if (self.pending_send_message_id) |message_id| {
                try self.setMessageFailed(message_id);
            }
            if (status.error_text) |err_text| {
                const msg = try std.fmt.allocPrint(self.allocator, "Job {s} failed: {s}", .{ job_id, err_text });
                defer self.allocator.free(msg);
                try self.appendMessage("system", msg, null);
            } else {
                const msg = try std.fmt.allocPrint(self.allocator, "Job {s} failed: {s}", .{ job_id, result });
                defer self.allocator.free(msg);
                try self.appendMessage("system", msg, null);
            }
            self.clearPendingSend();
            return true;
        }

        if (self.pending_send_message_id) |message_id| {
            try self.setMessageState(message_id, null);
        }
        if (maybe_log) |log_text| {
            const replayed = try self.replaySessionReceiveFromJobLog(session_key, log_text);
            if (!replayed) {
                try self.appendMessageForSession(session_key, "assistant", result, null);
            }
        } else {
            try self.appendMessageForSession(session_key, "assistant", result, null);
        }
        self.clearPendingSend();
        return true;
    }

    fn nextMessageId(self: *App, prefix: []const u8) ![]const u8 {
        self.message_counter += 1;
        return try std.fmt.allocPrint(self.allocator, "{s}-{d}", .{ prefix, self.message_counter });
    }

    fn setPendingSend(
        self: *App,
        allocator: std.mem.Allocator,
        message_id: []const u8,
        session_key: []const u8,
    ) !void {
        if (self.pending_send_request_id) |value| {
            allocator.free(value);
            self.pending_send_request_id = null;
        }
        if (self.pending_send_message_id) |value| allocator.free(value);
        if (self.pending_send_session_key) |value| allocator.free(value);
        if (self.pending_send_job_id) |value| {
            allocator.free(value);
            self.pending_send_job_id = null;
        }
        if (self.pending_send_jobs_root) |value| {
            allocator.free(value);
            self.pending_send_jobs_root = null;
        }
        if (self.pending_send_thoughts_root) |value| {
            allocator.free(value);
            self.pending_send_thoughts_root = null;
        }
        if (self.pending_send_correlation_id) |value| {
            allocator.free(value);
            self.pending_send_correlation_id = null;
        }
        self.clearPendingThoughtMessage();
        if (self.pending_send_last_thought_text) |value| {
            allocator.free(value);
            self.pending_send_last_thought_text = null;
        }
        self.pending_send_message_id = try allocator.dupe(u8, message_id);
        self.pending_send_session_key = try allocator.dupe(u8, session_key);
        self.pending_send_resume_notified = false;
        self.pending_send_last_resume_attempt_ms = 0;
        self.pending_send_started_at_ms = std.time.milliTimestamp();
    }

    fn clearPendingSend(self: *App) void {
        self.clearPendingThoughtMessage();
        if (self.pending_send_request_id) |value| {
            self.allocator.free(value);
            for (self.session_messages.items) |*state| {
                if (state.streaming_request_id) |stream_request_id| {
                    if (std.mem.eql(u8, value, stream_request_id)) {
                        self.clearSessionStreamingState(state);
                    }
                }
            }
            self.pending_send_request_id = null;
        }
        if (self.pending_send_message_id) |value| {
            self.allocator.free(value);
            self.pending_send_message_id = null;
        }
        if (self.pending_send_session_key) |value| {
            self.allocator.free(value);
            self.pending_send_session_key = null;
        }
        if (self.pending_send_job_id) |value| {
            self.allocator.free(value);
            self.pending_send_job_id = null;
        }
        if (self.pending_send_jobs_root) |value| {
            self.allocator.free(value);
            self.pending_send_jobs_root = null;
        }
        if (self.pending_send_thoughts_root) |value| {
            self.allocator.free(value);
            self.pending_send_thoughts_root = null;
        }
        if (self.pending_send_correlation_id) |value| {
            self.allocator.free(value);
            self.pending_send_correlation_id = null;
        }
        self.clearPendingThoughtMessage();
        if (self.pending_send_last_thought_text) |value| {
            self.allocator.free(value);
            self.pending_send_last_thought_text = null;
        }
        self.pending_send_resume_notified = false;
        self.pending_send_last_resume_attempt_ms = 0;
        self.pending_send_started_at_ms = 0;
        self.awaiting_reply = false;
    }

    fn currentSessionOrDefault(self: *App) ![]const u8 {
        self.sanitizeCurrentSessionSelection();

        if (self.current_session_key) |current| {
            if (isValidSessionKeyForAttach(current)) return current;
            try self.ensureSessionExists("main", "Main");
            return self.current_session_key.?;
        }
        if (self.chat_sessions.items.len > 0) {
            const fallback = self.chat_sessions.items[0].key;
            if (isValidSessionKeyForAttach(fallback)) {
                try self.setCurrentSessionKey(fallback);
                return fallback;
            }
        }
        const fallback = "main";
        try self.ensureSessionExists(fallback, fallback);
        return fallback;
    }

    fn activeMessages(self: *App) []const ChatMessage {
        self.sanitizeCurrentSessionSelection();

        if (self.current_session_key) |key| {
            if (self.findSessionMessageState(key)) |state| {
                return state.messages.items;
            }
        }
        if (self.chat_sessions.items.len > 0) {
            if (self.findSessionMessageState(self.chat_sessions.items[0].key)) |state| {
                return state.messages.items;
            }
        }
        return &[_]ChatMessage{};
    }

    fn setMessageFailed(self: *App, message_id: []const u8) !void {
        for (self.session_messages.items) |*state| {
            for (state.messages.items) |*msg| {
                if (std.mem.eql(u8, msg.id, message_id)) {
                    msg.local_state = .failed;
                    return;
                }
            }
        }
    }

    fn setMessageState(self: *App, message_id: []const u8, state: ?ChatMessageState) !void {
        for (self.session_messages.items) |*session_state| {
            for (session_state.messages.items) |*msg| {
                if (std.mem.eql(u8, msg.id, message_id)) {
                    msg.local_state = state;
                    return;
                }
            }
        }
    }

    fn extractRequestId(root: std.json.ObjectMap, payload: ?std.json.ObjectMap) ?[]const u8 {
        if (root.get("request_id")) |value| {
            if (value == .string) return value.string;
        }
        if (payload) |obj| {
            if (obj.get("request_id")) |value| {
                if (value == .string) return value.string;
            }
        }
        if (root.get("request")) |value| {
            if (value == .string) return value.string;
        }
        if (payload) |obj| {
            if (obj.get("request")) |value| {
                if (value == .string) return value.string;
            }
        }
        if (root.get("id")) |value| {
            if (value == .string) return value.string;
        }
        if (payload) |obj| {
            if (obj.get("id")) |value| {
                if (value == .string) return value.string;
            }
        }
        return null;
    }

    fn extractSessionKey(root: std.json.ObjectMap, payload: ?std.json.ObjectMap) ?[]const u8 {
        if (payload) |obj| {
            if (obj.get("session_key")) |value| {
                if (value == .string) return value.string;
            }
        }
        if (root.get("session_key")) |value| {
            if (value == .string) return value.string;
        }
        if (payload) |obj| {
            if (obj.get("sessionKey")) |value| {
                if (value == .string) return value.string;
            }
        }
        if (root.get("sessionKey")) |value| {
            if (value == .string) return value.string;
        }
        return null;
    }

    fn isJsonString(s: []const u8) bool {
        const trimmed = std.mem.trim(u8, s, " \n\r\t");
        if (trimmed.len < 2) return false;
        if (trimmed[0] == '{' and trimmed[trimmed.len - 1] == '}') return true;
        if (trimmed[0] == '[' and trimmed[trimmed.len - 1] == ']') return true;
        return false;
    }

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

    fn hexVal(b: u8) ?u8 {
        if (b >= '0' and b <= '9') return b - '0';
        if (b >= 'a' and b <= 'f') return 10 + (b - 'a');
        if (b >= 'A' and b <= 'F') return 10 + (b - 'A');
        return null;
    }

    fn unescapeJsonStringAlloc(self: *App, s: []const u8) ![]u8 {
        // Allocate worst-case size; we'll slice down at the end
        var out = try self.allocator.alloc(u8, s.len);
        errdefer self.allocator.free(out);

        var j: usize = 0;
        var i: usize = 0;
        while (i < s.len) : (i += 1) {
            const ch = s[i];
            if (ch == '\\' and i + 1 < s.len) {
                const esc = s[i + 1];
                switch (esc) {
                    'n' => {
                        out[j] = '\n';
                        j += 1;
                        i += 1;
                        continue;
                    },
                    'r' => {
                        out[j] = '\r';
                        j += 1;
                        i += 1;
                        continue;
                    },
                    't' => {
                        out[j] = '\t';
                        j += 1;
                        i += 1;
                        continue;
                    },
                    '"' => {
                        out[j] = '"';
                        j += 1;
                        i += 1;
                        continue;
                    },
                    '\\' => {
                        out[j] = '\\';
                        j += 1;
                        i += 1;
                        continue;
                    },
                    'u' => {
                        // Minimal handling: keep as-is if malformed
                        if (i + 5 < s.len) {
                            // Try to parse 4 hex digits and encode as UTF-8
                            const h0 = s[i + 2];
                            const h1 = s[i + 3];
                            const h2 = s[i + 4];
                            const h3 = s[i + 5];
                            const v0 = hexVal(h0) orelse {
                                out[j] = ch;
                                j += 1;
                                continue;
                            };
                            const v1 = hexVal(h1) orelse {
                                out[j] = ch;
                                j += 1;
                                continue;
                            };
                            const v2 = hexVal(h2) orelse {
                                out[j] = ch;
                                j += 1;
                                continue;
                            };
                            const v3 = hexVal(h3) orelse {
                                out[j] = ch;
                                j += 1;
                                continue;
                            };
                            const code_unit: u16 = (@as(u16, v0) << 12) | (@as(u16, v1) << 8) | (@as(u16, v2) << 4) | @as(u16, v3);
                            var buf: [4]u8 = undefined;
                            const wrote = std.unicode.utf8Encode(@as(u21, code_unit), &buf) catch {
                                // Fallback: copy literally
                                out[j] = ch;
                                j += 1;
                                continue;
                            };
                            @memcpy(out[j .. j + wrote], buf[0..wrote]);
                            j += wrote;
                            i += 5; // consumed '\\uXXXX'
                            continue;
                        }
                        // Not enough bytes, just copy
                        out[j] = ch;
                        j += 1;
                        continue;
                    },
                    else => {
                        // Unknown escape; drop backslash and keep char
                        out[j] = esc;
                        j += 1;
                        i += 1;
                        continue;
                    },
                }
            }
            out[j] = ch;
            j += 1;
        }
        return self.allocator.realloc(out, j);
    }

    fn prettifyValue(self: *App, val: std.json.Value) error{OutOfMemory}!std.json.Value {
        switch (val) {
            .string => |s| {
                const s_trimmed = std.mem.trim(u8, s, " \n\r\t");
                if (isJsonString(s_trimmed)) {
                    const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, s_trimmed, .{}) catch null;
                    if (parsed) |p| {
                        defer p.deinit();
                        const cloned = try self.cloneJsonValue(p.value);
                        errdefer self.freePrettifiedValue(cloned);
                        const pretty = try self.prettifyValue(cloned);
                        if (!std.meta.eql(pretty, cloned)) {
                            self.freePrettifiedValue(cloned);
                        }
                        return pretty;
                    }
                }

                if (std.mem.indexOfScalar(u8, s, '\n') != null) {
                    var new_arr = std.json.Array.init(self.allocator);
                    errdefer self.freePrettifiedValue(.{ .array = new_arr });
                    var iter = std.mem.splitScalar(u8, s, '\n');
                    while (iter.next()) |line| {
                        const line_trimmed = std.mem.trimRight(u8, line, "\r");
                        // We must dupe the line because prettifyValue may transform/clone; we own and must free our duplicate
                        const duped_line = try self.allocator.dupe(u8, line_trimmed);
                        defer self.allocator.free(duped_line);
                        const v = try self.prettifyValue(.{ .string = duped_line });
                        // v is now owned. If append fails, we must free v.
                        errdefer self.freePrettifiedValue(v);
                        try new_arr.append(v);
                    }
                    return std.json.Value{ .array = new_arr };
                }

                if (looksLikeEscaped(s)) {
                    const un = self.unescapeJsonStringAlloc(s) catch return try self.cloneJsonValue(val);
                    defer self.allocator.free(un);
                    const v = try self.prettifyValue(.{ .string = un });
                    return v;
                }

                return try self.cloneJsonValue(val);
            },
            .object => |obj| {
                var new_obj = std.json.ObjectMap.init(self.allocator);
                errdefer self.freePrettifiedValue(.{ .object = new_obj });
                var iter = obj.iterator();
                while (iter.next()) |entry| {
                    const k = try self.allocator.dupe(u8, entry.key_ptr.*);
                    errdefer self.allocator.free(k);
                    const v = try self.prettifyValue(entry.value_ptr.*);
                    try new_obj.put(k, v);
                }
                return std.json.Value{ .object = new_obj };
            },
            .array => |arr| {
                var new_arr = std.json.Array.init(self.allocator);
                errdefer self.freePrettifiedValue(.{ .array = new_arr });
                for (arr.items) |v| {
                    try new_arr.append(try self.prettifyValue(v));
                }
                return std.json.Value{ .array = new_arr };
            },
            else => return val, // non-allocated types are safe to return by value
        }
    }

    fn freePrettifiedValue(self: *App, val: std.json.Value) void {
        switch (val) {
            .object => |obj| {
                var mut_obj = obj;
                var it = mut_obj.iterator();
                while (it.next()) |entry| {
                    self.allocator.free(entry.key_ptr.*);
                    self.freePrettifiedValue(entry.value_ptr.*);
                }
                mut_obj.deinit();
            },
            .array => |arr| {
                var mut_arr = arr;
                for (mut_arr.items) |v| {
                    self.freePrettifiedValue(v);
                }
                mut_arr.deinit();
            },
            .string => |s| {
                self.allocator.free(s);
            },
            else => {},
        }
    }

    fn cloneJsonValue(self: *App, val: std.json.Value) error{OutOfMemory}!std.json.Value {
        switch (val) {
            .object => |obj| {
                var new_obj = std.json.ObjectMap.init(self.allocator);
                errdefer {
                    var iter = new_obj.iterator();
                    while (iter.next()) |entry| {
                        self.allocator.free(entry.key_ptr.*);
                        self.freePrettifiedValue(entry.value_ptr.*);
                    }
                    new_obj.deinit();
                }
                var iter = obj.iterator();
                while (iter.next()) |entry| {
                    const key_copy = try self.allocator.dupe(u8, entry.key_ptr.*);
                    errdefer self.allocator.free(key_copy);
                    const value_copy = try self.cloneJsonValue(entry.value_ptr.*);
                    try new_obj.put(key_copy, value_copy);
                }
                return std.json.Value{ .object = new_obj };
            },
            .array => |arr| {
                var new_arr = std.json.Array.init(self.allocator);
                errdefer {
                    for (new_arr.items) |it| {
                        self.freePrettifiedValue(it);
                    }
                    new_arr.deinit();
                }
                for (arr.items) |it| {
                    try new_arr.append(try self.cloneJsonValue(it));
                }
                return std.json.Value{ .array = new_arr };
            },
            .string => |s| {
                const s_copy = try self.allocator.dupe(u8, s);
                return std.json.Value{ .string = s_copy };
            },
            else => return val,
        }
    }

    fn formatDebugPayloadJson(self: *App, payload: std.json.Value) ![]u8 {
        // Keep debug-stream formatting intentionally cheap to avoid UI stalls
        // under high event throughput.
        return std.json.Stringify.valueAlloc(self.allocator, payload, .{ .whitespace = .indent_2 });
    }

    fn recordDecodeError(self: *App, reason: []const u8, msg: []const u8) !void {
        const preview_max: usize = 1024;
        var preview = msg;
        var preview_owned: ?[]u8 = null;
        if (msg.len > preview_max) {
            const suffix = "...(truncated)";
            const total = preview_max + suffix.len;
            const buf = try self.allocator.alloc(u8, total);
            @memcpy(buf[0..preview_max], msg[0..preview_max]);
            @memcpy(buf[preview_max..total], suffix);
            preview_owned = buf;
            preview = buf;
        }
        defer if (preview_owned) |buf| self.allocator.free(buf);

        var obj = std.json.ObjectMap.init(self.allocator);
        errdefer self.freePrettifiedValue(.{ .object = obj });

        const key_error = try self.allocator.dupe(u8, "error");
        errdefer self.allocator.free(key_error);
        const val_error = try self.allocator.dupe(u8, reason);
        errdefer self.allocator.free(val_error);
        try obj.put(key_error, .{ .string = val_error });

        const key_bytes = try self.allocator.dupe(u8, "bytes");
        errdefer self.allocator.free(key_bytes);
        try obj.put(key_bytes, .{ .integer = @intCast(msg.len) });

        const key_preview = try self.allocator.dupe(u8, "preview");
        errdefer self.allocator.free(key_preview);
        const val_preview = try self.allocator.dupe(u8, preview);
        errdefer self.allocator.free(val_preview);
        try obj.put(key_preview, .{ .string = val_preview });

        const value = std.json.Value{ .object = obj };
        defer self.freePrettifiedValue(value);

        const payload_json = std.json.Stringify.valueAlloc(self.allocator, value, .{ .whitespace = .indent_2 }) catch |err| {
            std.log.err("Failed to format decode error payload: {s}", .{@errorName(err)});
            return;
        };
        defer self.allocator.free(payload_json);

        try self.appendDebugEvent(std.time.milliTimestamp(), "decode.error", null, payload_json);
    }

    fn formatDebugEventLine(self: *App, entry: DebugEventEntry) ![]u8 {
        if (std.mem.indexOfScalar(u8, entry.payload_json, '\n') == null) {
            return std.fmt.allocPrint(
                self.allocator,
                "{d} {s} {s}",
                .{ entry.timestamp_ms, entry.category, entry.payload_json },
            );
        }

        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(self.allocator);
        try out.writer(self.allocator).print("{d} {s}\n", .{ entry.timestamp_ms, entry.category });
        var iter = std.mem.splitScalar(u8, entry.payload_json, '\n');
        while (iter.next()) |line| {
            try out.writer(self.allocator).print("  {s}\n", .{line});
        }
        if (out.items.len > 0 and out.items[out.items.len - 1] == '\n') {
            _ = out.pop();
        }
        return out.toOwnedSlice(self.allocator);
    }

    fn lineStartsWithJsonClose(trimmed_line: []const u8) bool {
        if (trimmed_line.len == 0) return false;
        return trimmed_line[0] == '}' or trimmed_line[0] == ']';
    }

    fn lineEndsWithJsonOpen(trimmed_line: []const u8) bool {
        if (trimmed_line.len == 0) return false;
        var end = trimmed_line.len;
        while (end > 0 and trimmed_line[end - 1] == ',') : (end -= 1) {}
        if (end == 0) return false;
        const ch = trimmed_line[end - 1];
        return ch == '{' or ch == '[';
    }

    fn buildDebugPayloadLines(self: *App, payload_json: []const u8) !std.ArrayList(DebugPayloadLine) {
        var lines: std.ArrayList(DebugPayloadLine) = .empty;
        errdefer lines.deinit(self.allocator);

        var open_stack: std.ArrayList(usize) = .empty;
        defer open_stack.deinit(self.allocator);

        var line_start: usize = 0;
        while (true) {
            const maybe_nl = std.mem.indexOfScalarPos(u8, payload_json, line_start, '\n');
            const line_end = maybe_nl orelse payload_json.len;
            const line = payload_json[line_start..line_end];

            var indent_spaces: usize = 0;
            while (indent_spaces < line.len and line[indent_spaces] == ' ') : (indent_spaces += 1) {}

            const trimmed = std.mem.trim(u8, line, " \t\r");
            const is_close_line = lineStartsWithJsonClose(trimmed);
            const is_open_line = lineEndsWithJsonOpen(trimmed);

            const current_line_index = lines.items.len;
            try lines.append(self.allocator, .{
                .start = line_start,
                .end = line_end,
                .indent_spaces = indent_spaces,
                .opens_block = is_open_line,
            });

            if (is_close_line and open_stack.items.len > 0) {
                const open_line_index = open_stack.items[open_stack.items.len - 1];
                open_stack.items.len -= 1;
                lines.items[open_line_index].matching_close_index = @intCast(current_line_index);
            }

            if (is_open_line) {
                try open_stack.append(self.allocator, current_line_index);
            }

            if (maybe_nl == null) break;
            line_start = line_end + 1;
        }

        return lines;
    }

    fn handleDebugEventMessage(self: *App, root: std.json.ObjectMap) !void {
        const timestamp = if (root.get("timestamp")) |value| switch (value) {
            .integer => value.integer,
            else => std.time.milliTimestamp(),
        } else std.time.milliTimestamp();
        const category = if (root.get("category")) |value| switch (value) {
            .string => value.string,
            else => "unknown",
        } else "unknown";

        // Render payload directly to keep debug streaming resilient for large/complex payloads.
        const payload_json = if (root.get("payload")) |payload| blk: {
            if (self.formatDebugPayloadJson(payload)) |pretty| break :blk pretty else |_| {
                break :blk try self.allocator.dupe(u8, "{\"error\":\"failed to format debug payload\"}");
            }
        } else try self.allocator.dupe(u8, "{}");
        defer self.allocator.free(payload_json);

        const payload_obj = if (root.get("payload")) |payload| switch (payload) {
            .object => payload.object,
            else => null,
        } else null;
        const correlation_id = extractCorrelationId(root, payload_obj);
        try self.appendDebugEvent(timestamp, category, correlation_id, payload_json);
    }

    fn handleNodeServiceEventMessage(self: *App, root: std.json.ObjectMap) !void {
        const timestamp = if (root.get("timestamp")) |value| switch (value) {
            .integer => value.integer,
            else => std.time.milliTimestamp(),
        } else if (root.get("timestamp_ms")) |value| switch (value) {
            .integer => value.integer,
            else => std.time.milliTimestamp(),
        } else std.time.milliTimestamp();

        const payload_value = root.get("payload") orelse {
            try self.appendDebugEvent(timestamp, "control.node_service_event", null, "{}");
            return;
        };
        const payload_json = if (self.formatDebugPayloadJson(payload_value)) |pretty|
            pretty
        else |_|
            try self.allocator.dupe(u8, "{\"error\":\"failed to format node service payload\"}");
        defer self.allocator.free(payload_json);

        const payload_obj = if (payload_value == .object) payload_value.object else null;
        const correlation_id = extractCorrelationId(root, payload_obj);
        try self.appendDebugEvent(timestamp, "control.node_service_event", correlation_id, payload_json);

        if (try self.buildNodeServiceDeltaDiagnosticsTextFromValue(payload_value)) |diag| {
            self.clearNodeServiceReloadDiagnostics();
            self.node_service_latest_reload_diag = diag;
        }
    }

    fn handleIncomingMessage(self: *App, msg: []const u8) !void {
        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, msg, .{}) catch |err| {
            self.recordDecodeError(@errorName(err), msg) catch {};
            return;
        };
        defer parsed.deinit();
        if (parsed.value != .object) {
            self.recordDecodeError("non-object json", msg) catch {};
            return;
        }
        const root = parsed.value.object;

        const mt = if (root.get("type")) |type_value| switch (type_value) {
            .string => protocol_messages.classifyTypeString(type_value.string),
            else => protocol_messages.parseMessageType(msg) orelse return,
        } else protocol_messages.parseMessageType(msg) orelse return;
        switch (mt) {
            .session_receive => {
                const payload = if (root.get("payload")) |payload| switch (payload) {
                    .object => payload.object,
                    else => root,
                } else root;

                const request_id = if (root.get("request_id")) |value| switch (value) {
                    .string => value.string,
                    else => null,
                } else if (payload.get("request_id")) |value| switch (value) {
                    .string => value.string,
                    else => null,
                } else if (root.get("request")) |value| switch (value) {
                    .string => value.string,
                    else => null,
                } else if (payload.get("request")) |value| switch (value) {
                    .string => value.string,
                    else => null,
                } else if (root.get("id")) |value| switch (value) {
                    .string => value.string,
                    else => null,
                } else if (payload.get("id")) |value| switch (value) {
                    .string => value.string,
                    else => null,
                } else null;
                const session_key = if (payload.get("session_key")) |value| switch (value) {
                    .string => value.string,
                    else => null,
                } else if (root.get("session_key")) |value| switch (value) {
                    .string => value.string,
                    else => null,
                } else if (payload.get("sessionKey")) |value| switch (value) {
                    .string => value.string,
                    else => null,
                } else if (root.get("sessionKey")) |value| switch (value) {
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
                const timestamp = if (root.get("timestamp")) |value| switch (value) {
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
                    if (self.pending_send_request_id) |pending| {
                        if (std.mem.eql(u8, pending, req_id)) {
                            if (self.pending_send_message_id) |msg_id| {
                                self.setMessageState(msg_id, null) catch {};
                            }
                            if (session_key) |sk| {
                                if (self.current_session_key) |current| {
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
                    try self.appendOrUpdateStreamingMessage(request_id, session_key, delta, false, timestamp);
                    return;
                }
                if (content.len > 0) {
                    if (request_id != null) {
                        const is_final = final;
                        try self.appendOrUpdateStreamingMessage(request_id, session_key, content, is_final, timestamp);
                    } else {
                        try self.appendMessageWithState(role, content, null, null);
                    }
                }
            },
            .connect_ack => {
                const request_id = if (root.get("request_id")) |value| switch (value) {
                    .string => value.string,
                    else => null,
                } else if (root.get("request")) |value| switch (value) {
                    .string => value.string,
                    else => null,
                } else if (root.get("id")) |value| switch (value) {
                    .string => value.string,
                    else => null,
                } else null;

                if (request_id) |rid| {
                    if (self.pending_send_request_id) |pending| {
                        if (std.mem.eql(u8, pending, rid)) {
                            if (self.pending_send_message_id) |message_id| {
                                self.setMessageState(message_id, null) catch {};
                            }
                            self.clearPendingSend();
                        }
                    }
                }
            },
            .error_response => {
                const payload = if (root.get("payload")) |payload| switch (payload) {
                    .object => payload.object,
                    else => root,
                } else root;
                const err_message = if (payload.get("message")) |value| switch (value) {
                    .string => value.string,
                    else => "Unknown error",
                } else if (root.get("error")) |value| switch (value) {
                    .object => if (value.object.get("message")) |err_msg| switch (err_msg) {
                        .string => err_msg.string,
                        else => "Unknown error",
                    } else "Unknown error",
                    else => "Unknown error",
                } else "Unknown error";
                const err_code = if (payload.get("code")) |value| switch (value) {
                    .string => value.string,
                    else => null,
                } else if (root.get("error")) |value| switch (value) {
                    .object => if (value.object.get("code")) |err_code_value| switch (err_code_value) {
                        .string => err_code_value.string,
                        else => null,
                    } else null,
                    else => null,
                } else null;
                if (extractRequestId(root, payload)) |request_id| {
                    if (self.pending_send_request_id) |pending| {
                        if (std.mem.eql(u8, pending, request_id)) {
                            if (self.pending_send_message_id) |message_id| {
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
                try self.appendMessage("system", detail, null);
            },
            else => {
                if (self.connection_state == .connected) {
                    return;
                }
                try self.appendMessage("system", "Unhandled message", null);
            },
        }
    }

    fn appendOrUpdateStreamingMessage(
        self: *App,
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
            if (self.pending_send_request_id) |pending| {
                if (std.mem.eql(u8, pending, request)) {
                    if (self.pending_send_session_key) |key| break :blk key;
                }
            }
            break :blk session_key_opt;
        } else session_key_opt;

        const target = target_session orelse try self.currentSessionOrDefault();

        if (request_id) |request| {
            const state = try self.getSessionMessageState(target);

            if (state.streaming_request_id) |existing_request| {
                if (!std.mem.eql(u8, existing_request, request)) {
                    self.clearSessionStreamingState(state);
                }
            }

            if (state.streaming_request_id == null) {
                try self.setSessionStreamingRequest(state, request);
            }

            const stream_id = try self.makeStreamingMessageId(request);
            defer self.allocator.free(stream_id);

            if (self.findMessageIndex(target, stream_id)) |idx| {
                if (final) {
                    try self.setMessageContentByIndex(target, idx, use);
                } else {
                    try self.appendToMessage(target, idx, use);
                }
                if (state.messages.items.len > idx) {
                    state.messages.items[idx].timestamp = timestamp;
                }
            } else {
                const new_id = try self.appendMessageWithIdForSession(target, "assistant", use, null, stream_id);
                self.allocator.free(new_id);
            }

            if (self.pending_send_request_id) |pending| {
                if (std.mem.eql(u8, pending, request)) {
                    if (self.pending_send_message_id) |msg_id| {
                        self.setMessageState(msg_id, null) catch {};
                    }
                    if (final) {
                        self.clearSessionStreamingState(state);
                        self.clearPendingSend();
                    }
                }
            }

            if (final) {
                self.clearSessionStreamingState(state);
            }
            return;
        }

        try self.appendMessageForSession(target, "assistant", use, null);
    }

    fn findSessionMessageState(self: *App, key: []const u8) ?*SessionMessageState {
        for (self.session_messages.items) |*state| {
            if (std.mem.eql(u8, state.key, key)) return state;
        }
        return null;
    }

    fn getSessionMessageState(self: *App, key: []const u8) !*SessionMessageState {
        if (self.findSessionMessageState(key)) |state| return state;
        const key_copy = try self.allocator.dupe(u8, key);
        try self.session_messages.append(self.allocator, .{
            .key = key_copy,
            .messages = .empty,
        });
        return &self.session_messages.items[self.session_messages.items.len - 1];
    }

    fn makeStreamingMessageId(self: *App, request_id: []const u8) ![]const u8 {
        return std.fmt.allocPrint(self.allocator, "stream:{s}", .{request_id});
    }

    fn setSessionStreamingRequest(self: *App, state: *SessionMessageState, request_id: []const u8) !void {
        if (state.streaming_request_id) |existing_request| {
            if (std.mem.eql(u8, existing_request, request_id)) {
                return;
            }
            self.allocator.free(existing_request);
        }
        state.streaming_request_id = try self.allocator.dupe(u8, request_id);
    }

    fn clearSessionStreamingState(self: *App, state: *SessionMessageState) void {
        if (state.streaming_request_id) |existing_request| {
            self.allocator.free(existing_request);
            state.streaming_request_id = null;
        }
    }

    fn setMessageContentByIndex(self: *App, session_key: []const u8, index: usize, content: []const u8) !void {
        const state = try self.getSessionMessageState(session_key);
        if (index >= state.messages.items.len) return;
        const msg = &state.messages.items[index];
        self.allocator.free(msg.content);
        msg.content = try self.allocator.dupe(u8, content);
    }

    fn appendToMessage(self: *App, session_key: []const u8, index: usize, content: []const u8) !void {
        const state = try self.getSessionMessageState(session_key);
        var msg = &state.messages.items[index];
        const old_content = msg.content;
        const new_len = old_content.len + content.len;
        var combined = try self.allocator.alloc(u8, new_len);
        @memcpy(combined[0..old_content.len], old_content);
        @memcpy(combined[old_content.len..new_len], content);
        msg.content = combined;
        self.allocator.free(old_content);
    }

    fn findMessageIndex(self: *App, session_key: []const u8, message_id: []const u8) ?usize {
        const state = self.findSessionMessageState(session_key) orelse return null;
        for (state.messages.items, 0..) |*msg, idx| {
            if (std.mem.eql(u8, msg.id, message_id)) return idx;
        }
        return null;
    }

    fn removeMessageById(self: *App, session_key: []const u8, message_id: []const u8) void {
        const state = self.findSessionMessageState(session_key) orelse return;
        const idx = self.findMessageIndex(session_key, message_id) orelse return;
        var removed = state.messages.orderedRemove(idx);
        self.freeMessage(&removed);
    }

    fn clearPendingThoughtMessage(self: *App) void {
        if (self.pending_send_thought_message_id) |message_id| {
            if (self.pending_send_session_key) |session_key| {
                self.removeMessageById(session_key, message_id);
            }
            self.allocator.free(message_id);
            self.pending_send_thought_message_id = null;
        }
    }

    fn appendMessage(self: *App, role: []const u8, content: []const u8, local_state: ?ChatMessageState) !void {
        const session_key = try self.currentSessionOrDefault();
        const id = try self.appendMessageWithIdForSession(session_key, role, content, local_state, "");
        self.allocator.free(id);
    }

    fn appendMessageForSession(
        self: *App,
        session_key: []const u8,
        role: []const u8,
        content: []const u8,
        local_state: ?ChatMessageState,
    ) !void {
        const id = try self.appendMessageWithIdForSession(session_key, role, content, local_state, "");
        self.allocator.free(id);
    }

    fn appendMessageWithId(
        self: *App,
        role: []const u8,
        content: []const u8,
        local_state: ?ChatMessageState,
        id_override: []const u8,
    ) ![]const u8 {
        const session_key = try self.currentSessionOrDefault();
        return self.appendMessageWithIdForSession(session_key, role, content, local_state, id_override);
    }

    fn appendMessageWithIdForSession(
        self: *App,
        session_key: []const u8,
        role: []const u8,
        content: []const u8,
        local_state: ?ChatMessageState,
        id_override: []const u8,
    ) ![]const u8 {
        const id = if (id_override.len > 0) try self.allocator.dupe(u8, id_override) else try self.nextMessageId("msg");
        errdefer self.allocator.free(id);

        const state = try self.getSessionMessageState(session_key);
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
            if (self.pending_send_message_id) |pending_message_id| {
                if (std.mem.eql(u8, pending_message_id, oldest.id)) {
                    self.allocator.free(pending_message_id);
                    self.pending_send_message_id = null;
                }
            }
            self.freeMessage(&oldest);
        }

        return id;
    }

    fn appendMessageWithState(
        self: *App,
        role: []const u8,
        content: []const u8,
        local_state: ?ChatMessageState,
        id_override: ?[]const u8,
    ) !void {
        if (id_override) |id| {
            const id_out = try self.appendMessageWithId(role, content, local_state, id);
            self.allocator.free(id_out);
            return;
        }
        return self.appendMessage(role, content, local_state);
    }

    fn freeMessage(self: *App, msg: *ChatMessage) void {
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

    fn clearAllMessages(self: *App) void {
        for (self.session_messages.items) |*state| {
            self.clearSessionStreamingState(state);
            for (state.messages.items) |*msg| {
                self.freeMessage(msg);
            }
            state.messages.clearRetainingCapacity();
        }
    }

    fn clearSessions(self: *App) void {
        self.clearAllMessages();

        if (self.current_session_key) |current_session| {
            self.allocator.free(current_session);
            self.current_session_key = null;
        }
        for (self.chat_sessions.items) |session| {
            self.allocator.free(session.key);
            if (session.display_name) |name| self.allocator.free(name);
        }
        self.chat_sessions.clearRetainingCapacity();

        for (self.session_messages.items) |*state| {
            state.messages.deinit(self.allocator);
            self.allocator.free(state.key);
            if (state.streaming_request_id) |rid| self.allocator.free(rid);
        }
        self.session_messages.clearRetainingCapacity();
    }

    fn clearDebugEvents(self: *App) void {
        for (self.debug_events.items) |*entry| {
            entry.deinit(self.allocator);
        }
        self.debug_events.clearRetainingCapacity();
        self.debug_folded_blocks.clearRetainingCapacity();
        self.debug_event_fingerprint_set.clearRetainingCapacity();
        self.debug_event_fingerprint_count = 0;
        self.debug_event_fingerprint_next = 0;
        self.debug_fold_revision +%= 1;
        if (self.debug_fold_revision == 0) self.debug_fold_revision = 1;
        self.debug_next_event_id = 1;
        self.debug_selected_index = null;
        self.clearSelectedNodeServiceEventCache();
        self.node_service_diff_base_index = null;
        self.clearNodeServiceReloadDiagnostics();
        self.clearNodeServiceDiffPreview();
        self.bumpDebugEventsRevision();
    }

    fn bumpDebugEventsRevision(self: *App) void {
        self.debug_events_revision +%= 1;
        if (self.debug_events_revision == 0) self.debug_events_revision = 1;
        self.debug_filter_cache_valid = false;
    }

    fn clearDebugStreamSnapshot(self: *App) void {
        if (self.debug_stream_snapshot) |value| {
            self.allocator.free(value);
            self.debug_stream_snapshot = null;
        }
    }

    fn mergeDebugStreamSnapshot(self: *App, content: []const u8) !void {
        if (self.debug_stream_snapshot) |previous| {
            if (content.len >= previous.len and std.mem.startsWith(u8, content, previous)) {
                try self.ingestDebugStreamLines(content[previous.len..]);
            } else {
                self.clearDebugEvents();
                try self.ingestDebugStreamLines(content);
            }
        } else {
            self.clearDebugEvents();
            try self.ingestDebugStreamLines(content);
        }

        const snapshot_copy = try self.allocator.dupe(u8, content);
        if (self.debug_stream_snapshot) |previous| self.allocator.free(previous);
        self.debug_stream_snapshot = snapshot_copy;
    }

    fn ingestDebugStreamLines(self: *App, chunk: []const u8) !void {
        var iter = std.mem.splitScalar(u8, chunk, '\n');
        while (iter.next()) |raw_line| {
            const line = std.mem.trim(u8, raw_line, " \t\r\n");
            if (line.len == 0) continue;
            try self.ingestDebugStreamLine(line);
        }
    }

    fn ingestDebugEventsFromJobLog(self: *App, log_text: []const u8) !void {
        var iter = std.mem.splitScalar(u8, log_text, '\n');
        while (iter.next()) |raw_line| {
            const line = std.mem.trim(u8, raw_line, " \t\r\n");
            if (line.len == 0 or line[0] != '{') continue;
            try self.ingestDebugStreamLine(line);
        }
    }

    fn ingestDebugStreamLine(self: *App, line: []const u8) !void {
        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, line, .{}) catch return;
        defer parsed.deinit();
        if (parsed.value != .object) return;
        const root = parsed.value.object;
        const type_value = root.get("type") orelse return;
        if (type_value != .string or !std.mem.eql(u8, type_value.string, "debug.event")) return;
        try self.handleDebugEventMessage(root);
    }

    fn ingestNodeServiceSnapshotLines(self: *App, chunk: []const u8) !void {
        var matching_lines: std.ArrayListUnmanaged([]const u8) = .{};
        defer matching_lines.deinit(self.allocator);

        const node_filter = std.mem.trim(u8, self.node_service_watch_filter.items, " \t\r\n");
        var iter = std.mem.splitScalar(u8, chunk, '\n');
        while (iter.next()) |raw_line| {
            const line = std.mem.trim(u8, raw_line, " \t\r\n");
            if (line.len == 0) continue;
            if (!try self.nodeServiceSnapshotLineMatchesFilter(line, node_filter)) continue;
            try matching_lines.append(self.allocator, line);
        }

        const replay_limit = self.parseNodeServiceWatchReplayLimit();
        const start_index = if (replay_limit > 0 and matching_lines.items.len > replay_limit)
            matching_lines.items.len - replay_limit
        else
            0;
        for (matching_lines.items[start_index..]) |line| {
            try self.ingestNodeServiceSnapshotLine(line);
        }
    }

    fn nodeServiceSnapshotLineMatchesFilter(
        self: *App,
        line: []const u8,
        node_filter: []const u8,
    ) !bool {
        if (node_filter.len == 0) return true;

        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, line, .{}) catch return false;
        defer parsed.deinit();
        if (parsed.value != .object) return false;
        const root = parsed.value.object;
        const node_id_value = root.get("node_id") orelse return false;
        if (node_id_value != .string) return false;
        return std.mem.eql(u8, node_id_value.string, node_filter);
    }

    fn ingestNodeServiceSnapshotLine(self: *App, line: []const u8) !void {
        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, line, .{}) catch return;
        defer parsed.deinit();
        if (parsed.value != .object) return;
        try self.handleNodeServiceEventMessage(parsed.value.object);
    }

    fn clearNodeServiceReloadDiagnostics(self: *App) void {
        if (self.node_service_latest_reload_diag) |value| {
            self.allocator.free(value);
            self.node_service_latest_reload_diag = null;
        }
    }

    fn clearNodeServiceDiffPreview(self: *App) void {
        if (self.node_service_diff_preview) |value| {
            self.allocator.free(value);
            self.node_service_diff_preview = null;
        }
    }

    fn debugEventFingerprint(
        timestamp_ms: i64,
        category: []const u8,
        correlation_id: ?[]const u8,
        payload_json: []const u8,
    ) u64 {
        var hasher = std.hash.Wyhash.init(0);
        hasher.update(std.mem.asBytes(&timestamp_ms));
        hasher.update(category);
        if (correlation_id) |value| {
            hasher.update(&[_]u8{0});
            hasher.update(value);
        } else {
            hasher.update(&[_]u8{1});
        }
        hasher.update(payload_json);
        return hasher.final();
    }

    fn rememberDebugEventFingerprint(self: *App, fingerprint: u64) bool {
        if (self.debug_event_fingerprint_set.contains(fingerprint)) {
            return false;
        }

        if (self.debug_event_fingerprint_count == DEBUG_EVENT_DEDUPE_WINDOW) {
            const evicted = self.debug_event_fingerprint_ring[self.debug_event_fingerprint_next];
            _ = self.debug_event_fingerprint_set.remove(evicted);
        } else {
            self.debug_event_fingerprint_count += 1;
        }

        self.debug_event_fingerprint_ring[self.debug_event_fingerprint_next] = fingerprint;
        self.debug_event_fingerprint_next = (self.debug_event_fingerprint_next + 1) % DEBUG_EVENT_DEDUPE_WINDOW;
        self.debug_event_fingerprint_set.put(self.allocator, fingerprint, {}) catch {
            return true;
        };
        return true;
    }

    fn appendDebugEvent(self: *App, timestamp_ms: i64, category: []const u8, correlation_id: ?[]const u8, payload_json: []const u8) !void {
        const fingerprint = debugEventFingerprint(timestamp_ms, category, correlation_id, payload_json);
        if (!self.rememberDebugEventFingerprint(fingerprint)) return;

        while (self.debug_events.items.len >= MAX_DEBUG_EVENTS) {
            var removed = self.debug_events.orderedRemove(0);
            self.pruneDebugFoldStateForEvent(removed.id);
            removed.deinit(self.allocator);
            if (self.node_service_diff_base_index) |idx| {
                if (idx == 0) {
                    self.node_service_diff_base_index = null;
                    self.clearNodeServiceDiffPreview();
                } else {
                    self.node_service_diff_base_index = idx - 1;
                }
            }
            if (self.debug_selected_index) |idx| {
                if (idx == 0) {
                    self.debug_selected_index = null;
                    self.clearSelectedNodeServiceEventCache();
                } else {
                    self.debug_selected_index = idx - 1;
                    self.clearSelectedNodeServiceEventCache();
                }
            }
        }

        const category_copy = try self.allocator.dupe(u8, category);
        errdefer self.allocator.free(category_copy);
        const correlation_copy = if (correlation_id) |value|
            try self.allocator.dupe(u8, value)
        else
            null;
        errdefer if (correlation_copy) |value| self.allocator.free(value);
        const payload_copy = try self.allocator.dupe(u8, payload_json);
        errdefer self.allocator.free(payload_copy);

        const event_id = self.debug_next_event_id;
        self.debug_next_event_id +%= 1;
        if (self.debug_next_event_id == 0) self.debug_next_event_id = 1;

        try self.debug_events.append(self.allocator, .{
            .id = event_id,
            .timestamp_ms = timestamp_ms,
            .category = category_copy,
            .correlation_id = correlation_copy,
            .payload_json = payload_copy,
        });
        self.bumpDebugEventsRevision();
    }

    fn ensureDebugFilteredIndices(self: *App, filter_text: []const u8) []const u32 {
        const query_hash = std.hash.Wyhash.hash(0, filter_text);
        if (self.debug_filter_cache_valid and
            self.debug_filter_cache_query_hash == query_hash and
            self.debug_filter_cache_query_len == filter_text.len and
            self.debug_filter_cache_events_revision == self.debug_events_revision)
        {
            return self.debug_filtered_indices.items;
        }

        self.debug_filtered_indices.clearRetainingCapacity();
        self.debug_filtered_indices.ensureTotalCapacity(self.allocator, self.debug_events.items.len) catch {
            self.debug_filter_cache_valid = false;
            return self.debug_filtered_indices.items;
        };

        if (filter_text.len == 0) {
            for (self.debug_events.items, 0..) |_, idx| {
                const value: u32 = @intCast(idx);
                self.debug_filtered_indices.appendAssumeCapacity(value);
            }
        } else {
            for (self.debug_events.items, 0..) |*entry, idx| {
                if (!self.debugEventMatchesFilter(entry, filter_text)) continue;
                const value: u32 = @intCast(idx);
                self.debug_filtered_indices.appendAssumeCapacity(value);
            }
        }

        self.debug_filter_cache_query_hash = query_hash;
        self.debug_filter_cache_query_len = filter_text.len;
        self.debug_filter_cache_events_revision = self.debug_events_revision;
        self.debug_filter_cache_valid = true;
        return self.debug_filtered_indices.items;
    }

    fn debugEventMatchesFilter(self: *App, entry: *const DebugEventEntry, filter_text: []const u8) bool {
        _ = self;
        if (filter_text.len == 0) return true;
        if (std.ascii.indexOfIgnoreCase(entry.category, filter_text) != null) return true;
        if (entry.correlation_id) |value| {
            if (std.ascii.indexOfIgnoreCase(value, filter_text) != null) return true;
        }
        return std.ascii.indexOfIgnoreCase(entry.payload_json, filter_text) != null;
    }

    fn countDebugEventsMatchingFilter(self: *App, filter_text: []const u8) usize {
        if (filter_text.len == 0) return self.debug_events.items.len;
        var total: usize = 0;
        for (self.debug_events.items) |*entry| {
            if (self.debugEventMatchesFilter(entry, filter_text)) total += 1;
        }
        return total;
    }

    fn ensureDebugPanel(self: *App, manager: *panel_manager.PanelManager) !workspace.PanelId {
        if (self.debug_panel_id) |panel_id| {
            if (self.findPanelById(manager, panel_id) != null) {
                manager.focusPanel(panel_id);
                self.requestDebugStreamSnapshot(true);
                return panel_id;
            }
            self.debug_panel_id = null;
        }

        for (manager.workspace.panels.items) |*panel| {
            if (panel.kind == .DebugStream) {
                self.debug_panel_id = panel.id;
                manager.focusPanel(panel.id);
                self.requestDebugStreamSnapshot(true);
                return panel.id;
            }
            if (panel.kind == .ToolOutput and std.mem.eql(u8, panel.title, "Debug Stream")) {
                self.promoteLegacyHostPanel(manager, panel);
                self.debug_panel_id = panel.id;
                manager.focusPanel(panel.id);
                self.requestDebugStreamSnapshot(true);
                return panel.id;
            }
        }

        const panel_data = workspace.PanelData{ .DebugStream = {} };
        const panel_id = try manager.openPanel(.DebugStream, "Debug Stream", panel_data);
        self.debug_panel_id = panel_id;
        if (manager.workspace.syncDockLayout() catch false) {
            manager.workspace.markDirty();
        }
        manager.focusPanel(panel_id);
        self.requestDebugStreamSnapshot(true);
        return panel_id;
    }

    fn ensureProjectPanel(self: *App, manager: *panel_manager.PanelManager) !workspace.PanelId {
        if (self.project_panel_id) |panel_id| {
            if (self.findPanelById(manager, panel_id) != null) {
                manager.focusPanel(panel_id);
                return panel_id;
            }
            self.project_panel_id = null;
        }

        for (manager.workspace.panels.items) |*panel| {
            if (panel.kind == .ProjectWorkspace) {
                self.project_panel_id = panel.id;
                manager.focusPanel(panel.id);
                return panel.id;
            }
            if (panel.kind == .ToolOutput and std.mem.eql(u8, panel.title, "Projects")) {
                self.promoteLegacyHostPanel(manager, panel);
                self.project_panel_id = panel.id;
                manager.focusPanel(panel.id);
                return panel.id;
            }
        }

        const panel_data = workspace.PanelData{ .ProjectWorkspace = {} };
        const panel_id = try manager.openPanel(.ProjectWorkspace, "Projects", panel_data);
        self.project_panel_id = panel_id;
        if (manager.workspace.syncDockLayout() catch false) {
            manager.workspace.markDirty();
        }
        manager.focusPanel(panel_id);
        return panel_id;
    }

    fn removeWorkspaceSettingsPanels(self: *App, manager: *panel_manager.PanelManager) void {
        var removed_any = false;
        var idx: usize = 0;
        while (idx < manager.workspace.panels.items.len) {
            const panel = manager.workspace.panels.items[idx];
            if (panel.kind != .Settings and panel.kind != .Control) {
                idx += 1;
                continue;
            }

            var removed_panel = manager.workspace.panels.swapRemove(idx);
            removed_panel.deinit(self.allocator);
            removed_any = true;
        }
        if (removed_any) {
            _ = manager.workspace.syncDockLayout() catch false;
            manager.workspace.markDirty();
        }
    }

    fn ensureFilesystemPanel(self: *App, manager: *panel_manager.PanelManager) !workspace.PanelId {
        if (self.filesystem_panel_id) |panel_id| {
            if (self.findPanelById(manager, panel_id) != null) {
                manager.focusPanel(panel_id);
                if (self.filesystem_entries.items.len == 0 and self.filesystem_active_request == null and self.filesystem_pending_path == null) {
                    self.requestFilesystemBrowserRefresh(true);
                }
                return panel_id;
            }
            self.filesystem_panel_id = null;
        }

        for (manager.workspace.panels.items) |*panel| {
            if (panel.kind == .FilesystemBrowser) {
                self.filesystem_panel_id = panel.id;
                manager.focusPanel(panel.id);
                return panel.id;
            }
            if (panel.kind == .ToolOutput and std.mem.eql(u8, panel.title, "Filesystem Browser")) {
                self.promoteLegacyHostPanel(manager, panel);
                self.filesystem_panel_id = panel.id;
                manager.focusPanel(panel.id);
                return panel.id;
            }
        }

        const panel_data = workspace.PanelData{ .FilesystemBrowser = {} };
        const panel_id = try manager.openPanel(.FilesystemBrowser, "Filesystem Browser", panel_data);
        self.filesystem_panel_id = panel_id;
        if (manager.workspace.syncDockLayout() catch false) {
            manager.workspace.markDirty();
        }
        _ = self.ensureFilesystemToolsPanel(manager) catch null;
        manager.focusPanel(panel_id);
        self.requestFilesystemBrowserRefresh(true);
        self.refreshContractServices() catch {};
        return panel_id;
    }

    fn ensureFilesystemToolsPanel(self: *App, manager: *panel_manager.PanelManager) !workspace.PanelId {
        if (self.filesystem_tools_panel_id) |panel_id| {
            if (self.findPanelById(manager, panel_id) != null) {
                manager.focusPanel(panel_id);
                return panel_id;
            }
            self.filesystem_tools_panel_id = null;
        }

        for (manager.workspace.panels.items) |*panel| {
            if (panel.kind == .FilesystemTools) {
                self.filesystem_tools_panel_id = panel.id;
                manager.focusPanel(panel.id);
                return panel.id;
            }
            if (panel.kind == .ToolOutput and std.mem.eql(u8, panel.title, "Filesystem Tools")) {
                self.promoteLegacyHostPanel(manager, panel);
                self.filesystem_tools_panel_id = panel.id;
                manager.focusPanel(panel.id);
                return panel.id;
            }
        }

        const panel_data = workspace.PanelData{ .FilesystemTools = {} };
        const panel_id = try manager.openPanel(.FilesystemTools, "Filesystem Tools", panel_data);
        self.filesystem_tools_panel_id = panel_id;
        if (manager.workspace.syncDockLayout() catch false) {
            manager.workspace.markDirty();
        }
        manager.focusPanel(panel_id);
        self.refreshContractServices() catch {};
        return panel_id;
    }

    fn ensureTerminalPanel(self: *App, manager: *panel_manager.PanelManager) !workspace.PanelId {
        if (self.terminal_panel_id) |panel_id| {
            if (self.findPanelById(manager, panel_id) != null) {
                manager.focusPanel(panel_id);
                return panel_id;
            }
            self.terminal_panel_id = null;
        }

        for (manager.workspace.panels.items) |*panel| {
            if (panel.kind == .ToolOutput and std.mem.eql(u8, panel.title, "Terminal")) {
                self.terminal_panel_id = panel.id;
                manager.focusPanel(panel.id);
                return panel.id;
            }
        }

        const tool_name = try self.allocator.dupe(u8, "Acheron Terminal");
        errdefer self.allocator.free(tool_name);
        var stdout_buf = try text_buffer.TextBuffer.init(self.allocator, "");
        errdefer stdout_buf.deinit(self.allocator);
        var stderr_buf = try text_buffer.TextBuffer.init(self.allocator, "");
        errdefer stderr_buf.deinit(self.allocator);
        const panel_data = workspace.PanelData{ .ToolOutput = .{
            .tool_name = tool_name,
            .stdout = stdout_buf,
            .stderr = stderr_buf,
            .exit_code = 0,
        } };
        const panel_id = try manager.openPanel(.ToolOutput, "Terminal", panel_data);
        self.terminal_panel_id = panel_id;
        if (manager.workspace.syncDockLayout() catch false) {
            manager.workspace.markDirty();
        }
        manager.focusPanel(panel_id);
        return panel_id;
    }

    fn addSession(self: *App, key: []const u8, display_name: []const u8) !void {
        const key_copy = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(key_copy);
        const name_copy = try self.allocator.dupe(u8, display_name);
        errdefer self.allocator.free(name_copy);

        if (self.shouldLogDebug(1)) {
            std.log.debug("addSession: key={s} current={}", .{ key, self.chat_sessions.items.len });
        }
        try self.chat_sessions.append(self.allocator, .{
            .key = key_copy,
            .display_name = name_copy,
        });
    }

    fn ensureSessionExists(self: *App, key: []const u8, display_name: []const u8) !void {
        try self.ensureSessionInList(key, display_name);
        try self.setCurrentSessionKey(key);
    }

    fn ensureSessionInList(self: *App, key: []const u8, display_name: []const u8) !void {
        for (self.chat_sessions.items) |*session| {
            if (std.mem.eql(u8, session.key, key)) {
                const existing_name = session.display_name orelse "";
                if (display_name.len > 0 and !std.mem.eql(u8, existing_name, display_name)) {
                    const display_name_copy = try self.allocator.dupe(u8, display_name);
                    if (session.display_name) |value| self.allocator.free(value);
                    session.display_name = display_name_copy;
                }
                if (self.shouldLogDebug(120)) {
                    std.log.debug("ensureSessionInList: key exists {s}", .{key});
                }
                return;
            }
        }
        if (self.shouldLogDebug(120)) {
            std.log.debug("ensureSessionInList: adding new key {s}", .{key});
        }
        try self.addSession(key, display_name);
    }

    fn sanitizeCurrentSessionSelection(self: *App) void {
        if (self.current_session_key) |current| {
            for (self.chat_sessions.items) |session| {
                if (std.mem.eql(u8, current, session.key)) {
                    return;
                }
            }

            self.allocator.free(current);
            self.current_session_key = null;
        }

        if (self.current_session_key == null) {
            if (self.chat_sessions.items.len > 0) {
                self.setCurrentSessionKey(self.chat_sessions.items[0].key) catch {};
            }
        }
    }

    fn setCurrentSessionByKey(self: *App, session_key: []const u8) bool {
        for (self.chat_sessions.items) |session| {
            if (std.mem.eql(u8, session.key, session_key)) {
                self.setCurrentSessionKey(session.key) catch {};
                return true;
            }
        }
        return false;
    }

    fn setCurrentSessionByIndex(self: *App, index: usize) bool {
        if (index >= self.chat_sessions.items.len) return false;
        self.setCurrentSessionKey(self.chat_sessions.items[index].key) catch {};
        return true;
    }

    fn setCurrentSessionKey(self: *App, key: []const u8) !void {
        if (key.len == 0) return;
        const key_copy = try self.allocator.dupe(u8, key);
        self.setCurrentSessionKeyOwned(key_copy);
    }

    fn setCurrentSessionKeyOwned(self: *App, key_copy: []const u8) void {
        var changed = true;
        if (self.current_session_key) |current| {
            changed = !std.mem.eql(u8, current, key_copy);
            self.allocator.free(current);
        }
        self.current_session_key = key_copy;
        if (changed) {
            self.session_attach_state = .unknown;
        }
    }

    fn handleChatPanelAction(self: *App, action: panels_bridge.ChatPanelAction) void {
        if (action.send_message) |message| {
            std.log.info("[GUI] handleChatPanelAction send_message len={d}", .{message.len});
            defer self.allocator.free(message);
            self.sendChatMessageText(message) catch {};
        }

        if (action.select_session) |session_key| {
            defer self.allocator.free(session_key);
            _ = self.setCurrentSessionByKey(session_key);
        }

        if (action.select_session_id) |sid| {
            defer self.allocator.free(sid);
            if (std.fmt.parseInt(usize, sid, 10)) |index| {
                if (self.setCurrentSessionByIndex(index)) return;
            } else |_| {
                _ = self.setCurrentSessionByKey(sid);
            }
        }

        if (action.new_chat_session_key) |new_key| {
            defer self.allocator.free(new_key);
            const sanitized_key = sanitizeSessionKey(self.allocator, new_key) catch return;
            defer self.allocator.free(sanitized_key);

            if (self.setCurrentSessionByKey(sanitized_key)) {
                return;
            }
            self.addSession(sanitized_key, new_key) catch {};
            _ = self.setCurrentSessionByKey(sanitized_key);
        }
    }

    fn setConnectionState(self: *App, state: ConnectionState, text: []const u8) void {
        self.connection_state = state;
        const copy = self.allocator.dupe(u8, text) catch return;
        self.allocator.free(self.status_text);
        self.status_text = copy;
    }

    // Drawing helpers

    fn drawSurfacePanel(self: *App, rect: Rect) void {
        const fill = Paint{ .solid = self.theme.colors.surface };
        self.drawPaintRect(rect, fill);
        self.drawRect(rect, self.theme.colors.border);
    }

    fn drawPaintRect(self: *App, rect: Rect, paint: Paint) void {
        switch (paint) {
            .solid => |color| self.drawFilledRect(rect, color),
            .gradient4 => |g| {
                self.ui_commands.pushRectGradient(
                    .{ .min = rect.min, .max = rect.max },
                    .{
                        .tl = g.tl,
                        .tr = g.tr,
                        .bl = g.bl,
                        .br = g.br,
                    },
                );
            },
            .image => {
                self.drawFilledRect(rect, self.theme.colors.surface);
            },
        }
    }

    fn drawFilledRect(self: *App, rect: Rect, color: [4]f32) void {
        self.ui_commands.pushRect(
            .{ .min = rect.min, .max = rect.max },
            .{ .fill = color },
        );
    }

    fn drawRect(self: *App, rect: Rect, color: [4]f32) void {
        self.ui_commands.pushRect(
            .{ .min = rect.min, .max = rect.max },
            .{ .stroke = color },
        );
    }

    fn drawLabel(self: *App, x: f32, y: f32, text: []const u8, color: [4]f32) void {
        self.drawText(x, y, text, color);
    }

    fn drawFormSectionTitle(
        self: *App,
        x: f32,
        y: *f32,
        max_w: f32,
        layout: PanelLayoutMetrics,
        text: []const u8,
    ) void {
        const width = @max(1.0, max_w);
        const row_h = form_layout.titleRowHeight(layout);
        const text_y = y.* + @max(0.0, (row_h - layout.line_height) * 0.5);
        self.drawTextTrimmed(x, text_y, width, text, self.theme.colors.text_primary);
        y.* += form_layout.advanceAfterTitle(layout);
    }

    fn drawFormFieldLabel(
        self: *App,
        x: f32,
        y: *f32,
        max_w: f32,
        layout: PanelLayoutMetrics,
        text: []const u8,
    ) void {
        const width = @max(1.0, max_w);
        const row_h = form_layout.labelRowHeight(layout);
        const text_y = y.* + @max(0.0, (row_h - layout.line_height) * 0.5);
        self.drawTextTrimmed(x, text_y, width, text, self.theme.colors.text_primary);
        y.* += form_layout.advanceLabelToInput(layout);
    }

    fn textLineHeight(self: *App) f32 {
        const measured = self.metrics_context.lineHeight();
        const px: f32 = @floatFromInt(self.textPixelSize());
        const min_from_font = px * 1.18;
        if (measured > 0.0) return @max(measured, min_from_font);
        return @max(@max(12.0, 16.0 * self.ui_scale), min_from_font);
    }

    fn textPixelSize(_: *App) u16 {
        const size_f = font_system.currentFontSize(zui.ui.theme.activeTheme());
        if (size_f <= 1.0) return 1;
        const clamped = @min(@as(u32, @intFromFloat(size_f)), 65535);
        return @intCast(clamped);
    }

    fn panelLayoutMetrics(self: *App) PanelLayoutMetrics {
        const line_height = self.textLineHeight();
        return form_layout.defaultMetrics(zui.ui.theme.activeTheme(), line_height, self.ui_scale);
    }

    fn dockTabMetrics(self: *App) DockTabMetrics {
        const line_height = self.textLineHeight();
        const tab_pad = @max(self.theme.spacing.sm, self.theme.spacing.xs * 1.4);
        return .{
            .pad = tab_pad,
            .height = @max(line_height + self.theme.spacing.sm * 1.4, 28.0 * self.ui_scale),
            .min_width = @max(96.0 * self.ui_scale, line_height * 4.8),
            .max_width_ratio = 0.34,
        };
    }

    fn dockTabWidth(self: *App, title: []const u8, group_width: f32, metrics: DockTabMetrics) f32 {
        const desired = self.measureText(title) + metrics.pad * 2.0;
        const max_width = @max(metrics.min_width, (group_width - metrics.pad * 2.0) * metrics.max_width_ratio);
        return @min(max_width, desired);
    }

    fn dockSplitGap(self: *App) f32 {
        return @max(self.theme.spacing.xs, 6.0 * self.ui_scale);
    }

    fn nextUtf8Boundary(text: []const u8, index: usize) usize {
        if (index >= text.len) return text.len;
        var i = index + 1;
        while (i < text.len and (text[i] & 0xC0) == 0x80) : (i += 1) {}
        return i;
    }

    fn skipLeadingSpaces(text: []const u8, start: usize) usize {
        var i = start;
        while (i < text.len and (text[i] == ' ' or text[i] == '\t')) : (i += 1) {}
        return i;
    }

    fn nextWrapBreak(self: *App, line: []const u8, start: usize, max_w: f32) usize {
        if (start >= line.len) return line.len;
        const max_width = @max(1.0, max_w);

        var cursor = start;
        var last_fit = start;
        var last_space_end: ?usize = null;
        var width: f32 = 0.0;
        while (cursor < line.len) {
            const next = nextUtf8Boundary(line, cursor);
            if (next <= cursor) break;
            const glyph_w = self.measureGlyphWidth(line[cursor..next]);
            if (width + glyph_w <= max_width or last_fit == start) {
                width += glyph_w;
                last_fit = next;
                if (line[cursor] == ' ' or line[cursor] == '\t') {
                    last_space_end = next;
                }
                cursor = next;
                continue;
            }
            break;
        }

        if (last_fit == start) {
            return nextUtf8Boundary(line, start);
        }
        if (last_space_end) |space_end| {
            if (space_end > start and space_end < line.len) {
                return space_end;
            }
        }
        return last_fit;
    }

    fn inputTailStartForWidth(self: *App, text: []const u8, max_w: f32) usize {
        if (text.len == 0 or max_w <= 0.0) return 0;
        var width: f32 = 0.0;
        var idx: usize = text.len;
        while (idx > 0) {
            var prev = idx - 1;
            while (prev > 0 and (text[prev] & 0xC0) == 0x80) : (prev -= 1) {}
            const glyph_w = self.measureGlyphWidth(text[prev..idx]);
            if (width + glyph_w > max_w) return idx;
            width += glyph_w;
            idx = prev;
        }
        return 0;
    }

    fn drawCenteredText(self: *App, rect: Rect, text: []const u8, color: [4]f32) void {
        const text_w = self.measureTextFast(text);
        const line_height = self.textLineHeight();
        const x = rect.min[0] + @max(0.0, (rect.width() - text_w) * 0.5);
        const y = rect.min[1] + @max(0.0, (rect.height() - line_height) * 0.5);
        self.drawText(x, y, text, color);
    }

    fn drawText(self: *App, x: f32, y: f32, text: []const u8, color: [4]f32) void {
        self.ui_commands.pushText(text, .{ x, y }, color, .body, self.textPixelSize());
    }

    fn drawTextWrapped(self: *App, x: f32, y: f32, max_w: f32, text: []const u8, color: [4]f32) f32 {
        var current_y = y;
        const line_height = self.textLineHeight();
        const wrap_w = @max(1.0, max_w);

        // Split by existing newlines first
        var lines_iter = std.mem.splitScalar(u8, text, '\n');
        while (lines_iter.next()) |raw_line| {
            if (raw_line.len == 0) {
                current_y += line_height;
                continue;
            }

            var line_start: usize = 0;
            while (line_start < raw_line.len) {
                const best_end = self.nextWrapBreak(raw_line, line_start, wrap_w);
                self.drawText(x, current_y, raw_line[line_start..best_end], color);
                current_y += line_height;
                line_start = skipLeadingSpaces(raw_line, best_end);
            }
        }
        return current_y - y;
    }

    fn measureTextWrappedHeight(self: *App, max_w: f32, text: []const u8) f32 {
        const line_height = self.textLineHeight();
        const wrap_w = @max(1.0, max_w);
        var total_height: f32 = 0;

        if (text.len == 0) return line_height;

        // Split by existing newlines first
        var lines_iter = std.mem.splitScalar(u8, text, '\n');
        while (lines_iter.next()) |raw_line| {
            if (raw_line.len == 0) {
                total_height += line_height;
                continue;
            }

            var line_start: usize = 0;
            while (line_start < raw_line.len) {
                const best_end = self.nextWrapBreak(raw_line, line_start, wrap_w);
                total_height += line_height;
                line_start = skipLeadingSpaces(raw_line, best_end);
            }
        }
        return total_height;
    }

    fn measureText(self: *App, text: []const u8) f32 {
        return self.metrics_context.measureText(text, 0.0)[0];
    }

    fn measureTextFast(self: *App, text: []const u8) f32 {
        var width: f32 = 0.0;
        var idx: usize = 0;
        while (idx < text.len) {
            const next = nextUtf8Boundary(text, idx);
            if (next <= idx) break;
            width += self.measureGlyphWidth(text[idx..next]);
            idx = next;
        }
        return width;
    }

    fn drawTextCenteredTrimmed(self: *App, center_x: f32, y: f32, max_w: f32, text: []const u8, color: [4]f32) void {
        if (max_w <= 0.0) return;
        const measured = self.measureTextFast(text);
        if (measured <= max_w) {
            self.drawText(center_x - measured * 0.5, y, text, color);
            return;
        }
        self.drawTextTrimmed(center_x - max_w * 0.5, y, max_w, text, color);
    }

    fn drawTextTrimmed(self: *App, x: f32, y: f32, max_w: f32, text: []const u8, color: [4]f32) void {
        if (max_w <= 0.0) return;
        const text_w = self.measureTextFast(text);
        if (text_w <= max_w) {
            self.drawText(x, y, text, color);
            return;
        }

        const ellipsis = "...";
        const ellipsis_w = self.measureTextFast(ellipsis);
        if (ellipsis_w > max_w) return;

        const limit = max_w - ellipsis_w;
        var width: f32 = 0.0;
        var idx: usize = 0;
        var best_end: usize = 0;
        while (idx < text.len) {
            const next = nextUtf8Boundary(text, idx);
            if (next <= idx) break;
            const glyph_w = self.measureGlyphWidth(text[idx..next]);
            if (width + glyph_w > limit) break;
            width += glyph_w;
            best_end = next;
            idx = next;
        }

        if (best_end == 0) {
            self.drawText(x, y, "...", color);
            return;
        }
        self.drawText(x, y, text[0..best_end], color);
        self.drawText(x + width, y, ellipsis, color);
    }
};

// Image loading stubs required by ziggy-ui
pub export fn zsc_load_icon_rgba_from_memory(data: [*c]const u8, len: c_int, width: [*c]c_int, height: [*c]c_int) [*c]u8 {
    _ = data;
    _ = len;
    if (width != null) width[0] = 0;
    if (height != null) height[0] = 0;
    return null;
}

fn extractCorrelationId(root: std.json.ObjectMap, payload: ?std.json.ObjectMap) ?[]const u8 {
    if (root.get("correlation_id")) |value| {
        if (value == .string and value.string.len > 0) return value.string;
    }
    if (payload) |obj| {
        if (obj.get("correlation_id")) |value| {
            if (value == .string and value.string.len > 0) return value.string;
        }
    }
    return App.extractRequestId(root, payload);
}

test "gui root: extractLatestThoughtFromJobLog returns latest agent thought" {
    const allocator = std.testing.allocator;

    var app: App = undefined;
    app.allocator = allocator;

    const latest = try app.extractLatestThoughtFromJobLog(
        \\{"type":"debug.event","category":"ignored","payload":{"x":1}}
        \\{"type":"agent.thought","content":"first draft","source":"thinking","round":1}
        \\{"type":"agent.thought","content":"second draft","source":"thinking","round":2}
    );
    defer if (latest) |value| allocator.free(value);

    try std.testing.expect(latest != null);
    try std.testing.expectEqualStrings("second draft", latest.?);
}

pub export fn zsc_free_icon(pixels: ?*anyopaque) void {
    _ = pixels;
}

pub export fn zsc_load_image_rgba_from_memory(data: [*c]const u8, len: c_int, width: [*c]c_int, height: [*c]c_int) [*c]u8 {
    _ = data;
    _ = len;
    if (width != null) width[0] = 0;
    if (height != null) height[0] = 0;
    return null;
}

pub export fn zsc_free_image(pixels: ?*anyopaque) void {
    _ = pixels;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{ .thread_safe = true }){};
    defer _ = gpa.deinit();

    var app = try App.init(gpa.allocator());
    defer app.deinit();

    if (app.config.auto_connect_on_launch) {
        app.tryConnect(&app.manager) catch {};
    }

    try app.run();
}
