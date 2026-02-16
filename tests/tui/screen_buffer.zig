//! Screen Buffer - Captures and analyzes TUI screen output
//! 
//! Provides utilities for capturing screen state and making assertions
//! about what is rendered.

const std = @import("std");
const VirtualTerminal = @import("virtual_terminal.zig").VirtualTerminal;

pub const ScreenBuffer = struct {
    allocator: std.mem.Allocator,
    terminal: VirtualTerminal,
    snapshots: std.ArrayList(Snapshot),
    
    pub const Snapshot = struct {
        name: []const u8,
        text: []const u8,
        timestamp: i64,
    };
    
    pub fn init(allocator: std.mem.Allocator, width: u16, height: u16) !ScreenBuffer {
        return .{
            .allocator = allocator,
            .terminal = try VirtualTerminal.init(allocator, width, height),
            .snapshots = .empty,
        };
    }
    
    pub fn deinit(self: *ScreenBuffer) void {
        for (self.snapshots.items) |snap| {
            self.allocator.free(snap.name);
            self.allocator.free(snap.text);
        }
        self.snapshots.deinit(self.allocator);
        self.terminal.deinit();
    }
    
    /// Take a snapshot of the current screen state
    pub fn snapshot(self: *ScreenBuffer, name: []const u8) !void {
        const text = try self.terminal.getAllText(self.allocator);
        errdefer self.allocator.free(text);
        
        const name_copy = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(name_copy);
        
        try self.snapshots.append(self.allocator, .{
            .name = name_copy,
            .text = text,
            .timestamp = std.time.timestamp(),
        });
    }
    
    /// Check if text exists on current screen
    pub fn contains(self: *ScreenBuffer, text: []const u8) bool {
        return self.terminal.hasText(text);
    }
    
    /// Find text position on screen
    pub fn find(self: *ScreenBuffer, text: []const u8) ?struct { x: u16, y: u16 } {
        return self.terminal.findText(text);
    }
    
    /// Get text at specific row
    pub fn getRow(self: *ScreenBuffer, y: u16) ![]u8 {
        return self.terminal.getRowString(y, self.allocator);
    }
    
    /// Assert that text exists on screen
    pub fn expectText(self: *ScreenBuffer, expected: []const u8) !void {
        if (!self.contains(expected)) {
            const actual = try self.terminal.getAllText(self.allocator);
            defer self.allocator.free(actual);
            
            std.debug.print("\nExpected text not found: '{s}'\n", .{expected});
            std.debug.print("Actual screen content:\n{s}\n", .{actual});
            return error.TextNotFound;
        }
    }
    
    /// Assert that text does NOT exist on screen
    pub fn expectNoText(self: *ScreenBuffer, unexpected: []const u8) !void {
        if (self.contains(unexpected)) {
            std.debug.print("\nUnexpected text found: '{s}'\n", .{unexpected});
            return error.UnexpectedTextFound;
        }
    }
    
    /// Assert that screen contains all expected texts
    pub fn expectAllTexts(self: *ScreenBuffer, expecteds: []const []const u8) !void {
        for (expecteds) |expected| {
            try self.expectText(expected);
        }
    }
    
    /// Assert that screen matches a pattern (substring match)
    pub fn expectPattern(self: *ScreenBuffer, pattern: []const u8) !void {
        const text = try self.terminal.getAllText(self.allocator);
        defer self.allocator.free(text);
        
        if (std.mem.indexOf(u8, text, pattern) == null) {
            std.debug.print("\nPattern not found: '{s}'\n", .{pattern});
            std.debug.print("Actual screen content:\n{s}\n", .{text});
            return error.PatternNotFound;
        }
    }
    
    /// Get the terminal for direct manipulation
    pub fn getTerminal(self: *ScreenBuffer) *VirtualTerminal {
        return &self.terminal;
    }
    
    /// Compare current screen with a snapshot
    pub fn compareWithSnapshot(self: *ScreenBuffer, snapshot_name: []const u8) !bool {
        for (self.snapshots.items) |snap| {
            if (std.mem.eql(u8, snap.name, snapshot_name)) {
                const current = try self.terminal.getAllText(self.allocator);
                defer self.allocator.free(current);
                return std.mem.eql(u8, current, snap.text);
            }
        }
        return error.SnapshotNotFound;
    }
    
    /// Print current screen for debugging
    pub fn debugPrint(self: *ScreenBuffer) void {
        const stdout = std.io.getStdOut().writer();
        self.terminal.dump(stdout) catch {};
    }
    
    /// Get current screen content as string
    pub fn getContent(self: *ScreenBuffer) ![]u8 {
        return self.terminal.getAllText(self.allocator);
    }
};

// ============================================================================
// Screen Assertions Helper
// ============================================================================

pub const ScreenAssertions = struct {
    buffer: *ScreenBuffer,
    
    pub fn init(buffer: *ScreenBuffer) ScreenAssertions {
        return .{ .buffer = buffer };
    }
    
    /// Assert text exists at specific position
    pub fn textAt(self: ScreenAssertions, x: u16, y: u16, expected: []const u8) !void {
        const row = try self.buffer.getRow(y);
        defer self.buffer.allocator.free(row);
        
        if (x + expected.len > row.len) {
            return error.TextNotAtPosition;
        }
        
        const actual = row[x..x + expected.len];
        if (!std.mem.eql(u8, actual, expected)) {
            std.debug.print("\nExpected '{s}' at ({d},{d}), found '{s}'\n", .{ expected, x, y, actual });
            return error.TextMismatch;
        }
    }
    
    /// Assert row contains text
    pub fn rowContains(self: ScreenAssertions, y: u16, expected: []const u8) !void {
        const row = try self.buffer.getRow(y);
        defer self.buffer.allocator.free(row);
        
        if (std.mem.indexOf(u8, row, expected) == null) {
            std.debug.print("\nRow {d} does not contain '{s}'\n", .{ y, expected });
            std.debug.print("Row content: '{s}'\n", .{row});
            return error.TextNotInRow;
        }
    }
    
    /// Assert screen has expected dimensions
    pub fn dimensions(self: ScreenAssertions, expected_width: u16, expected_height: u16) !void {
        const term = self.buffer.getTerminal();
        if (term.width != expected_width or term.height != expected_height) {
            std.debug.print("\nExpected dimensions {d}x{d}, got {d}x{d}\n", .{
                expected_width, expected_height, term.width, term.height,
            });
            return error.DimensionMismatch;
        }
    }
};
