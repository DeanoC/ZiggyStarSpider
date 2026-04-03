const std = @import("std");
const builtin = @import("builtin");
const config_mod = @import("config.zig");

pub const ProviderKind = enum {
    windows_credential_manager,
    macos_keychain,
    file_fallback,
};

const windows_not_found_error: u32 = 1168;
const macos_keychain_service = "com.deanocalver.spiderapp";

fn hexEncodeAlloc(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    const alphabet = "0123456789abcdef";
    const out = try allocator.alloc(u8, bytes.len * 2);
    for (bytes, 0..) |byte, idx| {
        out[idx * 2] = alphabet[byte >> 4];
        out[idx * 2 + 1] = alphabet[byte & 0x0f];
    }
    return out;
}

pub const CredentialStore = struct {
    allocator: std.mem.Allocator,
    provider: ProviderKind,
    fallback_dir: []u8,
    warned_unsupported: bool = false,

    pub fn init(allocator: std.mem.Allocator) !CredentialStore {
        const config_dir = try config_mod.Config.getConfigDir(allocator);
        defer allocator.free(config_dir);

        const fallback_dir = try std.fs.path.join(allocator, &.{ config_dir, "credentials" });
        const provider: ProviderKind = switch (builtin.os.tag) {
            .windows => .windows_credential_manager,
            .macos => .macos_keychain,
            else => .file_fallback,
        };

        var out = CredentialStore{
            .allocator = allocator,
            .provider = provider,
            .fallback_dir = fallback_dir,
            .warned_unsupported = false,
        };

        if (out.provider == .file_fallback) {
            out.warnFallbackProvider();
        }

        return out;
    }

    pub fn initForTesting(
        allocator: std.mem.Allocator,
        provider: ProviderKind,
        fallback_dir: []const u8,
    ) !CredentialStore {
        return .{
            .allocator = allocator,
            .provider = provider,
            .fallback_dir = try allocator.dupe(u8, fallback_dir),
            .warned_unsupported = false,
        };
    }

    pub fn deinit(self: *CredentialStore) void {
        self.allocator.free(self.fallback_dir);
        self.* = undefined;
    }

    pub fn providerKind(self: *const CredentialStore) ProviderKind {
        return self.provider;
    }

    pub fn save(
        self: *CredentialStore,
        profile_id: []const u8,
        key: []const u8,
        secret: []const u8,
    ) !void {
        const target = try self.makeTargetName(profile_id, key);
        defer self.allocator.free(target);

        switch (self.provider) {
            .windows_credential_manager => {
                if (builtin.os.tag == .windows) {
                    return try windows_provider.save(self.allocator, target, secret);
                }
                self.warnFallbackProvider();
                self.provider = .file_fallback;
                return self.saveFallback(target, secret);
            },
            .macos_keychain => {
                if (builtin.os.tag == .macos) {
                    return macos_provider.save(self.allocator, target, secret);
                }
                self.warnFallbackProvider();
                self.provider = .file_fallback;
                return self.saveFallback(target, secret);
            },
            .file_fallback => {
                self.warnFallbackProvider();
                return self.saveFallback(target, secret);
            },
        }
    }

    pub fn load(
        self: *CredentialStore,
        profile_id: []const u8,
        key: []const u8,
    ) !?[]u8 {
        const target = try self.makeTargetName(profile_id, key);
        defer self.allocator.free(target);

        switch (self.provider) {
            .windows_credential_manager => {
                if (builtin.os.tag == .windows) {
                    return windows_provider.load(self.allocator, target);
                }
                self.warnFallbackProvider();
                self.provider = .file_fallback;
                return self.loadFallback(target);
            },
            .macos_keychain => {
                if (builtin.os.tag == .macos) {
                    if (try macos_provider.load(self.allocator, target)) |secret| {
                        return secret;
                    }
                    if (try self.loadFallback(target)) |secret| {
                        macos_provider.save(self.allocator, target, secret) catch |err| {
                            std.log.warn("CredentialStore: failed to migrate fallback credential to Keychain: {s}", .{@errorName(err)});
                            return secret;
                        };
                        self.deleteFallback(target) catch |err| {
                            std.log.warn("CredentialStore: failed to remove fallback credential after migration: {s}", .{@errorName(err)});
                        };
                        return secret;
                    }
                    return null;
                }
                self.warnFallbackProvider();
                self.provider = .file_fallback;
                return self.loadFallback(target);
            },
            .file_fallback => {
                self.warnFallbackProvider();
                return self.loadFallback(target);
            },
        }
    }

    pub fn delete(
        self: *CredentialStore,
        profile_id: []const u8,
        key: []const u8,
    ) !void {
        const target = try self.makeTargetName(profile_id, key);
        defer self.allocator.free(target);

        switch (self.provider) {
            .windows_credential_manager => {
                if (builtin.os.tag == .windows) {
                    return windows_provider.delete(target);
                }
                self.warnFallbackProvider();
                self.provider = .file_fallback;
                return self.deleteFallback(target);
            },
            .macos_keychain => {
                if (builtin.os.tag == .macos) {
                    try macos_provider.delete(self.allocator, target);
                    return self.deleteFallback(target);
                }
                self.warnFallbackProvider();
                self.provider = .file_fallback;
                return self.deleteFallback(target);
            },
            .file_fallback => {
                self.warnFallbackProvider();
                return self.deleteFallback(target);
            },
        }
    }

    fn warnFallbackProvider(self: *CredentialStore) void {
        if (self.warned_unsupported) return;
        self.warned_unsupported = true;
        std.log.warn(
            "CredentialStore: using plaintext fallback provider instead of the platform credential store",
            .{},
        );
    }

    fn makeTargetName(self: *CredentialStore, profile_id: []const u8, key: []const u8) ![]u8 {
        const profile_trimmed = std.mem.trim(u8, profile_id, " \t\r\n");
        const key_trimmed = std.mem.trim(u8, key, " \t\r\n");
        if (profile_trimmed.len == 0 or key_trimmed.len == 0) {
            return error.InvalidCredentialTarget;
        }
        return std.fmt.allocPrint(self.allocator, "SpiderApp/{s}/{s}", .{ profile_trimmed, key_trimmed });
    }

    fn fallbackLegacyFilePath(self: *CredentialStore, target: []const u8) ![]u8 {
        const hash = std.hash.Wyhash.hash(0, target);
        const name = try std.fmt.allocPrint(self.allocator, "{x:0>16}.cred", .{hash});
        defer self.allocator.free(name);
        return std.fs.path.join(self.allocator, &.{ self.fallback_dir, name });
    }

    fn fallbackFriendlyFilePath(self: *CredentialStore, target: []const u8) ![]u8 {
        const encoded = try hexEncodeAlloc(self.allocator, target);
        defer self.allocator.free(encoded);
        const name = try std.fmt.allocPrint(self.allocator, "target-{s}.cred2", .{encoded});
        defer self.allocator.free(name);
        return std.fs.path.join(self.allocator, &.{ self.fallback_dir, name });
    }

    fn saveFallback(self: *CredentialStore, target: []const u8, secret: []const u8) !void {
        try std.fs.cwd().makePath(self.fallback_dir);
        const friendly_path = try self.fallbackFriendlyFilePath(target);
        defer self.allocator.free(friendly_path);
        const legacy_path = try self.fallbackLegacyFilePath(target);
        defer self.allocator.free(legacy_path);

        var friendly_file = try std.fs.cwd().createFile(friendly_path, .{ .truncate = true });
        defer friendly_file.close();
        try friendly_file.writeAll(secret);

        var legacy_file = try std.fs.cwd().createFile(legacy_path, .{ .truncate = true });
        defer legacy_file.close();
        try legacy_file.writeAll(secret);
    }

    fn loadFallback(self: *CredentialStore, target: []const u8) !?[]u8 {
        const friendly_path = try self.fallbackFriendlyFilePath(target);
        defer self.allocator.free(friendly_path);
        const friendly = std.fs.cwd().readFileAlloc(self.allocator, friendly_path, 8192) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
        if (friendly != null) return friendly;

        const legacy_path = try self.fallbackLegacyFilePath(target);
        defer self.allocator.free(legacy_path);
        return std.fs.cwd().readFileAlloc(self.allocator, legacy_path, 8192) catch |err| switch (err) {
            error.FileNotFound => null,
            else => err,
        };
    }

    fn deleteFallback(self: *CredentialStore, target: []const u8) !void {
        const friendly_path = try self.fallbackFriendlyFilePath(target);
        defer self.allocator.free(friendly_path);
        std.fs.cwd().deleteFile(friendly_path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };

        const legacy_path = try self.fallbackLegacyFilePath(target);
        defer self.allocator.free(legacy_path);
        std.fs.cwd().deleteFile(legacy_path) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
    }
};

const macos_provider = if (builtin.os.tag == .macos) struct {
    const delete_not_found_error: u8 = 44;

    pub fn save(allocator: std.mem.Allocator, target: []const u8, secret: []const u8) !void {
        const result = try std.process.Child.run(.{
            .allocator = allocator,
            .argv = &.{
                "security",
                "add-generic-password",
                "-U",
                "-s",
                macos_keychain_service,
                "-a",
                target,
                "-l",
                target,
                "-w",
                secret,
            },
            .max_output_bytes = 32 * 1024,
        });
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);

        switch (result.term) {
            .Exited => |code| if (code == 0) return,
            else => {},
        }

        const stderr_text = std.mem.trim(u8, result.stderr, " \t\r\n");
        if (stderr_text.len > 0) {
            std.log.warn("security add-generic-password failed: {s}", .{stderr_text});
        }
        return error.CredentialStoreFailure;
    }

    pub fn load(allocator: std.mem.Allocator, target: []const u8) !?[]u8 {
        const result = try std.process.Child.run(.{
            .allocator = allocator,
            .argv = &.{
                "security",
                "find-generic-password",
                "-s",
                macos_keychain_service,
                "-a",
                target,
                "-w",
            },
            .max_output_bytes = 32 * 1024,
        });
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);

        switch (result.term) {
            .Exited => |code| if (code != 0) return null,
            else => return null,
        }

        const trimmed = std.mem.trimRight(u8, result.stdout, "\r\n");
        if (trimmed.len == 0) return null;
        return try allocator.dupe(u8, trimmed);
    }

    pub fn delete(allocator: std.mem.Allocator, target: []const u8) !void {
        const result = try std.process.Child.run(.{
            .allocator = allocator,
            .argv = &.{
                "security",
                "delete-generic-password",
                "-s",
                macos_keychain_service,
                "-a",
                target,
            },
            .max_output_bytes = 16 * 1024,
        });
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);

        switch (result.term) {
            .Exited => |code| if (code == 0 or code == delete_not_found_error) return,
            else => {},
        }

        const stderr_text = std.mem.trim(u8, result.stderr, " \t\r\n");
        if (stderr_text.len > 0) {
            std.log.warn("security delete-generic-password failed: {s}", .{stderr_text});
        }
        return error.CredentialStoreFailure;
    }
} else struct {
    pub fn save(_: std.mem.Allocator, _: []const u8, _: []const u8) !void {
        return error.UnsupportedPlatform;
    }

    pub fn load(_: std.mem.Allocator, _: []const u8) !?[]u8 {
        return error.UnsupportedPlatform;
    }

    pub fn delete(_: std.mem.Allocator, _: []const u8) !void {
        return error.UnsupportedPlatform;
    }
};

const windows_provider = if (builtin.os.tag == .windows) struct {
    const windows = std.os.windows;

    const DWORD = u32;

    const FILETIME = extern struct {
        dwLowDateTime: DWORD,
        dwHighDateTime: DWORD,
    };

    const CREDENTIAL_ATTRIBUTEW = extern struct {
        Keyword: [*:0]u16,
        Flags: DWORD,
        ValueSize: DWORD,
        Value: [*]u8,
    };

    const CREDENTIALW = extern struct {
        Flags: DWORD,
        Type: DWORD,
        TargetName: [*:0]u16,
        Comment: ?[*:0]u16,
        LastWritten: FILETIME,
        CredentialBlobSize: DWORD,
        CredentialBlob: ?[*]u8,
        Persist: DWORD,
        AttributeCount: DWORD,
        Attributes: ?*CREDENTIAL_ATTRIBUTEW,
        TargetAlias: ?[*:0]u16,
        UserName: ?[*:0]u16,
    };

    const CRED_TYPE_GENERIC: DWORD = 1;
    const CRED_PERSIST_LOCAL_MACHINE: DWORD = 2;

    extern "advapi32" fn CredWriteW(
        Credential: *const CREDENTIALW,
        Flags: DWORD,
    ) callconv(.winapi) windows.BOOL;

    extern "advapi32" fn CredReadW(
        TargetName: [*:0]const u16,
        Type: DWORD,
        Flags: DWORD,
        Credential: *?*CREDENTIALW,
    ) callconv(.winapi) windows.BOOL;

    extern "advapi32" fn CredDeleteW(
        TargetName: [*:0]const u16,
        Type: DWORD,
        Flags: DWORD,
    ) callconv(.winapi) windows.BOOL;

    extern "advapi32" fn CredFree(Buffer: *anyopaque) callconv(.winapi) void;

    extern "kernel32" fn GetLastError() callconv(.winapi) DWORD;

    fn mapWinError(code: DWORD) anyerror {
        return switch (code) {
            windows_not_found_error => error.CredentialNotFound,
            else => error.CredentialStoreFailure,
        };
    }

    pub fn save(allocator: std.mem.Allocator, target: []const u8, secret: []const u8) !void {
        const target_w = try std.unicode.utf8ToUtf16LeAllocZ(allocator, target);
        defer allocator.free(target_w);
        const username_w = try std.unicode.utf8ToUtf16LeAllocZ(allocator, "spider");
        defer allocator.free(username_w);

        var credential = CREDENTIALW{
            .Flags = 0,
            .Type = CRED_TYPE_GENERIC,
            .TargetName = target_w.ptr,
            .Comment = null,
            .LastWritten = .{ .dwLowDateTime = 0, .dwHighDateTime = 0 },
            .CredentialBlobSize = @intCast(secret.len),
            .CredentialBlob = if (secret.len > 0) @constCast(secret.ptr) else null,
            .Persist = CRED_PERSIST_LOCAL_MACHINE,
            .AttributeCount = 0,
            .Attributes = null,
            .TargetAlias = null,
            .UserName = username_w.ptr,
        };

        if (CredWriteW(&credential, 0) == 0) {
            return mapWinError(GetLastError());
        }
    }

    pub fn load(allocator: std.mem.Allocator, target: []const u8) !?[]u8 {
        const target_w = try std.unicode.utf8ToUtf16LeAllocZ(allocator, target);
        defer allocator.free(target_w);

        var raw: ?*CREDENTIALW = null;
        if (CredReadW(target_w.ptr, CRED_TYPE_GENERIC, 0, &raw) == 0) {
            const err = GetLastError();
            if (err == windows_not_found_error) return null;
            return mapWinError(err);
        }

        const credential = raw orelse return null;
        defer CredFree(@ptrCast(credential));

        const blob_size: usize = @intCast(credential.CredentialBlobSize);
        if (blob_size == 0 or credential.CredentialBlob == null) {
            return @as(?[]u8, try allocator.dupe(u8, ""));
        }

        const blob = credential.CredentialBlob.?[0..blob_size];
        return @as(?[]u8, try allocator.dupe(u8, blob));
    }

    pub fn delete(target: []const u8) !void {
        var gpa = std.heap.GeneralPurposeAllocator(.{}){};
        defer _ = gpa.deinit();
        const allocator = gpa.allocator();

        const target_w = try std.unicode.utf8ToUtf16LeAllocZ(allocator, target);
        defer allocator.free(target_w);

        if (CredDeleteW(target_w.ptr, CRED_TYPE_GENERIC, 0) == 0) {
            const err = GetLastError();
            if (err == windows_not_found_error) return;
            return mapWinError(err);
        }
    }
} else struct {
    pub fn save(_: std.mem.Allocator, _: []const u8, _: []const u8) !void {
        return error.UnsupportedPlatform;
    }

    pub fn load(_: std.mem.Allocator, _: []const u8) !?[]u8 {
        return error.UnsupportedPlatform;
    }

    pub fn delete(_: []const u8) !void {
        return error.UnsupportedPlatform;
    }
};

test "file fallback save/load/delete roundtrip" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const fallback_path = try tmp.dir.realpathAlloc(allocator, ".");
    var store = try CredentialStore.initForTesting(allocator, .file_fallback, fallback_path);
    defer store.deinit();

    try store.save("profile-a", "role-admin", "secret-token");

    const loaded = try store.load("profile-a", "role-admin");
    try std.testing.expect(loaded != null);
    defer if (loaded) |value| allocator.free(value);
    try std.testing.expectEqualStrings("secret-token", loaded.?);

    try store.delete("profile-a", "role-admin");
    const missing = try store.load("profile-a", "role-admin");
    try std.testing.expect(missing == null);
}

test "provider selection defaults by platform" {
    var store = try CredentialStore.init(std.testing.allocator);
    defer store.deinit();

    if (builtin.os.tag == .windows) {
        try std.testing.expectEqual(ProviderKind.windows_credential_manager, store.providerKind());
    } else if (builtin.os.tag == .macos) {
        try std.testing.expectEqual(ProviderKind.macos_keychain, store.providerKind());
    } else {
        try std.testing.expectEqual(ProviderKind.file_fallback, store.providerKind());
    }
}
