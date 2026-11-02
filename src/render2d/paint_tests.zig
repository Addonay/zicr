//! Written during implementation phase; run only in the final validation phase.
const std=@import("std");
const c=@import("color.zig");
const p=@import("paint.zig");
const im=@import("image.zig");
const comp=@import("composite.zig");
fn expectPixel(expected:c.Pixel,actual:c.Pixel,tolerance:f64) !void {inline for(@typeInfo(c.Pixel).@"struct".field_names)|field|try std.testing.expectApproxEqAbs(@field(expected,field),@field(actual,field),tolerance);}
test "copy and clear retain destination under fractional geometry coverage" {
    const source=(c.Color{.r=1,.a=0.5}).premultiplied();const destination=(c.Color{.b=1}).premultiplied();
    try expectPixel(.{.r=0.25,.b=0.5,.a=0.75},comp.composite(.source,source,destination,0.5),1e-12);
    try expectPixel(.{.b=0.75,.a=0.75},comp.composite(.clear,source,destination,0.25),1e-12);
    try expectPixel(destination,comp.composite(.source,source,destination,0),1e-12);
    try expectPixel(.{.r=0.5,.b=0.5,.a=1},comp.composite(.source_over,source,destination,1),1e-12);
}
test "all composition modes preserve normalized alpha and valid finite channels" {
    const s=(c.Color{.r=0.8,.g=0.2,.b=0.6,.a=0.35}).premultiplied();const d=(c.Color{.r=0.1,.g=0.7,.b=0.3,.a=0.65}).premultiplied();
    inline for(@typeInfo(comp.Mode).@"enum".field_names)|name|{
        const mode=@field(comp.Mode,name);const result=comp.composite(mode,s,d,0.6);
        try std.testing.expect(result.valid());
        try std.testing.expect(result.r>=-1e-12 and result.g>=-1e-12 and result.b>=-1e-12);
        try std.testing.expect(result.r<=result.a+1e-12 and result.g<=result.a+1e-12 and result.b<=result.a+1e-12);
        try expectPixel(d,comp.composite(mode,s,d,0),1e-12);
    }
}
test "gradient duplicate stops are right-continuous and arbitrary offsets extend correctly" {
    const gradient:p.Gradient=.{.stops=&.{.{.offset=0,.color=.{.r=1}},.{.offset=0.5,.color=.{.r=1}},.{.offset=0.5,.color=.{.b=1}},.{.offset=1,.color=.{.b=1}}}};
    try gradient.validate();try expectPixel(.{.r=1,.a=1},gradient.at(0.499),1e-12);try expectPixel(.{.b=1,.a=1},gradient.at(0.5),1e-12);
    var repeat=gradient;repeat.extend=.repeat;try expectPixel(gradient.at(0.25),repeat.at(1.25),1e-12);
    var reflect=gradient;reflect.extend=.reflect;try expectPixel(gradient.at(0.75),reflect.at(1.25),1e-12);
    var transparent=gradient;transparent.extend=.transparent;try expectPixel(.{},transparent.at(-0.1),1e-12);
}
test "premultiplied gradient interpolation ignores transparent endpoint RGB" {
    const gradient:p.Gradient=.{.stops=&.{.{.offset=0,.color=.{.r=1,.a=0}},.{.offset=1,.color=.{.b=1,.a=1}}}};
    try expectPixel(.{.b=0.5,.a=0.5},gradient.at(0.5),1e-12);
}
test "image filtering interpolates premultiplied linear pixels without transparent fringes" {
    var image=try im.Image.fromBytes(std.testing.allocator,2,1,&.{255,0,0,0,0,0,255,255},.{});defer image.deinit();
    try expectPixel(.{.b=0.5,.a=0.5},try image.sample(1,0.5,.{.filter=.linear}),1e-12);
    try image.generateMipmaps();try std.testing.expectEqual(@as(usize,2),image.levels.len);
    try expectPixel(.{.b=0.5,.a=0.5},image.levels[1].pixels[0],1e-12);
}
test "pattern atlas filtering stays within its region" {
    var image=try im.Image.fromBytes(std.testing.allocator,2,1,&.{255,0,0,255,0,0,255,255},.{});defer image.deinit();
    const paint:p.Paint=.{.image=.{.image=.{.pixels=&image},.region=.{.width=1,.height=1},.sampling=.{.filter=.linear,.extend_x=.pad,.extend_y=.pad}}};
    try expectPixel(.{.r=1,.a=1},try paint.evaluated(.{.x=0.99,.y=0.5}),1e-12);
}
test "transfer functions preserve extended gamut and roundtrip midtones" {
    for([_]f64{-0.5,0,0.003,0.1,0.5,1,3})|value|try std.testing.expectApproxEqAbs(value,c.decodeSrgb(c.encodeSrgb(value)),1e-12);
    const input:c.Color=.{.r=1,.g=0.2,.b=0.4,.a=0.8};const restored=input.converted(.linear_srgb,.display_p3).converted(.display_p3,.linear_srgb);
    try std.testing.expectApproxEqAbs(input.r,restored.r,1e-8);try std.testing.expectApproxEqAbs(input.g,restored.g,1e-8);try std.testing.expectApproxEqAbs(input.b,restored.b,1e-8);
}
