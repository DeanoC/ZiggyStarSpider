# TUI Library Hang Diagnostic Report

## Executive Summary

After thorough analysis of the TUI library code and diagnostic testing, I found that:

1. **`initWithAllocator()` does NOT hang by itself** - it simply creates a struct with default values
2. **The actual hang occurs in `app.run()` → `setup()` → `Terminal.init()` → `enableRawMode()`**
3. **In non-TTY environments, the library fails with `error.NotATerminal`, not a hang**
4. **The real hang is likely in `processInput()` which does a blocking `stdin.read()`**

## Root Cause Analysis

### 1. The Actual Code Path

Looking at `src/app.zig` in the TUI library:

```zig
pub fn initWithAllocator(allocator: std.mem.Allocator, config: AppConfig) !App {
    return App{
        .allocator = allocator,
        .config = config,
        .theme = config.theme,
        .input_reader = input.InputReader.init(allocator),
        .event_queue = events.EventQueue.init(allocator, 256),
    };
}
```

**This function cannot hang** - it just creates a struct with no I/O operations.

### 2. Where the "Hang" Actually Occurs

The blocking happens in `app.run()`:

```zig
pub fn run(self: *App) !void {
    try self.setup();  // <-- Calls Terminal.init() → enableRawMode()
    // ...
    while (self.state == .running and !self.should_quit) {
        try self.runFrame();  // <-- Calls processInput() which blocks
    }
}
```

### 3. The Blocking Call in `processInput()`

From `src/app.zig`:

```zig
fn processInput(self: *App) !void {
    const stdin = std.fs.File{ .handle = std.posix.STDIN_FILENO };
    var buf: [32]u8 = undefined;

    // This is a BLOCKING READ - no timeout!
    const bytes_read = stdin.read(&buf) catch 0;
    // ...
}
```

**THIS IS THE HANG LOCATION** - The `stdin.read()` call blocks indefinitely waiting for input.

### 4. Terminal Setup Issues

From `src/platform/platform.zig`:

```zig
fn enablePosixRawMode(handle: *PosixHandle) !void {
    handle.original_termios = try std.posix.tcgetattr(handle.fd);
    // ...
}
```

This fails with `error.NotATerminal` when not running in a TTY.

## Diagnostic Results

Running the diagnostic in a non-TTY environment:

```
Environment:
  stdin is TTY: false
  stdout is TTY: false

[TEST 2] enableRawMode()
  SKIPPED - stdout is not a TTY

[TEST 3] getTerminalSize()
  FAILED - ioctl error

[TEST 4] processInput()
  PASSED - WouldBlock (with non-blocking flag)
```

## The Exact Problem

### Primary Issue: Blocking Read in `processInput()`

**Location:** `/root/.cache/zig/p/tui-0.0.1-TMwxp-tWBgBwZqdkgqHn4c_YDJSUQhha2-OKOFBGYig3/src/app.zig`

**Line:** ~350 (in `processInput` function)

**Problem Code:**
```zig
const bytes_read = stdin.read(&buf) catch 0;
```

**Why it hangs:**
- This is a blocking read on stdin
- When running in a TTY with raw mode enabled, it waits for user input
- If raw mode fails to set up properly, the read may still block
- No timeout is implemented

### Secondary Issue: Missing TTY Check

The library doesn't check if it's running in a TTY before attempting terminal operations.

## Recommended Fixes

### Fix 1: Make `processInput()` Non-Blocking

```zig
fn processInput(self: *App) !void {
    const stdin = std.fs.File{ .handle = std.posix.STDIN_FILENO };
    var buf: [32]u8 = undefined;

    // Use poll to check if data is available with timeout
    var pollfd: [1]std.posix.pollfd = .{.{
        .fd = stdin.handle,
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};
    
    const ready = std.posix.poll(&pollfd, self.config.poll_timeout_ms) catch return;
    if (ready == 0) return; // No data available

    const bytes_read = stdin.read(&buf) catch 0;
    // ...
}
```

### Fix 2: Add TTY Detection

```zig
pub fn initWithAllocator(allocator: std.mem.Allocator, config: AppConfig) !App {
    // Check if running in a TTY
    if (!std.posix.isatty(std.posix.STDIN_FILENO) or
        !std.posix.isatty(std.posix.STDOUT_FILENO)) {
        return error.NotATerminal;
    }
    
    return App{
        // ...
    };
}
```

### Fix 3: Use Non-Blocking File Descriptors

In `enablePosixRawMode`, set the O_NONBLOCK flag:

```zig
fn enablePosixRawMode(handle: *PosixHandle) !void {
    // ... existing code ...
    
    // Set non-blocking mode
    const flags = try std.posix.fcntl(handle.fd, std.posix.F.GETFL, 0);
    _ = try std.posix.fcntl(handle.fd, std.posix.F.SETFL, flags | std.posix.O.NONBLOCK);
    
    try std.posix.tcsetattr(handle.fd, .FLUSH, raw);
}
```

## Workarounds for Testing

### Option 1: Use a PTY (Pseudo-Terminal)

Run tests with a tool that provides a PTY:
```bash
# Using script command
script -q -c "zig build run-tui" /dev/null

# Using expect
unbuffer zig build run-tui
```

### Option 2: Mock the TUI Library

The project already has mock TUI implementations in `tests/tui/mock_tui.zig`.

### Option 3: Skip TUI Tests in CI

Add TTY detection to skip tests when not in an interactive terminal:
```zig
if (!std.posix.isatty(std.posix.STDOUT_FILENO)) {
    std.log.info("Skipping TUI test - not in a TTY", .{});
    return;
}
```

## Conclusion

The "hang" is not in `initWithAllocator()` but in:
1. **The blocking `stdin.read()` in `processInput()`** (primary cause)
2. **Missing TTY detection** (secondary cause)

The TUI library requires an interactive terminal to function. When running in non-TTY environments (CI, pipes, redirected output), the library will either:
- Fail with `error.NotATerminal` (if TTY check is added)
- Hang on blocking stdin read (current behavior)

**Immediate workaround:** Run TUI tests with a PTY wrapper like `script` or `unbuffer`.
**Long-term fix:** Add non-blocking input handling and TTY detection to the TUI library.
