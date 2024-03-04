const std = @import("std");

pub fn build(b: *std.Build) void {
    // Standard release options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall.
    const mode = b.standardOptimizeOption(.{});
    const target = b.standardTargetOptions(.{});
    const local_module = b.addModule("antiphony", .{
        .root_source_file = .{ .path = "src/antiphony.zig" },
    });
    const s2s_dep = b.dependency("s2s", .{});
    const s2s_mod = s2s_dep.module("s2s");
    local_module.addImport("s2s",s2s_mod );

    const linux_example = b.addExecutable(.{
        .name = "socketpair-example",
        .root_source_file = .{
            .path = "examples/linux.zig",
        },
        .optimize = mode,
        .target = target,
    });
    linux_example.root_module.addImport("antiphony", local_module);

    b.installArtifact(linux_example);

    const main_tests = b.addTest(.{
        .name = "antiphony",
        .root_source_file = .{
            .path = "src/antiphony.zig"
        },
        .target = target,
        .optimize = mode,
    });
    main_tests.root_module.addImport("s2s", s2s_mod);

    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&main_tests.step);
}
