//! Compare actual renderer output to independent Blend2D alpha pixels.
const std = @import("std");
const zicr = @import("zicr");
const gpu = zicr.gpu;
const r2 = zicr.render2d;
pub fn run(allocator: std.mem.Allocator, io: std.Io, device: *gpu.Device, shader: gpu.ShaderDesc, filename: []const u8) !void {
    const reference = try std.Io.Dir.cwd().readFileAlloc(io, filename, allocator, .unlimited);
    defer allocator.free(reference);
    if (reference.len != 20 + 26 * 4096 or !std.mem.eql(u8, reference[0..8], "Z2DBL001") or
        std.mem.readInt(u32, reference[8..12], .little) != 26 or std.mem.readInt(u32, reference[12..16], .little) != 64 or std.mem.readInt(u32, reference[16..20], .little) != 64) return error.InvalidReference;
    var renderer = try r2.Renderer.init(device, shader, .{ .max_quads = 8192 });
    defer renderer.deinit();
    var draws = try r2.DrawList.init(allocator, .{ .max_quads = 8192 });
    defer draws.deinit();
    const image = try device.createImage(.{ .width = 64, .height = 64, .format = .rgba8, .usage = .{ .color_attachment = true, .copy_src = true } });
    defer device.destroy(image);
    const view = try device.createView(.{ .color_attachment = .{ .image = image } });
    defer device.destroy(view);
    var failed: u32 = 0;
    for (0..26) |id| {
        var path = r2.Path.init(allocator);
        defer path.deinit();
        var style: r2.StrokeOptions = .{ .width = if (id >= 16 and id < 21) 18.5 else 7.25, .miter_limit = 1.75 };
        const caps = [_]r2.StrokeCap{ .butt, .square, .round, .round_reverse, .triangle, .triangle_reverse };
        const joins = [_]r2.StrokeJoin{ .miter_clip, .miter_bevel, .miter_round, .bevel, .round };
        style.start_cap = if (id < 6) caps[id] else .round;
        style.end_cap = style.start_cap;
        if (id >= 6) style.join = joins[(id - 6) % 5];
        if (id < 6) {
            try path.moveTo(.{ .x = 12.25, .y = 24.5 });
            try path.lineTo(.{ .x = 48.75, .y = 37.25 });
        } else if (id < 11) {
            try path.addPolygon(&.{ .{ .x = 9.75, .y = 44.25 }, .{ .x = 31.5, .y = 12.5 }, .{ .x = 50.75, .y = 43.25 } }, false);
        } else if (id < 16) {
            try path.moveTo(.{ .x = 8.5, .y = 32.25 });
            try path.cubicTo(.{ .x = 12.25, .y = 3.5 }, .{ .x = 40.75, .y = 61.25 }, .{ .x = 55.25, .y = 24.75 });
        } else if (id < 21) {
            try path.moveTo(.{ .x = 15.5, .y = 34.25 });
            try path.cubicTo(.{ .x = 58, .y = 8 }, .{ .x = 12.75, .y = 7.25 }, .{ .x = 39.5, .y = 37 });
        } else try path.ellipse(.{ .x = 32.25, .y = 32.75 }, .{ .x = 15, .y = 9 }, 0);
        try draws.reset(64, 64, null);
        try draws.strokePath(&path, .{}, style);
        try renderer.submit(&draws, .{ .target = .{ .attachments = .{ .colors = &.{view} } }, .colors = &.{.{ .load = .{ .clear = .{ 0, 0, 0, 0 } } }} });
        device.commit();
        var pixels: [64 * 64 * 4]u8 = undefined;
        try device.readImage(image, .{}, &pixels, .{});
        var maximum: u32 = 0;
        var total: u32 = 0;
        var outside: u32 = 0;
        for (0..64) |y| for (0..64) |x| {
            const row = if (device.features().origin_top_left) y else 63 - y;
            const actual = pixels[(row * 64 + x) * 4 + 3];
            const expected = reference[20 + id * 4096 + y * 64 + x];
            const difference: u32 = @intCast(@abs(@as(i32, actual) - @as(i32, expected)));
            maximum = @max(maximum, difference);
            total += difference;
            if (difference > 2) outside += 1;
        };
        std.debug.print("{{\"case\":{d},\"max_alpha_error\":{d},\"total_alpha_error\":{d},\"pixels_over_2\":{d}}}\n", .{ id, maximum, total, outside });
        if (outside != 0) failed += 1;
    }
    if (failed != 0) return error.ReferenceMismatch;
}
