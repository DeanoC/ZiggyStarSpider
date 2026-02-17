const std = @import("std");

// Minimal diagnostic to trace TUI library hang
// This tests each component in isolation to find the blocking call

pub fn main() !void {
    std.log.info("=== TUI Hang Diagnostic ===", .{});
    
    // Test 1: Basic stdio access
    std.log.info("[TEST 1] Testing stdout access...", .{});
    const stdout = std.fs.File{ .handle = std.posix.STDOUT_FILENO };
    _ = try stdout.write("Direct stdout write works\n");
    std.log.info("[TEST 1] PASSED - stdout accessible", .{});
    
    // Test 2: Check if stdin is a TTY
    std.log.info("[TEST 2] Checking stdin TTY status...", .{});
    const stdin = std.fs.File{ .handle = std.posix.STDIN_FILENO };
    const is_tty = std.posix.isatty(stdin.handle);
    std.log.info("[TEST 2] stdin is TTY: {}", .{is_tty});
    
    // Test 3: Check if stdout is a TTY  
    std.log.info("[TEST 3] Checking stdout TTY status...", .{});
    const is_stdout_tty = std.posix.isatty(stdout.handle);
    std.log.info("[TEST 3] stdout is TTY: {}", .{is_stdout_tty});
    
    // Test 4: Try tcgetattr (this could hang if terminal is in bad state)
    std.log.info("[TEST 4] Testing tcgetattr on stdin...", .{});
    const getattr_result = std.posix.tcgetattr(stdin.handle);
    if (getattr_result) |termios| {
        _ = termios;
        std.log.info("[TEST 4] PASSED - tcgetattr works", .{});
    } else |err| {
        std.log.info("[TEST 4] FAILED - tcgetattr error: {}", .{err});
    }
    
    // Test 5: Try tcgetattr on stdout
    std.log.info("[TEST 5] Testing tcgetattr on stdout...", .{});
    const getattr_stdout_result = std.posix.tcgetattr(stdout.handle);
    if (getattr_stdout_result) |_| {
        std.log.info("[TEST 5] PASSED - tcgetattr on stdout works", .{});
    } else |err| {
        std.log.info("[TEST 5] FAILED - tcgetattr on stdout error: {}", .{err});
    }
    
    // Test 6: Non-blocking read test using O_NONBLOCK constant
    std.log.info("[TEST 6] Testing non-blocking read from stdin...", .{});
    
    // Set non-blocking mode temporarily
    const flags = try std.posix.fcntl(stdin.handle, std.posix.F.GETFL, 0);
    const NONBLOCK = 0x800; // O_NONBLOCK on Linux
    _ = try std.posix.fcntl(stdin.handle, std.posix.F.SETFL, flags | NONBLOCK);
    
    var buf: [32]u8 = undefined;
    const read_result = std.posix.read(stdin.handle, &buf);
    if (read_result) |n| {
        std.log.info("[TEST 6] Read {d} bytes (expected 0 for non-blocking)", .{n});
    } else |err| {
        if (err == error.WouldBlock) {
            std.log.info("[TEST 6] PASSED - WouldBlock as expected", .{});
        } else {
            std.log.info("[TEST 6] Read error: {}", .{err});
        }
    }
    
    // Restore blocking mode
    _ = try std.posix.fcntl(stdin.handle, std.posix.F.SETFL, flags);
    
    // Test 7: ioctl for terminal size
    std.log.info("[TEST 7] Testing ioctl TIOCGWINSZ...", .{});
    var wsz: std.posix.winsize = .{
        .col = 0,
        .row = 0,
        .xpixel = 0,
        .ypixel = 0,
    };
    const ioctl_result = std.posix.system.ioctl(stdout.handle, std.posix.T.IOCGWINSZ, @intFromPtr(&wsz));
    if (ioctl_result == 0) {
        std.log.info("[TEST 7] PASSED - Terminal size: {d}x{d}", .{wsz.col, wsz.row});
    } else {
        std.log.info("[TEST 7] FAILED - ioctl error: {d}", .{ioctl_result});
    }
    
    // Test 8: Poll test
    std.log.info("[TEST 8] Testing poll on stdin...", .{});
    var pollfd: [1]std.posix.pollfd = .{.{
        .fd = stdin.handle,
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};
    const poll_result = std.posix.poll(&pollfd, 100); // 100ms timeout
    if (poll_result) |n| {
        std.log.info("[TEST 8] PASSED - Poll returned: {d} (0=timeout, 1=data available)", .{n});
    } else |err| {
        std.log.info("[TEST 8] FAILED - Poll error: {}", .{err});
    }
    
    std.log.info("=== Diagnostic Complete ===", .{});
}
