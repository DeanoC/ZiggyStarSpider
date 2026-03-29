//! Devices panel host.
//! Pure draw logic; receives `self: anytype` (*App duck-typed) so this file
//! never imports root.zig and therefore has no circular dependency.

const std = @import("std");
const zui = @import("ziggy-ui");
const zcolors = zui.theme.colors;
const Rect = zui.core.Rect;
const Paint = zui.ui.theme_engine.style_sheet.Paint;

// ── Public entry point ────────────────────────────────────────────────────────

pub fn draw(self: anytype, manager: anytype, rect: anytype) void {
    _ = manager;
    const layout = self.panelLayoutMetrics();
    const inset = layout.inner_inset;
    const surfaces = self.sharedStyleSheet().surfaces;
    const bg = surfaces.surface orelse Paint{ .solid = self.theme.colors.background };
    const panel_rect = Rect{ .min = rect.min, .max = rect.max };
    self.drawPaintRect(panel_rect, bg);

    // Title bar
    const title_h = layout.button_height + inset * 1.4;
    const title_rect = Rect.fromXYWH(panel_rect.min[0], panel_rect.min[1], panel_rect.width(), title_h);
    const header_bg = zcolors.withAlpha(self.theme.colors.border, 60);
    self.drawFilledRect(title_rect, header_bg);
    self.drawTextTrimmed(
        panel_rect.min[0] + inset,
        panel_rect.min[1] + (title_h - layout.line_height) * 0.5,
        panel_rect.width() - inset * 2.0,
        "Devices",
        self.theme.colors.text_primary,
    );

    // Toggle buttons: Table / Tree
    const btn_w = 80.0 * self.ui_scale;
    const btn_h = layout.button_height;
    const btn_y = panel_rect.min[1] + (title_h - btn_h) * 0.5;
    const btn_gap = 4.0 * self.ui_scale;
    const table_btn_x = panel_rect.max[0] - inset - btn_w * 2.0 - btn_gap;
    const tree_btn_x = panel_rect.max[0] - inset - btn_w;

    if (self.drawButtonWidget(
        Rect.fromXYWH(table_btn_x, btn_y, btn_w, btn_h),
        "Table",
        .{ .variant = if (self.ws.node_topology_table_view) .primary else .secondary },
    )) {
        self.ws.node_topology_table_view = true;
    }
    if (self.drawButtonWidget(
        Rect.fromXYWH(tree_btn_x, btn_y, btn_w, btn_h),
        "Tree",
        .{ .variant = if (!self.ws.node_topology_table_view) .primary else .secondary },
    )) {
        self.ws.node_topology_table_view = false;
    }

    const content_rect = Rect.fromXYWH(
        panel_rect.min[0],
        panel_rect.min[1] + title_h,
        panel_rect.width(),
        panel_rect.height() - title_h,
    );

    if (self.ws.node_topology_table_view) {
        drawTableView(self, content_rect);
    } else {
        drawTreeView(self, content_rect);
    }
}

// ── Private helpers ───────────────────────────────────────────────────────────

fn drawTableView(self: anytype, rect: Rect) void {
    const layout = self.panelLayoutMetrics();
    const inset = layout.inner_inset;
    const row_h = layout.input_height;
    const row_gap = @max(1.0, layout.inner_inset * 0.15);
    const now_ms = std.time.milliTimestamp();

    // Header row
    const header_h = row_h;
    const hdr_bg = zcolors.withAlpha(self.theme.colors.border, 80);
    self.drawFilledRect(Rect.fromXYWH(rect.min[0], rect.min[1], rect.width(), header_h), hdr_bg);

    const col_status_w = 60.0 * self.ui_scale;
    const col_name_w = 160.0 * self.ui_scale;
    const col_id_w = 200.0 * self.ui_scale;
    const col_seen_w = 100.0 * self.ui_scale;
    var hx = rect.min[0] + inset;
    const hy = rect.min[1] + (header_h - layout.line_height) * 0.5;
    const hdr_color = zcolors.withAlpha(self.theme.colors.text_primary, 160);
    self.drawTextTrimmed(hx, hy, col_status_w - inset, "Status", hdr_color);
    hx += col_status_w;
    self.drawTextTrimmed(hx, hy, col_name_w - inset, "Name", hdr_color);
    hx += col_name_w;
    self.drawTextTrimmed(hx, hy, col_id_w - inset, "ID", hdr_color);
    hx += col_id_w;
    self.drawTextTrimmed(hx, hy, col_seen_w - inset, "Last Seen", hdr_color);

    var y = rect.min[1] + header_h + row_gap;

    if (self.ws.nodes.items.len == 0) {
        self.drawText(
            rect.min[0] + inset,
            y + inset,
            if (self.connection_state == .connected) "No devices registered." else "Not connected.",
            zcolors.withAlpha(self.theme.colors.text_primary, 100),
        );
        return;
    }

    for (self.ws.nodes.items, 0..) |node, idx| {
        if (y + row_h > rect.max[1]) break;
        const online = node.lease_expires_at_ms > now_ms;
        const selected = self.ws.node_topology_selected_index == idx;

        const row_rect = Rect.fromXYWH(rect.min[0], y, rect.width(), row_h);
        if (selected) {
            self.drawFilledRect(row_rect, zcolors.withAlpha(self.theme.colors.primary, 40));
        } else if (idx % 2 == 1) {
            self.drawFilledRect(row_rect, zcolors.withAlpha(self.theme.colors.border, 20));
        }

        if (self.mouse_released and row_rect.contains(.{ self.mouse_x, self.mouse_y })) {
            self.ws.node_topology_selected_index = if (selected) null else idx;
        }

        const tx = rect.min[0] + inset;
        const ty = y + (row_h - layout.line_height) * 0.5;

        // Status dot
        const dot_color = if (online) zcolors.rgba(36, 174, 100, 255) else zcolors.rgba(220, 80, 60, 255);
        const dot_size = layout.line_height * 0.7;
        self.drawFilledRect(Rect.fromXYWH(tx + (col_status_w - inset - dot_size) * 0.5, ty + (layout.line_height - dot_size) * 0.5, dot_size, dot_size), dot_color);

        // Name
        self.drawTextTrimmed(tx + col_status_w, ty, col_name_w - inset, node.node_name, self.theme.colors.text_primary);

        // ID (dimmed)
        self.drawTextTrimmed(tx + col_status_w + col_name_w, ty, col_id_w - inset, node.node_id, zcolors.withAlpha(self.theme.colors.text_primary, 140));

        // Last seen
        const age_ms = now_ms - node.last_seen_ms;
        var age_buf: [32]u8 = undefined;
        const age_str = if (node.last_seen_ms == 0) "unknown" else if (age_ms < 1000) "< 1s" else if (age_ms < 60_000) std.fmt.bufPrint(&age_buf, "{d}s ago", .{@divTrunc(age_ms, 1000)}) catch "?" else if (age_ms < 3_600_000) std.fmt.bufPrint(&age_buf, "{d}m ago", .{@divTrunc(age_ms, 60_000)}) catch "?" else std.fmt.bufPrint(&age_buf, "{d}h ago", .{@divTrunc(age_ms, 3_600_000)}) catch "?";
        self.drawTextTrimmed(tx + col_status_w + col_name_w + col_id_w, ty, col_seen_w - inset, age_str, zcolors.withAlpha(self.theme.colors.text_primary, 160));

        y += row_h + row_gap;
    }
}

fn drawTreeView(self: anytype, rect: Rect) void {
    const layout = self.panelLayoutMetrics();
    const inset = layout.inner_inset;
    const row_h = layout.input_height;
    const row_gap = @max(1.0, layout.inner_inset * 0.15);
    const indent = 20.0 * self.ui_scale;
    const now_ms = std.time.milliTimestamp();

    var y = rect.min[1] + inset * 0.5;

    // Workspace section header
    const ws_name = if (self.ws.selected_workspace_detail) |*d| d.name else "(no workspace selected)";
    const ws_header_color = zcolors.withAlpha(self.theme.colors.text_primary, 180);
    self.drawText(rect.min[0] + inset, y + (row_h - layout.line_height) * 0.5, ws_name, ws_header_color);
    y += row_h + row_gap;

    // Track which node IDs appear in mounts so we can show unmounted nodes separately
    var mounted_node_ids_buf: [64][]const u8 = undefined;
    var mounted_node_ids_len: usize = 0;

    if (self.ws.selected_workspace_detail) |*detail| {
        for (detail.mounts.items) |*mount| {
            if (y + row_h > rect.max[1]) break;
            const node_online: bool = blk: {
                for (self.ws.nodes.items) |n| {
                    if (std.mem.eql(u8, n.node_id, mount.node_id)) {
                        break :blk n.lease_expires_at_ms > now_ms;
                    }
                }
                break :blk false;
            };
            const dot_color = if (node_online) zcolors.rgba(36, 174, 100, 255) else zcolors.rgba(220, 80, 60, 255);
            const dot_size = layout.line_height * 0.6;
            const tx = rect.min[0] + inset + indent;
            const ty = y + (row_h - layout.line_height) * 0.5;
            self.drawFilledRect(Rect.fromXYWH(tx, ty + (layout.line_height - dot_size) * 0.5, dot_size, dot_size), dot_color);
            var line_buf: [256]u8 = undefined;
            const node_label = mount.node_name orelse mount.node_id;
            const line = std.fmt.bufPrint(&line_buf, "{s}  →  {s}", .{ mount.mount_path, node_label }) catch mount.mount_path;
            self.drawTextTrimmed(tx + dot_size + 6.0 * self.ui_scale, ty, rect.max[0] - tx - dot_size - inset, line, self.theme.colors.text_primary);
            if (mounted_node_ids_len < 64) { mounted_node_ids_buf[mounted_node_ids_len] = mount.node_id; mounted_node_ids_len += 1; }
            y += row_h + row_gap;
        }
    }

    // Unmounted nodes section
    var has_unmounted = false;
    for (self.ws.nodes.items) |node| {
        var is_mounted = false;
        for (mounted_node_ids_buf[0..mounted_node_ids_len]) |id| {
            if (std.mem.eql(u8, id, node.node_id)) {
                is_mounted = true;
                break;
            }
        }
        if (!is_mounted) {
            if (!has_unmounted) {
                if (y + row_h * 1.5 > rect.max[1]) break;
                y += row_gap * 3.0;
                self.drawText(rect.min[0] + inset, y + (row_h - layout.line_height) * 0.5, "Devices without drives:", zcolors.withAlpha(self.theme.colors.text_primary, 140));
                y += row_h + row_gap;
                has_unmounted = true;
            }
            if (y + row_h > rect.max[1]) break;
            const online = node.lease_expires_at_ms > now_ms;
            const dot_color = if (online) zcolors.rgba(36, 174, 100, 255) else zcolors.rgba(220, 80, 60, 255);
            const dot_size = layout.line_height * 0.6;
            const tx = rect.min[0] + inset + indent;
            const ty = y + (row_h - layout.line_height) * 0.5;
            self.drawFilledRect(Rect.fromXYWH(tx, ty + (layout.line_height - dot_size) * 0.5, dot_size, dot_size), dot_color);
            var line_buf: [256]u8 = undefined;
            const line = std.fmt.bufPrint(&line_buf, "{s}  ({s})", .{ node.node_name, node.node_id }) catch node.node_name;
            self.drawTextTrimmed(tx + dot_size + 6.0 * self.ui_scale, ty, rect.max[0] - tx - dot_size - inset, line, self.theme.colors.text_primary);
            y += row_h + row_gap;
        }
    }

    if (self.ws.nodes.items.len == 0) {
        self.drawText(
            rect.min[0] + inset,
            y,
            if (self.connection_state == .connected) "No devices registered." else "Not connected.",
            zcolors.withAlpha(self.theme.colors.text_primary, 100),
        );
    }
}
