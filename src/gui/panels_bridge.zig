const zui = @import("ziggy-ui");

// SpiderApp consumes canonical panel contracts through this local alias layer so
// host code stays insulated from package layout churn inside ziggy-ui.
const has_panel_interfaces = @hasDecl(zui.ui, "panel_interfaces");
const has_panel_runtime = @hasDecl(zui.ui, "panel_runtime");
const has_panels_catalog = @hasDecl(zui.ui, "panels");

pub const catalog = if (has_panels_catalog) zui.ui.panels else struct {};

// Shared runtime and generic UI actions.
pub const UiAction = if (has_panel_interfaces) zui.ui.panel_interfaces.UiAction else zui.ui.main_window.UiAction;
pub const DrawResult = if (has_panel_interfaces) zui.ui.panel_interfaces.DrawResult else struct {
    session_key: ?[]const u8 = null,
    agent_id: ?[]const u8 = null,
};
pub const ChatPanelAction = if (has_panel_interfaces) zui.ui.panel_interfaces.ChatPanelAction else struct {
    send_message: ?[]u8 = null,
    select_session: ?[]u8 = null,
    select_session_id: ?[]u8 = null,
    new_chat_session_key: ?[]u8 = null,
    open_activity_panel: bool = false,
    open_approvals_panel: bool = false,
};
pub const AttachmentOpen = if (has_panel_interfaces) zui.ui.panel_interfaces.AttachmentOpen else struct {
    name: []u8,
    kind: []u8,
    url: []u8,
    body: ?[]u8 = null,
    status: ?[]u8 = null,
    truncated: bool = false,
};

// Filesystem panel contracts.
pub const FilesystemEntryKind = if (has_panel_interfaces) zui.ui.panel_interfaces.FilesystemEntryKind else enum { unknown };
pub const FilesystemSortKey = if (has_panel_interfaces) zui.ui.panel_interfaces.FilesystemSortKey else enum { name };
pub const FilesystemSortDirection = if (has_panel_interfaces) zui.ui.panel_interfaces.FilesystemSortDirection else enum { ascending };
pub const FilesystemPreviewMode = if (has_panel_interfaces) zui.ui.panel_interfaces.FilesystemPreviewMode else enum { empty };
pub const FilesystemPanelModel = if (has_panel_interfaces) zui.ui.panel_interfaces.FilesystemPanelModel else struct {};
pub const FilesystemPanelView = if (has_panel_interfaces) zui.ui.panel_interfaces.FilesystemPanelView else struct {};
pub const FilesystemEntryView = if (has_panel_interfaces) zui.ui.panel_interfaces.FilesystemEntryView else struct {};
pub const FilesystemPanelAction = if (has_panel_interfaces) zui.ui.panel_interfaces.FilesystemPanelAction else enum { refresh };
pub const FilesystemToolsPanelModel = if (has_panel_interfaces) zui.ui.panel_interfaces.FilesystemToolsPanelModel else struct {};
pub const FilesystemToolsPanelView = if (has_panel_interfaces) zui.ui.panel_interfaces.FilesystemToolsPanelView else struct {};
pub const FilesystemToolsPanelAction = if (has_panel_interfaces) zui.ui.panel_interfaces.FilesystemToolsPanelAction else enum { contract_refresh };
pub const FilesystemRuntimeReadTarget = if (has_panel_interfaces) zui.ui.panel_interfaces.FilesystemRuntimeReadTarget else enum { status };
pub const FilesystemRuntimeControlTarget = if (has_panel_interfaces) zui.ui.panel_interfaces.FilesystemRuntimeControlTarget else enum { enable };

// Debug panel contracts.
pub const DebugPanelModel = if (has_panel_interfaces) zui.ui.panel_interfaces.DebugPanelModel else struct {};
pub const DebugPanelView = if (has_panel_interfaces) zui.ui.panel_interfaces.DebugPanelView else struct {};
pub const DebugSparklineSeriesView = if (has_panel_interfaces) zui.ui.panel_interfaces.DebugSparklineSeriesView else struct {};
pub const DebugEventStreamView = if (has_panel_interfaces) zui.ui.panel_interfaces.DebugEventStreamView else struct {};
pub const DebugPanelAction = if (has_panel_interfaces) zui.ui.panel_interfaces.DebugPanelAction else enum { toggle_stream };

// Settings panel contracts.
pub const ConnectRole = if (has_panel_interfaces) zui.ui.panel_interfaces.ConnectRole else enum { admin, user };
pub const SettingsConnectionState = if (has_panel_interfaces) zui.ui.panel_interfaces.SettingsConnectionState else enum { disconnected };
pub const SettingsTerminalBackend = if (has_panel_interfaces) zui.ui.panel_interfaces.SettingsTerminalBackend else enum { plain_text };
pub const SettingsThemeMode = if (has_panel_interfaces) zui.ui.panel_interfaces.SettingsThemeMode else enum { pack_default };
pub const SettingsThemeProfile = if (has_panel_interfaces) zui.ui.panel_interfaces.SettingsThemeProfile else enum { auto };
pub const ThemePackQuickPickView = if (has_panel_interfaces) zui.ui.panel_interfaces.ThemePackQuickPickView else struct {
    label: []const u8 = "",
    value: []const u8 = "",
    selected: bool = false,
};
pub const LauncherSettingsModel = if (has_panel_interfaces) zui.ui.panel_interfaces.LauncherSettingsModel else struct {};
pub const LauncherSettingsAction = if (has_panel_interfaces) zui.ui.panel_interfaces.LauncherSettingsAction else enum { connect };

// Workspace panel contracts.
pub const WorkspaceMountEntryView = if (has_panel_interfaces) zui.ui.panel_interfaces.WorkspaceMountEntryView else struct {
    index: usize = 0,
    mount_path: []const u8 = "",
    node_id: []const u8 = "",
    node_name: ?[]const u8 = null,
    export_name: []const u8 = "",
    selected: bool = false,
};
pub const WorkspaceBindEntryView = if (has_panel_interfaces) zui.ui.panel_interfaces.WorkspaceBindEntryView else struct {
    index: usize = 0,
    bind_path: []const u8 = "",
    target_path: []const u8 = "",
    selected: bool = false,
};
pub const WorkspaceNodePickerEntryView = if (has_panel_interfaces) zui.ui.panel_interfaces.WorkspaceNodePickerEntryView else struct {
    index: usize = 0,
    node_id: []const u8 = "",
    node_name: []const u8 = "",
    online: bool = false,
    selected: bool = false,
};
pub const WorkspacePanelModel = if (has_panel_interfaces) zui.ui.panel_interfaces.WorkspacePanelModel else struct {
    connected: bool = false,
    has_workspaces: bool = false,
    has_nodes: bool = false,
    can_create_workspace: bool = false,
    can_activate_workspace: bool = false,
    can_attach_session: bool = false,
    can_lock_workspace: bool = false,
    can_unlock_workspace: bool = false,
    can_remove_mount: bool = false,
    can_remove_bind: bool = false,
    can_rotate_token: bool = false,
    has_local_node: bool = false,

    pub fn controlsDisabled(self: @This()) bool {
        return !self.connected;
    }
};
pub const WorkspacePanelView = if (has_panel_interfaces) zui.ui.panel_interfaces.WorkspacePanelView else struct {
    title: []const u8 = "Workspace Overview",
    selected_workspace_button_label: []const u8 = "Select workspace",
    lock_state_text: []const u8 = "Workspace lock state: unknown",
    workspace_token: []const u8 = "",
    create_name: []const u8 = "",
    create_vision: []const u8 = "",
    template_id: []const u8 = "",
    operator_token: []const u8 = "",
    mount_path: []const u8 = "/",
    mount_node_id: []const u8 = "",
    mount_export_name: []const u8 = "",
    bind_path: []const u8 = "/repo",
    bind_target_path: []const u8 = "/nodes/local/fs",
    mount_hint: ?[]const u8 = null,
    workspace_error_text: ?[]const u8 = null,
    session_status_line: ?[]const u8 = null,
    session_status_warning: bool = false,
    selected_workspace_line: ?[]const u8 = null,
    setup_status_line: ?[]const u8 = null,
    setup_status_warning: bool = false,
    setup_vision_line: ?[]const u8 = null,
    template_line: ?[]const u8 = null,
    binds_line: ?[]const u8 = null,
    workspace_summary_line: ?[]const u8 = null,
    workspace_health_line: ?[]const u8 = null,
    workspace_health_warning: bool = false,
    workspace_health_error: bool = false,
    counts_line: ?[]const u8 = null,
    help_line: []const u8 = "Open Filesystem and Debug panels from the Windows menu.",
    workspaces: []const WorkspaceListEntryView = &.{},
    nodes: []const WorkspaceNodeEntryView = &.{},
    mounts: []const WorkspaceMountEntryView = &.{},
    binds: []const WorkspaceBindEntryView = &.{},
    nodes_for_picker: []const WorkspaceNodePickerEntryView = &.{},
    token_display: ?[]const u8 = null,
    local_node_id: ?[]const u8 = null,
    local_node_name: ?[]const u8 = null,
    local_node_ttl_text: ?[]const u8 = null,
    local_node_bootstrapped: bool = false,
    workspace_op_busy: bool = false,
    workspace_op_error: ?[]const u8 = null,
};
pub const WorkspaceListEntryView = if (has_panel_interfaces) zui.ui.panel_interfaces.WorkspaceListEntryView else struct {
    index: usize = 0,
    line: []const u8 = "",
    selected: bool = false,
};
pub const WorkspaceNodeEntryView = if (has_panel_interfaces) zui.ui.panel_interfaces.WorkspaceNodeEntryView else struct {
    line: []const u8 = "",
    degraded: bool = false,
};
pub const WorkspacePanelAction = if (has_panel_interfaces) zui.ui.panel_interfaces.WorkspacePanelAction else union(enum) {
    select_workspace_index: usize,
    create_workspace,
    refresh_workspace,
    activate_workspace,
    attach_session,
    lock_workspace,
    unlock_workspace,
    add_mount,
    remove_mount,
    add_bind,
    remove_bind,
    auth_status,
    rotate_auth_user,
    rotate_auth_admin,
    reveal_auth_admin,
    copy_auth_admin,
    reveal_auth_user,
    copy_auth_user,
    select_mount_index: usize,
    remove_selected_mount,
    select_bind_index: usize,
    remove_selected_bind,
    select_node_for_mount: usize,
    rotate_workspace_token,
    open_node_browser,
    rebootstrap_local_node,
};

// Terminal panel contracts.
pub const TerminalPanelModel = if (has_panel_interfaces) zui.ui.panel_interfaces.TerminalPanelModel else struct {};
pub const TerminalPanelView = if (has_panel_interfaces) zui.ui.panel_interfaces.TerminalPanelView else struct {};
pub const TerminalOutputView = if (has_panel_interfaces) zui.ui.panel_interfaces.TerminalOutputView else struct {};
pub const TerminalPanelAction = if (has_panel_interfaces) zui.ui.panel_interfaces.TerminalPanelAction else enum { start_or_restart };

pub const runtime = if (has_panel_runtime) zui.ui.panel_runtime else zui.ui.main_window;

pub fn assertAvailable() void {
    _ = UiAction;
    _ = DrawResult;
    _ = ChatPanelAction;
    _ = AttachmentOpen;
    _ = FilesystemEntryKind;
    _ = FilesystemSortKey;
    _ = FilesystemSortDirection;
    _ = FilesystemPreviewMode;
    _ = FilesystemPanelModel;
    _ = FilesystemPanelView;
    _ = FilesystemEntryView;
    _ = FilesystemPanelAction;
    _ = FilesystemToolsPanelModel;
    _ = FilesystemToolsPanelView;
    _ = FilesystemToolsPanelAction;
    _ = FilesystemRuntimeReadTarget;
    _ = FilesystemRuntimeControlTarget;
    _ = DebugPanelModel;
    _ = DebugPanelView;
    _ = DebugSparklineSeriesView;
    _ = DebugEventStreamView;
    _ = DebugPanelAction;
    _ = ConnectRole;
    _ = SettingsConnectionState;
    _ = SettingsTerminalBackend;
    _ = SettingsThemeMode;
    _ = SettingsThemeProfile;
    _ = ThemePackQuickPickView;
    _ = LauncherSettingsModel;
    _ = LauncherSettingsAction;
    _ = WorkspaceMountEntryView;
    _ = WorkspaceBindEntryView;
    _ = WorkspaceNodePickerEntryView;
    _ = WorkspacePanelModel;
    _ = WorkspacePanelView;
    _ = WorkspaceListEntryView;
    _ = WorkspaceNodeEntryView;
    _ = WorkspacePanelAction;
    _ = TerminalPanelModel;
    _ = TerminalPanelView;
    _ = TerminalOutputView;
    _ = TerminalPanelAction;
    if (has_panel_runtime) {
        _ = runtime.drawContents;
    }
    if (has_panels_catalog) {
        if (@hasDecl(catalog, "operator")) {
            _ = catalog.operator;
        }
        if (@hasDecl(catalog, "approvals_inbox")) {
            _ = catalog.approvals_inbox;
        }
    }
}
