//! Virtual Terminal - Simulates a terminal environment for headless testing
//! 
//! This provides a virtual terminal that captures all terminal operations
//! (cursor movement, text output, styling) without needing an actual terminal.

const std = @import("std");

pub const Cell = struct {
    char: u21 = ' ',
    fg: Color = .default,
    bg: Color = .default,
    attrs: Attributes = .{},
    dirty: bool = false,
};

pub const Color = enum(u8) {
    default = 0,
    black = 1,
    red = 2,
    green = 3,
    yellow = 4,
    blue = 5,
    magenta = 6,
    cyan = 7,
    white = 8,
    gray = 9,
    bright_red = 10,
    bright_green = 11,
    bright_yellow = 12,
    bright_blue = 13,
    bright_magenta = 14,
    bright_cyan = 15,
    bright_white = 16,
};

pub const Attributes = packed struct {
    bold: bool = false,
    dim: bool = false,
    italic: bool = false,
    underline: bool = false,
    blink: bool = false,
    reverse: bool = false,
    hidden: bool = false,
    strikethrough: bool = false,
};

pub const Cursor = struct {
    x: u16 = 0,
    y: u16 = 0,
    visible: bool = true,
    style: Cell = .{},
};

pub const VirtualTerminal = struct {
    allocator: std.mem.Allocator,
    width: u16,
    height: u16,
    cells: []Cell,
    cursor: Cursor,
    current_style: Cell,
    alternate_screen: bool = false,
    cleared: bool = false,
    
    pub fn init(allocator: std.mem.Allocator, width: u16, height: u16) !VirtualTerminal {
        const cells = try allocator.alloc(Cell, width * height);
        @memset(cells, Cell{});
        
        return .{
            .allocator = allocator,
            .width = width,
            .height = height,
            .cells = cells,
            .cursor = .{},
            .current_style = .{},
        };
    }
    
    pub fn deinit(self: *VirtualTerminal) void {
        self.allocator.free(self.cells);
    }
    
    /// Resize the terminal
    pub fn resize(self: *VirtualTerminal, width: u16, height: u16) !void {
        const new_cells = try self.allocator.alloc(Cell, width * height);
        @memset(new_cells, Cell{});
        
        // Copy existing content
        const copy_height = @min(self.height, height);
        const copy_width = @min(self.width, width);
        
        for (0..copy_height) |y| {
            for (0..copy_width) |x| {
                new_cells[y * width + x] = self.cells[y * self.width + x];
            }
        }
        
        self.allocator.free(self.cells);
        self.cells = new_cells;
        self.width = width;
        self.height = height;
    }
    
    /// Clear the entire screen
    pub fn clear(self: *VirtualTerminal) void {
        @memset(self.cells, Cell{});
        self.cleared = true;
        self.cursor.x = 0;
        self.cursor.y = 0;
    }
    
    /// Clear from cursor to end of line
    pub fn clearLine(self: *VirtualTerminal) void {
        const row_start = self.cursor.y * self.width;
        for (self.cursor.x..self.width) |x| {
            self.cells[row_start + x] = Cell{};
        }
    }
    
    /// Move cursor to position
    pub fn moveCursor(self: *VirtualTerminal, x: u16, y: u16) void {
        self.cursor.x = @min(x, self.width - 1);
        self.cursor.y = @min(y, self.height - 1);
    }
    
    /// Move cursor relative to current position
    pub fn moveCursorRelative(self: *VirtualTerminal, dx: i16, dy: i16) void {
        const new_x = @as(i32, self.cursor.x) + dx;
        const new_y = @as(i32, self.cursor.y) + dy;
        self.cursor.x = @intCast(@max(0, @min(new_x, self.width - 1)));
        self.cursor.y = @intCast(@max(0, @min(new_y, self.height - 1)));
    }
    
    /// Set the current text style
    pub fn setStyle(self: *VirtualTerminal, style: Cell) void {
        self.current_style = style;
    }
    
    /// Put a single character at cursor position
    pub fn putChar(self: *VirtualTerminal, char: u21) void {
        if (self.cursor.y >= self.height) return;
        
        const idx = self.cursor.y * self.width + self.cursor.x;
        self.cells[idx] = .{
            .char = char,
            .fg = self.current_style.fg,
            .bg = self.current_style.bg,
            .attrs = self.current_style.attrs,
            .dirty = true,
        };
        
        // Advance cursor
        self.cursor.x += 1;
        if (self.cursor.x >= self.width) {
            self.cursor.x = 0;
            self.cursor.y += 1;
        }
    }
    
    /// Put a string at cursor position
    pub fn putString(self: *VirtualTerminal, str: []const u8) void {
        var iter = std.unicode.Utf8Iterator{ .bytes = str, .i = 0 };
        while (iter.nextCodepoint()) |codepoint| {
            self.putChar(codepoint);
        }
    }
    
    /// Get cell at position
    pub fn getCell(self: *VirtualTerminal, x: u16, y: u16) ?Cell {
        if (x >= self.width or y >= self.height) return null;
        return self.cells[y * self.width + x];
    }
    
    /// Get a row as a string
    pub fn getRowString(self: *VirtualTerminal, y: u16, allocator: std.mem.Allocator) ![]u8 {
        if (y >= self.height) return error.OutOfBounds;
        
        var result: std.ArrayList(u8) = .empty;
        defer result.deinit(allocator);
        
        const row_start = y * self.width;
        for (0..self.width) |x| {
            const cell = self.cells[row_start + x];
            if (cell.char <= 0x7F) {
                try result.append(allocator, @intCast(cell.char));
            } else {
                var buf: [4]u8 = undefined;
                const len = std.unicode.utf8Encode(cell.char, &buf) catch continue;
                try result.appendSlice(allocator, buf[0..len]);
            }
        }
        
        // Trim trailing spaces
        var end = result.items.len;
        while (end > 0 and result.items[end - 1] == ' ') {
            end -= 1;
        }
        
        return try allocator.dupe(u8, result.items[0..end]);
    }
    
    /// Search for text on screen
    pub fn findText(self: *VirtualTerminal, text: []const u8) ?struct { x: u16, y: u16 } {
        for (0..self.height) |y| {
            const row_start = y * self.width;
            for (0..self.width) |start_x| {
                if (start_x + text.len > self.width) continue;
                
                var match = true;
                for (text, 0..) |expected_char, i| {
                    const cell = self.cells[row_start + start_x + i];
                    if (cell.char != expected_char) {
                        match = false;
                        break;
                    }
                }
                
                if (match) {
                    return .{ .x = @intCast(start_x), .y = @intCast(y) };
                }
            }
        }
        return null;
    }
    
    /// Check if text exists on screen
    pub fn hasText(self: *VirtualTerminal, text: []const u8) bool {
        return self.findText(text) != null;
    }
    
    /// Get all text on screen as a single string
    pub fn getAllText(self: *VirtualTerminal, allocator: std.mem.Allocator) ![]u8 {
        var result: std.ArrayList(u8) = .empty;
        defer result.deinit(allocator);
        
        for (0..self.height) |y| {
            const row = try self.getRowString(@intCast(y), allocator);
            defer allocator.free(row);
            if (row.len > 0) {
                if (result.items.len > 0) try result.append(allocator, '\n');
                try result.appendSlice(allocator, row);
            }
        }
        
        return try allocator.dupe(u8, result.items);
    }
    
    /// Enable alternate screen buffer
    pub fn enableAlternateScreen(self: *VirtualTerminal) void {
        self.alternate_screen = true;
        self.clear();
    }
    
    /// Disable alternate screen buffer
    pub fn disableAlternateScreen(self: *VirtualTerminal) void {
        self.alternate_screen = false;
    }
    
    /// Dump screen content for debugging
    pub fn dump(self: *VirtualTerminal, writer: anytype) !void {
        try writer.print("Terminal ({d}x{d}):\n", .{ self.width, self.height });
        try writer.print("Cursor: ({d}, {d})\n", .{ self.cursor.x, self.cursor.y });
        try writer.print("+{s}+\n", .{"-" ** self.width});
        
        for (0..self.height) |y| {
            try writer.writeByte('|');
            const row_start = y * self.width;
            for (0..self.width) |x| {
                const cell = self.cells[row_start + x];
                const char: u8 = if (cell.char < 128 and cell.char >= 32)
                    @intCast(cell.char)
                else if (cell.char == 0)
                    ' '
                else
                    '?';
                try writer.writeByte(char);
            }
            try writer.print("|\n", .{});
        }
        
        try writer.print("+{s}+\n", .{"-" ** self.width});
    }
};

// ============================================================================
// Tests
// ============================================================================

test "VirtualTerminal basic operations" {
    const allocator = std.testing.allocator;
    
    var vt = try VirtualTerminal.init(allocator, 80, 24);
    defer vt.deinit();
    
    try std.testing.expectEqual(@as(u16, 80), vt.width);
    try std.testing.expectEqual(@as(u16, 24), vt.height);
    
    // Test cursor movement
    vt.moveCursor(10, 5);
    try std.testing.expectEqual(@as(u16, 10), vt.cursor.x);
    try std.testing.expectEqual(@as(u16, 5), vt.cursor.y);
    
    // Test putString
    vt.moveCursor(0, 0);
    vt.putString("Hello");
    try std.testing.expect(vt.hasText("Hello"));
    
    // Test findText
    const pos = vt.findText("Hello").?;
    try std.testing.expectEqual(@as(u16, 0), pos.x);
    try std.testing.expectEqual(@as(u16, 0), pos.y);
}

test "VirtualTerminal clear" {
    const allocator = std.testing.allocator;
    
    var vt = try VirtualTerminal.init(allocator, 80, 24);
    defer vt.deinit();
    
    vt.putString("Test content");
    try std.testing.expect(vt.hasText("Test content"));
    
    vt.clear();
    try std.testing.expect(!vt.hasText("Test content"));
    try std.testing.expect(vt.cleared);
}

test "VirtualTerminal resize" {
    const allocator = std.testing.allocator;
    
    var vt = try VirtualTerminal.init(allocator, 80, 24);
    defer vt.deinit();
    
    vt.moveCursor(0, 0);
    vt.putString("Resize test");
    
    try vt.resize(40, 12);
    try std.testing.expectEqual(@as(u16, 40), vt.width);
    try std.testing.expectEqual(@as(u16, 12), vt.height);
    try std.testing.expect(vt.hasText("Resize test"));
}
