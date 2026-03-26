// tui.zig — Lightweight TUI primitives for interactive CLI flows.
//
// All functions write to stdout and read from stdin.
// On TTY terminals they use ANSI escape sequences for colour.
// On non-TTY (piped / legacy cmd.exe) they fall back to numbered menus and
// plain text — the same logic works everywhere, just less pretty.

const std = @import("std");

// ── Colour constants (exported so callers can compose sequences) ─────────────

pub const RESET = "\x1b[0m";
pub const BOLD = "\x1b[1m";
pub const DIM = "\x1b[2m";
pub const GREEN = "\x1b[32m";
pub const YELLOW = "\x1b[33m";
pub const CYAN = "\x1b[36m";
pub const RED = "\x1b[31m";
pub const BLUE = "\x1b[34m";

fn isTty() bool {
    return std.fs.File.stdin().isTty() and std.fs.File.stdout().isTty();
}

pub fn writeAnsi(writer: anytype, comptime seq: []const u8) void {
    if (isTty()) writer.writeAll(seq) catch {};
}

// ── Internal: read one line from stdin into an owned slice ──────────────────

pub fn readLine(allocator: std.mem.Allocator) ![]u8 {
    var buf: [4096]u8 = undefined;
    var reader = std.fs.File.stdin().reader(&buf);
    const raw = reader.interface.takeDelimiterExclusive('\n') catch |err| switch (err) {
        error.EndOfStream => return allocator.dupe(u8, ""),
        else => return err,
    };
    // Strip \r on Windows
    const trimmed = if (raw.len > 0 and raw[raw.len - 1] == '\r')
        raw[0 .. raw.len - 1]
    else
        raw;
    return allocator.dupe(u8, std.mem.trim(u8, trimmed, " \t"));
}

fn readLineBuf(out: []u8) ![]u8 {
    var buf: [4096]u8 = undefined;
    var reader = std.fs.File.stdin().reader(&buf);
    const raw = reader.interface.takeDelimiterExclusive('\n') catch |err| switch (err) {
        error.EndOfStream => {
            out[0] = 0;
            return out[0..0];
        },
        else => return err,
    };
    const stripped = if (raw.len > 0 and raw[raw.len - 1] == '\r') raw[0 .. raw.len - 1] else raw;
    const src = std.mem.trim(u8, stripped, " \t");
    const copy_len = @min(src.len, out.len);
    @memcpy(out[0..copy_len], src[0..copy_len]);
    return out[0..copy_len];
}

// ── prompt ───────────────────────────────────────────────────────────────────

/// Prints `question` (and an optional `default` hint), reads a line from stdin.
/// Returns an owned slice; caller must free.
/// If the user presses Enter with no input and `default` is non-null,
/// returns a copy of `default`.
pub fn prompt(
    allocator: std.mem.Allocator,
    question: []const u8,
    default: ?[]const u8,
) ![]u8 {
    const stdout = std.fs.File.stdout().deprecatedWriter();

    writeAnsi(stdout, CYAN ++ BOLD);
    try stdout.writeAll("? ");
    writeAnsi(stdout, RESET ++ BOLD);
    try stdout.writeAll(question);
    writeAnsi(stdout, RESET);
    if (default) |d| {
        writeAnsi(stdout, DIM);
        try stdout.print(" [{s}]", .{d});
        writeAnsi(stdout, RESET);
    }
    try stdout.writeAll(": ");

    const line = try readLine(allocator);
    if (line.len == 0) {
        allocator.free(line);
        if (default) |d| return allocator.dupe(u8, d);
        return allocator.dupe(u8, "");
    }
    return line;
}

// ── confirm ──────────────────────────────────────────────────────────────────

/// Asks a yes/no question. Returns true for y/Y, false for n/N.
/// Defaults to `default_yes` if the user just presses Enter.
pub fn confirm(question: []const u8, default_yes: bool) !bool {
    const stdout = std.fs.File.stdout().deprecatedWriter();

    writeAnsi(stdout, CYAN ++ BOLD);
    try stdout.writeAll("? ");
    writeAnsi(stdout, RESET ++ BOLD);
    try stdout.writeAll(question);
    writeAnsi(stdout, RESET);
    if (default_yes) {
        writeAnsi(stdout, DIM);
        try stdout.writeAll(" [Y/n]");
        writeAnsi(stdout, RESET);
    } else {
        writeAnsi(stdout, DIM);
        try stdout.writeAll(" [y/N]");
        writeAnsi(stdout, RESET);
    }
    try stdout.writeAll(": ");

    var out: [64]u8 = undefined;
    const line = try readLineBuf(&out);
    if (line.len == 0) return default_yes;
    return line[0] == 'y' or line[0] == 'Y';
}

// ── select ───────────────────────────────────────────────────────────────────

/// Presents a numbered list of `options` and returns the chosen index.
/// Returns error.Cancelled if the user types 'q'.
pub fn select(
    allocator: std.mem.Allocator,
    label: []const u8,
    options: []const []const u8,
) !usize {
    const stdout = std.fs.File.stdout().deprecatedWriter();

    writeAnsi(stdout, BOLD);
    try stdout.print("\n{s}\n", .{label});
    writeAnsi(stdout, RESET);

    for (options, 1..) |opt, n| {
        writeAnsi(stdout, DIM);
        try stdout.print("  {d:>2}. ", .{n});
        writeAnsi(stdout, RESET);
        try stdout.print("{s}\n", .{opt});
    }
    try stdout.writeByte('\n');

    while (true) {
        writeAnsi(stdout, CYAN);
        try stdout.print("Enter number (1-{d}): ", .{options.len});
        writeAnsi(stdout, RESET);

        const line = try readLine(allocator);
        defer allocator.free(line);

        if (std.mem.eql(u8, line, "q") or std.mem.eql(u8, line, "Q")) {
            return error.Cancelled;
        }
        const n = std.fmt.parseInt(usize, line, 10) catch {
            writeAnsi(stdout, YELLOW);
            try stdout.print("  Please enter a number between 1 and {d}.\n", .{options.len});
            writeAnsi(stdout, RESET);
            continue;
        };
        if (n < 1 or n > options.len) {
            writeAnsi(stdout, YELLOW);
            try stdout.print("  Please enter a number between 1 and {d}.\n", .{options.len});
            writeAnsi(stdout, RESET);
            continue;
        }
        return n - 1;
    }
}

// ── selectOptional ───────────────────────────────────────────────────────────

/// Like `select` but includes a "(skip)" option at position 0.
/// Returns null if the user chooses skip.
pub fn selectOptional(
    allocator: std.mem.Allocator,
    label: []const u8,
    options: []const []const u8,
) !?usize {
    const stdout = std.fs.File.stdout().deprecatedWriter();

    writeAnsi(stdout, BOLD);
    try stdout.print("\n{s}\n", .{label});
    writeAnsi(stdout, RESET);

    writeAnsi(stdout, DIM);
    try stdout.writeAll("   0. (skip)\n");
    writeAnsi(stdout, RESET);
    for (options, 1..) |opt, n| {
        writeAnsi(stdout, DIM);
        try stdout.print("  {d:>2}. ", .{n});
        writeAnsi(stdout, RESET);
        try stdout.print("{s}\n", .{opt});
    }
    try stdout.writeByte('\n');

    while (true) {
        writeAnsi(stdout, CYAN);
        try stdout.print("Enter number (0-{d}): ", .{options.len});
        writeAnsi(stdout, RESET);

        const line = try readLine(allocator);
        defer allocator.free(line);

        if (std.mem.eql(u8, line, "q") or std.mem.eql(u8, line, "Q")) {
            return error.Cancelled;
        }
        const n = std.fmt.parseInt(usize, line, 10) catch {
            writeAnsi(stdout, YELLOW);
            try stdout.print("  Please enter a number between 0 and {d}.\n", .{options.len});
            writeAnsi(stdout, RESET);
            continue;
        };
        if (n > options.len) {
            writeAnsi(stdout, YELLOW);
            try stdout.print("  Please enter a number between 0 and {d}.\n", .{options.len});
            writeAnsi(stdout, RESET);
            continue;
        }
        if (n == 0) return null;
        return n - 1;
    }
}

// ── printStep ────────────────────────────────────────────────────────────────

pub fn printStep(step: usize, total: usize, title: []const u8) void {
    const stdout = std.fs.File.stdout().deprecatedWriter();
    writeAnsi(stdout, BOLD ++ BLUE);
    stdout.print("\nStep {d}/{d}: {s}\n", .{ step, total, title }) catch {};
    writeAnsi(stdout, RESET);
    var i: usize = 0;
    while (i < title.len + 12) : (i += 1) stdout.writeByte('-') catch {};
    stdout.writeByte('\n') catch {};
}

// ── printSuccess / printError / printInfo / printSummaryRow ─────────────────

pub fn printSuccess(msg: []const u8) void {
    const stdout = std.fs.File.stdout().deprecatedWriter();
    writeAnsi(stdout, GREEN ++ BOLD);
    stdout.writeAll("+ ") catch {};
    writeAnsi(stdout, RESET);
    stdout.print("{s}\n", .{msg}) catch {};
}

pub fn printError(msg: []const u8) void {
    const stderr = std.fs.File.stderr().deprecatedWriter();
    writeAnsi(stderr, RED ++ BOLD);
    stderr.writeAll("! ") catch {};
    writeAnsi(stderr, RESET);
    stderr.print("{s}\n", .{msg}) catch {};
}

pub fn printInfo(msg: []const u8) void {
    const stdout = std.fs.File.stdout().deprecatedWriter();
    writeAnsi(stdout, DIM);
    stdout.print("  {s}\n", .{msg}) catch {};
    writeAnsi(stdout, RESET);
}

pub fn printSummaryRow(label: []const u8, value: []const u8) void {
    const stdout = std.fs.File.stdout().deprecatedWriter();
    writeAnsi(stdout, DIM);
    stdout.print("  {s:<18}", .{label}) catch {};
    writeAnsi(stdout, RESET);
    stdout.print("{s}\n", .{value}) catch {};
}
