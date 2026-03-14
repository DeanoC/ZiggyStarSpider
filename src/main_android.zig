const std = @import("std");
const gui = @import("gui/root.zig");
const storage = @import("platform_storage");

const c = @cImport({
    @cInclude("SDL3/SDL.h");
    @cInclude("android/log.h");
});

pub const std_options: std.Options = .{
    .logFn = androidLogFn,
};

const android_log_tag: [*:0]const u8 = "SpiderApp";

pub const panic = struct {
    fn callImpl(msg: []const u8, ra: ?usize) noreturn {
        _ = c.__android_log_print(
            c.ANDROID_LOG_ERROR,
            android_log_tag,
            "panic: %.*s ra=0x%zx",
            @as(c_int, @intCast(msg.len)),
            msg.ptr,
            if (ra) |value| value else @as(usize, 0),
        );
        @trap();
    }

    pub fn call(msg: []const u8, ra: ?usize) noreturn {
        callImpl(msg, ra);
    }

    pub fn sentinelMismatch(expected: anytype, found: @TypeOf(expected)) noreturn {
        _ = found;
        callImpl("sentinel mismatch", @returnAddress());
    }

    pub fn unwrapError(err: anyerror) noreturn {
        _ = &err;
        callImpl("attempt to unwrap error", @returnAddress());
    }

    pub fn outOfBounds(index: usize, len: usize) noreturn {
        _ = index;
        _ = len;
        callImpl("index out of bounds", @returnAddress());
    }

    pub fn startGreaterThanEnd(start: usize, end: usize) noreturn {
        _ = start;
        _ = end;
        callImpl("start index is larger than end index", @returnAddress());
    }

    pub fn inactiveUnionField(active: anytype, accessed: @TypeOf(active)) noreturn {
        _ = accessed;
        callImpl("access of inactive union field", @returnAddress());
    }

    pub fn sliceCastLenRemainder(src_len: usize) noreturn {
        _ = src_len;
        callImpl("slice length does not divide exactly into destination elements", @returnAddress());
    }

    pub fn reachedUnreachable() noreturn {
        callImpl("reached unreachable code", @returnAddress());
    }

    pub fn unwrapNull() noreturn {
        callImpl("attempt to use null value", @returnAddress());
    }

    pub fn castToNull() noreturn {
        callImpl("cast causes pointer to be null", @returnAddress());
    }

    pub fn incorrectAlignment() noreturn {
        callImpl("incorrect alignment", @returnAddress());
    }

    pub fn invalidErrorCode() noreturn {
        callImpl("invalid error code", @returnAddress());
    }

    pub fn integerOutOfBounds() noreturn {
        callImpl("integer does not fit in destination type", @returnAddress());
    }

    pub fn integerOverflow() noreturn {
        callImpl("integer overflow", @returnAddress());
    }

    pub fn shlOverflow() noreturn {
        callImpl("left shift overflowed bits", @returnAddress());
    }

    pub fn shrOverflow() noreturn {
        callImpl("right shift overflowed bits", @returnAddress());
    }

    pub fn divideByZero() noreturn {
        callImpl("division by zero", @returnAddress());
    }

    pub fn exactDivisionRemainder() noreturn {
        callImpl("exact division produced remainder", @returnAddress());
    }

    pub fn integerPartOutOfBounds() noreturn {
        callImpl("integer part of floating point value out of bounds", @returnAddress());
    }

    pub fn corruptSwitch() noreturn {
        callImpl("switch on corrupt value", @returnAddress());
    }

    pub fn shiftRhsTooBig() noreturn {
        callImpl("shift amount is greater than the type size", @returnAddress());
    }

    pub fn invalidEnumValue() noreturn {
        callImpl("invalid enum value", @returnAddress());
    }

    pub fn forLenMismatch() noreturn {
        callImpl("for loop over objects with non-equal lengths", @returnAddress());
    }

    pub fn copyLenMismatch() noreturn {
        callImpl("source and destination have non-equal lengths", @returnAddress());
    }

    pub fn memcpyAlias() noreturn {
        callImpl("@memcpy arguments alias", @returnAddress());
    }

    pub fn noreturnReturned() noreturn {
        callImpl("'noreturn' function returned", @returnAddress());
    }
};

fn androidLogPriority(comptime level: std.log.Level) c_int {
    return switch (level) {
        .err => c.ANDROID_LOG_ERROR,
        .warn => c.ANDROID_LOG_WARN,
        .info => c.ANDROID_LOG_INFO,
        .debug => c.ANDROID_LOG_DEBUG,
    };
}

fn androidLogFn(
    comptime message_level: std.log.Level,
    comptime scope: @TypeOf(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    var buffer: [1024]u8 = undefined;
    const scope_prefix = if (scope == .default) "" else @tagName(scope) ++ ": ";
    const message = std.fmt.bufPrint(&buffer, scope_prefix ++ format, args) catch blk: {
        const fallback = std.fmt.bufPrint(&buffer, scope_prefix ++ "log formatting failed", .{}) catch return;
        break :blk fallback;
    };

    _ = c.__android_log_print(
        androidLogPriority(message_level),
        android_log_tag,
        "%.*s",
        @as(c_int, @intCast(message.len)),
        message.ptr,
    );
}

fn setCwdToPrefPath() void {
    const pref_path_c = c.SDL_GetPrefPath(storage.android_pref_org, storage.android_pref_app);
    if (pref_path_c == null) return;
    defer c.SDL_free(pref_path_c);

    const pref_path = std.mem.span(@as([*:0]const u8, @ptrCast(pref_path_c.?)));
    std.posix.chdir(pref_path) catch {};
}

pub fn main() !void {
    setCwdToPrefPath();
    try gui.main();
}

pub export fn SDL_main(argc: c_int, argv: [*c][*c]u8) c_int {
    _ = argc;
    _ = argv;
    setCwdToPrefPath();
    gui.main() catch {
        return 1;
    };
    return 0;
}
