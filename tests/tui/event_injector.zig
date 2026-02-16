//! Event Injector - Simulates user input events for testing
//! 
//! Provides a way to inject keyboard and mouse events into the TUI
//! for automated testing scenarios.

const std = @import("std");

pub const Key = union(enum) {
    char: u8,
    enter,
    escape,
    backspace,
    delete,
    tab,
    space,
    up,
    down,
    left,
    right,
    home,
    end,
    page_up,
    page_down,
    f1,
    f2,
    f3,
    f4,
    f5,
    f6,
    f7,
    f8,
    f9,
    f10,
    f11,
    f12,
};

pub const Modifiers = packed struct {
    ctrl: bool = false,
    alt: bool = false,
    shift: bool = false,
    meta: bool = false,
};

pub const KeyEvent = struct {
    key: Key,
    modifiers: Modifiers = .{},
};

pub const MouseButton = enum {
    left,
    right,
    middle,
};

pub const MouseEvent = struct {
    button: MouseButton,
    x: u16,
    y: u16,
    modifiers: Modifiers = .{},
};

pub const Event = union(enum) {
    key: KeyEvent,
    mouse: MouseEvent,
    resize: struct { width: u16, height: u16 },
    quit,
};

pub const EventInjector = struct {
    allocator: std.mem.Allocator,
    events: std.ArrayList(Event),
    event_index: usize = 0,
    
    pub fn init(allocator: std.mem.Allocator) EventInjector {
        return .{
            .allocator = allocator,
            .events = .empty,
        };
    }
    
    pub fn deinit(self: *EventInjector) void {
        self.events.deinit(self.allocator);
    }
    
    /// Add a key event to the queue
    pub fn addKey(self: *EventInjector, key: Key) !void {
        try self.events.append(self.allocator, .{ .key = .{ .key = key } });
    }
    
    /// Add a key event with modifiers
    pub fn addKeyWithModifiers(self: *EventInjector, key: Key, modifiers: Modifiers) !void {
        try self.events.append(self.allocator, .{ .key = .{ .key = key, .modifiers = modifiers } });
    }
    
    /// Add a character key press
    pub fn addChar(self: *EventInjector, char: u8) !void {
        try self.events.append(self.allocator, .{ .key = .{ .key = .{ .char = char } } });
    }
    
    /// Add a string as sequential character presses
    pub fn addString(self: *EventInjector, str: []const u8) !void {
        for (str) |char| {
            try self.addChar(char);
        }
    }
    
    /// Add Ctrl+key combination
    pub fn addCtrlKey(self: *EventInjector, key: u8) !void {
        try self.events.append(self.allocator, .{ .key = .{
            .key = .{ .char = key },
            .modifiers = .{ .ctrl = true },
        } });
    }
    
    /// Add Alt+key combination
    pub fn addAltKey(self: *EventInjector, key: u8) !void {
        try self.events.append(self.allocator, .{ .key = .{
            .key = .{ .char = key },
            .modifiers = .{ .alt = true },
        } });
    }
    
    /// Add Enter key press
    pub fn addEnter(self: *EventInjector) !void {
        try self.addKey(.enter);
    }
    
    /// Add Escape key press
    pub fn addEscape(self: *EventInjector) !void {
        try self.addKey(.escape);
    }
    
    /// Add Backspace key press
    pub fn addBackspace(self: *EventInjector) !void {
        try self.addKey(.backspace);
    }
    
    /// Add Delete key press
    pub fn addDelete(self: *EventInjector) !void {
        try self.addKey(.delete);
    }
    
    /// Add Tab key press
    pub fn addTab(self: *EventInjector) !void {
        try self.addKey(.tab);
    }
    
    /// Add arrow key presses
    pub fn addArrowUp(self: *EventInjector) !void {
        try self.addKey(.up);
    }
    
    pub fn addArrowDown(self: *EventInjector) !void {
        try self.addKey(.down);
    }
    
    pub fn addArrowLeft(self: *EventInjector) !void {
        try self.addKey(.left);
    }
    
    pub fn addArrowRight(self: *EventInjector) !void {
        try self.addKey(.right);
    }
    
    /// Add Ctrl+C (interrupt/quit)
    pub fn addCtrlC(self: *EventInjector) !void {
        try self.addCtrlKey('c');
    }
    
    /// Add Ctrl+D (disconnect/EOF)
    pub fn addCtrlD(self: *EventInjector) !void {
        try self.addCtrlKey('d');
    }
    
    /// Add mouse click event
    pub fn addMouseClick(self: *EventInjector, x: u16, y: u16) !void {
        try self.events.append(self.allocator, .{ .mouse = .{
            .button = .left,
            .x = x,
            .y = y,
        } });
    }
    
    /// Add resize event
    pub fn addResize(self: *EventInjector, width: u16, height: u16) !void {
        try self.events.append(self.allocator, .{ .resize = .{ .width = width, .height = height } });
    }
    
    /// Add quit event
    pub fn addQuit(self: *EventInjector) !void {
        try self.events.append(self.allocator, .quit);
    }
    
    /// Get the next event (for mock TUI to call)
    pub fn nextEvent(self: *EventInjector) ?Event {
        if (self.event_index >= self.events.items.len) return null;
        const event = self.events.items[self.event_index];
        self.event_index += 1;
        return event;
    }
    
    /// Peek at next event without consuming it
    pub fn peekEvent(self: *EventInjector) ?Event {
        if (self.event_index >= self.events.items.len) return null;
        return self.events.items[self.event_index];
    }
    
    /// Check if there are more events
    pub fn hasMoreEvents(self: *EventInjector) bool {
        return self.event_index < self.events.items.len;
    }
    
    /// Reset to beginning of event queue
    pub fn reset(self: *EventInjector) void {
        self.event_index = 0;
    }
    
    /// Clear all events
    pub fn clear(self: *EventInjector) void {
        self.events.clearRetainingCapacity(self.allocator);
        self.event_index = 0;
    }
    
    /// Get number of remaining events
    pub fn remainingCount(self: *EventInjector) usize {
        if (self.event_index >= self.events.items.len) return 0;
        return self.events.items.len - self.event_index;
    }
    
    /// Create a sequence builder for fluent API
    pub fn sequence(self: *EventInjector) SequenceBuilder {
        return .{ .injector = self };
    }
};

/// Fluent API for building event sequences
pub const SequenceBuilder = struct {
    injector: *EventInjector,
    
    pub fn typeText(self: SequenceBuilder, text: []const u8) !SequenceBuilder {
        try self.injector.addString(text);
        return self;
    }
    
    pub fn pressEnter(self: SequenceBuilder) !SequenceBuilder {
        try self.injector.addEnter();
        return self;
    }
    
    pub fn pressEscape(self: SequenceBuilder) !SequenceBuilder {
        try self.injector.addEscape();
        return self;
    }
    
    pub fn pressBackspace(self: SequenceBuilder) !SequenceBuilder {
        try self.injector.addBackspace();
        return self;
    }
    
    pub fn pressCtrlC(self: SequenceBuilder) !SequenceBuilder {
        try self.injector.addCtrlC();
        return self;
    }
    
    pub fn pressCtrlD(self: SequenceBuilder) !SequenceBuilder {
        try self.injector.addCtrlD();
        return self;
    }
    
    pub fn waitForMs(self: SequenceBuilder, ms: u64) SequenceBuilder {
        // In a real implementation, this might add a delay event
        _ = ms;
        return self;
    }
};

// ============================================================================
// Common Event Sequences
// ============================================================================

pub const EventSequences = struct {
    /// Connect to a server: type URL and press Enter
    pub fn connect(injector: *EventInjector, url: []const u8) !void {
        try injector.addString(url);
        try injector.addEnter();
    }
    
    /// Send a chat message
    pub fn sendMessage(injector: *EventInjector, message: []const u8) !void {
        try injector.addString(message);
        try injector.addEnter();
    }
    
    /// Disconnect from server
    pub fn disconnect(injector: *EventInjector) !void {
        try injector.addCtrlD();
    }
    
    /// Quit the application
    pub fn quit(injector: *EventInjector) !void {
        try injector.addCtrlC();
    }
    
    /// Clear input field (Ctrl+U or multiple backspaces)
    pub fn clearInput(injector: *EventInjector, char_count: usize) !void {
        for (0..char_count) |_| {
            try injector.addBackspace();
        }
    }
};
