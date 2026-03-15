const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("open_responses", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    const exe = b.addExecutable(.{
        .name = "open-responses-demo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "open_responses", .module = mod },
            },
        }),
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run the demo");
    run_step.dependOn(&run_cmd.step);

    const mod_tests = b.addTest(.{
        .root_module = mod,
    });

    const run_mod_tests = b.addRunArtifact(mod_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_mod_tests.step);

    const integration_mod = b.createModule(.{
        .root_source_file = b.path("src/integration_test.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{},
    });

    const integration_tests = b.addTest(.{
        .root_module = integration_mod,
    });

    const run_integration_tests = b.addRunArtifact(integration_tests);
    const integration_step = b.step("test-integration", "Run integration tests against fixture server");
    integration_step.dependOn(&run_integration_tests.step);

    const client_test_mod = b.createModule(.{
        .root_source_file = b.path("src/client_test.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{},
    });

    const client_tests = b.addTest(.{
        .root_module = client_test_mod,
    });

    const run_client_tests = b.addRunArtifact(client_tests);
    const client_test_step = b.step("test-client", "Run client integration tests");
    client_test_step.dependOn(&run_client_tests.step);

    const all_step = b.step("test-all", "Run all tests");
    all_step.dependOn(&run_mod_tests.step);
    all_step.dependOn(&run_integration_tests.step);
    all_step.dependOn(&run_client_tests.step);
}
