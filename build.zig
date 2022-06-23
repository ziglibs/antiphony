const std = @import("std");

const pkgs = struct {
    const s2s = std.build.Pkg{
        .name = "s2s",
        .source = .{ .path = "vendor/s2s/s2s.zig" },
    };
};

pub fn build(b: *std.build.Builder) void {
    // Standard release options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall.
    const mode = b.standardReleaseOptions();

    const linux_example = b.addExecutable("socketpair-example", "examples/linux.zig");
    linux_example.addPackage(.{
        .name = "antiphony",
        .source = .{ .path = "src/antiphony.zig" },
        .dependencies = &.{pkgs.s2s},
    });
    linux_example.install();

    const main_tests = b.addTest("src/antiphony.zig");
    main_tests.addPackage(pkgs.s2s);
    main_tests.setBuildMode(mode);

    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&main_tests.step);
}
