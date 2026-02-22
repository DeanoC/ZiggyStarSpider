const zui = @import("ziggy-ui");

// Host-facing alias for ziggy-ui's panel split boundary. Keeping this indirection
// local lets us switch to an external panels package with minimal churn.
const has_panel_interfaces = @hasDecl(zui.ui, "panel_interfaces");
const has_panel_runtime = @hasDecl(zui.ui, "panel_runtime");
const has_panels_catalog = @hasDecl(zui.ui, "panels");

pub const catalog = if (has_panels_catalog) zui.ui.panels else struct {};

pub const UiAction = if (has_panel_interfaces) zui.ui.panel_interfaces.UiAction else zui.ui.main_window.UiAction;
pub const DrawResult = if (has_panel_interfaces) zui.ui.panel_interfaces.DrawResult else struct {
    session_key: ?[]const u8 = null,
    agent_id: ?[]const u8 = null,
};
pub const AttachmentOpen = if (has_panel_interfaces) zui.ui.panel_interfaces.AttachmentOpen else struct {
    name: []u8,
    kind: []u8,
    url: []u8,
    body: ?[]u8 = null,
    status: ?[]u8 = null,
    truncated: bool = false,
};

pub const runtime = if (has_panel_runtime) zui.ui.panel_runtime else zui.ui.main_window;

pub fn assertAvailable() void {
    _ = UiAction;
    _ = DrawResult;
    _ = AttachmentOpen;
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
