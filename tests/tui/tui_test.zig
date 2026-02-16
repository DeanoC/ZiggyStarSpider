//! TUI Testing Framework for ZiggyStarSpider
//! 
//! This module provides a headless testing framework for the TUI application.
//! It allows programmatic control of the TUI for automated testing.

const std = @import("std");

// Test harness components
pub const VirtualTerminal = @import("virtual_terminal.zig").VirtualTerminal;
pub const MockTui = @import("mock_tui.zig").MockTui;
pub const TestHarness = @import("test_harness.zig").TestHarness;
pub const ScreenBuffer = @import("screen_buffer.zig").ScreenBuffer;
pub const EventInjector = @import("event_injector.zig").EventInjector;

// Re-export test utilities
pub const expect = std.testing.expect;
pub const expectEqual = std.testing.expectEqual;
pub const expectEqualStrings = std.testing.expectEqualStrings;

/// Initialize the TUI testing framework
pub fn init() void {
    // Setup any global test state
}

/// Cleanup the TUI testing framework
pub fn deinit() void {
    // Cleanup any global test state
}
