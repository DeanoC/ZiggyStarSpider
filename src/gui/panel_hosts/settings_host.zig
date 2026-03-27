// settings_host.zig — Settings panel draw functions.

const std = @import("std");
const zui = @import("ziggy-ui");
const zui_panels = @import("ziggy-ui-panels");
const control_plane = @import("control_plane");
const workspace_types = control_plane.workspace_types;
const panels_bridge = @import("../panels_bridge.zig");

const workspace = zui.ui.workspace;
const panel_manager = zui.ui.panel_manager;
const form_layout = zui.ui.layout.form_layout;
const zcolors = zui.theme.colors;

const Rect = zui.core.Rect;
const ui_draw_context = zui.ui.draw_context;
const UiRect = ui_draw_context.Rect;

const LauncherSettingsPanel = zui_panels.launcher_settings_panel;

// Note: launcherSettingsDrawFormSectionTitle, launcherSettingsDrawFormFieldLabel,
// launcherSettingsDrawTextInput, launcherSettingsDrawButton, launcherSettingsDrawLabel,
// launcherSettingsDrawTextTrimmed, launcherSettingsDrawVerticalScrollbar,
// settingsFocusFieldToExternal, settingsFocusFieldFromExternal, isSettingsPanelFocusField
// must be provided by the including namespace (e.g. via usingnamespace in root.zig).

pub fn drawSettingsPanel(self: anytype, manager: anytype, rect: anytype) void {
    const root = @import("../root.zig");
    if (self.ui_stage == .workspace) {
        self.drawWorkspaceSettingsPanel(rect);
        return;
    }
    const host = LauncherSettingsPanel.Host{
        .ctx = @ptrCast(self),
        .draw_form_section_title = root.launcherSettingsDrawFormSectionTitle,
        .draw_form_field_label = root.launcherSettingsDrawFormFieldLabel,
        .draw_text_input = root.launcherSettingsDrawTextInput,
        .draw_button = root.launcherSettingsDrawButton,
        .draw_label = root.launcherSettingsDrawLabel,
        .draw_text_trimmed = root.launcherSettingsDrawTextTrimmed,
        .draw_vertical_scrollbar = root.launcherSettingsDrawVerticalScrollbar,
    };
    const panel_rect = Rect{ .min = rect.min, .max = rect.max };
    var panel_state = LauncherSettingsPanel.State{
        .focused_field = root.settingsFocusFieldToExternal(self.settings_panel.focused_field),
        .scroll_y = self.settings_panel.settings_scroll_y,
    };
    var model = self.launcherSettingsModel();
    var meta_buf: [256]u8 = undefined;
    model.theme_pack_meta_text = self.themePackMetaText(&meta_buf);
    var quick_buf: [4]panels_bridge.ThemePackQuickPickView = undefined;
    var recent_buf: [8]panels_bridge.ThemePackQuickPickView = undefined;
    var available_buf: [16]panels_bridge.ThemePackQuickPickView = undefined;
    const picks = self.populateThemePackQuickPicks(&quick_buf, &recent_buf, &available_buf);
    model.theme_pack_quick_picks = picks.quick;
    model.theme_pack_recent = picks.recent;
    model.theme_pack_available = picks.available;
    const action = LauncherSettingsPanel.draw(
        host,
        panel_rect,
        self.panelLayoutMetrics(),
        self.ui_scale,
        .{
            .text_primary = self.theme.colors.text_primary,
            .text_secondary = self.theme.colors.text_secondary,
        },
        model,
        .{
            .server_url = self.settings_panel.server_url.items,
            .default_session = self.settings_panel.default_session.items,
            .default_agent = self.settings_panel.default_agent.items,
            .theme_pack = self.settings_panel.theme_pack.items,
        },
        .{
            .mouse_x = self.mouse_x,
            .mouse_y = self.mouse_y,
            .mouse_released = self.mouse_released,
        },
        &panel_state,
        .launcher,
    );
    const mapped_focus = root.settingsFocusFieldFromExternal(panel_state.focused_field);
    if (mapped_focus != .none or root.isSettingsPanelFocusField(self.settings_panel.focused_field)) {
        self.settings_panel.focused_field = mapped_focus;
    }
    self.settings_panel.settings_scroll_y = panel_state.scroll_y;
    if (action) |value| {
        self.performLauncherSettingsAction(manager, value);
    }
}

pub fn drawWorkspaceSettingsPanel(self: anytype, rect: anytype) void {
    const root = @import("../root.zig");
    const host = LauncherSettingsPanel.Host{
        .ctx = @ptrCast(self),
        .draw_form_section_title = root.launcherSettingsDrawFormSectionTitle,
        .draw_form_field_label = root.launcherSettingsDrawFormFieldLabel,
        .draw_text_input = root.launcherSettingsDrawTextInput,
        .draw_button = root.launcherSettingsDrawButton,
        .draw_label = root.launcherSettingsDrawLabel,
        .draw_text_trimmed = root.launcherSettingsDrawTextTrimmed,
        .draw_vertical_scrollbar = root.launcherSettingsDrawVerticalScrollbar,
    };
    const panel_rect = Rect{ .min = rect.min, .max = rect.max };
    var panel_state = LauncherSettingsPanel.State{
        .focused_field = root.settingsFocusFieldToExternal(self.settings_panel.focused_field),
        .scroll_y = self.settings_panel.settings_scroll_y,
    };
    var model = self.launcherSettingsModel();
    var meta_buf: [256]u8 = undefined;
    model.theme_pack_meta_text = self.themePackMetaText(&meta_buf);
    var quick_buf: [4]panels_bridge.ThemePackQuickPickView = undefined;
    var recent_buf: [8]panels_bridge.ThemePackQuickPickView = undefined;
    var available_buf: [16]panels_bridge.ThemePackQuickPickView = undefined;
    const picks = self.populateThemePackQuickPicks(&quick_buf, &recent_buf, &available_buf);
    model.theme_pack_quick_picks = picks.quick;
    model.theme_pack_recent = picks.recent;
    model.theme_pack_available = picks.available;
    const action = LauncherSettingsPanel.draw(
        host,
        panel_rect,
        self.panelLayoutMetrics(),
        self.ui_scale,
        .{
            .text_primary = self.theme.colors.text_primary,
            .text_secondary = self.theme.colors.text_secondary,
        },
        model,
        .{
            .theme_pack = self.settings_panel.theme_pack.items,
        },
        .{
            .mouse_x = self.mouse_x,
            .mouse_y = self.mouse_y,
            .mouse_released = self.mouse_released,
        },
        &panel_state,
        .workspace,
    );
    const mapped_focus = root.settingsFocusFieldFromExternal(panel_state.focused_field);
    if (mapped_focus != .none or root.isSettingsPanelFocusField(self.settings_panel.focused_field)) {
        self.settings_panel.focused_field = mapped_focus;
    }
    self.settings_panel.settings_scroll_y = panel_state.scroll_y;
    if (action) |value| {
        self.performLauncherSettingsAction(&self.manager, value);
    }
}
