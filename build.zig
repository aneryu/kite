const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Library module
    const mod = b.addModule("kite", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .link_libc = true,
    });

    // Main executable
    const exe = b.addExecutable(.{
        .name = "kite",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "kite", .module = mod },
            },
        }),
    });

    // Link libdatachannel
    exe.root_module.addSystemIncludePath(.{ .cwd_relative = "/opt/homebrew/include" });
    exe.root_module.addLibraryPath(.{ .cwd_relative = "/opt/homebrew/lib" });
    exe.root_module.linkSystemLibrary("datachannel", .{});

    b.installArtifact(exe);

    // Run step
    const run_step = b.step("run", "Run kite");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // Tests
    // Link libdatachannel for library module (needed for tests)
    mod.addSystemIncludePath(.{ .cwd_relative = "/opt/homebrew/include" });
    mod.addLibraryPath(.{ .cwd_relative = "/opt/homebrew/lib" });
    mod.linkSystemLibrary("datachannel", .{});

    const mod_tests = b.addTest(.{
        .root_module = mod,
    });
    const run_mod_tests = b.addRunArtifact(mod_tests);

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });
    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);
}
