const std = @import("std");

pub fn build(b: *std.build.Builder) void {
    // Standard release options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall.
    const mode = b.standardOptimizeOption(.{});
    const target = b.standardTargetOptions(.{});

    const linux_example = b.addExecutable(.{
        .name = "socketpair-example",
        .root_source_file = .{
            .path = "examples/linux.zig",
        },
        .optimize = mode,
        .target = target,
    });
    linux_example.addAnonymousModule("antiphony", .{
        .source_file = .{ .path = "src/antiphony.zig" },
        .dependencies = &.{
            .{
                .name = "s2s",
                .module = b.addModule("s2s", .{
                    .source_file = .{ .path = "vendor/s2s/s2s.zig" },
                }),
            }
        },
    });
    linux_example.install();

    const main_tests = b.addTest(.{
        .name = "antiphony",
        .root_source_file = .{
            .path = "src/antiphony.zig"
        },
        .target = target,
        .optimize = mode,
    });
    main_tests.addAnonymousModule("s2s", .{
        .source_file = .{ .path = "vendor/s2s/s2s.zig" },
    });

    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&main_tests.step);
}
