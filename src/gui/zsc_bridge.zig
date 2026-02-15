pub const protocol = struct {
    pub const types = struct {
        pub const ChatAttachment = struct {
            kind: []const u8,
            url: []const u8,
            name: ?[]const u8 = null,
        };

        pub const LocalChatMessageState = enum {
            sending,
            failed,
        };

        pub const ChatMessage = struct {
            id: []const u8,
            role: []const u8,
            content: []const u8,
            timestamp: i64,
            attachments: ?[]ChatAttachment = null,
            local_state: ?LocalChatMessageState = null,
        };

        pub const ChatSession = struct {
            key: []const u8,
            display_name: ?[]const u8 = null,
            label: ?[]const u8 = null,
            kind: ?[]const u8 = null,
            updated_at: ?i64 = null,
            session_id: ?[]const u8 = null,
        };

        pub const ChatHistoryPayload = struct {
            session_key: []const u8,
            messages: ?[]ChatMessage = null,
        };

        pub const ChatSendRequest = struct {
            session_key: []const u8,
            message: []const u8,
            message_id: ?[]const u8 = null,
            attachments: ?[]ChatAttachment = null,
        };

        pub const ChatStreamChunk = struct {
            session_key: []const u8,
            run_id: []const u8,
            request_id: ?[]const u8 = null,
            message_id: []const u8,
            content_delta: []const u8,
        };

        pub const ChatStreamComplete = struct {
            session_key: []const u8,
            run_id: []const u8,
            request_id: ?[]const u8 = null,
            message_id: []const u8,
            final_content: []const u8,
        };

        pub const WindowProfile = struct {
            profile_name: []const u8,
            theme: ?[]const u8 = null,
            theme_pack: ?[]const u8 = null,
            ui_scale: ?f32 = null,
        };
    };

    pub const ui = struct {
        pub const WindowId = u32;
        pub const WindowStateMode = enum { attached, detached };
        pub const DockEdge = enum { left, right, top, bottom, tab };

        pub const WindowState = struct {
            window_id: WindowId,
            title: []const u8,
            session_key: ?[]const u8 = null,
            mode: WindowStateMode = .attached,
            profile_name: ?[]const u8 = null,
        };

        pub const WindowAction = union(enum) {
            open: WindowState,
            close: WindowId,
            detach: WindowId,
            attach: WindowId,
            close_request: WindowId,
            focus: WindowId,
            dock_to_edge: struct {
                window_id: WindowId,
                target: DockEdge,
            },
        };

        pub const AppSettings = struct {
            server_url: []const u8,
            auth_token: []const u8,
            ui_theme: ?[]const u8 = null,
            ui_theme_pack: ?[]const u8 = null,
            ui_profile: ?[]const u8 = null,
            auto_connect_on_launch: bool = true,
        };
    };
};

pub const platform = struct {
    pub const sdl3 = struct {
        pub const c = @cImport({
            @cInclude("SDL3/SDL.h");
        });
    };
};
