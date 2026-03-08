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
pub const LauncherSettingsModel = if (has_panel_interfaces) zui.ui.panel_interfaces.LauncherSettingsModel else struct {};
pub const LauncherSettingsAction = if (has_panel_interfaces) zui.ui.panel_interfaces.LauncherSettingsAction else enum { connect };

// Project panel contracts.
pub const ProjectPanelModel = if (has_panel_interfaces) zui.ui.panel_interfaces.ProjectPanelModel else struct {};
pub const ProjectPanelView = if (has_panel_interfaces) zui.ui.panel_interfaces.ProjectPanelView else struct {};
pub const ProjectListEntryView = if (has_panel_interfaces) zui.ui.panel_interfaces.ProjectListEntryView else struct {};
pub const ProjectNodeEntryView = if (has_panel_interfaces) zui.ui.panel_interfaces.ProjectNodeEntryView else struct {};
pub const ProjectPanelAction = if (has_panel_interfaces) zui.ui.panel_interfaces.ProjectPanelAction else enum { refresh_workspace };

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
    _ = LauncherSettingsModel;
    _ = LauncherSettingsAction;
    _ = ProjectPanelModel;
    _ = ProjectPanelView;
    _ = ProjectListEntryView;
    _ = ProjectNodeEntryView;
    _ = ProjectPanelAction;
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
