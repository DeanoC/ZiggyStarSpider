const builtin = @import("builtin");

pub const android_pref_org = "DeanoC";
pub const android_pref_app = "SpiderApp";
pub const android_config_dir_name = "config";

pub fn isAndroid() bool {
    return builtin.target.abi.isAndroid();
}

pub fn supportsMultiWindow() bool {
    return !isAndroid();
}

pub fn supportsWindowGeometryPersistence() bool {
    return !isAndroid();
}

pub fn supportsThemePackWatch() bool {
    return builtin.target.os.tag != .emscripten and
        builtin.target.os.tag != .wasi and
        !isAndroid();
}

pub fn supportsThemePackBrowse() bool {
    return !isAndroid();
}

pub fn supportsThemePackRefresh() bool {
    return !isAndroid() and builtin.target.os.tag != .emscripten and builtin.target.os.tag != .wasi;
}

pub fn supportsWorkspaceSnapshots() bool {
    return !isAndroid();
}
