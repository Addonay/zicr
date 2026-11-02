const std = @import("std");
const paths = @import("path.zig");
const geo = @import("geometry.zig");
const Point = geo.Point;

fn distanceToPolyline(p: Point, points: []const Point) f64 {
    var distance = std.math.inf(f64);
    for (points[1..], points[0 .. points.len - 1]) |b, a| distance = @min(distance, geo.distanceToSegment(p, a, b));
    return distance;
}

test "quadratic and cubic flattening satisfy sampled device-space geometric error" {
    var path = paths.Path.init(std.testing.allocator);
    defer path.deinit();
    try path.moveTo(.{ .x = 0, .y = 0 });
    try path.quadTo(.{ .x = 20, .y = 100 }, .{ .x = 80, .y = -5 });
    try path.moveTo(.{ .x = -20, .y = 10 });
    try path.cubicTo(.{ .x = 120, .y = 200 }, .{ .x = -100, .y = -150 }, .{ .x = 60, .y = 30 });
    const transform: geo.Affine = .{ .a = 4, .b = 0.7, .c = 1.3, .d = -2, .tx = 100, .ty = 50 };
    const tolerance: f64 = 0.05;
    var flat = try paths.flatten(&path, std.testing.allocator, .{ .transform = transform, .tolerance = tolerance });
    defer flat.deinit();
    try std.testing.expectEqual(@as(usize, 2), flat.contours.items.len);
    for (0..2001) |i| {
        const t = @as(f64, @floatFromInt(i)) / 2000.0;
        const u = 1 - t;
        // Independent Bernstein evaluation, not subdivision of the input.
        const quad: Point = .{ .x = 2 * u * t * 20 + t * t * 80, .y = 2 * u * t * 100 - t * t * 5 };
        const cubic: Point = .{ .x = -20 * u * u * u + 3 * u * u * t * 120 - 3 * u * t * t * 100 + 60 * t * t * t, .y = 10 * u * u * u + 3 * u * u * t * 200 - 3 * u * t * t * 150 + 30 * t * t * t };
        try std.testing.expect(distanceToPolyline(transform.point(quad), flat.contourPoints(flat.contours.items[0])) <= tolerance + 1e-9);
        try std.testing.expect(distanceToPolyline(transform.point(cubic), flat.contourPoints(flat.contours.items[1])) <= tolerance + 1e-9);
    }
}

test "rational conic represents a quarter circle and ellipse retains contour boundaries" {
    var path = paths.Path.init(std.testing.allocator);
    defer path.deinit();
    try path.moveTo(.{ .x = 1, .y = 0 });
    try path.conicTo(.{ .x = 1, .y = 1 }, .{ .x = 0, .y = 1 }, @sqrt(@as(f64, 0.5)));
    var flat = try paths.flatten(&path, std.testing.allocator, .{ .transform = geo.Affine.scaling(100, 100), .tolerance = 0.02 });
    defer flat.deinit();
    for (flat.points.items) |p| try std.testing.expectApproxEqAbs(@as(f64, 100), @sqrt(p.x * p.x + p.y * p.y), 1e-10);
    for (0..1001) |i| {
        const angle = @as(f64, @floatFromInt(i)) / 1000.0 * std.math.pi / 2.0;
        try std.testing.expect(distanceToPolyline(.{ .x = @cos(angle) * 100, .y = @sin(angle) * 100 }, flat.points.items) <= 0.02);
    }
    try path.ellipse(.{ .x = 10, .y = 20 }, .{ .x = 5, .y = 3 }, 0.4);
    var multiple = try paths.flatten(&path, std.testing.allocator, .{});
    defer multiple.deinit();
    try std.testing.expectEqual(@as(usize, 2), multiple.contours.items.len);
    try std.testing.expect(!multiple.contours.items[0].closed);
    try std.testing.expect(multiple.contours.items[1].closed);
}

test "collinear backtracking and coincident-endpoint loops are not discarded" {
    var path = paths.Path.init(std.testing.allocator);
    defer path.deinit();
    try path.moveTo(.{});
    try path.cubicTo(.{ .x = 100 }, .{ .x = -100 }, .{});
    var flat = try paths.flatten(&path, std.testing.allocator, .{ .tolerance = 0.01 });
    defer flat.deinit();
    const bounds = flat.bounds().?;
    try std.testing.expect(bounds.max.x > 28);
    try std.testing.expect(bounds.min.x < -28);
    try std.testing.expect(flat.points.items.len > 3);
}

test "close and subsequent line retain independent open-contour semantics" {
    var path = paths.Path.init(std.testing.allocator);
    defer path.deinit();
    try path.addRect(.{ .x = 1, .y = 2, .width = 5, .height = 6 });
    try path.lineTo(.{ .x = 20, .y = 30 });
    var flat = try paths.flatten(&path, std.testing.allocator, .{});
    defer flat.deinit();
    try std.testing.expectEqual(@as(usize, 2), flat.contours.items.len);
    try std.testing.expect(flat.contours.items[0].closed);
    try std.testing.expect(!flat.contours.items[1].closed);
    try std.testing.expectEqual(Point{ .x = 1, .y = 2 }, flat.contourPoints(flat.contours.items[1])[0]);
    try std.testing.expectEqual(Point{ .x = 20, .y = 30 }, flat.contourPoints(flat.contours.items[1])[1]);
}

test "invalid commands and subdivision limits report errors without mutating path" {
    var path = paths.Path.init(std.testing.allocator);
    defer path.deinit();
    try std.testing.expectError(error.MissingCurrentPoint, path.lineTo(.{}));
    try path.moveTo(.{});
    try path.quadTo(.{ .x = 50, .y = 100 }, .{ .x = 100 });
    const revision = path.revision;
    const count = path.data().len;
    try std.testing.expectError(error.InvalidCoordinate, path.lineTo(.{ .x = std.math.nan(f64) }));
    try std.testing.expectError(error.InvalidWeight, path.conicTo(.{}, .{}, -1));
    try std.testing.expectError(error.InvalidRadius, path.arc(.{}, .{ .x = -1, .y = 1 }, 0, 0, 1));
    try std.testing.expectEqual(revision, path.revision);
    try std.testing.expectEqual(count, path.data().len);
    try std.testing.expectError(error.FlattenLimit, paths.flatten(&path, std.testing.allocator, .{ .max_depth = 0, .tolerance = 0.01 }));
    try std.testing.expectError(error.FlattenLimit, paths.flatten(&path, std.testing.allocator, .{ .max_points = 1 }));
    try std.testing.expectError(error.InvalidTolerance, paths.flatten(&path, std.testing.allocator, .{ .tolerance = 0 }));
}

test "path append to self is safe and curve command storage remains independent" {
    var path = paths.Path.init(std.testing.allocator);
    defer path.deinit();
    try path.addRect(.{ .width = 4, .height = 6 });
    try path.append(&path, geo.Affine.translation(10, 20));
    var flat = try paths.flatten(&path, std.testing.allocator, .{});
    defer flat.deinit();
    try std.testing.expectEqual(@as(usize, 2), flat.contours.items.len);
    try std.testing.expectEqual(Point{ .x = 10, .y = 20 }, flat.contourPoints(flat.contours.items[1])[0]);
}

test "path construction transformation and flattening release all partial allocations" {
    const Case = struct {
        fn run(allocator: std.mem.Allocator) !void {
            var path = paths.Path.init(allocator);
            defer path.deinit();
            try path.addRect(.{ .width = 10, .height = 10 });
            try path.ellipse(.{ .x = 5, .y = 5 }, .{ .x = 10, .y = 20 }, 0.7);
            var copy = try path.transformed(allocator, geo.Affine.scaling(4, 2));
            defer copy.deinit();
            var reverse = try copy.reversed(allocator);
            defer reverse.deinit();
            var flat = try paths.flatten(&reverse, allocator, .{ .tolerance = 0.1 });
            defer flat.deinit();
        }
    };
    var backing = std.testing.allocator;
    try std.testing.checkAllAllocationFailures(@import("test_allocator.zig").noResize(&backing), Case.run, .{});
}

test "SVG endpoint arcs correct radii and preserve exact endpoints" {
    var path = paths.Path.init(std.testing.allocator);
    defer path.deinit();
    try path.moveTo(.{ .x = -10 });
    // Too-small radii are enlarged to the radius-10 semicircle.
    try path.svgArcTo(.{ .x = -2, .y = 2 }, 0, false, true, .{ .x = 10 });
    try std.testing.expectEqual(Point{ .x = 10 }, path.current.?);
    var flat = try paths.flatten(&path, std.testing.allocator, .{ .tolerance = 0.001 });
    defer flat.deinit();
    for (flat.points.items) |point| try std.testing.expectApproxEqAbs(@as(f64, 10), std.math.hypot(point.x, point.y), 1e-10);
    try std.testing.expectEqual(Point{ .x = -10 }, flat.points.items[0]);
    try std.testing.expectEqual(Point{ .x = 10 }, flat.points.items[flat.points.items.len - 1]);
    try std.testing.expect(flat.bounds().?.min.y < -9.99);
    const count = path.data().len;
    try path.svgArcTo(.{ .x = 10, .y = 20 }, 0, true, false, .{ .x = 10 });
    try std.testing.expectEqual(count, path.data().len);
    try path.svgArcTo(.{ .x = 0, .y = 20 }, 0, false, true, .{ .x = 15 });
    try std.testing.expectEqual(Point{ .x = 15 }, path.current.?);
}

test "rounded rectangles and circles retain exact conics and usable geometry" {
    var path = paths.Path.init(std.testing.allocator);
    defer path.deinit();
    try path.roundedRect(.{ .x = 10, .y = 20, .width = -8, .height = 4 }, .{ .x = 100, .y = 100 });
    var flat = try paths.flatten(&path, std.testing.allocator, .{ .tolerance = 0.001 });
    defer flat.deinit();
    const bounds = flat.bounds().?;
    try std.testing.expectApproxEqAbs(@as(f64, 2), bounds.min.x, 1e-10);
    try std.testing.expectApproxEqAbs(@as(f64, 10), bounds.max.x, 1e-10);
    try std.testing.expectApproxEqAbs(@as(f64, 20), bounds.min.y, 1e-10);
    try std.testing.expectApproxEqAbs(@as(f64, 24), bounds.max.y, 1e-10);
    try std.testing.expect(flat.contours.items[0].closed);
    try path.circle(.{}, 3);
    try std.testing.expectError(error.InvalidRadius, path.circle(.{}, -1));
}

test "small arc sweep is not lost when the starting angle has large magnitude" {
    var path = paths.Path.init(std.testing.allocator);
    defer path.deinit();
    try path.arc(.{}, .{ .x = 100, .y = 100 }, 0, 1e20, 0.1);
    var flat = try paths.flatten(&path, std.testing.allocator, .{ .tolerance = 0.001 });
    defer flat.deinit();
    const first = flat.points.items[0];
    const last = flat.points.items[flat.points.items.len - 1];
    try std.testing.expectApproxEqAbs(200 * @sin(@as(f64, 0.05)), std.math.hypot(last.x - first.x, last.y - first.y), 1e-10);
}

test "retained curve bounds use analytic extrema instead of control hull bounds" {
    var path = paths.Path.init(std.testing.allocator);
    defer path.deinit();
    try path.moveTo(.{});
    try path.quadTo(.{ .x = 20, .y = 100 }, .{ .x = 80, .y = -5 });
    const quadratic = (try path.bounds()).?;
    try std.testing.expectApproxEqAbs(@as(f64, 10000.0 / 205.0), quadratic.max.y, 1e-10);
    try std.testing.expectEqual(@as(f64, -5), quadratic.min.y);
    path.clear();
    try path.moveTo(.{});
    try path.cubicTo(.{ .x = 100, .y = 100 }, .{ .x = -100, .y = 100 }, .{});
    const cubic = (try path.bounds()).?;
    try std.testing.expectApproxEqAbs(@as(f64, 75), cubic.max.y, 1e-10);
    try std.testing.expectApproxEqAbs(@as(f64, 100.0 / (2.0 * @sqrt(@as(f64, 3)))), cubic.max.x, 1e-10);
    try std.testing.expectApproxEqAbs(-cubic.max.x, cubic.min.x, 1e-10);
    path.clear();
    try path.moveTo(.{});
    try path.conicTo(.{ .x = 10, .y = 10 }, .{ .x = 20 }, 0.5);
    const conic = (try path.bounds()).?;
    try std.testing.expectApproxEqAbs(@as(f64, 10.0 / 3.0), conic.max.y, 1e-10);
}

test "curve-preserving reversal changes winding without changing filled coverage" {
    const cov = @import("coverage.zig");
    var path = paths.Path.init(std.testing.allocator);
    defer path.deinit();
    try path.roundedRect(.{ .x = 2, .y = 3, .width = 20, .height = 15 }, .{ .x = 4, .y = 3 });
    try path.addRect(.{ .x = 15, .y = 6, .width = -8, .height = 6 });
    var reverse = try path.reversed(std.testing.allocator);
    defer reverse.deinit();
    try std.testing.expectEqual(path.data().len, reverse.data().len);
    var a = try paths.flatten(&path, std.testing.allocator, .{ .tolerance = 0.001 });
    defer a.deinit();
    var b = try paths.flatten(&reverse, std.testing.allocator, .{ .tolerance = 0.001 });
    defer b.deinit();
    var ma = try cov.rasterize(&a, std.testing.allocator, .{ .width = 32, .height = 32 }, .{});
    defer ma.deinit();
    var mb = try cov.rasterize(&b, std.testing.allocator, .{ .width = 32, .height = 32 }, .{});
    defer mb.deinit();
    try std.testing.expectEqual(ma.bounds, mb.bounds);
    for (ma.pixels, mb.pixels) |av, bv| try std.testing.expectApproxEqAbs(av, bv, 1e-6);
}

test "bounded negative conic weights subdivide before applying a convex hull bound" {
    var path = paths.Path.init(std.testing.allocator);
    defer path.deinit();
    try path.moveTo(.{ .x = -1 });
    try path.conicTo(.{ .y = 1 }, .{ .x = 1 }, -0.5);
    var flat = try paths.flatten(&path, std.testing.allocator, .{ .tolerance = 0.0001 });
    defer flat.deinit();
    for (0..1001) |i| {
        const t = @as(f64, @floatFromInt(i)) / 1000.0;
        const u = 1 - t;
        const denominator = u * u - u * t + t * t;
        const point: Point = .{ .x = (-u * u + t * t) / denominator, .y = -u * t / denominator };
        try std.testing.expect(distanceToPolyline(point, flat.points.items) <= 0.0001 + 1e-12);
    }
    const bounds = (try path.bounds()).?;
    try std.testing.expectApproxEqAbs(@as(f64, -1), bounds.min.y, 1e-10);
}
