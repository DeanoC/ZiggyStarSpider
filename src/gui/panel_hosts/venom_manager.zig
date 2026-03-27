//! Venom Manager panel host.
//! Pure draw logic; receives `self: anytype` (*App duck-typed) so this file
//! never imports root.zig and therefore has no circular dependency.

const std = @import("std");
const zui = @import("ziggy-ui");
const zcolors = zui.theme.colors;
const Rect = zui.core.Rect;
const PanelLayoutMetrics = zui.ui.layout.form_layout.Metrics;

// ── Public entry point ────────────────────────────────────────────────────────

pub fn draw(self: anytype, manager: anytype, rect: anytype) void {
    _ = manager;
    self.requestVenomRefresh(false);

    const panel_rect = Rect{ .min = rect.min, .max = rect.max };
    self.drawSurfacePanel(panel_rect);

    const layout = self.panelLayoutMetrics();
    const pad = layout.inset;
    const inner_w = @max(1.0, panel_rect.width() - pad * 2.0);
    const line_h = self.textLineHeight();
    const button_h = layout.button_height;

    // Refresh button (top-right)
    const refresh_label = if (self.ws.venom_refresh_busy) "Loading..." else "Refresh";
    const refresh_w = @max(96.0 * self.ui_scale, self.measureTextFast(refresh_label) + pad * 1.4);
    const refresh_rect = Rect.fromXYWH(
        panel_rect.max[0] - pad - refresh_w,
        panel_rect.min[1] + pad,
        refresh_w,
        button_h,
    );
    if (self.drawButtonWidget(refresh_rect, refresh_label, .{
        .variant = .secondary,
        .disabled = self.connection_state != .connected or self.ws.venom_refresh_busy,
    })) {
        self.requestVenomRefresh(true);
    }

    // Title
    self.drawTextTrimmed(
        panel_rect.min[0] + pad,
        panel_rect.min[1] + pad,
        @max(1.0, refresh_rect.min[0] - panel_rect.min[0] - pad * 1.6),
        "Venoms",
        self.theme.colors.text_primary,
    );

    // Status subtitle
    var subtitle_buf: [128]u8 = undefined;
    const subtitle: []const u8 = if (self.ws.venom_last_error) |err_msg|
        err_msg
    else if (self.ws.venom_entries.items.len == 0 and self.connection_state == .connected)
        "No venoms found  |  check active workspace has venoms configured"
    else if (self.connection_state != .connected)
        "Disconnected  |  connect to load venoms"
    else
        std.fmt.bufPrint(&subtitle_buf, "{d} venoms  (global + workspace + agent)", .{self.ws.venom_entries.items.len}) catch "Venoms loaded";

    self.drawTextTrimmed(
        panel_rect.min[0] + pad,
        panel_rect.min[1] + pad + line_h + layout.row_gap * 0.35,
        inner_w,
        subtitle,
        if (self.ws.venom_last_error != null) zcolors.rgba(220, 80, 60, 255) else self.theme.colors.text_secondary,
    );

    // ── Split: list (left) + detail (right) ────────────────────────────
    const content_top = panel_rect.min[1] + pad + line_h * 2.0 + layout.row_gap;
    const content_h = @max(1.0, panel_rect.max[1] - content_top - pad);
    const list_w = @max(220.0 * self.ui_scale, inner_w * 0.38);
    const gap = @max(layout.inner_inset, 8.0 * self.ui_scale);
    const list_rect = Rect.fromXYWH(panel_rect.min[0] + pad, content_top, list_w, content_h);
    const detail_rect = Rect.fromXYWH(list_rect.max[0] + gap, content_top, @max(1.0, panel_rect.max[0] - list_rect.max[0] - pad - gap), content_h);

    drawListPane(self, list_rect, pad, line_h, layout);
    drawDetailPane(self, detail_rect, pad, line_h);
}

// ── Private helpers ───────────────────────────────────────────────────────────

fn drawListPane(self: anytype, rect: Rect, pad: f32, line_h: f32, layout: PanelLayoutMetrics) void {
    self.drawSurfacePanel(rect);
    const row_gap = @max(3.0 * self.ui_scale, layout.inner_inset * 0.3);
    const row_h = @max(line_h * 2.0, 40.0 * self.ui_scale);
    const badge_w = @max(72.0 * self.ui_scale, self.measureTextFast("workspace") + pad * 0.8);
    const name_w = @max(1.0, rect.width() - pad * 2.0 - badge_w - pad * 0.5);

    // Header
    self.drawTextTrimmed(rect.min[0] + pad, rect.min[1] + pad, rect.width() - pad * 2.0, "Venom Bindings", self.theme.colors.text_primary);

    if (self.ws.venom_entries.items.len == 0) {
        self.drawTextTrimmed(rect.min[0] + pad, rect.min[1] + pad + line_h + pad, rect.width() - pad * 2.0, "(none)", self.theme.colors.text_secondary);
        return;
    }

    var y = rect.min[1] + pad + line_h + row_gap;
    const avail_h = @max(1.0, rect.max[1] - y - pad);
    const max_rows = @as(usize, @intFromFloat(@max(1.0, avail_h / (row_h + row_gap))));

    var current_scope: ?@TypeOf(self.ws.venom_entries.items[0].scope) = null;
    var drawn: usize = 0;
    for (self.ws.venom_entries.items, 0..) |entry, idx| {
        if (drawn >= max_rows) break;

        // Scope separator header
        if (current_scope == null or current_scope.? != entry.scope) {
            current_scope = entry.scope;
            self.drawTextTrimmed(rect.min[0] + pad, y, rect.width() - pad * 2.0, entry.scope.label(), entry.scope.color());
            y += line_h + row_gap * 0.5;
            drawn += 1;
            if (drawn >= max_rows) break;
        }

        const is_selected = self.ws.venom_selected_index != null and self.ws.venom_selected_index.? == idx;
        const row_rect = Rect.fromXYWH(rect.min[0], y, rect.width(), row_h);
        const hovered = row_rect.contains(.{ self.mouse_x, self.mouse_y });
        const fill = if (is_selected)
            zcolors.withAlpha(self.theme.colors.primary, 0.16)
        else if (hovered)
            zcolors.withAlpha(self.theme.colors.primary, 0.07)
        else
            zcolors.withAlpha(self.theme.colors.surface, 0.0);
        if (is_selected or hovered) self.drawFilledRect(row_rect, fill);

        // Venom ID
        const name_x = rect.min[0] + pad;
        self.drawTextTrimmed(name_x, y + (row_h - line_h * 2.0) * 0.5, name_w, entry.venom_id, if (is_selected) self.theme.colors.primary else self.theme.colors.text_primary);

        // Provider node (second line)
        const provider_label = entry.provider_node_id orelse "(no node)";
        self.drawTextTrimmed(name_x, y + (row_h - line_h * 2.0) * 0.5 + line_h, name_w, provider_label, self.theme.colors.text_secondary);

        // Scope badge (right)
        const badge_x = rect.min[0] + pad + name_w + pad * 0.5;
        const badge_rect = Rect.fromXYWH(badge_x, y + (row_h - line_h) * 0.5, badge_w, line_h);
        self.drawFilledRect(badge_rect, zcolors.withAlpha(entry.scope.color(), 0.15));
        self.drawTextTrimmed(badge_rect.min[0] + pad * 0.4, badge_rect.min[1], badge_w, entry.scope.label(), entry.scope.color());

        if (self.mouse_released and row_rect.contains(.{ self.mouse_x, self.mouse_y })) {
            self.ws.venom_selected_index = idx;
        }

        y += row_h + row_gap;
        drawn += 1;
    }

    if (self.ws.venom_entries.items.len > drawn) {
        var more_buf: [48]u8 = undefined;
        const more = std.fmt.bufPrint(&more_buf, "...and {d} more", .{self.ws.venom_entries.items.len - drawn}) catch "...";
        self.drawTextTrimmed(rect.min[0] + pad, rect.max[1] - pad - line_h, rect.width() - pad * 2.0, more, self.theme.colors.text_secondary);
    }
}

fn drawDetailPane(self: anytype, rect: Rect, pad: f32, line_h: f32) void {
    self.drawSurfacePanel(rect);
    const idx = self.ws.venom_selected_index orelse {
        self.drawTextTrimmed(rect.min[0] + pad, rect.min[1] + pad, rect.width() - pad * 2.0, "Select a venom to view details", self.theme.colors.text_secondary);
        return;
    };
    if (idx >= self.ws.venom_entries.items.len) {
        self.ws.venom_selected_index = null;
        return;
    }
    const entry = self.ws.venom_entries.items[idx];
    const row_gap = pad * 0.4;
    var y = rect.min[1] + pad;

    // Title (venom_id)
    self.drawTextTrimmed(rect.min[0] + pad, y, rect.width() - pad * 2.0, entry.venom_id, self.theme.colors.text_primary);
    y += line_h + row_gap;

    // Scope accent bar
    const accent_rect = Rect.fromXYWH(rect.min[0], rect.min[1], @max(3.0, 4.0 * self.ui_scale), rect.height());
    self.drawFilledRect(accent_rect, entry.scope.color());

    // Field rows
    const detail_rows = [_][2][]const u8{
        .{ "Scope", entry.scope.label() },
        .{ "Venom path", entry.venom_path },
        .{ "Provider node", entry.provider_node_id orelse "(none)" },
        .{ "Endpoint path", entry.endpoint_path orelse "(none)" },
        .{ "Invoke path", entry.invoke_path orelse "(none)" },
    };
    const label_w = @max(100.0 * self.ui_scale, self.measureTextFast("Provider node") + pad);
    const value_w = @max(1.0, rect.width() - pad * 2.0 - label_w);
    for (detail_rows) |pair| {
        if (y + line_h > rect.max[1] - pad) break;
        self.drawTextTrimmed(rect.min[0] + pad, y, label_w, pair[0], self.theme.colors.text_secondary);
        self.drawTextTrimmed(rect.min[0] + pad + label_w, y, value_w, pair[1], self.theme.colors.text_primary);
        y += line_h + row_gap;
    }
}
