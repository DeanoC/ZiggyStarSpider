// Package commands: list, catalog, updates, update, update-all, get,
// channel-get, channel-set, channel-clear, install, enable, switch,
// disable, rollback, remove

const std = @import("std");
const args = @import("../args.zig");
const logger = @import("ziggy-core").utils.logger;
const unified = @import("spider-protocol").unified;
const ctx = @import("../client_context.zig");
const fsrpc = @import("../fsrpc.zig");
const output = @import("../output.zig");
const vd = @import("../venom_discovery.zig");

const packages_control_root = "/.spiderweb/control/packages";

const jsonObjectStringOr = vd.jsonObjectStringOr;
const jsonObjectBoolOr = vd.jsonObjectBoolOr;

fn jsonObjectUsizeOr(obj: std.json.ObjectMap, name: []const u8, fallback: usize) usize {
    const value = obj.get(name) orelse return fallback;
    return switch (value) {
        .integer => if (value.integer >= 0) @intCast(value.integer) else fallback,
        .string => std.fmt.parseUnsigned(usize, value.string, 10) catch fallback,
        else => fallback,
    };
}

fn packageClient(allocator: std.mem.Allocator, options: args.Options) !*@import("../../client/websocket.zig").WebSocketClient {
    const client = try ctx.getOrCreateClient(allocator, options);
    try ctx.maybeApplyWorkspaceContext(allocator, options, client);
    try fsrpc.fsrpcBootstrap(allocator, client);
    return client;
}

fn buildPackagesControlPath(allocator: std.mem.Allocator, leaf: []const u8) ![]u8 {
    return fsrpc.joinFsPath(allocator, packages_control_root, leaf);
}

fn writePackageControlAndReadResult(
    allocator: std.mem.Allocator,
    client: *@import("../../client/websocket.zig").WebSocketClient,
    control_name: []const u8,
    payload: []const u8,
) ![]u8 {
    const control_dir = try buildPackagesControlPath(allocator, "control");
    defer allocator.free(control_dir);
    const control_path = try fsrpc.joinFsPath(allocator, control_dir, control_name);
    defer allocator.free(control_path);
    try fsrpc.fsrpcWritePathText(allocator, client, control_path, payload);

    const result_path = try buildPackagesControlPath(allocator, "result.json");
    defer allocator.free(result_path);
    return fsrpc.fsrpcReadPathText(allocator, client, result_path);
}

fn parseEnvelope(allocator: std.mem.Allocator, raw: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, allocator, raw, .{});
}

fn ensureEnvelopeOk(parsed: *const std.json.Parsed(std.json.Value)) !std.json.ObjectMap {
    if (parsed.value != .object) return error.InvalidResponse;
    const root = parsed.value.object;
    if (!jsonObjectBoolOr(root, "ok", false)) {
        if (root.get("error")) |err_value| {
            if (err_value == .object) {
                const message = jsonObjectStringOr(err_value.object, "message", "package operation failed");
                logger.err("{s}", .{message});
            }
        }
        return error.RemoteError;
    }
    return root;
}

fn optionalJsonString(allocator: std.mem.Allocator, value: ?[]const u8) ![]u8 {
    if (value) |text| {
        const escaped = try unified.jsonEscape(allocator, text);
        defer allocator.free(escaped);
        return std.fmt.allocPrint(allocator, "\"{s}\"", .{escaped});
    }
    return allocator.dupe(u8, "null");
}

fn buildIdPayload(allocator: std.mem.Allocator, package_id: []const u8, release_version: ?[]const u8) ![]u8 {
    const escaped_id = try unified.jsonEscape(allocator, package_id);
    defer allocator.free(escaped_id);
    const release_json = try optionalJsonString(allocator, release_version);
    defer allocator.free(release_json);
    return std.fmt.allocPrint(
        allocator,
        "{{\"venom_id\":\"{s}\",\"release_version\":{s}}}",
        .{ escaped_id, release_json },
    );
}

fn buildCatalogPayload(allocator: std.mem.Allocator, package_id: ?[]const u8, channel: ?[]const u8) ![]u8 {
    const id_json = try optionalJsonString(allocator, package_id);
    defer allocator.free(id_json);
    const channel_json = try optionalJsonString(allocator, channel);
    defer allocator.free(channel_json);
    return std.fmt.allocPrint(
        allocator,
        "{{\"venom_id\":{s},\"channel\":{s}}}",
        .{ id_json, channel_json },
    );
}

fn buildGetPayload(
    allocator: std.mem.Allocator,
    package_id: []const u8,
    release_version: ?[]const u8,
    source: ?[]const u8,
    channel: ?[]const u8,
) ![]u8 {
    const escaped_id = try unified.jsonEscape(allocator, package_id);
    defer allocator.free(escaped_id);
    const release_json = try optionalJsonString(allocator, release_version);
    defer allocator.free(release_json);
    const source_json = try optionalJsonString(allocator, source);
    defer allocator.free(source_json);
    const channel_json = try optionalJsonString(allocator, channel);
    defer allocator.free(channel_json);
    return std.fmt.allocPrint(
        allocator,
        "{{\"venom_id\":\"{s}\",\"release_version\":{s},\"source\":{s},\"channel\":{s}}}",
        .{ escaped_id, release_json, source_json, channel_json },
    );
}

fn buildUpdatePayload(
    allocator: std.mem.Allocator,
    package_id: []const u8,
    release_version: ?[]const u8,
    channel: ?[]const u8,
    activate: bool,
) ![]u8 {
    const escaped_id = try unified.jsonEscape(allocator, package_id);
    defer allocator.free(escaped_id);
    const release_json = try optionalJsonString(allocator, release_version);
    defer allocator.free(release_json);
    const channel_json = try optionalJsonString(allocator, channel);
    defer allocator.free(channel_json);
    return std.fmt.allocPrint(
        allocator,
        "{{\"venom_id\":\"{s}\",\"release_version\":{s},\"channel\":{s},\"activate\":{s}}}",
        .{ escaped_id, release_json, channel_json, if (activate) "true" else "false" },
    );
}

fn buildUpdateAllPayload(
    allocator: std.mem.Allocator,
    package_ids: []const []const u8,
    apply: bool,
    activate: bool,
) ![]u8 {
    var packages_json = std.ArrayListUnmanaged(u8){};
    defer packages_json.deinit(allocator);
    try packages_json.append(allocator, '[');
    for (package_ids, 0..) |package_id, idx| {
        if (idx != 0) try packages_json.append(allocator, ',');
        const escaped = try unified.jsonEscape(allocator, package_id);
        defer allocator.free(escaped);
        try packages_json.writer(allocator).print("\"{s}\"", .{escaped});
    }
    try packages_json.append(allocator, ']');
    return std.fmt.allocPrint(
        allocator,
        "{{\"apply\":{s},\"activate\":{s},\"packages\":{s}}}",
        .{
            if (apply) "true" else "false",
            if (activate) "true" else "false",
            packages_json.items,
        },
    );
}

fn buildChannelPayload(allocator: std.mem.Allocator, package_id: ?[]const u8, channel: ?[]const u8) ![]u8 {
    const id_json = try optionalJsonString(allocator, package_id);
    defer allocator.free(id_json);
    const channel_json = try optionalJsonString(allocator, channel);
    defer allocator.free(channel_json);
    return std.fmt.allocPrint(
        allocator,
        "{{\"venom_id\":{s},\"channel\":{s}}}",
        .{ id_json, channel_json },
    );
}

fn loadInstallPayload(allocator: std.mem.Allocator, cmd: args.Command) ![]u8 {
    if (cmd.args.len == 0) return error.InvalidArguments;
    const first = cmd.args[0];
    if (first.len > 1 and first[0] == '@') {
        return std.fs.cwd().readFileAlloc(allocator, first[1..], 1024 * 1024);
    }
    if (first.len > 0 and (first[0] == '{' or first[0] == '[')) {
        return std.mem.join(allocator, " ", cmd.args);
    }

    var package_id: ?[]const u8 = null;
    var release_version: ?[]const u8 = null;
    var channel: ?[]const u8 = null;
    var i: usize = 0;
    while (i < cmd.args.len) : (i += 1) {
        const arg = cmd.args[i];
        if (std.mem.eql(u8, arg, "--release")) {
            i += 1;
            if (i >= cmd.args.len) return error.InvalidArguments;
            release_version = cmd.args[i];
            continue;
        }
        if (std.mem.eql(u8, arg, "--channel")) {
            i += 1;
            if (i >= cmd.args.len) return error.InvalidArguments;
            channel = cmd.args[i];
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--")) return error.InvalidArguments;
        if (package_id != null) return error.InvalidArguments;
        package_id = arg;
    }
    const value = package_id orelse return error.InvalidArguments;
    const escaped_id = try unified.jsonEscape(allocator, value);
    defer allocator.free(escaped_id);
    const release_json = try optionalJsonString(allocator, release_version);
    defer allocator.free(release_json);
    const channel_json = try optionalJsonString(allocator, channel);
    defer allocator.free(channel_json);
    return std.fmt.allocPrint(
        allocator,
        "{{\"venom_id\":\"{s}\",\"source\":\"registry\",\"release_version\":{s},\"channel\":{s}}}",
        .{ escaped_id, release_json, channel_json },
    );
}

fn printPackageTable(stdout: anytype, allocator: std.mem.Allocator, result_obj: std.json.ObjectMap) !void {
    const packages_value = result_obj.get("packages") orelse return error.InvalidResponse;
    if (packages_value != .array) return error.InvalidResponse;
    if (packages_value.array.items.len == 0) {
        try stdout.writeAll("(no packages)\n");
        return;
    }

    if (result_obj.get("registry")) |registry_value| {
        if (registry_value == .object) {
            try stdout.print(
                "Registry: enabled={}  channel={s}  source={s}\n\n",
                .{
                    jsonObjectBoolOr(registry_value.object, "enabled", false),
                    jsonObjectStringOr(registry_value.object, "default_channel", "(none)"),
                    jsonObjectStringOr(registry_value.object, "source_url", "(none)"),
                },
            );
        }
    }

    var tbl = try output.Table.init(allocator, &.{ "Package", "Active", "Latest", "Channel", "Enabled", "Update" });
    defer tbl.deinit();
    for (packages_value.array.items) |item| {
        if (item != .object) continue;
        const obj = item.object;
        try tbl.row(&.{
            jsonObjectStringOr(obj, "package_id", jsonObjectStringOr(obj, "venom_id", "(unknown)")),
            jsonObjectStringOr(obj, "active_release_version", jsonObjectStringOr(obj, "release_version", "-")),
            jsonObjectStringOr(obj, "latest_release_version", "-"),
            jsonObjectStringOr(obj, "effective_channel", jsonObjectStringOr(obj, "registry_channel", "-")),
            if (jsonObjectBoolOr(obj, "enabled", true)) "yes" else "no",
            if (jsonObjectBoolOr(obj, "update_available", false)) "yes" else "no",
        });
    }
    try tbl.print(stdout, ctx.stdoutSupportsAnsi());
}

fn printUpdatesTable(stdout: anytype, allocator: std.mem.Allocator, result_obj: std.json.ObjectMap) !void {
    const updates_value = result_obj.get("updates") orelse return error.InvalidResponse;
    if (updates_value != .array) return error.InvalidResponse;
    if (updates_value.array.items.len == 0) {
        try stdout.writeAll("(no updates)\n");
        return;
    }

    var tbl = try output.Table.init(allocator, &.{ "Package", "Installed", "Latest", "Channel", "Update" });
    defer tbl.deinit();
    for (updates_value.array.items) |item| {
        if (item != .object) continue;
        const obj = item.object;
        try tbl.row(&.{
            jsonObjectStringOr(obj, "package_id", jsonObjectStringOr(obj, "venom_id", "(unknown)")),
            jsonObjectStringOr(obj, "installed_release_version", "-"),
            jsonObjectStringOr(obj, "latest_release_version", "-"),
            jsonObjectStringOr(obj, "latest_release_channel", jsonObjectStringOr(obj, "effective_channel", "-")),
            if (jsonObjectBoolOr(obj, "update_available", false)) "yes" else "no",
        });
    }
    try tbl.print(stdout, ctx.stdoutSupportsAnsi());
}

fn printPackageInfo(stdout: anytype, allocator: std.mem.Allocator, result_obj: std.json.ObjectMap) !void {
    _ = allocator;
    const package_value = result_obj.get("package") orelse result_obj.get("release") orelse return error.InvalidResponse;
    if (package_value != .object) return error.InvalidResponse;
    const obj = package_value.object;

    try stdout.print("Package {s}\n", .{jsonObjectStringOr(obj, "package_id", jsonObjectStringOr(obj, "venom_id", "(unknown)"))});
    try stdout.print("  Kind: {s}\n", .{jsonObjectStringOr(obj, "kind", "(unknown)")});
    try stdout.print("  Enabled: {s}\n", .{if (jsonObjectBoolOr(obj, "enabled", true)) "true" else "false"});
    try stdout.print("  Runtime: {s}\n", .{jsonObjectStringOr(obj, "runtime_kind", "(unknown)")});
    try stdout.print("  Active release: {s}\n", .{jsonObjectStringOr(obj, "active_release_version", jsonObjectStringOr(obj, "release_version", "(none)"))});
    try stdout.print("  Latest release: {s}\n", .{jsonObjectStringOr(obj, "latest_release_version", "(none)")});
    try stdout.print("  Effective channel: {s}\n", .{jsonObjectStringOr(obj, "effective_channel", jsonObjectStringOr(obj, "registry_channel", "(none)"))});
    try stdout.print("  Channel override: {s}\n", .{jsonObjectStringOr(obj, "channel_override", "(none)")});
    try stdout.print("  Installed releases: {d}\n", .{jsonObjectUsizeOr(obj, "installed_release_count", 0)});
    try stdout.print("  Update available: {s}\n", .{if (jsonObjectBoolOr(obj, "update_available", false)) "true" else "false"});
    try stdout.print("  Release history entries: {d}\n", .{jsonObjectUsizeOr(obj, "release_history_count", 0)});
    if (obj.get("last_release_action")) |value| {
        if (value == .string) try stdout.print("  Last action: {s}\n", .{value.string});
    }
    if (obj.get("last_release_version")) |value| {
        if (value == .string) try stdout.print("  Last action version: {s}\n", .{value.string});
    }
    if (obj.get("help_md")) |value| {
        if (value == .string and value.string.len > 0) {
            try stdout.print("\n{s}\n", .{value.string});
        }
    }
}

fn printEnvelopeJson(stdout: anytype, allocator: std.mem.Allocator, raw_json: []const u8) !void {
    try output.printJson(stdout, allocator, raw_json);
}

pub fn executePackageList(allocator: std.mem.Allocator, options: args.Options, cmd: args.Command) !void {
    _ = cmd;
    const stdout = std.fs.File.stdout().deprecatedWriter();
    const client = try packageClient(allocator, options);
    const raw = try writePackageControlAndReadResult(allocator, client, "list.json", "{}");
    defer allocator.free(raw);
    if (options.json) return printEnvelopeJson(stdout, allocator, raw);

    var parsed = try parseEnvelope(allocator, raw);
    defer parsed.deinit();
    const root = try ensureEnvelopeOk(&parsed);
    const result = root.get("result") orelse return error.InvalidResponse;
    if (result != .object) return error.InvalidResponse;
    try printPackageTable(stdout, allocator, result.object);
}

pub fn executePackageCatalog(allocator: std.mem.Allocator, options: args.Options, cmd: args.Command) !void {
    var package_id: ?[]const u8 = null;
    var channel: ?[]const u8 = null;
    var i: usize = 0;
    while (i < cmd.args.len) : (i += 1) {
        const arg = cmd.args[i];
        if (std.mem.eql(u8, arg, "--channel")) {
            i += 1;
            if (i >= cmd.args.len) return error.InvalidArguments;
            channel = cmd.args[i];
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--")) return error.InvalidArguments;
        if (package_id != null) return error.InvalidArguments;
        package_id = arg;
    }

    const payload = try buildCatalogPayload(allocator, package_id, channel);
    defer allocator.free(payload);
    const stdout = std.fs.File.stdout().deprecatedWriter();
    const client = try packageClient(allocator, options);
    const raw = try writePackageControlAndReadResult(allocator, client, "catalog.json", payload);
    defer allocator.free(raw);
    try printEnvelopeJson(stdout, allocator, raw);
}

pub fn executePackageUpdates(allocator: std.mem.Allocator, options: args.Options, cmd: args.Command) !void {
    _ = cmd;
    const stdout = std.fs.File.stdout().deprecatedWriter();
    const client = try packageClient(allocator, options);
    const raw = try writePackageControlAndReadResult(allocator, client, "updates.json", "{}");
    defer allocator.free(raw);
    if (options.json) return printEnvelopeJson(stdout, allocator, raw);

    var parsed = try parseEnvelope(allocator, raw);
    defer parsed.deinit();
    const root = try ensureEnvelopeOk(&parsed);
    const result = root.get("result") orelse return error.InvalidResponse;
    if (result != .object) return error.InvalidResponse;
    try printUpdatesTable(stdout, allocator, result.object);
}

pub fn executePackageGet(allocator: std.mem.Allocator, options: args.Options, cmd: args.Command) !void {
    if (cmd.args.len == 0) return error.InvalidArguments;
    var package_id: ?[]const u8 = null;
    var release_version: ?[]const u8 = null;
    var source: ?[]const u8 = null;
    var channel: ?[]const u8 = null;
    var i: usize = 0;
    while (i < cmd.args.len) : (i += 1) {
        const arg = cmd.args[i];
        if (std.mem.eql(u8, arg, "--release")) {
            i += 1;
            if (i >= cmd.args.len) return error.InvalidArguments;
            release_version = cmd.args[i];
            continue;
        }
        if (std.mem.eql(u8, arg, "--source")) {
            i += 1;
            if (i >= cmd.args.len) return error.InvalidArguments;
            source = cmd.args[i];
            continue;
        }
        if (std.mem.eql(u8, arg, "--channel")) {
            i += 1;
            if (i >= cmd.args.len) return error.InvalidArguments;
            channel = cmd.args[i];
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--")) return error.InvalidArguments;
        if (package_id != null) return error.InvalidArguments;
        package_id = arg;
    }

    const selected_package_id = package_id orelse return error.InvalidArguments;
    const payload = try buildGetPayload(allocator, selected_package_id, release_version, source, channel);
    defer allocator.free(payload);
    const stdout = std.fs.File.stdout().deprecatedWriter();
    const client = try packageClient(allocator, options);
    const raw = try writePackageControlAndReadResult(allocator, client, "get.json", payload);
    defer allocator.free(raw);
    if (options.json) return printEnvelopeJson(stdout, allocator, raw);

    var parsed = try parseEnvelope(allocator, raw);
    defer parsed.deinit();
    const root = try ensureEnvelopeOk(&parsed);
    const result = root.get("result") orelse return error.InvalidResponse;
    if (result != .object) return error.InvalidResponse;
    try printPackageInfo(stdout, allocator, result.object);
}

pub fn executePackageInstall(allocator: std.mem.Allocator, options: args.Options, cmd: args.Command) !void {
    const payload = try loadInstallPayload(allocator, cmd);
    defer allocator.free(payload);
    const stdout = std.fs.File.stdout().deprecatedWriter();
    const client = try packageClient(allocator, options);
    const raw = try writePackageControlAndReadResult(allocator, client, "install.json", payload);
    defer allocator.free(raw);
    try printEnvelopeJson(stdout, allocator, raw);
}

pub fn executePackageEnable(allocator: std.mem.Allocator, options: args.Options, cmd: args.Command) !void {
    if (cmd.args.len == 0) return error.InvalidArguments;
    const payload = try buildIdPayload(allocator, cmd.args[0], null);
    defer allocator.free(payload);
    const stdout = std.fs.File.stdout().deprecatedWriter();
    const client = try packageClient(allocator, options);
    const raw = try writePackageControlAndReadResult(allocator, client, "enable.json", payload);
    defer allocator.free(raw);
    try printEnvelopeJson(stdout, allocator, raw);
}

pub fn executePackageDisable(allocator: std.mem.Allocator, options: args.Options, cmd: args.Command) !void {
    if (cmd.args.len == 0) return error.InvalidArguments;
    const payload = try buildIdPayload(allocator, cmd.args[0], null);
    defer allocator.free(payload);
    const stdout = std.fs.File.stdout().deprecatedWriter();
    const client = try packageClient(allocator, options);
    const raw = try writePackageControlAndReadResult(allocator, client, "disable.json", payload);
    defer allocator.free(raw);
    try printEnvelopeJson(stdout, allocator, raw);
}

pub fn executePackageRemove(allocator: std.mem.Allocator, options: args.Options, cmd: args.Command) !void {
    if (cmd.args.len == 0) return error.InvalidArguments;
    const payload = try buildIdPayload(allocator, cmd.args[0], if (cmd.args.len > 1) cmd.args[1] else null);
    defer allocator.free(payload);
    const stdout = std.fs.File.stdout().deprecatedWriter();
    const client = try packageClient(allocator, options);
    const raw = try writePackageControlAndReadResult(allocator, client, "remove.json", payload);
    defer allocator.free(raw);
    try printEnvelopeJson(stdout, allocator, raw);
}

pub fn executePackageUpdate(allocator: std.mem.Allocator, options: args.Options, cmd: args.Command) !void {
    if (cmd.args.len == 0) return error.InvalidArguments;
    var package_id: ?[]const u8 = null;
    var release_version: ?[]const u8 = null;
    var channel: ?[]const u8 = null;
    var activate = false;
    var i: usize = 0;
    while (i < cmd.args.len) : (i += 1) {
        const arg = cmd.args[i];
        if (std.mem.eql(u8, arg, "--release")) {
            i += 1;
            if (i >= cmd.args.len) return error.InvalidArguments;
            release_version = cmd.args[i];
            continue;
        }
        if (std.mem.eql(u8, arg, "--channel")) {
            i += 1;
            if (i >= cmd.args.len) return error.InvalidArguments;
            channel = cmd.args[i];
            continue;
        }
        if (std.mem.eql(u8, arg, "--activate")) {
            activate = true;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--")) return error.InvalidArguments;
        if (package_id != null) return error.InvalidArguments;
        package_id = arg;
    }

    const selected_package_id = package_id orelse return error.InvalidArguments;
    const payload = try buildUpdatePayload(allocator, selected_package_id, release_version, channel, activate);
    defer allocator.free(payload);
    const stdout = std.fs.File.stdout().deprecatedWriter();
    const client = try packageClient(allocator, options);
    const raw = try writePackageControlAndReadResult(allocator, client, "update.json", payload);
    defer allocator.free(raw);
    try printEnvelopeJson(stdout, allocator, raw);
}

pub fn executePackageUpdateAll(allocator: std.mem.Allocator, options: args.Options, cmd: args.Command) !void {
    var package_ids = std.ArrayListUnmanaged([]const u8){};
    defer package_ids.deinit(allocator);
    var apply = false;
    var activate = false;
    for (cmd.args) |arg| {
        if (std.mem.eql(u8, arg, "--apply")) {
            apply = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--activate")) {
            activate = true;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--")) return error.InvalidArguments;
        try package_ids.append(allocator, arg);
    }

    const payload = try buildUpdateAllPayload(allocator, package_ids.items, apply, activate);
    defer allocator.free(payload);
    const stdout = std.fs.File.stdout().deprecatedWriter();
    const client = try packageClient(allocator, options);
    const raw = try writePackageControlAndReadResult(allocator, client, "update_all.json", payload);
    defer allocator.free(raw);
    try printEnvelopeJson(stdout, allocator, raw);
}

pub fn executePackageChannelGet(allocator: std.mem.Allocator, options: args.Options, cmd: args.Command) !void {
    const payload = try buildChannelPayload(allocator, if (cmd.args.len > 0) cmd.args[0] else null, null);
    defer allocator.free(payload);
    const stdout = std.fs.File.stdout().deprecatedWriter();
    const client = try packageClient(allocator, options);
    const raw = try writePackageControlAndReadResult(allocator, client, "channel_get.json", payload);
    defer allocator.free(raw);
    try printEnvelopeJson(stdout, allocator, raw);
}

pub fn executePackageChannelSet(allocator: std.mem.Allocator, options: args.Options, cmd: args.Command) !void {
    if (cmd.args.len == 0) return error.InvalidArguments;
    const channel = cmd.args[0];
    const package_id = if (cmd.args.len > 1) cmd.args[1] else null;
    const payload = try buildChannelPayload(allocator, package_id, channel);
    defer allocator.free(payload);
    const stdout = std.fs.File.stdout().deprecatedWriter();
    const client = try packageClient(allocator, options);
    const raw = try writePackageControlAndReadResult(allocator, client, "channel_set.json", payload);
    defer allocator.free(raw);
    try printEnvelopeJson(stdout, allocator, raw);
}

pub fn executePackageChannelClear(allocator: std.mem.Allocator, options: args.Options, cmd: args.Command) !void {
    if (cmd.args.len == 0) return error.InvalidArguments;
    const payload = try buildChannelPayload(allocator, cmd.args[0], null);
    defer allocator.free(payload);
    const stdout = std.fs.File.stdout().deprecatedWriter();
    const client = try packageClient(allocator, options);
    const raw = try writePackageControlAndReadResult(allocator, client, "channel_clear.json", payload);
    defer allocator.free(raw);
    try printEnvelopeJson(stdout, allocator, raw);
}

pub fn executePackageSwitch(allocator: std.mem.Allocator, options: args.Options, cmd: args.Command) !void {
    if (cmd.args.len < 2) return error.InvalidArguments;
    const payload = try buildIdPayload(allocator, cmd.args[0], cmd.args[1]);
    defer allocator.free(payload);
    const stdout = std.fs.File.stdout().deprecatedWriter();
    const client = try packageClient(allocator, options);
    const raw = try writePackageControlAndReadResult(allocator, client, "switch.json", payload);
    defer allocator.free(raw);
    try printEnvelopeJson(stdout, allocator, raw);
}

pub fn executePackageRollback(allocator: std.mem.Allocator, options: args.Options, cmd: args.Command) !void {
    if (cmd.args.len == 0) return error.InvalidArguments;
    const payload = try buildIdPayload(allocator, cmd.args[0], if (cmd.args.len > 1) cmd.args[1] else null);
    defer allocator.free(payload);
    const stdout = std.fs.File.stdout().deprecatedWriter();
    const client = try packageClient(allocator, options);
    const raw = try writePackageControlAndReadResult(allocator, client, "rollback.json", payload);
    defer allocator.free(raw);
    try printEnvelopeJson(stdout, allocator, raw);
}
