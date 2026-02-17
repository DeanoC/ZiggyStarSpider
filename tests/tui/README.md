# TUI Testing Framework for ZiggyStarSpider

A headless testing framework for programmatically testing the ZiggyStarSpider TUI application.

## Overview

This testing framework allows you to:
- Run TUI tests without an actual terminal (headless)
- Simulate user input (keyboard, mouse)
- Capture and inspect screen output
- Verify expected behavior with assertions
- Test both the Connect and Chat screens

## Quick Start

### Run all TUI tests

```bash
zig build test-tui
```

### Build the test executable

```bash
zig build build-tui-test
./zig-out/bin/zss-tui-test
```

## Architecture

The testing framework consists of several components:

### 1. Virtual Terminal (`virtual_terminal.zig`)

Simulates a terminal environment in memory:
- 80x24 (or custom size) character buffer
- Cursor tracking and movement
- Text styling (colors, attributes)
- Screen clearing and resizing

```zig
var vt = try VirtualTerminal.init(allocator, 80, 24);
defer vt.deinit();

vt.moveCursor(10, 5);
vt.putString("Hello, World!");
```

### 2. Screen Buffer (`screen_buffer.zig`)

Captures and analyzes TUI output:
- Take snapshots of screen state
- Search for text on screen
- Make assertions about content

```zig
var screen = try ScreenBuffer.init(allocator, 80, 24);
defer screen.deinit();

try screen.expectText("Expected text");
try screen.expectPattern("partial.*match");
```

### 3. Event Injector (`event_injector.zig`)

Simulates user input:
- Key presses (characters, special keys)
- Keyboard combinations (Ctrl+C, Ctrl+D)
- Mouse events
- Resize events

```zig
var injector = EventInjector.init(allocator);
defer injector.deinit();

try injector.addString("ws://localhost:8080");
try injector.addEnter();
try injector.addCtrlC();
```

### 4. Mock TUI (`mock_tui.zig`)

Mock implementations of TUI library interfaces:
- `MockTui.App` - Application runner
- `MockTui.RenderContext` - Rendering context
- `MockTui.InputField` - Text input widget
- `MockTui.Event` - Input events

### 5. Test Harness (`test_harness.zig`)

High-level orchestration:
- Combines all components
- Provides fluent test API
- Tracks test results

```zig
var harness = try TestHarness.init(allocator, 80, 24);
defer harness.deinit();

try harness.expectText("ZiggyStarSpider TUI");
try harness.snapshot("initial_state");
```

## Test Cases

The framework includes comprehensive tests in `test_cases.zig`:

### Connection Screen Tests
- `Connection screen renders correctly` - Verifies UI elements
- `Connection screen shows default URL` - Default value display
- `Connection screen shows connecting status` - Status updates
- `Connection screen shows error status` - Error display

### URL Input Tests
- `URL input handling - typing URL` - Text entry
- `URL input handling - clear and retype` - Input modification

### Chat Screen Tests
- `Chat screen renders header` - Header display
- `Chat screen shows connected status` - Connection indicator
- `Chat screen displays messages` - Message rendering
- `Chat screen shows input prompt` - Input area
- `Chat screen shows typed message` - Typing feedback

### Event Injection Tests
- `Event injection - type URL and connect` - Input sequence
- `Event injection - send chat message` - Message sending
- `Event injection - disconnect` - Disconnect shortcut
- `Event injection - quit` - Quit shortcut

### Error Handling Tests
- `Error handling - connection refused` - Connection errors
- `Error handling - invalid URL` - URL validation
- `Error handling - timeout` - Timeout errors

### Screen Capture Tests
- `Virtual terminal tracks cleared state` - Clear detection
- `Virtual terminal text search` - Text finding
- `Screen buffer snapshot` - Snapshot comparison
- `Screen assertions - row content` - Row verification

## Writing New Tests

### Basic Test Structure

```zig
test "My new test" {
    const allocator = std.testing.allocator;
    
    // Initialize harness
    var harness = try TestHarness.init(allocator, 80, 24);
    defer harness.deinit();
    
    // Set up initial state
    var my_screen = MyScreen.init();
    my_screen.render(harness.getTerminal());
    
    // Make assertions
    try harness.expectText("Expected content");
    try harness.expectNoText("Should not appear");
}
```

### Testing with Events

```zig
test "User interaction test" {
    const allocator = std.testing.allocator;
    
    var harness = try TestHarness.init(allocator, 80, 24);
    defer harness.deinit();
    
    // Queue events
    try harness.getInjector().addString("ws://test.com");
    try harness.getInjector().addEnter();
    
    // Process events
    try harness.run();
    
    // Verify result
    try harness.expectText("Connecting...");
}
```

### Using the Fluent API

```zig
test "Fluent API test" {
    const allocator = std.testing.allocator;
    
    var harness = try TestHarness.init(allocator, 80, 24);
    defer harness.deinit();
    
    _ = try harness.getInjector().sequence()
        .typeText("Hello")
        .pressEnter()
        .pressCtrlC();
    
    try harness.run();
}
```

## Integration with Real TUI Code

To test the actual TUI screens (not mocks), you need to:

1. **Create a test wrapper** that injects the mock TUI:

```zig
// In your test file
const real_app = @import("../../src/tui/app.zig");
const MockTui = @import("mock_tui.zig").MockTui;

// Create a version of App that uses MockTui instead of real tui
const TestApp = struct {
    // Copy of App but with MockTui types
};
```

2. **Use conditional compilation**:

```zig
const tui = if (@import("builtin").is_test)
    @import("tests/tui/mock_tui.zig").MockTui
else
    @import("tui");
```

3. **Run tests headlessly** - The mock TUI never touches real terminal

## Debugging Tests

### Print Screen Content

```zig
harness.debugPrint();
```

Output:
```
Terminal (80x24):
Cursor: (10, 5)
+--------------------------------------------------------------------------------+
|ZiggyStarSpider TUI                                                             |
|                                                                                |
|                    Connect to Spiderweb Server                                  |
...
```

### Get Screen Content as String

```zig
const content = try harness.getScreen().getContent();
defer allocator.free(content);
std.debug.print("Content:\n{s}\n", .{content});
```

### Take Snapshots

```zig
try harness.snapshot("before");
// ... perform action
try harness.snapshot("after");

// Compare
const matches = try harness.getScreen().compareWithSnapshot("before");
```

## Known Issues and TUI Problems

The current TUI implementation has these issues that this framework helps identify:

1. **Screen clearing on exit** - The TUI clears the screen before exiting, making it hard to see what happened
   - **Test approach**: Capture screen before exit, verify content

2. **Never exits** - The TUI may hang waiting for input
   - **Test approach**: Use event injector with limited events, verify clean exit

3. **No way to verify output** - Without the framework, you can't see what was rendered
   - **Test approach**: Virtual terminal captures all output

## Future Enhancements

Potential improvements to the framework:

1. **Screenshot comparison** - Compare rendered output against reference images
2. **Performance testing** - Measure render times, memory usage
3. **Fuzzing** - Random input testing
4. **Recording/playback** - Record user sessions, replay as tests
5. **Coverage reporting** - Track which UI code paths are tested

## File Structure

```
tests/tui/
├── README.md              # This file
├── main.zig               # Test runner entry point
├── tui_test.zig           # Main module exports
├── virtual_terminal.zig   # Terminal simulation
├── screen_buffer.zig      # Screen capture and assertions
├── event_injector.zig     # Input simulation
├── mock_tui.zig           # Mock TUI library
├── test_harness.zig       # Test orchestration
└── test_cases.zig         # Actual test cases
```

## Running in CI/CD

The tests run headlessly and return proper exit codes:

```bash
#!/bin/bash
zig build test-tui
if [ $? -eq 0 ]; then
    echo "All TUI tests passed!"
else
    echo "TUI tests failed!"
    exit 1
fi
```

## License

Same as ZiggyStarSpider project.
