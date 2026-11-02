const std = @import("std");
const gpu = @import("zicr").gpu;
const r2 = @import("zicr").render2d;
const shaders = @import("render2d_shaders");
fn example(allocator: std.mem.Allocator, device: *gpu.Device, sprite_view: gpu.View, pass_desc: gpu.PassDesc, width: i32, height: i32) !void {
    var renderer = try r2.Renderer.init(device, shaders.quad.desc(device.backend()) orelse return error.UnsupportedBackend, .{ .max_quads = 16384, .color_format = .rgba8 });
    defer renderer.deinit();
    var draws = try r2.DrawList.init(allocator, .{ .max_quads = 16384 });
    defer draws.deinit();
    try draws.reset(width, height, null);
    try draws.rect(.{ .width = 100, .height = 60 }, .{ .r = 0, .g = 0.5, .b = 1 });
    try draws.pushClip(.{ .x = 10, .y = 10, .width = 80, .height = 40 });
    try draws.quad(.{ .rect = .{ .width = 32, .height = 32 }, .transform = .{ .tx = 20, .ty = 15 }, .texture = .{ .view = sprite_view }, .uv = .{ .x = 0.25, .width = 0.25, .height = 1 } });
    try draws.popClip();
    try renderer.submit(&draws, pass_desc);
    device.commit();
}
pub fn main() void {
    var function: *const @TypeOf(example) = example;
    std.mem.doNotOptimizeAway(&function);
}
