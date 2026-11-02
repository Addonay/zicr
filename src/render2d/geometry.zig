//! Double-precision local/device geometry for paths, paints and glyph outlines.
const std = @import("std");
pub const Point = struct {
    x: f64 = 0,
    y: f64 = 0,
    pub fn finite(p: Point) bool {
        return std.math.isFinite(p.x) and std.math.isFinite(p.y);
    }
    pub fn lerp(a: Point, b: Point, t: f64) Point {
        return .{ .x = a.x * (1 - t) + b.x * t, .y = a.y * (1 - t) + b.y * t };
    }
    pub fn eql(a: Point, b: Point) bool {
        return a.x == b.x and a.y == b.y;
    }
};
pub const Rect = struct { x: f64 = 0, y: f64 = 0, width: f64, height: f64 };
pub const Bounds = struct {
    min: Point,
    max: Point,
    pub fn include(b: *Bounds, p: Point) void {
        b.min = .{ .x = @min(b.min.x, p.x), .y = @min(b.min.y, p.y) };
        b.max = .{ .x = @max(b.max.x, p.x), .y = @max(b.max.y, p.y) };
    }
};
/// Column-vector map: (a*x+c*y+tx, b*x+d*y+ty). Positive Y points down.
pub const Affine = struct {
    a: f64 = 1,
    b: f64 = 0,
    c: f64 = 0,
    d: f64 = 1,
    tx: f64 = 0,
    ty: f64 = 0,
    pub fn translation(x: f64, y: f64) Affine {
        return .{ .tx = x, .ty = y };
    }
    pub fn scaling(x: f64, y: f64) Affine {
        return .{ .a = x, .d = y };
    }
    pub fn rotation(angle: f64) Affine {
        return .{ .a = @cos(angle), .b = @sin(angle), .c = -@sin(angle), .d = @cos(angle) };
    }
    pub fn finite(t: Affine) bool {
        inline for (@typeInfo(Affine).@"struct".field_names) |name| if (!std.math.isFinite(@field(t, name))) return false;
        return true;
    }
    pub fn point(t: Affine, p: Point) Point {
        return .{ .x = t.a * p.x + t.c * p.y + t.tx, .y = t.b * p.x + t.d * p.y + t.ty };
    }
    /// Apply child first, then parent.
    pub fn mul(parent: Affine, child: Affine) Affine {
        return .{ .a = parent.a * child.a + parent.c * child.b, .b = parent.b * child.a + parent.d * child.b, .c = parent.a * child.c + parent.c * child.d, .d = parent.b * child.c + parent.d * child.d, .tx = parent.a * child.tx + parent.c * child.ty + parent.tx, .ty = parent.b * child.tx + parent.d * child.ty + parent.ty };
    }
    pub fn inverse(t: Affine) error{SingularTransform}!Affine {
        const determinant = t.a * t.d - t.b * t.c;
        if (!t.finite() or !std.math.isFinite(determinant) or determinant == 0) return error.SingularTransform;
        const result: Affine = .{ .a = t.d / determinant, .b = -t.b / determinant, .c = -t.c / determinant, .d = t.a / determinant, .tx = (t.c * t.ty - t.d * t.tx) / determinant, .ty = (t.b * t.tx - t.a * t.ty) / determinant };
        if (!result.finite()) return error.SingularTransform;
        return result;
    }
};

/// Distance to the finite segment (not its infinite line), so collinear
/// backtracking curves cannot incorrectly pass the flatness test.
pub fn distanceToSegment(p: Point, a: Point, b: Point) f64 {
    const dx = b.x - a.x;
    const dy = b.y - a.y;
    const length = std.math.hypot(dx, dy);
    if (length == 0) return std.math.hypot(p.x - a.x, p.y - a.y);
    if (!std.math.isFinite(length)) return std.math.inf(f64);
    const ux = dx / length;
    const uy = dy / length;
    const projection = std.math.clamp((p.x - a.x) * ux + (p.y - a.y) * uy, 0, length);
    const ex = p.x - (a.x + projection * ux);
    const ey = p.y - (a.y + projection * uy);
    return std.math.hypot(ex, ey);
}

test "affine composition and inverse retain asymmetric double precision coordinates" {
    const t = Affine.mul(Affine.translation(1e9, -3), Affine.mul(Affine.rotation(0.37), Affine.scaling(2, -3)));
    const p: Point = .{ .x = 1.25, .y = -4.75 };
    const restored = (try t.inverse()).point(t.point(p));
    try std.testing.expectApproxEqAbs(p.x, restored.x, 1e-6);
    try std.testing.expectApproxEqAbs(p.y, restored.y, 1e-6);
    try std.testing.expectError(error.SingularTransform, Affine.scaling(0, 1).inverse());
}
