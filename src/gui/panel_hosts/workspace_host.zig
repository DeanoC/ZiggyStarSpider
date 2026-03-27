// workspace_host.zig — Workspace UI, launcher, and workspace overview panel draw functions.

const std = @import("std");
const zui = @import("ziggy-ui");
const zui_panels = @import("ziggy-ui-panels");
const control_plane = @import("control_plane");
const workspace_types = control_plane.workspace_types;
const panels_bridge = @import("../panels_bridge.zig");
const venom_types = @import("../state/venom_types.zig");

const widgets = zui.widgets;
const zcolors = zui.theme.colors;
const form_layout = zui.ui.layout.form_layout;

const Rect = zui.core.Rect;
const Paint = zui.ui.theme_engine.style_sheet.Paint;

const WorkspacePanel = zui_panels.workspace_panel;
const LauncherSettingsPanel = zui_panels.launcher_settings_panel;
const FilesystemToolsPanel = zui_panels.filesystem_tools_panel;
const DebugPanel = zui_panels.debug_panel;
const TerminalPanel = zui_panels.terminal_panel;

const PanelLayoutMetrics = form_layout.Metrics;

// Constants re-declared locally (source of truth: root.zig)
const CONTROL_CONNECT_TIMEOUT_MS: i64 = 2_500;
const APP_LOCAL_NODE_LEASE_TTL_MS: u64 = 15 * 60 * 1000;
const MAX_REASONABLE_PANEL_COUNT: usize = 4096;

// ---------------------------------------------------------------------------
// SettingsFocusField — a subset needed for workspace/launcher focus mapping.
// The canonical definition lives in root.zig; the enum values below must
// match it exactly so that the translation helpers compile correctly when
// this file is used alongside root.zig.
// ---------------------------------------------------------------------------

// NOTE: The translation helpers (projectFocusFieldToExternal, etc.) and the
// host-callback shims (launcherSettingsDrawFormSectionTitle, etc.) that live
// in root.zig are intentionally NOT duplicated here.  This file only contains
// the draw functions and their immediately-required helpers.

// ---------------------------------------------------------------------------
// Standalone helpers
// ---------------------------------------------------------------------------

pub fn maskTokenForDisplay(allocator: std.mem.Allocator, token: []const u8) ![]u8 {
    if (token.len == 0) return allocator.dupe(u8, "(empty)");
    if (token.len <= 8) return allocator.dupe(u8, "****");
    return std.fmt.allocPrint(
        allocator,
        "{s}...{s}",
        .{ token[0..4], token[token.len - 4 ..] },
    );
}

pub fn containsCaseInsensitive(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    return std.ascii.indexOfIgnoreCase(haystack, needle) != null;
}

pub fn pathWithinMount(path: []const u8, mount_path: []const u8) bool {
    if (std.mem.eql(u8, mount_path, "/")) return std.mem.startsWith(u8, path, "/");
    if (!std.mem.startsWith(u8, path, mount_path)) return false;
    if (path.len == mount_path.len) return true;
    return path.len > mount_path.len and path[mount_path.len] == '/';
}

// ---------------------------------------------------------------------------
// WorkspaceHealthState
// ---------------------------------------------------------------------------

pub const WorkspaceHealthState = enum {
    healthy,
    degraded,
    missing,
    unknown,
};

pub fn workspaceHealthState(status: *const workspace_types.WorkspaceStatus) WorkspaceHealthState {
    if (status.availability_missing > 0) return .missing;
    const reconcile_state = status.reconcile_state orelse "";
    if (status.availability_degraded > 0 or
        status.drift_count > 0 or
        status.queue_depth > 0 or
        std.mem.eql(u8, reconcile_state, "degraded"))
    {
        return .degraded;
    }
    if (status.availability_mounts_total == 0 or std.mem.eql(u8, reconcile_state, "unknown")) return .unknown;
    return .healthy;
}

pub fn workspaceHealthStateLabel(state: WorkspaceHealthState) []const u8 {
    return switch (state) {
        .healthy => "healthy",
        .degraded => "degraded",
        .missing => "missing",
        .unknown => "unknown",
    };
}

// ---------------------------------------------------------------------------
// buildLocalNodeTtlText — static helper (no self receiver)
// ---------------------------------------------------------------------------

pub fn buildLocalNodeTtlText(allocator: std.mem.Allocator, nodes: []const workspace_types.NodeInfo, node_id: []const u8) ![]u8 {
    const now_ms = std.time.milliTimestamp();
    for (nodes) |*node| {
        if (!std.mem.eql(u8, node.node_id, node_id)) continue;
        const remaining_ms = node.lease_expires_at_ms - now_ms;
        if (remaining_ms <= 0) {
            return allocator.dupe(u8, "expired");
        }
        const remaining_sec = @divTrunc(remaining_ms, 1000);
        const remaining_min = @divTrunc(remaining_sec, 60);
        if (remaining_min > 0) {
            return std.fmt.allocPrint(allocator, "{d}m {d}s", .{ remaining_min, @mod(remaining_sec, 60) });
        }
        return std.fmt.allocPrint(allocator, "{d}s", .{remaining_sec});
    }
    return allocator.dupe(u8, "offline");
}

// ---------------------------------------------------------------------------
// OwnedWorkspacePanelView — standalone (not nested inside App)
// ---------------------------------------------------------------------------

pub const OwnedWorkspacePanelView = struct {
    selected_workspace_button_label: ?[]u8 = null,
    session_status_line: ?[]u8 = null,
    selected_workspace_line: ?[]u8 = null,
    setup_status_line: ?[]u8 = null,
    setup_vision_line: ?[]u8 = null,
    template_line: ?[]u8 = null,
    binds_line: ?[]u8 = null,
    workspace_summary_line: ?[]u8 = null,
    workspace_health_line: ?[]u8 = null,
    counts_line: ?[]u8 = null,
    workspace_lines: std.ArrayListUnmanaged([]u8) = .{},
    projects: std.ArrayListUnmanaged(panels_bridge.WorkspaceListEntryView) = .{},
    node_lines: std.ArrayListUnmanaged([]u8) = .{},
    nodes: std.ArrayListUnmanaged(panels_bridge.WorkspaceNodeEntryView) = .{},
    mount_entries: std.ArrayListUnmanaged(panels_bridge.WorkspaceMountEntryView) = .{},
    bind_entries: std.ArrayListUnmanaged(panels_bridge.WorkspaceBindEntryView) = .{},
    node_picker_entries: std.ArrayListUnmanaged(panels_bridge.WorkspaceNodePickerEntryView) = .{},
    token_display: ?[]u8 = null,
    local_node_ttl_text: ?[]u8 = null,
    view: panels_bridge.WorkspacePanelView = .{},

    pub fn deinit(self: *OwnedWorkspacePanelView, allocator: std.mem.Allocator) void {
        if (self.selected_workspace_button_label) |value| allocator.free(value);
        if (self.session_status_line) |value| allocator.free(value);
        if (self.selected_workspace_line) |value| allocator.free(value);
        if (self.setup_status_line) |value| allocator.free(value);
        if (self.setup_vision_line) |value| allocator.free(value);
        if (self.template_line) |value| allocator.free(value);
        if (self.binds_line) |value| allocator.free(value);
        if (self.workspace_summary_line) |value| allocator.free(value);
        if (self.workspace_health_line) |value| allocator.free(value);
        if (self.counts_line) |value| allocator.free(value);
        if (self.token_display) |value| allocator.free(value);
        if (self.local_node_ttl_text) |value| allocator.free(value);
        for (self.workspace_lines.items) |value| allocator.free(value);
        for (self.node_lines.items) |value| allocator.free(value);
        self.workspace_lines.deinit(allocator);
        self.projects.deinit(allocator);
        self.node_lines.deinit(allocator);
        self.nodes.deinit(allocator);
        self.mount_entries.deinit(allocator);
        self.bind_entries.deinit(allocator);
        self.node_picker_entries.deinit(allocator);
        self.* = undefined;
    }
};

// ---------------------------------------------------------------------------
// buildWorkspacePanelView
// ---------------------------------------------------------------------------

pub fn buildWorkspacePanelView(self: anytype) OwnedWorkspacePanelView {
    var owned: OwnedWorkspacePanelView = .{};
    const selected_workspace_lock_state = self.selectedWorkspaceTokenLocked();
    const selected_summary = self.selectedWorkspaceSummary();

    const selected_workspace_button_label: []const u8 = blk: {
        if (self.settings_panel.project_id.items.len == 0) break :blk "Select workspace";
        const selected_id = self.settings_panel.project_id.items;
        for (self.ws.projects.items) |project| {
            if (std.mem.eql(u8, project.id, selected_id)) {
                const formatted = std.fmt.allocPrint(
                    self.allocator,
                    "{s} ({s}) [{s}]",
                    .{
                        project.name,
                        project.id,
                        if (project.token_locked) "locked" else "open",
                    },
                ) catch null;
                if (formatted) |value| {
                    owned.selected_workspace_button_label = value;
                    break :blk value;
                }
                break :blk selected_id;
            }
        }
        break :blk selected_id;
    };

    const lock_state_text: []const u8 = if (self.selectedWorkspaceId() == null)
        "Workspace lock state: select a workspace"
    else if (selected_workspace_lock_state) |locked|
        if (locked)
            "Workspace lock state: locked (workspace token required for non-admin)"
        else
            "Workspace lock state: unlocked (workspace token optional)"
    else
        "Workspace lock state: unknown (workspace not in current list)";

    const add_mount_validation = self.validateWorkspaceMountAddInput();
    const remove_mount_validation = self.validateWorkspaceMountRemoveInput();
    const add_bind_validation = self.validateWorkspaceBindAddInput();
    const remove_bind_validation = self.validateWorkspaceBindRemoveInput();
    const mount_hint = if (self.connection_state == .connected)
        (add_mount_validation orelse remove_mount_validation)
    else
        null;
    const bind_hint = if (self.connection_state == .connected)
        (add_bind_validation orelse remove_bind_validation)
    else
        null;

    var session_status_warning = false;
    owned.session_status_line = switch (self.session_attach_state) {
        .ready => std.fmt.allocPrint(
            self.allocator,
            "Live session attached: {s}",
            .{self.chat.current_session_key orelse self.settings_panel.default_session.items},
        ) catch null,
        .err => blk: {
            session_status_warning = true;
            break :blk std.fmt.allocPrint(
                self.allocator,
                "Live chat unavailable: {s}",
                .{self.ws.workspace_last_error orelse "session attach failed"},
            ) catch null;
        },
        .unknown, .warming => blk: {
            session_status_warning = true;
            break :blk self.allocator.dupe(
                u8,
                "Live chat is off. Select a workspace, finish setup, then use Attach Session when you want a Spiderweb runtime.",
            ) catch null;
        },
    };

    const selected_workspace_text = if (self.settings_panel.project_id.items.len > 0)
        self.settings_panel.project_id.items
    else
        "(none)";
    const selected_workspace_lock_suffix: []const u8 = if (selected_workspace_lock_state) |locked|
        if (locked) " [locked]" else " [open]"
    else
        "";
    owned.selected_workspace_line = std.fmt.allocPrint(
        self.allocator,
        "Selected workspace: {s}{s}",
        .{ selected_workspace_text, selected_workspace_lock_suffix },
    ) catch null;

    var setup_status_warning = false;
    if (self.connect_setup_hint) |hint| {
        const setup_status = if (hint.required) "required" else "ready";
        owned.setup_status_line = std.fmt.allocPrint(
            self.allocator,
            "Workspace setup: {s}",
            .{setup_status},
        ) catch null;
        setup_status_warning = hint.required;
        if (hint.workspace_vision) |vision| {
            owned.setup_vision_line = std.fmt.allocPrint(
                self.allocator,
                "Workspace vision: {s}",
                .{vision},
            ) catch null;
        }
    }

    if (selected_summary) |summary| {
        const template_text = summary.template_id orelse "dev";
        owned.template_line = std.fmt.allocPrint(
            self.allocator,
            "Workspace template: {s}",
            .{template_text},
        ) catch null;
        if (bind_hint) |hint| {
            owned.binds_line = std.fmt.allocPrint(
                self.allocator,
                "Workspace binds: {d}. {s}",
                .{ summary.bind_count, hint },
            ) catch null;
        } else {
            owned.binds_line = std.fmt.allocPrint(
                self.allocator,
                "Workspace binds: {d}",
                .{summary.bind_count},
            ) catch null;
        }
    } else if (bind_hint) |hint| {
        owned.binds_line = self.allocator.dupe(u8, hint) catch null;
    }

    var workspace_health_warning = false;
    var workspace_health_error = false;
    if (self.ws.workspace_state) |*status| {
        const root_text = status.workspace_root orelse "(none)";
        const mounted_count: usize = if (status.actual_mounts.items.len > 0)
            status.actual_mounts.items.len
        else
            status.mounts.items.len;
        owned.workspace_summary_line = std.fmt.allocPrint(
            self.allocator,
            "Workspace root: {s} | mounts: {d}",
            .{ root_text, mounted_count },
        ) catch null;

        const health_state = workspaceHealthState(status);
        owned.workspace_health_line = std.fmt.allocPrint(
            self.allocator,
            "Workspace health: {s} | online={d}/{d} degraded={d} missing={d} drift={d}",
            .{
                workspaceHealthStateLabel(health_state),
                status.availability_online,
                status.availability_mounts_total,
                status.availability_degraded,
                status.availability_missing,
                status.drift_count,
            },
        ) catch null;
        switch (health_state) {
            .healthy, .unknown => {},
            .degraded => workspace_health_warning = true,
            .missing => workspace_health_error = true,
        }
    }

    owned.counts_line = std.fmt.allocPrint(
        self.allocator,
        "Workspaces: {d} | Nodes: {d}",
        .{ self.ws.projects.items.len, self.ws.nodes.items.len },
    ) catch null;

    for (self.ws.projects.items, 0..) |project, idx| {
        const line = std.fmt.allocPrint(
            self.allocator,
            "{s} [{s}] access={s} template={s} mounts={d} binds={d}",
            .{
                project.id,
                project.status,
                if (project.token_locked) "locked" else "open",
                project.template_id orelse "dev",
                project.mount_count,
                project.bind_count,
            },
        ) catch continue;
        owned.workspace_lines.append(self.allocator, line) catch {
            self.allocator.free(line);
            continue;
        };
        const project_selected = self.settings_panel.project_id.items.len > 0 and
            std.mem.eql(u8, self.settings_panel.project_id.items, project.id);
        owned.projects.append(self.allocator, .{
            .index = idx,
            .line = line,
            .selected = project_selected,
        }) catch {};
    }

    const now_ms = std.time.milliTimestamp();
    for (self.ws.nodes.items) |node| {
        const node_online = node.lease_expires_at_ms > now_ms;
        const line = std.fmt.allocPrint(
            self.allocator,
            "  - {s} ({s}) [{s}]",
            .{ node.node_id, node.node_name, if (node_online) "online" else "degraded" },
        ) catch continue;
        owned.node_lines.append(self.allocator, line) catch {
            self.allocator.free(line);
            continue;
        };
        owned.nodes.append(self.allocator, .{
            .line = line,
            .degraded = !node_online,
        }) catch {};
    }

    if (self.ws.selected_workspace_detail) |*detail| {
        for (detail.mounts.items, 0..) |*mount, idx| {
            owned.mount_entries.append(self.allocator, .{
                .index = idx,
                .mount_path = mount.mount_path,
                .node_id = mount.node_id,
                .node_name = mount.node_name,
                .export_name = mount.export_name,
                .selected = self.ws.workspace_selected_mount_index == idx,
            }) catch {};
        }
        for (detail.binds.items, 0..) |*bind, idx| {
            owned.bind_entries.append(self.allocator, .{
                .index = idx,
                .bind_path = bind.bind_path,
                .target_path = bind.target_path,
                .selected = self.ws.workspace_selected_bind_index == idx,
            }) catch {};
        }
        if (detail.workspace_token) |token| {
            owned.token_display = maskTokenForDisplay(self.allocator, token) catch null;
        }
    }

    if (self.ws.node_browser_open) {
        const now_ms_for_nodes = std.time.milliTimestamp();
        for (self.ws.nodes.items, 0..) |*node, idx| {
            const node_online = node.lease_expires_at_ms > now_ms_for_nodes;
            owned.node_picker_entries.append(self.allocator, .{
                .index = idx,
                .node_id = node.node_id,
                .node_name = node.node_name,
                .online = node_online,
                .selected = self.ws.node_browser_selected_index == idx,
            }) catch {};
        }
    }

    const profile_id = self.config.selectedProfileId();
    var local_node_id_val: ?[]const u8 = null;
    var local_node_name_val: ?[]const u8 = null;
    var local_node_bootstrapped_val: bool = false;
    if (self.config.appLocalNode(profile_id)) |local_node| {
        local_node_id_val = local_node.node_id;
        local_node_name_val = local_node.node_name;
        local_node_bootstrapped_val = true;
        owned.local_node_ttl_text = buildLocalNodeTtlText(self.allocator, self.ws.nodes.items, local_node.node_id) catch null;
    }

    owned.view = .{
        .title = "Workspace Overview",
        .selected_workspace_button_label = selected_workspace_button_label,
        .lock_state_text = lock_state_text,
        .workspace_token = self.settings_panel.project_token.items,
        .create_name = self.settings_panel.project_create_name.items,
        .create_vision = self.settings_panel.project_create_vision.items,
        .template_id = self.settings_panel.workspace_template_id.items,
        .operator_token = self.settings_panel.project_operator_token.items,
        .mount_path = self.settings_panel.project_mount_path.items,
        .mount_node_id = self.settings_panel.project_mount_node_id.items,
        .mount_export_name = self.settings_panel.project_mount_export_name.items,
        .bind_path = self.settings_panel.workspace_bind_path.items,
        .bind_target_path = self.settings_panel.workspace_bind_target_path.items,
        .mount_hint = mount_hint,
        .workspace_error_text = self.ws.workspace_last_error,
        .session_status_line = owned.session_status_line,
        .session_status_warning = session_status_warning,
        .selected_workspace_line = owned.selected_workspace_line,
        .setup_status_line = owned.setup_status_line,
        .setup_status_warning = setup_status_warning,
        .setup_vision_line = owned.setup_vision_line,
        .template_line = owned.template_line,
        .binds_line = owned.binds_line,
        .workspace_summary_line = owned.workspace_summary_line,
        .workspace_health_line = owned.workspace_health_line,
        .workspace_health_warning = workspace_health_warning,
        .workspace_health_error = workspace_health_error,
        .counts_line = owned.counts_line,
        .help_line = if (self.session_attach_state == .ready)
            "Open Filesystem, Debug, or Terminal panels from the Windows menu."
        else
            "External workers can use the workspace without live chat. Use Attach Session only when you want a Spiderweb runtime.",
        .workspaces = owned.projects.items,
        .nodes = owned.nodes.items,
        .mounts = owned.mount_entries.items,
        .binds = owned.bind_entries.items,
        .nodes_for_picker = owned.node_picker_entries.items,
        .token_display = owned.token_display,
        .local_node_id = local_node_id_val,
        .local_node_name = local_node_name_val,
        .local_node_ttl_text = owned.local_node_ttl_text,
        .local_node_bootstrapped = local_node_bootstrapped_val,
        .workspace_op_busy = self.ws.workspace_op_busy,
        .workspace_op_error = null,
    };
    return owned;
}

// ---------------------------------------------------------------------------
// drawLauncherUi
// ---------------------------------------------------------------------------

pub fn drawLauncherUi(self: anytype, ui_window: anytype, fb_width: u32, fb_height: u32) void {
    self.ui_commands.clear();
    const ui_draw_context = zui.ui.draw_context;
    ui_draw_context.setGlobalCommandList(&self.ui_commands);
    defer ui_draw_context.clearGlobalCommandList();

    const menu_h = self.windowMenuBarHeight();
    const status_h: f32 = 24.0 * self.ui_scale;
    const content_rect = Rect.fromXYWH(
        0,
        menu_h,
        @floatFromInt(fb_width),
        @max(1.0, @as(f32, @floatFromInt(fb_height)) - menu_h - status_h),
    );
    const UiRect = ui_draw_context.Rect;
    ui_window.ui_state.last_dock_content_rect = UiRect.fromMinSize(content_rect.min, .{
        content_rect.width(),
        content_rect.height(),
    });

    const shell = self.sharedStyleSheet().shell;
    const surfaces = self.sharedStyleSheet().surfaces;
    const full_rect = Rect.fromXYWH(0, 0, @floatFromInt(fb_width), @floatFromInt(fb_height));
    self.drawPaintRect(
        full_rect,
        surfaces.background orelse Paint{ .solid = self.theme.colors.background },
    );
    self.drawPaintRect(
        content_rect,
        shell.dock_fill orelse surfaces.surface orelse Paint{ .solid = self.theme.colors.surface },
    );
    if (shell.dock_border) |dock_border| self.drawRect(content_rect, dock_border);

    const launcher_modal_open = self.ws.launcher_create_modal_open;
    const saved_mouse_down = self.mouse_down;
    const saved_mouse_clicked = self.mouse_clicked;
    const saved_mouse_released = self.mouse_released;
    const saved_mouse_right_clicked = self.mouse_right_clicked;
    if (launcher_modal_open) {
        // Keep launcher visible under the modal, but route pointer input only to modal widgets.
        self.mouse_down = false;
        self.mouse_clicked = false;
        self.mouse_released = false;
        self.mouse_right_clicked = false;
    }

    const layout = self.panelLayoutMetrics();
    const pad = layout.inset;
    const gap = layout.section_gap;
    const left_width = @max(260.0 * self.ui_scale, content_rect.width() * 0.33);
    const right_width = @max(320.0 * self.ui_scale, content_rect.width() - left_width - gap - pad * 2.0);
    const left_rect = Rect.fromXYWH(
        content_rect.min[0] + pad,
        content_rect.min[1] + pad,
        left_width,
        @max(1.0, content_rect.height() - pad * 2.0),
    );
    const right_rect = Rect.fromXYWH(
        left_rect.max[0] + gap,
        content_rect.min[1] + pad,
        right_width,
        @max(1.0, content_rect.height() - pad * 2.0),
    );

    const sidebar_fill = shell.sidebar_fill orelse surfaces.surface orelse Paint{ .solid = self.theme.colors.surface };
    const sidebar_border = self.sharedStyleSheet().panel.border orelse self.theme.colors.border;
    self.drawPaintRect(left_rect, sidebar_fill);
    self.drawRect(left_rect, sidebar_border);
    self.drawPaintRect(right_rect, sidebar_fill);
    self.drawRect(right_rect, sidebar_border);

    var left_y = left_rect.min[1] + pad;
    const title = "Spider Web Connections";
    self.drawLabel(left_rect.min[0] + pad, left_y, title, self.theme.colors.text_primary);
    left_y += layout.line_height + layout.row_gap;

    const profile_row_h = @max(layout.button_height, 34.0 * self.ui_scale);
    const profile_row_w = left_rect.width() - pad * 2.0;
    const profiles_rect_h = @max(140.0 * self.ui_scale, left_rect.height() * 0.30);
    const profiles_rect = Rect.fromXYWH(
        left_rect.min[0] + pad,
        left_y,
        profile_row_w,
        profiles_rect_h,
    );
    self.drawSurfacePanel(profiles_rect);
    self.drawRect(profiles_rect, self.theme.colors.border);

    const selected_index = @min(
        self.ws.launcher_selected_profile_index,
        if (self.config.connection_profiles.len > 0) self.config.connection_profiles.len - 1 else 0,
    );
    var profile_row_y = profiles_rect.min[1] + layout.inner_inset;
    if (self.config.connection_profiles.len == 0) {
        self.drawTextTrimmed(
            profiles_rect.min[0] + layout.inner_inset,
            profile_row_y,
            profiles_rect.width() - layout.inner_inset * 2.0,
            "No connection profiles. Create one below.",
            self.theme.colors.text_secondary,
        );
    } else {
        for (self.config.connection_profiles, 0..) |profile, idx| {
            if (profile_row_y + profile_row_h > profiles_rect.max[1] - layout.inner_inset) break;
            const label = if (std.mem.eql(u8, profile.id, self.config.selectedProfileId()))
                profile.name
            else
                profile.server_url;
            if (self.drawButtonWidget(
                Rect.fromXYWH(
                    profiles_rect.min[0] + layout.inner_inset,
                    profile_row_y,
                    profiles_rect.width() - layout.inner_inset * 2.0,
                    profile_row_h,
                ),
                label,
                .{ .variant = if (idx == selected_index) .primary else .secondary },
            )) {
                self.ws.launcher_selected_profile_index = idx;
                self.applyLauncherSelectedProfile() catch |err| {
                    std.log.warn("Failed to apply selected profile: {s}", .{@errorName(err)});
                };
            }
            profile_row_y += profile_row_h + layout.row_gap * 0.6;
        }
    }
    left_y = profiles_rect.max[1] + layout.section_gap * 0.6;

    self.drawLabel(left_rect.min[0] + pad, left_y, "Profile Name", self.theme.colors.text_secondary);
    left_y += layout.line_height + layout.row_gap * 0.25;
    const profile_name_focused = self.drawTextInputWidget(
        Rect.fromXYWH(left_rect.min[0] + pad, left_y, profile_row_w, layout.input_height),
        self.ws.launcher_profile_name.items,
        self.settings_panel.focused_field == .launcher_profile_name,
        .{ .placeholder = "Display name" },
    );
    if (profile_name_focused) self.settings_panel.focused_field = .launcher_profile_name;
    left_y += layout.input_height + layout.row_gap * 0.55;

    self.drawLabel(left_rect.min[0] + pad, left_y, "Server URL", self.theme.colors.text_secondary);
    left_y += layout.line_height + layout.row_gap * 0.25;
    const url_focused = self.drawTextInputWidget(
        Rect.fromXYWH(left_rect.min[0] + pad, left_y, profile_row_w, layout.input_height),
        self.settings_panel.server_url.items,
        self.settings_panel.focused_field == .server_url,
        .{ .placeholder = "ws://host:port" },
    );
    if (url_focused) self.settings_panel.focused_field = .server_url;
    left_y += layout.input_height + layout.row_gap * 0.55;

    self.drawLabel(left_rect.min[0] + pad, left_y, "Metadata", self.theme.colors.text_secondary);
    left_y += layout.line_height + layout.row_gap * 0.25;
    const metadata_focused = self.drawTextInputWidget(
        Rect.fromXYWH(left_rect.min[0] + pad, left_y, profile_row_w, layout.input_height),
        self.ws.launcher_profile_metadata.items,
        self.settings_panel.focused_field == .launcher_profile_metadata,
        .{ .placeholder = "Optional notes" },
    );
    if (metadata_focused) self.settings_panel.focused_field = .launcher_profile_metadata;
    left_y += layout.input_height + layout.row_gap * 0.55;

    self.drawLabel(left_rect.min[0] + pad, left_y, "Role", self.theme.colors.text_secondary);
    left_y += layout.line_height + layout.row_gap * 0.25;
    const role_button_w = (profile_row_w - pad) * 0.5;
    if (self.drawButtonWidget(
        Rect.fromXYWH(left_rect.min[0] + pad, left_y, role_button_w, layout.button_height),
        "Admin",
        .{ .variant = if (self.config.active_role == .admin) .primary else .secondary },
    )) {
        self.setActiveConnectRole(.admin) catch {};
    }
    if (self.drawButtonWidget(
        Rect.fromXYWH(left_rect.min[0] + pad + role_button_w + pad, left_y, role_button_w, layout.button_height),
        "User",
        .{ .variant = if (self.config.active_role == .user) .primary else .secondary },
    )) {
        self.setActiveConnectRole(.user) catch {};
    }
    left_y += layout.button_height + layout.row_gap * 0.8;

    self.drawLabel(
        left_rect.min[0] + pad,
        left_y,
        "Access Token",
        self.theme.colors.text_secondary,
    );
    left_y += layout.line_height + layout.row_gap * 0.25;
    const connect_token_focused = self.drawTextInputWidget(
        Rect.fromXYWH(left_rect.min[0] + pad, left_y, profile_row_w, layout.input_height),
        self.ws.launcher_connect_token.items,
        self.settings_panel.focused_field == .launcher_connect_token,
        .{
            .placeholder = "Spiderweb access token",
        },
    );
    if (connect_token_focused) self.settings_panel.focused_field = .launcher_connect_token;
    left_y += layout.input_height + layout.row_gap * 0.55;

    if (self.drawButtonWidget(
        Rect.fromXYWH(left_rect.min[0] + pad, left_y, role_button_w, profile_row_h),
        "New Profile",
        .{ .variant = .secondary },
    )) {
        self.createConnectionProfileFromLauncher() catch |err| {
            const msg = std.fmt.allocPrint(self.allocator, "Profile create failed: {s}", .{@errorName(err)}) catch null;
            defer if (msg) |value| self.allocator.free(value);
            if (msg) |value| self.setLauncherNotice(value);
        };
    }
    if (self.drawButtonWidget(
        Rect.fromXYWH(left_rect.min[0] + pad + role_button_w + pad, left_y, role_button_w, profile_row_h),
        "Save Profile",
        .{ .variant = .secondary, .disabled = self.config.connection_profiles.len == 0 },
    )) {
        self.saveSelectedProfileFromLauncher() catch |err| {
            const msg = std.fmt.allocPrint(self.allocator, "Profile save failed: {s}", .{@errorName(err)}) catch null;
            defer if (msg) |value| self.allocator.free(value);
            if (msg) |value| self.setLauncherNotice(value);
        };
    }
    left_y += profile_row_h + layout.row_gap;

    if (self.drawButtonWidget(
        Rect.fromXYWH(left_rect.min[0] + pad, left_y, role_button_w, profile_row_h),
        if (self.connection_state == .connected) "Disconnect" else "Connect",
        .{ .variant = .primary, .disabled = self.connection_state == .connecting },
    )) {
        if (self.connection_state == .connected) {
            self.disconnect();
            self.setConnectionState(.disconnected, "Disconnected");
        } else {
            self.persistLauncherConnectToken() catch |err| {
                const msg = std.fmt.allocPrint(self.allocator, "Unable to persist token: {s}", .{@errorName(err)}) catch null;
                defer if (msg) |value| self.allocator.free(value);
                if (msg) |value| self.setLauncherNotice(value);
                return;
            };
            self.tryConnect(&self.manager) catch {};
            if (self.connection_state == .connected) {
                self.refreshWorkspaceData() catch {};
            }
        }
    }
    if (self.drawButtonWidget(
        Rect.fromXYWH(left_rect.min[0] + pad + role_button_w + pad, left_y, role_button_w, profile_row_h),
        "Refresh",
        .{ .variant = .secondary, .disabled = self.connection_state != .connected },
    )) {
        self.refreshWorkspaceData() catch |err| {
            const msg = std.fmt.allocPrint(self.allocator, "Refresh failed: {s}", .{@errorName(err)}) catch null;
            defer if (msg) |value| self.allocator.free(value);
            if (msg) |value| self.setLauncherNotice(value);
        };
    }

    var right_y = right_rect.min[1] + pad;
    self.drawLabel(right_rect.min[0] + pad, right_y, "Workspaces", self.theme.colors.text_primary);
    right_y += layout.line_height + layout.row_gap * 0.6;
    if (self.ws.launcher_notice) |notice| {
        self.drawTextTrimmed(
            right_rect.min[0] + pad,
            right_y,
            right_rect.width() - pad * 2.0,
            notice,
            self.theme.colors.text_secondary,
        );
        right_y += layout.line_height + layout.row_gap * 0.7;
    }

    const filter_rect = Rect.fromXYWH(
        right_rect.min[0] + pad,
        right_y,
        right_rect.width() - pad * 2.0,
        layout.input_height,
    );
    const filter_focused = self.drawTextInputWidget(
        filter_rect,
        self.ws.launcher_project_filter.items,
        self.settings_panel.focused_field == .launcher_project_filter,
        .{ .placeholder = "Search workspaces" },
    );
    if (filter_focused) self.settings_panel.focused_field = .launcher_project_filter;
    right_y += layout.input_height + layout.row_gap;

    const project_row_h = @max(layout.button_height, 32.0 * self.ui_scale);
    const list_h = @max(1.0, right_rect.max[1] - right_y - pad - project_row_h - layout.row_gap);
    const list_rect = Rect.fromXYWH(right_rect.min[0] + pad, right_y, right_rect.width() - pad * 2.0, list_h);
    self.drawSurfacePanel(list_rect);
    self.drawRect(list_rect, self.theme.colors.border);

    var project_row_y = list_rect.min[1] + layout.inner_inset;
    for (self.ws.projects.items) |project| {
        if (project_row_y + project_row_h > list_rect.max[1] - layout.inner_inset) break;
        const matches_filter = self.ws.launcher_project_filter.items.len == 0 or
            containsCaseInsensitive(project.name, self.ws.launcher_project_filter.items) or
            containsCaseInsensitive(project.id, self.ws.launcher_project_filter.items);
        if (!matches_filter) continue;
        const is_selected = self.settings_panel.project_id.items.len > 0 and std.mem.eql(u8, self.settings_panel.project_id.items, project.id);
        if (self.drawButtonWidget(
            Rect.fromXYWH(list_rect.min[0] + layout.inner_inset, project_row_y, list_rect.width() - layout.inner_inset * 2.0, project_row_h),
            project.name,
            .{ .variant = if (is_selected) .primary else .secondary },
        )) {
            self.selectWorkspaceInSettings(project.id) catch {};
        }
        project_row_y += project_row_h + layout.row_gap * 0.5;
    }

    const open_rect = Rect.fromXYWH(
        right_rect.min[0] + pad,
        right_rect.max[1] - pad - project_row_h,
        @max(160.0 * self.ui_scale, right_rect.width() * 0.4),
        project_row_h,
    );
    if (self.drawButtonWidget(
        open_rect,
        "Open Workspace",
        .{ .variant = .primary, .disabled = self.connection_state != .connected or self.selectedWorkspaceId() == null },
    )) {
        self.openSelectedWorkspaceFromLauncher() catch |err| {
            const msg = self.formatControlOpError("Failed to open workspace", err);
            if (msg) |value| {
                defer self.allocator.free(value);
                self.setLauncherNotice(value);
            }
        };
    }

    const create_rect = Rect.fromXYWH(
        open_rect.max[0] + pad,
        right_rect.max[1] - pad - project_row_h,
        @max(160.0 * self.ui_scale, right_rect.width() * 0.4),
        project_row_h,
    );
    if (self.drawButtonWidget(
        create_rect,
        "Create Workspace",
        .{ .variant = .secondary, .disabled = self.connection_state != .connected },
    )) {
        self.openLauncherCreateWorkspaceModal();
    }

    _ = self.drawWindowMenuBar(ui_window, fb_width);
    self.drawStatusOverlay(fb_width, fb_height);
    if (launcher_modal_open) {
        self.mouse_down = saved_mouse_down;
        self.mouse_clicked = saved_mouse_clicked;
        self.mouse_released = saved_mouse_released;
        self.mouse_right_clicked = saved_mouse_right_clicked;
        self.drawLauncherCreateWorkspaceModal(fb_width, fb_height);
    }
    if (self.ws.workspace_wizard_open) {
        self.mouse_down = saved_mouse_down;
        self.mouse_clicked = saved_mouse_clicked;
        self.mouse_released = saved_mouse_released;
        self.mouse_right_clicked = saved_mouse_right_clicked;
        self.drawWorkspaceWizardModal(fb_width, fb_height);
    }
}

// ---------------------------------------------------------------------------
// drawLauncherCreateWorkspaceModal
// ---------------------------------------------------------------------------

pub fn drawLauncherCreateWorkspaceModal(self: anytype, fb_width: u32, fb_height: u32) void {
    const layout = self.panelLayoutMetrics();
    const pad = @max(layout.inset, 12.0 * self.ui_scale);
    const row_h = @max(layout.button_height, 34.0 * self.ui_scale);
    const screen_rect = Rect.fromXYWH(0, 0, @floatFromInt(fb_width), @floatFromInt(fb_height));

    self.drawFilledRect(screen_rect, zcolors.withAlpha(self.theme.colors.background, 0.68));

    const modal_w = std.math.clamp(
        screen_rect.width() * 0.62,
        420.0 * self.ui_scale,
        760.0 * self.ui_scale,
    );
    const modal_h = std.math.clamp(
        screen_rect.height() * 0.72,
        360.0 * self.ui_scale,
        640.0 * self.ui_scale,
    );
    const modal_rect = Rect.fromXYWH(
        screen_rect.min[0] + (screen_rect.width() - modal_w) * 0.5,
        screen_rect.min[1] + (screen_rect.height() - modal_h) * 0.5,
        modal_w,
        modal_h,
    );

    self.drawSurfacePanel(modal_rect);
    self.drawRect(modal_rect, self.theme.colors.border);

    var y = modal_rect.min[1] + pad;
    const field_w = modal_rect.width() - pad * 2.0;

    self.drawLabel(modal_rect.min[0] + pad, y, "Create Workspace", self.theme.colors.text_primary);
    y += layout.line_height + layout.row_gap * 0.35;
    self.drawTextTrimmed(
        modal_rect.min[0] + pad,
        y,
        field_w,
        "Pick a Spiderweb template and create a new workspace.",
        self.theme.colors.text_secondary,
    );
    y += layout.line_height + layout.row_gap * 0.8;

    if (self.ws.launcher_create_modal_error) |message| {
        self.drawTextTrimmed(
            modal_rect.min[0] + pad,
            y,
            field_w,
            message,
            zcolors.rgba(220, 80, 80, 255),
        );
        y += layout.line_height + layout.row_gap * 0.65;
    }

    self.drawLabel(modal_rect.min[0] + pad, y, "Workspace Name", self.theme.colors.text_secondary);
    y += layout.line_height + layout.row_gap * 0.25;
    const name_focused = self.drawTextInputWidget(
        Rect.fromXYWH(modal_rect.min[0] + pad, y, field_w, layout.input_height),
        self.settings_panel.project_create_name.items,
        self.settings_panel.focused_field == .project_create_name,
        .{ .placeholder = "Example: Distributed Workspace" },
    );
    if (name_focused) self.settings_panel.focused_field = .project_create_name;
    y += layout.input_height + layout.row_gap * 0.6;

    self.drawLabel(modal_rect.min[0] + pad, y, "Vision (Optional)", self.theme.colors.text_secondary);
    y += layout.line_height + layout.row_gap * 0.25;
    const vision_focused = self.drawTextInputWidget(
        Rect.fromXYWH(modal_rect.min[0] + pad, y, field_w, layout.input_height),
        self.settings_panel.project_create_vision.items,
        self.settings_panel.focused_field == .project_create_vision,
        .{ .placeholder = "Short goal or context" },
    );
    if (vision_focused) self.settings_panel.focused_field = .project_create_vision;
    y += layout.input_height + layout.row_gap * 0.8;

    const action_y = modal_rect.max[1] - pad - row_h;
    const detail_h = layout.line_height * 2.2;
    const detail_y = action_y - layout.row_gap - detail_h;

    const template_header_y = y;
    self.drawLabel(modal_rect.min[0] + pad, template_header_y, "Template", self.theme.colors.text_secondary);

    const refresh_w = @max(160.0 * self.ui_scale, self.measureText("Refresh Templates") + pad * 1.4);
    const refresh_rect = Rect.fromXYWH(
        modal_rect.max[0] - pad - refresh_w,
        template_header_y - @max(0.0, (row_h - layout.line_height) * 0.3),
        refresh_w,
        row_h,
    );
    if (self.drawButtonWidget(
        refresh_rect,
        "Refresh Templates",
        .{ .variant = .secondary, .disabled = self.connection_state != .connected },
    )) {
        self.clearLauncherCreateWorkspaceModalError();
        self.refreshLauncherCreateWorkspaceTemplates() catch |err| {
            const msg = self.formatControlOpError("Workspace template list failed", err);
            if (msg) |text| {
                defer self.allocator.free(text);
                self.setLauncherCreateWorkspaceModalError(text);
            } else {
                self.setLauncherCreateWorkspaceModalError("Workspace template list failed.");
            }
        };
    }
    y += row_h + layout.row_gap * 0.4;

    const list_bottom = detail_y - layout.row_gap * 0.5;
    const list_h = @max(88.0 * self.ui_scale, list_bottom - y);
    const list_rect = Rect.fromXYWH(modal_rect.min[0] + pad, y, field_w, list_h);
    self.drawSurfacePanel(list_rect);
    self.drawRect(list_rect, self.theme.colors.border);

    const template_count = self.ws.launcher_create_templates.items.len;
    const template_row_h = @max(layout.button_height, 30.0 * self.ui_scale);
    const template_row_gap = layout.row_gap * 0.45;
    const template_row_step = template_row_h + template_row_gap;
    const list_inner_h = @max(0.0, list_rect.height() - layout.inner_inset * 2.0);
    const rows_per_page = blk: {
        if (template_row_step <= 0.0 or list_inner_h <= 0.0) break :blk @as(usize, 1);
        const rows_fit = @floor((list_inner_h + template_row_gap) / template_row_step);
        break :blk @max(@as(usize, 1), @as(usize, @intFromFloat(rows_fit)));
    };
    const total_pages = if (template_count == 0)
        @as(usize, 1)
    else
        (template_count / rows_per_page) + @as(usize, @intFromBool((template_count % rows_per_page) != 0));
    if (self.ws.launcher_create_template_page >= total_pages) {
        self.ws.launcher_create_template_page = total_pages - 1;
    }

    const pager_button_w = @max(62.0 * self.ui_scale, self.measureText("Next") + pad * 1.05);
    const pager_gap = @max(6.0 * self.ui_scale, layout.row_gap * 0.4);
    const next_rect = Rect.fromXYWH(
        refresh_rect.min[0] - pager_gap - pager_button_w,
        refresh_rect.min[1],
        pager_button_w,
        row_h,
    );
    const prev_rect = Rect.fromXYWH(
        next_rect.min[0] - pager_gap - pager_button_w,
        refresh_rect.min[1],
        pager_button_w,
        row_h,
    );
    if (self.drawButtonWidget(
        prev_rect,
        "Prev",
        .{ .variant = .secondary, .disabled = template_count == 0 or self.ws.launcher_create_template_page == 0 },
    )) {
        self.ws.launcher_create_template_page -= 1;
    }
    if (self.drawButtonWidget(
        next_rect,
        "Next",
        .{
            .variant = .secondary,
            .disabled = template_count == 0 or (self.ws.launcher_create_template_page + 1) >= total_pages,
        },
    )) {
        self.ws.launcher_create_template_page += 1;
    }

    const page_line = std.fmt.allocPrint(
        self.allocator,
        "Page {d}/{d}",
        .{ self.ws.launcher_create_template_page + 1, total_pages },
    ) catch null;
    defer if (page_line) |value| self.allocator.free(value);
    if (page_line) |value| {
        const label_x = modal_rect.min[0] + pad + self.measureText("Template") + pad * 0.45;
        const label_w = @max(0.0, prev_rect.min[0] - pager_gap - label_x);
        self.drawTextTrimmed(
            label_x,
            template_header_y,
            label_w,
            value,
            self.theme.colors.text_secondary,
        );
    }

    if (template_count == 0) {
        self.drawTextTrimmed(
            list_rect.min[0] + layout.inner_inset,
            list_rect.min[1] + layout.inner_inset,
            list_rect.width() - layout.inner_inset * 2.0,
            "No templates returned by Spiderweb. Use Refresh Templates.",
            self.theme.colors.text_secondary,
        );
    } else {
        const page_start = self.ws.launcher_create_template_page * rows_per_page;
        const page_end = @min(page_start + rows_per_page, template_count);
        var row_y = list_rect.min[1] + layout.inner_inset;
        const row_max_y = list_rect.max[1] - layout.inner_inset;
        for (self.ws.launcher_create_templates.items[page_start..page_end], page_start..) |template, idx| {
            if (row_y + template_row_h > row_max_y) break;
            if (self.drawButtonWidget(
                Rect.fromXYWH(
                    list_rect.min[0] + layout.inner_inset,
                    row_y,
                    list_rect.width() - layout.inner_inset * 2.0,
                    template_row_h,
                ),
                template.id,
                .{ .variant = if (idx == self.ws.launcher_create_selected_template_index) .primary else .secondary },
            )) {
                self.ws.launcher_create_selected_template_index = idx;
                self.syncLauncherCreateSelectedTemplateToSettings() catch {};
                self.clearLauncherCreateWorkspaceModalError();
            }
            row_y += template_row_step;
        }
    }

    const detail_rect = Rect.fromXYWH(modal_rect.min[0] + pad, detail_y, field_w, detail_h);
    self.drawSurfacePanel(detail_rect);
    self.drawRect(detail_rect, self.theme.colors.border);
    if (self.selectedLauncherCreateWorkspaceTemplate()) |template| {
        const desc = if (template.description.len > 0) template.description else "(no description)";
        const binds_line = std.fmt.allocPrint(
            self.allocator,
            "Selected: {s} | binds: {d}",
            .{ template.id, template.binds.items.len },
        ) catch null;
        defer if (binds_line) |value| self.allocator.free(value);
        if (binds_line) |value| {
            self.drawTextTrimmed(
                detail_rect.min[0] + layout.inner_inset,
                detail_rect.min[1] + layout.inner_inset * 0.7,
                detail_rect.width() - layout.inner_inset * 2.0,
                value,
                self.theme.colors.text_primary,
            );
        }
        self.drawTextTrimmed(
            detail_rect.min[0] + layout.inner_inset,
            detail_rect.min[1] + layout.inner_inset * 0.7 + layout.line_height,
            detail_rect.width() - layout.inner_inset * 2.0,
            desc,
            self.theme.colors.text_secondary,
        );
    } else {
        self.drawTextTrimmed(
            detail_rect.min[0] + layout.inner_inset,
            detail_rect.min[1] + layout.inner_inset * 0.7,
            detail_rect.width() - layout.inner_inset * 2.0,
            "Select a template to continue.",
            self.theme.colors.text_secondary,
        );
    }

    const button_w = (field_w - pad) * 0.5;
    const cancel_rect = Rect.fromXYWH(modal_rect.min[0] + pad, action_y, button_w, row_h);
    if (self.drawButtonWidget(cancel_rect, "Cancel", .{ .variant = .secondary })) {
        self.closeLauncherCreateWorkspaceModal();
        return;
    }

    const trimmed_name = std.mem.trim(u8, self.settings_panel.project_create_name.items, " \t\r\n");
    const create_disabled = self.connection_state != .connected or
        trimmed_name.len == 0 or
        self.ws.launcher_create_templates.items.len == 0;
    if (self.drawButtonWidget(
        Rect.fromXYWH(cancel_rect.max[0] + pad, action_y, button_w, row_h),
        "Create Workspace",
        .{ .variant = .primary, .disabled = create_disabled },
    )) {
        self.createWorkspaceFromLauncherModal() catch |err| {
            const msg = self.formatControlOpError("Workspace create failed", err);
            if (msg) |text| {
                defer self.allocator.free(text);
                self.setLauncherCreateWorkspaceModalError(text);
            } else {
                self.setLauncherCreateWorkspaceModalError("Workspace create failed.");
            }
        };
    }

    if (self.mouse_released and !modal_rect.contains(.{ self.mouse_x, self.mouse_y })) {
        self.closeLauncherCreateWorkspaceModal();
    }
}

// ---------------------------------------------------------------------------
// drawWorkspaceUi
// ---------------------------------------------------------------------------

pub fn drawWorkspaceUi(self: anytype, ui_window: anytype, fb_width: u32, fb_height: u32) void {
    self.ui_commands.clear();
    const ui_draw_context = zui.ui.draw_context;
    ui_draw_context.setGlobalCommandList(&self.ui_commands);
    defer ui_draw_context.clearGlobalCommandList();

    const status_height: f32 = 24.0 * self.ui_scale;
    const menu_height = self.windowMenuBarHeight();
    const dock_height = @max(1.0, @as(f32, @floatFromInt(fb_height)) - status_height - menu_height);
    const UiRect = ui_draw_context.Rect;
    const viewport = UiRect.fromMinSize(
        .{ 0, menu_height },
        .{ @floatFromInt(fb_width), dock_height },
    );

    const shell = self.sharedStyleSheet().shell;
    const surfaces = self.sharedStyleSheet().surfaces;
    const full_rect = Rect.fromXYWH(0, 0, @floatFromInt(fb_width), @floatFromInt(fb_height));
    const viewport_rect = Rect{ .min = viewport.min, .max = viewport.max };
    self.drawPaintRect(
        full_rect,
        surfaces.background orelse Paint{ .solid = self.theme.colors.background },
    );
    self.drawPaintRect(
        viewport_rect,
        shell.dock_fill orelse surfaces.surface orelse Paint{ .solid = self.theme.colors.surface },
    );
    if (shell.dock_border) |dock_border| self.drawRect(viewport_rect, dock_border);

    ui_window.ui_state.last_dock_content_rect = viewport;

    const mouse_in_viewport = self.mouse_x >= viewport.min[0] and
        self.mouse_x <= viewport.max[0] and
        self.mouse_y >= viewport.min[1] and
        self.mouse_y <= viewport.max[1];
    const saved_mouse_clicked = self.mouse_clicked;
    const saved_mouse_released = self.mouse_released;
    const saved_mouse_down = self.mouse_down;
    if (!mouse_in_viewport) {
        self.mouse_clicked = false;
        self.mouse_released = false;
        self.mouse_down = false;
    }

    self.ui_commands.pushClip(.{ .min = viewport.min, .max = viewport.max });

    const dock_graph = zui.ui.layout.dock_graph;
    var layout: dock_graph.LayoutResult = .{};
    if (!self.collectDockLayoutSafe(ui_window.manager, viewport, &layout)) {
        if (self.shouldLogDebug(120) or self.shouldLogStartup()) {
            std.log.warn("drawDockUi: unable to recover dock layout; no panels available", .{});
        }
        self.drawText(
            viewport.min[0] + 12.0,
            viewport.min[1] + 12.0,
            "Unable to recover dock layout; no panels available.",
            self.theme.colors.text_secondary,
        );
        self.ui_commands.popClip();
        self.mouse_clicked = saved_mouse_clicked;
        self.mouse_released = saved_mouse_released;
        self.mouse_down = saved_mouse_down;
        _ = self.drawWindowMenuBar(ui_window, fb_width);
        self.drawStatusOverlay(fb_width, fb_height);
        if (self.ws.workspace_wizard_open) {
            self.mouse_down = saved_mouse_down;
            self.mouse_clicked = saved_mouse_clicked;
            self.mouse_released = saved_mouse_released;
            self.drawWorkspaceWizardModal(fb_width, fb_height);
        }
        return;
    }
    // Draw each dock group
    for (layout.slice()) |group| {
        if (!self.isLayoutGroupUsable(ui_window.manager, group.node_id)) continue;
        self.drawDockGroup(ui_window.manager, group.node_id, group.rect);
    }

    const splitters = ui_window.manager.workspace.dock_layout.computeSplitters(viewport);
    self.drawDockSplitters(&ui_window.queue, ui_window, &splitters);

    const DockTabHitList = @TypeOf(self).DockTabHitList;
    const DockDropTargetList = @TypeOf(self).DockDropTargetList;
    var drag_tab_hits = DockTabHitList{};
    var drag_drop_targets = DockDropTargetList{};
    self.collectDockInteractionGeometry(ui_window.manager, viewport, &drag_tab_hits, &drag_drop_targets);
    self.drawDockDragOverlay(&ui_window.queue, ui_window.manager, ui_window, &drag_drop_targets, viewport);
    self.ui_commands.popClip();
    self.mouse_clicked = saved_mouse_clicked;
    self.mouse_released = saved_mouse_released;
    self.mouse_down = saved_mouse_down;

    _ = self.drawWindowMenuBar(ui_window, fb_width);
    self.drawStatusOverlay(fb_width, fb_height);
    if (self.ws.workspace_wizard_open) {
        self.mouse_down = saved_mouse_down;
        self.mouse_clicked = saved_mouse_clicked;
        self.mouse_released = saved_mouse_released;
        self.drawWorkspaceWizardModal(fb_width, fb_height);
    }
}

// ---------------------------------------------------------------------------
// drawWorkspacePanel
// ---------------------------------------------------------------------------

pub fn drawWorkspacePanel(self: anytype, manager: anytype, rect: anytype) void {
    _ = manager;
    var view = buildWorkspacePanelView(self);
    defer view.deinit(self.allocator);
    const host = WorkspacePanel.Host{
        .ctx = @ptrCast(self),
        .draw_form_section_title = launcherSettingsDrawFormSectionTitle,
        .draw_form_field_label = launcherSettingsDrawFormFieldLabel,
        .draw_text_input = launcherSettingsDrawTextInput,
        .draw_button = launcherSettingsDrawButton,
        .draw_label = launcherSettingsDrawLabel,
        .draw_text_trimmed = launcherSettingsDrawTextTrimmed,
        .draw_status_row = projectDrawStatusRow,
        .draw_vertical_scrollbar = projectDrawVerticalScrollbar,
    };
    var panel_state = WorkspacePanel.State{
        .focused_field = projectFocusFieldToExternal(self.settings_panel.focused_field),
        .scroll_y = self.settings_panel.workspaces_scroll_y,
    };
    const action = WorkspacePanel.draw(
        host,
        Rect{ .min = rect.min, .max = rect.max },
        self.panelLayoutMetrics(),
        self.ui_scale,
        .{
            .text_primary = self.theme.colors.text_primary,
            .text_secondary = self.theme.colors.text_secondary,
            .warning_text = zcolors.rgba(236, 174, 36, 255),
            .error_text = zcolors.rgba(220, 80, 80, 255),
        },
        self.workspacePanelModel(),
        view.view,
        .{
            .workspace_token = self.settings_panel.project_token.items,
            .create_name = self.settings_panel.project_create_name.items,
            .create_vision = self.settings_panel.project_create_vision.items,
            .template_id = self.settings_panel.workspace_template_id.items,
            .operator_token = self.settings_panel.project_operator_token.items,
            .mount_path = self.settings_panel.project_mount_path.items,
            .mount_node_id = self.settings_panel.project_mount_node_id.items,
            .mount_export_name = self.settings_panel.project_mount_export_name.items,
            .bind_path = self.settings_panel.workspace_bind_path.items,
            .bind_target_path = self.settings_panel.workspace_bind_target_path.items,
        },
        .{
            .mouse_x = self.mouse_x,
            .mouse_y = self.mouse_y,
            .mouse_released = self.mouse_released,
        },
        &panel_state,
    );
    const mapped_focus = projectFocusFieldFromExternal(panel_state.focused_field);
    if (mapped_focus != .none or isWorkspacePanelFocusField(self.settings_panel.focused_field)) {
        self.settings_panel.focused_field = mapped_focus;
    }
    self.settings_panel.workspaces_scroll_y = panel_state.scroll_y;
    if (action) |value| self.performWorkspacePanelAction(value);
}

// ---------------------------------------------------------------------------
// Focus-field translation helpers (workspace panel)
// These are standalone (no self) so they can be called from host callbacks.
// ---------------------------------------------------------------------------

pub fn projectFocusFieldToExternal(field: anytype) WorkspacePanel.FocusField {
    return switch (field) {
        .project_token => .workspace_token,
        .project_create_name => .create_name,
        .project_create_vision => .create_vision,
        .workspace_template_id => .template_id,
        .project_operator_token => .operator_token,
        .project_mount_path => .mount_path,
        .project_mount_node_id => .mount_node_id,
        .project_mount_export_name => .mount_export_name,
        .workspace_bind_path => .bind_path,
        .workspace_bind_target_path => .bind_target_path,
        else => .none,
    };
}

pub fn projectFocusFieldFromExternal(field: WorkspacePanel.FocusField) u8 {
    // Placeholder — real mapping lives in root.zig.
    _ = field;
    return 0;
}

pub fn isWorkspacePanelFocusField(field: anytype) bool {
    return switch (field) {
        .project_token,
        .project_create_name,
        .project_create_vision,
        .workspace_template_id,
        .project_operator_token,
        .project_mount_path,
        .project_mount_node_id,
        .project_mount_export_name,
        .workspace_bind_path,
        .workspace_bind_target_path,
        => true,
        else => false,
    };
}

// ---------------------------------------------------------------------------
// Host draw callbacks used by WorkspacePanel
// ---------------------------------------------------------------------------

fn launcherSettingsDrawFormSectionTitle(
    ctx: *anyopaque,
    x: f32,
    y: *f32,
    max_w: f32,
    layout: PanelLayoutMetrics,
    text: []const u8,
) void {
    const App = @import("../root.zig").App;
    const self: *App = @ptrCast(@alignCast(ctx));
    self.drawFormSectionTitle(x, y, max_w, layout, text);
}

fn launcherSettingsDrawFormFieldLabel(
    ctx: *anyopaque,
    x: f32,
    y: *f32,
    max_w: f32,
    layout: PanelLayoutMetrics,
    text: []const u8,
) void {
    const App = @import("../root.zig").App;
    const self: *App = @ptrCast(@alignCast(ctx));
    self.drawFormFieldLabel(x, y, max_w, layout, text);
}

fn launcherSettingsDrawTextInput(
    ctx: *anyopaque,
    rect: Rect,
    text: []const u8,
    focused: bool,
    opts: widgets.text_input.Options,
) bool {
    const App = @import("../root.zig").App;
    const self: *App = @ptrCast(@alignCast(ctx));
    return self.drawTextInputWidget(rect, text, focused, opts);
}

fn launcherSettingsDrawButton(
    ctx: *anyopaque,
    rect: Rect,
    label: []const u8,
    opts: widgets.button.Options,
) bool {
    const App = @import("../root.zig").App;
    const self: *App = @ptrCast(@alignCast(ctx));
    return self.drawButtonWidget(rect, label, opts);
}

fn launcherSettingsDrawLabel(
    ctx: *anyopaque,
    x: f32,
    y: f32,
    text: []const u8,
    color: [4]f32,
) void {
    const App = @import("../root.zig").App;
    const self: *App = @ptrCast(@alignCast(ctx));
    self.drawLabel(x, y, text, color);
}

fn launcherSettingsDrawTextTrimmed(
    ctx: *anyopaque,
    x: f32,
    y: f32,
    max_w: f32,
    text: []const u8,
    color: [4]f32,
) void {
    const App = @import("../root.zig").App;
    const self: *App = @ptrCast(@alignCast(ctx));
    self.drawTextTrimmed(x, y, max_w, text, color);
}

fn projectDrawStatusRow(ctx: *anyopaque, rect: Rect) void {
    const App = @import("../root.zig").App;
    const self: *App = @ptrCast(@alignCast(ctx));
    self.drawStatusRow(rect);
}

fn projectDrawVerticalScrollbar(
    ctx: *anyopaque,
    viewport_rect: Rect,
    content_height: f32,
    scroll_y: *f32,
) void {
    const App = @import("../root.zig").App;
    const self: *App = @ptrCast(@alignCast(ctx));
    self.drawVerticalScrollbar(.projects, viewport_rect, content_height, scroll_y);
}
