//! CPU semantic reference for Porter-Duff and artistic operators. GPU shaders
//! implement the same equations; final validation compares both and Blend2D.
const std = @import("std");
const color = @import("color.zig");
pub const Pixel = color.Pixel;
pub const Mode = enum(u8) {
    source_over, source, source_in, source_out, source_atop,
    destination_over, destination, destination_in, destination_out, destination_atop,
    xor, clear, plus, minus, modulate, multiply, screen, overlay, darken, lighten,
    color_dodge, color_burn, linear_burn, linear_light, pin_light, hard_light,
    soft_light, difference, exclusion, hue, saturation, color, luminosity,
};
/// Geometric coverage interpolates the completed operation. Scaling source alpha
/// alone would give incorrect edge behavior for copy, clear, in and out modes.
pub fn composite(mode: Mode, source: Pixel, destination: Pixel, coverage: f64) Pixel {
    return Pixel.lerp(destination, operation(mode, source, destination), std.math.clamp(coverage, 0, 1));
}
pub fn operation(mode: Mode, s: Pixel, d: Pixel) Pixel {
    const sa = s.a; const da = d.a;
    switch (mode) {
        .clear => return .{}, .source => return s, .destination => return d,
        .source_over => return Pixel.add(s, d.scaled(1-sa)),
        .destination_over => return Pixel.add(d, s.scaled(1-da)),
        .source_in => return s.scaled(da), .destination_in => return d.scaled(sa),
        .source_out => return s.scaled(1-da), .destination_out => return d.scaled(1-sa),
        .source_atop => return Pixel.add(s.scaled(da), d.scaled(1-sa)),
        .destination_atop => return Pixel.add(d.scaled(sa), s.scaled(1-da)),
        .xor => return Pixel.add(s.scaled(1-da), d.scaled(1-sa)),
        .plus => return .{ .r=@min(1,s.r+d.r), .g=@min(1,s.g+d.g), .b=@min(1,s.b+d.b), .a=@min(1,sa+da) },
        .minus => return .{ .r=@max(0,d.r-s.r)+s.r*(1-da), .g=@max(0,d.g-s.g)+s.g*(1-da), .b=@max(0,d.b-s.b)+s.b*(1-da), .a=sa+da-sa*da },
        .modulate => return .{ .r=s.r*d.r, .g=s.g*d.g, .b=s.b*d.b, .a=sa*da },
        else => {},
    }
    const cs = s.straight(); const cd = d.straight();
    const source_rgb=[3]f64{cs.r,cs.g,cs.b}; const destination_rgb=[3]f64{cd.r,cd.g,cd.b};
    const blended = blendRgb(mode, source_rgb, destination_rgb);
    return .{ .r = s.r*(1-da)+d.r*(1-sa)+sa*da*blended[0], .g = s.g*(1-da)+d.g*(1-sa)+sa*da*blended[1], .b = s.b*(1-da)+d.b*(1-sa)+sa*da*blended[2], .a=sa+da-sa*da };
}
fn blendRgb(mode: Mode, s: [3]f64, d: [3]f64) [3]f64 {
    switch (mode) {
        .hue => return setLum(setSat(s, sat(d)), lum(d)),
        .saturation => return setLum(setSat(d, sat(s)), lum(d)),
        .color => return setLum(s, lum(d)),
        .luminosity => return setLum(d, lum(s)),
        else => {},
    }
    var result: [3]f64 = undefined;
    for (&result, s, d) |*out, a, b| out.* = channel(mode, a, b);
    return result;
}
fn channel(mode: Mode, s: f64, d: f64) f64 {
    return switch (mode) {
        .multiply => s*d, .screen => s+d-s*d,
        .overlay => if (d<=0.5) 2*s*d else 1-2*(1-s)*(1-d),
        .hard_light => if (s<=0.5) 2*s*d else 1-2*(1-s)*(1-d),
        .darken => @min(s,d), .lighten => @max(s,d),
        .color_dodge => if (d<=0) 0 else if (s>=1) 1 else @min(1,d/(1-s)),
        .color_burn => if (d>=1) 1 else if (s<=0) 0 else 1-@min(1,(1-d)/s),
        .linear_burn => @max(0,s+d-1), .linear_light => std.math.clamp(d+2*s-1,0,1),
        .pin_light => if (s<=0.5) @min(d,2*s) else @max(d,2*s-1),
        .soft_light => if (s<=0.5) d-(1-2*s)*d*(1-d) else d+(2*s-1)*(softD(d)-d),
        .difference => @abs(d-s), .exclusion => s+d-2*s*d,
        else => unreachable,
    };
}
fn softD(d: f64) f64 { return if (d<=0.25) ((16*d-12)*d+4)*d else @sqrt(@max(0,d)); }
fn lum(c: [3]f64) f64 { return 0.3*c[0]+0.59*c[1]+0.11*c[2]; }
fn sat(c: [3]f64) f64 { return @max(c[0],@max(c[1],c[2]))-@min(c[0],@min(c[1],c[2])); }
fn setLum(input: [3]f64, target: f64) [3]f64 {
    const delta=target-lum(input); var c=input;
    for (&c) |*v| v.* += delta;
    const l=lum(c); const n=@min(c[0],@min(c[1],c[2])); const x=@max(c[0],@max(c[1],c[2]));
    if (n<0 and l!=n) for (&c) |*v| v.*=l+(v.*-l)*l/(l-n);
    if (x>1 and x!=l) for (&c) |*v| v.*=l+(v.*-l)*(1-l)/(x-l);
    return c;
}
fn setSat(c: [3]f64, target: f64) [3]f64 {
    var order=[3]usize{0,1,2};
    if (c[order[0]]>c[order[1]]) std.mem.swap(usize,&order[0],&order[1]);
    if (c[order[1]]>c[order[2]]) std.mem.swap(usize,&order[1],&order[2]);
    if (c[order[0]]>c[order[1]]) std.mem.swap(usize,&order[0],&order[1]);
    var out=[3]f64{0,0,0};
    if (c[order[2]]>c[order[0]]) {
        out[order[1]]=(c[order[1]]-c[order[0]])*target/(c[order[2]]-c[order[0]]);
        out[order[2]]=target;
    }
    return out;
}
