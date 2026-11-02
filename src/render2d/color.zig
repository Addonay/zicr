//! Explicit color/alpha semantics shared by paints, filters and compositing.
//! Computation is linear-light by default. Packing is the only implicit clamp.
const std = @import("std");
pub const Space = enum { linear_srgb, srgb, linear_display_p3, display_p3 };
pub const Color = struct {
    r: f64 = 0, g: f64 = 0, b: f64 = 0, a: f64 = 1,
    pub const transparent: Color = .{ .a = 0 };
    pub const black: Color = .{};
    pub const white: Color = .{ .r = 1, .g = 1, .b = 1 };
    pub fn valid(c: Color) bool { return std.math.isFinite(c.r) and std.math.isFinite(c.g) and std.math.isFinite(c.b) and std.math.isFinite(c.a) and c.a >= 0 and c.a <= 1; }
    pub fn rgba8(r: u8, g: u8, b: u8, a: u8) Color { return .{ .r = decodeSrgb(@as(f64, @floatFromInt(r)) / 255), .g = decodeSrgb(@as(f64, @floatFromInt(g)) / 255), .b = decodeSrgb(@as(f64, @floatFromInt(b)) / 255), .a = @as(f64, @floatFromInt(a)) / 255 }; }
    pub fn premultiplied(c: Color) Pixel { return .{ .r = c.r * c.a, .g = c.g * c.a, .b = c.b * c.a, .a = c.a }; }
    pub fn converted(c: Color, from: Space, to: Space) Color {
        var rgb = [3]f64{ c.r, c.g, c.b };
        if (from == .srgb or from == .display_p3) for (&rgb) |*v| v.* = decodeSrgb(v.*);
        const from_p3 = from == .linear_display_p3 or from == .display_p3;
        const to_p3 = to == .linear_display_p3 or to == .display_p3;
        if (from_p3 != to_p3) rgb = if (from_p3) multiply3(.{
            .{ 1.22494017628056, -0.22494017628056, 0 },
            .{ -0.04205695470969, 1.04205695470969, 0 },
            .{ -0.01963755459033, -0.07863604555063, 1.09827360014097 },
        }, rgb) else multiply3(.{
            .{ 0.82246196871436, 0.17753803128564, 0 },
            .{ 0.03319419885096, 0.96680580114904, 0 },
            .{ 0.01708263072112, 0.07239744066396, 0.91051992861492 },
        }, rgb);
        if (to == .srgb or to == .display_p3) for (&rgb) |*v| v.* = encodeSrgb(v.*);
        return .{ .r = rgb[0], .g = rgb[1], .b = rgb[2], .a = c.a };
    }
};
/// Premultiplied linear channels; RGB can be HDR or outside the sRGB gamut.
pub const Pixel = struct {
    r: f64 = 0, g: f64 = 0, b: f64 = 0, a: f64 = 0,
    pub const transparent: Pixel = .{};
    pub fn straight(p: Pixel) Color { return if (p.a == 0) .transparent else .{ .r = p.r / p.a, .g = p.g / p.a, .b = p.b / p.a, .a = p.a }; }
    pub fn scaled(p: Pixel, alpha: f64) Pixel { return .{ .r = p.r * alpha, .g = p.g * alpha, .b = p.b * alpha, .a = p.a * alpha }; }
    pub fn add(a: Pixel, b: Pixel) Pixel { return .{ .r = a.r + b.r, .g = a.g + b.g, .b = a.b + b.b, .a = a.a + b.a }; }
    pub fn lerp(a: Pixel, b: Pixel, t: f64) Pixel { return add(a.scaled(1 - t), b.scaled(t)); }
    pub fn valid(p: Pixel) bool { return std.math.isFinite(p.r) and std.math.isFinite(p.g) and std.math.isFinite(p.b) and std.math.isFinite(p.a) and p.a >= 0 and p.a <= 1; }
    pub fn rgba8(p: Pixel, output: Space, alpha: enum { straight, premultiplied }) [4]u8 {
        const c = p.straight().converted(.linear_srgb, output);
        const rgb = if (alpha == .premultiplied) c.premultiplied() else Pixel{ .r = c.r, .g = c.g, .b = c.b, .a = c.a };
        return .{ unorm(rgb.r), unorm(rgb.g), unorm(rgb.b), unorm(p.a) };
    }
};
pub fn decodeSrgb(v: f64) f64 { const x = @abs(v); const result = if (x <= 0.04045) x / 12.92 else std.math.pow(f64, (x + 0.055) / 1.055, 2.4); return std.math.copysign(result, v); }
pub fn encodeSrgb(v: f64) f64 { const x = @abs(v); const result = if (x <= 0.0031308) x * 12.92 else 1.055 * std.math.pow(f64, x, 1.0 / 2.4) - 0.055; return std.math.copysign(result, v); }
pub fn unorm(v: f64) u8 { return @intFromFloat(@round(std.math.clamp(v, 0, 1) * 255)); }
fn multiply3(matrix: [3][3]f64, vector: [3]f64) [3]f64 {
    var result: [3]f64 = undefined;
    for (&result, matrix) |*v, row| v.* = row[0] * vector[0] + row[1] * vector[1] + row[2] * vector[2];
    return result;
}

/// Cartesian OKLab coordinates, for perceptual gradient interpolation.
pub fn toOklab(c: Color) [3]f64 {
    const l = std.math.cbrt(0.4122214708*c.r + 0.5363325363*c.g + 0.0514459929*c.b);
    const m = std.math.cbrt(0.2119034982*c.r + 0.6806995451*c.g + 0.1073969566*c.b);
    const s = std.math.cbrt(0.0883024619*c.r + 0.2817188376*c.g + 0.6299787005*c.b);
    return .{ 0.2104542553*l + 0.7936177850*m - 0.0040720468*s, 1.9779984951*l - 2.4285922050*m + 0.4505937099*s, 0.0259040371*l + 0.7827717662*m - 0.8086757660*s };
}
pub fn fromOklab(v: [3]f64, alpha: f64) Color {
    const ll = v[0] + 0.3963377774*v[1] + 0.2158037573*v[2];
    const mm = v[0] - 0.1055613458*v[1] - 0.0638541728*v[2];
    const ss = v[0] - 0.0894841775*v[1] - 1.2914855480*v[2];
    const l=ll*ll*ll; const m=mm*mm*mm; const s=ss*ss*ss;
    return .{ .r = 4.0767416621*l - 3.3077115913*m + 0.2309699292*s, .g = -1.2684380046*l + 2.6097574011*m - 0.3413193965*s, .b = -0.0041960863*l - 0.7034186147*m + 1.7076147010*s, .a = alpha };
}
