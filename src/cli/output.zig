// CLI output formatting helpers: table rendering, color-coded status indicators.
// Import as:
//   const output = @import("output.zig");

const std = @import("std");

// ── ANSI colors ───────────────────────────────────────────────────────────────

const ansi_reset = "\x1b[0m";
const ansi_bold = "\x1b[1m";
const ansi_dim = "\x1b[2m";
const ansi_green = "\x1b[32m";
const ansi_yellow = "\x1b[33m";
const ansi_red = "\x1b[31m";
const ansi_cyan = "\x1b[36m";

pub const StatusKind = enum { ok, warn, fail, info };

/// Print a status line: "[OK] msg", "[WARN] msg", "[FAIL] msg", "[INFO] msg"
/// Uses ANSI color when the terminal supports it.
pub fn printStatus(stdout: anytype, ansi: bool, kind: StatusKind, msg: []const u8) !void {
    if (ansi) {
        const color = switch (kind) {
            .ok => ansi_green,
            .warn => ansi_yellow,
            .fail => ansi_red,
            .info => ansi_cyan,
        };
        const label = switch (kind) {
            .ok => "OK  ",
            .warn => "WARN",
            .fail => "FAIL",
            .info => "INFO",
        };
        try stdout.print("{s}{s}[{s}]{s} {s}\n", .{ ansi_bold, color, label, ansi_reset, msg });
    } else {
        const label = switch (kind) {
            .ok => "OK  ",
            .warn => "WARN",
            .fail => "FAIL",
            .info => "INFO",
        };
        try stdout.print("[{s}] {s}\n", .{ label, msg });
    }
}

/// Color-code a workspace/service state string for display.
pub fn stateColor(state: []const u8) struct { pre: []const u8, post: []const u8 } {
    const pre = if (std.mem.eql(u8, state, "ready") or std.mem.eql(u8, state, "active") or std.mem.eql(u8, state, "running") or std.mem.eql(u8, state, "done"))
        ansi_green
    else if (std.mem.eql(u8, state, "warming") or std.mem.eql(u8, state, "pending") or std.mem.eql(u8, state, "starting"))
        ansi_yellow
    else if (std.mem.eql(u8, state, "error") or std.mem.eql(u8, state, "failed") or std.mem.eql(u8, state, "stopped"))
        ansi_red
    else
        ansi_dim;
    return .{ .pre = pre, .post = ansi_reset };
}

pub fn printState(stdout: anytype, ansi: bool, state: []const u8) !void {
    if (ansi) {
        const c = stateColor(state);
        try stdout.print("{s}{s}{s}", .{ c.pre, state, c.post });
    } else {
        try stdout.writeAll(state);
    }
}

// ── Table renderer ────────────────────────────────────────────────────────────

/// A simple column-aligned table.  Stores all rows in memory, computes column
/// widths from content, then prints once.
///
/// Usage:
///   var t = Table.init(allocator, &.{"ID", "Name", "Status"});
///   defer t.deinit();
///   try t.row(&.{id, name, status});
///   try t.print(stdout, ansi);
pub const Table = struct {
    allocator: std.mem.Allocator,
    headers: []const []const u8,
    col_widths: []usize,
    rows: std.ArrayListUnmanaged([][]u8),

    pub fn init(allocator: std.mem.Allocator, headers: []const []const u8) !Table {
        const widths = try allocator.alloc(usize, headers.len);
        for (headers, 0..) |h, i| widths[i] = h.len;
        return .{
            .allocator = allocator,
            .headers = headers,
            .col_widths = widths,
            .rows = .{},
        };
    }

    pub fn deinit(self: *Table) void {
        for (self.rows.items) |r| {
            for (r) |cell| self.allocator.free(cell);
            self.allocator.free(r);
        }
        self.rows.deinit(self.allocator);
        self.allocator.free(self.col_widths);
    }

    /// Add a row. `cells` must have the same length as `headers`.
    /// Each cell string is duped, so the caller owns the originals.
    pub fn row(self: *Table, cells: []const []const u8) !void {
        std.debug.assert(cells.len == self.headers.len);
        const owned = try self.allocator.alloc([]u8, cells.len);
        for (cells, 0..) |cell, i| {
            owned[i] = try self.allocator.dupe(u8, cell);
            if (cell.len > self.col_widths[i]) self.col_widths[i] = cell.len;
        }
        try self.rows.append(self.allocator, owned);
    }

    pub fn print(self: *const Table, stdout: anytype, ansi: bool) !void {
        // Header row
        if (ansi) try stdout.writeAll(ansi_bold);
        for (self.headers, 0..) |h, i| {
            try stdout.writeAll(h);
            if (i + 1 < self.headers.len) {
                try printPadding(stdout, self.col_widths[i] - h.len + 2);
            }
        }
        if (ansi) try stdout.writeAll(ansi_reset);
        try stdout.writeByte('\n');

        // Separator
        for (self.col_widths, 0..) |w, i| {
            var j: usize = 0;
            while (j < w) : (j += 1) try stdout.writeByte('-');
            if (i + 1 < self.col_widths.len) {
                try stdout.writeAll("  ");
            }
        }
        try stdout.writeByte('\n');

        // Data rows
        for (self.rows.items) |data_row| {
            for (data_row, 0..) |cell, i| {
                try stdout.writeAll(cell);
                if (i + 1 < data_row.len) {
                    try printPadding(stdout, self.col_widths[i] - cell.len + 2);
                }
            }
            try stdout.writeByte('\n');
        }
    }

    fn printPadding(stdout: anytype, count: usize) !void {
        var i: usize = 0;
        while (i < count) : (i += 1) try stdout.writeByte(' ');
    }
};

// ── JSON output helper ────────────────────────────────────────────────────────

/// Pretty-print a raw JSON payload. Falls back to raw print on parse error.
pub fn printJson(stdout: anytype, allocator: std.mem.Allocator, json: []const u8) !void {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, json, .{}) catch {
        try stdout.print("{s}\n", .{json});
        return;
    };
    defer parsed.deinit();
    const pretty = try std.fmt.allocPrint(
        allocator,
        "{f}",
        .{std.json.fmt(parsed.value, .{ .whitespace = .indent_2 })},
    );
    defer allocator.free(pretty);
    try stdout.print("{s}\n", .{pretty});
}
