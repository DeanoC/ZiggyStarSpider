const std = @import("std");

pub const Stage = enum {
    launcher,
    workspace,
};

pub const OnboardingStage = enum {
    connect,
    choose_workspace,
    workspace_ready,
};

pub const HomeRoute = enum {
    workspace,
    devices,
    capabilities,
    explore,
    settings,
};

pub const ReturnReason = enum {
    none,
    switched_workspace,
    disconnected,
    connection_lost,
};

pub const State = struct {
    stage: Stage = .launcher,
    connected: bool = false,
    selected_workspace_id: ?[]const u8 = null,
    last_return_reason: ReturnReason = .none,
    onboarding_stage: OnboardingStage = .connect,
    home_route: HomeRoute = .workspace,

    pub fn canEnterWorkspace(self: *const State) bool {
        return self.connected and self.selected_workspace_id != null;
    }

    pub fn syncOnboardingStage(self: *State) void {
        self.onboarding_stage = if (!self.connected)
            .connect
        else if (self.selected_workspace_id == null)
            .choose_workspace
        else
            .workspace_ready;
    }

    pub fn setConnected(self: *State, connected: bool) void {
        self.connected = connected;
        if (!connected and self.stage == .workspace) {
            self.returnToLauncher(.disconnected);
        }
        self.syncOnboardingStage();
    }

    pub fn setSelectedWorkspace(self: *State, workspace_id: ?[]const u8) void {
        self.selected_workspace_id = workspace_id;
        if (workspace_id == null and self.stage == .workspace) {
            self.returnToLauncher(.disconnected);
        }
        self.syncOnboardingStage();
    }

    pub fn openWorkspace(self: *State, workspace_id: []const u8) !void {
        if (!self.connected) return error.ConnectionRequired;
        if (workspace_id.len == 0) return error.WorkspaceRequired;
        self.stage = .workspace;
        self.selected_workspace_id = workspace_id;
        self.last_return_reason = .none;
        self.syncOnboardingStage();
    }

    pub fn returnToLauncher(self: *State, reason: ReturnReason) void {
        self.stage = .launcher;
        self.last_return_reason = reason;
        self.syncOnboardingStage();
    }

    pub fn handleConnectionLoss(self: *State) void {
        self.connected = false;
        self.returnToLauncher(.connection_lost);
    }
};

test "workspace entry requires connected workspace selection" {
    var state = State{};
    try std.testing.expectError(error.ConnectionRequired, state.openWorkspace("alpha"));

    state.setConnected(true);
    try state.openWorkspace("alpha");
    try std.testing.expectEqual(Stage.workspace, state.stage);
}

test "disconnect forces workspace to launcher" {
    var state = State{
        .stage = .workspace,
        .connected = true,
        .selected_workspace_id = "alpha",
    };

    state.handleConnectionLoss();

    try std.testing.expectEqual(Stage.launcher, state.stage);
    try std.testing.expectEqual(ReturnReason.connection_lost, state.last_return_reason);
}

test "empty workspace id is rejected when opening workspace" {
    var state = State{
        .connected = true,
    };

    try std.testing.expectError(error.WorkspaceRequired, state.openWorkspace(""));
    try std.testing.expectEqual(Stage.launcher, state.stage);
}

test "setConnected false while in workspace returns to launcher" {
    var state = State{
        .stage = .workspace,
        .connected = true,
        .selected_workspace_id = "alpha",
    };

    state.setConnected(false);

    try std.testing.expectEqual(Stage.launcher, state.stage);
    try std.testing.expectEqual(ReturnReason.disconnected, state.last_return_reason);
}

test "clearing selected workspace in workspace returns to launcher" {
    var state = State{
        .stage = .workspace,
        .connected = true,
        .selected_workspace_id = "alpha",
    };

    state.setSelectedWorkspace(null);

    try std.testing.expectEqual(Stage.launcher, state.stage);
    try std.testing.expectEqual(ReturnReason.disconnected, state.last_return_reason);
}
