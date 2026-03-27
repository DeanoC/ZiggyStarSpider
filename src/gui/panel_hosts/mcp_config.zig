//! MCP Config panel host.
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
        panel_rect.width() * 0.6,
        "MCP Servers",
        self.theme.colors.text_primary,
    );

    // Refresh button
    const btn_w = 80.0 * self.ui_scale;
    const btn_h = layout.button_height;
    const btn_y = panel_rect.min[1] + (title_h - btn_h) * 0.5;
    if (self.drawButtonWidget(
        Rect.fromXYWH(panel_rect.max[0] - inset - btn_w, btn_y, btn_w, btn_h),
        "Refresh",
        .{ .variant = .secondary, .disabled = self.connection_state != .connected },
    )) {
        self.refreshMcpConfig();
    }

    const content_rect = Rect.fromXYWH(panel_rect.min[0], panel_rect.min[1] + title_h, panel_rect.width(), panel_rect.height() - title_h);

    // Auto-load on first open
    if (self.ws.mcp_last_refresh_ms == 0 and self.connection_state == .connected) {
        self.refreshMcpConfig();
    }

    // Error bar
    var content_top = content_rect.min[1];
    if (self.ws.mcp_last_error) |err_msg| {
        const err_h = layout.input_height;
        self.drawFilledRect(Rect.fromXYWH(content_rect.min[0], content_top, content_rect.width(), err_h), zcolors.rgba(180, 40, 40, 200));
        self.drawTextTrimmed(content_rect.min[0] + inset, content_top + (err_h - layout.line_height) * 0.5, content_rect.width() - inset * 2.0, err_msg, zcolors.rgba(255, 255, 255, 255));
        content_top += err_h;
    }

    // Split: list left (40%), detail right (60%)
    const list_w = content_rect.width() * 0.4;
    const detail_x = content_rect.min[0] + list_w;
    const list_rect = Rect.fromXYWH(content_rect.min[0], content_top, list_w, content_rect.max[1] - content_top);
    const detail_rect = Rect.fromXYWH(detail_x, content_top, content_rect.max[0] - detail_x, content_rect.max[1] - content_top);

    drawListPane(self, list_rect);
    self.drawRect(Rect.fromXYWH(detail_x, content_top, 1.0, detail_rect.height()), self.theme.colors.border);
    drawDetailPane(self, detail_rect);
}

// ── Private helpers ───────────────────────────────────────────────────────────

fn drawListPane(self: anytype, rect: Rect) void {
    const layout = self.panelLayoutMetrics();
    const inset = layout.inner_inset;
    const row_h = layout.input_height;
    const row_gap = @max(1.0, layout.inner_inset * 0.15);

    if (self.ws.mcp_entries.items.len == 0) {
        const msg = if (self.connection_state != .connected)
            "Not connected."
        else
            "No MCP servers found.\nMCP servers are venoms with kind=\"mcp\"\nregistered on connected nodes.";
        self.drawTextTrimmed(rect.min[0] + inset, rect.min[1] + inset, rect.width() - inset * 2.0, msg, zcolors.withAlpha(self.theme.colors.text_primary, 100));
        return;
    }

    var y = rect.min[1];
    for (self.ws.mcp_entries.items, 0..) |entry, idx| {
        if (y + row_h > rect.max[1]) break;
        const selected = self.ws.mcp_selected_index == idx;
        const row_rect = Rect.fromXYWH(rect.min[0], y, rect.width(), row_h);

        if (selected) {
            self.drawFilledRect(row_rect, zcolors.withAlpha(self.theme.colors.primary, 40));
        } else if (idx % 2 == 1) {
            self.drawFilledRect(row_rect, zcolors.withAlpha(self.theme.colors.border, 20));
        }

        if (self.mouse_released and row_rect.contains(.{ self.mouse_x, self.mouse_y })) {
            if (self.ws.mcp_selected_index != idx) {
                self.ws.mcp_selected_index = idx;
                self.loadMcpRuntime(&entry);
            } else {
                self.ws.mcp_selected_index = null;
                if (self.ws.mcp_selected_runtime) |v| {
                    self.allocator.free(v);
                    self.ws.mcp_selected_runtime = null;
                }
            }
        }

        const tx = rect.min[0] + inset;
        const ty = y + (row_h - layout.line_height) * 0.5;

        // State dot
        const online = std.mem.eql(u8, entry.state, "online");
        const dot_color = if (online) zcolors.rgba(36, 174, 100, 255) else zcolors.rgba(200, 120, 40, 255);
        const dot_size = layout.line_height * 0.65;
        self.drawFilledRect(Rect.fromXYWH(tx, ty + (layout.line_height - dot_size) * 0.5, dot_size, dot_size), dot_color);

        // Venom ID
        self.drawTextTrimmed(tx + dot_size + 6.0 * self.ui_scale, ty, rect.width() - inset * 2.0 - dot_size - 6.0 * self.ui_scale, entry.venom_id, self.theme.colors.text_primary);

        y += row_h + row_gap;
    }
}

fn drawDetailPane(self: anytype, rect: Rect) void {
    const layout = self.panelLayoutMetrics();
    const inset = layout.inner_inset;
    const row_h = layout.input_height;
    const row_gap = layout.row_gap;

    const idx = self.ws.mcp_selected_index orelse {
        self.drawText(rect.min[0] + inset, rect.min[1] + inset, "Select a server to see details.", zcolors.withAlpha(self.theme.colors.text_primary, 100));
        return;
    };
    if (idx >= self.ws.mcp_entries.items.len) return;
    const entry = &self.ws.mcp_entries.items[idx];

    // Accent bar
    const accent_w = 3.0 * self.ui_scale;
    self.drawFilledRect(Rect.fromXYWH(rect.min[0], rect.min[1], accent_w, rect.height()), zcolors.rgba(200, 90, 40, 255));

    const tx = rect.min[0] + accent_w + inset;
    var y = rect.min[1] + inset;
    const label_w = 90.0 * self.ui_scale;
    const value_w = rect.max[0] - tx - label_w - inset;

    // Header: venom_id
    self.drawTextTrimmed(tx, y, rect.max[0] - tx - inset, entry.venom_id, self.theme.colors.text_primary);
    y += row_h + row_gap;

    // Fields
    const dim = zcolors.withAlpha(self.theme.colors.text_primary, 130);
    const field_rows = [_]struct { label: []const u8, value: []const u8 }{
        .{ .label = "Node:", .value = entry.node_id },
        .{ .label = "State:", .value = entry.state },
        .{ .label = "Endpoint:", .value = if (entry.endpoint.len > 0) entry.endpoint else "(none)" },
    };
    for (field_rows) |row| {
        if (y + row_h > rect.max[1]) break;
        self.drawTextTrimmed(tx, y + (row_h - layout.line_height) * 0.5, label_w, row.label, dim);
        self.drawTextTrimmed(tx + label_w, y + (row_h - layout.line_height) * 0.5, value_w, row.value, self.theme.colors.text_primary);
        y += row_h + row_gap;
    }

    // Runtime section
    y += row_gap * 2.0;
    if (y + row_h > rect.max[1]) return;
    self.drawText(tx, y + (row_h - layout.line_height) * 0.5, "Runtime config:", dim);
    y += row_h + row_gap;

    if (self.ws.mcp_selected_runtime) |runtime_json| {
        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, runtime_json, .{}) catch {
            self.drawTextTrimmed(tx, y, rect.max[0] - tx - inset, "(invalid RUNTIME.json)", dim);
            return;
        };
        defer parsed.deinit();

        if (parsed.value == .object) {
            const obj = parsed.value.object;
            if (obj.get("executable_path")) |ep| {
                if (ep == .string and y + row_h <= rect.max[1]) {
                    self.drawTextTrimmed(tx, y + (row_h - layout.line_height) * 0.5, label_w, "Exec:", dim);
                    self.drawTextTrimmed(tx + label_w, y + (row_h - layout.line_height) * 0.5, value_w, ep.string, self.theme.colors.text_primary);
                    y += row_h + row_gap;
                }
            }
            if (obj.get("args")) |args_val| {
                if (args_val == .array and y + row_h <= rect.max[1]) {
                    // Find the MCP command after "--"
                    var found_sep = false;
                    var mcp_cmd_buf: [256]u8 = undefined;
                    var mcp_cmd_len: usize = 0;
                    for (args_val.array.items) |arg| {
                        if (arg != .string) continue;
                        if (!found_sep) {
                            if (std.mem.eql(u8, arg.string, "--")) found_sep = true;
                            continue;
                        }
                        if (mcp_cmd_len + arg.string.len + 1 < mcp_cmd_buf.len) {
                            if (mcp_cmd_len > 0) {
                                mcp_cmd_buf[mcp_cmd_len] = ' ';
                                mcp_cmd_len += 1;
                            }
                            @memcpy(mcp_cmd_buf[mcp_cmd_len..][0..arg.string.len], arg.string);
                            mcp_cmd_len += arg.string.len;
                        }
                    }
                    if (mcp_cmd_len > 0) {
                        self.drawTextTrimmed(tx, y + (row_h - layout.line_height) * 0.5, label_w, "Command:", dim);
                        self.drawTextTrimmed(tx + label_w, y + (row_h - layout.line_height) * 0.5, value_w, mcp_cmd_buf[0..mcp_cmd_len], self.theme.colors.text_primary);
                        y += row_h + row_gap;
                    }
                }
            }
            if (obj.get("timeout_ms")) |to| {
                if (y + row_h <= rect.max[1]) {
                    self.drawTextTrimmed(tx, y + (row_h - layout.line_height) * 0.5, label_w, "Timeout:", dim);
                    var buf: [32]u8 = undefined;
                    const val_str = switch (to) {
                        .integer => |n| std.fmt.bufPrint(&buf, "{d}ms", .{n}) catch "?",
                        .float => |f| std.fmt.bufPrint(&buf, "{d:.0}ms", .{f}) catch "?",
                        else => "?",
                    };
                    self.drawTextTrimmed(tx + label_w, y + (row_h - layout.line_height) * 0.5, value_w, val_str, self.theme.colors.text_primary);
                    y += row_h + row_gap;
                }
            }
        }
    } else {
        self.drawText(tx, y, "(loading...)", dim);
    }
}
