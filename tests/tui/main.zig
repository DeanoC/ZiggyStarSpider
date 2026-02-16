//! Main TUI Test Runner
//! 
//! Entry point for running TUI tests. Can be executed via:
//!   zig build test-tui

const std = @import("std");

// Import all test modules to ensure they're compiled
const virtual_terminal = @import("virtual_terminal.zig");
const screen_buffer = @import("screen_buffer.zig");
const event_injector = @import("event_injector.zig");
const mock_tui = @import("mock_tui.zig");
const test_harness = @import("test_harness.zig");
const test_cases = @import("test_cases.zig");
const debug_tui = @import("debug_tui.zig");

pub fn main() !void {
    std.debug.print("\n========================================\n", .{});
    std.debug.print("ZiggyStarSpider TUI Test Suite\n", .{});
    std.debug.print("========================================\n", .{});
    
    std.debug.print("\nTUI Testing Framework initialized.\n", .{});
    std.debug.print("Run tests with: zig build test-tui\n", .{});
    std.debug.print("\nTest modules available:\n", .{});
    std.debug.print("  - virtual_terminal.zig: Virtual terminal simulation\n", .{});
    std.debug.print("  - screen_buffer.zig: Screen capture and assertions\n", .{});
    std.debug.print("  - event_injector.zig: Input simulation\n", .{});
    std.debug.print("  - mock_tui.zig: Mock TUI library interfaces\n", .{});
    std.debug.print("  - test_harness.zig: Test orchestration\n", .{});
    std.debug.print("  - test_cases.zig: Actual test cases\n", .{});
    
    std.debug.print("\nTest categories:\n", .{});
    std.debug.print("  ✓ Connection screen rendering\n", .{});
    std.debug.print("  ✓ URL input handling\n", .{});
    std.debug.print("  ✓ Chat screen rendering\n", .{});
    std.debug.print("  ✓ Message display\n", .{});
    std.debug.print("  ✓ Error handling\n", .{});
    std.debug.print("  ✓ Event injection\n", .{});
    std.debug.print("  ✓ Screen capture\n", .{});
}

// Re-export test modules for external use
pub const VirtualTerminal = virtual_terminal.VirtualTerminal;
pub const ScreenBuffer = screen_buffer.ScreenBuffer;
pub const EventInjector = event_injector.EventInjector;
pub const MockTui = mock_tui.MockTui;
pub const TestHarness = test_harness.TestHarness;
