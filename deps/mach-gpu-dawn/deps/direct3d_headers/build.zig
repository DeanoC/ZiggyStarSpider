const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const root_module = b.createModule(.{
        .root_source_file = b.path("build.zig"),
        .target = target,
        .optimize = optimize,
    });
    const lib = b.addLibrary(.{
        .name = "direct3d-headers",
        .root_module = root_module,
    });
    b.installArtifact(lib);
}

pub fn addLibraryPath(step: *std.Build.Step.Compile) void {
    _ = step;
}

pub fn addLibraryPathToModule(module: *std.Build.Module) void {
    _ = module;
}
