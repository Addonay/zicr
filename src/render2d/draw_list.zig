//! Frame-local geometry, preserving painter order. No GPU or window ownership.
const std = @import("std");
const gpu = @import("gpu");
const paths = @import("path.zig");
const coverage = @import("coverage.zig");
const geo = @import("geometry.zig");
const strokes = @import("stroke.zig");

pub const Vec2 = struct { x: f32 = 0, y: f32 = 0 };
pub const Rect = struct { x: f32 = 0, y: f32 = 0, width: f32, height: f32 };
/// Linear-light, straight RGBA. Vertices store premultiplied color.
pub const Color = @import("color.zig").Color;
/// Column-vector affine map: (a*x+c*y+tx, b*x+d*y+ty).
pub const Transform = struct {
    a: f32 = 1,
    b: f32 = 0,
    c: f32 = 0,
    d: f32 = 1,
    tx: f32 = 0,
    ty: f32 = 0,
    pub fn translation(x: f32, y: f32) Transform {
        return .{ .tx = x, .ty = y };
    }
    pub fn scaling(x: f32, y: f32) Transform {
        return .{ .a = x, .d = y };
    }
    /// Radians; positive angles rotate clockwise in the +Y-down world.
    pub fn rotation(radians: f32) Transform {
        const cosine = @cos(radians);
        const sine = @sin(radians);
        return .{ .a = cosine, .b = sine, .c = -sine, .d = cosine };
    }
    pub fn point(t: Transform, p: Vec2) Vec2 {
        return .{ .x = t.a * p.x + t.c * p.y + t.tx, .y = t.b * p.x + t.d * p.y + t.ty };
    }
    /// Apply `child` first, then `parent`.
    pub fn mul(parent: Transform, child: Transform) Transform {
        return .{ .a = parent.a * child.a + parent.c * child.b, .b = parent.b * child.a + parent.d * child.b, .c = parent.a * child.c + parent.c * child.d, .d = parent.b * child.c + parent.d * child.d, .tx = parent.a * child.tx + parent.c * child.ty + parent.tx, .ty = parent.b * child.tx + parent.d * child.ty + parent.ty };
    }
};
/// Logical world rectangle mapped onto the entire output. Top-left origin, +Y down.
pub const Camera = Rect;
/// Borrowed sampled-image view and sampler. Keep both alive through submission.
/// `.invalid` view selects the renderer's opaque white texture for solid colors.
pub const Texture = struct {
    view: gpu.View = .invalid,
    sampler: gpu.Sampler = .invalid,
    /// Rendered transparent images normally contain premultiplied color.
    alpha: enum { straight, premultiplied } = .straight,
    /// Use for bottom-left-origin offscreen images (GL/GLES/WebGL).
    flip_y: bool = false,
};
pub const Quad = struct {
    rect: Rect,
    uv: Rect = .{ .width = 1, .height = 1 },
    transform: Transform = .{},
    tint: Color = .white,
    texture: Texture = .{},
};
pub const Vertex = extern struct { position: [2]f32, uv: [2]f32, color: [4]f32, premultiplied: f32 };
pub const Batch = struct { first: u32, count: u32, texture: Texture, clip: gpu.Rect };
pub const Error = error{ InvalidDimensions, InvalidGeometry, CapacityExceeded, ClipStackOverflow, ClipStackUnderflow };
pub const FillOptions = struct {
    transform: geo.Affine = .{},
    rule: paths.FillRule = .nonzero,
    /// Device-pixel curve error. Coverage of the resulting line segments is analytic.
    tolerance: f64 = 1.0 / 256.0,
    max_points: usize = 1 << 20,
    max_pixels: usize = 16 * 1024 * 1024,
    max_pair_tests: usize = 4 * 1024 * 1024,
};
pub const Options = struct { max_quads: u32 = 16384, max_clip_depth: u32 = 32 };

/// Owns fixed-capacity storage. `reset` reuses it with no allocations.
/// Capacity errors leave the existing draw list intact.
pub const DrawList = struct {
    allocator: std.mem.Allocator,
    vertices: []Vertex,
    batches: []Batch,
    clips: []gpu.Rect,
    vertex_count: u32 = 0,
    batch_count: u32 = 0,
    clip_depth: usize = 0,
    width: i32 = 0,
    height: i32 = 0,
    camera: Camera = .{ .width = 1, .height = 1 },

    pub fn init(allocator: std.mem.Allocator, options: Options) !DrawList {
        if (options.max_quads == 0 or options.max_quads > std.math.maxInt(u32) / 6 or options.max_clip_depth == 0) return error.InvalidDimensions;
        const vertices = try allocator.alloc(Vertex, @as(usize, options.max_quads) * 6);
        errdefer allocator.free(vertices);
        const batches = try allocator.alloc(Batch, options.max_quads);
        errdefer allocator.free(batches);
        const clips = try allocator.alloc(gpu.Rect, options.max_clip_depth);
        return .{ .allocator = allocator, .vertices = vertices, .batches = batches, .clips = clips };
    }
    pub fn deinit(self: *DrawList) void {
        self.allocator.free(self.clips);
        self.allocator.free(self.batches);
        self.allocator.free(self.vertices);
        self.* = undefined;
    }
    pub fn reset(self: *DrawList, width: i32, height: i32, camera: ?Camera) Error!void {
        const cam = camera orelse Camera{ .width = @floatFromInt(width), .height = @floatFromInt(height) };
        if (width <= 0 or height <= 0 or !validRect(cam) or cam.width <= 0 or cam.height <= 0) return error.InvalidDimensions;
        self.width = width;
        self.height = height;
        self.camera = cam;
        self.vertex_count = 0;
        self.batch_count = 0;
        self.clip_depth = 0;
    }
    /// Pixel-space, axis-aligned clip, independent of the camera and quad transforms.
    /// Nested clips intersect. Empty clips suppress drawing without using capacity.
    pub fn pushClip(self: *DrawList, bounds: gpu.Rect) Error!void {
        if (self.width == 0) return error.InvalidDimensions;
        if (self.clip_depth == self.clips.len) return error.ClipStackOverflow;
        self.clips[self.clip_depth] = intersect(self.currentClip(), bounds);
        self.clip_depth += 1;
    }
    pub fn popClip(self: *DrawList) Error!void {
        if (self.clip_depth == 0) return error.ClipStackUnderflow;
        self.clip_depth -= 1;
    }
    fn currentClip(self: *const DrawList) gpu.Rect {
        return if (self.clip_depth > 0) self.clips[self.clip_depth - 1] else .{ .width = self.width, .height = self.height };
    }
    pub fn rect(self: *DrawList, bounds: Rect, color: Color) Error!void {
        return self.quad(.{ .rect = bounds, .tint = color });
    }
    /// Fill vector contours with analytic line-segment antialiasing. CPU
    /// preprocessing emits disjoint coverage spans into the normal GPU batch.
    /// Uses temporary allocator storage; unlike quad(), this is not allocation-free.
    /// All geometry/coverage/capacity failures preserve earlier draw commands.
    pub fn fillPath(self: *DrawList, path: *const paths.Path, color: Color, options: FillOptions) (Error || paths.FlattenError || coverage.Error)!void {
        if (self.width <= 0 or self.height <= 0) return error.InvalidDimensions;
        if (!color.valid()) return error.InvalidGeometry;
        const clip = self.currentClip();
        if (clip.width == 0 or clip.height == 0) return;
        const sx = @as(f64, @floatFromInt(self.width)) / self.camera.width;
        const sy = @as(f64, @floatFromInt(self.height)) / self.camera.height;
        const camera: geo.Affine = .{ .a = sx, .d = sy, .tx = -@as(f64, self.camera.x) * sx, .ty = -@as(f64, self.camera.y) * sy };
        var flat = try paths.flatten(path, self.allocator, .{ .transform = geo.Affine.mul(camera, options.transform), .tolerance = options.tolerance, .max_points = options.max_points });
        defer flat.deinit();
        var mask = try coverage.rasterize(&flat, self.allocator, .{ .x = clip.x, .y = clip.y, .width = clip.width, .height = clip.height }, .{ .rule = options.rule, .max_pixels = options.max_pixels, .max_pair_tests = options.max_pair_tests });
        defer mask.deinit();
        var count: usize = 0;
        var counter = mask.spans();
        while (counter.next() != null) count += 1;
        if (count > (self.vertices.len - self.vertex_count) / 6) return error.CapacityExceeded;
        const old_vertices = self.vertex_count;
        const old_batches = self.batch_count;
        const old_last_count = if (old_batches > 0) self.batches[old_batches - 1].count else 0;
        errdefer {
            self.vertex_count = old_vertices;
            self.batch_count = old_batches;
            if (old_batches > 0) self.batches[old_batches - 1].count = old_last_count;
        }
        const old_camera = self.camera;
        defer self.camera = old_camera;
        // Spans are already in output pixels, avoiding a lossy round-trip
        // through large world-space f32 coordinates.
        self.camera = .{ .width = @floatFromInt(self.width), .height = @floatFromInt(self.height) };
        var spans = mask.spans();
        while (spans.next()) |span| try self.quad(.{
            .rect = .{ .x = @floatFromInt(span.x), .y = @floatFromInt(span.y), .width = @floatFromInt(span.width), .height = @floatFromInt(span.height) },
            .tint = .{ .r = color.r, .g = color.g, .b = color.b, .a = color.a * span.coverage },
        });
    }
    /// Stroke retained geometry and submit its union coverage through the GPU
    /// painter. Width is local-space by default; transform_then_stroke makes
    /// it output-pixel width after the camera and supplied transform.
    pub fn strokePath(self: *DrawList, path: *const paths.Path, color: Color, options: strokes.Options) (Error || strokes.Error || coverage.Error)!void {
        if (self.width <= 0 or self.height <= 0) return error.InvalidDimensions;
        const sx = @as(f64, @floatFromInt(self.width)) / self.camera.width;
        const sy = @as(f64, @floatFromInt(self.height)) / self.camera.height;
        const camera: geo.Affine = .{ .a = sx, .d = sy, .tx = -@as(f64, self.camera.x) * sx, .ty = -@as(f64, self.camera.y) * sy };
        var configured = options;
        configured.transform = geo.Affine.mul(camera, options.transform);
        var outline = try strokes.outline(path, self.allocator, configured);
        defer outline.deinit();
        const old_camera = self.camera;
        defer self.camera = old_camera;
        self.camera = .{ .width = @floatFromInt(self.width), .height = @floatFromInt(self.height) };
        try self.fillPath(&outline, color, .{ .tolerance = options.tolerance, .max_points = options.max_points });
    }
    pub fn quad(self: *DrawList, q: Quad) Error!void {
        if (self.width == 0) return error.InvalidDimensions;
        if (!validRect(q.rect) or !validRect(q.uv)) return error.InvalidGeometry;
        inline for (@typeInfo(Transform).@"struct".field_names) |field| if (!std.math.isFinite(@field(q.transform, field))) return error.InvalidGeometry;
        if (!q.tint.valid()) return error.InvalidGeometry;
        if (@abs(q.tint.r*q.tint.a)>std.math.floatMax(f32) or @abs(q.tint.g*q.tint.a)>std.math.floatMax(f32) or @abs(q.tint.b*q.tint.a)>std.math.floatMax(f32)) return error.InvalidGeometry;
        const clip = self.currentClip();
        if (clip.width <= 0 or clip.height <= 0 or q.rect.width == 0 or q.rect.height == 0) return;
        if (self.vertices.len - self.vertex_count < 6) return error.CapacityExceeded;
        // Validate all generated coordinates before mutating the list.
        var corners: [4]Vertex = undefined;
        const offsets = [4][2]f32{ .{ 0, 0 }, .{ 1, 0 }, .{ 1, 1 }, .{ 0, 1 } };
        for (offsets, &corners) |o, *v| {
            const p = q.transform.point(.{ .x = q.rect.x + o[0] * q.rect.width, .y = q.rect.y + o[1] * q.rect.height });
            v.* = .{ .position = .{ 2 * ((p.x - self.camera.x) / self.camera.width) - 1, 1 - 2 * ((p.y - self.camera.y) / self.camera.height) }, .uv = .{ q.uv.x + o[0] * q.uv.width, q.uv.y + (if (q.texture.flip_y) 1 - o[1] else o[1]) * q.uv.height }, .color = .{ @floatCast(q.tint.r * q.tint.a), @floatCast(q.tint.g * q.tint.a), @floatCast(q.tint.b * q.tint.a), @floatCast(q.tint.a) }, .premultiplied = if (q.texture.alpha == .premultiplied) 1 else 0 };
            for (v.position) |n| if (!std.math.isFinite(n)) return error.InvalidGeometry;
            for (v.uv) |n| if (!std.math.isFinite(n)) return error.InvalidGeometry;
        }
        const merge = self.batch_count > 0 and compatible(self.batches[self.batch_count - 1], q.texture, clip);
        if (!merge) {
            self.batches[self.batch_count] = .{ .first = self.vertex_count, .count = 0, .texture = q.texture, .clip = clip };
            self.batch_count += 1;
        }
        for ([_]usize{ 0, 1, 2, 0, 2, 3 }, 0..) |index, offset| self.vertices[self.vertex_count + offset] = corners[index];
        self.vertex_count += 6;
        self.batches[self.batch_count - 1].count += 6;
    }
    pub fn vertexData(self: *const DrawList) []const Vertex {
        return self.vertices[0..self.vertex_count];
    }
    pub fn batchData(self: *const DrawList) []const Batch {
        return self.batches[0..self.batch_count];
    }
};
fn validRect(r: Rect) bool {
    return std.math.isFinite(r.x) and std.math.isFinite(r.y) and std.math.isFinite(r.width) and std.math.isFinite(r.height);
}
fn compatible(batch: Batch, texture: Texture, clip: gpu.Rect) bool {
    return batch.texture.view == texture.view and batch.texture.sampler == texture.sampler and std.meta.eql(batch.clip, clip);
}
fn intersect(a: gpu.Rect, b: gpu.Rect) gpu.Rect {
    const x: i64 = @max(a.x, b.x);
    const y: i64 = @max(a.y, b.y);
    const right = @min(@as(i64, a.x) + @max(a.width, 0), @as(i64, b.x) + @max(b.width, 0));
    const bottom = @min(@as(i64, a.y) + @max(a.height, 0), @as(i64, b.y) + @max(b.height, 0));
    return .{ .x = @intCast(x), .y = @intCast(y), .width = @intCast(@max(0, right - x)), .height = @intCast(@max(0, bottom - y)) };
}

test "painter order is preserved across texture changes" {
    var list = try DrawList.init(std.testing.allocator, .{ .max_quads = 4 });
    defer list.deinit();
    try list.reset(100, 50, null);
    try list.rect(.{ .width = 10, .height = 10 }, .{ .r = 1, .g = 0, .b = 0, .a = 0.5 });
    try list.rect(.{ .width = 10, .height = 10 }, .{});
    try list.quad(.{ .rect = .{ .width = 10, .height = 10 }, .texture = .{ .view = @fromBackingInt(@intCast(5)) } });
    try list.rect(.{ .width = 10, .height = 10 }, .{});
    try std.testing.expectEqual(@as(usize, 3), list.batchData().len);
    try std.testing.expectEqual(@as(u32, 12), list.batches[0].count);
    try std.testing.expectEqual(@as(u32, 12), list.batches[1].first);
    try std.testing.expectEqual(@as(u32, 18), list.batches[2].first);
    try std.testing.expectEqual([4]f32{ 0.5, 0, 0, 0.5 }, list.vertices[0].color);
}
test "camera and affine transform produce asymmetric expected corners" {
    var list = try DrawList.init(std.testing.allocator, .{});
    defer list.deinit();
    try list.reset(200, 100, .{ .x = 10, .y = 20, .width = 100, .height = 50 });
    try list.quad(.{ .rect = .{ .width = 20, .height = 10 }, .transform = .{ .tx = 10, .ty = 20 }, .uv = .{ .x = 0.25, .y = 0.5, .width = 0.5, .height = 0.25 } });
    try std.testing.expectEqual([2]f32{ -1, 1 }, list.vertices[0].position);
    try std.testing.expectApproxEqAbs(@as(f32, -0.6), list.vertices[2].position[0], 0.00001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.6), list.vertices[2].position[1], 0.00001);
    try std.testing.expectEqual([2]f32{ 0.75, 0.75 }, list.vertices[2].uv);
    const t = Transform.mul(.{ .tx = 3, .ty = 4 }, .{ .a = 0, .b = 1, .c = -1, .d = 0 });
    try std.testing.expectEqual(Vec2{ .x = 1, .y = 5 }, t.point(.{ .x = 1, .y = 2 }));
    const composed = Transform.mul(Transform.translation(10, 20), Transform.mul(Transform.rotation(std.math.pi / 2.0), Transform.scaling(2, 3)));
    const point = composed.point(.{ .x = 1, .y = 2 });
    try std.testing.expectApproxEqAbs(@as(f32, 4), point.x, 0.00001);
    try std.testing.expectApproxEqAbs(@as(f32, 22), point.y, 0.00001);
}
test "nested empty clips, overflow and capacity errors are transactional" {
    var list = try DrawList.init(std.testing.allocator, .{ .max_quads = 1, .max_clip_depth = 2 });
    defer list.deinit();
    try list.reset(100, 50, null);
    try list.pushClip(.{ .x = 10, .y = 10, .width = 30, .height = 30 });
    try list.pushClip(.{ .x = 50, .width = 10, .height = 50 });
    try list.rect(.{ .width = 5, .height = 5 }, .{});
    try std.testing.expectEqual(@as(u32, 0), list.vertex_count);
    try std.testing.expectError(error.ClipStackOverflow, list.pushClip(.{ .width = 1, .height = 1 }));
    try list.popClip();
    try list.rect(.{ .width = 5, .height = 5 }, .{});
    try std.testing.expectEqual(gpu.Rect{ .x = 10, .y = 10, .width = 30, .height = 30 }, list.batches[0].clip);
    try std.testing.expectError(error.CapacityExceeded, list.rect(.{ .width = 5, .height = 5 }, .{}));
    try std.testing.expectEqual(@as(u32, 6), list.vertex_count);
    try std.testing.expectError(error.InvalidGeometry, list.rect(.{ .width = std.math.nan(f32), .height = 1 }, .{}));
    try list.popClip();
    try std.testing.expectError(error.ClipStackUnderflow, list.popClip());
    try list.reset(50, 50, null);
    try std.testing.expectEqual(@as(u32, 0), list.vertex_count);
}

test "draw-list initialization frees every partial allocation" {
    const Case = struct {
        fn run(allocator: std.mem.Allocator) !void {
            var list = try DrawList.init(allocator, .{ .max_quads = 4 });
            defer list.deinit();
            try list.reset(20, 10, null);
            try list.rect(.{ .width = 2, .height = 3 }, .{});
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Case.run, .{});
}

test "analytic path fill emits reusable GPU geometry and capacity errors preserve prefix" {
    var list = try DrawList.init(std.testing.allocator, .{ .max_quads = 1 });
    defer list.deinit();
    var path = paths.Path.init(std.testing.allocator);
    defer path.deinit();
    try path.addRect(.{ .width = 100, .height = 100 });
    try list.reset(100, 100, null);
    try list.fillPath(&path, .{ .r = 1, .g = 0, .b = 0 }, .{});
    // Identical interior rows merge into one rectangle, not one quad per pixel.
    try std.testing.expectEqual(@as(u32, 6), list.vertex_count);
    try std.testing.expectEqual(@as(u32, 1), list.batch_count);
    try std.testing.expectEqual([2]f32{ -1, 1 }, list.vertices[0].position);
    try std.testing.expectEqual([2]f32{ 1, -1 }, list.vertices[2].position);
    const first = list.vertices[0];
    const camera = list.camera;
    try std.testing.expectError(error.CapacityExceeded, list.fillPath(&path, .{}, .{}));
    try std.testing.expectEqual(@as(u32, 6), list.vertex_count);
    try std.testing.expectEqual(@as(u32, 6), list.batches[0].count);
    try std.testing.expectEqual(first, list.vertices[0]);
    try std.testing.expectEqual(camera, list.camera);
}

test "path-fill scratch allocation failures do not leak or corrupt previous draws" {
    const Case = struct {
        fn run(allocator: std.mem.Allocator) !void {
            var list = try DrawList.init(allocator, .{ .max_quads = 128 });
            defer list.deinit();
            var path = paths.Path.init(allocator);
            defer path.deinit();
            try path.moveTo(.{});
            try path.lineTo(.{ .x = 10 });
            try path.lineTo(.{ .y = 10 });
            try list.reset(16, 16, null);
            try list.rect(.{ .width = 16, .height = 16 }, .{});
            list.fillPath(&path, .{ .a = 0.5 }, .{}) catch |err| {
                try std.testing.expectEqual(@as(u32, 6), list.vertex_count);
                try std.testing.expectEqual(@as(u32, 6), list.batches[0].count);
                return err;
            };
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Case.run, .{});
}

test "stroke submission failure restores camera and existing draw prefix" {
    var list = try DrawList.init(std.testing.allocator, .{ .max_quads = 1 });
    defer list.deinit();
    var path = paths.Path.init(std.testing.allocator);
    defer path.deinit();
    try path.moveTo(.{ .x = 20, .y = 30 });
    try path.lineTo(.{ .x = 40, .y = 30 });
    try list.reset(64, 64, .{ .x = 10, .y = 20, .width = 64, .height = 64 });
    try list.rect(.{ .width = 64, .height = 64 }, .{});
    const camera = list.camera;
    try std.testing.expectError(error.CapacityExceeded, list.strokePath(&path, .{}, .{ .width = 4 }));
    try std.testing.expectEqual(@as(u32, 6), list.vertex_count);
    try std.testing.expectEqual(@as(u32, 6), list.batches[0].count);
    try std.testing.expectEqual(camera, list.camera);
}
