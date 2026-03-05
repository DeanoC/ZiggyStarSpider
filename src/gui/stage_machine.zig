const std = @import("std");

pub const Stage = enum {
    launcher,
    workspace,
};

pub const ReturnReason = enum {
    none,
    switched_project,
    disconnected,
    connection_lost,
};

pub const State = struct {
    stage: Stage = .launcher,
    connected: bool = false,
    selected_project_id: ?[]const u8 = null,
    last_return_reason: ReturnReason = .none,

    pub fn canEnterWorkspace(self: *const State) bool {
        return self.connected and self.selected_project_id != null;
    }

    pub fn setConnected(self: *State, connected: bool) void {
        self.connected = connected;
        if (!connected and self.stage == .workspace) {
            self.returnToLauncher(.disconnected);
        }
    }

    pub fn setSelectedProject(self: *State, project_id: ?[]const u8) void {
        self.selected_project_id = project_id;
        if (project_id == null and self.stage == .workspace) {
            self.returnToLauncher(.disconnected);
        }
    }

    pub fn openProject(self: *State, project_id: []const u8) !void {
        if (!self.connected) return error.ConnectionRequired;
        if (project_id.len == 0) return error.ProjectRequired;
        self.stage = .workspace;
        self.selected_project_id = project_id;
        self.last_return_reason = .none;
    }

    pub fn returnToLauncher(self: *State, reason: ReturnReason) void {
        self.stage = .launcher;
        self.last_return_reason = reason;
    }

    pub fn handleConnectionLoss(self: *State) void {
        self.connected = false;
        self.returnToLauncher(.connection_lost);
    }
};

test "workspace entry requires connected project selection" {
    var state = State{};
    try std.testing.expectError(error.ConnectionRequired, state.openProject("alpha"));

    state.setConnected(true);
    try state.openProject("alpha");
    try std.testing.expectEqual(Stage.workspace, state.stage);
}

test "disconnect forces workspace to launcher" {
    var state = State{
        .stage = .workspace,
        .connected = true,
        .selected_project_id = "alpha",
    };

    state.handleConnectionLoss();

    try std.testing.expectEqual(Stage.launcher, state.stage);
    try std.testing.expectEqual(ReturnReason.connection_lost, state.last_return_reason);
}

test "empty project id is rejected when opening workspace" {
    var state = State{
        .connected = true,
    };

    try std.testing.expectError(error.ProjectRequired, state.openProject(""));
    try std.testing.expectEqual(Stage.launcher, state.stage);
}

test "setConnected false while in workspace returns to launcher" {
    var state = State{
        .stage = .workspace,
        .connected = true,
        .selected_project_id = "alpha",
    };

    state.setConnected(false);

    try std.testing.expectEqual(Stage.launcher, state.stage);
    try std.testing.expectEqual(ReturnReason.disconnected, state.last_return_reason);
}

test "clearing selected project in workspace returns to launcher" {
    var state = State{
        .stage = .workspace,
        .connected = true,
        .selected_project_id = "alpha",
    };

    state.setSelectedProject(null);

    try std.testing.expectEqual(Stage.launcher, state.stage);
    try std.testing.expectEqual(ReturnReason.disconnected, state.last_return_reason);
}
