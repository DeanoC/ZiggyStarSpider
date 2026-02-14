const std = @import("std");

// Client configuration for ZiggyStarSpider

pub const Config = struct {
    allocator: std.mem.Allocator,
    
    // Connection settings
    server_url: []const u8,
    auth_token: []const u8,
    insecure_tls: bool = false,
    
    // UI settings
    auto_connect_on_launch: bool = true,
    default_project: ?[]const u8 = null,
    
    // Update settings
    update_manifest_url: []const u8,
    
    pub fn init(allocator: std.mem.Allocator) Config {
        return .{
            .allocator = allocator,
            .server_url = "ws://127.0.0.1:18790",
            .auth_token = "",
            .update_manifest_url = "https://github.com/DeanoC/ZiggyStarSpider/releases/latest/download/update.json",
        };
    }
    
    pub fn deinit(self: *Config) void {
        // Cleanup if needed
        _ = self;
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
        
        // Read file
        const data = std.fs.cwd().readFileAlloc(allocator, config_path, 65536) catch |err| switch (err) {
            error.FileNotFound => return Config.init(allocator),
            else => return err,
        };
        defer allocator.free(data);
        
        // Parse JSON
        var parsed = try std.json.parseFromSlice(ConfigJson, allocator, data, .{});
        defer parsed.deinit();
        
        const json = parsed.value;
        
        return .{
            .allocator = allocator,
            .server_url = try allocator.dupe(u8, json.server_url orelse "ws://127.0.0.1:18790"),
            .auth_token = try allocator.dupe(u8, json.auth_token orelse ""),
            .insecure_tls = json.insecure_tls orelse false,
            .auto_connect_on_launch = json.auto_connect_on_launch orelse true,
            .default_project = if (json.default_project) |p| try allocator.dupe(u8, p) else null,
            .update_manifest_url = try allocator.dupe(u8, json.update_manifest_url orelse "https://github.com/DeanoC/ZiggyStarSpider/releases/latest/download/update.json"),
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
        
        const json = ConfigJson{
            .server_url = self.server_url,
            .auth_token = self.auth_token,
            .insecure_tls = self.insecure_tls,
            .auto_connect_on_launch = self.auto_connect_on_launch,
            .default_project = self.default_project,
            .update_manifest_url = self.update_manifest_url,
        };
        
        // Write JSON directly to file
        var json_file = try std.fs.cwd().createFile(config_path, .{});
        defer json_file.close();
        
        var buf: [4096]u8 = undefined;
        var stream = std.io.fixedBufferStream(&buf);
        const writer = stream.writer();
        
        try writer.writeAll("{\n");
        try writer.writeAll("  \"server_url\": \"");
        try writer.writeAll(json.server_url orelse "");
        try writer.writeAll("\",\n");
        try writer.writeAll("  \"auth_token\": \"");
        try writer.writeAll(json.auth_token orelse "");
        try writer.writeAll("\",\n");
        try writer.writeAll("  \"insecure_tls\": ");
        try writer.writeAll(if (json.insecure_tls orelse false) "true" else "false");
        try writer.writeAll("\n");
        try writer.writeAll("}\n");
        
        try json_file.writeAll(buf[0..stream.pos]);
    }
};

// JSON-compatible config struct for serialization
const ConfigJson = struct {
    server_url: ?[]const u8 = null,
    auth_token: ?[]const u8 = null,
    insecure_tls: ?bool = null,
    auto_connect_on_launch: ?bool = null,
    default_project: ?[]const u8 = null,
    update_manifest_url: ?[]const u8 = null,
};
