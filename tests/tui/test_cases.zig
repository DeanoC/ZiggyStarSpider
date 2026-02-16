//! TUI Test Cases for ZiggyStarSpider
//! 
//! These tests verify the behavior of the TUI application including:
//! - Connection screen rendering
//! - URL input handling
//! - Connection establishment
//! - Chat message display
//! - Error handling

const std = @import("std");
const tui_test = @import("tui_test.zig");
const TestHarness = tui_test.TestHarness;
const EventInjector = @import("event_injector.zig").EventInjector;
const EventSequences = @import("event_injector.zig").EventSequences;

// Mock versions of the TUI screens for testing
const MockConnectScreen = struct {
    state: MockAppState,
    url_input: MockInputField,
    
    const MockAppState = struct {
        connection_state: ConnectionState = .disconnected,
        connection_error: ?[]const u8 = null,
        
        const ConnectionState = enum {
            disconnected,
            connecting,
            connected,
            err,
        };
    };
    
    const MockInputField = struct {
        value: []const u8 = "",
        placeholder: []const u8 = "ws://127.0.0.1:18790",
        
        pub fn setValue(self: *MockInputField, val: []const u8) void {
            self.value = val;
        }
        
        pub fn getValue(self: *MockInputField) []const u8 {
            return if (self.value.len > 0) self.value else self.placeholder;
        }
        
        pub fn clear(self: *MockInputField) void {
            self.value = "";
        }
    };
    
    pub fn init() MockConnectScreen {
        return .{
            .state = .{},
            .url_input = .{},
        };
    }
    
    pub fn render(self: *MockConnectScreen, terminal: anytype) void {
        // Title
        terminal.moveCursor(30, 2);
        terminal.putString("ZiggyStarSpider TUI");
        
        // Subtitle
        terminal.moveCursor(28, 4);
        terminal.putString("Connect to Spiderweb Server");
        
        // URL label
        terminal.moveCursor(14, 7);
        terminal.putString("Server URL:");
        
        // URL input field
        terminal.moveCursor(15, 8);
        terminal.putString(self.url_input.getValue());
        
        // Connect button hint
        terminal.moveCursor(28, 10);
        terminal.putString("[ Press Enter to Connect ]");
        
        // Status line
        const status_text = switch (self.state.connection_state) {
            .disconnected => "Enter server URL to connect",
            .connecting => "Connecting...",
            .connected => "Connected to Spiderweb",
            .err => if (self.state.connection_error) |err| err else "Connection error",
        };
        terminal.moveCursor(25, 13);
        terminal.putString(status_text);
        
        // Help text
        terminal.moveCursor(32, 22);
        terminal.putString("Press Ctrl+C to quit");
    }
};

const MockChatScreen = struct {
    messages: std.ArrayList(Message),
    message_input: MockInputField,
    connected: bool = false,
    
    const Message = struct {
        sender: []const u8,
        content: []const u8,
        is_user: bool,
    };
    
    const MockInputField = struct {
        value: []const u8 = "",
        placeholder: []const u8 = "Type a message...",
        
        pub fn getValue(self: *MockInputField) []const u8 {
            return self.value;
        }
        
        pub fn clear(self: *MockInputField) void {
            self.value = "";
        }
        
        pub fn setValue(self: *MockInputField, val: []const u8) void {
            self.value = val;
        }
    };
    
    pub fn init(allocator: std.mem.Allocator) MockChatScreen {
        return .{
            .messages = std.ArrayList(Message).init(allocator),
            .message_input = .{},
        };
    }
    
    pub fn deinit(self: *MockChatScreen) void {
        self.messages.deinit();
    }
    
    pub fn addMessage(self: *MockChatScreen, sender: []const u8, content: []const u8, is_user: bool) !void {
        try self.messages.append(.{
            .sender = sender,
            .content = content,
            .is_user = is_user,
        });
    }
    
    pub fn render(self: *MockChatScreen, terminal: anytype) void {
        // Header
        terminal.moveCursor(2, 0);
        terminal.putString("ZiggyStarSpider - Chat");
        
        // Status
        const status = if (self.connected) "● Connected" else "● Disconnected";
        terminal.moveCursor(68, 0);
        terminal.putString(status);
        
        // Separator
        terminal.moveCursor(0, 1);
        for (0..80) |_| terminal.putString("─");
        
        // Messages
        var y: u16 = 2;
        for (self.messages.items) |msg| {
            terminal.moveCursor(2, y);
            terminal.putString(msg.sender);
            terminal.putString(": ");
            terminal.putString(msg.content);
            y += 1;
        }
        
        // Input area
        terminal.moveCursor(0, 20);
        for (0..80) |_| terminal.putString("─");
        terminal.moveCursor(2, 21);
        terminal.putString("> ");
        terminal.putString(self.message_input.getValue());
        
        // Help
        terminal.moveCursor(2, 23);
        terminal.putString("Enter: Send | Ctrl+D: Disconnect | Ctrl+C: Quit");
    }
};

// ============================================================================
// Test Cases
// ============================================================================

test "Connection screen renders correctly" {
    const allocator = std.testing.allocator;
    
    var harness = try TestHarness.init(allocator, 80, 24);
    defer harness.deinit();
    
    var connect_screen = MockConnectScreen.init();
    connect_screen.render(harness.getTerminal());
    
    // Verify title is displayed
    try harness.expectText("ZiggyStarSpider TUI");
    
    // Verify subtitle
    try harness.expectText("Connect to Spiderweb Server");
    
    // Verify URL label
    try harness.expectText("Server URL:");
    
    // Verify connect button hint
    try harness.expectText("[ Press Enter to Connect ]");
    
    // Verify help text
    try harness.expectText("Press Ctrl+C to quit");
}

test "Connection screen shows default URL" {
    const allocator = std.testing.allocator;
    
    var harness = try TestHarness.init(allocator, 80, 24);
    defer harness.deinit();
    
    var connect_screen = MockConnectScreen.init();
    connect_screen.url_input.setValue("ws://127.0.0.1:18790");
    connect_screen.render(harness.getTerminal());
    
    // Verify default URL is shown
    try harness.expectText("ws://127.0.0.1:18790");
}

test "Connection screen shows connecting status" {
    const allocator = std.testing.allocator;
    
    var harness = try TestHarness.init(allocator, 80, 24);
    defer harness.deinit();
    
    var connect_screen = MockConnectScreen.init();
    connect_screen.state.connection_state = .connecting;
    connect_screen.render(harness.getTerminal());
    
    // Verify connecting status is shown
    try harness.expectText("Connecting...");
}

test "Connection screen shows error status" {
    const allocator = std.testing.allocator;
    
    var harness = try TestHarness.init(allocator, 80, 24);
    defer harness.deinit();
    
    var connect_screen = MockConnectScreen.init();
    connect_screen.state.connection_state = .err;
    connect_screen.state.connection_error = "Connection refused";
    connect_screen.render(harness.getTerminal());
    
    // Verify error is shown
    try harness.expectText("Connection refused");
}

test "URL input handling - typing URL" {
    const allocator = std.testing.allocator;
    
    var harness = try TestHarness.init(allocator, 80, 24);
    defer harness.deinit();
    
    var connect_screen = MockConnectScreen.init();
    
    // Simulate typing a URL
    const test_url = "ws://example.com:8080";
    connect_screen.url_input.setValue(test_url);
    connect_screen.render(harness.getTerminal());
    
    // Verify URL appears on screen
    try harness.expectText(test_url);
}

test "URL input handling - clear and retype" {
    const allocator = std.testing.allocator;
    
    var harness = try TestHarness.init(allocator, 80, 24);
    defer harness.deinit();
    
    var connect_screen = MockConnectScreen.init();
    
    // Set initial URL
    connect_screen.url_input.setValue("ws://old-server:1234");
    connect_screen.render(harness.getTerminal());
    try harness.expectText("ws://old-server:1234");
    
    // Clear terminal and URL
    harness.getTerminal().clear();
    connect_screen.url_input.clear();
    
    // Type new URL
    const new_url = "ws://new-server:5678";
    connect_screen.url_input.setValue(new_url);
    connect_screen.render(harness.getTerminal());
    
    // Verify old URL is gone
    try harness.expectNoText("ws://old-server:1234");
    
    // Verify new URL is shown
    try harness.expectText(new_url);
}

test "Chat screen renders header" {
    const allocator = std.testing.allocator;
    
    var harness = try TestHarness.init(allocator, 80, 24);
    defer harness.deinit();
    
    var chat_screen = MockChatScreen.init(allocator);
    defer chat_screen.deinit();
    
    chat_screen.render(harness.getTerminal());
    
    // Verify header
    try harness.expectText("ZiggyStarSpider - Chat");
    
    // Verify status
    try harness.expectText("● Disconnected");
}

test "Chat screen shows connected status" {
    const allocator = std.testing.allocator;
    
    var harness = try TestHarness.init(allocator, 80, 24);
    defer harness.deinit();
    
    var chat_screen = MockChatScreen.init(allocator);
    defer chat_screen.deinit();
    
    chat_screen.connected = true;
    chat_screen.render(harness.getTerminal());
    
    // Verify connected status
    try harness.expectText("● Connected");
}

test "Chat screen displays messages" {
    const allocator = std.testing.allocator;
    
    var harness = try TestHarness.init(allocator, 80, 24);
    defer harness.deinit();
    
    var chat_screen = MockChatScreen.init(allocator);
    defer chat_screen.deinit();
    
    // Add some messages
    try chat_screen.addMessage("You", "Hello, AI!", true);
    try chat_screen.addMessage("AI", "Hello! How can I help you?", false);
    
    chat_screen.render(harness.getTerminal());
    
    // Verify messages are displayed
    try harness.expectText("You: Hello, AI!");
    try harness.expectText("AI: Hello! How can I help you?");
}

test "Chat screen shows input prompt" {
    const allocator = std.testing.allocator;
    
    var harness = try TestHarness.init(allocator, 80, 24);
    defer harness.deinit();
    
    var chat_screen = MockChatScreen.init(allocator);
    defer chat_screen.deinit();
    
    chat_screen.render(harness.getTerminal());
    
    // Verify input prompt
    try harness.expectText("> ");
    
    // Verify help text
    try harness.expectText("Enter: Send | Ctrl+D: Disconnect | Ctrl+C: Quit");
}

test "Chat screen shows typed message" {
    const allocator = std.testing.allocator;
    
    var harness = try TestHarness.init(allocator, 80, 24);
    defer harness.deinit();
    
    var chat_screen = MockChatScreen.init(allocator);
    defer chat_screen.deinit();
    
    // Type a message
    chat_screen.message_input.setValue("This is my message");
    chat_screen.render(harness.getTerminal());
    
    // Verify message appears in input area
    try harness.expectText("> This is my message");
}

test "Event injection - type URL and connect" {
    const allocator = std.testing.allocator;
    
    var harness = try TestHarness.init(allocator, 80, 24);
    defer harness.deinit();
    
    // Set up event sequence: type URL and press Enter
    try EventSequences.connect(harness.getInjector(), "ws://test.com:9000");
    
    // Verify events were added
    try std.testing.expect(harness.getInjector().hasMoreEvents());
    try std.testing.expectEqual(@as(usize, 22), harness.getInjector().remainingCount()); // 20 chars + Enter
}

test "Event injection - send chat message" {
    const allocator = std.testing.allocator;
    
    var harness = try TestHarness.init(allocator, 80, 24);
    defer harness.deinit();
    
    // Set up event sequence: type message and send
    try EventSequences.sendMessage(harness.getInjector(), "Hello, world!");
    
    // Verify events were added
    try std.testing.expect(harness.getInjector().hasMoreEvents());
    try std.testing.expectEqual(@as(usize, 14), harness.getInjector().remainingCount()); // 13 chars + Enter
}

test "Event injection - disconnect" {
    const allocator = std.testing.allocator;
    
    var harness = try TestHarness.init(allocator, 80, 24);
    defer harness.deinit();
    
    // Set up disconnect event
    try EventSequences.disconnect(harness.getInjector());
    
    // Verify event was added
    try std.testing.expect(harness.getInjector().hasMoreEvents());
    try std.testing.expectEqual(@as(usize, 1), harness.getInjector().remainingCount());
}

test "Event injection - quit" {
    const allocator = std.testing.allocator;
    
    var harness = try TestHarness.init(allocator, 80, 24);
    defer harness.deinit();
    
    // Set up quit event
    try EventSequences.quit(harness.getInjector());
    
    // Verify event was added
    try std.testing.expect(harness.getInjector().hasMoreEvents());
    try std.testing.expectEqual(@as(usize, 1), harness.getInjector().remainingCount());
}

test "Virtual terminal tracks cleared state" {
    const allocator = std.testing.allocator;
    
    var harness = try TestHarness.init(allocator, 80, 24);
    defer harness.deinit();
    
    // Initially not cleared
    try std.testing.expect(!harness.getTerminal().cleared);
    
    // Clear the terminal
    harness.getTerminal().clear();
    
    // Now it should be cleared
    try std.testing.expect(harness.getTerminal().cleared);
}

test "Virtual terminal text search" {
    const allocator = std.testing.allocator;
    
    var harness = try TestHarness.init(allocator, 80, 24);
    defer harness.deinit();
    
    // Render some content
    var connect_screen = MockConnectScreen.init();
    connect_screen.render(harness.getTerminal());
    
    // Search for text
    const pos = harness.getTerminal().findText("ZiggyStarSpider");
    try std.testing.expect(pos != null);
    try std.testing.expectEqual(@as(u16, 30), pos.?.x);
    try std.testing.expectEqual(@as(u16, 2), pos.?.y);
}

test "Screen buffer snapshot" {
    const allocator = std.testing.allocator;
    
    var harness = try TestHarness.init(allocator, 80, 24);
    defer harness.deinit();
    
    // Render initial content
    var connect_screen = MockConnectScreen.init();
    connect_screen.render(harness.getTerminal());
    
    // Take snapshot
    try harness.snapshot("initial");
    
    // Change content
    connect_screen.state.connection_state = .connected;
    harness.getTerminal().clear();
    connect_screen.render(harness.getTerminal());
    
    // Compare with snapshot - should be different
    const matches = try harness.getScreen().compareWithSnapshot("initial");
    try std.testing.expect(!matches);
}

test "Screen assertions - row content" {
    const allocator = std.testing.allocator;
    
    var harness = try TestHarness.init(allocator, 80, 24);
    defer harness.deinit();
    
    // Render content
    var connect_screen = MockConnectScreen.init();
    connect_screen.render(harness.getTerminal());
    
    // Check specific row
    const assertions = @import("screen_buffer.zig").ScreenAssertions.init(harness.getScreen());
    try assertions.rowContains(2, "ZiggyStarSpider TUI");
}

test "Multiple messages in chat" {
    const allocator = std.testing.allocator;
    
    var harness = try TestHarness.init(allocator, 80, 24);
    defer harness.deinit();
    
    var chat_screen = MockChatScreen.init(allocator);
    defer chat_screen.deinit();
    
    // Add multiple messages
    try chat_screen.addMessage("You", "Message 1", true);
    try chat_screen.addMessage("AI", "Response 1", false);
    try chat_screen.addMessage("You", "Message 2", true);
    try chat_screen.addMessage("AI", "Response 2", false);
    
    chat_screen.render(harness.getTerminal());
    
    // Verify all messages appear
    try harness.expectText("You: Message 1");
    try harness.expectText("AI: Response 1");
    try harness.expectText("You: Message 2");
    try harness.expectText("AI: Response 2");
}

test "Error handling - connection refused" {
    const allocator = std.testing.allocator;
    
    var harness = try TestHarness.init(allocator, 80, 24);
    defer harness.deinit();
    
    var connect_screen = MockConnectScreen.init();
    connect_screen.state.connection_state = .err;
    connect_screen.state.connection_error = "ConnectionRefused";
    connect_screen.render(harness.getTerminal());
    
    // Verify error is displayed
    try harness.expectText("ConnectionRefused");
}

test "Error handling - invalid URL" {
    const allocator = std.testing.allocator;
    
    var harness = try TestHarness.init(allocator, 80, 24);
    defer harness.deinit();
    
    var connect_screen = MockConnectScreen.init();
    connect_screen.state.connection_state = .err;
    connect_screen.state.connection_error = "InvalidUrl";
    connect_screen.render(harness.getTerminal());
    
    // Verify error is displayed
    try harness.expectText("InvalidUrl");
}

test "Error handling - timeout" {
    const allocator = std.testing.allocator;
    
    var harness = try TestHarness.init(allocator, 80, 24);
    defer harness.deinit();
    
    var connect_screen = MockConnectScreen.init();
    connect_screen.state.connection_state = .err;
    connect_screen.state.connection_error = "ConnectionTimeout";
    connect_screen.render(harness.getTerminal());
    
    // Verify error is displayed
    try harness.expectText("ConnectionTimeout");
}

test "Terminal resize handling" {
    const allocator = std.testing.allocator;
    
    var harness = try TestHarness.init(allocator, 80, 24);
    defer harness.deinit();
    
    // Initial dimensions
    try harness.expectDimensions(80, 24);
    
    // Resize
    try harness.getTerminal().resize(120, 30);
    
    // New dimensions
    try harness.expectDimensions(120, 30);
}

test "Event sequence builder" {
    const allocator = std.testing.allocator;
    
    var harness = try TestHarness.init(allocator, 80, 24);
    defer harness.deinit();
    
    // Use fluent API
    _ = try harness.getInjector().sequence()
        .typeText("Hello")
        .pressEnter();
    
    // Verify events
    try std.testing.expectEqual(@as(usize, 6), harness.getInjector().remainingCount());
}
