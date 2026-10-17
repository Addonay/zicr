const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const debug = b.option(bool, "debug", "Enable the validation layer and debug log messages (default: Debug and ReleaseSafe)");
    const validate_non_fatal = b.option(bool, "validate_non_fatal", "Log validation errors without raising VALIDATION_FAILED") orelse false;
    const options = b.addOptions();
    options.addOption(?bool, "debug", debug);
    options.addOption(bool, "validate_non_fatal", validate_non_fatal);

    const module = b.addModule("sokol_gfx", .{
        .root_source_file = b.path("src/sokol_gfx/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    module.addOptions("sokol_gfx_options", options);

    // the unit tests exercise failing validation, so validation is non-fatal for them
    const test_options = b.addOptions();
    test_options.addOption(?bool, "debug", debug);
    test_options.addOption(bool, "validate_non_fatal", true);
    const test_module = b.createModule(.{
        .root_source_file = b.path("src/sokol_gfx/tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_module.addOptions("sokol_gfx_options", test_options);

    const gl_smoke = b.addExecutable(.{
        .name = "sokol-gfx-gl-smoke",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/gl_smoke.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{.{ .name = "sokol_gfx", .module = module }},
        }),
    });
    const gl_step = b.step("test-gl", "Verify native OpenGL and GLES rendering with surfaceless EGL");
    const gl_run = b.addRunArtifact(gl_smoke);
    gl_run.addPassthruArgs();
    gl_step.dependOn(&gl_run.step);

    inline for (.{
        .{ "test-vk", "tools/vk_smoke.zig", "sokol-gfx-vk-smoke", "Verify native Vulkan rendering with the system Vulkan loader" },
        .{ "test-wgpu", "tools/wgpu_smoke.zig", "sokol-gfx-wgpu-smoke", "Verify native WebGPU rendering with a wgpu-native library" },
    }) |smoke| {
        const exe = b.addExecutable(.{
            .name = smoke[2],
            .root_module = b.createModule(.{
                .root_source_file = b.path(smoke[1]),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
                .imports = &.{.{ .name = "sokol_gfx", .module = module }},
            }),
        });
        const run = b.addRunArtifact(exe);
        run.addPassthruArgs();
        b.step(smoke[0], smoke[3]).dependOn(&run.step);
    }

    // Metal can only run on Apple platforms; this step type-checks the
    // backend for macOS and iOS without linking.
    const metal_step = b.step("check-metal", "Type-check the Metal backend for macOS and iOS targets");
    inline for (.{ .macos, .ios }) |os| {
        const apple_target = b.resolveTargetQuery(.{ .cpu_arch = .aarch64, .os_tag = os });
        const apple_module = b.createModule(.{ .root_source_file = b.path("src/sokol_gfx/root.zig"), .target = apple_target, .optimize = optimize });
        apple_module.addOptions("sokol_gfx_options", options);
        const metal_check = b.addObject(.{
            .name = "sokol-gfx-metal-check-" ++ @tagName(os),
            .root_module = b.createModule(.{
                .root_source_file = b.path("tools/metal_check.zig"),
                .target = apple_target,
                .optimize = optimize,
                .imports = &.{.{ .name = "sokol_gfx", .module = apple_module }},
            }),
        });
        metal_step.dependOn(&metal_check.step);
    }

    const windows_target = b.resolveTargetQuery(.{ .cpu_arch = .x86_64, .os_tag = .windows, .abi = .gnu });
    const windows_module = b.createModule(.{ .root_source_file = b.path("src/sokol_gfx/root.zig"), .target = windows_target, .optimize = optimize });
    windows_module.addOptions("sokol_gfx_options", options);
    const d3d_smoke = b.addExecutable(.{
        .name = "sokol-gfx-d3d11-smoke",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/d3d11_smoke.zig"),
            .target = windows_target,
            .optimize = optimize,
            .imports = &.{.{ .name = "sokol_gfx", .module = windows_module }},
        }),
    });
    const d3d_step = b.step("check-d3d11", "Build the native Windows D3D11 rendering smoke executable");
    d3d_step.dependOn(&b.addInstallArtifact(d3d_smoke, .{}).step);

    // tests ported from the upstream sokol repository, one module per part
    // the upstream suite runs with fatal validation and a logger that doesn't
    // abort, so VALIDATION_FAILED is logged after every failed validation
    const upstream_options = b.addOptions();
    upstream_options.addOption(?bool, "debug", debug);
    upstream_options.addOption(bool, "validate_non_fatal", false);
    const upstream_step = b.step("test-upstream", "Run the tests ported from upstream sokol_gfx_test.c");
    inline for (1..5) |part| {
        const part_module = b.createModule(.{
            .root_source_file = b.path(std.fmt.comptimePrint("src/sokol_gfx/upstream_test_{d}.zig", .{part})),
            .target = target,
            .optimize = optimize,
        });
        part_module.addOptions("sokol_gfx_options", upstream_options);
        const part_tests = b.addTest(.{ .root_module = part_module });
        const part_run = b.addRunArtifact(part_tests);
        b.step(std.fmt.comptimePrint("test-upstream-{d}", .{part}), "Run part of the tests ported from upstream sokol_gfx_test.c").dependOn(&part_run.step);
        upstream_step.dependOn(&part_run.step);
    }

    // Differential fuzzing against the original C implementation. The C header is
    // compiled only into this test tool, never into the library.
    const ref_c = b.addTranslateC(.{ .root_source_file = b.path("tools/diff/sokol_ref.h"), .target = target, .optimize = optimize });
    ref_c.addIncludePath(b.path("."));
    const fuzz_options = b.addOptions();
    fuzz_options.addOption(?bool, "debug", true);
    fuzz_options.addOption(bool, "validate_non_fatal", true);
    const fuzz_gfx = b.createModule(.{ .root_source_file = b.path("src/sokol_gfx/root.zig"), .target = target, .optimize = optimize });
    fuzz_gfx.addOptions("sokol_gfx_options", fuzz_options);
    const fuzz_module = b.createModule(.{
        .root_source_file = b.path("tools/diff/fuzz.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "sokol_gfx", .module = fuzz_gfx },
            .{ .name = "sokol_ref", .module = ref_c.createModule() },
        },
    });
    fuzz_module.addIncludePath(b.path("."));
    fuzz_module.addCSourceFile(.{ .file = b.path("tools/diff/sokol_ref.c"), .flags = &.{"-fno-sanitize=undefined"} });
    const fuzz = b.addExecutable(.{ .name = "sokol-gfx-diff-fuzz", .root_module = fuzz_module });
    const fuzz_run = b.addRunArtifact(fuzz);
    fuzz_run.addPassthruArgs();
    b.step("test-diff", "Differential fuzzing of the Zig core against the original C sokol_gfx.h").dependOn(&fuzz_run.step);

    const unit_tests = b.addTest(.{ .root_module = test_module });
    const test_step = b.step("test", "Run native sokol_gfx tests");
    test_step.dependOn(&b.addRunArtifact(unit_tests).step);
    const check_step = b.step("check", "Compile the native sokol_gfx module and tests");
    check_step.dependOn(&unit_tests.step);
}
