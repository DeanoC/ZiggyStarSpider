const std = @import("std");

// Client configuration for ZiggyStarSpider

pub const ProjectTokenEntry = struct {
    project_id: []const u8,
    token: []const u8,
};

pub const Config = struct {
    pub const TokenRole = enum {
        admin,
        user,
    };

    allocator: std.mem.Allocator,

    // Connection settings
    server_url: []const u8,
    admin_token: []const u8,
    user_token: []const u8,
    active_role: TokenRole = .admin,
    insecure_tls: bool = false,

    // UI and workflow defaults
    auto_connect_on_launch: bool = true,
    connect_host_override: ?[]const u8 = null,
    default_project: ?[]const u8 = null,
    default_agent: ?[]const u8 = null,
    project_tokens: ?[]ProjectTokenEntry = null,
    default_session: ?[]const u8 = null,

    // Update + theme settings
    update_manifest_url: []const u8,
    ui_theme: ?[]const u8 = null,
    ui_theme_pack: ?[]const u8 = null,
    ui_watch_theme_pack: bool = false,
    ui_theme_pack_recent: ?[]const []const u8 = null,
    ui_profile: ?[]const u8 = null,
    terminal_backend: ?[]const u8 = null,
    gui_verbose_ws_logs: bool = false,

    pub const default_server_url = "ws://127.0.0.1:18790";

    pub fn init(allocator: std.mem.Allocator) !Config {
        const server_url = try allocator.dupe(u8, default_server_url);
        errdefer allocator.free(server_url);
        const admin_token = try allocator.dupe(u8, "");
        errdefer allocator.free(admin_token);
        const user_token = try allocator.dupe(u8, "");
        errdefer allocator.free(user_token);
        const update_manifest_url = try allocator.dupe(u8, "https://github.com/DeanoC/ZiggyStarSpider/releases/latest/download/update.json");
        errdefer allocator.free(update_manifest_url);

        return .{
            .allocator = allocator,
            .server_url = server_url,
            .admin_token = admin_token,
            .user_token = user_token,
            .active_role = .admin,
            .update_manifest_url = update_manifest_url,
        };
    }

    pub fn deinit(self: *Config) void {
        self.allocator.free(self.server_url);
        self.allocator.free(self.admin_token);
        self.allocator.free(self.user_token);
        self.allocator.free(self.update_manifest_url);
        if (self.connect_host_override) |value| {
            self.allocator.free(value);
            self.connect_host_override = null;
        }
        if (self.default_project) |value| {
            self.allocator.free(value);
            self.default_project = null;
        }
        if (self.default_agent) |value| {
            self.allocator.free(value);
            self.default_agent = null;
        }
        if (self.project_tokens) |entries| {
            for (entries) |entry| {
                self.allocator.free(entry.project_id);
                self.allocator.free(entry.token);
            }
            self.allocator.free(entries);
            self.project_tokens = null;
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
        if (self.terminal_backend) |value| {
            self.allocator.free(value);
            self.terminal_backend = null;
        }
    }

    pub fn setServerUrl(self: *Config, server_url: []const u8) !void {
        const new_url = try self.allocator.dupe(u8, server_url);
        self.allocator.free(self.server_url);
        self.server_url = new_url;
    }

    pub fn getRoleToken(self: *const Config, role: TokenRole) []const u8 {
        return switch (role) {
            .admin => self.admin_token,
            .user => self.user_token,
        };
    }

    pub fn activeRoleToken(self: *const Config) []const u8 {
        const primary = self.getRoleToken(self.active_role);
        if (primary.len > 0) return primary;
        return switch (self.active_role) {
            .admin => self.user_token,
            .user => self.admin_token,
        };
    }

    pub fn setActiveRole(self: *Config, role: TokenRole) !void {
        self.active_role = role;
    }

    pub fn setRoleToken(self: *Config, role: TokenRole, value: []const u8) !void {
        const copy = try self.allocator.dupe(u8, value);
        switch (role) {
            .admin => {
                self.allocator.free(self.admin_token);
                self.admin_token = copy;
            },
            .user => {
                self.allocator.free(self.user_token);
                self.user_token = copy;
            },
        }
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

    pub fn setSelectedProject(self: *Config, project_id: ?[]const u8) !void {
        const next = if (project_id) |value| blk: {
            if (value.len == 0) break :blk null;
            break :blk try self.allocator.dupe(u8, value);
        } else null;
        if (self.default_project) |value| self.allocator.free(value);
        self.default_project = next;
    }

    pub fn selectedProject(self: *const Config) ?[]const u8 {
        return self.default_project;
    }

    pub fn setDefaultAgent(self: *Config, agent_id: ?[]const u8) !void {
        const next = if (agent_id) |value| blk: {
            if (value.len == 0) break :blk null;
            break :blk try self.allocator.dupe(u8, value);
        } else null;
        if (self.default_agent) |value| self.allocator.free(value);
        self.default_agent = next;
    }

    pub fn selectedAgent(self: *const Config) ?[]const u8 {
        return self.default_agent;
    }

    pub fn getProjectToken(self: *const Config, project_id: []const u8) ?[]const u8 {
        const entries = self.project_tokens orelse return null;
        for (entries) |entry| {
            if (std.mem.eql(u8, entry.project_id, project_id)) return entry.token;
        }
        return null;
    }

    pub fn setProjectToken(self: *Config, project_id: []const u8, token: []const u8) !void {
        if (project_id.len == 0) return;
        if (token.len == 0) {
            try self.clearProjectToken(project_id);
            return;
        }

        if (self.project_tokens) |entries| {
            for (entries) |*entry| {
                if (!std.mem.eql(u8, entry.project_id, project_id)) continue;
                const token_copy = try self.allocator.dupe(u8, token);
                self.allocator.free(entry.token);
                entry.token = token_copy;
                return;
            }

            const expanded = try self.allocator.alloc(ProjectTokenEntry, entries.len + 1);
            @memcpy(expanded[0..entries.len], entries);
            expanded[entries.len] = .{
                .project_id = try self.allocator.dupe(u8, project_id),
                .token = try self.allocator.dupe(u8, token),
            };
            self.allocator.free(entries);
            self.project_tokens = expanded;
            return;
        }

        const entries = try self.allocator.alloc(ProjectTokenEntry, 1);
        entries[0] = .{
            .project_id = try self.allocator.dupe(u8, project_id),
            .token = try self.allocator.dupe(u8, token),
        };
        self.project_tokens = entries;
    }

    pub fn clearProjectToken(self: *Config, project_id: []const u8) !void {
        if (project_id.len == 0) return;
        const entries = self.project_tokens orelse return;

        var remove_idx: ?usize = null;
        for (entries, 0..) |entry, idx| {
            if (std.mem.eql(u8, entry.project_id, project_id)) {
                remove_idx = idx;
                break;
            }
        }
        const idx = remove_idx orelse return;

        self.allocator.free(entries[idx].project_id);
        self.allocator.free(entries[idx].token);

        if (entries.len == 1) {
            self.allocator.free(entries);
            self.project_tokens = null;
            return;
        }

        const compacted = try self.allocator.alloc(ProjectTokenEntry, entries.len - 1);
        var out_idx: usize = 0;
        for (entries, 0..) |entry, entry_idx| {
            if (entry_idx == idx) continue;
            compacted[out_idx] = entry;
            out_idx += 1;
        }

        self.allocator.free(entries);
        self.project_tokens = compacted;
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

    pub fn setTerminalBackend(self: *Config, value: ?[]const u8) !void {
        const next = if (value) |backend| blk: {
            if (backend.len == 0) break :blk null;
            break :blk try self.allocator.dupe(u8, backend);
        } else null;
        if (self.terminal_backend) |backend| self.allocator.free(backend);
        self.terminal_backend = next;
    }

    pub fn selectedTerminalBackend(self: *const Config) ?[]const u8 {
        return self.terminal_backend;
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

    fn duplicateOptionalProjectTokens(
        allocator: std.mem.Allocator,
        values: ?[]const ProjectTokenEntry,
    ) !?[]ProjectTokenEntry {
        if (values == null) return null;
        const list = values.?;
        if (list.len == 0) return try allocator.alloc(ProjectTokenEntry, 0);

        const out = try allocator.alloc(ProjectTokenEntry, list.len);
        var written: usize = 0;
        errdefer {
            for (0..written) |i| {
                allocator.free(out[i].project_id);
                allocator.free(out[i].token);
            }
            allocator.free(out);
        }

        for (list) |entry| {
            out[written] = .{
                .project_id = try allocator.dupe(u8, entry.project_id),
                .token = try allocator.dupe(u8, entry.token),
            };
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
        const legacy_token = if (json.auth_token) |value|
            value
        else if (json.token) |value|
            value
        else
            "";
        const loaded_admin = if (json.admin_token) |value|
            value
        else
            legacy_token;
        const loaded_user = if (json.user_token) |value|
            value
        else
            legacy_token;

        const active_role = parseTokenRole(json.active_role);
        var loaded_default_project = try duplicateOptionalString(allocator, json.default_project);
        if (loaded_default_project) |value| {
            if (std.mem.eql(u8, value, "spider-web")) {
                allocator.free(value);
                loaded_default_project = null;
            }
        }
        var loaded_default_agent = try duplicateOptionalString(allocator, json.default_agent);
        if (loaded_default_agent) |value| {
            if (std.mem.eql(u8, value, "default")) {
                allocator.free(value);
                loaded_default_agent = null;
            }
        }
        var loaded_project_tokens = try duplicateOptionalProjectTokens(allocator, json.project_tokens);
        if (loaded_project_tokens) |entries_const| {
            var entries = entries_const;
            var keep: usize = 0;
            for (entries) |entry| {
                if (std.mem.eql(u8, entry.project_id, "spider-web")) {
                    allocator.free(entry.project_id);
                    allocator.free(entry.token);
                    continue;
                }
                entries[keep] = entry;
                keep += 1;
            }
            if (keep == 0) {
                allocator.free(entries);
                loaded_project_tokens = null;
            } else if (keep < entries.len) {
                loaded_project_tokens = try allocator.realloc(entries, keep);
            }
        }

        return .{
            .allocator = allocator,
            .server_url = try duplicateOptionalString(allocator, json.server_url) orelse
                try allocator.dupe(u8, default_server_url),
            .admin_token = try allocator.dupe(u8, loaded_admin),
            .user_token = try allocator.dupe(u8, loaded_user),
            .active_role = active_role,
            .insecure_tls = json.insecure_tls orelse false,
            .auto_connect_on_launch = json.auto_connect_on_launch orelse true,
            .connect_host_override = try duplicateOptionalString(allocator, json.connect_host_override),
            .default_project = loaded_default_project,
            .default_agent = loaded_default_agent,
            .project_tokens = loaded_project_tokens,
            .default_session = try duplicateOptionalString(allocator, json.default_session),
            .update_manifest_url = try duplicateOptionalString(allocator, json.update_manifest_url) orelse
                try allocator.dupe(u8, "https://github.com/DeanoC/ZiggyStarSpider/releases/latest/download/update.json"),
            .ui_theme = try duplicateOptionalString(allocator, json.ui_theme),
            .ui_theme_pack = try duplicateOptionalString(allocator, json.ui_theme_pack),
            .ui_watch_theme_pack = json.ui_watch_theme_pack orelse false,
            .ui_theme_pack_recent = try duplicateOptionalList(allocator, json.ui_theme_pack_recent),
            .ui_profile = try duplicateOptionalString(allocator, json.ui_profile),
            .terminal_backend = try duplicateOptionalString(allocator, json.terminal_backend),
            .gui_verbose_ws_logs = json.gui_verbose_ws_logs orelse false,
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
            .admin_token = self.admin_token,
            .user_token = self.user_token,
            .active_role = tokenRoleName(self.active_role),
            .insecure_tls = self.insecure_tls,
            .auto_connect_on_launch = self.auto_connect_on_launch,
            .connect_host_override = self.connect_host_override,
            .default_project = self.default_project,
            .default_agent = self.default_agent,
            .project_tokens = self.project_tokens,
            .default_session = self.default_session,
            .update_manifest_url = self.update_manifest_url,
            .ui_theme = self.ui_theme,
            .ui_theme_pack = self.ui_theme_pack,
            .ui_watch_theme_pack = self.ui_watch_theme_pack,
            .ui_theme_pack_recent = self.ui_theme_pack_recent,
            .ui_profile = self.ui_profile,
            .terminal_backend = self.terminal_backend,
            .gui_verbose_ws_logs = self.gui_verbose_ws_logs,
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
    // Legacy fields kept for backwards-compatible config migration.
    auth_token: ?[]const u8 = null,
    token: ?[]const u8 = null,
    admin_token: ?[]const u8 = null,
    user_token: ?[]const u8 = null,
    active_role: ?[]const u8 = null,
    insecure_tls: ?bool = null,
    auto_connect_on_launch: ?bool = null,
    connect_host_override: ?[]const u8 = null,
    default_project: ?[]const u8 = null,
    default_agent: ?[]const u8 = null,
    project_tokens: ?[]const ProjectTokenEntry = null,
    default_session: ?[]const u8 = null,
    update_manifest_url: ?[]const u8 = null,
    ui_theme: ?[]const u8 = null,
    ui_theme_pack: ?[]const u8 = null,
    ui_watch_theme_pack: ?bool = null,
    ui_theme_pack_recent: ?[]const []const u8 = null,
    ui_profile: ?[]const u8 = null,
    terminal_backend: ?[]const u8 = null,
    gui_verbose_ws_logs: ?bool = null,
};

fn parseTokenRole(value: ?[]const u8) Config.TokenRole {
    if (value) |raw| {
        if (std.mem.eql(u8, raw, "user")) return .user;
    }
    return .admin;
}

fn tokenRoleName(role: Config.TokenRole) []const u8 {
    return switch (role) {
        .admin => "admin",
        .user => "user",
    };
}
