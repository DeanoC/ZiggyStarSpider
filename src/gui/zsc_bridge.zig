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
    };
};

pub const platform = struct {
    pub const sdl3 = struct {
        pub const c = @cImport({
            @cInclude("SDL3/SDL.h");
        });
    };
};
