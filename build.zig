const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "zombotvpn",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    exe.linkLibC();
    exe.defineCMacro("INI_MAX_LINE", "1000");
    exe.addIncludePath(b.path("deps/inih"));
    exe.addCSourceFile(.{
        .file = b.path("deps/inih/ini.c"),
        .flags = &.{},
    });

    b.installArtifact(exe);
}
