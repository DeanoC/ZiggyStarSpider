// wizards/workspace_setup.zig
// Interactive workspace creation wizard.
// Invoked via `spider workspace up --interactive`.
//
// Flow:
//   Step 1 — Template selection (list from API, or skip for "dev")
//   Step 2 — Workspace name + optional vision
//   Step 3 — Mount configuration (auto-discover or pick a node)
//   Step 4 — Bind configuration (optional, iterative)
//   Step 5 — Summary review → confirm → create

const std = @import("std");
const args = @import("../args.zig");
const tui = @import("../tui.zig");
const ctx = @import("../client_context.zig");
const control_plane = @import("control_plane");
const workspace_types = control_plane.workspace_types;
const unified = @import("spider-protocol").unified;
const vd = @import("../venom_discovery.zig");
const workspace_ops = @import("../../client/workspace_operations.zig");

// ── Internal plan structs ────────────────────────────────────────────────────

const MountSpec = struct {
    mount_path: []const u8,
    node_id: []const u8,
    export_name: []const u8,
};

const BindSpec = struct {
    bind_path: []const u8,
    target_path: []const u8,
};

const SetupPlan = struct {
    name: []u8,
    vision: []u8,
    template_id: ?[]u8,
    mounts: std.ArrayListUnmanaged(MountSpec),
    binds: std.ArrayListUnmanaged(BindSpec),

    fn deinit(self: *SetupPlan, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.vision);
        if (self.template_id) |t| allocator.free(t);
        self.mounts.deinit(allocator);
        self.binds.deinit(allocator);
        self.* = undefined;
    }
};

// ── Entry point ──────────────────────────────────────────────────────────────

pub fn run(allocator: std.mem.Allocator, options: args.Options) !void {
    const stdout = std.fs.File.stdout().deprecatedWriter();

    tui.writeAnsi(stdout, tui.BOLD ++ tui.BLUE);
    try stdout.writeAll("\n╔══════════════════════════════════════╗\n");
    try stdout.writeAll("║   Spider — Workspace Setup Wizard    ║\n");
    try stdout.writeAll("╚══════════════════════════════════════╝\n");
    tui.writeAnsi(stdout, tui.RESET);
    tui.printInfo("Press Ctrl-C at any time to cancel.");

    const client = try ctx.getOrCreateClient(allocator, options);
    try ctx.ensureUnifiedV2Control(allocator, client);

    var plan = SetupPlan{
        .name = try allocator.dupe(u8, ""),
        .vision = try allocator.dupe(u8, ""),
        .template_id = null,
        .mounts = .{},
        .binds = .{},
    };
    defer plan.deinit(allocator);

    // ── Step 1: Template ──────────────────────────────────────────────────────
    tui.printStep(1, 5, "Choose a workspace template");

    var templates = control_plane.listWorkspaceTemplates(
        allocator,
        client,
        &ctx.g_control_request_counter,
    ) catch blk: {
        tui.printInfo("Could not fetch templates (using 'dev'): check connection.");
        break :blk std.ArrayListUnmanaged(workspace_types.WorkspaceTemplate){};
    };
    defer workspace_types.deinitWorkspaceTemplateList(allocator, &templates);

    if (templates.items.len > 0) {
        var labels = try allocator.alloc([]const u8, templates.items.len + 1);
        defer allocator.free(labels);
        labels[0] = "(no template — dev mode)";
        for (templates.items, 1..) |t, i| {
            const label = try std.fmt.allocPrint(allocator, "{s}  —  {s}", .{ t.id, t.description });
            labels[i] = label;
        }
        defer for (labels[1..]) |l| allocator.free(l);

        const choice = try tui.select(allocator, "Available templates:", labels);
        if (choice > 0) {
            plan.template_id = try allocator.dupe(u8, templates.items[choice - 1].id);
        }
    } else {
        tui.printInfo("No templates available — workspace will use dev mode.");
    }

    // ── Step 2: Name + Vision ─────────────────────────────────────────────────
    tui.printStep(2, 5, "Name your workspace");

    const name = try tui.prompt(allocator, "Workspace name", "Workspace");
    defer allocator.free(name);
    allocator.free(plan.name);
    plan.name = try allocator.dupe(u8, name);

    const vision = try tui.prompt(allocator, "Vision / purpose (optional)", null);
    defer allocator.free(vision);
    allocator.free(plan.vision);
    plan.vision = try allocator.dupe(u8, vision);

    // ── Step 3: Mounts ────────────────────────────────────────────────────────
    tui.printStep(3, 5, "Configure node mounts");

    // Try auto-discover first
    var default_mount = vd.discoverDefaultFsMount(allocator, client, .{
        .agent_id = null,
        .workspace_id = null,
    }) catch null;
    defer if (default_mount) |*m| m.deinit(allocator);

    if (default_mount) |dm| {
        if (dm.mount_path.len > 0) {
            var info_buf: [256]u8 = undefined;
            const info = std.fmt.bufPrint(&info_buf, "Auto-discovered: node={s}  path={s}", .{ dm.node_id, dm.mount_path }) catch dm.mount_path;
            tui.printInfo(info);
            const use_auto = try tui.confirm("Use this auto-discovered mount?", true);
            if (use_auto) {
                try plan.mounts.append(allocator, .{
                    .mount_path = dm.mount_path,
                    .node_id = dm.node_id,
                    .export_name = "work",
                });
            }
        }
    }

    if (plan.mounts.items.len == 0) {
        // Let user pick from node list
        var nodes = control_plane.listNodes(
            allocator,
            client,
            &ctx.g_control_request_counter,
        ) catch blk: {
            tui.printError("Could not list nodes — you can add mounts after creation.");
            break :blk std.ArrayListUnmanaged(workspace_types.NodeInfo){};
        };
        defer workspace_types.deinitNodeList(allocator, &nodes);

        if (nodes.items.len > 0) {
            const now_ms = std.time.milliTimestamp();
            var node_labels = try allocator.alloc([]const u8, nodes.items.len);
            defer allocator.free(node_labels);
            for (nodes.items, 0..) |node, i| {
                const online = node.lease_expires_at_ms > now_ms;
                node_labels[i] = try std.fmt.allocPrint(
                    allocator,
                    "{s}  ({s})  [{s}]",
                    .{ node.node_name, node.node_id, if (online) "online" else "offline" },
                );
            }
            defer for (node_labels) |l| allocator.free(l);

            const node_choice = try tui.selectOptional(allocator, "Select a node to mount:", node_labels);
            if (node_choice) |ni| {
                const node = &nodes.items[ni];
                const mount_path_input = try tui.prompt(allocator, "Mount path", "/nodes/local");
                defer allocator.free(mount_path_input);
                try plan.mounts.append(allocator, .{
                    .mount_path = try allocator.dupe(u8, mount_path_input),
                    .node_id = try allocator.dupe(u8, node.node_id),
                    .export_name = "work",
                });
            }
        } else {
            tui.printInfo("No nodes available. You can add mounts later with `spider workspace mount add`.");
        }
    }

    // Allow adding more mounts
    while (plan.mounts.items.len > 0) {
        const add_more = try tui.confirm("Add another mount?", false);
        if (!add_more) break;

        var nodes = control_plane.listNodes(
            allocator,
            client,
            &ctx.g_control_request_counter,
        ) catch break;
        defer workspace_types.deinitNodeList(allocator, &nodes);

        if (nodes.items.len == 0) {
            tui.printInfo("No nodes available.");
            break;
        }

        const now_ms = std.time.milliTimestamp();
        var node_labels = try allocator.alloc([]const u8, nodes.items.len);
        defer allocator.free(node_labels);
        for (nodes.items, 0..) |node, i| {
            const online = node.lease_expires_at_ms > now_ms;
            node_labels[i] = try std.fmt.allocPrint(
                allocator,
                "{s}  ({s})  [{s}]",
                .{ node.node_name, node.node_id, if (online) "online" else "offline" },
            );
        }
        defer for (node_labels) |l| allocator.free(l);

        const node_choice = tui.selectOptional(allocator, "Select a node:", node_labels) catch break;
        const ni = node_choice orelse break;
        const node = &nodes.items[ni];
        const mount_path_input = try tui.prompt(allocator, "Mount path", "/nodes/extra");
        defer allocator.free(mount_path_input);
        try plan.mounts.append(allocator, .{
            .mount_path = try allocator.dupe(u8, mount_path_input),
            .node_id = try allocator.dupe(u8, node.node_id),
            .export_name = "work",
        });
    }

    // ── Step 4: Binds ─────────────────────────────────────────────────────────
    tui.printStep(4, 5, "Configure venom binds (optional)");
    tui.printInfo("Binds connect workspace paths to venom endpoints.");
    tui.printInfo("Format: bind_path=target_path  (e.g. /.spiderweb/venoms/git=/nodes/local/venoms/git)");

    while (true) {
        const add_bind = try tui.confirm("Add a venom bind?", false);
        if (!add_bind) break;

        const bind_path = try tui.prompt(allocator, "Bind path (workspace side)", null);
        defer allocator.free(bind_path);
        if (bind_path.len == 0) break;

        const target_path = try tui.prompt(allocator, "Target path (provider side)", null);
        defer allocator.free(target_path);
        if (target_path.len == 0) break;

        try plan.binds.append(allocator, .{
            .bind_path = try allocator.dupe(u8, bind_path),
            .target_path = try allocator.dupe(u8, target_path),
        });
        var buf: [256]u8 = undefined;
        const info = std.fmt.bufPrint(&buf, "Added bind: {s}  →  {s}", .{ bind_path, target_path }) catch bind_path;
        tui.printSuccess(info);
    }

    // ── Step 5: Summary + confirm ─────────────────────────────────────────────
    tui.printStep(5, 5, "Review and confirm");

    try stdout.writeAll("\n");
    tui.printSummaryRow("Name:", plan.name);
    tui.printSummaryRow("Vision:", if (plan.vision.len > 0) plan.vision else "(none)");
    tui.printSummaryRow("Template:", plan.template_id orelse "dev");

    if (plan.mounts.items.len == 0) {
        tui.printSummaryRow("Mounts:", "(none — add later)");
    } else {
        for (plan.mounts.items, 0..) |m, i| {
            var label_buf: [32]u8 = undefined;
            const label = std.fmt.bufPrint(&label_buf, "Mount {d}:", .{i + 1}) catch "Mount:";
            var val_buf: [256]u8 = undefined;
            const val = std.fmt.bufPrint(&val_buf, "{s}  →  node:{s}", .{ m.mount_path, m.node_id }) catch m.mount_path;
            tui.printSummaryRow(label, val);
        }
    }

    for (plan.binds.items, 0..) |b, i| {
        var label_buf: [32]u8 = undefined;
        const label = std.fmt.bufPrint(&label_buf, "Bind {d}:", .{i + 1}) catch "Bind:";
        var val_buf: [256]u8 = undefined;
        const val = std.fmt.bufPrint(&val_buf, "{s}  →  {s}", .{ b.bind_path, b.target_path }) catch b.bind_path;
        tui.printSummaryRow(label, val);
    }
    try stdout.writeByte('\n');

    const ok = try tui.confirm("Create this workspace?", true);
    if (!ok) {
        tui.printInfo("Cancelled. No workspace was created.");
        return;
    }

    // ── Execute ───────────────────────────────────────────────────────────────
    try stdout.writeAll("\n");
    tui.printInfo("Creating workspace...");

    try executeCreateWorkspace(allocator, client, &plan, options);
}

fn executeCreateWorkspace(
    allocator: std.mem.Allocator,
    client: anytype,
    plan: *const SetupPlan,
    options: args.Options,
) !void {
    const stdout = std.fs.File.stdout().deprecatedWriter();

    // Build mount/bind slices for the shared operations module.
    var mounts = try allocator.alloc(workspace_ops.MountSpec, plan.mounts.items.len);
    defer allocator.free(mounts);
    for (plan.mounts.items, 0..) |m, i| {
        mounts[i] = .{
            .mount_path = m.mount_path,
            .node_id = m.node_id,
            .export_name = m.export_name,
        };
    }
    var binds = try allocator.alloc(workspace_ops.BindSpec, plan.binds.items.len);
    defer allocator.free(binds);
    for (plan.binds.items, 0..) |b, i| {
        binds[i] = .{ .bind_path = b.bind_path, .target_path = b.target_path };
    }

    const setup_plan = workspace_ops.WorkspaceSetupPlan{
        .name = plan.name,
        .vision = if (plan.vision.len > 0) plan.vision else null,
        .template_id = plan.template_id,
        .activate = true,
        .mounts = mounts,
        .binds = binds,
    };

    var result = try workspace_ops.executeSetupPlan(
        allocator,
        client,
        &ctx.g_control_request_counter,
        &setup_plan,
    );
    defer result.deinit(allocator);

    // Persist selection
    var cfg = try ctx.loadCliConfig(allocator);
    defer cfg.deinit();
    try cfg.setSelectedWorkspace(result.workspace_id);
    if (result.workspace_token) |token| try cfg.setWorkspaceToken(result.workspace_id, token);
    try cfg.save();

    _ = options;

    tui.printSuccess("Workspace created successfully!");
    try stdout.writeByte('\n');
    tui.printSummaryRow("Workspace ID:", result.workspace_id);
    tui.printSummaryRow("Name:", plan.name);
    tui.printSummaryRow("Status:", "active (selected)");
    try stdout.writeByte('\n');
    tui.printInfo("Run `spider workspace status` to check mount health.");
    tui.printInfo("Run `spider workspace doctor` to diagnose any issues.");
    try stdout.writeByte('\n');
}
