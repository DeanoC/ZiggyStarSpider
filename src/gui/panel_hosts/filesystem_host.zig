// filesystem_host.zig — Filesystem panel draw functions.

const std = @import("std");
const zui = @import("ziggy-ui");
const zui_panels = @import("ziggy-ui-panels");
const control_plane = @import("control_plane");
const workspace_types = control_plane.workspace_types;
const panels_bridge = @import("../panels_bridge.zig");
const terminal_render_backend = @import("../terminal_render_backend.zig");

const zcolors = zui.theme.colors;
const form_layout = zui.ui.layout.form_layout;
const panel_manager = zui.ui.panel_manager;
const ui_draw_context = zui.ui.draw_context;

const Rect = zui.core.Rect;
const UiRect = ui_draw_context.Rect;
const PanelLayoutMetrics = form_layout.Metrics;

const FilesystemPanel = zui_panels.filesystem_panel;
const FilesystemToolsPanel = zui_panels.filesystem_tools_panel;

fn filesystemToolsFocusFieldToExternal(field: anytype) FilesystemToolsPanel.FocusField {
    return switch (field) {
        .filesystem_contract_payload => .contract_payload,
        else => .none,
    };
}

fn filesystemToolsFocusFieldFromExternal(field: FilesystemToolsPanel.FocusField) @import("../root.zig").SettingsFocusField {
    return switch (field) {
        .contract_payload => .filesystem_contract_payload,
        .none => .none,
    };
}

fn isFilesystemToolsPanelFocusField(field: anytype) bool {
    return switch (field) {
        .filesystem_contract_payload => true,
        else => false,
    };
}

pub fn drawFilesystemPanel(self: anytype, manager: anytype, rect: anytype) void {
    _ = manager;
    if (self.connection_state == .connected and
        self.fs.filesystem_entries.items.len == 0 and
        self.fs.filesystem_active_request == null and
        self.fs.filesystem_pending_path == null)
    {
        self.requestFilesystemBrowserRefresh(true);
    }

    const model = self.filesystemPanelModel();
    const host = FilesystemPanel.Host{
        .ctx = @ptrCast(self),
        .draw_label = @import("../root.zig").launcherSettingsDrawLabel,
        .draw_text_trimmed = @import("../root.zig").launcherSettingsDrawTextTrimmed,
        .draw_text_input = @import("../root.zig").launcherSettingsDrawTextInput,
        .draw_button = @import("../root.zig").launcherSettingsDrawButton,
        .draw_surface_panel = @import("../root.zig").filesystemDrawSurfacePanel,
        .draw_text_wrapped = @import("../root.zig").filesystemDrawTextWrapped,
        .push_clip = @import("../root.zig").debugEventStreamPushClip,
        .pop_clip = @import("../root.zig").debugEventStreamPopClip,
        .draw_filled_rect = @import("../root.zig").filesystemDrawFilledRect,
        .draw_rect = @import("../root.zig").filesystemDrawRect,
    };
    const path_label = if (self.fs.filesystem_path.items.len > 0) self.fs.filesystem_path.items else "/";
    var view = self.buildFilesystemPanelView();
    defer view.deinit(self.allocator);
    var panel_state = FilesystemPanel.State{
        .entry_scroll_y = self.fs.filesystem_entry_scroll_y,
        .entry_scrollbar_dragging = self.fs.filesystem_entry_scrollbar_dragging,
        .entry_scrollbar_drag_anchor = self.fs.filesystem_entry_scrollbar_drag_anchor,
        .entry_scrollbar_drag_scroll = self.fs.filesystem_entry_scrollbar_drag_scroll,
        .last_clicked_entry_index = self.fs.filesystem_last_clicked_entry_index,
        .last_click_ms = self.fs.filesystem_last_click_ms,
        .type_column_width = self.fs.filesystem_type_column_width,
        .modified_column_width = self.fs.filesystem_modified_column_width,
        .size_column_width = self.fs.filesystem_size_column_width,
        .column_resize = self.fs.filesystem_column_resize_handle,
        .preview_split_ratio = self.fs.filesystem_preview_split_ratio,
        .preview_split_dragging = self.fs.filesystem_preview_split_dragging,
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
    self.fs.filesystem_entry_scroll_y = panel_state.entry_scroll_y;
    self.fs.filesystem_entry_scrollbar_dragging = panel_state.entry_scrollbar_dragging;
    self.fs.filesystem_entry_scrollbar_drag_anchor = panel_state.entry_scrollbar_drag_anchor;
    self.fs.filesystem_entry_scrollbar_drag_scroll = panel_state.entry_scrollbar_drag_scroll;
    self.fs.filesystem_last_clicked_entry_index = panel_state.last_clicked_entry_index;
    self.fs.filesystem_last_click_ms = panel_state.last_click_ms;
    self.fs.filesystem_type_column_width = panel_state.type_column_width;
    self.fs.filesystem_modified_column_width = panel_state.modified_column_width;
    self.fs.filesystem_size_column_width = panel_state.size_column_width;
    self.fs.filesystem_column_resize_handle = panel_state.column_resize;
    self.fs.filesystem_preview_split_ratio = panel_state.preview_split_ratio;
    self.fs.filesystem_preview_split_dragging = panel_state.preview_split_dragging;
    if (action) |value| {
        self.performFilesystemPanelAction(value, path_label);
    }
}

pub fn drawFilesystemToolsPanel(self: anytype, manager: anytype, rect: anytype) void {
    _ = manager;
    const model = self.filesystemToolsPanelModel();
    const host = FilesystemToolsPanel.Host{
        .ctx = @ptrCast(self),
        .draw_text_trimmed = @import("../root.zig").launcherSettingsDrawTextTrimmed,
        .draw_text_input = @import("../root.zig").launcherSettingsDrawTextInput,
        .draw_button = @import("../root.zig").launcherSettingsDrawButton,
        .draw_surface_panel = @import("../root.zig").filesystemDrawSurfacePanel,
        .draw_text_wrapped = @import("../root.zig").filesystemDrawTextWrapped,
        .draw_rect = @import("../root.zig").filesystemDrawRect,
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
