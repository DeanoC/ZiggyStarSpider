const std = @import("std");
const builtin = @import("builtin");
const zui = @import("ziggy-ui");
const zui_panels = @import("ziggy-ui-panels");
const ws_client_mod = @import("websocket_client.zig");
const app_venom_host = @import("app_venom_host");
const config_mod = @import("client-config");
const credential_store_mod = config_mod.credential_store;
const control_plane = @import("control_plane");
const unified_v2_client = control_plane.unified_v2;
const venom_bindings = @import("venom_bindings");
const build_options = @import("build_options");
const storage = @import("platform_storage");
const workspace_types = control_plane.workspace_types;
const panels_bridge = @import("panels_bridge.zig");
const stage_machine = @import("stage_machine.zig");
const mission_types = @import("state/mission_types.zig");
const venom_types = @import("state/venom_types.zig");
const dashboard_host = @import("panel_hosts/dashboard.zig");
const venom_manager_host = @import("panel_hosts/venom_manager.zig");
const node_topology_host = @import("panel_hosts/node_topology.zig");
const mcp_config_host = @import("panel_hosts/mcp_config.zig");
const mission_workboard_host = @import("panel_hosts/mission_workboard.zig");
const mission_helpers = @import("state/mission_helpers.zig");
const workspace_host_mod = @import("panel_hosts/workspace_host.zig");
const settings_host_mod = @import("panel_hosts/settings_host.zig");
const mission_host_mod = @import("panel_hosts/mission_host.zig");
const terminal_host_mod = @import("panel_hosts/terminal_host.zig");
const filesystem_host_mod = @import("panel_hosts/filesystem_host.zig");
const debug_host_mod = @import("panel_hosts/debug_host.zig");

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
const Paint = zui.ui.theme_engine.style_sheet.Paint;

const UiThemePackStatus = zui.ui.theme_engine.runtime.PackStatusKind;
const UiThemePackMeta = zui.ui.theme_engine.runtime.PackMeta;

const ConnectionState = enum {
    disconnected,
    connecting,
    connected,
    error_state,
};

const LauncherRecipe = enum {
    create_workspace,
    add_second_device,
    install_package,
    run_remote_service,
    connect_to_spiderweb,
    workspace_tokens,
    connect_another_machine,
    contribute_this_mac,
};

const LauncherRecipeSpec = struct {
    eyebrow: []const u8,
    title: []const u8,
    summary: []const u8,
    steps: [3][]const u8,
    primary_label: []const u8,
    secondary_label: ?[]const u8 = null,
};

const LauncherConnectDetails = struct {
    server_url: []const u8,
    token_label: []const u8,
    token: []const u8,
    workspace_id: []const u8,
    workspace_name: []const u8,
};

const LauncherRecipeProgress = enum {
    guide,
    ready,
    done,
};

const UiStage = stage_machine.Stage;
const OnboardingStage = stage_machine.OnboardingStage;
const HomeRoute = stage_machine.HomeRoute;

const LaunchAction = enum {
    none,
    open_workspace,
    open_devices,
    open_capabilities,
    open_explore,
    open_remote_terminal,
    open_settings,
};

const LaunchContext = struct {
    profile_id: ?[]u8 = null,
    workspace_id: ?[]u8 = null,
    device_id: ?[]u8 = null,
    route: ?HomeRoute = null,
    action: LaunchAction = .none,

    fn deinit(self: *LaunchContext, allocator: std.mem.Allocator) void {
        if (self.profile_id) |value| allocator.free(value);
        if (self.workspace_id) |value| allocator.free(value);
        if (self.device_id) |value| allocator.free(value);
        self.* = undefined;
    }
};

const workflow_start_local_workspace = "start_local_workspace";
const workflow_add_second_device = "add_second_device";
const workflow_install_package = "install_package";
const workflow_run_remote_service = "run_remote_service";
const workflow_connect_to_another_spiderweb = "connect_to_another_spiderweb";
const workflow_spiderweb_handoff_completed = "spiderweb_handoff_completed";

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
const APP_LOCAL_NODE_LEASE_TTL_MS: u64 = 15 * 60 * 1000;
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
const NODE_SERVICE_EVENTS_PATH = "/.spiderweb/catalog/node-venom-events.ndjson";
const PACKAGES_CONTROL_ROOT = "/.spiderweb/control/packages";
const NODE_SERVICE_SNAPSHOT_RETRY_MS: i64 = 2_000;
const DEBUG_EVENT_DEDUPE_WINDOW: usize = 4096;
const DEBUG_SYNTAX_COLOR_MAX_PAYLOAD_BYTES: usize = 64 * 1024;
const DEBUG_SYNTAX_COLOR_MAX_LINE_BYTES: usize = 768;
const PERF_SAMPLE_INTERVAL_MS: i64 = 1_000;
const PERF_HISTORY_CAPACITY: usize = 600;
const PERF_AUTOMATION_DEFAULT_DURATION_MS: i64 = 12_000;
const MISSION_REFRESH_INTERVAL_MS: i64 = 5_000;
const MISSION_PREVIEW_EVENT_COUNT: usize = 4;
const MISSION_PREVIEW_ARTIFACT_COUNT: usize = 4;
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
const WorkspacePanel = zui_panels.workspace_panel;
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
    workspace_id: ?[]u8 = null,
    workspace_vision: ?[]u8 = null,

    fn deinit(self: *ConnectSetupHint, allocator: std.mem.Allocator) void {
        if (self.message) |value| allocator.free(value);
        if (self.workspace_id) |value| allocator.free(value);
        if (self.workspace_vision) |value| allocator.free(value);
        self.* = undefined;
    }
};

const MissionActorView = mission_types.MissionActorView;
const MissionArtifactView = mission_types.MissionArtifactView;
const MissionEventView = mission_types.MissionEventView;
const MissionApprovalView = mission_types.MissionApprovalView;
const MissionAgentPackView = mission_types.MissionAgentPackView;

const MissionRecordView = mission_types.MissionRecordView;

fn platformWindowTitle(title: [:0]const u8) [:0]const u8 {
    if (storage.isAndroid()) return "";
    return title;
}

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

const PackageManagerEntry = struct {
    package_id: []u8,
    kind: []u8,
    version: []u8,
    runtime_kind: []u8,
    enabled: bool = true,
    active_release_version: ?[]u8 = null,
    latest_release_version: ?[]u8 = null,
    latest_release_channel: ?[]u8 = null,
    effective_channel: ?[]u8 = null,
    channel_override: ?[]u8 = null,
    installed_release_count: usize = 0,
    release_history_count: usize = 0,
    update_available: bool = false,
    last_release_action: ?[]u8 = null,
    last_release_version: ?[]u8 = null,
    help_md: ?[]u8 = null,

    fn deinit(self: *PackageManagerEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.package_id);
        allocator.free(self.kind);
        allocator.free(self.version);
        allocator.free(self.runtime_kind);
        if (self.active_release_version) |value| allocator.free(value);
        if (self.latest_release_version) |value| allocator.free(value);
        if (self.latest_release_channel) |value| allocator.free(value);
        if (self.effective_channel) |value| allocator.free(value);
        if (self.channel_override) |value| allocator.free(value);
        if (self.last_release_action) |value| allocator.free(value);
        if (self.last_release_version) |value| allocator.free(value);
        if (self.help_md) |value| allocator.free(value);
        self.* = undefined;
    }
};

const VenomScope = enum {
    global,
    workspace,
    agent,

    pub fn label(scope: VenomScope) []const u8 {
        return switch (scope) {
            .global => "global",
            .workspace => "workspace",
            .agent => "agent",
        };
    }

    pub fn color(scope: VenomScope) [4]f32 {
        return switch (scope) {
            .global => zcolors.rgba(80, 160, 240, 255),
            .workspace => zcolors.rgba(80, 200, 100, 255),
            .agent => zcolors.rgba(220, 140, 50, 255),
        };
    }
};

const VenomEntry = struct {
    venom_id: []u8,
    scope: VenomScope,
    provider_node_id: ?[]u8,
    provider_venom_path: ?[]u8,
    venom_path: []u8,
    endpoint_path: ?[]u8,
    invoke_path: ?[]u8,

    fn deinit(self: *VenomEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.venom_id);
        if (self.provider_node_id) |v| allocator.free(v);
        if (self.provider_venom_path) |v| allocator.free(v);
        allocator.free(self.venom_path);
        if (self.endpoint_path) |v| allocator.free(v);
        if (self.invoke_path) |v| allocator.free(v);
        self.* = undefined;
    }
};

const McpEntry = venom_types.McpEntry;
const WizardMount = venom_types.WizardMount;
const WizardBind = venom_types.WizardBind;

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
    const build_default = terminal_render_backend.Backend.parseKind(TERMINAL_BACKEND_KIND);
    if (builtin.os.tag == .macos and build_default == .plain_text) {
        return .ghostty_vt;
    }
    return build_default;
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

fn normalizeWorkspaceToken(workspace_token: ?[]const u8) ?[]const u8 {
    const token = workspace_token orelse return null;
    const trimmed = std.mem.trim(u8, token, " \t\r\n");
    if (trimmed.len == 0) return null;
    return trimmed;
}

fn platformSupportsMultiWindow() bool {
    return storage.supportsMultiWindow();
}

fn themePackWatchSupported() bool {
    return storage.supportsThemePackWatch();
}

fn themePackBrowseSupported() bool {
    return storage.supportsThemePackBrowse();
}

fn themePackRefreshSupported() bool {
    return storage.supportsThemePackRefresh();
}

fn platformSupportsWindowGeometryPersistence() bool {
    return storage.supportsWindowGeometryPersistence();
}

fn platformSupportsWorkspaceSnapshots() bool {
    return storage.supportsWorkspaceSnapshots();
}

fn containsCaseInsensitive(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    return std.ascii.indexOfIgnoreCase(haystack, needle) != null;
}

pub const SettingsFocusField = enum {
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
    workspace_template_id,
    project_operator_token,
    project_mount_path,
    project_mount_node_id,
    project_mount_export_name,
    workspace_bind_path,
    workspace_bind_target_path,
    default_session,
    default_agent,
    theme_pack,
    node_watch_filter,
    node_watch_replay_limit,
    debug_search_filter,
    perf_benchmark_label,
    filesystem_contract_payload,
    package_manager_install_payload,
    about_modal_build_label,
    terminal_command_input,
};

const PointerInputLayer = enum {
    base,
    text_input_context_menu,
};

pub fn isSettingsPanelFocusField(field: SettingsFocusField) bool {
    return switch (field) {
        .server_url,
        .default_session,
        .default_agent,
        .theme_pack,
        => true,
        else => false,
    };
}

// Panel extraction keeps host-owned text storage in SpiderApp, so these helpers
// translate between the shared panel state enums and the host-local focus enum.
pub fn settingsFocusFieldToExternal(field: SettingsFocusField) LauncherSettingsPanel.FocusField {
    return switch (field) {
        .server_url => .server_url,
        .default_session => .default_session,
        .default_agent => .default_agent,
        .theme_pack => .theme_pack,
        else => .none,
    };
}

pub fn settingsFocusFieldFromExternal(field: LauncherSettingsPanel.FocusField) SettingsFocusField {
    return switch (field) {
        .server_url => .server_url,
        .default_session => .default_session,
        .default_agent => .default_agent,
        .theme_pack => .theme_pack,
        .none => .none,
    };
}

fn settingsThemeModeFromConfig(mode: config_mod.Config.ThemeMode) panels_bridge.SettingsThemeMode {
    return switch (mode) {
        .pack_default => .pack_default,
        .light => .light,
        .dark => .dark,
    };
}

fn configThemeModeFromSettings(mode: panels_bridge.SettingsThemeMode) config_mod.Config.ThemeMode {
    return switch (mode) {
        .pack_default => .pack_default,
        .light => .light,
        .dark => .dark,
    };
}

fn settingsThemeProfileFromConfig(profile_value: config_mod.Config.ThemeProfile) panels_bridge.SettingsThemeProfile {
    return switch (profile_value) {
        .auto => .auto,
        .desktop => .desktop,
        .phone => .phone,
        .tablet => .tablet,
        .fullscreen => .fullscreen,
    };
}

fn configThemeProfileFromSettings(profile_value: panels_bridge.SettingsThemeProfile) config_mod.Config.ThemeProfile {
    return switch (profile_value) {
        .auto => .auto,
        .desktop => .desktop,
        .phone => .phone,
        .tablet => .tablet,
        .fullscreen => .fullscreen,
    };
}

fn themeProfileLabel(profile_value: panels_bridge.SettingsThemeProfile) ?[]const u8 {
    return switch (profile_value) {
        .auto => null,
        .desktop => "desktop",
        .phone => "phone",
        .tablet => "tablet",
        .fullscreen => "fullscreen",
    };
}

pub fn debugFocusFieldToExternal(field: SettingsFocusField) DebugPanel.FocusField {
    return switch (field) {
        .perf_benchmark_label => .perf_benchmark_label,
        .node_watch_filter => .node_watch_filter,
        .node_watch_replay_limit => .node_watch_replay_limit,
        .debug_search_filter => .debug_search_filter,
        else => .none,
    };
}

pub fn debugFocusFieldFromExternal(field: DebugPanel.FocusField) SettingsFocusField {
    return switch (field) {
        .perf_benchmark_label => .perf_benchmark_label,
        .node_watch_filter => .node_watch_filter,
        .node_watch_replay_limit => .node_watch_replay_limit,
        .debug_search_filter => .debug_search_filter,
        .none => .none,
    };
}

pub fn isDebugPanelFocusField(field: SettingsFocusField) bool {
    return switch (field) {
        .perf_benchmark_label,
        .node_watch_filter,
        .node_watch_replay_limit,
        .debug_search_filter,
        => true,
        else => false,
    };
}

pub fn projectFocusFieldToExternal(field: SettingsFocusField) WorkspacePanel.FocusField {
    return switch (field) {
        .project_token => .workspace_token,
        .project_create_name => .create_name,
        .project_create_vision => .create_vision,
        .workspace_template_id => .template_id,
        .project_operator_token => .operator_token,
        .project_mount_path => .mount_path,
        .project_mount_node_id => .mount_node_id,
        .project_mount_export_name => .mount_export_name,
        .workspace_bind_path => .bind_path,
        .workspace_bind_target_path => .bind_target_path,
        else => .none,
    };
}

pub fn projectFocusFieldFromExternal(field: WorkspacePanel.FocusField) SettingsFocusField {
    return switch (field) {
        .workspace_token => .project_token,
        .create_name => .project_create_name,
        .create_vision => .project_create_vision,
        .template_id => .workspace_template_id,
        .operator_token => .project_operator_token,
        .mount_path => .project_mount_path,
        .mount_node_id => .project_mount_node_id,
        .mount_export_name => .project_mount_export_name,
        .bind_path => .workspace_bind_path,
        .bind_target_path => .workspace_bind_target_path,
        .none => .none,
    };
}

pub fn isWorkspacePanelFocusField(field: SettingsFocusField) bool {
    return switch (field) {
        .project_token,
        .project_create_name,
        .project_create_vision,
        .workspace_template_id,
        .project_operator_token,
        .project_mount_path,
        .project_mount_node_id,
        .project_mount_export_name,
        .workspace_bind_path,
        .workspace_bind_target_path,
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

const system_workspace_id = "system";
const system_agent_id = "spiderweb";

fn isSystemWorkspaceId(workspace_id: ?[]const u8) bool {
    const concrete = workspace_id orelse return false;
    return std.mem.eql(u8, concrete, system_workspace_id);
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
    workspace_template_id: std.ArrayList(u8) = .empty,
    project_operator_token: std.ArrayList(u8) = .empty,
    project_mount_path: std.ArrayList(u8) = .empty,
    project_mount_node_id: std.ArrayList(u8) = .empty,
    project_mount_export_name: std.ArrayList(u8) = .empty,
    workspace_bind_path: std.ArrayList(u8) = .empty,
    workspace_bind_target_path: std.ArrayList(u8) = .empty,
    default_session: std.ArrayList(u8) = .empty,
    default_agent: std.ArrayList(u8) = .empty,
    theme_mode: panels_bridge.SettingsThemeMode = .pack_default,
    theme_profile: panels_bridge.SettingsThemeProfile = .auto,
    theme_pack: std.ArrayList(u8) = .empty,
    watch_theme_pack: bool = false,
    terminal_backend_kind: terminal_render_backend.Backend.Kind = .plain_text,
    ws_verbose_logs: bool = false,
    auto_connect_on_launch: bool = true,
    focused_field: SettingsFocusField = .server_url,
    // Vertical scroll offsets per form panel
    settings_scroll_y: f32 = 0.0,
    workspaces_scroll_y: f32 = 0.0,

    pub fn init(allocator: std.mem.Allocator) SettingsPanel {
        var panel = SettingsPanel{};
        panel.server_url.appendSlice(allocator, "ws://127.0.0.1:18790") catch {};
        panel.project_id.appendSlice(allocator, "") catch {};
        panel.project_token.appendSlice(allocator, "") catch {};
        panel.project_create_name.appendSlice(allocator, "") catch {};
        panel.project_create_vision.appendSlice(allocator, "") catch {};
        panel.workspace_template_id.appendSlice(allocator, "dev") catch {};
        panel.project_operator_token.appendSlice(allocator, "") catch {};
        panel.project_mount_path.appendSlice(allocator, "/") catch {};
        panel.project_mount_node_id.appendSlice(allocator, "") catch {};
        panel.project_mount_export_name.appendSlice(allocator, "") catch {};
        panel.workspace_bind_path.appendSlice(allocator, "/repo") catch {};
        panel.workspace_bind_target_path.appendSlice(allocator, "/nodes/local/fs") catch {};
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
        self.workspace_template_id.deinit(allocator);
        self.project_operator_token.deinit(allocator);
        self.project_mount_path.deinit(allocator);
        self.project_mount_node_id.deinit(allocator);
        self.project_mount_export_name.deinit(allocator);
        self.workspace_bind_path.deinit(allocator);
        self.workspace_bind_target_path.deinit(allocator);
        self.default_session.deinit(allocator);
        self.default_agent.deinit(allocator);
        self.theme_pack.deinit(allocator);
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

const ThemePackEntry = struct {
    name: []u8,

    fn deinit(self: *ThemePackEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        self.* = undefined;
    }
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

fn scanThemeDirStamp(dir: *std.fs.Dir) !i128 {
    var latest: i128 = 0;
    var it = dir.iterate();
    while (try it.next()) |entry| {
        switch (entry.kind) {
            .file => {
                var file = dir.openFile(entry.name, .{}) catch continue;
                defer file.close();
                const stat = file.stat() catch continue;
                latest = @max(latest, stat.mtime);
            },
            .directory => {
                if (std.mem.eql(u8, entry.name, ".") or std.mem.eql(u8, entry.name, "..")) continue;
                var child = dir.openDir(entry.name, .{ .iterate = true }) catch continue;
                defer child.close();
                latest = @max(latest, try scanThemeDirStamp(&child));
            },
            else => {},
        }
    }
    return latest;
}

fn scanThemePackStamp(path: []const u8) ?i128 {
    var dir = std.fs.cwd().openDir(path, .{ .iterate = true }) catch return null;
    defer dir.close();
    return scanThemeDirStamp(&dir) catch null;
}

// ── Domain state sub-structs ─────────────────────────────────────────────────
// Each sub-struct groups the App fields for one functional domain.
// Fields keep their full names inside the sub-struct for greppability;
// access sites read e.g. self.mission.records instead of self.mission.records.

const MissionState = struct {
    records: std.ArrayListUnmanaged(MissionRecordView) = .{},
    selected_id: ?[]u8 = null,
    last_error: ?[]u8 = null,
    last_refresh_ms: i64 = 0,
};

const TerminalState = struct {
    terminal_panel_id: ?workspace.PanelId = null,
    terminal_backend_kind: terminal_render_backend.Backend.Kind = .plain_text,
    terminal_backend: terminal_render_backend.Backend, // no default — must be set by App.init
    terminal_input: std.ArrayList(u8) = .empty,
    terminal_status: ?[]u8 = null,
    terminal_error: ?[]u8 = null,
    terminal_session_id: ?[]u8 = null,
    terminal_auto_poll: bool = true,
    terminal_next_poll_at_ms: i64 = 0,
    terminal_target_node_id: ?[]u8 = null,
    terminal_target_label: ?[]u8 = null,
    terminal_service_root: ?[]u8 = null,
    terminal_control_root: ?[]u8 = null,
};

const FilesystemState = struct {
    // Panel IDs
    filesystem_panel_id: ?workspace.PanelId = null,
    filesystem_tools_panel_id: ?workspace.PanelId = null,
    // Directory listing
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
    filesystem_entry_scroll_y: f32 = 0.0,
    filesystem_entry_scrollbar_dragging: bool = false,
    filesystem_entry_scrollbar_drag_anchor: f32 = 0.0,
    filesystem_entry_scrollbar_drag_scroll: f32 = 0.0,
    filesystem_last_clicked_entry_index: ?usize = null,
    filesystem_last_click_ms: i64 = 0,
    // Column widths (non-zero defaults — set by App.init)
    filesystem_type_column_width: f32 = 96.0,
    filesystem_modified_column_width: f32 = 122.0,
    filesystem_size_column_width: f32 = 72.0,
    filesystem_column_resize_handle: FilesystemPanel.ColumnResizeHandle = .none,
    // Preview pane
    filesystem_preview_split_ratio: f32 = 0.28,
    filesystem_preview_split_dragging: bool = false,
    filesystem_preview_path: ?[]u8 = null,
    filesystem_preview_text: ?[]u8 = null,
    filesystem_preview_status: ?[]u8 = null,
    filesystem_preview_mode: FilesystemPreviewMode = .empty,
    filesystem_preview_kind: FilesystemEntryKind = .unknown,
    filesystem_preview_size_bytes: ?u64 = null,
    filesystem_preview_modified_unix_ms: ?i64 = null,
    // Request tracking
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
    // fsrpc connection state
    fsrpc_last_remote_error: ?[]u8 = null,
    fsrpc_ready: bool = false,
    next_fsrpc_tag: u32 = 1,
    next_fsrpc_fid: u32 = 2,
    // Contract services (filesystem-based RPC schema browser)
    contract_services: std.ArrayListUnmanaged(ContractServiceEntry) = .{},
    contract_service_selected_index: usize = 0,
    contract_invoke_payload: std.ArrayList(u8) = .empty,
};

const ChatState = struct {
    chat_panel_state: zui.ui.workspace.ChatPanel = .{},
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
};

const DebugState = struct {
    // Debug event stream
    debug_stream_enabled: bool = true,
    debug_stream_snapshot_pending: bool = false,
    debug_stream_snapshot_retry_at_ms: i64 = 0,
    debug_stream_snapshot: ?[]u8 = null,
    // Node-service watch (shares the debug panel)
    node_service_watch_enabled: bool = false,
    node_service_snapshot_pending: bool = false,
    node_service_snapshot_retry_at_ms: i64 = 0,
    node_service_watch_filter: std.ArrayList(u8) = .empty,
    node_service_watch_replay_limit: std.ArrayList(u8) = .empty,
    node_service_latest_reload_diag: ?[]u8 = null,
    node_service_diff_preview: ?[]u8 = null,
    node_service_diff_base_index: ?usize = null,
    // Debug panel state
    debug_search_filter: std.ArrayList(u8) = .empty,
    debug_panel_id: ?workspace.PanelId = null,
    debug_events: std.ArrayList(DebugEventEntry) = .empty,
    debug_next_event_id: u64 = 1,
    debug_events_revision: u64 = 1,
    debug_filter_cache_valid: bool = false,
    debug_filter_cache_query_hash: u64 = 0,
    debug_filter_cache_query_len: usize = 0,
    debug_filter_cache_events_revision: u64 = 0,
    debug_filtered_indices: std.ArrayList(u32) = .empty,
    debug_folded_blocks: std.AutoHashMap(DebugFoldKey, void), // init in App.init
    debug_fold_revision: u64 = 1,
    debug_scroll_y: f32 = 0.0,
    debug_selected_index: ?usize = null,
    // Node-service cache for selected entry detail
    debug_selected_node_service_cache_event_id: u64 = 0,
    debug_selected_node_service_cache_index: ?usize = null,
    debug_selected_node_service_cache_node_id: ?[]u8 = null,
    debug_selected_node_service_cache_diagnostics: ?[]u8 = null,
    // Deduplication fingerprint ring
    debug_event_fingerprint_set: std.AutoHashMapUnmanaged(u64, void) = .{},
    debug_event_fingerprint_ring: [DEBUG_EVENT_DEDUPE_WINDOW]u64 = [_]u64{0} ** DEBUG_EVENT_DEDUPE_WINDOW,
    debug_event_fingerprint_count: usize = 0,
    debug_event_fingerprint_next: usize = 0,
    // Layout state
    debug_output_rect: Rect = Rect.fromXYWH(0, 0, 0, 0),
    debug_scrollbar_dragging: bool = false,
    debug_scrollbar_drag_start_y: f32 = 0.0,
    debug_scrollbar_drag_start_scroll_y: f32 = 0.0,
};

const WorkspaceState = struct {
    projects: std.ArrayListUnmanaged(workspace_types.WorkspaceSummary) = .{},
    nodes: std.ArrayListUnmanaged(workspace_types.NodeInfo) = .{},
    workspace_state: ?workspace_types.WorkspaceStatus = null,
    workspace_last_error: ?[]u8 = null,
    workspace_last_refresh_ms: i64 = 0,
    selected_workspace_detail: ?workspace_types.WorkspaceDetail = null,
    workspace_selected_mount_index: ?usize = null,
    workspace_selected_bind_index: ?usize = null,
    workspace_op_busy: bool = false,
    node_browser_open: bool = false,
    node_browser_selected_index: ?usize = null,
    workspace_panel_id: ?workspace.PanelId = null,
    workspace_selector_open: bool = false,
    dashboard_panel_id: ?workspace.PanelId = null,
    dashboard_last_refresh_ms: i64 = 0,
    venom_manager_panel_id: ?workspace.PanelId = null,
    venom_entries: std.ArrayListUnmanaged(VenomEntry) = .{},
    venom_selected_index: ?usize = null,
    venom_last_refresh_ms: i64 = 0,
    venom_last_error: ?[]u8 = null,
    venom_refresh_busy: bool = false,
    node_topology_panel_id: ?workspace.PanelId = null,
    node_topology_table_view: bool = false,
    node_topology_selected_index: ?usize = null,
    mcp_config_panel_id: ?workspace.PanelId = null,
    mcp_entries: std.ArrayListUnmanaged(McpEntry) = .{},
    mcp_selected_index: ?usize = null,
    mcp_selected_runtime: ?[]u8 = null,
    mcp_last_error: ?[]u8 = null,
    mcp_last_refresh_ms: i64 = 0,
    workspace_wizard_open: bool = false,
    workspace_wizard_step: usize = 0,
    workspace_wizard_mounts: std.ArrayListUnmanaged(WizardMount) = .{},
    workspace_wizard_binds: std.ArrayListUnmanaged(WizardBind) = .{},
    workspace_wizard_error: ?[]u8 = null,
    workspace_wizard_selected_node_index: ?usize = null,
    active_workspace_id: ?[]u8 = null,
    launcher_notice: ?[]u8 = null,
    launcher_selected_profile_index: usize = 0,
    launcher_project_filter: std.ArrayList(u8) = .empty,
    launcher_profile_name: std.ArrayList(u8) = .empty,
    launcher_profile_metadata: std.ArrayList(u8) = .empty,
    launcher_connect_token: std.ArrayList(u8) = .empty,
    launcher_create_modal_open: bool = false,
    launcher_create_selected_template_index: usize = 0,
    launcher_create_template_page: usize = 0,
    launcher_create_templates: std.ArrayListUnmanaged(workspace_types.WorkspaceTemplate) = .{},
    launcher_create_modal_error: ?[]u8 = null,
    launcher_recipe_modal: ?LauncherRecipe = null,
    onboarding_stage: OnboardingStage = .connect,
    home_route: HomeRoute = .workspace,
    workspace_recovery_blocked_until: u64 = 0,
    workspace_recovery_blocked_for_manager: usize = 0,
    workspace_recovery_suspended_until: u64 = 0,
    workspace_recovery_suspended_for_manager: usize = 0,
    workspace_recovery_failures: u8 = 0,
    workspace_snapshot_restore_cooldown_until: u64 = 0,
    workspace_snapshot: ?workspace.WorkspaceSnapshot = null,
    workspace_snapshot_stale: bool = false,
    workspace_snapshot_restore_attempted: bool = false,
};

pub const App = struct {
    allocator: std.mem.Allocator,
    window: *c.SDL_Window,
    gpu: zapp.multi_window_renderer.Shared,
    swapchain: zapp.multi_window_renderer.WindowSwapchain,

    ui_windows: std.ArrayList(*UiWindow) = .empty,
    main_window_id: u32 = 0,

    // Panel state
    settings_panel: SettingsPanel,

    // Workspace and panel management
    next_panel_id: workspace.PanelId = 1,
    manager: panel_manager.PanelManager,

    // Chat state
    chat: ChatState = .{},
    debug: DebugState,
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
    form_scroll_drag_target: FormScrollTarget = .none,
    form_scroll_drag_start_y: f32 = 0.0,
    form_scroll_drag_start_scroll_y: f32 = 0.0,
    drag_mouse_capture_active: bool = false,
    ui_commands: zui.ui.render.command_list.CommandList,
    ui_inbox: ui_command_inbox.UiCommandInbox,

    ws: WorkspaceState = .{},
    mission: MissionState = .{},
    fs: FilesystemState = .{},
    terminal: TerminalState,
    session_attach_state: SessionAttachUiState = .unknown,
    connect_setup_hint: ?ConnectSetupHint = null,

    ws_client: ?ws_client_mod.WebSocketClient = null,
    app_local_venom_host: ?app_venom_host.AppVenomHost = null,

    connection_state: ConnectionState = .disconnected,
    status_text: []u8,
    ui_stage: UiStage = .launcher,
    active_profile_id: ?[]u8 = null,
    ide_menu_open: ?IdeMenuDomain = null,
    credential_store: credential_store_mod.CredentialStore,

    theme: *const zui.Theme,
    host_theme_engine: zui.theme_engine.ThemeEngine,
    shared_theme_engine: zui.ui.theme_engine.theme_engine.ThemeEngine,
    ui_scale: f32 = 1.0,
    metrics_context: ui_draw_context.DrawContext,
    ascii_glyph_width_cache: [128]f32 = [_]f32{-1.0} ** 128,
    config: config_mod.Config,
    launch_context: ?LaunchContext = null,
    launch_uses_env_token: bool = false,
    client_context: client_state.ClientContext,
    agent_registry: client_agents.AgentRegistry,

    running: bool = true,

    // Input state
    mouse_x: f32 = 0,
    mouse_y: f32 = 0,
    mouse_down: bool = false,
    mouse_clicked: bool = false,
    mouse_released: bool = false,
    mouse_scroll_y: f32 = 0,
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
    // UI State for dock
    ui_state: zui.ui.main_window.WindowUiState = .{},
    windows_menu_open_window_id: ?u32 = null,
    theme_pack_entries: std.ArrayListUnmanaged(ThemePackEntry) = .{},
    theme_pack_watch_next_scan_ms: i64 = 0,
    theme_pack_watch_stamp_ns: i128 = 0,
    package_manager_modal_open: bool = false,
    package_manager_packages: std.ArrayListUnmanaged(PackageManagerEntry) = .{},
    package_manager_selected_index: usize = 0,
    package_manager_refresh_busy: bool = false,
    package_manager_last_refresh_ms: i64 = 0,
    package_manager_install_payload: std.ArrayList(u8) = .empty,
    package_manager_modal_error: ?[]u8 = null,
    package_manager_modal_notice: ?[]u8 = null,
    about_modal_open: bool = false,
    about_modal_build_label: std.ArrayList(u8) = .empty,
    about_modal_notice: ?[]u8 = null,
    mount_control_ready: bool = false,

    pub fn init(allocator: std.mem.Allocator) !*App {
        panels_bridge.assertAvailable();
        // Load config before creating window so saved geometry can be restored.
        var config = config_mod.Config.load(allocator) catch |err| blk: {
            std.log.warn("Failed to load config: {s}, using defaults", .{@errorName(err)});
            break :blk try config_mod.Config.init(allocator);
        };
        errdefer config.deinit();

        const launch_profile_id = duplicateTrimmedEnvVarOwned(allocator, "SPIDERAPP_LAUNCH_PROFILE_ID");
        defer if (launch_profile_id) |value| allocator.free(value);
        const launch_server_url = duplicateTrimmedEnvVarOwned(allocator, "SPIDERAPP_LAUNCH_SERVER_URL");
        defer if (launch_server_url) |value| allocator.free(value);
        const launch_token = duplicateTrimmedEnvVarOwned(allocator, "SPIDERAPP_LAUNCH_TOKEN");
        defer if (launch_token) |value| allocator.free(value);
        const launch_active_role_raw = duplicateTrimmedEnvVarOwned(allocator, "SPIDERAPP_LAUNCH_ACTIVE_ROLE");
        defer if (launch_active_role_raw) |value| allocator.free(value);
        const launch_active_role = if (launch_active_role_raw) |value| parseLaunchTokenRole(value) else null;

        if (launch_profile_id) |profile_id| {
            if (config.hasConnectionProfileId(profile_id)) {
                config.setSelectedProfileById(profile_id) catch {};
            }
        }
        if (launch_server_url) |server_url| {
            config.setServerUrl(server_url) catch {};
        }
        if (launch_active_role) |role| {
            config.setActiveRole(role) catch {};
        }
        if (launch_token) |token| {
            config.setRoleToken(config.active_role, token) catch {};
            config.syncSelectedProfileFromLegacyFields() catch {};
        }

        const restored_width = config.window_width orelse DEFAULT_MAIN_WINDOW_WIDTH;
        const restored_height = config.window_height orelse DEFAULT_MAIN_WINDOW_HEIGHT;
        const initial_width: c_int = @intCast(@max(MIN_MAIN_WINDOW_WIDTH, restored_width));
        const initial_height: c_int = @intCast(@max(MIN_MAIN_WINDOW_HEIGHT, restored_height));

        try zapp.sdl_app.init(.{ .video = true, .events = true, .gamepad = false });
        zapp.clipboard.init();

        const window = zapp.sdl_app.createWindow(platformWindowTitle("Spider Legacy Runtime"), initial_width, initial_height, c.SDL_WINDOW_RESIZABLE) catch {
            return error.SdlWindowCreateFailed;
        };
        errdefer c.SDL_DestroyWindow(window);
        _ = c.SDL_SetWindowMinimumSize(window, MIN_MAIN_WINDOW_WIDTH, MIN_MAIN_WINDOW_HEIGHT);
        if (platformSupportsWindowGeometryPersistence()) {
            if (config.window_x) |window_x| {
                if (config.window_y) |window_y| {
                    _ = c.SDL_SetWindowPosition(window, window_x, window_y);
                }
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
        if (launch_token == null) {
            if (credential_store.load(selected_profile_id, "role_admin") catch null) |token| {
                defer allocator.free(token);
                config.setRoleToken(.admin, token) catch {};
            }
            if (credential_store.load(selected_profile_id, "role_user") catch null) |token| {
                defer allocator.free(token);
                config.setRoleToken(.user, token) catch {};
            }
        }

        // Initialize settings panel with config values
        var settings_panel = SettingsPanel.init(allocator);
        settings_panel.server_url.clearRetainingCapacity();
        settings_panel.server_url.appendSlice(allocator, config.server_url) catch {};
        settings_panel.project_id.clearRetainingCapacity();
        if (config.selectedWorkspace()) |value| {
            settings_panel.project_id.appendSlice(allocator, value) catch {};
            if (!isSystemWorkspaceId(value)) {
                if (config.getWorkspaceToken(value)) |project_token| {
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
        settings_panel.theme_mode = settingsThemeModeFromConfig(config.theme_mode);
        settings_panel.theme_profile = settingsThemeProfileFromConfig(config.theme_profile);
        if (config.theme_pack) |value| {
            settings_panel.theme_pack.clearRetainingCapacity();
            settings_panel.theme_pack.appendSlice(allocator, value) catch {};
        }
        settings_panel.watch_theme_pack = config.watch_theme_pack and themePackWatchSupported();
        settings_panel.ws_verbose_logs = config.gui_verbose_ws_logs;
        settings_panel.auto_connect_on_launch = config.auto_connect_on_launch;
        settings_panel.terminal_backend_kind = if (config.selectedTerminalBackend()) |backend|
            terminal_render_backend.Backend.parseKind(backend)
        else
            defaultTerminalBackendKind();

        var app = try allocator.create(App);
        errdefer allocator.destroy(app);
        @memset(std.mem.asBytes(app), 0);
        app.allocator = allocator;
        app.window = window;
        app.gpu = gpu;
        app.swapchain = swapchain;
        app.settings_panel = settings_panel;
        app.next_panel_id = 1;
        app.debug.debug_stream_enabled = true;
        app.debug.debug_next_event_id = 1;
        app.debug.debug_events_revision = 1;
        app.debug.debug_folded_blocks = std.AutoHashMap(DebugFoldKey, void).init(allocator);
        app.debug.debug_fold_revision = 1;
        app.perf_automation_duration_ms = PERF_AUTOMATION_DEFAULT_DURATION_MS;
        app.fs.filesystem_sort_key = .name;
        app.fs.filesystem_sort_direction = .ascending;
        app.fs.filesystem_type_column_width = 96.0;
        app.fs.filesystem_modified_column_width = 122.0;
        app.fs.filesystem_size_column_width = 72.0;
        app.fs.filesystem_column_resize_handle = .none;
        app.fs.filesystem_preview_split_ratio = 0.28;
        app.fs.filesystem_preview_mode = .empty;
        app.fs.filesystem_preview_kind = .unknown;
        app.fs.filesystem_next_request_id = 1;
        app.terminal.terminal_backend_kind = settings_panel.terminal_backend_kind;
        app.terminal.terminal_backend = initTerminalBackend(settings_panel.terminal_backend_kind);
        app.terminal.terminal_auto_poll = true;
        app.session_attach_state = .unknown;
        app.connection_state = .disconnected;
        app.status_text = try allocator.dupe(u8, "Not connected");
        app.ui_stage = .launcher;
        app.theme = zui.theme.current();
        app.host_theme_engine = zui.theme_engine.ThemeEngine.init(
            allocator,
            zui.theme_engine.PlatformCaps.defaultForTarget(),
        );
        app.shared_theme_engine = zui.ui.theme_engine.theme_engine.ThemeEngine.init(
            allocator,
            zui.ui.theme_engine.profile.PlatformCaps.defaultForTarget(),
        );
        app.ui_scale = 1.0;
        app.config = config;
        app.ui_commands = zui.ui.render.command_list.CommandList.init(allocator);
        app.ui_inbox = ui_command_inbox.UiCommandInbox.init(allocator);
        app.frame_clock = zapp.frame_clock.FrameClock.init(60);
        app.ascii_glyph_width_cache = [_]f32{-1.0} ** 128;
        app.running = true;
        app.text_edit_history_field = .none;
        app.active_pointer_layer = .base;
        app.frame_dt_seconds = 1.0 / 60.0;
        app.fs.next_fsrpc_tag = 1;
        app.fs.next_fsrpc_fid = 2;
        app.credential_store = credential_store;
        app.launch_uses_env_token = launch_token != null;
        app.configurePerfAutomationFromEnv();
        app.ws.launcher_project_filter.appendSlice(allocator, "") catch {};
        app.ws.launcher_profile_name.appendSlice(allocator, "") catch {};
        app.ws.launcher_profile_metadata.appendSlice(allocator, "") catch {};
        app.ws.launcher_connect_token.appendSlice(allocator, "") catch {};
        app.syncLauncherSelectionFromConfig();
        app.applyLauncherSelectedProfile() catch {};
        app.launch_context = app.parseLaunchContextFromEnv();
        errdefer if (app.launch_context) |*context| context.deinit(allocator);
        app.applyLaunchContextSelection();
        app.debug.node_service_watch_filter.appendSlice(allocator, "") catch {};
        app.debug.node_service_watch_replay_limit.appendSlice(allocator, "25") catch {};
        app.debug.debug_search_filter.appendSlice(allocator, "") catch {};
        app.perf_benchmark_label_input.appendSlice(allocator, "") catch {};
        app.fs.contract_invoke_payload.appendSlice(allocator, "{}") catch {};
        app.refreshThemePackEntries();
        app.applyThemeSettings(false);
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
        try app.fs.filesystem_path.appendSlice(allocator, "/");

        if (app.config.default_session) |default_session| {
            const seed = if (default_session.len > 0) default_session else "main";
            app.ensureSessionExists(seed, seed) catch {};
        } else {
            app.ensureSessionExists("main", "Main") catch {};
        }

        const main_window = try app.createUiWindowFromExisting(
            window,
            "Spider Legacy Runtime",
            &app.manager,
            true,
            false,
            false,
            false,
        );
        try app.ui_windows.append(allocator, main_window);
        app.main_window_id = main_window.id;
        _ = c.SDL_SetWindowTitle(window, platformWindowTitle("Spider Legacy Runtime - Launcher"));

        errdefer allocator.free(app.status_text);
        errdefer app.settings_panel.deinit(allocator);

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
        if (self.app_local_venom_host) |*host| {
            host.deinit();
            self.app_local_venom_host = null;
        }
        self.disconnect();
        self.clearSessions();
        self.chat.chat_sessions.deinit(self.allocator);
        self.chat.session_messages.deinit(self.allocator);
        workspace_types.deinitWorkspaceList(self.allocator, &self.ws.projects);
        workspace_types.deinitNodeList(self.allocator, &self.ws.nodes);
        if (self.ws.workspace_state) |*status| {
            status.deinit(self.allocator);
            self.ws.workspace_state = null;
        }
        if (self.ws.workspace_last_error) |value| {
            self.allocator.free(value);
            self.ws.workspace_last_error = null;
        }
        if (self.ws.selected_workspace_detail) |*detail| {
            detail.deinit(self.allocator);
            self.ws.selected_workspace_detail = null;
        }
        self.stopFilesystemWorker();
        self.fs.filesystem_active_request = null;
        self.clearPendingFilesystemPathLoad();
        self.clearFsrpcRemoteError();
        self.clearDebugStreamSnapshot();
        self.clearDebugEvents();
        self.debug.debug_events.deinit(self.allocator);
        self.debug.debug_filtered_indices.deinit(self.allocator);
        self.debug.debug_folded_blocks.deinit();
        self.debug.debug_event_fingerprint_set.deinit(self.allocator);
        self.invalidateWorkspaceSnapshot();
        if (self.chat.pending_send_request_id) |request_id| self.allocator.free(request_id);
        if (self.chat.pending_send_message_id) |message_id| self.allocator.free(message_id);
        if (self.chat.pending_send_session_key) |session_key| self.allocator.free(session_key);
        if (self.chat.pending_send_job_id) |job_id| self.allocator.free(job_id);
        if (self.chat.pending_send_jobs_root) |jobs_root| self.allocator.free(jobs_root);
        if (self.chat.pending_send_thoughts_root) |thoughts_root| self.allocator.free(thoughts_root);
        if (self.chat.pending_send_correlation_id) |corr| self.allocator.free(corr);
        if (self.chat.pending_send_thought_message_id) |message_id| self.allocator.free(message_id);
        if (self.chat.pending_send_last_thought_text) |thought| self.allocator.free(thought);
        self.clearFilesystemData();
        self.clearFilesystemDirCache();
        self.fs.filesystem_path.deinit(self.allocator);
        self.clearContractServices();
        self.fs.contract_invoke_payload.deinit(self.allocator);
        self.clearVenomEntries();
        if (self.ws.venom_last_error) |v| self.allocator.free(v);
        self.clearMcpEntries();
        if (self.ws.mcp_last_error) |v| self.allocator.free(v);
        if (self.ws.mcp_selected_runtime) |v| self.allocator.free(v);
        self.closeWorkspaceWizard();
        self.clearTerminalState();
        self.clearTerminalTarget();
        self.terminal.terminal_input.deinit(self.allocator);
        self.terminal.terminal_backend.deinit(self.allocator);
        self.debug.node_service_watch_filter.deinit(self.allocator);
        self.debug.node_service_watch_replay_limit.deinit(self.allocator);
        self.debug.debug_search_filter.deinit(self.allocator);
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

        zui.ChatView(ChatMessage).deinit(&self.chat.chat_panel_state.view, self.allocator);

        self.settings_panel.deinit(self.allocator);
        self.chat.chat_input.deinit(self.allocator);
        self.ws.launcher_project_filter.deinit(self.allocator);
        self.ws.launcher_profile_name.deinit(self.allocator);
        self.ws.launcher_profile_metadata.deinit(self.allocator);
        self.ws.launcher_connect_token.deinit(self.allocator);
        workspace_types.deinitWorkspaceTemplateList(self.allocator, &self.ws.launcher_create_templates);
        if (self.ws.launcher_create_modal_error) |value| self.allocator.free(value);
        if (self.ws.launcher_notice) |value| self.allocator.free(value);
        if (self.active_profile_id) |value| self.allocator.free(value);
        if (self.ws.active_workspace_id) |value| self.allocator.free(value);
        self.credential_store.deinit();
        self.client_context.deinit();
        self.agent_registry.deinit(self.allocator);
        self.clearThemePackEntries();
        self.shared_theme_engine.deinit();
        self.host_theme_engine.deinit();

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
        if (self.launch_context) |*context| context.deinit(self.allocator);
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

            self.pollThemePackWatcher();

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
                var themed_fb_w: c_int = 0;
                var themed_fb_h: c_int = 0;
                _ = c.SDL_GetWindowSizeInPixels(window.window, &themed_fb_w, &themed_fb_h);
                self.resolveThemeProfileForWindow(
                    @intCast(if (themed_fb_w > 0) themed_fb_w else 1),
                    @intCast(if (themed_fb_h > 0) themed_fb_h else 1),
                );
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
            if (self.chat.pending_send_job_id != null and self.ws_client != null and self.chat.pending_send_resume_notified) {
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

    fn parseLaunchTokenRole(value: []const u8) ?config_mod.Config.TokenRole {
        if (std.ascii.eqlIgnoreCase(value, "admin")) return .admin;
        if (std.ascii.eqlIgnoreCase(value, "user")) return .user;
        return null;
    }

    fn duplicateTrimmedEnvVarOwned(allocator: std.mem.Allocator, name: []const u8) ?[]u8 {
        const raw = std.process.getEnvVarOwned(allocator, name) catch return null;
        defer allocator.free(raw);
        const trimmed = std.mem.trim(u8, raw, " \t\r\n");
        if (trimmed.len == 0) return null;
        return allocator.dupe(u8, trimmed) catch null;
    }

    fn parseLaunchRoute(value: []const u8) ?HomeRoute {
        if (std.ascii.eqlIgnoreCase(value, "workspace")) return .workspace;
        if (std.ascii.eqlIgnoreCase(value, "devices")) return .devices;
        if (std.ascii.eqlIgnoreCase(value, "capabilities")) return .capabilities;
        if (std.ascii.eqlIgnoreCase(value, "explore")) return .explore;
        if (std.ascii.eqlIgnoreCase(value, "settings")) return .settings;
        return null;
    }

    fn parseLaunchAction(value: []const u8) LaunchAction {
        if (std.ascii.eqlIgnoreCase(value, "open_workspace")) return .open_workspace;
        if (std.ascii.eqlIgnoreCase(value, "open_devices")) return .open_devices;
        if (std.ascii.eqlIgnoreCase(value, "open_capabilities")) return .open_capabilities;
        if (std.ascii.eqlIgnoreCase(value, "open_explore")) return .open_explore;
        if (std.ascii.eqlIgnoreCase(value, "open_remote_terminal")) return .open_remote_terminal;
        if (std.ascii.eqlIgnoreCase(value, "open_settings")) return .open_settings;
        return .none;
    }

    fn duplicateTrimmedEnvVar(self: *App, name: []const u8) ?[]u8 {
        return duplicateTrimmedEnvVarOwned(self.allocator, name);
    }

    fn parseLaunchContextFromEnv(self: *App) ?LaunchContext {
        var context = LaunchContext{};
        var has_value = false;

        if (self.duplicateTrimmedEnvVar("SPIDERAPP_LAUNCH_PROFILE_ID")) |value| {
            context.profile_id = value;
            has_value = true;
        }
        if (self.duplicateTrimmedEnvVar("SPIDERAPP_LAUNCH_WORKSPACE_ID")) |value| {
            context.workspace_id = value;
            has_value = true;
        }
        if (self.duplicateTrimmedEnvVar("SPIDERAPP_LAUNCH_DEVICE_ID")) |value| {
            context.device_id = value;
            has_value = true;
        }
        if (self.duplicateTrimmedEnvVar("SPIDERAPP_LAUNCH_ROUTE")) |value| {
            defer self.allocator.free(value);
            if (parseLaunchRoute(value)) |route| {
                context.route = route;
                has_value = true;
            }
        }
        if (self.duplicateTrimmedEnvVar("SPIDERAPP_LAUNCH_ACTION")) |value| {
            defer self.allocator.free(value);
            const action = parseLaunchAction(value);
            if (action != .none) {
                context.action = action;
                has_value = true;
            }
        }

        if (!has_value) {
            if (context.profile_id) |value| self.allocator.free(value);
            if (context.workspace_id) |value| self.allocator.free(value);
            if (context.device_id) |value| self.allocator.free(value);
            return null;
        }
        return context;
    }

    fn launchContextRoute(context: LaunchContext) ?HomeRoute {
        if (context.route) |route| return route;
        return switch (context.action) {
            .open_workspace => .workspace,
            .open_devices => .devices,
            .open_capabilities => .capabilities,
            .open_explore => .explore,
            .open_remote_terminal => .workspace,
            .open_settings => .settings,
            .none => null,
        };
    }

    fn launchContextRequiresConnection(context: LaunchContext) bool {
        return context.action != .none;
    }

    fn applyLaunchContextSelection(self: *App) void {
        const context = self.launch_context orelse return;

        if (context.profile_id) |profile_id| {
            if (self.config.hasConnectionProfileId(profile_id)) {
                self.config.setSelectedProfileById(profile_id) catch {};
                self.syncLauncherSelectionFromConfig();
                self.applyLauncherSelectedProfile() catch {};
            }
        }

        if (launchContextRoute(context)) |route| {
            self.ws.home_route = route;
        }

        if (context.workspace_id) |workspace_id| {
            self.selectWorkspaceInSettings(workspace_id) catch {
                self.settings_panel.project_id.clearRetainingCapacity();
                self.settings_panel.project_id.appendSlice(self.allocator, workspace_id) catch {};
                self.config.setSelectedWorkspace(workspace_id) catch {};
            };
        }
        self.syncHomeOnboardingStage();
    }

    fn runLaunchContextAction(self: *App) void {
        const context = self.launch_context orelse return;
        if (context.action == .none) return;
        if (self.connection_state != .connected) {
            self.setLauncherNotice("Connect to Spiderweb before opening the requested workspace view.");
            return;
        }
        if (context.action == .open_remote_terminal) {
            self.openRemoteTerminalForSelectedWorkspace(context.device_id) catch |err| {
                const msg = self.formatFilesystemOpError("Open remote terminal", err);
                if (msg) |text| {
                    defer self.allocator.free(text);
                    self.setLauncherNotice(text);
                } else {
                    self.setLauncherNotice("Unable to open the requested remote terminal.");
                }
            };
            return;
        }
        self.openSelectedHomeRoute() catch |err| {
            const msg = self.formatControlOpError("Open workspace route", err);
            if (msg) |text| {
                defer self.allocator.free(text);
                self.setLauncherNotice(text);
            } else {
                self.setLauncherNotice("Unable to open the requested workspace view.");
            }
        };
    }

    fn packageCount(self: *const App) usize {
        return @max(self.package_manager_packages.items.len, self.ws.venom_entries.items.len);
    }

    fn markWorkflowCompleted(self: *App, profile_id: []const u8, workspace_id: ?[]const u8, workflow_id: []const u8) void {
        self.config.markWorkflowCompleted(profile_id, workspace_id, workflow_id) catch return;
        self.config.save() catch {};
    }

    fn syncCompletedOnboardingWorkflowsFromLiveState(self: *App) void {
        if (self.connection_state != .connected) return;

        const profile_id = self.config.selectedProfileId();
        const selected_workspace_id = self.selectedWorkspaceId() orelse if (self.ws.projects.items.len == 1)
            self.ws.projects.items[0].id
        else
            null;
        const package_count = self.packageCount();

        if (isProfileLikelyRemote(self.config.selectedProfile())) {
            self.markWorkflowCompleted(profile_id, null, workflow_connect_to_another_spiderweb);
        }
        if (self.ui_stage == .workspace and selected_workspace_id != null) {
            self.markWorkflowCompleted(profile_id, selected_workspace_id, workflow_start_local_workspace);
        }
        if (selected_workspace_id != null and self.ws.nodes.items.len > 1) {
            self.markWorkflowCompleted(profile_id, selected_workspace_id, workflow_add_second_device);
        }
        if (selected_workspace_id != null and package_count > 0) {
            self.markWorkflowCompleted(profile_id, selected_workspace_id, workflow_install_package);
        }
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
        if (!platformSupportsMultiWindow()) return error.UnsupportedPlatform;
        const width: c_int = 960;
        const height: c_int = 720;
        const title = try std.fmt.allocPrint(self.allocator, "Spider Legacy Runtime ({d})", .{self.ui_windows.items.len});
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
        self.mouse_scroll_y = 0;
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
                    self.mouse_scroll_y += mw.delta[1];
                    const mouse_pos = .{ self.mouse_x, self.mouse_y };
                    var handled_debug_scroll = self.debug.debug_output_rect.contains(mouse_pos);
                    if (!handled_debug_scroll) {
                        if (self.debug.debug_panel_id) |panel_id| {
                            handled_debug_scroll = self.isPanelFocused(manager, panel_id);
                        }
                    }
                    if (handled_debug_scroll) {
                        self.debug.debug_scroll_y -= mw.delta[1] * 40.0 * self.ui_scale;
                        if (self.debug.debug_scroll_y < 0.0) self.debug.debug_scroll_y = 0.0;
                        if (self.debug.debug_panel_id) |panel_id| {
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
            self.debug.debug_scrollbar_dragging = false;
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
                } else if (platformSupportsMultiWindow() and !dock_rect.contains(release_pos)) {
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
                    } else if (platformSupportsMultiWindow() and !dock_rect.contains(release_pos)) {
                        out.detach_panel_id = drag_panel_id;
                        out.focus_panel_id = drag_panel_id;
                    } else {
                        out.focus_panel_id = drag_panel_id;
                    }
                } else if (platformSupportsMultiWindow() and !dock_rect.contains(release_pos)) {
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
        if (!platformSupportsMultiWindow()) return;
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
        if (!platformSupportsMultiWindow()) return null;
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
        if (!platformSupportsMultiWindow()) return null;
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

    pub fn collectDockLayoutSafe(
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

        if (self.ws.workspace_recovery_failures >= WORKSPACE_RECOVERY_ATTEMPTS_BEFORE_SUSPEND) {
            if (self.shouldLogDebug(120) or self.shouldLogStartup()) {
                std.log.warn(
                    "ensureWindowManagerHealthy: recovery attempts exceeded, forcing safe reset",
                    .{},
                );
            }
            self.ws.workspace_recovery_failures = 0;
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

            if (!self.ws.workspace_snapshot_stale and self.ws.workspace_snapshot != null and !self.ws.workspace_snapshot_restore_attempted) {
                if (self.shouldLogDebug(120) or self.shouldLogStartup()) {
                    std.log.info("ensureWindowManagerHealthy: trying snapshot restore during recovery", .{});
                }
                if (self.debug_frame_counter >= self.ws.workspace_snapshot_restore_cooldown_until and
                    self.restoreWorkspaceFromSnapshot(manager))
                {
                    self.ws.workspace_snapshot_stale = false;
                    self.ws.workspace_snapshot_restore_attempted = false;
                    self.ws.workspace_recovery_failures = 0;
                    self.clearWorkspaceRecoveryCooldown();
                    self.clearWorkspaceRecoverySuspend();
                    self.ws.workspace_snapshot_restore_cooldown_until = self.debug_frame_counter + WORKSPACE_RECOVERY_COOLDOWN_FRAMES;
                    return true;
                }
                self.invalidateWorkspaceSnapshot();
                self.ws.workspace_snapshot_stale = true;
                self.ws.workspace_snapshot_restore_attempted = true;
                self.ws.workspace_snapshot_restore_cooldown_until = self.debug_frame_counter + WORKSPACE_RECOVERY_COOLDOWN_FRAMES;
                if (self.ws.workspace_recovery_failures < 250) self.ws.workspace_recovery_failures +%= 1;
                if (self.shouldLogDebug(120) or self.shouldLogStartup()) {
                    std.log.warn("ensureWindowManagerHealthy: snapshot restore failed; disabling repeated restore", .{});
                }
            } else if (self.ws.workspace_snapshot_stale) {
                if (self.shouldLogDebug(120) or self.shouldLogStartup()) {
                    std.log.warn(
                        "ensureWindowManagerHealthy: skipping restore because workspace snapshot is stale",
                        .{},
                    );
                }
                if (self.ws.workspace_recovery_failures < 250) self.ws.workspace_recovery_failures +%= 1;
            } else if (self.debug_frame_counter < self.ws.workspace_snapshot_restore_cooldown_until) {
                if (self.shouldLogDebug(120) or self.shouldLogStartup()) {
                    std.log.warn(
                        "ensureWindowManagerHealthy: snapshot restore cooldown active (frame {} < {})",
                        .{ self.debug_frame_counter, self.ws.workspace_snapshot_restore_cooldown_until },
                    );
                }
                if (self.ws.workspace_recovery_failures < 250) self.ws.workspace_recovery_failures +%= 1;
            }

            if (!self.resetManagerToDefaultSafe(manager)) {
                self.logWorkspaceState(manager, "invalid-after-reset", self.debug_frame_counter);
                if (self.shouldLogDebug(120) or self.shouldLogStartup()) {
                    std.log.err(
                        "ensureWindowManagerHealthy: reset did not produce a valid default workspace",
                        .{},
                    );
                }
                self.ws.workspace_recovery_failures +%= 1;
                self.suspendWorkspaceRecovery(manager);
                return false;
            }

            if (!self.isWorkspaceStateReasonable(manager) or manager.workspace.panels.items.len == 0) {
                self.logWorkspaceState(manager, "invalid-after-reset-verify", self.debug_frame_counter);
                self.ws.workspace_recovery_failures +%= 1;
                self.suspendWorkspaceRecovery(manager);
                self.resetWorkspaceToSafeEmpty(manager);
                return false;
            }

            self.captureWorkspaceSnapshot(manager);
            self.ws.workspace_recovery_failures = 0;
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
            if (self.ws.workspace_snapshot_stale and self.shouldLogDebug(600)) {
                std.log.warn("ensureWindowManagerHealthy: skipping snapshot capture while snapshot is stale", .{});
            }
        } else {
            self.suspendWorkspaceRecovery(manager);
        }

        if (self.isWorkspaceStateReasonable(manager) and self.ws.workspace_snapshot == null) {
            self.captureWorkspaceSnapshot(manager);
            self.ws.workspace_snapshot_restore_attempted = false;
        }

        return self.isWorkspaceStateReasonable(manager) and manager.workspace.panels.items.len > 0;
    }

    fn canRecoverManagerWorkspace(self: *App, manager: *panel_manager.PanelManager) bool {
        if (self.ws.workspace_recovery_blocked_until == 0) return true;
        if (self.ws.workspace_recovery_blocked_for_manager != @intFromPtr(manager)) return true;
        if (self.debug_frame_counter < self.ws.workspace_recovery_blocked_until) return false;
        self.ws.workspace_recovery_blocked_until = 0;
        self.ws.workspace_recovery_blocked_for_manager = 0;
        return true;
    }

    fn blockWorkspaceRecovery(self: *App, manager: *panel_manager.PanelManager) void {
        self.ws.workspace_recovery_blocked_for_manager = @intFromPtr(manager);
        self.ws.workspace_recovery_blocked_until = self.debug_frame_counter + WORKSPACE_RECOVERY_COOLDOWN_FRAMES;
    }

    fn isWorkspaceRecoverySuspended(self: *App, manager: *panel_manager.PanelManager) bool {
        if (self.ws.workspace_recovery_suspended_for_manager != @intFromPtr(manager)) return false;
        if (self.ws.workspace_recovery_suspended_until == 0) return true;
        if (self.debug_frame_counter < self.ws.workspace_recovery_suspended_until) return true;
        self.ws.workspace_recovery_suspended_for_manager = 0;
        self.ws.workspace_recovery_suspended_until = 0;
        return false;
    }

    fn suspendWorkspaceRecovery(self: *App, manager: *panel_manager.PanelManager) void {
        if (self.ws.workspace_recovery_suspended_for_manager == 0) {
            self.ws.workspace_recovery_suspended_for_manager = @intFromPtr(manager);
        }
        self.ws.workspace_recovery_suspended_until = self.debug_frame_counter + WORKSPACE_RECOVERY_SUSPEND_FRAMES;
        self.blockWorkspaceRecovery(manager);
    }

    fn clearWorkspaceRecoverySuspend(self: *App) void {
        if (self.ws.workspace_recovery_suspended_until != 0) {
            self.ws.workspace_recovery_suspended_until = 0;
            self.ws.workspace_recovery_suspended_for_manager = 0;
        }
    }

    fn resetWorkspaceToSafeEmpty(self: *App, manager: *panel_manager.PanelManager) void {
        self.tryDeinitWorkspaceForReset(manager);
        manager.workspace = workspace.Workspace.initEmpty(self.allocator);
        self.recomputeManagerNextId(manager);
    }

    fn clearWorkspaceRecoveryCooldown(self: *App) void {
        self.ws.workspace_recovery_blocked_until = 0;
        self.ws.workspace_recovery_blocked_for_manager = 0;
    }

    fn captureWorkspaceSnapshot(self: *App, manager: *panel_manager.PanelManager) void {
        if (!platformSupportsWorkspaceSnapshots()) return;
        if (!self.isWorkspaceStateReasonable(manager)) return;
        const snapshot = manager.workspace.toSnapshot(self.allocator) catch {
            if (self.shouldLogDebug(120) or self.shouldLogStartup()) {
                std.log.warn("captureWorkspaceSnapshot: unable to snapshot workspace", .{});
            }
            return;
        };
        if (self.ws.workspace_snapshot) |*previous| {
            previous.deinit(self.allocator);
        }
        self.ws.workspace_snapshot = snapshot;
        self.ws.workspace_snapshot_stale = false;
        self.ws.workspace_snapshot_restore_attempted = false;
    }

    fn invalidateWorkspaceSnapshot(self: *App) void {
        if (self.ws.workspace_snapshot) |*snapshot| {
            snapshot.deinit(self.allocator);
            self.ws.workspace_snapshot = null;
        }
        self.ws.workspace_snapshot_stale = true;
        self.ws.workspace_snapshot_restore_attempted = true;
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
        if (!platformSupportsWorkspaceSnapshots()) return false;
        const snapshot = self.ws.workspace_snapshot orelse return false;
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

    pub fn collectDockInteractionGeometry(
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

    pub fn shouldLogDebug(self: *App, every_frames: u64) bool {
        if (every_frames == 0) return false;
        return self.debug_frame_counter > 0 and (self.debug_frame_counter % every_frames) == 0;
    }

    pub fn shouldLogStartup(self: *App) bool {
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
        self.perf_last_ws_wait_ms = if (self.chat.awaiting_reply and self.chat.pending_send_started_at_ms > 0)
            @as(f32, @floatFromInt(@max(0, now_ms - self.chat.pending_send_started_at_ms)))
        else
            0.0;
        self.perf_last_fs_request_ms = if (self.fs.filesystem_active_request) |active|
            @as(f32, @floatFromInt(@max(0, now_ms - active.started_at_ms)))
        else
            self.fs.filesystem_last_request_duration_ms;
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
        if (!platformSupportsMultiWindow()) return;
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
        if (!platformSupportsMultiWindow()) return false;
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
        if (!platformSupportsMultiWindow()) return error.UnsupportedPlatform;
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
                const has_pending_send = self.chat.pending_send_message_id != null;
                self.debug.debug_stream_snapshot_pending = true;
                self.debug.debug_stream_snapshot_retry_at_ms = 0;
                self.clearDebugStreamSnapshot();
                self.stopFilesystemWorker();
                self.clearTerminalState();

                client.deinit();
                self.ws_client = null;
                self.mount_control_ready = false;
                self.session_attach_state = .unknown;
                self.setConnectionState(.error_state, "Connection lost. Please reconnect.");
                if (self.ui_stage == .workspace) {
                    self.returnToLauncher(.connection_lost);
                }
                if (has_pending_send) {
                    if (!self.chat.pending_send_resume_notified) {
                        if (self.chat.pending_send_job_id) |job_id| {
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
                        self.chat.pending_send_resume_notified = true;
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
                std.log.debug("[SpiderApp] Polled {d} messages this frame", .{count});
            }
        }
    }

    fn pollFilesystemWorker(self: *App) void {
        if (self.fs.filesystem_active_request != null) return;
        if (self.connection_state != .connected) return;
        const pending_path = self.fs.filesystem_pending_path orelse return;

        const now = std.time.milliTimestamp();
        if (now < self.fs.filesystem_pending_retry_at_ms) return;

        const path = self.allocator.dupe(u8, pending_path) catch return;
        defer self.allocator.free(path);
        const use_cache = self.fs.filesystem_pending_use_cache;
        const force_refresh = self.fs.filesystem_pending_force_refresh;
        self.clearPendingFilesystemPathLoad();
        self.queueFilesystemPathLoad(path, use_cache, force_refresh) catch |err| {
            if (err != error.Busy and err != error.NotConnected) {
                std.log.debug("filesystem pending load skipped: {s}", .{@errorName(err)});
            }
        };
    }

    fn pollDebugStream(self: *App) void {
        if (!self.debug.debug_stream_enabled) return;
        if (self.connection_state != .connected) return;
        if (self.fs.filesystem_active_request != null) return;
        if (self.chat.awaiting_reply or self.chat.pending_send_job_id != null) return;
        if (!self.debug.debug_stream_snapshot_pending) return;

        const now = std.time.milliTimestamp();
        if (now < self.debug.debug_stream_snapshot_retry_at_ms) return;

        self.submitFilesystemRequestWithMode(.read_file, DEBUG_STREAM_PATH, false, true) catch |err| {
            if (err != error.Busy and err != error.NotConnected) {
                std.log.debug("debug stream poll skipped: {s}", .{@errorName(err)});
            }
            self.debug.debug_stream_snapshot_pending = true;
            self.debug.debug_stream_snapshot_retry_at_ms = now + DEBUG_STREAM_SNAPSHOT_RETRY_MS;
            return;
        };
    }

    fn pollNodeServiceSnapshot(self: *App) void {
        if (!self.debug.node_service_watch_enabled) return;
        if (self.connection_state != .connected) return;
        if (self.fs.filesystem_active_request != null) return;
        if (self.chat.awaiting_reply or self.chat.pending_send_job_id != null) return;
        if (!self.debug.node_service_snapshot_pending) return;

        const now = std.time.milliTimestamp();
        if (now < self.debug.node_service_snapshot_retry_at_ms) return;

        self.submitFilesystemRequestWithMode(.read_file, NODE_SERVICE_EVENTS_PATH, false, true) catch |err| {
            if (err != error.Busy and err != error.NotConnected) {
                std.log.debug("node service snapshot poll skipped: {s}", .{@errorName(err)});
            }
            self.debug.node_service_snapshot_pending = true;
            self.debug.node_service_snapshot_retry_at_ms = now + NODE_SERVICE_SNAPSHOT_RETRY_MS;
            return;
        };
    }

    fn requestDebugStreamSnapshot(self: *App, immediate: bool) void {
        self.debug.debug_stream_snapshot_pending = true;
        if (immediate) {
            self.debug.debug_stream_snapshot_retry_at_ms = 0;
        } else if (self.debug.debug_stream_snapshot_retry_at_ms == 0) {
            self.debug.debug_stream_snapshot_retry_at_ms = std.time.milliTimestamp() + DEBUG_STREAM_SNAPSHOT_RETRY_MS;
        }
    }

    fn requestNodeServiceSnapshot(self: *App, immediate: bool) void {
        self.debug.node_service_snapshot_pending = true;
        if (immediate) {
            self.debug.node_service_snapshot_retry_at_ms = 0;
        } else if (self.debug.node_service_snapshot_retry_at_ms == 0) {
            self.debug.node_service_snapshot_retry_at_ms = std.time.milliTimestamp() + NODE_SERVICE_SNAPSHOT_RETRY_MS;
        }
    }

    fn handleFilesystemWorkerResult(self: *App, result: *const FilesystemRequestResult) void {
        const active = self.fs.filesystem_active_request orelse return;
        if (active.id != result.id) return;
        const request_finished_ms = std.time.milliTimestamp();
        const request_duration_ms: f32 = @as(f32, @floatFromInt(@max(0, request_finished_ms - active.started_at_ms)));

        self.fs.filesystem_active_request = null;
        if (!active.is_background) self.fs.filesystem_busy = false;
        if (!active.is_background) {
            self.fs.filesystem_last_request_duration_ms = request_duration_ms;
        }

        const is_debug_stream_result = std.mem.eql(u8, result.path, DEBUG_STREAM_PATH);
        if (is_debug_stream_result) {
            if (result.error_text) |_| {
                self.debug.debug_stream_snapshot_pending = true;
                self.debug.debug_stream_snapshot_retry_at_ms = std.time.milliTimestamp() + DEBUG_STREAM_SNAPSHOT_RETRY_MS;
                return;
            }
            const content = result.content orelse {
                self.debug.debug_stream_snapshot_pending = true;
                self.debug.debug_stream_snapshot_retry_at_ms = std.time.milliTimestamp() + DEBUG_STREAM_SNAPSHOT_RETRY_MS;
                return;
            };
            self.mergeDebugStreamSnapshot(content) catch |err| {
                std.log.warn("debug stream merge failed: {s}", .{@errorName(err)});
            };
            // Keep polling while debug stream is enabled so new events arrive
            // without requiring manual refresh.
            self.debug.debug_stream_snapshot_pending = true;
            self.debug.debug_stream_snapshot_retry_at_ms = std.time.milliTimestamp() + DEBUG_STREAM_SNAPSHOT_RETRY_MS;
            return;
        }

        const is_node_service_snapshot = std.mem.eql(u8, result.path, NODE_SERVICE_EVENTS_PATH);
        if (is_node_service_snapshot) {
            if (result.error_text) |_| {
                if (self.debug.node_service_watch_enabled) {
                    self.debug.node_service_snapshot_pending = true;
                    self.debug.node_service_snapshot_retry_at_ms = std.time.milliTimestamp() + NODE_SERVICE_SNAPSHOT_RETRY_MS;
                }
                return;
            }
            const content = result.content orelse {
                if (self.debug.node_service_watch_enabled) {
                    self.debug.node_service_snapshot_pending = true;
                    self.debug.node_service_snapshot_retry_at_ms = std.time.milliTimestamp() + NODE_SERVICE_SNAPSHOT_RETRY_MS;
                }
                return;
            };
            self.ingestNodeServiceSnapshotLines(content) catch |err| {
                std.log.warn("node service snapshot merge failed: {s}", .{@errorName(err)});
            };
            if (self.debug.node_service_watch_enabled) {
                self.debug.node_service_snapshot_pending = true;
                self.debug.node_service_snapshot_retry_at_ms = std.time.milliTimestamp() + NODE_SERVICE_SNAPSHOT_RETRY_MS;
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
                    if (self.fs.filesystem_selected_path) |selected| {
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
        if (storage.isAndroid()) return;
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
        if (storage.isAndroid()) return;
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
            .launcher_project_filter => &self.ws.launcher_project_filter,
            .launcher_profile_name => &self.ws.launcher_profile_name,
            .launcher_profile_metadata => &self.ws.launcher_profile_metadata,
            .launcher_connect_token => &self.ws.launcher_connect_token,
            .project_token => &self.settings_panel.project_token,
            .project_create_name => &self.settings_panel.project_create_name,
            .project_create_vision => &self.settings_panel.project_create_vision,
            .workspace_template_id => &self.settings_panel.workspace_template_id,
            .project_operator_token => &self.settings_panel.project_operator_token,
            .project_mount_path => &self.settings_panel.project_mount_path,
            .project_mount_node_id => &self.settings_panel.project_mount_node_id,
            .project_mount_export_name => &self.settings_panel.project_mount_export_name,
            .workspace_bind_path => &self.settings_panel.workspace_bind_path,
            .workspace_bind_target_path => &self.settings_panel.workspace_bind_target_path,
            .default_session => &self.settings_panel.default_session,
            .default_agent => &self.settings_panel.default_agent,
            .theme_pack => &self.settings_panel.theme_pack,
            .node_watch_filter => &self.debug.node_service_watch_filter,
            .node_watch_replay_limit => &self.debug.node_service_watch_replay_limit,
            .debug_search_filter => &self.debug.debug_search_filter,
            .perf_benchmark_label => &self.perf_benchmark_label_input,
            .filesystem_contract_payload => &self.fs.contract_invoke_payload,
            .package_manager_install_payload => &self.package_manager_install_payload,
            .about_modal_build_label => &self.about_modal_build_label,
            .terminal_command_input => &self.terminal.terminal_input,
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
                if (platformSupportsMultiWindow() and key_evt.mods.ctrl and !key_evt.repeat) {
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
                if (key_evt.mods.ctrl and !key_evt.repeat and self.debug.debug_selected_index != null) {
                    var allow_copy = false;
                    if (self.debug.debug_panel_id != null and self.isPanelFocused(manager, self.debug.debug_panel_id.?)) {
                        allow_copy = true;
                    }
                    // Also allow Ctrl+C when mouse is over the debug output area
                    if (self.debug.debug_output_rect.contains(.{ self.mouse_x, self.mouse_y })) {
                        allow_copy = true;
                    }
                    if (allow_copy) {
                        if (self.debug.debug_selected_index) |sel_idx| {
                            if (sel_idx < self.debug.debug_events.items.len) {
                                const entry = self.debug.debug_events.items[sel_idx];
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
                if (self.debug.debug_panel_id) |panel_id| {
                    if (self.isPanelFocused(manager, panel_id)) {
                        self.debug.debug_scroll_y -= 200.0 * self.ui_scale;
                        if (self.debug.debug_scroll_y < 0.0) self.debug.debug_scroll_y = 0.0;
                    }
                }
                if (self.focusedFormScrollY(manager)) |scroll_y| {
                    scroll_y.* -= 200.0 * self.ui_scale;
                    if (scroll_y.* < 0.0) scroll_y.* = 0.0;
                }
            },
            .page_down => {
                if (self.debug.debug_panel_id) |panel_id| {
                    if (self.isPanelFocused(manager, panel_id)) {
                        self.debug.debug_scroll_y += 200.0 * self.ui_scale;
                    }
                }
                if (self.focusedFormScrollY(manager)) |scroll_y| {
                    scroll_y.* += 200.0 * self.ui_scale;
                }
            },
            .home => {
                if (self.debug.debug_panel_id) |panel_id| {
                    if (self.isPanelFocused(manager, panel_id)) {
                        self.debug.debug_scroll_y = 0.0;
                    }
                }
                if (self.focusedFormScrollY(manager)) |scroll_y| {
                    scroll_y.* = 0.0;
                }
            },
            .end => {
                if (self.debug.debug_panel_id) |panel_id| {
                    if (self.isPanelFocused(manager, panel_id)) {
                        // Move far down; clamped during render
                        self.debug.debug_scroll_y += 1_000_000.0;
                    }
                }
                if (self.focusedFormScrollY(manager)) |scroll_y| {
                    // Move far down; clamped during render
                    scroll_y.* += 1_000_000.0;
                }
            },
            .up_arrow => {
                if (self.debug.debug_panel_id) |panel_id| {
                    if (self.isPanelFocused(manager, panel_id)) {
                        self.debug.debug_scroll_y -= 40.0 * self.ui_scale;
                        if (self.debug.debug_scroll_y < 0.0) self.debug.debug_scroll_y = 0.0;
                    }
                }
                if (self.focusedFormScrollY(manager)) |scroll_y| {
                    scroll_y.* -= 40.0 * self.ui_scale;
                    if (scroll_y.* < 0.0) scroll_y.* = 0.0;
                }
            },
            .down_arrow => {
                if (self.debug.debug_panel_id) |panel_id| {
                    if (self.isPanelFocused(manager, panel_id)) {
                        self.debug.debug_scroll_y += 40.0 * self.ui_scale;
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
        try self.config.setSelectedWorkspace(
            if (self.settings_panel.project_id.items.len > 0)
                self.settings_panel.project_id.items
            else
                null,
        );
        if (self.settings_panel.project_id.items.len > 0) {
            try self.config.setWorkspaceToken(
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
        self.config.setThemeMode(configThemeModeFromSettings(self.settings_panel.theme_mode));
        self.config.setThemeProfile(configThemeProfileFromSettings(self.settings_panel.theme_profile));
        try self.config.setThemePack(if (self.settings_panel.theme_pack.items.len > 0) self.settings_panel.theme_pack.items else null);
        _ = self.config.rememberThemePack(self.effectiveThemePackPath());
        self.config.setWatchThemePack(self.settings_panel.watch_theme_pack and themePackWatchSupported());
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
        self.applyThemeSettings(false);
    }

    fn clearWorkspaceData(self: *App) void {
        workspace_types.deinitWorkspaceList(self.allocator, &self.ws.projects);
        workspace_types.deinitNodeList(self.allocator, &self.ws.nodes);
        self.ws.workspace_selector_open = false;
        self.ws.launcher_create_modal_open = false;
        self.ws.launcher_create_selected_template_index = 0;
        self.ws.launcher_create_template_page = 0;
        workspace_types.deinitWorkspaceTemplateList(self.allocator, &self.ws.launcher_create_templates);
        if (self.ws.launcher_create_modal_error) |value| {
            self.allocator.free(value);
            self.ws.launcher_create_modal_error = null;
        }
        self.clearConnectSetupHint();
        if (self.ws.workspace_state) |*status| {
            status.deinit(self.allocator);
            self.ws.workspace_state = null;
        }
        if (self.ws.workspace_last_error) |value| {
            self.allocator.free(value);
            self.ws.workspace_last_error = null;
        }
        self.ws.workspace_last_refresh_ms = 0;
        if (self.ws.selected_workspace_detail) |*detail| {
            detail.deinit(self.allocator);
            self.ws.selected_workspace_detail = null;
        }
        self.ws.workspace_selected_mount_index = null;
        self.ws.workspace_selected_bind_index = null;
        self.clearMissionDashboardData();
    }

    fn clearMissionDashboardData(self: *App) void {
        for (self.mission.records.items) |*mission| mission.deinit(self.allocator);
        self.mission.records.deinit(self.allocator);
        self.mission.records = .{};
        if (self.mission.selected_id) |value| {
            self.allocator.free(value);
            self.mission.selected_id = null;
        }
        if (self.mission.last_error) |value| {
            self.allocator.free(value);
            self.mission.last_error = null;
        }
        self.mission.last_refresh_ms = 0;
        self.client_context.clearWorkboardItems();
        self.client_context.clearApprovals();
        self.client_context.clearPendingWorkboardRequest();
        self.client_context.clearPendingApprovalResolveRequest();
    }

    pub fn setMissionDashboardError(self: *App, message: []const u8) void {
        if (self.mission.last_error) |value| {
            self.allocator.free(value);
            self.mission.last_error = null;
        }
        self.mission.last_error = self.allocator.dupe(u8, message) catch null;
    }

    fn clearMissionDashboardError(self: *App) void {
        if (self.mission.last_error) |value| {
            self.allocator.free(value);
            self.mission.last_error = null;
        }
    }

    fn clearFilesystemEntries(self: *App) void {
        for (self.fs.filesystem_entries.items) |*entry| entry.deinit(self.allocator);
        self.fs.filesystem_entries.deinit(self.allocator);
        self.fs.filesystem_entries = .{};
    }

    fn setFilesystemSelectedPath(self: *App, path: ?[]const u8) void {
        if (self.fs.filesystem_selected_path) |value| {
            self.allocator.free(value);
            self.fs.filesystem_selected_path = null;
        }
        if (path) |value| {
            self.fs.filesystem_selected_path = self.allocator.dupe(u8, value) catch null;
        }
    }

    fn clearFilesystemPreviewState(self: *App) void {
        if (self.fs.filesystem_preview_path) |value| {
            self.allocator.free(value);
            self.fs.filesystem_preview_path = null;
        }
        if (self.fs.filesystem_preview_text) |value| {
            self.allocator.free(value);
            self.fs.filesystem_preview_text = null;
        }
        if (self.fs.filesystem_preview_status) |value| {
            self.allocator.free(value);
            self.fs.filesystem_preview_status = null;
        }
        self.fs.filesystem_preview_mode = .empty;
        self.fs.filesystem_preview_kind = .unknown;
        self.fs.filesystem_preview_size_bytes = null;
        self.fs.filesystem_preview_modified_unix_ms = null;
    }

    fn clearFilesystemData(self: *App) void {
        self.clearFilesystemEntries();
        self.setFilesystemSelectedPath(null);
        self.clearFilesystemPreviewState();
        self.fs.filesystem_entry_page = 0;
        self.fs.filesystem_last_clicked_entry_index = null;
        self.fs.filesystem_last_click_ms = 0;
        if (self.fs.filesystem_error) |value| {
            self.allocator.free(value);
            self.fs.filesystem_error = null;
        }
    }

    fn clearContractServices(self: *App) void {
        for (self.fs.contract_services.items) |*entry| entry.deinit(self.allocator);
        self.fs.contract_services.deinit(self.allocator);
        self.fs.contract_services = .{};
        self.fs.contract_service_selected_index = 0;
    }

    fn setFilesystemError(self: *App, message: []const u8) void {
        if (self.fs.filesystem_error) |value| {
            self.allocator.free(value);
            self.fs.filesystem_error = null;
        }
        self.fs.filesystem_error = self.allocator.dupe(u8, message) catch null;
    }

    fn clearFilesystemError(self: *App) void {
        if (self.fs.filesystem_error) |value| {
            self.allocator.free(value);
            self.fs.filesystem_error = null;
        }
    }

    pub fn setTerminalStatus(self: *App, message: []const u8) void {
        if (self.terminal.terminal_status) |value| {
            self.allocator.free(value);
            self.terminal.terminal_status = null;
        }
        self.terminal.terminal_status = self.allocator.dupe(u8, message) catch null;
    }

    fn clearTerminalStatus(self: *App) void {
        if (self.terminal.terminal_status) |value| {
            self.allocator.free(value);
            self.terminal.terminal_status = null;
        }
    }

    pub fn setTerminalError(self: *App, message: []const u8) void {
        if (self.terminal.terminal_error) |value| {
            self.allocator.free(value);
            self.terminal.terminal_error = null;
        }
        self.terminal.terminal_error = self.allocator.dupe(u8, message) catch null;
    }

    pub fn clearTerminalError(self: *App) void {
        if (self.terminal.terminal_error) |value| {
            self.allocator.free(value);
            self.terminal.terminal_error = null;
        }
    }

    fn clearTerminalTarget(self: *App) void {
        if (self.terminal.terminal_target_node_id) |value| {
            self.allocator.free(value);
            self.terminal.terminal_target_node_id = null;
        }
        if (self.terminal.terminal_target_label) |value| {
            self.allocator.free(value);
            self.terminal.terminal_target_label = null;
        }
        if (self.terminal.terminal_service_root) |value| {
            self.allocator.free(value);
            self.terminal.terminal_service_root = null;
        }
        if (self.terminal.terminal_control_root) |value| {
            self.allocator.free(value);
            self.terminal.terminal_control_root = null;
        }
    }

    fn clearTerminalState(self: *App) void {
        if (self.terminal.terminal_session_id) |value| {
            self.allocator.free(value);
            self.terminal.terminal_session_id = null;
        }
        self.terminal.terminal_next_poll_at_ms = 0;
        self.clearTerminalStatus();
        self.clearTerminalError();
    }

    fn applySelectedTerminalBackend(self: *App) void {
        const next_kind = self.settings_panel.terminal_backend_kind;
        if (self.terminal.terminal_backend_kind == next_kind) return;

        const snapshot = self.allocator.dupe(u8, self.terminal.terminal_backend.text()) catch null;
        defer if (snapshot) |value| self.allocator.free(value);

        self.terminal.terminal_backend.deinit(self.allocator);
        self.terminal.terminal_backend = initTerminalBackend(next_kind);
        self.terminal.terminal_backend_kind = next_kind;

        if (snapshot) |value| {
            _ = self.terminal.terminal_backend.appendBytes(self.allocator, value) catch {};
        }

        const status = std.fmt.allocPrint(
            self.allocator,
            "Terminal backend switched to {s}",
            .{terminal_render_backend.Backend.kindName(self.terminal.terminal_backend_kind)},
        ) catch null;
        defer if (status) |value| self.allocator.free(value);
        self.setTerminalStatus(status orelse "Terminal backend switched");
    }

    fn clearFilesystemDirCache(self: *App) void {
        var it = self.fs.filesystem_dir_cache.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(self.allocator);
        }
        self.fs.filesystem_dir_cache.deinit(self.allocator);
        self.fs.filesystem_dir_cache = .{};
    }

    fn clearPendingFilesystemPathLoad(self: *App) void {
        if (self.fs.filesystem_pending_path) |value| {
            self.allocator.free(value);
            self.fs.filesystem_pending_path = null;
        }
        self.fs.filesystem_pending_use_cache = false;
        self.fs.filesystem_pending_force_refresh = false;
        self.fs.filesystem_pending_retry_at_ms = 0;
    }

    fn schedulePendingFilesystemPathLoad(self: *App, path: []const u8, use_cache: bool, force_refresh: bool) void {
        self.clearPendingFilesystemPathLoad();
        self.fs.filesystem_pending_path = self.allocator.dupe(u8, path) catch null;
        self.fs.filesystem_pending_use_cache = use_cache;
        self.fs.filesystem_pending_force_refresh = force_refresh;
        self.fs.filesystem_pending_retry_at_ms = std.time.milliTimestamp() + 50;
    }

    pub fn requestFilesystemBrowserRefresh(self: *App, force_refresh: bool) void {
        const current_path = if (self.fs.filesystem_path.items.len > 0) self.fs.filesystem_path.items else "/";
        self.schedulePendingFilesystemPathLoad(current_path, false, force_refresh);
        self.fs.filesystem_pending_retry_at_ms = 0;
        self.pollFilesystemWorker();
    }

    fn invalidateFilesystemDirCachePath(self: *App, path: []const u8) void {
        if (self.fs.filesystem_dir_cache.fetchRemove(path)) |removed| {
            self.allocator.free(removed.key);
            var value = removed.value;
            value.deinit(self.allocator);
        }
    }

    fn putFilesystemDirCache(self: *App, path: []const u8, listing: []const u8) !void {
        if (self.fs.filesystem_dir_cache.getEntry(path)) |entry| {
            entry.value_ptr.deinit(self.allocator);
            entry.value_ptr.* = .{
                .listing = try self.allocator.dupe(u8, listing),
                .cached_at_ms = std.time.milliTimestamp(),
            };
            return;
        }

        const key_copy = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(key_copy);
        try self.fs.filesystem_dir_cache.put(self.allocator, key_copy, .{
            .listing = try self.allocator.dupe(u8, listing),
            .cached_at_ms = std.time.milliTimestamp(),
        });
    }

    fn cachedFilesystemListing(self: *App, path: []const u8) ?[]const u8 {
        const now_ms = std.time.milliTimestamp();
        if (self.fs.filesystem_dir_cache.getEntry(path)) |entry| {
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
        self.fs.filesystem_busy = false;
        self.fs.filesystem_active_request = null;
        self.clearFilesystemError();
    }

    fn stopFilesystemWorker(self: *App) void {
        self.fs.filesystem_busy = false;
        self.fs.filesystem_active_request = null;
    }

    fn resetFsrpcConnectionState(self: *App) void {
        self.fs.fsrpc_ready = false;
        self.fs.next_fsrpc_tag = 1;
        self.fs.next_fsrpc_fid = 2;
        self.clearFsrpcRemoteError();
    }

    fn invalidateFsrpcAttachment(self: *App) void {
        self.fs.fsrpc_ready = false;
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
        if (is_background and (self.chat.awaiting_reply or self.chat.pending_send_job_id != null)) {
            return error.Busy;
        }
        if (self.fs.filesystem_active_request != null) return error.Busy;
        const client = if (self.ws_client) |*value| value else return error.NotConnected;
        const request_id = self.fs.filesystem_next_request_id;
        self.fs.filesystem_next_request_id +%= 1;
        if (self.fs.filesystem_next_request_id == 0) self.fs.filesystem_next_request_id = 1;

        self.fs.filesystem_active_request = .{
            .id = request_id,
            .kind = kind,
            .open_after_resolve = open_after_resolve,
            .is_background = is_background,
            .started_at_ms = std.time.milliTimestamp(),
        };
        if (!is_background) self.fs.filesystem_busy = true;

        var request_completed = false;
        errdefer {
            if (!request_completed) {
                self.fs.filesystem_active_request = null;
                if (!is_background) self.fs.filesystem_busy = false;
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
        var snapshot = try self.mountAttachSnapshotGui(client, path, 1);
        defer snapshot.deinit(self.allocator);

        const root_info = try self.mountSnapshotRootInfo(snapshot.parsed.value.object);
        if (root_info.info.kind != .directory) return error.NotDir;
        return self.buildMountDirectoryListingText(root_info.root_node_id, snapshot.parsed.value.object);
    }

    fn readFilesystemFileGui(
        self: *App,
        client: *ws_client_mod.WebSocketClient,
        path: []const u8,
    ) ![]u8 {
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
        for (self.fs.filesystem_entries.items) |*entry| {
            if (std.mem.eql(u8, entry.path, path)) return entry;
        }
        return null;
    }

    fn selectedFilesystemEntry(self: *App) ?*FilesystemEntry {
        const selected = self.fs.filesystem_selected_path orelse return null;
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
        self.fs.filesystem_preview_path = try self.allocator.dupe(u8, path);
        self.fs.filesystem_preview_kind = kind;
        self.fs.filesystem_preview_size_bytes = size_bytes;
        self.fs.filesystem_preview_modified_unix_ms = modified_unix_ms;
        self.fs.filesystem_preview_mode = mode;
        self.fs.filesystem_preview_status = try self.allocator.dupe(u8, status);
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
        const previous_selected_path = if (self.fs.filesystem_selected_path) |value|
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

            try self.fs.filesystem_entries.append(self.allocator, entry);
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
        self.fs.filesystem_preview_path = try self.allocator.dupe(u8, path);

        if (self.findFilesystemEntryByPath(path)) |entry| {
            self.fs.filesystem_preview_kind = entry.kind;
            self.fs.filesystem_preview_size_bytes = entry.size_bytes orelse content.len;
            self.fs.filesystem_preview_modified_unix_ms = entry.modified_unix_ms;
        } else {
            self.fs.filesystem_preview_kind = .file;
            self.fs.filesystem_preview_size_bytes = content.len;
        }

        const preview_mode = inferFilesystemPreviewMode(path, content);
        self.fs.filesystem_preview_mode = preview_mode;
        switch (preview_mode) {
            .text => {
                self.fs.filesystem_preview_status = try self.allocator.dupe(u8, "Text preview");
                self.fs.filesystem_preview_text = try self.truncateFilesystemPreviewText(content);
            },
            .json => {
                self.fs.filesystem_preview_status = try self.allocator.dupe(u8, "JSON preview");
                self.fs.filesystem_preview_text = try self.truncateFilesystemPreviewText(content);
            },
            .empty => {
                self.fs.filesystem_preview_status = try self.allocator.dupe(u8, "Empty file");
            },
            .unsupported => {
                self.fs.filesystem_preview_status = try self.allocator.dupe(u8, "Preview unavailable for binary or unsupported content.");
            },
            .loading => {},
        }
    }

    fn setFsrpcRemoteError(self: *App, message: []const u8) void {
        self.clearFsrpcRemoteError();
        self.fs.fsrpc_last_remote_error = self.allocator.dupe(u8, message) catch null;
    }

    fn clearFsrpcRemoteError(self: *App) void {
        if (self.fs.fsrpc_last_remote_error) |value| {
            self.allocator.free(value);
            self.fs.fsrpc_last_remote_error = null;
        }
    }

    pub fn formatFilesystemOpError(self: *App, operation: []const u8, err: anyerror) ?[]u8 {
        if (err == error.RemoteError or err == error.RuntimeWarming) {
            if (self.fs.fsrpc_last_remote_error) |remote| {
                return std.fmt.allocPrint(self.allocator, "{s}: {s}", .{ operation, remote }) catch null;
            }
        }
        return std.fmt.allocPrint(self.allocator, "{s}: {s}", .{ operation, @errorName(err) }) catch null;
    }

    fn controlAuthHintForRemote(self: *App, remote: []const u8) ?[]u8 {
        if (std.mem.indexOf(u8, remote, "workspace_auth_failed") != null) {
            return self.allocator.dupe(
                u8,
                "Workspace access denied. If the workspace is locked, provide its Workspace Token.",
            ) catch null;
        }
        if (std.mem.indexOf(u8, remote, "workspace_not_found") != null) {
            return self.allocator.dupe(
                u8,
                "Selected workspace no longer exists. Clear workspace selection and reconnect.",
            ) catch null;
        }
        if (std.mem.indexOf(u8, remote, "workspace_assignment_forbidden") != null) {
            return self.allocator.dupe(
                u8,
                "This agent is not allowed on that workspace (the system workspace is Spiderweb-only).",
            ) catch null;
        }
        if (std.mem.indexOf(u8, remote, "control_plane_error") != null and
            std.mem.indexOf(u8, remote, "SyntaxError") != null)
        {
            return self.allocator.dupe(
                u8,
                "Selected workspace settings are invalid for this server. Clear workspace/token in Settings and retry.",
            ) catch null;
        }
        if (std.mem.indexOf(u8, remote, "provisioning_required") != null) {
            return self.allocator.dupe(
                u8,
                "This user token has no non-system workspace/agent target. Ask an admin to provision one via Spiderweb.",
            ) catch null;
        }
        if (std.mem.indexOf(u8, remote, "last_target_invalid") != null) {
            return self.allocator.dupe(
                u8,
                "The remembered workspace/agent target is no longer valid. Ask an admin to re-provision access.",
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
                "Workspace observe policy denied this stream. Check access_policy.actions.observe and agent overrides.",
            ) catch null;
        }
        if (std.mem.indexOf(u8, remote, "watch requires a project-scoped session binding") != null) {
            return self.allocator.dupe(
                u8,
                "Attach the session to a workspace first (workspace selection + Attach Session).",
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

    pub fn formatControlOpError(self: *App, operation: []const u8, err: anyerror) ?[]u8 {
        if (err == error.RemoteError) {
            if (control_plane.lastRemoteError()) |remote| {
                return self.formatControlRemoteMessage(operation, remote);
            }
        }
        return std.fmt.allocPrint(self.allocator, "{s}: {s}", .{ operation, @errorName(err) }) catch null;
    }

    fn isWorkspaceAuthRemoteError(remote: []const u8) bool {
        return std.mem.indexOf(u8, remote, "workspace_auth_failed") != null or
            std.mem.indexOf(u8, remote, "WorkspaceAuthFailed") != null;
    }

    fn isSelectedWorkspaceAttachRemoteError(remote: []const u8) bool {
        if (isWorkspaceAuthRemoteError(remote)) return true;
        if (std.mem.indexOf(u8, remote, "workspace_not_found") != null) return true;
        if (std.mem.indexOf(u8, remote, "workspace_assignment_forbidden") != null) return true;
        if (std.mem.indexOf(u8, remote, "invalid workspace_id") != null) return true;
        if (std.mem.indexOf(u8, remote, "workspace_id is required") != null) return true;
        if (std.mem.indexOf(u8, remote, "invalid_payload") != null and
            std.mem.indexOf(u8, remote, "workspace_id") != null)
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

    fn clearSelectedWorkspaceAfterAttachFailure(self: *App) void {
        self.settings_panel.project_id.clearRetainingCapacity();
        self.settings_panel.project_token.clearRetainingCapacity();
        self.session_attach_state = .unknown;
        self.syncSettingsToConfig() catch |err| {
            std.log.warn("Failed to persist cleared selected workspace after attach failure: {s}", .{@errorName(err)});
        };
    }

    fn setWorkspaceError(self: *App, message: []const u8) void {
        if (self.ws.workspace_last_error) |value| {
            self.allocator.free(value);
            self.ws.workspace_last_error = null;
        }
        self.ws.workspace_last_error = self.allocator.dupe(u8, message) catch null;
    }

    fn clearWorkspaceError(self: *App) void {
        if (self.ws.workspace_last_error) |value| {
            self.allocator.free(value);
            self.ws.workspace_last_error = null;
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

        if (root.get("workspace_setup_required")) |value| {
            if (value != .bool) return error.InvalidResponse;
            hint.required = value.bool;
        }

        if (root.get("workspace_setup_message")) |value| {
            switch (value) {
                .string => hint.message = try self.allocator.dupe(u8, value.string),
                .null => {},
                else => return error.InvalidResponse,
            }
        }

        if (root.get("workspace_setup_workspace_id")) |value| {
            switch (value) {
                .string => hint.workspace_id = try self.allocator.dupe(u8, value.string),
                .null => {},
                else => return error.InvalidResponse,
            }
        } else if (root.get("workspace_id")) |value| {
            switch (value) {
                .string => hint.workspace_id = try self.allocator.dupe(u8, value.string),
                .null => {},
                else => return error.InvalidResponse,
            }
        }

        if (root.get("workspace_setup_workspace_vision")) |value| {
            switch (value) {
                .string => hint.workspace_vision = try self.allocator.dupe(u8, value.string),
                .null => {},
                else => return error.InvalidResponse,
            }
        }

        self.clearConnectSetupHint();
        self.connect_setup_hint = hint;
    }

    pub fn selectedWorkspaceId(self: *const App) ?[]const u8 {
        if (self.settings_panel.project_id.items.len > 0) return self.settings_panel.project_id.items;
        return self.config.selectedWorkspace();
    }

    fn defaultAttachWorkspaceId(self: *const App) ?[]const u8 {
        if (self.connect_setup_hint) |hint| {
            if (hint.workspace_id) |workspace_id| {
                if (workspace_id.len > 0) return workspace_id;
            }
        }
        if (self.config.active_role == .admin) return "system";
        return null;
    }

    fn preferredAttachWorkspaceId(self: *const App) ?[]const u8 {
        if (self.selectedWorkspaceId()) |workspace_id| return workspace_id;
        return self.defaultAttachWorkspaceId();
    }

    pub fn selectedWorkspaceSummary(self: *const App) ?*const workspace_types.WorkspaceSummary {
        const workspace_id = self.selectedWorkspaceId() orelse return null;
        for (self.ws.projects.items) |*project| {
            if (std.mem.eql(u8, project.id, workspace_id)) return project;
        }
        return null;
    }

    pub fn selectedWorkspaceTokenLocked(self: *const App) ?bool {
        const selected_workspace = self.selectedWorkspaceSummary() orelse return null;
        return selected_workspace.token_locked;
    }

    fn ensureSelectedWorkspaceInSettings(self: *App, workspace_id: []const u8) !void {
        if (self.settings_panel.project_id.items.len > 0 and
            std.mem.eql(u8, self.settings_panel.project_id.items, workspace_id))
        {
            return;
        }
        self.settings_panel.project_id.clearRetainingCapacity();
        try self.settings_panel.project_id.appendSlice(self.allocator, workspace_id);
    }

    pub fn selectWorkspaceInSettings(self: *App, workspace_id: []const u8) !void {
        self.settings_panel.project_id.clearRetainingCapacity();
        try self.settings_panel.project_id.appendSlice(self.allocator, workspace_id);
        self.ws.workspace_selector_open = false;
        self.settings_panel.project_token.clearRetainingCapacity();
        if (!isSystemWorkspaceId(workspace_id)) {
            if (self.config.getWorkspaceToken(workspace_id)) |token| {
                try self.settings_panel.project_token.appendSlice(self.allocator, token);
            }
        }
        self.session_attach_state = .unknown;
        if (self.ws.selected_workspace_detail) |*detail| {
            detail.deinit(self.allocator);
            self.ws.selected_workspace_detail = null;
        }
        self.ws.workspace_selected_mount_index = null;
        self.ws.workspace_selected_bind_index = null;
        try self.syncSettingsToConfig();
        self.syncHomeOnboardingStage();
    }

    pub fn refreshWorkspaceData(self: *App) !void {
        const client = if (self.ws_client) |*value| value else return error.NotConnected;
        try control_plane.ensureUnifiedV2Connection(self.allocator, client, &self.message_counter);

        var projects = try control_plane.listWorkspaces(self.allocator, client, &self.message_counter);
        errdefer workspace_types.deinitWorkspaceList(self.allocator, &projects);
        var nodes = try control_plane.listNodes(self.allocator, client, &self.message_counter);
        errdefer workspace_types.deinitNodeList(self.allocator, &nodes);
        const selected_workspace_id = self.selectedWorkspaceId();
        const selected_workspace_token = if (selected_workspace_id) |workspace_id|
            self.selectedWorkspaceToken(workspace_id)
        else
            null;

        var selected_workspace_warning: ?[]u8 = null;
        defer if (selected_workspace_warning) |value| self.allocator.free(value);

        var workspace_status = control_plane.workspaceStatus(
            self.allocator,
            client,
            &self.message_counter,
            selected_workspace_id,
            selected_workspace_token,
        ) catch |err| blk: {
            if (selected_workspace_id != null and err == error.RemoteError) {
                if (control_plane.lastRemoteError()) |remote| {
                    if (isSelectedWorkspaceAttachRemoteError(remote)) {
                        self.clearSelectedWorkspaceAfterAttachFailure();
                    }
                    selected_workspace_warning = self.formatControlRemoteMessage("Selected workspace unavailable", remote);
                } else {
                    selected_workspace_warning = std.fmt.allocPrint(self.allocator, "Selected workspace unavailable: {s}", .{@errorName(err)}) catch null;
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

        workspace_types.deinitWorkspaceList(self.allocator, &self.ws.projects);
        workspace_types.deinitNodeList(self.allocator, &self.ws.nodes);
        if (self.ws.workspace_state) |*status| status.deinit(self.allocator);

        self.ws.projects = projects;
        self.ws.nodes = nodes;
        self.ws.workspace_state = workspace_status;
        self.ws.workspace_last_refresh_ms = std.time.milliTimestamp();
        if (selected_workspace_warning) |message| {
            self.setWorkspaceError(message);
        } else {
            self.clearWorkspaceError();
        }

        if (selected_workspace_id) |ws_id| {
            const new_detail = control_plane.getWorkspace(
                self.allocator,
                client,
                &self.message_counter,
                ws_id,
            ) catch null;
            if (self.ws.selected_workspace_detail) |*old_detail| {
                old_detail.deinit(self.allocator);
            }
            self.ws.selected_workspace_detail = new_detail;
            // Validate selection indices against the refreshed arrays so a
            // stale index cannot target the wrong row or enable remove actions
            // for entries that no longer exist.
            if (new_detail) |*d| {
                if (self.ws.workspace_selected_mount_index) |mi| {
                    if (mi >= d.mounts.items.len) self.ws.workspace_selected_mount_index = null;
                }
                if (self.ws.workspace_selected_bind_index) |bi| {
                    if (bi >= d.binds.items.len) self.ws.workspace_selected_bind_index = null;
                }
            } else {
                self.ws.workspace_selected_mount_index = null;
                self.ws.workspace_selected_bind_index = null;
            }
        } else {
            if (self.ws.selected_workspace_detail) |*old_detail| {
                old_detail.deinit(self.allocator);
                self.ws.selected_workspace_detail = null;
            }
            self.ws.workspace_selected_mount_index = null;
            self.ws.workspace_selected_bind_index = null;
        }

        self.refreshMissionDashboardData() catch |err| {
            if (self.formatMissionDashboardOpError("Refresh missions", err)) |message| {
                defer self.allocator.free(message);
                self.setMissionDashboardError(message);
            } else {
                self.setMissionDashboardError("Refresh missions failed");
            }
        };
        self.syncCompletedOnboardingWorkflowsFromLiveState();
        self.syncHomeOnboardingStage();
    }

    fn refreshMissionDashboardData(self: *App) !void {
        const client = if (self.ws_client) |*value| value else return error.NotConnected;

        const request_id = try std.fmt.allocPrint(self.allocator, "missions-{d}", .{std.time.milliTimestamp()});
        self.client_context.setPendingWorkboardRequest(request_id);
        defer self.client_context.clearPendingWorkboardRequest();

        var agent_packs = self.loadMissionAgentPacks(client) catch std.ArrayListUnmanaged(MissionAgentPackView){};
        defer deinitMissionAgentPackList(self.allocator, &agent_packs);

        try self.writeFsPathTextGui(client, "/agents/self/missions/control/list.json", "{}");
        const result_json = try self.readFsPathTextGui(client, "/agents/self/missions/result.json");
        defer self.allocator.free(result_json);
        if (try missionResultErrorMessage(self.allocator, result_json)) |message| {
            defer self.allocator.free(message);
            self.setMissionDashboardError(message);
            return error.RemoteError;
        }

        var missions = try self.parseMissionListResult(result_json, agent_packs.items);
        errdefer deinitMissionRecordList(self.allocator, &missions);

        const workboard_items = try self.buildMissionWorkboardItemsOwned(missions.items);
        errdefer deinitWorkboardItemOwnedSlice(self.allocator, workboard_items);

        var approvals = try self.buildMissionApprovalsOwned(missions.items);
        self.client_context.clearApprovals();
        var approval_index: usize = 0;
        errdefer {
            while (approval_index < approvals.items.len) : (approval_index += 1) {
                freeOwnedExecApproval(self.allocator, &approvals.items[approval_index]);
            }
            approvals.deinit(self.allocator);
        }
        while (approval_index < approvals.items.len) : (approval_index += 1) {
            try self.client_context.upsertApprovalOwned(approvals.items[approval_index]);
        }
        approvals.items.len = 0;
        approvals.deinit(self.allocator);

        self.client_context.setWorkboardItemsOwned(workboard_items);
        self.replaceMissionRecordsOwned(missions);
        self.mission.last_refresh_ms = std.time.milliTimestamp();
        self.clearMissionDashboardError();
    }

    pub fn requestMissionDashboardRefresh(self: *App, force: bool) void {
        if (self.connection_state != .connected) return;
        if (self.client_context.pending_workboard_request_id != null) return;
        const now = std.time.milliTimestamp();
        if (!force and self.mission.last_refresh_ms != 0 and now - self.mission.last_refresh_ms < MISSION_REFRESH_INTERVAL_MS) return;
        self.refreshMissionDashboardData() catch |err| {
            if (self.formatMissionDashboardOpError("Refresh missions", err)) |message| {
                defer self.allocator.free(message);
                self.setMissionDashboardError(message);
            } else {
                self.setMissionDashboardError("Refresh missions failed");
            }
        };
    }

    fn replaceMissionRecordsOwned(self: *App, missions: std.ArrayListUnmanaged(MissionRecordView)) void {
        for (self.mission.records.items) |*mission| mission.deinit(self.allocator);
        self.mission.records.deinit(self.allocator);
        self.mission.records = missions;
        self.syncMissionSelection();
    }

    fn syncMissionSelection(self: *App) void {
        if (self.mission.selected_id) |selected_id| {
            for (self.mission.records.items) |*mission| {
                if (std.mem.eql(u8, mission.mission_id, selected_id)) return;
            }
            self.allocator.free(selected_id);
            self.mission.selected_id = null;
        }
        if (self.mission.selected_id == null and self.mission.records.items.len > 0) {
            self.mission.selected_id = self.allocator.dupe(u8, self.mission.records.items[0].mission_id) catch null;
        }
    }

    pub fn selectedMission(self: *App) ?*MissionRecordView {
        const selected_id = self.mission.selected_id orelse return if (self.mission.records.items.len > 0) &self.mission.records.items[0] else null;
        for (self.mission.records.items) |*mission| {
            if (std.mem.eql(u8, mission.mission_id, selected_id)) return mission;
        }
        return if (self.mission.records.items.len > 0) &self.mission.records.items[0] else null;
    }

    fn loadMissionAgentPacks(self: *App, client: *ws_client_mod.WebSocketClient) !std.ArrayListUnmanaged(MissionAgentPackView) {
        try self.writeFsPathTextGui(client, "/agents/self/agents/control/list.json", "{}");
        const result_json = try self.readFsPathTextGui(client, "/agents/self/agents/result.json");
        defer self.allocator.free(result_json);

        var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, result_json, .{});
        defer parsed.deinit();
        if (parsed.value != .object) return error.InvalidResponse;
        const root = parsed.value.object;
        if (root.get("ok")) |value| {
            if (value == .bool and !value.bool) return error.RemoteError;
        }
        const result_val = root.get("result") orelse return error.InvalidResponse;
        if (result_val != .object) return error.InvalidResponse;
        const agents_val = result_val.object.get("agents") orelse return error.InvalidResponse;
        if (agents_val != .array) return error.InvalidResponse;

        var out = std.ArrayListUnmanaged(MissionAgentPackView){};
        errdefer deinitMissionAgentPackList(self.allocator, &out);

        for (agents_val.array.items) |item| {
            if (item != .object) continue;
            const obj = item.object;
            const agent_id = try dupRequiredStringField(self.allocator, obj, "agent_id");
            errdefer self.allocator.free(agent_id);
            const persona_pack = try dupOptionalStringField(self.allocator, obj, "persona_pack");
            errdefer if (persona_pack) |value| self.allocator.free(value);
            try out.append(self.allocator, .{
                .agent_id = agent_id,
                .persona_pack = persona_pack,
            });
        }

        return out;
    }

    fn parseMissionListResult(
        self: *App,
        result_json: []const u8,
        agent_packs: []const MissionAgentPackView,
    ) !std.ArrayListUnmanaged(MissionRecordView) {
        var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, result_json, .{});
        defer parsed.deinit();
        if (parsed.value != .object) return error.InvalidResponse;
        const root = parsed.value.object;
        if (root.get("ok")) |value| {
            if (value == .bool and !value.bool) return error.RemoteError;
        }
        const result_val = root.get("result") orelse return error.InvalidResponse;
        if (result_val != .object) return error.InvalidResponse;
        const missions_val = result_val.object.get("missions") orelse return error.InvalidResponse;
        if (missions_val != .array) return error.InvalidResponse;

        var out = std.ArrayListUnmanaged(MissionRecordView){};
        errdefer deinitMissionRecordList(self.allocator, &out);

        for (missions_val.array.items) |item| {
            if (item != .object) continue;
            try out.append(self.allocator, try self.parseMissionRecordView(item.object, agent_packs));
        }

        return out;
    }

    fn parseMissionRecordView(
        self: *App,
        obj: std.json.ObjectMap,
        agent_packs: []const MissionAgentPackView,
    ) !MissionRecordView {
        var mission = MissionRecordView{
            .mission_id = try dupRequiredStringField(self.allocator, obj, "mission_id"),
            .use_case = try dupRequiredStringField(self.allocator, obj, "use_case"),
            .title = try dupOptionalStringField(self.allocator, obj, "title"),
            .stage = try dupRequiredStringField(self.allocator, obj, "stage"),
            .state = try dupRequiredStringField(self.allocator, obj, "state"),
            .agent_id = try dupOptionalStringField(self.allocator, obj, "agent_id"),
            .project_id = try dupOptionalStringField(self.allocator, obj, "project_id"),
            .run_id = try dupOptionalStringField(self.allocator, obj, "run_id"),
            .workspace_root = try dupOptionalStringField(self.allocator, obj, "workspace_root"),
            .worktree_name = try dupOptionalStringField(self.allocator, obj, "worktree_name"),
            .created_by = try parseMissionActorView(self.allocator, obj.get("created_by") orelse return error.InvalidResponse),
            .created_at_ms = try intFieldOrDefault(obj, "created_at_ms", 0),
            .updated_at_ms = try intFieldOrDefault(obj, "updated_at_ms", 0),
            .last_heartbeat_ms = try intFieldOrDefault(obj, "last_heartbeat_ms", 0),
            .checkpoint_seq = try u64FieldOrDefault(obj, "checkpoint_seq", 0),
            .recovery_count = try u64FieldOrDefault(obj, "recovery_count", 0),
            .recovery_reason = try dupOptionalStringField(self.allocator, obj, "recovery_reason"),
            .blocked_reason = try dupOptionalStringField(self.allocator, obj, "blocked_reason"),
            .summary = try dupOptionalStringField(self.allocator, obj, "summary"),
        };
        errdefer mission.deinit(self.allocator);

        if (obj.get("contract")) |value| {
            if (value != .object) return error.InvalidResponse;
            mission.contract_id = try dupOptionalStringField(self.allocator, value.object, "contract_id");
            mission.contract_context_path = try dupOptionalStringField(self.allocator, value.object, "context_path");
            mission.contract_state_path = try dupOptionalStringField(self.allocator, value.object, "state_path");
            mission.contract_artifact_root = try dupOptionalStringField(self.allocator, value.object, "artifact_root");
        }

        if (mission.agent_id) |agent_id| {
            if (lookupMissionPersonaPack(agent_packs, agent_id)) |persona_pack| {
                mission.persona_pack = try self.allocator.dupe(u8, persona_pack);
            }
        }

        if (obj.get("pending_approval")) |value| {
            if (value == .object) {
                mission.pending_approval = try parseMissionApprovalView(self.allocator, value);
            }
        }

        if (obj.get("artifacts")) |value| {
            if (value != .array) return error.InvalidResponse;
            for (value.array.items) |artifact_val| {
                if (artifact_val != .object) continue;
                try mission.artifacts.append(self.allocator, try parseMissionArtifactView(self.allocator, artifact_val));
            }
        }

        if (obj.get("events")) |value| {
            if (value != .array) return error.InvalidResponse;
            for (value.array.items) |event_val| {
                if (event_val != .object) continue;
                try mission.events.append(self.allocator, try parseMissionEventView(self.allocator, event_val));
            }
        }

        return mission;
    }

    fn buildMissionWorkboardItemsOwned(self: *App, missions: []const MissionRecordView) ![]zui.protocol.types.WorkboardItem {
        var out = try self.allocator.alloc(zui.protocol.types.WorkboardItem, missions.len);
        errdefer deinitWorkboardItemOwnedSlice(self.allocator, out);

        for (missions, 0..) |mission, index| {
            const title_source = mission.title orelse mission.summary orelse mission.mission_id;
            const owner_source = mission.agent_id orelse mission.created_by.actor_id;
            out[index] = .{
                .id = try self.allocator.dupe(u8, mission.mission_id),
                .kind = try self.allocator.dupe(u8, mission.use_case),
                .status = try self.allocator.dupe(u8, mission.state),
                .title = try self.allocator.dupe(u8, title_source),
                .summary = if (mission.summary) |value| try self.allocator.dupe(u8, value) else null,
                .owner = try self.allocator.dupe(u8, owner_source),
                .agent_id = if (mission.agent_id) |value| try self.allocator.dupe(u8, value) else null,
                .parent_id = null,
                .cron_key = null,
                .created_at_ms = mission.created_at_ms,
                .updated_at_ms = mission.updated_at_ms,
                .due_at_ms = null,
                .payload_json = if (mission.persona_pack) |value|
                    try std.fmt.allocPrint(self.allocator, "{{\"mission_id\":\"{s}\",\"persona_pack\":\"{s}\"}}", .{ mission.mission_id, value })
                else
                    try std.fmt.allocPrint(self.allocator, "{{\"mission_id\":\"{s}\"}}", .{mission.mission_id}),
            };
        }
        return out;
    }

    fn buildMissionApprovalsOwned(self: *App, missions: []const MissionRecordView) !std.ArrayListUnmanaged(zui.protocol.types.ExecApproval) {
        var approvals = std.ArrayListUnmanaged(zui.protocol.types.ExecApproval){};
        errdefer deinitExecApprovalList(self.allocator, &approvals);

        for (missions) |mission| {
            const approval = mission.pending_approval orelse continue;
            var summary_buf: [256]u8 = undefined;
            const title = mission.title orelse mission.summary orelse mission.mission_id;
            const summary = std.fmt.bufPrint(
                &summary_buf,
                "{s}: {s}",
                .{ title, approval.action_kind },
            ) catch approval.action_kind;
            const payload_json = if (approval.payload_json) |payload|
                try std.fmt.allocPrint(
                    self.allocator,
                    "{{\"mission_id\":\"{s}\",\"action_kind\":\"{s}\",\"payload\":{s}}}",
                    .{ mission.mission_id, approval.action_kind, payload },
                )
            else
                try std.fmt.allocPrint(
                    self.allocator,
                    "{{\"mission_id\":\"{s}\",\"action_kind\":\"{s}\"}}",
                    .{ mission.mission_id, approval.action_kind },
                );

            try approvals.append(self.allocator, .{
                .id = try self.allocator.dupe(u8, approval.approval_id),
                .payload_json = payload_json,
                .summary = try self.allocator.dupe(u8, summary),
                .requested_at_ms = approval.requested_at_ms,
                .requested_by = try std.fmt.allocPrint(
                    self.allocator,
                    "{s}/{s}",
                    .{ approval.requested_by.actor_type, approval.requested_by.actor_id },
                ),
                .resolved_at_ms = null,
                .resolved_by = null,
                .decision = null,
                .can_resolve = true,
            });
        }

        return approvals;
    }

    pub fn resolveMissionApproval(self: *App, action: zui.ui.operator_view.ExecApprovalResolveAction) !void {
        const mission = self.findMissionForApprovalId(action.request_id) orelse return error.NotFound;
        const client = if (self.ws_client) |*value| value else return error.NotConnected;

        const request_id = try std.fmt.allocPrint(self.allocator, "mission-approval-{d}", .{std.time.milliTimestamp()});
        const approval_target = try self.allocator.dupe(u8, action.request_id);
        const decision_label = switch (action.decision) {
            .allow_once, .allow_always => "approve",
            .deny => "deny",
        };
        const decision_copy = try self.allocator.dupe(u8, decision_label);
        self.client_context.setPendingApprovalResolveRequest(request_id, approval_target, decision_copy);
        defer self.client_context.clearPendingApprovalResolveRequest();

        const control_name = switch (action.decision) {
            .allow_once, .allow_always => "approve.json",
            .deny => "reject.json",
        };
        const payload = try std.fmt.allocPrint(
            self.allocator,
            "{{\"mission_id\":\"{s}\"}}",
            .{mission.mission_id},
        );
        defer self.allocator.free(payload);

        const control_path = try std.fmt.allocPrint(self.allocator, "/agents/self/missions/control/{s}", .{control_name});
        defer self.allocator.free(control_path);
        try self.writeFsPathTextGui(client, control_path, payload);

        const result_json = try self.readFsPathTextGui(client, "/agents/self/missions/result.json");
        defer self.allocator.free(result_json);
        if (try missionResultErrorMessage(self.allocator, result_json)) |message| {
            defer self.allocator.free(message);
            self.setMissionDashboardError(message);
            return error.RemoteError;
        }

        try self.client_context.markApprovalResolvedOwned(
            action.request_id,
            switch (action.decision) {
                .allow_once, .allow_always => "approve",
                .deny => "deny",
            },
            "SpiderApp",
            std.time.milliTimestamp(),
        );
        try self.refreshMissionDashboardData();
    }

    fn findMissionForApprovalId(self: *App, approval_id: []const u8) ?*MissionRecordView {
        for (self.mission.records.items) |*mission| {
            if (mission.pending_approval) |approval| {
                if (std.mem.eql(u8, approval.approval_id, approval_id)) return mission;
            }
        }
        return null;
    }

    pub fn formatMissionDashboardOpError(self: *App, operation: []const u8, err: anyerror) ?[]u8 {
        if (self.mission.last_error) |message| {
            return std.fmt.allocPrint(self.allocator, "{s}: {s}", .{ operation, message }) catch null;
        }
        if (err == error.RemoteError) {
            if (control_plane.lastRemoteError()) |remote| {
                return std.fmt.allocPrint(self.allocator, "{s}: {s}", .{ operation, remote }) catch null;
            }
        }
        if (self.fs.fsrpc_last_remote_error) |remote| {
            return std.fmt.allocPrint(self.allocator, "{s}: {s}", .{ operation, remote }) catch null;
        }
        return std.fmt.allocPrint(self.allocator, "{s}: {s}", .{ operation, @errorName(err) }) catch null;
    }

    pub fn activateSelectedWorkspace(self: *App) !void {
        const client = if (self.ws_client) |*value| value else return error.NotConnected;
        const project_id = self.selectedWorkspaceId() orelse return error.MissingField;

        const token = self.selectedWorkspaceToken(project_id);

        var status = try control_plane.activateWorkspace(
            self.allocator,
            client,
            &self.message_counter,
            project_id,
            token,
        );
        errdefer status.deinit(self.allocator);

        if (self.ws.workspace_state) |*existing| existing.deinit(self.allocator);
        self.ws.workspace_state = status;
        self.ws.workspace_last_refresh_ms = std.time.milliTimestamp();
        self.clearWorkspaceError();
        self.session_attach_state = .unknown;
        self.refreshMissionDashboardData() catch {};

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
        self.ws.launcher_connect_token.clearRetainingCapacity();
        const token = self.config.activeRoleToken();
        if (token.len > 0) {
            try self.ws.launcher_connect_token.appendSlice(self.allocator, token);
        }
    }

    pub fn persistLauncherConnectToken(self: *App) !void {
        const token = std.mem.trim(u8, self.ws.launcher_connect_token.items, " \t\r\n");
        try self.setRoleToken(.admin, token, false);
        try self.setRoleToken(.user, token, false);
    }

    fn activeRoleLabel(self: *const App) []const u8 {
        return if (self.config.active_role == .admin) "Admin" else "User";
    }

    pub fn setActiveConnectRole(self: *App, role: config_mod.Config.TokenRole) !void {
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

    pub fn copyTextToClipboard(self: *App, text: []const u8) !void {
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

    fn createWorkspaceFromPanel(self: *App) !void {
        const client = if (self.ws_client) |*value| value else return error.NotConnected;
        if (self.settings_panel.project_create_name.items.len == 0) return error.MissingField;
        try control_plane.ensureUnifiedV2Connection(self.allocator, client, &self.message_counter);

        const vision = if (self.settings_panel.project_create_vision.items.len > 0)
            self.settings_panel.project_create_vision.items
        else
            null;
        const template_id = blk: {
            const trimmed = std.mem.trim(u8, self.settings_panel.workspace_template_id.items, " \t\r\n");
            break :blk if (trimmed.len > 0) trimmed else "dev";
        };
        var created = try control_plane.createWorkspace(
            self.allocator,
            client,
            &self.message_counter,
            self.settings_panel.project_create_name.items,
            vision,
            template_id,
            self.resolveProjectOperatorToken(),
        );
        defer created.deinit(self.allocator);

        self.settings_panel.project_id.clearRetainingCapacity();
        try self.settings_panel.project_id.appendSlice(self.allocator, created.id);
        self.settings_panel.project_token.clearRetainingCapacity();
        if (created.workspace_token) |token| {
            try self.settings_panel.project_token.appendSlice(self.allocator, token);
        }
        try self.syncSettingsToConfig();
        self.settings_panel.project_create_name.clearRetainingCapacity();
        self.refreshWorkspaceData() catch {};
        self.clearWorkspaceError();
    }

    fn lockSelectedWorkspaceFromPanel(self: *App) !void {
        const client = if (self.ws_client) |*value| value else return error.NotConnected;
        const project_id = self.selectedWorkspaceId() orelse return error.MissingField;
        const current_token = self.selectedWorkspaceToken(project_id);
        try control_plane.ensureUnifiedV2Connection(self.allocator, client, &self.message_counter);

        var result = try control_plane.rotateWorkspaceToken(
            self.allocator,
            client,
            &self.message_counter,
            project_id,
            current_token,
        );
        defer result.deinit(self.allocator);

        const next_token = result.workspace_token orelse return error.InvalidResponse;
        try self.ensureSelectedWorkspaceInSettings(project_id);
        self.settings_panel.project_token.clearRetainingCapacity();
        try self.settings_panel.project_token.appendSlice(self.allocator, next_token);
        try self.syncSettingsToConfig();

        self.refreshWorkspaceData() catch {};
        self.clearWorkspaceError();
    }

    fn unlockSelectedWorkspaceFromPanel(self: *App) !void {
        const client = if (self.ws_client) |*value| value else return error.NotConnected;
        const project_id = self.selectedWorkspaceId() orelse return error.MissingField;
        const current_token = self.selectedWorkspaceToken(project_id);
        try control_plane.ensureUnifiedV2Connection(self.allocator, client, &self.message_counter);

        var result = try control_plane.revokeWorkspaceToken(
            self.allocator,
            client,
            &self.message_counter,
            project_id,
            current_token,
        );
        defer result.deinit(self.allocator);

        try self.ensureSelectedWorkspaceInSettings(project_id);
        self.settings_panel.project_token.clearRetainingCapacity();
        try self.syncSettingsToConfig();

        self.refreshWorkspaceData() catch {};
        self.clearWorkspaceError();
    }

    fn setWorkspaceMountFromPanel(self: *App) !void {
        const client = if (self.ws_client) |*value| value else return error.NotConnected;
        const project_id = self.selectedWorkspaceId() orelse return error.MissingField;
        const project_token = self.selectedWorkspaceToken(project_id);
        const mount_path = std.mem.trim(u8, self.settings_panel.project_mount_path.items, " \t");
        const node_id = std.mem.trim(u8, self.settings_panel.project_mount_node_id.items, " \t");
        const export_name = std.mem.trim(u8, self.settings_panel.project_mount_export_name.items, " \t");
        if (mount_path.len == 0 or node_id.len == 0 or export_name.len == 0) return error.MissingField;
        try control_plane.ensureUnifiedV2Connection(self.allocator, client, &self.message_counter);

        var detail = try control_plane.setWorkspaceMount(
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

    pub fn validateWorkspaceMountAddInput(self: *App) ?[]const u8 {
        _ = self.selectedWorkspaceId() orelse return "Select a workspace before adding mounts.";
        const mount_path = std.mem.trim(u8, self.settings_panel.project_mount_path.items, " \t");
        if (mount_path.len == 0) return "Mount path is required.";
        const node_id = std.mem.trim(u8, self.settings_panel.project_mount_node_id.items, " \t");
        if (node_id.len == 0) return "Mount node ID is required.";
        const export_name = std.mem.trim(u8, self.settings_panel.project_mount_export_name.items, " \t");
        if (export_name.len == 0) return "Mount export name is required.";
        return null;
    }

    pub fn validateWorkspaceMountRemoveInput(self: *App) ?[]const u8 {
        _ = self.selectedWorkspaceId() orelse return "Select a workspace before removing mounts.";
        const mount_path = std.mem.trim(u8, self.settings_panel.project_mount_path.items, " \t");
        if (mount_path.len == 0) return "Mount path is required.";
        const node_id = std.mem.trim(u8, self.settings_panel.project_mount_node_id.items, " \t");
        const export_name = std.mem.trim(u8, self.settings_panel.project_mount_export_name.items, " \t");
        if ((node_id.len == 0) != (export_name.len == 0)) {
            return "For filtered remove, provide both node ID and export name, or leave both blank.";
        }
        return null;
    }

    fn removeWorkspaceMountFromPanel(self: *App) !void {
        const client = if (self.ws_client) |*value| value else return error.NotConnected;
        const project_id = self.selectedWorkspaceId() orelse return error.MissingField;
        const project_token = self.selectedWorkspaceToken(project_id);
        const mount_path = std.mem.trim(u8, self.settings_panel.project_mount_path.items, " \t");
        if (mount_path.len == 0) return error.MissingField;

        const trimmed_node_id = std.mem.trim(u8, self.settings_panel.project_mount_node_id.items, " \t");
        const trimmed_export_name = std.mem.trim(u8, self.settings_panel.project_mount_export_name.items, " \t");
        const node_id_filter: ?[]const u8 = if (trimmed_node_id.len > 0) trimmed_node_id else null;
        const export_name_filter: ?[]const u8 = if (trimmed_export_name.len > 0) trimmed_export_name else null;
        if ((node_id_filter == null) != (export_name_filter == null)) return error.MissingField;
        try control_plane.ensureUnifiedV2Connection(self.allocator, client, &self.message_counter);

        var detail = try control_plane.removeWorkspaceMount(
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

    pub fn validateWorkspaceBindAddInput(self: *App) ?[]const u8 {
        _ = self.selectedWorkspaceId() orelse return "Select a workspace before adding binds.";
        const bind_path = std.mem.trim(u8, self.settings_panel.workspace_bind_path.items, " \t");
        if (bind_path.len == 0) return "Bind path is required.";
        const target_path = std.mem.trim(u8, self.settings_panel.workspace_bind_target_path.items, " \t");
        if (target_path.len == 0) return "Target path is required.";
        return null;
    }

    pub fn validateWorkspaceBindRemoveInput(self: *App) ?[]const u8 {
        _ = self.selectedWorkspaceId() orelse return "Select a workspace before removing binds.";
        const bind_path = std.mem.trim(u8, self.settings_panel.workspace_bind_path.items, " \t");
        if (bind_path.len == 0) return "Bind path is required.";
        return null;
    }

    fn setWorkspaceBindFromPanel(self: *App) !void {
        const client = if (self.ws_client) |*value| value else return error.NotConnected;
        const project_id = self.selectedWorkspaceId() orelse return error.MissingField;
        const project_token = self.selectedWorkspaceToken(project_id);
        const bind_path = std.mem.trim(u8, self.settings_panel.workspace_bind_path.items, " \t");
        const target_path = std.mem.trim(u8, self.settings_panel.workspace_bind_target_path.items, " \t");
        if (bind_path.len == 0 or target_path.len == 0) return error.MissingField;
        try control_plane.ensureUnifiedV2Connection(self.allocator, client, &self.message_counter);

        var detail = try control_plane.setWorkspaceBind(
            self.allocator,
            client,
            &self.message_counter,
            project_id,
            project_token,
            bind_path,
            target_path,
        );
        defer detail.deinit(self.allocator);

        self.refreshWorkspaceData() catch {};
        self.clearWorkspaceError();
    }

    fn removeWorkspaceBindFromPanel(self: *App) !void {
        const client = if (self.ws_client) |*value| value else return error.NotConnected;
        const project_id = self.selectedWorkspaceId() orelse return error.MissingField;
        const project_token = self.selectedWorkspaceToken(project_id);
        const bind_path = std.mem.trim(u8, self.settings_panel.workspace_bind_path.items, " \t");
        if (bind_path.len == 0) return error.MissingField;
        try control_plane.ensureUnifiedV2Connection(self.allocator, client, &self.message_counter);

        var detail = try control_plane.removeWorkspaceBind(
            self.allocator,
            client,
            &self.message_counter,
            project_id,
            project_token,
            bind_path,
        );
        defer detail.deinit(self.allocator);

        self.refreshWorkspaceData() catch {};
        self.clearWorkspaceError();
    }

    fn buildLocalNodeTtlText(allocator: std.mem.Allocator, nodes: []const workspace_types.NodeInfo, node_id: []const u8) ![]u8 {
        const now_ms = std.time.milliTimestamp();
        for (nodes) |*node| {
            if (!std.mem.eql(u8, node.node_id, node_id)) continue;
            const remaining_ms = node.lease_expires_at_ms - now_ms;
            if (remaining_ms <= 0) {
                return allocator.dupe(u8, "expired");
            }
            const remaining_sec = @divTrunc(remaining_ms, 1000);
            const remaining_min = @divTrunc(remaining_sec, 60);
            if (remaining_min > 0) {
                return std.fmt.allocPrint(allocator, "{d}m {d}s", .{ remaining_min, @mod(remaining_sec, 60) });
            }
            return std.fmt.allocPrint(allocator, "{d}s", .{remaining_sec});
        }
        return allocator.dupe(u8, "offline");
    }

    fn removeWorkspaceMountByView(self: *App, idx: usize) !void {
        const detail = if (self.ws.selected_workspace_detail) |*d| d else return error.MissingField;
        if (idx >= detail.mounts.items.len) return error.MissingField;
        const mount = detail.mounts.items[idx];
        const client = if (self.ws_client) |*value| value else return error.NotConnected;
        const project_id = self.selectedWorkspaceId() orelse return error.MissingField;
        const project_token = self.selectedWorkspaceToken(project_id);
        try control_plane.ensureUnifiedV2Connection(self.allocator, client, &self.message_counter);
        // Pass node_id and export_name as filters so that in workspaces with
        // multiple mounts on the same path we remove only the selected row,
        // not every mount that shares the path.
        const node_id_filter: ?[]const u8 = if (mount.node_id.len > 0) mount.node_id else null;
        const export_name_filter: ?[]const u8 = if (mount.export_name.len > 0) mount.export_name else null;
        var result = try control_plane.removeWorkspaceMount(
            self.allocator,
            client,
            &self.message_counter,
            project_id,
            project_token,
            mount.mount_path,
            node_id_filter,
            export_name_filter,
        );
        defer result.deinit(self.allocator);
        self.ws.workspace_selected_mount_index = null;
        self.refreshWorkspaceData() catch {};
        self.clearWorkspaceError();
    }

    fn removeWorkspaceBindByView(self: *App, idx: usize) !void {
        const detail = if (self.ws.selected_workspace_detail) |*d| d else return error.MissingField;
        if (idx >= detail.binds.items.len) return error.MissingField;
        const bind = detail.binds.items[idx];
        const client = if (self.ws_client) |*value| value else return error.NotConnected;
        const project_id = self.selectedWorkspaceId() orelse return error.MissingField;
        const project_token = self.selectedWorkspaceToken(project_id);
        try control_plane.ensureUnifiedV2Connection(self.allocator, client, &self.message_counter);
        var result = try control_plane.removeWorkspaceBind(
            self.allocator,
            client,
            &self.message_counter,
            project_id,
            project_token,
            bind.bind_path,
        );
        defer result.deinit(self.allocator);
        self.ws.workspace_selected_bind_index = null;
        self.refreshWorkspaceData() catch {};
        self.clearWorkspaceError();
    }

    fn rotateWorkspaceTokenFromPanel(self: *App) !void {
        const client = if (self.ws_client) |*value| value else return error.NotConnected;
        const project_id = self.selectedWorkspaceId() orelse return error.MissingField;
        const current_token = self.selectedWorkspaceToken(project_id);
        try control_plane.ensureUnifiedV2Connection(self.allocator, client, &self.message_counter);
        var result = try control_plane.rotateWorkspaceToken(
            self.allocator,
            client,
            &self.message_counter,
            project_id,
            current_token,
        );
        defer result.deinit(self.allocator);
        const next_token = result.workspace_token orelse return error.InvalidResponse;
        try self.ensureSelectedWorkspaceInSettings(project_id);
        self.settings_panel.project_token.clearRetainingCapacity();
        try self.settings_panel.project_token.appendSlice(self.allocator, next_token);
        try self.config.setWorkspaceToken(project_id, next_token);
        try self.config.save();
        self.refreshWorkspaceData() catch {};
        self.clearWorkspaceError();
    }

    fn rawThemePackPath(self: *const App) ?[]const u8 {
        return if (self.settings_panel.theme_pack.items.len > 0)
            self.settings_panel.theme_pack.items
        else
            null;
    }

    fn effectiveThemePackPath(self: *const App) []const u8 {
        return self.rawThemePackPath() orelse "themes/zsc_modern_ai";
    }

    fn effectiveThemeMode(self: *const App) zui.theme.Mode {
        const pack_default: zui.theme.Mode = switch (zui.ui.theme_engine.runtime.getPackDefaultMode() orelse .dark) {
            .light => .light,
            .dark => .dark,
        };
        if (zui.ui.theme_engine.runtime.getPackModeLockToDefault()) return pack_default;
        return switch (self.settings_panel.theme_mode) {
            .pack_default => pack_default,
            .light => .light,
            .dark => .dark,
        };
    }

    fn resolveThemeProfileForWindow(self: *App, fb_width: u32, fb_height: u32) void {
        const profile_label = themeProfileLabel(self.settings_panel.theme_profile);
        self.shared_theme_engine.resolveProfileFromConfig(fb_width, fb_height, profile_label);
        self.host_theme_engine.resolveProfileFromConfig(fb_width, fb_height, profile_label);
    }

    fn applyThemeSettings(self: *App, force_reload: bool) void {
        const pack_path = self.effectiveThemePackPath();
        self.shared_theme_engine.applyThemePackDirFromPath(pack_path, force_reload) catch |err| {
            std.log.warn("Failed to apply shared theme pack {s}: {s}", .{ pack_path, @errorName(err) });
        };
        self.host_theme_engine.loadAndApplyThemePackDir(pack_path) catch |err| {
            std.log.warn("Failed to apply host theme pack {s}: {s}", .{ pack_path, @errorName(err) });
        };

        const mode = self.effectiveThemeMode();
        zui.theme.setMode(mode);
        zui.ui.theme.setMode(switch (mode) {
            .light => .light,
            .dark => .dark,
        });
        zui.ui.theme.apply();
        self.theme = zui.theme.current();
        self.syncThemePackWatchStamp();
        self.invalidateGlyphWidthCache();
    }

    fn syncThemePackWatchStamp(self: *App) void {
        self.theme_pack_watch_stamp_ns = scanThemePackStamp(self.effectiveThemePackPath()) orelse 0;
        self.theme_pack_watch_next_scan_ms = std.time.milliTimestamp() + 750;
    }

    fn pollThemePackWatcher(self: *App) void {
        if (!self.settings_panel.watch_theme_pack) {
            self.theme_pack_watch_stamp_ns = 0;
            return;
        }

        const now_ms = std.time.milliTimestamp();
        if (now_ms < self.theme_pack_watch_next_scan_ms) return;
        self.theme_pack_watch_next_scan_ms = now_ms + 750;

        const stamp = scanThemePackStamp(self.effectiveThemePackPath()) orelse return;
        if (self.theme_pack_watch_stamp_ns == 0) {
            self.theme_pack_watch_stamp_ns = stamp;
            return;
        }
        if (stamp > self.theme_pack_watch_stamp_ns) {
            self.theme_pack_watch_stamp_ns = stamp;
            self.applyThemeSettings(true);
        }
    }

    fn clearThemePackEntries(self: *App) void {
        for (self.theme_pack_entries.items) |*entry| entry.deinit(self.allocator);
        self.theme_pack_entries.deinit(self.allocator);
        self.theme_pack_entries = .{};
    }

    fn refreshThemePackEntries(self: *App) void {
        self.clearThemePackEntries();
        if (builtin.target.os.tag == .emscripten or builtin.target.os.tag == .wasi) return;

        var themes_dir = std.fs.cwd().openDir("themes", .{ .iterate = true }) catch return;
        defer themes_dir.close();

        var it = themes_dir.iterate();
        while (it.next() catch null) |entry| {
            if (entry.kind != .directory or entry.name.len == 0) continue;

            var pack_dir = themes_dir.openDir(entry.name, .{}) catch continue;
            defer pack_dir.close();
            var manifest = pack_dir.openFile("manifest.json", .{}) catch continue;
            manifest.close();

            const name = self.allocator.dupe(u8, entry.name) catch continue;
            self.theme_pack_entries.append(self.allocator, .{ .name = name }) catch {
                self.allocator.free(name);
                break;
            };
        }

        if (self.theme_pack_entries.items.len > 1) {
            const Ctx = struct {};
            std.sort.pdq(ThemePackEntry, self.theme_pack_entries.items, Ctx{}, struct {
                fn lessThan(_: Ctx, a: ThemePackEntry, b: ThemePackEntry) bool {
                    return std.mem.lessThan(u8, a.name, b.name);
                }
            }.lessThan);
        }
    }

    fn openThemePackBrowseLocation(self: *App) void {
        if (!themePackBrowseSupported()) return;
        const target = self.rawThemePackPath() orelse "themes";
        const argv = switch (builtin.target.os.tag) {
            .windows => [_][]const u8{ "explorer.exe", target },
            .macos => [_][]const u8{ "open", target },
            else => [_][]const u8{ "xdg-open", target },
        };
        var child = std.process.Child.init(&argv, self.allocator);
        _ = child.spawn() catch {};
    }

    pub fn sharedStyleSheet(self: *const App) zui.ui.theme_engine.style_sheet.StyleSheet {
        _ = self;
        return zui.ui.theme_engine.runtime.getStyleSheet();
    }

    fn connectionStatusColors(self: *const App) struct { fill: [4]f32, border: [4]f32, text: [4]f32 } {
        const ss = self.sharedStyleSheet();
        const tone = switch (self.connection_state) {
            .disconnected => ss.status.danger,
            .connecting => ss.status.warning,
            .connected => ss.status.success,
            .error_state => ss.status.info,
        };
        const fallback_fill = switch (self.connection_state) {
            .disconnected => zcolors.rgba(200, 80, 80, 255),
            .connecting => zcolors.rgba(220, 200, 60, 255),
            .connected => zcolors.rgba(90, 210, 90, 255),
            .error_state => zcolors.rgba(230, 120, 70, 255),
        };
        return .{
            .fill = tone.fill orelse fallback_fill,
            .border = tone.border orelse zcolors.blend(fallback_fill, self.theme.colors.border, 0.25),
            .text = tone.text orelse self.theme.colors.text_primary,
        };
    }

    fn syntaxThemeColor(self: *const App, kind: JsonTokenKind) [4]f32 {
        const syntax = self.sharedStyleSheet().syntax;
        return switch (kind) {
            .key => syntax.key orelse zcolors.blend(self.theme.colors.text_primary, self.theme.colors.primary, 0.5),
            .string => syntax.string orelse zcolors.rgba(48, 140, 92, 255),
            .number => syntax.number orelse zcolors.rgba(193, 126, 54, 255),
            .keyword => syntax.keyword orelse zcolors.rgba(137, 88, 186, 255),
            .punctuation => syntax.punctuation orelse self.theme.colors.text_secondary,
            .plain => syntax.plain orelse self.theme.colors.text_primary,
        };
    }

    pub fn chartSeriesThemeColor(self: *const App, idx: usize) [4]f32 {
        const charts = self.sharedStyleSheet().charts;
        return switch (idx) {
            0 => charts.series_1 orelse zcolors.rgba(92, 173, 255, 255),
            1 => charts.series_2 orelse zcolors.rgba(255, 170, 72, 255),
            2 => charts.series_3 orelse zcolors.rgba(175, 122, 255, 255),
            3 => charts.series_4 orelse zcolors.rgba(98, 205, 128, 255),
            4 => charts.series_5 orelse self.theme.colors.primary,
            5 => charts.series_6 orelse self.theme.colors.primary,
            else => self.theme.colors.primary,
        };
    }

    fn textInputStateStyle(
        self: *const App,
        state: widgets.text_input.TextInputState,
        opts: widgets.text_input.Options,
    ) zui.ui.theme_engine.style_sheet.TextInputStateStyle {
        const style = self.sharedStyleSheet().text_input;
        if (opts.disabled) return style.states.disabled;
        if (opts.read_only) return style.states.read_only;
        if (state.focused) return style.states.focused;
        if (state.hovered) return style.states.hover;
        return .{};
    }

    fn textInputFillPaint(
        self: *const App,
        state: widgets.text_input.TextInputState,
        opts: widgets.text_input.Options,
    ) Paint {
        const style = self.sharedStyleSheet().text_input;
        const override = self.textInputStateStyle(state, opts);
        if (override.fill) |paint| return paint;
        if (style.fill) |paint| return paint;
        if (opts.disabled) return Paint{ .solid = zcolors.withAlpha(self.theme.colors.surface, 0.5) };
        if (opts.read_only) return Paint{ .solid = self.theme.colors.surface };
        if (state.focused) return Paint{ .solid = zcolors.blend(self.theme.colors.background, self.theme.colors.primary, 0.05) };
        if (state.hovered) return Paint{ .solid = zcolors.blend(self.theme.colors.background, self.theme.colors.primary, 0.03) };
        return Paint{ .solid = self.theme.colors.background };
    }

    fn textInputBorderColor(
        self: *const App,
        state: widgets.text_input.TextInputState,
        opts: widgets.text_input.Options,
    ) [4]f32 {
        const style = self.sharedStyleSheet().text_input;
        const override = self.textInputStateStyle(state, opts);
        if (override.border) |color| return color;
        if (style.border) |color| return color;
        if (opts.disabled) return zcolors.withAlpha(self.theme.colors.border, 0.3);
        if (state.focused) return self.theme.colors.primary;
        if (state.hovered) return zcolors.blend(self.theme.colors.border, self.theme.colors.primary, 0.2);
        return self.theme.colors.border;
    }

    fn textInputTextColor(
        self: *const App,
        state: widgets.text_input.TextInputState,
        opts: widgets.text_input.Options,
    ) [4]f32 {
        const style = self.sharedStyleSheet().text_input;
        const override = self.textInputStateStyle(state, opts);
        if (override.text) |color| return color;
        if (style.text) |color| return color;
        if (opts.disabled) return zcolors.withAlpha(self.theme.colors.text_primary, 0.45);
        return self.theme.colors.text_primary;
    }

    fn textInputPlaceholderColor(
        self: *const App,
        state: widgets.text_input.TextInputState,
        opts: widgets.text_input.Options,
    ) [4]f32 {
        const style = self.sharedStyleSheet().text_input;
        const override = self.textInputStateStyle(state, opts);
        return override.placeholder orelse style.placeholder orelse self.theme.colors.text_secondary;
    }

    fn textInputSelectionColor(
        self: *const App,
        state: widgets.text_input.TextInputState,
        opts: widgets.text_input.Options,
    ) [4]f32 {
        const style = self.sharedStyleSheet().text_input;
        const override = self.textInputStateStyle(state, opts);
        return override.selection orelse style.selection orelse zcolors.withAlpha(self.theme.colors.primary, 0.3);
    }

    fn textInputCaretColor(
        self: *const App,
        state: widgets.text_input.TextInputState,
        opts: widgets.text_input.Options,
    ) [4]f32 {
        const style = self.sharedStyleSheet().text_input;
        const override = self.textInputStateStyle(state, opts);
        return override.caret orelse style.caret orelse self.theme.colors.primary;
    }

    fn invalidateGlyphWidthCache(self: *App) void {
        for (&self.ascii_glyph_width_cache) |*value| {
            value.* = -1.0;
        }
        for (self.debug.debug_events.items) |*entry| {
            entry.payload_wrap_rows_valid = false;
            entry.cached_visible_rows_valid = false;
        }
        self.debug.debug_fold_revision +%= 1;
        if (self.debug.debug_fold_revision == 0) self.debug.debug_fold_revision = 1;
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

        const shell = self.sharedStyleSheet().shell;
        const surfaces = self.sharedStyleSheet().surfaces;
        const full_rect = Rect.fromXYWH(0, 0, @floatFromInt(fb_width), @floatFromInt(fb_height));
        self.drawPaintRect(
            full_rect,
            surfaces.background orelse Paint{ .solid = self.theme.colors.background },
        );
        self.drawPaintRect(
            content_rect,
            shell.dock_fill orelse surfaces.surface orelse Paint{ .solid = self.theme.colors.surface },
        );
        if (shell.dock_border) |dock_border| self.drawRect(content_rect, dock_border);

        const launcher_modal_open = self.ws.launcher_create_modal_open;
        const about_modal_open = self.about_modal_open;
        const recipe_modal_open = self.ws.launcher_recipe_modal != null;
        const saved_mouse_down = self.mouse_down;
        const saved_mouse_clicked = self.mouse_clicked;
        const saved_mouse_released = self.mouse_released;
        const saved_mouse_right_clicked = self.mouse_right_clicked;
        if (launcher_modal_open or about_modal_open or recipe_modal_open) {
            // Keep launcher visible under the modal, but route pointer input only to modal widgets.
            self.mouse_down = false;
            self.mouse_clicked = false;
            self.mouse_released = false;
            self.mouse_right_clicked = false;
        }

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

        const sidebar_fill = shell.sidebar_fill orelse surfaces.surface orelse Paint{ .solid = self.theme.colors.surface };
        const sidebar_border = self.sharedStyleSheet().panel.border orelse self.theme.colors.border;
        self.drawPaintRect(left_rect, sidebar_fill);
        self.drawRect(left_rect, sidebar_border);
        self.drawPaintRect(right_rect, sidebar_fill);
        self.drawRect(right_rect, sidebar_border);

        var left_y = left_rect.min[1] + pad;
        const title = "Spiderweb Connections";
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
            self.ws.launcher_selected_profile_index,
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
                    self.ws.launcher_selected_profile_index = idx;
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
            self.ws.launcher_profile_name.items,
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
            self.ws.launcher_profile_metadata.items,
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
            "Access Token",
            self.theme.colors.text_secondary,
        );
        left_y += layout.line_height + layout.row_gap * 0.25;
        const connect_token_focused = self.drawTextInputWidget(
            Rect.fromXYWH(left_rect.min[0] + pad, left_y, profile_row_w, layout.input_height),
            self.ws.launcher_connect_token.items,
            self.settings_panel.focused_field == .launcher_connect_token,
            .{
                .placeholder = "Spiderweb access token",
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
        self.drawLabel(right_rect.min[0] + pad, right_y, onboardingStageHeadline(self.ws.onboarding_stage), self.theme.colors.text_primary);
        right_y += layout.line_height + layout.row_gap * 0.45;

        const stage_detail = switch (self.ws.onboarding_stage) {
            .connect => "Save a connection profile, add an access token, and connect to Spiderweb.",
            .choose_workspace => "Choose the workspace you want to open first, or create a new one with strong defaults.",
            .workspace_ready => "Open the workspace shell directly, or jump into Devices, Capabilities, Explore, or Settings.",
        };
        self.drawTextTrimmed(
            right_rect.min[0] + pad,
            right_y,
            right_rect.width() - pad * 2.0,
            stage_detail,
            self.theme.colors.text_secondary,
        );
        right_y += layout.line_height + layout.row_gap * 0.7;
        if (self.ws.launcher_notice) |notice| {
            self.drawTextTrimmed(
                right_rect.min[0] + pad,
                right_y,
                right_rect.width() - pad * 2.0,
                notice,
                self.theme.colors.text_secondary,
            );
            right_y += layout.line_height + layout.row_gap * 0.7;
        }

        const route_gap = @max(6.0 * self.ui_scale, layout.row_gap * 0.4);
        const route_rect_w = (right_rect.width() - pad * 2.0 - route_gap * 4.0) / 5.0;
        var route_x = right_rect.min[0] + pad;
        for ([_]HomeRoute{ .workspace, .devices, .capabilities, .explore, .settings }) |route| {
            if (self.drawButtonWidget(
                Rect.fromXYWH(route_x, right_y, route_rect_w, layout.button_height),
                homeRouteLabel(route),
                .{ .variant = if (self.ws.home_route == route) .primary else .secondary },
            )) {
                self.ws.home_route = route;
            }
            route_x += route_rect_w + route_gap;
        }
        right_y += layout.button_height + layout.row_gap * 0.8;

        const home_content_rect = Rect.fromXYWH(
            right_rect.min[0] + pad,
            right_y,
            right_rect.width() - pad * 2.0,
            @max(1.0, right_rect.max[1] - right_y - pad),
        );
        switch (self.ws.home_route) {
            .workspace => self.drawLauncherWorkspaceRoute(home_content_rect),
            .devices => self.drawLauncherDevicesRoute(home_content_rect),
            .capabilities => self.drawLauncherCapabilitiesRoute(home_content_rect),
            .explore => self.drawLauncherExploreRoute(home_content_rect),
            .settings => self.drawLauncherSettingsRoute(home_content_rect),
        }

        _ = self.drawWindowMenuBar(ui_window, fb_width);
        self.drawStatusOverlay(fb_width, fb_height);
        if (launcher_modal_open or about_modal_open or recipe_modal_open) {
            self.mouse_down = saved_mouse_down;
            self.mouse_clicked = saved_mouse_clicked;
            self.mouse_released = saved_mouse_released;
            self.mouse_right_clicked = saved_mouse_right_clicked;
            if (launcher_modal_open) self.drawLauncherCreateWorkspaceModal(fb_width, fb_height);
            if (about_modal_open) self.drawAboutModal(fb_width, fb_height);
            if (recipe_modal_open) self.drawLauncherRecipeModal(fb_width, fb_height);
        }
        if (self.ws.workspace_wizard_open) {
            self.mouse_down = saved_mouse_down;
            self.mouse_clicked = saved_mouse_clicked;
            self.mouse_released = saved_mouse_released;
            self.mouse_right_clicked = saved_mouse_right_clicked;
            self.drawWorkspaceWizardModal(fb_width, fb_height);
        }
    }

    pub fn drawLauncherCreateWorkspaceModal(self: *App, fb_width: u32, fb_height: u32) void {
        const layout = self.panelLayoutMetrics();
        const pad = @max(layout.inset, 12.0 * self.ui_scale);
        const row_h = @max(layout.button_height, 34.0 * self.ui_scale);
        const screen_rect = Rect.fromXYWH(0, 0, @floatFromInt(fb_width), @floatFromInt(fb_height));

        self.drawFilledRect(screen_rect, zcolors.withAlpha(self.theme.colors.background, 0.68));

        const modal_w = std.math.clamp(
            screen_rect.width() * 0.62,
            420.0 * self.ui_scale,
            760.0 * self.ui_scale,
        );
        const modal_h = std.math.clamp(
            screen_rect.height() * 0.72,
            360.0 * self.ui_scale,
            640.0 * self.ui_scale,
        );
        const modal_rect = Rect.fromXYWH(
            screen_rect.min[0] + (screen_rect.width() - modal_w) * 0.5,
            screen_rect.min[1] + (screen_rect.height() - modal_h) * 0.5,
            modal_w,
            modal_h,
        );

        self.drawSurfacePanel(modal_rect);
        self.drawRect(modal_rect, self.theme.colors.border);

        var y = modal_rect.min[1] + pad;
        const field_w = modal_rect.width() - pad * 2.0;

        self.drawLabel(modal_rect.min[0] + pad, y, "Create Workspace", self.theme.colors.text_primary);
        y += layout.line_height + layout.row_gap * 0.35;
        self.drawTextTrimmed(
            modal_rect.min[0] + pad,
            y,
            field_w,
            "Pick a Spiderweb template and create a new workspace.",
            self.theme.colors.text_secondary,
        );
        y += layout.line_height + layout.row_gap * 0.8;

        if (self.ws.launcher_create_modal_error) |message| {
            self.drawTextTrimmed(
                modal_rect.min[0] + pad,
                y,
                field_w,
                message,
                zcolors.rgba(220, 80, 80, 255),
            );
            y += layout.line_height + layout.row_gap * 0.65;
        }

        self.drawLabel(modal_rect.min[0] + pad, y, "Workspace Name", self.theme.colors.text_secondary);
        y += layout.line_height + layout.row_gap * 0.25;
        const name_focused = self.drawTextInputWidget(
            Rect.fromXYWH(modal_rect.min[0] + pad, y, field_w, layout.input_height),
            self.settings_panel.project_create_name.items,
            self.settings_panel.focused_field == .project_create_name,
            .{ .placeholder = "Example: Distributed Workspace" },
        );
        if (name_focused) self.settings_panel.focused_field = .project_create_name;
        y += layout.input_height + layout.row_gap * 0.6;

        self.drawLabel(modal_rect.min[0] + pad, y, "Vision (Optional)", self.theme.colors.text_secondary);
        y += layout.line_height + layout.row_gap * 0.25;
        const vision_focused = self.drawTextInputWidget(
            Rect.fromXYWH(modal_rect.min[0] + pad, y, field_w, layout.input_height),
            self.settings_panel.project_create_vision.items,
            self.settings_panel.focused_field == .project_create_vision,
            .{ .placeholder = "Short goal or context" },
        );
        if (vision_focused) self.settings_panel.focused_field = .project_create_vision;
        y += layout.input_height + layout.row_gap * 0.8;

        const action_y = modal_rect.max[1] - pad - row_h;
        const detail_h = layout.line_height * 2.2;
        const detail_y = action_y - layout.row_gap - detail_h;

        const template_header_y = y;
        self.drawLabel(modal_rect.min[0] + pad, template_header_y, "Template", self.theme.colors.text_secondary);

        const refresh_w = @max(160.0 * self.ui_scale, self.measureText("Refresh Templates") + pad * 1.4);
        const refresh_rect = Rect.fromXYWH(
            modal_rect.max[0] - pad - refresh_w,
            template_header_y - @max(0.0, (row_h - layout.line_height) * 0.3),
            refresh_w,
            row_h,
        );
        if (self.drawButtonWidget(
            refresh_rect,
            "Refresh Templates",
            .{ .variant = .secondary, .disabled = self.connection_state != .connected },
        )) {
            self.clearLauncherCreateWorkspaceModalError();
            self.refreshLauncherCreateWorkspaceTemplates() catch |err| {
                const msg = self.formatControlOpError("Workspace template list failed", err);
                if (msg) |text| {
                    defer self.allocator.free(text);
                    self.setLauncherCreateWorkspaceModalError(text);
                } else {
                    self.setLauncherCreateWorkspaceModalError("Workspace template list failed.");
                }
            };
        }
        y += row_h + layout.row_gap * 0.4;

        const list_bottom = detail_y - layout.row_gap * 0.5;
        const list_h = @max(88.0 * self.ui_scale, list_bottom - y);
        const list_rect = Rect.fromXYWH(modal_rect.min[0] + pad, y, field_w, list_h);
        self.drawSurfacePanel(list_rect);
        self.drawRect(list_rect, self.theme.colors.border);

        const template_count = self.ws.launcher_create_templates.items.len;
        const template_row_h = @max(layout.button_height, 30.0 * self.ui_scale);
        const template_row_gap = layout.row_gap * 0.45;
        const template_row_step = template_row_h + template_row_gap;
        const list_inner_h = @max(0.0, list_rect.height() - layout.inner_inset * 2.0);
        const rows_per_page = blk: {
            if (template_row_step <= 0.0 or list_inner_h <= 0.0) break :blk @as(usize, 1);
            const rows_fit = @floor((list_inner_h + template_row_gap) / template_row_step);
            break :blk @max(@as(usize, 1), @as(usize, @intFromFloat(rows_fit)));
        };
        const total_pages = if (template_count == 0)
            @as(usize, 1)
        else
            (template_count / rows_per_page) + @as(usize, @intFromBool((template_count % rows_per_page) != 0));
        if (self.ws.launcher_create_template_page >= total_pages) {
            self.ws.launcher_create_template_page = total_pages - 1;
        }

        const pager_button_w = @max(62.0 * self.ui_scale, self.measureText("Next") + pad * 1.05);
        const pager_gap = @max(6.0 * self.ui_scale, layout.row_gap * 0.4);
        const next_rect = Rect.fromXYWH(
            refresh_rect.min[0] - pager_gap - pager_button_w,
            refresh_rect.min[1],
            pager_button_w,
            row_h,
        );
        const prev_rect = Rect.fromXYWH(
            next_rect.min[0] - pager_gap - pager_button_w,
            refresh_rect.min[1],
            pager_button_w,
            row_h,
        );
        if (self.drawButtonWidget(
            prev_rect,
            "Prev",
            .{ .variant = .secondary, .disabled = template_count == 0 or self.ws.launcher_create_template_page == 0 },
        )) {
            self.ws.launcher_create_template_page -= 1;
        }
        if (self.drawButtonWidget(
            next_rect,
            "Next",
            .{
                .variant = .secondary,
                .disabled = template_count == 0 or (self.ws.launcher_create_template_page + 1) >= total_pages,
            },
        )) {
            self.ws.launcher_create_template_page += 1;
        }

        const page_line = std.fmt.allocPrint(
            self.allocator,
            "Page {d}/{d}",
            .{ self.ws.launcher_create_template_page + 1, total_pages },
        ) catch null;
        defer if (page_line) |value| self.allocator.free(value);
        if (page_line) |value| {
            const label_x = modal_rect.min[0] + pad + self.measureText("Template") + pad * 0.45;
            const label_w = @max(0.0, prev_rect.min[0] - pager_gap - label_x);
            self.drawTextTrimmed(
                label_x,
                template_header_y,
                label_w,
                value,
                self.theme.colors.text_secondary,
            );
        }

        if (template_count == 0) {
            self.drawTextTrimmed(
                list_rect.min[0] + layout.inner_inset,
                list_rect.min[1] + layout.inner_inset,
                list_rect.width() - layout.inner_inset * 2.0,
                "No templates returned by Spiderweb. Use Refresh Templates.",
                self.theme.colors.text_secondary,
            );
        } else {
            const page_start = self.ws.launcher_create_template_page * rows_per_page;
            const page_end = @min(page_start + rows_per_page, template_count);
            var row_y = list_rect.min[1] + layout.inner_inset;
            const row_max_y = list_rect.max[1] - layout.inner_inset;
            for (self.ws.launcher_create_templates.items[page_start..page_end], page_start..) |template, idx| {
                if (row_y + template_row_h > row_max_y) break;
                if (self.drawButtonWidget(
                    Rect.fromXYWH(
                        list_rect.min[0] + layout.inner_inset,
                        row_y,
                        list_rect.width() - layout.inner_inset * 2.0,
                        template_row_h,
                    ),
                    template.id,
                    .{ .variant = if (idx == self.ws.launcher_create_selected_template_index) .primary else .secondary },
                )) {
                    self.ws.launcher_create_selected_template_index = idx;
                    self.syncLauncherCreateSelectedTemplateToSettings() catch {};
                    self.clearLauncherCreateWorkspaceModalError();
                }
                row_y += template_row_step;
            }
        }

        const detail_rect = Rect.fromXYWH(modal_rect.min[0] + pad, detail_y, field_w, detail_h);
        self.drawSurfacePanel(detail_rect);
        self.drawRect(detail_rect, self.theme.colors.border);
        if (self.selectedLauncherCreateWorkspaceTemplate()) |template| {
            const desc = if (template.description.len > 0) template.description else "(no description)";
        const binds_line = std.fmt.allocPrint(
            self.allocator,
            "Selected: {s} | packages: {d}",
            .{ template.id, template.binds.items.len },
        ) catch null;
            defer if (binds_line) |value| self.allocator.free(value);
            if (binds_line) |value| {
                self.drawTextTrimmed(
                    detail_rect.min[0] + layout.inner_inset,
                    detail_rect.min[1] + layout.inner_inset * 0.7,
                    detail_rect.width() - layout.inner_inset * 2.0,
                    value,
                    self.theme.colors.text_primary,
                );
            }
            self.drawTextTrimmed(
                detail_rect.min[0] + layout.inner_inset,
                detail_rect.min[1] + layout.inner_inset * 0.7 + layout.line_height,
                detail_rect.width() - layout.inner_inset * 2.0,
                desc,
                self.theme.colors.text_secondary,
            );
        } else {
            self.drawTextTrimmed(
                detail_rect.min[0] + layout.inner_inset,
                detail_rect.min[1] + layout.inner_inset * 0.7,
                detail_rect.width() - layout.inner_inset * 2.0,
                "Select a template to continue.",
                self.theme.colors.text_secondary,
            );
        }

        const button_w = (field_w - pad) * 0.5;
        const cancel_rect = Rect.fromXYWH(modal_rect.min[0] + pad, action_y, button_w, row_h);
        if (self.drawButtonWidget(cancel_rect, "Cancel", .{ .variant = .secondary })) {
            self.closeLauncherCreateWorkspaceModal();
            return;
        }

        const trimmed_name = std.mem.trim(u8, self.settings_panel.project_create_name.items, " \t\r\n");
        const create_disabled = self.connection_state != .connected or
            trimmed_name.len == 0 or
            self.ws.launcher_create_templates.items.len == 0;
        if (self.drawButtonWidget(
            Rect.fromXYWH(cancel_rect.max[0] + pad, action_y, button_w, row_h),
            "Create Workspace",
            .{ .variant = .primary, .disabled = create_disabled },
        )) {
            self.createWorkspaceFromLauncherModal() catch |err| {
                const msg = self.formatControlOpError("Workspace create failed", err);
                if (msg) |text| {
                    defer self.allocator.free(text);
                    self.setLauncherCreateWorkspaceModalError(text);
                } else {
                    self.setLauncherCreateWorkspaceModalError("Workspace create failed.");
                }
            };
        }

        if (self.mouse_released and !modal_rect.contains(.{ self.mouse_x, self.mouse_y })) {
            self.closeLauncherCreateWorkspaceModal();
        }
    }

    fn launcherLocalDeviceSummary(self: *App) []const u8 {
        if (self.connection_state != .connected) return "Connect to check this Mac";

        const local_node = self.config.appLocalNode(self.config.selectedProfileId()) orelse return "Not prepared yet";
        const now_ms = std.time.milliTimestamp();
        for (self.ws.nodes.items) |node| {
            if (!std.mem.eql(u8, node.node_id, local_node.node_id)) continue;
            return if (node.lease_expires_at_ms > now_ms) "Online" else "Needs attention";
        }
        return "Waiting to connect";
    }

    fn launcherDriveLabel(self: *App) []const u8 {
        if (self.ws.workspace_state) |*status| {
            if (status.workspace_root) |root| {
                const trimmed = std.mem.trim(u8, root, " \t\r\n");
                if (trimmed.len > 0) return root;
            }
            if (status.mounts.items.len > 0) return status.mounts.items[0].mount_path;
        }
        if (self.ws.selected_workspace_detail) |*detail| {
            if (detail.mounts.items.len > 0) return detail.mounts.items[0].mount_path;
        }
        return "Mount a drive to begin";
    }

    fn drawLauncherActionCard(
        self: *App,
        rect: Rect,
        title: []const u8,
        body: []const u8,
        button_label: []const u8,
        enabled: bool,
    ) bool {
        const layout = self.panelLayoutMetrics();
        const pad = @max(layout.inner_inset, 10.0 * self.ui_scale);
        const button_h = @max(layout.button_height, 34.0 * self.ui_scale);
        self.drawSurfacePanel(rect);
        self.drawTextTrimmed(
            rect.min[0] + pad,
            rect.min[1] + pad,
            rect.width() - pad * 2.0,
            title,
            self.theme.colors.text_primary,
        );
        self.drawTextTrimmed(
            rect.min[0] + pad,
            rect.min[1] + pad + layout.line_height + layout.row_gap * 0.3,
            rect.width() - pad * 2.0,
            body,
            self.theme.colors.text_secondary,
        );
        return self.drawButtonWidget(
            Rect.fromXYWH(
                rect.min[0] + pad,
                rect.max[1] - pad - button_h,
                rect.width() - pad * 2.0,
                button_h,
            ),
            button_label,
            .{ .variant = .secondary, .disabled = !enabled },
        );
    }

    fn drawLauncherRecipeCard(
        self: *App,
        rect: Rect,
        eyebrow: []const u8,
        title: []const u8,
        body: []const u8,
        progress: LauncherRecipeProgress,
        button_label: []const u8,
        enabled: bool,
    ) bool {
        const layout = self.panelLayoutMetrics();
        const pad = @max(layout.inner_inset, 10.0 * self.ui_scale);
        const button_h = @max(layout.button_height, 34.0 * self.ui_scale);
        self.drawSurfacePanel(rect);
        self.drawTextTrimmed(
            rect.min[0] + pad,
            rect.min[1] + pad,
            rect.width() - pad * 2.0 - 88.0 * self.ui_scale,
            eyebrow,
            self.theme.colors.text_secondary,
        );
        const progress_label = launcherRecipeProgressLabel(progress);
        const progress_color = self.launcherRecipeProgressColor(progress);
        const badge_w = @max(64.0 * self.ui_scale, self.measureText(progress_label) + pad * 1.2);
        const badge_rect = Rect.fromXYWH(
            rect.max[0] - pad - badge_w,
            rect.min[1] + pad - 2.0 * self.ui_scale,
            badge_w,
            layout.button_height * 0.82,
        );
        self.drawFilledRect(badge_rect, zcolors.withAlpha(progress_color, 28));
        self.drawRect(badge_rect, progress_color);
        self.drawTextTrimmed(
            badge_rect.min[0] + pad * 0.4,
            badge_rect.min[1] + @max(0.0, (badge_rect.height() - layout.line_height) * 0.5),
            badge_rect.width() - pad * 0.8,
            progress_label,
            progress_color,
        );
        self.drawTextTrimmed(
            rect.min[0] + pad,
            rect.min[1] + pad + layout.line_height,
            rect.width() - pad * 2.0,
            title,
            self.theme.colors.text_primary,
        );
        self.drawTextTrimmed(
            rect.min[0] + pad,
            rect.min[1] + pad + layout.line_height * 2.0 + layout.row_gap * 0.25,
            rect.width() - pad * 2.0,
            body,
            self.theme.colors.text_secondary,
        );
        return self.drawButtonWidget(
            Rect.fromXYWH(
                rect.min[0] + pad,
                rect.max[1] - pad - button_h,
                rect.width() - pad * 2.0,
                button_h,
            ),
            button_label,
            .{ .variant = .secondary, .disabled = !enabled },
        );
    }

    fn launcherRecipeSpec(recipe: LauncherRecipe) LauncherRecipeSpec {
        return switch (recipe) {
            .create_workspace => .{
                .eyebrow = "RECIPE",
                .title = "Create a useful workspace",
                .summary = "Start with one workspace that has a clear job. Keep the scope obvious, then enter the workspace shell before expanding into more devices or packages.",
                .steps = .{
                    "Pick a clear workspace name and short goal.",
                    "Choose the smallest template that matches the job.",
                    "Open the workspace shell, then add devices or packages only when needed.",
                },
                .primary_label = "Create Workspace",
                .secondary_label = "Open Workspace",
            },
            .add_second_device => .{
                .eyebrow = "RECIPE",
                .title = "Add a second device",
                .summary = "Once the first workspace is healthy, bring in another machine so the workspace can span more than one device and you can see distributed behavior directly.",
                .steps = .{
                    "Use Spiderweb on the host Mac to copy a network URL and access token.",
                    "Connect from the second machine with that URL and token.",
                    "Return to Devices and confirm the machine appears online in the workspace.",
                },
                .primary_label = "Open Devices",
                .secondary_label = "Open Settings",
            },
            .install_package => .{
                .eyebrow = "RECIPE",
                .title = "Install a package",
                .summary = "Add the next useful capability after first success. Start with tools or services you will actually use, not every package at once.",
                .steps = .{
                    "Open Capabilities for the selected workspace.",
                    "Refresh packages and inspect what is already installed.",
                    "Enable the next useful package, then return to the workspace to use it.",
                },
                .primary_label = "Open Capabilities",
                .secondary_label = "Refresh Packages",
            },
            .run_remote_service => .{
                .eyebrow = "RECIPE",
                .title = "Open a remote terminal",
                .summary = "Use Spiderweb to open a real terminal on the selected workspace device so you can inspect files, run commands, and prove remote execution is working.",
                .steps = .{
                    "Choose or confirm the workspace you want to work in.",
                    "Open the terminal and let SpiderApp target the best available device terminal.",
                    "Run commands there to inspect the workspace and confirm which device is hosting the shell.",
                },
                .primary_label = "Open Remote Terminal",
                .secondary_label = "Open Devices",
            },
            .connect_to_spiderweb => .{
                .eyebrow = "REMOTE CONNECTION",
                .title = "Connect SpiderApp to another Spiderweb",
                .summary = "Save a profile, paste the server URL and access token, connect, then choose the workspace you want to open first.",
                .steps = .{
                    "Create or select a connection profile on the left.",
                    "Paste the Spiderweb server URL and access token.",
                    "Connect, refresh, then choose the workspace you want to open.",
                },
                .primary_label = "Connect",
                .secondary_label = "Refresh",
            },
            .workspace_tokens => .{
                .eyebrow = "WORKSPACE TOKENS",
                .title = "Share workspace-scoped access carefully",
                .summary = "Use workspace tokens when a tool or user should access one workspace without holding the broader connection token.",
                .steps = .{
                    "Connect to Spiderweb and select the right workspace first.",
                    "Open Settings to manage the workspace-scoped token surfaces.",
                    "Share the narrowest token that matches the task instead of the broader connection token.",
                },
                .primary_label = "Open Settings",
                .secondary_label = null,
            },
            .connect_another_machine => .{
                .eyebrow = "RECIPE",
                .title = "Connect another machine",
                .summary = "Use Spiderweb on the host Mac to copy a network URL and access token, then connect from the second machine and confirm it joins the workspace.",
                .steps = .{
                    "On the host Mac, reveal a network URL and access token.",
                    "Use those details on the second machine to connect back to Spiderweb.",
                    "Return here and confirm the new device shows up online.",
                },
                .primary_label = "Open Settings",
                .secondary_label = "Open Devices",
            },
            .contribute_this_mac => .{
                .eyebrow = "RECIPE",
                .title = "Contribute this Mac remotely",
                .summary = "Use Spiderweb.app on this Mac to pair it with an invite token when another Spiderweb should see this machine as a device.",
                .steps = .{
                    "Open the host-side setup and switch to the pairing flow.",
                    "Paste the remote control URL and invite token.",
                    "Pair this Mac, then verify it appears in the remote workspace topology.",
                },
                .primary_label = "Advanced Setup",
                .secondary_label = "Open Settings",
            },
        };
    }

    fn openLauncherRecipeModal(self: *App, recipe: LauncherRecipe) void {
        self.ws.launcher_recipe_modal = recipe;
    }

    fn closeLauncherRecipeModal(self: *App) void {
        self.ws.launcher_recipe_modal = null;
    }

    fn runLauncherRecipePrimaryAction(self: *App, recipe: LauncherRecipe) void {
        self.closeLauncherRecipeModal();
        switch (recipe) {
            .create_workspace => self.openLauncherCreateWorkspaceModal(),
            .add_second_device => {
                self.ws.home_route = .devices;
                self.openSelectedHomeRoute() catch {};
            },
            .install_package => {
                self.ws.home_route = .capabilities;
                self.openSelectedHomeRoute() catch {};
            },
            .run_remote_service => {
                self.openRemoteTerminalForSelectedWorkspace(null) catch |err| {
                    if (self.formatFilesystemOpError("Remote terminal", err)) |text| {
                        defer self.allocator.free(text);
                        self.setLauncherNotice(text);
                    } else {
                        self.setLauncherNotice("Unable to open the remote terminal.");
                    }
                };
            },
            .connect_to_spiderweb => {
                if (self.connection_state == .connected) {
                    self.refreshWorkspaceData() catch {};
                } else {
                    self.persistLauncherConnectToken() catch {};
                    self.tryConnect(&self.manager) catch {};
                }
            },
            .workspace_tokens => {
                self.ws.home_route = .settings;
                self.openSelectedHomeRoute() catch {};
            },
            .connect_another_machine => {
                self.ws.home_route = .settings;
                self.openSelectedHomeRoute() catch {};
            },
            .contribute_this_mac => self.openWorkspaceWizard(),
        }
    }

    fn runLauncherRecipeSecondaryAction(self: *App, recipe: LauncherRecipe) void {
        self.closeLauncherRecipeModal();
        switch (recipe) {
            .create_workspace => {
                self.ws.home_route = .workspace;
                self.openSelectedHomeRoute() catch {};
            },
            .run_remote_service => {
                self.ws.home_route = .devices;
                self.openSelectedHomeRoute() catch {};
            },
            .add_second_device, .contribute_this_mac, .workspace_tokens => {
                self.ws.home_route = .settings;
                self.openSelectedHomeRoute() catch {};
            },
            .connect_another_machine => {
                self.ws.home_route = .devices;
                self.openSelectedHomeRoute() catch {};
            },
            .install_package => {
                self.requestPackageManagerRefresh(true);
                self.requestVenomRefresh(true);
            },
            .connect_to_spiderweb => {
                if (self.connection_state == .connected) self.refreshWorkspaceData() catch {};
            },
        }
    }

    fn launcherRecipePrimaryEnabled(self: *const App, recipe: LauncherRecipe) bool {
        const can_open = self.connection_state == .connected and (self.selectedWorkspaceId() != null or self.ws.projects.items.len == 1);
        const has_connect_details = self.launcherConnectDetails() != null;
        return switch (recipe) {
            .create_workspace => self.connection_state == .connected,
            .add_second_device => has_connect_details,
            .install_package => can_open,
            .run_remote_service => can_open and self.ws.nodes.items.len > 0,
            .connect_to_spiderweb => self.connection_state != .connecting,
            .workspace_tokens => can_open,
            .connect_another_machine => can_open,
            .contribute_this_mac => self.connection_state == .connected,
        };
    }

    fn launcherRecipeSecondaryEnabled(self: *const App, recipe: LauncherRecipe) bool {
        const can_open = self.connection_state == .connected and (self.selectedWorkspaceId() != null or self.ws.projects.items.len == 1);
        return switch (recipe) {
            .create_workspace => can_open,
            .add_second_device => self.connection_state == .connected,
            .install_package => self.connection_state == .connected,
            .run_remote_service => can_open,
            .connect_to_spiderweb => self.connection_state == .connected,
            .workspace_tokens => can_open,
            .connect_another_machine => can_open,
            .contribute_this_mac => can_open,
        };
    }

    fn workflowIdForLauncherRecipe(recipe: LauncherRecipe) ?[]const u8 {
        return switch (recipe) {
            .create_workspace => workflow_start_local_workspace,
            .add_second_device, .connect_another_machine => workflow_add_second_device,
            .install_package => workflow_install_package,
            .run_remote_service => workflow_run_remote_service,
            .connect_to_spiderweb => workflow_connect_to_another_spiderweb,
            .workspace_tokens, .contribute_this_mac => null,
        };
    }

    fn selectedOrOnlyWorkspaceId(self: *const App) ?[]const u8 {
        if (self.selectedWorkspaceId()) |workspace_id| return workspace_id;
        if (self.ws.projects.items.len == 1) return self.ws.projects.items[0].id;
        return null;
    }

    fn launcherRecipeUsesWorkspaceScope(recipe: LauncherRecipe) bool {
        return switch (recipe) {
            .create_workspace,
            .add_second_device,
            .connect_another_machine,
            .install_package,
            .run_remote_service,
            => true,
            .connect_to_spiderweb,
            .workspace_tokens,
            .contribute_this_mac,
            => false,
        };
    }

    fn hasCompletedWorkflowForRecipe(self: *const App, recipe: LauncherRecipe) bool {
        const workflow_id = workflowIdForLauncherRecipe(recipe) orelse return false;
        const profile_id = self.config.selectedProfileId();

        if (launcherRecipeUsesWorkspaceScope(recipe)) {
            if (self.selectedOrOnlyWorkspaceId()) |workspace_id| {
                return self.config.isWorkflowCompleted(profile_id, workspace_id, workflow_id);
            }
            const entries = self.config.onboarding_workflows orelse return false;
            for (entries) |entry| {
                if (!std.mem.eql(u8, entry.profile_id, profile_id)) continue;
                if (!std.mem.eql(u8, entry.workflow_id, workflow_id)) continue;
                return true;
            }
            return false;
        }

        return self.config.isWorkflowCompleted(profile_id, null, workflow_id);
    }

    fn launcherConnectDetails(self: *const App) ?LauncherConnectDetails {
        const workspace_id = self.selectedOrOnlyWorkspaceId() orelse return null;
        const workspace_name = if (self.selectedWorkspaceSummary()) |selected_ws|
            selected_ws.name
        else if (self.ws.projects.items.len == 1)
            self.ws.projects.items[0].name
        else
            workspace_id;

        const server_url = blk: {
            const from_settings = std.mem.trim(u8, self.settings_panel.server_url.items, " \t\r\n");
            if (from_settings.len > 0) break :blk from_settings;
            const from_config = std.mem.trim(u8, self.config.server_url, " \t\r\n");
            if (from_config.len > 0) break :blk from_config;
            return null;
        };

        const active_role_token = self.config.activeRoleToken();
        if (active_role_token.len > 0) {
            return .{
                .server_url = server_url,
                .token_label = switch (self.config.active_role) {
                    .admin => "admin",
                    .user => "user",
                },
                .token = active_role_token,
                .workspace_id = workspace_id,
                .workspace_name = workspace_name,
            };
        }
        const admin_token = self.config.getRoleToken(.admin);
        if (admin_token.len > 0) {
            return .{
                .server_url = server_url,
                .token_label = "admin",
                .token = admin_token,
                .workspace_id = workspace_id,
                .workspace_name = workspace_name,
            };
        }
        const user_token = self.config.getRoleToken(.user);
        if (user_token.len > 0) {
            return .{
                .server_url = server_url,
                .token_label = "user",
                .token = user_token,
                .workspace_id = workspace_id,
                .workspace_name = workspace_name,
            };
        }
        return null;
    }

    fn copyLauncherConnectDetailsField(self: *App, value: []const u8, success_message: []const u8) void {
        self.copyTextToClipboard(value) catch {
            self.setLauncherNotice("Unable to copy the selected value.");
            return;
        };
        self.setLauncherNotice(success_message);
    }

    fn copyLauncherConnectDetailsSummary(self: *App) void {
        const details = self.launcherConnectDetails() orelse {
            self.setLauncherNotice("Choose a workspace and save a profile token before sharing this Spiderweb.");
            return;
        };
        const summary = std.fmt.allocPrint(
            self.allocator,
            "Spiderweb URL: {s}\nAccess token ({s}): {s}\nWorkspace: {s} ({s})",
            .{ details.server_url, details.token_label, details.token, details.workspace_name, details.workspace_id },
        ) catch {
            self.setLauncherNotice("Unable to build the second-device setup summary.");
            return;
        };
        defer self.allocator.free(summary);
        self.copyLauncherConnectDetailsField(summary, "Copied the second-device setup summary.");
    }

    fn launcherRecipeProgress(self: *App, recipe: LauncherRecipe) LauncherRecipeProgress {
        const can_open = self.connection_state == .connected and (self.selectedWorkspaceId() != null or self.ws.projects.items.len == 1);
        const package_count = self.packageCount();
        const selected_workspace_done = self.selectedWorkspaceId() != null or self.ws.projects.items.len == 1;
        const has_connect_details = self.launcherConnectDetails() != null;
        if (self.hasCompletedWorkflowForRecipe(recipe)) return .done;
        return switch (recipe) {
            .create_workspace => if (self.ws.projects.items.len > 0) .done else if (self.connection_state == .connected) .ready else .guide,
            .add_second_device => if (self.ws.nodes.items.len > 1) .done else if (has_connect_details) .ready else .guide,
            .install_package => if (package_count > 0) .done else if (can_open) .ready else .guide,
            .run_remote_service => if (can_open and self.ws.nodes.items.len > 0) .ready else .guide,
            .connect_to_spiderweb => if (self.connection_state == .connected) .done else if (self.settings_panel.server_url.items.len > 0 and self.ws.launcher_connect_token.items.len > 0) .ready else .guide,
            .workspace_tokens => blk: {
                const workspace_id = self.selectedWorkspaceId() orelse if (self.ws.projects.items.len == 1) self.ws.projects.items[0].id else null;
                if (workspace_id) |id| {
                    if (self.selectedWorkspaceToken(id)) |token| {
                        if (token.len > 0) break :blk .done;
                    }
                    if (can_open) break :blk .ready;
                }
                break :blk .guide;
            },
            .connect_another_machine => if (self.ws.nodes.items.len > 1) .done else if (has_connect_details) .ready else .guide,
            .contribute_this_mac => if (selected_workspace_done and self.ws.nodes.items.len > 1) .done else if (self.connection_state == .connected) .ready else .guide,
        };
    }

    fn launcherRecipeProgressLabel(progress: LauncherRecipeProgress) []const u8 {
        return switch (progress) {
            .guide => "Guide",
            .ready => "Ready",
            .done => "Done",
        };
    }

    fn launcherRecipeProgressColor(self: *App, progress: LauncherRecipeProgress) zcolors.Color {
        return switch (progress) {
            .guide => self.theme.colors.text_secondary,
            .ready => zcolors.rgba(224, 145, 36, 255),
            .done => zcolors.rgba(36, 174, 100, 255),
        };
    }

    fn drawLauncherWorkspaceRoute(self: *App, rect: Rect) void {
        const layout = self.panelLayoutMetrics();
        const pad = @max(layout.inner_inset, 10.0 * self.ui_scale);
        const gap = @max(layout.row_gap, 8.0 * self.ui_scale);
        const card_h = @max(84.0 * self.ui_scale, layout.button_height * 2.4);
        const card_w = (rect.width() - gap * 3.0) / 4.0;
        const selected_workspace = self.selectedWorkspaceSummary();
        const workspace_name = if (selected_workspace) |selected_ws| selected_ws.name else "Choose a workspace";
        const workspace_status = if (selected_workspace) |selected_ws| selected_ws.status else "Pick or create your first workspace";
        const drive_label = self.launcherDriveLabel();
        const local_device_summary = self.launcherLocalDeviceSummary();
        var device_count_buf: [32]u8 = undefined;
        var package_count_buf: [32]u8 = undefined;
        const package_count = @max(self.package_manager_packages.items.len, self.ws.venom_entries.items.len);
        const device_count = std.fmt.bufPrint(&device_count_buf, "{d}", .{self.ws.nodes.items.len}) catch "0";
        const package_count_text = std.fmt.bufPrint(&package_count_buf, "{d}", .{package_count}) catch "0";

        self.drawMissionSummaryCard(
            Rect.fromXYWH(rect.min[0], rect.min[1], card_w, card_h),
            zcolors.rgba(64, 166, 255, 255),
            "Workspace",
            workspace_name,
            workspace_status,
        );
        self.drawMissionSummaryCard(
            Rect.fromXYWH(rect.min[0] + card_w + gap, rect.min[1], card_w, card_h),
            zcolors.rgba(48, 189, 134, 255),
            "Drive",
            drive_label,
            "The mounted path SpiderApp will work from",
        );
        self.drawMissionSummaryCard(
            Rect.fromXYWH(rect.min[0] + (card_w + gap) * 2.0, rect.min[1], card_w, card_h),
            zcolors.rgba(255, 166, 61, 255),
            "Devices",
            device_count,
            local_device_summary,
        );
        self.drawMissionSummaryCard(
            Rect.fromXYWH(rect.min[0] + (card_w + gap) * 3.0, rect.min[1], card_w, card_h),
            zcolors.rgba(196, 111, 255, 255),
            "Packages",
            package_count_text,
            "Installed capabilities ready for this workspace",
        );

        const body_y = rect.min[1] + card_h + gap;
        const left_w = @max(260.0 * self.ui_scale, rect.width() * 0.45);
        const right_w = @max(240.0 * self.ui_scale, rect.width() - left_w - gap);
        const left_rect = Rect.fromXYWH(rect.min[0], body_y, left_w, @max(1.0, rect.max[1] - body_y));
        const right_rect = Rect.fromXYWH(left_rect.max[0] + gap, body_y, right_w, @max(1.0, rect.max[1] - body_y));

        self.drawSurfacePanel(left_rect);
        self.drawTextTrimmed(
            left_rect.min[0] + pad,
            left_rect.min[1] + pad,
            left_rect.width() - pad * 2.0,
            "Workspace list",
            self.theme.colors.text_primary,
        );
        const filter_focused = self.drawTextInputWidget(
            Rect.fromXYWH(
                left_rect.min[0] + pad,
                left_rect.min[1] + pad + layout.line_height + layout.row_gap * 0.35,
                left_rect.width() - pad * 2.0,
                layout.input_height,
            ),
            self.ws.launcher_project_filter.items,
            self.settings_panel.focused_field == .launcher_project_filter,
            .{ .placeholder = "Filter by name or id" },
        );
        if (filter_focused) self.settings_panel.focused_field = .launcher_project_filter;

        const list_top = left_rect.min[1] + pad + layout.line_height + layout.row_gap * 0.35 + layout.input_height + layout.row_gap * 0.5;
        const list_rect = Rect.fromXYWH(
            left_rect.min[0] + pad,
            list_top,
            left_rect.width() - pad * 2.0,
            @max(80.0 * self.ui_scale, left_rect.max[1] - list_top - pad),
        );
        self.drawSurfacePanel(list_rect);
        var row_y = list_rect.min[1] + layout.inner_inset;
        const row_h = @max(layout.button_height, 34.0 * self.ui_scale);
        const selected_workspace_id = self.selectedWorkspaceId();
        const filter = std.mem.trim(u8, self.ws.launcher_project_filter.items, " \t\r\n");
        var visible_count: usize = 0;
        for (self.ws.projects.items) |project_summary| {
            if (filter.len > 0 and
                std.ascii.indexOfIgnoreCase(project_summary.name, filter) == null and
                std.ascii.indexOfIgnoreCase(project_summary.id, filter) == null)
            {
                continue;
            }
            visible_count += 1;
            if (row_y + row_h > list_rect.max[1] - layout.inner_inset) break;
            var row_buf: [256]u8 = undefined;
            const row_label = std.fmt.bufPrint(
                &row_buf,
                "{s}  [{s}]",
                .{ project_summary.name, project_summary.status },
            ) catch project_summary.name;
            const is_selected = if (selected_workspace_id) |workspace_id|
                std.mem.eql(u8, project_summary.id, workspace_id)
            else
                false;
            if (self.drawButtonWidget(
                Rect.fromXYWH(
                    list_rect.min[0] + layout.inner_inset,
                    row_y,
                    list_rect.width() - layout.inner_inset * 2.0,
                    row_h,
                ),
                row_label,
                .{ .variant = if (is_selected) .primary else .secondary },
            )) {
                self.selectWorkspaceInSettings(project_summary.id) catch {};
                self.refreshWorkspaceData() catch {};
            }
            row_y += row_h + layout.row_gap * 0.35;
        }
        if (visible_count == 0) {
            self.drawTextTrimmed(
                list_rect.min[0] + layout.inner_inset,
                list_rect.min[1] + layout.inner_inset,
                list_rect.width() - layout.inner_inset * 2.0,
                if (self.ws.projects.items.len == 0) "No workspaces yet. Create one to get started." else "No workspaces match the current filter.",
                self.theme.colors.text_secondary,
            );
        }

        self.drawSurfacePanel(right_rect);
        var detail_y = right_rect.min[1] + pad;
        self.drawTextTrimmed(
            right_rect.min[0] + pad,
            detail_y,
            right_rect.width() - pad * 2.0,
            if (selected_workspace) |selected_ws| selected_ws.name else "Workspace details",
            self.theme.colors.text_primary,
        );
        detail_y += layout.line_height + layout.row_gap * 0.35;
        self.drawTextTrimmed(
            right_rect.min[0] + pad,
            detail_y,
            right_rect.width() - pad * 2.0,
            if (selected_workspace) |selected_ws| selected_ws.vision else "Select a workspace to see its drive, status, and next steps.",
            self.theme.colors.text_secondary,
        );
        detail_y += layout.line_height * 2.0 + layout.row_gap * 0.25;

        if (self.ws.selected_workspace_detail) |*detail| {
            var summary_buf: [256]u8 = undefined;
            const summary_text = std.fmt.bufPrint(
                &summary_buf,
                "Status: {s}  |  Drives: {d}  |  Packages: {d}",
                .{ detail.status, detail.mounts.items.len, package_count },
            ) catch detail.status;
            self.drawTextTrimmed(
                right_rect.min[0] + pad,
                detail_y,
                right_rect.width() - pad * 2.0,
                summary_text,
                self.theme.colors.text_secondary,
            );
            detail_y += layout.line_height + layout.row_gap * 0.35;
        }

        self.drawTextTrimmed(
            right_rect.min[0] + pad,
            detail_y,
            right_rect.width() - pad * 2.0,
            drive_label,
            self.theme.colors.text_primary,
        );
        detail_y += layout.line_height + layout.row_gap * 0.35;
        self.drawTextTrimmed(
            right_rect.min[0] + pad,
            detail_y,
            right_rect.width() - pad * 2.0,
            "SpiderApp will open into the workspace shell and keep Devices, Capabilities, Explore, and Settings close by after this first step.",
            self.theme.colors.text_secondary,
        );

        const can_enter_workspace = self.connection_state == .connected and (self.selectedWorkspaceId() != null or self.ws.projects.items.len == 1);
        const button_y = right_rect.max[1] - pad - row_h;
        const button_gap = @max(layout.row_gap * 0.5, 8.0 * self.ui_scale);
        const button_w = (right_rect.width() - pad * 2.0 - button_gap * 2.0) / 3.0;
        if (self.drawButtonWidget(
            Rect.fromXYWH(right_rect.min[0] + pad, button_y, button_w, row_h),
            "Enter Workspace",
            .{ .variant = .primary, .disabled = !can_enter_workspace },
        )) {
            self.ws.home_route = .workspace;
            self.openSelectedHomeRoute() catch |err| {
                const msg = self.formatControlOpError("Open workspace", err);
                if (msg) |text| {
                    defer self.allocator.free(text);
                    self.setLauncherNotice(text);
                } else {
                    self.setLauncherNotice("Unable to open the workspace.");
                }
            };
        }
        if (self.drawButtonWidget(
            Rect.fromXYWH(right_rect.min[0] + pad + button_w + button_gap, button_y, button_w, row_h),
            "Create Workspace",
            .{ .variant = .secondary, .disabled = self.connection_state != .connected },
        )) {
            self.openLauncherCreateWorkspaceModal();
        }
        if (self.drawButtonWidget(
            Rect.fromXYWH(right_rect.min[0] + pad + (button_w + button_gap) * 2.0, button_y, button_w, row_h),
            "Advanced",
            .{ .variant = .secondary, .disabled = self.connection_state != .connected },
        )) {
            self.openWorkspaceWizard();
        }
    }

    fn drawLauncherDevicesRoute(self: *App, rect: Rect) void {
        const layout = self.panelLayoutMetrics();
        const pad = @max(layout.inner_inset, 10.0 * self.ui_scale);
        const gap = @max(layout.row_gap, 8.0 * self.ui_scale);
        const card_h = @max(84.0 * self.ui_scale, layout.button_height * 2.4);
        const card_w = (rect.width() - gap * 2.0) / 3.0;
        var node_count_buf: [32]u8 = undefined;
        var drive_count_buf: [32]u8 = undefined;
        const drive_count = if (self.ws.selected_workspace_detail) |*detail| detail.mounts.items.len else 0;
        const node_count_text = std.fmt.bufPrint(&node_count_buf, "{d}", .{self.ws.nodes.items.len}) catch "0";
        const drive_count_text = std.fmt.bufPrint(&drive_count_buf, "{d}", .{drive_count}) catch "0";

        self.drawMissionSummaryCard(
            Rect.fromXYWH(rect.min[0], rect.min[1], card_w, card_h),
            zcolors.rgba(255, 166, 61, 255),
            "Local Device",
            self.launcherLocalDeviceSummary(),
            "This Mac powers the first workspace experience",
        );
        self.drawMissionSummaryCard(
            Rect.fromXYWH(rect.min[0] + card_w + gap, rect.min[1], card_w, card_h),
            zcolors.rgba(64, 166, 255, 255),
            "Connected Devices",
            node_count_text,
            "Every device contributing to the current workspace",
        );
        self.drawMissionSummaryCard(
            Rect.fromXYWH(rect.min[0] + (card_w + gap) * 2.0, rect.min[1], card_w, card_h),
            zcolors.rgba(48, 189, 134, 255),
            "Drives",
            drive_count_text,
            "Mounted workspace drives available right now",
        );

        const list_y = rect.min[1] + card_h + gap;
        const list_rect = Rect.fromXYWH(rect.min[0], list_y, rect.width(), @max(1.0, rect.max[1] - list_y));
        self.drawSurfacePanel(list_rect);
        self.drawTextTrimmed(
            list_rect.min[0] + pad,
            list_rect.min[1] + pad,
            list_rect.width() - pad * 2.0,
            "Devices",
            self.theme.colors.text_primary,
        );
        self.drawTextTrimmed(
            list_rect.min[0] + pad,
            list_rect.min[1] + pad + layout.line_height + layout.row_gap * 0.2,
            list_rect.width() - pad * 2.0,
            "Start with this Mac, then add another machine when you want the workspace to span devices.",
            self.theme.colors.text_secondary,
        );

        var row_y = list_rect.min[1] + pad + layout.line_height * 2.0 + layout.row_gap * 0.55;
        const row_h = @max(layout.button_height, 34.0 * self.ui_scale);
        const now_ms = std.time.milliTimestamp();
        if (self.ws.nodes.items.len == 0) {
            self.drawTextTrimmed(
                list_rect.min[0] + pad,
                row_y,
                list_rect.width() - pad * 2.0,
                "No devices are connected yet. Use the follow-on flow to connect another machine or contribute this Mac to another Spiderweb.",
                self.theme.colors.text_secondary,
            );
        } else {
            for (self.ws.nodes.items, 0..) |node, idx| {
                if (row_y + row_h > list_rect.max[1] - pad - row_h - layout.row_gap) break;
                const row_rect = Rect.fromXYWH(list_rect.min[0] + pad, row_y, list_rect.width() - pad * 2.0, row_h);
                if (idx % 2 == 1) {
                    self.drawFilledRect(row_rect, zcolors.withAlpha(self.theme.colors.border, 20));
                }
                const status_color = if (node.lease_expires_at_ms > now_ms)
                    zcolors.rgba(36, 174, 100, 255)
                else
                    zcolors.rgba(220, 80, 60, 255);
                self.drawFilledRect(
                    Rect.fromXYWH(
                        row_rect.min[0] + 8.0 * self.ui_scale,
                        row_rect.min[1] + (row_h - 10.0 * self.ui_scale) * 0.5,
                        10.0 * self.ui_scale,
                        10.0 * self.ui_scale,
                    ),
                    status_color,
                );
                var row_buf: [256]u8 = undefined;
                const label = std.fmt.bufPrint(
                    &row_buf,
                    "{s}  ({s})",
                    .{ node.node_name, if (node.lease_expires_at_ms > now_ms) "online" else "degraded" },
                ) catch node.node_name;
                self.drawTextTrimmed(
                    row_rect.min[0] + 26.0 * self.ui_scale,
                    row_rect.min[1] + (row_h - layout.line_height) * 0.5,
                    row_rect.width() - 34.0 * self.ui_scale,
                    label,
                    self.theme.colors.text_primary,
                );
                row_y += row_h + layout.row_gap * 0.35;
            }
        }

        const can_open = self.connection_state == .connected and (self.selectedWorkspaceId() != null or self.ws.projects.items.len == 1);
        const button_y = list_rect.max[1] - pad - row_h;
        const button_gap = @max(layout.row_gap * 0.5, 8.0 * self.ui_scale);
        const button_w = (list_rect.width() - pad * 2.0 - button_gap * 2.0) / 3.0;
        const recipe_y = button_y - gap - card_h;
        if (recipe_y > row_y + gap) {
            const recipe_w = (list_rect.width() - pad * 2.0 - gap) * 0.5;
            if (self.drawLauncherRecipeCard(
                Rect.fromXYWH(list_rect.min[0] + pad, recipe_y, recipe_w, card_h),
                "RECIPE",
                "Connect another machine",
                "Use Spiderweb on the host Mac to copy a network URL and access token, then connect from the second machine and return here to confirm it joined the workspace.",
                self.launcherRecipeProgress(.connect_another_machine),
                "Open Settings",
                self.connection_state == .connected,
            )) {
                self.openLauncherRecipeModal(.connect_another_machine);
            }
            if (self.drawLauncherRecipeCard(
                Rect.fromXYWH(list_rect.min[0] + pad + recipe_w + gap, recipe_y, recipe_w, card_h),
                "RECIPE",
                "Contribute this Mac remotely",
                "Use Spiderweb.app on this Mac to pair it with an invite token when another Spiderweb should see this machine as a device.",
                self.launcherRecipeProgress(.contribute_this_mac),
                "Advanced Setup",
                self.connection_state == .connected,
            )) {
                self.openLauncherRecipeModal(.contribute_this_mac);
            }
        }

        if (self.drawButtonWidget(
            Rect.fromXYWH(list_rect.min[0] + pad, button_y, button_w, row_h),
            "Open Devices",
            .{ .variant = .primary, .disabled = !can_open },
        )) {
            self.ws.home_route = .devices;
            self.openSelectedHomeRoute() catch |err| {
                const msg = self.formatControlOpError("Open devices", err);
                if (msg) |text| {
                    defer self.allocator.free(text);
                    self.setLauncherNotice(text);
                } else {
                    self.setLauncherNotice("Unable to open Devices.");
                }
            };
        }
        if (self.drawButtonWidget(
            Rect.fromXYWH(list_rect.min[0] + pad + button_w + button_gap, button_y, button_w, row_h),
            "Refresh Devices",
            .{ .variant = .secondary, .disabled = self.connection_state != .connected },
        )) {
            self.refreshWorkspaceData() catch |err| {
                const msg = self.formatControlOpError("Refresh devices", err);
                if (msg) |text| {
                    defer self.allocator.free(text);
                    self.setLauncherNotice(text);
                } else {
                    self.setLauncherNotice("Unable to refresh devices.");
                }
            };
        }
        if (self.drawButtonWidget(
            Rect.fromXYWH(list_rect.min[0] + pad + (button_w + button_gap) * 2.0, button_y, button_w, row_h),
            "Advanced Setup",
            .{ .variant = .secondary, .disabled = self.connection_state != .connected },
        )) {
            self.openWorkspaceWizard();
        }
    }

    fn drawLauncherCapabilitiesRoute(self: *App, rect: Rect) void {
        const layout = self.panelLayoutMetrics();
        const pad = @max(layout.inner_inset, 10.0 * self.ui_scale);
        const gap = @max(layout.row_gap, 8.0 * self.ui_scale);
        const card_h = @max(84.0 * self.ui_scale, layout.button_height * 2.4);
        const card_w = (rect.width() - gap * 2.0) / 3.0;
        const package_count = @max(self.package_manager_packages.items.len, self.ws.venom_entries.items.len);
        var package_count_buf: [32]u8 = undefined;
        var device_count_buf: [32]u8 = undefined;
        const package_count_text = std.fmt.bufPrint(&package_count_buf, "{d}", .{package_count}) catch "0";
        const device_count_text = std.fmt.bufPrint(&device_count_buf, "{d}", .{self.ws.nodes.items.len}) catch "0";

        self.drawMissionSummaryCard(
            Rect.fromXYWH(rect.min[0], rect.min[1], card_w, card_h),
            zcolors.rgba(196, 111, 255, 255),
            "Packages",
            package_count_text,
            "Install capabilities only after the workspace is ready",
        );
        self.drawMissionSummaryCard(
            Rect.fromXYWH(rect.min[0] + card_w + gap, rect.min[1], card_w, card_h),
            zcolors.rgba(64, 166, 255, 255),
            "Workspace",
            if (self.selectedWorkspaceSummary()) |selected_ws| selected_ws.name else "No workspace selected",
            "Capabilities follow the selected workspace",
        );
        self.drawMissionSummaryCard(
            Rect.fromXYWH(rect.min[0] + (card_w + gap) * 2.0, rect.min[1], card_w, card_h),
            zcolors.rgba(255, 166, 61, 255),
            "Devices",
            device_count_text,
            "Devices expose packages and services into the workspace",
        );

        const body_y = rect.min[1] + card_h + gap;
        const body_rect = Rect.fromXYWH(rect.min[0], body_y, rect.width(), @max(1.0, rect.max[1] - body_y));
        self.drawSurfacePanel(body_rect);
        self.drawTextTrimmed(
            body_rect.min[0] + pad,
            body_rect.min[1] + pad,
            body_rect.width() - pad * 2.0,
            "Capabilities",
            self.theme.colors.text_primary,
        );
        self.drawTextTrimmed(
            body_rect.min[0] + pad,
            body_rect.min[1] + pad + layout.line_height + layout.row_gap * 0.35,
            body_rect.width() - pad * 2.0,
            "Packages turn the workspace into something useful: coding tools, agents, local services, and other workspace behaviors. Older internal docs may still call them venoms, but the onboarding flow stays package-first.",
            self.theme.colors.text_secondary,
        );

        var row_y = body_rect.min[1] + pad + layout.line_height * 3.0;
        if (self.package_manager_packages.items.len == 0 and self.ws.venom_entries.items.len == 0) {
            self.drawTextTrimmed(
                body_rect.min[0] + pad,
                row_y,
                body_rect.width() - pad * 2.0,
                "No packages loaded yet. Open Capabilities after the workspace is running to inspect what is installed or add more.",
                self.theme.colors.text_secondary,
            );
        } else {
            self.drawTextTrimmed(
                body_rect.min[0] + pad,
                row_y,
                body_rect.width() - pad * 2.0,
                "Recently seen packages",
                self.theme.colors.text_primary,
            );
            row_y += layout.line_height + layout.row_gap * 0.35;
            var shown: usize = 0;
            for (self.package_manager_packages.items) |entry| {
                if (shown >= 5) break;
                var line_buf: [256]u8 = undefined;
                const line = std.fmt.bufPrint(
                    &line_buf,
                    "{s}  [{s}]",
                    .{ entry.package_id, if (entry.enabled) "enabled" else "disabled" },
                ) catch entry.package_id;
                self.drawTextTrimmed(
                    body_rect.min[0] + pad,
                    row_y,
                    body_rect.width() - pad * 2.0,
                    line,
                    self.theme.colors.text_secondary,
                );
                row_y += layout.line_height + layout.row_gap * 0.25;
                shown += 1;
            }
            if (shown == 0) {
                for (self.ws.venom_entries.items) |entry| {
                    if (shown >= 5) break;
                    self.drawTextTrimmed(
                        body_rect.min[0] + pad,
                        row_y,
                        body_rect.width() - pad * 2.0,
                        entry.venom_id,
                        self.theme.colors.text_secondary,
                    );
                    row_y += layout.line_height + layout.row_gap * 0.25;
                    shown += 1;
                }
            }
        }

        const row_h = @max(layout.button_height, 34.0 * self.ui_scale);
        const button_y = body_rect.max[1] - pad - row_h;
        const button_gap = @max(layout.row_gap * 0.5, 8.0 * self.ui_scale);
        const button_w = (body_rect.width() - pad * 2.0 - button_gap * 2.0) / 3.0;
        const can_open = self.connection_state == .connected and (self.selectedWorkspaceId() != null or self.ws.projects.items.len == 1);
        const recipe_h = @max(96.0 * self.ui_scale, layout.button_height * 2.8);
        const recipe_gap = @max(layout.row_gap * 0.5, 8.0 * self.ui_scale);
        const recipe_y = button_y - recipe_gap - recipe_h;
        if (recipe_y > row_y + recipe_gap) {
            const recipe_w = (body_rect.width() - pad * 2.0 - recipe_gap) * 0.5;
            if (self.drawLauncherRecipeCard(
                Rect.fromXYWH(body_rect.min[0] + pad, recipe_y, recipe_w, recipe_h),
                "PACKAGE RECIPE",
                "Make the workspace useful",
                "Start with a small set of packages that match the job: coding tools, agents, or one service you actually need. Avoid turning everything on at once.",
                self.launcherRecipeProgress(.install_package),
                "Open Capabilities",
                can_open,
            )) {
                self.openLauncherRecipeModal(.install_package);
            }
            if (self.drawLauncherRecipeCard(
                Rect.fromXYWH(body_rect.min[0] + pad + recipe_w + recipe_gap, recipe_y, recipe_w, recipe_h),
                "SERVICE RECIPE",
                "Run a remote service",
                "Packages can expose services into the workspace after the drive and devices are stable. Open Capabilities, refresh packages, then enable the specific service you need.",
                self.launcherRecipeProgress(.run_remote_service),
                "Refresh Packages",
                self.connection_state == .connected,
            )) {
                self.openLauncherRecipeModal(.run_remote_service);
            }
        }

        if (self.drawButtonWidget(
            Rect.fromXYWH(body_rect.min[0] + pad, button_y, button_w, row_h),
            "Open Capabilities",
            .{ .variant = .primary, .disabled = !can_open },
        )) {
            self.ws.home_route = .capabilities;
            self.openSelectedHomeRoute() catch |err| {
                const msg = self.formatControlOpError("Open capabilities", err);
                if (msg) |text| {
                    defer self.allocator.free(text);
                    self.setLauncherNotice(text);
                } else {
                    self.setLauncherNotice("Unable to open Capabilities.");
                }
            };
        }
        if (self.drawButtonWidget(
            Rect.fromXYWH(body_rect.min[0] + pad + button_w + button_gap, button_y, button_w, row_h),
            "Refresh Packages",
            .{ .variant = .secondary, .disabled = self.connection_state != .connected },
        )) {
            self.requestPackageManagerRefresh(true);
            self.requestVenomRefresh(true);
        }
        if (self.drawButtonWidget(
            Rect.fromXYWH(body_rect.min[0] + pad + (button_w + button_gap) * 2.0, button_y, button_w, row_h),
            "Advanced Setup",
            .{ .variant = .secondary, .disabled = self.connection_state != .connected },
        )) {
            self.openWorkspaceWizard();
        }
    }

    fn drawLauncherExploreRoute(self: *App, rect: Rect) void {
        const layout = self.panelLayoutMetrics();
        const gap = @max(layout.row_gap, 8.0 * self.ui_scale);
        const card_h = (rect.height() - gap) * 0.5;
        const card_w = (rect.width() - gap) * 0.5;
        const can_open = self.connection_state == .connected and (self.selectedWorkspaceId() != null or self.ws.projects.items.len == 1);

        if (self.drawLauncherRecipeCard(
            Rect.fromXYWH(rect.min[0], rect.min[1], card_w, card_h),
            "RECIPE",
            "Create a useful workspace",
            "Create or pick one workspace with a clear purpose first. Keep the name obvious, keep the scope small, then enter the workspace shell before expanding further.",
            self.launcherRecipeProgress(.create_workspace),
            "Create Workspace",
            self.connection_state == .connected,
        )) {
            self.openLauncherRecipeModal(.create_workspace);
        }
        if (self.drawLauncherRecipeCard(
            Rect.fromXYWH(rect.min[0] + card_w + gap, rect.min[1], card_w, card_h),
            "RECIPE",
            "Add a second device",
            "Once the first workspace is healthy, bring in another machine so the workspace can span more than one device and you can see distributed behavior directly.",
            self.launcherRecipeProgress(.add_second_device),
            "Open Devices",
            can_open,
        )) {
            self.openLauncherRecipeModal(.add_second_device);
        }
        if (self.drawLauncherRecipeCard(
            Rect.fromXYWH(rect.min[0], rect.min[1] + card_h + gap, card_w, card_h),
            "RECIPE",
            "Install a package",
            "Add the next useful capability after first success. Start with tools or services you will actually use, not every package at once.",
            self.launcherRecipeProgress(.install_package),
            "Open Capabilities",
            can_open,
        )) {
            self.openLauncherRecipeModal(.install_package);
        }
        if (self.drawLauncherRecipeCard(
            Rect.fromXYWH(rect.min[0] + card_w + gap, rect.min[1] + card_h + gap, card_w, card_h),
            "RECIPE",
            "Run a remote service",
            "After the workspace and devices are stable, use Capabilities and Workspace together: enable the package, confirm the device is online, then inspect the workspace and topology.",
            self.launcherRecipeProgress(.run_remote_service),
            "Open Workspace",
            can_open,
        )) {
            self.openLauncherRecipeModal(.run_remote_service);
        }
    }

    fn drawLauncherSettingsRoute(self: *App, rect: Rect) void {
        const layout = self.panelLayoutMetrics();
        const pad = @max(layout.inner_inset, 10.0 * self.ui_scale);
        const gap = @max(layout.row_gap, 8.0 * self.ui_scale);
        const selected_profile = self.config.selectedProfile();
        const selected_workspace = self.selectedWorkspaceSummary();
        const row_h = @max(layout.button_height, 34.0 * self.ui_scale);
        self.drawSurfacePanel(rect);

        var y = rect.min[1] + pad;
        self.drawTextTrimmed(
            rect.min[0] + pad,
            y,
            rect.width() - pad * 2.0,
            "Settings",
            self.theme.colors.text_primary,
        );
        y += layout.line_height + layout.row_gap * 0.35;

        var profile_buf: [512]u8 = undefined;
        const profile_line = std.fmt.bufPrint(
            &profile_buf,
            "Profile: {s}  |  Server: {s}",
            .{ selected_profile.name, selected_profile.server_url },
        ) catch selected_profile.name;
        self.drawTextTrimmed(
            rect.min[0] + pad,
            y,
            rect.width() - pad * 2.0,
            profile_line,
            self.theme.colors.text_secondary,
        );
        y += layout.line_height + layout.row_gap * 0.25;

        const role_label = if (self.config.active_role == .admin) "Admin" else "User";
        var workspace_buf: [512]u8 = undefined;
        const workspace_line = std.fmt.bufPrint(
            &workspace_buf,
            "Role: {s}  |  Workspace: {s}",
            .{ role_label, if (selected_workspace) |selected_ws| selected_ws.name else "Not selected" },
        ) catch role_label;
        self.drawTextTrimmed(
            rect.min[0] + pad,
            y,
            rect.width() - pad * 2.0,
            workspace_line,
            self.theme.colors.text_secondary,
        );
        y += layout.line_height + layout.row_gap * 0.35;

        self.drawTextTrimmed(
            rect.min[0] + pad,
            y,
            rect.width() - pad * 2.0,
            "Manual controls still live here: connection profile management, role changes, workspace tokens, and advanced setup tools.",
            self.theme.colors.text_secondary,
        );
        y += layout.line_height * 2.0 + layout.row_gap * 0.45;

        const can_open = self.connection_state == .connected and (self.selectedWorkspaceId() != null or self.ws.projects.items.len == 1);
        const recipe_h = @max(96.0 * self.ui_scale, row_h * 2.8);
        const recipe_w = (rect.width() - pad * 2.0 - gap) * 0.5;
        if (self.drawLauncherRecipeCard(
            Rect.fromXYWH(rect.min[0] + pad, y, recipe_w, recipe_h),
            "REMOTE CONNECTION",
            "Connect SpiderApp to another Spiderweb",
            "Save a profile, paste the server URL and access token, connect, then pick the workspace you want to open first.",
            self.launcherRecipeProgress(.connect_to_spiderweb),
            if (self.connection_state == .connected) "Refresh" else "Connect",
            self.connection_state != .connecting,
        )) {
            self.openLauncherRecipeModal(.connect_to_spiderweb);
        }
        if (self.drawLauncherRecipeCard(
            Rect.fromXYWH(rect.min[0] + pad + recipe_w + gap, y, recipe_w, recipe_h),
            "WORKSPACE TOKENS",
            "Share workspace-scoped access carefully",
            "Use workspace tokens when a tool or user should access one workspace without holding the broader connection token. Settings is where those manual controls stay.",
            self.launcherRecipeProgress(.workspace_tokens),
            "Open Settings",
            can_open,
        )) {
            self.openLauncherRecipeModal(.workspace_tokens);
        }

        const button_y = rect.max[1] - pad - row_h;
        const button_w = (rect.width() - pad * 2.0 - gap * 2.0) / 3.0;
        if (self.drawButtonWidget(
            Rect.fromXYWH(rect.min[0] + pad, button_y, button_w, row_h),
            "Open Settings",
            .{ .variant = .primary, .disabled = !can_open },
        )) {
            self.ws.home_route = .settings;
            self.openSelectedHomeRoute() catch |err| {
                const msg = self.formatControlOpError("Open settings", err);
                if (msg) |text| {
                    defer self.allocator.free(text);
                    self.setLauncherNotice(text);
                } else {
                    self.setLauncherNotice("Unable to open Settings.");
                }
            };
        }
        if (self.drawButtonWidget(
            Rect.fromXYWH(rect.min[0] + pad + button_w + gap, button_y, button_w, row_h),
            "Advanced Setup",
            .{ .variant = .secondary, .disabled = self.connection_state != .connected },
        )) {
            self.openWorkspaceWizard();
        }
        if (self.drawButtonWidget(
            Rect.fromXYWH(rect.min[0] + pad + (button_w + gap) * 2.0, button_y, button_w, row_h),
            if (self.connection_state == .connected) "Refresh" else "Connect",
            .{ .variant = .secondary, .disabled = self.connection_state == .connecting },
        )) {
            if (self.connection_state == .connected) {
                self.refreshWorkspaceData() catch |err| {
                    const msg = self.formatControlOpError("Refresh settings", err);
                    if (msg) |text| {
                        defer self.allocator.free(text);
                        self.setLauncherNotice(text);
                    } else {
                        self.setLauncherNotice("Unable to refresh settings.");
                    }
                };
            } else {
                self.persistLauncherConnectToken() catch |err| {
                    const msg = std.fmt.allocPrint(self.allocator, "Unable to persist token: {s}", .{@errorName(err)}) catch null;
                    defer if (msg) |value| self.allocator.free(value);
                    if (msg) |value| self.setLauncherNotice(value);
                    return;
                };
                self.tryConnect(&self.manager) catch |err| {
                    const msg = self.formatControlOpError("Connect", err);
                    if (msg) |text| {
                        defer self.allocator.free(text);
                        self.setLauncherNotice(text);
                    }
                };
            }
        }
    }

    fn openSelectedHomeRoute(self: *App) !void {
        if (self.selectedWorkspaceId() == null and self.ws.projects.items.len == 1) {
            try self.selectWorkspaceInSettings(self.ws.projects.items[0].id);
        }

        try self.openSelectedWorkspaceFromLauncher();

        switch (self.ws.home_route) {
            .workspace => {
                _ = self.ensureWorkspacePanel(&self.manager) catch {};
                _ = self.ensureDashboardPanel(&self.manager) catch {};
                _ = self.ensureFilesystemPanel(&self.manager) catch {};
            },
            .devices => {
                _ = self.ensureWorkspacePanel(&self.manager) catch {};
                _ = self.ensureNodeTopologyPanel(&self.manager) catch {};
            },
            .capabilities => {
                _ = self.ensureWorkspacePanel(&self.manager) catch {};
                self.requestVenomRefresh(true);
                self.requestPackageManagerRefresh(true);
                _ = self.ensureVenomManagerPanel(&self.manager) catch {};
            },
            .explore => {
                _ = self.ensureWorkspacePanel(&self.manager) catch {};
                _ = self.ensureDashboardPanel(&self.manager) catch {};
                _ = self.ensureFilesystemPanel(&self.manager) catch {};
            },
            .settings => {
                _ = self.ensureWorkspacePanel(&self.manager) catch {};
                self.ensureSettingsPanel(&self.manager);
            },
        }
    }

    fn drawPackageManagerModal(self: *App, fb_width: u32, fb_height: u32) void {
        const layout = self.panelLayoutMetrics();
        const pad = @max(layout.inset, 12.0 * self.ui_scale);
        const row_h = @max(layout.button_height, 34.0 * self.ui_scale);
        const screen_rect = Rect.fromXYWH(0, 0, @floatFromInt(fb_width), @floatFromInt(fb_height));

        self.drawFilledRect(screen_rect, zcolors.withAlpha(self.theme.colors.background, 0.68));

        const modal_w = std.math.clamp(
            screen_rect.width() * 0.72,
            560.0 * self.ui_scale,
            980.0 * self.ui_scale,
        );
        const modal_h = std.math.clamp(
            screen_rect.height() * 0.78,
            420.0 * self.ui_scale,
            760.0 * self.ui_scale,
        );
        const modal_rect = Rect.fromXYWH(
            screen_rect.min[0] + (screen_rect.width() - modal_w) * 0.5,
            screen_rect.min[1] + (screen_rect.height() - modal_h) * 0.5,
            modal_w,
            modal_h,
        );

        self.drawSurfacePanel(modal_rect);
        self.drawRect(modal_rect, self.theme.colors.border);

        const left_w = @max(220.0 * self.ui_scale, modal_rect.width() * 0.38);
        const right_w = modal_rect.width() - left_w - pad * 3.0;
        const left_rect = Rect.fromXYWH(modal_rect.min[0] + pad, modal_rect.min[1] + pad, left_w, modal_rect.height() - pad * 2.0);
        const right_rect = Rect.fromXYWH(left_rect.max[0] + pad, modal_rect.min[1] + pad, right_w, modal_rect.height() - pad * 2.0);

        self.drawLabel(left_rect.min[0], left_rect.min[1], "Packages", self.theme.colors.text_primary);
        self.drawLabel(right_rect.min[0], right_rect.min[1], "Package Manager", self.theme.colors.text_primary);

        const left_y = left_rect.min[1] + layout.line_height + layout.row_gap * 0.6;
        const list_h = @max(120.0 * self.ui_scale, left_rect.height() - row_h - layout.row_gap - (left_y - left_rect.min[1]));
        const list_rect = Rect.fromXYWH(left_rect.min[0], left_y, left_rect.width(), list_h);
        self.drawSurfacePanel(list_rect);
        self.drawRect(list_rect, self.theme.colors.border);

        var row_y = list_rect.min[1] + layout.inner_inset;
        const row_w = list_rect.width() - layout.inner_inset * 2.0;
        for (self.package_manager_packages.items, 0..) |entry, idx| {
            if (row_y + row_h > list_rect.max[1] - layout.inner_inset) break;
            const label = std.fmt.allocPrint(
                self.allocator,
                "{s} [{s}]",
                .{ entry.package_id, if (entry.enabled) "enabled" else "disabled" },
            ) catch null;
            defer if (label) |value| self.allocator.free(value);
            if (self.drawButtonWidget(
                Rect.fromXYWH(list_rect.min[0] + layout.inner_inset, row_y, row_w, row_h),
                label orelse entry.package_id,
                .{ .variant = if (idx == self.package_manager_selected_index) .primary else .secondary },
            )) {
                self.package_manager_selected_index = idx;
                self.clearPackageManagerModalNotice();
                self.clearPackageManagerModalError();
            }
            row_y += row_h + layout.row_gap * 0.35;
        }

        const refresh_rect = Rect.fromXYWH(
            left_rect.min[0],
            left_rect.max[1] - row_h,
            left_rect.width(),
            row_h,
        );
        if (self.drawButtonWidget(
            refresh_rect,
            "Refresh Packages",
            .{ .variant = .secondary, .disabled = self.connection_state != .connected },
        )) {
            self.clearPackageManagerModalNotice();
            self.requestPackageManagerRefresh(true);
        }

        var right_y = right_rect.min[1] + layout.line_height + layout.row_gap * 0.6;
        if (self.package_manager_modal_notice) |message| {
            self.drawTextTrimmed(right_rect.min[0], right_y, right_rect.width(), message, self.theme.colors.text_secondary);
            right_y += layout.line_height + layout.row_gap * 0.45;
        }
        if (self.package_manager_modal_error) |message| {
            self.drawTextTrimmed(right_rect.min[0], right_y, right_rect.width(), message, zcolors.rgba(220, 80, 80, 255));
            right_y += layout.line_height + layout.row_gap * 0.45;
        }

        const selected_entry = self.selectedPackageManagerEntry();
        const detail_rect = Rect.fromXYWH(
            right_rect.min[0],
            right_y,
            right_rect.width(),
            @max(150.0 * self.ui_scale, right_rect.height() * 0.36),
        );
        self.drawSurfacePanel(detail_rect);
        self.drawRect(detail_rect, self.theme.colors.border);

        if (selected_entry) |entry| {
            const header = std.fmt.allocPrint(
                self.allocator,
                "{s} ({s}) v{s}",
                .{ entry.package_id, entry.kind, entry.version },
            ) catch null;
            const runtime_line = std.fmt.allocPrint(
                self.allocator,
                "Runtime: {s} | Enabled: {s}",
                .{ entry.runtime_kind, if (entry.enabled) "true" else "false" },
            ) catch null;
            defer if (header) |value| self.allocator.free(value);
            defer if (runtime_line) |value| self.allocator.free(value);
            self.drawTextTrimmed(
                detail_rect.min[0] + layout.inner_inset,
                detail_rect.min[1] + layout.inner_inset * 0.7,
                detail_rect.width() - layout.inner_inset * 2.0,
                header orelse entry.package_id,
                self.theme.colors.text_primary,
            );
            self.drawTextTrimmed(
                detail_rect.min[0] + layout.inner_inset,
                detail_rect.min[1] + layout.inner_inset * 0.7 + layout.line_height,
                detail_rect.width() - layout.inner_inset * 2.0,
                runtime_line orelse "",
                self.theme.colors.text_secondary,
            );
            if (entry.help_md) |help_md| {
                self.drawTextTrimmed(
                    detail_rect.min[0] + layout.inner_inset,
                    detail_rect.min[1] + layout.inner_inset * 0.7 + layout.line_height * 2.0,
                    detail_rect.width() - layout.inner_inset * 2.0,
                    help_md,
                    self.theme.colors.text_secondary,
                );
            }
        } else {
            self.drawTextTrimmed(
                detail_rect.min[0] + layout.inner_inset,
                detail_rect.min[1] + layout.inner_inset * 0.7,
                detail_rect.width() - layout.inner_inset * 2.0,
                "No packages loaded yet. Refresh the list to inspect package lifecycle state.",
                self.theme.colors.text_secondary,
            );
        }

        right_y = detail_rect.max[1] + layout.row_gap * 0.7;
        const action_w = (right_rect.width() - pad * 2.0) / 3.0;
        const selected_disabled = selected_entry == null or self.connection_state != .connected;
        if (self.drawButtonWidget(
            Rect.fromXYWH(right_rect.min[0], right_y, action_w, row_h),
            if (selected_entry != null and !selected_entry.?.enabled) "Enable" else "Disable",
            .{ .variant = .secondary, .disabled = selected_disabled },
        )) {
            if (selected_entry) |entry| {
                const payload = self.buildPackageManagerIdPayload(entry.package_id) catch null;
                defer if (payload) |value| self.allocator.free(value);
                if (payload) |value| {
                    const control_name = if (entry.enabled) "disable.json" else "enable.json";
                    const notice = if (entry.enabled) "Package disabled." else "Package enabled.";
                    self.runPackageManagerOperation(control_name, value, notice) catch |err| {
                        if (err != error.RemoteError) {
                            const msg = self.formatControlOpError("Package update failed", err);
                            if (msg) |text| {
                                defer self.allocator.free(text);
                                self.setPackageManagerModalError(text);
                            }
                        }
                    };
                }
            }
        }
        if (self.drawButtonWidget(
            Rect.fromXYWH(right_rect.min[0] + action_w + pad, right_y, action_w, row_h),
            "Remove",
            .{ .variant = .secondary, .disabled = selected_disabled },
        )) {
            if (selected_entry) |entry| {
                const payload = self.buildPackageManagerIdPayload(entry.package_id) catch null;
                defer if (payload) |value| self.allocator.free(value);
                if (payload) |value| {
                    self.runPackageManagerOperation("remove.json", value, "Package removed.") catch |err| {
                        if (err != error.RemoteError) {
                            const msg = self.formatControlOpError("Package remove failed", err);
                            if (msg) |text| {
                                defer self.allocator.free(text);
                                self.setPackageManagerModalError(text);
                            }
                        }
                    };
                }
            }
        }
        if (self.drawButtonWidget(
            Rect.fromXYWH(right_rect.min[0] + (action_w + pad) * 2.0, right_y, action_w, row_h),
            "Close",
            .{ .variant = .primary },
        )) {
            self.closePackageManagerModal();
            return;
        }

        right_y += row_h + layout.row_gap * 0.75;
        self.drawLabel(right_rect.min[0], right_y, "Install Package JSON", self.theme.colors.text_secondary);
        right_y += layout.line_height + layout.row_gap * 0.25;
        const payload_focused = self.drawTextInputWidget(
            Rect.fromXYWH(right_rect.min[0], right_y, right_rect.width(), layout.input_height),
            self.package_manager_install_payload.items,
            self.settings_panel.focused_field == .package_manager_install_payload,
            .{ .placeholder = "{\"package\":{...}}" },
        );
        if (payload_focused) self.settings_panel.focused_field = .package_manager_install_payload;
        right_y += layout.input_height + layout.row_gap * 0.55;

        const install_payload = std.mem.trim(u8, self.package_manager_install_payload.items, " \t\r\n");
        if (self.drawButtonWidget(
            Rect.fromXYWH(right_rect.min[0], right_y, right_rect.width(), row_h),
            "Install From JSON",
            .{ .variant = .primary, .disabled = self.connection_state != .connected or install_payload.len == 0 },
        )) {
            self.runPackageManagerOperation("install.json", install_payload, "Package installed.") catch |err| {
                if (err != error.RemoteError) {
                    const msg = self.formatControlOpError("Package install failed", err);
                    if (msg) |text| {
                        defer self.allocator.free(text);
                        self.setPackageManagerModalError(text);
                    }
                }
            };
        }

        if (self.mouse_released and !modal_rect.contains(.{ self.mouse_x, self.mouse_y })) {
            self.closePackageManagerModal();
        }
    }

    fn drawLauncherRecipeModal(self: *App, fb_width: u32, fb_height: u32) void {
        const recipe = self.ws.launcher_recipe_modal orelse return;
        const spec = launcherRecipeSpec(recipe);
        const progress = self.launcherRecipeProgress(recipe);
        const connect_details = if (recipe == .add_second_device or recipe == .connect_another_machine)
            self.launcherConnectDetails()
        else
            null;
        const layout = self.panelLayoutMetrics();
        const pad = @max(layout.inset, 12.0 * self.ui_scale);
        const row_h = @max(layout.button_height, 34.0 * self.ui_scale);
        const screen_rect = Rect.fromXYWH(0, 0, @floatFromInt(fb_width), @floatFromInt(fb_height));

        self.drawFilledRect(screen_rect, zcolors.withAlpha(self.theme.colors.background, 0.68));

        const modal_w = std.math.clamp(
            screen_rect.width() * 0.46,
            440.0 * self.ui_scale,
            760.0 * self.ui_scale,
        );
        const modal_h = std.math.clamp(
            screen_rect.height() * 0.52,
            320.0 * self.ui_scale,
            520.0 * self.ui_scale,
        );
        const modal_rect = Rect.fromXYWH(
            screen_rect.min[0] + (screen_rect.width() - modal_w) * 0.5,
            screen_rect.min[1] + (screen_rect.height() - modal_h) * 0.5,
            modal_w,
            modal_h,
        );

        self.drawSurfacePanel(modal_rect);
        self.drawRect(modal_rect, self.theme.colors.border);

        var y = modal_rect.min[1] + pad;
        const content_w = modal_rect.width() - pad * 2.0;
        self.drawTextTrimmed(modal_rect.min[0] + pad, y, content_w - 88.0 * self.ui_scale, spec.eyebrow, self.theme.colors.text_secondary);
        const progress_label = launcherRecipeProgressLabel(progress);
        const progress_color = self.launcherRecipeProgressColor(progress);
        const badge_w = @max(64.0 * self.ui_scale, self.measureText(progress_label) + pad * 1.2);
        const badge_rect = Rect.fromXYWH(
            modal_rect.max[0] - pad - badge_w,
            y - 2.0 * self.ui_scale,
            badge_w,
            layout.button_height * 0.82,
        );
        self.drawFilledRect(badge_rect, zcolors.withAlpha(progress_color, 28));
        self.drawRect(badge_rect, progress_color);
        self.drawTextTrimmed(
            badge_rect.min[0] + pad * 0.4,
            badge_rect.min[1] + @max(0.0, (badge_rect.height() - layout.line_height) * 0.5),
            badge_rect.width() - pad * 0.8,
            progress_label,
            progress_color,
        );
        y += layout.line_height + layout.row_gap * 0.25;
        self.drawTextTrimmed(modal_rect.min[0] + pad, y, content_w, spec.title, self.theme.colors.text_primary);
        y += layout.line_height + layout.row_gap * 0.45;
        self.drawTextTrimmed(modal_rect.min[0] + pad, y, content_w, spec.summary, self.theme.colors.text_secondary);
        y += layout.line_height * 3.0 + layout.row_gap * 0.35;

        self.drawLabel(modal_rect.min[0] + pad, y, "What to do", self.theme.colors.text_primary);
        y += layout.line_height + layout.row_gap * 0.35;
        for (spec.steps, 0..) |step, idx| {
            const line = std.fmt.allocPrint(self.allocator, "{d}. {s}", .{ idx + 1, step }) catch null;
            defer if (line) |value| self.allocator.free(value);
            self.drawTextTrimmed(
                modal_rect.min[0] + pad,
                y,
                content_w,
                line orelse step,
                self.theme.colors.text_secondary,
            );
            y += layout.line_height * 1.4 + layout.row_gap * 0.1;
        }

        if (connect_details) |details| {
            y += layout.row_gap * 0.35;
            self.drawLabel(modal_rect.min[0] + pad, y, "Share From This Spiderweb", self.theme.colors.text_primary);
            y += layout.line_height + layout.row_gap * 0.3;

            const info_h = layout.line_height * 4.3;
            const info_rect = Rect.fromXYWH(
                modal_rect.min[0] + pad,
                y,
                content_w,
                info_h,
            );
            self.drawSurfacePanel(info_rect);
            self.drawRect(info_rect, self.theme.colors.border);

            var info_y = info_rect.min[1] + layout.inner_inset * 0.7;
            const server_line = std.fmt.allocPrint(self.allocator, "Spiderweb URL: {s}", .{details.server_url}) catch null;
            const token_line = std.fmt.allocPrint(self.allocator, "Access token ({s}): {s}", .{ details.token_label, details.token }) catch null;
            const workspace_line = std.fmt.allocPrint(self.allocator, "Workspace: {s} ({s})", .{ details.workspace_name, details.workspace_id }) catch null;
            defer if (server_line) |value| self.allocator.free(value);
            defer if (token_line) |value| self.allocator.free(value);
            defer if (workspace_line) |value| self.allocator.free(value);

            self.drawTextTrimmed(info_rect.min[0] + layout.inner_inset, info_y, info_rect.width() - layout.inner_inset * 2.0, server_line orelse details.server_url, self.theme.colors.text_secondary);
            info_y += layout.line_height + layout.row_gap * 0.2;
            self.drawTextTrimmed(info_rect.min[0] + layout.inner_inset, info_y, info_rect.width() - layout.inner_inset * 2.0, token_line orelse details.token, self.theme.colors.text_secondary);
            info_y += layout.line_height + layout.row_gap * 0.2;
            self.drawTextTrimmed(info_rect.min[0] + layout.inner_inset, info_y, info_rect.width() - layout.inner_inset * 2.0, workspace_line orelse details.workspace_name, self.theme.colors.text_secondary);
            y = info_rect.max[1] + layout.row_gap * 0.45;

            const copy_gap = pad * 0.4;
            const copy_w = (content_w - copy_gap * 2.0) / 3.0;
            if (self.drawButtonWidget(
                Rect.fromXYWH(modal_rect.min[0] + pad, y, copy_w, row_h),
                "Copy URL",
                .{ .variant = .secondary },
            )) {
                self.copyLauncherConnectDetailsField(details.server_url, "Copied the Spiderweb URL for the second device.");
            }
            if (self.drawButtonWidget(
                Rect.fromXYWH(modal_rect.min[0] + pad + copy_w + copy_gap, y, copy_w, row_h),
                "Copy Token",
                .{ .variant = .secondary },
            )) {
                const success = std.fmt.allocPrint(self.allocator, "Copied the {s} access token for the second device.", .{details.token_label}) catch null;
                defer if (success) |value| self.allocator.free(value);
                self.copyLauncherConnectDetailsField(details.token, success orelse "Copied the access token for the second device.");
            }
            if (self.drawButtonWidget(
                Rect.fromXYWH(modal_rect.min[0] + pad + (copy_w + copy_gap) * 2.0, y, copy_w, row_h),
                "Copy Setup",
                .{ .variant = .primary },
            )) {
                self.copyLauncherConnectDetailsSummary();
            }
            y += row_h + layout.row_gap * 0.45;
        } else if (recipe == .add_second_device or recipe == .connect_another_machine) {
            self.drawTextTrimmed(
                modal_rect.min[0] + pad,
                y,
                content_w,
                "Choose a workspace and save an admin or user token in Settings before sharing this Spiderweb with another machine.",
                self.theme.colors.text_secondary,
            );
            y += layout.line_height * 2.0 + layout.row_gap * 0.35;
        }

        const button_y = modal_rect.max[1] - pad - row_h;
        const close_w = @max(90.0 * self.ui_scale, self.measureText("Close") + pad * 1.2);
        const secondary_w = if (spec.secondary_label != null)
            @max(150.0 * self.ui_scale, self.measureText(spec.secondary_label.?) + pad * 1.4)
        else
            0.0;
        const secondary_gap = if (spec.secondary_label != null) pad * 0.5 else 0.0;
        const primary_w = modal_rect.width() - pad * 2.0 - close_w - secondary_w - secondary_gap;

        if (self.drawButtonWidget(
            Rect.fromXYWH(modal_rect.min[0] + pad, button_y, primary_w, row_h),
            spec.primary_label,
            .{ .variant = .primary, .disabled = !self.launcherRecipePrimaryEnabled(recipe) },
        )) {
            self.runLauncherRecipePrimaryAction(recipe);
            return;
        }

        var trailing_x = modal_rect.max[0] - pad - close_w;
        if (self.drawButtonWidget(
            Rect.fromXYWH(trailing_x, button_y, close_w, row_h),
            "Close",
            .{ .variant = .secondary },
        )) {
            self.closeLauncherRecipeModal();
            return;
        }

        if (spec.secondary_label) |secondary_label| {
            trailing_x -= pad * 0.5 + secondary_w;
            if (self.drawButtonWidget(
                Rect.fromXYWH(trailing_x, button_y, secondary_w, row_h),
                secondary_label,
                .{ .variant = .secondary, .disabled = !self.launcherRecipeSecondaryEnabled(recipe) },
            )) {
                self.runLauncherRecipeSecondaryAction(recipe);
                return;
            }
        }

        if (self.mouse_released and !modal_rect.contains(.{ self.mouse_x, self.mouse_y })) {
            self.closeLauncherRecipeModal();
        }
    }

    fn drawAboutModal(self: *App, fb_width: u32, fb_height: u32) void {
        const layout = self.panelLayoutMetrics();
        const pad = @max(layout.inset, 12.0 * self.ui_scale);
        const row_h = @max(layout.button_height, 34.0 * self.ui_scale);
        const screen_rect = Rect.fromXYWH(0, 0, @floatFromInt(fb_width), @floatFromInt(fb_height));

        self.drawFilledRect(screen_rect, zcolors.withAlpha(self.theme.colors.background, 0.68));

        const modal_w = std.math.clamp(
            screen_rect.width() * 0.42,
            420.0 * self.ui_scale,
            720.0 * self.ui_scale,
        );
        const modal_h = std.math.clamp(
            screen_rect.height() * 0.34,
            220.0 * self.ui_scale,
            360.0 * self.ui_scale,
        );
        const modal_rect = Rect.fromXYWH(
            screen_rect.min[0] + (screen_rect.width() - modal_w) * 0.5,
            screen_rect.min[1] + (screen_rect.height() - modal_h) * 0.5,
            modal_w,
            modal_h,
        );

        self.drawSurfacePanel(modal_rect);
        self.drawRect(modal_rect, self.theme.colors.border);

        var y = modal_rect.min[1] + pad;
        const content_w = modal_rect.width() - pad * 2.0;
        self.drawLabel(modal_rect.min[0] + pad, y, "About SpiderApp", self.theme.colors.text_primary);
        y += layout.line_height + layout.row_gap * 0.4;
        self.drawTextTrimmed(
            modal_rect.min[0] + pad,
            y,
            content_w,
            "Build identity for diagnostics and demo verification.",
            self.theme.colors.text_secondary,
        );
        y += layout.line_height + layout.row_gap * 0.7;
        self.drawLabel(modal_rect.min[0] + pad, y, "Version", self.theme.colors.text_secondary);
        y += layout.line_height + layout.row_gap * 0.25;
        const focused = self.drawTextInputWidget(
            Rect.fromXYWH(modal_rect.min[0] + pad, y, content_w, layout.input_height),
            self.about_modal_build_label.items,
            self.settings_panel.focused_field == .about_modal_build_label,
            .{ .read_only = true },
        );
        if (focused) self.settings_panel.focused_field = .about_modal_build_label;
        y += layout.input_height + layout.row_gap * 0.55;

        if (self.about_modal_notice) |notice| {
            self.drawTextTrimmed(
                modal_rect.min[0] + pad,
                y,
                content_w,
                notice,
                self.theme.colors.text_secondary,
            );
        }

        const button_w = (content_w - pad) * 0.5;
        const button_y = modal_rect.max[1] - pad - row_h;
        if (self.drawButtonWidget(
            Rect.fromXYWH(modal_rect.min[0] + pad, button_y, button_w, row_h),
            "Copy Version",
            .{ .variant = .secondary },
        )) {
            self.copyTextToClipboard(self.about_modal_build_label.items) catch {};
            self.setAboutModalNotice("Copied build string to clipboard.");
        }
        if (self.drawButtonWidget(
            Rect.fromXYWH(modal_rect.min[0] + pad + button_w + pad, button_y, button_w, row_h),
            "Close",
            .{ .variant = .primary },
        )) {
            self.closeAboutModal();
            return;
        }

        if (self.mouse_released and !modal_rect.contains(.{ self.mouse_x, self.mouse_y })) {
            self.closeAboutModal();
        }
    }

    fn drawWorkspaceUi(self: *App, ui_window: *UiWindow, fb_width: u32, fb_height: u32) void {
        self.ui_commands.clear();
        ui_draw_context.setGlobalCommandList(&self.ui_commands);
        defer ui_draw_context.clearGlobalCommandList();

        const package_modal_open = self.package_manager_modal_open;
        const about_modal_open = self.about_modal_open;
        const saved_mouse_down = self.mouse_down;
        const saved_mouse_clicked = self.mouse_clicked;
        const saved_mouse_released = self.mouse_released;
        const saved_mouse_right_clicked = self.mouse_right_clicked;
        if (package_modal_open or about_modal_open) {
            self.mouse_down = false;
            self.mouse_clicked = false;
            self.mouse_released = false;
            self.mouse_right_clicked = false;
        }

        const status_height: f32 = 24.0 * self.ui_scale;
        const menu_height = self.windowMenuBarHeight();
        const dock_height = @max(1.0, @as(f32, @floatFromInt(fb_height)) - status_height - menu_height);
        const viewport = UiRect.fromMinSize(
            .{ 0, menu_height },
            .{ @floatFromInt(fb_width), dock_height },
        );

        const shell = self.sharedStyleSheet().shell;
        const surfaces = self.sharedStyleSheet().surfaces;
        const full_rect = Rect.fromXYWH(0, 0, @floatFromInt(fb_width), @floatFromInt(fb_height));
        const viewport_rect = Rect{ .min = viewport.min, .max = viewport.max };
        self.drawPaintRect(
            full_rect,
            surfaces.background orelse Paint{ .solid = self.theme.colors.background },
        );
        self.drawPaintRect(
            viewport_rect,
            shell.dock_fill orelse surfaces.surface orelse Paint{ .solid = self.theme.colors.surface },
        );
        if (shell.dock_border) |dock_border| self.drawRect(viewport_rect, dock_border);

        ui_window.ui_state.last_dock_content_rect = viewport;

        const mouse_in_viewport = self.mouse_x >= viewport.min[0] and
            self.mouse_x <= viewport.max[0] and
            self.mouse_y >= viewport.min[1] and
            self.mouse_y <= viewport.max[1];
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
            if (self.ws.workspace_wizard_open) {
                self.mouse_down = saved_mouse_down;
                self.mouse_clicked = saved_mouse_clicked;
                self.mouse_released = saved_mouse_released;
                self.drawWorkspaceWizardModal(fb_width, fb_height);
            }
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
        self.mouse_right_clicked = saved_mouse_right_clicked;

        if (package_modal_open or about_modal_open) {
            self.mouse_down = false;
            self.mouse_clicked = false;
            self.mouse_released = false;
            self.mouse_right_clicked = false;
        }
        _ = self.drawWindowMenuBar(ui_window, fb_width);
        self.drawStatusOverlay(fb_width, fb_height);
        if (self.ws.workspace_wizard_open) {
            self.mouse_down = saved_mouse_down;
            self.mouse_clicked = saved_mouse_clicked;
            self.mouse_released = saved_mouse_released;
            self.drawWorkspaceWizardModal(fb_width, fb_height);
        }
    }

    pub fn windowMenuBarHeight(self: *App) f32 {
        if (storage.isAndroid()) return 0.0;
        const layout = self.panelLayoutMetrics();
        return @max(layout.button_height + layout.inner_inset * 1.2, 30.0 * self.ui_scale);
    }

    fn ideMenuDomainLabel(domain: IdeMenuDomain) []const u8 {
        return switch (domain) {
            .file => "File",
            .edit => "Edit",
            .view => "View",
            .project => "Workspace",
            .tools => "Tools",
            .window => "Window",
            .help => "Help",
        };
    }

    fn homeRouteLabel(route: HomeRoute) []const u8 {
        return switch (route) {
            .workspace => "Workspace",
            .devices => "Devices",
            .capabilities => "Capabilities",
            .explore => "Explore",
            .settings => "Settings",
        };
    }

    fn onboardingStageHeadline(stage: OnboardingStage) []const u8 {
        return switch (stage) {
            .connect => "Connect to Spiderweb",
            .choose_workspace => "Choose a workspace",
            .workspace_ready => "Workspace ready",
        };
    }

    fn ideMenuRowCount(domain: IdeMenuDomain, stage: UiStage) usize {
        return switch (domain) {
            .file => if (stage == .launcher) 1 else 2,
            .edit => 2,
            .view => 4,
            .project => 3,
            .tools => 5,
            .window => 1,
            .help => 1,
        };
    }

    pub fn drawWindowMenuBar(self: *App, ui_window: *UiWindow, fb_width: u32) f32 {
        if (storage.isAndroid()) {
            return 0.0;
        }
        const layout = self.panelLayoutMetrics();
        const bar_h = self.windowMenuBarHeight();
        const bar_rect = Rect.fromXYWH(0, 0, @floatFromInt(fb_width), bar_h);
        const shell = self.sharedStyleSheet().shell;
        const surfaces = self.sharedStyleSheet().surfaces;
        self.drawPaintRect(
            bar_rect,
            shell.menu_bar_fill orelse surfaces.menu_bar orelse Paint{ .solid = self.theme.colors.background },
        );
        self.drawRect(bar_rect, self.theme.colors.border);

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
                            "Switch Workspace",
                            .{ .variant = .secondary },
                        )) {
                            self.returnToLauncher(.switched_workspace);
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
                        if (self.ws.dashboard_panel_id != null) "Dashboard (Focus)" else "Dashboard (Open)",
                        .{ .variant = .secondary },
                    )) {
                        _ = self.ensureDashboardPanel(&self.manager) catch {};
                        self.ide_menu_open = null;
                    }
                    row_y += row_h + row_gap;
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
                        if (self.fs.filesystem_panel_id != null) "Explorer (Focus)" else "Explorer (Open)",
                        .{ .variant = .secondary },
                    )) {
                        _ = self.ensureFilesystemPanel(&self.manager) catch {};
                        self.ide_menu_open = null;
                    }
                    row_y += row_h + row_gap;
                    if (self.drawButtonWidget(
                        Rect.fromXYWH(row_x, row_y, row_w, row_h),
                        if (self.ws.node_topology_panel_id != null) "Devices (Focus)" else "Devices (Open)",
                        .{ .variant = .secondary },
                    )) {
                        _ = self.ensureNodeTopologyPanel(&self.manager) catch {};
                        self.ide_menu_open = null;
                    }
                },
                .project => {
                    if (self.drawButtonWidget(
                        Rect.fromXYWH(row_x, row_y, row_w, row_h),
                        "Advanced Workspace Setup...",
                        .{ .variant = .secondary, .disabled = self.connection_state != .connected },
                    )) {
                        self.openWorkspaceWizard();
                        self.ide_menu_open = null;
                    }
                    row_y += row_h + row_gap;
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
                        .{ .variant = .secondary, .disabled = self.connection_state != .connected or self.selectedWorkspaceId() == null },
                    )) {
                        self.activateSelectedWorkspace() catch {};
                        self.ide_menu_open = null;
                    }
                },
                .tools => {
                    if (self.drawButtonWidget(
                        Rect.fromXYWH(row_x, row_y, row_w, row_h),
                        "Settings",
                        .{ .variant = .secondary },
                    )) {
                        self.ensureSettingsPanel(&self.manager);
                        self.ide_menu_open = null;
                    }
                    row_y += row_h + row_gap;
                    if (self.drawButtonWidget(
                        Rect.fromXYWH(row_x, row_y, row_w, row_h),
                        if (self.fs.filesystem_tools_panel_id != null) "Explorer Tools (Focus)" else "Explorer Tools (Open)",
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
                    row_y += row_h + row_gap;
                    if (self.drawButtonWidget(
                        Rect.fromXYWH(row_x, row_y, row_w, row_h),
                        if (self.ws.venom_manager_panel_id != null) "Packages (Focus)" else "Packages (Open)",
                        .{ .variant = .secondary },
                    )) {
                        _ = self.ensureVenomManagerPanel(&self.manager) catch {};
                        self.ide_menu_open = null;
                    }
                    row_y += row_h + row_gap;
                    if (self.drawButtonWidget(
                        Rect.fromXYWH(row_x, row_y, row_w, row_h),
                        if (self.ws.mcp_config_panel_id != null) "MCP Servers (Focus)" else "MCP Servers (Open)",
                        .{ .variant = .secondary },
                    )) {
                        _ = self.ensureMcpConfigPanel(&self.manager) catch {};
                        self.ide_menu_open = null;
                    }
                },
                .window => {
                    if (platformSupportsMultiWindow() and self.drawButtonWidget(
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
                        self.openAboutModal();
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

    pub fn drawDockGroup(self: *App, manager: *panel_manager.PanelManager, node_id: dock_graph.NodeId, rect: UiRect) void {
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

    pub fn drawDockSplitters(
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

    pub fn drawDockDragOverlay(
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

    pub fn isLayoutGroupUsable(self: *App, manager: *panel_manager.PanelManager, node_id: dock_graph.NodeId) bool {
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
            .WorkspaceOverview => {
                const started_ns = std.time.nanoTimestamp();
                if (!self.drawHostPanelWithRuntime(manager, panel, rect)) {
                    self.drawWorkspacePanel(manager, rect);
                }
                self.ws.workspace_panel_id = panel.id;
                self.perf_frame_panel_ns.projects += std.time.nanoTimestamp() - started_ns;
            },
            .FilesystemBrowser => {
                const started_ns = std.time.nanoTimestamp();
                if (!self.drawHostPanelWithRuntime(manager, panel, rect)) {
                    self.drawFilesystemPanel(manager, rect);
                }
                self.fs.filesystem_panel_id = panel.id;
                self.perf_frame_panel_ns.filesystem += std.time.nanoTimestamp() - started_ns;
            },
            .FilesystemTools => {
                const started_ns = std.time.nanoTimestamp();
                if (!self.drawHostPanelWithRuntime(manager, panel, rect)) {
                    self.drawFilesystemToolsPanel(manager, rect);
                }
                self.fs.filesystem_tools_panel_id = panel.id;
                self.perf_frame_panel_ns.filesystem += std.time.nanoTimestamp() - started_ns;
            },
            .DebugStream => {
                const started_ns = std.time.nanoTimestamp();
                if (!self.drawHostPanelWithRuntime(manager, panel, rect)) {
                    self.drawDebugPanel(manager, rect);
                }
                self.debug.debug_panel_id = panel.id;
                self.perf_frame_panel_ns.debug += std.time.nanoTimestamp() - started_ns;
            },
            .Workboard => {
                const started_ns = std.time.nanoTimestamp();
                self.drawMissionWorkboardPanel(manager, panel, rect);
                self.perf_frame_panel_ns.other += std.time.nanoTimestamp() - started_ns;
            },
            .ApprovalsInbox => {
                const started_ns = std.time.nanoTimestamp();
                self.drawApprovalsInboxPanel(manager, panel, rect);
                self.perf_frame_panel_ns.other += std.time.nanoTimestamp() - started_ns;
            },
            .ToolOutput => {
                if (self.terminal.terminal_panel_id != null and self.terminal.terminal_panel_id.? == panel.id) {
                    const started_ns = std.time.nanoTimestamp();
                    self.drawTerminalPanel(manager, rect);
                    self.perf_frame_panel_ns.terminal += std.time.nanoTimestamp() - started_ns;
                } else if (std.mem.eql(u8, panel.title, "Debug Stream") or
                    std.mem.eql(u8, panel.title, "Filesystem Browser") or
                    std.mem.eql(u8, panel.title, "Filesystem Tools"))
                {
                    // Upgrade legacy ToolOutput-backed host panels in-place.
                    self.promoteLegacyHostPanel(manager, panel);
                    self.drawPanelContent(manager, panel_id, rect);
                } else if (std.mem.eql(u8, panel.title, "Terminal")) {
                    self.terminal.terminal_panel_id = panel.id;
                    const started_ns = std.time.nanoTimestamp();
                    self.drawTerminalPanel(manager, rect);
                    self.perf_frame_panel_ns.terminal += std.time.nanoTimestamp() - started_ns;
                } else if (std.mem.eql(u8, panel.title, "Devices")) {
                    const started_ns = std.time.nanoTimestamp();
                    self.ws.node_topology_panel_id = panel.id;
                    self.drawNodeTopologyPanel(&self.manager, rect);
                    self.perf_frame_panel_ns.other += std.time.nanoTimestamp() - started_ns;
                } else if (std.mem.eql(u8, panel.title, "Packages")) {
                    const started_ns = std.time.nanoTimestamp();
                    self.ws.venom_manager_panel_id = panel.id;
                    self.drawVenomManagerPanel(&self.manager, rect);
                    self.perf_frame_panel_ns.other += std.time.nanoTimestamp() - started_ns;
                } else if (std.mem.eql(u8, panel.title, "MCP Servers")) {
                    const started_ns = std.time.nanoTimestamp();
                    self.ws.mcp_config_panel_id = panel.id;
                    self.drawMcpConfigPanel(&self.manager, rect);
                    self.perf_frame_panel_ns.other += std.time.nanoTimestamp() - started_ns;
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
        if (panel.kind != .WorkspaceOverview and panel.kind != .FilesystemBrowser and panel.kind != .FilesystemTools and panel.kind != .DebugStream) {
            return false;
        }

        var runtime_ctx = HostPanelRuntimeCtx{ .app = self };
        var action: panels_bridge.UiAction = .{};
        var pending_attachment: ?panels_bridge.AttachmentOpen = null;
        const host_registry = panels_bridge.runtime.HostPanelRegistry{
            .workspace_overview = .{ .ctx = @ptrCast(&runtime_ctx), .draw_fn = drawWorkspaceOverviewHostPanel },
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

    fn drawWorkspaceOverviewHostPanel(
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
        runtime_ctx.app.drawWorkspacePanel(manager, panel_rect orelse return);
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
            if (std.mem.eql(u8, panel.title, "Filesystem Browser")) break :blk .FilesystemBrowser;
            if (std.mem.eql(u8, panel.title, "Filesystem Tools")) break :blk .FilesystemTools;
            if (std.mem.eql(u8, panel.title, "Debug Stream")) break :blk .DebugStream;
            break :blk null;
        };
        const kind = target_kind orelse return;

        panel.data.deinit(self.allocator);
        panel.kind = kind;
        panel.data = switch (kind) {
            .WorkspaceOverview => .{ .WorkspaceOverview = {} },
            .FilesystemBrowser => .{ .FilesystemBrowser = {} },
            .FilesystemTools => .{ .FilesystemTools = {} },
            .DebugStream => .{ .DebugStream = {} },
            else => unreachable,
        };
        switch (kind) {
            .WorkspaceOverview => self.ws.workspace_panel_id = panel.id,
            .FilesystemBrowser => self.fs.filesystem_panel_id = panel.id,
            .FilesystemTools => self.fs.filesystem_tools_panel_id = panel.id,
            .DebugStream => self.debug.debug_panel_id = panel.id,
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

    pub fn launcherSettingsDrawFormSectionTitle(
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

    pub fn launcherSettingsDrawFormFieldLabel(
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

    pub fn launcherSettingsDrawTextInput(
        ctx: *anyopaque,
        rect: Rect,
        text: []const u8,
        focused: bool,
        opts: widgets.text_input.Options,
    ) bool {
        const self: *App = @ptrCast(@alignCast(ctx));
        return self.drawTextInputWidget(rect, text, focused, opts);
    }

    pub fn launcherSettingsDrawButton(
        ctx: *anyopaque,
        rect: Rect,
        label: []const u8,
        opts: widgets.button.Options,
    ) bool {
        const self: *App = @ptrCast(@alignCast(ctx));
        return self.drawButtonWidget(rect, label, opts);
    }

    pub fn launcherSettingsDrawLabel(
        ctx: *anyopaque,
        x: f32,
        y: f32,
        text: []const u8,
        color: [4]f32,
    ) void {
        const self: *App = @ptrCast(@alignCast(ctx));
        self.drawLabel(x, y, text, color);
    }

    pub fn launcherSettingsDrawTextTrimmed(
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

    pub fn launcherSettingsDrawVerticalScrollbar(
        ctx: *anyopaque,
        viewport_rect: Rect,
        content_height: f32,
        scroll_y: *f32,
    ) void {
        const self: *App = @ptrCast(@alignCast(ctx));
        self.drawVerticalScrollbar(.settings, viewport_rect, content_height, scroll_y);
    }

    pub fn filesystemDrawSurfacePanel(ctx: *anyopaque, rect: Rect) void {
        const self: *App = @ptrCast(@alignCast(ctx));
        self.drawSurfacePanel(rect);
    }

    pub fn filesystemDrawFilledRect(ctx: *anyopaque, rect: Rect, color: [4]f32) void {
        const self: *App = @ptrCast(@alignCast(ctx));
        self.drawFilledRect(rect, color);
    }

    pub fn filesystemDrawRect(ctx: *anyopaque, rect: Rect, color: [4]f32) void {
        const self: *App = @ptrCast(@alignCast(ctx));
        self.drawRect(rect, color);
    }

    pub fn filesystemDrawTextWrapped(
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

    pub fn terminalDrawOutput(ctx: *anyopaque, rect: Rect, inner: f32) void {
        const self: *App = @ptrCast(@alignCast(ctx));
        const host = TerminalOutputPanel.Host{
            .ctx = @ptrCast(self),
            .draw_text_trimmed = App.launcherSettingsDrawTextTrimmed,
            .draw_line = App.terminalDrawStyledLineAt,
        };
        TerminalOutputPanel.draw(
            host,
            rect,
            inner,
            .{ .text_secondary = self.theme.colors.text_secondary },
            .{
                .total_lines = self.terminal.terminal_backend.lineCount(),
                .line_height = self.textLineHeight(),
                .empty_text = "(terminal output empty)",
            },
        );
    }

    pub fn terminalDrawStyledLineAt(ctx: *anyopaque, line_index: usize, x: f32, y: f32, max_w: f32) void {
        const self: *App = @ptrCast(@alignCast(ctx));
        const line = self.terminal.terminal_backend.lineAt(line_index) orelse return;
        terminal_host_mod.drawTerminalStyledLine(self, x, y, max_w, line);
    }

    pub fn debugDrawPerfCharts(
        ctx: *anyopaque,
        rect: Rect,
        layout: PanelLayoutMetrics,
        y: f32,
        perf_charts: []const panels_bridge.DebugSparklineSeriesView,
    ) f32 {
        const self: *App = @ptrCast(@alignCast(ctx));
        return debug_host_mod.drawDebugPerfCharts(self, rect, layout, y, perf_charts);
    }

    pub fn debugDrawEventStream(
        ctx: *anyopaque,
        output_rect: Rect,
        view: panels_bridge.DebugEventStreamView,
    ) void {
        const self: *App = @ptrCast(@alignCast(ctx));
        debug_host_mod.drawDebugEventStream(self, output_rect, view);
    }

    pub fn debugEventStreamSetOutputRect(ctx: *anyopaque, rect: Rect) void {
        const self: *App = @ptrCast(@alignCast(ctx));
        self.debug.debug_output_rect = rect;
    }

    pub fn debugEventStreamFocusPanel(ctx: *anyopaque) void {
        const self: *App = @ptrCast(@alignCast(ctx));
        if (self.debug.debug_panel_id) |panel_id| self.manager.focusPanel(panel_id);
    }

    pub fn debugEventStreamPushClip(ctx: *anyopaque, rect: Rect) void {
        const self: *App = @ptrCast(@alignCast(ctx));
        self.ui_commands.pushClip(.{ .min = rect.min, .max = rect.max });
    }

    pub fn debugEventStreamPopClip(ctx: *anyopaque) void {
        const self: *App = @ptrCast(@alignCast(ctx));
        self.ui_commands.popClip();
    }

    pub fn debugEventStreamDrawFilledRect(ctx: *anyopaque, rect: Rect, color: [4]f32) void {
        const self: *App = @ptrCast(@alignCast(ctx));
        self.drawFilledRect(rect, color);
    }

    pub fn debugEventStreamGetScrollY(ctx: *anyopaque) f32 {
        const self: *App = @ptrCast(@alignCast(ctx));
        return self.debug.debug_scroll_y;
    }

    pub fn debugEventStreamSetScrollY(ctx: *anyopaque, value: f32) void {
        const self: *App = @ptrCast(@alignCast(ctx));
        self.debug.debug_scroll_y = value;
    }

    pub fn debugEventStreamGetScrollbarDragging(ctx: *anyopaque) bool {
        const self: *App = @ptrCast(@alignCast(ctx));
        return self.debug.debug_scrollbar_dragging;
    }

    pub fn debugEventStreamSetScrollbarDragging(ctx: *anyopaque, value: bool) void {
        const self: *App = @ptrCast(@alignCast(ctx));
        self.debug.debug_scrollbar_dragging = value;
    }

    pub fn debugEventStreamGetDragStartY(ctx: *anyopaque) f32 {
        const self: *App = @ptrCast(@alignCast(ctx));
        return self.debug.debug_scrollbar_drag_start_y;
    }

    pub fn debugEventStreamSetDragStartY(ctx: *anyopaque, value: f32) void {
        const self: *App = @ptrCast(@alignCast(ctx));
        self.debug.debug_scrollbar_drag_start_y = value;
    }

    pub fn debugEventStreamGetDragStartScrollY(ctx: *anyopaque) f32 {
        const self: *App = @ptrCast(@alignCast(ctx));
        return self.debug.debug_scrollbar_drag_start_scroll_y;
    }

    pub fn debugEventStreamSetDragStartScrollY(ctx: *anyopaque, value: f32) void {
        const self: *App = @ptrCast(@alignCast(ctx));
        self.debug.debug_scrollbar_drag_start_scroll_y = value;
    }

    pub fn debugEventStreamSetDragCapture(ctx: *anyopaque, capture: bool) void {
        const self: *App = @ptrCast(@alignCast(ctx));
        self.setDragMouseCapture(capture);
    }

    pub fn debugEventStreamReleaseDragCapture(ctx: *anyopaque) void {
        const self: *App = @ptrCast(@alignCast(ctx));
        if (self.form_scroll_drag_target == .none) self.setDragMouseCapture(false);
    }

    pub fn debugEventStreamEntryHeight(
        ctx: *anyopaque,
        filtered_index: usize,
        content_min_x: f32,
        content_max_x: f32,
        selected: bool,
    ) f32 {
        const self: *App = @ptrCast(@alignCast(ctx));
        if (filtered_index >= self.debug.debug_events.items.len) return 0.0;
        const layout = self.panelLayoutMetrics();
        const entry = &self.debug.debug_events.items[filtered_index];
        const payload_visible_rows = if (selected)
            self.countVisibleDebugPayloadRows(content_min_x, content_max_x, entry)
        else
            0;
        const visible_lines = 1 + payload_visible_rows;
        return layout.line_height * @as(f32, @floatFromInt(visible_lines));
    }

    pub fn debugEventStreamDrawEntry(
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
        if (filtered_index >= self.debug.debug_events.items.len) return false;
        const layout = self.panelLayoutMetrics();
        const line_height = layout.line_height;
        const entry = &self.debug.debug_events.items[filtered_index];
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

    pub fn debugEventStreamSelectEntry(ctx: *anyopaque, filtered_index: usize) void {
        const self: *App = @ptrCast(@alignCast(ctx));
        if (self.debug.debug_selected_index == null or self.debug.debug_selected_index.? != filtered_index) {
            self.debug.debug_selected_index = filtered_index;
            self.clearSelectedNodeServiceEventCache();
        }
    }

    pub fn debugEventStreamCopySelectedEvent(ctx: *anyopaque) void {
        const self: *App = @ptrCast(@alignCast(ctx));
        self.performDebugPanelAction(&self.manager, .copy_selected_event);
    }

    pub fn debugEventStreamSelectedEventCount(ctx: *anyopaque) usize {
        const self: *App = @ptrCast(@alignCast(ctx));
        if (self.debug.debug_selected_index) |sel_idx| {
            return if (sel_idx < self.debug.debug_events.items.len) 1 else 0;
        }
        return 0;
    }

    fn drawSettingsPanel(self: *App, manager: *panel_manager.PanelManager, rect: UiRect) void {
        settings_host_mod.drawSettingsPanel(self, manager, rect);
    }

    pub fn drawWorkspaceSettingsPanel(self: *App, rect: UiRect) void {
        settings_host_mod.drawWorkspaceSettingsPanel(self, rect);
    }

    fn drawApprovalsInboxPanel(self: *App, manager: *panel_manager.PanelManager, panel: *workspace.Panel, rect: UiRect) void {
        mission_host_mod.drawApprovalsInboxPanel(self, manager, panel, rect);
    }

    fn drawMissionWorkboardPanel(self: *App, manager: *panel_manager.PanelManager, panel: *workspace.Panel, rect: UiRect) void {
        mission_workboard_host.draw(self, manager, panel, rect);
    }

    // ── Dashboard panel ────────────────────────────────────────────────────────

    const DASHBOARD_REFRESH_INTERVAL_MS: i64 = 8_000;

    pub fn requestDashboardRefresh(self: *App, force: bool) void {
        if (self.connection_state != .connected) return;
        if (self.ws.workspace_op_busy) return;
        const now = std.time.milliTimestamp();
        if (!force and self.ws.dashboard_last_refresh_ms != 0 and now - self.ws.dashboard_last_refresh_ms < DASHBOARD_REFRESH_INTERVAL_MS) return;
        self.ws.dashboard_last_refresh_ms = now;
        self.refreshWorkspaceData() catch {};
    }

    fn drawDashboardPanel(self: *App, manager: *panel_manager.PanelManager, rect: UiRect) void {
        dashboard_host.draw(self, manager, rect);
    }


    // ── Venom Manager panel ────────────────────────────────────────────────────

    const VENOM_REFRESH_INTERVAL_MS: i64 = 10_000;

    fn clearVenomEntries(self: *App) void {
        for (self.ws.venom_entries.items) |*e| e.deinit(self.allocator);
        self.ws.venom_entries.clearRetainingCapacity();
        self.ws.venom_selected_index = null;
    }

    fn setVenomError(self: *App, message: []const u8) void {
        if (self.ws.venom_last_error) |v| self.allocator.free(v);
        self.ws.venom_last_error = self.allocator.dupe(u8, message) catch null;
    }

    fn clearVenomError(self: *App) void {
        if (self.ws.venom_last_error) |v| {
            self.allocator.free(v);
            self.ws.venom_last_error = null;
        }
    }

    fn loadVenomsFromPath(self: *App, client: *ws_client_mod.WebSocketClient, path: []const u8, scope: VenomScope) !void {
        const payload = self.readFsPathTextGui(client, path) catch |err| {
            if (err == error.FileNotFound) return;
            return err;
        };
        defer self.allocator.free(payload);

        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, payload, .{}) catch return;
        defer parsed.deinit();
        if (parsed.value != .array) return;

        for (parsed.value.array.items) |item| {
            if (item != .object) continue;
            const obj = item.object;
            const venom_id_raw = if (obj.get("venom_id")) |v| switch (v) {
                .string => v.string,
                else => continue,
            } else continue;
            const venom_path_raw = if (obj.get("venom_path")) |v| switch (v) {
                .string => v.string,
                else => "",
            } else "";
            const provider_node_raw = if (obj.get("provider_node_id")) |v| switch (v) {
                .string => v.string,
                else => null,
            } else null;
            const provider_venom_raw = if (obj.get("provider_venom_path")) |v| switch (v) {
                .string => v.string,
                else => null,
            } else null;
            const endpoint_raw = if (obj.get("endpoint_path")) |v| switch (v) {
                .string => v.string,
                else => null,
            } else null;
            const invoke_raw = if (obj.get("invoke_path")) |v| switch (v) {
                .string => v.string,
                else => null,
            } else null;

            const venom_id = try self.allocator.dupe(u8, venom_id_raw);
            errdefer self.allocator.free(venom_id);
            const venom_path = try self.allocator.dupe(u8, venom_path_raw);
            errdefer self.allocator.free(venom_path);
            const provider_node_id = if (provider_node_raw) |v| try self.allocator.dupe(u8, v) else null;
            errdefer if (provider_node_id) |v| self.allocator.free(v);
            const provider_venom_path = if (provider_venom_raw) |v| try self.allocator.dupe(u8, v) else null;
            errdefer if (provider_venom_path) |v| self.allocator.free(v);
            const endpoint_path = if (endpoint_raw) |v| try self.allocator.dupe(u8, v) else null;
            errdefer if (endpoint_path) |v| self.allocator.free(v);
            const invoke_path = if (invoke_raw) |v| try self.allocator.dupe(u8, v) else null;
            errdefer if (invoke_path) |v| self.allocator.free(v);

            try self.ws.venom_entries.append(self.allocator, .{
                .venom_id = venom_id,
                .scope = scope,
                .provider_node_id = provider_node_id,
                .provider_venom_path = provider_venom_path,
                .venom_path = venom_path,
                .endpoint_path = endpoint_path,
                .invoke_path = invoke_path,
            });
        }
    }

    fn refreshVenomManager(self: *App) void {
        if (self.ws.venom_refresh_busy) return;
        self.ws.venom_refresh_busy = true;
        defer self.ws.venom_refresh_busy = false;
        self.ws.venom_last_refresh_ms = std.time.milliTimestamp();
        self.clearVenomEntries();
        self.clearVenomError();

        const client = if (self.ws_client) |*value| value else return;

        // Global scope
        self.loadVenomsFromPath(client, "/global/venoms/VENOMS.json", .global) catch |err| {
            self.setVenomError(std.fmt.allocPrint(self.allocator, "Global load failed: {s}", .{@errorName(err)}) catch "Global load failed");
        };

        // Workspace scope
        if (self.ws.active_workspace_id) |ws_id| {
            const path = std.fmt.allocPrint(self.allocator, "/projects/{s}/venoms/VENOMS.json", .{ws_id}) catch null;
            if (path) |p| {
                defer self.allocator.free(p);
                self.loadVenomsFromPath(client, p, .workspace) catch {};
            }
        }

        // Agent scope
        self.loadVenomsFromPath(client, "/agents/self/venoms/VENOMS.json", .agent) catch {};
    }

    pub fn requestVenomRefresh(self: *App, force: bool) void {
        if (self.connection_state != .connected) return;
        if (self.ws.venom_refresh_busy) return;
        const now = std.time.milliTimestamp();
        if (!force and self.ws.venom_last_refresh_ms != 0 and now - self.ws.venom_last_refresh_ms < VENOM_REFRESH_INTERVAL_MS) return;
        self.refreshVenomManager();
    }

    fn drawVenomManagerPanel(self: *App, manager: *panel_manager.PanelManager, rect: UiRect) void {
        venom_manager_host.draw(self, manager, rect);
    }



    fn drawNodeTopologyPanel(self: *App, manager: *panel_manager.PanelManager, rect: UiRect) void {
        node_topology_host.draw(self, manager, rect);
    }



    fn clearMcpEntries(self: *App) void {
        for (self.ws.mcp_entries.items) |*e| e.deinit(self.allocator);
        self.ws.mcp_entries.clearRetainingCapacity();
        self.ws.mcp_selected_index = null;
        if (self.ws.mcp_selected_runtime) |v| {
            self.allocator.free(v);
            self.ws.mcp_selected_runtime = null;
        }
    }

    pub fn refreshMcpConfig(self: *App) void {
        const client = if (self.ws_client) |*value| value else return;
        self.clearMcpEntries();
        if (self.ws.mcp_last_error) |v| {
            self.allocator.free(v);
            self.ws.mcp_last_error = null;
        }

        const now_ms = std.time.milliTimestamp();
        for (self.ws.nodes.items) |node| {
            const venoms_path = std.fmt.allocPrint(self.allocator, "/nodes/{s}/venoms/VENOMS.json", .{node.node_id}) catch continue;
            defer self.allocator.free(venoms_path);

            const payload = self.readFsPathTextGui(client, venoms_path) catch continue;
            defer self.allocator.free(payload);

            var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, payload, .{}) catch continue;
            defer parsed.deinit();
            if (parsed.value != .array) continue;

            for (parsed.value.array.items) |item| {
                if (item != .object) continue;
                const obj = item.object;
                const kind = if (obj.get("kind")) |v| switch (v) {
                    .string => v.string,
                    else => continue,
                } else continue;
                if (!std.mem.eql(u8, kind, "mcp")) continue;

                const venom_id_raw = if (obj.get("venom_id")) |v| switch (v) {
                    .string => v.string,
                    else => continue,
                } else continue;
                const state_raw = if (obj.get("state")) |v| switch (v) {
                    .string => v.string,
                    else => "unknown",
                } else "unknown";
                const endpoint_raw = if (obj.get("endpoint")) |v| switch (v) {
                    .string => v.string,
                    else => "",
                } else "";

                const entry = McpEntry{
                    .node_id = self.allocator.dupe(u8, node.node_id) catch continue,
                    .venom_id = self.allocator.dupe(u8, venom_id_raw) catch continue,
                    .state = self.allocator.dupe(u8, state_raw) catch continue,
                    .endpoint = self.allocator.dupe(u8, endpoint_raw) catch continue,
                };
                self.ws.mcp_entries.append(self.allocator, entry) catch continue;
            }
        }
        self.ws.mcp_last_refresh_ms = now_ms;
    }

    pub fn loadMcpRuntime(self: *App, entry: *const McpEntry) void {
        const client = if (self.ws_client) |*value| value else return;
        if (self.ws.mcp_selected_runtime) |v| {
            self.allocator.free(v);
            self.ws.mcp_selected_runtime = null;
        }
        if (entry.endpoint.len == 0) return;
        const runtime_path = std.fmt.allocPrint(self.allocator, "{s}/RUNTIME.json", .{entry.endpoint}) catch return;
        defer self.allocator.free(runtime_path);
        const text = self.readFsPathTextGui(client, runtime_path) catch return;
        self.ws.mcp_selected_runtime = text;
    }

    fn drawMcpConfigPanel(self: *App, manager: *panel_manager.PanelManager, rect: UiRect) void {
        mcp_config_host.draw(self, manager, rect);
    }



    // ── Workspace Setup Wizard ────────────────────────────────────────────────

    fn openWorkspaceWizard(self: *App) void {
        self.ws.workspace_wizard_open = true;
        self.ws.workspace_wizard_step = 0;
        self.ws.workspace_wizard_selected_node_index = null;
        // Clear wizard-scoped buffers (reuse settings_panel fields)
        self.settings_panel.project_create_name.clearRetainingCapacity();
        self.settings_panel.project_create_vision.clearRetainingCapacity();
        self.settings_panel.project_mount_path.clearRetainingCapacity();
        self.settings_panel.project_mount_node_id.clearRetainingCapacity();
        self.settings_panel.workspace_bind_path.clearRetainingCapacity();
        self.settings_panel.workspace_bind_target_path.clearRetainingCapacity();
        // Clear accumulated lists
        for (self.ws.workspace_wizard_mounts.items) |*m| m.deinit(self.allocator);
        self.ws.workspace_wizard_mounts.clearRetainingCapacity();
        for (self.ws.workspace_wizard_binds.items) |*b| b.deinit(self.allocator);
        self.ws.workspace_wizard_binds.clearRetainingCapacity();
        if (self.ws.workspace_wizard_error) |v| self.allocator.free(v);
        self.ws.workspace_wizard_error = null;
        // Ensure templates are loaded
        self.refreshLauncherCreateWorkspaceTemplates() catch |err| {
            self.clearLauncherCreateWorkspaceTemplates();
            const msg = self.formatControlOpError("Template list failed", err);
            if (msg) |text| {
                defer self.allocator.free(text);
                self.ws.workspace_wizard_error = self.allocator.dupe(u8, text) catch null;
            }
        };
    }

    fn closeWorkspaceWizard(self: *App) void {
        self.ws.workspace_wizard_open = false;
        for (self.ws.workspace_wizard_mounts.items) |*m| m.deinit(self.allocator);
        self.ws.workspace_wizard_mounts.clearAndFree(self.allocator);
        for (self.ws.workspace_wizard_binds.items) |*b| b.deinit(self.allocator);
        self.ws.workspace_wizard_binds.clearAndFree(self.allocator);
        if (self.ws.workspace_wizard_error) |v| self.allocator.free(v);
        self.ws.workspace_wizard_error = null;
        self.ws.workspace_wizard_step = 0;
        self.ws.workspace_wizard_selected_node_index = null;
    }

    fn wizardAddCurrentMount(self: *App) void {
        const path = std.mem.trim(u8, self.settings_panel.project_mount_path.items, " \t\r\n");
        const node_id = std.mem.trim(u8, self.settings_panel.project_mount_node_id.items, " \t\r\n");
        if (path.len == 0 or node_id.len == 0) return;
        const path_copy = self.allocator.dupe(u8, path) catch return;
        const node_copy = self.allocator.dupe(u8, node_id) catch {
            self.allocator.free(path_copy);
            return;
        };
        self.ws.workspace_wizard_mounts.append(self.allocator, .{ .path = path_copy, .node_id = node_copy }) catch {
            self.allocator.free(path_copy);
            self.allocator.free(node_copy);
            return;
        };
        self.settings_panel.project_mount_path.clearRetainingCapacity();
        self.settings_panel.project_mount_node_id.clearRetainingCapacity();
    }

    fn wizardAddCurrentBind(self: *App) void {
        const bind_path = std.mem.trim(u8, self.settings_panel.workspace_bind_path.items, " \t\r\n");
        const target_path = std.mem.trim(u8, self.settings_panel.workspace_bind_target_path.items, " \t\r\n");
        if (bind_path.len == 0 or target_path.len == 0) return;
        const bp_copy = self.allocator.dupe(u8, bind_path) catch return;
        const tp_copy = self.allocator.dupe(u8, target_path) catch {
            self.allocator.free(bp_copy);
            return;
        };
        self.ws.workspace_wizard_binds.append(self.allocator, .{ .bind_path = bp_copy, .target_path = tp_copy }) catch {
            self.allocator.free(bp_copy);
            self.allocator.free(tp_copy);
            return;
        };
        self.settings_panel.workspace_bind_path.clearRetainingCapacity();
        self.settings_panel.workspace_bind_target_path.clearRetainingCapacity();
    }

    fn wizardExecuteCreate(self: *App) void {
        // Delegate to existing createWorkspaceFromPanel which reads settings_panel fields.
        // Mounts and binds are handled separately after creation via the workspace panel.
        self.createWorkspaceFromPanel() catch |err| {
            const msg = self.formatControlOpError("Workspace create failed", err);
            if (self.ws.workspace_wizard_error) |v| self.allocator.free(v);
            if (msg) |text| {
                defer self.allocator.free(text);
                self.ws.workspace_wizard_error = self.allocator.dupe(u8, text) catch null;
            } else {
                self.ws.workspace_wizard_error = self.allocator.dupe(u8, "Workspace create failed.") catch null;
            }
            return;
        };
        self.closeWorkspaceWizard();
        self.setLauncherNotice("Workspace created.");
    }

    pub fn drawWorkspaceWizardModal(self: *App, fb_width: u32, fb_height: u32) void {
        const layout = self.panelLayoutMetrics();
        const pad = @max(layout.inset, 12.0 * self.ui_scale);
        const row_h = @max(layout.button_height, 34.0 * self.ui_scale);

        const modal_w = @min(740.0 * self.ui_scale, @as(f32, @floatFromInt(fb_width)) - pad * 4.0);
        const modal_h = @min(520.0 * self.ui_scale, @as(f32, @floatFromInt(fb_height)) - pad * 4.0);
        const modal_x = (@as(f32, @floatFromInt(fb_width)) - modal_w) * 0.5;
        const modal_y = (@as(f32, @floatFromInt(fb_height)) - modal_h) * 0.5;
        const modal_rect = Rect.fromXYWH(modal_x, modal_y, modal_w, modal_h);

        // Dim backdrop
        self.drawFilledRect(
            Rect.fromXYWH(0, 0, @floatFromInt(fb_width), @floatFromInt(fb_height)),
            zcolors.withAlpha(self.theme.colors.background, 0.72),
        );
        self.drawSurfacePanel(modal_rect);
        self.drawRect(modal_rect, self.theme.colors.border);

        // Title bar
        const step_names = [_][]const u8{ "Template", "Name & Vision", "Mounts", "Binds", "Review" };
        const current_step_name = if (self.ws.workspace_wizard_step < step_names.len) step_names[self.ws.workspace_wizard_step] else "?";
        const title_str = std.fmt.allocPrint(
            self.allocator,
            "Advanced Workspace Setup — Step {d}/5: {s}",
            .{ self.ws.workspace_wizard_step + 1, current_step_name },
        ) catch null;
        defer if (title_str) |v| self.allocator.free(v);
        var y = modal_rect.min[1] + pad;
        self.drawText(
            modal_rect.min[0] + pad,
            y,
            title_str orelse "Advanced Workspace Setup",
            self.theme.colors.text_primary,
        );
        y += layout.line_height + layout.row_gap * 0.5;

        // Step indicator dots
        const dot_r = 5.0 * self.ui_scale;
        const dot_spacing = 18.0 * self.ui_scale;
        var dot_x = modal_rect.min[0] + pad;
        for (0..5) |i| {
            const dot_rect = Rect.fromXYWH(dot_x, y, dot_r * 2.0, dot_r * 2.0);
            const dot_color = if (i == self.ws.workspace_wizard_step)
                self.theme.colors.primary
            else if (i < self.ws.workspace_wizard_step)
                zcolors.blend(self.theme.colors.primary, self.theme.colors.background, 0.5)
            else
                self.theme.colors.border;
            self.drawFilledRect(dot_rect, dot_color);
            dot_x += dot_r * 2.0 + dot_spacing;
        }
        y += dot_r * 2.0 + layout.row_gap * 0.8;

        // Divider
        self.drawFilledRect(
            Rect.fromXYWH(modal_rect.min[0] + pad, y, modal_w - pad * 2.0, 1.0),
            self.theme.colors.border,
        );
        y += 1.0 + layout.row_gap * 0.5;

        // Error message
        if (self.ws.workspace_wizard_error) |msg| {
            self.drawTextTrimmed(
                modal_rect.min[0] + pad,
                y,
                modal_w - pad * 2.0,
                msg,
                zcolors.rgba(220, 80, 80, 255),
            );
            y += layout.line_height + layout.row_gap * 0.5;
        }

        // Content area (above action buttons)
        const action_h = row_h + pad * 2.0;
        const content_rect = Rect.fromXYWH(
            modal_rect.min[0] + pad,
            y,
            modal_w - pad * 2.0,
            modal_rect.max[1] - y - action_h,
        );

        switch (self.ws.workspace_wizard_step) {
            0 => self.drawWizardStepTemplate(content_rect, layout, pad),
            1 => self.drawWizardStepNameVision(content_rect, layout, pad),
            2 => self.drawWizardStepMounts(content_rect, layout, pad),
            3 => self.drawWizardStepBinds(content_rect, layout, pad),
            4 => self.drawWizardStepReview(content_rect, layout, pad),
            else => {},
        }

        // Action buttons
        const btn_area_y = modal_rect.max[1] - pad - row_h;
        const btn_w = (modal_w - pad * 3.0) * 0.5;

        if (self.drawButtonWidget(
            Rect.fromXYWH(modal_rect.min[0] + pad, btn_area_y, btn_w, row_h),
            if (self.ws.workspace_wizard_step == 0) "Cancel" else "Back",
            .{ .variant = .secondary },
        )) {
            if (self.ws.workspace_wizard_step == 0) {
                self.closeWorkspaceWizard();
            } else {
                self.ws.workspace_wizard_step -= 1;
                if (self.ws.workspace_wizard_error) |v| self.allocator.free(v);
                self.ws.workspace_wizard_error = null;
            }
            return;
        }

        const is_last_step = self.ws.workspace_wizard_step == 4;
        const next_label: []const u8 = if (is_last_step) "Create Workspace" else "Next";
        const next_disabled = switch (self.ws.workspace_wizard_step) {
            0 => self.ws.launcher_create_templates.items.len == 0,
            1 => std.mem.trim(u8, self.settings_panel.project_create_name.items, " \t\r\n").len == 0,
            else => false,
        };
        if (self.drawButtonWidget(
            Rect.fromXYWH(modal_rect.min[0] + pad * 2.0 + btn_w, btn_area_y, btn_w, row_h),
            next_label,
            .{ .variant = .primary, .disabled = next_disabled or self.connection_state != .connected },
        )) {
            if (is_last_step) {
                self.wizardExecuteCreate();
            } else {
                self.ws.workspace_wizard_step += 1;
                if (self.ws.workspace_wizard_error) |v| self.allocator.free(v);
                self.ws.workspace_wizard_error = null;
                // Focus appropriate field when entering step
                self.settings_panel.focused_field = switch (self.ws.workspace_wizard_step) {
                    1 => .project_create_name,
                    2 => .project_mount_path,
                    3 => .workspace_bind_path,
                    else => .none,
                };
            }
        }

        // Close on outside click
        if (self.mouse_released and !modal_rect.contains(.{ self.mouse_x, self.mouse_y })) {
            self.closeWorkspaceWizard();
        }
    }

    fn drawWizardStepTemplate(self: *App, rect: Rect, layout: PanelLayoutMetrics, pad: f32) void {
        const template_count = self.ws.launcher_create_templates.items.len;
        if (template_count == 0) {
            self.drawTextTrimmed(
                rect.min[0], rect.min[1], rect.width(),
                "No templates available. Ensure you are connected.",
                self.theme.colors.text_secondary,
            );
            return;
        }
        const row_h = @max(layout.button_height, 30.0 * self.ui_scale);
        const row_gap = layout.row_gap * 0.45;
        var row_y = rect.min[1];
        self.drawText(rect.min[0], row_y, "Select a workspace template:", self.theme.colors.text_secondary);
        row_y += layout.line_height + layout.row_gap * 0.4;
        for (self.ws.launcher_create_templates.items, 0..) |template, idx| {
            if (row_y + row_h > rect.max[1]) break;
            const is_selected = idx == self.ws.launcher_create_selected_template_index;
            if (self.drawButtonWidget(
                Rect.fromXYWH(rect.min[0], row_y, rect.width(), row_h),
                template.id,
                .{ .variant = if (is_selected) .primary else .secondary },
            )) {
                self.ws.launcher_create_selected_template_index = idx;
                self.syncLauncherCreateSelectedTemplateToSettings() catch {};
            }
            row_y += row_h + row_gap;
        }
        // Show description of selected template
        if (self.selectedLauncherCreateWorkspaceTemplate()) |tmpl| {
            if (tmpl.description.len > 0) {
                const desc_y = @min(row_y + layout.row_gap, rect.max[1] - layout.line_height * 2.0);
                self.drawTextTrimmed(rect.min[0], desc_y, rect.width(), tmpl.description, self.theme.colors.text_secondary);
            }
        }
        _ = pad;
    }

    fn drawWizardStepNameVision(self: *App, rect: Rect, layout: PanelLayoutMetrics, pad: f32) void {
        var y = rect.min[1];
        self.drawLabel(rect.min[0], y, "Workspace Name", self.theme.colors.text_secondary);
        y += layout.line_height + layout.row_gap * 0.25;
        const name_focused = self.drawTextInputWidget(
            Rect.fromXYWH(rect.min[0], y, rect.width(), layout.input_height),
            self.settings_panel.project_create_name.items,
            self.settings_panel.focused_field == .project_create_name,
            .{ .placeholder = "my-workspace" },
        );
        if (name_focused) self.settings_panel.focused_field = .project_create_name;
        y += layout.input_height + layout.row_gap * 0.8;

        self.drawLabel(rect.min[0], y, "Vision (optional)", self.theme.colors.text_secondary);
        y += layout.line_height + layout.row_gap * 0.25;
        const vision_focused = self.drawTextInputWidget(
            Rect.fromXYWH(rect.min[0], y, rect.width(), layout.input_height),
            self.settings_panel.project_create_vision.items,
            self.settings_panel.focused_field == .project_create_vision,
            .{ .placeholder = "Describe the workspace goal..." },
        );
        if (vision_focused) self.settings_panel.focused_field = .project_create_vision;
        _ = pad;
    }

    fn drawWizardStepMounts(self: *App, rect: Rect, layout: PanelLayoutMetrics, pad: f32) void {
        var y = rect.min[1];
        // Existing mounts
        self.drawText(rect.min[0], y, "Mounts (optional — press Add to add each)", self.theme.colors.text_secondary);
        y += layout.line_height + layout.row_gap * 0.4;
        const row_h = @max(layout.button_height, 26.0 * self.ui_scale);
        for (self.ws.workspace_wizard_mounts.items, 0..) |m, idx| {
            if (y + row_h > rect.max[1] - layout.input_height * 3.0 - row_h * 1.5) break;
            const line = std.fmt.allocPrint(self.allocator, "{s}  →  {s}", .{ m.path, m.node_id }) catch null;
            defer if (line) |v| self.allocator.free(v);
            self.drawText(rect.min[0] + pad * 0.5, y + (row_h - layout.line_height) * 0.5, line orelse m.path, self.theme.colors.text_primary);
            // Remove button
            const rm_w = @max(60.0 * self.ui_scale, self.measureText("Remove") + pad);
            if (self.drawButtonWidget(
                Rect.fromXYWH(rect.max[0] - rm_w, y, rm_w, row_h),
                "Remove",
                .{ .variant = .secondary },
            )) {
                var entry = self.ws.workspace_wizard_mounts.orderedRemove(idx);
                entry.deinit(self.allocator);
                return;
            }
            y += row_h + layout.row_gap * 0.3;
        }
        // Add form
        const form_top = rect.max[1] - layout.input_height * 2.0 - layout.row_gap * 1.0 - row_h;
        y = @max(y, form_top);
        self.drawLabel(rect.min[0], y, "Mount Path", self.theme.colors.text_secondary);
        y += layout.line_height + layout.row_gap * 0.2;
        const mp_focused = self.drawTextInputWidget(
            Rect.fromXYWH(rect.min[0], y, rect.width(), layout.input_height),
            self.settings_panel.project_mount_path.items,
            self.settings_panel.focused_field == .project_mount_path,
            .{ .placeholder = "/workspace/path" },
        );
        if (mp_focused) self.settings_panel.focused_field = .project_mount_path;
        y += layout.input_height + layout.row_gap * 0.4;
        self.drawLabel(rect.min[0], y, "Node ID", self.theme.colors.text_secondary);
        y += layout.line_height + layout.row_gap * 0.2;
        const ni_focused = self.drawTextInputWidget(
            Rect.fromXYWH(rect.min[0], y, rect.width(), layout.input_height),
            self.settings_panel.project_mount_node_id.items,
            self.settings_panel.focused_field == .project_mount_node_id,
            .{ .placeholder = "node-id" },
        );
        if (ni_focused) self.settings_panel.focused_field = .project_mount_node_id;
        y += layout.input_height + layout.row_gap * 0.4;
        const add_w = @max(80.0 * self.ui_scale, self.measureText("Add Mount") + pad);
        const can_add = std.mem.trim(u8, self.settings_panel.project_mount_path.items, " \t\r\n").len > 0 and
            std.mem.trim(u8, self.settings_panel.project_mount_node_id.items, " \t\r\n").len > 0;
        if (self.drawButtonWidget(
            Rect.fromXYWH(rect.min[0], y, add_w, row_h),
            "Add Mount",
            .{ .variant = .secondary, .disabled = !can_add },
        )) {
            self.wizardAddCurrentMount();
        }
    }

    fn drawWizardStepBinds(self: *App, rect: Rect, layout: PanelLayoutMetrics, pad: f32) void {
        var y = rect.min[1];
        self.drawText(rect.min[0], y, "Binds (optional — press Add to add each)", self.theme.colors.text_secondary);
        y += layout.line_height + layout.row_gap * 0.4;
        const row_h = @max(layout.button_height, 26.0 * self.ui_scale);
        for (self.ws.workspace_wizard_binds.items, 0..) |b, idx| {
            if (y + row_h > rect.max[1] - layout.input_height * 3.0 - row_h * 1.5) break;
            const line = std.fmt.allocPrint(self.allocator, "{s}  →  {s}", .{ b.bind_path, b.target_path }) catch null;
            defer if (line) |v| self.allocator.free(v);
            self.drawText(rect.min[0] + pad * 0.5, y + (row_h - layout.line_height) * 0.5, line orelse b.bind_path, self.theme.colors.text_primary);
            const rm_w = @max(60.0 * self.ui_scale, self.measureText("Remove") + pad);
            if (self.drawButtonWidget(
                Rect.fromXYWH(rect.max[0] - rm_w, y, rm_w, row_h),
                "Remove",
                .{ .variant = .secondary },
            )) {
                var entry = self.ws.workspace_wizard_binds.orderedRemove(idx);
                entry.deinit(self.allocator);
                return;
            }
            y += row_h + layout.row_gap * 0.3;
        }
        const form_top = rect.max[1] - layout.input_height * 2.0 - layout.row_gap * 1.0 - row_h;
        y = @max(y, form_top);
        self.drawLabel(rect.min[0], y, "Bind Path", self.theme.colors.text_secondary);
        y += layout.line_height + layout.row_gap * 0.2;
        const bp_focused = self.drawTextInputWidget(
            Rect.fromXYWH(rect.min[0], y, rect.width(), layout.input_height),
            self.settings_panel.workspace_bind_path.items,
            self.settings_panel.focused_field == .workspace_bind_path,
            .{ .placeholder = "/bind/path" },
        );
        if (bp_focused) self.settings_panel.focused_field = .workspace_bind_path;
        y += layout.input_height + layout.row_gap * 0.4;
        self.drawLabel(rect.min[0], y, "Target Path", self.theme.colors.text_secondary);
        y += layout.line_height + layout.row_gap * 0.2;
        const tp_focused = self.drawTextInputWidget(
            Rect.fromXYWH(rect.min[0], y, rect.width(), layout.input_height),
            self.settings_panel.workspace_bind_target_path.items,
            self.settings_panel.focused_field == .workspace_bind_target_path,
            .{ .placeholder = "/target/path" },
        );
        if (tp_focused) self.settings_panel.focused_field = .workspace_bind_target_path;
        y += layout.input_height + layout.row_gap * 0.4;
        const add_w = @max(80.0 * self.ui_scale, self.measureText("Add Bind") + pad);
        const can_add = std.mem.trim(u8, self.settings_panel.workspace_bind_path.items, " \t\r\n").len > 0 and
            std.mem.trim(u8, self.settings_panel.workspace_bind_target_path.items, " \t\r\n").len > 0;
        if (self.drawButtonWidget(
            Rect.fromXYWH(rect.min[0], y, add_w, row_h),
            "Add Bind",
            .{ .variant = .secondary, .disabled = !can_add },
        )) {
            self.wizardAddCurrentBind();
        }
    }

    fn drawWizardStepReview(self: *App, rect: Rect, layout: PanelLayoutMetrics, pad: f32) void {
        var y = rect.min[1];
        self.drawText(rect.min[0], y, "Review your workspace configuration:", self.theme.colors.text_secondary);
        y += layout.line_height + layout.row_gap * 0.6;

        const label_w = 120.0 * self.ui_scale;
        // Template
        const tmpl_id = if (self.selectedLauncherCreateWorkspaceTemplate()) |t| t.id else "(none)";
        self.drawTextTrimmed(rect.min[0], y, label_w, "Template:", self.theme.colors.text_secondary);
        self.drawTextTrimmed(rect.min[0] + label_w, y, rect.width() - label_w, tmpl_id, self.theme.colors.text_primary);
        y += layout.line_height + layout.row_gap * 0.35;
        // Name
        const name = std.mem.trim(u8, self.settings_panel.project_create_name.items, " \t\r\n");
        self.drawTextTrimmed(rect.min[0], y, label_w, "Name:", self.theme.colors.text_secondary);
        self.drawTextTrimmed(rect.min[0] + label_w, y, rect.width() - label_w, if (name.len > 0) name else "(none)", self.theme.colors.text_primary);
        y += layout.line_height + layout.row_gap * 0.35;
        // Vision
        const vision = std.mem.trim(u8, self.settings_panel.project_create_vision.items, " \t\r\n");
        self.drawTextTrimmed(rect.min[0], y, label_w, "Vision:", self.theme.colors.text_secondary);
        self.drawTextTrimmed(rect.min[0] + label_w, y, rect.width() - label_w, if (vision.len > 0) vision else "(none)", self.theme.colors.text_primary);
        y += layout.line_height + layout.row_gap * 0.6;
        // Mounts
        const mount_count_str = std.fmt.allocPrint(self.allocator, "Mounts ({d}):", .{self.ws.workspace_wizard_mounts.items.len}) catch null;
        defer if (mount_count_str) |v| self.allocator.free(v);
        self.drawTextTrimmed(rect.min[0], y, label_w, mount_count_str orelse "Mounts:", self.theme.colors.text_secondary);
        y += layout.line_height + layout.row_gap * 0.2;
        for (self.ws.workspace_wizard_mounts.items) |m| {
            if (y + layout.line_height > rect.max[1] - layout.line_height * 3.0) break;
            const line = std.fmt.allocPrint(self.allocator, "  {s}  →  {s}", .{ m.path, m.node_id }) catch null;
            defer if (line) |v| self.allocator.free(v);
            self.drawTextTrimmed(rect.min[0] + pad * 0.5, y, rect.width() - pad * 0.5, line orelse m.path, self.theme.colors.text_primary);
            y += layout.line_height + layout.row_gap * 0.2;
        }
        y += layout.row_gap * 0.4;
        // Binds
        const bind_count_str = std.fmt.allocPrint(self.allocator, "Binds ({d}):", .{self.ws.workspace_wizard_binds.items.len}) catch null;
        defer if (bind_count_str) |v| self.allocator.free(v);
        self.drawTextTrimmed(rect.min[0], y, label_w, bind_count_str orelse "Binds:", self.theme.colors.text_secondary);
        y += layout.line_height + layout.row_gap * 0.2;
        for (self.ws.workspace_wizard_binds.items) |b| {
            if (y + layout.line_height > rect.max[1]) break;
            const line = std.fmt.allocPrint(self.allocator, "  {s}  →  {s}", .{ b.bind_path, b.target_path }) catch null;
            defer if (line) |v| self.allocator.free(v);
            self.drawTextTrimmed(rect.min[0] + pad * 0.5, y, rect.width() - pad * 0.5, line orelse b.bind_path, self.theme.colors.text_primary);
            y += layout.line_height + layout.row_gap * 0.2;
        }
    }

    fn ensureMcpConfigPanel(self: *App, manager: *panel_manager.PanelManager) !workspace.PanelId {
        if (self.ws.mcp_config_panel_id) |panel_id| {
            if (self.findPanelById(manager, panel_id) != null) {
                manager.focusPanel(panel_id);
                return panel_id;
            }
            self.ws.mcp_config_panel_id = null;
        }
        for (manager.workspace.panels.items) |*panel| {
            if (panel.kind == .ToolOutput and std.mem.eql(u8, panel.title, "MCP Servers")) {
                self.ws.mcp_config_panel_id = panel.id;
                manager.focusPanel(panel.id);
                return panel.id;
            }
        }
        const panel_id = try self.openHostToolOutputPanel(manager, "MCP Servers", "Spiderweb MCP Servers");
        self.ws.mcp_config_panel_id = panel_id;
        if (manager.workspace.syncDockLayout() catch false) {
            manager.workspace.markDirty();
        }
        manager.focusPanel(panel_id);
        return panel_id;
    }

    fn ensureNodeTopologyPanel(self: *App, manager: *panel_manager.PanelManager) !workspace.PanelId {
        if (self.ws.node_topology_panel_id) |panel_id| {
            if (self.findPanelById(manager, panel_id) != null) {
                manager.focusPanel(panel_id);
                return panel_id;
            }
            self.ws.node_topology_panel_id = null;
        }
        for (manager.workspace.panels.items) |*panel| {
            if (panel.kind == .ToolOutput and std.mem.eql(u8, panel.title, "Devices")) {
                self.ws.node_topology_panel_id = panel.id;
                manager.focusPanel(panel.id);
                return panel.id;
            }
        }
        const panel_id = try self.openHostToolOutputPanel(manager, "Devices", "Spiderweb Devices");
        self.ws.node_topology_panel_id = panel_id;
        if (manager.workspace.syncDockLayout() catch false) {
            manager.workspace.markDirty();
        }
        manager.focusPanel(panel_id);
        return panel_id;
    }

    fn ensureVenomManagerPanel(self: *App, manager: *panel_manager.PanelManager) !workspace.PanelId {
        if (self.ws.venom_manager_panel_id) |panel_id| {
            if (self.findPanelById(manager, panel_id) != null) {
                manager.focusPanel(panel_id);
                return panel_id;
            }
            self.ws.venom_manager_panel_id = null;
        }
        for (manager.workspace.panels.items) |*panel| {
            if (panel.kind == .ToolOutput and std.mem.eql(u8, panel.title, "Packages")) {
                self.ws.venom_manager_panel_id = panel.id;
                manager.focusPanel(panel.id);
                return panel.id;
            }
        }
        const panel_id = try self.openHostToolOutputPanel(manager, "Packages", "Spiderweb Packages");
        self.ws.venom_manager_panel_id = panel_id;
        if (manager.workspace.syncDockLayout() catch false) {
            manager.workspace.markDirty();
        }
        manager.focusPanel(panel_id);
        return panel_id;
    }

    fn ensureDashboardPanel(self: *App, manager: *panel_manager.PanelManager) !workspace.PanelId {
        const panel_id = try self.ensureWorkspacePanel(manager);
        self.ws.dashboard_panel_id = panel_id;
        return panel_id;
    }

    pub fn drawMissionSummaryCard(self: *App, rect: Rect, accent: [4]f32, title: []const u8, value: []const u8, summary: []const u8) void {
        self.drawSurfacePanel(rect);
        const pad = @max(self.theme.spacing.xs, 8.0 * self.ui_scale);
        const line_h = self.textLineHeight();
        const accent_rect = Rect.fromXYWH(rect.min[0], rect.min[1], @max(3.0, 4.0 * self.ui_scale), rect.height());
        self.drawFilledRect(accent_rect, accent);
        self.drawTextTrimmed(rect.min[0] + pad * 1.6, rect.min[1] + pad, rect.width() - pad * 2.0, title, self.theme.colors.text_secondary);
        self.drawTextTrimmed(rect.min[0] + pad * 1.6, rect.min[1] + pad + line_h + pad * 0.15, rect.width() - pad * 2.0, value, self.theme.colors.text_primary);
        self.drawTextTrimmed(rect.min[0] + pad * 1.6, rect.min[1] + rect.height() - pad - line_h, rect.width() - pad * 2.0, summary, self.theme.colors.text_secondary);
    }

    pub fn setSelectedMissionId(self: *App, mission_id: []const u8) void {
        if (self.mission.selected_id) |existing| {
            if (std.mem.eql(u8, existing, mission_id)) return;
            self.allocator.free(existing);
        }
        self.mission.selected_id = self.allocator.dupe(u8, mission_id) catch null;
    }

    pub fn workspaceRecoveryHeadline(self: *App, buf: []u8) []const u8 {
        if (self.ws.workspace_recovery_suspended_until != 0 and self.debug_frame_counter < self.ws.workspace_recovery_suspended_until) {
            return "suspended";
        }
        if (self.ws.workspace_recovery_blocked_until != 0 and self.debug_frame_counter < self.ws.workspace_recovery_blocked_until) {
            return "cooldown";
        }
        if (self.ws.workspace_recovery_failures > 0) {
            return std.fmt.bufPrint(buf, "{d} recent retries", .{self.ws.workspace_recovery_failures}) catch "retrying";
        }
        return "stable";
    }

    pub fn workspaceRecoveryColor(self: *App) [4]f32 {
        if (self.ws.workspace_recovery_suspended_until != 0 and self.debug_frame_counter < self.ws.workspace_recovery_suspended_until) {
            return self.theme.colors.danger;
        }
        if (self.ws.workspace_recovery_blocked_until != 0 and self.debug_frame_counter < self.ws.workspace_recovery_blocked_until) {
            return zcolors.rgba(236, 174, 36, 255);
        }
        if (self.ws.workspace_recovery_failures > 0) {
            return zcolors.rgba(236, 174, 36, 255);
        }
        return self.theme.colors.success;
    }

    pub fn missionDashboardStatusText(self: *App, buf: []u8) []const u8 {
        if (self.connection_state != .connected) return "Disconnected";
        if (self.client_context.pending_workboard_request_id != null) return "Updating mission dashboard...";
        if (self.mission.last_error) |value| return value;
        if (self.mission.last_refresh_ms <= 0) return "Mission dashboard not loaded yet.";
        var rel_buf: [40]u8 = undefined;
        const relative = mission_helpers.formatRelativeTimeLabel(std.time.milliTimestamp(), self.mission.last_refresh_ms, &rel_buf);
        return std.fmt.bufPrint(buf, "Live mission data refreshed {s}", .{relative}) catch "Live mission data";
    }

    fn drawWorkspacePanel(self: *App, manager: *panel_manager.PanelManager, rect: UiRect) void {
        workspace_host_mod.drawWorkspacePanel(self, manager, rect);
    }

    fn pathWithinMount(path: []const u8, mount_path: []const u8) bool {
        if (std.mem.eql(u8, mount_path, "/")) return std.mem.startsWith(u8, path, "/");
        if (!std.mem.startsWith(u8, path, mount_path)) return false;
        if (path.len == mount_path.len) return true;
        return path.len > mount_path.len and path[mount_path.len] == '/';
    }

    fn findMountForPath(self: *App, path: []const u8) ?*const workspace_types.MountView {
        if (self.ws.workspace_state) |*status| {
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
        const existing = self.fs.filesystem_path.items;
        const aliases_existing =
            existing.len > 0 and
            path.len > 0 and
            slicesOverlap(existing, path);
        const safe_path = if (aliases_existing)
            try self.allocator.dupe(u8, path)
        else
            path;
        defer if (aliases_existing) self.allocator.free(safe_path);

        self.fs.filesystem_path.clearRetainingCapacity();
        if (safe_path.len == 0) {
            try self.fs.filesystem_path.appendSlice(self.allocator, "/");
        } else {
            try self.fs.filesystem_path.appendSlice(self.allocator, safe_path);
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
        if (self.fs.filesystem_path.items.len == 0) {
            try self.fs.filesystem_path.appendSlice(self.allocator, "/");
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
        for (self.fs.filesystem_entries.items) |*item| {
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
        for (self.fs.filesystem_entries.items) |entry| {
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
        const current_path = if (self.fs.filesystem_path.items.len > 0) self.fs.filesystem_path.items else "/";
        return self.joinFilesystemPath(current_path, name);
    }

    fn readFilesystemServiceRuntimeFile(self: *App, name: []const u8) !void {
        const client = if (self.ws_client) |*value| value else return error.NotConnected;
        const path = try self.filesystemServiceRuntimePath(name);
        defer self.allocator.free(path);
        const content = try self.readFsPathTextGui(client, path);
        defer self.allocator.free(content);
        try self.applyFilesystemPreview(path, content);
        self.clearFilesystemError();
    }

    fn writeFilesystemServiceRuntimeControl(self: *App, name: []const u8, payload: []const u8) !void {
        const client = if (self.ws_client) |*value| value else return error.NotConnected;

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
        if (self.fs.contract_services.items.len == 0) return null;
        if (self.fs.contract_service_selected_index >= self.fs.contract_services.items.len) return null;
        return &self.fs.contract_services.items[self.fs.contract_service_selected_index];
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
        const payload = try self.readFsPathTextGui(client, "/.spiderweb/venoms/VENOMS.json");
        defer self.allocator.free(payload);

        var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, payload, .{});
        defer parsed.deinit();
        if (parsed.value != .array) return error.InvalidResponse;

        self.clearContractServices();
        for (parsed.value.array.items) |entry| {
            if (entry != .object) continue;
            const obj = entry.object;
            const has_invoke = if (obj.get("has_invoke")) |value| switch (value) {
                .bool => value.bool,
                else => false,
            } else false;
            if (!has_invoke) continue;

            const service_id = if (obj.get("venom_id")) |value| switch (value) {
                .string => value.string,
                else => continue,
            } else continue;
            const service_path = if (obj.get("venom_path")) |value| switch (value) {
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

            try self.fs.contract_services.append(self.allocator, .{
                .service_id = try self.allocator.dupe(u8, service_id),
                .service_path = try self.allocator.dupe(u8, service_path),
                .invoke_path = try self.allocator.dupe(u8, invoke_path),
                .help_path = help_path,
                .schema_path = schema_path,
                .template_path = template_path,
            });
        }

        if (self.fs.contract_services.items.len == 0) {
            self.fs.contract_service_selected_index = 0;
        } else if (self.fs.contract_service_selected_index >= self.fs.contract_services.items.len) {
            self.fs.contract_service_selected_index = 0;
        }
        self.clearFilesystemError();
    }

    fn readSelectedContractServiceStatus(self: *App) !void {
        const entry = self.selectedContractService() orelse return error.MissingField;
        const client = if (self.ws_client) |*value| value else return error.NotConnected;
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
        const content = try self.readContractServiceFileWithFallback(client, entry.help_path, null);
        defer self.allocator.free(content);
        try self.applyFilesystemPreview(entry.help_path, content);
        self.clearFilesystemError();
    }

    fn readSelectedContractServiceSchema(self: *App) !void {
        const entry = self.selectedContractService() orelse return error.MissingField;
        const client = if (self.ws_client) |*value| value else return error.NotConnected;
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
        const fallback = try self.joinFilesystemPath(entry.service_path, "template.json");
        defer self.allocator.free(fallback);
        const template_text = try self.readContractServiceFileWithFallback(client, entry.template_path, fallback);
        defer self.allocator.free(template_text);
        const trimmed = std.mem.trim(u8, template_text, " \t\r\n");
        const payload = if (trimmed.len > 0) trimmed else "{}";
        self.fs.contract_invoke_payload.clearRetainingCapacity();
        try self.fs.contract_invoke_payload.appendSlice(self.allocator, payload);
        try self.applyFilesystemPreview(entry.template_path, payload);
        self.clearFilesystemError();
    }

    fn readSelectedContractServiceResult(self: *App) !void {
        const entry = self.selectedContractService() orelse return error.MissingField;
        const client = if (self.ws_client) |*value| value else return error.NotConnected;
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

        const payload_trimmed = std.mem.trim(u8, self.fs.contract_invoke_payload.items, " \t\r\n");
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
        const control_root = self.terminal.terminal_control_root orelse "/agents/self/terminal/control";
        const control_path = try self.joinFilesystemPath(control_root, control_name);
        defer self.allocator.free(control_path);
        try self.writeFsPathTextGui(client, control_path, payload);
    }

    fn readTerminalPath(self: *App, path: []const u8) ![]u8 {
        const client = if (self.ws_client) |*value| value else return error.NotConnected;
        return self.readFsPathTextGui(client, path);
    }

    fn terminalServiceRoot(self: *const App) []const u8 {
        return self.terminal.terminal_service_root orelse "/agents/self/terminal";
    }

    fn terminalTargetLabel(self: *const App) []const u8 {
        return self.terminal.terminal_target_label orelse "Workspace default terminal";
    }

    fn buildTerminalServicePath(self: *App, child: []const u8) ![]u8 {
        return self.joinFilesystemPath(self.terminalServiceRoot(), child);
    }

    fn filesystemPathNodeId(path: []const u8) ?[]const u8 {
        if (!std.mem.startsWith(u8, path, "/nodes/")) return null;
        const rest = path["/nodes/".len..];
        const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return null;
        if (slash == 0) return null;
        return rest[0..slash];
    }

    fn terminalEntryMatchesPreferredNode(entry: VenomEntry, node_id: []const u8) bool {
        if (entry.provider_node_id) |provider| {
            if (std.mem.eql(u8, provider, node_id)) return true;
        }
        if (entry.provider_venom_path) |provider_path| {
            if (filesystemPathNodeId(provider_path)) |path_node_id| {
                if (std.mem.eql(u8, path_node_id, node_id)) return true;
            }
        }
        if (filesystemPathNodeId(entry.venom_path)) |path_node_id| {
            return std.mem.eql(u8, path_node_id, node_id);
        }
        return false;
    }

    fn isTerminalVenomEntry(entry: VenomEntry) bool {
        return std.mem.eql(u8, entry.venom_id, "terminal") or std.mem.startsWith(u8, entry.venom_id, "terminal-");
    }

    fn preferredTerminalNodeId(self: *const App, requested_node_id: ?[]const u8) ?[]const u8 {
        if (requested_node_id) |node_id| {
            if (node_id.len > 0) return node_id;
        }
        if (self.ws.node_topology_selected_index) |selected_index| {
            if (selected_index < self.ws.nodes.items.len) return self.ws.nodes.items[selected_index].node_id;
        }
        if (self.ws.workspace_state) |state| {
            if (state.actual_mounts.items.len > 0) return state.actual_mounts.items[0].node_id;
            if (state.mounts.items.len > 0) return state.mounts.items[0].node_id;
        }
        if (self.ws.selected_workspace_detail) |detail| {
            if (detail.mounts.items.len > 0) return detail.mounts.items[0].node_id;
        }
        for (self.ws.nodes.items) |node| {
            if (std.mem.eql(u8, node.node_id, "local")) return node.node_id;
        }
        if (self.ws.nodes.items.len > 0) return self.ws.nodes.items[0].node_id;
        return null;
    }

    const ResolvedTerminalTarget = struct {
        node_id: ?[]const u8,
        label: []const u8,
        service_root: []const u8,
        service_root_owned: bool = false,
    };

    fn terminalServiceRootForEntry(entry: VenomEntry) []const u8 {
        return entry.provider_venom_path orelse entry.venom_path;
    }

    fn liveNodeLabel(self: *const App, node_id: []const u8) []const u8 {
        for (self.ws.nodes.items) |node| {
            if (std.mem.eql(u8, node.node_id, node_id)) return node.node_name;
        }
        return node_id;
    }

    fn hasLiveNode(self: *const App, node_id: []const u8) bool {
        for (self.ws.nodes.items) |node| {
            if (std.mem.eql(u8, node.node_id, node_id)) return true;
        }
        return false;
    }

    fn resolveRemoteTerminalTarget(self: *const App, requested_node_id: ?[]const u8) ?ResolvedTerminalTarget {
        const preferred_node_id = self.preferredTerminalNodeId(requested_node_id);

        if (preferred_node_id) |node_id| {
            for (self.ws.venom_entries.items) |entry| {
                if (!isTerminalVenomEntry(entry)) continue;
                if (!terminalEntryMatchesPreferredNode(entry, node_id)) continue;
                return .{
                    .node_id = node_id,
                    .label = self.liveNodeLabel(node_id),
                    .service_root = terminalServiceRootForEntry(entry),
                    .service_root_owned = false,
                };
            }
        }

        for (self.ws.venom_entries.items) |entry| {
            if (!isTerminalVenomEntry(entry)) continue;
            if (entry.provider_node_id == null and builtin.os.tag != .linux) continue;
            const resolved_node_id = entry.provider_node_id orelse
                if (entry.provider_venom_path) |provider_path| filesystemPathNodeId(provider_path) else null orelse
                filesystemPathNodeId(entry.venom_path);
            if (resolved_node_id) |node_id| {
                if (!self.hasLiveNode(node_id)) continue;
            }
            const node_label = if (resolved_node_id) |node_id| self.liveNodeLabel(node_id) else "workspace";
            return .{
                .node_id = resolved_node_id,
                .label = node_label,
                .service_root = terminalServiceRootForEntry(entry),
                .service_root_owned = false,
            };
        }

        if (preferred_node_id) |node_id| {
            if (!std.mem.eql(u8, node_id, "local")) {
                return .{
                    .node_id = node_id,
                    .label = self.liveNodeLabel(node_id),
                    .service_root = std.fmt.allocPrint(self.allocator, "/nodes/{s}/venoms/terminal", .{node_id}) catch return null,
                    .service_root_owned = true,
                };
            }
        }

        return null;
    }

    fn configureRemoteTerminalTarget(self: *App, requested_node_id: ?[]const u8) !void {
        const target = self.resolveRemoteTerminalTarget(requested_node_id) orelse return error.NotFound;
        defer if (target.service_root_owned) self.allocator.free(target.service_root);
        self.clearTerminalTarget();

        if (target.node_id) |node_id| {
            self.terminal.terminal_target_node_id = try self.allocator.dupe(u8, node_id);
        }
        self.terminal.terminal_target_label = try self.allocator.dupe(u8, target.label);
        self.terminal.terminal_service_root = try self.allocator.dupe(u8, target.service_root);
        self.terminal.terminal_control_root = try self.joinFilesystemPath(target.service_root, "control");
    }

    fn openRemoteTerminalForSelectedWorkspace(self: *App, requested_node_id: ?[]const u8) !void {
        try self.openSelectedWorkspaceFromLauncher();
        self.refreshVenomManager();
        try self.configureRemoteTerminalTarget(requested_node_id);
        _ = self.ensureWorkspacePanel(&self.manager) catch {};
        _ = self.ensureTerminalPanel(&self.manager) catch {};
        if (self.terminal.terminal_session_id != null) {
            self.closeTerminalSession() catch {};
        }
        try self.ensureTerminalSession();
        const profile_id = self.config.selectedProfileId();
        const workspace_id = self.selectedWorkspaceId() orelse self.ws.active_workspace_id orelse return;
        self.markWorkflowCompleted(profile_id, workspace_id, workflow_run_remote_service);
        const notice = try std.fmt.allocPrint(self.allocator, "Remote Terminal ready on {s}.", .{self.terminalTargetLabel()});
        defer self.allocator.free(notice);
        self.setLauncherNotice(notice);
    }

    pub fn ensureTerminalSession(self: *App) !void {
        if (self.terminal.terminal_session_id != null) return;

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
        self.terminal.terminal_session_id = try self.allocator.dupe(u8, session_id);
        const status = try std.fmt.allocPrint(self.allocator, "Terminal session ready on {s}", .{self.terminalTargetLabel()});
        defer self.allocator.free(status);
        self.setTerminalStatus(status);
        self.terminal.terminal_next_poll_at_ms = std.time.milliTimestamp() + TERMINAL_READ_POLL_INTERVAL_MS;
    }

    pub fn closeTerminalSession(self: *App) !void {
        if (self.terminal.terminal_session_id == null) return;
        const session_id = self.terminal.terminal_session_id.?;
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

    pub fn resizeTerminalSession(self: *App, cols: u32, rows: u32) !void {
        if (self.terminal.terminal_session_id == null) return error.InvalidState;
        const session_id = self.terminal.terminal_session_id.?;
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

    pub fn sendTerminalControlC(self: *App) !void {
        try self.ensureTerminalSession();
        if (self.terminal.terminal_session_id == null) return error.InvalidState;
        const session_id = self.terminal.terminal_session_id.?;
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
        if (self.terminal.terminal_session_id == null) return error.InvalidState;

        const session_id = self.terminal.terminal_session_id.?;
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

    pub fn sendTerminalInputFromUi(self: *App) !void {
        const input = std.mem.trim(u8, self.terminal.terminal_input.items, " \t\r\n");
        if (input.len == 0) return;
        try self.sendTerminalInputRaw(input, true);
        self.terminal.terminal_input.clearRetainingCapacity();
        self.terminalReadOnce(25) catch |err| switch (err) {
            error.RemoteError => {},
            else => return err,
        };
    }

    pub fn terminalReadOnce(self: *App, timeout_ms: u32) !void {
        if (self.terminal.terminal_session_id == null) return;
        const session_id = self.terminal.terminal_session_id.?;
        const escaped_session = try jsonEscape(self.allocator, session_id);
        defer self.allocator.free(escaped_session);
        const payload = try std.fmt.allocPrint(
            self.allocator,
            "{{\"session_id\":\"{s}\",\"timeout_ms\":{d},\"max_bytes\":{d}}}",
            .{ escaped_session, timeout_ms, TERMINAL_READ_MAX_BYTES },
        );
        defer self.allocator.free(payload);
        try self.writeTerminalControl("read.json", payload);

        const result_path = try self.buildTerminalServicePath("result.json");
        defer self.allocator.free(result_path);
        const result_payload = try self.readTerminalPath(result_path);
        defer self.allocator.free(result_payload);
        try self.applyTerminalReadResult(result_payload);
        self.terminal.terminal_next_poll_at_ms = std.time.milliTimestamp() + TERMINAL_READ_POLL_INTERVAL_MS;
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
            try self.terminal.terminal_backend.appendBytes(self.allocator, decoded);
        }

        if (eof) {
            if (self.terminal.terminal_session_id) |value| {
                self.allocator.free(value);
                self.terminal.terminal_session_id = null;
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
        if (!self.terminal.terminal_auto_poll) return;
        if (self.terminal.terminal_session_id == null) return;
        if (self.ws_client == null) return;
        if (self.chat.awaiting_reply or self.chat.pending_send_job_id != null) return;

        const now_ms = std.time.milliTimestamp();
        if (now_ms < self.terminal.terminal_next_poll_at_ms) return;

        self.terminalReadOnce(TERMINAL_READ_TIMEOUT_MS) catch |err| {
            if (err != error.RemoteError) {
                const msg = self.formatFilesystemOpError("Terminal read failed", err);
                if (msg) |text| {
                    defer self.allocator.free(text);
                    self.setTerminalError(text);
                }
            }
            self.terminal.terminal_next_poll_at_ms = now_ms + 500;
            return;
        };
    }

    fn drawTerminalPanel(self: *App, manager: *panel_manager.PanelManager, rect: UiRect) void {
        terminal_host_mod.drawTerminalPanel(self, manager, rect);
    }

    pub fn workspacePanelModel(self: *App) panels_bridge.WorkspacePanelModel {
        const selected_workspace_lock_state = self.selectedWorkspaceTokenLocked();
        const selected_workspace_known = selected_workspace_lock_state != null;
        const selected_is_locked = if (selected_workspace_lock_state) |locked| locked else false;
        return .{
            .connected = self.connection_state == .connected,
            .has_workspaces = self.ws.projects.items.len > 0,
            .has_nodes = self.ws.nodes.items.len > 0,
            .can_create_workspace = self.connection_state == .connected and self.settings_panel.project_create_name.items.len > 0,
            .can_activate_workspace = self.connection_state == .connected and self.selectedWorkspaceId() != null,
            .can_attach_session = self.connection_state == .connected and self.selectedWorkspaceId() != null,
            .can_lock_workspace = self.connection_state == .connected and selected_workspace_known and !selected_is_locked,
            .can_unlock_workspace = self.connection_state == .connected and selected_workspace_known and selected_is_locked,
        };
    }

    fn handleWorkspacePanelError(self: *App, prefix: []const u8, err: anyerror) void {
        const msg = self.formatControlOpError(prefix, err);
        if (msg) |text| {
            defer self.allocator.free(text);
            self.setWorkspaceError(text);
        }
    }

    pub fn performWorkspacePanelAction(self: *App, action: panels_bridge.WorkspacePanelAction) void {
        switch (action) {
            .select_workspace_index => |project_index| {
                if (project_index >= self.ws.projects.items.len) return;
                const project = self.ws.projects.items[project_index];
                self.selectWorkspaceInSettings(project.id) catch |err| {
                    const msg = std.fmt.allocPrint(self.allocator, "Workspace select failed: {s}", .{@errorName(err)}) catch null;
                    if (msg) |text| {
                        defer self.allocator.free(text);
                        self.setWorkspaceError(text);
                    }
                };
            },
            .create_workspace => {
                self.createWorkspaceFromPanel() catch |err| {
                    self.handleWorkspacePanelError("Workspace create failed", err);
                };
            },
            .refresh_workspace => {
                self.refreshWorkspaceData() catch |err| {
                    self.handleWorkspacePanelError("Workspace refresh failed", err);
                };
            },
            .activate_workspace => {
                self.activateSelectedWorkspace() catch |err| {
                    self.handleWorkspacePanelError("Workspace activate failed", err);
                };
            },
            .attach_session => {
                self.attachSelectedSessionFromPanel() catch |err| {
                    self.handleWorkspacePanelError("Session attach failed", err);
                };
            },
            .lock_workspace => {
                self.lockSelectedWorkspaceFromPanel() catch |err| {
                    self.handleWorkspacePanelError("Workspace lock failed", err);
                };
            },
            .unlock_workspace => {
                self.unlockSelectedWorkspaceFromPanel() catch |err| {
                    self.handleWorkspacePanelError("Workspace unlock failed", err);
                };
            },
            .add_mount => {
                if (self.validateWorkspaceMountAddInput()) |message| {
                    self.setWorkspaceError(message);
                } else {
                    self.setWorkspaceMountFromPanel() catch |err| {
                        self.handleWorkspacePanelError("Mount set failed", err);
                    };
                }
            },
            .remove_mount => {
                if (self.validateWorkspaceMountRemoveInput()) |message| {
                    self.setWorkspaceError(message);
                } else {
                    self.removeWorkspaceMountFromPanel() catch |err| {
                        self.handleWorkspacePanelError("Mount remove failed", err);
                    };
                }
            },
            .add_bind => {
                if (self.validateWorkspaceBindAddInput()) |message| {
                    self.setWorkspaceError(message);
                } else {
                    self.setWorkspaceBindFromPanel() catch |err| {
                        self.handleWorkspacePanelError("Bind set failed", err);
                    };
                }
            },
            .remove_bind => {
                if (self.validateWorkspaceBindRemoveInput()) |message| {
                    self.setWorkspaceError(message);
                } else {
                    self.removeWorkspaceBindFromPanel() catch |err| {
                        self.handleWorkspacePanelError("Bind remove failed", err);
                    };
                }
            },
            .auth_status => {
                self.fetchAuthStatusFromPanel(false) catch |err| {
                    self.handleWorkspacePanelError("Auth status failed", err);
                };
            },
            .rotate_auth_user => {
                self.rotateAuthTokenFromPanel("user") catch |err| {
                    self.handleWorkspacePanelError("Auth rotate(user) failed", err);
                };
            },
            .rotate_auth_admin => {
                self.rotateAuthTokenFromPanel("admin") catch |err| {
                    self.handleWorkspacePanelError("Auth rotate(admin) failed", err);
                };
            },
            .reveal_auth_admin => {
                self.revealAuthTokenFromPanel("admin") catch |err| {
                    self.handleWorkspacePanelError("Reveal admin token failed", err);
                };
            },
            .copy_auth_admin => {
                self.copyAuthTokenFromPanel("admin") catch |err| {
                    self.handleWorkspacePanelError("Copy admin token failed", err);
                };
            },
            .reveal_auth_user => {
                self.revealAuthTokenFromPanel("user") catch |err| {
                    self.handleWorkspacePanelError("Reveal user token failed", err);
                };
            },
            .copy_auth_user => {
                self.copyAuthTokenFromPanel("user") catch |err| {
                    self.handleWorkspacePanelError("Copy user token failed", err);
                };
            },
        }
    }

    const VisibleFilesystemEntry = struct {
        index: usize,
        entry: *const FilesystemEntry,
    };

    fn filesystemEntryPassesFilters(self: *App, entry: *const FilesystemEntry) bool {
        if (self.fs.filesystem_hide_hidden and entry.hidden) return false;
        if (self.fs.filesystem_hide_runtime_noise and entry.runtime_noise) return false;
        if (self.fs.filesystem_hide_directories and entry.kind == .directory) return false;
        if (self.fs.filesystem_hide_files and entry.kind != .directory) return false;
        return true;
    }

    fn filesystemVisibleEntryCount(self: *App) usize {
        var count: usize = 0;
        for (self.fs.filesystem_entries.items) |*entry| {
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

        const direction = self.fs.filesystem_sort_direction;
        const order = switch (self.fs.filesystem_sort_key) {
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

    pub fn filesystemPanelModel(self: *App) panels_bridge.FilesystemPanelModel {
        return .{
            .connected = self.connection_state == .connected,
            .busy = self.fs.filesystem_busy,
            .sort_key = self.fs.filesystem_sort_key,
            .sort_direction = self.fs.filesystem_sort_direction,
            .hide_hidden = self.fs.filesystem_hide_hidden,
            .hide_directories = self.fs.filesystem_hide_directories,
            .hide_files = self.fs.filesystem_hide_files,
            .hide_runtime_noise = self.fs.filesystem_hide_runtime_noise,
            .total_entry_count = self.fs.filesystem_entries.items.len,
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

    pub fn filesystemToolsPanelModel(self: *App) panels_bridge.FilesystemToolsPanelModel {
        return .{
            .connected = self.connection_state == .connected,
            .busy = self.fs.filesystem_busy,
            .has_service_runtime_root = self.filesystemHasServiceRuntimeRoot(),
            .has_selected_contract_service = self.selectedContractService() != null,
            .contract_service_count = self.fs.contract_services.items.len,
        };
    }

    pub fn performFilesystemPanelAction(self: *App, action: panels_bridge.FilesystemPanelAction, path_label: []const u8) void {
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
                if (self.ws.workspace_state) |*status| {
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
                if (entry_index >= self.fs.filesystem_entries.items.len) return;
                const entry = self.fs.filesystem_entries.items[entry_index];
                self.setFilesystemSelectedPath(entry.path);
                self.refreshSelectedFilesystemPreview() catch |err| {
                    self.handleFilesystemPanelError("Filesystem preview failed", err);
                };
            },
            .open_entry_index => |entry_index| {
                if (entry_index >= self.fs.filesystem_entries.items.len) return;
                const entry = self.fs.filesystem_entries.items[entry_index];
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
                self.fs.filesystem_sort_key = sort_key;
                self.fs.filesystem_entry_page = 0;
            },
            .toggle_sort_direction => {
                self.fs.filesystem_sort_direction = switch (self.fs.filesystem_sort_direction) {
                    .ascending => .descending,
                    .descending => .ascending,
                };
                self.fs.filesystem_entry_page = 0;
            },
            .toggle_hide_hidden => {
                self.fs.filesystem_hide_hidden = !self.fs.filesystem_hide_hidden;
                self.fs.filesystem_entry_page = 0;
            },
            .toggle_hide_directories => {
                self.fs.filesystem_hide_directories = !self.fs.filesystem_hide_directories;
                self.fs.filesystem_entry_page = 0;
            },
            .toggle_hide_files => {
                self.fs.filesystem_hide_files = !self.fs.filesystem_hide_files;
                self.fs.filesystem_entry_page = 0;
            },
            .toggle_hide_runtime_noise => {
                self.fs.filesystem_hide_runtime_noise = !self.fs.filesystem_hide_runtime_noise;
                self.fs.filesystem_entry_page = 0;
            },
            .reset_explorer_view => {
                self.fs.filesystem_sort_key = .name;
                self.fs.filesystem_sort_direction = .ascending;
                self.fs.filesystem_hide_hidden = false;
                self.fs.filesystem_hide_directories = false;
                self.fs.filesystem_hide_files = false;
                self.fs.filesystem_hide_runtime_noise = false;
                self.fs.filesystem_entry_page = 0;
            },
            .refresh_preview => {
                self.refreshSelectedFilesystemPreview() catch |err| {
                    self.handleFilesystemPanelError("Filesystem preview failed", err);
                };
            },
        }
    }

    pub fn performFilesystemToolsPanelAction(self: *App, action: panels_bridge.FilesystemToolsPanelAction) void {
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
                if (self.fs.contract_services.items.len > 1) {
                    if (self.fs.contract_service_selected_index == 0) {
                        self.fs.contract_service_selected_index = self.fs.contract_services.items.len - 1;
                    } else {
                        self.fs.contract_service_selected_index -= 1;
                    }
                }
            },
            .contract_select_next => {
                if (self.fs.contract_services.items.len > 1) {
                    self.fs.contract_service_selected_index = (self.fs.contract_service_selected_index + 1) % self.fs.contract_services.items.len;
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

        pub fn deinit(self: *OwnedFilesystemPanelView, allocator: std.mem.Allocator) void {
            for (self.owned_strings.items) |value| allocator.free(value);
            self.owned_strings.deinit(allocator);
            self.entries.deinit(allocator);
            self.* = undefined;
        }
    };

    const OwnedFilesystemToolsPanelView = struct {
        selected_contract_label: ?[]u8 = null,
        view: panels_bridge.FilesystemToolsPanelView = .{},

        pub fn deinit(self: *OwnedFilesystemToolsPanelView, allocator: std.mem.Allocator) void {
            if (self.selected_contract_label) |value| allocator.free(value);
            self.* = undefined;
        }
    };

    pub fn buildFilesystemPanelView(self: *App) OwnedFilesystemPanelView {
        var owned: OwnedFilesystemPanelView = .{};
        const path_label = if (self.fs.filesystem_path.items.len > 0) self.fs.filesystem_path.items else "/";

        var visible = std.ArrayListUnmanaged(VisibleFilesystemEntry){};
        defer visible.deinit(self.allocator);
        for (self.fs.filesystem_entries.items, 0..) |*entry, idx| {
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
                .selected = self.fs.filesystem_selected_path != null and std.mem.eql(u8, self.fs.filesystem_selected_path.?, entry.path),
            }) catch {};
        }

        var preview_title: []const u8 = "(select a file to preview)";
        var preview_path = self.fs.filesystem_preview_path;
        var preview_kind = self.fs.filesystem_preview_kind;
        var preview_size_bytes = self.fs.filesystem_preview_size_bytes;
        var preview_modified_unix_ms = self.fs.filesystem_preview_modified_unix_ms;
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
            .error_text = self.fs.filesystem_error,
            .entries = owned.entries.items,
            .total_entry_count = self.fs.filesystem_entries.items.len,
            .visible_entry_count = visible.items.len,
            .preview_title = preview_title,
            .preview_path = preview_path,
            .preview_kind = preview_kind,
            .preview_type_label = preview_type_label,
            .preview_size_bytes = preview_size_bytes,
            .preview_size_label = preview_size_label,
            .preview_modified_unix_ms = preview_modified_unix_ms,
            .preview_modified_label = preview_modified_label,
            .preview_mode = self.fs.filesystem_preview_mode,
            .preview_status = self.fs.filesystem_preview_status,
            .preview_text = self.fs.filesystem_preview_text,
        };
        return owned;
    }

    pub fn buildFilesystemToolsPanelView(self: *App) OwnedFilesystemToolsPanelView {
        var owned: OwnedFilesystemToolsPanelView = .{};
        owned.selected_contract_label = if (self.selectedContractService()) |entry|
            std.fmt.allocPrint(
                self.allocator,
                "Selected: {s} ({d}/{d})",
                .{ entry.service_id, self.fs.contract_service_selected_index + 1, self.fs.contract_services.items.len },
            ) catch null
        else
            self.allocator.dupe(u8, "Selected: (none loaded)") catch null;

        owned.view = .{
            .selected_contract_label = if (owned.selected_contract_label) |value| value else "Selected: (none loaded)",
            .contract_payload = self.fs.contract_invoke_payload.items,
        };
        return owned;
    }

    pub fn debugPanelModel(self: *App) panels_bridge.DebugPanelModel {
        const search_trimmed = std.mem.trim(u8, self.debug.debug_search_filter.items, " \t\r\n");
        const selected_node_event = self.selectedNodeServiceEventInfo();
        const selected_idx = selected_node_event.index;
        const base_idx_opt = self.debug.node_service_diff_base_index;
        const can_generate_diff = if (selected_idx) |current_idx|
            if (base_idx_opt) |base_idx|
                base_idx < self.debug.debug_events.items.len and base_idx != current_idx
            else
                false
        else
            false;
        return .{
            .connected = self.ws_client != null,
            .stream_enabled = self.debug.debug_stream_enabled,
            .has_perf_history = self.perf_history.items.len > 0,
            .perf_benchmark_active = self.perf_benchmark_active,
            .has_perf_benchmark_capture = self.hasPerfBenchmarkCapture(),
            .node_watch_enabled = self.debug.node_service_watch_enabled,
            .has_search_filter = search_trimmed.len > 0,
            .has_selected_event = self.debug.debug_selected_index != null and self.debug.debug_selected_index.? < self.debug.debug_events.items.len,
            .has_selected_node_event = selected_node_event.index != null,
            .has_diff_base_or_preview = self.debug.node_service_diff_base_index != null or self.debug.node_service_diff_preview != null,
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

        pub fn deinit(self: *OwnedDebugPanelView, allocator: std.mem.Allocator) void {
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

    pub fn buildDebugPanelView(self: *App) OwnedDebugPanelView {
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
            "Panel draw ms: debug {d:.2} settings {d:.2} chat {d:.2} fs {d:.2} terminal {d:.2} workspaces {d:.2} other {d:.2}",
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
        owned.scope_preview = if (self.selectedWorkspaceId()) |project_id| blk: {
            const token_present = if (self.selectedWorkspaceToken(project_id)) |token| token.len > 0 else false;
            break :blk std.fmt.allocPrint(
                self.allocator,
                "Node watch scope: role={s} workspace={s} token={s}",
                .{ role_name, project_id, if (token_present) "set" else "none" },
            ) catch null;
        } else std.fmt.allocPrint(
            self.allocator,
            "Node watch scope: role={s} workspace=(session default)",
            .{role_name},
        ) catch null;

        const search_trimmed = std.mem.trim(u8, self.debug.debug_search_filter.items, " \t\r\n");
        const filtered_source = self.ensureDebugFilteredIndices(search_trimmed);
        owned.filtered_indices.appendSlice(self.allocator, filtered_source) catch {};
        const filtered_events = owned.filtered_indices.items.len;
        owned.filter_status = std.fmt.allocPrint(
            self.allocator,
            "Showing {d}/{d} events",
            .{ filtered_events, self.debug.debug_events.items.len },
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
            owned.diff_base_label = if (self.debug.node_service_diff_base_index) |idx|
                if (idx < self.debug.debug_events.items.len)
                    std.fmt.allocPrint(
                        self.allocator,
                        "Diff base event: #{d}",
                        .{self.debug.debug_events.items[idx].id},
                    ) catch null
                else
                    self.allocator.dupe(u8, "Diff base event: (stale selection)") catch null
            else
                self.allocator.dupe(u8, "Diff base event: (not set)") catch null;
        }

        const show_large_payload_notice = if (selected_node_event.index) |selected_idx|
            selected_idx < self.debug.debug_events.items.len and
                self.debug.debug_events.items[selected_idx].payload_json.len > DEBUG_SYNTAX_COLOR_MAX_PAYLOAD_BYTES
        else
            false;

        owned.view = .{
            .title = "SpiderWeb Debug Stream",
            .stream_status = if (self.debug.debug_stream_enabled) "Status: live WebSocket debug events" else "Status: paused",
            .snapshot_status = if (self.debug.debug_stream_snapshot_pending)
                "Snapshot: refresh pending"
            else if (self.debug.debug_stream_snapshot != null)
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
            .node_watch_status = if (self.debug.node_service_watch_enabled)
                "Node service events: polling worldfs snapshot"
            else
                "Node service events: paused",
            .scope_preview = if (owned.scope_preview) |value| value else "Node watch scope: role/workspace unavailable",
            .show_user_scope_notice = self.config.active_role == .user,
            .node_watch_filter = self.debug.node_service_watch_filter.items,
            .node_watch_replay_limit = self.debug.node_service_watch_replay_limit.items,
            .debug_search_filter = self.debug.debug_search_filter.items,
            .filter_status = if (owned.filter_status) |value| value else "Showing events",
            .jump_to_node_label = owned.jump_to_node_label,
            .diff_base_label = owned.diff_base_label,
            .latest_reload_diag = self.debug.node_service_latest_reload_diag,
            .selected_diag = selected_node_event.diagnostics,
            .diff_preview = self.debug.node_service_diff_preview,
            .show_large_payload_notice = show_large_payload_notice,
        };
        owned.event_stream_view = .{
            .filtered_indices = owned.filtered_indices.items,
            .selected_index = self.debug.debug_selected_index,
        };
        return owned;
    }

    pub fn performDebugPanelAction(self: *App, manager: *panel_manager.PanelManager, action: panels_bridge.DebugPanelAction) void {
        switch (action) {
            .toggle_stream => {
                self.debug.debug_stream_enabled = !self.debug.debug_stream_enabled;
                if (self.debug.debug_stream_enabled) {
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
                self.debug.debug_search_filter.clearRetainingCapacity();
                self.debug.debug_selected_index = null;
                self.clearSelectedNodeServiceEventCache();
                self.debug.debug_scroll_y = 0;
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
                self.debug.node_service_diff_base_index = selected_idx;
                self.clearNodeServiceDiffPreview();
                const msg = std.fmt.allocPrint(self.allocator, "Node diff base set to event #{d}", .{self.debug.debug_events.items[selected_idx].id}) catch null;
                defer if (msg) |value| self.allocator.free(value);
                if (msg) |value| self.appendMessage("system", value, null) catch {};
            },
            .clear_diff_base => {
                self.debug.node_service_diff_base_index = null;
                self.clearNodeServiceDiffPreview();
            },
            .generate_diff => {
                const selected_idx = self.selectedNodeServiceEventInfo().index orelse return;
                const base_idx = self.debug.node_service_diff_base_index orelse return;
                if (base_idx >= self.debug.debug_events.items.len or base_idx == selected_idx) return;
                if (self.buildNodeServiceEventDiffText(base_idx, selected_idx) catch null) |diff| {
                    self.clearNodeServiceDiffPreview();
                    self.debug.node_service_diff_preview = diff;
                } else {
                    self.appendMessage("system", "Unable to build node service diff from selected events.", null) catch {};
                }
            },
            .copy_diff => {
                const selected_idx = self.selectedNodeServiceEventInfo().index orelse return;
                const base_idx = self.debug.node_service_diff_base_index orelse return;
                if (base_idx >= self.debug.debug_events.items.len or base_idx == selected_idx) return;
                const diff_text = if (self.debug.node_service_diff_preview) |value|
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
                const base_idx = self.debug.node_service_diff_base_index orelse return;
                if (base_idx >= self.debug.debug_events.items.len or base_idx == selected_idx) return;
                const diff_text = if (self.debug.node_service_diff_preview) |value|
                    self.allocator.dupe(u8, value) catch null
                else
                    (self.buildNodeServiceEventDiffText(base_idx, selected_idx) catch null);
                defer if (diff_text) |value| self.allocator.free(value);
                if (diff_text) |value| {
                    const export_path = self.exportNodeServiceDiffSnapshot(
                        value,
                        self.debug.debug_events.items[base_idx].id,
                        self.debug.debug_events.items[selected_idx].id,
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
                const sel_idx = self.debug.debug_selected_index orelse return;
                if (sel_idx >= self.debug.debug_events.items.len) return;
                const entry = self.debug.debug_events.items[sel_idx];
                const to_copy = self.formatDebugEventLine(entry) catch "";
                defer if (to_copy.len > 0) self.allocator.free(to_copy);
                if (to_copy.len > 0) {
                    self.copyTextToClipboard(to_copy) catch {};
                    self.appendMessage("system", "Copied debug event.", null) catch {};
                }
            },
        }
    }

    pub fn launcherSettingsModel(self: *App) panels_bridge.LauncherSettingsModel {
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
        const pack_status = zui.ui.theme_engine.runtime.getPackStatus();
        return .{
            .connection_state = connection_state,
            .active_role = active_role,
            .watch_theme_pack = self.settings_panel.watch_theme_pack,
            .auto_connect_on_launch = self.settings_panel.auto_connect_on_launch,
            .ws_verbose_logs = self.settings_panel.ws_verbose_logs,
            .terminal_backend = terminal_backend,
            .theme_mode = self.settings_panel.theme_mode,
            .theme_mode_locked = zui.ui.theme_engine.runtime.getPackModeLockToDefault(),
            .theme_profile = self.settings_panel.theme_profile,
            .theme_pack_status_kind = switch (pack_status.kind) {
                .none => .idle,
                .fetching => .fetching,
                .ok => .ok,
                .failed => .failed,
            },
            .theme_pack_status_text = pack_status.msg,
            .theme_pack_watch_supported = themePackWatchSupported(),
            .theme_pack_reload_supported = true,
            .theme_pack_browse_supported = themePackBrowseSupported(),
            .theme_pack_refresh_supported = themePackRefreshSupported(),
        };
    }

    fn themePackSelected(self: *const App, path: []const u8) bool {
        return std.mem.eql(u8, self.effectiveThemePackPath(), path);
    }

    fn themePackChipLabel(path: []const u8) []const u8 {
        const themes_prefix = "themes/";
        if (std.mem.startsWith(u8, path, themes_prefix)) return path[themes_prefix.len..];
        const idx = std.mem.lastIndexOfAny(u8, path, "/\\") orelse return path;
        return if (idx + 1 < path.len) path[idx + 1 ..] else path;
    }

    pub fn themePackMetaText(self: *const App, buf: []u8) ?[]const u8 {
        _ = self;
        const meta: UiThemePackMeta = zui.ui.theme_engine.runtime.getPackMeta() orelse return null;
        const name = if (meta.name.len > 0) meta.name else meta.id;
        return std.fmt.bufPrint(
            buf,
            "Pack: {s} ({s}) | defaults: {s}/{s}",
            .{ name, meta.author, meta.defaults_variant, meta.defaults_profile },
        ) catch null;
    }

    pub fn populateThemePackQuickPicks(
        self: *const App,
        quick_buf: []panels_bridge.ThemePackQuickPickView,
        recent_buf: []panels_bridge.ThemePackQuickPickView,
        available_buf: []panels_bridge.ThemePackQuickPickView,
    ) struct {
        quick: []const panels_bridge.ThemePackQuickPickView,
        recent: []const panels_bridge.ThemePackQuickPickView,
        available: []const panels_bridge.ThemePackQuickPickView,
    } {
        const builtins = [_]struct { label: []const u8, path: []const u8 }{
            .{ .label = "Modern AI", .path = "themes/zsc_modern_ai" },
        };

        var quick_len: usize = 0;
        for (builtins) |pick| {
            if (quick_len >= quick_buf.len) break;
            quick_buf[quick_len] = .{
                .label = pick.label,
                .value = pick.path,
                .selected = self.themePackSelected(pick.path),
            };
            quick_len += 1;
        }

        var recent_len: usize = 0;
        const recent = self.config.theme_pack_recent orelse &[_][]const u8{};
        for (recent) |item| {
            if (recent_len >= recent_buf.len) break;
            recent_buf[recent_len] = .{
                .label = themePackChipLabel(item),
                .value = item,
                .selected = self.themePackSelected(item),
            };
            recent_len += 1;
        }

        var available_len: usize = 0;
        for (self.theme_pack_entries.items) |entry| {
            if (available_len >= available_buf.len) break;
            if (std.mem.startsWith(u8, entry.name, "zsc_") and !std.mem.eql(u8, entry.name, "zsc_modern_ai")) continue;
            var full_path_buf: [256]u8 = undefined;
            const full_path = std.fmt.bufPrint(&full_path_buf, "themes/{s}", .{entry.name}) catch entry.name;
            available_buf[available_len] = .{
                .label = entry.name,
                .value = entry.name,
                .selected = self.themePackSelected(full_path),
            };
            available_len += 1;
        }

        return .{
            .quick = quick_buf[0..quick_len],
            .recent = recent_buf[0..recent_len],
            .available = available_buf[0..available_len],
        };
    }

    fn replaceSettingsText(self: *App, buf: *std.ArrayList(u8), value: ?[]const u8) void {
        buf.clearRetainingCapacity();
        if (value) |text| buf.appendSlice(self.allocator, text) catch {};
    }

    pub fn performLauncherSettingsAction(self: *App, manager: *panel_manager.PanelManager, action: panels_bridge.LauncherSettingsAction) void {
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
            .set_theme_mode => |mode| {
                self.settings_panel.theme_mode = mode;
                self.applyThemeSettings(false);
            },
            .set_theme_profile => |profile| {
                self.settings_panel.theme_profile = profile;
                self.applyThemeSettings(false);
            },
            .toggle_watch_theme_pack => {
                if (themePackWatchSupported()) {
                    self.settings_panel.watch_theme_pack = !self.settings_panel.watch_theme_pack;
                    if (self.settings_panel.watch_theme_pack) self.syncThemePackWatchStamp();
                } else {
                    self.settings_panel.watch_theme_pack = false;
                }
            },
            .apply_theme_pack_input => {
                _ = self.config.rememberThemePack(self.effectiveThemePackPath());
                self.applyThemeSettings(false);
            },
            .select_theme_pack => |value| {
                if (std.mem.startsWith(u8, value, "themes/") or std.mem.indexOfAny(u8, value, "/\\") != null) {
                    self.replaceSettingsText(&self.settings_panel.theme_pack, value);
                } else {
                    var buf: [256]u8 = undefined;
                    const path = std.fmt.bufPrint(&buf, "themes/{s}", .{value}) catch value;
                    self.replaceSettingsText(&self.settings_panel.theme_pack, path);
                }
                _ = self.config.rememberThemePack(self.effectiveThemePackPath());
                self.applyThemeSettings(false);
            },
            .reload_theme_pack => {
                _ = self.config.rememberThemePack(self.effectiveThemePackPath());
                self.applyThemeSettings(true);
            },
            .disable_theme_pack => {
                self.replaceSettingsText(&self.settings_panel.theme_pack, null);
                self.applyThemeSettings(false);
            },
            .browse_theme_pack => {
                self.openThemePackBrowseLocation();
            },
            .refresh_theme_pack_list => {
                if (themePackRefreshSupported()) self.refreshThemePackEntries();
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

    fn drawFilesystemPanel(self: *App, manager: *panel_manager.PanelManager, rect: UiRect) void {
        filesystem_host_mod.drawFilesystemPanel(self, manager, rect);
    }

    fn drawFilesystemToolsPanel(self: *App, manager: *panel_manager.PanelManager, rect: UiRect) void {
        filesystem_host_mod.drawFilesystemToolsPanel(self, manager, rect);
    }

    fn drawDebugPanel(self: *App, manager: *panel_manager.PanelManager, rect: UiRect) void {
        debug_host_mod.drawDebugPanel(self, manager, rect);
    }

    fn makeDebugFoldKey(event_id: u64, line_index: usize) DebugFoldKey {
        return .{
            .event_id = event_id,
            .line_index = @intCast(line_index),
        };
    }

    fn isDebugBlockCollapsed(self: *App, event_id: u64, line_index: usize) bool {
        return self.debug.debug_folded_blocks.contains(makeDebugFoldKey(event_id, line_index));
    }

    fn toggleDebugBlockCollapsed(self: *App, event_id: u64, line_index: usize) void {
        const key = makeDebugFoldKey(event_id, line_index);
        if (self.debug.debug_folded_blocks.contains(key)) {
            _ = self.debug.debug_folded_blocks.remove(key);
            self.debug.debug_fold_revision +%= 1;
            if (self.debug.debug_fold_revision == 0) self.debug.debug_fold_revision = 1;
            return;
        }
        self.debug.debug_folded_blocks.put(key, {}) catch {};
        self.debug.debug_fold_revision +%= 1;
        if (self.debug.debug_fold_revision == 0) self.debug.debug_fold_revision = 1;
    }

    fn pruneDebugFoldStateForEvent(self: *App, event_id: u64) void {
        var to_remove: std.ArrayList(DebugFoldKey) = .empty;
        defer to_remove.deinit(self.allocator);

        var it = self.debug.debug_folded_blocks.keyIterator();
        while (it.next()) |key_ptr| {
            if (key_ptr.*.event_id == event_id) {
                to_remove.append(self.allocator, key_ptr.*) catch return;
            }
        }
        for (to_remove.items) |key| {
            _ = self.debug.debug_folded_blocks.remove(key);
        }
        if (to_remove.items.len > 0) {
            self.debug.debug_fold_revision +%= 1;
            if (self.debug.debug_fold_revision == 0) self.debug.debug_fold_revision = 1;
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
            entry.cached_visible_rows_fold_revision == self.debug.debug_fold_revision)
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
        entry.cached_visible_rows_fold_revision = self.debug.debug_fold_revision;
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
        return self.syntaxThemeColor(kind);
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
        if (self.debug.debug_selected_node_service_cache_node_id) |value| {
            self.allocator.free(value);
            self.debug.debug_selected_node_service_cache_node_id = null;
        }
        if (self.debug.debug_selected_node_service_cache_diagnostics) |value| {
            self.allocator.free(value);
            self.debug.debug_selected_node_service_cache_diagnostics = null;
        }
        self.debug.debug_selected_node_service_cache_index = null;
        self.debug.debug_selected_node_service_cache_event_id = 0;
    }

    fn selectedNodeServiceEventInfo(self: *App) SelectedNodeServiceEventInfo {
        const selected_idx = self.debug.debug_selected_index orelse {
            self.clearSelectedNodeServiceEventCache();
            return .{};
        };
        if (selected_idx >= self.debug.debug_events.items.len) {
            self.debug.debug_selected_index = null;
            self.clearSelectedNodeServiceEventCache();
            return .{};
        }

        const entry = self.debug.debug_events.items[selected_idx];
        if (!std.mem.eql(u8, entry.category, "control.node_service_event")) {
            self.clearSelectedNodeServiceEventCache();
            return .{};
        }

        if (self.debug.debug_selected_node_service_cache_index == selected_idx and
            self.debug.debug_selected_node_service_cache_event_id == entry.id)
        {
            return .{
                .index = selected_idx,
                .node_id = self.debug.debug_selected_node_service_cache_node_id,
                .diagnostics = self.debug.debug_selected_node_service_cache_diagnostics,
            };
        }

        self.clearSelectedNodeServiceEventCache();
        self.debug.debug_selected_node_service_cache_index = selected_idx;
        self.debug.debug_selected_node_service_cache_event_id = entry.id;

        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, entry.payload_json, .{}) catch null;
        if (parsed) |*parsed_value| {
            defer parsed_value.deinit();
            if (parsed_value.value == .object) {
                if (parsed_value.value.object.get("node_id")) |value| {
                    if (value == .string and value.string.len > 0) {
                        self.debug.debug_selected_node_service_cache_node_id = self.allocator.dupe(u8, value.string) catch null;
                    }
                }
            }
        }
        self.debug.debug_selected_node_service_cache_diagnostics =
            self.buildNodeServiceDeltaDiagnosticsTextFromJson(entry.payload_json) catch null;

        return .{
            .index = selected_idx,
            .node_id = self.debug.debug_selected_node_service_cache_node_id,
            .diagnostics = self.debug.debug_selected_node_service_cache_diagnostics,
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
        if (base_idx >= self.debug.debug_events.items.len or compare_idx >= self.debug.debug_events.items.len) return null;
        const base_entry = self.debug.debug_events.items[base_idx];
        const compare_entry = self.debug.debug_events.items[compare_idx];
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
        self.fs.filesystem_path.clearRetainingCapacity();
        try self.fs.filesystem_path.appendSlice(self.allocator, node_path);
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
        const session_key_for_panel: ?[]const u8 = if (self.chat.current_session_key) |key| key else if (self.connection_state == .connected) "main" else null;
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
            &self.chat.chat_panel_state,
            "spider-gui",
            session_key_for_panel,
            self.activeMessages(),
            null,
            null,
            "🕷",
            "SpiderApp",
            self.chat.chat_sessions.items,
            0,
            panel_rect,
        );

        self.handleChatPanelAction(action);
    }

    pub fn drawStatusOverlay(self: *App, fb_width: u32, fb_height: u32) void {
        const status_height: f32 = 24.0 * self.ui_scale;
        const fb_w: f32 = @floatFromInt(fb_width);
        const fb_h: f32 = @floatFromInt(fb_height);
        const status_rect = UiRect.fromMinSize(
            .{ 0, fb_h - status_height },
            .{ fb_w, status_height },
        );

        const shell = self.sharedStyleSheet().shell;
        const status_panel_rect = Rect{ .min = status_rect.min, .max = status_rect.max };
        self.drawPaintRect(status_panel_rect, shell.status_bar_fill orelse Paint{ .solid = zcolors.withAlpha(self.theme.colors.background, 0.9) });
        self.drawRect(status_panel_rect, shell.status_bar_border orelse self.theme.colors.border);

        // Status indicator
        const indicator_size: f32 = 8.0 * self.ui_scale;
        const tone = self.connectionStatusColors();

        self.ui_commands.pushRect(
            .{
                .min = .{ status_rect.min[0] + 8, status_rect.min[1] + 8 },
                .max = .{ status_rect.min[0] + 8 + indicator_size, status_rect.min[1] + 8 + indicator_size },
            },
            .{ .fill = tone.fill, .stroke = tone.border },
        );

        // Status text
        self.drawText(
            status_rect.min[0] + 24,
            status_rect.min[1] + 4,
            self.status_text,
            tone.text,
        );
    }

    pub fn drawStatusRow(self: *App, rect: Rect) void {
        self.drawSurfacePanel(rect);

        const inner = @max(self.theme.spacing.xs, 6.0 * self.ui_scale);
        const line_height = self.textLineHeight();
        const indicator_size = @max(10.0 * self.ui_scale, line_height * 0.58);
        const indicator_y = rect.min[1] + @max(0.0, (rect.height() - indicator_size) * 0.5);
        const indicator = Rect.fromXYWH(rect.min[0] + inner, indicator_y, indicator_size, indicator_size);
        const tone = self.connectionStatusColors();
        self.drawFilledRect(indicator, tone.fill);
        self.drawRect(indicator, tone.border);

        self.drawTextTrimmed(
            indicator.max[0] + inner,
            rect.min[1] + @max(0.0, (rect.height() - line_height) * 0.5),
            rect.width() - (indicator.max[0] - rect.min[0]) - inner * 2.0,
            self.status_text,
            tone.text,
        );
    }

    pub fn drawVerticalScrollbar(
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
                if (!self.debug.debug_scrollbar_dragging) self.setDragMouseCapture(false);
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
                if (!self.debug.debug_scrollbar_dragging) self.setDragMouseCapture(false);
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

        const scrollbar = self.sharedStyleSheet().scrollbar;
        self.drawFilledRect(track_rect, scrollbar.track orelse zcolors.withAlpha(self.theme.colors.border, 0.25));
        const hovered = thumb_rect.contains(.{ self.mouse_x, self.mouse_y });
        const active = self.form_scroll_drag_target == target;
        const thumb_color = if (active)
            (scrollbar.thumb_active orelse self.theme.colors.primary)
        else if (hovered)
            (scrollbar.thumb_hover orelse zcolors.blend(self.theme.colors.border, self.theme.colors.primary, 0.46))
        else
            (scrollbar.thumb orelse self.theme.colors.border);
        self.drawFilledRect(thumb_rect, thumb_color);
        if (scrollbar.border) |border| self.drawRect(track_rect, border);
    }

    pub fn drawButtonWidget(self: *App, rect: Rect, label: []const u8, opts: widgets.button.Options) bool {
        const block_interaction = self.text_input_context_menu_open and !self.text_input_context_menu_rendering;
        const state = widgets.button.updateState(
            .{ .x = rect.min[0], .y = rect.min[1], .width = rect.width(), .height = rect.height() },
            .{ self.mouse_x, self.mouse_y },
            self.mouse_down,
            opts,
        );

        const ss = self.sharedStyleSheet();
        var variant_style = switch (opts.variant) {
            .primary => ss.button.primary,
            .secondary => ss.button.secondary,
            .ghost => ss.button.ghost,
        };
        var fill = switch (opts.variant) {
            .primary => variant_style.fill orelse Paint{ .solid = self.theme.colors.primary },
            .secondary => variant_style.fill orelse Paint{ .solid = self.theme.colors.surface },
            .ghost => variant_style.fill orelse Paint{ .solid = zcolors.withAlpha(self.theme.colors.primary, 0.08) },
        };
        var border = variant_style.border orelse self.theme.colors.border;
        var text_color = variant_style.text orelse switch (opts.variant) {
            .primary => zcolors.rgba(255, 255, 255, 255),
            .secondary => self.theme.colors.text_primary,
            .ghost => self.theme.colors.primary,
        };

        if (opts.disabled) {
            if (variant_style.states.disabled.fill) |paint| fill = paint;
            if (variant_style.states.disabled.border) |color| border = color;
            if (variant_style.states.disabled.text) |color| text_color = color;
            if (!variant_style.states.disabled.isSet()) {
                fill = switch (fill) {
                    .solid => |color| Paint{ .solid = zcolors.blend(color, self.theme.colors.background, 0.45) },
                    else => fill,
                };
                text_color = zcolors.withAlpha(self.theme.colors.text_secondary, 0.7);
            }
        } else if (state.pressed) {
            if (variant_style.states.pressed.fill) |paint| fill = paint;
            if (variant_style.states.pressed.border) |color| border = color;
            if (variant_style.states.pressed.text) |color| text_color = color;
            if (!variant_style.states.pressed.isSet()) {
                fill = switch (fill) {
                    .solid => |color| Paint{ .solid = zcolors.blend(color, zcolors.rgba(255, 255, 255, 255), 0.22) },
                    else => fill,
                };
            }
        } else if (state.hovered) {
            if (variant_style.states.hover.fill) |paint| fill = paint;
            if (variant_style.states.hover.border) |color| border = color;
            if (variant_style.states.hover.text) |color| text_color = color;
            if (!variant_style.states.hover.isSet()) {
                fill = switch (fill) {
                    .solid => |color| Paint{ .solid = zcolors.blend(color, self.theme.colors.primary, 0.12) },
                    else => fill,
                };
                border = zcolors.blend(border, self.theme.colors.primary, 0.28);
            }
        }

        self.drawPaintRect(rect, fill);
        self.drawRect(rect, border);
        self.drawCenteredText(rect, label, text_color);

        return !block_interaction and !opts.disabled and self.mouse_released and rect.contains(.{ self.mouse_x, self.mouse_y });
    }

    pub fn drawTextInputWidget(
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

        const fill = self.textInputFillPaint(state, opts);
        const border = self.textInputBorderColor(state, opts);

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
                self.drawTextTrimmed(text_x, text_y, max_w, placeholder, self.textInputPlaceholderColor(state, opts));
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
                        self.drawFilledRect(sel_rect, self.textInputSelectionColor(state, opts));
                    }
                }
            }
            self.drawText(text_x, text_y, text[visible_start..], self.textInputTextColor(state, opts));
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
                .{ .fill = self.textInputCaretColor(state, opts) },
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

    fn selectedWorkspaceToken(self: *App, workspace_id: []const u8) ?[]const u8 {
        if (workspace_id.len == 0) return null;
        if (isSystemWorkspaceId(workspace_id)) return null;
        if (self.settings_panel.project_token.items.len > 0) return self.settings_panel.project_token.items;
        return self.config.getWorkspaceToken(workspace_id);
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
                    session.workspace_id orelse "(none)",
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
                session.workspace_id orelse "(none)",
            },
        );
    }

    fn sessionExists(self: *const App, session_key: []const u8) bool {
        for (self.chat.chat_sessions.items) |session| {
            if (std.mem.eql(u8, session.key, session_key)) return true;
        }
        return false;
    }

    fn workspaceTokenForSession(self: *App, workspace_id: ?[]const u8) ?[]const u8 {
        const id = workspace_id orelse return null;
        if (isSystemWorkspaceId(id)) return null;
        if (self.settings_panel.project_id.items.len > 0 and
            std.mem.eql(u8, self.settings_panel.project_id.items, id) and
            self.settings_panel.project_token.items.len > 0)
        {
            return self.settings_panel.project_token.items;
        }
        return self.config.getWorkspaceToken(id);
    }

    fn attachSessionBindingExplicit(
        self: *App,
        client: *ws_client_mod.WebSocketClient,
        session_key: []const u8,
        agent_id: []const u8,
        workspace_id: ?[]const u8,
        workspace_token: ?[]const u8,
    ) !void {
        const payload_json = try self.buildSessionAttachWorkspacePayload(
            session_key,
            agent_id,
            workspace_id,
            workspace_token,
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
        if (self.debug.debug_stream_enabled) self.requestDebugStreamSnapshot(true);
        if (self.debug.node_service_watch_enabled) self.requestNodeServiceSnapshot(true);
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

        if (self.chat.current_session_key == null and history.items.len > 0) {
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

        var effective_workspace_id: ?[]const u8 = session.workspace_id;
        if (effective_workspace_id == null) {
            effective_workspace_id = self.preferredAttachWorkspaceId();
        }
        const effective_workspace_token = self.workspaceTokenForSession(effective_workspace_id);
        self.attachSessionBindingExplicit(
            client,
            session.session_key,
            session.agent_id,
            effective_workspace_id,
            effective_workspace_token,
        ) catch |err| return err;

        if (effective_workspace_id) |workspace_id| {
            try self.ensureSelectedWorkspaceInSettings(workspace_id);
            self.settings_panel.project_token.clearRetainingCapacity();
            if (effective_workspace_token) |token| {
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
            effective_workspace_id,
            effective_workspace_token,
        ) catch |restore_err| {
            std.log.warn("Failed to rebind filesystem transport for restored session: {s}", .{@errorName(restore_err)});
        };
        self.requestDebugStreamSnapshot(true);
        self.debug.node_service_watch_enabled = true;
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

    fn resolveAttachAgentForWorkspace(
        self: *App,
        client: *ws_client_mod.WebSocketClient,
        session_key: []const u8,
        workspace_id: ?[]const u8,
    ) ![]u8 {
        var resolved_agent = if (self.selectedAgentId()) |value| blk: {
            // Prevent stale persisted user-scoped agent ids from being reused on admin connects.
            if (self.config.active_role == .admin and isUserScopedAgentId(value)) {
                break :blk try self.fetchDefaultAgentFromServer(client, session_key);
            }
            break :blk try self.allocator.dupe(u8, value);
        } else try self.fetchDefaultAgentFromServer(client, session_key);
        errdefer self.allocator.free(resolved_agent);

        if (isSystemWorkspaceId(workspace_id)) {
            if (!isSystemAgentId(resolved_agent)) {
                self.allocator.free(resolved_agent);
                resolved_agent = try self.allocator.dupe(u8, system_agent_id);
            }
            return resolved_agent;
        }

        if (workspace_id != null and isSystemAgentId(resolved_agent)) {
            self.allocator.free(resolved_agent);
            resolved_agent = try self.fetchFirstNonSystemAgentFromServer(client);
        }

        return resolved_agent;
    }

    fn buildSessionAttachWorkspacePayload(
        self: *App,
        session_key: []const u8,
        agent_id: []const u8,
        workspace_id: ?[]const u8,
        workspace_token: ?[]const u8,
    ) ![]u8 {
        const requested_workspace = workspace_id orelse return error.ProjectIdRequired;
        const trimmed_workspace = std.mem.trim(u8, requested_workspace, " \t\r\n");
        if (trimmed_workspace.len == 0) return error.ProjectIdRequired;
        if (!isValidSessionKeyForAttach(session_key)) return error.InvalidSessionKey;
        if (!isValidAgentIdForAttach(agent_id)) return error.InvalidAgentId;
        if (!isValidProjectIdForAttach(trimmed_workspace)) return error.InvalidProjectId;
        const normalized_workspace_token = normalizeWorkspaceToken(workspace_token);

        const escaped_session = try jsonEscape(self.allocator, session_key);
        defer self.allocator.free(escaped_session);
        const escaped_agent = try jsonEscape(self.allocator, agent_id);
        defer self.allocator.free(escaped_agent);
        const escaped_workspace = try jsonEscape(self.allocator, trimmed_workspace);
        defer self.allocator.free(escaped_workspace);

        var out = std.ArrayListUnmanaged(u8){};
        defer out.deinit(self.allocator);
        try out.writer(self.allocator).print(
            "{{\"session_key\":\"{s}\",\"agent_id\":\"{s}\",\"workspace_id\":\"{s}\"",
            .{ escaped_session, escaped_agent, escaped_workspace },
        );
        if (normalized_workspace_token) |token| {
            const escaped_token = try jsonEscape(self.allocator, token);
            defer self.allocator.free(escaped_token);
            try out.writer(self.allocator).print(",\"workspace_token\":\"{s}\"", .{escaped_token});
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

    fn attachSessionBindingWithWorkspace(
        self: *App,
        client: *ws_client_mod.WebSocketClient,
        session_key: []const u8,
        workspace_id: ?[]const u8,
        workspace_token: ?[]const u8,
    ) !void {
        std.log.info(
            "[GUI] attachSessionBindingWithWorkspace: session={s} workspace={s} token={} state={s}",
            .{
                session_key,
                workspace_id orelse "(none)",
                normalizeWorkspaceToken(workspace_token) != null,
                @tagName(self.session_attach_state),
            },
        );
        const resolved_agent = try self.resolveAttachAgentForWorkspace(
            client,
            session_key,
            workspace_id,
        );
        defer self.allocator.free(resolved_agent);
        std.log.info(
            "[GUI] attachSessionBindingWithWorkspace: resolved_agent={s} workspace={s}",
            .{ resolved_agent, workspace_id orelse "(none)" },
        );

        const payload_json = try self.buildSessionAttachWorkspacePayload(
            session_key,
            resolved_agent,
            workspace_id,
            workspace_token,
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
            const has_workspace_token = normalizeWorkspaceToken(workspace_token) != null;
            if (err == error.RemoteError and
                isSystemWorkspaceId(workspace_id) and
                has_workspace_token)
            {
                const remote = control_plane.lastRemoteError() orelse "";
                const token_rejected = std.mem.indexOf(u8, remote, "workspace_token") != null;
                const invalid_payload = std.mem.indexOf(u8, remote, "invalid_payload") != null;
                if (token_rejected or invalid_payload) {
                    std.log.warn(
                        "Session attach for system workspace failed with token ({s}); retrying without workspace_token",
                        .{remote},
                    );
                    const retry_payload_json = try self.buildSessionAttachWorkspacePayload(
                        session_key,
                        resolved_agent,
                        workspace_id,
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
                "[GUI] attachSessionBindingWithWorkspace failed: session={s} workspace={s} agent={s} err={s} detail={s}",
                .{
                    session_key,
                    workspace_id orelse "(none)",
                    resolved_agent,
                    @errorName(err),
                    if (err == error.RemoteError) (control_plane.lastRemoteError() orelse "(none)") else "(none)",
                },
            );
            return err;
        };
        defer self.allocator.free(response_payload);

        std.log.info(
            "[GUI] attachSessionBindingWithWorkspace ok: session={s} workspace={s} agent={s}",
            .{ session_key, workspace_id orelse "(none)", resolved_agent },
        );
        self.invalidateFsrpcAttachment();
        if (self.debug.debug_stream_enabled) self.requestDebugStreamSnapshot(true);
        if (self.debug.node_service_watch_enabled) self.requestNodeServiceSnapshot(true);
        try self.setDefaultAgentInSettings(resolved_agent);
    }

    fn attachSessionBinding(self: *App, client: *ws_client_mod.WebSocketClient, session_key: []const u8) !void {
        const workspace_id = self.preferredAttachWorkspaceId();
        const workspace_token = self.workspaceTokenForSession(workspace_id);
        try self.attachSessionBindingWithWorkspace(
            client,
            session_key,
            workspace_id,
            workspace_token,
        );
    }

    fn attachSelectedSessionFromPanel(self: *App) !void {
        const client = if (self.ws_client) |*value| value else return error.NotConnected;
        const workspace_id = self.selectedWorkspaceId() orelse return error.ProjectIdRequired;
        const workspace_token = self.selectedWorkspaceToken(workspace_id);
        const session_key = try self.currentSessionOrDefault();

        try self.ensureSessionExists(session_key, session_key);
        try self.attachSessionBindingWithWorkspace(
            client,
            session_key,
            workspace_id,
            workspace_token,
        );
        self.refreshSessionAttachStatusOnce(client, session_key);

        var resolved_agent = self.selectedAgentId();
        var fetched_agent: ?[]u8 = null;
        defer if (fetched_agent) |value| self.allocator.free(value);
        if (resolved_agent == null) {
            fetched_agent = self.fetchDefaultAgentFromServer(client, session_key) catch null;
            if (fetched_agent) |agent_id| {
                resolved_agent = agent_id;
                try self.setDefaultAgentInSettings(agent_id);
            }
        }

        try self.startFilesystemWorker(
            client.url_buf,
            client.token_buf,
            session_key,
            resolved_agent,
            workspace_id,
            workspace_token,
        );
        self.clearFilesystemError();
        self.requestDebugStreamSnapshot(true);
        self.debug.node_service_watch_enabled = true;
        self.requestNodeServiceSnapshot(true);
        self.clearWorkspaceError();
        try self.syncSettingsToConfig();

        const notice = try std.fmt.allocPrint(
            self.allocator,
            "Attached session {s} to workspace {s}.",
            .{ session_key, workspace_id },
        );
        defer self.allocator.free(notice);
        try self.appendMessage("system", notice, null);
    }

    pub fn tryConnect(self: *App, manager: *panel_manager.PanelManager) !void {
        if (self.settings_panel.server_url.items.len == 0) {
            self.setConnectionState(.error_state, "Server URL cannot be empty");
            return;
        }

        const had_pending_send = self.chat.pending_send_message_id != null;
        self.setConnectionState(.connecting, "Connecting...");
        self.session_attach_state = .unknown;
        self.clearConnectSetupHint();
        self.stopFilesystemWorker();
        self.clearFilesystemDirCache();
        self.clearContractServices();
        self.clearTerminalState();
        self.resetFsrpcConnectionState();
        self.mount_control_ready = false;
        if (self.ws_client) |*existing| {
            while (existing.tryReceive()) |msg| self.allocator.free(msg);
            existing.deinit();
            self.ws_client = null;
        }
        self.debug.debug_stream_enabled = true;
        self.debug.debug_stream_snapshot_pending = false;
        self.debug.debug_stream_snapshot_retry_at_ms = 0;
        self.debug.node_service_watch_enabled = false;
        self.debug.node_service_snapshot_pending = false;
        self.debug.node_service_snapshot_retry_at_ms = 0;
        self.clearDebugStreamSnapshot();

        const effective_url = std.mem.trim(u8, self.settings_panel.server_url.items, " \t\r\n");
        if (effective_url.len == 0) {
            self.setConnectionState(.error_state, "Server URL cannot be empty");
            return;
        }
        try self.persistLauncherConnectToken();
        const connect_token = std.mem.trim(u8, self.ws.launcher_connect_token.items, " \t\r\n");
        std.log.info(
            "[GUI] SpiderApp v{s} connect requested url={s} token_present={}",
            .{ currentBuildLabel(), effective_url, connect_token.len > 0 },
        );
        appendGuiDiagnosticLogFmt("[GUI] SpiderApp v{s} connect requested url={s} token_present={}", .{
            currentBuildLabel(),
            effective_url,
            connect_token.len > 0,
        });
        if (connect_token.len == 0) {
            const msg = try self.allocator.dupe(u8, "Access token is required to connect.");
            defer self.allocator.free(msg);
            self.setConnectionState(.error_state, msg);
            if (self.ui_stage == .launcher) self.setLauncherNotice(msg);
            appendGuiDiagnosticLogFmt("[GUI] connect blocked: {s}", .{msg});
            return error.AuthTokenRequired;
        }
        var ws_client = ws_client_mod.WebSocketClient.init(self.allocator, effective_url, connect_token) catch |err| {
            const msg = try std.fmt.allocPrint(self.allocator, "Client init failed: {s}", .{@errorName(err)});
            defer self.allocator.free(msg);
            self.setConnectionState(.error_state, msg);
            appendGuiDiagnosticLogFmt("[GUI] client init failed: {s}", .{@errorName(err)});
            return;
        };
        ws_client.setVerboseLogs(self.settings_panel.ws_verbose_logs);
        self.ws_client = ws_client;

        self.ws_client.?.connect() catch |err| {
            self.ws_client.?.deinit();
            self.ws_client = null;
            self.mount_control_ready = false;
            const msg = try std.fmt.allocPrint(self.allocator, "Connect failed: {s}", .{@errorName(err)});
            defer self.allocator.free(msg);
            self.setConnectionState(.error_state, msg);
            appendGuiDiagnosticLogFmt("[GUI] websocket connect failed: {s}", .{@errorName(err)});
            return;
        };

        if (self.ws_client) |*client| {
            const connect_payload_json = control_plane.ensureUnifiedV2ConnectionPayloadJsonWithTimeout(
                self.allocator,
                client,
                &self.message_counter,
                CONTROL_CONNECT_TIMEOUT_MS,
            ) catch |err| {
                std.log.err("[GUI] unified control connect failed: {s}", .{@errorName(err)});
                appendGuiDiagnosticLogFmt("[GUI] unified control connect failed: {s}", .{@errorName(err)});
                client.deinit();
                self.ws_client = null;
                self.mount_control_ready = false;
                const msg = if (err == error.RemoteError) blk: {
                    if (control_plane.lastRemoteError()) |remote| {
                        std.log.err("[GUI] remote control error detail: {s}", .{remote});
                        appendGuiDiagnosticLogFmt("[GUI] remote control error detail: {s}", .{remote});
                        if (isProvisioningRemoteError(remote)) {
                            break :blk self.formatControlRemoteMessage("Connection blocked", remote) orelse
                                try std.fmt.allocPrint(self.allocator, "Connection blocked: {s}", .{remote});
                        }
                        if (isTokenAuthRemoteError(remote)) {
                            self.disableAutoConnectAfterAuthFailure();
                            self.settings_panel.focused_field = .project_operator_token;
                            break :blk try std.fmt.allocPrint(
                                self.allocator,
                                "Handshake failed: {s}. Update the workspace operator token and reconnect.",
                                .{remote},
                            );
                        }
                        break :blk try std.fmt.allocPrint(self.allocator, "Handshake failed: {s}", .{remote});
                    }
                    break :blk try std.fmt.allocPrint(self.allocator, "Handshake failed: {s}", .{@errorName(err)});
                } else try std.fmt.allocPrint(self.allocator, "Handshake failed: {s}", .{@errorName(err)});
                defer self.allocator.free(msg);
                self.setConnectionState(.error_state, msg);
                appendGuiDiagnosticLogFmt("[GUI] handshake result: {s}", .{msg});
                return;
            };
            defer self.allocator.free(connect_payload_json);
            std.log.info("[GUI] unified control connect succeeded payload={s}", .{connect_payload_json});
            appendGuiDiagnosticLogFmt("[GUI] unified control connect succeeded payload={s}", .{connect_payload_json});
            self.mount_control_ready = true;
            self.applyConnectSetupHintFromPayload(connect_payload_json) catch |err| {
                std.log.warn("Failed to parse connect setup hint payload: {s}", .{@errorName(err)});
                self.clearConnectSetupHint();
                appendGuiDiagnosticLogFmt("[GUI] connect payload hint parse failed: {s}", .{@errorName(err)});
            };
            if (storage.isAndroid()) {
                self.ensureAppLocalNodeBootstrap(client) catch |err| {
                    std.log.warn("SpiderApp Android local node bootstrap skipped: {s}", .{@errorName(err)});
                    appendGuiDiagnosticLogFmt("[GUI] Android local node bootstrap skipped: {s}", .{@errorName(err)});
                };
            }
        }

        self.setFilesystemError("Filesystem transport is idle until you attach a Spiderweb session to the selected workspace.");
        self.setConnectionState(.connected, "Connected");
        if (self.ui_stage == .launcher) {
            self.setLauncherNotice("Connected. Select a workspace to open.");
        }
        self.requestDebugStreamSnapshot(true);
        self.debug.node_service_watch_enabled = true;
        self.requestNodeServiceSnapshot(true);
        self.settings_panel.focused_field = .none;
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
        if (self.chat.chat_sessions.items.len == 0) {
            try self.ensureSessionExists("main", "Main");
        } else if (self.chat.current_session_key == null) {
            try self.setCurrentSessionKey(self.chat.chat_sessions.items[0].key);
        }

        if (self.connect_setup_hint) |hint| {
            if (hint.required) {
                const base = hint.message orelse "Workspace setup is required. Ask Spiderweb to gather setup details.";
                const setup_notice = if (hint.workspace_vision) |vision|
                    std.fmt.allocPrint(self.allocator, "{s} Workspace vision: {s}", .{ base, vision }) catch null
                else
                    self.allocator.dupe(u8, base) catch null;
                defer if (setup_notice) |value| self.allocator.free(value);
                if (setup_notice) |notice| {
                    self.setWorkspaceError(notice);
                    try self.appendMessage("system", notice, null);
                }
            }
        }

        if (had_pending_send) {
            self.chat.pending_send_resume_notified = true;
        }
        if (had_pending_send) {
            _ = try self.tryResumePendingSendJob();
            try self.appendMessage(
                "system",
                "Reconnected to Spiderweb. Pending chat/job state was cleared because chat transport is being redesigned.",
                null,
            );
        } else {
            try self.appendMessage("system", "Connected to Spiderweb", null);
        }
        _ = try self.ensureWorkspacePanel(manager);
    }

    fn focusSettingsPanel(_: *App, manager: *panel_manager.PanelManager) void {
        for (manager.workspace.panels.items) |*panel| {
            if (panel.kind == .Settings or panel.kind == .Control) {
                manager.focusPanel(panel.id);
                break;
            }
        }
    }

    fn ensureSettingsPanel(self: *App, manager: *panel_manager.PanelManager) void {
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
            .projects => &self.settings_panel.workspaces_scroll_y,
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
        self.ws.launcher_selected_profile_index = 0;
        const selected_id = self.config.selected_profile_id orelse return;
        for (self.config.connection_profiles, 0..) |profile, idx| {
            if (!std.mem.eql(u8, profile.id, selected_id)) continue;
            self.ws.launcher_selected_profile_index = idx;
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

    pub fn saveSelectedProfileFromLauncher(self: *App) !void {
        if (self.config.connection_profiles.len == 0) return error.ProfileNotFound;
        const profile_name = std.mem.trim(u8, self.ws.launcher_profile_name.items, " \t\r\n");
        const server_url = std.mem.trim(u8, self.settings_panel.server_url.items, " \t\r\n");
        const metadata_trimmed = std.mem.trim(u8, self.ws.launcher_profile_metadata.items, " \t\r\n");
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

    pub fn createConnectionProfileFromLauncher(self: *App) !void {
        const profile_name = std.mem.trim(u8, self.ws.launcher_profile_name.items, " \t\r\n");
        const server_url = std.mem.trim(u8, self.settings_panel.server_url.items, " \t\r\n");
        const metadata_trimmed = std.mem.trim(u8, self.ws.launcher_profile_metadata.items, " \t\r\n");
        if (server_url.len == 0) return error.ServerUrlRequired;

        const display_name = if (profile_name.len > 0) profile_name else "Spiderweb";
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

    pub fn applyLauncherSelectedProfile(self: *App) !void {
        if (self.config.connection_profiles.len == 0) return;
        const index = @min(self.ws.launcher_selected_profile_index, self.config.connection_profiles.len - 1);
        const profile = self.config.connection_profiles[index];
        try self.config.setSelectedProfileById(profile.id);
        self.settings_panel.server_url.clearRetainingCapacity();
        try self.settings_panel.server_url.appendSlice(self.allocator, self.config.server_url);
        self.ws.launcher_profile_name.clearRetainingCapacity();
        try self.ws.launcher_profile_name.appendSlice(self.allocator, profile.name);
        self.ws.launcher_profile_metadata.clearRetainingCapacity();
        if (profile.metadata) |value| {
            try self.ws.launcher_profile_metadata.appendSlice(self.allocator, value);
        }
        try self.config.setRoleToken(.admin, "");
        try self.config.setRoleToken(.user, "");
        self.settings_panel.project_operator_token.clearRetainingCapacity();
        if (!self.launch_uses_env_token) {
            if (self.credential_store.load(profile.id, "role_admin") catch null) |token| {
                defer self.allocator.free(token);
                try self.config.setRoleToken(.admin, token);
                try self.settings_panel.project_operator_token.appendSlice(self.allocator, token);
            }
            if (self.credential_store.load(profile.id, "role_user") catch null) |token| {
                defer self.allocator.free(token);
                try self.config.setRoleToken(.user, token);
            }
        } else if (self.config.getRoleToken(.admin).len > 0) {
            try self.settings_panel.project_operator_token.appendSlice(self.allocator, self.config.getRoleToken(.admin));
        }
        try self.syncLauncherConnectTokenFromConfig();
    }

    pub fn setLauncherNotice(self: *App, message: []const u8) void {
        if (self.ws.launcher_notice) |existing| self.allocator.free(existing);
        self.ws.launcher_notice = self.allocator.dupe(u8, message) catch null;
    }

    fn clearLauncherNotice(self: *App) void {
        if (self.ws.launcher_notice) |existing| self.allocator.free(existing);
        self.ws.launcher_notice = null;
    }

    fn clearLauncherCreateWorkspaceTemplates(self: *App) void {
        workspace_types.deinitWorkspaceTemplateList(self.allocator, &self.ws.launcher_create_templates);
        self.ws.launcher_create_selected_template_index = 0;
        self.ws.launcher_create_template_page = 0;
    }

    pub fn setLauncherCreateWorkspaceModalError(self: *App, message: []const u8) void {
        if (self.ws.launcher_create_modal_error) |existing| self.allocator.free(existing);
        self.ws.launcher_create_modal_error = self.allocator.dupe(u8, message) catch null;
    }

    pub fn clearLauncherCreateWorkspaceModalError(self: *App) void {
        if (self.ws.launcher_create_modal_error) |existing| self.allocator.free(existing);
        self.ws.launcher_create_modal_error = null;
    }

    fn clearPackageManagerPackages(self: *App) void {
        for (self.package_manager_packages.items) |*entry| entry.deinit(self.allocator);
        self.package_manager_packages.deinit(self.allocator);
        self.package_manager_packages = .{};
        self.package_manager_selected_index = 0;
    }

    fn setPackageManagerModalError(self: *App, message: []const u8) void {
        if (self.package_manager_modal_error) |existing| self.allocator.free(existing);
        self.package_manager_modal_error = self.allocator.dupe(u8, message) catch null;
    }

    fn clearPackageManagerModalError(self: *App) void {
        if (self.package_manager_modal_error) |existing| self.allocator.free(existing);
        self.package_manager_modal_error = null;
    }

    fn setPackageManagerModalNotice(self: *App, message: []const u8) void {
        if (self.package_manager_modal_notice) |existing| self.allocator.free(existing);
        self.package_manager_modal_notice = self.allocator.dupe(u8, message) catch null;
    }

    fn clearPackageManagerModalNotice(self: *App) void {
        if (self.package_manager_modal_notice) |existing| self.allocator.free(existing);
        self.package_manager_modal_notice = null;
    }

    pub fn requestPackageManagerRefresh(self: *App, force: bool) void {
        if (self.connection_state != .connected) return;
        if (self.package_manager_refresh_busy) return;
        const now = std.time.milliTimestamp();
        if (!force and self.package_manager_last_refresh_ms != 0 and now - self.package_manager_last_refresh_ms < 10_000) return;
        self.package_manager_refresh_busy = true;
        defer self.package_manager_refresh_busy = false;
        self.package_manager_last_refresh_ms = now;
        self.refreshPackageManagerPackages() catch |err| {
            if (err != error.RemoteError) {
                const msg = self.formatControlOpError("Package list failed", err);
                if (msg) |text| {
                    defer self.allocator.free(text);
                    self.setPackageManagerModalError(text);
                } else {
                    self.setPackageManagerModalError("Package list failed.");
                }
            }
        };
    }

    pub fn packageManagerUpdateSelected(self: *App, activate: bool) void {
        const entry = self.selectedPackageManagerEntry() orelse return;
        const escaped_id = jsonEscape(self.allocator, entry.package_id) catch return;
        defer self.allocator.free(escaped_id);
        const payload = std.fmt.allocPrint(
            self.allocator,
            "{{\"venom_id\":\"{s}\",\"activate\":{s}}}",
            .{ escaped_id, if (activate) "true" else "false" },
        ) catch return;
        defer self.allocator.free(payload);
        self.runPackageManagerOperation(
            "update.json",
            payload,
            if (activate) "Package updated and switched." else "Package update installed.",
        ) catch |err| {
            if (err != error.RemoteError) {
                const msg = self.formatControlOpError("Package update failed", err);
                if (msg) |text| {
                    defer self.allocator.free(text);
                    self.setPackageManagerModalError(text);
                }
            }
        };
    }

    pub fn packageManagerRollbackSelected(self: *App) void {
        const entry = self.selectedPackageManagerEntry() orelse return;
        const payload = self.buildPackageManagerIdPayload(entry.package_id) catch return;
        defer self.allocator.free(payload);
        self.runPackageManagerOperation("rollback.json", payload, "Package rolled back.") catch |err| {
            if (err != error.RemoteError) {
                const msg = self.formatControlOpError("Package rollback failed", err);
                if (msg) |text| {
                    defer self.allocator.free(text);
                    self.setPackageManagerModalError(text);
                }
            }
        };
    }

    pub fn packageManagerToggleSelectedEnabled(self: *App) void {
        const entry = self.selectedPackageManagerEntry() orelse return;
        const payload = self.buildPackageManagerIdPayload(entry.package_id) catch return;
        defer self.allocator.free(payload);
        const control_name = if (entry.enabled) "disable.json" else "enable.json";
        const notice = if (entry.enabled) "Package disabled." else "Package enabled.";
        self.runPackageManagerOperation(control_name, payload, notice) catch |err| {
            if (err != error.RemoteError) {
                const msg = self.formatControlOpError("Package update failed", err);
                if (msg) |text| {
                    defer self.allocator.free(text);
                    self.setPackageManagerModalError(text);
                }
            }
        };
    }

    fn setAboutModalNotice(self: *App, message: []const u8) void {
        if (self.about_modal_notice) |existing| self.allocator.free(existing);
        self.about_modal_notice = self.allocator.dupe(u8, message) catch null;
    }

    fn clearAboutModalNotice(self: *App) void {
        if (self.about_modal_notice) |existing| self.allocator.free(existing);
        self.about_modal_notice = null;
    }

    fn selectedPackageManagerEntry(self: *App) ?*const PackageManagerEntry {
        if (self.package_manager_packages.items.len == 0) return null;
        if (self.package_manager_selected_index >= self.package_manager_packages.items.len) return null;
        return &self.package_manager_packages.items[self.package_manager_selected_index];
    }

    fn openPackageManagerModal(self: *App) void {
        self.package_manager_modal_open = true;
        self.settings_panel.focused_field = .package_manager_install_payload;
        self.clearPackageManagerModalError();
        self.clearPackageManagerModalNotice();
        self.requestPackageManagerRefresh(true);
    }

    fn closePackageManagerModal(self: *App) void {
        self.package_manager_modal_open = false;
        self.clearPackageManagerModalError();
        self.clearPackageManagerModalNotice();
        if (self.settings_panel.focused_field == .package_manager_install_payload) {
            self.settings_panel.focused_field = .none;
        }
    }

    fn openAboutModal(self: *App) void {
        self.about_modal_open = true;
        self.settings_panel.focused_field = .about_modal_build_label;
        self.about_modal_build_label.clearRetainingCapacity();
        self.about_modal_build_label.appendSlice(self.allocator, currentBuildLabel()) catch {};
        self.clearAboutModalNotice();
    }

    fn closeAboutModal(self: *App) void {
        self.about_modal_open = false;
        self.clearAboutModalNotice();
        if (self.settings_panel.focused_field == .about_modal_build_label) {
            self.settings_panel.focused_field = .none;
        }
    }

    pub fn syncLauncherCreateSelectedTemplateToSettings(self: *App) !void {
        if (self.ws.launcher_create_templates.items.len == 0) {
            self.settings_panel.workspace_template_id.clearRetainingCapacity();
            return;
        }
        const selected_index = @min(self.ws.launcher_create_selected_template_index, self.ws.launcher_create_templates.items.len - 1);
        self.ws.launcher_create_selected_template_index = selected_index;
        self.settings_panel.workspace_template_id.clearRetainingCapacity();
        try self.settings_panel.workspace_template_id.appendSlice(
            self.allocator,
            self.ws.launcher_create_templates.items[selected_index].id,
        );
    }

    pub fn selectedLauncherCreateWorkspaceTemplate(self: *const App) ?*const workspace_types.WorkspaceTemplate {
        if (self.ws.launcher_create_templates.items.len == 0) return null;
        const selected_index = @min(self.ws.launcher_create_selected_template_index, self.ws.launcher_create_templates.items.len - 1);
        return &self.ws.launcher_create_templates.items[selected_index];
    }

    pub fn refreshLauncherCreateWorkspaceTemplates(self: *App) !void {
        const client = if (self.ws_client) |*value| value else return error.NotConnected;
        try control_plane.ensureUnifiedV2Connection(self.allocator, client, &self.message_counter);

        var templates = try control_plane.listWorkspaceTemplates(self.allocator, client, &self.message_counter);
        errdefer workspace_types.deinitWorkspaceTemplateList(self.allocator, &templates);

        self.clearLauncherCreateWorkspaceTemplates();
        self.ws.launcher_create_templates = templates;
        self.ws.launcher_create_selected_template_index = 0;

        const preferred_template = std.mem.trim(u8, self.settings_panel.workspace_template_id.items, " \t\r\n");
        if (preferred_template.len > 0) {
            for (self.ws.launcher_create_templates.items, 0..) |template, idx| {
                if (std.mem.eql(u8, template.id, preferred_template)) {
                    self.ws.launcher_create_selected_template_index = idx;
                    break;
                }
            }
        }
        try self.syncLauncherCreateSelectedTemplateToSettings();
    }

    pub fn openLauncherCreateWorkspaceModal(self: *App) void {
        self.ws.launcher_create_modal_open = true;
        self.settings_panel.focused_field = .project_create_name;
        self.clearLauncherCreateWorkspaceModalError();
        self.refreshLauncherCreateWorkspaceTemplates() catch |err| {
            self.clearLauncherCreateWorkspaceTemplates();
            const msg = self.formatControlOpError("Workspace template list failed", err);
            if (msg) |text| {
                defer self.allocator.free(text);
                self.setLauncherCreateWorkspaceModalError(text);
            } else {
                self.setLauncherCreateWorkspaceModalError("Workspace template list failed.");
            }
        };
    }

    pub fn closeLauncherCreateWorkspaceModal(self: *App) void {
        self.ws.launcher_create_modal_open = false;
        self.clearLauncherCreateWorkspaceModalError();
        if (self.settings_panel.focused_field == .project_create_name or
            self.settings_panel.focused_field == .project_create_vision)
        {
            self.settings_panel.focused_field = .launcher_project_filter;
        }
    }

    pub fn createWorkspaceFromLauncherModal(self: *App) !void {
        const name = std.mem.trim(u8, self.settings_panel.project_create_name.items, " \t\r\n");
        if (name.len == 0) return error.MissingField;
        if (self.ws.launcher_create_templates.items.len == 0) return error.MissingField;
        try self.syncLauncherCreateSelectedTemplateToSettings();
        try self.createWorkspaceFromPanel();
        self.closeLauncherCreateWorkspaceModal();
        self.setLauncherNotice("Workspace created.");
    }

    fn canRenderWorkspaceStage(self: *const App) bool {
        if (self.connection_state != .connected) return false;
        if (self.ws_client == null) return false;
        if (self.ws.active_workspace_id == null) return false;
        return true;
    }

    fn layoutPathForWorkspace(
        self: *App,
        profile_id: []const u8,
        workspace_id: []const u8,
    ) ![]u8 {
        const config_dir = try config_mod.Config.getConfigDir(self.allocator);
        defer self.allocator.free(config_dir);
        const hash = std.hash.Wyhash.hash(0, profile_id) ^ (std.hash.Wyhash.hash(0, workspace_id) << 1);
        const file_name = try std.fmt.allocPrint(self.allocator, "{x:0>16}.workspace.json", .{hash});
        defer self.allocator.free(file_name);
        const layouts_dir = try std.fs.path.join(self.allocator, &.{ config_dir, "layouts" });
        defer self.allocator.free(layouts_dir);
        try std.fs.cwd().makePath(layouts_dir);
        return std.fs.path.join(self.allocator, &.{ layouts_dir, file_name });
    }

    fn saveActiveWorkspaceLayout(self: *App) void {
        const profile_id = self.active_profile_id orelse return;
        const workspace_id = self.ws.active_workspace_id orelse return;
        const layout_path = self.layoutPathForWorkspace(profile_id, workspace_id) catch return;
        defer self.allocator.free(layout_path);
        zui.ui.workspace_store.save(self.allocator, layout_path, &self.manager.workspace) catch return;
        self.config.setWorkspaceLayoutPath(profile_id, workspace_id, layout_path) catch {};
        self.config.save() catch {};
    }

    fn restoreWorkspaceLayout(self: *App, profile_id: []const u8, workspace_id: []const u8) !void {
        const configured_path = self.config.workspaceLayoutPath(profile_id, workspace_id);
        const layout_path = if (configured_path) |path|
            try self.allocator.dupe(u8, path)
        else blk: {
            break :blk try self.layoutPathForWorkspace(profile_id, workspace_id);
        };
        defer self.allocator.free(layout_path);

        var next_workspace = zui.ui.workspace_store.loadOrDefault(self.allocator, layout_path) catch |err| blk: {
            std.log.warn("Failed to load workspace layout, using canonical default: {s}", .{@errorName(err)});
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
        _ = self.ensureWorkspacePanel(&self.manager) catch {};
    }

    pub fn openSelectedWorkspaceFromLauncher(self: *App) !void {
        if (self.connection_state != .connected) return error.NotConnected;
        if (self.ws_client == null) return error.NotConnected;
        const project_id = self.selectedWorkspaceId() orelse return error.ProjectIdRequired;
        if (project_id.len == 0) return error.ProjectIdRequired;
        try self.activateSelectedWorkspace();
        const profile_id = self.config.selectedProfileId();
        self.saveActiveWorkspaceLayout();
        if (self.active_profile_id) |existing| self.allocator.free(existing);
        if (self.ws.active_workspace_id) |existing| self.allocator.free(existing);
        self.active_profile_id = try self.allocator.dupe(u8, profile_id);
        self.ws.active_workspace_id = try self.allocator.dupe(u8, project_id);
        self.ui_stage = .workspace;
        self.ide_menu_open = null;
        self.windows_menu_open_window_id = null;
        self.setLauncherNotice("Workspace opened.");
        self.restoreWorkspaceLayout(profile_id, project_id) catch {};
        self.config.recordRecentWorkspace(profile_id, project_id, null) catch {};
        self.config.markWorkflowCompleted(profile_id, project_id, workflow_start_local_workspace) catch {};
        self.config.save() catch {};
        _ = c.SDL_SetWindowTitle(self.window, platformWindowTitle("Spider Legacy Runtime - Workspace"));
    }

    fn returnToLauncher(self: *App, reason: stage_machine.ReturnReason) void {
        self.saveActiveWorkspaceLayout();
        self.closePackageManagerModal();
        self.closeAboutModal();
        self.ui_stage = .launcher;
        self.ide_menu_open = null;
        self.windows_menu_open_window_id = null;
        if (self.active_profile_id) |value| {
            self.allocator.free(value);
            self.active_profile_id = null;
        }
        if (self.ws.active_workspace_id) |value| {
            self.allocator.free(value);
            self.ws.active_workspace_id = null;
        }
        self.closeAllSecondaryWindows();
        _ = c.SDL_SetWindowTitle(self.window, platformWindowTitle("Spider Legacy Runtime - Launcher"));
        switch (reason) {
            .switched_workspace => self.setLauncherNotice("Switched back to launcher. Select another workspace."),
            .connection_lost => self.setLauncherNotice("Connection lost. Reconnect to continue."),
            .disconnected => self.setLauncherNotice("Disconnected from Spiderweb."),
            .none => self.clearLauncherNotice(),
        }

        if (reason == .connection_lost or reason == .disconnected) {
            self.clearWorkspaceData();
            self.clearFilesystemData();
            self.clearFilesystemDirCache();
            self.clearTerminalState();
            self.clearTerminalTarget();
            self.clearNodeServiceReloadDiagnostics();
        }

        if (reason == .switched_workspace) {
            self.clearTerminalState();
            self.clearTerminalTarget();
        }

        if (reason == .switched_workspace and self.connection_state == .connected and self.ws_client != null) {
            self.refreshWorkspaceData() catch |err| {
                const msg = std.fmt.allocPrint(self.allocator, "Workspace refresh failed: {s}", .{@errorName(err)}) catch null;
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
        if (!platformSupportsWindowGeometryPersistence()) return;
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

    pub fn disconnect(self: *App) void {
        self.setDragMouseCapture(false);
        self.debug.debug_scrollbar_dragging = false;
        self.form_scroll_drag_target = .none;
        self.stopFilesystemWorker();
        if (self.ws_client) |*client| {
            client.deinit();
            self.ws_client = null;
        }
        self.mount_control_ready = false;
        self.clearPendingSend();
        self.clearSessions();
        self.debug.debug_stream_enabled = false;
        self.debug.debug_stream_snapshot_pending = false;
        self.debug.debug_stream_snapshot_retry_at_ms = 0;
        self.debug.node_service_watch_enabled = false;
        self.debug.node_service_snapshot_pending = false;
        self.debug.node_service_snapshot_retry_at_ms = 0;
        self.session_attach_state = .unknown;
        self.resetFsrpcConnectionState();
        self.clearDebugStreamSnapshot();
        self.clearWorkspaceData();
        self.clearFilesystemData();
        self.clearFilesystemDirCache();
        self.clearTerminalState();
        self.clearTerminalTarget();
        self.clearNodeServiceReloadDiagnostics();
    }

    fn ensureAppLocalNodeBootstrap(self: *App, client: *ws_client_mod.WebSocketClient) !void {
        const profile_id = self.config.selectedProfileId();
        const node_name = try app_venom_host.buildAppLocalNodeName(self.allocator, profile_id);
        defer self.allocator.free(node_name);

        const active_token = self.config.getRoleToken(self.config.active_role);
        var bootstrap_token = active_token;
        var bootstrap_client = client;
        var used_admin_fallback = false;
        var admin_client_storage: ?ws_client_mod.WebSocketClient = null;
        defer if (admin_client_storage) |*admin_client| admin_client.deinit();

        var ensured = control_plane.ensureNode(
            self.allocator,
            client,
            &self.message_counter,
            node_name,
            null,
            APP_LOCAL_NODE_LEASE_TTL_MS,
        ) catch |primary_err| blk: {
            const admin_token = self.config.getRoleToken(.admin);
            if (admin_token.len == 0) return primary_err;
            if (std.mem.eql(u8, active_token, admin_token)) return primary_err;
            admin_client_storage = try ws_client_mod.WebSocketClient.init(
                self.allocator,
                self.config.server_url,
                admin_token,
            );
            try admin_client_storage.?.connect();
            try control_plane.ensureUnifiedV2Connection(self.allocator, &admin_client_storage.?, &self.message_counter);
            bootstrap_token = admin_token;
            bootstrap_client = &admin_client_storage.?;
            used_admin_fallback = true;
            break :blk try control_plane.ensureNode(
                self.allocator,
                &admin_client_storage.?,
                &self.message_counter,
                node_name,
                null,
                APP_LOCAL_NODE_LEASE_TTL_MS,
            );
        };
        defer ensured.deinit(self.allocator);

        self.startAppLocalVenomHost(
            bootstrap_client,
            bootstrap_token,
            ensured,
            APP_LOCAL_NODE_LEASE_TTL_MS,
        ) catch |start_err| {
            const admin_token = self.config.getRoleToken(.admin);
            if (admin_token.len == 0) return start_err;
            if (used_admin_fallback or std.mem.eql(u8, bootstrap_token, admin_token)) return start_err;
            if (admin_client_storage == null) {
                admin_client_storage = try ws_client_mod.WebSocketClient.init(
                    self.allocator,
                    self.config.server_url,
                    admin_token,
                );
                try admin_client_storage.?.connect();
                try control_plane.ensureUnifiedV2Connection(self.allocator, &admin_client_storage.?, &self.message_counter);
            }
            try self.startAppLocalVenomHost(
                &admin_client_storage.?,
                admin_token,
                ensured,
                APP_LOCAL_NODE_LEASE_TTL_MS,
            );
            bootstrap_token = admin_token;
            bootstrap_client = &admin_client_storage.?;
            used_admin_fallback = true;
        };

        if (self.config.appLocalNode(profile_id)) |existing| {
            if (std.mem.eql(u8, existing.node_name, ensured.node_name) and
                std.mem.eql(u8, existing.node_id, ensured.node_id) and
                std.mem.eql(u8, existing.node_secret, ensured.node_secret))
            {
                return;
            }
        }

        try self.config.setAppLocalNode(profile_id, ensured.node_name, ensured.node_id, ensured.node_secret);
        try self.config.save();
    }

    fn startAppLocalVenomHost(
        self: *App,
        client: *ws_client_mod.WebSocketClient,
        control_token: []const u8,
        ensured: control_plane.EnsuredNodeIdentity,
        lease_ttl_ms: u64,
    ) !void {
        if (self.app_local_venom_host) |*existing| {
            if (existing.matches(self.config.server_url, control_token, ensured)) return;
            existing.deinit();
            self.app_local_venom_host = null;
        }

        self.app_local_venom_host = try app_venom_host.AppVenomHost.init(
            self.allocator,
            self.config.server_url,
            control_token,
            ensured,
        );
        errdefer {
            if (self.app_local_venom_host) |*host| host.deinit();
            self.app_local_venom_host = null;
        }
        self.app_local_venom_host.?.bindSelf();
        try self.app_local_venom_host.?.bootstrap(client, &self.message_counter, lease_ttl_ms);
    }

    fn saveConfig(self: *App) !void {
        if (self.settings_panel.default_session.items.len == 0) {
            try self.settings_panel.default_session.appendSlice(self.allocator, "main");
        }
        try self.syncSettingsToConfig();
    }

    fn parseNodeServiceWatchReplayLimit(self: *App) usize {
        const trimmed = std.mem.trim(u8, self.debug.node_service_watch_replay_limit.items, " \t\r\n");
        if (trimmed.len == 0) return 25;
        const parsed = std.fmt.parseUnsigned(usize, trimmed, 10) catch return 25;
        return @min(parsed, 10_000);
    }

    fn subscribeNodeServiceEvents(self: *App, client: *ws_client_mod.WebSocketClient) void {
        _ = client;
        self.debug.node_service_watch_enabled = true;
        self.requestNodeServiceSnapshot(true);
    }

    fn subscribeNodeServiceEventsFromUi(self: *App) !void {
        const client = if (self.ws_client) |*value|
            value
        else
            return error.NotConnected;
        self.subscribeNodeServiceEvents(client);
        if (self.debug.node_service_watch_enabled) {
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
        self.debug.node_service_watch_enabled = false;
        self.debug.node_service_snapshot_pending = false;
        self.debug.node_service_snapshot_retry_at_ms = 0;
        try self.appendMessage("system", "Node service feed paused", null);
    }

    fn sendChatMessageText(self: *App, text: []const u8) !void {
        if (text.len == 0) return;
        std.log.info("[GUI] sendChatMessageText: text_len={d} connected={}", .{ text.len, self.ws_client != null });
        if (self.chat.awaiting_reply) {
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
        const attach_project_id = self.preferredAttachWorkspaceId();
        std.log.info(
            "[GUI] sendChatMessageText: session={s} workspace={s} attach_state={s}",
            .{ session_key, attach_project_id orelse "(none)", @tagName(self.session_attach_state) },
        );
        if (self.session_attach_state == .err) {
            const detail = self.ws.workspace_last_error orelse "Sandbox runtime is unavailable for this session.";
            try self.appendMessage("system", detail, null);
            return error.RemoteError;
        }
        if (self.session_attach_state != .ready) {
            const msg = "Chat is disabled until you attach a Spiderweb session from Workspace Overview. External workers can keep using the mounted workspace without live chat.";
            self.setWorkspaceError(msg);
            try self.appendMessage("system", msg, null);
            return error.ProjectIdRequired;
        }

        const user_msg_id = try self.nextMessageId("msg");
        const appended_user_msg_id = try self.appendMessageWithIdForSession(session_key, "user", text, .sending, user_msg_id);
        defer self.allocator.free(appended_user_msg_id);
        self.allocator.free(user_msg_id);
        try self.setPendingSend(self.allocator, appended_user_msg_id, session_key);

        const request_id = try self.nextMessageId("send");
        defer self.allocator.free(request_id);
        if (self.chat.pending_send_request_id) |value| {
            self.allocator.free(value);
            self.chat.pending_send_request_id = null;
        }
        self.chat.pending_send_request_id = try self.allocator.dupe(u8, request_id);
        self.chat.awaiting_reply = true;
        std.log.info(
            "[GUI] sendChatMessageText: submit request_id={s} session={s}",
            .{ request_id, session_key },
        );

        const submit = self.submitChatJobViaFsrpc(client, text) catch |err| {
            std.log.err("[GUI] sendChatMessageText: fsrpc submit failed: {s}", .{@errorName(err)});
            const remote_detail = if (err == error.RemoteError)
                (control_plane.lastRemoteError() orelse (self.fs.fsrpc_last_remote_error orelse @errorName(err)))
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
            if (self.chat.pending_send_message_id) |message_id| {
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
        if (self.chat.pending_send_job_id) |value| {
            self.allocator.free(value);
            self.chat.pending_send_job_id = null;
        }
        if (self.chat.pending_send_jobs_root) |value| {
            self.allocator.free(value);
            self.chat.pending_send_jobs_root = null;
        }
        if (self.chat.pending_send_correlation_id) |value| {
            self.allocator.free(value);
            self.chat.pending_send_correlation_id = null;
        }
        self.chat.pending_send_job_id = submit.job_id;
        self.chat.pending_send_jobs_root = submit.jobs_root;
        self.chat.pending_send_thoughts_root = submit.thoughts_root;
        self.chat.pending_send_correlation_id = submit.correlation_id;
    }

    fn nextFsrpcTag(self: *App) u32 {
        if (self.ws_client) |*client| {
            return client.nextAcheronTag();
        }
        const tag = self.fs.next_fsrpc_tag;
        self.fs.next_fsrpc_tag +%= 1;
        if (self.fs.next_fsrpc_tag == 0) self.fs.next_fsrpc_tag = 1;
        return tag;
    }

    fn nextFsrpcFid(self: *App) u32 {
        if (self.ws_client) |*client| {
            return client.nextAcheronFid();
        }
        const fid = self.fs.next_fsrpc_fid;
        self.fs.next_fsrpc_fid +%= 1;
        if (self.fs.next_fsrpc_fid == 0 or self.fs.next_fsrpc_fid == 1) self.fs.next_fsrpc_fid = 2;
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

    fn fsrpcVerboseLogsEnabled(self: *const App) bool {
        return self.settings_panel.ws_verbose_logs;
    }

    fn logFsrpcVerbose(self: *const App, comptime fmt: []const u8, args: anytype) void {
        if (!self.fsrpcVerboseLogsEnabled()) return;
        std.log.info(fmt, args);
    }

    fn sendAndAwaitFsrpc(
        self: *App,
        client: *ws_client_mod.WebSocketClient,
        request_json: []const u8,
        tag: u32,
        timeout_ms: u32,
    ) !FsrpcEnvelope {
        const req_type = fsrpcRequestTypeForLog(request_json);
        self.logFsrpcVerbose(
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
        self.logFsrpcVerbose(
            "[GUI][FSRPC] recv type={s} tag={d} bytes={d} alive={}",
            .{ req_type, tag, raw.len, client.isAlive() },
        );
        if (!client.isAlive()) {
            self.fs.fsrpc_ready = false;
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

        // Detect the POSIX enoent code that the 9P layer sends for missing paths.
        // This is a normal "file not found" condition; callers already handle it
        // via `catch`. Log at debug so the console stays quiet, and return a
        // dedicated error so callers can distinguish it from real protocol errors.
        const is_enoent = blk: {
            if (obj.get("error")) |ev| {
                if (ev == .object) {
                    if (ev.object.get("code")) |cv| {
                        if (cv == .string and std.mem.eql(u8, cv.string, "enoent")) break :blk true;
                    }
                }
            }
            break :blk false;
        };

        if (is_enoent) {
            if (detail) |value| {
                defer self.allocator.free(value);
                std.log.debug("[GUI][FSRPC] path not found: {s}", .{value});
            } else {
                std.log.debug("[GUI][FSRPC] path not found (enoent)", .{});
            }
            return error.FileNotFound;
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
        if (self.fs.fsrpc_ready) {
            self.logFsrpcVerbose("[GUI][FSRPC] bootstrap skipped: already ready", .{});
            return;
        }

        self.logFsrpcVerbose("[GUI][FSRPC] bootstrap start", .{});

        try control_plane.ensureUnifiedV2Connection(
            self.allocator,
            client,
            &self.message_counter,
        );
        self.logFsrpcVerbose("[GUI][FSRPC] unified-v2 ready", .{});

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
        self.logFsrpcVerbose("[GUI][FSRPC] version ok tag={d}", .{version_tag});

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
        self.fs.fsrpc_ready = true;
        self.logFsrpcVerbose("[GUI][FSRPC] bootstrap ready attach_tag={d}", .{attach_tag});
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
        self.logFsrpcVerbose("[GUI][FSRPC] submitChatJobViaFsrpc start text_len={d}", .{text.len});
        try self.fsrpcBootstrapGui(client);
        var chat_paths = try self.discoverScopedChatBindingPathsGui(client);
        defer chat_paths.deinit(self.allocator);

        const input_fid = self.nextFsrpcFid();
        defer self.fsrpcClunkBestEffort(client, input_fid);
        self.logFsrpcVerbose("[GUI][FSRPC] chat input fid={d}", .{input_fid});
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
        self.logFsrpcVerbose("[GUI][FSRPC] chat input open ok fid={d}", .{input_fid});

        const encoded = try encodeDataB64(self.allocator, text);
        defer self.allocator.free(encoded);
        var generated_write_request_id: ?[]const u8 = null;
        defer if (generated_write_request_id) |value| self.allocator.free(value);
        const write_request_id = if (self.chat.pending_send_request_id) |pending|
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
        self.logFsrpcVerbose(
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

    fn resolveFilesystemPathStatGui(
        self: *App,
        client: *ws_client_mod.WebSocketClient,
        path: []const u8,
    ) !FilesystemStatInfo {
        var snapshot = try self.mountAttachSnapshotGui(client, path, 0);
        defer snapshot.deinit(self.allocator);
        const root_info = try self.mountSnapshotRootInfo(snapshot.parsed.value.object);
        return root_info.info;
    }

    fn readFsPathTextGui(self: *App, client: *ws_client_mod.WebSocketClient, path: []const u8) ![]u8 {
        return self.mountReadAllTextGui(client, path);
    }

    fn writeFsPathTextGui(self: *App, client: *ws_client_mod.WebSocketClient, path: []const u8, content: []const u8) !void {
        try self.mountWriteAllTextGui(client, path, content);
    }

    const MountSnapshotRootInfo = struct {
        root_node_id: u64,
        info: FilesystemStatInfo,
    };

    fn sendMountControlRequestGui(
        self: *App,
        client: *ws_client_mod.WebSocketClient,
        control_type: []const u8,
        payload_json: []const u8,
        timeout_ms: i64,
    ) !unified_v2_client.JsonEnvelope {
        unified_v2_client.clearLastRemoteError();
        try self.ensureMountControlReadyGui(client);
        const request_id = try unified_v2_client.nextRequestId(self.allocator, &self.message_counter, "mount");
        defer self.allocator.free(request_id);
        return unified_v2_client.sendControlRequest(
            self.allocator,
            client,
            control_type,
            request_id,
            payload_json,
            timeout_ms,
        ) catch |err| {
            if (err == error.ConnectionClosed) self.mount_control_ready = false;
            if (err == error.RemoteError) {
                if (unified_v2_client.lastRemoteError()) |remote| self.setFsrpcRemoteError(remote);
            }
            return err;
        };
    }

    fn ensureMountControlReadyGui(self: *App, client: *ws_client_mod.WebSocketClient) !void {
        if (self.mount_control_ready and client.isAlive()) return;
        try control_plane.ensureUnifiedV2Connection(self.allocator, client, &self.message_counter);
        self.mount_control_ready = true;
    }

    fn buildPackageManagerIdPayload(self: *App, package_id: []const u8) ![]u8 {
        const escaped_id = try jsonEscape(self.allocator, package_id);
        defer self.allocator.free(escaped_id);
        return std.fmt.allocPrint(self.allocator, "{{\"venom_id\":\"{s}\"}}", .{escaped_id});
    }

    fn controlPayloadObjectGui(self: *App, envelope: *unified_v2_client.JsonEnvelope) !std.json.ObjectMap {
        _ = self;
        return unified_v2_client.extractPayloadObject(envelope);
    }

    fn mountAttachSnapshotGui(
        self: *App,
        client: *ws_client_mod.WebSocketClient,
        path: []const u8,
        depth: u32,
    ) !unified_v2_client.JsonEnvelope {
        const escaped_path = try jsonEscape(self.allocator, path);
        defer self.allocator.free(escaped_path);
        const payload = try std.fmt.allocPrint(
            self.allocator,
            "{{\"path\":\"{s}\",\"depth\":{d}}}",
            .{ escaped_path, depth },
        );
        defer self.allocator.free(payload);
        return self.sendMountControlRequestGui(client, "control.mount_attach", payload, FSRPC_DEFAULT_TIMEOUT_MS);
    }

    fn mountNodeKind(kind_label: []const u8) FilesystemEntryKind {
        if (std.mem.indexOf(u8, kind_label, "directory") != null) return .directory;
        if (std.mem.indexOf(u8, kind_label, "file") != null) return .file;
        if (std.mem.eql(u8, kind_label, "export_root")) return .directory;
        if (std.mem.eql(u8, kind_label, "dir")) return .directory;
        if (std.mem.eql(u8, kind_label, "file")) return .file;
        return .unknown;
    }

    fn mountSnapshotRootInfo(
        self: *App,
        root: std.json.ObjectMap,
    ) !MountSnapshotRootInfo {
        _ = self;
        const payload_value = root.get("payload") orelse return error.InvalidResponse;
        if (payload_value != .object) return error.InvalidResponse;
        const payload = payload_value.object;
        const root_node_id = jsonObjectFirstU64(payload, &.{"root_node_id"}) orelse return error.InvalidResponse;
        const nodes_value = payload.get("nodes") orelse return error.InvalidResponse;
        if (nodes_value != .array) return error.InvalidResponse;

        for (nodes_value.array.items) |node_value| {
            if (node_value != .object) continue;
            const node_obj = node_value.object;
            const node_id = jsonObjectFirstU64(node_obj, &.{"id"}) orelse continue;
            if (node_id != root_node_id) continue;
            const kind_label = jsonObjectFirstString(node_obj, &.{"kind"}) orelse return error.InvalidResponse;
            return .{
                .root_node_id = root_node_id,
                .info = .{
                    .kind = mountNodeKind(kind_label),
                    .size_bytes = jsonObjectFirstU64(node_obj, &.{ "size", "size_bytes", "bytes", "length", "len" }),
                    .modified_unix_ms = null,
                },
            };
        }
        return error.InvalidResponse;
    }

    fn buildMountDirectoryListingText(
        self: *App,
        root_node_id: u64,
        root: std.json.ObjectMap,
    ) ![]u8 {
        const payload = root.get("payload") orelse return error.InvalidResponse;
        if (payload != .object) return error.InvalidResponse;
        const nodes_value = payload.object.get("nodes") orelse return error.InvalidResponse;
        if (nodes_value != .array) return error.InvalidResponse;

        var out = std.ArrayListUnmanaged(u8){};
        defer out.deinit(self.allocator);
        var first = true;
        for (nodes_value.array.items) |node_value| {
            if (node_value != .object) continue;
            const node_obj = node_value.object;
            const parent_id = jsonObjectFirstU64(node_obj, &.{"parent_id"}) orelse continue;
            if (parent_id != root_node_id) continue;
            const name = jsonObjectFirstString(node_obj, &.{"name"}) orelse continue;
            if (!first) try out.append(self.allocator, '\n');
            first = false;
            try out.appendSlice(self.allocator, name);
        }
        return out.toOwnedSlice(self.allocator);
    }

    fn mountReadAllTextGui(self: *App, client: *ws_client_mod.WebSocketClient, path: []const u8) ![]u8 {
        var out = std.ArrayListUnmanaged(u8){};
        errdefer out.deinit(self.allocator);
        var offset: u64 = 0;
        while (true) {
            const escaped_path = try jsonEscape(self.allocator, path);
            defer self.allocator.free(escaped_path);
            const payload = try std.fmt.allocPrint(
                self.allocator,
                "{{\"path\":\"{s}\",\"offset\":{d},\"length\":{d}}}",
                .{ escaped_path, offset, FSRPC_READ_CHUNK_BYTES },
            );
            defer self.allocator.free(payload);

            var envelope = try self.sendMountControlRequestGui(client, "control.mount_file_read", payload, FSRPC_DEFAULT_TIMEOUT_MS);
            defer envelope.deinit(self.allocator);
            const response = try self.controlPayloadObjectGui(&envelope);
            const data_b64 = jsonObjectFirstString(response, &.{"data_b64"}) orelse return error.InvalidResponse;
            const eof = jsonObjectFirstBool(response, &.{"eof"}) orelse false;

            const decoded_len = std.base64.standard.Decoder.calcSizeForSlice(data_b64) catch return error.InvalidResponse;
            const decoded = try self.allocator.alloc(u8, decoded_len);
            defer self.allocator.free(decoded);
            _ = std.base64.standard.Decoder.decode(decoded, data_b64) catch return error.InvalidResponse;

            if (decoded.len != 0) {
                if (out.items.len + decoded.len > FSRPC_READ_MAX_TOTAL_BYTES) return error.ResponseTooLarge;
                try out.appendSlice(self.allocator, decoded);
                offset += @as(u64, @intCast(decoded.len));
            }
            if (eof or decoded.len == 0 or decoded.len < @as(usize, FSRPC_READ_CHUNK_BYTES)) break;
        }
        return out.toOwnedSlice(self.allocator);
    }

    fn mountWriteAllTextGui(self: *App, client: *ws_client_mod.WebSocketClient, path: []const u8, content: []const u8) !void {
        const escaped_path = try jsonEscape(self.allocator, path);
        defer self.allocator.free(escaped_path);
        const encoded = try encodeDataB64(self.allocator, content);
        defer self.allocator.free(encoded);
        const payload = try std.fmt.allocPrint(
            self.allocator,
            "{{\"path\":\"{s}\",\"offset\":0,\"truncate_to_size\":{d},\"data_b64\":\"{s}\"}}",
            .{ escaped_path, content.len, encoded },
        );
        defer self.allocator.free(payload);

        var envelope = try self.sendMountControlRequestGui(client, "control.mount_file_write", payload, FSRPC_CHAT_WRITE_TIMEOUT_MS);
        defer envelope.deinit(self.allocator);
        _ = try self.controlPayloadObjectGui(&envelope);
    }

    fn jsonObjectFirstString(obj: std.json.ObjectMap, keys: []const []const u8) ?[]const u8 {
        for (keys) |key| {
            const value = obj.get(key) orelse continue;
            if (value == .string) return value.string;
        }
        return null;
    }

    fn jsonObjectFirstBool(obj: std.json.ObjectMap, keys: []const []const u8) ?bool {
        for (keys) |key| {
            const value = obj.get(key) orelse continue;
            if (value == .bool) return value.bool;
        }
        return null;
    }

    fn buildPackagesControlPathGui(self: *App, leaf: []const u8) ![]u8 {
        return self.joinFilesystemPath(PACKAGES_CONTROL_ROOT, leaf);
    }

    fn writePackageControlAndReadResultGui(
        self: *App,
        client: *ws_client_mod.WebSocketClient,
        control_name: []const u8,
        payload: []const u8,
    ) ![]u8 {
        const control_dir = try self.buildPackagesControlPathGui("control");
        defer self.allocator.free(control_dir);
        const control_path = try self.joinFilesystemPath(control_dir, control_name);
        defer self.allocator.free(control_path);
        try self.writeFsPathTextGui(client, control_path, payload);

        const result_path = try self.buildPackagesControlPathGui("result.json");
        defer self.allocator.free(result_path);
        return self.readFsPathTextGui(client, result_path);
    }

    fn setPackageManagerRemoteErrorFromResult(self: *App, root: std.json.ObjectMap, fallback: []const u8) void {
        if (root.get("error")) |error_value| {
            if (error_value == .object) {
                const code = jsonObjectFirstString(error_value.object, &.{"code"}) orelse "error";
                const message = jsonObjectFirstString(error_value.object, &.{"message"}) orelse fallback;
                const formatted = std.fmt.allocPrint(self.allocator, "{s} [{s}]", .{ message, code }) catch null;
                defer if (formatted) |value| self.allocator.free(value);
                if (formatted) |value| {
                    self.setPackageManagerModalError(value);
                    return;
                }
            }
        }
        self.setPackageManagerModalError(fallback);
    }

    fn refreshPackageManagerPackages(self: *App) !void {
        const client = if (self.ws_client) |*value| value else return error.NotConnected;
        const selected_package_id = if (self.selectedPackageManagerEntry()) |entry|
            try self.allocator.dupe(u8, entry.package_id)
        else
            null;
        defer if (selected_package_id) |value| self.allocator.free(value);
        errdefer self.clearPackageManagerPackages();

        const result_json = try self.writePackageControlAndReadResultGui(client, "list.json", "{}");
        defer self.allocator.free(result_json);

        var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, result_json, .{});
        defer parsed.deinit();
        if (parsed.value != .object) return error.InvalidResponse;
        const root = parsed.value.object;
        if (jsonObjectFirstBool(root, &.{"ok"}) != true) {
            self.clearPackageManagerPackages();
            self.setPackageManagerRemoteErrorFromResult(root, "Package list failed.");
            return error.RemoteError;
        }
        const result_value = root.get("result") orelse return error.InvalidResponse;
        if (result_value != .object) return error.InvalidResponse;
        const packages_value = result_value.object.get("packages") orelse return error.InvalidResponse;
        if (packages_value != .array) return error.InvalidResponse;

        var next_packages: std.ArrayListUnmanaged(PackageManagerEntry) = .{};
        errdefer {
            for (next_packages.items) |*entry| entry.deinit(self.allocator);
            next_packages.deinit(self.allocator);
        }

        for (packages_value.array.items) |item| {
            if (item != .object) continue;
            const obj = item.object;
            try next_packages.append(self.allocator, .{
                .package_id = try self.allocator.dupe(u8, jsonObjectFirstString(obj, &.{ "package_id", "venom_id" }) orelse continue),
                .kind = try self.allocator.dupe(u8, jsonObjectFirstString(obj, &.{"kind"}) orelse "(unknown)"),
                .version = try self.allocator.dupe(
                    u8,
                    jsonObjectFirstString(obj, &.{ "active_release_version", "release_version", "version" }) orelse "1",
                ),
                .runtime_kind = try self.allocator.dupe(u8, jsonObjectFirstString(obj, &.{"runtime_kind"}) orelse "native"),
                .enabled = jsonObjectFirstBool(obj, &.{"enabled"}) orelse true,
                .active_release_version = if (jsonObjectFirstString(obj, &.{"active_release_version"})) |value|
                    try self.allocator.dupe(u8, value)
                else
                    null,
                .latest_release_version = if (jsonObjectFirstString(obj, &.{"latest_release_version"})) |value|
                    try self.allocator.dupe(u8, value)
                else
                    null,
                .latest_release_channel = if (jsonObjectFirstString(obj, &.{"latest_release_channel"})) |value|
                    try self.allocator.dupe(u8, value)
                else
                    null,
                .effective_channel = if (jsonObjectFirstString(obj, &.{"effective_channel"})) |value|
                    try self.allocator.dupe(u8, value)
                else
                    null,
                .channel_override = if (jsonObjectFirstString(obj, &.{"channel_override"})) |value|
                    try self.allocator.dupe(u8, value)
                else
                    null,
                .installed_release_count = @intCast(jsonObjectFirstU64(obj, &.{"installed_release_count"}) orelse 0),
                .release_history_count = @intCast(jsonObjectFirstU64(obj, &.{"release_history_count"}) orelse 0),
                .update_available = jsonObjectFirstBool(obj, &.{"update_available"}) orelse false,
                .last_release_action = if (jsonObjectFirstString(obj, &.{"last_release_action"})) |value|
                    try self.allocator.dupe(u8, value)
                else
                    null,
                .last_release_version = if (jsonObjectFirstString(obj, &.{"last_release_version"})) |value|
                    try self.allocator.dupe(u8, value)
                else
                    null,
                .help_md = if (jsonObjectFirstString(obj, &.{"help_md"})) |value|
                    try self.allocator.dupe(u8, value)
                else
                    null,
            });
        }

        self.clearPackageManagerPackages();
        self.package_manager_packages = next_packages;
        self.package_manager_selected_index = 0;
        if (selected_package_id) |wanted| {
            for (self.package_manager_packages.items, 0..) |entry, idx| {
                if (std.mem.eql(u8, entry.package_id, wanted)) {
                    self.package_manager_selected_index = idx;
                    break;
                }
            }
        }
        self.clearPackageManagerModalError();
        self.syncCompletedOnboardingWorkflowsFromLiveState();
    }

    fn runPackageManagerOperation(
        self: *App,
        control_name: []const u8,
        payload: []const u8,
        success_notice: []const u8,
    ) !void {
        const client = if (self.ws_client) |*value| value else return error.NotConnected;
        const result_json = try self.writePackageControlAndReadResultGui(client, control_name, payload);
        defer self.allocator.free(result_json);

        var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, result_json, .{});
        defer parsed.deinit();
        if (parsed.value != .object) return error.InvalidResponse;
        const root = parsed.value.object;
        if (jsonObjectFirstBool(root, &.{"ok"}) != true) {
            if (root.get("error")) |error_value| {
                if (error_value == .object) {
                    const code = jsonObjectFirstString(error_value.object, &.{"code"}) orelse "error";
                    const message = jsonObjectFirstString(error_value.object, &.{"message"}) orelse "package operation failed";
                    const formatted = try std.fmt.allocPrint(self.allocator, "{s} [{s}]", .{ message, code });
                    defer self.allocator.free(formatted);
                    self.setPackageManagerModalError(formatted);
                }
            }
            return error.RemoteError;
        }

        try self.refreshPackageManagerPackages();
        self.setPackageManagerModalNotice(success_notice);
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
                .workspace_id = self.selectedWorkspaceId(),
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

        const global_jobs_path = try std.fmt.allocPrint(self.allocator, "/.spiderweb/venoms/jobs/{s}/{s}", .{ job_id, leaf });
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

        if (self.chat.pending_send_last_thought_text) |previous| {
            if (std.mem.eql(u8, previous, thought)) return;
            self.allocator.free(previous);
            self.chat.pending_send_last_thought_text = null;
        }
        self.chat.pending_send_last_thought_text = try self.allocator.dupe(u8, thought);

        if (self.chat.pending_send_thought_message_id) |message_id| {
            if (self.findMessageIndex(session_key, message_id)) |idx| {
                try self.setMessageContentByIndex(session_key, idx, thought);
                return;
            }
            self.allocator.free(message_id);
            self.chat.pending_send_thought_message_id = null;
        }

        const appended_id = try self.appendMessageWithIdForSession(session_key, "thought", thought, null, "");
        self.chat.pending_send_thought_message_id = @constCast(appended_id);
    }

    fn tryResumePendingSendJob(self: *App) !bool {
        const job_id = self.chat.pending_send_job_id orelse return false;
        const jobs_root = self.chat.pending_send_jobs_root orelse "/global/jobs";
        const client = if (self.ws_client) |*value| value else return false;
        if (!self.chat.pending_send_resume_notified) return false;
        const session_key = if (self.chat.pending_send_session_key) |value|
            value
        else
            try self.currentSessionOrDefault();

        const now_ms = std.time.milliTimestamp();
        if (self.chat.pending_send_last_resume_attempt_ms != 0 and now_ms - self.chat.pending_send_last_resume_attempt_ms < 1_500) {
            return false;
        }
        self.chat.pending_send_last_resume_attempt_ms = now_ms;
        std.log.info("[GUI] tryResumePendingSendJob: job_id={s}", .{job_id});

        try self.fsrpcBootstrapGui(client);
        var status = try self.readJobStatusGui(client, jobs_root, job_id);
        defer status.deinit(self.allocator);

        const maybe_log = self.readJobArtifactTextGui(client, jobs_root, job_id, "log.txt") catch null;
        defer if (maybe_log) |value| self.allocator.free(value);

        if (self.chat.pending_send_thoughts_root) |thoughts_root| {
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
            if (self.chat.pending_send_message_id) |message_id| {
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

        if (self.chat.pending_send_message_id) |message_id| {
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
        return false;
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
        if (self.chat.pending_send_request_id) |value| {
            allocator.free(value);
            self.chat.pending_send_request_id = null;
        }
        if (self.chat.pending_send_message_id) |value| allocator.free(value);
        if (self.chat.pending_send_session_key) |value| allocator.free(value);
        if (self.chat.pending_send_job_id) |value| {
            allocator.free(value);
            self.chat.pending_send_job_id = null;
        }
        if (self.chat.pending_send_jobs_root) |value| {
            allocator.free(value);
            self.chat.pending_send_jobs_root = null;
        }
        if (self.chat.pending_send_thoughts_root) |value| {
            allocator.free(value);
            self.chat.pending_send_thoughts_root = null;
        }
        if (self.chat.pending_send_correlation_id) |value| {
            allocator.free(value);
            self.chat.pending_send_correlation_id = null;
        }
        self.clearPendingThoughtMessage();
        if (self.chat.pending_send_last_thought_text) |value| {
            allocator.free(value);
            self.chat.pending_send_last_thought_text = null;
        }
        self.chat.pending_send_message_id = try allocator.dupe(u8, message_id);
        self.chat.pending_send_session_key = try allocator.dupe(u8, session_key);
        self.chat.pending_send_resume_notified = false;
        self.chat.pending_send_last_resume_attempt_ms = 0;
        self.chat.pending_send_started_at_ms = std.time.milliTimestamp();
    }

    fn clearPendingSend(self: *App) void {
        self.clearPendingThoughtMessage();
        if (self.chat.pending_send_request_id) |value| {
            self.allocator.free(value);
            for (self.chat.session_messages.items) |*state| {
                if (state.streaming_request_id) |stream_request_id| {
                    if (std.mem.eql(u8, value, stream_request_id)) {
                        self.clearSessionStreamingState(state);
                    }
                }
            }
            self.chat.pending_send_request_id = null;
        }
        if (self.chat.pending_send_message_id) |value| {
            self.allocator.free(value);
            self.chat.pending_send_message_id = null;
        }
        if (self.chat.pending_send_session_key) |value| {
            self.allocator.free(value);
            self.chat.pending_send_session_key = null;
        }
        if (self.chat.pending_send_job_id) |value| {
            self.allocator.free(value);
            self.chat.pending_send_job_id = null;
        }
        if (self.chat.pending_send_jobs_root) |value| {
            self.allocator.free(value);
            self.chat.pending_send_jobs_root = null;
        }
        if (self.chat.pending_send_thoughts_root) |value| {
            self.allocator.free(value);
            self.chat.pending_send_thoughts_root = null;
        }
        if (self.chat.pending_send_correlation_id) |value| {
            self.allocator.free(value);
            self.chat.pending_send_correlation_id = null;
        }
        self.clearPendingThoughtMessage();
        if (self.chat.pending_send_last_thought_text) |value| {
            self.allocator.free(value);
            self.chat.pending_send_last_thought_text = null;
        }
        self.chat.pending_send_resume_notified = false;
        self.chat.pending_send_last_resume_attempt_ms = 0;
        self.chat.pending_send_started_at_ms = 0;
        self.chat.awaiting_reply = false;
    }

    fn currentSessionOrDefault(self: *App) ![]const u8 {
        self.sanitizeCurrentSessionSelection();

        if (self.chat.current_session_key) |current| {
            if (isValidSessionKeyForAttach(current)) return current;
            try self.ensureSessionExists("main", "Main");
            return self.chat.current_session_key.?;
        }
        if (self.chat.chat_sessions.items.len > 0) {
            const fallback = self.chat.chat_sessions.items[0].key;
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

        if (self.chat.current_session_key) |key| {
            if (self.findSessionMessageState(key)) |state| {
                return state.messages.items;
            }
        }
        if (self.chat.chat_sessions.items.len > 0) {
            if (self.findSessionMessageState(self.chat.chat_sessions.items[0].key)) |state| {
                return state.messages.items;
            }
        }
        return &[_]ChatMessage{};
    }

    fn setMessageFailed(self: *App, message_id: []const u8) !void {
        for (self.chat.session_messages.items) |*state| {
            for (state.messages.items) |*msg| {
                if (std.mem.eql(u8, msg.id, message_id)) {
                    msg.local_state = .failed;
                    return;
                }
            }
        }
    }

    fn setMessageState(self: *App, message_id: []const u8, state: ?ChatMessageState) !void {
        for (self.chat.session_messages.items) |*session_state| {
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
            self.debug.node_service_latest_reload_diag = diag;
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
            if (self.chat.pending_send_request_id) |pending| {
                if (std.mem.eql(u8, pending, request)) {
                    if (self.chat.pending_send_session_key) |key| break :blk key;
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

            if (self.chat.pending_send_request_id) |pending| {
                if (std.mem.eql(u8, pending, request)) {
                    if (self.chat.pending_send_message_id) |msg_id| {
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
        for (self.chat.session_messages.items) |*state| {
            if (std.mem.eql(u8, state.key, key)) return state;
        }
        return null;
    }

    fn getSessionMessageState(self: *App, key: []const u8) !*SessionMessageState {
        if (self.findSessionMessageState(key)) |state| return state;
        const key_copy = try self.allocator.dupe(u8, key);
        try self.chat.session_messages.append(self.allocator, .{
            .key = key_copy,
            .messages = .empty,
        });
        return &self.chat.session_messages.items[self.chat.session_messages.items.len - 1];
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
        if (self.chat.pending_send_thought_message_id) |message_id| {
            if (self.chat.pending_send_session_key) |session_key| {
                self.removeMessageById(session_key, message_id);
            }
            self.allocator.free(message_id);
            self.chat.pending_send_thought_message_id = null;
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
            if (self.chat.pending_send_message_id) |pending_message_id| {
                if (std.mem.eql(u8, pending_message_id, oldest.id)) {
                    self.allocator.free(pending_message_id);
                    self.chat.pending_send_message_id = null;
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
        for (self.chat.session_messages.items) |*state| {
            self.clearSessionStreamingState(state);
            for (state.messages.items) |*msg| {
                self.freeMessage(msg);
            }
            state.messages.clearRetainingCapacity();
        }
    }

    fn clearSessions(self: *App) void {
        self.clearAllMessages();

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

    fn clearDebugEvents(self: *App) void {
        for (self.debug.debug_events.items) |*entry| {
            entry.deinit(self.allocator);
        }
        self.debug.debug_events.clearRetainingCapacity();
        self.debug.debug_folded_blocks.clearRetainingCapacity();
        self.debug.debug_event_fingerprint_set.clearRetainingCapacity();
        self.debug.debug_event_fingerprint_count = 0;
        self.debug.debug_event_fingerprint_next = 0;
        self.debug.debug_fold_revision +%= 1;
        if (self.debug.debug_fold_revision == 0) self.debug.debug_fold_revision = 1;
        self.debug.debug_next_event_id = 1;
        self.debug.debug_selected_index = null;
        self.clearSelectedNodeServiceEventCache();
        self.debug.node_service_diff_base_index = null;
        self.clearNodeServiceReloadDiagnostics();
        self.clearNodeServiceDiffPreview();
        self.bumpDebugEventsRevision();
    }

    fn bumpDebugEventsRevision(self: *App) void {
        self.debug.debug_events_revision +%= 1;
        if (self.debug.debug_events_revision == 0) self.debug.debug_events_revision = 1;
        self.debug.debug_filter_cache_valid = false;
    }

    fn clearDebugStreamSnapshot(self: *App) void {
        if (self.debug.debug_stream_snapshot) |value| {
            self.allocator.free(value);
            self.debug.debug_stream_snapshot = null;
        }
    }

    fn mergeDebugStreamSnapshot(self: *App, content: []const u8) !void {
        if (self.debug.debug_stream_snapshot) |previous| {
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
        if (self.debug.debug_stream_snapshot) |previous| self.allocator.free(previous);
        self.debug.debug_stream_snapshot = snapshot_copy;
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

        const node_filter = std.mem.trim(u8, self.debug.node_service_watch_filter.items, " \t\r\n");
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
        if (self.debug.node_service_latest_reload_diag) |value| {
            self.allocator.free(value);
            self.debug.node_service_latest_reload_diag = null;
        }
    }

    fn clearNodeServiceDiffPreview(self: *App) void {
        if (self.debug.node_service_diff_preview) |value| {
            self.allocator.free(value);
            self.debug.node_service_diff_preview = null;
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
        if (self.debug.debug_event_fingerprint_set.contains(fingerprint)) {
            return false;
        }

        if (self.debug.debug_event_fingerprint_count == DEBUG_EVENT_DEDUPE_WINDOW) {
            const evicted = self.debug.debug_event_fingerprint_ring[self.debug.debug_event_fingerprint_next];
            _ = self.debug.debug_event_fingerprint_set.remove(evicted);
        } else {
            self.debug.debug_event_fingerprint_count += 1;
        }

        self.debug.debug_event_fingerprint_ring[self.debug.debug_event_fingerprint_next] = fingerprint;
        self.debug.debug_event_fingerprint_next = (self.debug.debug_event_fingerprint_next + 1) % DEBUG_EVENT_DEDUPE_WINDOW;
        self.debug.debug_event_fingerprint_set.put(self.allocator, fingerprint, {}) catch {
            return true;
        };
        return true;
    }

    fn appendDebugEvent(self: *App, timestamp_ms: i64, category: []const u8, correlation_id: ?[]const u8, payload_json: []const u8) !void {
        const fingerprint = debugEventFingerprint(timestamp_ms, category, correlation_id, payload_json);
        if (!self.rememberDebugEventFingerprint(fingerprint)) return;

        while (self.debug.debug_events.items.len >= MAX_DEBUG_EVENTS) {
            var removed = self.debug.debug_events.orderedRemove(0);
            self.pruneDebugFoldStateForEvent(removed.id);
            removed.deinit(self.allocator);
            if (self.debug.node_service_diff_base_index) |idx| {
                if (idx == 0) {
                    self.debug.node_service_diff_base_index = null;
                    self.clearNodeServiceDiffPreview();
                } else {
                    self.debug.node_service_diff_base_index = idx - 1;
                }
            }
            if (self.debug.debug_selected_index) |idx| {
                if (idx == 0) {
                    self.debug.debug_selected_index = null;
                    self.clearSelectedNodeServiceEventCache();
                } else {
                    self.debug.debug_selected_index = idx - 1;
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

        const event_id = self.debug.debug_next_event_id;
        self.debug.debug_next_event_id +%= 1;
        if (self.debug.debug_next_event_id == 0) self.debug.debug_next_event_id = 1;

        try self.debug.debug_events.append(self.allocator, .{
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
        if (self.debug.debug_filter_cache_valid and
            self.debug.debug_filter_cache_query_hash == query_hash and
            self.debug.debug_filter_cache_query_len == filter_text.len and
            self.debug.debug_filter_cache_events_revision == self.debug.debug_events_revision)
        {
            return self.debug.debug_filtered_indices.items;
        }

        self.debug.debug_filtered_indices.clearRetainingCapacity();
        self.debug.debug_filtered_indices.ensureTotalCapacity(self.allocator, self.debug.debug_events.items.len) catch {
            self.debug.debug_filter_cache_valid = false;
            return self.debug.debug_filtered_indices.items;
        };

        if (filter_text.len == 0) {
            for (self.debug.debug_events.items, 0..) |_, idx| {
                const value: u32 = @intCast(idx);
                self.debug.debug_filtered_indices.appendAssumeCapacity(value);
            }
        } else {
            for (self.debug.debug_events.items, 0..) |*entry, idx| {
                if (!self.debugEventMatchesFilter(entry, filter_text)) continue;
                const value: u32 = @intCast(idx);
                self.debug.debug_filtered_indices.appendAssumeCapacity(value);
            }
        }

        self.debug.debug_filter_cache_query_hash = query_hash;
        self.debug.debug_filter_cache_query_len = filter_text.len;
        self.debug.debug_filter_cache_events_revision = self.debug.debug_events_revision;
        self.debug.debug_filter_cache_valid = true;
        return self.debug.debug_filtered_indices.items;
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
        if (filter_text.len == 0) return self.debug.debug_events.items.len;
        var total: usize = 0;
        for (self.debug.debug_events.items) |*entry| {
            if (self.debugEventMatchesFilter(entry, filter_text)) total += 1;
        }
        return total;
    }

    fn ensureDebugPanel(self: *App, manager: *panel_manager.PanelManager) !workspace.PanelId {
        if (self.debug.debug_panel_id) |panel_id| {
            if (self.findPanelById(manager, panel_id) != null) {
                manager.focusPanel(panel_id);
                self.requestDebugStreamSnapshot(true);
                return panel_id;
            }
            self.debug.debug_panel_id = null;
        }

        for (manager.workspace.panels.items) |*panel| {
            if (panel.kind == .DebugStream) {
                self.debug.debug_panel_id = panel.id;
                manager.focusPanel(panel.id);
                self.requestDebugStreamSnapshot(true);
                return panel.id;
            }
            if (panel.kind == .ToolOutput and std.mem.eql(u8, panel.title, "Debug Stream")) {
                self.promoteLegacyHostPanel(manager, panel);
                self.debug.debug_panel_id = panel.id;
                manager.focusPanel(panel.id);
                self.requestDebugStreamSnapshot(true);
                return panel.id;
            }
        }

        const panel_data = workspace.PanelData{ .DebugStream = {} };
        const panel_id = try manager.openPanel(.DebugStream, "Debug Stream", panel_data);
        self.debug.debug_panel_id = panel_id;
        if (manager.workspace.syncDockLayout() catch false) {
            manager.workspace.markDirty();
        }
        manager.focusPanel(panel_id);
        self.requestDebugStreamSnapshot(true);
        return panel_id;
    }

    fn ensureWorkspacePanel(self: *App, manager: *panel_manager.PanelManager) !workspace.PanelId {
        if (self.ws.workspace_panel_id) |panel_id| {
            if (self.findPanelById(manager, panel_id) != null) {
                manager.focusPanel(panel_id);
                return panel_id;
            }
            self.ws.workspace_panel_id = null;
        }

        for (manager.workspace.panels.items) |*panel| {
            if (panel.kind == .WorkspaceOverview) {
                self.ws.workspace_panel_id = panel.id;
                manager.focusPanel(panel.id);
                return panel.id;
            }
        }

        const panel_data = workspace.PanelData{ .WorkspaceOverview = {} };
        const panel_id = try manager.openPanel(.WorkspaceOverview, "Workspace Overview", panel_data);
        self.ws.workspace_panel_id = panel_id;
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
        if (self.fs.filesystem_panel_id) |panel_id| {
            if (self.findPanelById(manager, panel_id) != null) {
                manager.focusPanel(panel_id);
                if (self.fs.filesystem_entries.items.len == 0 and self.fs.filesystem_active_request == null and self.fs.filesystem_pending_path == null) {
                    self.requestFilesystemBrowserRefresh(true);
                }
                return panel_id;
            }
            self.fs.filesystem_panel_id = null;
        }

        for (manager.workspace.panels.items) |*panel| {
            if (panel.kind == .FilesystemBrowser) {
                self.fs.filesystem_panel_id = panel.id;
                manager.focusPanel(panel.id);
                return panel.id;
            }
            if (panel.kind == .ToolOutput and std.mem.eql(u8, panel.title, "Filesystem Browser")) {
                self.promoteLegacyHostPanel(manager, panel);
                self.fs.filesystem_panel_id = panel.id;
                manager.focusPanel(panel.id);
                return panel.id;
            }
        }

        const panel_data = workspace.PanelData{ .FilesystemBrowser = {} };
        const panel_id = try manager.openPanel(.FilesystemBrowser, "Filesystem Browser", panel_data);
        self.fs.filesystem_panel_id = panel_id;
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
        if (self.fs.filesystem_tools_panel_id) |panel_id| {
            if (self.findPanelById(manager, panel_id) != null) {
                manager.focusPanel(panel_id);
                return panel_id;
            }
            self.fs.filesystem_tools_panel_id = null;
        }

        for (manager.workspace.panels.items) |*panel| {
            if (panel.kind == .FilesystemTools) {
                self.fs.filesystem_tools_panel_id = panel.id;
                manager.focusPanel(panel.id);
                return panel.id;
            }
            if (panel.kind == .ToolOutput and std.mem.eql(u8, panel.title, "Filesystem Tools")) {
                self.promoteLegacyHostPanel(manager, panel);
                self.fs.filesystem_tools_panel_id = panel.id;
                manager.focusPanel(panel.id);
                return panel.id;
            }
        }

        const panel_data = workspace.PanelData{ .FilesystemTools = {} };
        const panel_id = try manager.openPanel(.FilesystemTools, "Filesystem Tools", panel_data);
        self.fs.filesystem_tools_panel_id = panel_id;
        if (manager.workspace.syncDockLayout() catch false) {
            manager.workspace.markDirty();
        }
        manager.focusPanel(panel_id);
        self.refreshContractServices() catch {};
        return panel_id;
    }

    fn openHostToolOutputPanel(
        self: *App,
        manager: *panel_manager.PanelManager,
        title: []const u8,
        tool_name_label: []const u8,
    ) !workspace.PanelId {
        const tool_name = try self.allocator.dupe(u8, tool_name_label);
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
        return manager.openPanel(.ToolOutput, title, panel_data);
    }

    fn ensureTerminalPanel(self: *App, manager: *panel_manager.PanelManager) !workspace.PanelId {
        if (self.terminal.terminal_panel_id) |panel_id| {
            if (self.findPanelById(manager, panel_id) != null) {
                manager.focusPanel(panel_id);
                return panel_id;
            }
            self.terminal.terminal_panel_id = null;
        }

        for (manager.workspace.panels.items) |*panel| {
            if (panel.kind == .ToolOutput and std.mem.eql(u8, panel.title, "Terminal")) {
                self.terminal.terminal_panel_id = panel.id;
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
        self.terminal.terminal_panel_id = panel_id;
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
            std.log.debug("addSession: key={s} current={}", .{ key, self.chat.chat_sessions.items.len });
        }
        try self.chat.chat_sessions.append(self.allocator, .{
            .key = key_copy,
            .display_name = name_copy,
        });
    }

    fn ensureSessionExists(self: *App, key: []const u8, display_name: []const u8) !void {
        try self.ensureSessionInList(key, display_name);
        try self.setCurrentSessionKey(key);
    }

    fn ensureSessionInList(self: *App, key: []const u8, display_name: []const u8) !void {
        for (self.chat.chat_sessions.items) |*session| {
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
        if (self.chat.current_session_key) |current| {
            for (self.chat.chat_sessions.items) |session| {
                if (std.mem.eql(u8, current, session.key)) {
                    return;
                }
            }

            self.allocator.free(current);
            self.chat.current_session_key = null;
        }

        if (self.chat.current_session_key == null) {
            if (self.chat.chat_sessions.items.len > 0) {
                self.setCurrentSessionKey(self.chat.chat_sessions.items[0].key) catch {};
            }
        }
    }

    fn setCurrentSessionByKey(self: *App, session_key: []const u8) bool {
        for (self.chat.chat_sessions.items) |session| {
            if (std.mem.eql(u8, session.key, session_key)) {
                self.setCurrentSessionKey(session.key) catch {};
                return true;
            }
        }
        return false;
    }

    fn setCurrentSessionByIndex(self: *App, index: usize) bool {
        if (index >= self.chat.chat_sessions.items.len) return false;
        self.setCurrentSessionKey(self.chat.chat_sessions.items[index].key) catch {};
        return true;
    }

    fn setCurrentSessionKey(self: *App, key: []const u8) !void {
        if (key.len == 0) return;
        const key_copy = try self.allocator.dupe(u8, key);
        self.setCurrentSessionKeyOwned(key_copy);
    }

    fn setCurrentSessionKeyOwned(self: *App, key_copy: []const u8) void {
        var changed = true;
        if (self.chat.current_session_key) |current| {
            changed = !std.mem.eql(u8, current, key_copy);
            self.allocator.free(current);
        }
        self.chat.current_session_key = key_copy;
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

    pub fn setConnectionState(self: *App, state: ConnectionState, text: []const u8) void {
        self.connection_state = state;
        const copy = self.allocator.dupe(u8, text) catch return;
        self.allocator.free(self.status_text);
        self.status_text = copy;
        self.syncHomeOnboardingStage();
    }

    fn syncHomeOnboardingStage(self: *App) void {
        self.ws.onboarding_stage = if (self.connection_state != .connected)
            .connect
        else if (self.selectedWorkspaceId() == null)
            .choose_workspace
        else
            .workspace_ready;
    }

    // Drawing helpers

    pub fn drawSurfacePanel(self: *App, rect: Rect) void {
        const ss = self.sharedStyleSheet();
        const fill = ss.surfaces.surface orelse ss.panel.fill orelse Paint{ .solid = self.theme.colors.surface };
        self.drawPaintRect(rect, fill);
        self.drawRect(rect, ss.panel.border orelse self.theme.colors.border);
    }

    pub fn drawPaintRect(self: *App, rect: Rect, paint: Paint) void {
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

    pub fn drawFilledRect(self: *App, rect: Rect, color: [4]f32) void {
        self.ui_commands.pushRect(
            .{ .min = rect.min, .max = rect.max },
            .{ .fill = color },
        );
    }

    pub fn drawRect(self: *App, rect: Rect, color: [4]f32) void {
        self.ui_commands.pushRect(
            .{ .min = rect.min, .max = rect.max },
            .{ .stroke = color },
        );
    }

    pub fn drawLabel(self: *App, x: f32, y: f32, text: []const u8, color: [4]f32) void {
        self.drawText(x, y, text, color);
    }

    pub fn drawFormSectionTitle(
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

    pub fn drawFormFieldLabel(
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

    pub fn textLineHeight(self: *App) f32 {
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

    pub fn panelLayoutMetrics(self: *App) PanelLayoutMetrics {
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

    pub fn drawCenteredText(self: *App, rect: Rect, text: []const u8, color: [4]f32) void {
        const text_w = self.measureTextFast(text);
        const line_height = self.textLineHeight();
        const x = rect.min[0] + @max(0.0, (rect.width() - text_w) * 0.5);
        const y = rect.min[1] + @max(0.0, (rect.height() - line_height) * 0.5);
        self.drawText(x, y, text, color);
    }

    pub fn drawText(self: *App, x: f32, y: f32, text: []const u8, color: [4]f32) void {
        self.ui_commands.pushText(text, .{ x, y }, color, .body, self.textPixelSize());
    }

    pub fn drawTextWrapped(self: *App, x: f32, y: f32, max_w: f32, text: []const u8, color: [4]f32) f32 {
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

    pub fn measureText(self: *App, text: []const u8) f32 {
        return self.metrics_context.measureText(text, 0.0)[0];
    }

    pub fn measureTextFast(self: *App, text: []const u8) f32 {
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

    pub fn drawTextCenteredTrimmed(self: *App, center_x: f32, y: f32, max_w: f32, text: []const u8, color: [4]f32) void {
        if (max_w <= 0.0) return;
        const measured = self.measureTextFast(text);
        if (measured <= max_w) {
            self.drawText(center_x - measured * 0.5, y, text, color);
            return;
        }
        self.drawTextTrimmed(center_x - max_w * 0.5, y, max_w, text, color);
    }

    pub fn drawTextTrimmed(self: *App, x: f32, y: f32, max_w: f32, text: []const u8, color: [4]f32) void {
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

fn dupRequiredStringField(allocator: std.mem.Allocator, obj: std.json.ObjectMap, key: []const u8) ![]u8 {
    const value = obj.get(key) orelse return error.InvalidResponse;
    if (value != .string) return error.InvalidResponse;
    return allocator.dupe(u8, value.string);
}

fn dupOptionalStringField(allocator: std.mem.Allocator, obj: std.json.ObjectMap, key: []const u8) !?[]u8 {
    const value = obj.get(key) orelse return null;
    return switch (value) {
        .string => try allocator.dupe(u8, value.string),
        .null => null,
        else => return error.InvalidResponse,
    };
}

fn intFieldOrDefault(obj: std.json.ObjectMap, key: []const u8, default: i64) !i64 {
    const value = obj.get(key) orelse return default;
    return switch (value) {
        .integer => @intCast(value.integer),
        .float => @intFromFloat(value.float),
        .null => default,
        else => return error.InvalidResponse,
    };
}

fn u64FieldOrDefault(obj: std.json.ObjectMap, key: []const u8, default: u64) !u64 {
    const value = obj.get(key) orelse return default;
    return switch (value) {
        .integer => if (value.integer < 0) return error.InvalidResponse else @intCast(value.integer),
        .float => if (value.float < 0) return error.InvalidResponse else @intFromFloat(value.float),
        .null => default,
        else => return error.InvalidResponse,
    };
}

fn parseMissionActorView(allocator: std.mem.Allocator, value: std.json.Value) !MissionActorView {
    if (value != .object) return error.InvalidResponse;
    return .{
        .actor_type = try dupRequiredStringField(allocator, value.object, "actor_type"),
        .actor_id = try dupRequiredStringField(allocator, value.object, "actor_id"),
    };
}

fn parseMissionArtifactView(allocator: std.mem.Allocator, value: std.json.Value) !MissionArtifactView {
    if (value != .object) return error.InvalidResponse;
    return .{
        .kind = try dupRequiredStringField(allocator, value.object, "kind"),
        .path = try dupOptionalStringField(allocator, value.object, "path"),
        .summary = try dupOptionalStringField(allocator, value.object, "summary"),
        .created_at_ms = try intFieldOrDefault(value.object, "created_at_ms", 0),
    };
}

fn parseMissionEventView(allocator: std.mem.Allocator, value: std.json.Value) !MissionEventView {
    if (value != .object) return error.InvalidResponse;
    return .{
        .seq = try u64FieldOrDefault(value.object, "seq", 0),
        .event_type = try dupRequiredStringField(allocator, value.object, "event_type"),
        .payload_json = blk: {
            const payload = value.object.get("payload") orelse return error.InvalidResponse;
            break :blk try std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(payload, .{})});
        },
        .created_at_ms = try intFieldOrDefault(value.object, "created_at_ms", 0),
    };
}

fn parseMissionApprovalView(allocator: std.mem.Allocator, value: std.json.Value) !MissionApprovalView {
    if (value != .object) return error.InvalidResponse;
    const obj = value.object;
    return .{
        .approval_id = try dupRequiredStringField(allocator, obj, "approval_id"),
        .action_kind = try dupRequiredStringField(allocator, obj, "action_kind"),
        .message = try dupRequiredStringField(allocator, obj, "message"),
        .payload_json = blk: {
            const payload = obj.get("payload") orelse break :blk null;
            break :blk switch (payload) {
                .null => null,
                else => try std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(payload, .{})}),
            };
        },
        .requested_at_ms = try intFieldOrDefault(obj, "requested_at_ms", 0),
        .requested_by = try parseMissionActorView(allocator, obj.get("requested_by") orelse return error.InvalidResponse),
        .resolved_at_ms = try intFieldOrDefault(obj, "resolved_at_ms", 0),
        .resolved_by = blk: {
            const resolved = obj.get("resolved_by") orelse break :blk null;
            if (resolved == .null) break :blk null;
            break :blk try parseMissionActorView(allocator, resolved);
        },
        .resolution_note = try dupOptionalStringField(allocator, obj, "resolution_note"),
        .resolution = try dupOptionalStringField(allocator, obj, "resolution"),
    };
}

fn lookupMissionPersonaPack(agent_packs: []const MissionAgentPackView, agent_id: []const u8) ?[]const u8 {
    for (agent_packs) |entry| {
        if (std.mem.eql(u8, entry.agent_id, agent_id)) return entry.persona_pack;
    }
    return null;
}

fn missionResultErrorMessage(allocator: std.mem.Allocator, result_json: []const u8) !?[]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, result_json, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const root = parsed.value.object;
    if (root.get("ok")) |value| {
        if (value == .bool and value.bool) return null;
    }
    const err_val = root.get("error") orelse return try allocator.dupe(u8, "mission operation failed");
    return switch (err_val) {
        .string => try allocator.dupe(u8, err_val.string),
        .object => blk: {
            if (err_val.object.get("message")) |message| {
                if (message == .string) break :blk try allocator.dupe(u8, message.string);
            }
            if (err_val.object.get("code")) |code| {
                if (code == .string) break :blk try allocator.dupe(u8, code.string);
            }
            break :blk try allocator.dupe(u8, "mission operation failed");
        },
        .null => null,
        else => try allocator.dupe(u8, "mission operation failed"),
    };
}

fn deinitMissionRecordList(allocator: std.mem.Allocator, list: *std.ArrayListUnmanaged(MissionRecordView)) void {
    for (list.items) |*mission| mission.deinit(allocator);
    list.deinit(allocator);
    list.* = .{};
}

fn deinitMissionAgentPackList(allocator: std.mem.Allocator, list: *std.ArrayListUnmanaged(MissionAgentPackView)) void {
    for (list.items) |*entry| entry.deinit(allocator);
    list.deinit(allocator);
    list.* = .{};
}

fn freeOwnedExecApproval(allocator: std.mem.Allocator, approval: *zui.protocol.types.ExecApproval) void {
    allocator.free(approval.id);
    allocator.free(approval.payload_json);
    if (approval.summary) |summary| allocator.free(summary);
    if (approval.requested_by) |value| allocator.free(value);
    if (approval.resolved_by) |value| allocator.free(value);
    if (approval.decision) |value| allocator.free(value);
    approval.* = undefined;
}

fn deinitExecApprovalList(allocator: std.mem.Allocator, list: *std.ArrayListUnmanaged(zui.protocol.types.ExecApproval)) void {
    for (list.items) |*approval| freeOwnedExecApproval(allocator, approval);
    list.deinit(allocator);
    list.* = .{};
}

fn freeOwnedWorkboardItem(allocator: std.mem.Allocator, item: *zui.protocol.types.WorkboardItem) void {
    allocator.free(item.id);
    if (item.kind) |value| allocator.free(value);
    if (item.status) |value| allocator.free(value);
    if (item.title) |value| allocator.free(value);
    if (item.summary) |value| allocator.free(value);
    if (item.owner) |value| allocator.free(value);
    if (item.agent_id) |value| allocator.free(value);
    if (item.parent_id) |value| allocator.free(value);
    if (item.cron_key) |value| allocator.free(value);
    if (item.payload_json) |value| allocator.free(value);
    item.* = undefined;
}

fn deinitWorkboardItemOwnedSlice(allocator: std.mem.Allocator, items: []zui.protocol.types.WorkboardItem) void {
    for (items) |*item| freeOwnedWorkboardItem(allocator, item);
    allocator.free(items);
}

fn isLocalSpiderwebServerUrl(server_url: []const u8) bool {
    const trimmed = std.mem.trim(u8, server_url, " \t\r\n");
    return std.mem.eql(u8, trimmed, config_mod.Config.default_server_url) or
        std.mem.eql(u8, trimmed, "ws://localhost:18790") or
        std.mem.eql(u8, trimmed, "ws://127.0.0.1:18790");
}

fn isProfileLikelyRemote(profile: *const config_mod.ConnectionProfile) bool {
    return !isLocalSpiderwebServerUrl(profile.server_url);
}






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
    if (builtin.abi.isAndroid()) {
        var app = try App.init(std.heap.c_allocator);
        defer {
            app.deinit();
            std.heap.c_allocator.destroy(app);
        }

        const should_connect = app.config.auto_connect_on_launch or
            (if (app.launch_context) |context| App.launchContextRequiresConnection(context) else false);
        if (should_connect) {
            app.tryConnect(&app.manager) catch {};
        }
        app.runLaunchContextAction();

        try app.run();
        return;
    }

    var gpa = std.heap.GeneralPurposeAllocator(.{ .thread_safe = true }){};
    defer _ = gpa.deinit();

    var app = try App.init(gpa.allocator());
    defer {
        app.deinit();
        gpa.allocator().destroy(app);
    }

    const should_connect = app.config.auto_connect_on_launch or
        (if (app.launch_context) |context| App.launchContextRequiresConnection(context) else false);
    if (should_connect) {
        app.tryConnect(&app.manager) catch {};
    }
    app.runLaunchContextAction();

    try app.run();
}
fn currentBuildLabel() []const u8 {
    if (std.mem.eql(u8, build_options.git_revision, "unknown")) return build_options.app_version;
    return std.fmt.comptimePrint("{s} ({s})", .{ build_options.app_version, build_options.git_revision });
}

fn appendGuiDiagnosticLogFmt(comptime fmt: []const u8, args: anytype) void {
    const allocator = std.heap.page_allocator;
    const line = std.fmt.allocPrint(allocator, fmt, args) catch return;
    defer allocator.free(line);
    appendGuiDiagnosticLog(line);
}

fn appendGuiDiagnosticLog(line: []const u8) void {
    const allocator = std.heap.page_allocator;
    const home = std.process.getEnvVarOwned(allocator, "HOME") catch return;
    defer allocator.free(home);

    const log_dir = std.fmt.allocPrint(allocator, "{s}/Library/Logs/SpiderApp", .{home}) catch return;
    defer allocator.free(log_dir);
    std.fs.makeDirAbsolute(log_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return,
    };

    const log_path = std.fmt.allocPrint(allocator, "{s}/gui.log", .{log_dir}) catch return;
    defer allocator.free(log_path);

    const file = std.fs.openFileAbsolute(log_path, .{ .mode = .read_write }) catch |err| switch (err) {
        error.FileNotFound => std.fs.createFileAbsolute(log_path, .{}) catch return,
        else => return,
    };
    defer file.close();

    file.seekFromEnd(0) catch return;
    const payload = std.fmt.allocPrint(allocator, "[{d}] {s}\n", .{ std.time.timestamp(), line }) catch return;
    defer allocator.free(payload);
    _ = file.writeAll(payload) catch return;
}

// Module-level re-exports of App methods, allowing panel host files to reference
// them as `@import("../root.zig").methodName` for use as function pointer callbacks.
pub const launcherSettingsDrawFormSectionTitle = App.launcherSettingsDrawFormSectionTitle;
pub const launcherSettingsDrawFormFieldLabel = App.launcherSettingsDrawFormFieldLabel;
pub const launcherSettingsDrawTextInput = App.launcherSettingsDrawTextInput;
pub const launcherSettingsDrawButton = App.launcherSettingsDrawButton;
pub const launcherSettingsDrawLabel = App.launcherSettingsDrawLabel;
pub const launcherSettingsDrawTextTrimmed = App.launcherSettingsDrawTextTrimmed;
pub const launcherSettingsDrawVerticalScrollbar = App.launcherSettingsDrawVerticalScrollbar;
pub const filesystemDrawSurfacePanel = App.filesystemDrawSurfacePanel;
pub const filesystemDrawFilledRect = App.filesystemDrawFilledRect;
pub const filesystemDrawRect = App.filesystemDrawRect;
pub const filesystemDrawTextWrapped = App.filesystemDrawTextWrapped;
pub const terminalDrawOutput = App.terminalDrawOutput;
pub const terminalDrawStyledLineAt = App.terminalDrawStyledLineAt;
pub const debugDrawPerfCharts = App.debugDrawPerfCharts;
pub const debugDrawEventStream = App.debugDrawEventStream;
pub const debugEventStreamSetOutputRect = App.debugEventStreamSetOutputRect;
pub const debugEventStreamFocusPanel = App.debugEventStreamFocusPanel;
pub const debugEventStreamPushClip = App.debugEventStreamPushClip;
pub const debugEventStreamPopClip = App.debugEventStreamPopClip;
pub const debugEventStreamDrawFilledRect = App.debugEventStreamDrawFilledRect;
pub const debugEventStreamGetScrollY = App.debugEventStreamGetScrollY;
pub const debugEventStreamSetScrollY = App.debugEventStreamSetScrollY;
pub const debugEventStreamGetScrollbarDragging = App.debugEventStreamGetScrollbarDragging;
pub const debugEventStreamSetScrollbarDragging = App.debugEventStreamSetScrollbarDragging;
pub const debugEventStreamGetDragStartY = App.debugEventStreamGetDragStartY;
pub const debugEventStreamSetDragStartY = App.debugEventStreamSetDragStartY;
pub const debugEventStreamGetDragStartScrollY = App.debugEventStreamGetDragStartScrollY;
pub const debugEventStreamSetDragStartScrollY = App.debugEventStreamSetDragStartScrollY;
pub const debugEventStreamSetDragCapture = App.debugEventStreamSetDragCapture;
pub const debugEventStreamReleaseDragCapture = App.debugEventStreamReleaseDragCapture;
pub const debugEventStreamEntryHeight = App.debugEventStreamEntryHeight;
pub const debugEventStreamDrawEntry = App.debugEventStreamDrawEntry;
pub const debugEventStreamSelectEntry = App.debugEventStreamSelectEntry;
pub const debugEventStreamCopySelectedEvent = App.debugEventStreamCopySelectedEvent;
pub const debugEventStreamSelectedEventCount = App.debugEventStreamSelectedEventCount;
