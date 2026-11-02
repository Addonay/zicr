//! External-consumer compile check for the documented dependency/shader API.
const std = @import("std");
const zicr_build = @import("zicr");
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const dep = b.dependency("zicr", .{ .target = target, .optimize = optimize });
    const zicr = dep.module("zicr");
    const app = b.addExecutable(.{ .name = "renderer-consumer", .root_module = b.createModule(.{ .root_source_file = b.path("main.zig"), .target = target, .optimize = optimize }) });
    app.root_module.addImport("zicr", zicr);
    if (zicr_build.addRender2dShaderModule(b, dep, zicr)) |shaders| app.root_module.addImport("render2d_shaders", shaders);
    b.step("check", "Compile the documented renderer consumer API").dependOn(&app.step);
}
