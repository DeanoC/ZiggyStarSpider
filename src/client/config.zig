const std = @import("std");
const storage = @import("platform_storage");

// Client configuration for SpiderApp

pub const WorkspaceTokenEntry = struct {
    workspace_id: []const u8,
    token: []const u8,
};

pub const ConnectionProfile = struct {
    id: []const u8,
    name: []const u8,
    server_url: []const u8,
    active_role: Config.TokenRole = .admin,
    insecure_tls: bool = false,
    connect_host_override: ?[]const u8 = null,
    metadata: ?[]const u8 = null,

    pub fn deinit(self: *ConnectionProfile, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.name);
        allocator.free(self.server_url);
        if (self.connect_host_override) |value| allocator.free(value);
        if (self.metadata) |value| allocator.free(value);
        self.* = undefined;
    }
};

pub const RecentWorkspaceEntry = struct {
    profile_id: []const u8,
    workspace_id: []const u8,
    workspace_name: ?[]const u8 = null,
    opened_at_ms: i64 = 0,

    pub fn deinit(self: *RecentWorkspaceEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.profile_id);
        allocator.free(self.workspace_id);
        if (self.workspace_name) |value| allocator.free(value);
        self.* = undefined;
    }
};

pub const WorkspaceLayoutEntry = struct {
    profile_id: []const u8,
    workspace_id: []const u8,
    layout_path: []const u8,
    updated_at_ms: i64 = 0,

    pub fn deinit(self: *WorkspaceLayoutEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.profile_id);
        allocator.free(self.workspace_id);
        allocator.free(self.layout_path);
        self.* = undefined;
    }
};

pub const AppLocalNodeEntry = struct {
    profile_id: []const u8,
    node_name: []const u8,
    node_id: []const u8,
    node_secret: []const u8,

    pub fn deinit(self: *AppLocalNodeEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.profile_id);
        allocator.free(self.node_name);
        allocator.free(self.node_id);
        allocator.free(self.node_secret);
        self.* = undefined;
    }
};

pub const Config = struct {
    pub const TokenRole = enum {
        admin,
        user,
    };

    pub const current_schema_version: u32 = 2;

    pub const ThemeMode = enum {
        pack_default,
        light,
        dark,
    };

    pub const ThemeProfile = enum {
        auto,
        desktop,
        phone,
        tablet,
        fullscreen,
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
    default_workspace: ?[]const u8 = null,
    default_agent: ?[]const u8 = null,
    workspace_tokens: ?[]WorkspaceTokenEntry = null,
    default_session: ?[]const u8 = null,
    connection_profiles: []ConnectionProfile,
    selected_profile_id: ?[]const u8 = null,
    recent_workspaces: ?[]RecentWorkspaceEntry = null,
    workspace_layout_index: ?[]WorkspaceLayoutEntry = null,
    app_local_nodes: ?[]AppLocalNodeEntry = null,

    // Update + theme settings
    update_manifest_url: []const u8,
    theme_mode: ThemeMode = .pack_default,
    theme_pack: ?[]const u8 = null,
    watch_theme_pack: bool = false,
    theme_pack_recent: ?[]const []const u8 = null,
    theme_profile: ThemeProfile = .auto,
    terminal_backend: ?[]const u8 = null,
    gui_verbose_ws_logs: bool = false,
    window_x: ?i32 = null,
    window_y: ?i32 = null,
    window_width: ?i32 = null,
    window_height: ?i32 = null,

    pub const default_server_url = "ws://127.0.0.1:18790";
    pub const default_profile_id = "default";
    pub const default_profile_name = "Default Spiderweb";

    pub fn init(allocator: std.mem.Allocator) !Config {
        const server_url = try allocator.dupe(u8, default_server_url);
        errdefer allocator.free(server_url);
        const admin_token = try allocator.dupe(u8, "");
        errdefer allocator.free(admin_token);
        const user_token = try allocator.dupe(u8, "");
        errdefer allocator.free(user_token);
        const update_manifest_url = try allocator.dupe(u8, "https://github.com/DeanoC/SpiderApp/releases/latest/download/update.json");
        errdefer allocator.free(update_manifest_url);
        const profiles = try allocator.alloc(ConnectionProfile, 1);
        errdefer allocator.free(profiles);
        profiles[0] = .{
            .id = try allocator.dupe(u8, default_profile_id),
            .name = try allocator.dupe(u8, default_profile_name),
            .server_url = try allocator.dupe(u8, server_url),
            .active_role = .admin,
            .insecure_tls = false,
            .connect_host_override = null,
            .metadata = null,
        };
        errdefer {
            profiles[0].deinit(allocator);
        }
        const selected_profile_id = try allocator.dupe(u8, default_profile_id);
        errdefer allocator.free(selected_profile_id);

        return .{
            .allocator = allocator,
            .server_url = server_url,
            .admin_token = admin_token,
            .user_token = user_token,
            .active_role = .admin,
            .update_manifest_url = update_manifest_url,
            .connection_profiles = profiles,
            .selected_profile_id = selected_profile_id,
            .watch_theme_pack = storage.supportsThemePackWatch(),
        };
    }

    pub fn deinit(self: *Config) void {
        self.allocator.free(self.server_url);
        self.allocator.free(self.admin_token);
        self.allocator.free(self.user_token);
        self.allocator.free(self.update_manifest_url);
        for (self.connection_profiles) |*profile| profile.deinit(self.allocator);
        self.allocator.free(self.connection_profiles);
        if (self.selected_profile_id) |value| {
            self.allocator.free(value);
            self.selected_profile_id = null;
        }
        if (self.recent_workspaces) |entries| {
            for (entries) |*entry| entry.deinit(self.allocator);
            self.allocator.free(entries);
            self.recent_workspaces = null;
        }
        if (self.workspace_layout_index) |entries| {
            for (entries) |*entry| entry.deinit(self.allocator);
            self.allocator.free(entries);
            self.workspace_layout_index = null;
        }
        if (self.app_local_nodes) |entries| {
            for (entries) |*entry| entry.deinit(self.allocator);
            self.allocator.free(entries);
            self.app_local_nodes = null;
        }
        if (self.connect_host_override) |value| {
            self.allocator.free(value);
            self.connect_host_override = null;
        }
        if (self.default_workspace) |value| {
            self.allocator.free(value);
            self.default_workspace = null;
        }
        if (self.default_agent) |value| {
            self.allocator.free(value);
            self.default_agent = null;
        }
        if (self.workspace_tokens) |entries| {
            for (entries) |entry| {
                self.allocator.free(entry.workspace_id);
                self.allocator.free(entry.token);
            }
            self.allocator.free(entries);
            self.workspace_tokens = null;
        }
        if (self.default_session) |value| {
            self.allocator.free(value);
            self.default_session = null;
        }
        if (self.theme_pack) |value| {
            self.allocator.free(value);
            self.theme_pack = null;
        }
        if (self.theme_pack_recent) |values| {
            for (values) |value| self.allocator.free(value);
            self.allocator.free(values);
            self.theme_pack_recent = null;
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

    fn profileIndexById(self: *const Config, profile_id: []const u8) ?usize {
        for (self.connection_profiles, 0..) |profile, idx| {
            if (std.mem.eql(u8, profile.id, profile_id)) return idx;
        }
        return null;
    }

    fn selectedProfileIndex(self: *const Config) usize {
        if (self.selected_profile_id) |profile_id| {
            if (self.profileIndexById(profile_id)) |idx| return idx;
        }
        return 0;
    }

    pub fn selectedProfile(self: *const Config) *const ConnectionProfile {
        return &self.connection_profiles[self.selectedProfileIndex()];
    }

    pub fn selectedProfileId(self: *const Config) []const u8 {
        return self.selectedProfile().id;
    }

    pub fn hasConnectionProfileId(self: *const Config, profile_id: []const u8) bool {
        return self.profileIndexById(profile_id) != null;
    }

    fn copyOptionalStringReplacing(
        allocator: std.mem.Allocator,
        destination: *?[]const u8,
        value: ?[]const u8,
    ) !void {
        const next = if (value) |raw| try allocator.dupe(u8, raw) else null;
        if (destination.*) |existing| allocator.free(existing);
        destination.* = next;
    }

    fn applySelectedProfileToLegacyFields(self: *Config) !void {
        if (self.connection_profiles.len == 0) {
            const profile = ConnectionProfile{
                .id = try self.allocator.dupe(u8, default_profile_id),
                .name = try self.allocator.dupe(u8, default_profile_name),
                .server_url = try self.allocator.dupe(u8, default_server_url),
                .active_role = .admin,
                .insecure_tls = false,
                .connect_host_override = null,
                .metadata = null,
            };
            self.connection_profiles = try self.allocator.alloc(ConnectionProfile, 1);
            self.connection_profiles[0] = profile;
        }

        const profile = self.selectedProfile();
        try self.setServerUrl(profile.server_url);
        self.active_role = profile.active_role;
        self.insecure_tls = profile.insecure_tls;
        try copyOptionalStringReplacing(self.allocator, &self.connect_host_override, profile.connect_host_override);
    }

    pub fn syncSelectedProfileFromLegacyFields(self: *Config) !void {
        if (self.connection_profiles.len == 0) return;
        const index = self.selectedProfileIndex();
        var profile = &self.connection_profiles[index];

        const server_copy = try self.allocator.dupe(u8, self.server_url);
        self.allocator.free(profile.server_url);
        profile.server_url = server_copy;
        profile.active_role = self.active_role;
        profile.insecure_tls = self.insecure_tls;
        try copyOptionalStringReplacing(self.allocator, &profile.connect_host_override, self.connect_host_override);
    }

    pub fn setSelectedProfileById(self: *Config, profile_id: []const u8) !void {
        if (self.profileIndexById(profile_id) == null) return error.ProfileNotFound;
        const id_copy = try self.allocator.dupe(u8, profile_id);
        if (self.selected_profile_id) |existing| self.allocator.free(existing);
        self.selected_profile_id = id_copy;
        try self.applySelectedProfileToLegacyFields();
    }

    pub fn addConnectionProfile(
        self: *Config,
        profile_id: []const u8,
        profile_name: []const u8,
        server_url: []const u8,
        role: TokenRole,
        metadata: ?[]const u8,
    ) !void {
        if (profile_id.len == 0 or server_url.len == 0) return error.InvalidProfile;
        if (self.profileIndexById(profile_id) != null) return error.ProfileAlreadyExists;

        const existing = self.connection_profiles;
        const expanded = try self.allocator.alloc(ConnectionProfile, existing.len + 1);
        @memcpy(expanded[0..existing.len], existing);
        expanded[existing.len] = .{
            .id = try self.allocator.dupe(u8, profile_id),
            .name = try self.allocator.dupe(u8, if (profile_name.len > 0) profile_name else profile_id),
            .server_url = try self.allocator.dupe(u8, server_url),
            .active_role = role,
            .insecure_tls = self.insecure_tls,
            .connect_host_override = try duplicateOptionalString(self.allocator, self.connect_host_override),
            .metadata = if (metadata) |value| try self.allocator.dupe(u8, value) else null,
        };
        self.allocator.free(existing);
        self.connection_profiles = expanded;
    }

    pub fn updateSelectedConnectionProfile(
        self: *Config,
        profile_name: []const u8,
        server_url: []const u8,
        role: TokenRole,
        metadata: ?[]const u8,
    ) !void {
        if (self.connection_profiles.len == 0) return error.ProfileNotFound;
        if (server_url.len == 0) return error.ServerUrlRequired;

        const selected = self.selectedProfileIndex();
        var profile = &self.connection_profiles[selected];

        const next_name = try self.allocator.dupe(u8, if (profile_name.len > 0) profile_name else profile.id);
        const next_url = try self.allocator.dupe(u8, server_url);
        const next_metadata = if (metadata) |value|
            if (value.len > 0) try self.allocator.dupe(u8, value) else null
        else
            null;

        self.allocator.free(profile.name);
        profile.name = next_name;
        self.allocator.free(profile.server_url);
        profile.server_url = next_url;
        if (profile.metadata) |value| self.allocator.free(value);
        profile.metadata = next_metadata;
        profile.active_role = role;
        profile.insecure_tls = self.insecure_tls;
        try copyOptionalStringReplacing(self.allocator, &profile.connect_host_override, self.connect_host_override);

        try self.setServerUrl(server_url);
        self.active_role = role;
    }

    pub fn setWorkspaceLayoutPath(
        self: *Config,
        profile_id: []const u8,
        workspace_id: []const u8,
        layout_path: []const u8,
    ) !void {
        if (profile_id.len == 0 or workspace_id.len == 0) return;
        if (self.workspace_layout_index == null) {
            const created = try self.allocator.alloc(WorkspaceLayoutEntry, 1);
            created[0] = .{
                .profile_id = try self.allocator.dupe(u8, profile_id),
                .workspace_id = try self.allocator.dupe(u8, workspace_id),
                .layout_path = try self.allocator.dupe(u8, layout_path),
                .updated_at_ms = std.time.milliTimestamp(),
            };
            self.workspace_layout_index = created;
            return;
        }
        const entries = self.workspace_layout_index.?;

        for (entries) |*entry| {
            if (!std.mem.eql(u8, entry.profile_id, profile_id)) continue;
            if (!std.mem.eql(u8, entry.workspace_id, workspace_id)) continue;
            const next_path = try self.allocator.dupe(u8, layout_path);
            self.allocator.free(entry.layout_path);
            entry.layout_path = next_path;
            entry.updated_at_ms = std.time.milliTimestamp();
            return;
        }

        const expanded = try self.allocator.alloc(WorkspaceLayoutEntry, entries.len + 1);
        @memcpy(expanded[0..entries.len], entries);
        expanded[entries.len] = .{
            .profile_id = try self.allocator.dupe(u8, profile_id),
            .workspace_id = try self.allocator.dupe(u8, workspace_id),
            .layout_path = try self.allocator.dupe(u8, layout_path),
            .updated_at_ms = std.time.milliTimestamp(),
        };
        self.allocator.free(entries);
        self.workspace_layout_index = expanded;
    }

    pub fn workspaceLayoutPath(
        self: *const Config,
        profile_id: []const u8,
        workspace_id: []const u8,
    ) ?[]const u8 {
        const entries = self.workspace_layout_index orelse return null;
        for (entries) |entry| {
            if (!std.mem.eql(u8, entry.profile_id, profile_id)) continue;
            if (!std.mem.eql(u8, entry.workspace_id, workspace_id)) continue;
            return entry.layout_path;
        }
        return null;
    }

    pub fn appLocalNode(self: *const Config, profile_id: []const u8) ?*const AppLocalNodeEntry {
        const entries = self.app_local_nodes orelse return null;
        for (entries) |*entry| {
            if (std.mem.eql(u8, entry.profile_id, profile_id)) return entry;
        }
        return null;
    }

    pub fn setAppLocalNode(
        self: *Config,
        profile_id: []const u8,
        node_name: []const u8,
        node_id: []const u8,
        node_secret: []const u8,
    ) !void {
        if (profile_id.len == 0 or node_name.len == 0 or node_id.len == 0 or node_secret.len == 0) {
            return error.InvalidProfile;
        }

        if (self.app_local_nodes) |entries| {
            for (entries) |*entry| {
                if (!std.mem.eql(u8, entry.profile_id, profile_id)) continue;
                const next_name = try self.allocator.dupe(u8, node_name);
                const next_id = try self.allocator.dupe(u8, node_id);
                const next_secret = try self.allocator.dupe(u8, node_secret);
                self.allocator.free(entry.node_name);
                self.allocator.free(entry.node_id);
                self.allocator.free(entry.node_secret);
                entry.node_name = next_name;
                entry.node_id = next_id;
                entry.node_secret = next_secret;
                return;
            }

            const expanded = try self.allocator.alloc(AppLocalNodeEntry, entries.len + 1);
            @memcpy(expanded[0..entries.len], entries);
            expanded[entries.len] = .{
                .profile_id = try self.allocator.dupe(u8, profile_id),
                .node_name = try self.allocator.dupe(u8, node_name),
                .node_id = try self.allocator.dupe(u8, node_id),
                .node_secret = try self.allocator.dupe(u8, node_secret),
            };
            self.allocator.free(entries);
            self.app_local_nodes = expanded;
            return;
        }

        const entries = try self.allocator.alloc(AppLocalNodeEntry, 1);
        entries[0] = .{
            .profile_id = try self.allocator.dupe(u8, profile_id),
            .node_name = try self.allocator.dupe(u8, node_name),
            .node_id = try self.allocator.dupe(u8, node_id),
            .node_secret = try self.allocator.dupe(u8, node_secret),
        };
        self.app_local_nodes = entries;
    }

    pub fn recordRecentWorkspace(
        self: *Config,
        profile_id: []const u8,
        workspace_id: []const u8,
        workspace_name: ?[]const u8,
    ) !void {
        if (profile_id.len == 0 or workspace_id.len == 0) return;
        const now_ms = std.time.milliTimestamp();

        if (self.recent_workspaces) |entries| {
            var found: ?usize = null;
            for (entries, 0..) |entry, idx| {
                if (std.mem.eql(u8, entry.profile_id, profile_id) and
                    std.mem.eql(u8, entry.workspace_id, workspace_id))
                {
                    found = idx;
                    break;
                }
            }
            if (found) |idx| {
                entries[idx].opened_at_ms = now_ms;
                if (workspace_name) |name| {
                    const copy = try self.allocator.dupe(u8, name);
                    if (entries[idx].workspace_name) |existing| self.allocator.free(existing);
                    entries[idx].workspace_name = copy;
                }
                return;
            }

            const expanded = try self.allocator.alloc(RecentWorkspaceEntry, entries.len + 1);
            @memcpy(expanded[0..entries.len], entries);
            expanded[entries.len] = .{
                .profile_id = try self.allocator.dupe(u8, profile_id),
                .workspace_id = try self.allocator.dupe(u8, workspace_id),
                .workspace_name = if (workspace_name) |name| try self.allocator.dupe(u8, name) else null,
                .opened_at_ms = now_ms,
            };
            self.allocator.free(entries);
            self.recent_workspaces = expanded;
            return;
        }

        const entries = try self.allocator.alloc(RecentWorkspaceEntry, 1);
        entries[0] = .{
            .profile_id = try self.allocator.dupe(u8, profile_id),
            .workspace_id = try self.allocator.dupe(u8, workspace_id),
            .workspace_name = if (workspace_name) |name| try self.allocator.dupe(u8, name) else null,
            .opened_at_ms = now_ms,
        };
        self.recent_workspaces = entries;
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

    pub fn setSelectedWorkspace(self: *Config, workspace_id: ?[]const u8) !void {
        const next = if (workspace_id) |value| blk: {
            if (value.len == 0) break :blk null;
            break :blk try self.allocator.dupe(u8, value);
        } else null;
        if (self.default_workspace) |value| self.allocator.free(value);
        self.default_workspace = next;
    }

    pub fn selectedWorkspace(self: *const Config) ?[]const u8 {
        return self.default_workspace;
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

    pub fn getWorkspaceToken(self: *const Config, workspace_id: []const u8) ?[]const u8 {
        const entries = self.workspace_tokens orelse return null;
        for (entries) |entry| {
            if (std.mem.eql(u8, entry.workspace_id, workspace_id)) return entry.token;
        }
        return null;
    }

    pub fn setWorkspaceToken(self: *Config, workspace_id: []const u8, token: []const u8) !void {
        if (workspace_id.len == 0) return;
        if (token.len == 0) {
            try self.clearWorkspaceToken(workspace_id);
            return;
        }

        if (self.workspace_tokens) |entries| {
            for (entries) |*entry| {
                if (!std.mem.eql(u8, entry.workspace_id, workspace_id)) continue;
                const token_copy = try self.allocator.dupe(u8, token);
                self.allocator.free(entry.token);
                entry.token = token_copy;
                return;
            }

            const expanded = try self.allocator.alloc(WorkspaceTokenEntry, entries.len + 1);
            @memcpy(expanded[0..entries.len], entries);
            expanded[entries.len] = .{
                .workspace_id = try self.allocator.dupe(u8, workspace_id),
                .token = try self.allocator.dupe(u8, token),
            };
            self.allocator.free(entries);
            self.workspace_tokens = expanded;
            return;
        }

        const entries = try self.allocator.alloc(WorkspaceTokenEntry, 1);
        entries[0] = .{
            .workspace_id = try self.allocator.dupe(u8, workspace_id),
            .token = try self.allocator.dupe(u8, token),
        };
        self.workspace_tokens = entries;
    }

    pub fn clearWorkspaceToken(self: *Config, workspace_id: []const u8) !void {
        if (workspace_id.len == 0) return;
        const entries = self.workspace_tokens orelse return;

        var remove_idx: ?usize = null;
        for (entries, 0..) |entry, idx| {
            if (std.mem.eql(u8, entry.workspace_id, workspace_id)) {
                remove_idx = idx;
                break;
            }
        }
        const idx = remove_idx orelse return;

        self.allocator.free(entries[idx].workspace_id);
        self.allocator.free(entries[idx].token);

        if (entries.len == 1) {
            self.allocator.free(entries);
            self.workspace_tokens = null;
            return;
        }

        const compacted = try self.allocator.alloc(WorkspaceTokenEntry, entries.len - 1);
        var out_idx: usize = 0;
        for (entries, 0..) |entry, entry_idx| {
            if (entry_idx == idx) continue;
            compacted[out_idx] = entry;
            out_idx += 1;
        }

        self.allocator.free(entries);
        self.workspace_tokens = compacted;
    }

    pub fn setThemeMode(self: *Config, value: ThemeMode) void {
        self.theme_mode = value;
    }

    pub fn setThemePack(self: *Config, value: ?[]const u8) !void {
        const next = if (value) |pack| try self.allocator.dupe(u8, pack) else null;
        if (self.theme_pack) |pack| self.allocator.free(pack);
        self.theme_pack = next;
    }

    pub fn setThemeProfile(self: *Config, value: ThemeProfile) void {
        self.theme_profile = value;
    }

    pub fn setWatchThemePack(self: *Config, enabled: bool) void {
        self.watch_theme_pack = enabled and storage.supportsThemePackWatch();
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

    pub fn rememberThemePack(self: *Config, pack_path: []const u8) bool {
        if (pack_path.len == 0) return false;

        const max_items: usize = 8;
        const current = self.theme_pack_recent orelse &[_][]const u8{};
        if (current.len > 0 and std.mem.eql(u8, current[0], pack_path)) return false;

        var new_len: usize = 1;
        for (current) |item| {
            if (new_len >= max_items) break;
            if (std.mem.eql(u8, item, pack_path)) continue;
            new_len += 1;
        }

        var out = self.allocator.alloc([]const u8, new_len) catch return false;
        var written: usize = 0;

        out[written] = self.allocator.dupe(u8, pack_path) catch {
            self.allocator.free(out);
            return false;
        };
        written += 1;

        for (current) |item| {
            if (written >= new_len) break;
            if (std.mem.eql(u8, item, pack_path)) continue;
            out[written] = self.allocator.dupe(u8, item) catch {
                var i: usize = 0;
                while (i < written) : (i += 1) self.allocator.free(out[i]);
                self.allocator.free(out);
                return false;
            };
            written += 1;
        }

        if (self.theme_pack_recent) |list| {
            for (list) |item| self.allocator.free(item);
            self.allocator.free(list);
        }
        self.theme_pack_recent = out;
        return true;
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

    fn duplicateOptionalWorkspaceTokens(
        allocator: std.mem.Allocator,
        values: ?[]const WorkspaceTokenEntry,
    ) !?[]WorkspaceTokenEntry {
        if (values == null) return null;
        const list = values.?;
        if (list.len == 0) return try allocator.alloc(WorkspaceTokenEntry, 0);

        const out = try allocator.alloc(WorkspaceTokenEntry, list.len);
        var written: usize = 0;
        errdefer {
            for (0..written) |i| {
                allocator.free(out[i].workspace_id);
                allocator.free(out[i].token);
            }
            allocator.free(out);
        }

        for (list) |entry| {
            out[written] = .{
                .workspace_id = try allocator.dupe(u8, entry.workspace_id),
                .token = try allocator.dupe(u8, entry.token),
            };
            written += 1;
        }
        return out;
    }

    fn duplicateConnectionProfiles(
        allocator: std.mem.Allocator,
        values: ?[]const ConnectionProfileJson,
        legacy: LegacyProfileSeed,
    ) ![]ConnectionProfile {
        if (values) |list| {
            if (list.len > 0) {
                const out = try allocator.alloc(ConnectionProfile, list.len);
                var written: usize = 0;
                errdefer {
                    for (0..written) |i| out[i].deinit(allocator);
                    allocator.free(out);
                }

                for (list) |entry| {
                    const profile_id = if (entry.id) |value|
                        value
                    else
                        default_profile_id;
                    const profile_name = if (entry.name) |value|
                        value
                    else if (entry.server_url) |url|
                        url
                    else
                        default_profile_name;
                    const profile_url = if (entry.server_url) |value|
                        value
                    else
                        legacy.server_url;
                    out[written] = .{
                        .id = try allocator.dupe(u8, profile_id),
                        .name = try allocator.dupe(u8, profile_name),
                        .server_url = try allocator.dupe(u8, profile_url),
                        .active_role = parseTokenRole(entry.active_role),
                        .insecure_tls = entry.insecure_tls orelse false,
                        .connect_host_override = try duplicateOptionalString(allocator, entry.connect_host_override),
                        .metadata = try duplicateOptionalString(allocator, entry.metadata),
                    };
                    written += 1;
                }
                return out;
            }
        }

        const out = try allocator.alloc(ConnectionProfile, 1);
        out[0] = .{
            .id = try allocator.dupe(u8, default_profile_id),
            .name = try allocator.dupe(u8, default_profile_name),
            .server_url = try allocator.dupe(u8, legacy.server_url),
            .active_role = legacy.active_role,
            .insecure_tls = legacy.insecure_tls,
            .connect_host_override = try duplicateOptionalString(allocator, legacy.connect_host_override),
            .metadata = null,
        };
        return out;
    }

    fn duplicateOptionalRecentWorkspaces(
        allocator: std.mem.Allocator,
        values: ?[]const RecentWorkspaceJson,
    ) !?[]RecentWorkspaceEntry {
        if (values == null) return null;
        const list = values.?;
        if (list.len == 0) return try allocator.alloc(RecentWorkspaceEntry, 0);

        const out = try allocator.alloc(RecentWorkspaceEntry, list.len);
        var written: usize = 0;
        errdefer {
            for (0..written) |i| out[i].deinit(allocator);
            allocator.free(out);
        }

        for (list) |entry| {
            out[written] = .{
                .profile_id = try allocator.dupe(u8, entry.profile_id),
                .workspace_id = try allocator.dupe(u8, entry.workspace_id),
                .workspace_name = try duplicateOptionalString(allocator, entry.workspace_name),
                .opened_at_ms = entry.opened_at_ms orelse 0,
            };
            written += 1;
        }
        return out;
    }

    fn duplicateOptionalWorkspaceLayoutIndex(
        allocator: std.mem.Allocator,
        values: ?[]const WorkspaceLayoutJson,
    ) !?[]WorkspaceLayoutEntry {
        if (values == null) return null;
        const list = values.?;
        if (list.len == 0) return try allocator.alloc(WorkspaceLayoutEntry, 0);

        const out = try allocator.alloc(WorkspaceLayoutEntry, list.len);
        var written: usize = 0;
        errdefer {
            for (0..written) |i| out[i].deinit(allocator);
            allocator.free(out);
        }
        for (list) |entry| {
            out[written] = .{
                .profile_id = try allocator.dupe(u8, entry.profile_id),
                .workspace_id = try allocator.dupe(u8, entry.workspace_id),
                .layout_path = try allocator.dupe(u8, entry.layout_path),
                .updated_at_ms = entry.updated_at_ms orelse 0,
            };
            written += 1;
        }
        return out;
    }

    fn duplicateOptionalAppLocalNodes(
        allocator: std.mem.Allocator,
        values: ?[]const AppLocalNodeJson,
    ) !?[]AppLocalNodeEntry {
        if (values == null) return null;
        const list = values.?;
        if (list.len == 0) return try allocator.alloc(AppLocalNodeEntry, 0);

        const out = try allocator.alloc(AppLocalNodeEntry, list.len);
        var written: usize = 0;
        errdefer {
            for (0..written) |i| out[i].deinit(allocator);
            allocator.free(out);
        }
        for (list) |entry| {
            out[written] = .{
                .profile_id = try allocator.dupe(u8, entry.profile_id),
                .node_name = try allocator.dupe(u8, entry.node_name),
                .node_id = try allocator.dupe(u8, entry.node_id),
                .node_secret = try allocator.dupe(u8, entry.node_secret),
            };
            written += 1;
        }
        return out;
    }

    /// Get config directory path
    pub fn getConfigDir(allocator: std.mem.Allocator) ![]const u8 {
        if (storage.isAndroid()) {
            return allocator.dupe(u8, storage.android_config_dir_name);
        }

        const home = std.process.getEnvVarOwned(allocator, "HOME") catch |err| switch (err) {
            error.EnvironmentVariableNotFound => {
                // Windows fallback
                return std.process.getEnvVarOwned(allocator, "USERPROFILE") catch ".";
            },
            else => return err,
        };
        defer allocator.free(home);

        return std.fs.path.join(allocator, &.{ home, ".config", "spider" });
    }

    fn unsupportedConfigBackupPath(allocator: std.mem.Allocator, config_path: []const u8) ![]const u8 {
        const config_dir = std.fs.path.dirname(config_path) orelse ".";
        return std.fs.path.join(allocator, &.{ config_dir, "config.unsupported-schema.backup.json" });
    }

    fn resetFromUnsupportedConfig(allocator: std.mem.Allocator, config_path: []const u8) !Config {
        const backup_path = try unsupportedConfigBackupPath(allocator, config_path);
        defer allocator.free(backup_path);

        deletePath(backup_path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
        try renamePath(config_path, backup_path);
        std.log.warn(
            "unsupported SpiderApp config schema at {s}; moved previous config to {s} and starting with defaults",
            .{ config_path, backup_path },
        );
        return try Config.init(allocator);
    }

    fn loadFromJsonSlice(allocator: std.mem.Allocator, data: []const u8) !Config {
        const parsed = try std.json.parseFromSlice(ConfigJson, allocator, data, .{
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();

        const json = parsed.value;
        const schema_version = json.schema_version orelse return error.UnsupportedConfigSchema;
        if (schema_version != current_schema_version) return error.UnsupportedConfigSchema;
        const loaded_admin = json.admin_token orelse "";
        const loaded_user = json.user_token orelse "";

        const active_role = parseTokenRole(json.active_role);
        const legacy_server_url = json.server_url orelse default_server_url;
        const legacy_seed = LegacyProfileSeed{
            .server_url = legacy_server_url,
            .active_role = active_role,
            .insecure_tls = json.insecure_tls orelse false,
            .connect_host_override = json.connect_host_override,
        };
        const loaded_profiles = try duplicateConnectionProfiles(allocator, json.connection_profiles, legacy_seed);
        errdefer {
            for (loaded_profiles) |*profile| profile.deinit(allocator);
            allocator.free(loaded_profiles);
        }

        var loaded_selected_profile_id = try duplicateOptionalString(allocator, json.selected_profile_id);
        if (loaded_selected_profile_id == null or
            (loaded_selected_profile_id != null and profileIndexByIdList(loaded_profiles, loaded_selected_profile_id.?) == null))
        {
            if (loaded_selected_profile_id) |value| allocator.free(value);
            loaded_selected_profile_id = try allocator.dupe(u8, loaded_profiles[0].id);
        }

        const selected_profile_index = profileIndexByIdList(loaded_profiles, loaded_selected_profile_id.?) orelse 0;
        const selected_profile = loaded_profiles[selected_profile_index];
        const loaded_default_workspace = try duplicateOptionalString(allocator, json.default_workspace);
        var loaded_default_agent = try duplicateOptionalString(allocator, json.default_agent);
        if (loaded_default_agent) |value| {
            if (std.mem.eql(u8, value, "default")) {
                allocator.free(value);
                loaded_default_agent = null;
            }
        }
        const loaded_workspace_tokens = try duplicateOptionalWorkspaceTokens(allocator, json.workspace_tokens);
        const loaded_recent_workspaces = try duplicateOptionalRecentWorkspaces(allocator, json.recent_workspaces);
        const loaded_layout_index = try duplicateOptionalWorkspaceLayoutIndex(
            allocator,
            json.workspace_layout_index,
        );
        const loaded_app_local_nodes = try duplicateOptionalAppLocalNodes(allocator, json.app_local_nodes);

        return .{
            .allocator = allocator,
            .server_url = try allocator.dupe(u8, selected_profile.server_url),
            .admin_token = try allocator.dupe(u8, loaded_admin),
            .user_token = try allocator.dupe(u8, loaded_user),
            .active_role = selected_profile.active_role,
            .insecure_tls = selected_profile.insecure_tls,
            .auto_connect_on_launch = json.auto_connect_on_launch orelse true,
            .connect_host_override = try duplicateOptionalString(allocator, selected_profile.connect_host_override),
            .default_workspace = loaded_default_workspace,
            .default_agent = loaded_default_agent,
            .workspace_tokens = loaded_workspace_tokens,
            .default_session = try duplicateOptionalString(allocator, json.default_session),
            .connection_profiles = loaded_profiles,
            .selected_profile_id = loaded_selected_profile_id,
            .recent_workspaces = loaded_recent_workspaces,
            .workspace_layout_index = loaded_layout_index,
            .app_local_nodes = loaded_app_local_nodes,
            .update_manifest_url = try duplicateOptionalString(allocator, json.update_manifest_url) orelse
                try allocator.dupe(u8, "https://github.com/DeanoC/SpiderApp/releases/latest/download/update.json"),
            .theme_mode = parseThemeMode(json.theme_mode),
            .theme_pack = try duplicateOptionalString(allocator, json.theme_pack),
            .watch_theme_pack = (json.watch_theme_pack orelse false) and storage.supportsThemePackWatch(),
            .theme_pack_recent = try duplicateOptionalList(allocator, json.theme_pack_recent),
            .theme_profile = parseThemeProfile(json.theme_profile),
            .terminal_backend = try duplicateOptionalString(allocator, json.terminal_backend),
            .gui_verbose_ws_logs = json.gui_verbose_ws_logs orelse false,
            .window_x = json.window_x,
            .window_y = json.window_y,
            .window_width = json.window_width,
            .window_height = json.window_height,
        };
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

        return loadFromJsonSlice(allocator, data) catch |err| switch (err) {
            error.UnsupportedConfigSchema => return try resetFromUnsupportedConfig(allocator, config_path),
            else => return err,
        };
    }

    /// Save config to file
    pub fn save(self: Config) !void {
        var mutable_self = self;
        try mutable_self.syncSelectedProfileFromLegacyFields();

        const config_dir = try getConfigDir(self.allocator);
        defer self.allocator.free(config_dir);

        // Create directory if needed
        std.fs.cwd().makePath(config_dir) catch {};

        const config_path = try std.fs.path.join(self.allocator, &.{ config_dir, "config.json" });
        defer self.allocator.free(config_path);

        var json_file = try std.fs.cwd().createFile(config_path, .{ .truncate = true });
        defer json_file.close();

        const payload = ConfigJson{
            .schema_version = current_schema_version,
            .server_url = mutable_self.server_url,
            .admin_token = mutable_self.admin_token,
            .user_token = mutable_self.user_token,
            .active_role = tokenRoleName(mutable_self.active_role),
            .insecure_tls = mutable_self.insecure_tls,
            .auto_connect_on_launch = mutable_self.auto_connect_on_launch,
            .connect_host_override = mutable_self.connect_host_override,
            .default_workspace = mutable_self.default_workspace,
            .default_agent = mutable_self.default_agent,
            .workspace_tokens = mutable_self.workspace_tokens,
            .default_session = mutable_self.default_session,
            .connection_profiles = try makeConnectionProfileJsonSlice(self.allocator, mutable_self.connection_profiles),
            .selected_profile_id = mutable_self.selected_profile_id,
            .recent_workspaces = try makeRecentWorkspaceJsonSlice(self.allocator, mutable_self.recent_workspaces),
            .workspace_layout_index = try makeWorkspaceLayoutJsonSlice(self.allocator, mutable_self.workspace_layout_index),
            .app_local_nodes = try makeAppLocalNodeJsonSlice(self.allocator, mutable_self.app_local_nodes),
            .update_manifest_url = mutable_self.update_manifest_url,
            .theme_mode = themeModeName(mutable_self.theme_mode),
            .theme_pack = mutable_self.theme_pack,
            .watch_theme_pack = mutable_self.watch_theme_pack,
            .theme_pack_recent = mutable_self.theme_pack_recent,
            .theme_profile = themeProfileName(mutable_self.theme_profile),
            .terminal_backend = mutable_self.terminal_backend,
            .gui_verbose_ws_logs = mutable_self.gui_verbose_ws_logs,
            .window_x = mutable_self.window_x,
            .window_y = mutable_self.window_y,
            .window_width = mutable_self.window_width,
            .window_height = mutable_self.window_height,
        };
        defer {
            if (payload.connection_profiles) |values| self.allocator.free(values);
            if (payload.recent_workspaces) |values| self.allocator.free(values);
            if (payload.workspace_layout_index) |values| self.allocator.free(values);
            if (payload.app_local_nodes) |values| self.allocator.free(values);
        }

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
    schema_version: ?u32 = null,
    server_url: ?[]const u8 = null,
    admin_token: ?[]const u8 = null,
    user_token: ?[]const u8 = null,
    active_role: ?[]const u8 = null,
    insecure_tls: ?bool = null,
    auto_connect_on_launch: ?bool = null,
    connect_host_override: ?[]const u8 = null,
    default_workspace: ?[]const u8 = null,
    default_agent: ?[]const u8 = null,
    workspace_tokens: ?[]const WorkspaceTokenEntry = null,
    default_session: ?[]const u8 = null,
    connection_profiles: ?[]const ConnectionProfileJson = null,
    selected_profile_id: ?[]const u8 = null,
    recent_workspaces: ?[]const RecentWorkspaceJson = null,
    workspace_layout_index: ?[]const WorkspaceLayoutJson = null,
    app_local_nodes: ?[]const AppLocalNodeJson = null,
    update_manifest_url: ?[]const u8 = null,
    theme_mode: ?[]const u8 = null,
    theme_pack: ?[]const u8 = null,
    watch_theme_pack: ?bool = null,
    theme_pack_recent: ?[]const []const u8 = null,
    theme_profile: ?[]const u8 = null,
    terminal_backend: ?[]const u8 = null,
    gui_verbose_ws_logs: ?bool = null,
    window_x: ?i32 = null,
    window_y: ?i32 = null,
    window_width: ?i32 = null,
    window_height: ?i32 = null,
};

const LegacyProfileSeed = struct {
    server_url: []const u8,
    active_role: Config.TokenRole,
    insecure_tls: bool,
    connect_host_override: ?[]const u8,
};

const ConnectionProfileJson = struct {
    id: ?[]const u8 = null,
    name: ?[]const u8 = null,
    server_url: ?[]const u8 = null,
    active_role: ?[]const u8 = null,
    insecure_tls: ?bool = null,
    connect_host_override: ?[]const u8 = null,
    metadata: ?[]const u8 = null,
};

const RecentWorkspaceJson = struct {
    profile_id: []const u8,
    workspace_id: []const u8,
    workspace_name: ?[]const u8 = null,
    opened_at_ms: ?i64 = null,
};

const WorkspaceLayoutJson = struct {
    profile_id: []const u8,
    workspace_id: []const u8,
    layout_path: []const u8,
    updated_at_ms: ?i64 = null,
};

const AppLocalNodeJson = struct {
    profile_id: []const u8,
    node_name: []const u8,
    node_id: []const u8,
    node_secret: []const u8,
};

fn profileIndexByIdList(profiles: []const ConnectionProfile, profile_id: []const u8) ?usize {
    for (profiles, 0..) |profile, idx| {
        if (std.mem.eql(u8, profile.id, profile_id)) return idx;
    }
    return null;
}

fn makeConnectionProfileJsonSlice(
    allocator: std.mem.Allocator,
    profiles: []const ConnectionProfile,
) !?[]ConnectionProfileJson {
    if (profiles.len == 0) return null;
    const out = try allocator.alloc(ConnectionProfileJson, profiles.len);
    for (profiles, 0..) |profile, idx| {
        out[idx] = .{
            .id = profile.id,
            .name = profile.name,
            .server_url = profile.server_url,
            .active_role = tokenRoleName(profile.active_role),
            .insecure_tls = profile.insecure_tls,
            .connect_host_override = profile.connect_host_override,
            .metadata = profile.metadata,
        };
    }
    return out;
}

fn makeRecentWorkspaceJsonSlice(
    allocator: std.mem.Allocator,
    entries: ?[]const RecentWorkspaceEntry,
) !?[]RecentWorkspaceJson {
    const list = entries orelse return null;
    if (list.len == 0) return try allocator.alloc(RecentWorkspaceJson, 0);
    const out = try allocator.alloc(RecentWorkspaceJson, list.len);
    for (list, 0..) |entry, idx| {
        out[idx] = .{
            .profile_id = entry.profile_id,
            .workspace_id = entry.workspace_id,
            .workspace_name = entry.workspace_name,
            .opened_at_ms = entry.opened_at_ms,
        };
    }
    return out;
}

fn makeWorkspaceLayoutJsonSlice(
    allocator: std.mem.Allocator,
    entries: ?[]const WorkspaceLayoutEntry,
) !?[]WorkspaceLayoutJson {
    const list = entries orelse return null;
    if (list.len == 0) return try allocator.alloc(WorkspaceLayoutJson, 0);
    const out = try allocator.alloc(WorkspaceLayoutJson, list.len);
    for (list, 0..) |entry, idx| {
        out[idx] = .{
            .profile_id = entry.profile_id,
            .workspace_id = entry.workspace_id,
            .layout_path = entry.layout_path,
            .updated_at_ms = entry.updated_at_ms,
        };
    }
    return out;
}

fn makeAppLocalNodeJsonSlice(
    allocator: std.mem.Allocator,
    entries: ?[]const AppLocalNodeEntry,
) !?[]AppLocalNodeJson {
    const list = entries orelse return null;
    if (list.len == 0) return try allocator.alloc(AppLocalNodeJson, 0);
    const out = try allocator.alloc(AppLocalNodeJson, list.len);
    for (list, 0..) |entry, idx| {
        out[idx] = .{
            .profile_id = entry.profile_id,
            .node_name = entry.node_name,
            .node_id = entry.node_id,
            .node_secret = entry.node_secret,
        };
    }
    return out;
}

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

test "config rejects missing schema version" {
    const legacy_json =
        \\{
        \\  "server_url": "ws://legacy:18790",
        \\  "active_role": "user",
        \\  "insecure_tls": true,
        \\  "connect_host_override": "legacy-host",
        \\  "default_workspace": "workspace-a"
        \\}
    ;

    try std.testing.expectError(error.UnsupportedConfigSchema, Config.loadFromJsonSlice(std.testing.allocator, legacy_json));
}

fn parseThemeMode(value: ?[]const u8) Config.ThemeMode {
    if (value) |raw| {
        if (std.ascii.eqlIgnoreCase(raw, "light")) return .light;
        if (std.ascii.eqlIgnoreCase(raw, "dark")) return .dark;
    }
    return .pack_default;
}

fn themeModeName(mode: Config.ThemeMode) []const u8 {
    return switch (mode) {
        .pack_default => "pack_default",
        .light => "light",
        .dark => "dark",
    };
}

fn parseThemeProfile(value: ?[]const u8) Config.ThemeProfile {
    if (value) |raw| {
        if (std.ascii.eqlIgnoreCase(raw, "desktop")) return .desktop;
        if (std.ascii.eqlIgnoreCase(raw, "phone")) return .phone;
        if (std.ascii.eqlIgnoreCase(raw, "tablet")) return .tablet;
        if (std.ascii.eqlIgnoreCase(raw, "fullscreen")) return .fullscreen;
    }
    return .auto;
}

fn themeProfileName(profile: Config.ThemeProfile) []const u8 {
    return switch (profile) {
        .auto => "auto",
        .desktop => "desktop",
        .phone => "phone",
        .tablet => "tablet",
        .fullscreen => "fullscreen",
    };
}

fn deletePath(path: []const u8) !void {
    if (std.fs.path.isAbsolute(path)) {
        return std.fs.deleteFileAbsolute(path);
    }
    return std.fs.cwd().deleteFile(path);
}

fn renamePath(old_path: []const u8, new_path: []const u8) !void {
    if (std.fs.path.isAbsolute(old_path) and std.fs.path.isAbsolute(new_path)) {
        return std.fs.renameAbsolute(old_path, new_path);
    }
    return std.fs.cwd().rename(old_path, new_path);
}

test "theme config uses modern keys and round-trips" {
    var config = try Config.init(std.testing.allocator);
    defer config.deinit();

    config.setThemeMode(.dark);
    try config.setThemePack("themes/custom_pack");
    config.setWatchThemePack(true);
    config.setThemeProfile(.tablet);
    try std.testing.expect(config.rememberThemePack("themes/custom_pack"));
    try std.testing.expect(config.rememberThemePack("themes/secondary_pack"));

    const payload = ConfigJson{
        .theme_mode = themeModeName(config.theme_mode),
        .theme_pack = config.theme_pack,
        .watch_theme_pack = config.watch_theme_pack,
        .theme_pack_recent = config.theme_pack_recent,
        .theme_profile = themeProfileName(config.theme_profile),
    };
    const bytes = try std.json.Stringify.valueAlloc(std.testing.allocator, payload, .{
        .emit_null_optional_fields = false,
    });
    defer std.testing.allocator.free(bytes);

    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"theme_mode\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"theme_pack\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"watch_theme_pack\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"theme_pack_recent\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"theme_profile\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"ui_theme\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"ui_theme_pack\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"ui_profile\"") == null);

    var loaded = try Config.loadFromJsonSlice(std.testing.allocator, bytes);
    defer loaded.deinit();

    try std.testing.expectEqual(Config.ThemeMode.dark, loaded.theme_mode);
    try std.testing.expectEqual(Config.ThemeProfile.tablet, loaded.theme_profile);
    try std.testing.expect(loaded.watch_theme_pack);
    try std.testing.expect(loaded.theme_pack != null);
    try std.testing.expectEqualStrings("themes/custom_pack", loaded.theme_pack.?);
    try std.testing.expect(loaded.theme_pack_recent != null);
    try std.testing.expectEqual(@as(usize, 2), loaded.theme_pack_recent.?.len);
    try std.testing.expectEqualStrings("themes/secondary_pack", loaded.theme_pack_recent.?[0]);
    try std.testing.expectEqualStrings("themes/custom_pack", loaded.theme_pack_recent.?[1]);
}

test "unsupported config backup path stays alongside config file" {
    const backup_path = try Config.unsupportedConfigBackupPath(std.testing.allocator, "/tmp/spider/config.json");
    defer std.testing.allocator.free(backup_path);

    try std.testing.expectEqualStrings("/tmp/spider/config.unsupported-schema.backup.json", backup_path);
}

test "selected profile falls back to first available profile when id is invalid" {
    const json =
        \\{
        \\  "schema_version": 2,
        \\  "server_url": "ws://legacy-only",
        \\  "connection_profiles": [
        \\    { "id": "alpha", "name": "Alpha", "server_url": "ws://alpha:18790", "active_role": "admin" },
        \\    { "id": "beta", "name": "Beta", "server_url": "ws://beta:18790", "active_role": "user" }
        \\  ],
        \\  "selected_profile_id": "missing"
        \\}
    ;

    var config = try Config.loadFromJsonSlice(std.testing.allocator, json);
    defer config.deinit();

    try std.testing.expectEqualStrings("alpha", config.selectedProfileId());
    try std.testing.expectEqualStrings("ws://alpha:18790", config.server_url);
    try std.testing.expectEqual(Config.TokenRole.admin, config.active_role);
}

test "workspace layout index upserts by profile and workspace" {
    var config = try Config.init(std.testing.allocator);
    defer config.deinit();

    try config.setWorkspaceLayoutPath("default", "workspace-a", "/tmp/layout-a.json");
    try std.testing.expect(config.workspaceLayoutPath("default", "workspace-a") != null);
    try std.testing.expectEqualStrings(
        "/tmp/layout-a.json",
        config.workspaceLayoutPath("default", "workspace-a").?,
    );
    try std.testing.expectEqual(@as(usize, 1), config.workspace_layout_index.?.len);

    try config.setWorkspaceLayoutPath("default", "workspace-a", "/tmp/layout-b.json");
    try std.testing.expectEqual(@as(usize, 1), config.workspace_layout_index.?.len);
    try std.testing.expectEqualStrings(
        "/tmp/layout-b.json",
        config.workspaceLayoutPath("default", "workspace-a").?,
    );
}

test "recent workspaces are deduplicated per profile and workspace" {
    var config = try Config.init(std.testing.allocator);
    defer config.deinit();

    try config.recordRecentWorkspace("default", "workspace-a", "Workspace A");
    try std.testing.expectEqual(@as(usize, 1), config.recent_workspaces.?.len);
    try std.testing.expectEqualStrings("Workspace A", config.recent_workspaces.?[0].workspace_name.?);

    try config.recordRecentWorkspace("default", "workspace-a", "Workspace A (Renamed)");
    try std.testing.expectEqual(@as(usize, 1), config.recent_workspaces.?.len);
    try std.testing.expectEqualStrings("Workspace A (Renamed)", config.recent_workspaces.?[0].workspace_name.?);
    try std.testing.expect(config.recent_workspaces.?[0].opened_at_ms > 0);
}

test "workspace config ignores legacy project keys" {
    const json =
        \\{
        \\  "schema_version": 2,
        \\  "default_project": "legacy-project",
        \\  "project_tokens": [
        \\    { "project_id": "legacy-project", "token": "legacy-token" }
        \\  ],
        \\  "recent_projects": [
        \\    { "profile_id": "default", "project_id": "legacy-project", "project_name": "Legacy Project" }
        \\  ]
        \\}
    ;

    var config = try Config.loadFromJsonSlice(std.testing.allocator, json);
    defer config.deinit();

    try std.testing.expect(config.default_workspace == null);
    try std.testing.expect(config.workspace_tokens == null);
    try std.testing.expect(config.recent_workspaces == null);
}

test "config stores app-local node identity per profile" {
    var config = try Config.init(std.testing.allocator);
    defer config.deinit();

    try config.setAppLocalNode("default", "spiderapp-default", "node-42", "secret-xyz");
    const stored = config.appLocalNode("default") orelse return error.TestExpectedResponse;
    try std.testing.expectEqualStrings("spiderapp-default", stored.node_name);
    try std.testing.expectEqualStrings("node-42", stored.node_id);
    try std.testing.expectEqualStrings("secret-xyz", stored.node_secret);
}

test "config loads app-local node identities from json" {
    const json =
        \\{
        \\  "schema_version": 2,
        \\  "server_url": "ws://127.0.0.1:18790",
        \\  "app_local_nodes": [
        \\    {
        \\      "profile_id": "default",
        \\      "node_name": "spiderapp-default",
        \\      "node_id": "node-7",
        \\      "node_secret": "secret-7"
        \\    }
        \\  ]
        \\}
    ;

    var config = try Config.loadFromJsonSlice(std.testing.allocator, json);
    defer config.deinit();

    const stored = config.appLocalNode("default") orelse return error.TestExpectedResponse;
    try std.testing.expectEqualStrings("spiderapp-default", stored.node_name);
    try std.testing.expectEqualStrings("node-7", stored.node_id);
    try std.testing.expectEqualStrings("secret-7", stored.node_secret);
}
