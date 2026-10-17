const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const debug = b.option(bool, "debug", "Enable the validation layer and debug log messages (default: Debug and ReleaseSafe)");
    const validate_non_fatal = b.option(bool, "validate_non_fatal", "Log validation errors without raising VALIDATION_FAILED") orelse false;
    const options = zicrOptions(b, debug, validate_non_fatal);

    const zicr = b.addModule("zicr", .{
        .root_source_file = b.path("src/zicr.zig"),
        .target = target,
        .optimize = optimize,
    });
    zicr.addOptions("zicr_options", options);

    // ------------------------------------------------------------ tests

    const test_step = b.step("test", "Run the unit tests");
    const check_step = b.step("check", "Compile the library and its tests");
    // the unit tests exercise failing validation, so validation is non-fatal for them
    const test_options = zicrOptions(b, debug, true);
    inline for (.{ "src/gpu/tests.zig", "src/gpu/api_tests.zig" }) |root| {
        const unit_tests = b.addTest(.{ .root_module = testModule(b, root, target, optimize, test_options) });
        test_step.dependOn(&b.addRunArtifact(unit_tests).step);
        check_step.dependOn(&unit_tests.step);
    }

    // tests ported from upstream sokol (tests/functional/sokol_gfx_test.c); like
    // upstream they run with fatal validation and a logger that doesn't abort
    const upstream_options = zicrOptions(b, debug, false);
    const upstream_step = b.step("test-upstream", "Run the tests ported from upstream sokol_gfx_test.c");
    inline for (1..5) |part| {
        const root = std.fmt.comptimePrint("src/gpu/upstream_test_{d}.zig", .{part});
        const part_tests = b.addTest(.{ .root_module = testModule(b, root, target, optimize, upstream_options) });
        const part_run = b.addRunArtifact(part_tests);
        b.step(std.fmt.comptimePrint("test-upstream-{d}", .{part}), "Run part of the upstream sokol_gfx tests").dependOn(&part_run.step);
        upstream_step.dependOn(&part_run.step);
        check_step.dependOn(&part_tests.step);
    }

    // Differential fuzzing against the original C implementation. The C header is
    // compiled only into this test tool, never into the library.
    const ref_c = b.addTranslateC(.{ .root_source_file = b.path("tools/diff/sokol_ref.h"), .target = target, .optimize = optimize });
    ref_c.addIncludePath(b.path("."));
    const fuzz_module = toolModule(b, "tools/diff/fuzz.zig", target, optimize, zicrOptions(b, true, true));
    fuzz_module.addImport("sokol_ref", ref_c.createModule());
    fuzz_module.addIncludePath(b.path("."));
    fuzz_module.addCSourceFile(.{ .file = b.path("tools/diff/sokol_ref.c"), .flags = &.{"-fno-sanitize=undefined"} });
    const fuzz = b.addExecutable(.{ .name = "zicr-diff-fuzz", .root_module = fuzz_module });
    const fuzz_run = b.addRunArtifact(fuzz);
    fuzz_run.addPassthruArgs();
    b.step("test-diff", "Differential fuzzing of the core against the original C sokol_gfx.h").dependOn(&fuzz_run.step);

    // ------------------------------------------------------------ GPU smoke tests

    inline for (.{
        .{ "test-gl", "tools/gl_smoke.zig", "zicr-gl-smoke", "Verify OpenGL and GLES rendering with surfaceless EGL" },
        .{ "test-vk", "tools/vk_smoke.zig", "zicr-vk-smoke", "Verify Vulkan rendering with the system Vulkan loader" },
        .{ "test-wgpu", "tools/wgpu_smoke.zig", "zicr-wgpu-smoke", "Verify WebGPU rendering with a wgpu-native library" },
    }) |smoke| {
        const exe = b.addExecutable(.{ .name = smoke[2], .root_module = toolModule(b, smoke[1], target, optimize, options) });
        const run = b.addRunArtifact(exe);
        run.addPassthruArgs();
        b.step(smoke[0], smoke[3]).dependOn(&run.step);
    }

    const windows_target = b.resolveTargetQuery(.{ .cpu_arch = .x86_64, .os_tag = .windows, .abi = .gnu });
    const d3d_module = toolModule(b, "tools/d3d11_smoke.zig", windows_target, optimize, options);
    d3d_module.link_libc = null;
    const d3d_smoke = b.addExecutable(.{ .name = "zicr-d3d11-smoke", .root_module = d3d_module });
    b.step("check-d3d11", "Build the D3D11 rendering smoke executable").dependOn(&b.addInstallArtifact(d3d_smoke, .{}).step);

    // Metal can only run on Apple platforms; this step type-checks the backend
    // for macOS and iOS without linking.
    const metal_step = b.step("check-metal", "Type-check the Metal backend for macOS and iOS targets");
    inline for (.{ .macos, .ios }) |os| {
        const apple_target = b.resolveTargetQuery(.{ .cpu_arch = .aarch64, .os_tag = os });
        const apple_module = toolModule(b, "tools/metal_check.zig", apple_target, optimize, options);
        apple_module.link_libc = null;
        const metal_check = b.addObject(.{ .name = "zicr-metal-check-" ++ @tagName(os), .root_module = apple_module });
        metal_step.dependOn(&metal_check.step);
    }
}

fn zicrOptions(b: *std.Build, debug: ?bool, validate_non_fatal: bool) *std.Build.Step.Options {
    const options = b.addOptions();
    options.addOption(?bool, "debug", debug);
    options.addOption(bool, "validate_non_fatal", validate_non_fatal);
    return options;
}

fn testModule(b: *std.Build, root: []const u8, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, options: *std.Build.Step.Options) *std.Build.Module {
    const module = b.createModule(.{ .root_source_file = b.path(root), .target = target, .optimize = optimize });
    module.addOptions("zicr_options", options);
    return module;
}

/// A tool executable importing its own instance of the library, built with `options`.
fn toolModule(b: *std.Build, root: []const u8, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, options: *std.Build.Step.Options) *std.Build.Module {
    const zicr = b.createModule(.{ .root_source_file = b.path("src/zicr.zig"), .target = target, .optimize = optimize });
    zicr.addOptions("zicr_options", options);
    return b.createModule(.{
        .root_source_file = b.path(root),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "zicr", .module = zicr }},
    });
}
