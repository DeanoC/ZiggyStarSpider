// terminal_host.zig — Terminal panel draw functions.

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

const TerminalPanel = zui_panels.terminal_panel;
const TerminalOutputPanel = zui_panels.terminal_output_panel;

const TERMINAL_BACKEND_KIND = if (@hasDecl(@import("build_options"), "terminal_backend"))
    @import("build_options").terminal_backend
else
    "plain";

fn terminalFocusFieldToExternal(field: anytype) TerminalPanel.FocusField {
    return switch (field) {
        .terminal_command_input => .command_input,
        else => .none,
    };
}

fn terminalFocusFieldFromExternal(field: TerminalPanel.FocusField) @import("../root.zig").SettingsFocusField {
    return switch (field) {
        .command_input => .terminal_command_input,
        .none => .none,
    };
}

fn isTerminalPanelFocusField(field: anytype) bool {
    return switch (field) {
        .terminal_command_input => true,
        else => false,
    };
}

pub fn drawTerminalPanel(self: anytype, manager: anytype, rect: anytype) void {
    _ = manager;
    const host = TerminalPanel.Host{
        .ctx = @ptrCast(self),
        .draw_label = @import("../root.zig").launcherSettingsDrawLabel,
        .draw_text_trimmed = @import("../root.zig").launcherSettingsDrawTextTrimmed,
        .draw_text_input = @import("../root.zig").launcherSettingsDrawTextInput,
        .draw_button = @import("../root.zig").launcherSettingsDrawButton,
        .draw_surface_panel = @import("../root.zig").filesystemDrawSurfacePanel,
        .draw_output = @import("../root.zig").terminalDrawOutput,
    };
    var panel_state = TerminalPanel.State{
        .focused_field = terminalFocusFieldToExternal(self.settings_panel.focused_field),
    };
    var owned_view = terminalPanelViewOwned(self);
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
        terminalPanelModel(self),
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
    if (action) |value| performTerminalPanelAction(self, value);
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
    self: anytype,
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
    self: anytype,
    style: terminal_render_backend.Style,
) struct { fg: [4]f32, bg: ?[4]f32 } {
    var fg = terminalColorToRgba(self, style.fg, self.theme.colors.text_primary);
    var bg_opt: ?[4]f32 = if (style.bg == .default)
        null
    else
        terminalColorToRgba(self, style.bg, self.theme.colors.background);

    if (style.inverse) {
        const swapped_fg = if (bg_opt) |bg| bg else self.theme.colors.background;
        const swapped_bg = terminalColorToRgba(self, style.fg, self.theme.colors.text_primary);
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

fn nextUtf8Boundary(text: []const u8, index: usize) usize {
    if (index >= text.len) return text.len;
    var i = index + 1;
    while (i < text.len and (text[i] & 0xC0) == 0x80) : (i += 1) {}
    return i;
}

fn fitTextToWidth(self: anytype, text: []const u8, max_w: f32) usize {
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

pub fn drawTerminalStyledLine(
    self: anytype,
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
        const fit_end = fitTextToWidth(self, run_text, remaining_w);
        if (fit_end == 0) break;
        const segment = run_text[0..fit_end];
        const colors = terminalStyleColors(self, style);
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

fn terminalPanelModel(self: anytype) panels_bridge.TerminalPanelModel {
    return .{
        .connected = self.connection_state == .connected,
        .has_session = self.terminal.terminal_session_id != null,
        .auto_poll = self.terminal.terminal_auto_poll,
        .has_input = std.mem.trim(u8, self.terminal.terminal_input.items, " \t\r\n").len > 0,
        .has_output = self.terminal.terminal_backend.text().len > 0,
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

fn terminalPanelViewOwned(self: anytype) OwnedTerminalPanelView {
    const backend_line = std.fmt.allocPrint(
        self.allocator,
        "Backend: {s} (selected: {s}, build default: {s})",
        .{
            self.terminal.terminal_backend.label(),
            terminal_render_backend.Backend.kindName(self.terminal.terminal_backend_kind),
            TERMINAL_BACKEND_KIND,
        },
    ) catch null;
    const session_line = if (self.terminal.terminal_session_id) |id|
        std.fmt.allocPrint(self.allocator, "Session: {s}", .{id}) catch null
    else
        self.allocator.dupe(u8, "Session: (not started)") catch null;
    return .{
        .view = .{
            .title = "Terminal",
            .backend_line = backend_line orelse "Backend: unknown",
            .backend_detail = self.terminal.terminal_backend.statusDetail(),
            .session_line = session_line orelse "Session: (unknown)",
            .status_text = self.terminal.terminal_status,
            .error_text = self.terminal.terminal_error,
            .input_text = self.terminal.terminal_input.items,
            .start_label = if (self.terminal.terminal_session_id == null) "Start" else "Restart",
        },
        .backend_line = backend_line,
        .session_line = session_line,
    };
}

fn performTerminalPanelAction(self: anytype, action: panels_bridge.TerminalPanelAction) void {
    switch (action) {
        .start_or_restart => {
            if (self.terminal.terminal_session_id != null) {
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
            self.terminal.terminal_backend.clear(self.allocator);
            self.clearTerminalError();
            self.setTerminalStatus("Output cleared");
        },
        .toggle_auto_poll => {
            self.terminal.terminal_auto_poll = !self.terminal.terminal_auto_poll;
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
            self.copyTextToClipboard(self.terminal.terminal_backend.text()) catch {};
            self.setTerminalStatus("Copied terminal output");
        },
    }
}
