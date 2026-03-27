//! Dashboard panel host.
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
    self.requestDashboardRefresh(false);

    const panel_rect = Rect{ .min = rect.min, .max = rect.max };
    self.drawSurfacePanel(panel_rect);

    const layout = self.panelLayoutMetrics();
    const pad = layout.inset;
    const inner_w = @max(1.0, panel_rect.width() - pad * 2.0);
    const line_h = self.textLineHeight();
    const button_h = layout.button_height;

    // Refresh button (top-right)
    const refresh_label = if (self.ws.workspace_op_busy) "Refreshing..." else "Refresh";
    const refresh_w = @max(96.0 * self.ui_scale, self.measureTextFast(refresh_label) + pad * 1.4);
    const refresh_rect = Rect.fromXYWH(
        panel_rect.max[0] - pad - refresh_w,
        panel_rect.min[1] + pad,
        refresh_w,
        button_h,
    );
    if (self.drawButtonWidget(refresh_rect, refresh_label, .{
        .variant = .secondary,
        .disabled = self.connection_state != .connected or self.ws.workspace_op_busy,
    })) {
        self.requestDashboardRefresh(true);
    }

    // Title
    self.drawTextTrimmed(
        panel_rect.min[0] + pad,
        panel_rect.min[1] + pad,
        @max(1.0, refresh_rect.min[0] - panel_rect.min[0] - pad * 1.6),
        "Dashboard",
        self.theme.colors.text_primary,
    );

    // Status subtitle
    var status_buf: [192]u8 = undefined;
    const status_text = switch (self.connection_state) {
        .connected => blk: {
            if (self.ws.active_workspace_id) |ws_id| {
                break :blk std.fmt.bufPrint(&status_buf, "Connected  |  active workspace: {s}", .{ws_id}) catch "Connected";
            }
            break :blk @as([]const u8, "Connected  |  no active workspace");
        },
        .connecting => "Connecting...",
        .disconnected => "Disconnected  |  open File menu to connect",
        .error_state => "Connection error",
    };
    self.drawTextTrimmed(
        panel_rect.min[0] + pad,
        panel_rect.min[1] + pad + line_h + layout.row_gap * 0.35,
        inner_w,
        status_text,
        self.theme.colors.text_secondary,
    );

    // ── Stat cards ──────────────────────────────────────────────────────
    const cards_top = panel_rect.min[1] + pad + line_h * 2.0 + layout.row_gap;
    const card_gap = @max(layout.inner_inset, 10.0 * self.ui_scale);
    const card_h = @max(84.0 * self.ui_scale, button_h * 2.4);
    const card_w = @max(80.0, (inner_w - card_gap * 2.0) / 3.0);

    // Workspaces card
    var ws_val_buf: [16]u8 = undefined;
    const ws_val = std.fmt.bufPrint(&ws_val_buf, "{d}", .{self.ws.projects.items.len}) catch "?";
    self.drawMissionSummaryCard(
        Rect.fromXYWH(panel_rect.min[0] + pad, cards_top, card_w, card_h),
        self.theme.colors.primary,
        "Workspaces",
        ws_val,
        "total",
    );

    // Nodes card
    var node_val_buf: [16]u8 = undefined;
    const node_val = std.fmt.bufPrint(&node_val_buf, "{d}", .{self.ws.nodes.items.len}) catch "?";
    const node_accent = if (self.ws.nodes.items.len > 0) zcolors.rgba(36, 174, 100, 255) else self.theme.colors.border;
    self.drawMissionSummaryCard(
        Rect.fromXYWH(panel_rect.min[0] + pad + card_w + card_gap, cards_top, card_w, card_h),
        node_accent,
        "Nodes",
        node_val,
        if (self.connection_state == .connected) "online" else "offline",
    );

    // Active workspace card
    const active_accent = if (self.ws.active_workspace_id != null) zcolors.rgba(120, 60, 200, 255) else self.theme.colors.border;
    const active_val = if (self.ws.active_workspace_id != null) "Active" else "None";
    const active_summary = self.ws.active_workspace_id orelse "(none)";
    self.drawMissionSummaryCard(
        Rect.fromXYWH(panel_rect.min[0] + pad + (card_w + card_gap) * 2.0, cards_top, card_w, card_h),
        active_accent,
        "Active Workspace",
        active_val,
        active_summary,
    );

    // ── Workspace list ───────────────────────────────────────────────────
    const list_top = cards_top + card_h + layout.row_gap;
    const list_rect = Rect.fromXYWH(panel_rect.min[0] + pad, list_top, inner_w, @max(1.0, panel_rect.max[1] - list_top - pad));
    drawWorkspaceList(self, list_rect, pad, line_h, layout);
}

// ── Private helpers ───────────────────────────────────────────────────────────

fn drawWorkspaceList(self: anytype, rect: Rect, pad: f32, line_h: f32, layout: PanelLayoutMetrics) void {
    self.drawSurfacePanel(rect);
    const row_gap = @max(4.0 * self.ui_scale, layout.inner_inset * 0.5);
    const row_h = @max(line_h * 2.2, 44.0 * self.ui_scale);
    const button_h = layout.button_height;
    const col_status_w = @max(80.0 * self.ui_scale, self.measureTextFast("warming") + pad * 1.4);
    const col_action_w = @max(72.0 * self.ui_scale, self.measureTextFast("Open") + pad * 1.4);
    const name_w = @max(1.0, rect.width() - pad * 2.0 - col_status_w - col_action_w - pad * 2.0);

    // Header
    const header_y = rect.min[1] + pad;
    self.drawTextTrimmed(rect.min[0] + pad, header_y, name_w, "Workspaces", self.theme.colors.text_primary);

    if (self.ws.projects.items.len == 0) {
        const empty_msg = if (self.connection_state == .connected)
            "No workspaces found."
        else
            "Connect to load workspaces.";
        self.drawTextTrimmed(rect.min[0] + pad, header_y + line_h + row_gap, rect.width() - pad * 2.0, empty_msg, self.theme.colors.text_secondary);
        return;
    }

    var row_y = header_y + line_h + row_gap;
    const available_h = @max(1.0, rect.max[1] - row_y - pad);
    const max_rows = @as(usize, @intFromFloat(@max(1.0, available_h / (row_h + row_gap))));

    for (self.ws.projects.items, 0..) |project, idx| {
        if (idx >= max_rows) break;
        const is_active = if (self.ws.active_workspace_id) |aws| std.mem.eql(u8, aws, project.id) else false;
        const row_bg = if (is_active) Rect.fromXYWH(rect.min[0], row_y, rect.width(), row_h) else null;
        if (row_bg) |bg| {
            self.drawFilledRect(bg, zcolors.rgba(120, 60, 200, 20));
        }

        // Name + ID
        const name_x = rect.min[0] + pad;
        const name_color = if (is_active) self.theme.colors.primary else self.theme.colors.text_primary;
        self.drawTextTrimmed(name_x, row_y + (row_h - line_h * 2.0) * 0.5, name_w, project.name, name_color);
        self.drawTextTrimmed(name_x, row_y + (row_h - line_h * 2.0) * 0.5 + line_h, name_w, project.id, self.theme.colors.text_secondary);

        // Status badge
        const status_x = rect.min[0] + pad + name_w + pad;
        self.drawTextTrimmed(status_x, row_y + (row_h - line_h) * 0.5, col_status_w, project.status, self.theme.colors.text_secondary);

        // Open button
        const btn_x = status_x + col_status_w + pad * 0.5;
        const btn_y = row_y + (row_h - button_h) * 0.5;
        const open_btn = Rect.fromXYWH(btn_x, btn_y, col_action_w, button_h);
        const open_label = if (is_active) "Active" else "Open";
        if (self.drawButtonWidget(open_btn, open_label, .{
            .variant = if (is_active) .primary else .secondary,
            .disabled = is_active or self.connection_state != .connected,
        })) {
            if (self.config.setSelectedWorkspace(project.id)) |_| {} else |_| {}
            self.activateSelectedWorkspace() catch {};
        }

        row_y += row_h + row_gap;
    }
}
