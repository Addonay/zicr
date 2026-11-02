const std = @import("std");
const paths = @import("path.zig");
const stroke = @import("stroke.zig");
const cov = @import("coverage.zig");
fn maskFor(path: *const paths.Path, options: stroke.Options) !cov.Mask {
    var outline = try stroke.outline(path, std.testing.allocator, options);
    defer outline.deinit();
    var flat = try paths.flatten(&outline, std.testing.allocator, .{ .tolerance = 0.0001 });
    defer flat.deinit();
    return cov.rasterize(&flat, std.testing.allocator, .{ .width = 96, .height = 96 }, .{});
}
fn area(mask: cov.Mask) f64 {
    var sum: f64 = 0;
    for (mask.pixels) |v| sum += v;
    return sum;
}
fn pixel(mask: cov.Mask, x: i32, y: i32) f32 {
    if (x < mask.bounds.x or y < mask.bounds.y or x >= mask.bounds.x + mask.bounds.width or y >= mask.bounds.y + mask.bounds.height) return 0;
    return mask.row(@intCast(y - mask.bounds.y))[@intCast(x - mask.bounds.x)];
}
test "six cap geometries have independently computed areas" {
    var path = paths.Path.init(std.testing.allocator);
    defer path.deinit();
    try path.moveTo(.{ .x = 10, .y = 20 });
    try path.lineTo(.{ .x = 30, .y = 20 });
    const caps = [_]stroke.Cap{ .butt, .square, .round, .round_reverse, .triangle, .triangle_reverse };
    const expected = [_]f64{ 160, 224, 160 + 16 * std.math.pi, 224 - 16 * std.math.pi, 192, 192 };
    for (caps, expected) |cap, want| {
        var mask = try maskFor(&path, .{ .width = 8, .start_cap = cap, .end_cap = cap });
        defer mask.deinit();
        try std.testing.expectApproxEqAbs(want, area(mask), 0.01);
    }
}
test "miter bevel round and clipped-miter joins differ by analytic corner area" {
    var path = paths.Path.init(std.testing.allocator);
    defer path.deinit();
    try path.addPolygon(&.{ .{ .x = 10, .y = 30 }, .{ .x = 30, .y = 30 }, .{ .x = 30, .y = 10 } }, false);
    const joins = [_]stroke.Join{ .miter_clip, .miter_bevel, .bevel, .round, .miter_round };
    const expected = [_]f64{ 320, 320, 312, 304 + 4 * std.math.pi, 320 };
    for (joins, expected) |join, want| {
        var mask = try maskFor(&path, .{ .width = 8, .join = join });
        defer mask.deinit();
        try std.testing.expectApproxEqAbs(want, area(mask), 0.01);
    }
    var clipped = try maskFor(&path, .{ .width = 8, .join = .miter_clip, .miter_limit = 1 });
    defer clipped.deinit();
    try std.testing.expectApproxEqAbs(320 - std.math.pow(f64, 4 * @sqrt(@as(f64, 2)) - 4, 2), area(clipped), 0.01);
    var fallback = try maskFor(&path, .{ .width = 8, .join = .miter_round, .miter_limit = 1 });
    defer fallback.deinit();
    try std.testing.expectApproxEqAbs(304 + 4 * std.math.pi, area(fallback), 0.01);
}
test "dash phase odd patterns and zero-length round dashes retain their semantics" {
    var path = paths.Path.init(std.testing.allocator);
    defer path.deinit();
    try path.moveTo(.{ .x = 10, .y = 20 });
    try path.lineTo(.{ .x = 21, .y = 20 });
    var positive = try maskFor(&path, .{ .width = 2, .dashes = &.{ 3, 2 }, .dash_offset = 1 });
    defer positive.deinit();
    var negative = try maskFor(&path, .{ .width = 2, .dashes = &.{ 3, 2 }, .dash_offset = -1 });
    defer negative.deinit();
    try std.testing.expectEqual(@as(f32, 1), pixel(positive, 10, 20));
    try std.testing.expectEqual(@as(f32, 0), pixel(negative, 10, 20));
    try std.testing.expectEqual(@as(f32, 0), pixel(positive, 12, 20));
    try std.testing.expectEqual(@as(f32, 1), pixel(negative, 12, 20));
    path.clear();
    try path.moveTo(.{ .x = 10, .y = 20 });
    try path.lineTo(.{ .x = 30, .y = 20 });
    var odd = try maskFor(&path, .{ .width = 2, .dashes = &.{3} });
    defer odd.deinit();
    try std.testing.expectApproxEqAbs(@as(f64, 22), area(odd), 1e-6);
    var dots = try maskFor(&path, .{ .width = 2, .dashes = &.{ 0, 5 }, .start_cap = .round, .end_cap = .round });
    defer dots.deinit();
    try std.testing.expectApproxEqAbs(4 * std.math.pi, area(dots), 0.01);
}
test "closed dashed contour merges across seam without introducing a gap or extra connector" {
    var a = paths.Path.init(std.testing.allocator);
    defer a.deinit();
    var b = paths.Path.init(std.testing.allocator);
    defer b.deinit();
    try a.addPolygon(&.{ .{ .x = 10, .y = 10 }, .{ .x = 20, .y = 10 }, .{ .x = 20, .y = 20 }, .{ .x = 10, .y = 20 } }, true);
    try b.addPolygon(&.{ .{ .x = 20, .y = 10 }, .{ .x = 20, .y = 20 }, .{ .x = 10, .y = 20 }, .{ .x = 10, .y = 10 } }, true);
    var ma = try maskFor(&a, .{ .width = 2, .join = .bevel, .dashes = &.{ 8, 2 }, .dash_offset = 4 });
    defer ma.deinit();
    var mb = try maskFor(&b, .{ .width = 2, .join = .bevel, .dashes = &.{ 8, 2 }, .dash_offset = 4 });
    defer mb.deinit();
    for (0..32) |y| for (0..32) |x| try std.testing.expectApproxEqAbs(pixel(ma, @intCast(x), @intCast(y)), pixel(mb, @intCast(x), @intCast(y)), 1e-6);
}
test "stroke and transform order preserve distinct width semantics" {
    const geo = @import("geometry.zig");
    var path = paths.Path.init(std.testing.allocator);
    defer path.deinit();
    try path.moveTo(.{ .x = 10, .y = 20 });
    try path.lineTo(.{ .x = 30, .y = 20 });
    var before = try maskFor(&path, .{ .width = 4, .transform = geo.Affine.scaling(2, 3) });
    defer before.deinit();
    var after = try maskFor(&path, .{ .width = 4, .transform = geo.Affine.scaling(2, 3), .order = .transform_then_stroke });
    defer after.deinit();
    try std.testing.expectApproxEqAbs(@as(f64, 480), area(before), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f64, 160), area(after), 1e-6);
}
test "stroke allocation failures clean temporary outlines and malformed styles fail" {
    const Case = struct {
        fn run(allocator: std.mem.Allocator) !void {
            var path = paths.Path.init(allocator);
            defer path.deinit();
            try path.addPolygon(&.{ .{ .x = 10, .y = 10 }, .{ .x = 30, .y = 10 }, .{ .x = 20, .y = 30 } }, true);
            var output = try stroke.outline(&path, allocator, .{ .width = 3, .join = .round, .start_cap = .round_reverse, .end_cap = .triangle_reverse, .dashes = &.{ 5, 2, 3 } });
            defer output.deinit();
        }
    };
    var backing = std.testing.allocator;
    try std.testing.checkAllAllocationFailures(@import("test_allocator.zig").noResize(&backing), Case.run, .{});
    var path = paths.Path.init(std.testing.allocator);
    defer path.deinit();
    try path.moveTo(.{});
    try path.lineTo(.{ .x = 20 });
    try std.testing.expectError(error.InvalidStroke, stroke.outline(&path, std.testing.allocator, .{ .width = -1 }));
    try std.testing.expectError(error.InvalidStroke, stroke.outline(&path, std.testing.allocator, .{ .dashes = &.{ 1, -1 } }));
    try std.testing.expectError(error.StrokeLimit, stroke.outline(&path, std.testing.allocator, .{ .max_pieces = 0 }));
}
