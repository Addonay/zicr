//! The standalone module and renderer re-export must share types and device IDs.
const std = @import("std");
const gpu = @import("gpu");
const zicr = @import("zicr");
comptime {
    if (gpu.Device != zicr.gpu.Device or gpu.Buffer != zicr.gpu.Buffer) @compileError("gpu module and zicr.gpu must share one module instance");
}
test "standalone GPU module shares the zicr re-export" {
    var first = try gpu.Device.init(std.testing.allocator, .{ .backend = .dummy });
    defer first.deinit();
    var second = try zicr.gpu.Device.init(std.testing.allocator, .{ .backend = .dummy });
    defer second.deinit();
    const buffer = try first.createBuffer(.{ .size = 16, .usage = .{ .vertex = true, .writes = .transient } });
    defer first.destroy(buffer);
    const other = try second.createBuffer(.{ .size = 16, .usage = .{ .vertex = true, .writes = .transient } });
    defer second.destroy(other);
    try std.testing.expect(buffer != other);
    try std.testing.expectEqual(gpu.ResourceState.valid, first.state(buffer));
    try std.testing.expectEqual(gpu.ResourceState.invalid, second.state(buffer));
}

// Compile the README sequence with concrete API types, without fabricating a
// native device or pretending that compilation establishes a Vulkan runtime pass.
fn readmeUsage(
    allocator: std.mem.Allocator,
    vkGetInstanceProcAddr: gpu.raw.native.vulkan.GetInstanceProcAddr,
    instance: *const anyopaque,
    physical_device: *const anyopaque,
    native_device: *const anyopaque,
    queue: *const anyopaque,
    family: u32,
    swapchain: gpu.Swapchain,
    shader_desc: gpu.ShaderDesc,
) !void {
    const vertices = [_][2]f32{ .{ -1, -1 }, .{ 3, -1 }, .{ -1, 3 } };
    const params = [4]f32{ 1, 0, 0, 1 };
    var dev = try gpu.Device.init(allocator, .{ .backend = .{ .vulkan = .{
        .get_instance_proc_addr = @ptrCast(vkGetInstanceProcAddr),
        .instance = instance,
        .physical_device = physical_device,
        .device = native_device,
        .queue = queue,
        .queue_family_index = family,
    } } });
    defer dev.deinit();
    const shader = try dev.createShader(shader_desc);
    defer dev.destroy(shader);
    const pipeline = try dev.createPipeline(.{
        .shader = shader,
        .vertex_attrs = &.{.{ .format = .float2 }},
        .colors = &.{.{ .format = swapchain.color_format }},
        .depth = .{ .format = .none },
    });
    defer dev.destroy(pipeline);
    const vbuf = try dev.createBuffer(.{ .usage = .{ .vertex = true }, .data = std.mem.sliceAsBytes(&vertices) });
    defer dev.destroy(vbuf);
    var pass = dev.beginPass(.{ .target = .{ .swapchain = swapchain } });
    pass.setPipeline(pipeline);
    pass.setBindings(.{ .vertex_buffers = &.{.{ .buffer = vbuf }} });
    pass.setUniforms(0, &params);
    pass.draw(.{ .count = 3 });
    pass.end();
    dev.commit();
}

test "README usage compiles against the real public API" {
    var example: *const @TypeOf(readmeUsage) = readmeUsage;
    std.mem.doNotOptimizeAway(&example);
}
