//! Mock TUI - Provides mock implementations of TUI library interfaces
//! 
//! This module creates mock versions of the TUI library's types and interfaces
//! that can be used for headless testing without requiring an actual terminal.

const std = @import("std");
const VirtualTerminal = @import("virtual_terminal.zig").VirtualTerminal;
const EventInjector = @import("event_injector.zig").EventInjector;
const Event = @import("event_injector.zig").Event;

// Re-export types that match the real TUI library interface
pub const Color = @import("virtual_terminal.zig").Color;
pub const Attributes = @import("virtual_terminal.zig").Attributes;

pub const Style = struct {
    fg: Color = .default,
    bg: Color = .default,
    attrs: Attributes = .{},
};

pub const EventResult = enum {
    consumed,
    ignored,
};

pub const Bounds = struct {
    x: u16,
    y: u16,
    width: u16,
    height: u16,
};

/// Mock RenderContext that renders to a virtual terminal
pub const RenderContext = struct {
    terminal: *VirtualTerminal,
    theme: Theme,
    bounds: Bounds,
    clip: Bounds,
    focused_id: ?u32,
    time_ns: i64,
    
    /// The screen interface that widgets interact with
    pub const Screen = struct {
        ctx: *RenderContext,
        
        pub fn clear(self: Screen) void {
            // Only clear within bounds
            for (self.ctx.bounds.y..self.ctx.bounds.y + self.ctx.bounds.height) |y| {
                for (self.ctx.bounds.x..self.ctx.bounds.x + self.ctx.bounds.width) |x| {
                    self.ctx.terminal.moveCursor(@intCast(x), @intCast(y));
                    self.ctx.terminal.putChar(' ');
                }
            }
        }
        
        pub fn moveCursor(self: Screen, x: u16, y: u16) void {
            const abs_x = self.ctx.bounds.x + x;
            const abs_y = self.ctx.bounds.y + y;
            self.ctx.terminal.moveCursor(abs_x, abs_y);
        }
        
        pub fn setStyle(self: Screen, style: Style) void {
            self.ctx.terminal.setStyle(.{
                .fg = style.fg,
                .bg = style.bg,
                .attrs = style.attrs,
            });
        }
        
        pub fn putString(self: Screen, str: []const u8) void {
            self.ctx.terminal.putString(str);
        }
        
        pub fn putChar(self: Screen, char: u21) void {
            self.ctx.terminal.putChar(char);
        }
        
        pub fn getWidth(self: Screen) u16 {
            return self.ctx.bounds.width;
        }
        
        pub fn getHeight(self: Screen) u16 {
            return self.ctx.bounds.height;
        }
    };
    
    pub fn screen(self: *RenderContext) Screen {
        return .{ .ctx = self };
    }
};

pub const Theme = struct {
    background: Color = .default,
    foreground: Color = .default,
    accent: Color = .cyan,
    error_color: Color = .red,
    success: Color = .green,
    warning: Color = .yellow,
};

/// Mock InputField that works with our virtual terminal
pub const InputField = struct {
    allocator: std.mem.Allocator,
    buffer: std.ArrayList(u8),
    cursor_pos: usize = 0,
    placeholder: ?[]const u8 = null,
    focused: bool = true,
    
    pub fn init(allocator: std.mem.Allocator) InputField {
        return .{
            .allocator = allocator,
            .buffer = std.ArrayList(u8).init(allocator),
        };
    }
    
    pub fn deinit(self: *InputField) void {
        self.buffer.deinit();
        if (self.placeholder) |p| {
            self.allocator.free(p);
        }
    }
    
    pub fn setValue(self: *InputField, value: []const u8) !void {
        self.buffer.clearRetainingCapacity();
        try self.buffer.appendSlice(value);
        self.cursor_pos = value.len;
    }
    
    pub fn getValue(self: *InputField) []const u8 {
        return self.buffer.items;
    }
    
    pub fn clear(self: *InputField) void {
        self.buffer.clearRetainingCapacity();
        self.cursor_pos = 0;
    }
    
    pub fn insertChar(self: *InputField, char: u8) !void {
        try self.buffer.insert(self.cursor_pos, char);
        self.cursor_pos += 1;
    }
    
    pub fn deleteChar(self: *InputField) void {
        if (self.cursor_pos < self.buffer.items.len) {
            _ = self.buffer.orderedRemove(self.cursor_pos);
        }
    }
    
    pub fn backspace(self: *InputField) void {
        if (self.cursor_pos > 0) {
            self.cursor_pos -= 1;
            _ = self.buffer.orderedRemove(self.cursor_pos);
        }
    }
    
    pub fn moveCursorLeft(self: *InputField) void {
        if (self.cursor_pos > 0) {
            self.cursor_pos -= 1;
        }
    }
    
    pub fn moveCursorRight(self: *InputField) void {
        if (self.cursor_pos < self.buffer.items.len) {
            self.cursor_pos += 1;
        }
    }
    
    pub fn moveCursorHome(self: *InputField) void {
        self.cursor_pos = 0;
    }
    
    pub fn moveCursorEnd(self: *InputField) void {
        self.cursor_pos = self.buffer.items.len;
    }
    
    pub fn render(self: *InputField, ctx: *RenderContext) void {
        const screen = ctx.screen();
        const width = ctx.bounds.width;
        
        // Draw background
        screen.setStyle(.{ .fg = .white, .bg = .default });
        for (0..width) |_| {
            screen.putChar(' ');
        }
        
        // Move back to start
        screen.moveCursor(0, 0);
        
        // Draw content or placeholder
        const content = if (self.buffer.items.len > 0)
            self.buffer.items
        else if (self.placeholder) |p|
            p
        else
            "";
        
        const style = if (self.buffer.items.len > 0)
            Style{ .fg = .white }
        else
            Style{ .fg = .gray };
        
        screen.setStyle(style);
        
        // Truncate if too long
        const display_len = @min(content.len, width);
        screen.putString(content[0..display_len]);
    }
    
    pub fn handleEvent(self: *InputField, event: Event) EventResult {
        switch (event) {
            .key => |key_event| {
                switch (key_event.key) {
                    .char => |c| {
                        if (key_event.modifiers.ctrl) {
                            // Handle Ctrl+key combinations
                            switch (c) {
                                'a' => self.moveCursorHome(),
                                'e' => self.moveCursorEnd(),
                                'u' => self.clear(),
                                else => return .ignored,
                            }
                            return .consumed;
                        }
                        self.insertChar(c) catch return .ignored;
                        return .consumed;
                    },
                    .enter => return .ignored, // Let parent handle
                    .backspace => {
                        self.backspace();
                        return .consumed;
                    },
                    .delete => {
                        self.deleteChar();
                        return .consumed;
                    },
                    .left => {
                        self.moveCursorLeft();
                        return .consumed;
                    },
                    .right => {
                        self.moveCursorRight();
                        return .consumed;
                    },
                    .home => {
                        self.moveCursorHome();
                        return .consumed;
                    },
                    .end => {
                        self.moveCursorEnd();
                        return .consumed;
                    },
                    else => return .ignored,
                }
            },
            else => return .ignored,
        }
    }
};

/// Mock App that runs without a real terminal
pub const App = struct {
    allocator: std.mem.Allocator,
    terminal: *VirtualTerminal,
    injector: *EventInjector,
    theme: Theme,
    running: bool = false,
    should_quit: bool = false,
    root_widget: ?*anyopaque = null,
    render_fn: ?*const fn (*anyopaque, *RenderContext) void = null,
    event_fn: ?*const fn (*anyopaque, Event) EventResult = null,
    
    pub const Config = struct {
        alternate_screen: bool = true,
        hide_cursor: bool = false,
        enable_mouse: bool = true,
    };
    
    pub fn initWithAllocator(allocator: std.mem.Allocator, config: Config) !App {
        _ = config;
        
        // Create a terminal - we'll need to set it after init
        return .{
            .allocator = allocator,
            .terminal = undefined, // Set later
            .injector = undefined, // Set later
            .theme = .{},
        };
    }
    
    pub fn initForTesting(allocator: std.mem.Allocator, terminal: *VirtualTerminal, injector: *EventInjector) !App {
        return .{
            .allocator = allocator,
            .terminal = terminal,
            .injector = injector,
            .theme = .{},
        };
    }
    
    pub fn deinit(self: *App) void {
        _ = self;
    }
    
    pub fn setRoot(self: *App, widget: anytype) !void {
        const WidgetType = @TypeOf(widget);
        self.root_widget = widget;
        
        // Store type-erased function pointers
        self.render_fn = struct {
            pub fn render(ptr: *anyopaque, ctx: *RenderContext) void {
                const typed_ptr: WidgetType = @ptrCast(@alignCast(ptr));
                typed_ptr.render(ctx);
            }
        }.render;
        
        self.event_fn = struct {
            pub fn handleEvent(ptr: *anyopaque, event: Event) EventResult {
                const typed_ptr: WidgetType = @ptrCast(@alignCast(ptr));
                return typed_ptr.handleEvent(event);
            }
        }.handleEvent;
    }
    
    pub fn run(self: *App) !void {
        self.running = true;
        
        while (self.running and !self.should_quit) {
            // Process events
            if (self.injector.nextEvent()) |event| {
                switch (event) {
                    .quit => {
                        self.should_quit = true;
                        break;
                    },
                    else => {
                        if (self.event_fn) |handler| {
                            const result = handler(self.root_widget.?, event);
                            if (result == .consumed) continue;
                        }
                    },
                }
            } else {
                // No more events - exit if we're in test mode
                break;
            }
            
            // Render
            if (self.render_fn) |renderer| {
                var ctx = RenderContext{
                    .terminal = self.terminal,
                    .theme = self.theme,
                    .bounds = .{
                        .x = 0,
                        .y = 0,
                        .width = self.terminal.width,
                        .height = self.terminal.height,
                    },
                    .clip = .{
                        .x = 0,
                        .y = 0,
                        .width = self.terminal.width,
                        .height = self.terminal.height,
                    },
                    .focused_id = null,
                    .time_ns = std.time.nanoTimestamp(),
                };
                renderer(self.root_widget.?, &ctx);
            }
        }
    }
    
    pub fn stop(self: *App) void {
        self.running = false;
    }
    
    pub fn requestQuit(self: *App) void {
        self.should_quit = true;
    }
};

/// Mock TUI module that aggregates all mock types
pub const MockTui = @This();
