// debug_host.zig — Debug stream panel draw functions.

const std = @import("std");
const zui = @import("ziggy-ui");
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

// Constants re-declared locally (same values as in root.zig)
const DEBUG_STREAM_SNAPSHOT_RETRY_MS: i64 = 2_000;
const DEBUG_STREAM_PATH = "/debug/stream.log";
const NODE_SERVICE_EVENTS_PATH = "/global/services/node-service-events.ndjson";
const NODE_SERVICE_SNAPSHOT_RETRY_MS: i64 = 2_000;
const DEBUG_EVENT_DEDUPE_WINDOW: usize = 4096;
const DEBUG_SYNTAX_COLOR_MAX_PAYLOAD_BYTES: usize = 64 * 1024;
const PERF_SPARKLINE_MAX_COLUMNS: usize = 24;

pub fn drawDebugPanel(self: anytype, manager: anytype, rect: anytype) void {
    const DebugPanel = @import("ziggy-ui-panels").debug_panel;
    const host = DebugPanel.Host{
        .ctx = @ptrCast(self),
        .draw_label = @import("../root.zig").launcherSettingsDrawLabel,
        .draw_text_trimmed = @import("../root.zig").launcherSettingsDrawTextTrimmed,
        .draw_text_input = @import("../root.zig").launcherSettingsDrawTextInput,
        .draw_button = @import("../root.zig").launcherSettingsDrawButton,
        .draw_text_wrapped = @import("../root.zig").filesystemDrawTextWrapped,
        .draw_perf_charts = @import("../root.zig").debugDrawPerfCharts,
        .draw_event_stream = @import("../root.zig").debugDrawEventStream,
    };
    var view = self.buildDebugPanelView();
    defer view.deinit(self.allocator);
    var panel_state = DebugPanel.State{
        .focused_field = @import("../root.zig").debugFocusFieldToExternal(self.settings_panel.focused_field),
    };
    const action = DebugPanel.draw(
        host,
        Rect{ .min = rect.min, .max = rect.max },
        self.panelLayoutMetrics(),
        .{
            .text_primary = self.theme.colors.text_primary,
            .text_secondary = self.theme.colors.text_secondary,
        },
        self.debugPanelModel(),
        view.view,
        view.event_stream_view,
        .{
            .mouse_x = self.mouse_x,
            .mouse_y = self.mouse_y,
            .mouse_released = self.mouse_released,
        },
        &panel_state,
    );
    const mapped_focus = @import("../root.zig").debugFocusFieldFromExternal(panel_state.focused_field);
    if (mapped_focus != .none or @import("../root.zig").isDebugPanelFocusField(self.settings_panel.focused_field)) {
        self.settings_panel.focused_field = mapped_focus;
    }
    if (action) |value| self.performDebugPanelAction(manager, value);
}

const SparklinePointsCtx = struct {
    points: []const f32,
};

fn sparklinePointAt(ctx: *const anyopaque, idx: usize) f32 {
    const points_ctx: *const SparklinePointsCtx = @ptrCast(@alignCast(ctx));
    return if (idx < points_ctx.points.len) points_ctx.points[idx] else 0.0;
}

pub fn drawDebugPerfCharts(
    self: anytype,
    rect: anytype,
    layout: anytype,
    y_start: f32,
    perf_charts: anytype,
) f32 {
    const pad = layout.inset;
    const line_height = layout.line_height;
    const row_height = layout.button_height;
    const width = rect.max[0] - rect.min[0];
    const content_width = @max(240.0, width - pad * 2.0);
    var y = y_start;
    if (perf_charts.len == 0) return y;
    const spark_gap = @max(6.0 * self.ui_scale, layout.inner_inset * 0.8);
    const spark_h = @max(52.0 * self.ui_scale, row_height * 1.9);
    const spark_min_card_w = @max(150.0 * self.ui_scale, 90.0);
    const spark_chart_count: usize = perf_charts.len;
    const spark_cols_float = @floor((content_width + spark_gap) / (spark_min_card_w + spark_gap));
    const spark_cols = std.math.clamp(@as(usize, @intFromFloat(@max(1.0, spark_cols_float))), 1, spark_chart_count);
    const spark_rows = @divTrunc(spark_chart_count + spark_cols - 1, spark_cols);
    const spark_card_w = @max(72.0 * self.ui_scale, (content_width - spark_gap * @as(f32, @floatFromInt(spark_cols - 1))) / @as(f32, @floatFromInt(spark_cols)));
    const spark_label_h = line_height;
    const spark_row_h = spark_label_h + spark_h + layout.row_gap * 0.35;
    self.drawTextTrimmed(rect.min[0] + pad, y, content_width, "Perf sparkline charts (recent window)", self.theme.colors.text_secondary);
    y += line_height;

    const widgets = zui.widgets;
    for (perf_charts, 0..) |chart, idx| {
        const row = @divTrunc(idx, spark_cols);
        const col = idx % spark_cols;
        const row_y = y + @as(f32, @floatFromInt(row)) * spark_row_h;
        const x = rect.min[0] + pad + @as(f32, @floatFromInt(col)) * (spark_card_w + spark_gap);
        const chart_rect = Rect.fromXYWH(x, row_y + spark_label_h, spark_card_w, spark_h);
        self.drawTextCenteredTrimmed(
            x + spark_card_w * 0.5,
            row_y,
            spark_card_w - @max(8.0 * self.ui_scale, 4.0),
            chart.label,
            self.theme.colors.text_secondary,
        );
        var points_ctx = SparklinePointsCtx{ .points = chart.points };
        const charts = self.sharedStyleSheet().charts;
        const stroke_color = self.chartSeriesThemeColor(idx);
        widgets.sparkline.draw(
            &self.ui_commands,
            chart_rect,
            .{ .ctx = @as(*const anyopaque, @ptrCast(&points_ctx)), .count = chart.points.len, .at = &sparklinePointAt },
            .{
                .stroke_color = stroke_color,
                .fill_color = zcolors.withAlpha(stroke_color, charts.fill_alpha orelse 0.28),
                .background_color = charts.background orelse zcolors.withAlpha(self.theme.colors.surface, 0.96),
                .border_color = charts.border orelse self.theme.colors.border,
                .max_columns = PERF_SPARKLINE_MAX_COLUMNS,
            },
        );
    }
    return y + @as(f32, @floatFromInt(spark_rows)) * spark_row_h + layout.row_gap * 0.2;
}

pub fn drawDebugEventStream(self: anytype, output_rect: anytype, view: anytype) void {
    const DebugEventStreamPanel = @import("ziggy-ui-panels").debug_event_stream;
    const host = DebugEventStreamPanel.Host{
        .ctx = @ptrCast(self),
        .set_output_rect = @import("../root.zig").debugEventStreamSetOutputRect,
        .focus_panel = @import("../root.zig").debugEventStreamFocusPanel,
        .draw_surface_panel = @import("../root.zig").filesystemDrawSurfacePanel,
        .push_clip = @import("../root.zig").debugEventStreamPushClip,
        .pop_clip = @import("../root.zig").debugEventStreamPopClip,
        .draw_filled_rect = @import("../root.zig").debugEventStreamDrawFilledRect,
        .draw_button = @import("../root.zig").launcherSettingsDrawButton,
        .get_scroll_y = @import("../root.zig").debugEventStreamGetScrollY,
        .set_scroll_y = @import("../root.zig").debugEventStreamSetScrollY,
        .get_scrollbar_dragging = @import("../root.zig").debugEventStreamGetScrollbarDragging,
        .set_scrollbar_dragging = @import("../root.zig").debugEventStreamSetScrollbarDragging,
        .get_drag_start_y = @import("../root.zig").debugEventStreamGetDragStartY,
        .set_drag_start_y = @import("../root.zig").debugEventStreamSetDragStartY,
        .get_drag_start_scroll_y = @import("../root.zig").debugEventStreamGetDragStartScrollY,
        .set_drag_start_scroll_y = @import("../root.zig").debugEventStreamSetDragStartScrollY,
        .set_drag_capture = @import("../root.zig").debugEventStreamSetDragCapture,
        .release_drag_capture = @import("../root.zig").debugEventStreamReleaseDragCapture,
        .entry_height = @import("../root.zig").debugEventStreamEntryHeight,
        .draw_entry = @import("../root.zig").debugEventStreamDrawEntry,
        .select_entry = @import("../root.zig").debugEventStreamSelectEntry,
        .copy_selected_event = @import("../root.zig").debugEventStreamCopySelectedEvent,
        .selected_event_count = @import("../root.zig").debugEventStreamSelectedEventCount,
    };
    DebugEventStreamPanel.draw(
        host,
        output_rect,
        self.panelLayoutMetrics(),
        self.ui_scale,
        .{
            .primary = self.theme.colors.primary,
            .border = self.theme.colors.border,
        },
        view,
        .{
            .mouse_x = self.mouse_x,
            .mouse_y = self.mouse_y,
            .mouse_clicked = self.mouse_clicked,
            .mouse_down = self.mouse_down,
        },
    );
}

fn makeDebugFoldKey(event_id: u64, line_index: usize) @import("../root.zig").DebugFoldKey {
    return .{
        .event_id = event_id,
        .line_index = @intCast(line_index),
    };
}

pub fn isDebugBlockCollapsed(self: anytype, event_id: u64, line_index: usize) bool {
    return self.debug.debug_folded_blocks.contains(makeDebugFoldKey(event_id, line_index));
}

pub fn toggleDebugBlockCollapsed(self: anytype, event_id: u64, line_index: usize) void {
    const key = makeDebugFoldKey(event_id, line_index);
    if (self.debug.debug_folded_blocks.contains(key)) {
        _ = self.debug.debug_folded_blocks.remove(key);
        self.debug.debug_fold_revision +%= 1;
        if (self.debug.debug_fold_revision == 0) self.debug.debug_fold_revision = 1;
        return;
    }
    self.debug.debug_folded_blocks.put(key, {}) catch {};
    self.debug.debug_fold_revision +%= 1;
    if (self.debug.debug_fold_revision == 0) self.debug.debug_fold_revision = 1;
}

pub fn pruneDebugFoldStateForEvent(self: anytype, event_id: u64) void {
    var to_remove: std.ArrayList(@import("../root.zig").DebugFoldKey) = .empty;
    defer to_remove.deinit(self.allocator);

    var it = self.debug.debug_folded_blocks.keyIterator();
    while (it.next()) |key_ptr| {
        if (key_ptr.*.event_id == event_id) {
            to_remove.append(self.allocator, key_ptr.*) catch return;
        }
    }
    for (to_remove.items) |key| {
        _ = self.debug.debug_folded_blocks.remove(key);
    }
    if (to_remove.items.len > 0) {
        self.debug.debug_fold_revision +%= 1;
        if (self.debug.debug_fold_revision == 0) self.debug.debug_fold_revision = 1;
    }
}

pub fn ensureDebugPayloadLines(self: anytype, entry: anytype) void {
    if (entry.payload_lines.items.len > 0) return;
    if (entry.payload_json.len == 0) return;
    entry.payload_lines = self.buildDebugPayloadLines(entry.payload_json) catch .empty;
    entry.payload_wrap_rows.clearRetainingCapacity();
    entry.payload_visible_line_indices.clearRetainingCapacity();
    entry.payload_visible_line_row_starts.clearRetainingCapacity();
    entry.payload_visible_lines_valid = false;
    entry.payload_wrap_rows_valid = false;
    entry.cached_visible_rows_valid = false;
}

pub fn ensureDebugPayloadWrapRows(self: anytype, output_min_x: f32, content_max_x: f32, entry: anytype) void {
    if (entry.payload_lines.items.len == 0) return;
    const wrap_width = @max(1.0, content_max_x - output_min_x);
    if (entry.payload_wrap_rows_valid and
        @abs(entry.payload_wrap_rows_wrap_width - wrap_width) < 0.5 and
        entry.payload_wrap_rows.items.len == entry.payload_lines.items.len)
    {
        return;
    }

    entry.payload_wrap_rows.clearRetainingCapacity();
    entry.payload_wrap_rows_valid = false;
    entry.payload_wrap_rows.ensureTotalCapacity(self.allocator, entry.payload_lines.items.len) catch return;

    const space_w = self.measureText(" ");
    const fold_marker_w = self.measureText("[-]") + space_w;
    for (entry.payload_lines.items, 0..) |meta, line_index| {
        const line = entry.payload_json[meta.start..meta.end];
        const indent_width = @as(f32, @floatFromInt(meta.indent_spaces)) * space_w;
        const line_x_base = output_min_x + indent_width;
        const content_start = @min(meta.indent_spaces, line.len);
        const content = line[content_start..];
        const can_fold = meta.opens_block and meta.matching_close_index != null and
            @as(usize, @intCast(meta.matching_close_index.?)) > line_index + 1;
        const text_x = if (can_fold) line_x_base + fold_marker_w else line_x_base;
        const rows = self.measureJsonLineWrapRows(text_x, content_max_x, content);
        const clamped_rows: u32 = if (rows > std.math.maxInt(u32))
            std.math.maxInt(u32)
        else
            @intCast(rows);
        entry.payload_wrap_rows.appendAssumeCapacity(clamped_rows);
    }

    entry.payload_wrap_rows_wrap_width = wrap_width;
    entry.payload_wrap_rows_valid = true;
    entry.payload_visible_lines_valid = false;
    entry.cached_visible_rows_valid = false;
}

fn payloadLineRowsFromCache(entry: anytype, line_index: usize) usize {
    if (line_index >= entry.payload_wrap_rows.items.len) return 1;
    const rows = @as(usize, @intCast(entry.payload_wrap_rows.items[line_index]));
    return if (rows == 0) 1 else rows;
}

pub fn ensureDebugVisiblePayloadLines(self: anytype, output_min_x: f32, content_max_x: f32, entry: anytype) void {
    if (entry.payload_lines.items.len == 0) {
        entry.payload_visible_line_indices.clearRetainingCapacity();
        entry.payload_visible_line_row_starts.clearRetainingCapacity();
        entry.cached_visible_rows = 0;
        entry.cached_visible_rows_valid = true;
        entry.payload_visible_lines_valid = true;
        return;
    }

    self.ensureDebugPayloadWrapRows(output_min_x, content_max_x, entry);
    const wrap_width = @max(1.0, content_max_x - output_min_x);
    if (entry.payload_visible_lines_valid and
        @abs(entry.cached_visible_rows_wrap_width - wrap_width) < 0.5 and
        entry.cached_visible_rows_fold_revision == self.debug.debug_fold_revision)
    {
        return;
    }

    entry.payload_visible_line_indices.clearRetainingCapacity();
    entry.payload_visible_line_row_starts.clearRetainingCapacity();
    entry.payload_visible_line_indices.ensureTotalCapacity(self.allocator, entry.payload_lines.items.len) catch return;
    entry.payload_visible_line_row_starts.ensureTotalCapacity(self.allocator, entry.payload_lines.items.len) catch return;

    var rows_u64: u64 = 0;
    var line_index: usize = 0;
    while (line_index < entry.payload_lines.items.len) {
        const meta = entry.payload_lines.items[line_index];
        const start_clamped: u32 = if (rows_u64 > std.math.maxInt(u32))
            std.math.maxInt(u32)
        else
            @intCast(rows_u64);
        entry.payload_visible_line_indices.appendAssumeCapacity(@intCast(line_index));
        entry.payload_visible_line_row_starts.appendAssumeCapacity(start_clamped);

        const rows_used = payloadLineRowsFromCache(entry, line_index);
        rows_u64 += rows_used;

        if (meta.opens_block and meta.matching_close_index != null and
            @as(usize, @intCast(meta.matching_close_index.?)) > line_index + 1 and
            self.isDebugBlockCollapsed(entry.id, line_index))
        {
            line_index = @as(usize, @intCast(meta.matching_close_index.?)) + 1;
        } else {
            line_index += 1;
        }
    }

    entry.cached_visible_rows = if (rows_u64 > std.math.maxInt(usize))
        std.math.maxInt(usize)
    else
        @intCast(rows_u64);
    entry.cached_visible_rows_wrap_width = wrap_width;
    entry.cached_visible_rows_fold_revision = self.debug.debug_fold_revision;
    entry.cached_visible_rows_valid = true;
    entry.payload_visible_lines_valid = true;
}

pub fn countVisibleDebugPayloadRows(self: anytype, output_min_x: f32, content_max_x: f32, entry: anytype) usize {
    if (entry.payload_lines.items.len == 0) return 0;
    self.ensureDebugVisiblePayloadLines(output_min_x, content_max_x, entry);
    return entry.cached_visible_rows;
}

pub fn findFirstVisiblePayloadLine(
    entry: anytype,
    min_row: usize,
) usize {
    var lo: usize = 0;
    var hi: usize = entry.payload_visible_line_indices.items.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const line_index = @as(usize, @intCast(entry.payload_visible_line_indices.items[mid]));
        const start_row = @as(usize, @intCast(entry.payload_visible_line_row_starts.items[mid]));
        const rows_used = payloadLineRowsFromCache(entry, line_index);
        const end_row = start_row + rows_used;
        if (end_row <= min_row) {
            lo = mid + 1;
        } else {
            hi = mid;
        }
    }
    return lo;
}

pub fn measureJsonLineWrapRows(self: anytype, line_x: f32, max_x: f32, line: []const u8) usize {
    const line_height = self.textLineHeight();
    const available_w = @max(1.0, max_x - line_x);
    const h = self.measureTextWrappedHeight(available_w, line);

    var rows: usize = 1;
    var remaining = h - line_height;
    while (remaining > line_height * 0.05) : (rows += 1) {
        remaining -= line_height;
    }
    return rows;
}

pub fn debugCategoryColor(self: anytype, category: []const u8) [4]f32 {
    if (std.mem.indexOf(u8, category, "error") != null) {
        return zcolors.rgba(196, 74, 74, 255);
    }
    if (std.mem.startsWith(u8, category, "control.")) {
        return zcolors.blend(self.theme.colors.primary, self.theme.colors.text_primary, 0.32);
    }
    if (std.mem.startsWith(u8, category, "session.")) {
        return zcolors.rgba(64, 134, 196, 255);
    }
    return self.theme.colors.text_primary;
}

pub fn drawDebugEventHeaderLine(self: anytype, x: f32, y: f32, max_x: f32, entry: anytype) void {
    var ts_buf: [64]u8 = undefined;
    const ts = std.fmt.bufPrint(&ts_buf, "{d}", .{entry.timestamp_ms}) catch "0";
    const line_height = self.textLineHeight();

    // Use a fixed timestamp column so category text never overlaps when
    // text measurement is slightly off relative to actual glyph widths.
    const ts_col_w = 116.0 * self.ui_scale;
    const ts_max_w = @max(0.0, @min(ts_col_w, max_x - x));
    self.drawTextTrimmed(x, y, ts_max_w, ts, self.theme.colors.text_secondary);

    const cursor_x = x + ts_col_w + 6.0 * self.ui_scale;
    if (cursor_x >= max_x) return;

    const category_max = @max(0.0, max_x - cursor_x);
    var category_w = self.measureText(entry.category);
    if (category_w > category_max) category_w = category_max;
    self.drawTextTrimmed(cursor_x, y, category_max, entry.category, self.debugCategoryColor(entry.category));

    if (entry.correlation_id) |value| {
        var badge_buf: [160]u8 = undefined;
        const text = std.fmt.bufPrint(&badge_buf, "CID:{s}", .{value}) catch "CID:(long)";
        const badge_x = cursor_x + category_w + 8.0 * self.ui_scale;
        const remaining = max_x - badge_x;
        if (remaining > 40.0 * self.ui_scale) {
            const badge_w = @min(remaining, self.measureText(text) + 10.0 * self.ui_scale);
            const badge_h = line_height;
            const badge_rect = Rect.fromXYWH(
                badge_x,
                y + 1.0 * self.ui_scale,
                badge_w,
                badge_h,
            );
            self.drawFilledRect(
                badge_rect,
                zcolors.withAlpha(self.theme.colors.primary, 0.22),
            );
            self.drawTextTrimmed(
                badge_rect.min[0] + 4.0 * self.ui_scale,
                y,
                badge_w - 6.0 * self.ui_scale,
                text,
                self.theme.colors.text_primary,
            );
        }
    }
}

pub fn jsonTokenColor(self: anytype, kind: anytype) [4]f32 {
    return self.syntaxThemeColor(kind);
}

pub fn wrappedLineBreak(self: anytype, wrap_x: f32, cursor_x: *f32, cursor_y: *f32, rows: *usize) void {
    const line_height = self.textLineHeight();
    cursor_x.* = wrap_x;
    cursor_y.* += line_height;
    rows.* += 1;
}

pub fn measureGlyphWidth(self: anytype, glyph: []const u8) f32 {
    if (glyph.len == 1) {
        const idx = glyph[0];
        if (idx < self.ascii_glyph_width_cache.len) {
            const cached = self.ascii_glyph_width_cache[idx];
            if (cached >= 0.0) return cached;
            const measured = self.measureText(glyph);
            self.ascii_glyph_width_cache[idx] = measured;
            return measured;
        }
    }
    return self.measureText(glyph);
}

pub fn maxFittingPrefix(self: anytype, text: []const u8, max_w: f32) usize {
    if (text.len == 0 or max_w <= 0.0) return 0;
    var width: f32 = 0.0;
    var idx: usize = 0;
    var best_end: usize = 0;
    while (idx < text.len) {
        const next = @import("../root.zig").nextUtf8Boundary(text, idx);
        if (next <= idx) break;
        const glyph_w = self.measureGlyphWidth(text[idx..next]);
        if (width + glyph_w > max_w) break;
        width += glyph_w;
        best_end = next;
        idx = next;
    }
    return best_end;
}

pub fn drawJsonTokenWrapped(
    self: anytype,
    wrap_x: f32,
    cursor_x: *f32,
    cursor_y: *f32,
    max_x: f32,
    token: []const u8,
    color: [4]f32,
    rows: *usize,
) void {
    if (token.len == 0) return;

    var start: usize = 0;
    while (start < token.len) {
        const remaining_w = max_x - cursor_x.*;
        if (remaining_w <= 0.0) {
            if (cursor_x.* > wrap_x) {
                self.wrappedLineBreak(wrap_x, cursor_x, cursor_y, rows);
                continue;
            }
            const next = @import("../root.zig").nextUtf8Boundary(token, start);
            const single = token[start..next];
            self.drawText(cursor_x.*, cursor_y.*, single, color);
            cursor_x.* += self.measureText(single);
            start = next;
            continue;
        }

        const rest = token[start..];
        const fit = self.maxFittingPrefix(rest, remaining_w);
        if (fit == 0) {
            if (cursor_x.* > wrap_x) {
                self.wrappedLineBreak(wrap_x, cursor_x, cursor_y, rows);
                continue;
            }
            const next = @import("../root.zig").nextUtf8Boundary(rest, 0);
            const single = rest[0..next];
            self.drawText(cursor_x.*, cursor_y.*, single, color);
            cursor_x.* += self.measureText(single);
            start += next;
            continue;
        }

        const piece = rest[0..fit];
        self.drawText(cursor_x.*, cursor_y.*, piece, color);
        cursor_x.* += self.measureText(piece);
        start += fit;

        if (start < token.len) {
            self.wrappedLineBreak(wrap_x, cursor_x, cursor_y, rows);
        }
    }
}

fn isJsonDelimiter(ch: u8) bool {
    return ch == ' ' or ch == '\t' or ch == ',' or ch == ':' or ch == ']' or ch == '}' or ch == '[' or ch == '{';
}

pub fn drawJsonLineColored(self: anytype, x: f32, y: f32, max_x: f32, line: []const u8) usize {
    const JsonTokenKind = @import("../root.zig").JsonTokenKind;
    var cursor_x = x;
    var cursor_y = y;
    var rows: usize = 1;
    var i: usize = 0;
    while (i < line.len) {
        const ch = line[i];

        if (ch == ' ' or ch == '\t') {
            var j = i + 1;
            while (j < line.len and (line[j] == ' ' or line[j] == '\t')) : (j += 1) {}
            const ws_width = self.measureText(line[i..j]);
            if (cursor_x + ws_width <= max_x) {
                cursor_x += ws_width;
            } else if (cursor_x > x) {
                self.wrappedLineBreak(x, &cursor_x, &cursor_y, &rows);
            }
            i = j;
            continue;
        }

        if (ch == '"') {
            var j = i + 1;
            var escaped = false;
            while (j < line.len) : (j += 1) {
                const cur = line[j];
                if (escaped) {
                    escaped = false;
                    continue;
                }
                if (cur == '\\') {
                    escaped = true;
                    continue;
                }
                if (cur == '"') {
                    j += 1;
                    break;
                }
            }
            if (j > line.len) j = line.len;

            var kind: JsonTokenKind = .string;
            var k = j;
            while (k < line.len and (line[k] == ' ' or line[k] == '\t')) : (k += 1) {}
            if (k < line.len and line[k] == ':') {
                kind = .key;
            }
            self.drawJsonTokenWrapped(x, &cursor_x, &cursor_y, max_x, line[i..j], self.jsonTokenColor(kind), &rows);
            i = j;
            continue;
        }

        if (ch == '{' or ch == '}' or ch == '[' or ch == ']' or ch == ':' or ch == ',') {
            self.drawJsonTokenWrapped(x, &cursor_x, &cursor_y, max_x, line[i .. i + 1], self.jsonTokenColor(.punctuation), &rows);
            i += 1;
            continue;
        }

        if ((ch >= '0' and ch <= '9') or ch == '-') {
            var j = i + 1;
            while (j < line.len) : (j += 1) {
                const cur = line[j];
                if (!((cur >= '0' and cur <= '9') or cur == '.' or cur == 'e' or cur == 'E' or cur == '+' or cur == '-')) {
                    break;
                }
            }
            self.drawJsonTokenWrapped(x, &cursor_x, &cursor_y, max_x, line[i..j], self.jsonTokenColor(.number), &rows);
            i = j;
            continue;
        }

        if (std.mem.startsWith(u8, line[i..], "true")) {
            const end = i + 4;
            if (end == line.len or isJsonDelimiter(line[end])) {
                self.drawJsonTokenWrapped(x, &cursor_x, &cursor_y, max_x, line[i..end], self.jsonTokenColor(.keyword), &rows);
                i = end;
                continue;
            }
        }
        if (std.mem.startsWith(u8, line[i..], "false")) {
            const end = i + 5;
            if (end == line.len or isJsonDelimiter(line[end])) {
                self.drawJsonTokenWrapped(x, &cursor_x, &cursor_y, max_x, line[i..end], self.jsonTokenColor(.keyword), &rows);
                i = end;
                continue;
            }
        }
        if (std.mem.startsWith(u8, line[i..], "null")) {
            const end = i + 4;
            if (end == line.len or isJsonDelimiter(line[end])) {
                self.drawJsonTokenWrapped(x, &cursor_x, &cursor_y, max_x, line[i..end], self.jsonTokenColor(.keyword), &rows);
                i = end;
                continue;
            }
        }

        var j = i + 1;
        while (j < line.len) : (j += 1) {
            const cur = line[j];
            if (cur == '"' or cur == ' ' or cur == '\t' or cur == '{' or cur == '}' or cur == '[' or cur == ']' or cur == ',' or cur == ':') {
                break;
            }
        }
        self.drawJsonTokenWrapped(x, &cursor_x, &cursor_y, max_x, line[i..j], self.jsonTokenColor(.plain), &rows);
        i = j;
    }
    return rows;
}

pub fn clearSelectedNodeServiceEventCache(self: anytype) void {
    if (self.debug.debug_selected_node_service_cache_node_id) |value| {
        self.allocator.free(value);
        self.debug.debug_selected_node_service_cache_node_id = null;
    }
    if (self.debug.debug_selected_node_service_cache_diagnostics) |value| {
        self.allocator.free(value);
        self.debug.debug_selected_node_service_cache_diagnostics = null;
    }
    self.debug.debug_selected_node_service_cache_index = null;
    self.debug.debug_selected_node_service_cache_event_id = 0;
}

pub fn selectedNodeServiceEventInfo(self: anytype) @import("../root.zig").SelectedNodeServiceEventInfo {
    const selected_idx = self.debug.debug_selected_index orelse {
        self.clearSelectedNodeServiceEventCache();
        return .{};
    };
    if (selected_idx >= self.debug.debug_events.items.len) {
        self.debug.debug_selected_index = null;
        self.clearSelectedNodeServiceEventCache();
        return .{};
    }

    const entry = self.debug.debug_events.items[selected_idx];
    if (!std.mem.eql(u8, entry.category, "control.node_service_event")) {
        self.clearSelectedNodeServiceEventCache();
        return .{};
    }

    if (self.debug.debug_selected_node_service_cache_index == selected_idx and
        self.debug.debug_selected_node_service_cache_event_id == entry.id)
    {
        return .{
            .index = selected_idx,
            .node_id = self.debug.debug_selected_node_service_cache_node_id,
            .diagnostics = self.debug.debug_selected_node_service_cache_diagnostics,
        };
    }

    self.clearSelectedNodeServiceEventCache();
    self.debug.debug_selected_node_service_cache_index = selected_idx;
    self.debug.debug_selected_node_service_cache_event_id = entry.id;

    var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, entry.payload_json, .{}) catch null;
    if (parsed) |*parsed_value| {
        defer parsed_value.deinit();
        if (parsed_value.value == .object) {
            if (parsed_value.value.object.get("node_id")) |value| {
                if (value == .string and value.string.len > 0) {
                    self.debug.debug_selected_node_service_cache_node_id = self.allocator.dupe(u8, value.string) catch null;
                }
            }
        }
    }
    self.debug.debug_selected_node_service_cache_diagnostics =
        self.buildNodeServiceDeltaDiagnosticsTextFromJson(entry.payload_json) catch null;

    return .{
        .index = selected_idx,
        .node_id = self.debug.debug_selected_node_service_cache_node_id,
        .diagnostics = self.debug.debug_selected_node_service_cache_diagnostics,
    };
}

pub fn collectUniqueLinesOrdered(
    self: anytype,
    text: []const u8,
    out: *std.ArrayListUnmanaged([]u8),
) !void {
    var iter = std.mem.splitScalar(u8, text, '\n');
    while (iter.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0) continue;
        var exists = false;
        for (out.items) |existing| {
            if (std.mem.eql(u8, existing, line)) {
                exists = true;
                break;
            }
        }
        if (exists) continue;
        try out.append(self.allocator, try self.allocator.dupe(u8, line));
    }
}

pub fn freeOwnedLines(self: anytype, lines: *std.ArrayListUnmanaged([]u8)) void {
    for (lines.items) |line| self.allocator.free(line);
    lines.deinit(self.allocator);
    lines.* = .{};
}

pub fn lineListContains(lines: []const []const u8, candidate: []const u8) bool {
    for (lines) |line| {
        if (std.mem.eql(u8, line, candidate)) return true;
    }
    return false;
}

pub fn buildNodeServiceEventDiffText(
    self: anytype,
    base_idx: usize,
    compare_idx: usize,
) !?[]u8 {
    if (base_idx >= self.debug.debug_events.items.len or compare_idx >= self.debug.debug_events.items.len) return null;
    const base_entry = self.debug.debug_events.items[base_idx];
    const compare_entry = self.debug.debug_events.items[compare_idx];
    if (!std.mem.eql(u8, base_entry.category, "control.node_service_event")) return null;
    if (!std.mem.eql(u8, compare_entry.category, "control.node_service_event")) return null;

    const base_diag_opt = try self.buildNodeServiceDeltaDiagnosticsTextFromJson(base_entry.payload_json);
    defer if (base_diag_opt) |value| self.allocator.free(value);
    const compare_diag_opt = try self.buildNodeServiceDeltaDiagnosticsTextFromJson(compare_entry.payload_json);
    defer if (compare_diag_opt) |value| self.allocator.free(value);
    const base_diag = base_diag_opt orelse return null;
    const compare_diag = compare_diag_opt orelse return null;

    var base_lines: std.ArrayListUnmanaged([]u8) = .{};
    defer self.freeOwnedLines(&base_lines);
    var compare_lines: std.ArrayListUnmanaged([]u8) = .{};
    defer self.freeOwnedLines(&compare_lines);
    try self.collectUniqueLinesOrdered(base_diag, &base_lines);
    try self.collectUniqueLinesOrdered(compare_diag, &compare_lines);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(self.allocator);
    try out.writer(self.allocator).print(
        "node_service_event_diff\nbase_event_id={d} base_timestamp_ms={d}\ncompare_event_id={d} compare_timestamp_ms={d}",
        .{ base_entry.id, base_entry.timestamp_ms, compare_entry.id, compare_entry.timestamp_ms },
    );
    try out.appendSlice(self.allocator, "\n\n--- base_diagnostics ---\n");
    try out.appendSlice(self.allocator, base_diag);
    try out.appendSlice(self.allocator, "\n\n--- compare_diagnostics ---\n");
    try out.appendSlice(self.allocator, compare_diag);

    try out.appendSlice(self.allocator, "\n\n--- only_in_compare ---");
    var compare_delta_count: usize = 0;
    for (compare_lines.items) |line| {
        if (lineListContains(base_lines.items, line)) continue;
        compare_delta_count += 1;
        try out.writer(self.allocator).print("\n+ {s}", .{line});
    }
    if (compare_delta_count == 0) try out.appendSlice(self.allocator, "\n(none)");

    try out.appendSlice(self.allocator, "\n\n--- only_in_base ---");
    var base_delta_count: usize = 0;
    for (base_lines.items) |line| {
        if (lineListContains(compare_lines.items, line)) continue;
        base_delta_count += 1;
        try out.writer(self.allocator).print("\n- {s}", .{line});
    }
    if (base_delta_count == 0) try out.appendSlice(self.allocator, "\n(none)");

    try out.writer(self.allocator).print(
        "\n\nsummary: compare_only={d} base_only={d}",
        .{ compare_delta_count, base_delta_count },
    );

    return try out.toOwnedSlice(self.allocator);
}

pub fn exportNodeServiceDiffSnapshot(
    self: anytype,
    diff_text: []const u8,
    base_event_id: u64,
    compare_event_id: u64,
) ![]u8 {
    const filename = try std.fmt.allocPrint(
        self.allocator,
        "node-service-diff-{d}-to-{d}-{d}.txt",
        .{ base_event_id, compare_event_id, std.time.milliTimestamp() },
    );
    defer self.allocator.free(filename);

    try std.fs.cwd().writeFile(.{
        .sub_path = filename,
        .data = diff_text,
    });

    const cwd = std.fs.cwd().realpathAlloc(self.allocator, ".") catch return self.allocator.dupe(u8, filename);
    defer self.allocator.free(cwd);
    return std.fmt.allocPrint(
        self.allocator,
        "{s}{s}{s}",
        .{ cwd, std.fs.path.sep_str, filename },
    );
}

pub fn hasPerfBenchmarkCapture(self: anytype) bool {
    if (self.perf_benchmark_active) return true;
    return self.perf_benchmark_last_start_timestamp_ms > 0 and
        self.perf_benchmark_last_end_timestamp_ms >= self.perf_benchmark_last_start_timestamp_ms;
}

pub fn clearPerfBenchmarkCapture(self: anytype) void {
    self.perf_benchmark_last_start_sample_index = null;
    self.perf_benchmark_last_end_sample_index = 0;
    self.perf_benchmark_last_start_timestamp_ms = 0;
    self.perf_benchmark_last_end_timestamp_ms = 0;
    if (self.perf_benchmark_last_label) |value| {
        self.allocator.free(value);
        self.perf_benchmark_last_label = null;
    }
}

pub fn startPerfBenchmark(self: anytype) !void {
    if (self.perf_benchmark_active) return;
    const now_ms = std.time.milliTimestamp();
    const trimmed = std.mem.trim(u8, self.perf_benchmark_label_input.items, " \t\r\n");
    const label = if (trimmed.len > 0)
        try self.allocator.dupe(u8, trimmed)
    else
        try std.fmt.allocPrint(self.allocator, "bench-{d}", .{now_ms});

    if (self.perf_benchmark_active_label) |value| self.allocator.free(value);
    self.perf_benchmark_active_label = label;
    self.perf_benchmark_active = true;
    self.perf_benchmark_start_sample_index = self.perf_history.items.len;
    self.perf_benchmark_start_timestamp_ms = now_ms;
}

pub fn stopPerfBenchmark(self: anytype) !void {
    if (!self.perf_benchmark_active) return;
    const now_ms = std.time.milliTimestamp();

    self.clearPerfBenchmarkCapture();
    self.perf_benchmark_last_start_sample_index = self.perf_benchmark_start_sample_index;
    self.perf_benchmark_last_end_sample_index = self.perf_history.items.len;
    self.perf_benchmark_last_start_timestamp_ms = self.perf_benchmark_start_timestamp_ms;
    self.perf_benchmark_last_end_timestamp_ms = now_ms;
    if (self.perf_benchmark_active_label) |value| {
        self.perf_benchmark_last_label = value;
        self.perf_benchmark_active_label = null;
    }
    self.perf_benchmark_active = false;
    self.perf_benchmark_start_sample_index = 0;
    self.perf_benchmark_start_timestamp_ms = 0;
}

pub fn buildPerfReportTextForSlice(
    self: anytype,
    report_name: []const u8,
    label: ?[]const u8,
    range_start_ms: ?i64,
    range_end_ms: ?i64,
    samples: anytype,
) ![]u8 {
    const PerfSample = @import("../root.zig").PerfSample;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(self.allocator);

    const latest = if (samples.len > 0)
        samples[samples.len - 1]
    else
        PerfSample{
            .timestamp_ms = std.time.milliTimestamp(),
            .fps = self.perf_last_fps,
            .frame_ms = self.perf_last_frame_ms,
            .ws_poll_ms = self.perf_last_ws_ms,
            .fs_poll_ms = self.perf_last_fs_ms,
            .ws_wait_ms = self.perf_last_ws_wait_ms,
            .fs_request_ms = self.perf_last_fs_request_ms,
            .debug_ms = self.perf_last_debug_ms,
            .terminal_ms = self.perf_last_terminal_ms,
            .draw_ms = self.perf_last_draw_ms,
            .panel_chat_ms = self.perf_last_panel_chat_ms,
            .panel_settings_ms = self.perf_last_panel_settings_ms,
            .panel_debug_ms = self.perf_last_panel_debug_ms,
            .panel_projects_ms = self.perf_last_panel_projects_ms,
            .panel_filesystem_ms = self.perf_last_panel_filesystem_ms,
            .panel_terminal_ms = self.perf_last_panel_terminal_ms,
            .panel_other_ms = self.perf_last_panel_other_ms,
            .cmd_total_per_frame = self.perf_last_cmd_total_per_frame,
            .cmd_text_per_frame = self.perf_last_cmd_text_per_frame,
            .cmd_shape_per_frame = self.perf_last_cmd_shape_per_frame,
            .cmd_line_per_frame = self.perf_last_cmd_line_per_frame,
            .cmd_image_per_frame = self.perf_last_cmd_image_per_frame,
            .cmd_clip_per_frame = self.perf_last_cmd_clip_per_frame,
            .text_bytes_per_frame = self.perf_last_text_bytes_per_frame,
            .text_command_share_pct = self.perf_last_text_command_share_pct,
        };
    const latest_other_ms = @max(
        0.0,
        latest.frame_ms - (latest.draw_ms + latest.ws_poll_ms + latest.fs_poll_ms + latest.debug_ms + latest.terminal_ms),
    );

    try out.writer(self.allocator).print(
        "{s}\ncaptured_at_ms={d}\nsamples={d}\nlatest_fps={d:.2}\nlatest_frame_ms={d:.3}\nlatest_draw_ms={d:.3}\nlatest_other_ms={d:.3}\nlatest_ws_poll_ms={d:.3}\nlatest_fs_poll_ms={d:.3}\nlatest_ws_wait_ms={d:.3}\nlatest_fs_request_ms={d:.3}\nlatest_debug_ms={d:.3}\nlatest_terminal_ms={d:.3}\nlatest_panel_chat_ms={d:.3}\nlatest_panel_settings_ms={d:.3}\nlatest_panel_debug_ms={d:.3}\nlatest_panel_projects_ms={d:.3}\nlatest_panel_filesystem_ms={d:.3}\nlatest_panel_terminal_ms={d:.3}\nlatest_panel_other_ms={d:.3}\nlatest_cmd_total_per_frame={d:.3}\nlatest_cmd_text_per_frame={d:.3}\nlatest_cmd_shape_per_frame={d:.3}\nlatest_cmd_line_per_frame={d:.3}\nlatest_cmd_image_per_frame={d:.3}\nlatest_cmd_clip_per_frame={d:.3}\nlatest_text_bytes_per_frame={d:.3}\nlatest_text_command_share_pct={d:.3}\n",
        .{
            report_name,
            std.time.milliTimestamp(),
            samples.len,
            latest.fps,
            latest.frame_ms,
            latest.draw_ms,
            latest_other_ms,
            latest.ws_poll_ms,
            latest.fs_poll_ms,
            latest.ws_wait_ms,
            latest.fs_request_ms,
            latest.debug_ms,
            latest.terminal_ms,
            latest.panel_chat_ms,
            latest.panel_settings_ms,
            latest.panel_debug_ms,
            latest.panel_projects_ms,
            latest.panel_filesystem_ms,
            latest.panel_terminal_ms,
            latest.panel_other_ms,
            latest.cmd_total_per_frame,
            latest.cmd_text_per_frame,
            latest.cmd_shape_per_frame,
            latest.cmd_line_per_frame,
            latest.cmd_image_per_frame,
            latest.cmd_clip_per_frame,
            latest.text_bytes_per_frame,
            latest.text_command_share_pct,
        },
    );
    if (label) |value| {
        try out.writer(self.allocator).print("benchmark_label={s}\n", .{value});
    }
    if (range_start_ms != null and range_end_ms != null) {
        const start_ms = range_start_ms.?;
        const end_ms = range_end_ms.?;
        const duration_ms: i64 = @max(0, end_ms - start_ms);
        try out.writer(self.allocator).print(
            "range_start_ms={d}\nrange_end_ms={d}\nrange_duration_ms={d}\n",
            .{ start_ms, end_ms, duration_ms },
        );
    }

    try out.appendSlice(self.allocator, "\n# sample_table\ntimestamp_ms,fps,frame_ms,draw_ms,other_ms,ws_poll_ms,fs_poll_ms,ws_wait_ms,fs_request_ms,debug_ms,terminal_ms,panel_chat_ms,panel_settings_ms,panel_debug_ms,panel_projects_ms,panel_filesystem_ms,panel_terminal_ms,panel_other_ms,cmd_total_per_frame,cmd_text_per_frame,cmd_shape_per_frame,cmd_line_per_frame,cmd_image_per_frame,cmd_clip_per_frame,text_bytes_per_frame,text_command_share_pct\n");
    for (samples) |sample| {
        const other_ms = @max(
            0.0,
            sample.frame_ms - (sample.draw_ms + sample.ws_poll_ms + sample.fs_poll_ms + sample.debug_ms + sample.terminal_ms),
        );
        try out.writer(self.allocator).print(
            "{d},{d:.3},{d:.4},{d:.4},{d:.4},{d:.4},{d:.4},{d:.4},{d:.4},{d:.4},{d:.4},{d:.4},{d:.4},{d:.4},{d:.4},{d:.4},{d:.4},{d:.4},{d:.3},{d:.3},{d:.3},{d:.3},{d:.3},{d:.3},{d:.3},{d:.3}\n",
            .{
                sample.timestamp_ms,
                sample.fps,
                sample.frame_ms,
                sample.draw_ms,
                other_ms,
                sample.ws_poll_ms,
                sample.fs_poll_ms,
                sample.ws_wait_ms,
                sample.fs_request_ms,
                sample.debug_ms,
                sample.terminal_ms,
                sample.panel_chat_ms,
                sample.panel_settings_ms,
                sample.panel_debug_ms,
                sample.panel_projects_ms,
                sample.panel_filesystem_ms,
                sample.panel_terminal_ms,
                sample.panel_other_ms,
                sample.cmd_total_per_frame,
                sample.cmd_text_per_frame,
                sample.cmd_shape_per_frame,
                sample.cmd_line_per_frame,
                sample.cmd_image_per_frame,
                sample.cmd_clip_per_frame,
                sample.text_bytes_per_frame,
                sample.text_command_share_pct,
            },
        );
    }

    return out.toOwnedSlice(self.allocator);
}

pub fn buildPerfReportText(self: anytype) ![]u8 {
    return self.buildPerfReportTextForSlice(
        "spider_gui_perf_report",
        null,
        null,
        null,
        self.perf_history.items,
    );
}

pub fn buildBenchmarkPerfReportText(self: anytype) !?[]u8 {
    var label: ?[]const u8 = null;
    var start_ms: i64 = 0;
    var end_ms: i64 = 0;
    if (self.perf_benchmark_active) {
        label = self.perf_benchmark_active_label;
        start_ms = self.perf_benchmark_start_timestamp_ms;
        end_ms = std.time.milliTimestamp();
    } else if (self.perf_benchmark_last_start_timestamp_ms > 0 and
        self.perf_benchmark_last_end_timestamp_ms >= self.perf_benchmark_last_start_timestamp_ms)
    {
        label = self.perf_benchmark_last_label;
        start_ms = self.perf_benchmark_last_start_timestamp_ms;
        end_ms = self.perf_benchmark_last_end_timestamp_ms;
    } else {
        return null;
    }

    var start_idx: usize = 0;
    while (start_idx < self.perf_history.items.len and self.perf_history.items[start_idx].timestamp_ms < start_ms) : (start_idx += 1) {}
    var end_idx: usize = start_idx;
    while (end_idx < self.perf_history.items.len and self.perf_history.items[end_idx].timestamp_ms <= end_ms) : (end_idx += 1) {}

    return @as(?[]u8, try self.buildPerfReportTextForSlice(
        "spider_gui_perf_benchmark_report",
        label,
        start_ms,
        end_ms,
        self.perf_history.items[start_idx..end_idx],
    ));
}

pub fn exportPerfReport(self: anytype, report_text: []const u8) ![]u8 {
    const filename = try std.fmt.allocPrint(
        self.allocator,
        "spider-gui-perf-{d}.txt",
        .{std.time.milliTimestamp()},
    );
    defer self.allocator.free(filename);

    try std.fs.cwd().writeFile(.{
        .sub_path = filename,
        .data = report_text,
    });

    const cwd = std.fs.cwd().realpathAlloc(self.allocator, ".") catch return self.allocator.dupe(u8, filename);
    defer self.allocator.free(cwd);
    return std.fmt.allocPrint(
        self.allocator,
        "{s}{s}{s}",
        .{ cwd, std.fs.path.sep_str, filename },
    );
}

pub fn buildNodeServiceDeltaDiagnosticsTextFromJson(self: anytype, payload_json: []const u8) !?[]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, payload_json, .{});
    defer parsed.deinit();
    return self.buildNodeServiceDeltaDiagnosticsTextFromValue(parsed.value);
}

pub fn buildNodeServiceDeltaDiagnosticsTextFromValue(self: anytype, payload: std.json.Value) !?[]u8 {
    if (payload != .object) return null;
    const payload_obj = payload.object;
    const service_delta = payload_obj.get("service_delta") orelse return null;
    if (service_delta != .object) return null;
    const delta_obj = service_delta.object;

    const node_id = if (payload_obj.get("node_id")) |value| switch (value) {
        .string => value.string,
        else => "unknown",
    } else "unknown";
    const changed = if (delta_obj.get("changed")) |value| switch (value) {
        .bool => value.bool,
        else => false,
    } else false;
    const timestamp_ms: ?i64 = if (delta_obj.get("timestamp_ms")) |value| switch (value) {
        .integer => value.integer,
        else => null,
    } else null;

    const empty_values = &[_]std.json.Value{};
    const added_items: []const std.json.Value = if (delta_obj.get("added")) |value| switch (value) {
        .array => value.array.items,
        else => empty_values,
    } else empty_values;
    const updated_items: []const std.json.Value = if (delta_obj.get("updated")) |value| switch (value) {
        .array => value.array.items,
        else => empty_values,
    } else empty_values;
    const removed_items: []const std.json.Value = if (delta_obj.get("removed")) |value| switch (value) {
        .array => value.array.items,
        else => empty_values,
    } else empty_values;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(self.allocator);
    if (timestamp_ms) |value| {
        try out.writer(self.allocator).print(
            "node={s} changed={s} timestamp_ms={d}",
            .{ node_id, if (changed) "true" else "false", value },
        );
    } else {
        try out.writer(self.allocator).print(
            "node={s} changed={s}",
            .{ node_id, if (changed) "true" else "false" },
        );
    }
    try out.writer(self.allocator).print(
        "\nadded={d} updated={d} removed={d}",
        .{ added_items.len, updated_items.len, removed_items.len },
    );

    const max_entries: usize = 18;
    var shown_entries: usize = 0;
    try self.appendNodeServiceDeltaEntries(&out, "+", added_items, false, max_entries, &shown_entries);
    try self.appendNodeServiceDeltaEntries(&out, "~", updated_items, true, max_entries, &shown_entries);
    try self.appendNodeServiceDeltaEntries(&out, "-", removed_items, false, max_entries, &shown_entries);

    const total_entries = added_items.len + updated_items.len + removed_items.len;
    if (total_entries > shown_entries) {
        try out.writer(self.allocator).print("\n... {d} more service changes", .{total_entries - shown_entries});
    }
    try self.appendNodeServiceRuntimeDiagnostics(
        &out,
        payload_obj,
        added_items,
        updated_items,
    );
    const owned = try out.toOwnedSlice(self.allocator);
    return @as(?[]u8, owned);
}

pub fn appendNodeServiceDeltaEntries(
    self: anytype,
    out: *std.ArrayList(u8),
    prefix: []const u8,
    entries: []const std.json.Value,
    include_previous: bool,
    max_entries: usize,
    shown_entries: *usize,
) !void {
    for (entries) |entry| {
        if (shown_entries.* >= max_entries) break;
        if (entry != .object) continue;
        const obj = entry.object;
        const service_id = if (obj.get("service_id")) |value| switch (value) {
            .string => value.string,
            else => "?",
        } else "?";
        const version = if (obj.get("version")) |value| switch (value) {
            .string => value.string,
            else => "?",
        } else "?";
        var hash_buf: [48]u8 = undefined;
        const hash = nodeServiceDeltaHashText(obj, "hash", "digest", &hash_buf);

        if (include_previous) {
            const previous_version = if (obj.get("previous_version")) |value| switch (value) {
                .string => value.string,
                else => "?",
            } else "?";
            var previous_hash_buf: [48]u8 = undefined;
            const previous_hash = nodeServiceDeltaHashText(obj, "previous_hash", "previous_digest", &previous_hash_buf);
            try out.writer(self.allocator).print(
                "\n{s} {s}@{s} hash={s} prev={s}/{s}",
                .{ prefix, service_id, version, hash, previous_version, previous_hash },
            );
        } else {
            try out.writer(self.allocator).print(
                "\n{s} {s}@{s} hash={s}",
                .{ prefix, service_id, version, hash },
            );
        }
        shown_entries.* += 1;
    }
}

pub fn nodeServiceDeltaHashText(
    obj: std.json.ObjectMap,
    primary_key: []const u8,
    fallback_key: []const u8,
    fallback_buffer: *[48]u8,
) []const u8 {
    if (obj.get(primary_key)) |value| {
        return switch (value) {
            .string => value.string,
            .integer => std.fmt.bufPrint(fallback_buffer, "{d}", .{value.integer}) catch "n/a",
            else => "n/a",
        };
    }
    if (obj.get(fallback_key)) |value| {
        return switch (value) {
            .string => value.string,
            .integer => std.fmt.bufPrint(fallback_buffer, "{d}", .{value.integer}) catch "n/a",
            else => "n/a",
        };
    }
    return "n/a";
}

pub fn appendNodeServiceRuntimeDiagnostics(
    self: anytype,
    out: *std.ArrayList(u8),
    payload_obj: std.json.ObjectMap,
    added_items: []const std.json.Value,
    updated_items: []const std.json.Value,
) !void {
    const services_value = payload_obj.get("services") orelse return;
    if (services_value != .array) return;

    const max_runtime_lines: usize = 12;
    var runtime_lines: usize = 0;
    var appended_header = false;
    for (services_value.array.items) |service| {
        if (runtime_lines >= max_runtime_lines) break;
        if (service != .object) continue;
        const service_id = if (service.object.get("service_id")) |value| switch (value) {
            .string => value.string,
            else => continue,
        } else continue;
        if (!serviceIdPresentInDeltaItems(service_id, added_items, updated_items)) continue;
        if (!serviceHasRuntimeStatus(service.object)) continue;
        if (!appended_header) {
            try out.appendSlice(self.allocator, "\nruntime_status:");
            appended_header = true;
        }
        try out.writer(self.allocator).print("\n* {s}: ", .{service_id});
        try self.appendRuntimeStatusSummary(out, service.object);
        runtime_lines += 1;
    }
    if (runtime_lines == max_runtime_lines) {
        try out.appendSlice(self.allocator, "\n* ... more runtime status entries omitted");
    }
}

pub fn serviceIdPresentInDeltaItems(service_id: []const u8, items_a: []const std.json.Value, items_b: []const std.json.Value) bool {
    if (serviceIdPresentInDeltaArray(service_id, items_a)) return true;
    return serviceIdPresentInDeltaArray(service_id, items_b);
}

pub fn serviceIdPresentInDeltaArray(service_id: []const u8, items: []const std.json.Value) bool {
    for (items) |entry| {
        if (entry != .object) continue;
        const entry_service_id = if (entry.object.get("service_id")) |value| switch (value) {
            .string => value.string,
            else => continue,
        } else continue;
        if (std.mem.eql(u8, service_id, entry_service_id)) return true;
    }
    return false;
}

pub fn serviceHasRuntimeStatus(service_obj: std.json.ObjectMap) bool {
    const runtime_value = service_obj.get("runtime") orelse return false;
    if (runtime_value != .object) return false;
    const supervision_value = runtime_value.object.get("supervision_status") orelse return false;
    return supervision_value == .object;
}

pub fn appendRuntimeStatusSummary(
    self: anytype,
    out: *std.ArrayList(u8),
    service_obj: std.json.ObjectMap,
) !void {
    const runtime_value = service_obj.get("runtime") orelse return;
    if (runtime_value != .object) return;
    const supervision_value = runtime_value.object.get("supervision_status") orelse return;
    if (supervision_value != .object) return;
    const status = supervision_value.object;

    const state = if (status.get("state")) |value| switch (value) {
        .string => value.string,
        else => "unknown",
    } else "unknown";
    const enabled = if (status.get("enabled")) |value| switch (value) {
        .bool => value.bool,
        else => false,
    } else false;
    const running = if (status.get("running")) |value| switch (value) {
        .bool => value.bool,
        else => false,
    } else false;
    const failures = if (status.get("consecutive_failures")) |value| switch (value) {
        .integer => value.integer,
        else => 0,
    } else 0;
    const transition_ms = if (status.get("last_transition_ms")) |value| switch (value) {
        .integer => value.integer,
        else => 0,
    } else 0;
    const healthy_ms = if (status.get("last_healthy_ms")) |value| switch (value) {
        .integer => value.integer,
        else => 0,
    } else 0;
    const last_error = if (status.get("last_error")) |value| switch (value) {
        .string => value.string,
        .null => null,
        else => null,
    } else null;

    try out.writer(self.allocator).print(
        "state={s} enabled={s} running={s} failures={d} transition_ms={d} healthy_ms={d} last_error={s}",
        .{
            state,
            if (enabled) "true" else "false",
            if (running) "true" else "false",
            failures,
            transition_ms,
            healthy_ms,
            if (last_error) |value| value else "none",
        },
    );
}

pub fn jumpFilesystemToNode(self: anytype, manager: anytype, node_id: []const u8) !void {
    const panel_id = try self.ensureFilesystemPanel(manager);
    manager.focusPanel(panel_id);

    const node_path = try std.fmt.allocPrint(
        self.allocator,
        "/nodes/{s}/fs",
        .{node_id},
    );
    defer self.allocator.free(node_path);
    self.fs.filesystem_path.clearRetainingCapacity();
    try self.fs.filesystem_path.appendSlice(self.allocator, node_path);
    try self.queueFilesystemPathLoad(node_path, true, false);
}
