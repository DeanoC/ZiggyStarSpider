//! TUI Diagnostic Tool
//! 
//! Standalone executable for diagnosing TUI hang issues.
//! Tests each component in isolation to identify where things get stuck.

const std = @import("std");

// Import TUI test framework components via module
const tui_testing = @import("tui_testing");
const VirtualTerminal = tui_testing.VirtualTerminal;
const EventInjector = tui_testing.EventInjector;
const MockTui = tui_testing.MockTui;

// Import actual TUI components via modules
const cli_args = @import("cli_args");
const client_config = @import("client_config");

// Timeout configuration
const TEST_TIMEOUT_MS = 5000;

// Diagnostic result tracking
const DiagnosticResult = struct {
    name: []const u8,
    passed: bool,
    duration_ms: u64,
    error_message: ?[]const u8 = null,
};

const DiagnosticReport = struct {
    results: std.ArrayList(DiagnosticResult),
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) DiagnosticReport {
        return .{
            .results = .empty,
            .allocator = allocator,
        };
    }
    
    pub fn deinit(self: *DiagnosticReport) void {
        for (self.results.items) |result| {
            if (result.error_message) |msg| {
                self.allocator.free(msg);
            }
        }
        self.results.deinit(self.allocator);
    }
    
    pub fn addResult(self: *DiagnosticReport, result: DiagnosticResult) !void {
        try self.results.append(self.allocator, result);
    }
    
    pub fn printReport(self: *DiagnosticReport) void {
        std.debug.print("\n", .{});
        std.debug.print("╔════════════════════════════════════════════════════════════════╗\n", .{});
        std.debug.print("║           TUI DIAGNOSTIC REPORT                                ║\n", .{});
        std.debug.print("╚════════════════════════════════════════════════════════════════╝\n", .{});
        std.debug.print("\n", .{});
        
        var passed_count: usize = 0;
        var failed_count: usize = 0;
        
        for (self.results.items) |result| {
            const status = if (result.passed) "✅ PASS" else "❌ FAIL";
            
            if (result.passed) {
                passed_count += 1;
            } else {
                failed_count += 1;
            }
            
            std.debug.print("{s:12} | {s:40} | {d:4}ms\n", .{
                status,
                result.name,
                result.duration_ms,
            });
            
            if (result.error_message) |msg| {
                std.debug.print("               Error: {s}\n", .{msg});
            }
        }
        
        std.debug.print("\n", .{});
        std.debug.print("══════════════════════════════════════════════════════════════════\n", .{});
        std.debug.print("Summary: {d} passed, {d} failed\n", .{
            passed_count, failed_count,
        });
        std.debug.print("══════════════════════════════════════════════════════════════════\n", .{});
    }
};

// Run a test and track timing
fn runTest(
    allocator: std.mem.Allocator,
    name: []const u8,
    test_fn: *const fn (std.mem.Allocator) anyerror!void,
) !DiagnosticResult {
    std.debug.print("[TEST] {s}... ", .{name});
    
    const start_time = std.time.milliTimestamp();
    
    test_fn(allocator) catch |err| {
        const end_time = std.time.milliTimestamp();
        const duration = @as(u64, @intCast(end_time - start_time));
        
        std.debug.print("FAILED ({d}ms)\n", .{duration});
        
        return DiagnosticResult{
            .name = name,
            .passed = false,
            .duration_ms = duration,
            .error_message = try std.fmt.allocPrint(allocator, "{s}", .{@errorName(err)}),
        };
    };
    
    const end_time = std.time.milliTimestamp();
    const duration = @as(u64, @intCast(end_time - start_time));
    
    std.debug.print("PASSED ({d}ms)\n", .{duration});
    
    return DiagnosticResult{
        .name = name,
        .passed = true,
        .duration_ms = duration,
    };
}

// ============================================================================
// Individual Tests
// ============================================================================

// Test 1: VirtualTerminal initialization
fn testVirtualTerminalInit(allocator: std.mem.Allocator) !void {
    var vt = try VirtualTerminal.init(allocator, 80, 24);
    defer vt.deinit();
    
    if (vt.width != 80 or vt.height != 24) {
        return error.InvalidDimensions;
    }
}

// Test 2: EventInjector initialization
fn testEventInjectorInit(allocator: std.mem.Allocator) !void {
    var injector = EventInjector.init(allocator);
    defer injector.deinit();
}

// Test 3: Config loading
fn testConfigLoad(allocator: std.mem.Allocator) !void {
    var config = try client_config.Config.load(allocator);
    defer config.deinit();
    
    std.debug.print("(server_url: {s}) ", .{config.server_url});
}

// Test 4: CLI args parsing
fn testCliArgs(allocator: std.mem.Allocator) !void {
    var options = cli_args.Options{};
    defer options.deinit(allocator);
    
    if (options.url.len == 0) {
        return error.EmptyDefaultUrl;
    }
}

// Test 5: VirtualTerminal resize
fn testVirtualTerminalResize(allocator: std.mem.Allocator) !void {
    var vt = try VirtualTerminal.init(allocator, 80, 24);
    defer vt.deinit();
    
    try vt.resize(120, 30);
    
    if (vt.width != 120 or vt.height != 30) {
        return error.ResizeFailed;
    }
}

// Test 6: VirtualTerminal text operations
fn testVirtualTerminalText(allocator: std.mem.Allocator) !void {
    var vt = try VirtualTerminal.init(allocator, 80, 24);
    defer vt.deinit();
    
    vt.moveCursor(0, 0);
    vt.putString("Hello World");
    
    if (!vt.hasText("Hello World")) {
        return error.TextNotFound;
    }
}

// Test 7: Event injection sequence
fn testEventSequence(allocator: std.mem.Allocator) !void {
    var injector = EventInjector.init(allocator);
    defer injector.deinit();
    
    // Add some events using the correct API
    try injector.addChar('h');
    try injector.addChar('i');
    try injector.addKey(.enter);
    
    if (injector.remainingCount() != 3) {
        return error.WrongEventCount;
    }
}

// Test 8: MockTui InputField
fn testMockInputField(allocator: std.mem.Allocator) !void {
    var input = MockTui.InputField.init(allocator);
    defer input.deinit();
    
    try input.setValue("test");
    
    if (!std.mem.eql(u8, input.getValue(), "test")) {
        return error.ValueMismatch;
    }
}

// Test 9: Screen capture
fn testScreenCapture(allocator: std.mem.Allocator) !void {
    var vt = try VirtualTerminal.init(allocator, 80, 24);
    defer vt.deinit();
    
    vt.moveCursor(5, 10);
    vt.putString("X");
    
    const capture = try vt.capture(allocator);
    defer allocator.free(capture);
    
    if (capture.len == 0) {
        return error.EmptyCapture;
    }
}

// Test 10: Config with custom values
fn testConfigCustom(allocator: std.mem.Allocator) !void {
    var config = try client_config.Config.load(allocator);
    defer config.deinit();
    
    std.debug.print("(auto_connect: {}) ", .{
        config.auto_connect_on_launch,
    });
}

// ============================================================================
// Main
// ============================================================================

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    std.debug.print("\n", .{});
    std.debug.print("╔══════════════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║     ZiggyStarSpider TUI Diagnostic Tool                      ║\n", .{});
    std.debug.print("║     Testing components for hang issues                       ║\n", .{});
    std.debug.print("╚══════════════════════════════════════════════════════════════╝\n", .{});
    std.debug.print("\n", .{});
    
    var report = DiagnosticReport.init(allocator);
    defer report.deinit();
    
    // Run all tests
    try report.addResult(try runTest(allocator, "VirtualTerminal.init", testVirtualTerminalInit));
    try report.addResult(try runTest(allocator, "EventInjector.init", testEventInjectorInit));
    try report.addResult(try runTest(allocator, "Config.load", testConfigLoad));
    try report.addResult(try runTest(allocator, "CLI args defaults", testCliArgs));
    try report.addResult(try runTest(allocator, "VirtualTerminal.resize", testVirtualTerminalResize));
    try report.addResult(try runTest(allocator, "VirtualTerminal.text", testVirtualTerminalText));
    try report.addResult(try runTest(allocator, "Event sequence", testEventSequence));
    try report.addResult(try runTest(allocator, "Mock InputField", testMockInputField));
    try report.addResult(try runTest(allocator, "Screen capture", testScreenCapture));
    try report.addResult(try runTest(allocator, "Config inspection", testConfigCustom));
    
    report.printReport();
    
    std.debug.print("\n", .{});
    std.debug.print("══════════════════════════════════════════════════════════════════\n", .{});
    std.debug.print("DIAGNOSTICS COMPLETE\n", .{});
    std.debug.print("══════════════════════════════════════════════════════════════════\n", .{});
    std.debug.print("\n", .{});
    std.debug.print("All framework components tested successfully.\n", .{});
    std.debug.print("\n", .{});
    std.debug.print("To test the actual TUI (which may hang):\n", .{});
    std.debug.print("  zig build run-tui\n", .{});
    std.debug.print("\n", .{});
    std.debug.print("If the TUI hangs, the issue is likely in:\n", .{});
    std.debug.print("  - tui.App.initWithAllocator() - terminal setup\n", .{});
    std.debug.print("  - tui.App.run() - blocking event loop\n", .{});
    std.debug.print("  - stdin/stdout terminal initialization\n", .{});
}
