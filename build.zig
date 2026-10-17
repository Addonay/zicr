const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const module = b.addModule("sokol_gfx", .{
        .root_source_file = b.path("src/sokol_gfx/root.zig"),
        .target = target,
        .optimize = optimize,
    });

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

    const windows_target = b.resolveTargetQuery(.{ .cpu_arch = .x86_64, .os_tag = .windows, .abi = .gnu });
    const windows_module = b.createModule(.{ .root_source_file = b.path("src/sokol_gfx/root.zig"), .target = windows_target, .optimize = optimize });
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

    const unit_tests = b.addTest(.{ .root_module = module });
    const test_step = b.step("test", "Run native sokol_gfx tests");
    test_step.dependOn(&b.addRunArtifact(unit_tests).step);
    const check_step = b.step("check", "Compile the native sokol_gfx module and tests");
    check_step.dependOn(&unit_tests.step);
}
