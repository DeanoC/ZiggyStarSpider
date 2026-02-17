//! Test Harness - Main testing framework for TUI tests
//! 
//! Provides a high-level API for writing TUI tests with setup, execution,
//! and assertion capabilities.

const std = @import("std");
const VirtualTerminal = @import("virtual_terminal.zig").VirtualTerminal;
const EventInjector = @import("event_injector.zig").EventInjector;
const Event = @import("event_injector.zig").Event;
const MockTui = @import("mock_tui.zig").MockTui;

pub const TestResult = union(enum) {
    passed,
    failed: struct {
        message: []const u8,
        line: u32,
        file: []const u8,
    },
    skipped,
};

pub const TestHarness = struct {
    allocator: std.mem.Allocator,
    // Heap-allocated to avoid dangling pointers when passed to MockTui.App
    terminal_ptr: *VirtualTerminal,
    injector_ptr: *EventInjector,
    mock_tui: MockTui.App,
    
    // Test state
    current_test: ?[]const u8 = null,
    results: std.ArrayList(TestResult),
    
    pub fn init(allocator: std.mem.Allocator, width: u16, height: u16) !TestHarness {
        // Allocate terminal on heap to avoid dangling pointers
        const terminal_ptr = try allocator.create(VirtualTerminal);
        errdefer allocator.destroy(terminal_ptr);
        terminal_ptr.* = try VirtualTerminal.init(allocator, width, height);
        errdefer terminal_ptr.deinit();
        
        // Allocate injector on heap to avoid dangling pointers
        const injector_ptr = try allocator.create(EventInjector);
        errdefer allocator.destroy(injector_ptr);
        injector_ptr.* = EventInjector.init(allocator);
        errdefer injector_ptr.deinit();
        
        // Now safe to pass pointers to initForTesting - they remain valid
        const mock_tui = try MockTui.App.initForTesting(allocator, terminal_ptr, injector_ptr);
        
        return .{
            .allocator = allocator,
            .terminal_ptr = terminal_ptr,
            .injector_ptr = injector_ptr,
            .mock_tui = mock_tui,
            .results = std.ArrayList(TestResult).init(allocator),
        };
    }
    
    pub fn deinit(self: *TestHarness) void {
        self.results.deinit();
        self.mock_tui.deinit();
        self.injector_ptr.deinit();
        self.allocator.destroy(self.injector_ptr);
        self.terminal_ptr.deinit();
        self.allocator.destroy(self.terminal_ptr);
    }
    
    /// Start a new test case
    pub fn beginTest(self: *TestHarness, name: []const u8) void {
        self.current_test = name;
        self.injector_ptr.clear();
        self.terminal_ptr.clear();
        std.debug.print("\n[TEST] {s}\n", .{name});
    }
    
    /// End current test case
    pub fn endTest(self: *TestHarness, result: TestResult) !void {
        try self.results.append(result);
        
        switch (result) {
            .passed => std.debug.print("  ✓ PASSED\n", .{}),
            .failed => |f| std.debug.print("  ✗ FAILED: {s} at {s}:{d}\n", .{ f.message, f.file, f.line }),
            .skipped => std.debug.print("  ⊘ SKIPPED\n", .{}),
        }
        
        self.current_test = null;
    }
    
    /// Get the event injector for setting up input
    pub fn getInjector(self: *TestHarness) *EventInjector {
        return self.injector_ptr;
    }
    
    /// Get the virtual terminal for assertions (renders happen here)
    pub fn getTerminal(self: *TestHarness) *VirtualTerminal {
        return self.terminal_ptr;
    }
    
    /// Get the mock TUI app
    pub fn getApp(self: *TestHarness) *MockTui.App {
        return &self.mock_tui;
    }
    
    /// Set the root widget for testing
    pub fn setRootWidget(self: *TestHarness, widget: anytype) !void {
        try self.mock_tui.setRoot(widget);
    }
    
    /// Run the TUI until completion or no more events
    pub fn run(self: *TestHarness) !void {
        try self.mock_tui.run();
    }
    
    /// Run for a specific number of event processing cycles
    pub fn runCycles(self: *TestHarness, cycles: usize) !void {
        for (0..cycles) |_| {
            if (!self.injector_ptr.hasMoreEvents()) break;
            
            if (self.injector_ptr.nextEvent()) |event| {
                // Process event through widget if set
                _ = event;
            }
        }
    }
    
    /// Take a snapshot of current terminal state
    pub fn snapshot(self: *TestHarness, name: []const u8) !void {
        try self.terminal_ptr.snapshot(name);
    }
    
    /// Assert that text exists on terminal (where rendering happens)
    pub fn expectText(self: *TestHarness, expected: []const u8) !void {
        try self.terminal_ptr.expectText(expected);
    }
    
    /// Assert that text does NOT exist on terminal
    pub fn expectNoText(self: *TestHarness, unexpected: []const u8) !void {
        try self.terminal_ptr.expectNoText(unexpected);
    }
    
    /// Assert that terminal contains a pattern
    pub fn expectPattern(self: *TestHarness, pattern: []const u8) !void {
        try self.terminal_ptr.expectPattern(pattern);
    }
    
    /// Assert terminal has specific dimensions
    pub fn expectDimensions(self: *TestHarness, width: u16, height: u16) !void {
        try std.testing.expectEqual(width, self.terminal_ptr.width);
        try std.testing.expectEqual(height, self.terminal_ptr.height);
    }
    
    /// Print current terminal for debugging
    pub fn debugPrint(self: *TestHarness) void {
        self.terminal_ptr.debugPrint();
    }
    
    /// Get test summary
    pub fn getSummary(self: *TestHarness) struct { passed: usize, failed: usize, skipped: usize } {
        var passed: usize = 0;
        var failed: usize = 0;
        var skipped: usize = 0;
        
        for (self.results.items) |result| {
            switch (result) {
                .passed => passed += 1,
                .failed => failed += 1,
                .skipped => skipped += 1,
            }
        }
        
        return .{ .passed = passed, .failed = failed, .skipped = skipped };
    }
    
    /// Print test summary
    pub fn printSummary(self: *TestHarness) void {
        const summary = self.getSummary();
        std.debug.print("\n========================================\n", .{});
        std.debug.print("Test Summary: {d} passed, {d} failed, {d} skipped\n", .{
            summary.passed, summary.failed, summary.skipped,
        });
        std.debug.print("========================================\n", .{});
    }
    
    /// Check if all tests passed
    pub fn allPassed(self: *TestHarness) bool {
        const summary = self.getSummary();
        return summary.failed == 0;
    }
};

/// Test runner for multiple test cases
pub const TestRunner = struct {
    allocator: std.mem.Allocator,
    harness: TestHarness,
    
    pub fn init(allocator: std.mem.Allocator, width: u16, height: u16) !TestRunner {
        return .{
            .allocator = allocator,
            .harness = try TestHarness.init(allocator, width, height),
        };
    }
    
    pub fn deinit(self: *TestRunner) void {
        self.harness.deinit();
    }
    
    /// Run a test function
    pub fn runTest(self: *TestRunner, name: []const u8, test_fn: *const fn (*TestHarness) anyerror!void) !void {
        self.harness.beginTest(name);
        
        test_fn(&self.harness) catch |err| {
            try self.harness.endTest(.{ .failed = .{
                .message = @errorName(err),
                .line = 0,
                .file = name,
            } });
            return;
        };
        
        try self.harness.endTest(.passed);
    }
    
    /// Get the harness
    pub fn getHarness(self: *TestRunner) *TestHarness {
        return &self.harness;
    }
};
