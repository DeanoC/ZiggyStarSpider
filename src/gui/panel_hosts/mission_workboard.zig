//! Mission Workboard panel host (includes Mission List and Detail sub-panels).
//! Pure draw logic; receives `self: anytype` (*App duck-typed) so this file
//! never imports root.zig and therefore has no circular dependency.

const std = @import("std");
const zui = @import("ziggy-ui");
const zcolors = zui.theme.colors;
const Rect = zui.core.Rect;
const PanelLayoutMetrics = zui.ui.layout.form_layout.Metrics;

const mission_types = @import("../state/mission_types.zig");
const MissionRecordView = mission_types.MissionRecordView;
const MissionArtifactView = mission_types.MissionArtifactView;

const helpers = @import("../state/mission_helpers.zig");
const missionDisplayTitle = helpers.missionDisplayTitle;
const normalizedMissionStateLabel = helpers.normalizedMissionStateLabel;
const latestMissionArtifactByKind = helpers.latestMissionArtifactByKind;
const formatRelativeTimeLabel = helpers.formatRelativeTimeLabel;

const MISSION_PREVIEW_ARTIFACT_COUNT: usize = 4;
const MISSION_PREVIEW_EVENT_COUNT: usize = 4;

// ── Public entry point ────────────────────────────────────────────────────────

pub fn draw(self: anytype, manager: anytype, panel: anytype, rect: anytype) void {
    _ = panel;
    self.requestMissionDashboardRefresh(false);

    const panel_rect = Rect{ .min = rect.min, .max = rect.max };
    self.drawSurfacePanel(panel_rect);

    const layout = self.panelLayoutMetrics();
    const pad = layout.inset;
    const inner_w = @max(1.0, panel_rect.width() - pad * 2.0);
    const line_h = self.textLineHeight();
    const button_h = layout.button_height;

    const refresh_label = if (self.client_context.pending_workboard_request_id != null) "Refreshing..." else "Refresh";
    const refresh_w = @max(96.0 * self.ui_scale, self.measureTextFast(refresh_label) + pad * 1.4);
    const refresh_rect = Rect.fromXYWH(
        panel_rect.max[0] - pad - refresh_w,
        panel_rect.min[1] + pad,
        refresh_w,
        button_h,
    );
    if (self.drawButtonWidget(refresh_rect, refresh_label, .{
        .variant = .secondary,
        .disabled = self.connection_state != .connected or self.client_context.pending_workboard_request_id != null,
    })) {
        self.requestMissionDashboardRefresh(true);
    }

    var approvals_label_buf: [64]u8 = undefined;
    const approvals_label = std.fmt.bufPrint(
        &approvals_label_buf,
        "Approvals {d}",
        .{self.client_context.approvals.items.len},
    ) catch "Approvals";
    const approvals_w = @max(112.0 * self.ui_scale, self.measureTextFast(approvals_label) + pad * 1.6);
    const approvals_rect = Rect.fromXYWH(
        refresh_rect.min[0] - pad * 0.6 - approvals_w,
        refresh_rect.min[1],
        approvals_w,
        button_h,
    );
    if (self.drawButtonWidget(approvals_rect, approvals_label, .{
        .variant = .ghost,
        .disabled = self.client_context.approvals.items.len == 0 and self.client_context.approvals_resolved.items.len == 0,
    })) {
        manager.ensurePanel(.ApprovalsInbox);
    }

    self.drawTextTrimmed(
        panel_rect.min[0] + pad,
        panel_rect.min[1] + pad,
        @max(1.0, approvals_rect.min[0] - panel_rect.min[0] - pad * 1.6),
        "Mission Workboard",
        self.theme.colors.text_primary,
    );

    var status_buf: [160]u8 = undefined;
    self.drawTextTrimmed(
        panel_rect.min[0] + pad,
        panel_rect.min[1] + pad + line_h + layout.row_gap * 0.35,
        inner_w,
        self.missionDashboardStatusText(&status_buf),
        self.theme.colors.text_secondary,
    );

    const cards_top = panel_rect.min[1] + pad + line_h * 2.0 + layout.row_gap;
    const card_gap = @max(layout.inner_inset, 10.0 * self.ui_scale);
    const card_h = @max(84.0 * self.ui_scale, button_h * 2.4);
    const card_w = @max(80.0, (inner_w - card_gap * 2.0) / 3.0);
    const missions_rect = Rect.fromXYWH(panel_rect.min[0] + pad, cards_top, card_w, card_h);
    const approvals_card_rect = Rect.fromXYWH(missions_rect.max[0] + card_gap, cards_top, card_w, card_h);
    const recovery_rect = Rect.fromXYWH(approvals_card_rect.max[0] + card_gap, cards_top, card_w, card_h);

    var running_count: usize = 0;
    var waiting_count: usize = 0;
    var failed_count: usize = 0;
    var recovering_count: usize = 0;
    for (self.mission.records.items) |mission| {
        if (std.ascii.eqlIgnoreCase(mission.state, "running")) running_count += 1;
        if (std.ascii.eqlIgnoreCase(mission.state, "waiting_for_approval") or std.ascii.eqlIgnoreCase(mission.state, "blocked")) waiting_count += 1;
        if (std.ascii.eqlIgnoreCase(mission.state, "failed") or std.ascii.eqlIgnoreCase(mission.state, "cancelled")) failed_count += 1;
        if (mission.recovery_count > 0 or std.ascii.eqlIgnoreCase(mission.state, "recovering")) recovering_count += 1;
    }

    var missions_summary_buf: [96]u8 = undefined;
    const missions_summary = std.fmt.bufPrint(
        &missions_summary_buf,
        "{d} running, {d} waiting, {d} failed",
        .{ running_count, waiting_count, failed_count },
    ) catch "Mission activity";
    self.drawMissionSummaryCard(missions_rect, self.theme.colors.primary, "Missions", if (self.mission.records.items.len > 0) "Live queue" else "No missions", missions_summary);

    var approvals_summary_buf: [96]u8 = undefined;
    const approvals_summary = std.fmt.bufPrint(
        &approvals_summary_buf,
        "{d} pending, {d} resolved in-session",
        .{ self.client_context.approvals.items.len, self.client_context.approvals_resolved.items.len },
    ) catch "Approval queue";
    self.drawMissionSummaryCard(
        approvals_card_rect,
        if (self.client_context.approvals.items.len > 0) zcolors.rgba(236, 174, 36, 255) else self.theme.colors.border,
        "Approvals",
        if (self.client_context.approvals.items.len > 0) "Operator review" else "Queue clear",
        approvals_summary,
    );

    var recovery_title_buf: [64]u8 = undefined;
    const recovery_title = self.workspaceRecoveryHeadline(&recovery_title_buf);
    var recovery_summary_buf: [96]u8 = undefined;
    const recovery_summary = std.fmt.bufPrint(
        &recovery_summary_buf,
        "{d} missions with recovery history",
        .{recovering_count},
    ) catch "Mission recovery";
    self.drawMissionSummaryCard(recovery_rect, self.workspaceRecoveryColor(), "Recovery", recovery_title, recovery_summary);

    const content_top = cards_top + card_h + layout.row_gap;
    const content_h = @max(1.0, panel_rect.max[1] - content_top - pad);
    const list_w = @max(240.0 * self.ui_scale, inner_w * 0.36);
    const list_rect = Rect.fromXYWH(panel_rect.min[0] + pad, content_top, list_w, content_h);
    const detail_rect = Rect.fromXYWH(list_rect.max[0] + card_gap, content_top, @max(1.0, panel_rect.max[0] - list_rect.max[0] - pad - card_gap), content_h);
    drawListPanel(self, list_rect);
    drawDetailPanel(self, detail_rect);
}

// ── Private helpers ───────────────────────────────────────────────────────────

fn missionStateColor(app: anytype, state: []const u8) [4]f32 {
    if (std.ascii.eqlIgnoreCase(state, "running")) return app.theme.colors.primary;
    if (std.ascii.eqlIgnoreCase(state, "completed")) return app.theme.colors.success;
    if (std.ascii.eqlIgnoreCase(state, "failed") or std.ascii.eqlIgnoreCase(state, "cancelled")) return app.theme.colors.danger;
    if (std.ascii.eqlIgnoreCase(state, "waiting_for_approval") or
        std.ascii.eqlIgnoreCase(state, "blocked") or
        std.ascii.eqlIgnoreCase(state, "planning"))
    {
        return zcolors.rgba(236, 174, 36, 255);
    }
    if (std.ascii.eqlIgnoreCase(state, "recovering")) return zcolors.rgba(120, 180, 255, 255);
    return app.theme.colors.border;
}

fn drawStateBadge(self: anytype, rect: Rect, label: []const u8, color: [4]f32) void {
    self.drawFilledRect(rect, zcolors.withAlpha(color, 0.18));
    self.drawRect(rect, color);
    self.drawCenteredText(rect, label, color);
}

fn drawDetailLine(self: anytype, rect: Rect, pad: f32, y: f32, label: []const u8, value: []const u8) f32 {
    const line_h = self.textLineHeight();
    const label_w = @max(110.0 * self.ui_scale, rect.width() * 0.18);
    self.drawTextTrimmed(rect.min[0] + pad, y, label_w, label, self.theme.colors.text_secondary);
    self.drawTextTrimmed(rect.min[0] + pad + label_w + pad * 0.6, y, rect.width() - label_w - pad * 3.0, value, self.theme.colors.text_primary);
    return y + line_h;
}

fn drawOptionalDetailLine(self: anytype, rect: Rect, pad: f32, y: f32, label: []const u8, value: ?[]const u8) f32 {
    if (value) |text| return drawDetailLine(self, rect, pad, y, label, text);
    return y;
}

fn drawArtifactDetailLine(self: anytype, rect: Rect, pad: f32, y: f32, label: []const u8, artifact: ?*const MissionArtifactView) f32 {
    const value = if (artifact) |entry|
        entry.path orelse entry.summary orelse entry.kind
    else
        null;
    return drawOptionalDetailLine(self, rect, pad, y, label, value);
}

fn drawListPanel(self: anytype, rect: Rect) void {
    self.drawSurfacePanel(rect);
    const pad = @max(self.theme.spacing.xs, 8.0 * self.ui_scale);
    const line_h = self.textLineHeight();
    const header_y = rect.min[1] + pad;
    self.drawTextTrimmed(rect.min[0] + pad, header_y, rect.width() - pad * 2.0, "Mission Queue", self.theme.colors.text_primary);

    if (self.mission.records.items.len == 0) {
        self.drawTextTrimmed(
            rect.min[0] + pad,
            header_y + line_h + pad,
            rect.width() - pad * 2.0,
            if (self.connection_state == .connected) "No missions recorded yet." else "Connect to load mission records.",
            self.theme.colors.text_secondary,
        );
        return;
    }

    const row_gap = @max(6.0 * self.ui_scale, pad * 0.6);
    const row_h = @max(line_h * 3.0, 76.0 * self.ui_scale);
    var y = header_y + line_h + pad * 0.8;
    var drawn: usize = 0;
    const available_rows = @as(usize, @intFromFloat(@max(1.0, (rect.max[1] - y - pad) / (row_h + row_gap))));
    const now_ms = std.time.milliTimestamp();

    for (self.mission.records.items) |mission| {
        if (drawn >= available_rows) break;
        const row_rect = Rect.fromXYWH(rect.min[0] + pad, y, rect.width() - pad * 2.0, row_h);
        const selected = self.mission.selected_id != null and std.mem.eql(u8, self.mission.selected_id.?, mission.mission_id);
        const hovered = row_rect.contains(.{ self.mouse_x, self.mouse_y });
        const fill = if (selected)
            zcolors.withAlpha(self.theme.colors.primary, 0.14)
        else if (hovered)
            zcolors.withAlpha(self.theme.colors.primary, 0.08)
        else
            zcolors.withAlpha(self.theme.colors.surface, 0.6);
        self.drawFilledRect(row_rect, fill);
        self.drawRect(row_rect, if (selected) self.theme.colors.primary else self.theme.colors.border);

        const content_x = row_rect.min[0] + pad;
        const content_w = row_rect.width() - pad * 2.0;
        self.drawTextTrimmed(content_x, row_rect.min[1] + pad * 0.55, @max(1.0, content_w - 88.0 * self.ui_scale), missionDisplayTitle(&mission), self.theme.colors.text_primary);

        var state_buf: [40]u8 = undefined;
        const state_rect = Rect.fromXYWH(row_rect.max[0] - pad - 80.0 * self.ui_scale, row_rect.min[1] + pad * 0.45, 80.0 * self.ui_scale, line_h + pad * 0.5);
        const state_label = normalizedMissionStateLabel(mission.state, &state_buf);
        drawStateBadge(self, state_rect, state_label, missionStateColor(self, mission.state));

        var secondary_buf: [160]u8 = undefined;
        const secondary = std.fmt.bufPrint(
            &secondary_buf,
            "{s}  {s}",
            .{ mission.stage, mission.project_id orelse "no-workspace" },
        ) catch mission.stage;
        self.drawTextTrimmed(content_x, row_rect.min[1] + pad * 0.55 + line_h + pad * 0.25, content_w, secondary, self.theme.colors.text_secondary);

        var meta_buf: [160]u8 = undefined;
        const relative = if (mission.updated_at_ms > 0) blk: {
            var time_buf: [40]u8 = undefined;
            break :blk formatRelativeTimeLabel(now_ms, mission.updated_at_ms, &time_buf);
        } else "unknown";
        const meta = std.fmt.bufPrint(
            &meta_buf,
            "{s}  {s}",
            .{ mission.agent_id orelse "agent:unknown", relative },
        ) catch relative;
        self.drawTextTrimmed(content_x, row_rect.min[1] + pad * 0.55 + line_h * 2.0 + pad * 0.3, content_w, meta, self.theme.colors.text_secondary);

        if (self.mouse_released and row_rect.contains(.{ self.mouse_x, self.mouse_y })) {
            self.setSelectedMissionId(mission.mission_id);
        }

        y += row_h + row_gap;
        drawn += 1;
    }

    if (self.mission.records.items.len > drawn) {
        var more_buf: [64]u8 = undefined;
        const more = std.fmt.bufPrint(&more_buf, "...and {d} more", .{self.mission.records.items.len - drawn}) catch "...";
        self.drawTextTrimmed(rect.min[0] + pad, rect.max[1] - pad - line_h, rect.width() - pad * 2.0, more, self.theme.colors.text_secondary);
    }
}

fn drawDetailPanel(self: anytype, rect: Rect) void {
    self.drawSurfacePanel(rect);
    const mission = self.selectedMission() orelse {
        self.drawTextTrimmed(rect.min[0] + self.theme.spacing.sm, rect.min[1] + self.theme.spacing.sm, rect.width() - self.theme.spacing.sm * 2.0, "Select a mission to inspect it.", self.theme.colors.text_secondary);
        return;
    };

    const pad = @max(self.theme.spacing.sm, 10.0 * self.ui_scale);
    const line_h = self.textLineHeight();
    const inner_w = rect.width() - pad * 2.0;
    var y = rect.min[1] + pad;

    self.drawTextTrimmed(rect.min[0] + pad, y, inner_w - 96.0 * self.ui_scale, missionDisplayTitle(mission), self.theme.colors.text_primary);
    var state_buf: [40]u8 = undefined;
    const badge_rect = Rect.fromXYWH(rect.max[0] - pad - 88.0 * self.ui_scale, y - pad * 0.2, 88.0 * self.ui_scale, line_h + pad * 0.6);
    drawStateBadge(self, badge_rect, normalizedMissionStateLabel(mission.state, &state_buf), missionStateColor(self, mission.state));
    y += line_h + pad * 0.6;

    if (mission.summary) |summary| {
        y += self.drawTextWrapped(rect.min[0] + pad, y, inner_w, summary, self.theme.colors.text_secondary) + pad * 0.5;
    }

    y = drawDetailLine(self, rect, pad, y, "Use Case", mission.use_case);
    y = drawDetailLine(self, rect, pad, y, "Stage", mission.stage);
    y = drawDetailLine(self, rect, pad, y, "Agent", mission.agent_id orelse "unknown");
    if (mission.persona_pack) |persona_pack| {
        y = drawDetailLine(self, rect, pad, y, "Persona Pack", persona_pack);
    }
    if (mission.project_id) |project_id| {
        y = drawDetailLine(self, rect, pad, y, "Workspace", project_id);
    }
    if (mission.worktree_name) |worktree_name| {
        y = drawDetailLine(self, rect, pad, y, "Worktree", worktree_name);
    }
    if (mission.workspace_root) |workspace_root| {
        y = drawDetailLine(self, rect, pad, y, "Workspace", workspace_root);
    }
    if (mission.contract_context_path != null or mission.contract_state_path != null or mission.contract_artifact_root != null) {
        y += pad * 0.35;
        self.drawTextTrimmed(rect.min[0] + pad, y, inner_w, "Contract", self.theme.colors.text_primary);
        y += line_h;
        y = drawOptionalDetailLine(self, rect, pad, y, "Context", mission.contract_context_path);
        y = drawOptionalDetailLine(self, rect, pad, y, "State File", mission.contract_state_path);
        y = drawOptionalDetailLine(self, rect, pad, y, "Artifacts Root", mission.contract_artifact_root);
    }

    if (std.mem.eql(u8, mission.use_case, "pr_review")) {
        const provider_sync = latestMissionArtifactByKind(mission, "provider_sync");
        const checkout_sync = latestMissionArtifactByKind(mission, "checkout_sync");
        const repo_status = latestMissionArtifactByKind(mission, "repo_status");
        const diff_range = latestMissionArtifactByKind(mission, "diff_range");
        const validation = latestMissionArtifactByKind(mission, "validation");
        const recommendation = latestMissionArtifactByKind(mission, "recommendation");
        const publish_review = latestMissionArtifactByKind(mission, "publish_review");

        if (provider_sync != null or checkout_sync != null or repo_status != null or diff_range != null or validation != null or recommendation != null or publish_review != null) {
            y += pad * 0.35;
            self.drawTextTrimmed(rect.min[0] + pad, y, inner_w, "PR Review", self.theme.colors.text_primary);
            y += line_h;
            y = drawArtifactDetailLine(self, rect, pad, y, "Provider Sync", provider_sync);
            y = drawArtifactDetailLine(self, rect, pad, y, "Checkout", checkout_sync);
            y = drawArtifactDetailLine(self, rect, pad, y, "Repo Status", repo_status);
            y = drawArtifactDetailLine(self, rect, pad, y, "Diff Range", diff_range);
            y = drawArtifactDetailLine(self, rect, pad, y, "Validation", validation);
            y = drawArtifactDetailLine(self, rect, pad, y, "Recommendation", recommendation);
            y = drawArtifactDetailLine(self, rect, pad, y, "Published Review", publish_review);
        }
    }

    var recovery_buf: [96]u8 = undefined;
    const recovery_text = if (mission.recovery_count > 0)
        (std.fmt.bufPrint(&recovery_buf, "{d} recoveries", .{mission.recovery_count}) catch "recovery history")
    else
        "none";
    y = drawDetailLine(self, rect, pad, y, "Recovery", recovery_text);
    if (mission.recovery_reason) |reason| {
        y = drawDetailLine(self, rect, pad, y, "Recovery Reason", reason);
    }
    if (mission.blocked_reason) |reason| {
        y = drawDetailLine(self, rect, pad, y, "Blocked", reason);
    }

    y += pad * 0.4;
    self.drawTextTrimmed(rect.min[0] + pad, y, inner_w, "Memory ownership", self.theme.colors.text_primary);
    y += line_h;
    y += self.drawTextWrapped(
        rect.min[0] + pad,
        y,
        inner_w,
        "Kernel policy memories stay write-protected, identity memories remain agent-owned, and working memory stays mutable for strategy updates.",
        self.theme.colors.text_secondary,
    ) + pad * 0.6;

    if (mission.pending_approval) |approval| {
        self.drawTextTrimmed(rect.min[0] + pad, y, inner_w, "Pending approval", self.theme.colors.text_primary);
        y += line_h;
        y += self.drawTextWrapped(rect.min[0] + pad, y, inner_w, approval.message, self.theme.colors.text_secondary) + pad * 0.2;
        var approval_buf: [128]u8 = undefined;
        const approval_meta = std.fmt.bufPrint(
            &approval_buf,
            "{s} requested by {s}/{s}",
            .{ approval.action_kind, approval.requested_by.actor_type, approval.requested_by.actor_id },
        ) catch approval.action_kind;
        y += self.drawTextWrapped(rect.min[0] + pad, y, inner_w, approval_meta, self.theme.colors.text_secondary) + pad * 0.6;
    }

    if (mission.artifacts.items.len > 0 and y < rect.max[1] - line_h * 2.0) {
        self.drawTextTrimmed(rect.min[0] + pad, y, inner_w, "Artifacts", self.theme.colors.text_primary);
        y += line_h;
        const start_index = if (mission.artifacts.items.len > MISSION_PREVIEW_ARTIFACT_COUNT) mission.artifacts.items.len - MISSION_PREVIEW_ARTIFACT_COUNT else 0;
        for (mission.artifacts.items[start_index..]) |artifact| {
            if (y >= rect.max[1] - line_h * 2.0) break;
            var artifact_buf: [256]u8 = undefined;
            const artifact_line = std.fmt.bufPrint(
                &artifact_buf,
                "{s}  {s}",
                .{ artifact.kind, artifact.summary orelse artifact.path orelse "(no summary)" },
            ) catch artifact.kind;
            self.drawTextTrimmed(rect.min[0] + pad, y, inner_w, artifact_line, self.theme.colors.text_secondary);
            y += line_h;
        }
        y += pad * 0.4;
    }

    if (mission.events.items.len > 0 and y < rect.max[1] - line_h * 2.0) {
        self.drawTextTrimmed(rect.min[0] + pad, y, inner_w, "Recent events", self.theme.colors.text_primary);
        y += line_h;
        const start_index = if (mission.events.items.len > MISSION_PREVIEW_EVENT_COUNT) mission.events.items.len - MISSION_PREVIEW_EVENT_COUNT else 0;
        const now_ms = std.time.milliTimestamp();
        for (mission.events.items[start_index..]) |event| {
            if (y >= rect.max[1] - line_h * 2.0) break;
            var time_buf: [40]u8 = undefined;
            var event_buf: [256]u8 = undefined;
            const event_line = std.fmt.bufPrint(
                &event_buf,
                "{s}  {s}",
                .{ formatRelativeTimeLabel(now_ms, event.created_at_ms, &time_buf), event.event_type },
            ) catch event.event_type;
            self.drawTextTrimmed(rect.min[0] + pad, y, inner_w, event_line, self.theme.colors.text_secondary);
            y += line_h;
        }
    }
}
