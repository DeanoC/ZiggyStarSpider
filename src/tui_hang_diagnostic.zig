const std = @import("std");
const builtin = @import("builtin");

// Replicate the TUI library's platform code to diagnose the hang

const TerminalSize = struct {
    cols: u16,
    rows: u16,
};

const PosixHandle = struct {
    fd: std.posix.fd_t,
    original_termios: ?std.posix.termios = null,

    pub fn init() PosixHandle {
        return .{ .fd = std.posix.STDOUT_FILENO };
    }
};

fn enablePosixRawMode(handle: *PosixHandle) !void {
    std.log.info("    [enablePosixRawMode] Calling tcgetattr...", .{});
    handle.original_termios = try std.posix.tcgetattr(handle.fd);
    std.log.info("    [enablePosixRawMode] tcgetattr succeeded", .{});
    
    var raw = handle.original_termios.?;

    // Input flags
    raw.iflag.BRKINT = false;
    raw.iflag.ICRNL = false;
    raw.iflag.INPCK = false;
    raw.iflag.ISTRIP = false;
    raw.iflag.IXON = false;

    // Output flags
    raw.oflag.OPOST = false;

    // Control flags
    raw.cflag.CSIZE = .CS8;

    // Local flags
    raw.lflag.ECHO = false;
    raw.lflag.ICANON = false;
    raw.lflag.ISIG = false;
    raw.lflag.IEXTEN = false;

    // Read with timeout
    raw.cc[@intFromEnum(std.posix.V.MIN)] = 0;
    raw.cc[@intFromEnum(std.posix.V.TIME)] = 1;

    std.log.info("    [enablePosixRawMode] Calling tcsetattr...", .{});
    try std.posix.tcsetattr(handle.fd, .FLUSH, raw);
    std.log.info("    [enablePosixRawMode] tcsetattr succeeded", .{});
}

fn getPosixTerminalSize() !TerminalSize {
    std.log.info("    [getPosixTerminalSize] Calling ioctl TIOCGWINSZ...", .{});
    var wsz: std.posix.winsize = .{
        .col = 0,
        .row = 0,
        .xpixel = 0,
        .ypixel = 0,
    };

    const result = std.posix.system.ioctl(std.posix.STDOUT_FILENO, std.posix.T.IOCGWINSZ, @intFromPtr(&wsz));
    if (result != 0) {
        std.log.info("    [getPosixTerminalSize] ioctl failed with: {d}", .{result});
        return error.IoctlFailed;
    }

    std.log.info("    [getPosixTerminalSize] ioctl succeeded: {d}x{d}", .{wsz.col, wsz.row});
    return .{
        .cols = wsz.col,
        .rows = wsz.row,
    };
}

// Simulate processInput from app.zig
fn testProcessInput() !void {
    std.log.info("  [processInput] Testing stdin read...", .{});
    
    const stdin = std.fs.File{ .handle = std.posix.STDIN_FILENO };
    var buf: [32]u8 = undefined;

    // Make stdin non-blocking temporarily
    const flags = try std.posix.fcntl(stdin.handle, std.posix.F.GETFL, 0);
    const NONBLOCK = 0x800;
    _ = try std.posix.fcntl(stdin.handle, std.posix.F.SETFL, flags | NONBLOCK);
    defer {
        _ = std.posix.fcntl(stdin.handle, std.posix.F.SETFL, flags) catch {};
    }

    std.log.info("  [processInput] Attempting read (non-blocking)...", .{});
    const bytes_read = stdin.read(&buf) catch |err| {
        if (err == error.WouldBlock) {
            std.log.info("  [processInput] Read returned WouldBlock (expected)", .{});
            return;
        }
        std.log.info("  [processInput] Read error: {}", .{err});
        return err;
    };

    std.log.info("  [processInput] Read {d} bytes", .{bytes_read});
}

pub fn main() !void {
    std.log.info("=== TUI Library Hang Diagnostic ===", .{});
    std.log.info("This replicates the exact code paths from the TUI library", .{});
    std.log.info("", .{});

    // Check TTY status first
    const is_stdin_tty = std.posix.isatty(std.posix.STDIN_FILENO);
    const is_stdout_tty = std.posix.isatty(std.posix.STDOUT_FILENO);
    std.log.info("Environment:", .{});
    std.log.info("  stdin is TTY: {}", .{is_stdin_tty});
    std.log.info("  stdout is TTY: {}", .{is_stdout_tty});
    std.log.info("", .{});

    // Test 1: TerminalHandle.init()
    std.log.info("[TEST 1] TerminalHandle.init()", .{});
    var handle = PosixHandle.init();
    std.log.info("  Result: handle.fd = {d}", .{handle.fd});
    std.log.info("[TEST 1] PASSED\n", .{});

    // Test 2: enableRawMode
    std.log.info("[TEST 2] enableRawMode() (from Terminal.setup)", .{});
    if (!is_stdout_tty) {
        std.log.info("  SKIPPED - stdout is not a TTY, enableRawMode would fail with NotATerminal", .{});
    } else {
        enablePosixRawMode(&handle) catch |err| {
            std.log.info("  FAILED with error: {}", .{err});
        };
    }
    std.log.info("[TEST 2] Complete\n", .{});

    // Test 3: getTerminalSize
    std.log.info("[TEST 3] getTerminalSize() (from App.setup)", .{});
    const size: TerminalSize = blk: {
        break :blk getPosixTerminalSize() catch |err| {
            std.log.info("  FAILED with error: {}", .{err});
            break :blk TerminalSize{ .cols = 80, .rows = 24 };
        };
    };
    std.log.info("  Terminal size: {d}x{d}", .{size.cols, size.rows});
    std.log.info("[TEST 3] Complete\n", .{});

    // Test 4: processInput (the blocking read)
    std.log.info("[TEST 4] processInput() (from runFrame)", .{});
    try testProcessInput();
    std.log.info("[TEST 4] Complete\n", .{});

    // Summary
    std.log.info("=== Summary ===", .{});
    if (!is_stdin_tty or !is_stdout_tty) {
        std.log.info("ISSUE IDENTIFIED: Not running in a TTY environment", .{});
        std.log.info("  - stdin TTY: {}", .{is_stdin_tty});
        std.log.info("  - stdout TTY: {}", .{is_stdout_tty});
        std.log.info("", .{});
        std.log.info("The TUI library requires an interactive terminal.", .{});
        std.log.info("When running in non-TTY environments (CI, pipes, etc.):", .{});
        std.log.info("  - tcgetattr/tcsetattr will fail with error.NotATerminal", .{});
        std.log.info("  - ioctl TIOCGWINSZ will fail", .{});
        std.log.info("  - The app cannot function without terminal control", .{});
    } else {
        std.log.info("Environment has TTY. If hang occurs, it's likely in:", .{});
        std.log.info("  - Blocking read in processInput()", .{});
        std.log.info("  - Some other blocking system call", .{});
    }
    
    std.log.info("", .{});
    std.log.info("=== Diagnostic Complete ===", .{});
}
