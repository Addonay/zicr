const std = @import("std");
const paths = @import("path.zig");
const cov = @import("coverage.zig");
fn sum(mask: cov.Mask) f64 {
    var result: f64 = 0;
    for (mask.pixels) |value| result += value;
    return result;
}

test "analytic coverage integrates fractional rectangle area without supersampling" {
    var path = paths.Path.init(std.testing.allocator);
    defer path.deinit();
    try path.addRect(.{ .x = 0.2, .y = 0.3, .width = 2.4, .height = 1.5 });
    var flat = try paths.flatten(&path, std.testing.allocator, .{});
    defer flat.deinit();
    var mask = try cov.rasterize(&flat, std.testing.allocator, .{ .width = 4, .height = 4 }, .{});
    defer mask.deinit();
    try std.testing.expectApproxEqAbs(@as(f64, 3.6), sum(mask), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.56), mask.row(0)[0], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.48), mask.row(1)[2], 1e-6);
}
test "nonzero and even odd distinguish overlapping contours and oriented holes" {
    var path = paths.Path.init(std.testing.allocator);
    defer path.deinit();
    try path.addRect(.{ .width = 3, .height = 3 });
    try path.addRect(.{ .x = 1, .y = 1, .width = 3, .height = 3 });
    var flat = try paths.flatten(&path, std.testing.allocator, .{});
    defer flat.deinit();
    var nz = try cov.rasterize(&flat, std.testing.allocator, .{ .width = 5, .height = 5 }, .{});
    defer nz.deinit();
    var eo = try cov.rasterize(&flat, std.testing.allocator, .{ .width = 5, .height = 5 }, .{ .rule = .even_odd });
    defer eo.deinit();
    try std.testing.expectEqual(@as(f64, 14), sum(nz));
    try std.testing.expectEqual(@as(f64, 10), sum(eo));
    try std.testing.expectEqual(@as(f32, 1), nz.row(1)[1]);
    try std.testing.expectEqual(@as(f32, 0), eo.row(1)[1]);
    path.clear();
    try path.addRect(.{ .width = 4, .height = 4 });
    try path.addRect(.{ .x = 3, .y = 1, .width = -2, .height = 2 });
    var holes = try paths.flatten(&path, std.testing.allocator, .{});
    defer holes.deinit();
    var hole = try cov.rasterize(&holes, std.testing.allocator, .{ .width = 4, .height = 4 }, .{});
    defer hole.deinit();
    try std.testing.expectEqual(@as(f64, 12), sum(hole));
}
test "self intersection inside a pixel row splits the winding order correctly" {
    var path = paths.Path.init(std.testing.allocator);
    defer path.deinit();
    try path.moveTo(.{});
    try path.lineTo(.{ .x = 5, .y = 5 });
    try path.lineTo(.{ .y = 5 });
    try path.lineTo(.{ .x = 5 });
    var flat = try paths.flatten(&path, std.testing.allocator, .{});
    defer flat.deinit();
    var mask = try cov.rasterize(&flat, std.testing.allocator, .{ .width = 5, .height = 5 }, .{});
    defer mask.deinit();
    try std.testing.expectApproxEqAbs(@as(f64, 12.5), sum(mask), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), mask.row(2)[2], 1e-6);
}
test "coverage clipping and resource limits release partial output" {
    const Case = struct {
        fn run(allocator: std.mem.Allocator) !void {
            var path = paths.Path.init(allocator);
            defer path.deinit();
            try path.addRect(.{ .x = -0.5, .y = -0.5, .width = 4, .height = 4 });
            var flat = try paths.flatten(&path, allocator, .{});
            defer flat.deinit();
            var mask = try cov.rasterize(&flat, allocator, .{ .x = 1, .y = 1, .width = 2, .height = 2 }, .{});
            defer mask.deinit();
            try std.testing.expectEqual(@as(f64, 4), sum(mask));
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Case.run, .{});
    var path = paths.Path.init(std.testing.allocator);
    defer path.deinit();
    try path.addRect(.{ .width = 10, .height = 10 });
    var flat = try paths.flatten(&path, std.testing.allocator, .{});
    defer flat.deinit();
    try std.testing.expectError(error.RasterLimit, cov.rasterize(&flat, std.testing.allocator, .{ .width = 10, .height = 10 }, .{ .max_pixels = 4 }));
    try std.testing.expectError(error.RasterLimit, cov.rasterize(&flat, std.testing.allocator, .{ .width = 10, .height = 10 }, .{ .max_pair_tests = 0 }));
}

test "finite extreme slopes do not hide an intersection through overflow" {
    var path = paths.Path.init(std.testing.allocator);
    defer path.deinit();
    try path.addPolygon(&.{ .{ .x = -5e307, .y = 0 }, .{ .x = 5e307, .y = 1 }, .{ .x = -5e307, .y = 1 }, .{ .x = 5e307, .y = 0 } }, true);
    var flat = try paths.flatten(&path, std.testing.allocator, .{});
    defer flat.deinit();
    var mask = try cov.rasterize(&flat, std.testing.allocator, .{ .width = 4, .height = 1 }, .{});
    defer mask.deinit();
    for (mask.pixels) |value| try std.testing.expectApproxEqAbs(@as(f32, 1), value, 1e-6);
}
