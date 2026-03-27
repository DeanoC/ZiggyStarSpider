//! Pure helper functions for mission view-model types.
//! Depends only on std and mission_types — no zui, no circular imports.

const std = @import("std");
const mission_types = @import("mission_types.zig");

pub const MissionRecordView = mission_types.MissionRecordView;
pub const MissionArtifactView = mission_types.MissionArtifactView;

pub fn missionDisplayTitle(mission: *const MissionRecordView) []const u8 {
    return mission.title orelse mission.summary orelse mission.mission_id;
}

pub fn normalizedMissionStateLabel(state: []const u8, buf: []u8) []const u8 {
    if (std.ascii.eqlIgnoreCase(state, "waiting_for_approval")) return "waiting";
    if (std.ascii.eqlIgnoreCase(state, "completed")) return "done";
    if (std.ascii.eqlIgnoreCase(state, "cancelled")) return "cancelled";
    if (std.ascii.eqlIgnoreCase(state, "recovering")) return "recovering";
    return std.fmt.bufPrint(buf, "{s}", .{state}) catch state;
}

pub fn latestMissionArtifactByKind(mission: *const MissionRecordView, kind: []const u8) ?*const MissionArtifactView {
    var index = mission.artifacts.items.len;
    while (index > 0) {
        index -= 1;
        const artifact = &mission.artifacts.items[index];
        if (std.mem.eql(u8, artifact.kind, kind)) return artifact;
    }
    return null;
}

pub fn formatRelativeTimeLabel(now_ms: i64, ts_ms: i64, buf: []u8) []const u8 {
    if (ts_ms <= 0) return "unknown";
    const delta_ms_abs: i64 = if (now_ms >= ts_ms) now_ms - ts_ms else ts_ms - now_ms;
    const minutes: i64 = @divTrunc(delta_ms_abs, 60_000);
    if (minutes < 1) return "just now";
    if (minutes < 60) return std.fmt.bufPrint(buf, "{d}m ago", .{minutes}) catch "recent";
    const hours: i64 = @divTrunc(minutes, 60);
    if (hours < 24) return std.fmt.bufPrint(buf, "{d}h ago", .{hours}) catch "today";
    const days: i64 = @divTrunc(hours, 24);
    if (days < 30) return std.fmt.bufPrint(buf, "{d}d ago", .{days}) catch "this month";
    const months: i64 = @divTrunc(days, 30);
    return std.fmt.bufPrint(buf, "{d}mo ago", .{months}) catch "older";
}

test "missionDisplayTitle prefers title then summary then id" {
    const actor = mission_types.MissionActorView{ .actor_type = @constCast("human"), .actor_id = @constCast("test") };
    var rec = MissionRecordView{
        .mission_id = @constCast("id-1"),
        .use_case = @constCast("test"),
        .title = null,
        .summary = null,
        .state = @constCast("running"),
        .stage = @constCast("active"),
        .created_by = actor,
    };
    try std.testing.expectEqualStrings("id-1", missionDisplayTitle(&rec));
    rec.summary = @constCast("a summary");
    try std.testing.expectEqualStrings("a summary", missionDisplayTitle(&rec));
    rec.title = @constCast("a title");
    try std.testing.expectEqualStrings("a title", missionDisplayTitle(&rec));
}

test "normalizedMissionStateLabel maps known states" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("waiting", normalizedMissionStateLabel("waiting_for_approval", &buf));
    try std.testing.expectEqualStrings("done", normalizedMissionStateLabel("completed", &buf));
    try std.testing.expectEqualStrings("cancelled", normalizedMissionStateLabel("cancelled", &buf));
    try std.testing.expectEqualStrings("recovering", normalizedMissionStateLabel("recovering", &buf));
    try std.testing.expectEqualStrings("running", normalizedMissionStateLabel("running", &buf));
}

test "formatRelativeTimeLabel returns known buckets" {
    // Use a large enough base so subtracting hours/days stays positive
    const now: i64 = 100_000_000_000;
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("unknown", formatRelativeTimeLabel(now, 0, &buf));
    try std.testing.expectEqualStrings("just now", formatRelativeTimeLabel(now, now - 30_000, &buf));
    const label_5m = formatRelativeTimeLabel(now, now - 5 * 60_000, &buf);
    try std.testing.expectEqualStrings("5m ago", label_5m);
    const label_3h = formatRelativeTimeLabel(now, now - 3 * 3_600_000, &buf);
    try std.testing.expectEqualStrings("3h ago", label_3h);
}
