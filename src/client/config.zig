const std = @import("std");

// Client configuration for ZiggyStarSpider

pub const Config = struct {
    allocator: std.mem.Allocator,

    // Connection settings
    server_url: []const u8,
    auth_token: []const u8,
    token: []const u8,
    insecure_tls: bool = false,

    // UI and workflow defaults
    auto_connect_on_launch: bool = true,
    connect_host_override: ?[]const u8 = null,
    default_project: ?[]const u8 = null,
    default_session: ?[]const u8 = null,

    // Update + theme settings
    update_manifest_url: []const u8,
    ui_theme: ?[]const u8 = null,
    ui_theme_pack: ?[]const u8 = null,
    ui_watch_theme_pack: bool = false,
    ui_theme_pack_recent: ?[]const []const u8 = null,
    ui_profile: ?[]const u8 = null,

    pub fn init(allocator: std.mem.Allocator) !Config {
        const server_url = try allocator.dupe(u8, "ws://127.0.0.1:18790");
        errdefer allocator.free(server_url);
        const auth_token = try allocator.dupe(u8, "");
        errdefer allocator.free(auth_token);
        const token = try allocator.dupe(u8, "");
        errdefer allocator.free(token);
        const update_manifest_url = try allocator.dupe(u8, "https://github.com/DeanoC/ZiggyStarSpider/releases/latest/download/update.json");
        errdefer allocator.free(update_manifest_url);

        return .{
            .allocator = allocator,
            .server_url = server_url,
            .auth_token = auth_token,
            .token = token,
            .update_manifest_url = update_manifest_url,
        };
    }

    pub fn deinit(self: *Config) void {
        self.allocator.free(self.server_url);
        self.allocator.free(self.auth_token);
        self.allocator.free(self.token);
        self.allocator.free(self.update_manifest_url);
        if (self.connect_host_override) |value| {
            self.allocator.free(value);
            self.connect_host_override = null;
        }
        if (self.default_project) |value| {
            self.allocator.free(value);
            self.default_project = null;
        }
        if (self.default_session) |value| {
            self.allocator.free(value);
            self.default_session = null;
        }
        if (self.ui_theme) |value| {
            self.allocator.free(value);
            self.ui_theme = null;
        }
        if (self.ui_theme_pack) |value| {
            self.allocator.free(value);
            self.ui_theme_pack = null;
        }
        if (self.ui_theme_pack_recent) |values| {
            for (values) |value| self.allocator.free(value);
            self.allocator.free(values);
            self.ui_theme_pack_recent = null;
        }
        if (self.ui_profile) |value| {
            self.allocator.free(value);
            self.ui_profile = null;
        }
    }

    pub fn setServerUrl(self: *Config, server_url: []const u8) !void {
        const new_url = try self.allocator.dupe(u8, server_url);
        self.allocator.free(self.server_url);
        self.server_url = new_url;
    }

    pub fn setAuthToken(self: *Config, token: []const u8) !void {
        const auth_copy = try self.allocator.dupe(u8, token);
        const token_copy = try self.allocator.dupe(u8, token);
        self.allocator.free(self.auth_token);
        self.allocator.free(self.token);
        self.auth_token = auth_copy;
        self.token = token_copy;
    }

    pub fn setDefaultSession(self: *Config, default_session: []const u8) !void {
        const current = if (default_session.len > 0)
            try self.allocator.dupe(u8, default_session)
        else
            try self.allocator.dupe(u8, "main");
        if (self.default_session) |value| {
            self.allocator.free(value);
        }
        self.default_session = current;
    }

    pub fn setTheme(self: *Config, value: ?[]const u8) !void {
        const next = if (value) |theme| try self.allocator.dupe(u8, theme) else null;
        if (self.ui_theme) |theme| self.allocator.free(theme);
        self.ui_theme = next;
    }

    pub fn setThemePack(self: *Config, value: ?[]const u8) !void {
        const next = if (value) |pack| try self.allocator.dupe(u8, pack) else null;
        if (self.ui_theme_pack) |pack| self.allocator.free(pack);
        self.ui_theme_pack = next;
    }

    pub fn setProfile(self: *Config, value: ?[]const u8) !void {
        const next = if (value) |profile| try self.allocator.dupe(u8, profile) else null;
        if (self.ui_profile) |profile| self.allocator.free(profile);
        self.ui_profile = next;
    }

    pub fn setWatchThemePack(self: *Config, enabled: bool) void {
        self.ui_watch_theme_pack = enabled;
    }

    fn duplicateOptionalString(
        allocator: std.mem.Allocator,
        source: ?[]const u8,
    ) !?[]const u8 {
        return if (source) |value| try allocator.dupe(u8, value) else null;
    }

    fn duplicateOptionalList(
        allocator: std.mem.Allocator,
        values: ?[]const []const u8,
    ) !?[]const []const u8 {
        if (values == null) return null;
        const list = values.?;
        if (list.len == 0) return try allocator.alloc([]const u8, 0);

        const out = try allocator.alloc([]const u8, list.len);
        var written: usize = 0;
        errdefer {
            for (0..written) |i| allocator.free(out[i]);
            allocator.free(out);
        }
        for (list, 0..) |entry, i| {
            _ = i;
            out[written] = try allocator.dupe(u8, entry);
            written += 1;
        }
        return out;
    }

    /// Get config directory path
    pub fn getConfigDir(allocator: std.mem.Allocator) ![]const u8 {
        const home = std.process.getEnvVarOwned(allocator, "HOME") catch |err| switch (err) {
            error.EnvironmentVariableNotFound => {
                // Windows fallback
                return std.process.getEnvVarOwned(allocator, "USERPROFILE") catch ".";
            },
            else => return err,
        };
        defer allocator.free(home);

        return std.fs.path.join(allocator, &.{ home, ".config", "zss" });
    }

    /// Load config from file, or return default if not exists
    pub fn load(allocator: std.mem.Allocator) !Config {
        const config_dir = try getConfigDir(allocator);
        defer allocator.free(config_dir);

        const config_path = try std.fs.path.join(allocator, &.{ config_dir, "config.json" });
        defer allocator.free(config_path);

        const data = std.fs.cwd().readFileAlloc(allocator, config_path, 65536) catch |err| switch (err) {
            error.FileNotFound => return try Config.init(allocator),
            else => return err,
        };
        defer allocator.free(data);

        const parsed = try std.json.parseFromSlice(ConfigJson, allocator, data, .{
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();

        const json = parsed.value;
        const auth_token = if (json.auth_token) |value| value else json.token orelse "";
        const token = if (json.token) |value| value else auth_token;

        return .{
            .allocator = allocator,
            .server_url = try duplicateOptionalString(allocator, json.server_url) orelse
                try allocator.dupe(u8, "ws://127.0.0.1:18790"),
            .auth_token = try allocator.dupe(u8, auth_token),
            .token = try allocator.dupe(u8, token),
            .insecure_tls = json.insecure_tls orelse false,
            .auto_connect_on_launch = json.auto_connect_on_launch orelse true,
            .connect_host_override = try duplicateOptionalString(allocator, json.connect_host_override),
            .default_project = try duplicateOptionalString(allocator, json.default_project),
            .default_session = try duplicateOptionalString(allocator, json.default_session),
            .update_manifest_url = try duplicateOptionalString(allocator, json.update_manifest_url) orelse
                try allocator.dupe(u8, "https://github.com/DeanoC/ZiggyStarSpider/releases/latest/download/update.json"),
            .ui_theme = try duplicateOptionalString(allocator, json.ui_theme),
            .ui_theme_pack = try duplicateOptionalString(allocator, json.ui_theme_pack),
            .ui_watch_theme_pack = json.ui_watch_theme_pack orelse false,
            .ui_theme_pack_recent = try duplicateOptionalList(allocator, json.ui_theme_pack_recent),
            .ui_profile = try duplicateOptionalString(allocator, json.ui_profile),
        };
    }

    /// Save config to file
    pub fn save(self: Config) !void {
        const config_dir = try getConfigDir(self.allocator);
        defer self.allocator.free(config_dir);

        // Create directory if needed
        std.fs.cwd().makePath(config_dir) catch {};

        const config_path = try std.fs.path.join(self.allocator, &.{ config_dir, "config.json" });
        defer self.allocator.free(config_path);

        var json_file = try std.fs.cwd().createFile(config_path, .{ .truncate = true });
        defer json_file.close();

        const payload = ConfigJson{
            .server_url = self.server_url,
            .auth_token = self.auth_token,
            .token = self.token,
            .insecure_tls = self.insecure_tls,
            .auto_connect_on_launch = self.auto_connect_on_launch,
            .connect_host_override = self.connect_host_override,
            .default_project = self.default_project,
            .default_session = self.default_session,
            .update_manifest_url = self.update_manifest_url,
            .ui_theme = self.ui_theme,
            .ui_theme_pack = self.ui_theme_pack,
            .ui_watch_theme_pack = self.ui_watch_theme_pack,
            .ui_theme_pack_recent = self.ui_theme_pack_recent,
            .ui_profile = self.ui_profile,
        };

        const bytes = try std.json.Stringify.valueAlloc(self.allocator, payload, .{
            .emit_null_optional_fields = false,
            .whitespace = .indent_2,
        });
        defer self.allocator.free(bytes);
        try json_file.writeAll(bytes);
    }
};

// JSON-compatible config struct for serialization
const ConfigJson = struct {
    server_url: ?[]const u8 = null,
    auth_token: ?[]const u8 = null,
    token: ?[]const u8 = null,
    insecure_tls: ?bool = null,
    auto_connect_on_launch: ?bool = null,
    connect_host_override: ?[]const u8 = null,
    default_project: ?[]const u8 = null,
    default_session: ?[]const u8 = null,
    update_manifest_url: ?[]const u8 = null,
    ui_theme: ?[]const u8 = null,
    ui_theme_pack: ?[]const u8 = null,
    ui_watch_theme_pack: ?bool = null,
    ui_theme_pack_recent: ?[]const []const u8 = null,
    ui_profile: ?[]const u8 = null,
};
