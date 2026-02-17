# Threaded Input Fix for TUI Library Hang

## Problem
The TUI library hangs because `processInput()` in `app.zig` performs a blocking `stdin.read()` call on the main thread. This blocks the entire render loop when there's no input.

## Solution
Move input handling to a separate thread. The input thread blocks on `read()`, parses input into events, and pushes them to a thread-safe queue. The main thread just drains the queue each frame without blocking.

## Files Changed
- `src/app.zig` - Modified to use threaded input

## Key Changes

### 1. Added Threading Primitives
```zig
event_mutex: std.Thread.Mutex = .{},
event_cond: std.Thread.Condition = .{},
has_event: bool = false,
input_thread: ?std.Thread = null,
```

### 2. Input Thread Context (shared state)
```zig
const InputThreadContext = struct {
    allocator: std.mem.Allocator,
    event_queue: *events.EventQueue,
    input_reader: *input.InputReader,
    state: *AppState,
    should_quit: *bool,
    mutex: *std.Thread.Mutex,
    cond: *std.Thread.Condition,
    has_event: *bool,
};
```

### 3. Input Thread Function
Runs in background, blocking on `stdin.read()`, parses input, and pushes events to the shared queue:
```zig
fn inputThreadFn(ctx: InputThreadContext) void {
    while (ctx.state.* == .running and !ctx.should_quit.*) {
        const bytes_read = stdin.read(&buf) catch |err| {
            // Handle errors, continue
        };
        
        if (ctx.input_reader.parse(buf[0..bytes_read])) |event| {
            ctx.mutex.lock();
            ctx.event_queue.push(event) catch {};
            ctx.has_event.* = true;
            ctx.cond.signal();
            ctx.mutex.unlock();
        }
    }
}
```

### 4. Modified `runFrame()`
Removed the blocking `processInput()` call. Events are now just drained from the queue:
```zig
fn runFrame(self: *App) !void {
    // Process events (non-blocking, just drain the queue)
    self.processEvents();
    
    // Render, update FPS, etc.
    // ...
}
```

### 5. Modified `processEvents()`
Now drains the queue with proper locking:
```zig
fn processEvents(self: *App) void {
    while (true) {
        self.event_mutex.lock();
        const event = self.event_queue.pop();
        self.event_mutex.unlock();
        
        const evt = event orelse break;
        // Handle event...
    }
}
```

### 6. Modified `deinit()`
Properly shuts down the input thread:
```zig
pub fn deinit(self: *App) void {
    // Signal input thread to stop
    self.should_quit = true;
    
    // Wait for input thread to finish
    if (self.input_thread) |thread| {
        thread.join();
        self.input_thread = null;
    }
    // ... rest of cleanup
}
```

## How to Apply

### Option 1: Replace the file directly
```bash
cd /root/.cache/zig/p/tui-0.0.1-TMwxp-tWBgBwZqdkgqHn4c_YDJSUQhha2-OKOFBGYig3/
cp src/app.zig src/app.zig.bak
cp /root/.openclaw/workspace/ZiggyStarSpider/patches/app_threaded_input.zig src/app.zig
```

### Option 2: Use as a local override
Copy the patched file to your project's `src/` and modify the import path in your TUI module.

### Option 3: Fork the TUI library
Apply the patch to a fork of `tui.zig` and update your `build.zig.zon` to use your fork.

## Testing

Build and run the TUI:
```bash
cd /root/.openclaw/workspace/ZiggyStarSpider
zig build run-tui
```

The app should now start without hanging, and the render loop should run at the target FPS regardless of input activity.

## Trade-offs

**Pros:**
- Main thread never blocks on input
- Render loop runs at consistent FPS
- Better responsiveness for animations
- Can handle input buffering more easily

**Cons:**
- Additional thread overhead (minimal)
- Need for thread synchronization (mutex/condition)
- Slightly more complex shutdown sequence

## Alternative: Non-blocking with poll()

If you prefer not to use threads, an alternative is to use `poll()` before reading:

```zig
fn processInput(self: *App) !void {
    var pollfd: [1]std.posix.pollfd = .{.{ 
        .fd = stdin.handle, 
        .events = std.posix.POLL.IN, 
        .revents = 0 
    }};
    
    const ready = std.posix.poll(&pollfd, self.config.poll_timeout_ms) catch return;
    if (ready == 0) return; // No data available
    
    const bytes_read = stdin.read(&buf) catch 0;
    // ...
}
```

This is simpler but still has edge cases with partial reads and escape sequence timing.
