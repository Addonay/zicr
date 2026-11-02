//! Stroke-to-outline geometry. The result is a positive-winding union of
//! segment bodies, outer joins and caps, filled once by the GPU coverage path.
const std = @import("std");
const paths = @import("path.zig");
const geo = @import("geometry.zig");
const Point = geo.Point;
pub const Cap = enum { butt, square, round, round_reverse, triangle, triangle_reverse };
pub const Join = enum { miter_clip, miter_bevel, miter_round, bevel, round };
pub const TransformOrder = enum { stroke_then_transform, transform_then_stroke };
pub const Options = struct {
    width: f64 = 1,
    join: Join = .miter_clip,
    start_cap: Cap = .butt,
    end_cap: Cap = .butt,
    miter_limit: f64 = 4,
    dashes: []const f64 = &.{},
    dash_offset: f64 = 0,
    transform: geo.Affine = .{},
    order: TransformOrder = .stroke_then_transform,
    tolerance: f64 = 1.0 / 256.0,
    max_points: usize = 1 << 20,
    max_pieces: usize = 1 << 18,
};
pub const Error = paths.Error || paths.FlattenError || error{ InvalidStroke, StrokeLimit };
const Interval = struct { start: f64, end: f64 };
const Segment = struct { from: Point, to: Point, length: f64, start: f64 };

/// Returned Path owns its storage. It is in transformed coordinates and must
/// be filled using nonzero winding. This function never mutates the source.
pub fn outline(path: *const paths.Path, allocator: std.mem.Allocator, options: Options) Error!paths.Path {
    if (!std.math.isFinite(options.width) or options.width < 0 or !std.math.isFinite(options.miter_limit) or options.miter_limit < 1 or
        !std.math.isFinite(options.dash_offset) or !options.transform.finite() or !std.math.isFinite(options.tolerance) or options.tolerance <= 0) return error.InvalidStroke;
    var period: f64 = 0;
    for (options.dashes) |dash| {
        if (!std.math.isFinite(dash) or dash < 0) return error.InvalidStroke;
        period += dash;
    }
    if (options.dashes.len % 2 != 0) period *= 2;
    if (!std.math.isFinite(period)) return error.InvalidStroke;
    var result = paths.Path.init(allocator);
    errdefer result.deinit();
    if (options.width == 0) return result;
    const matrix_norm = std.math.hypot(std.math.hypot(options.transform.a, options.transform.b), std.math.hypot(options.transform.c, options.transform.d));
    const local_tolerance = if (options.order == .stroke_then_transform) options.tolerance / @max(matrix_norm, 1) else options.tolerance;
    var flat = try paths.flatten(path, allocator, .{ .transform = if (options.order == .transform_then_stroke) options.transform else .{}, .tolerance = local_tolerance, .max_points = options.max_points });
    defer flat.deinit();
    var builder: Builder = .{ .output = &result, .options = options };
    for (flat.contours.items) |contour| {
        var points = flat.contourPoints(contour);
        if (points.len > 1 and points[0].eql(points[points.len - 1])) points = points[0 .. points.len - 1];
        if (points.len == 0) continue;
        if (period == 0) {
            try builder.polyline(points, contour.closed);
        } else try dashed(&builder, points, contour.closed, period);
    }
    if (options.order == .stroke_then_transform) {
        const transformed = try result.transformed(allocator, options.transform);
        result.deinit();
        result = transformed;
    }
    return result;
}
const Builder = struct {
    output: *paths.Path,
    options: Options,
    pieces: usize = 0,
    fn piece(self: *Builder) Error!void {
        if (self.pieces >= self.options.max_pieces) return error.StrokeLimit;
        self.pieces += 1;
    }
    fn polygon(self: *Builder, comptime count: usize, input: [count]Point) Error!void {
        var points = input;
        var area: f64 = 0;
        for (points, 0..) |point, i| {
            if (!point.finite()) return error.InvalidCoordinate;
            const a = subtract(point, points[0]);
            const b = subtract(points[(i + 1) % count], points[0]);
            area += cross(a, b);
        }
        if (!std.math.isFinite(area)) return error.InvalidCoordinate;
        if (area == 0) return;
        if (area < 0) std.mem.reverse(Point, &points);
        try self.piece();
        try self.output.addPolygon(&points, true);
    }
    fn sector(self: *Builder, center: Point, direction: Point, sweep: f64) Error!void {
        try self.piece();
        const radius = self.options.width * 0.5;
        const angle = std.math.atan2(direction.y, direction.x);
        try self.output.moveTo(center);
        try self.output.arc(center, .{ .x = radius, .y = radius }, 0, angle, sweep);
        try self.output.close();
    }
    fn cap(self: *Builder, center: Point, outward: Point, kind: Cap) Error!void {
        const radius = self.options.width * 0.5;
        const side: Point = .{ .x = outward.y * radius, .y = -outward.x * radius };
        const extension = multiply(outward, radius);
        const a = add(center, side);
        const b = subtract(center, side);
        switch (kind) {
            .butt => {},
            .square => try self.polygon(4, .{ a, add(a, extension), add(b, extension), b }),
            .triangle => try self.polygon(3, .{ a, add(center, extension), b }),
            .triangle_reverse => try self.polygon(5, .{ a, add(a, extension), center, add(b, extension), b }),
            .round => try self.sector(center, .{ .x = outward.y, .y = -outward.x }, std.math.pi),
            .round_reverse => {
                try self.piece();
                try self.output.moveTo(a);
                try self.output.lineTo(add(a, extension));
                try self.output.conicTo(a, center, @sqrt(@as(f64, 0.5)));
                try self.output.conicTo(b, add(b, extension), @sqrt(@as(f64, 0.5)));
                try self.output.lineTo(b);
                try self.output.close();
            },
        }
    }
    fn join(self: *Builder, center: Point, incoming: Point, outgoing: Point) Error!void {
        const turn = cross(incoming, outgoing);
        const cosine = dot(incoming, outgoing);
        if (turn == 0) {
            if (cosine < 0 and (self.options.join == .round or self.options.join == .miter_round)) try self.cap(center, incoming, .round);
            return;
        }
        const radius = self.options.width * 0.5;
        const sign: f64 = if (turn > 0) -1 else 1;
        const na: Point = .{ .x = -incoming.y * sign, .y = incoming.x * sign };
        const nb: Point = .{ .x = -outgoing.y * sign, .y = outgoing.x * sign };
        const a = add(center, multiply(na, radius));
        const b = add(center, multiply(nb, radius));
        const distance_along = cross(subtract(b, a), outgoing) / turn;
        const miter = add(a, multiply(incoming, distance_along));
        const miter_length = std.math.hypot(miter.x - center.x, miter.y - center.y);
        const is_miter = self.options.join == .miter_clip or self.options.join == .miter_bevel or self.options.join == .miter_round;
        if (is_miter and std.math.isFinite(miter_length) and miter_length <= self.options.miter_limit * radius) return self.polygon(4, .{ center, a, miter, b });
        if (self.options.join == .round or self.options.join == .miter_round) {
            const direction = if (turn > 0) na else nb;
            return self.sector(center, direction, @abs(std.math.atan2(turn, cosine)));
        }
        if (self.options.join == .miter_clip and std.math.isFinite(miter_length) and miter_length > 0) {
            const bisector = multiply(subtract(miter, center), 1 / miter_length);
            const clip_distance = self.options.miter_limit * radius;
            const da = subtract(miter, a);
            const db = subtract(miter, b);
            const denominator_a = dot(da, bisector);
            const denominator_b = dot(db, bisector);
            if (denominator_a != 0 and denominator_b != 0) {
                const ta = std.math.clamp((clip_distance - dot(subtract(a, center), bisector)) / denominator_a, 0, 1);
                const tb = std.math.clamp((clip_distance - dot(subtract(b, center), bisector)) / denominator_b, 0, 1);
                return self.polygon(5, .{ center, a, add(a, multiply(da, ta)), add(b, multiply(db, tb)), b });
            }
        }
        try self.polygon(3, .{ center, a, b });
    }
    fn polyline(self: *Builder, points: []const Point, closed: bool) Error!void {
        if (points.len == 0) return;
        if (points.len == 1) {
            if (!closed) {
                try self.cap(points[0], .{ .x = -1 }, self.options.start_cap);
                try self.cap(points[0], .{ .x = 1 }, self.options.end_cap);
            }
            return;
        }
        const radius = self.options.width * 0.5;
        var first_unit: ?Point = null;
        var previous_unit: ?Point = null;
        var previous_end = points[0];
        const count = points.len - @as(usize, if (closed) 0 else 1);
        for (0..count) |i| {
            const a = points[i];
            const b = points[(i + 1) % points.len];
            const delta = subtract(b, a);
            const length = std.math.hypot(delta.x, delta.y);
            if (!std.math.isFinite(length)) return error.InvalidCoordinate;
            if (length == 0) continue;
            const unit = multiply(delta, 1 / length);
            const side: Point = .{ .x = -unit.y * radius, .y = unit.x * radius };
            if (first_unit == null) first_unit = unit;
            if (previous_unit) |previous| try self.join(a, previous, unit);
            try self.polygon(4, .{ add(a, side), subtract(a, side), subtract(b, side), add(b, side) });
            previous_unit = unit;
            previous_end = b;
        }
        if (first_unit) |first| {
            if (closed) try self.join(points[0], previous_unit.?, first) else {
                try self.cap(points[0], multiply(first, -1), self.options.start_cap);
                try self.cap(previous_end, previous_unit.?, self.options.end_cap);
            }
        } else if (!closed) {
            try self.cap(points[0], .{ .x = -1 }, self.options.start_cap);
            try self.cap(points[0], .{ .x = 1 }, self.options.end_cap);
        }
    }
};
fn dashed(builder: *Builder, points: []const Point, closed: bool, period: f64) Error!void {
    const allocator = builder.output.allocator;
    var segments: std.ArrayList(Segment) = .empty;
    defer segments.deinit(allocator);
    var length: f64 = 0;
    const edge_count = points.len - @as(usize, if (closed) 0 else 1);
    for (0..edge_count) |i| {
        const a = points[i];
        const b = points[(i + 1) % points.len];
        const delta = subtract(b, a);
        const size = std.math.hypot(delta.x, delta.y);
        if (!std.math.isFinite(size) or !std.math.isFinite(length + size)) return error.InvalidCoordinate;
        if (size == 0) continue;
        try segments.append(allocator, .{ .from = a, .to = b, .length = size, .start = length });
        length += size;
    }
    var intervals: std.ArrayList(Interval) = .empty;
    defer intervals.deinit(allocator);
    const values = builder.options.dashes;
    const count = values.len * @as(usize, if (values.len % 2 == 0) 1 else 2);
    var offset = @mod(builder.options.dash_offset, period);
    var index: usize = 0;
    while (offset > values[index % values.len]) {
        offset -= values[index % values.len];
        index = (index + 1) % count;
    }
    var position = @min(values[index % values.len] - offset, length);
    if (index % 2 == 0) try intervals.append(allocator, .{ .start = 0, .end = position });
    var events: usize = 0;
    while (position < length) {
        if (events >= builder.options.max_pieces) return error.StrokeLimit;
        events += 1;
        index = (index + 1) % count;
        const dash_length = @min(values[index % values.len], length - position);
        const end = position + dash_length;
        if (dash_length > 0 and end == position) return error.StrokeLimit;
        if (index % 2 == 0) try intervals.append(allocator, .{ .start = position, .end = end });
        position = end;
    }
    var run: std.ArrayList(Point) = .empty;
    defer run.deinit(allocator);
    const merge_seam = closed and intervals.items.len > 0 and intervals.items[0].start == 0 and intervals.items[intervals.items.len - 1].end == length;
    for (intervals.items, 0..) |interval, i| {
        if (merge_seam and intervals.items.len > 1 and (i == 0 or i == intervals.items.len - 1)) continue;
        run.clearRetainingCapacity();
        try extract(&run, allocator, segments.items, interval, points[0]);
        try builder.polyline(run.items, merge_seam and intervals.items.len == 1);
    }
    if (merge_seam and intervals.items.len > 1) {
        run.clearRetainingCapacity();
        try extract(&run, allocator, segments.items, intervals.items[intervals.items.len - 1], points[0]);
        try extract(&run, allocator, segments.items, intervals.items[0], points[0]);
        // extract suppresses a duplicate closure point at the seam.
        try builder.polyline(run.items, false);
    }
}
fn extract(output: *std.ArrayList(Point), allocator: std.mem.Allocator, segments: []const Segment, interval: Interval, fallback: Point) Error!void {
    if (segments.len == 0) {
        try appendPoint(output, allocator, fallback);
        return;
    }
    var started = false;
    var low: usize = 0;
    var high = segments.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        if (segments[middle].start + segments[middle].length < interval.start) low = middle + 1 else high = middle;
    }
    for (segments[low..]) |segment| {
        if (segment.start + segment.length < interval.start or segment.start > interval.end) continue;
        const a = std.math.clamp((interval.start - segment.start) / segment.length, 0, 1);
        const b = std.math.clamp((interval.end - segment.start) / segment.length, 0, 1);
        if (!started) {
            try appendPoint(output, allocator, Point.lerp(segment.from, segment.to, a));
            started = true;
        }
        try appendPoint(output, allocator, Point.lerp(segment.from, segment.to, b));
        if (interval.end <= segment.start + segment.length) break;
    }
}
fn appendPoint(output: *std.ArrayList(Point), allocator: std.mem.Allocator, point: Point) !void {
    if (output.items.len == 0 or !output.items[output.items.len - 1].eql(point)) try output.append(allocator, point);
}
fn add(a: Point, b: Point) Point {
    return .{ .x = a.x + b.x, .y = a.y + b.y };
}
fn subtract(a: Point, b: Point) Point {
    return .{ .x = a.x - b.x, .y = a.y - b.y };
}
fn multiply(a: Point, k: f64) Point {
    return .{ .x = a.x * k, .y = a.y * k };
}
fn dot(a: Point, b: Point) f64 {
    return a.x * b.x + a.y * b.y;
}
fn cross(a: Point, b: Point) f64 {
    return a.x * b.y - a.y * b.x;
}
