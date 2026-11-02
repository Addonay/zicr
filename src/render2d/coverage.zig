//! Analytic coverage of flattened polygons. Winding intervals are integrated
//! across row slabs split at vertices/intersections, rather than supersampled.
//! The resulting coverage is consumed by the portable GPU painter pipeline.
const std = @import("std");
const paths = @import("path.zig");
const Point = @import("geometry.zig").Point;

pub const Clip = struct { x: i32 = 0, y: i32 = 0, width: i32, height: i32 };
pub const Options = struct {
    rule: paths.FillRule = .nonzero,
    max_pixels: usize = 16 * 1024 * 1024,
    max_pair_tests: usize = 4 * 1024 * 1024,
    max_cuts: usize = 1024 * 1024,
};
pub const Error = std.mem.Allocator.Error || error{ InvalidGeometry, RasterLimit };
pub const Mask = struct {
    allocator: std.mem.Allocator,
    bounds: Clip,
    pixels: []f32,
    pub fn deinit(self: *Mask) void {
        self.allocator.free(self.pixels);
        self.* = undefined;
    }
    pub fn spans(self: *const Mask) Spans {
        return .{ .mask = self };
    }
    pub fn row(self: *const Mask, y: usize) []const f32 {
        const width: usize = @intCast(self.bounds.width);
        return self.pixels[y * width ..][0..width];
    }
};
pub const Edge = struct {
    x0: f64,
    y0: f64,
    y1: f64,
    slope: f64,
    winding: i32,
    pub fn xAt(e: Edge, y: f64) f64 {
        return e.x0 + (y - e.y0) * e.slope;
    }
};
const Crossing = struct {
    index: usize,
    x: f64,
    fn less(_: void, a: Crossing, b: Crossing) bool {
        return a.x < b.x;
    }
};

pub fn rasterize(flat: *const paths.FlatPath, allocator: std.mem.Allocator, clip: Clip, options: Options) Error!Mask {
    const bounds = clippedBounds(flat, clip);
    const width: usize = @intCast(bounds.width);
    const height: usize = @intCast(bounds.height);
    if (width != 0 and height > options.max_pixels / width) return error.RasterLimit;
    const pixels = try allocator.alloc(f32, width * height);
    errdefer allocator.free(pixels);
    @memset(pixels, 0);
    var result: Mask = .{ .allocator = allocator, .bounds = bounds, .pixels = pixels };
    if (pixels.len == 0) return result;
    var edges: std.ArrayList(Edge) = .empty;
    defer edges.deinit(allocator);
    for (flat.contours.items) |contour| {
        const points = flat.contourPoints(contour);
        if (points.len < 2) continue;
        // Filling implicitly closes open contours, unlike stroke semantics.
        var previous = points[points.len - 1];
        for (points) |point| {
            if (!previous.finite() or !point.finite()) return error.InvalidGeometry;
            if (previous.y != point.y) {
                const a = if (previous.y < point.y) previous else point;
                const b = if (previous.y < point.y) point else previous;
                const slope = (b.x - a.x) / (b.y - a.y);
                if (!std.math.isFinite(slope)) return error.InvalidGeometry;
                try edges.append(allocator, .{ .x0 = a.x, .y0 = a.y, .y1 = b.y, .slope = slope, .winding = if (point.y > previous.y) 1 else -1 });
            }
            previous = point;
        }
    }
    const area = try allocator.alloc(f64, width);
    defer allocator.free(area);
    var active: std.ArrayList(usize) = .empty;
    defer active.deinit(allocator);
    var cuts: std.ArrayList(f64) = .empty;
    defer cuts.deinit(allocator);
    var crossings: std.ArrayList(Crossing) = .empty;
    defer crossings.deinit(allocator);
    var pair_tests: usize = 0;
    for (0..height) |row_index| {
        const top: f64 = @floatFromInt(@as(i64, bounds.y) + @as(i64, @intCast(row_index)));
        const bottom = top + 1;
        @memset(area, 0);
        active.clearRetainingCapacity();
        cuts.clearRetainingCapacity();
        try addCut(&cuts, allocator, top, options.max_cuts);
        try addCut(&cuts, allocator, bottom, options.max_cuts);
        for (edges.items, 0..) |edge, i| {
            if (edge.y1 <= top or edge.y0 >= bottom) continue;
            try active.append(allocator, i);
            if (edge.y0 > top and edge.y0 < bottom) try addCut(&cuts, allocator, edge.y0, options.max_cuts);
            if (edge.y1 > top and edge.y1 < bottom) try addCut(&cuts, allocator, edge.y1, options.max_cuts);
        }
        for (active.items, 0..) |a_index, i| {
            const a = edges.items[a_index];
            for (active.items[i + 1 ..]) |b_index| {
                if (pair_tests == options.max_pair_tests) return error.RasterLimit;
                pair_tests += 1;
                const b = edges.items[b_index];
                if (a.slope == b.slope) continue;
                const ax = a.xAt(top);
                const bx = b.xAt(top);
                if (!std.math.isFinite(ax) or !std.math.isFinite(bx)) return error.InvalidGeometry;
                const numerator = bx - ax;
                const denominator = a.slope - b.slope;
                const offset: f64 = if (std.math.isFinite(numerator) and std.math.isFinite(denominator)) numerator / denominator else @floatCast((@as(f128, bx) - @as(f128, ax)) / (@as(f128, a.slope) - @as(f128, b.slope)));
                const y = top + offset;
                if (!std.math.isFinite(y)) continue;
                if (y > @max(top, @max(a.y0, b.y0)) and y < @min(bottom, @min(a.y1, b.y1))) try addCut(&cuts, allocator, y, options.max_cuts);
            }
        }
        std.sort.heap(f64, cuts.items, {}, std.sort.asc(f64));
        for (cuts.items[1..], cuts.items[0 .. cuts.items.len - 1]) |end, start| {
            if (end <= start) continue;
            const middle = start * 0.5 + end * 0.5;
            crossings.clearRetainingCapacity();
            for (active.items) |index| {
                const edge = edges.items[index];
                if (middle < edge.y0 or middle >= edge.y1) continue;
                const x = edge.xAt(middle);
                if (!std.math.isFinite(x)) return error.InvalidGeometry;
                try crossings.append(allocator, .{ .index = index, .x = x });
            }
            std.sort.heap(Crossing, crossings.items, {}, Crossing.less);
            var winding: i64 = 0;
            var left: ?Edge = null;
            for (crossings.items) |crossing| {
                const edge = edges.items[crossing.index];
                const was_inside = inside(winding, options.rule);
                winding += edge.winding;
                const is_inside = inside(winding, options.rule);
                if (!was_inside and is_inside) left = edge;
                if (was_inside and !is_inside) {
                    try accumulate(area, bounds.x, left.?, edge, start, end);
                    left = null;
                }
            }
        }
        for (area, result.pixels[row_index * width ..][0..width]) |value, *pixel| {
            if (!std.math.isFinite(value)) return error.InvalidGeometry;
            pixel.* = @floatCast(std.math.clamp(value, 0, 1));
        }
    }
    return result;
}
fn inside(winding: i64, rule: paths.FillRule) bool {
    return if (rule == .nonzero) winding != 0 else @mod(winding, 2) != 0;
}
fn addCut(cuts: *std.ArrayList(f64), allocator: std.mem.Allocator, y: f64, limit: usize) Error!void {
    if (cuts.items.len == limit) return error.RasterLimit;
    try cuts.append(allocator, y);
}
pub fn clippedBounds(flat: *const paths.FlatPath, clip: Clip) Clip {
    const empty: Clip = .{ .width = 0, .height = 0 };
    if (clip.width <= 0 or clip.height <= 0) return empty;
    const bounds = flat.bounds() orelse return empty;
    const right: f64 = @floatFromInt(@as(i64, clip.x) + clip.width);
    const bottom: f64 = @floatFromInt(@as(i64, clip.y) + clip.height);
    const x0 = @max(@as(f64, @floatFromInt(clip.x)), @floor(bounds.min.x));
    const y0 = @max(@as(f64, @floatFromInt(clip.y)), @floor(bounds.min.y));
    const x1 = @min(right, @ceil(bounds.max.x));
    const y1 = @min(bottom, @ceil(bounds.max.y));
    if (x1 <= x0 or y1 <= y0) return empty;
    return .{ .x = @intFromFloat(x0), .y = @intFromFloat(y0), .width = @intFromFloat(x1 - x0), .height = @intFromFloat(y1 - y0) };
}
pub fn accumulate(area: []f64, origin: i32, left: Edge, right: Edge, start: f64, end: f64) Error!void {
    const l0 = left.xAt(start);
    const l1 = left.xAt(end);
    const r0 = right.xAt(start);
    const r1 = right.xAt(end);
    if (!std.math.isFinite(l0) or !std.math.isFinite(l1) or !std.math.isFinite(r0) or !std.math.isFinite(r1)) return error.InvalidGeometry;
    const begin = @max(@as(f64, @floatFromInt(origin)), @floor(@min(l0, l1)));
    const finish = @min(@as(f64, @floatFromInt(@as(i64, origin) + @as(i64, @intCast(area.len)))), @ceil(@max(r0, r1)));
    if (finish <= begin) return;
    const first: usize = @intFromFloat(begin - @as(f64, @floatFromInt(origin)));
    const last: usize = @intFromFloat(finish - @as(f64, @floatFromInt(origin)));
    for (first..last) |i| {
        const x: f64 = @floatFromInt(@as(i64, origin) + @as(i64, @intCast(i)));
        area[i] += (integrateClamp(r0 - x, r1 - x) - integrateClamp(l0 - x, l1 - x)) * (end - start);
    }
}
/// Mean of clamp(v(t),0,1) over t in [0,1], for a linear v.
fn integrateClamp(a: f64, b: f64) f64 {
    if (a <= 0 and b <= 0) return 0;
    if (a >= 1 and b >= 1) return 1;
    if (a >= 0 and a <= 1 and b >= 0 and b <= 1) return (a + b) * 0.5;
    if (a == b) return std.math.clamp(a, 0, 1);
    if (!std.math.isFinite(b - a)) {
        const aa: f128 = a;
        const bb: f128 = b;
        const pa: f128 = if (aa <= 0) 0 else if (aa >= 1) aa - 0.5 else aa * aa * 0.5;
        const pb: f128 = if (bb <= 0) 0 else if (bb >= 1) bb - 0.5 else bb * bb * 0.5;
        return @floatCast(std.math.clamp((pb - pa) / (bb - aa), 0, 1));
    }
    return std.math.clamp((primitive(b) - primitive(a)) / (b - a), 0, 1);
}
fn primitive(x: f64) f64 {
    return if (x <= 0) 0 else if (x >= 1) x - 0.5 else x * x * 0.5;
}

pub const Span = struct { x: i32, y: i32, width: i32, height: i32, coverage: f32 };
/// Merge identical adjacent rows, then emit nonzero constant-coverage runs.
/// Spans partition the mask; their rectangles never overlap.
pub const Spans = struct {
    mask: *const Mask,
    y: usize = 0,
    x: usize = 0,
    band_end: usize = 0,
    pub fn next(self: *Spans) ?Span {
        const height: usize = @intCast(self.mask.bounds.height);
        const width: usize = @intCast(self.mask.bounds.width);
        while (self.y < height and width > 0) {
            const row = self.mask.row(self.y);
            if (self.band_end <= self.y) {
                self.band_end = self.y + 1;
                while (self.band_end < height and std.mem.eql(f32, row, self.mask.row(self.band_end))) self.band_end += 1;
            }
            while (self.x < width and row[self.x] == 0) self.x += 1;
            if (self.x == width) {
                self.y = self.band_end;
                self.x = 0;
                continue;
            }
            const first = self.x;
            const value = row[first];
            self.x += 1;
            while (self.x < width and row[self.x] == value) self.x += 1;
            return .{ .x = self.mask.bounds.x + @as(i32, @intCast(first)), .y = self.mask.bounds.y + @as(i32, @intCast(self.y)), .width = @intCast(self.x - first), .height = @intCast(self.band_end - self.y), .coverage = value };
        }
        return null;
    }
};
