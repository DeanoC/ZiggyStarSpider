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
};
