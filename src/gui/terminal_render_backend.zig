const std = @import("std");
const builtin = @import("builtin");

pub const Options = struct {
    max_bytes: usize = 512 * 1024,
};

const ParserState = enum {
    ground,
    esc,
    csi,
    osc,
    osc_esc,
};

const Line = struct {
    bytes: std.ArrayListUnmanaged(u8) = .{},
    styles: std.ArrayListUnmanaged(Style) = .{},

    fn deinit(self: *Line, allocator: std.mem.Allocator) void {
        self.bytes.deinit(allocator);
        self.styles.deinit(allocator);
        self.* = undefined;
    }
};

pub const Color = union(enum) {
    default,
    indexed: u8,
    rgb: [3]u8,
};

pub const Style = struct {
    fg: Color = .default,
    bg: Color = .default,
    bold: bool = false,
    dim: bool = false,
    italic: bool = false,
    underline: bool = false,
    inverse: bool = false,
    strikethrough: bool = false,

    fn reset(self: *Style) void {
        self.* = .{};
    }
};

pub const StyledLine = struct {
    bytes: []const u8,
    styles: []const Style,
};

const GhosttyResult = c_int;
const GhosttySgrParser = ?*anyopaque;
const GhosttySgrAttribute = extern struct {
    tag: c_int,
    value: extern union {
        _padding: [8]u64,
    },
};

const GhosttySgrRuntime = struct {
    lib: std.DynLib,
    parser: GhosttySgrParser = null,
    sgr_new: *const fn (?*const anyopaque, *GhosttySgrParser) callconv(.c) GhosttyResult,
    sgr_free: *const fn (GhosttySgrParser) callconv(.c) void,
    sgr_set_params: *const fn (GhosttySgrParser, ?[*]const u16, ?[*]const u8, usize) callconv(.c) GhosttyResult,
    sgr_next: *const fn (GhosttySgrParser, *GhosttySgrAttribute) callconv(.c) bool,

    fn tryInit() ?GhosttySgrRuntime {
        const candidates = switch (builtin.os.tag) {
            .linux => &[_][]const u8{ "libghostty-vt.so", "libghostty-vt.so.0" },
            .macos => &[_][]const u8{"libghostty-vt.dylib"},
            .windows => &[_][]const u8{ "ghostty-vt.dll", "libghostty-vt.dll" },
            else => &[_][]const u8{},
        };

        for (candidates) |candidate| {
            var lib = std.DynLib.open(candidate) catch continue;

            const sgr_new = lib.lookup(
                *const fn (?*const anyopaque, *GhosttySgrParser) callconv(.c) GhosttyResult,
                "ghostty_sgr_new",
            ) orelse {
                lib.close();
                continue;
            };
            const sgr_free = lib.lookup(
                *const fn (GhosttySgrParser) callconv(.c) void,
                "ghostty_sgr_free",
            ) orelse {
                lib.close();
                continue;
            };
            const sgr_set_params = lib.lookup(
                *const fn (GhosttySgrParser, ?[*]const u16, ?[*]const u8, usize) callconv(.c) GhosttyResult,
                "ghostty_sgr_set_params",
            ) orelse {
                lib.close();
                continue;
            };
            const sgr_next = lib.lookup(
                *const fn (GhosttySgrParser, *GhosttySgrAttribute) callconv(.c) bool,
                "ghostty_sgr_next",
            ) orelse {
                lib.close();
                continue;
            };

            var runtime = GhosttySgrRuntime{
                .lib = lib,
                .sgr_new = sgr_new,
                .sgr_free = sgr_free,
                .sgr_set_params = sgr_set_params,
                .sgr_next = sgr_next,
            };
            if (runtime.sgr_new(null, &runtime.parser) != 0 or runtime.parser == null) {
                runtime.lib.close();
                continue;
            }
            return runtime;
        }

        return null;
    }

    fn deinit(self: *GhosttySgrRuntime) void {
        if (self.parser) |parser| {
            self.sgr_free(parser);
            self.parser = null;
        }
        self.lib.close();
        self.* = undefined;
    }

    fn consumeSgr(self: *GhosttySgrRuntime, allocator: std.mem.Allocator, params_text: []const u8, is_private: bool) void {
        const parser = self.parser orelse return;

        const param_slice = if (is_private and params_text.len > 0) params_text[1..] else params_text;
        var params = std.ArrayListUnmanaged(u16){};
        defer params.deinit(allocator);

        if (param_slice.len > 0) {
            var token_start: usize = 0;
            var i: usize = 0;
            while (i <= param_slice.len) : (i += 1) {
                if (i == param_slice.len or param_slice[i] == ';' or param_slice[i] == ':') {
                    const token = std.mem.trim(u8, param_slice[token_start..i], " \t");
                    const parsed: u16 = if (token.len == 0)
                        0
                    else
                        (std.fmt.parseUnsigned(u16, token, 10) catch 0);
                    params.append(allocator, parsed) catch return;
                    token_start = i + 1;
                }
            }
        }

        const params_ptr: ?[*]const u16 = if (params.items.len > 0) params.items.ptr else null;
        if (self.sgr_set_params(parser, params_ptr, null, params.items.len) != 0) return;

        var attr = GhosttySgrAttribute{
            .tag = 0,
            .value = .{ ._padding = [_]u64{0} ** 8 },
        };
        while (self.sgr_next(parser, &attr)) {}
    }
};

const PlainTextBackend = struct {
    lines: std.ArrayListUnmanaged(Line) = .{},
    render_cache: std.ArrayListUnmanaged(u8) = .{},
    csi_buf: std.ArrayListUnmanaged(u8) = .{},
    parser_state: ParserState = .ground,
    cursor_row: usize = 0,
    cursor_col: usize = 0,
    saved_row: usize = 0,
    saved_col: usize = 0,
    current_style: Style = .{},
    max_bytes: usize,
    dirty: bool = true,

    fn init(options: Options) PlainTextBackend {
        return .{
            .max_bytes = if (options.max_bytes == 0) 512 * 1024 else options.max_bytes,
        };
    }

    fn deinit(self: *PlainTextBackend, allocator: std.mem.Allocator) void {
        for (self.lines.items) |*line| line.deinit(allocator);
        self.lines.deinit(allocator);
        self.render_cache.deinit(allocator);
        self.csi_buf.deinit(allocator);
        self.* = undefined;
    }

    fn clear(self: *PlainTextBackend, allocator: std.mem.Allocator) void {
        for (self.lines.items) |*line| line.deinit(allocator);
        self.lines.clearRetainingCapacity();
        self.render_cache.clearRetainingCapacity();
        self.csi_buf.clearRetainingCapacity();
        self.parser_state = .ground;
        self.cursor_row = 0;
        self.cursor_col = 0;
        self.saved_row = 0;
        self.saved_col = 0;
        self.current_style.reset();
        self.dirty = true;
    }

    fn text(self: *const PlainTextBackend) []const u8 {
        return self.render_cache.items;
    }

    fn appendBytes(
        self: *PlainTextBackend,
        allocator: std.mem.Allocator,
        chunk: []const u8,
        ghostty_runtime: ?*GhosttySgrRuntime,
    ) !void {
        for (chunk) |ch| {
            switch (self.parser_state) {
                .ground => switch (ch) {
                    0x1b => self.parser_state = .esc,
                    else => try self.handleGroundByte(allocator, ch),
                },
                .esc => switch (ch) {
                    '[' => {
                        self.csi_buf.clearRetainingCapacity();
                        self.parser_state = .csi;
                    },
                    ']' => self.parser_state = .osc,
                    '7' => {
                        self.saved_row = self.cursor_row;
                        self.saved_col = self.cursor_col;
                        self.parser_state = .ground;
                    },
                    '8' => {
                        self.cursor_row = self.saved_row;
                        self.cursor_col = self.saved_col;
                        self.parser_state = .ground;
                    },
                    else => self.parser_state = .ground,
                },
                .csi => {
                    try self.csi_buf.append(allocator, ch);
                    if (ch >= 0x40 and ch <= 0x7e) {
                        try self.handleCsi(allocator, self.csi_buf.items, ghostty_runtime);
                        self.csi_buf.clearRetainingCapacity();
                        self.parser_state = .ground;
                    }
                },
                .osc => switch (ch) {
                    0x07 => self.parser_state = .ground,
                    0x1b => self.parser_state = .osc_esc,
                    else => {},
                },
                .osc_esc => switch (ch) {
                    '\\' => self.parser_state = .ground,
                    else => self.parser_state = .osc,
                },
            }
        }

        try self.enforceMaxBytes(allocator);
        if (self.dirty) try self.rebuildRenderCache(allocator);
    }

    fn handleGroundByte(self: *PlainTextBackend, allocator: std.mem.Allocator, ch: u8) !void {
        switch (ch) {
            '\n' => {
                self.cursor_row += 1;
                self.cursor_col = 0;
                _ = try self.ensureLine(allocator, self.cursor_row);
                self.dirty = true;
            },
            '\r' => {
                self.cursor_col = 0;
            },
            0x08 => {
                if (self.cursor_col > 0) self.cursor_col -= 1;
            },
            '\t' => {
                const next_tab = ((self.cursor_col / 8) + 1) * 8;
                self.cursor_col = next_tab;
            },
            else => {
                if (ch < 0x20) return;
                var line = try self.ensureLine(allocator, self.cursor_row);
                try self.padLineToCursor(allocator, line);
                if (self.cursor_col < line.bytes.items.len) {
                    line.bytes.items[self.cursor_col] = ch;
                    line.styles.items[self.cursor_col] = self.current_style;
                } else {
                    try line.bytes.append(allocator, ch);
                    try line.styles.append(allocator, self.current_style);
                }
                self.cursor_col += 1;
                self.dirty = true;
            },
        }
    }

    fn handleCsi(
        self: *PlainTextBackend,
        allocator: std.mem.Allocator,
        seq: []const u8,
        ghostty_runtime: ?*GhosttySgrRuntime,
    ) !void {
        if (seq.len == 0) return;
        const final = seq[seq.len - 1];
        const params_text = seq[0 .. seq.len - 1];
        const is_private = params_text.len > 0 and params_text[0] == '?';

        var params_buf: [8]usize = [_]usize{0} ** 8;
        const params = self.parseCsiParams(params_text, is_private, &params_buf);

        switch (final) {
            'A' => {
                const n = self.csiParam(params, 0, 1);
                if (n >= self.cursor_row) self.cursor_row = 0 else self.cursor_row -= n;
            },
            'B' => {
                const n = self.csiParam(params, 0, 1);
                self.cursor_row += n;
                _ = try self.ensureLine(allocator, self.cursor_row);
            },
            'C' => {
                const n = self.csiParam(params, 0, 1);
                self.cursor_col += n;
            },
            'D' => {
                const n = self.csiParam(params, 0, 1);
                if (n >= self.cursor_col) self.cursor_col = 0 else self.cursor_col -= n;
            },
            'G' => {
                const col = self.csiParam(params, 0, 1);
                self.cursor_col = if (col > 0) col - 1 else 0;
            },
            'H', 'f' => {
                const row = self.csiParam(params, 0, 1);
                const col = self.csiParam(params, 1, 1);
                self.cursor_row = if (row > 0) row - 1 else 0;
                self.cursor_col = if (col > 0) col - 1 else 0;
                _ = try self.ensureLine(allocator, self.cursor_row);
            },
            'J' => {
                const mode = self.csiParam(params, 0, 0);
                switch (mode) {
                    2 => {
                        self.clear(allocator);
                        _ = try self.ensureLine(allocator, 0);
                    },
                    else => {
                        var line = try self.ensureLine(allocator, self.cursor_row);
                        if (self.cursor_col < line.bytes.items.len) {
                            line.bytes.shrinkRetainingCapacity(self.cursor_col);
                            line.styles.shrinkRetainingCapacity(self.cursor_col);
                            self.dirty = true;
                        }
                        while (self.lines.items.len > self.cursor_row + 1) {
                            var removed = self.lines.orderedRemove(self.lines.items.len - 1);
                            removed.deinit(allocator);
                            self.dirty = true;
                        }
                    },
                }
            },
            'K' => {
                var line = try self.ensureLine(allocator, self.cursor_row);
                const mode = self.csiParam(params, 0, 0);
                switch (mode) {
                    0 => {
                        if (self.cursor_col < line.bytes.items.len) {
                            line.bytes.shrinkRetainingCapacity(self.cursor_col);
                            line.styles.shrinkRetainingCapacity(self.cursor_col);
                            self.dirty = true;
                        }
                    },
                    1 => {
                        const upto = @min(self.cursor_col + 1, line.bytes.items.len);
                        @memset(line.bytes.items[0..upto], ' ');
                        @memset(line.styles.items[0..upto], self.current_style);
                        self.dirty = true;
                    },
                    2 => {
                        line.bytes.clearRetainingCapacity();
                        line.styles.clearRetainingCapacity();
                        self.dirty = true;
                    },
                    else => {},
                }
            },
            'P' => {
                const count = self.csiParam(params, 0, 1);
                var line = try self.ensureLine(allocator, self.cursor_row);
                if (self.cursor_col >= line.bytes.items.len) return;
                const remove_count = @min(count, line.bytes.items.len - self.cursor_col);
                const tail_start = self.cursor_col + remove_count;
                const tail_len = line.bytes.items.len - tail_start;
                if (tail_len > 0) {
                    std.mem.copyForwards(
                        u8,
                        line.bytes.items[self.cursor_col .. self.cursor_col + tail_len],
                        line.bytes.items[tail_start..],
                    );
                    std.mem.copyForwards(
                        Style,
                        line.styles.items[self.cursor_col .. self.cursor_col + tail_len],
                        line.styles.items[tail_start..],
                    );
                }
                line.bytes.shrinkRetainingCapacity(line.bytes.items.len - remove_count);
                line.styles.shrinkRetainingCapacity(line.styles.items.len - remove_count);
                self.dirty = true;
            },
            'X' => {
                const count = self.csiParam(params, 0, 1);
                var line = try self.ensureLine(allocator, self.cursor_row);
                if (line.bytes.items.len < self.cursor_col + count) {
                    try line.bytes.appendNTimes(
                        allocator,
                        ' ',
                        self.cursor_col + count - line.bytes.items.len,
                    );
                    try line.styles.appendNTimes(
                        allocator,
                        self.current_style,
                        self.cursor_col + count - line.styles.items.len,
                    );
                }
                @memset(line.bytes.items[self.cursor_col .. self.cursor_col + count], ' ');
                @memset(line.styles.items[self.cursor_col .. self.cursor_col + count], self.current_style);
                self.dirty = true;
            },
            'm' => {
                self.applySgrParams(params_text, is_private);
                if (ghostty_runtime) |runtime| {
                    runtime.consumeSgr(allocator, params_text, is_private);
                }
            },
            's' => {
                self.saved_row = self.cursor_row;
                self.saved_col = self.cursor_col;
            },
            'u' => {
                self.cursor_row = self.saved_row;
                self.cursor_col = self.saved_col;
                _ = try self.ensureLine(allocator, self.cursor_row);
            },
            'h', 'l' => {
                if (is_private and params.len > 0 and (params[0] == 1049 or params[0] == 47)) {
                    self.clear(allocator);
                    _ = try self.ensureLine(allocator, 0);
                }
            },
            else => {},
        }
    }

    fn parseCsiParams(
        self: *const PlainTextBackend,
        params_text: []const u8,
        is_private: bool,
        out: []usize,
    ) []const usize {
        _ = self;
        const params_slice = if (is_private and params_text.len > 0) params_text[1..] else params_text;
        if (params_slice.len == 0) return &.{};

        var count: usize = 0;
        var it = std.mem.splitScalar(u8, params_slice, ';');
        while (it.next()) |part| {
            if (count >= out.len) break;
            out[count] = std.fmt.parseUnsigned(usize, part, 10) catch 0;
            count += 1;
        }
        return out[0..count];
    }

    fn csiParam(self: *const PlainTextBackend, params: []const usize, idx: usize, default: usize) usize {
        _ = self;
        if (idx >= params.len or params[idx] == 0) return default;
        return params[idx];
    }

    fn padLineToCursor(self: *PlainTextBackend, allocator: std.mem.Allocator, line: *Line) !void {
        if (line.bytes.items.len >= self.cursor_col) return;
        const missing = self.cursor_col - line.bytes.items.len;
        try line.bytes.appendNTimes(allocator, ' ', missing);
        try line.styles.appendNTimes(allocator, self.current_style, missing);
    }

    fn sgrDefaultColorFg() Color {
        return .default;
    }

    fn sgrDefaultColorBg() Color {
        return .default;
    }

    fn applySgrParams(self: *PlainTextBackend, params_text: []const u8, is_private: bool) void {
        const params_slice = if (is_private and params_text.len > 0) params_text[1..] else params_text;
        if (params_slice.len == 0) {
            self.current_style.reset();
            return;
        }

        var values_buf: [32]usize = [_]usize{0} ** 32;
        var count: usize = 0;
        var token_start: usize = 0;
        var i: usize = 0;
        while (i <= params_slice.len) : (i += 1) {
            if (i == params_slice.len or params_slice[i] == ';' or params_slice[i] == ':') {
                if (count < values_buf.len) {
                    const token = std.mem.trim(u8, params_slice[token_start..i], " \t");
                    values_buf[count] = if (token.len == 0)
                        0
                    else
                        (std.fmt.parseUnsigned(usize, token, 10) catch 0);
                    count += 1;
                }
                token_start = i + 1;
            }
        }

        if (count == 0) {
            self.current_style.reset();
            return;
        }

        var idx: usize = 0;
        while (idx < count) {
            const code = values_buf[idx];
            switch (code) {
                0 => self.current_style.reset(),
                1 => self.current_style.bold = true,
                2 => self.current_style.dim = true,
                3 => self.current_style.italic = true,
                4 => self.current_style.underline = true,
                7 => self.current_style.inverse = true,
                9 => self.current_style.strikethrough = true,
                22 => {
                    self.current_style.bold = false;
                    self.current_style.dim = false;
                },
                23 => self.current_style.italic = false,
                24 => self.current_style.underline = false,
                27 => self.current_style.inverse = false,
                29 => self.current_style.strikethrough = false,
                30...37 => self.current_style.fg = .{ .indexed = @intCast(code - 30) },
                39 => self.current_style.fg = sgrDefaultColorFg(),
                40...47 => self.current_style.bg = .{ .indexed = @intCast(code - 40) },
                49 => self.current_style.bg = sgrDefaultColorBg(),
                90...97 => self.current_style.fg = .{ .indexed = @intCast((code - 90) + 8) },
                100...107 => self.current_style.bg = .{ .indexed = @intCast((code - 100) + 8) },
                38, 48 => {
                    const is_fg = code == 38;
                    if (idx + 1 >= count) break;
                    const color_mode = values_buf[idx + 1];
                    if (color_mode == 5) {
                        if (idx + 2 >= count) break;
                        const color_idx: u8 = @intCast(@min(values_buf[idx + 2], 255));
                        if (is_fg) {
                            self.current_style.fg = .{ .indexed = color_idx };
                        } else {
                            self.current_style.bg = .{ .indexed = color_idx };
                        }
                        idx += 2;
                    } else if (color_mode == 2) {
                        if (idx + 4 >= count) break;
                        const rgb: [3]u8 = .{
                            @intCast(@min(values_buf[idx + 2], 255)),
                            @intCast(@min(values_buf[idx + 3], 255)),
                            @intCast(@min(values_buf[idx + 4], 255)),
                        };
                        if (is_fg) {
                            self.current_style.fg = .{ .rgb = rgb };
                        } else {
                            self.current_style.bg = .{ .rgb = rgb };
                        }
                        idx += 4;
                    }
                },
                else => {},
            }
            idx += 1;
        }
    }

    fn ensureLine(self: *PlainTextBackend, allocator: std.mem.Allocator, row: usize) !*Line {
        while (self.lines.items.len <= row) {
            try self.lines.append(allocator, .{});
            self.dirty = true;
        }
        var line = &self.lines.items[row];
        if (line.styles.items.len < line.bytes.items.len) {
            try line.styles.appendNTimes(
                allocator,
                self.current_style,
                line.bytes.items.len - line.styles.items.len,
            );
        } else if (line.styles.items.len > line.bytes.items.len) {
            line.styles.shrinkRetainingCapacity(line.bytes.items.len);
        }
        return line;
    }

    fn totalTextBytes(self: *const PlainTextBackend) usize {
        var total: usize = 0;
        for (self.lines.items, 0..) |line, idx| {
            total += line.bytes.items.len;
            if (idx + 1 < self.lines.items.len) total += 1;
        }
        return total;
    }

    fn enforceMaxBytes(self: *PlainTextBackend, allocator: std.mem.Allocator) !void {
        if (self.max_bytes == 0) return;

        while (self.lines.items.len > 1 and self.totalTextBytes() > self.max_bytes) {
            var first = self.lines.orderedRemove(0);
            first.deinit(allocator);
            if (self.cursor_row > 0) self.cursor_row -= 1 else self.cursor_row = 0;
            if (self.saved_row > 0) self.saved_row -= 1 else self.saved_row = 0;
            self.dirty = true;
        }

        if (self.lines.items.len == 0) {
            _ = try self.ensureLine(allocator, 0);
            return;
        }

        while (self.totalTextBytes() > self.max_bytes) {
            var line = &self.lines.items[0];
            if (line.bytes.items.len == 0) break;
            const overflow = self.totalTextBytes() - self.max_bytes;
            const trim = @min(overflow, line.bytes.items.len);
            const remain = line.bytes.items.len - trim;
            if (remain > 0) {
                std.mem.copyForwards(u8, line.bytes.items[0..remain], line.bytes.items[trim..]);
                std.mem.copyForwards(Style, line.styles.items[0..remain], line.styles.items[trim..]);
            }
            line.bytes.shrinkRetainingCapacity(remain);
            line.styles.shrinkRetainingCapacity(remain);
            if (self.cursor_row == 0) {
                if (trim >= self.cursor_col) self.cursor_col = 0 else self.cursor_col -= trim;
            }
            self.dirty = true;
            if (self.totalTextBytes() <= self.max_bytes) break;
            if (self.lines.items.len <= 1) break;
            var first = self.lines.orderedRemove(0);
            first.deinit(allocator);
            if (self.cursor_row > 0) self.cursor_row -= 1 else self.cursor_row = 0;
            if (self.saved_row > 0) self.saved_row -= 1 else self.saved_row = 0;
        }
    }

    fn rebuildRenderCache(self: *PlainTextBackend, allocator: std.mem.Allocator) !void {
        self.render_cache.clearRetainingCapacity();
        for (self.lines.items, 0..) |line, idx| {
            try self.render_cache.appendSlice(allocator, line.bytes.items);
            if (idx + 1 < self.lines.items.len) {
                try self.render_cache.append(allocator, '\n');
            }
        }
        self.dirty = false;
    }
};

pub const Backend = struct {
    kind: Kind = .plain_text,
    plain_text: PlainTextBackend,
    ghostty_runtime: ?GhosttySgrRuntime = null,

    pub const Kind = enum {
        plain_text,
        ghostty_vt,
    };

    pub fn parseKind(value: []const u8) Kind {
        if (std.mem.eql(u8, value, "ghostty-vt")) return .ghostty_vt;
        return .plain_text;
    }

    pub fn kindName(kind: Kind) []const u8 {
        return switch (kind) {
            .plain_text => "plain",
            .ghostty_vt => "ghostty-vt",
        };
    }

    pub fn initPlain(options: Options) Backend {
        return .{
            .kind = .plain_text,
            .plain_text = PlainTextBackend.init(options),
        };
    }

    pub fn initGhosttyVt(options: Options) Backend {
        var out = Backend{
            .kind = .ghostty_vt,
            .plain_text = PlainTextBackend.init(options),
        };
        out.ghostty_runtime = GhosttySgrRuntime.tryInit();
        return out;
    }

    pub fn initForKind(kind: Kind, options: Options) Backend {
        return switch (kind) {
            .plain_text => initPlain(options),
            .ghostty_vt => initGhosttyVt(options),
        };
    }

    pub fn deinit(self: *Backend, allocator: std.mem.Allocator) void {
        if (self.ghostty_runtime) |*runtime| {
            runtime.deinit();
            self.ghostty_runtime = null;
        }
        self.plain_text.deinit(allocator);
    }

    pub fn clear(self: *Backend, allocator: std.mem.Allocator) void {
        self.plain_text.clear(allocator);
    }

    pub fn appendBytes(self: *Backend, allocator: std.mem.Allocator, chunk: []const u8) !void {
        const runtime: ?*GhosttySgrRuntime = if (self.ghostty_runtime) |*value| value else null;
        try self.plain_text.appendBytes(allocator, chunk, runtime);
    }

    pub fn text(self: *const Backend) []const u8 {
        return self.plain_text.text();
    }

    pub fn label(self: *const Backend) []const u8 {
        return switch (self.kind) {
            .plain_text => "plain_text+ansi",
            .ghostty_vt => if (self.ghostty_runtime != null)
                "ghostty-vt(dynamic)+ansi"
            else
                "ghostty-vt(unavailable,fallback)+ansi",
        };
    }

    pub fn statusDetail(self: *const Backend) ?[]const u8 {
        return switch (self.kind) {
            .plain_text => "Plain backend active",
            .ghostty_vt => if (self.ghostty_runtime != null)
                "Ghostty SGR dynamic library loaded"
            else
                "Ghostty SGR library unavailable; ANSI fallback active",
        };
    }

    pub fn lineCount(self: *const Backend) usize {
        return self.plain_text.lines.items.len;
    }

    pub fn lineAt(self: *const Backend, idx: usize) ?StyledLine {
        if (idx >= self.plain_text.lines.items.len) return null;
        const line = self.plain_text.lines.items[idx];
        const style_len = @min(line.styles.items.len, line.bytes.items.len);
        return .{
            .bytes = line.bytes.items[0..style_len],
            .styles = line.styles.items[0..style_len],
        };
    }
};

test "terminal backend: carriage return overwrite with clear sequence" {
    const allocator = std.testing.allocator;
    var backend = Backend.initPlain(.{ .max_bytes = 1024 });
    defer backend.deinit(allocator);

    try backend.appendBytes(allocator, "hello\r\x1b[Kbye\n");
    try std.testing.expectEqualStrings("bye\n", backend.text());
}

test "terminal backend: csi cursor move rewrites existing cells" {
    const allocator = std.testing.allocator;
    var backend = Backend.initPlain(.{ .max_bytes = 1024 });
    defer backend.deinit(allocator);

    try backend.appendBytes(allocator, "abc\x1b[2DXY");
    try std.testing.expectEqualStrings("aXY", backend.text());
}

test "terminal backend: ansi color escapes are ignored in text output" {
    const allocator = std.testing.allocator;
    var backend = Backend.initPlain(.{ .max_bytes = 1024 });
    defer backend.deinit(allocator);

    try backend.appendBytes(allocator, "\x1b[31mred\x1b[0m");
    try std.testing.expectEqualStrings("red", backend.text());
}

test "terminal backend: sgr updates styled line metadata" {
    const allocator = std.testing.allocator;
    var backend = Backend.initPlain(.{ .max_bytes = 1024 });
    defer backend.deinit(allocator);

    try backend.appendBytes(allocator, "\x1b[31mR\x1b[0mD");
    const line = backend.lineAt(0) orelse {
        try std.testing.expect(false);
        return;
    };
    try std.testing.expectEqual(@as(usize, 2), line.bytes.len);
    try std.testing.expectEqual(@as(u8, 'R'), line.bytes[0]);
    try std.testing.expectEqual(@as(u8, 'D'), line.bytes[1]);
    try std.testing.expectEqualStrings("RD", backend.text());

    switch (line.styles[0].fg) {
        .indexed => |idx| try std.testing.expectEqual(@as(u8, 1), idx),
        else => {
            try std.testing.expect(false);
            return;
        },
    }
    try std.testing.expect(line.styles[1].fg == .default);
}
